extends RefCounted
## POCKETS: one entrance stub, in its own frame, and the geometry of its pocket-side copy.
##
## Stub-local tiles (u, v): u runs along the slot from leg 1 (u 0..1) to leg 3 (u w-2..w-1), v runs
## away from the hospital hallway (0 beside the front wall, d-1 at the back). Continuous local
## coordinates (s, t) in tiles: tile (u, v) covers [u, u+1] x [v, v+1].
##
##        v=d  ###############
##             #2 bend1  leg2 : seam : leg2  bend2#     leg 2 along the back, the seam at s = w / 2
##             #1 #################### 3#
##        v=0  #1 #                   # 3#
##        v=-1 ..##                   ##..            hospital: leg 1's mouth opens onto the hallway
##             hallway                  pocket         pocket: leg 3's opening leads into the space
##
## The hospital copy (built by HospitalBuilder from the carved tiles) and the pocket copy (built here
## under a Node3D whose transform is the seam's H->P transform, so every vertex and UV is the
## hospital's own) are identical. A body that stands past the seam in the hospital copy (s >= w / 2)
## is moved to the pocket copy; one that stands before it in the pocket copy is moved back. Nothing
## past the seam can be seen from the other side except the far half of leg 2, the far bend and at
## most CORRIDOR^2 / L tiles of the far leg (L = half the straight part of leg 2), which exist in
## both copies. `size_ok` keeps the mouth itself (and the hallway past it) out of that view. Hospital
## lights near a stub reach its walls (fixtures cast no shadows): the pocket copy gets a copy of each
## of them that lights only the copy (COPY_LAYER_BIT), so both copies are lit the same.

const T := 1.5
const CORRIDOR := 2
const MIN_W := 8
## How much of leg 1 must stay unseen from the other side, tiles in front of the front wall.
const MOUTH_MARGIN := 0.5
## Render layer (bit index) of the pocket copy's surfaces: the pocket's own lights leave it out, so
## nothing inside a pocket brightens the part of the stub the hospital side can see.
const COPY_LAYER_BIT := 11
## Render layer (bit index) of the pockets' own surfaces and props: the stub copy's lights leave it out (they
## would light the pocket through the stub's walls) but light everything else, bodies and hands included.
const POCKET_LAYER_BIT := 12

const HB := preload("res://scripts/hospital_builder.gd")
const Legacy := preload("res://scripts/level/legacy_builder.gd")


static func straight_half(w: int) -> float:
	return float(w - 2 * CORRIDOR) * 0.5


## How far past the bend (tiles into the far leg) a sight line through the seam can reach.
static func peek(w: int) -> float:
	var l := straight_half(w)
	return float(CORRIDOR * CORRIDOR) / maxf(0.5, l)


static func size_ok(w: int, d: int) -> bool:
	if w < MIN_W:
		return false
	# The part of leg 1 visible from the other side starts at v = d - CORRIDOR - peek.
	return float(d - CORRIDOR) - peek(w) >= MOUTH_MARGIN


static func seam_s(w: int) -> float:
	return float(w) * 0.5


## Open tiles of the stub (Vector2i u, v). `hospital`: with leg 1's mouth; else with leg 3's opening.
static func open_tiles(w: int, d: int, hospital: bool) -> Array:
	var out: Array = []
	for v in d:
		for u in w:
			if u < CORRIDOR or u >= w - CORRIDOR or v >= d - CORRIDOR:
				out.append(Vector2i(u, v))
	for u in CORRIDOR:
		out.append(Vector2i(u, -1) if hospital else Vector2i(w - CORRIDOR + u, -1))
	return out


## Stub tiles past the seam in the hospital copy (never walked there: blocked for navigation).
static func phantom_hospital(w: int, t: Vector2i) -> bool:
	return t.y >= 0 and t.x >= ceili(seam_s(w))


## Stub tiles before the seam in the pocket copy.
static func phantom_pocket(w: int, t: Vector2i) -> bool:
	return t.y >= 0 and t.x < floori(seam_s(w))


## Ceiling fixtures: over the inner corner of each bend.
static func light_tiles(w: int, d: int) -> Array:
	return [Vector2i(CORRIDOR - 1, d - CORRIDOR), Vector2i(w - CORRIDOR, d - CORRIDOR)]


## Stub-local continuous tile coordinates -> world metres, for a frame (o, eu, ev) in some tile grid.
static func frame(o: Vector2i, eu: Vector2i, ev: Vector2i) -> Transform3D:
	var a := Vector2(o) + Vector2(maxi(0, -eu.x) + maxi(0, -ev.x), maxi(0, -eu.y) + maxi(0, -ev.y))
	var b := Basis(Vector3(eu.x, 0, eu.y), Vector3.UP, Vector3(ev.x, 0, ev.y))
	return Transform3D(b, Vector3(a.x * T, 0.0, a.y * T))


## A stub-local point (s, t in tiles, y metres) in the world through a frame.
static func local_point(xf: Transform3D, s: float, t: float, y := 0.0) -> Vector3:
	return xf * Vector3(s * T, y, t * T)


