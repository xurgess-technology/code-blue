extends Node3D
## Look-dev viewer for the Blender-built humans (art pass only; nothing in the game uses them yet).
## Builds a corridor and an OR with the game's environment, post layer, torch and work lamp, places
## the variations, and saves windowed 1280x720 screenshots into art/human/godot_shots/.
##
##   godot --path . --resolution 1280x720 art/human/viewer/human_viewer.tscn
##   options (after --): --only=a,b  --nopost  --hold (stay on the first shot, no screenshots)  --report (print stats, quit)

const HB := preload("res://scripts/hospital_builder.gd")
const Tables := preload("res://scripts/loop/tables.gd")
const SurgerySystem := preload("res://scripts/surgery/surgery_system.gd")
const DIR := "res://assets/models/characters/human"
const SHOT_DIR := "res://art/human/godot_shots"
const VARIANTS := ["surgeon_a", "surgeon_b", "surgeon_c", "bob", "paramedic_a", "paramedic_b"]
const ClothShader := preload("res://assets/models/characters/human/shaders/human_cloth.gdshader")
const SkinShader := preload("res://assets/models/characters/human/shaders/human_skin.gdshader")

var camera: Camera3D
var flashlight: SpotLight3D
var bulbs: Array = []
var only := ""
var humans: Array = []          # every spawned model, cleared between shots
var extras: Array = []
var level_info := {}
var or_pos := Vector3.ZERO


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--only="):
			only = a.split("=")[1]
	_build_level()
	add_child(Look.make_environment())
	if not args.has("--nopost"):
		add_child(Look.make_post_layer())
	_make_camera()
	if args.has("--report"):
		_report()
		get_tree().quit(0)
		return
	for i in 4:
		await get_tree().physics_frame
	await _run_shots(args.has("--hold"))


# ------------------------------------------------------------------ level
func _build_level() -> void:
	var w := 50
	var h := 11
	var rows := PackedStringArray()
	for y in h:
		var s := ""
		for x in w:
			var c := "#"
			var border := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if not border:
				if x == 40:
					c = "+" if y == 5 else "#"
				elif x > 40:
					c = "."
				elif y >= 1 and y <= 3:
					c = "#" if x % 11 == 0 else "."
				elif y == 4:
					c = "+" if x in [5, 16, 27, 38] else "#"
				elif y == 5 or y == 6:
					c = "."
				elif y == 7:
					c = "+" if x in [10, 32] else "#"
				elif y == 8 or y == 9:
					c = "#" if x == 22 else "."
			s += c
		rows.append(s)
	var lights := [Vector2i(4, 5), Vector2i(14, 6), Vector2i(24, 5), Vector2i(36, 6), Vector2i(45, 4), Vector2i(45, 7)]
	var level: Node3D = HB.build({"rows": rows, "seed": 7, "lights": lights}, level_info)
	add_child(level)
	for l in level_info.get("lights", []):
		bulbs.append(l.node.get_node("Bulb"))
	set_all_lights(false)
	# the OR: an operating table in the end room under a work lamp
	or_pos = C.tile_to_world(45, 5.5)
	Tables._build_table(level, or_pos, 0.0)
	var lamp: SpotLight3D = SurgerySystem.make_work_lamp()
	add_child(lamp)
	lamp.global_position = or_pos + Vector3(0, 2.3, 0)
	lamp.look_at(or_pos + Vector3(0, 0.9, 0.001), Vector3.FORWARD)


func set_light(i: int, on: bool, energy_scale := 1.0) -> void:
	var b: OmniLight3D = bulbs[i]
	b.light_energy = HB.LIGHT_ENERGY * energy_scale if on else 0.0
	b.visible = on
	var panel = b.get_meta("panel") if b.has_meta("panel") else null
	if panel is MeshInstance3D and panel.material_override is StandardMaterial3D:
		(panel.material_override as StandardMaterial3D).emission_energy_multiplier = 2.4 * energy_scale if on else 0.0


func set_all_lights(on: bool) -> void:
	for i in bulbs.size():
		set_light(i, on)


func cor(x: float, lane := 0.0) -> Vector3:
	return Vector3(x, 0.0, 5.5 * C.TILE + lane)


func _make_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 78.0
	camera.near = 0.03
	camera.far = 120.0
	add_child(camera)
	camera.current = true
	flashlight = SpotLight3D.new()
	flashlight.position = Vector3(0.18, -0.16, 0.0)
	flashlight.light_color = Color(1.0, 0.86, 0.62)
	flashlight.light_energy = 4.5
	flashlight.spot_range = C.CONE_RANGE
	flashlight.spot_angle = C.CONE_DEG
	flashlight.spot_angle_attenuation = 0.55
	flashlight.spot_attenuation = 1.1
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.03
	flashlight.shadow_normal_bias = 1.0
	flashlight.light_volumetric_fog_energy = 2.8
	camera.add_child(flashlight)
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.72, 0.80, 0.86)
	glow.light_energy = 0.22
	glow.omni_range = 3.6
	glow.omni_attenuation = 2.0
	glow.light_volumetric_fog_energy = 0.0
	camera.add_child(glow)


