extends RefCounted
## Primitive models for the sellable loot in loot_table.gd. Same rules as ItemModels: origin at
## the base, no collision, a stack of N shows N. Materials are cached and shared, so a hospital
## full of loot compiles a handful of materials, not one per item.
##
## ItemModels.make() calls build() for loot kinds (after checking Assets for `item/<kind>`).

static var _mats := {}


static func build(root: Node3D, kind: String, count: int) -> void:
	match kind:
		"stethoscope": _stethoscope(root)
		"pulse_oximeter": _pulse_oximeter(root)
		"bp_cuff": _bp_cuff(root)
		"thermometer": _thermometer(root)
		"reflex_hammer": _reflex_hammer(root)
		"pill_bottle": _pill_bottles(root, clampi(count, 1, 6))
		"xray_film": _xray_film(root)
		"patient_records": _records(root)
		"desk_phone": _desk_phone(root)
		"wheelchair_wheel": _wheel(root)
		"sample_rack": _sample_rack(root)
		"otoscope": _otoscope(root)
		"laptop": _laptop(root)
		"gold_watch": _watch(root)
		"wedding_ring": _ring_box(root)
		"coffee_maker": _coffee_maker(root)
		"heart_monitor": _heart_monitor(root)
		"iv_pump": _iv_pump(root)
		"defibrillator": _defibrillator(root)
		"microscope": _microscope(root)
		"ultrasound": _ultrasound(root)
		_: _add(root, _box(Vector3(0.15, 0.1, 0.15), _m("magenta", Color.MAGENTA)), Vector3(0, 0.05, 0))


## Rough footprint (x, height, z) so the pickup box and shelves can size themselves.
static func footprint(kind: String) -> Vector3:
	match kind:
		"stethoscope": return Vector3(0.2, 0.04, 0.2)
		"pulse_oximeter": return Vector3(0.07, 0.05, 0.05)
		"bp_cuff": return Vector3(0.24, 0.06, 0.14)
		"thermometer": return Vector3(0.16, 0.04, 0.05)
		"reflex_hammer": return Vector3(0.22, 0.04, 0.07)
		"pill_bottle": return Vector3(0.12, 0.08, 0.06)
		"xray_film": return Vector3(0.3, 0.02, 0.25)
		"patient_records": return Vector3(0.24, 0.04, 0.31)
		"desk_phone": return Vector3(0.2, 0.09, 0.2)
		"wheelchair_wheel": return Vector3(0.58, 0.06, 0.58)
		"sample_rack": return Vector3(0.22, 0.1, 0.08)
		"otoscope": return Vector3(0.18, 0.05, 0.06)
		"laptop": return Vector3(0.34, 0.24, 0.24)
		"gold_watch": return Vector3(0.08, 0.03, 0.1)
		"wedding_ring": return Vector3(0.06, 0.06, 0.06)
		"coffee_maker": return Vector3(0.24, 0.34, 0.26)
		"heart_monitor": return Vector3(0.38, 0.34, 0.2)
		"iv_pump": return Vector3(0.2, 0.32, 0.18)
		"defibrillator": return Vector3(0.36, 0.2, 0.28)
		"microscope": return Vector3(0.24, 0.4, 0.3)
		"ultrasound": return Vector3(0.42, 0.34, 0.32)
	return Vector3(0.15, 0.1, 0.15)


# ---------------------------------------------------------------------------
# materials and shapes

static func _m(key: String, col: Color, rough := 0.6, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "loot_" + key
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	_mats[key] = m
	return m


static func _glass(key: String, col: Color) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := _m(key, col, 0.1)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.5
	return m


static func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	return mi


static func _cyl(r: float, h: float, mat: Material, sides := 12, r_top := -1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r if r_top < 0.0 else r_top
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	c.rings = 1
	mi.mesh = c
	mi.material_override = mat
	return mi


static func _torus(r_in: float, r_out: float, mat: Material, rings := 20, sides := 6) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = r_in
	t.outer_radius = r_out
	t.rings = rings
	t.ring_segments = sides
	mi.mesh = t
	mi.material_override = mat
	return mi


static func _sphere(r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 12
	s.rings = 6
	mi.mesh = s
	mi.material_override = mat
	return mi


static func _add(root: Node3D, n: Node3D, pos: Vector3, rot_deg := Vector3.ZERO) -> Node3D:
	n.position = pos
	n.rotation_degrees = rot_deg
	root.add_child(n)
	return n


static func _steel() -> StandardMaterial3D:
	return _m("steel", Color(0.78, 0.8, 0.83), 0.3, 0.6)


static func _black_plastic() -> StandardMaterial3D:
	return _m("black_plastic", Color(0.08, 0.08, 0.09), 0.55)


static func _grey_plastic() -> StandardMaterial3D:
	return _m("grey_plastic", Color(0.72, 0.73, 0.72), 0.6)


static func _screen(key: String, col: Color) -> StandardMaterial3D:
	return _m("screen_" + key, Color(0.02, 0.03, 0.03), 0.3, 0.0, col, 1.6)


static func _gold() -> StandardMaterial3D:
	return _m("gold", Color(1.0, 0.76, 0.3), 0.22, 1.0)


# ---------------------------------------------------------------------------
# small loot

static func _stethoscope(root: Node3D) -> void:
	var tube := _m("rubber_dark", Color(0.12, 0.13, 0.15), 0.7)
	_add(root, _torus(0.06, 0.075, tube, 24, 6), Vector3(0, 0.008, 0))
	_add(root, _cyl(0.024, 0.014, _steel(), 16), Vector3(0.09, 0.007, 0.02))
	_add(root, _cyl(0.02, 0.004, _m("diaphragm", Color(0.9, 0.9, 0.88), 0.5), 16), Vector3(0.09, 0.016, 0.02))
	for s in [-1.0, 1.0]:
		_add(root, _cyl(0.003, 0.11, _steel(), 6), Vector3(-0.06, 0.012, s * 0.018), Vector3(0, s * 12.0, 90))
		_add(root, _sphere(0.007, _black_plastic()), Vector3(-0.115, 0.012, s * 0.03))


static func _pulse_oximeter(root: Node3D) -> void:
	var body := _m("oxi_blue", Color(0.25, 0.42, 0.62), 0.5)
	_add(root, _box(Vector3(0.065, 0.022, 0.042), body), Vector3(0, 0.011, 0))
	_add(root, _box(Vector3(0.06, 0.018, 0.04), _grey_plastic()), Vector3(0, 0.031, 0), Vector3(0, 0, -6))
	_add(root, _box(Vector3(0.03, 0.002, 0.018), _screen("red", Color(1.0, 0.25, 0.2))), Vector3(0.004, 0.041, 0), Vector3(0, 0, -6))


static func _bp_cuff(root: Node3D) -> void:
	var cuff := _m("cuff_navy", Color(0.12, 0.17, 0.3), 0.9)
	_add(root, _box(Vector3(0.2, 0.025, 0.12), cuff), Vector3(0, 0.0125, 0))
	_add(root, _box(Vector3(0.05, 0.028, 0.121), _m("velcro", Color(0.2, 0.22, 0.25), 1.0)), Vector3(-0.07, 0.014, 0))
	_add(root, _torus(0.035, 0.042, _black_plastic(), 16, 5), Vector3(0.05, 0.03, 0.03), Vector3(90, 0, 20))
	_add(root, _sphere(0.022, _black_plastic()), Vector3(0.1, 0.022, -0.035))
	_add(root, _cyl(0.024, 0.012, _m("gauge_face", Color(0.95, 0.95, 0.92), 0.4), 16), Vector3(-0.02, 0.03, 0.03))


static func _thermometer(root: Node3D) -> void:
	var white := _m("white_plastic", Color(0.93, 0.93, 0.9), 0.45)
	_add(root, _box(Vector3(0.12, 0.028, 0.038), white), Vector3(-0.01, 0.014, 0))
	_add(root, _cyl(0.012, 0.045, white, 10, 0.006), Vector3(0.07, 0.014, 0), Vector3(0, 0, -90))
	_add(root, _box(Vector3(0.035, 0.002, 0.022), _screen("lcd", Color(0.55, 0.9, 0.7))), Vector3(-0.025, 0.029, 0))


static func _reflex_hammer(root: Node3D) -> void:
	_add(root, _cyl(0.005, 0.18, _steel(), 8), Vector3(-0.02, 0.012, 0), Vector3(0, 0, 90))
	var head := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.05, 0.06, 0.022)
	head.mesh = prism
	head.material_override = _m("rubber_orange", Color(0.9, 0.35, 0.12), 0.7)
	_add(root, head, Vector3(0.08, 0.012, 0), Vector3(90, 0, 0))


static func _pill_bottles(root: Node3D, n: int) -> void:
	var amber := _glass("amber", Color(0.95, 0.5, 0.12))
	var cap := _m("white_plastic", Color(0.93, 0.93, 0.9), 0.45)
	var label := _m("label_paper", Color(0.96, 0.95, 0.9), 0.9)
	var pills := _m("pills", Color(0.95, 0.92, 0.85), 0.8)
	for i in n:
		var b := Node3D.new()
		_add(b, _cyl(0.021, 0.07, amber, 12), Vector3(0, 0.035, 0))
		_add(b, _cyl(0.017, 0.04, pills, 8), Vector3(0, 0.022, 0))
		_add(b, _cyl(0.0215, 0.03, label, 12), Vector3(0, 0.036, 0))
		_add(b, _cyl(0.023, 0.014, cap, 12), Vector3(0, 0.077, 0))
		var x := (i % 3 - 1) * 0.05
		var z := 0.0 if i < 3 else 0.048
		_add(root, b, Vector3(x, 0, z), Vector3(0, i * 41.0, 0))


static func _xray_film(root: Node3D) -> void:
	var film := _m("xray_film", Color(0.08, 0.12, 0.18), 0.25, 0.0, Color(0.15, 0.25, 0.35), 0.3)
	var bone := _m("xray_bone", Color(0.5, 0.6, 0.66), 0.3, 0.0, Color(0.45, 0.6, 0.7), 0.7)
	_add(root, _box(Vector3(0.28, 0.003, 0.23), film), Vector3(0, 0.0015, 0))
	# A rib cage: a spine and a few curved-looking ribs as thin bars.
	_add(root, _box(Vector3(0.018, 0.001, 0.19), bone), Vector3(0, 0.0035, 0))
	for i in 5:
		for s in [-1.0, 1.0]:
			_add(root, _box(Vector3(0.09, 0.001, 0.008), bone), Vector3(s * 0.05, 0.0035, -0.07 + i * 0.035), Vector3(0, s * (14.0 + i * 3.0), 0))


static func _records(root: Node3D) -> void:
	var manila := _m("manila", Color(0.82, 0.68, 0.42), 0.9)
	var paper := _m("label_paper", Color(0.96, 0.95, 0.9), 0.9)
	_add(root, _box(Vector3(0.22, 0.012, 0.3), paper), Vector3(0.004, 0.012, 0.0))
	_add(root, _box(Vector3(0.23, 0.006, 0.31), manila), Vector3(0, 0.003, 0))
	_add(root, _box(Vector3(0.23, 0.006, 0.31), manila), Vector3(-0.003, 0.021, 0.004), Vector3(0, 2.0, 0))
	_add(root, _box(Vector3(0.07, 0.007, 0.02), _m("tab_red", Color(0.7, 0.15, 0.12), 0.7)), Vector3(-0.06, 0.022, -0.16))


static func _desk_phone(root: Node3D) -> void:
	var body := _m("phone_grey", Color(0.18, 0.19, 0.2), 0.5)
	_add(root, _box(Vector3(0.18, 0.05, 0.2), body), Vector3(0, 0.025, 0), Vector3(-8, 0, 0))
	_add(root, _box(Vector3(0.05, 0.028, 0.19), _black_plastic()), Vector3(-0.055, 0.064, 0), Vector3(-8, 0, 0))
	for s in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.056, 0.022, 0.045), _black_plastic()), Vector3(-0.055, 0.075, s * 0.075), Vector3(-8, 0, 0))
	_add(root, _box(Vector3(0.07, 0.004, 0.1), _m("keypad", Color(0.75, 0.76, 0.74), 0.5)), Vector3(0.04, 0.056, 0.01), Vector3(-8, 0, 0))
	_add(root, _box(Vector3(0.05, 0.003, 0.025), _screen("amber", Color(1.0, 0.65, 0.2))), Vector3(0.04, 0.056, -0.065), Vector3(-8, 0, 0))


