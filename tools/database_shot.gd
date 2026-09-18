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
	# --wall2: the wall terminal's drill-down (chunk 2), straight on, projector on.
	if OS.get_cmdline_user_args().has("--wall2"):
		shots = [
			{"name": "78_wall_signing_in", "fn": _pose_wall_sign_in.bind(0.8), "settle": 1},
			{"name": "79_wall_signed_in", "fn": _pose_wall_sign_in.bind(1.2), "settle": 10},
			{"name": "80_wall_home", "fn": _pose_wall2.bind({"kind": "home"}), "settle": 30},
			{"name": "81_wall_monsters", "fn": _pose_wall2.bind({"kind": "section", "id": "monsters", "index": 0}), "settle": 20},
			{"name": "82_wall_walk_in", "fn": _pose_wall2.bind({"kind": "entry", "section": "monsters", "key": "walk_in"}), "settle": 45},
			{"name": "83_wall_other", "fn": _pose_wall2.bind({"kind": "section", "id": "other", "index": 1}), "settle": 20},
			{"name": "84_wall_gunshot", "fn": _pose_wall2.bind({"kind": "entry", "section": "procedures", "key": "amputation"}), "settle": 45},
			{"name": "85_wall_tool_hover", "fn": _pose_wall2_tool.bind(false), "settle": 4},
			{"name": "85b_wall_tool_clicked", "fn": _pose_wall2_tool.bind(true), "settle": 45},
			{"name": "86_wall_upside_down", "fn": _pose_wall2.bind({"kind": "section", "id": "monsters", "index": 0}, "flip"), "settle": 30},
			{"name": "87_wall_jammed", "fn": _pose_wall2.bind({"kind": "section", "id": "surgery", "index": 0}, "jam"), "settle": 20},
		]
	# --nurse: scan the waiting room's Night Nurse the way a player would (she keeps running).
	if OS.get_cmdline_user_args().has("--nurse"):
		shots = [{"name": "86_scan_nurse", "fn": _pose_scan_nurse, "settle": 1}]
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


## Aiming at a monster mid-scan: the HUD's crosshair progress ring.
func _pose_scan_ring() -> void:
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


func _pose_scan_nurse() -> void:
	var wn: Node3D = game.economy.waiting_nurse
	# From each side of her (one has the bench in the way): does a held scan finish?
	for ang in [0.0, PI * 0.5, PI, PI * 1.5]:
		game.database.erase("night_nurse")
		var dir := Basis(Vector3.UP, ang) * -wn.global_basis.z
		bot.bot_scan = false
		bot.teleport(game._floor_at(wn.global_position + dir * 2.5))
		await get_tree().process_frame
		bot.bot_scan = true
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 6000 and not bool(game.db_record("night_nurse").scanned):
			var head: Vector3 = wn.global_position + Vector3.UP * 1.1
			var d: Vector3 = head - bot.camera.global_position
			var fwd: Vector3 = -bot.camera.global_transform.basis.z
			bot.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
			bot.bot_pitch = clampf(bot.bot_pitch + atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length()), -1.2, 1.2)
			await get_tree().process_frame
		print("[database_shot] NURSE side=%.0f scanned=%s after %d ms" % [rad_to_deg(ang), str(game.db_record("night_nurse").scanned), Time.get_ticks_msec() - t0])
	bot.bot_scan = false


