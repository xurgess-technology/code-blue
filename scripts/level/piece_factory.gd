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
const Mirrors := preload("res://scripts/personnel/mirrors.gd")

## Kind -> Assets key. Models are centred on their footprint with their base on the floor.
const ASSET := {
	"curtain": "prop/curtain", "bedside": "hosp/bedside", "visitor_chair": "hosp/chair_cushion",
	"wall_sink": "hosp/sink_wall", "bin": "prop/bin", "steel_shelves": "hosp/steel_shelves",
	"storage_cabinet": "hosp/cabinet_tall", "box_stack": "hosp/box_closed",
	"office_desk": "hosp/office_desk", "office_chair": "prop/chair", "filing_cabinet": "hosp/filing_cabinet",
	"bookcase": "hosp/bookcase", "school_chair": "hosp/school_chair", "magazine_table": "hosp/coffee_table",
	"tv_wall": "hosp/tv", "plant": "hosp/plant", "vending": "hosp/vending",
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
	"reception_desk": [["hosp/plant_small", Vector3(1.2, 1.12, -0.33), 0.0]],
	"shop_table": [["hosp/box_open", Vector3(-0.45, 0.8, 0.0), 10.0], ["hosp/medical_box", Vector3(0.45, 0.8, 0.0), -8.0]],
	"shop_crates": [["hosp/box_closed", Vector3(-0.2, 0.0, 0.0), 0.0], ["hosp/box_closed", Vector3(0.22, 0.0, 0.05), 14.0], ["hosp/box_closed", Vector3(0.0, 0.62, 0.0), -9.0]],
	"mop_bucket": [["hosp/bucket", Vector3(0.0, 0.0, 0.0), 0.0]],
	"magazine_table": [["hosp/books", Vector3(0.25, 0.41, 0.05), 20.0]],
	"office_desk": [["hosp/plant_small", Vector3(-0.75, 0.75, 0.25), 0.0]],
}

