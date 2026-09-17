extends Node
## Windowed screenshots of patient exits: carrying a body over the shoulder, a body on the floor, the
## body sliding into the furnace, Bob thanking and walking out, the seal flopping out.
##
##   godot --path . tools/exitshot.tscn
##
## Writes tools/game_shots/exit_<n>_<name>.png.

const OUT_DIR := "res://tools/game_shots"

var main: Node3D
var game: Game
var me: Player


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(300.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(0.5)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	main.tips.reset_seen()
	game.clock_in()
	await _seconds(0.5)
	game.loop.first_called = true
	game.loop._end_call()
	for m in game.monsters.values():
		game.kill_monster(m)

	# A body over the shoulder, from the carrier's own view (the shoulder camera).
	var t := int(game.patient_tables[0].index)
	var id: int = game.add_case({"patient_id": "bob", "ailment_id": "gunshot", "table": t, "state": "on_table"})
	await _seconds(0.2)
	game.finish_case(id, false)
	await _seconds(0.5)
	_look(game.table_position(t) + Vector3(0, 0, 2.4), game.table_position(t) + Vector3.UP * 0.9)
	await _seconds(2.0)
	await _shot("1_body_on_table_tip")
	game.corpses.lift(me, id)
	await _seconds(1.0)
	await _shot("2_carrying")
	game.drop_carried(me)
	await _seconds(0.5)
	var c: Dictionary = game.case_by_id(id)
	var bp: Vector3 = c.get("bp", me.global_position)
	_look(bp + Vector3(1.6, 0, 1.6), bp + Vector3.UP * 0.2)
	await _seconds(0.6)
	await _shot("3_on_the_floor")
	game.corpses.lift(me, id)
	var furn: Node3D = game.economy.furnace
	var stand: Vector3 = furn.global_position + furn.global_basis.z * 2.2 + furn.global_basis.x * 1.2
	_look(stand, furn.global_position + Vector3.UP * 1.2)
	await _seconds(0.8)
	await _shot("4_at_the_furnace")
	game.corpses.cremate(me)
	await _seconds(0.55)
	await _shot("5_into_the_fire")
	await _seconds(0.5)
	await _shot("6_flare")
	await _seconds(1.0)
	game.remove_case(id)

	# Bob pulls through.
	var t2 := int(game.patient_tables[1].index)
	var id2: int = game.add_case({"patient_id": "bob", "ailment_id": "amputation", "table": t2, "state": "on_table"})
	await _seconds(0.2)
	_look(game.table_position(t2) + Vector3(0.5, 0, 3.2), game.table_position(t2) + Vector3.UP * 1.0)
	game.finish_case(id2, true)
	await _seconds(3.4)
	await _shot("7_bob_thanks")
	await _seconds(4.0)
	var w: Dictionary = game.loop.walkers.walkers.get(id2, {})
	if not w.is_empty():
		_look((w.p as Vector3) + Vector3(2.5, 0, 2.5), (w.p as Vector3) + Vector3.UP * 1.0)
	await _seconds(0.3)
	await _shot("8_bob_walking")

	var id3: int = game.add_case({"patient_id": "seal", "ailment_id": "gunshot", "table": t, "state": "on_table"})
	await _seconds(0.2)
	game.finish_case(id3, true)
	await _seconds(7.0)
	var w3: Dictionary = game.loop.walkers.walkers.get(id3, {})
	if not w3.is_empty():
		_look((w3.p as Vector3) + Vector3(2.2, 0, 2.2), (w3.p as Vector3) + Vector3.UP * 0.3)
	await _seconds(0.3)
	await _shot("9_seal_flopping")
	main.tips.reset_seen()
	get_tree().quit(0)


func _look(pos: Vector3, at: Vector3) -> void:
	me.teleport(game._floor_at(pos))
	var d := at - (me.global_position + Vector3.UP * C.EYE_H)
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/exit_%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[exitshot] wrote ", path)
