extends RefCounted
## The seal: a harbor seal built from lofted primitives, lying on its belly.
##
## Body frame: nose toward -X, tail flippers toward +X, belly on the table at y = 0, back up.
## Lying on its belly facing -X, the seal's LEFT is +Z, so the removable left front flipper is
## on +Z like Bob's forearm.
##
## Parts under the rig: Body (lofted torso), Head (pivot at the neck: skull, muzzle, nose,
## nostrils, eyes, whiskers), FlipperLBase / FlipperRBase (pivot at the shoulder: the short
## arm stub, which keeps the tourniquet and stump), FlipperL (the removable paddle, a child of
## FlipperLBase), RearFlippers. Coat is seal_coat.gdshader with baked vertex colours.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const CoatShader := preload("res://scripts/patients/seal_coat.gdshader")

## [x, half_width (z), half_height (y), lift]
const PROFILE := [
	[-0.62, 0.095, 0.095, 0.19],
	[-0.54, 0.15, 0.14, 0.11],
	[-0.44, 0.205, 0.19, 0.05],
	[-0.30, 0.26, 0.235, 0.012],
	[-0.14, 0.29, 0.255, 0.0],
	[0.04, 0.29, 0.25, 0.0],
	[0.20, 0.26, 0.22, 0.0],
	[0.34, 0.20, 0.17, 0.004],
	[0.46, 0.135, 0.118, 0.014],
	[0.55, 0.08, 0.075, 0.03],
	[0.61, 0.045, 0.045, 0.045],
]
const FLAT := 0.6
const SHOULDER_X := -0.22
const FLIPPER_DIR := Vector3(0.75, -0.17, 0.62)
const LIMB_AT := 0.075
const CUT_AT := 0.15
## Flipper stub (kept) and paddle (removable): [x, half_width, half_height]
const STUB := [[-0.1, 0.09, 0.07], [0.0, 0.084, 0.062], [0.075, 0.076, 0.054], [0.15, 0.07, 0.046]]
const PADDLE := [[0.14, 0.07, 0.046], [0.2, 0.088, 0.036], [0.27, 0.098, 0.028], [0.33, 0.094, 0.021], [0.37, 0.072, 0.016], [0.395, 0.035, 0.01]]

static var _cache := {}


static func section(x: float) -> Vector3:
	# returns (half_width, half_height, centre_y)
	var n := PROFILE.size()
	if x <= PROFILE[0][0]:
		return Vector3(PROFILE[0][1], PROFILE[0][2], PROFILE[0][2] * FLAT + PROFILE[0][3])
	for i in n - 1:
		var a: Array = PROFILE[i]
		var c: Array = PROFILE[i + 1]
		if x <= c[0]:
			var t := (x - float(a[0])) / (float(c[0]) - float(a[0]))
			var w := lerpf(a[1], c[1], t)
			var h := lerpf(a[2], c[2], t)
			return Vector3(w, h, h * FLAT + lerpf(a[3], c[3], t))
	var l: Array = PROFILE[n - 1]
	return Vector3(l[1], l[2], l[2] * FLAT + l[3])


## Point on the upper body surface at x and lateral fraction f (-1..1 of the half width), with its normal.
static func surface(x: float, f: float) -> Array:
	var s := section(x)
	var cth := clampf(f, -0.98, 0.98)
	var sth := sqrt(1.0 - cth * cth)
	var p := Vector3(x, s.z + s.y * sth, s.x * cth)
	var n := Vector3(0.0, sth / s.y, cth / s.x).normalized()
	# include the slope along x
	var s2 := section(x + 0.02)
	var dy := (s2.z + s2.y * sth) - p.y
	n = (n - Vector3(dy / 0.02, 0, 0) * n.y).normalized()
	return [p, n]


