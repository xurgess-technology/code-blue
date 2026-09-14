extends RefCounted
## A strapped monster on a patient table: the PatientBody builder for `walk_in` and `discharged`
## (PatientBody.create dispatches here). Same builder interface as scripts/patients/*_builder.gd:
## build(b), animate(b, jolt, env, fidget, twitch, t), set_limb_removed(b, removed),
## make_severed_limb(b, parent), plus skull_cap_rest(b) for the saw's skull variant.
##
## Frame (PatientBody): lying along X, head toward -X, face up (+Y), back on the table top at y = 0,
## centred on the origin. Sites: `injection` (upper arm), `skull` (the craniotomy line across the
## forehead: +Y out of the head along the cut plane, X toward the cap, the line along Z) and `brain`
## (the centre of the opening: +Y out of the opening, X back toward the table, Z ear to ear).
##
## The look below the neck comes from `make_lying(kind)` (the monsters worker's still lying copy,
## on Monster or on scripts/monsters/monster_model.gd) when it exists; its head is hidden and this
## file's own head, which can be opened, sits in its place. Without it the whole body is primitives.
##
## State read from the body every frame (flags replace, see PatientBody.apply_flags):
## `skull_open` (cap lies beside the head, the brain shows), `brain_removed` (empty cavity),
## sedation (b._sedation): under 0.75 twitches, under 0.35 thrashes against the straps.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const Head := preload("res://scripts/dissection/monster_head.gd")

const AWAKE := 0.35
const STIR := 0.75

## Per kind: body length, head radii, widths, colours.
const LOOKS := {
	"walk_in": {
		"length": 1.74, "head": Vector3(0.14, 0.125, 0.112), "width": 1.0, "thin": 1.0,
		"skin": Color(0.5, 0.55, 0.38), "scalp": Color(0.14, 0.12, 0.1), "hair": 0.9,
		"gown": Color(0.34, 0.56, 0.6), "gown_dark": Color(0.28, 0.32, 0.2), "eyeless": false,
		"ear": 1.0, "brain_scale": 1.0,
	},
	"discharged": {
		"length": 1.96, "head": Vector3(0.145, 0.12, 0.104), "width": 0.9, "thin": 0.82,
		"skin": Color(0.58, 0.56, 0.55), "scalp": Color(0.45, 0.43, 0.42), "hair": 0.0,
		"gown": Color(0.52, 0.5, 0.4), "gown_dark": Color(0.26, 0.2, 0.14), "eyeless": true,
		"ear": 1.45, "brain_scale": 1.0,
	},
}

static var _vc_mats := {}


static func look_of(id: String) -> Dictionary:
	return LOOKS.get(id, LOOKS["walk_in"])


