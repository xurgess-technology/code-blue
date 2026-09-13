extends Node3D
## Two paramedics wheeling a gurney (loop, sweep 2). Visual only: no collision, nothing thinks.
## The shift loop moves the crew (the host along the navmesh, clients toward the replicated
## position) and says which phase it is in; the crew animates to match.
##
## Local frame: the crew walks along -Z. The gurney is in the middle, one medic pulls at the
## front, one pushes at the back. The patient lies on the gurney until the hand-over.

const WALK_CYCLE := 7.5
const HEAD_SKIN := Color("d9ad8c")

const BodyScript := preload("res://scripts/patient_body.gd")

var patient_id := ""
var ailment_id := ""
var phase := "in"          # "in" (bringing), "hand" (putting on the table), "out" (leaving)
var target_pos := Vector3.ZERO
var target_yaw := 0.0

var _walk := 0.0
var _speed := 0.0
var _gurney: Node3D
var _body: Node3D = null
var _medics: Array = []    # [{root, legs: [Node3D, Node3D], arms: [..]}]
var _placed := false


static func create(pid: String, ail: String) -> Node3D:
	var n: Node3D = (load("res://scripts/loop/crew.gd") as GDScript).new()
	n.name = "ParamedicCrew"
	n.patient_id = pid
	n.ailment_id = ail
	n._build()
	return n


func _build() -> void:
	_gurney = _make_gurney()
	_gurney.position = Vector3(0, 0, 0)
	add_child(_gurney)
	if patient_id != "" and patient_id != "player" and not Procedures.patient(patient_id).is_empty():
		_body = BodyScript.create(patient_id)
		_body.name = "Patient"
		# Bodies lie along their local X (the table's long axis); the gurney runs along Z.
		_body.rotation.y = PI * 0.5
		_body.position = Vector3(0, 0.86, 0)
		_gurney.add_child(_body)
		if _body.has_method("set_ailment"):
			_body.set_ailment(ailment_id)
		if _body.has_method("set_vitals"):
			_body.set_vitals(70.0)
	_make_medic(Vector3(0, 0, -1.55), 0.0, Color("2f4f3f"))   # pulling at the front
	_make_medic(Vector3(0, 0, 1.45), 0.0, Color("2f4f3f"))    # pushing at the back


