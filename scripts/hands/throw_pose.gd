extends RefCounted
## THROW HOOK: the wind-up of a charged throw (hold the drop key, scripts/player.gd), shared by the
## first-person hands (fp_hands.gd) and the third-person body (body_hands.gd). Each driver owns one
## and feeds it Player.throw_wind every frame:
##   > 0   the drop key is held past the tap: the live 0..1 charge (1 = full)
##   < 0   a charged throw just fired (for Player.THROW_FOLLOW_TIME): the follow-through
##   0     nothing (a quick tap never winds up; a cancel lands here and eases back)
## The driver then poses: blend(blend(rest, windup, wind_w()), strike, strike_w()), plus jig() on the
## hands (non-zero only at full charge on a two-handed thing). `two` is latched while the pose plays,
## so throwing the last bulky thing still follows through with both hands.

## Seconds of the snap forward and the return to rest after a charged throw fires.
const FOLLOW_TIME := 0.34
## Share of FOLLOW_TIME spent snapping forward (the rest eases back to rest).
const SNAP := 0.3

var w := 0.0          # eased wind-up weight
var follow := -1.0    # 0..1 while the follow-through plays, -1 otherwise
var from_w := 0.0     # the wind-up weight the throw fired from
var shake := 0.0      # 0..1 tremble at full charge (two-handed)
var two := false
var _t := 0.0


## True while any part of the throw pose is showing.
func active() -> bool:
	return w > 0.002 or follow >= 0.0


func update(delta: float, wind: float, two_handed: bool) -> void:
	_t += delta
	if not active():
		two = two_handed
	if wind < 0.0:
		if follow < 0.0 and w > 0.02:
			follow = 0.0
			from_w = w
		w = 0.0
	elif wind > 0.0:
		follow = -1.0
		two = two_handed
	if follow >= 0.0:
		follow += delta / FOLLOW_TIME
		if follow >= 1.0:
			follow = -1.0
	if wind >= 0.0:
		# Ease in slowly with the charge; a snapshot step (remote, 20 Hz) or a cancel glides.
		var target := _smooth(clampf(wind, 0.0, 1.0))
		w = lerpf(w, target, clampf(delta * (9.0 if target > w else 6.0), 0.0, 1.0))
		if target <= 0.0 and w < 0.002:
			w = 0.0
	var want_shake := 1.0 if two and wind >= 0.99 else 0.0
	shake = move_toward(shake, want_shake, delta * (5.0 if want_shake > shake else 8.0))


## How far toward the wind-up pose.
func wind_w() -> float:
	if follow >= 0.0:
		return from_w * (1.0 - _ease_out(follow / SNAP)) if follow < SNAP else 0.0
	return w


## How far toward the strike pose (the snap forward, then back).
func strike_w() -> float:
	if follow < 0.0:
		return 0.0
	var k := clampf(from_w / 0.35, 0.0, 1.0)
	if follow < SNAP:
		return k * _ease_out(follow / SNAP)
	return k * (1.0 - _smooth((follow - SNAP) / (1.0 - SNAP)))


## A small noise-ish tremble (unit-ish amplitude times `shake`); `seed` decorrelates hands.
func jig(seed: float) -> Vector3:
	if shake <= 0.001:
		return Vector3.ZERO
	var t := _t + seed * 1.7
	return Vector3(sin(t * 67.0) + 0.5 * sin(t * 113.0 + 1.3),
		cos(t * 59.0) + 0.5 * sin(t * 97.0 + 2.1),
		sin(t * 71.0 + 0.7) * 0.6) * (shake / 1.5)


static func _smooth(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


static func _ease_out(u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	return 1.0 - (1.0 - u) * (1.0 - u)
