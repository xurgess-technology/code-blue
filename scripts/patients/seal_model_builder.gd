extends RefCounted
## The seal on its Blender model (`patient/seal`, assets/models/patients/seal/, art/seal/README.md).
##
## PatientBody tries this first and falls back to the procedural seal (seal_builder.gd) when the
## asset is missing or broken. Same frame: nose toward -X, tail +X, belly on the table at y = 0, the
## seal's left (+Z) holds the removable left fore flipper.
##
## What comes from the GLB:
##   Seal_Body, Seal_Paddle_L, Seal_FishingLine_L   skinned; the paddle is the piece past the cut loop
##   Seal_StumpCap_L, Seal_PaddleSevered_L          static, on the flipper_fore.L bone
##   site_injection / site_gunshot / site_limb / site_limb_cut   nodes on neck / spine / flipper_fore.L
## Both materials are replaced by per-body copies of seal_skin.gdshader, which reads pallor, grey,
## infect and breath like the procedural coat shader (PatientBody drives them through skin_mats).
##
## Motion: no AnimationPlayer runs. animate() samples the five clips itself every frame and blends
## them by the body's state, so the existing state logic (vitals, sedation, stirs, twitches, flatline)
## drives the clips:
##   Idle      the base; its playback rate follows the breathing rate (PatientBody's vitals curve) and
##             its ribs swell by the breathing depth
##   Fidget    blended in by the fidget amount (awake, low sedation)
##   Twitch    blended in below 25 vitals, plus each twitch spike
##   Stir      restarted by every stir(), weighted by its strength
##   Flatline  faded in after flatline()
## site_transform() stays the rest pose (Idle frame 0), because the surgery system re-places the
## minigame there every tick; the site anchors (and every overlay on them) follow their bones.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const KEY := "patient/seal"
const SHADER_PATH := "res://assets/models/patients/seal/seal_skin.gdshader"
const TEX_DIR := "res://assets/models/patients/seal/textures/"
const SITES := ["injection", "gunshot", "limb", "limb_cut"]
## Measured from the mesh rings by art/seal/blender_src/seal_build.py (seal_sites.json), built scale.
const SECTIONS := {
	"limb": {"half_up": 0.0335, "half_down": 0.0261, "half_side": 0.0659, "axis_depth": 0.0335, "shape": 2.3},
	"limb_cut": {"half_up": 0.0270, "half_down": 0.0211, "half_side": 0.0626, "axis_depth": 0.0270, "shape": 2.3},
}
## Metres along the site's +X to where the painted infection begins.
const INFECTION := {"limb": 0.0972, "limb_cut": 0.0216}
## Body half width and centre height at the gunshot's x (for the dressing band), built scale.
const FLANK := {"half_w": 0.300, "half_up": 0.195, "centre_y": 0.172}
const CLIPS := ["Idle", "Fidget", "Twitch", "Stir", "Flatline"]
const IDLE_LEN := 4.0
const IDLE_BREATH_HZ := 0.5
const STIR_LEN := 1.2

## Tools: force the procedural seal (fallback checks).
static var procedural_only := false
static var _shader: Shader
static var _tex := {}


static func _load_tex(nm: String) -> Texture2D:
	if not _tex.has(nm):
		var p := TEX_DIR + nm + ".png"
		_tex[nm] = load(p) as Texture2D if ResourceLoader.exists(p) else null
	return _tex[nm]


static func available() -> bool:
	if procedural_only:
		return false
	var assets = Engine.get_main_loop().root.get_node_or_null("/root/Assets") if Engine.get_main_loop() is SceneTree else null
	if assets == null or not assets.has(KEY):
		return false
	return ResourceLoader.exists(SHADER_PATH)


