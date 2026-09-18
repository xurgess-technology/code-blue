extends RefCounted
## The over-the-shoulder carry camera while the local player carries a downed teammate or a body, or
## drags a monster (docs/HANDS_AND_FEEDBACK.md "Over-the-shoulder carry camera"). Local only: nothing
## new on the wire.
##
## Ordinary play is first person unless the `camera` setting is "shoulder" (F5 flips it): then this
## rig is on all the time, at PLAY_ARM, except where the game wants the head (operating, Hive Eyes,
## downed, carried, on the table, dead). Framed the way the big third-person games do it (The Last of Us Part II,
## the RE4 remake, God of War): the camera sits close behind and over the RIGHT shoulder, so the
## carrier fills the left third of the screen and the crosshair at the centre is clear; the load
## rides the LEFT shoulder (game.pinned_pose -0.55 x, Player.HUMAN_CARRIED_SHOULDER mirrored,
## corpses.shoulder_pose), where it shows at the left edge without filling the frame.
##
## The rig: a PIVOT at the upper back (just below and behind the eye, in the player's yaw frame),
## then the shoulder offset sideways, then an arm up and back that swings with the look pitch --
## scaled down (ORBIT_K) so looking down lifts the camera a little over the shoulder and looking up
## lowers it a little behind the back, and a little shorter looking up (LOOK_UP_PULL) so it never
## digs into the floor. The camera itself always looks where the head looks, so the crosshair aims
## along the player's aim (aim_segment). A teleport moves it with the player (no easing across the
## world; the wall pull-in snaps to the new place). Sphere casts along the same three legs (head ->
## pivot -> shoulder -> camera) keep it out of walls: in a corridor it pulls in toward the head, and
## the first-person hands take back over if it pulls in far enough to put the camera inside the
## local body. The local body (and the carried body, while carrying) become visible whenever the
## camera is far enough out to show them; the first-person hands and held item show whenever it is
## not. The flashlight stays at the head, pointed where the camera looks.
## After a body goes into the furnace the camera lingers over the shoulder for LINGER_SECONDS so the
## carrier sees it roll off into the fire (linger(), corpses.gd).
## Setting `carry_camera`: "shoulder" (default) or "first_person", for the carry/drag states when
## the `camera` setting is first person.

const EASE_TIME := 0.4
## Yaw-frame offsets (x right, y up, z back). PIVOT is from the eye; the arms are from the pivot.
const PIVOT := Vector3(0.0, -0.2, 0.12)
## Carrying: close over the right shoulder. At level pitch the camera sits (0.5, 0.14, 1.27) from the eye.
const CARRY_ARM := Vector3(0.5, 0.34, 1.15)
## Ordinary play with the `camera` setting on "shoulder": the carry framing, a touch further back.
const PLAY_ARM := Vector3(0.5, 0.3, 1.35)
## Dragging: the body lies behind, so a little higher and further back, looking gently down.
const DRAG_ARM := Vector3(0.58, 0.72, 1.5)
## Extra downward look while dragging, radians, so the body behind is in frame.
const DRAG_TILT := 0.2
## How much of the look pitch swings the arm around the pivot (0 rigid, 1 a full orbit).
const ORBIT_K := 0.45
## The arm's back reach is this much shorter looking fully up (none looking level or down).
const LOOK_UP_PULL := 0.25
## How fast the arm follows a change of target (carrying -> dragging), 1/s.
const ARM_FOLLOW := 6.0
const LINGER_SECONDS := 2.5
const CAST_RADIUS := 0.16
## Below this distance from the head the local body hides (the camera would be inside it).
const HIDE_BODY_BELOW := 0.55
## How fast the arm lengthens again after a wall pulled it in (m/s); shortening is instant.
const EXTEND_SPEED := 2.5
const FLASH_OFFSET := Vector3(0.18, -0.16, 0.0)

