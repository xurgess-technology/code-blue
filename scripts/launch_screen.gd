extends CanvasLayer
## The launch printout. While the one-time warmup runs (scripts/warmup.gd), the game's own admission
## chart feeds out of a dot-matrix printer: the patient is Code Blue. main.gd shows it over the title
## menu and frees it when `done` fires.
##
## The page is a fixed script printed at a steady pace, not a progress readout, so it never jumps:
##   1. CONNECTING: a still page while the renderer's one-time setup lands (a few frames of seconds
##      each that nothing could animate through); the fax handshake plays on the audio thread.
##   2. RECEIVING: the chart prints line by line while the warmup builds everything hidden (so
##      nothing new is drawn and frames stay light). Printer time advances by at most MAX_STEP per
##      frame, so a rare slow frame slows the printer for an instant instead of skipping ahead. If
##      the chart finishes first, "awaiting labs" lines print while the warmup finishes.
##   3. PAGE COMPLETE: the ADMITTED stamp comes down, and only then does the warmup draw everything
##      it built (its long first-draw frames) behind the still, stamped page. Then it fades.

signal done

const LAYER := 124
const CPS := 135.0
const LINE_PAUSE := 0.14
const RULE_PAUSE := 0.3
## Longest step of printer time per frame (seconds).
const MAX_STEP := 1.0 / 30.0
## The stamped page stays still at least this long, and this long after the final draw finished.
const STAMP_HOLD := 1.3
const AFTER_DRAW_HOLD := 0.35
## The stamp settles before the warmup is allowed to start its long draw frames.
const STAMP_SETTLE := 0.35
const FADE := 0.5
const WIDTH_CHARS := 58

## Connecting lasts until the renderer's setup frame has gone by: a frame of at least SETUP_MS
## (measured ~2.4 s on a Radeon 890M, landing about a second after the first frame, not on it),
## then CALM_FRAMES quick frames. A GPU that never shows one moves on after CONNECT_FALLBACK.
const SETUP_MS := 500.0
const CALM_FRAMES := 4
const CALM_MS := 70.0
const CONNECT_MIN := 1.6
const CONNECT_FALLBACK := 5.0
const CONNECT_MAX := 10.0

const PAPER := Color("dcd8c9")
const PAPER_BAND := Color(0.55, 0.72, 0.55, 0.13)
const INK := Color("2b2c2f")
const INK_FAINT := Color("5a5c60")
const STAMP_INK := Color("a3242a")
const ROOM := Color("06080c")
const PRINTER := Color("16191c")
const PRINTER_EDGE := Color("2b3035")
const LCD_TEXT := Color("9fe8a0")

const HumanModelScript := preload("res://scripts/human/human_model.gd")

## Printed one at a time while the chart waits on the warmup, then "..." until it's done.
const WAITING_LINES := ["Awaiting labs.", "Still awaiting labs.", "Labs misplaced. Running them again."]

var _queue: Array = []   # {text, kind, ts}: kind "text", "dim", "rule", "stamp", "gap"; ts = timestamp it
var _printed: Array = []
var _current := {}
var _chars := 0.0
var _pause := 0.0
var _waiting_i := 0
var _built := false
var _drawn := false
var _closing := false
var _connecting := true
var _connect_since := 0.0
var _calm := 0
var _frames_seen := 0
var _setup_seen := false
var _stamp_at := -1.0
var _stamp_anim := 0.0
var _drawn_at := -1.0
var _fade := 1.0
var _scroll := 0.0
var _last_usec := 0
var _headless := false
var _font: Font
var _canvas: Control


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Consolas", "Courier New", "Lucida Console", "DejaVu Sans Mono", "monospace"])
	sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	_font = sf
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_page)
	add_child(_canvas)
	_last_usec = Time.get_ticks_usec()
	_connect_since = _now()
	_queue_chart()
	if not _headless:
		Audio.play("fax_connect", null, -12.0, 0.0, Audio.BUS_UI)


## Warmup.run's progress callback: only "built" and "done" matter here.
func report(stage: String, _detail = null) -> void:
	if stage == "built":
		_built = true
	elif stage == "done":
		_drawn = true
		_drawn_at = _now()


## Warmup.run's ready_to_draw callback: its long first-draw frames wait for the stamped page.
func can_draw() -> bool:
	return _headless or (_stamp_at >= 0.0 and _now() - _stamp_at >= STAMP_SETTLE)


## Warmup.run's may_work callback: it only builds while the print head is idle between lines, so
## a slow frame shows as a slightly longer pause rather than a stutter mid-line. Not while
## connecting either, so those frames settle quickly once the renderer's setup is done.
func may_work() -> bool:
	return _headless or (not _connecting and _current.is_empty() and _stamp_at < 0.0)


func _queue_chart() -> void:
	var dt := Time.get_datetime_dict_from_system()
	var date := "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	var clock := "%02d:%02d" % [dt.hour, dt.minute]
	var items := Items.ITEMS.size()
	for line in [
		[">> FAX  %s  %s  PAGE 1 OF 1" % [date, clock], "dim", false],
		["COUNTY GENERAL  /  NIGHT ADMISSIONS", "text", false],
		["", "rule", false],
		["PATIENT ........ CODE BLUE", "text", false],
		["ADMITTED ....... %s  %s" % [date, clock], "text", false],
		["COMPLAINT ...... Unresponsive. Will not start on its own.", "text", false],
		["", "rule", false],
		["Pulse found. Pupils reactive to light.", "text", true],
		["Instruments counted: %d of %d. None left inside." % [items, items], "text", true],
		["Pharmacy stocked. Furnace lit.", "text", true],
		["%d surgeons on call. Nobody picked up." % HumanModelScript.SURGEONS.size(), "text", true],
		["Charts pulled for %d patients." % Procedures.human_patients().size(), "text", true],
		["Wards report movement. Doors locked.", "text", true],
		["Procedures rehearsed: %d." % Procedures.AILMENTS.size(), "text", true],
	]:
		_queue.append({"text": line[0], "kind": line[1], "ts": line[2]})


func _queue_closing() -> void:
	_closing = true
	for line in [["", "rule"], ["CONDITION ...... STABLE", "text"], ["ATTENDING ...... YOU", "text"], ["", "gap"], ["ADMITTED", "stamp"]]:
		_queue.append({"text": line[0], "kind": line[1], "ts": false})


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d:%02d  " % [t.hour, t.minute, t.second]


func _process(_delta: float) -> void:
	var now_usec := Time.get_ticks_usec()
	var real_dt := float(now_usec - _last_usec) / 1000000.0
	_last_usec = now_usec
	if _headless:
		# Tests: nothing to watch; hand over as soon as the warmup is done.
		if _drawn:
			done.emit()
			set_process(false)
		return
	var dt := minf(real_dt, MAX_STEP)
	if _connecting:
		_frames_seen += 1
		# The first frames carry launch script work, not the renderer's setup.
		if _frames_seen > 2 and real_dt * 1000.0 >= SETUP_MS:
			_setup_seen = true
		_calm = _calm + 1 if real_dt * 1000.0 < CALM_MS else 0
		var waited := _now() - _connect_since
		var settled := _calm >= CALM_FRAMES and waited >= CONNECT_MIN
		if (settled and (_setup_seen or waited >= CONNECT_FALLBACK)) or waited >= CONNECT_MAX:
			_connecting = false
		_canvas.queue_redraw()
		return
	if _queue.is_empty() and _current.is_empty() and _stamp_at < 0.0:
		if _built and not _closing:
			_queue_closing()
		elif not _built and _pause <= 0.0 and _waiting_i < WAITING_LINES.size():
			_queue.append({"text": WAITING_LINES[_waiting_i], "kind": "dim", "ts": true})
			_waiting_i += 1
			_pause = 0.9
	_print(dt)
	_scroll = lerpf(_scroll, float(_printed.size()), clampf(dt * 14.0, 0.0, 1.0))
	if _stamp_at >= 0.0:
		_stamp_anim += dt
		if _drawn and _now() - _drawn_at >= AFTER_DRAW_HOLD and _now() - _stamp_at >= STAMP_HOLD:
			_fade = maxf(0.0, _fade - dt / FADE)
			if _fade <= 0.0:
				done.emit()
				set_process(false)
	_canvas.queue_redraw()


