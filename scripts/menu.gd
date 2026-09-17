class_name Menu
extends Control
## Title screen: the night-shift sign-in sheet, page 2 of the launch fax. Pick a name, then tick
## solo, host, or join.
##
## Same paper as the launch printout (scripts/fax_printer.gd). At launch, main.gd hands over with
## feed_in() once the stamped admission page has ejected off the top: this sheet, the next page, feeds
## up out of the printer and slows to a stop, standing out of the slot; so does every fresh sheet after
## settings, a failed start or Main menu from the pause page (docs/FAX.md). The choices are real
## Buttons and LineEdits (focus, keyboard, disabled all work) drawn as ink on the paper.

signal chose_solo(player_name: String)
signal chose_host(player_name: String)
signal chose_join(player_name: String, address: String)
## Settings hook: the Settings button; main.gd opens the settings screen.
signal chose_settings

signal chose_host_steam(player_name: String)

## DEV HOOK (scripts/dev): Solo or Host while the secret code is armed. host = true to host.

const Fax := preload("res://scripts/fax_printer.gd")

## Feeding up out of the printer and ejecting off the top take Fax.FEED_SECONDS / Fax.EJECT_SECONDS.
const OPTION_H := 34.0
## Paper left above the sheet's first line, and between its last line and the printer's slot.
const PAGE_MARGIN := 30.0
const BOTTOM_PAD := 22.0

var _name_edit: LineEdit
var _addr_edit: LineEdit
var _status: Label
var _note_tag: Label
var _header: Label
var _buttons: Array[Button] = []
var _options: Array = []

var _font: Font
var _canvas: Control   # the room, the paper and (while feeding in) the printer
var _clip: Control     # the paper above the printer; the sheet feeds up inside it
var _sheet: VBoxContainer
var _title: Control
var _over: Control     # the top fade, over the sheet
var _title_ink := Fax.STAMP_INK

var _base_scroll := 0.0
## 0 = the sheet still inside the printer, 1 = standing at rest out of the slot.
var _feed := Fax.Motion.new(1.0)
## 0 = at rest (or wherever the feed left it), 1 = gone off the top of the screen.
var _lift := Fax.Motion.new(0.0)
var _lift_from := 0.0   # how far below rest the sheet was when it started ejecting
## The fax page this sheet is (its header), and the one after it goes to whatever replaces it.
var page_no := 2
var _eject_done: Array[Callable] = []
var _feed_tick := 0.0


func _ready() -> void:
	_font = Fax.make_font()
	_fit()
	get_viewport().size_changed.connect(_fit)
	_build()
	resized.connect(_layout)
	_layout.call_deferred()


