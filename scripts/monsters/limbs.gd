extends RefCounted
## Bony, tapered limbs that ride the Kenney arm and leg bones. The Kenney limb blocks are
## squeezed to a sliver by the RigShaper and these take their place, so the silhouette is
## knuckles, elbows and knees instead of planks, while the clips still drive the motion.

const Shapes := preload("res://scripts/monsters/shapes.gd")


## An arm of length `l` in metres, built along +Y from the shoulder. Attach it to an arm
## bone with the basis that turns +Y onto the bone's axis (see add_arm()).
## `finger` scales the finger length; long fingers are half the creepiness.
static func arm(l: float, skin: Material, thick := 1.0, finger := 1.0, seed := 1, left := true, hand_mat: Material = null) -> Node3D:
	# The palm faces +X of this frame on the left arm and -X on the right (see add_arm).
	var curl := 1.0 if left else -1.0
	var n := Node3D.new()
	var k := thick
	var hm: Material = hand_mat if hand_mat != null else skin
	n.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.02, 0.03 * k, 0.034 * k], [0.02, 0.043 * k, 0.046 * k], [0.14 * l, 0.036 * k, 0.04 * k],
		[0.34 * l, 0.028 * k, 0.03 * k], [0.45 * l, 0.03 * k, 0.034 * k], [0.5 * l, 0.028 * k, 0.03 * k],
		[0.62 * l, 0.029 * k, 0.027 * k], [0.8 * l, 0.02 * k, 0.024 * k], [0.86 * l, 0.017 * k, 0.021 * k],
	], 10, 0.0, 0.0, 0.05, seed, true, true), skin))
	# Elbow knob, wrist bone.
	n.add_child(Shapes.ellipsoid(Vector3(0.026, 0.03, 0.03) * k, skin, Vector3(0.004, 0.475 * l, -0.012), 8))
	n.add_child(Shapes.ellipsoid(Vector3(0.018, 0.018, 0.024) * k, hm, Vector3(0.0, 0.85 * l, 0.0), 8))
	# Hand: a flat palm facing the thigh, then four long fingers curling toward it.
	var hand := Node3D.new()
	hand.position = Vector3(0, 0.86 * l, 0)
	n.add_child(hand)
	hand.add_child(Shapes.ellipsoid(Vector3(0.013, 0.05, 0.034) * k, hm, Vector3(0, 0.045, 0), 10))
	for i in 4:
		var fz := (float(i) - 1.5) * 0.017 * k
		var fl := (0.085 + 0.012 * (1.5 - absf(float(i) - 1.5))) * finger
		var f := Node3D.new()
		f.position = Vector3(0, 0.09, fz)
		f.rotation = Vector3(0, 0, (-0.12 - 0.05 * i) * curl)
		f.add_child(Shapes.cylinder(0.0065 * k, fl * 0.55, hm, Vector3(0, fl * 0.27, 0), 0.006 * k, 6))
		var tip := Node3D.new()
		tip.position = Vector3(0, fl * 0.55, 0)
		tip.rotation.z = -0.35 * curl
		tip.add_child(Shapes.cylinder(0.006 * k, fl * 0.45, hm, Vector3(0, fl * 0.22, 0), 0.004 * k, 6))
		tip.add_child(Shapes.ellipsoid(Vector3(0.007, 0.008, 0.007) * k, hm, Vector3.ZERO, 6))
		f.add_child(tip)
		hand.add_child(f)
	var thumb := Shapes.cylinder(0.007 * k, 0.06 * finger, hm, Vector3(0.012 * curl, 0.03, 0.03 * k), 0.005 * k, 6)
	thumb.rotation = Vector3(0.5, 0, -0.3 * curl)
	hand.add_child(thumb)
	return n


## A leg of length `l`, hanging down -Y from the hip, with a knee knob and a long foot
## pointing +Z. `foot` false leaves the foot off (shoes are added separately).
static func leg(l: float, skin: Material, thick := 1.0, foot := true, seed := 1) -> Node3D:
	var n := Node3D.new()
	var k := thick
	n.add_child(Shapes.mesh_node(Shapes.lathe([
		[-l + 0.02, 0.022 * k, 0.026 * k], [-0.88 * l, 0.026 * k, 0.03 * k], [-0.72 * l, 0.036 * k, 0.042 * k, -0.006],
		[-0.56 * l, 0.034 * k, 0.037 * k], [-0.5 * l, 0.036 * k, 0.04 * k, 0.004], [-0.4 * l, 0.042 * k, 0.046 * k],
		[-0.15 * l, 0.054 * k, 0.058 * k], [0.02, 0.058 * k, 0.062 * k],
	], 12, 0.0, 0.0, 0.04, seed, true, true), skin))
	n.add_child(Shapes.ellipsoid(Vector3(0.032, 0.036, 0.026) * k, skin, Vector3(0, -0.5 * l, 0.022 * k), 8))
	if foot:
		var f := Node3D.new()
		f.position = Vector3(0, -l + 0.03, 0)
		f.add_child(Shapes.ellipsoid(Vector3(0.036, 0.024, 0.12) * k, skin, Vector3(0, 0.0, 0.06), 10))
		f.add_child(Shapes.ellipsoid(Vector3(0.028, 0.03, 0.04) * k, skin, Vector3(0, 0.012, -0.02), 8))
		for i in 4:
			f.add_child(Shapes.ellipsoid(Vector3(0.008, 0.009, 0.018) * k, skin, Vector3((float(i) - 1.5) * 0.017, -0.006, 0.18), 6))
		n.add_child(f)
	return n


## Attach an arm built by arm() to a side ("arm-left" or "arm-right").
static func add_arm(model: Node3D, side: String, node: Node3D) -> void:
	var sgn := -1.0 if side == "arm-left" else 1.0
	model.add_part(node, side, Transform3D(Basis(Vector3.BACK, sgn * PI * 0.5), Vector3.ZERO))
