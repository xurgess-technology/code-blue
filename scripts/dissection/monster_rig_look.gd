extends RefCounted
## How a strapped monster wears the walking monster's rig (`make_lying`): the fit on the OR table
## and the face of the openable head, copied from scripts/monsters/discharged_look.gd and
## walk_in_look.gd so the one on the table is the one from the halls.
##
## Lying-root coordinates are make_lying's frame (along X, head -X, face up, unscaled). The model head
## frame is the walking look's head part: +Y up the head, +Z the face, X ear to ear, origin at the head
## bone. monster_builder.gd turns it face up onto the table: model +Y -> body -X, +Z -> +Y, +X -> -Z.

const Shapes := preload("res://scripts/monsters/shapes.gd")

## Per kind:
##   scale        the lying copy is shrunk this much to fit the 2 m table (Discharged 2.08 m -> 1.87 m)
##   offset       added after scaling (the copy's back sinks about 10 cm below its origin; legs rest at y 0)
##   head_bone    where make_lying puts the head bone (lying root, unscaled; tools/dissectiontest checks it)
##   centre       the cranium's centre in the model head frame; radii (ear to ear, up, front) of the
##                one ellipsoid that replaces the look's skull pieces and is cut open
##   spread       degrees the arms lie out from the sides (the shaper's lying_spread)
##   straps       [x, half width, top of the body] in lying root: chest over the upper arms,
##                wrists and hips, thighs, shins
##   injection    top of the upper arm, lying root
##   shoulder_x, arm_reach, hip_x   where the limbs pivot (lying root), for the straps pulled taut
const RIG := {
	"walk_in": {
		"scale": 1.0, "offset": Vector3(-0.01, 0.05, 0.0), "head_bone": Vector3(-0.648, 0.1204, 0.0),
		"centre": Vector3(0.0, 0.12, -0.008), "radii": Vector3(0.095, 0.11, 0.108), "spread": 2.0,
		"straps": [[-0.42, 0.29, 0.15], [0.12, 0.3, 0.27], [0.42, 0.19, 0.13], [0.68, 0.18, 0.12]],
		"injection": Vector3(-0.42, 0.1, -0.205), "brain_scale": 0.92,
		"shoulder_x": -0.57, "arm_reach": 0.75, "hip_x": -0.07,
	},
	"discharged": {
		"scale": 0.9, "offset": Vector3(0.0, 0.05, 0.0), "head_bone": Vector3(-0.8154, 0.0663, 0.0),
		"centre": Vector3(0.0, 0.127, -0.0165), "radii": Vector3(0.085, 0.115, 0.1135), "spread": 2.0,
		"straps": [[-0.47, 0.24, 0.1], [0.2, 0.25, 0.19], [0.52, 0.16, 0.09], [0.82, 0.15, 0.085]],
		"injection": Vector3(-0.55, 0.035, -0.17), "brain_scale": 0.92,
		"shoulder_x": -0.73, "arm_reach": 0.95, "hip_x": -0.13,
	},
}

## Model head frame -> head-local (the dissection head: +Y face, -X crown, Z ear to ear).
const TO_HEAD := Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))

## The Discharged's ears a little bigger than the walking one's: on a head lying at table height they
## are what you see of it from beside the table.
const EAR_K := 1.15

static var _mats := {}


static func has(kind: String) -> bool:
	return RIG.has(kind)


## Head radii in the dissection head's frame (crown to chin, face to back, ear to ear), scaled.
static func head_radii(kind: String) -> Vector3:
	var d: Dictionary = RIG[kind]
	var r: Vector3 = d.radii
	return Vector3(r.y, r.z, r.x) * float(d.scale)


## The walking look's face without its skull pieces, built under a plain Node3D in the model head
## frame. The mouth sits in a `Jaw` pivot (meta `no_bake`, the builder gapes it); the ears hang from
## pivots (meta `no_bake`) at their resting turn.
static func face(kind: String, skin: Material) -> Node3D:
	var head := Node3D.new()
	head.name = "LookFace"
	if kind == "discharged":
		_discharged_face(head, skin)
	else:
		_walk_in_face(head, skin)
	return head


static func hair_material(kind: String) -> Material:
	if kind != "walk_in":
		return null
	return _mat("walk_in_hair", func(): return Shapes.mat(Color("3a3530"), {"mottle": 0.4, "stain_scale": 60.0, "rough": 0.9, "weave": 0.4}))


