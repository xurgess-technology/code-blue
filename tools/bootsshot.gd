extends Node
## ROCKET BOOTS: windowed screenshots of a pair on a surgeon (a dev bot, standing, then posed flat
## out with the flame lit), the pair on the floor, and the first-person view mid-flight with the
## fuel bar.
##
##   godot --path . --resolution 1280x720 tools/bootsshot.tscn
##
## Writes tools/boots_shots/<name>.png.

const OUT_DIR := "res://tools/boots_shots"

var main: Node3D
var game: Game
var me: Player


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_run.call_deferred()


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(4242)
	await _frames(2)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await _frames(20)

	# The hub's spine, as tools/controlstest.gd runs its dives.
	var er: Rect2 = game.level_info.get("entrance_rect", Rect2())
	var spot: Vector3 = me.global_position
	if er.size != Vector2.ZERO:
		var t := er.position + Vector2(16.5, 14.5) * C.TILE
		spot = game._floor_at(Vector3(t.x, 0.0, t.y))

	# The pair on the floor.
	var it: Node3D = game._spawn_item("rocket_boots", 1, Transform3D(Basis(), spot + Vector3(0, 0.05, 0)), WorldItem.State.LOOSE)
	await _frames(30)
	_look_from(spot + Vector3(0.9, 0.0, 0.9), it.global_position)
	await _frames(20)
	await _shot("floor")
	game.pickup_item(me, it)

	# A surgeon wearing them, side on to the camera.
	var id: int = game.dev.spawn_bot("bot", me)
	game.dev.brains.erase(id)   # a surgeon body that stands still
	var d: Player = game.players[id]
	d.bot_move = Vector2.ZERO
	d.teleport(spot)
	d.bot_yaw = PI * 0.5
	game.give_hand(d, "rocket_boots", 1)
	await _frames(20)
	_look_from(spot + Vector3(0.0, 0.0, 2.6), d.global_position + Vector3(0, 0.6, 0))
	await _frames(30)
	await _shot("standing")
	_look_from(spot + Vector3(0.6, 0.0, 1.2), d.global_position + Vector3(0, 0.1, 0))
	await _frames(20)
	await _shot("feet")

	# Flat out, burning (the replicated bits a remote copy would have).
	d._remote_dive_air = true
	d._remote_rocket = true
	d.global_position = spot + Vector3.UP * 0.45
	if d._rocket_fx != null:
		d._rocket_fx._heading = -d.global_basis.z
		d._rocket_fx._last_pos = Vector3.INF
	_look_from(spot + Vector3(0.0, 0.0, 2.8), d.global_position + Vector3(0, 0.3, 0))
	for i in 40:
		d.global_position = spot + Vector3.UP * 0.45
		if d._rocket_fx != null:
			d._rocket_fx._heading = -d.global_basis.z
			d._rocket_fx._last_pos = Vector3.INF
		await get_tree().physics_frame
	await _shot("flying")
	game.dev.remove_bot(id)

	# First person, mid-flight: run up the spine and hold the dive.
	me.teleport(game._floor_at(spot + Vector3(0, 0, 8.0)))
	me.bot_yaw = 0.0
	me.bot_pitch = 0.0
	me.stamina = 1.0
	await _frames(5)
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	for i in 120:
		if me.sprinting:
			break
		await get_tree().physics_frame
	me.bot_rocket_hold = true
	me.bot_dive += 1
	await _frames(24)
	await _shot("first_person")
	me.bot_rocket_hold = false
	print("[bootsshot] done")
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[bootsshot] wrote ", path)


func _look_from(pos: Vector3, at: Vector3) -> void:
	me.teleport(game._floor_at(pos))
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var d := at - eye
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)
