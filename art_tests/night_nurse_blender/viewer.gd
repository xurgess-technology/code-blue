extends Node3D
## Look-dev viewer for the Blender-built Night Nurse (art test only, not wired into the game).
## Builds the monster-lab corridor with the game's environment and post layer, stands the
## GLB in it next to the current primitive Night Nurse, and saves windowed screenshots.
##
##   godot --path . --resolution 1280x720 art_tests/night_nurse_blender/viewer.tscn
##   options (after --): --only=a,b  --nopost  --hold (stay open, no screenshots)

const HB := preload("res://scripts/hospital_builder.gd")
const MonsterScript := preload("res://scripts/monster.gd")
const Modes := preload("res://scripts/monsters/modes.gd")
const GLB := "res://art_tests/night_nurse_blender/night_nurse.glb"
const SHOT_DIR := "res://art_tests/night_nurse_blender/godot_shots"

## The smallest stand-in for the game node a client-side Monster looks for.
class StubGame extends Node3D:
	var players: Dictionary = {}
	var level_info: Dictionary = {}
	var world_time := 0.0
	var noises: Array = []

	func _ready() -> void:
		add_to_group("game")

	func _physics_process(delta: float) -> void:
		world_time += delta

	func is_host() -> bool:
		return false

	func alive_players() -> Array:
		return []

	func viewed_player() -> Node:
		return null

	func emit_noise(_pos: Vector3, _loudness: float, _kind: String) -> void:
		pass

	func recent_noises(_max_age: float = 1.5) -> Array:
		return []

	func say(_text: String, _seconds: float = 3.0) -> void:
		pass


var game: StubGame
var camera: Camera3D
var flashlight: SpotLight3D
var bulbs: Array = []
var nurse: Node3D          # the GLB instance
var nurse_anim: AnimationPlayer
var old_nurse: Node = null
var only := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.split("=")[1]
	game = StubGame.new()
	add_child(game)
	_build_level()
	add_child(Look.make_environment())
	if not OS.get_cmdline_user_args().has("--nopost"):
		add_child(Look.make_post_layer())
	_make_camera()
	var scene: PackedScene = load(GLB)
	nurse = scene.instantiate()
	add_child(nurse)
	nurse_anim = nurse.find_children("*", "AnimationPlayer", true, false)[0]
	for n in nurse_anim.get_animation_list():
		nurse_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	print("[viewer] animations: ", nurse_anim.get_animation_list())
	var tris := 0
	for mi in nurse.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	print("[viewer] GLB triangles: ", tris)
	for i in 4:
		await get_tree().physics_frame
	if OS.get_cmdline_user_args().has("--hold"):
		await _pose_corridor()
		return
	await _run_shots()


func _build_level() -> void:
	# The monster lab's corridor: rooms along both sides, a doorway at the far east end.
	var w := 50
	var h := 11
	var rows := PackedStringArray()
	for y in h:
		var s := ""
		for x in w:
			var c := "#"
			var border := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if not border:
				if x == 43:
					c = "+" if y == 5 else "#"
				elif x > 43:
					c = "." if y >= 3 and y <= 8 else "#"
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
	var lights := [Vector2i(4, 5), Vector2i(14, 6), Vector2i(24, 5), Vector2i(36, 6), Vector2i(46, 5)]
	var info := {}
	var level: Node3D = HB.build({"rows": rows, "seed": 7, "lights": lights}, info)
	add_child(level)
	game.level_info = info
	for l in info.get("lights", []):
		bulbs.append(l.node.get_node("Bulb"))
	set_all_lights(false)


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
	return Vector3(x, 0.0, 6.0 * C.TILE + lane)


## A camera and flashlight with the player's numbers.
func _make_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 78.0
	camera.near = 0.05
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
	glow.shadow_enabled = false
	camera.add_child(glow)


func look_from(eye: Vector3, target: Vector3, fov := 78.0, light_on := true) -> void:
	camera.global_position = eye
	camera.look_at(target, Vector3.UP)
	camera.fov = fov
	flashlight.visible = light_on
	# aim the torch at the target, not along the camera's parallax offset
	flashlight.look_at(target, Vector3.UP)


## GLB faces +Z. yaw is the world direction it should face (radians about Y).
func place_nurse(pos: Vector3, face_dir: Vector3, clip: String, t := 0.0, extra_yaw := 0.0) -> void:
	nurse.visible = true
	nurse.global_position = pos
	nurse.rotation = Vector3(0, atan2(face_dir.x, face_dir.z) + extra_yaw, 0)
	nurse_anim.play(clip)
	nurse_anim.seek(t, true)
	nurse_anim.speed_scale = 0.0


