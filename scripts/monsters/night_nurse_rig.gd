extends SkeletonModifier3D
## The Night Nurse's Blender-made model (`monster/night_nurse`, art/night_nurse/) on a monster model.
##
## `build(model)` spawns the GLB under the MonsterModel, points the model's `rig`, `skeleton` and
## `anim` at it and adds this modifier to its skeleton, plus a BoneAttachment3D named `Head` on the
## head bone (Monster.eye_transform and the lab's head shots look for it).
##
## Clips (Assets anims): Idle (4 s loop), Walk (1.6 s loop, in place, no root motion), Frozen (the
## still, wrong pose). The monster picks the clip and the rate (monster.gd `_update_visual`); this
## modifier adds the procedural poses there are no clips for, on top of whatever the clip left:
##
##   lunge   0..1  both arms reach forward and up, the head pushes out (the attack)
##   recoil  0..1  knocked back: torso and head thrown back, arms flung out (a dev gun knock-down)
##   slump   0..1  dead: head dropped, shoulders fallen, arms loose (the dev room's corpse)
##
## She is never sedated, dragged or strapped to a table (docs/SWEEP3.md: unfightable, no brain), so
## there is no lying or thrashing pose; `MonsterModel.make_lying` still gives her rest pose if asked.
##
## Every value is in skeleton space (+Y up, +Z her front, +X her left), so the numbers do not depend
## on how each bone's local axes were authored. Nothing runs while every value is zero.

const KEY := "monster/night_nurse"
## Ground speed at which the Walk clip's planted foot slides back exactly as fast as the body moves:
## measured from the clip's toe bones (the stance foot travels about 0.41 m in 0.4 s). Playback rate
## = speed / WALK_SPEED, so the feet do not skate at any speed.
const WALK_SPEED := 1.0
## Where the eyes sit in the head bone's frame (+Y up the head, +Z the face).
const EYE_OFFSET := Vector3(0.0, 0.134, 0.079)
## The toes dip about 4 cm under the floor through the Walk clip's stance; lifted this much while walking.
const WALK_LIFT := 0.035

var lunge := 0.0
var recoil := 0.0
var slump := 0.0

var _b := {}

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
		for n in ["Idle", "Walk"]:
			if ap.has_animation(n):
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var sk: Skeleton3D = skels[0]
	var head := BoneAttachment3D.new()
	head.name = "Head"
	head.bone_name = "head"
	sk.add_child(head)
	var poser = load("res://scripts/monsters/night_nurse_rig.gd").new()
	poser.name = "NursePoser"
	sk.add_child(poser)
	model.nurse = poser
	return true


func _bone(sk: Skeleton3D, n: String) -> int:
	if _b.is_empty():
		for i in sk.get_bone_count():
			_b[sk.get_bone_name(i)] = i
	return int(_b.get(n, -1))


## World position of a bone (after this frame's pose).
func bone_world(n: String) -> Vector3:
	var sk := get_skeleton()
	if sk == null:
		return Vector3.ZERO
	var i := _bone(sk, n)
	if i < 0:
		return sk.global_position
	return sk.global_transform * sk.get_bone_global_pose(i).origin


## Turn `bone` about a skeleton-space axis through its own head, on top of its current pose.
func _turn(sk: Skeleton3D, bone: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.0001:
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
	if lunge == 0.0 and recoil == 0.0 and slump == 0.0:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	var X := Vector3.RIGHT
	var Z := Vector3.BACK
	if slump > 0.0:
		var s := slump
		_turn(sk, "spine", X, 0.25 * s)
		_turn(sk, "neck", X, 0.5 * s)
		_turn(sk, "head", Z, 0.45 * s)
		_turn(sk, "shoulder.L", Z, -0.25 * s)
		_turn(sk, "shoulder.R", Z, 0.25 * s)
		_turn(sk, "forearm.L", X, 0.3 * s)
		_turn(sk, "forearm.R", X, 0.3 * s)
	if recoil > 0.0:
		var r := recoil
		_turn(sk, "spine", X, -0.35 * r)
		_turn(sk, "chest", X, -0.2 * r)
		_turn(sk, "head", X, -0.55 * r)
		_turn(sk, "upperarm.L", Z, 0.7 * r)
		_turn(sk, "upperarm.R", Z, -0.7 * r)
	if lunge > 0.0:
		var k := lunge
		# Hanging arms swing forward (toward +Z) and a little inward, as if to take hold.
		_turn(sk, "chest", X, 0.2 * k)
		_turn(sk, "upperarm.L", X, -1.25 * k)
		_turn(sk, "upperarm.R", X, -1.25 * k)
		_turn(sk, "upperarm.L", Z, -0.15 * k)
		_turn(sk, "upperarm.R", Z, 0.15 * k)
		_turn(sk, "forearm.L", X, -0.35 * k)
		_turn(sk, "forearm.R", X, -0.35 * k)
		_turn(sk, "head", X, -0.25 * k)
