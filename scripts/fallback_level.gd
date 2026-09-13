class_name FallbackLevel
extends RefCounted
## A small hand-made ward used when the procedural generator is unavailable.
## It exposes the same `info` dictionary as HospitalBuilder so the game does not
## care which one it got.

const W := 26   # tiles
const H := 20


static func build(info: Dictionary) -> Node3D:
	var root := Node3D.new()
	var body := StaticBody3D.new()
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)

	var floor_mat := _mat(Color("8a968f"), 0.9)
	var wall_mat := _mat(Color("a3aaa5"), 0.95)
	var ceil_mat := _mat(Color("b9bbb2"), 1.0)

	var fw := W * C.TILE
	var fh := H * C.TILE

	_add_plane(root, Vector3(fw * 0.5, 0.0, fh * 0.5), Vector2(fw, fh), floor_mat, false)
	_add_plane(root, Vector3(fw * 0.5, C.WALL_H, fh * 0.5), Vector2(fw, fh), ceil_mat, true)
	_add_floor_collider(body, Vector3(fw * 0.5, -0.05, fh * 0.5), Vector3(fw, 0.1, fh))

	# Perimeter walls plus one internal divider with a gap, so there is something to hide behind.
	_add_wall(root, body, wall_mat, Vector3(fw * 0.5, C.WALL_H * 0.5, 0.1), Vector3(fw, C.WALL_H, 0.2))
	_add_wall(root, body, wall_mat, Vector3(fw * 0.5, C.WALL_H * 0.5, fh - 0.1), Vector3(fw, C.WALL_H, 0.2))
	_add_wall(root, body, wall_mat, Vector3(0.1, C.WALL_H * 0.5, fh * 0.5), Vector3(0.2, C.WALL_H, fh))
	_add_wall(root, body, wall_mat, Vector3(fw - 0.1, C.WALL_H * 0.5, fh * 0.5), Vector3(0.2, C.WALL_H, fh))
	var divider_z := fh * 0.68
	_add_wall(root, body, wall_mat, Vector3(fw * 0.25, C.WALL_H * 0.5, divider_z), Vector3(fw * 0.5, C.WALL_H, 0.2))
	_add_wall(root, body, wall_mat, Vector3(fw * 0.88, C.WALL_H * 0.5, divider_z), Vector3(fw * 0.24, C.WALL_H, 0.2))

	var table_pos := Vector3(fw * 0.5, 0.0, fh * 0.4)
	var clock_pos := Vector3(fw * 0.35, 0.0, fh * 0.85)
	var pod_pos := Vector3(fw * 0.65, 0.0, fh * 0.85)

	_add_table(root, body, table_pos)
	_add_pillar(root, body, clock_pos, Color("3dff7a"))
	_add_pillar(root, body, pod_pos, Color("4fe0c8"))

	# Ceiling fixtures
	var lights: Array = []
	for gx in 4:
		for gz in 3:
			var p := Vector3((gx + 0.5) * fw / 4.0, C.WALL_H - 0.05, (gz + 0.5) * fh / 3.0)
			_add_fixture(root, p)
			lights.append(p)

	var player_spawns: Array = []
	for i in 4:
		player_spawns.append(Vector3(fw * 0.5 + (i - 1.5) * 1.6, 0.0, fh * 0.92))
	var tool_spawns: Array = []
	for i in 12:
		var a := TAU * i / 12.0
		tool_spawns.append(Vector3(fw * 0.5 + cos(a) * fw * 0.34, 0.0, fh * 0.42 + sin(a) * fh * 0.28))
	var monster_spawns: Array = [
		Vector3(fw * 0.1, 0.0, fh * 0.1), Vector3(fw * 0.9, 0.0, fh * 0.1),
		Vector3(fw * 0.1, 0.0, fh * 0.55), Vector3(fw * 0.9, 0.0, fh * 0.55),
	]

	info["player_spawns"] = player_spawns
	info["tool_spawns"] = tool_spawns
	info["monster_spawns"] = monster_spawns
	info["table"] = table_pos
	info["clock"] = clock_pos
	info["pod"] = pod_pos
	info["lights"] = lights
	info["fallback"] = true
	return root


static func _mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


static func _add_plane(root: Node3D, pos: Vector3, size: Vector2, mat: Material, flip: bool) -> void:
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	mi.material_override = mat
	mi.position = pos
	if flip:
		mi.rotation_degrees.x = 180
	root.add_child(mi)


static func _add_floor_collider(body: StaticBody3D, pos: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	body.add_child(cs)


static func _add_wall(root: Node3D, body: StaticBody3D, mat: Material, pos: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	root.add_child(mi)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	body.add_child(cs)


static func _add_table(root: Node3D, body: StaticBody3D, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 0.9, 1.0)
	mi.mesh = mesh
	mi.material_override = _mat(Color("cdd4d0"), 0.6)
	mi.position = pos + Vector3(0, 0.45, 0)
	root.add_child(mi)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = mesh.size
	cs.shape = box
	cs.position = mi.position
	body.add_child(cs)


static func _add_pillar(root: Node3D, body: StaticBody3D, pos: Vector3, glow: Color) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.7, 1.8, 0.7)
	mi.mesh = mesh
	var mat := _mat(Color("55606b"), 0.5)
	mat.emission_enabled = true
	mat.emission = glow
	mat.emission_energy_multiplier = 0.7
	mi.material_override = mat
	mi.position = pos + Vector3(0, 0.9, 0)
	root.add_child(mi)
	var light := OmniLight3D.new()
	light.light_color = glow
	light.light_energy = 1.0
	light.omni_range = 5.0
	light.shadow_enabled = false
	light.position = pos + Vector3(0, 2.0, 0)
	root.add_child(light)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = mesh.size
	cs.shape = box
	cs.position = mi.position
	body.add_child(cs)


static func _add_fixture(root: Node3D, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.4, 0.06, 0.5)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("222222")
	mat.emission_enabled = true
	mat.emission = Color("d9f0e6")
	mat.emission_energy_multiplier = 1.4
	mi.material_override = mat
	mi.position = pos
	root.add_child(mi)
	var light := OmniLight3D.new()
	light.light_color = Color("d9f0e6")
	light.light_energy = 1.2
	light.omni_range = 7.0
	light.shadow_enabled = false
	light.position = pos - Vector3(0, 0.2, 0)
	light.add_to_group("fixture")
	light.set_meta("mode", 0 if randf() < 0.6 else 1)
	root.add_child(light)
