extends RefCounted
## Shared building blocks for the patient bodies: cached materials, small meshes,
## procedural textures and the overlay props (wound, tourniquet, gauze, stump).
## Everything is built once and shared; nothing here runs per frame.

static var _mats := {}
static var _meshes := {}
static var _texes := {}


# -- materials ----------------------------------------------------------------

static func mat(key: String, color: Color, rough := 0.8, metal := 0.0, emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	_mats[key] = m
	return m


static func flesh_mat() -> StandardMaterial3D:
	return mat("flesh", Color(0.52, 0.06, 0.07), 0.35, 0.0, Color(0.2, 0.0, 0.0), 0.1)


static func blood_mat() -> StandardMaterial3D:
	return mat("blood", Color(0.32, 0.01, 0.02), 0.15, 0.0, Color(0.15, 0.0, 0.0), 0.2)


static func gauze_mat() -> StandardMaterial3D:
	return mat("gauze", Color(0.93, 0.92, 0.86), 0.95)


static func strap_mat() -> StandardMaterial3D:
	var m := mat("strap", Color(0.08, 0.08, 0.085), 0.55)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func unshaded(key: String, color: Color, on_top := false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.no_depth_test = on_top
	m.render_priority = 10 if on_top else 0
	_mats[key] = m
	return m


# -- meshes -------------------------------------------------------------------

static func sphere(r: float, segs := 10, rings := 6) -> SphereMesh:
	var key := "s%.4f_%d_%d" % [r, segs, rings]
	if not _meshes.has(key):
		var m := SphereMesh.new()
		m.radius = r
		m.height = r * 2.0
		m.radial_segments = segs
		m.rings = rings
		_meshes[key] = m
	return _meshes[key]


static func box(size: Vector3) -> BoxMesh:
	var key := "b%s" % str(size)
	if not _meshes.has(key):
		var m := BoxMesh.new()
		m.size = size
		_meshes[key] = m
	return _meshes[key]


static func cyl(r_top: float, r_bottom: float, h: float, segs := 10, caps := true) -> CylinderMesh:
	var key := "c%.4f_%.4f_%.4f_%d_%s" % [r_top, r_bottom, h, segs, str(caps)]
	if not _meshes.has(key):
		var m := CylinderMesh.new()
		m.top_radius = r_top
		m.bottom_radius = r_bottom
		m.height = h
		m.radial_segments = segs
		m.rings = 1
		m.cap_top = caps
		m.cap_bottom = caps
		_meshes[key] = m
	return _meshes[key]


static func add_mesh(parent: Node3D, mesh: Mesh, material: Material, xf := Transform3D(), nm := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	if nm != "":
		mi.name = nm
	mi.mesh = mesh
	mi.material_override = material
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if mesh.get_aabb().size.length() < 0.06 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


## A transform that places a unit-axis mesh (Y up) with its Y along `dir`.
static func along(dir: Vector3, origin: Vector3, scale := Vector3.ONE) -> Transform3D:
	var y := dir.normalized()
	var ref := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x, y, z).scaled_local(scale), origin)


# -- procedural textures ------------------------------------------------------

static func _hash2(x: float, y: float) -> float:
	return fposmod(sin(x * 127.1 + y * 311.7) * 43758.5453, 1.0)


static func _vnoise(x: float, y: float) -> float:
	var ix := floorf(x)
	var iy := floorf(y)
	var fx := x - ix
	var fy := y - iy
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := _hash2(ix, iy)
	var b := _hash2(ix + 1.0, iy)
	var c := _hash2(ix, iy + 1.0)
	var d := _hash2(ix + 1.0, iy + 1.0)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


## Irregular blood splat, alpha in the shape.
static func blood_tex() -> Texture2D:
	if _texes.has("blood"):
		return _texes["blood"]
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var ang := atan2(v, u)
			var edge := 0.62 + 0.22 * _vnoise(cos(ang) * 2.2 + 3.0, sin(ang) * 2.2 + 3.0) + 0.1 * _vnoise(u * 7.0, v * 7.0)
			# a few satellite droplets
			var drop := 0.0
			for k in 5:
				var a := float(k) * 1.37 + 0.4
				var cx := cos(a) * 0.8
				var cy := sin(a) * 0.8
				var dr := 0.07 + 0.04 * fposmod(float(k) * 0.618, 1.0)
				drop = maxf(drop, 1.0 - smoothstep(dr * 0.6, dr, Vector2(u - cx, v - cy).length()))
			var a_main := 1.0 - smoothstep(edge - 0.06, edge, r)
			var alpha := clampf(maxf(a_main, drop), 0.0, 1.0)
			var shade := 0.75 + 0.25 * _vnoise(u * 5.0 + 9.0, v * 5.0)
			var dark := lerpf(1.0, 0.55, smoothstep(0.0, edge, r))
			img.set_pixel(x, y, Color(0.55 * shade * dark, 0.02, 0.03, alpha * 0.95))
	var t := ImageTexture.create_from_image(img)
	_texes["blood"] = t
	return t


## Bruise ring + torn dark centre, for the gunshot entry wound.
static func wound_tex() -> Texture2D:
	if _texes.has("wound"):
		return _texes["wound"]
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var nz := _vnoise(u * 4.0 + 1.0, v * 4.0 + 7.0)
			var bruise := (1.0 - smoothstep(0.45, 1.0, r + nz * 0.25))
			var red := 1.0 - smoothstep(0.18, 0.42, r + nz * 0.12)
			var core := 1.0 - smoothstep(0.08, 0.16, r)
			var col := Color(0.22, 0.08, 0.26).lerp(Color(0.55, 0.04, 0.05), red).lerp(Color(0.04, 0.0, 0.0), core)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, clampf(bruise + red, 0.0, 1.0)))
	var t := ImageTexture.create_from_image(img)
	_texes["wound"] = t
	return t


