extends Node
## GRAFTING chunk C smoke-look screenshots, into tools/graft_shots/. Run minimized (RULES.md
## "Reviews"): the shots come from the viewport, so nothing ever takes focus.
##
##   tools\review.bat 2 "SMOKE" -Scene res://tools/graftsurgeryshot.tscn
##
## The whole loop once, solo: the stand with a vat beside an OR table, you strapped down looking up
## at Dr. Botsworth working on your eye, the swapped eye in third person and in the Personnel
## mirror, its glow while Hive Eyes runs, and the orange down the left edge of your own view.

const SHOT_DIR := "res://tools/graft_shots"
var main: Node3D
var game: Game
var dev: Node
var me: Player
var bw: Player
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
	var ti: int = game.free_patient_table()
	var si: int = vats.stand_of_table(ti)
	var yaw: float = game.table_yaw_of(ti)
	var tb := Basis(Vector3.UP, yaw)
	var tp: Vector3 = game.table_position(ti)
	# ---- 50: the stand beside the table, with a vat on it
	var stand_at: Vector3 = vats.stands[si].position
	var vat: Node = game._spawn_item("specimen_vat", 1, Transform3D(tb, stand_at), WorldItem.State.LOOSE)
	vat.x = Eyes.pack("eye_hive", "", 0.0, 120)
	me.flashlight_on = true
	await _seconds(1.0)
	_stand(stand_at + tb * Vector3(0.0, 0.0, 1.3))
	_look_at(stand_at + Vector3(0, 0.1, 0))
	await _seconds(1.0)
	await _shot("50_stand_with_vat")
	_stand(tp + tb * Vector3(2.2, 0.0, 1.8))
	_look_at(tp + Vector3(0, 1.0, 0))
	await _seconds(1.0)
	await _shot("51_table_and_stand")

	# ---- strapped down, Dr. Botsworth operating
	me.teleport(game._floor_at(tp + tb * Vector3(0, 0, 1.2)))
	await _seconds(0.4)
	game.strap_in(me, ti)
	await _seconds(0.8)
	print("[graftshot] strapped=", me.strapped(), " table=", game.player_table.get("index", -1))
	dev.control_botsworth()
	await _seconds(0.8)
	bw = dev.possessed_player()
	if bw == null:
		print("[graftshot] no Botsworth")
		return
	bw.bot_active = true
	bw.teleport(game._floor_at(tp + tb * Vector3(-0.3, 0.0, 1.0)))
	bw.bot_move = Vector2.ZERO
	await _seconds(0.5)
	var ps: Node = game.player_surgery
	var sys: Node = ps.surgery
	sys.bot_skill = 1.0
	var n := 52
	for step in [["scalpel", "cut"], ["eye_spoon", "scoop"], ["eye_spoon", "seat"], ["suture_kit", "stitch"]]:
		for i in bw.slots.size():
			bw.slots[i] = Player.empty_slot()
		game.give_hand(bw, String(step[0]), 1)
		bw.selected = _slot(bw, String(step[0]))
		await _seconds(0.4)
		game._proxy_used(game.table_interact_id(ti), bw)
		var ok := await _until(func(): return sys.mg != null and String(sys.mg.get("variant")) == String(step[1]), 10.0)
		print("[graftshot] step %s began=%s" % [String(step[1]), str(ok)])
		await _seconds(2.0)
		await _shot("%d_%s_operating" % [n, String(step[1])])
		n += 1
		# What the patient sees: their own camera, looking up, while the step plays.
		var cam: Camera3D = me.camera
		var was: Camera3D = get_viewport().get_camera_3d()
		cam.make_current()
		await _seconds(0.6)
		await _shot("%d_%s_patient_view" % [n, String(step[1])])
		n += 1
		if was != null:
			was.make_current()
		var want := String(step[1])
		await _until(func(): return ps.case.is_empty() or String(sys.mg.get("variant")) != want or bool(sys.mg.get("done")), 90.0)
		await _seconds(0.6)
	await _until(func(): return game.grafts.graft_of(me.peer_id) == "eye_hive", 20.0)
	print("[graftshot] graft=", game.grafts.graft_of(me.peer_id), " vat=", String(vat.x),
		" slot=", game.brains.slot_of(me.peer_id, "hive_in"))

	# ---- back on your feet, and what everyone sees
	game.get_up_from_table(me)
	dev.control_botsworth()   # back into your own body
	await _seconds(1.0)
	me.bot_active = true
	_stand(tp + tb * Vector3(0.0, 0.0, 2.0))
	me.bot_yaw = yaw + PI * 0.5
	await _seconds(6.0)   # let the new-ability card close itself
	print("[graftshot] lock=", game.grafts.local_lock(), " driving=", game.driving_player())
	await _shot("60_first_person_tint")
	print("[graftshot] tint drawn: ", main.graft_view.wash.showing)
	await _hive_eyes(1.5)
	print("[graftshot] lock hot=", game.grafts.local_lock(), " tint drawn: ", main.graft_view.wash.showing)
	await _shot("63_first_person_tint_hive_eyes")
	_hive_hold = false

	# ---- the Personnel mirror
	var pr: Dictionary = game.level_info.get("personnel", {})
	var mirror: Dictionary = pr.get("mirror", {})
	if mirror.is_empty():
		print("[graftshot] no personnel mirror on this level")
		return
	var mp: Vector3 = mirror.position
	var myaw := float(mirror.get("yaw", 0.0))
	var out := Basis(Vector3.UP, myaw) * Vector3(0, 0, -1)
	_stand(mp + out * 0.75)
	_look_at(mp + Vector3(0, 1.62, 0))
	await _seconds(2.0)
	await _shot("64_mirror")
	me.apply_fov(24.0)   # a close look at your own face in the glass
	await _seconds(1.0)
	await _shot("65_mirror_close")
	await _hive_eyes(1.5)
	await _shot("66_mirror_close_glow")
	_hive_hold = false
	me.apply_fov(75.0)


## Hive Eyes for the look only: the host clears `hive_view` whenever its own rules say so, so hold
## it on for a moment instead of setting it once.
var _hive_hold := false


func _hive_eyes(seconds: float) -> void:
	_hive_hold = true
	var end := t + seconds
	while t < end:
		me.hive_view = true
		await get_tree().physics_frame
	me.hive_view = true


func _process(_d: float) -> void:
	if _hive_hold and me != null:
		me.hive_view = true
	elif me != null and me.hive_view and not _hive_hold:
		me.hive_view = false


func _slot(p, kind: String) -> int:
	for i in p.slots.size():
		if String(p.slots[i].kind) == kind:
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
