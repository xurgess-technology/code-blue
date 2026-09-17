extends Control
## What the break room's wall terminal shows (wall_terminal.gd projects it), 1280x720. Driven like a
## computer by the scan laser: the terminal pushes mouse motion and clicks into its viewport, and
## this draws the laser's cursor on top (a viewport has no OS cursor of its own).
##
## Terminal redesign, chunk 2: one drill-down of cards (content in wall_pages.gd).
##   HOME      a 2x2 grid: Monsters, Procedures, Surgery Items, Other Items, each with an icon
##   SECTION   a 3x3 grid of its entries, PREV / NEXT through more; "???" cards can't be opened
##   ENTRY     a header, a subtitle and a paragraph or two on the left (a monster's ability and its
##             three levels, a procedure's steps, each step opening its surgery item), the entry's
##             3D model turning on the right (model_preview.gd)
## BACK goes up one page (a procedure's item goes back to the procedure), HOME to the top.
## Chunk 3 adds signing in; chunk 4 shares the page between players.

const Pages := preload("res://scripts/database/wall_pages.gd")
const ModelPreview := preload("res://scripts/database/model_preview.gd")
const MonsterModel := preload("res://scripts/monsters/monster_model.gd")
const MonsterPages := preload("res://scripts/database/monster_pages.gd")

const W := 1280.0
const H := 720.0
const MARGIN := 48.0
const BODY_Y := 128.0

const BG := Color(0.02, 0.05, 0.035)
const GREEN := Color(0.45, 1.0, 0.55)
const GREEN_DIM := Color(0.55, 0.75, 0.6)
const CARD := Color(0.04, 0.1, 0.065)
const CARD_HOT := Color(0.08, 0.2, 0.12)
const CURSOR := Color(0.36, 0.88, 0.82)
const PER_PAGE := 9

## The page on screen: {kind: "home"} | {kind: "section", id, index} | {kind: "entry", section, key}
var page: Dictionary = {"kind": "home"}
var _history: Array = []
var _body: Control
var _crumb: Label
var _back: Button
var _home: Button
var _preview: SubViewportContainer
var _cursor := Vector2.ZERO
var _cursor_on := false
var _pulse_at := Vector2.ZERO
var _pulse_t := -1.0
var _overlay: Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := _label("COUNTY GENERAL  /  STAFF DATABASE", 30, GREEN)
	title.position = Vector2(MARGIN, 26)
	add_child(title)
	_crumb = _label("", 22, GREEN_DIM)
	_crumb.position = Vector2(MARGIN + 2, 70)
	add_child(_crumb)
	_home = _button("HOME", Vector2(130, 56), 24)
	_home.position = Vector2(W - MARGIN - 130, 30)
	_home.pressed.connect(go_home)
	add_child(_home)
	_back = _button("< BACK", Vector2(150, 56), 24)
	_back.position = Vector2(W - MARGIN - 130 - 16 - 150, 30)
	_back.pressed.connect(back)
	add_child(_back)

	var line := ColorRect.new()
	line.color = Color(GREEN, 0.35)
	line.position = Vector2(MARGIN, 108)
	line.size = Vector2(W - MARGIN * 2, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)

	_body = Control.new()
	_body.position = Vector2(MARGIN, BODY_Y)
	_body.size = Vector2(W - MARGIN * 2, H - BODY_Y - 24)
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_body)

	_preview = ModelPreview.new()
	_preview.position = Vector2(800, BODY_Y)
	_preview.size = Vector2(W - MARGIN - 800, H - BODY_Y - 30)
	_preview.visible = false
	add_child(_preview)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_show()


func _process(delta: float) -> void:
	if _pulse_t >= 0.0:
		_pulse_t += delta
		if _pulse_t > 0.35:
			_pulse_t = -1.0
		_overlay.queue_redraw()


func _game() -> Node:
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


# ---------------------------------------------------------------------------
# navigation

func go_home() -> void:
	_history.clear()
	page = {"kind": "home"}
	_show()


func back() -> void:
	page = _history.pop_back() if not _history.is_empty() else {"kind": "home"}
	_show()


func open(to: Dictionary) -> void:
	_history.append(page)
	page = to
	_show()