static func decal(parent: Node3D, tex: Texture2D, size: Vector3, xf := Transform3D()) -> Decal:
	var d := Decal.new()
	d.texture_albedo = tex
	d.size = size
	d.transform = xf
	d.upper_fade = 0.15
	d.lower_fade = 0.3
	d.normal_fade = 0.2
	d.cull_mask = 1
	parent.add_child(d)
	return d


# -- overlay props (all built at a site frame: +Y out of the skin, X along limb) --

## Entry wound. Returns {root, bullet, hole_full, hole_empty}.
static func make_wound(parent: Node3D, radius: float) -> Dictionary:
	var root := Node3D.new()
	root.name = "Wound"
	parent.add_child(root)
	decal(root, wound_tex(), Vector3(radius * 7.0, 0.12, radius * 6.0))
	var rim := TorusMesh.new()
	rim.inner_radius = radius * 0.7
	rim.outer_radius = radius * 1.25
	rim.rings = 10
	rim.ring_segments = 6
	add_mesh(root, rim, flesh_mat(), Transform3D(Basis().scaled(Vector3(1.0, 0.5, 0.85)), Vector3(0, 0.002, 0)), "Rim")
	add_mesh(root, sphere(radius * 0.85, 10, 5), mat("hole", Color(0.02, 0.0, 0.0), 0.9), Transform3D(Basis().scaled(Vector3(1.0, 0.25, 0.85)), Vector3(0, -0.001, 0)), "Hole")
	var bullet := add_mesh(root, sphere(radius * 0.42, 8, 5), mat("bullet", Color(0.55, 0.45, 0.25), 0.3, 0.9), Transform3D(Basis().scaled(Vector3(1.0, 0.6, 1.0)), Vector3(radius * 0.1, 0.003, 0)), "Bullet")
	var empty := add_mesh(root, sphere(radius * 0.8, 10, 5), blood_mat(), Transform3D(Basis().scaled(Vector3(1.0, 0.2, 0.8)), Vector3(0, 0.002, 0)), "Emptied")
	empty.visible = false
	return {"root": root, "bullet": bullet, "emptied": empty}


## Black strap round an elliptical limb section (half sizes up/side), with a red windlass on top.
## `depth` is how far below the site origin the limb axis runs.
static func make_tourniquet(parent: Node3D, half_up: float, half_side: float, depth: float, boxy := false) -> Node3D:
	var root := Node3D.new()
	root.name = "Tourniquet"
	parent.add_child(root)
	var band := Node3D.new()
	band.name = "Band"
	band.position = Vector3(0, -depth, 0)
	root.add_child(band)
	# Cylinder axis Y -> limb X; radii scaled to the ellipse.
	var b := Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1))
	var k := 1.34 if boxy else 1.14
	var segs := 8 if boxy else 14
	# An octagon with its flats on the axes hugs a box-section limb; an ellipse hugs a round one.
	var spin := Basis(Vector3.UP, PI / 8.0) if boxy else Basis()
	var xf := Transform3D(b.scaled_local(Vector3(half_up * k, 1.0, half_side * k)) * spin, Vector3.ZERO)
	add_mesh(band, cyl(1.0, 1.0, 0.045, segs, false), strap_mat(), xf, "Strap")
	var top := half_up * k * (cos(PI / 8.0) if boxy else 1.0) - depth
	add_mesh(root, box(Vector3(0.06, 0.02, 0.06)), mat("buckle", Color(0.12, 0.12, 0.13), 0.5, 0.4), Transform3D(Basis(), Vector3(0, top + 0.008, 0)), "Buckle")
	add_mesh(root, cyl(0.011, 0.011, 0.15, 8), mat("windlass", Color(0.85, 0.07, 0.05), 0.45), Transform3D(Basis(Vector3(1, 0, 0), PI * 0.5).rotated(Vector3.UP, 0.3), Vector3(0, top + 0.03, 0)), "Windlass")
	add_mesh(root, box(Vector3(0.035, 0.014, 0.04)), mat("windlass_clip", Color(0.6, 0.04, 0.04), 0.5), Transform3D(Basis(), Vector3(0.0, top + 0.012, 0.085)), "Clip")
	# White time label on the strap, so the black band reads against dark skin.
	add_mesh(root, box(Vector3(0.03, 0.004, 0.05)), mat("tq_label", Color(0.92, 0.92, 0.88), 0.8), Transform3D(Basis(), Vector3(0.0, top + 0.002, -0.07)), "Label")
	return root


