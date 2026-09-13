class_name GuideUI
extends CanvasLayer
## The medical guide: a battered reference binder, open as a two-page spread over a blurred,
## darkened view of the world. See docs/CONTRACTS.md, "Medical guide".
##
##   open(page)  page = an item kind, "procedure:<ailment>", "locked:<name>" or "" for the index
##   close()     slides the binder away and emits `closed`
##   is_open()   true from open() until close() is called
##
## Every spread is built from data (guide_pages.gd reads Items and Procedures), so adding an
## item, an ailment or a locked placeholder adds its tab, contents line and page automatically.
##
## Controls while open: A/D or Left/Right (also PageUp/PageDown, mouse back/forward) turn the
## page, 1-9 jump to that tab, 0 or Home goes to the index, W/S or Up/Down and the mouse wheel
## scroll a long page, click tabs, contents lines or step items to jump, Esc or R closes.
## The guide never touches the mouse mode: the main scene frees the mouse while is_open().

signal closed

const Art := preload("res://scripts/guide/guide_art.gd")
const Pages := preload("res://scripts/guide/guide_pages.gd")
const W := preload("res://scripts/guide/guide_widgets.gd")
const Viewer := preload("res://scripts/guide/guide_viewer.gd")

## Layout, in the project's 1600x900 canvas space.
const DESIGN := Vector2(1600, 900)
const TAB_OUT := 128.0
const PAD := 14.0
const PAGE := Vector2(606, 768)
const SPINE := 30.0
const BOOK := Vector2(PAGE.x * 2 + SPINE + PAD * 2 + TAB_OUT * 2, PAGE.y + PAD * 2)
const MARGIN_OUT := 50.0
const MARGIN_GUT := 46.0
const MARGIN_TOP := 44.0
const MARGIN_BOTTOM := 60.0

const FLIP_TIME := 0.46
const OPEN_TIME := 0.5
const CLOSE_TIME := 0.32
const BODY_SIZE := 18

var entries: Array = []

var _root: Control
var _backdrop: ColorRect
var _book: Control
var _tabs: Array = []
var _left_slot: Control
var _right_slot: Control
var _hint: Label
var _left: Control
var _right: Control
var _spread := 0
var _open := false
var _closing := false
var _opened_frame := -10
var _flip := {}
var _flip_hold := -1.0
var _tween: Tween


func _ready() -> void:
	layer = 60   # above the look pass's post layer (50) so the text is not grained or warped
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	entries = Pages.entries()
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func open(page: String = "") -> void:
	var idx := Pages.index_of(entries, page)
	if _open and not _closing:
		_go(idx)
		return
	if _tween != null:
		_tween.kill()
	var was_closing := _closing
	_open = true
	_closing = false
	_opened_frame = Engine.get_process_frames()
	if not was_closing or idx != _spread:
		_finish_flip()
		_show_spread(idx)
	visible = true
	_set_viewers_active(true)
	_layout()
	_sfx("guide_open")
	var vs := _visible_size()
	if not was_closing:
		_book.position.y = _rest_y() + vs.y * 0.95
		_book.rotation_degrees = 5.0
		_set_backdrop(0.0)
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "position:y", _rest_y(), OPEN_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_book, "rotation_degrees", 0.0, OPEN_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_backdrop, _backdrop_amount(), 1.0, 0.3)
	_tween.tween_property(_hint, "modulate:a", 1.0, 0.4).set_delay(0.25)


func close() -> void:
	if not _open or _closing:
		return
	_closing = true
	_finish_flip()
	_sfx("guide_close")
	if _tween != null:
		_tween.kill()
	var vs := _visible_size()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "position:y", _rest_y() + vs.y * 0.95, CLOSE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(_book, "rotation_degrees", -4.0, CLOSE_TIME).set_ease(Tween.EASE_IN)
	_tween.tween_method(_set_backdrop, _backdrop_amount(), 0.0, CLOSE_TIME)
	_tween.tween_property(_hint, "modulate:a", 0.0, 0.12)
	_tween.chain().tween_callback(_closed_done)
	closed.emit()


