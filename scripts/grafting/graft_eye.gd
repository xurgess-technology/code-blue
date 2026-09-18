class_name GraftEye
extends RefCounted
## GRAFTING chunk C (docs/GRAFTING.md): the grafted eyeball on a surgeon's body.
##
## The stylized surgeon carries each eye as its own object (`Human_Eye_L` / `Human_Eye_R`,
## art/stylized/README.md) so a graft can swap one. There is no separate `surgeon_graft` GLB in the
## game, so this is the `surgeon_graft` look built at runtime: the left eyeball is hidden and a Hive
## eyeball (the item's own shader, scripts/grafting/eyes.gd) is hung on the head bone in its place,
## with a ring of stitches round the socket.
##
## It rides a BoneAttachment3D, so it follows the head through every clip -- standing, lying on the
## table, carried -- and shows wherever the body shows: third person, other players' screens, the
## Personnel mirrors and the carry camera.
##
## `set_lock` drives the Hive eye material's `Lock`: 0 a low pinpoint, 1 the whole ball lit. Grafts
## keeps it low normally and high while the surgeon is in Hive Eyes.

const HumanModel := preload("res://scripts/human/human_model.gd")

const NODE_NAME := "GraftEye"
## How far the left eye sits from the eyes' site, along the model's left (-X).
const SIDE := 0.033
const STITCHES := 7


## Hang a grafted eyeball of `kind` on `human_root`'s head and hide `Human_Eye_L`. Returns the node
## (free it to take the graft off; the caller shows the real eye again). Null when the model has no
## skeleton or no `Site_eyes` (the primitive fallback body).
static func attach(human_root: Node, kind: String, radius := 0.0135) -> Node3D:
	if human_root == null or not is_instance_valid(human_root):
		return null
	var skel := HumanModel.skeleton(human_root)
	var site := human_root.find_child("Site_eyes", true, false) as Node3D
	if skel == null or site == null:
		return null
	var att := site.get_parent() as BoneAttachment3D
	if att == null:
		return null
	var old := att.get_node_or_null(NODE_NAME)
	if old != null:
		return old as Node3D
	var bone := skel.find_bone(att.bone_name)
	var rest := skel.get_bone_global_rest(bone) if bone >= 0 else Transform3D()
	# In the bone's frame, but with the model's own axes, so the eyeball's pupil (its -Z) faces
	# the way the model does and the socket offset goes along the model's left.
	var b := rest.basis.orthonormalized().inverse()
	var root := Node3D.new()
	root.name = NODE_NAME
	root.transform = Transform3D(b, site.transform.origin + b * Vector3(-SIDE, 0.0, 0.0))
	att.add_child(root)
	_build(root, kind, radius)
	var eye_l := HumanModel.piece(human_root, "Human_Eye_L")
	if eye_l != null:
		eye_l.visible = false
		for mi in root.find_children("*", "GeometryInstance3D", true, false):
			(mi as VisualInstance3D).layers = eye_l.layers
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


## The same thing for a body that hands over its left-eye mesh directly (the player table's
## stand-in, scripts/downed/player_body.gd).
static func build(eye_l: MeshInstance3D, kind: String, radius := 0.0135) -> Node3D:
	if eye_l == null or not is_instance_valid(eye_l):
		return null
	var root: Node3D = null
	var n: Node = eye_l
	while n != null and root == null:
		if n.has_meta("human_variant"):
			root = n as Node3D
		n = n.get_parent()
	return attach(root, kind, radius) if root != null else null


## Take the graft off `human_root` (and show the real eye again).
static func detach(human_root: Node) -> void:
	if human_root == null or not is_instance_valid(human_root):
		return
	var site := human_root.find_child("Site_eyes", true, false) as Node3D
	if site != null and site.get_parent() != null:
		var old := site.get_parent().get_node_or_null(NODE_NAME)
		if old != null:
			old.queue_free()
	var eye_l := HumanModel.piece(human_root, "Human_Eye_L")
	if eye_l != null:
		eye_l.visible = true


## The grafted eyeball on `human_root`, or null.
static func node_on(human_root: Node) -> Node3D:
	if human_root == null or not is_instance_valid(human_root):
		return null
	var site := human_root.find_child("Site_eyes", true, false) as Node3D
	if site == null or site.get_parent() == null:
		return null
	return site.get_parent().get_node_or_null(NODE_NAME) as Node3D


## The Hive eye material's `Lock` on a grafted eye: 0 a low pinpoint, 1 the whole ball lit.
static func set_lock(node: Node, v: float) -> void:
	Eyes.set_lock(node, v)


static func _build(root: Node3D, kind: String, radius: float) -> void:
	var ball := MeshInstance3D.new()
	ball.name = "EyeBall_Graft"
	var sph := SphereMesh.new()
	sph.radius = radius
	sph.height = radius * 2.0
	sph.radial_segments = 18
	sph.rings = 9
	ball.mesh = sph
	ball.material_override = Eyes.material(kind)
	root.add_child(ball)
	# The stitches the `surgeon_graft` render shows: short dark ticks radiating round the socket.
	var thread := StandardMaterial3D.new()
	thread.albedo_color = Color(0.09, 0.07, 0.11)
	thread.roughness = 0.8
	for i in STITCHES:
		var a := -PI * 0.5 + PI * (float(i) + 0.5) / float(STITCHES)
		var dir := Vector3(cos(a), sin(a), 0.0)
		var tick := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.0016, 0.0075, 0.0016)
		tick.mesh = box
		tick.material_override = thread
		var up := dir
		var fwd := Vector3.BACK
		var right := up.cross(fwd).normalized()
		tick.transform = Transform3D(Basis(right, up, right.cross(up)), dir * radius * 1.12 + Vector3(0, 0, -radius * 0.25))
		root.add_child(tick)
