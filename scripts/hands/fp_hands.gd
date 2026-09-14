extends Node3D
## The local player's first-person hands (node "Hands" under the camera; docs/HANDS_AND_FEEDBACK.md
## "Held items in the hands"). The right hand holds the torch, the left hand the selected stack;
## bulky loot and the guide take both hands and the torch tucks under the right arm. Every frame it
## poses both hands (rest pose for what is held, the wind-up / strike / recover of combat.action_of,
## walk bob, sway lagging the mouse, lower-and-raise on a new stack, lowered while sprinting, pulled
## in near walls) and puts HeldFirstPerson on the palm with the kind's grip (grips.gd).
##
## Hands and held stacks render on HANDS_LAYER, which the flashlight does not light (it sits a hand's
## width away and would bleach them), and cast no shadows.

const Arms := preload("res://scripts/hands/fp_arms.gd")
const Poses := preload("res://scripts/hands/hand_poses.gd")
const Grips := preload("res://scripts/hands/grips.gd")
const WindupScript := preload("res://scripts/combat/windup.gd")

const HANDS_LAYER := 1 << 18
## First-person stack sizes: bulky / two-handed things fit this longest side, big loot this one.
const FP_BOTH_SIZE := 0.22
const FP_LOOT_SIZE := 0.13
const FP_FIST_SIZE := 0.26
## Seconds to lower and raise the hands when the stack changes.
const RAISE_TIME := 0.38
## How far in front of the camera the wall check reaches, and how far the hands pull back.
const WALL_REACH := 0.62
const WALL_PULL := 0.17

var player: Node = null
var arm_r: Node3D
var arm_l: Node3D
var torch: Node3D
var syringe: Node3D
## x/y scale of every placed position for the current field of view (Player.apply_fov sets it).
var fov_k := 1.0
## The pose each hand ended on last frame (tests and the gameshot read these).
var pose_r: Dictionary = {}
var pose_l: Dictionary = {}

var _kind := ""
var _count := 0
var _raise := 0.0
var _bob := 0.0
var _speed := 0.0
var _sprint := 0.0
var _sway := Vector2.ZERO
var _last_look := Vector2.INF
var _pull := 0.0
var _wall_t := 0.0
var _shake_t := 0.0


func setup(p: Node) -> void:
	player = p
	name = "Hands"
	var col: Color = p.colour
	arm_r = Arms.make_arm(1.0, col)
	add_child(arm_r)
	arm_l = Arms.make_arm(-1.0, col)
	add_child(arm_l)
	torch = Arms.make_torch()
	arm_r.add_child(torch)
	torch.position = Vector3(0.0, 0.022, -0.01)
	syringe = preload("res://scripts/combat/combat.gd").make_syringe()
	syringe.name = "HandsSyringe"
	syringe.visible = false
	arm_l.add_child(syringe)
	syringe.position = Vector3(0.0, 0.024, 0.0)
	dress(self)


## Put every mesh under `node` on the hands layer, shadowless.
static func dress(node: Node) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = HANDS_LAYER
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in node.get_children():
		dress(c)


## The selected stack changed: lower the hands and bring the new one up.
func held_changed(kind: String, count: int) -> void:
	if kind != _kind:
		_raise = 1.0
	_kind = kind
	_count = count


## How big a stack of `kind` is drawn in first person.
static func fp_scale(kind: String) -> float:
	var fp := ItemModels.footprint(kind)
	var biggest := maxf(fp.x, maxf(fp.y, fp.z))
	var g := Grips.grip(kind)
	if int(g.hands) >= 2:
		return minf(1.0, FP_BOTH_SIZE / maxf(0.01, biggest))
	if String(g.style) == "fist":
		return minf(1.0, FP_FIST_SIZE / maxf(0.01, biggest))   # a handle stays long enough to see past the fist
	if Items.is_loot(kind) and biggest > FP_LOOT_SIZE:
		return FP_LOOT_SIZE / biggest
	return 1.0


func update(delta: float) -> void:
	if player == null or not visible:
		return
	var g = player.game
	var act: Dictionary = g.combat.action_of(player) if g != null and g.combat != null else {}
	var grip := Grips.grip(_kind) if _kind != "" else {}
	var two := _kind != "" and int(grip.get("hands", 1)) >= 2
	var fist := _kind != "" and String(grip.get("style", "palm")) == "fist"

	# ---- rest poses for what is held
	var rest_l: Dictionary = Poses.LEFT_EMPTY
	var rest_r: Dictionary = Poses.TORCH
	var centre := Poses.BOTH_CENTRE
	var half := 0.0
	if two:
		var fp := ItemModels.footprint(_kind) * fp_scale(_kind)
		half = fp.x * 0.5
		rest_l = _offset(Poses.BOTH_LEFT, centre + Vector3(-half, 0.0, 0.0))
		rest_r = Poses.TORCH_TUCKED
	elif _kind != "":
		rest_l = Poses.LEFT_FIST if fist else Poses.LEFT_PALM
	var right_both := _offset(Poses.mirror(Poses.BOTH_LEFT), centre + Vector3(half, 0.0, 0.0))

	# ---- actions
	var pl: Dictionary = rest_l
	var pr: Dictionary = right_both if two else rest_r
	var jab := false
	if not act.is_empty():
		match String(act.k):
			"jab":
				pl = Poses.action_pose(rest_l, Poses.JAB, act)
				jab = true
			"saw":
				pl = Poses.action_pose(rest_l, Poses.SAW, act)
			"shove":
				pl = Poses.action_pose(rest_l, Poses.SHOVE_LEFT, act)
				var keys_r := [Poses.mirror(Poses.SHOVE_LEFT[0]), Poses.mirror(Poses.SHOVE_LEFT[1])]
				pr = Poses.action_pose(pr, keys_r, act)
				if int(act.ph) == WindupScript.WINDUP:
					# Shaking as the charge builds.
					_shake_t += delta
					var amp := 0.002 + 0.007 * float(act.charge)
					var jig := Vector3(sin(_shake_t * 71.0), cos(_shake_t * 57.0), 0.0) * amp
					pl.p = (pl.p as Vector3) + jig
					pr.p = (pr.p as Vector3) - jig
	if two and (act.is_empty() or String(act.k) != "shove"):
		pr = right_both

	# ---- life: bob, sway, raise, sprint, walls
	var speed01 := 0.0
	if player.is_on_floor():
		speed01 = clampf(Vector2(player.velocity.x, player.velocity.z).length() / C.SPRINT_SPEED, 0.0, 1.0)
	_speed = lerpf(_speed, speed01, clampf(delta * 8.0, 0.0, 1.0))
	_bob = fmod(_bob + delta * (7.5 + 4.0 * _speed) * maxf(_speed, 0.05), TAU)
	var sprint_on: bool = player.sprinting and act.is_empty()
	_sprint = move_toward(_sprint, 1.0 if sprint_on else 0.0, delta * 4.0)
	var look := Vector2(player.rotation.y, player.head.rotation.x)
	if _last_look == Vector2.INF:
		_last_look = look
	var dl := Vector2(wrapf(look.x - _last_look.x, -PI, PI), look.y - _last_look.y)
	_last_look = look
	var want_sway := Vector2(clampf(dl.x / maxf(delta, 0.001) * 0.012, -0.05, 0.05), clampf(dl.y / maxf(delta, 0.001) * 0.01, -0.04, 0.04))
	_sway = _sway.lerp(want_sway, clampf(delta * 9.0, 0.0, 1.0))
	_raise = maxf(0.0, _raise - delta / RAISE_TIME)
	_wall_t -= delta
	if _wall_t <= 0.0:
		_wall_t = 0.05
		_wall_target = _wall_check()
	_pull = lerpf(_pull, _wall_target, clampf(delta * 12.0, 0.0, 1.0))

	var bob := Vector3(sin(_bob) * 0.009, -absf(cos(_bob)) * 0.011, 0.0) * _speed
	var raise_e := Poses.smooth(_raise)
	var extra := bob + Vector3(_sway.x, -_sway.y, 0.0) + Vector3(0.0, -0.3 * raise_e, 0.05 * raise_e) \
		+ Vector3(0.02, -0.13, 0.07) * _sprint + Vector3(0.0, -0.05, WALL_PULL) * _pull
	var tilt := Basis(Vector3.RIGHT, -0.55 * raise_e - 0.45 * _sprint - 0.2 * _pull)
	pose_l = pl
	pose_r = pr
	var xl := _placed(pl, extra, tilt)
	var xr := _placed(pr, extra, tilt)
	arm_l.transform = xl
	arm_r.transform = xr
	Arms.set_curl(arm_l, float(pl.c), -1.0)
	Arms.set_curl(arm_r, float(pr.c), 1.0)
	torch.visible = true
	syringe.visible = jab and int(act.ph) != WindupScript.RECOVER or (jab and float(act.u) < 0.5)

	# ---- the held stack
	var held: Node3D = player._held_fp
	if held != null:
		if two:
			# The midpoint of the two palms, facing forward, palm-up frame.
			var mid := (xl.origin + xr.origin) * 0.5 + Vector3(0.0, 0.03, 0.0)
			held.transform = Transform3D(tilt, mid)
		else:
			held.transform = xl
		for c in held.get_children():
			for part in c.get_children():
				if part is Node3D and part != syringe:
					(part as Node3D).visible = not syringe.visible


var _wall_target := 0.0


## 0..1: how much a wall in front of the camera pushes the hands back.
func _wall_check() -> float:
	var cam: Camera3D = player.camera
	if cam == null or not cam.is_inside_tree():
		return 0.0
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var basis := cam.global_transform.basis
	var best := WALL_REACH
	for dir in [Vector3(0.0, -0.25, -1.0), Vector3(0.35, -0.4, -1.0), Vector3(-0.35, -0.4, -1.0)]:
		var d: Vector3 = (basis * dir).normalized()
		var q := PhysicsRayQueryParameters3D.create(from, from + d * WALL_REACH)
		q.collision_mask = C.L_WORLD
		q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			best = minf(best, from.distance_to(hit.position))
	return clampf((WALL_REACH - best) / (WALL_REACH - 0.25), 0.0, 1.0)


func _placed(pose: Dictionary, extra: Vector3, tilt: Basis) -> Transform3D:
	var x := Poses.xform(pose)
	var p := x.origin + extra
	return Transform3D(tilt * x.basis, Vector3(p.x * fov_k, p.y * fov_k, p.z))


static func _offset(pose: Dictionary, by: Vector3) -> Dictionary:
	var d := pose.duplicate()
	d.p = (pose.p as Vector3) + by
	return d
