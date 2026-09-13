extends RefCounted
## Bob: the rigged Kenney human (Assets "patient/human") laid on his back in a hospital gown.
##
## Body frame (PatientBody local): lying along X, head toward -X, feet toward +X, face up (+Y),
## back on the table top at y = 0, centred on the origin. The removable forearm is on +Z.
##
## The Kenney Mini Characters rig has ONE bone per arm ("arm-left", "arm-right"), no elbow.
## So at build time we add a bone "forearm-limb" parented to the +Z arm at the elbow and
## re-skin every vertex past the elbow to it (a short blend across the joint). Amputation
## scales that bone to ~0, which collapses the forearm and hand into the elbow, where a
## stump cap sits. The re-skinned mesh and skin are built once and cached.
##
## Authored ("A") space of the Kenney rig: +Y up, front +Z, character's left arm toward +X,
## height 0.795. A face-up character with head at -X has its anatomical left arm on -Z, so the
## +Z arm is "arm-right" in the rig; the game only cares that the limb sites are on +Z.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const SkinShader := preload("res://scripts/patients/bob_skin.gdshader")

## Whole-model scale (Assets registry uses 2.278 for a 1.81 m stander; Bob is a bit smaller
## so the chibi head and shoulders fit a 1.1 m wide table).
const S := 1.85
const LIMB_ARM := "arm-right"     # on body +Z
const OTHER_ARM := "arm-left"     # on body -Z
const FOREARM := "forearm-limb"
const SHOULDER_X := 0.099897
## Arm pose: swung down along the body, pushed out beside the torso, slimmed a little.
const ARM_DOWN_DEG := 84.0
const ARM_OUT := 0.105            # pivot moves outward by this (A units)
const ARM_DROP := 0.02
const ARM_SINK := 0.062           # and down toward the table (A -z)
const HEAD_SCALE := 0.82
const ARM_SCALE := Vector3(0.9, 0.62, 0.8)  # along, in-plane thickness, vertical thickness
const LEG_BACK_DEG := 12.0
## Distances along the rest arm from the shoulder pivot (A units, before ARM_SCALE).
const ELBOW := 0.2
const TOURNIQUET_AT := 0.168
const CUT_AT := 0.198
const INFECT_FROM := 0.2
const INFECT_FULL := 0.228
const INJECT_AT := 0.2

static var _cache := {}


