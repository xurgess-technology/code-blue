extends Node3D
## The visual of one monster: the reshaped Kenney rig plus hand-built geometry.
## Knows nothing about behaviour; the Monster tells it what to show every frame.

const Shaper := preload("res://scripts/monsters/rig_shaper.gd")
const Shapes := preload("res://scripts/monsters/shapes.gd")
const DischargedLook := preload("res://scripts/monsters/discharged_look.gd")
const NurseLook := preload("res://scripts/monsters/night_nurse_look.gd")

const RIG_KEY := "patient/human"
const LOOPING := ["idle", "walk", "sprint"]

var kind := ""
var rig: Node3D = null
var skeleton: Skeleton3D = null
var anim: AnimationPlayer = null
var shaper: Shaper = null
var iv: Node3D = null            ## the Discharged's IV pole, top-level
var _logical := ""
var _fallback: Node3D = null


func setup(monster_kind: String) -> void:
	kind = monster_kind
	name = "Model"
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
		_:
			DischargedLook.build(self)
	play("idle")


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


func body_material(m: Material) -> void:
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
		var real := Assets.anim_name(RIG_KEY, logical)
		if real != "" and anim.has_animation(real):
			anim.play(real, blend)
			_logical = logical
	anim.speed_scale = rate


func current() -> String:
	return _logical


func attack_length() -> float:
	var real := Assets.anim_name(RIG_KEY, "attack")
	return anim.get_animation(real).length if anim != null and anim.has_animation(real) else 0.4


func add_part(node: Node3D, bone: String, offset := Transform3D.IDENTITY, tip := 0.0) -> void:
	if shaper != null:
		shaper.attach(node, bone, offset, tip)


func hand_point(left := true) -> Vector3:
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
	var tall := 2.25 if kind == "night_nurse" else 1.8
	var col := Color("dcd8cc") if kind == "night_nurse" else Color("9aa39c")
	var body := Shapes.cylinder(0.16, tall * 0.62, Shapes.flat(col, 0.9), Vector3(0, tall * 0.45, 0), 0.12)
	_fallback.add_child(body)
	_fallback.add_child(Shapes.ellipsoid(Vector3(0.1, 0.13, 0.11), Shapes.flat(Color("b8b3a6")), Vector3(0, tall - 0.13, 0)))


func _process(delta: float) -> void:
	if iv != null and iv.has_method("follow"):
		iv.follow(self, delta)
