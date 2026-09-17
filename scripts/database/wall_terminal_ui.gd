extends Control
## What the break room's wall terminal shows (wall_terminal.gd draws it onto the glass), 1280x720.
## Driven like a computer by the scan laser: the terminal pushes mouse motion and clicks into its
## viewport, and this draws the laser's cursor on top (a viewport has no OS cursor of its own).
##
## Terminal redesign, chunk 1: the frame (header, a home page of section cards, a page per section
## with Back) so the pointer and clicking can be tried. Chunk 2 fills the sections with entry cards
## and entry pages; chunk 3 adds signing in.

const BG := Color(0.02, 0.05, 0.035)
const GREEN := Color(0.45, 1.0, 0.55)
const GREEN_DIM := Color(0.55, 0.75, 0.6)
const CARD := Color(0.04, 0.1, 0.065)
const CARD_HOT := Color(0.08, 0.2, 0.12)
const CURSOR := Color(0.36, 0.88, 0.82)

const SECTIONS := [
	{"id": "monsters", "title": "MONSTERS", "blurb": "What is out in the wings"},
	{"id": "abilities", "title": "ABILITIES", "blurb": "What their brains give you"},
	{"id": "items", "title": "ITEMS", "blurb": "Tools, supplies, pills"},
	{"id": "procedures", "title": "PROCEDURES", "blurb": "Every operation, step by step"},
]

var page := "home"          # "home" or a section id
var _body: Control
var _crumb: Label
var _back: Button
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
	title.position = Vector2(48, 30)
	add_child(title)
	_crumb = _label("", 20, GREEN_DIM)
	_crumb.position = Vector2(50, 76)
	add_child(_crumb)
	_back = _card_button("< BACK", Vector2(150, 54), 22)
	_back.position = Vector2(1080, 34)
	_back.pressed.connect(func(): go("home"))
	add_child(_back)

	var line := ColorRect.new()
	line.color = Color(GREEN, 0.35)
	line.position = Vector2(48, 116)
	line.size = Vector2(1184, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)

	_body = Control.new()
	_body.position = Vector2(48, 140)
	_body.size = Vector2(1184, 540)
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_body)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	go("home")


func _process(delta: float) -> void:
	if _pulse_t >= 0.0:
		_pulse_t += delta
		if _pulse_t > 0.35:
			_pulse_t = -1.0
		_overlay.queue_redraw()


# ---------------------------------------------------------------------------
# pages

func go(to: String) -> void:
	page = to
	for c in _body.get_children():
		c.queue_free()
	_back.visible = to != "home"
	if to == "home":
		_crumb.text = "HOME"
		_home()
	else:
		for s in SECTIONS:
			if s.id == to:
				_crumb.text = "HOME  >  %s" % s.title
		_section(to)


func _home() -> void:
	var sign := _card_button("SIGN IN\n\nno one signed in", Vector2(1184, 110), 26)
	sign.position = Vector2(0, 0)
	sign.disabled = true
	_body.add_child(sign)
	var w := (1184.0 - 3 * 24.0) / 4.0
	for i in SECTIONS.size():
		var s: Dictionary = SECTIONS[i]
		var card := _card_button("%s\n\n%s" % [s.title, s.blurb], Vector2(w, 330), 28)
		card.position = Vector2(i * (w + 24.0), 140)
		var id: String = s.id
		card.pressed.connect(func(): go(id))
		_body.add_child(card)


func _section(id: String) -> void:
	var note := _label("Entries for this section arrive in the next chunk.", 24, GREEN_DIM)
	note.position = Vector2(0, 20)
	_body.add_child(note)


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


func _card_button(text: String, sz: Vector2, font_px: int) -> Button:
	var b := Button.new()
	b.text = text
	b.size = sz
	b.custom_minimum_size = sz
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", font_px)
	b.add_theme_color_override("font_color", GREEN)
	b.add_theme_color_override("font_hover_color", Color(0.8, 1.0, 0.85))
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(GREEN_DIM, 0.6))
	var states := {"normal": [CARD, Color(GREEN, 0.4)], "hover": [CARD_HOT, GREEN], "pressed": [Color(0.15, 0.35, 0.2), Color.WHITE],
		"disabled": [Color(CARD, 0.6), Color(GREEN_DIM, 0.25)]}
	for st in states.keys():
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[st][0]
		sb.border_color = states[st][1]
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(6)
		b.add_theme_stylebox_override(st, sb)
	return b
