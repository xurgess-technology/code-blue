extends Node3D
## A downed surgeon lying on the OR's player table, for the stitches step (docs/CONTRACTS.md,
## "Downed players"). The same surface as scripts/patient_body.gd, as far as a minigame needs it.
##
## Frame: lying on its back along local X, head toward -X, feet toward +X, origin at the table top
## centre. Sites: `gash`, a laceration across the belly (+Y out of the skin, X along the body and
## along the gash, Z across it), and -- GRAFTING chunk C -- `eye`, the LEFT eyeball in its socket,
## for Eyeball Grafting on a strapped surgeon.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const HumanModel := preload("res://scripts/human/human_model.gd")   # HUMAN HOOK
const GraftEye := preload("res://scripts/grafting/graft_eye.gd")   # GRAFTING chunk C

const GASH_POS := Vector3(-0.2, 0.24, 0.04)
const GASH_HALF_LEN := 0.1
const GASH_HALF_GAP := 0.016
## GRAFTING chunk C: how far the left eye sits from the eyes' site (the body's left is model -X),
## and the eyeball's radius on a surgeon.
const EYE_SIDE := 0.033
const EYE_RADIUS := 0.0135

var player_id: int = 0
var ailment_id := "stitches"
var colour := Color("3d8f80")

var rig: Node3D
var _torso: Node3D
var _gash: Node3D
var _scar: Node3D
var _skin_blood: Decal
var _pool: Decal
var _sites := {}
var _flags := {}
var _vitals := 100.0
var _flat := false
var _t := 0.0
var _jolt := 0.0
var _jolt_v := 0.0
var _bleed := 0.0
var _bleed_cur := 0.0
var _pool_amt := 0.0
var _gash_shown := true
# HUMAN HOOK: the Blender surgeon lying on the table (null on the primitive fallback).
var _human: Node3D = null
var _skel: Skeleton3D = null
var _lying: Animation = null
var _gash_mesh: MeshInstance3D = null
var _gash_open := 1.0
var _idle_t := 0.0
## GRAFTING chunk C: the parts a minigame may reach for, the left eyeball, and what is in the socket.
var parts := {}
var _eye_l: MeshInstance3D = null
var _graft_eye: Node3D = null
var _eye_kind := ""      # "" the surgeon's own, "eye_hive" a grafted Hive eye
var _eye_out := false    # the socket is empty (between the scoop and the seat)
## Tools and A/B: build the primitive body.
static var primitive_only := false


static func create(for_player: int, scrubs: Color) -> Node3D:
	var b = load("res://scripts/downed/player_body.gd").new()
	b.player_id = for_player
	b.colour = scrubs
	b.name = "PlayerBody_%d" % for_player
	b._build()
	return b


