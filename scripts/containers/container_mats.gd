extends RefCounted
## Shared materials for container visuals, created once and reused by every instance.

static var _cache := {}


static func get_mat(key: String) -> Material:
	if _cache.has(key):
		return _cache[key]
	var m := _make(key)
	_cache[key] = m
	return m


static func _std(col: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _make(key: String) -> Material:
	match key:
		"enamel": return _std(Color(0.80, 0.83, 0.82), 0.38, 0.05)
		"enamel_dark": return _std(Color(0.22, 0.24, 0.25), 0.6)
		"liner": return _std(Color(0.42, 0.52, 0.55), 0.45)
		"grille": return _std(Color(0.08, 0.09, 0.09), 0.7, 0.3)
		"steel": return _std(Color(0.47, 0.53, 0.56), 0.42, 0.65)
		"steel_dark": return _std(Color(0.30, 0.34, 0.36), 0.5, 0.6)
		"chrome": return _std(Color(0.85, 0.87, 0.9), 0.18, 1.0)
		"cavity": return _std(Color(0.035, 0.04, 0.04), 0.95)
		"tray": return _std(Color(0.62, 0.66, 0.68), 0.3, 0.8)
		"label":
			var m := _std(Color(0.93, 0.92, 0.84), 0.9)
			return m
		"laminate": return _std(Color(0.42, 0.55, 0.58), 0.55)
		"laminate_dark": return _std(Color(0.2, 0.26, 0.28), 0.6)
		"counter_top": return _std(Color(0.86, 0.85, 0.80), 0.35)
		"rubber": return _std(Color(0.06, 0.06, 0.06), 0.9)
		"bag_red": return _std(Color(0.70, 0.07, 0.05), 0.82)
		"bag_red_dark": return _std(Color(0.38, 0.03, 0.02), 0.9)
		"bag_lining": return _std(Color(0.62, 0.64, 0.6), 0.9)
		"reflective":
			var r := _std(Color(0.85, 0.87, 0.8), 0.3, 0.2)
			r.emission_enabled = true
			r.emission = Color(0.6, 0.62, 0.55)
			r.emission_energy_multiplier = 0.15
			return r
		"white_cross": return _std(Color(0.95, 0.95, 0.93), 0.6)
		"board": return _board()
		"board_edge": return _std(Color(0.34, 0.25, 0.16), 0.8)
		"outline": return _std(Color(0.55, 0.12, 0.08), 0.9)
		"glass":
			var g := _std(Color(0.55, 0.8, 0.85, 0.16), 0.04, 0.1)
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			g.rim_enabled = true
			g.rim = 0.35
			g.rim_tint = 0.3
			g.cull_mode = BaseMaterial3D.CULL_DISABLED
			return g
		"shelf_glass":
			var s := _std(Color(0.7, 0.9, 0.95, 0.35), 0.1)
			s.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			return s
		"fridge_light":
			var e := _std(Color(0.9, 0.97, 1.0), 0.3)
			e.emission_enabled = true
			e.emission = Color(0.75, 0.93, 1.0)
			e.emission_energy_multiplier = 1.2
			return e
		"screen":
			var sc := _std(Color(0.03, 0.08, 0.08), 0.2)
			sc.emission_enabled = true
			sc.emission = Color(0.25, 0.75, 0.65)
			sc.emission_energy_multiplier = 0.4
			return sc
		"led_green":
			var l := _std(Color(0.1, 0.5, 0.2), 0.3)
			l.emission_enabled = true
			l.emission = Color(0.3, 1.0, 0.45)
			l.emission_energy_multiplier = 2.5
			return l
	return _std(Color.MAGENTA, 0.5)


## Hardboard with a grid of dark holes, drawn on the CPU so it works headless.
static func _board() -> StandardMaterial3D:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var base := Color(0.62, 0.47, 0.31)
	img.fill(base)
	var cell := 16
	for cy in range(0, size, cell):
		for cx in range(0, size, cell):
			var ox := cx + cell / 2
			var oy := cy + cell / 2
			for y in range(-3, 4):
				for x in range(-3, 4):
					var d := sqrt(float(x * x + y * y))
					if d <= 2.6:
						img.set_pixel(ox + x, oy + y, Color(0.08, 0.06, 0.04))
					elif d <= 3.4:
						img.set_pixel(ox + x, oy + y, base.darkened(0.25))
	var tex := ImageTexture.create_from_image(img)
	var m := _std(Color.WHITE, 0.88)
	m.albedo_texture = tex
	# One 64px tile = 4 holes = 10 cm, like real 25 mm pegboard.
	m.uv1_scale = Vector3(13.0, 9.5, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m