var player: Node
## 0 first person .. 1 fully over the shoulder (eased when applied).
var blend := 0.0
## The last applied head-space offset of the camera and its distance from the head (tests).
var offset := Vector3.ZERO
var arm_length := 0.0
var active := false

var _target_arm := CARRY_ARM
var _arm := CARRY_ARM
var _tilt := 0.0
var _last_pos := Vector3.INF
var _len_k := 1.0
var _side_k := 1.0
var _body_shown := false
var _linger := 0.0


func _init(p: Node) -> void:
	player = p


static func setting_on() -> bool:
	return String(Settings.get_value("carry_camera")) != "first_person"


## The `camera` setting: over the shoulder in ordinary play too.
static func play_on() -> bool:
	return String(Settings.get_value("camera")) == "shoulder"


func wants() -> bool:
	var p = player
	if p == null or not p.alive or p.downed or p.operating or p.hive_view or p.carried_by != 0 or p.on_table:
		return false
	if p.game == null or p.game.phase == p.game.Phase.MENU:
		return false
	if play_on():
		return true
	if not setting_on():
		return false
	return p.carrying != 0 or p.dragging_monster >= 0 or _linger > 0.0


## Stay over the shoulder a moment after the carry ends (a body just went into the furnace).
func linger(seconds: float = LINGER_SECONDS) -> void:
	_target_arm = CARRY_ARM
	_linger = seconds


## The camera's yaw-frame offset from the eye for an arm and a look pitch, walls ignored (tests).
static func rest_offset(arm: Vector3, pitch: float) -> Vector3:
	return PIVOT + Vector3(arm.x, 0.0, 0.0) + swing(arm, pitch)


## The up-and-back part of an arm, swung around the pivot by the look pitch (+ looks up).
static func swing(arm: Vector3, pitch: float) -> Vector3:
	var pull := 1.0 - LOOK_UP_PULL * clampf(pitch / 1.3, 0.0, 1.0)
	return Basis(Vector3.RIGHT, pitch * ORBIT_K) * Vector3(0.0, arm.y, arm.z * pull)


