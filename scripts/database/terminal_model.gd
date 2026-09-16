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
	var steel := _mat(Color("5d6468"), 0.45, 0.7)
	var laminate := _mat(Color(0.47, 0.43, 0.38), 0.75)
	var beige := _mat(Color(0.74, 0.7, 0.61), 0.6)
	var beige_dark := _mat(Color(0.6, 0.57, 0.5), 0.65)
	var dark := _mat(Color("1c1e20"), 0.5)

	# Hub rebuild, chunk 4: the break room's computer. An office desk (laminate top at sitting height
	# on steel legs with a modesty panel), a beige CRT, a keyboard and mouse, a tower under the desk.
	var top := 0.76
	_box(root, Vector3(1.15, 0.035, 0.6), Vector3(0, top - 0.018, 0), laminate)
	for x in [-0.54, 0.54]:
		_box(root, Vector3(0.04, top - 0.035, 0.52), Vector3(x, (top - 0.035) * 0.5, 0), steel)
	_box(root, Vector3(1.04, 0.38, 0.02), Vector3(0, top - 0.25, 0.26), steel)   # modesty panel, at the wall
	# The tower, on the floor under the desk's right end.
	_box(root, Vector3(0.19, 0.42, 0.44), Vector3(0.36, 0.21, 0.02), beige)
	_box(root, Vector3(0.12, 0.012, 0.004), Vector3(0.36, 0.34, -0.2), dark)       # the drive slot
	var led := _mat(Color(0.2, 0.9, 0.3), 0.4)
	led.emission_enabled = true
	led.emission = Color(0.3, 1.0, 0.4)
	_box(root, Vector3(0.012, 0.012, 0.004), Vector3(0.42, 0.28, -0.2), led)

	# The CRT: a deep beige shell tapering back, on a swivel foot, screen facing -Z (into the room).
	var monitor := Node3D.new()
	monitor.name = "Monitor"
	monitor.position = Vector3(-0.05, top + 0.05, 0.02)
	root.add_child(monitor)
	_box(monitor, Vector3(0.24, 0.03, 0.2), Vector3(0, -0.035, 0.02), beige_dark)   # swivel foot
	_box(monitor, Vector3(0.44, 0.38, 0.1), Vector3(0, 0.2, -0.12), beige)          # the bezel
	_box(monitor, Vector3(0.38, 0.32, 0.26), Vector3(0, 0.19, 0.06), beige_dark)    # the tube's back
	_box(monitor, Vector3(0.05, 0.02, 0.012), Vector3(0.16, 0.035, -0.172), beige_dark)   # power button
	var screen := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.34, 0.26)
	screen.mesh = qm
	var sm := _mat(SCREEN_GLOW, 0.6)
	sm.emission_enabled = true
	sm.emission = SCREEN_GLOW
	sm.emission_energy_multiplier = 1.4
	screen.material_override = sm
	screen.name = "Screen"
	screen.rotation_degrees.y = 180.0
	screen.position = Vector3(0, 0.21, -0.172)
	monitor.add_child(screen)
	var glow := OmniLight3D.new()
	glow.name = "ScreenGlow"
	glow.light_color = SCREEN_GLOW
	glow.light_energy = 0.5
	glow.omni_range = 1.6
	glow.position = Vector3(0, 0.21, -0.35)
	monitor.add_child(glow)

	# A beige keyboard in front of the monitor, a mouse on a pad beside it, a mug.
	var kb := _box(root, Vector3(0.44, 0.025, 0.16), Vector3(-0.05, top + 0.013, -0.2), beige)
	kb.rotation_degrees.x = -4.0
	_box(root, Vector3(0.2, 0.004, 0.17), Vector3(0.3, top + 0.002, -0.18), dark)
	_box(root, Vector3(0.055, 0.03, 0.09), Vector3(0.3, top + 0.015, -0.18), beige)
	var mug := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.04
	cyl.height = 0.1
	mug.mesh = cyl
	mug.material_override = _mat(Color(0.55, 0.12, 0.1), 0.4)
	mug.position = Vector3(-0.42, top + 0.05, -0.12)
	root.add_child(mug)

	root.set_meta("collider_size", Vector3(1.15, 1.2, 0.6))
	root.set_meta("collider_y", 0.6)

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