static func build(b) -> bool:
	var assets = Engine.get_main_loop().root.get_node_or_null("Assets") if Engine.get_main_loop() is SceneTree else null
	if assets == null or not assets.has("patient/human"):
		return false
	var model: Node3D = assets.spawn("patient/human")
	if model == null:
		return false
	var skels := model.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		model.free()
		return false
	var skel: Skeleton3D = skels[0]
	var body_mi := skel.get_node_or_null("body-mesh") as MeshInstance3D
	var head_mi := skel.get_node_or_null("head-mesh") as MeshInstance3D
	if body_mi == null or head_mi == null or skel.find_bone(LIMB_ARM) < 0:
		model.free()
		return false
	for ap in model.find_children("*", "AnimationPlayer", true, false):
		ap.get_parent().remove_child(ap)
		ap.free()

	var rig: Node3D = b.rig
	var pose := Node3D.new()
	pose.name = "Pose"
	rig.add_child(pose)
	pose.add_child(model)

	# --- lying transform: A.y -> -X, A.z -> +Y, A.x -> -Z (via the spawn's yaw 180) -----------
	var inner_scale: float = float(assets.info("patient/human").get("scale", 2.278))
	var k := S / inner_scale
	var lie := Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)).scaled(Vector3(k, k, k))
	pose.transform = Transform3D(lie, Vector3.ZERO)
	var skel_xf := _chain(skel, rig)
	# Centre along X on the full height, torso back (A z = -0.163) on the table.
	var head_top := skel_xf * Vector3(0, 0.795, 0)
	var feet := skel_xf * Vector3(0, 0, 0)
	var back := skel_xf * Vector3(0, 0.25, -0.163)
	pose.position = Vector3(-(head_top.x + feet.x) * 0.5, -back.y + 0.004, 0)
	skel_xf = _chain(skel, rig)

	# --- re-skinned meshes, shared material ----------------------------------------------------
	var data := _mesh_data(body_mi, head_mi)
	var arm_i := skel.find_bone(LIMB_ARM)
	var fore_i := skel.find_bone(FOREARM)
	if fore_i < 0:
		skel.add_bone(FOREARM)
		fore_i = skel.get_bone_count() - 1
		skel.set_bone_parent(fore_i, arm_i)
		skel.set_bone_rest(fore_i, Transform3D(Basis(), Vector3(-ELBOW, 0, 0)))
		skel.reset_bone_pose(fore_i)
	body_mi.mesh = data.body_mesh
	body_mi.skin = data.body_skin
	head_mi.mesh = data.head_mesh
	var sm := ShaderMaterial.new()
	sm.shader = SkinShader
	sm.set_shader_parameter("colormap", data.colormap)
	sm.set_shader_parameter("breath_axis", Vector3(0, 0, 1))
	body_mi.material_override = sm
	head_mi.material_override = sm
	head_mi.set_instance_shader_parameter(&"is_head", 1.0)
	b.skin_mats.append(sm)
	b.breath_amp = 0.011

	# --- pose ------------------------------------------------------------------------------------
	var torso_i := skel.find_bone("torso")
	var other_i := skel.find_bone(OTHER_ARM)
	var head_i := skel.find_bone("head")
	var legl_i := skel.find_bone("leg-left")
	var legr_i := skel.find_bone("leg-right")
	var q_limb := Quaternion(Vector3(0, 0, 1), deg_to_rad(ARM_DOWN_DEG))    # -X arm swings down
	var q_other := Quaternion(Vector3(0, 0, 1), -deg_to_rad(ARM_DOWN_DEG))
	var p_limb := skel.get_bone_rest(arm_i).origin + Vector3(-ARM_OUT, -ARM_DROP, -ARM_SINK)
	var p_other := skel.get_bone_rest(other_i).origin + Vector3(ARM_OUT, -ARM_DROP, -ARM_SINK)
	var q_leg := Quaternion(Vector3(1, 0, 0), deg_to_rad(LEG_BACK_DEG))
	skel.set_bone_pose_position(arm_i, p_limb)
	skel.set_bone_pose_rotation(arm_i, q_limb)
	skel.set_bone_pose_scale(arm_i, ARM_SCALE)
	skel.set_bone_pose_position(other_i, p_other)
	skel.set_bone_pose_rotation(other_i, q_other)
	skel.set_bone_pose_scale(other_i, ARM_SCALE)
	skel.set_bone_pose_rotation(legl_i, q_leg)
	skel.set_bone_pose_rotation(legr_i, q_leg)
	skel.set_bone_pose_scale(head_i, Vector3.ONE * HEAD_SCALE)

	var torso_g := skel.get_bone_global_rest(torso_i)
	var limb_pose := torso_g * Transform3D(Basis(q_limb).scaled_local(ARM_SCALE), p_limb)
	var other_pose := torso_g * Transform3D(Basis(q_other).scaled_local(ARM_SCALE), p_other)
	var limb_rest_inv := skel.get_bone_global_rest(arm_i).affine_inverse()
	var other_rest_inv := skel.get_bone_global_rest(other_i).affine_inverse()

	b.parts["skel"] = skel
	b.parts["bones"] = {"arm": arm_i, "other": other_i, "fore": fore_i, "head": head_i, "legl": legl_i, "legr": legr_i}
	b.parts["base_q"] = {"arm": q_limb, "other": q_other, "leg": q_leg}

	# --- sites -----------------------------------------------------------------------------------
	# Arm sites: sample the rest-pose arm vertices for the top surface and section at a distance.
	var limb_att := _attachment(skel, LIMB_ARM)
	var other_att := _attachment(skel, OTHER_ARM)
	var arm_site := func(att: Node3D, pose_xf: Transform3D, rest_inv: Transform3D, sign_x: float, at: float, nm: String) -> Dictionary:
		var sec: Dictionary = _arm_section(data.arm_verts, at)
		var p_rest := Vector3(sign_x * (SHOULDER_X + at), sec.cy, sec.ztop)
		var skel_pose := pose_xf * rest_inv
		var p := skel_xf * (skel_pose * p_rest)
		var dist := skel_xf.basis * (skel_pose.basis * Vector3(sign_x, 0, 0))
		var xf := _frame(p, dist, Vector3.UP)
		var anchor := Node3D.new()
		anchor.name = nm
		att.add_child(anchor)
		anchor.transform = (skel_xf * pose_xf).affine_inverse() * xf
		b.anchors[nm] = anchor
		b._sites[nm] = xf
		var half_up: float = (sec.ztop - sec.cz) * ARM_SCALE.z * S
		var half_side: float = sec.hy * ARM_SCALE.y * S
		return {"half_up": half_up, "half_side": half_side, "xf": xf}
	var limb: Dictionary = arm_site.call(limb_att, limb_pose, limb_rest_inv, -1.0, TOURNIQUET_AT, "limb")
	var cut: Dictionary = arm_site.call(limb_att, limb_pose, limb_rest_inv, -1.0, CUT_AT, "limb_cut")
	var inj: Dictionary = arm_site.call(other_att, other_pose, other_rest_inv, 1.0, INJECT_AT, "injection")

	# Gunshot: the belly, a little toward his +Z side, on the front face of the torso.
	var belly_a := Vector3(-0.06, 0.235, 0)
	belly_a.z = _front_z(data.torso_verts, belly_a.x, belly_a.y)
	var gp := skel_xf * belly_a
	var gxf := _frame(gp, Vector3(1, 0, 0), Vector3.UP)
	var ganchor := Node3D.new()
	ganchor.name = "gunshot"
	rig.add_child(ganchor)
	ganchor.transform = gxf
	b.anchors["gunshot"] = ganchor
	b._sites["gunshot"] = gxf

	# --- overlays ------------------------------------------------------------------------------
	var lu: float = limb.half_up
	var ls: float = limb.half_side
	b.parts["tourniquet"] = Kit.make_tourniquet(b.anchors["limb"], lu, ls, lu, true)
	var cu: float = cut.half_up
	var cs: float = cut.half_side
	b.parts["stump"] = Kit.make_stump(b.anchors["limb_cut"], cu, cs, cu, 0.018)
	b.parts["dress_stump"] = Kit.make_stump_dressing(b.anchors["limb_cut"], cu, cs, cu)
	b.parts["wound"] = Kit.make_wound(ganchor, 0.032)
	var dress := Kit.make_pad(ganchor, 0.17)
	# A gauze band round the belly: a flat wide ring following the torso section.
	var torso_half_w := 0.191 * S
	var torso_h := gp.y
	var band := MeshInstance3D.new()
	band.mesh = Kit.cyl(1.0, 1.0, 0.1, 14, false)
	band.material_override = Kit.gauze_mat()
	band.transform = Transform3D(Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)).scaled_local(Vector3(torso_half_w * 1.03, 1.0, torso_h * 0.55)), Vector3(0, -torso_h * 0.5 + 0.004, -gp.z))
	dress.add_child(band)
	b.parts["dress_wound"] = dress

	# Blood drip paths (body local): run off the side of the limb / the flank onto the table.
	var lxf: Transform3D = limb.xf
	var cxf: Transform3D = cut.xf
	b.drips["limb"] = [lxf.origin + Vector3(0, -lu * 0.6, ls * 0.95), Vector3(lxf.origin.x, 0.003, lxf.origin.z + ls * 1.25)]
	b.drips["limb_cut"] = [cxf.origin + Vector3(0.02, -cu * 0.8, cs * 0.6), Vector3(cxf.origin.x + 0.04, 0.003, cxf.origin.z + cs * 0.7)]
	var ixf: Transform3D = inj.xf
	b.drips["injection"] = [ixf.origin + Vector3(0, -0.02, -inj.half_side), Vector3(ixf.origin.x, 0.003, ixf.origin.z - inj.half_side * 1.3)]
	b.drips["gunshot"] = [gp + Vector3(0, -torso_h * 0.3, torso_half_w * 0.9 - gp.z), Vector3(gp.x, 0.003, torso_half_w * 1.1)]
	return true


## Per frame: stir / fidget / twitch on the rig's bones. No allocations.
static func animate(b, jolt: float, env: float, fidget: float, twitch: float, t: float) -> void:
	var skel: Skeleton3D = b.parts["skel"]
	var bones: Dictionary = b.parts["bones"]
	var bq: Dictionary = b.parts["base_q"]
	var arm_lift := env * 0.9 + jolt * 0.35 + fidget * 0.25 * sin(t * 1.7) + twitch * 0.25 * sin(t * 37.0)
	var other_lift := env * 0.7 - jolt * 0.3 + fidget * 0.2 * sin(t * 1.3 + 1.0) + twitch * 0.15 * sin(t * 29.0)
	# Rotating about A +Y lifts the lying arm off the table (toward A +Z = up).
	skel.set_bone_pose_rotation(bones["arm"], Quaternion(Vector3(0, 0, 1), -jolt * 0.2) * (bq["arm"] as Quaternion) * Quaternion(Vector3(0, 1, 0), arm_lift * 0.6))
	skel.set_bone_pose_rotation(bones["other"], Quaternion(Vector3(0, 0, 1), jolt * 0.15) * (bq["other"] as Quaternion) * Quaternion(Vector3(0, 1, 0), -other_lift * 0.6))
	var kick := env * 0.5 + jolt * 0.25 + twitch * 0.1 * sin(t * 23.0)
	skel.set_bone_pose_rotation(bones["legl"], (bq["leg"] as Quaternion) * Quaternion(Vector3(1, 0, 0), -kick * 0.45 + fidget * 0.1 * sin(t * 0.9)))
	skel.set_bone_pose_rotation(bones["legr"], (bq["leg"] as Quaternion) * Quaternion(Vector3(1, 0, 0), -kick * 0.3 - fidget * 0.1 * sin(t * 1.1)))
	skel.set_bone_pose_rotation(bones["head"], Quaternion(Vector3(1, 0, 0), env * 0.35 + jolt * 0.2) * Quaternion(Vector3(0, 1, 0), fidget * 0.35 * sin(t * 0.6) + jolt * 0.3))


