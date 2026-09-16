extends RefCounted
## Visuals for every piece in piece_defs.gd.
##
## `parts(kind)` returns the meshes that draw one piece, each with its transform in the piece
## frame (origin on the floor at the centre of the footprint, front toward -Z; wall-mounted
## pieces: origin on the floor at the wall face). Parts are built once per kind and shared by
## every instance, so the builder can draw each kind as a few MultiMeshes per level chunk.
##
## A kind uses an Assets model when there is one (see ASSET), otherwise primitives merged into
## one vertex-coloured ArrayMesh (up to three surfaces: solid, glowing, glass). Some kinds add
## primitives to their model (EXTRA). Everything works without any asset on disk.

const Defs := preload("res://scripts/level/piece_defs.gd")

## Kind -> Assets key. Models are centred on their footprint with their base on the floor.
const ASSET := {
	"curtain": "prop/curtain", "bedside": "hosp/bedside", "visitor_chair": "hosp/chair_cushion",
	"wall_sink": "hosp/sink_wall", "bin": "prop/bin", "steel_shelves": "hosp/steel_shelves",
	"storage_cabinet": "hosp/cabinet_tall", "box_stack": "hosp/box_closed",
	"office_desk": "hosp/office_desk", "office_chair": "prop/chair", "filing_cabinet": "hosp/filing_cabinet",
	"bookcase": "hosp/bookcase", "school_chair": "hosp/school_chair", "magazine_table": "hosp/coffee_table",
	"tv_wall": "hosp/tv", "plant": "hosp/plant", "vending": "hosp/vending", "computer": "prop/screen",
	"wheelchair": "hosp/wheelchair", "instrument_cart": "hosp/tool_cart", "wet_floor": "hosp/wet_floor",
	"washer": "hosp/washer", "cafeteria_table": "hosp/table", "register": "hosp/register",
	"fridge_kitchen": "hosp/fridge_kitchen", "sofa": "hosp/sofa", "armchair": "hosp/armchair",
	"break_table": "hosp/table", "wall_phone": "hosp/wall_phone", "wall_clock": "hosp/wall_clock",
	"extinguisher": "hosp/extinguisher", "security_camera": "hosp/security_camera",
	"doormat": "hosp/doormat", "scrub_sink": "hosp/sink_cabinet", "ambulance": "hosp/ambulance",
	"van": "hosp/van", "sedan": "hosp/sedan", "suv": "hosp/suv", "hatchback": "hosp/hatchback",
	"covered_car": "hosp/covered_car", "street_light": "hosp/street_light", "dumpster": "hosp/dumpster",
	"cone": "hosp/cone", "barrier": "hosp/barrier", "mirror": "hosp/mirror", "coat_rack": "hosp/coat_rack",
}

## Models laid on top of a primitive kind: [asset key, position in the piece frame, yaw degrees].
const EXTRA := {
	"stall": [["hosp/toilet", Vector3(0.0, 0.0, 0.42), 0.0]],
	"lab_bench_scope": [["hosp/microscope", Vector3(-0.35, 0.92, 0.0), 0.0]],
	"kitchen_counter_coffee": [["hosp/coffee_machine", Vector3(-0.35, 0.95, 0.08), 0.0], ["hosp/microwave", Vector3(0.35, 0.95, 0.1), 0.0]],
	"kitchen_counter": [["hosp/radio", Vector3(0.3, 0.95, 0.15), -12.0]],
	"lab_island": [["hosp/laptop", Vector3(0.4, 0.92, 0.2), 150.0]],
	"console_desk": [["prop/screen", Vector3(-0.35, 0.76, 0.12), 0.0], ["prop/screen", Vector3(0.35, 0.76, 0.12), 0.0], ["hosp/keyboard", Vector3(0.0, 0.76, -0.12), 0.0]],
	"reception_desk": [["prop/screen", Vector3(-0.7, 0.77, 0.15), 180.0], ["hosp/keyboard", Vector3(-0.7, 0.77, -0.05), 180.0],
			["hosp/plant_small", Vector3(1.2, 1.12, -0.33), 0.0]],
	"shop_table": [["hosp/box_open", Vector3(-0.45, 0.8, 0.0), 10.0], ["hosp/medical_box", Vector3(0.45, 0.8, 0.0), -8.0]],
	"shop_crates": [["hosp/box_closed", Vector3(-0.2, 0.0, 0.0), 0.0], ["hosp/box_closed", Vector3(0.22, 0.0, 0.05), 14.0], ["hosp/box_closed", Vector3(0.0, 0.62, 0.0), -9.0]],
	"mop_bucket": [["hosp/bucket", Vector3(0.0, 0.0, 0.0), 0.0]],
	"magazine_table": [["hosp/books", Vector3(0.25, 0.41, 0.05), 20.0]],
	"office_desk": [["prop/screen", Vector3(0.35, 0.75, 0.25), 0.0], ["hosp/keyboard", Vector3(0.35, 0.75, 0.0), 0.0],
			["hosp/plant_small", Vector3(-0.75, 0.75, 0.25), 0.0]],
}

## Kinds whose model is replaced by primitives even when the asset exists, because the model's
## proportions would not match the piece (tops that items or patients rest on).
const PRIMITIVE_ONLY := []

static var _cache := {}
static var _solid_mat: StandardMaterial3D
static var _glow_mat: StandardMaterial3D
static var _glass_mat: StandardMaterial3D


## [{mesh: Mesh, xform: Transform3D}] for one piece of `kind`.
static func parts(kind: String) -> Array:
	if _cache.has(kind):
		return _cache[kind]
	var out: Array = []
	var key: String = ASSET.get(kind, "")
	var base_xf := _mount_xform(kind)
	if key != "" and not PRIMITIVE_ONLY.has(kind):
		out.append_array(_asset_parts(key, base_xf))
	if out.is_empty():
		var p := _primitive(kind)
		if p != null:
			out.append({"mesh": p, "xform": Transform3D.IDENTITY})
	for e in EXTRA.get(kind, []):
		var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(e[2]))), e[1])
		out.append_array(_asset_parts(e[0], xf))
	_cache[kind] = out
	return out


## Wall-mounted models stand on the floor at their base; lift them to their mount height and
## push them off the wall so their back touches it.
static func _mount_xform(kind: String) -> Transform3D:
	if not Defs.mounted(kind):
		return Transform3D.IDENTITY
	var s := Defs.size(kind)
	return Transform3D(Basis.IDENTITY, Vector3(0.0, Defs.mount_height(kind), -s.z * 0.5))


static func assets_node() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Assets")
	return null


## Every mesh in an Assets model, with transforms relative to the piece frame.
static func _asset_parts(key: String, xf: Transform3D) -> Array:
	var out: Array = []
	var a := assets_node()
	if a == null or not a.has(key):
		return out
	var n = a.spawn(key)
	if not (n is Node3D):
		return out
	var root := n as Node3D
	for c in root.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var mesh: Mesh = mi.mesh
		var has_override := mi.material_override != null
		for s in mi.get_surface_override_material_count():
			if mi.get_surface_override_material(s) != null:
				has_override = true
		if has_override and mesh is ArrayMesh:
			mesh = (mesh as ArrayMesh).duplicate()
			for s in mesh.get_surface_count():
				var m: Material = mi.material_override
				if m == null:
					m = mi.get_surface_override_material(s)
				if m != null:
					(mesh as ArrayMesh).surface_set_material(s, m)
		out.append({"mesh": mesh, "xform": xf * _rel(root, mi)})
	root.free()
	return out