func update(delta: float) -> void:
	var p = player
	_linger = maxf(0.0, _linger - delta)
	if p != null and (p.downed or not p.alive):
		_linger = 0.0
	var want := wants()
	if want and (p.carrying != 0 or p.dragging_monster >= 0):
		_target_arm = CARRY_ARM if p.carrying != 0 else DRAG_ARM
	elif want and _linger <= 0.0:
		_target_arm = PLAY_ARM
	if blend <= 0.0:
		_arm = _target_arm
	else:
		_arm = _arm.lerp(_target_arm, clampf(1.0 - exp(-ARM_FOLLOW * delta), 0.0, 1.0))
	blend = move_toward(blend, 1.0 if want else 0.0, delta / EASE_TIME)
	active = blend > 0.0
	# smootherstep: no jolt as it leaves the head or as it settles over the shoulder
	var e := blend * blend * blend * (blend * (blend * 6.0 - 15.0) + 10.0)
	var fx: Node3D = p.fx
	var head: Node3D = p.head
	if fx == null or head == null:
		return
	if not active:
		if fx.position != Vector3.ZERO or fx.rotation.x != 0.0:
			fx.position = Vector3.ZERO
			fx.rotation.x = 0.0
			p.flashlight.transform = Transform3D(Basis(), FLASH_OFFSET)
			offset = Vector3.ZERO
			arm_length = 0.0
		_show_body(false)
		_last_pos = Vector3.INF
		return
	_tilt = (DRAG_TILT if p.dragging_monster >= 0 else 0.0) * e
	# Keep the camera out of walls, in three legs from the head: to the pivot at the upper back, out
	# to the right shoulder, then up and back along the swung arm. A wall beside the player moves the
	# camera in over the head (it stays behind them); a wall behind pulls it in toward the head.
	# Shortening is instant, growing back eases.
	var hx: Transform3D = head.global_transform
	var hb := Basis(Vector3.UP, (p as Node3D).global_rotation.y)   # yaw only; the pitch swings the arm
	var sw: Vector3 = swing(_arm, head.rotation.x) * e
	var space: PhysicsDirectSpaceState3D = head.get_world_3d().direct_space_state if head.is_inside_tree() else null
	var pivot: Vector3 = _cast(space, hx.origin, hx.origin + hb * (PIVOT * e))
	var side_goal: Vector3 = pivot + hb * Vector3(_arm.x * e, 0.0, 0.0)
	var side_k := _fraction(space, pivot, side_goal)
	var from_side: Vector3 = pivot + (side_goal - pivot) * side_k
	var back_k := _fraction(space, from_side, from_side + hb * sw)
	var teleported: bool = _last_pos != Vector3.INF and _last_pos.distance_to(p.global_position) > 2.5
	_last_pos = p.global_position
	if teleported:
		_side_k = side_k
		_len_k = back_k
	else:
		_side_k = side_k if side_k < _side_k else minf(side_k, _side_k + EXTEND_SPEED * delta / maxf(0.05, absf(_arm.x * e)))
		_len_k = back_k if back_k < _len_k else minf(back_k, _len_k + EXTEND_SPEED * delta / maxf(0.05, sw.length()))
	var shoulder: Vector3 = pivot + (side_goal - pivot) * minf(_side_k, side_k)
	var world_cam: Vector3 = shoulder + hb * (sw * minf(_len_k, back_k))
	offset = hx.affine_inverse() * world_cam
	arm_length = offset.length()
	fx.position = offset
	fx.rotation.x = -_tilt
	# The torch stays at the head and looks where the camera looks.
	var cam: Camera3D = p.camera
	var flash: SpotLight3D = p.flashlight
	flash.global_transform = Transform3D(cam.global_transform.basis, hx * FLASH_OFFSET)
	_show_body(e > 0.08 and arm_length > HIDE_BODY_BELOW)


func _show_body(on: bool) -> void:
	var p = player
	if on == _body_shown:
		return
	_body_shown = on
	if p.body_visual == null:
		return
	# Player shows it on its own layer, unshadowed (the torch sits inside the head), and lets the
	# first-person camera draw that layer while it's shown.
	p.set_carry_body(on)


## True while the first-person hands and held stack should hide: only once the third-person body
## is actually showing (see HIDE_BODY_BELOW). A wall pulling the shoulder camera in close enough to
## hide the body hands the first-person view back rather than leaving both hidden.
func hides_hands() -> bool:
	return _body_shown


## Player._update_aim (and any other reach check, e.g. the scanner) while the camera is over the
## shoulder: the ray starts on the camera ray where it passes the head (nothing between the camera
## and the head counts) and reaches `range` from the head. [from, to].
func aim_segment(range: float = C.INTERACT_RANGE) -> Array:
	var cam: Camera3D = player.camera
	var dir: Vector3 = -cam.global_transform.basis.z
	var from: Vector3 = cam.global_position
	var head: Vector3 = player.head.global_position
	var along := maxf(0.0, (head - from).dot(dir))
	var start := from + dir * along
	var side := start.distance_to(head)
	var reach := sqrt(maxf(0.0, range * range - side * side))
	return [start, start + dir * reach]


## How far (0..1) a CAST_RADIUS sphere gets from `from` to `to` before the world stops it.
func _fraction(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> float:
	if space == null or from.distance_to(to) < 0.005:
		return 1.0
	var q := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = CAST_RADIUS
	q.shape = sphere
	q.transform = Transform3D(Basis(), from)
	q.motion = to - from
	q.collision_mask = C.L_WORLD
	q.exclude = [player.get_rid()]
	var res := space.cast_motion(q)
	return clampf(res[0], 0.0, 1.0) if res.size() >= 1 else 1.0


func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Vector3:
	return from + (to - from) * _fraction(space, from, to)
