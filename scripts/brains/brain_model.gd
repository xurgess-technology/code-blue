extends RefCounted
## The harvested brain as a world object (brains, sweep 3): two hemispheres with a fissure, the
## temporal lobes, the cerebellum and a stub of brain stem, merged into ONE mesh per kind (one draw,
## one gold rim overlay). The folds are drawn by the shader (a domain-warped noise ridge pattern in
## the mesh's own space, bump-mapped from screen-space derivatives, so it costs one noise stack per
## pixel), and the rot is a per-instance shader parameter: `set_rot(node, 0..1)` darkens the flesh
## toward grey-green, blotches it, dries the shine and lets it sag a little. No material is
## duplicated for a rotting brain.
##
## Origin at the base, front toward -Z, no collision. LootModels.build() calls build().

const KINDS := ["brain_walk_in", "brain_discharged"]

const SHADER := """
shader_type spatial;
render_mode cull_back;

uniform vec3 flesh : source_color = vec3(0.80, 0.58, 0.58);
uniform vec3 groove : source_color = vec3(0.45, 0.17, 0.19);
uniform vec3 vein : source_color = vec3(0.55, 0.08, 0.1);
uniform float fold_scale = 34.0;
uniform float bump = 0.0035;
instance uniform float rot = 0.0;

varying vec3 obj;
varying float fold_amt;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	obj = VERTEX;
	fold_amt = COLOR.r;
	// Rot: it shrinks and slumps onto whatever it lies on.
	VERTEX.xz *= 1.0 - rot * 0.06;
	VERTEX.y *= 1.0 - rot * 0.16;
}

void fragment() {
	float scale = fold_scale * mix(1.0, 1.9, COLOR.g);
	vec3 p = obj * scale;
	vec3 warp = vec3(vnoise(obj * 9.0), vnoise(obj * 9.0 + vec3(5.2, 1.3, 7.1)), vnoise(obj * 9.0 + vec3(2.8, 9.1, 3.3)));
	float n = vnoise(p + warp * 3.2);
	// Thin grooves (sulci) where the noise crosses the middle, wide rounded folds (gyri) between.
	float ridge = smoothstep(0.0, 0.17, abs(n - 0.5));
	float g = mix(1.0, ridge, fold_amt);
	float h = g * bump * fold_amt;
	// Bump from screen-space derivatives of the height (surface gradient method).
	vec3 sx = dFdx(VERTEX);
	vec3 sy = dFdy(VERTEX);
	vec3 nrm = normalize(NORMAL);
	vec3 r1 = cross(sy, nrm);
	vec3 r2 = cross(nrm, sx);
	float det = dot(sx, r1);
	vec3 sgrad = sign(det) * (dFdx(h) * r1 + dFdy(h) * r2);
	NORMAL = normalize(abs(det) * nrm - sgrad);

	float veins = smoothstep(0.035, 0.0, abs(vnoise(obj * 60.0 + warp * 6.0) - 0.5)) * 0.45 * (1.0 - rot);
	vec3 fresh = mix(groove, flesh, g);
	fresh = mix(fresh, vein, veins * g);
	// Rot: grey-green flesh, brown-black grooves, dark wet blotches that spread as it goes.
	vec3 dead_flesh = vec3(0.40, 0.42, 0.26);
	vec3 dead_groove = vec3(0.10, 0.08, 0.05);
	vec3 rotten = mix(dead_groove, dead_flesh, g);
	float blotch = smoothstep(0.66 - rot * 0.34, 0.74 - rot * 0.34, vnoise(obj * 14.0 + vec3(3.0)));
	rotten = mix(rotten, vec3(0.13, 0.16, 0.07), blotch * 0.85);
	float r = smoothstep(0.0, 1.0, rot);
	ALBEDO = mix(fresh, rotten, r);
	ROUGHNESS = mix(0.28, 0.8, r) + (1.0 - g) * 0.15;
	SPECULAR = mix(0.7, 0.25, r);
	// A little light gets into fresh flesh.
	SSS_STRENGTH = 0.0;
	BACKLIGHT = vec3(0.12, 0.03, 0.03) * (1.0 - r);
}
"""

static var _shader: Shader = null
static var _mats := {}
static var _meshes := {}


## Colours and size per kind: the Walk-In's brain is ordinary pink-grey; the Discharged's is bigger
## and paler, with a bluish cast and deeper grooves.
static func _look(kind: String) -> Dictionary:
	if kind == "brain_discharged":
		return {"flesh": Color(0.72, 0.66, 0.72), "groove": Color(0.33, 0.2, 0.3), "vein": Color(0.35, 0.12, 0.25), "scale": 1.14}
	return {"flesh": Color(0.82, 0.58, 0.57), "groove": Color(0.46, 0.17, 0.19), "vein": Color(0.58, 0.07, 0.1), "scale": 1.0}


