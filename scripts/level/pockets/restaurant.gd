extends RefCounted
## POCKETS: the Restaurant. A complete Mexican restaurant with no windows: a host stand by locked
## front doors, booths along the walls, tables laid for four, a bar with its bottles lined up, a
## kitchen out back through a swing door, and the restrooms. The dining room is a little larger than
## it should be. Every table is set as if the first customers are about to walk in; nobody does.
##
## layout(stubs, seed) is pure data; build(layout, origin, out) makes the nodes (see factory.gd).

const Common := preload("res://scripts/level/pockets/pocket_common.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")

const T := 1.5
const M := 10
const W := 34
const H := 24
const DINING_CEIL := 3.6
const BACK_CEIL := 3.0
const KITCHEN_CEIL := 3.2

const INTERIOR := Rect2i(M + 1, M + 1, W, H)            # x 11..44, y 11..34
const DINING := Rect2i(M + 1, M + 1, W, 16)             # y 11..26; wall row y 27
const KITCHEN := Rect2i(M + 15, M + 18, W - 14, 7)      # x 25..44, y 28..34; wall column x 24
const CORRIDOR := Rect2i(M + 1, M + 18, 13, 2)          # x 11..23, y 28..29; wall row y 30
const MEN := Rect2i(M + 1, M + 21, 5, 4)                # x 11..15, y 31..34
const WOMEN := Rect2i(M + 7, M + 21, 5, 4)              # x 17..21
const BAR := Rect2i(M + 29, M + 2, 5, 9)                # counter x 39, aisle x 40..42, back bar x 43; y 12..20
const FRONT_DOOR := Vector2i(M + 17, M)                 # the two door tiles x 27..28 on the north wall


static func layout(stubs: Array, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var g := Common.new_grid(INTERIOR.end.x + M + 1, INTERIOR.end.y + M + 1)
	var dining := Common.add_room(g, {"name": "dining", "ceil": DINING_CEIL, "floor": "saltillo", "ceiling": "planks",
			"wall": "stucco", "wall_low": "talavera", "split": 1.1, "place": "restaurant"})
	var kitchen := Common.add_room(g, {"name": "kitchen", "ceil": KITCHEN_CEIL, "floor": "kitchen_floor", "ceiling": "kitchen_ceiling",
			"wall": "kitchen_wall", "wall_low": "", "split": 0.0, "place": "restaurant_kitchen"})
	var corridor := Common.add_room(g, {"name": "corridor", "ceil": BACK_CEIL, "floor": "saltillo", "ceiling": "kitchen_ceiling",
			"wall": "stucco", "wall_low": "wood_low", "split": 1.1, "place": "restaurant"})
	var restroom := Common.add_room(g, {"name": "restroom", "ceil": BACK_CEIL, "floor": "restroom_floor", "ceiling": "kitchen_ceiling",
			"wall": "restroom_wall", "wall_low": "", "split": 0.0, "place": "restaurant_restroom"})
	Common.carve(g, DINING, dining)
	Common.carve(g, KITCHEN, kitchen)
	Common.carve(g, CORRIDOR, corridor)
	Common.carve(g, MEN, restroom)
	Common.carve(g, WOMEN, restroom)
	var doors := {
		"corridor": Vector2i(M + 2, DINING.end.y),
		"kitchen": [Vector2i(M + 22, DINING.end.y), Vector2i(M + 23, DINING.end.y)],
		"men": Vector2i(MEN.position.x + 2, CORRIDOR.end.y),
		"women": Vector2i(WOMEN.position.x + 2, CORRIDOR.end.y),
	}
	Common.set_open(g, doors.corridor.x, doors.corridor.y, corridor)
	for t in doors.kitchen:
		Common.set_open(g, t.x, t.y, kitchen)
	Common.set_open(g, doors.men.x, doors.men.y, restroom)
	Common.set_open(g, doors.women.x, doors.women.y, restroom)
	# The fixed furniture first, so an entrance never opens onto the stove or the bar.
	var counter := Rect2i(BAR.position.x, BAR.position.y, 1, BAR.size.y)
	_block(g, counter)
	_block(g, Rect2i(BAR.end.x - 1, BAR.position.y, 1, BAR.size.y))
	var host := Vector2i(FRONT_DOOR.x + 1, FRONT_DOOR.y + 3)
	_block(g, Rect2i(host, Vector2i.ONE))
	# Kitchen: counters on the north and east walls, the stove on the south wall, an island.
	var counters: Array = []
	for x in range(KITCHEN.position.x + 1, KITCHEN.end.x - 1):
		if absi(x - doors.kitchen[0].x) <= 1 or x == doors.kitchen[1].x:
			continue
		counters.append({"tile": Vector2i(x, KITCHEN.position.y), "wall": Vector2i(0, -1)})
	for y in range(KITCHEN.position.y + 2, KITCHEN.end.y - 2):
		counters.append({"tile": Vector2i(KITCHEN.end.x - 1, y), "wall": Vector2i(1, 0)})
	for c in counters:
		_block(g, Rect2i(c.tile, Vector2i.ONE))
	var stove := Rect2i(KITCHEN.position.x + 8, KITCHEN.end.y - 1, 3, 1)
	_block(g, stove)
	var island := Rect2i(KITCHEN.position.x + 5, KITCHEN.position.y + 3, 7, 1)
	_block(g, island)
	var fridge := Vector2i(KITCHEN.end.x - 1, KITCHEN.end.y - 1)
	_block(g, Rect2i(fridge, Vector2i.ONE))
	var sink := Vector2i(KITCHEN.position.x + 2, KITCHEN.end.y - 1)
	_block(g, Rect2i(sink, Vector2i.ONE))
	var containers := [
		{"tile": Vector2i(FRONT_DOOR.x - 3, FRONT_DOOR.y + 1), "wall": Vector2i(0, -1), "type": "station_drawers"},
		{"tile": Vector2i(BAR.end.x - 1, BAR.position.y + 4), "wall": Vector2i(1, 0), "type": "med_fridge"},
		{"tile": Vector2i(KITCHEN.position.x + 4, KITCHEN.position.y), "wall": Vector2i(0, -1), "type": "drawer_unit"},
		{"tile": Vector2i(KITCHEN.end.x - 1, KITCHEN.position.y + 3), "wall": Vector2i(1, 0), "type": "drawer_unit"},
		{"tile": Vector2i(KITCHEN.position.x, KITCHEN.position.y + 4), "wall": Vector2i(-1, 0), "type": "pegboard"},
		{"tile": Vector2i(CORRIDOR.end.x - 1, CORRIDOR.position.y), "wall": Vector2i(1, 0), "type": "trauma_bag"},
	]
	for c in containers:
		if c.type != "trauma_bag" and c.type != "pegboard":
			_block(g, Rect2i(c.tile, Vector2i.ONE))
		Common.reserve(g, Rect2i(c.tile, Vector2i.ONE))
	var stalls := [Rect2i(MEN.position.x, MEN.end.y - 1, 2, 1), Rect2i(WOMEN.position.x + 3, WOMEN.end.y - 1, 2, 1)]
	for s: Rect2i in stalls:
		_block(g, s)
	# The bar and the front door keep their walls; entrances go elsewhere.
	Common.reserve(g, BAR.grow(1))
	Common.reserve(g, Rect2i(FRONT_DOOR.x - 3, FRONT_DOOR.y, 8, 5))
	Common.reserve(g, Rect2i(doors.kitchen[0].x - 2, DINING.end.y - 3, 6, 4))
	Common.reserve(g, Rect2i(doors.corridor.x - 1, DINING.end.y - 3, 4, 4))
	var walls := [
		{"from": Vector2i(M, M + 3), "dir": Vector2i(0, 1), "len": 12, "ev": Vector2i(-1, 0)},
		{"from": Vector2i(M + 3, M), "dir": Vector2i(1, 0), "len": W - 4, "ev": Vector2i(0, -1)},
		{"from": Vector2i(INTERIOR.end.x, M + 3), "dir": Vector2i(0, 1), "len": 12, "ev": Vector2i(1, 0)},
		{"from": Vector2i(KITCHEN.position.x + 2, INTERIOR.end.y), "dir": Vector2i(1, 0), "len": KITCHEN.size.x - 4, "ev": Vector2i(0, 1)},
	]
	var ports := Common.place_ports(g, stubs, walls, rng)

	# Tables for four in a grid down the middle, booths along the walls where no entrance opens.
	var tables: Array = []
	for ty in range(DINING.position.y + 4, DINING.end.y - 3, 4):
		for tx in range(DINING.position.x + 5, BAR.position.x - 2, 4):
			var t := Vector2i(tx, ty)
			if _free(g, Rect2i(t, Vector2i.ONE).grow(1)):
				tables.append({"tile": t, "yaw": 0.0 if rng.randf() < 0.8 else PI * 0.25})
				_block(g, Rect2i(t, Vector2i.ONE))
	var booths: Array = []
	# West wall: benches along y, the table against the wall.
	for y in range(DINING.position.y + 1, DINING.end.y - 2, 3):
		var r := Rect2i(DINING.position.x, y, 1, 2)
		if _free(g, r.grow(1).intersection(Rect2i(DINING.position.x, DINING.position.y, DINING.size.x, DINING.size.y))):
			booths.append({"rect": r, "wall": Vector2i(-1, 0)})
			_block(g, r)
	# South wall (the back of the dining room).
	for x in range(DINING.position.x + 4, BAR.position.x - 1, 3):
		var r := Rect2i(x, DINING.end.y - 1, 2, 1)
		if _free(g, r.grow(1).intersection(DINING)):
			booths.append({"rect": r, "wall": Vector2i(0, 1)})
			_block(g, r)
	var spawns := [Vector2i(DINING.position.x + 3, DINING.position.y + 2), Vector2i(KITCHEN.get_center().x, KITCHEN.position.y + 2),
			Vector2i(DINING.end.x - 8, DINING.end.y - 3)]
	var lamps: Array = []
	for ly in [DINING.position.y + 3, DINING.position.y + 8, DINING.position.y + 13]:
		for lx in range(DINING.position.x + 4, BAR.position.x, 7):
			lamps.append(Vector2i(lx, ly))
	return {"kind": "restaurant", "size": Vector2i(g.w, g.h), "grid": g, "rows": Common.rows(g), "ports": ports,
			"tables": tables, "booths": booths, "counter": counter, "host": host, "counters": counters,
			"stove": stove, "island": island, "fridge": fridge, "sink": sink, "containers": containers,
			"stalls": stalls, "spawns": spawns, "lamps": lamps, "doors": doors,
			"spawn": Vector2i(DINING.get_center().x, DINING.get_center().y)}


static func _free(g: Dictionary, r: Rect2i) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if not Common.is_open(g, x, y):
				return false
			var i := Common.idx(g, x, y)
			if g.reserved[i] == 1 or g.nav[i] == 1 or g.stub[i] == 1 or g.room[i] != 0:
				return false
	return true


static func _block(g: Dictionary, r: Rect2i) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if Common.inb(g, x, y):
				g.nav[Common.idx(g, x, y)] = 1


# =========================================================================
# build
# =========================================================================

## Data only (a worker thread): the grid's surfaces as mesh arrays and the navigation faces.
static func prepare(lay: Dictionary, origin: Vector2i) -> Dictionary:
	var geo := Common.Geo.new()
	var nav := PackedVector3Array()
	Common.build_surfaces(lay.grid, origin, geo, nav)
	geo.bake()
	return {"geo": geo, "nav_faces": nav}


## Everything at once (warmup, tools): the interior's root node.
static func build(lay: Dictionary, origin: Vector2i, out: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Restaurant"
	var prep := prepare(lay, origin)
	out.nav_faces.append_array(prep.nav_faces)
	Common.run_steps(build_steps(lay, origin, out, root, prep))
	return root


## The interior's nodes as small steps under `root` (see Common.run_steps).
static func build_steps(lay: Dictionary, origin: Vector2i, out: Dictionary, root: Node3D, prep: Dictionary) -> Array:
	var ow := Vector3(origin.x * T, 0.0, origin.y * T)
	var world := func(t: Vector2, y := 0.0) -> Vector3:
		return ow + Vector3(t.x * T, y, t.y * T)
	var ctx := {}
	var steps: Array = []
	var geo: Common.Geo = prep.geo
	var props := Common.Props.new()
	var wood := Common.mat("rest_wood", Color(0.60, 0.40, 0.23), 0.55)
	var dark_wood := Common.mat("rest_dark_wood", Color(0.20, 0.12, 0.07), 0.6)
	var iron := Common.mat("rest_iron", Color(0.06, 0.06, 0.06), 0.5, 0.7)
	var steel := Common.tri_mat("rest_steel", "mat/metal", Color(0.62, 0.64, 0.66), 1.2, 0.35, 0.9)

	steps.append(func():
		geo.mats["saltillo"] = _tex_mat("saltillo", _saltillo_tex(), 0.8, Vector3(0.5, 0.5, 1))
		geo.mats["planks"] = _tex_mat("planks", _planks_tex(), 0.9, Vector3(0.35, 0.35, 1))
		geo.mats["stucco"] = Common.tri_mat("rest_stucco", "mat/wall", Color(1.0, 0.74, 0.52), 0.35, 0.95)
		geo.mats["talavera"] = _tex_mat("talavera", _talavera_tex(), 0.35, Vector3(0.85, 0.85, 1))
		geo.mats["wood_low"] = _tex_mat("wood_low", _planks_tex(), 0.85, Vector3(0.6, 0.3, 1))
		geo.mats["kitchen_floor"] = Common.tri_mat("rest_kfloor", "mat/tile_floor", Color(0.62, 0.60, 0.56), 0.6, 0.6)
		geo.mats["kitchen_ceiling"] = Common.HB.surface_mat("mat/ceiling", Color(0.30, 0.31, 0.31), 0.95)
		geo.mats["kitchen_wall"] = Common.tri_mat("rest_kwall", "mat/wall_tile", Color(0.86, 0.88, 0.86), 0.5, 0.45)
		geo.mats["restroom_floor"] = Common.tri_mat("rest_rfloor", "mat/tile_floor", Color(0.55, 0.62, 0.66), 0.6, 0.55)
		geo.mats["restroom_wall"] = Common.tri_mat("rest_rwall", "mat/wall_tile", Color(0.50, 0.70, 0.74), 0.5, 0.4)
		return geo.commit_steps(root, ctx))
	steps.append(func():
		var body: StaticBody3D = ctx.body
		var inter := Rect2(Vector2(INTERIOR.position) * T + Vector2(ow.x, ow.z), Vector2(INTERIOR.size) * T)
		Common.collider(body, Transform3D(Basis(), Vector3(inter.get_center().x, -0.2, inter.get_center().y)), Vector3(inter.size.x, 0.4, inter.size.y))
		Common.collider(body, Transform3D(Basis(), Vector3(inter.get_center().x, DINING_CEIL + 0.2, inter.get_center().y)), Vector3(inter.size.x, 0.4, inter.size.y))
		_beams(props, world, dark_wood))
	steps.append(func(): _tables(props, ctx.body, lay, world, wood, out))
	steps.append(func(): _booths(props, ctx.body, lay, world, wood, out))
	steps.append(func(): _bar(root, props, ctx.body, lay, world, wood, dark_wood, out))
	steps.append(func(): _front(root, props, ctx.body, lay, world, dark_wood, iron, out))
	steps.append(func(): _kitchen(root, props, ctx.body, lay, world, steel, iron, out))
	steps.append(func(): _restrooms(root, props, ctx.body, lay, world, out))
	steps.append(func(): _decor(root, props, lay, world, dark_wood))
	steps.append(func(): _lights(root, lay, world, out))

	var cts := Node3D.new()
	cts.name = "Containers"
	steps.append(func(): root.add_child(cts))
	for c in lay.containers:
		steps.append(func():
			var t: Vector2i = c.tile
			var room := "restaurant_kitchen" if KITCHEN.has_point(t) else "restaurant"
			Common.container(cts, out, origin, t, c.wall, c.type, room))
	steps.append(func():
		for s: Vector2i in lay.spawns:
			out.monster_spawns.append(world.call(Vector2(s) + Vector2(0.5, 0.5)))
		out["spawn"] = world.call(Vector2(lay.spawn) + Vector2(0.5, 0.5))
		return props.commit_steps(root))
	return steps


## The doorways as door plan entries in world tiles: the swing doors into the kitchen (a pair), the
## door to the back corridor, and the two restrooms'. All hang at the side you come from.
static func door_entries(lay: Dictionary, origin: Vector2i) -> Array:
	var d: Dictionary = lay.doors
	return [
		Common.door_entry(origin, d.kitchen, Vector2i(0, -1), "double", 90.0),
		Common.door_entry(origin, [d.corridor], Vector2i(0, -1), "hinged", 90.0),
		Common.door_entry(origin, [d.men], Vector2i(0, -1), "hinged", 90.0),
		Common.door_entry(origin, [d.women], Vector2i(0, -1), "hinged", 90.0),
	]




# ---- materials and textures -----------------------------------------------

static func _tex_mat(key: String, tex: Texture2D, rough: float, scale: Vector3, triplanar := false) -> Material:
	var ck := "rest_" + key
	if Common._mat_cache.has(ck):
		return Common._mat_cache[ck]
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = rough
	m.uv1_scale = scale
	if triplanar:
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_triplanar_sharpness = 4.0
	Common._mat_cache[ck] = m
	return m


## Terracotta floor tiles: 4 x 4 squares a texture, each its own shade, grey grout.
static func _saltillo_tex() -> Texture2D:
	return Common.cached_texture("saltillo", func():
		var n := 128
		var img := Image.create(n, n, true, Image.FORMAT_RGB8)
		var rng := RandomNumberGenerator.new()
		rng.seed = 91
		var shades := []
		for i in 16:
			shades.append(Color(0.56, 0.36, 0.26).lerp(Color(0.66, 0.46, 0.34), rng.randf()).darkened(rng.randf() * 0.12))
		for y in n:
			for x in n:
				var cx := x * 4 / n
				var cy := y * 4 / n
				var lx := (x * 4) % n
				var ly := (y * 4) % n
				var grout := lx < 5 or ly < 5
				var c: Color = Color(0.55, 0.52, 0.47) if grout else (shades[cy * 4 + cx] as Color)
				var speck := sin(float(x * 12.9898 + y * 78.233)) * 43758.5453
				c = c.darkened((speck - floor(speck)) * 0.07)
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img))


## Blue, yellow and white painted tiles for the wainscot.
static func _talavera_tex() -> Texture2D:
	return Common.cached_texture("talavera", func():
		var n := 128
		var img := Image.create(n, n, true, Image.FORMAT_RGB8)
		var white := Color(0.90, 0.88, 0.80)
		var blue := Color(0.10, 0.22, 0.52)
		var yellow := Color(0.86, 0.62, 0.12)
		for y in n:
			for x in n:
				var tx := (x % 64) - 32
				var ty := (y % 64) - 32
				var r := sqrt(float(tx * tx + ty * ty))
				var c := white
				if absi(tx) >= 30 or absi(ty) >= 30:
					c = Color(0.55, 0.52, 0.46)
				elif r < 8.0:
					c = yellow
				elif r < 12.0:
					c = blue
				elif absi(absi(tx) - absi(ty)) < 3 and r < 26.0:
					c = blue
				elif r > 20.0 and r < 23.0:
					c = yellow
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img))


