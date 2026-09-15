extends Control
## The OR monitor's picture, drawn into the screen's SubViewport. Immediate mode, from the model
## (scripts/orscreen/or_screen_model.gd). Phosphor look: near-black glass, green for fine, amber
## for low / needs attention, red for critical. Big type: it has to read from across the OR.

const GREEN := Color(0.36, 1.0, 0.56)
const GREEN_DIM := Color(0.16, 0.5, 0.3)
const GREEN_FAINT := Color(0.09, 0.26, 0.16)
const AMBER := Color(1.0, 0.72, 0.2)
const RED := Color(1.0, 0.26, 0.22)
const TEXT := Color(0.8, 1.0, 0.86)
const BG := Color(0.012, 0.03, 0.022)

var model: Dictionary = {}
## Seconds, advanced by the owner; drives the ECG sweep and the flashing states.
var t := 0.0

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static func level_color(level: String) -> Color:
	return GREEN if level == "ok" else (AMBER if level == "low" else RED)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var w := size.x
	var h := size.y
	draw_rect(Rect2(0, 0, w, h), BG)
	# A faint grid like an old patient monitor.
	for gx in range(0, int(w), 48):
		draw_line(Vector2(gx, 0), Vector2(gx, h), Color(GREEN_FAINT, 0.25), 1.0)
	for gy in range(0, int(h), 48):
		draw_line(Vector2(0, gy), Vector2(w, gy), Color(GREEN_FAINT, 0.25), 1.0)
	var panels: Array = model.get("panels", [])
	if String(model.get("mode", "idle")) != "cases" or panels.is_empty():
		_draw_idle(w, h)
		return
	var n := mini(panels.size(), 3)
	var pw := w / n
	for i in n:
		var r := Rect2(i * pw, 0, pw, h)
		if i > 0:
			draw_line(Vector2(r.position.x, 14), Vector2(r.position.x, h - 14), GREEN_DIM, 2.0)
		var p: Dictionary = panels[i]
		if String(p.state) == "incoming":
			_draw_incoming(r, p)
		elif n == 1:
			_draw_panel_wide(r, p)
		else:
			_draw_panel_narrow(r, p)


