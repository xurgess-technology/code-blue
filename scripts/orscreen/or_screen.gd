extends Node
## The OR monitors (sweep 2 wave 3, `orscreen`). One controller per game, child "ORScreen" of Game.
##
## It watches game.level: whenever a new level appears it mounts the OR's monitors. Hub rebuild,
## chunk 2: level_info.or_screens ([{position, yaw, size, table}]) gives one monitor per table, each
## showing only its own table's patient (or "no patient"). Otherwise one monitor for every case at
## level_info.or_screen ({position, yaw, size}) or, without that key, on the flattest wall facing the
## operating table. The picture is a SubViewport drawn by or_screen_canvas.gd from
## or_screen_model.gd, derived locally from replicated game state on every machine.
##
## `mount`, `model`, `placement` and screen_centre()/screen_normal() describe the first monitor
## (tests and tools read them); `monitors` holds all of them.
##
## Cost control: each SubViewport renders only on request (UPDATE_ONCE), at REFRESH_NEAR_HZ while
## the live camera is close and REFRESH_FAR_HZ further away, and not at all while its screen is
## outside the camera's view or beyond VIEW_RANGE. Its light re-tints a few times a second.

const ModelScript := preload("res://scripts/orscreen/or_screen_model.gd")
const CanvasScript := preload("res://scripts/orscreen/or_screen_canvas.gd")

const DEFAULT_SIZE := Vector2(2.6, 1.46)
const CENTRE_HEIGHT := 1.85
const TEX_WIDTH := 1024
const VIEW_RANGE := 22.0
const NEAR_RANGE := 7.0
const REFRESH_NEAR_HZ := 12.0
const REFRESH_FAR_HZ := 5.0
const LIGHT_HZ := 4.0
const LIGHT_ENERGY := 0.16

var game: Node = null
## The mounted monitor (a Node3D under game.level), or null.
var mount: Node3D = null
## The last model the picture was drawn from (tests read it).
var model: Dictionary = {}
## Where it went and why: "level_info", "wall" or "floating".
var placement := ""
## Debug/perf: false stops all picture refreshes (the perfprobe A/B toggles it).
var enabled := true
## Picture refreshes so far (tests use it to check the gating).
var refresh_count := 0
## Test seam (tools/gameshot.gd): when not empty, shown instead of the model built from the game.
var model_override: Dictionary = {}

## Every mounted monitor: {mount, vp, canvas, light, quad, size, table (-1: every case), model,
## accum, light_accum, since}.
var monitors: Array = []

var _level: Node = null
var _place_wait := -1
var _quad: MeshInstance3D = null
var _size := DEFAULT_SIZE
var _t := 0.0
var _full: Dictionary = {}
var _full_frame := -1

static var _shader: Shader = null


func setup(g: Node) -> void:
	game = g


func mounted() -> bool:
	return mount != null and is_instance_valid(mount)


func screen_centre() -> Vector3:
	return _quad.global_position if mounted() and _quad != null else Vector3.ZERO


func screen_normal() -> Vector3:
	return mount.global_basis.z.normalized() if mounted() else Vector3.FORWARD


# ------------------------------------------------------------------------------ lifecycle

func _process(delta: float) -> void:
	if game == null:
		return
	var lvl = game.get("level")
	if lvl != _level or (lvl != null and not is_instance_valid(_level)):
		_level = lvl if lvl != null and is_instance_valid(lvl) else null
		_unmount()
		if _level != null:
			_place_wait = 2
	if not mounted():
		return
	if not enabled:
		return
	_t += delta
	for m in monitors:
		if not is_instance_valid(m.mount):
			continue
		(m.canvas as Control).set("t", _t)
		m.since += delta
		var cam_d := _camera_distance(m)
		if cam_d >= 0.0 and cam_d <= VIEW_RANGE:
			# The glow lights the room even when the glass itself is out of view.
			m.light_accum += delta
			if m.light_accum >= 1.0 / LIGHT_HZ:
				m.light_accum = 0.0
				if m.since > 1.0 / LIGHT_HZ:
					m.model = _model_for(int(m.table))
				_tint_light(m)
		var vis := _visibility_of(m)
		if vis < 0.0:
			continue
		m.accum += delta
		var interval := 1.0 / (REFRESH_NEAR_HZ if vis <= NEAR_RANGE else REFRESH_FAR_HZ)
		if m.accum >= interval:
			m.accum = 0.0
			_refresh(m)
	if not monitors.is_empty():
		model = monitors[0].model


## Perf A/B and debugging: hide the monitors and stop refreshing them.
func set_enabled(on: bool) -> void:
	enabled = on
	for m in monitors:
		if is_instance_valid(m.mount):
			m.mount.visible = on


