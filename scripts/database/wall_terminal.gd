extends Node3D
## The break room's database terminal: a pull-down projector screen on the wall and a projector hung
## from the ceiling across the room, its light cone running to the screen (terminal redesign, chunk 1).
## What it shows is a 2D Control drawn into a SubViewport and projected onto the screen (blacks come
## out as the grey of the lit fabric, the middle a little brighter, a faint flicker), and players drive
## it with the scan laser (scan_fx.gd): the dot on the screen is a mouse cursor, a left click while
## scanning clicks under it.
##
##   make()                           the screen, origin on the floor at the spot, glass facing -Z
##   pixel_at(world_point) -> Vector2 where on the screen texture a world point on the glass lands
##                                    (Vector2(-1, -1) off the glass)
##   point(px)                        a cursor over the screen (hover)
##   click(px)                        a left click there
##   clear_pointer()                  nobody's cursor is on it
##   set_on(on)                       the projector on or off: off, no picture, no light, no clicks
##   projector_position() -> Vector3  the projector hung from the ceiling (its E aim target, game.gd)
##
## The picture is a slide, not a computer screen (projector redesign, chunk 1: the look): a warm lamp,
## ivory film in a black mount, near-black type, dust and a fiber in the gate, and a clack as the
## carousel indexes to the next slide. wall_terminal_ui.gd draws the slide and says when one changes.

const OrScreen := preload("res://scripts/orscreen/or_screen.gd")
const UIScript := preload("res://scripts/database/wall_terminal_ui.gd")

## The glass, in metres, and the texture behind it.
const SIZE := Vector2(4.4, 2.475)
const TEX := Vector2i(1280, 720)
## Height of the picture's centre off the floor, and how far it sits in front of the origin (the
## origin is the reserved lectern spot, 0.32 m out from the wall).
const CENTRE_Y := 1.6
const WALL_Z := 0.26
## Sideways from the spot.
const SHIFT_X := 0.0
## The projector: how far out into the room it hangs, and its lens's height off the floor.
const THROW := 5.0
const PROJECTOR_Y := 2.62

