extends SubViewportContainer
## The database terminal's 3D viewer: the models a page talks about (a monster, its brain, an item,
## every tool a procedure needs), lit and slowly turning in their own little world beside the text.
## One per terminal, kept for its whole life; `show_models` swaps what stands on the turntable, so a
## page that redraws its text every frame never rebuilds the viewport.
##
##   show_models(key, models, silhouette)   models: [Node3D] (not in a tree yet), laid out in a row
##                                     and framed; silhouette: every surface flat black (unscanned).
##                                     Meta on a model: "preview_monster" = kind (a MonsterModel to
##                                     set up in the tree), "preview_scale" = enlarge it (a brain),
##                                     "preview_bounds" = its AABB (origin on the floor) when mesh
##                                     bounds would lie (skinned rigs).
##   clear()
##   pick(local) -> Node3D                  the model under a point in the viewer (null: none)
##   set_hover(model)                       show that model's "preview_label" over it (null: none)

const TURN_SPEED := 0.45
const GAP := 0.12
const PITCH_DEG := 22.0
const GREEN := Color(0.45, 1.0, 0.55)

var _vp: SubViewport
var _cam: Camera3D
var _pivot: Node3D
var _floor: MeshInstance3D
var _key := ""
var _hover: Node3D = null
const PICK_SLACK := 14.0
static var _black: StandardMaterial3D = null


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.58)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38.0, 35.0, 0.0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.97, 0.9)
	_vp.add_child(key)
	# A green rim from behind, the terminal's own glow.
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-15.0, 200.0, 0.0)
	rim.light_energy = 1.1
	rim.light_color = GREEN
	_vp.add_child(rim)

	_pivot = Node3D.new()
	_vp.add_child(_pivot)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	_vp.add_child(_cam)
	_cam.current = true

	# A dim turntable disc under the models.
	_floor = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.02
	disc.radial_segments = 40
	_floor.mesh = disc
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.05, 0.12, 0.08)
	fm.emission_enabled = true
	fm.emission = Color(0.1, 0.35, 0.16)
	fm.emission_energy_multiplier = 0.4
	_floor.material_override = fm
	_pivot.add_child(_floor)
	_floor.visible = false


func _process(delta: float) -> void:
	if is_visible_in_tree():
		_pivot.rotate_y(delta * TURN_SPEED)


## What is showing, so a page can skip rebuilding the same models every frame.
func current_key() -> String:
	return _key


func clear() -> void:
	_key = ""
	_hover = null
	for c in _pivot.get_children():
		if c != _floor:
			c.queue_free()
	_floor.visible = false


