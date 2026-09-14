extends SkeletonModifier3D
## Pose overrides on a player body (third person), applied after the idle / walk clip: each arm is
## pointed along a direction in skeleton space and the torso leans and twists, each blended over the
## clip by its own weight. body_hands.gd sets the targets every frame from the rig map's pose table.

var rig: Dictionary = {}
## Targets: arm direction (skeleton space) and weight; torso [pitch, yaw] and weight.
var arm_r := Vector3.FORWARD
var arm_r_w := 0.0
var arm_l := Vector3.FORWARD
var arm_l_w := 0.0
var torso := Vector2.ZERO
var torso_w := 0.0

var _idx := {}


func _bones(sk: Skeleton3D) -> bool:
	if _idx.is_empty() and not rig.is_empty():
		for key in (rig.bones as Dictionary).keys():
			_idx[key] = sk.find_bone(String(rig.bones[key]))
	return not _idx.is_empty() and int(_idx.get("torso", -1)) >= 0


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _bones(sk):
		return
	var ti: int = _idx.torso
	var tq := sk.get_bone_pose_rotation(ti)
	if torso_w > 0.001:
		var want := tq * Quaternion.from_euler(Vector3(torso.x, torso.y, 0.0))
		tq = tq.slerp(want, clampf(torso_w, 0.0, 1.0))
		sk.set_bone_pose_rotation(ti, tq)
	# The arms hang off the torso: express the skeleton-space direction in the torso's frame.
	var parent := sk.get_bone_parent(ti)
	var tb := Basis(tq)
	while parent >= 0:
		tb = Basis(sk.get_bone_pose_rotation(parent)) * tb
		parent = sk.get_bone_parent(parent)
	var inv := tb.inverse()
	for side in [["arm_r", arm_r, arm_r_w], ["arm_l", arm_l, arm_l_w]]:
		var w: float = side[2]
		var bi := int(_idx.get(side[0], -1))
		if w <= 0.001 or bi < 0:
			continue
		var rest: Vector3 = rig.arm_rest[side[0]]
		var dir: Vector3 = (inv * (side[1] as Vector3)).normalized()
		var target := Quaternion(rest.normalized(), dir)
		var aq := sk.get_bone_pose_rotation(bi)
		sk.set_bone_pose_rotation(bi, aq.slerp(target, clampf(w, 0.0, 1.0)))
