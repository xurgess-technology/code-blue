extends CanvasLayer
## The surgery view's overlay, created by the surgery system. Same look as scripts/hud.gd:
## the fallback font, dark translucent panels, red / green / amber.
##
## Local operator: step title, hint, progress bar and the minigame's gauges at the bottom.
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

	func _process(delta: float) -> void:
		_t += delta

	func _draw() -> void:
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

	func _draw_operator(font: Font, w: float, h: float, st: Dictionary, game) -> void:
		var gauges: Array = st.get("gauges", [])
		var xs: Dictionary = st.get("cross_section", {})
		var pw := minf(640.0, w - 40.0)
		var ph := 96.0 + gauges.size() * 24.0 + (24.0 if not xs.is_empty() else 0.0)
		var x := w * 0.5 - pw * 0.5
		var y := h - ph - 18.0
		draw_rect(Rect2(x, y, pw, ph), Color(0, 0, 0, 0.62))
		draw_rect(Rect2(x, y, 4, ph), Color("5ce0d0"))
		var idx := int(game.case.get("step_index", 0)) + 1
		var total := Procedures.steps(String(game.case.get("ailment_id", ""))).size()
		draw_string(font, Vector2(x + 16, y + 22), "STEP %d/%d: %s" % [idx, total, String(st.get("title", "")).to_upper()],
			HORIZONTAL_ALIGNMENT_LEFT, pw - 32, 15, Color("f0e6c8"))
		draw_string(font, Vector2(x + pw - 16 - 150, y + 22), "ESC / E: step away", HORIZONTAL_ALIGNMENT_RIGHT, 150, 11, Color("777777"))
		var hint := String(st.get("hint", ""))
		var hint_col := Color("c9d1d9")
		if bool(st.get("stirring", false)):
			hint = "The patient is stirring! " + hint
			hint_col = Color(1, 0.42, 0.42, 0.75 + 0.25 * sin(_t * 14.0))
		draw_string(font, Vector2(x + 16, y + 44), hint, HORIZONTAL_ALIGNMENT_LEFT, pw - 32, 13, hint_col)
		# Progress
		var bx := x + 16
		var bw := pw - 32
		var by := y + 56
		var pr := clampf(float(st.get("progress", 0.0)), 0.0, 1.0)
		draw_rect(Rect2(bx, by, bw, 10), Color("2a2f36"))
		draw_rect(Rect2(bx, by, bw * pr, 10), Color("5cff8a"))
		draw_string(font, Vector2(bx, by + 26), "PROGRESS %d%%" % roundi(pr * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aaaaaa"))
		var v: float = maxf(0.0, float(game.get("vitals")))
		var vcol := Color("5cff8a") if v > 50.0 else (Color("ffd35c") if v > 25.0 else Color("ff2a2a"))
		draw_string(font, Vector2(bx, by + 26), "VITALS %d%%" % ceili(v), HORIZONTAL_ALIGNMENT_RIGHT, bw, 12, vcol)
		# Gauges
		var gy := by + 36
		for g in gauges:
			_gauge(font, bx, gy, bw, g)
			gy += 24.0
		if not xs.is_empty():
			_cross_section(font, bx, gy, bw, xs)

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

	func _gauge(font: Font, x: float, y: float, bw: float, g: Dictionary) -> void:
		var label := String(g.get("label", ""))
		var lo := float(g.get("min", 0.0))
		var hi := float(g.get("max", 1.0))
		var span := maxf(1e-5, hi - lo)
		var value := float(g.get("value", 0.0))
		var gmin := float(g.get("good_min", lo))
		var gmax := float(g.get("good_max", hi))
		var lw := 120.0
		draw_string(font, Vector2(x, y + 14), label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, lw - 8, 12, Color("c9d1d9"))
		var bx := x + lw
		var w := bw - lw - 56.0
		draw_rect(Rect2(bx, y + 4, w, 12), Color("2a2f36"))
		var full_good := gmin <= lo + 1e-4 and gmax >= hi - 1e-4
		var good := value >= gmin and value <= gmax
		if full_good:
			# A plain meter (progress-like): fill it.
			draw_rect(Rect2(bx, y + 4, w * clampf((value - lo) / span, 0.0, 1.0), 12), Color("7ad0c0"))
		else:
			var z0 := clampf((gmin - lo) / span, 0.0, 1.0)
			var z1 := clampf((gmax - lo) / span, 0.0, 1.0)
			draw_rect(Rect2(bx + w * z0, y + 4, w * (z1 - z0), 12), Color(0.36, 1.0, 0.54, 0.4))
			var mx := bx + w * clampf((value - lo) / span, 0.0, 1.0)
			var col := Color("ffffff") if good else (Color("ffd35c") if value < gmin else Color("ff6a6a"))
			draw_rect(Rect2(mx - 2, y + 1, 4, 18), col)
		var unit := absf(lo) < 1e-4 and absf(hi - 1.0) < 1e-4
		var num := "%d%%" % roundi(value * 100.0) if unit else ("%.2f" % value if span <= 3.0 else "%.1f" % value)
		draw_string(font, Vector2(bx + w + 8, y + 15), num, HORIZONTAL_ALIGNMENT_LEFT, 48, 12,
			Color("eeeeee") if good or full_good else Color("ffd35c"))

	func _draw_spectator(font: Font, w: float, h: float, st: Dictionary, game) -> void:
		var view = game.viewed_player() if game.has_method("viewed_player") else game.local_player()
		if view == null or view.global_position.distance_to(game.table_pos()) > SPECTATE_RANGE:
			return
		var text := "%s is operating: %s  %d%%" % [String(st.get("operator_name", "Someone")),
			String(st.get("step_label", st.get("title", ""))), roundi(clampf(float(st.get("progress", 0.0)), 0.0, 1.0) * 100.0)]
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var y := h - 196.0
		draw_rect(Rect2(w * 0.5 - tw * 0.5 - 12, y - 17, tw + 24, 24), Color(0, 0, 0, 0.55))
		draw_string(font, Vector2(0, y), text, HORIZONTAL_ALIGNMENT_CENTER, w, 13,
			Color("ff6a6a") if bool(st.get("stirring", false)) else Color("5ce0d0"))
