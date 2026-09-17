extends CanvasLayer
## The shift assignment: the fax page that covers a session start from the title menu (solo, host,
## host on Steam, join). Same printer as the menu (scripts/fax_printer.gd), so the hand-off doesn't
## move a pixel:
##
##   1. The sign-in sheet ejects off the top (Menu.eject) and this page feeds up out of the slot.
##   2. It stands there, LCD LOADING / CONNECTING, while main.gd builds or joins the session.
##   3. Once the player is in the hospital and frames have settled (the first frames of a new level
##      are the hitchy ones, drawn behind the still-opaque room), the room fades part way so the
##      hospital shows faintly through while a last line types at the print head: GOOD LUCK...
##   4. A short beat, then the pause fax's leaving motion (scripts/settings_screen.gd close()): the page
##      ejects off the top, the printer sinks off the bottom and the rest of the room fades out. The
##      mouse and keys go back to the player as that starts (main.gd _update_mouse via holds_input());
##      only the pause fax waits the moment until this printer has gone.
##   Steps 3-4 add under 2 s once the world is ready (docs/FAX.md).
##
## A failed start (connection refused, host gone, hosting failed) calls cancel(): the page ejects
## off the top like any other and main.gd feeds a fresh sign-in sheet in with the reason on it.
##
##     ShiftFax.begin("session", "solo", name)   # or "join"; reasons overlap like Loading's
##     await ShiftFax.drawn()                     # before blocking work
##     ...build...
##     ShiftFax.end("session")
##
## Headless (tests): nothing is drawn and nothing waits; is_active() is true from begin() until the
## session is in, or until cancel().

signal finished

const Fax := preload("res://scripts/fax_printer.gd")

## Over the title menu (51) and the settings fax (52), under the heart monitor (Loading, 125).
const LAYER := 53
## Longest step of animation time per frame: a long blocking frame holds the paper up for a moment
## instead of skipping most of an animation.
const MAX_STEP := 0.1
const PAGE_MARGIN := 30.0
## Blank paper between the pre-printed lines and the print line the last message goes on.
const GAP := 0.35
## After the player is in: quick frames in a row (and at least SETTLE_MIN, at most SETTLE_MAX
## seconds) before anything behind the paper is allowed to show.
const CALM_FRAMES := 8
const CALM_MS := 50.0
const SETTLE_MIN := 0.3
const SETTLE_MAX := 8.0
## The room fades to ROOM_FLOOR (and the paper to PAPER_FLOOR) over FADE_UP seconds; the last line
## starts printing MESSAGE_AT seconds in.
const FADE_UP := 0.5
const ROOM_FLOOR := 0.3
const PAPER_FLOOR := 0.9
const MESSAGE_AT := 0.08
const MESSAGE := "GOOD LUCK..."
const MESSAGE_CPS := 36.0
## Extra seconds each trailing dot takes.
const DOT_PAUSE := 0.06
const BEAT_SECONDS := 0.25
## Leaving: the page ejects (Fax.EJECT_SECONDS) while the printer sinks (Fax.DROP_SECONDS).
const OUT_SECONDS := Fax.DROP_SECONDS

enum State { IDLE, WAIT_MENU, FEED, LOADING, SETTLE, FADE, BEAT, OUT, CANCEL }

## The title menu, set by main.gd: ejected to make way, and fed back in by main after a cancel.
var menu: Control = null

var _state := State.IDLE
var _reasons := {}
var _headless := false
var _font: Font
var _canvas: Control
var _lines: Array = []    # [text, kind]: kind "text", "dim", "rule"
var _page := 3
var _t := 0.0             # seconds into the current state (animation time)
var _since := 0.0         # wall clock the current state began
var _calm := 0
var _feed_tick := 0.0
var _msg_t := -1.0        # seconds into printing the message, < 0 before it starts
var _cancel_then: Callable
var _cancel_from := 0.0   # where the page was (see _page_offset) when a cancel sent it away
var _cancel_pending := false
var _last_usec := 0


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	_font = Fax.make_font()
	_canvas = Control.new()
	_canvas.name = "Page"
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP   # no clicking through to the menu mid-load
	_canvas.draw.connect(_draw_page)
	add_child(_canvas)
	_fit()
	get_viewport().size_changed.connect(_fit)
	visible = false


