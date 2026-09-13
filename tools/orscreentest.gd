extends "res://tools/playtest.gd"
## Headless test for the OR wall monitor and the minimal HUD (sweep 2, orscreen).
##
##   godot --headless --path . tools/orscreentest.tscn --fixed-fps 60 -- [--ailment=amputation] [playtest args]
##
## Runs a whole shift with the playtest bot (god mode is forced) and, every physics frame, checks
## the screen's derived content against the game: steps and the current one, supplies ticking green
## as they reach the shelf, vitals and their colour level, stable at the end. Before the shift it
## checks the idle state, that the monitor mounted in the OR, and that the HUD no longer draws the
## removed elements. Synthetic game states cover several cases (game.cases), incoming, dead,
## player cases and a shared shelf, whether or not the `loop` worker's cases exist on this branch.
## Exits 0 only if the shift was won and every check passed.

const ModelScript := preload("res://scripts/orscreen/or_screen_model.gd")
const CanvasScript := preload("res://scripts/orscreen/or_screen_canvas.gd")

var _problems: Array = []
var _checked_frames := 0
var _ticks_seen := {}          # supply kind -> true once it went from missing to ok
var _was_ok := {}
var _steps_seen := {}
var _low_checked := false
var _far_frames := 0
var _far_refreshes := 0
var _last_refresh := -1
var _last_vis := 0.0
var _op_hud_seen := false
var _hud_draw_seen := false
var _stable_seen := false
var _ailment := ""


func _ready() -> void:
	god = true
	await super()
	if game == null:
		return
	_synthetic_checks()
	# The monitor mounts two physics frames after the level exists.
	for i in 6:
		await get_tree().physics_frame
	var scr = game.get("or_screen")
	_expect(scr != null, "game.or_screen exists")
	if scr != null:
		_expect(scr.mounted(), "the monitor mounted in the level")
		_say("[orscreen] placement=%s centre=%s normal=%s" % [scr.placement, str(scr.screen_centre().snappedf(0.1)), str(scr.screen_normal().snappedf(0.01))])
		if scr.mounted():
			var c: Vector3 = scr.screen_centre()
			var t: Vector3 = game.table_pos()
			var flat := Vector2(c.x - t.x, c.z - t.z)
			_expect(flat.length() < 12.0, "the monitor is near the table (%.1f m)" % flat.length())
			var to_table := Vector3(t.x - c.x, 0, t.z - c.z).normalized()
			_expect(scr.screen_normal().dot(to_table) > 0.3, "the monitor faces the table")
			var m: Dictionary = ModelScript.build(game)
			_expect(m.mode == "idle" and bool(m.lobby), "idle in the lobby (mode=%s lobby=%s)" % [m.mode, str(m.lobby)])
	_hud_checks()


# ------------------------------------------------------------------------------ per frame

func _physics_process(delta: float) -> void:
	if not _finished and game != null:
		_sample()
	super(delta)


func _sample() -> void:
	var scr = game.get("or_screen")
	if scr != null and scr.mounted():
		var vis: float = scr._visibility()
		var rc: int = scr.refresh_count
		if _last_refresh >= 0 and vis < 0.0 and _last_vis < 0.0:
			_far_frames += 1
			if rc > _last_refresh:
				_far_refreshes += 1
		_last_refresh = rc
		_last_vis = vis
	var hud = main.hud
	if hud != null and hud.drawn.size() > 0:
		_hud_draw_seen = true
		for bad in ["party", "objective", "case_panel", "surgery_fallback", "gauges"]:
			if hud.drawn.has(bad):
				_problem("HUD drew removed element '%s'" % bad)
	if game.surgery != null and game.surgery.hud != null:
		var canvas = game.surgery.hud.get("_canvas")
		if canvas != null and canvas.drawn.has("operator"):
			_op_hud_seen = true
	match game.phase:
		Game.Phase.SHIFT:
			if game.case.is_empty():
				return
			_check_shift_model()
		Game.Phase.WON:
			var m: Dictionary = ModelScript.build(game)
			# loop: a clocked-out shift may have had several patients; all of them read stable.
			if not m.panels.is_empty() and m.panels.all(func(pn): return pn.state == "stable"):
				_stable_seen = true
				for pn in m.panels:
					for s in pn.steps:
						if s.state != "done":
							_problem("WON but step '%s' is %s" % [s.label, s.state])


