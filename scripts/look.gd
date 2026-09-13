class_name Look
extends RefCounted
## Builds the visual environment in code.
##
## The hospital is generated at runtime, so nothing visual can live in a prebuilt
## scene. Everything here is a static factory: call it once when the level is
## built, parent the results into the scene tree, and forget about it.
##
## Typical wiring (see tools/lookdev.gd for a working example):
## [codeblock]
## add_child(Look.make_environment())
## var post := Look.make_post_layer()
## add_child(post)
## Look.apply_quality(self, Look.QUALITY_MEDIUM)
## var fx: Look.PostFX = Look.get_post_fx(self)   # named setters live here
## [/codeblock]

const QUALITY_LOW := 0
const QUALITY_MEDIUM := 1
const QUALITY_HIGH := 2

const QUALITY_NAMES := ["low", "medium", "high"]

## Node names, so other systems can find these without keeping references.
const ENV_NODE_NAME := "LookEnvironment"
const POST_LAYER_NAME := "LookPostLayer"
const POST_RECT_NAME := "PostFX"

const POST_SHADER_PATH := "res://shaders/post.gdshader"

## Canvas layer for the post pass. Above the world, below gameplay HUD (which
## should live at 100+) so the HUD does not get grained and vignetted.
const POST_CANVAS_LAYER := 50


# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

## A tuned WorldEnvironment for the dark hospital.
##
## The single biggest win here is volumetric fog: it is what makes the
## flashlight read as a solid cone of light cutting through haze instead of a
## bright circle painted on a wall. Everything else is support.
static func make_environment() -> WorldEnvironment:
	var we := WorldEnvironment.new()
	we.name = ENV_NODE_NAME
	we.environment = make_environment_resource()
	we.camera_attributes = make_camera_attributes()
	return we


