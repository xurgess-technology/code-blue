extends SkeletonModifier3D
## The Hive's stylized model (`monster/hive`, art/stylized variant `hive`) on a monster model.
##
## `build(model)` spawns the GLB under the MonsterModel, points the model's `rig`, `skeleton` and `anim`
## at it and adds this modifier to its skeleton, plus a node named `Head` riding the head bone in the
## model's own axes (+Y up, +Z its face; Monster.eye_transform and Hive Eyes look for it). The eyes get
## the glowing eye shader (shaders/hive_eye.gdshader).
##
## Clips (Assets anims): HiveIdle (5 s loop), HiveWalk (a shamble dragging the right leg, 0.85 m/s,
## in place), HiveAttack (the lunge, one-shot). The monster picks the clip and the rate; this modifier
## adds the poses there are no clips for, on top of whatever the clip left.
##
## It stands in for rig_shaper.gd: `model.shaper` points here, so monster.gd, the stun window and the
## dissection table set the same inputs they give the Kenney-rig monsters:
##   lying    0..1  straight on its back, arms at its sides (the Monster tips the whole model over)
##   daze     0..1  the shove's stun: slumped, head hanging, arms dangling; `rise` 0..1 the jerk up at its end
##   stagger  0..1  knocked back
##   twitch   small extra head rotation (radians, skeleton axes)
##   lunge, listen, listen_yaw   accepted; the attack clip does the reach and the Hive is deaf
## and one of its own:
##   lock     0..1  locked on to someone: the head comes up out of its hang and looks at `look_target`
##                  (world), and the eyes go from a pinpoint to fully lit
##
## Every value is in skeleton space (+Y up, +Z its front, +X its left). Nothing runs while every value is zero.

const KEY := "monster/hive"
## Ground speed at which HiveWalk's planted foot keeps pace with the ground (art/stylized/st_hive_clips.py).
const WALK_SPEED := 0.85
const GLOW := Color(1.0, 0.42, 0.06)
## The skin texture times this (see _setup).
const SKIN_DARKEN := 0.7
const EYE_SHADER := "res://shaders/hive_eye.gdshader"
## How far the look can turn the head from where the clip has it, and how the turn is shared out.
const LOOK_MAX := 1.35
## Little in the neck: the gown's collar and the skin under it are weighted differently there.
const LOOK_SHARE := {"chest": 0.3, "neck": 0.15, "head": 0.55}

var cfg := {"lying_spread": 6.0}
var listen := 0.0
var listen_yaw := 0.0
var lunge := 0.0
var stagger := 0.0
var twitch := Vector3.ZERO
var lying := 0.0
var daze := 0.0
var rise := 0.0
var lock := 0.0
## World position the head looks at while `lock` > 0.
var look_target := Vector3.ZERO
## Where the eyes sit in the Head node's frame; set from the model's Site_eyes.
var eye_offset := Vector3(0.0, 0.10, 0.09)
## World positions of the hands after this frame's pose (outside the update the bones read back the clip).
var hand_left := Vector3.ZERO
var hand_right := Vector3.ZERO

var _b := {}
var _rest_fwd := Vector3.BACK      ## the face's forward, in the head bone's own frame
var _rest_up := Vector3.UP
var _eye_mats: Array = []
var _eye_light: OmniLight3D = null
var _shown_lock := -1.0

static var _looped := false


## Spawn the model under `model` (a MonsterModel). False when the asset is missing or broken.
static func build(model: Node3D) -> bool:
	if not Assets.has(KEY):
		return false
	var root: Node3D = Assets.spawn(KEY)
	if root == null:
		return false
	var skels := root.find_children("*", "Skeleton3D", true, false)
	var ap: AnimationPlayer = Assets.anim_player(root)
	if skels.is_empty() or ap == null:
		root.free()
		return false
	model.add_child(root)
	model.rig = root
	model.skeleton = skels[0]
	model.anim = ap
	if not _looped:
		# The imported clips are one-shot; only this model uses them, so loop the shared copies once.
		_looped = true
		for n in ["HiveIdle", "HiveWalk"]:
			if ap.has_animation(n):
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	var sk: Skeleton3D = skels[0]
	var poser = load("res://scripts/monsters/hive_rig.gd").new()
	poser.name = "HivePoser"
	sk.add_child(poser)
	poser._setup(root, sk)
	model.hive = poser
	model.shaper = poser
	return true