static func _wheel(root: Node3D) -> void:
	_add(root, _torus(0.24, 0.29, _m("tyre", Color(0.06, 0.06, 0.06), 0.9), 28, 6), Vector3(0, 0.025, 0))
	_add(root, _torus(0.215, 0.235, _steel(), 28, 4), Vector3(0, 0.025, 0))
	_add(root, _torus(0.25, 0.26, _steel(), 28, 4), Vector3(0, 0.05, 0))
	for i in 6:
		_add(root, _cyl(0.003, 0.45, _steel(), 4), Vector3(0, 0.025, 0), Vector3(0, i * 30.0, 90))
	_add(root, _cyl(0.03, 0.05, _black_plastic(), 12), Vector3(0, 0.025, 0))


static func _sample_rack(root: Node3D) -> void:
	var rack := _m("rack_white", Color(0.9, 0.9, 0.88), 0.5)
	_add(root, _box(Vector3(0.2, 0.012, 0.07), rack), Vector3(0, 0.006, 0))
	_add(root, _box(Vector3(0.2, 0.01, 0.07), rack), Vector3(0, 0.05, 0))
	for s in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.008, 0.05, 0.07), rack), Vector3(s * 0.096, 0.028, 0))
	var glass := _glass("tube_glass", Color(0.85, 0.9, 0.95))
	var blood := _m("blood", Color(0.45, 0.02, 0.03), 0.25)
	for i in 6:
		var x := -0.075 + i * 0.03
		_add(root, _cyl(0.007, 0.08, glass, 8), Vector3(x, 0.045, 0))
		_add(root, _cyl(0.006, 0.05, blood, 8), Vector3(x, 0.03, 0))
		_add(root, _cyl(0.008, 0.012, _m("cap_%d" % (i % 3), [Color(0.7, 0.1, 0.1), Color(0.2, 0.4, 0.8), Color(0.3, 0.6, 0.25)][i % 3], 0.5), 8), Vector3(x, 0.09, 0))