func _fit() -> void:
	Fax.fit_layer(self, _canvas)


## Put the page up for `reason` (or add a reason to the page already up). `mode` ("solo", "host",
## "steam", "join") and `surgeon` fill in the page the first time.
func begin(reason: String, mode := "solo", surgeon := "") -> void:
	_reasons[reason] = true
	if _state != State.IDLE and _state != State.CANCEL:
		return
	_cancel_pending = false
	_cancel_then = Callable()
	_msg_t = -1.0
	var from_menu: bool = menu != null and is_instance_valid(menu) and menu.visible
	_page = int(menu.page_no) + 1 if menu != null and is_instance_valid(menu) else 3
	_fill_page(mode, surgeon)
	if _headless:
		_enter(State.LOADING)
		return
	if from_menu and menu.has_method("eject"):
		_enter(State.WAIT_MENU)
		menu.eject(_on_menu_ejected)
	else:
		_start_feed()


func end(reason: String) -> void:
	_reasons.erase(reason)


## Up at all: from begin() until the page has gone (or been cancelled away).
func is_active() -> bool:
	return _state != State.IDLE


func has_reason(reason: String) -> bool:
	return _reasons.has(reason)


## The player's mouse stays free (and so their surgeon still) until the page starts to leave: from
## then on the shift has the mouse and keys while the page and printer animate away.
func holds_input() -> bool:
	return is_active() and _state != State.OUT


## Resolves once the page covers the screen (the menu's sheet has gone and this one has drawn).
func drawn() -> void:
	while _state == State.WAIT_MENU:
		await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


## The start failed: eject the page off the top (the printer stays), then `then` runs (main.gd shows
## the menu and feeds a fresh sign-in sheet into the same printer).
func cancel(then: Callable = Callable()) -> void:
	_reasons.clear()
	if _state == State.IDLE:
		if then.is_valid():
			then.call()
		return
	if _state == State.WAIT_MENU:
		# The sign-in sheet is still on its way out; go straight back once it has.
		_cancel_pending = true
		_cancel_then = then
		return
	if _headless or _state == State.OUT:
		_finish()
		if then.is_valid():
			then.call()
		return
	_cancel_then = then
	_cancel_from = _page_offset(_layout())   # half fed in, it leaves from there
	_enter(State.CANCEL)
	Fax.sfx("print_feed", -8.0)


func _on_menu_ejected() -> void:
	if menu != null and is_instance_valid(menu):
		menu.visible = false
	if _cancel_pending:
		_cancel_pending = false
		var then := _cancel_then
		_cancel_then = Callable()
		_finish()
		if then.is_valid():
			then.call()
		return
	_start_feed()


func _start_feed() -> void:
	visible = true
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP   # no clicking through to the menu mid-load
	_feed_tick = 0.0
	Fax.sfx("print_feed", -8.0)
	_enter(State.FEED)
	_canvas.queue_redraw()


func _enter(s: State) -> void:
	_state = s
	_t = 0.0
	_since = _now()
	_calm = 0
	_last_usec = Time.get_ticks_usec()


func _finish() -> void:
	_state = State.IDLE
	_reasons.clear()
	visible = false
	finished.emit()


