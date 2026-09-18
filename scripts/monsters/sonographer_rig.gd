extends SkeletonModifier3D
## The Sonographer's stylized model (`monster/sonographer`, art/stylized variant `sonographer`) on a
## monster model.
##
## `build(model)` spawns the GLB under the MonsterModel, points the model's `rig`, `skeleton` and
## `anim` at it, adds this modifier to its skeleton and hangs a node named `Head` on the head bone in
## the model's own axes (+Y up, +Z its face), the way the Hive does. It also:
##   - takes the two ear pieces (Human_Ear_L / _R) off the mesh and re-hangs each one under a pivot at
##     its Site_ear_*, so MonsterModel.set_ears can swivel them toward a sound;
##   - puts the glow shader on the windpipe (Human_Throat) behind the thin skin of the throat
##     (Human_ThroatSkin, which goes translucent), and a small cold light in the neck;
##   - builds its ultrasound cart (sono_cart.gd) and remembers where the cable plugs in (Site_cable).
##
## Clips (Assets anims): SonoIdle, SonoWalk (1.05 m/s), SonoListen, SonoCharge, SonoEcho, SonoRush
## (3.1 m/s), SonoWail, SonoStagger, SonoLying. The monster picks the clip and the rate; this modifier
## adds the poses there are no clips for, on top of whatever the clip left.
##
## It stands in for rig_shaper.gd: `model.shaper` points here, so monster.gd, the stun window and the
## dissection table set the same inputs they give every other monster:
##   lying, daze, rise, stagger, twitch, listen, listen_yaw, lunge   (see hive_rig.gd)
## and the look interface it adds is documented on MonsterModel.set_sono_look (docs/CONTRACTS.md).
##
## Every value is in skeleton space (+Y up, +Z its front, +X its left).

const KEY := "monster/sonographer"
## Ground speeds the walk and rush clips were authored at (art/stylized/st_sono_clips.py).
const WALK_SPEED := 1.05
const RUSH_SPEED := 3.10
const GLOW := Color(0.30, 0.78, 1.0)
const GLOW_SHADER := "res://shaders/sono_glow.gdshader"
const CartScript := preload("res://scripts/monsters/sono_cart.gd")
## How far a look can turn the head from where the clip has it, and how the turn is shared out. The
## long neck does most of it: that is the whole point of the neck.
const LOOK_MAX := 1.45
const LOOK_SHARE := {"chest": 0.14, "neck": 0.46, "head": 0.40}

var cfg := {"lying_spread": 6.0}
var listen := 0.0
var listen_yaw := 0.0
var lunge := 0.0
var stagger := 0.0
var twitch := Vector3.ZERO
var lying := 0.0
var daze := 0.0
var rise := 0.0
## The look interface (MonsterModel.set_sono_look sets these): how suspicious it is, how far an echo
## is charged, which of idle/suspicious/charging/echo/rush/wail/stagger/lying it is in, and whether
## the cart is still plugged into its neck.
var suspicion := 0.0
var charge := 0.0
var mode := "idle"
var plugged := true
## World position the head looks at while `listen` > 0 (set by whoever drives it).
var look_target := Vector3.ZERO
## Where the eyes would have been, in the Head node's frame; set from the model's Site_eyes.
var eye_offset := Vector3(0.0, 0.10, 0.09)
## World positions of the hands after this frame's pose.
var hand_left := Vector3.ZERO
var hand_right := Vector3.ZERO

var cart: Node3D = null

var _b := {}
var _rest_fwd := Vector3.BACK
var _rest_up := Vector3.UP
var _throat: ShaderMaterial = null
var _pane: StandardMaterial3D = null
var _light: OmniLight3D = null
var _cable_at: Node3D = null
var _shown := -1.0

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
		for n in ["SonoIdle", "SonoWalk", "SonoListen", "SonoRush", "SonoLying"]:
			if ap.has_animation(n):
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	var sk: Skeleton3D = skels[0]
	var poser = load("res://scripts/monsters/sonographer_rig.gd").new()
	poser.name = "SonoPoser"
	sk.add_child(poser)
	poser._setup(root, sk, model)
	model.sono = poser
	model.shaper = poser
	return true


