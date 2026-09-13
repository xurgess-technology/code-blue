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