static func set_limb_removed(b, removed: bool) -> void:
	var skel: Skeleton3D = b.parts["skel"]
	var fore: int = b.parts["bones"]["fore"]
	skel.set_bone_pose_scale(fore, Vector3(0.001, 1.0, 1.0) if removed else Vector3.ONE)


# -- helpers --------------------------------------------------------------------------------------

## Transform of `node` relative to `ancestor`, from local transforms (works outside the tree).
static func _chain(node: Node3D, ancestor: Node3D) -> Transform3D:
	var xf := Transform3D()
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## +Y as close to `up` as possible while perpendicular to `x_dir`; Z = X cross Y.
static func _frame(origin: Vector3, x_dir: Vector3, up: Vector3) -> Transform3D:
	var x := x_dir.normalized()
	var y := (up - x * up.dot(x)).normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x, y, z), origin)


static func _attachment(skel: Skeleton3D, bone: String) -> BoneAttachment3D:
	var att := BoneAttachment3D.new()
	att.name = "At_" + bone
	att.bone_name = bone
	skel.add_child(att)
	return att


## Section of the rest arm at distance `at` from the shoulder: top z, centre y/z, half thickness in y.
static func _arm_section(verts: PackedVector3Array, at: float) -> Dictionary:
	var zmax := -1.0
	var zmin := 1.0
	var ymax := -1.0
	var ymin := 1.0
	# The Kenney forearm+hand is one box, so its section is the same all along: use every sample.
	for v in verts:
		zmax = maxf(zmax, v.z); zmin = minf(zmin, v.z)
		ymax = maxf(ymax, v.y); ymin = minf(ymin, v.y)
	return {"ztop": zmax, "cz": (zmax + zmin) * 0.5, "cy": (ymax + ymin) * 0.5, "hy": (ymax - ymin) * 0.5}


static func _front_z(verts: PackedVector3Array, x: float, y: float) -> float:
	var z := -1.0
	var w := 0.02
	while z < -0.5 and w < 0.3:
		for v in verts:
			if absf(v.x - x) < w and absf(v.y - y) < w:
				z = maxf(z, v.z)
		w *= 2.0
	return z