func _check_shift_model() -> void:
	var m: Dictionary = ModelScript.build(game)
	_checked_frames += 1
	# loop: one panel per case (game.cases), in order. Several at once are checked case by case;
	# the detailed supply rows only with one live case (the shelf is shared out between panels).
	var n_cases: int = game.cases.size() if "cases" in game else 1
	if m.mode != "cases" or m.panels.size() != n_cases:
		_problem("shift: expected %d panels, got mode=%s panels=%d" % [n_cases, m.mode, m.panels.size()])
		return
	if n_cases > 1:
		_check_multi(m)
		return
	var p: Dictionary = m.panels[0]
	var steps := Procedures.steps(game.case.ailment_id)
	var cur := int(game.case.step_index)
	if String(game.case.get("state", "on_table")) == "stable":
		cur = steps.size()
	if p.steps.size() != steps.size():
		_problem("steps: %d on screen, %d in the procedure" % [p.steps.size(), steps.size()])
	if int(p.current) != cur:
		_problem("current step %d on screen, %d in the case" % [p.current, cur])
	for i in p.steps.size():
		var want := "done" if i < cur else ("current" if i == cur else "todo")
		if p.steps[i].state != want:
			_problem("step %d is %s, expected %s" % [i, p.steps[i].state, want])
			break
	_steps_seen[cur] = true
	_ailment = String(game.case.ailment_id)
	if absf(float(p.vitals) - clampf(game.vitals, 0.0, 100.0)) > 0.01:
		_problem("vitals %.2f on screen, %.2f in the game" % [p.vitals, game.vitals])
	var want_level := "ok" if game.vitals > 50.0 else ("low" if game.vitals > 25.0 else "critical")
	if p.level != want_level:
		_problem("vitals level %s, expected %s at %.1f" % [p.level, want_level, game.vitals])
	# Supplies: exactly the remaining requirements, counted against the shelf.
	var need := Procedures.remaining_requirements(game.case.ailment_id, cur)
	if p.supplies.size() != need.size():
		_problem("supplies: %d rows for %d needed kinds" % [p.supplies.size(), need.size()])
	for s in p.supplies:
		var n := int(need.get(s.kind, -1))
		var have := mini(game.shelf_count(s.kind), n)
		if int(s.need) != n or int(s.have) != have or bool(s.ok) != (have >= n):
			_problem("supply %s shows %d/%d ok=%s, game has %d of %d" % [s.kind, s.have, s.need, str(s.ok), game.shelf_count(s.kind), n])
			break
		if bool(s.ok) and _was_ok.has(s.kind) and not bool(_was_ok[s.kind]):
			if not _ticks_seen.has(s.kind):
				_say("[orscreen] t=%.0f %s ticked green (%d/%d)" % [elapsed, s.kind, s.have, s.need])
			_ticks_seen[s.kind] = true
		_was_ok[s.kind] = bool(s.ok)
	# Once, after the first step: a low and a critical reading, then put the vitals back.
	if cur >= 1 and not _low_checked:
		_low_checked = true
		var keep: float = game.vitals
		game.vitals = 40.0
		var lo: Dictionary = ModelScript.build(game).panels[0]
		game.vitals = 12.0
		var cr: Dictionary = ModelScript.build(game).panels[0]
		game.vitals = keep
		_expect(lo.level == "low" and cr.level == "critical", "vitals 40 is low and 12 is critical (%s, %s)" % [lo.level, cr.level])
		_expect(CanvasScript.bpm_for(12.0) > CanvasScript.bpm_for(90.0) + 40.0, "the trace speeds up as vitals fall")


var _multi_seen := false


