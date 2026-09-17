extends CanvasLayer
## The pharmacy order form (hub rebuild, chunk 3): opened with E at the lobby's fax terminal
## (fax_terminal.gd, main.gd opens it), on this machine only. The whole screen is the fax, the same
## room, paper and machine as the launch printout (scripts/fax_printer.gd): an order page sitting in
## the pharmacy order fax, a tick box per item the pharmacy stocks (game.PHARMACY_CATALOG) with how
## many sets of it once ticked (- / + , type a number, or scroll on it; shift steps by 10), the total
## and the team's money. SEND FAX feeds the page down into the machine, then sends the ticked items and
## their quantities to the host (economy.request_order), which takes the money and starts the order.
##
## DEV HOOK: a quantity of exactly game.DEV_CODE placebo pills is the secret order. It sends whatever
## the team has; instead of closing, the machine prints a reply page while the host turns dev mode on
## and every machine builds the hidden dev room (dev_room.gd), then closes.
##
##   open(game)   show it; the player stops (main.gd frees the mouse while is_open())
##   close()      hide it
##   is_open()

const Fax := preload("res://scripts/fax_printer.gd")

const LAYER := 61
const SEND_SECONDS := 1.1
const BOTTOM_PAD := 22.0
const MACHINE_LABEL := "PHARMACY ORDER FAX  /  COUNTY GENERAL"

var game: Node = null
var _open := false
var _font: Font
var _root: Control
var _canvas: Control
var _clip: Control
var _sheet: VBoxContainer
var _over: Control
var _rows: Array = []        # [{kind, price, box}]
var _total: Label
var _funds: Label
var _note: Label
var _send: Button
var _sending := -1.0
var _sent_sets := {}
# DEV HOOK: the reply page after the secret order.
const REPLY_LINE_SECONDS := 0.42
const REPLY_SEND_AT_LINE := 3     # the order goes out once this many lines are on the page
const REPLY_HOLD_SECONDS := 1.8
const REPLY_TIMEOUT := 15.0
const SECRET_KIND := "placebo_pills"
var _reply := -1.0                # seconds since the reply page started, < 0 while not printing
var _reply_lines: Array = []      # the lines still to print ("@build" waits for the room)
var _reply_next := 0.0
var _reply_sent := false
var _reply_wait: Label = null
var _reply_done := -1.0


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
	_over = Control.new()
	_over.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_over.draw.connect(_draw_over)
	_root.add_child(_over)
	_root.resized.connect(_layout)


func _fit() -> void:
	Fax.fit_layer(self, _root)


func is_open() -> bool:
	return _open


func open(g: Node) -> void:
	if _open:
		return
	game = g
	_open = true
	_sending = -1.0
	_reply = -1.0
	_build_sheet()
	visible = true
	_layout.call_deferred()
	_click()


func close() -> void:
	if not _open:
		return
	_open = false
	_sending = -1.0
	_reply = -1.0
	_reply_wait = null
	visible = false


func _click() -> void:
	if DisplayServer.get_name() != "headless":
		Audio.play("click", null, -8.0, 0.05, Audio.BUS_UI)


func _input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("pause") and _sending < 0.0 and _reply < 0.0:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _open:
		return
	var me = game.local_player() if game != null else null
	if me == null or not me.alive or me.downed or game.phase == Game.Phase.MENU:
		close()
		return
	if _reply >= 0.0:
		_tick_reply(delta)
		return
	if _sending >= 0.0:
		_sending += delta
		_layout()
		if _sending >= SEND_SECONDS:
			if _is_secret(_sent_sets):
				_start_reply()
				return
			if game != null and game.economy != null:
				game.economy.request_order(_sent_sets)
			close()
		return
	_refresh()


# ---------------------------------------------------------------------------
# the sheet

