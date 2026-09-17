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
##      it built (its long first-draw frames) behind the still, stamped page.
##   4. FEED OUT: the stamped sheet ejects, all of it, up and out of the top of the screen. The title
##      menu underneath draws the same printer (scripts/fax_printer.gd) and feeds its sign-in sheet
##      up out of the slot as the next page (`paper_scroll_px`, `feed_speed`, `pages_printed`).

signal done

const Fax := preload("res://scripts/fax_printer.gd")

const LAYER := 124
const CPS := 135.0
const LINE_PAUSE := 0.14
const RULE_PAUSE := 0.3
## Longest step of printer time per frame (seconds).
const MAX_STEP := 1.0 / 30.0
## The stamped page stays still at least this long, and this long after the final draw finished.
const STAMP_HOLD := 0.9
const AFTER_DRAW_HOLD := 0.25
## The stamp settles before the warmup is allowed to start its long draw frames.
const STAMP_SETTLE := 0.35
## Seconds for the finished page to accelerate up and off the screen (a long page: a little over the
## shared Fax.EJECT_SECONDS), after which the menu's sign-in sheet feeds in (Fax.FEED_SECONDS).
const FEED_OUT := 0.45
const FEED_TICK := Fax.FEED_TICK
## Lines to a sheet; then it ejects and a new sheet peeks out.
const PAGE_LINES := 12
const EJECT_SECONDS := 0.4
const PEEK_SECONDS := 0.3
## Blank paper above a sheet's first line (in lines): what peeks out of the slot before it prints.
const PAGE_MARGIN := 1.3

## Connecting lasts until the renderer's setup frame has gone by: a frame of at least SETUP_MS
## (measured ~2.4 s on a Radeon 890M, landing about a second after the first frame, not on it),
## then CALM_FRAMES quick frames. A GPU that never shows one moves on after CONNECT_FALLBACK.
const SETUP_MS := 500.0
const CALM_FRAMES := 4
const CALM_MS := 70.0
const CONNECT_MIN := 1.6
const CONNECT_FALLBACK := 5.0
const CONNECT_MAX := 10.0

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
var _feed_t := -1.0       # seconds into the feed-out, < 0 before it starts
var _feed_px := 0.0
var _feed_dist := 0.0
var _feed_tick := 0.0
var _head_from := 0.0
var _scroll := 0.0
## Pages: the chart prints onto sheets of PAGE_LINES lines. A full sheet ejects (flies up and off),
## and a fresh one peeks out of the slot before the next line prints.
var _page_start := 0      # index in _printed of the current page's first line
var _page_no := 1
var _old_start := -1      # the ejecting page's lines: _old_start until _page_start
var _eject_t := -1.0
var _eject_px := 0.0
var _peek_t := -1.0
var _last_usec := 0
var _headless := false
var _font: Font
var _canvas: Control


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	_font = Fax.make_font()
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_page)
	add_child(_canvas)
	_fit()
	get_viewport().size_changed.connect(_fit)
	_last_usec = Time.get_ticks_usec()
	_connect_since = _now()
	_queue_chart()
	if not _headless:
		Audio.play("fax_connect", null, -12.0, 0.0, Audio.BUS_UI)


func _fit() -> void:
	Fax.fit_layer(self, _canvas)


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


## How far the paper has moved up, in pixels: where the next page's green bars and holes carry on.
func paper_scroll_px() -> float:
	return _scroll * Fax.LINE_H + _feed_px


## The paper's speed (px/s) as the page leaves: the next page starts at this speed.
func feed_speed() -> float:
	return 1.7 * _feed_dist / FEED_OUT if _feed_dist > 0.0 else 0.0   # d/dt of Fax.ease_in at the end