static func build(b) -> bool:
	var id: String = b.patient_id
	var lk := look_of(id)
	var rig: Node3D = b.rig
	var L: float = lk.length
	var hr: Vector3 = lk.head
	var w: float = lk.width
	var seed_v: int = hash(id) & 0xffff
	b.breath_amp = 0.0

	var lying: Node3D = _make_lying(id)
	var own_body := lying == null
	var parts: Dictionary = b.parts
	parts["kind"] = id

	# --- head (always ours: it opens) ------------------------------------------------------------
	var head_c := Vector3(-L * 0.5 + hr.x + 0.005, hr.y + 0.012, 0.0)
	var neck := Node3D.new()
	neck.name = "Neck"
	neck.position = head_c + Vector3(hr.x * 0.8, -hr.y * 0.3, 0)
	rig.add_child(neck)
	var head := Node3D.new()
	head.name = "HeadRoot"
	head.position = head_c - neck.position
	neck.add_child(head)
	var hd: Dictionary = Head.build(head, hr, {"skin": lk.skin, "scalp": lk.scalp, "hair": lk.hair,
		"eyeless": lk.eyeless, "brain_scale": lk.brain_scale}, seed_v)
	parts["neck"] = neck
	parts["head"] = head
	parts["cap"] = hd.cap
	parts["cap_home"] = (hd.cap as Node3D).transform
	parts["open_skull"] = hd.rim
	parts["brain"] = hd.brain
	parts["cut"] = hd.info
	parts["brain_radii"] = hd.brain_radii
	# The face is laid out for a 0.112 m head and scaled up to this one.
	var fk := hr.x / 0.112
	var face_root := Node3D.new()
	face_root.name = "Face"
	face_root.scale = Vector3.ONE * fk
	head.add_child(face_root)
	var face := _face(face_root, hr / fk, lk, seed_v)
	parts["jaw"] = face.get("jaw")

	# --- body ---------------------------------------------------------------------------------------
	var dims := {"L": L, "w": w, "thin": float(lk.thin), "head_c": head_c, "hr": hr, "tx": head_c.x + hr.x + 0.02}
	if own_body:
		_primitive_body(b, rig, lk, dims, seed_v)
	else:
		lying.name = "Lying"
		rig.add_child(lying)
		_hide_lying_head(lying, head_c.x + hr.x * 1.1)
		parts["lying"] = lying
	_straps(rig, dims)

	# --- sites -------------------------------------------------------------------------------------
	var info: Dictionary = hd.info
	var m: Vector3 = info.m
	var u: Vector3 = info.u
	var skull_xf := Transform3D(Basis(m, u, m.cross(u)), head_c + (info.top as Vector3))
	var brain_xf := Transform3D(Basis(-u, m, (-u).cross(m)), head_c + (info.centre as Vector3))
	var arm_z := -0.25 * w
	var inj_xf := Transform3D(Basis(), Vector3(-L * 0.5 + 0.52 * L / 1.74, 0.105 * float(lk.thin) + 0.01, arm_z))
	_site(b, "skull", skull_xf, head)
	_site(b, "brain", brain_xf, head)
	_site(b, "injection", inj_xf, rig)
	# The saw reads the section at the cut: the kerf runs across the head, a few centimetres deep.
	b.sections["skull"] = {"half_up": 0.04, "half_side": float(info.half_z) * 0.92, "axis_depth": float(info.half_u), "shape": 2.0}
	# The brain step reads the opening and where the specimen tray stands on the table (site-local).
	var tray_body := Vector3(head_c.x + 0.01, 0.0, -0.21)
	b.sections["brain"] = {"half_up": float((hd.brain_radii as Vector3).y), "half_side": float(info.half_z) * (1.0 - Head.BONE_T),
		"axis_depth": head_c.y + float((info.centre as Vector3).y), "shape": 2.0,
		"half_u": float(info.half_u) * (1.0 - Head.BONE_T), "brain_radii": hd.brain_radii,
		"brain_seed": seed_v, "brain_y": -(float((hd.brain_radii as Vector3).y) * 0.55 + 0.004),
		"tray": brain_xf.affine_inverse() * tray_body, "table_up": brain_xf.basis.inverse() * Vector3.UP}
	b.drips["skull"] = [skull_xf.origin, Vector3(head_c.x - hr.x * 0.9, 0.003, 0.05)]
	b.drips["brain"] = [brain_xf.origin, Vector3(head_c.x - hr.x * 0.9, 0.003, -0.04)]
	b.drips["injection"] = [inj_xf.origin, Vector3(inj_xf.origin.x, 0.003, inj_xf.origin.z - 0.08)]
	# Where the removed cap lies: beside the head, bone side up.
	# The cap's origin is the centre of its cut face and its dome points along the cut direction
	# (135 degrees in XY): turning it another 135 degrees about Z points the dome at the table.
	var flip := Basis(Vector3(0, 0, 1), PI * 0.75) * Basis(Vector3.UP, 0.4)
	parts["cap_rest"] = Transform3D(flip, Vector3(head_c.x + 0.03, float(info.extent) * (1.0 - Head.CUT_K) + 0.004, 0.26 * w + 0.03) - head_c)
	parts["rng"] = RandomNumberGenerator.new()
	(parts["rng"] as RandomNumberGenerator).seed = seed_v
	parts["thrash"] = {"arm_l": 0.0, "arm_l_v": 0.0, "arm_r": 0.0, "arm_r_v": 0.0, "legs": 0.0, "legs_v": 0.0,
		"head": 0.0, "head_v": 0.0, "next": 0.5, "twitch_next": 1.0, "jaw": 0.0}
	return true


static func _site(b, nm: String, xf: Transform3D, follow: Node3D) -> void:
	var a := Node3D.new()
	a.name = nm
	follow.add_child(a)
	# Anchors follow the part the site is on; the rest pose transform is body-local.
	a.transform = (_chain(follow, b.rig)).affine_inverse() * xf
	b.anchors[nm] = a
	b._sites[nm] = xf


