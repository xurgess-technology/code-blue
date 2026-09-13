
extends RefCounted
## The pre-sweep-2 builder, kept for hand-made tile maps without furniture data
## (tools/monster_lab.gd builds its corridor through HospitalBuilder.build, which forwards here).

## Builds the runtime 3D level from a MapGen dictionary. Pure code, no .tscn, headless-safe.
##
## Everything visual is a primitive stand-in built by a small `_make_*()` factory. The asset
## agent replaces those one at a time: each factory first asks the `Assets` autoload for a
## model under a stable key (see ASSET_KEYS) and only falls back to primitives when it has none.

const MG := preload("res://scripts/mapgen.gd")
const FridgeScript := preload("res://scripts/containers/med_fridge.gd")
const DrawerUnitScript := preload("res://scripts/containers/drawer_unit.gd")
const StationScript := preload("res://scripts/containers/station_drawers.gd")
const TraumaBagScript := preload("res://scripts/containers/trauma_bag.gd")
const PegboardScript := preload("res://scripts/containers/pegboard.gd")
const GUIDE_MODELS_PATH := "res://scripts/guide/guide_models.gd"

## Rooms where nothing is ever placed loose and nothing needed may spawn.
const SAFE_ROOMS := ["or", "anteroom", "clockin"]
## Share of beds that get an over-bed tray table.
const BED_TRAY_EVERY := 5
const CORRIDOR_FLOOR_ANCHORS := 8

## Assets autoload keys each factory asks for before falling back to primitives.
## `prop/ivstand` and `light_fixture` do not exist in the asset pack (see ASSETS.md),
## so those two are always the primitive versions.
const ASSET_KEYS := {
	"bed": "prop/bed", "cabinet": "prop/cabinet", "operating_table": "prop/table_op",
	"time_clock": "prop/clock", "regen_pod": "prop/pod", "gurney": "prop/gurney",
	"wheelchair": "prop/wheelchair", "vending": "prop/vending", "bin": "prop/bin",
	"locker": "prop/locker", "screen": "prop/screen",
	"floor": "mat/floor", "wall": "mat/wall", "ceiling": "mat/ceiling",
}

## Deliberately dim and sparse: the hospital should read as half-abandoned, with
## pools of light and long dark stretches between them, not as a working ward.
const LIGHT_RANGE := 5.2
const LIGHT_ENERGY := 1.15
## Share of fixtures that are steady / flickering / dead. Most are dead.
const LIGHT_STEADY_CHANCE := 0.30
const LIGHT_FLICKER_CHANCE := 0.62   # cumulative: 0.30..0.62 flicker, the rest are dead
const MAX_SIGNS := 40
const NAV_AGENT_RADIUS := 0.45
const SIGN_H := 2.45

