extends Node
## Hive Eyes, on the watching player's machine only (brains, sweep 3; the fly-through is sweep 4a
## chunk 4): a camera riding in a Hive's eyes and a grainy, sickly, night-sight screen over it.
## main.gd renders through `camera` while `active` (game.brains.camera()). Hives see in the
## dark, so the screen lifts the shadows a lot; everything is a washed-out yellow-green with
## grain, scan lines and a slow wobble.
##
## The brains system (host) says which monster and until when; everything about the flight -- the
## camera leaving the player's own head, gliding along the navmesh to the Hive (or a straight
## line when there is no path) and settling into its eyes over FLIGHT_IN seconds, then a quick
## FLIGHT_OUT glide back on a normal end -- is local and purely cosmetic (docs/SWEEP4A.md "Hive
## Eyes"). A hit, the Hive dying or going under snap back instantly instead (no fly-back):
## this file decides that itself, by comparing the local player's hp/state to what it was when
## the flight started, since only the local machine can react to its own hit instantly.

const OVERLAY_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float amount = 1.0;
uniform float time_s = 0.0;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = SCREEN_UV;
	uv.x += sin(uv.y * 34.0 + time_s * 5.0) * 0.0016 * amount;
	uv.y += sin(uv.x * 21.0 - time_s * 3.1) * 0.0011 * amount;
	vec3 c = textureLod(screen_tex, uv, 0.0).rgb;
	// Colour fringe: the eyes are not good eyes.
	float fr = textureLod(screen_tex, uv + vec2(0.0025, 0.0), 0.0).r;
	float lum = dot(c, vec3(0.3, 0.59, 0.11));
	lum = pow(clamp(lum, 0.0, 1.0), 0.45) * 1.25;
	vec3 sick = vec3(0.62, 0.78, 0.36) * lum + vec3(0.03, 0.05, 0.0);
	sick.r = mix(sick.r, fr * 1.4, 0.18);
	float grain = h(floor(FRAGCOORD.xy / 2.0) + vec2(fract(time_s * 13.0) * 97.0, fract(time_s * 7.0) * 53.0)) - 0.5;
	float scan = 0.9 + 0.1 * sin(FRAGCOORD.y * 1.3 + time_s * 40.0);
	vec2 d = UV - vec2(0.5);
	float vig = smoothstep(0.78, 0.22, length(d * vec2(1.35, 1.0)));
	float blink = 1.0 - 0.85 * smoothstep(0.95, 1.0, sin(time_s * 0.9) * 0.5 + 0.5);
	vec3 outc = (sick + grain * 0.13) * scan * vig * blink;
	COLOR = vec4(mix(c, outc, amount), 1.0);
}
"""

static var _shader: Shader = null

## SWEEP 4A HOOK (Hive Eyes fly-through, chunk 4): local, cosmetic, both ends of the flight.
const FLIGHT_IN := 1.2
const FLIGHT_OUT := 0.3

var game: Node = null
var active := false
var monster_id := -1
var until := 0.0
var camera: Camera3D
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial
var _label: Label
var _t := 0.0
var _fade := 0.0

## "in" (flying to the Hive), "settled" (riding its eyes) or "out" (flying back to the body).
var _phase := "in"
var _phase_t := 0.0
var _path: PackedVector3Array = PackedVector3Array()
var _start_hp := 0
var _pending_end := false


static func overlay_material() -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = OVERLAY_SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	return m


func setup(g: Node) -> void:
	game = g
	camera = Camera3D.new()
	camera.name = "HiveEyesCamera"
	camera.fov = 88.0
	camera.near = 0.05
	camera.far = 70.0
	camera.current = false
	add_child(camera)
	_layer = CanvasLayer.new()
	_layer.name = "HiveEyesOverlay"
	_layer.layer = 1   # over the world, under the HUD (2)
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = overlay_material()
	_rect.material = _mat
	_layer.add_child(_rect)
	_label = Label.new()
	_label.anchor_left = 0.0
	_label.anchor_right = 1.0
	_label.offset_top = 38
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.78, 0.9, 0.55, 0.85))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("outline_size", 5)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_label)
	_layer.visible = false


## Look through monster `id` until world_time `end_at` (or stop with id -1). Called every frame
## from brains.gd's physics_tick with the current authoritative state, on every machine; only
## transitions (inactive -> active, ending, or the target id changing) do anything.
func set_target(id: int, end_at: float) -> void:
	if id < 0:
		if active and not _pending_end:
			_pending_end = true
			_begin_end()
		return
	_pending_end = false
	if not active:
		_begin_start(id)
	elif id != monster_id and _phase == "settled":
		_begin_cycle(id)
	monster_id = id
	until = end_at
	active = true


func _local_me() -> Node:
	return game.local_player() if game != null else null


func _local_eye() -> Transform3D:
	var me := _local_me()
	if me != null and me.get("camera") != null:
		return (me.camera as Camera3D).global_transform
	return camera.global_transform


func _begin_start(id: int) -> void:
	_t = 0.0
	_fade = 0.0
	_phase = "in"
	_phase_t = 0.0
	var me := _local_me()
	_start_hp = int(me.hp) if me != null else 0
	var m = game.monsters.get(id)
	var from_xf := _local_eye()
	var to_pos: Vector3 = (m as Node3D).global_position if m != null else from_xf.origin
	_path = _path_from(from_xf.origin, to_pos)
	camera.global_transform = from_xf
	Audio.play("brains_hive_in", null, -3.0)


func _begin_cycle(id: int) -> void:
	_phase = "in"
	_phase_t = 0.0
	var m = game.monsters.get(id)
	var to_pos: Vector3 = (m as Node3D).global_position if m != null else camera.global_position
	_path = _path_from(camera.global_position, to_pos)
	Audio.play("brains_hive_in", null, -3.0, 0.1)


func _begin_end() -> void:
	# A hit, the Hive dying/going under, or the player going down/being carried snap back
	# instantly (docs/SWEEP4A.md "Hive Eyes"); a quiet end (the slot again, or time running out)
	# gets the quick fly-back.
	var me := _local_me()
	var m = game.monsters.get(monster_id)
	var instant: bool = m == null or not is_instance_valid(m) \
		or (me != null and (int(me.hp) < _start_hp or not me.alive or me.downed or me.carried_by != 0))
	if instant:
		_deactivate()
		return
	_phase = "out"
	_phase_t = 0.0
	var me_xf := _local_eye()
	_path = _path_from(camera.global_position, me_xf.origin)
	Audio.play("brains_hive_out", null, -4.0)


func _deactivate() -> void:
	active = false
	monster_id = -1
	_phase = "in"
	camera.current = false
	_layer.visible = false
	Audio.play("brains_hive_out", null, -4.0)


## A navmesh path from `from` to `to` on the default map, else empty (the caller glides straight).
func _find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var world: World3D = game.get_tree().root.get_world_3d() if game != null and game.get_tree() != null else null
	if world == null:
		return PackedVector3Array()
	var map: RID = world.navigation_map
	if NavigationServer3D.map_get_iteration_id(map) <= 0:
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(map, from, to, true)


## Like _find_path, but always starts at the exact camera position (never snapped to the navmesh),
## so the flight never jumps at takeoff. A single-point "path" means _fly() glides straight.
func _path_from(from: Vector3, to: Vector3) -> PackedVector3Array:
	var p := _find_path(from, to)
	var out := PackedVector3Array([from])
	for v in p:
		if v.distance_to(from) > 0.05:
			out.append(v)
	if out.size() == 1:
		out.append(to)
	return out


func _process(delta: float) -> void:
	if not active or game == null:
		return
	# The Hive gone mid fly-back (a new run clears the monsters the same frame game over ends the
	# view): snap back, as when it dies while you look through it, instead of gliding across the
	# new hospital.
	if _phase == "out" and not game.monsters.has(monster_id):
		_deactivate()
		return
	if _phase == "in" or _phase == "out":
		_fly(delta)
	else:
		_settled(delta)


## Glide the camera along `_path` (or a straight line) over FLIGHT_IN / FLIGHT_OUT seconds,
## looking ahead along the path toward the destination.
func _fly(delta: float) -> void:
	var total := FLIGHT_IN if _phase == "in" else FLIGHT_OUT
	_phase_t = minf(total, _phase_t + delta)
	var e := smoothstep(0.0, 1.0, _phase_t / total)
	var dest_xf: Transform3D
	if _phase == "in":
		var m = game.monsters.get(monster_id)
		dest_xf = _eye_transform(m) if m != null and is_instance_valid(m) else camera.global_transform
	else:
		dest_xf = _local_eye()
	var pos: Vector3
	if _path.size() > 1:
		pos = _along_path(_path, e)
	else:
		var start: Vector3 = _path[0] if _path.size() > 0 else camera.global_position
		pos = start.lerp(dest_xf.origin, e)
	pos.y += sin(e * PI) * 0.3   # a little lift mid-flight, purely cosmetic
	var look_at: Vector3 = dest_xf.origin
	var look_dir := (look_at - pos)
	var yaw := atan2(-look_dir.x, -look_dir.z) if look_dir.length() > 0.01 else 0.0
	var pitch := clampf(asin(clampf(look_dir.normalized().y, -1.0, 1.0)), -1.2, 1.2) if look_dir.length() > 0.01 else 0.0
	camera.global_transform = Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), pos)
	_layer.visible = _phase == "in"
	_mat.set_shader_parameter("amount", 0.0 if _phase == "out" else e)
	_label.text = "HIVE EYES   arriving..." if _phase == "in" else ""
	if _phase_t >= total:
		if _phase == "in":
			_phase = "settled"
			_t = 0.0
		else:
			_deactivate()


## A point `e` (0..1) of the way along a polyline, by arc length.
func _along_path(path: PackedVector3Array, e: float) -> Vector3:
	var total_len := 0.0
	for i in path.size() - 1:
		total_len += path[i].distance_to(path[i + 1])
	if total_len <= 0.001:
		return path[path.size() - 1]
	var target_len := total_len * e
	var acc := 0.0
	for i in path.size() - 1:
		var seg := path[i].distance_to(path[i + 1])
		if acc + seg >= target_len or i == path.size() - 2:
			var t := clampf((target_len - acc) / maxf(seg, 0.001), 0.0, 1.0)
			return path[i].lerp(path[i + 1], t)
		acc += seg
	return path[path.size() - 1]


## Ride the Hive's eyes once the flight has landed (unchanged from sweep 3's version).
func _settled(delta: float) -> void:
	var m = game.monsters.get(monster_id)
	if m == null or not is_instance_valid(m):
		_layer.visible = false
		return
	_t += delta
	_fade = minf(1.0, _fade + delta * 5.0)
	camera.global_transform = _eye_transform(m)
	_layer.visible = true
	_mat.set_shader_parameter("amount", _fade)
	_mat.set_shader_parameter("time_s", _t)
	var left := maxf(0.0, until - float(game.world_time))
	_label.text = "HIVE EYES   %.1f s        R / E / Esc: back to your body" % left


## The settled eye transform for monster `m`, including its lumbering sway and head bob.
func _eye_transform(m: Node) -> Transform3D:
	var eye_h: float = float(m.get("height")) * 0.93 if m.get("height") != null else 1.7
	var yaw: float = (m as Node3D).global_rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var sway := sin(_t * 2.3) * 0.02
	var bob := sin(_t * 4.6) * 0.012
	var eye: Vector3 = (m as Node3D).global_position + Vector3.UP * (eye_h + bob) + fwd * 0.34
	var pitch := -0.1 + bob
	if m.has_method("eye_transform"):
		# Integration: ride the Hive's animated head (Monster.eye_transform, -Z forward), a little in
		# front of the face so its own head never fills the view; keep the horizon level.
		var ex: Transform3D = m.eye_transform()
		var look := -ex.basis.z
		if Vector2(look.x, look.z).length() > 0.05:
			yaw = atan2(-look.x, -look.z)
			pitch = clampf(asin(clampf(look.y, -1.0, 1.0)), -0.5, 0.3) + bob
		eye = ex.origin + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 0.12
	return Transform3D(Basis.from_euler(Vector3(pitch, yaw, sway)), eye)


## Warmup hook: compile the overlay's canvas shader once (a tiny rect, freed shortly after).
static func warm(parent: Node) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	var r := ColorRect.new()
	r.size = Vector2(4, 4)
	r.material = overlay_material()
	layer.add_child(r)
	parent.add_child(layer)
	parent.get_tree().create_timer(0.4).timeout.connect(func():
		if is_instance_valid(layer):
			layer.queue_free())