func _setup(root: Node3D, sk: Skeleton3D, model: Node3D) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var hi := _bone(sk, "head")
	var rest := sk.get_bone_global_rest(hi) if hi >= 0 else Transform3D()
	var rb := rest.basis.orthonormalized()
	_rest_fwd = rb.inverse() * Vector3.BACK
	_rest_up = rb.inverse() * Vector3.UP
	var ba := BoneAttachment3D.new()
	ba.name = "HeadBone"
	ba.bone_name = "head"
	sk.add_child(ba)
	var head := Node3D.new()
	head.name = "Head"
	head.transform = Transform3D(rb.inverse(), Vector3.ZERO)
	ba.add_child(head)
	var site := root.find_child("Site_eyes", true, false) as Node3D
	if site != null and hi >= 0:
		eye_offset = (rest * site.position) - rest.origin

	_ears(root, sk, model)
	_throat_glow(root, sk)
	_cable_socket(root, sk)
	cart = CartScript.new()
	model.add_child(cart)
	model.cart = cart
	_set_glow(0.0)


## Each ear off the mesh and onto a pivot at its site, so set_ears can turn it.
func _ears(root: Node3D, sk: Skeleton3D, model: Node3D) -> void:
	var hi := _bone(sk, "head")
	if hi < 0:
		return
	var head_rest := sk.get_bone_global_rest(hi)
	# the pivots stand in the model's own axes (X its left, Y up, Z its face), not the head bone's,
	# so MonsterModel.set_ears can yaw an ear about Y and tip it about X the way it expects
	var model_axes := head_rest.basis.orthonormalized().inverse()
	for tag in ["L", "R"]:
		var mi := root.find_child("Human_Ear_" + tag, true, false) as MeshInstance3D
		var at := root.find_child("Site_ear_" + tag, true, false) as Node3D
		if mi == null or at == null:
			continue
		var sx := 1.0 if tag == "L" else -1.0
		var ba := BoneAttachment3D.new()
		ba.name = "EarBone" + tag
		ba.bone_name = "head"
		sk.add_child(ba)
		var pivot := Node3D.new()
		pivot.name = "Ear" + tag
		# Site_ear_* rides the head bone, so its position is where the ear turns in that bone's frame.
		pivot.transform = Transform3D(model_axes, at.position)
		ba.add_child(pivot)
		# The ear mesh's vertices are in the skeleton's space, so under the pivot it needs the inverse
		# of everything above it to land back where the sculpt put it. Its skin goes: the pivot moves
		# it now, not the head bone's weights.
		mi.get_parent().remove_child(mi)
		mi.skin = null
		mi.skeleton = NodePath()
		mi.transform = (head_rest * pivot.transform).affine_inverse()
		pivot.add_child(mi)
		model.ears.append({"node": pivot, "side": sx, "rest": 0.0})