## Jump straight to a pose (the first placement, or a big correction).
func snap(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation.y = yaw
	target_pos = pos
	target_yaw = yaw
	_placed = true


func set_target(pos: Vector3, yaw: float, new_phase: String) -> void:
	if not _placed:
		snap(pos, yaw)
	target_pos = pos
	target_yaw = yaw
	phase = new_phase


func _process(delta: float) -> void:
	var before := global_position
	var k := clampf(delta * 10.0, 0.0, 1.0)
	if global_position.distance_to(target_pos) > 6.0:
		global_position = target_pos
	else:
		global_position = global_position.lerp(target_pos, k)
	rotation.y = lerp_angle(rotation.y, target_yaw, k)
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_speed = lerpf(_speed, moved / maxf(delta, 1e-4), clampf(delta * 8.0, 0.0, 1.0))
	_walk += delta * WALK_CYCLE * clampf(_speed / 2.0, 0.0, 1.2)
	var swing := sin(_walk) * 0.55 * clampf(_speed / 1.2, 0.0, 1.0)
	for i in _medics.size():
		var m: Dictionary = _medics[i]
		var s := swing if i == 0 else -swing
		(m.legs[0] as Node3D).rotation.x = s
		(m.legs[1] as Node3D).rotation.x = -s
		(m.root as Node3D).position.y = absf(sin(_walk)) * 0.025 * clampf(_speed, 0.0, 1.0)
	if _body != null:
		_body.visible = phase != "out"
		if _body.has_method("set_sedation"):
			_body.set_sedation(0.2)
	# The gurney casters jiggle on the tiles while it rolls.
	_gurney.position.y = absf(sin(_walk * 2.3)) * 0.008 * clampf(_speed, 0.0, 1.0)


func is_moving() -> bool:
	return _speed > 0.3


# ---------------------------------------------------------------------------- models

func _make_gurney() -> Node3D:
	var g := Node3D.new()
	g.name = "Gurney"
	var steel := _mat(Color(0.62, 0.64, 0.66), 0.35, 0.7)
	var dark := _mat(Color(0.1, 0.1, 0.11), 0.8)
	var sheet := _mat(Color(0.86, 0.88, 0.86), 0.9)
	var orange := _mat(Color(0.9, 0.42, 0.1), 0.6)
	# Frame and mattress (long along Z).
	g.add_child(_box(Vector3(0.62, 0.05, 1.95), Vector3(0, 0.66, 0), steel))
	g.add_child(_box(Vector3(0.58, 0.12, 1.9), Vector3(0, 0.75, 0), sheet))
	g.add_child(_box(Vector3(0.6, 0.03, 0.12), Vector3(0, 0.83, -0.75), sheet))
	# Side rails and the orange straps across the patient.
	for sx in [-1, 1]:
		g.add_child(_box(Vector3(0.025, 0.025, 1.7), Vector3(0.32 * sx, 0.86, 0), steel))
	for z in [-0.35, 0.45]:
		g.add_child(_box(Vector3(0.66, 0.012, 0.07), Vector3(0, 0.99, z), orange))
	# Scissor legs and casters.
	for sz in [-1, 1]:
		for sx in [-1, 1]:
			var leg := _box(Vector3(0.035, 0.62, 0.035), Vector3(0.24 * sx, 0.34, 0.72 * sz), steel)
			leg.rotation.x = 0.28 * sz
			g.add_child(leg)
			var wheel := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.06
			cm.bottom_radius = 0.06
			cm.height = 0.04
			cm.radial_segments = 10
			wheel.mesh = cm
			wheel.material_override = dark
			wheel.rotation.z = PI * 0.5
			wheel.position = Vector3(0.24 * sx, 0.06, 0.8 * sz)
			g.add_child(wheel)
	# Push handle at the back, an IV pole with a bag at the head end.
	g.add_child(_box(Vector3(0.6, 0.03, 0.03), Vector3(0, 0.98, 1.02), steel))
	for sx in [-1, 1]:
		g.add_child(_box(Vector3(0.025, 0.3, 0.025), Vector3(0.29 * sx, 0.84, 1.0), steel))
	g.add_child(_box(Vector3(0.02, 1.0, 0.02), Vector3(-0.28, 1.2, -0.85), steel))
	var bag := _box(Vector3(0.1, 0.16, 0.04), Vector3(-0.28, 1.62, -0.85), _mat(Color(0.8, 0.9, 1.0, 0.7), 0.2))
	(bag.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	g.add_child(bag)
	return g


func _make_medic(at: Vector3, yaw: float, uniform: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Medic"
	root.position = at
	root.rotation.y = yaw
	add_child(root)
	var cloth := _mat(uniform, 0.85)
	var pants := _mat(uniform.darkened(0.35), 0.9)
	var hi_vis := _mat(Color(0.85, 0.95, 0.25), 0.4)
	hi_vis.emission_enabled = true
	hi_vis.emission = Color(0.7, 0.8, 0.2)
	hi_vis.emission_energy_multiplier = 0.35
	var skin := _mat(HEAD_SKIN, 0.7)
	var boots := _mat(Color(0.08, 0.08, 0.09), 0.7)
	# Torso and the reflective bands.
	var torso := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.22
	cap.height = 0.78
	cap.radial_segments = 10
	cap.rings = 4
	torso.mesh = cap
	torso.material_override = cloth
	torso.position = Vector3(0, 1.22, 0)
	root.add_child(torso)
	for y in [1.08, 1.3]:
		var band := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.225
		cyl.bottom_radius = 0.225
		cyl.height = 0.05
		cyl.radial_segments = 10
		band.mesh = cyl
		band.material_override = hi_vis
		band.position = Vector3(0, y, 0)
		root.add_child(band)
	# Head, cap.
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.radial_segments = 10
	sm.rings = 6
	head.mesh = sm
	head.material_override = skin
	head.position = Vector3(0, 1.74, 0)
	root.add_child(head)
	root.add_child(_box(Vector3(0.24, 0.07, 0.26), Vector3(0, 1.83, 0.01), cloth))
	root.add_child(_box(Vector3(0.22, 0.02, 0.1), Vector3(0, 1.8, -0.15), cloth))
	# Legs swing from the hip.
	var legs := []
	for sx in [-1, 1]:
		var hip := Node3D.new()
		hip.position = Vector3(0.1 * sx, 0.86, 0)
		root.add_child(hip)
		hip.add_child(_box(Vector3(0.13, 0.8, 0.15), Vector3(0, -0.4, 0), pants))
		hip.add_child(_box(Vector3(0.14, 0.08, 0.24), Vector3(0, -0.82, -0.04), boots))
		legs.append(hip)
	# Arms reaching for the gurney handle / rail (toward the gurney's middle).
	var reach := signf(at.z) if absf(at.z) > 0.01 else 1.0
	var arms := []
	for sx in [-1, 1]:
		var shoulder := Node3D.new()
		shoulder.position = Vector3(0.26 * sx, 1.45, 0)
		shoulder.rotation.x = 1.05 * reach
		root.add_child(shoulder)
		shoulder.add_child(_box(Vector3(0.1, 0.56, 0.1), Vector3(0, -0.28, 0), cloth))
		shoulder.add_child(_box(Vector3(0.09, 0.1, 0.1), Vector3(0, -0.6, 0), skin))
		arms.append(shoulder)
	_medics.append({"root": root, "legs": legs, "arms": arms})
	return root


static func _mat(col: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
