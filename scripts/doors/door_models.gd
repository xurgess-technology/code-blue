extends RefCounted
## Procedural door models in the hospital's primitive style (scripts/level/piece_factory.gd's Geo:
## vertex-coloured boxes merged into one ArrayMesh with a solid, a glowing and a glass surface).
## No CC0 door model fits (see ASSETS.md, "Doors"). Every mesh is built once and shared.
##
## Frames: a leaf mesh has its hinge edge at the origin, runs along +X for its length, stands on
## the floor (y 0), and is centred on z = 0 (thickness along Z). A sliding panel is centred on its
## own x. A frame mesh is centred on the doorway, in the door plane, its faces toward +Z (the face
## side) and -Z (the tunnel).

const Factory := preload("res://scripts/level/piece_factory.gd")

const LEAF_H := 2.18
const LEAF_T := 0.05

# Palette (hospital greens, brushed steel, the wing gates in dark painted steel).
const LAMINATE := Color(0.66, 0.70, 0.64)
const LAMINATE_EDGE := Color(0.48, 0.52, 0.47)
const STEEL := Color(0.62, 0.64, 0.66)
const DARK_STEEL := Color(0.26, 0.30, 0.33)
const GATE_PAINT := Color(0.24, 0.33, 0.37)
const OR_PAINT := Color(0.70, 0.73, 0.74)
const RUBBER := Color(0.08, 0.08, 0.09)
const HAZARD_Y := Color(0.80, 0.62, 0.08)
const HAZARD_K := Color(0.09, 0.09, 0.08)
const FRAME := Color(0.52, 0.56, 0.55)
const GLASS := Color(0.55, 0.72, 0.75, 0.28)
const WIRED_GLASS := Color(0.42, 0.55, 0.56, 0.45)
const ALU := Color(0.70, 0.72, 0.74)

static var _cache := {}


## A room door leaf: laminate slab, steel kick and push plates, a lever, a narrow vision panel.
static func hinged_leaf(length: float) -> ArrayMesh:
	var key := "hinged|%.3f" % length
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	var L := length
	var win_x := L * 0.66
	var win_w := 0.16
	var win_y0 := 1.12
	var win_y1 := 1.86
	# Slab around the vision panel.
	g.box(Vector3(L, win_y0, LEAF_T), Vector3(L * 0.5, win_y0 * 0.5, 0.0), LAMINATE)
	g.box(Vector3(L, LEAF_H - win_y1, LEAF_T), Vector3(L * 0.5, (win_y1 + LEAF_H) * 0.5, 0.0), LAMINATE)
	var left := win_x - win_w * 0.5
	var right := win_x + win_w * 0.5
	g.box(Vector3(left, win_y1 - win_y0, LEAF_T), Vector3(left * 0.5, (win_y0 + win_y1) * 0.5, 0.0), LAMINATE)
	g.box(Vector3(L - right, win_y1 - win_y0, LEAF_T), Vector3((right + L) * 0.5, (win_y0 + win_y1) * 0.5, 0.0), LAMINATE)
	g.box(Vector3(win_w, win_y1 - win_y0, 0.012), Vector3(win_x, (win_y0 + win_y1) * 0.5, 0.0), GLASS, 2)
	# Steel trim of the vision panel, both faces.
	for z in [LEAF_T * 0.5 + 0.004, -LEAF_T * 0.5 - 0.004]:
		g.box(Vector3(win_w + 0.05, 0.025, 0.008), Vector3(win_x, win_y0, z), STEEL)
		g.box(Vector3(win_w + 0.05, 0.025, 0.008), Vector3(win_x, win_y1, z), STEEL)
		g.box(Vector3(0.025, win_y1 - win_y0, 0.008), Vector3(left, (win_y0 + win_y1) * 0.5, z), STEEL)
		g.box(Vector3(0.025, win_y1 - win_y0, 0.008), Vector3(right, (win_y0 + win_y1) * 0.5, z), STEEL)
		# Kick plate and push plate.
		g.box(Vector3(L - 0.06, 0.26, 0.006), Vector3(L * 0.5, 0.15, z), STEEL)
		g.box(Vector3(0.1, 0.34, 0.006), Vector3(L - 0.16, 1.05, z), STEEL)
	# Edge bands and a lever on each face.
	g.box(Vector3(0.02, LEAF_H, LEAF_T + 0.004), Vector3(0.01, LEAF_H * 0.5, 0.0), LAMINATE_EDGE)
	g.box(Vector3(0.02, LEAF_H, LEAF_T + 0.004), Vector3(L - 0.01, LEAF_H * 0.5, 0.0), LAMINATE_EDGE)
	for sgn in [1.0, -1.0]:
		g.box(Vector3(0.06, 0.1, 0.03), Vector3(L - 0.09, 1.0, sgn * (LEAF_T * 0.5 + 0.015)), STEEL)
		g.box(Vector3(0.16, 0.025, 0.025), Vector3(L - 0.15, 1.0, sgn * (LEAF_T * 0.5 + 0.045)), STEEL)
	# Hinges.
	for y in [0.3, 1.1, 1.9]:
		g.cyl(0.018, 0.12, Vector3(0.0, y, 0.0), DARK_STEEL, "y", 8)
	var m := g.commit()
	_cache[key] = m
	return m