static func _planks_tex(light := false) -> Texture2D:
	return Common.cached_texture("planks_light" if light else "planks", func():
		var n := 128
		var img := Image.create(n, n, true, Image.FORMAT_RGB8)
		var rng := RandomNumberGenerator.new()
		rng.seed = 17
		var tones := []
		for i in 8:
			if light:
				tones.append(Color(0.62, 0.42, 0.24).lerp(Color(0.78, 0.56, 0.34), rng.randf()))
			else:
				tones.append(Color(0.34, 0.20, 0.11).lerp(Color(0.48, 0.30, 0.16), rng.randf()))
		for y in n:
			for x in n:
				var plank := y * 8 / n
				var gap := (y * 8) % n < 4
				var grain := 0.5 + 0.5 * sin(float(x) * 0.21 + float(plank) * 3.0 + sin(float(x) * 0.05) * 3.0)
				var c: Color = Color(0.12, 0.07, 0.04) if gap else (tones[plank] as Color).darkened(grain * 0.18)
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img))


# ---- furniture --------------------------------------------------------------

static func _beams(props: Common.Props, world: Callable, dark_wood: Material) -> void:
	var beam := Common.cached_mesh("rest_beam", func():
		var mb := Common.MeshBuilder.new()
		mb.box("w", dark_wood, Transform3D(), Vector3(0.3, 0.3, 1.0))
		return mb.commit())
	var len_z := DINING.size.y * T
	for x in range(DINING.position.x + 2, DINING.end.x, 3):
		var p: Vector3 = world.call(Vector2(x, DINING.position.y), DINING_CEIL - 0.15)
		props.add(beam, Transform3D(Basis().scaled(Vector3(1, 1, len_z)), p + Vector3(0, 0, len_z * 0.5)), 0.0, false)