const DEPARTMENTS := [
	"RADIOLOGY", "WARD A", "WARD B", "SUPPLY", "ONCOLOGY", "ICU",
	"PHARMACY", "LAB", "PATHOLOGY", "RECOVERY", "ADMIN", "THEATRE",
]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Build the level. `info` is filled with:
##   player_spawns / tool_spawns / monster_spawns : Array[Vector3]
##   table / clock / pod : Vector3
##   lights : Array[Dictionary] ({tile, position, mode, node})
##   size : Vector2i, rows : PackedStringArray, nav_region : NavigationRegion3D
##   containers : Array[{id, type, room_kind, node, position, slots}]
##   loose_anchors : Array[{position, yaw, surface, room_kind}]
##   shelf / lectern : {position, yaw} (floor point about 0.25 m off the wall, yaw faces the room)
##   lectern_node : the lectern StaticBody3D
static func build(gen: Dictionary, info: Dictionary) -> Node3D:
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length()
	var seed: int = gen.get("seed", 0)

	var root := Node3D.new()
	root.name = "Hospital"

	info["size"] = Vector2i(w, h)
	info["rows"] = rows
	var player_spawns: Array[Vector3] = []
	var tool_spawns: Array[Vector3] = []
	var monster_spawns: Array[Vector3] = []
	var table_tiles: Array[Vector2i] = []
	info["table"] = Vector3.ZERO
	info["clock"] = Vector3.ZERO
	info["pod"] = Vector3.ZERO

	# ---- floor / ceiling -------------------------------------------------
	var floor_st := SurfaceTool.new()
	floor_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ceil_st := SurfaceTool.new()
	ceil_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ty in h:
		for tx in w:
			if _at(rows, tx, ty) == "#":
				continue
			_floor_quad(floor_st, tx, ty, 0.0, true)
			_floor_quad(ceil_st, tx, ty, C.WALL_H, false)
	floor_st.generate_tangents()
	ceil_st.generate_tangents()
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	floor_mi.mesh = floor_st.commit()
	floor_mi.material_override = _surface_mat("mat/floor", Color(0.30, 0.32, 0.33), 0.9)
	root.add_child(floor_mi)
	var ceil_mi := MeshInstance3D.new()
	ceil_mi.name = "Ceiling"
	ceil_mi.mesh = ceil_st.commit()
	ceil_mi.material_override = _surface_mat("mat/ceiling", Color(0.20, 0.21, 0.22), 0.95)
	root.add_child(ceil_mi)

	# ---- walls -----------------------------------------------------------
	var wall_st := SurfaceTool.new()
	wall_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_faces := PackedVector3Array()
	for ty in h:
		for tx in w:
			if _at(rows, tx, ty) != "#":
				continue
			for d in MG.DIRS:
				var nx := tx + d.x
				var ny := ty + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if _at(rows, nx, ny) == "#":
					continue  # never emit a face between two wall tiles
				_wall_quad(wall_st, wall_faces, tx, ty, d)
	wall_st.generate_tangents()
	var wall_mi := MeshInstance3D.new()
	wall_mi.name = "Walls"
	wall_mi.mesh = wall_st.commit()
	wall_mi.material_override = _surface_mat("mat/wall", Color(0.52, 0.55, 0.53), 0.85)
	root.add_child(wall_mi)

	# ---- world collision -------------------------------------------------
	var body := StaticBody3D.new()
	body.name = "WorldCollision"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	var wall_shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(wall_faces)
	wall_shape.shape = concave
	wall_shape.name = "WallTrimesh"
	body.add_child(wall_shape)
	body.add_child(_box_shape(
		Vector3(w * C.TILE, 0.4, h * C.TILE),
		Vector3(w * C.TILE * 0.5, -0.2, h * C.TILE * 0.5), "FloorBox"))
	body.add_child(_box_shape(
		Vector3(w * C.TILE, 0.4, h * C.TILE),
		Vector3(w * C.TILE * 0.5, C.WALL_H + 0.2, h * C.TILE * 0.5), "CeilingBox"))
	root.add_child(body)

	# ---- furniture, props, markers --------------------------------------
	var furniture := Node3D.new()
	furniture.name = "Furniture"
	root.add_child(furniture)
	var room_at := _room_lookup(gen.get("rooms", []))
	var anchors: Array = []
	for ty in h:
		for tx in w:
			var c := _at(rows, tx, ty)
			match c:
				"P":
					player_spawns.append(C.tile_to_world(tx, ty))
				"T":
					tool_spawns.append(C.tile_to_world(tx, ty))
				"M":
					monster_spawns.append(C.tile_to_world(tx, ty))
				"b":
					var bed := _make_bed()
					_add_piece(furniture, bed, C.tile_to_world(tx, ty), 0.0)
					if absi(tx * 7 + ty * 13 + seed) % BED_TRAY_EVERY == 0:
						var rk := _kind_at(room_at, tx, ty)
						if not SAFE_ROOMS.has(rk):
							_add_bed_tray(furniture, bed, Vector2i(tx, ty), rk, anchors)
				"c":
					_add_piece(furniture, _make_cabinet(), C.tile_to_world(tx, ty), _wall_facing(rows, tx, ty))
				"K":
					var pk := C.tile_to_world(tx, ty)
					info["clock"] = pk
					_add_piece(furniture, _make_time_clock(), pk, _wall_facing(rows, tx, ty))
				"C":
					var pc := C.tile_to_world(tx, ty)
					info["pod"] = pc
					_add_piece(furniture, _make_regen_pod(), pc, _wall_facing(rows, tx, ty))
				"O":
					table_tiles.append(Vector2i(tx, ty))
	if table_tiles.size() >= 2:
		var a := table_tiles[0]
		var b := table_tiles[table_tiles.size() - 1]
		var mid := C.tile_to_world((a.x + b.x) * 0.5, (a.y + b.y) * 0.5)
		info["table"] = mid
		_add_piece(furniture, _make_operating_table(), mid, 0.0)

	var props_root := Node3D.new()
	props_root.name = "Props"
	root.add_child(props_root)
	for p in gen.get("props", []):
		var t: Vector2i = p.tile
		var node := _make_prop(p.kind)
		if node != null:
			var yaw := _yaw_from_prop_rot(float(p.rot))
			_add_piece(props_root, node, C.tile_to_world(t.x, t.y), yaw)
			if p.kind == "gurney" and not SAFE_ROOMS.has(_kind_at(room_at, t.x, t.y)):
				anchors.append({"position": C.tile_to_world(t.x, t.y, _surface_top(node)), "yaw": yaw,
						"surface": "gurney", "room_kind": _kind_at(room_at, t.x, t.y)})

	_build_containers(root, gen, info, room_at, anchors)
	_add_floor_anchors(gen, room_at, anchors)
	info["loose_anchors"] = anchors
	_place_shelf_and_lectern(root, gen, info)

	info["player_spawns"] = player_spawns
	info["tool_spawns"] = tool_spawns
	info["monster_spawns"] = monster_spawns

	# ---- lights ----------------------------------------------------------
	var lights_root := Node3D.new()
	lights_root.name = "Lights"
	root.add_child(lights_root)
	var lrng := MG.Rng.new((seed ^ 0x5f356495) & 0xFFFFFFFF)
	var light_info: Array[Dictionary] = []
	for l in gen.get("lights", []):
		var roll := lrng.nextf()
		var mode := 0 if roll < LIGHT_STEADY_CHANCE else (1 if roll < LIGHT_FLICKER_CHANCE else 2)
		var pos := C.tile_to_world(l.x, l.y)
		var node := _make_light_fixture(mode, ((seed * 73856093) ^ (l.x * 19349663) ^ (l.y * 83492791)) & 0x7FFFFFFF)
		node.name = "Fixture_%d_%d" % [l.x, l.y]
		node.position = pos
		node.add_to_group("fixture")
		node.set_meta("mode", mode)
		node.set_meta("tile", l)
		lights_root.add_child(node)
		light_info.append({"tile": l, "position": pos, "mode": mode, "node": node})
	info["lights"] = light_info

	# ---- signage ---------------------------------------------------------
	root.add_child(_build_signs(rows, w, h, seed))

	# ---- navigation ------------------------------------------------------
	var nav := _build_nav(rows, w, h)
	root.add_child(nav)
	info["nav_region"] = nav

	return root


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

static func _at(rows: PackedStringArray, x: int, y: int) -> String:
	if x < 0 or y < 0 or y >= rows.size() or x >= rows[y].length():
		return "#"
	return rows[y][x]


static func _walkable(rows: PackedStringArray, x: int, y: int) -> bool:
	return MG.is_walkable_char(_at(rows, x, y))


## One tile of floor (up = true) or ceiling. UVs are in world metres: the Assets PBR
## sets carry their own uv1_scale (~2 repeats per metre) and expect world-unit UVs.
static func _floor_quad(st: SurfaceTool, tx: int, ty: int, y: float, up: bool) -> void:
	var x0 := tx * C.TILE
	var x1 := x0 + C.TILE
	var z0 := ty * C.TILE
	var z1 := z0 + C.TILE
	var a := Vector3(x0, y, z0)
	var b := Vector3(x1, y, z0)
	var c := Vector3(x1, y, z1)
	var d := Vector3(x0, y, z1)
	var ua := Vector2(x0, z0)
	var ub := Vector2(x1, z0)
	var uc := Vector2(x1, z1)
	var ud := Vector2(x0, z1)
	var n := Vector3.UP if up else Vector3.DOWN
	if up:
		_tri(st, a, b, c, ua, ub, uc, n)
		_tri(st, a, c, d, ua, uc, ud, n)
	else:
		_tri(st, a, c, b, ua, uc, ub, n)
		_tri(st, a, d, c, ua, ud, uc, n)


