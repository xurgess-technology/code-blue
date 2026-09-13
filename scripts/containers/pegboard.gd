extends "res://scripts/containers/container_base.gd"
## A wall pegboard with hooks and painted tool outlines. Always open and prompt-free: items
## hang on it in plain sight. Four slots, two rows of two, each on a pair of hooks.
##
## Slot transforms lay a stack flat against the board: the stack's +Y points out of the
## board and its +X runs along it, so a bone saw hangs lengthways.
##
## Local frame: origin on the floor at the wall, the board faces -Z.

const PW := 1.32
const PH := 0.96
const BOTTOM := 0.95
const THICK := 0.022
const STANDOFF := 0.03
const SLOT_POS := [Vector2(-0.33, 1.63), Vector2(0.33, 1.63), Vector2(-0.33, 1.23), Vector2(0.33, 1.23)]


static func create(id: String) -> Node3D:
	var p = new()
	p.init_container("pegboard", id)
	p.display_name = "pegboard"
	p._open = true
	p._build()
	return p


func _build() -> void:
	var front_z := -STANDOFF - THICK
	var yc := BOTTOM + PH * 0.5
	box(self, Vector3(PW, PH, THICK), Vector3(0, yc, -STANDOFF - THICK * 0.5), Mats.get_mat("board_edge"))
	var face := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(PW - 0.02, PH - 0.02)
	face.mesh = q
	# QuadMesh faces +Z; turn it to face -Z.
	face.rotation.y = PI
	face.position = Vector3(0, yc, front_z - 0.001)
	face.material_override = Mats.get_mat("board")
	add_child(face)
	# Frame
	var edge := Mats.get_mat("steel_dark")
	box(self, Vector3(PW + 0.04, 0.03, 0.035), Vector3(0, BOTTOM - 0.015, front_z + 0.005), edge)
	box(self, Vector3(PW + 0.04, 0.03, 0.035), Vector3(0, BOTTOM + PH + 0.015, front_z + 0.005), edge)
	for sx in [-1.0, 1.0]:
		box(self, Vector3(0.03, PH + 0.06, 0.035), Vector3(sx * (PW * 0.5 + 0.005), yc, front_z + 0.005), edge)
	# A few empty hooks and a hanging roll of tape for life.
	for h in [Vector2(-0.52, 1.44), Vector2(0.0, 1.8), Vector2(0.55, 1.0), Vector2(0.02, 1.02)]:
		_hook(Vector3(h.x, h.y, front_z))
	var tape := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.03
	tm.outer_radius = 0.05
	tm.rings = 14
	tm.ring_segments = 6
	tape.mesh = tm
	tape.rotation_degrees = Vector3(90, 0, 0)
	tape.position = Vector3(0.0, 1.745, front_z - 0.03)
	tape.material_override = Mats.get_mat("label")
	add_child(tape)

	for s in SLOT_POS:
		# Painted outline behind the tool and two hooks it rests on.
		box(self, Vector3(0.56, 0.18, 0.002), Vector3(s.x, s.y, front_z - 0.002), Mats.get_mat("outline"))
		box(self, Vector3(0.53, 0.15, 0.002), Vector3(s.x, s.y, front_z - 0.003), Mats.get_mat("board_edge"))
		for hx in [-0.17, 0.17]:
			_hook(Vector3(s.x + hx, s.y - 0.095, front_z))
		var basis := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
		add_slot(self, Transform3D(basis, Vector3(s.x, s.y, front_z - 0.006)))

	collider(self, C.L_WORLD, Vector3(PW, PH, THICK + STANDOFF), Vector3(0, yc, -(THICK + STANDOFF) * 0.5), "Body")
	collider(self, C.L_INTERACT, Vector3(PW, PH, 0.01), Vector3(0, yc, front_z + 0.004), "Aim")
	bake(self)


func _hook(at: Vector3) -> void:
	var chrome := Mats.get_mat("chrome")
	cyl(self, 0.005, 0.07, at + Vector3(0, 0, -0.035), chrome, Vector3(90, 0, 0), 6)
	cyl(self, 0.005, 0.025, at + Vector3(0, 0.012, -0.07), chrome, Vector3.ZERO, 6)


func is_open() -> bool:
	return true


func set_open(_open_arg: bool, _animate: bool = true) -> void:
	_open = true


func interact_prompt(_player) -> String:
	return ""


func interact(_player) -> void:
	pass