func _setup(root: Node3D, sk: Skeleton3D) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# A flashlight at arm's length burns the charcoal skin out to grey; the imported skin (shared by
	# every Hive, so once) is taken down to keep it charcoal where the Hives are met.
	var body := root.find_child("Human", true, false) as MeshInstance3D
	if body != null and body.mesh != null:
		for si in body.mesh.get_surface_count():
			var m := body.mesh.surface_get_material(si) as BaseMaterial3D
			if m != null and m.resource_name.contains("Skin") and not m.has_meta("hive_dark"):
				m.albedo_color = Color(SKIN_DARKEN, SKIN_DARKEN, SKIN_DARKEN)
				m.set_meta("hive_dark", true)
	var hi := _bone(sk, "head")
	var rest := sk.get_bone_global_rest(hi) if hi >= 0 else Transform3D()
	var rb := rest.basis.orthonormalized()
	_rest_fwd = rb.inverse() * Vector3.BACK
	_rest_up = rb.inverse() * Vector3.UP
	# `Head`: rides the head bone, turned so that at rest its axes are the model's (+Y up, +Z the face).
	var ba := BoneAttachment3D.new()
	ba.name = "HeadBone"
	ba.bone_name = "head"
	sk.add_child(ba)
	var head := Node3D.new()
	head.name = "Head"
	head.transform = Transform3D(rb.inverse(), Vector3.ZERO)
	ba.add_child(head)
	var site := root.find_child("Site_eyes", true, false) as Node3D
	if site != null and hi >= 0:
		eye_offset = (rest * site.position) - rest.origin
	# The eyes: the painted ball from the Skin atlas, plus the orange glow.
	var shader := load(EYE_SHADER) as Shader
	for n in ["Human_Eye_L", "Human_Eye_R"]:
		var mi := root.find_child(n, true, false) as MeshInstance3D
		if mi == null or shader == null or mi.mesh == null:
			continue
		var src := mi.get_active_material(0) as BaseMaterial3D
		var sm := ShaderMaterial.new()
		sm.shader = shader
		if src != null:
			sm.set_shader_parameter("albedo_tex", src.albedo_texture)
		sm.set_shader_parameter("glow", GLOW)
		mi.material_override = sm
		_eye_mats.append(sm)
	# A little orange spill on the face while it is locked on.
	_eye_light = OmniLight3D.new()
	_eye_light.name = "EyeGlow"
	_eye_light.light_color = GLOW
	_eye_light.omni_range = 0.45
	_eye_light.light_energy = 0.0
	_eye_light.shadow_enabled = false
	_eye_light.visible = false
	_eye_light.position = eye_offset + Vector3(0.0, 0.0, 0.04)
	head.add_child(_eye_light)
	_set_glow(0.0)


func _bone(sk: Skeleton3D, n: String) -> int:
	if _b.is_empty():
		for i in sk.get_bone_count():
			_b[sk.get_bone_name(i)] = i
	return int(_b.get(n, -1))


## Eyes and their spill: 0 a soft pinpoint, 1 the whole eyeball lit.
func _set_glow(v: float) -> void:
	if absf(v - _shown_lock) < 0.01:
		return
	_shown_lock = v
	for sm in _eye_mats:
		(sm as ShaderMaterial).set_shader_parameter("lock", v)
	if _eye_light != null:
		_eye_light.visible = v > 0.02
		_eye_light.light_energy = 0.22 * v


## World position of a bone (after this frame's pose).
func bone_world(n: String) -> Vector3:
	var sk := get_skeleton()
	if sk == null:
		return Vector3.ZERO
	var i := _bone(sk, n)
	if i < 0:
		return sk.global_position
	return sk.global_transform * sk.get_bone_global_pose(i).origin


## rig_shaper.gd's API, for anything that asks. The Hive carries nothing extra on its bones.
func attach(node: Node3D, bone: String, offset := Transform3D.IDENTITY, _tip := 0.0) -> void:
	var sk := get_skeleton()
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone
	sk.add_child(ba)
	node.transform = offset
	ba.add_child(node)


func bone_point(bone: String, offset := Vector3.ZERO, _tip := 0.0) -> Vector3:
	var sk := get_skeleton()
	var i := _bone(sk, bone)
	if i < 0:
		return sk.global_position
	return sk.global_transform * (sk.get_bone_global_pose(i) * offset)


