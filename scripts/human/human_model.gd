extends RefCounted
## The Blender-built humans (art/human/README.md): spawning a variation, its two shader materials
## (scrub tint through the cloth mask; skin with pallor / infection / gash / wound), the piece
## switches and the per-player variation. Every caller keeps its Kenney or primitive path as the
## fallback when `available()` is false.
##
## Model space after Assets.spawn (registry yaw 180): Y up, feet at y 0, facing -Z, the body's right
## on +X. Pieces (MeshInstance3D under the one Skeleton3D): Human, Human_Cap, Human_Mask,
## Human_TopLower, Human_TopRolled (hidden by default), Human_GashSkin (blend shape GashOpen),
## Human_GownPanel, Human_Forearm_R. Sites: Site_<name> nodes under BoneAttachment3D.

const DIR := "res://assets/models/characters/human"
const CLOTH_SHADER := "res://assets/models/characters/human/shaders/human_cloth.gdshader"
const SKIN_SHADER := "res://assets/models/characters/human/shaders/human_skin.gdshader"
const SURGEONS := ["surgeon_a", "surgeon_b", "surgeon_c"]
const KEYS := {
	"surgeon_a": "char/human_surgeon_a", "surgeon_b": "char/human_surgeon_b", "surgeon_c": "char/human_surgeon_c",
	"bob": "patient/human_bob", "paramedic_a": "crew/human_paramedic_a", "paramedic_b": "crew/human_paramedic_b",
}
## The colour the scrubs are baked in (C.PLAYER_COLORS[0]).
const BAKED_TINT := Color("3d8f80")
## Height of each variation (metres), for fits that scale with the body (sites JSON `height`).
const HEIGHTS := {"surgeon_a": 1.80, "surgeon_b": 1.68, "surgeon_c": 1.75, "bob": 1.75, "paramedic_a": 1.83, "paramedic_b": 1.70}

## Tools and perf A/B: force every caller onto its old Kenney / primitive path.
static var disabled := false
static var _shaders := {}
static var _tex := {}
static var _skin_shared := {}


static func _assets() -> Node:
	var loop := Engine.get_main_loop()
	return (loop as SceneTree).root.get_node_or_null("/root/Assets") if loop is SceneTree else null


static func available(variant: String) -> bool:
	if disabled or not KEYS.has(variant):
		return false
	var a := _assets()
	return a != null and a.has(KEYS[variant]) and ResourceLoader.exists(CLOTH_SHADER) and ResourceLoader.exists(SKIN_SHADER)


## The surgeon variation a player wears: deterministic by peer id, like the colour.
static func surgeon_for(peer_id: int) -> String:
	return SURGEONS[posmod(peer_id - 1, SURGEONS.size())]


static func _shader(path: String) -> Shader:
	if not _shaders.has(path):
		_shaders[path] = load(path)
	return _shaders[path]


static func _mask(variant: String, which: String) -> Texture2D:
	var p := "%s/textures/%s_%s_mask.png" % [DIR, variant, which]
	if not _tex.has(p):
		_tex[p] = load(p) if ResourceLoader.exists(p) else null
	return _tex[p]


## An instance of the variation (Assets root, facing -Z), dressed with the shader materials.
## own_skin: a skin material only this instance uses (patients: pallor, infection). Returns null
## when the asset is missing.
static func spawn(variant: String, tint := BAKED_TINT, own_skin := false) -> Node3D:
	if not available(variant):
		return null
	var root: Node3D = _assets().spawn(KEYS[variant])
	if root == null:
		return null
	var cloth := ShaderMaterial.new()
	cloth.shader = _shader(CLOTH_SHADER)
	cloth.set_shader_parameter(&"mask_tex", _mask(variant, "Cloth"))
	cloth.set_shader_parameter(&"baked_tint", BAKED_TINT)
	cloth.set_shader_parameter(&"tint", tint)
	var skin: ShaderMaterial = null if own_skin else _skin_shared.get(variant)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			var is_skin := String(src.resource_name).contains("Skin")
			if is_skin:
				if skin == null:
					skin = ShaderMaterial.new()
					skin.shader = _shader(SKIN_SHADER)
					_textures(skin, src)
					skin.set_shader_parameter(&"mask_tex", _mask(variant, "Skin"))
					if not own_skin:
						_skin_shared[variant] = skin
				m.set_surface_override_material(i, skin)
			else:
				if cloth.get_shader_parameter(&"albedo_tex") == null:
					_textures(cloth, src)
				m.set_surface_override_material(i, cloth)
	root.set_meta("human_variant", variant)
	root.set_meta("human_cloth", cloth)
	root.set_meta("human_skin", skin)
	show_piece(root, "Human_TopRolled", false)
	return root


