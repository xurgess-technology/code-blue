extends Node
## SWEEP 4A HOOK (scanner): what scanning looks like, on the scanning player's own machine only.
## While R is held on a monster (Player.scan_progress / scan_target_id) the monster wears a cyan
## hologram overlay (scanlines, a rim, and a bright band sweeping up and down it, faster as the
## scan builds) and a thin beam runs from the player's hand to it. When the scan completes: the
## overlay flashes, a ring rolls out across the floor from its feet, a chime, and the HUD's
## "SCAN COMPLETE" banner (hud.gd show_scan_banner). Holding R at all, target or not, turns the
## flashlight scanner-blue and sweeps a projected scan line up and down straight ahead, so pressing
## R always visibly does something. Purely cosmetic: the host's _tick_scan still
## decides what the database records, and nothing here is replicated.

const MonsterPages := preload("res://scripts/database/monster_pages.gd")

const COLOR := Color(0.36, 0.88, 0.82)
const FLASH_SECONDS := 0.6
const RING_SECONDS := 0.9
const RING_RADIUS := 3.2
## Holding R: the flashlight's colour, how fast it fades in and out, and the sweeping line.
const SCAN_LIGHT := Color(0.35, 0.72, 1.0)
const LIGHT_FADE := 6.0
const SWEEP_DEG := 17.0
const SWEEP_SPEED := 2.4
const LINE_RANGE := 11.0

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.36, 0.88, 0.82);
uniform float band_y = 0.0;
uniform float strength = 1.0;
uniform float flash = 0.0;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float lines = smoothstep(0.55, 1.0, 0.5 + 0.5 * sin(wpos.y * 80.0 - TIME * 7.0));
	float band = 1.0 - smoothstep(0.0, 0.09, abs(wpos.y - band_y));
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	float a = strength * (0.12 * lines + 0.45 * rim + 1.1 * band) + flash;
	ALBEDO = tint * a;
}
"""

var game: Node = null
var _mat: ShaderMaterial
var _beam: MeshInstance3D
var _target: Node3D = null          # the monster wearing the overlay
var _saved := {}                    # GeometryInstance3D -> its own material_overlay
var _last_progress := 0.0
var _last_target := -1
var _flash := 0.0
var _flash_target: Node3D = null
var _rings: Array = []              # [{node, t}]
var _t := 0.0
var _scan_k := 0.0                  # 0 warm flashlight .. 1 scanning blue
var _warm := Color(1.0, 0.86, 0.62)
var _warm_of: Object = null         # the flashlight _warm was read from
var _line: SpotLight3D


func setup(g: Node) -> void:
	game = g
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.006
	cyl.bottom_radius = 0.012
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 1
	_beam.mesh = cyl
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.albedo_color = Color(COLOR, 0.55)
	_beam.material_override = bm
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	_beam.top_level = true
	add_child(_beam)
	# The scan line: a spot light projecting one bright horizontal stripe, swept up and down.
	_line = SpotLight3D.new()
	_line.light_color = SCAN_LIGHT
	_line.light_energy = 0.0
	_line.spot_range = LINE_RANGE
	_line.spot_angle = 26.0
	_line.spot_attenuation = 0.8
	_line.shadow_enabled = true
	_line.light_projector = _line_texture()
	_line.top_level = true
	_line.visible = false
	add_child(_line)


func _process(delta: float) -> void:
	if game == null:
		return
	_t += delta
	var me = game.local_player()
	var mid := -1
	var progress := 0.0
	if me != null and me.alive and bool(me.scan_holding):
		mid = int(me.scan_target_id)
		progress = float(me.scan_progress)
	var monster: Node3D = game.scan_target_node(mid) if mid != -1 else null
	if _flash_target != null and not is_instance_valid(_flash_target):
		_flash_target = null
		_flash = 0.0
	# A scan that just wrapped from nearly done back to the start completed.
	if monster != null and mid == _last_target and _last_progress > 0.8 and progress < 0.2:
		_complete(monster)
	_last_target = mid
	_last_progress = progress

	_set_target(monster if monster != null else (_flash_target if _flash > 0.0 else null))
	if _target != null:
		var h := _height_of(_target)
		var speed := lerpf(1.2, 3.5, progress)
		var base := _target.global_position.y
		_mat.set_shader_parameter("band_y", base + h * (0.5 - 0.5 * cos(_t * speed * PI)))
		_mat.set_shader_parameter("strength", 1.0 if monster != null else 0.0)
		_mat.set_shader_parameter("flash", _flash * 1.4)
	_flash = maxf(0.0, _flash - delta / FLASH_SECONDS)
	if _flash <= 0.0:
		_flash_target = null
	_update_beam(me, monster)
	_tick_rings(delta)
	_update_scan_light(me, delta)


## Holding R: the flashlight goes blue and the scan line sweeps straight ahead, target or not.
func _update_scan_light(me, delta: float) -> void:
	var holding: bool = me != null and me.alive and bool(me.scan_holding) and me.camera != null
	_scan_k = move_toward(_scan_k, 1.0 if holding else 0.0, delta * LIGHT_FADE)
	var flash: SpotLight3D = me.flashlight if me != null else null
	if flash != null and is_instance_valid(flash):
		if _warm_of != flash:
			_warm_of = flash
			_warm = flash.light_color
		flash.light_color = _warm.lerp(SCAN_LIGHT, _scan_k)
	if _scan_k <= 0.001 or me == null or me.camera == null:
		_line.visible = false
		return
	_line.visible = true
	_line.light_energy = 9.0 * _scan_k
	var cam: Camera3D = me.camera
	var pitch := deg_to_rad(SWEEP_DEG) * sin(_t * SWEEP_SPEED)
	var basis := cam.global_transform.basis.orthonormalized() * Basis(Vector3.RIGHT, pitch)
	var origin: Vector3 = flash.global_position if flash != null and is_instance_valid(flash) else cam.global_position
	_line.global_transform = Transform3D(basis, origin)


## A thin bright horizontal stripe across the middle, soft edges, a faint glow around it.
static func _line_texture() -> ImageTexture:
	var w := 128
	var h := 64
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var d := absf(float(y) - (h - 1) * 0.5)
		var core := clampf(1.0 - d / 1.6, 0.0, 1.0)
		var glow := exp(-d * d / 60.0) * 0.18
		var v := clampf(core + glow, 0.0, 1.0)
		for x in w:
			var edge := clampf(minf(float(x), float(w - 1 - x)) / 10.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(v * edge, v * edge, v * edge, 1.0))
	return ImageTexture.create_from_image(img)


func _complete(monster: Node3D) -> void:
	_flash = 1.0
	_flash_target = monster
	_spawn_ring(monster.global_position)
	if DisplayServer.get_name() != "headless":
		Audio.play("beep", null, -2.0)
		Audio.play("deliver", null, -6.0)
	var name := String(MonsterPages.entry(String(monster.get("kind"))).get("name", "Unknown specimen"))
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("show_scan_banner"):
		hud.show_scan_banner(name)


# ---- the overlay ----

func _set_target(m) -> void:
	if _target != null and not is_instance_valid(_target):
		_saved.clear()
		_target = null
	if m == _target:
		return
	_restore()
	_target = m
	if m == null:
		return
	var model: Node = m.get("model")
	for gi in (model if model != null else m).find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		_saved[g] = g.material_overlay
		g.material_overlay = _mat


func _restore() -> void:
	for g in _saved.keys():
		if is_instance_valid(g):
			(g as GeometryInstance3D).material_overlay = _saved[g]
	_saved.clear()
	_target = null


func _height_of(m: Node3D) -> float:
	var h = m.get("height")
	return float(h) if h != null else 1.9


# ---- the beam ----

func _update_beam(me, monster: Node3D) -> void:
	if me == null or monster == null or me.camera == null:
		_beam.visible = false
		return
	var cam: Camera3D = me.camera
	var from: Vector3 = cam.global_transform * Vector3(0.22, -0.24, -0.45)
	var to: Vector3 = monster.global_position + Vector3.UP * _height_of(monster) * 0.6
	var d := to - from
	var len := d.length()
	if len < 0.05:
		_beam.visible = false
		return
	_beam.visible = true
	# The cylinder runs along +Y: point it from the hand to the monster, flickering a little.
	var y := d / len
	var x := y.cross(Vector3.UP)
	if x.length() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y)
	var wobble := 1.0 + 0.35 * sin(_t * 40.0)
	_beam.global_transform = Transform3D(Basis(x * wobble, y * len, z * wobble), from + d * 0.5)


# ---- the ring ----

func _spawn_ring(at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.94
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 4
	mi.mesh = torus
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(COLOR, 0.9)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)
	mi.global_position = at + Vector3.UP * 0.04
	_rings.append({"node": mi, "t": 0.0, "mat": m})


func _tick_rings(delta: float) -> void:
	for r in _rings.duplicate():
		r.t += delta
		var k := clampf(float(r.t) / RING_SECONDS, 0.0, 1.0)
		var node: MeshInstance3D = r.node
		var s := lerpf(0.2, RING_RADIUS, 1.0 - pow(1.0 - k, 3.0))
		node.scale = Vector3(s, 1.0, s)
		(r.mat as StandardMaterial3D).albedo_color = Color(COLOR, 0.9 * (1.0 - k))
		if k >= 1.0:
			node.queue_free()
			_rings.erase(r)


func _exit_tree() -> void:
	_restore()
