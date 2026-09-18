extends SkeletonModifier3D
## The Sonographer's stylized model (`monster/sonographer`, art/stylized variant `sonographer`) on a
## monster model. **The monster and its ultrasound cart are one entity and one model**, on the same
## skeleton: the cart hangs off a pivot bone at the right hand, and each castor has its own bone.
##
## `build(model)` spawns the GLB under the MonsterModel, points the model's `rig`, `skeleton` and
## `anim` at it, adds this modifier to its skeleton and hangs a node named `Head` on the head bone in
## the model's own axes (+Y up, +Z its face), the way the Hive does. It also:
##   - takes the two ear pieces (Human_Ear_L / _R) off the mesh and re-hangs each one under a pivot at
##     its Site_ear_*, so MonsterModel.set_ears can swivel them toward a sound;
##   - puts the glow shader on the windpipe (Human_Throat) behind the thin skin of the throat
##     (Human_ThroatSkin, which goes translucent), and a small cold light in the neck;
##   - draws the pump line from the cart's outlet (Site_pump) into the nape of the neck (Site_cable),
##     short and always in the same place, with the charge travelling down it to the cart;
##   - hangs markers for the cart's one collision box (Site_cart_box, on the pivot) and for where an
##     echo leaves from (Site_echo, on the head, because the echo fires where the head points).
##
## Clips (Assets anims): SonoIdle, SonoDrag (the sideways drag-walk, 0.95 m/s), SonoListen,
## SonoCharge, SonoEcho, SonoTurn (swinging round to rush), SonoRush (3.1 m/s), SonoWail,
## SonoStagger, SonoLying. The monster picks the clip and the rate; this modifier adds the poses
## there are no clips for, on top of whatever the clip left.
##
## It stands in for rig_shaper.gd: `model.shaper` points here, so monster.gd, the stun window and the
## dissection table set the same inputs they give every other monster:
##   lying, daze, rise, stagger, twitch, listen, listen_yaw, lunge   (see hive_rig.gd)
## and the look interface it adds is documented on MonsterModel.set_sono_look (docs/CONTRACTS.md).
##
## Every value is in skeleton space (+Y up, +Z its front, +X its left).

const Shapes := preload("res://scripts/monsters/shapes.gd")

const KEY := "monster/sonographer"
## Ground speeds the drag and rush clips were authored at (art/stylized/st_sono_clips.py).
const DRAG_SPEED := 0.95
const RUSH_SPEED := 3.10
## The cart's resting pivot angles, in radians: 0 out at its right where it was built (dragging),
## CART_BEHIND swung round behind the hand with its handle pointing back at the body (rushing).
## Chunk B eases between them a beat after the body turns: that is the trailer swing.
const CART_BEHIND := -1.50
const GLOW := Color(0.30, 0.78, 1.0)
const GLOW_SHADER := "res://shaders/sono_glow.gdshader"
const LINE_SEGS := 8
const CART_BONE := "cart_pivot"
const CASTOR_BONES := ["castor_fl", "castor_fr", "castor_bl", "castor_br"]
## The castor that squeaks (art/stylized: its fork is bent, so it sits askew).
const SQUEAKY := "castor_br"
const CASTOR_R := 0.046
## Half extents of the cart's one collision box, centred on the CartBox marker. Chunk B builds the
## body from it; nothing here touches physics.
const CART_BOX := Vector3(0.26, 0.60, 0.22)
## The cart's pieces in the GLB: they hide together, and a copy of them is what is left standing
## when the Sonographer goes down.
const CART_PIECES := ["Human_Cart", "Human_CartScreen", "Human_Castor_FL", "Human_Castor_FR",
	"Human_Castor_BL", "Human_Castor_BR"]

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
## is charged, which mode it is in, how far round the cart is swung on its pivot, and whether the
## pump line is still plugged into its neck.
var suspicion := 0.0
var charge := 0.0
var mode := "idle"
var cart_angle := 0.0
var plugged := true
## How fast the cart is being dragged (m/s): the castors roll with it and it jostles a little.
var cart_speed := 0.0
## World position the head looks at while `listen` > 0 (set by whoever drives it).
var look_target := Vector3.ZERO
## Where the eyes would have been, in the Head node's frame; set from the model's Site_eyes.
var eye_offset := Vector3(0.0, 0.10, 0.09)
## World positions of the hands after this frame's pose.
var hand_left := Vector3.ZERO
var hand_right := Vector3.ZERO