func look_from(eye: Vector3, target: Vector3, fov := 70.0, light_on := true) -> void:
	camera.global_position = eye
	camera.look_at(target, Vector3.UP)
	camera.fov = fov
	flashlight.visible = light_on
	flashlight.look_at(target, Vector3.UP)


# ------------------------------------------------------------------ humans
class Human:
	var root: Node3D
	var skel: Skeleton3D
	var anim: AnimationPlayer
	var variant: String
	var cloth: ShaderMaterial
	var skin: ShaderMaterial

	func piece(name: String) -> MeshInstance3D:
		return root.find_child(name, true, false) as MeshInstance3D

	func site(name: String) -> Node3D:
		return root.find_child("Site_" + name, true, false) as Node3D

	func show_piece(name: String, on: bool) -> void:
		var p := piece(name)
		if p != null:
			p.visible = on


func spawn(variant: String, pos: Vector3, face_dir: Vector3, clip := "Idle", t := 0.0) -> Human:
	var scene: PackedScene = load("%s/%s.glb" % [DIR, variant])
	var h := Human.new()
	h.variant = variant
	h.root = scene.instantiate()
	add_child(h.root)
	h.skel = h.root.find_children("*", "Skeleton3D", true, false)[0]
	h.anim = h.root.find_children("*", "AnimationPlayer", true, false)[0]
	for n in h.anim.get_animation_list():
		var a := h.anim.get_animation(n)
		a.loop_mode = Animation.LOOP_NONE if n in ["Interact", "PickUp"] else Animation.LOOP_LINEAR
	_apply_shaders(h)
	h.root.global_position = pos
	h.root.rotation.y = atan2(face_dir.x, face_dir.z)
	# hidden by default: the rolled-up top
	h.show_piece("Human_TopRolled", false)
	for mi in h.root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	pose(h, clip, t)
	humans.append(h)
	return h


func pose(h: Human, clip: String, t: float) -> void:
	h.anim.play(clip)
	h.anim.seek(t, true)
	h.anim.speed_scale = 0.0


func _apply_shaders(h: Human) -> void:
	var cmask: Texture2D = load("%s/textures/%s_Cloth_mask.png" % [DIR, h.variant]) if ResourceLoader.exists("%s/textures/%s_Cloth_mask.png" % [DIR, h.variant]) else null
	var smask: Texture2D = load("%s/textures/%s_Skin_mask.png" % [DIR, h.variant]) if ResourceLoader.exists("%s/textures/%s_Skin_mask.png" % [DIR, h.variant]) else null
	for mi in h.root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i) as StandardMaterial3D
			if src == null:
				continue
			var is_skin := String(src.resource_name).contains("Skin")
			var sm: ShaderMaterial
			if is_skin and h.skin != null:
				sm = h.skin
			elif not is_skin and h.cloth != null:
				sm = h.cloth
			else:
				sm = ShaderMaterial.new()
				sm.shader = SkinShader if is_skin else ClothShader
				sm.set_shader_parameter("albedo_tex", src.albedo_texture)
				sm.set_shader_parameter("normal_tex", src.normal_texture)
				sm.set_shader_parameter("rough_tex", src.roughness_texture)
				sm.set_shader_parameter("mask_tex", smask if is_skin else cmask)
				if is_skin:
					h.skin = sm
				else:
					h.cloth = sm
			m.set_surface_override_material(i, sm)


func tint(h: Human, c: Color) -> void:
	if h.cloth != null:
		h.cloth.set_shader_parameter("tint", c)


func clear_humans() -> void:
	for h in humans:
		(h as Human).root.queue_free()
	humans.clear()
	for e in extras:
		(e as Node).queue_free()
	extras.clear()
	await get_tree().process_frame


func wait(seconds: float) -> void:
	for i in maxi(1, int(ceil(seconds * 60.0))):
		await get_tree().physics_frame


