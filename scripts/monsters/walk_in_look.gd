extends RefCounted
## The Walk-In: an ordinary patient who walked in and never left. Heavy-set, about 1.75 m,
## grey-yellow skin, a faded blue print gown tied wrong, bare legs, one slipper sock, a
## wristband. The head hangs forward and to one side; the eyes are wide open, filmed over,
## with a faint wet shine: this is the one that looks at you. It drags its right leg.

const Shapes := preload("res://scripts/monsters/shapes.gd")
const Limbs := preload("res://scripts/monsters/limbs.gd")

const ARM_LEN := 0.78
const LEG_LEN := 0.92


static func build(model: Node3D) -> void:
	var sh = model.shaper
	sh.cfg = {
		"leg_len": LEG_LEN, "leg_thick": 0.02, "hip_half": 0.11, "stride": 0.55, "bob": 0.8,
		"shoulder": Vector3(0.2, 0.5, 0.0), "neck": Vector3(0.0, 0.6, 0.09),
		"arm_len": ARM_LEN, "arm_thick": 0.02, "arm_swing": 0.35, "arm_idle": 0.3,
		"hunch": 0.24, "head_pitch": 0.26, "head_roll": -0.3, "torso_sway": 0.9, "head_sway": 0.9,
		"limp": 0.85, "lean": 0.07,
		# Arms dangle a little forward of the body, loose, the left more than the right.
		"arm_l": {"back": -16.0, "spread": 9.0, "swing": 0.4, "idle": 0.35, "lunge": 0.8},
		"arm_r": {"back": -9.0, "spread": 12.0, "swing": 0.25, "idle": 0.35, "lunge": 0.8},
	}

	var skin := Shapes.mat(Color("a39f86"), {
		"mottle": 0.16, "vein": 0.35, "stain_col": Color("7d7a5a"), "stain_amt": 0.18,
		"stain2_col": Color("5a4a52"), "stain2_amt": 0.08, "stain_scale": 7.0,
		"edge_dark": 0.45, "rough": 0.5, "sss": 0.18, "seed": 41.0,
	})
	var gown := Shapes.mat(Color("7f97a8"), {
		"double": true, "mottle": 0.12, "weave": 0.35, "stain_col": Color("6a6553"), "stain_amt": 0.28,
		"stain_low": 1.6, "stain2_col": Color("3f2a22"), "stain2_amt": 0.1, "stain_scale": 11.0,
		"edge_dark": 0.2, "rough": 0.95, "seed": 43.0,
	})
	# The gown's print: small darker diamonds, mostly washed out.
	var print_mat := Shapes.mat(Color("5d7384"), {"double": true, "mottle": 0.3, "stain_amt": 0.2, "stain_col": Color("7f97a8"), "stain_scale": 20.0, "rough": 0.95})
	var sock := Shapes.mat(Color("8a8f86"), {"mottle": 0.2, "weave": 0.7, "stain_col": Color("4c4536"), "stain_amt": 0.45, "stain_low": 3.0, "stain_scale": 18.0, "rough": 1.0, "seed": 7.0})
	var band := Shapes.flat(Color("d8d4c6"), 0.4)
	var hair := Shapes.mat(Color("3a3530"), {"mottle": 0.4, "stain_scale": 60.0, "rough": 0.9, "weave": 0.4})
	var dark := Shapes.flat(Color("120908"), 0.9)
	var lid := Shapes.mat(Color("7f7766"), {"mottle": 0.2, "vein": 0.5, "stain_col": Color("574a48"), "stain_amt": 0.35, "stain_scale": 40.0, "rough": 0.5})
	# Filmed-over eyes with a faint shine, so a pair of them catches your flashlight.
	var eye := StandardMaterial3D.new()
	eye.albedo_color = Color("c9c7b2")
	eye.roughness = 0.12
	eye.emission_enabled = true
	eye.emission = Color("b8b89a")
	eye.emission_energy_multiplier = 0.35
	var pupil := Shapes.flat(Color("6e6a5c"), 0.2)
	model.body_material(skin)

	# ---- torso: soft and heavy, a belly under the gown
	var torso := Node3D.new()
	torso.name = "Torso"
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.05, 0.15, 0.12], [0.08, 0.165, 0.15, 0.03], [0.22, 0.16, 0.13, 0.02],
		[0.38, 0.175, 0.115], [0.49, 0.16, 0.1], [0.56, 0.06, 0.055, 0.03],
	], 16, 0.0, 0.0, 0.03, 45, true, true), skin))
	for sx in [-1.0, 1.0]:
		torso.add_child(Shapes.ellipsoid(Vector3(0.05, 0.042, 0.05), skin, Vector3(sx * 0.15, 0.5, 0.0), 10))
	torso.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.3, 0.215, 0.2, 0.04], [-0.12, 0.205, 0.19, 0.035], [0.06, 0.19, 0.18, 0.035],
		[0.24, 0.182, 0.15, 0.02], [0.42, 0.195, 0.13, 0.0], [0.52, 0.17, 0.11, 0.0], [0.57, 0.09, 0.07, 0.03],
	], 22, 0.9, 0.07, 0.05, 47), gown, Vector3.ZERO, "Gown"))
	# A scatter of the faded print on the front of the gown.
	for i in 9:
		var a := -0.9 + (i % 3) * 0.9 + (0.3 if i / 3 == 1 else 0.0)
		var y := -0.15 + (i / 3) * 0.2
		var r := 0.2 - (i / 3) * 0.008
		var dot := Shapes.box(Vector3(0.022, 0.022, 0.003), print_mat, Vector3(sin(a) * r, y, cos(a) * (r - 0.006) + 0.035))
		dot.rotation = Vector3(0, a, PI * 0.25)
		torso.add_child(dot)
	# The ties hang loose at the back.
	for i in 2:
		var tie := Shapes.box(Vector3(0.014, 0.2, 0.004), gown, Vector3(0.04 - i * 0.07, 0.2 + i * 0.12, -0.14))
		tie.rotation.z = 0.3 - i * 0.5
		torso.add_child(tie)
	model.add_part(torso, "torso")

	for side in ["arm-left", "arm-right"]:
		var sgn := -1.0 if side == "arm-left" else 1.0
		Limbs.add_arm(model, side, Limbs.arm(ARM_LEN, skin, 1.35, 0.95, 81 if side == "arm-left" else 82, side == "arm-left"))
		var sleeve := Shapes.mesh_node(Shapes.lathe([
			[-0.02, 0.075, 0.078], [0.1, 0.07, 0.074], [0.2, 0.08, 0.082],
		], 12, 0.0, 0.04, 0.08, 9), gown)
		model.add_part(sleeve, side, Transform3D(Basis(Vector3.BACK, sgn * PI * 0.5), Vector3.ZERO))
	# Wristband on the left, a cotton ball taped in the crook of the right arm.
	model.add_part(Shapes.mesh_node(Shapes.lathe([[0.0, 0.032, 0.036], [0.022, 0.032, 0.036]], 12), band),
		"arm-left", Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3.ZERO), 0.82)
	model.add_part(Shapes.box(Vector3(0.03, 0.03, 0.05), band, Vector3(0.0, 0.0, 0.03)), "arm-right", Transform3D.IDENTITY, 0.48)

	for side in ["leg-left", "leg-right"]:
		model.add_part(Limbs.leg(LEG_LEN, skin, 1.3, side == "leg-right", 91 if side == "leg-left" else 92), side)
	# One grey slipper sock, the tread worn off.
	var s := Node3D.new()
	s.add_child(Shapes.ellipsoid(Vector3(0.05, 0.034, 0.13), sock, Vector3(0, 0.03, 0.05), 10))
	s.add_child(Shapes.cylinder(0.042, 0.1, sock, Vector3(0, 0.08, -0.01), 0.04, 10))
	model.add_part(s, "leg-left", Transform3D.IDENTITY, 1.0)

	# ---- head: round, puffy, sparse hair, mouth hanging open, eyes wide and filmed
	var head := Node3D.new()
	head.name = "Head"
	head.add_child(Shapes.cylinder(0.05, 0.16, skin, Vector3(0, -0.04, -0.01), 0.045))
	head.add_child(Shapes.ellipsoid(Vector3(0.095, 0.11, 0.1), skin, Vector3(0, 0.12, 0.0)))
	# Jowls and a double chin.
	head.add_child(Shapes.ellipsoid(Vector3(0.075, 0.05, 0.07), skin, Vector3(0, 0.035, 0.03)))
	head.add_child(Shapes.ellipsoid(Vector3(0.05, 0.035, 0.05), skin, Vector3(0, 0.0, 0.035)))
	# Thin hair left only round the back and sides; the crown is bare.
	head.add_child(Shapes.ellipsoid(Vector3(0.093, 0.075, 0.075), hair, Vector3(0, 0.125, -0.042)))
	for sx in [-1.0, 1.0]:
		# Ears: plain and small; this one does not listen.
		head.add_child(Shapes.ellipsoid(Vector3(0.01, 0.026, 0.017), skin, Vector3(sx * 0.094, 0.11, -0.01), 8))
		# Sockets, lids heavy and dark, the eye bulging in them.
		head.add_child(Shapes.ellipsoid(Vector3(0.022, 0.016, 0.01), lid, Vector3(sx * 0.035, 0.13, 0.088), 10))
		head.add_child(Shapes.ellipsoid(Vector3(0.012, 0.01, 0.008), eye, Vector3(sx * 0.035, 0.128, 0.094), 10))
		head.add_child(Shapes.ellipsoid(Vector3(0.0045, 0.0045, 0.003), pupil, Vector3(sx * 0.034, 0.128, 0.1015), 8))
		# A heavy upper lid half over each, and bags under them.
		var upper := Shapes.ellipsoid(Vector3(0.016, 0.006, 0.009), lid, Vector3(sx * 0.035, 0.137, 0.095), 8)
		upper.rotation.x = 0.3
		head.add_child(upper)
		head.add_child(Shapes.ellipsoid(Vector3(0.02, 0.008, 0.009), lid, Vector3(sx * 0.036, 0.113, 0.092), 8))
	head.add_child(Shapes.ellipsoid(Vector3(0.015, 0.022, 0.018), skin, Vector3(0, 0.1, 0.1), 8))
	# The mouth hangs open: a slack dark gap, lower lip sagging.
	head.add_child(Shapes.ellipsoid(Vector3(0.022, 0.012, 0.008), dark, Vector3(0, 0.052, 0.098), 10))
	head.add_child(Shapes.ellipsoid(Vector3(0.024, 0.007, 0.01), lid, Vector3(0, 0.039, 0.098), 8))
	model.add_part(head, "head")
