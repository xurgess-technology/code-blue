class_name TerminalModel
extends RefCounted
## The database terminal as a world object: a desk-mounted CRT-style monitor, keyboard and a
## steel stand, built from primitives (docs/SWEEP4A.md "Hard rule: no new Blender models").
## Replaces the old medical guide's lectern and binder (sweep 4a chunk 4).
##
##   make_terminal()   origin on the floor, screen faces +Z (the reader's side)

const SCREEN_GLOW := Color(0.35, 0.9, 0.55)


static func make_terminal() -> Node3D:
	var root := Node3D.new()
	root.name = "DatabaseTerminal"
	var steel := _mat(Color("6b7378"), 0.4, 0.8)
	var dark := _mat(Color("232629"), 0.55)
	var plastic := _mat(Color("1c1e20"), 0.5)

	# Stand: a steel column on a small base, like the blender's stand.
	_box(root, Vector3(0.42, 0.04, 0.34), Vector3(0, 0.02, 0), dark)
	_box(root, Vector3(0.1, 0.86, 0.1), Vector3(0, 0.46, -0.05), steel)
	# Desk slab the monitor and keyboard sit on.
	_box(root, Vector3(0.56, 0.04, 0.4), Vector3(0, 0.9, 0), dark)

	# Monitor: a boxy CRT-style shell, screen facing +Z.
	var monitor := Node3D.new()
	monitor.name = "Monitor"
	monitor.position = Vector3(0, 0.92, -0.08)
	root.add_child(monitor)
	_box(monitor, Vector3(0.34, 0.28, 0.3), Vector3(0, 0.14, 0), plastic)
	var screen := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.27, 0.2)
	screen.mesh = qm
	var sm := _mat(SCREEN_GLOW, 0.6)
	sm.emission_enabled = true
	sm.emission = SCREEN_GLOW
	sm.emission_energy_multiplier = 1.4
	screen.material_override = sm
	screen.name = "Screen"
	screen.position = Vector3(0, 0.14, 0.152)
	monitor.add_child(screen)
	var glow := OmniLight3D.new()
	glow.name = "ScreenGlow"
	glow.light_color = SCREEN_GLOW
	glow.light_energy = 0.5
	glow.omni_range = 1.2
	glow.position = Vector3(0, 0.14, 0.2)
	monitor.add_child(glow)

	# A slab keyboard in front of the monitor.
	_box(root, Vector3(0.26, 0.02, 0.1), Vector3(0, 0.925, 0.1), dark)

	root.set_meta("collider_size", Vector3(0.56, 0.9, 0.4))
	root.set_meta("collider_y", 0.45)
	return root


static func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi
