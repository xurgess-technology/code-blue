class_name TerminalModel
extends RefCounted
## The database terminal as a world object: a standing desk with a full-size monitor and
## keyboard, built from primitives (docs/SWEEP4A.md "Hard rule: no new Blender models"). Replaces
## the old medical guide's lectern and binder (sweep 4a chunk 4).
##
## HUB REDESIGN (2026-09-15): two fixes over the original lectern-sized version.
##  1. It was placed with the SAME yaw `scripts/level/entrance.gd` computes for every other
##     wall-mounted piece via `Defs.yaw_facing` (front assumed to be local -Z, matching every
##     `put()`-placed prop), but this model's screen was built facing local +Z -- so at yaw 0 it
##     faced INTO the wall it stands against, not out into the break room where players walk up to
##     it. The monitor (and its camera mirror below) now face -Z, matching that convention; no
##     placement code needed to change.
##  2. The whole thing is bigger: a proper standing desk (a wide slab, steel legs), a full-size
##     monitor and a keyboard, instead of a narrow lectern-shaped stand.
##
##   make_terminal()   origin on the floor, screen faces -Z (out into the room, the reader's side)

const SCREEN_GLOW := Color(0.35, 0.9, 0.55)
const ScreenLive := preload("res://scripts/database/terminal_screen_live.gd")


static func make_terminal() -> Node3D:
	var root := Node3D.new()
	root.name = "DatabaseTerminal"
	var steel := _mat(Color("6b7378"), 0.4, 0.8)
	var dark := _mat(Color("232629"), 0.55)
	var plastic := _mat(Color("1c1e20"), 0.5)

	# Desk: a wide slab on four steel legs, standing height.
	_box(root, Vector3(1.15, 0.05, 0.55), Vector3(0, 0.92, 0), dark)
	for x in [-0.5, 0.5]:
		for z in [-0.2, 0.2]:
			_box(root, Vector3(0.06, 0.9, 0.06), Vector3(x, 0.46, z), steel)
	_box(root, Vector3(1.2, 0.03, 0.02), Vector3(0, 0.5, -0.26), steel)   # a low crossbar, front

	# Monitor: a boxy shell on a short neck, screen facing -Z (out into the room).
	var monitor := Node3D.new()
	monitor.name = "Monitor"
	monitor.position = Vector3(0, 0.965, -0.1)
	root.add_child(monitor)
	_box(monitor, Vector3(0.1, 0.14, 0.06), Vector3(0, -0.1, 0), steel)   # neck
	_box(monitor, Vector3(0.52, 0.36, 0.08), Vector3(0, 0.1, 0), plastic)
	var screen := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.44, 0.27)
	screen.mesh = qm
	var sm := _mat(SCREEN_GLOW, 0.6)
	sm.emission_enabled = true
	sm.emission = SCREEN_GLOW
	sm.emission_energy_multiplier = 1.4
	screen.material_override = sm
	screen.name = "Screen"
	screen.rotation_degrees.y = 180.0
	screen.position = Vector3(0, 0.1, -0.045)
	monitor.add_child(screen)
	var glow := OmniLight3D.new()
	glow.name = "ScreenGlow"
	glow.light_color = SCREEN_GLOW
	glow.light_energy = 0.5
	glow.omni_range = 1.6
	glow.position = Vector3(0, 0.1, -0.15)
	monitor.add_child(glow)

	# A slab keyboard in front of the monitor, and a mouse beside it.
	_box(root, Vector3(0.4, 0.02, 0.16), Vector3(0, 0.955, 0.14), dark)
	_box(root, Vector3(0.05, 0.02, 0.08), Vector3(0.28, 0.955, 0.17), dark)

	root.set_meta("collider_size", Vector3(1.15, 0.9, 0.55))
	root.set_meta("collider_y", 0.45)

	# HUB REDESIGN: the live "what you're looking at" mirror on the screen when nobody has it open.
	# A per-machine local visual only (see terminal_screen_live.gd); no network traffic.
	var live := ScreenLive.new()
	live.name = "ScreenLive"
	monitor.add_child(live)
	live.attach(monitor, screen, qm.size)

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