func _ink(text: String, size: int, col: Color = Fax.INK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(col, 0.92))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_sheet() -> void:
	if _sheet != null:
		_sheet.queue_free()
	_rows = []
	_sheet = VBoxContainer.new()
	_sheet.add_theme_constant_override("separation", 6)
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_sheet)

	var dt := Time.get_datetime_dict_from_system()
	_sheet.add_child(_ink(">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE 1 OF 1" % [dt.year, dt.month, dt.day, dt.hour, dt.minute], 16, Fax.INK_FAINT))
	_sheet.add_child(_ink("TO:    COUNTY GENERAL PHARMACY", Fax.FONT_SIZE))
	_sheet.add_child(_ink("FROM:  NIGHT SHIFT, OPERATING ROOM", Fax.FONT_SIZE))
	_sheet.add_child(_rule())
	_sheet.add_child(_ink("PLEASE SUPPLY  (TICK, THEN HOW MANY)", 15, Fax.INK_FAINT))
	for e in _catalog():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var box := Tick.new()
		box.font = _font
		box.label = "%s  x%d" % [String(e.name).to_upper(), int(e.count)]
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.custom_minimum_size = Vector2(0, 34)
		row.add_child(box)
		var r := {"kind": String(e.kind), "price": int(e.price), "box": box}
		var stepper := _stepper(r)
		row.add_child(stepper)
		var cost := _ink("", Fax.FONT_SIZE)
		cost.custom_minimum_size.x = 84
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(cost)
		r["stepper"] = stepper
		r["cost"] = cost
		box.toggled_on.connect(func(on):
			_click()
			_show_stepper(r, on))
		_show_stepper(r, false)
		_sheet.add_child(row)
		_rows.append(r)
	_sheet.add_child(_rule())
	_total = _ink("", Fax.FONT_SIZE)
	_sheet.add_child(_total)
	_funds = _ink("", 16, Fax.INK_FAINT)
	_sheet.add_child(_funds)
	_note = _ink("", 16, Fax.STAMP_INK)
	_note.custom_minimum_size = Vector2(0, 24)
	_sheet.add_child(_note)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 24)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_send = _button("SEND FAX", _send_order)
	buttons.add_child(_send)
	buttons.add_child(_button("CANCEL", close))
	_sheet.add_child(buttons)
	_refresh()


## QTY  [-] [ 1 ] [+]  for one catalog row: how many sets. Only shown once the row is ticked.
func _stepper(r: Dictionary) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(_ink("QTY", 15, Fax.INK_FAINT))
	var edit := LineEdit.new()
	edit.text = "1"
	edit.max_length = 10   # DEV HOOK: room for the secret order
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.custom_minimum_size = Vector2(52, 30)
	edit.add_theme_font_override("font", _font)
	edit.add_theme_font_size_override("font_size", Fax.FONT_SIZE)
	edit.add_theme_color_override("font_color", Fax.INK)
	edit.add_theme_color_override("caret_color", Fax.STAMP_INK)
	edit.add_theme_color_override("selection_color", Color(Fax.STAMP_INK, 0.25))
	edit.add_theme_color_override("font_selected_color", Fax.INK)
	var line := StyleBoxFlat.new()
	line.bg_color = Color(Fax.INK, 0.06)
	line.border_color = Color(Fax.INK, 0.8)
	line.border_width_bottom = 2
	line.content_margin_left = 4
	line.content_margin_right = 4
	for s in ["normal", "focus", "read_only"]:
		edit.add_theme_stylebox_override(s, line)
	edit.text_changed.connect(func(t: String):
		var digits := ""
		for c in t:
			if c >= "0" and c <= "9":
				digits += c
		if digits != t:
			edit.text = digits
			edit.caret_column = digits.length())
	var settle := func(_t: String):
		_set_qty(r, _qty(r))
		edit.release_focus()
	edit.text_submitted.connect(settle)
	edit.focus_exited.connect(func(): _set_qty(r, _qty(r)))
	edit.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			var step := 10 if ev.shift_pressed else 1
			if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
				_set_qty(r, _qty(r) + step)
				edit.accept_event()
			elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_set_qty(r, _qty(r) - step)
				edit.accept_event())
	r["edit"] = edit
	var minus := _button("-", func(): _step(r, -1))
	var plus := _button("+", func(): _step(r, 1))
	for b in [minus, plus]:
		b.custom_minimum_size = Vector2(30, 30)
		(b.get_theme_stylebox("normal") as StyleBoxFlat).content_margin_left = 8
		(b.get_theme_stylebox("normal") as StyleBoxFlat).content_margin_right = 8
	h.add_child(minus)
	h.add_child(edit)
	h.add_child(plus)
	r["buttons"] = [minus, plus]
	return h


## How many sets a row is set to: 0 while its box is blank or unticked.
func _qty(r: Dictionary) -> int:
	if _is_code(r):
		return _code()
	return clampi(int(String(r.edit.text)), 0, _max_qty())


## DEV HOOK: this row holds the secret order.
func _is_code(r: Dictionary) -> bool:
	return String(r.kind) == SECRET_KIND and String(r.edit.text) == str(_code())


func _code() -> int:
	return int(game.DEV_CODE) if game != null else 3141592653


func _is_secret(sets: Dictionary) -> bool:
	return int(sets.get(SECRET_KIND, 0)) == _code()


func _max_qty() -> int:
	return int(game.PHARMACY_MAX_QTY) if game != null else 99


func _set_qty(r: Dictionary, n: int) -> void:
	if String(r.kind) == SECRET_KIND and n == _code():
		r.edit.text = str(n)
		_refresh()
		return
	r.edit.text = str(clampi(n, 1, _max_qty()))
	_refresh()


## - / + : one set, or ten with shift held.
func _step(r: Dictionary, dir: int) -> void:
	_click()
	_set_qty(r, _qty(r) + dir * (10 if Input.is_key_pressed(KEY_SHIFT) else 1))


## The stepper keeps its space while hidden, so ticking a row doesn't shuffle the line.
func _show_stepper(r: Dictionary, on: bool) -> void:
	var h: Control = r.stepper
	h.modulate.a = 1.0 if on else 0.0
	for b in r.buttons:
		b.disabled = not on
		b.focus_mode = Control.FOCUS_ALL if on else Control.FOCUS_NONE
	r.edit.editable = on
	r.edit.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	if not on and r.edit.has_focus():
		r.edit.release_focus()
	_refresh()


func _rule() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 18)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func(): Fax.draw_rule(c, 0.0, c.size.y * 0.5, c.size.x, 1.0))
	return c


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", Fax.FONT_SIZE)
	b.add_theme_color_override("font_color", Fax.INK)
	for s in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, Fax.STAMP_INK)
	b.add_theme_color_override("font_disabled_color", Color(Fax.INK_FAINT, 0.5))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(Fax.INK, 0.8)
	sb.set_border_width_all(2)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	var dim := sb.duplicate() as StyleBoxFlat
	dim.border_color = Color(Fax.INK_FAINT, 0.4)
	for s in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, sb)
	b.add_theme_stylebox_override("disabled", dim)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(on_press)
	return b


# ---------------------------------------------------------------------------
# layout and drawing

## How far the page has fed down into the machine while sending: 0 at rest, the whole sheet at the end.
func _feed() -> float:
	return 0.0 if _sending < 0.0 else ease(clampf(_sending / SEND_SECONDS, 0.0, 1.0), 2.2)


func _layout() -> void:
	if _sheet == null or not is_instance_valid(_sheet):
		return
	var sz := _root.size
	var l := Fax.layout(sz, _font)
	_clip.position = Vector2(l.px, 0.0)
	_clip.size = Vector2(l.paper_w, l.slot_y)
	var h := _sheet.get_combined_minimum_size().y
	var rest_y: float = float(l.slot_y) - h - BOTTOM_PAD
	_sheet.position = Vector2(Fax.MARGIN, rest_y + _feed() * (h + BOTTOM_PAD + 20.0))
	_sheet.size = Vector2(l.text_w, h)
	_canvas.queue_redraw()
	_over.queue_redraw()