func _build() -> void:
	rig = Node3D.new()
	rig.name = "Rig"
	add_child(rig)
	if not primitive_only and _build_human():   # HUMAN HOOK
		return
	var scrubs := StandardMaterial3D.new()
	scrubs.albedo_color = colour
	scrubs.roughness = 0.9
	var skin := Kit.mat("downed_skin", Color(0.62, 0.45, 0.36), 0.7)
	var hair := Kit.mat("downed_hair", Color(0.13, 0.1, 0.08), 0.9)
	var shoe := Kit.mat("downed_shoe", Color(0.12, 0.12, 0.13), 0.6)

	_torso = Node3D.new()
	_torso.name = "Torso"
	rig.add_child(_torso)
	# Torso: a flattened capsule along X, belly up.
	var torso := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.17
	cap.height = 0.7
	cap.radial_segments = 16
	cap.rings = 6
	torso.mesh = cap
	torso.material_override = scrubs
	torso.rotation_degrees = Vector3(0, 0, 90)
	torso.scale = Vector3(0.68, 1.0, 1.08)
	torso.position = Vector3(-0.27, 0.12, 0.0)
	_torso.add_child(torso)
	# Scrub top rolled up over the wound: bare skin round the belly.
	Kit.add_mesh(_torso, Kit.box(Vector3(0.3, 0.02, 0.22)), skin, Transform3D(Basis(), Vector3(GASH_POS.x, GASH_POS.y - 0.011, GASH_POS.z * 0.6)), "Belly")
	# Head and cap
	Kit.add_mesh(rig, Kit.sphere(0.105, 14, 8), skin, Transform3D(Basis(), Vector3(-0.8, 0.11, 0.0)), "Head")
	Kit.add_mesh(rig, Kit.sphere(0.108, 12, 6), hair, Transform3D(Basis().scaled(Vector3(0.9, 0.55, 1.0)), Vector3(-0.84, 0.13, 0.0)), "Hair")
	Kit.add_mesh(rig, Kit.cyl(0.045, 0.05, 0.1), skin, Transform3D(Basis(Vector3(0, 0, 1), PI / 2), Vector3(-0.67, 0.1, 0.0)), "Neck")
	# Arms along the sides
	for side in [-1.0, 1.0]:
		var arm := Kit.add_mesh(rig, Kit.cyl(0.048, 0.04, 0.62), scrubs if side > 0 else scrubs, Transform3D(Basis(Vector3(0, 0, 1), PI / 2), Vector3(-0.3, 0.07, side * 0.235)), "Arm")
		arm.material_override = scrubs
		Kit.add_mesh(rig, Kit.sphere(0.045, 8, 5), skin, Transform3D(Basis(), Vector3(0.04, 0.06, side * 0.235)), "Hand")
		# Legs
		Kit.add_mesh(rig, Kit.cyl(0.075, 0.055, 0.82), scrubs, Transform3D(Basis(Vector3(0, 0, 1), PI / 2), Vector3(0.49, 0.08, side * 0.1)), "Leg")
		Kit.add_mesh(rig, Kit.box(Vector3(0.08, 0.13, 0.09)), shoe, Transform3D(Basis(), Vector3(0.92, 0.1, side * 0.1)), "Shoe")

	# The gash: a dark split with raw edges, and a scar with stitches for afterwards.
	_gash = Node3D.new()
	_gash.name = "Gash"
	_gash.position = GASH_POS
	_torso.add_child(_gash)
	var flesh := Kit.flesh_mat()
	var dark := Kit.mat("downed_gash_core", Color(0.12, 0.0, 0.01), 0.3)
	Kit.add_mesh(_gash, Kit.box(Vector3(GASH_HALF_LEN * 2.0, 0.004, GASH_HALF_GAP * 2.0)), flesh, Transform3D(Basis(), Vector3(0, 0.001, 0)), "Edges")
	Kit.add_mesh(_gash, Kit.box(Vector3(GASH_HALF_LEN * 1.8, 0.005, GASH_HALF_GAP * 0.9)), dark, Transform3D(Basis(), Vector3(0, 0.002, 0)), "Core")
	_scar = Node3D.new()
	_scar.name = "Scar"
	_scar.position = GASH_POS
	_scar.visible = false
	_torso.add_child(_scar)
	var scar_mat := Kit.mat("downed_scar", Color(0.55, 0.22, 0.2), 0.6)
	var thread := Kit.mat("downed_thread", Color(0.08, 0.06, 0.12), 0.7)
	Kit.add_mesh(_scar, Kit.box(Vector3(GASH_HALF_LEN * 2.0, 0.003, 0.004)), scar_mat, Transform3D(Basis(), Vector3(0, 0.001, 0)), "Line")
	for i in 6:
		var x := lerpf(-GASH_HALF_LEN * 0.75, GASH_HALF_LEN * 0.75, i / 5.0)
		Kit.add_mesh(_scar, Kit.box(Vector3(0.003, 0.004, 0.022)), thread, Transform3D(Basis(Vector3.UP, 0.35 if i % 2 == 0 else -0.35), Vector3(x, 0.003, 0)), "Stitch")

	_skin_blood = Kit.decal(_torso, Kit.blood_tex(), Vector3(0.22, 0.2, 0.2), Transform3D(Basis(), GASH_POS))
	_skin_blood.visible = false
	_pool = Kit.decal(self, Kit.blood_tex(), Vector3(0.3, 0.1, 0.25), Transform3D(Basis(Vector3.UP, 0.6), Vector3(-0.2, 0.0, 0.3)))
	_pool.visible = false

	_sites["gash"] = Transform3D(Basis(), GASH_POS + Vector3(0, 0.006, 0))
	_sites["injection"] = Transform3D(Basis(), Vector3(-0.05, 0.12, 0.235))
	_apply_visuals()