static func build(b) -> bool:
	if not available():
		return false
	var assets = Engine.get_main_loop().root.get_node("/root/Assets")
	var root: Node3D = assets.spawn(KEY)
	if root == null:
		return false
	var skels := root.find_children("*", "Skeleton3D", true, false)
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if skels.is_empty() or aps.is_empty():
		root.free()
		return false
	var skel: Skeleton3D = skels[0]
	var ap: AnimationPlayer = aps[0]
	var nodes := {}
	for nm in ["Seal_Body", "Seal_Paddle_L", "Seal_StumpCap_L", "Seal_FishingLine_L", "Seal_PaddleSevered_L"]:
		nodes[nm] = root.find_child(nm, true, false)
		if nodes[nm] == null:
			root.free()
			return false
	for st in SITES:
		if root.find_child("site_" + st, true, false) == null:
			root.free()
			return false
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	b.rig.add_child(root)

	# materials: one coat and one detail copy per body (pallor / infect are per patient)
	var coat := ShaderMaterial.new()
	coat.shader = _shader
	coat.set_shader_parameter(&"albedo_tex", _load_tex("Seal_Coat_albedo"))
	coat.set_shader_parameter(&"normal_tex", _load_tex("Seal_Coat_normal"))
	coat.set_shader_parameter(&"rough_tex", _load_tex("Seal_Coat_roughness"))
	coat.set_shader_parameter(&"infect_tex", _load_tex("Seal_Infect"))
	coat.set_shader_parameter(&"use_infection", true)
	var detail := ShaderMaterial.new()
	detail.shader = _shader
	detail.set_shader_parameter(&"albedo_tex", _load_tex("Seal_Detail_albedo"))
	detail.set_shader_parameter(&"normal_tex", _load_tex("Seal_Detail_normal"))
	detail.set_shader_parameter(&"rough_tex", _load_tex("Seal_Detail_roughness"))
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			var detail_surface := src != null and String(src.resource_name).contains("Detail")
			m.set_surface_override_material(i, detail if detail_surface else coat)
	b.skin_mats.append(coat)
	b.skin_mats.append(detail)
	b.breath_amp = 0.0   # the ribs bone breathes

	(nodes["Seal_StumpCap_L"] as Node3D).visible = false
	(nodes["Seal_FishingLine_L"] as Node3D).visible = false
	(nodes["Seal_PaddleSevered_L"] as Node3D).visible = false

	# clips: sampled by hand, so the player never runs
	var clips := {}
	for nm in CLIPS:
		if not ap.has_animation(nm):
			root.free()
			return false
		clips[nm] = _tracks(ap.get_animation(nm), skel)
	ap.active = false
	var bones: Array[int] = []
	for i in skel.get_bone_count():
		bones.append(i)
	var ribs := skel.find_bone("ribs")
	var st := {
		"skel": skel, "clips": clips, "bones": bones, "ribs": ribs, "last_t": 0.0,
		"idle_t": 0.0, "fid_t": 0.0, "tw_t": 0.0, "stir_t": 99.0, "stir_w": 0.0, "last_env": 0.0, "flat_w": 0.0,
	}
	b.parts["seal"] = st
	b.parts["limb_node"] = nodes["Seal_Paddle_L"]
	b.parts["cap"] = nodes["Seal_StumpCap_L"]
	b.parts["line"] = nodes["Seal_FishingLine_L"]
	b.parts["severed_src"] = nodes["Seal_PaddleSevered_L"]
	_pose(st, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)

	# sites: the rest pose from the posed bone chain; anchors are the bone-following nodes
	var to_rig := _chain_to(skel, b.rig)
	for s in SITES:
		var node := root.find_child("site_" + s, true, false) as Node3D
		var att := node.get_parent() as BoneAttachment3D
		var bone_xf := Transform3D()
		if att != null:
			bone_xf = _bone_global(skel, skel.find_bone(att.bone_name))
		b.anchors[s] = node
		b._sites[s] = (to_rig * bone_xf * node.transform).orthonormalized()
	for s in ["limb", "limb_cut"]:
		b.sections[s] = (SECTIONS[s] as Dictionary).duplicate()
		b.infection[s] = INFECTION[s]

	# overlays, fitted to the model
	var lsec: Dictionary = SECTIONS["limb"]
	var band_half := (float(lsec.half_up) + float(lsec.half_down)) * 0.5
	b.parts["tourniquet"] = Kit.make_tourniquet(b.anchors["limb"], band_half, float(lsec.half_side), band_half)
	var stump := Node3D.new()
	stump.name = "StumpMarker"   # the model's own cap is shown by set_limb_removed
	(b.anchors["limb_cut"] as Node3D).add_child(stump)
	b.parts["stump"] = stump
	b.parts["dress_stump"] = make_stump_dressing(b.anchors["limb_cut"], SECTIONS["limb_cut"])
	b.parts["wound"] = Kit.make_wound(b.anchors["gunshot"], 0.034)
	b.parts["dress_wound"] = _make_flank_dressing(b)

	# drip paths
	var gp: Vector3 = (b._sites["gunshot"] as Transform3D).origin
	b.drips["gunshot"] = [gp + Vector3(0.0, -0.07, -0.09), Vector3(gp.x + 0.03, 0.003, -FLANK.half_w - 0.05)]
	var ip: Vector3 = (b._sites["injection"] as Transform3D).origin
	b.drips["injection"] = [ip + Vector3(0.0, -0.06, -0.11), Vector3(ip.x, 0.003, -0.22)]
	var lxf: Transform3D = b._sites["limb"]
	var cxf: Transform3D = b._sites["limb_cut"]
	var lu := float(lsec.half_up)
	var lw := float(lsec.half_side)
	var cu := float((SECTIONS["limb_cut"] as Dictionary).half_up)
	b.drips["limb"] = [lxf.origin + lxf.basis.z * lw * 0.9 - Vector3(0, lu, 0), Vector3(lxf.origin.x + lxf.basis.z.x * lw * 1.4, 0.003, lxf.origin.z + lxf.basis.z.z * lw * 1.4)]
	b.drips["limb_cut"] = [cxf.origin + cxf.basis.x * 0.012 - Vector3(0, cu, 0), Vector3(cxf.origin.x + cxf.basis.x.x * 0.06, 0.003, cxf.origin.z + cxf.basis.x.z * 0.06)]
	return true