static func make_environment_resource() -> Environment:
	var env := Environment.new()

	# --- background --------------------------------------------------------
	# Pure black. There is no sky in a hospital basement; anything we can see
	# in the distance should be fog, not backdrop.
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 1)
	env.background_energy_multiplier = 1.0

	# --- ambient -----------------------------------------------------------
	# sdfgi is off (way too expensive to rebuild for a per-shift procedural
	# map, and it flickers while geometry streams in), so instead of global
	# illumination we lift ambient a little. This is the compromise that keeps
	# unlit corners readable as *shapes* rather than flat black holes.
	# The colour is the sickly green-teal that carries the whole palette.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.26, 0.55, 0.44)
	env.ambient_light_energy = 0.13
	env.ambient_light_sky_contribution = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	# --- tonemap -----------------------------------------------------------
	# ACES: rolls off the flashlight hotspot instead of clipping it to a white
	# disc, and keeps saturation in the deep shadows where Linear goes muddy.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	# white=2.4, not the default 1.0 and not the 6.0 I started with: 6.0 makes
	# ACES roll off so gently that every pool of light turns into flat grey
	# mush, 1.0 clips hard. 2.4 keeps a hot core with a readable shoulder.
	env.tonemap_white = 2.4

	# --- depth fog (backstop) ---------------------------------------------
	# Volumetric fog has a finite range (volumetric_fog_length). Past that it
	# simply stops, which produces a visible "wall of clarity" down a long
	# corridor. Plain depth fog picks up from roughly where the volumetric
	# range ends and carries the falloff to black.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.040, 0.082, 0.066)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.0
	env.fog_density = 0.55
	env.fog_aerial_perspective = 0.0
	env.fog_sky_affect = 0.0
	env.fog_depth_begin = 8.0
	env.fog_depth_end = 42.0
	env.fog_depth_curve = 1.6

	# --- volumetric fog (the money shot) -----------------------------------
	env.volumetric_fog_enabled = true
	# 0.036. Below ~0.030 the flashlight cone simply is not visible, which
	# defeats the point; at 0.045+ the cone goes opaque and you can no longer
	# see the thing you are pointing the torch at.
	env.volumetric_fog_density = 0.036
	env.volumetric_fog_albedo = Color(0.56, 0.76, 0.66)
	env.volumetric_fog_emission = Color(0.008, 0.020, 0.014)
	env.volumetric_fog_emission_energy = 0.30
	env.volumetric_fog_gi_inject = 0.0          # sdfgi is off, nothing to inject
	# Slightly BACK-scattering. First-person means you almost always look down
	# your own beam, and that is 180-degree scatter: positive (forward)
	# anisotropy actively dims the halo you are trying to see. -0.12 brightens
	# the cone from the player's own viewpoint without flattening the pools of
	# light under the ceiling fixtures, which are viewed side-on.
	env.volumetric_fog_anisotropy = -0.12
	# 40 m covers a whole corridor; shorter means more froxel resolution per
	# metre near the camera, which is where the cone actually reads.
	env.volumetric_fog_length = 40.0
	env.volumetric_fog_detail_spread = 2.0
	# Low ambient inject: we want the fog dark except where a light hits it.
	env.volumetric_fog_ambient_inject = 0.35
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.9

	# --- glow / bloom ------------------------------------------------------
	# Tuned so emissive monitors and ceiling panels bleed without the whole
	# frame hazing over. Levels 3-5 only: level 1-2 bloom looks like a smeared
	# lens, 6-7 is a cheap wide halo that eats contrast in a dark scene.
	env.glow_enabled = true
	env.set("glow_levels/1", 0.0)
	env.set("glow_levels/2", 0.0)
	env.set("glow_levels/3", 0.55)
	env.set("glow_levels/4", 1.00)
	env.set("glow_levels/5", 0.35)
	env.set("glow_levels/6", 0.0)
	env.set("glow_levels/7", 0.0)
	env.glow_normalized = false
	# 0.38, well down from where I started. Anything near 1.0 and the ceiling
	# panels stop being panels and become soft white clouds; the whole frame
	# loses its edges. The bloom should be something you notice only when you
	# turn it off.
	env.glow_intensity = 0.38
	env.glow_strength = 0.9
	env.glow_mix = 0.02
	env.glow_bloom = 0.0
	# SCREEN rather than ADDITIVE: additive turns a bright monitor into a solid
	# white blob, screen keeps the screen's colour in the bloom.
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	# Threshold above 1.0 so only genuinely over-range pixels (emissive panels,
	# the monitor, the flashlight hotspot) bloom. Below 1.0 and lit walls bloom
	# too, which is exactly the grey mush above.
	env.glow_hdr_threshold = 1.10
	env.glow_hdr_scale = 1.6
	env.glow_hdr_luminance_cap = 8.0

	# --- SSAO / SSIL -------------------------------------------------------
	# Both on but deliberately cheap (see apply_quality for the RenderingServer
	# quality knobs). SSAO is what grounds the chunky low-poly boxes so they
	# stop looking like they are floating. SSIL is subtle here but it is the
	# reason a green wall next to a lit floor tints the floor.
	env.ssao_enabled = true
	env.ssao_radius = 0.85
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.15
	env.ssao_ao_channel_affect = 0.0

	env.ssil_enabled = true
	env.ssil_radius = 2.5
	env.ssil_intensity = 0.75
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 0.2

	# Screen-space reflections off: wet-floor reflections are not worth the
	# cost here and they fight the fog.
	env.ssr_enabled = false

	# --- sdfgi -------------------------------------------------------------
	env.sdfgi_enabled = false

	# --- colour grade ------------------------------------------------------
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.22
	env.adjustment_saturation = 1.18
	env.adjustment_color_correction = make_grade_gradient()

	return env