func is_open() -> bool:
	return _open and not _closing


## The page id currently showing ("" for the index).
func current_page() -> String:
	return entries[_spread].id


func is_settled() -> bool:
	return _flip.is_empty() and (_tween == null or not _tween.is_running())


## Tooling: start turning to `page` and freeze the turn at `progress` (0..1). -1 releases it.
func debug_hold_flip(page: String, progress: float) -> void:
	_flip_hold = progress
	if progress >= 0.0 and _flip.is_empty():
		_go(Pages.index_of(entries, page))
	if not _flip.is_empty():
		_apply_flip(maxf(progress, 0.0) if progress >= 0.0 else _flip.t)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "GuideRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = _theme()
	add_child(_root)

	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bm := ShaderMaterial.new()
	bm.shader = Art.shader("backdrop")
	_backdrop.material = bm
	_root.add_child(_backdrop)

	_book = Control.new()
	_book.name = "Book"
	_book.size = BOOK
	_book.pivot_offset = BOOK * 0.5
	_book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_book)

	var lrect := _page_rect(-1.0)
	var rrect := _page_rect(1.0)
	var board := W.Board.new(Vector2(BOOK.x - TAB_OUT * 2, BOOK.y),
		Rect2(lrect.position - Vector2(TAB_OUT, 0), lrect.size), Rect2(rrect.position - Vector2(TAB_OUT, 0), rrect.size))
	board.position = Vector2(TAB_OUT, 0)
	_book.add_child(board)

	var tab_layer := Control.new()
	tab_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab_layer.size = BOOK
	_book.add_child(tab_layer)
	var n := entries.size()
	var spacing := minf(46.0, (PAGE.y - 16.0) / float(n))
	var y0 := PAD + 8.0 + ((PAGE.y - 16.0) - spacing * n) * 0.5
	for i in n:
		var e: Dictionary = entries[i]
		var key := "0" if i == 0 else (str(i) if i <= 9 else "")
		var tab := W.Tab.new(i, e.tab, e.colour, key, e.type == "locked", Vector2(TAB_OUT + PAD + 12.0, spacing - 5.0))
		tab.position.y = y0 + spacing * i
		tab.chosen.connect(_go)
		tab.mouse_entered.connect(_place_tabs.bind(true))
		tab.mouse_exited.connect(_place_tabs.bind(true))
		tab_layer.add_child(tab)
		_tabs.append(tab)

	_book.add_child(W.Edges.new(BOOK, lrect, rrect))

	_left_slot = Control.new()
	_left_slot.position = lrect.position
	_left_slot.size = PAGE
	_left_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book.add_child(_left_slot)
	_right_slot = Control.new()
	_right_slot.position = rrect.position
	_right_slot.size = PAGE
	_right_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book.add_child(_right_slot)

	var rings := W.Rings.new(BOOK, BOOK.x * 0.5, PAD, PAGE.y)
	rings.z_index = 3
	_book.add_child(rings)

	_hint = Label.new()
	_hint.text = "A / D  turn the page      1-9  jump to a tab      0  index      wheel  scroll      Esc / R  put it down"
	_hint.add_theme_font_override("font", Art.font("type_bold"))
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(0.9, 0.85, 0.74, 0.85))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.modulate.a = 0.0
	_root.add_child(_hint)


func _theme() -> Theme:
	var t := Theme.new()
	t.default_font = Art.font("serif")
	t.default_font_size = BODY_SIZE
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_stylebox("focus", "RichTextLabel", StyleBoxEmpty.new())
	return t


func _page_rect(side: float) -> Rect2:
	var x := TAB_OUT + PAD
	if side > 0.0:
		x += PAGE.x + SPINE
	return Rect2(Vector2(x, PAD), PAGE)


func _visible_size() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else DESIGN


