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
##   4. FEED OUT: the page speeds up and out of the top of the screen. The title menu underneath
##      draws the same printer (scripts/fax_printer.gd) and carries the paper on at the speed this
##      page left at (`paper_scroll_px`, `feed_speed`), feeding its sign-in sheet in.

signal done

const Fax := preload("res://scripts/fax_printer.gd")

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
## Seconds for the finished page to accelerate up and off the screen.
const FEED_OUT := 0.8
const FEED_TICK := 0.11

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


## How far the paper has moved up, in pixels: where the next page's green bars and holes carry on.
func paper_scroll_px() -> float:
	return _scroll * Fax.LINE_H + _feed_px


## The paper's speed (px/s) as the page leaves: the next page starts at this speed.
func feed_speed() -> float:
	return 2.0 * _feed_dist / FEED_OUT if _feed_dist > 0.0 else 0.0


func _queue_chart() -> void:
	var dt := Time.get_datetime_dict_from_system()
	var date := "%04d-%02d-%02d" % [dt.year, dt.month, dt.day]
	var clock := "%02d:%02d" % [dt.hour, dt.minute]
	var items := Items.ITEMS.size()
	for line in [
		[">> FAX  %s  %s  PAGE 1 OF 2" % [date, clock], "dim", false],
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
		if _feed_t < 0.0 and _drawn and _now() - _drawn_at >= AFTER_DRAW_HOLD and _now() - _stamp_at >= STAMP_HOLD:
			_start_feed_out()
		if _feed_t >= 0.0:
			_feed_t += dt
			var t := minf(_feed_t / FEED_OUT, 1.0)
			_feed_px = _feed_dist * t * t   # accelerating: leaves at feed_speed()
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
	# Far enough that the stamp, the last thing printed, is gone off the top.
	_feed_dist = _canvas.size.y * Fax.SLOT + Fax.LINE_H * 3.0
	_head_from = _head_x(Fax.layout(_canvas.size, _font))


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
	Fax.draw_paper(_canvas, size, l, paper_scroll_px(), 1.0)

	# Printed lines, newest at the head, older ones scrolled up.
	var fs := Fax.FONT_SIZE
	var print_y: float = l.print_y
	var tx: float = l.tx
	var text_w: float = l.text_w
	var total := _printed.size()
	for i in range(total - 1, -1, -1):
		var y := print_y - (_scroll - float(i)) * Fax.LINE_H - _feed_px
		if y < -Fax.LINE_H * 3.0:
			break
		_draw_line(_printed[i], tx, y, text_w, fs, -1)
	if not _current.is_empty():
		_draw_line(_current, tx, print_y - (_scroll - float(total)) * Fax.LINE_H, text_w, fs, int(_chars))
	Fax.draw_top_fade(_canvas, size, 1.0)

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
