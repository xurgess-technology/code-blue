extends Node
## Windowed screenshots for the settings work: the screen over the title menu and over the
## pause overlay, a dark corridor at low / default / high brightness, the held item at three
## fields of view, and the surgery camera at the widest field of view.
##
##   godot --path . --resolution 1280x720 tools/settingsshot.tscn -- [--seed=N]
##
## Writes tools/settings_shots/<width>x<height>_<name>.png. Uses a scratch settings file, so
## the player's own settings are untouched.

const OUT_DIR := "res://tools/settings_shots"
const TEST_PATH := "user://settings_shot.cfg"

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _prefix := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s_%s.png" % [OUT_DIR, _prefix, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[settingsshot] wrote ", path)


func _run() -> void:
	var real_path: String = Settings.path
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	Settings.legacy_path = ""
	Settings.use_path(TEST_PATH)
	var s := Vector2(DisplayServer.window_get_size())
	_prefix = "%dx%d" % [int(s.x), int(s.y)]

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	game = main.game
	if main.launching:
		await main.launched
	await _frames(90)   # the sign-in sheet feeds up and settles

	# 1. From the title menu: the sign-in sheet ejects, the settings page feeds out; Back reverses it.
	main.settings_ui.open()
	await _frames(14)
	await _shot("01a_menu_sheet_ejecting")
	await _frames(40)
	await _shot("01b_settings_feeding")
	await _frames(70)
	await _shot("01_menu_settings")
	main.settings_ui.close()
	await _frames(14)
	await _shot("01c_settings_ejecting")
	await _frames(40)
	await _shot("01d_menu_feeding")
	await _frames(80)
	await _shot("01e_menu_back")
	if OS.get_cmdline_user_args().has("--menu-only"):
		get_tree().quit(0)
		return

	# Into a shift.
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await _frames(2)
	bot = game.local_player()
	# Mouse look needs a captured mouse, which the headless test cannot get; check it here.
	Settings.set_value("sensitivity", 2.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await _frames(2)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var yaw0: float = bot._yaw
		var ev := InputEventMouseMotion.new()
		ev.relative = Vector2(100, 0)
		bot._input(ev)
		var got: float = yaw0 - bot._yaw
		print("[settingsshot] sensitivity 2.0: yaw moved %.4f for 100 px, expected %.4f -> %s" % [
			got, 100.0 * Player.MOUSE_SENS * 2.0, "ok" if absf(got - 0.44) < 0.0001 else "FAIL"])
	else:
		print("[settingsshot] sensitivity check skipped: mouse could not be captured")
	Settings.set_value("sensitivity", 1.0)
	bot.bot_active = true
	bot.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	game.begin_shift()
	await _frames(5)
	_pose_corridor(true)
	await _frames(30)

	# 2. Esc: the settings fax comes in (printer up, page down into it), at rest, and on its way out.
	main._toggle_pause()
	await _frames(14)
	await _shot("02_pause_coming_in")
	await _frames(50)
	await _shot("03_pause_settings")
	main._toggle_pause()
	await _frames(12)
	await _shot("03b_pause_leaving")
	while game.paused:
		await get_tree().process_frame
	if OS.get_cmdline_user_args().has("--pause-only"):
		get_tree().quit(0)
		return

	# 3. Dark corridor, flashlight off and on, at three brightness settings.
	for light in [false, true]:
		bot.set_flashlight(light)
		for b in [0.0, 0.5, 1.0]:
			Settings.set_value("brightness", b)
			await _frames(40)
			await _shot("04_corridor_%s_brightness_%03d" % ["light" if light else "dark", roundi(b * 100)])
	Settings.set_value("brightness", 0.5)
	_pose_dark()
	for b in [0.0, 0.5, 1.0]:
		Settings.set_value("brightness", b)
		await _frames(40)
		await _shot("05_dark_room_brightness_%03d" % roundi(b * 100))
	Settings.set_value("brightness", 0.5)
	bot.set_flashlight(true)

	# 4. Held item at three fields of view.
	bot.slots[0] = {"kind": "bone_saw", "count": 1}
	bot.slots[1] = {"kind": "anesthetic", "count": 3}
	bot.selected = 0
	_pose_or()
	for f in [60.0, 78.0, 100.0]:
		Settings.set_value("fov", f)
		await _frames(30)
		await _shot("06_held_fov_%03d" % roundi(f))
	bot.slots[0] = {"kind": "", "count": 0}
	bot.slots[1] = {"kind": "", "count": 0}

	# 5. Operating at the widest field of view: the surgery camera keeps its own framing.
	Settings.set_value("fov", 100.0)
	for kind in Items.SURGICAL:
		game.shelf[kind] = 3 if Items.is_consumable(kind) else 1
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)
	var tb := game.table_pos()
	_look_from(tb + Vector3(0.0, 0.0, 1.2), tb + Vector3(0, 1.0, 0))
	game.surgery.bot_skill = 0.5
	bot.bot_aim_id = "table"
	bot.bot_press += 1
	await _frames(140)
	await _shot("07_operating_fov_100")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	Settings.path = real_path
	Settings._save_timer = -1.0
	print("[settingsshot] done")
	get_tree().quit(0)


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y - C.EYE_H, Vector2(d.x, d.z).length()), -1.0, 1.0)


func _pose_or() -> void:
	var t := game.table_pos()
	_look_from(t + Vector3(0.6, 0, 3.4), t + Vector3(0, 1.0, 0))


## The longest clear sightline, as in tools/gameshot.gd.
func _pose_corridor(_first: bool) -> void:
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
	_look_from(best_from, best_from + Vector3.UP * C.EYE_H + best_dir * best_len * 0.9)


func _pose_dark() -> void:
	bot.set_flashlight(false)
	var spots: Array = game.level_info.get("tool_spawns", [])
	var p: Vector3 = spots[spots.size() / 2] if spots.size() > 0 else game.table_pos()
	_look_from(p, game.table_pos())
