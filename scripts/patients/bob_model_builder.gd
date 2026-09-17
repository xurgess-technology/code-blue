extends RefCounted
## Bob on his Blender model (`patient/human_bob`, assets/models/characters/human/bob.glb, art/human/).
##
## PatientBody tries this first and falls back to the reshaped Kenney rig (bob_builder.gd) when the
## asset or its shaders are missing (`BobModelBuilder.kenney_only = true` forces the fallback).
## Frame as every patient: lying along X, head toward -X, face up (+Y), back on the table top at
## y = 0, centred on the origin; his right arm (the removable forearm) on +Z.
##
## From the GLB:
##   Human             body, gown, socks (skinned); the right upper arm ends in a stump cap at the cut
##   Human_Forearm_R   the right forearm and hand past the cut, with its own cut cap: hidden when amputated,
##                     baked from the current pose for make_severed_limb
##   Human_GownPanel   the gown over the gunshot site: hidden for the gunshot ailment, so the wound is bare;
##                     while a step exposes the site (PatientBody.expose_site) it is back, with the gown
##                     cut away round the step's skin patch instead (the cloth shader's `expose`)
##   Site_injection / Site_gunshot / Site_limb / Site_limb_cut   on forearm.L / hips / upperarm.R / forearm.R
## The model is posed by hand every frame (no AnimationPlayer runs): the Lying clip at the body's
## breathing rate, with stirs, fidgets and twitches turned onto the arm, leg and head bones.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const HM := preload("res://scripts/human/human_model.gd")
const SealModel := preload("res://scripts/patients/seal_model_builder.gd")

## From art/human/blender_src/bob_sites.json (model metres).
const SECTIONS := {
	"limb": {"half_up": 0.0489, "half_side": 0.049, "axis_depth": 0.0489, "shape": 2.2},
	"limb_cut": {"half_up": 0.0411, "half_side": 0.0384, "axis_depth": 0.0411, "shape": 2.2},
}
const INFECTION := {"limb": 0.1721, "limb_cut": 0.0295}
## Arc length along the right arm (UV2.x) where the painted infection starts and is complete.
const INFECT_FROM := 0.3843
const INFECT_FULL := 0.4335
## The trunk section at the gunshot height (half width, front depth from the body axis), and the
## azimuth (radians toward his right) the entry wound is moved to so the belly round it is nearly
## level for the forceps' skin patch (the model's own site sits 0.62 rad round on the flank).
const TRUNK_HALF_W := 0.19
const TRUNK_FRONT := 0.156
const SITE_AZIMUTH := 0.62
const WOUND_AZIMUTH := 0.25
const LYING_BREATH_HZ := 2.0 / 3.0
const LYING_LEN := 3.0

static var kenney_only := false


