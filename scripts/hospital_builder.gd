class_name HospitalBuilder
extends RefCounted
## Builds the runtime 3D level from a MapGen dictionary. Pure code, no .tscn, headless-safe.
##
## Geometry (floors, ceilings, walls, lintels, the fence and the entrance canopy) is merged into
## one mesh per material per CHUNK x CHUNK tiles, so the renderer can cull it. Furniture is drawn
## as MultiMeshes, one per mesh per chunk (scripts/level/piece_factory.gd), with box colliders
## from scripts/level/piece_defs.gd. Containers, fixtures, signs and the navigation mesh are
## built here too. `info` gets every key listed in docs/CONTRACTS.md ("Hospital").
##
## Maps without furniture data (hand-made tile maps in tools) go through the legacy builder.

const MG := preload("res://scripts/mapgen.gd")
const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Factory := preload("res://scripts/level/piece_factory.gd")
const Rooms := preload("res://scripts/level/room_furnish.gd")
const Legacy := preload("res://scripts/level/legacy_builder.gd")
const FridgeScript := preload("res://scripts/containers/med_fridge.gd")
const DrawerUnitScript := preload("res://scripts/containers/drawer_unit.gd")
const StationScript := preload("res://scripts/containers/station_drawers.gd")
const TraumaBagScript := preload("res://scripts/containers/trauma_bag.gd")
const PegboardScript := preload("res://scripts/containers/pegboard.gd")
const GUIDE_MODELS_PATH := "res://scripts/guide/guide_models.gd"

## Places where nothing a case needs is placed and monsters never spawn.
const SAFE_ROOMS := ["or", "break_room", "locker_room", "lobby", "entrance", "neutral", "anteroom", "clockin"]

## Kept for perception.gd and tools/monster_lab.gd.
const LIGHT_RANGE := 5.2
const LIGHT_ENERGY := 1.15
## A whole number of navigation cells (0.25 m), so the baker does not round it and warn.
const NAV_AGENT_RADIUS := 0.5
const SIGN_H := 2.62
const MAX_SIGNS := 90

const CHUNK := 12
## Furniture past this distance is not drawn (the fog has swallowed it by then).
const FURNITURE_RANGE := 36.0
const LINTEL_Y := 2.25
const FENCE_H := 1.9
const CANOPY_Y := 3.15

const OUTDOOR_LIGHT_RANGE := 19.0
const OUTDOOR_LIGHT_ENERGY := 3.6

const TILE_FLOOR_ROOMS := ["restroom", "morgue", "or", "janitor_closet", "lab", "radiology", "locker_room"]
const WARM_FLOOR_ROOMS := ["lobby", "break_room", "waiting_room", "cafeteria", "office"]
const TILE_WALL_ROOMS := ["restroom", "or", "morgue"]

const WING_LABELS := {"west": "WEST WING", "east": "EAST WING", "north": "NORTH WING",
		"north_west": "NORTH WING A", "north_east": "NORTH WING B"}

static var _mat_cache := {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Build the level. `info` is filled with (world units, metres, +Y up):
##   player_spawns / tool_spawns / monster_spawns : Array[Vector3]
##   table (first patient table) / table_yaw / clock / pod : Vector3 / float
##   lights : Array[{tile, position, mode, node}]
##   size : Vector2i, rows : PackedStringArray, nav_region : NavigationRegion3D
##   containers : Array[{id, type, room_kind, wing, depth, node, position, slots}]
##   loose_anchors : Array[{position, yaw, surface, room_kind, wing, depth}]
##   shelf / lectern : {position, yaw}; lectern_node
##   tables, or_screen, phone, entrance, entrance_rect, ambulance, neutral, neutral_rect,
##   wings, rooms, zones: see docs/CONTRACTS.md ("Hospital")
static func build(gen: Dictionary, info: Dictionary) -> Node3D:
	if not gen.has("furniture"):
		return Legacy.build(gen, info)
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length()
	var seed: int = gen.get("seed", 0)
	var root := Node3D.new()
	root.name = "Hospital"
	info["size"] = Vector2i(w, h)
	info["rows"] = rows

	var geo := GeoChunks.new()
	_build_surfaces(gen, geo)
	var body := StaticBody3D.new()
	body.name = "WorldCollision"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)
	geo.commit(root, body, w, h)

	_build_furniture(root, gen, info)
	_build_containers(root, gen, info)
	_add_floor_anchors(gen, info)
	_build_landmarks(root, gen, info)
	_build_lights(root, gen, info)
	root.add_child(_build_signs(gen))
	_fill_contract(gen, info)

	var nav := _build_nav(gen, info)
	root.add_child(nav)
	info["nav_region"] = nav
	return root


## Which part of the map a world position is in: a wing id, "entrance", "neutral", or "".
static func zone_of(info: Dictionary, p: Vector3) -> String:
	var z: Dictionary = info.get("zones", {})
	if z.is_empty():
		return ""
	var t := C.world_to_tile(p)
	var wd: int = z.width
	if t.x < 0 or t.y < 0 or t.x >= wd or t.y >= int(z.height):
		return ""
	return String(z.names.get(int((z.grid as PackedByteArray)[t.y * wd + t.x]), ""))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _w(p: Vector2, y := 0.0) -> Vector3:
	return Vector3(p.x * C.TILE, y, p.y * C.TILE)


static func _at(rows: PackedStringArray, x: int, y: int) -> String:
	if x < 0 or y < 0 or y >= rows.size() or x >= rows[y].length():
		return "#"
	return rows[y][x]


static func _open_char(c: String) -> bool:
	return MG.is_walkable_char(c)


static func _room_of(gen: Dictionary, x: int, y: int) -> Dictionary:
	var w: int = gen.width
	if x < 0 or y < 0 or x >= w or y >= int(gen.height):
		return {}
	var ri: int = (gen.room_at as PackedInt32Array)[y * w + x]
	return gen.rooms[ri] if ri >= 0 else {}


static func _zone(gen: Dictionary, x: int, y: int) -> int:
	var w: int = gen.width
	if x < 0 or y < 0 or x >= w or y >= int(gen.height):
		return S.ZONE_NONE
	return (gen.zone as PackedByteArray)[y * w + x]


## The place kind of a tile: its room's kind, or "corridor" (wing hallway), "entrance", "neutral".
static func place_kind(gen: Dictionary, x: int, y: int) -> String:
	var r := _room_of(gen, x, y)
	if not r.is_empty():
		return String(r.kind)
	var z := _zone(gen, x, y)
	if z == S.ZONE_ENTRANCE:
		return "entrance"
	if z == S.ZONE_OUTDOOR:
		return "neutral"
	return "corridor"


