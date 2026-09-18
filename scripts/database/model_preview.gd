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

## A specimen is photographed from four sides; the carousel steps between them.
const ANGLES := 4

## The plate, printed rather than lit. The specimen keeps its own tones, part-desaturated and a touch
## darker, and gets an inked outline where it ends -- which is the only reason a white gauze pack or a
## steel saw reads at all against ivory paper. Alpha is left alone, so there is no panel behind it.
const INK_SHADER := """
shader_type canvas_item;
uniform float ink_width = 1.6;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 printed = mix(c.rgb, vec3(l), 0.35) * 0.82;
	// How much specimen is just outside this pixel: that edge is where the ink goes.
	float near = 0.0;
	vec2 o = TEXTURE_PIXEL_SIZE * ink_width;
	near = max(near, texture(TEXTURE, UV + vec2(o.x, 0.0)).a);
	near = max(near, texture(TEXTURE, UV - vec2(o.x, 0.0)).a);
	near = max(near, texture(TEXTURE, UV + vec2(0.0, o.y)).a);
	near = max(near, texture(TEXTURE, UV - vec2(0.0, o.y)).a);
	near = max(near, texture(TEXTURE, UV + o).a);
	near = max(near, texture(TEXTURE, UV - o).a);
	near = max(near, texture(TEXTURE, UV + vec2(o.x, -o.y)).a);
	near = max(near, texture(TEXTURE, UV + vec2(-o.x, o.y)).a);
	float edge = clamp(near - c.a, 0.0, 1.0);
	COLOR = vec4(mix(printed, vec3(0.07, 0.07, 0.08), edge), max(c.a, edge));
}
"""
const GAP := 0.2
## A tray of tools is drawn like a catalogue plate, not to scale: real sizes are compressed by this
## power, so an anesthetic vial beside a bone saw is small but still a thing you can see. 1.0 would be
## true scale, 0.0 would make everything the same size.
const SIZE_EXP := 0.4
## However far a model has to be blown up to reach that, it stops here (and nothing is shrunk).
const SIZE_MAX := 8.0
const PITCH_DEG := 22.0
## Looking down on a tray of instruments, nearly overhead.
const TRAY_PITCH_DEG := 62.0
## The specimen sits on the slide, lit warm, on a pale disc: no phosphor glow any more.
const LAMP := Color(1.0, 0.94, 0.84)

var _vp: SubViewport
var _cam: Camera3D
var _pivot: Node3D
var _angle := 0
## This set is a tray of instruments (laid out in a column, shot from above).
var _tray := false
var _floor: MeshInstance3D
var _key := ""
var _hover: Node3D = null
const PICK_SLACK := 14.0
static var _black: StandardMaterial3D = null


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Everything the viewport renders goes through the ink pass on its way onto the slide.
	var sh := Shader.new()
	sh.code = INK_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	material = m
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.70, 0.66)
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
	rim.light_color = Color(0.86, 0.90, 0.95)
	_vp.add_child(rim)

	_pivot = Node3D.new()
	_vp.add_child(_pivot)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	_vp.add_child(_cam)
	_cam.current = true

	# The pale disc the specimen stands on: the ink pass (INK_SHADER) darkens it with everything else,
	# so it reads as the shaded ground of a printed plate.
	_floor = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.02
	disc.radial_segments = 40
	_floor.mesh = disc
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.72, 0.70, 0.64)
	fm.roughness = 0.95
	_floor.material_override = fm
	_pivot.add_child(_floor)
	_floor.visible = false


## Which of the four sides is facing us.
func angle() -> int:
	return _angle


## Face the specimen's nth side. There is no easing: the slide changes, it does not spin.
func set_angle(n: int) -> void:
	_angle = posmod(n, ANGLES)
	if _pivot != null:
		_pivot.rotation.y = float(_angle) * TAU / float(ANGLES)


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
	_pivot.rotation.y = float(_angle) * TAU / float(ANGLES)
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
	# A set of instruments is laid out as a tray and shot from above: one column down the plate, which
	# is a tall window, so each tool gets as much width as it can have. Anything with something big in
	# it (a monster, a patient) stays in the old grid, seen from eye level.
	var big := 0.0
	for bb in boxes:
		big = maxf(big, maxf(maxf((bb as AABB).size.x, (bb as AABB).size.y), (bb as AABB).size.z))
	_tray = models.size() > 1 and big < 0.9
	var cols := 1 if _tray else ceili(sqrt(float(models.size())))
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
			# The name is typed on the slide by wall_terminal_ui.gd, not stood up in the world: in here
			# the ink pass would outline its glyphs like part of the specimen.
			holder.set_meta("label", String(models[i].get_meta("preview_label")).to_upper())
	# The disc (kept for its size, not drawn) and the reach the camera has to fit. The specimen is shot
	# from four square-on sides now, not spun, so that is the wider of its two footprints -- not the
	# diagonal of the circle it used to sweep, which pushed the camera back and left everything tiny.
	var radius := maxf(maxf(all.size.x, all.size.z) * 0.5, 0.05)
	_floor.scale = Vector3(radius * 1.15, 1.0, radius * 1.15)
	_floor.position = Vector3(0, -0.012, 0)
	_floor.visible = false   # the slide's own vignette is the ground now
	# Looking down a little; far enough back that the turntable's whole width (it turns) fits the
	# narrower horizontal field and the models' height fits the vertical one.
	var height := all.size.y
	var aspect := size.x / maxf(size.y, 1.0)
	var half_v := tan(deg_to_rad(_cam.fov * 0.5))
	var half_h := half_v * aspect
	var pitch := deg_to_rad(TRAY_PITCH_DEG if _tray else PITCH_DEG)
	var fit_v := (height * 0.5 * cos(pitch) + radius * sin(pitch)) / half_v
	var fit_h := radius * 1.06 / half_h
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
	_hover = model


## The name of whatever the laser is over ("" for nothing), and where it is on the screen: the slide
## types it there itself.
func hover_label() -> String:
	if _hover == null or not is_instance_valid(_hover) or _hover.get_parent() == null:
		return ""
	var holder: Node = _hover.get_parent()
	return String(holder.get_meta("label")) if holder.has_meta("label") else ""


func hover_rect() -> Rect2:
	if _hover == null or not is_instance_valid(_hover) or _hover.get_parent() == null:
		return Rect2()
	return screen_rect(_hover.get_parent())


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
		_black.albedo_color = Color(0.02, 0.02, 0.025)
		_black.roughness = 1.0
		_black.metallic_specular = 0.0
	for gi in root.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).material_override = _black
