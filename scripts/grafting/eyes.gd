class_name Eyes
extends RefCounted
## Grafting part one (docs/GRAFTING.md): the two eyes you can hold. `eye_hive` (taken from a strapped
## Hive) and `eye_surgeon` (a surgeon's own, labelled with whose it is). Both are sellable loot
## (loot_table.gd) that SPOIL outside a vat: over about a minute or two the eye clouds over and
## dulls, and a spoiled eye can't be grafted. A vat stops the clock (vats.gd).
##
## An eye's owner rides in the stack's/item's `x` string ("" for an Eyeball of Hive); the spoil clock is
## `bt` (world time it came out), exactly like a brain's.

const KINDS := ["eye_hive", "eye_surgeon"]

const FRESH_SECONDS := 40.0     # no change for this long
const ROTTEN_SECONDS := 130.0   # fully clouded by here
const MIN_FACTOR := 0.15        # what a fully rotten eye still fetches
const SPOILED_BELOW := 0.3      # a spoiled eye can't be grafted

const SHADER := """
shader_type spatial;
render_mode cull_back;

uniform vec3 iris : source_color = vec3(0.25, 0.42, 0.62);
uniform float glow = 0.0;
uniform vec3 sclera_col : source_color = vec3(0.93, 0.90, 0.88);
uniform vec3 pupil_col : source_color = vec3(0.02, 0.02, 0.02);
uniform float pupil_glow = 0.0;
uniform float pupil_r = 0.30;
uniform float ring_r = 0.62;
instance uniform float rot = 0.0;
varying vec3 obj;

void vertex() { obj = VERTEX; }

void fragment() {
	vec3 d = normalize(obj);
	float a = acos(clamp(-d.z, -1.0, 1.0));            // angle away from the front (-Z)
	float pupil = smoothstep(pupil_r, pupil_r - 0.04, a);
	float ring = smoothstep(ring_r, ring_r - 0.07, a);
	float vein = 0.5 + 0.5 * sin(d.x * 40.0 + d.y * 25.0) * sin(d.y * 31.0 - d.x * 12.0);
	vec3 sclera = mix(sclera_col, sclera_col * vec3(0.9, 0.6, 0.6), vein * 0.25);
	vec3 col = mix(sclera, iris * (0.75 + 0.35 * vein), ring);
	col = mix(col, pupil_col, pupil);
	// Spoiled: milky grey-yellow cloud spreads over everything and dulls it.
	float r = smoothstep(0.0, 1.0, rot);
	vec3 cloud = vec3(0.62, 0.62, 0.55);
	col = mix(col, cloud, r * (0.55 + 0.4 * ring + 0.4 * pupil));
	ALBEDO = col;
	ROUGHNESS = mix(0.12, 0.8, r);
	SPECULAR = mix(0.9, 0.2, r);
	EMISSION = iris * glow * (1.0 - r) * ring * (1.0 - pupil) + pupil_col * pupil_glow * pupil * (1.0 - r);
}
"""

static var _shader: Shader = null
static var _mats := {}


static func is_eye(kind: String) -> bool:
	return KINDS.has(kind)


## How much of its value an eye keeps after `age_seconds` out of a vat.
static func spoil_factor(age_seconds: float) -> float:
	if age_seconds <= FRESH_SECONDS:
		return 1.0
	var k := clampf((age_seconds - FRESH_SECONDS) / (ROTTEN_SECONDS - FRESH_SECONDS), 0.0, 1.0)
	return lerpf(1.0, MIN_FACTOR, k)


static func is_spoiled_factor(f: float) -> bool:
	return f < SPOILED_BELOW


## "fresh", "spoiling" or "spoiled".
static func condition(f: float) -> String:
	if f >= 0.999:
		return "fresh"
	return "spoiling" if f >= SPOILED_BELOW else "spoiled"


## Rot 0..1 for the model.
static func rot_of(f: float) -> float:
	return clampf(1.0 - (f - MIN_FACTOR) / (1.0 - MIN_FACTOR), 0.0, 1.0)


## "Eyeball of Hive" / "Zach's eye".
static func label(kind: String, owner: String) -> String:
	if kind == "eye_hive":
		return "Eyeball of Hive"
	var o := owner.strip_edges()
	return "%s's eye" % (o if o != "" else "A surgeon")


# ------------------------------------------------------------------ vat contents (a string)

## What a vat holds, as the string in a vat's `x`: "kind|owner|age|value" ("" = empty).
static func pack(kind: String, owner: String, age: float, value: int) -> String:
	return "%s|%s|%d|%d" % [kind, owner.replace("|", "/"), roundi(age), value]


static func unpack(x: String) -> Dictionary:
	if x == "":
		return {}
	var p := x.split("|")
	if p.size() < 4 or not is_eye(p[0]):
		return {}
	return {"kind": p[0], "owner": p[1], "age": float(p[2]), "value": int(p[3])}


# ------------------------------------------------------------------ the model

static func material(kind: String) -> ShaderMaterial:
	if _mats.has(kind):
		return _mats[kind]
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var m := ShaderMaterial.new()
	m.resource_name = kind
	m.shader = _shader
	if kind == "eye_hive":
		# The Hive's eye as the model has it (art/stylized/README.md): a dark ball, a lit orange-red iris and a bright
		# pinpoint in the middle. The body's eye, the minigames' copy of it, the item and the vat all read this.
		m.set_shader_parameter("iris", Color(1.0, 0.32, 0.05))
		m.set_shader_parameter("ring_r", 0.5)
		m.set_shader_parameter("sclera_col", Color(0.07, 0.02, 0.02))
		m.set_shader_parameter("pupil_col", Color(1.0, 0.85, 0.45))
		m.set_shader_parameter("pupil_glow", 1.6)
		m.set_shader_parameter("pupil_r", 0.16)
		m.set_shader_parameter("glow", 1.2)
	else:
		m.set_shader_parameter("iris", Color(0.25, 0.42, 0.62))
	_mats[kind] = m
	return m


const RADIUS := 0.017

## An eyeball with a stub of optic nerve behind it, sitting on the ground (origin at the base),
## looking up out of the table: the pupil faces -Z of the returned node.
static func build(root: Node3D, kind: String) -> void:
	var ball := MeshInstance3D.new()
	ball.name = "EyeBall"
	var sph := SphereMesh.new()
	sph.radius = RADIUS
	sph.height = RADIUS * 2.0
	sph.radial_segments = 20
	sph.rings = 10
	ball.mesh = sph
	ball.material_override = material(kind)
	ball.position = Vector3(0, RADIUS, 0)
	root.add_child(ball)
	var nerve := MeshInstance3D.new()
	nerve.name = "Nerve"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.004
	cyl.bottom_radius = 0.005
	cyl.height = 0.03
	cyl.radial_segments = 8
	cyl.rings = 1
	nerve.mesh = cyl
	var nm := StandardMaterial3D.new()
	nm.albedo_color = Color(0.85, 0.7, 0.62)
	nm.roughness = 0.5
	nerve.material_override = nm
	nerve.rotation_degrees = Vector3(90, 0, 0)
	nerve.position = Vector3(0, RADIUS, RADIUS + 0.012)
	root.add_child(nerve)
	# Rest with the pupil toward the viewer/the sky a little.
	ball.rotation_degrees = Vector3(-50, 0, 0)


## Set the rot of every eyeball under `node` (a world item, a hand's holder or a model).
static func set_rot(node: Node, r: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	for mi in node.find_children("EyeBall*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).set_instance_shader_parameter("rot", r)


static func footprint() -> Vector3:
	return Vector3(0.036, 0.036, 0.06)
