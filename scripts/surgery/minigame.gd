class_name Minigame
extends Node3D
## Base class for every surgery step. THIS FILE IS A CONTRACT: the surgery system, the
## minigame lab and every individual minigame depend on it. Do not change a signature
## without updating all of them.
##
## A minigame lives on a flat "work plane" laid on the patient at a site marker.
## The node's own transform IS the plane: local X and Z span the plane, local +Y points
## up out of the patient's body. Units are metres, origin is the site marker.
##
## Who runs what:
##   - Every machine instantiates the minigame and calls tick() so it animates.
##   - Only the operating player's machine calls handle_cursor(); it is the authority for
##     that step's progress and botches (co-op with friends: we trust the operator).
##   - The operator's net_state() is relayed through the host to everyone else, who call
##     apply_net_state() so spectators see the tool move.
##   - bot_input() lets tests play the step without a human.

## Vitals damage from a mistake. The host applies it and it costs nothing else.
signal botched(amount: float, reason: String)
## The step is done. `result` is merged into the case flags that later steps read
## (e.g. {"sedation": 0.8} or {"tourniquet": 0.95}).
signal finished(result: Dictionary)

## Everything the step needs to know. Keys the surgery system always provides:
##   patient_id: String, patient: Dictionary (Procedures.PATIENTS entry)
##   ailment_id: String, step: Dictionary (Procedures step), variant: String
##   shift: int, difficulty: float (Procedures.difficulty)
##   flags: Dictionary, results of earlier steps (sedation, tourniquet, ...)
##   seed: int, deterministic per case and step
##   body: Node3D, the PatientBody on the table (may be null in the lab)
##   operator: bool, true on the machine whose player is doing this step
## Optional:
##   helper_lights: Callable -> Array of SpotLight3D, the flashlights of teammates standing by (on,
##     not the operator's). Every machine has them (their aim and on/off are replicated), so a step
##     can use helper_light() to let a teammate's light help on everyone's screen.
var ctx: Dictionary = {}
## 0..1, shown on the HUD and used by the surgery system to know how far along we are.
var progress: float = 0.0
var done: bool = false

const BUTTON_PRIMARY := 1
const BUTTON_SECONDARY := 2

## Render layer 20, reserved for a minigame's own props (tools, straps, raised wound models).
## Every decal, the patient's and the minigames', projects only onto layer 1 (cull_mask = 1),
## so props here are never painted by them. Cameras keep the default cull mask.
const OWN_LAYER := 1 << 19


func setup(context: Dictionary) -> void:
	ctx = context


## Half-size of the area the cursor may move over, in metres, around the site.
func plane_extent() -> Vector2:
	return Vector2(0.35, 0.25)


## Where the operator's camera sits, relative to the site. The surgery system tweens to it.
##   height: metres above the plane along its +Y
##   back: metres pulled back along the plane's +Z so the view is slightly angled
##   fov: camera field of view
func camera_pose() -> Dictionary:
	return {"height": 0.55, "back": 0.18, "fov": 55.0}


## Operator only. `p` is the cursor on the plane in metres (clamped to plane_extent),
## `buttons` is a bitmask of BUTTON_* currently held.
func handle_cursor(_p: Vector2, _buttons: int, _delta: float) -> void:
	pass


## Operator only. The patient just jerked (an underdosed stir): for the next `duration` seconds
## the framework adds a decaying shake of up to `offset` metres to the cursor it passes to
## handle_cursor. `strength` is 0..1. React here instead of guessing jolts from cursor jumps.
func on_jolt(_offset: Vector2, _strength: float, _duration: float) -> void:
	pass


## Every machine, every physics frame while the step is on screen.
func tick(_delta: float) -> void:
	pass


## What the HUD should show for this step:
##   title: String, hint: String, progress: float 0..1
##   gauges: Array of {label, value, min, max, good_min, good_max}
func hud_state() -> Dictionary:
	return {"title": String(ctx.get("step", {}).get("label", "")), "hint": "", "progress": progress, "gauges": []}


## Small dictionary describing what spectators need to draw (tool position, stage).
## Sent about 20 times a second; keep it tiny.
func net_state() -> Dictionary:
	return {"p": progress}


func apply_net_state(s: Dictionary) -> void:
	progress = float(s.get("p", progress))


