extends RefCounted
## The Night Nurse: too tall and too thin, in old-fashioned whites and a folded cap,
## long grey hands hanging at its sides, and a surgical mask where a face should be.

const Shapes := preload("res://scripts/monsters/shapes.gd")
const Limbs := preload("res://scripts/monsters/limbs.gd")

const ARM_LEN := 0.98
const LEG_LEN := 1.12


static func build(model: Node3D) -> void:
	var sh = model.shaper
	sh.cfg = {
		"leg_len": LEG_LEN, "leg_thick": 0.02, "hip_half": 0.065, "stride": 0.5, "bob": 0.15,
		"shoulder": Vector3(0.14, 0.6, 0.0), "neck": Vector3(0.0, 0.74, 0.035),
		"arm_len": ARM_LEN, "arm_thick": 0.02, "arm_swing": 0.05, "arm_idle": 0.0,
		"hunch": 0.06, "head_pitch": 0.22, "head_roll": 0.14, "torso_sway": 0.25, "head_sway": 0.0,
		"arm_l": {"back": -4.0, "spread": 3.0, "swing": 0.05, "idle": 0.0},
		"arm_r": {"back": -4.0, "spread": 3.0, "swing": 0.05, "idle": 0.0},
	}

	var whites := Shapes.mat(Color("bdbab0"), {
		"mottle": 0.07, "weave": 0.25, "stain_col": Color("a39468"), "stain_amt": 0.16, "stain_low": 0.8,
		"stain2_col": Color("5a2a1e"), "stain2_amt": 0.05, "stain_scale": 12.0, "edge_dark": 0.35,
		"rough": 0.9, "seed": 2.0,
	})
	var skirt_mat := Shapes.mat(Color("bdbab0"), {
		"double": true, "mottle": 0.07, "weave": 0.25, "stain_col": Color("9a8a60"), "stain_amt": 0.2,
		"stain_low": 1.5, "stain2_col": Color("4d231a"), "stain2_amt": 0.07, "stain_scale": 10.0,
		"edge_dark": 0.3, "rough": 0.92, "seed": 9.0,
	})
	var stockings := Shapes.mat(Color("c9c5bb"), {
		"mottle": 0.05, "stain_col": Color("857d68"), "stain_amt": 0.1, "stain_low": 2.0, "stain_scale": 14.0,
		"edge_dark": 0.6, "rough": 0.5, "seed": 4.0,
	})
	var skin := Shapes.mat(Color("b8b2a8"), {
		"mottle": 0.12, "vein": 0.4, "stain_amt": 0.0, "stain_scale": 12.0, "edge_dark": 0.5,
		"rough": 0.45, "sss": 0.15, "seed": 8.0,
	})
	var hair := Shapes.mat(Color("15100d"), {"mottle": 0.3, "stain_scale": 40.0, "rough": 0.75, "weave": 0.5})
	var mask := Shapes.mat(Color("a2bab5"), {
		"double": true, "mottle": 0.05, "weave": 0.45, "stain_col": Color("7d735a"), "stain_amt": 0.12,
		"stain_scale": 30.0, "rough": 1.0, "edge_dark": 0.2, "seed": 6.0,
	})
	var navy := Shapes.flat(Color("1b1f2a"), 0.7)
	var red := Shapes.flat(Color("6e0c0c"), 0.6)
	var hollow := Shapes.flat(Color("040202"), 1.0)
	model.body_material(stockings)

	var torso := Node3D.new()
	torso.name = "Torso"
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.03, 0.115, 0.085], [0.12, 0.085, 0.064], [0.30, 0.105, 0.078, 0.008],
		[0.46, 0.125, 0.085], [0.58, 0.13, 0.072], [0.66, 0.05, 0.045, 0.012],
	], 18, 0.0, 0.0, 0.01, 3, true, true), whites, Vector3.ZERO, "Bodice"))
	for sx in [-1.0, 1.0]:
		torso.add_child(Shapes.ellipsoid(Vector3(0.05, 0.045, 0.05), whites, Vector3(sx * 0.13, 0.59, 0.0), 10))
	for i in 5:
		torso.add_child(Shapes.ellipsoid(Vector3(0.007, 0.007, 0.004), Shapes.flat(Color("b1ab9c"), 0.4), Vector3(0, 0.18 + i * 0.09, 0.08 + (0.006 if i > 2 else 0.0)), 6))
	# A starched bib apron over the dress, its straps crossing the shoulders.
	var apron := Shapes.mat(Color("ebe8df"), {
		"double": true, "mottle": 0.05, "weave": 0.3, "stain_col": Color("a3946a"), "stain_amt": 0.12,
		"stain2_col": Color("5a2418"), "stain2_amt": 0.06, "stain_scale": 14.0, "rough": 0.85, "seed": 13.0,
	})
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.1, 0.092, 0.075, 0.004], [0.3, 0.11, 0.083, 0.006], [0.46, 0.128, 0.09, 0.004],
	], 10, TAU - 1.3, 0.0, 0.0, 5), apron, Vector3.ZERO, "Bib"))
	for sx in [-1.0, 1.0]:
		var strap := Shapes.box(Vector3(0.028, 0.2, 0.004), apron, Vector3(sx * 0.075, 0.54, 0.076))
		strap.rotation = Vector3(-0.25, 0, sx * -0.15)
		torso.add_child(strap)
	var pin := Shapes.cylinder(0.014, 0.004, Shapes.flat(Color("6b645a"), 0.3), Vector3(-0.055, 0.4, 0.098))
	pin.rotation.x = PI * 0.5
	torso.add_child(pin)
	# An A-line skirt to just below the knee.
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.6, 0.235, 0.215, 0.02], [-0.38, 0.195, 0.175, 0.01], [-0.14, 0.14, 0.12], [0.04, 0.11, 0.085], [0.1, 0.092, 0.07],
	], 28, 0.0, 0.015, 0.03, 29), skirt_mat, Vector3.ZERO, "Skirt"))
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.5, 0.215, 0.212, 0.018], [-0.14, 0.145, 0.128, 0.004], [0.08, 0.1, 0.078, 0.002],
	], 10, TAU - 1.6, 0.02, 0.02, 15), apron, Vector3.ZERO, "Apron"))
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.065, 0.095, 0.078], [0.11, 0.092, 0.075],
	], 18), navy, Vector3.ZERO, "Belt"))
	torso.add_child(Shapes.box(Vector3(0.03, 0.03, 0.006), Shapes.flat(Color("8c887c"), 0.3), Vector3(0, 0.088, 0.078)))
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.62, 0.068, 0.06, 0.01], [0.675, 0.064, 0.056, 0.012],
	], 14, 0.0, 0.0, 0.0, 1), skirt_mat, Vector3.ZERO, "Collar"))
	model.add_part(torso, "torso")

	for side in ["arm-left", "arm-right"]:
		var sgn := -1.0 if side == "arm-left" else 1.0
		Limbs.add_arm(model, side, Limbs.arm(ARM_LEN, whites, 0.85, 1.45, 61 if side == "arm-left" else 62, side == "arm-left", skin))
		var cuff := Shapes.mesh_node(Shapes.lathe([[0.0, 0.026, 0.029], [0.04, 0.028, 0.031]], 10), skirt_mat)
		model.add_part(cuff, side, Transform3D(Basis(Vector3.BACK, sgn * PI * 0.5), Vector3.ZERO), 0.8)

	for side in ["leg-left", "leg-right"]:
		model.add_part(Limbs.leg(LEG_LEN, stockings, 0.78, false, 71 if side == "leg-left" else 72), side)
		var shoe := Node3D.new()
		var shoe_mat := Shapes.mat(Color("c4bfb0"), {"stain_col": Color("514a3c"), "stain_amt": 0.35, "stain_scale": 30.0, "rough": 0.35})
		shoe.add_child(Shapes.ellipsoid(Vector3(0.042, 0.03, 0.115), shoe_mat, Vector3(0, 0.03, 0.045), 10))
		shoe.add_child(Shapes.box(Vector3(0.05, 0.04, 0.05), shoe_mat, Vector3(0, 0.02, -0.04)))
		model.add_part(shoe, side, Transform3D(Basis(), Vector3.ZERO), 1.0)

	var head_root := Node3D.new()
	head_root.name = "Head"
	# A little too big for the neck it sits on.
	var head := Node3D.new()
	head.scale = Vector3.ONE * 1.1
	head_root.add_child(head)
	head.add_child(Shapes.cylinder(0.034, 0.2, skin, Vector3(0, -0.06, -0.01), 0.03))
	head.add_child(Shapes.ellipsoid(Vector3(0.085, 0.125, 0.1), skin, Vector3(0, 0.12, 0.0)))
	head.add_child(Shapes.ellipsoid(Vector3(0.092, 0.1, 0.1), hair, Vector3(0, 0.165, -0.025)))
	head.add_child(Shapes.ellipsoid(Vector3(0.052, 0.05, 0.047), hair, Vector3(0, 0.135, -0.115)))
	for sx in [-1.0, 1.0]:
		var sock := Shapes.ellipsoid(Vector3(0.021, 0.011, 0.012), hollow, Vector3(sx * 0.032, 0.15, 0.09), 10)
		sock.rotation.z = sx * -0.15
		head.add_child(sock)
	head.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.0, 0.072, 0.093, 0.014], [0.05, 0.09, 0.113, 0.014], [0.1, 0.092, 0.113, 0.012], [0.132, 0.087, 0.106, 0.01],
	], 16, 3.2, 0.0, 0.015, 12), mask, Vector3.ZERO, "Mask"))
	for i in 3:
		var pleat := Shapes.mesh_node(Shapes.lathe([[0.0, 0.093, 0.116, 0.014], [0.003, 0.093, 0.116, 0.014]], 16, 3.3), Shapes.flat(Color("7f9892"), 1.0))
		pleat.position.y = 0.035 + i * 0.03
		head.add_child(pleat)
	for sx in [-1.0, 1.0]:
		head.add_child(Shapes.box(Vector3(0.004, 0.005, 0.11), Shapes.flat(Color("8aa39f"), 0.9), Vector3(sx * 0.088, 0.11, -0.02)))
	var cap := Node3D.new()
	cap.position = Vector3(0, 0.235, -0.01)
	cap.rotation.x = -0.3
	cap.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.0, 0.085, 0.08], [0.035, 0.09, 0.072], [0.07, 0.105, 0.03],
	], 16, 0.0, 0.0, 0.02, 2, true, false), Shapes.mat(Color("dedbd2"), {"double": true, "stain_amt": 0.15, "stain_col": Color("a39873"), "stain_scale": 14.0, "rough": 0.8})))
	cap.add_child(Shapes.box(Vector3(0.036, 0.011, 0.004), red, Vector3(0, 0.035, 0.078)))
	cap.add_child(Shapes.box(Vector3(0.011, 0.036, 0.004), red, Vector3(0, 0.035, 0.078)))
	head.add_child(cap)
	model.add_part(head_root, "head")