func _show() -> void:
	for c in _body.get_children():
		c.queue_free()
	var at_home := String(page.kind) == "home"
	_back.visible = not at_home
	_home.visible = not at_home
	_preview.visible = false
	match String(page.kind):
		"home":
			_crumb.text = "HOME"
			_draw_home()
		"section":
			_crumb.text = "HOME  >  %s" % _section_title(String(page.id))
			_draw_section(String(page.id), int(page.get("index", 0)))
		"entry":
			_draw_entry(String(page.section), String(page.key))


func _section_title(id: String) -> String:
	for s in Pages.SECTIONS:
		if s.id == id:
			return String(s.title)
	return id.to_upper()


# ---------------------------------------------------------------------------
# home: the 2x2 grid

func _draw_home() -> void:
	var gap := 28.0
	var cw := (_body.size.x - gap) * 0.5
	var ch := (_body.size.y - gap - 10.0) * 0.5
	for i in Pages.SECTIONS.size():
		var s: Dictionary = Pages.SECTIONS[i]
		var card := _button("", Vector2(cw, ch), 40)
		card.position = Vector2((i % 2) * (cw + gap), (i / 2) * (ch + gap))
		var id: String = s.id
		card.pressed.connect(func(): open({"kind": "section", "id": id, "index": 0}))
		_body.add_child(card)
		var icon := Icon.new()
		icon.kind = id
		icon.position = Vector2(34, (ch - 170) * 0.5)
		icon.size = Vector2(170, 170)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(icon)
		var t := _label(String(s.title), 46, GREEN)
		t.position = Vector2(240, ch * 0.5 - 30)
		card.add_child(t)


# ---------------------------------------------------------------------------
# a section: 3x3 cards, a page at a time

func _draw_section(id: String, index: int) -> void:
	var list := Pages.entries(id, _game())
	var pages := maxi(1, ceili(float(list.size()) / PER_PAGE))
	index = clampi(index, 0, pages - 1)
	page["index"] = index
	var gap := 18.0
	var grid_h := _body.size.y - 76.0
	var cw := (_body.size.x - gap * 2.0) / 3.0
	var ch := (grid_h - gap * 2.0) / 3.0
	for n in PER_PAGE:
		var i := index * PER_PAGE + n
		if i >= list.size():
			break
		var e: Dictionary = list[i]
		var known := bool(e.known)
		var card := _button(String(e.title).to_upper() if known else "???", Vector2(cw, ch), 30)
		card.position = Vector2((n % 3) * (cw + gap), (n / 3) * (ch + gap))
		card.disabled = not known
		var key: String = e.key
		card.pressed.connect(func(): open({"kind": "entry", "section": id, "key": key}))
		_body.add_child(card)
	if pages > 1:
		var prev := _button("< PREV", Vector2(190, 56), 26)
		prev.position = Vector2(0, grid_h + 14)
		prev.disabled = index <= 0
		prev.pressed.connect(func():
			page["index"] = index - 1
			_show())
		_body.add_child(prev)
		var nxt := _button("NEXT >", Vector2(190, 56), 26)
		nxt.position = Vector2(_body.size.x - 190, grid_h + 14)
		nxt.disabled = index >= pages - 1
		nxt.pressed.connect(func():
			page["index"] = index + 1
			_show())
		_body.add_child(nxt)
		var of := _label("PAGE %d / %d" % [index + 1, pages], 24, GREEN_DIM)
		of.position = Vector2(_body.size.x * 0.5 - 70, grid_h + 26)
		_body.add_child(of)


# ---------------------------------------------------------------------------
# an entry: text on the left, the model turning on the right