static func _chair_mesh(col: Color, key: String) -> Mesh:
	return Common.cached_mesh("rest_chair_" + key, func():
		var mb := Common.MeshBuilder.new()
		var paint := Common.mat("rest_chair_paint_" + key, col, 0.6)
		var seat := Common.mat("rest_chair_seat", Color(0.62, 0.48, 0.28), 0.9)
		mb.box("s", seat, Transform3D(Basis(), Vector3(0, 0.46, 0)), Vector3(0.44, 0.05, 0.42))
		for lx in [-0.19, 0.19]:
			for lz in [-0.18, 0.18]:
				mb.box("p", paint, Transform3D(Basis(), Vector3(lx, 0.23, lz)), Vector3(0.04, 0.46, 0.04))
		for lx in [-0.19, 0.19]:
			mb.box("p", paint, Transform3D(Basis(), Vector3(lx, 0.75, 0.19)), Vector3(0.045, 0.6, 0.045))
		for yy in [0.72, 0.9]:
			mb.box("p", paint, Transform3D(Basis(), Vector3(0, yy, 0.19)), Vector3(0.4, 0.07, 0.03))
		return mb.commit())


static func _setting_mesh() -> Mesh:
	## One place setting: plate, folded napkin with cutlery, a glass. Origin at the table top, the
	## diner sits toward +Z.
	return Common.cached_mesh("rest_setting", func():
		var mb := Common.MeshBuilder.new()
		var plate := Common.mat("rest_plate", Color(0.92, 0.90, 0.84), 0.35)
		var rim := Common.mat("rest_plate_rim", Color(0.14, 0.30, 0.58), 0.4)
		var napkin := Common.mat("rest_napkin", Color(0.66, 0.12, 0.10), 0.95)
		var silver := Common.mat("rest_silver", Color(0.75, 0.76, 0.78), 0.25, 0.9)
		var glass := Common.mat("rest_glass", Color(0.55, 0.70, 0.66), 0.08, 0.3)
		mb.cylinder("r", rim, Transform3D(Basis(), Vector3(0, 0.006, 0)), 0.135, 0.012, 18)
		mb.cylinder("p", plate, Transform3D(Basis(), Vector3(0, 0.014, 0)), 0.115, 0.006, 18)
		mb.box("n", napkin, Transform3D(Basis(), Vector3(0.19, 0.008, 0)), Vector3(0.1, 0.016, 0.2))
		mb.box("s", silver, Transform3D(Basis(), Vector3(0.175, 0.02, 0)), Vector3(0.012, 0.006, 0.19))
		mb.box("s", silver, Transform3D(Basis(), Vector3(0.205, 0.02, 0)), Vector3(0.014, 0.006, 0.2))
		mb.cylinder("g", glass, Transform3D(Basis(), Vector3(-0.16, 0.06, -0.1)), 0.035, 0.12, 10, 0.04)
		return mb.commit())


static func _centre_mesh() -> Mesh:
	## Salsa, a basket of chips, salt and pepper and a candle in red glass.
	return Common.cached_mesh("rest_centre", func():
		var mb := Common.MeshBuilder.new()
		var salsa := Common.mat("rest_salsa", Color(0.55, 0.08, 0.04), 0.4)
		var bowl := Common.mat("rest_bowl", Color(0.20, 0.36, 0.62), 0.4)
		var chips := Common.mat("rest_chips", Color(0.86, 0.66, 0.26), 0.9)
		var basket := Common.mat("rest_basket", Color(0.45, 0.30, 0.14), 0.95)
		var candle := Common.mat("rest_candle", Color(0.7, 0.08, 0.06), 0.2, 0.0, Color(1.0, 0.45, 0.15), 0.9)
		mb.cylinder("b", bowl, Transform3D(Basis(), Vector3(-0.1, 0.03, 0.02)), 0.07, 0.06, 12, 0.08)
		mb.cylinder("s", salsa, Transform3D(Basis(), Vector3(-0.1, 0.062, 0.02)), 0.066, 0.004, 12)
		mb.cylinder("k", basket, Transform3D(Basis(), Vector3(0.1, 0.035, -0.02)), 0.11, 0.07, 12, 0.13)
		mb.cylinder("c", chips, Transform3D(Basis(), Vector3(0.1, 0.075, -0.02)), 0.11, 0.03, 10, 0.06)
		mb.cylinder("x", candle, Transform3D(Basis(), Vector3(0.0, 0.05, 0.14)), 0.03, 0.1, 10)
		mb.cylinder("p", Common.mat("rest_shaker", Color(0.9, 0.9, 0.88), 0.2), Transform3D(Basis(), Vector3(-0.02, 0.04, -0.15)), 0.016, 0.08, 8)
		mb.cylinder("q", Common.mat("rest_shaker_d", Color(0.15, 0.12, 0.1), 0.2), Transform3D(Basis(), Vector3(0.03, 0.04, -0.15)), 0.016, 0.08, 8)
		return mb.commit())


static func _tables(props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, wood: Material, out: Dictionary) -> void:
	var table := Common.cached_mesh("rest_table4", func():
		var mb := Common.MeshBuilder.new()
		var cloth := Common.mat("rest_runner", Color(0.10, 0.45, 0.42), 0.9)
		mb.box("w", wood, Transform3D(Basis(), Vector3(0, 0.73, 0)), Vector3(1.0, 0.05, 1.0))
		mb.box("c", cloth, Transform3D(Basis(), Vector3(0, 0.757, 0)), Vector3(0.3, 0.004, 1.02))
		mb.cylinder("w", wood, Transform3D(Basis(), Vector3(0, 0.36, 0)), 0.06, 0.7, 10)
		mb.box("w", wood, Transform3D(Basis(), Vector3(0, 0.02, 0)), Vector3(0.6, 0.04, 0.6))
		return mb.commit())
	var colours := [[Color(0.66, 0.14, 0.10), "red"], [Color(0.12, 0.34, 0.60), "blue"], [Color(0.80, 0.58, 0.10), "yellow"], [Color(0.16, 0.46, 0.26), "green"]]
	var setting := _setting_mesh()
	var centre := _centre_mesh()
	for i in lay.tables.size():
		var e: Dictionary = lay.tables[i]
		var p: Vector3 = world.call(Vector2(e.tile) + Vector2(0.5, 0.5))
		var b := Basis(Vector3.UP, float(e.yaw))
		props.add(table, Transform3D(b, p), 40.0)
		props.add(centre, Transform3D(b, p + Vector3(0, 0.755, 0)), 22.0, false)
		for k in 4:
			var yaw := float(e.yaw) + k * PI * 0.5
			var sb := Basis(Vector3.UP, yaw)
			var col: Array = colours[(i + k) % colours.size()]
			props.add(_chair_mesh(col[0], col[1]), Transform3D(sb, p + sb * Vector3(0, 0, 0.72)), 40.0)
			props.add(setting, Transform3D(sb, p + Vector3(0, 0.755, 0) + sb * Vector3(0, 0, 0.3)), 18.0, false)
		Common.collider(body, Transform3D(b, p + Vector3(0, 0.38, 0)), Vector3(0.95, 0.76, 0.95))
		Common.anchor(out, p + b * Vector3(0.3, 0.76, -0.3), float(e.yaw), "counter", "restaurant")


