extends CanvasLayer
## The `Loading` autoload: the in-game loading screen, a heart monitor whose trace sweeps and beeps
## while anything is loading (a new hospital between runs). Session starts from the title menu use
## the shift assignment fax instead (scripts/shift_fax.gd).
##
##     Loading.begin("new_run", "NEW HOSPITAL...")
##     await Loading.drawn()        # before blocking work, so the screen is actually up first
##     ...build...
##     Loading.end("new_run")
##
## Reasons can overlap (a session start, then the warmup it kicks off): the screen stays up until
## every reason has ended and it has been visible for MIN_SECONDS, then fades. The trace and the
## beat are functions of the wall clock, so a long blocking build makes the trace jump ahead when
## the next frame draws instead of falling behind.

const LAYER := 125
const MIN_SECONDS := 0.9
const FADE_SECONDS := 0.3
const BPM := 72.0
## Seconds for the trace to sweep once across the monitor (a little over three beats).
const SWEEP_SECONDS := 2.8
## Where in a beat the R spike (and the beep) lands.
const R_PHASE := 0.25
const BEEP_DB := -12.0

const BG := Color("06080c")
const PANEL := Color("0b1114")
const GRID := Color(0.36, 0.88, 0.82, 0.07)
const TRACE := Color("9fe8a0")
const TEXT := Color("8a9aa0")

var _reasons := {}   # reason -> label text ("" keeps whatever label is up)
var _order: Array = []
var _shown_at := 0.0
var _alpha := 0.0
var _last_beat := 0
var _hr := 72
var _canvas: Control


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP   # no clicking through to the menu mid-load
	_canvas.draw.connect(_draw_screen)
	add_child(_canvas)
	visible = false


func begin(reason: String, text: String = "") -> void:
	if not visible:
		_shown_at = _now()
		_last_beat = _beat_index(_now())
	if not _reasons.has(reason):
		_order.append(reason)
	_reasons[reason] = text
	_alpha = 1.0
	visible = true


func end(reason: String) -> void:
	_reasons.erase(reason)
	_order.erase(reason)


func is_active() -> bool:
	return not _reasons.is_empty()


func has_reason(reason: String) -> bool:
	return _reasons.has(reason)


## Two frames: one to lay the screen out, one to present it.
func drawn() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _process(delta: float) -> void:
	if not visible:
		return
	var now := _now()
	if _reasons.is_empty() and now - _shown_at >= MIN_SECONDS:
		_alpha = move_toward(_alpha, 0.0, delta / FADE_SECONDS)
		if _alpha <= 0.0:
			visible = false
			return
	elif not _reasons.is_empty():
		_alpha = 1.0
	var beat := _beat_index(now)
	if beat != _last_beat:
		_last_beat = beat   # after a long stall, one beep, not a burst
		if not _reasons.is_empty():
			_hr = 70 + randi() % 6
			Audio.play("surgery_beep", null, BEEP_DB, 0.0, Audio.BUS_UI)
	_canvas.queue_redraw()


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _beat_index(t: float) -> int:
	return int(floor(t * BPM / 60.0 - R_PHASE))


## One heartbeat, p in [0, 1): P wave, QRS complex, T wave. About -0.3 .. 1.0.
static func _ecg(p: float) -> float:
	return 0.12 * _bump(p, 0.12, 0.028) - 0.14 * _bump(p, R_PHASE - 0.022, 0.009) \
			+ 1.0 * _bump(p, R_PHASE, 0.011) - 0.3 * _bump(p, R_PHASE + 0.022, 0.011) \
			+ 0.26 * _bump(p, 0.47, 0.05)


static func _bump(p: float, c: float, w: float) -> float:
	var d := (p - c) / w
	return exp(-d * d)


func _label_text() -> String:
	for i in range(_order.size() - 1, -1, -1):
		var t := String(_reasons.get(_order[i], ""))
		if t != "":
			return t
	return "LOADING..."


