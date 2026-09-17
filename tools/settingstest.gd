extends Node
## Headless check of the Settings autoload and everything that listens to it.
##
##   godot --headless --fixed-fps 60 --path . tools/settingstest.tscn
##
## Works on a scratch file (user://settings_test.cfg), never the player's own settings.
## Checks: defaults, migration of the old quality preset, clamping, every key applied to
## its consumer (buses, Audio's music trim, the environment, the player camera and hands,
## mouse look, main's quality), the settings screen following changes, and persistence
## through a save and reload. Exits 0 when every check passes.

const TEST_PATH := "user://settings_test.cfg"
const TEST_LEGACY := "user://settings_test_prefs.cfg"

var main: Node3D
var game: Game
var fails := 0
var checks := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	checks += 1
	if ok:
		print("[settings] ok    ", what)
	else:
		fails += 1
		print("[settings] FAIL  ", what)


func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var real_path: String = Settings.path
	var real_legacy: String = Settings.legacy_path
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_LEGACY))

	# --- migration: no settings file, an old prefs.cfg with video/quality = 2 ---------
	var legacy := ConfigFile.new()
	legacy.set_value("menu", "name", "Tester")
	legacy.set_value("video", "quality", 2)
	legacy.save(TEST_LEGACY)
	Settings.legacy_path = TEST_LEGACY
	Settings.use_path(TEST_PATH)
	_check(int(Settings.get_value("quality")) == 2, "migrates quality from the old prefs file")
	_check(FileAccess.file_exists(TEST_PATH), "migration writes the new file")
	# Defaults for everything else.
	for key in Settings.DEFAULTS.keys():
		if key != "quality":
			_check(str(Settings.get_value(key)) == str(Settings.DEFAULTS[key]), "default %s = %s" % [key, str(Settings.DEFAULTS[key])])

	# --- the game, with a local player --------------------------------------------------
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(2)
	game = main.game
	_check(main.quality == 2, "main boots with the migrated quality")
	_check(main.settings_ui != null and not main.settings_ui.is_open(), "settings screen exists, closed")
	main.menu.hide_menu()
	Net.start_solo("Settings")
	game.start_session(777)
	await _frames(3)
	var me: Player = game.local_player()
	_check(me != null, "local player exists")

	var env: Environment = (main.get_node("LookEnvironment") as WorldEnvironment).environment
	var shipped_grade: Texture2D = env.adjustment_color_correction
	_check(_near(env.tonemap_exposure, 1.0, 0.0001), "default brightness keeps exposure 1.0")

	# --- clamping and validation ---------------------------------------------------------
	Settings.set_value("fov", 500.0)
	_check(_near(Settings.get_value("fov"), 100.0), "fov clamps to 100")
	Settings.set_value("window_mode", "banana")
	_check(Settings.get_value("window_mode") == "windowed", "bad window mode falls back to windowed")
	Settings.set_value("carry_camera", "banana")   # HANDS HOOK
	_check(Settings.get_value("carry_camera") == "shoulder", "bad carry camera mode falls back to shoulder")
	Settings.set_value("sprint_mode", "banana")
	_check(Settings.get_value("sprint_mode") == "toggle", "bad sprint mode falls back to toggle")
	Settings.set_value("quality", 7)
	_check(Settings.get_value("quality") == 2, "quality clamps to 2")

	# --- apply every key ------------------------------------------------------------------
	var seen := {}
	var on_changed := func(k, _v): seen[k] = true
	Settings.changed.connect(on_changed)

	Settings.set_value("master_volume", 0.5)
	Settings.set_value("music_volume", 0.0)
	Settings.set_value("sfx_volume", 0.25)
	Settings.set_value("window_mode", "borderless")
	Settings.set_value("brightness", 0.8)
	Settings.set_value("sensitivity", 2.0)
	Settings.set_value("fov", 95.0)
	Settings.set_value("quality", 0)
	Settings.set_value("carry_camera", "first_person")   # HANDS HOOK
	Settings.set_value("sprint_mode", "hold")
	Settings.set_value("key_crouch", KEY_C)   # SWEEP 4A HOOK (controls)
	Settings.set_value("key_jump", KEY_J)
	Settings.set_value("key_ability_alt", KEY_X)
	Settings.set_value("key_scan", KEY_V)
	await _frames(3)
	for key in Settings.DEFAULTS.keys():
		_check(seen.has(key), "changed emitted for %s" % key)
	# SWEEP 4A HOOK (controls): a rebind applies to the InputMap action right away.
	for pair in [["key_crouch", "crouch", KEY_C], ["key_jump", "jump", KEY_J], ["key_ability_alt", "ability_alt", KEY_X], ["key_scan", "scan", KEY_V]]:
		var evs: Array = InputMap.action_get_events(String(pair[1]))
		var found := false
		for ev in evs:
			if ev is InputEventKey and int((ev as InputEventKey).physical_keycode) == int(pair[2]):
				found = true
		_check(found, "rebinding %s updates the '%s' InputMap action" % [pair[0], pair[1]])

	_check(_near(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master")), -12.04), "Master bus at -12 dB for 0.5")
	_check(_near(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX")), -24.08), "SFX bus at -24 dB for 0.25")
	_check(AudioServer.get_bus_send(AudioServer.get_bus_index("Ambience")) == &"SFX", "Ambience sends to SFX")
	# Pool players take whatever bus their last cue asked for (the loading screen's beeps use UI), so
	# check a plain cue lands on SFX rather than a particular pool slot.
	var cue_player: Node = Audio.play("click", null, -80.0)
	_check(Audio._ambience_player.bus == &"Ambience" and cue_player != null and cue_player.bus == &"SFX", "Audio players on their buses")
	_check((Audio._stem_players["dread"] as AudioStreamPlayer).bus == &"Music", "music stems on the Music bus")
	_check(_near(Audio.music_volume_db, -80.0), "Audio music trim at -80 dB for 0")
	_check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "Music bus muted at 0")
	Settings.set_value("music_volume", 0.5)
	await _frames(2)
	var music_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music"))
	_check(not AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) and _near(music_db, Audio.MUSIC_BASE_DB - 12.04, 0.2),
		"Music bus at base -12 dB for 0.5 (%.2f)" % music_db)

	_check(_near(env.tonemap_exposure, pow(2.0, 0.15), 0.001), "brightness 0.8 raises exposure (%.3f)" % env.tonemap_exposure)
	_check(env.adjustment_color_correction != shipped_grade, "brightness 0.8 bends the grade ramp")
	var bent := env.adjustment_color_correction as GradientTexture1D
	var shipped := Look.make_grade_gradient()
	_check(bent.gradient.sample(0.2).get_luminance() > shipped.gradient.sample(0.2).get_luminance() + 0.02, "bent ramp lifts the shadows")
	_check(_near(bent.gradient.sample(0.0).r, 0.0, 0.001) and _near(bent.gradient.sample(1.0).r, 1.0, 0.001), "bent ramp keeps black and white")

	_check(_near(me.camera.fov, 95.0, 0.05), "player camera fov follows (%.2f)" % me.camera.fov)
	# HANDS HOOK: the first-person hands are posed every frame; their x/y scale follows the setting.
	var k := tan(deg_to_rad(95.0) * 0.5) / tan(deg_to_rad(78.0) * 0.5)
	await get_tree().process_frame
	var pr: Dictionary = me.hands.pose_r
	_check(_near(me.hands.fov_k, k, 0.001) and not pr.is_empty() and absf(me.hands.arm_r.position.z - float((pr.p as Vector3).z)) < 0.06
		and absf(me.hands.arm_r.position.x - float((pr.p as Vector3).x) * k) < 0.06, "hands keep their screen place at fov 95 (k %.3f)" % me.hands.fov_k)
	# Sprinting still kicks on top of the setting.
	me.bot_active = true
	me.bot_invulnerable = true
	me.bot_yaw = me._yaw
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _frames(40)
	_check(me.camera.fov > 97.0, "sprint fov kick adds on top (%.1f)" % me.camera.fov)
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	await _frames(90)
	me.bot_active = false
	_check(_near(me.camera.fov, 95.0, 0.2), "fov settles back to the setting")

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await _frames(1)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var yaw0: float = me._yaw
		var ev := InputEventMouseMotion.new()
		ev.relative = Vector2(100, 0)
		me._input(ev)
		_check(_near(yaw0 - me._yaw, 100.0 * Player.MOUSE_SENS * 2.0, 0.0001), "sensitivity 2.0 doubles mouse look")
	else:
		# The headless display server cannot capture the mouse; check the math the handler uses.
		_check(_near(float(Settings.get_value("sensitivity")), 2.0), "sensitivity stored (mouse capture unavailable headless)")

	_check(main.quality == 0, "main switched to quality LOW")
	_check(_near(get_viewport().scaling_3d_scale, main.RENDER_SCALE[0]), "LOW render scale applied")

	# --- the screen follows changes made elsewhere (F2, F11) --------------------------------
	main.settings_ui.open()
	await _frames(1)
	var f2 := InputEventKey.new()
	f2.physical_keycode = KEY_F2
	f2.pressed = true
	main._unhandled_input(f2)
	await _frames(1)
	_check(main.quality == 2 and Settings.get_value("quality") == 2, "F2 cycles quality LOW -> HIGH and saves it")
	var ui = main.settings_ui
	_check((ui._choices["quality"][2] as Button).button_pressed, "screen shows HIGH after F2")
	(ui._sliders["brightness"].slider as HSlider).value = 0.3
	await _frames(1)
	_check(_near(Settings.get_value("brightness"), 0.3), "brightness slider writes the setting")
	_check(env.tonemap_exposure < 1.0, "brightness 0.3 lowers exposure")
	(ui._choices["window_mode"]["windowed"] as Button).button_pressed = true
	_check(Settings.get_value("window_mode") == "windowed", "window mode buttons write the setting")
	# HANDS HOOK: the carry camera toggle.
	(ui._choices["carry_camera"]["first_person"] as Button).button_pressed = true
	_check(Settings.get_value("carry_camera") == "first_person", "carry camera buttons write the setting")
	Settings.set_value("carry_camera", "shoulder")
	_check((ui._choices["carry_camera"]["shoulder"] as Button).button_pressed, "the screen follows the carry camera setting")
	(ui._choices["sprint_mode"]["hold"] as Button).button_pressed = true
	_check(Settings.get_value("sprint_mode") == "hold", "sprint mode buttons write the setting")
	Settings.set_value("sprint_mode", "toggle")
	_check((ui._choices["sprint_mode"]["toggle"] as Button).button_pressed, "the screen follows the sprint mode setting")
	var f11 := InputEventAction.new()
	f11.action = "fullscreen"
	f11.pressed = true
	main._unhandled_input(f11)
	_check(Settings.get_value("window_mode") == "fullscreen" and (ui._choices["window_mode"]["fullscreen"] as Button).button_pressed,
		"F11 sets fullscreen and the screen follows")
	Settings.set_value("window_mode", "borderless")
	var esc := InputEventAction.new()
	esc.action = "pause"
	esc.pressed = true
	get_viewport().push_input(esc)
	await _frames(1)
	_check(not ui.is_open() and not game.paused, "Esc closes the screen without pausing")

	# Pause: Esc brings up the settings fax as the pause menu; Esc again resumes the shift at once while
	# the page animates away (docs/FAX.md).
	main._toggle_pause()
	await _frames(2)
	_check(game.paused and ui.is_open() and ui._pause_button.visible, "pausing brings up the settings fax with Resume")
	_check(ui._exit_menu_button.visible and ui._exit_desktop_button.visible,
		"the pause page has the Main menu / Quit game buttons")
	get_viewport().push_input(esc)
	await _frames(1)
	_check(not ui.is_open() and not game.paused, "Esc sends the page away and resumes the shift straight away")
	await _until(func(): return not game.paused, 3.0)
	_check(not game.paused and not ui._root.visible, "once the page has gone the shift resumes")
	main._toggle_pause()
	await _frames(2)
	ui._pause_button.pressed.emit()
	await _until(func(): return not game.paused, 3.0)
	_check(not game.paused, "Resume on the page resumes too")

	# "Exit to Main Menu": ends the session cleanly (same path Q already uses to walk out
	# mid-shift) and lands back at the menu, same as a fresh launch.
	main._toggle_pause()
	await _frames(2)
	_check(ui._exit_menu_button.visible, "pause shows Exit to Main Menu before using it")
	ui._exit_menu_button.pressed.emit()
	await _frames(2)
	_check(game.phase == Game.Phase.MENU and main.menu.visible, "Exit to Main Menu returns to the menu")
	_check(not Net.active and game.players.is_empty() and game.level == null,
		"Exit to Main Menu tears the session down: active=%s players=%d level=%s" %
		[str(Net.active), game.players.size(), str(game.level)])
	_check(not game.paused, "Exit to Main Menu clears the pause flag")

	# Back in for the rest of the file: a fresh solo session, same as before this block.
	main.menu.hide_menu()
	Net.start_solo("Settings")
	game.start_session(778)
	await _frames(3)
	me = game.local_player()
	_check(me != null, "local player exists again after Exit to Main Menu")

	# Default brightness restores the shipped look exactly.
	Settings.set_value("brightness", 0.5)
	_check(_near(env.tonemap_exposure, 1.0, 0.0001), "brightness back to default restores exposure 1.0")

	# --- persistence -------------------------------------------------------------------------
	var want := {
		"master_volume": 0.5, "music_volume": 0.5, "sfx_volume": 0.25, "window_mode": "borderless",
		"brightness": 0.5, "sensitivity": 2.0, "fov": 95.0, "quality": 2,
	}
	Settings.set_value("brightness", 0.65)
	want["brightness"] = 0.65
	Settings.save_now()
	var cfg := ConfigFile.new()
	_check(cfg.load(TEST_PATH) == OK, "settings file saved")
	# Knock the live values off, then reload from disk.
	Settings.set_value("fov", 70.0)
	Settings.set_value("master_volume", 1.0)
	Settings.set_value("quality", 1)
	Settings.reload()
	await _frames(2)
	for key in want.keys():
		_check(str(Settings.get_value(key)) == str(want[key]) or (want[key] is float and _near(float(Settings.get_value(key)), want[key], 0.0001)),
			"reload keeps %s = %s (got %s)" % [key, str(want[key]), str(Settings.get_value(key))])
	_check(_near(me.camera.fov, 95.0, 0.2), "reload re-applies fov to the camera")
	_check(main.quality == 2, "reload re-applies quality")
	_check(_near(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master")), -12.04), "reload re-applies Master volume")
	_check(_near(env.tonemap_exposure, pow(2.0, 0.075), 0.001), "reload re-applies brightness")

	# --- clean up, leave the player's settings untouched ---------------------------------------
	Settings.changed.disconnect(on_changed)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_LEGACY))
	Settings.legacy_path = real_legacy
	Settings.path = real_path
	Settings._save_timer = -1.0
	print("[settings] %d checks, %d failed" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)


func _until(cond: Callable, seconds: float) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())
