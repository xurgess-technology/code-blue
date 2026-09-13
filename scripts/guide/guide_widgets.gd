extends RefCounted
## The small hand-drawn pieces the binder is made of. Each is a plain Control that draws
## itself, so everything stays crisp under canvas_items stretch at any window size.

const Art := preload("res://scripts/guide/guide_art.gd")


## One sheet of paper. Content goes in as children; the paper is a shader underneath.
class Page extends Control:
	var paper: ColorRect
	var mat: ShaderMaterial

	func _init(seed_key: String, side: float, page_size: Vector2, torn := -1.0) -> void:
		size = page_size
		mouse_filter = Control.MOUSE_FILTER_PASS
		paper = ColorRect.new()
		paper.size = page_size
		paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mat = Art.paper_material(seed_key, side, torn)
		mat.set_shader_parameter("page_size", page_size)
		paper.material = mat
		add_child(paper)

	func set_ring(centre: Vector2, radius: float, strength: float) -> void:
		mat.set_shader_parameter("ring", Vector3(centre.x, centre.y, radius))
		mat.set_shader_parameter("ring_strength", strength)

	func set_shade(amount: float) -> void:
		mat.set_shader_parameter("shade", clampf(amount, 0.0, 0.9))

	func set_gutter_shade(amount: float) -> void:
		mat.set_shader_parameter("shade_gutter", clampf(amount, 0.0, 0.9))


## Freehand text: margin notes, scrawls, captions. Rotates about its centre.
class Scribble extends Control:
	var text := ""
	var font: Font
	var font_size := 22
	var colour := Art.BLUE_PEN
	var align := HORIZONTAL_ALIGNMENT_LEFT
	var underline := false

	var _lines: PackedStringArray = []
	var line_h := 0.0

	func _init(t: String, role := "hand", fsize := 22, col := Art.BLUE_PEN, width := 300.0, rot_deg := 0.0) -> void:
		text = t
		font = Art.font(role)
		font_size = fsize
		colour = col
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Handwriting fonts report a short line height; space lines by the size instead.
		line_h = maxf(font.get_height(font_size), font_size * (1.3 if role in ["hand", "marker"] else 1.12))
		_lines = _wrap(width)
		size = Vector2(width, line_h * _lines.size() + 4.0)
		pivot_offset = size * 0.5
		rotation_degrees = rot_deg

	func _wrap(width: float) -> PackedStringArray:
		var out: PackedStringArray = []
		for para in text.split("\n"):
			var line := ""
			for word in para.split(" "):
				var trial := word if line == "" else line + " " + word
				if line != "" and font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
					out.append(line)
					line = word
				else:
					line = trial
			out.append(line)
		return out

	func _draw() -> void:
		var asc := font.get_ascent(font_size)
		var y := asc + (line_h - font.get_height(font_size)) * 0.5
		for line in _lines:
			var x := 0.0
			if align != HORIZONTAL_ALIGNMENT_LEFT:
				var lw := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
				x = (size.x - lw) * (0.5 if align == HORIZONTAL_ALIGNMENT_CENTER else 1.0)
			draw_string(font, Vector2(x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
			y += line_h
		if underline:
			var w := minf(size.x, font.get_string_size(text, align, -1, font_size).x)
			var uy := size.y - 2.0
			draw_polyline(PackedVector2Array([Vector2(0, uy), Vector2(w * 0.45, uy + 2.5), Vector2(w, uy - 1.0)]), colour, 2.2, true)


## A rubber stamp: double border, red ink, slightly uneven.
class Stamp extends Control:
	var text := ""
	var colour := Art.RED_INK
	var fsize := 22

	func _init(t: String, col := Art.RED_INK, font_size := 22, rot_deg := -5.0) -> void:
		text = t
		colour = col
		fsize = font_size
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var w := Art.font("type_bold").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		size = Vector2(w + fsize * 1.3, fsize * 1.9)
		pivot_offset = size * 0.5
		rotation_degrees = rot_deg

	func _draw() -> void:
		var c := Color(colour, 0.78)
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, c, false, 3.0)
		draw_rect(r.grow(-5.0), Color(colour, 0.55), false, 1.5)
		var f := Art.font("type_bold")
		var ts := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
		draw_string(f, Vector2((size.x - ts.x) * 0.5, size.y * 0.5 + f.get_ascent(fsize) * 0.36), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, c)


## A strip of masking tape with torn ends.
class Tape extends Control:
	var colour := Art.TAPE

	func _init(length := 110.0, width := 30.0, rot_deg := 0.0) -> void:
		size = Vector2(length, width)
		pivot_offset = size * 0.5
		rotation_degrees = rot_deg
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var pts := PackedVector2Array()
		var steps := 6
		for i in steps + 1:
			pts.append(Vector2(((i % 2) * 4.0), size.y * i / steps))
		for i in steps + 1:
			pts.append(Vector2(size.x - ((i % 2) * 4.0), size.y * (steps - i) / steps))
		# Left edge goes top to bottom, right edge bottom to top: reorder into one loop.
		var loop := PackedVector2Array()
		loop.append_array(pts.slice(0, steps + 1))
		loop.append_array(pts.slice(steps + 1))
		draw_colored_polygon(loop, colour)
		draw_line(Vector2(6, size.y * 0.3), Vector2(size.x - 6, size.y * 0.26), Color(1, 1, 1, 0.18), size.y * 0.25)


## A yellow sticky note with a curled shadow.
class Sticky extends Control:
	var colour := Art.STICKY
	var lined := false

	func _init(note_size: Vector2, rot_deg := 2.0, col := Art.STICKY) -> void:
		size = note_size
		colour = col
		pivot_offset = size * 0.5
		rotation_degrees = rot_deg
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2(5, 8), size), Color(0, 0, 0, 0.22))
		draw_rect(Rect2(Vector2.ZERO, size), colour)
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, 26)), colour.darkened(0.06))
		if lined:
			var y := 62.0
			while y < size.y - 10.0:
				draw_line(Vector2(12, y), Vector2(size.x - 12, y), Color(0.35, 0.5, 0.75, 0.35), 1.2)
				y += 34.0
			draw_line(Vector2(44, 26), Vector2(44, size.y), Color(0.8, 0.25, 0.25, 0.35), 1.2)
		# curled corner
		var c := size
		draw_colored_polygon(PackedVector2Array([c - Vector2(34, 0), c, c - Vector2(0, 30)]), colour.darkened(0.18))


