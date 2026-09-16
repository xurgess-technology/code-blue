extends CanvasLayer
## The case sheet reader (hub rebuild, chunk 4): E on the break room printer (case_printer.gd, opened
## by main.gd) shows the sheets it has printed, one page per case, on the same fax paper and machine
## as the launch printout and the pharmacy order form (scripts/fax_printer.gd). The page is derived
## locally from replicated game state (OrScreenModel.build, the same panels the OR monitors draw):
## patient, complaint, where they are, the procedure with its done / current steps, and the supplies
## the shelf is still short. It refreshes while open.
##
##   open(game, ids)   show the sheets for these case ids (newest first); the player stops
##   close()
##   is_open()
##
## Keys: A / D or the arrow keys turn pages, Esc or E closes.

const Fax := preload("res://scripts/fax_printer.gd")
const OrModel := preload("res://scripts/orscreen/or_screen_model.gd")

const LAYER := 61
const BOTTOM_PAD := 22.0
const REFRESH_SECONDS := 0.5
const MACHINE_LABEL := "BREAK ROOM PRINTER  /  COUNTY GENERAL"

var game: Node = null
var _open := false
var _font: Font
var _root: Control
var _canvas: Control
var _clip: Control
var _sheet: VBoxContainer
var _ids: Array = []
var _page := 0
var _pages := 0
var _refresh_t := 0.0
var _shown := ""   # what the sheet was built from; rebuilt only when it changes


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_font = Fax.make_font()
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_fit()
	get_viewport().size_changed.connect(_fit)
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_room)
	_root.add_child(_canvas)
	_clip = Control.new()
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_clip)
	_root.resized.connect(_layout)


func _fit() -> void:
	Fax.fit_layer(self, _root)


func is_open() -> bool:
	return _open


func open(g: Node, ids: Array) -> void:
	if _open or ids.is_empty():
		return
	game = g
	_ids = ids.duplicate()
	_page = 0
	_open = true
	_shown = ""
	_rebuild()
	visible = true
	_layout.call_deferred()
	_sound("click", -8.0)


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false


func _sound(cue: String, db: float) -> void:
	if DisplayServer.get_name() != "headless":
		Audio.play(cue, null, db, 0.05, Audio.BUS_UI)


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("interact"):
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_A, KEY_LEFT]:
			_turn(-1)
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_D, KEY_RIGHT]:
			_turn(1)
			get_viewport().set_input_as_handled()


func _turn(dir: int) -> void:
	if _pages <= 1:
		return
	_page = posmod(_page + dir, _pages)
	_shown = ""
	_rebuild()
	_sound("print_feed", -10.0)


func _process(delta: float) -> void:
	if not _open:
		return
	var me = game.local_player() if game != null else null
	if me == null or not me.alive or me.downed or game.phase == Game.Phase.MENU:
		close()
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = REFRESH_SECONDS
		_rebuild()


# ---------------------------------------------------------------------------
# the sheet

## The panels for this machine's printed sheets that still exist, in the printer's order.
func _panels() -> Array:
	var by_id := {}
	for p in OrModel.build(game).panels:
		by_id[int(p.id)] = p
	var out := []
	for id in _ids:
		if by_id.has(int(id)):
			out.append(by_id[int(id)])
	return out


func _rebuild() -> void:
	if game == null:
		return
	var panels := _panels()
	if panels.is_empty():
		close()
		return
	_pages = panels.size()
	_page = clampi(_page, 0, _pages - 1)
	var p: Dictionary = panels[_page]
	var key := "%d/%d|%s" % [_page, _pages, var_to_str(p)]
	if key == _shown and _sheet != null and is_instance_valid(_sheet):
		return
	_shown = key
	_build_sheet(p)
	_layout()


