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
const FogRingScript := preload("res://scripts/level/fog_ring.gd")   # SWEEP 4A HOOK (fog lot, chunk 2)
const DrawerUnitScript := preload("res://scripts/containers/drawer_unit.gd")
const StationScript := preload("res://scripts/containers/station_drawers.gd")
const TraumaBagScript := preload("res://scripts/containers/trauma_bag.gd")
const PegboardScript := preload("res://scripts/containers/pegboard.gd")
const TERMINAL_MODEL_PATH := "res://scripts/database/terminal_model.gd"

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

## SWEEP 4A FOLLOW-UP (fog lot, chunk 2): was 19.0 -- easily reaching the border wall from any
## reasonable lamp position on the lot (chunk 2 already pulled the lamps in from the old
## parking-lot edge placements; a 19 m range still lit the wall well past that). Cut down so the
## lamps read as pools of light over the walkway, not a wash all the way to the fog belt.
const OUTDOOR_LIGHT_RANGE := 9.0
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
##   table (first patient table) / table_yaw / clock : Vector3 / float
##   lights : Array[{tile, position, mode, node}]
##   size : Vector2i, rows : PackedStringArray, nav_region : NavigationRegion3D
##   containers : Array[{id, type, room_kind, wing, depth, node, position, slots}]
##   loose_anchors : Array[{position, yaw, surface, room_kind, wing, depth}]
##   shelf / lectern : {position, yaw}; lectern_node
##   tables, or_screen, phone, entrance, entrance_rect, ambulance, neutral, neutral_rect,
##   wings, rooms, zones: see docs/CONTRACTS.md ("Hospital")
##
## DOORS (2026-09-14): the map is built in two parts. PART_BASE is the entrance building and the
## neutral area (everything in the entrance or outdoor zones, and every wall face that looks into
## them); it never changes within a run. PART_WINGS is everything behind the wing gates, under the
## Hospital's "Wings" child, and is rebuilt for every shift (scripts/level/wing_loader.gd). Each part
## goes through `prepare()` (pure data, safe on a worker thread once `warm_parts()` has run on the
## main thread) and `commit_steps()` (small callables that create nodes, run all at once here or a
## few per frame by the wing loader). `finish_info()` then fills `info` from the committed parts.
static func build(gen: Dictionary, info: Dictionary) -> Node3D:
	if not gen.has("furniture"):
		return Legacy.build(gen, info)
	warm_parts(gen)
	var root := Node3D.new()
	root.name = "Hospital"
	var base := prepare(gen, PART_BASE)
	var wings := prepare(gen, PART_WINGS)
	for step in commit_steps(base, root):
		step.call()
	var wings_root := Node3D.new()
	wings_root.name = "Wings"
	root.add_child(wings_root)
	for step in commit_steps(wings, wings_root):
		step.call()
	finish_info(gen, info, base, wings)
	_build_fog_belt(info, root)
	# The base part is kept (the wing loader merges its lists with every new set of wings); its
	# mesh data is not needed any more.
	for key in ["geo", "faces", "furn", "colliders", "signs", "lights", "containers", "doors", "occluder"]:
		base[key] = {} if (base[key] is Dictionary) else []
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	nav.navigation_mesh = bake_nav(gen)
	root.add_child(nav)
	info["nav_region"] = nav
	info["wings_root"] = wings_root
	info["base_part"] = base
	return root


## SWEEP 4A HOOK (fog lot, chunk 2): a real local FogVolume over the outdoor lot, so the fog is
## visible atmosphere from anywhere on the lot (including standing at the doors, not yet inside
## the fog_ring.gd belt) instead of only a per-camera tint that activates once a player's own
## position is deep in the ring. Without this the lot's border wall was plainly visible in the
## distance since nothing occluded it. Local density only (the doc asks to prefer this over
## raising the tuned global volumetric fog everywhere).
##
## SWEEP 4A FOLLOW-UP: a single box over the whole lot (inner clear area included) with a soft
## `edge_fade` read as a slow gradual haze, not "walking well-lit ground and immediately hitting
## thick fog," and it never fully hid the border wall. Rebuilt as a ring of 3 strips (west, east,
## south -- the entrance/north side needs none, the canopy already shields it and fog_ring.gd's
## own `inner_rect` never puts a margin there) that starts exactly at `FogRing.inner_rect()`'s own
## edge, the same boundary the screen-space steer/blind math in fog_ring.gd uses, so the visible
## atmosphere and "you are now blind" both begin at the same line instead of drifting apart. Edge
## fade is small for a sharp wall of fog, not a gradient; density is high enough with the local
## screen-space fog (see fog_ring.gd's own FOG_DENSITY note) that nothing including a flashlight
## should read through it once inside.
const FOG_BELT_PAD_M := 6.0
const FOG_BELT_HEIGHT_M := 8.0
## SWEEP 4A FOLLOW-UP: 9.0 scattered the ambulance's headlights into a blown-out white haze
## instead of a dark wall of fog (real Light3Ds scatter through a real FogVolume, unlike the
## screen-space override). Lower, relying more on FogRing's own screen-space fog (which now has
## its own light_energy turned down too) for the "can't see anything" guarantee once a player's
## own depth is high, while this volume still reads as atmosphere from a distance.
const FOG_BELT_DENSITY := 4.0
const FOG_BELT_EDGE_FADE := 0.8