## Whether a point of the head shell (head-local, scaled) has hair: the Walk-In's thin fringe round
## the back and sides (walk_in_look.gd's hair ellipsoid, a little larger so it shows on the shell).
static func has_hair(kind: String, p: Vector3) -> bool:
	if kind != "walk_in":
		return false
	var d: Dictionary = RIG[kind]
	var m := (d.centre as Vector3) + TO_HEAD.inverse() * (p / float(d.scale))
	var q := (m - Vector3(0, 0.125, -0.042)) / Vector3(0.1, 0.082, 0.082)
	return q.length() < 1.0


static func _mouth(head: Node3D, slit: MeshInstance3D, at: Vector3) -> void:
	var jaw := Node3D.new()
	jaw.name = "Jaw"
	jaw.position = at
	jaw.set_meta("no_bake", true)
	head.add_child(jaw)
	jaw.add_child(slit)


static func _mat(key: String, make: Callable) -> Material:
	if not _mats.has(key):
		_mats[key] = make.call()
	return _mats[key]


# ------------------------------------------------------------------------------------ Discharged

static func _discharged_face(head: Node3D, skin: Material) -> void:
	var scar := _mat("dis_scar", func(): return Shapes.mat(Color("6f6a66"), {
		"mottle": 0.2, "vein": 0.8, "stain_col": Color("4d3a3a"), "stain_amt": 0.35, "stain_scale": 40.0,
		"edge_dark": 0.2, "rough": 0.3, "sss": 0.2, "seed": 17.0}))
	var ear_in := _mat("dis_ear_in", func(): return Shapes.mat(Color("8a6a66"), {
		"mottle": 0.18, "vein": 0.5, "stain_col": Color("5a3434"), "stain_amt": 0.3, "stain_scale": 45.0,
		"edge_dark": 0.1, "rough": 0.5, "sss": 0.45, "seed": 23.0}))
	var dark := _mat("dis_dark", func(): return Shapes.flat(Color("0d0605"), 0.9))
	var stitch := _mat("dis_stitch", func(): return Shapes.flat(Color("1c1412"), 0.7))

	# The neck, straight into the collar (the walking one's tendons stick out of a neck lying flat).
	head.add_child(Shapes.cylinder(0.034, 0.24, skin, Vector3(0, -0.07, -0.005), 0.029))
	# Hollow cheeks: a narrow jaw set in under wide cheekbones.
	head.add_child(Shapes.ellipsoid(Vector3(0.05, 0.048, 0.064), skin, Vector3(0, 0.035, 0.042)))
	for sx in [-1.0, 1.0]:
		head.add_child(Shapes.ellipsoid(Vector3(0.02, 0.014, 0.026), skin, Vector3(sx * 0.056, 0.088, 0.058), 8))
	# A heavy brow over nothing; the sockets are shallow dents of tight, shiny skin.
	# (Set 6 mm further out than on the walking head: this skull is one smooth ellipsoid, and the
	# brow would sink into it.)
	head.add_child(Shapes.ellipsoid(Vector3(0.072, 0.024, 0.022), skin, Vector3(0, 0.158, 0.086), 14))
	for sx in [-1.0, 1.0]:
		var dent := Shapes.ellipsoid(Vector3(0.023, 0.013, 0.006), scar, Vector3(sx * 0.032, 0.134, 0.0878), 12)
		dent.rotation = Vector3(0.1, sx * 0.3, sx * -0.1)
		head.add_child(dent)
	# The seam that closed them: one line straight across, with cross-stitches.
	for sx in [-1.0, 1.0]:
		var seam := Shapes.box(Vector3(0.042, 0.003, 0.003), stitch, Vector3(sx * 0.03, 0.134, 0.0955))
		seam.rotation.y = sx * 0.42
		head.add_child(seam)
		for i in 3:
			var x: float = sx * (0.016 + i * 0.012)
			var st := Shapes.box(Vector3(0.002, 0.013, 0.0025), stitch, Vector3(x, 0.134, 0.1 - absf(x) * 0.42))
			st.rotation = Vector3(0.0, sx * 0.42, 0.3 if i % 2 == 0 else -0.3)
			head.add_child(st)
	# A small collapsed nose; the jaw hangs slack in a thin dark slit.
	head.add_child(Shapes.ellipsoid(Vector3(0.011, 0.018, 0.012), skin, Vector3(0, 0.1, 0.097), 8))
	_mouth(head, Shapes.ellipsoid(Vector3(0.021, 0.007, 0.006), dark, Vector3.ZERO, 10), Vector3(0.002, 0.036, 0.101))
	# Ears: on the large side of normal (about 8 cm), standing a little out, at their resting turn.
	for sx in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.name = "EarL" if sx > 0.0 else "EarR"
		pivot.set_meta("no_bake", true)
		pivot.position = Vector3(sx * 0.08, 0.122, 0.004)
		# Flared a little further than the walking one's rest (0.26): lying on its back it is listening.
		pivot.rotation = Vector3(-0.2, -sx * 0.5, sx * 0.1)
		head.add_child(pivot)
		var ear := Node3D.new()
		ear.position = Vector3(sx * 0.003, 0.0, -0.024)
		ear.scale = Vector3.ONE * EAR_K
		pivot.add_child(ear)
		ear.add_child(Shapes.ellipsoid(Vector3(0.0085, 0.039, 0.024), skin, Vector3(0, 0.002, 0), 14))
		ear.add_child(Shapes.ellipsoid(Vector3(0.008, 0.021, 0.022), skin, Vector3(0, 0.021, -0.003), 12))
		var rim := Shapes.ellipsoid(Vector3(0.007, 0.038, 0.0065), skin, Vector3(sx * 0.003, 0.004, -0.02), 10)
		rim.rotation.x = -0.12
		ear.add_child(rim)
		ear.add_child(Shapes.ellipsoid(Vector3(0.0045, 0.023, 0.014), ear_in, Vector3(sx * 0.006, -0.002, 0.001), 12))
		ear.add_child(Shapes.ellipsoid(Vector3(0.003, 0.008, 0.0065), dark, Vector3(sx * 0.0072, -0.011, 0.009), 8))
		ear.add_child(Shapes.ellipsoid(Vector3(0.007, 0.012, 0.01), skin, Vector3(0, -0.034, 0.003), 10))
		Shapes.bake(ear, "dx_discharged|ear%d" % int(sx))


