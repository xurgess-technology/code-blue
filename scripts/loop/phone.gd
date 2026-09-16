extends Node3D
## The break-room phone (loop, sweep 2). Interactable `phone`: while it rings, E answers it (the
## shift loop decides what answering means). A red line lamp blinks (and lights the wall a
## little) while it rings, on every machine.
##
## Three builds: `create(true)` for levels that already have a wall phone model at
## level_info.phone: only the aim target, the lamp and its glow, origin at the phone's centre, -Z
## facing into the room. `create(false, true)` (the hub's triage counter): the desk phone alone,
## origin on the counter top. `create()`: a desk phone on a small side table, origin on the floor,
## for levels without one. The desk phone shivers while it rings.

const RING_SHAKE := 0.012
## Hub desk phone: how high it leaps off the counter while it rings.
const LEAP := 0.32

var ringing := false
var wall := false
## Standing on a counter: no side table, everything `desk_drop` lower.
var on_desk := false
var _t := 0.0
var _lamp_mat: StandardMaterial3D
var _glow: OmniLight3D
var _handset: Node3D = null
var _handset_rest := Vector3.ZERO


static func create(on_wall: bool = false, desk: bool = false) -> Node3D:
	var n: Node3D = (load("res://scripts/loop/phone.gd") as GDScript).new()
	n.name = "BreakRoomPhone" if not desk else "TriagePhone"
	n.wall = on_wall
	n.on_desk = desk
	if on_wall:
		n._build_wall()
	elif desk:
		n._build_on_desk()
	else:
		n._build()
	return n


## Hub rebuild: the desk phone on the triage counter. The side-table build's phone, 0.8 m lower (its
## origin is the counter top), with a brighter line lamp you can see from the path in.
func _build_on_desk() -> void:
	_build()
	var stand := get_node_or_null("Stand")
	if stand != null:
		stand.free()
	for c in get_children():
		if c is Node3D:
			(c as Node3D).position.y -= 0.8
	_handset_rest.y -= 0.8
	if _glow != null:
		_glow.omni_range = 2.2


func _build_wall() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "phone")
	_lamp_mat = _mat(Color(0.25, 0.04, 0.03), 0.3)
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(1.0, 0.12, 0.08)
	_lamp_mat.emission_energy_multiplier = 0.0
	add_child(_box(Vector3(0.05, 0.03, 0.03), Vector3(0.1, 0.19, -0.115), _lamp_mat))
	_add_glow(Vector3(0.1, 0.19, -0.3))
	var area := Area3D.new()
	area.name = "Aim"
	area.collision_layer = C.L_INTERACT
	area.collision_mask = 0
	area.monitoring = false
	var acs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.36
	acs.shape = sph
	area.add_child(acs)
	add_child(area)


func _add_glow(at: Vector3) -> void:
	_glow = OmniLight3D.new()
	_glow.name = "RingGlow"
	_glow.light_color = Color(1.0, 0.18, 0.1)
	_glow.light_energy = 0.0
	_glow.omni_range = 1.4
	_glow.shadow_enabled = false
	_glow.light_volumetric_fog_energy = 0.0
	_glow.position = at
	_glow.visible = false
	add_child(_glow)


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

	# MODELS HOOK (models sweep 2): the red rotary desk phone model (the desk_phone loot's model)
	# when it exists; the whole phone shivers while it rings.
	var model_mesh: ArrayMesh = ItemModels.asset_mesh("desk_phone")
	if model_mesh != null:
		_handset = ItemModels.make("desk_phone")
		_handset.name = "Handset"
		_handset_rest = Vector3(0, 0.805, 0)
		_handset.position = _handset_rest
		add_child(_handset)
		_lamp_mat = _mat(Color(0.25, 0.04, 0.03), 0.3)
		_lamp_mat.emission_enabled = true
		_lamp_mat.emission = Color(1.0, 0.12, 0.08)
		_lamp_mat.emission_energy_multiplier = 0.0
		add_child(_box(Vector3(0.03, 0.015, 0.03), Vector3(0.2, 0.812, 0.12), _lamp_mat))
		_add_glow(Vector3(0.0, 1.05, 0.15))
		_add_aim()
		return
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
	_add_glow(Vector3(0.0, 1.05, 0.15))
	_add_aim()


## The aim target for E, over the desk phone.
func _add_aim() -> void:
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
		var blink := fmod(_t, 0.5) < 0.25
		_lamp_mat.emission_energy_multiplier = 3.0 if blink else 0.4
		_glow.visible = true
		_glow.light_energy = 0.9 if blink else 0.15
		if _handset != null:
			if on_desk:
				# Hub: the phone leaps off the counter and rattles in the air for each ring, then drops.
				var ph := fmod(_t, 2.6)
				var up := 0.0
				if ph < 1.9:
					up = smoothstep(0.0, 0.18, ph) * (1.0 - smoothstep(1.7, 1.9, ph))
				var buzz := up * (0.6 + 0.4 * absf(sin(_t * 9.0)))
				_handset.position = _handset_rest + Vector3(sin(_t * 90.0) * 0.012 * buzz, LEAP * up + absf(sin(_t * 55.0)) * 0.02 * buzz, cos(_t * 77.0) * 0.01 * buzz)
				_handset.rotation = Vector3(sin(_t * 61.0) * 0.12 * buzz, sin(_t * 23.0) * 0.25 * up, sin(_t * 83.0) * 0.14 * buzz)
			elif trill:
				_handset.position = _handset_rest + Vector3(sin(_t * 140.0) * RING_SHAKE * 0.3, absf(sin(_t * 70.0)) * RING_SHAKE, 0)
			else:
				_handset.position = _handset_rest
	else:
		_lamp_mat.emission_energy_multiplier = 0.0
		_glow.visible = false
		if _handset != null:
			_handset.position = _handset_rest
			_handset.rotation = Vector3.ZERO


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
