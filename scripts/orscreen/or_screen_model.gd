extends RefCounted
## What the OR wall monitor shows, derived from replicated game state only. Every machine builds
## it locally from the same state, so the screen needs no replication of its own.
##
## build(game) -> {
##   mode: "idle" | "cases",
##   phase: int, shift: int, lobby: bool,
##   panels: [{
##     id, table: int, patient_id, patient_name, ailment_id, ailment_name, code,
##     state: "incoming" | "on_table" | "stable" | "dead",
##     vitals: float 0..100, level: "ok" | "low" | "critical",
##     steps: [{label, item, item_name, state: "done" | "current" | "todo"}], current: int,
##     supplies: [{kind, name, need: int, have: int, ok: bool}],   # remaining steps vs the shelf
##     ready: bool,                                                 # the current step's item is on the shelf
##     operator: String, progress: float,                           # "" when nobody operates
##   }]
## }
##
## Cases come from game.cases (the `loop` worker's contract, docs/SWEEP2.md) when it exists,
## else from the single game.case / game.vitals. The shared shelf is handed out to the panels in
## case order, so two patients needing one anesthetic do not both tick green on one vial.

const ProceduresDB := preload("res://scripts/procedures.gd")
const ItemsDB := preload("res://scripts/items.gd")

const PHASE_LOBBY := 1
const PHASE_SHIFT := 2
const PHASE_WON := 3
const PHASE_LOST := 4

const LOW := 50.0
const CRITICAL := 25.0


static func build(game: Object) -> Dictionary:
	var out := {"mode": "idle", "phase": -1, "shift": 1, "lobby": false, "panels": []}
	if game == null:
		return out
	var phase := int(game.get("phase")) if game.get("phase") != null else -1
	out.phase = phase
	out.shift = int(game.get("shift")) if game.get("shift") != null else 1
	out.lobby = phase == PHASE_LOBBY
	var cases := raw_cases(game)
	var shelf_left := {}
	for i in cases.size():
		var p := _panel(game, cases[i], i, shelf_left)
		if not p.is_empty():
			out.panels.append(p)
	if not out.panels.is_empty():
		out.mode = "cases"
	return out


## The case dictionaries to show, in order: game.cases when present, else the legacy single case.
static func raw_cases(game: Object) -> Array:
	if "cases" in game and game.get("cases") is Array:
		var list := []
		for c in game.get("cases"):
			if c is Dictionary and not c.is_empty():
				list.append(c)
		return list
	var phase := int(game.get("phase")) if game.get("phase") != null else -1
	var c = game.get("case")
	if not (c is Dictionary) or c.is_empty() or phase < PHASE_SHIFT:
		return []
	var legacy: Dictionary = c.duplicate()
	legacy["id"] = int(legacy.get("id", 0))
	legacy["table"] = int(legacy.get("table", 0))
	if not legacy.has("vitals"):
		legacy["vitals"] = float(game.get("vitals")) if game.get("vitals") != null else 100.0
	if not legacy.has("state"):
		legacy["state"] = "stable" if phase == PHASE_WON else ("dead" if phase == PHASE_LOST else "on_table")
	return [legacy]


static func _panel(game: Object, c: Dictionary, order: int, shelf_left: Dictionary) -> Dictionary:
	var ailment_id := String(c.get("ailment_id", ""))
	var patient_id := String(c.get("patient_id", ""))
	var state := String(c.get("state", "on_table"))
	var vitals := clampf(float(c.get("vitals", game.get("vitals") if game.get("vitals") != null else 100.0)), 0.0, 100.0)
	if state == "dead":
		vitals = 0.0
	var ail := ProceduresDB.ailment(ailment_id)
	var steps := ProceduresDB.steps(ailment_id)
	var cur := clampi(int(c.get("step_index", 0)), 0, steps.size())
	if state == "stable":
		cur = steps.size()
	var p := {
		"id": int(c.get("id", order)),
		"table": int(c.get("table", order)),
		"patient_id": patient_id,
		"patient_name": _patient_name(game, c),
		"ailment_id": ailment_id,
		"ailment_name": String(ail.get("name", ailment_id.capitalize())),
		"code": String(ail.get("code", "")),
		"state": state,
		"vitals": vitals,
		"level": "ok" if vitals > LOW else ("low" if vitals > CRITICAL else "critical"),
		"steps": [],
		"current": cur,
		"supplies": [],
		"ready": false,
		"operator": "",
		"progress": 0.0,
	}
	for i in steps.size():
		var s: Dictionary = steps[i]
		p.steps.append({
			"label": String(s.get("label", "")),
			"item": String(s.get("item", "")),
			"item_name": ItemsDB.display_name(String(s.get("item", ""))),
			"state": "done" if i < cur else ("current" if i == cur and state != "dead" else "todo"),
		})
	# Supplies for the steps still to come, against what the shelf can still spare for this case.
	if state == "on_table" or state == "incoming":
		var need := ProceduresDB.remaining_requirements(ailment_id, cur)
		var kinds := []
		for kind in ItemsDB.SURGICAL:
			if need.has(kind):
				kinds.append(kind)
		for kind in need.keys():
			if not kinds.has(kind):
				kinds.append(kind)
		for kind in kinds:
			var n := int(need[kind])
			var on_shelf := _shelf_count(game, kind)
			var free := on_shelf - int(shelf_left.get(kind, 0))
			var have := clampi(free, 0, n)
			# Tools are not used up: every case may count the same forceps.
			if ItemsDB.is_consumable(kind):
				shelf_left[kind] = int(shelf_left.get(kind, 0)) + have
			p.supplies.append({"kind": kind, "name": ItemsDB.display_name(kind), "need": n, "have": have, "ok": have >= n})
		if cur < steps.size():
			var step: Dictionary = steps[cur]
			var item := String(step.get("item", ""))
			var uses := maxi(1, int(step.get("uses", 0)))
			for s in p.supplies:
				if s.kind == item:
					p.ready = int(s.have) >= uses
	_operator_into(game, c, order, p)
	return p


static func _patient_name(game: Object, c: Dictionary) -> String:
	var pid := String(c.get("patient_id", ""))
	if pid == "player":
		var players = game.get("players")
		var who = players.get(int(c.get("player_id", 0))) if players is Dictionary else null
		return String(who.player_name) if who != null and is_instance_valid(who) else "Staff member"
	var pt := ProceduresDB.patient(pid)
	return String(pt.get("full_name", pid.capitalize()))


static func _shelf_count(game: Object, kind: String) -> int:
	if game.has_method("shelf_count"):
		return int(game.shelf_count(kind))
	var shelf = game.get("shelf")
	return int(shelf.get(kind, 0)) if shelf is Dictionary else 0


## Who operates on this case and how far along the step is. Uses a per-table surgery system when
## the game offers one (game.surgery_for_table(t)), else the single game.surgery for the first case.
static func _operator_into(game: Object, c: Dictionary, order: int, p: Dictionary) -> void:
	var sys = null
	if game.has_method("surgery_for_table"):
		sys = game.surgery_for_table(int(c.get("table", order)))
	elif order == 0:
		sys = game.get("surgery")
	if sys == null or not is_instance_valid(sys) or int(sys.get("operator_id") if sys.get("operator_id") != null else 0) == 0:
		return
	var players = game.get("players")
	var op = players.get(int(sys.operator_id)) if players is Dictionary else null
	p.operator = String(op.player_name) if op != null and is_instance_valid(op) else "Someone"
	if sys.has_method("hud_state"):
		var st: Dictionary = sys.hud_state()
		p.progress = clampf(float(st.get("progress", 0.0)), 0.0, 1.0)