func _rest_y() -> float:
	# The book scales and tilts about its centre, so its position is its centre minus half size.
	var vs := _visible_size()
	return vs.y * 0.5 - BOOK.y * 0.5 - 22.0 * _book.scale.y


func _layout() -> void:
	if _book == null:
		return
	var vs := _visible_size()
	var s := minf(1.0, minf(vs.x / (BOOK.x + 40.0), vs.y / (BOOK.y + 90.0)))
	_book.scale = Vector2(s, s)
	_book.pivot_offset = BOOK * 0.5
	_book.position.x = vs.x * 0.5 - BOOK.x * 0.5
	if _tween == null or not _tween.is_running():
		_book.position.y = _rest_y()
	_hint.size = Vector2(vs.x, 24)
	_hint.position = Vector2(0, vs.y * 0.5 - 22.0 * s + (BOOK.y * 0.5 + 10.0) * s)


func _set_backdrop(v: float) -> void:
	(_backdrop.material as ShaderMaterial).set_shader_parameter("amount", v)


func _backdrop_amount() -> float:
	var v = (_backdrop.material as ShaderMaterial).get_shader_parameter("amount")
	return float(v) if v != null else 0.0


func _closed_done() -> void:
	if not _closing:
		return
	_closing = false
	_open = false
	visible = false
	_set_viewers_active(false)


# ---------------------------------------------------------------------------
# Navigation and the page turn
# ---------------------------------------------------------------------------

func _show_spread(idx: int) -> void:
	idx = clampi(idx, 0, entries.size() - 1)
	for c in _left_slot.get_children():
		c.queue_free()
	for c in _right_slot.get_children():
		c.queue_free()
	var pair := _build_spread(idx)
	_left = pair[0]
	_right = pair[1]
	_left_slot.add_child(_left)
	_right_slot.add_child(_right)
	_spread = idx
	_place_tabs(false)


func _go(idx: int) -> void:
	idx = clampi(idx, 0, entries.size() - 1)
	if idx == _spread and _flip.is_empty():
		return
	if not _flip.is_empty():
		_finish_flip()
		if idx == _spread:
			return
	if not _open or _closing or not is_inside_tree():
		_show_spread(idx)
		return
	var dir := 1 if idx > _spread else -1
	var pair := _build_spread(idx)
	var new_l: Control = pair[0]
	var new_r: Control = pair[1]
	var f := {"t": 0.0, "old_l": _left, "old_r": _right, "new_l": new_l, "new_r": new_r}
	_left_slot.add_child(new_l)
	_right_slot.add_child(new_r)
	if dir > 0:
		_right_slot.move_child(new_r, 0)
		f.leaf_a = _right
		f.leaf_b = new_l
		f.under_new = new_r
		f.under_old = _left
		_right.pivot_offset = Vector2(0, PAGE.y * 0.5)
		new_l.pivot_offset = Vector2(PAGE.x, PAGE.y * 0.5)
	else:
		_left_slot.move_child(new_l, 0)
		f.leaf_a = _left
		f.leaf_b = new_r
		f.under_new = new_l
		f.under_old = _right
		_left.pivot_offset = Vector2(PAGE.x, PAGE.y * 0.5)
		new_r.pivot_offset = Vector2(0, PAGE.y * 0.5)
	(f.leaf_a as Control).z_index = 2
	(f.leaf_b as Control).z_index = 2
	(f.leaf_b as Control).visible = false
	_flip = f
	_left = new_l
	_right = new_r
	_spread = idx
	_place_tabs(true)
	_sfx("guide_flip", -2.0, 0.08)
	_apply_flip(maxf(_flip_hold, 0.0))