## Drawn at the fax screens' scale (the menu's own CanvasLayer, set up in main.gd).
func _fit() -> void:
	var layer := get_parent() as CanvasLayer
	if layer != null:
		Fax.fit_layer(layer, self)
	else:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build() -> void:
	_canvas = Control.new()
	_canvas.name = "Paper"
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_paper)
	_canvas.gui_input.connect(_on_background_input)
	add_child(_canvas)

	_clip = Control.new()
	_clip.name = "Sheet"
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)

	_over = Control.new()
	_over.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.draw.connect(_draw_over)
	add_child(_over)

	_sheet = VBoxContainer.new()
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_theme_constant_override("separation", 4)
	_clip.add_child(_sheet)

	var dt := Time.get_datetime_dict_from_system()
	_header = _ink(_header_text(2), 16, Fax.INK_FAINT)
	_sheet.add_child(_header)
	_sheet.add_child(_ink("COUNTY GENERAL  /  NIGHT SHIFT SIGN-IN", Fax.FONT_SIZE, Fax.INK))

	_title = Control.new()
	_title.custom_minimum_size.y = 110
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.draw.connect(_draw_title)
	_sheet.add_child(_title)
	_sheet.add_child(_rule())

	var name_row := _row()
	name_row.add_child(_ink("SURGEON ON CALL:", Fax.FONT_SIZE, Fax.INK))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "your name"
	_name_edit.max_length = 16
	_name_edit.text = _load_pref("name", "Surgeon %d" % (randi() % 90 + 10))
	_name_edit.custom_minimum_size.x = 300
	_style_field(_name_edit)
	name_row.add_child(_name_edit)
	_sheet.add_child(name_row)

	var space := Control.new()
	space.custom_minimum_size.y = 10
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(space)
	var solo := _option("SOLO SHIFT")
	_sheet.add_child(solo)
	# net hook: Steam hosting, only when GodotSteam loaded and the Steam client is running.
	var host_steam := _option("HOST SHIFT  (STEAM)")
	host_steam.visible = Net.steam_available()
	host_steam.pressed.connect(_on_host_steam)
	_sheet.add_child(host_steam)
	var host := _option("HOST SHIFT  (IP)")
	_sheet.add_child(host)
	var join_row := _row()
	var join := _option("JOIN SHIFT  AT")
	join_row.add_child(join)
	_addr_edit = LineEdit.new()
	_addr_edit.placeholder_text = "host address, e.g. 192.168.1.20"
	_addr_edit.text = _load_pref("addr", "")
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_field(_addr_edit)
	join_row.add_child(_addr_edit)
	_sheet.add_child(join_row)

	_sheet.add_child(_rule())

	var admin_row := _row()
	# Settings hook: not in _buttons, so it stays usable while a join is pending.
	var settings := _option("SETTINGS", false)
	settings.name = "SettingsButton"
	settings.pressed.connect(func():
		if _accepting():
			chose_settings.emit())
	admin_row.add_child(settings)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	admin_row.add_child(gap)
	var quit := _option("EXIT", false)
	quit.name = "ExitButton"
	quit.pressed.connect(func(): get_tree().quit())
	admin_row.add_child(quit)
	_sheet.add_child(admin_row)

	var note_row := _row()
	note_row.custom_minimum_size.y = 26
	_note_tag = _ink("NOTE:", 16, Fax.STAMP_INK)
	_note_tag.visible = false
	_note_tag.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	note_row.add_child(_note_tag)
	_status = _ink("", 16, Fax.STAMP_INK)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	note_row.add_child(_status)
	_sheet.add_child(note_row)

	_buttons = [solo, host, join, host_steam]
	solo.pressed.connect(_on_solo)
	host.pressed.connect(_on_host)
	join.pressed.connect(_on_join)
	_addr_edit.text_submitted.connect(func(_t): _on_join())
	_name_edit.text_submitted.connect(func(_t): _on_solo())


# -- pieces of the sheet ---------------------------------------------------------------------

func _ink(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color(color, 0.92))
	return l


func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_constant_override("separation", 12)
	return r


func _rule() -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = 18
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func(): Fax.draw_rule(c, 0.0, c.size.y * 0.5, c.size.x, 1.0))
	return c


## A tick box: a Button that draws "[ ] LABEL" in ink. Hover or focus pencils in a faint tick;
## choosing it stamps an X that stays while that choice is loading (sticky), or flashes (not).
func _option(label: String, sticky := true) -> Button:
	var b := FaxOption.new()
	b.label = label
	b.font = _font
	b.sticky = sticky
	# Button's own minimum size is computed from its (empty) text, so the width is set here.
	b.custom_minimum_size = Vector2(FaxOption.BOX + 20.0 + _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, FaxOption.FONT_SIZE).x, OPTION_H)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.flat = true
	var none := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		b.add_theme_stylebox_override(s, none)
	_options.append(b)
	return b


func _style_field(e: LineEdit) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Fax.INK, 0.04)
	sb.border_width_bottom = 2
	sb.border_color = Color(Fax.INK, 0.8)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	var focus := sb.duplicate() as StyleBoxFlat
	focus.border_color = Fax.STAMP_INK
	focus.bg_color = Color(Fax.STAMP_INK, 0.05)
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("read_only", sb)
	e.add_theme_stylebox_override("focus", focus)
	e.add_theme_font_override("font", _font)
	e.add_theme_font_size_override("font_size", Fax.FONT_SIZE)
	e.add_theme_color_override("font_color", Fax.INK)
	e.add_theme_color_override("font_placeholder_color", Color(Fax.INK_FAINT, 0.6))
	e.add_theme_color_override("caret_color", Fax.STAMP_INK)
	e.add_theme_color_override("selection_color", Color(Fax.STAMP_INK, 0.25))
	e.add_theme_color_override("font_selected_color", Fax.INK)