static func build(b) -> bool:
	if kenney_only or not HM.available("bob"):
		return false
	var root: Node3D = HM.spawn("bob", HM.BAKED_TINT, true)
	if root == null:
		return false
	var skel := HM.skeleton(root)
	var ap := HM.anim_player(root)
	var forearm := HM.piece(root, "Human_Forearm_R")
	var panel := HM.piece(root, "Human_GownPanel")
	var lying: Animation = ap.get_animation("Lying") if ap != null and ap.has_animation("Lying") else null
	if skel == null or lying == null or forearm == null or panel == null:
		root.free()
		return false
	for s in ["injection", "gunshot", "limb", "limb_cut"]:
		if root.find_child("Site_" + s, true, false) == null:
			root.free()
			return false
	ap.active = false
	b.rig.add_child(root)
	# Lying (frame 0) puts the middle of the back on the origin with the head toward -Z; the spawn's yaw
	# 180 turns that to +Z. A further -90 degrees puts the head at -X and his right arm on +Z.
	root.rotation.y = -PI * 0.5
	HM.sample_clip(skel, lying, 0.0)
	var to_rig := HM.chain_to(skel, b.rig)
	var crown: Vector3 = to_rig * HM.bone_global(skel, skel.find_bone("head")).origin
	var toe: Vector3 = to_rig * HM.bone_global(skel, skel.find_bone("toe.L")).origin
	root.position.x = -((crown.x - 0.20) + toe.x) * 0.5
	to_rig = HM.chain_to(skel, b.rig)

	var skin := HM.skin_of(root)
	skin.set_shader_parameter(&"infect_from", INFECT_FROM)
	skin.set_shader_parameter(&"infect_full", INFECT_FULL)
	b.skin_mats.append(skin)
	b.breath_amp = 0.0

	# --- sites: the model's frames at rest (Lying frame 0), levelled so +Y points straight up
	for s in ["injection", "gunshot", "limb", "limb_cut"]:
		var node := root.find_child("Site_" + s, true, false) as Node3D
		var att := node.get_parent() as BoneAttachment3D
		var bone_xf := HM.bone_global(skel, skel.find_bone(att.bone_name)) if att != null else Transform3D()
		var xf: Transform3D = to_rig * bone_xf * node.transform
		var origin := xf.origin
		var x_dir := xf.basis.x
		if s == "gunshot":
			# round the belly toward the midline: the centre of the trunk section, then out at WOUND_AZIMUTH
			var y_out := xf.basis.y.normalized()
			var side := Vector3(0, 0, 1)
			var centre := origin - Vector3(0, TRUNK_FRONT * cos(SITE_AZIMUTH), 0) - side * TRUNK_HALF_W * sin(SITE_AZIMUTH)
			origin = centre + Vector3(0, TRUNK_FRONT * cos(WOUND_AZIMUTH), 0) + side * TRUNK_HALF_W * sin(WOUND_AZIMUTH)
			x_dir = Vector3(1, 0, 0)
			if y_out.y < 0.0:
				push_warning("BobModelBuilder: gunshot site faces down")
		var site := _frame(origin, x_dir, Vector3.UP)
		b._sites[s] = site
		var anchor := Node3D.new()
		anchor.name = s
		if att != null:
			att.add_child(anchor)
			anchor.transform = (to_rig * bone_xf).affine_inverse() * site
		else:
			b.rig.add_child(anchor)
			anchor.transform = site
		b.anchors[s] = anchor
	for s in ["limb", "limb_cut"]:
		b.sections[s] = (SECTIONS[s] as Dictionary).duplicate()
		b.infection[s] = INFECTION[s]

	var st := {"skel": skel, "lying": lying, "last_t": 0.0, "idle_t": 0.0, "flat_w": 0.0,
		"bones": {}, "forearm": forearm, "panel": panel, "root": root}
	for nm in ["upperarm.R", "upperarm.L", "forearm.R", "forearm.L", "thigh.L", "thigh.R", "shin.L", "shin.R", "head", "neck", "hand.R", "hand.L"]:
		st.bones[nm] = skel.find_bone(nm)
	b.parts["human"] = st
	b.parts["limb_node"] = forearm

	# --- overlays, fitted to the model
	var lsec: Dictionary = SECTIONS["limb"]
	var csec: Dictionary = SECTIONS["limb_cut"]
	var lu := float(lsec.half_up)
	var ls := float(lsec.half_side)
	var cu := float(csec.half_up)
	var cs := float(csec.half_side)
	b.parts["tourniquet"] = Kit.make_tourniquet(b.anchors["limb"], lu, ls, lu, false)
	var stump := Node3D.new()
	stump.name = "StumpMarker"   # the model's own cap shows once the forearm is hidden
	(b.anchors["limb_cut"] as Node3D).add_child(stump)
	b.parts["stump"] = stump
	b.parts["dress_stump"] = SealModel.make_stump_dressing(b.anchors["limb_cut"], csec)
	b.parts["wound"] = Kit.make_wound(b.anchors["gunshot"], 0.032)
	var gxf: Transform3D = b._sites["gunshot"]
	var dress := Kit.make_pad(b.anchors["gunshot"], 0.15)
	var band := MeshInstance3D.new()
	band.name = "Band"
	band.mesh = Kit.cyl(1.0, 1.0, 0.11, 20, false)
	band.material_override = Kit.gauze_mat()
	var half_up := gxf.origin.y * 0.5 + 0.012
	var band_global := Transform3D(Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)).scaled_local(Vector3(TRUNK_HALF_W * 1.12, 1.0, half_up)), Vector3(gxf.origin.x, half_up, 0))
	band.transform = gxf.affine_inverse() * band_global
	dress.add_child(band)
	b.parts["dress_wound"] = dress

	# --- drip paths (body local): off the side of the arm or the flank onto the table
	var lxf: Transform3D = b._sites["limb"]
	var cxf: Transform3D = b._sites["limb_cut"]
	b.drips["limb"] = [lxf.origin + Vector3(0, -lu * 0.6, ls * 0.95), Vector3(lxf.origin.x, 0.003, lxf.origin.z + ls * 1.3)]
	b.drips["limb_cut"] = [cxf.origin + Vector3(0.02, -cu * 0.8, cs * 0.6), Vector3(cxf.origin.x + 0.04, 0.003, cxf.origin.z + cs * 0.9)]
	var ixf: Transform3D = b._sites["injection"]
	var ihs := 0.042
	b.drips["injection"] = [ixf.origin + Vector3(0, -0.02, -ihs), Vector3(ixf.origin.x, 0.003, ixf.origin.z - ihs * 1.4)]
	var gp := gxf.origin
	b.drips["gunshot"] = [gp + Vector3(0, -gp.y * 0.3, TRUNK_HALF_W * 0.9 - gp.z), Vector3(gp.x, 0.003, TRUNK_HALF_W * 1.15)]
	return true