static func _chain(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D()
	var cur: Node = n
	while cur != null and cur != root:
		xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## The monsters worker's still lying copy (Monster.make_lying / monster_model.gd make_lying), or null.
static func _make_lying(id: String) -> Node3D:
	for path in ["res://scripts/monster.gd", "res://scripts/monsters/monster_model.gd"]:
		if not ResourceLoader.exists(path):
			continue
		var s := load(path) as GDScript
		if s == null:
			continue
		for mdef in s.get_script_method_list():
			if String(mdef.get("name", "")) == "make_lying":
				var n = s.call("make_lying", id)
				if n is Node3D:
					return n
				return null
	return null


## Hides every mesh of the lying copy that lies entirely beyond `x_limit` toward -X (its head).
static func _hide_lying_head(lying: Node3D, x_limit: float) -> void:
	for mi in lying.find_children("*", "MeshInstance3D", true, false):
		var g := mi as MeshInstance3D
		if g.mesh == null:
			continue
		var xf := _chain(g, lying.get_parent() as Node3D) if lying.get_parent() != null else g.transform
		var bb := xf * g.mesh.get_aabb()
		if bb.end.x < x_limit:
			g.visible = false


static func vc_mat(key: String, rough := 0.85, cull_off := false) -> StandardMaterial3D:
	if _vc_mats.has(key):
		return _vc_mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = rough
	if cull_off:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_vc_mats[key] = m
	return m


# ---------------------------------------------------------------------------------------- face

static func _surface_y(hr: Vector3, x: float, z: float) -> float:
	var k := 1.0 - (x * x) / (hr.x * hr.x) - (z * z) / (hr.z * hr.z)
	return hr.y * sqrt(maxf(0.0, k))


static func _face(head: Node3D, hr: Vector3, lk: Dictionary, seed_v: int) -> Dictionary:
	var skin: Color = lk.skin
	var skin_mat := Kit.mat("mb_skin_%s" % str(skin), skin * 0.95, 0.8)
	var dark := Kit.mat("mb_hollow", Color(0.09, 0.05, 0.06), 0.9)
	var eyeless: bool = lk.eyeless
	var out := {}
	var eye_x := -0.006
	var eye_z := hr.z * 0.4
	if not eyeless:
		# Sunken sockets with small milky eyes staring up.
		var white := Kit.mat("mb_eye", Color(0.8, 0.78, 0.55), 0.3)
		var pupil := Kit.mat("mb_pupil", Color(0.12, 0.08, 0.03), 0.4)
		for sz in [-1.0, 1.0]:
			var y := _surface_y(hr, eye_x, eye_z)
			Kit.add_mesh(head, Kit.sphere(0.022, 12, 6), dark, Transform3D(Basis().scaled(Vector3(0.9, 0.45, 1.15)), Vector3(eye_x, y - 0.004, sz * eye_z)), "Socket")
			Kit.add_mesh(head, Kit.sphere(0.0115, 10, 6), white, Transform3D(Basis(), Vector3(eye_x + 0.001, y - 0.002, sz * eye_z)), "Eye")
			Kit.add_mesh(head, Kit.sphere(0.0045, 8, 4), pupil, Transform3D(Basis(), Vector3(eye_x + 0.0015, y + 0.008, sz * eye_z * 0.97)), "Pupil")
	else:
		# Where the eyes were: skin grown over, two short scars.
		var scar := Kit.mat("mb_scar", Color(0.36, 0.22, 0.24), 0.9)
		for sz in [-1.0, 1.0]:
			var y := _surface_y(hr, eye_x, eye_z)
			Kit.add_mesh(head, Kit.box(Vector3(0.004, 0.003, 0.03)), scar, Transform3D(Basis(Vector3(1, 0, 0), sz * 0.25), Vector3(eye_x, y + 0.0005, sz * eye_z)), "Scar")
	# Brow ridge, nose, mouth.
	var nose_y := _surface_y(hr, 0.028, 0.0)
	Kit.add_mesh(head, Kit.sphere(1.0, 10, 6), skin_mat, Transform3D(Basis(Vector3(0, 0, 1), 0.5).scaled(Vector3(0.026, 0.012, 0.014)), Vector3(0.026, nose_y + 0.006, 0)), "Nose")
	Kit.add_mesh(head, Kit.sphere(0.0035, 6, 4), dark, Transform3D(Basis(), Vector3(0.043, nose_y + 0.004, 0.006)), "Nostril")
	Kit.add_mesh(head, Kit.sphere(0.0035, 6, 4), dark, Transform3D(Basis(), Vector3(0.043, nose_y + 0.004, -0.006)), "Nostril")
	var mouth_y := _surface_y(hr, 0.066, 0.0)
	var jaw := Node3D.new()
	jaw.name = "Jaw"
	jaw.position = Vector3(0.066, mouth_y - 0.004, 0)
	head.add_child(jaw)
	Kit.add_mesh(jaw, Kit.sphere(1.0, 12, 6), dark, Transform3D(Basis().scaled(Vector3(0.008, 0.004, 0.026)), Vector3.ZERO), "Mouth")
	Kit.add_mesh(jaw, Kit.box(Vector3(0.004, 0.003, 0.03)), Kit.mat("mb_teeth", Color(0.62, 0.58, 0.42), 0.6), Transform3D(Basis(), Vector3(-0.004, 0.002, 0)), "Teeth")
	out["jaw"] = jaw
	# Ears: clear ones, larger than normal on the Discharged, with a dark hollow.
	var ek: float = lk.ear
	var ear_mat := Kit.mat("mb_ear_%s" % str(skin), skin * 0.88, 0.75)
	for sz in [-1.0, 1.0]:
		var ear := Node3D.new()
		ear.name = "Ear"
		ear.position = Vector3(0.004, hr.y * 0.1, sz * (hr.z - 0.004))
		ear.basis = Basis(Vector3(1, 0, 0), sz * -0.45) * Basis(Vector3(0, 1, 0), 0.0)
		head.add_child(ear)
		var h := 0.034 * ek
		var wd := 0.02 * ek
		Kit.add_mesh(ear, Kit.sphere(1.0, 14, 7), ear_mat, Transform3D(Basis().scaled(Vector3(h, wd, 0.007 * sqrt(ek))), Vector3(0, 0, sz * 0.008 * ek)), "Pinna")
		Kit.add_mesh(ear, Kit.sphere(1.0, 10, 5), dark, Transform3D(Basis().scaled(Vector3(h * 0.5, wd * 0.5, 0.004)), Vector3(0.002, 0.002, sz * (0.012 * ek + 0.002))), "Hollow")
		Kit.add_mesh(ear, Kit.sphere(1.0, 10, 5), ear_mat, Transform3D(Basis().scaled(Vector3(h * 0.35, wd * 0.25, 0.006)), Vector3(h * 0.8, 0.0, sz * 0.009 * ek)), "Lobe")
	return out


# ---------------------------------------------------------------------------------------- body

static func _primitive_body(b, rig: Node3D, lk: Dictionary, d: Dictionary, seed_v: int) -> void:
	var L: float = d.L
	var w: float = d.w
	var th: float = d.thin
	var s := L / 1.74
	var x0 := -L * 0.5
	var tx: float = d.tx
	var skin: Color = lk.skin
	var gown: Color = lk.gown
	var stain: Color = lk.gown_dark
	var skin_fn := func(p: Vector3, _up: float) -> Color:
		var n := Head.noise3(p * 30.0 + Vector3(seed_v % 17, 0, 0))
		var blotch := smoothstep(0.62, 0.8, Head.noise3(p * 9.0 + Vector3(3, seed_v % 11, 1)))
		return (skin * (0.88 + 0.18 * n)).lerp(Color(0.33, 0.3, 0.36), blotch * 0.35)
	var gown_fn := func(p: Vector3, up: float) -> Color:
		var n := Head.noise3(p * 14.0 + Vector3(1, 2, seed_v % 9))
		var fold := 0.9 + 0.1 * sin(p.x * 60.0 + p.z * 25.0 + n * 4.0)
		var c := gown * fold * (0.92 + 0.12 * n)
		# Old stains.
		var st := smoothstep(0.66, 0.84, Head.noise3(p * 6.0 + Vector3(seed_v % 23, 5, 2)))
		c = c.lerp(stain, st * 0.7)
		# Pattern of little dots, the hospital print.
		var dots := 1.0 if fposmod(p.x * 40.0, 1.0) < 0.12 and fposmod(p.z * 40.0, 1.0) < 0.12 else 0.0
		return c.lerp(gown.darkened(0.35), dots * 0.5 * clampf(up + 0.2, 0.0, 1.0))
	var skin_m := vc_mat("mb_vskin")
	var gown_m := vc_mat("mb_vgown", 0.95)

	# Neck.
	var hc: Vector3 = d.head_c
	var hrr: Vector3 = d.hr
	var neck_x := hc.x + hrr.x * 0.75
	var nk := Kit.loft([
		[neck_x - 0.03 * s, 0.045 * w, 0.045, 0.075, 0.9],
		[neck_x + 0.05 * s, 0.05 * w, 0.05, 0.08, 0.9],
	], 14, skin_fn)
	Kit.add_mesh(rig, nk, skin_m, Transform3D(), "NeckMesh")

	# Torso in the gown, down past the hips like a short skirt over the thighs.
	var torso_rings := [
		[tx, 0.13 * w, 0.07 * th * 0.85, 0.085, 0.9],
		[tx + 0.05 * s, 0.2 * w, 0.1 * th * 0.85, 0.1, 0.9],
		[tx + 0.18 * s, 0.215 * w, 0.115 * th * 0.85, 0.105, 0.9],
		[tx + 0.34 * s, 0.18 * w, 0.1 * th * 0.85, 0.095, 0.9],
		[tx + 0.5 * s, 0.185 * w, 0.095 * th * 0.85, 0.09, 0.9],
		[tx + 0.62 * s, 0.2 * w, 0.085 * th * 0.85, 0.085, 0.9],
		[tx + 0.8 * s, 0.2 * w, 0.075 * th * 0.85, 0.075, 0.9],
		[tx + 0.84 * s, 0.205 * w, 0.07 * th * 0.85, 0.072, 0.9],
	]
	var torso := Node3D.new()
	torso.name = "Torso"
	rig.add_child(torso)
	Kit.add_mesh(torso, Kit.loft(torso_rings, 22, gown_fn), gown_m, Transform3D(), "Gown")
	b.parts["torso"] = torso

	# Arms along the sides, bare below the short sleeves; they hinge at the shoulder to thrash.
	for side in [-1.0, 1.0]:
		var arm := Node3D.new()
		arm.name = "Arm" + ("L" if side > 0 else "R")
		arm.position = Vector3(tx + 0.07 * s, 0.07, side * 0.235 * w)
		rig.add_child(arm)
		var ar := [
			[0.0, 0.05 * w, 0.048 * th, 0.0, 0.8],
			[0.28 * s, 0.04 * w, 0.038 * th, -0.012, 0.8],
			[0.3 * s, 0.037 * w, 0.034 * th, -0.014, 0.8],
			[0.52 * s, 0.03 * w, 0.028 * th, -0.02, 0.8],
			[0.58 * s, 0.034 * w, 0.017, -0.024, 0.6],
			[0.66 * s, 0.03 * w, 0.014, -0.028, 0.6],
		]
		Kit.add_mesh(arm, Kit.loft(ar, 12, skin_fn), skin_m, Transform3D(), "ArmMesh")
		# Sleeve.
		var sl := [[-0.02, 0.058 * w, 0.056 * th, 0.0, 0.8], [0.12 * s, 0.054 * w, 0.05 * th, -0.004, 0.8]]
		Kit.add_mesh(arm, Kit.loft(sl, 12, gown_fn), gown_m, Transform3D(), "Sleeve")
		# Fingers: a few thin bent sticks, they curl when it thrashes.
		var fingers := Node3D.new()
		fingers.name = "Fingers"
		fingers.position = Vector3(0.66 * s, -0.028, 0)
		arm.add_child(fingers)
		for f in 4:
			Kit.add_mesh(fingers, Kit.box(Vector3(0.07, 0.012, 0.011)), Kit.mat("mb_finger_%s" % str(skin), skin * 0.85, 0.8),
				Transform3D(Basis(Vector3(0, 0, 1), -0.35), Vector3(0.03, -0.01, (float(f) - 1.5) * 0.014)), "Finger")
		b.parts["arm_%s" % ("l" if side > 0 else "r")] = arm
		b.parts["fingers_%s" % ("l" if side > 0 else "r")] = fingers
	# The Walk-In's wristband; the Discharged's IV line taped to the forearm.
	if String(b.patient_id) == "discharged":
		var arm_n: Node3D = b.parts["arm_r"]
		Kit.add_mesh(arm_n, Kit.box(Vector3(0.05, 0.004, 0.03)), Kit.mat("mb_tape", Color(0.85, 0.82, 0.7), 0.9), Transform3D(Basis(), Vector3(0.45 * s, 0.02, 0)), "Tape")
		Kit.add_mesh(arm_n, Kit.cyl(0.003, 0.003, 0.35, 6), Kit.mat("mb_tube", Color(0.75, 0.8, 0.78), 0.3), Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5).rotated(Vector3.UP, 0.35), Vector3(0.62 * s, 0.022, -0.06)), "Tube")
	else:
		var arm_n2: Node3D = b.parts["arm_l"]
		Kit.add_mesh(arm_n2, Kit.cyl(0.035 * w, 0.035 * w, 0.02, 12, false), Kit.mat("mb_band", Color(0.9, 0.9, 0.86), 0.7), Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0.56 * s, -0.022, 0)), "Wristband")

	# Legs: thighs under the gown hem, bare shins, feet up.
	var legs := Node3D.new()
	legs.name = "Legs"
	legs.position = Vector3(tx + 0.78 * s, 0.0, 0)
	rig.add_child(legs)
	b.parts["legs"] = legs
	for side in [-1.0, 1.0]:
		var lg := [
			[0.0, 0.085 * w, 0.075 * th, 0.075, 0.9],
			[0.2 * s, 0.07 * w, 0.065 * th, 0.066, 0.9],
			[0.42 * s, 0.05 * w, 0.05 * th, 0.052, 0.9],
			[0.62 * s, 0.038 * w, 0.038 * th, 0.042, 0.9],
			[0.78 * s, 0.03 * w, 0.03 * th, 0.034, 0.9],
		]
		var leg := Kit.loft(lg, 12, skin_fn)
		Kit.add_mesh(legs, leg, skin_m, Transform3D(Basis(), Vector3(0, 0, side * 0.1 * w)), "Leg")
		Kit.add_mesh(legs, Kit.box(Vector3(0.05, 0.12, 0.07 * w)), Kit.mat("mb_foot_%s" % str(skin), skin * 0.8, 0.85),
			Transform3D(Basis(Vector3(0, 0, 1), 0.25), Vector3(0.8 * s, 0.075, side * 0.1 * w)), "Foot")
	# Hem of the gown over the thighs.
	var hem := [[-0.06, 0.2 * w, 0.085 * th, 0.078, 0.9], [0.14 * s, 0.19 * w, 0.08 * th, 0.075, 0.9]]
	Kit.add_mesh(legs, Kit.loft(hem, 22, gown_fn, false, true), gown_m, Transform3D(), "Hem")


