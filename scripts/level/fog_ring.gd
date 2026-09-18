class_name FogRing
extends RefCounted
## The fog ring around the outdoor lot (sweep 4A chunk 2). Past the lot's clear inner area,
## thick fog: visibility falls to nothing within a few metres and sound gets muffled; deep
## enough while fully blinded, heading bends back toward the lot so a player walks out on their
## own without touching the map's border wall. Dropped or thrown items that land in the fog are
## nudged back to its edge (see world_item.gd's settle step).
##
## Every quantity here is a pure function of `level_info.neutral_rect` (static for the level, on
## every machine already), so every machine computes the same fog for a given position with no
## extra network traffic: the steering follows the usual "each client owns its own movement"
## rule, it just has one more input now. Cheap on purpose: no global fog setting is touched
## (see scripts/look.gd's tuned volumetric fog) — the look is a small per-camera Environment
## override (screen-space depth fog) plus a low-pass on the SFX/Ambience buses.

## How far in from the lot's outer edge the fog belt runs.
const MARGIN_M := 7.0
## SWEEP 4A FOLLOW-UP: depth at which visibility/sound are effectively gone -- was 5.0, which
## read as a slow gradual fade-out rather than "walking well-lit ground and immediately hitting
## thick fog." Blindness now lands fast, within a couple of steps of the clear area's edge.
const BLIND_M := 2.2
## Depth at which heading starts bending back toward the lot. Small but non-zero so the very
## first step into the fog doesn't already yank the camera.
const STEER_START_M := 0.6
## Depth at which a fully blinded player is turned to face the lot outright.
const SNAP_M := 1.9
## Max turn rate approaching SNAP_M, radians/second.
const STEER_MAX_RATE := 2.4
const FOG_COLOR := Color(0.60, 0.63, 0.61)


## The lot's clear inner rect: `neutral_rect` shrunk by the fog margin on every side except the
## one against the entrance building (the canopy shields that edge; fog never needs to reach it).
static func inner_rect(level_info: Dictionary) -> Rect2:
	var outer: Rect2 = level_info.get("neutral_rect", Rect2())
	if outer.size == Vector2.ZERO:
		return outer
	return Rect2(outer.position.x + MARGIN_M, outer.position.y,
			maxf(1.0, outer.size.x - MARGIN_M * 2.0), maxf(1.0, outer.size.y - MARGIN_M))


## True while `pos` is anywhere on the lot (inner clear area or the fog belt around it).
static func on_lot(pos: Vector3, level_info: Dictionary) -> bool:
	var outer: Rect2 = level_info.get("neutral_rect", Rect2())
	return outer.size != Vector2.ZERO and outer.has_point(Vector2(pos.x, pos.z))


## Metres past the inner rect's edge; 0 inside it or anywhere off the lot (indoors, a wing: the
## fog never reaches there, so callers should gate on `on_lot` first when that matters).
static func depth_m(pos: Vector3, level_info: Dictionary) -> float:
	if not on_lot(pos, level_info):
		return 0.0
	var r := inner_rect(level_info)
	var p := Vector2(pos.x, pos.z)
	var dx := maxf(r.position.x - p.x, maxf(0.0, p.x - r.end.x))
	var dy := maxf(r.position.y - p.y, maxf(0.0, p.y - r.end.y))
	return maxf(dx, dy)


## 0 (clear) .. 1 (fully blind/deaf) for a depth.
static func visibility01(depth: float) -> float:
	return clampf(depth / BLIND_M, 0.0, 1.0)


## This frame's yaw for a player standing at `pos` with current `yaw`: unchanged near the inner
## rect, bending back toward the lot's centre with depth, snapped to face it outright once both
## fully blind and past SNAP_M ("quietly turned to face the lot" at the deepest point). Every
## machine calls this for its own locally-driven player (and the host for its bots), matching
## the existing rule that a player's own heading is client-owned; a carried player needs nothing
## extra here since their body simply follows the carrier who is doing the steering.
static func steer_yaw(pos: Vector3, yaw: float, level_info: Dictionary, delta: float) -> float:
	var d := depth_m(pos, level_info)
	if d <= STEER_START_M:
		return yaw
	var r := inner_rect(level_info)
	var centre := r.get_center()
	var to_lot := centre - Vector2(pos.x, pos.z)
	if to_lot.length() < 0.01:
		return yaw
	var want := atan2(-to_lot.x, -to_lot.y)
	if d >= SNAP_M and visibility01(d) >= 0.999:
		return want
	var k := clampf((d - STEER_START_M) / maxf(0.01, SNAP_M - STEER_START_M), 0.0, 1.0)
	return lerp_angle(yaw, want, clampf(k * STEER_MAX_RATE * delta, 0.0, 1.0))