## A leaf of a pair of room double doors: the same slab with a wider, lower window and a push plate.
static func double_leaf(length: float) -> ArrayMesh:
	var key := "double|%.3f" % length
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	var L := length
	var wx0 := L * 0.28
	var wx1 := L * 0.72
	var wy0 := 1.2
	var wy1 := 1.62
	g.box(Vector3(L, wy0, LEAF_T), Vector3(L * 0.5, wy0 * 0.5, 0.0), LAMINATE)
	g.box(Vector3(L, LEAF_H - wy1, LEAF_T), Vector3(L * 0.5, (wy1 + LEAF_H) * 0.5, 0.0), LAMINATE)
	g.box(Vector3(wx0, wy1 - wy0, LEAF_T), Vector3(wx0 * 0.5, (wy0 + wy1) * 0.5, 0.0), LAMINATE)
	g.box(Vector3(L - wx1, wy1 - wy0, LEAF_T), Vector3((wx1 + L) * 0.5, (wy0 + wy1) * 0.5, 0.0), LAMINATE)
	g.box(Vector3(wx1 - wx0, wy1 - wy0, 0.012), Vector3((wx0 + wx1) * 0.5, (wy0 + wy1) * 0.5, 0.0), GLASS, 2)
	for z in [LEAF_T * 0.5 + 0.004, -LEAF_T * 0.5 - 0.004]:
		g.box(Vector3(wx1 - wx0 + 0.04, 0.02, 0.008), Vector3((wx0 + wx1) * 0.5, wy0, z), STEEL)
		g.box(Vector3(wx1 - wx0 + 0.04, 0.02, 0.008), Vector3((wx0 + wx1) * 0.5, wy1, z), STEEL)
		g.box(Vector3(0.02, wy1 - wy0, 0.008), Vector3(wx0, (wy0 + wy1) * 0.5, z), STEEL)
		g.box(Vector3(0.02, wy1 - wy0, 0.008), Vector3(wx1, (wy0 + wy1) * 0.5, z), STEEL)
		g.box(Vector3(L - 0.06, 0.3, 0.006), Vector3(L * 0.5, 0.17, z), STEEL)
		g.box(Vector3(0.12, 0.42, 0.006), Vector3(L - 0.14, 1.0, z), STEEL)
	g.box(Vector3(0.02, LEAF_H, LEAF_T + 0.004), Vector3(0.01, LEAF_H * 0.5, 0.0), LAMINATE_EDGE)
	g.box(Vector3(0.012, LEAF_H, LEAF_T + 0.01), Vector3(L - 0.006, LEAF_H * 0.5, 0.0), RUBBER)
	for y in [0.3, 1.1, 1.9]:
		g.cyl(0.018, 0.12, Vector3(0.0, y, 0.0), DARK_STEEL, "y", 8)
	var m := g.commit()
	_cache[key] = m
	return m