func _build_sheet(p: Dictionary) -> void:
	if _sheet != null and is_instance_valid(_sheet):
		_sheet.queue_free()
	_sheet = VBoxContainer.new()
	_sheet.add_theme_constant_override("separation", 1)
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_sheet)

	var dt := Time.get_datetime_dict_from_system()
	_sheet.add_child(_ink(">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE %d OF %d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, _page + 1, _pages], 16, Fax.INK_FAINT))
	_sheet.add_child(_ink("COUNTY GENERAL  /  DISPATCH CASE SHEET", Fax.FONT_SIZE))
	_sheet.add_child(_rule())
	var ailment := String(p.ailment_name).to_upper()
	if String(p.code) != "":
		ailment += "  (%s)" % String(p.code)
	_sheet.add_child(_ink("PATIENT ........ %s" % String(p.patient_name).to_upper(), Fax.FONT_SIZE))
	_sheet.add_child(_ink("COMPLAINT ...... %s" % ailment, Fax.FONT_SIZE))
	_sheet.add_child(_ink("CONDITION ...... %s" % _condition(p), Fax.FONT_SIZE, Fax.STAMP_INK if String(p.state) == "dead" else Fax.INK))
	var blurb := Procedures.blurb(String(p.patient_id), String(p.ailment_id))
	for line in _wrap(blurb, Fax.WIDTH_CHARS):
		_sheet.add_child(_ink(line, 16, Fax.INK_FAINT))
	_sheet.add_child(_rule())

	_sheet.add_child(_ink("PROCEDURE", 15, Fax.INK_FAINT))
	for i in p.steps.size():
		var s: Dictionary = p.steps[i]
		var mark := "[X]" if String(s.state) == "done" else ("[>]" if String(s.state) == "current" else "[ ]")
		var text := "%s %d. %s" % [mark, i + 1, String(s.label)]
		if String(s.item_name) != "":
			text += "  -  %s" % String(s.item_name)
		var col := Fax.INK_FAINT if String(s.state) == "done" else (Fax.STAMP_INK if String(s.state) == "current" else Fax.INK)
		_sheet.add_child(_ink(text.substr(0, Fax.WIDTH_CHARS), Fax.FONT_SIZE, col))
	if not p.supplies.is_empty():
		_sheet.add_child(_ink("SUPPLIES  (ON THE OR SHELF / NEEDED)", 15, Fax.INK_FAINT))
		for s in p.supplies:
			var dots := maxi(2, 24 - String(s.name).length())
			var line := "  %s %s %d / %d" % [String(s.name).to_upper(), ".".repeat(dots), int(s.have), int(s.need)]
			_sheet.add_child(_ink(line, Fax.FONT_SIZE, Fax.INK if bool(s.ok) else Fax.STAMP_INK))
	_sheet.add_child(_rule())

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 24)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _pages > 1:
		buttons.add_child(_button("< PREV", func(): _turn(-1)))
		buttons.add_child(_button("NEXT >", func(): _turn(1)))
	buttons.add_child(_button("CLOSE", close))
	_sheet.add_child(buttons)


func _condition(p: Dictionary) -> String:
	match String(p.state):
		"incoming":
			return "EN ROUTE  (PARAMEDICS)"
		"on_table":
			return "ON TABLE %d  /  VITALS %d%%" % [int(p.table) + 1, roundi(float(p.vitals))]
		"stable":
			return "STABLE"
		"dead":
			return "DECEASED"
	return String(p.state).to_upper()


static func _wrap(text: String, width: int) -> Array:
	var lines := []
	var cur := ""
	for word in text.split(" ", false):
		if cur == "":
			cur = word
		elif cur.length() + 1 + word.length() <= width:
			cur += " " + word
		else:
			lines.append(cur)
			cur = word
	if cur != "":
		lines.append(cur)
	return lines


func _ink(text: String, size: int, col: Color = Fax.INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(col, 0.92))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _rule() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 18)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func(): Fax.draw_rule(c, 0.0, c.size.y * 0.5, c.size.x, 1.0))
	return c


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", Fax.FONT_SIZE)
	b.add_theme_color_override("font_color", Fax.INK)
	for s in ["font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(s, Fax.STAMP_INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(Fax.INK, 0.8)
	sb.set_border_width_all(2)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	for s in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(on_press)
	return b


# ---------------------------------------------------------------------------
# layout and drawing

func _layout() -> void:
	if _sheet == null or not is_instance_valid(_sheet):
		return
	var l := Fax.layout(_root.size, _font)
	_clip.position = Vector2(l.px, 0.0)
	_clip.size = Vector2(l.paper_w, l.slot_y)
	var h := _sheet.get_combined_minimum_size().y
	_sheet.position = Vector2(Fax.MARGIN, float(l.slot_y) - h - BOTTOM_PAD)
	_sheet.size = Vector2(l.text_w, h)
	_canvas.queue_redraw()


func _draw_room() -> void:
	var sz := _canvas.size
	var l := Fax.layout(sz, _font)
	# No room behind it: the game stays visible either side of the paper and the machine.
	var page_top := (_sheet.position.y - 30.0) if _sheet != null and is_instance_valid(_sheet) else float(l.slot_y)
	Fax.draw_paper(_canvas, sz, l, 0.0, 1.0, INF, false, page_top)
	var status := "PAGE %d OF %d" % [_page + 1, maxi(_pages, 1)]
	Fax.draw_printer(_canvas, sz, l, _font, float(l.tx), status, Fax.LCD_TEXT, 1.0, 0.0, MACHINE_LABEL)
