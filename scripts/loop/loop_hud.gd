extends CanvasLayer
## Phone call subtitles (loop, sweep 2): the line being spoken, bottom centre, above the game's
## short messages; at the top while operating so the surgery panel stays clear. Everyone sees them
## (the phone is loud and dispatch repeats nothing).

var loop: Node = null
var _canvas: Control


func _ready() -> void:
	layer = 4
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

	func _draw() -> void:
		if hud == null or hud.loop == null or hud.loop.game == null:
			return
		var loop = hud.loop
		var game = loop.game
		if game.phase == game.Phase.MENU or String(loop.subtitle) == "":
			return
		var font := ThemeDB.fallback_font
		var w := size.x
		var h := size.y
		var text := String(loop.subtitle)
		var speaker := ""
		var colon := text.find(": ")
		if colon > 0 and colon < 24:
			speaker = text.substr(0, colon)
			text = text.substr(colon + 2)
		var size_px := 20
		var in_surgery: bool = game.surgery != null and game.surgery.camera() != null
		var max_w := minf(900.0, w - 60.0)
		var lines := _wrap(font, text, size_px, max_w)
		var line_h := 26.0
		var box_h := 18.0 + line_h * lines.size() + (20.0 if speaker != "" else 0.0)
		var y0 := 118.0 if in_surgery else h - 200.0 - box_h
		var widest := 0.0
		for l in lines:
			widest = maxf(widest, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x)
		var bw := maxf(widest, 200.0) + 36.0
		draw_rect(Rect2(w * 0.5 - bw * 0.5, y0, bw, box_h), Color(0, 0, 0, 0.72))
		var y := y0 + 8.0
		if speaker != "":
			draw_string(font, Vector2(0, y + 13), speaker, HORIZONTAL_ALIGNMENT_CENTER, w, 13, Color("e0a020"))
			y += 20.0
		for l in lines:
			draw_string(font, Vector2(0, y + 20), l, HORIZONTAL_ALIGNMENT_CENTER, w, size_px, Color("f4efe0"))
			y += line_h

	func _wrap(font: Font, text: String, size_px: int, max_w: float) -> Array:
		var out := []
		var cur := ""
		for word in text.split(" "):
			var trial := word if cur == "" else cur + " " + word
			if font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x > max_w and cur != "":
				out.append(cur)
				cur = word
			else:
				cur = trial
		if cur != "":
			out.append(cur)
		return out