## The windpipe glows behind the thin skin of the throat, and throws a little cold light into the neck.
func _throat_glow(root: Node3D, sk: Skeleton3D) -> void:
	var mi := root.find_child("Human_Throat", true, false) as MeshInstance3D
	var shader := load(GLOW_SHADER) as Shader
	if mi != null and shader != null:
		var src := mi.get_active_material(0) as BaseMaterial3D
		var sm := ShaderMaterial.new()
		sm.shader = shader
		if src != null and src.albedo_texture != null:
			sm.set_shader_parameter("albedo_tex", src.albedo_texture)
		else:
			sm.set_shader_parameter("use_tex", false)
			sm.set_shader_parameter("base_color", Color("cfd2cb"))
		sm.set_shader_parameter("glow", GLOW)
		sm.set_shader_parameter("idle_energy", 0.12)
		sm.set_shader_parameter("full_energy", 10.0)
		# the whole windpipe lights at once: nothing travels along it (that is the cable's job)
		sm.set_shader_parameter("t_scale", 0.0)
		sm.set_shader_parameter("t_offset", 0.5)
		sm.set_shader_parameter("flow", 1.0)
		mi.material_override = sm
		_throat = sm
	# the pane of skin over it goes translucent so the rings show through
	var pane := root.find_child("Human_ThroatSkin", true, false) as MeshInstance3D
	if pane != null:
		var src2 := pane.get_active_material(0) as BaseMaterial3D
		var m := StandardMaterial3D.new()
		if src2 != null:
			m.albedo_texture = src2.albedo_texture
		m.albedo_color = Color(1.0, 1.0, 1.0, 0.42)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.roughness = 0.2
		pane.material_override = m
		_pane = m
	var neck := BoneAttachment3D.new()
	neck.name = "ThroatBone"
	neck.bone_name = "neck"
	sk.add_child(neck)
	_light = OmniLight3D.new()
	_light.name = "ThroatGlow"
	_light.light_color = GLOW
	_light.omni_range = 0.7
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.visible = false
	var thr := root.find_child("Site_throat", true, false) as Node3D
	if thr != null:
		_light.transform = thr.transform
	else:
		_light.position = Vector3(0.0, 0.10, 0.0)
	neck.add_child(_light)


func _cable_socket(root: Node3D, sk: Skeleton3D) -> void:
	var at := root.find_child("Site_cable", true, false) as Node3D
	var ba := BoneAttachment3D.new()
	ba.name = "CableBone"
	ba.bone_name = "neck"
	sk.add_child(ba)
	_cable_at = Node3D.new()
	_cable_at.name = "CableSocket"
	if at != null:
		_cable_at.transform = at.transform
	else:
		_cable_at.position = Vector3(0.0, 0.0, -0.06)
	ba.add_child(_cable_at)


## Where the cart's cable plugs into the back of its neck, in world space.
func cable_point() -> Vector3:
	return _cable_at.global_position if _cable_at != null else global_position


## The look interface. `mode` is one of idle, suspicious, charging, echo, rush, wail, stagger, lying.
func set_look(susp: float, chg: float, m: String, plug: bool) -> void:
	suspicion = clampf(susp, 0.0, 1.0)
	charge = clampf(chg, 0.0, 1.0)
	mode = m
	plugged = plug
	_set_glow(maxf(charge, suspicion * 0.30))
	if cart != null:
		cart.set_look(suspicion, charge, mode, plug)


## The throat: 0 a cold ember behind the skin, 1 the rings burning through it.
func _set_glow(v: float) -> void:
	if absf(v - _shown) < 0.01:
		return
	_shown = v
	if _throat != null:
		_throat.set_shader_parameter("level", v)
	if _pane != null:
		_pane.albedo_color = Color(1.0, 1.0, 1.0, 0.42 - 0.18 * v)
	if _light != null:
		_light.visible = v > 0.02
		_light.light_energy = 0.55 * v


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


## rig_shaper.gd's API, for anything that asks.
func attach(node: Node3D, bone: String, offset := Transform3D.IDENTITY, _tip := 0.0) -> void:
	var sk := get_skeleton()
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone
	sk.add_child(ba)
	node.transform = offset
	ba.add_child(node)


func bone_point(bone: String, offset := Vector3.ZERO, _tip := 0.0) -> Vector3:
	var sk := get_skeleton()
	var i := _bone(sk, bone)
	if i < 0:
		return sk.global_position
	return sk.global_transform * (sk.get_bone_global_pose(i) * offset)


