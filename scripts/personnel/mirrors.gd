extends Node3D
## Personnel's mirrors, reflecting for real: the big full-length mirror and the one over every sink.
##
## Each mirror is a SubViewport with its own camera, reflected across the glass every frame from
## wherever the local camera is. The camera looks straight through the glass (an off-axis frustum
## fitted exactly to it, the near plane on the glass so the wall behind never shows), and the
## picture goes on a quad over the glass, flipped left to right.
##
## A mirror is a whole extra render of the scene, so not all of them run at once:
##   - the big mirror renders every frame while you can see it;
##   - of the sink mirrors you can see, the nearest renders every frame and the rest take turns,
##     one a frame, holding their last picture in between;
##   - a mirror you can't see (behind you, off screen, too far, or you're behind the wall) doesn't
##     render at all.
## While any mirror is rendering, the local player's own body is shown to the mirror cameras only
## (Player.set_mirror_self, on LightRooms.SELF, which the first-person camera leaves out), so you see
## yourself in them.
##
## The glass sizes and places below match piece_factory.gd's "full_mirror" and "vanity".

const LightRooms := preload("res://scripts/level/light_rooms.gd")

## The big mirror's glass: size, and its centre in the piece's frame (wall-mounted: origin at the
## wall face, -Z out into the room).
const BIG_GLASS := Vector2(1.58, 2.66)
const BIG_MOUNT := 0.06
const BIG_CENTRE := Vector3(0.0, BIG_MOUNT + 1.43, -0.05)
## A sink's mirror: size, and its centre in the vanity's frame (origin at its footprint's centre).
const SINK_GLASS := Vector2(0.76, 0.92)
const SINK_CENTRE := Vector3(0.0, 1.68, 0.275 - 0.042)
## Picture resolution, pixels per metre of glass.
const BIG_PPM := 380.0
const SINK_PPM := 260.0
## Beyond these distances (metres) a mirror stops rendering.
const BIG_RANGE := 24.0
const SINK_RANGE := 14.0
## The mirror cameras see everything the first-person camera does except the first-person hands
## (fp_hands.gd HANDS_LAYER) and the dev gun's first-person model (dev_room.gd GUN_FP_LAYER), plus
## the local player's own body. Plain numbers: piece_factory.gd preloads this script, and map
## generation runs where the autoloads those scripts need don't exist.
const HIDE_FROM_MIRRORS := (1 << 18) | (1 << 17)

class Mirror extends RefCounted:
	var big := false
	var size := Vector2.ONE
	var root: Node3D          # at the glass's centre, +Z out of the glass into the room
	var viewport: SubViewport
	var cam: Camera3D
	var shown := false        # has a picture (rendered at least once)

var _mirrors: Array[Mirror] = []
var _turn := 0
var _self_on := false


## `spots` is level_info.personnel's builder form (tile-space spots; see entrance.gd), converted by
## `to_world` (tile position, height -> Vector3).
func setup(spots: Dictionary, to_world: Callable) -> void:
	name = "Mirrors"
	set_meta("light_dynamic", true)   # light_rooms.gd: leave its layers alone
	var m: Dictionary = spots.get("mirror", {})
	if not m.is_empty():
		_add(true, BIG_GLASS, _glass_xform(m, BIG_CENTRE, to_world), BIG_PPM)
	for s in spots.get("sinks", []):
		_add(false, SINK_GLASS, _glass_xform(s, SINK_CENTRE, to_world), SINK_PPM)


func _glass_xform(spot: Dictionary, centre: Vector3, to_world: Callable) -> Transform3D:
	var basis := Basis(Vector3.UP, float(spot.yaw))
	var origin: Vector3 = to_world.call(spot.pos, 0.0)
	# Turned half round, so +Z points out of the glass (the piece's front is -Z).
	return Transform3D(basis * Basis(Vector3.UP, PI), origin + basis * centre)