func _draw_entry(section: String, key: String) -> void:
	var p := Pages.page(section, key, _game())
	_crumb.text = "HOME  >  %s  >  %s" % [_section_title(section), String(p.get("title", key))]
	var col_w := 640.0
	var y := 0.0
	var head := _label(String(p.get("title", "")), 48, GREEN)
	head.position = Vector2(0, y)
	_body.add_child(head)
	y += 62.0
	var sub := _label(String(p.get("subtitle", "")), 20, GREEN_DIM)
	sub.position = Vector2(2, y)
	_body.add_child(sub)
	y += 42.0
	for text in p.get("paragraphs", []):
		if String(text).strip_edges() == "":
			continue
		var para := _para(String(text), 25, Color(0.8, 0.95, 0.83), col_w)
		para.position = Vector2(0, y)
		_body.add_child(para)
		y += float(para.get_line_count()) * 34.0 + 18.0
	if p.has("ability"):
		var ab: Dictionary = p.ability
		var at := _label("ABILITY:  %s" % String(ab.name), 28, GREEN)
		at.position = Vector2(0, y + 4)
		_body.add_child(at)
		y += 50.0
		for n in (ab.levels as Array).size():
			var known := String(ab.levels[n]) != "???"
			var lv := _label("LEVEL %d    %s" % [n + 1, String(ab.levels[n])], 24, Color(0.8, 0.95, 0.83) if known else GREEN_DIM)
			lv.position = Vector2(20, y)
			_body.add_child(lv)
			y += 36.0
	if String(p.get("hint", "")) != "":
		var hint := _para(String(p.hint), 20, GREEN_DIM, col_w)
		hint.position = Vector2(0, y + 6)
		_body.add_child(hint)
	_show_models(section + ":" + key, p.get("models", []))


## A wrapped paragraph `width` wide (it never runs under the model on the right).
func _para(text: String, size_px: int, col: Color, width: float) -> Label:
	var l := _label(text, size_px, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(width, 0)
	l.size = Vector2(width, 0)
	return l


func _show_models(key: String, specs: Array) -> void:
	_preview.visible = true
	if _preview.current_key() == key:
		return
	var models: Array = []
	for m in specs:
		var d: Dictionary = m
		if d.has("monster"):
			var mm: Node3D = MonsterModel.new()
			mm.set_meta("preview_monster", String(d.monster))
			var h := float(MonsterPages.entry(String(d.monster)).get("height", 1.9))
			mm.set_meta("preview_bounds", AABB(Vector3(-0.35, 0.0, -0.3), Vector3(0.7, h, 0.6)))
			models.append(mm)
		else:
			var im: Node3D = ItemModels.make(String(d.item), int(d.get("count", 1)))
			if d.has("link"):
				im.set_meta("preview_link", String(d.link))
				im.set_meta("preview_label", String(d.get("label", d.link)))
			models.append(im)
	_preview.show_models(key, models, false)


## The laser on the screen: over a linked model its name shows; a click on it opens its page. Motion
## never reaches _gui_input here (nothing under the pointer takes it), so hovering reads every motion.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_preview.set_hover(_preview.pick((event as InputEventMouse).position - _preview.position) if _preview.visible else null)


func _gui_input(event: InputEvent) -> void:
	if not _preview.visible or not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	var hit: Node3D = _preview.pick((event as InputEventMouse).position - _preview.position)
	if hit != null and hit.has_meta("preview_link"):
		open({"kind": "entry", "section": "surgery", "key": String(hit.get_meta("preview_link"))})
		accept_event()


# ---------------------------------------------------------------------------
# the laser cursor

func set_cursor(px: Vector2, on: bool) -> void:
	_cursor = px
	_cursor_on = on
	_overlay.queue_redraw()


func pulse(px: Vector2) -> void:
	_pulse_at = px
	_pulse_t = 0.0
	_overlay.queue_redraw()


func _draw_overlay() -> void:
	if _pulse_t >= 0.0:
		var k := _pulse_t / 0.35
		_overlay.draw_arc(_pulse_at, lerpf(8.0, 46.0, k), 0.0, TAU, 32, Color(CURSOR, 1.0 - k), 4.0)
	if not _cursor_on:
		return
	_overlay.draw_circle(_cursor, 7.0, Color(CURSOR, 0.95))
	_overlay.draw_arc(_cursor, 16.0, 0.0, TAU, 32, Color(CURSOR, 0.6), 2.5)


# ---------------------------------------------------------------------------
# pieces

func _label(text: String, size_px: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, sz: Vector2, font_px: int) -> Button:
	var b := Button.new()
	b.text = text
	b.size = sz
	b.custom_minimum_size = sz
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.add_theme_font_size_override("font_size", font_px)
	b.add_theme_color_override("font_color", GREEN)
	b.add_theme_color_override("font_hover_color", Color(0.8, 1.0, 0.85))
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(GREEN_DIM, 0.45))
	var states := {"normal": [CARD, Color(GREEN, 0.4)], "hover": [CARD_HOT, GREEN], "pressed": [Color(0.15, 0.35, 0.2), Color.WHITE],
		"disabled": [Color(CARD, 0.5), Color(GREEN_DIM, 0.2)]}
	for st in states.keys():
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[st][0]
		sb.border_color = states[st][1]
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 18
		sb.content_margin_right = 18
		b.add_theme_stylebox_override(st, sb)
	return b


