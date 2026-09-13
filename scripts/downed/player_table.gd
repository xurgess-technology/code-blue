extends RefCounted
## The OR's player table when the level does not build one (docs/CONTRACTS.md, "Downed players"):
## a plain steel treatment table with a thin mattress and a head cushion, top at TOP_Y, long axis
## along local X (head end toward -X, like the patient bodies). Collision on C.L_WORLD.

const TOP_Y := 0.92
const SIZE := Vector3(2.0, 0.08, 0.8)


static func make() -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = "PlayerTable"
	sb.collision_layer = C.L_WORLD
	sb.collision_mask = 0
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.62, 0.66, 0.68)
	steel.metallic = 0.55
	steel.roughness = 0.35
	var pad := StandardMaterial3D.new()
	pad.albedo_color = Color(0.2, 0.34, 0.4)
	pad.roughness = 0.8
	var frame := _box(Vector3(SIZE.x, 0.05, SIZE.z), Vector3(0, TOP_Y - 0.07, 0), steel)
	sb.add_child(frame)
	sb.add_child(_box(Vector3(SIZE.x - 0.04, 0.05, SIZE.z - 0.06), Vector3(0, TOP_Y - 0.025, 0), pad))
	sb.add_child(_box(Vector3(0.28, 0.06, SIZE.z - 0.2), Vector3(-SIZE.x * 0.5 + 0.2, TOP_Y + 0.01, 0), pad))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			sb.add_child(_box(Vector3(0.05, TOP_Y - 0.1, 0.05), Vector3(sx * (SIZE.x * 0.5 - 0.1), (TOP_Y - 0.1) * 0.5, sz * (SIZE.z * 0.5 - 0.08)), steel))
	sb.add_child(_box(Vector3(SIZE.x - 0.25, 0.03, 0.03), Vector3(0, 0.25, SIZE.z * 0.5 - 0.08), steel))
	sb.add_child(_box(Vector3(SIZE.x - 0.25, 0.03, 0.03), Vector3(0, 0.25, -SIZE.z * 0.5 + 0.08), steel))
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(SIZE.x, TOP_Y, SIZE.z)
	cs.shape = bs
	cs.position = Vector3(0, TOP_Y * 0.5, 0)
	sb.add_child(cs)
	var tag := Label3D.new()
	tag.text = "STAFF"
	tag.font_size = 40
	tag.pixel_size = 0.004
	tag.modulate = Color(0.85, 0.9, 0.9, 0.8)
	tag.position = Vector3(SIZE.x * 0.5 + 0.005, TOP_Y - 0.07, 0)
	tag.rotation.y = PI * 0.5
	sb.add_child(tag)
	return sb


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi
