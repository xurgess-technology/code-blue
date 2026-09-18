extends CanvasLayer
## The settings screen, a page on the fax like everything else (scripts/fax_printer.gd), and the
## in-shift pause menu.
##
##   Title menu: Settings ejects the sign-in sheet off the top and the settings sheet feeds up out of
##   the same printer as the next page; Back ejects it and a fresh sign-in sheet feeds up in turn.
##
##   In a shift: Esc (main.gd _toggle_pause -> open_pause) pauses, the printer rises from the bottom
##   of the screen and the settings sheet feeds up out of its slot, with the pause buttons on the page
##   (Resume, Main menu, Quit game). Leaving (Esc or Resume) fires `closed` at once (main.gd unpauses
##   and captures the mouse: the shift has control straight back) while the sheet ejects off the top
##   and the printer sinks off the bottom; `gone` fires once they have. Esc again before then turns the
##   same printer and page around. Main menu (leave_to_menu) ejects the page over the title's printer
##   and the sign-in sheet feeds in after it. The game stays visible either side of the paper.
##
## Every control writes straight to the Settings autoload, so a change applies the moment it is
## made; the page follows Settings.changed, so F2 / F11 stay in sync.
##
##     open() / open_pause() / close() / is_open() / leave_to_menu(), signal closed, signal gone,
##     exit_to_menu_requested, exit_to_desktop_requested

## The page was dismissed (Esc, Resume, Back): the moment it happens, before it has animated away.
signal closed
## The page and (in a shift) the printer have left the screen.
signal gone
## Pause-only buttons: main.gd connects these to tear the session down and return to the menu, or
## quit the app outright.
signal exit_to_menu_requested
signal exit_to_desktop_requested

const Fax := preload("res://scripts/fax_printer.gd")

## Over the title menu (51, which sits above the look pass's grain at 50).
const LAYER := 52
const ROW_FONT := 16
const ROW_H := 26.0
const COL_GAP := 26.0
const LABEL_W := 96.0
const BOTTOM_PAD := 22.0
const PAGE_MARGIN := 30.0
## Motions and their timings are the shared ones in scripts/fax_printer.gd (Fax.FEED_SECONDS etc.).
## Pausing, the page starts feeding once the rising printer is this far up.
const FEED_AFTER_RISE := 0.3
const MACHINE_LABEL := "DOE GENERAL  /  STAFF SETTINGS"

## key -> {slider, label, fmt: Callable}
var _sliders: Dictionary = {}
## key -> {option_value: Button}
var _choices: Dictionary = {}
## SWEEP 4A HOOK (controls): key -> its rebind Button. Click one, press a key.
var _rebind_buttons: Dictionary = {}
var _listening_key: String = ""
var _syncing := false
## The title menu, set by main.gd: hidden while this page stands in for it.
var menu: Control = null

var _font: Font
var _root: Control
var _canvas: Control
var _clip: Control
var _sheet: VBoxContainer
var _first_focus: Control
var _status: Label
## Pause-only, on the page: Resume, end the session and go to the menu, quit outright.
var _pause_button: Button
var _exit_menu_button: Button
var _exit_desktop_button: Button
var _reset_button: Button
var _reset_tips_button: Button
var _back_button: Button

var _open := false
var _mode := ""          # "menu": over the title menu, printer standing | "game": over a shift, printer rises
var _printer := Fax.Motion.new(0.0)   # 1 standing in place, 0 sunk off the bottom (menu: always 1)
var _feed := Fax.Motion.new(0.0)      # 0 inside the slot, 1 standing out of it at rest
var _lift := Fax.Motion.new(0.0)      # 0 where the feed has it, 1 ejected off the top
var _lift_from := 0.0                 # how far below rest the page was when it started ejecting
var _feed_wait := 0.0                 # seconds until the page starts feeding (the printer rising first)
var _feed_tick := 0.0
var _opening := false    # menu: waiting for the sign-in sheet to eject
var _grabber: ImageTexture


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = Fax.make_font()
	_build()
	_fit()
	get_viewport().size_changed.connect(_fit)
	Settings.changed.connect(_on_setting_changed)
	_sync_all()
	_root.visible = false