func _apply_flip(t: float) -> void:
	if _flip.is_empty():
		return
	_flip.t = t
	var e := smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))
	var a: Control = _flip.leaf_a
	var b: Control = _flip.leaf_b
	var lift := 1.0 + 0.018 * sin(e * PI)
	if e < 0.5:
		var k := cos(e * PI)
		a.visible = true
		a.scale = Vector2(maxf(k, 0.001), lift)
		_shade(a, (1.0 - k) * 0.5)
		b.visible = false
		_gutter(_flip.under_new, k * 0.45)
		_gutter(_flip.under_old, 0.0)
	else:
		var k := -cos(e * PI)
		a.visible = false
		b.visible = true
		b.scale = Vector2(maxf(k, 0.001), lift)
		_shade(b, (1.0 - k) * 0.5)
		_gutter(_flip.under_new, 0.0)
		_gutter(_flip.under_old, (1.0 - k) * 0.45)


func _finish_flip() -> void:
	if _flip.is_empty():
		return
	var f := _flip
	_flip = {}
	for key in ["old_l", "old_r"]:
		var n: Node = f[key]
		if is_instance_valid(n):
			n.queue_free()
	for key in ["new_l", "new_r"]:
		var p: Control = f[key]
		p.visible = true
		p.scale = Vector2.ONE
		p.z_index = 0
		_shade(p, 0.0)
		_gutter(p, 0.0)


func _shade(page: Control, v: float) -> void:
	if page is W.Page:
		(page as W.Page).set_shade(v)


func _gutter(page: Control, v: float) -> void:
	if page is W.Page:
		(page as W.Page).set_gutter_shade(v)