static func _otoscope(root: Node3D) -> void:
	_add(root, _cyl(0.014, 0.11, _black_plastic(), 10), Vector3(-0.03, 0.014, 0), Vector3(0, 0, 90))
	_add(root, _cyl(0.02, 0.03, _steel(), 12), Vector3(0.035, 0.02, 0), Vector3(0, 0, 90))
	_add(root, _cyl(0.014, 0.05, _m("speculum", Color(0.2, 0.2, 0.22), 0.4), 10, 0.004), Vector3(0.075, 0.02, 0), Vector3(0, 0, -90))


static func _laptop(root: Node3D) -> void:
	var shell := _m("laptop_shell", Color(0.24, 0.25, 0.27), 0.35, 0.5)
	_add(root, _box(Vector3(0.33, 0.018, 0.23), shell), Vector3(0, 0.009, 0))
	_add(root, _box(Vector3(0.29, 0.002, 0.1), _black_plastic()), Vector3(0, 0.019, 0.02))
	var lid := Node3D.new()
	_add(root, lid, Vector3(0, 0.018, -0.114), Vector3(-105, 0, 0))
	_add(lid, _box(Vector3(0.33, 0.012, 0.23), shell), Vector3(0, -0.006, 0.115))
	_add(lid, _box(Vector3(0.29, 0.002, 0.19), _screen("laptop", Color(0.25, 0.45, 0.8))), Vector3(0, 0.001, 0.115))


static func _watch(root: Node3D) -> void:
	var strap := _m("leather", Color(0.28, 0.16, 0.08), 0.8)
	_add(root, _box(Vector3(0.022, 0.004, 0.1), strap), Vector3(0, 0.002, 0))
	_add(root, _cyl(0.02, 0.01, _gold(), 18), Vector3(0, 0.008, 0))
	_add(root, _cyl(0.016, 0.002, _m("watch_face", Color(0.95, 0.93, 0.85), 0.3), 18), Vector3(0, 0.0135, 0))
	_add(root, _box(Vector3(0.002, 0.001, 0.012), _black_plastic()), Vector3(0, 0.015, -0.004))


static func _ring_box(root: Node3D) -> void:
	var velvet := _m("velvet", Color(0.35, 0.04, 0.08), 1.0)
	_add(root, _box(Vector3(0.05, 0.03, 0.05), velvet), Vector3(0, 0.015, 0))
	var lid := Node3D.new()
	_add(root, lid, Vector3(0, 0.03, -0.025), Vector3(-100, 0, 0))
	_add(lid, _box(Vector3(0.05, 0.016, 0.05), velvet), Vector3(0, -0.008, 0.025))
	_add(root, _torus(0.009, 0.013, _gold(), 16, 6), Vector3(0, 0.041, 0), Vector3(90, 0, 0))
	_add(root, _sphere(0.004, _m("diamond", Color(0.9, 0.95, 1.0), 0.05, 0.0, Color(0.7, 0.85, 1.0), 1.2)), Vector3(0, 0.055, 0))