func _fit() -> void:
	Fax.fit_layer(self, _root)


## Settings from the title menu (or, with no menu up, over the game without pausing it).
func open() -> void:
	if _opening or _open or (_root.visible and _mode == "menu"):
		return   # already up, or still leaving for the sign-in sheet
	if menu != null and is_instance_valid(menu) and menu.visible:
		_opening = true
		menu.eject(func():
			_opening = false
			menu.visible = false
			_show("menu", false))
	else:
		_show("game", false)


## Esc in a shift: the pause menu. main.gd has already set game.paused.
func open_pause() -> void:
	_show("game", true)


func _show(mode: String, pause: bool) -> void:
	_sync_all()
	# Sent away and called back before it had gone: the same printer and page turn around.
	var returning := _root.visible and not _open and mode == _mode
	_open = true
	_mode = mode
	_root.visible = true
	_listening_key = ""
	for b in [_pause_button, _exit_menu_button, _exit_desktop_button]:
		b.visible = pause
	_back_button.visible = not pause
	_status.text = "SHIFT PAUSED" if pause else ""
	_set_live(true)
	if mode == "menu":
		var page: int = int(menu.page_no) + 1 if menu != null and is_instance_valid(menu) else 3
		_status.text = "PAGE %d" % page
		_status.add_theme_color_override("font_color", Color(Fax.INK_FAINT, 0.92))
		# The title's printer is already standing: just the next page, up out of its slot.
		_printer.snap(1.0)
		_lift.snap(0.0)
		_feed.snap(0.0)
		_feed.go(1.0, Fax.FEED_SECONDS, true)
		_feed_wait = 0.0
	else:
		_status.add_theme_color_override("font_color", Color(Fax.STAMP_INK, 0.92))
		if not returning:
			_lift.snap(0.0)
			_feed.snap(0.0)
		# The machine rises in from below; the page starts feeding once it is most of the way up.
		_feed_wait = maxf(0.0, (FEED_AFTER_RISE - _printer.value) * Fax.RISE_SECONDS)
		_printer.go(1.0, Fax.RISE_SECONDS, true)
		_lift.go(0.0, Fax.EJECT_SECONDS, true)
		_feed.go(1.0, Fax.FEED_SECONDS, true)
	_feed_tick = _feed_wait
	Fax.sfx("print_feed", -8.0)
	_layout()
	if _first_focus != null:
		_first_focus.grab_focus.call_deferred()


func close() -> void:
	if not _open:
		return
	_open = false
	_send_away()
	if _mode == "game":
		_printer.go(0.0, Fax.DROP_SECONDS, false)
	closed.emit()
	if Fax.headless():
		_finish_close()


## Main menu from the pause page (main.gd _back_to_menu): the session is gone underneath and the title
## menu (its room and printer, standing where this one stands) is up below with its sheet held in the
## printer. This page ejects off the top, then the sign-in sheet feeds in. False if no pause page is up.
func leave_to_menu() -> bool:
	if not _root.visible or _mode != "game":
		return false
	var was_open := _open
	_open = false
	_mode = "menu"
	_printer.snap(1.0)
	_send_away()
	if was_open:
		closed.emit()
	if Fax.headless():
		_finish_close()
	return true


## The page leaves: from wherever it is (even half fed in) it accelerates up and off the top.
func _send_away() -> void:
	_listening_key = ""
	_set_live(false)
	var focused := _root.get_viewport().gui_get_focus_owner()
	if focused != null and _root.is_ancestor_of(focused):
		focused.release_focus()
	_feed.snap(_feed.value)
	_feed_wait = 0.0
	_lift_from = (1.0 - _feed.value) * _feed_dist()
	_lift.go(1.0, Fax.EJECT_SECONDS, false)
	Fax.sfx("print_feed", -8.0)


