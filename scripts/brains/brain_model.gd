extends RefCounted
## The harvested brain as a world object (brains, sweep 3): two hemispheres pressed together along a
## fissure, each with a temporal lobe bulging low on its side and a narrower frontal end, the
## cerebellum tucked under the back and a stub of brain stem, merged into ONE mesh per kind (one
## draw, one gold rim overlay).
##
## The folds are the shader's: meandering grooves where a domain-warped noise field crosses its
## middle (gyri between them), shaded with a normal bent by the field's gradient (finite differences
## in the mesh's own space) and darkened and reddened in the grooves; the cerebellum gets fine
## parallel folia instead. Rot is a per-instance shader parameter, `set_rot(node, 0..1)`: the flesh
## goes grey-olive, the grooves brown-black, dark wet blotches spread and the shine dries. No material
## is duplicated for a rotting brain, and the geometry never changes (so the rim overlay fits).
##
## Origin at the base, front toward -Z, no collision. LootModels.build() calls build().

const KINDS := ["brain_walk_in", "brain_discharged"]

const SHADER := """
shader_type spatial;
render_mode cull_back;

uniform vec3 flesh : source_color = vec3(0.80, 0.6, 0.58);
uniform vec3 groove : source_color = vec3(0.36, 0.12, 0.13);
uniform float fold_scale = 95.0;
uniform float fold_depth = 1.0;
instance uniform float rot = 0.0;

varying vec3 obj;
varying vec3 obj_n;
varying vec4 part;

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

// 1 on top of a fold, 0 at the bottom of a groove. `warp` bends the grooves into meanders.
float folds(vec3 p, vec3 warp) {
	float n = vnoise(p * fold_scale + warp);
	float n2 = vnoise(p * fold_scale * 0.5 + warp * 0.5 + vec3(17.0));
	float d = min(abs(n - 0.5) * 1.0, abs(n2 - 0.5) * 1.6 + 0.08);
	return sqrt(smoothstep(0.0, 0.2, d));
}

// Cerebellum folia: fine parallel ridges wrapping around it.
float folia(vec3 p, vec3 warp) {
	float s = sin((p.y * 700.0 + p.z * 120.0) + warp.x * 1.5);
	return sqrt(smoothstep(-0.9, 0.2, s));
}

float height(vec3 p, vec3 warp, vec4 pr) {
	float f = pr.g > 0.5 ? folia(p, warp) : folds(p, warp);
	return mix(1.0, f, pr.r);
}

void vertex() {
	obj = VERTEX;
	obj_n = NORMAL;
	part = COLOR;
}

void fragment() {
	vec3 warp = vec3(vnoise(obj * 22.0), vnoise(obj * 22.0 + vec3(5.2, 1.3, 7.1)), vnoise(obj * 22.0 + vec3(2.8, 9.1, 3.3))) * 3.0;
	float h = height(obj, warp, part);
	float e = 0.0012;
	vec3 grad = vec3(height(obj + vec3(e, 0, 0), warp, part) - h, height(obj + vec3(0, e, 0), warp, part) - h, height(obj + vec3(0, 0, e), warp, part) - h) / e;
	vec3 n = normalize(obj_n);
	vec3 gt = grad - n * dot(grad, n);
	vec3 bent = normalize(n - gt * 0.0022 * fold_depth);
	NORMAL = normalize((VIEW_MATRIX * vec4(MODEL_NORMAL_MATRIX * bent, 0.0)).xyz);

	float r = smoothstep(0.0, 1.0, rot);
	// Fresh: pink-grey folds, dark red grooves, a faint blood blush in the deepest ones.
	vec3 fresh = mix(groove, flesh, smoothstep(0.0, 0.85, h));
	fresh *= 0.9 + 0.2 * vnoise(obj * 40.0);
	// Rotten: grey-olive folds, brown-black grooves, spreading dark blotches.
	vec3 dead = mix(vec3(0.09, 0.07, 0.04), vec3(0.42, 0.41, 0.3), smoothstep(0.0, 0.85, h));
	float blotch = smoothstep(0.62 - rot * 0.3, 0.72 - rot * 0.3, vnoise(obj * 30.0 + vec3(3.0)));
	dead = mix(dead, vec3(0.16, 0.17, 0.08), blotch * 0.8);
	ALBEDO = mix(fresh, dead, r);
	ROUGHNESS = mix(0.32, 0.85, r) + (1.0 - h) * 0.2;
	SPECULAR = mix(0.62, 0.2, r);
	BACKLIGHT = vec3(0.1, 0.02, 0.02) * (1.0 - r);
}
"""

static var _shader: Shader = null
static var _mats := {}
static var _meshes := {}


## Colours and size per kind: the Walk-In's brain is ordinary pink-grey; the Discharged's is bigger
## and paler, with a lilac-grey cast and deeper grooves.
static func _look(kind: String) -> Dictionary:
	if kind == "brain_discharged":
		return {"flesh": Color(0.74, 0.68, 0.72), "groove": Color(0.3, 0.17, 0.25), "depth": 1.3, "scale": 1.14}
	return {"flesh": Color(0.82, 0.61, 0.59), "groove": Color(0.4, 0.12, 0.13), "depth": 1.0, "scale": 1.0}


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
	m.set_shader_parameter("fold_depth", look.depth)
	_mats[kind] = m
	return m