## A section's icon, drawn in terminal green: a hunched figure with eyes, a clipboard, crossed
## surgical tools, a pill bottle and a box.
class Icon extends Control:
	var kind := ""

	func _draw() -> void:
		var c := Color(0.45, 1.0, 0.55)
		var dim := Color(0.45, 1.0, 0.55, 0.35)
		var s := size
		var w := 5.0
		match kind:
			"monsters":
				var head := Vector2(s.x * 0.5, s.y * 0.3)
				draw_arc(head, s.x * 0.2, 0.0, TAU, 32, c, w)
				draw_circle(head + Vector2(-s.x * 0.07, -2), 7.0, c)
				draw_circle(head + Vector2(s.x * 0.07, -2), 7.0, c)
				draw_polyline(PackedVector2Array([Vector2(s.x * 0.18, s.y * 0.98), Vector2(s.x * 0.24, s.y * 0.6),
					Vector2(s.x * 0.5, s.y * 0.5), Vector2(s.x * 0.76, s.y * 0.6), Vector2(s.x * 0.82, s.y * 0.98)]), c, w)
				for k in 3:
					draw_line(Vector2(s.x * (0.3 + k * 0.08), s.y * 0.95), Vector2(s.x * (0.33 + k * 0.08), s.y * 0.78), dim, 3.0)
			"procedures":
				var r := Rect2(s.x * 0.2, s.y * 0.12, s.x * 0.6, s.y * 0.84)
				draw_rect(r, c, false, w)
				draw_rect(Rect2(s.x * 0.38, s.y * 0.05, s.x * 0.24, s.y * 0.12), c, true)
				for k in 4:
					var yy := s.y * (0.34 + k * 0.15)
					draw_rect(Rect2(s.x * 0.28, yy - 8, 16, 16), c, false, 3.0)
					draw_line(Vector2(s.x * 0.42, yy), Vector2(s.x * 0.72, yy), dim if k > 1 else c, 4.0)
			"surgery":
				draw_line(Vector2(s.x * 0.15, s.y * 0.85), Vector2(s.x * 0.85, s.y * 0.15), c, w + 3)
				draw_line(Vector2(s.x * 0.62, s.y * 0.38), Vector2(s.x * 0.85, s.y * 0.15), Color.WHITE, 2.0)
				draw_line(Vector2(s.x * 0.2, s.y * 0.15), Vector2(s.x * 0.62, s.y * 0.6), c, w)
				draw_line(Vector2(s.x * 0.15, s.y * 0.22), Vector2(s.x * 0.55, s.y * 0.68), c, w)
				draw_arc(Vector2(s.x * 0.68, s.y * 0.72), s.x * 0.1, 0.0, TAU, 24, c, w)
			"other":
				var body := Rect2(s.x * 0.12, s.y * 0.38, s.x * 0.34, s.y * 0.56)
				draw_rect(body, c, false, w)
				draw_rect(Rect2(s.x * 0.1, s.y * 0.26, s.x * 0.38, s.y * 0.12), c, true)
				draw_line(Vector2(s.x * 0.12, s.y * 0.58), Vector2(s.x * 0.46, s.y * 0.58), dim, 4.0)
				var box := Rect2(s.x * 0.54, s.y * 0.5, s.x * 0.36, s.y * 0.44)
				draw_rect(box, c, false, w)
				draw_line(Vector2(s.x * 0.54, s.y * 0.5), Vector2(s.x * 0.64, s.y * 0.38), c, w)
				draw_line(Vector2(s.x * 0.9, s.y * 0.5), Vector2(s.x * 0.98, s.y * 0.38), c, w)
				draw_line(Vector2(s.x * 0.64, s.y * 0.38), Vector2(s.x * 0.98, s.y * 0.38), c, w)