# ---------------------------------------------------------------------------
# bulky loot

static func _coffee_maker(root: Node3D) -> void:
	var body := _m("coffee_black", Color(0.1, 0.1, 0.11), 0.4, 0.2)
	_add(root, _box(Vector3(0.22, 0.03, 0.24), body), Vector3(0, 0.015, 0))
	_add(root, _box(Vector3(0.22, 0.32, 0.08), body), Vector3(0, 0.16, -0.08))
	_add(root, _box(Vector3(0.22, 0.06, 0.2), body), Vector3(0, 0.29, 0.0))
	_add(root, _cyl(0.07, 0.012, _steel(), 16), Vector3(0, 0.036, 0.04))
	_add(root, _cyl(0.065, 0.13, _glass("coffee_glass", Color(0.8, 0.85, 0.85)), 16), Vector3(0, 0.107, 0.04))
	_add(root, _cyl(0.058, 0.07, _m("coffee", Color(0.12, 0.06, 0.02), 0.2), 14), Vector3(0, 0.077, 0.04))
	_add(root, _box(Vector3(0.012, 0.012, 0.012), _screen("coffee", Color(1.0, 0.3, 0.1))), Vector3(0.08, 0.29, 0.101))


static func _heart_monitor(root: Node3D) -> void:
	var shell := _m("monitor_shell", Color(0.78, 0.79, 0.77), 0.5)
	_add(root, _box(Vector3(0.36, 0.26, 0.17), shell), Vector3(0, 0.13, 0))
	_add(root, _box(Vector3(0.28, 0.18, 0.004), _screen("ecg_bg", Color(0.02, 0.1, 0.08))), Vector3(-0.02, 0.14, 0.086))
	# The trace: a few bright segments making a heartbeat.
	var trace := _screen("ecg", Color(0.3, 1.0, 0.45))
	var pts := [Vector2(-0.15, 0.0), Vector2(-0.07, 0.0), Vector2(-0.05, 0.05), Vector2(-0.03, -0.04), Vector2(-0.01, 0.0), Vector2(0.11, 0.0)]
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg := _box(Vector3((b - a).length(), 0.005, 0.002), trace)
		_add(root, seg, Vector3((a.x + b.x) * 0.5 - 0.02, 0.15 + (a.y + b.y) * 0.5, 0.089), Vector3(0, 0, rad_to_deg((b - a).angle())))
	for i in 3:
		_add(root, _cyl(0.01, 0.01, _m("knob", Color(0.3, 0.3, 0.32), 0.5), 10), Vector3(0.15, 0.08 + i * 0.05, 0.088), Vector3(90, 0, 0))
	_add(root, _box(Vector3(0.2, 0.02, 0.03), _black_plastic()), Vector3(0, 0.29, 0))
	for s in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.02, 0.03, 0.03), _black_plastic()), Vector3(s * 0.09, 0.27, 0))


static func _iv_pump(root: Node3D) -> void:
	var shell := _m("pump_shell", Color(0.88, 0.88, 0.85), 0.5)
	_add(root, _box(Vector3(0.18, 0.28, 0.14), shell), Vector3(0, 0.14, 0))
	_add(root, _box(Vector3(0.12, 0.06, 0.004), _screen("pump", Color(0.4, 0.8, 1.0))), Vector3(0, 0.22, 0.072))
	for r in 3:
		for c in 3:
			_add(root, _box(Vector3(0.024, 0.016, 0.006), _m("pump_key", Color(0.35, 0.55, 0.75), 0.5)), Vector3(-0.035 + c * 0.035, 0.15 - r * 0.028, 0.072))
	_add(root, _box(Vector3(0.05, 0.2, 0.02), _m("pump_door", Color(0.55, 0.6, 0.65), 0.4)), Vector3(0.0, 0.14, -0.08))
	_add(root, _cyl(0.012, 0.08, _steel(), 8), Vector3(0, 0.14, -0.13), Vector3(90, 0, 0))