## Per-channel colour-correction ramp.
##
## Godot's 1D adjustment texture remaps each channel independently by its own
## value, so a gradient that is blue-green at the dark end and amber at the
## bright end pushes shadows toward sickly teal and anything the flashlight
## actually reaches toward warm tungsten. That single split is most of the
## R.E.P.O. palette.
##
## [param gamma] (settings hook, brightness): when not 1.0 the ramp is resampled so input x
## reads the shipped ramp at x^gamma; below 1 lifts the shadows, above 1 sinks them.
static func make_grade_gradient(gamma := 1.0) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.22, 0.50, 0.78, 1.0])
	g.colors = PackedColorArray([
		Color(0.000, 0.034, 0.034),  # crushed blacks, lifted only in G/B
		Color(0.170, 0.248, 0.232),  # shadows: clearly green-teal
		Color(0.500, 0.516, 0.492),  # midtones: near neutral, hair cool
		Color(0.800, 0.780, 0.700),  # upper mids warming up
		Color(1.000, 0.965, 0.880),  # highlights: warm tungsten
	])
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR

	if not is_equal_approx(gamma, 1.0):
		const N := 48
		var offs := PackedFloat32Array()
		var cols := PackedColorArray()
		for i in N + 1:
			# Denser samples near black, where the gamma bend is steepest.
			var x := pow(float(i) / N, 2.0)
			offs.append(x)
			# Take the brightness from x^gamma but keep the shipped hue for x, so lifted
			# shadows stay the grade's teal instead of sliding into its saturated green.
			var base := g.sample(x)
			var bent_c := g.sample(pow(x, gamma))
			var l0 := base.get_luminance()
			var l1 := bent_c.get_luminance()
			if l0 > 0.02:
				var r := l1 / l0
				cols.append(Color(minf(base.r * r, 1.0), minf(base.g * r, 1.0), minf(base.b * r, 1.0)))
			else:
				cols.append(bent_c)
		var bent := Gradient.new()
		bent.offsets = offs
		bent.colors = cols
		bent.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_LINEAR
		g = bent

	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 256
	tex.use_hdr = false
	return tex


# ---------------------------------------------------------------------------
# Brightness (settings hook)
# ---------------------------------------------------------------------------

## The shipped look. Settings "brightness" is 0..1 with this in the middle.
const BRIGHTNESS_DEFAULT := 0.5

## Apply the player's brightness setting to the environment under [param target] (a node
## that has the Look environment as a child or descendant, a WorldEnvironment, or an
## Environment).
##
## Two free knobs inside the tonemap pass the frame already runs, so it costs nothing:
## - a gamma bend baked into the colour-grade ramp, which lifts (or sinks) the shadows and
##   midtones where dark corridors live while pure black stays black and the flashlight
##   hotspot stays where it was;
## - a small tonemap exposure change on top, so lit areas follow a little.
## At the default (0.5) the shipped ramp and exposure 1.0 are restored exactly.
static func apply_brightness(target: Object, value: float) -> void:
	var env: Environment = null
	if target is Environment:
		env = target
	elif target is WorldEnvironment:
		env = (target as WorldEnvironment).environment
	elif target is Node:
		var we := (target as Node).get_node_or_null(ENV_NODE_NAME) as WorldEnvironment
		if we == null:
			we = (target as Node).find_child(ENV_NODE_NAME, true, false) as WorldEnvironment
		if we == null:
			we = _find_first_world_environment(target)
		if we != null:
			env = we.environment
	if env == null:
		return
	var v := clampf(value, 0.0, 1.0)
	var d := v - BRIGHTNESS_DEFAULT
	env.set_meta("brightness", v)
	if absf(d) < 0.004:
		env.adjustment_color_correction = make_grade_gradient()
		env.tonemap_exposure = 1.0
		return
	# Gamma on the ramp input: 0.6 at the top of the slider (shadows lifted), about 1.5 at
	# the bottom (a darker, crushed look). 1.0 in the middle.
	var p := pow(2.0, -d * 1.47) if d > 0.0 else pow(2.0, -d * 1.17)
	env.adjustment_color_correction = make_grade_gradient(p)
	# +/- a quarter stop at the ends; more than that washes out the lit areas.
	env.tonemap_exposure = pow(2.0, d * 0.5)


