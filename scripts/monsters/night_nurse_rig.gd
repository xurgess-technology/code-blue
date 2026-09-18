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
##   sit     0..1  seated upright, hands in her lap (the hub's waiting room; no clip plays)
##   hold    0..1  right hand raised in front of her chest, as if holding a page up to read (the
##                 hub pharmacy's attendant reading a fax; `bone_world("hand.R")` is where it is)
##   grab    0..1  the grab (nurse_grab.gd): she straightens all the way up out of her hunch, both
##                 hands round a throat held close in front of her face, elbows bowed out, her head
##                 turned straight on to whoever she holds; `grip_world` is the throat
##   cock    0..1+ on top of grab: her head snapped over to one side, considering them
##
## She is never sedated, dragged or strapped to a table (docs/SWEEP3.md: unfightable, no brain), so
## there is no lying or thrashing pose; `MonsterModel.make_lying` still gives her rest pose if asked.
##
## Every value is in skeleton space (+Y up, +Z her front, +X her left), so the numbers do not depend
## on how each bone's local axes were authored. Nothing runs while every value is zero.

const KEY := "monster/night_nurse"
const NurseGrabScript := preload("res://scripts/monsters/nurse_grab.gd")
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
var sit := 0.0
var hold := 0.0
var grab := 0.0
var cock := 0.0
## World position of her grip (the throat she holds) as last posed with `grab`; ZERO when not grabbing.
var grip_world := Vector3.ZERO
## Her wrists as last posed with `grab` (world), right then left: the lab checks they close on the neck.
var grab_wrists: Array = [Vector3.ZERO, Vector3.ZERO]
## World position of her right hand as last posed with `hold` (what the page is pinned to).
var held_hand_world := Vector3.ZERO

## Where she holds the throat, from her eyes (skeleton space): this far in front of her face, the
## victim's neck NurseGrab.NECK_BELOW_EYES below her eyes so their eyes are level with hers.
const GRAB_REACH := 0.52
## Which way her grabbing elbows bow (the right one; the left mirrors): down and out, sharp and wrong.
const GRAB_POLE := Vector3(-0.8, -0.6, 0.0)
## Her hands round the victim's neck (skeleton space, from the neck's centre): each wrist this far to
## its side and this far in front, the hand running back along the side of the neck, the fingers
## curled round behind it. The neck's centre is NECK_DEPTH past the throat she holds.
const WRAP_SIDE := 0.085
const WRAP_FRONT := 0.075
const NECK_DEPTH := 0.07
## How far each finger joint closes round the neck (radians; bone-local X, the hinge).
const CURL := [0.6, 0.8, 0.6]
## How far her head rolls over when it cocks (radians), and the little tip forward with it.
const COCK_ROLL := 0.62
const COCK_TIP := 0.12

## Seated, her hips come down by about a thigh's length (hip 1.12 m, knee 0.62 m standing): the model
## is lowered this much so her feet stay on the floor.
const SIT_DROP := 0.5

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


## Swing `bone` so it points along `dir` (skeleton space), blended by `w`, keeping its roll.
func _point(sk: Skeleton3D, bone: String, dir: Vector3, w: float) -> void:
	var i := _bone(sk, bone)
	if i < 0 or w <= 0.0:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var g := (pg * Basis(sk.get_bone_pose_rotation(i))).orthonormalized()
	var want := (Basis(Quaternion(g.y.normalized(), dir.normalized())) * g).orthonormalized()
	var q := g.get_rotation_quaternion().slerp(want.get_rotation_quaternion(), clampf(w, 0.0, 1.0))
	sk.set_bone_pose_rotation(i, (pg.inverse() * Basis(q)).get_rotation_quaternion())


## Turn the head to face `at` (skeleton space) upright, blended by `w`, then roll it over by `c`.
func _face(sk: Skeleton3D, at: Vector3, w: float, c: float) -> void:
	var i := _bone(sk, "head")
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var g := (pg * Basis(sk.get_bone_pose_rotation(i))).orthonormalized()
	var z := at - sk.get_bone_global_pose(i).origin
	if z.length() < 0.01:
		return
	z = z.normalized()
	var x := Vector3.UP.cross(z).normalized()
	var want := Basis(x, z.cross(x), z)
	# Her right ear drops toward her right shoulder: a roll about the way she faces.
	want = Basis(z, -COCK_ROLL * c) * Basis(x, COCK_TIP * c) * want
	var q := g.get_rotation_quaternion().slerp(want.orthonormalized().get_rotation_quaternion(), clampf(w, 0.0, 1.0))
	sk.set_bone_pose_rotation(i, (pg.inverse() * Basis(q)).get_rotation_quaternion())


## Two-bone reach (law of cosines): `upper` and `lower` bend so the `hand` bone's head (the wrist)
## lands on `wrist` (skeleton space) with the hand pointing along `hand_dir`; the elbow bows toward `pole`.
func _reach(sk: Skeleton3D, upper: String, lower: String, hand: String, wrist: Vector3, hand_dir: Vector3, pole: Vector3, w: float) -> void:
	var ui := _bone(sk, upper)
	var li := _bone(sk, lower)
	var hi := _bone(sk, hand)
	if ui < 0 or li < 0 or hi < 0:
		return
	var s := sk.get_bone_global_pose(ui).origin
	var a := s.distance_to(sk.get_bone_global_pose(li).origin)
	var b := sk.get_bone_global_pose(li).origin.distance_to(sk.get_bone_global_pose(hi).origin)
	var to := wrist - s
	var d := clampf(to.length(), absf(a - b) + 0.01, a + b - 0.001)
	var dir := to.normalized()
	var cos_a := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var side := pole - dir * pole.dot(dir)
	side = side.normalized() if side.length() > 0.001 else Vector3.DOWN
	var elbow := s + dir * (a * cos_a) + side * (a * sqrt(1.0 - cos_a * cos_a))
	_point(sk, upper, elbow - s, w)
	_point(sk, lower, s + dir * d - elbow, w)
	_point(sk, hand, hand_dir.normalized(), w)