## Primitive kinds drawn on top of a kind, model or not: [kind, position in the piece frame, yaw
## degrees]. Every desk carries the standard computer ("computer": the pharmacy terminal's, which
## is the only one that works; fax_terminal.gd builds on the office desk too).
const PRIM_EXTRA := {
	"office_desk": [["computer", Vector3(0.35, 0.75, 0.1), 0.0]],
	"reception_desk": [["computer", Vector3(-0.7, 0.77, 0.16), 180.0]],
	"console_desk": [["computer", Vector3(-0.42, 0.76, 0.1), 0.0], ["computer", Vector3(0.42, 0.76, 0.1), 0.0]],
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
	for e in PRIM_EXTRA.get(kind, []):
		var pm := _primitive(String(e[0]))
		if pm != null:
			out.append({"mesh": pm, "xform": Transform3D(Basis(Vector3.UP, deg_to_rad(float(e[2]))), e[1])})
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

	## A low-poly ellipsoid of `size` centred at `pos`, turned by `basis`, its bottom squashed flat by
	## `sag` (0..1) like something heavy and soft sitting on the floor: garbage bags, heaps.
	func blob(size: Vector3, pos: Vector3, col: Color, basis := Basis.IDENTITY, sag := 0.35, seg := 8, rings := 5) -> void:
		var h := size * 0.5
		var pt := func(i: int, j: int) -> Vector3:
			var th := PI * float(j) / rings            # 0 top .. PI bottom
			var ph := TAU * float(i) / seg
			var y := cos(th)
			if y < 0.0:
				y *= 1.0 - sag
			return pos + basis * Vector3(sin(th) * cos(ph) * h.x, y * h.y, sin(th) * sin(ph) * h.z)
		for j in rings:
			for i in seg:
				var a: Vector3 = pt.call(i, j)
				var b: Vector3 = pt.call(i + 1, j)
				var c: Vector3 = pt.call(i + 1, j + 1)
				var d: Vector3 = pt.call(i, j + 1)
				if j == 0:
					_tri(0, a, c, d, col)
				elif j == rings - 1:
					_tri(0, a, b, d, col)
				else:
					quad(0, a, b, c, d, col)

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


## Grout lines over a `w` x `h` tiled face whose surface is at `at` (z), 0.3 m tiles, standing
## 2 mm proud of it on the `side` (+1 or -1) it faces.
static func _tile_lines(g: Geo, at: Vector3, w: float, h: float, side: float) -> void:
	var grout := Color(0.64, 0.66, 0.67)
	var z := at.z + side * 0.002
	for k in range(1, int(w / 0.3) + 1):
		var x := -w * 0.5 + k * 0.3
		if x < w * 0.5:
			g.box(Vector3(0.022, h, 0.004), Vector3(at.x + x, h * 0.5, z), grout)
	for k in range(1, int(h / 0.3) + 1):
		g.box(Vector3(w, 0.022, 0.004), Vector3(at.x, k * 0.3, z), grout)


## A black garbage bag of about `size` metres: a sagging lump with a knot on top.
static func _bag(g: Geo, pos: Vector3, size: float, col: Color, turn: float) -> void:
	var b := Basis(Vector3.UP, turn) * Basis(Vector3.BACK, 0.12 * sin(turn * 3.0))
	g.blob(Vector3(size, size * 0.8, size * 0.85), pos, col, b, 0.45)
	g.blob(Vector3(size * 0.16, size * 0.22, size * 0.16), pos + Vector3(0, size * 0.42, 0), col.lightened(0.05), b, 0.1, 6, 3)


## A mound of junk and bodies against a wall (back +Z), `s` wide/high/deep: highest at the wall,
## sloping down to about knee height at the front, ragged along the top. A dark core fills it so
## nothing shows through, and the surface is covered in what the hospital throws away: garbage and
## biohazard bags, body bags, sheeted corpses with a foot and a toe tag out, an arm, skulls and
## bones, boxes, bins, bedpans, drip stands, broken chairs, mattresses, bloody rags. Laid out from
## `seed`, so each mound is its own.
static func _junk_mound(g: Geo, s: Vector3, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var hx := s.x * 0.5
	var hz := s.z * 0.5
	var ph := [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
	# Surface height at (x, z): the slope, a wobble along the top, and lower toward the open ends.
	var height := func(x: float, z: float) -> float:
		var t := clampf((z + hz) / s.z, 0.0, 1.0)
		var wob := 0.12 * sin(x * 1.7 + ph[0]) + 0.08 * sin(x * 3.9 + ph[1]) + 0.06 * sin((x + z) * 5.3 + ph[2])
		var end_k := clampf((hx - absf(x)) / 0.9, 0.35, 1.0)
		return maxf(0.12, s.y * (0.18 + 0.82 * pow(t, 0.75)) * (1.0 + wob) * end_k)
	var slope_basis := func(x: float, z: float) -> Basis:
		var dz: float = (float(height.call(x, z + 0.2)) - float(height.call(x, z - 0.2))) / 0.4
		var dx: float = (float(height.call(x + 0.2, z)) - float(height.call(x - 0.2, z))) / 0.4
		return Basis(Vector3.RIGHT, atan(dz)) * Basis(Vector3.BACK, -atan(dx))
	# The core: dark rubbish in overlapping lumps following the slope.
	var core := Color(0.07, 0.06, 0.05)
	var step := 0.7
	var nx := int(s.x / step) + 1
	var nz := int(s.z / step) + 1
	for iz in nz:
		for ix in nx:
			var x := -hx + 0.2 + (s.x - 0.4) * float(ix) / maxf(1.0, nx - 1)
			var z := -hz + 0.2 + (s.z - 0.4) * float(iz) / maxf(1.0, nz - 1)
			var h: float = height.call(x, z)
			g.blob(Vector3(step * 1.7, h * 2.0, step * 1.7), Vector3(x, 0.0, z), core.lightened(rng.randf() * 0.08), Basis.IDENTITY, 0.95, 7, 4)
	# The surface, densest along the front and top where you see it.
	var count := int(s.x * s.z * 5.5)
	var bag_cols := [Color(0.05, 0.05, 0.055), Color(0.06, 0.08, 0.055), Color(0.04, 0.04, 0.045), Color(0.55, 0.08, 0.06), Color(0.09, 0.08, 0.07)]
	var skin := Color(0.6, 0.58, 0.5)
	var blood := Color(0.22, 0.01, 0.01)
	for k in count:
		var x := rng.randf_range(-hx + 0.15, hx - 0.15)
		var z := -hz + s.z * pow(rng.randf(), 0.8)
		var h: float = height.call(x, z)
		var y := h * rng.randf_range(0.8, 1.02)
		var b: Basis = slope_basis.call(x, z) * Basis(Vector3.UP, rng.randf() * TAU)
		var p := Vector3(x, y, z)
		var roll := rng.randf()
		if roll < 0.36:
			var sz := rng.randf_range(0.4, 0.7)
			_bag(g, p + Vector3(0, sz * 0.15, 0), sz, bag_cols[rng.randi() % bag_cols.size()], rng.randf() * TAU)
		elif roll < 0.46:
			_heap_body_bag(g, p, b, rng)
		elif roll < 0.53:
			_sheeted_body(g, p, b, rng, skin, blood)
		elif roll < 0.56:
			# An arm out of the heap, hanging down the slope.
			var ab := b * Basis(Vector3.RIGHT, rng.randf_range(0.6, 1.2))
			g.cyl(0.045, 0.34, p + ab * Vector3(0, 0.12, 0), skin, "y", 6)
			g.cyl(0.04, 0.3, p + ab * Vector3(0, 0.42, 0), skin.darkened(0.1), "y", 6)
			g.box(Vector3(0.09, 0.03, 0.12), p + ab * Vector3(0, 0.6, 0.02), skin.darkened(0.15), 0, ab)
		elif roll < 0.61:
			_skull(g, p + Vector3(0, 0.06, 0), b, rng)
		elif roll < 0.67:
			for n in 3:   # bones
				g.box(Vector3(0.05, 0.05, rng.randf_range(0.25, 0.45)), p + b * Vector3(rng.randf_range(-0.2, 0.2), 0.03, rng.randf_range(-0.2, 0.2)),
						Color(0.7, 0.66, 0.56), 0, b * Basis(Vector3.UP, rng.randf() * TAU))
		elif roll < 0.73:
			var bs := Vector3(rng.randf_range(0.3, 0.6), rng.randf_range(0.2, 0.45), rng.randf_range(0.3, 0.5))
			g.box(bs, p + b * Vector3(0, bs.y * 0.3, 0), Color(0.36, 0.26, 0.15).darkened(rng.randf_range(0.0, 0.6)), 0, b)
		elif roll < 0.77:
			# A biohazard bin or a sharps box, fallen over.
			var red := rng.randf() < 0.5
			var bb := b * Basis(Vector3.BACK, rng.randf_range(-1.4, 1.4))
			g.box(Vector3(0.4, 0.5, 0.4) if red else Vector3(0.3, 0.35, 0.22), p + bb * Vector3(0, 0.15, 0), Color(0.58, 0.07, 0.05) if red else YELLOW, 0, bb)
			g.box(Vector3(0.42, 0.05, 0.42) if red else Vector3(0.31, 0.05, 0.23), p + bb * Vector3(0, 0.42 if red else 0.34, 0), Color(0.5, 0.05, 0.04), 0, bb)
		elif roll < 0.8:
			# A bedpan or a kidney dish.
			g.box(Vector3(0.36, 0.08, 0.28), p + b * Vector3(0, 0.04, 0), STEEL, 0, b)
		elif roll < 0.83:
			# A drip stand stuck in at an angle.
			var pb := Basis(Vector3.BACK, rng.randf_range(-0.8, 0.8)) * Basis(Vector3.RIGHT, rng.randf_range(-0.6, 0.3))
			g.box(Vector3(0.025, 1.7, 0.025), p + pb * Vector3(0, 0.5, 0), CHROME, 0, pb)
			g.box(Vector3(0.3, 0.02, 0.02), p + pb * Vector3(0, 1.3, 0), CHROME, 0, pb)
		elif roll < 0.86:
			# A broken chair.
			var cb := b * Basis(Vector3.BACK, rng.randf_range(0.8, 1.6))
			g.box(Vector3(0.45, 0.05, 0.45), p + cb * Vector3(0, 0.1, 0), TEAL, 0, cb)
			g.box(Vector3(0.45, 0.4, 0.05), p + cb * Vector3(0, 0.3, 0.2), TEAL, 0, cb)
			for n in 3:
				g.box(Vector3(0.025, 0.42, 0.025), p + cb * Vector3(-0.18 + n * 0.18, -0.12, -0.18), DARK_STEEL, 0, cb * Basis(Vector3.RIGHT, 0.4 * n))
		elif roll < 0.89:
			# A stained mattress, folded over the heap.
			g.box(Vector3(0.9, 0.16, 1.3), p + b * Vector3(0, 0.05, 0), Color(0.46, 0.44, 0.36), 0, b * Basis(Vector3.RIGHT, 0.2))
			g.box(Vector3(0.5, 0.165, 0.6), p + b * Vector3(0.15, 0.05, 0.2), Color(0.3, 0.12, 0.08), 0, b * Basis(Vector3.RIGHT, 0.2))
		else:
			# Rags, sheets and gloves, a lot of them bloody.
			var rc: Color = [blood, Color(0.72, 0.7, 0.62), Color(0.45, 0.7, 0.75), Color(0.35, 0.05, 0.03), Color(0.12, 0.1, 0.08)][rng.randi() % 5]
			g.box(Vector3(rng.randf_range(0.2, 0.55), 0.02, rng.randf_range(0.15, 0.45)), p + b * Vector3(0, 0.02, 0), rc, 0, b)
	# Blood run down the front onto the floor.
	for k in int(s.x * 1.2):
		var x := rng.randf_range(-hx + 0.3, hx - 0.3)
		g.box(Vector3(rng.randf_range(0.2, 0.6), 0.004, rng.randf_range(0.3, 0.7)), Vector3(x, 0.006, -hz + rng.randf_range(-0.2, 0.15)), blood, 0,
				Basis(Vector3.UP, rng.randf_range(-0.6, 0.6)))


## A body bag lying on the heap: black, bulging where the body is, a zip down it, sometimes a tag.
static func _heap_body_bag(g: Geo, p: Vector3, b: Basis, rng: RandomNumberGenerator) -> void:
	var bag := Color(0.035, 0.035, 0.04)
	var long := rng.randf_range(1.7, 1.95)
	g.blob(Vector3(0.55, 0.3, long), p + b * Vector3(0, 0.12, 0), bag, b, 0.6, 8, 5)
	g.blob(Vector3(0.34, 0.24, 0.34), p + b * Vector3(0, 0.2, -long * 0.38), bag, b, 0.4, 7, 4)       # the head
	g.blob(Vector3(0.3, 0.2, 0.28), p + b * Vector3(0.1, 0.19, long * 0.4), bag, b, 0.4, 6, 3)         # feet
	g.box(Vector3(0.02, 0.01, long * 0.85), p + b * Vector3(0, 0.27, 0), Color(0.3, 0.3, 0.3), 0, b)   # the zip
	if rng.randf() < 0.5:
		g.box(Vector3(0.08, 0.005, 0.12), p + b * Vector3(0.12, 0.26, long * 0.44), Color(0.85, 0.82, 0.7), 0, b)


## A body under a stained sheet, a bare foot out at one end with a tag on its toe.
static func _sheeted_body(g: Geo, p: Vector3, b: Basis, rng: RandomNumberGenerator, skin: Color, blood: Color) -> void:
	var sheet := Color(0.66, 0.65, 0.58)
	g.blob(Vector3(0.6, 0.28, 1.75), p + b * Vector3(0, 0.12, 0), sheet, b, 0.7, 8, 5)
	g.blob(Vector3(0.3, 0.22, 0.32), p + b * Vector3(0, 0.2, -0.78), sheet, b, 0.4, 7, 4)
	g.box(Vector3(0.3, 0.012, 0.4), p + b * Vector3(rng.randf_range(-0.1, 0.1), 0.27, rng.randf_range(-0.4, 0.2)), blood, 0, b)
	var foot := p + b * Vector3(0.12, 0.13, 0.92)
	g.box(Vector3(0.1, 0.1, 0.24), foot, skin, 0, b)
	g.box(Vector3(0.06, 0.004, 0.09), foot + b * Vector3(0.0, 0.0, 0.16), Color(0.9, 0.88, 0.78), 0, b * Basis(Vector3.RIGHT, 1.2))


## A skull, half sunk in the rubbish.
static func _skull(g: Geo, p: Vector3, b: Basis, rng: RandomNumberGenerator) -> void:
	var bone := Color(0.72, 0.68, 0.58)
	var sb := b * Basis(Vector3.UP, rng.randf() * TAU)
	g.blob(Vector3(0.17, 0.18, 0.21), p, bone, sb, 0.2, 7, 5)
	g.box(Vector3(0.11, 0.06, 0.08), p + sb * Vector3(0, -0.07, -0.07), bone.darkened(0.1), 0, sb)
	for sx in [-0.04, 0.04]:
		g.box(Vector3(0.04, 0.035, 0.02), p + sb * Vector3(sx, 0.0, -0.1), Color(0.05, 0.04, 0.03), 0, sb)


## One station of the OR's lab wall: a white base cabinet with a black top, a backsplash, and a
## shelf on the wall above crowded with bottles and jars (from `seed`). Back is +Z (the wall).
static func _lab_counter(g: Geo, seed: int) -> void:
	_counter_body(g, 1.5, 0.92, 0.7, Color(0.84, 0.86, 0.86), Color(0.08, 0.08, 0.09))
	g.box(Vector3(1.5, 0.3, 0.02), Vector3(0, 1.07, 0.34), Color(0.8, 0.82, 0.82))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for shelf_y in [1.6, 1.98]:
		g.box(Vector3(1.44, 0.03, 0.26), Vector3(0, shelf_y, 0.23), Color(0.78, 0.8, 0.8))
		for sx in [-0.66, 0.66]:
			g.box(Vector3(0.02, 0.12, 0.2), Vector3(sx, shelf_y - 0.07, 0.25), DARK_STEEL)
		var x := -0.64
		while x < 0.62:
			var r := rng.randf_range(0.03, 0.06)
			var h := rng.randf_range(0.1, 0.26)
			var kind := rng.randi() % 5
			var col: Color = [Color(0.45, 0.25, 0.08, 0.8), Color(0.8, 0.85, 0.88, 0.45), Color(0.2, 0.3, 0.6, 0.8),
					Color(0.9, 0.9, 0.88), Color(0.3, 0.45, 0.2, 0.8)][kind]
			if kind == 3:
				g.box(Vector3(r * 2.2, h * 0.8, r * 2.0), Vector3(x + r, shelf_y + 0.015 + h * 0.4, 0.22), col)   # a box
			else:
				g.cyl(r, h, Vector3(x + r, shelf_y + 0.015 + h * 0.5, 0.22), col, "y", 8, 2 if col.a < 1.0 else 0)
				g.cyl(r * 0.6, 0.03, Vector3(x + r, shelf_y + 0.03 + h, 0.22), DARK, "y", 6)
			x += r * 2.0 + rng.randf_range(0.01, 0.05)


## A rack of test tubes, `rows` x `cols`, capped in colours, standing on `at` (its base centre).
static func _vial_rack(g: Geo, at: Vector3, rows: int, cols: int, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var w := cols * 0.05 + 0.04
	var d := rows * 0.05 + 0.04
	g.box(Vector3(w, 0.02, d), at + Vector3(0, 0.01, 0), Color(0.85, 0.86, 0.86))
	g.box(Vector3(w, 0.02, d), at + Vector3(0, 0.08, 0), Color(0.85, 0.86, 0.86))
	var caps := [Color(0.7, 0.1, 0.1), Color(0.6, 0.2, 0.6), Color(0.9, 0.75, 0.1), Color(0.2, 0.5, 0.8), Color(0.3, 0.6, 0.3)]
	var fills := [Color(0.45, 0.03, 0.03), Color(0.75, 0.65, 0.2), Color(0.5, 0.1, 0.1), Color(0.35, 0.4, 0.3)]
	for r in rows:
		for c in cols:
			var p := at + Vector3(-w * 0.5 + 0.045 + c * 0.05, 0.0, -d * 0.5 + 0.045 + r * 0.05)
			g.cyl(0.013, 0.12, p + Vector3(0, 0.07, 0), Color(0.85, 0.9, 0.92, 0.35), "y", 6, 2)
			g.cyl(0.011, rng.randf_range(0.03, 0.09), p + Vector3(0, 0.04, 0), fills[rng.randi() % fills.size()], "y", 6)
			g.cyl(0.015, 0.02, p + Vector3(0, 0.14, 0), caps[rng.randi() % caps.size()], "y", 6)


## Personnel's palm vein machine, across the whole back wall (7.2 x 2.95 x 1.5 m, back at +Z):
## a big screen over a base cabinet, the palm console standing out in front of it, a tank of
## blood either side, and a server tower at each end, all tied together by blood lines over the
## top and cables along the floor. entrance.gd's VEIN_* constants point at the plate and the screen.
static func _vein_machine(g: Geo) -> void:
	var white := Color(0.88, 0.9, 0.92)
	var panel := Color(0.8, 0.83, 0.86)
	var blood := Color(0.42, 0.02, 0.03)
	# Plinth with hazard striping along its front.
	g.box(Vector3(7.2, 0.12, 1.5), Vector3(0, 0.06, 0), DARK_STEEL)
	for k in 24:
		g.box(Vector3(0.3, 0.1, 0.01), Vector3(-3.45 + k * 0.3, 0.06, -0.755), YELLOW if k % 2 == 0 else DARK)
	# The screen: bezel, glass (off), name plate, and a row of status lights on the cabinet below.
	g.box(Vector3(3.5, 2.0, 0.35), Vector3(0, 1.9, 0.575), white)
	g.box(Vector3(3.2, 1.7, 0.01), Vector3(0, 1.9, 0.395), Color(0.03, 0.05, 0.06, 0.92), 2)
	g.box(Vector3(0.9, 0.07, 0.01), Vector3(0, 0.96, 0.395), CHROME)
	g.box(Vector3(3.5, 0.78, 0.9), Vector3(0, 0.51, 0.3), panel)
	for k in 12:
		g.box(Vector3(0.04, 0.025, 0.01), Vector3(-0.66 + k * 0.12, 0.8, -0.155), Color(0.25, 0.6, 1.0), 1)
	for sx in [-1.2, 1.2]:
		g.box(Vector3(0.9, 0.5, 0.01), Vector3(sx, 0.45, -0.155), white)   # service hatches
		g.box(Vector3(0.12, 0.03, 0.02), Vector3(sx, 0.62, -0.17), DARK_STEEL)
	# The palm console: a pedestal with a slanted plate, the glass outlined in standby blue.
	g.box(Vector3(0.55, 0.85, 0.45), Vector3(0, 0.47, -0.42), white)
	var tilt := Basis(Vector3.RIGHT, -0.4)   # the plate leans toward whoever stands at it
	g.box(Vector3(1.0, 0.1, 0.6), Vector3(0, 0.95, -0.5), panel, 0, tilt)
	var plate := Vector3(0, 1.005, -0.52)
	g.box(Vector3(0.5, 0.012, 0.36), plate, Color(0.15, 0.25, 0.32, 0.75), 2, tilt)
	var edge := Color(0.3, 0.65, 1.0)
	for sz in [-0.19, 0.19]:
		g.box(Vector3(0.54, 0.014, 0.015), plate + tilt * Vector3(0, 0.002, sz), edge, 1, tilt)
	for sx in [-0.26, 0.26]:
		g.box(Vector3(0.015, 0.014, 0.38), plate + tilt * Vector3(sx, 0.002, 0), edge, 1, tilt)
	# Tanks of blood between the screen and the towers.
	for sx in [-1.97, 1.97]:
		g.cyl(0.2, 0.08, Vector3(sx, 0.16, 0.1), DARK_STEEL, "y", 14)
		g.cyl(0.2, 0.08, Vector3(sx, 1.84, 0.1), DARK_STEEL, "y", 14)
		g.cyl(0.14, 1.2, Vector3(sx, 0.8, 0.1), blood, "y", 14, 1)
		g.cyl(0.17, 1.6, Vector3(sx, 1.0, 0.1), Color(0.75, 0.82, 0.85, 0.3), "y", 14, 2)
		g.cyl(0.035, 1.06, Vector3(sx, 2.41, 0.1), blood, "y", 8)   # up to the blood line
	# Server towers at the ends: vents, a panel of lights, two gauges, a beacon on top.
	for sx in [-2.9, 2.9]:
		g.box(Vector3(1.3, 2.75, 1.0), Vector3(sx, 1.495, 0.25), white)
		g.box(Vector3(1.34, 0.06, 1.04), Vector3(sx, 2.86, 0.25), DARK_STEEL)
		for k in 8:
			g.box(Vector3(1.0, 0.025, 0.01), Vector3(sx, 0.3 + k * 0.08, -0.255), DARK)
		g.box(Vector3(1.0, 0.62, 0.01), Vector3(sx, 1.32, -0.255), DARK)
		var cols := [Color(0.2, 1.0, 0.45), Color(1.0, 0.7, 0.15), Color(0.2, 1.0, 0.45), Color(1.0, 0.18, 0.12)]
		for r in 4:
			for c in 7:
				g.box(Vector3(0.05, 0.04, 0.01), Vector3(sx - 0.39 + c * 0.13, 1.1 + r * 0.14, -0.262), cols[(r * 7 + c + int(sx > 0)) % 4], 1)
		for gx in [-0.28, 0.28]:
			var gp := Vector3(sx + gx, 1.98, -0.27)
			g.cyl(0.13, 0.03, gp, DARK, "z", 16)
			g.cyl(0.11, 0.01, gp + Vector3(0, 0, -0.02), ENAMEL, "z", 16)
			g.box(Vector3(0.012, 0.09, 0.005), gp + Vector3(0.02, 0.03, -0.028), RED, 0, Basis(Vector3.BACK, -0.6 if gx < 0 else 0.9))
		g.box(Vector3(1.0, 0.22, 0.01), Vector3(sx, 2.45, -0.255), panel)
		g.cyl(0.09, 0.12, Vector3(sx, 2.94, 0.25), Color(1.0, 0.55, 0.1), "y", 10, 1)
	# Blood lines across the top, and cables along the floor from the console to the towers.
	g.cyl(0.04, 5.8, Vector3(0, 2.94, 0.1), blood, "x", 8)
	g.cyl(0.03, 5.8, Vector3(0, 2.94, 0.3), Color(0.3, 0.02, 0.03), "x", 8)
	for side in [-1.0, 1.0]:
		for z in [-0.34, -0.48]:
			g.cyl(0.035, 2.0, Vector3(side * 1.25, 0.16, z), RUBBER, "x", 6)


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


## GRAFTING part one: a jar of fluid on a shelf with something floating in it, `i` picks what: mostly
## heads (a surgeon's, a Hive's), now and then an eye or a brain. Origin is the jar's base.
static func _specimen_jar(g: Geo, base: Vector3, i: int, rng: RandomNumberGenerator) -> void:
	var fluid: Color = [Color(0.85, 0.8, 0.45, 0.35), Color(0.6, 0.8, 0.7, 0.35), Color(0.8, 0.7, 0.55, 0.35)][rng.randi() % 3]
	g.cyl(0.072, 0.27, base + Vector3(0, 0.135, 0), fluid, "y", 14, 2)
	g.cyl(0.076, 0.03, base + Vector3(0, 0.285, 0), DARK_STEEL, "y", 14)
	g.cyl(0.078, 0.012, base + Vector3(0, 0.006, 0), DARK_STEEL, "y", 14)
	var c := base + Vector3(0, 0.13, 0)
	var what := i % 8
	var ry := rng.randf() * TAU
	if what == 3:
		# A loose eyeball, and its stub of nerve.
		g.blob(Vector3(0.05, 0.05, 0.05), c, Color(0.92, 0.9, 0.86), Basis.IDENTITY, 0.0, 8, 5)
		g.cyl(0.012, 0.03, c + Vector3(0, 0.0, 0.04), Color(0.8, 0.62, 0.58), "z", 6)
		g.cyl(0.014, 0.008, c + Vector3(0, 0.0, -0.023), Color(0.2, 0.4, 0.6), "z", 8)
	elif what == 6:
		g.blob(Vector3(0.11, 0.08, 0.1), c, Color(0.78, 0.55, 0.55), Basis(Vector3.UP, ry), 0.2, 8, 5)
	else:
		# A head: bare, bald, the face turned a little toward the room.
		var hive := what % 2 == 1
		var skin: Color = Color(0.55, 0.6, 0.45) if hive else [Color(0.86, 0.68, 0.56), Color(0.62, 0.46, 0.36), Color(0.93, 0.78, 0.66)][rng.randi() % 3]
		var face := Basis(Vector3.UP, rng.randf_range(-0.6, 0.6))
		g.blob(Vector3(0.105, 0.125, 0.105), c, skin, face, 0.1, 10, 6)
		for ex in [-0.024, 0.024]:
			var ep: Vector3 = c + face * Vector3(ex, 0.012, -0.046)
			if hive:
				g.cyl(0.011, 0.006, ep, Color(1.0, 0.5, 0.1), "z", 8, 1)
			else:
				g.cyl(0.011, 0.006, ep, Color(0.93, 0.93, 0.9), "z", 8)
				g.cyl(0.005, 0.007, ep + face * Vector3(0, 0, -0.001), Color(0.2, 0.35, 0.55), "z", 6)
		g.blob(Vector3(0.018, 0.024, 0.02), c + face * Vector3(0, -0.006, -0.055), skin.darkened(0.08), face, 0.0, 6, 4)   # the nose


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
			# The standard desk computer (the pharmacy terminal's): a boxy beige monitor with a green
			# screen, and its keyboard. Origin on the desk top; whoever uses it stands at -Z.
			var beige := Color(0.74, 0.7, 0.6)
			g.box(Vector3(0.44, 0.34, 0.3), Vector3(0, 0.18, 0.1), beige)
			g.box(Vector3(0.36, 0.26, 0.01), Vector3(0, 0.19, -0.055), Color(0.2, 0.56, 0.3), 1)
			g.box(Vector3(0.4, 0.03, 0.15), Vector3(0, 0.015, -0.22), beige)
			for r in 3:
				g.box(Vector3(0.36, 0.004, 0.025), Vector3(0, 0.032, -0.27 + r * 0.04), beige.darkened(0.25))
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
		# ---- crematorium (hub) ------------------------------------------------
		"junk_mound_n1", "junk_mound_n2", "junk_mound_n3", "junk_mound_s1", "junk_mound_s2", "junk_mound_s3":
			_junk_mound(g, s, hash(kind))
		"ash_pile":
			g.blob(Vector3(1.4, 0.3, 1.1), Vector3(0, 0.08, 0), Color(0.3, 0.29, 0.28), Basis.IDENTITY, 0.9, 10, 4)
			g.blob(Vector3(0.6, 0.18, 0.5), Vector3(0.35, 0.12, -0.2), Color(0.22, 0.21, 0.2), Basis.IDENTITY, 0.9)
			for k in 6:   # bits of bone
				g.box(Vector3(0.06, 0.03, 0.03), Vector3(-0.4 + k * 0.15, 0.2 - absf(k - 2.5) * 0.03, 0.1 * (k % 3 - 1)), Color(0.72, 0.68, 0.6), 0, Basis(Vector3.UP, k * 0.9))
		"litter":
			# Papers, a burnt rag, a glove, flat on the floor.
			var bits := [[Vector3(-0.5, 0.0, -0.3), Vector2(0.21, 0.29), 0.4, Color(0.8, 0.78, 0.7)], [Vector3(0.2, 0.0, 0.35), Vector2(0.21, 0.29), -0.8, Color(0.75, 0.72, 0.62)],
					[Vector3(0.55, 0.0, -0.4), Vector2(0.3, 0.2), 1.2, Color(0.12, 0.1, 0.08)], [Vector3(-0.1, 0.0, -0.05), Vector2(0.15, 0.1), 0.2, Color(0.45, 0.7, 0.75)],
					[Vector3(-0.6, 0.0, 0.4), Vector2(0.21, 0.29), 2.0, Color(0.7, 0.65, 0.5)], [Vector3(0.6, 0.0, 0.1), Vector2(0.12, 0.2), -0.3, Color(0.75, 0.74, 0.7)]]
			for b in bits:
				var bsz: Vector2 = b[1]
				g.box(Vector3(bsz.x, 0.004, bsz.y), b[0] + Vector3(0, 0.006, 0), b[3], 0, Basis(Vector3.UP, float(b[2])))
		# ---- personnel (hub) -------------------------------------------------
		"staff_lockers":
			g.box(Vector3(2.4, 0.1, 0.46), Vector3(0, 0.05, 0.02), DARK)
			g.box(Vector3(2.42, 0.04, 0.5), Vector3(0, 1.97, 0), DARK_STEEL)
			for i in 4:
				var x := -0.9 + i * 0.6
				g.box(Vector3(0.58, 1.85, 0.48), Vector3(x, 1.02, 0), Color(0.36, 0.42, 0.47))
				g.box(Vector3(0.54, 1.75, 0.01), Vector3(x, 1.02, -0.245), Color(0.4, 0.47, 0.52))
				for v in 4:
					g.box(Vector3(0.3, 0.015, 0.005), Vector3(x, 1.62 + v * 0.05, -0.252), DARK)
				# The emblem plate: blank until its owner stamps it.
				g.box(Vector3(0.2, 0.2, 0.006), Vector3(x, 1.3, -0.253), Color(0.8, 0.78, 0.7))
				g.box(Vector3(0.14, 0.03, 0.006), Vector3(x, 0.4, -0.253), Color(0.86, 0.85, 0.8))   # name tag
				g.box(Vector3(0.03, 0.14, 0.03), Vector3(x + 0.2, 1.05, -0.265), CHROME)
		"full_mirror":
			# The glass is a real mirror (scripts/personnel/mirrors.gd draws over it): same size and place.
			var glass: Vector2 = Mirrors.BIG_GLASS
			var gc: Vector3 = Mirrors.BIG_CENTRE
			g.box(Vector3(1.8, 2.86, 0.04), Vector3(0, m + 1.43, -0.02), DARK)
			g.box(Vector3(glass.x, glass.y, 0.01), gc + Vector3(0, 0, 0.005), Color(0.62, 0.7, 0.72, 0.55), 2)
			# Dressing-room bulbs down both sides and across the top; two have gone.
			var dead := [3, 12]
			var i := 0
			for sx in [-0.845, 0.845]:
				for k in 10:
					var p := Vector3(sx, m + 0.2 + k * 0.27, -0.06)
					if dead.has(i):
						g.cyl(0.03, 0.03, p, Color(0.25, 0.24, 0.2), "z", 8)
					else:
						g.cyl(0.03, 0.03, p, LAMP, "z", 8, 1)
					i += 1
			for k in 7:
				g.cyl(0.03, 0.03, Vector3(-0.63 + k * 0.21, m + 2.8, -0.06), LAMP, "z", 8, 1)
		"vanity":
			# A wall basin with its own mirror and a light bar over it. Back (+Z) against the wall.
			var back := 0.275
			g.box(Vector3(1.0, 0.14, 0.5), Vector3(0, 0.83, back - 0.25), ENAMEL)
			g.box(Vector3(0.62, 0.02, 0.32), Vector3(0, 0.9, back - 0.27), Color(0.55, 0.57, 0.57))   # the bowl
			g.box(Vector3(0.12, 0.08, 0.08), Vector3(0, 0.9, back - 0.05), CHROME)
			g.cyl(0.018, 0.2, Vector3(0, 1.0, back - 0.08), CHROME, "y", 8)
			g.cyl(0.015, 0.14, Vector3(0, 1.09, back - 0.14), CHROME, "z", 8)
			g.cyl(0.03, 0.62, Vector3(0, 0.45, back - 0.12), DARK_STEEL, "y", 8)   # the trap
			g.box(Vector3(0.84, 1.0, 0.03), Vector3(0, 1.68, back - 0.015), DARK_STEEL)
			g.box(Vector3(Mirrors.SINK_GLASS.x, Mirrors.SINK_GLASS.y, 0.01), Vector3(0, Mirrors.SINK_CENTRE.y, back - 0.035), Color(0.62, 0.7, 0.72, 0.55), 2)   # a real mirror
			g.box(Vector3(0.7, 0.06, 0.08), Vector3(0, 2.24, back - 0.05), DARK_STEEL)
			g.box(Vector3(0.64, 0.02, 0.05), Vector3(0, 2.2, back - 0.06), LAMP, 1)
			g.box(Vector3(0.08, 0.16, 0.08), Vector3(0.42, 1.1, back - 0.05), OFFWHITE)   # soap
			g.box(Vector3(0.03, 0.04, 0.03), Vector3(0.42, 1.03, back - 0.1), DARK)
		"vein_machine":
			_vein_machine(g)
		"shower":
			# Wall-mounted: the riser up the wall, an arm out, the head, two taps under it.
			g.cyl(0.018, 1.25, Vector3(0, m + 0.62, -0.03), CHROME, "y", 8)
			g.cyl(0.016, 0.3, Vector3(0, m + 1.25, -0.16), CHROME, "z", 8)
			g.cyl(0.09, 0.05, Vector3(0, m + 1.22, -0.3), CHROME, "y", 14)
			g.cyl(0.075, 0.01, Vector3(0, m + 1.195, -0.3), DARK_STEEL, "y", 14)
			g.box(Vector3(0.36, 0.1, 0.03), Vector3(0, m + 0.12, -0.015), STEEL)
			for sx in [-0.12, 0.12]:
				g.cyl(0.035, 0.05, Vector3(sx, m + 0.12, -0.05), CHROME, "z", 10)
				g.cyl(0.03, 0.02, Vector3(sx, m + 0.12, -0.08), Color(0.7, 0.15, 0.12) if sx < 0 else Color(0.15, 0.3, 0.7), "z", 10)
		"floor_drain":
			g.cyl(0.15, 0.008, Vector3(0, 0.014, 0), DARK_STEEL, "y", 16)
			for k in 5:
				g.box(Vector3(0.2, 0.004, 0.02), Vector3(0, 0.02, -0.08 + k * 0.04), RUBBER)
		"tile_floor":
			g.box(Vector3(s.x, 0.006, s.z), Vector3(0, 0.006, 0), Color(0.84, 0.86, 0.86))
			var grout := Color(0.62, 0.64, 0.65)
			for k in range(1, int(s.x / 0.3)):
				g.box(Vector3(0.022, 0.004, s.z), Vector3(-s.x * 0.5 + k * 0.3, 0.011, 0), grout)
			for k in range(1, int(s.z / 0.3)):
				g.box(Vector3(s.x, 0.004, 0.022), Vector3(0, 0.011, -s.z * 0.5 + k * 0.3), grout)
		"tile_wall", "tile_wall_end":
			g.box(Vector3(s.x, s.y, 0.02), Vector3(0, s.y * 0.5, -0.01), Color(0.88, 0.9, 0.9))
			_tile_lines(g, Vector3(0, 0, -0.021), s.x, s.y, -1.0)
		# ---- the OR's lab wall (hub) ----------------------------------------------
		"lab_centrifuge":
			_lab_counter(g, hash(kind))
			# The centrifuge: a squat white drum, a dark lid with a window onto the rotor, a slanted
			# panel with a little green readout. entrance.gd records where it is (spots.lab).
			g.box(Vector3(0.56, 0.3, 0.56), Vector3(-0.2, 1.07, -0.04), Color(0.88, 0.9, 0.9))
			g.cyl(0.25, 0.05, Vector3(-0.2, 1.245, -0.04), Color(0.3, 0.32, 0.34), "y", 18)
			g.cyl(0.15, 0.012, Vector3(-0.2, 1.275, -0.04), Color(0.2, 0.3, 0.35, 0.6), "y", 16, 2)
			g.cyl(0.03, 0.02, Vector3(-0.2, 1.265, -0.04), CHROME, "y", 8)
			for k in 6:
				var a := TAU * k / 6.0
				g.box(Vector3(0.03, 0.01, 0.1), Vector3(-0.2 + cos(a) * 0.07, 1.262, -0.04 + sin(a) * 0.07), DARK_STEEL, 0, Basis(Vector3.UP, -a))
			var panel := Basis(Vector3.RIGHT, -0.5)
			g.box(Vector3(0.5, 0.14, 0.04), Vector3(-0.2, 1.0, -0.33), Color(0.8, 0.82, 0.82), 0, panel)
			g.box(Vector3(0.16, 0.05, 0.01), Vector3(-0.3, 1.01, -0.355), Color(0.3, 1.0, 0.5), 1, panel)
			for k in 3:
				g.cyl(0.018, 0.02, Vector3(-0.1 + k * 0.08, 0.99, -0.35), [RED, DARK, DARK][k], "z", 8)
			# A rack of vials waiting for it.
			_vial_rack(g, Vector3(0.38, 0.92, 0.0), 2, 4, hash(kind) + 1)
		"lab_vials":
			_lab_counter(g, hash(kind))
			_vial_rack(g, Vector3(-0.4, 0.92, 0.05), 2, 5, hash(kind))
			_vial_rack(g, Vector3(0.05, 0.92, 0.12), 1, 5, hash(kind) + 7)
			# Beakers and flasks with things in them, and a burner.
			var liquids := [Color(0.5, 0.05, 0.05), Color(0.2, 0.55, 0.3), Color(0.75, 0.6, 0.15), Color(0.3, 0.3, 0.7)]
			for k in 4:
				var bp := Vector3(0.25 + (k % 2) * 0.2, 0.92, -0.12 - (k / 2) * 0.16)
				g.cyl(0.055, 0.14, bp + Vector3(0, 0.07, 0), Color(0.8, 0.85, 0.88, 0.3), "y", 10, 2)
				g.cyl(0.048, 0.08, bp + Vector3(0, 0.045, 0), liquids[k], "y", 10)
			g.cyl(0.04, 0.02, Vector3(0.58, 0.93, -0.2), DARK_STEEL, "y", 10)
			g.cyl(0.012, 0.14, Vector3(0.58, 1.0, -0.2), CHROME, "y", 6)
			g.box(Vector3(0.02, 0.24, 0.02), Vector3(-0.1, 1.04, -0.2), DARK, 0, Basis(Vector3.BACK, 0.3))   # pipette
		"lab_microscope":
			_lab_counter(g, hash(kind))
			# A microscope: foot, arm, stage, the tube and eyepiece.
			var m0 := Vector3(-0.15, 0.92, -0.02)
			g.box(Vector3(0.24, 0.05, 0.3), m0 + Vector3(0, 0.025, 0), DARK)
			g.box(Vector3(0.07, 0.34, 0.08), m0 + Vector3(0, 0.2, 0.1), ENAMEL)
			g.box(Vector3(0.18, 0.02, 0.16), m0 + Vector3(0, 0.16, -0.03), DARK)
			g.cyl(0.03, 0.2, m0 + Vector3(0, 0.32, -0.02), ENAMEL, "y", 10)
			g.cyl(0.018, 0.12, m0 + Vector3(0, 0.46, 0.03), DARK, "y", 8)
			g.cyl(0.012, 0.06, m0 + Vector3(0, 0.2, -0.05), CHROME, "y", 6)
			g.box(Vector3(0.07, 0.003, 0.025), m0 + Vector3(0, 0.172, -0.04), Color(0.8, 0.85, 0.88, 0.5), 2)   # a slide
			# A box of slides and a lamp.
			g.box(Vector3(0.22, 0.05, 0.16), Vector3(0.3, 0.945, -0.1), Color(0.3, 0.35, 0.5))
			g.cyl(0.06, 0.02, Vector3(0.5, 0.93, 0.15), DARK, "y", 10)
			g.box(Vector3(0.02, 0.3, 0.02), Vector3(0.5, 1.08, 0.15), DARK)
			g.box(Vector3(0.16, 0.06, 0.1), Vector3(0.44, 1.23, 0.08), DARK, 0, Basis(Vector3.BACK, 0.4))
		"lab_analyzer":
			_lab_counter(g, hash(kind))
			# A blood analyser: a boxy machine with a screen and a carousel of sample tubes on top.
			g.box(Vector3(0.8, 0.45, 0.55), Vector3(-0.2, 1.145, 0.0), Color(0.86, 0.88, 0.88))
			g.box(Vector3(0.34, 0.22, 0.01), Vector3(-0.35, 1.2, -0.28), DARK)
			g.box(Vector3(0.3, 0.18, 0.005), Vector3(-0.35, 1.2, -0.287), Color(0.25, 0.6, 1.0), 1)
			g.box(Vector3(0.22, 0.02, 0.01), Vector3(0.0, 1.0, -0.28), DARK)   # printer slot
			g.box(Vector3(0.18, 0.1, 0.003), Vector3(0.0, 0.96, -0.29), Color(0.9, 0.9, 0.86), 0, Basis(Vector3.RIGHT, 0.3))
			g.cyl(0.18, 0.03, Vector3(-0.1, 1.385, 0.05), Color(0.4, 0.42, 0.44), "y", 16)
			for k in 10:
				var a := TAU * k / 10.0
				g.cyl(0.012, 0.09, Vector3(-0.1 + cos(a) * 0.14, 1.44, 0.05 + sin(a) * 0.14), [Color(0.5, 0.05, 0.05), Color(0.6, 0.2, 0.6)][k % 2], "y", 6)
			g.box(Vector3(0.3, 0.2, 0.3), Vector3(0.45, 1.02, 0.05), Color(0.9, 0.9, 0.88))   # a box of gloves
			g.box(Vector3(0.12, 0.04, 0.01), Vector3(0.45, 1.08, -0.1), Color(0.45, 0.7, 0.75))
		"lab_specimens":
			_lab_counter(g, hash(kind))
			# Jars of things in fluid, a dissection tray, a scale.
			var flesh := [Color(0.45, 0.12, 0.12), Color(0.55, 0.35, 0.3), Color(0.35, 0.3, 0.2), Color(0.6, 0.45, 0.4)]
			for k in 4:
				var jp := Vector3(-0.55 + k * 0.2, 0.92, 0.12)
				g.cyl(0.08, 0.26, jp + Vector3(0, 0.13, 0), Color(0.85, 0.8, 0.45, 0.35), "y", 12, 2)
				g.blob(Vector3(0.1, 0.1, 0.09), jp + Vector3(0, 0.12, 0), flesh[k], Basis(Vector3.UP, k * 1.7), 0.2, 6, 4)
				g.cyl(0.085, 0.03, jp + Vector3(0, 0.275, 0), DARK_STEEL, "y", 12)
			g.box(Vector3(0.5, 0.03, 0.34), Vector3(-0.3, 0.935, -0.17), STEEL)
			g.blob(Vector3(0.2, 0.06, 0.14), Vector3(-0.32, 0.96, -0.17), Color(0.4, 0.08, 0.08), Basis.IDENTITY, 0.8, 6, 3)
			g.box(Vector3(0.14, 0.008, 0.02), Vector3(-0.12, 0.955, -0.1), CHROME, 0, Basis(Vector3.UP, 0.4))
			g.box(Vector3(0.3, 0.08, 0.3), Vector3(0.45, 0.96, -0.08), Color(0.85, 0.86, 0.84))
			g.cyl(0.11, 0.01, Vector3(0.45, 1.005, -0.08), STEEL, "y", 14)
			g.box(Vector3(0.1, 0.03, 0.005), Vector3(0.45, 0.96, -0.232), Color(0.3, 1.0, 0.5), 1)
		"lab_vat_bench":
			# GRAFTING part one: three round marks on the counter where a specimen vat stands (the vats
			# are items, scripts/grafting/vats.gd), and two shelves of jars over it, mostly heads.
			_counter_body(g, 1.5, 0.92, 0.7, Color(0.84, 0.86, 0.86), Color(0.08, 0.08, 0.09))
			g.box(Vector3(1.5, 0.3, 0.02), Vector3(0, 1.07, 0.34), Color(0.8, 0.82, 0.82))
			for vx in [-0.5, 0.0, 0.5]:
				g.cyl(0.085, 0.004, Vector3(vx, 0.927, 0.0), Color(0.6, 0.66, 0.68), "y", 18)
			var jar_rng := RandomNumberGenerator.new()
			jar_rng.seed = hash(kind) + int(s.x * 100.0)
			var jar_i := 0
			for shelf_y in [1.6, 1.98]:
				g.box(Vector3(1.44, 0.03, 0.26), Vector3(0, shelf_y, 0.23), Color(0.78, 0.8, 0.8))
				for sx in [-0.66, 0.66]:
					g.box(Vector3(0.02, 0.12, 0.2), Vector3(sx, shelf_y - 0.07, 0.25), DARK_STEEL)
				for jx in [-0.53, -0.18, 0.18, 0.53]:
					_specimen_jar(g, Vector3(jx, shelf_y + 0.015, 0.22), jar_i, jar_rng)
					jar_i += 1
		"lab_corner":
			_counter_body(g, 0.75, 0.92, 0.7, Color(0.84, 0.86, 0.86), Color(0.08, 0.08, 0.09))
			g.box(Vector3(0.75, 0.3, 0.02), Vector3(0, 1.07, 0.34), Color(0.8, 0.82, 0.82))
			for shelf_y in [1.6, 1.98]:
				g.box(Vector3(0.75, 0.03, 0.26), Vector3(0, shelf_y, 0.23), Color(0.78, 0.8, 0.8))
		"lab_sink":
			_lab_counter(g, hash(kind))
			g.box(Vector3(0.6, 0.02, 0.44), Vector3(-0.2, 0.93, -0.05), DARK_STEEL)   # the basin
			g.cyl(0.018, 0.4, Vector3(-0.2, 1.12, 0.22), CHROME, "y", 8)
			g.cyl(0.016, 0.22, Vector3(-0.2, 1.31, 0.11), CHROME, "z", 8)
			# An eyewash on the wall, a towel dispenser, soap.
			g.box(Vector3(0.28, 0.06, 0.18), Vector3(0.42, 1.12, 0.2), Color(0.9, 0.72, 0.1))
			for sx in [-0.06, 0.06]:
				g.cyl(0.04, 0.05, Vector3(0.42 + sx, 1.17, 0.18), Color(0.3, 0.6, 0.2), "y", 8)
			g.box(Vector3(0.3, 0.36, 0.14), Vector3(0.42, 1.55, 0.28), Color(0.85, 0.86, 0.84))
			g.box(Vector3(0.12, 0.2, 0.08), Vector3(0.1, 1.25, 0.3), OFFWHITE)
		"blood_fridge":
			# A blood bank fridge, glass door, lit inside, bags of blood on its shelves; two gas
			# cylinders chained up beside it.
			var fx := -0.25
			g.box(Vector3(0.9, 2.0, 0.7), Vector3(fx, 1.0, 0.0), Color(0.86, 0.88, 0.88))
			g.box(Vector3(0.76, 1.6, 0.6), Vector3(fx, 1.05, 0.01), Color(0.92, 0.94, 0.96), 1)
			for k in 4:
				var sy := 0.4 + k * 0.38
				g.box(Vector3(0.74, 0.015, 0.55), Vector3(fx, sy, 0.02), CHROME)
				for n in 5:
					g.box(Vector3(0.11, 0.2, 0.04), Vector3(fx - 0.28 + n * 0.14, sy + 0.11, -0.05 + (n % 2) * 0.1), Color(0.45, 0.02, 0.03), 0, Basis(Vector3.RIGHT, -0.2))
			g.box(Vector3(0.8, 1.66, 0.02), Vector3(fx, 1.05, -0.34), Color(0.7, 0.8, 0.85, 0.25), 2)
			g.box(Vector3(0.03, 0.5, 0.03), Vector3(fx + 0.34, 1.1, -0.37), CHROME)
			g.box(Vector3(0.2, 0.07, 0.01), Vector3(fx, 1.93, -0.355), DARK)
			g.box(Vector3(0.16, 0.04, 0.005), Vector3(fx, 1.93, -0.362), Color(1.0, 0.3, 0.2), 1)
			for k in 2:
				var cx := 0.42 + k * 0.2
				var col := Color(0.2, 0.5, 0.25) if k == 0 else Color(0.2, 0.35, 0.6)
				g.cyl(0.09, 1.3, Vector3(cx, 0.65, 0.15), col, "y", 12)
				g.cyl(0.05, 0.12, Vector3(cx, 1.36, 0.15), ENAMEL, "y", 10)
				g.cyl(0.03, 0.08, Vector3(cx, 1.46, 0.15), CHROME, "y", 8)
			g.box(Vector3(0.44, 0.02, 0.02), Vector3(0.52, 1.0, 0.04), DARK_STEEL)   # the chain
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
