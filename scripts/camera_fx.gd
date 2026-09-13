class_name CameraFX
extends Node3D
## Owns all camera feel. Sits between the player body and the Camera3D.
##
## This node reads no input and knows nothing about the game. The player script
## drives it every frame. It never touches its own transform, only the child
## camera's, so the player is free to rotate CameraFX for mouse pitch without
## fighting it.
##
## Wiring:
## [codeblock]
## var fx := CameraFX.new()
## fx.name = "CameraFX"
## fx.position = Vector3(0, C.EYE_H, 0)
## add_child(fx)
## var cam := Camera3D.new()
## cam.name = "Camera"          # required name
## fx.add_child(cam)
## # then, each frame, from the player:
## fx.set_motion(vel_planar.length() / C.SPRINT_SPEED, sprinting, is_on_floor(), strafe)
## [/codeblock]
##
## Everything is exponentially damped with a per-second rate, so behaviour is
## identical at 30 and 300 fps, and every channel settles to exactly zero when
## its driver stops (no slow drift off-centre).

## Name of the Camera3D child this node drives.
const CAMERA_NODE_NAME := "Camera"

# --- head bob -------------------------------------------------------------
## Horizontal half-amplitude of the figure-eight at full walk speed, in metres.
@export var bob_amount_h := 0.045
## Vertical half-amplitude. Vertical runs at 2x the horizontal frequency; that
## 1:2 Lissajous is what makes it a figure-eight rather than a wobble.
@export var bob_amount_v := 0.055
## Radians per second of bob phase at full speed.
@export var bob_rate := 8.2
## Multiplier applied to amplitude and rate while sprinting.
@export var bob_sprint_amp := 1.45
@export var bob_sprint_rate := 1.25
## Tiny counter-rotation so the head tips with the step, not just slides.
@export var bob_pitch := 0.010

# --- strafe roll ----------------------------------------------------------
@export var strafe_roll := 0.035       ## radians at full sideways speed
@export var strafe_roll_rate := 6.0

# --- landing --------------------------------------------------------------
@export var land_dip := 0.16           ## metres at force 1.0
@export var land_stiffness := 120.0    ## spring k
@export var land_damping := 15.0       ## spring c
@export var land_pitch := 0.09         ## radians of nose-down at force 1.0

# --- shake ----------------------------------------------------------------
## Trauma is what callers add; the applied shake is trauma squared, which is
## what makes small shakes feel small and big ones feel violent.
@export var shake_pos_max := 0.22      ## metres at trauma 1
@export var shake_rot_max := 0.10      ## radians at trauma 1
@export var shake_freq := 22.0         ## noise samples per second
@export var shake_decay_default := 2.5 ## trauma units per second

# --- fov ------------------------------------------------------------------
@export var fov_kick_max := 12.0       ## degrees added at amount 1.0
@export var fov_rate := 7.0

# --- breathing ------------------------------------------------------------
@export var breath_amp := 0.016        ## metres of sway at calm
@export var breath_rot := 0.008        ## radians
@export var breath_rate_calm := 0.26   ## Hz
@export var breath_rate_afraid := 1.35 ## Hz
## Fear makes breathing faster but shallower; this is the amplitude scale at
## intensity 1.0.
@export var breath_shallow := 0.40

# --- recoil / impact ------------------------------------------------------
@export var recoil_pos := 0.10
@export var recoil_rot := 0.09
@export var recoil_return := 9.0       ## spring-back rate
@export var recoil_settle := 14.0

# --- lean -----------------------------------------------------------------
@export var lean_offset := 0.40        ## metres sideways at amount 1.0
@export var lean_roll := 0.22          ## radians
@export var lean_rate := 8.0

## Below this, a channel is snapped to exactly zero so nothing can drift.
const EPSILON := 0.00008

var camera: Camera3D

var _base_pos := Vector3.ZERO
var _base_rot := Vector3.ZERO
var _base_fov := 75.0

# motion state
var _speed01 := 0.0
var _sprint01 := 0.0
var _grounded := true
var _strafe := 0.0
var _strafe_s := 0.0
var _bob_phase := 0.0
var _bob_amp := 0.0          ## smoothed, so bob fades in/out instead of popping

# landing spring
var _land_y := 0.0
var _land_v := 0.0
var _land_force := 0.0

# shake
var _trauma := 0.0
var _trauma_decay := 2.5
var _shake_t := 0.0
var _noise: FastNoiseLite

# fov
var _fov_target := 0.0
var _fov_cur := 0.0

# breathing
var _breath := 0.0
var _breath_target := 0.0
var _breath_phase := 0.0

# recoil / impact (a critically-damped-ish spring in local space)
var _recoil_p := Vector3.ZERO
var _recoil_pv := Vector3.ZERO
var _recoil_r := Vector3.ZERO
var _recoil_rv := Vector3.ZERO