# ---------------------------------------------------------------------------------------- straps

static func _straps(rig: Node3D, d: Dictionary) -> void:
	var L: float = d.L
	var w: float = d.w
	var s := L / 1.74
	var x0 := -L * 0.5
	var tx: float = d.tx
	var th: float = d.thin
	var root := Node3D.new()
	root.name = "Straps"
	rig.add_child(root)
	# x, half width over the body, height over the body
	var list := [
		[tx + 0.18 * s, 0.3 * w, 0.215 * th * 0.85 + 0.03],   # chest, over the upper arms
		[tx + 0.58 * s, 0.3 * w, 0.18 * th * 0.85 + 0.025],     # wrists and hips
		[tx + 0.92 * s, 0.2 * w, 0.14 * th + 0.015],     # thighs
		[tx + 1.24 * s, 0.17 * w, 0.1 * th + 0.015],      # shins
	]
	var leather := Kit.mat("mb_strap", Color(0.2, 0.13, 0.08), 0.7)
	leather.cull_mode = BaseMaterial3D.CULL_DISABLED
	var metal := Kit.mat("mb_buckle", Color(0.62, 0.62, 0.6), 0.35, 0.8)
	for e in list:
		var x: float = e[0]
		var hw: float = e[1]
		var hh: float = e[2]
		Kit.add_mesh(root, _band(hw, hh, 0.37, 0.065, 0.007), leather, Transform3D(Basis(), Vector3(x, 0, 0)), "Strap")
		Kit.add_mesh(root, Kit.box(Vector3(0.05, 0.012, 0.045)), metal, Transform3D(Basis(), Vector3(x, hh * 0.72, hw * 0.78)), "Buckle")
		Kit.add_mesh(root, Kit.box(Vector3(0.03, 0.014, 0.03)), Kit.mat("mb_buckle_in", Color(0.2, 0.13, 0.08), 0.7), Transform3D(Basis(), Vector3(x, hh * 0.72 + 0.002, hw * 0.78)), "BuckleIn")


