class_name Menu
extends Control
## Title screen: pick a name, then play solo, host, or join.

signal chose_solo(player_name: String)
signal chose_host(player_name: String)
signal chose_join(player_name: String, address: String)
## Settings hook: the Settings button; main.gd opens the settings screen.
signal chose_settings

## DEV HOOK (scripts/dev): Solo or Host while the secret code is armed. host = true to host.
signal chose_dev(player_name: String, host: bool)

const DevCodeScript := preload("res://scripts/dev/dev_code.gd")

var dev_code: Node = null
var _name_edit: LineEdit
var _addr_edit: LineEdit
var _status: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color("06080c")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.remove_child(col)
	margin.add_child(col)
	panel.add_child(margin)

	var title := Label.new()
	title.text = "CODE BLUE"
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color("d71e28"))
	col.add_child(title)
	# DEV HOOK: the dev room's secret code listens here; armed, the title turns blue.
	dev_code = DevCodeScript.new()
	dev_code.name = "DevCode"
	add_child(dev_code)
	dev_code.armed_changed.connect(func(on): title.add_theme_color_override("font_color", Color("2f7bff") if on else Color("d71e28")))
	bg.gui_input.connect(_on_background_input)

	var tag := Label.new()
	tag.text = "Clock in. Find the tools. Save the patient.\nTry not to shove each other into the monsters."
	tag.add_theme_font_size_override("font_size", 15)
	tag.add_theme_color_override("font_color", Color("8a9aa0"))
	col.add_child(tag)

	col.add_child(_spacer(8))

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Your name"
	_name_edit.max_length = 16
	_name_edit.text = _load_pref("name", "Surgeon %d" % (randi() % 90 + 10))
	col.add_child(_labelled("YOUR NAME", _name_edit))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	var solo := _button("Solo shift")
	var host := _button("Host a shift")
	row.add_child(solo)
	row.add_child(host)
	# Settings hook: not in _buttons, so it stays usable while a join is pending.
	var settings := _button("Settings")
	settings.name = "SettingsButton"
	settings.pressed.connect(func(): chose_settings.emit())
	row.add_child(settings)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 10)
	col.add_child(row2)
	_addr_edit = LineEdit.new()
	_addr_edit.placeholder_text = "host address, e.g. 192.168.1.20"
	_addr_edit.text = _load_pref("addr", "")
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(_addr_edit)
	var join := _button("Join")
	join.size_flags_horizontal = Control.SIZE_SHRINK_END
	row2.add_child(join)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color("ffd35c"))
	_status.custom_minimum_size.y = 22
	col.add_child(_status)

	var help := Label.new()
	help.text = "Hosting listens on port %d. Friends on your network join with the address shown once you are in.\nOver the internet, forward that port or put everyone on Tailscale." % C.DEFAULT_PORT
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color("7a8790"))
	col.add_child(help)

	var controls := Label.new()
	controls.text = "WASD move · mouse look · Shift sprint · F flashlight · E interact · Q shove · G drop · Esc pause · F11 fullscreen"
	controls.add_theme_font_size_override("font_size", 12)
	controls.add_theme_color_override("font_color", Color("5e6a73"))
	col.add_child(controls)

	_buttons = [solo, host, join]
	solo.pressed.connect(_on_solo)
	host.pressed.connect(_on_host)
	join.pressed.connect(_on_join)
	_addr_edit.text_submitted.connect(func(_t): _on_join())
	_name_edit.text_submitted.connect(func(_t): _on_solo())


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size.y = h
	return s


func _labelled(text: String, child: Control) -> Control:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color("8a9aa0"))
	box.add_child(l)
	box.add_child(child)
	return box


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(160, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 17)
	return b


func player_name() -> String:
	var n := _name_edit.text.strip_edges().substr(0, 16)
	return n if not n.is_empty() else "Surgeon"


func show_menu(message: String = "") -> void:
	visible = true
	_status.text = message
	set_enabled(true)


func hide_menu() -> void:
	visible = false


func set_status(text: String) -> void:
	_status.text = text


func set_enabled(on: bool) -> void:
	for b in _buttons:
		b.disabled = not on


func _on_solo() -> void:
	_save_prefs()
	set_enabled(false)
	if _dev_start(false):  # DEV HOOK
		return
	chose_solo.emit(player_name())


func _on_host() -> void:
	_save_prefs()
	set_enabled(false)
	if _dev_start(true):  # DEV HOOK
		return
	chose_host.emit(player_name())


## DEV HOOK: armed by the secret code, Solo and Host open the dev room (once; it disarms).
func _dev_start(host: bool) -> bool:
	if dev_code == null or not dev_code.armed:
		return false
	dev_code.set_armed(false, false)
	chose_dev.emit(player_name(), host)
	return true


## Clicking the empty background lets go of a text field (so typing reaches the menu again).
func _on_background_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		get_viewport().gui_release_focus()


func _on_join() -> void:
	_save_prefs()
	if _addr_edit.text.strip_edges().is_empty():
		_status.text = "Type the host's address first."
		return
	set_enabled(false)
	chose_join.emit(player_name(), _addr_edit.text)


# Preferences live in a tiny config file next to the save data.
func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("menu", "name", _name_edit.text)
	cfg.set_value("menu", "addr", _addr_edit.text)
	cfg.save("user://prefs.cfg")


func _load_pref(key: String, fallback: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://prefs.cfg") != OK:
		return fallback
	return cfg.get_value("menu", key, fallback)