## How deep in the fog, straight out from the main doors, a run's players arrive, and how far apart
## they stand side by side.
const ARRIVAL_DEPTH_M := 3.6
const ARRIVAL_SPACING_M := 1.3


## Where a run's players arrive: `count` spots in a row across the walkway to the main doors, deep in
## the south fog belt (fully blind), so they walk out of the fog toward the hospital. Empty when the
## level has no lot. The lot is centred on the main doors, so its centre line is the walkway.
static func arrival_points(level_info: Dictionary, count: int, y := 0.0) -> Array:
	var outer: Rect2 = level_info.get("neutral_rect", Rect2())
	if outer.size == Vector2.ZERO:
		return []
	var r := inner_rect(level_info)
	var z := minf(r.end.y + ARRIVAL_DEPTH_M, outer.end.y - 1.0)
	var cx := outer.get_center().x
	var out: Array = []
	for i in maxi(1, count):
		out.append(Vector3(cx + (float(i) - (count - 1) * 0.5) * ARRIVAL_SPACING_M, y, z))
	return out


## Where to put a dropped/thrown item that came to rest in the fog: pulled back onto the lot,
## just inside the clear area's edge. `pos` unchanged if it is not in the fog at all.
static func pull_from_fog(pos: Vector3, level_info: Dictionary) -> Vector3:
	if not on_lot(pos, level_info) or depth_m(pos, level_info) <= 0.0:
		return pos
	var r := inner_rect(level_info)
	var cx := clampf(pos.x, r.position.x + 0.4, r.end.x - 0.4)
	var cz := clampf(pos.z, r.position.y + 0.4, r.end.y - 0.4)
	return Vector3(cx, pos.y, cz)


# ---------------------------------------------------------------------------
# Local presentation: a per-camera screen-space fog override, cheap and local only.
# ---------------------------------------------------------------------------

## Give `cam` a fog look for `depth01` (0 clear .. 1 fully blind), or clear the override at 0.
## Builds one Environment per camera, cloned from whatever it was already using (the shared
## WorldEnvironment, normally), so brightness/tonemap/etc. keep working; only the fog fields
## move. Call every frame from the local player's camera driver (see camera_fx.gd).
static func apply_camera_fog(cam: Camera3D, depth01: float, cache: Dictionary) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	depth01 = clampf(depth01, 0.0, 1.0)
	if depth01 <= 0.001:
		if cache.has("env") and cam.environment == cache.env:
			cam.environment = cache.get("base")
		return
	if not cache.has("env"):
		var base: Environment = cam.environment
		if base == null and cam.is_inside_tree():
			var w := cam.get_world_3d()
			base = w.environment if w != null else null
		cache["base"] = cam.environment
		var env: Environment = base.duplicate() if base != null else Environment.new()
		env.fog_enabled = true
		env.fog_light_color = FOG_COLOR
		# SWEEP 4A FOLLOW-UP: 1.0 here plus a high density scattered a bright nearby light (the
		# ambulance's headlights) into a blown-out white haze instead of a dark wall of fog --
		# this is how much the fog itself re-emits/scatters ambient light, separate from real
		# lights volumetrically scattering through it. Low, so the fog reads as dark, not lit.
		env.fog_light_energy = 0.15
		env.fog_sun_scatter = 0.0
		env.fog_aerial_perspective = 0.0
		# SWEEP 4A FOLLOW-UP: override depth begin/end locally regardless of whatever the base
		# (indoor-tuned) environment uses, so the fog ramp is steep at outdoor-lot scale (metres),
		# not the corridor-scale distances look.gd tunes fog_depth_end for.
		env.fog_depth_begin = 0.0
		env.fog_depth_end = 5.0
		env.fog_depth_curve = 1.0
		cache["env"] = env
	var env: Environment = cache.env
	# SWEEP 4A FOLLOW-UP: was capped at 1.35, which still let a bright light (the flashlight)
	# visibly punch through -- "the flashlight shouldn't permeate the fog... it should just be
	# fog." High enough that transmittance over a couple of metres is effectively zero, without
	# going so high it blows out into a white haze near a bright light (see fog_light_energy above).
	env.fog_density = lerpf(0.0, 6.0, depth01)
	cam.environment = env