## The face of wall tile (tx, ty) that looks toward its open neighbour in direction `d`.
static func _wall_quad(st: SurfaceTool, faces: PackedVector3Array, tx: int, ty: int, d: Vector2i) -> void:
	var n := Vector3(d.x, 0.0, d.y)
	var r := n.cross(Vector3.UP)
	var mid := C.tile_to_world(tx, ty) + n * (C.TILE * 0.5)
	var p0 := mid - r * (C.TILE * 0.5)
	var v0 := Vector3(p0.x, 0.0, p0.z)
	var v1 := v0 + r * C.TILE
	var v2 := v1 + Vector3(0.0, C.WALL_H, 0.0)
	var v3 := v0 + Vector3(0.0, C.WALL_H, 0.0)
	# World-metre UVs, continuous along the wall run: u is the distance along the wall,
	# v is the height (0 at the ceiling, WALL_H at the floor).
	var u0 := v0.x * absf(r.x) + v0.z * absf(r.z)
	var u1 := u0 + (C.TILE if (r.x + r.z) > 0.0 else -C.TILE)
	var t0 := Vector2(u0, C.WALL_H)
	var t1 := Vector2(u1, C.WALL_H)
	var t2 := Vector2(u1, 0.0)
	var t3 := Vector2(u0, 0.0)
	_tri(st, v0, v1, v2, t0, t1, t2, n)
	_tri(st, v0, v2, v3, t0, t2, t3, n)
	faces.append_array([v0, v1, v2, v0, v2, v3])


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, n: Vector3) -> void:
	st.set_normal(n)
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(uc)
	st.add_vertex(c)


static func _box_shape(size: Vector3, pos: Vector3, nm: String) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	cs.name = nm
	return cs


