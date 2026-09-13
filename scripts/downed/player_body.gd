extends Node3D
## A downed surgeon lying on the OR's player table, for the stitches step (docs/CONTRACTS.md,
## "Downed players"). The same surface as scripts/patient_body.gd, as far as a minigame needs it.
##
## Frame: lying on its back along local X, head toward -X, feet toward +X, origin at the table top
## centre. One site, `gash`: a laceration across the belly, +Y out of the skin, X along the body
## (and along the gash), Z across it.

const Kit := preload("res://scripts/patients/patient_kit.gd")

const GASH_POS := Vector3(-0.2, 0.24, 0.04)
const GASH_HALF_LEN := 0.1
const GASH_HALF_GAP := 0.016

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
		return {"half_len": GASH_HALF_LEN, "half_gap": GASH_HALF_GAP}
	return {}


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


func _apply_visuals() -> void:
	var stitched := bool(_flags.get("stitched", false))
	if _gash != null:
		_gash.visible = _gash_shown and not stitched
	if _scar != null:
		_scar.visible = _gash_shown and stitched


func _process(delta: float) -> void:
	delta = minf(delta, 0.1)
	_t += delta
	var v01 := _vitals / 100.0
	# Shallow, quick breaths as the bleed runs on; none when flat.
	var rate := lerpf(0.9, 0.3, v01)
	var br := 0.0 if _flat else (0.5 - 0.5 * cos(_t * TAU * rate)) * lerpf(0.4, 1.0, v01)
	if _torso != null:
		_torso.scale = Vector3(1.0, 1.0 + br * 0.05, 1.0 + br * 0.02)
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
