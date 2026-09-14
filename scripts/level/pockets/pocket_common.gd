extends RefCounted
## POCKETS: what the Factory and the Restaurant share. A pocket's own tile grid (same 1.5 m tiles
## as the hospital), placing the entrance stubs on its outer walls, merged procedural meshes,
## MultiMesh props, surfaces from the grid, occluders and the navigation bake.
##
## Grid (local tiles, the pocket's world tile is origin + local):
##   cells    '#' solid, '.' floor         room  per tile: index into `rooms`, -1 solid
##   wall_h   per solid tile: height of a free-standing wall (0 = up to the room's ceiling)
##   nav      1 = open but left out of the navigation mesh (the stub halves nobody walks, props)
##   stub     1 = drawn by the stub copy (stub.gd), not by the pocket
## rooms: [{name, ceil, floor, wall, wall_low, ceiling, split, place}]

const Stub := preload("res://scripts/level/pockets/stub.gd")
const HB := preload("res://scripts/hospital_builder.gd")

const T := 1.5
const CHUNK := 16

static var _mesh_cache := {}
static var _mat_cache := {}
static var _tex_cache := {}


# =========================================================================
# grid
# =========================================================================

static func new_grid(w: int, h: int) -> Dictionary:
	var n := w * h
	var cells := PackedByteArray()
	cells.resize(n)
	cells.fill(35)
	var room := PackedInt32Array()
	room.resize(n)
	room.fill(-1)
	var wall_h := PackedFloat32Array()
	wall_h.resize(n)
	var nav := PackedByteArray()
	nav.resize(n)
	var stub := PackedByteArray()
	stub.resize(n)
	var reserved := PackedByteArray()
	reserved.resize(n)
	return {"w": w, "h": h, "cells": cells, "room": room, "wall_h": wall_h, "nav": nav, "stub": stub,
			"reserved": reserved, "rooms": []}