## Physical-ish camera attributes. Auto exposure is deliberately OFF: in a game
## about pointing a flashlight at things, auto exposure fights the player by
## brightening every dark room they are supposed to be afraid of.
static func make_camera_attributes() -> CameraAttributesPractical:
	var ca := CameraAttributesPractical.new()
	ca.auto_exposure_enabled = false
	ca.exposure_multiplier = 1.0
	ca.dof_blur_far_enabled = false
	ca.dof_blur_near_enabled = false
	return ca


# ---------------------------------------------------------------------------
# Post layer
# ---------------------------------------------------------------------------

## A full-screen ColorRect running shaders/post.gdshader on a high CanvasLayer.
## The returned layer has one child, "PostFX", which is a Look.PostFX and
## carries the named setters.
static func make_post_layer() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = POST_LAYER_NAME
	layer.layer = POST_CANVAS_LAYER
	layer.follow_viewport_enabled = false

	var rect := PostFX.new()
	rect.name = POST_RECT_NAME
	layer.add_child(rect)
	return layer


## Find the PostFX wrapper anywhere under [param root]. Returns null if the
## post layer was never added (all call sites should null-check; the game must
## stay playable with post disabled).
static func get_post_fx(root: Node) -> PostFX:
	if root == null:
		return null
	var layer := root.find_child(POST_LAYER_NAME, true, false)
	if layer == null:
		# Maybe someone parented the rect directly.
		var direct := root.find_child(POST_RECT_NAME, true, false)
		return direct as PostFX
	return layer.find_child(POST_RECT_NAME, true, false) as PostFX


# ---------------------------------------------------------------------------
# Quality presets
# ---------------------------------------------------------------------------

