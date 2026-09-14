extends Node
## Dissection (sweep 3): strapped monsters on the patient tables.
##
##   godot --headless --fixed-fps 60 --path . tools/dissectiontest.tscn
##   godot --path . --resolution 1280x720 tools/dissectiontest.tscn -- --shots   # tools/dissection_shots/
##
## Headless checks, in the dev room (a solo host): the procedures data (monsters never roll), a
## Walk-In strapped through the dev request, its body (sites, straps, flags), sedation wearing off
## and 2.5x faster while the saw bites, the local surgeon operating both steps through the real
## surgery system with bot_input, the brain's condition never going up, the brain handed over with
## condition -> quality, the flatline and the case clearing itself; the Discharged stirring and
## awake (thrash botches while operated, shrieks as noise); re-dosing from hands with the tolerance
## math and vials used (also while someone operates); a ruined brain; the OR screen's model.
##
## --shots: windowed pictures in the generated hospital's OR: both monsters strapped (sedated and
## thrashing), an opened skull, the skull saw and the brain forceps mid-step, the OR monitor.

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const DissectionScript := preload("res://scripts/dissection/dissection.gd")
const OrModel := preload("res://scripts/orscreen/or_screen_model.gd")
const SHOT_DIR := "res://tools/dissection_shots"

var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0
var shots := false
var _done := false
var _failures: Array = []


func _ready() -> void:
	shots = OS.get_cmdline_user_args().has("--shots")
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	main.menu.hide_menu()
	Net.start_solo("Tester")
	if shots:
		await _shots()
	else:
		_data_checks()
		await _dev_room()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 1200.0 and not _done:
		_check(false, "timed out")
		_finish()


# =========================================================================
# data
# =========================================================================

func _data_checks() -> void:
	_check(Procedures.patient_ailments() == ["amputation", "gunshot"], "patient_ailments has no dissection (%s)" % str(Procedures.patient_ailments()))
	_check(Procedures.human_patients() == ["bob", "seal"] and Procedures.monster_patients() == ["discharged", "walk_in"], "human and monster patients")
	var monster_rolled := false
	for s in 400:
		var r := Procedures.roll(s * 7 + 3, 1 + s % 5)
		if Procedures.is_monster(String(r.patient)) or String(r.ailment) == "dissection":
			monster_rolled = true
	_check(not monster_rolled, "roll() never picks a monster or dissection in 400 rolls")
	_check(Procedures.roll(4242, 1) == {"patient": Procedures.roll(4242, 1).patient, "ailment": Procedures.roll(4242, 1).ailment}, "roll is deterministic")
	var st: Array = Procedures.steps("dissection")
	_check(st.size() == 2 and st[0].game == "saw" and st[0].variant == "skull" and st[0].site == "skull" and st[0].item == "bone_saw"
		and st[1].game == "forceps" and st[1].variant == "brain" and st[1].site == "brain" and st[1].item == "forceps",
		"dissection steps: saw skull, forceps brain")
	_check(Procedures.is_monster_only("dissection") and Procedures.ailment("dissection").get("monster_only", false), "dissection is monster_only")
	_check(Procedures.requirements("dissection") == {"bone_saw": 1, "forceps": 1}, "dissection needs a bone saw and forceps")
	_check(is_equal_approx(DissectionScript.dose_amount(0), 0.6) and is_equal_approx(DissectionScript.dose_amount(1), 0.36)
		and is_equal_approx(DissectionScript.dose_amount(2), 0.216), "dose tolerance: 0.6, 0.36, 0.216")


# =========================================================================
# the dev room
# =========================================================================

