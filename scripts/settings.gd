extends Node
## The `Settings` autoload: the player's own options, persisted to user://settings.cfg.
##
##     Settings.get_value("fov")              # 78.0
##     Settings.set_value("brightness", 0.7)  # clamped, saved, applied, `changed` emitted
##     Settings.changed.connect(func(key, value): ...)
##
## Keys and ranges (see DEFAULTS / RANGES):
##   master_volume, music_volume, sfx_volume   0..1 slider position (mapped perceptually to dB)
##   window_mode    "fullscreen" (exclusive), "borderless" (full-screen window), "windowed"
##   brightness     0..1, 0.5 is the look as tuned; applied by main.gd through Look.apply_brightness
##   sensitivity    mouse look multiplier, 1.0 is the old fixed sensitivity
##   fov            player camera vertical field of view in degrees
##   quality        0 low, 1 medium, 2 high (main.gd's presets)
##   carry_camera   "shoulder" or "first_person" while carrying or dragging (scripts/camera/carry_camera.gd)
##   sprint_mode    "toggle" (press to start/stop sprinting) or "hold" (scripts/player.gd)
##
## This node applies what is global itself (audio buses, window mode). Scene-specific
## settings are applied by whoever owns the thing: main.gd (quality, brightness) and
## player.gd (sensitivity, fov) read get_value() when they are built and listen to `changed`.

signal changed(key: String, value)

const PATH := "user://settings.cfg"
const SECTION := "settings"
## The old home of the quality preset (main.gd wrote video/quality there before Settings).
const LEGACY_PREFS := "user://prefs.cfg"

const WINDOW_MODES: PackedStringArray = ["fullscreen", "borderless", "windowed"]
## HANDS HOOK: the over-the-shoulder camera while carrying a body or dragging a monster.
const CARRY_CAMERA_MODES: PackedStringArray = ["shoulder", "first_person"]
const SPRINT_MODES: PackedStringArray = ["toggle", "hold"]

const DEFAULTS := {
	"master_volume": 1.0,
	"music_volume": 1.0,
	"sfx_volume": 1.0,
	"window_mode": "windowed",
	"brightness": 0.5,
	"sensitivity": 1.0,
	"fov": 78.0,
	"quality": 1,
	"carry_camera": "shoulder",   # HANDS HOOK: "shoulder" | "first_person", carrying/dragging
	"sprint_mode": "toggle",
	# SWEEP 4A HOOK (controls): rebindable keys, stored as a physical_keycode int. Applied to the
	# matching InputMap action (see REBIND_ACTIONS / _apply) so the whole game (not just the
	# settings screen) follows a rebind immediately.
	"key_crouch": KEY_CTRL,
	"key_jump": KEY_SPACE,
	"key_ability_alt": KEY_ALT,
	"key_scan": KEY_R,
}

## Settings key -> the InputMap action it rebinds.
const REBIND_ACTIONS := {
	"key_crouch": "crouch",
	"key_jump": "jump",
	"key_ability_alt": "ability_alt",
	"key_scan": "scan",
}

## Numeric keys: [min, max]. Values are clamped into these on set and on load.
const RANGES := {
	"master_volume": [0.0, 1.0],
	"music_volume": [0.0, 1.0],
	"sfx_volume": [0.0, 1.0],
	"brightness": [0.0, 1.0],
	"sensitivity": [0.2, 3.0],
	"fov": [60.0, 100.0],
	"quality": [0, 2],
	"key_crouch": [0, 4194500],
	"key_jump": [0, 4194500],
	"key_ability_alt": [0, 4194500],
	"key_scan": [0, 4194500],
}

## Below this slider position a bus is muted outright.
const MUTE_BELOW := 0.005
const MIN_DB := -80.0
## Slider drags would otherwise write the file every frame.
const SAVE_DELAY := 0.4

## Where the file lives. Tests point this elsewhere through use_path() so they never touch
## the player's real settings.
var path := PATH
## Where a first run looks for the old quality preset (tests point this elsewhere too).
var legacy_path := LEGACY_PREFS

var _values: Dictionary = {}
var _save_timer := -1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	apply_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _save_timer >= 0.0:
			save_now()


func _process(delta: float) -> void:
	if _save_timer < 0.0:
		return
	_save_timer -= delta
	if _save_timer < 0.0:
		save_now()


# ------------------------------------------------------------------ public API

func get_value(key: String):
	if _values.has(key):
		return _values[key]
	if DEFAULTS.has(key):
		return DEFAULTS[key]
	push_warning("Settings: unknown key '%s'" % key)
	return null


## Validate, store, apply, emit `changed` (only when the value really changed), and save
## shortly after. Unknown keys are refused with a warning.
func set_value(key: String, v) -> void:
	if not DEFAULTS.has(key):
		push_warning("Settings: unknown key '%s'" % key)
		return
	var clean = _sanitize(key, v)
	if _values.has(key) and _same(_values[key], clean):
		return
	_values[key] = clean
	_apply(key)
	_save_timer = SAVE_DELAY
	changed.emit(key, clean)


func reset_to_defaults() -> void:
	for key in DEFAULTS.keys():
		set_value(key, DEFAULTS[key])