## Builds (once) the re-skinned body mesh with the forearm bind and baked vertex masks.
static func _mesh_data(body_mi: MeshInstance3D, head_mi: MeshInstance3D) -> Dictionary:
	if _cache.has("bob"):
		return _cache["bob"]
	var src_skin: Skin = body_mi.skin
	var bind_of := {}
	for i in src_skin.get_bind_count():
		bind_of[String(src_skin.get_bind_name(i))] = i
	var skin: Skin = src_skin.duplicate()
	var arm_rest := Vector3(-SHOULDER_X, 0.28775, -0.01725)
	var arm_b: int = bind_of.get(LIMB_ARM, 5)
	# Bind pose = inverse of the bone's global rest; rests here are pure translations.
	arm_rest = -src_skin.get_bind_pose(arm_b).origin
	skin.add_named_bind(FOREARM, Transform3D(Basis(), -(arm_rest + Vector3(-ELBOW, 0, 0))))
	var fore_b := skin.get_bind_count() - 1
	var torso_b: int = bind_of.get("torso", 3)
	var other_b: int = bind_of.get(OTHER_ARM, 4)
	var legl_b: int = bind_of.get("leg-left", 1)
	var legr_b: int = bind_of.get("leg-right", 2)

	var arrays := body_mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var nb := bones.size() / verts.size()
	var cols := PackedColorArray()
	cols.resize(verts.size())
	var arm_verts := PackedVector3Array()
	var torso_verts := PackedVector3Array()
	for i in verts.size():
		var v := verts[i]
		var uv := uvs[i]
		var bone := bones[i * nb]
		var skin_uv := uv.x > 0.875 and uv.y > 0.75
		var c := Color(0, 0, 0, 1.0 if skin_uv else 0.0)
		if bone == torso_b:
			torso_verts.append(v)
			c.r = 1.0
			c.b = smoothstep(-0.02, 0.09, v.z) * smoothstep(0.16, 0.22, v.y) * (1.0 - smoothstep(0.31, 0.345, v.y))
		elif bone == legl_b or bone == legr_b:
			c.r = 1.0
		elif bone == arm_b or bone == other_b:
			var along := absf(v.x) - SHOULDER_X
			if not skin_uv:
				c.r = 1.0
			if bone == arm_b:
				if skin_uv and along > 0.2 and along < 0.26:
					arm_verts.append(v)
				c.g = smoothstep(INFECT_FROM, INFECT_FULL, along)
				var wf := 1.0 if along > ELBOW else 0.0
				if wf > 0.0:
					bones[i * nb] = fore_b
					weights[i * nb] = wf
					if wf < 1.0:
						bones[i * nb + 1] = arm_b
						weights[i * nb + 1] = 1.0 - wf
		cols[i] = c
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_COLOR] = cols
	var body_mesh := ArrayMesh.new()
	body_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if nb == 8 else 0)

	var harr := head_mi.mesh.surface_get_arrays(0)
	var hv: PackedVector3Array = harr[Mesh.ARRAY_VERTEX]
	var huv: PackedVector2Array = harr[Mesh.ARRAY_TEX_UV]
	var hcols := PackedColorArray()
	hcols.resize(hv.size())
	for i in hv.size():
		var hskin := huv[i].x > 0.875 and huv[i].y > 0.75
		var hair := not hskin and (hv[i].y > 0.655 or (hv[i].z < -0.06 and hv[i].y > 0.42))
		hcols[i] = Color(1.0 if hair else 0.0, 0, 0, 1.0 if hskin else 0.0)
	harr[Mesh.ARRAY_COLOR] = hcols
	var hnb := (harr[Mesh.ARRAY_BONES] as PackedInt32Array).size() / hv.size()
	var head_mesh := ArrayMesh.new()
	head_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, harr, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if hnb == 8 else 0)

	var colormap: Texture2D = null
	var src_mat := body_mi.mesh.surface_get_material(0) as BaseMaterial3D
	if body_mi.get_surface_override_material(0) is BaseMaterial3D:
		src_mat = body_mi.get_surface_override_material(0)
	if src_mat != null:
		colormap = src_mat.albedo_texture
	var d := {
		"body_mesh": body_mesh, "head_mesh": head_mesh, "body_skin": skin, "colormap": colormap,
		"arm_verts": arm_verts, "torso_verts": torso_verts,
	}
	_cache["bob"] = d
	return d
