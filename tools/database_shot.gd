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
	# --scan: the scanner's hologram mid-scan, then the completion flash, ring and banner.
	if OS.get_cmdline_user_args().has("--scan"):
		shots = [
			{"name": "70_scan_hologram", "fn": _pose_scan_ring, "settle": 1},
			{"name": "71_scan_complete", "fn": _pose_scan_complete, "settle": 1},
			{"name": "72_scan_nothing", "fn": _pose_scan_nothing, "settle": 20},
		]
	# --wall: the break room's wall terminal (terminal redesign chunk 1): from across the room, the
	# laser on a card, and after clicking it.
	if OS.get_cmdline_user_args().has("--wall"):
		shots = [
			{"name": "73_wall_terminal", "fn": _pose_wall.bind(-1), "settle": 30},
			{"name": "74_wall_laser_hover", "fn": _pose_wall.bind(0), "settle": 20},
			{"name": "75_wall_after_click", "fn": _pose_wall_click, "settle": 20},
			{"name": "76_wall_surge", "fn": _pose_wall_surge, "settle": 3},
			{"name": "77_projector_off", "fn": _pose_projector_off, "settle": 10},
		]
	# --terminal: every kind of page the 3D viewer shows instead.
	if OS.get_cmdline_user_args().has("--terminal"):
		shots = [
			{"name": "63_terminal_walk_in_t1", "fn": _pose_page.bind(0, 0, {"walk_in": ["sighted"]}), "settle": 30},
			{"name": "64_terminal_discharged_t2", "fn": _pose_page.bind(0, 1, {"discharged": ["sighted", "scanned"]}), "settle": 30},
			{"name": "65_terminal_walk_in_t3", "fn": _pose_page.bind(0, 0, {"walk_in": ["sighted", "scanned", "harvested"]}), "settle": 30},
			{"name": "66_terminal_nurse_t2", "fn": _pose_page.bind(0, 2, {"night_nurse": ["sighted", "scanned"]}), "settle": 30},
			{"name": "67_terminal_ability", "fn": _pose_page.bind(1, 0, {}), "settle": 30},
			{"name": "68_terminal_item", "fn": _pose_page.bind(2, 2, {}), "settle": 30},
			{"name": "69_terminal_procedure", "fn": _pose_procedure, "settle": 30},
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


## The terminal open on section `tab`, row `index`, with the database holding `marks`.
func _pose_page(tab: int, index: int, marks: Dictionary) -> void:
	game.database.clear()
	for kind in marks.keys():
		for m in marks[kind]:
			game.mark_db(kind, m)
	main.terminal_ui.open()
	main.terminal_ui._tab = tab
	main.terminal_ui._index = index
	await get_tree().process_frame


func _pose_procedure() -> void:
	var entries: Array = main.terminal_ui.Pages.entries()
	for i in entries.size():
		if String(entries[i].type) == "procedure":
			await _pose_page(2, i, {})
			return


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


## Stand back from the wall terminal; `card` >= 0 aims the laser at that home card (R held).
func _pose_wall(card: int) -> void:
	var wt: Node3D = _level_wall_terminal()
	if wt == null:
		print("[database_shot] no wall terminal")
		return
	var glass: Node3D = wt.glass
	var n: Vector3 = glass.global_basis.z.normalized()
	var stand: Vector3 = glass.global_position + n * 3.2
	bot.teleport(game._floor_at(Vector3(stand.x, 0.0, stand.z)))
	await get_tree().process_frame
	var target: Vector3 = glass.global_position
	if card >= 0:
		var w := (1184.0 - 72.0) / 4.0
		var px := Vector2(48.0 + card * (w + 24.0) + w * 0.5, 140.0 + 140.0 + 165.0)
		target = glass.global_transform * Vector3((px.x / 1280.0 - 0.5) * wt.SIZE.x, (0.5 - px.y / 720.0) * wt.SIZE.y, 0.0)
	for i in 30:
		var d: Vector3 = target - bot.camera.global_position
		var fwd: Vector3 = -bot.camera.global_transform.basis.z
		bot.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		bot.bot_pitch = clampf(bot.bot_pitch + atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length()), -1.2, 1.2)
		await get_tree().process_frame
	bot.bot_scan = card >= 0


## The level's own wall terminal (the warmup's hidden copy is in the group too).
func _level_wall_terminal() -> Node3D:
	for n in get_tree().get_nodes_in_group("wall_terminal"):
		if game.level != null and game.level.is_ancestor_of(n):
			return n
	return null


func _pose_wall_click() -> void:
	bot.bot_laser_click += 1
	await get_tree().process_frame
	await get_tree().process_frame
	var wt: Node3D = _level_wall_terminal()
	print("[database_shot] wall page after click: ", wt.ui.page if wt != null else "?")


## E on the projector (through its proxy, as the host) switches it off; the laser on the dark screen.
func _pose_projector_off() -> void:
	var node := game.find_interactable("projector")
	print("[database_shot] projector proxy: %s, flashlight lit while scanning: %s" % [str(node != null), str(bot.flashlight.visible)])
	if node != null:
		node.interact(bot)
	await get_tree().process_frame
	print("[database_shot] projector on after E: %s, prompt '%s'" % [str(game.projector_on), node.interact_prompt(bot) if node != null else ""])
	await _pose_wall(0)


func _pose_wall_surge() -> void:
	bot.bot_yaw += 1.2
	for i in 4:
		await get_tree().process_frame
	bot.bot_laser_click += 1
	await get_tree().process_frame


## Keep scanning the Walk-In from _pose_scan_ring until it completes, a few frames into the ring.
func _pose_scan_complete() -> void:
	var hud: Node = get_tree().get_first_node_in_group("hud")
	var wi: Node3D = null
	for m in game.monsters.values():
		wi = m
	if wi == null or hud == null:
		return
	var pin: Vector3 = wi.global_position
	for i in 400:
		wi.global_position = pin
		var d: Vector3 = pin + Vector3.UP * 1.0 - bot.camera.global_position
		bot.bot_yaw = atan2(-d.x, -d.z)
		bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
		await get_tree().process_frame
		if float(hud._scan_banner_until) > float(hud._t) + 2.2:
			break
	for i in 12:
		wi.global_position = pin
		await get_tree().process_frame


## Holding R at an empty wall: the blue flashlight and the scan line.
func _pose_scan_nothing() -> void:
	for m in game.monsters.values():
		game.kill_monster(m)
	await get_tree().process_frame
	bot.bot_scan = false
	var er: Rect2 = game.level_info.get("entrance_rect", Rect2())
	var at := er.position + Vector2(8.0, 3.0) * C.TILE
	bot.teleport(game._floor_at(Vector3(at.x, 0, at.y)))
	bot.bot_yaw = 0.0
	bot.bot_pitch = -0.1
	await get_tree().process_frame
	bot.bot_scan = true


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