## Curl a finger joint about its own hinge (bone-local X), on top of the clip.
func _curl(sk: Skeleton3D, bone: String, angle: float) -> void:
	var i := _bone(sk, bone)
	if i < 0:
		return
	sk.set_bone_pose_rotation(i, sk.get_bone_pose_rotation(i) * Quaternion(Vector3.RIGHT, angle))


func _process_modification_with_delta(_delta: float) -> void:
	if lunge == 0.0 and recoil == 0.0 and slump == 0.0 and sit == 0.0 and hold == 0.0 and grab == 0.0:
		grip_world = Vector3.ZERO
		return
	var sk := get_skeleton()
	if sk == null:
		return
	var X := Vector3.RIGHT
	var Z := Vector3.BACK
	if hold > 0.0:
		var h := hold
		# The upper arm forward and a little in, the forearm folded up so the hand is at chest height.
		_turn(sk, "upperarm.R", X, -0.45 * h)
		_turn(sk, "upperarm.R", Z, 0.25 * h)
		_turn(sk, "forearm.R", X, -1.05 * h)
		_turn(sk, "hand.R", X, 0.2 * h)
		_turn(sk, "head", X, 0.25 * h)
		# Recorded here, after the pose: outside the modifier the skeleton reads back the clip's pose.
		held_hand_world = bone_world("hand.R")
	if sit > 0.0:
		var s := sit
		# Thighs forward to level, shins back down, a slight lean; forearms laid across the lap.
		_turn(sk, "thigh.L", X, -1.52 * s)
		_turn(sk, "thigh.R", X, -1.52 * s)
		_turn(sk, "shin.L", X, 1.45 * s)
		_turn(sk, "shin.R", X, 1.45 * s)
		_turn(sk, "foot.L", X, 0.05 * s)
		_turn(sk, "foot.R", X, 0.05 * s)
		_turn(sk, "spine", X, 0.06 * s)
		_turn(sk, "upperarm.L", X, -0.35 * s)
		_turn(sk, "upperarm.R", X, -0.35 * s)
		_turn(sk, "forearm.L", X, -1.0 * s)
		_turn(sk, "forearm.R", X, -1.0 * s)
		_turn(sk, "forearm.L", Vector3.UP, -0.35 * s)
		_turn(sk, "forearm.R", Vector3.UP, 0.35 * s)
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
	if grab > 0.0:
		var gk := minf(grab, 1.0)
		# All the way up, to her full height: legs locked straight under her, the hunch gone out of
		# her, hips to neck straight.
		_point(sk, "hips", Vector3.UP, gk)
		for sd in [".L", ".R"]:
			_point(sk, "thigh" + sd, Vector3.DOWN, gk)
			_point(sk, "shin" + sd, Vector3.DOWN, gk)
		for b in ["spine", "chest", "upperchest", "neck"]:
			_point(sk, b, Vector3.UP, gk)
		# Both hands round a throat held close in front of her face (two-bone reaches).
		var hbi := _bone(sk, "head")
		var head_at := sk.get_bone_global_pose(hbi).origin if hbi >= 0 else Vector3(0.0, 1.99, 0.0)
		var eye_at := head_at + Vector3(0.0, EYE_OFFSET.y, EYE_OFFSET.z)
		var grip := Vector3(0.0, eye_at.y - NurseGrabScript.NECK_BELOW_EYES, eye_at.z + GRAB_REACH)
		# Each hand along one side of the neck, fingers round the back of it, thumbs on the throat.
		var neck := grip + Vector3(0.0, 0.0, NECK_DEPTH)
		for side in [["R", -1.0], ["L", 1.0]]:
			var sd: String = side[0]
			var sx: float = side[1]
			var wrist := neck + Vector3(sx * WRAP_SIDE, 0.0, -WRAP_FRONT)
			var along := Vector3(-sx * 0.35, 0.0, 1.0)   # back along the neck, turning in round it
			_reach(sk, "upperarm." + sd, "forearm." + sd, "hand." + sd, wrist, along, GRAB_POLE * Vector3(-sx, 1.0, 1.0), gk)
			for f in ["index", "middle", "ring", "pinky"]:
				_curl(sk, f + "1." + sd, CURL[0] * gk)
				_curl(sk, f + "2." + sd, CURL[1] * gk)
				_curl(sk, f + "3." + sd, CURL[2] * gk)
			_curl(sk, "thumb2." + sd, 0.4 * gk)
			var wi := _bone(sk, "hand." + sd)
			if wi >= 0:
				grab_wrists[0 if sd == "R" else 1] = sk.global_transform * sk.get_bone_global_pose(wi).origin
		# Straight on to the face above her grip, then the snap.
		_face(sk, grip + Vector3.UP * NurseGrabScript.NECK_BELOW_EYES, gk, cock)
		# Recorded here, after the pose: outside the modifier the skeleton reads back the clip's pose.
		grip_world = sk.global_transform * grip
	else:
		grip_world = Vector3.ZERO