# -- the patient-body surface a minigame may use ----------------------------------------------------

func set_ailment(id: String) -> void:
	ailment_id = id
	_apply_visuals()


func has_site(site: String) -> bool:
	return _sites.has(site)


func site_transform(site: String) -> Transform3D:
	var local: Transform3D = _sites.get(site, Transform3D(Basis(), Vector3(0, 0.3, 0)))
	var rig_xf := rig.transform if rig != null else Transform3D()
	return (global_transform if is_inside_tree() else transform) * rig_xf * local


## For the gash: {half_len: metres along X, half_gap: how far apart the edges start}. {} elsewhere.
func site_section(site: String) -> Dictionary:
	if site == "gash":
		return {"half_len": half_len(), "half_gap": GASH_HALF_GAP}
	return {}


## GRAFTING chunk C: what sits in the left socket -- "" the surgeon's own eye, "eye_hive" a grafted
## Hive eye, and `out` while the socket is empty (between the scoop and the seat).
func set_eye(kind: String, out := false) -> void:
	_eye_kind = kind
	_eye_out = out
	_apply_eye()


var _eye_key := "?"


## Idempotent and cheap: only rebuilds when what is in the socket actually changed. The minigame's
## `eye_hidden` meta (the scoop and the seat draw their own eye) is polled here every frame.
func _apply_eye() -> void:
	if _eye_l == null or not is_instance_valid(_eye_l):
		return
	var hidden: bool = _eye_out or bool(get_meta("eye_hidden", false))
	var key := "%s|%s" % [_eye_kind, hidden]
	if key == _eye_key:
		return
	_eye_key = key
	_eye_l.visible = not hidden and _eye_kind == ""
	if _graft_eye != null and is_instance_valid(_graft_eye):
		_graft_eye.queue_free()
		_graft_eye = null
	if hidden or _eye_kind == "":
		return
	_graft_eye = GraftEye.build(_eye_l, _eye_kind, EYE_RADIUS)


func infection_start(_site: String) -> float:
	return INF


func make_severed_limb(_parent: Node) -> Node3D:
	return null


func set_vitals(v: float) -> void:
	_vitals = clampf(v, 0.0, 100.0)


func set_sedation(_s: float) -> void:
	pass


func stir(strength: float) -> void:
	if _flat:
		return
	_jolt_v += clampf(strength, 0.0, 1.5) * 6.0


func set_bleeding(site: String, amount: float) -> void:
	if site == "gash":
		_bleed = clampf(amount, 0.0, 1.0)


## Replaces the flag set. "stitched" shows the closed scar.
func apply_flags(flags: Dictionary) -> void:
	_flags = flags.duplicate()
	_apply_visuals()


func flatline() -> void:
	_flat = true
	_vitals = 0.0


## The stitches minigame draws its own wound while it runs and hides this one.
func show_gash(on: bool) -> void:
	_gash_shown = on
	_apply_visuals()


## HUMAN HOOK: how open the gash is, 1 fresh .. 0 closed (the stitches step drives it as it closes).
func set_gash_open(f: float) -> void:
	_gash_open = clampf(f, 0.0, 1.0)
	_apply_visuals()


func _apply_visuals() -> void:
	# GRAFTING chunk C: a graft is on the face, so the scrub top stays down and the belly is covered.
	if _human != null:
		var belly: bool = ailment_id != "eye_graft"
		HumanModel.show_piece(_human, "Human_TopLower", not belly)
		HumanModel.show_piece(_human, "Human_TopRolled", belly)
		HumanModel.show_piece(_human, "Human_GashSkin", belly)
		if not belly:
			if _gash != null:
				_gash.visible = false
			if _scar != null:
				_scar.visible = false
			if _skin_blood != null:
				_skin_blood.visible = false
			return
	var stitched := bool(_flags.get("stitched", false))
	if _human != null:
		var open := 0.0 if stitched else _gash_open
		if _gash_mesh != null and _gash_mesh.get_blend_shape_count() > 0:
			_gash_mesh.set_blend_shape_value(0, open)
		var sm := HumanModel.skin_of(_human)
		if sm != null:
			sm.set_shader_parameter(&"gash", open if _gash_shown or open > 0.0 else 0.0)
	if _gash != null:
		_gash.visible = _gash_shown and not stitched
	if _scar != null:
		_scar.visible = _gash_shown and stitched