static func _mat(albedo: Color, rough := 0.8, emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = 0.0
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


static func _box(size: Vector3, pos: Vector3, col: Color, rough := 0.8) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = _mat(col, rough)
	return mi


static func _cyl(radius: float, height: float, pos: Vector3, col: Color, rough := 0.6) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 10
	mi.mesh = cm
	mi.position = pos
	mi.material_override = _mat(col, rough)
	return mi


## Wrap a factory's visual node in a StaticBody3D with a box collider and drop it in the world.
static func _add_piece(parent: Node3D, piece: Node3D, pos: Vector3, rot: float) -> void:
	var size: Vector3 = piece.get_meta("collider_size", Vector3(1.0, 1.0, 1.0))
	var cy: float = piece.get_meta("collider_y", size.y * 0.5)
	var sb := StaticBody3D.new()
	sb.name = piece.name
	sb.collision_layer = C.L_WORLD
	sb.collision_mask = 0
	sb.position = pos
	sb.rotation.y = rot
	sb.add_child(piece)
	sb.add_child(_box_shape(size, Vector3(0.0, cy, 0.0), "Shape"))
	parent.add_child(sb)


## Godot yaw that points a wall-hugging piece away from the wall it touches.
## Models (and the primitives here) face -Z at yaw 0.
static func _wall_facing(rows: PackedStringArray, tx: int, ty: int) -> float:
	if _at(rows, tx, ty - 1) == "#":
		return PI          # wall to the north -> face south
	if _at(rows, tx, ty + 1) == "#":
		return 0.0         # wall to the south -> face north
	if _at(rows, tx - 1, ty) == "#":
		return -PI / 2.0   # wall to the west -> face east
	return PI / 2.0        # wall to the east -> face west


## MapGen prop rotations use the TS screen convention (0 = +X, +PI/2 = +Z). Convert to a
## Godot yaw for a model whose forward is -Z.
static func _yaw_from_prop_rot(rot: float) -> float:
	return -(rot + PI / 2.0)


## A tiling PBR set from the Assets autoload, or a flat placeholder. The asset materials are
## cached and shared, so they are used as-is; only the fallback is tuned here (one repeat per
## map tile, which is what a placeholder texture would want).
static func _surface_mat(key: String, albedo: Color, rough: float) -> Material:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var a = (loop as SceneTree).root.get_node_or_null("Assets")
		if a != null and a.has_method("material") and a.has_method("has") and a.call("has", key):
			var m = a.call("material", key)
			if m is Material:
				return m
	var fallback := _mat(albedo, rough)
	fallback.uv1_scale = Vector3.ONE / C.TILE
	return fallback


## Transform of `node` relative to `root` (both out of the tree, so no global_transform).
static func _rel_xform(root: Node3D, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n := node
	while n != null and n != root:
		t = n.transform * t
		n = n.get_parent() as Node3D
	return t


## Union of every mesh AABB under `root`, in root space.
static func _mesh_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := _rel_xform(root, mi) * mi.mesh.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


## Size a spawned model's box collider from its own geometry. The footprint is capped at one
## tile so an oversized model never seals off the tile next door.
static func _fit_collider(root: Node3D) -> void:
	var box := _mesh_aabb(root)
	if box.size.y <= 0.0:
		root.set_meta("collider_size", Vector3(0.8, 1.0, 0.8))
		root.set_meta("collider_y", 0.5)
		return
	var cap := C.TILE * 0.95
	root.set_meta("collider_size", Vector3(
		clampf(box.size.x, 0.2, cap), maxf(box.size.y, 0.2), clampf(box.size.z, 0.2, cap)))
	root.set_meta("collider_y", box.position.y + box.size.y * 0.5)


## Wrap an Assets model in a piece node with a collider fitted to it. Null when the key
## does not resolve, so every factory can fall through to its primitive.
static func _asset_piece(key: String, nm: String) -> Node3D:
	var a := _asset(key)
	if a == null:
		return null
	var n := Node3D.new()
	n.name = nm
	n.add_child(a)
	_fit_collider(n)
	return n


## Assets autoload lookup, safe when the autoload is missing (unit tests, tools).
static func _asset(key: String) -> Node3D:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var a = (loop as SceneTree).root.get_node_or_null("Assets")
		if a != null and a.has_method("spawn"):
			if a.has_method("has") and not a.call("has", key):
				return null
			var n = a.call("spawn", key)
			if n is Node3D:
				return n
	return null


# ---------------------------------------------------------------------------
# Furniture factories - the asset agent replaces the bodies of these.
# Each returns a visual-only Node3D with `collider_size` / `collider_y` metadata.
# ---------------------------------------------------------------------------

static func _piece(nm: String, size: Vector3, cy := -1.0) -> Node3D:
	var n := Node3D.new()
	n.name = nm
	n.set_meta("collider_size", size)
	n.set_meta("collider_y", size.y * 0.5 if cy < 0.0 else cy)
	return n


static func _make_bed() -> Node3D:
	var a := _asset_piece("prop/bed", "Bed")
	if a != null:
		return a
	var n := _piece("Bed", Vector3(0.95, 0.7, 1.35))
	n.add_child(_box(Vector3(0.9, 0.12, 1.3), Vector3(0, 0.55, 0), Color(0.85, 0.86, 0.88), 0.5))
	n.add_child(_box(Vector3(0.8, 0.1, 1.15), Vector3(0, 0.63, 0), Color(0.72, 0.76, 0.80), 0.9))
	n.add_child(_box(Vector3(0.85, 0.45, 0.08), Vector3(0, 0.75, -0.62), Color(0.55, 0.57, 0.60), 0.4))
	n.add_child(_box(Vector3(0.85, 0.30, 0.08), Vector3(0, 0.67, 0.62), Color(0.55, 0.57, 0.60), 0.4))
	for sx in [-0.35, 0.35]:
		for sz in [-0.55, 0.55]:
			n.add_child(_cyl(0.04, 0.5, Vector3(sx, 0.25, sz), Color(0.40, 0.42, 0.45)))
	return n


static func _make_cabinet() -> Node3D:
	var a := _asset_piece("prop/cabinet", "Cabinet")
	if a != null:
		return a
	var n := _piece("Cabinet", Vector3(1.2, 1.7, 1.0))
	n.add_child(_box(Vector3(1.15, 1.65, 0.95), Vector3(0, 0.83, 0), Color(0.62, 0.63, 0.60), 0.7))
	for y in [0.45, 1.0, 1.45]:
		n.add_child(_box(Vector3(0.5, 0.04, 0.06), Vector3(0.0, y, -0.49), Color(0.30, 0.31, 0.33), 0.3))
	return n


static func _make_operating_table() -> Node3D:
	var a := _asset_piece("prop/table_op", "OperatingTable")
	if a != null:
		return a
	var n := _piece("OperatingTable", Vector3(2.4, 1.0, 1.1))
	n.add_child(_box(Vector3(2.2, 0.14, 0.95), Vector3(0, 0.95, 0), Color(0.78, 0.82, 0.84), 0.35))
	n.add_child(_box(Vector3(0.5, 0.75, 0.5), Vector3(0, 0.38, 0), Color(0.45, 0.47, 0.50), 0.4))
	n.add_child(_cyl(0.45, 0.12, Vector3(0, 0.06, 0), Color(0.35, 0.37, 0.40)))
	n.add_child(_box(Vector3(0.5, 0.05, 0.5), Vector3(0.0, 2.55, 0.0), Color(0.9, 0.9, 0.85), 0.2))
	return n


## The asset clock is a small desk alarm clock, so it gets a primitive shelf to stand on.
static func _make_time_clock() -> Node3D:
	var n := _piece("TimeClock", Vector3(0.8, 1.2, 0.6), 1.1)
	var model := _asset("prop/clock")
	if model != null:
		n.add_child(_box(Vector3(0.6, 1.25, 0.3), Vector3(0, 0.62, 0), Color(0.34, 0.36, 0.40), 0.7))
		model.position = Vector3(0, 1.25, 0)
		n.add_child(model)
		_fit_collider(n)
		return n
	n.add_child(_box(Vector3(0.55, 0.8, 0.35), Vector3(0, 1.35, 0), Color(0.30, 0.32, 0.36), 0.6))
	var face := _box(Vector3(0.38, 0.28, 0.06), Vector3(0.0, 1.55, -0.19), Color(0.05, 0.08, 0.06), 0.2)
	face.material_override = _mat(Color(0.05, 0.10, 0.07), 0.2, Color(0.2, 1.0, 0.5), 1.6)
	n.add_child(face)
	n.add_child(_box(Vector3(0.30, 0.06, 0.10), Vector3(0.0, 1.18, -0.16), Color(0.6, 0.6, 0.6), 0.4))
	return n


static func _make_regen_pod() -> Node3D:
	var a := _asset_piece("prop/pod", "RegenPod")
	if a != null:
		return a
	var n := _piece("RegenPod", Vector3(1.0, 2.1, 1.0))
	n.add_child(_cyl(0.48, 0.15, Vector3(0, 0.07, 0), Color(0.28, 0.30, 0.33)))
	var glass := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.42
	cap.height = 1.9
	cap.radial_segments = 12
	glass.mesh = cap
	glass.position = Vector3(0, 1.05, 0)
	var gm := _mat(Color(0.35, 0.75, 0.70, 0.45), 0.15, Color(0.2, 0.9, 0.8), 0.9)
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.material_override = gm
	n.add_child(glass)
	n.add_child(_cyl(0.5, 0.1, Vector3(0, 2.05, 0), Color(0.28, 0.30, 0.33)))
	return n


# ---------------------------------------------------------------------------
# Prop factories. Primitives face -Z, the same way spawned models do.
# ---------------------------------------------------------------------------

static func _make_prop(kind: String) -> Node3D:
	match kind:
		"gurney": return _make_gurney()
		"wheelchair": return _make_wheelchair()
		"ivstand": return _make_ivstand()
		"vending": return _make_vending()
		"bin": return _make_bin()
		"locker": return _make_locker()
		"screen": return _make_screen()
	return null


static func _make_gurney() -> Node3D:
	var a := _asset_piece("prop/gurney", "Gurney")
	if a != null:
		return a
	var n := _piece("Gurney", Vector3(0.7, 0.9, 1.3))
	n.set_meta("surface_top", 0.83)
	n.add_child(_box(Vector3(0.62, 0.1, 1.25), Vector3(0, 0.72, 0), Color(0.70, 0.73, 0.76), 0.4))
	n.add_child(_box(Vector3(0.5, 0.08, 1.1), Vector3(0, 0.79, 0), Color(0.55, 0.62, 0.66), 0.9))
	n.add_child(_box(Vector3(0.55, 0.35, 0.06), Vector3(0, 0.9, 0.6), Color(0.5, 0.52, 0.55), 0.4))
	for sx in [-0.25, 0.25]:
		for sz in [-0.5, 0.5]:
			n.add_child(_cyl(0.06, 0.62, Vector3(sx, 0.34, sz), Color(0.38, 0.40, 0.42)))
	return n


static func _make_wheelchair() -> Node3D:
	var a := _asset_piece("prop/wheelchair", "Wheelchair")
	if a != null:
		return a
	var n := _piece("Wheelchair", Vector3(0.8, 1.0, 0.8))
	n.add_child(_box(Vector3(0.5, 0.07, 0.5), Vector3(0, 0.48, 0), Color(0.22, 0.24, 0.28), 0.8))
	n.add_child(_box(Vector3(0.5, 0.55, 0.07), Vector3(0, 0.76, 0.22), Color(0.22, 0.24, 0.28), 0.8))
	for sx in [-0.32, 0.32]:
		var wheel := _cyl(0.3, 0.05, Vector3(sx, 0.3, 0.0), Color(0.15, 0.15, 0.17))
		wheel.rotation.z = PI / 2.0
		n.add_child(wheel)
	n.add_child(_cyl(0.02, 0.4, Vector3(0.0, 0.95, 0.2), Color(0.45, 0.46, 0.5)))
	return n


## No CC0 IV stand exists (see ASSETS.md), so this one is always the primitive.
static func _make_ivstand() -> Node3D:
	var n := _piece("IVStand", Vector3(0.4, 1.9, 0.4))
	n.add_child(_cyl(0.18, 0.05, Vector3(0, 0.03, 0), Color(0.35, 0.36, 0.38)))
	n.add_child(_cyl(0.025, 1.75, Vector3(0, 0.9, 0), Color(0.72, 0.74, 0.78), 0.3))
	n.add_child(_box(Vector3(0.16, 0.26, 0.1), Vector3(0.11, 1.6, 0), Color(0.85, 0.88, 0.75, 0.9), 0.2))
	return n


static func _make_vending() -> Node3D:
	var a := _asset_piece("prop/vending", "Vending")
	if a != null:
		return a
	var n := _piece("Vending", Vector3(1.0, 1.9, 0.75))
	n.add_child(_box(Vector3(0.95, 1.85, 0.7), Vector3(0, 0.93, 0), Color(0.20, 0.28, 0.34), 0.6))
	var glass := _box(Vector3(0.62, 1.25, 0.05), Vector3(-0.12, 1.05, -0.36), Color(0.4, 0.6, 0.7), 0.2)
	glass.material_override = _mat(Color(0.15, 0.35, 0.40), 0.2, Color(0.4, 0.85, 0.95), 0.8)
	n.add_child(glass)
	n.add_child(_box(Vector3(0.18, 0.5, 0.05), Vector3(0.33, 1.2, -0.36), Color(0.1, 0.1, 0.12), 0.5))
	return n


static func _make_bin() -> Node3D:
	var a := _asset_piece("prop/bin", "Bin")
	if a != null:
		return a
	var n := _piece("Bin", Vector3(0.7, 0.9, 0.7))
	n.add_child(_cyl(0.31, 0.8, Vector3(0, 0.4, 0), Color(0.25, 0.30, 0.28), 0.8))
	n.add_child(_cyl(0.33, 0.06, Vector3(0, 0.83, 0), Color(0.15, 0.19, 0.18), 0.6))
	return n


static func _make_locker() -> Node3D:
	var a := _asset_piece("prop/locker", "Locker")
	if a != null:
		return a
	var n := _piece("Locker", Vector3(0.95, 1.9, 0.65))
	n.add_child(_box(Vector3(0.9, 1.85, 0.6), Vector3(0, 0.93, 0), Color(0.33, 0.40, 0.42), 0.7))
	n.add_child(_box(Vector3(0.04, 1.7, 0.02), Vector3(0.0, 0.93, -0.31), Color(0.18, 0.22, 0.24), 0.5))
	n.add_child(_box(Vector3(0.3, 0.06, 0.03), Vector3(0.0, 1.75, -0.32), Color(0.75, 0.76, 0.7), 0.4))
	return n


## The asset screen is a desk monitor; lift it to wall height so it reads as a ward display.
static func _make_screen() -> Node3D:
	var model := _asset("prop/screen")
	if model != null:
		var m := Node3D.new()
		m.name = "Screen"
		model.position = Vector3(0, 1.45, 0)
		m.add_child(model)
		_fit_collider(m)
		return m
	var n := _piece("Screen", Vector3(1.1, 0.8, 0.25), 1.7)
	n.add_child(_box(Vector3(1.05, 0.72, 0.08), Vector3(0, 1.7, 0), Color(0.12, 0.13, 0.15), 0.4))
	var glow := _box(Vector3(0.95, 0.6, 0.03), Vector3(0, 1.7, -0.06), Color(0.1, 0.3, 0.3), 0.2)
	glow.material_override = _mat(Color(0.08, 0.22, 0.25), 0.2, Color(0.3, 0.8, 0.9), 1.2)
	n.add_child(glow)
	n.add_child(_cyl(0.03, 0.5, Vector3(0, 1.2, 0.02), Color(0.3, 0.31, 0.33)))
	return n


static func _make_light_fixture(mode: int, light_seed: int) -> Node3D:
	var n := Node3D.new()
	n.name = "Fixture"
	var panel: MeshInstance3D = null
	var a := _asset("light_fixture")
	if a != null:
		n.add_child(a)
		for child in a.find_children("Panel", "MeshInstance3D", true, false):
			panel = child
			break
	else:
		panel = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(C.TILE * 0.62, 0.06, C.TILE * 0.62)
		panel.mesh = bm
		panel.position = Vector3(0, C.WALL_H - 0.05, 0)
		panel.name = "Panel"
		var lit := mode != 2
		panel.material_override = _mat(
			Color(0.85, 0.88, 0.85) if lit else Color(0.25, 0.26, 0.25), 0.35,
			Color(1.0, 0.97, 0.90), 2.4 if lit else 0.0)
		n.add_child(panel)
	var bulb := OmniLight3D.new()
	bulb.name = "Bulb"
	bulb.position = Vector3(0, C.WALL_H - 0.35, 0)
	bulb.omni_range = LIGHT_RANGE
	bulb.light_energy = 0.0 if mode == 2 else LIGHT_ENERGY
	bulb.light_color = Color(1.0, 0.96, 0.90)
	# Punchier in fog than in air: this is what makes each fixture read as a
	# hanging pool of light rather than a flat wash on the floor.
	bulb.light_volumetric_fog_energy = 2.0
	bulb.shadow_enabled = false  # the flashlight is the only shadow caster
	# The flicker system finds fixtures by group and reads these off the light itself.
	bulb.add_to_group("fixture")
	bulb.set_meta("mode", mode)
	bulb.set_meta("seed", light_seed)
	if panel != null:
		bulb.set_meta("panel", panel)
	n.add_child(bulb)
	return n


# ---------------------------------------------------------------------------
# Containers, loose anchors, OR shelf spot, lectern
# ---------------------------------------------------------------------------

## tile key (y * 4096 + x) -> room dictionary, for every tile inside a room.
static func _room_lookup(rooms: Array) -> Dictionary:
	var out := {}
	for r in rooms:
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				out[y * 4096 + x] = r
	return out


static func _kind_at(room_at: Dictionary, x: int, y: int) -> String:
	var r = room_at.get(y * 4096 + x, null)
	return "corridor" if r == null else String(r.kind)


## World transform of a wall-standing piece: origin on the floor at the wall face, -Z into the room.
static func _site_xform(tile: Vector2i, wall: Vector2i) -> Transform3D:
	var yaw := atan2(float(wall.x), float(wall.y))
	var pos := C.tile_to_world(tile.x, tile.y) + Vector3(wall.x, 0.0, wall.y) * (C.TILE * 0.5)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


## Top of the flat surface of a furniture piece: explicit meta for primitives, else the collider top.
static func _surface_top(piece: Node3D) -> float:
	if piece.has_meta("surface_top"):
		return float(piece.get_meta("surface_top"))
	var size: Vector3 = piece.get_meta("collider_size", Vector3.ONE)
	var cy: float = piece.get_meta("collider_y", size.y * 0.5)
	return cy + size.y * 0.5


static func _build_containers(root: Node3D, gen: Dictionary, info: Dictionary, room_at: Dictionary, anchors: Array) -> void:
	var holder := Node3D.new()
	holder.name = "Containers"
	root.add_child(holder)
	var entries: Array = []
	for s in gen.get("containers", []):
		var tile: Vector2i = s.tile
		var type: String = s.type
		var xf := _site_xform(tile, s.wall)
		var id0 := "ct_%d_%d_0" % [tile.x, tile.y]
		var node: Node3D = null
		var list: Array = []
		match type:
			"med_fridge":
				node = FridgeScript.create(id0)
				list = [node]
			"drawer_unit":
				node = DrawerUnitScript.create_unit(tile)
				list = node.get_meta("drawers")
			"station_drawers":
				node = StationScript.create_unit(tile)
				list = node.get_meta("drawers")
			"trauma_bag":
				node = TraumaBagScript.create(id0)
				list = [node]
			"pegboard":
				node = PegboardScript.create(id0)
				list = [node]
		if node == null:
			continue
		node.transform = xf
		holder.add_child(node)
		for c in list:
			var ct: Node3D = c
			entries.append({
				"id": String(ct.get_meta("interact_id")), "type": type, "room_kind": String(s.room_kind),
				"node": ct, "position": (xf * ct.transform).origin if ct != node else xf.origin,
				"slots": ct.slot_count(),
			})
		for a in node.get_meta("anchors", []):
			var t: Transform3D = xf * (a.xform as Transform3D)
			anchors.append({"position": t.origin, "yaw": xf.basis.get_euler().y, "surface": a.surface,
					"room_kind": String(s.room_kind)})
	info["containers"] = entries


static func _add_bed_tray(parent: Node3D, bed: Node3D, tile: Vector2i, room_kind: String, anchors: Array) -> void:
	var top := maxf(_surface_top(bed) + 0.3, 0.92)
	var n := _piece("BedTray", Vector3(0.66, 0.05, 0.4), top - 0.025)
	var steel := _mat(Color(0.62, 0.65, 0.68), 0.35)
	steel.metallic = 0.7
	var add := func(size: Vector3, pos: Vector3) -> void:
		var b := _box(size, pos, Color.WHITE)
		b.material_override = steel
		n.add_child(b)
	add.call(Vector3(0.62, 0.025, 0.38), Vector3(0.0, top - 0.0125, 0.0))
	add.call(Vector3(0.62, 0.02, 0.01), Vector3(0.0, top + 0.01, -0.19))
	add.call(Vector3(0.62, 0.02, 0.01), Vector3(0.0, top + 0.01, 0.19))
	add.call(Vector3(0.04, top, 0.04), Vector3(0.62, top * 0.5, 0.0))
	add.call(Vector3(0.3, 0.012, 0.04), Vector3(0.47, top - 0.03, 0.0))
	add.call(Vector3(0.08, 0.03, 0.46), Vector3(0.62, 0.015, 0.0))
	var pos := C.tile_to_world(tile.x, tile.y) + Vector3(-0.05, 0.0, 0.3)
	_add_piece(parent, n, pos, 0.0)
	anchors.append({"position": pos + Vector3(0.0, top, 0.0), "yaw": 0.0, "surface": "tray", "room_kind": room_kind})


## Floor edges: a spot or two against a wall in each ordinary room, plus some along corridors.
static func _add_floor_anchors(gen: Dictionary, room_at: Dictionary, anchors: Array) -> void:
	var rows: PackedStringArray = gen.rows
	var seed: int = gen.get("seed", 0)
	var rng := MG.Rng.new((seed ^ 0x3c6ef372) & 0xFFFFFFFF)
	var blocked := {}
	for s in gen.get("containers", []):
		var t: Vector2i = s.tile
		var d: Vector2i = s.wall
		blocked[t.y * 4096 + t.x] = true
		blocked[(t.y - d.y) * 4096 + (t.x - d.x)] = true
	var edge_dir := func(x: int, y: int) -> Vector2i:
		if _at(rows, x, y) != "." or blocked.has(y * 4096 + x):
			return Vector2i.ZERO
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := _at(rows, x + dx, y + dy)
				if c == "+" or c == "T" or MG.PROP_CHARS.has(c):
					return Vector2i.ZERO
		for d in MG.DIRS:
			if _at(rows, x + d.x, y + d.y) == "#" and _walkable(rows, x - d.x, y - d.y):
				return d
		return Vector2i.ZERO
	var add := func(x: int, y: int, d: Vector2i, kind: String) -> void:
		var pos := C.tile_to_world(x, y) + Vector3(d.x, 0.0, d.y) * (C.TILE * 0.5 - 0.24)
		anchors.append({"position": pos, "yaw": atan2(float(d.x), float(d.y)), "surface": "floor", "room_kind": kind})
	for r in gen.get("rooms", []):
		if SAFE_ROOMS.has(r.kind):
			continue
		var cands: Array = []
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				var d: Vector2i = edge_dir.call(x, y)
				if d != Vector2i.ZERO and room_at.get((y - d.y) * 4096 + (x - d.x), null) == r:
					cands.append([x, y, d])
		rng.shuffle(cands)
		var want := 2 if r.w * r.h >= 30 else 1
		for i in mini(want, cands.size()):
			add.call(cands[i][0], cands[i][1], cands[i][2], String(r.kind))
	var corr: Array = []
	for y in rows.size():
		for x in rows[0].length():
			if room_at.has(y * 4096 + x):
				continue
			var d: Vector2i = edge_dir.call(x, y)
			if d != Vector2i.ZERO:
				corr.append([x, y, d])
	rng.shuffle(corr)
	var placed: Array[Vector2i] = []
	for c in corr:
		if placed.size() >= CORRIDOR_FLOOR_ANCHORS:
			break
		var p := Vector2i(c[0], c[1])
		var ok := true
		for q in placed:
			if absi(p.x - q.x) + absi(p.y - q.y) < 10:
				ok = false
				break
		if ok:
			placed.append(p)
			add.call(p.x, p.y, c[2], "corridor")


## Wall spots in a room: [tile, wall dir] for floor tiles with a room-bounding wall and no door beside them.
static func _wall_spots(rows: PackedStringArray, r: Dictionary) -> Array:
	var out: Array = []
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if _at(rows, x, y) != ".":
				continue
			var door := false
			for d in MG.DIRS:
				if _at(rows, x + d.x, y + d.y) == "+":
					door = true
			if door:
				continue
			for d in MG.DIRS:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if _at(rows, nx, ny) == "#" and not (nx >= r.x and nx < r.x + r.w and ny >= r.y and ny < r.y + r.h):
					out.append([Vector2i(x, y), d])
	return out


static func _spot(tile: Vector2i, d: Vector2i, off_wall: float) -> Dictionary:
	var pos := C.tile_to_world(tile.x, tile.y) + Vector3(d.x, 0.0, d.y) * (C.TILE * 0.5 - off_wall)
	return {"position": pos, "yaw": atan2(float(d.x), float(d.y))}


static func _place_shelf_and_lectern(root: Node3D, gen: Dictionary, info: Dictionary) -> void:
	var rows: PackedStringArray = gen.rows
	var table: Vector3 = info.get("table", Vector3.ZERO)
	for r in gen.get("rooms", []):
		if r.kind == "or" and not info.has("shelf"):
			# The wall spot nearest the table that keeps the doorways clear.
			var best: Dictionary = {}
			var best_d := INF
			for s in _wall_spots(rows, r):
				var spot := _spot(s[0], s[1], 0.25)
				var dd: float = Vector2(spot.position.x - table.x, spot.position.z - table.z).length()
				if dd < best_d - 0.001:
					best_d = dd
					best = spot
			if not best.is_empty():
				info["shelf"] = best
		elif r.kind == "clockin" and not info.has("lectern"):
			var keep: Array[Vector2i] = []
			var doors: Array[Vector2i] = []
			for y in range(r.y - 1, r.y + r.h + 1):
				for x in range(r.x - 1, r.x + r.w + 1):
					var c := _at(rows, x, y)
					if c == "P" or c == "K" or c == "C":
						keep.append(Vector2i(x, y))
					elif c == "+":
						doors.append(Vector2i(x, y))
			var center := Vector2(r.x + r.w * 0.5, r.y + r.h * 0.5)
			var best_tile := Vector2i(-1, -1)
			var best_wall := Vector2i.ZERO
			var best_d := INF
			for s in _wall_spots(rows, r):
				var t: Vector2i = s[0]
				var ok := true
				for k in keep:
					if absi(k.x - t.x) + absi(k.y - t.y) < 2:
						ok = false
				for dr in doors:
					if absi(dr.x - t.x) + absi(dr.y - t.y) < 3:
						ok = false
				if not ok:
					continue
				var dd := Vector2(t.x + 0.5, t.y + 0.5).distance_to(center)
				if dd < best_d - 0.001:
					best_d = dd
					best_tile = t
					best_wall = s[1]
			if best_tile.x >= 0:
				var spot := _spot(best_tile, best_wall, 0.3)
				info["lectern"] = spot
				var lectern := _make_lectern()
				var sb := StaticBody3D.new()
				sb.name = "Lectern"
				sb.collision_layer = C.L_WORLD
				sb.collision_mask = 0
				sb.position = spot.position
				sb.rotation.y = spot.yaw
				sb.add_child(lectern)
				_fit_collider(lectern)
				var size: Vector3 = lectern.get_meta("collider_size")
				sb.add_child(_box_shape(size, Vector3(0.0, lectern.get_meta("collider_y"), 0.0), "Shape"))
				root.add_child(sb)
				info["lectern_node"] = sb


## The guide worker's lectern when it exists, else a simple wooden reading stand.
static func _make_lectern() -> Node3D:
	if ResourceLoader.exists(GUIDE_MODELS_PATH):
		var s = load(GUIDE_MODELS_PATH)
		if s is GDScript:
			for m in (s as GDScript).get_script_method_list():
				if m.name == "make_lectern":
					var n = s.call("make_lectern")
					if n is Node3D:
						return n
					break
	var n := Node3D.new()
	n.name = "LecternFallback"
	var wood := Color(0.29, 0.2, 0.13)
	n.add_child(_box(Vector3(0.45, 0.05, 0.4), Vector3(0, 0.025, 0), wood))
	n.add_child(_box(Vector3(0.12, 1.0, 0.12), Vector3(0, 0.52, 0), wood))
	var top := _box(Vector3(0.52, 0.04, 0.4), Vector3(0, 1.08, 0), wood)
	top.rotation.x = -0.3
	n.add_child(top)
	return n


# ---------------------------------------------------------------------------
# Signage
# ---------------------------------------------------------------------------

static func _build_signs(rows: PackedStringArray, w: int, h: int, seed: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Signs"
	var cache := {}
	var count := 0

	# Exit signs where the outer ring turns a corner (the ends of each ring run).
	var exits := [
		Vector2i(2, 2), Vector2i(w - 3, 2), Vector2i(2, h - 3), Vector2i(w - 3, h - 3),
	]
	for e in exits:
		if count >= MAX_SIGNS:
			break
		if not _walkable(rows, e.x, e.y):
			continue
		var yaw := 0.0 if e.x < w / 2 else PI
		root.add_child(_sign_node("EXIT", C.tile_to_world(e.x, e.y), yaw, cache, true))
		count += 1

	# Department names over doors, sampled evenly so the budget is never blown.
	var doors: Array[Vector2i] = []
	for ty in range(1, h - 1):
		for tx in range(1, w - 1):
			if _at(rows, tx, ty) == "+":
				doors.append(Vector2i(tx, ty))
	var budget := MAX_SIGNS - count
	if doors.size() > 0 and budget > 0:
		var step := maxi(1, int(ceil(float(doors.size()) / float(budget))))
		var i := 0
		while i < doors.size() and count < MAX_SIGNS:
			var d := doors[i]
			# A door in a north/south wall run faces along Z; otherwise along X.
			var horizontal_run := _at(rows, d.x - 1, d.y) == "#" or _at(rows, d.x + 1, d.y) == "#"
			var yaw := 0.0 if horizontal_run else PI / 2.0
			var text: String = DEPARTMENTS[(d.x * 31 + d.y * 17 + seed) % DEPARTMENTS.size()]
			root.add_child(_sign_node(text, C.tile_to_world(d.x, d.y), yaw, cache, false))
			count += 1
			i += step
	return root


static func _sign_node(text: String, pos: Vector3, yaw: float, cache: Dictionary, is_exit: bool) -> Node3D:
	var n := Node3D.new()
	n.name = "Sign_" + text.replace(" ", "_")
	n.position = Vector3(pos.x, SIGN_H, pos.z)
	n.rotation.y = yaw
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.9, 0.26) if not is_exit else Vector2(0.7, 0.26)
	mi.mesh = qm
	var key := text + ("|exit" if is_exit else "|dept")
	var tex: ImageTexture = cache.get(key, null)
	if tex == null:
		var fg := Color(0.85, 1.0, 0.88) if is_exit else Color(0.92, 0.94, 0.96)
		var bg := Color(0.03, 0.22, 0.08) if is_exit else Color(0.06, 0.09, 0.14)
		tex = _text_texture(text, fg, bg)
		cache[key] = tex
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.emission_enabled = true
	m.emission_texture = tex
	m.emission = Color(0.25, 1.0, 0.45) if is_exit else Color(0.55, 0.75, 1.0)
	m.emission_energy_multiplier = 1.8
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	n.add_child(mi)
	return n


## Rasterise a short label into an ImageTexture with the fallback font. CPU only, so it
## works under --headless where no rendering device is available.
static func _text_texture(text: String, fg: Color, bg: Color, iw := 192, ih := 56) -> ImageTexture:
	var img := Image.create(iw, ih, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	var font := ThemeDB.fallback_font
	var ts := TextServerManager.get_primary_interface()
	if font != null and ts != null:
		var rids := font.get_rids()
		if rids.size() > 0:
			var rid: RID = rids[0]
			var fsize := 34
			var glyphs: Array[int] = []
			var total := 0.0
			for i in text.length():
				var gi := ts.font_get_glyph_index(rid, fsize, text.unicode_at(i), 0)
				glyphs.append(gi)
				total += ts.font_get_glyph_advance(rid, fsize, gi).x
			var pen := Vector2(maxf(2.0, (iw - total) * 0.5), ih * 0.5 + fsize * 0.36)
			for gi in glyphs:
				_blit_glyph(img, ts, rid, fsize, gi, pen, fg)
				pen.x += ts.font_get_glyph_advance(rid, fsize, gi).x
	return ImageTexture.create_from_image(img)


static func _blit_glyph(img: Image, ts: TextServer, rid: RID, fsize: int, glyph: int,
		pen: Vector2, fg: Color) -> void:
	var sz := Vector2i(fsize, 0)
	var uv := ts.font_get_glyph_uv_rect(rid, sz, glyph)
	if uv.size.x <= 0.0 or uv.size.y <= 0.0:
		return
	var tex_idx := ts.font_get_glyph_texture_idx(rid, sz, glyph)
	if tex_idx < 0:
		return
	var atlas: Image = ts.font_get_texture_image(rid, sz, tex_idx)
	if atlas == null or atlas.is_empty():
		return
	var off := ts.font_get_glyph_offset(rid, sz, glyph)
	if atlas.get_format() != Image.FORMAT_RGBA8:
		atlas.convert(Image.FORMAT_RGBA8)
	var gx := int(uv.position.x)
	var gy := int(uv.position.y)
	var gw := int(uv.size.x)
	var gh := int(uv.size.y)
	for y in gh:
		for x in gw:
			var sxp := gx + x
			var syp := gy + y
			if sxp < 0 or syp < 0 or sxp >= atlas.get_width() or syp >= atlas.get_height():
				continue
			var src := atlas.get_pixel(sxp, syp)
			# Mono/greyscale atlases store coverage in the colour channels.
			var cov: float = src.a if src.a < 1.0 else maxf(src.r, maxf(src.g, src.b))
			if cov <= 0.02:
				continue
			var dx := int(pen.x + off.x) + x
			var dy := int(pen.y + off.y) + y
			if dx < 0 or dy < 0 or dx >= img.get_width() or dy >= img.get_height():
				continue
			img.set_pixel(dx, dy, img.get_pixel(dx, dy).lerp(fg, cov))


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

## A NavigationRegion3D over the walkable tiles. Baked from a polygon soup we build here
## (never from the editor), with a hand-rolled fallback when no baking backend is present.
static func _build_nav(rows: PackedStringArray, w: int, h: int) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.name = "Nav"
	var nm := NavigationMesh.new()
	nm.agent_radius = NAV_AGENT_RADIUS
	# agent_height is snapped to whole cell_height units by the baker; 1.75 = 7 cells.
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	# Match the project's default 3D navigation map cell size so the region merges cleanly.
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES

	var faces := PackedVector3Array()
	for ty in h:
		for tx in w:
			if not _walkable(rows, tx, ty):
				continue
			var x0 := tx * C.TILE
			var x1 := x0 + C.TILE
			var z0 := ty * C.TILE
			var z1 := z0 + C.TILE
			var a := Vector3(x0, 0.0, z0)
			var b := Vector3(x1, 0.0, z0)
			var c := Vector3(x1, 0.0, z1)
			var d := Vector3(x0, 0.0, z1)
			faces.append_array([a, b, c, a, c, d])

	var baked := false
	if ClassDB.class_exists("NavigationMeshSourceGeometryData3D"):
		var src: NavigationMeshSourceGeometryData3D = NavigationMeshSourceGeometryData3D.new()
		src.add_faces(faces, Transform3D.IDENTITY)
		NavigationServer3D.bake_from_source_geometry_data(nm, src)
		baked = nm.get_polygon_count() > 0
		if baked:
			_drop_nav_to_floor(nm)
	if not baked:
		_nav_from_tiles(nm, rows, w, h)
	region.navigation_mesh = nm
	return region


## Recast lifts the baked surface by a voxel or two; put it back on the floor plane.
static func _drop_nav_to_floor(nm: NavigationMesh) -> void:
	var vs := nm.get_vertices()
	if vs.is_empty():
		return
	var min_y := vs[0].y
	for v in vs:
		min_y = minf(min_y, v.y)
	if absf(min_y) < 0.001:
		return
	for i in vs.size():
		vs[i] = Vector3(vs[i].x, vs[i].y - min_y, vs[i].z)
	nm.set_vertices(vs)


## Fallback: one convex quad per walkable tile, corners shared so the tiles stitch together.
static func _nav_from_tiles(nm: NavigationMesh, rows: PackedStringArray, w: int, h: int) -> void:
	nm.clear_polygons()
	var verts := PackedVector3Array()
	var index := {}
	var polys: Array = []
	for ty in h:
		for tx in w:
			if not _walkable(rows, tx, ty):
				continue
			var ids := PackedInt32Array()
			for c in [Vector2i(tx, ty), Vector2i(tx + 1, ty), Vector2i(tx + 1, ty + 1), Vector2i(tx, ty + 1)]:
				var key: int = c.y * (w + 1) + c.x
				if not index.has(key):
					index[key] = verts.size()
					verts.append(Vector3(c.x * C.TILE, 0.0, c.y * C.TILE))
				ids.append(index[key])
			polys.append(ids)
	nm.set_vertices(verts)
	for p in polys:
		nm.add_polygon(p)
