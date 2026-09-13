extends Node
## Boots the real game, poses it, and saves screenshots so the look can be checked
## without a human sitting at the keyboard.
##
##   godot --path . tools/gameshot.tscn -- [--seed=N]

const OUT_DIR := "res://tools/game_shots"
const SETTLE_FRAMES := 26

var main: Node3D
var game: Game
var bot: Player
var shots: Array = []
var _i := 0
var _seed := 4242


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.bot_move = Vector2.ZERO

	shots = [
		{"name": "01_clockin_room", "fn": _pose_clockin},
		{"name": "02_time_clock", "fn": _pose_clock},
		{"name": "03_corridor", "fn": _pose_corridor},
		{"name": "04_operating_room", "fn": _pose_or},
		{"name": "05_monster_close", "fn": _pose_monster},
		{"name": "06_surgery_hud", "fn": _pose_surgery},
		{"name": "07_dark_no_light", "fn": _pose_dark},
		{"name": "08_lectern_guide", "fn": _pose_lectern},
		{"name": "09_container_open", "fn": _pose_container},
	]
	_run()


func _run() -> void:
	for shot in shots:
		shot.fn.call()
		for i in SETTLE_FRAMES:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot.name]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[gameshot] wrote ", path, "  ", img.get_width(), "x", img.get_height())
		_i += 1
	print("[gameshot] done, %d shots" % _i)
	get_tree().quit(0)


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot._pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	bot.head.rotation.x = bot._pitch


func _pose_clockin() -> void:
	var spots := game.spawn_points()
	_look_from(spots[0] + Vector3(0, 0, 0), game.clock_pos())


func _pose_clock() -> void:
	var c := game.clock_pos()
	_look_from(c + Vector3(2.6, 0, 2.6), c + Vector3(0, 1.4, 0))


## Find the longest clear sightline in the level and stand at one end of it,
## so the shot shows a corridor rather than the inside of a wall.
func _pose_corridor() -> void:
	var candidates: Array = game.level_info.get("monster_spawns", [])
	if candidates.is_empty():
		candidates = game.level_info.get("tool_spawns", [])
	if candidates.is_empty():
		_look_from(game.table_pos() + Vector3(0, 0, 6), game.table_pos())
		return
	var space := bot.get_world_3d().direct_space_state
	var best_len := -1.0
	var best_from: Vector3 = candidates[0]
	var best_dir := Vector3.FORWARD
	for spot in candidates:
		var eye: Vector3 = spot + Vector3.UP * C.EYE_H
		for i in 16:
			var a := TAU * i / 16.0
			var dir := Vector3(cos(a), 0, sin(a))
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 40.0)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			var reach: float = 40.0 if hit.is_empty() else eye.distance_to(hit.position)
			if reach > best_len:
				best_len = reach
				best_from = spot
				best_dir = dir
	print("[gameshot] longest sightline %.1f m" % best_len)
	_look_from(best_from, best_from + Vector3.UP * (C.EYE_H - 0.1) + best_dir * best_len * 0.9)


func _pose_or() -> void:
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
	var t := game.table_pos()
	_look_from(t + Vector3(0.6, 0, 3.4), t + Vector3(0, 1.0, 0))


func _pose_monster() -> void:
	if game.monsters.is_empty():
		return
	var m = game.monsters.values()[0]
	var t := game.table_pos()
	m.global_position = t + Vector3(0, 0, -3.0)
	m.state = Monster.State.STUNNED
	if "stun" in m:  # the monster rewrite dropped this field
		m.stun = 99.0
	m.process_mode = Node.PROCESS_MODE_DISABLED
	_look_from(t + Vector3(0, 0, 2.0), m.global_position + Vector3(0, 1.4, 0))


## Stock the shelf and stand beside the table looking at the patient and the supplies.
func _pose_surgery() -> void:
	for kind in Items.SURGICAL:
		game.shelf[kind] = 3 if Items.is_consumable(kind) else 1
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)
	game.vitals = 38.0
	var tb := game.table_pos()
	var sh: Vector3 = game.shelf_node.global_position if game.shelf_node != null else tb
	_look_from(tb + (tb - sh).normalized() * 2.2 + Vector3(0, 0, 0.6), (tb + sh) * 0.5 + Vector3(0, 1.0, 0))
	bot.bot_aim_id = "table"


func _pose_dark() -> void:
	bot.bot_interact = false
	bot.set_flashlight(false)
	var spots: Array = game.level_info.get("tool_spawns", [])
	var p: Vector3 = spots[spots.size() / 2] if spots.size() > 0 else game.table_pos()
	_look_from(p, game.table_pos())


func _pose_lectern() -> void:
	bot.set_flashlight(true)
	var info: Dictionary = game.level_info.get("lectern", {})
	var base: Vector3 = info.get("position", game.clock_pos() + Vector3(1.6, 0, 0))
	_look_from(base + Vector3(1.4, 0, 1.4), base + Vector3(0, 1.0, 0))


func _pose_container() -> void:
	var cts: Array = game.level_info.get("containers", [])
	for e in cts:
		var node: Node = e.get("node")
		if node == null or not is_instance_valid(node) or not node.has_method("set_open"):
			continue
		node.set_open(true, false)
		var p: Vector3 = (node as Node3D).global_position
		var out: Vector3 = (node as Node3D).global_basis.z.normalized()
		_look_from(p + out * 1.6, p + Vector3(0, 1.0, 0))
		return