## World -> stub-local (s, t in tiles, y metres).
static func to_local(xf: Transform3D, p: Vector3) -> Vector3:
	var l := xf.affine_inverse() * p
	return Vector3(l.x / T, l.y, l.z / T)


static func det(eu: Vector2i, ev: Vector2i) -> int:
	return eu.x * ev.y - eu.y * ev.x


## The pocket copy's eu for an outward wall normal `ev`, matching the hospital frame's handedness.
static func pocket_eu(ev: Vector2i, handed: int) -> Vector2i:
	var a := Vector2i(-ev.y, ev.x)
	return a if det(a, ev) == handed else -a


## Walk-through waypoints along the corridor centre line, stub-local (s, t), mouth to opening.
static func centre_line(w: int, d: int) -> Array:
	var c := CORRIDOR * 0.5
	var back := float(d) - c
	return [Vector2(c, -1.6), Vector2(c, 0.5), Vector2(c, back), Vector2(seam_s(w), back),
			Vector2(float(w) - c, back), Vector2(float(w) - c, 0.5), Vector2(float(w) - c, -1.6)]


# ---------------------------------------------------------------------------
# The pocket copy: the stub's corridor surfaces exactly as HospitalBuilder draws a wing hallway
# (linoleum floor, suspended ceiling, the two-tone wall split at 1.05 m, world-metre UVs), in
# HOSPITAL world coordinates. The caller parents the result under the seam transform.
# ---------------------------------------------------------------------------

