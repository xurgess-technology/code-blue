extends RefCounted
## The fax printer every paper screen draws: the launch printout (scripts/launch_screen.gd), the title
## menu's sign-in sheet (scripts/menu.gd), the settings / pause page (scripts/settings_screen.gd), the
## shift assignment (scripts/shift_fax.gd) and the pharmacy order form (scripts/economy/fax_order_ui.gd).
## One layout and one set of drawing calls, so when one page feeds out and the next feeds in, the
## printer underneath doesn't move a pixel. docs/FAX.md lists every transition and its timing.

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
## Pages are short (a sheet holds a dozen lines), so the paper and printer are drawn this much larger
## than their pixel sizes here, capped so the machine still fits across the screen.
const UI_SCALE := 1.3
const FIT_WIDTH := 780.0

## One set of motions for every fax screen (docs/FAX.md), so a page arriving, a page leaving and the
## machine itself coming and going look and take the same everywhere:
##   a page feeds UP out of the slot, slowing to a stop (ease out)      FEED_SECONDS
##   a finished page ejects UP off the top of the screen (ease in)       EJECT_SECONDS
##   the printer rises in from below the screen (ease out)               RISE_SECONDS
##   the printer sinks off the bottom (ease in)                          DROP_SECONDS
## The printer only moves when the machine itself appears or goes (the pause menu, the pharmacy form,
## the end of the shift assignment); pages that follow one another swap in the same standing printer.
const FEED_SECONDS := 0.5
const EJECT_SECONDS := 0.35
const RISE_SECONDS := 0.38
const DROP_SECONDS := 0.38
## Longest step of animation time per frame: a slow frame holds the paper for a moment rather than
## skipping most of a motion.
const MAX_STEP := 0.05
## Seconds between the feed motor's ticks while a page feeds.
const FEED_TICK := 0.11


static func make_font() -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Consolas", "Courier New", "Lucida Console", "DejaVu Sans Mono", "monospace"])
	sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return sf


## Scales `layer` up by UI_SCALE and sizes `root`, its full-screen Control, to cover the screen in that
## scaled space; every fax screen draws in there. Call again when the viewport resizes.
static func fit_layer(layer: CanvasLayer, root: Control) -> void:
	var vp := layer.get_viewport().get_visible_rect().size
	var k := minf(UI_SCALE, vp.x / FIT_WIDTH)
	layer.scale = Vector2(k, k)
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root.position = Vector2.ZERO
	root.size = vp / k


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