# lean
var _lean_target := 0.0
var _lean := 0.0


func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	# Per-instance seed: two players' cameras should not shake in lockstep.
	_noise.seed = int(randi())
	_resolve_camera()
	set_process(true)


func _resolve_camera() -> void:
	if camera != null and is_instance_valid(camera):
		return
	camera = get_node_or_null(NodePath(CAMERA_NODE_NAME)) as Camera3D
	if camera == null:
		# Fall back to the first Camera3D child, so a differently-named camera
		# still works rather than silently doing nothing.
		for c in get_children():
			if c is Camera3D:
				camera = c
				break
	if camera != null:
		_base_pos = camera.position
		_base_rot = camera.rotation
		_base_fov = camera.fov


## Call if you swap the camera or change its resting transform.
func rebind_camera() -> void:
	camera = null
	_resolve_camera()


# ---------------------------------------------------------------------------
# Drivers — called by the player script
# ---------------------------------------------------------------------------

## [param speed01] 0..1 planar speed (velocity.length() / C.SPRINT_SPEED).
## [param sprinting] whether the sprint input is held and effective.
## [param grounded] false in the air: bob stops, nothing else changes.
## [param strafe] -1..1 signed sideways velocity, for the roll. Optional so the
## three-argument form in the spec still works.
func set_motion(speed01: float, sprinting: bool, grounded: bool, strafe := 0.0) -> void:
	_speed01 = clampf(speed01, 0.0, 1.0)
	_sprint01 = 1.0 if sprinting else 0.0
	_grounded = grounded
	_strafe = clampf(strafe, -1.0, 1.0)


## Landing dip. [param force] 0..1+, usually fall_speed / terminal_speed.
func land(force: float) -> void:
	force = clampf(force, 0.0, 2.0)
	if force <= 0.001:
		return
	_land_force = maxf(_land_force, force)
	# Kick the spring's velocity rather than its position: that gives a fast
	# compress and a slower rebound, which is what a real knee does.
	_land_v -= land_dip * force * land_stiffness * 0.05
	# Hard landings also shake a little.
	if force > 0.5:
		add_shake((force - 0.5) * 0.5, 0.3)


## Trauma-based shake. [param amount] 0..1 adds to current trauma.
## [param duration] roughly how long this shake should take to die out.
func add_shake(amount: float, duration := 0.4) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if amount <= 0.0:
		return
	_trauma = clampf(_trauma + amount, 0.0, 1.0)
	# A longer-duration shake wins: slow the decay, never speed it up, or a
	# small quick shake would cut a big slow one short.
	_trauma_decay = minf(_trauma_decay, 1.0 / maxf(0.05, duration))


## Sprint FOV widening. [param amount] 0..1. Smoothed; safe every frame.
func set_fov_kick(amount: float) -> void:
	_fov_target = clampf(amount, 0.0, 1.0)


## Idle sway. [param intensity] 0 = off (fully settles), 0.2-0.3 = calm idle
## breathing, 1 = terrified: fast and shallow.
func set_breathing(intensity: float) -> void:
	_breath_target = clampf(intensity, 0.0, 1.0)


## Directional kick, e.g. a tool recoiling or a shove landing.
## [param dir] is in this node's local space; magnitude scales the kick.
## +Z is backwards (toward the player), so a forward punch is Vector3(0,0,1).
func recoil(dir: Vector3) -> void:
	var m := dir.length()
	if m <= 0.0001:
		return
	var n := dir / m
	m = minf(m, 2.0)
	_recoil_pv += n * recoil_pos * m * recoil_return
	# Push back -> pitch up, push sideways -> yaw and roll away.
	_recoil_rv += Vector3(n.z, -n.x, -n.x * 0.6) * recoil_rot * m * recoil_return
	add_shake(0.12 * m, 0.25)


## Hit reaction. By default [param from] is the attacker's WORLD POSITION (pass
## monster.global_position) and the camera is knocked away from it.
##
## Pass [code]is_direction = true[/code] if you already have a world-space
## direction pointing from the attacker toward the player — for example
## [code]fx.impact(-global_transform.basis.z, true)[/code] for "hit from the
## front". Passing a direction without the flag is silently wrong: it would be
## read as a point a metre from the world origin.
func impact(from: Vector3, is_direction := false) -> void:
	if is_direction:
		if from.length_squared() < 0.0001:
			recoil(Vector3(0, 0, 1))
			return
		# The direction points from the attacker to us, so we get pushed along it.
		var l := global_transform.basis.inverse() * from.normalized()
		recoil(l * 1.2)
		add_shake(0.45, 0.5)
		return
	var to_self := global_position - from
	to_self.y = 0.0
	if to_self.length_squared() < 0.0001:
		recoil(Vector3(0, 0, 1))
		return
	var local := global_transform.basis.inverse() * to_self.normalized()
	# Knocked away from the source.
	recoil(local * 1.2)
	add_shake(0.45, 0.5)


