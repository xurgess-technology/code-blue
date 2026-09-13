extends SkeletonModifier3D
## Reshapes the Kenney mini-character rig into something that is not a person.
##
## The Kenney rig has seven bones: root, leg-left, leg-right, torso, arm-left,
## arm-right, head. Its animations key positions and rotations but never scale, so a
## modifier that runs after the AnimationPlayer can stretch, thin, hunch and re-pose
## the bones every frame while the walk/sprint/idle clips still drive the motion.
##
## What it does to each bone (the numbers live in `cfg`, in metres):
##   legs   scaled along their length to `leg_len` and thinned; the root is lifted so
##          the feet stay on the floor; stride and bob are scaled.
##   torso  collapsed to a uniform 2% (its blocky Kenney mesh vanishes inside our own
##          ribcage / gown geometry) and pitched forward by `hunch`. Because the
##          collapse is uniform, the children compensate exactly with 1/u: no shear.
##   arms   moved to narrow `shoulder` sockets, stretched to `arm_len`, thinned, and
##          re-posed from the clip's A-pose into hanging arms whose swing is taken
##          from the clip's own swing angle. `lunge` reaches them forward.
##   head   lifted to `neck` height (a long neck), pitched, tilted and turned by the
##          dynamic listen / twitch values. The Kenney head mesh is hidden; our head
##          geometry rides the bone through `attach()`.
##
## Attachments are plain Node3D children of the Skeleton3D that follow a bone's
## orthonormal frame, so hand-built meshes are never sheared by the bone scales.

const LEG_REST := 0.17625
const ARM_REST := 0.28369
const COLLAPSE := 0.02

var cfg := {
	"leg_len": 0.9, "leg_thick": 0.55, "hip_half": 0.1, "stride": 1.0, "bob": 1.0,
	"shoulder": Vector3(0.17, 0.5, 0.0), "neck": Vector3(0.0, 0.64, 0.02),
	"arm_len": 0.75, "arm_thick": 0.42, "arm_swing": 1.0, "arm_idle": 0.5,
	"hunch": 0.0, "head_pitch": 0.0, "head_roll": 0.0, "torso_sway": 1.0, "head_sway": 1.0,
	"arm_l": {}, "arm_r": {},
}
## Metres per skeleton unit (the scale Assets.spawn applied to the glTF).
var model_scale := 1.0

# Dynamic pose inputs, set by the monster model every frame.
var listen := 0.0          ## 0..1 freeze-and-tilt
var listen_yaw := 0.0      ## radians, positive turns the face toward the body's left (+X of the rig)
var lunge := 0.0           ## 0..1 reach
var stagger := 0.0         ## 0..1 knocked back
var twitch := Vector3.ZERO ## small extra head rotation (radians)

var _bones := {}
var _attachments: Array = []
## World positions of the hands, captured while the reshaped pose is live. Outside the
## skeleton update the bones read back as the unmodified clip pose, so read these instead.
var hand_left := Vector3.ZERO
var hand_right := Vector3.ZERO


func _skel() -> Skeleton3D:
	var sk := get_parent() as Skeleton3D
	if sk != null and _bones.is_empty():
		for i in sk.get_bone_count():
			_bones[sk.get_bone_name(i)] = i
		sk.skeleton_updated.connect(_update_attachments)
	return sk


## Make `node` follow `bone`. `offset` is in metres in the bone's frame (+Y up, +Z front).
## `tip` > 0 slides the anchor that fraction of the way down a stretched arm or leg.
func attach(node: Node3D, bone: String, offset := Transform3D.IDENTITY, tip := 0.0) -> void:
	var sk := _skel()
	sk.add_child(node)
	_attachments.append({"node": node, "bone": _bones.get(bone, -1), "name": bone, "offset": offset, "tip": tip})


## World-space position of an attachment point, for things like the IV tube.
func bone_point(bone: String, offset := Vector3.ZERO, tip := 0.0) -> Vector3:
	var sk := _skel()
	var t := _frame(_bones.get(bone, -1), bone, tip)
	return sk.global_transform * (t * (offset / model_scale))


func _frame(idx: int, bone: String, tip: float) -> Transform3D:
	var sk := _skel()
	if idx < 0:
		return Transform3D.IDENTITY
	var g := sk.get_bone_global_pose(idx)
	var r := g.basis.orthonormalized()
	var o := g.origin
	if tip > 0.0:
		if bone == "arm-left":
			o += r * Vector3(1, 0, 0) * (cfg.arm_len / model_scale) * tip
		elif bone == "arm-right":
			o += r * Vector3(-1, 0, 0) * (cfg.arm_len / model_scale) * tip
		elif bone.begins_with("leg"):
			o += r * Vector3(0, -1, 0) * (cfg.leg_len / model_scale) * tip
	return Transform3D(r, o)


