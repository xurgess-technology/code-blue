extends RefCounted
## First-person hand poses in camera space (metres, -Z into the view), tuned at BASE_FOV 78 (the
## driver scales x and y with the field of view). A pose is {p: palm position, f: fingers direction,
## n: out-of-the-palm direction, c: finger curl 0..1}. scripts/hands/fp_hands.gd blends them.

const WindupScript := preload("res://scripts/combat/windup.gd")

## Right hand, the torch in a fist, thumb up, pointing where you look.
const TORCH := {"p": Vector3(0.25, -0.255, -0.42), "f": Vector3(-0.1, 0.1, -1.0), "n": Vector3(-1.0, 0.1, -0.12), "c": 1.0}
## Right hand while both hands carry something: low and to the side, torch pressed to the forearm.
const TORCH_TUCKED := {"p": Vector3(0.3, -0.42, -0.26), "f": Vector3(-0.3, 0.2, -1.0), "n": Vector3(-1.0, 0.25, 0.0), "c": 1.0}
## Left hand: a stack lying on an open palm.
const LEFT_PALM := {"p": Vector3(-0.215, -0.25, -0.45), "f": Vector3(0.38, 0.12, -1.0), "n": Vector3(0.2, 1.0, 0.12), "c": 0.18}
## Left hand: a handle in a fist, thumb up.
const LEFT_FIST := {"p": Vector3(-0.215, -0.24, -0.44), "f": Vector3(0.22, 0.2, -1.0), "n": Vector3(1.0, 0.15, 0.1), "c": 1.0}
## Left hand with nothing in it: relaxed, mostly under the view.
const LEFT_EMPTY := {"p": Vector3(-0.25, -0.4, -0.33), "f": Vector3(0.35, 0.25, -1.0), "n": Vector3(0.7, 0.7, 0.0), "c": 0.45}

## Both hands on the sides of a big thing, relative to the carried thing's centre (x mirrored for the
## right hand, which adds the half width of the thing).
const BOTH_CENTRE := Vector3(0.0, -0.33, -0.56)
const BOTH_LEFT := {"p": Vector3(-0.012, -0.03, 0.03), "f": Vector3(0.12, 0.1, -1.0), "n": Vector3(1.0, 0.35, 0.0), "c": 0.65}


## Action keyframes: [pose at the wind-up peak, pose at the strike] for the hand(s) that move.
## Jab and saw move the left hand (it holds the stack); the shove moves both.
const JAB := [
	{"p": Vector3(-0.15, -0.2, -0.27), "f": Vector3(0.28, 0.3, -1.0), "n": Vector3(1.0, 0.25, 0.15), "c": 1.0},
	{"p": Vector3(-0.045, -0.12, -0.58), "f": Vector3(0.1, 0.06, -1.0), "n": Vector3(1.0, 0.1, 0.0), "c": 1.0},
]
const SAW := [
	{"p": Vector3(0.24, 0.03, -0.56), "f": Vector3(-0.5, 0.75, 0.45), "n": Vector3(0.3, 0.45, -1.0), "c": 1.0},
	{"p": Vector3(-0.16, -0.33, -0.5), "f": Vector3(-0.8, -0.6, -0.55), "n": Vector3(-0.2, 0.55, -1.0), "c": 1.0},
]
const SHOVE_LEFT := [
	{"p": Vector3(-0.16, -0.19, -0.38), "f": Vector3(0.25, 1.0, 0.15), "n": Vector3(0.15, 0.0, -1.0), "c": 0.1},
	{"p": Vector3(-0.15, -0.13, -0.66), "f": Vector3(0.15, 1.0, -0.1), "n": Vector3(0.1, 0.0, -1.0), "c": 0.05},
]

## THROW HOOK (scripts/hands/throw_pose.gd): [wind-up peak, release] for a one-handed throw (the left
## hand, which holds the stack): drawn up and back past the shoulder, palm and stack turned forward
## at the edge of the view, then flung out ahead.
const THROW_LEFT := [
	{"p": Vector3(-0.4, -0.05, -0.34), "f": Vector3(0.1, 1.0, 0.3), "n": Vector3(0.45, 0.2, -0.9), "c": 0.4},
	{"p": Vector3(-0.07, -0.13, -0.64), "f": Vector3(0.2, 0.25, -1.0), "n": Vector3(0.25, 0.95, -0.15), "c": 0.08},
]
## Two-handed throw: the thing's centre raised over the head (top of the view) and slightly back,
## then heaved out in front; the hands' own frames (left hand, mirrored for the right).
const THROW_BOTH_CENTRE := [Vector3(0.0, 0.2, -0.3), Vector3(0.0, -0.17, -0.74)]
const THROW_BOTH_LEFT := [
	{"p": Vector3(-0.012, -0.03, 0.03), "f": Vector3(0.1, 0.45, 0.9), "n": Vector3(1.0, 0.2, 0.0), "c": 0.7},
	{"p": Vector3(-0.012, -0.03, 0.03), "f": Vector3(0.12, -0.2, -1.0), "n": Vector3(1.0, 0.35, 0.0), "c": 0.35},
]


## Mirror a left-hand pose to the right hand.
static func mirror(pose: Dictionary) -> Dictionary:
	var p: Vector3 = pose.p
	var f: Vector3 = pose.f
	var n: Vector3 = pose.n
	return {"p": Vector3(-p.x, p.y, p.z), "f": Vector3(-f.x, f.y, f.z), "n": Vector3(-n.x, n.y, n.z), "c": pose.c}


## The pose's socket transform (grips.gd axes).
static func xform(pose: Dictionary) -> Transform3D:
	var z: Vector3 = -(pose.f as Vector3).normalized()
	var y: Vector3 = pose.n
	y = (y - z * y.dot(z)).normalized()
	return Transform3D(Basis(y.cross(z), y, z), pose.p)


static func blend(a: Dictionary, b: Dictionary, u: float) -> Dictionary:
	u = clampf(u, 0.0, 1.0)
	return {"p": (a.p as Vector3).lerp(b.p, u), "f": (a.f as Vector3).normalized().slerp((b.f as Vector3).normalized(), u),
		"n": (a.n as Vector3).normalized().slerp((b.n as Vector3).normalized(), u), "c": lerpf(float(a.c), float(b.c), u)}


static func smooth(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


## The pose of the hand an action moves, from its rest pose, given combat.action_of(). `keys` is the
## [wind-up, strike] pair. Wind-ups ease out (fast start), strikes snap then decelerate all the way
## to rest so the hand arrives at the strike pose with no leftover velocity (its `sqrt` used to still
## be moving at u=1, which popped into RECOVER's zero-velocity start), recoveries ease back.
static func action_pose(rest: Dictionary, keys: Array, act: Dictionary) -> Dictionary:
	var ph := int(act.ph)
	var u := float(act.u)
	match ph:
		WindupScript.WINDUP:
			return blend(rest, keys[0], 1.0 - pow(1.0 - clampf(u, 0.0, 1.0), 2.2))
		WindupScript.STRIKE:
			return blend(keys[0], keys[1], 1.0 - pow(1.0 - clampf(u, 0.0, 1.0), 2.0))
	return blend(keys[1], rest, smooth(u))