static func _booths(props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, wood: Material, out: Dictionary) -> void:
	var vinyl := Common.mat("rest_vinyl", Color(0.50, 0.08, 0.08), 0.45)
	var booth := Common.cached_mesh("rest_booth", func():
		# Along local X (3 m): bench, table against the wall (-Z), bench. The diners face each other.
		var mb := Common.MeshBuilder.new()
		for sx in [-1.12, 1.12]:
			var inward := -signf(sx)
			mb.box("w", wood, Transform3D(Basis(), Vector3(sx, 0.22, 0)), Vector3(0.62, 0.44, 1.3))
			mb.box("v", vinyl, Transform3D(Basis(), Vector3(sx + inward * 0.03, 0.48, 0)), Vector3(0.56, 0.1, 1.25))
			mb.box("w", wood, Transform3D(Basis(), Vector3(sx - inward * 0.27, 0.8, 0)), Vector3(0.08, 1.6, 1.3))
			mb.box("v", vinyl, Transform3D(Basis(), Vector3(sx - inward * 0.2, 0.85, 0)), Vector3(0.08, 0.7, 1.2))
		mb.box("w", wood, Transform3D(Basis(), Vector3(0, 0.74, -0.05)), Vector3(1.3, 0.05, 1.1))
		mb.box("w", wood, Transform3D(Basis(), Vector3(0, 0.36, -0.2)), Vector3(0.12, 0.72, 0.12))
		return mb.commit())
	var setting := _setting_mesh()
	var centre := _centre_mesh()
	for e in lay.booths:
		var r: Rect2i = e.rect
		var wall: Vector2i = e.wall
		var c: Vector3 = world.call(Vector2(r.position) + Vector2(r.size) * 0.5)
		# Local -Z toward the wall.
		var yaw := atan2(float(wall.x), float(wall.y)) + PI
		var b := Basis(Vector3.UP, yaw)
		var p := c + Vector3(wall.x, 0, wall.y) * (T * 0.5 - 0.62)
		props.add(booth, Transform3D(b, p), 40.0)
		props.add(centre, Transform3D(b, p + b * Vector3(0, 0.765, -0.35)), 22.0, false)
		for sx in [-0.42, 0.42]:
			var sb := Basis(Vector3.UP, yaw + (PI * 0.5 if sx < 0.0 else -PI * 0.5))
			props.add(setting, Transform3D(sb, p + Vector3(0, 0.765, 0) + b * Vector3(sx, 0, 0.05)), 18.0, false)
		# Two benches and the table between them (an item set on the table rests on it).
		for sx in [-1.12, 1.12]:
			Common.collider(body, Transform3D(b, p + b * Vector3(sx, 0.8, 0.0)), Vector3(0.62, 1.6, 1.3))
		Common.collider(body, Transform3D(b, p + b * Vector3(0.0, 0.38, -0.05)), Vector3(1.3, 0.76, 1.1))
		Common.anchor(out, p + b * Vector3(0.0, 0.77, 0.25), yaw, "counter", "restaurant")


static func _bar(root: Node3D, props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, wood: Material, dark_wood: Material, out: Dictionary) -> void:
	var mb := Common.MeshBuilder.new()
	var talavera: Material = Common._mat_cache.get("rest_talavera")
	var brass := Common.mat("rest_brass", Color(0.72, 0.52, 0.22), 0.3, 0.9)
	var counter: Rect2i = lay.counter
	var a: Vector3 = world.call(Vector2(counter.position))
	var len_z := counter.size.y * T
	var cx := a.x + T * 0.5
	var mid_z := a.z + len_z * 0.5
	mb.box("t", talavera, Transform3D(Basis(), Vector3(cx - 0.05, 0.52, mid_z)), Vector3(0.6, 1.04, len_z))
	mb.box("w", dark_wood, Transform3D(Basis(), Vector3(cx, 1.08, mid_z)), Vector3(0.85, 0.07, len_z + 0.1))
	mb.box("b", brass, Transform3D(Basis(), Vector3(cx - 0.52, 0.22, mid_z)), Vector3(0.05, 0.05, len_z))
	Common.collider(body, Transform3D(Basis(), Vector3(cx, 0.55, mid_z)), Vector3(0.85, 1.1, len_z))
	for k in counter.size.y:
		Common.anchor(out, Vector3(cx + 0.1, 1.115, a.z + (k + 0.5) * T), 0.0, "counter", "restaurant")
	# Stools on the dining side.
	var stool := Common.cached_mesh("rest_stool", func():
		var sm := Common.MeshBuilder.new()
		sm.cylinder("v", Common.mat("rest_vinyl", Color(0.50, 0.08, 0.08), 0.45), Transform3D(Basis(), Vector3(0, 0.76, 0)), 0.2, 0.08, 14)
		sm.cylinder("b", Common.mat("rest_brass", Color(0.72, 0.52, 0.22), 0.3, 0.9), Transform3D(Basis(), Vector3(0, 0.38, 0)), 0.03, 0.72, 8)
		sm.cylinder("b", Common.mat("rest_brass", Color(0.72, 0.52, 0.22), 0.3, 0.9), Transform3D(Basis(), Vector3(0, 0.02, 0)), 0.2, 0.04, 14)
		return sm.commit())
	for k in counter.size.y:
		props.add(stool, Transform3D(Basis(), Vector3(cx - 1.05, 0, a.z + (k + 0.5) * T)), 36.0)
	# The back bar: shelves of bottles in front of a dark mirror.
	var back: Vector3 = world.call(Vector2(BAR.end.x, counter.position.y))
	var bx := back.x - 0.3
	mb.box("w", dark_wood, Transform3D(Basis(), Vector3(bx, 0.5, mid_z)), Vector3(0.6, 1.0, len_z))
	mb.box("w", dark_wood, Transform3D(Basis(), Vector3(bx, 1.02, mid_z)), Vector3(0.65, 0.05, len_z))
	mb.box("m", Common.mat("rest_mirror", Color(0.08, 0.09, 0.1), 0.05, 1.0), Transform3D(Basis(), Vector3(back.x - 0.02, 1.9, mid_z)), Vector3(0.02, 1.4, len_z - 1.0))
	for yy in [1.45, 1.95, 2.45]:
		mb.box("w", dark_wood, Transform3D(Basis(), Vector3(bx + 0.1, yy, mid_z)), Vector3(0.35, 0.04, len_z - 0.8))
	Common.collider(body, Transform3D(Basis(), Vector3(bx, 1.4, mid_z)), Vector3(0.6, 2.8, len_z))
	var bottle_cols := [Color(0.10, 0.30, 0.12), Color(0.45, 0.22, 0.05), Color(0.75, 0.78, 0.72), Color(0.30, 0.08, 0.06)]
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	for yy in [1.45, 1.95, 2.45]:
		var z := a.z + 0.7
		while z < a.z + len_z - 0.7:
			var ci := rng.randi_range(0, bottle_cols.size() - 1)
			var bottle := Common.cached_mesh("rest_bottle_%d" % ci, func():
				var bm := Common.MeshBuilder.new()
				var gm := Common.mat("rest_bottle_%d" % ci, bottle_cols[ci], 0.1, 0.2)
				bm.cylinder("g", gm, Transform3D(Basis(), Vector3(0, 0.12, 0)), 0.04, 0.24, 8)
				bm.cylinder("g", gm, Transform3D(Basis(), Vector3(0, 0.29, 0)), 0.014, 0.1, 6, 0.012)
				return bm.commit())
			props.add(bottle, Transform3D(Basis().scaled(Vector3.ONE * rng.randf_range(0.85, 1.15)), Vector3(bx + 0.1, yy + 0.02, z)), 26.0, false)
			z += rng.randf_range(0.11, 0.18)
	var mi := MeshInstance3D.new()
	mi.name = "Bar"
	mi.mesh = mb.commit()
	root.add_child(mi)
	# The menu board over the bar.
	var sign := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(3.4, 0.7)
	sign.mesh = qm
	var sm := StandardMaterial3D.new()
	var tex := Common.text_texture("CANTINA  *  COCINA", Color(0.98, 0.86, 0.5), Color(0.08, 0.05, 0.04), 512, 104)
	sm.albedo_texture = tex
	sm.emission_enabled = true
	sm.emission_texture = tex
	sm.emission = Color(1.0, 0.7, 0.4)
	sm.emission_energy_multiplier = 0.8
	sign.material_override = sm
	sign.position = Vector3(back.x - 0.05, 2.95, mid_z)
	sign.rotation.y = -PI * 0.5
	root.add_child(sign)