## Peek around a corner. [param amount] -1 (left) .. 1 (right).
func set_lean(amount: float) -> void:
	_lean_target = clampf(amount, -1.0, 1.0)


## Immediately zero every channel. Use on respawn / teleport so the camera does
## not spring across the map.
func reset() -> void:
	_speed01 = 0.0
	_sprint01 = 0.0
	_strafe = 0.0
	_strafe_s = 0.0
	_bob_phase = 0.0
	_bob_amp = 0.0
	_land_y = 0.0
	_land_v = 0.0
	_land_force = 0.0
	_trauma = 0.0
	_shake_t = 0.0
	_fov_target = 0.0
	_fov_cur = 0.0
	_breath = 0.0
	_breath_target = 0.0
	_breath_phase = 0.0
	_recoil_p = Vector3.ZERO
	_recoil_pv = Vector3.ZERO
	_recoil_r = Vector3.ZERO
	_recoil_rv = Vector3.ZERO
	_lean = 0.0
	_lean_target = 0.0
	if camera != null:
		camera.position = _base_pos
		camera.rotation = _base_rot
		camera.fov = _base_fov


## Current shake magnitude, 0..1. Useful for driving screen post in sympathy.
func get_trauma() -> float:
	return _trauma


# ---------------------------------------------------------------------------
# Integration
# ---------------------------------------------------------------------------

static func _damp(cur: float, target: float, rate: float, delta: float) -> float:
	# Frame-rate independent exponential approach.
	return lerpf(cur, target, 1.0 - exp(-rate * delta))


static func _dz(v: float) -> float:
	return 0.0 if absf(v) < EPSILON else v


func _process(delta: float) -> void:
	if camera == null or not is_instance_valid(camera):
		_resolve_camera()
		if camera == null:
			return
	delta = minf(delta, 0.1)   # a hitch must not launch the springs

	var pos := Vector3.ZERO
	var rot := Vector3.ZERO

	pos += _tick_bob(delta)
	rot += _bob_rot
	rot.z += _tick_strafe_roll(delta)
	pos.y += _tick_land(delta)
	rot.x += _land_rot
	var sh := _tick_shake(delta)
	pos += sh[0]
	rot += sh[1]
	var br := _tick_breath(delta)
	pos += br[0]
	rot += br[1]
	var rc := _tick_recoil(delta)
	pos += rc[0]
	rot += rc[1]
	var ln := _tick_lean(delta)
	pos += ln[0]
	rot += ln[1]

	camera.position = _base_pos + pos
	camera.rotation = _base_rot + rot

	_fov_cur = _damp(_fov_cur, _fov_target, fov_rate, delta)
	_fov_cur = _dz(_fov_cur)
	camera.fov = _base_fov + _fov_cur * fov_kick_max


var _bob_rot := Vector3.ZERO

func _tick_bob(delta: float) -> Vector3:
	# Target amplitude: zero in the air, zero standing still.
	var want := _speed01 if _grounded else 0.0
	var amp_mul := lerpf(1.0, bob_sprint_amp, _sprint01)
	var target_amp := want * amp_mul
	# Fade in faster than out; stopping should coast to a halt.
	var rate := 9.0 if target_amp > _bob_amp else 5.0
	_bob_amp = _damp(_bob_amp, target_amp, rate, delta)

	if _bob_amp < EPSILON:
		_bob_amp = 0.0
		_bob_rot = Vector3.ZERO
		# Reset the phase so the next step starts from a neutral pose rather
		# than mid-stride.
		_bob_phase = 0.0
		return Vector3.ZERO

	var rate_mul := lerpf(1.0, bob_sprint_rate, _sprint01)
	# Phase advances with actual speed: slow walking gives slow steps.
	_bob_phase += delta * bob_rate * rate_mul * maxf(_speed01, 0.15)
	_bob_phase = fmod(_bob_phase, TAU)

	var x := sin(_bob_phase) * bob_amount_h * _bob_amp
	# 2x frequency on the vertical axis -> figure eight.
	var y := sin(_bob_phase * 2.0) * bob_amount_v * _bob_amp
	_bob_rot = Vector3(cos(_bob_phase * 2.0) * bob_pitch * _bob_amp, 0.0, 0.0)
	return Vector3(_dz(x), _dz(y), 0.0)


func _tick_strafe_roll(delta: float) -> float:
	_strafe_s = _damp(_strafe_s, _strafe * _speed01, strafe_roll_rate, delta)
	_strafe_s = _dz(_strafe_s)
	# Roll *into* the turn: strafing right drops the right side.
	return -_strafe_s * strafe_roll


var _land_rot := 0.0