static func _meshes() -> Dictionary:
	if _cache.has("seal"):
		return _cache["seal"]
	var body_rings := []
	for r in PROFILE:
		body_rings.append([r[0], r[1], r[2], float(r[2]) * FLAT + float(r[3]), FLAT])
	var body := Kit.loft(body_rings, 16, func(p: Vector3, up: float) -> Color:
		var belly := smoothstep(0.05, -0.55, up)
		var chest := smoothstep(-0.45, -0.25, p.x) * (1.0 - smoothstep(0.12, 0.34, p.x)) * clampf(up + 0.3, 0.0, 1.0)
		return Color(belly, 0.0, chest, 1.0))
	var head := Kit.ellipsoid(Vector3(0.19, 0.155, 0.175), 16, 10, func(p: Vector3, up: float) -> Color:
		return Color(smoothstep(0.0, -0.85, up), 0.0, 0.0, 0.8))
	var muzzle := Kit.ellipsoid(Vector3(0.125, 0.09, 0.11), 14, 8, func(p: Vector3, up: float) -> Color:
		return Color(0.55 + 0.45 * smoothstep(0.3, -0.6, up), 0.0, 0.0, 0.3))
	var stub_rings := []
	for r in STUB:
		stub_rings.append([r[0], r[1], r[2], 0.0, 1.0])
	var stub := Kit.loft(stub_rings, 12, func(p: Vector3, up: float) -> Color:
		return Color(smoothstep(0.2, -0.7, up) * 0.6, smoothstep(0.1, 0.15, p.x), 0.0, 0.8))
	var pad_rings := []
	for r in PADDLE:
		pad_rings.append([r[0], r[1], r[2], 0.0, 1.0])
	var paddle := Kit.loft(pad_rings, 12, func(p: Vector3, up: float) -> Color:
		return Color(smoothstep(0.2, -0.7, up) * 0.6, 1.0, 0.0, 0.8))
	var paddle_plain := Kit.loft(pad_rings, 12, func(p: Vector3, up: float) -> Color:
		return Color(smoothstep(0.2, -0.7, up) * 0.6, 0.0, 0.0, 0.8))
	var stub_plain := Kit.loft(stub_rings, 12, func(p: Vector3, up: float) -> Color:
		return Color(smoothstep(0.2, -0.7, up) * 0.6, 0.0, 0.0, 0.8))
	var rear_rings := [[0.0, 0.045, 0.032, 0.0, 1.0], [0.08, 0.06, 0.022, 0.0, 1.0], [0.17, 0.09, 0.014, 0.0, 1.0], [0.24, 0.115, 0.009, 0.0, 1.0], [0.255, 0.1, 0.006, 0.0, 1.0]]
	var rear := Kit.loft(rear_rings, 10, func(p: Vector3, up: float) -> Color:
		return Color(0.25, 0.0, 0.0, 0.7))
	var digit := Kit.ellipsoid(Vector3(0.045, 0.009, 0.02), 8, 4, func(p: Vector3, up: float) -> Color:
		return Color(0.2, 0.0, 0.0, 0.5))
	var d := {"body": body, "head": head, "muzzle": muzzle, "stub": stub, "paddle": paddle, "digit": digit,
		"paddle_plain": paddle_plain, "stub_plain": stub_plain, "rear": rear}
	_cache["seal"] = d
	return d