## A leaf of the heavy automatic doors: painted steel, a small square wired-glass window, a push
## bar, a rubber seal on the meeting edge and (the wing gates) a hazard band at the bottom.
static func heavy_leaf(length: float, gate: bool) -> ArrayMesh:
	var key := "heavy|%.3f|%s" % [length, str(gate)]
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	var L := length
	var paint := GATE_PAINT if gate else OR_PAINT
	var T := LEAF_T + 0.02
	var wc := L * 0.62
	var ws := 0.3
	var wy0 := 1.28
	var wy1 := wy0 + ws
	g.box(Vector3(L, wy0, T), Vector3(L * 0.5, wy0 * 0.5, 0.0), paint)
	g.box(Vector3(L, LEAF_H - wy1, T), Vector3(L * 0.5, (wy1 + LEAF_H) * 0.5, 0.0), paint)
	g.box(Vector3(wc - ws * 0.5, ws, T), Vector3((wc - ws * 0.5) * 0.5, wy0 + ws * 0.5, 0.0), paint)
	g.box(Vector3(L - wc - ws * 0.5, ws, T), Vector3((wc + ws * 0.5 + L) * 0.5, wy0 + ws * 0.5, 0.0), paint)
	g.box(Vector3(ws, ws, 0.014), Vector3(wc, wy0 + ws * 0.5, 0.0), WIRED_GLASS, 2)
	for z in [T * 0.5 + 0.005, -T * 0.5 - 0.005]:
		# Window frame.
		g.box(Vector3(ws + 0.07, 0.035, 0.01), Vector3(wc, wy0, z), DARK_STEEL)
		g.box(Vector3(ws + 0.07, 0.035, 0.01), Vector3(wc, wy1, z), DARK_STEEL)
		g.box(Vector3(0.035, ws, 0.01), Vector3(wc - ws * 0.5, wy0 + ws * 0.5, z), DARK_STEEL)
		g.box(Vector3(0.035, ws, 0.01), Vector3(wc + ws * 0.5, wy0 + ws * 0.5, z), DARK_STEEL)
		# Wire mesh lines in the glass.
		for k in [1, 2]:
			g.box(Vector3(ws, 0.004, 0.004), Vector3(wc, wy0 + ws * k / 3.0, z * 0.2), DARK_STEEL)
			g.box(Vector3(0.004, ws, 0.004), Vector3(wc - ws * 0.5 + ws * k / 3.0, wy0 + ws * 0.5, z * 0.2), DARK_STEEL)
		# Kick plate.
		g.box(Vector3(L - 0.04, 0.34, 0.008), Vector3(L * 0.5, 0.19, z), STEEL if not gate else DARK_STEEL)
		if gate:
			# Hazard band: yellow and black diagonals, as alternating blocks.
			var n := int(L / 0.14)
			for i in n:
				var col := HAZARD_Y if i % 2 == 0 else HAZARD_K
				g.box(Vector3(L / n, 0.1, 0.004), Vector3((i + 0.5) * L / n, 0.43, z + signf(z) * 0.005), col)
	# Push bars across both faces.
	for sgn in [1.0, -1.0]:
		g.box(Vector3(L * 0.7, 0.05, 0.05), Vector3(L * 0.5, 1.02, sgn * (T * 0.5 + 0.06)), STEEL)
		for x in [L * 0.18, L * 0.82]:
			g.box(Vector3(0.04, 0.08, 0.06), Vector3(x, 1.02, sgn * (T * 0.5 + 0.03)), DARK_STEEL)
	g.box(Vector3(0.018, LEAF_H, T + 0.012), Vector3(L - 0.009, LEAF_H * 0.5, 0.0), RUBBER)
	for y in [0.25, 1.1, 1.95]:
		g.cyl(0.024, 0.16, Vector3(0.0, y, 0.0), DARK_STEEL, "y", 8)
	var m := g.commit()
	_cache[key] = m
	return m


