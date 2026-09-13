extends SubViewport
## A tiny photo studio for an item page: the item model on a dark cloth under a warm lamp,
## slowly turning. Its own World3D, so none of it leaks into the game and the game's fog and
## grade do not reach it.

const ItemModelsDB := preload("res://scripts/item_models.gd")

const TURN_SPEED := 0.42

var pivot: Node3D
var _t := 0.0


func setup(kind: String, count: int, px_size := Vector2i(960, 800)) -> void:
	size = px_size
	own_world_3d = true
	transparent_bg = false
	msaa_3d = Viewport.MSAA_4X
	render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.075, 0.062, 0.052)
	# A sky only for lighting and reflections, so steel reads as steel; the background stays dark.
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.5, 0.45, 0.4)
	sky_mat.sky_horizon_color = Color(0.75, 0.68, 0.58)
	sky_mat.ground_bottom_color = Color(0.12, 0.1, 0.09)
	sky_mat.ground_horizon_color = Color(0.4, 0.35, 0.3)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.ssao_enabled = true
	env.ssao_radius = 0.08
	env.ssao_intensity = 1.2
	we.environment = env
	add_child(we)

	var model: Node3D = ItemModelsDB.make(kind, count)
	var box := merged_aabb(model)
	if box.size.length() < 0.001:
		box = AABB(Vector3(-0.1, 0, -0.1), Vector3(0.2, 0.1, 0.2))
	var centre := box.get_center()
	pivot = Node3D.new()
	add_child(pivot)
	model.position = Vector3(-centre.x, -box.position.y, -centre.z)
	pivot.add_child(model)
	pivot.rotation.y = 0.6

	var radius := maxf(0.06, Vector3(box.size.x, box.size.y, box.size.z).length() * 0.5)

	# Cloth the item rests on.
	var cloth := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2.ONE * radius * 14.0
	cloth.mesh = pm
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.13, 0.12, 0.115)
	cm.roughness = 1.0
	cloth.material_override = cm
	add_child(cloth)

	var lamp := SpotLight3D.new()
	lamp.light_color = Color(1.0, 0.85, 0.62)
	lamp.light_energy = 3.4
	lamp.spot_range = radius * 20.0
	lamp.spot_angle = 34.0
	lamp.spot_angle_attenuation = 1.6
	lamp.shadow_enabled = true
	lamp.shadow_blur = 2.5
	add_child(lamp)
	lamp.position = Vector3(-radius * 2.2, radius * 5.5, radius * 2.4)
	lamp.look_at_from_position(lamp.position, Vector3(0, box.size.y * 0.3, 0), Vector3.UP)

	var fill := OmniLight3D.new()
	fill.light_color = Color(0.6, 0.75, 0.9)
	fill.light_energy = 0.5
	fill.omni_range = radius * 12.0
	fill.position = Vector3(radius * 3.0, radius * 1.5, radius * 2.0)
	add_child(fill)

	var cam := Camera3D.new()
	cam.fov = 30.0
	cam.near = 0.01
	cam.far = 50.0
	add_child(cam)
	var aspect := float(px_size.x) / float(px_size.y)
	var half_fov := deg_to_rad(cam.fov * 0.5)
	var dist := radius / sin(half_fov) * (0.86 if aspect >= 1.0 else 1.1)
	var look := Vector3(0, box.size.y * 0.35, 0)
	var dir := Vector3(0, 0.62, 1.0).normalized()
	cam.look_at_from_position(look + dir * dist, look, Vector3.UP)
	cam.current = true


func _process(delta: float) -> void:
	_t += delta
	if pivot != null:
		pivot.rotation.y += TURN_SPEED * delta


## Local-space bounds of every visual under `root`, walking transforms without the tree.
static func merged_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is VisualInstance3D:
			var b: AABB = xf * (n as VisualInstance3D).get_aabb()
			if first:
				out = b
				first = false
			else:
				out = out.merge(b)
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
	return out