static func _textures(sm: ShaderMaterial, src: BaseMaterial3D) -> void:
	sm.set_shader_parameter(&"albedo_tex", src.albedo_texture)
	sm.set_shader_parameter(&"normal_tex", src.normal_texture)
	sm.set_shader_parameter(&"rough_tex", src.roughness_texture)


static func cloth_of(root: Node) -> ShaderMaterial:
	return root.get_meta("human_cloth", null) if root != null else null


static func skin_of(root: Node) -> ShaderMaterial:
	return root.get_meta("human_skin", null) if root != null else null


static func set_tint(root: Node, c: Color) -> void:
	var m := cloth_of(root)
	if m != null:
		m.set_shader_parameter(&"tint", c)


static func piece(root: Node, name: String) -> MeshInstance3D:
	return root.find_child(name, true, false) as MeshInstance3D if root != null else null


static func show_piece(root: Node, name: String, on: bool) -> void:
	var p := piece(root, name)
	if p != null:
		p.visible = on


static func skeleton(root: Node) -> Skeleton3D:
	var s := root.find_children("*", "Skeleton3D", true, false)
	return s[0] if not s.is_empty() else null


static func anim_player(root: Node) -> AnimationPlayer:
	var s := root.find_children("*", "AnimationPlayer", true, false)
	return s[0] if not s.is_empty() else null


## Loop every clip except the one-shots, on a copy of the library shared per variation.
static var _libs := {}


static func loop_clips(root: Node) -> void:
	var ap := anim_player(root)
	if ap == null:
		return
	var libs := ap.get_animation_library_list()
	if libs.is_empty():
		return
	var lib_name: StringName = libs[0]
	var key := String(root.get_meta("human_variant", "")) + "|" + String(lib_name)
	if not _libs.has(key):
		var lib: AnimationLibrary = ap.get_animation_library(lib_name).duplicate(false)
		for n in lib.get_animation_list():
			var a: Animation = lib.get_animation(n).duplicate(false)
			a.loop_mode = Animation.LOOP_NONE if String(n) in ["Interact", "PickUp"] else Animation.LOOP_LINEAR
			lib.remove_animation(n)
			lib.add_animation(n, a)
		_libs[key] = lib
	ap.remove_animation_library(lib_name)
	ap.add_animation_library(lib_name, _libs[key])


## Bone-by-bone sample of one clip onto a skeleton at time t (rotations and positions), for bodies
## that are posed by hand rather than by an AnimationPlayer (the patients). Returns false if missing.
static func sample_clip(skel: Skeleton3D, anim: Animation, t: float) -> void:
	for i in anim.get_track_count():
		var bone := skel.find_bone(String(anim.track_get_path(i).get_concatenated_subnames()))
		if bone < 0:
			continue
		match anim.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				skel.set_bone_pose_rotation(bone, anim.rotation_track_interpolate(i, t))
			Animation.TYPE_POSITION_3D:
				skel.set_bone_pose_position(bone, anim.position_track_interpolate(i, t))


## The skeleton-space transform of a bone from the current local poses (works outside the tree).
static func bone_global(skel: Skeleton3D, bone: int) -> Transform3D:
	var xf := Transform3D()
	var i := bone
	while i >= 0:
		xf = Transform3D(Basis(skel.get_bone_pose_rotation(i)).scaled(skel.get_bone_pose_scale(i)), skel.get_bone_pose_position(i)) * xf
		i = skel.get_bone_parent(i)
	return xf


## Transform from `node`'s space up to (not including) `ancestor`, from local transforms.
static func chain_to(node: Node, ancestor: Node) -> Transform3D:
	var xf := Transform3D()
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Turn bone `bone` by `q` in skeleton space on top of its current local pose.
static func turn_bone(skel: Skeleton3D, bone: int, q: Quaternion) -> void:
	if bone < 0:
		return
	var parent := skel.get_bone_parent(bone)
	var pb := bone_global(skel, parent).basis.get_rotation_quaternion() if parent >= 0 else Quaternion.IDENTITY
	var local := skel.get_bone_pose_rotation(bone)
	skel.set_bone_pose_rotation(bone, (pb.inverse() * q * pb * local).normalized())
