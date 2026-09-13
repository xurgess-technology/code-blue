extends Node3D
## The break-room phone (loop, sweep 2): a beige desk phone on a small side table. Interactable
## `phone`: while it rings, E answers it (the shift loop decides what answering means). The red
## line lamp blinks and the handset shivers while it rings, on every machine.

const RING_SHAKE := 0.012

var ringing := false
var _t := 0.0
var _lamp_mat: StandardMaterial3D
var _handset: Node3D
var _handset_rest := Vector3.ZERO


static func create() -> Node3D:
	var n: Node3D = (load("res://scripts/loop/phone.gd") as GDScript).new()
	n.name = "BreakRoomPhone"
	n._build()
	return n


func _build() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "phone")

	# The side table: collides with the world so nobody walks through it and the economy's
	# free-floor search avoids it.
	var stand := StaticBody3D.new()
	stand.name = "Stand"
	stand.collision_layer = C.L_WORLD
	stand.collision_mask = 0
	add_child(stand)
	var wood := _mat(Color(0.36, 0.27, 0.19), 0.75)
	var steel := _mat(Color(0.3, 0.31, 0.33), 0.5)
	stand.add_child(_box(Vector3(0.62, 0.05, 0.46), Vector3(0, 0.78, 0), wood))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			stand.add_child(_box(Vector3(0.04, 0.76, 0.04), Vector3(0.27 * sx, 0.38, 0.19 * sz), steel))
	stand.add_child(_box(Vector3(0.56, 0.03, 0.4), Vector3(0, 0.25, 0), wood))
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.62, 0.8, 0.46)
	cs.shape = bs
	cs.position = Vector3(0, 0.4, 0)
	stand.add_child(cs)

	# The phone: a wedge body, a keypad, a cord and a handset lying across the cradle.
	var beige := _mat(Color(0.78, 0.72, 0.6), 0.55)
	var dark := _mat(Color(0.12, 0.12, 0.13), 0.6)
	var body := _box(Vector3(0.24, 0.07, 0.2), Vector3(0, 0.84, 0.01), beige)
	add_child(body)
	var slope := _box(Vector3(0.22, 0.04, 0.1), Vector3(0, 0.885, 0.05), beige)
	slope.rotation.x = -0.35
	add_child(slope)
	for i in 3:
		for j in 3:
			add_child(_box(Vector3(0.028, 0.008, 0.022), Vector3(-0.04 + i * 0.04, 0.906 - j * 0.012, 0.03 + j * 0.028), dark))
	_handset = Node3D.new()
	_handset.name = "Handset"
	_handset_rest = Vector3(0, 0.905, -0.05)
	_handset.position = _handset_rest
	add_child(_handset)
	_handset.add_child(_box(Vector3(0.24, 0.035, 0.05), Vector3.ZERO, beige))
	for sx in [-1, 1]:
		_handset.add_child(_box(Vector3(0.06, 0.04, 0.065), Vector3(0.1 * sx, -0.012, 0), beige))
	# Coiled cord, a few dark loops down to the body.
	for k in 5:
		var loop := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.006
		tm.outer_radius = 0.014
		tm.rings = 6
		tm.ring_segments = 4
		loop.mesh = tm
		loop.material_override = dark
		loop.position = Vector3(0.14, 0.87 - k * 0.012, -0.03 + k * 0.004)
		loop.rotation.z = PI * 0.5
		add_child(loop)
	# The line lamp.
	_lamp_mat = _mat(Color(0.25, 0.04, 0.03), 0.3)
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(1.0, 0.12, 0.08)
	_lamp_mat.emission_energy_multiplier = 0.0
	add_child(_box(Vector3(0.025, 0.012, 0.018), Vector3(0.085, 0.878, 0.09), _lamp_mat))

	# The aim target for E.
	var area := Area3D.new()
	area.name = "Aim"
	area.collision_layer = C.L_INTERACT
	area.collision_mask = 0
	area.monitoring = false
	var acs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.38
	acs.shape = sph
	acs.position = Vector3(0, 0.9, 0)
	area.add_child(acs)
	add_child(area)


func set_ringing(on: bool) -> void:
	ringing = on


func _process(delta: float) -> void:
	_t += delta
	if ringing:
		var trill := fmod(_t, 2.6) < 1.9
		_lamp_mat.emission_energy_multiplier = 3.0 if fmod(_t, 0.5) < 0.25 else 0.4
		if trill:
			_handset.position = _handset_rest + Vector3(sin(_t * 140.0) * RING_SHAKE * 0.3, absf(sin(_t * 70.0)) * RING_SHAKE, 0)
		else:
			_handset.position = _handset_rest
	else:
		_lamp_mat.emission_energy_multiplier = 0.0
		_handset.position = _handset_rest


# ---- interactable contract ----

func interact_prompt(_player) -> String:
	var g = get_tree().get_first_node_in_group("game") if is_inside_tree() else null
	if g == null or g.loop == null:
		return ""
	return g.loop.phone_prompt()


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g = get_tree().get_first_node_in_group("game")
	if g != null and g.loop != null:
		g.loop.answer(player)


static func _mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi
