extends RefCounted
## A player's body in third person (what teammates see, and the local body in the carry camera):
## plays the rig's idle / walk / run clips, blends pose overrides over them (holding something,
## both hands on bulky loot, the fireman's carry, dragging, and every wind-up / strike from
## combat.action_of), and puts HeldThirdPerson on the right hand (both hands for bulky things) with
## the kind's grip. Everything rig-specific comes from scripts/hands/rig_map.gd; a body without a rig
## (the capsule placeholder, a dev dummy) keeps the old fixed attach point.

const RigMap := preload("res://scripts/hands/rig_map.gd")
const Poser := preload("res://scripts/hands/body_poser.gd")
const Grips := preload("res://scripts/hands/grips.gd")
const WindupScript := preload("res://scripts/combat/windup.gd")

## The fallback attach point on a body without a rig (body space).
const FIXED_ATTACH := Vector3(-0.25, 1.05, -0.35)
## Third-person size cap for two-handed things.
const TP_BOTH_SIZE := 0.55
## Seconds for a hold pose to come and go.
const POSE_RATE := 7.0

var player: Node
var body: Node3D
var skeleton: Skeleton3D = null
var anim: AnimationPlayer = null
var poser: SkeletonModifier3D = null
var rig: Dictionary = {}
## BoneAttachment3D on each arm bone ("HandR" / "HandL"): anything can hang off a hand.
var hand_r: BoneAttachment3D = null
var hand_l: BoneAttachment3D = null

var _clip := ""
var _w := {}              # pose name -> current weight
var _socket_r := Transform3D.IDENTITY   # body space, updated after the skeleton
var _socket_l := Transform3D.IDENTITY
var _two := false
var _shake_t := 0.0
var _active := true
var _syringe: Node3D = null

static var _libs := {}


func _init(p: Node, body_visual: Node3D) -> void:
	player = p
	body = body_visual
	var sks := body.find_children("*", "Skeleton3D", true, false)
	skeleton = sks[0] if not sks.is_empty() else null
	rig = RigMap.detect(skeleton)
	if rig.is_empty():
		skeleton = null
		return
	var aps := body.find_children("*", "AnimationPlayer", true, false)
	anim = aps[0] if not aps.is_empty() else null
	if anim != null:
		_loop_clips()
	poser = Poser.new()
	poser.name = "HandsPoser"
	poser.rig = rig
	skeleton.add_child(poser)
	for side in ["arm_r", "arm_l"]:
		var ba := BoneAttachment3D.new()
		ba.name = "HandR" if side == "arm_r" else "HandL"
		ba.bone_name = String(rig.bones[side])
		skeleton.add_child(ba)
		if side == "arm_r":
			hand_r = ba
		else:
			hand_l = ba
	skeleton.skeleton_updated.connect(_after_skeleton)


func has_rig() -> bool:
	return skeleton != null and is_instance_valid(skeleton) and skeleton.is_inside_tree()


## Every clip loops (the glTF import leaves idle / walk one-shot); shared per rig.
func _loop_clips() -> void:
	var libs := anim.get_animation_library_list()
	if libs.is_empty():
		return
	var lib_name: StringName = libs[0]
	var key := "%s|%s" % [rig.name, lib_name]
	if not _libs.has(key):
		var src := anim.get_animation_library(lib_name)
		var lib: AnimationLibrary = src.duplicate(false)
		for clip in (rig.clips as Dictionary).values():
			if lib.has_animation(clip):
				var a: Animation = lib.get_animation(clip).duplicate(false)
				a.loop_mode = Animation.LOOP_LINEAR
				lib.remove_animation(clip)
				lib.add_animation(clip, a)
		_libs[key] = lib
	anim.remove_animation_library(lib_name)
	anim.add_animation_library(lib_name, _libs[key])
	set_meta("prefix", ("%s/" % lib_name) if String(lib_name) != "" else "")


## Turn the whole body animation off while nobody can see it (the local player outside the carry camera).
func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if anim != null:
		if on:
			_clip = ""
		else:
			anim.stop()
	if poser != null:
		poser.active = on


func update(delta: float) -> void:
	var held: Node3D = player._held_tp
	if not has_rig():
		if held != null and held.position != FIXED_ATTACH:
			held.transform = Transform3D(Basis(), FIXED_ATTACH)
		return
	if not _active:
		return
	var g = player.game
	var act: Dictionary = g.combat.action_of(player) if g != null and g.combat != null else {}
	var kind := String(player.selected_stack().kind)
	var grip := Grips.grip(kind) if kind != "" else {}
	_two = kind != "" and int(grip.hands) >= 2

	# ---- the clip underneath
	if anim != null:
		var want := "idle"
		var rate := 1.0
		if player.moving and not player.downed and player.carried_by == 0 and not player.on_table:
			want = "run" if player.sprinting else "walk"
			if player.carrying != 0 or player.dragging_monster >= 0 or (not act.is_empty() and int(act.ph) == WindupScript.WINDUP):
				rate = 0.7
		var clip: String = String(get_meta("prefix", "")) + String(rig.clips.get(want, want))
		if clip != _clip and anim.has_animation(clip):
			_clip = clip
			anim.play(clip, 0.2)
		anim.speed_scale = rate

	# ---- which poses, how much
	var target := {}
	if player.carrying != 0:
		target["carry"] = 1.0
	elif player.dragging_monster >= 0:
		target["drag"] = 1.0
	elif kind != "":
		target["hold_both" if _two else "hold"] = 1.0
	var action_pose := ""
	var action_w := 0.0
	var from_pose := ""
	if not act.is_empty():
		var k := String(act.k)
		var u := float(act.u)
		match int(act.ph):
			WindupScript.WINDUP:
				action_pose = k + ("_charge" if k == "shove" else "_windup")
				action_w = 1.0 - pow(1.0 - clampf(u * (1.6 if k != "shove" else 2.2), 0.0, 1.0), 2.0)
			WindupScript.STRIKE:
				action_pose = k + "_strike"
				from_pose = k + ("_charge" if k == "shove" else "_windup")
				action_w = 1.0
			_:
				action_pose = k + "_strike"
				action_w = 1.0 - clampf(u, 0.0, 1.0)
	for name in ["hold", "hold_both", "carry", "drag"]:
		var cur := float(_w.get(name, 0.0))
		_w[name] = move_toward(cur, float(target.get(name, 0.0)), delta * POSE_RATE)

	# ---- blend into arm directions
	var ar := Vector3.ZERO
	var arw := 0.0
	var al := Vector3.ZERO
	var alw := 0.0
	var tor := Vector2.ZERO
	var torw := 0.0
	for name in _w.keys():
		var w := float(_w[name])
		if w <= 0.001:
			continue
		var pose: Dictionary = RigMap.POSES.get(name, {})
		if pose.has("arm_r"):
			ar += (pose.arm_r[0] as Vector3).normalized() * w
			arw = maxf(arw, w * float(pose.arm_r[1]))
		if pose.has("arm_l"):
			al += (pose.arm_l[0] as Vector3).normalized() * w
			alw = maxf(alw, w * float(pose.arm_l[1]))
		if pose.has("torso"):
			tor += Vector2(pose.torso[0], pose.torso[1]) * w
			torw = maxf(torw, w * float(pose.torso[2]))
	if action_pose != "" and action_w > 0.0:
		var ap: Dictionary = RigMap.POSES.get(action_pose, {})
		if from_pose != "":
			# Strike: sweep from the wind-up pose to the strike pose.
			var fp: Dictionary = RigMap.POSES.get(from_pose, {})
			var su := sqrt(clampf(float(act.u), 0.0, 1.0))
			ap = _mix(fp, ap, su)
		ar = _toward(ar, arw, ap.get("arm_r"), action_w)
		arw = maxf(arw, action_w * (float(ap.arm_r[1]) if ap.has("arm_r") else 0.0))
		if ap.has("arm_l"):
			al = _toward(al, alw, ap.get("arm_l"), action_w)
			alw = maxf(alw, action_w * float(ap.arm_l[1]))
		if ap.has("torso"):
			tor = tor.lerp(Vector2(ap.torso[0], ap.torso[1]), action_w)
			torw = maxf(torw, action_w)
		if String(act.k) == "shove" and int(act.ph) == WindupScript.WINDUP:
			_shake_t += delta
			var amp := 0.03 + 0.08 * float(act.charge)
			ar += Vector3(sin(_shake_t * 60.0), cos(_shake_t * 47.0), 0.0) * amp
			al += Vector3(cos(_shake_t * 53.0), sin(_shake_t * 66.0), 0.0) * amp
			tor.x -= 0.1 * float(act.charge)
	poser.arm_r = ar if ar.length() > 0.01 else Vector3.FORWARD
	poser.arm_r_w = arw
	poser.arm_l = al if al.length() > 0.01 else Vector3.FORWARD
	poser.arm_l_w = alw
	poser.torso = tor
	poser.torso_w = torw

	# ---- the held stack (placed from the pose the skeleton finished last frame)
	if held != null:
		if _two:
			var mid := (_socket_r.origin + _socket_l.origin) * 0.5
			held.transform = Transform3D(Basis(), mid + Vector3(0.0, 0.05, 0.0))
		else:
			held.transform = _socket_r
		# The jab: the syringe drawn from the vials rides the hand; the vials are out of sight meanwhile.
		var jab: bool = not act.is_empty() and String(act.k) == "jab" and (int(act.ph) != WindupScript.RECOVER or float(act.u) < 0.5)
		if jab and _syringe == null:
			_syringe = preload("res://scripts/combat/combat.gd").make_syringe()
			_syringe.name = "HandsSyringeTP"
			body.add_child(_syringe)
		if _syringe != null:
			_syringe.visible = jab
			if jab:
				_syringe.transform = _socket_r * Transform3D(Basis.from_scale(Vector3.ONE * 2.6), Vector3(0.0, 0.05, 0.0))
		for c in held.get_children():
			(c as Node3D).visible = not jab


## Blend an accumulated direction toward a pose entry [dir, weight] by w.
static func _toward(cur: Vector3, cur_w: float, entry, w: float) -> Vector3:
	if entry == null:
		return cur
	var d: Vector3 = (entry[0] as Vector3).normalized()
	if cur_w <= 0.001 or cur.length() < 0.01:
		return d
	return cur.normalized().slerp(d, clampf(w, 0.0, 1.0))


static func _mix(a: Dictionary, b: Dictionary, u: float) -> Dictionary:
	var out := {}
	for key in ["arm_r", "arm_l"]:
		if a.has(key) and b.has(key):
			out[key] = [(a[key][0] as Vector3).normalized().slerp((b[key][0] as Vector3).normalized(), u), lerpf(a[key][1], b[key][1], u)]
		elif b.has(key):
			out[key] = b[key]
	if a.has("torso") and b.has("torso"):
		out["torso"] = [lerpf(a.torso[0], b.torso[0], u), lerpf(a.torso[1], b.torso[1], u), 1.0]
	elif b.has("torso"):
		out["torso"] = b.torso
	return out


## skeleton_updated: the posed hands, in body space, with the socket axes of grips.gd.
func _after_skeleton() -> void:
	if not has_rig():
		return
	var to_body := body.global_transform.affine_inverse() * skeleton.global_transform
	_socket_r = _socket(to_body, "arm_r")
	_socket_l = _socket(to_body, "arm_l")


func _socket(to_body: Transform3D, side: String) -> Transform3D:
	var bi := skeleton.find_bone(String(rig.bones[side]))
	if bi < 0:
		return Transform3D(Basis(), FIXED_ATTACH)
	var bone := skeleton.get_bone_global_pose(bi)
	var h: Dictionary = rig.hand[side]
	var at: Vector3 = to_body * (bone * (h.offset as Vector3))
	var elbow: Vector3 = to_body * bone.origin
	var fingers := at - elbow
	fingers = fingers.normalized() if fingers.length() > 0.001 else Vector3(0, 0, -1)
	# Palm up for things lying on it; a fist holds its handle thumb up (palm facing the body's middle).
	var kind := String(player.selected_stack().kind)
	var fist := kind != "" and String(Grips.grip(kind).style) == "fist"
	var up := Vector3.UP
	if fist:
		# Body space faces -Z (the glTF is turned 180 degrees): the right hand is on +X, its palm faces -X.
		up = Vector3(-1.0 if side == "arm_r" else 1.0, 0.0, 0.0)
	var z := -fingers
	up = (up - z * up.dot(z))
	up = up.normalized() if up.length() > 0.01 else Vector3.UP
	return Transform3D(Basis(up.cross(z), up, z), at)
