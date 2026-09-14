extends Node3D
## Two paramedics wheeling a gurney (loop, sweep 2). Nothing thinks; since the models sweep the
## medics are rigged Kenney characters and the crew has solid collision (_make_blockers).
## The shift loop moves the crew (the host along the navmesh, clients toward the replicated
## position) and says which phase it is in; the crew animates to match.
##
## Local frame: the crew walks along -Z. The gurney is in the middle, one medic pulls at the
## front, one pushes at the back. The patient lies on the gurney until the hand-over.

const WALK_CYCLE := 7.5
const HEAD_SKIN := Color("d9ad8c")

const BodyScript := preload("res://scripts/patient_body.gd")

var patient_id := ""
var ailment_id := ""
var phase := "in"          # "in" (bringing), "hand" (putting on the table), "out" (leaving)
var target_pos := Vector3.ZERO
var target_yaw := 0.0

var _walk := 0.0
var _speed := 0.0
var _gurney: Node3D
var _body: Node3D = null
var _medics: Array = []    # [{root, legs: [Node3D, Node3D], arms: [..]}]
var _placed := false


static func create(pid: String, ail: String) -> Node3D:
	var n: Node3D = (load("res://scripts/loop/crew.gd") as GDScript).new()
	n.name = "ParamedicCrew"
	n.patient_id = pid
	n.ailment_id = ail
	n._build()
	return n


func _build() -> void:
	_gurney = _make_gurney()
	_gurney.position = Vector3(0, 0, 0)
	add_child(_gurney)
	if patient_id != "" and patient_id != "player" and not Procedures.patient(patient_id).is_empty():
		_body = BodyScript.create(patient_id)
		_body.name = "Patient"
		# Bodies lie along their local X (the table's long axis); the gurney runs along Z.
		_body.rotation.y = PI * 0.5
		_body.position = Vector3(0, 0.86, 0)
		_gurney.add_child(_body)
		if _body.has_method("set_ailment"):
			_body.set_ailment(ailment_id)
		if _body.has_method("set_vitals"):
			_body.set_vitals(70.0)
	_make_medic(Vector3(0, 0, -1.55), 0.0, Color("2f4f3f"), "crew/paramedic_a", false)   # pulling at the front
	_make_medic(Vector3(0, 0, 1.3), 0.0, Color("2f4f3f"), "crew/paramedic_b", true)      # pushing at the back
	_make_blockers()