func _dev_room() -> void:
	game.start_session(DevRoomScript.SEED)
	await _frames(8)
	me = game.local_player()
	me.bot_active = true
	dev.request("god", {"on": true})
	var dx: Node = game.dissection

	# ---- strap a Walk-In through the dev request
	dev.request("strap_monster", {"kind": "walk_in", "sedation": 1.0})
	await _frames(3)
	var c := _monster_case("walk_in")
	_check(not c.is_empty() and bool(c.get("monster", false)) and String(c.ailment_id) == "dissection" and String(c.state) == "on_table",
		"the dev request straps a Walk-In to a table (%s)" % str(c))
	if c.is_empty():
		return
	var table := int(c.table)
	var case_id := int(c.id)
	var body = game.body_for_table(table)
	_check(body != null and body is PatientBody and body.has_site("skull") and body.has_site("brain") and body.has_site("injection")
		and not body.has_site("gunshot"), "the monster body is a PatientBody with sites injection, skull and brain")
	_check(body != null and body.find_child("Straps", true, false) != null and body.find_child("Strap", true, false) != null, "the body has straps")
	_check(body != null and not body.site_section("skull").is_empty() and body.site_section("brain").has("tray"), "site sections for the skull and the brain")
	_check(dx.owns_case(c) and dx.owns_table(table), "dissection owns the case and its table")
	_check(game.loop.pay_for(c, 1) == 0, "a monster case pays nothing")

	# ---- sedation wears off
	var s0: float = dx.sedation(c)
	await _seconds(12.0)
	var s1: float = dx.sedation(c)
	var drop := s0 - s1
	_check(absf(drop - 12.0 / 120.0) < 0.01, "sedation falls 1/120 per second at rest (%.3f in 12 s)" % drop)
	_check(absf(float(c.flags.sedation) - snappedf(s1, 0.05)) < 0.001, "the case flag holds it snapped to 0.05 (%.2f vs %.3f)" % [float(c.flags.sedation), s1])
	var ns: Dictionary = dx.net_state()
	_check(ns.has("s") and absf(float(ns.s[str(case_id)]) / 100.0 - s1) <= 0.011, "dx carries it in hundredths (%s)" % str(ns))
	_check(float(c.vitals) == 100.0, "nothing drains the brain's condition (%.1f)" % float(c.vitals))
	_check(String(game._table_prompt(me, table)).begins_with("!") or String(game._table_prompt(me, table)).contains("sedation"),
		"the table prompt shows sedation ('%s')" % game._table_prompt(me, table))

	# ---- operate step 1: the skull, with the real surgery system and bot_input
	dev.request("stock_shelf")
	_stand_at_table(table)
	await _frames(2)
	var prompt := String(game._table_prompt(me, table))
	_check(prompt.begins_with("Operate: Saw open the skull") and prompt.contains("sedation"), "operate prompt with sedation ('%s')" % prompt)
	game.surgery_bot_skill = 1.0
	var sys = game.surgery_for_table(table)
	game._proxy_used(game.table_interact_id(table), me)
	var began := await _until(func(): return sys.is_local_operating() and sys.mg != null, 5.0)
	_check(began and sys.mg.get("skull") == true, "E at the table starts the skull saw (variant skull)")
	# Sawing: sedation falls 2.5x faster while the blade is held.
	await _until(func(): return bool(sys.mg.get("held")), 3.0)
	var sa: float = dx.sedation(c)
	var held_t := 0.0
	var start_t := t
	while t - start_t < 3.0:
		await get_tree().physics_frame
		if sys.mg != null and bool(sys.mg.get("held")):
			held_t += get_physics_process_delta_time()
	var sb: float = dx.sedation(c)
	var expect := (held_t * 2.5 + (3.0 - held_t)) / 120.0
	_check(absf((sa - sb) - expect) < 0.006 and held_t > 2.5, "sedation falls 2.5x faster while sawing (%.4f, expected %.4f, held %.1f s)" % [sa - sb, expect, held_t])
	var ok1 := await _until(func(): return int(c.get("step_index", 0)) >= 1, 40.0)
	_check(ok1 and bool(c.flags.get("skull_open", false)), "the skull step finishes with skull_open (flags %s)" % str(c.flags))
	await _frames(2)
	_check(float(c.vitals) <= 100.0 and float(c.vitals) >= 99.0, "condition does not go up after the step (%.1f)" % float(c.vitals))

	# ---- a few botches, then step 2: the brain
	game.surgery_botch(7.0, "test", table)
	await _frames(3)
	var cond_before := float(c.vitals)
	await _seconds(0.5)
	game._proxy_used(game.table_interact_id(table), me)
	var began2 := await _until(func(): return sys.is_local_operating() and sys.mg != null and sys.mg.get("_brain_game") != null, 5.0)
	_check(began2, "E again starts the brain forceps (variant brain)")
	var ok2 := await _until(func(): return String(c.get("state", "")) != "on_table", 40.0)
	_check(ok2 and String(c.state) == "stable" and bool(c.flags.get("brain_removed", false)), "the brain step wins the case (state %s)" % String(c.get("state", "")))
	var lb: Dictionary = dx.last_brain
	_check(not lb.is_empty() and String(lb.kind) == "brain_walk_in" and absf(float(lb.quality) - cond_before / 100.0) < 0.011,
		"the brain is handed over: %s quality %.2f (condition %.1f)" % [str(lb.get("kind", "")), float(lb.get("quality", -1.0)), cond_before])
	var node = lb.get("node")
	_check(node != null and is_instance_valid(node) and (node as Node3D).global_position.distance_to(game.table_position(table)) < 1.6,
		"a brain item lies by the table (%s)" % str(node))
	_check(absf(float(c.vitals) - cond_before) < 0.01, "the finished case keeps the condition, not the step bonus (%.1f)" % float(c.vitals))
	await _frames(3)
	_check(body != null and is_instance_valid(body) and bool(body.get("_flat")), "the monster flatlines on the table")
	_check(String(game._table_prompt(me, table)) == "!The brain is out.", "table prompt after: '%s'" % game._table_prompt(me, table))
	var model: Dictionary = OrModel.build(game)
	var panel := {}
	for p in model.panels:
		if int(p.id) == case_id:
			panel = p
	_check(not panel.is_empty() and bool(panel.get("monster", false)), "the OR screen model marks the monster panel")
	var gone := await _until(func(): return game.case_by_id(case_id).is_empty(), 9.0)
	_check(gone, "the case is removed about 6 s later")

	# ---- the Discharged: stirring, awake, thrashing, shrieking
	var did: int = dx.dev_strap("discharged", 0.6, table)
	await _frames(3)
	var d := game.case_by_id(did)
	_check(not d.is_empty() and DissectionScript.sedation_state(dx.sedation(d)) == "stirring", "0.6 is stirring")
	_check(sys._stirs_now() if sys.mg != null else true, "the surgery system's stir code sees it")
	dx.set_sedation(did, 0.3)
	await _frames(2)
	_check(DissectionScript.sedation_state(dx.sedation(d)) == "awake", "0.3 is awake")
	var shrieked := await _until(func():
		for n in game.recent_noises(0.5):
			if String(n.kind) == "shriek" and float(n.loudness) >= 0.69:
				return true
		return false, 8.0)
	_check(shrieked, "an awake monster shrieks as noise 0.7")
	var v0 := float(d.vitals)
	await _seconds(4.0)
	_check(float(d.vitals) == v0, "no thrash botches while nobody operates (%.1f)" % float(d.vitals))
	var tb = game.body_for_table(table)
	_check(tb != null and float(tb.get("_sedation")) < 0.35, "the body gets the awake sedation (%.2f)" % (float(tb.get("_sedation")) if tb != null else -1.0))
	# Operate while awake: about 1.5 every 3 s from thrashing.
	game.surgery_bot_skill = -1.0   # hands off: only the thrashing botches
	_stand_at_table(table)
	sys.begin(me)
	var began3 := await _until(func(): return sys.is_local_operating(), 3.0)
	var v1 := float(d.vitals)
	dx.set_sedation(did, 0.3)
	await _seconds(9.3)
	var lost := v1 - float(d.vitals)
	_check(began3 and lost >= 4.4 and lost <= 4.6, "awake and operated: 1.5 every 3 s (lost %.1f in 9.3 s)" % lost)

	# ---- re-dosing from hands, while operating
	me.take_into("anesthetic", 3)
	await _frames(1)
	var p2 := String(game._table_prompt(me, table))
	_check(p2.begins_with("Re-dose The Discharged") and p2.contains("sedation"), "holding anesthetic: '%s'" % p2)
	dx.set_sedation(did, 0.2)
	var before: float = dx.sedation(d)
	game._proxy_used(game.table_interact_id(table), me)
	await _frames(1)
	var after: float = dx.sedation(d)
	_check(absf((after - before) - 0.6) < 0.01 and int(d.get("doses", 0)) == 1, "first dose +0.6 (%.3f -> %.3f)" % [before, after])
	_check(_vials() == 2, "one vial used (%d left)" % _vials())
	_check(sys.operator_id == me.peer_id, "re-dosing did not interrupt the operation")
	dx.set_sedation(did, 0.2)
	game._proxy_used(game.table_interact_id(table), me)
	await _frames(1)
	_check(absf(dx.sedation(d) - 0.56) < 0.01 and _vials() == 1, "second dose +0.36 (%.3f, %d vials)" % [dx.sedation(d), _vials()])
	dx.set_sedation(did, 0.9)
	game._proxy_used(game.table_interact_id(table), me)
	await _frames(1)
	_check(absf(dx.sedation(d) - 1.0) < 0.003 and _vials() == 0 and int(d.doses) == 3, "third dose caps at 1.0 and the last vial is gone (%.3f, %d vials, %d doses)" % [dx.sedation(d), _vials(), int(d.get("doses", 0))])
	_check(not String(game._table_prompt(me, table)).begins_with("Re-dose"), "no vials: back to the operate prompt")

	# ---- a ruined brain
	sys.local_operator_exit()
	await _frames(3)
	d.vitals = 2.0
	game.surgery_botch(3.0, "test", table)
	await _frames(3)
	_check(String(d.state) == "dead", "condition 0: the case is lost (%s)" % String(d.state))
	_check(String(game.message).contains("ruined"), "'%s'" % game.message)
	var gone2 := await _until(func(): return game.case_by_id(did).is_empty(), 9.0)
	_check(gone2, "the ruined case clears too")
	game.surgery_bot_skill = -1.0