func _camera_distance(m: Dictionary) -> float:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null or m.quad == null:
		return -1.0
	return cam.global_position.distance_to((m.quad as Node3D).global_position)


func _physics_process(_delta: float) -> void:
	if _place_wait < 0:
		return
	_place_wait -= 1
	if _place_wait <= 0:
		_place_wait = -1
		if _level != null and is_instance_valid(_level):
			_mount_on(_level)


## Rebuild the models and redraw every picture right now.
func refresh_now() -> void:
	if not mounted():
		return
	_full_frame = -1
	for m in monitors:
		_refresh(m)
	model = monitors[0].model


func _refresh(m: Dictionary) -> void:
	m.model = _model_for(int(m.table))
	m.canvas.model = m.model
	m.canvas.queue_redraw()
	(m.vp as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
	refresh_count += 1
	m.since = 0.0


## The picture for one table: every case's panel built once a frame, then only this table's panel
## (table -1: all of them).
func _model_for(table: int) -> Dictionary:
	var frame := Engine.get_process_frames()
	if frame != _full_frame:
		_full_frame = frame
		_full = model_override if not model_override.is_empty() else ModelScript.build(game)
	if table < 0:
		return _full
	var out := _full.duplicate()
	var panels: Array = []
	for p in _full.get("panels", []):
		if int(p.get("table", -1)) == table:
			panels.append(p)
	out["panels"] = panels
	out["mode"] = "cases" if not panels.is_empty() else "idle"
	return out


## Distance from the live camera to a monitor when its screen is in view and facing the camera,
## else -1.
func _visibility_of(m: Dictionary) -> float:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null or m.quad == null:
		return -1.0
	var mnt: Node3D = m.mount
	var c: Vector3 = (m.quad as Node3D).global_position
	var to_cam := cam.global_position - c
	var d := to_cam.length()
	if d > VIEW_RANGE or to_cam.dot(mnt.global_basis.z.normalized()) <= 0.0:
		return -1.0
	var sz: Vector2 = m.size
	var right := mnt.global_basis.x.normalized() * sz.x * 0.5
	var up := mnt.global_basis.y.normalized() * sz.y * 0.5
	for p in [c, c + right + up, c - right + up, c + right - up, c - right - up]:
		if cam.is_position_in_frustum(p):
			return d
	return -1.0


## The first monitor's visibility (tools/orscreentest.gd).
func _visibility() -> float:
	return _visibility_of(monitors[0]) if not monitors.is_empty() else -1.0


func _unmount() -> void:
	for m in monitors:
		if is_instance_valid(m.mount):
			m.mount.queue_free()
	monitors = []
	mount = null
	_quad = null
	placement = ""
	model = {}


# ------------------------------------------------------------------------------ placement

func _mount_on(level: Node) -> void:
	_unmount()
	var info: Dictionary = game.get("level_info") if game.get("level_info") is Dictionary else {}
	var spots: Array = []
	var per_table = info.get("or_screens")
	if per_table is Array and not per_table.is_empty():
		for o in per_table:
			var s := _level_spot(o, info)
			s["table"] = int(o.get("table", -1))
			spots.append(s)
	else:
		var s := find_spot(level, info)
		s["table"] = -1
		spots.append(s)
	for i in spots.size():
		var spot: Dictionary = spots[i]
		# On the level's own mount (a dark bezel the hospital builds, face ~0.087 m off the wall) only
		# the glass is added, just in front of it and inside its frame.
		var on_level_mount: bool = String(spot.how) == "level_info"
		var sz: Vector2 = spot.size - (Vector2(0.12, 0.12) if on_level_mount else Vector2.ZERO)
		var mnt := make_monitor(sz, not on_level_mount, 0.095 if on_level_mount else 0.072)
		mnt.name = "ORScreen" if i == 0 else "ORScreen%d" % i
		level.add_child(mnt)
		mnt.global_position = spot.position
		mnt.rotation = Vector3(0.0, float(spot.yaw), 0.0)
		mnt.visible = enabled
		var vp: SubViewport = mnt.get_node("Viewport")
		var m := {"mount": mnt, "vp": vp, "canvas": vp.get_node("Canvas"), "light": mnt.get_node("Glow"),
				"quad": mnt.get_node("Screen"), "size": sz, "table": int(spot.table), "model": {},
				"accum": 1.0, "light_accum": 0.0, "since": 0.0}
		monitors.append(m)
	mount = monitors[0].mount
	_quad = monitors[0].quad
	_size = monitors[0].size
	placement = String(spots[0].how)
	refresh_now()
	for m in monitors:
		_tint_light(m)


## Where the monitor goes: {position (on the wall, centre of the display), yaw (+Z faces the
## room), size, how}.
func find_spot(level: Node, info: Dictionary) -> Dictionary:
	var target := _table_centre(info)
	var o = info.get("or_screen")
	if o is Dictionary and o.has("position"):
		return _level_spot(o, info)
	var wall := _wall_spot(level, target, DEFAULT_SIZE)
	if not wall.is_empty():
		return wall
	return {"position": target + Vector3(0.0, CENTRE_HEIGHT, -3.5), "yaw": 0.0, "size": DEFAULT_SIZE, "how": "floating"}


## A monitor spot the level gave ({position, yaw, size}), turned to face the tables.
func _level_spot(o: Dictionary, info: Dictionary) -> Dictionary:
	var target := _table_centre(info)
	var floor_y := target.y
	var pos: Vector3 = o.position
	var size: Vector2 = o.get("size", DEFAULT_SIZE)
	if size.x < 0.3 or size.y < 0.2:
		size = DEFAULT_SIZE
	# A floor-level anchor means "on the wall above here".
	if pos.y < floor_y + 1.0:
		pos.y = floor_y + CENTRE_HEIGHT
	# level_info yaws face -Z into the room (Godot forward); this monitor faces its local +Z.
	var yaw := float(o.get("yaw", 0.0)) + PI
	# Whatever the convention, never face the wall: if +Z points away from the table, turn round.
	var n := Vector3(sin(yaw), 0.0, cos(yaw))
	var to_table := target - pos
	to_table.y = 0.0
	if to_table.length() > 0.2 and n.dot(to_table) < 0.0:
		yaw += PI
	return {"position": pos, "yaw": yaw, "size": size, "how": "level_info"}


func _table_centre(info: Dictionary) -> Vector3:
	var tables = info.get("tables")
	if tables is Array and not tables.is_empty():
		var sum := Vector3.ZERO
		var n := 0
		for tb in tables:
			if tb is Dictionary and tb.has("position"):
				sum += tb.position
				n += 1
		if n > 0:
			return sum / n
	if game != null and game.has_method("table_pos"):
		return game.table_pos()
	return info.get("table", Vector3.ZERO)


## Cast around the table at screen height and take the nearest-to-ideal flat wall that faces it,
## is wide enough, and is not right above the supply shelf.
func _wall_spot(level: Node, target: Vector3, size: Vector2) -> Dictionary:
	var world := (level as Node3D).get_world_3d() if level is Node3D else null
	if world == null:
		return {}
	var space := world.direct_space_state
	var eye := target + Vector3.UP * CENTRE_HEIGHT
	var shelf_pos := Vector3.INF
	var sn = game.get("shelf_node") if game != null else null
	if sn != null and is_instance_valid(sn):
		shelf_pos = sn.global_position
	var best := {}
	var best_score := INF
	var rays := 48
	for i in rays:
		var a := TAU * i / rays
		var dir := Vector3(cos(a), 0.0, sin(a))
		var hit := _ray(space, eye, eye + dir * 14.0)
		if hit.is_empty():
			continue
		var n: Vector3 = hit.normal
		n.y = 0.0
		if n.length() < 0.8:
			continue
		n = n.normalized()
		if n.dot(-dir) < 0.6:
			continue
		var p: Vector3 = hit.position
		var d := Vector2(p.x - eye.x, p.z - eye.z).length()
		if d < 1.8:
			continue
		if shelf_pos != Vector3.INF and Vector2(p.x - shelf_pos.x, p.z - shelf_pos.z).length() < size.x * 0.5 + 0.8:
			continue
		# Flat and wide enough: rays at the four corners (plus margin) meet the same plane.
		var side := Vector3(-n.z, 0.0, n.x)
		var flat := true
		for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1), Vector2(0, 0.0)]:
			var off: Vector3 = side * (size.x * 0.5 + 0.12) * c.x + Vector3.UP * (size.y * 0.5 + 0.05) * c.y
			var from := p + n * 0.6 + off
			var h2 := _ray(space, from, from - n * 1.0)
			if h2.is_empty() or (h2.normal as Vector3).dot(n) < 0.9 or absf((from - (h2.position as Vector3)).dot(n) - 0.6) > 0.08:
				flat = false
				break
		if not flat:
			continue
		var score := absf(d - 4.5) + (0.0 if n.dot(-dir) > 0.95 else 1.0)
		if score < best_score:
			best_score = score
			best = {"position": p + n * 0.01, "yaw": atan2(n.x, n.z), "size": size, "how": "wall"}
	return best


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = C.L_WORLD
	q.hit_back_faces = false
	return space.intersect_ray(q)


