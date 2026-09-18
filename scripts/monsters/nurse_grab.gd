extends RefCounted
## The Night Nurse's grab (docs/CONTRACTS.md "The Night Nurse's grab"): the one timeline every machine
## plays from the moment she has someone by the neck, counted by Monster.grab_t.
##
##   0 .. REACH        her right arm snaps out and takes the surgeon by the throat
##   0 .. LIFT         the surgeon comes off the floor, up to her face (overshoots, settles)
##   .. SNAP_AT        she looks at them straight on; their camera is locked on her face
##   SNAP_AT + SNAP    her head snaps over to one side, cocked, considering (a crack)
##   DROP_AT           she lets go: the surgeon drops where they stood, downed, and she is gone
##
## Nothing hurts the surgeon until DROP_AT, and nothing else can touch them while she holds them.

const REACH := 0.08
const LIFT := 0.24
const SNAP_AT := 1.1
const SNAP := 0.07
const DROP_AT := 2.0
## The victim's throat sits this far below their eyes (C.EYE_H 1.7): her grip is on it.
const NECK_BELOW_EYES := 0.19
## How long after she vanishes before she hunts again.
const VANISH_CALM := 5.0
## Where she reappears: at least this far from every living surgeon, and out of everyone's light.
const VANISH_MIN := 22.0


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## 0..1: her arm out, her head turned straight on to the victim.
static func reach(t: float) -> float:
	if t < 0.0 or t >= DROP_AT:
		return 0.0
	return _smooth(t / REACH)


## 0..1+: how far the victim has come up off the floor; a jolt past 1, then it settles.
static func lift(t: float) -> float:
	if t < 0.0:
		return 0.0
	var u := clampf(t / LIFT, 0.0, 1.0)
	var e := 1.0 - pow(1.0 - u, 3.0)
	return e + 0.08 * sin(u * PI) * u


## 0..1+: her head cocked over; snaps in SNAP seconds with a small overshoot.
static func cock(t: float) -> float:
	if t < SNAP_AT or t >= DROP_AT:
		return 0.0
	var u := clampf((t - SNAP_AT) / SNAP, 0.0, 1.0)
	return u + 0.12 * sin(u * PI)