const PROJECTION_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;
uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
uniform vec3 fabric : source_color = vec3(0.045, 0.045, 0.043);
uniform float gain = 1.35;
// 0 = lamp cold, 1 = fully up: the bulb comes on over a moment rather than snapping.
uniform float warm = 1.0;
// A slide projector's lamp: warm, a hot spot in the middle, and the slow unsteadiness of a bulb and
// a fan rather than a scanning phosphor screen.
void fragment() {
	vec3 c = texture(screen_tex, UV).rgb;
	vec2 d = UV - 0.5;
	float hot = 1.0 - 0.75 * dot(d, d);
	float flick = 0.985 + 0.012 * sin(TIME * 7.7) + 0.006 * sin(TIME * 23.1);
	vec3 lamp = vec3(1.0, 0.955, 0.88);
	// A slide has real blacks: pull the toe down so type stays type instead of grey.
	c = pow(c, vec3(1.35));
	ALBEDO = (fabric + c * gain * lamp) * hot * flick * warm;
}
"""

var viewport: SubViewport
var ui: Control
var glass: MeshInstance3D
var on := true
var _pointer_seen := false
var _projector: MeshInstance3D
var _lens: MeshInstance3D
var _lens_on: Material
var _lens_off: StandardMaterial3D
var _beam: MeshInstance3D
var _glow: OmniLight3D
## The slide tray on top of the projector: it turns one slot each time a slide changes.
var _carousel: Node3D
var _carousel_to := 0.0
## The cooling fan: a loop that runs while the lamp is on.
var _fan: AudioStreamPlayer3D
## Seconds into the lamp warming up, < 0 when it is simply on or off.
var _warm_t := -1.0
var _screen_mat: ShaderMaterial

## Slots round the tray, and how long the bulb takes to come up.
const SLOTS := 40
const WARM_SECONDS := 0.9


static func make() -> Node3D:
	var n: Node3D = (load("res://scripts/database/wall_terminal.gd") as GDScript).new()
	n.name = "WallTerminal"
	n._build()
	return n


func _build() -> void:
	viewport = SubViewport.new()
	viewport.name = "Viewport"
	viewport.size = TEX
	viewport.disable_3d = false   # the entry pages turn 3D models (their own worlds)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = false
	add_child(viewport)
	ui = UIScript.new()
	ui.name = "UI"
	ui.size = Vector2(TEX)
	ui.advanced.connect(_on_advanced)
	ui.jammed.connect(_on_jammed)
	viewport.add_child(ui)

	# Everything on the wall hangs off a front pivot turned to face the room (-Z): a QuadMesh shows its
	# texture the right way round from its own +Z side, so the glass itself is never turned.
	var front := Node3D.new()
	front.name = "Front"
	front.rotation.y = PI
	front.position = Vector3(SHIFT_X, CENTRE_Y, WALL_Z)
	add_child(front)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.085, 0.09)
	dark.roughness = 0.55
	dark.metallic = 0.3
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.72, 0.72, 0.7)
	cloth.roughness = 0.95

	# The screen: matte fabric a little bigger than the picture, a black masking band across its top,
	# the roller case under the ceiling it pulls down from, and the weighted bar along its bottom.
	var top := 3.0 - 0.06 - CENTRE_Y   # the case, just under the ceiling (front-local y)
	var fabric := _box(front, Vector3(SIZE.x + 0.2, top - (-SIZE.y * 0.5 - 0.1), 0.01),
			Vector3(0, (top + (-SIZE.y * 0.5 - 0.1)) * 0.5, 0.0), cloth)
	fabric.name = "Fabric"
	_box(front, Vector3(SIZE.x + 0.2, top - SIZE.y * 0.5 - 0.02, 0.012),
			Vector3(0, (top + SIZE.y * 0.5 + 0.02) * 0.5, 0.004), dark)
	var case := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.07
	cyl.bottom_radius = 0.07
	cyl.height = SIZE.x + 0.5
	cyl.radial_segments = 12
	case.mesh = cyl
	case.material_override = dark
	case.rotation.z = PI * 0.5
	case.position = Vector3(0, top, -0.02)
	front.add_child(case)
	for sx in [-1.0, 1.0]:
		_box(front, Vector3(0.05, 0.16, 0.16), Vector3(sx * (SIZE.x * 0.5 + 0.28), top, -0.02), dark)
	var bar := MeshInstance3D.new()
	var bcyl := CylinderMesh.new()
	bcyl.top_radius = 0.018
	bcyl.bottom_radius = 0.018
	bcyl.height = SIZE.x + 0.24
	bcyl.radial_segments = 8
	bar.mesh = bcyl
	bar.material_override = dark
	bar.rotation.z = PI * 0.5
	bar.position = Vector3(0, -SIZE.y * 0.5 - 0.11, 0.01)
	front.add_child(bar)

	# The picture on it.
	glass = MeshInstance3D.new()
	glass.name = "Screen"
	var qm := QuadMesh.new()
	qm.size = SIZE
	glass.mesh = qm
	var sh := Shader.new()
	sh.code = PROJECTION_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("screen_tex", viewport.get_texture())
	glass.material_override = mat
	_screen_mat = mat
	glass.position = Vector3(0, 0, 0.012)
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	front.add_child(glass)

	# The projector, hung from the ceiling on a rod across the room, lens toward the screen.
	var py := PROJECTOR_Y - CENTRE_Y
	var body := _box(front, Vector3(0.42, 0.15, 0.36), Vector3(0, py, THROW + 0.18), dark)
	body.name = "Projector"
	_projector = body
	_box(front, Vector3(0.04, 3.0 - PROJECTOR_Y - 0.07, 0.04), Vector3(0, (py + 0.07 + (3.0 - CENTRE_Y)) * 0.5, THROW + 0.18), dark)
	_box(front, Vector3(0.2, 0.02, 0.2), Vector3(0, 3.0 - CENTRE_Y - 0.01, THROW + 0.18), dark)
	_carousel = Node3D.new()
	_carousel.name = "Carousel"
	_carousel.position = Vector3(-0.02, py + 0.075 + 0.03, THROW + 0.2)
	front.add_child(_carousel)
	var tray_mat := StandardMaterial3D.new()
	tray_mat.albedo_color = Color(0.16, 0.15, 0.14)
	tray_mat.roughness = 0.6
	var tray := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.2
	tm.bottom_radius = 0.2
	tm.height = 0.05
	tm.radial_segments = 32
	tray.mesh = tm
	tray.material_override = tray_mat
	_carousel.add_child(tray)
	var slide_mat := StandardMaterial3D.new()
	slide_mat.albedo_color = Color(0.82, 0.8, 0.74)
	slide_mat.roughness = 0.9
	var slot_mesh := BoxMesh.new()
	slot_mesh.size = Vector3(0.004, 0.05, 0.05)
	for i in SLOTS:
		var a := TAU * float(i) / float(SLOTS)
		var sl := MeshInstance3D.new()
		sl.mesh = slot_mesh
		sl.material_override = slide_mat
		sl.position = Vector3(cos(a) * 0.16, 0.035, sin(a) * 0.16)
		sl.rotation.y = -a
		_carousel.add_child(sl)
	var hub := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = 0.045
	hm.bottom_radius = 0.045
	hm.height = 0.07
	hub.mesh = hm
	hub.material_override = dark
	hub.position.y = 0.02
	_carousel.add_child(hub)

	var lens := MeshInstance3D.new()
	var lm := CylinderMesh.new()
	lm.top_radius = 0.045
	lm.bottom_radius = 0.05
	lm.height = 0.05
	lm.radial_segments = 12
	lens.mesh = lm
	var lmat := StandardMaterial3D.new()
	lmat.albedo_color = Color(1.0, 0.97, 0.9)
	lmat.emission_enabled = true
	lmat.emission = Color(1.0, 0.93, 0.78)
	lmat.emission_energy_multiplier = 3.0
	lens.material_override = lmat
	_lens = lens
	_lens_on = lmat
	_lens_off = StandardMaterial3D.new()
	_lens_off.albedo_color = Color(0.05, 0.06, 0.06)
	_lens_off.roughness = 0.2
	_lens_off.metallic = 0.4
	lens.rotation.x = PI * 0.5
	lens.position = Vector3(0.1, py, THROW - 0.02)
	front.add_child(lens)
	# Its light: a faint cone from the lens to the picture's corners, brightest at the lens.
	var cone := MeshInstance3D.new()
	cone.name = "Beam"
	cone.mesh = _beam_mesh(Vector3(0.1, py, THROW - 0.04), SIZE)
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	cm.cull_mode = BaseMaterial3D.CULL_DISABLED
	cm.vertex_color_use_as_albedo = true
	cm.albedo_color = Color(1.0, 0.94, 0.8, 1.0)
	cone.material_override = cm
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	front.add_child(cone)
	_beam = cone

	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.light_color = Color(1.0, 0.92, 0.78)
	glow.light_energy = 1.1
	glow.omni_range = 6.0
	glow.omni_attenuation = 1.4
	glow.light_specular = 0.2
	glow.position = Vector3(0, 0, 0.7)
	front.add_child(glow)
	_glow = glow

	_start_fan()

	set_meta("collider_size", Vector3(SIZE.x + 0.14, SIZE.y + 0.14, 0.12))
	set_meta("collider_y", CENTRE_Y)
	set_meta("collider_offset", Vector3(SHIFT_X, 0.0, WALL_Z))
	add_to_group("wall_terminal")


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


## The projector's light: four faces from the lens to the picture's corners, bright at the lens and
## fading out toward the screen (vertex colours).
static func _beam_mesh(lens: Vector3, size: Vector2) -> ArrayMesh:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var corners := [Vector3(-hx, -hy, 0.02), Vector3(hx, -hy, 0.02), Vector3(hx, hy, 0.02), Vector3(-hx, hy, 0.02)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var near := Color(0.095, 0.085, 0.065, 1.0)
	var far := Color(0.018, 0.016, 0.012, 1.0)
	for i in 4:
		st.set_color(near)
		st.add_vertex(lens)
		st.set_color(far)
		st.add_vertex(corners[i])
		st.set_color(far)
		st.add_vertex(corners[(i + 1) % 4])
	return st.commit()


## The fan: a seamless loop off the projector body (skipped headless, and if the file is missing).
func _start_fan() -> void:
	const CUE := "res://audio/sfx/db_fan.wav"
	if DisplayServer.get_name() == "headless" or not ResourceLoader.exists(CUE):
		return
	var res = load(CUE)
	if not (res is AudioStreamWAV):
		return
	var stream := (res as AudioStreamWAV).duplicate() as AudioStreamWAV
	var frames := stream.data.size() / ((2 if stream.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if stream.stereo else 1))
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = frames
	_fan = AudioStreamPlayer3D.new()
	_fan.name = "Fan"
	_fan.stream = stream
	_fan.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	_fan.volume_db = -16.0
	_fan.unit_size = 1.4
	_fan.max_distance = 9.0
	_projector.add_child(_fan)
	_fan.autoplay = on


func _process(delta: float) -> void:
	# The tray turning to its next slot: quick, and done before the slide lands.
	if _carousel != null and not is_equal_approx(_carousel.rotation.y, _carousel_to):
		_carousel.rotation.y = move_toward(_carousel.rotation.y, _carousel_to, delta * TAU / float(SLOTS) * 14.0)
	# The bulb catching: it stutters, then comes up.
	if _warm_t >= 0.0 and _screen_mat != null:
		_warm_t += delta
		var k := clampf(_warm_t / WARM_SECONDS, 0.0, 1.0)
		var stutter := 0.35 if _warm_t > 0.12 and _warm_t < 0.2 else 1.0
		_screen_mat.set_shader_parameter("warm", k * k * stutter)
		_glow.light_energy = 1.1 * k * stutter
		if k >= 1.0:
			_warm_t = -1.0
			_screen_mat.set_shader_parameter("warm", 1.0)
			_glow.light_energy = 1.1


## The projector on or off. Off: the bare screen, no light cone, a dark lens, the viewport idle and
## nothing to click. On: the switch and the bulb catching (db_bulb), the picture warming up, the fan.
func set_on(value: bool) -> void:
	if value == on:
		return
	on = value
	if _fan != null:
		if value:
			_fan.play()
		else:
			_fan.stop()
	if value and is_inside_tree():
		Audio.play("db_bulb", _projector, -6.0, 0.02)
		_warm_t = 0.0
		if _screen_mat != null:
			_screen_mat.set_shader_parameter("warm", 0.0)
	glass.visible = value
	_beam.visible = value
	_glow.visible = value
	_lens.material_override = _lens_on if value else _lens_off
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
	if not value:
		clear_pointer()


## A slide change: the carousel indexes round up at the projector, not down at the screen.
func _on_advanced() -> void:
	_carousel_to += TAU / float(SLOTS)
	if on and _projector != null and is_inside_tree():
		Audio.play("db_clack", _projector, -4.0, 0.04)


## A slide caught in the gate (wall_terminal_ui.gd): the carousel grinds instead of clacking.
func _on_jammed() -> void:
	if on and _projector != null and is_inside_tree():
		Audio.play("db_jam", _projector, -5.0, 0.03)


func projector_position() -> Vector3:
	return _projector.global_position


## Where a world point on the glass falls on the screen texture, or (-1, -1) when it is off it (or the
## projector is off).
func pixel_at(world_point: Vector3) -> Vector2:
	if not on:
		return Vector2(-1, -1)
	var local := glass.global_transform.affine_inverse() * world_point
	# The quad is SIZE in its own XY, its texture's left edge at local -X seen from the front.
	var u := local.x / SIZE.x + 0.5
	var v := 0.5 - local.y / SIZE.y
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0 or absf(local.z) > 0.2:
		return Vector2(-1, -1)
	return Vector2(u * TEX.x, v * TEX.y)


func point(px: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = px
	ev.global_position = px
	viewport.push_input(ev)
	ui.set_cursor(px, true)
	_pointer_seen = true


func click(px: Vector2) -> void:
	point(px)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = px
		ev.global_position = px
		viewport.push_input(ev)
	ui.pulse(px)


func clear_pointer() -> void:
	if not _pointer_seen:
		return
	_pointer_seen = false
	ui.set_cursor(Vector2.ZERO, false)
	# Move the (virtual) mouse off every card so nothing stays lit.
	var ev := InputEventMouseMotion.new()
	ev.position = Vector2(-100, -100)
	ev.global_position = ev.position
	viewport.push_input(ev)