func save_now() -> void:
	_save_timer = -1.0
	var cfg := ConfigFile.new()
	for key in DEFAULTS.keys():
		cfg.set_value(SECTION, key, get_value(key))
	var err := cfg.save(path)
	if err != OK:
		push_warning("Settings: could not save %s (%s)" % [path, error_string(err)])


## Test seam: switch to another file and load it (missing file means defaults), then apply.
## Emits `changed` for every key so live listeners pick the loaded values up.
func use_path(p: String) -> void:
	path = p
	_values.clear()
	_load()
	apply_all()
	for key in DEFAULTS.keys():
		changed.emit(key, get_value(key))


## Re-read the current file (for tests: proves what was saved round-trips).
func reload() -> void:
	use_path(path)


## Linear slider position (0..1) to bus decibels. Squared amplitude, so the middle of the
## slider sounds like the middle (0.5 is -12 dB, 0.25 is -24 dB) instead of nearly full.
static func slider_to_db(v: float) -> float:
	if v <= MUTE_BELOW:
		return MIN_DB
	return maxf(MIN_DB, linear_to_db(v * v))


func apply_all() -> void:
	for key in DEFAULTS.keys():
		_apply(key)


# ------------------------------------------------------------------ internals

func _load() -> void:
	var cfg := ConfigFile.new()
	var ok := cfg.load(path) == OK
	for key in DEFAULTS.keys():
		if ok and cfg.has_section_key(SECTION, key):
			_values[key] = _sanitize(key, cfg.get_value(SECTION, key))
		else:
			_values[key] = DEFAULTS[key]
	# Migration: the quality preset used to live in prefs.cfg. Take it once, then the
	# new file is the truth.
	if not ok and legacy_path != "":
		var legacy := ConfigFile.new()
		if legacy.load(legacy_path) == OK and legacy.has_section_key("video", "quality"):
			_values["quality"] = _sanitize("quality", legacy.get_value("video", "quality"))
			save_now()


func _sanitize(key: String, v):
	var def = DEFAULTS[key]
	if key == "carry_camera":   # HANDS HOOK
		var c := str(v)
		return c if CARRY_CAMERA_MODES.has(c) else def
	if key == "sprint_mode":
		var sm := str(v)
		return sm if SPRINT_MODES.has(sm) else def
	if key == "window_mode":
		var s := str(v)
		return s if WINDOW_MODES.has(s) else def
	if not (v is int or v is float or v is bool or (v is String and (v as String).is_valid_float())):
		return def
	var r: Array = RANGES[key]
	if def is int:
		return clampi(int(roundf(float(v))), int(r[0]), int(r[1]))
	return clampf(float(v), float(r[0]), float(r[1]))


func _same(a, b) -> bool:
	if a is float and b is float:
		return is_equal_approx(a, b)
	return typeof(a) == typeof(b) and a == b


func _apply(key: String) -> void:
	match key:
		"master_volume":
			_set_bus("Master", float(get_value(key)))
		"sfx_volume":
			_set_bus("SFX", float(get_value(key)))
		"music_volume":
			# The Audio autoload drives the Music bus every frame (base level and the
			# flatline duck), so the player's trim goes through it rather than the bus.
			var audio := get_node_or_null("/root/Audio")
			if audio != null and "music_volume_db" in audio:
				var v := float(get_value(key))
				audio.music_volume_db = slider_to_db(v)
		"window_mode":
			_apply_window_mode()
	if REBIND_ACTIONS.has(key):   # SWEEP 4A HOOK (controls)
		_rebind(String(REBIND_ACTIONS[key]), int(get_value(key)))


## Point an InputMap action's key event at `physical_keycode`, keeping any non-key events
## (mouse buttons, joypad) on the action untouched.
func _rebind(action: String, physical_keycode: int) -> void:
	if not InputMap.has_action(action) or physical_keycode <= 0:
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	var ev := InputEventKey.new()
	ev.physical_keycode = physical_keycode
	InputMap.action_add_event(action, ev)


func _set_bus(bus_name: String, v: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, slider_to_db(v))
	# Warmup mutes Master briefly and restores it; never unmute over it, only mute at zero.
	if bus_name != "Master":
		AudioServer.set_bus_mute(idx, v <= MUTE_BELOW)


func _apply_window_mode() -> void:
	if not _window_control_allowed():
		return
	var mode := str(get_value("window_mode"))
	match mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		"borderless":
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_:
			var cur := DisplayServer.window_get_mode()
			if cur != DisplayServer.WINDOW_MODE_WINDOWED and cur != DisplayServer.WINDOW_MODE_MAXIMIZED:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
				# Coming back from full screen: a sensible window, centred.
				var screen := DisplayServer.window_get_current_screen()
				var usable := DisplayServer.screen_get_usable_rect(screen)
				var want := Vector2i(1600, 900)
				if usable.size.x > 0 and (want.x > usable.size.x or want.y > usable.size.y):
					want = Vector2i(usable.size.x * 0.85, usable.size.y * 0.85)
				DisplayServer.window_set_size(want)
				DisplayServer.window_set_position(usable.position + (usable.size - want) / 2)


## Test tools and screenshot runs choose their own window; only the real game (launched
## without a scene path or window flags) follows the saved window mode.
func _window_control_allowed() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	for a in OS.get_cmdline_args():
		if a.ends_with(".tscn") or a in ["--resolution", "-f", "--fullscreen", "-w", "--windowed", "--position", "-m", "--maximized"]:
			return false
	return true