static func _wing_of(gen: Dictionary, x: int, y: int) -> Dictionary:
	var z := _zone(gen, x, y)
	for wd in gen.wings:
		if int(wd.zone) == z:
			return {"wing": String(wd.id), "depth": int(wd.depth)}
	if z == S.ZONE_ENTRANCE:
		return {"wing": "entrance", "depth": 0}
	if z == S.ZONE_OUTDOOR:
		return {"wing": "neutral", "depth": 0}
	return {"wing": "", "depth": 0}


static func _assets() -> Node:
	return Factory.assets_node()


## A tiling PBR set from the Assets autoload (optionally tinted), or a flat placeholder.
static func surface_mat(key: String, albedo: Color, rough: float, tint := Color.WHITE) -> Material:
	var ck := "%s|%s" % [key, tint.to_html()]
	if _mat_cache.has(ck):
		return _mat_cache[ck]
	var out: Material = null
	var a := _assets()
	if a != null and a.has(key):
		var m = a.material(key)
		if m is StandardMaterial3D:
			out = m
			if tint != Color.WHITE:
				var d: StandardMaterial3D = (m as StandardMaterial3D).duplicate()
				d.albedo_color = tint
				out = d
	if out == null:
		var fb := StandardMaterial3D.new()
		fb.albedo_color = albedo * tint
		fb.roughness = rough
		out = fb
	_mat_cache[ck] = out
	return out


static func _box_shape(size: Vector3, xf: Transform3D, nm: String) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf
	cs.name = nm
	return cs


# ---------------------------------------------------------------------------
# Surfaces: floors, ceilings, walls, lintels, fence, canopy
# ---------------------------------------------------------------------------

## Merged geometry, bucketed by chunk and material.
class GeoChunks extends RefCounted:
	var buckets := {}   # "cx,cy|mat" -> SurfaceTool
	var mats := {}      # mat key -> Material
	var faces := PackedVector3Array()

	func st_for(cx: int, cy: int, mat: String) -> SurfaceTool:
		var k := "%d,%d|%s" % [cx, cy, mat]
		if not buckets.has(k):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			buckets[k] = st
		return buckets[k]

	## Quad a-b-c-d (clockwise seen from the front), UVs in world metres.
	func quad(cx: int, cy: int, mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
			ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, collide := false) -> void:
		var st := st_for(cx, cy, mat)
		var n := (c - a).cross(b - a).normalized()
		for v in [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [d, ud]]:
			st.set_normal(n)
			st.set_uv(v[1])
			st.add_vertex(v[0])
		if collide:
			faces.append_array([a, b, c, a, c, d])

	func commit(root: Node3D, body: StaticBody3D, w: int, h: int) -> void:
		var holder := Node3D.new()
		holder.name = "Geometry"
		root.add_child(holder)
		var keys := buckets.keys()
		keys.sort()
		for k in keys:
			var st: SurfaceTool = buckets[k]
			st.generate_tangents()
			var mi := MeshInstance3D.new()
			mi.name = String(k).replace(",", "_").replace("|", "_")
			mi.mesh = st.commit()
			mi.material_override = mats.get(String(k).get_slice("|", 1))
			holder.add_child(mi)
		var wall_shape := CollisionShape3D.new()
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(faces)
		wall_shape.shape = concave
		wall_shape.name = "WallTrimesh"
		body.add_child(wall_shape)
		var bs := BoxShape3D.new()
		bs.size = Vector3(w * C.TILE, 0.4, h * C.TILE)
		var fl := CollisionShape3D.new()
		fl.shape = bs
		fl.position = Vector3(w * C.TILE * 0.5, -0.2, h * C.TILE * 0.5)
		fl.name = "FloorBox"
		body.add_child(fl)
		var cl := CollisionShape3D.new()
		cl.shape = bs
		cl.position = Vector3(w * C.TILE * 0.5, C.WALL_H + 0.2, h * C.TILE * 0.5)
		cl.name = "CeilingBox"
		body.add_child(cl)


static func _build_surfaces(gen: Dictionary, geo: GeoChunks) -> void:
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length()
	var nr: Rect2i = gen.get("neutral_rect", Rect2i())
	var T := C.TILE
	geo.mats["linoleum"] = surface_mat("mat/linoleum", Color(0.42, 0.44, 0.40), 0.8)
	geo.mats["floor"] = surface_mat("mat/floor", Color(0.46, 0.44, 0.40), 0.85)
	geo.mats["tile"] = surface_mat("mat/tile_floor", Color(0.55, 0.56, 0.54), 0.6)
	geo.mats["asphalt"] = surface_mat("mat/asphalt", Color(0.16, 0.16, 0.17), 0.95)
	geo.mats["pavement"] = surface_mat("mat/pavement", Color(0.4, 0.4, 0.38), 0.9)
	geo.mats["ceiling"] = surface_mat("mat/ceiling", Color(0.30, 0.31, 0.31), 0.95)
	geo.mats["wall"] = surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85)
	geo.mats["wall_low"] = surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85, Color(0.62, 0.78, 0.70))
	geo.mats["wall_tile"] = surface_mat("mat/wall_tile", Color(0.72, 0.74, 0.72), 0.5)
	geo.mats["facade"] = surface_mat("mat/concrete", Color(0.42, 0.42, 0.40), 0.9)

	for ty in h:
		for tx in w:
			var c := rows[ty][tx]
			var cx := tx / CHUNK
			var cy := ty / CHUNK
			var x0 := tx * T
			var z0 := ty * T
			var x1 := x0 + T
			var z1 := z0 + T
			if _open_char(c):
				var fkey := "linoleum"
				if c == ",":
					fkey = "pavement" if ty - nr.position.y < 4 else "asphalt"
				else:
					var kind := place_kind(gen, tx, ty)
					if TILE_FLOOR_ROOMS.has(kind):
						fkey = "tile"
					elif WARM_FLOOR_ROOMS.has(kind) or kind == "entrance":
						fkey = "floor"
				geo.quad(cx, cy, fkey, Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1),
						Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1))
				if c != ",":
					var y := C.WALL_H
					geo.quad(cx, cy, "ceiling", Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
							Vector2(x0, z0), Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0))
				if c == "+" or _is_archway(gen, tx, ty):
					_lintel(geo, gen, tx, ty)
				continue
			# Solid: faces toward open neighbours.
			var fence := c == "="
			for d in MG.DIRS:
				var nx: int = tx + d.x
				var ny: int = ty + d.y
				var nc := _at(rows, nx, ny)
				if not _open_char(nc):
					continue
				var mat := "wall"
				var outdoor := nc == ","
				if outdoor:
					mat = "facade"
				elif TILE_WALL_ROOMS.has(place_kind(gen, nx, ny)):
					mat = "wall_tile"
				var top := FENCE_H if fence else (C.WALL_H + (1.2 if outdoor else 0.0))
				var split := 0.0 if (outdoor or mat == "wall_tile") else 1.05
				_wall_face(geo, cx, cy, tx, ty, d, 0.0, split, "wall_low", false)
				_wall_face(geo, cx, cy, tx, ty, d, split, top, mat, false)
				_collision_face(geo, rows, tx, ty, d, maxf(top, C.WALL_H))
			if fence:
				var y := FENCE_H
				geo.quad(cx, cy, "facade", Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1),
						Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1))
	_canopy(geo, gen)
	_ground_paint(geo, gen)