## Jump straight to a pose (the first placement, or a big correction).
func snap(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation.y = yaw
	target_pos = pos
	target_yaw = yaw
	_placed = true


func set_target(pos: Vector3, yaw: float, new_phase: String) -> void:
	if not _placed:
		snap(pos, yaw)
	target_pos = pos
	target_yaw = yaw
	phase = new_phase


func _process(delta: float) -> void:
	var before := global_position
	var k := clampf(delta * 10.0, 0.0, 1.0)
	if global_position.distance_to(target_pos) > 6.0:
		global_position = target_pos
	else:
		global_position = global_position.lerp(target_pos, k)
	rotation.y = lerp_angle(rotation.y, target_yaw, k)
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_speed = lerpf(_speed, moved / maxf(delta, 1e-4), clampf(delta * 8.0, 0.0, 1.0))
	_walk += delta * WALK_CYCLE * clampf(_speed / 2.0, 0.0, 1.2)
	var swing := sin(_walk) * 0.55 * clampf(_speed / 1.2, 0.0, 1.0)
	for i in _medics.size():
		var m: Dictionary = _medics[i]
		if m.has("tree"):
			# models sweep 2: the rigged paramedic blends idle -> walk by speed; the walk's own
			# stride speed follows how fast the crew rolls.
			var amt := clampf(_speed / 1.0, 0.0, 1.0)
			(m.tree as AnimationTree).set("parameters/move/blend_amount", amt)
			(m.tree as AnimationTree).set("parameters/pace/scale", clampf(_speed / 1.25, 0.6, 1.6))
			continue
		var s := swing if i == 0 else -swing
		(m.legs[0] as Node3D).rotation.x = s
		(m.legs[1] as Node3D).rotation.x = -s
		(m.root as Node3D).position.y = absf(sin(_walk)) * 0.025 * clampf(_speed, 0.0, 1.0)
	if _body != null:
		_body.visible = phase != "out"
		if _body.has_method("set_sedation"):
			_body.set_sedation(0.2)
	# The gurney casters jiggle on the tiles while it rolls.
	_gurney.position.y = absf(sin(_walk * 2.3)) * 0.008 * clampf(_speed, 0.0, 1.0)


func is_moving() -> bool:
	return _speed > 0.3


# ---------------------------------------------------------------------------- models

const ItemModelsScript := preload("res://scripts/item_models.gd")

## Looping animation libraries and recoloured materials per paramedic model key, shared by every
## crew (the imported resources are never modified).
static var _libs := {}
## Tools only (perfprobe --models): the capsule medics, as before the models sweep.
static var shapes_only := false
static var _skins := {}
## models sweep 2: the gurney is still built from shapes (no CC0 hospital gurney or stretcher
## exists on any vetted source; see ASSETS.md), merged once into one mesh with one surface per
## material and shared by every crew. The frame uses the brushed steel texture from Assets.
static var _gurney_mesh: ArrayMesh = null


func _make_gurney() -> Node3D:
	var g := Node3D.new()
	g.name = "Gurney"
	if _gurney_mesh == null:
		_gurney_mesh = _build_gurney_mesh()
	var mi := MeshInstance3D.new()
	mi.name = "Frame"
	mi.mesh = _gurney_mesh
	g.add_child(mi)
	# The drip bag is see-through, so it stays out of the merged (opaque) mesh.
	var bag := _box(Vector3(0.1, 0.16, 0.04), Vector3(-0.28, 1.62, -0.85), _mat(Color(0.8, 0.9, 1.0, 0.7), 0.2))
	(bag.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	g.add_child(bag)
	return g


static func _build_gurney_mesh() -> ArrayMesh:
	var steel: Material = _mat(Color(0.62, 0.64, 0.66), 0.35, 0.7)
	var loop := Engine.get_main_loop()
	var assets = (loop as SceneTree).root.get_node_or_null("Assets") if loop is SceneTree else null
	if assets != null and assets.has("mat/metal"):
		steel = assets.material("mat/metal")
	var dark := _mat(Color(0.1, 0.1, 0.11), 0.8)
	var sheet := _mat(Color(0.86, 0.88, 0.86), 0.9)
	var mattress := _mat(Color(0.16, 0.22, 0.3), 0.7)
	var orange := _mat(Color(0.9, 0.42, 0.1), 0.6)
	var parts := []
	# Frame, a dark vinyl mattress and the sheet over it (long along Z).
	_part(parts, Vector3(0.62, 0.05, 1.95), Vector3(0, 0.66, 0), steel)
	_part(parts, Vector3(0.58, 0.1, 1.9), Vector3(0, 0.74, 0), mattress)
	_part(parts, Vector3(0.6, 0.025, 1.7), Vector3(0, 0.8, 0.08), sheet)
	_part(parts, Vector3(0.5, 0.08, 0.3), Vector3(0, 0.83, -0.75), sheet)
	# Side rails and the orange straps across the patient.
	for sx in [-1, 1]:
		_part(parts, Vector3(0.025, 0.025, 1.7), Vector3(0.32 * sx, 0.86, 0), steel)
		for z in [-0.6, 0.6]:
			_part(parts, Vector3(0.02, 0.14, 0.02), Vector3(0.32 * sx, 0.78, z), steel)
	for z in [-0.35, 0.45]:
		_part(parts, Vector3(0.66, 0.012, 0.07), Vector3(0, 0.99, z), orange)
	# Scissor legs, a base frame and casters.
	for sz in [-1, 1]:
		for sx in [-1, 1]:
			_part(parts, Vector3(0.035, 0.62, 0.035), Vector3(0.24 * sx, 0.34, 0.72 * sz), steel, Basis(Vector3.RIGHT, 0.28 * sz))
			var wheel := CylinderMesh.new()
			wheel.top_radius = 0.06
			wheel.bottom_radius = 0.06
			wheel.height = 0.04
			wheel.radial_segments = 12
			wheel.rings = 1
			parts.append([wheel, 0, Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0.24 * sx, 0.06, 0.8 * sz)), dark])
			_part(parts, Vector3(0.03, 0.06, 0.03), Vector3(0.24 * sx, 0.12, 0.8 * sz), steel)
		_part(parts, Vector3(0.52, 0.03, 0.03), Vector3(0, 0.15, 0.8 * sz), steel)
	# Push handle at the back, an IV pole at the head end.
	_part(parts, Vector3(0.6, 0.03, 0.03), Vector3(0, 0.98, 1.02), steel)
	for sx in [-1, 1]:
		_part(parts, Vector3(0.025, 0.3, 0.025), Vector3(0.29 * sx, 0.84, 1.0), steel)
	_part(parts, Vector3(0.02, 1.0, 0.02), Vector3(-0.28, 1.2, -0.85), steel)
	_part(parts, Vector3(0.12, 0.012, 0.012), Vector3(-0.28, 1.7, -0.85), steel)
	return ItemModelsScript.merge_parts(parts, 1000000)


static func _part(parts: Array, size: Vector3, pos: Vector3, mat: Material, basis := Basis()) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	parts.append([bm, 0, Transform3D(basis, pos), mat])


## A paramedic: the rigged Kenney character in a green uniform when the model exists (it walks;
## the one at the back holds the push handle), else the old capsule figure.
func _make_medic(at: Vector3, yaw: float, uniform: Color, key: String, pushing: bool) -> Node3D:
	var rig: Node3D = Assets.spawn(key) if Assets.has(key) and not shapes_only else null
	var ap: AnimationPlayer = Assets.anim_player(rig) if rig != null else null
	if rig == null or ap == null:
		if rig != null:
			rig.free()
		return _make_medic_shapes(at, yaw, uniform)
	var root := Node3D.new()
	root.name = "Medic"
	root.position = at
	root.rotation.y = yaw
	add_child(root)
	root.add_child(rig)
	var skin := _medic_skin(key, rig)
	if skin != null:
		for mi in rig.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = skin
	var lib_names := ap.get_animation_library_list()
	var lib_name: StringName = lib_names[0] if not lib_names.is_empty() else &""
	var lib := _medic_library(key, ap, lib_name)
	if lib != null:
		ap.remove_animation_library(lib_name)
		ap.add_animation_library(lib_name, lib)
	var tree := AnimationTree.new()
	tree.name = "Anim"
	ap.get_parent().add_child(tree)
	tree.anim_player = NodePath("../" + String(ap.name))
	var prefix := ("%s/" % lib_name) if String(lib_name) != "" else ""
	var bt := AnimationNodeBlendTree.new()
	for pair in [["idle", "idle"], ["walk", "walk"], ["hold", "holding-both"]]:
		var an := AnimationNodeAnimation.new()
		an.animation = prefix + String(pair[1])
		bt.add_node(pair[0], an)
	bt.add_node("move", AnimationNodeBlend2.new())
	bt.add_node("pace", AnimationNodeTimeScale.new())
	var arms := AnimationNodeBlend2.new()
	arms.filter_enabled = true
	var hold_name := prefix + "holding-both"
	var hold_anim: Animation = ap.get_animation(hold_name) if ap.has_animation(hold_name) else null
	if hold_anim != null:
		for t in hold_anim.get_track_count():
			var path := hold_anim.track_get_path(t)
			if String(path).contains("arm-"):
				arms.set_filter_path(path, true)
	bt.add_node("arms", arms)
	bt.connect_node("move", 0, "idle")
	bt.connect_node("move", 1, "walk")
	bt.connect_node("pace", 0, "move")
	bt.connect_node("arms", 0, "pace")
	bt.connect_node("arms", 1, "hold")
	bt.connect_node("output", 0, "arms")
	tree.tree_root = bt
	tree.set("parameters/arms/blend_amount", 1.0 if pushing and hold_anim != null else 0.0)
	tree.set("parameters/move/blend_amount", 0.0)
	tree.set("parameters/pace/scale", 1.0)
	tree.active = true
	_medics.append({"root": root, "tree": tree})
	return root


static func _medic_skin(key: String, rig: Node) -> Material:
	if _skins.has(key):
		return _skins[key]
	var out: Material = null
	var tex_path := String(Assets.info(key).get("albedo", ""))
	if tex_path != "" and ResourceLoader.exists(tex_path):
		for n in rig.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			var src: Material = mi.mesh.surface_get_material(0) if mi.mesh != null else null
			if src is StandardMaterial3D:
				var m := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
				m.albedo_texture = load(tex_path)
				m.resource_name = key.replace("/", "_")
				out = m
				break
	_skins[key] = out
	return out