static func _frame(origin: Vector3, x_dir: Vector3, up: Vector3) -> Transform3D:
	var x := x_dir.normalized()
	var y := (up - x * up.dot(x)).normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x, y, z), origin)


## Per frame: breathe with the Lying clip, then turn the limbs and head for stirs, fidgets and twitches.
static func animate(b, jolt: float, env: float, fidget: float, twitch: float, t: float) -> void:
	var st: Dictionary = b.parts.get("human", {})
	if st.is_empty():
		return
	var skel: Skeleton3D = st.skel
	var dt := clampf(t - float(st.last_t), 0.0, 0.1)
	st.last_t = t
	var flat: bool = b._flat
	var v01 := float(b._vitals) / 100.0
	var rate := lerpf(0.75, 0.24, v01)
	if flat:
		st.idle_t = move_toward(float(st.idle_t), 0.0, dt)   # breathe out, stop
	else:
		st.idle_t = fposmod(float(st.idle_t) + dt * rate / LYING_BREATH_HZ * lerpf(0.6, 1.0, v01), LYING_LEN)
	HM.sample_clip(skel, st.lying, float(st.idle_t))
	var bones: Dictionary = st.bones
	var arm_lift := env * 0.9 + jolt * 0.35 + fidget * 0.25 * sin(t * 1.7) + twitch * 0.25 * sin(t * 37.0)
	var other_lift := env * 0.7 - jolt * 0.3 + fidget * 0.2 * sin(t * 1.3 + 1.0) + twitch * 0.15 * sin(t * 29.0)
	# Skeleton space here is the glTF's: head toward -Z, face +Y, his right arm on -X.
	# Skeleton space here is the glTF's: head toward -Z, face +Y, the arms along +Z beside the body.
	HM.turn_bone(skel, bones["upperarm.R"], Quaternion(Vector3(1, 0, 0), -arm_lift * 0.25))
	HM.turn_bone(skel, bones["forearm.R"], Quaternion(Vector3(1, 0, 0), -arm_lift * 0.3))
	HM.turn_bone(skel, bones["upperarm.L"], Quaternion(Vector3(1, 0, 0), -other_lift * 0.25))
	HM.turn_bone(skel, bones["forearm.L"], Quaternion(Vector3(1, 0, 0), -other_lift * 0.25))
	var kick := env * 0.5 + jolt * 0.25 + twitch * 0.1 * sin(t * 23.0)
	HM.turn_bone(skel, bones["thigh.L"], Quaternion(Vector3(1, 0, 0), -kick * 0.35 - fidget * 0.08 * sin(t * 0.9)))
	HM.turn_bone(skel, bones["shin.L"], Quaternion(Vector3(1, 0, 0), kick * 0.55))
	HM.turn_bone(skel, bones["thigh.R"], Quaternion(Vector3(1, 0, 0), -kick * 0.22 + fidget * 0.08 * sin(t * 1.1)))
	HM.turn_bone(skel, bones["shin.R"], Quaternion(Vector3(1, 0, 0), kick * 0.35))
	HM.turn_bone(skel, bones["head"], Quaternion(Vector3(0, 0, 1), fidget * 0.35 * sin(t * 0.6) + jolt * 0.3) * Quaternion(Vector3(1, 0, 0), env * 0.35 + absf(jolt) * 0.2))
	var hand_curl := twitch * 0.4 * sin(t * 31.0) + env * 0.3
	HM.turn_bone(skel, bones["hand.R"], Quaternion(Vector3(1, 0, 0), hand_curl))
	HM.turn_bone(skel, bones["hand.L"], Quaternion(Vector3(1, 0, 0), hand_curl * 0.8))
	var panel: Node3D = st.panel
	var ex: Dictionary = b.exposure
	var bare: bool = b.ailment_id == "gunshot" and ex.is_empty()
	if panel.visible == bare:
		panel.visible = not bare
	# The gown pulled back round an exposed site: its folds rise above the site plane and would poke
	# through the step's skin patch (the forceps step on the gunshot wound).
	var cloth: ShaderMaterial = HM.cloth_of(st.root)
	if cloth != null:
		if not ex.is_empty():
			cloth.set_shader_parameter(&"expose", 1.0)
			cloth.set_shader_parameter(&"expose_inv", b.site_transform(String(ex.site)).affine_inverse())
			cloth.set_shader_parameter(&"expose_c", ex.centre)
			cloth.set_shader_parameter(&"expose_r", ex.radii)
			st.exposed = true
		elif st.get("exposed", false):
			cloth.set_shader_parameter(&"expose", 0.0)
			st.exposed = false