## `stub`: the plan entry. `seed`: the map seed (fixtures are seeded exactly as the hospital's).
## Returns {node: Node3D, lights: [{tile, position (hospital world), mode, node}], occluder: [verts, idx]}.
static func build_copy(stub: Dictionary, map_seed: int, hospital_lights: Array) -> Dictionary:
	var o: Vector2i = stub.o
	var eu: Vector2i = stub.eu
	var ev: Vector2i = stub.ev
	var w: int = stub.w
	var d: int = stub.d
	var open := {}
	for t in open_tiles(w, d, false):
		open[o + eu * t.x + ev * t.y] = true
	# The pocket side of the opening is open too (no wall face), but draws nothing here.
	var beyond := {}
	for u in CORRIDOR:
		beyond[o + eu * (w - CORRIDOR + u) - ev * 2] = true
	var root := Node3D.new()
	root.name = "StubCopy_%d" % int(stub.id)
	var sts := {}
	var faces := PackedVector3Array()
	var occ_v := PackedVector3Array()
	var occ_i := PackedInt32Array()
	var mats := {
		"linoleum": HB.surface_mat("mat/linoleum", Color(0.42, 0.44, 0.40), 0.8),
		"ceiling": HB.surface_mat("mat/ceiling", Color(0.30, 0.31, 0.31), 0.95),
		"wall": HB.surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85),
		"wall_low": HB.surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85, Color(0.62, 0.78, 0.70)),
	}
	var quad := func(mat: String, a: Vector3, b: Vector3, c: Vector3, dd: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		if not sts.has(mat):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[mat] = s
		var st: SurfaceTool = sts[mat]
		var n := (c - a).cross(b - a).normalized()
		for vv in [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [dd, ud]]:
			st.set_normal(n)
			st.set_uv(vv[1])
			st.add_vertex(vv[0])
	var solid := func(p: Vector2i) -> bool:
		return not open.has(p) and not beyond.has(p)
	var dirs: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	var bounds := Rect2()
	var first := true
	for p: Vector2i in open.keys():
		var x0 := p.x * T
		var z0 := p.y * T
		var x1 := x0 + T
		var z1 := z0 + T
		quad.call("linoleum", Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1),
				Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1))
		var y := C.WALL_H
		quad.call("ceiling", Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
				Vector2(x0, z0), Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0))
		var r := Rect2(x0, z0, T, T)
		bounds = r if first else bounds.merge(r)
		first = false
		# Faces of solid neighbours looking into this tile.
		for dir in dirs:
			var q: Vector2i = p + dir
			if not solid.call(q):
				continue
			# The face belongs to solid tile q and looks back toward p (normal -dir from q).
			var nrm := Vector3(-dir.x, 0.0, -dir.y)
			var centre := C.tile_to_world(q.x, q.y)
			_vface(quad, centre, nrm, 0.0, 1.05, "wall_low")
			_vface(quad, centre, nrm, 1.05, C.WALL_H, "wall")
			var rr := nrm.cross(Vector3.UP)
			var mid := centre + nrm * (T * 0.5)
			var k0 := mid - rr * (T * 0.5)
			var k1 := mid + rr * (T * 0.5)
			var up := Vector3(0.0, C.WALL_H, 0.0)
			faces.append_array([k0, k1, k1 + up, k0, k1 + up, k0 + up])
			var base := occ_v.size()
			occ_v.append_array([k0, k1, k1 + up, k0 + up])
			for i in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
				occ_i.append(base + i)
	var geo := Node3D.new()
	geo.name = "Geometry"
	root.add_child(geo)
	var keys := sts.keys()
	keys.sort()
	for k in keys:
		var st: SurfaceTool = sts[k]
		st.generate_tangents()
		var mi := MeshInstance3D.new()
		mi.name = String(k)
		mi.mesh = st.commit()
		mi.material_override = mats[k]
		mi.layers = 1 << COPY_LAYER_BIT
		geo.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)
	var cs := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	cs.shape = concave
	body.add_child(cs)
	for yy in [-0.2, C.WALL_H + 0.2]:
		var box := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(bounds.size.x, 0.4, bounds.size.y)
		box.shape = bs
		box.position = Vector3(bounds.get_center().x, yy, bounds.get_center().y)
		body.add_child(box)
	if not occ_v.is_empty():
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(occ_v, occ_i)
		var oi := OccluderInstance3D.new()
		oi.name = "Occluders"
		oi.occluder = occ
		root.add_child(oi)
	# Ceiling fixtures, seeded exactly as HospitalBuilder._build_lights seeds the hospital's, lighting
	# only the copy (a fixture casts no shadow: it would light the pocket through the stub's walls).
	var lights_root := Node3D.new()
	lights_root.name = "Lights"
	root.add_child(lights_root)
	var lights: Array = []
	var own := {}
	for tile: Vector2i in stub.lights:
		own[tile] = true
	# The stub block (walls included) in hospital world metres, to find the fixtures that reach it.
	var xf := frame(o, eu, ev)
	var c0: Vector3 = xf * Vector3(-T, 0.0, -T)
	var block := Rect2(Vector2(c0.x, c0.z), Vector2.ZERO)
	for v in [-1, d + 1]:
		for u in [-1, w + 1]:
			var p3: Vector3 = xf * Vector3(u * T, 0.0, v * T)
			block = block.expand(Vector2(p3.x, p3.z))
	for l in hospital_lights:
		var kind := String(l.get("kind", ""))
		if kind == "street" or kind == "canopy":
			continue
		var tile: Vector2i = l.tile
		var mode := int(l.mode)
		var light_seed := ((map_seed * 73856093) ^ (tile.x * 19349663) ^ (tile.y * 83492791)) & 0x7FFFFFFF
		if own.has(tile):
			var node := Legacy._make_light_fixture(mode, light_seed)
			node.name = "Fixture_%d_%d" % [tile.x, tile.y]
			node.position = C.tile_to_world(tile.x, tile.y)
			node.add_to_group("fixture")
			node.set_meta("mode", mode)
			node.set_meta("tile", tile)
			var bulb: OmniLight3D = node.get_node("Bulb")
			bulb.light_cull_mask = 0xFFFFF & ~(1 << POCKET_LAYER_BIT)
			if mode == 2:
				bulb.visible = false
			lights_root.add_child(node)
			lights.append({"tile": tile, "position": node.position, "mode": mode, "node": node})
			continue
		if mode == 2:
			continue
		# A hospital fixture near the stub: the same light (same seed, so the same flicker), for the
		# copy's surfaces only, no haze.
		var pos := C.tile_to_world(tile.x, tile.y) + Vector3(0.0, C.WALL_H - 0.35, 0.0)
		var bright := bool(l.get("bright", false))
		var rng := HB.LIGHT_RANGE * (1.35 if bright else 1.0)
		var q := Vector2(clampf(pos.x, block.position.x, block.end.x), clampf(pos.z, block.position.y, block.end.y))
		if q.distance_to(Vector2(pos.x, pos.z)) > rng + 0.1:
			continue
		var mirror := OmniLight3D.new()
		mirror.name = "Borrowed_%d_%d" % [tile.x, tile.y]
		mirror.position = pos
		mirror.omni_range = rng
		mirror.light_energy = HB.LIGHT_ENERGY * (1.7 if bright else 1.0)
		mirror.light_color = Color(0.96, 0.98, 1.0) if bright else Color(1.0, 0.96, 0.90)
		mirror.light_volumetric_fog_energy = 0.0
		mirror.shadow_enabled = false
		mirror.light_cull_mask = 0xFFFFF & ~(1 << POCKET_LAYER_BIT)
		mirror.add_to_group("fixture")
		mirror.set_meta("mode", mode)
		mirror.set_meta("seed", light_seed)
		lights_root.add_child(mirror)
	return {"node": root, "lights": lights}


## HospitalBuilder._vface: a face on the boundary of the tile centred at `centre`, facing `n`.
static func _vface(quad: Callable, centre: Vector3, n: Vector3, y0: float, y1: float, mat: String) -> void:
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
	quad.call(mat, v0, v1, v2, v3, Vector2(u0, C.WALL_H - y0), Vector2(u1, C.WALL_H - y0),
			Vector2(u1, C.WALL_H - y1), Vector2(u0, C.WALL_H - y1))
