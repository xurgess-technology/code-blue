extends RefCounted
## The second patient table on levels that only have one (loop, sweep 2). The hospital worker's
## levels list their tables in `level_info.tables`; the generated hospital of today, the fallback
## ward and the dev room have a single `table`, so the game puts a second one beside it.
##
## Placement is deterministic (every machine builds the same level and must agree on where the
## table is): a fixed list of offsets around the first table, the first one that is clear.
## "Clear" reads the level's tile rows when it has them (walkable floor under the whole table
## plus a margin, no wall between the two tables, away from the shelf, pod and clock), else a
## plain distance check against the level's known furniture spots.

const TABLE_SIZE := Vector3(2.4, 1.0, 1.1)
const MARGIN := 0.35
## Offsets in the first table's frame (x along its long axis): beside it first, then end to end.
const OFFSETS := [
	Vector3(0, 0, -2.6), Vector3(0, 0, 2.6), Vector3(0, 0, -2.2), Vector3(0, 0, 2.2),
	Vector3(3.3, 0, 0), Vector3(-3.3, 0, 0), Vector3(0, 0, -3.2), Vector3(0, 0, 3.2),
]
const WALKABLE := ".+PTM"

const BuilderPath := "res://scripts/hospital_builder.gd"


## Builds the second table into `level` and returns {position, yaw, kind: "patient"}, or {} when
## nothing around the first table is clear.
static func place_second(game: Node, level: Node3D, first: Vector3, yaw: float, info: Dictionary) -> Dictionary:
	if level == null:
		return {}
	var basis := Basis(Vector3.UP, yaw)
	var rows: PackedStringArray = info.get("rows", PackedStringArray())
	var keep_clear: Array = []
	var shelf: Dictionary = info.get("shelf", {})
	if shelf.has("position"):
		keep_clear.append(shelf.position)
	for key in ["clock", "pod"]:
		if info.has(key):
			keep_clear.append(info[key])
	var lectern: Dictionary = info.get("lectern", {})
	if lectern.has("position"):
		keep_clear.append(lectern.position)
	for e in info.get("containers", []):
		var n = e.get("node")
		if n != null and is_instance_valid(n) and n is Node3D:
			keep_clear.append((n as Node3D).position if not n.is_inside_tree() else (n as Node3D).global_position)
	for off in OFFSETS:
		var pos: Vector3 = first + basis * off
		pos.y = first.y
		if not rows.is_empty():
			if not _rows_clear(rows, pos, yaw) or not _rows_line_clear(rows, first, pos):
				continue
		elif not _inside_level_bounds(info, pos):
			continue
		var ok := true
		for k in keep_clear:
			if Vector2(k.x - pos.x, k.z - pos.z).length() < 1.9:
				ok = false
				break
		if not ok:
			continue
		_build_table(level, pos, yaw)
		return {"position": pos, "yaw": yaw, "kind": "patient"}
	return {}


## Every tile under the table's footprint (plus a margin to walk around it) is plain floor.
static func _rows_clear(rows: PackedStringArray, pos: Vector3, yaw: float) -> bool:
	var basis := Basis(Vector3.UP, yaw)
	var hx := TABLE_SIZE.x * 0.5 + MARGIN
	var hz := TABLE_SIZE.z * 0.5 + MARGIN
	var steps := 6
	for i in steps + 1:
		for j in steps + 1:
			var local := Vector3(lerpf(-hx, hx, float(i) / steps), 0.0, lerpf(-hz, hz, float(j) / steps))
			var p: Vector3 = pos + basis * local
			var t := C.world_to_tile(p)
			if t.y < 0 or t.y >= rows.size() or t.x < 0 or t.x >= rows[t.y].length():
				return false
			var ch := rows[t.y][t.x]
			# The table itself and doorways must stay free too: only plain floor counts.
			if ch != "." and ch != "P" and ch != "T":
				return false
	return true


## No wall tile on the straight line between the two tables (same room).
static func _rows_line_clear(rows: PackedStringArray, a: Vector3, b: Vector3) -> bool:
	var n := int(ceil(a.distance_to(b) / (C.TILE * 0.25))) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		var t := C.world_to_tile(p)
		if t.y < 0 or t.y >= rows.size() or t.x < 0 or t.x >= rows[t.y].length():
			return false
		if not WALKABLE.contains(rows[t.y][t.x]) and rows[t.y][t.x] != "O":
			return false
	return true


static func _inside_level_bounds(info: Dictionary, pos: Vector3) -> bool:
	var size = info.get("size")
	if not (size is Vector2i):
		return true
	var hx := TABLE_SIZE.x * 0.5 + 0.8
	var w := float(size.x) * C.TILE
	var d := float(size.y) * C.TILE
	return pos.x > hx and pos.z > hx and pos.x < w - hx and pos.z < d - hx


static func _build_table(level: Node3D, pos: Vector3, yaw: float) -> void:
	var sb := StaticBody3D.new()
	sb.name = "OperatingTable2"
	sb.collision_layer = C.L_WORLD
	sb.collision_mask = 0
	sb.position = pos
	sb.rotation.y = yaw
	var piece: Node3D = null
	if ResourceLoader.exists(BuilderPath):
		var builder: GDScript = load(BuilderPath)
		if builder.has_method("_make_operating_table"):
			piece = builder._make_operating_table()
	if piece == null:
		piece = _primitive_table()
	sb.add_child(piece)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = piece.get_meta("collider_size", TABLE_SIZE)
	cs.shape = box
	cs.position = Vector3(0.0, float(piece.get_meta("collider_y", box.size.y * 0.5)), 0.0)
	sb.add_child(cs)
	level.add_child(sb)


static func _primitive_table() -> Node3D:
	var n := Node3D.new()
	n.name = "OperatingTable"
	var top := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(2.2, 0.14, 0.95)
	top.mesh = tm
	top.position = Vector3(0, 0.95, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.82, 0.84)
	mat.roughness = 0.35
	top.material_override = mat
	n.add_child(top)
	var leg := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.5, 0.75, 0.5)
	leg.mesh = lm
	leg.position = Vector3(0, 0.38, 0)
	n.add_child(leg)
	return n