static func _front(root: Node3D, props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, dark_wood: Material, iron: Material, out: Dictionary) -> void:
	var mb := Common.MeshBuilder.new()
	# Locked double doors in the north wall, on the wall face.
	var d: Vector3 = world.call(Vector2(FRONT_DOOR.x + 1, FRONT_DOOR.y + 1))
	for sx in [-0.72, 0.72]:
		mb.box("w", dark_wood, Transform3D(Basis(), d + Vector3(sx, 1.2, 0.04)), Vector3(1.4, 2.4, 0.08))
		for yy in [0.5, 1.2, 1.9]:
			mb.box("w", dark_wood, Transform3D(Basis(), d + Vector3(sx, yy, 0.09)), Vector3(1.1, 0.5, 0.03))
		mb.box("i", iron, Transform3D(Basis(), d + Vector3(sx * 0.12, 1.1, 0.12)), Vector3(0.04, 0.5, 0.04))
	mb.box("w", dark_wood, Transform3D(Basis(), d + Vector3(0, 2.5, 0.05)), Vector3(3.1, 0.2, 0.12))
	# The host stand, with menus and a little lamp.
	var h: Vector3 = world.call(Vector2(lay.host) + Vector2(0.5, 0.5))
	mb.box("w", dark_wood, Transform3D(Basis(), h + Vector3(0, 0.55, 0)), Vector3(0.8, 1.1, 0.5))
	mb.box("w", dark_wood, Transform3D(Basis(Vector3.RIGHT, -0.25), h + Vector3(0, 1.14, 0.02)), Vector3(0.85, 0.05, 0.55))
	var menu := Common.mat("rest_menu", Color(0.45, 0.10, 0.08), 0.8)
	for k in 5:
		mb.box("m", menu, Transform3D(Basis(Vector3.UP, k * 0.05), h + Vector3(-0.2, 1.19 + k * 0.012, 0.05)), Vector3(0.24, 0.01, 0.34))
	Common.collider(body, Transform3D(Basis(), h + Vector3(0, 0.6, 0)), Vector3(0.8, 1.2, 0.5))
	Common.anchor(out, h + Vector3(0.22, 1.2, 0.02), 0.0, "counter", "restaurant")
	var mi := MeshInstance3D.new()
	mi.name = "Front"
	mi.mesh = mb.commit()
	root.add_child(mi)
	# "Please wait to be seated", facing the room.
	var sign := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.9, 0.36)
	sign.mesh = qm
	var sm := StandardMaterial3D.new()
	sm.albedo_texture = Common.text_texture("PLEASE WAIT TO BE SEATED", Color(0.95, 0.92, 0.82), Color(0.30, 0.06, 0.05), 384, 96)
	sm.roughness = 0.8
	sign.material_override = sm
	sign.position = h + Vector3(1.0, 1.25, 0.2)
	root.add_child(sign)
	var post := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.02
	cm.height = 1.1
	post.mesh = cm
	post.material_override = iron
	post.position = h + Vector3(1.0, 0.55, 0.18)
	root.add_child(post)
	# OPEN, glowing over the doors.
	var neon := MeshInstance3D.new()
	var nq := QuadMesh.new()
	nq.size = Vector2(0.9, 0.3)
	neon.mesh = nq
	var nm := StandardMaterial3D.new()
	var ntex := Common.text_texture("ABIERTO", Color(1.0, 0.25, 0.2), Color(0.02, 0.0, 0.0), 256, 80)
	nm.albedo_texture = ntex
	nm.emission_enabled = true
	nm.emission_texture = ntex
	nm.emission = Color(1.0, 0.3, 0.25)
	nm.emission_energy_multiplier = 2.2
	nm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	neon.material_override = nm
	neon.position = d + Vector3(0, 2.95, 0.06)
	root.add_child(neon)