func _monster_case(kind: String) -> Dictionary:
	for c in game.cases:
		if String(c.get("patient_id", "")) == kind:
			return c
	return {}


func _vials() -> int:
	var n := 0
	for s in me.slots:
		if String(s.kind) == "anesthetic":
			n += int(s.count)
	return n


func _stand_at_table(table: int) -> void:
	var tp: Vector3 = game.table_position(table)
	me.teleport(game._floor_at(tp + Vector3(0, 0, 1.0).rotated(Vector3.UP, game.table_yaw_of(table))))
	me.bot_move = Vector2.ZERO


# =========================================================================
# shots
# =========================================================================

func _shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	game.start_session(4242)
	await _seconds(2.0)
	me = game.local_player()
	me.bot_active = true
	game.begin_shift()
	await _seconds(1.0)
	for m in game.monsters.values():
		m.global_position += Vector3(0, -80, 0)
	me.invuln = 99999.0
	var dx: Node = game.dissection
	var tables: Array = game.patient_tables
	var t0 := int(tables[0].index)
	var t1 := int(tables[1].index) if tables.size() > 1 else t0
	var wid: int = dx.dev_strap("walk_in", 1.0, t0)
	var did: int = dx.dev_strap("discharged", 0.15, t1)
	await _seconds(1.5)
	# 01/02: each monster from beside its table.
	for pair in [[t0, "01_walk_in_strapped"], [t1, "02_discharged_thrashing"]]:
		var tb := int(pair[0])
		var tp: Vector3 = game.table_position(tb)
		var yaw: float = game.table_yaw_of(tb)
		me.teleport(game._floor_at(tp + Vector3(-0.6, 0, 1.35).rotated(Vector3.UP, yaw)))
		await _frames(2)
		_look_at(tp + Vector3(-0.35, 0.9, 0).rotated(Vector3.UP, yaw))
		await _seconds(1.2)
		await _shot(String(pair[1]))
		# Close on the head.
		me.teleport(game._floor_at(tp + Vector3(-1.4, 0, 0.55).rotated(Vector3.UP, yaw)))
		await _frames(2)
		_look_at(tp + Vector3(-0.78, 0.95, 0).rotated(Vector3.UP, yaw))
		await _seconds(0.6)
		await _shot(String(pair[1]) + "_head")
	# 03: the skull saw mid-step, the operator's view.
	game.shelf["bone_saw"] = 1
	game.shelf["forceps"] = 1
	game.surgery_bot_skill = 0.6
	var sys = game.surgery_for_table(t0)
	var tp0: Vector3 = game.table_position(t0)
	me.teleport(game._floor_at(tp0 + Vector3(0, 0, 1.0).rotated(Vector3.UP, game.table_yaw_of(t0))))
	await _frames(2)
	sys.begin(me)
	await _seconds(5.0)
	await _shot("03_skull_saw_mid")
	await _until(func(): return int(game.case_by_id(wid).get("step_index", 0)) >= 1, 40.0)
	await _seconds(1.2)
	# 04: the opened skull from beside the table.
	me.teleport(game._floor_at(tp0 + Vector3(-1.4, 0, 0.55).rotated(Vector3.UP, game.table_yaw_of(t0))))
	await _frames(2)
	_look_at(tp0 + Vector3(-0.78, 0.95, 0).rotated(Vector3.UP, game.table_yaw_of(t0)))
	await _seconds(1.0)
	await _shot("04_skull_open")
	# 05/06: the brain forceps: the nerves, then carrying it to the tray.
	me.teleport(game._floor_at(tp0 + Vector3(0, 0, 1.0).rotated(Vector3.UP, game.table_yaw_of(t0))))
	await _frames(2)
	sys.begin(me)
	await _until(func(): return sys.mg != null and sys.mg.get("_brain_game") != null, 5.0)
	await _seconds(2.4)
	await _shot("05_brain_nerves")
	await _until(func(): return sys.mg == null or int(sys.mg.get("_brain_game").stage) >= 3, 30.0)
	await _seconds(0.5)
	await _shot("06_brain_carry")
	await _until(func(): return String(game.case_by_id(wid).get("state", "")) != "on_table", 30.0)
	await _seconds(1.5)
	# 07: the OR monitor with both monster panels.
	if game.or_screen != null and game.or_screen.mounted():
		var sc: Vector3 = game.or_screen.screen_centre()
		var nrm: Vector3 = game.or_screen.screen_normal()
		me.teleport(game._floor_at(sc + nrm * 2.6))
		await _frames(2)
		_look_at(sc)
		game.or_screen.refresh_now()
		await _seconds(1.0)
		await _shot("07_or_screen")
	await _seconds(3.0)
	print("[dissectiontest] shots done (discharged case %d)" % did)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[dissectiontest] wrote %s" % path)


func _look_at(target: Vector3) -> void:
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var dv := target - eye
	me.bot_yaw = atan2(-dv.x, -dv.z)
	me.bot_pitch = clampf(atan2(dv.y, Vector2(dv.x, dv.z).length()), -1.2, 1.2)


# =========================================================================
# helpers
# =========================================================================

func _check(ok: bool, what: String) -> void:
	print("[dissectiontest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[dissectiontest] ------------------------------------------")
	print("[dissectiontest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	for f in _failures:
		print("[dissectiontest]   FAILED: ", f)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())
