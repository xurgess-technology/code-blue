extends Node3D
## Look-development rig. Standalone on purpose.
##
##   godot --path . tools/lookdev.tscn
##   godot --path . tools/lookdev.tscn -- --shots     # capture PNGs and quit
##
## Builds a hand-made ~26 m corridor out of primitive boxes and applies
## Look.make_environment(), Look.make_post_layer(), CameraFX and LightFlicker.
## It deliberately depends on nothing except scripts/look.gd, scripts/camera_fx.gd,
## scripts/light_flicker.gd, scripts/consts.gd and shaders/post.gdshader, so it
## keeps working while the rest of the project churns.
##
## KEYS
##   1 2 3      quality preset low / medium / high
##   F          flashlight
##   V          volumetric fog          G   film grain
##   C          chromatic aberration    B   barrel distortion
##   K          scanlines (CRT)         N   vignette
##   J          colour grade (adjustment)   M  glow
##   ,  .       SSAO / SSIL
##   P          whole post layer on/off
##   X          damage flash (hold-toggle)  Z  danger    H  heartbeat pulse
##   O          fade to / from black
##   SPACE      camera shake            R   reset camera feel
##   Q / E      lean left / right       L   toggle breathing
##   TAB        print current settings
##   RMB-drag   look    WASD  fly    SHIFT  fast    ENTER  auto-fly on/off

const ShotDir := "res://tools/lookdev_shots"
## The corridor runs toward +Z; a Camera3D looks down -Z. This is the rig's
## resting yaw, so `yaw == 0` everywhere below means "down the hall".
const FORWARD_YAW := PI

var env_node: WorldEnvironment
var post_layer: CanvasLayer
var fx: Look.PostFX
var cam_fx: CameraFX
var camera: Camera3D
var flashlight: SpotLight3D
var rig: Node3D

var quality := Look.QUALITY_HIGH
var auto_fly := true
var fly_t := 0.0
var mouse_look := false
var yaw := 0.0
var pitch := 0.0
var breathing_on := false
var danger_on := false
var pulse_on := false
var damage_hold := false
var blackout_on := false

var fixtures: Array[LightFlicker] = []
var _shot_mode := false


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _ready() -> void:
	_shot_mode = "--shots" in OS.get_cmdline_user_args() or "--shots" in OS.get_cmdline_args()

	env_node = Look.make_environment()
	add_child(env_node)

	post_layer = Look.make_post_layer()
	add_child(post_layer)
	fx = Look.get_post_fx(self)

	_build_corridor()
	_build_rig()

	Look.apply_quality(self, quality)

	if _shot_mode:
		auto_fly = false
		_run_shots()
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_print_settings()


# --- materials -------------------------------------------------------------

