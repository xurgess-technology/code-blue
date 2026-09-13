extends CanvasLayer
## The surgery view's overlay, created by the surgery system. Same look as scripts/hud.gd:
## the fallback font, dark translucent panels, red / green / amber.
##
## Local operator: a slim strip with the step title, the patient's vitals as a number and the hint
## (minimal HUD, sweep 2 orscreen: no gauges, no progress bar).
## Anyone else near the table: one small "Bob is operating: Remove the bullet 40%" line.

const SPECTATE_RANGE := 6.0

var system: Node = null
var _canvas: Control


func _ready() -> void:
	layer = 3
	_canvas = _Canvas.new()
	_canvas.hud = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)


func _process(_delta: float) -> void:
	if _canvas != null:
		_canvas.queue_redraw()


class _Canvas extends Control:
	var hud = null
	var _t := 0.0
	## What the last frame drew: "operator", "cross_section", "spectator" (tests read it).
	var drawn := PackedStringArray()

	func _process(delta: float) -> void:
		_t += delta

	func _draw() -> void:
		drawn = PackedStringArray()
		if hud == null or hud.system == null or hud.system.game == null:
			return
		var sys = hud.system
		var game = sys.game
		if int(game.get("phase")) != 2:   # Game.Phase.SHIFT
			return
		var st: Dictionary = sys.hud_state()
		if st.is_empty():
			return
		var font := ThemeDB.fallback_font
		var w := size.x
		var h := size.y
		if bool(st.get("local", false)):
			_draw_operator(font, w, h, st, game)
		else:
			_draw_spectator(font, w, h, st, game)

	## ORSCREEN (minimal HUD): one slim strip at the bottom. The step title with the patient's vitals as
	## a small number, and the one-line hint. No gauges (the minigames show what is right in the
	## world) and no progress bar; the OR wall monitor carries the checklist and supplies.
	func _draw_operator(font: Font, w: float, h: float, st: Dictionary, game) -> void:
		drawn.append("operator")
		var xs: Dictionary = st.get("cross_section", {})
		var pw := minf(620.0, w - 40.0)
		var ph := 48.0
		var x := w * 0.5 - pw * 0.5
		var y := h - ph - 16.0
		draw_rect(Rect2(x, y, pw, ph), Color(0, 0, 0, 0.42))
		draw_rect(Rect2(x, y, 3, ph), Color(0.36, 0.88, 0.82, 0.8))
		var case_d: Dictionary = _case_of(game)
		var idx := int(case_d.get("step_index", 0)) + 1
		var total := Procedures.steps(String(case_d.get("ailment_id", ""))).size()
		var v: float = maxf(0.0, _vitals_of(game, case_d))
		var vcol := Color("5cff8a") if v > 50.0 else (Color("ffd35c") if v > 25.0 else Color(1, 0.16, 0.16, 0.7 + 0.3 * sin(_t * 9.0)))
		var vtxt := "VITALS %d" % ceili(v)
		var vw := font.get_string_size(vtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		var title := "%d/%d  %s" % [idx, total, String(st.get("title", "")).to_upper()] if total > 0 else String(st.get("title", "")).to_upper()
		draw_string(font, Vector2(x + 14, y + 19), title, HORIZONTAL_ALIGNMENT_LEFT, pw - vw - 44, 14, Color(0.94, 0.9, 0.78, 0.95))
		draw_string(font, Vector2(x + pw - vw - 14, y + 19), vtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, vcol)
		var hint := String(st.get("hint", ""))
		var hint_col := Color(0.79, 0.82, 0.85, 0.9)
		if bool(st.get("stirring", false)):
			hint = "The patient is stirring! " + hint
			hint_col = Color(1, 0.42, 0.42, 0.75 + 0.25 * sin(_t * 14.0))
		var esc := "Esc / E: step away"
		var ew := font.get_string_size(esc, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, Vector2(x + 14, y + 38), hint, HORIZONTAL_ALIGNMENT_LEFT, pw - ew - 44, 13, hint_col)
		draw_string(font, Vector2(x + pw - ew - 14, y + 38), esc, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.6, 0.6, 0.7))
		if not xs.is_empty():
			drawn.append("cross_section")
			draw_rect(Rect2(x, y - 30, pw, 26), Color(0, 0, 0, 0.42))
			_cross_section(font, x + 14, y - 30, pw - 28, xs)

	## The case being operated on: the system's own when it has one (per-table surgery, `loop`),
	## else game.case.
	func _case_of(game) -> Dictionary:
		var sys = hud.system
		if sys.has_method("_case"):   # loop: this table's case
			return sys._case()
		return game.case if game.case is Dictionary else {}

	func _vitals_of(game, case_d: Dictionary) -> float:
		if case_d.has("vitals"):
			return float(case_d.vitals)
		return float(game.get("vitals")) if game.get("vitals") != null else 100.0

	## A cut-through-the-limb strip: one coloured segment per tissue layer, the part already cut
	## darkened, and a marker at the current depth. From hud_state()["cross_section"]:
	## {layers: [{name, from, to, color}], depth: 0..1, layer: index}.
	func _cross_section(font: Font, x: float, y: float, bw: float, xs: Dictionary) -> void:
		var layers: Array = xs.get("layers", [])
		var depth := clampf(float(xs.get("depth", 0.0)), 0.0, 1.0)
		var li := int(xs.get("layer", 0))
		var lw := 120.0
		var lname := String(layers[li].get("name", "")) if li >= 0 and li < layers.size() else ""
		draw_string(font, Vector2(x, y + 14), ("Cut: " + lname).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, lw - 8, 12, Color("c9d1d9"))
		var bx := x + lw
		var w := bw - lw - 56.0
		for l in layers:
			var a := clampf(float(l.get("from", 0.0)), 0.0, 1.0)
			var b := clampf(float(l.get("to", 1.0)), 0.0, 1.0)
			var col: Color = l.get("color", Color.GRAY)
			draw_rect(Rect2(bx + w * a, y + 4, w * (b - a), 12), col.darkened(0.15))
			draw_rect(Rect2(bx + w * a, y + 4, 1, 12), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bx, y + 4, w * depth, 12), Color(0, 0, 0, 0.55))
		var mx := bx + w * depth
		draw_rect(Rect2(mx - 2, y + 1, 4, 18), Color("ffffff"))
		draw_string(font, Vector2(bx + w + 8, y + 15), "%d%%" % roundi(depth * 100.0), HORIZONTAL_ALIGNMENT_LEFT, 48, 12, Color("eeeeee"))

	func _draw_spectator(font: Font, w: float, h: float, st: Dictionary, game) -> void:
		var view = game.viewed_player() if game.has_method("viewed_player") else game.local_player()
		var sys = hud.system
		var table_at: Vector3 = sys._table_pos() if sys.has_method("_table_pos") else game.table_pos()
		if view == null or view.global_position.distance_to(table_at) > SPECTATE_RANGE:
			return
		var text := "%s is operating: %s  %d%%" % [String(st.get("operator_name", "Someone")),
			String(st.get("step_label", st.get("title", ""))), roundi(clampf(float(st.get("progress", 0.0)), 0.0, 1.0) * 100.0)]
		drawn.append("spectator")
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		# loop: one line per table being operated on, stacked.
		var slot: int = maxi(0, game.surgeries.find(sys)) if "surgeries" in game else 0
		var y := h - 196.0 - 26.0 * slot
		draw_rect(Rect2(w * 0.5 - tw * 0.5 - 10, y - 15, tw + 20, 21), Color(0, 0, 0, 0.45))
		draw_string(font, Vector2(0, y), text, HORIZONTAL_ALIGNMENT_CENTER, w, 12,
			Color("ff6a6a") if bool(st.get("stirring", false)) else Color("5ce0d0"))