## A strap over an elliptic hump (half width hw, height hh), flat on the table out to `table_hw`
## and down its sides, `width` along X and `t` thick. Profile in YZ, extruded along X.
static func _band(hw: float, hh: float, table_hw: float, width: float, t: float) -> ArrayMesh:
	var prof := PackedVector2Array()   # (z, y)
	prof.append(Vector2(-table_hw, -0.12))
	prof.append(Vector2(-table_hw, 0.004))
	prof.append(Vector2(-hw - 0.03, 0.004))
	var n := 16
	for i in n + 1:
		var a := PI - PI * float(i) / float(n)
		prof.append(Vector2(cos(a) * hw, 0.004 + sin(a) * hh))
	prof.append(Vector2(hw + 0.03, 0.004))
	prof.append(Vector2(table_hw, 0.004))
	prof.append(Vector2(table_hw, -0.12))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hwx := width * 0.5
	for i in prof.size() - 1:
		var p0 := prof[i]
		var p1 := prof[i + 1]
		var dirv := (p1 - p0).normalized()
		var nrm := Vector2(-dirv.y, dirv.x)   # outward (left of travel from -z to +z over the top)
		for lay in [0.0, -t]:
			var q0 := p0 + nrm * float(lay)
			var q1 := p1 + nrm * float(lay)
			var a := Vector3(-hwx, q0.y, q0.x)
			var b := Vector3(hwx, q0.y, q0.x)
			var c := Vector3(-hwx, q1.y, q1.x)
			var dd := Vector3(hwx, q1.y, q1.x)
			var nn := Vector3(0, nrm.y, nrm.x) * (1.0 if lay == 0.0 else -1.0)
			for v in [a, c, b, b, c, dd]:
				st.set_normal(nn)
				st.add_vertex(v)
	return st.commit()