# ------------------------------------------------------------------------------------ Walk-In

static func _walk_in_face(head: Node3D, skin: Material) -> void:
	var dark := _mat("wi_dark", func(): return Shapes.flat(Color("120908"), 0.9))
	var lid := _mat("wi_lid", func(): return Shapes.mat(Color("7f7766"), {"mottle": 0.2, "vein": 0.5, "stain_col": Color("574a48"), "stain_amt": 0.35, "stain_scale": 40.0, "rough": 0.5}))
	var eye := _mat("wi_eye", func():
		var e := StandardMaterial3D.new()
		e.albedo_color = Color("c9c7b2")
		e.roughness = 0.12
		e.emission_enabled = true
		e.emission = Color("b8b89a")
		e.emission_energy_multiplier = 0.35
		return e)
	var pupil := _mat("wi_pupil", func(): return Shapes.flat(Color("6e6a5c"), 0.2))

	head.add_child(Shapes.cylinder(0.05, 0.16, skin, Vector3(0, -0.04, -0.01), 0.045))
	# Jowls and a double chin.
	head.add_child(Shapes.ellipsoid(Vector3(0.075, 0.05, 0.07), skin, Vector3(0, 0.035, 0.03)))
	head.add_child(Shapes.ellipsoid(Vector3(0.05, 0.035, 0.05), skin, Vector3(0, 0.0, 0.035)))
	for sx in [-1.0, 1.0]:
		# Ears: plain and small.
		head.add_child(Shapes.ellipsoid(Vector3(0.01, 0.026, 0.017), skin, Vector3(sx * 0.094, 0.11, -0.01), 8))
		# Sockets, lids heavy and dark, the eye bulging in them.
		head.add_child(Shapes.ellipsoid(Vector3(0.022, 0.016, 0.01), lid, Vector3(sx * 0.035, 0.13, 0.088), 10))
		head.add_child(Shapes.ellipsoid(Vector3(0.012, 0.01, 0.008), eye, Vector3(sx * 0.035, 0.128, 0.094), 10))
		head.add_child(Shapes.ellipsoid(Vector3(0.0045, 0.0045, 0.003), pupil, Vector3(sx * 0.034, 0.128, 0.1015), 8))
		var upper := Shapes.ellipsoid(Vector3(0.016, 0.006, 0.009), lid, Vector3(sx * 0.035, 0.137, 0.095), 8)
		upper.rotation.x = 0.3
		head.add_child(upper)
		head.add_child(Shapes.ellipsoid(Vector3(0.02, 0.008, 0.009), lid, Vector3(sx * 0.036, 0.113, 0.092), 8))
	head.add_child(Shapes.ellipsoid(Vector3(0.015, 0.022, 0.018), skin, Vector3(0, 0.1, 0.1), 8))
	# The mouth hangs open: a slack dark gap, lower lip sagging.
	_mouth(head, Shapes.ellipsoid(Vector3(0.022, 0.012, 0.008), dark, Vector3.ZERO, 10), Vector3(0, 0.052, 0.098))
	head.add_child(Shapes.ellipsoid(Vector3(0.024, 0.007, 0.01), lid, Vector3(0, 0.039, 0.098), 8))