## loop: several real cases on the screen at once (the extra patient): each panel matches its case.
func _check_multi(m: Dictionary) -> void:
	if not _multi_seen:
		_multi_seen = true
		_say("[orscreen] t=%.0f the screen shows %d patients" % [elapsed, m.panels.size()])
	for i in m.panels.size():
		var p: Dictionary = m.panels[i]
		var c: Dictionary = game.cases[i]
		if int(p.id) != int(c.id) or int(p.table) != int(c.table) or String(p.state) != String(c.state):
			_problem("panel %d shows case %d table %d %s, game has %d table %d %s" % [i, p.id, p.table, p.state, c.id, c.table, c.state])
			continue
		var steps := Procedures.steps(String(c.ailment_id))
		var cur := steps.size() if String(c.state) == "stable" else int(c.step_index)
		if int(p.current) != cur:
			_problem("panel %d current step %d, case at %d" % [i, p.current, cur])
		var v := 0.0 if String(c.state) == "dead" else clampf(float(c.vitals), 0.0, 100.0)
		if absf(float(p.vitals) - v) > 0.01:
			_problem("panel %d vitals %.2f, case %.2f" % [i, p.vitals, v])
		if String(c.state) == "on_table" or String(c.state) == "incoming":
			var need := Procedures.remaining_requirements(String(c.ailment_id), int(c.step_index))
			for s in p.supplies:
				if int(s.need) != int(need.get(s.kind, -1)) or int(s.have) > game.shelf_count(s.kind):
					_problem("panel %d supply %s shows %d/%d with %d on the shelf" % [i, s.kind, s.have, s.need, game.shelf_count(s.kind)])
					break


# ------------------------------------------------------------------------------ one-off checks

func _hud_checks() -> void:
	var hud = main.hud
	for gone in ["_draw_party", "_draw_objective", "_draw_case_panel", "_missing_supplies", "_draw_surgery_fallback"]:
		_expect(not hud.has_method(gone), "HUD no longer has %s" % gone)
	for kept in ["_draw_hands", "_draw_prompt", "_draw_health", "_draw_message", "_draw_money"]:
		_expect(hud.has_method(kept), "HUD still has %s" % kept)
	var canvas = game.surgery.hud.get("_canvas") if game.surgery != null and game.surgery.hud != null else null
	_expect(canvas != null and not canvas.has_method("_gauge"), "the surgery HUD has no gauges")
	await get_tree().process_frame
	await get_tree().process_frame
	if hud.drawn.size() > 0:
		_say("[orscreen] HUD drew in the lobby: %s" % ", ".join(hud.drawn))
		_expect(hud.drawn.has("hands") and hud.drawn.has("health"), "the lobby HUD draws hands and health")
	else:
		_say("[orscreen] note: _draw() does not run headless here; the per-element HUD checks rely on the method checks")


func _synthetic_checks() -> void:
	# Several cases through game.cases, with a shared shelf.
	var g := FakeCases.new()
	g.shelf = {"anesthetic": 1, "gauze": 1, "forceps": 1}
	g.cases = [
		{"id": 1, "table": 0, "patient_id": "bob", "ailment_id": "gunshot", "step_index": 0, "flags": {}, "vitals": 70.0, "state": "on_table"},
		{"id": 2, "table": 1, "patient_id": "seal", "ailment_id": "amputation", "step_index": 0, "flags": {}, "vitals": 22.0, "state": "on_table"},
	]
	var m: Dictionary = ModelScript.build(g)
	_expect(m.mode == "cases" and m.panels.size() == 2, "two cases give two panels")
	if m.panels.size() == 2:
		var a: Dictionary = m.panels[0]
		var b: Dictionary = m.panels[1]
		_expect(a.patient_name.begins_with("Bob") and b.ailment_id == "amputation", "panels follow the case order")
		_expect(a.level == "ok" and b.level == "critical", "per-case vitals levels")
		_expect(_supply(a, "anesthetic").ok and not _supply(b, "anesthetic").ok, "one anesthetic on the shelf ticks only the first case")
		_expect(_supply(a, "forceps").ok, "tools are not used up between cases")
		_expect(bool(a.ready) and not bool(b.ready), "ready follows the shared shelf")
		_expect(int(b.table) == 1, "the second case is on table 2")
	# Incoming, dead, stable, a player case and a case on the gurney.
	g.cases = [
		{"id": 3, "table": -1, "patient_id": "seal", "ailment_id": "gunshot", "step_index": 0, "vitals": 90.0, "state": "incoming"},
		{"id": 4, "table": 0, "patient_id": "bob", "ailment_id": "amputation", "step_index": 2, "vitals": 0.0, "state": "dead"},
		{"id": 5, "table": 2, "patient_id": "player", "player_id": 77, "ailment_id": "stitches", "step_index": 0, "vitals": 55.0, "state": "stable"},
	]
	m = ModelScript.build(g)
	_expect(m.panels.size() == 3, "three cases give three panels")
	if m.panels.size() == 3:
		_expect(m.panels[0].state == "incoming" and m.panels[0].supplies.size() == 3, "an incoming case shows its supplies")
		_expect(m.panels[1].state == "dead" and float(m.panels[1].vitals) == 0.0 and m.panels[1].supplies.is_empty(), "a dead case reads 0 and needs nothing")
		_expect(m.panels[2].patient_name == "Staff member" and m.panels[2].state == "stable", "a player case without a Player node")
	g.cases = []
	m = ModelScript.build(g)
	_expect(m.mode == "idle" and m.panels.is_empty(), "no cases is idle")
	# The legacy single case.
	var l := FakeLegacy.new()
	l.phase = Game.Phase.LOST
	l.case = {"patient_id": "bob", "ailment_id": "gunshot", "step_index": 1, "flags": {}}
	l.vitals = 0.0
	m = ModelScript.build(l)
	_expect(m.panels.size() == 1 and m.panels[0].state == "dead", "legacy: a lost shift reads dead")
	l.phase = Game.Phase.LOBBY
	_expect(ModelScript.build(l).mode == "idle", "legacy: a leftover case in the lobby is idle")
	# The canvas draws every state without errors (headless: only the code path runs).
	var cv: Control = CanvasScript.new()
	add_child(cv)
	cv.size = Vector2(1024, 576)
	g.cases = [{"id": 1, "table": 0, "patient_id": "bob", "ailment_id": "gunshot", "step_index": 1, "vitals": 30.0, "state": "on_table"}]
	cv.model = ModelScript.build(g)
	cv.queue_redraw()
	cv.queue_free()
	g.free()
	l.free()