static func _build_fog_belt(info: Dictionary, root: Node3D) -> void:
	if not info.has("neutral_rect"):
		return
	var outer: Rect2 = info.neutral_rect
	if outer.size == Vector2.ZERO:
		return
	var inner: Rect2 = FogRingScript.inner_rect(info)
	var mat := FogMaterial.new()
	mat.density = FOG_BELT_DENSITY
	mat.albedo = FogRingScript.FOG_COLOR
	mat.edge_fade = FOG_BELT_EDGE_FADE
	var far_x0 := outer.position.x - FOG_BELT_PAD_M
	var far_x1 := outer.end.x + FOG_BELT_PAD_M
	var far_z1 := outer.end.y + FOG_BELT_PAD_M
	# West strip: from the padded outer edge in to the clear area's own west edge, full depth.
	_add_fog_strip(root, mat, far_x0, inner.position.x, outer.position.y, far_z1)
	# East strip: clear area's east edge out to the padded outer edge, full depth.
	_add_fog_strip(root, mat, inner.end.x, far_x1, outer.position.y, far_z1)
	# South strip: clear area's south edge out past the padded outer edge, full width (overlaps
	# the west/east strips at the corners so there is no gap to see through).
	_add_fog_strip(root, mat, far_x0, far_x1, inner.end.y, far_z1)


static func _add_fog_strip(root: Node3D, mat: FogMaterial, x0: float, x1: float, z0: float, z1: float) -> void:
	var w := x1 - x0
	var d := z1 - z0
	if w <= 0.01 or d <= 0.01:
		return
	var vol := FogVolume.new()
	vol.name = "FogBelt"
	vol.shape = 3   # FogVolume box shape (this Godot build exposes no GDScript-visible enum constant for it)
	vol.material = mat
	vol.size = Vector3(w, FOG_BELT_HEIGHT_M, d)
	vol.position = Vector3(x0 + w * 0.5, FOG_BELT_HEIGHT_M * 0.5, z0 + d * 0.5)
	root.add_child(vol)


const PART_BASE := 0
const PART_WINGS := 1
const DoorsScript := preload("res://scripts/doors/door.gd")


## Which part a tile belongs to: the entrance building and outside (and unused solid) are the base.
static func part_of(gen: Dictionary, x: int, y: int) -> int:
	var z := _zone(gen, x, y)
	return PART_BASE if z == S.ZONE_ENTRANCE or z == S.ZONE_OUTDOOR or z == S.ZONE_NONE else PART_WINGS


## Build every furniture kind's shared meshes once, on the main thread, so `prepare()` only reads
## the cache (a worker thread must never load an asset or create a mesh).
static func warm_parts(gen: Dictionary = {}) -> void:
	if gen.has("furniture"):
		# Just the kinds this map uses (a cold start builds every model it draws anyway).
		for e in gen.furniture:
			Factory.parts("canopy_post" if e.get("canopy_post", false) else String(e.kind))
		return
	for kind in Defs.P.keys():
		Factory.parts(kind)
	Factory.parts("canopy_post")