## Spend `dt` seconds of printer time: characters, pauses, the next line off the queue.
func _print(dt: float) -> void:
	var t_left := dt
	while t_left > 0.0:
		if _current.is_empty():
			if _pause > 0.0:
				var p := minf(_pause, t_left)
				_pause -= p
				t_left -= p
				continue
			if _queue.is_empty() or _stamp_at >= 0.0:
				return
			_current = _queue.pop_front()
			if bool(_current.get("ts", false)):
				_current.text = _clock() + String(_current.text)
			_chars = 0.0
			match String(_current.kind):
				"stamp":
					Audio.play("print_stamp", null, -6.0, 0.03, Audio.BUS_UI)
				"rule":
					Audio.play("print_feed", null, -15.0, 0.08, Audio.BUS_UI)
				"text", "dim":
					Audio.play("print_line", null, -13.0, 0.06, Audio.BUS_UI)
		var kind := String(_current.kind)
		if kind in ["rule", "gap", "stamp"]:
			_finish_line(RULE_PAUSE)
			if kind == "stamp":
				_stamp_at = _now()
				return
			return   # one line per frame at most keeps the sounds from stacking
		var remaining := float(String(_current.text).length()) - _chars
		var needed := remaining / CPS
		if t_left >= needed:
			_finish_line(LINE_PAUSE)
			return
		_chars += t_left * CPS
		t_left = 0.0


func _finish_line(pause: float) -> void:
	_printed.append(_current)
	_current = {}
	_pause = pause


# -- drawing -----------------------------------------------------------------------------------

func _draw_page() -> void:
	var size := _canvas.size
	var a := _fade
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(ROOM, a))
	var fs := 19
	var line_h := 29.0
	var char_w := _font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var text_w := char_w * WIDTH_CHARS
	var margin := 56.0
	var paper_w := text_w + margin * 2.0
	var px := (size.x - paper_w) * 0.5
	var print_y := size.y * 0.74
	var paper_top := -10.0

	# The paper, with its green-bar bands and tractor holes, moving up with the scroll.
	var paper := Rect2(px, paper_top, paper_w, print_y + line_h * 0.6 - paper_top)
	_canvas.draw_rect(paper, Color(PAPER, a))
	var offset := fposmod(_scroll * line_h, line_h * 4.0)
	var by := print_y - line_h * 0.72 - offset + line_h * 4.0
	while by > paper_top - line_h * 2.0:
		var band := Rect2(px, by - line_h * 2.0, paper_w, line_h * 2.0).intersection(paper)
		if band.size.y > 0.0:
			_canvas.draw_rect(band, Color(PAPER_BAND, PAPER_BAND.a * a))
		by -= line_h * 4.0
	var hole_step := line_h * 0.8
	var hy := print_y - fposmod(_scroll * line_h, hole_step) + hole_step
	while hy > paper_top:
		if hy < paper.end.y - 4.0:
			for hx in [px + margin * 0.38, px + paper_w - margin * 0.38]:
				_canvas.draw_circle(Vector2(hx, hy), 5.0, Color(ROOM, 0.85 * a))
		hy -= hole_step

	# Printed lines, newest at the head, older ones scrolled up.
	var tx := px + margin
	var total := _printed.size()
	for i in range(total - 1, -1, -1):
		var y := print_y - (_scroll - float(i)) * line_h
		if y < -line_h:
			break
		_draw_line(_printed[i], tx, y, text_w, fs, -1, a)
	if not _current.is_empty():
		_draw_line(_current, tx, print_y - (_scroll - float(total)) * line_h, text_w, fs, int(_chars), a)

	# Older lines fade toward the top, into the dark.
	var fade_h := size.y * 0.5
	var top := Color(ROOM, 0.95 * a)
	var clear := Color(ROOM, 0.0)
	_canvas.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, fade_h), Vector2(0, fade_h)]),
			PackedColorArray([top, top, clear, clear]))

	# The printer: its body below the tear line, the head riding along the line being printed.
	var body := Rect2(px - 36.0, print_y + line_h * 0.6, paper_w + 72.0, size.y - print_y)
	_canvas.draw_rect(body, Color(PRINTER, a))
	_canvas.draw_line(body.position, Vector2(body.end.x, body.position.y), Color(PRINTER_EDGE, a), 3.0)
	_canvas.draw_rect(Rect2(px - 4.0, body.position.y - 2.0, paper_w + 8.0, 6.0), Color(0.0, 0.0, 0.0, 0.6 * a))
	var head_x := tx
	if not _current.is_empty() and String(_current.kind) in ["text", "dim"]:
		head_x = tx + char_w * float(int(_chars))
	elif total > 0:
		head_x = tx + char_w * float(String(_printed[total - 1].text).length())
	var head := Rect2(head_x - 10.0, body.position.y - 16.0, 26.0, 20.0)
	_canvas.draw_rect(head, Color("2a2f34", a))
	_canvas.draw_rect(Rect2(head.position.x + 3.0, head.position.y + 3.0, 20.0, 3.0), Color("45505a", a))

	# Status light and display. Both hold still while connecting and once the page is stamped: those
	# are the moments a long frame may land, and nothing that should be moving may be on screen then.
	var light := Vector2(body.end.x - 30.0, body.position.y + 22.0)
	var status := "RECEIVING"
	var light_col := Color(LCD_TEXT, 0.9 * a)
	if _connecting:
		status = "CONNECTING"
		light_col = Color("e0a020", 0.9 * a)
	elif _stamp_at >= 0.0:
		status = "PAGE COMPLETE"
	_canvas.draw_circle(light, 4.0, light_col)
	var lcd := Rect2(body.end.x - 250.0, body.position.y + 10.0, 200.0, 26.0)
	_canvas.draw_rect(lcd, Color("0c1a12", a))
	_canvas.draw_rect(lcd, Color(PRINTER_EDGE, a), false, 1.5)
	_canvas.draw_string(_font, lcd.position + Vector2(10.0, 19.0), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(LCD_TEXT, 0.85 * a))
	_canvas.draw_string(_font, Vector2(px - 20.0, body.position.y + 29.0), "FAX-9 / COUNTY GENERAL", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("5a646c", a))