func _mat(albedo: Color, rough := 0.85, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	# Chunky low-poly look: no specular sparkle, hard shading.
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	return m


func _emissive(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var m := _mat(albedo, 0.4)
	m.emission_enabled = true
	m.emission = emission
	m.emission_energy_multiplier = energy
	return m


func _box(parent: Node3D, nm: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


# --- geometry --------------------------------------------------------------

func _build_corridor() -> void:
	var world := Node3D.new()
	world.name = "Corridor"
	add_child(world)

	var W := C.TILE * 2.0      # 3.0 m corridor, two tiles
	var H := C.WALL_H          # 3.0 m
	var L := 28.0
	var hw := W * 0.5

	var floor_mat := _mat(Color(0.20, 0.26, 0.24), 0.72)
	var wall_lo := _mat(Color(0.30, 0.40, 0.34), 0.88)   # institutional green dado
	var wall_hi := _mat(Color(0.62, 0.66, 0.60), 0.92)   # dirty off-white above
	var ceil_mat := _mat(Color(0.42, 0.46, 0.44), 0.95)
	var trim_mat := _mat(Color(0.10, 0.13, 0.12), 0.6)

	_box(world, "Floor", Vector3(W, 0.2, L), Vector3(0, -0.1, L * 0.5 - 1.0), floor_mat)
	_box(world, "Ceiling", Vector3(W, 0.2, L), Vector3(0, H + 0.1, L * 0.5 - 1.0), ceil_mat)

	# Dado rail split at 1.1 m: the two-tone wall is most of the "hospital".
	var dado := 1.1
	# Right wall (+X) with a doorway at z 5.4..7.0
	_wall_run(world, "R", hw, dado, H, -1.0, 5.4, wall_lo, wall_hi, trim_mat)
	_wall_run(world, "R2", hw, dado, H, 7.0, 27.0, wall_lo, wall_hi, trim_mat)
	# Left wall (-X) with a doorway at z 12.0..13.6
	_wall_run(world, "L", -hw, dado, H, -1.0, 12.0, wall_lo, wall_hi, trim_mat)
	_wall_run(world, "L2", -hw, dado, H, 13.6, 27.0, wall_lo, wall_hi, trim_mat)

	# Far end wall, deliberately out past the volumetric fog range so the
	# corridor reads as fading out rather than ending.
	_box(world, "EndWall", Vector3(W + 0.4, H, 0.2), Vector3(0, H * 0.5, 27.0), wall_hi)
	_box(world, "BackWall", Vector3(W + 0.4, H, 0.2), Vector3(0, H * 0.5, -1.0), wall_hi)

	# Door frames, so the gaps read as doorways and not as missing geometry.
	_door_frame(world, Vector3(hw, 0, 6.2), true, trim_mat)
	_door_frame(world, Vector3(-hw, 0, 12.8), false, trim_mat)

	# Side rooms behind the doorways: dark volumes so the openings have depth.
	_side_room(world, "RoomR", Vector3(hw, 0, 6.2), 1.0, floor_mat, wall_hi, ceil_mat)
	_side_room(world, "RoomL", Vector3(-hw, 0, 12.8), -1.0, floor_mat, wall_hi, ceil_mat)

	# --- ceiling fixtures --------------------------------------------------
	# One of each mode, plus a second flicker far down the hall so there is
	# always something moving in the distance.
	_fixture(world, Vector3(0, H, 3.0), LightFlicker.MODE_STEADY, 1101)
	_fixture(world, Vector3(0, H, 9.0), LightFlicker.MODE_FLICKER, 2202)
	_fixture(world, Vector3(0, H, 15.0), LightFlicker.MODE_DEAD, 3303)
	_fixture(world, Vector3(0, H, 21.0), LightFlicker.MODE_FLICKER, 4404)

	# --- emissive monitor --------------------------------------------------
	var mon_body := _mat(Color(0.07, 0.08, 0.09), 0.5, 0.2)
	_box(world, "MonitorBody", Vector3(0.12, 0.66, 0.92), Vector3(hw - 0.07, 1.55, 11.0), mon_body)
	# Sickly clinical green, hot enough to punch through glow_hdr_threshold.
	var screen := _emissive(Color(0.03, 0.06, 0.05), Color(0.18, 1.0, 0.55), 3.2)
	_box(world, "MonitorScreen", Vector3(0.03, 0.50, 0.76), Vector3(hw - 0.14, 1.55, 11.0), screen)
	# A small omni so the monitor actually lights the wall next to it.
	var mo := OmniLight3D.new()
	mo.name = "MonitorGlow"
	mo.position = Vector3(hw - 0.45, 1.55, 11.0)
	mo.light_color = Color(0.35, 1.0, 0.6)
	mo.light_energy = 1.0
	mo.omni_range = 3.2
	mo.shadow_enabled = false
	mo.light_volumetric_fog_energy = 2.0
	world.add_child(mo)

	# An exit sign at the far end: a second colour in the palette, and it gives
	# the eye something to walk toward down the fog.
	var exit_mat := _emissive(Color(0.1, 0.02, 0.02), Color(1.0, 0.12, 0.06), 2.6)
	_box(world, "ExitSign", Vector3(0.55, 0.22, 0.06), Vector3(0, 2.45, 26.85), exit_mat)

	# --- clutter, so SSAO and the flashlight have something to bite on ------
	var crate := _mat(Color(0.34, 0.30, 0.22), 0.9)
	var steel := _mat(Color(0.50, 0.54, 0.55), 0.35, 0.8)
	_box(world, "Crate1", Vector3(0.7, 0.7, 0.7), Vector3(hw - 0.45, 0.35, 17.4), crate)
	_box(world, "Crate2", Vector3(0.7, 0.7, 0.7), Vector3(hw - 0.45, 1.05, 17.4), crate)
	_box(world, "Crate3", Vector3(0.62, 0.62, 0.62), Vector3(hw - 0.55, 0.31, 18.3), crate)
	# A gurney: three boxes is enough to read as one.
	_box(world, "GurneyTop", Vector3(0.72, 0.10, 1.9), Vector3(-hw + 0.62, 0.80, 7.8), steel)
	_box(world, "GurneyLegA", Vector3(0.08, 0.75, 0.08), Vector3(-hw + 0.35, 0.38, 7.0), steel)
	_box(world, "GurneyLegB", Vector3(0.08, 0.75, 0.08), Vector3(-hw + 0.89, 0.38, 8.6), steel)
	# A bloody sheet on it: the one saturated red in the frame.
	_box(world, "Sheet", Vector3(0.74, 0.06, 1.5), Vector3(-hw + 0.62, 0.88, 7.8), _mat(Color(0.55, 0.09, 0.10), 0.95))

	# --- capsule "character" for scale -------------------------------------
	var cap := MeshInstance3D.new()
	cap.name = "ScaleCharacter"
	var cm := CapsuleMesh.new()
	cm.radius = C.PLAYER_RADIUS
	cm.height = C.PLAYER_HEIGHT
	cm.radial_segments = 10
	cm.rings = 4
	cap.mesh = cm
	cap.position = Vector3(0.55, C.PLAYER_HEIGHT * 0.5, 13.2)
	cap.material_override = _mat(C.PLAYER_COLORS[0], 0.8)
	world.add_child(cap)
	# A head, so the silhouette reads as a person and not a pill.
	_box(world, "ScaleHead", Vector3(0.34, 0.34, 0.30),
		Vector3(0.55, C.PLAYER_HEIGHT - 0.05, 13.2), _mat(Color(0.72, 0.62, 0.54), 0.9))


func _wall_run(p: Node3D, nm: String, x: float, dado: float, h: float,
		z0: float, z1: float, lo: Material, hi: Material, trim: Material) -> void:
	var ln := z1 - z0
	if ln <= 0.01:
		return
	var cz := (z0 + z1) * 0.5
	var sx := signf(x)
	_box(p, nm + "_lo", Vector3(0.2, dado, ln), Vector3(x + 0.1 * sx, dado * 0.5, cz), lo)
	_box(p, nm + "_hi", Vector3(0.2, h - dado, ln), Vector3(x + 0.1 * sx, dado + (h - dado) * 0.5, cz), hi)
	_box(p, nm + "_rail", Vector3(0.26, 0.06, ln), Vector3(x + 0.07 * sx, dado, cz), trim)


func _door_frame(p: Node3D, at: Vector3, right: bool, mat: Material) -> void:
	var sx := 1.0 if right else -1.0
	var top := 2.1
	# Header above the opening.
	_box(p, "DoorHead_%.0f" % at.z, Vector3(0.24, C.WALL_H - top, 1.7),
		Vector3(at.x + 0.1 * sx, top + (C.WALL_H - top) * 0.5, at.z), mat)
	# Jambs.
	_box(p, "DoorJambA_%.0f" % at.z, Vector3(0.24, top, 0.12),
		Vector3(at.x + 0.1 * sx, top * 0.5, at.z - 0.85), mat)
	_box(p, "DoorJambB_%.0f" % at.z, Vector3(0.24, top, 0.12),
		Vector3(at.x + 0.1 * sx, top * 0.5, at.z + 0.85), mat)


func _side_room(p: Node3D, nm: String, door: Vector3, sx: float,
		fl: Material, wl: Material, cl: Material) -> void:
	var d := 4.0          # depth away from the corridor
	var w := 4.2          # along Z
	var cx := door.x + sx * (d * 0.5 + 0.2)
	var cz := door.z
	var h := C.WALL_H
	var r := Node3D.new()
	r.name = nm
	p.add_child(r)
	_box(r, "f", Vector3(d, 0.2, w), Vector3(cx, -0.1, cz), fl)
	_box(r, "c", Vector3(d, 0.2, w), Vector3(cx, h + 0.1, cz), cl)
	_box(r, "back", Vector3(0.2, h, w), Vector3(cx + sx * d * 0.5, h * 0.5, cz), wl)
	_box(r, "s1", Vector3(d, h, 0.2), Vector3(cx, h * 0.5, cz - w * 0.5), wl)
	_box(r, "s2", Vector3(d, h, 0.2), Vector3(cx, h * 0.5, cz + w * 0.5), wl)
	# One very dim fixture deep in the room: enough to suggest a space, not
	# enough to be safe.
	var o := OmniLight3D.new()
	o.position = Vector3(cx + sx * 1.2, h - 0.4, cz)
	o.light_energy = 0.40
	o.light_color = Color(0.55, 0.85, 0.80)
	o.omni_range = 4.5
	o.shadow_enabled = false
	o.light_volumetric_fog_energy = 1.4
	r.add_child(o)


func _fixture(p: Node3D, at: Vector3, mode: int, sd: int) -> void:
	var holder := Node3D.new()
	holder.name = "Fixture_%d" % int(at.z)
	holder.position = at
	p.add_child(holder)

	# Housing + the emissive diffuser panel LightFlicker will drive.
	_box(holder, "Housing", Vector3(0.78, 0.10, 1.36), Vector3(0, -0.06, 0),
		_mat(Color(0.22, 0.24, 0.23), 0.6, 0.3))
	var panel_mat := _emissive(Color(0.88, 0.94, 0.90), Color(0.80, 1.0, 0.92), 1.5)
	var panel := _box(holder, "Panel", Vector3(0.62, 0.04, 1.20), Vector3(0, -0.12, 0), panel_mat)
	# material_override wins over surface overrides, so clear it and let
	# LightFlicker install a per-instance surface material.
	panel.material_override = null
	panel.set_surface_override_material(0, panel_mat)

	var l := SpotLight3D.new()
	l.name = "Light"
	l.position = Vector3(0, -0.18, 0)
	l.rotation_degrees = Vector3(-90, 0, 0)
	l.light_color = Color(0.78, 0.90, 1.00)     # cold blue-white tube
	l.light_energy = 3.6
	l.spot_range = 7.0
	l.spot_angle = 60.0
	l.spot_angle_attenuation = 1.4
	l.spot_attenuation = 1.5
	l.shadow_enabled = true
	l.shadow_bias = 0.04
	l.shadow_normal_bias = 1.2
	# Punchier in fog than in air: this is what makes the pools of light read
	# as volumes hanging under each fixture.
	l.light_volumetric_fog_energy = 3.0
	l.set_meta(LightFlicker.META_MODE, mode)
	l.set_meta(LightFlicker.META_SEED, sd)
	l.set_meta(LightFlicker.META_PANEL, panel)
	l.set_meta(LightFlicker.META_BASE_EMISSION, 1.5)
	holder.add_child(l)

	var f := LightFlicker.new()
	f.name = "Flicker"
	l.add_child(f)
	fixtures.append(f)


# --- camera rig ------------------------------------------------------------

func _build_rig() -> void:
	rig = Node3D.new()
	rig.name = "Rig"
	rig.position = Vector3(0, 0, 1.0)
	rig.rotation.y = FORWARD_YAW
	add_child(rig)

	cam_fx = CameraFX.new()
	cam_fx.name = "CameraFX"
	cam_fx.position = Vector3(0, C.EYE_H, 0)
	rig.add_child(cam_fx)

	camera = Camera3D.new()
	camera.name = CameraFX.CAMERA_NODE_NAME
	camera.fov = 75.0
	camera.near = 0.05
	camera.far = 120.0
	camera.current = true
	cam_fx.add_child(camera)

	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	# Slightly below and right of the eye: a held torch, not a headlamp.
	flashlight.position = Vector3(0.18, -0.16, 0.0)
	flashlight.light_color = Color(1.0, 0.86, 0.62)   # warm tungsten, against the teal
	flashlight.light_energy = 4.5
	flashlight.spot_range = C.CONE_RANGE
	flashlight.spot_angle = C.CONE_DEG
	flashlight.spot_angle_attenuation = 0.55
	flashlight.spot_attenuation = 1.1
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.03
	flashlight.shadow_normal_bias = 1.0
	# 6.0: the cone is the point. This is the single number that decides
	# whether the beam is a visible shaft of light or just a bright spot
	# painted on a wall.
	flashlight.light_volumetric_fog_energy = 2.8
	camera.add_child(flashlight)

	cam_fx.rebind_camera()


# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _shot_mode:
		return

	if auto_fly:
		fly_t += delta
		# Walk up and down the corridor, looking around on the way.
		var z := 1.5 + 11.0 * (1.0 - cos(fly_t * 0.16))
		rig.position = Vector3(sin(fly_t * 0.23) * 0.5, 0, z)
		yaw = sin(fly_t * 0.19) * 0.55
		pitch = sin(fly_t * 0.11) * 0.10
		rig.rotation.y = FORWARD_YAW + yaw
		cam_fx.rotation.x = pitch
		var spd := 0.45 + 0.25 * sin(fly_t * 0.16)
		cam_fx.set_motion(spd, false, true, sin(fly_t * 0.23) * 0.3)
		cam_fx.set_fov_kick(0.0)
	else:
		_fly_input(delta)

	cam_fx.set_breathing(1.0 if breathing_on else 0.0)
	if fx != null:
		fx.set_danger(1.0 if danger_on else 0.0)
		fx.set_pulse(1.0 if pulse_on else 0.0)


func _fly_input(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir.z -= 1.0
	if Input.is_key_pressed(KEY_S): dir.z += 1.0
	if Input.is_key_pressed(KEY_A): dir.x -= 1.0
	if Input.is_key_pressed(KEY_D): dir.x += 1.0
	var sprinting := Input.is_key_pressed(KEY_SHIFT)
	var speed := (C.SPRINT_SPEED if sprinting else C.WALK_SPEED)
	if dir.length_squared() > 0.0:
		dir = dir.normalized()
		var basis := Basis(Vector3.UP, rig.rotation.y)
		rig.position += basis * dir * speed * delta
	cam_fx.set_motion(dir.length() * (speed / C.SPRINT_SPEED), sprinting, true, dir.x)
	cam_fx.set_fov_kick(1.0 if (sprinting and dir.length_squared() > 0.0) else 0.0)


func _unhandled_input(e: InputEvent) -> void:
	if _shot_mode:
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT:
		mouse_look = e.pressed
		Input.set_mouse_mode(
			Input.MOUSE_MODE_CAPTURED if mouse_look else Input.MOUSE_MODE_VISIBLE)
	elif e is InputEventMouseMotion and mouse_look:
		auto_fly = false
		yaw -= e.relative.x * 0.0025
		pitch = clampf(pitch - e.relative.y * 0.0025, -1.4, 1.4)
		rig.rotation.y = FORWARD_YAW + yaw
		cam_fx.rotation.x = pitch
	elif e is InputEventKey and e.pressed and not e.echo:
		_key(e.keycode)


func _key(k: int) -> void:
	var e: Environment = env_node.environment
	match k:
		KEY_1, KEY_2, KEY_3:
			quality = k - KEY_1
			Look.apply_quality(self, quality)
		KEY_F:
			flashlight.visible = not flashlight.visible
		KEY_V:
			e.volumetric_fog_enabled = not e.volumetric_fog_enabled
		KEY_G:
			fx.set_grain(0.0 if fx.material.get_shader_parameter("grain_amount") > 0.0
				else Look.PostFX.BASE_GRAIN)
		KEY_C:
			fx.set_aberration(0.0 if fx.material.get_shader_parameter("aberration") > 0.0
				else Look.PostFX.BASE_ABERRATION)
		KEY_B:
			fx.set_barrel(0.0 if fx.material.get_shader_parameter("barrel") > 0.0
				else Look.PostFX.BASE_BARREL)
		KEY_K:
			fx.set_scanlines(0.0 if fx.material.get_shader_parameter("scanlines") > 0.0 else 0.85)
		KEY_N:
			fx.set_vignette(0.0 if fx.material.get_shader_parameter("vignette_strength") > 0.0
				else Look.PostFX.BASE_VIGNETTE)
		KEY_J:
			e.adjustment_enabled = not e.adjustment_enabled
		KEY_M:
			e.glow_enabled = not e.glow_enabled
		KEY_COMMA:
			e.ssao_enabled = not e.ssao_enabled
		KEY_PERIOD:
			e.ssil_enabled = not e.ssil_enabled
		KEY_P:
			fx.set_enabled(not fx.is_enabled())
		KEY_X:
			damage_hold = not damage_hold
			if damage_hold: fx.set_damage(1.0)
			else: fx.set_damage(0.0)
		KEY_Z:
			danger_on = not danger_on
		KEY_H:
			pulse_on = not pulse_on
		KEY_O:
			blackout_on = not blackout_on
			if blackout_on: fx.fade_to_black(0.8)
			else: fx.fade_from_black(0.8)
		KEY_SPACE:
			cam_fx.add_shake(0.8, 0.6)
		KEY_R:
			cam_fx.reset()
			fx.reset()
			damage_hold = false
			danger_on = false
			pulse_on = false
			blackout_on = false
		KEY_L:
			breathing_on = not breathing_on
		KEY_Q:
			cam_fx.set_lean(-1.0)
		KEY_E:
			cam_fx.set_lean(1.0)
		KEY_ENTER, KEY_KP_ENTER:
			auto_fly = not auto_fly
		KEY_TAB:
			_print_settings()
			return
		KEY_ESCAPE:
			get_tree().quit()
			return
		_:
			return
	_print_settings()


func _print_settings() -> void:
	print("\n--- lookdev [quality=%s] ------------------------------------" %
		Look.QUALITY_NAMES[quality])
	print(Look.describe(self))
	print("RIG  flashlight=%s autofly=%s breathing=%s trauma=%.2f | lights t=%.1f" % [
		flashlight.visible, auto_fly, breathing_on, cam_fx.get_trauma(),
		LightFlicker.get_time()])
	var st: PackedStringArray = []
	for f in fixtures:
		st.append("%s:%.2f" % [["steady", "flicker", "dead"][f.mode], f.get_factor()])
	print("FIX  " + "  ".join(st))


# ---------------------------------------------------------------------------
# Screenshot capture
# ---------------------------------------------------------------------------

## Find a time at which fixture [param idx] is doing something photogenic.
func _find_time(idx: int, lo: float, hi: float) -> float:
	var f := fixtures[idx]
	var t := 0.0
	while t < 400.0:
		var v: float = f._factor(t)
		if v >= lo and v <= hi:
			return t
		t += 0.01
	return 0.0


func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ShotDir))
	await get_tree().process_frame

	# Freeze the light clock so each shot is reproducible.
	LightFlicker.sync_time(2.0)

	var shots := [
		{
			"name": "01_flashlight_on",
			"desc": "flashlight on, dark corridor, cone through volumetric fog",
			"pos": Vector3(-0.5, 0, 1.4), "yaw": 0.10, "pitch": -0.05,
			"flash": true, "t": 2.0,
		},
		{
			"name": "02_flashlight_off",
			"desc": "flashlight off, same spot: fixtures and monitor only",
			"pos": Vector3(-0.5, 0, 1.4), "yaw": 0.10, "pitch": -0.05,
			"flash": false, "t": 2.0,
		},
		{
			"name": "03_flicker_mid",
			"desc": "flicker fixture mid re-strike (overbright), flashlight off",
			"pos": Vector3(0.3, 0, 6.6), "yaw": -0.05, "pitch": 0.06,
			"flash": false, "t": -1.0,   # resolved below
		},
		{
			"name": "04_damage_danger_full",
			"desc": "damage 1.0 + danger 1.0 + pulse 1.0, flashlight on",
			"pos": Vector3(-0.5, 0, 1.4), "yaw": 0.10, "pitch": -0.05,
			"flash": true, "t": 2.0, "damage": 1.0, "danger": 1.0, "pulse": 1.0,
		},
		{
			"name": "05_quality_low",
			"desc": "same frame as 01 on the low preset: no volumetric fog, no SSAO/SSIL",
			"pos": Vector3(-0.5, 0, 1.4), "yaw": 0.10, "pitch": -0.05,
			"flash": true, "t": 2.0, "quality": Look.QUALITY_LOW,
		},
		{
			"name": "06_scanlines_crt",
			"desc": "scanline/CRT mode at 0.85, for the patient-monitor UI feel",
			"pos": Vector3(0.3, 0, 6.6), "yaw": -0.05, "pitch": 0.06,
			"flash": false, "t": -2.0, "scanlines": 0.85,
		},
	]

	# Fixture 1 (z=9) is the near flicker; find a frame where it is punching
	# back on rather than merely lit or merely out.
	shots[2]["t"] = _find_time(1, 1.05, 1.40)
	shots[5]["t"] = shots[2]["t"]

	cam_fx.reset()
	cam_fx.set_motion(0.0, false, true, 0.0)
	cam_fx.set_breathing(0.0)

	for s in shots:
		rig.position = s["pos"]
		rig.rotation.y = FORWARD_YAW + s["yaw"]
		cam_fx.rotation.x = s["pitch"]
		flashlight.visible = s["flash"]
		LightFlicker.sync_time(s["t"])

		fx.reset()
		fx.set_damage(float(s.get("damage", 0.0)))
		fx.set_danger(float(s.get("danger", 0.0)))
		fx.set_pulse(float(s.get("pulse", 0.0)))
		fx.set_scanlines(float(s.get("scanlines", 0.0)))
		Look.apply_quality(self, int(s.get("quality", quality)))

		# Volumetric fog uses temporal reprojection and SSAO/glow need a few
		# frames too; 90 frames is well past settled.
		for i in 90:
			LightFlicker.sync_time(s["t"])
			await get_tree().process_frame

		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var fn := "shot_%s.png" % s["name"]
		img.save_png("user://%s" % fn)
		img.save_png("%s/%s" % [ShotDir, fn])
		print("[shot] %s  t=%.2f  %s" % [fn, float(s["t"]), s["desc"]])
		print(Look.describe(self))

	print("[shot] user dir: ", OS.get_user_data_dir())
	await get_tree().process_frame
	get_tree().quit()