## Everything one part needs, as data. Thread-safe after `warm_parts()`.
static func prepare(gen: Dictionary, part: int) -> Dictionary:
	var p := {"part": part, "gen": gen, "geo": {}, "faces": {}, "furn": {}, "colliders": {},
		"anchors": [], "containers": [], "lights": [], "signs": [], "doors": [], "occluder": [],
		"out": {"containers": [], "lights": [], "anchors": [], "doors": [], "lectern_node": null}}
	var geo := GeoChunks.new()
	_build_surfaces(gen, geo, part)
	p.geo = geo.to_arrays()
	p.faces = geo.faces_by_chunk
	_prep_furniture(gen, p)
	for s in gen.get("containers", []):
		if part_of(gen, s.tile.x, s.tile.y) == part:
			p.containers.append(s)
	if part == PART_WINGS:
		p["floor_anchors"] = _floor_anchors(gen)
		var data := {}
		_fill_landmarks(gen, data)
		_fill_contract(gen, data)
		p["info_data"] = data
	for l in gen.lights:
		var zl := int(l.zone)
		var is_base := zl == S.ZONE_ENTRANCE or zl == S.ZONE_OUTDOOR
		if is_base == (part == PART_BASE):
			p.lights.append(l)
	p.signs = _sign_specs(gen, part)
	for d in gen.get("doors", []):
		if bool(d.base) == (part == PART_BASE):
			p.doors.append(d)
	p.occluder = _occluder_arrays(gen, part)
	return p


## Callables that create the part's nodes under `parent`, each a few milliseconds at most.
static func commit_steps(p: Dictionary, parent: Node3D) -> Array:
	var steps: Array = []
	var gen: Dictionary = p.gen
	var part := int(p.part)
	var holder := Node3D.new()
	holder.name = "Geometry"
	var body := StaticBody3D.new()
	body.name = "WorldCollision"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	var furn := Node3D.new()
	furn.name = "Furniture"
	var cts := Node3D.new()
	cts.name = "Containers"
	var lights := Node3D.new()
	lights.name = "Lights"
	var signs := Node3D.new()
	signs.name = "Signs"
	var doors := Node3D.new()
	doors.name = "Doors"
	steps.append(func():
		for n in [holder, body, furn, cts, lights, signs, doors]:
			parent.add_child(n)
		if part == PART_BASE:
			var rows: PackedStringArray = gen.rows
			var w: int = rows[0].length()
			var h := rows.size()
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
			body.add_child(cl))
	# Geometry: a handful of merged chunk meshes per step.
	var keys: Array = (p.geo as Dictionary).keys()
	keys.sort()
	var batch := 6
	for i in range(0, keys.size(), batch):
		var slice := keys.slice(i, i + batch)
		steps.append(func():
			for k in slice:
				var arrays: Array = p.geo[k]
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				var mi := MeshInstance3D.new()
				mi.name = String(k).replace(",", "_").replace("|", "_")
				mi.mesh = mesh
				mi.material_override = _geo_material(String(k).get_slice("|", 1))
				holder.add_child(mi))
	var labels: Array = []
	p["step_labels"] = labels
	var mark := func(label: String) -> void:
		while labels.size() < steps.size():
			labels.append(label)
	mark.call("geometry")
	# Wall collision, one trimesh per chunk.
	var fkeys: Array = (p.faces as Dictionary).keys()
	fkeys.sort()
	for i in range(0, fkeys.size(), 3):
		var slice := fkeys.slice(i, i + 3)
		steps.append(func():
			for k in slice:
				var cs := CollisionShape3D.new()
				var concave := ConcavePolygonShape3D.new()
				concave.set_faces(p.faces[k])
				cs.shape = concave
				cs.name = "Walls_" + String(k).replace(",", "_")
				body.add_child(cs))
	mark.call("wall collision")
	# Furniture, one chunk per step.
	var ck_keys: Array = (p.furn as Dictionary).keys()
	for k in (p.colliders as Dictionary).keys():
		if not ck_keys.has(k):
			ck_keys.append(k)
	ck_keys.sort()
	for ck in ck_keys:
		steps.append(func(): _commit_furniture_chunk(p, String(ck), furn))
	mark.call("furniture")
	# Containers, a few per step.
	var clist: Array = p.containers
	for i in range(0, clist.size(), 1):
		var slice := clist.slice(i, i + 1)
		steps.append(func(): _commit_containers(p, slice, cts))
	mark.call("containers")
	if part == PART_WINGS:
		steps.append(func():
			(p.out.anchors as Array).append_array(p.floor_anchors))
	if part == PART_BASE:
		steps.append(func(): _commit_lectern(p, parent))
	mark.call("anchors")
	# Lights.
	var llist: Array = p.lights
	for i in range(0, llist.size(), 8):
		var slice := llist.slice(i, i + 8)
		steps.append(func(): _commit_lights(p, slice, lights))
	mark.call("lights")
	# Signs.
	var slist: Array = p.signs
	for i in range(0, slist.size(), 10):
		var slice := slist.slice(i, i + 10)
		steps.append(func():
			for sp in slice:
				signs.add_child(_sign_node(sp[0], sp[1], sp[2], _SIGN_CACHE, sp[3])))
	mark.call("signs")
	# Doors.
	var dlist: Array = p.doors
	for i in range(0, dlist.size(), 4):
		var slice := dlist.slice(i, i + 4)
		steps.append(func():
			for d in slice:
				var node: Node3D = DoorsScript.create(d)
				doors.add_child(node)
				(p.out.doors as Array).append(node))
	mark.call("doors")
	# Wall occluders.
	steps.append(func():
		var arr: Array = p.occluder
		if (arr[0] as PackedVector3Array).is_empty():
			return
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(arr[0], arr[1])
		var node := OccluderInstance3D.new()
		node.name = "WallOccluders"
		node.occluder = occ
		parent.add_child(node))
	mark.call("occluder")
	return steps


