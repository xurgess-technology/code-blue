extends CanvasLayer
## The settings screen, over the title menu or the pause overlay, plus the "Settings",
## "Exit to Main Menu" and "Exit to Desktop" buttons shown while paused in a shift (stacked
## under the HUD's "PAUSED" text). main.gd creates one and connects Menu.chose_settings to
## open(), and the two exit signals below to tearing the session down / quitting. Every
## settings control writes straight to the Settings autoload, so a change applies the moment
## it is made; the screen follows Settings.changed, so F2 / F11 stay in sync.
##
##     open() / close() / is_open(), signal closed, exit_to_menu_requested, exit_to_desktop_requested

signal closed
## Pause-only buttons (see _build_pause_button): main.gd connects these to tear the session
## down and return to the menu, or quit the app outright.
signal exit_to_menu_requested
signal exit_to_desktop_requested

const LAYER := 6

const COL_TITLE := Color("d71e28")
const COL_LABEL := Color("cfd6da")
const COL_SECTION := Color("8a9aa0")
const COL_VALUE := Color("9fe8a0")
const COL_HINT := Color("ffd35c")
const COL_DIM := Color("5e6a73")

## key -> {slider, value_label, fmt: Callable}
var _sliders: Dictionary = {}
## key -> {option_value: Button}
var _choices: Dictionary = {}
## SWEEP 4A HOOK (controls): key -> its rebind Button. Click one, press a key.
var _rebind_buttons: Dictionary = {}
var _listening_key: String = ""
var _syncing := false
## The title menu, set by main.gd, so the pause button hides while it is up.
var menu: Control = null

var _root: Control
var _first_focus: Control
var _pause_button: Button
## Pause-only, under the Settings button: end the session and go to the menu, or quit outright.
var _exit_menu_button: Button
var _exit_desktop_button: Button


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_build_pause_button()
	Settings.changed.connect(_on_setting_changed)
	_sync_all()
	_root.visible = false


func open() -> void:
	_sync_all()
	_root.visible = true
	_pause_button.visible = false
	_exit_menu_button.visible = false
	_exit_desktop_button.visible = false
	if _first_focus != null:
		_first_focus.grab_focus()


func close() -> void:
	if not _root.visible:
		return
	var focused := _root.get_viewport().gui_get_focus_owner()
	if focused != null and _root.is_ancestor_of(focused):
		focused.release_focus()
	_root.visible = false
	closed.emit()


func is_open() -> bool:
	return _root != null and _root.visible


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if not is_open():
		return
	# SWEEP 4A HOOK (controls): a rebind row is waiting for the next key. Esc cancels it without
	# changing anything; any other key becomes the new binding.
	if _listening_key != "":
		if event is InputEventKey and event.pressed and not event.echo:
			if int(event.physical_keycode) != KEY_ESCAPE:
				Settings.set_value(_listening_key, int(event.physical_keycode))
			_listening_key = ""
			get_viewport().set_input_as_handled()
		return
	# Esc goes back (to the menu or the pause overlay) instead of resuming the shift, and
	# nothing underneath (pause toggles, Q to walk out) reacts while the screen is up.
	if event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k == KEY_F2 or k == KEY_F3 or k == KEY_F11:
			return   # the global shortcuts still work, and the screen follows them
	if event is InputEventKey or event is InputEventMouseButton:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# The pause overlay is drawn by the HUD; this adds the buttons it needs (Settings, and the
	# two exit buttons below it).
	var game := get_tree().get_first_node_in_group("game")
	var show_pause := false
	if game != null and not is_open():
		var menu_up := menu != null and is_instance_valid(menu) and menu.visible
		show_pause = game.paused and game.phase != Game.Phase.MENU and not menu_up
	if _pause_button.visible != show_pause:
		_pause_button.visible = show_pause
	if _exit_menu_button.visible != show_pause:
		_exit_menu_button.visible = show_pause
	if _exit_desktop_button.visible != show_pause:
		_exit_desktop_button.visible = show_pause


# ------------------------------------------------------------------ building

