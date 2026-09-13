extends Node
## What downed players look like, on every machine: the blood trail a downed (or carried) player
## leaves on the floor, and for the local downed player a slow red vignette with a small bleed-out
## clock that only they see. Child "DownedView" of Game; reads replicated Player fields only.

const MAX_DECALS := 72
const CRAWL_STEP_M := 0.5
const CARRY_STEP_M := 1.1
const IDLE_DROP_S := 7.0

const VIGNETTE := """
shader_type canvas_item;
uniform float amount = 0.0;
uniform float pulse = 0.0;
void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d * vec2(1.25, 1.0));
	float edge = smoothstep(0.32, 0.78, r);
	float a = edge * (0.35 + 0.65 * amount) * (0.8 + 0.2 * pulse);
	COLOR = vec4(0.28 * (0.6 + 0.4 * pulse), 0.0, 0.01, clamp(a, 0.0, 0.92));
}
"""

const Kit := preload("res://scripts/patients/patient_kit.gd")

var game: Node = null
var _decals: Array = []
var _trail := {}   # peer id -> {pos: Vector3, t: float}
var _layer: CanvasLayer
var _veil: ColorRect
var _veil_mat: ShaderMaterial
var _clock: Label
var _state: Label
var _t := 0.0
static var _shader: Shader


func setup(g: Node) -> void:
	game = g
	_layer = CanvasLayer.new()
	_layer.name = "DownedOverlay"
	_layer.layer = 2
	add_child(_layer)
	_veil = ColorRect.new()
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		_shader.code = VIGNETTE
	_veil_mat = ShaderMaterial.new()
	_veil_mat.shader = _shader
	_veil.material = _veil_mat
	_layer.add_child(_veil)
	_clock = _label(13, Color(0.85, 0.3, 0.28, 0.8))
	_clock.offset_top = -58
	_state = _label(12, Color(0.8, 0.78, 0.75, 0.7))
	_state.offset_top = -38
	_layer.visible = false


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.anchor_left = 0.0
	l.anchor_right = 1.0
	l.anchor_top = 1.0
	l.anchor_bottom = 1.0
	l.offset_bottom = 0
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(l)
	return l


func reset() -> void:
	for d in _decals:
		if is_instance_valid(d):
			d.queue_free()
	_decals.clear()
	_trail.clear()


func _process(delta: float) -> void:
	_t += delta
	if game == null or game.phase == game.Phase.MENU:
		_layer.visible = false
		return
	_trails(delta)
	_overlay()


func _trails(delta: float) -> void:
	for p in game.players.values():
		if not p.alive or not p.downed or p.on_table:
			_trail.erase(p.peer_id)
			continue
		var at: Vector3 = p.global_position
		var step := CRAWL_STEP_M
		if p.carried_by != 0:
			var c = game.players.get(p.carried_by)
			if c == null:
				continue
			at = c.global_position
			step = CARRY_STEP_M
		var tr: Dictionary = _trail.get(p.peer_id, {})
		if tr.is_empty():
			_trail[p.peer_id] = {"pos": at, "t": 0.0}
			_drop(at, 0.5)
			continue
		tr.t = float(tr.t) + delta
		var moved := Vector2(at.x - tr.pos.x, at.z - tr.pos.z).length()
		if moved >= step or (float(tr.t) >= IDLE_DROP_S and moved < 0.3):
			tr.pos = at
			tr.t = 0.0
			_drop(at, 0.28 if moved >= step else 0.42)


func _drop(at: Vector3, size: float) -> void:
	if game.level == null or not is_instance_valid(game.level) or not game.is_inside_tree():
		return
	var from := at + Vector3.UP * 0.6
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0)
	q.collision_mask = C.L_WORLD
	var hit: Dictionary = game.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	var yaw := randf() * TAU
	var s := size * randf_range(0.8, 1.2)
	var d := Kit.decal(game.level, Kit.blood_tex(), Vector3(s, 0.2, s * randf_range(0.6, 1.0)), Transform3D(Basis(Vector3.UP, yaw), hit.position))
	d.modulate = Color(0.8, 0.8, 0.8, 0.85)
	d.name = "BloodTrail"
	_decals.append(d)
	while _decals.size() > MAX_DECALS:
		var old = _decals.pop_front()
		if is_instance_valid(old):
			old.queue_free()


func _overlay() -> void:
	var me = game.local_player()
	var show: bool = me != null and me.alive and me.downed
	_layer.visible = show
	if not show:
		return
	var frac := clampf(float(me.bleed) / float(game.BLEED_SECONDS), 0.0, 1.0)
	# The heart slows as the blood runs out.
	var bpm := lerpf(38.0, 110.0, frac)
	var beat := pow(maxf(0.0, sin(_t * PI * bpm / 60.0)), 6.0)
	_veil_mat.set_shader_parameter("amount", 1.0 - frac)
	_veil_mat.set_shader_parameter("pulse", beat)
	var secs := int(ceil(float(me.bleed)))
	_clock.text = "bleeding out  %d:%02d" % [secs / 60, secs % 60]
	var line := "Crawl, or call for help. Someone has to carry you to the OR."
	if me.on_table:
		var op = game.players.get(game.player_surgery.operator_peer())
		line = "%s is stitching you up." % op.player_name if op != null else "On the table. Someone needs a suture kit on the shelf."
	elif me.carried_by != 0:
		var c = game.players.get(me.carried_by)
		line = "%s is carrying you." % (c.player_name if c != null else "Someone")
	_state.text = line