static func material(kind: String) -> ShaderMaterial:
	if _mats.has(kind):
		return _mats[kind]
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var look := _look(kind)
	var m := ShaderMaterial.new()
	m.resource_name = "brain_" + kind
	m.shader = _shader
	m.set_shader_parameter("flesh", look.flesh)
	m.set_shader_parameter("groove", look.groove)
	m.set_shader_parameter("vein", look.vein)
	_mats[kind] = m
	return m


## The merged mesh for a kind, built once.
static func mesh(kind: String) -> ArrayMesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var k: float = float(_look(kind).scale)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Hemispheres: long along Z, a little flattened underneath, a gap between them (the fissure).
	for s in [-1.0, 1.0]:
		_ellipsoid(st, Vector3(s * 0.037, 0.05, 0.0) * k, Vector3(0.036, 0.047, 0.084) * k, 1.0, 0.0, 0.35, s * 3.0)
		# Temporal lobes, low on the sides and a little forward.
		_ellipsoid(st, Vector3(s * 0.047, 0.03, -0.012) * k, Vector3(0.027, 0.025, 0.05) * k, 1.0, 0.0, 0.2, s * 7.0)
	# Cerebellum: tucked under the back, finer folds.
	_ellipsoid(st, Vector3(0.0, 0.024, 0.066) * k, Vector3(0.05, 0.022, 0.03) * k, 1.0, 1.0, 0.0, 11.0)
	# Brain stem: a short smooth stub going down and back.
	_ellipsoid(st, Vector3(0.0, 0.016, 0.045) * k, Vector3(0.011, 0.02, 0.013) * k, 0.0, 0.0, 0.0, 13.0)
	st.generate_normals()
	var m := st.commit()
	m.resource_name = "brain_mesh_" + kind
	_meshes[kind] = m
	return m


## An ellipsoid with a gently lumpy surface. `fold` goes to COLOR.r (how much the shader folds it),
## `fine` to COLOR.g (smaller folds), `flat` squashes the underside toward the floor.
static func _ellipsoid(st: SurfaceTool, centre: Vector3, radii: Vector3, fold: float, fine: float, flat: float, seed: float) -> void:
	const RINGS := 14
	const SEGS := 22
	var pts: Array = []
	for r in RINGS + 1:
		var v := float(r) / RINGS
		var phi := PI * v
		var row: Array = []
		for sgi in SEGS + 1:
			var u := float(sgi) / SEGS
			var th := TAU * u
			var d := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var lump := 1.0 + 0.05 * sin(d.x * 7.0 + seed) * sin(d.z * 5.0 + seed * 1.7) * sin(d.y * 6.0 - seed)
			var p := Vector3(d.x * radii.x, d.y * radii.y, d.z * radii.z) * lump
			if p.y < 0.0:
				p.y *= 1.0 - flat
			row.append(centre + p)
		pts.append(row)
	var col := Color(fold, fine, 0.0)
	for r in RINGS:
		for sgi in SEGS:
			var a: Vector3 = pts[r][sgi]
			var b: Vector3 = pts[r][sgi + 1]
			var c: Vector3 = pts[r + 1][sgi]
			var d2: Vector3 = pts[r + 1][sgi + 1]
			for q in [a, c, b, b, c, d2]:
				st.set_color(col)
				st.add_vertex(q)


## Build the brain under `root` (LootModels.build).
static func build(root: Node3D, kind: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Brain"
	mi.mesh = mesh(kind)
	mi.material_override = material(kind)
	mi.set_meta("brain", true)
	root.add_child(mi)


static func footprint(kind: String) -> Vector3:
	var k: float = float(_look(kind).scale)
	return Vector3(0.15, 0.1, 0.18) * k


## Show how far gone a brain is (0 fresh .. 1 rotten) on every brain mesh under `node`.
static func set_rot(node: Node, rot: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var list: Array = []
	if node is MeshInstance3D and node.has_meta("brain"):
		list.append(node)
	for mi in node.find_children("Brain", "MeshInstance3D", true, false):
		list.append(mi)
	for mi in list:
		if (mi as MeshInstance3D).has_meta("brain"):
			var cur = mi.get_meta("rot_shown", -1.0)
			if absf(float(cur) - rot) > 0.004:
				(mi as MeshInstance3D).set_instance_shader_parameter("rot", rot)
				mi.set_meta("rot_shown", rot)