var _b := {}
var _rest_fwd := Vector3.BACK
var _rest_up := Vector3.UP
var _throat: ShaderMaterial = null
var _pane: StandardMaterial3D = null
var _screen: StandardMaterial3D = null
var _light: OmniLight3D = null
var _nape: Node3D = null
var _pump: Node3D = null
var _echo: Node3D = null
var _box: Node3D = null
var _line: Array = []
var _line_mats: Array = []
var _cart_pieces: Array = []
var _shown := -1.0
var _pulse := -1.0
var _spin := 0.0
var _screen_t := 0.0

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
		for n in ["SonoIdle", "SonoDrag", "SonoListen", "SonoRush", "SonoLying"]:
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
	_screen = _screen_material(root)
	for p in CART_PIECES:
		var mi := root.find_child(p, true, false) as MeshInstance3D
		if mi != null:
			_cart_pieces.append(mi)
	_nape = _marker(root, sk, "Site_cable", "neck", "NapeSocket", Vector3(0.0, 0.0, -0.06))
	_pump = _marker(root, sk, "Site_pump", CART_BONE, "PumpOutlet", Vector3(0.0, 0.5, 0.0))
	_echo = _marker(root, sk, "Site_echo", "head", "EchoOrigin", Vector3(0.0, 0.1, 0.1))
	_box = _marker(root, sk, "Site_cart_box", CART_BONE, "CartBox", Vector3(0.0, 0.5, 0.0))
	_pump_line(model)
	_set_glow(0.0)


## A node riding `bone` at the GLB's `site`, or at `fallback` in the bone's frame when it is missing.
func _marker(root: Node3D, sk: Skeleton3D, site: String, bone: String, node_name: String, fallback: Vector3) -> Node3D:
	var ba := BoneAttachment3D.new()
	ba.name = node_name + "Bone"
	ba.bone_name = bone
	sk.add_child(ba)
	var n := Node3D.new()
	n.name = node_name
	var at := root.find_child(site, true, false) as Node3D
	if at != null:
		n.transform = at.transform
	else:
		n.position = fallback
	ba.add_child(n)
	return n


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
		# the whole windpipe lights at once: nothing travels along it (that is the line's job)
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


## The cart's monitor: the screen is simply on, a dim grey glow with nothing on it.
func _screen_material(root: Node3D) -> StandardMaterial3D:
	var mi := root.find_child("Human_CartScreen", true, false) as MeshInstance3D
	if mi == null:
		return null
	var m := StandardMaterial3D.new()
	var src := mi.get_active_material(0) as BaseMaterial3D
	if src != null:
		m.albedo_texture = src.albedo_texture
	m.albedo_color = Color("20272b")
	m.emission_enabled = true
	m.emission = Color("7f8f96")
	m.emission_energy_multiplier = 0.55
	m.roughness = 0.25
	mi.material_override = m
	return m


## The pump line: short, from the cart's outlet up into the nape of the neck. Both ends ride bones
## that keep the same relation in every clip, so the run is always the same shape and never clips.
func _pump_line(model: Node3D) -> void:
	var shader := load(GLOW_SHADER) as Shader
	for seg in LINE_SEGS:
		var m := ShaderMaterial.new()
		m.shader = shader
		m.set_shader_parameter("use_tex", false)
		m.set_shader_parameter("base_color", Color("3b4046"))
		m.set_shader_parameter("glow", GLOW)
		m.set_shader_parameter("idle_energy", 0.10)
		m.set_shader_parameter("full_energy", 5.0)
		m.set_shader_parameter("roughness_v", 0.5)
		# t runs 0 at the nape to 1 at the cart, continuously across the segments
		m.set_shader_parameter("t_scale", 1.0 / float(LINE_SEGS))
		m.set_shader_parameter("t_offset", (float(seg) + 0.5) / float(LINE_SEGS))
		var c: MeshInstance3D = Shapes.cylinder(0.017, 1.0, m, Vector3.ZERO, -1.0, 6)
		c.name = "PumpLine%d" % seg
		# stretched between two world points every frame, so it must not inherit the model's transform
		c.top_level = true
		model.add_child(c)
		_line.append(c)
		_line_mats.append(m)


# ====================================================================== the look interface
## `mode` is one of idle, suspicious, charging, echo, turning, rush, wail, stagger, lying.
## `angle` is how far round the cart is swung on its pivot (radians; 0 dragging, CART_BEHIND rushing).
func set_look(susp: float, chg: float, m: String, angle: float, plug: bool) -> void:
	suspicion = clampf(susp, 0.0, 1.0)
	charge = clampf(chg, 0.0, 1.0)
	mode = m
	cart_angle = angle
	plugged = plug
	_set_glow(maxf(charge, suspicion * 0.30))
	# unplugged (sedated, killed) or on the table: the cart is gone from the model, and chunk B has
	# left a copy of it standing where it was
	set_cart_visible(plug and m != "lying")


## Show or hide the cart on the model. `make_cart` is the copy that stays behind.
func set_cart_visible(on: bool) -> void:
	for mi in _cart_pieces:
		(mi as MeshInstance3D).visible = on
	for c in _line:
		(c as MeshInstance3D).visible = on and plugged


func cart_visible() -> bool:
	return not _cart_pieces.is_empty() and (_cart_pieces[0] as MeshInstance3D).visible


