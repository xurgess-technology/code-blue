extends Node3D
## The break-room blender (brains, sweep 3). Interactable `blender`: holding a brain, hold E to blend
## it and drink it (the brains system simulates the hold on the host and decides everything; this
## node only draws). While someone blends, the jar shakes and fills with a pink swirl on every
## machine; afterwards it drains.
##
## Two builds: `create(false)` sits on a counter top (origin on the counter, front toward +Z);
## `create(true)` stands on a small steel stand with a collider (origin on the floor) for levels
## without a counter.

const SWIRL_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform float level = 0.0;
uniform float spin = 0.0;
uniform float swirl_t = 0.0;
varying vec3 obj;
void vertex() { obj = VERTEX; }
void fragment() {
	// obj.y runs -0.5..0.5 on the unit cylinder: cut everything above the fill level.
	if (obj.y + 0.5 > level) { discard; }
	float a = atan(obj.z, obj.x);
	float bands = sin(a * 3.0 + obj.y * 18.0 - swirl_t * 9.0) * 0.5 + 0.5;
	vec3 pink = vec3(0.62, 0.3, 0.32);
	vec3 dark = vec3(0.3, 0.05, 0.06);
	float chunks = step(0.8, fract(sin(dot(floor(vec2(a * 6.0, obj.y * 30.0 - swirl_t * 3.0)), vec2(12.9, 78.2))) * 43758.5));
	ALBEDO = mix(mix(dark, pink, bands * 0.8 + 0.1), vec3(0.55, 0.45, 0.42), chunks * 0.5 * (1.0 - spin * 0.6));
	ROUGHNESS = 0.25;
	SPECULAR = 0.6;
}
"""

const JAR_H := 0.2
const JAR_R := 0.058

var on_stand := false
## 0..1: how far the current blend is (from the brains system), and how full the jar looks.
var progress := 0.0
var _fill := 0.0
var _drain := 0.0
var _t := 0.0
var _jar: Node3D
var _swirl_mat: ShaderMaterial
var _lamp_mat: StandardMaterial3D
var _whirr: Node = null
var _whirr_stream = null

static var _mats := {}
static var _swirl_shader: Shader = null


static func create(stand: bool) -> Node3D:
	var n: Node3D = (load("res://scripts/brains/blender.gd") as GDScript).new()
	n.name = "Blender"
	n.on_stand = stand
	n._build()
	return n


func _build() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "blender")
	var top := 0.0
	if on_stand:
		top = 0.86
		var stand := StaticBody3D.new()
		stand.name = "Stand"
		stand.collision_layer = C.L_WORLD
		stand.collision_mask = 0
		add_child(stand)
		var steel := _mat("stand_steel", Color(0.42, 0.44, 0.46), 0.4, 0.6)
		stand.add_child(_box(Vector3(0.46, 0.04, 0.4), Vector3(0, top - 0.02, 0), steel))
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				stand.add_child(_box(Vector3(0.035, top - 0.04, 0.035), Vector3(0.2 * sx, (top - 0.04) * 0.5, 0.17 * sz), steel))
		stand.add_child(_box(Vector3(0.42, 0.02, 0.36), Vector3(0, 0.22, 0), steel))
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.46, top, 0.4)
		cs.shape = bs
		cs.position = Vector3(0, top * 0.5, 0)
		stand.add_child(cs)
	var body := _mat("body", Color(0.13, 0.13, 0.14), 0.45, 0.1)
	var chrome := _mat("chrome", Color(0.78, 0.8, 0.82), 0.2, 0.9)
	# Motor base: a squat block with a sloped front, a dial and a red "on" lamp.
	add_child(_box(Vector3(0.16, 0.09, 0.15), Vector3(0, top + 0.045, 0), body))
	add_child(_box(Vector3(0.14, 0.012, 0.13), Vector3(0, top + 0.096, 0), chrome))
	var dial := _cyl(0.018, 0.012, _mat("dial", Color(0.7, 0.7, 0.72), 0.3, 0.7), 12)
	dial.position = Vector3(-0.03, top + 0.045, 0.078)
	dial.rotation.x = PI * 0.5
	add_child(dial)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(0.25, 0.03, 0.03)
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(1.0, 0.15, 0.1)
	_lamp_mat.emission_energy_multiplier = 0.0
	add_child(_box(Vector3(0.016, 0.01, 0.006), Vector3(0.035, top + 0.05, 0.077), _lamp_mat))
	# The jar: glass, a steel collar with the blades, a black lid; the swirl fills it while blending.
	_jar = Node3D.new()
	_jar.name = "Jar"
	_jar.position = Vector3(0, top + 0.1, 0)
	add_child(_jar)
	_jar.add_child(_cyl(0.045, 0.03, chrome, 16, 0.05, Vector3(0, 0.015, 0)))
	for i in 3:
		var blade := _box(Vector3(0.07, 0.003, 0.012), Vector3(0, 0.036, 0), chrome)
		blade.rotation.y = i * PI / 3.0
		_jar.add_child(blade)
	_swirl_mat = ShaderMaterial.new()
	if _swirl_shader == null:
		_swirl_shader = Shader.new()
		_swirl_shader.code = SWIRL_SHADER
	_swirl_mat.shader = _swirl_shader
	var swirl := MeshInstance3D.new()
	swirl.name = "Swirl"
	var sm := CylinderMesh.new()
	sm.top_radius = 1.0
	sm.bottom_radius = 1.0
	sm.height = 1.0
	sm.radial_segments = 18
	sm.rings = 1
	swirl.mesh = sm
	swirl.material_override = _swirl_mat
	swirl.scale = Vector3(JAR_R - 0.006, JAR_H - 0.02, JAR_R - 0.006)
	swirl.position = Vector3(0, 0.03 + (JAR_H - 0.02) * 0.5, 0)
	_jar.add_child(swirl)
	var glass := _mat("glass", Color(0.75, 0.85, 0.88), 0.05, 0.0)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color.a = 0.22
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_jar.add_child(_cyl(JAR_R - 0.008, JAR_H, glass, 18, JAR_R, Vector3(0, 0.03 + JAR_H * 0.5, 0)))
	var lid := _mat("lid", Color(0.08, 0.08, 0.09), 0.5)
	_jar.add_child(_cyl(JAR_R + 0.004, 0.018, lid, 18, JAR_R + 0.004, Vector3(0, 0.03 + JAR_H + 0.009, 0)))
	_jar.add_child(_cyl(0.016, 0.02, lid, 10, 0.016, Vector3(0, 0.03 + JAR_H + 0.028, 0)))
	# A handle on the jar.
	_jar.add_child(_box(Vector3(0.014, 0.14, 0.022), Vector3(JAR_R + 0.03, 0.03 + JAR_H * 0.55, 0), glass))
	# AFFORDANCE HOOK: the always-on "BLENDER" label is gone (scripts/aim_highlight.gd now supplies
	# the "you can interact with this" cue as an aim rim, docs/CONTRACTS.md "Interaction"); the
	# swirling jar of brains reads as a blender on sight, and the crosshair prompt still names the
	# action when aimed at.
	# The aim target for E.
	var area := Area3D.new()
	area.name = "Aim"
	area.collision_layer = C.L_INTERACT
	area.collision_mask = 0
	area.monitoring = false
	var acs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.24
	acs.shape = sph
	acs.position = Vector3(0, top + 0.17, 0)
	area.add_child(acs)
	add_child(area)


func set_progress(p: float) -> void:
	progress = clampf(p, 0.0, 1.0)


## A brain was drunk: the jar empties over a moment.
func drain() -> void:
	_drain = 1.0
	_fill = maxf(_fill, 0.85)


func _process(delta: float) -> void:
	_t += delta
	var blending := progress > 0.001
	if blending:
		_fill = maxf(_fill, 0.25 + progress * 0.7)
		_drain = 0.0
	elif _drain > 0.0:
		_drain = maxf(0.0, _drain - delta * 1.3)
		_fill = 0.85 * _drain
	else:
		_fill = move_toward(_fill, 0.0, delta * 1.5)
	_swirl_mat.set_shader_parameter("level", _fill)
	_swirl_mat.set_shader_parameter("spin", 1.0 if blending else 0.3)
	_swirl_mat.set_shader_parameter("swirl_t", _t * (1.0 if blending else 0.1))
	_lamp_mat.emission_energy_multiplier = 2.6 if blending else 0.0
	if blending:
		_jar.position.x = sin(_t * 90.0) * 0.0025
		_jar.position.z = cos(_t * 77.0) * 0.002
	else:
		_jar.position.x = 0.0
		_jar.position.z = 0.0
	_sound(blending)


func _sound(blending: bool) -> void:
	if blending and _whirr == null:
		_whirr = Audio.play("brains_blend", global_position + Vector3.UP * 1.0, -2.0)
		_whirr_stream = _whirr.get("stream") if _whirr != null else null
	elif not blending and _whirr != null:
		if is_instance_valid(_whirr) and _whirr.get("stream") == _whirr_stream and _whirr.has_method("stop"):
			_whirr.stop()
		_whirr = null


# ---- interactable contract (the brains system answers) ----

func _brains() -> Node:
	var g = get_tree().get_first_node_in_group("game") if is_inside_tree() else null
	return g.brains if g != null else null


func interact_prompt(player) -> String:
	var b := _brains()
	return b.blender_prompt(player) if b != null else ""


func interact_hold() -> float:
	return 1.5


func interact(_player) -> void:
	pass   # a hold: the brains system simulates it every frame on the host


# ---- building blocks ----

static func _mat(key: String, col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "blender_" + key
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	_mats[key] = m
	return m


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi


static func _cyl(r: float, h: float, mat: Material, sides := 12, r_top := -1.0, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.bottom_radius = r
	c.top_radius = r if r_top < 0.0 else r_top
	c.height = h
	c.radial_segments = sides
	c.rings = 1
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	return mi