## {bone index: [rotation track or -1, scale track or -1]} for one clip.
static func _tracks(anim: Animation, skel: Skeleton3D) -> Dictionary:
	var out := {}
	for i in anim.get_track_count():
		var bone := skel.find_bone(String(anim.track_get_path(i).get_concatenated_subnames()))
		if bone < 0:
			continue
		var e: Array = out.get(bone, [-1, -1])
		match anim.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				e[0] = i
			Animation.TYPE_SCALE_3D:
				e[1] = i
		out[bone] = e
	return {"anim": anim, "tracks": out}


static func _rot(clip: Dictionary, bone: int, time: float, skel: Skeleton3D) -> Quaternion:
	var e = (clip.tracks as Dictionary).get(bone)
	if e == null or int(e[0]) < 0:
		return skel.get_bone_rest(bone).basis.get_rotation_quaternion()
	return (clip.anim as Animation).rotation_track_interpolate(int(e[0]), time)


static func _scl(clip: Dictionary, bone: int, time: float) -> Vector3:
	var e = (clip.tracks as Dictionary).get(bone)
	if e == null or int(e[1]) < 0:
		return Vector3.ONE
	return (clip.anim as Animation).scale_track_interpolate(int(e[1]), time)


## Blend the clips onto the skeleton. Weights 0..1; depth scales the Idle breath.
static func _pose(st: Dictionary, idle_t: float, fid_w: float, tw_w: float, stir_w: float, flat_w: float, stir_t: float, depth: float) -> void:
	var skel: Skeleton3D = st.skel
	var c: Dictionary = st.clips
	var fid_t: float = st.fid_t
	var tw_t: float = st.tw_t
	for bone in st.bones:
		var q := _rot(c.Idle, bone, idle_t, skel)
		if fid_w > 0.001:
			q = q.slerp(_rot(c.Fidget, bone, fid_t, skel), fid_w)
		if tw_w > 0.001:
			q = q.slerp(_rot(c.Twitch, bone, tw_t, skel), tw_w)
		if stir_w > 0.001:
			q = q.slerp(_rot(c.Stir, bone, stir_t, skel), stir_w)
		if flat_w > 0.001:
			q = q.slerp(_rot(c.Flatline, bone, 0.0, skel), flat_w)
		skel.set_bone_pose_rotation(bone, q)
	var ribs: int = st.ribs
	if ribs >= 0:
		var s := Vector3.ONE + (_scl(c.Idle, ribs, idle_t) - Vector3.ONE) * depth
		if fid_w > 0.001:
			s = s.lerp(Vector3.ONE + (_scl(c.Fidget, ribs, fid_t) - Vector3.ONE) * depth, fid_w)
		if tw_w > 0.001:
			s = s.lerp(_scl(c.Twitch, ribs, tw_t), tw_w)
		if stir_w > 0.001:
			s = s.lerp(_scl(c.Stir, ribs, stir_t), stir_w)
		if flat_w > 0.001:
			s = s.lerp(_scl(c.Flatline, ribs, 0.0), flat_w)
		skel.set_bone_pose_scale(ribs, s)