## Scripted input for tests. `t` is seconds since the step began, `skill` is 1.0 for a
## competent surgeon and 0.0 for a sloppy one. Returns {"cursor": Vector2, "buttons": int}.
func bot_input(_t: float, _skill: float) -> Dictionary:
	return {"cursor": Vector2.ZERO, "buttons": 0}


## Helpers for subclasses -----------------------------------------------------

static var _shader_cache := {}

## One Shader resource per distinct source, shared by every instance of every minigame.
## Building a new Shader for each step made the renderer compile it again every time,
## which showed up as a 60 to 140 ms frame whenever a step began.
static func cached_shader(code: String) -> Shader:
	var sh: Shader = _shader_cache.get(code)
	if sh == null:
		sh = Shader.new()
		sh.code = code
		_shader_cache[code] = sh
	return sh


func botch(amount: float, reason: String) -> void:
	botched.emit(amount, reason)


func finish(result: Dictionary = {}) -> void:
	if done:
		return
	done = true
	progress = 1.0
	finished.emit(result)


## How much teammates' flashlights (ctx.helper_lights) light this site: {"amount": 0..1, "spot":
## Vector2 where the brightest beam meets the plane, plane metres}. A light counts when it is on,
## above the plane, within HELPER_RANGE and aimed at the site (full inside half its cone, none past
## the cone's edge), with nothing solid in between. Line of sight is re-checked every HELPER_RAY_EVERY s.
const HELPER_RANGE := 4.0
const HELPER_RAY_EVERY := 0.25
var _helper_los := {}              # light instance id -> [clear: bool, checked_at: msec]

func helper_light() -> Dictionary:
	var out := {"amount": 0.0, "spot": Vector2.ZERO}
	var src = ctx.get("helper_lights")
	if not (src is Callable) or not (src as Callable).is_valid() or not is_inside_tree():
		return out
	var site := global_transform
	var n := site.basis.y.normalized()
	var inv := site.affine_inverse()
	var now := Time.get_ticks_msec()
	for l in (src as Callable).call():
		var light := l as SpotLight3D
		if light == null or not is_instance_valid(light) or not light.is_visible_in_tree():
			continue
		var from := light.global_position
		var to_site := site.origin - from
		var d := to_site.length()
		if d < 0.05 or d > minf(HELPER_RANGE, light.spot_range) or n.dot(-to_site) <= 0.0:
			continue
		var aim := -light.global_basis.z.normalized()
		var ang := rad_to_deg(acos(clampf(aim.dot(to_site / d), -1.0, 1.0)))
		var cone := light.spot_angle
		var k := 1.0 - smoothstep(cone * 0.5, cone, ang)
		k *= 1.0 - smoothstep(HELPER_RANGE * 0.6, HELPER_RANGE, d)
		k *= clampf(light.light_energy / 3.0, 0.0, 1.0)
		if k <= 0.001 or k <= float(out.amount):
			continue
		if not _helper_clear(light, from, site.origin + n * 0.03, now):
			continue
		var la := inv.basis * aim
		var lf := inv * from
		var spot := Vector2.ZERO
		if la.y < -0.05:
			var t := -lf.y / la.y
			spot = Vector2(lf.x + la.x * t, lf.z + la.z * t)
		out = {"amount": k, "spot": spot.limit_length(0.25)}
	return out


func _helper_clear(light: Node, from: Vector3, to: Vector3, now: int) -> bool:
	var id := light.get_instance_id()
	var rec: Array = _helper_los.get(id, [])
	if not rec.is_empty() and now - int(rec[1]) < int(HELPER_RAY_EVERY * 1000.0):
		return bool(rec[0])
	var clear := true
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = C.L_WORLD
		clear = space.intersect_ray(q).is_empty()
	_helper_los[id] = [clear, now]
	return clear


## Plane-local 2D point (metres) to a local 3D position on the plane, lifted by `lift`.
func plane_to_local(p: Vector2, lift: float = 0.0) -> Vector3:
	return Vector3(p.x, lift, p.y)


## Shared by the surgery system and the lab: where a screen position lands on a work plane.
## Returns null when the ray is parallel to the plane or behind the camera.
static func screen_to_plane(camera: Camera3D, screen_pos: Vector2, plane_global: Transform3D):
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var n := plane_global.basis.y.normalized()
	var denom := n.dot(dir)
	if absf(denom) < 1e-5:
		return null
	var t := n.dot(plane_global.origin - origin) / denom
	if t < 0.0:
		return null
	var hit := origin + dir * t
	var local := plane_global.affine_inverse() * hit
	return Vector2(local.x, local.z)
