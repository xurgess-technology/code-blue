extends RefCounted
## The Discharged: a gaunt patient in a stained, too-short gown, bare legs, gauze
## wound over its eyes, head cocked, one wrist still taped to the IV pole it drags.

const Shapes := preload("res://scripts/monsters/shapes.gd")
const Limbs := preload("res://scripts/monsters/limbs.gd")
const IVPole := preload("res://scripts/monsters/iv_pole.gd")

const ARM_LEN := 0.86
const LEG_LEN := 0.93


static func build(model: Node3D) -> void:
	var sh = model.shaper
	sh.cfg = {
		# Limb blocks squeezed to slivers (0.02): the bony limbs below replace them.
		"leg_len": LEG_LEN, "leg_thick": 0.02, "hip_half": 0.085, "stride": 0.9, "bob": 0.5,
		"shoulder": Vector3(0.15, 0.49, -0.02), "neck": Vector3(0.0, 0.56, 0.08),
		"arm_len": ARM_LEN, "arm_thick": 0.02, "arm_swing": 0.7, "arm_idle": 0.5,
		"hunch": 0.48, "head_pitch": 0.2, "head_roll": 0.3, "torso_sway": 1.0, "head_sway": 0.6,
		# The IV arm is held back and low; it barely swings, it is dragging something.
		"arm_l": {"back": 22.0, "spread": 7.0, "swing": 0.1, "idle": 0.1, "lunge": 0.35},
		"arm_r": {"back": -6.0, "spread": 4.0, "swing": 0.7, "idle": 0.6},
	}

	var skin := Shapes.mat(Color("8e9189"), {
		"mottle": 0.12, "vein": 0.55, "stain_col": Color("6c6a52"), "stain_amt": 0.08,
		"stain2_col": Color("4b3842"), "stain2_amt": 0.0, "stain_scale": 6.0,
		"edge_dark": 0.55, "rough": 0.58, "sss": 0.12, "seed": 3.0,
	})
	var gown := Shapes.mat(Color("73827d"), {
		"double": true, "mottle": 0.1, "weave": 0.25, "stain_col": Color("6d6348"), "stain_amt": 0.22,
		"stain_low": 1.2, "stain2_col": Color("4a1c16"), "stain2_amt": 0.12, "stain_scale": 9.0,
		"edge_dark": 0.25, "rough": 0.95, "seed": 11.0,
	})
	var gauze := Shapes.mat(Color("b9b3a2"), {
		"double": true, "mottle": 0.2, "weave": 0.6, "stain_col": Color("7d735c"), "stain_amt": 0.25,
		"stain_scale": 22.0, "rough": 1.0, "edge_dark": 0.4, "seed": 5.0,
	})
	var dark := Shapes.flat(Color("0d0605"), 0.9)
	# The wrap over the eyes has soaked through: same gauze, rust-brown from within.
	var seep := Shapes.mat(Color("a39b88"), {
		"double": true, "mottle": 0.25, "weave": 0.6, "stain_col": Color("4f3c2e"), "stain_amt": 0.55,
		"stain2_col": Color("24130e"), "stain2_amt": 0.45, "stain_scale": 30.0, "rough": 1.0, "edge_dark": 0.4, "seed": 9.0,
	})
	model.body_material(skin)

	# ---- torso: a narrow ribcage with a visible spine, under a gown open at the back
	var torso := Node3D.new()
	torso.name = "Torso"
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.06, 0.11, 0.08], [0.10, 0.092, 0.065], [0.24, 0.118, 0.085, 0.012],
		[0.38, 0.14, 0.092], [0.47, 0.135, 0.078, -0.005], [0.53, 0.05, 0.042, 0.03],
	], 16, 0.0, 0.0, 0.03, 21, true, true), skin))
	for i in 7:
		var y := 0.12 + i * 0.056
		torso.add_child(Shapes.ellipsoid(Vector3(0.016, 0.02, 0.018), skin, Vector3(0, y, -0.075 - 0.008 * sin(i * 0.5)), 8))
	for sx in [-1.0, 1.0]:
		torso.add_child(Shapes.ellipsoid(Vector3(0.045, 0.065, 0.018), skin, Vector3(sx * 0.065, 0.39, -0.08), 10))
		torso.add_child(Shapes.ellipsoid(Vector3(0.036, 0.032, 0.036), skin, Vector3(sx * 0.14, 0.485, -0.02), 10))
		var clav := Shapes.ellipsoid(Vector3(0.07, 0.011, 0.013), skin, Vector3(sx * 0.07, 0.5, 0.05), 8)
		clav.rotation.z = sx * -0.2
		torso.add_child(clav)
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.33, 0.19, 0.155, 0.03], [-0.16, 0.172, 0.14, 0.025], [0.04, 0.145, 0.112, 0.02],
		[0.24, 0.15, 0.112, 0.02], [0.40, 0.17, 0.11, 0.0], [0.49, 0.16, 0.098, 0.0], [0.53, 0.085, 0.068, 0.035],
	], 22, 1.1, 0.06, 0.05, 41), gown, Vector3.ZERO, "Gown"))
	var tie := Shapes.box(Vector3(0.012, 0.16, 0.004), gown, Vector3(0.05, 0.3, -0.115))
	tie.rotation.z = 0.2
	torso.add_child(tie)
	model.add_part(torso, "torso")

	for side in ["arm-left", "arm-right"]:
		var sgn := -1.0 if side == "arm-left" else 1.0
		Limbs.add_arm(model, side, Limbs.arm(ARM_LEN, skin, 0.9, 1.25, 31 if side == "arm-left" else 32, side == "arm-left"))
		var sleeve := Shapes.mesh_node(Shapes.lathe([
			[-0.02, 0.06, 0.062], [0.08, 0.058, 0.06], [0.15, 0.07, 0.068],
		], 12, 0.0, 0.03, 0.08, 7), gown)
		model.add_part(sleeve, side, Transform3D(Basis(Vector3.BACK, sgn * PI * 0.5), Vector3.ZERO))
	for side in ["leg-left", "leg-right"]:
		model.add_part(Limbs.leg(LEG_LEN, skin, 0.9, true, 51 if side == "leg-left" else 52), side)

	# ---- head: bald, mottled, cheeks sunk, gauze wound over and over the eyes
	var head := Node3D.new()
	head.name = "Head"
	var neck := Shapes.cylinder(0.032, 0.2, skin, Vector3(0, -0.06, -0.01), 0.028)
	neck.rotation.x = -0.3
	head.add_child(neck)
	for sx in [-1.0, 1.0]:
		var tendon := Shapes.ellipsoid(Vector3(0.01, 0.06, 0.011), skin, Vector3(sx * 0.02, -0.05, 0.028), 8)
		tendon.rotation.z = sx * 0.2
		head.add_child(tendon)
	head.add_child(Shapes.ellipsoid(Vector3(0.084, 0.108, 0.097), skin, Vector3(0, 0.12, 0.0)))
	head.add_child(Shapes.ellipsoid(Vector3(0.08, 0.09, 0.098), skin, Vector3(0, 0.15, -0.03)))
	# Hollow cheeks: a narrow jaw set in under wide cheekbones.
	head.add_child(Shapes.ellipsoid(Vector3(0.05, 0.048, 0.064), skin, Vector3(0, 0.035, 0.042)))
	for sx in [-1.0, 1.0]:
		head.add_child(Shapes.ellipsoid(Vector3(0.022, 0.016, 0.03), skin, Vector3(sx * 0.058, 0.085, 0.06), 8))
		head.add_child(Shapes.ellipsoid(Vector3(0.011, 0.026, 0.017), skin, Vector3(sx * 0.084, 0.11, -0.012), 8))
	# The jaw hangs slack.
	head.add_child(Shapes.ellipsoid(Vector3(0.024, 0.02, 0.012), dark, Vector3(0.003, 0.022, 0.1), 10))
	# Wrap after wrap of gauze, each a little crooked, sagging over the eyes.
	var wraps := [
		[0.112, 0.0, 0.03, 0.1, 0.116, 13, 0.032, true], [0.088, 0.22, 0.1, 0.098, 0.112, 17, 0.02, false],
		[0.14, -0.28, -0.06, 0.098, 0.111, 19, 0.024, false], [0.165, 0.14, 0.4, 0.09, 0.104, 23, 0.02, false],
		[0.19, -0.1, -0.5, 0.08, 0.094, 29, 0.018, false],
	]
	for wd in wraps:
		var hw: float = wd[6]
		var band := Shapes.mesh_node(Shapes.lathe([
			[-hw, wd[3], wd[4], 0.004], [0.0, wd[3] + 0.005, wd[4] + 0.005, 0.005], [hw, wd[3], wd[4], 0.003],
		], 24, 0.0, 0.0, 0.06, wd[5]), seep if wd[7] else gauze)
		band.position = Vector3(0, wd[0], 0)
		band.rotation = Vector3(wd[2], 0, wd[1])
		head.add_child(band)
	for sx in [-1.0, 1.0]:
		var drip := Shapes.ellipsoid(Vector3(0.0035, 0.024, 0.003), Shapes.flat(Color("2e120c"), 0.35), Vector3(sx * 0.036, 0.068, 0.108), 6)
		head.add_child(drip)
	var trail := Shapes.box(Vector3(0.028, 0.3, 0.003), gauze, Vector3(0.035, 0.0, -0.1))
	trail.rotation = Vector3(-0.25, 0, 0.2)
	head.add_child(trail)
	model.add_part(head, "head")

	# ---- the taped wrist and the IV pole it drags
	var tape_mat := Shapes.mat(Color("d2cbb4"), {"stain_amt": 0.4, "stain_col": Color("8b7c52"), "stain_scale": 30.0, "rough": 0.6})
	var tape := Shapes.box(Vector3(0.05, 0.035, 0.07), tape_mat)
	model.add_part(tape, "arm-left", Transform3D(Basis(), Vector3.ZERO), 0.8)
	model.iv = IVPole.new()
	model.add_child(model.iv)