func show_models(key: String, models: Array, silhouette := false) -> void:
	clear()
	_key = key
	_pivot.rotation = Vector3.ZERO
	if models.is_empty():
		return
	# Each model sits on the floor, centred on the turntable.
	var boxes: Array = []
	for m in models:
		var holder := Node3D.new()
		_pivot.add_child(holder)
		holder.add_child(m)
		# A monster model builds itself once it is in the tree (monster_model.gd setup).
		if m.has_meta("preview_monster"):
			m.setup(String(m.get_meta("preview_monster")))
		if m.has_meta("preview_scale"):
			m.scale = Vector3.ONE * float(m.get_meta("preview_scale"))
		# A skinned rig's mesh bounds are its rest pose, not what stands there: models can say.
		boxes.append(m.get_meta("preview_bounds") if m.has_meta("preview_bounds") else _bounds(holder))
		holder.set_meta("box", boxes[-1])
	# Several models share the turntable in a small grid (a row of tools spins as a wide circle and
	# ends up tiny), one cell each, cells as big as the largest footprint.
	var cols := ceili(sqrt(float(models.size())))
	var rows := ceili(float(models.size()) / float(cols))
	var cell := Vector2.ZERO
	for bb in boxes:
		cell = Vector2(maxf(cell.x, (bb as AABB).size.x), maxf(cell.y, (bb as AABB).size.z))
	cell += Vector2(GAP, GAP)
	var all := AABB()
	for i in models.size():
		var holder: Node3D = models[i].get_parent()
		var b: AABB = boxes[i]
		var c := Vector2(float(i % cols) - (cols - 1) * 0.5, float(i / cols) - (rows - 1) * 0.5) * cell
		# In the last, shorter row, centre what's there.
		if i / cols == rows - 1:
			var in_row := models.size() - (rows - 1) * cols
			c.x = (float(i % cols) - (in_row - 1) * 0.5) * cell.x
		holder.position = Vector3(c.x - (b.position.x + b.size.x * 0.5), -b.position.y, c.y - (b.position.z + b.size.z * 0.5))
		var placed := AABB(b.position + holder.position, b.size)
		all = placed if i == 0 else all.merge(placed)
		if silhouette:
			_blacken(holder)
		if models[i].has_meta("preview_label"):
			var tag := Label3D.new()
			tag.name = "Tag"
			tag.text = String(models[i].get_meta("preview_label")).to_upper()
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.fixed_size = true
			tag.pixel_size = 0.0012
			tag.font_size = 40
			tag.outline_size = 10
			tag.modulate = Color(0.75, 1.0, 0.8)
			tag.outline_modulate = Color(0.0, 0.08, 0.03)
			tag.no_depth_test = true
			tag.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM   # sits above the model
			tag.position = Vector3(b.get_center().x, b.end.y + 0.06, b.get_center().z)
			tag.visible = false
			holder.add_child(tag)
	# The disc under everything, and a camera far enough back to fit it all while it turns.
	var radius := maxf(Vector2(all.size.x, all.size.z).length() * 0.5, 0.05)
	_floor.scale = Vector3(radius * 1.15, 1.0, radius * 1.15)
	_floor.position = Vector3(0, -0.012, 0)
	_floor.visible = true
	# Looking down a little; far enough back that the turntable's whole width (it turns) fits the
	# narrower horizontal field and the models' height fits the vertical one.
	var height := all.size.y
	var aspect := size.x / maxf(size.y, 1.0)
	var half_v := tan(deg_to_rad(_cam.fov * 0.5))
	var half_h := half_v * aspect
	var pitch := deg_to_rad(PITCH_DEG)
	var fit_v := (height * 0.5 * cos(pitch) + radius * sin(pitch)) / half_v
	var fit_h := radius * 1.12 / half_h
	var dist := maxf(fit_v, fit_h) + radius * cos(pitch)
	var centre := Vector3(0.0, height * 0.5, 0.0)
	_cam.position = centre + Vector3(0.0, sin(pitch), cos(pitch)) * dist
	_cam.look_at(centre, Vector3.UP)
	_cam.near = maxf(0.01, dist * 0.02)
	_cam.far = dist * 6.0 + 10.0


## The model under `local` (a point in this viewer, in pixels); null for none. Forgiving: a laser
## wobbles and tools are small, so each model's on-screen box counts, plus PICK_SLACK pixels.
func pick(local: Vector2) -> Node3D:
	if local.x < 0.0 or local.y < 0.0 or local.x > size.x or local.y > size.y:
		return null
	var best: Node3D = null
	var best_d := INF
	for holder in _pivot.get_children():
		if holder == _floor or not holder.has_meta("box") or holder.get_child_count() == 0:
			continue
		var r := screen_rect(holder)
		if not r.grow(PICK_SLACK).has_point(local):
			continue
		var d := r.get_center().distance_to(local)
		if d < best_d:
			best_d = d
			best = holder.get_child(0) as Node3D
	return best


## A model holder's box as it appears in this viewer, in pixels.
func screen_rect(holder: Node3D) -> Rect2:
	var box: AABB = holder.get_meta("box")
	var r := Rect2()
	for n in 8:
		var corner := holder.global_transform * box.get_endpoint(n)
		var at := _cam.unproject_position(corner) * (size / Vector2(_vp.size))
		r = Rect2(at, Vector2.ZERO) if n == 0 else r.expand(at)
	return r


func set_hover(model: Node3D) -> void:
	if model == _hover:
		return
	for m in [_hover, model]:
		if m != null and is_instance_valid(m) and m.get_parent() != null:
			var tag: Node3D = m.get_parent().get_node_or_null("Tag")
			if tag != null:
				tag.visible = m == model
	_hover = model


## The visual bounds of everything under `root`, in `root`'s parent space (the pivot).
func _bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for gi in root.find_children("*", "VisualInstance3D", true, false):
		if not (gi is GeometryInstance3D) or not (gi as Node3D).is_visible_in_tree():
			continue
		var local: AABB = (gi as VisualInstance3D).get_aabb()
		if local.size == Vector3.ZERO:
			continue
		var xf: Transform3D = _pivot.global_transform.affine_inverse() * (gi as Node3D).global_transform
		var b := xf * local
		out = b if first else out.merge(b)
		first = false
	if first:
		return AABB(Vector3(-0.1, 0, -0.1), Vector3(0.2, 0.2, 0.2))
	return out


static func _blacken(root: Node) -> void:
	if _black == null:
		_black = StandardMaterial3D.new()
		_black.albedo_color = Color(0.015, 0.02, 0.018)
		_black.roughness = 1.0
		_black.metallic_specular = 0.0
	for gi in root.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).material_override = _black