func _txt(pos: Vector2, s: String, px: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(_font, pos, s, align, width, px, col)


func _fit(s: String, px: int, width: float) -> String:
	if _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x <= width:
		return s
	while s.length() > 3 and _font.get_string_size(s + "..", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > width:
		s = s.substr(0, s.length() - 1)
	return s + ".."


func _blink(rate := 1.6) -> bool:
	return fmod(t * rate, 1.0) < 0.55


# ------------------------------------------------------------------------------ states

func _draw_idle(w: float, h: float) -> void:
	_txt(Vector2(30, 52), "OPERATING ROOM", 32, GREEN_DIM)
	_txt(Vector2(0, 52), "SHIFT %d" % int(model.get("shift", 1)), 32, GREEN_DIM, HORIZONTAL_ALIGNMENT_RIGHT, w - 30)
	_ecg(Rect2(40, h * 0.5 - 30, w - 80, 80), 100.0, "flat", GREEN_DIM)
	_txt(Vector2(0, h * 0.5 - 60), "AWAITING PATIENT", 84, GREEN, HORIZONTAL_ALIGNMENT_CENTER, w)
	var sub := "CLOCK IN TO START THE SHIFT" if bool(model.get("lobby", false)) else "NO PATIENT ON THE TABLE"
	_txt(Vector2(0, h * 0.5 + 130), sub, 40, GREEN_DIM, HORIZONTAL_ALIGNMENT_CENTER, w)


func _draw_incoming(r: Rect2, p: Dictionary) -> void:
	var on := _blink(1.4)
	var x := r.position.x
	var w := r.size.x
	var wide := w > 700
	if on:
		draw_rect(Rect2(x + 10, 10, w - 20, r.size.y - 20), Color(AMBER, 0.14))
	draw_rect(Rect2(x + 10, 10, w - 20, r.size.y - 20), AMBER if on else Color(AMBER, 0.35), false, 6.0)
	var big := 150 if wide else 76
	_txt(Vector2(x, r.size.y * 0.44), "INCOMING", big, AMBER if on else Color(AMBER, 0.45), HORIZONTAL_ALIGNMENT_CENTER, w)
	var name_px := 50 if wide else 32
	var y := r.size.y * 0.44 + name_px + 26
	_txt(Vector2(x, y), _fit(String(p.patient_name).to_upper(), name_px, w - 40), name_px, TEXT, HORIZONTAL_ALIGNMENT_CENTER, w)
	var ail := "%s (%s)" % [String(p.ailment_name).to_upper(), p.code] if String(p.code) != "" else String(p.ailment_name).to_upper()
	_txt(Vector2(x, y + name_px + 8), _fit(ail, name_px - 10, w - 40), name_px - 10, AMBER, HORIZONTAL_ALIGNMENT_CENTER, w)
	var tbl := int(p.table)
	var prep := "PREPARE TABLE %d" % (tbl + 1) if tbl >= 0 else "ON THE WAY IN"
	_txt(Vector2(x, r.size.y - 36), prep, 34 if wide else 24, GREEN_DIM, HORIZONTAL_ALIGNMENT_CENTER, w)


## One patient: name across the top, a big vitals number with its trace, then the checklist on the
## left and the supplies on the right. Sized to read from across the OR.
func _draw_panel_wide(r: Rect2, p: Dictionary) -> void:
	var w := r.size.x
	var h := r.size.y
	var col := _state_color(p)
	_header(r, p, 50, 32)
	# Vitals
	var vy := 116.0
	var vh := 160.0
	draw_rect(Rect2(16, vy, w - 32, vh), Color(GREEN_FAINT, 0.4))
	var vtxt := _vitals_text(p)
	_txt(Vector2(28, vy + vh - 22), vtxt, 150, col)
	var nw := _font.get_string_size(vtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 150).x
	_beat_dot(Vector2(28 + nw + 34, vy + vh * 0.5), p, col, 12.0)
	var ex := maxf(330.0, 28 + nw + 70)
	_ecg(Rect2(ex, vy + 14, w - ex - 30, vh - 28), float(p.vitals), _rhythm(p), col, 5.0)
	_monster_labels(Rect2(16, vy, w - 32, vh), p, 30)   # SWEEP 3 HOOK (dissection)
	_pill_note(Rect2(16, vy, w - 32, vh), p, 26)   # SWEEP 4A HOOK (pharmacy, chunk 3)
	# Checklist
	var y := vy + vh + 18.0
	var steps: Array = p.steps
	var row := 56.0 if steps.size() <= 4 else 44.0
	var px := 33 if steps.size() <= 4 else 28
	var col_w := w * 0.6
	for s in steps:
		_step_row(Rect2(16, y, col_w - 24, row - 8), s, px)
		y += row
	_status_line(Vector2(26, h - 14), p, w - 52, 30)
	# Supplies
	var sx := col_w
	_supplies(Rect2(sx, vy + vh + 18.0, w - sx - 16, h - (vy + vh + 18.0) - 44), p, 33, 56.0)


## Two or three patients side by side: the same content, stacked in a column.
func _draw_panel_narrow(r: Rect2, p: Dictionary) -> void:
	var x := r.position.x
	var w := r.size.x
	var h := r.size.y
	var col := _state_color(p)
	var third := w < 400.0
	_header(r, p, 28 if third else 36, 20 if third else 25)
	var vy := 94.0
	var vpx := 76 if third else 100
	draw_rect(Rect2(x + 8, vy, w - 16, vpx + 10), Color(GREEN_FAINT, 0.4))
	var vtxt := _vitals_text(p)
	_txt(Vector2(x + 16, vy + vpx - 2), vtxt, vpx, col)
	var nw := _font.get_string_size(vtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, vpx).x
	_beat_dot(Vector2(x + 16 + nw + 22, vy + vpx * 0.45), p, col, 8.0)
	var ex := x + 16 + nw + 44
	_ecg(Rect2(ex, vy + 8, x + w - 16 - ex, vpx - 6), float(p.vitals), _rhythm(p), col, 4.0)
	_monster_labels(Rect2(x + 8, vy, w - 16, vpx + 10), p, 18 if third else 22)   # SWEEP 3 HOOK (dissection)
	_pill_note(Rect2(x + 8, vy, w - 16, vpx + 10), p, 16 if third else 20)   # SWEEP 4A HOOK (pharmacy, chunk 3)
	var y := vy + vpx + 22.0
	var steps: Array = p.steps
	var row := 38.0 if not third else 32.0
	var px := 26 if not third else 20
	for s in steps:
		_step_row(Rect2(x + 8, y, w - 16, row - 5), s, px, true)
		y += row
	y += 8.0
	_supplies(Rect2(x + 4, y, w - 12, h - y - 44), p, px, row)
	_status_line(Vector2(x + 16, h - 14), p, w - 32, 26 if not third else 20)

# ------------------------------------------------------------------------------ pieces

func _header(r: Rect2, p: Dictionary, name_px: int, sub_px: int) -> void:
	var x := r.position.x
	var w := r.size.x
	var tbl := int(p.table)
	var tag := "TABLE %d" % (tbl + 1) if tbl >= 0 else "GURNEY"
	var tag_w := _font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, sub_px).x
	_txt(Vector2(x + 16, 12 + name_px), _fit(String(p.patient_name).to_upper(), name_px, w - tag_w - 48), name_px, TEXT)
	_txt(Vector2(x, 12 + name_px), tag, sub_px, GREEN_DIM, HORIZONTAL_ALIGNMENT_RIGHT, w - 16)
	var ail := String(p.ailment_name).to_upper()
	if String(p.code) != "":
		ail += "  (%s)" % p.code
	_txt(Vector2(x + 16, 24 + name_px + sub_px), _fit(ail, sub_px, w - 32), sub_px, AMBER)


## SWEEP 3 HOOK (dissection): on a strapped monster's panel the big number is the brain's condition
## (a "BRAIN" tag on it) and the top right of the box shows the sedation, amber while it stirs and
## blinking red once it is awake.
func _monster_labels(box: Rect2, p: Dictionary, px: int) -> void:
	if not bool(p.get("monster", false)):
		return
	_txt(Vector2(box.position.x + 10, box.position.y + px + 2), "BRAIN", px, Color(TEXT, 0.7))
	if String(p.state) != "on_table":
		return
	var s := float(p.get("sedation", 1.0))
	var col := GREEN if s >= 0.75 else (AMBER if s >= 0.35 else RED)
	var txt := "SEDATION %d%%" % roundi(s * 100.0)
	if s < 0.35:
		txt = ("AWAKE  " if _blink(1.4) else "") + txt
	_txt(Vector2(box.position.x, box.position.y + px + 2), txt, px, col, HORIZONTAL_ALIGNMENT_RIGHT, box.size.x - 10)


func _vitals_text(p: Dictionary) -> String:
	match String(p.state):
		"dead":
			return "0"
		_:
			return "%d" % ceili(float(p.vitals))


func _state_color(p: Dictionary) -> Color:
	match String(p.state):
		"dead":
			return RED
		"stable":
			return GREEN
	return level_color(String(p.level))


func _rhythm(p: Dictionary) -> String:
	match String(p.state):
		"dead":
			return "flat"
		"stable":
			return "calm"
	return "sinus"


## Beats per minute for a vitals value: faster as the patient weakens.
static func bpm_for(vitals: float) -> float:
	return lerpf(148.0, 64.0, clampf(vitals, 0.0, 100.0) / 100.0)


## SWEEP 4A HOOK (pharmacy, chunk 3): a hopeful green blip in the bottom-left corner of the vitals
## box for a few seconds after a thrown placebo pill lands on this patient. Vitals/sedation above
## are untouched; this reads straight off p.note (or_screen_model.gd derives it from pill_notes).
func _pill_note(box: Rect2, p: Dictionary, px: int) -> void:
	var note := String(p.get("note", ""))
	if note == "":
		return
	_txt(Vector2(box.position.x + 6, box.position.y + box.size.y - 8), note, px, GREEN)


func _beat_dot(at: Vector2, p: Dictionary, col: Color, radius := 9.0) -> void:
	var c := col
	if String(p.state) == "dead":
		if not _blink(2.0):
			return
		c = RED
	else:
		var ph := fmod(t * bpm_for(float(p.vitals)) / 60.0, 1.0)
		c = Color(col, clampf(1.0 - absf(ph - 0.31) * 5.0, 0.3, 1.0))
	# A small heart that beats with the trace.
	var k := radius / 6.0
	var o := at + Vector2(0, radius * 0.4)
	draw_circle(o + Vector2(-3.2, -2.0) * k, 3.6 * k, c)
	draw_circle(o + Vector2(3.2, -2.0) * k, 3.6 * k, c)
	draw_colored_polygon(PackedVector2Array([o + Vector2(-6.7, -0.9) * k, o + Vector2(6.7, -0.9) * k, o + Vector2(0, 7.0) * k]), c)


## A scrolling ECG strip over the last few seconds, newest at the right edge.
func _ecg(r: Rect2, vitals: float, rhythm: String, col: Color, width := 3.0) -> void:
	var window := 3.2
	var bpm := bpm_for(vitals) if rhythm != "calm" else 70.0
	var pts := PackedVector2Array()
	var steps := int(clampf(r.size.x / 2.0, 24.0, 400.0))
	var base := r.position.y + r.size.y * 0.62
	var amp := r.size.y * 0.55
	var ragged := clampf((50.0 - vitals) / 50.0, 0.0, 1.0) if rhythm == "sinus" else 0.0
	for i in steps + 1:
		var u := float(i) / steps
		var ts := t - window * (1.0 - u)
		var y := 0.0
		if rhythm != "flat":
			var beats := ts * bpm / 60.0
			var idx := floorf(beats)
			var ph := beats - idx
			var jit := 1.0 - ragged * 0.45 * (0.5 + 0.5 * sin(idx * 12.9898))
			y = _ecg_shape(ph) * jit
			y += ragged * 0.05 * sin(ts * 37.0)
		else:
			y = 0.015 * sin(ts * 9.0)
		pts.append(Vector2(r.position.x + u * r.size.x, base - y * amp))
	# The oldest part fades like phosphor.
	var fade_col := Color(col, 0.35)
	var split := int(steps * 0.35)
	if split > 1:
		draw_polyline(pts.slice(0, split + 1), fade_col, width)
	draw_polyline(pts.slice(split), col, width)
	draw_circle(pts[pts.size() - 1], width + 2.0, col)


static func _ecg_shape(p: float) -> float:
	var y := 0.0
	y += 0.12 * exp(-pow((p - 0.12) / 0.035, 2.0))    # P
	y -= 0.12 * exp(-pow((p - 0.265) / 0.018, 2.0))    # Q
	y += 1.0 * exp(-pow((p - 0.3) / 0.022, 2.0))      # R
	y -= 0.28 * exp(-pow((p - 0.335) / 0.02, 2.0))    # S
	y += 0.22 * exp(-pow((p - 0.55) / 0.05, 2.0))     # T
	return y


func _step_row(r: Rect2, s: Dictionary, px: int, show_item := false) -> void:
	var st := String(s.state)
	var box := Rect2(r.position.x + 8, r.position.y + (r.size.y - px * 0.8) * 0.5, px * 0.8, px * 0.8)
	var col := GREEN_DIM
	if st == "current":
		draw_rect(r, Color(AMBER, 0.2))
		draw_rect(Rect2(r.position.x, r.position.y, 5, r.size.y), AMBER)
		col = AMBER
	elif st == "done":
		col = GREEN
	draw_rect(box, col, false, 2.5)
	if st == "done":
		_tick(box, GREEN)
	elif st == "current" and _blink(1.2):
		draw_rect(box.grow(-box.size.x * 0.28), AMBER)
	var label := String(s.label).to_upper()
	var tx := box.end.x + 12
	var text_col := TEXT if st == "current" else (Color(GREEN, 0.75) if st == "done" else Color(TEXT, 0.45))
	var avail := r.end.x - tx - 8
	if show_item and st != "done":
		var item := String(s.item_name).to_upper()
		var iw := _font.get_string_size(item, HORIZONTAL_ALIGNMENT_LEFT, -1, px - 6).x
		_txt(Vector2(r.end.x - iw - 8, r.position.y + r.size.y * 0.5 + px * 0.33), item, px - 6, Color(TEXT, 0.4))
		avail -= iw + 12
	_txt(Vector2(tx, r.position.y + r.size.y * 0.5 + px * 0.36), _fit(label, px, avail), px, text_col)


func _tick(box: Rect2, col: Color) -> void:
	var a := box.position + Vector2(box.size.x * 0.18, box.size.y * 0.55)
	var b := box.position + Vector2(box.size.x * 0.42, box.size.y * 0.8)
	var c := box.position + Vector2(box.size.x * 0.86, box.size.y * 0.18)
	draw_polyline(PackedVector2Array([a, b, c]), col, 4.0)


func _supplies(r: Rect2, p: Dictionary, px: int, row: float) -> void:
	var list: Array = p.supplies
	var y := r.position.y
	if list.is_empty():
		var msg := "NOTHING MORE NEEDED" if String(p.state) != "dead" else "-"
		_txt(Vector2(r.position.x + 10, y + px + 8), msg, px - 4, GREEN_DIM)
		return
	for s in list:
		if y + row > r.end.y + 4:
			break
		var ok := bool(s.ok)
		var col := GREEN if ok else (AMBER if int(s.have) > 0 else RED)
		var box := Rect2(r.position.x + 10, y + (row - px * 0.8) * 0.5, px * 0.8, px * 0.8)
		if ok:
			draw_rect(box, Color(GREEN, 0.25))
			_tick(box, GREEN)
		draw_rect(box, col, false, 2.5)
		var count := "%d/%d" % [int(s.have), int(s.need)]
		var cw := _font.get_string_size(count, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		var baseline := y + row * 0.5 + px * 0.36
		_txt(Vector2(r.end.x - cw - 6, baseline), count, px, col)
		_txt(Vector2(box.end.x + 12, baseline), _fit(String(s.name).to_upper(), px, r.end.x - cw - box.end.x - 30), px,
			TEXT if ok else Color(TEXT, 0.8))
		y += row


## The bottom line: who is operating, whether the next step can start, or the outcome.
func _status_line(at: Vector2, p: Dictionary, width: float, px: int) -> void:
	var text := ""
	var col := GREEN
	match String(p.state):
		"dead":
			text = ("BRAIN RUINED" if bool(p.get("monster", false)) else "FLATLINE") if _blink(1.0) else ""   # SWEEP 3 HOOK (dissection)
			col = RED
		"stable":
			text = "BRAIN HARVESTED" if bool(p.get("monster", false)) else "STABLE"   # SWEEP 3 HOOK (dissection)
		_:
			if String(p.operator) != "":
				text = "%s OPERATING  %d%%" % [String(p.operator).to_upper(), roundi(float(p.progress) * 100.0)]
				col = GREEN
			elif int(p.current) >= (p.steps as Array).size():
				text = "STABLE"
			elif bool(p.ready):
				text = "READY: OPERATE AT THE TABLE"
			else:
				text = "BRING SUPPLIES TO THE SHELF"
				col = AMBER
			if String(p.level) == "critical" and _blink(2.2):
				text = "CRITICAL"
				col = RED
	if text != "":
		_txt(at, _fit(text, px, width), px, col)