static var _SIGN_CACHE := {}


## Fill `info` from the committed base and wings parts (docs/CONTRACTS.md, "Hospital").
static func finish_info(gen: Dictionary, info: Dictionary, base: Dictionary, wings: Dictionary) -> void:
	var rows: PackedStringArray = gen.rows
	info["size"] = Vector2i(rows[0].length(), rows.size())
	info["rows"] = rows
	var anchors: Array = []
	anchors.append_array(base.out.anchors)
	anchors.append_array(wings.out.anchors)
	info["loose_anchors"] = anchors
	var cts: Array = []
	cts.append_array(base.out.containers)
	cts.append_array(wings.out.containers)
	info["containers"] = cts
	var lights: Array = []
	lights.append_array(base.out.lights)
	lights.append_array(wings.out.lights)
	info["lights"] = lights
	info["furniture_count"] = int(base.get("furniture_count", 0)) + int(wings.get("furniture_count", 0))
	# The spawns, landmarks and contract keys are data: prepare() already worked them out on the
	# thread for the wings part.
	var data: Dictionary = wings.get("info_data", {})
	if data.is_empty():
		_fill_landmarks(gen, info)
		_fill_contract(gen, info)
	else:
		info.merge(data, true)
	if base.out.lectern_node != null:
		info["lectern_node"] = base.out.lectern_node
	info["doors"] = gen.get("doors", [])
	info["door_nodes"] = (base.out.doors as Array) + (wings.out.doors as Array)
	info["wing_seed"] = int(gen.get("wing_seed", gen.get("seed", 0)))
	# POCKETS HOOK: what game.pockets.build_wings needs from the map (the plan, the fixtures and the run
	# seed they are seeded with, for the entrance stubs' pocket copies).
	info["pocket_plan"] = gen.get("spots", {}).get("pocket", {})
	info["map_lights"] = gen.get("lights", [])
	info["map_seed"] = int(gen.get("seed", 0))
	info["occluders_built"] = true


static func _geo_material(key: String) -> Material:
	match key:
		"linoleum": return surface_mat("mat/linoleum", Color(0.42, 0.44, 0.40), 0.8)
		"floor": return surface_mat("mat/floor", Color(0.46, 0.44, 0.40), 0.85)
		"tile": return surface_mat("mat/tile_floor", Color(0.55, 0.56, 0.54), 0.6)
		"asphalt": return surface_mat("mat/asphalt", Color(0.16, 0.16, 0.17), 0.95)
		"pavement": return surface_mat("mat/pavement", Color(0.4, 0.4, 0.38), 0.9)
		"ceiling": return surface_mat("mat/ceiling", Color(0.30, 0.31, 0.31), 0.95)
		"wall": return surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85)
		"wall_low": return surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85, Color(0.62, 0.78, 0.70))
		"wall_tile": return surface_mat("mat/wall_tile", Color(0.72, 0.74, 0.72), 0.5)
		"facade": return surface_mat("mat/concrete", Color(0.42, 0.42, 0.40), 0.9)
		"paint_white": return _paint_mat("white", Color(0.78, 0.78, 0.74))
		"paint_yellow": return _paint_mat("yellow", Color(0.8, 0.6, 0.1))
	return surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85)


