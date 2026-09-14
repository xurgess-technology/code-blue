extends RefCounted
## Procedural geometry and materials for the monsters: lathed cloth and bodies,
## ellipsoids, and one mottled-skin / stained-cloth shader shared by everything.
## All sizes are metres; every mesh is built around its node origin.

const SHADER_CODE := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform vec3 base_col : source_color = vec3(0.7);
uniform vec3 stain_col : source_color = vec3(0.3, 0.25, 0.15);
uniform vec3 stain2_col : source_color = vec3(0.25, 0.05, 0.04);
uniform float stain_amt = 0.0;
uniform float stain2_amt = 0.0;
uniform float stain_scale = 6.0;
uniform float stain_low = 0.0;
uniform float mottle = 0.15;
uniform float rough = 0.85;
uniform float edge_dark = 0.35;
uniform float vein = 0.0;
uniform float weave = 0.0;
uniform float sss = 0.0;
uniform float seed = 0.0;

varying vec3 opos;

void vertex() {
	opos = VERTEX;
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3) + seed * 0.013);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * noise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		a *= 0.5;
	}
	return s;
}

void fragment() {
	vec3 p = opos * stain_scale;
	vec3 c = base_col * (1.0 - mottle + mottle * 2.0 * fbm(p * 2.7));
	if (weave > 0.0) {
		float w = sin(opos.x * 900.0) * sin(opos.y * 900.0 + opos.z * 900.0);
		c *= 1.0 - weave * 0.5 * (w * 0.5 + 0.5);
	}
	if (vein > 0.0) {
		float v = abs(fbm(p * 1.3 + vec3(4.0)) - 0.5);
		c = mix(c, vec3(0.32, 0.36, 0.42) * base_col * 1.2, (1.0 - smoothstep(0.0, 0.035, v)) * vein);
	}
	float low = clamp(-opos.y * stain_low, -1.0, 1.0);
	float n = fbm(p + vec3(seed));
	float s = smoothstep(0.62 - stain_amt * 0.35, 0.72 - stain_amt * 0.35, n + low * 0.25);
	c = mix(c, stain_col * (0.8 + 0.4 * fbm(p * 5.0)), s * 0.9);
	float n2 = fbm(p * 1.7 + vec3(13.0, 2.0, seed));
	float s2 = smoothstep(0.70 - stain2_amt * 0.3, 0.76 - stain2_amt * 0.3, n2 + low * 0.3);
	c = mix(c, stain2_col, s2 * 0.95);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = c * (1.0 - fres * edge_dark);
	ROUGHNESS = rough;
	SPECULAR = 0.35;
	if (sss > 0.0) {
		BACKLIGHT = base_col * sss;
	}
}
"""

static var _shader: Shader = null
static var _shader_double: Shader = null


static func shader(double_sided := false) -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
		_shader_double = Shader.new()
		_shader_double.code = SHADER_CODE.replace("cull_back", "cull_disabled")
	return _shader_double if double_sided else _shader


## A material from the shared shader. `opts` keys match the uniforms above.
static func mat(base: Color, opts: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(opts.get("double", false))
	m.set_shader_parameter("base_col", base)
	for k in opts:
		if k == "double":
			continue
		m.set_shader_parameter(k, opts[k])
	return m


static func flat(col: Color, rough := 0.6, emissive := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emissive
	return m


## A lathed body: `rings` is an Array of [y, rx, rz] (optionally [y, rx, rz, z_offset]),
## bottom ring first. `arc` leaves the back open by that many radians (0 closes it).
## `ragged` lifts points of the bottom ring (a torn hem), `wobble` the radius of every vertex, deterministically from `seed`.
static func lathe(rings: Array, segs := 18, arc := 0.0, ragged := 0.0, wobble := 0.0, seed := 1,
		cap_top := false, cap_bottom := false) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(0)
	var cols := segs + 1
	var start := PI + arc * 0.5   # angle 0 points at +Z (front); PI is the back
	var span := TAU - arc
	var verts: Array = []
	for ri in rings.size():
		var r: Array = rings[ri]
		var row: Array = []
		for si in cols:
			var a := start + span * float(si) / float(segs)
			var j := _h(seed, ri, si)
			var w := 1.0 + wobble * (j - 0.5) * 2.0
			var y: float = r[0]
			if ri == 0 and ragged > 0.0:
				y += ragged * _h(seed + 7, si / 2, 3)
			var zo: float = r[3] if r.size() > 3 else 0.0
			row.append(Vector3(sin(a) * r[1] * w, y, cos(a) * r[2] * w + zo))
		verts.append(row)
	for ri in rings.size() - 1:
		for si in segs:
			var a: Vector3 = verts[ri][si]
			var b: Vector3 = verts[ri][si + 1]
			var c: Vector3 = verts[ri + 1][si + 1]
			var d: Vector3 = verts[ri + 1][si]
			var v0 := float(ri) / float(rings.size() - 1)
			var v1 := float(ri + 1) / float(rings.size() - 1)
			var u0 := float(si) / segs
			var u1 := float(si + 1) / segs
			_tri(st, a, b, c, Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1))
			_tri(st, a, c, d, Vector2(u0, v0), Vector2(u1, v1), Vector2(u0, v1))
	if cap_bottom:
		_cap(st, verts[0], rings[0], segs, true)
	if cap_top:
		_cap(st, verts[rings.size() - 1], rings[rings.size() - 1], segs, false)
	st.generate_normals()
	return st.commit()


static func _cap(st: SurfaceTool, row: Array, r: Array, segs: int, bottom: bool) -> void:
	var zo: float = r[3] if r.size() > 3 else 0.0
	var c := Vector3(0, r[0], zo)
	for si in segs:
		var a: Vector3 = row[si]
		var b: Vector3 = row[si + 1]
		if bottom:
			_tri(st, c, b, a, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		else:
			_tri(st, c, a, b, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)


## Winding chosen so the outside of a lathe faces out with Godot's clockwise front faces.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_uv(ub)
	st.add_vertex(b)


static func _h(s: int, a: int, b: int) -> float:
	var h := (s * 374761393 + a * 668265263 + b * 2246822519) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h & 0xFFFF) / 65535.0


static func mesh_node(mesh: Mesh, material: Material, pos := Vector3.ZERO, name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	if name != "":
		mi.name = name
	return mi


static func ellipsoid(r: Vector3, material: Material, pos := Vector3.ZERO, segs := 16) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = segs
	sm.rings = maxi(6, segs / 2)
	var mi := mesh_node(sm, material, pos)
	mi.scale = r
	return mi


static func box(size: Vector3, material: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return mesh_node(bm, material, pos)


static func cylinder(radius: float, height: float, material: Material, pos := Vector3.ZERO, top := -1.0, segs := 10) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius if top < 0.0 else top
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = segs
	cm.rings = 1
	return mesh_node(cm, material, pos)


## Merge every MeshInstance3D under `root` into one MeshInstance3D child with one surface per
## material, so a hand-built part costs a draw call per material instead of one per primitive.
## Subtrees under a node with meta "no_bake" (moving pieces such as ears) are left alone.
## Materials are keyed by instance, so parts must share material objects to share a surface.
## The shared shader's noise reads object-space positions: baked primitives get their stain and
## mottle pattern in the part's metres instead of their own unit space (finer on small bits).
static var _baked := {}

static func bake(root: Node3D, key := "") -> Node3D:
	var found: Array = []
	_collect(root, Transform3D.IDENTITY, found)
	if found.size() < 2:
		return root
	# Every monster of a kind is built identically: bake each part once per session.
	if key != "" and _baked.has(key):
		for e in found:
			if (e.node as MeshInstance3D).material_override != null:
				(e.node as MeshInstance3D).mesh = null
		_prune(root)
		var cached := MeshInstance3D.new()
		cached.name = "Baked"
		cached.mesh = _baked[key]
		root.add_child(cached)
		return root
	# Positions, normals and indices only (the shared shader needs nothing else); formats of
	# lathed ArrayMeshes and primitive meshes differ, so the arrays are merged by hand.
	var groups := {}     # material -> [verts, normals, indices]
	var order: Array = []
	var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for e in found:
		var mi: MeshInstance3D = e.node
		var mat: Material = mi.material_override
		if mat == null or mi.mesh == null:
			continue
		if not groups.has(mat):
			groups[mat] = [PackedVector3Array(), PackedVector3Array(), PackedInt32Array()]
			order.append(mat)
		var g: Array = groups[mat]
		var xf: Transform3D = e.xform
		var nb := xf.basis.inverse().transposed()
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var idx = arr[Mesh.ARRAY_INDEX]
			var base: int = (g[0] as PackedVector3Array).size()
			var gv: PackedVector3Array = g[0]
			var gn: PackedVector3Array = g[1]
			var gi: PackedInt32Array = g[2]
			for i in v.size():
				gv.append(xf * v[i])
				gn.append((nb * n[i]).normalized() if i < n.size() else Vector3.UP)
			if idx != null and (idx as PackedInt32Array).size() > 0:
				for k in idx:
					gi.append(base + k)
			else:
				for i in v.size():
					gi.append(base + i)
			g[0] = gv
			g[1] = gn
			g[2] = gi
	var mesh := ArrayMesh.new()
	for mat in order:
		var g: Array = groups[mat]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g[0]
		arrays[Mesh.ARRAY_NORMAL] = g[1]
		arrays[Mesh.ARRAY_INDEX] = g[2]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	if key != "":
		_baked[key] = mesh
	for e in found:
		var n: MeshInstance3D = e.node
		if n.material_override != null:
			n.mesh = null
	_prune(root)
	var baked := MeshInstance3D.new()
	baked.name = "Baked"
	baked.mesh = mesh
	baked.cast_shadow = shadow
	root.add_child(baked)
	return root


static func _collect(n: Node, xf: Transform3D, out: Array) -> void:
	for c in n.get_children():
		if c.has_meta("no_bake"):
			continue
		if c is Node3D:
			var cx: Transform3D = xf * (c as Node3D).transform
			if c is MeshInstance3D and (c as MeshInstance3D).visible:
				out.append({"node": c, "xform": cx})
			_collect(c, cx, out)


## Drop plain Node3Ds left with no children after baking.
static func _prune(n: Node) -> void:
	for c in n.get_children():
		if c.has_meta("no_bake"):
			continue
		_prune(c)
		var empty_mesh: bool = c is MeshInstance3D and (c as MeshInstance3D).mesh == null
		if (c.get_class() == "Node3D" or empty_mesh) and c.get_child_count() == 0 and c.get_script() == null:
			n.remove_child(c)
			c.free()


## Point a unit-height cylinder node from a to b (world or local, whatever its parent uses).
static func stretch_between(node: Node3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var l := d.length()
	if l < 0.0001:
		node.visible = false
		return
	node.visible = true
	var y := d / l
	var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y).normalized()
	node.transform = Transform3D(Basis(x, y * l, z), (a + b) * 0.5)