static func _kitchen(root: Node3D, props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, steel: Material, iron: Material, out: Dictionary) -> void:
	var mb := Common.MeshBuilder.new()
	var dark := Common.mat("rest_kdark", Color(0.08, 0.08, 0.09), 0.5, 0.5)
	var taken := {}
	for ct in lay.containers:
		taken[ct.tile] = true
	for c in lay.counters:
		var t: Vector2i = c.tile
		if taken.has(t):
			continue   # a steel drawer unit stands there instead
		var wall: Vector2i = c.wall
		var p: Vector3 = world.call(Vector2(t) + Vector2(0.5, 0.5))
		var off := Vector3(wall.x, 0, wall.y) * (T * 0.5 - 0.35)
		var size := Vector3(T if wall.x == 0 else 0.7, 0.92, 0.7 if wall.x == 0 else T)
		mb.box("s", steel, Transform3D(Basis(), p + off + Vector3(0, 0.46, 0)), size)
		Common.collider(body, Transform3D(Basis(), p + off + Vector3(0, 0.46, 0)), size)
		Common.anchor(out, p + off + Vector3(0, 0.925, 0), atan2(float(wall.x), float(wall.y)), "counter", "restaurant_kitchen")
	# Stove and hood.
	var st: Rect2i = lay.stove
	var sa: Vector3 = world.call(Vector2(st.position) + Vector2(0, 0.5))
	var sw := st.size.x * T
	var sc := sa + Vector3(sw * 0.5, 0, T * 0.5 - 0.45)
	mb.box("s", steel, Transform3D(Basis(), sc + Vector3(0, 0.45, 0)), Vector3(sw, 0.9, 0.9))
	mb.box("d", dark, Transform3D(Basis(), sc + Vector3(0, 0.91, 0)), Vector3(sw - 0.1, 0.02, 0.8))
	for k in 6:
		mb.cylinder("i", iron, Transform3D(Basis(), sc + Vector3(-sw * 0.5 + 0.45 + k * (sw - 0.9) / 5.0, 0.93, 0.0)), 0.13, 0.02, 10)
	mb.box("s", steel, Transform3D(Basis(), sc + Vector3(0, 2.3, 0.1)), Vector3(sw + 0.2, 0.5, 1.0))
	Common.collider(body, Transform3D(Basis(), sc + Vector3(0, 0.46, 0)), Vector3(sw, 0.92, 0.9))
	# Pots waiting on the burners.
	for k in 2:
		mb.cylinder("s", steel, Transform3D(Basis(), sc + Vector3(-0.8 + k * 1.6, 1.08, 0.0)), 0.2, 0.28, 12)
	# Island.
	var il: Rect2i = lay.island
	var ia: Vector3 = world.call(Vector2(il.position) + Vector2(0, 0.5))
	var ic := ia + Vector3(il.size.x * T * 0.5, 0, 0)
	mb.box("s", steel, Transform3D(Basis(), ic + Vector3(0, 0.46, 0)), Vector3(il.size.x * T - 0.2, 0.92, 0.9))
	Common.collider(body, Transform3D(Basis(), ic + Vector3(0, 0.46, 0)), Vector3(il.size.x * T - 0.2, 0.92, 0.9))
	var board := Common.mat("rest_board", Color(0.55, 0.40, 0.24), 0.8)
	for k in 3:
		var bp := ic + Vector3(-3.0 + k * 3.0, 0.94, 0)
		mb.box("b", board, Transform3D(Basis(Vector3.UP, 0.1 * k), bp), Vector3(0.5, 0.03, 0.32))
		Common.anchor(out, bp + Vector3(0.5, 0.0, 0.0), 0.0, "counter", "restaurant_kitchen")
	# Ticket rail over the pass, the order slips still in it.
	var door0: Vector2i = lay.doors.kitchen[0]
	var rp: Vector3 = world.call(Vector2(door0.x + 4, door0.y + 1.1), 1.7)
	mb.box("s", steel, Transform3D(Basis(), rp), Vector3(2.0, 0.05, 0.06))
	var slip := Common.mat("rest_slip", Color(0.93, 0.92, 0.86), 0.9)
	for k in 5:
		mb.box("p", slip, Transform3D(Basis(), rp + Vector3(-0.8 + k * 0.4, -0.12, 0.04)), Vector3(0.12, 0.2, 0.005))
	var mi := MeshInstance3D.new()
	mi.name = "Kitchen"
	mi.mesh = mb.commit()
	root.add_child(mi)
	# Real models where the project has them: the fridge and the sink.
	_asset(root, "hosp/fridge_kitchen", world.call(Vector2(lay.fridge) + Vector2(0.5, 0.5)) + Vector3(0.15, 0, 0), -PI * 0.5)
	_asset(root, "hosp/sink_cabinet", world.call(Vector2(lay.sink) + Vector2(0.5, 0.5)) + Vector3(0, 0, 0.3), PI)
	for t in [lay.fridge, lay.sink]:
		var p: Vector3 = world.call(Vector2(t) + Vector2(0.5, 0.5))
		Common.collider(body, Transform3D(Basis(), p + Vector3(0, 0.9, 0.15)), Vector3(1.0, 1.8, 0.8))


static func _restrooms(root: Node3D, props: Common.Props, body: StaticBody3D, lay: Dictionary, world: Callable, out: Dictionary) -> void:
	var mb := Common.MeshBuilder.new()
	var part := Common.mat("rest_partition", Color(0.42, 0.20, 0.16), 0.5, 0.2)
	for s: Rect2i in lay.stalls:
		var c: Vector3 = world.call(Vector2(s.position) + Vector2(s.size) * 0.5)
		mb.box("p", part, Transform3D(Basis(), c + Vector3(-s.size.x * T * 0.5 + 0.02, 1.0, 0)), Vector3(0.04, 1.8, T))
		mb.box("p", part, Transform3D(Basis(), c + Vector3(s.size.x * T * 0.5 - 0.02, 1.0, 0)), Vector3(0.04, 1.8, T))
		mb.box("p", part, Transform3D(Basis(), c + Vector3(0, 1.0, -T * 0.5 + 0.02)), Vector3(s.size.x * T - 0.9, 1.8, 0.04))
		_asset(root, "hosp/toilet", c + Vector3(0, 0, T * 0.5 - 0.45), PI)
		Common.collider(body, Transform3D(Basis(), c + Vector3(0, 0.4, T * 0.5 - 0.4)), Vector3(0.5, 0.8, 0.7))
	for r: Rect2i in [MEN, WOMEN]:
		var sp: Vector3 = world.call(Vector2(r.position.x + 0.5, r.position.y + 0.5))
		_asset(root, "hosp/sink_wall", sp + Vector3(-T * 0.5 + 0.25, 0, 0.3), -PI * 0.5)
		_asset(root, "hosp/mirror", sp + Vector3(-T * 0.5 + 0.02, 1.2, 0.3), -PI * 0.5)
	var mi := MeshInstance3D.new()
	mi.name = "Restrooms"
	mi.mesh = mb.commit()
	root.add_child(mi)
	# Signs on the doors' corridor side.
	for pair in [[lay.doors.men, "CABALLEROS"], [lay.doors.women, "DAMAS"]]:
		var t: Vector2i = pair[0]
		var sign := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.8, 0.22)
		sign.mesh = qm
		var sm := StandardMaterial3D.new()
		sm.albedo_texture = Common.text_texture(pair[1], Color(0.95, 0.9, 0.75), Color(0.12, 0.2, 0.36), 256, 72)
		sign.material_override = sm
		sign.position = world.call(Vector2(t.x + 0.5, t.y - 0.02), 2.55)
		sign.rotation.y = PI
		root.add_child(sign)


static func _asset(parent: Node3D, key: String, pos: Vector3, yaw: float) -> void:
	var a := Common.HB.Factory.assets_node()
	if a == null or not a.has(key):
		return
	var n: Node3D = a.spawn(key)
	if n == null:
		return
	n.position = pos
	n.rotation.y = yaw
	for c in n.find_children("*", "CollisionObject3D", true, false):
		c.queue_free()
	parent.add_child(n)


