extends RefCounted
## Visuals for the dev room: the dev gun, its tracers and impacts, fallen monsters, and the
## target dummy's body. All primitives with shared materials, so nothing compiles mid-fight
## after the warmup has drawn them once (see warm()).

const MonsterModel := preload("res://scripts/monsters/monster_model.gd")

const KILL_COLOR := Color(1.0, 0.32, 0.18)
const KNOCK_COLOR := Color(0.3, 0.85, 1.0)
const TRACER_TIME := 0.16
const CORPSE_TIME := 6.0

static var _mats := {}


static func mat(key: String) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	match key:
		"body":
			m.albedo_color = Color(0.16, 0.17, 0.2)
			m.metallic = 0.6
			m.roughness = 0.35
		"trim":
			m.albedo_color = Color(0.85, 0.87, 0.9)
			m.metallic = 0.9
			m.roughness = 0.25
		"grip":
			m.albedo_color = Color(0.09, 0.09, 0.1)
			m.roughness = 0.9
		"coil":
			m.albedo_color = Color(0.1, 0.1, 0.1)
			m.emission_enabled = true
			m.emission = Color(0.35, 1.0, 0.85)
			m.emission_energy_multiplier = 3.0
		"kill", "knock":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.albedo_color = (KILL_COLOR if key == "kill" else KNOCK_COLOR) * 1.6
		"dummy":
			m.albedo_color = Color(0.93, 0.72, 0.18)
			m.roughness = 0.7
		"dummy_dark":
			m.albedo_color = Color(0.12, 0.12, 0.13)
			m.roughness = 0.8
		"target":
			m.albedo_color = Color(0.85, 0.1, 0.08)
			m.roughness = 0.6
			m.emission_enabled = true
			m.emission = Color(0.6, 0.05, 0.02)
			m.emission_energy_multiplier = 0.4
	_mats[key] = m
	return m


static func _box(size: Vector3, pos: Vector3, key: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat(key)
	return mi


static func _cyl(r: float, h: float, pos: Vector3, rot: Vector3, key: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 12
	mi.mesh = cm
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat(key)
	return mi


## The dev gun: a chunky sci-fi pistol pointing down -Z, origin at the grip.
static func make_gun() -> Node3D:
	var g := Node3D.new()
	g.name = "DevGun"
	g.add_child(_box(Vector3(0.05, 0.075, 0.2), Vector3(0, 0.05, -0.08), "body"))
	g.add_child(_box(Vector3(0.04, 0.11, 0.05), Vector3(0, -0.02, 0.0), "grip"))
	g.get_child(1).rotation.x = 0.25
	g.add_child(_cyl(0.018, 0.16, Vector3(0, 0.06, -0.24), Vector3(PI / 2.0, 0, 0), "trim"))
	g.add_child(_cyl(0.03, 0.02, Vector3(0, 0.06, -0.31), Vector3(PI / 2.0, 0, 0), "body"))
	for i in 3:
		g.add_child(_cyl(0.028, 0.012, Vector3(0, 0.06, -0.17 - i * 0.035), Vector3(PI / 2.0, 0, 0), "coil"))
	g.add_child(_box(Vector3(0.012, 0.02, 0.07), Vector3(0, 0.1, -0.06), "coil"))
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0.06, -0.33)
	g.add_child(muzzle)
	return g


## A beam from `from` to `to` that fades out, plus a flash where it landed.
static func tracer(parent: Node, from: Vector3, to: Vector3, mode: String, hit: bool) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var col := KILL_COLOR if mode == "kill" else KNOCK_COLOR
	var len := from.distance_to(to)
	if len < 0.05:
		return
	var beam := MeshInstance3D.new()
	beam.name = "DevTracer"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.025, 0.025, len)
	beam.mesh = bm
	beam.material_override = mat("kill" if mode == "kill" else "knock")
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(beam)
	var mid := (from + to) * 0.5
	var up := Vector3.UP if absf((to - from).normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	beam.global_transform = Transform3D(Basis.looking_at(to - from, up), mid)
	# A thinner, brighter core inside the glow (additive, so the overlap reads as hotter).
	var core := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.008, 0.008, len)
	core.mesh = cm
	core.material_override = beam.material_override
	beam.add_child(core)
	var flash := OmniLight3D.new()
	flash.light_color = col
	flash.light_energy = 3.0 if hit else 1.5
	flash.omni_range = 2.5
	flash.shadow_enabled = false
	parent.add_child(flash)
	flash.global_position = to - (to - from).normalized() * 0.1
	var spark := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.07 if hit else 0.04
	sp.height = sp.radius * 2.0
	spark.mesh = sp
	spark.material_override = beam.material_override
	parent.add_child(spark)
	spark.global_position = to
	var tw := parent.create_tween()
	tw.set_parallel(true)
	tw.tween_property(beam, "transparency", 1.0, TRACER_TIME)
	tw.tween_property(core, "transparency", 1.0, TRACER_TIME)
	tw.tween_property(flash, "light_energy", 0.0, TRACER_TIME * 1.5)
	tw.tween_property(spark, "scale", Vector3.ONE * 2.5, TRACER_TIME)
	tw.tween_property(spark, "transparency", 1.0, TRACER_TIME)
	tw.chain().tween_callback(func():
		for n in [beam, flash, spark]:
			if is_instance_valid(n):
				n.queue_free())


## A monster that was just killed: its model falls over backwards where it stood, lies there,
## then sinks away.
static func monster_corpse(parent: Node, kind: String, pos: Vector3, yaw: float) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var root := Node3D.new()
	root.name = "DevCorpse"
	parent.add_child(root)
	root.global_position = pos
	root.rotation.y = yaw
	var model: Node3D = MonsterModel.new()
	root.add_child(model)
	model.setup(kind)
	if model.has_method("play"):
		model.play("idle", 0.0, 0.0)
	var tw := root.create_tween()
	tw.tween_property(model, "rotation:x", PI / 2.0 * 0.96, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(model, "position:y", 0.25, 0.45)
	tw.tween_interval(CORPSE_TIME)
	tw.tween_property(root, "position:y", pos.y - 1.2, 1.5)
	tw.tween_callback(root.queue_free)


## Replace a Player's body with a crash-test target dummy.
static func dress_dummy(body_visual: Node3D) -> void:
	# Only the surgeon's look goes; the held-item and gun mounts stay.
	for c in body_visual.get_children():
		if not String(c.name).begins_with("Held") and not String(c.name).begins_with("DevGun"):
			c.queue_free()
	var torso := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.27
	cap.height = 1.05
	torso.mesh = cap
	torso.material_override = mat("dummy")
	torso.position.y = 1.02
	body_visual.add_child(torso)
	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.17
	sph.height = 0.34
	head.mesh = sph
	head.material_override = mat("dummy")
	head.position.y = 1.72
	body_visual.add_child(head)
	# Target rings on the chest, facing -Z like the player's front.
	for i in 3:
		var ring := _cyl(0.2 - i * 0.065, 0.012 + i * 0.004, Vector3(0, 1.12, -0.26 - i * 0.004), Vector3(PI / 2.0, 0, 0), "target" if i % 2 == 0 else "dummy")
		body_visual.add_child(ring)
	body_visual.add_child(_box(Vector3(0.36, 0.05, 0.36), Vector3(0, 0.4, 0), "dummy_dark"))
	body_visual.add_child(_cyl(0.05, 0.4, Vector3(0, 0.2, 0), Vector3.ZERO, "dummy_dark"))
	body_visual.add_child(_cyl(0.3, 0.04, Vector3(0, 0.02, 0), Vector3.ZERO, "dummy_dark"))
	# Quadrant marks on the head, the crash-test look.
	body_visual.add_child(_box(Vector3(0.35, 0.02, 0.02), Vector3(0, 1.72, -0.165), "dummy_dark"))
	body_visual.add_child(_box(Vector3(0.02, 0.35, 0.02), Vector3(0, 1.72, -0.165), "dummy_dark"))


## Build and keep one of everything above so the warmup compiles their materials.
static func warm(parent: Node3D) -> void:
	var g := make_gun()
	parent.add_child(g)
	g.position = Vector3(0.4, 0.3, 0.0)
	var dummy := Node3D.new()
	parent.add_child(dummy)
	dummy.position = Vector3(-0.4, -0.5, -0.6)
	dummy.scale = Vector3.ONE * 0.4
	dress_dummy(dummy)
	for key in ["kill", "knock"]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.05, 0.05, 0.5)
		mi.mesh = bm
		mi.material_override = mat(key)
		mi.transparency = 0.5
		parent.add_child(mi)
		mi.position = Vector3(0.0 if key == "kill" else 0.2, 0.0, 0.0)