## One sliding glass panel of the main doors, `width` wide, centred on its own x.
static func sliding_panel(width: float) -> ArrayMesh:
	var key := "sliding|%.3f" % width
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	var W := width
	var t := 0.045
	var fw := 0.06
	g.box(Vector3(W, fw, t), Vector3(0.0, fw * 0.5, 0.0), ALU)
	g.box(Vector3(W, fw, t), Vector3(0.0, LEAF_H - fw * 0.5, 0.0), ALU)
	g.box(Vector3(fw, LEAF_H, t), Vector3(-W * 0.5 + fw * 0.5, LEAF_H * 0.5, 0.0), ALU)
	g.box(Vector3(fw, LEAF_H, t), Vector3(W * 0.5 - fw * 0.5, LEAF_H * 0.5, 0.0), ALU)
	g.box(Vector3(W - fw * 2.0, 0.09, t), Vector3(0.0, 0.13, 0.0), ALU)
	g.box(Vector3(W - fw * 2.0, LEAF_H - fw * 2.0 - 0.13, 0.01), Vector3(0.0, (fw + 0.18 + LEAF_H - fw) * 0.5, 0.0), GLASS, 2)
	# A frosted band at eye height so the glass reads as glass.
	for z in [0.008, -0.008]:
		g.box(Vector3(W - fw * 2.0, 0.08, 0.002), Vector3(0.0, 1.45, z), Color(0.82, 0.88, 0.9, 0.6), 2)
	var m := g.commit()
	_cache[key] = m
	return m


## A jamb-and-head trim around a doorway, `width` wide, on the face side of the door plane (the
## tunnel behind it stays plain). `heavy`: thicker steel for the automatic doors.
static func frame(width: float, heavy: bool) -> ArrayMesh:
	var key := "frame|%.3f|%s" % [width, str(heavy)]
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	var W := width
	var tw := 0.07 if heavy else 0.05
	var depth := 0.06
	var col := DARK_STEEL if heavy else FRAME
	var z := 0.03
	g.box(Vector3(tw, 2.25, depth), Vector3(-W * 0.5 + tw * 0.5, 1.125, z), col)
	g.box(Vector3(tw, 2.25, depth), Vector3(W * 0.5 - tw * 0.5, 1.125, z), col)
	g.box(Vector3(W, tw, depth), Vector3(0.0, 2.25 - tw * 0.5, z), col)
	var m := g.commit()
	_cache[key] = m
	return m


## The sliding doors' track housing along the head, both faces.
static func slide_header(width: float) -> ArrayMesh:
	var key := "slide_header|%.3f" % width
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	g.box(Vector3(width, 0.1, 0.16), Vector3(0.0, 2.2, 0.0), ALU)
	g.box(Vector3(0.08, 0.02, 0.17), Vector3(width * 0.36, 2.16, 0.0), Color(0.2, 0.9, 0.4), 1)
	var m := g.commit()
	_cache[key] = m
	return m


## The wing gate's name plate and lock lamp housing above the doors, on the face side.
static func gate_header(width: float) -> ArrayMesh:
	var key := "gate_header|%.3f" % width
	if _cache.has(key):
		return _cache[key]
	var g := Factory.Geo.new()
	g.box(Vector3(width, 0.14, 0.08), Vector3(0.0, 2.25 - 0.07, 0.07), DARK_STEEL)
	g.box(Vector3(0.34, 0.14, 0.08), Vector3(0.0, 2.25 + 0.2, 0.05), DARK_STEEL)
	var m := g.commit()
	_cache[key] = m
	return m


## The lock lamp lens (its own mesh so each gate can swap its material).
static func lamp_lens() -> Mesh:
	if not _cache.has("lens"):
		var bm := BoxMesh.new()
		bm.size = Vector3(0.26, 0.08, 0.03)
		_cache["lens"] = bm
	return _cache["lens"]


static var _lamp_mats := {}


## "locked" red, "unlocking" amber, "open" green, "off".
static func lamp_material(state: String) -> Material:
	if _lamp_mats.has(state):
		return _lamp_mats[state]
	var m := StandardMaterial3D.new()
	var col := Color(0.15, 0.15, 0.15)
	var e := 0.0
	match state:
		"locked":
			col = Color(1.0, 0.12, 0.08)
			e = 3.5
		"unlocking":
			col = Color(1.0, 0.62, 0.1)
			e = 3.0
		"open":
			col = Color(0.2, 1.0, 0.35)
			e = 2.2
	m.albedo_color = col
	if e > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = e
	_lamp_mats[state] = m
	return m