## Apply one of three presets to everything under [param root].
##
## 0 low     — integrated-graphics laptop. No volumetric fog, no SSIL, no MSAA.
## 1 medium  — the default. Volumetric fog at half resolution, cheap SSAO.
## 2 high    — everything on, 4x MSAA, big shadow atlas.
##
## Safe to call at any time, including every time the player moves the slider.
static func apply_quality(root: Node, level: int) -> void:
	level = clampi(level, QUALITY_LOW, QUALITY_HIGH)
	if root == null:
		return

	var env: Environment = null
	var we := root.find_child(ENV_NODE_NAME, true, false) as WorldEnvironment
	if we == null:
		we = _find_first_world_environment(root)
	if we != null:
		env = we.environment

	# --- environment toggles ----------------------------------------------
	if env != null:
		match level:
			QUALITY_LOW:
				# Volumetric fog is the single most expensive thing here, so it
				# is the first thing to go. Depth fog is bumped to compensate
				# so the corridor still fades out instead of going crisp.
				env.volumetric_fog_enabled = false
				env.fog_density = 0.85
				env.fog_depth_begin = 5.0
				env.fog_depth_end = 32.0
				env.ssao_enabled = false
				env.ssil_enabled = false
				env.glow_enabled = true
				env.set("glow_levels/3", 0.0)
				env.set("glow_levels/4", 1.0)
				env.set("glow_levels/5", 0.0)
				env.set("glow_levels/6", 0.0)
				env.glow_intensity = 0.30
				# Ambient up: with no volumetrics and no SSAO, black corners
				# really are featureless, so lift them a touch more.
				env.ambient_light_energy = 0.15
			QUALITY_MEDIUM:
				env.volumetric_fog_enabled = true
				env.volumetric_fog_density = 0.036
				env.volumetric_fog_length = 32.0
				env.volumetric_fog_detail_spread = 2.0
				env.volumetric_fog_temporal_reprojection_enabled = true
				env.fog_density = 0.55
				env.fog_depth_begin = 8.0
				env.fog_depth_end = 42.0
				# Measured on a Radeon 890M: SSAO alone cost 36 -> 56 fps in the OR. The
				# fog and flashlight already carry the darkness, so medium goes without.
				env.ssao_enabled = false
				env.ssil_enabled = false
				env.glow_enabled = true
				env.set("glow_levels/3", 0.55)
				env.set("glow_levels/4", 1.00)
				env.set("glow_levels/5", 0.35)
				env.set("glow_levels/6", 0.0)
				env.glow_intensity = 0.38
				env.ambient_light_energy = 0.13
			QUALITY_HIGH:
				env.volumetric_fog_enabled = true
				env.volumetric_fog_density = 0.036
				env.volumetric_fog_length = 40.0
				env.volumetric_fog_detail_spread = 2.0
				env.volumetric_fog_temporal_reprojection_enabled = true
				env.fog_density = 0.55
				env.fog_depth_begin = 8.0
				env.fog_depth_end = 42.0
				env.ssao_enabled = true
				env.ssil_enabled = true
				env.glow_enabled = true
				env.set("glow_levels/3", 0.55)
				env.set("glow_levels/4", 1.00)
				env.set("glow_levels/5", 0.35)
				env.set("glow_levels/6", 0.10)
				env.glow_intensity = 0.38
				env.ambient_light_energy = 0.13

	# --- renderer-wide knobs ----------------------------------------------
	# These are RenderingServer calls, not ProjectSettings: changing the
	# project setting at runtime does nothing.
	match level:
		QUALITY_LOW:
			RenderingServer.environment_set_volumetric_fog_volume_size(64, 64)
			RenderingServer.environment_set_volumetric_fog_filter_active(false)
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, true, 0.5, 1, 50.0, 300.0)
			RenderingServer.environment_set_ssil_quality(
				RenderingServer.ENV_SSIL_QUALITY_VERY_LOW, true, 0.5, 1, 50.0, 300.0)
			RenderingServer.environment_glow_set_use_bicubic_upscale(false)
			RenderingServer.directional_shadow_atlas_set_size(1024, false)
		QUALITY_MEDIUM:
			# 96x48 instead of 128x64: about +10 fps in every scene, and with temporal
			# reprojection on the haze still reads the same.
			RenderingServer.environment_set_volumetric_fog_volume_size(96, 48)
			RenderingServer.environment_set_volumetric_fog_filter_active(true)
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_LOW, true, 0.5, 2, 50.0, 300.0)
			RenderingServer.environment_set_ssil_quality(
				RenderingServer.ENV_SSIL_QUALITY_LOW, true, 0.5, 2, 50.0, 300.0)
			RenderingServer.environment_glow_set_use_bicubic_upscale(false)
			RenderingServer.directional_shadow_atlas_set_size(2048, true)
		QUALITY_HIGH:
			RenderingServer.environment_set_volumetric_fog_volume_size(192, 96)
			RenderingServer.environment_set_volumetric_fog_filter_active(true)
			RenderingServer.environment_set_ssao_quality(
				RenderingServer.ENV_SSAO_QUALITY_MEDIUM, false, 0.5, 2, 50.0, 300.0)
			RenderingServer.environment_set_ssil_quality(
				RenderingServer.ENV_SSIL_QUALITY_MEDIUM, false, 0.5, 2, 50.0, 300.0)
			RenderingServer.environment_glow_set_use_bicubic_upscale(true)
			RenderingServer.directional_shadow_atlas_set_size(4096, true)

	# --- viewport ----------------------------------------------------------
	var vp := root.get_viewport()
	if vp != null:
		match level:
			QUALITY_LOW:
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
				vp.use_taa = false
				vp.positional_shadow_atlas_size = 1024
			QUALITY_MEDIUM:
				# No MSAA: the 3D view renders below native and is upscaled (see main.gd),
				# where MSAA costs a lot for little. FXAA at render resolution is nearly free.
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
				vp.use_taa = false
				vp.positional_shadow_atlas_size = 2048
			QUALITY_HIGH:
				vp.msaa_3d = Viewport.MSAA_2X
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
				vp.use_taa = false
				vp.positional_shadow_atlas_size = 4096
		# 16 shadow-casting lights per quadrant: a corridor easily has that many
		# ceiling fixtures in view.
		vp.positional_shadow_atlas_quad_0 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		vp.positional_shadow_atlas_quad_1 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		vp.positional_shadow_atlas_quad_2 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4
		vp.positional_shadow_atlas_quad_3 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1

	# --- post ---------------------------------------------------------------
	var fx := get_post_fx(root)
	if fx != null:
		fx.apply_quality(level)


