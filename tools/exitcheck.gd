extends Node
## Headless check of patient exits (scripts/loop/corpses.gd, scripts/loop/walkers.gd): a patient dies
## on a table and holds up the clock-out; lifting the body frees the table; it can be put down and
## lifted again; at the furnace window it goes into the fire and the clock-out is free. A saved
## patient gets up, frees the table, thanks someone and walks out through the main doors.
##
##   godot --headless --fixed-fps 60 --path . tools/exitcheck.tscn

var main: Node3D
var game: Game
var me: Player
var _fails := 0


func _ready() -> void:
	get_tree().create_timer(600.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Exit")
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(10)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	game.clock_in()
	await _frames(30)
	game.loop.first_called = true
	game.loop._end_call()
	for m in game.monsters.values():
		game.kill_monster(m)
	await _dead_patient()
	await _saved_patient()
	print("[exitcheck] result=%s failures=%d" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _dead_patient() -> void:
	var t := int(game.patient_tables[0].index)
	var id: int = game.add_case({"patient_id": "bob", "ailment_id": "gunshot", "table": t, "state": "on_table"})
	await _frames(2)
	game.finish_case(id, false)
	await _frames(2)
	var blocker: String = game.loop._clock_out_blocker()
	_check(blocker.contains("body"), "a body holds up the clock-out ('%s')" % blocker)
	_check(game.case_on_table(t).get("id", -1) == id, "the body stays on its table")
	var aim: String = game.table_interact_id(t)
	_check(not game.corpses.aimed_body(aim).is_empty(), "aiming at the table finds the body")
	_check(game._table_prompt(me, t).begins_with("Hold E: lift"), "the table offers to lift it ('%s')" % game._table_prompt(me, t))
	game.corpses.lift(me, id)
	await _frames(2)
	_check(game.corpses.is_body(me.carrying), "lifting it: the player carries the body")
	_check(game.case_on_table(t).is_empty() and game.free_patient_table() >= 0, "lifting it frees the table")
	game.drop_carried(me)
	await _frames(3)
	var c: Dictionary = game.case_by_id(id)
	_check(me.carrying == 0 and c.has("bp"), "put down: it lies on the floor at %s" % str(c.get("bp")))
	_check(not game.corpses.aimed_body("corpse_%d" % id).is_empty(), "the floor body can be aimed at")
	game.corpses.lift(me, id)
	var furn: Node3D = game.economy.furnace
	me.teleport(furn.global_position + furn.global_basis.z * 1.2)
	await _frames(3)
	game.corpses.cremate(me)
	await _frames(5)
	c = game.case_by_id(id)
	_check(bool(c.get("cremated", false)) and me.carrying == 0, "at the furnace it goes into the fire")
	_check(game.loop._clock_out_blocker() == "", "with the body burned the clock-out is free ('%s')" % game.loop._clock_out_blocker())
	await _seconds(2.0)
	game.remove_case(id)


func _saved_patient() -> void:
	var t := int(game.patient_tables[1].index)
	me.teleport(game.table_position(t) + Vector3(0, 0, 2.0))
	var id: int = game.add_case({"patient_id": "seal", "ailment_id": "gunshot", "table": t, "state": "on_table"})
	await _frames(2)
	game.finish_case(id, true)
	await _seconds(3.2)
	var w: Dictionary = game.loop.walkers.walkers.get(id, {})
	_check(not w.is_empty(), "a couple of seconds after it is stable the patient gets up")
	_check(game.case_on_table(t).is_empty(), "getting up frees the table")
	_check(String(game.message).begins_with("THE SEAL:"), "and thanks someone ('%s')" % game.message)
	var start: Vector3 = w.get("p", Vector3.ZERO)
	await _seconds(8.0)
	w = game.loop.walkers.walkers.get(id, {})
	_check(not w.is_empty() and String(w.ph) == "walk" and (w.p as Vector3).distance_to(start) > 2.0,
			"then walks off toward the doors (%.1f m)" % ((w.get("p", start) as Vector3).distance_to(start)))
	_check(game.loop._clock_out_blocker() == "", "a patient walking out never holds up the clock-out")


func _check(ok: bool, what: String) -> void:
	print("[exitcheck] %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await _frames(int(s * 60.0))