func _update_attachments() -> void:
	var inv := 1.0 / model_scale
	hand_left = bone_point("arm-left", Vector3.ZERO, 0.92)
	hand_right = bone_point("arm-right", Vector3.ZERO, 0.92)
	for a in _attachments:
		var node: Node3D = a.node
		if not is_instance_valid(node):
			continue
		var f := _frame(a.bone, a.name, a.tip)
		var off: Transform3D = a.offset
		node.transform = Transform3D(f.basis * Basis().scaled(Vector3(inv, inv, inv)) * off.basis, f.origin + f.basis * (off.origin * inv))


func _process_modification_with_delta(_delta: float) -> void:
	var sk := _skel()
	if sk == null or _bones.is_empty():
		return
	var S := model_scale
	var u := COLLAPSE
	var leg_k: float = cfg.leg_len / (LEG_REST * S)
	var lift := LEG_REST * (leg_k - 1.0)

	var root: int = _bones.get("root", -1)
	if root >= 0:
		var p := sk.get_bone_pose_position(root)
		sk.set_bone_pose_position(root, Vector3(p.x, p.y * cfg.bob + lift, p.z))

	var thick: float = cfg.leg_thick
	for side in [["leg-left", 1.0], ["leg-right", -1.0]]:
		var li: int = _bones.get(side[0], -1)
		if li < 0:
			continue
		var lp := sk.get_bone_pose_position(li)
		sk.set_bone_pose_position(li, Vector3(side[1] * cfg.hip_half / S, lp.y, lp.z))
		var le := Basis(sk.get_bone_pose_rotation(li)).get_euler()
		var swing: float = le.x * cfg.stride
		sk.set_bone_pose_rotation(li, Quaternion(Vector3.RIGHT, swing))
		sk.set_bone_pose_scale(li, Vector3(thick, leg_k, thick))

	var ti: int = _bones.get("torso", -1)
	if ti < 0:
		return
	var te := Basis(sk.get_bone_pose_rotation(ti)).get_euler()
	var pitch: float = cfg.hunch + te.x * cfg.torso_sway + lunge * 0.45 - stagger * 0.5 - listen * cfg.hunch * 0.35
	var torso_q := Quaternion.from_euler(Vector3(pitch, te.y * cfg.torso_sway, stagger * 0.15))
	sk.set_bone_pose_rotation(ti, torso_q)
	sk.set_bone_pose_scale(ti, Vector3(u, u, u))

	var inv := 1.0 / u
	for side in [["arm-left", 1.0, "arm_l"], ["arm-right", -1.0, "arm_r"]]:
		var ai: int = _bones.get(side[0], -1)
		if ai < 0:
			continue
		var sgn: float = side[1]
		var o: Dictionary = cfg[side[2]]
		var sh: Vector3 = cfg.shoulder
		sk.set_bone_pose_position(ai, Vector3(sgn * sh.x, sh.y, sh.z) / S * inv)
		var ae := Basis(sk.get_bone_pose_rotation(ai)).get_euler()
		# Kenney swings its A-pose arms about Y; a hanging arm swings about X instead.
		var back: float = ae.y * sgn * float(o.get("swing", cfg.arm_swing)) + deg_to_rad(float(o.get("back", 0.0)))
		var spread: float = deg_to_rad(float(o.get("spread", 6.0))) + (absf(ae.z) - PI * 0.25) * float(o.get("idle", cfg.arm_idle))
		back = lerpf(back, deg_to_rad(-80.0), lunge * float(o.get("lunge", 1.0)))
		spread = lerpf(spread, deg_to_rad(14.0), lunge * float(o.get("lunge", 1.0)))
		var twist: float = deg_to_rad(float(o.get("twist", 0.0)))
		var hang := Quaternion(Vector3.BACK, -sgn * (PI * 0.5 - spread))
		var q := Quaternion(Vector3.RIGHT, back) * Quaternion(Vector3.UP, twist * sgn) * hang
		sk.set_bone_pose_rotation(ai, q)
		var arm_k: float = cfg.arm_len / (ARM_REST * S)
		var at: float = cfg.arm_thick
		sk.set_bone_pose_scale(ai, Vector3(arm_k, at, at) * inv)

	var hi: int = _bones.get("head", -1)
	if hi >= 0:
		var nk: Vector3 = cfg.neck
		sk.set_bone_pose_position(hi, nk / S * inv)
		var he := Basis(sk.get_bone_pose_rotation(hi)).get_euler()
		var roll: float = cfg.head_roll + listen * signf(listen_yaw if absf(listen_yaw) > 0.05 else 1.0) * 0.6
		var hp: float = cfg.head_pitch - pitch * 0.8 + he.x * cfg.head_sway - lunge * 0.2 + listen * 0.15
		var hq := Quaternion(Vector3.UP, listen_yaw * listen + he.y * cfg.head_sway + twitch.y) \
			* Quaternion(Vector3.RIGHT, hp + twitch.x) * Quaternion(Vector3.BACK, roll + twitch.z)
		sk.set_bone_pose_rotation(hi, hq)
		sk.set_bone_pose_scale(hi, Vector3(inv, inv, inv))
