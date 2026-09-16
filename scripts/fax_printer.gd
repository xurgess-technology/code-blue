extends RefCounted
## The fax printer both paper screens draw: the launch printout (scripts/launch_screen.gd) and the
## title menu's sign-in sheet (scripts/menu.gd). One layout and one set of drawing calls, so when the
## launch page feeds out and the menu's page feeds in, the printer underneath doesn't move a pixel.

const PAPER := Color("dcd8c9")
const PAPER_BAND := Color(0.55, 0.72, 0.55, 0.13)
const INK := Color("2b2c2f")
const INK_FAINT := Color("5a5c60")
const STAMP_INK := Color("a3242a")
const DEV_INK := Color("2f63c9")
const ROOM := Color("06080c")
const PRINTER := Color("16191c")
const PRINTER_EDGE := Color("2b3035")
const LCD_TEXT := Color("9fe8a0")
const LCD_WAIT := Color("e0a020")

const FONT_SIZE := 19
const LINE_H := 29.0
const WIDTH_CHARS := 58
const MARGIN := 56.0
## The print line (the paper's slot into the printer), as a fraction of the screen height.
const SLOT := 0.74


static func make_font() -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Consolas", "Courier New", "Lucida Console", "DejaVu Sans Mono", "monospace"])
	sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return sf


## Where everything goes on a screen of `size`: px (paper left), paper_w, tx (text left), text_w,
## char_w, print_y (the print line), slot_y (the printer body's top edge).
static func layout(size: Vector2, font: Font) -> Dictionary:
	var char_w := font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var text_w := char_w * WIDTH_CHARS
	var paper_w := text_w + MARGIN * 2.0
	var px := (size.x - paper_w) * 0.5
	var print_y := size.y * SLOT
	return {
		"px": px, "paper_w": paper_w, "tx": px + MARGIN, "text_w": text_w, "char_w": char_w,
		"print_y": print_y, "slot_y": print_y + LINE_H * 0.6,
	}


## The room, and the paper from the top of the screen down to `bottom` (default: into the slot).
## `scroll_px` is how far the paper has moved up; its green bars and tractor holes ride along with it,
## phased from the print line so they line up across both screens.
static func draw_paper(ci: CanvasItem, size: Vector2, l: Dictionary, scroll_px: float, a: float, bottom := -1.0) -> void:
	ci.draw_rect(Rect2(Vector2.ZERO, size), Color(ROOM, a))
	var px: float = l.px
	var paper_w: float = l.paper_w
	var print_y: float = l.print_y
	var paper_top := -10.0
	var paper_bottom: float = float(l.slot_y) if bottom < 0.0 else bottom
	var paper := Rect2(px, paper_top, paper_w, paper_bottom - paper_top)
	ci.draw_rect(paper, Color(PAPER, a))
	var band_step := LINE_H * 4.0
	var below := ceilf(maxf(0.0, paper_bottom - print_y) / band_step) + 1.0
	var by := print_y - LINE_H * 0.72 - fposmod(scroll_px, band_step) + band_step * below
	while by > paper_top - LINE_H * 2.0:
		var band := Rect2(px, by - LINE_H * 2.0, paper_w, LINE_H * 2.0).intersection(paper)
		if band.size.y > 0.0:
			ci.draw_rect(band, Color(PAPER_BAND, PAPER_BAND.a * a))
		by -= band_step
	var hole_step := LINE_H * 0.8
	var hy := print_y - fposmod(scroll_px, hole_step) + hole_step * (ceilf(maxf(0.0, paper_bottom - print_y) / hole_step) + 1.0)
	while hy > paper_top:
		if hy < paper.end.y - 4.0:
			for hx in [px + MARGIN * 0.38, px + paper_w - MARGIN * 0.38]:
				ci.draw_circle(Vector2(hx, hy), 5.0, Color(ROOM, 0.85 * a))
		hy -= hole_step


## Older paper fades toward the top of the screen, into the dark.
static func draw_top_fade(ci: CanvasItem, size: Vector2, a: float) -> void:
	var fade_h := size.y * 0.5
	var top := Color(ROOM, 0.95 * a)
	var clear := Color(ROOM, 0.0)
	ci.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, fade_h), Vector2(0, fade_h)]),
			PackedColorArray([top, top, clear, clear]))


## The printer body below the slot, its print head at `head_x`, the status light and the LCD.
## `drop` lowers the whole machine (the menu slides it off the bottom of the screen).
static func draw_printer(ci: CanvasItem, size: Vector2, l: Dictionary, font: Font, head_x: float,
		status: String, light: Color, a: float, drop := 0.0) -> void:
	var px: float = l.px
	var paper_w: float = l.paper_w
	var top := float(l.slot_y) + drop
	if top >= size.y:
		return
	var body := Rect2(px - 36.0, top, paper_w + 72.0, size.y - top)
	ci.draw_rect(body, Color(PRINTER, a))
	ci.draw_line(body.position, Vector2(body.end.x, body.position.y), Color(PRINTER_EDGE, a), 3.0)
	ci.draw_rect(Rect2(px - 4.0, body.position.y - 2.0, paper_w + 8.0, 6.0), Color(0.0, 0.0, 0.0, 0.6 * a))
	var head := Rect2(head_x - 10.0, body.position.y - 16.0, 26.0, 20.0)
	ci.draw_rect(head, Color("2a2f34", a))
	ci.draw_rect(Rect2(head.position.x + 3.0, head.position.y + 3.0, 20.0, 3.0), Color("45505a", a))
	ci.draw_circle(Vector2(body.end.x - 30.0, body.position.y + 22.0), 4.0, Color(light, 0.9 * a))
	var lcd := Rect2(body.end.x - 250.0, body.position.y + 10.0, 200.0, 26.0)
	ci.draw_rect(lcd, Color("0c1a12", a))
	ci.draw_rect(lcd, Color(PRINTER_EDGE, a), false, 1.5)
	ci.draw_string(font, lcd.position + Vector2(10.0, 19.0), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(LCD_TEXT, 0.85 * a))


## A dashed rule across the paper at `y`.
static func draw_rule(ci: CanvasItem, x: float, y: float, w: float, a: float) -> void:
	var dx := x
	while dx < x + w:
		ci.draw_line(Vector2(dx, y), Vector2(minf(dx + 9.0, x + w), y), Color(INK, 0.75 * a), 2.0)
		dx += 14.0


## A rubber stamp: a double-ruled box, tilted, centred on `centre`. `punch` (0..1) is how freshly it
## came down (1 = the instant it hits, drawn a little larger).
static func draw_stamp(ci: CanvasItem, font: Font, text: String, centre: Vector2, size: int, punch: float,
		ink: Color, a: float, angle := -0.14) -> void:
	var k := 1.0 + 0.5 * clampf(punch, 0.0, 1.0)
	var big := int(size * k)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	var box := Vector2(tw + 34.0, big + 20.0)
	ci.draw_set_transform(centre, angle, Vector2.ONE)
	var col := Color(ink, 0.85 * a)
	ci.draw_rect(Rect2(-box * 0.5, box), col, false, 4.0)
	ci.draw_rect(Rect2(-box * 0.5 + Vector2(6, 6), box - Vector2(12, 12)), Color(col, col.a * 0.5), false, 1.5)
	ci.draw_string(font, Vector2(-tw * 0.5, big * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, col)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