func _process(delta: float) -> void:
	_apply_eye()   # GRAFTING chunk C: the socket follows the case and the minigame's own eye
	delta = minf(delta, 0.1)
	_t += delta
	var v01 := _vitals / 100.0
	# Shallow, quick breaths as the bleed runs on; none when flat.
	var rate := lerpf(0.9, 0.3, v01)
	var br := 0.0 if _flat else (0.5 - 0.5 * cos(_t * TAU * rate)) * lerpf(0.4, 1.0, v01)
	if _torso != null:
		_torso.scale = Vector3(1.0, 1.0 + br * 0.05, 1.0 + br * 0.02)
	if _skel != null and _lying != null:
		# HUMAN HOOK: the Lying clip's breath, faster and shallower as the bleed runs on
		if not _flat:
			_idle_t = fposmod(_idle_t + delta * lerpf(1.4, 0.45, v01), 3.0)
		HumanModel.sample_clip(_skel, _lying, _idle_t)
	_jolt_v += (-110.0 * _jolt - 9.0 * _jolt_v) * delta
	_jolt += _jolt_v * delta
	if rig != null:
		rig.position = Vector3(0.0, absf(_jolt) * 0.012, _jolt * 0.004)
	_bleed_cur = move_toward(_bleed_cur, _bleed, delta * 0.5)
	if _skin_blood != null:
		var stitched := bool(_flags.get("stitched", false))
		_skin_blood.visible = _bleed_cur > 0.02 or (_gash_shown and not stitched)
		var s := lerpf(0.12, 0.3, _bleed_cur)
		_skin_blood.size = Vector3(s * 1.3, 0.2, s)
		_skin_blood.modulate = Color(1, 1, 1, 0.3 if stitched else clampf(0.35 + _bleed_cur, 0.0, 1.0))
	if _bleed_cur > 0.05 and not _flat:
		_pool_amt = minf(1.0, _pool_amt + delta * _bleed_cur * 0.05)
	if _pool != null:
		_pool.visible = _pool_amt > 0.01
		var ps := lerpf(0.08, 0.5, sqrt(_pool_amt))
		_pool.size = Vector3(ps, 0.1, ps * 0.8)


# -- HUMAN HOOK: the Blender surgeon ------------------------------------------------------------------

