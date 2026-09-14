extends Node3D
## Seal art test viewer: the Blender seal patient (assets/models/patients/seal/seal.glb) on the OR
## table in the game's look, in every surgery state, for screenshots. It does not touch the game;
## it only builds overlays with PatientKit the way the seal builder does.
##
##   godot --path . --resolution 1280x720 tools/seal_viewer.tscn                 # all shots -> art/seal/godot_shots/
##   godot --path . --resolution 1280x720 tools/seal_viewer.tscn -- --only=face  # shots whose name contains "face"
##   godot --path . tools/seal_viewer.tscn -- --view                              # stays open, idle clip, orbit with arrow keys
##   godot --headless --path . tools/seal_viewer.tscn -- --check                  # structure, sites and masks report

const Kit := preload("res://scripts/patients/patient_kit.gd")
const BodyScript := preload("res://scripts/patient_body.gd")
const SEAL_GLB := "res://assets/models/patients/seal/seal.glb"
const SHADER := preload("res://assets/models/patients/seal/seal_skin.gdshader")
const TEX := "res://assets/models/patients/seal/textures/"
const SHOT_DIR := "res://art/seal/godot_shots"
const SITES := ["injection", "gunshot", "limb", "limb_cut"]
## Section numbers measured from the mesh by seal_build.py (art/seal/blender_src/seal_sites.json).
var sections := {}

var table_top := 0.9
var seal: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var coat_mats: Array[ShaderMaterial] = []
var detail_mat: ShaderMaterial
var overlays: Array[Node] = []
var old_seal: Node3D
var cam: Camera3D
var lamp: SpotLight3D
var fill: OmniLight3D
var flashlight: SpotLight3D
var env: WorldEnvironment
var table2_x := 2.6
var view_yaw := 0.8


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_load_sections()
	_build_room()
	_spawn_seal()
	if args.has("check"):
		await _check()
		get_tree().quit(0)
		return
	if args.has("view"):
		_play("Idle")
		_look_34()
		return
	await _run_shots(String(args.get("only", "")))
	get_tree().quit(0)


func _process(delta: float) -> void:
	if not OS.get_cmdline_user_args().has("--view"):
		return
	if Input.is_key_pressed(KEY_LEFT):
		view_yaw -= delta
	if Input.is_key_pressed(KEY_RIGHT):
		view_yaw += delta
	var o := seal.global_position + Vector3(-0.1, 0.12, 0)
	cam.global_position = o + Vector3(sin(view_yaw) * 1.9, 1.1, cos(view_yaw) * 1.9)
	cam.look_at(o)


func _load_sections() -> void:
	var f := FileAccess.open("res://art/seal/blender_src/seal_sites.json", FileAccess.READ)
	if f == null:
		push_warning("seal_viewer: no seal_sites.json, using defaults")
		return
	var d = JSON.parse_string(f.get_as_text())
	if d is Dictionary:
		for s in SITES:
			if d.has(s):
				sections[s] = d[s].get("section", {})


# -- room -------------------------------------------------------------------------------------------

