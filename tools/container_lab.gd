extends Node3D
## Container look-dev and screenshot rig.
##
##   godot --path . tools/container_lab.tscn                 # shots into tools/container_shots/, then quit
##   godot --path . tools/container_lab.tscn -- --stay       # keep the window open afterwards
##
## A small lit room with one of each container against the back wall, each filled with
## item stacks from ItemModels. Takes a closed and an open shot of each from eye height,
## then two shots under the game's real grading (Look.make_environment + post layer, one
## dim ceiling fixture and a flashlight).

const OUT_DIR := "res://tools/container_shots"
const FridgeScript := preload("res://scripts/containers/med_fridge.gd")
const DrawerUnitScript := preload("res://scripts/containers/drawer_unit.gd")
const StationScript := preload("res://scripts/containers/station_drawers.gd")
const TraumaBagScript := preload("res://scripts/containers/trauma_bag.gd")
const PegboardScript := preload("res://scripts/containers/pegboard.gd")
const LookScript := preload("res://scripts/look.gd")
const Models := preload("res://scripts/item_models.gd")

const ROOM_W := 11.0
const ROOM_D := 6.0

var camera: Camera3D
var flashlight: SpotLight3D
var lab_lights: Array[Light3D] = []
var lab_env: WorldEnvironment
var units := {}        # name -> {x, containers: Array}
var stay := false


func _ready() -> void:
	stay = OS.get_cmdline_user_args().has("--stay")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build_room()
	_build_containers()
	camera = Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	camera.current = true
	flashlight = SpotLight3D.new()
	flashlight.spot_range = 14.0
	flashlight.spot_angle = 26.0
	flashlight.light_energy = 2.2
	flashlight.shadow_enabled = true
	flashlight.visible = false
	flashlight.position = Vector3(0.25, -0.2, 0.0)
	camera.add_child(flashlight)
	_run()


func _build_room() -> void:
	var floor_m := _mat(Color(0.3, 0.32, 0.33), 0.9)
	var wall_m := _mat(Color(0.52, 0.55, 0.53), 0.85)
	_slab(Vector3(ROOM_W, 0.2, ROOM_D), Vector3(0, -0.1, ROOM_D * 0.5 - 0.5), floor_m)
	_slab(Vector3(ROOM_W, 0.2, ROOM_D), Vector3(0, 3.1, ROOM_D * 0.5 - 0.5), _mat(Color(0.2, 0.21, 0.22), 0.95))
	_slab(Vector3(ROOM_W, 3.0, 0.2), Vector3(0, 1.5, -0.1), wall_m)
	_slab(Vector3(ROOM_W, 3.0, 0.2), Vector3(0, 1.5, ROOM_D - 0.4), wall_m)
	_slab(Vector3(0.2, 3.0, ROOM_D), Vector3(-ROOM_W * 0.5, 1.5, ROOM_D * 0.5 - 0.5), wall_m)
	_slab(Vector3(0.2, 3.0, ROOM_D), Vector3(ROOM_W * 0.5, 1.5, ROOM_D * 0.5 - 0.5), wall_m)
	lab_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.02)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.55)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	lab_env.environment = env
	add_child(lab_env)
	for x in [-3.5, 0.0, 3.5]:
		var l := OmniLight3D.new()
		l.position = Vector3(x, 2.7, 2.0)
		l.omni_range = 7.0
		l.light_energy = 1.6
		l.shadow_enabled = true
		add_child(l)
		lab_lights.append(l)


func _build_containers() -> void:
	var yaw := PI   # fronts face +Z, backs against the wall at z = 0
	var specs := [
		["drawer_unit", -4.0], ["med_fridge", -2.0], ["station_drawers", 0.1], ["trauma_bag", 2.2], ["pegboard", 4.1],
	]
	for s in specs:
		var type: String = s[0]
		var x: float = s[1]
		var node: Node3D
		var list: Array = []
		var tile := Vector2i(int(x * 10.0) + 100, 5)
		match type:
			"med_fridge":
				node = FridgeScript.create("ct_%d_%d_0" % [tile.x, tile.y])
				list = [node]
			"drawer_unit":
				node = DrawerUnitScript.create_unit(tile)
				list = node.get_meta("drawers")
			"station_drawers":
				node = StationScript.create_unit(tile)
				list = node.get_meta("drawers")
			"trauma_bag":
				node = TraumaBagScript.create("ct_%d_%d_0" % [tile.x, tile.y])
				list = [node]
			"pegboard":
				node = PegboardScript.create("ct_%d_%d_0" % [tile.x, tile.y])
				list = [node]
		node.position = Vector3(x, 0, 0)
		node.rotation.y = yaw
		add_child(node)
		units[type] = {"x": x, "containers": list, "root": node}
		_fill(type, list)
		for a in node.get_meta("anchors", []):
			var m := Models.make("gauze" if type == "station_drawers" else "forceps", 3)
			m.transform = a.xform
			node.add_child(m)