## Controls on the page answer the mouse and keyboard focus only while it is up: on its way out the
## clicks (a captured mouse in a shift) go to the game.
func _set_live(on: bool) -> void:
	_clip.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED if on else Control.MOUSE_BEHAVIOR_DISABLED
	_clip.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if on else Control.FOCUS_BEHAVIOR_DISABLED
	_root.mouse_filter = Control.MOUSE_FILTER_STOP if on and _mode == "menu" else Control.MOUSE_FILTER_IGNORE


func _finish_close() -> void:
	_root.visible = false
	_printer.snap(0.0)
	_feed.snap(0.0)
	_lift.snap(0.0)
	var was := _mode
	_mode = ""
	if was == "menu" and menu != null and is_instance_valid(menu):
		menu.visible = true
		menu.feed_in(0.0, 0.0, int(menu.page_no) + 2)   # a fresh sign-in sheet, the page after this one
	gone.emit()


func is_open() -> bool:
	return _open


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if not _open:
		# On its way out. In a shift control is already back (Esc again reopens it through main.gd);
		# over the title nothing underneath is showing yet.
		if _mode == "menu" and (event is InputEventKey or event is InputEventMouseButton):
			get_viewport().set_input_as_handled()
		return
	# SWEEP 4A HOOK (controls): a rebind row is waiting for the next key. Esc cancels it without
	# changing anything; any other key becomes the new binding.
	if _listening_key != "":
		if event is InputEventKey and event.pressed and not event.echo:
			if int(event.physical_keycode) != KEY_ESCAPE:
				Settings.set_value(_listening_key, int(event.physical_keycode))
			_listening_key = ""
			_sync_all()
			get_viewport().set_input_as_handled()
		return
	# Esc goes back (to the menu, or out of the pause into the shift), and nothing underneath (pause
	# toggles, walking out) reacts while the page is up.
	if event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k == KEY_F2 or k == KEY_F3 or k == KEY_F5 or k == KEY_F11:
			return   # the global shortcuts still work, and the page follows them
	if event is InputEventKey or event is InputEventMouseButton:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _root.visible:
		return
	if _mode == "game":
		var game := get_tree().get_first_node_in_group("game")
		# The session ended underneath without leave_to_menu (walked out, host left): nothing to
		# animate away over.
		if game == null or game.phase == Game.Phase.MENU:
			if _open:
				_open = false
				closed.emit()
			_finish_close()
			return
	var dt := Fax.ui_dt(delta)
	_printer.step(dt)
	_lift.step(dt)
	if _feed_wait > 0.0:
		_feed_wait -= dt
	else:
		_feed.step(dt)
		if _open and _feed.moving():
			_feed_tick -= dt
			if _feed_tick <= 0.0 and _feed.value < 0.85:
				_feed_tick = Fax.FEED_TICK
				Fax.sfx("print_feed", -14.0, 0.1)
	_layout()
	if not _open and _lift.at(1.0) and (_mode == "menu" or _printer.at(0.0)):
		_finish_close()


# ------------------------------------------------------------------ building

