extends Node
## Hive Eyes, on the watching player's machine only (brains, sweep 3): a camera riding in a
## Walk-In's eyes and a grainy, sickly, night-sight screen over it. main.gd renders through
## `camera` while `active` (game.brains.camera()). Walk-Ins see in the dark, so the screen lifts the
## shadows a lot; everything is a washed-out yellow-green with grain, scan lines and a slow wobble.
##
## Nothing here decides anything: the brains system says which monster and until when.

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


## Look through monster `id` until world_time `end_at` (or stop with id -1).
func set_target(id: int, end_at: float) -> void:
	if id < 0:
		if active:
			active = false
			monster_id = -1
			camera.current = false
			_layer.visible = false
			Audio.play("brains_hive_out", null, -4.0)
		return
	if not active:
		_t = 0.0
		_fade = 0.0
		Audio.play("brains_hive_in", null, -3.0)
	active = true
	monster_id = id
	until = end_at


func _process(delta: float) -> void:
	if not active or game == null:
		return
	var m = game.monsters.get(monster_id)
	if m == null or not is_instance_valid(m):
		_layer.visible = false
		return
	_t += delta
	_fade = minf(1.0, _fade + delta * 5.0)
	var eye_h: float = float(m.get("height")) * 0.93 if m.get("height") != null else 1.7
	var yaw: float = (m as Node3D).global_rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	# A lumbering sway: the Walk-In's head rolls as it walks.
	var sway := sin(_t * 2.3) * 0.02
	var bob := sin(_t * 4.6) * 0.012
	var eye: Vector3 = (m as Node3D).global_position + Vector3.UP * (eye_h + bob) + fwd * 0.34
	camera.global_transform = Transform3D(Basis.from_euler(Vector3(-0.1 + bob, yaw, sway)), eye)
	_layer.visible = true
	_mat.set_shader_parameter("amount", _fade)
	_mat.set_shader_parameter("time_s", _t)
	var left := maxf(0.0, until - float(game.world_time))
	_label.text = "HIVE EYES   %.1f s        R / E / Esc: back to your body" % left


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