static func _paint_mat(key: String, col: Color) -> Material:
	var ck := "paint|" + key
	if not _mat_cache.has(ck):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.85
		_mat_cache[ck] = m
	return _mat_cache[ck]


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
	var faces_by_chunk := {}   # "cx,cy" -> PackedVector3Array (collision triangles)

	func add_faces(cx: int, cy: int, tris: Array) -> void:
		var k := "%d,%d" % [cx, cy]
		if not faces_by_chunk.has(k):
			faces_by_chunk[k] = PackedVector3Array()
		var arr: PackedVector3Array = faces_by_chunk[k]
		arr.append_array(tris)
		faces_by_chunk[k] = arr

	## Mesh arrays per bucket, tangents generated (no resources are created: thread-safe).
	func to_arrays() -> Dictionary:
		var out := {}
		for k in buckets.keys():
			var st: SurfaceTool = buckets[k]
			st.generate_tangents()
			out[k] = st.commit_to_arrays()
		return out

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
			add_faces(cx, cy, [a, b, c, a, c, d])


## Floors, ceilings, walls, lintels, fence and canopy of one part. A wall face belongs to the part
## of the open tile it looks into, so the entrance building's outer walls seen from a wing hallway
## are rebuilt with the wings and the ones seen from inside never change.
static func _build_surfaces(gen: Dictionary, geo: GeoChunks, part: int = PART_BASE) -> void:
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length()
	var nr: Rect2i = gen.get("neutral_rect", Rect2i())
	var T := C.TILE

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
				if part_of(gen, tx, ty) != part:
					continue
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
				if not _open_char(nc) or part_of(gen, nx, ny) != part:
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
				_collision_face(geo, rows, tx, ty, d, maxf(top, C.WALL_H), cx, cy)
			if fence and part == PART_BASE:
				var y := FENCE_H
				geo.quad(cx, cy, "facade", Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1),
						Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1))
	if part == PART_BASE:
		_canopy(geo, gen)
		_ground_paint(geo, gen)


## Parking stall lines, the ambulance bay box and a crossing from the main doors: flat quads just
## above the asphalt.
static func _ground_paint(geo: GeoChunks, gen: Dictionary) -> void:
	var spots: Dictionary = gen.spots
	if not spots.has("stalls"):
		return
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
	if spots.has("entrance"):
		# SWEEP 4A HOOK (pharmacy, chunk 3): the gold pile's marked-off square is gone with the
		# pile itself; keep the faded crosswalk lines in front of the doors.
		var e: Vector2 = spots.entrance.pos
		for k in 7:
			var x := e.x - 1.8 + k * 0.6
			strip.call("paint_white", Vector2(x, e.y + 3.4), Vector2(x, e.y + 5.2), 0.3)


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
static func _collision_face(geo: GeoChunks, rows: PackedStringArray, tx: int, ty: int, d: Vector2i, top: float, cx := 0, cy := 0) -> void:
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
	geo.add_faces(cx, cy, [a, b, b + up, a, b + up, a + up])
	if convex1:
		# The corner's other face starts c back along -n; join the two with a slanted face.
		var p := k1 - r * c
		var q := k1 - n * c
		geo.add_faces(cx, cy, [p, q, q + up, p, q + up, p + up])


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

