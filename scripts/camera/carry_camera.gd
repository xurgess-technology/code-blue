extends RefCounted
## The over-the-shoulder camera while the local player carries a downed teammate or drags a monster
## (docs/HANDS_AND_FEEDBACK.md "Over-the-shoulder carry camera"). Local only: nothing new on the wire.
##
## Ordinary play is always first person, locked -- this camera only ever engages for the
## carry/drag states below. It moves the camera-feel node (Head/FX) back from the head, over the
## LEFT shoulder while carrying (the body rides the right shoulder, game.pinned_pose +0.55 x) and
## higher over the right shoulder while dragging (the body lies behind and below). The offset is in
## the head's frame, so mouse pitch orbits it around the head, and a teleport moves it with the
## player (no easing across the world; the wall pull-in snaps to the new place). A sphere cast from
## the shoulder keeps it out of walls: in a corridor it pulls in toward the head, and the
## first-person hands take back over if it pulls in far enough to put the camera inside the local
## body. The local body (and the carried body, while carrying) become visible whenever the shoulder
## offset is far enough out to show them; the first-person hands and held item show whenever it is
## not. The flashlight stays at the head, pointed where the camera looks.
## Setting `carry_camera`: "shoulder" (default) or "first_person".

const EASE_TIME := 0.35
## Head-space offsets (x right, y up, z back).
const CARRY_OFFSET := Vector3(-1.0, 0.45, 2.0)
const DRAG_OFFSET := Vector3(0.45, 1.0, 3.6)
## Extra downward look while dragging, radians, so the body behind is in frame.
const DRAG_TILT := 0.45
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

var _side_offset := CARRY_OFFSET
var _tilt := 0.0
var _last_pos := Vector3.INF
var _len_k := 1.0
var _side_k := 1.0
var _body_shown := false


func _init(p: Node) -> void:
	player = p


static func setting_on() -> bool:
	return String(Settings.get_value("carry_camera")) != "first_person"


func wants() -> bool:
	var p = player
	if p == null or not p.alive or p.downed or p.operating or p.hive_view or p.carried_by != 0 or p.on_table:
		return false
	if p.game == null or p.game.phase == p.game.Phase.MENU:
		return false
	if not setting_on():
		return false
	return p.carrying != 0 or p.dragging_monster >= 0


func update(delta: float) -> void:
	var p = player
	var want := wants()
	if want:
		_side_offset = CARRY_OFFSET if p.carrying != 0 else DRAG_OFFSET
	blend = move_toward(blend, 1.0 if want else 0.0, delta / EASE_TIME)
	active = blend > 0.0
	var e := blend * blend * (3.0 - 2.0 * blend)
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
	var want_off: Vector3 = _side_offset * e
	_tilt = (DRAG_TILT if p.dragging_monster >= 0 else 0.0) * e
	# Keep the camera out of walls, in three legs from the head: up, out to the shoulder, back. A wall
	# beside the player moves the camera in over the head (it stays behind them); a wall behind pulls
	# it in toward the head. Shortening is instant, growing back eases.
	var hx: Transform3D = head.global_transform
	var hb := hx.basis.orthonormalized()
	var space: PhysicsDirectSpaceState3D = head.get_world_3d().direct_space_state if head.is_inside_tree() else null
	var top: Vector3 = _cast(space, hx.origin, hx.origin + hb * Vector3(0.0, want_off.y, 0.0))
	var side_goal: Vector3 = top + hb * Vector3(want_off.x, 0.0, 0.0)
	var side_k := _fraction(space, top, side_goal)
	var back_from_full: Vector3 = top + (side_goal - top) * side_k
	var back_k := _fraction(space, back_from_full, back_from_full + hb * Vector3(0.0, 0.0, want_off.z))
	var teleported: bool = _last_pos != Vector3.INF and _last_pos.distance_to(p.global_position) > 2.5
	_last_pos = p.global_position
	if teleported:
		_side_k = side_k
		_len_k = back_k
	else:
		_side_k = side_k if side_k < _side_k else minf(side_k, _side_k + EXTEND_SPEED * delta / maxf(0.05, absf(want_off.x)))
		_len_k = back_k if back_k < _len_k else minf(back_k, _len_k + EXTEND_SPEED * delta / maxf(0.05, want_off.z))
	var shoulder: Vector3 = top + (side_goal - top) * minf(_side_k, side_k)
	var world_cam: Vector3 = shoulder + hb * Vector3(0.0, 0.0, want_off.z * minf(_len_k, back_k))
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
	p.body_visual.visible = on
	if on:
		# The torch sits inside the head: the local body must not shadow its own beam.
		for mi in p.body_visual.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if p.body_hands != null:
		p.body_hands.set_active(on)


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