func spawn_old_nurse(pos: Vector3, face_dir: Vector3) -> void:
	if old_nurse != null:
		old_nurse.queue_free()
		await get_tree().physics_frame
	old_nurse = MonsterScript.new_monster(4242, "night_nurse", pos)
	game.add_child(old_nurse)
	# the primitive nurse's model faces -Z
	var yaw := atan2(-face_dir.x, -face_dir.z)
	old_nurse.rotation.y = yaw
	for i in 30:
		old_nurse.apply_remote({"pos": pos, "y": yaw, "st": 0, "md": Modes.Mode.WANDER, "mv": false, "sp": 0.0, "ob": true, "ly": 0.0, "lg": false, "cm": false})
		await get_tree().physics_frame


func clear_old_nurse() -> void:
	if old_nurse != null:
		old_nurse.queue_free()
		old_nurse = null
		await get_tree().physics_frame


func wait(seconds: float) -> void:
	for i in maxi(1, int(ceil(seconds * 60.0))):
		await get_tree().physics_frame


func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var list := [
		["corridor_4m", _shot_corridor.bind(4.0, "Frozen", 0.0)],
		["corridor_2m_look_up", _shot_close],
		["face_1m", _shot_face],
		["doorway_20m", _shot_door],
		["idle_twitch", _shot_corridor.bind(3.0, "Idle", 1.35)],
		["walk_midstride", _shot_walk],
		["side_by_side", _shot_side_by_side.bind(false)],
		["side_by_side_profile", _shot_side_by_side.bind(true)],
		["lit_turnaround", _shot_lit],
	]
	for s in list:
		if only != "" and not only.split(",").has(s[0]):
			continue
		await clear_old_nurse()
		set_all_lights(false)
		await s[1].call()
		await wait(1.0)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [SHOT_DIR, s[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[viewer] wrote ", path)
	get_tree().quit(0)


func _shot_corridor(dist: float, clip: String, t: float) -> void:
	var pos := cor(20.0, 0.25)
	place_nurse(pos, Vector3(-1, 0, 0), clip, t, 0.2)
	set_light(1, true, 0.5)
	look_from(cor(20.0 - dist, -0.2) + Vector3.UP * C.EYE_H, pos + Vector3.UP * 1.45)


func _shot_close() -> void:
	var pos := cor(20.0, 0.1)
	place_nurse(pos, Vector3(-1, 0, 0), "Frozen", 0.0, 0.25)
	look_from(cor(18.2, -0.25) + Vector3.UP * C.EYE_H, pos + Vector3.UP * 1.95)


func _shot_face() -> void:
	# Right up against it, torch in its face: the worst place to be.
	var pos := cor(20.0, 0.0)
	place_nurse(pos, Vector3(-1, 0, 0), "Frozen", 0.0, 0.1)
	await get_tree().process_frame
	var skel := nurse.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var head_i := skel.find_bone("head")
	var head_pos := skel.global_transform * skel.get_bone_global_pose(head_i).origin + Vector3.UP * 0.12
	look_from(head_pos + Vector3(-0.95, -0.12, -0.12), head_pos, 50.0)


func _shot_door() -> void:
	var door := C.tile_to_world(43, 5)
	place_nurse(door, Vector3(-1, 0, 0), "Frozen", 0.0, -0.2)
	set_light(4, true, 0.6)
	look_from(cor(door.x - 10.0, 0.3) + Vector3.UP * C.EYE_H, door + Vector3.UP * 1.3)


func _shot_walk() -> void:
	var pos := cor(20.0, 0.0)
	place_nurse(pos, Vector3(-0.3, 0, 1).normalized(), "Walk", 0.4, 0.0)
	set_light(1, true, 0.7)
	look_from(cor(16.8, -1.0) + Vector3.UP * C.EYE_H, pos + Vector3.UP * 1.2)


func _shot_side_by_side(profile: bool) -> void:
	var pos_new := cor(20.0, -0.55)
	var pos_old := cor(20.0, 0.6)
	set_light(1, true, 0.9)
	set_light(2, true, 0.6)
	if profile:
		place_nurse(pos_new, Vector3(0, 0, 1), "Frozen", 0.0)
		await spawn_old_nurse(pos_old, Vector3(0, 0, 1))
		look_from(cor(16.4, 0.0) + Vector3.UP * 1.35, cor(20.0, 0.0) + Vector3.UP * 1.2, 60.0)
	else:
		place_nurse(pos_new, Vector3(-1, 0, 0), "Frozen", 0.0)
		await spawn_old_nurse(pos_old, Vector3(-1, 0, 0))
		look_from(cor(15.8, 0.0) + Vector3.UP * 1.35, cor(20.0, 0.0) + Vector3.UP * 1.2, 60.0)


func _shot_lit() -> void:
	# Corridor lights on, three-quarter view: the textures without the flashlight's help.
	var pos := cor(22.6, 0.1)
	place_nurse(pos, Vector3(-1, 0, -0.8).normalized(), "Frozen", 0.0)
	set_light(1, true, 1.0)
	look_from(cor(19.4, 0.7) + Vector3.UP * 1.5, pos + Vector3.UP * 1.25, 60.0, false)


func _pose_corridor() -> void:
	await _shot_corridor(4.0, "Idle", 0.0)
	nurse_anim.speed_scale = 1.0