## One part's furniture as data: per chunk, the instance transforms of every shared mesh (packed
## for MultiMesh.buffer), the box colliders, and the loose-item anchors on top of the pieces.
static func _prep_furniture(gen: Dictionary, p: Dictionary) -> void:
	var part := int(p.part)
	var batches := {}     # "cx,cy" -> {mesh -> Array[Transform3D]}
	var colliders := {}   # "cx,cy" -> [[size, centre]]
	var anchors: Array = p.anchors
	var count := 0
	for e in gen.furniture:
		var kind: String = e.kind
		if e.get("canopy_post", false):
			kind = "canopy_post"
		var p2: Vector2 = e.pos
		if part_of(gen, int(floor(p2.x)), int(floor(p2.y))) != part:
			continue
		var pos := _w(p2, float(e.get("y", 0.0)))
		var xf := Transform3D(Basis(Vector3.UP, float(e.yaw)), pos)
		var ck := "%d,%d" % [int(p2.x) / CHUNK, int(p2.y) / CHUNK]
		if not batches.has(ck):
			batches[ck] = {}
		var b: Dictionary = batches[ck]
		for part_mesh in Factory.parts(kind):
			var mesh: Mesh = part_mesh.mesh
			if not b.has(mesh):
				b[mesh] = []
			(b[mesh] as Array).append(xf * (part_mesh.xform as Transform3D))
		var support := Rect2()
		var support_top := -1.0
		if _solid_piece(gen, kind, p2, float(e.yaw)):
			var s := Defs.size(kind)
			var fp := Defs.footprint_rect(kind, p2, float(e.yaw))
			var tiles := Defs.blocked_tiles(kind, p2, float(e.yaw))
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
			if not colliders.has(ck):
				colliders[ck] = []
			(colliders[ck] as Array).append([Vector3(fp.size.x * C.TILE, s.y, fp.size.y * C.TILE), centre])
			support = fp
			support_top = s.y + float(e.get("y", 0.0))
		var t := Vector2i(int(floor(p2.x)), int(floor(p2.y)))
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
	var furn := {}
	for ck in batches.keys():
		var b: Dictionary = batches[ck]
		var packed := {}
		for mesh in b.keys():
			var xfs: Array = b[mesh]
			var buf := PackedFloat32Array()
			buf.resize(xfs.size() * 12)
			for k in xfs.size():
				var x: Transform3D = xfs[k]
				var o := k * 12
				buf[o] = x.basis.x.x
				buf[o + 1] = x.basis.y.x
				buf[o + 2] = x.basis.z.x
				buf[o + 3] = x.origin.x
				buf[o + 4] = x.basis.x.y
				buf[o + 5] = x.basis.y.y
				buf[o + 6] = x.basis.z.y
				buf[o + 7] = x.origin.y
				buf[o + 8] = x.basis.x.z
				buf[o + 9] = x.basis.y.z
				buf[o + 10] = x.basis.z.z
				buf[o + 11] = x.origin.z
			packed[mesh] = [xfs.size(), buf]
		furn[ck] = packed
	p.furn = furn
	p.colliders = colliders
	p.out.anchors = anchors
	p["furniture_count"] = count


static func _commit_furniture_chunk(p: Dictionary, ck: String, holder: Node3D) -> void:
	var packed: Dictionary = p.furn.get(ck, {})
	var i := 0
	for mesh in packed.keys():
		var e: Array = packed[mesh]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = int(e[0])
		mm.buffer = e[1]
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "MM_%s_%d" % [ck.replace(",", "_"), i]
		mmi.multimesh = mm
		mmi.visibility_range_end = FURNITURE_RANGE
		mmi.visibility_range_end_margin = 4.0
		holder.add_child(mmi)
		i += 1
	var cols: Array = p.colliders.get(ck, [])
	if not cols.is_empty():
		var sb := StaticBody3D.new()
		sb.name = "Collide_" + ck.replace(",", "_")
		sb.collision_layer = C.L_WORLD
		sb.collision_mask = 0
		var n := 0
		for c in cols:
			sb.add_child(_box_shape(c[0], Transform3D(Basis.IDENTITY, c[1]), "S%d" % n))
			n += 1
		holder.add_child(sb)


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


static func _commit_containers(p: Dictionary, list: Array, holder: Node3D) -> void:
	var gen: Dictionary = p.gen
	var entries: Array = p.out.containers
	var anchors: Array = p.out.anchors
	for s in list:
		var tile: Vector2i = s.tile
		var type: String = s.type
		var xf := _site_xform(tile, s.wall)
		var id0 := "ct_%d_%d_0" % [tile.x, tile.y]
		var node: Node3D = null
		var cl: Array = []
		match type:
			"med_fridge":
				node = FridgeScript.create(id0)
				cl = [node]
			"drawer_unit":
				node = DrawerUnitScript.create_unit(tile)
				cl = node.get_meta("drawers")
			"station_drawers":
				node = StationScript.create_unit(tile)
				cl = node.get_meta("drawers")
			"trauma_bag":
				node = TraumaBagScript.create(id0)
				cl = [node]
			"pegboard":
				node = PegboardScript.create(id0)
				cl = [node]
		if node == null:
			continue
		node.transform = xf
		holder.add_child(node)
		var wi := _wing_of(gen, tile.x, tile.y)
		for c in cl:
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