func _draw_room() -> void:
	var sz := _canvas.size
	var l := Fax.layout(sz, _font)
	var feed_px := _feed() * 400.0
	# No room behind it: in a shift the game stays visible either side of the paper and the machine.
	# The page is just the order form's size, its top edge a margin above the first line.
	var page_top := (_sheet.position.y - 30.0) if _sheet != null and is_instance_valid(_sheet) else float(l.slot_y)
	Fax.draw_paper(_canvas, sz, l, -feed_px, 1.0, INF, false, page_top)
	var sending := _sending >= 0.0
	var lcd := "SENDING..." if sending else "READY TO SEND"
	var head := float(l.tx) + (fmod(_sending * 900.0, float(l.text_w)) if sending else 0.0)
	if _reply >= 0.0:
		sending = true
		lcd = "RECEIVING..." if _reply_done < 0.0 else "RECEIVED"
		head = float(l.tx) + fmod(_reply * 700.0, float(l.text_w))
	Fax.draw_printer(_canvas, sz, l, _font, head, lcd, Fax.LCD_WAIT if sending else Fax.LCD_TEXT, 1.0, 0.0, MACHINE_LABEL)


## Nothing over the page: it ends at its own top edge.
func _draw_over() -> void:
	pass


# ---------------------------------------------------------------------------

func _catalog() -> Array:
	return game.PHARMACY_CATALOG if game != null else []


func _refresh() -> void:
	if _total == null or not is_instance_valid(_total):
		return
	var total := 0
	var secret := false
	for r in _rows:
		if not is_instance_valid(r.box):
			continue
		if r.box.checked and _is_code(r):
			secret = true
		var qty := _qty(r) if r.box.checked else 1
		r.cost.text = "$%d" % (int(r.price) * maxi(qty, 1))
		if r.box.checked:
			total += int(r.price) * qty
	var money := int(game.money) if game != null else 0
	_total.text = "TOTAL ........ $%d" % total
	_funds.text = "TEAM FUNDS ... $%d" % money
	_note.text = "NOTE: not enough money for this order." if total > money and not secret else ""
	_send.disabled = total == 0 or (total > money and not secret)


func _send_order() -> void:
	_sent_sets = {}
	for r in _rows:
		if is_instance_valid(r.box) and r.box.checked and _qty(r) > 0:
			_sent_sets[String(r.kind)] = _qty(r)
	if _sent_sets.is_empty() or _sending >= 0.0:
		return
	_sending = 0.0
	if DisplayServer.get_name() != "headless":
		Audio.play("fax_connect", null, -10.0, 0.0, Audio.BUS_UI)
		Audio.play("print_feed", null, -6.0, 0.05, Audio.BUS_UI)


# ---------------------------------------------------------------------------
# DEV HOOK: the pharmacy's reply to the secret order

func _start_reply() -> void:
	_sending = -1.0
	_reply = 0.0
	_reply_next = 0.0
	_reply_sent = false
	_reply_wait = null
	_reply_done = -1.0
	if _sheet != null:
		_sheet.queue_free()
	_rows = []
	_sheet = VBoxContainer.new()
	_sheet.add_theme_constant_override("separation", 6)
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_sheet)
	var dt := Time.get_datetime_dict_from_system()
	_reply_lines = [
		[">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE 1 OF 1" % [dt.year, dt.month, dt.day, dt.hour, dt.minute], 16, Fax.INK_FAINT],
		["TO:    NIGHT SHIFT, OPERATING ROOM", Fax.FONT_SIZE, Fax.INK],
		["FROM:  COUNTY GENERAL PHARMACY", Fax.FONT_SIZE, Fax.INK],
		["RE:    3,141,592,653 PLACEBO PILLS", Fax.FONT_SIZE, Fax.INK],
		["@rule"],
		["ORDER VOIDED. NO CHARGE.", Fax.FONT_SIZE, Fax.INK],
		["AUTHORIZATION ........ 3.14159265", Fax.FONT_SIZE, Fax.INK],
		["UNLOCKING SUPPLY CLOSET ........ OK", Fax.FONT_SIZE, Fax.INK],
		["@build"],
		["@rule"],
		["DEV MODE ON.  F1: DEV PANEL.", Fax.FONT_SIZE, Fax.DEV_INK],
	]
	if DisplayServer.get_name() != "headless":
		Audio.play("fax_connect", null, -10.0, 0.0, Audio.BUS_UI)
	_layout()