static func build(b) -> bool:
	var m := _meshes()
	var rig: Node3D = b.rig
	var coat := ShaderMaterial.new()
	coat.shader = CoatShader
	b.skin_mats.append(coat)
	b.breath_amp = 0.012
	var dark := Kit.mat("seal_dark", Color(0.035, 0.035, 0.04), 0.5)
	var eye := Kit.mat("seal_eye", Color(0.01, 0.01, 0.012), 0.08, 0.0)
	var whisker := Kit.mat("seal_whisker", Color(0.86, 0.83, 0.74), 0.6)
	var claw := Kit.mat("seal_claw", Color(0.1, 0.09, 0.08), 0.4)

	var body := Kit.add_mesh(rig, m.body, coat, Transform3D(), "Body")

	# --- head ----------------------------------------------------------------------------------
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(-0.58, 0.2, 0)
	rig.add_child(head)
	var HC := Vector3(-0.68, 0.31, 0)
	var MC := Vector3(-0.865, 0.272, 0)
	var MR := Vector3(0.125, 0.09, 0.11)
	Kit.add_mesh(head, m.head, coat, Transform3D(Basis(), HC - head.position), "Skull")
	Kit.add_mesh(head, m.muzzle, coat, Transform3D(Basis(), MC - head.position), "Muzzle")
	var tip := MC + Vector3(-MR.x, 0, 0)
	Kit.add_mesh(head, Kit.sphere(1.0, 10, 6), dark, Transform3D(Basis().scaled(Vector3(0.026, 0.034, 0.048)), tip + Vector3(0.012, 0.022, 0) - head.position), "Nose")
	var nost := Kit.mat("nostril", Color(0.0, 0.0, 0.0), 1.0)
	for sgn in [-1.0, 1.0]:
		# Harbor seal nostrils: two slits in a V on top of the nose pad.
		Kit.add_mesh(head, Kit.sphere(1.0, 8, 4), nost, Transform3D(Basis(Vector3.UP, sgn * 0.55).scaled(Vector3(0.006, 0.007, 0.022)), tip + Vector3(0.006, 0.05, sgn * 0.02) - head.position), "Nostril")
		var ep := HC + Vector3(-0.116, 0.079, sgn * 0.106) - head.position
		Kit.add_mesh(head, Kit.sphere(0.043, 12, 8), eye, Transform3D(Basis(), ep), "Eye")
		Kit.add_mesh(head, Kit.sphere(0.01, 6, 4), Kit.mat("eye_glint", Color(1, 1, 1), 0.2, 0.0, Color(1, 1, 1), 1.5), Transform3D(Basis(), ep + Vector3(-0.022, 0.028, sgn * 0.012)), "Glint")
		# Whiskers fan out from the sides of the muzzle.
		for k in 5:
			var dir := Vector3(-0.45 + 0.22 * float(k), -0.12 + 0.05 * float(k % 2), sgn).normalized()
			var root := MC + Vector3(-MR.x * 0.5 + 0.016 * float(k), -0.012 + 0.006 * float(k % 3), sgn * MR.z * 0.82) - head.position
			var len := 0.15 + 0.03 * float((k + 1) % 3)
			Kit.add_mesh(head, Kit.cyl(0.0015, 0.004, len, 4), whisker, Kit.along(dir, root + dir * len * 0.5), "Whisker")
			Kit.add_mesh(head, Kit.sphere(0.007, 4, 3), dark, Transform3D(Basis(), root), "WhiskerPad")
		for k in 2:
			var dir := Vector3(-0.3 + 0.35 * float(k), 0.8, sgn * 0.6).normalized()
			var root := ep + Vector3(-0.01 + 0.02 * float(k), 0.038, sgn * -0.01)
			Kit.add_mesh(head, Kit.cyl(0.0012, 0.003, 0.08, 4), whisker, Kit.along(dir, root + dir * 0.04), "Brow")
	# mouth line under the muzzle
	Kit.add_mesh(head, Kit.box(Vector3(0.06, 0.006, 0.09)), dark, Transform3D(Basis(Vector3.FORWARD, 0.3), MC + Vector3(-MR.x * 0.62, -MR.y * 0.62, 0) - head.position), "Mouth")

	# --- front flippers --------------------------------------------------------------------------
	var fl := _front_flipper(b, rig, m, coat, claw, 1.0)
	var fr := _front_flipper(b, rig, m, coat, claw, -1.0)

	# --- rear flippers ---------------------------------------------------------------------------
	var rear := Node3D.new()
	rear.name = "RearFlippers"
	rear.position = Vector3(0.56, section(0.56).z, 0)
	rig.add_child(rear)
	for sgn in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.name = "Rear%s" % ("L" if sgn > 0 else "R")
		pivot.transform = Transform3D(Basis(Vector3.UP, -sgn * 0.2) * Basis(Vector3.RIGHT, sgn * 0.35) * Basis(Vector3.FORWARD, -0.1), Vector3(0.0, 0.0, sgn * 0.03))
		rear.add_child(pivot)
		Kit.add_mesh(pivot, m.rear, coat, Transform3D(), "Paddle")
		for k in 5:
			var zt := (float(k) - 2.0) / 2.0
			var along := 0.235 + 0.03 * absf(zt)
			Kit.add_mesh(pivot, m.digit, coat, Transform3D(Basis(Vector3.UP, -zt * 0.35), Vector3(along - 0.02, 0.0, zt * 0.085)), "Digit")
	b.parts["rear"] = rear

	b.parts["head"] = head
	b.parts["head_base"] = head.transform
	b.parts["fl"] = fl
	b.parts["fl_base"] = fl.transform
	b.parts["fr"] = fr
	b.parts["fr_base"] = fr.transform
	b.parts["rear_base"] = rear.transform

	# --- sites -----------------------------------------------------------------------------------
	# Injection: the back of the neck. X toward the tail, +Y the skin normal.
	var inj: Array = surface(-0.43, 0.0)
	_site_on(b, rig, "injection", inj[0], Vector3(1, 0, 0), inj[1])
	# Gunshot: the right flank (-Z), a hand's width off the spine.
	var gs: Array = surface(0.02, -0.42)
	var gxf := _site_on(b, rig, "gunshot", gs[0], Vector3(1, 0, 0), gs[1])

	# --- overlays ------------------------------------------------------------------------------
	var lu := _stub_h(LIMB_AT)
	var lw := _stub_w(LIMB_AT)
	b.parts["tourniquet"] = Kit.make_tourniquet(b.anchors["limb"], lu, lw, lu)
	var cu := _stub_h(CUT_AT)
	var cw := _stub_w(CUT_AT)
	b.parts["stump"] = Kit.make_stump(b.anchors["limb_cut"], cu, cw, cu, 0.014)
	b.parts["dress_stump"] = Kit.make_stump_dressing(b.anchors["limb_cut"], cu, cw, cu)
	b.parts["wound"] = Kit.make_wound(b.anchors["gunshot"], 0.036)
	var dress := Kit.make_pad(b.anchors["gunshot"], 0.14)
	var sec := section(0.02)
	var band := MeshInstance3D.new()
	band.mesh = Kit.cyl(1.0, 1.0, 0.11, 16, false)
	band.material_override = Kit.gauze_mat()
	var band_global := Transform3D(Basis(Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, -1, 0)).scaled_local(Vector3(sec.x * 1.03, 1.0, sec.y * 1.03)), Vector3(0.02, sec.z, 0))
	band.transform = gxf.affine_inverse() * band_global
	dress.add_child(band)
	b.parts["dress_wound"] = dress

	# Drip paths: off the flank / the flipper edge onto the table.
	var gp: Vector3 = gs[0]
	b.drips["gunshot"] = [gp + Vector3(0, -0.06, -0.08), Vector3(gp.x + 0.03, 0.003, -sec.x - 0.05)]
	b.drips["injection"] = [inj[0] + Vector3(0, -0.05, -0.12), Vector3(-0.43, 0.003, -section(-0.43).x - 0.04)]
	var lxf: Transform3D = b._sites["limb"]
	var cxf: Transform3D = b._sites["limb_cut"]
	b.drips["limb"] = [lxf.origin + lxf.basis.z * lw * 0.9 - Vector3(0, lu, 0), Vector3(lxf.origin.x + lxf.basis.z.x * lw * 1.3, 0.003, lxf.origin.z + lxf.basis.z.z * lw * 1.3)]
	b.drips["limb_cut"] = [cxf.origin + cxf.basis.x * 0.02 - Vector3(0, cu, 0), Vector3(cxf.origin.x + cxf.basis.x.x * 0.06, 0.003, cxf.origin.z + cxf.basis.x.z * 0.06)]
	return true


