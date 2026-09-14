extends RefCounted
## The one place that knows the player body rig (docs/CONTRACTS.md "Player: hands", the rig seam).
##
## Today the body is the Kenney mini character `char/surgeon`: seven bones (root, leg-left,
## leg-right, torso, arm-left, arm-right, head), no hand bones, arms straight out along X in the
## rest pose, the character facing +Z in skeleton space. Its arm is one bone with the mitten at the
## end, so a "hand" is a point near the end of the arm bone.
##
## Swapping in another rig (the shared Blender human) is a data change: add an entry to RIGS with
## that rig's bone names, hand sockets and rest directions, and have `detect()` pick it. The poses
## below are written as directions in skeleton space (+Z forward, +Y up, the body's right is -X),
## so they carry over to any rig whose arm bones can be pointed.

const KENNEY := {
	"name": "kenney",
	"bones": {"torso": "torso", "head": "head", "arm_r": "arm-right", "arm_l": "arm-left"},
	# Direction each arm bone points in its rest pose, in its parent's (torso) space.
	"arm_rest": {"arm_r": Vector3(-1, 0, 0), "arm_l": Vector3(1, 0, 0)},
	# The hand socket in the arm bone's space, in skeleton units (the mitten's palm, near the tip).
	# Socket axes as in scripts/hands/grips.gd: -Z fingers, +Y out of the palm, +X the hand's right.
	# With the arm along the bone's -X (right) / +X (left): fingers continue along the arm, the palm
	# faces up in the rest pose.
	"hand": {
		"arm_r": {"offset": Vector3(-0.245, 0.0, 0.0), "fingers": Vector3(-1, 0, 0), "palm": Vector3(0, 0, 1)},
		"arm_l": {"offset": Vector3(0.245, 0.0, 0.0), "fingers": Vector3(1, 0, 0), "palm": Vector3(0, 0, 1)},
	},
	# Animation clips the body plays underneath the pose overrides.
	"clips": {"idle": "idle", "walk": "walk", "run": "sprint"},
	# Metres per skeleton unit after Assets.spawn (surgeon.glb is scaled 2.687).
	"scale": 2.687,
}

const RIGS := [KENNEY]


## Which rig a spawned body uses (by its bone names), or {} for a body without a rig.
static func detect(skeleton: Skeleton3D) -> Dictionary:
	if skeleton == null:
		return {}
	for rig in RIGS:
		var ok := true
		for b in (rig.bones as Dictionary).values():
			if skeleton.find_bone(String(b)) < 0:
				ok = false
				break
		if ok:
			return rig
	return {}


## Pose table: arm directions (skeleton space, normalised when used), torso lean / twist (radians;
## +pitch leans forward, +yaw turns the chest toward the body's left) and how much each part
## overrides the animation (0..1). Poses blend with each other (see body_hands.gd).
const POSES := {
	"none": {},
	# One-handed carry: the right forearm raised in front, the thing held forward.
	"hold": {"arm_r": [Vector3(-0.28, -0.3, 0.91), 1.0]},
	# Bulky loot and the guide: both arms forward, hands on its sides.
	"hold_both": {"arm_r": [Vector3(-0.12, -0.42, 0.9), 1.0], "arm_l": [Vector3(0.12, -0.42, 0.9), 1.0]},
	# A fireman's carry on the right shoulder: the right arm up over the legs in front.
	"carry": {"arm_r": [Vector3(-0.35, 0.72, 0.6), 1.0], "torso": [0.08, 0.0, 1.0]},
	# Dragging a monster by the ankles behind: the right arm reaches back and down.
	"drag": {"arm_r": [Vector3(-0.3, -0.75, -0.58), 1.0], "torso": [0.18, 0.0, 1.0]},
	# Saw: raised high on the right, then chopped down across the front.
	"saw_windup": {"arm_r": [Vector3(-0.42, 0.86, -0.3), 1.0], "arm_l": [Vector3(0.55, -0.2, 0.8), 0.6], "torso": [-0.12, -0.3, 1.0]},
	"saw_strike": {"arm_r": [Vector3(0.25, -0.55, 0.8), 1.0], "torso": [0.25, 0.25, 1.0]},
	# Jab: syringe drawn back at the hip, thumb on the plunger, then a straight thrust.
	"jab_windup": {"arm_r": [Vector3(-0.45, -0.35, -0.82), 1.0], "torso": [-0.05, -0.28, 1.0]},
	"jab_strike": {"arm_r": [Vector3(-0.05, 0.02, 1.0), 1.0], "torso": [0.2, 0.18, 1.0]},
	# Shove: charging leans back with both arms braced up in front, the strike throws both forward.
	"shove_charge": {"arm_r": [Vector3(-0.45, 0.25, 0.86), 1.0], "arm_l": [Vector3(0.45, 0.25, 0.86), 1.0], "torso": [-0.32, 0.0, 1.0]},
	"shove_strike": {"arm_r": [Vector3(-0.2, 0.05, 1.0), 1.0], "arm_l": [Vector3(0.2, 0.05, 1.0), 1.0], "torso": [0.38, 0.0, 1.0]},
}
