extends CanvasLayer
## The settings screen, over the title menu or the pause overlay, plus the "Settings" button
## shown while paused in a shift. main.gd creates one and connects Menu.chose_settings to
## open(). Every control writes straight to the Settings autoload, so a change applies the
## moment it is made; the screen follows Settings.changed, so F2 / F11 stay in sync.
##
##     open() / close() / is_open(), signal closed

signal closed

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
var _syncing := false
## The title menu, set by main.gd, so the pause button hides while it is up.
var menu: Control = null

var _root: Control
var _first_focus: Control
var _pause_button: Button


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
	# The pause overlay is drawn by the HUD; this adds the one button it needs.
	var game := get_tree().get_first_node_in_group("game")
	var show_pause := false
	if game != null and not is_open():
		var menu_up := menu != null and is_instance_valid(menu) and menu.visible
		show_pause = game.paused and game.phase != Game.Phase.MENU and not menu_up
	if _pause_button.visible != show_pause:
		_pause_button.visible = show_pause


# ------------------------------------------------------------------ building

func _build() -> void:
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.012, 0.016, 0.024, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
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
	col.add_child(_slider_row("fov", "Field of view", 60.0, 100.0, 1.0,
		func(v): return "%d°" % roundi(v)))

	var hint := Label.new()
	hint.text = "Changes apply right away.  F2 cycles graphics, F11 toggles fullscreen."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", COL_DIM)
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
	_pause_button = _button("Settings")
	_pause_button.name = "PauseSettingsButton"
	_pause_button.size_flags_horizontal = Control.SIZE_FILL
	_pause_button.custom_minimum_size = Vector2(200, 44)
	_pause_button.anchor_left = 0.5
	_pause_button.anchor_right = 0.5
	_pause_button.anchor_top = 0.4
	_pause_button.anchor_bottom = 0.4
	_pause_button.offset_left = -100
	_pause_button.offset_right = 100
	_pause_button.offset_top = 84
	_pause_button.offset_bottom = 128
	_pause_button.visible = false
	_pause_button.pressed.connect(open)
	add_child(_pause_button)


func _section(text: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.add_child(_spacer(6))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", COL_SECTION)
	box.add_child(l)
	var line := ColorRect.new()
	line.color = Color(COL_TITLE, 0.45)
	line.custom_minimum_size = Vector2(0, 1)
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
	return b


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
	_syncing = false