## A hand-drawn tick box.
class Checkbox extends Control:
	var colour := Art.INK

	func _init(side_px: float, col: Color) -> void:
		size = Vector2(side_px, side_px)
		colour = col
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s := size.x
		draw_polyline(PackedVector2Array([Vector2(1, 2), Vector2(s - 1, 0), Vector2(s, s - 1), Vector2(0, s), Vector2(1, 1)]),
			Color(colour, 0.85), 2.0, true)


## A thin double rule, like a typed underline across the page.
class Rule extends Control:
	var colour := Art.INK_SOFT

	func _init(width: float) -> void:
		custom_minimum_size = Vector2(width, 10)
		size = custom_minimum_size
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_line(Vector2(0, 3), Vector2(size.x, 3), Color(colour, 0.8), 2.0)
		draw_line(Vector2(0, 7), Vector2(size.x, 7), Color(colour, 0.5), 1.0)


## A contents line: "Anesthetic ........ 3". Clickable, highlighter on hover.
class LinkRow extends Control:
	signal chosen(page_id: String)
	var page_id := ""
	var label := ""
	var page_no := ""
	var key_hint := ""
	var colour := Art.INK
	var dot := Color.TRANSPARENT
	var struck := false
	var hover := false
	var fsize := 20

	func _init(id: String, text: String, number: String, width: float, chip: Color, key := "", greyed := false) -> void:
		page_id = id
		label = text
		page_no = number
		key_hint = key
		dot = chip
		struck = greyed
		colour = Art.PENCIL if greyed else Art.INK
		custom_minimum_size = Vector2(width, 32)
		size = custom_minimum_size
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func(): hover = true; queue_redraw())
		mouse_exited.connect(func(): hover = false; queue_redraw())

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit(page_id)
			accept_event()

	func _draw() -> void:
		var f := Art.font("serif")
		var tf := Art.font("type")
		var base := size.y * 0.5 + f.get_ascent(fsize) * 0.38
		var x := 0.0
		if key_hint != "":
			draw_string(tf, Vector2(0, base), key_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Art.INK_SOFT)
		x = 28.0
		if dot.a > 0.0:
			draw_rect(Rect2(x, size.y * 0.5 - 6, 12, 12), dot)
			draw_rect(Rect2(x, size.y * 0.5 - 6, 12, 12), Color(0, 0, 0, 0.35), false, 1.0)
		x = 50.0
		var lw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
		if hover:
			draw_rect(Rect2(x - 4, size.y * 0.5 - 9, lw + 8, 20), Art.HIGHLIGHT)
		draw_string(f, Vector2(x, base), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, colour)
		var nw := tf.get_string_size(page_no, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		var dots_from := x + lw + 8.0
		var dots_to := size.x - nw - 8.0
		var dx := dots_from
		while dx < dots_to:
			draw_circle(Vector2(dx, base - 2), 1.1, Color(colour, 0.55))
			dx += 7.0
		draw_string(tf, Vector2(size.x - nw, base), page_no, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, colour)
		if struck:
			var y := size.y * 0.5 + 1.0
			draw_polyline(PackedVector2Array([Vector2(x - 3, y + 1), Vector2(x + lw * 0.5, y - 1.5), Vector2(x + lw + 4, y + 0.5)]),
				Color(Art.PENCIL, 0.9), 1.6, true)


## An index tab sticking out of the book edge. `side` +1 sticks out to the right, -1 to the left.
class Tab extends Control:
	signal chosen(index: int)
	var index := 0
	var label := ""
	var key_hint := ""
	var colour := Color.WHITE
	var locked := false
	var side := 1.0
	var current := false
	var hover := false

	func _init(i: int, text: String, col: Color, key: String, is_locked: bool, tab_size: Vector2) -> void:
		index = i
		label = text
		colour = col
		key_hint = key
		locked = is_locked
		size = tab_size
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func(): hover = true; queue_redraw())
		mouse_exited.connect(func(): hover = false; queue_redraw())
		tooltip_text = ""

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit(index)
			accept_event()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var r := 7.0
		var body := colour
		if locked:
			body = colour
		elif not current:
			body = colour.darkened(0.12)
		# Tab outline: square where it tucks under the page, rounded where it sticks out.
		var pts := PackedVector2Array()
		var arc_steps := 5
		if side > 0.0:
			pts.append(Vector2(0, 0))
			for i in arc_steps + 1:
				var a := -PI * 0.5 + (PI * 0.5) * i / arc_steps
				pts.append(Vector2(w - r, r) + Vector2(cos(a), sin(a)) * r)
			for i in arc_steps + 1:
				var a := (PI * 0.5) * i / arc_steps
				pts.append(Vector2(w - r, h - r) + Vector2(cos(a), sin(a)) * r)
			pts.append(Vector2(0, h))
		else:
			pts.append(Vector2(w, h))
			for i in arc_steps + 1:
				var a := PI * 0.5 + (PI * 0.5) * i / arc_steps
				pts.append(Vector2(r, h - r) + Vector2(cos(a), sin(a)) * r)
			for i in arc_steps + 1:
				var a := PI + (PI * 0.5) * i / arc_steps
				pts.append(Vector2(r, r) + Vector2(cos(a), sin(a)) * r)
			pts.append(Vector2(w, 0))
		var shadow := PackedVector2Array()
		for p in pts:
			shadow.append(p + Vector2(2, 3))
		draw_colored_polygon(shadow, Color(0, 0, 0, 0.35))
		draw_colored_polygon(pts, body)
		draw_line(Vector2(6, 4), Vector2(w - 6, 4), Color(1, 1, 1, 0.22), 2.0)
		var outline := pts.duplicate()
		outline.append(pts[0])
		draw_polyline(outline, body.darkened(0.35), 1.2, true)
		# Paper label insert on the tab. The first TUCK px sit under the page.
		var f := Art.font("serif_bold")
		var fs := 16
		var text_col := Art.INK if not locked else Color(0.36, 0.34, 0.31)
		var lum := body.get_luminance()
		var label_rect: Rect2
		var tuck := 12.0 + 14.0
		var inset := tuck + 18.0
		if side > 0.0:
			label_rect = Rect2(inset, 6, w - inset - 7, h - 12)
		else:
			label_rect = Rect2(7, 6, w - inset - 7, h - 12)
		draw_rect(label_rect, Color(0.97, 0.94, 0.85, 0.9 if not locked else 0.55))
		var fit := label
		while fs > 13 and f.get_string_size(fit, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > label_rect.size.x - 6:
			fs -= 1
		# Too long even small: drop trailing words first ("Gunshot wound" -> "Gunshot").
		while fit.contains(" ") and f.get_string_size(fit, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > label_rect.size.x - 6:
			fit = fit.substr(0, fit.rfind(" "))
		if f.get_string_size(fit, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > label_rect.size.x - 6:
			while f.get_string_size(fit + ".", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > label_rect.size.x - 6 and fit.length() > 3:
				fit = fit.substr(0, fit.length() - 1)
			fit = fit.strip_edges() + "."
		var tw := f.get_string_size(fit, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var base := label_rect.position.y + label_rect.size.y * 0.5 + f.get_ascent(fs) * 0.36
		draw_string(f, Vector2(label_rect.position.x + (label_rect.size.x - tw) * 0.5, base), fit,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, text_col)
		if key_hint != "":
			var kx := tuck + 3.0 if side > 0.0 else w - tuck - 13.0
			draw_string(Art.font("type_bold"), Vector2(kx, base), key_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(1, 1, 1, 0.9) if lum < 0.62 else Color(0.1, 0.08, 0.06, 0.85))


## The binder itself behind the pages: the board, the stacked page edges and a shadow.
class Board extends Control:
	var left_rect: Rect2
	var right_rect: Rect2

	func _init(board_size: Vector2, l: Rect2, r: Rect2) -> void:
		size = board_size
		left_rect = l
		right_rect = r
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var cr := ColorRect.new()
		cr.size = board_size
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = Art.shader("board")
		m.set_shader_parameter("board_size", board_size)
		var inner := Rect2(l.position - Vector2(6, 6), Vector2(r.end.x - l.position.x + 12, l.size.y + 12))
		m.set_shader_parameter("inner_rect", Vector4(inner.position.x, inner.position.y, inner.size.x, inner.size.y))
		cr.material = m
		add_child(cr)
		show_behind_parent = false

	func _draw() -> void:
		# Drop shadow under the whole book
		for i in 6:
			var g := 4.0 + i * 6.0
			draw_rect(Rect2(Vector2(-g * 0.5, g), size + Vector2(g, g * 0.3)), Color(0, 0, 0, 0.07))


## Page edges peeking out below each page, drawn between the board and the pages.
class Edges extends Control:
	var rects: Array[Rect2] = []

	func _init(area: Vector2, l: Rect2, r: Rect2) -> void:
		size = area
		rects = [l, r]
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		for n in rects.size():
			var rc: Rect2 = rects[n]
			var outward := -1.0 if n == 0 else 1.0
			# Only the slivers that peek out past the top sheet, so a torn page shows the board.
			for i in range(4, 0, -1):
				var ox := outward * i * 1.6
				var oy := i * 2.2
				var shade := Color(0.86, 0.8, 0.66).darkened(0.08 * i)
				var side_x := rc.end.x if outward > 0.0 else rc.position.x + ox
				draw_rect(Rect2(side_x, rc.position.y + oy, absf(ox), rc.size.y), shade)
				draw_rect(Rect2(rc.position.x + ox, rc.end.y, rc.size.x, oy), shade)
				draw_line(Vector2(rc.position.x + ox, rc.end.y + oy), Vector2(rc.end.x + ox, rc.end.y + oy), Color(0, 0, 0, 0.15), 1.0)


## Three binder rings over the spine.
class Rings extends Control:
	var spine_x := 0.0
	var top := 0.0
	var height := 0.0

	func _init(area: Vector2, x: float, y0: float, h: float) -> void:
		size = area
		spine_x = x
		top = y0
		height = h
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		for i in 3:
			var y := top + height * (0.18 + 0.32 * i)
			var c := Vector2(spine_x, y)
			draw_rect(Rect2(c.x - 30, c.y - 9, 60, 22), Color(0, 0, 0, 0.25))
			draw_arc(c + Vector2(0, 3), 26.0, PI * 1.05, TAU * 0.975, 24, Color(0, 0, 0, 0.35), 8.0, true)
			draw_arc(c, 26.0, PI * 1.05, TAU * 0.975, 24, Color("8c9196"), 7.0, true)
			draw_arc(c, 26.0, PI * 1.25, PI * 1.6, 12, Color("e3e8ec"), 2.5, true)
			draw_circle(c + Vector2(-25, 3), 5.0, Color("6f7479"))
			draw_circle(c + Vector2(25, 3), 5.0, Color("6f7479"))


## The instant-print photo frame the live model render sits in.
class Photo extends Control:
	var tex_rect: TextureRect

	func _init(photo_size: Vector2, rot_deg := -1.6) -> void:
		size = photo_size
		pivot_offset = size * 0.5
		rotation_degrees = rot_deg
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex_rect = TextureRect.new()
		tex_rect.position = Vector2(14, 14)
		tex_rect.size = size - Vector2(28, 28)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(tex_rect)

	func _draw() -> void:
		draw_rect(Rect2(Vector2(4, 7), size), Color(0, 0, 0, 0.28))
		draw_rect(Rect2(Vector2.ZERO, size), Color("f4f1ea"))
		draw_rect(Rect2(Vector2(13, 13), size - Vector2(26, 26)), Color(0.1, 0.08, 0.07))
