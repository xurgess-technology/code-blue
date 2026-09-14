extends Node
## Windowed screenshots of the shift loop (loop worker, sweep 2): the start outside, the ringing
## phone, the call's subtitles, the paramedics with their gurney, two patients on the two tables,
## the paycheck screen and game over.
##
##   godot --path . tools/loopshot.tscn --resolution 1280x720 [-- --seed=N]
##
## Writes tools/loop_shots/*.png.

const OUT_DIR := "res://tools/loop_shots"

var main: Node3D
var game: Game
var bot: Player
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
	await _wait(3.0)   # the warmup cover
	await _run()
	print("[loopshot] done")
	get_tree().quit(0)


func _run() -> void:
	# 1. The start: outside, looking at the entrance.
	var start: Vector3 = game.spawn_points()[0]
	var doors: Vector3 = game.level_info.get("entrance", {}).get("position", game.clock_pos())
	_look_from(start, doors + Vector3.UP * 1.5)
	await _shot("01_start_outside", 1.0)

	# 2. Clock in, skip the grace period: the phone rings.
	game.loop.force_first = {"patient_id": "bob", "ailment_id": "gunshot"}
	game.loop.force_extra = {"patient_id": "seal", "ailment_id": "amputation"}
	game.clock_in()
	game.dev_skip_grace()
	await _wait(0.5)
	var ph: Node3D = game.loop.phone
	var fwd := -(Basis(Vector3.UP, ph.rotation.y) * Vector3.BACK)
	var eye_spot := game._floor_at(ph.global_position + (Basis(Vector3.UP, ph.rotation.y) * Vector3(0.6, 0, -2.0)))
	_look_from(eye_spot, ph.global_position + Vector3.UP * (0.0 if ph.wall else 0.9))
	await _shot("02_phone_ringing", 1.1)

	# 3. Answer: the subtitles.
	game.loop.answer(bot)
	await _shot("03_phone_subtitles", 3.2)

	# 4. The paramedics with the gurney, seen from in front.
	await _until(func(): return not game.loop.crews.is_empty(), 20.0)
	await _wait(4.0)
	await _pose_crew(6.5, 0.4)
	await _shot("04_paramedics_gurney", 0.4)
	await _pose_crew(3.2, 3.6)
	await _shot("05_paramedics_side", 0.4)
	# MODELS HOOK: close behind the pushing paramedic, then at the table during the hand-over.
	await _pose_crew(-4.6, 0.9)
	await _shot("05b_paramedics_behind", 0.3)
	await _until(func(): return not game.loop.crews.is_empty() and String(game.loop.crews.values()[0].ph) == "hand", 120.0)
	await _wait(0.2)
	if not game.loop.crews.is_empty():
		var cr: Dictionary = game.loop.crews.values()[0]
		var tp: Vector3 = game.table_position(int(cr.tb))
		var from: Vector3 = cr.p + (cr.p - tp).normalized() * 3.4 + Basis(Vector3.UP, float(cr.y)) * Vector3(0, 0, -1.6)
		_look_from(game._floor_at(from), (cr.p + tp) * 0.5 + Vector3.UP * 0.8)
		await _shot("05c_paramedics_at_table", 0.6)

	# 5. Two patients on the two tables.
	await _until(func(): return String(game.case.get("state", "")) == "on_table", 120.0)
	game.dev_extra_patient()
	await _wait(0.3)
	game.loop.answer(bot)
	await _until(func(): return game.cases.size() == 2 and String(game.cases[1].state) == "on_table", 150.0)
	await _until(func(): return game.loop.crews.is_empty(), 60.0)
	await _wait(1.0)
	var a: Vector3 = game.table_position(int(game.cases[0].table))
	var b: Vector3 = game.table_position(int(game.cases[1].table))
	for c in game.cases:
		var body := game.body_for_table(int(c.table))
		print("[loopshot] %s on table %d at %s, body at %s" % [c.patient_id, int(c.table), str(game.table_position(int(c.table))), str(body.global_position if body != null else null)])
	var mid := (a + b) * 0.5
	var across := (b - a).normalized()
	var side := across.cross(Vector3.UP).normalized()
	var n := 0
	for sgn in [1.0, -1.0]:
		var cam: Vector3 = mid + side * 3.2 * sgn + across * 0.6
		var q := PhysicsRayQueryParameters3D.create(mid + Vector3.UP * 1.6, cam + Vector3.UP * 1.6)
		q.collision_mask = C.L_WORLD
		if not bot.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			continue   # that side is behind a wall
		_look_from(game._floor_at(cam), mid + Vector3.UP * 0.8)
		await _shot("06_two_patients" if n == 0 else "07_two_patients_other_side", 1.0)
		n += 1
	# From the foot of one table, looking along both.
	_look_from(game._floor_at(a - across * 2.6 + side * 1.0), b + Vector3.UP * 0.8)
	await _shot("07b_two_patients_along", 1.0)
	_look_from(game._floor_at(b + side * 2.2 + across * 0.4), b + Vector3.UP * 0.9)
	await _shot("07c_extra_patient_close", 1.0)

	# 6. Both stable, clock out: the paycheck.
	for c in game.cases:
		game.finish_case(int(c.id), true)
	await _wait(0.5)
	game.loop.clock_out(false)
	_look_from(game._floor_at(game.clock_pos() + Vector3(0, 0, 1.8)), game.clock_pos() + Vector3.UP * 1.2)
	await _shot("08_clocked_out", 1.5)

	# 7. Game over.
	await _until(func(): return game.phase == Game.Phase.LOBBY, 20.0)
	game.clock_in()
	await _wait(0.5)
	bot.bot_invulnerable = false
	bot.invuln = 0.0
	await get_tree().physics_frame
	bot.invuln = 0.0
	game.damage_player(bot, 99, "test")
	await _shot("09_game_over", 1.5)


func _pose_crew(dist: float, sideways: float) -> void:
	var cr: Dictionary = game.loop.crews.values()[0]
	var pos: Vector3 = cr.p
	var basis := Basis(Vector3.UP, float(cr.y))
	var ahead := basis * Vector3(sideways, 0, -dist)
	_look_from(game._floor_at(pos + ahead), pos + Vector3.UP * 0.9)
	await get_tree().physics_frame


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - (pos + Vector3.UP * C.EYE_H)
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)


func _shot(name: String, settle: float) -> void:
	await _wait(settle)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[loopshot] wrote ", path)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	print("[loopshot] gave up waiting")
	return false