# ------------------------------------------------------------------------------ the object

func _tint_light(m: Dictionary) -> void:
	var light: OmniLight3D = m.light
	if light == null or not is_instance_valid(light):
		return
	var mdl: Dictionary = m.model
	var col := CanvasScript.GREEN
	var energy := LIGHT_ENERGY
	for p in mdl.get("panels", []):
		var c: Color
		if String(p.state) == "incoming":
			c = CanvasScript.AMBER
		elif String(p.state) == "dead" or String(p.level) == "critical":
			c = CanvasScript.RED
		elif String(p.level) == "low":
			c = CanvasScript.AMBER
		else:
			continue
		if c == CanvasScript.RED or col == CanvasScript.GREEN:
			col = c
	if String(mdl.get("mode", "idle")) == "idle":
		energy = LIGHT_ENERGY * 0.6
	light.light_color = col.lerp(Color.WHITE, 0.4)
	light.light_energy = energy


## A monitor on its wall bracket, origin on the wall surface at the display's centre, facing +Z.
## Children: "Viewport" (SubViewport with "Canvas"), "Screen" (the glass), "Bezel", "Glow".
static func make_monitor(size: Vector2, bezel_too := true, glass_z := 0.072) -> Node3D:
	var root := Node3D.new()
	var tex_h := int(round(TEX_WIDTH * size.y / size.x))
	var vp := SubViewport.new()
	vp.name = "Viewport"
	vp.size = Vector2i(TEX_WIDTH, tex_h)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.gui_disable_input = true
	root.add_child(vp)
	var canvas: Control = CanvasScript.new()
	canvas.name = "Canvas"
	canvas.size = Vector2(TEX_WIDTH, tex_h)
	vp.add_child(canvas)

	var bezel := MeshInstance3D.new()
	bezel.name = "Bezel"
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x + 0.1, size.y + 0.1, 0.07)
	bezel.mesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.07, 0.075, 0.08)
	bmat.roughness = 0.55
	bmat.metallic = 0.3
	bezel.material_override = bmat
	bezel.position = Vector3(0, 0, 0.035)
	bezel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if bezel_too:
		root.add_child(bezel)
	else:
		bezel.free()

	var quad := MeshInstance3D.new()
	quad.name = "Screen"
	var qm := QuadMesh.new()
	qm.size = size
	quad.mesh = qm
	var mat := ShaderMaterial.new()
	mat.shader = _screen_shader()
	mat.set_shader_parameter("screen_tex", vp.get_texture())
	mat.set_shader_parameter("lines", float(tex_h) * 0.5)
	quad.material_override = mat
	quad.position = Vector3(0, 0, glass_z)
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(quad)

	# A small green status LED under the glass.
	var led := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.03, 0.012, 0.01)
	led.mesh = lm
	var ledm := StandardMaterial3D.new()
	ledm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ledm.albedo_color = Color(0.4, 1.0, 0.5)
	led.material_override = ledm
	led.position = Vector3(size.x * 0.5 - 0.02, -size.y * 0.5 - 0.028, glass_z)
	led.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(led)

	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.light_color = Color(0.5, 1.0, 0.65)
	glow.light_energy = LIGHT_ENERGY
	glow.omni_range = 4.0
	glow.omni_attenuation = 1.4
	glow.shadow_enabled = false
	glow.light_specular = 0.2
	glow.light_volumetric_fog_energy = 0.05
	glow.distance_fade_enabled = true
	glow.distance_fade_begin = 18.0
	glow.distance_fade_length = 4.0
	glow.position = Vector3(0, -0.1, 0.7)
	root.add_child(glow)
	return root


static func _screen_shader() -> Shader:
	if _shader != null:
		return _shader
	_shader = Shader.new()
	_shader.code = """
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
uniform float lines = 288.0;
uniform float brightness = 1.25;

void fragment() {
	vec3 c = texture(screen_tex, UV).rgb;
	// Scanlines, faded out once they get finer than a few pixels so they never shimmer.
	float per_px = fwidth(UV.y) * lines;
	float fade = 1.0 - smoothstep(0.18, 0.45, per_px);
	float sl = 0.5 + 0.5 * cos(UV.y * lines * 6.2831853);
	c *= 1.0 - 0.22 * sl * fade;
	// Glass: darker corners and a faint green cast where the picture is black.
	vec2 d = UV - 0.5;
	c *= 1.0 - 0.45 * dot(d, d);
	c += vec3(0.003, 0.012, 0.007);
	ALBEDO = c * brightness;
}
"""
	return _shader


## Warmup: build a monitor once so its shader and viewport compile behind the cover.
static func warm(parent: Node3D) -> void:
	var m := make_monitor(Vector2(0.8, 0.45))
	parent.add_child(m)
	m.position = Vector3(0.8, 0.6, 0.0)