func _fill_page(mode: String, surgeon: String) -> void:
	var dt := Time.get_datetime_dict_from_system()
	var staffing := "SOLO"
	match mode:
		"host":
			staffing = "HOSTING. OTHERS MAY JOIN."
		"steam":
			staffing = "HOSTING. FRIENDS ONLY."
		"join":
			staffing = "REPORTING AS BACKUP"
	_lines = [
		[">> FAX  %04d-%02d-%02d  %02d:%02d  PAGE %d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, _page], "dim"],
		["COUNTY GENERAL  /  SHIFT ASSIGNMENT", "text"],
		["", "rule"],
		["SURGEON ........ %s" % (surgeon if surgeon != "" else "ON CALL"), "text"],
		["STAFFING ....... %s" % staffing, "text"],
		["REPORT TO ...... THE TIME CLOCK", "text"],
		["NEXT OF KIN .... ON FILE", "text"],
		["", "rule"],
	]


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _game() -> Node:
	return get_tree().get_first_node_in_group("game")


## The session is in: no reason left, a hospital and our own surgeon standing in it.
func _world_ready() -> bool:
	if not _reasons.is_empty():
		return false
	var g := _game()
	return g != null and g.phase != Game.Phase.MENU and g.local_player() != null


func _process(_delta: float) -> void:
	if _state == State.IDLE:
		return
	var now_usec := Time.get_ticks_usec()
	var real_dt := float(now_usec - _last_usec) / 1000000.0
	_last_usec = now_usec
	if _headless:
		if _state != State.WAIT_MENU and _world_ready():
			_finish()
		return
	var dt := minf(real_dt, MAX_STEP)
	_t += dt
	match _state:
		State.FEED:
			_feed_tick -= dt
			if _feed_tick <= 0.0 and _t < Fax.FEED_SECONDS * 0.85:
				_feed_tick = Fax.FEED_TICK
				Fax.sfx("print_feed", -14.0, 0.1)
			if _t >= Fax.FEED_SECONDS:
				_enter(State.LOADING)
		State.LOADING:
			if _world_ready():
				_enter(State.SETTLE)
		State.SETTLE:
			if not _world_ready():
				_enter(State.LOADING)
			else:
				_calm = _calm + 1 if real_dt * 1000.0 < CALM_MS else 0
				var waited := _now() - _since
				if (_calm >= CALM_FRAMES and waited >= SETTLE_MIN) or waited >= SETTLE_MAX:
					_enter(State.FADE)
		State.FADE:
			if _msg_t < 0.0 and _t >= MESSAGE_AT:
				_msg_t = 0.0
				Fax.sfx("print_line", -11.0, 0.0)
			elif _msg_t >= 0.0:
				_msg_t += dt
			if _t >= FADE_UP and _message_done():
				_enter(State.BEAT)
		State.BEAT:
			if _t >= BEAT_SECONDS:
				_enter(State.OUT)
				# The shift has the mouse back from here (holds_input), so no clicks land on the page.
				_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
				Fax.sfx("print_feed", -8.0)
		State.OUT:
			if _t >= maxf(OUT_SECONDS, Fax.EJECT_SECONDS):
				_finish()
				return
		State.CANCEL:
			if _t >= Fax.EJECT_SECONDS:
				var then := _cancel_then
				_cancel_then = Callable()
				_finish()
				if then.is_valid():
					then.call()
				return
	_canvas.queue_redraw()


## How many characters of the message are on the paper: the words at MESSAGE_CPS, each trailing
## dot a beat slower.
func _message_chars() -> int:
	if _msg_t < 0.0:
		return 0
	var words := MESSAGE.rstrip(".").length()
	var n := int(_msg_t * MESSAGE_CPS)
	if n <= words:
		return n
	var dots := int((_msg_t - float(words) / MESSAGE_CPS) / (1.0 / MESSAGE_CPS + DOT_PAUSE))
	return mini(words + dots, MESSAGE.length())


func _message_done() -> bool:
	return _message_chars() >= MESSAGE.length()


# -- layout and drawing ----------------------------------------------------------------------

func _layout() -> Dictionary:
	return Fax.layout(_canvas.size, _font)


## Baseline of pre-printed line `i` at rest: the last one a little above the print line.
func _line_y(i: int, l: Dictionary) -> float:
	return float(l.print_y) - (float(_lines.size() - i) + GAP) * Fax.LINE_H


func _page_top_rest(l: Dictionary) -> float:
	return _line_y(0, l) - Fax.LINE_H * 0.7 - PAGE_MARGIN


## From just inside the slot up to rest: the page's whole height.
func _feed_dist(l: Dictionary) -> float:
	return float(l.slot_y) - _page_top_rest(l)


## How far the printer has sunk off its place: only while the page leaves at the end.
func _printer_drop(l: Dictionary) -> float:
	if _state != State.OUT:
		return 0.0
	return Fax.ease_in(_t / OUT_SECONDS) * Fax.printer_gone_px(_canvas.size, l)


## How far the page has moved up from rest: negative while feeding up out of the slot.
func _page_offset(l: Dictionary) -> float:
	var gone := float(l.slot_y) + PAGE_MARGIN + 20.0   # its bottom edge clear of the top of the screen
	match _state:
		State.FEED:
			return -(1.0 - Fax.ease_out(_t / Fax.FEED_SECONDS)) * _feed_dist(l)
		State.OUT:
			return Fax.ease_in(_t / Fax.EJECT_SECONDS) * gone
		State.CANCEL:
			return lerpf(_cancel_from, gone, Fax.ease_in(_t / Fax.EJECT_SECONDS))
	return 0.0


func _room_alpha() -> float:
	match _state:
		State.FADE:
			return lerpf(1.0, ROOM_FLOOR, ease(clampf(_t / FADE_UP, 0.0, 1.0), -1.8))
		State.BEAT:
			return ROOM_FLOOR
		State.OUT:
			return ROOM_FLOOR * (1.0 - Fax.ease_out(_t / OUT_SECONDS))
	return 1.0


func _paper_alpha() -> float:
	match _state:
		State.FADE:
			return lerpf(1.0, PAPER_FLOOR, clampf(_t / FADE_UP, 0.0, 1.0))
		State.BEAT, State.OUT:
			return PAPER_FLOOR
	return 1.0


func _draw_page() -> void:
	if _state == State.IDLE or _state == State.WAIT_MENU:
		return
	var size := _canvas.size
	var l := _layout()
	var room_a := _room_alpha()
	var a := _paper_alpha()
	if room_a > 0.0:
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(Fax.ROOM, room_a))
	var up := _page_offset(l)
	var drop := _printer_drop(l)
	var slot_y: float = l.slot_y
	var top := _page_top_rest(l) - up
	var bottom := minf(slot_y - maxf(up, 0.0), slot_y + drop)
	Fax.draw_paper(_canvas, size, l, _feed_dist(l) + up, a, bottom, false, top)

	var tx: float = l.tx
	var text_w: float = l.text_w
	var fs := Fax.FONT_SIZE
	for i in _lines.size():
		var y := _line_y(i, l) - up
		if y > slot_y + fs:
			continue   # still inside the printer
		var kind := String(_lines[i][1])
		if kind == "rule":
			Fax.draw_rule(_canvas, tx, y - fs * 0.35, text_w, a)
		else:
			_ink(String(_lines[i][0]), tx, y, Fax.INK_FAINT if kind == "dim" else Fax.INK, a)
	var shown := _message_chars()
	if shown > 0:
		_ink(MESSAGE.substr(0, shown), tx, float(l.print_y) - up, Fax.STAMP_INK, a)

	# The printer: its head follows the message as it prints; the LCD says what the page is waiting on.
	var head_x := tx + float(l.char_w) * float(shown)
	var status := "LOADING"
	var light := Fax.LCD_WAIT
	match _state:
		State.FEED:
			status = "RECEIVING"
			light = Fax.LCD_TEXT
		State.LOADING, State.SETTLE:
			var g := _game()
			status = "CONNECTING" if has_reason("join") and (g == null or g.phase == Game.Phase.MENU) else "LOADING"
			status += ".".repeat(1 + int(_now() * 2.0) % 3)
			if int(_now() * 2.0) % 2 == 1:
				light = Color(Fax.LCD_WAIT, 0.35)
		State.FADE:
			status = "PRINTING" if _msg_t >= 0.0 else "READY"
			light = Fax.LCD_TEXT
		State.BEAT, State.OUT:
			status = "PAGE COMPLETE"
			light = Fax.LCD_TEXT
		State.CANCEL:
			status = "CANCELLED"
			light = Fax.STAMP_INK
	Fax.draw_printer(_canvas, size, l, _font, head_x, status, light, a, drop)


## Dot-matrix ink, like the launch printout: a faint offset second strike under the line.
func _ink(text: String, x: float, y: float, col: Color, a: float) -> void:
	_canvas.draw_string(_font, Vector2(x + 0.6, y + 0.4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, Fax.FONT_SIZE, Color(col, 0.35 * a))
	_canvas.draw_string(_font, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, Fax.FONT_SIZE, Color(col, 0.92 * a))