func _build_room() -> void:
	env = Look.make_environment()
	add_child(env)
	Look.apply_quality(self, Look.QUALITY_HIGH)
	var assets = get_node_or_null("/root/Assets")
	var floor_mat := Kit.mat("lab_floor", Color(0.32, 0.34, 0.33), 0.9)
	if assets != null and assets.has("mat/floor"):
		floor_mat = assets.material("mat/floor")
	Kit.add_mesh(self, Kit.box(Vector3(10, 0.1, 8)), floor_mat, Transform3D(Basis(), Vector3(1.3, -0.05, 0)), "Floor")
	var wall := Kit.mat("lab_wall", Color(0.42, 0.5, 0.47), 0.9)
	if assets != null and assets.has("mat/wall_tile"):
		wall = assets.material("mat/wall_tile")
	Kit.add_mesh(self, Kit.box(Vector3(10, 3, 0.2)), wall, Transform3D(Basis(), Vector3(1.3, 1.5, -2.6)), "WallN")
	Kit.add_mesh(self, Kit.box(Vector3(0.2, 3, 8)), wall, Transform3D(Basis(), Vector3(-3.2, 1.5, 0)), "WallW")
	for x in [0.0, table2_x]:
		var table: Node3D = null
		if assets != null and assets.has("prop/table_op"):
			table = assets.spawn("prop/table_op")
		if table != null:
			add_child(table)
			table.position.x = x
			var top := -1.0
			for mi in table.find_children("*", "MeshInstance3D", true, false):
				var aabb: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
				top = maxf(top, aabb.end.y)
			table_top = top
		else:
			Kit.add_mesh(self, Kit.box(Vector3(2.0, 0.9, 1.1)), Kit.mat("lab_table", Color(0.6, 0.64, 0.66), 0.4, 0.5), Transform3D(Basis(), Vector3(x, 0.45, 0)), "Table")
	lamp = SpotLight3D.new()
	lamp.position = Vector3(0.1, table_top + 1.7, 0.2)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_angle = 42
	lamp.spot_range = 5.0
	lamp.light_energy = 2.2
	lamp.light_color = Color(1.0, 0.97, 0.9)
	lamp.shadow_enabled = true
	add_child(lamp)
	Kit.add_mesh(self, Kit.cyl(0.32, 0.4, 0.12, 20), Kit.mat("lamp_shell", Color(0.7, 0.72, 0.7), 0.4, 0.6), Transform3D(Basis(), lamp.position + Vector3(0, 0.1, 0)), "LampShell")
	Kit.add_mesh(self, Kit.cyl(0.3, 0.3, 0.02, 20), Kit.mat("lamp_glass", Color(1, 1, 0.95), 0.2, 0.0, Color(1, 0.97, 0.9), 1.2), Transform3D(Basis(), lamp.position + Vector3(0, 0.03, 0)), "LampGlass")
	fill = OmniLight3D.new()
	fill.position = Vector3(1.8, 2.2, 1.8)
	fill.light_energy = 0.8
	fill.omni_range = 6.0
	fill.light_color = Color(0.7, 0.85, 0.8)
	add_child(fill)
	cam = Camera3D.new()
	cam.fov = 50
	add_child(cam)
	cam.current = true
	# the player's flashlight (scripts/player.gd), off until a dark shot
	flashlight = SpotLight3D.new()
	flashlight.position = Vector3(0.18, -0.16, 0.0)
	flashlight.light_color = Color(1.0, 0.86, 0.62)
	flashlight.light_energy = 4.5
	flashlight.spot_range = 14.0
	flashlight.spot_angle = 26.0
	flashlight.spot_angle_attenuation = 0.55
	flashlight.spot_attenuation = 1.1
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.03
	flashlight.shadow_normal_bias = 1.0
	flashlight.light_volumetric_fog_energy = 2.8
	flashlight.visible = false
	cam.add_child(flashlight)


func _lights(mode: String) -> void:
	var dark := mode == "dark"
	lamp.visible = not dark
	fill.visible = not dark
	flashlight.visible = dark
	for n in ["LampGlass"]:
		var g := get_node_or_null(n) as MeshInstance3D
		if g != null:
			g.visible = not dark


# -- the seal ---------------------------------------------------------------------------------------

func _tex(nm: String) -> Texture2D:
	return load(TEX + nm + ".png") as Texture2D


func _spawn_seal() -> void:
	var packed := load(SEAL_GLB) as PackedScene
	seal = packed.instantiate() as Node3D
	add_child(seal)
	seal.position = Vector3(0, table_top, 0)
	for n in seal.find_children("*", "Skeleton3D", true, false):
		skel = n
	for n in seal.find_children("*", "AnimationPlayer", true, false):
		anim = n
	for nm in ["Idle", "Twitch", "Fidget", "Flatline"]:
		if anim != null and anim.has_animation(nm):
			anim.get_animation(nm).loop_mode = Animation.LOOP_LINEAR
	var coat := ShaderMaterial.new()
	coat.shader = SHADER
	coat.set_shader_parameter("albedo_tex", _tex("Seal_Coat_albedo"))
	coat.set_shader_parameter("normal_tex", _tex("Seal_Coat_normal"))
	coat.set_shader_parameter("rough_tex", _tex("Seal_Coat_roughness"))
	coat.set_shader_parameter("infect_tex", _tex("Seal_Infect"))
	coat.set_shader_parameter("use_infection", true)
	detail_mat = ShaderMaterial.new()
	detail_mat.shader = SHADER
	detail_mat.set_shader_parameter("albedo_tex", _tex("Seal_Detail_albedo"))
	detail_mat.set_shader_parameter("normal_tex", _tex("Seal_Detail_normal"))
	detail_mat.set_shader_parameter("rough_tex", _tex("Seal_Detail_roughness"))
	if OS.get_environment("SEAL_NOGLINT") != "":
		detail_mat.set_shader_parameter("eye_glint", 0.0)
	coat_mats = [coat]
	for mi in seal.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			var nm := String(src.resource_name) if src != null else ""
			m.set_surface_override_material(i, detail_mat if nm.contains("Detail") else coat)
	_reset_state()


