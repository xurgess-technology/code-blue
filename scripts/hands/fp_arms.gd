extends RefCounted
## The first-person forearms and hands (docs/CONTRACTS.md "Player: hands", the arms seam).
##
## `make_arm(side, colour)` is the only function the rest of the game calls: it returns a Node3D whose
## origin is the palm socket (scripts/hands/grips.gd axes: -Z fingers, +Y out of the palm, +X the
## hand's right) with the wrist and a scrub sleeve running back along +Z toward the elbow. Swapping in
## the Blender human's arms means returning that model from here, posed so its palm sits on the
## origin, with the same two optional children: "Fingers" (rotated about X to curl, 0 open ..
## CURL_MAX closed) and "Thumb". The low-poly primitives below are about 180 triangles per arm.

const ItemModelsScript := preload("res://scripts/item_models.gd")

## Radians the finger joints bend at curl 1 (a fist around a handle).
const CURL_MAX := 1.55
const SKIN := Color("d9ad8c")
## Drawn size of the hand and forearm against a real one.
const HAND_SCALE := 0.84

static var _mesh_cache := {}   # "hand|side" / "sleeve|colour" -> ArrayMesh
static var _mats := {}


static func make_arm(side: float, colour: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Arm" + ("R" if side > 0.0 else "L")
	# Everything is built at a real hand's size and drawn a little smaller (HAND_SCALE): at arm's
	# length in front of the camera a true-size hand fills too much of the view. The socket (the
	# root's origin) stays where the palm is.
	var rig := Node3D.new()
	rig.name = "Rig"
	rig.scale = Vector3.ONE * HAND_SCALE
	root.add_child(rig)
	var body := MeshInstance3D.new()
	body.name = "Palm"
	body.mesh = _hand_mesh(side)
	rig.add_child(body)
	var sleeve := MeshInstance3D.new()
	sleeve.name = "Sleeve"
	sleeve.mesh = _sleeve_mesh(colour)
	rig.add_child(sleeve)
	# Fingers: two segments from the knuckles, each its own pivot so the hand can close.
	var knuckle := Node3D.new()
	knuckle.name = "Fingers"
	knuckle.position = Vector3(0.0, -0.013, -0.046)
	rig.add_child(knuckle)
	var seg1 := MeshInstance3D.new()
	seg1.mesh = _box_mesh("finger1", Vector3(0.078, 0.021, 0.046), Vector3(0.0, 0.0, -0.023))
	knuckle.add_child(seg1)
	var mid := Node3D.new()
	mid.name = "Mid"
	mid.position = Vector3(0.0, 0.0, -0.046)
	knuckle.add_child(mid)
	var seg2 := MeshInstance3D.new()
	seg2.mesh = _box_mesh("finger2", Vector3(0.074, 0.019, 0.036), Vector3(0.0, 0.0, -0.018))
	mid.add_child(seg2)
	var thumb := Node3D.new()
	thumb.name = "Thumb"
	thumb.position = Vector3(side * 0.04, -0.012, 0.012)
	rig.add_child(thumb)
	var tm := MeshInstance3D.new()
	tm.mesh = _box_mesh("thumb", Vector3(0.024, 0.022, 0.058), Vector3(0.0, 0.0, -0.029))
	thumb.add_child(tm)
	set_curl(root, 0.2, side)
	return root


## 0 open .. 1 closed. The thumb swings in over the fingers as the hand closes.
static func set_curl(arm: Node3D, curl: float, side: float) -> void:
	var f := arm.get_node_or_null("Rig/Fingers") as Node3D
	if f != null:
		f.rotation.x = CURL_MAX * 0.55 * curl + 0.08
		var m := f.get_node_or_null("Mid") as Node3D
		if m != null:
			m.rotation.x = CURL_MAX * 0.75 * curl + 0.05
	var t := arm.get_node_or_null("Rig/Thumb") as Node3D
	if t != null:
		t.rotation = Vector3(0.25 + 0.7 * curl, side * lerpf(0.55, -0.15, curl), side * lerpf(0.2, 0.9, curl))


static func _mat(key: String, col: Color, rough: float) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.resource_name = "fp_arms_" + key
	_mats[key] = m
	return m


static func _hand_mesh(side: float) -> ArrayMesh:
	var key := "hand|%d" % int(side)
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var skin := _mat("skin", SKIN, 0.75)
	var parts: Array = []
	var palm := BoxMesh.new()
	palm.size = Vector3(0.086, 0.03, 0.094)
	parts.append([palm, 0, Transform3D(Basis(), Vector3(0.0, -0.017, 0.0)), skin])
	# The heel of the hand under the thumb, a little fuller.
	var heel := BoxMesh.new()
	heel.size = Vector3(0.036, 0.028, 0.05)
	parts.append([heel, 0, Transform3D(Basis(), Vector3(side * 0.026, -0.012, 0.024)), skin])
	var wrist := CylinderMesh.new()
	wrist.top_radius = 0.027
	wrist.bottom_radius = 0.031
	wrist.height = 0.09
	wrist.radial_segments = 8
	wrist.rings = 1
	var along_z := Basis(Vector3.RIGHT, PI * 0.5)
	parts.append([wrist, 0, Transform3D(along_z.scaled(Vector3(1.25, 1.0, 1.0)), Vector3(0.0, -0.018, 0.085)), skin])
	var mesh := ItemModelsScript.merge_parts(parts, 100000)
	_mesh_cache[key] = mesh
	return mesh


static func _sleeve_mesh(colour: Color) -> ArrayMesh:
	var key := "sleeve|%s" % colour.to_html(false)
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var cloth := _mat("sleeve_" + colour.to_html(false), colour.darkened(0.12), 0.95)
	var cuff := _mat("cuff_" + colour.to_html(false), colour.darkened(0.3), 0.95)
	var parts: Array = []
	var along_z := Basis(Vector3.RIGHT, PI * 0.5)
	var sleeve := CylinderMesh.new()
	sleeve.top_radius = 0.046    # +Y of the cylinder is toward the wrist after the turn below
	sleeve.bottom_radius = 0.06
	sleeve.height = 0.36
	sleeve.radial_segments = 8
	sleeve.rings = 1
	# Rotated so its top points at -Z (the wrist), centred behind the cuff.
	parts.append([sleeve, 0, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5).scaled(Vector3(1.15, 1.0, 1.0)), Vector3(0.0, -0.02, 0.29)), cloth])
	var band := CylinderMesh.new()
	band.top_radius = 0.049
	band.bottom_radius = 0.049
	band.height = 0.025
	band.radial_segments = 8
	band.rings = 1
	parts.append([band, 0, Transform3D(along_z.scaled(Vector3(1.15, 1.0, 1.0)), Vector3(0.0, -0.02, 0.112)), cuff])
	var mesh := ItemModelsScript.merge_parts(parts, 100000)
	_mesh_cache[key] = mesh
	return mesh


