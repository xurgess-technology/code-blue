extends RefCounted
## The head of a strapped monster, built so it can be opened: a lat-long ellipsoid split exactly
## along the craniotomy plane into the skull cap and the rest, the bone rims of both cut faces, the
## cavity and the brain. Also the brain mesh itself (the brain forceps step and fallbacks use it).
##
## Head-local frame (the PatientBody frame, moved to the head centre): +Y the face, -X the crown,
## +X the chin, Z ear to ear. The cut plane has the normal CUT_DIR (up and toward the crown, 45
## degrees) and cuts the ellipsoid where (p . CUT_DIR) = CUT_K * support(CUT_DIR): the forehead
## above the brows, the crown and the top of the back of the head come off as one bowl.

const CUT_DIR := Vector3(-0.70710678, 0.70710678, 0.0)
const CUT_K := 0.78
const SEGS := 30
const CAP_RINGS := 6
const REST_RINGS := 14
const BONE_T := 0.16          # rim width as a fraction of the opening radius

static var _mats := {}
static var _brain_meshes := {}


static func vmat(key: String, rough := 0.8, spec := 0.35, cull_off := false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = rough
	m.metallic_specular = spec
	if cull_off:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m


static func cmat(key: String, color: Color, rough := 0.8, cull_off := false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.albedo_color = color
	m.roughness = rough
	if cull_off:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m


static func _h(x: float, y: float, z: float) -> float:
	return fposmod(sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453, 1.0)


## Smooth 3D value noise, 0..1.
static func noise3(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector3(3, 3, 3) - 2.0 * f)
	var a := lerpf(_h(i.x, i.y, i.z), _h(i.x + 1, i.y, i.z), f.x)
	var b := lerpf(_h(i.x, i.y + 1, i.z), _h(i.x + 1, i.y + 1, i.z), f.x)
	var c := lerpf(_h(i.x, i.y, i.z + 1), _h(i.x + 1, i.y, i.z + 1), f.x)
	var d := lerpf(_h(i.x, i.y + 1, i.z + 1), _h(i.x + 1, i.y + 1, i.z + 1), f.x)
	return lerpf(lerpf(a, b, f.y), lerpf(c, d, f.y), f.z)


## Geometry of the cut for head radii `r`: {m, extent, d, cos0, centre, ring: PackedVector3Array,
## u (the in-plane direction up toward the face), half_u, half_z, top (the ring's point furthest along u)}.
static func cut_info(r: Vector3) -> Dictionary:
	var m := CUT_DIR
	var sm := Vector3(r.x * m.x, r.y * m.y, r.z * m.z)
	var extent := sm.length()
	var mp := sm / extent
	var cos0 := CUT_K
	var sin0 := sqrt(1.0 - cos0 * cos0)
	var e1 := Vector3(0, 0, 1)
	var e2 := mp.cross(e1).normalized()
	var ring := PackedVector3Array()
	for s in SEGS:
		var ph := TAU * float(s) / float(SEGS)
		var q := (e1 * cos(ph) + e2 * sin(ph)) * sin0 + mp * cos0
		ring.append(q * r)
	var centre := (mp * cos0) * r
	var u := (Vector3.UP - m * Vector3.UP.dot(m)).normalized()
	var top := ring[0]
	var best := -INF
	var half_z := 0.0
	for p in ring:
		var along := (p - centre).dot(u)
		if along > best:
			best = along
			top = p
		half_z = maxf(half_z, absf(p.z - centre.z))
	return {"m": m, "extent": extent, "d": extent * cos0, "cos0": cos0, "mp": mp, "e1": e1, "e2": e2,
		"centre": centre, "ring": ring, "u": u, "half_u": best, "half_z": half_z, "top": top}


## Builds the head under `parent` (a Node3D at the head centre). `look` = {skin: Color, hair: float,
## scalp: Color, brain_scale: float}. Returns {cap, rest, rim, cavity, brain, cap_rim, info}.
static func build(parent: Node3D, r: Vector3, look: Dictionary, seed_v: int) -> Dictionary:
	var info := cut_info(r)
	var skin: Color = look.get("skin", Color(0.6, 0.6, 0.55))
	var scalp: Color = look.get("scalp", skin.darkened(0.3))
	var hair := float(look.get("hair", 0.0))
	var eyeless := bool(look.get("eyeless", false))
	var colour_fn := func(q: Vector3) -> Color:
		var p := q * r
		var n := noise3(p * 55.0 + Vector3(seed_v % 97, 3, 5))
		var n2 := noise3(p * 180.0 + Vector3(11, seed_v % 31, 2))
		var c := skin * (0.9 + 0.16 * n) * (0.95 + 0.08 * n2)
		# Veins and bruising blotches.
		var blotch := smoothstep(0.62, 0.8, noise3(p * 22.0 + Vector3(7, 1, seed_v % 13)))
		c = c.lerp(Color(0.34, 0.3, 0.38), blotch * 0.35)
		# Hair: thin, patchy, over the crown and the back.
		var crown := smoothstep(-0.2, -0.75, q.x) * smoothstep(-0.2, 0.35, -q.y + 0.2)
		var patchy := smoothstep(0.35, 0.6, noise3(p * 70.0 + Vector3(2, 9, seed_v % 7)))
		c = c.lerp(scalp, clampf(crown * patchy * hair, 0.0, 1.0))
		# Eyeless: smooth dark hollows where the eyes were.
		if eyeless:
			for sz in [-1.0, 1.0]:
				var ep := Vector3(-0.006 * r.x / 0.112, r.y * 0.9, sz * r.z * 0.4)
				var dd := (p - ep).length()
				c = c.lerp(Color(0.2, 0.17, 0.2), (1.0 - smoothstep(0.008, 0.026, dd)) * 0.55)
		return c
	# The ellipsoid, as lat-long rings around the cut direction so the cut is exactly one ring.
	var sin0 := sqrt(1.0 - info.cos0 * info.cos0)
	var th0 := atan2(sin0, float(info.cos0))
	var cap_rings := PackedFloat32Array()
	for i in CAP_RINGS + 1:
		cap_rings.append(th0 * float(i) / float(CAP_RINGS))
	var rest_rings := PackedFloat32Array()
	for i in REST_RINGS + 1:
		rest_rings.append(lerpf(th0, PI, float(i) / float(REST_RINGS)))
	var mp: Vector3 = info.mp
	var e1: Vector3 = info.e1
	var e2: Vector3 = info.e2
	var centre: Vector3 = info.centre

	# The cap lives in its own node with the origin at the centre of the cut face, so it can be
	# lifted off and laid down by moving that node.
	var cap := Node3D.new()
	cap.name = "SkullCap"
	cap.position = centre
	parent.add_child(cap)
	var cap_mesh := _shell(cap_rings, r, mp, e1, e2, colour_fn, -centre)
	var cap_mi := _mi(cap, cap_mesh, vmat("mh_skin"), "Scalp")
	cap_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var ring_local := PackedVector3Array()
	for p in info.ring:
		ring_local.append(p - centre)
	# Underside of the cap: bone rim and the membrane inside, facing -m.
	var cap_rim := _annulus(ring_local, Vector3.ZERO, 1.0, 1.0 - BONE_T, -CUT_DIR * 0.0005, Color(0.86, 0.8, 0.66), true)
	_mi(cap, cap_rim, vmat("mh_bone", 0.7, 0.35, true), "CapRim")
	var cap_in := _annulus(ring_local, Vector3.ZERO, 1.0 - BONE_T, 0.0, CUT_DIR * 0.004, Color(0.55, 0.3, 0.3), true)
	_mi(cap, cap_in, vmat("mh_membrane", 0.4, 0.6, true), "CapInside")

	var rest_mesh := _shell(rest_rings, r, mp, e1, e2, colour_fn, Vector3.ZERO)
	var rest_mi := _mi(parent, rest_mesh, vmat("mh_skin"), "Head")
	rest_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# The open skull: a bone rim, then a dark wet cavity a little below the cut.
	var rim := Node3D.new()
	rim.name = "OpenSkull"
	parent.add_child(rim)
	var rim_mesh := _annulus(info.ring, centre, 1.0, 1.0 - BONE_T, CUT_DIR * 0.0005, Color(0.88, 0.82, 0.68), false)
	_mi(rim, rim_mesh, vmat("mh_bone", 0.7, 0.35, true), "BoneRim")
	var cavity_mesh := _bowl(info.ring, centre, 1.0 - BONE_T, 0.045)
	_mi(rim, cavity_mesh, vmat("mh_cavity", 0.25, 0.7, true), "Cavity")
	rim.visible = false

	# The brain sits in the cavity with its dome just under the cut.
	var brain := Node3D.new()
	brain.name = "Brain"
	parent.add_child(brain)
	var bs := float(look.get("brain_scale", 1.0))
	var bradii := brain_radii(info) * bs
	var u: Vector3 = info.u
	# Brain-local: X along u (front to back of the opening), Y out of the opening, Z ear to ear.
	brain.transform = Transform3D(Basis(u, CUT_DIR, u.cross(CUT_DIR)), centre - CUT_DIR * (bradii.y * 0.55 + 0.004))
	_mi(brain, brain_mesh(bradii, seed_v), vmat("mh_brain", 0.35, 0.55), "BrainMesh")
	brain.visible = false
	return {"cap": cap, "rest": rest_mi, "rim": rim, "brain": brain, "info": info, "brain_radii": bradii}


## How big a brain fits this opening (brain-local radii: along u, out of the opening, ear to ear).
static func brain_radii(info: Dictionary) -> Vector3:
	return Vector3(float(info.half_u) * 0.68, float(info.half_u) * 0.55, float(info.half_z) * 0.68)


static func _mi(parent: Node3D, mesh: Mesh, mat: Material, nm: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


## An ellipsoid band between the polar angles in `rings` (around pole `mp`), scaled by r, offset.
static func _shell(rings: PackedFloat32Array, r: Vector3, mp: Vector3, e1: Vector3, e2: Vector3, colour_fn: Callable, offset: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inv := Vector3(1.0 / r.x, 1.0 / r.y, 1.0 / r.z)
	for j in rings.size():
		var th := rings[j]
		for s in SEGS + 1:
			var ph := TAU * float(s) / float(SEGS)
			var q := (e1 * cos(ph) + e2 * sin(ph)) * sin(th) + mp * cos(th)
			if th < 1e-4:
				q = mp
			var p := q * r
			st.set_normal((q * inv).normalized())
			st.set_color(colour_fn.call(q))
			st.add_vertex(p + offset)
	for j in rings.size() - 1:
		for s in SEGS:
			var a := j * (SEGS + 1) + s
			var b := a + 1
			var c := a + SEGS + 1
			var d := c + 1
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	return st.commit()


## A flat ring in the cut plane between two fractions of the opening (1 = the ring itself).
## `down` flips the winding so it faces -CUT_DIR.
static func _annulus(ring: PackedVector3Array, centre: Vector3, outer: float, inner: float, lift: Vector3, col: Color, down: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := -CUT_DIR if down else CUT_DIR
	var count := ring.size()
	for s in count + 1:
		var p := ring[s % count] - centre
		for f in [outer, inner]:
			var k := 0.92 + 0.16 * _h(float(s), f, 1.0) if f > 0.0 and f < 1.0 else 1.0
			st.set_normal(n)
			st.set_color(col * (0.85 + 0.2 * _h(float(s), f, 3.0)))
			st.add_vertex(centre + p * float(f) * (k if inner > 0.0 else 1.0) + lift)
	for s in count:
		var a := s * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		if down:
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)
		else:
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	return st.commit()


## The inside of the open skull: a dark red bowl from the inner rim down `depth` along -CUT_DIR.
static func _bowl(ring: PackedVector3Array, centre: Vector3, frac: float, depth: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var levels := 5
	var count := ring.size()
	for l in levels + 1:
		var t := float(l) / float(levels)
		var shrink := frac * sqrt(maxf(0.0, 1.0 - t * t * 0.92))
		for s in count + 1:
			var p := (ring[s % count] - centre) * shrink
			var pos := centre + p - CUT_DIR * depth * t
			var wet := 0.8 + 0.3 * _h(float(s), float(l), 7.0)
			st.set_color(Color(0.3, 0.05, 0.06).lerp(Color(0.12, 0.01, 0.02), t) * wet)
			st.set_normal((CUT_DIR * 0.6 - p.normalized() * 0.4).normalized())
			st.add_vertex(pos)
	for l in levels:
		for s in count:
			var a := l * (count + 1) + s
			var b := a + 1
			var c := a + count + 1
			var d := c + 1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)
	return st.commit()


## A brain: an ellipsoid with folds (gyri) and the fissure between the hemispheres along X.
## Local frame: X front to back, Y up (the dome), Z ear to ear; flattened underneath. Cached.
static func brain_mesh(radii: Vector3, seed_v: int) -> ArrayMesh:
	var key := "%s|%d" % [str(radii.snapped(Vector3(0.001, 0.001, 0.001))), seed_v % 5]
	if _brain_meshes.has(key):
		return _brain_meshes[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 44
	var rings := 26
	var off := Vector3(float(seed_v % 5) * 1.7, 0.3, 0.9)
	for j in rings + 1:
		var v := float(j) / float(rings)
		var phi := PI * v
		for s in segs + 1:
			var th := TAU * float(s) / float(segs)
			var n := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			# Folds: ridged noise; deeper in the fissure between the hemispheres.
			var w := noise3(n * 4.2 + off) * 0.6 + noise3(n * 9.0 + off * 2.0) * 0.4
			var ridge := 1.0 - absf(sin(w * 18.0))
			var fis := 1.0 - smoothstep(0.02, 0.14, absf(n.z)) * 1.0
			fis *= smoothstep(-0.3, 0.2, n.y)
			var k := 1.0 - 0.055 * (1.0 - ridge) - 0.16 * fis
			var p := n * radii * k
			if p.y < -radii.y * 0.45:
				p.y = -radii.y * 0.45 + (p.y + radii.y * 0.45) * 0.25   # flattened base
			var groove := clampf((1.0 - ridge) * 1.2 + fis * 1.3, 0.0, 1.0)
			var col := Color(0.9, 0.7, 0.68).lerp(Color(0.5, 0.26, 0.3), groove)
			col = col.lerp(Color(0.55, 0.12, 0.14), 0.25 * smoothstep(0.55, 0.8, noise3(n * 3.0 + off * 3.0)))
			st.set_color(col)
			st.add_vertex(p)
	for j in rings:
		for s in segs:
			var a := j * (segs + 1) + s
			var b := a + 1
			var c := a + segs + 1
			var d := c + 1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)
	st.generate_normals()
	var mesh := st.commit()
	_brain_meshes[key] = mesh
	return mesh
