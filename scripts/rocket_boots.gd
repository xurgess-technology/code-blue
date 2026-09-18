extends RefCounted
## ROCKET BOOTS: what a pair looks like on a surgeon, and the flame while it burns (player.gd
## "ROCKET BOOTS" has the flight). A thruster pod rides each foot bone (`foot.L` / `foot.R` on the
## Blender surgeon; the body's root at the ankles on a rig without them). The flames and the glow are
## top level: every frame they sit on the pods and trail straight back from the way the body is
## travelling, so they read right in any pose. Built on first use; warm() pre-draws the materials.

const POD_COLOR := Color(0.32, 0.34, 0.36)
const TRIM_COLOR := Color(0.85, 0.3, 0.12)
const FLAME_COLOR := Color(1.0, 0.35, 0.05)
const CORE_COLOR := Color(1.0, 0.75, 0.3)
const FLAME_LEN := 0.8
const LIGHT_ENERGY := 3.0

const LightRoomsSelf := preload("res://scripts/level/light_rooms.gd")

static var _mats := {}

var player: Node3D
var body: Node3D
var _pods: Array = []
var _flames: Array = []
var _light: OmniLight3D
var _burn := 0.0
var _t := 0.0
var _last_pos := Vector3.INF
var _heading := Vector3.FORWARD
var _sound: Node = null
var _sound_stream: Resource = null


func _init(p: Node3D, body_visual: Node3D) -> void:
	player = p
	body = body_visual
	var skel: Skeleton3D = null
	if body != null:
		var found := body.find_children("*", "Skeleton3D", true, false)
		if not found.is_empty():
			skel = found[0]
	for side in ["L", "R"]:
		var holder: Node3D = null
		if skel != null and skel.find_bone("foot." + side) >= 0:
			var att := BoneAttachment3D.new()
			att.bone_name = "foot." + side
			skel.add_child(att)
			holder = att
		elif body != null:
			holder = Node3D.new()
			holder.position = Vector3(0.12 if side == "L" else -0.12, 0.08, 0.0)
			body.add_child(holder)
		if holder == null:
			continue
		var pod := make_pod()
		holder.add_child(pod)
		_pods.append(pod)
		var flame := make_flame()
		flame.top_level = true
		flame.visible = false
		player.add_child(flame)
		_flames.append(flame)
	_light = OmniLight3D.new()
	_light.light_color = FLAME_COLOR
	_light.omni_range = 3.5
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.visible = false
	_light.top_level = true
	player.add_child(_light)
	# The local surgeon's own body only shows in mirrors: its pods and flames live on that layer too.
	if bool(player.get("is_local")) and not bool(player.get("is_bot")):
		for n in _pods + _flames:
			for vi in ([n] + (n as Node).find_children("*", "VisualInstance3D", true, false)):
				if vi is VisualInstance3D:
					(vi as VisualInstance3D).layers = LightRoomsSelf.SELF


## One heel thruster: a steel can with an orange band, standing behind the ankle, in foot-bone space
## (on the Blender surgeon the bone sits at the ankle, +Y runs toward the toes, +Z up the calf).
static func make_pod() -> Node3D:
	var root := Node3D.new()
	root.name = "RocketPod"
	var can := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 0.06
	cm.height = 0.17
	cm.radial_segments = 12
	cm.rings = 1
	can.mesh = cm
	can.material_override = _mat("pod", POD_COLOR, false)
	can.position = Vector3(0.0, -0.075, 0.03)
	can.rotation_degrees.x = 90.0
	root.add_child(can)
	var band := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.064
	bm.bottom_radius = 0.064
	bm.height = 0.035
	bm.radial_segments = 12
	bm.rings = 1
	band.mesh = bm
	band.material_override = _mat("trim", TRIM_COLOR, false)
	band.position = Vector3(0.0, -0.075, 0.08)
	band.rotation_degrees.x = 90.0
	root.add_child(band)
	return root


## One flame: an orange cone round a short yellow-white core, tips at +Y (placed each frame to trail
## behind).
static func make_flame() -> MeshInstance3D:
	var mi := _cone("RocketFlame", 0.085, FLAME_LEN, _mat("flame", FLAME_COLOR, true))
	var core := _cone("Core", 0.05, FLAME_LEN * 0.5, _mat("core", CORE_COLOR, true))
	core.position.y = -FLAME_LEN * 0.25
	mi.add_child(core)
	return mi


static func _cone(n: String, r: float, h: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = r
	cone.height = h
	cone.radial_segments = 10
	cone.rings = 1
	mi.mesh = cone
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _mat(key: String, col: Color, glow: bool) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	if glow:
		# Unshaded, see-through, blended over (not added: added, the grading burns it to white).
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(col, 0.8)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		m.metallic = 0.7
		m.roughness = 0.45
	_mats[key] = m
	return m


## Warmup (scripts/warmup.gd): a pod and a lit flame, so the first pair doesn't stutter.
static func warm(shelf: Node3D) -> void:
	var pod := make_pod()
	shelf.add_child(pod)
	pod.position = Vector3(-1.4, 0.3, 0.3)
	var flame := make_flame()
	shelf.add_child(flame)
	flame.position = Vector3(-1.6, 0.3, 0.3)


func update(delta: float, wearing: bool, burning: bool) -> void:
	_t += delta
	for pod in _pods:
		(pod as Node3D).visible = wearing
	# Heading from how the body actually moved (remote copies have no velocity of their own).
	var pos := player.global_position
	if _last_pos != Vector3.INF and delta > 0.0:
		var v := (pos - _last_pos) / delta
		v.y = 0.0
		if v.length() > 1.0:
			_heading = v.normalized()
	_last_pos = pos
	_burn = move_toward(_burn, 1.0 if (burning and wearing) else 0.0, delta * (12.0 if burning else 5.0))
	var on := _burn > 0.01
	var flicker := 0.85 + 0.15 * sin(_t * 53.0) + 0.1 * sin(_t * 31.0 + 1.3)
	var centre := Vector3.ZERO
	for i in _flames.size():
		var flame: MeshInstance3D = _flames[i]
		flame.visible = on
		var pod: Node3D = _pods[i]
		var at: Vector3 = pod.global_position if pod.is_inside_tree() else pos
		centre += at
		if not on:
			continue
		var back := -_heading
		var side := back.cross(Vector3.UP)
		if side.length() < 0.01:
			side = Vector3.RIGHT
		side = side.normalized()
		var fwd := side.cross(back).normalized()
		var k := _burn * flicker
		var b := Basis(side, back * k, fwd)
		flame.global_transform = Transform3D(b, at + back * (FLAME_LEN * 0.5 * k))
	if not _flames.is_empty():
		centre /= float(_flames.size())
	_light.visible = on
	if on:
		_light.global_position = centre - _heading * 0.3
		_light.light_energy = LIGHT_ENERGY * _burn * flicker
	_update_sound(burning and wearing, pos)


func _update_sound(burning: bool, at: Vector3) -> void:
	var ours: bool = _sound != null and is_instance_valid(_sound) and _sound.get("stream") == _sound_stream \
			and _sound_stream != null and bool(_sound.call("is_playing"))
	if burning and not ours:
		_sound = Audio.play("rocket_burn", at, -2.0, 0.05)
		_sound_stream = _sound.get("stream") if _sound != null else null
	elif burning and ours and _sound is Node3D:
		(_sound as Node3D).global_position = at
	elif not burning and ours:
		_sound.call("stop")
		_sound = null
		_sound_stream = null