static func _rel(root: Node3D, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur := node
	while cur != null and cur != root:
		t = cur.transform * t
		cur = cur.get_parent() as Node3D
	return t


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

static func solid_material() -> StandardMaterial3D:
	if _solid_mat == null:
		_solid_mat = StandardMaterial3D.new()
		_solid_mat.resource_name = "piece_solid"
		_solid_mat.vertex_color_use_as_albedo = true
		_solid_mat.roughness = 0.62
	return _solid_mat


static func glow_material() -> StandardMaterial3D:
	if _glow_mat == null:
		_glow_mat = StandardMaterial3D.new()
		_glow_mat.resource_name = "piece_glow"
		_glow_mat.vertex_color_use_as_albedo = true
		_glow_mat.emission_enabled = true
		_glow_mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		_glow_mat.emission = Color(1, 1, 1)
		_glow_mat.emission_energy_multiplier = 1.6
		_glow_mat.roughness = 0.3
	return _glow_mat


static func glass_material() -> StandardMaterial3D:
	if _glass_mat == null:
		_glass_mat = StandardMaterial3D.new()
		_glass_mat.resource_name = "piece_glass"
		_glass_mat.vertex_color_use_as_albedo = true
		_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glass_mat.roughness = 0.08
		_glass_mat.metallic_specular = 0.8
	return _glass_mat


# ---------------------------------------------------------------------------
# Primitive mesh building
# ---------------------------------------------------------------------------

class Geo extends RefCounted:
	## Surfaces: 0 solid, 1 glow, 2 glass. Packed arrays are values in GDScript, so each lives
	## in its own member and is appended to in place.
	var v0 := PackedVector3Array()
	var n0 := PackedVector3Array()
	var c0 := PackedColorArray()
	var v1 := PackedVector3Array()
	var n1 := PackedVector3Array()
	var c1 := PackedColorArray()
	var v2 := PackedVector3Array()
	var n2 := PackedVector3Array()
	var c2 := PackedColorArray()

	func _tri(s: int, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
		# Godot front faces wind clockwise: emit a, c, b for a triangle a-b-c turning about +n.
		var n := (b - a).cross(c - a).normalized()
		match s:
			0:
				v0.append_array([a, c, b])
				n0.append_array([n, n, n])
				c0.append_array([col, col, col])
			1:
				v1.append_array([a, c, b])
				n1.append_array([n, n, n])
				c1.append_array([col, col, col])
			_:
				v2.append_array([a, c, b])
				n2.append_array([n, n, n])
				c2.append_array([col, col, col])

	func quad(s: int, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
		_tri(s, a, b, c, col)
		_tri(s, a, c, d, col)

	## Axis-aligned box of `size` centred at `pos`, turned by `basis` about its own centre.
	func box(size: Vector3, pos: Vector3, col: Color, s := 0, basis := Basis.IDENTITY) -> void:
		var h := size * 0.5
		var p := func(x: float, y: float, z: float) -> Vector3:
			return pos + basis * Vector3(x * h.x, y * h.y, z * h.z)
		var v := [p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(-1, 1, -1),
				p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1)]
		quad(s, v[0], v[3], v[2], v[1], col)   # -Z
		quad(s, v[5], v[6], v[7], v[4], col)   # +Z
		quad(s, v[4], v[7], v[3], v[0], col)   # -X
		quad(s, v[1], v[2], v[6], v[5], col)   # +X
		quad(s, v[3], v[7], v[6], v[2], col)   # +Y
		quad(s, v[4], v[0], v[1], v[5], col)   # -Y

	## Cylinder along `axis` ("y", "x" or "z").
	func cyl(r: float, length: float, pos: Vector3, col: Color, axis := "y", seg := 10, s := 0) -> void:
		var basis := Basis.IDENTITY
		if axis == "x":
			basis = Basis(Vector3(0, 0, 1), PI * 0.5)
		elif axis == "z":
			basis = Basis(Vector3(1, 0, 0), PI * 0.5)
		var hl := length * 0.5
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			var b0 := Vector3(cos(a0) * r, -hl, sin(a0) * r)
			var b1 := Vector3(cos(a1) * r, -hl, sin(a1) * r)
			var t0 := b0 + Vector3(0, length, 0)
			var t1 := b1 + Vector3(0, length, 0)
			quad(s, pos + basis * b0, pos + basis * t0, pos + basis * t1, pos + basis * b1, col)
			_tri(s, pos + basis * Vector3(0, hl, 0), pos + basis * t1, pos + basis * t0, col)
			_tri(s, pos + basis * Vector3(0, -hl, 0), pos + basis * b0, pos + basis * b1, col)

	func commit() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		var mats := [PieceFactoryMats.solid(), PieceFactoryMats.glow(), PieceFactoryMats.glass()]
		var sets := [[v0, n0, c0], [v1, n1, c1], [v2, n2, c2]]
		for i in 3:
			var arr: Array = sets[i]
			if (arr[0] as PackedVector3Array).is_empty():
				continue
			var a := []
			a.resize(Mesh.ARRAY_MAX)
			a[Mesh.ARRAY_VERTEX] = arr[0]
			a[Mesh.ARRAY_NORMAL] = arr[1]
			a[Mesh.ARRAY_COLOR] = arr[2]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mats[i])
		return mesh


## Lets the inner class reach the shared materials without a class_name.
class PieceFactoryMats extends RefCounted:
	static func solid() -> Material:
		return load("res://scripts/level/piece_factory.gd").solid_material()

	static func glow() -> Material:
		return load("res://scripts/level/piece_factory.gd").glow_material()

	static func glass() -> Material:
		return load("res://scripts/level/piece_factory.gd").glass_material()


# Palette.
const STEEL := Color(0.58, 0.61, 0.63)
const DARK_STEEL := Color(0.3, 0.32, 0.34)
const CHROME := Color(0.72, 0.74, 0.76)
const ENAMEL := Color(0.80, 0.82, 0.80)
const OFFWHITE := Color(0.74, 0.73, 0.68)
const DARK := Color(0.12, 0.13, 0.14)
const RUBBER := Color(0.07, 0.07, 0.08)
const SHEET := Color(0.70, 0.77, 0.80)
const PALE_GREEN := Color(0.52, 0.64, 0.58)
const TEAL := Color(0.22, 0.42, 0.44)
const WOOD := Color(0.42, 0.30, 0.20)
const LAMINATE := Color(0.62, 0.60, 0.55)
const RED := Color(0.55, 0.09, 0.07)
const BODY_BAG := Color(0.05, 0.05, 0.06)
const BLOOD := Color(0.24, 0.015, 0.01, 0.92)
const YELLOW := Color(0.85, 0.66, 0.08)
const BLUE_GREY := Color(0.36, 0.44, 0.50)
const BEIGE := Color(0.66, 0.60, 0.50)
const SCREEN := Color(0.20, 0.62, 0.55)
const LAMP := Color(1.0, 0.95, 0.82)


## Hub rebuild, chunk 5: a bare gurney (the "gurney" piece's frame and mattress) placed by `xf`.
## `open_frame` (the toppled one) swaps the lower tray for four corner posts, so on its side it reads
## as legs and wheels rather than two slabs.
static func _gurney_frame(g: Geo, xf: Transform3D, open_frame := false) -> void:
	var b := xf.basis
	var at := func(p: Vector3) -> Vector3: return xf * p
	g.box(Vector3(0.66, 0.05, 1.9), at.call(Vector3(0, 0.62, 0)), STEEL, 0, b)
	g.box(Vector3(0.62, 0.08, 1.9), at.call(Vector3(0, 0.69, 0)), BLUE_GREY, 0, b)
	for sx in [-0.34, 0.34]:
		g.box(Vector3(0.025, 0.1, 1.2), at.call(Vector3(sx, 0.72, -0.1)), CHROME, 0, b)
	if open_frame:
		for sx in [-0.26, 0.26]:
			for sz in [-0.8, 0.8]:
				g.box(Vector3(0.04, 0.56, 0.04), at.call(Vector3(sx, 0.34, sz)), CHROME, 0, b)
		for sz in [-0.8, 0.8]:
			g.box(Vector3(0.52, 0.04, 0.04), at.call(Vector3(0, 0.12, sz)), DARK_STEEL, 0, b)
		for sx in [-0.26, 0.26]:
			for sz in [-0.8, 0.8]:
				g.box(Vector3(0.05, 0.13, 0.13), at.call(Vector3(sx, 0.05, sz)), RUBBER, 0, b)
		return
	g.box(Vector3(0.5, 0.04, 1.4), at.call(Vector3(0, 0.16, 0)), DARK_STEEL, 0, b)
	g.box(Vector3(0.04, 0.5, 0.04), at.call(Vector3(0, 0.38, -0.55)), DARK_STEEL, 0, b * Basis(Vector3.RIGHT, 0.6))
	g.box(Vector3(0.04, 0.5, 0.04), at.call(Vector3(0, 0.38, 0.55)), DARK_STEEL, 0, b * Basis(Vector3.RIGHT, -0.6))
	for sx in [-0.24, 0.24]:
		for sz in [-0.68, 0.68]:
			g.box(Vector3(0.035, 0.09, 0.09), at.call(Vector3(sx, 0.045, sz)), RUBBER, 0, b)


## Hub rebuild, chunk 5: a zipped black body bag lying along Z (head toward +Z), bottom at `base`.
static func _body_bag(g: Geo, base: Vector3) -> void:
	g.box(Vector3(0.56, 0.2, 1.3), base + Vector3(0, 0.1, -0.18), BODY_BAG)
	g.box(Vector3(0.46, 0.24, 0.42), base + Vector3(0, 0.12, 0.62), BODY_BAG)          # shoulders
	g.box(Vector3(0.3, 0.2, 0.26), base + Vector3(0, 0.12, 0.9), BODY_BAG)             # head
	g.box(Vector3(0.4, 0.16, 0.3), base + Vector3(0, 0.09, -0.92), BODY_BAG)           # feet
	g.box(Vector3(0.022, 0.012, 1.5), base + Vector3(0.1, 0.245, 0.05), CHROME)       # the zip
	g.box(Vector3(0.05, 0.02, 0.08), base + Vector3(0.1, 0.25, 0.8), CHROME)
	g.box(Vector3(0.1, 0.004, 0.06), base + Vector3(-0.3, 0.1, -0.95), OFFWHITE, 0, Basis(Vector3.BACK, 1.2))   # toe tag


static func _casters(g: Geo, hx: float, hz: float, r := 0.045) -> void:
	for sx in [-hx, hx]:
		for sz in [-hz, hz]:
			g.cyl(r, 0.035, Vector3(sx, r, sz), RUBBER, "x", 8)


static func _counter_body(g: Geo, w: float, h: float, d: float, body: Color, top: Color) -> void:
	g.box(Vector3(w - 0.04, 0.08, d - 0.06), Vector3(0, 0.04, 0.02), DARK)
	g.box(Vector3(w - 0.02, h - 0.13, d - 0.04), Vector3(0, 0.08 + (h - 0.13) * 0.5, 0.0), body)
	g.box(Vector3(w, 0.05, d), Vector3(0, h - 0.025, 0), top)
	var doors := maxi(1, int(round(w / 0.5)))
	for i in doors:
		var x := -w * 0.5 + (i + 0.5) * w / doors
		g.box(Vector3(w / doors - 0.03, h - 0.22, 0.012), Vector3(x, 0.08 + (h - 0.13) * 0.5, -d * 0.5 + 0.012), body.lightened(0.07))
		g.box(Vector3(0.1, 0.018, 0.02), Vector3(x, h - 0.2, -d * 0.5), CHROME)


static func _primitive(kind: String) -> ArrayMesh:
	var g := Geo.new()
	var s := Defs.size(kind)
	var m := Defs.mount_height(kind)
	match kind:
		"hospital_bed":
			g.box(Vector3(0.9, 0.1, 2.0), Vector3(0, 0.42, 0), STEEL)
			g.box(Vector3(0.86, 0.16, 1.92), Vector3(0, 0.55, 0), SHEET)
			g.box(Vector3(0.88, 0.07, 0.95), Vector3(0, 0.655, -0.42), PALE_GREEN)
			g.box(Vector3(0.58, 0.1, 0.34), Vector3(0, 0.68, 0.74), ENAMEL, 0, Basis(Vector3.RIGHT, -0.25))
			g.box(Vector3(0.96, 0.6, 0.06), Vector3(0, 0.72, 1.05), BEIGE)
			g.box(Vector3(0.96, 0.42, 0.06), Vector3(0, 0.62, -1.05), BEIGE)
			for sx in [-0.47, 0.47]:
				g.box(Vector3(0.03, 0.14, 0.9), Vector3(sx, 0.72, 0.45), CHROME)
				g.box(Vector3(0.03, 0.2, 0.04), Vector3(sx, 0.6, 0.05), CHROME)
				g.box(Vector3(0.03, 0.2, 0.04), Vector3(sx, 0.6, 0.85), CHROME)
			for sx in [-0.38, 0.38]:
				for sz in [-0.88, 0.88]:
					g.cyl(0.03, 0.34, Vector3(sx, 0.2, sz), DARK_STEEL, "y", 6)
			_casters(g, 0.38, 0.88, 0.05)
		"bed_tray":
			g.box(Vector3(0.8, 0.03, 0.45), Vector3(0, 0.985, 0), LAMINATE)
			g.cyl(0.025, 0.95, Vector3(0.36, 0.5, 0), CHROME, "y", 6)
			g.box(Vector3(0.1, 0.03, 0.5), Vector3(0.36, 0.05, 0), DARK_STEEL)
			_casters(g, 0.04, 0.22, 0.03)
		"curtain":
			g.box(Vector3(1.9, 0.03, 0.05), Vector3(0, 2.43, 0), CHROME)
			for i in 6:
				g.box(Vector3(0.33, 2.05, 0.03), Vector3(-0.8 + i * 0.32, 1.38, 0.03 * (i % 2)), PALE_GREEN)
		"iv_stand":
			g.box(Vector3(0.45, 0.03, 0.05), Vector3(0, 0.06, 0), DARK_STEEL)
			g.box(Vector3(0.05, 0.03, 0.45), Vector3(0, 0.06, 0), DARK_STEEL)
			_casters(g, 0.2, 0.0, 0.03)
			g.cyl(0.013, 1.9, Vector3(0, 1.0, 0), CHROME, "y", 6)
			g.box(Vector3(0.32, 0.012, 0.012), Vector3(0, 1.93, 0), CHROME)
			g.box(Vector3(0.12, 0.2, 0.04), Vector3(0.12, 1.76, 0), Color(0.78, 0.78, 0.6, 0.6), 2)
			g.cyl(0.004, 0.9, Vector3(0.12, 1.2, 0.0), Color(0.8, 0.8, 0.8))
		"wall_monitor":
			g.box(Vector3(0.08, 0.08, 0.06), Vector3(0, m + 0.2, -0.03), DARK_STEEL)
			g.box(Vector3(0.55, 0.42, 0.08), Vector3(0, m + 0.21, -0.1), DARK)
			g.box(Vector3(0.47, 0.32, 0.01), Vector3(0, m + 0.22, -0.145), SCREEN * 0.5, 1)
		"counter", "kitchen_counter", "kitchen_counter_coffee":
			_counter_body(g, s.x, s.y, s.z, Color(0.55, 0.58, 0.58), LAMINATE)
		"sink_counter", "kitchen_counter_sink":
			_counter_body(g, s.x, s.y, s.z, Color(0.55, 0.58, 0.58), LAMINATE)
			g.box(Vector3(0.5, 0.02, 0.36), Vector3(0, s.y + 0.001, 0.02), DARK_STEEL)
			g.cyl(0.015, 0.3, Vector3(0, s.y + 0.15, s.z * 0.5 - 0.08), CHROME, "y", 6)
			g.box(Vector3(0.03, 0.03, 0.18), Vector3(0, s.y + 0.28, s.z * 0.5 - 0.16), CHROME)
		"pharmacy_counter":
			g.box(Vector3(1.5, 1.0, 0.58), Vector3(0, 0.5, 0.02), Color(0.70, 0.74, 0.74))
			g.box(Vector3(1.5, 0.12, 0.012), Vector3(0, 0.75, -0.28), TEAL)
			g.box(Vector3(1.52, 0.05, 0.62), Vector3(0, 1.055, 0), LAMINATE)
			g.box(Vector3(1.5, 0.5, 0.02), Vector3(0, 1.33, 0.2), Color(0.7, 0.8, 0.8, 0.25), 2)
			g.box(Vector3(0.03, 0.52, 0.03), Vector3(0.73, 1.33, 0.2), CHROME)
		"med_shelf":
			g.box(Vector3(1.5, 2.0, 0.03), Vector3(0, 1.0, 0.21), OFFWHITE)
			for sx in [-0.74, 0.74]:
				g.box(Vector3(0.03, 2.0, 0.45), Vector3(sx, 1.0, 0), OFFWHITE)
			var cols := [Color(0.8, 0.8, 0.78), Color(0.35, 0.5, 0.7), Color(0.75, 0.45, 0.2), Color(0.85, 0.85, 0.85), Color(0.5, 0.65, 0.4)]
			for row in 5:
				var y := 0.12 + row * 0.42
				g.box(Vector3(1.46, 0.025, 0.42), Vector3(0, y, 0), OFFWHITE)
				var x := -0.66
				var k := row * 3
				while x < 0.62:
					var bw := 0.1 + 0.06 * ((k * 7) % 3)
					var bh := 0.14 + 0.05 * ((k * 5) % 4)
					g.box(Vector3(bw, bh, 0.22), Vector3(x + bw * 0.5, y + 0.0125 + bh * 0.5, 0.02), cols[k % cols.size()])
					x += bw + 0.03 + 0.04 * ((k * 3) % 2)
					k += 1
		"steel_shelves":
			for sx in [-0.28, 0.28]:
				for sz in [-0.23, 0.23]:
					g.box(Vector3(0.03, 2.1, 0.03), Vector3(sx, 1.05, sz), STEEL)
			for y in [0.15, 0.65, 1.15, 1.65, 2.08]:
				g.box(Vector3(0.6, 0.02, 0.5), Vector3(0, y, 0), STEEL)
			g.box(Vector3(0.4, 0.3, 0.35), Vector3(-0.05, 0.31, 0), Color(0.6, 0.48, 0.3))
			g.box(Vector3(0.3, 0.22, 0.3), Vector3(0.1, 1.27, 0), Color(0.8, 0.8, 0.78))
		"storage_cabinet":
			g.box(Vector3(0.84, 1.78, 0.53), Vector3(0, 0.89, 0), Color(0.55, 0.58, 0.6))
			g.box(Vector3(0.01, 1.6, 0.01), Vector3(0, 0.9, -0.27), DARK)
		"box_stack":
			g.box(Vector3(0.5, 0.35, 0.5), Vector3(0, 0.175, 0), Color(0.6, 0.48, 0.3))
			g.box(Vector3(0.4, 0.27, 0.4), Vector3(0.03, 0.485, 0.02), Color(0.55, 0.44, 0.28), 0, Basis(Vector3.UP, 0.3))
		"office_desk":
			g.box(Vector3(1.9, 0.04, 0.9), Vector3(0, 0.73, 0), Color(0.5, 0.52, 0.5))
			g.box(Vector3(0.45, 0.7, 0.85), Vector3(0.7, 0.35, 0), Color(0.45, 0.47, 0.45))
			g.box(Vector3(0.04, 0.7, 0.85), Vector3(-0.92, 0.35, 0), Color(0.45, 0.47, 0.45))
		"office_chair":
			g.box(Vector3(0.48, 0.07, 0.46), Vector3(0, 0.47, 0), DARK)
			g.box(Vector3(0.46, 0.5, 0.06), Vector3(0, 0.78, 0.23), DARK)
			g.cyl(0.03, 0.4, Vector3(0, 0.24, 0), DARK_STEEL, "y", 6)
			g.box(Vector3(0.55, 0.03, 0.06), Vector3(0, 0.05, 0), DARK_STEEL)
			g.box(Vector3(0.06, 0.03, 0.55), Vector3(0, 0.05, 0), DARK_STEEL)
		"filing_cabinet":
			g.box(Vector3(0.91, 1.51, 0.4), Vector3(0, 0.755, 0), Color(0.46, 0.5, 0.48))
			for i in 4:
				g.box(Vector3(0.12, 0.02, 0.02), Vector3(0, 0.25 + i * 0.36, -0.21), CHROME)
		"bookcase":
			g.box(Vector3(0.84, 1.85, 0.53), Vector3(0, 0.925, 0.0), WOOD)
			for i in 4:
				g.box(Vector3(0.7, 0.25, 0.3), Vector3(0, 0.3 + i * 0.44, -0.05), Color(0.5, 0.2 + 0.1 * i, 0.2))
		"visitor_chair", "school_chair":
			g.box(Vector3(0.45, 0.05, 0.45), Vector3(0, 0.45, 0), TEAL)
			g.box(Vector3(0.45, 0.4, 0.05), Vector3(0, 0.7, 0.21), TEAL)
			for sx in [-0.2, 0.2]:
				for sz in [-0.2, 0.2]:
					g.box(Vector3(0.025, 0.45, 0.025), Vector3(sx, 0.225, sz), DARK_STEEL)
		"whiteboard":
			g.box(Vector3(1.4, 0.9, 0.03), Vector3(0, m + 0.45, -0.015), CHROME)
			g.box(Vector3(1.34, 0.84, 0.01), Vector3(0, m + 0.45, -0.033), Color(0.86, 0.87, 0.85))
			g.box(Vector3(0.5, 0.03, 0.01), Vector3(-0.2, m + 0.62, -0.039), Color(0.2, 0.25, 0.5))
			g.box(Vector3(0.7, 0.03, 0.01), Vector3(0.05, m + 0.5, -0.039), Color(0.5, 0.15, 0.15))
			g.box(Vector3(1.2, 0.03, 0.06), Vector3(0, m + 0.02, -0.05), CHROME)
		"notice_board":
			g.box(Vector3(1.2, 0.85, 0.03), Vector3(0, m + 0.425, -0.015), Color(0.55, 0.4, 0.25))
			for i in 5:
				g.box(Vector3(0.2, 0.26, 0.005), Vector3(-0.45 + i * 0.22, m + 0.3 + 0.25 * (i % 2), -0.033), Color(0.85, 0.84, 0.78))
		"directory_board":
			g.box(Vector3(1.4, 1.1, 0.04), Vector3(0, m + 0.55, -0.02), Color(0.1, 0.14, 0.2))
			g.box(Vector3(1.34, 0.16, 0.005), Vector3(0, m + 0.97, -0.043), TEAL, 1)
			for i in 7:
				g.box(Vector3(0.9 - 0.08 * (i % 3), 0.035, 0.005), Vector3(-0.15, m + 0.8 - i * 0.1, -0.043), Color(0.8, 0.82, 0.8))
		"chair_row":
			g.box(Vector3(1.8, 0.06, 0.08), Vector3(0, 0.36, 0.05), DARK_STEEL)
			for sx in [-0.8, 0.8]:
				g.box(Vector3(0.06, 0.36, 0.5), Vector3(sx, 0.18, 0.05), DARK_STEEL)
			for x in [-0.6, 0.0, 0.6]:
				g.box(Vector3(0.52, 0.06, 0.48), Vector3(x, 0.44, 0.0), TEAL)
				g.box(Vector3(0.52, 0.45, 0.05), Vector3(x, 0.7, 0.26), TEAL, 0, Basis(Vector3.RIGHT, 0.12))
		"magazine_table":
			g.box(Vector3(1.19, 0.04, 0.72), Vector3(0, 0.39, 0), WOOD)
			for sx in [-0.55, 0.55]:
				for sz in [-0.32, 0.32]:
					g.box(Vector3(0.04, 0.37, 0.04), Vector3(sx, 0.185, sz), DARK_STEEL)
		"reception_desk":
			g.box(Vector3(3.0, 1.1, 0.08), Vector3(0, 0.55, -0.41), Color(0.45, 0.36, 0.26))
			g.box(Vector3(3.0, 0.12, 0.012), Vector3(0, 0.85, -0.456), TEAL)
			g.box(Vector3(3.04, 0.04, 0.32), Vector3(0, 1.1, -0.33), LAMINATE)
			g.box(Vector3(3.0, 0.04, 0.62), Vector3(0, 0.75, 0.12), LAMINATE)
			for sx in [-1.48, 1.48]:
				g.box(Vector3(0.05, 1.1, 0.9), Vector3(sx, 0.55, 0), Color(0.45, 0.36, 0.26))
		"tv_wall":
			g.box(Vector3(1.3, 0.78, 0.08), Vector3(0, m + 0.43, -0.12), DARK)
			g.box(Vector3(1.2, 0.68, 0.01), Vector3(0, m + 0.43, -0.165), Color(0.03, 0.05, 0.06), 1)
		"plant":
			g.cyl(0.18, 0.35, Vector3(0, 0.175, 0), Color(0.35, 0.25, 0.2))
			g.box(Vector3(0.4, 0.7, 0.4), Vector3(0, 0.75, 0), Color(0.18, 0.3, 0.16), 0, Basis(Vector3.UP, 0.7))
		"vending":
			g.box(Vector3(0.81, 1.97, 0.87), Vector3(0, 0.985, 0), Color(0.5, 0.1, 0.1))
			g.box(Vector3(0.52, 1.3, 0.01), Vector3(-0.1, 1.15, -0.44), Color(0.5, 0.7, 0.7), 1)
		"med_cart":
			g.box(Vector3(0.66, 0.86, 0.46), Vector3(0, 0.53, 0), BLUE_GREY)
			for i in 4:
				g.box(Vector3(0.6, 0.012, 0.01), Vector3(0, 0.3 + i * 0.2, -0.235), DARK)
				g.box(Vector3(0.14, 0.02, 0.02), Vector3(0, 0.38 + i * 0.2, -0.24), CHROME)
			g.box(Vector3(0.7, 0.04, 0.5), Vector3(0, 0.98, 0), LAMINATE)
			g.box(Vector3(0.03, 0.03, 0.4), Vector3(0.36, 0.9, 0), CHROME)
			_casters(g, 0.27, 0.18)
		"computer":
			g.box(Vector3(0.52, 0.34, 0.04), Vector3(0, 0.3, 0), DARK)
			g.box(Vector3(0.46, 0.28, 0.01), Vector3(0, 0.3, -0.022), SCREEN * 0.4, 1)
			g.box(Vector3(0.06, 0.12, 0.06), Vector3(0, 0.08, 0.02), DARK)
		"wheelchair":
			g.box(Vector3(0.48, 0.06, 0.45), Vector3(0, 0.5, 0), DARK)
			g.box(Vector3(0.48, 0.45, 0.04), Vector3(0, 0.78, 0.24), DARK)
			for sx in [-0.33, 0.33]:
				g.cyl(0.3, 0.03, Vector3(sx, 0.3, 0.05), RUBBER, "x", 12)
			g.box(Vector3(0.4, 0.03, 0.1), Vector3(0, 0.12, -0.35), DARK_STEEL)
		"stall":
			var beige := Color(0.62, 0.6, 0.52)
			for sx in [-0.73, 0.73]:
				g.box(Vector3(0.04, 1.75, 1.9), Vector3(sx, 1.05, 0), beige)
			g.box(Vector3(0.62, 1.75, 0.04), Vector3(-0.38, 1.05, -0.93), beige)
			g.box(Vector3(0.62, 1.75, 0.04), Vector3(0.35, 1.05, -1.1), beige, 0, Basis(Vector3.UP, -0.5))
			g.box(Vector3(0.03, 1.9, 0.04), Vector3(-0.7, 1.0, -0.93), CHROME)
			if not assets_node() or not assets_node().has("hosp/toilet"):
				g.box(Vector3(0.4, 0.4, 0.55), Vector3(0, 0.2, 0.5), ENAMEL)
				g.box(Vector3(0.4, 0.4, 0.15), Vector3(0, 0.6, 0.85), ENAMEL)
		"hand_dryer":
			g.box(Vector3(0.28, 0.3, 0.18), Vector3(0, m + 0.15, -0.09), ENAMEL)
			g.box(Vector3(0.12, 0.03, 0.1), Vector3(0, m + 0.01, -0.1), DARK_STEEL)
		"lab_bench", "lab_bench_scope":
			_counter_body(g, 1.5, 0.92, 0.72, Color(0.8, 0.8, 0.76), DARK)
			for sx in [-0.72, 0.72]:
				g.box(Vector3(0.03, 0.6, 0.03), Vector3(sx, 1.22, 0.3), CHROME)
			g.box(Vector3(1.46, 0.03, 0.22), Vector3(0, 1.42, 0.25), CHROME)
			for i in 6:
				var c := Color(0.45, 0.25, 0.1) if i % 2 == 0 else Color(0.75, 0.8, 0.8, 0.5)
				g.cyl(0.035, 0.16, Vector3(-0.6 + i * 0.22, 1.52, 0.25), c, "y", 8, 0 if i % 2 == 0 else 2)
			if kind == "lab_bench_scope" and (assets_node() == null or not assets_node().has("hosp/microscope")):
				g.box(Vector3(0.15, 0.35, 0.25), Vector3(-0.35, 1.1, 0), DARK)
		"lab_island":
			_counter_body(g, 1.5, 0.92, 1.2, Color(0.8, 0.8, 0.76), DARK)
			g.box(Vector3(0.05, 0.5, 0.05), Vector3(0, 1.17, 0), CHROME)
			g.box(Vector3(1.3, 0.03, 0.3), Vector3(0, 1.4, 0), CHROME)
		"fume_hood":
			_counter_body(g, 1.5, 0.9, 0.85, Color(0.78, 0.78, 0.74), DARK)
			for sx in [-0.71, 0.71]:
				g.box(Vector3(0.08, 1.4, 0.85), Vector3(sx, 1.6, 0), Color(0.8, 0.8, 0.76))
			g.box(Vector3(1.5, 0.45, 0.85), Vector3(0, 2.075, 0), Color(0.8, 0.8, 0.76))
			g.box(Vector3(1.36, 1.0, 0.04), Vector3(0, 1.4, 0.4), Color(0.72, 0.72, 0.7))
			g.box(Vector3(1.34, 0.75, 0.015), Vector3(0, 1.45, -0.38), Color(0.6, 0.75, 0.75, 0.3), 2)
			g.box(Vector3(1.2, 0.03, 0.05), Vector3(0, 1.82, 0.2), LAMP * 0.8, 1)
		"ct_scanner":
			g.cyl(1.0, 0.8, Vector3(0, 1.05, 0.95), ENAMEL, "z", 20)
			g.cyl(0.36, 0.82, Vector3(0, 1.05, 0.95), DARK, "z", 16)
			g.box(Vector3(2.1, 0.5, 0.82), Vector3(0, 0.25, 0.95), ENAMEL)
			g.box(Vector3(0.24, 0.12, 0.01), Vector3(0.55, 1.6, 0.54), SCREEN * 0.6, 1)
			g.box(Vector3(0.5, 0.62, 1.4), Vector3(0, 0.31, -0.7), ENAMEL)
			g.box(Vector3(0.44, 0.08, 2.5), Vector3(0, 0.66, -0.35), Color(0.2, 0.25, 0.3))
			g.box(Vector3(0.38, 0.05, 2.3), Vector3(0, 0.72, -0.4), SHEET)
		"console_desk":
			g.box(Vector3(1.8, 0.04, 0.8), Vector3(0, 0.74, 0), LAMINATE)
			g.box(Vector3(1.76, 0.7, 0.05), Vector3(0, 0.35, 0.37), DARK_STEEL)
			for sx in [-0.88, 0.88]:
				g.box(Vector3(0.04, 0.72, 0.78), Vector3(sx, 0.36, 0), DARK_STEEL)
			if assets_node() == null or not assets_node().has("prop/screen"):
				for sx in [-0.35, 0.35]:
					g.box(Vector3(0.5, 0.32, 0.04), Vector3(sx, 1.0, 0.15), DARK)
					g.box(Vector3(0.44, 0.26, 0.01), Vector3(sx, 1.0, 0.125), SCREEN * 0.5, 1)
		"lead_partition":
			g.box(Vector3(1.5, 1.9, 0.12), Vector3(0, 1.05, 0), Color(0.6, 0.62, 0.6))
			g.box(Vector3(0.6, 0.4, 0.13), Vector3(0, 1.5, 0), Color(0.3, 0.4, 0.42, 0.45), 2)
			for sx in [-0.6, 0.6]:
				g.box(Vector3(0.1, 0.1, 0.5), Vector3(sx, 0.05, 0), DARK_STEEL)
		"lightbox":
			g.box(Vector3(1.2, 0.6, 0.07), Vector3(0, m + 0.3, -0.035), Color(0.3, 0.32, 0.34))
			g.box(Vector3(1.1, 0.5, 0.01), Vector3(0, m + 0.3, -0.072), Color(0.75, 0.8, 0.85), 1)
			for i in 3:
				g.box(Vector3(0.3, 0.4, 0.005), Vector3(-0.36 + i * 0.36, m + 0.3, -0.079), Color(0.08, 0.1, 0.12))
		"radiation_sign":
			g.box(Vector3(0.4, 0.4, 0.015), Vector3(0, m + 0.2, -0.008), YELLOW)
			g.cyl(0.05, 0.01, Vector3(0, m + 0.2, -0.02), DARK, "z", 10)
			for a in [0.0, 2.094, 4.189]:
				g.box(Vector3(0.1, 0.1, 0.01), Vector3(cos(a - PI * 0.5) * 0.11, m + 0.2 + sin(a + PI * 0.5) * 0.11, -0.02), DARK, 0, Basis(Vector3.BACK, a))
		"morgue_fridge", "morgue_fridge_open":
			g.box(Vector3(1.5, 2.1, 0.86), Vector3(0, 1.05, 0.02), STEEL)
			for row in 3:
				for col in 2:
					var cx := -0.37 + col * 0.74
					var cy := 0.38 + row * 0.66
					if kind == "morgue_fridge_open" and row == 1 and col == 0:
						g.box(Vector3(0.66, 0.58, 0.01), Vector3(cx, cy, -0.415), RUBBER)
						g.box(Vector3(0.66, 0.58, 0.03), Vector3(cx - 0.33, cy, -0.75), CHROME, 0, Basis(Vector3.UP, 1.45))
						g.box(Vector3(0.56, 0.04, 0.5), Vector3(cx, cy - 0.22, -0.6), STEEL)
					else:
						g.box(Vector3(0.68, 0.6, 0.02), Vector3(cx, cy, -0.42), CHROME)
						g.box(Vector3(0.04, 0.16, 0.04), Vector3(cx + 0.26, cy, -0.44), DARK_STEEL)
		"autopsy_table":
			g.box(Vector3(0.85, 0.05, 2.1), Vector3(0, 0.87, 0), CHROME)
			for sx in [-0.41, 0.41]:
				g.box(Vector3(0.03, 0.06, 2.1), Vector3(sx, 0.92, 0), CHROME)
			for sz in [-1.04, 1.04]:
				g.box(Vector3(0.85, 0.06, 0.03), Vector3(0, 0.92, sz), CHROME)
			g.cyl(0.16, 0.82, Vector3(0, 0.43, 0.1), STEEL, "y", 10)
			g.box(Vector3(0.6, 0.04, 0.9), Vector3(0, 0.02, 0.1), DARK_STEEL)
			g.cyl(0.04, 0.012, Vector3(0, 0.9, -0.9), DARK, "y", 8)
		"covered_body":
			var sheet := Color(0.78, 0.8, 0.8)
			g.box(Vector3(0.5, 0.2, 0.95), Vector3(0, 0.1, 0.08), sheet)
			g.cyl(0.12, 0.2, Vector3(0, 0.12, 0.78), sheet, "y", 10)
			g.box(Vector3(0.36, 0.12, 0.6), Vector3(0, 0.07, -0.6), sheet)
			for sx in [-0.09, 0.09]:
				g.box(Vector3(0.1, 0.15, 0.1), Vector3(sx, 0.1, -0.9), sheet)
		"gurney", "gurney_body":
			g.box(Vector3(0.66, 0.05, 1.9), Vector3(0, 0.62, 0), STEEL)
			g.box(Vector3(0.62, 0.08, 1.35), Vector3(0, 0.69, -0.28), Color(0.3, 0.42, 0.5))
			g.box(Vector3(0.62, 0.08, 0.6), Vector3(0, 0.82, 0.68), Color(0.3, 0.42, 0.5), 0, Basis(Vector3.RIGHT, -0.5))
			for sx in [-0.34, 0.34]:
				g.box(Vector3(0.025, 0.1, 1.2), Vector3(sx, 0.72, -0.1), CHROME)
			g.box(Vector3(0.5, 0.04, 1.4), Vector3(0, 0.16, 0), DARK_STEEL)
			g.box(Vector3(0.04, 0.5, 0.04), Vector3(0, 0.38, -0.55), DARK_STEEL, 0, Basis(Vector3.RIGHT, 0.6))
			g.box(Vector3(0.04, 0.5, 0.04), Vector3(0, 0.38, 0.55), DARK_STEEL, 0, Basis(Vector3.RIGHT, -0.6))
			_casters(g, 0.24, 0.68)
			if kind == "gurney_body":
				var sheet := Color(0.76, 0.78, 0.78)
				g.box(Vector3(0.46, 0.18, 0.95), Vector3(0, 0.82, -0.05), sheet)
				g.cyl(0.11, 0.18, Vector3(0, 0.84, 0.62), sheet, "y", 10)
				g.box(Vector3(0.34, 0.12, 0.6), Vector3(0, 0.79, -0.7), sheet)
		"gurney_bag":
			_gurney_frame(g, Transform3D.IDENTITY)
			_body_bag(g, Vector3(0, 0.73, -0.02))
		"body_bag":
			_body_bag(g, Vector3.ZERO)
		"gurney_toppled":
			# Knocked over onto its side: the frame turned 90 degrees about its long axis, the wheels in
			# the air toward +X, the mattress slid half off onto the floor.
			_gurney_frame(g, Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0.35, 0.36, 0)), true)
			g.box(Vector3(0.62, 0.08, 1.3), Vector3(-0.7, 0.05, 0.25), BLUE_GREY, 0, Basis(Vector3.UP, 0.18))
		"blood_trail":
			# A drag mark: blotches thinning out toward -Z, zig-zagging a little, wet on top.
			for i in 9:
				var k := float(i) / 8.0
				var w := lerpf(0.5, 0.12, k)
				var len := lerpf(0.5, 0.26, k)
				var x := sin(float(i) * 1.7) * 0.08
				g.box(Vector3(w, 0.008, len), Vector3(x, 0.006, 1.3 - k * 2.6), BLOOD, 2, Basis(Vector3.UP, sin(float(i) * 2.3) * 0.25))
			g.box(Vector3(0.12, 0.008, 0.14), Vector3(0.28, 0.006, 0.6), BLOOD, 2)
			g.box(Vector3(0.08, 0.008, 0.09), Vector3(-0.25, 0.006, -0.3), BLOOD, 2)
		"blood_pool":
			g.box(Vector3(0.9, 0.008, 0.62), Vector3(0, 0.006, 0), BLOOD, 2, Basis(Vector3.UP, 0.3))
			g.box(Vector3(0.5, 0.008, 0.5), Vector3(0.28, 0.007, 0.22), BLOOD, 2, Basis(Vector3.UP, -0.5))
			g.box(Vector3(0.36, 0.008, 0.3), Vector3(-0.34, 0.007, -0.24), BLOOD, 2, Basis(Vector3.UP, 0.9))
			for d in [Vector3(0.55, 0, -0.35), Vector3(-0.5, 0, 0.3), Vector3(0.1, 0, 0.45)]:
				g.box(Vector3(0.07, 0.008, 0.07), d + Vector3(0, 0.006, 0), BLOOD, 2)
		"instrument_cart":
			g.box(Vector3(1.2, 0.03, 0.7), Vector3(0, 0.94, 0), CHROME)
			g.box(Vector3(1.2, 0.03, 0.7), Vector3(0, 0.3, 0), CHROME)
			for sx in [-0.58, 0.58]:
				for sz in [-0.33, 0.33]:
					g.box(Vector3(0.025, 0.9, 0.025), Vector3(sx, 0.5, sz), CHROME)
			_casters(g, 0.55, 0.3)
		"mop_sink":
			g.box(Vector3(0.9, 0.5, 0.7), Vector3(0, 0.25, 0), Color(0.6, 0.6, 0.58))
			g.box(Vector3(0.74, 0.02, 0.54), Vector3(0, 0.505, 0), DARK)
			g.cyl(0.02, 0.35, Vector3(0, 0.85, 0.32), CHROME, "y", 6)
			g.box(Vector3(0.03, 0.03, 0.2), Vector3(0, 1.0, 0.24), CHROME)
		"mop_bucket":
			if assets_node() == null or not assets_node().has("hosp/bucket"):
				g.box(Vector3(0.42, 0.35, 0.42), Vector3(0, 0.175, 0), YELLOW)
			g.box(Vector3(0.3, 0.12, 0.2), Vector3(0, 0.52, 0.06), DARK_STEEL)
			g.cyl(0.014, 1.3, Vector3(0.05, 0.75, -0.05), WOOD, "y", 6)
			g.box(Vector3(0.28, 0.12, 0.2), Vector3(0.05, 0.12, -0.05), Color(0.72, 0.7, 0.6))
		"wet_floor":
			g.box(Vector3(0.3, 0.62, 0.02), Vector3(0, 0.3, -0.15), YELLOW, 0, Basis(Vector3.RIGHT, 0.25))
			g.box(Vector3(0.3, 0.62, 0.02), Vector3(0, 0.3, 0.15), YELLOW, 0, Basis(Vector3.RIGHT, -0.25))
		"broom":
			g.cyl(0.013, 1.25, Vector3(0, 0.75, 0), WOOD, "y", 6)
			g.box(Vector3(0.28, 0.12, 0.06), Vector3(0, 0.07, 0), Color(0.45, 0.4, 0.3))
		"washer":
			g.box(Vector3(0.78, 0.94, 0.78), Vector3(0, 0.47, 0), ENAMEL)
			g.cyl(0.22, 0.02, Vector3(0, 0.5, -0.39), DARK, "z", 14)
		"cafeteria_table", "break_table":
			g.box(Vector3(1.94, 0.04, 1.03), Vector3(0, 0.73, 0), LAMINATE)
			for sx in [-0.85, 0.85]:
				g.cyl(0.03, 0.72, Vector3(sx, 0.36, 0), DARK_STEEL, "y", 6)
				g.box(Vector3(0.05, 0.03, 0.8), Vector3(sx, 0.015, 0), DARK_STEEL)
		"tray":
			g.box(Vector3(0.45, 0.03, 0.33), Vector3(0, 0.015, 0), Color(0.55, 0.35, 0.2))
		"serving_counter":
			g.box(Vector3(1.5, 0.9, 0.78), Vector3(0, 0.45, 0.01), STEEL)
			g.box(Vector3(1.52, 0.04, 0.8), Vector3(0, 0.92, 0), CHROME)
			for sx in [-0.38, 0.38]:
				g.box(Vector3(0.6, 0.02, 0.45), Vector3(sx, 0.93, 0.08), DARK)
			g.box(Vector3(1.5, 0.02, 0.4), Vector3(0, 1.32, -0.12), Color(0.7, 0.8, 0.8, 0.3), 2, Basis(Vector3.RIGHT, 0.4))
			for sx in [-0.74, 0.74]:
				g.box(Vector3(0.025, 0.42, 0.025), Vector3(sx, 1.13, 0.05), CHROME)
			g.box(Vector3(1.4, 0.03, 0.05), Vector3(0, 1.28, 0.05), LAMP * 0.7, 1)
		"tray_stack":
			for i in 6:
				g.box(Vector3(0.45, 0.03, 0.33), Vector3(0.01 * (i % 2), 0.02 + i * 0.045, 0), Color(0.55, 0.35, 0.2))
		"register":
			g.box(Vector3(0.5, 0.25, 0.4), Vector3(0, 1.08, 0), DARK)
			_counter_body(g, 1.36, 0.95, 1.2, STEEL, LAMINATE)
		"lockers":
			g.box(Vector3(1.5, 0.1, 0.46), Vector3(0, 0.05, 0.02), DARK)
			for i in 3:
				var x := -0.5 + i * 0.5
				g.box(Vector3(0.48, 1.8, 0.48), Vector3(x, 1.0, 0), Color(0.38, 0.46, 0.5))
				g.box(Vector3(0.44, 1.7, 0.01), Vector3(x, 1.0, -0.245), Color(0.42, 0.5, 0.54))
				for v in 3:
					g.box(Vector3(0.25, 0.015, 0.005), Vector3(x, 1.65 + v * 0.05, -0.252), DARK)
				g.box(Vector3(0.03, 0.12, 0.03), Vector3(x + 0.16, 1.1, -0.26), CHROME)
		"bench":
			for i in 3:
				g.box(Vector3(1.8, 0.03, 0.12), Vector3(0, 0.44, -0.13 + i * 0.13), WOOD)
			for sx in [-0.75, 0.75]:
				g.box(Vector3(0.05, 0.42, 0.36), Vector3(sx, 0.21, 0), DARK_STEEL)
		"fridge_kitchen":
			g.box(Vector3(1.0, 1.84, 0.78), Vector3(0, 0.92, 0), ENAMEL)
			g.box(Vector3(0.02, 1.6, 0.02), Vector3(0, 1.0, -0.4), DARK_STEEL)
		"sofa":
			g.box(Vector3(1.96, 0.42, 0.82), Vector3(0, 0.21, 0), Color(0.3, 0.33, 0.4))
			g.box(Vector3(1.96, 0.5, 0.2), Vector3(0, 0.67, 0.31), Color(0.3, 0.33, 0.4))
		"armchair":
			g.box(Vector3(0.98, 0.42, 0.82), Vector3(0, 0.21, 0), Color(0.3, 0.33, 0.4))
			g.box(Vector3(0.98, 0.5, 0.2), Vector3(0, 0.67, 0.31), Color(0.3, 0.33, 0.4))
		"wall_phone":
			g.box(Vector3(0.22, 0.34, 0.08), Vector3(0, m + 0.17, -0.04), BEIGE)
			g.box(Vector3(0.07, 0.3, 0.07), Vector3(-0.07, m + 0.18, -0.11), BEIGE)
		"wall_clock":
			g.cyl(0.16, 0.05, Vector3(0, m + 0.16, -0.025), DARK, "z", 16)
			g.cyl(0.14, 0.01, Vector3(0, m + 0.16, -0.052), ENAMEL, "z", 16)
		"extinguisher":
			g.cyl(0.08, 0.5, Vector3(0, m + 0.3, -0.1), RED, "y", 10)
			g.box(Vector3(0.2, 0.05, 0.08), Vector3(0, m + 0.2, -0.04), DARK_STEEL)
		"security_camera":
			g.box(Vector3(0.06, 0.2, 0.06), Vector3(0, m + 0.1, -0.03), DARK)
			g.box(Vector3(0.12, 0.1, 0.3), Vector3(0, m + 0.05, -0.2), ENAMEL, 0, Basis(Vector3.RIGHT, 0.35))
			g.box(Vector3(0.015, 0.015, 0.01), Vector3(0.03, m + 0.08, -0.05), Color(1.0, 0.1, 0.05), 1)
		"time_clock":
			g.box(Vector3(0.5, 1.0, 0.34), Vector3(0, 0.5, 0.02), DARK_STEEL)
			g.box(Vector3(0.46, 0.36, 0.3), Vector3(0, 1.18, 0.02), BEIGE)
			g.box(Vector3(0.28, 0.1, 0.01), Vector3(0, 1.26, -0.135), Color(0.2, 0.9, 0.45), 1)
			g.box(Vector3(0.22, 0.03, 0.04), Vector3(0, 1.07, -0.14), DARK)
			for sx in [-0.34, 0.34]:
				g.box(Vector3(0.14, 0.7, 0.06), Vector3(sx, 1.0, 0.14), DARK_STEEL)
				for i in 5:
					g.box(Vector3(0.1, 0.09, 0.01), Vector3(sx, 0.75 + i * 0.13, 0.105), Color(0.85, 0.83, 0.72))
		"doormat":
			g.box(Vector3(1.5, 0.02, 0.83), Vector3(0, 0.01, 0), Color(0.15, 0.15, 0.14))
		"or_table":
			g.box(Vector3(0.7, 0.06, 0.5), Vector3(0, 0.03, 0), DARK_STEEL)
			g.box(Vector3(0.3, 0.72, 0.26), Vector3(0, 0.42, 0), CHROME)
			g.box(Vector3(2.1, 0.08, 0.62), Vector3(0, 0.82, 0), STEEL)
			g.box(Vector3(2.16, 0.09, 0.56), Vector3(0, 0.9, 0), Color(0.08, 0.09, 0.1))
			g.box(Vector3(0.34, 0.07, 0.22), Vector3(0.98, 0.97, 0), Color(0.08, 0.09, 0.1))
			for sz in [-0.33, 0.33]:
				g.box(Vector3(2.0, 0.03, 0.02), Vector3(0, 0.84, sz), CHROME)
		"surgical_lamp":
			g.cyl(0.03, 0.5, Vector3(0, 2.75, 0), DARK_STEEL, "y", 6)
			g.box(Vector3(0.7, 0.04, 0.05), Vector3(0.3, 2.5, 0), DARK_STEEL)
			g.cyl(0.03, 0.2, Vector3(0.62, 2.4, 0), DARK_STEEL, "y", 6)
			g.cyl(0.34, 0.12, Vector3(0.62, 2.26, 0), ENAMEL, "y", 16)
			g.cyl(0.26, 0.01, Vector3(0.62, 2.195, 0), LAMP * 0.6, "y", 16, 1)
		"anesthesia_cart":
			g.box(Vector3(0.66, 0.9, 0.56), Vector3(0, 0.5, 0), Color(0.7, 0.72, 0.7))
			for i in 3:
				g.box(Vector3(0.58, 0.2, 0.01), Vector3(0, 0.25 + i * 0.26, -0.285), [TEAL, BLUE_GREY, Color(0.6, 0.55, 0.3)][i])
			g.box(Vector3(0.7, 0.04, 0.6), Vector3(0, 0.97, 0), LAMINATE)
			g.box(Vector3(0.04, 0.5, 0.04), Vector3(0, 1.22, 0.2), DARK_STEEL)
			g.box(Vector3(0.48, 0.34, 0.06), Vector3(0, 1.4, 0.18), DARK)
			g.box(Vector3(0.42, 0.28, 0.01), Vector3(0, 1.4, 0.145), SCREEN * 0.6, 1)
			g.cyl(0.07, 0.8, Vector3(0.38, 0.45, 0.18), Color(0.25, 0.5, 0.3), "y", 10)
			g.cyl(0.07, 0.8, Vector3(0.38, 0.45, -0.02), ENAMEL, "y", 10)
			_casters(g, 0.27, 0.22)
		"crash_cart":
			g.box(Vector3(0.76, 0.92, 0.56), Vector3(0, 0.52, 0), RED)
			for i in 4:
				g.box(Vector3(0.7, 0.012, 0.01), Vector3(0, 0.28 + i * 0.2, -0.285), Color(0.2, 0.03, 0.02))
			g.box(Vector3(0.8, 0.04, 0.6), Vector3(0, 1.0, 0), DARK)
			g.box(Vector3(0.34, 0.14, 0.26), Vector3(-0.15, 1.09, 0.05), Color(0.85, 0.66, 0.08))
			g.box(Vector3(0.12, 0.06, 0.01), Vector3(-0.15, 1.1, -0.085), SCREEN * 0.8, 1)
			_casters(g, 0.3, 0.22)
		"scrub_sink":
			g.box(Vector3(0.82, 0.86, 0.8), Vector3(0, 0.43, 0.03), CHROME)
			g.box(Vector3(0.7, 0.04, 0.6), Vector3(0, 0.88, 0), DARK_STEEL)
			g.cyl(0.02, 0.4, Vector3(0, 1.1, 0.35), CHROME, "y", 6)
		"glass_cabinet":
			g.box(Vector3(1.2, 1.9, 0.04), Vector3(0, 0.95, 0.2), ENAMEL)
			for sx in [-0.58, 0.58]:
				g.box(Vector3(0.04, 1.9, 0.45), Vector3(sx, 0.95, 0), ENAMEL)
			g.box(Vector3(1.2, 0.3, 0.45), Vector3(0, 0.15, 0), ENAMEL)
			g.box(Vector3(1.2, 0.04, 0.45), Vector3(0, 1.88, 0), ENAMEL)
			for i in 4:
				var y := 0.35 + i * 0.4
				g.box(Vector3(1.12, 0.015, 0.4), Vector3(0, y, 0), Color(0.7, 0.8, 0.8, 0.4), 2)
				for j in 5:
					g.cyl(0.04, 0.14 + 0.04 * ((i + j) % 3), Vector3(-0.42 + j * 0.21, y + 0.08, 0.02), [ENAMEL, Color(0.45, 0.3, 0.15), Color(0.3, 0.45, 0.6)][(i * 2 + j) % 3], "y", 8)
			g.box(Vector3(1.12, 1.52, 0.015), Vector3(0, 1.08, -0.21), Color(0.65, 0.78, 0.8, 0.2), 2)
		"or_screen_mount":
			g.box(Vector3(2.2, 1.3, 0.06), Vector3(0, m + 0.65, -0.05), DARK)
			g.box(Vector3(2.08, 1.18, 0.01), Vector3(0, m + 0.65, -0.082), Color(0.02, 0.05, 0.06), 1)
		"table_monitor_mount":
			g.box(Vector3(1.2, 0.72, 0.06), Vector3(0, m + 0.36, -0.05), DARK)
			g.box(Vector3(1.08, 0.6, 0.01), Vector3(0, m + 0.36, -0.082), Color(0.02, 0.05, 0.06), 1)
			g.box(Vector3(0.12, 0.3, 0.05), Vector3(0, m - 0.12, -0.03), DARK)   # the wall arm
		# ---- outdoors ------------------------------------------------------
		"ambulance", "van", "sedan", "suv", "hatchback", "covered_car":
			var col := ENAMEL
			match kind:
				"van": col = Color(0.25, 0.3, 0.38)
				"sedan": col = Color(0.35, 0.1, 0.1)
				"suv": col = Color(0.15, 0.17, 0.2)
				"hatchback": col = Color(0.5, 0.5, 0.52)
				"covered_car": col = Color(0.35, 0.36, 0.34)
			g.box(Vector3(s.x - 0.1, s.y * 0.45, s.z), Vector3(0, 0.35 + s.y * 0.225, 0), col)
			g.box(Vector3(s.x - 0.2, s.y * 0.4, s.z * 0.55), Vector3(0, 0.35 + s.y * 0.45 + s.y * 0.2, s.z * 0.1), col.darkened(0.2))
			for sx in [-s.x * 0.45, s.x * 0.45]:
				for sz in [-s.z * 0.32, s.z * 0.32]:
					g.cyl(0.35, 0.25, Vector3(sx, 0.35, sz), RUBBER, "x", 12)
			if kind == "ambulance":
				g.box(Vector3(s.x - 0.08, 0.2, s.z + 0.01), Vector3(0, 0.9, 0), RED)
				g.box(Vector3(0.9, 0.12, 0.2), Vector3(0, s.y + 0.05, -s.z * 0.2), Color(0.9, 0.2, 0.15), 1)
		"street_light":
			g.cyl(0.08, 5.4, Vector3(0, 2.7, 0), DARK_STEEL, "y", 8)
			g.box(Vector3(0.08, 0.08, 1.3), Vector3(0, 5.35, -0.65), DARK_STEEL)
			g.box(Vector3(0.35, 0.12, 0.6), Vector3(0, 5.3, -1.25), DARK_STEEL)
			g.box(Vector3(0.3, 0.02, 0.5), Vector3(0, 5.23, -1.25), LAMP, 1)
		"dumpster":
			g.box(Vector3(1.79, 1.2, 2.3), Vector3(0, 0.7, 0), Color(0.18, 0.32, 0.2))
			g.box(Vector3(1.85, 0.08, 2.4), Vector3(0, 1.32, 0), Color(0.12, 0.22, 0.14))
			_casters(g, 0.8, 1.0, 0.1)
		"canopy_post":
			g.box(Vector3(0.22, 3.2, 0.22), Vector3(0, 1.6, 0), Color(0.55, 0.57, 0.58))
			g.box(Vector3(0.3, 0.2, 0.3), Vector3(0, 0.1, 0), Color(0.4, 0.42, 0.43))
		"bollard":
			g.cyl(0.11, 1.0, Vector3(0, 0.5, 0), YELLOW, "y", 10)
			g.cyl(0.115, 0.08, Vector3(0, 0.8, 0), Color(0.9, 0.9, 0.85), "y", 10)
		"cone":
			g.box(Vector3(0.45, 0.04, 0.45), Vector3(0, 0.02, 0), Color(0.9, 0.35, 0.05))
			g.cyl(0.12, 0.65, Vector3(0, 0.36, 0), Color(0.9, 0.35, 0.05), "y", 10)
		"barrier":
			g.box(Vector3(1.46, 0.25, 0.08), Vector3(0, 0.65, 0), Color(0.9, 0.9, 0.85))
			for sx in [-0.65, 0.65]:
				g.box(Vector3(0.06, 0.84, 0.4), Vector3(sx, 0.42, 0), DARK_STEEL)
		"shop_table":
			g.box(Vector3(1.8, 0.04, 0.75), Vector3(0, 0.78, 0), Color(0.75, 0.75, 0.72))
			g.box(Vector3(1.82, 0.4, 0.01), Vector3(0, 0.58, -0.38), Color(0.12, 0.3, 0.45))
			for sx in [-0.82, 0.82]:
				g.box(Vector3(0.03, 0.76, 0.6), Vector3(sx, 0.38, 0), DARK_STEEL)
		"shop_crates":
			if assets_node() == null or not assets_node().has("hosp/box_closed"):
				g.box(Vector3(0.5, 0.5, 0.5), Vector3(-0.2, 0.25, 0), Color(0.55, 0.42, 0.25))
				g.box(Vector3(0.45, 0.45, 0.45), Vector3(0.22, 0.225, 0.05), Color(0.5, 0.38, 0.22))
		"pallet":
			for i in 5:
				g.box(Vector3(1.2, 0.025, 0.14), Vector3(0, 0.125, -0.42 + i * 0.21), WOOD)
			for sz in [-0.42, 0.0, 0.42]:
				g.box(Vector3(1.2, 0.1, 0.1), Vector3(0, 0.05, sz), WOOD.darkened(0.2))
		"outdoor_bench":
			for i in 3:
				g.box(Vector3(1.8, 0.04, 0.12), Vector3(0, 0.45, -0.15 + i * 0.14), WOOD)
				g.box(Vector3(1.8, 0.1, 0.03), Vector3(0, 0.62 + i * 0.12, 0.25), WOOD)
			for sx in [-0.8, 0.8]:
				g.box(Vector3(0.06, 0.45, 0.5), Vector3(sx, 0.225, 0.02), DARK_STEEL)
		_:
			if s == Vector3.ONE and not Defs.exists(kind):
				return null
			g.box(Vector3(s.x, s.y, s.z), Vector3(0, m + s.y * 0.5, -s.z * 0.5 if Defs.mounted(kind) else 0.0), OFFWHITE)
	return g.commit()
