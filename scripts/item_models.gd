class_name ItemModels
extends RefCounted
## Visuals for item stacks, built from primitives so nothing waits on downloads.
## A registered asset under `item/<kind>` always wins. Origin sits at the base of the stack,
## there is no collision, and a stack of N looks like N things.


static func make(kind: String, count: int = 1) -> Node3D:
	var assets = Engine.get_main_loop().root.get_node_or_null("Assets") if Engine.get_main_loop() else null
	if assets != null and assets.has("item/" + kind):
		var real: Node3D = assets.spawn("item/" + kind)
		if real != null:
			return real
	var root := Node3D.new()
	root.name = "Model_%s" % kind
	match kind:
		"anesthetic": _vials(root, clampi(count, 1, 6))
		"gauze": _gauze(root, clampi(count, 1, 6))
		"forceps": _forceps(root)
		"tourniquet": _tourniquet(root)
		"bone_saw": _bone_saw(root)
		"guide": _guide(root)
		_: _add(root, _box(Vector3(0.15, 0.1, 0.15), Color.MAGENTA), Vector3(0, 0.05, 0))
	return root


## Rough footprint so containers and shelves can space stacks out.
static func footprint(kind: String) -> Vector3:
	match kind:
		"anesthetic": return Vector3(0.14, 0.09, 0.08)
		"gauze": return Vector3(0.22, 0.1, 0.12)
		"forceps": return Vector3(0.2, 0.03, 0.08)
		"tourniquet": return Vector3(0.28, 0.05, 0.1)
		"bone_saw": return Vector3(0.52, 0.05, 0.16)
		"guide": return Vector3(0.24, 0.06, 0.31)
	return Vector3(0.15, 0.1, 0.15)


# ---------------------------------------------------------------------------

static func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _glass(col: Color) -> StandardMaterial3D:
	var m := _mat(col, 0.08, 0.0)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.55
	m.rim_enabled = true
	m.rim = 0.5
	return m


static func _box(size: Vector3, col: Color, rough := 0.6, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = _mat(col, rough, metal)
	return mi


static func _cyl(r: float, h: float, mat: Material, sides := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	mi.mesh = c
	mi.material_override = mat
	return mi


static func _add(root: Node3D, n: Node3D, pos: Vector3, rot_deg := Vector3.ZERO) -> Node3D:
	n.position = pos
	n.rotation_degrees = rot_deg
	root.add_child(n)
	return n


static func _vials(root: Node3D, n: int) -> void:
	var glass := _glass(Color(0.75, 0.88, 0.95))
	var liquid := _mat(Color(0.95, 0.85, 0.35), 0.2)
	liquid.emission_enabled = true
	liquid.emission = Color(0.6, 0.5, 0.15)
	liquid.emission_energy_multiplier = 0.25
	var cap := _mat(Color(0.7, 0.15, 0.12), 0.5)
	var label := _mat(Color(0.93, 0.93, 0.9), 0.9)
	for i in n:
		var x := (i % 3 - 1) * 0.036 + (0.018 if i >= 3 else 0.0)
		var z := (0.0 if i < 3 else 0.034)
		var v := Node3D.new()
		_add(v, _cyl(0.014, 0.05, glass), Vector3(0, 0.025, 0))
		_add(v, _cyl(0.011, 0.034, liquid), Vector3(0, 0.019, 0))
		_add(v, _cyl(0.0145, 0.016, label), Vector3(0, 0.03, 0))
		_add(v, _cyl(0.009, 0.012, cap), Vector3(0, 0.056, 0))
		_add(root, v, Vector3(x, 0, z), Vector3(0, i * 37.0, 0))


static func _gauze(root: Node3D, n: int) -> void:
	var cloth := _mat(Color(0.95, 0.95, 0.92), 1.0)
	var wrap := _mat(Color(0.35, 0.55, 0.75), 0.8)
	for i in n:
		var roll := Node3D.new()
		_add(roll, _cyl(0.032, 0.07, cloth, 14), Vector3.ZERO, Vector3(0, 0, 90))
		_add(roll, _cyl(0.033, 0.012, wrap, 14), Vector3.ZERO, Vector3(0, 0, 90))
		var row := i % 3
		var layer := i / 3
		_add(root, roll, Vector3((row - 1) * 0.075, 0.032 + layer * 0.06, layer * 0.01), Vector3(0, (i * 13) % 20 - 10, 0))


static func _forceps(root: Node3D) -> void:
	var steel := _mat(Color(0.86, 0.89, 0.92), 0.3, 0.45)
	var pouch := _mat(Color(0.85, 0.9, 0.95), 0.4)
	pouch.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pouch.albedo_color.a = 0.35
	_add(root, _box(Vector3(0.24, 0.012, 0.07), Color.WHITE), Vector3(0, 0.006, 0)).material_override = pouch
	for side in [-1.0, 1.0]:
		var arm := _box(Vector3(0.19, 0.006, 0.008), Color.WHITE)
		arm.material_override = steel
		_add(root, arm, Vector3(0.0, 0.016, side * 0.008), Vector3(0, side * 4.0, 0))
	var joint := _cyl(0.008, 0.012, steel)
	_add(root, joint, Vector3(-0.08, 0.016, 0))


static func _tourniquet(root: Node3D) -> void:
	var strap := _mat(Color(0.12, 0.12, 0.13), 0.9)
	var buckle := _mat(Color(0.75, 0.1, 0.08), 0.5)
	var rod := _mat(Color(0.3, 0.3, 0.33), 0.45, 0.3)
	# A coiled strap, the red windlass clip and the rod
	for i in 3:
		var loop := MeshInstance3D.new()
		var t := TorusMesh.new()
		t.inner_radius = 0.045 - i * 0.009
		t.outer_radius = 0.06 - i * 0.009
		t.rings = 16
		t.ring_segments = 6
		loop.mesh = t
		loop.material_override = strap
		_add(root, loop, Vector3(0, 0.012 + i * 0.01, 0))
	_add(root, _box(Vector3(0.05, 0.02, 0.035), Color.WHITE), Vector3(0.07, 0.02, 0)).material_override = buckle
	var r := _cyl(0.006, 0.12, rod)
	_add(root, r, Vector3(0.0, 0.045, 0.0), Vector3(0, 0, 90))


static func _bone_saw(root: Node3D) -> void:
	var steel := _mat(Color(0.84, 0.86, 0.89), 0.32, 0.45)
	var grip := _mat(Color(0.18, 0.12, 0.08), 0.7)
	var blade := _box(Vector3(0.38, 0.004, 0.07), Color.WHITE)
	blade.material_override = steel
	_add(root, blade, Vector3(0.07, 0.012, 0.0))
	# Teeth along one edge: small wedges in a single shared mesh.
	var prism := PrismMesh.new()
	prism.size = Vector3(0.012, 0.004, 0.012)
	for i in 22:
		var tooth := MeshInstance3D.new()
		tooth.mesh = prism
		tooth.material_override = steel
		_add(root, tooth, Vector3(-0.09 + i * 0.015, 0.012, 0.041), Vector3(90, 0, 0))
	var handle := _box(Vector3(0.13, 0.03, 0.05), Color.WHITE)
	handle.material_override = grip
	_add(root, handle, Vector3(-0.17, 0.016, 0))
	var hole := _cyl(0.012, 0.032, _mat(Color(0.05, 0.05, 0.05)))
	_add(root, hole, Vector3(-0.17, 0.016, 0))


static func _guide(root: Node3D) -> void:
	var gm := "res://scripts/guide/guide_models.gd"
	if ResourceLoader.exists(gm):
		var s: GDScript = load(gm)
		var book: Node3D = s.make_book()
		if book != null:
			root.add_child(book)
			return
	_add(root, _box(Vector3(0.24, 0.05, 0.31), Color("6b2a22")), Vector3(0, 0.025, 0))