static func _defibrillator(root: Node3D) -> void:
	var case_mat := _m("aed_case", Color(0.95, 0.72, 0.08), 0.5)
	var dark := _m("aed_dark", Color(0.12, 0.12, 0.14), 0.6)
	_add(root, _box(Vector3(0.34, 0.14, 0.26), case_mat), Vector3(0, 0.07, 0))
	_add(root, _box(Vector3(0.3, 0.012, 0.22), dark), Vector3(0, 0.146, 0))
	_add(root, _box(Vector3(0.18, 0.03, 0.03), dark), Vector3(0, 0.18, 0))
	for s in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.025, 0.04, 0.03), dark), Vector3(s * 0.08, 0.16, 0))
	# A red heart with a lightning bolt, as blocks, on the lid.
	var red := _m("aed_red", Color(0.8, 0.08, 0.06), 0.5)
	_add(root, _box(Vector3(0.06, 0.004, 0.06), red), Vector3(-0.07, 0.154, 0.02), Vector3(0, 45, 0))
	_add(root, _sphere(0.022, red), Vector3(-0.089, 0.152, -0.002)).scale = Vector3(1, 0.15, 1)
	_add(root, _sphere(0.022, red), Vector3(-0.051, 0.152, -0.002)).scale = Vector3(1, 0.15, 1)
	_add(root, _box(Vector3(0.012, 0.005, 0.05), _m("aed_bolt", Color(1, 1, 1), 0.4)), Vector3(-0.07, 0.157, 0.01), Vector3(0, 25, 0))
	_add(root, _cyl(0.018, 0.006, _m("aed_button", Color(0.2, 0.7, 0.3), 0.4, 0.0, Color(0.2, 0.9, 0.3), 1.0), 12), Vector3(0.07, 0.154, 0.03))


static func _microscope(root: Node3D) -> void:
	var body := _m("scope_body", Color(0.9, 0.9, 0.88), 0.4)
	var dark := _black_plastic()
	_add(root, _box(Vector3(0.2, 0.04, 0.26), body), Vector3(0, 0.02, 0))
	_add(root, _box(Vector3(0.06, 0.26, 0.06), body), Vector3(0, 0.17, -0.09), Vector3(-10, 0, 0))
	_add(root, _box(Vector3(0.14, 0.012, 0.12), dark), Vector3(0, 0.13, 0.03))
	_add(root, _box(Vector3(0.07, 0.002, 0.025), _glass("slide", Color(0.9, 0.95, 1.0))), Vector3(0, 0.137, 0.03))
	_add(root, _cyl(0.03, 0.08, body, 14), Vector3(0, 0.24, -0.03), Vector3(20, 0, 0))
	_add(root, _cyl(0.035, 0.03, _steel(), 14), Vector3(0, 0.19, 0.0))
	for i in 3:
		_add(root, _cyl(0.008, 0.035, _steel(), 8), Vector3(-0.02 + i * 0.02, 0.165, 0.02 - i * 0.005))
	for s in [-1.0, 1.0]:
		_add(root, _cyl(0.012, 0.09, dark, 10), Vector3(s * 0.022, 0.31, -0.06), Vector3(35, 0, s * 8.0))
	for s in [-1.0, 1.0]:
		_add(root, _cyl(0.025, 0.02, dark, 12), Vector3(s * 0.05, 0.12, -0.09), Vector3(0, 0, 90))


static func _ultrasound(root: Node3D) -> void:
	var shell := _m("us_shell", Color(0.85, 0.86, 0.88), 0.45)
	_add(root, _box(Vector3(0.4, 0.07, 0.3), shell), Vector3(0, 0.035, 0))
	_add(root, _box(Vector3(0.3, 0.004, 0.14), _m("us_keys", Color(0.3, 0.32, 0.36), 0.5)), Vector3(0, 0.072, 0.06))
	_add(root, _cyl(0.02, 0.006, _m("us_ball", Color(0.25, 0.45, 0.8), 0.3), 12), Vector3(0.12, 0.076, 0.07))
	var lid := Node3D.new()
	_add(root, lid, Vector3(0, 0.07, -0.13), Vector3(-72, 0, 0))
	_add(lid, _box(Vector3(0.38, 0.02, 0.26), shell), Vector3(0, -0.01, 0.13))
	_add(lid, _box(Vector3(0.32, 0.002, 0.2), _screen("us", Color(0.55, 0.62, 0.66))), Vector3(0, 0.001, 0.13))
	_add(root, _cyl(0.014, 0.08, dark_probe(), 10, 0.02), Vector3(-0.15, 0.09, 0.1), Vector3(0, 0, 70))


static func dark_probe() -> StandardMaterial3D:
	return _m("us_probe", Color(0.2, 0.21, 0.23), 0.5)