## Chunk 2: stand square to the screen with the projector on and open `to` (a scanned Walk-In with
## Hive Eyes at level 1, a stethoscope picked up).
func _pose_wall2(to: Dictionary, quirk := "") -> void:
	var wt: Node3D = _level_wall_terminal()
	if wt == null:
		return
	# The carousel misbehaves only when a shot asks it to (projector chunk 3).
	wt.ui.quirks = false
	wt.ui.next_quirk = quirk
	game._set_projector(true)
	bot.bot_scan = false
	bot.bot_laser_hold = false
	game.database.clear()
	game.mark_db("walk_in", "sighted")
	game.mark_db("walk_in", "scanned")
	game.mark_db("stethoscope", "sighted")
	game.brains.set_level(bot.peer_id, "hive_in", 1)
	bot.set_flashlight(false)
	var glass: Node3D = wt.glass
	var n: Vector3 = glass.global_basis.z.normalized()
	var stand: Vector3 = glass.global_position + n * 4.6
	bot.teleport(game._floor_at(Vector3(stand.x, 0.0, stand.z)))
	await get_tree().process_frame
	for i in 20:
		var d: Vector3 = glass.global_position - bot.camera.global_position
		var fwd: Vector3 = -bot.camera.global_transform.basis.z
		bot.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		bot.bot_pitch = clampf(bot.bot_pitch + atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length()), -1.2, 1.2)
		await get_tree().process_frame
	if int(game.wall.user) == 0:
		game.wall.sign_in()
	if String(to.kind) == "home":
		wt.ui.go_home()
	else:
		wt.ui.open(to)


## Chunk 3: the bot's laser held on HOLD TO SIGN IN for `secs` (the first call starts signed out).
func _pose_wall_sign_in(secs: float) -> void:
	var wt: Node3D = _level_wall_terminal()
	if wt == null:
		return
	if secs < 1.0:
		await _pose_wall2({"kind": "home"})
		game.wall.sign_out()
		await get_tree().process_frame
	var r: Rect2 = wt.ui.sign_rect()
	var target: Vector3 = _screen_point(wt, r.get_center() if r.size.x > 0 else Vector2(640, 360))
	bot.bot_scan = true
	bot.bot_laser_hold = true
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		_aim_bot(target)
		await get_tree().process_frame
	print("[database_shot] sign-in after %.1f s: user=%d name=%s" % [secs, int(game.wall.user), game.wall.user_name()])
	if secs >= 1.0:
		bot.bot_laser_hold = false


func _screen_point(wt: Node3D, px: Vector2) -> Vector3:
	var local := Vector3((px.x / wt.TEX.x - 0.5) * wt.SIZE.x, (0.5 - px.y / wt.TEX.y) * wt.SIZE.y, 0.0)
	return wt.glass.global_transform * local


func _aim_bot(at: Vector3) -> void:
	var d: Vector3 = at - bot.camera.global_position
	var fwd: Vector3 = -bot.camera.global_transform.basis.z
	bot.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
	bot.bot_pitch = clampf(bot.bot_pitch + atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length()), -1.2, 1.2)


## Point at the amputation page's second tool on the turntable (its name shows); `click` opens it.
func _pose_wall2_tool(click: bool) -> void:
	var wt: Node3D = _level_wall_terminal()
	var pv = wt.ui._preview
	var holders: Array = []
	for h in pv._pivot.get_children():
		if h.has_meta("box"):
			holders.append(h)
	if holders.size() < 2:
		print("[database_shot] no tools on the turntable")
		return
	var h: Node3D = holders[1]
	var px: Vector2 = pv.screen_rect(h).get_center() + pv.position
	var label := String(h.get_child(0).get_meta("preview_label", "?"))
	if click:
		wt.click(px)
	else:
		# Keep pointing through the settle, as a held laser does.
		for f in 12:
			px = pv.screen_rect(h).get_center() + pv.position
			wt.point(px)
			await get_tree().process_frame
		var tag: Node3D = h.get_node_or_null("Tag")
		print("[database_shot] hover=%s tag_visible=%s" % [str(pv._hover), str(tag.visible if tag else null)])
	await get_tree().process_frame
	print("[database_shot] tool %s -> page %s" % [label, str(wt.ui.page)])


func _pose_wall2_step() -> void:
	var wt: Node3D = _level_wall_terminal()
	for c in wt.ui._body.get_children():
		if c is Button and String(c.text).begins_with("3."):
			c.pressed.emit()
			break
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