static func set_limb_removed(b, removed: bool) -> void:
	var fore: Node3D = b.parts.get("limb_node")
	if fore != null:
		fore.visible = not removed


## A static copy of the forearm past the cut (its own cut cap included), posed where it is now.
static func make_severed_limb(b, parent: Node) -> Node3D:
	var src: MeshInstance3D = b.parts.get("limb_node")
	if src == null or parent == null or not src.is_inside_tree():
		return null
	var mesh := _bake_skinned(src, b.parts["human"].skel)
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "SeveredForearm"
	mi.mesh = mesh
	for i in mesh.get_surface_count():
		var m := src.get_surface_override_material(i)
		if m is ShaderMaterial:
			m = (m as ShaderMaterial).duplicate()
			(m as ShaderMaterial).set_shader_parameter(&"breath", 0.0)
		mi.set_surface_override_material(i, m)
	parent.add_child(mi)
	if mi.is_inside_tree():
		mi.global_transform = src.global_transform
	return mi


## CPU skinning of a skinned MeshInstance3D with the skeleton's current pose, in the mesh
## instance's own space (bake_mesh_from_current_skeleton_pose needs a registered skin, which a hidden
## or not-yet-drawn instance may not have).
static func _bake_skinned(src: MeshInstance3D, skel: Skeleton3D) -> ArrayMesh:
	var skin := src.skin
	var am := src.mesh as ArrayMesh
	if skin == null or am == null or skel == null:
		return null
	var mi_to_skel := HM.chain_to(src, skel).affine_inverse()
	var mats: Array[Transform3D] = []
	for i in skin.get_bind_count():
		var bone := skin.get_bind_bone(i)
		if bone < 0:
			bone = skel.find_bone(String(skin.get_bind_name(i)))
		var g := HM.bone_global(skel, bone) if bone >= 0 else Transform3D()
		mats.append(mi_to_skel * g * skin.get_bind_pose(i))
	var out := ArrayMesh.new()
	for si in am.get_surface_count():
		var arr := am.surface_get_arrays(si)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var tans = arr[Mesh.ARRAY_TANGENT]
		var nb := bones.size() / maxi(1, verts.size())
		for v in verts.size():
			var p := Vector3.ZERO
			var n := Vector3.ZERO
			var tg := Vector3.ZERO
			for k in nb:
				var w := weights[v * nb + k]
				if w <= 0.0:
					continue
				var m: Transform3D = mats[bones[v * nb + k]]
				p += (m * verts[v]) * w
				n += (m.basis * norms[v]) * w
				if tans != null:
					tg += (m.basis * Vector3(tans[v * 4], tans[v * 4 + 1], tans[v * 4 + 2])) * w
			verts[v] = p
			norms[v] = n.normalized()
			if tans != null:
				tg = tg.normalized()
				tans[v * 4] = tg.x
				tans[v * 4 + 1] = tg.y
				tans[v * 4 + 2] = tg.z
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = norms
		arr[Mesh.ARRAY_BONES] = null
		arr[Mesh.ARRAY_WEIGHTS] = null
		if tans != null:
			arr[Mesh.ARRAY_TANGENT] = tans
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out