static func _box_mesh(key: String, size: Vector3, offset: Vector3) -> ArrayMesh:
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var b := BoxMesh.new()
	b.size = size
	var mesh := ItemModelsScript.merge_parts([[b, 0, Transform3D(Basis(), offset), _mat("skin", SKIN, 0.75)]], 100000)
	_mesh_cache[key] = mesh
	return mesh


## The torch the right hand holds: its lens at -Z, the handle centred on the origin (a fist grip).
static func make_torch() -> Node3D:
	var root := Node3D.new()
	root.name = "Torch"
	var metal := _mat("torch_metal", Color("2a2c30"), 0.4)
	metal.metallic = 0.6
	var parts: Array = []
	var along_z := Basis(Vector3.RIGHT, PI * 0.5)
	var body := CylinderMesh.new()
	body.top_radius = 0.021
	body.bottom_radius = 0.021
	body.height = 0.2
	body.radial_segments = 10
	body.rings = 1
	parts.append([body, 0, Transform3D(along_z, Vector3(0.0, 0.0, -0.01)), metal])
	var head := CylinderMesh.new()
	head.top_radius = 0.022
	head.bottom_radius = 0.031
	head.height = 0.05
	head.radial_segments = 10
	head.rings = 1
	parts.append([head, 0, Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 0.0, -0.125)), metal])
	var mi := MeshInstance3D.new()
	mi.mesh = ItemModelsScript.merge_parts(parts, 100000)
	root.add_child(mi)
	var lens := MeshInstance3D.new()
	var lm := CylinderMesh.new()
	lm.top_radius = 0.027
	lm.bottom_radius = 0.027
	lm.height = 0.004
	lm.radial_segments = 10
	lm.rings = 1
	lens.mesh = lm
	var glow := _mat("torch_lens", Color(1.0, 0.92, 0.75), 0.2)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.86, 0.62)
	glow.emission_energy_multiplier = 2.2
	lens.material_override = glow
	lens.transform = Transform3D(along_z, Vector3(0.0, 0.0, -0.151))
	lens.name = "Lens"
	root.add_child(lens)
	return root
