extends RefCounted
## The Discharged: a gaunt patient a head taller than a surgeon (about 2.1 m), in a stained,
## too-short gown, bare legs, one wrist still taped to the IV pole it drags. It has no eyes:
## smooth skin has grown over the sockets, pulled tight by an old surgical seam. What it has
## are ears, a little too large, that turn toward every sound and flare while it listens.

const Shapes := preload("res://scripts/monsters/shapes.gd")
const Limbs := preload("res://scripts/monsters/limbs.gd")
const IVPole := preload("res://scripts/monsters/iv_pole.gd")

const ARM_LEN := 1.0
const LEG_LEN := 1.16
## The torso geometry (built at the old 0.53 m) is stretched to this.
const TORSO_K := 1.22


static func build(model: Node3D) -> void:
	var sh = model.shaper
	sh.cfg = {
		# Limb blocks squeezed to slivers (0.02): the bony limbs below replace them.
		"leg_len": LEG_LEN, "leg_thick": 0.02, "hip_half": 0.09, "stride": 0.85, "bob": 0.5,
		"shoulder": Vector3(0.155, 0.49 * TORSO_K, -0.02), "neck": Vector3(0.0, 0.56 * TORSO_K + 0.02, 0.07),
		"arm_len": ARM_LEN, "arm_thick": 0.02, "arm_swing": 0.7, "arm_idle": 0.5,
		"hunch": 0.36, "head_pitch": 0.12, "head_roll": 0.22, "torso_sway": 1.0, "head_sway": 0.6,
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
	# Where the eyes were: the skin is thinner, darker and shinier, stretched over hollows.
	var scar := Shapes.mat(Color("6f6a66"), {
		"mottle": 0.2, "vein": 0.8, "stain_col": Color("4d3a3a"), "stain_amt": 0.35, "stain_scale": 40.0,
		"edge_dark": 0.2, "rough": 0.3, "sss": 0.2, "seed": 17.0,
	})
	# The inside of an ear: warmer, redder, where blood shows through thin cartilage.
	var ear_in := Shapes.mat(Color("8a6a66"), {
		"mottle": 0.18, "vein": 0.5, "stain_col": Color("5a3434"), "stain_amt": 0.3, "stain_scale": 45.0,
		"edge_dark": 0.1, "rough": 0.5, "sss": 0.45, "seed": 23.0,
	})
	var dark := Shapes.flat(Color("0d0605"), 0.9)
	var stitch := Shapes.flat(Color("1c1412"), 0.7)
	model.body_material(skin)

	# ---- torso: a narrow ribcage with a visible spine, under a gown open at the back
	var torso := Node3D.new()
	torso.name = "Torso"
	var tk := Node3D.new()
	tk.scale = Vector3(1.0, TORSO_K, 1.0)
	torso.add_child(tk)
	tk.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.06, 0.11, 0.08], [0.10, 0.092, 0.065], [0.24, 0.118, 0.085, 0.012],
		[0.38, 0.14, 0.092], [0.47, 0.135, 0.078, -0.005], [0.53, 0.05, 0.042, 0.03],
	], 16, 0.0, 0.0, 0.03, 21, true, true), skin))
	for i in 7:
		var y := 0.12 + i * 0.056
		tk.add_child(Shapes.ellipsoid(Vector3(0.016, 0.02, 0.018), skin, Vector3(0, y, -0.075 - 0.008 * sin(i * 0.5)), 8))
	for sx in [-1.0, 1.0]:
		tk.add_child(Shapes.ellipsoid(Vector3(0.045, 0.065, 0.018), skin, Vector3(sx * 0.065, 0.39, -0.08), 10))
		tk.add_child(Shapes.ellipsoid(Vector3(0.036, 0.032, 0.036), skin, Vector3(sx * 0.14, 0.485, -0.02), 10))
		var clav := Shapes.ellipsoid(Vector3(0.07, 0.011, 0.013), skin, Vector3(sx * 0.07, 0.5, 0.05), 8)
		clav.rotation.z = sx * -0.2
		tk.add_child(clav)
	tk.add_child(Shapes.mesh_node(Shapes.lathe([
		[-0.33, 0.19, 0.155, 0.03], [-0.16, 0.172, 0.14, 0.025], [0.04, 0.145, 0.112, 0.02],
		[0.24, 0.15, 0.112, 0.02], [0.40, 0.17, 0.11, 0.0], [0.49, 0.16, 0.098, 0.0], [0.53, 0.085, 0.068, 0.035],
	], 22, 1.1, 0.06, 0.05, 41), gown, Vector3.ZERO, "Gown"))
	var tie := Shapes.box(Vector3(0.012, 0.16, 0.004), gown, Vector3(0.05, 0.3, -0.115))
	tie.rotation.z = 0.2
	tk.add_child(tie)
	model.add_part(torso, "torso")

	for side in ["arm-left", "arm-right"]:
		var sgn := -1.0 if side == "arm-left" else 1.0
		Limbs.add_arm(model, side, Limbs.arm(ARM_LEN, skin, 0.9, 1.3, 31 if side == "arm-left" else 32, side == "arm-left"))
		var sleeve := Shapes.mesh_node(Shapes.lathe([
			[-0.02, 0.06, 0.062], [0.08, 0.058, 0.06], [0.15, 0.07, 0.068],
		], 12, 0.0, 0.03, 0.08, 7), gown)
		model.add_part(sleeve, side, Transform3D(Basis(Vector3.BACK, sgn * PI * 0.5), Vector3.ZERO))
	for side in ["leg-left", "leg-right"]:
		model.add_part(Limbs.leg(LEG_LEN, skin, 0.92, true, 51 if side == "leg-left" else 52), side)

	# ---- head: bald, mottled, cheeks sunk, no eyes, and the ears
	var head := Node3D.new()
	head.name = "Head"
	var neck := Shapes.cylinder(0.034, 0.24, skin, Vector3(0, -0.07, -0.01), 0.029)
	neck.rotation.x = -0.25
	head.add_child(neck)
	for sx in [-1.0, 1.0]:
		var tendon := Shapes.ellipsoid(Vector3(0.01, 0.07, 0.011), skin, Vector3(sx * 0.022, -0.06, 0.03), 8)
		tendon.rotation.z = sx * 0.2
		head.add_child(tendon)
	head.add_child(Shapes.ellipsoid(Vector3(0.084, 0.108, 0.097), skin, Vector3(0, 0.12, 0.0)))
	head.add_child(Shapes.ellipsoid(Vector3(0.082, 0.092, 0.1), skin, Vector3(0, 0.15, -0.03)))
	# Hollow cheeks: a narrow jaw set in under wide cheekbones.
	head.add_child(Shapes.ellipsoid(Vector3(0.05, 0.048, 0.064), skin, Vector3(0, 0.035, 0.042)))
	for sx in [-1.0, 1.0]:
		head.add_child(Shapes.ellipsoid(Vector3(0.022, 0.016, 0.03), skin, Vector3(sx * 0.058, 0.085, 0.06), 8))
	# A heavy brow over nothing. Below it the sockets are shallow dents of tight, shiny skin.
	var brow := Shapes.ellipsoid(Vector3(0.07, 0.017, 0.03), skin, Vector3(0, 0.162, 0.078), 12)
	head.add_child(brow)
	for sx in [-1.0, 1.0]:
		var dent := Shapes.ellipsoid(Vector3(0.026, 0.017, 0.012), scar, Vector3(sx * 0.034, 0.133, 0.087), 12)
		dent.rotation = Vector3(0.15, sx * 0.35, sx * -0.12)
		head.add_child(dent)
	# The seam that closed them: one line straight across, with cross-stitches.
	var seam := Shapes.box(Vector3(0.1, 0.0035, 0.004), stitch, Vector3(0, 0.134, 0.097))
	head.add_child(seam)
	for i in 7:
		var x := -0.045 + i * 0.015
		var st := Shapes.box(Vector3(0.0025, 0.016, 0.003), stitch, Vector3(x, 0.134, 0.098 - absf(x) * 0.28))
		st.rotation = Vector3(0.0, x * -3.2, 0.25 if i % 2 == 0 else -0.25)
		head.add_child(st)
	# A small nose, collapsed; the jaw hangs slack.
	head.add_child(Shapes.ellipsoid(Vector3(0.012, 0.02, 0.014), skin, Vector3(0, 0.1, 0.101), 8))
	head.add_child(Shapes.ellipsoid(Vector3(0.024, 0.02, 0.012), dark, Vector3(0.003, 0.03, 0.101), 10))

	# Ears: on the large side of normal (8.5 cm, a surgeon's are about 6.5), set a little high,
	# standing out from the skull. Each hangs from a pivot at its front edge so it can swivel.
	for sx in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.name = "EarL" if sx > 0.0 else "EarR"
		pivot.position = Vector3(sx * 0.08, 0.125, -0.012)
		head.add_child(pivot)
		var ear := Node3D.new()
		ear.position = Vector3(sx * 0.004, 0.0, -0.026)
		pivot.add_child(ear)
		# The pinna: a thin shell, taller than it is deep, wider at the top.
		var shell := Shapes.ellipsoid(Vector3(0.011, 0.043, 0.027), skin, Vector3(0, 0.004, 0), 14)
		ear.add_child(shell)
		var upper := Shapes.ellipsoid(Vector3(0.01, 0.022, 0.024), skin, Vector3(0, 0.024, -0.004), 12)
		ear.add_child(upper)
		# The rim curls around the back edge.
		var rim := Shapes.ellipsoid(Vector3(0.008, 0.042, 0.007), skin, Vector3(sx * 0.004, 0.006, -0.022), 10)
		rim.rotation.x = -0.12
		ear.add_child(rim)
		# The bowl, darker and redder, open to the side it faces.
		ear.add_child(Shapes.ellipsoid(Vector3(0.006, 0.026, 0.016), ear_in, Vector3(sx * 0.0075, -0.002, 0.001), 12))
		ear.add_child(Shapes.ellipsoid(Vector3(0.004, 0.009, 0.007), dark, Vector3(sx * 0.009, -0.012, 0.01), 8))
		# The lobe.
		ear.add_child(Shapes.ellipsoid(Vector3(0.008, 0.013, 0.011), skin, Vector3(0, -0.037, 0.004), 10))
		model.ears.append({"node": pivot, "side": sx, "rest": 0.32})
	model.add_part(head, "head")

	# ---- the taped wrist and the IV pole it drags
	var tape_mat := Shapes.mat(Color("d2cbb4"), {"stain_amt": 0.4, "stain_col": Color("8b7c52"), "stain_scale": 30.0, "rough": 0.6})
	var tape := Shapes.box(Vector3(0.05, 0.035, 0.07), tape_mat)
	model.add_part(tape, "arm-left", Transform3D(Basis(), Vector3.ZERO), 0.8)
	model.iv = IVPole.new()
	model.add_child(model.iv)