## Turn `bone` about a skeleton-space axis through its own head, on top of its current pose.
func _turn(sk: Skeleton3D, bone: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 0.0001 or axis.length_squared() < 1e-8:
		return
	var i := _bone(sk, bone)
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var g := pg * Basis(sk.get_bone_pose_rotation(i))
	var local := pg.inverse() * (Basis(axis.normalized(), angle) * g)
	sk.set_bone_pose_rotation(i, local.get_rotation_quaternion())


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if lying == 0.0 and daze == 0.0 and rise == 0.0 and stagger == 0.0 and listen == 0.0 and twitch == Vector3.ZERO:
		_record_hands(sk)
		return
	var X := Vector3.RIGHT
	var Z := Vector3.BACK
	if lying > 0.0:
		_lie(sk)
	var l := 1.0 - lying
	if daze > 0.0 or rise > 0.0:
		# Stunned: the long neck folds down and the head hangs off the end of it.
		var jolt := sin(Time.get_ticks_msec() * 0.031) * rise * (1.0 - rise) * 2.2
		_turn(sk, "spine", X, (0.30 * daze - 0.18 * jolt) * l)
		_turn(sk, "neck", X, (0.55 * daze - 0.30 * jolt) * l)
		_turn(sk, "head", X, 0.35 * daze * l)
		_turn(sk, "upperarm.L", X, 0.25 * daze * l)
		_turn(sk, "upperarm.R", X, 0.25 * daze * l)
	if stagger > 0.0:
		_turn(sk, "spine", X, -0.35 * stagger * l)
		_turn(sk, "neck", X, 0.30 * stagger * l)
		_turn(sk, "head", X, -0.25 * stagger * l)
	if twitch != Vector3.ZERO:
		var tw := twitch * l
		_turn(sk, "head", Vector3.UP, tw.y)
		_turn(sk, "head", X, tw.x)
		_turn(sk, "head", Z, tw.z)
	if listen > 0.0 and l > 0.0:
		_cock(sk, listen * l)
	_record_hands(sk)


func _record_hands(sk: Skeleton3D) -> void:
	var li := _bone(sk, "hand.L")
	var ri := _bone(sk, "hand.R")
	if li >= 0:
		hand_left = sk.global_transform * sk.get_bone_global_pose(li).origin
	if ri >= 0:
		hand_right = sk.global_transform * sk.get_bone_global_pose(ri).origin


## Straight on its back: every bone eases back to rest, then the arms come in to its sides.
func _lie(sk: Skeleton3D) -> void:
	var k := lying
	for i in sk.get_bone_count():
		var r := sk.get_bone_rest(i)
		sk.set_bone_pose_rotation(i, sk.get_bone_pose_rotation(i).slerp(r.basis.get_rotation_quaternion(), k))
		sk.set_bone_pose_position(i, sk.get_bone_pose_position(i).lerp(r.origin, k))
	var spread := deg_to_rad(float(cfg.get("lying_spread", 6.0)))
	for side in [["L", 1.0], ["R", -1.0]]:
		var ua := _bone(sk, "upperarm." + side[0])
		var fa := _bone(sk, "forearm." + side[0])
		if ua < 0 or fa < 0:
			continue
		var d := sk.get_bone_global_pose(fa).origin - sk.get_bone_global_pose(ua).origin
		var now := atan2(d.x * side[1], -d.y)
		_turn(sk, "upperarm." + side[0], Vector3.BACK, (spread - now) * side[1] * k)


## Listening: the neck swings the head round toward the sound and tips it further over its ear. The
## head does not point its face at you: it points an ear.
func _cock(sk: Skeleton3D, amt: float) -> void:
	var yaw := clampf(listen_yaw, -1.3, 1.3)
	for bn in LOOK_SHARE:
		_turn(sk, bn, Vector3.UP, yaw * float(LOOK_SHARE[bn]) * amt)
	_turn(sk, "neck", Vector3.RIGHT, 0.10 * amt)
	_turn(sk, "head", Vector3.BACK, -0.22 * amt)