func _build() -> void:
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.012, 0.016, 0.024, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	# The menu's dark panel, but nearly opaque: whatever is underneath (the title, the pause
	# text) must not read through the options.
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.055, 0.062, 0.075, 0.97)
	box.border_color = Color(1, 1, 1, 0.07)
	box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	panel.add_theme_stylebox_override("panel", box)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	margin.add_child(col)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", COL_TITLE)
	col.add_child(title)

	col.add_child(_section("AUDIO"))
	col.add_child(_slider_row("master_volume", "Master volume", 0.0, 1.0, 0.01, _pct))
	col.add_child(_slider_row("music_volume", "Music", 0.0, 1.0, 0.01, _pct))
	col.add_child(_slider_row("sfx_volume", "Effects", 0.0, 1.0, 0.01, _pct))

	col.add_child(_section("DISPLAY"))
	col.add_child(_choice_row("window_mode", "Window", [
		["fullscreen", "Fullscreen"], ["borderless", "Borderless"], ["windowed", "Windowed"]]))
	col.add_child(_choice_row("quality", "Graphics", [[0, "Low"], [1, "Medium"], [2, "High"]]))
	col.add_child(_slider_row("brightness", "Brightness", 0.0, 1.0, 0.01, _pct))

	col.add_child(_section("CONTROLS"))
	col.add_child(_slider_row("sensitivity", "Mouse sensitivity", 0.2, 3.0, 0.05,
		func(v): return "%.2fx" % v))
	col.add_child(_choice_row("sprint_mode", "Sprint", [["toggle", "Toggle"], ["hold", "Hold"]]))
	col.add_child(_choice_row("carry_camera", "Carry camera", [["shoulder", "Shoulder"], ["first_person", "First person"]]))   # HANDS HOOK
	col.add_child(_slider_row("fov", "Field of view", 60.0, 100.0, 1.0,
		func(v): return "%d°" % roundi(v)))

	col.add_child(_section("KEYS"))   # SWEEP 4A HOOK (controls)
	col.add_child(_rebind_row("key_crouch", "Crouch"))
	col.add_child(_rebind_row("key_jump", "Jump"))
	col.add_child(_rebind_row("key_ability_alt", "Ability modifier"))
	col.add_child(_rebind_row("key_scan", "Scan"))

	var hint := Label.new()
	hint.text = "Changes apply right away.  F2 cycles graphics, F11 toggles fullscreen."
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", COL_SECTION)
	col.add_child(_spacer(2))
	col.add_child(hint)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	col.add_child(buttons)
	var reset := _button("Reset to defaults")
	reset.pressed.connect(func(): Settings.reset_to_defaults())
	buttons.add_child(reset)
	var back := _button("Back")
	back.pressed.connect(close)
	buttons.add_child(back)


func _build_pause_button() -> void:
	# Sits under the HUD's "PAUSED / Esc to resume, Q to walk out" lines (drawn at 40% height).
	_pause_button = _pause_menu_button("Settings", 84, 128)
	_pause_button.name = "PauseSettingsButton"
	_pause_button.pressed.connect(open)

	_exit_menu_button = _pause_menu_button("Exit to Main Menu", 138, 182)
	_exit_menu_button.name = "PauseExitToMenuButton"
	_exit_menu_button.pressed.connect(func(): exit_to_menu_requested.emit())

	_exit_desktop_button = _pause_menu_button("Exit to Desktop", 192, 236)
	_exit_desktop_button.name = "PauseExitToDesktopButton"
	_exit_desktop_button.pressed.connect(func(): exit_to_desktop_requested.emit())


## One of the pause-only buttons stacked under the "PAUSED" text (see _build_pause_button):
## same width/position as the Settings button, offset vertically by the caller.
func _pause_menu_button(text: String, top: int, bottom: int) -> Button:
	var b := _button(text)
	b.size_flags_horizontal = Control.SIZE_FILL
	b.custom_minimum_size = Vector2(200, 44)
	b.anchor_left = 0.5
	b.anchor_right = 0.5
	b.anchor_top = 0.4
	b.anchor_bottom = 0.4
	b.offset_left = -100
	b.offset_right = 100
	b.offset_top = top
	b.offset_bottom = bottom
	b.visible = false
	add_child(b)
	return b