func _mesh(nm: String) -> MeshInstance3D:
	return seal.find_child(nm, true, false) as MeshInstance3D


func _site(nm: String) -> Node3D:
	return seal.find_child("site_" + nm, true, false) as Node3D


func _reset_state() -> void:
	for o in overlays:
		if is_instance_valid(o):
			o.queue_free()
	overlays.clear()
	_mesh("Seal_Paddle_L").visible = true
	_mesh("Seal_StumpCap_L").visible = false
	_mesh("Seal_FishingLine_L").visible = false
	_mesh("Seal_PaddleSevered_L").visible = false
	_param("infect", 0.0)
	_param("pallor", 0.0)
	_param("grey", 0.0)
	_param("highlight_injection", 0.0)
	_param("highlight_gunshot", 0.0)
	if old_seal != null:
		old_seal.queue_free()
		old_seal = null
	_lights("lamp")


func _param(param: String, v: float) -> void:
	for m in coat_mats:
		m.set_shader_parameter(param, v)
	detail_mat.set_shader_parameter(param, v)


func _play(nm: String, at := 0.0, pause := false) -> void:
	if anim == null or not anim.has_animation(nm):
		return
	anim.play(nm)
	anim.seek(at, true)
	if pause:
		anim.pause()


func _sec(site: String) -> Dictionary:
	return sections.get(site, {"half_up": 0.03, "half_side": 0.06, "axis_depth": 0.03})


func _state(kind: String) -> void:
	match kind:
		"amputation":
			_param("infect", 1.0)
			_mesh("Seal_FishingLine_L").visible = true
		"tourniquet":
			_param("infect", 1.0)
			_mesh("Seal_FishingLine_L").visible = true
			var s := _sec("limb")
			var t := Kit.make_tourniquet(_site("limb"), float(s.half_up), float(s.half_side), float(s.axis_depth))
			(t.get_node("Band") as Node3D).scale = Vector3(1.0, 0.97, 0.97)
			overlays.append(t)
		"amputated", "dressed_stump":
			_param("infect", 1.0)
			var s := _sec("limb")
			overlays.append(Kit.make_tourniquet(_site("limb"), float(s.half_up), float(s.half_side), float(s.axis_depth)))
			_mesh("Seal_Paddle_L").visible = false
			_mesh("Seal_FishingLine_L").visible = false
			_mesh("Seal_StumpCap_L").visible = kind == "amputated"
			var sev := _mesh("Seal_PaddleSevered_L")
			var copy := sev.duplicate() as MeshInstance3D
			add_child(copy)
			copy.visible = true
			# lying on the table beside the stump, cut face toward the camera
			var tip := seal.global_transform * Vector3(0.12, 0.0, 0.66)
			copy.global_transform = Transform3D(Basis(Vector3.UP, 1.2), tip + Vector3(0, 0.026, 0))
			overlays.append(copy)
			if kind == "dressed_stump":
				var c := _sec("limb_cut")
				overlays.append(Kit.make_stump_dressing(_site("limb_cut"), float(c.half_up), float(c.half_side), float(c.axis_depth)))
		"gunshot":
			var w: Dictionary = Kit.make_wound(_site("gunshot"), 0.036)
			(w.emptied as Node3D).visible = false
			overlays.append(w.root)
		"injection":
			_param("highlight_injection", 1.0)
		"gun_mask":
			_param("highlight_gunshot", 1.0)
		"low":
			_param("pallor", 0.8)
		"dead":
			_param("pallor", 1.0)
			_param("grey", 1.0)
		"axes":
			for st in SITES:
				overlays.append(Kit.make_axes(_site(st), 0.1, st))


func _side_by_side() -> void:
	old_seal = BodyScript.create("seal")
	add_child(old_seal)
	old_seal.position = Vector3(table2_x, table_top, 0)
	old_seal.set_ailment("amputation")
	old_seal.set_sedation(1.0)


# -- shots ------------------------------------------------------------------------------------------

func _place(pos: Vector3, target: Vector3) -> void:
	cam.global_position = pos
	cam.look_at(target, Vector3.UP)


func _look_34() -> void:
	var o := seal.global_position
	_place(o + Vector3(1.35, 1.25, 1.5), o + Vector3(-0.1, 0.12, 0))