static func inb(g: Dictionary, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < int(g.w) and y < int(g.h)


static func idx(g: Dictionary, x: int, y: int) -> int:
	return y * int(g.w) + x


static func is_open(g: Dictionary, x: int, y: int) -> bool:
	return inb(g, x, y) and (g.cells as PackedByteArray)[idx(g, x, y)] != 35


static func set_open(g: Dictionary, x: int, y: int, room: int) -> void:
	if not inb(g, x, y):
		return
	var i := idx(g, x, y)
	g.cells[i] = 46
	g.room[i] = room
	g.wall_h[i] = 0.0


static func set_solid(g: Dictionary, x: int, y: int, height := 0.0) -> void:
	if not inb(g, x, y):
		return
	var i := idx(g, x, y)
	g.cells[i] = 35
	g.room[i] = -1
	g.wall_h[i] = height


static func add_room(g: Dictionary, r: Dictionary) -> int:
	(g.rooms as Array).append(r)
	return g.rooms.size() - 1


static func carve(g: Dictionary, rect: Rect2i, room: int) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			set_open(g, x, y, room)


static func rows(g: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for y in int(g.h):
		out.append((g.cells as PackedByteArray).slice(y * int(g.w), (y + 1) * int(g.w)).get_string_from_ascii())
	return out


## Mark tiles no layout feature may take (kept clear in front of an entrance).
static func reserve(g: Dictionary, rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if inb(g, x, y):
				g.reserved[idx(g, x, y)] = 1


static func is_reserved(g: Dictionary, rect: Rect2i) -> bool:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if not inb(g, x, y) or g.reserved[idx(g, x, y)] == 1:
				return true
	return false


# =========================================================================
# entrance stubs on the pocket's walls
# =========================================================================

## Find a place on the outer walls for every stub. `walls`: [{from: Vector2i, dir: Vector2i (along
## the wall), len: int, ev: Vector2i (outward)}], each a straight run of wall tiles with interior
## floor at -ev. Stubs are tried at evenly spread positions, wall by wall in the given order starting
## from a seeded offset. Returns [{o, eu, ev}] in stub order (a missing entry is {}).
static func place_ports(g: Dictionary, stubs: Array, walls: Array, rng: RandomNumberGenerator) -> Array:
	var ports: Array = []
	var start := rng.randi_range(0, maxi(0, walls.size() - 1))
	for i in stubs.size():
		var s: Dictionary = stubs[i]
		var handed := Stub.det(s.eu, s.ev)
		var done := {}
		for k in walls.size():
			var wall: Dictionary = walls[(start + i + k) % walls.size()]
			done = _port_on_wall(g, s, handed, wall, rng)
			if not done.is_empty():
				break
		ports.append(done)
		if not done.is_empty():
			stamp_stub(g, s, done)
	return ports


static func _port_on_wall(g: Dictionary, s: Dictionary, handed: int, wall: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var w: int = s.w
	var d: int = s.d
	var ev: Vector2i = wall.ev
	var eu := Stub.pocket_eu(ev, handed)
	var along: Vector2i = wall.dir
	var n: int = wall.len
	var offsets: Array = range(0, n)
	# Middle-out from a seeded point, so two stubs on one wall spread apart.
	var mid := rng.randi_range(n / 4, maxi(n / 4, 3 * n / 4))
	offsets.sort_custom(func(a, b): return absi(a - mid) < absi(b - mid))
	for off in offsets:
		var p0: Vector2i = (wall.from as Vector2i) + along * off   # the wall tile at u = w - 2
		var o: Vector2i = p0 - eu * (w - Stub.CORRIDOR) + ev
		if _port_fits(g, s, o, eu, ev):
			return {"o": o, "eu": eu, "ev": ev}
	return {}


static func _port_fits(g: Dictionary, s: Dictionary, o: Vector2i, eu: Vector2i, ev: Vector2i) -> bool:
	var w: int = s.w
	var d: int = s.d
	# The whole block, walls included, must be solid and unreserved, except the front wall row which
	# is the pocket's own outer wall.
	for v in range(-1, d + 1):
		for u in range(-1, w + 1):
			var p: Vector2i = o + eu * u + ev * v
			if not inb(g, p.x, p.y) or g.reserved[idx(g, p.x, p.y)] == 1 or is_open(g, p.x, p.y):
				return false
	# The opening looks onto interior floor with room to either side; the rest of the front wall row
	# is backed by interior floor or wall, never by another opening.
	for u in range(Stub.CORRIDOR - 3 + w - Stub.CORRIDOR, w + 2):
		var q: Vector2i = o + eu * u - ev * 2
		if not is_open(g, q.x, q.y) or g.reserved[idx(g, q.x, q.y)] == 1:
			return false
	for k in range(2, 5):
		for u in range(w - Stub.CORRIDOR - 1, w + 1):
			var q: Vector2i = o + eu * u - ev * (k + 1)
			if not is_open(g, q.x, q.y):
				return false
	return true


## Carve the stub copy into the grid: its open tiles (drawn by stub.gd), its unwalked half left out
## of the navigation mesh, and the floor in front of the opening kept clear.
static func stamp_stub(g: Dictionary, s: Dictionary, port: Dictionary) -> void:
	var o: Vector2i = port.o
	var eu: Vector2i = port.eu
	var ev: Vector2i = port.ev
	var w: int = s.w
	var d: int = s.d
	for v in range(-1, d + 1):
		for u in range(-1, w + 1):
			var p: Vector2i = o + eu * u + ev * v
			if inb(g, p.x, p.y):
				g.reserved[idx(g, p.x, p.y)] = 1
	for t in Stub.open_tiles(w, d, false):
		var p: Vector2i = o + eu * t.x + ev * t.y
		set_open(g, p.x, p.y, -2)
		var i := idx(g, p.x, p.y)
		g.stub[i] = 1
		if Stub.phantom_pocket(w, t):
			g.nav[i] = 1
	# Clear floor in front of the opening.
	var a: Vector2i = o + eu * (w - Stub.CORRIDOR - 2) - ev * 2
	var b: Vector2i = o + eu * (w + 1) - ev * 6
	var r := Rect2i(Vector2i(mini(a.x, b.x), mini(a.y, b.y)), Vector2i(absi(a.x - b.x) + 1, absi(a.y - b.y) + 1))
	reserve(g, r)


# =========================================================================
# surfaces from the grid
# =========================================================================

class Geo extends RefCounted:
	var sts := {}        # "cx,cy|mat" -> SurfaceTool
	var mats := {}       # mat key -> Material
	var faces := PackedVector3Array()
	var occ_v := PackedVector3Array()
	var occ_i := PackedInt32Array()

	func quad(cx: int, cy: int, mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
			ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, collide := false) -> void:
		var k := "%d,%d|%s" % [cx, cy, mat]
		if not sts.has(k):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[k] = s
		var st: SurfaceTool = sts[k]
		var n := (c - a).cross(b - a).normalized()
		for v in [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [d, ud]]:
			st.set_normal(n)
			st.set_uv(v[1])
			st.add_vertex(v[0])
		if collide:
			faces.append_array([a, b, c, a, c, d])

	func occluder_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		var base := occ_v.size()
		occ_v.append_array([a, b, c, d])
		for i in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
			occ_i.append(base + i)

	func commit(parent: Node3D, layers := 1, vis_range := 0.0) -> StaticBody3D:
		var holder := Node3D.new()
		holder.name = "Surfaces"
		parent.add_child(holder)
		var keys := sts.keys()
		keys.sort()
		for k in keys:
			var st: SurfaceTool = sts[k]
			st.generate_tangents()
			var mi := MeshInstance3D.new()
			mi.name = String(k).replace(",", "_").replace("|", "_")
			mi.mesh = st.commit()
			mi.material_override = mats.get(String(k).get_slice("|", 1))
			mi.layers = layers
			if vis_range > 0.0:
				mi.visibility_range_end = vis_range
			holder.add_child(mi)
		var body := StaticBody3D.new()
		body.name = "Collision"
		body.collision_layer = C.L_WORLD
		body.collision_mask = 0
		parent.add_child(body)
		if not faces.is_empty():
			var cs := CollisionShape3D.new()
			var concave := ConcavePolygonShape3D.new()
			concave.set_faces(faces)
			cs.shape = concave
			body.add_child(cs)
		if not occ_v.is_empty():
			var occ := ArrayOccluder3D.new()
			occ.set_arrays(occ_v, occ_i)
			var oi := OccluderInstance3D.new()
			oi.name = "Occluders"
			oi.occluder = occ
			parent.add_child(oi)
		return body


## Floors, ceilings and walls of every open, non-stub tile of the grid, in world metres.
## Room keys: ceil (m), floor / ceiling / wall / wall_low (material keys in geo.mats), split (m, 0 =
## one material), uv (metres per UV unit, default 1). Returns floor nav faces too.
static func build_surfaces(g: Dictionary, origin: Vector2i, geo: Geo, nav_faces: PackedVector3Array) -> void:
	var w: int = g.w
	var h: int = g.h
	var ox := origin.x * T
	var oz := origin.y * T
	var rooms: Array = g.rooms
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	for ty in h:
		for tx in w:
			var i := ty * w + tx
			if g.cells[i] == 35:
				continue
			var x0 := ox + tx * T
			var z0 := oz + ty * T
			var x1 := x0 + T
			var z1 := z0 + T
			if g.nav[i] == 0:
				nav_faces.append_array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1),
						Vector3(x0, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])
			if g.stub[i] == 1:
				continue
			var ri: int = g.room[i]
			if ri < 0:
				continue
			var r: Dictionary = rooms[ri]
			var cx := tx / CHUNK
			var cy := ty / CHUNK
			var ceil_y := float(r.ceil)
			var uv := float(r.get("uv", 1.0))
			if String(r.get("floor", "")) != "":
				geo.quad(cx, cy, r.floor, Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1),
						Vector2(x0, z0) / uv, Vector2(x1, z0) / uv, Vector2(x1, z1) / uv, Vector2(x0, z1) / uv)
			if String(r.get("ceiling", "")) != "":
				geo.quad(cx, cy, r.ceiling, Vector3(x0, ceil_y, z0), Vector3(x0, ceil_y, z1), Vector3(x1, ceil_y, z1), Vector3(x1, ceil_y, z0),
						Vector2(x0, z0) / uv, Vector2(x0, z1) / uv, Vector2(x1, z1) / uv, Vector2(x1, z0) / uv)
			for d in dirs:
				var nx := tx + d.x
				var ny := ty + d.y
				var centre := Vector3(ox + (nx + 0.5) * T, 0.0, oz + (ny + 0.5) * T)
				var nrm := Vector3(-d.x, 0.0, -d.y)
				if not inb(g, nx, ny) or g.cells[ny * w + nx] == 35:
					var top := ceil_y
					var wh := float(g.wall_h[ny * w + nx]) if inb(g, nx, ny) else 0.0
					if wh > 0.0:
						top = minf(top, wh)
					var split := float(r.get("split", 0.0))
					if split > 0.0 and String(r.get("wall_low", "")) != "":
						vface(geo, cx, cy, r.wall_low, centre, nrm, 0.0, minf(split, top), uv, true)
						vface(geo, cx, cy, r.wall, centre, nrm, minf(split, top), top, uv, true)
					else:
						vface(geo, cx, cy, r.wall, centre, nrm, 0.0, top, uv, true)
					if top >= 2.4:
						var rr := nrm.cross(Vector3.UP)
						var mid := centre + nrm * (T * 0.5)
						var k0 := mid - rr * (T * 0.5)
						var k1 := mid + rr * (T * 0.5)
						geo.occluder_quad(k0, k1, k1 + Vector3(0, top, 0), k0 + Vector3(0, top, 0))
				elif g.stub[ny * w + nx] == 1:
					# The opening of a stub copy: the pocket's wall above its 3 m ceiling.
					if ceil_y > C.WALL_H + 0.01:
						vface(geo, cx, cy, r.wall, centre, nrm, C.WALL_H, ceil_y, uv, false)
				else:
					var r2: int = g.room[ny * w + nx]
					if r2 >= 0 and r2 != ri and float(rooms[r2].ceil) < ceil_y - 0.01:
						# A lower room next door: the wall above its ceiling (an open doorway's header).
						vface(geo, cx, cy, r.wall, centre, nrm, float(rooms[r2].ceil), ceil_y, uv, false)


## A vertical face on the boundary of the tile centred at `centre`, facing `n`, from y0 to y1.
static func vface(geo: Geo, cx: int, cy: int, mat: String, centre: Vector3, n: Vector3, y0: float, y1: float, uv := 1.0, collide := false) -> void:
	if y1 - y0 <= 0.001:
		return
	var r := n.cross(Vector3.UP)
	var mid := centre + n * (T * 0.5)
	var p0 := mid - r * (T * 0.5)
	var v0 := Vector3(p0.x, y0, p0.z)
	var v1 := v0 + r * T
	var v2 := v1 + Vector3(0.0, y1 - y0, 0.0)
	var v3 := v0 + Vector3(0.0, y1 - y0, 0.0)
	var u0 := v0.x * absf(r.x) + v0.z * absf(r.z)
	var u1 := u0 + (T if (r.x + r.z) > 0.0 else -T)
	geo.quad(cx, cy, mat, v0, v1, v2, v3, Vector2(u0, -y0) / uv, Vector2(u1, -y0) / uv,
			Vector2(u1, -y1) / uv, Vector2(u0, -y1) / uv, collide)


# =========================================================================
# meshes
# =========================================================================

## Merged procedural mesh: parts per material, one surface per material.
class MeshBuilder extends RefCounted:
	var sts := {}
	var mat_of := {}

	func _st(mat_key: String, mat: Material) -> SurfaceTool:
		if not sts.has(mat_key):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[mat_key] = s
			mat_of[mat_key] = mat
		return sts[mat_key]

	## An axis-aligned box of `size` centred at xf's origin, turned by xf's basis.
	func box(mat_key: String, mat: Material, xf: Transform3D, size: Vector3) -> void:
		var st := _st(mat_key, mat)
		var hx := size.x * 0.5
		var hy := size.y * 0.5
		var hz := size.z * 0.5
		var faces := [
			[Vector3(0, 0, 1), [Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)], Vector2(size.x, size.y)],
			[Vector3(0, 0, -1), [Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz)], Vector2(size.x, size.y)],
			[Vector3(1, 0, 0), [Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz)], Vector2(size.z, size.y)],
			[Vector3(-1, 0, 0), [Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz)], Vector2(size.z, size.y)],
			[Vector3(0, 1, 0), [Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz)], Vector2(size.x, size.z)],
			[Vector3(0, -1, 0), [Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)], Vector2(size.x, size.z)],
		]
		for f in faces:
			var n: Vector3 = (xf.basis * (f[0] as Vector3)).normalized()
			var c: Array = f[1]
			var uvs: Vector2 = f[2]
			var uv := [Vector2(0, uvs.y), Vector2(uvs.x, uvs.y), Vector2(uvs.x, 0), Vector2(0, 0)]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_normal(n)
				st.set_uv(uv[k])
				st.add_vertex(xf * (c[k] as Vector3))

	## A cylinder along local Y, centred at xf's origin.
	func cylinder(mat_key: String, mat: Material, xf: Transform3D, radius: float, height: float, segments := 10, top_radius := -1.0, caps := true) -> void:
		var st := _st(mat_key, mat)
		var tr := radius if top_radius < 0.0 else top_radius
		var hy := height * 0.5
		for i in segments:
			var a0 := TAU * i / segments
			var a1 := TAU * (i + 1) / segments
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			var p := [d0 * radius + Vector3(0, -hy, 0), d1 * radius + Vector3(0, -hy, 0), d1 * tr + Vector3(0, hy, 0), d0 * tr + Vector3(0, hy, 0)]
			var ns := [d0, d1, d1, d0]
			for k in [0, 2, 1, 0, 3, 2]:
				st.set_normal((xf.basis * (ns[k] as Vector3)).normalized())
				st.set_uv(Vector2(float(i if k in [0, 3] else i + 1) / segments, 1.0 if k < 2 else 0.0))
				st.add_vertex(xf * (p[k] as Vector3))
			if caps:
				for cap in [[-hy, radius, Vector3.DOWN], [hy, tr, Vector3.UP]]:
					var y: float = cap[0]
					var rr: float = cap[1]
					var nn: Vector3 = cap[2]
					var tri := [Vector3(0, y, 0), d0 * rr + Vector3(0, y, 0), d1 * rr + Vector3(0, y, 0)]
					var order := [0, 1, 2] if nn.y < 0.0 else [0, 2, 1]
					for k in order:
						st.set_normal((xf.basis * nn).normalized())
						st.set_uv(Vector2(0.5, 0.5))
						st.add_vertex(xf * (tri[k] as Vector3))

	func commit() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		var keys := sts.keys()
		keys.sort()
		for k in keys:
			var st: SurfaceTool = sts[k]
			st.generate_tangents()
			st.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat_of[k])
		return mesh