func _build() -> void:
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_root.resized.connect(_layout)

	_canvas = Control.new()
	_canvas.name = "Paper"
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_paper)
	_root.add_child(_canvas)

	_clip = Control.new()
	_clip.name = "Sheet"
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_clip)

	var img := Image.create(10, 18, false, Image.FORMAT_RGBA8)
	img.fill(Fax.INK)
	_grabber = ImageTexture.create_from_image(img)

	_sheet = VBoxContainer.new()
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_theme_constant_override("separation", 2)
	_clip.add_child(_sheet)

	var dt := Time.get_datetime_dict_from_system()
	var head := _row()
	head.add_child(_ink(">> FAX  %04d-%02d-%02d  %02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute], 16, Fax.INK_FAINT))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	_status = _ink("", 16, Fax.STAMP_INK)
	head.add_child(_status)
	_sheet.add_child(head)
	_sheet.add_child(_ink("STAFF SETTINGS", Fax.FONT_SIZE, Fax.INK))
	_sheet.add_child(_rule())

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", int(COL_GAP))
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(cols)
	var left := _column()
	var right := _column()
	cols.add_child(left)
	cols.add_child(right)

	left.add_child(_section("AUDIO"))
	left.add_child(_slider_row("master_volume", "Master", 0.0, 1.0, 0.01, _pct))
	left.add_child(_slider_row("music_volume", "Music", 0.0, 1.0, 0.01, _pct))
	left.add_child(_slider_row("sfx_volume", "Effects", 0.0, 1.0, 0.01, _pct))
	left.add_child(_section("DISPLAY"))
	left.add_child(_choice_row("window_mode", "Window", [
		["fullscreen", "FULL"], ["borderless", "BORDER"], ["windowed", "WINDOW"]]))
	left.add_child(_choice_row("quality", "Graphics", [[0, "LOW"], [1, "MED"], [2, "HIGH"]]))
	left.add_child(_slider_row("brightness", "Bright", 0.0, 1.0, 0.01, _pct))

	right.add_child(_section("CONTROLS"))
	right.add_child(_slider_row("sensitivity", "Mouse", 0.2, 3.0, 0.05, func(v): return "%.2fx" % v))
	right.add_child(_slider_row("fov", "FOV", 60.0, 100.0, 1.0, func(v): return "%d°" % roundi(v)))
	right.add_child(_choice_row("sprint_mode", "Sprint", [["toggle", "TOGGLE"], ["hold", "HOLD"]]))
	right.add_child(_choice_row("camera", "Camera", [["first_person", "FIRST"], ["shoulder", "SHOULDER"]]))
	right.add_child(_choice_row("carry_camera", "Carrying", [["shoulder", "SHOULDER"], ["first_person", "FIRST"]]))   # HANDS HOOK
	right.add_child(_section("KEYS"))   # SWEEP 4A HOOK (controls)
	right.add_child(_rebind_row("key_crouch", "Crouch"))
	right.add_child(_rebind_row("key_jump", "Jump"))
	right.add_child(_rebind_row("key_ability_alt", "Ability"))
	right.add_child(_rebind_row("key_scan", "Scan"))

	_sheet.add_child(_rule())
	_sheet.add_child(_ink("Changes apply right away.  F2 cycles graphics, F5 the camera, F11 fullscreen.", 14, Fax.INK_FAINT))
	var space := Control.new()
	space.custom_minimum_size.y = 6
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(space)

	var buttons := _row()
	buttons.add_theme_constant_override("separation", 14)
	_pause_button = _button("RESUME", close)
	_pause_button.name = "PauseResumeButton"
	buttons.add_child(_pause_button)
	_reset_button = _button("RESET", func(): Settings.reset_to_defaults())
	buttons.add_child(_reset_button)
	# Every tip on the tip fax (scripts/tips/tip_fax.gd) shows again the next time it comes up.
	_reset_tips_button = _button("RESET TIPS", _reset_tips)
	_reset_tips_button.name = "ResetTipsButton"
	buttons.add_child(_reset_tips_button)
	_back_button = _button("BACK", close)
	buttons.add_child(_back_button)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.add_child(push)
	_exit_menu_button = _button("MAIN MENU", func(): exit_to_menu_requested.emit())
	_exit_menu_button.name = "PauseExitToMenuButton"
	buttons.add_child(_exit_menu_button)
	_exit_desktop_button = _button("QUIT GAME", func(): exit_to_desktop_requested.emit())
	_exit_desktop_button.name = "PauseExitToDesktopButton"
	buttons.add_child(_exit_desktop_button)
	_sheet.add_child(buttons)


func _reset_tips() -> void:
	var tips := get_tree().get_first_node_in_group("tip_fax")
	if tips != null:
		tips.reset_seen()
	_reset_tips_button.text = "TIPS RESET"
	get_tree().create_timer(1.5, true).timeout.connect(func():
		if is_instance_valid(_reset_tips_button):
			_reset_tips_button.text = "RESET TIPS")


func _column() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _ink(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(col, 0.92))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _rule() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 16)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func(): Fax.draw_rule(c, 0.0, c.size.y * 0.5, c.size.x, 1.0))
	return c