## Parking stall lines, the ambulance bay box, a crossing from the main doors and a square
## where the gold bars go: flat quads just above the asphalt.
static func _ground_paint(geo: GeoChunks, gen: Dictionary) -> void:
	var spots: Dictionary = gen.spots
	if not spots.has("stalls"):
		return
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.78, 0.78, 0.74)
	white.roughness = 0.85
	var yellow := StandardMaterial3D.new()
	yellow.albedo_color = Color(0.8, 0.6, 0.1)
	yellow.roughness = 0.85
	geo.mats["paint_white"] = white
	geo.mats["paint_yellow"] = yellow
	var y := 0.012
	var strip := func(mat: String, a: Vector2, b: Vector2, width: float) -> void:
		var pa := _w(a)
		var pb := _w(b)
		var dir := (pb - pa).normalized()
		var side := Vector3(-dir.z, 0, dir.x) * width * 0.5
		var cx := int(a.x) / CHUNK
		var cy := int(a.y) / CHUNK
		var v0 := pa - side + Vector3(0, y, 0)
		var v1 := pb - side + Vector3(0, y, 0)
		var v2 := pb + side + Vector3(0, y, 0)
		var v3 := pa + side + Vector3(0, y, 0)
		# Wound so the face looks up.
		if (v1 - v0).cross(v3 - v0).y < 0.0:
			geo.quad(cx, cy, mat, v0, v1, v2, v3, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		else:
			geo.quad(cx, cy, mat, v0, v3, v2, v1, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
	var seen := {}
	for s in spots.stalls:
		var p: Vector2 = s.pos
		for dx in [-1.0, 1.0]:
			var key := "%.2f,%.2f" % [p.x + dx, p.y]
			if seen.has(key):
				continue
			seen[key] = true
			strip.call("paint_white", Vector2(p.x + dx, p.y - 1.5), Vector2(p.x + dx, p.y + 1.5), 0.1)
	if spots.has("bay_marking"):
		var c: Vector2 = spots.bay_marking.pos
		var hw := 1.7
		var hh := 3.4
		var corners := [c + Vector2(-hw, -hh), c + Vector2(hw, -hh), c + Vector2(hw, hh), c + Vector2(-hw, hh)]
		for i in 4:
			strip.call("paint_yellow", corners[i], corners[(i + 1) % 4], 0.15)
		for k in 5:
			var t := -hh + 0.6 + k * 1.4
			strip.call("paint_yellow", c + Vector2(-hw, t), c + Vector2(hw, t + 0.9), 0.12)
	if spots.has("entrance") and spots.has("gold_pile"):
		var e: Vector2 = spots.entrance.pos
		for k in 7:
			var x := e.x - 1.8 + k * 0.6
			strip.call("paint_white", Vector2(x, e.y + 3.4), Vector2(x, e.y + 5.2), 0.3)
		var g: Vector2 = spots.gold_pile.pos
		var q := [g + Vector2(-1.5, -1.3), g + Vector2(1.5, -1.3), g + Vector2(1.5, 1.3), g + Vector2(-1.5, 1.3)]
		for i in 4:
			strip.call("paint_yellow", q[i], q[(i + 1) % 4], 0.15)


static func _is_archway(gen: Dictionary, tx: int, ty: int) -> bool:
	if not gen.has("_archways"):
		var set := {}
		for r in gen.rooms:
			for t in r.get("open", []):
				set[t] = true
		gen["_archways"] = set
	return (gen._archways as Dictionary).has(Vector2i(tx, ty))


## A vertical face on the boundary of the tile centred at `centre`, facing `n`, from y0 to y1.
static func _vface(geo: GeoChunks, cx: int, cy: int, mat: String, centre: Vector3, n: Vector3, y0: float, y1: float, collide: bool) -> void:
	if y1 - y0 <= 0.001:
		return
	var r := n.cross(Vector3.UP)
	var mid := centre + n * (C.TILE * 0.5)
	var p0 := mid - r * (C.TILE * 0.5)
	var v0 := Vector3(p0.x, y0, p0.z)
	var v1 := v0 + r * C.TILE
	var v2 := v1 + Vector3(0.0, y1 - y0, 0.0)
	var v3 := v0 + Vector3(0.0, y1 - y0, 0.0)
	# World-metre UVs, continuous along a wall run; v counts down from the ceiling.
	var u0 := v0.x * absf(r.x) + v0.z * absf(r.z)
	var u1 := u0 + (C.TILE if (r.x + r.z) > 0.0 else -C.TILE)
	geo.quad(cx, cy, mat, v0, v1, v2, v3, Vector2(u0, C.WALL_H - y0), Vector2(u1, C.WALL_H - y0),
			Vector2(u1, C.WALL_H - y1), Vector2(u0, C.WALL_H - y1), collide)


## One wall face of solid tile (tx, ty) looking toward direction d, from height y0 to y1.
static func _wall_face(geo: GeoChunks, cx: int, cy: int, tx: int, ty: int, d: Vector2i, y0: float, y1: float, mat: String, collide: bool) -> void:
	_vface(geo, cx, cy, mat, C.tile_to_world(tx, ty), Vector3(d.x, 0.0, d.y), y0, y1, collide)


## Non-blocking pieces within (agent radius - player radius) of a wall keep their collider.
## Nothing the factory builds is that flat today, so this is off; kept for thin wall pieces.
const FLAT_PIECE_COLLIDERS := false

## Furniture colliders stop this far (metres) short of tiles the navigation mesh keeps.
const FURNITURE_INSET := 0.18

## Collision chamfer at outside wall corners (door jambs, hallway corners, pillars), metres.
const CORNER_CHAMFER := 0.18


## The collision for one wall face: the visual face, cut back at outside corners, with a
## 45-degree chamfer across each corner. Bodies sliding along a wall into a doorway glance off
## the chamfer instead of catching on the jamb.
static func _collision_face(geo: GeoChunks, rows: PackedStringArray, tx: int, ty: int, d: Vector2i, top: float) -> void:
	var n := Vector3(d.x, 0.0, d.y)
	var r := n.cross(Vector3.UP)
	var ri := Vector2i(roundi(r.x), roundi(r.z))
	var mid := C.tile_to_world(tx, ty) + n * (C.TILE * 0.5)
	var k0 := mid - r * (C.TILE * 0.5)
	var k1 := mid + r * (C.TILE * 0.5)
	var open := func(x: int, y: int) -> bool:
		return _open_char(_at(rows, x, y))
	var c := CORNER_CHAMFER
	var convex0: bool = open.call(tx - ri.x, ty - ri.y) and open.call(tx + d.x - ri.x, ty + d.y - ri.y)
	var convex1: bool = open.call(tx + ri.x, ty + ri.y) and open.call(tx + d.x + ri.x, ty + d.y + ri.y)
	var a := k0 + r * c if convex0 else k0
	var b := k1 - r * c if convex1 else k1
	var up := Vector3(0.0, top, 0.0)
	geo.faces.append_array([a, b, b + up, a, b + up, a + up])
	if convex1:
		# The corner's other face starts c back along -n; join the two with a slanted face.
		var p := k1 - r * c
		var q := k1 - n * c
		geo.faces.append_array([p, q, q + up, p, q + up, p + up])


## Solid wall, a doorway or an archway: anything a lintel continues.
static func _wallish(gen: Dictionary, x: int, y: int) -> bool:
	var c := _at(gen.rows, x, y)
	return not _open_char(c) or c == "+" or _is_archway(gen, x, y)


## The wall above a doorway: a box from LINTEL_Y to the ceiling across the door tile.
static func _lintel(geo: GeoChunks, gen: Dictionary, tx: int, ty: int) -> void:
	var along_x := _wallish(gen, tx - 1, ty) or _wallish(gen, tx + 1, ty)
	var along_z := _wallish(gen, tx, ty - 1) or _wallish(gen, tx, ty + 1)
	if along_x and along_z:
		along_x = _wallish(gen, tx - 1, ty) and _wallish(gen, tx + 1, ty)
	var cx := tx / CHUNK
	var cy := ty / CHUNK
	var T := C.TILE
	var x0 := tx * T
	var z0 := ty * T
	var x1 := x0 + T
	var z1 := z0 + T
	var y0 := LINTEL_Y
	geo.quad(cx, cy, "wall", Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0),
			Vector2(x0, z0), Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0))
	var centre := C.tile_to_world(tx, ty)
	var normals := [Vector3(0, 0, -1), Vector3(0, 0, 1)] if along_x else [Vector3(-1, 0, 0), Vector3(1, 0, 0)]
	for n in normals:
		_vface(geo, cx, cy, "wall", centre, n, y0, C.WALL_H, false)



