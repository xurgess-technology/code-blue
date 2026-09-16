extends Node
## Three windowed screenshots of sweep 4a chunk 4 (docs/SWEEP4A.md "Screenshots (max 3)"), the
## same way tools/gameshot.gd / tools/fogshot.gd take theirs.
##
##   godot --path . tools/database_shot.tscn -- [--seed=N]
##
## Writes tools/game_shots/60_terminal_monster_tier2.png, 61_scan_ring.png, 62_hive_flight.png.

const OUT_DIR := "res://tools/game_shots"

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(300.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.bot_move = Vector2.ZERO
	Settings.set_value("quality", 1)
	await get_tree().process_frame

	var shots := [
		{"name": "60_terminal_monster_tier2", "fn": _pose_terminal, "settle": 20},
		{"name": "61_scan_ring", "fn": _pose_scan_ring, "settle": 6},
		{"name": "62_hive_flight", "fn": _pose_hive_flight, "settle": 1},
	]
	for shot in shots:
		await shot.fn.call()
		for i in int(shot.get("settle", 20)):
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot.name]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[database_shot] wrote ", path, "  ", img.get_width(), "x", img.get_height())
	print("[database_shot] done")
	get_tree().quit(0)


## The database terminal open on the Monsters section, tier 2 (scanned) for the Walk-In, with its
## X-ray showing.
func _pose_terminal() -> void:
	bot.teleport(game.table_pos() + Vector3(0, 0, -2.0))
	game.database.clear()
	game.mark_db("walk_in", "sighted")
	game.mark_db("walk_in", "scanned")
	main.terminal_ui.open()
	main.terminal_ui._tab = main.terminal_ui.Tab.MONSTERS
	main.terminal_ui._index = 0
	await get_tree().process_frame


## Aiming at a monster mid-scan: the HUD's crosshair progress ring.
func _pose_scan_ring() -> void:
	main.terminal_ui.close()
	await get_tree().process_frame
	var here: Vector3 = game.table_pos() + Vector3(0, 0, -2.0)
	bot.teleport(here)
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 4))) as Node3D
	await get_tree().process_frame
	var pin: Vector3 = wi.global_position
	var eye: Vector3 = pin + Vector3.UP * 1.0
	bot.bot_scan = true
	for i in 100:   # partway through the 3 s scan, well clear of 0 and full
		wi.global_position = pin
		var d: Vector3 = eye - bot.camera.global_position
		bot.bot_yaw = atan2(-d.x, -d.z)
		bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
		await get_tree().process_frame


## Mid fly-through: the camera should be somewhere between the player's head and the Walk-In.
func _pose_hive_flight() -> void:
	bot.bot_scan = false
	var b: Node = game.brains
	b.on_reset()
	b.set_level(bot.peer_id, "hive_in", 1)
	var here: Vector3 = bot.global_position
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 8))) as Node3D
	await get_tree().process_frame
	bot.bot_ability_slot = 0
	bot.bot_ability += 1
	# Land the screenshot partway through FLIGHT_IN (1.2 s): a few frames in is early enough that
	# the camera has visibly left the player's head but not yet reached the Walk-In's eyes.
	for i in 20:
		await get_tree().process_frame