## Turn `bone` about a skeleton-space axis through its own head, on top of its current pose.
func _turn(sk: Skeleton3D, bone: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.0001 or axis.length_squared() < 1e-8:
		return
	var i := _bone(sk, bone)
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var g := pg * Basis(sk.get_bone_pose_rotation(i))
	var local := pg.inverse() * (Basis(axis.normalized(), angle) * g)
	sk.set_bone_pose_rotation(i, local.get_rotation_quaternion())


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	_set_glow(lock)
	if lying == 0.0 and daze == 0.0 and rise == 0.0 and stagger == 0.0 and lock == 0.0 and twitch == Vector3.ZERO:
		_record_hands(sk)
		return
	var X := Vector3.RIGHT
	var Z := Vector3.BACK
	if lying > 0.0:
		_lie(sk)
	var l := 1.0 - lying
	if daze > 0.0 or rise > 0.0:
		# Stunned: folded over, the head hanging, the arms swinging loose; jerking up at the end.
		var jolt := sin(Time.get_ticks_msec() * 0.031) * rise * (1.0 - rise) * 2.2
		_turn(sk, "spine", X, (0.35 * daze - 0.2 * jolt) * l)
		_turn(sk, "neck", X, (0.35 * daze - 0.3 * jolt) * l)
		_turn(sk, "head", Z, 0.25 * daze * l)
		_turn(sk, "upperarm.L", X, 0.25 * daze * l)
		_turn(sk, "upperarm.R", X, 0.25 * daze * l)
	if stagger > 0.0:
		_turn(sk, "spine", X, -0.35 * stagger * l)
		_turn(sk, "head", X, -0.3 * stagger * l)
	if twitch != Vector3.ZERO and lock < 0.99:
		var tw := twitch * l * (1.0 - lock)
		_turn(sk, "head", Vector3.UP, tw.y)
		_turn(sk, "head", X, tw.x)
		_turn(sk, "head", Z, tw.z)
	if lock > 0.0 and l > 0.0:
		_look(sk, lock * l)
	_record_hands(sk)


func _record_hands(sk: Skeleton3D) -> void:
	var li := _bone(sk, "hand.L")
	var ri := _bone(sk, "hand.R")
	if li >= 0:
		hand_left = sk.global_transform * sk.get_bone_global_pose(li).origin
	if ri >= 0:
		hand_right = sk.global_transform * sk.get_bone_global_pose(ri).origin


## Straight on its back: every bone eases back to rest (standing straight), then the arms come in
## to its sides for the straps (cfg.lying_spread degrees off the body).
func _lie(sk: Skeleton3D) -> void:
	var k := lying
	for i in sk.get_bone_count():
		var r := sk.get_bone_rest(i)
		sk.set_bone_pose_rotation(i, sk.get_bone_pose_rotation(i).slerp(r.basis.get_rotation_quaternion(), k))
		sk.set_bone_pose_position(i, sk.get_bone_pose_position(i).lerp(r.origin, k))
	var spread := deg_to_rad(float(cfg.get("lying_spread", 6.0)))
	for side in [["L", 1.0], ["R", -1.0]]:
		var ua := _bone(sk, "upperarm." + side[0])
		var fa := _bone(sk, "forearm." + side[0])
		if ua < 0 or fa < 0:
			continue
		var d := sk.get_bone_global_pose(fa).origin - sk.get_bone_global_pose(ua).origin
		var now := atan2(d.x * side[1], -d.y)            # the arm's angle out from straight down
		_turn(sk, "upperarm." + side[0], Vector3.BACK, (spread - now) * side[1] * k)


## The head comes up and looks at `look_target`: the turn from where the clip has the face to the target,
## shared between the chest, the neck and the head, and the hanging tilt levelled out.
func _look(sk: Skeleton3D, amt: float) -> void:
	var hi := _bone(sk, "head")
	if hi < 0:
		return
	var inv := sk.global_transform.affine_inverse()
	var target := inv * look_target
	var g := sk.get_bone_global_pose(hi)
	var eye := g * eye_offset_bone()
	var fwd := (g.basis.orthonormalized() * _rest_fwd).normalized()
	var to := (target - eye)
	if to.length() < 0.2:
		return
	to = to.normalized()
	var axis := fwd.cross(to)
	var ang := minf(fwd.angle_to(to), LOOK_MAX) * amt
	if axis.length() > 1e-4:
		for bn in LOOK_SHARE:
			_turn(sk, bn, axis, ang * float(LOOK_SHARE[bn]))
	# Level the hung tilt: turn about the look direction until the head's up is the world's.
	g = sk.get_bone_global_pose(hi)
	var up := (g.basis.orthonormalized() * _rest_up).normalized()
	var f2 := (g.basis.orthonormalized() * _rest_fwd).normalized()
	var want := (Vector3.UP - f2 * f2.dot(Vector3.UP))
	if want.length() > 1e-3:
		want = want.normalized()
		var roll := up.signed_angle_to(want, f2)
		_turn(sk, "head", f2, roll * amt * 0.85)


## The eyes' offset in the head bone's own frame (eye_offset is in the Head node's model-aligned frame).
func eye_offset_bone() -> Vector3:
	var sk := get_skeleton()
	var hi := _bone(sk, "head")
	if hi < 0:
		return eye_offset
	return sk.get_bone_global_rest(hi).basis.orthonormalized().inverse() * eye_offset