static func _find_first_world_environment(n: Node) -> WorldEnvironment:
	if n is WorldEnvironment:
		return n
	for c in n.get_children():
		var found := _find_first_world_environment(c)
		if found != null:
			return found
	return null


## Human-readable dump of the current look settings, for tuning in the console.
static func describe(root: Node) -> String:
	var lines: PackedStringArray = []
	var we := root.find_child(ENV_NODE_NAME, true, false) as WorldEnvironment
	if we == null:
		we = _find_first_world_environment(root)
	if we != null and we.environment != null:
		var e := we.environment
		lines.append("ENV  volfog=%s d=%.3f len=%.0f aniso=%.2f | fog=%s d=%.2f %.0f-%.0f" % [
			e.volumetric_fog_enabled, e.volumetric_fog_density, e.volumetric_fog_length,
			e.volumetric_fog_anisotropy, e.fog_enabled, e.fog_density,
			e.fog_depth_begin, e.fog_depth_end])
		lines.append("ENV  glow=%s i=%.2f thr=%.2f | ssao=%s ssil=%s | ambient=%.3f | grade=%s" % [
			e.glow_enabled, e.glow_intensity, e.glow_hdr_threshold,
			e.ssao_enabled, e.ssil_enabled, e.ambient_light_energy, e.adjustment_enabled])
	var fx := get_post_fx(root)
	if fx != null:
		lines.append(fx.describe())
	var vp := root.get_viewport()
	if vp != null:
		lines.append("VP   msaa=%d ssaa=%d shadow_atlas=%d" % [
			vp.msaa_3d, vp.screen_space_aa, vp.positional_shadow_atlas_size])
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# PostFX — the GDScript wrapper over post.gdshader
# ---------------------------------------------------------------------------