# ------------------------------------------------------------------ shots
func _run_shots(hold: bool) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var list := [
		["lineup_lit", _shot_lineup.bind(true)],
		["lineup_flashlight", _shot_lineup.bind(false)],
		["players_tinted", _shot_tinted],
		["walk_flashlight", _shot_walk],
		["face_bob_flashlight", _shot_face.bind("bob")],
		["face_paramedic_flashlight", _shot_face.bind("paramedic_b")],
		["side_by_side_kenney", _shot_kenney],
		["or_bob_gunshot", _shot_or_gunshot],
		["or_bob_amputation", _shot_or_amputation],
		["or_player_gash", _shot_or_gash],
		["paramedics_push", _shot_push],
		["crawl_downed", _shot_crawl],
		["carry", _shot_carry],
	]
	for s in list:
		if only != "" and not only.split(",").has(s[0]):
			continue
		await clear_humans()
		set_all_lights(false)
		await s[1].call()
		await wait(0.8)
		if hold:
			return
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [SHOT_DIR, s[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[human_viewer] wrote ", path)
	get_tree().quit(0)


func _shot_lineup(lit: bool) -> void:
	# two ranks under the corridor fixture at x 21.75 so it lights them from the front
	var x := 22.4
	for i in VARIANTS.size():
		var rank := i % 2
		var lane := -1.0 + (i / 2) * 1.0 + rank * 0.12
		spawn(VARIANTS[i], cor(x + rank * 1.1, lane - 0.25 + rank * 0.5), Vector3(-1, 0, 0.06 * (1 - rank * 2)).normalized(), "Idle", 0.3 + i * 0.5)
	if lit:
		set_light(1, true, 1.2)
		look_from(cor(x - 4.4, 0.0) + Vector3.UP * 1.5, cor(x + 0.5, 0.0) + Vector3.UP * 1.0, 58.0, false)
	else:
		look_from(cor(x - 4.0, 0.1) + Vector3.UP * C.EYE_H, cor(x + 0.5, 0.0) + Vector3.UP * 1.1, 70.0, true)


func _shot_tinted() -> void:
	var x := 22.6
	var v := ["surgeon_a", "surgeon_b", "surgeon_c", "surgeon_a"]
	for i in 4:
		var h := spawn(v[i], cor(x, -1.1 + i * 0.73), Vector3(-1, 0, -0.15 + i * 0.1).normalized(), "Idle", i * 0.7)
		tint(h, C.PLAYER_COLORS[i])
		if i == 3:
			h.show_piece("Human_Mask", false)
			h.show_piece("Human_Cap", false)
	set_light(1, true, 1.2)
	look_from(cor(x - 3.6, 0.0) + Vector3.UP * 1.5, cor(x, -0.1) + Vector3.UP * 1.1, 60.0, false)


func _shot_walk() -> void:
	var pos := cor(22.0, 0.1)
	spawn("surgeon_c", pos, Vector3(-1, 0, 0.15).normalized(), "Walk", 0.35)
	spawn("paramedic_a", cor(23.8, -0.8), Vector3(-1, 0, 0), "Jog", 0.2)
	set_light(1, true, 0.45)
	look_from(cor(18.6, -0.3) + Vector3.UP * C.EYE_H, pos + Vector3.UP * 1.2, 70.0, true)


func _shot_face(variant: String) -> void:
	var pos := cor(20.0, 0.0)
	var h := spawn(variant, pos, Vector3(-1, 0, 0), "Idle", 1.0)
	await get_tree().process_frame
	var e := h.site("eyes")
	var head := e.global_position if e != null else pos + Vector3.UP * 1.65
	look_from(head + Vector3(-0.85, 0.02, -0.25), head + Vector3(0, -0.05, 0), 45.0, true)


func _shot_kenney() -> void:
	var pos_new := cor(22.6, -0.55)
	var pos_old := cor(22.6, 0.55)
	var h := spawn("surgeon_a", pos_new, Vector3(-1, 0, 0), "Idle", 0.5)
	tint(h, C.PLAYER_COLORS[0])
	var old: Node3D = Assets.spawn("char/surgeon")
	if old != null:
		add_child(old)
		extras.append(old)
		old.global_position = pos_old
		old.rotation.y = atan2(1.0, 0.0)          # Assets models face -Z: yaw so -Z points along -X
		var ap := old.find_children("*", "AnimationPlayer", true, false)
		if not ap.is_empty():
			var p := ap[0] as AnimationPlayer
			for n in p.get_animation_list():
				if String(n).ends_with("idle"):
					p.play(n)
					break
	set_light(1, true, 1.2)
	look_from(cor(18.4, 0.0) + Vector3.UP * 1.4, cor(22.6, 0.0) + Vector3.UP * 1.1, 55.0, false)


func _table_human(variant: String) -> Human:
	# Lying puts the middle of the back at the model origin, head towards model -Z (Blender +Y).
	var top := or_pos + Vector3(0, 0.92, 0)
	var h := spawn(variant, top, Vector3(0, 0, 1), "Lying", 0.0)
	set_light(4, true, 1.2)
	set_light(5, true, 1.2)
	return h


func _shot_or_gunshot() -> void:
	var h := _table_human("bob")
	h.show_piece("Human_GownPanel", false)
	if h.skin:
		h.skin.set_shader_parameter("wound", 1.0)
	await get_tree().process_frame
	var s := h.site("gunshot")
	var c := s.global_position if s != null else or_pos + Vector3.UP
	look_from(c + Vector3(0.55, 0.75, 0.25), c, 50.0, false)


func _shot_or_amputation() -> void:
	var h := _table_human("bob")
	h.show_piece("Human_Forearm_R", false)
	if h.skin:
		h.skin.set_shader_parameter("infect", 1.0)
	await get_tree().process_frame
	# a second Bob, forearm intact and infected, beside it for comparison
	var h2 := spawn("bob", or_pos + Vector3(-1.25, 0.92, 0.0), Vector3(0, 0, 1), "Lying", 0.0)
	if h2.skin:
		h2.skin.set_shader_parameter("infect", 1.0)
	var s := h.site("limb_cut")
	var c := s.global_position if s != null else or_pos + Vector3.UP
	look_from(c + Vector3(0.25, 0.55, 0.45), c, 55.0, false)


func _shot_or_gash() -> void:
	var h := _table_human("surgeon_a")
	h.show_piece("Human_TopLower", false)
	h.show_piece("Human_TopRolled", true)
	h.show_piece("Human_Mask", false)
	var g := h.piece("Human_GashSkin")
	if g != null and g.get_blend_shape_count() > 0:
		g.set_blend_shape_value(0, 1.0)
	if h.skin:
		h.skin.set_shader_parameter("gash", 1.0)
	await get_tree().process_frame
	var s := h.site("gash")
	var c := s.global_position if s != null else or_pos + Vector3.UP
	look_from(c + Vector3(0.45, 0.70, 0.2), c, 50.0, false)


func _shot_push() -> void:
	spawn("paramedic_a", cor(20.0, 0.35), Vector3(-1, 0, 0), "Push", 0.2)
	spawn("paramedic_b", cor(20.0, -0.45), Vector3(-1, 0, 0), "Push", 0.7)
	set_light(1, true, 0.5)
	look_from(cor(16.2, 0.9) + Vector3.UP * C.EYE_H, cor(20.0, 0.0) + Vector3.UP * 1.0, 65.0, true)


func _shot_crawl() -> void:
	var pos := cor(19.0, 0.0)
	spawn("surgeon_b", pos, Vector3(-1, 0, 0.2).normalized(), "Crawl", 0.4)
	look_from(cor(16.0, -0.4) + Vector3.UP * C.EYE_H, pos + Vector3.UP * 0.2, 70.0, true)


func _shot_carry() -> void:
	var pos := cor(22.8, 0.2)
	var carrier := spawn("paramedic_a", pos, Vector3(-1, 0, 0), "Carrying", 0.3)
	var carried := spawn("surgeon_c", pos, Vector3(-1, 0, 0), "Carried", 0.3)
	# the carried body's origin sits on the carrier's right shoulder: Blender (-0.150, 0.030, 1.535) x height/1.78
	var s := 1.83 / 1.78
	carried.root.global_transform = carrier.root.global_transform * Transform3D(Basis(), Vector3(-0.150, 1.535, -0.030) * s)
	set_light(1, true, 1.2)
	look_from(cor(19.8, 1.25) + Vector3.UP * 1.5, pos + Vector3.UP * 1.2, 58.0, false)


# ------------------------------------------------------------------ stats
func _report() -> void:
	for v in VARIANTS:
		var path := "%s/%s.glb" % [DIR, v]
		if not ResourceLoader.exists(path):
			print("[human_viewer] missing ", path)
			continue
		var root: Node3D = (load(path) as PackedScene).instantiate()
		var tris := 0
		var surfaces := 0
		var per := {}
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D).mesh
			var t := 0
			for i in m.get_surface_count():
				var arr := m.surface_get_arrays(i)
				t += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				surfaces += 1
			per[mi.name] = t
			tris += t
		var skel: Skeleton3D = root.find_children("*", "Skeleton3D", true, false)[0]
		var ap: AnimationPlayer = root.find_children("*", "AnimationPlayer", true, false)[0]
		var sites := []
		for n in root.find_children("Site_*", "", true, false):
			sites.append("%s(%s)" % [n.name, n.get_class()])
		print("[human_viewer] %s: %d tris, %d surfaces, %d bones, clips %s" % [v, tris, surfaces, skel.get_bone_count(), ap.get_animation_list()])
		print("[human_viewer]   pieces ", per)
		print("[human_viewer]   sites ", sites)
		root.free()
