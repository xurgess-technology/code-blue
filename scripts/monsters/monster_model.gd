extends Node3D
## The visual of one monster: the reshaped Kenney rig plus hand-built geometry, or for the Night
## Nurse and the Hive their own Blender-made models (night_nurse_rig.gd, hive_rig.gd; the reshaped rig
## is the fallback when the asset is missing). Knows nothing about behaviour; the Monster tells it what
## to show every frame.

const Shaper := preload("res://scripts/monsters/rig_shaper.gd")
const Shapes := preload("res://scripts/monsters/shapes.gd")
const DischargedLook := preload("res://scripts/monsters/discharged_look.gd")
const NurseLook := preload("res://scripts/monsters/night_nurse_look.gd")
const HiveLook := preload("res://scripts/monsters/hive_look.gd")
const NurseRig := preload("res://scripts/monsters/night_nurse_rig.gd")
const HiveRig := preload("res://scripts/monsters/hive_rig.gd")
const SonoRig := preload("res://scripts/monsters/sonographer_rig.gd")

const RIG_KEY := "patient/human"
const LOOPING := ["idle", "walk", "sprint"]

var kind := ""
var rig: Node3D = null
var skeleton: Skeleton3D = null
var anim: AnimationPlayer = null
## The pose inputs monster.gd sets every frame: the Kenney rig's RigShaper, or the Hive's poser (same fields).
var shaper = null
## The Night Nurse's model: its pose modifier (night_nurse_rig.gd), null for every other look.
var nurse = null
## The Hive's model: its pose modifier (hive_rig.gd), null for every other look. It is `shaper` too.
var hive = null
## The Sonographer's model: its pose modifier and its look interface (sonographer_rig.gd), null for
## every other look. It is `shaper` too.
var sono = null
var iv: Node3D = null            ## the Discharged's IV pole, top-level
## Movable ears: [{node: Node3D pivot on the head, side: +1 left / -1 right, rest: outward radians}]
var ears: Array = []
var _ear_listen := 0.0
var _ear_yaw := 0.0
var _ear_twitch := 0.0
var _ear_twitch_t := 0.0
var _parts := 0
var _logical := ""
var _fallback: Node3D = null


func setup(monster_kind: String) -> void:
	kind = monster_kind
	name = "Model"
	if kind == "night_nurse" and NurseRig.build(self):
		play("idle")
		return
	if kind == "hive" and HiveRig.build(self):
		play("idle")
		return
	if kind == "sonographer" and SonoRig.build(self):
		play("idle")
		return
	rig = Assets.spawn(RIG_KEY) if Assets.has(RIG_KEY) else null
	if rig != null:
		add_child(rig)
		skeleton = rig.find_children("*", "Skeleton3D", true, false)[0] if not rig.find_children("*", "Skeleton3D", true, false).is_empty() else null
		anim = Assets.anim_player(rig)
	if skeleton == null or anim == null:
		_build_fallback()
		return
	_make_loops()
	shaper = Shaper.new()
	shaper.name = "RigShaper"
	shaper.model_scale = float(Assets.info(RIG_KEY).get("scale", 1.0))
	skeleton.add_child(shaper)
	var head_mesh := skeleton.get_node_or_null("head-mesh") as MeshInstance3D
	if head_mesh != null:
		head_mesh.visible = false
	match kind:
		"night_nurse":
			NurseLook.build(self)
		"hive":
			HiveLook.build(self)
		_:
			DischargedLook.build(self)
	play("idle")


## The Sonographer's look, on top of the clip. Safe on any model: the others ignore it.
##   suspicion   0..1  the neck cranes with it and the throat glows brighter: the body is the meter
##   charge      0..1  the charge pose, and the glow running down the cable into the probe
##   mode              which clip family is playing (idle, wander, suspicious, charging, echo, rush,
##                     wail, search, stagger, lying)
##   aim               the world direction the probe points while it charges and echoes
##   crane_limit 0..1  how far the neck may stretch up before it bends forward instead (the ceiling
##                     check; the brain does the raycast, the model just obeys the number)
## See docs/CONTRACTS.md, "The Sonographer's model".
func set_sono_look(suspicion: float, charge: float, mode: String, aim := Vector3.ZERO, crane_limit := 1.0) -> void:
	if sono != null:
		sono.set_look(suspicion, charge, mode, aim, crane_limit)


## Where an echo fires from and which way it points: the probe's tip (its -Z), not the head.
func echo_origin() -> Transform3D:
	return sono.echo_origin() if sono != null else global_transform


## Ears that turn toward a sound and flare while listening (the Discharged). Every machine,
## every frame. `listen` 0..1, `yaw` the head turn toward the sound (positive: its left).
func set_ears(listen: float, yaw: float, delta: float) -> void:
	if ears.is_empty():
		return
	_ear_listen = move_toward(_ear_listen, listen, delta * 4.0)
	_ear_yaw = lerpf(_ear_yaw, clampf(yaw, -1.2, 1.2) if listen > 0.05 else 0.0, clampf(delta * 5.0, 0.0, 1.0))
	_ear_twitch_t -= delta
	if _ear_twitch_t <= 0.0:
		_ear_twitch_t = randf_range(1.5, 4.0)
		_ear_twitch = randf_range(-0.25, 0.25)
	for e in ears:
		var pivot: Node3D = e.node
		var sx: float = e.side
		var twitch := _ear_twitch * (1.0 - _ear_listen) * (1.0 if sx > 0.0 else 0.6)
		pivot.rotation = Vector3(
			-0.12 - 0.22 * _ear_listen,
			-sx * (e.rest + 0.55 * _ear_listen) + _ear_yaw * 0.55 * _ear_listen + twitch * 0.3,
			sx * (0.05 + 0.12 * _ear_listen))