## Full-screen post rect with named setters.
##
## Gameplay code never touches set_shader_parameter strings; it calls things
## like [code]fx.hit(0.8)[/code] or [code]fx.set_danger(0.4)[/code]. Every
## setter is safe to call every frame.
class PostFX extends ColorRect:

	# Defaults, also used as the "base" that damage/danger add on top of.
	const BASE_VIGNETTE := 0.70
	const BASE_GRAIN := 0.045
	const BASE_ABERRATION := 0.0016
	const BASE_BARREL := 0.022
	const BASE_EDGE_DESAT := 0.55

	var _mat: ShaderMaterial
	var _damage := 0.0
	var _damage_decay := 1.6      ## units per second; a hit reads for ~0.6 s
	var _danger := 0.0
	var _danger_target := 0.0
	var _pulse := 0.0
	var _pulse_target := 0.0
	var _blackout := 0.0
	var _blackout_target := 0.0
	var _blackout_rate := 0.0     ## 0 == snap
	var _enabled := true

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		anchor_right = 1.0
		anchor_bottom = 1.0
		offset_left = 0.0
		offset_top = 0.0
		offset_right = 0.0
		offset_bottom = 0.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The shader replaces COLOR entirely; this just avoids a white flash on
		# the first frame if the shader fails to compile.
		color = Color(0, 0, 0, 0)

		var sh: Shader = load(Look.POST_SHADER_PATH)
		_mat = ShaderMaterial.new()
		if sh != null:
			_mat.shader = sh
		else:
			push_warning("Look.PostFX: %s missing; post effects disabled." % Look.POST_SHADER_PATH)
		material = _mat

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_update_aspect()
		get_viewport().size_changed.connect(_update_aspect)
		reset()
		set_process(true)

	func _update_aspect() -> void:
		var s := get_viewport().get_visible_rect().size
		if s.y > 0.0:
			_sp("aspect", s.x / s.y)

	## Short alias; used everywhere below. NOTE: must not be named `_set`,
	## that is an Object virtual and Godot would call it for every property.
	func _sp(n: StringName, v: Variant) -> void:
		if _mat != null and _mat.shader != null:
			_mat.set_shader_parameter(n, v)

	func _process(delta: float) -> void:
		if not _enabled:
			return
		# Damage decays on its own; callers only ever kick it up.
		if _damage > 0.0:
			_damage = maxf(0.0, _damage - _damage_decay * delta)
			_sp("damage", _damage)
		# Danger and pulse are smoothed so AI state changes do not pop.
		_danger = _damp(_danger, _danger_target, 3.0, delta)
		_sp("danger", _danger)
		_pulse = _damp(_pulse, _pulse_target, 2.5, delta)
		_sp("pulse", _pulse)
		if _blackout_rate > 0.0:
			_blackout = move_toward(_blackout, _blackout_target, _blackout_rate * delta)
			_sp("blackout", _blackout)
			if is_equal_approx(_blackout, _blackout_target):
				_blackout_rate = 0.0
				blackout_finished.emit(_blackout_target)

	signal blackout_finished(value: float)

	static func _damp(cur: float, target: float, rate: float, delta: float) -> float:
		return lerpf(cur, target, 1.0 - exp(-rate * delta))

	## Restore every uniform to its shipped default.
	func reset() -> void:
		_damage = 0.0
		_danger = 0.0
		_danger_target = 0.0
		_pulse = 0.0
		_pulse_target = 0.0
		_blackout = 0.0
		_blackout_target = 0.0
		_blackout_rate = 0.0
		set_vignette(BASE_VIGNETTE)
		set_grain(BASE_GRAIN)
		set_aberration(BASE_ABERRATION)
		set_barrel(BASE_BARREL)
		set_edge_desaturation(BASE_EDGE_DESAT)
		set_scanlines(0.0)
		_sp("damage", 0.0)
		_sp("danger", 0.0)
		_sp("pulse", 0.0)
		_sp("blackout", 0.0)
		_update_aspect()

	# --- named setters -----------------------------------------------------

	func set_enabled(on: bool) -> void:
		_enabled = on
		visible = on

	func is_enabled() -> bool:
		return _enabled

	func set_vignette(strength: float, softness := 1.05) -> void:
		_sp("vignette_strength", clampf(strength, 0.0, 1.0))
		_sp("vignette_softness", clampf(softness, 0.2, 2.0))

	## Kick the damage flash. Decays automatically.
	func hit(amount := 1.0, decay := 1.6) -> void:
		_damage = clampf(maxf(_damage, amount), 0.0, 1.0)
		_damage_decay = maxf(0.05, decay)
		_sp("damage", _damage)

	## Hold damage at a fixed value (e.g. a low-health overlay). Pass 0 to clear.
	func set_damage(amount: float) -> void:
		_damage = clampf(amount, 0.0, 1.0)
		_damage_decay = 0.0
		_sp("damage", _damage)

	func get_damage() -> float:
		return _damage

	## 0 = safe, 1 = a monster is right there. Smoothed internally.
	func set_danger(amount: float) -> void:
		_danger_target = clampf(amount, 0.0, 1.0)

	func get_danger() -> float:
		return _danger

	## Heartbeat throb strength. Smoothed internally.
	func set_pulse(amount: float, rate := 1.55) -> void:
		_pulse_target = clampf(amount, 0.0, 1.0)
		_sp("pulse_rate", clampf(rate, 0.1, 6.0))

	func get_pulse() -> float:
		return _pulse

	func set_grain(amount: float, size := 1.5, shadow_bias := 1.0) -> void:
		_sp("grain_amount", clampf(amount, 0.0, 0.5))
		_sp("grain_size", clampf(size, 0.5, 8.0))
		_sp("grain_shadow_bias", clampf(shadow_bias, 0.0, 2.0))

	func set_aberration(amount: float) -> void:
		_sp("aberration", clampf(amount, 0.0, 0.05))

	func set_barrel(amount: float) -> void:
		_sp("barrel", clampf(amount, -0.2, 0.2))

	func set_edge_desaturation(amount: float) -> void:
		_sp("edge_desaturation", clampf(amount, 0.0, 1.0))

	## CRT look. Off by default; this is for the patient-monitor UI feel, either
	## on a SubViewport that renders the monitor or briefly full-screen.
	func set_scanlines(amount: float, line_count := 700.0, roll := 0.35) -> void:
		_sp("scanlines", clampf(amount, 0.0, 1.0))
		_sp("scanline_count", clampf(line_count, 64.0, 2048.0))
		_sp("scanline_roll", clampf(roll, 0.0, 4.0))

	## Snap the fade level. Use fade_to_black / fade_from_black for transitions.
	func set_blackout(amount: float) -> void:
		_blackout = clampf(amount, 0.0, 1.0)
		_blackout_target = _blackout
		_blackout_rate = 0.0
		_sp("blackout", _blackout)

	func get_blackout() -> float:
		return _blackout

	func fade_to_black(duration := 0.6) -> void:
		_blackout_target = 1.0
		_blackout_rate = 1.0 / maxf(0.01, duration)

	func fade_from_black(duration := 0.6) -> void:
		_blackout_target = 0.0
		_blackout_rate = 1.0 / maxf(0.01, duration)

	# --- quality -----------------------------------------------------------

	func apply_quality(level: int) -> void:
		match level:
			Look.QUALITY_LOW:
				# Keep vignette and grain (free-ish, and they hide the loss of
				# volumetric fog), drop the sampling-heavy bits.
				set_aberration(0.0)
				set_barrel(0.0)
				set_grain(BASE_GRAIN * 0.8, 2.0, 1.0)
				set_edge_desaturation(BASE_EDGE_DESAT * 0.6)
			Look.QUALITY_MEDIUM:
				set_aberration(BASE_ABERRATION)
				set_barrel(BASE_BARREL)
				set_grain(BASE_GRAIN, 1.5, 1.0)
				set_edge_desaturation(BASE_EDGE_DESAT)
			Look.QUALITY_HIGH:
				set_aberration(BASE_ABERRATION)
				set_barrel(BASE_BARREL)
				set_grain(BASE_GRAIN, 1.0, 1.0)
				set_edge_desaturation(BASE_EDGE_DESAT)

	func describe() -> String:
		if _mat == null or _mat.shader == null:
			return "POST (shader missing)"
		return "POST on=%s vig=%.2f grain=%.3f ab=%.4f barrel=%.3f desat=%.2f scan=%.2f | dmg=%.2f danger=%.2f pulse=%.2f black=%.2f" % [
			_enabled,
			_mat.get_shader_parameter("vignette_strength"),
			_mat.get_shader_parameter("grain_amount"),
			_mat.get_shader_parameter("aberration"),
			_mat.get_shader_parameter("barrel"),
			_mat.get_shader_parameter("edge_desaturation"),
			_mat.get_shader_parameter("scanlines"),
			_damage, _danger, _pulse, _blackout,
		]