## Floor spots against walls: one or two per wing room, a few along each wing's hallways.
## Data only (the wings part; the entrance building's rooms are safe rooms and get none).
static func _floor_anchors(gen: Dictionary) -> Array:
	var rows: PackedStringArray = gen.rows
	var w: int = gen.width
	var rng := MG.Rng.new((int(gen.get("wing_seed", gen.seed)) ^ 0x3c6ef372) & 0xFFFFFFFF)
	var anchors: Array = []
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
			var q := Vector2i(c[0], c[1])
			var ok := true
			for o in placed:
				if absi(q.x - o.x) + absi(q.y - o.y) < 10:
					ok = false
					break
			if ok:
				placed.append(q)
				add.call(q.x, q.y, c[2])
	return anchors


# ---------------------------------------------------------------------------
# Landmarks: clock, lectern, tables, shelf and markers
# ---------------------------------------------------------------------------

## Spawns, tables, the clock, the shelf and the lectern spot, as data.
static func _fill_landmarks(gen: Dictionary, info: Dictionary) -> void:
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
	if spots.has("shelf"):
		info["shelf"] = {"position": _w(spots.shelf.pos), "yaw": float(spots.shelf.yaw)}
	if spots.has("lectern"):
		info["lectern"] = {"position": _w(spots.lectern.pos), "yaw": float(spots.lectern.yaw)}


## Builds at the "lectern" spot MapGen reserved in the break room (docs/CONTRACTS.md "Hospital"
## still calls the anchor `lectern`/`lectern_node`; sweep 4a chunk 4 puts a database terminal
## there instead of the old guide's binder and reading stand).
static func _commit_lectern(p: Dictionary, root: Node3D) -> void:
	var spots: Dictionary = p.gen.spots
	if not spots.has("lectern"):
		return
	var terminal := _make_lectern()
	var sb := StaticBody3D.new()
	sb.name = "Terminal"
	sb.collision_layer = C.L_WORLD
	sb.collision_mask = 0
	sb.position = _w(spots.lectern.pos)
	sb.rotation.y = float(spots.lectern.yaw)
	sb.add_child(terminal)
	Legacy._fit_collider(terminal)
	var size: Vector3 = terminal.get_meta("collider_size")
	sb.add_child(_box_shape(size, Transform3D(Basis.IDENTITY, Vector3(0.0, terminal.get_meta("collider_y"), 0.0)), "Shape"))
	root.add_child(sb)
	p.out.lectern_node = sb


## The database terminal (sweep 4a chunk 4) when it exists, else the legacy wooden stand.
static func _make_lectern() -> Node3D:
	if ResourceLoader.exists(TERMINAL_MODEL_PATH):
		var s = load(TERMINAL_MODEL_PATH)
		if s is GDScript:
			for m in (s as GDScript).get_script_method_list():
				if m.name == "make_terminal":
					var n = s.call("make_terminal")
					if n is Node3D:
						return n
					break
	return Legacy._make_lectern()




# ---------------------------------------------------------------------------
# Lights
# ---------------------------------------------------------------------------

static func _commit_lights(p: Dictionary, list: Array, lights_root: Node3D) -> void:
	var seed: int = p.gen.get("seed", 0)
	var out: Array = p.out.lights
	for l in list:
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