## The room, and a page from `top` down to `bottom` (INF, the default: into the slot; a sheet that has
## left the printer passes its own bottom edge, which may be above the screen). Pages are only as tall
## as what's on them: `top` is the page's top edge (above the screen for a long printout).
## `scroll_px` is how far the paper has moved up; its green bars and tractor holes ride along with it,
## phased from the print line so they line up across both screens.
static func draw_paper(ci: CanvasItem, size: Vector2, l: Dictionary, scroll_px: float, a: float, bottom := INF,
		room := true, top := -10.0) -> void:
	if room:
		ci.draw_rect(Rect2(Vector2.ZERO, size), Color(ROOM, a))
	var px: float = l.px
	var paper_w: float = l.paper_w
	var print_y: float = l.print_y
	var paper_top := top
	var paper_bottom: float = float(l.slot_y) if is_inf(bottom) else bottom
	if paper_bottom <= paper_top:
		return
	var paper := Rect2(px, paper_top, paper_w, paper_bottom - paper_top)
	ci.draw_rect(paper, Color(PAPER, a))
	# The page's torn-off top edge.
	if paper_top > -5.0:
		ci.draw_rect(Rect2(px, paper_top, paper_w, 2.0), Color(0.0, 0.0, 0.0, 0.18 * a))
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
		status: String, light: Color, a: float, drop := 0.0, label := "") -> void:
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
	if label != "":
		ci.draw_string(font, Vector2(px - 20.0, body.position.y + 29.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("7d8a93", a))


## A dashed rule across the paper at `y`.
static func draw_rule(ci: CanvasItem, x: float, y: float, w: float, a: float) -> void:
	var dx := x
	while dx < x + w:
		ci.draw_line(Vector2(dx, y), Vector2(minf(dx + 9.0, x + w), y), Color(INK, 0.75 * a), 2.0)
		dx += 14.0


## A rubber stamp: a double-ruled box, tilted down to the right (how a hand holds one), centred on
## `centre` -- generally the top right of the page. `punch` (0..1) is how freshly it
## came down (1 = the instant it hits, drawn a little larger).
##
## Pressed by hand onto the printed page, not printed with it (a fax is monochrome; the red comes
## from the rubber stamp in the nurse's hand). So the ink is patchy: each side of the box is its own
## stroke at its own weight, the rubber rocked and left a faint second impression, and specks of
## paper show through where it didn't take. All of it is seeded from the text and the spot, so a
## stamp looks the same every frame and two stamps don't look alike.
static func draw_stamp(ci: CanvasItem, font: Font, text: String, centre: Vector2, size: int, punch: float,
		ink: Color, a: float, angle := 0.12) -> void:
	var k := 1.0 + 0.5 * clampf(punch, 0.0, 1.0)
	var big := int(size * k)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	var box := Vector2(tw + 34.0, big + 20.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(text) ^ int(centre.x) * 73856093 ^ int(centre.y) * 19349663

	ci.draw_set_transform(centre, angle + rng.randf_range(-0.012, 0.012), Vector2.ONE)
	var col := Color(ink, 0.85 * a)
	var half := box * 0.5
	# The box: four strokes, each a touch heavier or lighter, and each stopping short of the corner.
	var corners := [-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]
	var light := rng.randi_range(0, 3)   # one side the rubber barely touched
	for i in 4:
		var p: Vector2 = corners[i]
		var q: Vector2 = corners[(i + 1) % 4]
		var d := (q - p).normalized()
		var gap := rng.randf_range(0.0, 7.0)
		var w := rng.randf_range(3.0, 5.5)
		var ia := rng.randf_range(0.75, 1.0)
		if i == light:
			w *= 0.5
			ia *= 0.4
		ci.draw_line(p + d * gap, q - d * rng.randf_range(0.0, 7.0), Color(col, col.a * ia), w)
	# The inner rule, broken into a few dashes.
	var inner := box - Vector2(12, 12)
	var ih := inner * 0.5
	var icorners := [-ih, Vector2(ih.x, -ih.y), ih, Vector2(-ih.x, ih.y)]
	for i in 4:
		var p: Vector2 = icorners[i]
		var q: Vector2 = icorners[(i + 1) % 4]
		var t := 0.0
		while t < 1.0:
			var seg := rng.randf_range(0.22, 0.4)
			ci.draw_line(p.lerp(q, t), p.lerp(q, minf(t + seg, 1.0)),
				Color(col, col.a * rng.randf_range(0.25, 0.6)), 1.5)
			t += seg + rng.randf_range(0.04, 0.12)
	# The rubber rocked: a faint offset impression under the solid one.
	var rock := Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-1.5, 1.5))
	var base := Vector2(-tw * 0.5, big * 0.36)
	ci.draw_string(font, base + rock, text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, Color(col, col.a * 0.3))
	ci.draw_string(font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, col)
	# Paper showing through where the ink didn't take: a dry patch that eats part of the stamp, and
	# speckle over the rest.
	# f keeps the grain in proportion: the same speck sizes would swallow a small stamp whole.
	var f := clampf(float(big) / 56.0, 0.4, 1.6)
	# The dry patch rides along the top or bottom band, where it eats the box instead of the word.
	var dry := Vector2(rng.randf_range(-half.x * 0.7, half.x * 0.7),
		half.y * rng.randf_range(0.6, 1.0) * (-1.0 if rng.randf() < 0.5 else 1.0))
	for _i in 7:
		var ds := rng.randf_range(4.0, 10.0) * f
		ci.draw_rect(Rect2(dry + Vector2(rng.randf_range(-22.0, 22.0), rng.randf_range(-5.0, 5.0)) * f,
			Vector2(ds, ds * rng.randf_range(0.7, 1.5))), Color(PAPER, rng.randf_range(0.5, 0.85) * a))
	for _i in 40:
		var s := rng.randf_range(2.0, 6.5) * f
		ci.draw_rect(Rect2(Vector2(rng.randf_range(-half.x, half.x), rng.randf_range(-half.y, half.y)),
			Vector2(s, s * rng.randf_range(0.5, 1.7))), Color(PAPER, rng.randf_range(0.4, 0.9) * a))
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# -- motion ------------------------------------------------------------------------------------