func _build_human() -> bool:
	var variant := HumanModel.surgeon_for(player_id)
	var root: Node3D = HumanModel.spawn(variant, colour, true)
	if root == null:
		return false
	var skel := HumanModel.skeleton(root)
	var ap := HumanModel.anim_player(root)
	var site := root.find_child("Site_gash", true, false) as Node3D
	var lying: Animation = ap.get_animation("Lying") if ap != null and ap.has_animation("Lying") else null
	var gash := HumanModel.piece(root, "Human_GashSkin")
	if skel == null or lying == null or site == null or gash == null:
		root.free()
		return false
	ap.active = false
	rig.add_child(root)
	_human = root
	_skel = skel
	_lying = lying
	_gash_mesh = gash
	HumanModel.show_piece(root, "Human_TopLower", false)
	HumanModel.show_piece(root, "Human_TopRolled", true)
	HumanModel.show_piece(root, "Human_GashSkin", true)
	# Lying frame 0: back on the origin, head toward model -Z; yaw 180 then -90 puts the head at -X.
	root.rotation.y = -PI * 0.5
	HumanModel.sample_clip(skel, lying, 0.0)
	var to_rig := HumanModel.chain_to(skel, rig)
	var crown: Vector3 = to_rig * HumanModel.bone_global(skel, skel.find_bone("head")).origin
	var toe: Vector3 = to_rig * HumanModel.bone_global(skel, skel.find_bone("toe.L")).origin
	root.position.x = -((crown.x - 0.20) + toe.x) * 0.5
	to_rig = HumanModel.chain_to(skel, rig)
	var att := site.get_parent() as BoneAttachment3D
	var bone_xf := HumanModel.bone_global(skel, skel.find_bone(att.bone_name))
	var xf: Transform3D = to_rig * bone_xf * site.transform
	var x := Vector3(1, 0, 0)
	var y := Vector3.UP
	var gxf := Transform3D(Basis(x, y, x.cross(y)), xf.origin)
	_sites["gash"] = gxf
	# GRAFTING chunk C: the left eye, from the eyes' site on the head bone (the body's left is -X of
	# the model, which lying along the table is +Z here). The eyeball is skinned, so its own node
	# transform says nothing about where it ends up: the bone does.
	var eyes_site := root.find_child("Site_eyes", true, false) as Node3D
	if eyes_site != null:
		var ea := eyes_site.get_parent() as BoneAttachment3D
		var e_bone := HumanModel.bone_global(skel, skel.find_bone(ea.bone_name))
		var exf: Transform3D = to_rig * e_bone * eyes_site.transform
		# The model's -X (its left) after the quarter turn onto the table: take it from the basis.
		var left: Vector3 = (to_rig * e_bone).basis.orthonormalized() * Vector3.LEFT
		_sites["eye"] = Transform3D(Basis(x, y, x.cross(y)), exf.origin + left * EYE_SIDE)
	_eye_l = HumanModel.piece(root, "Human_Eye_L")
	parts["eye_l"] = _eye_l
	var inj := root.find_child("Site_injection", true, false) as Node3D
	if inj != null:
		var ia := inj.get_parent() as BoneAttachment3D
		var ixf: Transform3D = to_rig * HumanModel.bone_global(skel, skel.find_bone(ia.bone_name)) * inj.transform
		_sites["injection"] = Transform3D(Basis(x, y, x.cross(y)), ixf.origin)
	# The gash anchor follows the spine; the scar (stitched) hangs off it.
	var anchor := Node3D.new()
	anchor.name = "GashAnchor"
	att.add_child(anchor)
	anchor.transform = (to_rig * bone_xf).affine_inverse() * gxf
	_gash = Node3D.new()
	_gash.name = "Gash"
	anchor.add_child(_gash)
	_scar = Node3D.new()
	_scar.name = "Scar"
	_scar.visible = false
	anchor.add_child(_scar)
	var scar_mat := Kit.mat("downed_scar", Color(0.45, 0.16, 0.14), 0.6)
	var thread := Kit.mat("downed_thread", Color(0.08, 0.06, 0.12), 0.7)
	Kit.add_mesh(_scar, Kit.box(Vector3(half_len() * 2.0, 0.002, 0.004)), scar_mat, Transform3D(Basis(), Vector3(0, 0.001, 0)), "Line")
	for i in 6:
		var sx := lerpf(-half_len() * 0.75, half_len() * 0.75, i / 5.0)
		Kit.add_mesh(_scar, Kit.box(Vector3(0.003, 0.004, 0.022)), thread, Transform3D(Basis(Vector3.UP, 0.35 if i % 2 == 0 else -0.35), Vector3(sx, 0.003, 0)), "Stitch")
	_skin_blood = Kit.decal(anchor, Kit.blood_tex(), Vector3(0.22, 0.2, 0.2), Transform3D())
	_skin_blood.visible = false
	_pool = Kit.decal(self, Kit.blood_tex(), Vector3(0.3, 0.1, 0.25), Transform3D(Basis(Vector3.UP, 0.6), Vector3(gxf.origin.x, 0.0, 0.3)))
	_pool.visible = false
	_apply_visuals()
	return true


func half_len() -> float:
	return 0.096 * HumanModel.HEIGHTS.get(HumanModel.surgeon_for(player_id), 1.78) / 1.78 if _human != null else GASH_HALF_LEN