func _queue_chart() -> void:
	var dt := Time.get_datetime_dict_from_system()
	var date := "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	var clock := "%02d:%02d" % [dt.hour, dt.minute]
	var items := Items.ITEMS.size()
	for line in [
		[">> FAX  %s  %s  PAGE 1" % [date, clock], "dim", false],
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
	if not _tick_page(dt):
		_print(dt)
	_scroll = lerpf(_scroll, float(_printed.size()), clampf(dt * 14.0, 0.0, 1.0))
	if _stamp_at >= 0.0:
		_stamp_anim += dt
		if _feed_t < 0.0 and _drawn and _now() - _drawn_at >= AFTER_DRAW_HOLD and _now() - _stamp_at >= STAMP_HOLD:
			_start_feed_out()
		if _feed_t >= 0.0:
			_feed_t += dt
			var t := minf(_feed_t / FEED_OUT, 1.0)
			_feed_px = _feed_dist * Fax.ease_in(t)   # accelerating: leaves at feed_speed()
			_feed_tick -= dt
			if _feed_tick <= 0.0:
				_feed_tick = FEED_TICK
				Audio.play("print_feed", null, -14.0, 0.1, Audio.BUS_UI)
			if t >= 1.0:
				done.emit()
				set_process(false)
	_canvas.queue_redraw()


func _start_feed_out() -> void:
	_feed_t = 0.0
	_scroll = float(_printed.size())
	# The finished sheet ejects like any other: far enough that its bottom edge, leaving the slot, is
	# gone off the top of the screen.
	_feed_dist = float(Fax.layout(_canvas.size, _font).slot_y) + Fax.LINE_H
	_head_from = _head_x(Fax.layout(_canvas.size, _font))


## A sheet being ejected or a new one peeking out: true while that holds the printer up.
func _tick_page(dt: float) -> bool:
	if _eject_t >= 0.0:
		_eject_t += dt
		var k := minf(_eject_t / EJECT_SECONDS, 1.0)
		_eject_px = _eject_dist() * Fax.ease_in(k)
		if k >= 1.0:
			_eject_t = -1.0
			_old_start = -1
			_eject_px = 0.0
			_peek_t = 0.0
			Audio.play("print_feed", null, -12.0, 0.08, Audio.BUS_UI)
		return true
	if _peek_t >= 0.0:
		_peek_t += dt
		if _peek_t >= PEEK_SECONDS:
			_peek_t = -1.0
		return true
	return false


func _eject_dist() -> float:
	return _canvas.size.y * Fax.SLOT + Fax.LINE_H * (PAGE_LINES + 3)


## The current sheet is full: send it up and out, start the next one with its own fax header.
func _eject_page() -> void:
	_old_start = _page_start
	_page_start = _printed.size()
	_page_no += 1
	_eject_t = 0.0
	_eject_px = 0.0
	_scroll = float(_printed.size())
	var dt := Time.get_datetime_dict_from_system()
	_queue.push_front({"text": ">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE %d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, _page_no],
			"kind": "dim", "ts": false})
	Audio.play("print_feed", null, -8.0, 0.05, Audio.BUS_UI)


## How many sheets the chart took (the menu's sign-in sheet is the next one).
func pages_printed() -> int:
	return _page_no


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
			# A full sheet ejects before the next line, unless that line finishes what's on it (the stamp
			# stays with the lines it stamps).
			if _printed.size() - _page_start >= PAGE_LINES and String(_queue[0].kind) in ["text", "dim", "rule"]:
				_eject_page()
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

## Where the print head sits: on the character being printed, else after the last line printed.
func _head_x(l: Dictionary) -> float:
	var tx: float = l.tx
	var char_w: float = l.char_w
	if not _current.is_empty() and String(_current.kind) in ["text", "dim"]:
		return tx + char_w * float(int(_chars))
	if not _printed.is_empty():
		return tx + char_w * float(String(_printed[_printed.size() - 1].text).length())
	return tx


func _draw_page() -> void:
	var size := _canvas.size
	var l := Fax.layout(size, _font)
	var print_y: float = l.print_y
	var slot_y: float = l.slot_y
	var margin := Fax.LINE_H * PAGE_MARGIN
	# Blank paper room behind the room fill: the room, then each sheet.
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Fax.ROOM)
	# The ejecting sheet: its own top edge and a bottom edge that has left the slot, flying up.
	if _old_start >= 0:
		var old_top := print_y - (_scroll - float(_old_start)) * Fax.LINE_H - margin - _eject_px
		Fax.draw_paper(_canvas, size, l, paper_scroll_px() + _eject_px, 1.0, slot_y - _eject_px, false, old_top)
	# The current sheet: a margin of blank paper above its first line, down into the slot. A brand new
	# sheet (nothing printed on it yet) peeks up out of the slot to that margin first.
	var page_top := print_y - (_scroll - float(_page_start)) * Fax.LINE_H - margin - _feed_px
	if _old_start >= 0:
		page_top = slot_y
	elif _peek_t >= 0.0:
		page_top = lerpf(slot_y, print_y - margin, ease(minf(_peek_t / PEEK_SECONDS, 1.0), 0.5))
	# Once stamped, the whole sheet leaves: its bottom edge comes up out of the slot with the rest of it.
	var page_bottom := slot_y - _feed_px if _feed_t >= 0.0 else INF
	Fax.draw_paper(_canvas, size, l, paper_scroll_px(), 1.0, page_bottom, false, page_top)

	# Printed lines, newest at the head, older ones scrolled up; the ejecting sheet's fly off with it.
	var fs := Fax.FONT_SIZE
	var tx: float = l.tx
	var text_w: float = l.text_w
	var total := _printed.size()
	for i in range(total - 1, -1, -1):
		var on_old := i < _page_start
		if on_old and (_old_start < 0 or i < _old_start):
			break
		var y := print_y - (_scroll - float(i)) * Fax.LINE_H - _feed_px - (_eject_px if on_old else 0.0)
		if y < -Fax.LINE_H * 3.0:
			break
		_draw_line(_printed[i], tx, y, text_w, fs, -1)
	if not _current.is_empty():
		_draw_line(_current, tx, print_y - (_scroll - float(total)) * Fax.LINE_H, text_w, fs, int(_chars))

	# Status light and display. Both hold still while connecting and once the page is stamped: those
	# are the moments a long frame may land, and nothing that should be moving may be on screen then.
	var head_x := _head_x(l)
	if _feed_t >= 0.0:
		head_x = lerpf(_head_from, tx, ease(minf(_feed_t / (FEED_OUT * 0.5), 1.0), 0.4))   # carriage return
	var status := "RECEIVING"
	var light := Fax.LCD_TEXT
	if _connecting:
		status = "CONNECTING"
		light = Fax.LCD_WAIT
	elif _stamp_at >= 0.0:
		status = "PAGE COMPLETE"
	Fax.draw_printer(_canvas, size, l, _font, head_x, status, light, 1.0)


func _draw_line(line: Dictionary, x: float, y: float, w: float, fs: int, shown: int) -> void:
	var kind := String(line.kind)
	match kind:
		"rule":
			Fax.draw_rule(_canvas, x, y - fs * 0.35, w, 1.0)
		"stamp":
			Fax.draw_stamp(_canvas, _font, String(line.text), Vector2(x + w - 150.0, y - 42.0), int(fs * 1.9),
					1.0 - _stamp_anim / 0.1, Fax.STAMP_INK, 1.0)
		"gap":
			pass
		_:
			var text := String(line.text)
			if shown >= 0:
				text = text.substr(0, shown)
			var col := Fax.INK_FAINT if kind == "dim" else Fax.INK
			# Dot-matrix ink: a slightly offset second pass reads as struck ribbon rather than crisp type.
			_canvas.draw_string(_font, Vector2(x + 0.6, y + 0.4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.35))
			_canvas.draw_string(_font, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.92))