class FaxOption extends Button:
	var label := ""
	var font: Font
	var sticky := true
	var marked := false

	const BOX := 20.0
	const FONT_SIZE := 19

	func _init() -> void:
		pressed.connect(_on_pressed)

	func _on_pressed() -> void:
		marked = true
		queue_redraw()
		Audio.play("print_stamp", null, -14.0, 0.05, Audio.BUS_UI)
		if not sticky:
			get_tree().create_timer(0.3).timeout.connect(func():
				marked = false
				queue_redraw())

	func set_marked(on: bool) -> void:
		marked = on
		queue_redraw()

	func _draw() -> void:
		var h := size.y
		var ink := Color(Fax.INK_FAINT, 0.7) if disabled else Fax.INK
		var box := Rect2(2.0, (h - BOX) * 0.5, BOX, BOX)
		draw_rect(box, Color(ink, 0.9), false, 2.0)
		if marked:
			var p := box.grow(-3.0)
			draw_line(p.position, p.end, Fax.STAMP_INK, 3.0)
			draw_line(Vector2(p.end.x, p.position.y), Vector2(p.position.x, p.end.y), Fax.STAMP_INK, 3.0)
		elif not disabled and (is_hovered() or has_focus()):
			var o := box.position
			draw_polyline(PackedVector2Array([o + Vector2(4, 11), o + Vector2(9, 16), o + Vector2(18, 3)]),
					Color(Fax.STAMP_INK, 0.6), 2.5)
		if font != null:
			draw_string(font, Vector2(BOX + 14.0, h * 0.5 + FONT_SIZE * 0.36), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(ink, 0.92))


# -- feeding and layout ----------------------------------------------------------------------

## The sheet's fax header: the page after however many the launch chart took.
func _header_text(page: int) -> String:
	var dt := Time.get_datetime_dict_from_system()
	return ">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE %d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, page]


## The launch printout's hand-off, and every return to the title (Back from settings, a failed start,
## Main menu from the pause page): a fresh sheet starts inside the printer and feeds up, slowing to a
## stop. `scroll_px` keeps the paper's green bars in phase; `page` is its number.
func feed_in(scroll_px := 0.0, _speed := 0.0, page := 2) -> void:
	page_no = page
	if _header != null:
		_header.text = _header_text(page)
	_eject_done.clear()
	_lift.snap(0.0)
	if Fax.headless():
		_feed.snap(1.0)
		return
	_base_scroll = scroll_px
	_feed.snap(0.0)
	_feed.go(1.0, Fax.FEED_SECONDS, true)
	_feed_tick = 0.0
	_layout()


## The sheet waits inside the printer (nothing on the paper yet) until feed_in(): the pause page is
## still ejecting on its way back to the title.
func hold_in_printer() -> void:
	if Fax.headless():
		return
	_eject_done.clear()
	_lift.snap(0.0)
	_feed.snap(0.0)
	_layout()


func is_feeding() -> bool:
	return _feed.moving()


## Another page is coming (settings, the shift assignment): this one accelerates up and out of the top
## of the screen from wherever it is (even half fed in), the printer staying put, then `done` runs (the
## caller hides the menu and feeds its own page). A second call while ejecting waits for the same exit.
func eject(done: Callable) -> void:
	if Fax.headless() or not visible:
		done.call()
		return
	_eject_done.append(done)
	if _eject_done.size() > 1:
		return
	_feed.snap(_feed.value)
	_lift_from = (1.0 - _feed.value) * _rest_offset()
	_lift.snap(0.0)
	_lift.go(1.0, Fax.EJECT_SECONDS, false)
	set_enabled(false)
	get_viewport().gui_release_focus()
	Fax.sfx("print_feed", -8.0)


func is_ejecting() -> bool:
	return not _eject_done.is_empty()


## How far below its resting place the sheet starts: its top edge just inside the slot.
func _rest_offset() -> float:
	var l := Fax.layout(size, _font)
	return float(l.slot_y) - _rest_y(l) + PAGE_MARGIN


## At rest the sheet stands out of the printer, its last line just above the slot.
func _rest_y(l: Dictionary) -> float:
	return float(l.slot_y) - _sheet.get_combined_minimum_size().y - BOTTOM_PAD


## How far above rest the sheet is (negative: still down in the printer).
func _up_px(l: Dictionary) -> float:
	if is_ejecting():
		return -_lift_from + _lift.value * (float(l.slot_y) + _lift_from + 20.0)
	return -(1.0 - _feed.value) * _rest_offset()