func _supply(p: Dictionary, kind: String) -> Dictionary:
	for s in p.supplies:
		if s.kind == kind:
			return s
	return {"ok": false}


func _expect(ok: bool, what: String) -> void:
	if ok:
		_say("[orscreen] ok: " + what)
	else:
		_problem(what)


func _problem(what: String) -> void:
	if _problems.size() < 40 and not _problems.has(what):
		_problems.append(what)
		_say("[orscreen] PROBLEM: " + what)


func _finish(ok: bool) -> void:
	if _finished:
		return
	_expect(_checked_frames > 100, "sampled %d shift frames" % _checked_frames)
	_expect(_steps_seen.size() >= Procedures.steps(_ailment).size() and _ailment != "", "saw every step of %s become current (%s)" % [_ailment, str(_steps_seen.keys())])
	_expect(not _ticks_seen.is_empty(), "supplies ticked green as they arrived (%s)" % str(_ticks_seen.keys()))
	_expect(_low_checked, "checked low and critical vitals")
	_expect(_stable_seen, "the screen read stable when the shift was won")
	if take_extra:
		_expect(_multi_seen, "the screen showed both patients at once (--extra)")
	_expect(_far_frames > 60 and _far_refreshes <= 2, "no picture refreshes while the screen was out of view (%d frames, %d refreshes)" % [_far_frames, _far_refreshes])
	var scr = game.get("or_screen")
	_expect(scr != null and scr.refresh_count > 20, "the picture refreshed while in view (%d refreshes)" % (scr.refresh_count if scr != null else -1))
	if _hud_draw_seen:
		_expect(_op_hud_seen, "the surgery HUD drew its operator strip while operating")
	var passed := ok and _problems.is_empty()
	_say("[orscreen] %s: %d problems" % ["PASS" if passed else "FAIL", _problems.size()])
	super(passed)


class FakeCases extends Node:
	var phase := 2
	var shift := 1
	var vitals := 100.0
	var case := {}
	var cases: Array = []
	var shelf := {}
	var players := {}
	var surgery = null

	func shelf_count(kind: String) -> int:
		return int(shelf.get(kind, 0))


class FakeLegacy extends Node:
	var phase := 2
	var shift := 1
	var vitals := 100.0
	var case := {}
	var shelf := {}
	var players := {}
	var surgery = null

	func shelf_count(kind: String) -> int:
		return int(shelf.get(kind, 0))