func _draw_screen() -> void:
	var size := _canvas.size
	var a := _alpha
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(BG, a))
	var now := _now()

	# The monitor.
	var w := minf(size.x * 0.62, 900.0)
	var h := 190.0
	var mon := Rect2(Vector2((size.x - w) * 0.5, size.y * 0.5 - h * 0.62), Vector2(w, h))
	_canvas.draw_rect(mon.grow(10.0), Color(PANEL, a))
	_canvas.draw_rect(mon.grow(10.0), Color(TEXT, 0.25 * a), false, 1.5)
	var cell := 24.0
	var gx := mon.position.x
	while gx <= mon.end.x:
		_canvas.draw_line(Vector2(gx, mon.position.y), Vector2(gx, mon.end.y), Color(GRID, GRID.a * a), 1.0)
		gx += cell
	var gy := mon.position.y
	while gy <= mon.end.y:
		_canvas.draw_line(Vector2(mon.position.x, gy), Vector2(mon.end.x, gy), Color(GRID, GRID.a * a), 1.0)
		gy += cell

	# The trace: every column shows the signal at the moment the sweep passed it, brightest right
	# behind the head, fading toward the gap just ahead of it.
	var base_y := mon.position.y + h * 0.66
	var amp := h * 0.52
	var head := fposmod(now, SWEEP_SECONDS) / SWEEP_SECONDS * w
	var gap := w * 0.05
	var step := 2.0
	var beat_s := 60.0 / BPM
	var before := PackedVector2Array()
	var before_c := PackedColorArray()
	var after := PackedVector2Array()
	var after_c := PackedColorArray()
	var x := 0.0
	while x <= w:
		var behind := head - x if x <= head else head + w - x
		if behind <= w - gap:
			var t := now - behind / w * SWEEP_SECONDS
			var y := base_y - _ecg(fposmod(t, beat_s) / beat_s) * amp
			var fade := pow(1.0 - behind / w, 1.6)
			var pt := Vector2(mon.position.x + x, y)
			var col := Color(TRACE, a * (0.15 + 0.85 * fade))
			if x <= head:
				before.append(pt)
				before_c.append(col)
			else:
				after.append(pt)
				after_c.append(col)
		x += step
	if before.size() >= 2:
		_canvas.draw_polyline_colors(before, before_c, 2.5, true)
	if after.size() >= 2:
		_canvas.draw_polyline_colors(after, after_c, 2.5, true)
	if before.size() >= 1:
		var tip: Vector2 = before[before.size() - 1]
		_canvas.draw_circle(tip, 7.0, Color(TRACE, 0.18 * a))
		_canvas.draw_circle(tip, 3.5, Color(TRACE, a))

	# Heart rate, the heart pulsing on each beat, and the label.
	var font := ThemeDB.fallback_font
	var since := fposmod(now * BPM / 60.0 - R_PHASE, 1.0) * beat_s
	var pulse := clampf(1.0 - since / 0.25, 0.0, 1.0)
	var hr_pos := Vector2(mon.end.x - 110.0, mon.position.y + 34.0)
	_draw_heart(hr_pos + Vector2(-18.0, -9.0), 8.0 + 3.0 * pulse, Color(TRACE, a * (0.55 + 0.45 * pulse)))
	_canvas.draw_string(font, hr_pos, "HR %d" % _hr, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(TRACE, a))
	_canvas.draw_string(font, Vector2(mon.position.x + 12.0, mon.position.y + 30.0), "II", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(TEXT, 0.7 * a))
	var dots := ".".repeat(1 + int(now * 2.0) % 3)
	var label := _label_text().trim_suffix("...") + dots
	_canvas.draw_string(font, Vector2(mon.position.x, mon.end.y + 64.0), label, HORIZONTAL_ALIGNMENT_CENTER, w, 26, Color(TEXT, a))


func _draw_heart(c: Vector2, r: float, col: Color) -> void:
	_canvas.draw_circle(c + Vector2(-r * 0.5, 0.0), r * 0.55, col)
	_canvas.draw_circle(c + Vector2(r * 0.5, 0.0), r * 0.55, col)
	_canvas.draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 1.02, r * 0.15), c + Vector2(r * 1.02, r * 0.15), c + Vector2(0.0, r * 1.25)]), col)