static func _canopy(geo: GeoChunks, gen: Dictionary) -> void:
	var c: Dictionary = gen.spots.get("canopy", {})
	if c.is_empty():
		return
	var r: Rect2 = c.rect
	var p0 := _w(r.position)
	var p1 := _w(r.end)
	var cx := int(r.get_center().x) / CHUNK
	var cy := int(r.get_center().y) / CHUNK
	var y0 := CANOPY_Y
	var y1 := CANOPY_Y + 0.35
	var q := func(a: Vector3, b: Vector3, cc: Vector3, d: Vector3) -> void:
		geo.quad(cx, cy, "facade", a, b, cc, d, Vector2(a.x, a.z + a.y), Vector2(b.x, b.z + b.y), Vector2(cc.x, cc.z + cc.y), Vector2(d.x, d.z + d.y))
	# Top, underside, front and sides.
	q.call(Vector3(p0.x, y1, p0.z), Vector3(p1.x, y1, p0.z), Vector3(p1.x, y1, p1.z), Vector3(p0.x, y1, p1.z))
	q.call(Vector3(p0.x, y0, p0.z), Vector3(p0.x, y0, p1.z), Vector3(p1.x, y0, p1.z), Vector3(p1.x, y0, p0.z))
	q.call(Vector3(p0.x, y0, p1.z), Vector3(p0.x, y1, p1.z), Vector3(p1.x, y1, p1.z), Vector3(p1.x, y0, p1.z))
	q.call(Vector3(p0.x, y0, p0.z), Vector3(p0.x, y1, p0.z), Vector3(p0.x, y1, p1.z), Vector3(p0.x, y0, p1.z))
	q.call(Vector3(p1.x, y0, p1.z), Vector3(p1.x, y1, p1.z), Vector3(p1.x, y1, p0.z), Vector3(p1.x, y0, p0.z))


# ---------------------------------------------------------------------------
# Furniture
# ---------------------------------------------------------------------------