func _section(text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.add_child(_spacer(6))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", COL_SECTION)
	box.add_child(l)
	var line := ColorRect.new()
	line.color = Color(COL_TITLE, 0.5)
	# 2 px: the canvas is scaled down below 1600x900 and a 1 px line drops out.
	line.custom_minimum_size = Vector2(0, 2)
	box.add_child(line)
	return box


func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(170, 0)
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", COL_LABEL)
	return l


func _slider_row(key: String, text: String, lo: float, hi: float, step: float, fmt: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size.y = 32
	row.add_child(_row_label(text))
	var s := HSlider.new()
	s.name = "Slider_" + key
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(0, 24)
	row.add_child(s)
	var val := Label.new()
	val.custom_minimum_size = Vector2(64, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 16)
	val.add_theme_color_override("font_color", COL_VALUE)
	row.add_child(val)
	s.value_changed.connect(func(v: float):
		val.text = fmt.call(v)
		if not _syncing:
			Settings.set_value(key, v))
	_sliders[key] = {"slider": s, "label": val, "fmt": fmt}
	if _first_focus == null:
		_first_focus = s
	return row


## SWEEP 4A HOOK (controls): a row with a button that shows the current key; click it, then press
## any key to rebind (Esc cancels). Consistent with _slider_row / _choice_row: writes straight to
## Settings, which applies it to the InputMap action immediately (Settings.REBIND_ACTIONS).
func _rebind_row(key: String, text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size.y = 32
	row.add_child(_row_label(text))
	var b := Button.new()
	b.name = "Rebind_" + key
	b.custom_minimum_size = Vector2(140, 30)
	b.add_theme_font_size_override("font_size", 15)
	_style_button(b)
	b.pressed.connect(func():
		_listening_key = key
		b.text = "Press a key…")
	row.add_child(b)
	_rebind_buttons[key] = b
	if _first_focus == null:
		_first_focus = b
	return row


func _key_name(keycode: int) -> String:
	return OS.get_keycode_string(keycode) if keycode > 0 else "?"


func _choice_row(key: String, text: String, options: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_row_label(text))
	var group := ButtonGroup.new()
	var map := {}
	for opt in options:
		var b := Button.new()
		b.name = "Choice_%s_%s" % [key, str(opt[0])]
		b.text = opt[1]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 34)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 15)
		b.add_theme_color_override("font_pressed_color", COL_VALUE)
		b.add_theme_color_override("font_hover_pressed_color", COL_VALUE)
		_style_button(b)
		b.add_theme_stylebox_override("pressed", _pressed_box())
		b.add_theme_stylebox_override("hover_pressed", _pressed_box())
		var value = opt[0]
		b.toggled.connect(func(on: bool):
			if on and not _syncing:
				Settings.set_value(key, value))
		row.add_child(b)
		map[value] = b
	_choices[key] = map
	return row


func _pressed_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.16, 0.11, 0.95)
	sb.border_color = Color(COL_VALUE, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	return sb


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(160, 42)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 17)
	_style_button(b)
	return b


## Dark boxes that stay visible on the dark panel and over the game.
func _style_button(b: Button) -> void:
	var states := {
		"normal": [Color(0.13, 0.145, 0.17, 0.95), Color(1, 1, 1, 0.10)],
		"hover": [Color(0.18, 0.2, 0.235, 0.98), Color(1, 1, 1, 0.22)],
		"pressed": [Color(0.09, 0.1, 0.12, 0.98), Color(COL_TITLE, 0.7)],
		"focus": [Color(0, 0, 0, 0), Color(COL_HINT, 0.55)],
	}
	for state in states.keys():
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[state][0]
		sb.border_color = states[state][1]
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		if state == "focus":
			sb.draw_center = false
		b.add_theme_stylebox_override(state, sb)


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = h
	return s


func _pct(v: float) -> String:
	return "%d%%" % roundi(v * 100.0)


# ------------------------------------------------------------------ syncing

func _sync_all() -> void:
	for key in _sliders.keys():
		_on_setting_changed(key, Settings.get_value(key))
	for key in _choices.keys():
		_on_setting_changed(key, Settings.get_value(key))
	for key in _rebind_buttons.keys():
		_on_setting_changed(key, Settings.get_value(key))


func _on_setting_changed(key: String, value) -> void:
	_syncing = true
	if _sliders.has(key):
		var e: Dictionary = _sliders[key]
		(e.slider as HSlider).set_value_no_signal(float(value))
		(e.label as Label).text = e.fmt.call(float(value))
	elif _choices.has(key):
		var map: Dictionary = _choices[key]
		for opt in map.keys():
			(map[opt] as Button).set_pressed_no_signal(str(opt) == str(value))
	elif _rebind_buttons.has(key):   # SWEEP 4A HOOK (controls)
		(_rebind_buttons[key] as Button).text = _key_name(int(value))
	_syncing = false