static func _decor(root: Node3D, props: Common.Props, lay: Dictionary, world: Callable, dark_wood: Material) -> void:
	# Papel picado: rows of paper flags strung across the room.
	var flag_cols := [Color(0.85, 0.12, 0.40), Color(0.10, 0.60, 0.70), Color(0.95, 0.65, 0.05), Color(0.35, 0.70, 0.20), Color(0.55, 0.25, 0.75)]
	var flags: Array = []
	for ci in flag_cols.size():
		flags.append(Common.cached_mesh("rest_flag_%d" % ci, func():
			var fm := Common.MeshBuilder.new()
			var m := Common.mat("rest_flag_%d" % ci, flag_cols[ci], 0.9)
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			fm.box("f", m, Transform3D(Basis(), Vector3(0, -0.14, 0)), Vector3(0.26, 0.3, 0.004))
			return fm.commit()))
	var string := Common.cached_mesh("rest_string", func():
		var sm := Common.MeshBuilder.new()
		sm.box("s", Common.mat("rest_twine", Color(0.8, 0.78, 0.7), 1.0), Transform3D(), Vector3(1.0, 0.01, 0.01))
		return sm.commit())
	var x0: float = world.call(Vector2(DINING.position.x, 0)).x
	var x1: float = world.call(Vector2(BAR.position.x - 1, 0)).x
	var k := 0
	for ty in range(DINING.position.y + 2, DINING.end.y - 1, 3):
		var z: float = world.call(Vector2(0, ty)).z
		var y := DINING_CEIL - 0.45
		props.add(string, Transform3D(Basis().scaled(Vector3(x1 - x0, 1, 1)), Vector3((x0 + x1) * 0.5, y, z)), 0.0, false)
		var x := x0 + 0.3
		while x < x1 - 0.2:
			var sag := sin((x - x0) / (x1 - x0) * PI) * 0.18
			props.add(flags[k % flags.size()], Transform3D(Basis(Vector3.UP, 0.05 * sin(x)), Vector3(x, y - sag, z)), 34.0, false)
			x += 0.34
			k += 1
	# Framed pictures on the walls.
	var art_positions := [[Vector2(DINING.position.x + 0.02, DINING.position.y + 7.5), PI * 0.5],
			[Vector2(DINING.position.x + 9.5, DINING.position.y + 0.02), 0.0],
			[Vector2(DINING.position.x + 30.0, DINING.position.y + 0.02), 0.0],
			[Vector2(DINING.position.x + 14.5, DINING.end.y - 0.02), PI]]
	for i in art_positions.size():
		var pos: Vector3 = world.call(art_positions[i][0], 2.1)
		var yaw: float = art_positions[i][1]
		var frame := MeshInstance3D.new()
		var fbm := BoxMesh.new()
		fbm.size = Vector3(1.2, 0.9, 0.05)
		frame.mesh = fbm
		frame.material_override = dark_wood
		frame.position = pos
		frame.rotation.y = yaw
		root.add_child(frame)
		var pic := MeshInstance3D.new()
		var pq := QuadMesh.new()
		pq.size = Vector2(1.04, 0.74)
		pic.mesh = pq
		var pm := StandardMaterial3D.new()
		pm.albedo_texture = _painting_tex(i)
		pm.roughness = 0.85
		pic.material_override = pm
		pic.position = pos + Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.03)
		pic.rotation.y = yaw
		root.add_child(pic)
	# Plants in the corners.
	for t in [Vector2(DINING.position.x + 0.6, DINING.position.y + 0.6), Vector2(DINING.position.x + 0.6, DINING.end.y - 0.6),
			Vector2(FRONT_DOOR.x - 1.2, FRONT_DOOR.y + 1.6), Vector2(FRONT_DOOR.x + 3.2, FRONT_DOOR.y + 1.6)]:
		_asset(root, "hosp/plant", world.call(t), 0.0)


## A little painting: sky, a sun, hills and a cactus. Different colours per index.
static func _painting_tex(i: int) -> Texture2D:
	return Common.cached_texture("rest_painting_%d" % i, func():
		var w := 104
		var h := 74
		var img := Image.create(w, h, false, Image.FORMAT_RGB8)
		var skies := [Color(0.95, 0.55, 0.25), Color(0.25, 0.55, 0.80), Color(0.85, 0.35, 0.45), Color(0.95, 0.75, 0.35)]
		var sky: Color = skies[i % skies.size()]
		for y in h:
			for x in w:
				var c := sky.lerp(sky.darkened(0.3), float(y) / h)
				var sun := Vector2(x - (30 + i * 14), y - 22).length()
				if sun < 10.0:
					c = Color(0.98, 0.9, 0.5)
				var hill := 48.0 + 8.0 * sin(float(x) * 0.08 + i)
				if float(y) > hill:
					c = Color(0.55, 0.35, 0.18).darkened(0.1 * float(i % 2))
				var cx := 70 - i * 9
				if absi(x - cx) < 3 and y > 30 and float(y) <= hill + 4.0:
					c = Color(0.15, 0.45, 0.2)
				if y > 38 and y < 42 and x > cx - 9 and x < cx + 9 and absi(x - cx) > 2:
					c = Color(0.15, 0.45, 0.2)
				img.set_pixel(x, y, c)
		return ImageTexture.create_from_image(img))


static func _lights(root: Node3D, lay: Dictionary, world: Callable, out: Dictionary) -> void:
	var lights := Node3D.new()
	lights.name = "Lights"
	root.add_child(lights)
	var warm := Color(1.0, 0.72, 0.45)
	var shade := Common.cached_mesh("rest_pendant", func():
		var mb := Common.MeshBuilder.new()
		var tin := Common.mat("rest_tin", Color(0.55, 0.40, 0.22), 0.4, 0.8)
		mb.cylinder("t", tin, Transform3D(Basis(), Vector3(0, 0.0, 0)), 0.28, 0.3, 14, 0.08, false)
		mb.cylinder("e", Common.mat("rest_bulb", Color(1.0, 0.8, 0.5), 0.3, 0.0, Color(1.0, 0.72, 0.4), 4.0), Transform3D(Basis(), Vector3(0, -0.1, 0)), 0.1, 0.1, 10)
		mb.box("t", tin, Transform3D(Basis(), Vector3(0, 0.45, 0)), Vector3(0.015, 0.6, 0.015))
		return mb.commit())
	var mb2 := Common.MeshBuilder.new()
	for t: Vector2i in lay.lamps:
		var p: Vector3 = world.call(Vector2(t) + Vector2(0.5, 0.5), DINING_CEIL - 0.85)
		var node := Common.omni(lights, p - Vector3(0, 0.25, 0), 1.7, 8.0, warm, 0.5, false, 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = shade
		node.add_child(mi)
		out.lights.append({"tile": t, "position": p, "mode": 0, "node": node, "pocket": "restaurant"})
	# Pendants over every table (their glow only), the bar, the kitchen, the back rooms.
	for e in lay.tables:
		var p: Vector3 = world.call(Vector2(e.tile) + Vector2(0.5, 0.5), DINING_CEIL - 1.3)
		var mi := MeshInstance3D.new()
		mi.mesh = shade
		mi.position = p
		lights.add_child(mi)
	var counter: Rect2i = lay.counter
	for k in 2:
		var p: Vector3 = world.call(Vector2(counter.position.x + 2.0, counter.position.y + 2.5 + k * 4.0), DINING_CEIL - 0.6)
		out.lights.append({"tile": counter.position, "position": p, "mode": 0, "pocket": "restaurant",
				"node": Common.omni(lights, p, 1.0, 6.5, Color(1.0, 0.6, 0.35), 0.8, false, 1.2)})
	for k in 2:
		var p: Vector3 = world.call(Vector2(KITCHEN.position.x + 5.0 + k * 9.0, KITCHEN.position.y + 3.5), KITCHEN_CEIL - 0.1)
		var node := Common.omni(lights, p, 1.3, 7.5, Color(0.9, 0.97, 1.0), 0.6, k == 0, 1.0)
		var panel := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.2, 0.05, 0.3)
		panel.mesh = bm
		panel.material_override = Common.mat("rest_tube", Color(0.9, 0.95, 0.9), 0.3, 0.0, Color(0.95, 1.0, 0.95), 2.4)
		panel.position = Vector3(0, 0.05, 0)
		node.add_child(panel)
		out.lights.append({"tile": KITCHEN.position, "position": p, "mode": 0, "node": node, "pocket": "restaurant"})
	for r: Rect2i in [CORRIDOR, MEN, WOMEN]:
		var p: Vector3 = world.call(Vector2(r.get_center()), BACK_CEIL - 0.15)
		var node := Common.omni(lights, p, 0.8, 5.0, Color(1.0, 0.9, 0.75), 0.6)
		out.lights.append({"tile": r.position, "position": p, "mode": 0, "node": node, "pocket": "restaurant"})
