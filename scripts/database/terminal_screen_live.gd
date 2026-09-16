extends Node
## HUB REDESIGN (2026-09-15): "put whatever the player is looking at onto the actual screen."
##
## A SubViewport + Camera3D mirror of the local viewer's own camera, drawn onto the terminal's
## monitor quad in place of its static idle glow -- the same SubViewport-plus-screen-quad trick the
## OR wall monitor already uses (`scripts/orscreen/or_screen.gd`), except that screen draws a 2D
## Control (`or_screen_canvas.gd`) from replicated game state, while this one renders the real 3D
## scene from a camera that copies the LOCAL player's own camera transform every frame. Purely a
## per-machine cosmetic: each machine only ever reads its own `get_viewport().get_camera_3d()` (the
## same call `or_screen.gd` already uses to find "the local viewer"), so there is no new network
## traffic and nothing here is host-authoritative.
##
## Cost control (perfprobe, docs/CONTRACTS.md): the extra render pass only happens within
## NEAR_METRES of the terminal, at REFRESH_HZ, at a small texture size; the SubViewport is fully
## disabled (no 3D render at all, not merely "not requested") outside that range, and the screen
## falls back to its static idle glow material so it never freezes on a stale frame.

const NEAR_METRES := 4.5
const REFRESH_HZ := 8.0
const TEX_SIZE := Vector2i(192, 120)

var _monitor: Node3D = null
var _screen: MeshInstance3D = null
var _idle_material: Material = null
var _live_material: StandardMaterial3D = null
var _vp: SubViewport = null
var _cam: Camera3D = null
var _active := false
var _accum := 0.0


func attach(monitor: Node3D, screen: MeshInstance3D, _size: Vector2) -> void:
	_monitor = monitor
	_screen = screen
	_idle_material = screen.material_override

	_vp = SubViewport.new()
	_vp.name = "LiveViewport"
	_vp.size = TEX_SIZE
	_vp.disable_3d = false
	_vp.own_world_3d = false   # shares this machine's own World3D: a security-camera trick, not a copy
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)

	_cam = Camera3D.new()
	_cam.name = "MirrorCam"
	_cam.current = false   # never the viewport's main camera, just what this SubViewport renders
	_vp.add_child(_cam)

	_live_material = StandardMaterial3D.new()
	_live_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_live_material.albedo_texture = _vp.get_texture()
	_live_material.emission_enabled = true
	_live_material.emission_texture = _vp.get_texture()
	_live_material.emission_energy_multiplier = 0.5


func _process(delta: float) -> void:
	if _monitor == null or not is_instance_valid(_monitor):
		return
	var vp := get_viewport()
	var live_cam := vp.get_camera_3d() if vp != null else null
	var near := false
	if live_cam != null:
		near = live_cam.global_position.distance_to(_monitor.global_position) <= NEAR_METRES
	if near != _active:
		_active = near
		_screen.material_override = _live_material if _active else _idle_material
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE if _active else SubViewport.UPDATE_DISABLED
		_accum = 0.0
	if not _active or live_cam == null:
		return
	_accum += delta
	if _accum < 1.0 / REFRESH_HZ:
		return
	_accum = 0.0
	_cam.global_transform = live_cam.global_transform
	if live_cam is Camera3D:
		_cam.fov = live_cam.fov
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


## Warmup hook: build one so its viewport and material compile behind the cover.
static func warm(parent: Node3D) -> Node:
	var mon := Node3D.new()
	parent.add_child(mon)
	var qm := QuadMesh.new()
	qm.size = Vector2(0.44, 0.27)
	var scr := MeshInstance3D.new()
	scr.mesh = qm
	var m := StandardMaterial3D.new()
	m.emission_enabled = true
	scr.material_override = m
	mon.add_child(scr)
	var live := new()
	mon.add_child(live)
	live.attach(mon, scr, qm.size)
	live._active = true
	live._screen.material_override = live._live_material
	live._vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	return mon
