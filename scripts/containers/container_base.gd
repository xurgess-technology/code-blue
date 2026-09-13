extends Node3D
## Base for every searchable container (see docs/CONTRACTS.md, "Containers").
##
## A container node is in the groups "container" and "interactable" and carries the meta
## `interact_id` ("ct_<tx>_<ty>_<n>"). Subclasses build their visuals and colliders, register
## slots with `add_slot()` and pose themselves in `_apply_pose(t)` for t in 0 (closed) .. 1 (open).
##
## Extras beyond the contract: `slot_node(i)` (a marker that moves with the slot) and the
## `open_changed` signal.

signal open_changed(open: bool)

const Mats := preload("res://scripts/containers/container_mats.gd")

const NOISE_LOUDNESS := 0.5

var container_type: String = ""
var display_name: String = "container"
## Seconds the open / close animation takes.
var open_time := 0.45
var close_time := 0.35
var sound_open := ""
var sound_close := ""

var _open := false
var _pose := 0.0
var _tween: Tween = null
var _slots: Array[Node3D] = []


func init_container(type: String, id: String) -> void:
	container_type = type
	name = id
	set_meta("interact_id", id)
	add_to_group("container")
	add_to_group("interactable")


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------

func slot_count() -> int:
	return _slots.size()


func slot_transform(i: int) -> Transform3D:
	if i < 0 or i >= _slots.size():
		return _global_of(self)
	return _global_of(_slots[i])


func slot_node(i: int) -> Node3D:
	return _slots[i] if i >= 0 and i < _slots.size() else null


func is_open() -> bool:
	return _open


func set_open(open: bool, animate: bool = true) -> void:
	if open == _open and (_tween == null or not _tween.is_running()):
		_apply_pose(1.0 if open else 0.0)
		return
	_open = open
	if _tween != null:
		_tween.kill()
		_tween = null
	var target := 1.0 if open else 0.0
	if animate and is_inside_tree():
		_tween = create_tween()
		_tween.tween_method(_set_pose, _pose, target, open_time if open else close_time) \
				.set_trans(_trans(open)).set_ease(Tween.EASE_OUT if open else Tween.EASE_IN_OUT)
		_on_animate(open)
		_play(sound_open if open else sound_close)
	else:
		_set_pose(target)
	open_changed.emit(open)


func interact_prompt(_player) -> String:
	return ("Close " if _open else "Open ") + display_name


func interact_hold() -> float:
	return 0.0


## Host only. Toggles; opening makes noise the monsters can hear.
func interact(_player) -> void:
	var opening := not _open
	set_open(opening, true)
	if opening:
		_emit_noise()


# ---------------------------------------------------------------------------
# For subclasses
# ---------------------------------------------------------------------------

## Pose the moving parts. t is 0 closed .. 1 open (may overshoot slightly with TRANS_BACK).
func _apply_pose(_t: float) -> void:
	pass


## Called when an animated open/close starts (lights, extra sounds).
func _on_animate(_open_now: bool) -> void:
	pass


func _trans(open: bool) -> Tween.TransitionType:
	return Tween.TRANS_CUBIC if open else Tween.TRANS_QUAD


func add_slot(parent: Node3D, xform: Transform3D) -> Node3D:
	var m := Marker3D.new()
	m.name = "Slot%d" % _slots.size()
	m.transform = xform
	m.gizmo_extents = 0.05
	parent.add_child(m)
	_slots.append(m)
	return m


func _set_pose(t: float) -> void:
	_pose = t
	_apply_pose(t)


func _play(cue: String) -> void:
	if cue == "" or not is_inside_tree():
		return
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play"):
		audio.call("play", cue, global_position + Vector3.UP, 0.0, 0.06)


func _emit_noise() -> void:
	if not is_inside_tree():
		return
	var game := get_tree().get_first_node_in_group("game")
	if game != null and game.has_method("emit_noise"):
		game.call("emit_noise", global_position, NOISE_LOUDNESS, "container")


## Global transform that also works before the node is in the tree.
static func _global_of(n: Node3D) -> Transform3D:
	if n.is_inside_tree():
		return n.global_transform
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur is Node3D:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# ---------------------------------------------------------------------------
# Building helpers
# ---------------------------------------------------------------------------

static func box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, nm := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	if nm != "":
		mi.name = nm
	parent.add_child(mi)
	return mi


static func cyl(parent: Node3D, r: float, h: float, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO, sides := 10) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = sides
	cm.rings = 1
	mi.mesh = cm
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi


## Merge the direct MeshInstance3D children of `parent` into one MeshInstance3D with a surface per
## material, so a container costs a handful of draw calls instead of dozens. `keep` children
## (animated materials, say) are left alone.
static func bake(parent: Node3D, keep: Array = []) -> void:
	var by_mat := {}
	var order: Array = []
	var victims: Array = []
	for child in parent.get_children():
		if not (child is MeshInstance3D) or keep.has(child):
			continue
		var mi := child as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() != 1:
			continue
		var mat: Material = mi.material_override if mi.material_override != null else mi.mesh.surface_get_material(0)
		if not by_mat.has(mat):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			by_mat[mat] = st
			order.append(mat)
		(by_mat[mat] as SurfaceTool).append_from(mi.mesh, 0, mi.transform)
		victims.append(mi)
	if victims.size() < 2:
		return
	var mesh := ArrayMesh.new()
	for mat in order:
		var st: SurfaceTool = by_mat[mat]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	for v in victims:
		parent.remove_child(v)
		v.free()
	var merged := MeshInstance3D.new()
	merged.name = "Baked"
	merged.mesh = mesh
	parent.add_child(merged)


## A StaticBody3D with one box shape. layer is C.L_WORLD or C.L_INTERACT.
static func collider(parent: Node3D, layer: int, size: Vector3, pos: Vector3, nm: String) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.name = nm
	sb.collision_layer = layer
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	sb.add_child(cs)
	parent.add_child(sb)
	return sb
