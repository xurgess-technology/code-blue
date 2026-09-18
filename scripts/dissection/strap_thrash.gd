extends SkeletonModifier3D
## A strapped rig monster straining against its straps. Runs after the monster's RigShaper (added as
## the skeleton's last child), on top of the flattened lying pose: the arms and legs lift off the
## table from the shoulder and the hip, the arms pull outward, the fingers' attachments follow the
## bones. monster_builder.gd's animate() sets the values every frame (radians, 0 = lying still).

var arm_l := 0.0
var arm_r := 0.0
var legs := 0.0
## The limbs it moves: left arm, right arm, left leg, right leg (the Kenney rig's by default).
var bones := PackedStringArray(["arm-left", "arm-right", "leg-left", "leg-right"])
## Turn about the skeleton's own axes (+X its left, +Z its front) instead of each bone's parent frame:
## the human skeleton (the Hive), whose parent bones are not lined up with the body.
var skeleton_axes := false

var _idx := PackedInt32Array()


func _process_modification_with_delta(_delta: float) -> void:
	if arm_l == 0.0 and arm_r == 0.0 and legs == 0.0:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	if _idx.is_empty():
		for bn in bones:
			_idx.append(sk.find_bone(bn))
	if skeleton_axes:
		_human(sk)
		return
	# In the torso's frame a negative turn about X swings a hanging limb toward the front: off the
	# table, for a body lying on its back. Z turns an arm out to its side.
	for i in 2:
		var bi := _idx[i]
		if bi < 0:
			continue
		var a := arm_l if i == 0 else arm_r
		var side := 1.0 if i == 0 else -1.0
		var q := Quaternion(Vector3.RIGHT, -a) * Quaternion(Vector3.BACK, side * a * 0.35)
		sk.set_bone_pose_rotation(bi, q * sk.get_bone_pose_rotation(bi))
	for i in range(2, 4):
		var bi := _idx[i]
		if bi < 0:
			continue
		var k := 1.0 if i == 2 else 0.8
		sk.set_bone_pose_rotation(bi, Quaternion(Vector3.RIGHT, -legs * k) * sk.get_bone_pose_rotation(bi))


## The human skeleton: a negative turn about the skeleton's X swings a hanging limb toward its front
## (off the table, lying on its back); about Z an arm swings out to its side.
func _human(sk: Skeleton3D) -> void:
	for i in 4:
		var bi := _idx[i]
		if bi < 0:
			continue
		var side := 1.0 if i % 2 == 0 else -1.0
		if i < 2:
			var a := arm_l if i == 0 else arm_r
			_turn(sk, bi, Vector3.RIGHT, -a)
			_turn(sk, bi, Vector3.BACK, side * a * 0.35)
		else:
			_turn(sk, bi, Vector3.RIGHT, -legs * (1.0 if i == 2 else 0.8))


func _turn(sk: Skeleton3D, i: int, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.0001:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var g := pg * Basis(sk.get_bone_pose_rotation(i))
	sk.set_bone_pose_rotation(i, (pg.inverse() * (Basis(axis, angle) * g)).get_rotation_quaternion())