func _tick_land(delta: float) -> float:
	if absf(_land_y) < EPSILON and absf(_land_v) < EPSILON:
		_land_y = 0.0
		_land_v = 0.0
		_land_force = 0.0
		_land_rot = 0.0
		return 0.0
	# Damped spring back to 0. Semi-implicit Euler with a clamped step so a
	# frame spike cannot make it explode.
	var steps := maxi(1, int(ceil(delta / 0.008)))
	var h := delta / float(steps)
	for _i in steps:
		var a := -land_stiffness * _land_y - land_damping * _land_v
		_land_v += a * h
		_land_y += _land_v * h
	_land_rot = -_land_y * (land_pitch / maxf(land_dip, 0.001)) * 0.5
	return _dz(_land_y)


func _tick_shake(delta: float) -> Array:
	if _trauma <= 0.0:
		_trauma = 0.0
		_trauma_decay = shake_decay_default
		return [Vector3.ZERO, Vector3.ZERO]

	_trauma = maxf(0.0, _trauma - _trauma_decay * delta)
	if _trauma < EPSILON:
		_trauma = 0.0
		_trauma_decay = shake_decay_default
		return [Vector3.ZERO, Vector3.ZERO]

	_shake_t += delta * shake_freq
	# Trauma squared: the classic curve. Linear trauma makes every shake feel
	# like the same shake at different volumes; squared has a real shape.
	var s := _trauma * _trauma

	# Six decorrelated noise channels, from six well-separated rows.
	var p := Vector3(
		_noise.get_noise_2d(_shake_t, 0.0),
		_noise.get_noise_2d(_shake_t, 137.0),
		_noise.get_noise_2d(_shake_t, 311.0)
	) * shake_pos_max * s
	var r := Vector3(
		_noise.get_noise_2d(_shake_t, 523.0),
		_noise.get_noise_2d(_shake_t, 719.0),
		_noise.get_noise_2d(_shake_t, 911.0)
	) * shake_rot_max * s
	# Roll reads as the most violent axis, so give it a bit more.
	r.z *= 1.6
	return [p, r]


func _tick_breath(delta: float) -> Array:
	_breath = _damp(_breath, _breath_target, 2.0, delta)
	if _breath < EPSILON and _breath_target <= 0.0:
		_breath = 0.0
		_breath_phase = 0.0
		return [Vector3.ZERO, Vector3.ZERO]

	var hz := lerpf(breath_rate_calm, breath_rate_afraid, _breath)
	_breath_phase = fmod(_breath_phase + delta * hz * TAU, TAU)

	# Fast ramp-in so a light touch of breathing is still visible, then the
	# amplitude falls off with fear: faster and shallower.
	var gate := minf(_breath * 4.0, 1.0)
	var amp := gate * lerpf(1.0, breath_shallow, _breath)

	# The chest rise is the vertical; the horizontal drifts at a third of the
	# rate so it never looks like a metronome.
	var y := sin(_breath_phase) * breath_amp * amp
	var x := sin(_breath_phase * 0.33 + 1.1) * breath_amp * 0.6 * amp
	var pitch := cos(_breath_phase) * breath_rot * amp
	var roll := sin(_breath_phase * 0.33) * breath_rot * 0.5 * amp
	return [
		Vector3(_dz(x), _dz(y), 0.0),
		Vector3(_dz(pitch), 0.0, _dz(roll)),
	]


func _tick_recoil(delta: float) -> Array:
	if _recoil_p.length_squared() < EPSILON * EPSILON \
			and _recoil_pv.length_squared() < EPSILON * EPSILON \
			and _recoil_r.length_squared() < EPSILON * EPSILON \
			and _recoil_rv.length_squared() < EPSILON * EPSILON:
		_recoil_p = Vector3.ZERO
		_recoil_pv = Vector3.ZERO
		_recoil_r = Vector3.ZERO
		_recoil_rv = Vector3.ZERO
		return [Vector3.ZERO, Vector3.ZERO]

	var steps := maxi(1, int(ceil(delta / 0.008)))
	var h := delta / float(steps)
	var k := recoil_return * recoil_return
	var c := 2.0 * recoil_settle * 0.5
	for _i in steps:
		_recoil_pv += (-_recoil_p * k - _recoil_pv * c) * h
		_recoil_p += _recoil_pv * h
		_recoil_rv += (-_recoil_r * k - _recoil_rv * c) * h
		_recoil_r += _recoil_rv * h
	return [_recoil_p, _recoil_r]


func _tick_lean(delta: float) -> Array:
	_lean = _damp(_lean, _lean_target, lean_rate, delta)
	_lean = _dz(_lean)
	if _lean == 0.0:
		return [Vector3.ZERO, Vector3.ZERO]
	return [
		Vector3(_lean * lean_offset, -absf(_lean) * lean_offset * 0.12, 0.0),
		Vector3(0.0, 0.0, -_lean * lean_roll),
	]