static func _stub_h(x: float) -> float:
	return _interp(STUB, x, 2)


static func _stub_w(x: float) -> float:
	return _interp(STUB, x, 1)


static func _interp(tab: Array, x: float, col: int) -> float:
	for i in tab.size() - 1:
		if x <= float(tab[i + 1][0]):
			var t := (x - float(tab[i][0])) / (float(tab[i + 1][0]) - float(tab[i][0]))
			return lerpf(tab[i][col], tab[i + 1][col], clampf(t, 0.0, 1.0))
	return float(tab[tab.size() - 1][col])


static func _front_flipper(b, rig: Node3D, m: Dictionary, coat: Material, claw: Material, sgn: float) -> Node3D:
	var left := sgn > 0.0
	var s := section(SHOULDER_X)
	var pivot := Vector3(SHOULDER_X, 0.085, sgn * s.x * 0.97)
	var dir := Vector3(FLIPPER_DIR.x, FLIPPER_DIR.y, FLIPPER_DIR.z * sgn)
	var xf := _frame(pivot, dir, Vector3.UP)
	var base := Node3D.new()
	base.name = "FlipperLBase" if left else "FlipperRBase"
	base.transform = xf
	rig.add_child(base)
	Kit.add_mesh(base, m.stub if left else m.stub_plain, coat, Transform3D(), "Stub")
	var paddle := Node3D.new()
	paddle.name = "FlipperL" if left else "FlipperR"
	base.add_child(paddle)
	Kit.add_mesh(paddle, m.paddle if left else m.paddle_plain, coat, Transform3D(), "Paddle")
	for k in 5:
		var zt := (float(k) - 2.0) / 2.0
		Kit.add_mesh(paddle, Kit.cyl(0.0, 0.007, 0.03, 5), claw, Kit.along(Vector3(1, 0.05, zt * 0.35), Vector3(0.37 - 0.03 * absf(zt), 0.012, zt * 0.05)), "Claw")
	if left:
		b.parts["limb_node"] = paddle
		for pair in [["limb", LIMB_AT], ["limb_cut", CUT_AT]]:
			var at: float = pair[1]
			var local := Transform3D(Basis(), Vector3(at, _stub_h(at), 0))
			var anchor := Node3D.new()
			anchor.name = pair[0]
			anchor.transform = local
			base.add_child(anchor)
			b.anchors[pair[0]] = anchor
			b._sites[pair[0]] = xf * local
	return base