func _tick_reply(delta: float) -> void:
	_reply += delta
	if _reply_sent and _reply_wait != null:
		var ready: bool = game != null and game.dev_on() and game.dev.room_ready()
		if ready or _reply >= REPLY_TIMEOUT:
			_reply_wait.text = "BUILDING DEV ROOM ................ " + ("DONE" if ready else "LATE")
			_reply_wait = null
			_reply_next = _reply + REPLY_LINE_SECONDS
		else:
			_reply_wait.text = "BUILDING DEV ROOM " + ".".repeat(1 + int(_reply * 6.0) % 16)
	elif _reply >= _reply_next and not _reply_lines.is_empty():
		_print_reply_line(_reply_lines.pop_front())
		_reply_next = _reply + REPLY_LINE_SECONDS
		if _reply_lines.is_empty():
			_reply_done = _reply
	if not _reply_sent and _sheet.get_child_count() >= REPLY_SEND_AT_LINE:
		# The page is up and drawing: now the order goes out and the room gets built behind it.
		_reply_sent = true
		if game != null and game.economy != null:
			game.economy.request_order(_sent_sets)
	if _reply_done >= 0.0 and _reply - _reply_done >= REPLY_HOLD_SECONDS:
		close()
		return
	_layout()


func _print_reply_line(line: Array) -> void:
	match String(line[0]):
		"@rule":
			_sheet.add_child(_rule())
		"@build":
			_reply_wait = _ink("BUILDING DEV ROOM .", Fax.FONT_SIZE)
			_sheet.add_child(_reply_wait)
		_:
			_sheet.add_child(_ink(String(line[0]), int(line[1]), line[2]))
	if DisplayServer.get_name() != "headless":
		Audio.play("print_feed", null, -12.0, 0.05, Audio.BUS_UI)


## A tick box drawn in ink: [ ] LABEL, click to tick or untick.
class Tick extends Button:
	signal toggled_on(on: bool)
	var label := ""
	var font: Font
	var checked := false

	func _init() -> void:
		flat = true
		var none := StyleBoxEmpty.new()
		for s in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			add_theme_stylebox_override(s, none)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		pressed.connect(func():
			checked = not checked
			queue_redraw()
			toggled_on.emit(checked))

	func _draw() -> void:
		var h := size.y
		var box := Rect2(2.0, (h - 20.0) * 0.5, 20.0, 20.0)
		draw_rect(box, Fax.INK, false, 2.0)
		if checked:
			var p := box.grow(-3.0)
			draw_line(p.position, p.end, Fax.STAMP_INK, 3.0)
			draw_line(Vector2(p.end.x, p.position.y), Vector2(p.position.x, p.end.y), Fax.STAMP_INK, 3.0)
		elif is_hovered():
			var o := box.position
			draw_polyline(PackedVector2Array([o + Vector2(4, 11), o + Vector2(9, 16), o + Vector2(18, 3)]), Color(Fax.STAMP_INK, 0.6), 2.5)
		if font != null:
			draw_string(font, Vector2(34.0, h * 0.5 + 7.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, Fax.FONT_SIZE, Color(Fax.INK, 0.92))