func _layout() -> void:
	if _sheet == null:
		return
	var l := Fax.layout(size, _font)
	_clip.position = Vector2(l.px, 0.0)
	_clip.size = Vector2(l.paper_w, float(l.slot_y))
	_sheet.position = Vector2(Fax.MARGIN, _rest_y(l) - _up_px(l))
	_sheet.size = Vector2(l.text_w, _sheet.get_combined_minimum_size().y)
	_canvas.queue_redraw()
	_over.queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	var dt := Fax.ui_dt(delta)
	if is_ejecting():
		_lift.step(dt)
		_layout()
		if not _lift.moving():
			set_enabled(true)
			var calls := _eject_done.duplicate()
			_eject_done.clear()
			for done: Callable in calls:
				if done.is_valid():
					done.call()
		return
	if not _feed.moving():
		return
	_feed.step(dt)
	_feed_tick -= dt
	if _feed_tick <= 0.0 and _feed.value < 0.85:
		_feed_tick = Fax.FEED_TICK
		Fax.sfx("print_feed", -14.0, 0.1)
	_layout()


func _draw_paper() -> void:
	var sz := _canvas.size
	var l := Fax.layout(sz, _font)
	# A page just the size of the sign-in sheet, a margin above its first line and a pad below its last:
	# at rest (and while feeding) that runs into the slot; ejecting, the whole page leaves it.
	var page_top := _sheet.position.y - PAGE_MARGIN
	var page_bottom := minf(_sheet.position.y + _sheet.size.y + BOTTOM_PAD, float(l.slot_y))
	Fax.draw_paper(_canvas, sz, l, _base_scroll + _rest_offset() + _up_px(l), 1.0, page_bottom, true, page_top)
	# READY only once a sheet stands still in the printer; any motion is a page coming through.
	var at_rest := not is_ejecting() and _feed.at(1.0)
	Fax.draw_printer(_canvas, sz, l, _font, float(l.tx), "READY" if at_rest else "RECEIVING", Fax.LCD_TEXT, 1.0)


## Nothing over the sheet any more: the page ends at its own top edge (kept for the node order).
func _draw_over() -> void:
	pass


func _draw_title() -> void:
	Fax.draw_stamp(_title, _font, "CODE BLUE", _title.size * 0.5, 56, 0.0, _title_ink, 1.0, -0.05)


# -- state -----------------------------------------------------------------------------------

func player_name() -> String:
	var n := _name_edit.text.strip_edges().substr(0, 16)
	return n if not n.is_empty() else "Surgeon"


func show_menu(message: String = "") -> void:
	visible = true
	_set_note(message)
	set_enabled(true)


func hide_menu() -> void:
	visible = false


func set_status(text: String) -> void:
	_set_note(text)


func _set_note(text: String) -> void:
	_status.text = text
	_note_tag.visible = not text.is_empty()


func set_enabled(on: bool) -> void:
	for b in _buttons:
		b.disabled = not on
	if on:
		for o in _options:
			o.set_marked(false)


## A choice counts only while the sheet is up and not on its way out (Enter in the name field, a double
## click, Settings while a start is ejecting the sheet); `choice` also needs the tick boxes live (not
## while a start or a join is already pending).
func _accepting(choice := false) -> bool:
	if not visible or is_ejecting():
		return false
	return not choice or not _buttons[0].disabled


func _on_solo() -> void:
	if not _accepting(true):
		return
	_save_prefs()
	set_enabled(false)
	chose_solo.emit(player_name())


func _on_host() -> void:
	if not _accepting(true):
		return
	_save_prefs()
	set_enabled(false)
	chose_host.emit(player_name())


## Clicking the empty paper or the room lets go of a text field (so typing reaches the menu again).
func _on_background_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		get_viewport().gui_release_focus()


func _on_host_steam() -> void:
	if not _accepting(true):
		return
	_save_prefs()
	set_enabled(false)
	_set_note("Opening a Steam lobby...")
	chose_host_steam.emit(player_name())


func _on_join() -> void:
	if not _accepting(true):
		return
	_save_prefs()
	if _addr_edit.text.strip_edges().is_empty():
		_set_note("Type the host's address first.")
		for o in _options:
			o.set_marked(false)
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
