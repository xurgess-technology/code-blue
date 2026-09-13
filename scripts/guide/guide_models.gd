class_name GuideModels
extends RefCounted
## The medical guide as a world object, and the lectern it is (in theory) chained to.
## Primitives plus small generated textures; no collision, no scripts, safe to build anywhere.
##
##   make_book()     origin at the base of the back cover, spine along -X, about 0.24 x 0.31 m
##   make_lectern()  origin on the floor, reader stands on +Z. Has a Marker3D "BookRest" (and
##                   meta "book_rest", a Transform3D) where make_book()'s origin should go.

const Art := preload("res://scripts/guide/guide_art.gd")

const BOOK_W := 0.24
const BOOK_D := 0.31
const BOOK_T := 0.062
const DESK_TILT_DEG := 18.0

static var _tex := {}


# ---------------------------------------------------------------------------
# The binder
# ---------------------------------------------------------------------------

static func make_book() -> Node3D:
	var root := Node3D.new()
	root.name = "GuideBook"
	var cover := _mat(Color.WHITE, 0.72)
	cover.albedo_texture = _cover_texture()
	var cover_edge := _mat(Color("5a1c16"), 0.8)
	var pages := _mat(Color.WHITE, 0.95)
	pages.albedo_texture = _page_edge_texture()
	pages.uv1_scale = Vector3(1, 1, 1)
	var metal := _mat(Color("9aa0a6"), 0.35, 0.9)

	var board := 0.0055
	# Back and front boards, slightly bigger than the page block.
	_box(root, Vector3(BOOK_W, board, BOOK_D), Vector3(0, board * 0.5, 0), cover)
	var front := _box(root, Vector3(BOOK_W, board, BOOK_D), Vector3(0.002, BOOK_T - board * 0.5, 0), cover)
	front.rotation_degrees = Vector3(0, 0, 0.0)
	# Spine: a rounded bar along -X
	var spine := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BOOK_T * 0.5
	cyl.bottom_radius = BOOK_T * 0.5
	cyl.height = BOOK_D
	cyl.radial_segments = 14
	spine.mesh = cyl
	spine.material_override = cover_edge
	spine.rotation_degrees = Vector3(90, 0, 0)
	spine.scale = Vector3(0.45, 1, 1)
	spine.position = Vector3(-BOOK_W * 0.5, BOOK_T * 0.5, 0)
	root.add_child(spine)
	# Page block, pushed a little toward the fore-edge
	var block_h := BOOK_T - board * 2.0 - 0.002
	_box(root, Vector3(BOOK_W - 0.018, block_h, BOOK_D - 0.012), Vector3(0.004, board + block_h * 0.5 + 0.001, 0), pages)

	# Index tabs poking out of the fore-edge (+X), in the UI's tab colours.
	var n := 9
	for i in n:
		var col := Art.tab_colour(i) if i < 6 else Art.LOCKED_TAB
		var tab := _box(root, Vector3(0.016, 0.0022, 0.026),
			Vector3(BOOK_W * 0.5 + 0.002, board + 0.006 + block_h * (float(i) / n) * 0.85, -BOOK_D * 0.5 + 0.03 + i * 0.03),
			_mat(col, 0.5))
		tab.name = "Tab%d" % i

	# Ring hinge bumps on the spine.
	for z in [-0.1, 0.0, 0.1]:
		_box(root, Vector3(0.008, 0.02, 0.018), Vector3(-BOOK_W * 0.5 - 0.012, BOOK_T * 0.5, z), metal)

	# A white label on the cover and the scrawl across it.
	var top := BOOK_T + 0.0016
	var label := _box(root, Vector3(0.15, 0.0008, 0.05), Vector3(0.012, top, -0.085), _mat(Color("e9e3d2"), 0.9))
	label.rotation_degrees = Vector3(0, 2.5, 0)
	_label(root, "MEDICAL REFERENCE", "type_bold", Color("2b2119"), 0.00022, Vector3(0.012, top + 0.0009, -0.092), 2.5)
	_label(root, "night shift / vol. 3", "type", Color("5c4b3b"), 0.00017, Vector3(0.012, top + 0.0009, -0.072), 2.5)
	_label(root, "DO NOT", "marker", Color("f2ecd8"), 0.00052, Vector3(0.0, top + 0.0004, 0.03), -8.0)
	_label(root, "REMOVE", "marker", Color("f2ecd8"), 0.00052, Vector3(0.012, top + 0.0004, 0.085), -6.0)
	# Tape on the torn corner
	var tape := _mat(Color(0.93, 0.89, 0.72, 0.7), 0.6)
	tape.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t := _box(root, Vector3(0.08, 0.001, 0.024), Vector3(BOOK_W * 0.5 - 0.02, top + 0.0003, BOOK_D * 0.5 - 0.025), tape)
	t.rotation_degrees = Vector3(0, 40, 0)

	# The cut end of the chain, still hanging off the spine.
	var chain := Node3D.new()
	chain.name = "ChainStub"
	chain.position = Vector3(-BOOK_W * 0.5 - 0.022, 0.012, BOOK_D * 0.5 - 0.03)
	root.add_child(chain)
	for i in 3:
		var link := _link(metal, 0.0075, 0.0028)
		link.position = Vector3(-i * 0.019, 0.0, i * 0.006)
		link.rotation_degrees = Vector3(0, 90 + i * 12.0, 90.0 if i % 2 == 0 else 0.0)
		chain.add_child(link)
	return root