func _place_tabs(animate: bool) -> void:
	var lrect := _page_rect(-1.0)
	var rrect := _page_rect(1.0)
	for tab in _tabs:
		var t: W.Tab = tab
		var right_side := t.index >= _spread
		t.side = 1.0 if right_side else -1.0
		t.current = t.index == _spread
		var out := (8.0 if t.hover else 0.0) + (6.0 if t.current else 0.0)
		var x: float
		if right_side:
			x = rrect.end.x - 12.0 + out
		else:
			x = lrect.position.x + 12.0 - t.size.x - out
		t.queue_redraw()
		if animate and is_inside_tree():
			var tw := t.create_tween()
			tw.tween_property(t, "position:x", x, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		else:
			t.position.x = x


func _process(delta: float) -> void:
	if _flip.is_empty():
		return
	if _flip_hold >= 0.0:
		_apply_flip(_flip_hold)
		return
	var t: float = _flip.t + delta / FLIP_TIME
	if t >= 1.0:
		_finish_flip()
	else:
		_apply_flip(t)


func _input(event: InputEvent) -> void:
	if not _open or _closing:
		return
	var handled := true
	if event is InputEventKey and event.pressed:
		var k: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if event.echo and k not in [KEY_UP, KEY_DOWN, KEY_W, KEY_S]:
			get_viewport().set_input_as_handled()
			return
		match k:
			KEY_ESCAPE, KEY_R:
				if Engine.get_process_frames() != _opened_frame:
					close()
			KEY_LEFT, KEY_A, KEY_PAGEUP, KEY_BACKSPACE:
				_go(_spread - 1)
			KEY_RIGHT, KEY_D, KEY_PAGEDOWN, KEY_SPACE:
				_go(_spread + 1)
			KEY_HOME, KEY_0, KEY_KP_0:
				_go(0)
			KEY_END:
				_go(entries.size() - 1)
			KEY_UP, KEY_W:
				_scroll(-70.0)
			KEY_DOWN, KEY_S:
				_scroll(70.0)
			_:
				if k >= KEY_1 and k <= KEY_9:
					_go(k - KEY_0)
				elif k >= KEY_KP_1 and k <= KEY_KP_9:
					_go(k - KEY_KP_0)
				elif event.is_action_pressed("pause") or event.is_action_pressed("read"):
					if Engine.get_process_frames() != _opened_frame:
						close()
				else:
					handled = false
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_XBUTTON1: _go(_spread - 1)
			MOUSE_BUTTON_XBUTTON2: _go(_spread + 1)
			_: handled = false
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _scroll(amount: float) -> void:
	for page in [_right, _left]:
		if page != null and page.has_meta("scroll"):
			var sc: ScrollContainer = page.get_meta("scroll")
			if is_instance_valid(sc) and sc.get_v_scroll_bar().max_value > sc.size.y + 1.0:
				sc.scroll_vertical = int(sc.scroll_vertical + amount)
				return


func _on_meta(meta) -> void:
	_go(Pages.index_of(entries, str(meta)))


func _sfx(cue: String, vol := 0.0, jitter := 0.0) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play"):
		audio.play(cue, null, vol, jitter)


func _set_viewers_active(on: bool) -> void:
	for slot in [_left_slot, _right_slot]:
		for page in slot.get_children():
			for v in page.find_children("*", "SubViewport", true, false):
				(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


# ---------------------------------------------------------------------------
# Spreads
# ---------------------------------------------------------------------------

func _build_spread(idx: int) -> Array:
	var e: Dictionary = entries[idx]
	match e.type:
		"item": return _item_spread(e)
		"procedure": return _procedure_spread(e)
		"locked": return _locked_spread(e)
	return _index_spread(e)


func _new_page(e: Dictionary, side: float, torn := -1.0) -> W.Page:
	var p := W.Page.new("%s|%d" % [e.id, int(side)], side, PAGE, torn)
	p.name = "Page_%s_%s" % [e.type, "L" if side < 0.0 else "R"]
	if torn < 0.0:
		var no := int(e.page) + (0 if side < 0.0 else 1)
		var num := W.Scribble.new("- %d -" % no, "type", 14, Art.INK_SOFT, 80.0)
		num.position = Vector2(MARGIN_OUT - 6.0 if side < 0.0 else PAGE.x - MARGIN_OUT - 70.0, PAGE.y - 36.0)
		p.add_child(num)
		var head_text: String = "NIGHT SHIFT MEDICAL GUIDE" if side < 0.0 else String(e.title).to_upper()
		var head := W.Scribble.new(head_text, "type", 12, Color(Art.INK_SOFT, 0.8), 400.0)
		head.position = Vector2(MARGIN_OUT if side < 0.0 else PAGE.x - MARGIN_OUT - 400.0, 16.0)
		if side > 0.0:
			head.align = HORIZONTAL_ALIGNMENT_RIGHT
		p.add_child(head)
	return p


func _content_x(side: float) -> float:
	return MARGIN_OUT if side < 0.0 else MARGIN_GUT


func _content_w() -> float:
	return PAGE.x - MARGIN_OUT - MARGIN_GUT


func _add(page: Control, node: Control, pos: Vector2) -> Control:
	node.position = pos
	page.add_child(node)
	return node


func _rtl(width: float) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(width, 0)
	r.size = Vector2(width, 10)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_theme_font_override("normal_font", Art.font("serif"))
	r.add_theme_font_override("bold_font", Art.font("serif_bold"))
	r.add_theme_font_override("italics_font", Art.font("serif_italic"))
	r.add_theme_font_override("mono_font", Art.font("type"))
	for s in ["normal_font_size", "bold_font_size", "italics_font_size"]:
		r.add_theme_font_size_override(s, BODY_SIZE)
	r.add_theme_font_size_override("mono_font_size", 17)
	r.add_theme_color_override("default_color", Art.INK)
	r.add_theme_constant_override("line_separation", 2)
	r.mouse_filter = Control.MOUSE_FILTER_PASS
	r.meta_clicked.connect(_on_meta)
	return r


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _heading(text: String, width: float, fsize := 19) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s := W.Scribble.new(text.to_upper(), "type_bold", fsize, Art.INK, width)
	s.custom_minimum_size = s.size
	box.add_child(s)
	var r := W.Rule.new(width)
	box.add_child(r)
	return box


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _scroll_box(page: Control, pos: Vector2, box_size: Vector2) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.position = pos
	sc.size = box_size
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	page.add_child(sc)
	page.set_meta("scroll", sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	sc.add_child(v)
	return v


## A scribble wrapped so a container can lay it out while it keeps its tilt.
func _held(s: Control, indent := 0.0) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(s.size.x + indent, s.size.y + 8.0)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.position = Vector2(indent, 4.0)
	holder.add_child(s)
	return holder


# --- index ---------------------------------------------------------------------

func _index_spread(e: Dictionary) -> Array:
	var L := _new_page(e, -1.0)
	var R := _new_page(e, 1.0)
	var x := _content_x(-1.0)
	var w := _content_w()
	L.set_ring(Vector2(455, 668), 64.0, 0.8)

	_add(L, W.Scribble.new("SURGICAL SERVICES  /  NIGHT SHIFT", "type", 15, Art.INK_SOFT, w), Vector2(x, 48))
	_add(L, W.Scribble.new("MEDICAL\nGUIDE", "type_bold", 58, Art.INK, w), Vector2(x, 72))
	var blurb := _rtl(w)
	blurb.text = "[i]Instruments, supplies and procedure checklists for whoever is on call tonight. Third binder. The first two walked.[/i]"
	_add(L, blurb, Vector2(x, 214))
	_add(L, W.Rule.new(w), Vector2(x, 290))
	var scrawl := W.Scribble.new("DO NOT REMOVE", "marker", 60, Art.RED_INK, w, -6.0)
	scrawl.underline = true
	_add(L, scrawl, Vector2(x - 4, 312))
	_add(L, W.Scribble.new("(from this room. this means YOU)", "hand", 22, Art.BLUE_PEN, 420.0, -3.0), Vector2(x + 70, 398))

	_add(L, W.Scribble.new("HOW TO READ THIS BINDER", "type_bold", 17, Art.INK, w), Vector2(x, 460))
	var how := _rtl(w)
	how.add_theme_font_size_override("mono_font_size", 16)
	how.text = "[code]Tabs, lines     click to jump\nA / D  <- ->     turn the page\n1 - 9            jump to that tab\n0                back to this page\nWheel, W / S     scroll a long page\nEsc or R         put it down[/code]"
	_add(L, how, Vector2(x, 490))

	var rx := _content_x(1.0)
	var box := _scroll_box(R, Vector2(rx, MARGIN_TOP), Vector2(w, PAGE.y - MARGIN_TOP - MARGIN_BOTTOM))
	box.add_theme_constant_override("separation", 1)
	box.add_child(_heading("Contents", w, 26))
	box.add_child(_spacer(4))
	var groups := [["item", "Instruments & supplies"], ["procedure", "Procedures"], ["locked", "Missing sections"]]
	for g in groups:
		var h := W.Scribble.new(g[1], "serif_bold", 19, Art.INK_SOFT if g[0] == "locked" else Art.INK, w)
		h.custom_minimum_size = h.size
		box.add_child(h)
		for i in entries.size():
			var en: Dictionary = entries[i]
			if en.type != g[0]:
				continue
			var key := str(i) if i >= 1 and i <= 9 else ""
			var row := W.LinkRow.new(en.id, en.title, str(en.page), w, en.colour, key, en.type == "locked")
			row.custom_minimum_size.y = 28
			row.chosen.connect(_on_meta)
			box.add_child(row)
		box.add_child(_spacer(6))
	return [L, R]


# --- item ----------------------------------------------------------------------

func _item_spread(e: Dictionary) -> Array:
	var d := Pages.item_page(e.key)
	var L := _new_page(e, -1.0)
	var R := _new_page(e, 1.0)
	var x := _content_x(-1.0)
	var w := _content_w()
	var file_no := entries.find(e)

	_add(L, W.Scribble.new("INSTRUMENTS & SUPPLIES  /  FILE %02d" % file_no, "type", 15, Art.INK_SOFT, w), Vector2(x, 48))
	var title := W.Scribble.new(d.name, "type_bold", 44, Art.INK, w)
	_add(L, title, Vector2(x, 70))
	_add(L, W.Rule.new(w), Vector2(x, 124))

	var photo_size := Vector2(470, 372)
	var photo := W.Photo.new(photo_size, -1.8)
	var viewer: SubViewport = Viewer.new()
	viewer.setup(e.key, d.count, Vector2i(916, 700))
	L.add_child(viewer)
	photo.tex_rect.texture = viewer.get_texture()
	_add(L, photo, Vector2(x + (w - photo_size.x) * 0.5, 150))
	_add(L, W.Tape.new(120, 32, -32.0), Vector2(x + 2, 148))
	_add(L, W.Tape.new(120, 32, 28.0), Vector2(x + w - 124, 140))
	_add(L, W.Scribble.new("fig. %d - %s" % [file_no, d.caption], "hand", 22, Art.BLUE_PEN, w, -1.2), Vector2(x + 20, 536))

	var sx := x + 6.0
	var srot := -6.0
	for s in d.stamps:
		var st := W.Stamp.new(s, Art.RED_INK, 21, srot)
		_add(L, st, Vector2(sx, 584))
		sx += st.size.x + 22.0
		srot = -srot * 0.7
	var ny := 650.0
	for note in d.notes:
		var sc := W.Scribble.new(note, "hand", 23, Art.BLUE_PEN if ny < 660.0 else Art.RED_INK, w - 20, -2.0 + ny * 0.0)
		_add(L, sc, Vector2(x + 14, ny))
		ny += sc.size.y + 2.0

	var rx := _content_x(1.0)
	var box := _scroll_box(R, Vector2(rx, MARGIN_TOP), Vector2(w, PAGE.y - MARGIN_TOP - MARGIN_BOTTOM))
	box.add_child(_heading("Real-world use", w))
	var use := _rtl(w)
	use.text = _esc(d.real_use)
	box.add_child(use)
	box.add_child(_spacer(8))

	box.add_child(_heading("Where to look", w))
	var where := _rtl(w)
	var wt := _esc(d.where)
	var split: Dictionary = d.where_split
	if not split.most.is_empty():
		wt += "\n[b]Most often:[/b] %s." % _esc("; ".join(split.most))
	if not split.sometimes.is_empty():
		wt += "\n[b]Sometimes:[/b] %s." % _esc("; ".join(split.sometimes))
	where.text = wt
	box.add_child(where)
	box.add_child(_spacer(8))

	box.add_child(_heading("Used in", w))
	var used := _rtl(w)
	if d.used_in.is_empty():
		used.text = "[i]No procedure. It will not save anyone, but it might tell you how.[/i]"
	else:
		var lines: Array = []
		for u in d.used_in:
			lines.append("[url=%s][color=#%s]%s[/color][/url]" % [u.link, Art.BLUE_PEN.to_html(false), _esc(u.text)])
		used.text = "\n".join(lines)
	box.add_child(used)
	box.add_child(_spacer(8))

	box.add_child(_heading("Handling", w))
	var handling := _rtl(w)
	handling.text = _esc(d.handling)
	box.add_child(handling)
	return [L, R]


# --- procedure -----------------------------------------------------------------

func _procedure_spread(e: Dictionary) -> Array:
	var d := Pages.procedure_page(e.key)
	var L := _new_page(e, -1.0)
	var R := _new_page(e, 1.0)
	var x := _content_x(-1.0)
	var w := _content_w()

	var code := (" / CODE %s" % d.code) if d.code != "" else ""
	_add(L, W.Scribble.new("PROCEDURE CHECKLIST" + code, "type", 15, Art.INK_SOFT, w), Vector2(x, 48))
	_add(L, W.Scribble.new(d.name, "type_bold", 42, Art.INK, w), Vector2(x, 70))
	_add(L, W.Rule.new(w), Vector2(x, 122))
	var box := _scroll_box(L, Vector2(x, 140), Vector2(w, PAGE.y - 140 - MARGIN_BOTTOM))
	var n := 1
	for s in d.steps:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		var num := W.Scribble.new("%d." % n, "type_bold", 30, Art.INK, 46.0)
		num.custom_minimum_size = Vector2(46, 40)
		row.add_child(num)
		var t := _rtl(w - 58)
		t.text = "[font_size=21][b]%s[/b][/font_size]\n[code]Needs: [url=%s][color=#%s]%s[/color][/url][/code]\n[i]%s[/i]" % [
			_esc(s.label), s.item, Art.BLUE_PEN.to_html(false), _esc(s.needs), _esc(s.how)]
		row.add_child(t)
		box.add_child(row)
		box.add_child(_spacer(14))
		n += 1
	box.add_child(_held(W.Scribble.new(d.note, "hand", 23, Art.BLUE_PEN, w - 40, -1.5), 20.0))

	var rx := _content_x(1.0)
	var rows: int = d.shopping.size()
	var note_h := 92.0 + rows * 40.0 + 50.0
	var sticky := W.Sticky.new(Vector2(w - 30, note_h), 1.5)
	sticky.lined = false
	_add(R, sticky, Vector2(rx + 10, 58))
	_add(sticky, W.Scribble.new("Shopping list", "marker", 34, Art.INK, w - 70), Vector2(20, 24))
	var ly := 88.0
	for item in d.shopping:
		var label: String = ("%s  x%d" % [item.name, item.count]) if item.consumable else ("%s  (one)" % item.name)
		if item.fragile:
			label += "  + spares"
		_add(sticky, W.Checkbox.new(22.0, Art.INK), Vector2(26, ly + 9))
		_add(sticky, W.Scribble.new(label, "hand", 27, Art.INK, w - 120), Vector2(72, ly))
		ly += 40.0
	_add(sticky, W.Scribble.new("used up: x-count.  tools stay in the OR.", "hand", 19, Art.INK_SOFT, w - 70), Vector2(20, ly + 10))
	_add(R, W.Tape.new(130, 30, -3.0), Vector2(rx + w * 0.5 - 70, 44))

	var info := _scroll_box(R, Vector2(rx, 58 + note_h + 34), Vector2(w, PAGE.y - (58 + note_h + 34) - MARGIN_BOTTOM))
	R.set_meta("scroll", info)
	info.add_child(_heading("Before you start", w))
	var warn := _rtl(w)
	var wl: Array = []
	for line in d.warnings:
		wl.append("- " + _esc(line))
	warn.text = "\n".join(wl)
	info.add_child(warn)
	info.add_child(_spacer(8))
	info.add_child(_heading("Patient weights (for the dose)", w))
	var pw := _rtl(w)
	pw.text = "\n".join(d.patients.map(func(p): return "- " + _esc(p)))
	info.add_child(pw)
	return [L, R]


# --- locked --------------------------------------------------------------------

func _locked_spread(e: Dictionary) -> Array:
	var d := Pages.locked_page(e.key)
	var L := _new_page(e, -1.0, 64.0)
	var R := _new_page(e, 1.0, 58.0)
	L.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := W.Scribble.new(String(d.name).to_upper(), "marker", 40, Art.INK, 420.0, -3.0)
	label.align = HORIZONTAL_ALIGNMENT_CENTER
	var tape := W.Tape.new(440, 74, -3.0)
	_add(L, tape, Vector2(70, 250))
	_add(L, label, Vector2(80, 262))
	_add(L, W.Scribble.new("pp. %d-%d" % [e.page, int(e.page) + 1], "type", 18, Color(0.85, 0.8, 0.7), 300.0, -3.0), Vector2(200, 340))

	var stamp := W.Stamp.new("PAGES MISSING", Art.RED_INK, 40, -8.0)
	_add(R, stamp, Vector2(120, 160))
	var sticky := W.Sticky.new(Vector2(360, 210), 4.0)
	_add(R, sticky, Vector2(140, 360))
	_add(sticky, W.Scribble.new(d.scrawl, "hand", 28, Art.INK, 320.0), Vector2(22, 36))
	_add(sticky, W.Scribble.new("- M.", "hand", 26, Art.BLUE_PEN, 120.0), Vector2(220, 150))
	return [L, R]