static func _site_on(b, rig: Node3D, nm: String, p: Vector3, x_dir: Vector3, normal: Vector3) -> Transform3D:
	var y := normal.normalized()
	var x := (x_dir - y * x_dir.dot(y)).normalized()
	var z := x.cross(y).normalized()
	var xf := Transform3D(Basis(x, y, z), p)
	var anchor := Node3D.new()
	anchor.name = nm
	anchor.transform = xf
	rig.add_child(anchor)
	b.anchors[nm] = anchor
	b._sites[nm] = xf
	return xf


static func _frame(origin: Vector3, x_dir: Vector3, up: Vector3) -> Transform3D:
	var x := x_dir.normalized()
	var y := (up - x * up.dot(x)).normalized()
	var z := x.cross(y).normalized()
	return Transform3D(Basis(x, y, z), origin)


static func animate(b, jolt: float, env: float, fidget: float, twitch: float, t: float) -> void:
	var head: Node3D = b.parts["head"]
	var hb: Transform3D = b.parts["head_base"]
	# Rotating about +Z by a negative angle lifts the -X-pointing head.
	var lift := env * 0.45 + jolt * 0.25 + fidget * 0.12 * (0.5 + 0.5 * sin(t * 0.7))
	var yaw := fidget * 0.35 * sin(t * 0.45) + jolt * 0.3 + twitch * 0.06 * sin(t * 31.0)
	head.transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, -lift), hb.origin)
	var flap := env * 0.6 + jolt * 0.5 + fidget * 0.18 * sin(t * 1.9) + twitch * 0.2 * sin(t * 41.0)
	var fl: Node3D = b.parts["fl"]
	var fr: Node3D = b.parts["fr"]
	var flb: Transform3D = b.parts["fl_base"]
	var frb: Transform3D = b.parts["fr_base"]
	# Raise the flippers by rotating about their own Z (the flipper's X tips up).
	fl.transform = Transform3D(flb.basis * Basis(Vector3.BACK, flap * 0.5) * Basis(Vector3.RIGHT, flap * 0.3), flb.origin)
	fr.transform = Transform3D(frb.basis * Basis(Vector3.BACK, (flap * 0.5 - fidget * 0.1 * sin(t * 1.3))) * Basis(Vector3.RIGHT, -flap * 0.3), frb.origin)
	var rear: Node3D = b.parts["rear"]
	var rb: Transform3D = b.parts["rear_base"]
	rear.transform = Transform3D(Basis(Vector3.BACK, env * 0.5 + jolt * 0.3 + fidget * 0.08 * sin(t * 1.1)) * Basis(Vector3.UP, fidget * 0.15 * sin(t * 0.8)), rb.origin)


static func set_limb_removed(b, removed: bool) -> void:
	var n: Node3D = b.parts.get("limb_node")
	if n != null:
		n.visible = not removed