# ---------------------------------------------------------------------------
# The lectern
# ---------------------------------------------------------------------------

static func make_lectern() -> Node3D:
	var root := Node3D.new()
	root.name = "GuideLectern"
	var wood := _mat(Color.WHITE, 0.62)
	wood.albedo_texture = _wood_texture()
	wood.uv1_triplanar = true
	wood.uv1_scale = Vector3(1.6, 1.6, 1.6)
	var dark_wood := _mat(Color("3a2618"), 0.7)
	dark_wood.albedo_texture = _wood_texture()
	dark_wood.uv1_triplanar = true
	dark_wood.uv1_scale = Vector3(1.6, 1.6, 1.6)
	dark_wood.albedo_color = Color(0.62, 0.55, 0.5)
	var metal := _mat(Color("8d9398"), 0.35, 0.9)
	var rubber := _mat(Color("1a1a1a"), 0.9)

	# Base: a heavy plinth with rubber feet
	_box(root, Vector3(0.5, 0.05, 0.42), Vector3(0, 0.035, 0), dark_wood)
	for x in [-0.21, 0.21]:
		for z in [-0.17, 0.17]:
			_box(root, Vector3(0.05, 0.012, 0.05), Vector3(x, 0.006, z), rubber)
	# Column: a boxed post, slightly tapered with a collar
	_box(root, Vector3(0.13, 0.86, 0.11), Vector3(0, 0.49, -0.02), wood)
	_box(root, Vector3(0.17, 0.04, 0.15), Vector3(0, 0.08, -0.02), dark_wood)
	_box(root, Vector3(0.17, 0.035, 0.15), Vector3(0, 0.92, -0.02), dark_wood)
	# Brass plate on the front of the post
	_box(root, Vector3(0.08, 0.1, 0.004), Vector3(0, 0.72, 0.037), _mat(Color("b08d45"), 0.35, 0.8))
	_label_upright(root, "REF.", "type_bold", Color("3a2a12"), 0.00028, Vector3(0, 0.735, 0.04))
	_label_upright(root, "DESK", "type_bold", Color("3a2a12"), 0.00028, Vector3(0, 0.705, 0.04))

	# Slanted desk. Pivot on the desk centre, tilted so the reader's edge (+Z) is lower.
	var desk := Node3D.new()
	desk.name = "Desk"
	desk.position = Vector3(0, 1.03, 0.0)
	desk.rotation_degrees = Vector3(DESK_TILT_DEG, 0, 0)
	root.add_child(desk)
	var top_t := 0.03
	_box(desk, Vector3(0.58, top_t, 0.46), Vector3(0, 0, 0), wood)
	_box(desk, Vector3(0.58, 0.045, 0.025), Vector3(0, top_t * 0.5 + 0.018, 0.23 - 0.0125), dark_wood)   # lip
	_box(desk, Vector3(0.025, 0.05, 0.46), Vector3(-0.29, -0.02, 0), dark_wood)
	_box(desk, Vector3(0.025, 0.05, 0.46), Vector3(0.29, -0.02, 0), dark_wood)
	# Under-desk support block joining it to the post
	_box(root, Vector3(0.2, 0.12, 0.18), Vector3(0, 0.97, -0.02), dark_wood)

	var rest := Marker3D.new()
	rest.name = "BookRest"
	rest.position = Vector3(0.0, top_t * 0.5, 0.23 - 0.025 - BOOK_D * 0.5 - 0.004)
	desk.add_child(rest)
	root.set_meta("book_rest", desk.transform * rest.transform)

	# Eye bolt on the left side of the desk and the broken chain hanging from it.
	var bolt_local := Vector3(-0.305, -0.01, 0.12)
	var bolt_world: Vector3 = desk.transform * bolt_local
	var eye := _link(metal, 0.012, 0.003)
	eye.position = bolt_world
	eye.rotation_degrees = Vector3(0, 0, 90)
	root.add_child(eye)
	var chain := Node3D.new()
	chain.name = "BrokenChain"
	chain.position = bolt_world + Vector3(-0.004, -0.014, 0)
	root.add_child(chain)
	var pitch := 0.026
	var count := 11
	for i in count:
		var sway := sin(i * 0.45) * 0.006
		var link := _link(metal, 0.0085, 0.0028)
		link.position = Vector3(-0.004 - i * 0.0015 + sway, -i * pitch, i * 0.0018)
		link.rotation_degrees = Vector3(90, 90.0 if i % 2 == 0 else 0.0, 0)
		link.scale = Vector3(1, 1, 1.55)
		chain.add_child(link)
	# The last link was cut: two bent halves, pulled apart.
	var y_end := -count * pitch
	for s in [-1.0, 1.0]:
		var half := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = 0.0028
		c.bottom_radius = 0.0028
		c.height = 0.022
		c.radial_segments = 6
		half.mesh = c
		half.material_override = metal
		half.position = Vector3(-0.02 + s * 0.007, y_end + 0.004, 0.02)
		half.rotation_degrees = Vector3(0, 0, s * 28.0)
		chain.add_child(half)
	return root


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _link(mat: Material, radius: float, wire: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = radius - wire
	t.outer_radius = radius + wire
	t.rings = 14
	t.ring_segments = 6
	mi.mesh = t
	mi.material_override = mat
	return mi


static func _label(parent: Node3D, text: String, role: String, col: Color, px: float, pos: Vector3, yaw_deg: float) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = Art.world_font(role)
	l.font_size = 96
	l.outline_size = 0
	l.pixel_size = px * 0.667
	l.modulate = col
	l.shaded = true
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	l.position = pos
	# Lie flat on the cover, readable from the fore-edge side... from +Z, the reader's side.
	l.rotation_degrees = Vector3(-90, yaw_deg, 0)
	parent.add_child(l)
	return l


static func _label_upright(parent: Node3D, text: String, role: String, col: Color, px: float, pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = Art.world_font(role)
	l.font_size = 96
	l.outline_size = 0
	l.pixel_size = px * 0.667
	l.modulate = col
	l.shaded = true
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	l.position = pos
	parent.add_child(l)
	return l


static func _cover_texture() -> Texture2D:
	if _tex.has("cover"):
		return _tex.cover
	var w := 128
	var h := 160
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var n := FastNoiseLite.new()
	n.seed = 7
	n.frequency = 0.05
	var scuff := FastNoiseLite.new()
	scuff.seed = 21
	scuff.frequency = 0.16
	var base := Color("6a211a")
	for y in h:
		for x in w:
			var v := n.get_noise_2d(x, y) * 0.5 + 0.5
			var c := base * (0.78 + 0.35 * v)
			var s := scuff.get_noise_2d(x, y)
			if s > 0.45:
				c = c.lerp(Color("a07a66"), (s - 0.45) * 1.4)
			var e := mini(mini(x, y), mini(w - 1 - x, h - 1 - y))
			if e < 4:
				c = c.lerp(Color("9c7560"), (4 - e) / 5.0 * (0.5 + 0.5 * v))
			c.a = 1.0
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex.cover = tex
	return tex


static func _page_edge_texture() -> Texture2D:
	if _tex.has("pages"):
		return _tex.pages
	var w := 64
	var h := 64
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var rows: Array = []
	for y in h:
		rows.append(rng.randf())
	for y in h:
		for x in w:
			var v: float = rows[y]
			var c := Color("e8dcc0") * (0.86 + 0.16 * v)
			c.a = 1.0
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex.pages = tex
	return tex


static func _wood_texture() -> Texture2D:
	if _tex.has("wood"):
		return _tex.wood
	var w := 96
	var h := 256
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var n := FastNoiseLite.new()
	n.seed = 3
	n.frequency = 0.03
	var base := Color("7a5234")
	for y in h:
		for x in w:
			var warp := n.get_noise_2d(x * 0.25, y * 0.12) * 9.0
			var grain := sin((x + warp) * 0.55) * 0.5 + 0.5
			var c := base * (0.78 + 0.22 * grain + 0.08 * n.get_noise_2d(x * 3.0, y * 0.2))
			c.a = 1.0
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex.wood = tex
	return tex