func _section(text: String) -> Control:
	var l := _ink(text, 14, Fax.INK_FAINT)
	l.custom_minimum_size.y = 24
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func _row_label(text: String) -> Label:
	var l := _ink(text, ROW_FONT, Fax.INK)
	l.custom_minimum_size = Vector2(LABEL_W, 0)
	return l


func _slider_row(key: String, text: String, lo: float, hi: float, step: float, fmt: Callable) -> Control:
	var row := _row()
	row.custom_minimum_size.y = ROW_H
	row.add_child(_row_label(text))
	var s := HSlider.new()
	s.name = "Slider_" + key
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(0, 20)
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(Fax.INK, 0.35)
	groove.content_margin_top = 1
	groove.content_margin_bottom = 1
	var filled := groove.duplicate() as StyleBoxFlat
	filled.bg_color = Color(Fax.INK, 0.85)
	s.add_theme_stylebox_override("slider", groove)
	s.add_theme_stylebox_override("grabber_area", filled)
	s.add_theme_stylebox_override("grabber_area_highlight", filled)
	s.add_theme_icon_override("grabber", _grabber)
	s.add_theme_icon_override("grabber_highlight", _grabber)
	s.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	row.add_child(s)
	var val := _ink("", ROW_FONT, Fax.INK)
	val.custom_minimum_size = Vector2(52, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	s.value_changed.connect(func(v: float):
		val.text = fmt.call(v)
		if not _syncing:
			Settings.set_value(key, v))
	_sliders[key] = {"slider": s, "label": val, "fmt": fmt}
	if _first_focus == null:
		_first_focus = s
	return row


## SWEEP 4A HOOK (controls): a row with a box showing the current key; click it, then press any key
## to rebind (Esc cancels). Writes straight to Settings, which applies it to the InputMap action.
func _rebind_row(key: String, text: String) -> Control:
	var row := _row()
	row.custom_minimum_size.y = ROW_H
	row.add_child(_row_label(text))
	var b := Button.new()
	b.name = "Rebind_" + key
	b.custom_minimum_size = Vector2(120, 22)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_ink_button(b, ROW_FONT - 1)
	b.pressed.connect(func():
		_listening_key = key
		b.text = "PRESS A KEY")
	row.add_child(b)
	_rebind_buttons[key] = b
	return row


func _key_name(keycode: int) -> String:
	return OS.get_keycode_string(keycode).to_upper() if keycode > 0 else "?"


func _choice_row(key: String, text: String, options: Array) -> Control:
	var row := _row()
	row.custom_minimum_size.y = ROW_H
	row.add_theme_constant_override("separation", 4)
	row.add_child(_row_label(text))
	var group := ButtonGroup.new()
	var map := {}
	for opt in options:
		var b := Button.new()
		b.name = "Choice_%s_%s" % [key, str(opt[0])]
		b.text = opt[1]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_style_ink_button(b, ROW_FONT - 2)
		b.add_theme_color_override("font_color", Color(Fax.INK_FAINT, 0.8))
		var ticked := StyleBoxFlat.new()
		ticked.bg_color = Color(Fax.STAMP_INK, 0.08)
		ticked.border_color = Color(Fax.STAMP_INK, 0.85)
		ticked.set_border_width_all(2)
		ticked.content_margin_left = 4
		ticked.content_margin_right = 4
		for st in ["pressed", "hover_pressed"]:
			b.add_theme_stylebox_override(st, ticked)
		for st in ["font_pressed_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(st, Fax.STAMP_INK)
		var value = opt[0]
		b.toggled.connect(func(on: bool):
			if on and not _syncing:
				Settings.set_value(key, value))
		row.add_child(b)
		map[value] = b
	_choices[key] = map
	return row


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	_style_ink_button(b, Fax.FONT_SIZE - 1)
	b.pressed.connect(on_press)
	return b


## Ink on paper: a thin ink border, red on hover and focus.
func _style_ink_button(b: Button, size: int) -> void:
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Fax.INK)
	for st in ["font_hover_color", "font_focus_color", "font_pressed_color"]:
		b.add_theme_color_override(st, Fax.STAMP_INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(Fax.INK, 0.75)
	sb.set_border_width_all(2)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	var hot := sb.duplicate() as StyleBoxFlat
	hot.border_color = Color(Fax.STAMP_INK, 0.9)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("pressed", hot)
	b.add_theme_stylebox_override("hover", hot)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _pct(v: float) -> String:
	return "%d%%" % roundi(v * 100.0)


# ------------------------------------------------------------------ layout and drawing

## How far the printer has sunk below its place (0 standing, off the bottom of the screen at 1).
func _printer_drop(l: Dictionary) -> float:
	return (1.0 - _printer.value) * Fax.printer_gone_px(_root.size, l)


## From just inside the slot up to rest: the page's whole height and its margins.
func _feed_dist() -> float:
	return _sheet.get_combined_minimum_size().y + BOTTOM_PAD + PAGE_MARGIN


## How far above its resting place the page is: negative while still down in the printer (riding with
## it as it rises or sinks), then up past the top of the screen as it ejects.
func _page_up(l: Dictionary, drop: float) -> float:
	var up := -(1.0 - _feed.value) * _feed_dist()
	up += _lift.value * (float(l.slot_y) + _lift_from + PAGE_MARGIN + 20.0)
	return up - drop * (1.0 - _lift.value)


func _layout() -> void:
	if _sheet == null or _root == null:
		return
	var l := Fax.layout(_root.size, _font)
	var drop := _printer_drop(l)
	var h := _sheet.get_combined_minimum_size().y
	var rest_y: float = float(l.slot_y) - h - BOTTOM_PAD
	_clip.position = Vector2(l.px, 0.0)
	_clip.size = Vector2(l.paper_w, float(l.slot_y) + drop)
	_sheet.position = Vector2(Fax.MARGIN, rest_y - _page_up(l, drop))
	_sheet.size = Vector2(l.text_w, h)
	_canvas.queue_redraw()


func _draw_paper() -> void:
	var sz := _canvas.size
	var l := Fax.layout(sz, _font)
	var drop := _printer_drop(l)
	var menu_mode := _mode == "menu"
	if menu_mode:
		_canvas.draw_rect(Rect2(Vector2.ZERO, sz), Fax.ROOM)
	# A page its own size (a margin above its first line, a pad below its last), feeding up out of the
	# slot: below the slot it is inside the printer.
	var page_top := _sheet.position.y - PAGE_MARGIN
	var page_bottom := minf(_sheet.position.y + _sheet.size.y + BOTTOM_PAD, float(l.slot_y) + drop)
	Fax.draw_paper(_canvas, sz, l, _page_up(l, drop) + _feed_dist(), 1.0, page_bottom, false, page_top)
	var status := "RECEIVING"
	if not _open:
		status = "RECEIVING" if menu_mode else "RESUMING"
	elif _feed.at(1.0) and _printer.at(1.0):
		status = "PAUSED" if _pause_button.visible else "SETTINGS"
	Fax.draw_printer(_canvas, sz, l, _font, float(l.tx), status, Fax.LCD_TEXT, 1.0, drop, MACHINE_LABEL)


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