func _look(view: String) -> void:
	var o := seal.global_position
	cam.fov = 50
	match view:
		"34":
			_look_34()
		"34b":
			_place(o + Vector3(-1.45, 1.15, -1.45), o + Vector3(-0.1, 0.12, 0))
		"top":
			_place(o + Vector3(-0.05, 2.1, 0.001), o + Vector3(-0.05, 0, 0))
		"side":
			_place(o + Vector3(-0.1, 0.45, 2.4), o + Vector3(-0.1, 0.15, 0))
		"face":
			cam.fov = 30
			_place(o + Vector3(-1.30, 0.62, 0.78), o + Vector3(-0.76, 0.17, 0.05))
		"face_front":
			cam.fov = 28
			_place(o + Vector3(-1.80, 0.52, 0.30), o + Vector3(-0.80, 0.16, 0.03))
		"cut":
			# the saw's view turned round: from past the cut, looking back at the stump face
			var ct: Transform3D = _site("limb_cut").global_transform
			var axis := ct.origin - ct.basis.y * float(_sec("limb_cut").get("axis_depth", 0.025))
			_place(axis + ct.basis.x * 0.26 + ct.basis.y * 0.16 + ct.basis.z * 0.08, axis)
		"player":
			# standing at the table's left side, eye height 1.6 m, looking down at the patient
			_place(Vector3(o.x - 0.2, 1.62, 1.35), o + Vector3(-0.15, 0.12, 0.1))
		"player_head":
			_place(Vector3(o.x - 1.55, 1.62, 0.55), o + Vector3(-0.72, 0.15, 0.0))
		"pair":
			cam.fov = 55
			_place(Vector3(table2_x * 0.5, table_top + 1.75, 2.6), Vector3(table2_x * 0.5, table_top + 0.1, 0))
		"pair_top":
			cam.fov = 55
			_place(Vector3(table2_x * 0.5, table_top + 2.6, 0.01), Vector3(table2_x * 0.5, table_top, 0))
		_:
			# "site:<name>[:<dist>]": the minigame's camera, above the site and a little back
			var bits := view.split(":")
			var st: Transform3D = _site(bits[1]).global_transform
			var d := float(bits[2]) if bits.size() > 2 else 0.42
			_place(st.origin + st.basis.y * d - st.basis.x * d * 0.35 + Vector3(0, 0, 0.001), st.origin)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(nm: String) -> void:
	await RenderingServer.frame_post_draw
	if DisplayServer.get_name() == "headless":
		return
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var p := "%s/%s.png" % [SHOT_DIR, nm]
	img.save_png(ProjectSettings.globalize_path(p))
	print("[seal_viewer] wrote ", p)


func _run_shots(only: String) -> void:
	var shots := [
		# name, states, lights, view, clip, clip time, wait
		["or_table_34", [], "lamp", "34", "Idle", 0.0, 0.5],
		["or_table_34b", [], "lamp", "34b", "Idle", 1.0, 0.5],
		["or_table_top", [], "lamp", "top", "Idle", 0.0, 0.5],
		["or_table_side", [], "lamp", "side", "Idle", 0.0, 0.5],
		["face", [], "lamp", "face", "Idle", 0.0, 0.5],
		["face_front", [], "lamp", "face_front", "Idle", 0.0, 0.5],
		["amputation_34", ["amputation"], "lamp", "34", "Idle", 0.0, 0.5],
		["amputation_site", ["amputation"], "lamp", "site:limb_cut:0.5", "Idle", 0.0, 0.5],
		["tourniquet_site", ["tourniquet"], "lamp", "site:limb:0.45", "Idle", 0.0, 0.5],
		["stump_cut", ["amputated"], "lamp", "cut", "Idle", 0.0, 0.5],
		["stump_cut_top", ["amputated"], "lamp", "site:limb_cut:0.45", "Idle", 0.0, 0.5],
		["stump_severed_34", ["amputated"], "lamp", "34", "Idle", 0.0, 0.5],
		["stump_dressed", ["dressed_stump"], "lamp", "site:limb_cut:0.45", "Idle", 0.0, 0.5],
		["gunshot_site", ["gunshot"], "lamp", "site:gunshot:0.42", "Idle", 0.0, 0.5],
		["gunshot_mask", ["gun_mask"], "lamp", "site:gunshot:0.6", "Idle", 0.0, 0.5],
		["injection_site", ["injection"], "lamp", "site:injection:0.42", "Idle", 0.0, 0.5],
		["sites_axes", ["axes"], "lamp", "34", "", 0.0, 0.3],
		["dark_flashlight", [], "dark", "player", "Idle", 0.0, 0.8],
		["dark_flashlight_face", [], "dark", "player_head", "Idle", 0.0, 0.8],
		["dark_flashlight_amputation", ["amputation"], "dark", "player", "Idle", 0.0, 0.8],
		["stir", [], "lamp", "34", "Stir", 0.2, 0.05],
		["fidget", [], "lamp", "34", "Fidget", 0.9, 0.05],
		["twitch_low_vitals", ["low"], "lamp", "34", "Twitch", 0.3, 0.05],
		["flatline", ["dead"], "lamp", "34", "Flatline", 0.0, 0.3],
		["side_by_side", ["pair"], "lamp", "pair", "Idle", 0.0, 0.8],
		["side_by_side_top", ["pair"], "lamp", "pair_top", "Idle", 0.0, 0.8],
	]
	for s in shots:
		var nm: String = s[0]
		if only != "" and not nm.contains(only):
			continue
		_reset_state()
		for st in s[1]:
			if st == "pair":
				_side_by_side()
			else:
				_state(st)
		_lights(s[2])
		await get_tree().process_frame
		_look(s[3])
		if String(s[4]) != "":
			_play(s[4], float(s[5]), float(s[6]) <= 0.1)
		elif anim != null:
			anim.stop()
		await _wait(maxf(float(s[6]), 0.15))
		await _snap(nm)