static func _bone_global(skel: Skeleton3D, bone: int) -> Transform3D:
	var xf := Transform3D()
	var i := bone
	while i >= 0:
		var local := Transform3D(Basis(skel.get_bone_pose_rotation(i)).scaled(skel.get_bone_pose_scale(i)), skel.get_bone_pose_position(i))
		xf = local * xf
		i = skel.get_bone_parent(i)
	return xf


## The transform from `node`'s space up to (not including) `ancestor`.
static func _chain_to(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D()
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func animate(b, jolt: float, env: float, fidget: float, twitch: float, t: float) -> void:
	var st: Dictionary = b.parts.get("seal", {})
	if st.is_empty():
		return
	var dt := clampf(t - float(st.last_t), 0.0, 0.1)
	st.last_t = t
	var flat: bool = b._flat
	var v01 := float(b._vitals) / 100.0
	# Idle runs at the body's breathing rate (PatientBody: 0.24 Hz healthy .. 0.75 Hz failing)
	var rate := lerpf(0.75, 0.24, v01)
	var depth := 0.0 if flat else lerpf(0.35, 1.0, v01)
	if not flat:
		st.idle_t = fposmod(float(st.idle_t) + dt * rate / IDLE_BREATH_HZ, IDLE_LEN)
	st.fid_t = fposmod(float(st.fid_t) + dt, 3.0)
	st.tw_t = fposmod(float(st.tw_t) + dt, 2.0)
	# a new stir restarts the Stir clip, weighted by how hard it was
	if env > float(st.last_env) + 0.04 and not flat:
		st.stir_t = 0.0
		st.stir_w = clampf(env * 1.25, 0.25, 1.0)
	st.last_env = env
	st.stir_t = float(st.stir_t) + dt
	var stir_t: float = st.stir_t
	var ws := 0.0
	if stir_t < STIR_LEN:
		ws = float(st.stir_w) * smoothstep(0.0, 0.06, stir_t) * (1.0 - smoothstep(STIR_LEN - 0.25, STIR_LEN, stir_t))
	var wf := clampf(fidget * 0.9, 0.0, 1.0)
	var low := 0.0 if flat else clampf((25.0 - float(b._vitals)) / 25.0, 0.0, 1.0)
	var wt := clampf(maxf(low * 0.85, twitch), 0.0, 1.0)
	st.flat_w = move_toward(float(st.flat_w), 1.0 if flat else 0.0, dt * 0.8)
	_pose(st, float(st.idle_t), wf, wt, ws, float(st.flat_w), minf(stir_t, STIR_LEN), depth)
	var line: Node3D = b.parts.get("line")
	if line != null:
		line.visible = b.ailment_id == "amputation" and not b._limb_removed


static func set_limb_removed(b, removed: bool) -> void:
	var paddle: Node3D = b.parts.get("limb_node")
	var cap: Node3D = b.parts.get("cap")
	var line: Node3D = b.parts.get("line")
	if paddle != null:
		paddle.visible = not removed
	if cap != null:
		cap.visible = removed
	if line != null and removed:
		line.visible = false


## A static copy of the paddle past the cut (with its cut face and the fishing line), where the
## paddle is right now.
static func make_severed_limb(b, parent: Node) -> Node3D:
	var src: MeshInstance3D = b.parts.get("severed_src")
	if src == null or parent == null:
		return null
	var copy := src.duplicate() as MeshInstance3D
	copy.name = "SeveredPaddle"
	for i in src.mesh.get_surface_count():
		copy.set_surface_override_material(i, src.get_surface_override_material(i))
	parent.add_child(copy)
	copy.visible = true
	if src.is_inside_tree() and copy.is_inside_tree():
		copy.global_transform = src.global_transform
	return copy


# -- overlays ---------------------------------------------------------------------------------------

## Gauze wrapped round the stub and over the cut end, in the `limb_cut` site frame (+X distal,
## +Y up out of the skin): diagonal wraps with frayed edges, a padded dome over the stump, tape, and
## blood seeping through at the end.
static func make_stump_dressing(parent: Node3D, sec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "StumpDressing"
	parent.add_child(root)
	var hu := float(sec.half_up)
	var hd := float(sec.get("half_down", hu))
	var hs := float(sec.half_side)
	var cy := -(hu + hd) * 0.5
	var ry := (hu + hd) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 24
	var xs := [-0.062, -0.058, -0.05, -0.04, -0.03, -0.02, -0.01, 0.0, 0.008, 0.016, 0.023, 0.029, 0.034, 0.038, 0.041, 0.043]
	var rows := []
	for x in xs:
		var dome := smoothstep(0.004, 0.044, x)
		var k := sqrt(maxf(0.0, 1.0 - dome * dome * dome)) if x > 0.004 else 1.0
		var row := []
		for j in segs + 1:
			var a := TAU * float(j) / float(segs)
			# diagonal wraps: a ridge where each turn of gauze overlaps the last
			var turn := fposmod(x / 0.017 + a / TAU * 0.6, 1.0)
			var ridge := 0.08 * smoothstep(0.75, 0.95, turn) * (1.0 - smoothstep(0.95, 1.0, turn))
			var lump := 0.03 * sin(a * 3.0 + x * 90.0) + 0.02 * sin(a * 7.0 - x * 150.0)
			var fray := 0.06 * (1.0 - smoothstep(-0.062, -0.052, x))
			var r := (1.0 + 0.16 + ridge + lump + fray) * k
			row.append(Vector3(x, cy + sin(a) * ry * r, cos(a) * hs * r))
		rows.append(row)
	var tip := Vector3(0.046, cy, 0.0)
	for i in xs.size() - 1:
		for j in segs:
			var p00: Vector3 = rows[i][j]
			var p01: Vector3 = rows[i][j + 1]
			var p10: Vector3 = rows[i + 1][j]
			var p11: Vector3 = rows[i + 1][j + 1]
			for p in [p00, p10, p11, p00, p11, p01]:
				st.set_uv(Vector2(float(j) / segs, float(i) / xs.size()))
				st.add_vertex(p)
	for j in segs:
		for p in [rows[xs.size() - 1][j], tip, rows[xs.size() - 1][j + 1]]:
			st.add_vertex(p)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Wrap"
	mi.mesh = st.commit()
	var gauze := Kit.mat("seal_stump_gauze", Color(0.84, 0.82, 0.76), 0.97)
	gauze.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = gauze
	root.add_child(mi)
	# tape across the wraps, and blood soaking through the end
	var tape := Kit.mat("tape", Color(0.86, 0.82, 0.7), 0.9)
	Kit.add_mesh(root, Kit.box(Vector3(0.018, 0.003, hs * 2.5)), tape, Transform3D(Basis(Vector3.RIGHT, 0.25), Vector3(-0.028, cy + ry * 1.17, 0.0)), "Tape")
	var seep := Kit.decal(root, Kit.blood_tex(), Vector3(hs * 1.3, 0.05, (hu + hd) * 1.1),
		Transform3D(Basis(Vector3(0, 0, -1), PI * 0.5), Vector3(0.05, cy, 0.0)))
	seep.name = "Seep"
	var seep2 := Kit.decal(root, Kit.blood_tex(), Vector3(0.03, 0.04, 0.03),
		Transform3D(Basis(), Vector3(0.02, cy + ry * 1.3, hs * 0.3)))
	seep2.name = "SeepTop"
	return root


## A packed pad on the flank wound and a gauze band round the body, in the gunshot site frame.
static func _make_flank_dressing(b) -> Node3D:
	var dress := Kit.make_pad(b.anchors["gunshot"], 0.13)
	var gxf: Transform3D = b._sites["gunshot"]
	var band := MeshInstance3D.new()
	band.name = "Band"
	band.mesh = Kit.cyl(1.0, 1.0, 0.10, 20, false)
	band.material_override = Kit.gauze_mat()
	var band_global := Transform3D(Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)).scaled_local(Vector3(FLANK.half_w * 1.04, 1.0, FLANK.half_up * 1.06)), Vector3(gxf.origin.x, FLANK.centre_y, 0))
	band.transform = gxf.affine_inverse() * band_global
	dress.add_child(band)
	return dress