## Bloody stump end facing +X, elliptical (half sizes up/side), centred `depth` below the site.
static func make_stump(parent: Node3D, half_up: float, half_side: float, depth: float, bone_r: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Stump"
	parent.add_child(root)
	# Cylinder / torus axis Y -> +X (the limb's distal direction).
	var face := Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1))
	var c := Vector3(0.012, -depth, 0)
	add_mesh(root, cyl(1.0, 1.0, 1.0, 14), flesh_mat(), Transform3D(face.scaled_local(Vector3(half_up * 1.02, 0.016, half_side * 1.02)), c), "Cap")
	add_mesh(root, sphere(1.0, 12, 6), mat("flesh_dark", Color(0.2, 0.0, 0.01), 0.3), Transform3D(face.scaled_local(Vector3(half_up * 0.8, 0.02, half_side * 0.8)), c + Vector3(0.004, 0, 0)), "Meat")
	var rim := TorusMesh.new()
	rim.inner_radius = 0.9
	rim.outer_radius = 1.08
	rim.rings = 14
	rim.ring_segments = 5
	add_mesh(root, rim, blood_mat(), Transform3D(face.scaled_local(Vector3(half_up, 0.03, half_side)), c + Vector3(0.004, 0, 0)), "Rim")
	var bone := Vector3(0.018, bone_r * 0.3, -bone_r * 0.4)
	add_mesh(root, cyl(bone_r, bone_r * 1.1, 0.03, 8), mat("bone", Color(0.92, 0.88, 0.76), 0.6), Transform3D(face, c + bone - Vector3(0.008, 0, 0)), "Bone")
	add_mesh(root, cyl(bone_r * 0.5, bone_r * 0.5, 0.002, 6), mat("marrow", Color(0.45, 0.1, 0.08), 0.5), Transform3D(face, c + bone + Vector3(0.008, 0, 0)), "Marrow")
	return root


## A lumpy gauze wrap round a limb stump end.
static func make_stump_dressing(parent: Node3D, half_up: float, half_side: float, depth: float) -> Node3D:
	var root := Node3D.new()
	root.name = "StumpDressing"
	parent.add_child(root)
	var face := Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1))
	add_mesh(root, sphere(1.0, 12, 7), gauze_mat(), Transform3D(face.scaled_local(Vector3(half_up * 1.12, half_up * 1.1, half_side * 1.12)), Vector3(0.01, -depth, 0)), "Ball")
	for i in 3:
		var x := -0.05 * float(i) + 0.0
		add_mesh(root, cyl(1.0, 1.0, 0.035, 12, false), gauze_mat(), Transform3D(face.scaled_local(Vector3(half_up * 1.13, 1.0, half_side * 1.13)).rotated(Vector3.FORWARD, 0.12 * float(i - 1)), Vector3(x, -depth, 0)), "Wrap%d" % i)
	add_mesh(root, sphere(half_up * 0.4, 8, 4), blood_mat(), Transform3D(Basis().scaled(Vector3(0.9, 0.25, 1.0)), Vector3(half_up * 0.55, half_up * 0.95 - depth + 0.0, half_side * 0.2)), "Seep")
	return root