static func _build_furniture(root: Node3D, gen: Dictionary, info: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Furniture"
	root.add_child(holder)
	var batches := {}     # "cx,cy" -> {mesh -> PackedTransforms Array}
	var bodies := {}      # "cx,cy" -> StaticBody3D
	var anchors: Array = []
	var count := 0
	for e in gen.furniture:
		var kind: String = e.kind
		if e.get("canopy_post", false):
			kind = "canopy_post"
		var p: Vector2 = e.pos
		var pos := _w(p, float(e.get("y", 0.0)))
		var xf := Transform3D(Basis(Vector3.UP, float(e.yaw)), pos)
		var ck := "%d,%d" % [int(p.x) / CHUNK, int(p.y) / CHUNK]
		if not batches.has(ck):
			batches[ck] = {}
		var b: Dictionary = batches[ck]
		for part in Factory.parts(kind):
			var mesh: Mesh = part.mesh
			if not b.has(mesh):
				b[mesh] = []
			(b[mesh] as Array).append(xf * (part.xform as Transform3D))
		var support := Rect2()
		var support_top := -1.0
		if _solid_piece(gen, kind, p, float(e.yaw)):
			if not bodies.has(ck):
				var sb := StaticBody3D.new()
				sb.name = "Collide_" + ck.replace(",", "_")
				sb.collision_layer = C.L_WORLD
				sb.collision_mask = 0
				holder.add_child(sb)
				bodies[ck] = sb
			var s := Defs.size(kind)
			var fp := Defs.footprint_rect(kind, p, float(e.yaw))
			var tiles := Defs.blocked_tiles(kind, p, float(e.yaw))
			if Defs.blocks(kind) and not tiles.is_empty():
				# Never let the collider reach into a tile the navigation mesh keeps: clip it to
				# the tiles the piece blocks (an overhang of a few centimetres stays visual only).
				var cover := Rect2(Vector2(tiles[0]), Vector2.ONE)
				for tt in tiles:
					cover = cover.merge(Rect2(Vector2(tt), Vector2.ONE))
				# ...and keep it FURNITURE_INSET back from tiles that stay open, so an agent cutting a
				# corner of its navigation path does not catch on the box.
				var inset := FURNITURE_INSET / C.TILE
				var rows: PackedStringArray = gen.rows
				var blk: PackedByteArray = gen.blocked
				var gw: int = gen.width
				var open_at := func(x: int, y: int) -> bool:
					return _open_char(_at(rows, x, y)) and blk[y * gw + x] == 0
				var x0 := int(cover.position.x)
				var y0 := int(cover.position.y)
				var x1 := int(cover.end.x) - 1
				var y1 := int(cover.end.y) - 1
				var left := false
				var right := false
				var top := false
				var bottom := false
				for yy in range(y0, y1 + 1):
					left = left or open_at.call(x0 - 1, yy)
					right = right or open_at.call(x1 + 1, yy)
				for xx in range(x0, x1 + 1):
					top = top or open_at.call(xx, y0 - 1)
					bottom = bottom or open_at.call(xx, y1 + 1)
				cover = Rect2(cover.position + Vector2(inset if left else 0.0, inset if top else 0.0),
						cover.size - Vector2((inset if left else 0.0) + (inset if right else 0.0), (inset if top else 0.0) + (inset if bottom else 0.0)))
				var clip := fp.intersection(cover)
				if clip.size.x > 0.07 and clip.size.y > 0.07:
					fp = clip
			var centre := _w(fp.get_center(), s.y * 0.5 + float(e.get("y", 0.0)))
			var box := Vector3(fp.size.x * C.TILE, s.y, fp.size.y * C.TILE)
			(bodies[ck] as StaticBody3D).add_child(_box_shape(box, Transform3D(Basis.IDENTITY, centre), "S%d" % count))
			support = fp
			support_top = s.y + float(e.get("y", 0.0))
		var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
		var pk := place_kind(gen, t.x, t.y)
		if int(e.room) >= 0:
			pk = String(gen.rooms[int(e.room)].kind)
		var wi := _wing_of(gen, t.x, t.y)
		for a in Defs.anchors(kind):
			var ap: Vector3 = xf * (a[0] as Vector3)
			# Only where the collider really is under it, or the item falls through.
			if not support.grow(-0.04).has_point(Vector2(ap.x, ap.z) / C.TILE) or absf(ap.y - support_top) > 0.06:
				continue
			anchors.append({"position": ap, "yaw": float(e.yaw), "surface": String(a[1]), "room_kind": pk,
					"wing": wi.wing, "depth": wi.depth})
		count += 1
	var keys := batches.keys()
	keys.sort()
	for ck in keys:
		var b: Dictionary = batches[ck]
		var i := 0
		for mesh in b.keys():
			var xfs: Array = b[mesh]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = xfs.size()
			for k in xfs.size():
				mm.set_instance_transform(k, xfs[k])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "MM_%s_%d" % [String(ck).replace(",", "_"), i]
			mmi.multimesh = mm
			mmi.visibility_range_end = FURNITURE_RANGE
			mmi.visibility_range_end_margin = 4.0
			holder.add_child(mmi)
			i += 1
	info["loose_anchors"] = anchors
	info["furniture_count"] = count


## Does a piece get a collider? Blocking pieces do (the navigation mesh leaves their tiles out).
## Other pieces only when they are flat against a wall, closer to it than the gap a navigation
## agent's body keeps (agent radius minus player radius): anything that stands further out is
## where a monster or bot following the mesh edge would catch on it, so chairs, bins, plants and
## IV stands have no collider. See docs/KNOWN_ISSUES.md.
static func _solid_piece(gen: Dictionary, kind: String, p: Vector2, yaw: float) -> bool:
	if not Defs.collides(kind):
		return false
	if Defs.blocks(kind):
		return not Defs.blocked_tiles(kind, p, yaw).is_empty()
	if not FLAT_PIECE_COLLIDERS:
		return false
	var r := Defs.footprint_rect(kind, p, yaw)
	var margin := (NAV_AGENT_RADIUS - C.PLAYER_RADIUS) / C.TILE
	var rows: PackedStringArray = gen.rows
	var solid := func(x: int, y: int) -> bool:
		return not _open_char(_at(rows, x, y))
	var x0 := int(floor(r.position.x + 0.001))
	var x1 := int(floor(r.end.x - 0.001))
	var y0 := int(floor(r.position.y + 0.001))
	var y1 := int(floor(r.end.y - 0.001))
	var cx := int(floor(p.x))
	var cy := int(floor(p.y))
	# North wall: the face at y = y0, the piece reaching no further than the margin from it.
	if solid.call(cx, y0 - 1) and r.end.y - y0 <= margin:
		return true
	if solid.call(cx, y1 + 1) and (y1 + 1) - r.position.y <= margin:
		return true
	if solid.call(x0 - 1, cy) and r.end.x - x0 <= margin:
		return true
	if solid.call(x1 + 1, cy) and (x1 + 1) - r.position.x <= margin:
		return true
	return false


# ---------------------------------------------------------------------------
# Containers and anchors
# ---------------------------------------------------------------------------

## World transform of a wall-standing piece: origin on the floor at the wall face, -Z into the room.
static func _site_xform(tile: Vector2i, wall: Vector2i) -> Transform3D:
	var yaw := atan2(float(wall.x), float(wall.y))
	var pos := C.tile_to_world(tile.x, tile.y) + Vector3(wall.x, 0.0, wall.y) * (C.TILE * 0.5)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


static func _build_containers(root: Node3D, gen: Dictionary, info: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Containers"
	root.add_child(holder)
	var entries: Array = []
	var anchors: Array = info.loose_anchors
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
		var wi := _wing_of(gen, tile.x, tile.y)
		for c in list:
			var ct: Node3D = c
			entries.append({
				"id": String(ct.get_meta("interact_id")), "type": type, "room_kind": String(s.room_kind),
				"wing": wi.wing, "depth": wi.depth,
				"node": ct, "position": (xf * ct.transform).origin if ct != node else xf.origin,
				"slots": ct.slot_count(),
			})
		for a in node.get_meta("anchors", []):
			var t: Transform3D = xf * (a.xform as Transform3D)
			anchors.append({"position": t.origin, "yaw": xf.basis.get_euler().y, "surface": a.surface,
					"room_kind": String(s.room_kind), "wing": wi.wing, "depth": wi.depth})
	info["containers"] = entries


## Floor spots against walls: one or two per wing room, a few along each wing's hallways.
static func _add_floor_anchors(gen: Dictionary, info: Dictionary) -> void:
	var rows: PackedStringArray = gen.rows
	var w: int = gen.width
	var h: int = gen.height
	var rng := MG.Rng.new((int(gen.seed) ^ 0x3c6ef372) & 0xFFFFFFFF)
	var anchors: Array = info.loose_anchors
	var blocked: PackedByteArray = gen.blocked
	var used := {}
	for s in gen.get("containers", []):
		used[s.tile] = true
		used[(s.tile as Vector2i) - (s.wall as Vector2i)] = true
	var edge_dir := func(x: int, y: int) -> Vector2i:
		if _at(rows, x, y) != "." or blocked[y * w + x] != 0 or used.has(Vector2i(x, y)):
			return Vector2i.ZERO
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := _at(rows, x + dx, y + dy)
				if c == "+" or c == "T" or c == "M":
					return Vector2i.ZERO
		for d in MG.DIRS:
			if _at(rows, x + d.x, y + d.y) == "#" and _open_char(_at(rows, x - d.x, y - d.y)) and blocked[(y - d.y) * w + x - d.x] == 0:
				return d
		return Vector2i.ZERO
	var add := func(x: int, y: int, d: Vector2i) -> void:
		var pos := C.tile_to_world(x, y) + Vector3(d.x, 0.0, d.y) * (C.TILE * 0.5 - 0.24)
		var wi := _wing_of(gen, x, y)
		anchors.append({"position": pos, "yaw": atan2(float(d.x), float(d.y)), "surface": "floor",
				"room_kind": place_kind(gen, x, y), "wing": wi.wing, "depth": wi.depth})
	for r in gen.rooms:
		if SAFE_ROOMS.has(String(r.kind)):
			continue
		var cands: Array = []
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				var d: Vector2i = edge_dir.call(x, y)
				if d != Vector2i.ZERO:
					cands.append([x, y, d])
		rng.shuffle(cands)
		var want := 2 if r.w * r.h >= 30 else 1
		for i in mini(want, cands.size()):
			add.call(cands[i][0], cands[i][1], cands[i][2])
	for wd in gen.wings:
		var corr: Array = []
		var rr: Rect2i = wd.rect
		for y in range(rr.position.y, rr.end.y):
			for x in range(rr.position.x, rr.end.x):
				if _zone(gen, x, y) != int(wd.zone) or not _room_of(gen, x, y).is_empty():
					continue
				var d: Vector2i = edge_dir.call(x, y)
				if d != Vector2i.ZERO:
					corr.append([x, y, d])
		rng.shuffle(corr)
		var placed: Array[Vector2i] = []
		var want := 2 + int(wd.depth)
		for c in corr:
			if placed.size() >= want:
				break
			var p := Vector2i(c[0], c[1])
			var ok := true
			for q in placed:
				if absi(p.x - q.x) + absi(p.y - q.y) < 10:
					ok = false
					break
			if ok:
				placed.append(p)
				add.call(p.x, p.y, c[2])


# ---------------------------------------------------------------------------
# Landmarks: clock, pod, lectern, tables, shelf and markers
# ---------------------------------------------------------------------------

static func _build_landmarks(root: Node3D, gen: Dictionary, info: Dictionary) -> void:
	var spots: Dictionary = gen.spots
	var rows: PackedStringArray = gen.rows
	var player_spawns: Array[Vector3] = []
	var tool_spawns: Array[Vector3] = []
	var monster_spawns: Array[Vector3] = []
	for ty in rows.size():
		var row := rows[ty]
		for tx in row.length():
			match row[tx]:
				"P": player_spawns.append(C.tile_to_world(tx, ty))
				"T": tool_spawns.append(C.tile_to_world(tx, ty))
				"M": monster_spawns.append(C.tile_to_world(tx, ty))
	info["player_spawns"] = player_spawns
	info["tool_spawns"] = tool_spawns
	info["monster_spawns"] = monster_spawns

	var tables: Array = []
	for t in spots.get("tables", []):
		tables.append({"position": _w(t.pos), "yaw": float(t.yaw), "kind": String(t.kind)})
	info["tables"] = tables
	info["table"] = Vector3.ZERO
	info["table_yaw"] = 0.0
	for t in tables:
		if t.kind == "patient":
			info["table"] = t.position
			info["table_yaw"] = t.yaw
			break
	info["clock"] = _w(spots.clock.pos) if spots.has("clock") else Vector3.ZERO
	info["pod"] = _w(spots.pod.pos) if spots.has("pod") else Vector3.ZERO
	if spots.has("shelf"):
		info["shelf"] = {"position": _w(spots.shelf.pos), "yaw": float(spots.shelf.yaw)}
	if spots.has("lectern"):
		var spot := {"position": _w(spots.lectern.pos), "yaw": float(spots.lectern.yaw)}
		info["lectern"] = spot
		var lectern := _make_lectern()
		var sb := StaticBody3D.new()
		sb.name = "Lectern"
		sb.collision_layer = C.L_WORLD
		sb.collision_mask = 0
		sb.position = spot.position
		sb.rotation.y = spot.yaw
		sb.add_child(lectern)
		Legacy._fit_collider(lectern)
		var size: Vector3 = lectern.get_meta("collider_size")
		sb.add_child(_box_shape(size, Transform3D(Basis.IDENTITY, Vector3(0.0, lectern.get_meta("collider_y"), 0.0)), "Shape"))
		root.add_child(sb)
		info["lectern_node"] = sb


## The guide worker's lectern when it exists, else the legacy wooden stand.
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
	return Legacy._make_lectern()


# ---------------------------------------------------------------------------
# Lights
# ---------------------------------------------------------------------------

static func _build_lights(root: Node3D, gen: Dictionary, info: Dictionary) -> void:
	var lights_root := Node3D.new()
	lights_root.name = "Lights"
	root.add_child(lights_root)
	var seed: int = gen.get("seed", 0)
	var out: Array[Dictionary] = []
	for l in gen.lights:
		var tile: Vector2i = l.tile
		var mode := int(l.mode)
		var kind: String = l.get("kind", "")
		var node: Node3D
		var pos: Vector3
		if kind == "street" or kind == "canopy":
			pos = _w(l.pos, 5.05 if kind == "street" else CANOPY_Y - 0.05)
			node = _make_outdoor_light(kind)
			node.name = "Outdoor_%d_%d" % [tile.x, tile.y]
			node.position = pos
		else:
			pos = C.tile_to_world(tile.x, tile.y)
			node = Legacy._make_light_fixture(mode, ((seed * 73856093) ^ (tile.x * 19349663) ^ (tile.y * 83492791)) & 0x7FFFFFFF)
			node.name = "Fixture_%d_%d" % [tile.x, tile.y]
			node.position = pos
			node.add_to_group("fixture")
			node.set_meta("mode", mode)
			node.set_meta("tile", tile)
			var bulb: OmniLight3D = node.get_node("Bulb")
			if mode == 2:
				# A dead fixture never lights anything: keep its panel, drop the light itself.
				bulb.visible = false
			elif l.get("bright", false):
				bulb.light_energy = LIGHT_ENERGY * 1.7
				bulb.omni_range = LIGHT_RANGE * 1.35
				bulb.light_color = Color(0.96, 0.98, 1.0)
		lights_root.add_child(node)
		out.append({"tile": tile, "position": pos, "mode": mode, "node": node})
	info["lights"] = out


## Sodium street lamps and the canopy downlights: steady, warm, long reach. Not "fixture"s, so
## they never flicker.
static func _make_outdoor_light(kind: String) -> Node3D:
	var n := Node3D.new()
	var bulb := OmniLight3D.new()
	bulb.name = "Bulb"
	bulb.omni_range = OUTDOOR_LIGHT_RANGE if kind == "street" else 7.0
	bulb.light_energy = OUTDOOR_LIGHT_ENERGY if kind == "street" else 1.6
	bulb.light_color = Color(1.0, 0.78, 0.52) if kind == "street" else Color(0.95, 0.95, 1.0)
	bulb.light_volumetric_fog_energy = 0.35
	bulb.shadow_enabled = false
	bulb.distance_fade_enabled = true
	bulb.distance_fade_begin = 55.0
	bulb.distance_fade_length = 10.0
	bulb.set_meta("mode", 0)
	n.add_child(bulb)
	if kind == "canopy":
		var panel := MeshInstance3D.new()
		panel.name = "Panel"
		var bm := BoxMesh.new()
		bm.size = Vector3(0.9, 0.04, 0.9)
		panel.mesh = bm
		panel.material_override = Legacy._mat(Color(0.9, 0.9, 0.9), 0.3, Color(1, 1, 1), 2.0)
		n.add_child(panel)
	return n


# ---------------------------------------------------------------------------
# Signs
# ---------------------------------------------------------------------------

static func _build_signs(gen: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Signs"
	var cache := {}
	var count := 0
	var er: Rect2i = gen.entrance_rect
	# Wing names over the entrance building's doorways into each wing.
	for wd in gen.wings:
		var entry: Array = wd.entry
		var mid := (Vector2(entry[0]) + Vector2(entry[1])) * 0.5 + Vector2(0.5, 0.5)
		var dir: Vector2i = wd.dir
		var f := Vector2(-dir.x, -dir.y)
		var pos := _w(mid - f * 0.51, SIGN_H)
		root.add_child(_sign_node(WING_LABELS.get(String(wd.id), String(wd.id).to_upper()), pos, Defs.yaw_facing(-f), cache, "wing"))
		count += 1
	# Exit over the main doors, inside; "EMERGENCY" outside.
	var ent: Dictionary = gen.spots.get("entrance", {})
	if not ent.is_empty():
		var p: Vector2 = ent.pos
		root.add_child(_sign_node("EXIT", _w(p + Vector2(0, -0.51), SIGN_H), Defs.yaw_facing(Vector2(0, 1)), cache, "exit"))
		root.add_child(_sign_node("EMERGENCY", _w(p + Vector2(0, 0.52), 3.6), Defs.yaw_facing(Vector2(0, -1)), cache, "emergency"))
		count += 2
	# Room names over their doors, on the hallway side.
	for r in gen.rooms:
		if count >= MAX_SIGNS:
			break
		if int(r.zone) == S.ZONE_ENTRANCE and String(r.kind) != "or" and String(r.kind) != "break_room":
			continue
		var label: String = Rooms.KINDS.get(r.kind, {}).get("label", "")
		if String(r.kind) == "or":
			label = "OPERATING"
		elif String(r.kind) == "break_room":
			label = "STAFF ONLY"
		if label == "":
			continue
		var door := Vector2i(-1, -1)
		var f := Vector2.ZERO
		if not (r.doors as Array).is_empty():
			door = r.doors[0]
		elif not (r.get("open", []) as Array).is_empty():
			var op: Array = r.open
			door = op[op.size() / 2]
		if door.x < 0:
			continue
		for d in MG.DIRS:
			var inside := door + d
			if not _room_of(gen, inside.x, inside.y).is_empty() and int(_room_of(gen, inside.x, inside.y).id) == int(r.id):
				f = Vector2(-d.x, -d.y)
				break
		if f == Vector2.ZERO:
			continue
		var pos := _w(Vector2(door) + Vector2(0.5, 0.5) + f * 0.51, SIGN_H)
		root.add_child(_sign_node(label, pos, Defs.yaw_facing(-f), cache, "room"))
		count += 1
	return root


static func _sign_node(text: String, pos: Vector3, yaw: float, cache: Dictionary, style: String) -> Node3D:
	var n := Node3D.new()
	n.name = "Sign_" + text.replace(" ", "_")
	n.position = pos
	n.rotation.y = yaw
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	var wide := clampf(0.2 + text.length() * 0.085, 0.6, 1.4)
	qm.size = Vector2(wide, 0.26)
	if style == "emergency":
		qm.size = Vector2(2.6, 0.55)
	mi.mesh = qm
	var key := text + "|" + style
	var mat: StandardMaterial3D = cache.get(key, null)
	if mat == null:
		var fg := Color(0.92, 0.94, 0.96)
		var bg := Color(0.06, 0.09, 0.14)
		var glow := Color(0.55, 0.75, 1.0)
		match style:
			"exit":
				fg = Color(0.85, 1.0, 0.88)
				bg = Color(0.03, 0.22, 0.08)
				glow = Color(0.25, 1.0, 0.45)
			"emergency":
				fg = Color(1.0, 0.95, 0.92)
				bg = Color(0.45, 0.03, 0.03)
				glow = Color(1.0, 0.3, 0.25)
			"wing":
				bg = Color(0.04, 0.16, 0.18)
				glow = Color(0.5, 0.9, 0.85)
		var tex := Legacy._text_texture(text, fg, bg, int(wide * 190.0) if style != "emergency" else 384, 56 if style != "emergency" else 82)
		mat = StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.emission_enabled = true
		mat.emission_texture = tex
		mat.emission = glow
		mat.emission_energy_multiplier = 1.6 if style != "room" else 0.9
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cache[key] = mat
	mi.material_override = mat
	n.add_child(mi)
	return n


# ---------------------------------------------------------------------------
# The contract keys (docs/CONTRACTS.md, "Hospital")
# ---------------------------------------------------------------------------

static func _fill_contract(gen: Dictionary, info: Dictionary) -> void:
	var spots: Dictionary = gen.spots
	if spots.has("or_screen"):
		var o: Dictionary = spots.or_screen
		info["or_screen"] = {"position": _w(o.pos, float(o.height)), "yaw": float(o.yaw), "size": o.size}
	if spots.has("phone"):
		info["phone"] = {"position": _w(spots.phone.pos, float(spots.phone.height)), "yaw": float(spots.phone.yaw)}
	if spots.has("entrance"):
		info["entrance"] = {"position": _w(spots.entrance.pos), "yaw": float(spots.entrance.yaw)}
	var er: Rect2i = gen.entrance_rect
	info["entrance_rect"] = Rect2(Vector2(er.position) * C.TILE, Vector2(er.size) * C.TILE)
	var nr: Rect2i = gen.neutral_rect
	info["neutral_rect"] = Rect2(Vector2(nr.position) * C.TILE, Vector2(nr.size) * C.TILE)
	if spots.has("ambulance"):
		info["ambulance"] = {"position": _w(spots.ambulance.pos), "yaw": float(spots.ambulance.yaw),
				"vehicle": _w(spots.ambulance.vehicle)}
	var spawns: Array = []
	for p in spots.get("neutral_spawns", []):
		spawns.append(_w(p))
	var neutral := {"spawn_points": spawns}
	if spots.has("shop"):
		neutral["shop"] = {"position": _w(spots.shop.pos), "yaw": float(spots.shop.yaw), "vehicle": _w(spots.shop.vehicle)}
	if spots.has("sell_bin"):
		neutral["sell_bin"] = {"position": _w(spots.sell_bin.pos), "yaw": float(spots.sell_bin.yaw), "front": _w(spots.sell_bin.front)}
	if spots.has("gold_pile"):
		neutral["gold_pile"] = {"position": _w(spots.gold_pile.pos)}
	info["neutral"] = neutral
	var wings: Array = []
	var names := {S.ZONE_ENTRANCE: "entrance", S.ZONE_OUTDOOR: "neutral"}
	for wd in gen.wings:
		var r: Rect2i = wd.rect
		wings.append({"id": String(wd.id), "rect": Rect2(Vector2(r.position) * C.TILE, Vector2(r.size) * C.TILE),
				"depth": int(wd.depth), "tile_rect": r})
		names[int(wd.zone)] = String(wd.id)
	info["wings"] = wings
	var rooms: Array = []
	for r in gen.rooms:
		var doors: Array = []
		for d in r.doors:
			doors.append(C.tile_to_world(d.x, d.y))
		for d in r.get("open", []):
			doors.append(C.tile_to_world(d.x, d.y))
		rooms.append({"id": int(r.id), "kind": String(r.kind), "wing": String(r.wing), "depth": int(r.depth),
				"rect": Rect2(Vector2(r.x, r.y) * C.TILE, Vector2(r.w, r.h) * C.TILE),
				"tiles": Rect2i(r.x, r.y, r.w, r.h), "doors": doors})
	info["rooms"] = rooms
	info["zones"] = {"grid": gen.zone, "width": int(gen.width), "height": int(gen.height), "names": names}


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

## One NavigationRegion3D over every open tile, with furniture that blocks movement cut out.
static func _build_nav(gen: Dictionary, info: Dictionary) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.name = "Nav"
	var nm := NavigationMesh.new()
	nm.agent_radius = NAV_AGENT_RADIUS
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	var rows: PackedStringArray = gen.rows
	var w: int = gen.width
	var h: int = gen.height
	var blocked: PackedByteArray = gen.blocked
	var faces := PackedVector3Array()
	for ty in h:
		for tx in w:
			if not _open_char(rows[ty][tx]) or blocked[ty * w + tx] != 0:
				continue
			var x0 := tx * C.TILE
			var x1 := x0 + C.TILE
			var z0 := ty * C.TILE
			var z1 := z0 + C.TILE
			faces.append_array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1),
					Vector3(x0, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])
	var baked := false
	if ClassDB.class_exists("NavigationMeshSourceGeometryData3D"):
		var src: NavigationMeshSourceGeometryData3D = NavigationMeshSourceGeometryData3D.new()
		src.add_faces(faces, Transform3D.IDENTITY)
		# Furniture that does not fill its tiles (chairs, carts, gurneys along a wall) is left in
		# the navigation mesh on purpose: cut out, even exactly, it split rooms into islands the
		# baker could not join. Agents slide past it on its colliders.
		NavigationServer3D.bake_from_source_geometry_data(nm, src)
		baked = nm.get_polygon_count() > 0
		if baked:
			Legacy._drop_nav_to_floor(nm)
	if not baked:
		Legacy._nav_from_tiles(nm, rows, w, h)
	region.navigation_mesh = nm
	return region