## The merged mesh for a kind, built once.
static func mesh(kind: String) -> ArrayMesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var k: float = float(_look(kind).scale)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		_hemisphere(st, s, k)
	# Cerebellum: two lobes tucked under the back, fine folia.
	for s in [-1.0, 1.0]:
		_blob(st, Vector3(s * 0.024, 0.026, 0.054) * k, Vector3(0.028, 0.02, 0.024) * k, Color(0.35, 1.0, 0.0), 0.35, 28, 16)
	# Brain stem: a smooth stub going down under the middle.
	_blob(st, Vector3(0.0, 0.016, 0.028) * k, Vector3(0.011, 0.02, 0.013) * k, Color(0.0, 0.0, 0.0), 0.0, 14, 10)
	st.generate_normals()
	var m := st.commit()
	m.resource_name = "brain_mesh_" + kind
	_meshes[kind] = m
	return m


## One cerebral hemisphere (side -1 left, +1 right): an egg long along Z, flat on the inner face
## where it meets the other one, a temporal lobe bulging low on the outer side, the frontal end a
## little narrower and lower, the back fuller, the underside flattened.
static func _hemisphere(st: SurfaceTool, side: float, k: float) -> void:
	const RINGS := 26
	const SEGS := 40
	var half_w := 0.046 * k          # outward from the centre; the inner side is INNER times that
	const INNER := 0.42
	var half_h := 0.045 * k
	var half_l := 0.084 * k
	# The flat inner face sits 1.5 mm from the midline: a narrow fissure, not a gap.
	var centre := Vector3(side * (half_w * INNER + 0.0015 * k), 0.052 * k, 0.0)
	var pts: Array = []
	for r in RINGS + 1:
		var phi := PI * float(r) / RINGS
		var row: Array = []
		for sgi in SEGS + 1:
			var th := TAU * float(sgi) / SEGS
			var d := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var p := Vector3(d.x * half_w, d.y * half_h, d.z * half_l)
			# Inner face: flattened toward the fissure.
			if d.x * side < 0.0:
				p.x *= INNER
			# Front (-Z) narrower and lower, back fuller.
			var front := clampf(-d.z, 0.0, 1.0)
			p.y *= 1.0 - 0.16 * front * front
			p.x *= 1.0 - 0.12 * front * front
			# Temporal lobe: low on the outer side, the middle-front third.
			var outer := clampf(d.x * side, 0.0, 1.0)
			var low := clampf(-d.y + 0.2, 0.0, 1.0)
			var mid := exp(-pow((d.z + 0.1) / 0.45, 2.0))
			p.x += side * 0.012 * k * outer * low * mid
			p.y -= 0.01 * k * outer * low * mid
			# Flat underside, a notch between the temporal lobe and the frontal lobe.
			if p.y < -half_h * 0.55:
				p.y = lerpf(p.y, -half_h * 0.55, 0.7)
			var lump := 1.0 + 0.025 * sin(d.x * 9.0 + side) * sin(d.z * 7.0 + 1.3) * sin(d.y * 8.0 - side)
			row.append(centre + p * lump)
		pts.append(row)
	_quads(st, pts, RINGS, SEGS, Color(1.0, 0.0, 0.0))


static func _blob(st: SurfaceTool, centre: Vector3, radii: Vector3, col: Color, flat: float, segs: int, rings: int) -> void:
	var pts: Array = []
	for r in rings + 1:
		var phi := PI * float(r) / rings
		var row: Array = []
		for sgi in segs + 1:
			var th := TAU * float(sgi) / segs
			var d := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var p := Vector3(d.x * radii.x, d.y * radii.y, d.z * radii.z)
			if p.y < 0.0:
				p.y *= 1.0 - flat
			row.append(centre + p)
		pts.append(row)
	_quads(st, pts, rings, segs, col)


static func _quads(st: SurfaceTool, pts: Array, rings: int, segs: int, col: Color) -> void:
	for r in rings:
		for sgi in segs:
			var a: Vector3 = pts[r][sgi]
			var b: Vector3 = pts[r][sgi + 1]
			var c: Vector3 = pts[r + 1][sgi]
			var d: Vector3 = pts[r + 1][sgi + 1]
			for q in [a, c, b, b, c, d]:
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
	return Vector3(0.16, 0.1, 0.18) * k


## Show how far gone a brain is (0 fresh .. 1 rotten) on every brain mesh under `node`.
static func set_rot(node: Node, rot: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var list: Array = node.find_children("Brain", "MeshInstance3D", true, false)
	if node is MeshInstance3D and node.has_meta("brain"):
		list.append(node)
	for mi in list:
		if not (mi as MeshInstance3D).has_meta("brain"):
			continue
		if absf(float(mi.get_meta("rot_shown", -1.0)) - rot) > 0.004:
			(mi as MeshInstance3D).set_instance_shader_parameter("rot", rot)
			mi.set_meta("rot_shown", rot)