## A stamp coming down on a page that has settled: arm() it once the page is at rest, step() it every
## frame, and pass punch() to draw_stamp. Nothing is drawn while it waits (hidden()), so call sites
## skip the stamp until it lands; step() returns true on the frame it lands, for the sound.
##
## Unarmed, it reads as already stamped (hidden() false, punch() 0), so a page drawn without ever
## arming one -- headless, a screenshot, a state restored mid-flight -- still shows its stamp.
class Stamp extends RefCounted:
	## Paper stops, a beat, then the stamp comes down.
	const DELAY := 0.16
	## The impression settles from "just hit" (drawn larger) to its resting size.
	const PUNCH := 0.1

	var _wait := -1.0
	var _anim := -1.0

	## Start the wait. The page should be at rest (or about to be) when this is called.
	func arm(delay := DELAY) -> void:
		_wait = maxf(delay, 0.0)
		_anim = -1.0

	## Already stamped, no animation (headless, or a page that arrives stamped).
	func settled() -> void:
		_wait = -1.0
		_anim = -1.0

	## True while the stamp has not come down yet: draw the page without it.
	func hidden() -> bool:
		return _wait >= 0.0

	## Feed to draw_stamp: 1 the instant it hits, easing to 0 as the impression settles.
	func punch() -> float:
		return clampf(1.0 - _anim / PUNCH, 0.0, 1.0) if _anim >= 0.0 else 0.0

	## True while it still needs frames (waiting or settling).
	func moving() -> bool:
		return _wait >= 0.0 or (_anim >= 0.0 and _anim < PUNCH)

	## Advance it. Returns true on the frame the stamp lands (play the cue then).
	func step(dt: float) -> bool:
		if _wait >= 0.0:
			_wait -= dt
			if _wait <= 0.0:
				_wait = -1.0
				_anim = 0.0
				return true
			return false
		if _anim >= 0.0 and _anim < PUNCH:
			_anim = minf(_anim + dt, PUNCH)
		return false


## Animation seconds for a frame of `delta`: real time (the dev panel's slow motion doesn't slow the
## paper), clamped to MAX_STEP.
static func ui_dt(delta: float) -> float:
	return minf(delta / maxf(Engine.time_scale, 0.001), MAX_STEP)


## 0..1 -> 0..1, fast then settling (a page feeding out, the printer rising).
static func ease_out(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


## 0..1 -> 0..1, accelerating away (a page ejecting, the printer sinking). Not from a dead stop: it
## moves the frame it starts, so a click or Esc is answered at once.
static func ease_in(t: float) -> float:
	var k := clampf(t, 0.0, 1.0)
	return k * (0.3 + 0.7 * k)


## How far the printer sinks to be fully off the bottom of a screen of `size`.
static func printer_gone_px(size: Vector2, l: Dictionary) -> float:
	return size.y - float(l.slot_y) + 40.0


## Headless runs (tests) skip every animation.
static func headless() -> bool:
	return DisplayServer.get_name() == "headless"


## A UI sound, not in headless runs.
static func sfx(cue: String, db: float, jitter := 0.05) -> void:
	if not headless():
		Audio.play(cue, null, db, jitter, Audio.BUS_UI)


## A value easing toward a target: go() starts from wherever it is now, so a motion reversed half way
## (Esc, then Esc again) turns around instead of jumping. `seconds` is for the whole 0..1 distance;
## shorter moves take proportionally less. Headless, it gets there at once.
class Motion extends RefCounted:
	var value := 0.0
	var _from := 0.0
	var _to := 0.0
	var _t := 0.0
	var _dur := 0.0
	var _out := true

	func _init(v := 0.0) -> void:
		snap(v)

	## Toward `to`, easing out (fast, then settling) or in (slow, then accelerating away).
	func go(to: float, seconds: float, out := true) -> void:
		if is_equal_approx(to, _to) and (_dur > 0.0 or is_equal_approx(value, to)):
			return
		_from = value
		_to = to
		_t = 0.0
		_out = out
		_dur = seconds * absf(to - value)
		if _dur <= 0.0 or DisplayServer.get_name() == "headless":
			snap(to)

	func snap(v: float) -> void:
		value = v
		_from = v
		_to = v
		_t = 0.0
		_dur = 0.0

	func step(dt: float) -> void:
		if _dur <= 0.0:
			return
		_t += dt
		var k := clampf(_t / _dur, 0.0, 1.0)
		var e := k * (0.3 + 0.7 * k)   # ease_in()
		if _out:
			var u := 1.0 - k
			e = 1.0 - u * u * u
		value = lerpf(_from, _to, e)
		if k >= 1.0:
			snap(_to)

	func moving() -> bool:
		return _dur > 0.0

	func target() -> float:
		return _to

	## Resting at `v`.
	func at(v: float) -> bool:
		return _dur <= 0.0 and is_equal_approx(value, v)