## Every sign of one part as [text, position, yaw, style]. The count cap runs over the whole map
## in the same order as ever, so a sign never moves between shifts of a run.
static func _sign_specs(gen: Dictionary, part: int) -> Array:
	var out: Array = []
	var count := 0
	# Wing names over the entrance building's doorways into each wing.
	for wd in gen.wings:
		var entry: Array = wd.entry
		var mid := (Vector2(entry[0]) + Vector2(entry[1])) * 0.5 + Vector2(0.5, 0.5)
		var dir: Vector2i = wd.dir
		var f := Vector2(-dir.x, -dir.y)
		if part == PART_BASE:
			out.append([WING_LABELS.get(String(wd.id), String(wd.id).to_upper()), _w(mid - f * 0.51, SIGN_H), Defs.yaw_facing(-f), "wing"])
		count += 1
	# Exit over the main doors, inside; "EMERGENCY" outside.
	var ent: Dictionary = gen.spots.get("entrance", {})
	if not ent.is_empty():
		var p: Vector2 = ent.pos
		if part == PART_BASE:
			out.append(["EXIT", _w(p + Vector2(0, -0.51), SIGN_H), Defs.yaw_facing(Vector2(0, 1)), "exit"])
			out.append(["EMERGENCY", _w(p + Vector2(0, 0.52), 3.6), Defs.yaw_facing(Vector2(0, -1)), "emergency"])
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
		var mid := Vector2.ZERO
		var f := Vector2.ZERO
		if not (r.doors as Array).is_empty():
			door = r.doors[0]
			mid = Vector2(door) + Vector2(0.5, 0.5)
			if r.has("door2") or (String(r.kind) == "or" and (r.doors as Array).size() == 2):
				mid = (Vector2(r.doors[0]) + Vector2(r.doors[1])) * 0.5 + Vector2(0.5, 0.5)
		elif not (r.get("open", []) as Array).is_empty():
			var op: Array = r.open
			door = op[op.size() / 2]
			mid = Vector2(door) + Vector2(0.5, 0.5)
		if door.x < 0:
			continue
		for d in MG.DIRS:
			var inside := door + d
			if not _room_of(gen, inside.x, inside.y).is_empty() and int(_room_of(gen, inside.x, inside.y).id) == int(r.id):
				f = Vector2(-d.x, -d.y)
				break
		if f == Vector2.ZERO:
			continue
		if part_of(gen, door.x, door.y) == part:
			out.append([label, _w(mid + f * 0.51, SIGN_H), Defs.yaw_facing(-f), "room"])
		count += 1
	return out


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
		var tex := Legacy._text_texture(text, fg, bg, int(wide * 240.0) if style != "emergency" else 384, 56 if style != "emergency" else 82)
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
		# SWEEP 4A HOOK (fog lot, chunk 2): the ambulance is a driven vehicle now (shift_loop.gd /
		# ambulance.gd), not a static prop; this is only the bay parking spot and the lane it
		# drives in along.
		info["ambulance"] = {"position": _w(spots.ambulance.pos), "yaw": float(spots.ambulance.yaw),
				"lane_start": _w(spots.ambulance.get("lane_start", spots.ambulance.pos))}
	var spawns: Array = []
	for p in spots.get("neutral_spawns", []):
		spawns.append(_w(p))
	var neutral := {"spawn_points": spawns}
	if spots.has("shop"):
		# SWEEP 4A HOOK (fog lot, chunk 2 / pharmacy, chunk 3): a placeholder spot only; the real
		# pharmacy and furnace are built off the lobby (info["safe_zone"] below).
		neutral["shop"] = {"position": _w(spots.shop.pos), "yaw": float(spots.shop.yaw)}
	info["neutral"] = neutral
	# SWEEP 4A HOOK (fog lot, chunk 2): space off the lobby chunk 3's pharmacy and crematorium
	# build into; reserved now so both have fixed spots.
	var reserve: Dictionary = spots.get("reserve", {})
	if reserve.has("pharmacy") or reserve.has("crematorium"):
		var sz := {}
		for key in ["pharmacy", "crematorium"]:
			if reserve.has(key):
				var r: Rect2i = reserve[key]
				sz[key + "_rect"] = Rect2(Vector2(r.position) * C.TILE, Vector2(r.size) * C.TILE)
		info["safe_zone"] = sz
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
## The navigation mesh over every open tile, furniture that blocks movement cut out. Door tiles are
## open: agents walk up to a door and it opens for them (scripts/doors/doors.gd). Pure data, so the
## wing loader bakes it on a worker thread.
static func bake_nav(gen: Dictionary) -> NavigationMesh:
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
	return nm


## The occluder quads of one part's wall faces (both windings), as [vertices, indices]: indoors the
## single biggest performance win (game.gd `_add_occluders` built the same for the whole map).
static func _occluder_arrays(gen: Dictionary, part: int) -> Array:
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for ty in h:
		for tx in w:
			if rows[ty][tx] != "#":
				continue
			for d in MG.DIRS:
				var nx: int = tx + d.x
				var ny: int = ty + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h or rows[ny][nx] == "#":
					continue
				if part_of(gen, nx, ny) != part:
					continue
				var cx := (tx + 0.5) * C.TILE
				var cz := (ty + 0.5) * C.TILE
				var half := C.TILE * 0.5
				var ox: float = d.x * half
				var oz: float = d.y * half
				var ax: float = half if d.x == 0 else 0.0
				var az: float = half if d.y == 0 else 0.0
				var b := verts.size()
				verts.append(Vector3(cx + ox - ax, 0.0, cz + oz - az))
				verts.append(Vector3(cx + ox + ax, 0.0, cz + oz + az))
				verts.append(Vector3(cx + ox + ax, C.WALL_H, cz + oz + az))
				verts.append(Vector3(cx + ox - ax, C.WALL_H, cz + oz - az))
				for t in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
					idx.append(b + t)
	return [verts, idx]