# -- headless report --------------------------------------------------------------------------------

func _check() -> void:
	await get_tree().process_frame
	print("[check] skeleton: ", skel.name if skel != null else "none", " bones=", skel.get_bone_count() if skel != null else 0)
	print("[check] animations: ", anim.get_animation_list() if anim != null else [])
	var tris := 0
	for mi in seal.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var t := 0
		var surf := []
		for i in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(i)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			t += idx.size() / 3
			var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
			var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
			var mat := m.mesh.surface_get_material(i)
			surf.append("%s colors=%d uv2=%d" % [mat.resource_name if mat != null else "?", cols.size(), uv2.size()])
		tris += t
		print("[check] mesh %s parent=%s(%s) tris=%d skin=%s surfaces=%s" % [m.name, m.get_parent().name, m.get_parent().get_class(), t, m.skin != null, surf])
	print("[check] total tris ", tris)
	for st in SITES:
		var n := _site(st)
		if n == null:
			print("[check] MISSING site ", st)
			continue
		var local := seal.global_transform.affine_inverse() * n.global_transform
		print("[check] site %-9s parent=%s pos=(%.3f, %.3f, %.3f) X=(%.2f, %.2f, %.2f) Y=(%.2f, %.2f, %.2f) Z=(%.2f, %.2f, %.2f)" % [
			st, n.get_parent().name, local.origin.x, local.origin.y, local.origin.z,
			local.basis.x.x, local.basis.x.y, local.basis.x.z, local.basis.y.x, local.basis.y.y, local.basis.y.z,
			local.basis.z.x, local.basis.z.y, local.basis.z.z])
	# mask sanity: infection at the paddle tip should be 1, the injection stripe peak near 1
	var pad := _mesh("Seal_Paddle_L")
	var arr := pad.mesh.surface_get_arrays(0)
	var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var mx := 0.0
	var mid := 0
	for c in cols:
		mx = maxf(mx, c.r)
		if c.r > 0.2 and c.r < 0.8:
			mid += 1
	print("[check] paddle infection max=%.3f mid-values=%d of %d" % [mx, mid, cols.size()])
	var distinct := {}
	for c in cols:
		distinct[snappedf(c.r, 0.001)] = true
	var uv2s: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	var ymin := 9.0
	var ymax := -9.0
	for u in uv2s:
		ymin = minf(ymin, u.y)
		ymax = maxf(ymax, u.y)
	print("[check] paddle infection values ", distinct.keys(), " (linear expects 0.394 on the ring 17 mm past the infection start); UV2.y range %.3f..%.3f" % [ymin, ymax])
	var body := _mesh("Seal_Body")
	var mxb := 0.0
	var mxa := 0.0
	var mxg := 0.0
	for i in body.mesh.get_surface_count():
		var ba := body.mesh.surface_get_arrays(i)
		var bc: PackedColorArray = ba[Mesh.ARRAY_COLOR]
		for c in bc:
			mxb = maxf(mxb, c.b)
			mxa = maxf(mxa, c.a)
			mxg = maxf(mxg, c.g)
	print("[check] body masks: injection max=%.3f gunshot max=%.3f breath max=%.3f" % [mxb, mxa, mxg])