func _fill(type: String, list: Array) -> void:
	var fills := {
		"med_fridge": [["anesthetic", 3], ["anesthetic", 2], [], ["anesthetic", 3], ["gauze", 2], ["anesthetic", 2]],
		"drawer_unit": [["forceps", 1], ["gauze", 3], ["gauze", 4], ["forceps", 1], ["forceps", 1], []],
		"station_drawers": [["gauze", 4], ["anesthetic", 2], ["gauze", 2], ["forceps", 1]],
		"trauma_bag": [["tourniquet", 1], ["tourniquet", 1]],
		"pegboard": [["bone_saw", 1], ["bone_saw", 1], ["bone_saw", 1], []],
	}
	var plan: Array = fills[type]
	var k := 0
	for c in list:
		for i in c.slot_count():
			if k < plan.size() and not (plan[k] as Array).is_empty():
				var m := Models.make(plan[k][0], plan[k][1])
				c.slot_node(i).add_child(m)
			k += 1


func _run() -> void:
	await _frames(20)
	await _shot_row("00_overview_closed", Vector3(0, 2.3, 5.2), Vector3(0, 0.9, 0))
	for type in units.keys():
		var x: float = units[type].x
		await _shot_container(type, x, false)
	for type in units.keys():
		var list: Array = units[type].containers
		for i in list.size():
			# Only the middle drawer of the cabinet: open drawers stack and hide each other.
			if type != "drawer_unit" or i == 1:
				list[i].set_open(true, true)
	await get_tree().create_timer(1.3).timeout
	for type in units.keys():
		var x: float = units[type].x
		await _shot_container(type, x, true)
	await _shot_row("01_overview_open", Vector3(0, 2.3, 5.2), Vector3(0, 0.9, 0))

	# The game's grading: its environment, post layer, one fixture, flashlight on.
	lab_env.queue_free()
	for l in lab_lights:
		l.visible = false
	add_child(LookScript.make_environment())
	add_child(LookScript.make_post_layer())
	var fixture := OmniLight3D.new()
	fixture.position = Vector3(-1.0, 2.65, 1.6)
	fixture.omni_range = 5.2
	fixture.light_energy = 1.15
	fixture.light_color = Color(1.0, 0.96, 0.9)
	fixture.light_volumetric_fog_energy = 2.0
	add_child(fixture)
	flashlight.visible = true
	await _frames(30)
	await _shot_row("game_01_pharmacy_corner", Vector3(-2.6, 1.7, 2.1), Vector3(-2.4, 0.9, 0.0))
	await _shot_row("game_02_station_and_bag", Vector3(1.4, 1.7, 2.2), Vector3(1.2, 0.95, 0.0))
	print("[container_lab] done")
	if not stay:
		get_tree().quit(0)


func _shot_container(type: String, x: float, open: bool) -> void:
	var target_y: float = {"med_fridge": 1.0, "drawer_unit": 0.55, "station_drawers": 0.8, "trauma_bag": 1.1, "pegboard": 1.4}[type]
	var dist: float = {"med_fridge": 1.9, "drawer_unit": 1.6, "station_drawers": 1.7, "trauma_bag": 1.5, "pegboard": 1.8}[type]
	await _shot_row("%s_%s" % [type, "open" if open else "closed"], Vector3(x + 0.35, 1.7, dist), Vector3(x, target_y, 0.0))


func _shot_row(nm: String, from: Vector3, at: Vector3) -> void:
	camera.global_position = from
	camera.look_at(at, Vector3.UP)
	await _frames(12)
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, nm]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[container_lab] wrote ", path)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _slab(size: Vector3, pos: Vector3, m: Material) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.material_override = m
	add_child(mi)


func _mat(c: Color, r: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = r
	return m
