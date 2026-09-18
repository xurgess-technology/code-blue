extends Node
## Smoke-look screenshots for grafting part one, into tools/graft_shots/ (gitignored via *_shots? no: delete after).
## Run minimized (see RULES.md "Reviews"): the shots come from the viewport, no focus needed.

const SHOT_DIR := "res://tools/graft_shots"
var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	main.menu.hide_menu()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	Net.start_solo("Zach")
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(1.0)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	dev.request("monsters_off", {"on": true})
	dev.request("no_game_over", {"on": true})
	dev.request("god", {"on": true})
	game.clock_in()
	await _until(func(): return game.phase == Game.Phase.SHIFT, 90.0)
	game.loop._end_call()
	game.loop.first_called = true
	game.loop.extra_done = true
	dev.request("clear_patient")
	await _run()
	get_tree().quit(0)


func _physics_process(delta: float) -> void:
	t += delta


func _run() -> void:
	var vats: Node = game.vats
	var sp: Dictionary = vats.spots[1]
	var front := Basis(Vector3.UP, float(sp.yaw)) * Vector3(0, 0, -1)
	var items := []
	for it in game.world_items.values():
		if String(it.kind) == "specimen_vat":
			items.append(it)
	items[0].x = Eyes.pack("eye_hive", "", 5.0, 50)
	items[1].x = Eyes.pack("eye_surgeon", "Zach", 5.0, 50)
	await _seconds(0.5)
	for i in 2:
		var at: Vector3 = items[i].global_position
		_stand(at + front * 0.55)
		me.flashlight_on = true
		_look_at(at + Vector3(0, 0.12, 0))
		await _seconds(1.0)
		await _shot("02_vat_%d" % i)
	# a spoiled eye out in the open
	var eye = game._spawn_item("eye_surgeon", 1, Transform3D(Basis(), items[2].global_position + front * 0.0 + Vector3(0.25, 0.02, 0)), WorldItem.State.LOOSE)
	eye.x = "Zach"
	eye.bt = float(game.world_time) - 200.0
	game.world_time += 0.0
	var eye2 = game._spawn_item("eye_hive", 1, Transform3D(Basis(), items[2].global_position + Vector3(0.45, 0.02, 0)), WorldItem.State.LOOSE)
	eye2.bt = float(game.world_time)
	await _seconds(1.0)
	_look_at(items[2].global_position + Vector3(0.35, 0.0, 0))
	await _seconds(1.0)
	await _shot("03_loose_eyes")
	game.give_hand(me, "scalpel", 1)
	me.bot_pitch = -0.5
	await _seconds(0.6)
	await _shot("04_scalpel_hand")
	for i in me.slots.size():
		me.slots[i] = Player.empty_slot()
	game.give_hand(me, "eye_spoon", 1)
	await _seconds(0.6)
	await _shot("05_spoon_hand")
	for i in me.slots.size():
		me.slots[i] = Player.empty_slot()
	dev.request("strap_monster", {"kind": "hive", "sedation": 1.0})
	await _seconds(1.0)
	var c := {}
	for cc in game.cases:
		if String(cc.get("patient_id", "")) == "hive":
			c = cc
	var table := int(c.table)
	var pt: Vector3 = game.table_position(table)
	var tb := Basis(Vector3.UP, game.table_yaw_of(table))
	var body = game.body_for_table(table)
	var eye_at: Vector3 = body.site_transform("eye").origin
	print("[graftshot] eye site ", eye_at, " table ", pt)
	_stand(pt + tb * Vector3(0, 0, 1.0))
	_look_at(eye_at)
	await _seconds(0.8)
	await _shot("06_eye_site_from_side")
	_stand(pt + tb * Vector3(0, 0, -0.95))
	_look_at(pt + tb * Vector3(0, 1.85, -1.5))
	await _seconds(0.8)
	await _shot("07_wall_monitor")
	_stand(pt + tb * Vector3(0, 0, 1.0))
	_look_at(eye_at)
	var sys = game.surgery_for_table(table)
	var n := 8
	for step in ["scalpel", "eye_spoon", "scalpel"]:
		game.give_hand(me, step, 1)
		me.selected = _slot(step)
		game.surgery_bot_skill = 1.0
		game._proxy_used(game.table_interact_id(table), me)
		await _until(func(): return sys.mg != null and sys.mg.get("variant") != null and sys.is_local_operating(), 8.0)
		print("[graftshot] mg=", sys.mg, " ailment=", c.get("ailment_id"), " step=", c.get("step_index"), " held=", me.selected_stack())
		var variant := String(sys.mg.get("variant")) if sys.mg != null else "none"
		if variant == "cut":
			game.surgery_bot_skill = 0.0   # a heavy hand: it slips out
			await _until(func(): return int(sys.mg.get("slips")) > 0, 20.0)
			await _seconds(0.15)
			await _shot("%02d_cut_slip" % n)
			n += 1
			game.surgery_bot_skill = 1.0
			var mgc = sys.mg
			await _until(func(): return is_instance_valid(mgc) and float(mgc.get("cut")) > 2.6, 20.0)
		elif variant == "scoop":
			await _seconds(1.8)
		else:
			await _seconds(1.5)
		await _shot("%02d_%s_midway" % [n, variant])
		n += 1
		var idx: int = int(c.get("step_index", 0)) + 1
		await _until(func(): return int(c.get("step_index", 0)) >= idx or String(c.state) != "on_table", 60.0)
		await _seconds(1.0)


func _slot(kind: String) -> int:
	for i in me.slots.size():
		if String(me.slots[i].kind) == kind:
			return i
	return 0


func _stand(pos: Vector3) -> void:
	me.teleport(game._floor_at(pos))
	me.bot_move = Vector2.ZERO


func _look_at(target: Vector3) -> void:
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var d := target - eye
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [SHOT_DIR, name]))
	print("[graftshot] wrote ", name)


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