## A still copy lying on its back along X, head toward -X, face up, origin at the middle of its
## back (the PatientBody convention). Primitives only where the rig is missing. For dissection.
static func make_lying(monster_kind: String) -> Node3D:
	var root := Node3D.new()
	root.name = "LyingMonster"
	var m = load("res://scripts/monsters/monster_model.gd").new()
	root.add_child(m)
	m.setup(monster_kind)
	if m.iv != null:
		m.iv.queue_free()
		m.iv = null
	if m.shaper != null:
		m.shaper.lying = 1.0
	var back := 0.12 if monster_kind == "hive" else 0.09
	if m.nurse != null:
		# Her rest pose is the lying pose: straight, arms at her sides. No clip plays.
		m.anim.stop()
		m.skeleton.reset_bone_poses()
		back = 0.1   # the dress at her shoulder blades; the flared skirt sinks into whatever she lies on
	elif m.sono != null:
		# Its rest pose is standing straight and the poser's `lying` brings the arms in, as the Hive
		# does. The neck goes back to rest length with it: nothing is craned on the table.
		m.sono.set_look(0.0, 0.0, "lying")
		m.anim.stop()
		m.skeleton.reset_bone_poses()
		back = 0.11
	elif m.hive != null:
		# Its rest pose is standing straight; no clip plays, and the poser's `lying` brings the arms in.
		m.anim.stop()
		m.skeleton.reset_bone_poses()
		back = 0.13   # the gown at its shoulder blades
	else:
		m.play("idle", 0.0, 0.0)
	# The model's up (+Y, feet to head) becomes -X, its front (-Z) becomes +Y.
	var tall := 2.1 if monster_kind == "discharged" else (2.3 if monster_kind == "night_nurse" else (2.05 if monster_kind == "sonographer" else 1.75))
	m.transform = Transform3D(Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)), Vector3(tall * 0.5, back, 0.0))
	return root


## The Kenney clips are authored one-shot. A per-model copy of the library gets loops,
## so the shared imported resource (the surgeons use it too) is never touched.
func _make_loops() -> void:
	var lib := anim.get_animation_library("")
	if lib == null:
		return
	var copy: AnimationLibrary = lib.duplicate(false)
	for n in LOOPING:
		if copy.has_animation(n):
			var a: Animation = copy.get_animation(n).duplicate(false)
			a.loop_mode = Animation.LOOP_LINEAR
			copy.remove_animation(n)
			copy.add_animation(n, a)
	anim.remove_animation_library("")
	anim.add_animation_library("", copy)


## Where the eyes are in the frame of the node named `Head` (+Y up the head, +Z the face).
func eye_offset() -> Vector3:
	if nurse != null:
		return NurseRig.EYE_OFFSET
	if hive != null:
		return hive.eye_offset
	if sono != null:
		return sono.eye_offset
	return Vector3(0.0, 0.13, 0.1)


func body_material(m: Material) -> void:
	if skeleton == null:
		return
	var body := skeleton.get_node_or_null("body-mesh") as MeshInstance3D
	if body != null:
		body.material_override = m
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Play a logical clip ("idle", "walk", "run", "attack") at a playback rate. Rate 0 freezes
## the current pose exactly where it is.
func play(logical: String, rate := 1.0, blend := 0.18) -> void:
	if anim == null:
		return
	if logical != _logical:
		var real := Assets.anim_name(_anim_key(), logical)
		if real != "" and anim.has_animation(real):
			anim.play(real, blend)
			_logical = logical
	anim.speed_scale = rate


func current() -> String:
	return _logical


func attack_length() -> float:
	var real := Assets.anim_name(_anim_key(), "attack")
	return anim.get_animation(real).length if anim != null and anim.has_animation(real) else 0.4


func _anim_key() -> String:
	if nurse != null:
		return NurseRig.KEY
	if hive != null:
		return HiveRig.KEY
	if sono != null:
		return SonoRig.KEY
	return RIG_KEY


func add_part(node: Node3D, bone: String, offset := Transform3D.IDENTITY, tip := 0.0) -> void:
	if shaper != null:
		# One draw call per material per part instead of one per primitive (a Hive was ~90).
		_parts += 1
		Shapes.bake(node, "%s|%d" % [kind, _parts])
		shaper.attach(node, bone, offset, tip)


func hand_point(left := true) -> Vector3:
	if nurse != null:
		return nurse.bone_world("hand.L" if left else "hand.R")
	if shaper == null:
		return global_position + Vector3.UP
	var h: Vector3 = shaper.hand_left if left else shaper.hand_right
	return h if h != Vector3.ZERO else global_position + Vector3.UP


func _build_fallback() -> void:
	if rig != null:
		rig.queue_free()
		rig = null
	skeleton = null
	anim = null
	_fallback = Node3D.new()
	add_child(_fallback)
	var tall := 2.25 if kind == "night_nurse" else (1.7 if kind == "hive" else 2.1)
	var col := Color("dcd8cc") if kind == "night_nurse" else (Color("8fa3b5") if kind == "hive" else Color("9aa39c"))
	var body := Shapes.cylinder(0.16, tall * 0.62, Shapes.flat(col, 0.9), Vector3(0, tall * 0.45, 0), 0.12)
	_fallback.add_child(body)
	_fallback.add_child(Shapes.ellipsoid(Vector3(0.1, 0.13, 0.11), Shapes.flat(Color("b8b3a6")), Vector3(0, tall - 0.13, 0)))


func _process(delta: float) -> void:
	if iv != null and iv.has_method("follow"):
		iv.follow(self, delta)