## Packed gauze pad on a wound (site frame), plus two tape strips.
static func make_pad(parent: Node3D, size: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Pad"
	parent.add_child(root)
	add_mesh(root, sphere(1.0, 10, 5), gauze_mat(), Transform3D(Basis().scaled(Vector3(size * 0.6, size * 0.18, size * 0.5)), Vector3(0, 0.004, 0)), "Gauze")
	add_mesh(root, sphere(size * 0.2, 8, 4), blood_mat(), Transform3D(Basis().scaled(Vector3(1.0, 0.3, 0.8)), Vector3(size * 0.05, size * 0.17, -size * 0.03)), "Seep")
	var tape := mat("tape", Color(0.86, 0.82, 0.7), 0.9)
	add_mesh(root, box(Vector3(size * 1.5, 0.006, size * 0.16)), tape, Transform3D(Basis(Vector3.UP, 0.5), Vector3(0, size * 0.14, 0)), "TapeA")
	add_mesh(root, box(Vector3(size * 1.5, 0.006, size * 0.16)), tape, Transform3D(Basis(Vector3.UP, -0.5), Vector3(0, size * 0.14, 0)), "TapeB")
	return root


## Tiny debug gizmo: red X, green Y, blue Z, drawn on top.
static func make_axes(parent: Node3D, length := 0.12, label := "") -> Node3D:
	var root := Node3D.new()
	root.name = "Axes"
	parent.add_child(root)
	var t := 0.006
	add_mesh(root, box(Vector3(length, t, t)), unshaded("ax_x", Color(1, 0.1, 0.1), true), Transform3D(Basis(), Vector3(length * 0.5, 0, 0)))
	add_mesh(root, box(Vector3(t, length, t)), unshaded("ax_y", Color(0.1, 1, 0.1), true), Transform3D(Basis(), Vector3(0, length * 0.5, 0)))
	add_mesh(root, box(Vector3(t, t, length)), unshaded("ax_z", Color(0.2, 0.4, 1), true), Transform3D(Basis(), Vector3(0, 0, length * 0.5)))
	add_mesh(root, box(Vector3(t * 2.5, t * 2.5, t * 2.5)), unshaded("ax_o", Color(1, 1, 1), true))
	if label != "":
		var l := Label3D.new()
		l.text = label
		l.font_size = 28
		l.pixel_size = 0.0012
		l.no_depth_test = true
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.outline_size = 8
		l.position = Vector3(0, length + 0.03, 0)
		root.add_child(l)
	return root


# -- loft mesh ----------------------------------------------------------------

## A tube along +X through elliptical rings. Each ring: [x, half_width(z), half_height(y), centre_y, bottom_flatten].
## `color_fn(p: Vector3, up_ness: float) -> Color` gives vertex colours. Ends closed with fans.
static func loft(rings: Array, segs: int, color_fn: Callable, close_start := true, close_end := true) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var verts := PackedVector3Array()
	for r in rings:
		for s in segs:
			var th := TAU * float(s) / float(segs)
			var cz := cos(th)
			var sy := sin(th)
			var y: float
			if sy >= 0.0:
				y = r[2] * sy
			else:
				y = -r[2] * float(r[4]) * pow(-sy, 0.55)
			var z: float = r[1] * cz * (1.0 if sy >= 0.0 else (1.0 + 0.06 * (-sy)))
			verts.append(Vector3(r[0], r[3] + y, z))
	var nr := rings.size()
	for i in verts.size():
		var ring: int = i / segs
		var s: int = i % segs
		var up := sin(TAU * float(s) / float(segs))
		st.set_color(color_fn.call(verts[i], up))
		st.add_vertex(verts[i])
	# end centres
	var start_idx := verts.size()
	var r0: Array = rings[0]
	var rn: Array = rings[nr - 1]
	var c0 := Vector3(r0[0] - 0.01, r0[3], 0)
	var cn := Vector3(rn[0] + 0.01, rn[3], 0)
	st.set_color(color_fn.call(c0, 0.0))
	st.add_vertex(c0)
	st.set_color(color_fn.call(cn, 0.0))
	st.add_vertex(cn)
	for i in nr - 1:
		for s in segs:
			var a := i * segs + s
			var b := i * segs + (s + 1) % segs
			var c := (i + 1) * segs + s
			var d := (i + 1) * segs + (s + 1) % segs
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	for s in segs:
		var a := s
		var b := (s + 1) % segs
		if close_start:
			st.add_index(start_idx); st.add_index(b); st.add_index(a)
		var e := (nr - 1) * segs
		if close_end:
			st.add_index(start_idx + 1); st.add_index(e + s); st.add_index(e + (s + 1) % segs)
	st.generate_normals()
	return st.commit()


## An ellipsoid with vertex colours from `color_fn(local_p, up_ness)`.
static func ellipsoid(radii: Vector3, segs: int, rings: int, color_fn: Callable) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in rings + 1:
		var v := float(j) / float(rings)
		var phi := PI * v
		for s in segs + 1:
			var th := TAU * float(s) / float(segs)
			var n := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var p := n * radii
			st.set_normal((n / radii).normalized())
			st.set_color(color_fn.call(p, n.y))
			st.add_vertex(p)
	for j in rings:
		for s in segs:
			var a := j * (segs + 1) + s
			var b := a + 1
			var c := a + segs + 1
			var d := c + 1
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(d)
	return st.commit()