func _draw_line(line: Dictionary, x: float, y: float, w: float, fs: int, shown: int, a: float) -> void:
	var kind := String(line.kind)
	match kind:
		"rule":
			var dash_y := y - fs * 0.35
			var dx := x
			while dx < x + w:
				_canvas.draw_line(Vector2(dx, dash_y), Vector2(minf(dx + 9.0, x + w), dash_y), Color(INK, 0.75 * a), 2.0)
				dx += 14.0
		"stamp":
			_draw_stamp(String(line.text), Vector2(x + w - 150.0, y - 42.0), fs, a)
		"gap":
			pass
		_:
			var text := String(line.text)
			if shown >= 0:
				text = text.substr(0, shown)
			var col := INK_FAINT if kind == "dim" else INK
			# Dot-matrix ink: a slightly offset second pass reads as struck ribbon rather than crisp type.
			_canvas.draw_string(_font, Vector2(x + 0.6, y + 0.4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.35 * a))
			_canvas.draw_string(_font, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.92 * a))


func _draw_stamp(text: String, centre: Vector2, fs: int, a: float) -> void:
	var k := 1.0 + 0.5 * clampf(1.0 - _stamp_anim / 0.1, 0.0, 1.0)
	var big := int(fs * 1.9 * k)
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	var box := Vector2(tw + 34.0, big + 20.0)
	_canvas.draw_set_transform(centre, -0.14, Vector2.ONE)
	var col := Color(STAMP_INK, 0.85 * a)
	_canvas.draw_rect(Rect2(-box * 0.5, box), col, false, 4.0)
	_canvas.draw_rect(Rect2(-box * 0.5 + Vector2(6, 6), box - Vector2(12, 12)), Color(col, col.a * 0.5), false, 1.5)
	_canvas.draw_string(_font, Vector2(-tw * 0.5, big * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, col)
	_canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