## A mesh built once per session by `key` (cached so its materials compile once).
static func cached_mesh(key: String, make: Callable) -> Mesh:
	if not _mesh_cache.has(key):
		_mesh_cache[key] = make.call()
	return _mesh_cache[key]


static func mat(key: String, albedo: Color, rough := 0.8, metal := 0.0, emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	_mat_cache[key] = m
	return m


## A tiling texture set from Assets, world-triplanar (props need no UVs), tinted, or a flat colour.
static func tri_mat(key: String, asset: String, tint: Color, scale := 0.5, rough := 0.85, metal := 0.0) -> Material:
	if _mat_cache.has(key):
		return _mat_cache[key]
	var base: Material = HB.surface_mat(asset, tint, rough)
	var m: StandardMaterial3D
	if base is StandardMaterial3D:
		m = (base as StandardMaterial3D).duplicate()
		m.albedo_color = tint
	else:
		m = StandardMaterial3D.new()
		m.albedo_color = tint
	m.roughness = rough
	m.metallic = metal
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	m.uv1_triplanar_sharpness = 4.0
	_mat_cache[key] = m
	return m


## A procedural texture, generated once per session.
static func cached_texture(key: String, make: Callable) -> Texture2D:
	if not _tex_cache.has(key):
		_tex_cache[key] = make.call()
	return _tex_cache[key]


# =========================================================================
# props: MultiMesh per mesh per chunk
# =========================================================================

class Props extends RefCounted:
	var batches := {}     # "cx,cy" -> {mesh: [Transform3D]}
	var ranges := {}      # mesh -> visibility range (0 = none)
	var shadows := {}     # mesh -> cast shadows

	func add(mesh: Mesh, xf: Transform3D, vis_range := 48.0, cast_shadow := true) -> void:
		var ck := "%d,%d" % [int(floor(xf.origin.x / (CHUNK * T))), int(floor(xf.origin.z / (CHUNK * T)))]
		if not batches.has(ck):
			batches[ck] = {}
		var b: Dictionary = batches[ck]
		if not b.has(mesh):
			b[mesh] = []
		(b[mesh] as Array).append(xf)
		ranges[mesh] = vis_range
		shadows[mesh] = cast_shadow

	func commit(parent: Node3D) -> void:
		var holder := Node3D.new()
		holder.name = "Props"
		parent.add_child(holder)
		var keys := batches.keys()
		keys.sort()
		var n := 0
		for ck in keys:
			var b: Dictionary = batches[ck]
			for mesh in b.keys():
				var xfs: Array = b[mesh]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mesh
				mm.instance_count = xfs.size()
				for k in xfs.size():
					mm.set_instance_transform(k, xfs[k])
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "MM_%d" % n
				mmi.multimesh = mm
				var vr := float(ranges.get(mesh, 0.0))
				if vr > 0.0:
					mmi.visibility_range_end = vr
					mmi.visibility_range_end_margin = 4.0
				if not bool(shadows.get(mesh, true)):
					mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				holder.add_child(mmi)
				n += 1


## A static collision box (world transform).
static func collider(body: StaticBody3D, xf: Transform3D, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf
	body.add_child(cs)


## A light the Perception system understands (level_info.lights: a node with an OmniLight3D "Bulb").
static func omni(parent: Node3D, pos: Vector3, energy: float, rng: float, col: Color, fog := 1.0, shadow := false, atten := 1.0) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	var bulb := OmniLight3D.new()
	bulb.name = "Bulb"
	bulb.light_energy = energy
	bulb.omni_range = rng
	bulb.omni_attenuation = atten
	bulb.light_color = col
	bulb.light_volumetric_fog_energy = fog
	bulb.shadow_enabled = shadow
	bulb.light_cull_mask = 0xFFFFF & ~(1 << Stub.COPY_LAYER_BIT)
	bulb.set_meta("base_energy", energy)
	n.add_child(bulb)
	parent.add_child(n)
	return n


# =========================================================================
# containers
# =========================================================================

## World transform of a wall-standing piece on pocket tile `tile` against the wall toward `wall`.
static func site_xform(origin: Vector2i, tile: Vector2i, wall: Vector2i) -> Transform3D:
	var yaw := atan2(float(wall.x), float(wall.y))
	var t := origin + tile
	var pos := C.tile_to_world(t.x, t.y) + Vector3(wall.x, 0.0, wall.y) * (T * 0.5)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


## Build a container like HospitalBuilder does and record it in out.containers (and its anchors).
static func container(parent: Node3D, out: Dictionary, origin: Vector2i, tile: Vector2i, wall: Vector2i, type: String, room_kind: String) -> void:
	var t := origin + tile
	var xf := site_xform(origin, tile, wall)
	var id0 := "ct_%d_%d_0" % [t.x, t.y]
	var node: Node3D = null
	var list: Array = []
	match type:
		"med_fridge":
			node = HB.FridgeScript.create(id0)
			list = [node]
		"drawer_unit":
			node = HB.DrawerUnitScript.create_unit(t)
			list = node.get_meta("drawers")
		"station_drawers":
			node = HB.StationScript.create_unit(t)
			list = node.get_meta("drawers")
		"trauma_bag":
			node = HB.TraumaBagScript.create(id0)
			list = [node]
		"pegboard":
			node = HB.PegboardScript.create(id0)
			list = [node]
	if node == null:
		return
	node.transform = xf
	parent.add_child(node)
	for c in list:
		var ct: Node3D = c
		out.containers.append({"id": String(ct.get_meta("interact_id")), "type": type, "room_kind": room_kind,
				"wing": String(out.wing), "depth": int(out.depth), "node": ct,
				"position": (xf * ct.transform).origin if ct != node else xf.origin, "slots": ct.slot_count()})
	for a in node.get_meta("anchors", []):
		var at: Transform3D = xf * (a.xform as Transform3D)
		out.loose_anchors.append({"position": at.origin, "yaw": xf.basis.get_euler().y, "surface": a.surface,
				"room_kind": room_kind, "wing": String(out.wing), "depth": int(out.depth)})


static func anchor(out: Dictionary, pos: Vector3, yaw: float, surface: String, room_kind: String) -> void:
	out.loose_anchors.append({"position": pos, "yaw": yaw, "surface": surface, "room_kind": room_kind,
			"wing": String(out.wing), "depth": int(out.depth)})


# =========================================================================
# navigation
# =========================================================================

static func bake_nav(faces: PackedVector3Array) -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.agent_radius = HB.NAV_AGENT_RADIUS
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	if faces.is_empty():
		return nm
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	# Recast lifts the surface a voxel or two; agents compare waypoints in 3D, so put it back down
	# (the catwalk moves with the floor: every vertex drops by the same amount).
	HB.Legacy._drop_nav_to_floor(nm)
	return nm


## A text label texture (signs, menus).
static func text_texture(text: String, fg: Color, bg: Color, iw := 256, ih := 64) -> Texture2D:
	return HB.Legacy._text_texture(text, fg, bg, iw, ih)