# ---------------------------------------------------------------------------------------- animation

static func animate(b, jolt: float, env: float, _fidget: float, _twitch: float, t: float) -> void:
	var parts: Dictionary = b.parts
	var flags: Dictionary = b._flags
	var flat: bool = b._flat
	var open := bool(flags.get("skull_open", false))
	var removed := bool(flags.get("brain_removed", false))
	var dt: float = minf(0.1, maxf(0.0, t - float(parts.get("last_t", t))))
	parts["last_t"] = t
	if removed and not flat:
		# Nothing left to keep it alive (a late joiner never saw the flatline event).
		b.flatline()
		flat = true
	# The cap: lifts off along the cut, turns over and settles beside the head (0.9 s). A body that
	# is built already open (a late joiner, the warmup) shows it lying there at once.
	var open_t := float(parts.get("open_t", -1.0))
	if open_t < 0.0:
		open_t = 1.0 if open else 0.0
	open_t = move_toward(open_t, 1.0 if open else 0.0, dt / 0.9 if open else 1.0)
	parts["open_t"] = open_t
	var cap: Node3D = parts.get("cap")
	if cap != null:
		var home: Transform3D = parts["cap_home"]
		var rest: Transform3D = parts["cap_rest"]
		if open_t <= 0.0:
			cap.transform = home
		elif open_t >= 1.0:
			cap.transform = rest
		else:
			var lifted := Transform3D(home.basis, home.origin + Head.CUT_DIR * 0.09)
			if open_t < 0.35:
				cap.transform = home.interpolate_with(lifted, smoothstep(0.0, 1.0, open_t / 0.35))
			else:
				var k := smoothstep(0.0, 1.0, (open_t - 0.35) / 0.65)
				var xf := lifted.interpolate_with(rest, k)
				xf.origin += Vector3(0, 0.05 * sin(k * PI), 0)
				cap.transform = xf
	var rim: Node3D = parts.get("open_skull")
	if rim != null:
		rim.visible = open
	var brain: Node3D = parts.get("brain")
	if brain != null:
		# The brain forceps step draws its own brain and hides this one (meta dx_brain_hidden).
		brain.visible = open and not removed and not bool(b.get_meta("dx_brain_hidden", false))

	var sed: float = b._sedation
	var st: Dictionary = parts["thrash"]
	var rng: RandomNumberGenerator = parts["rng"]
	var awake := not flat and sed < AWAKE
	var stirring := not flat and sed < STIR
	# Thrashing: every half second or so a limb yanks against its strap; the straps hold.
	if awake:
		st.next = float(st.next) - dt
		if float(st.next) <= 0.0:
			var fury := clampf((AWAKE - sed) / AWAKE, 0.0, 1.0) * 0.6 + 0.4
			st.next = rng.randf_range(0.25, 0.8) / (0.6 + fury)
			match rng.randi_range(0, 3):
				0: st.arm_l_v = float(st.arm_l_v) + rng.randf_range(4.0, 9.0) * fury
				1: st.arm_r_v = float(st.arm_r_v) + rng.randf_range(4.0, 9.0) * fury
				2: st.legs_v = float(st.legs_v) + rng.randf_range(3.0, 7.0) * fury
				_: st.head_v = float(st.head_v) + rng.randf_range(-6.0, 6.0) * fury
			b.stir(0.25 + 0.35 * fury)
		st.jaw = move_toward(float(st.jaw), 0.8 + 0.2 * sin(t * 9.0), dt * 3.0)
	elif stirring:
		st.twitch_next = float(st.twitch_next) - dt
		if float(st.twitch_next) <= 0.0:
			st.twitch_next = rng.randf_range(0.8, 2.6)
			var k := clampf((STIR - sed) / (STIR - AWAKE), 0.0, 1.0)
			match rng.randi_range(0, 2):
				0: st.arm_l_v = float(st.arm_l_v) + rng.randf_range(1.0, 2.5) * k
				1: st.arm_r_v = float(st.arm_r_v) + rng.randf_range(1.0, 2.5) * k
				_: st.legs_v = float(st.legs_v) + rng.randf_range(0.8, 1.8) * k
		st.jaw = move_toward(float(st.jaw), 0.15, dt)
	else:
		st.jaw = move_toward(float(st.jaw), 0.0, dt)
	# Springs, clamped hard: the straps stop every limb a few centimetres up.
	for k2 in ["arm_l", "arm_r", "legs", "head"]:
		var v := float(st[k2 + "_v"])
		var x := float(st[k2])
		v += (-90.0 * x - 7.0 * v) * dt
		x += v * dt
		var lim := 0.16 if k2 != "head" else 0.05
		if x > lim:
			x = lim
			v = -absf(v) * 0.3
		elif x < -lim * 0.3:
			x = -lim * 0.3
			v = absf(v) * 0.3
		st[k2 + "_v"] = v
		st[k2] = x
	if flat:
		for k3 in ["arm_l", "arm_r", "legs", "head"]:
			st[k3] = move_toward(float(st[k3]), 0.0, dt)
		st.jaw = move_toward(float(st.jaw), 0.35, dt * 0.5)
	var arm_l: Node3D = parts.get("arm_l")
	if arm_l != null:
		arm_l.rotation = Vector3(float(st.arm_l) * 0.8 + env * 0.2, 0, float(st.arm_l) * 0.5 + jolt * 0.05)
	var arm_r: Node3D = parts.get("arm_r")
	if arm_r != null:
		arm_r.rotation = Vector3(-float(st.arm_r) * 0.8 - env * 0.2, 0, float(st.arm_r) * 0.5 - jolt * 0.05)
	for key in ["fingers_l", "fingers_r"]:
		var f: Node3D = parts.get(key)
		if f != null:
			f.rotation.z = -0.2 - (0.9 if awake else 0.0) * (0.5 + 0.5 * sin(t * 13.0 + (0.0 if key == "fingers_l" else 1.7)))
	var legs: Node3D = parts.get("legs")
	if legs != null:
		legs.rotation.z = float(st.legs) * 0.35
	var neck: Node3D = parts.get("neck")
	if neck != null:
		# Only a little: the operator works on this head.
		neck.rotation = Vector3(float(st.head) * 0.4, 0, jolt * 0.01)
	var jaw: Node3D = parts.get("jaw")
	if jaw != null:
		jaw.scale = Vector3(1.0, 1.0 + float(st.jaw) * 2.5, 1.0 - float(st.jaw) * 0.15)
	# Breathing: the chest rises with the phase the body runs (none when flat).
	var torso: Node3D = parts.get("torso")
	if torso != null:
		var br := 0.0 if flat else (0.5 - 0.5 * cos(float(b._phase))) * (0.018 if not awake else 0.035)
		torso.scale = Vector3(1.0, 1.0 + br, 1.0 + br * 0.4)


static func set_limb_removed(_b, _removed: bool) -> void:
	pass


## The saw's skull variant calls this at the end of the cut: a static copy of the skull cap where it
## is right now. The body's own cap moves to its resting place beside the head when `skull_open`.
static func make_severed_limb(b, parent: Node) -> Node3D:
	var cap: Node3D = b.parts.get("cap")
	if cap == null or not cap.is_inside_tree() or parent == null:
		return null
	var copy := cap.duplicate() as Node3D
	parent.add_child(copy)
	copy.global_transform = cap.global_transform
	copy.visible = true
	return copy


## Where the removed cap comes to rest, global.
static func skull_cap_rest(b) -> Transform3D:
	var head: Node3D = b.parts.get("head")
	if head == null or not head.is_inside_tree():
		return Transform3D()
	return head.global_transform * (b.parts["cap_rest"] as Transform3D)