## A copy of the model's clips with idle, walk and the push pose looping.
static func _medic_library(key: String, ap: AnimationPlayer, lib_name: StringName) -> AnimationLibrary:
	if _libs.has(key):
		return _libs[key]
	var src := ap.get_animation_library(lib_name) if ap.has_animation_library(lib_name) else null
	if src == null:
		return null
	var lib: AnimationLibrary = src.duplicate(false)
	for n in ["idle", "walk", "holding-both"]:
		if lib.has_animation(n):
			var a: Animation = lib.get_animation(n).duplicate(false)
			a.loop_mode = Animation.LOOP_LINEAR
			lib.remove_animation(n)
			lib.add_animation(n, a)
	_libs[key] = lib
	return lib


## Solid bodies so players (and monsters) cannot walk through the gurney or the paramedics. They
## are on the world layer and move with the crew. The level's navigation mesh is baked from the
## level's own mesh instances before any crew exists, so the crew never changes its own path.
func _make_blockers() -> void:
	var body := AnimatableBody3D.new()
	body.name = "Blocker"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	body.sync_to_physics = false
	add_child(body)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.66, 1.0, 2.05)
	cs.shape = bs
	cs.position = Vector3(0, 0.5, 0)
	body.add_child(cs)
	for m in _medics:
		var mc := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.24
		cap.height = 1.7
		mc.shape = cap
		mc.position = (m.root as Node3D).position + Vector3(0, 0.85, 0)
		body.add_child(mc)


## The capsule figure (no model): the fallback when the Kenney character is missing.
func _make_medic_shapes(at: Vector3, yaw: float, uniform: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Medic"
	root.position = at
	root.rotation.y = yaw
	add_child(root)
	var cloth := _mat(uniform, 0.85)
	var pants := _mat(uniform.darkened(0.35), 0.9)
	var hi_vis := _mat(Color(0.85, 0.95, 0.25), 0.4)
	hi_vis.emission_enabled = true
	hi_vis.emission = Color(0.7, 0.8, 0.2)
	hi_vis.emission_energy_multiplier = 0.35
	var skin := _mat(HEAD_SKIN, 0.7)
	var boots := _mat(Color(0.08, 0.08, 0.09), 0.7)
	# Torso and the reflective bands.
	var torso := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.22
	cap.height = 0.78
	cap.radial_segments = 10
	cap.rings = 4
	torso.mesh = cap
	torso.material_override = cloth
	torso.position = Vector3(0, 1.22, 0)
	root.add_child(torso)
	for y in [1.08, 1.3]:
		var band := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.225
		cyl.bottom_radius = 0.225
		cyl.height = 0.05
		cyl.radial_segments = 10
		band.mesh = cyl
		band.material_override = hi_vis
		band.position = Vector3(0, y, 0)
		root.add_child(band)
	# Head, cap.
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.radial_segments = 10
	sm.rings = 6
	head.mesh = sm
	head.material_override = skin
	head.position = Vector3(0, 1.74, 0)
	root.add_child(head)
	root.add_child(_box(Vector3(0.24, 0.07, 0.26), Vector3(0, 1.83, 0.01), cloth))
	root.add_child(_box(Vector3(0.22, 0.02, 0.1), Vector3(0, 1.8, -0.15), cloth))
	# Legs swing from the hip.
	var legs := []
	for sx in [-1, 1]:
		var hip := Node3D.new()
		hip.position = Vector3(0.1 * sx, 0.86, 0)
		root.add_child(hip)
		hip.add_child(_box(Vector3(0.13, 0.8, 0.15), Vector3(0, -0.4, 0), pants))
		hip.add_child(_box(Vector3(0.14, 0.08, 0.24), Vector3(0, -0.82, -0.04), boots))
		legs.append(hip)
	# Arms reaching for the gurney handle / rail (toward the gurney's middle).
	var reach := signf(at.z) if absf(at.z) > 0.01 else 1.0
	var arms := []
	for sx in [-1, 1]:
		var shoulder := Node3D.new()
		shoulder.position = Vector3(0.26 * sx, 1.45, 0)
		shoulder.rotation.x = 1.05 * reach
		root.add_child(shoulder)
		shoulder.add_child(_box(Vector3(0.1, 0.56, 0.1), Vector3(0, -0.28, 0), cloth))
		shoulder.add_child(_box(Vector3(0.09, 0.1, 0.1), Vector3(0, -0.6, 0), skin))
		arms.append(shoulder)
	_medics.append({"root": root, "legs": legs, "arms": arms})
	return root


static func _mat(col: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