## A standalone copy of the cart, standing exactly where it is this frame, for chunk B to turn into
## smoke. Plain meshes at the transforms the cart bones have now: nothing about it moves any more.
func make_cart() -> Node3D:
	var out := Node3D.new()
	out.name = "SonoCartCopy"
	out.top_level = true
	var sk := get_skeleton()
	if sk == null:
		return out
	for mi in _cart_pieces:
		var src := mi as MeshInstance3D
		var bone := CART_BONE
		for cb in CASTOR_BONES:
			if src.name.to_lower().ends_with(cb.substr(cb.length() - 2)):
				bone = cb
		var bi := _bone(sk, bone)
		if bi < 0:
			continue
		var copy := MeshInstance3D.new()
		copy.name = src.name + "Copy"
		copy.mesh = src.mesh
		copy.material_override = src.material_override
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# the mesh's vertices are in the skeleton's space, and one bone each poses them
		copy.transform = sk.global_transform * sk.get_bone_global_pose(bi) * sk.get_bone_global_rest(bi).affine_inverse()
		out.add_child(copy)
	return out


## Where an echo leaves from, and which way it points: the head, not the chest. Its -Z is the way the
## face is pointing (the Head node's convention).
func echo_origin() -> Transform3D:
	return _echo.global_transform if _echo != null else global_transform


## The one box the cart needs for collision: the node it rides on and its half extents.
func cart_box() -> Dictionary:
	return {"node": _box, "half": CART_BOX}


## Where the pump line plugs into the nape of its neck, in world space.
func cable_point() -> Vector3:
	return _nape.global_position if _nape != null else global_position


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


# ====================================================================== every frame
## Called by MonsterModel: the castors roll, the screen breathes, and the charge runs down the line.
func tick(delta: float) -> void:
	_spin += cart_speed / CASTOR_R * delta
	if _screen != null:
		_screen_t += delta
		_screen.emission_energy_multiplier = 0.50 + 0.08 * sin(_screen_t * 1.7) + 0.03 * sin(_screen_t * 11.0)
	var level := maxf(charge, suspicion * 0.35)
	if level > 0.02 and plugged:
		_pulse = fposmod(_pulse + delta * (0.9 + 2.4 * level), 1.35) if _pulse >= 0.0 else 0.0
		if _pulse > 1.0:
			_pulse = -1.0
	else:
		_pulse = -1.0
	for m in _line_mats:
		(m as ShaderMaterial).set_shader_parameter("level", level if plugged else 0.0)
		(m as ShaderMaterial).set_shader_parameter("pulse_at", _pulse if plugged else -1.0)
	_draw_line()


func _draw_line() -> void:
	if _line.is_empty() or _nape == null or _pump == null:
		return
	if not plugged or not cart_visible():
		for c in _line:
			(c as MeshInstance3D).visible = false
		return
	var a: Vector3 = _pump.global_position
	var b: Vector3 = _nape.global_position
	var sag := minf(0.14, a.distance_to(b) * 0.18)
	for i in LINE_SEGS:
		(_line[i] as MeshInstance3D).visible = true
		Shapes.stretch_between(_line[i], _curve(b, a, float(i) / LINE_SEGS, sag),
			_curve(b, a, float(i + 1) / LINE_SEGS, sag))


func _curve(top: Vector3, bottom: Vector3, t: float, sag: float) -> Vector3:
	var p := top.lerp(bottom, t)
	p.y -= sag * sin(t * PI)
	return p


# ====================================================================== posing
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


## Turn a bone away from its *rest* orientation by `r`, in skeleton space, whatever the clip did with
## it. The cart lives on this: it has to stay upright and point where the trailer swing says, not
## inherit the hand's roll.
func _set_rest_rotated(sk: Skeleton3D, bone: String, r: Basis) -> void:
	var i := _bone(sk, bone)
	if i < 0:
		return
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis()
	var restb := sk.get_bone_rest(i).basis.orthonormalized()
	var grest := sk.get_bone_global_rest(i).basis.orthonormalized()
	sk.set_bone_pose_rotation(i, ((pg * restb).inverse() * r * grest).orthonormalized().get_rotation_quaternion())


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
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
	# last, so the cart never inherits any of the above
	_pose_cart(sk)
	_record_hands(sk)


## The cart: upright, swung `cart_angle` round the pivot at the right hand, castors rolling.
func _pose_cart(sk: Skeleton3D) -> void:
	if _bone(sk, CART_BONE) < 0:
		return
	var yaw := Basis(Vector3.UP, cart_angle)
	var jostle := 0.0
	if absf(cart_speed) > 0.05:
		jostle = 0.020 * sin(Time.get_ticks_msec() * 0.011) * clampf(absf(cart_speed) / RUSH_SPEED, 0.0, 1.5)
	_set_rest_rotated(sk, CART_BONE, yaw * Basis(Vector3.RIGHT, jostle) * Basis(Vector3.BACK, jostle * 0.6))
	for cb in CASTOR_BONES:
		_set_rest_rotated(sk, cb, yaw * Basis(Vector3.RIGHT, _spin))


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
const LOOK_SHARE := {"chest": 0.14, "neck": 0.46, "head": 0.40}


func _cock(sk: Skeleton3D, amt: float) -> void:
	var yaw := clampf(listen_yaw, -1.3, 1.3)
	for bn in LOOK_SHARE:
		_turn(sk, bn, Vector3.UP, yaw * float(LOOK_SHARE[bn]) * amt)
	_turn(sk, "neck", Vector3.RIGHT, 0.10 * amt)
	_turn(sk, "head", Vector3.BACK, -0.22 * amt)