func _add(big: bool, glass: Vector2, xf: Transform3D, ppm: float) -> void:
	var mr := Mirror.new()
	mr.big = big
	mr.size = glass
	mr.root = Node3D.new()
	mr.root.name = "BigMirror" if big else "SinkMirror%d" % _mirrors.size()
	mr.root.transform = xf   # world space: this node and the level root sit at the origin
	add_child(mr.root)
	mr.viewport = SubViewport.new()
	mr.viewport.size = Vector2i(maxi(16, int(glass.x * ppm)), maxi(16, int(glass.y * ppm)))
	mr.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	mr.viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	mr.viewport.handle_input_locally = false
	mr.viewport.gui_disable_input = true
	mr.root.add_child(mr.viewport)
	mr.cam = Camera3D.new()
	mr.cam.projection = Camera3D.PROJECTION_FRUSTUM
	mr.cam.keep_aspect = Camera3D.KEEP_HEIGHT
	mr.viewport.add_child(mr.cam)
	var quad := MeshInstance3D.new()
	quad.name = "Glass"
	var qm := QuadMesh.new()
	qm.size = glass
	quad.mesh = qm
	quad.position = Vector3(0, 0, 0.004)   # just proud of the glass box
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = mr.viewport.get_texture()
	mat.albedo_color = Color(0.9, 0.93, 0.94)   # a little grey, like old silvering
	mat.uv1_scale = Vector3(-1, 1, 1)           # a mirror: left and right swap
	mat.uv1_offset = Vector3(1, 0, 0)
	quad.material_override = mat
	mr.root.add_child(quad)
	_mirrors.append(mr)


func _exit_tree() -> void:
	_set_self(false)


func _process(_delta: float) -> void:
	var main := get_viewport().get_camera_3d()
	if main == null or _mirrors.is_empty():
		_set_self(false)
		return
	var eye := main.global_position
	var big_live: Mirror = null
	var sinks: Array[Mirror] = []
	for mr in _mirrors:
		if _can_see(mr, main, eye):
			if mr.big:
				big_live = mr
			else:
				sinks.append(mr)
		else:
			mr.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var any := big_live != null or not sinks.is_empty()
	_set_self(any)
	if not any:
		return
	var mask := (main.cull_mask & ~HIDE_FROM_MIRRORS) | LightRooms.SELF
	if big_live != null:
		_render(big_live, eye, mask, SubViewport.UPDATE_ALWAYS)
	if sinks.is_empty():
		return
	sinks.sort_custom(func(a: Mirror, b: Mirror) -> bool:
		return eye.distance_squared_to(a.root.global_position) < eye.distance_squared_to(b.root.global_position))
	_render(sinks[0], eye, mask, SubViewport.UPDATE_ALWAYS)
	if sinks.size() == 1:
		return
	# The rest take turns; one that has never had a picture goes first.
	var rest := sinks.slice(1)
	var pick: Mirror = null
	for mr in rest:
		if not mr.shown:
			pick = mr
			break
	if pick == null:
		_turn = (_turn + 1) % rest.size()
		pick = rest[_turn]
	for mr in rest:
		if mr != pick:
			mr.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_render(pick, eye, mask, SubViewport.UPDATE_ONCE)


## In front of the glass, near enough, and some part of the glass on screen.
func _can_see(mr: Mirror, main: Camera3D, eye: Vector3) -> bool:
	var xf := mr.root.global_transform
	var n := xf.basis.z
	if (eye - xf.origin).dot(n) < 0.05:
		return false
	if eye.distance_to(xf.origin) > (BIG_RANGE if mr.big else SINK_RANGE):
		return false
	var hx := xf.basis.x * mr.size.x * 0.5
	var hy := xf.basis.y * mr.size.y * 0.5
	for p in [xf.origin, xf.origin + hx + hy, xf.origin - hx + hy, xf.origin + hx - hy, xf.origin - hx - hy]:
		if main.is_position_in_frustum(p):
			return true
	return false


## Reflect the camera across the glass and fit its frustum to the glass's edges.
func _render(mr: Mirror, eye: Vector3, mask: int, mode: int) -> void:
	var xf := mr.root.global_transform
	var n := xf.basis.z.normalized()
	var up := xf.basis.y.normalized()
	var right := xf.basis.x.normalized()
	var p := xf.origin
	var d := (eye - p).dot(n)
	var ref := eye - n * (2.0 * d)
	# Looking out of the glass (+n) from behind it: its right is the glass's left.
	mr.cam.global_transform = Transform3D(Basis(-right, up, -n), ref)
	var to_glass := p - ref
	mr.cam.set_frustum(mr.size.y, Vector2(to_glass.dot(-right), to_glass.dot(up)), maxf(0.02, d), 60.0)
	mr.cam.cull_mask = mask
	mr.viewport.render_target_update_mode = mode
	mr.shown = true


## Show the local player's body to the mirror cameras (and only them) while any mirror renders.
func _set_self(on: bool) -> void:
	var g := get_tree().get_first_node_in_group("game") if is_inside_tree() else null
	var p = g.local_player() if g != null and g.has_method("local_player") else null
	if p == null or not p.has_method("set_mirror_self"):
		_self_on = false
		return
	var want: bool = on and bool(p.alive) and not bool(p.downed)
	if want != _self_on or bool(p.get("_mirror_self")) != want:
		_self_on = want
		p.set_mirror_self(want)
