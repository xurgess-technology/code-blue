extends RefCounted
## POCKETS: the Factory. A huge, empty industrial hall with a ceiling far too high (27 m): rows of
## identical columns, dead machinery on stopped conveyor lines, a catwalk along the north wall with
## stairs at both ends, a row of site offices, dim high-bay lamps hanging on long rods, and the
## volumetric haze and depth fog swallowing the far walls. Nothing works and nothing moves.
##
## layout(stubs, seed) is pure data (tools/mapcheck.gd checks it); build(layout, origin, out) makes
## the nodes in world space and fills `out` (lights, containers, loose_anchors, monster_spawns,
## nav_faces, spawn).

const Common := preload("res://scripts/level/pockets/pocket_common.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")

const T := 1.5
const M := 10
const RW := 60
const RH := 42
const CEIL := 27.0
const CATWALK_Y := 6.0
const OFFICE_CEIL := 3.0
const OFFICE_TOP := 3.35
const LAMP_Y := 9.0
const COLUMN_STEP := 8

## Hall interior: x 11..70, y 11..52 (local tiles).
const HALL := Rect2i(M + 1, M + 1, RW, RH)
const CATWALK := Rect2i(M + 2, M + 1, RW - 2, 2)
const STAIR_W := Rect2i(M + 4, M + 3, 12, 2)        # rises toward -x
const LANDING_W := Rect2i(M + 2, M + 3, 2, 2)
const STAIR_E := Rect2i(M + RW - 16, M + 3, 12, 2)  # rises toward +x
const LANDING_E := Rect2i(M + RW - 4, M + 3, 2, 2)
const OFFICES := [Rect2i(16, 49, 6, 4), Rect2i(23, 49, 6, 4), Rect2i(30, 49, 6, 4)]
const OFFICE_BLOCK := Rect2i(15, 48, 22, 5)


static func layout(stubs: Array, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var g := Common.new_grid(RW + 2 * M + 2, RH + 2 * M + 2)
	var hall := Common.add_room(g, {"name": "hall", "ceil": CEIL, "floor": "floor", "ceiling": "roof", "wall": "wall_up",
			"wall_low": "wall_low", "split": 2.4, "uv": 2.0, "place": "factory_floor"})
	var office := Common.add_room(g, {"name": "office", "ceil": OFFICE_CEIL, "floor": "office_floor", "ceiling": "office_ceiling",
			"wall": "office_wall", "wall_low": "office_wall_low", "split": 1.05, "header": OFFICE_TOP, "place": "factory_office"})
	Common.carve(g, HALL, hall)
	# Site offices along the south wall: walls OFFICE_TOP high, a doorway each.
	for y in range(OFFICE_BLOCK.position.y, OFFICE_BLOCK.end.y):
		for x in range(OFFICE_BLOCK.position.x, OFFICE_BLOCK.end.x):
			Common.set_solid(g, x, y, OFFICE_TOP)
	var doors: Array = []
	for r: Rect2i in OFFICES:
		Common.carve(g, r, office)
		var door := Vector2i(r.position.x + 2, r.position.y - 1)
		Common.set_open(g, door.x, door.y, office)
		doors.append(door)
	# Keep the stairs, the catwalk's landings and the offices clear of entrances.
	for r in [STAIR_W.grow(1), STAIR_E.grow(1), LANDING_W.grow(1), LANDING_E.grow(1), OFFICE_BLOCK.grow(2)]:
		Common.reserve(g, r)
	var walls := [
		{"from": Vector2i(M, M + 3), "dir": Vector2i(0, 1), "len": RH - 4, "ev": Vector2i(-1, 0)},
		{"from": Vector2i(M + 3, M), "dir": Vector2i(1, 0), "len": RW - 4, "ev": Vector2i(0, -1)},
		{"from": Vector2i(M + RW + 1, M + 3), "dir": Vector2i(0, 1), "len": RH - 4, "ev": Vector2i(1, 0)},
		{"from": Vector2i(M + 3, M + RH + 1), "dir": Vector2i(1, 0), "len": RW - 4, "ev": Vector2i(0, 1)},
	]
	var ports := Common.place_ports(g, stubs, walls, rng)

	# Columns on a grid; a column never stands in front of an entrance or on the stairs.
	var columns: Array = []
	for yy in range(HALL.position.y + COLUMN_STEP, HALL.end.y - 2, COLUMN_STEP):
		for xx in range(HALL.position.x + COLUMN_STEP, HALL.end.x - 2, COLUMN_STEP):
			var t := Vector2i(xx, yy)
			if Common.is_reserved(g, Rect2i(t, Vector2i.ONE)) or OFFICE_BLOCK.grow(1).has_point(t):
				continue
			columns.append(t)
			_block(g, Rect2i(t, Vector2i.ONE))
	# Two production lines between the column rows: a stopped conveyor with dead machines along it.
	var lines: Array = []
	var machines: Array = []
	var line_rows := [HALL.position.y + COLUMN_STEP + 4, HALL.position.y + COLUMN_STEP * 3 + 4]
	for ly in line_rows:
		var x := HALL.position.x + 5
		var seg_start := -1
		while x < HALL.end.x - 5:
			var gap := (x - HALL.position.x) % 16 == 10 or (x - HALL.position.x) % 16 == 11
			var ok := not gap and not Common.is_reserved(g, Rect2i(x, ly, 1, 1)) and Common.is_open(g, x, ly) \
					and (g.nav as PackedByteArray)[Common.idx(g, x, ly)] == 0
			if ok and seg_start < 0:
				seg_start = x
			if (not ok or x == HALL.end.x - 6) and seg_start >= 0:
				var end_x := x if not ok else x + 1
				if end_x - seg_start >= 4:
					lines.append(Rect2i(seg_start, ly, end_x - seg_start, 1))
					_block(g, Rect2i(seg_start, ly, end_x - seg_start, 1))
				seg_start = -1
			x += 1
	# Machines beside the lines.
	var kinds := ["press", "lathe", "cabinet", "robot", "press", "tank"]
	for ln: Rect2i in lines:
		var x := ln.position.x + 1
		while x < ln.end.x - 2:
			for side in [-1, 1]:
				var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
				var size := _machine_size(kind)
				var y0 := ln.position.y - size.y - 1 if side < 0 else ln.position.y + 2
				var r := Rect2i(x, y0, size.x, size.y)
				if rng.randf() < 0.72 and _free(g, r.grow(1)) :
					machines.append({"kind": kind, "rect": r, "yaw": 0.0 if side < 0 else PI})
					_block(g, r)
			x += rng.randi_range(4, 6)
	# Pallet racking and stacked crates near the walls, where nothing else is.
	var racks: Array = []
	for i in 10:
		var vertical := rng.randf() < 0.5
		var r := Rect2i(rng.randi_range(HALL.position.x + 2, HALL.end.x - 10), rng.randi_range(HALL.position.y + 4, HALL.end.y - 10), 1, 1)
		r.size = Vector2i(2, rng.randi_range(5, 8)) if vertical else Vector2i(rng.randi_range(5, 8), 2)
		if _free(g, r.grow(2)):
			racks.append(r)
			_block(g, r)
	var crates: Array = []
	for i in 26:
		var t := Vector2i(rng.randi_range(HALL.position.x + 1, HALL.end.x - 2), rng.randi_range(HALL.position.y + 3, HALL.end.y - 2))
		if _free(g, Rect2i(t, Vector2i.ONE).grow(1)):
			crates.append({"tile": t, "stack": rng.randi_range(1, 3), "yaw": rng.randf_range(-0.2, 0.2)})
			_block(g, Rect2i(t, Vector2i.ONE))
	# Containers: tool walls in the offices, a first aid bag on a few columns, a fridge in the last
	# office (the break corner).
	var containers: Array = []
	for i in OFFICES.size():
		var r: Rect2i = OFFICES[i]
		containers.append({"tile": Vector2i(r.end.x - 1, r.position.y + 1), "wall": Vector2i(1, 0), "type": "drawer_unit" if i != 2 else "med_fridge"})
		containers.append({"tile": Vector2i(r.position.x, r.position.y + 2), "wall": Vector2i(-1, 0), "type": "pegboard"})
	# First aid bags on the office block's outer wall.
	var bags := 0
	for x in range(OFFICE_BLOCK.position.x + 1, OFFICE_BLOCK.end.x - 1, 5):
		var front := Vector2i(x, OFFICE_BLOCK.position.y - 1)
		if bags < 2 and not Common.is_open(g, front.x, front.y + 1) and _free(g, Rect2i(front, Vector2i.ONE)):
			containers.append({"tile": front, "wall": Vector2i(0, 1), "type": "trauma_bag"})
			bags += 1
	for c in containers:
		if c.type != "trauma_bag" and c.type != "pegboard":
			_block(g, Rect2i(c.tile, Vector2i.ONE))
	for r: Rect2i in OFFICES:
		_block(g, Rect2i(r.position.x + 2, r.end.y - 1, 2, 1))
	# Lamps, a grid of high bays: most on, some flickering, some dead.
	var lamps: Array = []
	for ly in [HALL.position.y + 4, HALL.position.y + 16, HALL.position.y + 28, HALL.position.y + 38]:
		for lx in [HALL.position.x + 4, HALL.position.x + 16, HALL.position.x + 28, HALL.position.x + 40, HALL.position.x + 52]:
			var roll := rng.randf()
			lamps.append({"tile": Vector2i(lx, ly), "mode": 0 if roll < 0.5 else (1 if roll < 0.68 else 2)})
	# Monster spawns out on the floor, away from the entrances.
	var spawns: Array = []
	var tries := 0
	while spawns.size() < 3 and tries < 200:
		tries += 1
		var t := Vector2i(rng.randi_range(HALL.position.x + 4, HALL.end.x - 5), rng.randi_range(HALL.position.y + 6, HALL.end.y - 8))
		if not _free(g, Rect2i(t, Vector2i.ONE).grow(1)):
			continue
		var far := true
		for s in spawns:
			if (s as Vector2i).distance_to(t) < 14.0:
				far = false
		if far:
			spawns.append(t)
	return {"kind": "factory", "size": Vector2i(g.w, g.h), "grid": g, "rows": Common.rows(g), "ports": ports,
			"columns": columns, "lines": lines, "machines": machines, "racks": racks, "crates": crates,
			"containers": containers, "lamps": lamps, "spawns": spawns, "doors": doors,
			"spawn": Vector2i(HALL.get_center().x, HALL.get_center().y)}


static func _machine_size(kind: String) -> Vector2i:
	match kind:
		"press": return Vector2i(3, 2)
		"lathe": return Vector2i(3, 1)
		"cabinet": return Vector2i(1, 1)
		"robot": return Vector2i(2, 2)
		"tank": return Vector2i(2, 2)
	return Vector2i(2, 2)


static func _free(g: Dictionary, r: Rect2i) -> bool:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if not Common.is_open(g, x, y):
				return false
			var i := Common.idx(g, x, y)
			if g.reserved[i] == 1 or g.nav[i] == 1 or g.stub[i] == 1 or g.room[i] != 0:
				return false
			if HALL.has_point(Vector2i(x, y)) == false:
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
	_catwalk_nav(origin, nav)
	geo.bake()
	return {"geo": geo, "nav_faces": nav}


## Everything at once (warmup, tools): the interior's root node.
static func build(lay: Dictionary, origin: Vector2i, out: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Factory"
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
	var concrete := Common.tri_mat("fac_column", "mat/concrete", Color(0.66, 0.66, 0.63), 0.35, 0.9)
	var steel := Common.tri_mat("fac_steel", "mat/metal", Color(0.30, 0.31, 0.32), 0.6, 0.55, 0.6)
	var rust := Common.tri_mat("fac_rust", "mat/metal", Color(0.36, 0.24, 0.16), 0.8, 0.8, 0.3)
	var paint_g := Common.tri_mat("fac_paint_green", "mat/metal", Color(0.22, 0.34, 0.26), 0.7, 0.7, 0.2)
	var paint_y := Common.tri_mat("fac_paint_yellow", "mat/metal", Color(0.62, 0.48, 0.10), 0.7, 0.7, 0.2)
	var dark := _plain("fac_dark", Color(0.07, 0.07, 0.075), 0.6)
	var rubber := _plain("fac_rubber", Color(0.05, 0.05, 0.05), 0.95)

	steps.append(func():
		geo.mats["floor"] = Common.tri_mat("fac_floor", "mat/concrete", Color(0.62, 0.61, 0.57), 0.22, 0.92)
		geo.mats["roof"] = _plain("fac_roof", Color(0.05, 0.055, 0.06), 0.95)
		geo.mats["wall_low"] = Common.tri_mat("fac_wall_low", "mat/concrete", Color(0.52, 0.58, 0.53), 0.35, 0.9)
		geo.mats["wall_up"] = _corrugated()
		geo.mats["office_floor"] = Common.tri_mat("fac_office_floor", "mat/floor", Color(0.55, 0.52, 0.47), 0.6, 0.85)
		geo.mats["office_ceiling"] = Common.HB.surface_mat("mat/ceiling", Color(0.30, 0.31, 0.31), 0.95)
		geo.mats["office_wall"] = Common.tri_mat("fac_office_wall", "mat/wall", Color(0.62, 0.6, 0.52), 0.5, 0.85)
		geo.mats["office_wall_low"] = Common.tri_mat("fac_office_wall_low", "mat/wall", Color(0.42, 0.44, 0.40), 0.5, 0.85)
		return geo.commit_steps(root, ctx))

	# The floor and the roof as boxes, so nothing falls through between faces; the columns and beams.
	steps.append(func():
		var body: StaticBody3D = ctx.body
		var hall_w := Rect2(Vector2(HALL.position) * T + Vector2(ow.x, ow.z), Vector2(HALL.size) * T)
		Common.collider(body, Transform3D(Basis(), Vector3(hall_w.get_center().x, -0.2, hall_w.get_center().y)), Vector3(hall_w.size.x, 0.4, hall_w.size.y))
		Common.collider(body, Transform3D(Basis(), Vector3(hall_w.get_center().x, CEIL + 0.2, hall_w.get_center().y)), Vector3(hall_w.size.x, 0.4, hall_w.size.y))
		# Columns: concrete shafts with a steel base plate and a haunch where the roof beams sit.
		var column_mesh := Common.cached_mesh("fac_column", func():
			var mb := Common.MeshBuilder.new()
			mb.box("c", concrete, Transform3D(Basis(), Vector3(0, CEIL * 0.5, 0)), Vector3(0.9, CEIL, 0.9))
			mb.box("s", steel, Transform3D(Basis(), Vector3(0, 0.08, 0)), Vector3(1.2, 0.16, 1.2))
			mb.box("c", concrete, Transform3D(Basis(), Vector3(0, CEIL - 2.8, 0)), Vector3(1.3, 1.2, 1.3))
			mb.box("y", paint_y, Transform3D(Basis(), Vector3(0, 0.9, 0)), Vector3(0.94, 1.4, 0.94))
			return mb.commit())
		for c: Vector2i in lay.columns:
			var p: Vector3 = world.call(Vector2(c) + Vector2(0.5, 0.5))
			props.add(column_mesh, Transform3D(Basis(), p), 70.0)
			Common.collider(body, Transform3D(Basis(), p + Vector3(0, 1.5, 0)), Vector3(0.95, 3.0, 0.95))
		# Roof beams over every column line, so the ceiling reads as far away.
		var beam_mesh := Common.cached_mesh("fac_beam", func():
			var mb := Common.MeshBuilder.new()
			mb.box("s", steel, Transform3D(), Vector3(0.5, 1.4, 1.0))
			return mb.commit())
		var xs := {}
		var ys := {}
		for c: Vector2i in lay.columns:
			xs[c.x] = true
			ys[c.y] = true
		for x in xs.keys():
			var a: Vector3 = world.call(Vector2(x + 0.5, HALL.position.y))
			var len_z := HALL.size.y * T
			props.add(beam_mesh, Transform3D(Basis().scaled(Vector3(1, 1, len_z)), a + Vector3(0, CEIL - 2.2, len_z * 0.5)), 0.0, false)
		for y in ys.keys():
			var a: Vector3 = world.call(Vector2(HALL.position.x, y + 0.5))
			var len_x := HALL.size.x * T
			props.add(beam_mesh, Transform3D(Basis(Vector3.UP, PI * 0.5).scaled(Vector3(1, 1, len_x)), a + Vector3(len_x * 0.5, CEIL - 3.4, 0)), 0.0, false))

	# Conveyors: a frame on legs, a dead belt, rollers at the ends.
	steps.append(func():
		var body: StaticBody3D = ctx.body
		var belt_mesh := Common.cached_mesh("fac_belt", func():
			var mb := Common.MeshBuilder.new()
			mb.box("s", steel, Transform3D(Basis(), Vector3(0, 0.82, 0)), Vector3(T, 0.16, 1.1))
			mb.box("r", rubber, Transform3D(Basis(), Vector3(0, 0.91, 0)), Vector3(T, 0.03, 0.9))
			for sx in [-0.55, 0.55]:
				mb.box("y", paint_y, Transform3D(Basis(), Vector3(0, 0.95, sx)), Vector3(T, 0.12, 0.06))
			for lx in [-0.6, 0.6]:
				for lz in [-0.45, 0.45]:
					mb.box("s", steel, Transform3D(Basis(), Vector3(lx, 0.38, lz)), Vector3(0.08, 0.76, 0.08))
			return mb.commit())
		for ln: Rect2i in lay.lines:
			for x in range(ln.position.x, ln.end.x):
				var p: Vector3 = world.call(Vector2(x + 0.5, ln.position.y + 0.5))
				props.add(belt_mesh, Transform3D(Basis(), p), 52.0)
			var a: Vector3 = world.call(Vector2(ln.position.x, ln.position.y + 0.5))
			var b: Vector3 = world.call(Vector2(ln.end.x, ln.position.y + 0.5))
			Common.collider(body, Transform3D(Basis(), (a + b) * 0.5 + Vector3(0, 0.5, 0)), Vector3(b.x - a.x, 1.0, 1.15))
			# Boxes left on the belt, as if it stopped mid-shift.
			for x in range(ln.position.x + 1, ln.end.x - 1, 3):
				if (x * 7 + ln.position.y) % 5 < 2:
					var bp: Vector3 = world.call(Vector2(x + 0.5, ln.position.y + 0.5), 0.93)
					props.add(_crate_mesh(), Transform3D(Basis(Vector3.UP, float(x % 3) * 0.2).scaled(Vector3(0.9, 0.7, 0.8)), bp), 40.0))

	# Machines.
	steps.append(func():
		var body: StaticBody3D = ctx.body
		for mc in lay.machines:
			var r: Rect2i = mc.rect
			var centre: Vector3 = world.call(Vector2(r.position) + Vector2(r.size) * 0.5)
			var mesh := _machine_mesh(String(mc.kind), steel, paint_g, paint_y, dark, rust)
			props.add(mesh, Transform3D(Basis(Vector3.UP, float(mc.yaw)), centre), 52.0)
			var size := Vector3(r.size.x * T - 0.3, _machine_height(String(mc.kind)), r.size.y * T - 0.3)
			Common.collider(body, Transform3D(Basis(), centre + Vector3(0, size.y * 0.5, 0)), size)
			if String(mc.kind) == "lathe":
				Common.anchor(out, centre + Vector3(0, _machine_height(String(mc.kind)), 0), 0.0, "counter", "factory_floor"))

	# Pallet racking and crates.
	steps.append(func():
		var body: StaticBody3D = ctx.body
		var upright := Common.cached_mesh("fac_upright", func():
			var mb := Common.MeshBuilder.new()
			mb.box("b", Common.tri_mat("fac_rack_blue", "mat/metal", Color(0.16, 0.25, 0.42), 0.8, 0.6, 0.4), Transform3D(Basis(), Vector3(0, 3.0, 0)), Vector3(0.12, 6.0, 0.12))
			return mb.commit())
		var shelf_beam := Common.cached_mesh("fac_rack_beam", func():
			var mb := Common.MeshBuilder.new()
			mb.box("o", Common.tri_mat("fac_rack_orange", "mat/metal", Color(0.62, 0.30, 0.08), 0.8, 0.6, 0.4), Transform3D(), Vector3(1.0, 0.12, 0.1))
			mb.box("w", Common.tri_mat("fac_pallet", "mat/floor", Color(0.42, 0.33, 0.22), 0.8, 0.9), Transform3D(Basis(), Vector3(0, 0.1, 0.5)), Vector3(1.0, 0.1, 1.0))
			return mb.commit())
		for r: Rect2i in lay.racks:
			var along_x := r.size.x > r.size.y
			var n := r.size.x if along_x else r.size.y
			var a: Vector3 = world.call(Vector2(r.position))
			for k in n + 1:
				for side in [0.15, 2.85]:
					var p := a + (Vector3(k * T, 0, side) if along_x else Vector3(side, 0, k * T))
					props.add(upright, Transform3D(Basis(), p), 60.0)
			for level in [0.2, 2.1, 4.0]:
				for k in n:
					var p := a + (Vector3((k + 0.5) * T, level, 0.15) if along_x else Vector3(0.15, level, (k + 0.5) * T))
					var basis := Basis().scaled(Vector3(T, 1, 1)) if along_x else Basis(Vector3.UP, PI * 0.5).scaled(Vector3(T, 1, 1))
					props.add(shelf_beam, Transform3D(basis.rotated(Vector3.UP, 0.0), p), 48.0)
					var q := a + (Vector3((k + 0.5) * T, level, 2.85) if along_x else Vector3(2.85, level, (k + 0.5) * T))
					props.add(shelf_beam, Transform3D((Basis().scaled(Vector3(T, 1, 1)) if along_x else Basis(Vector3.UP, PI * 0.5).scaled(Vector3(T, 1, 1))).rotated(Vector3.UP, PI), q), 48.0)
					if ((k + int(level * 10.0)) * 13 + r.position.x) % 4 != 0:
						var cp := a + (Vector3((k + 0.5) * T, level + 0.15, 1.5) if along_x else Vector3(1.5, level + 0.15, (k + 0.5) * T))
						props.add(_crate_mesh(), Transform3D(Basis(Vector3.UP, float(k % 2) * 0.1).scaled(Vector3(1.1, 1.0, 1.1)), cp), 40.0)
			var rw := Vector3(r.size.x * T, 5.8, r.size.y * T)
			Common.collider(body, Transform3D(Basis(), a + Vector3(rw.x * 0.5, 2.9, rw.z * 0.5)), rw - Vector3(0.2, 0, 0.2))
		for cr in lay.crates:
			var t: Vector2i = cr.tile
			var p: Vector3 = world.call(Vector2(t) + Vector2(0.5, 0.5))
			for k in int(cr.stack):
				props.add(_crate_mesh(), Transform3D(Basis(Vector3.UP, float(cr.yaw) + k * 0.15).scaled(Vector3(1.15, 0.9, 1.15)), p + Vector3(0, k * 0.72, 0)), 44.0)
			Common.collider(body, Transform3D(Basis(), p + Vector3(0, 0.36 * int(cr.stack), 0)), Vector3(1.1, 0.72 * int(cr.stack), 1.1))
			if int(cr.stack) == 1:
				Common.anchor(out, p + Vector3(0, 0.72, 0), float(cr.yaw), "counter", "factory_floor"))

	steps.append(func(): _build_catwalk(root, ctx.body, props, world, steel, paint_y, out))
	steps.append(func(): _build_offices(root, ctx.body, props, lay, world, out))
	steps.append(func(): _build_floor_marks(props, lay, world))
	steps.append(func(): _build_lamps(root, props, lay, world, out))

	# Containers, one a step.
	var cts := Node3D.new()
	cts.name = "Containers"
	steps.append(func(): root.add_child(cts))
	for c in lay.containers:
		steps.append(func():
			var room := "factory_office" if OFFICE_BLOCK.has_point(c.tile) else "factory_floor"
			Common.container(cts, out, origin, c.tile, c.wall, c.type, room))
	steps.append(func():
		for s: Vector2i in lay.spawns:
			out.monster_spawns.append(world.call(Vector2(s) + Vector2(0.5, 0.5)))
		out["spawn"] = world.call(Vector2(lay.spawn) + Vector2(0.5, 0.5))
		return props.commit_steps(root))
	return steps


## The site offices' doorways, as door plan entries in world tiles (hinged, hung at the hall face).
static func door_entries(lay: Dictionary, origin: Vector2i) -> Array:
	var out: Array = []
	for t: Vector2i in lay.doors:
		out.append(Common.door_entry(origin, [t], Vector2i(0, -1), "hinged", 90.0))
	return out


## Navigation faces of the catwalk, its landings and both stairs (data only).
static func _catwalk_nav(origin: Vector2i, nav: PackedVector3Array) -> void:
	var ow := Vector3(origin.x * T, 0.0, origin.y * T)
	var cy := CATWALK_Y
	for r: Rect2i in [CATWALK, LANDING_W, LANDING_E]:
		var a := ow + Vector3(r.position.x * T, cy, r.position.y * T)
		var b := ow + Vector3(r.end.x * T, cy, r.end.y * T)
		nav.append_array([Vector3(a.x, cy, a.z), Vector3(b.x, cy, a.z), Vector3(b.x, cy, b.z),
				Vector3(a.x, cy, a.z), Vector3(b.x, cy, b.z), Vector3(a.x, cy, b.z)])
	for pair in [[STAIR_W, -1], [STAIR_E, 1]]:
		var r: Rect2i = pair[0]
		var up: int = pair[1]
		var x_low := float(r.position.x) if up > 0 else float(r.end.x)
		var x_high := float(r.end.x) if up > 0 else float(r.position.x)
		var z0 := float(r.position.y)
		var width := (float(r.end.y) - z0) * T
		var lo := ow + Vector3(x_low * T, 0.0, z0 * T)
		var hi := ow + Vector3(x_high * T, cy, z0 * T)
		var la := Vector3(lo.x, 0.0, lo.z)
		var lb := Vector3(lo.x, 0.0, lo.z + width)
		var ha := Vector3(hi.x, cy, lo.z)
		var hb := Vector3(hi.x, cy, lo.z + width)
		if up > 0:
			nav.append_array([la, ha, hb, la, hb, lb])
		else:
			nav.append_array([ha, la, lb, ha, lb, hb])



static func _plain(key: String, col: Color, rough: float, metal := 0.0) -> Material:
	return Common.mat(key, col, rough, metal)


## Corrugated cladding: vertical ribs painted into a small texture, stretched up the walls.
static func _corrugated() -> Material:
	if Common._mat_cache.has("fac_corrugated"):
		return Common._mat_cache["fac_corrugated"]
	var tex := Common.cached_texture("fac_corrugated", func():
		var img := Image.create(64, 64, true, Image.FORMAT_RGB8)
		for x in 64:
			var rib := 0.5 + 0.5 * cos(float(x) / 64.0 * TAU * 4.0)
			for y in 64:
				var n := 0.92 + 0.08 * sin(float(y) * 0.7 + float(x) * 0.13)
				var v := (0.20 + 0.10 * rib) * n
				img.set_pixel(x, y, Color(v * 0.95, v, v * 1.02))
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img))
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.roughness = 0.7
	m.metallic = 0.35
	m.uv1_scale = Vector3(0.5, 0.12, 1.0)
	Common._mat_cache["fac_corrugated"] = m
	return m


static func _crate_mesh() -> Mesh:
	return Common.cached_mesh("fac_crate", func():
		var mb := Common.MeshBuilder.new()
		var card := Common.tri_mat("fac_card", "mat/floor", Color(0.52, 0.40, 0.26), 1.2, 0.95)
		var tape := Common.mat("fac_tape", Color(0.58, 0.50, 0.36), 0.6)
		mb.box("c", card, Transform3D(Basis(), Vector3(0, 0.36, 0)), Vector3(0.9, 0.72, 0.9))
		mb.box("t", tape, Transform3D(Basis(), Vector3(0, 0.725, 0)), Vector3(0.12, 0.01, 0.91))
		return mb.commit())


static func _machine_height(kind: String) -> float:
	match kind:
		"press": return 4.2
		"lathe": return 1.3
		"cabinet": return 2.0
		"robot": return 2.6
		"tank": return 3.4
	return 2.0


static func _machine_mesh(kind: String, steel: Material, green: Material, yellow: Material, dark: Material, rust: Material) -> Mesh:
	return Common.cached_mesh("fac_m_" + kind, func():
		var mb := Common.MeshBuilder.new()
		match kind:
			"press":
				# A stamping press: two uprights, a crown, a ram stopped halfway down, a bed.
				mb.box("g", green, Transform3D(Basis(), Vector3(0, 0.5, 0)), Vector3(4.0, 1.0, 2.4))
				for sx in [-1.6, 1.6]:
					mb.box("g", green, Transform3D(Basis(), Vector3(sx, 2.2, 0)), Vector3(0.7, 3.4, 1.6))
				mb.box("g", green, Transform3D(Basis(), Vector3(0, 3.8, 0)), Vector3(4.2, 0.8, 1.9))
				mb.box("s", steel, Transform3D(Basis(), Vector3(0, 2.3, 0)), Vector3(2.4, 0.7, 1.3))
				mb.box("d", dark, Transform3D(Basis(), Vector3(0, 1.05, 0)), Vector3(2.6, 0.1, 1.5))
				mb.box("y", yellow, Transform3D(Basis(), Vector3(0, 1.12, 1.1)), Vector3(3.0, 0.08, 0.08))
				mb.cylinder("s", steel, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(1.7, 3.8, 1.0)), 0.35, 0.3, 12)
				mb.box("d", dark, Transform3D(Basis(), Vector3(2.35, 1.4, 0.6)), Vector3(0.5, 0.8, 0.4))
			"lathe":
				mb.box("g", green, Transform3D(Basis(), Vector3(0, 0.45, 0)), Vector3(4.2, 0.9, 1.1))
				mb.box("s", steel, Transform3D(Basis(), Vector3(0, 0.95, 0)), Vector3(4.0, 0.1, 0.6))
				mb.box("g", green, Transform3D(Basis(), Vector3(-1.6, 1.3, 0)), Vector3(0.9, 0.7, 0.9))
				mb.box("g", green, Transform3D(Basis(), Vector3(1.5, 1.2, 0)), Vector3(0.5, 0.5, 0.5))
				mb.cylinder("s", steel, Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(-0.4, 1.3, 0)), 0.08, 2.0, 8)
				mb.box("d", dark, Transform3D(Basis(), Vector3(0, 0.5, 0.56)), Vector3(3.6, 0.5, 0.02))
			"cabinet":
				mb.box("g", green, Transform3D(Basis(), Vector3(0, 1.0, 0)), Vector3(1.2, 2.0, 1.1))
				mb.box("d", dark, Transform3D(Basis(), Vector3(0, 1.4, 0.56)), Vector3(0.8, 0.5, 0.02))
				mb.box("y", yellow, Transform3D(Basis(), Vector3(0.3, 0.8, 0.57)), Vector3(0.12, 0.12, 0.03))
			"robot":
				# A welding arm frozen mid-reach.
				mb.cylinder("y", yellow, Transform3D(Basis(), Vector3(0, 0.3, 0)), 0.7, 0.6, 14)
				mb.cylinder("y", yellow, Transform3D(Basis(), Vector3(0, 0.9, 0)), 0.35, 0.6, 12)
				mb.box("y", yellow, Transform3D(Basis(Vector3.BACK, -0.45), Vector3(0.45, 1.8, 0)), Vector3(0.35, 1.8, 0.4))
				mb.box("y", yellow, Transform3D(Basis(Vector3.BACK, 1.1), Vector3(1.3, 2.35, 0)), Vector3(0.28, 1.5, 0.3))
				mb.cylinder("s", steel, Transform3D(Basis(Vector3.BACK, 1.9), Vector3(1.95, 1.8, 0)), 0.07, 0.6, 8)
				mb.box("d", dark, Transform3D(Basis(), Vector3(-1.0, 0.5, 0.8)), Vector3(0.6, 1.0, 0.5))
			"tank":
				mb.cylinder("r", rust, Transform3D(Basis(), Vector3(0, 1.8, 0)), 1.2, 3.0, 16)
				mb.cylinder("s", steel, Transform3D(Basis(), Vector3(0, 0.15, 0)), 1.25, 0.3, 16)
				for a in 4:
					var ang := TAU * a / 4.0 + 0.4
					mb.box("s", steel, Transform3D(Basis(), Vector3(cos(ang) * 1.05, 0.3, sin(ang) * 1.05)), Vector3(0.15, 0.6, 0.15))
				mb.cylinder("s", steel, Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(1.6, 0.8, 0)), 0.12, 1.0, 8)
		return mb.commit())


static func _build_catwalk(root: Node3D, body: StaticBody3D, props: Common.Props, world: Callable, steel: Material, yellow: Material, out: Dictionary) -> void:
	var grate := Common.tri_mat("fac_grate", "mat/metal", Color(0.26, 0.27, 0.27), 1.5, 0.6, 0.7)
	var mb := Common.MeshBuilder.new()
	var cy := CATWALK_Y
	# Deck, landings and the stairs (a ramp collider under visual treads).
	var deck_rects := [CATWALK, LANDING_W, LANDING_E]
	for r: Rect2i in deck_rects:
		var a: Vector3 = world.call(Vector2(r.position), cy)
		var b: Vector3 = world.call(Vector2(r.end), cy)
		var c := (a + b) * 0.5
		var size := Vector3(b.x - a.x, 0.12, b.z - a.z)
		mb.box("g", grate, Transform3D(Basis(), c - Vector3(0, 0.06, 0)), size)
		Common.collider(body, Transform3D(Basis(), c - Vector3(0, 0.08, 0)), Vector3(size.x, 0.16, size.z))
	for pair in [[STAIR_W, -1], [STAIR_E, 1]]:
		var r: Rect2i = pair[0]
		var up: int = pair[1]   # +1: rises toward +x
		var x_low := float(r.position.x) if up > 0 else float(r.end.x)
		var x_high := float(r.end.x) if up > 0 else float(r.position.x)
		var z0 := float(r.position.y)
		var z1 := float(r.end.y)
		var lo: Vector3 = world.call(Vector2(x_low, z0))
		var hi: Vector3 = world.call(Vector2(x_high, z0), cy)
		var run := absf(hi.x - lo.x)
		var slope := atan2(cy, run)
		var width := (z1 - z0) * T
		var mid := Vector3((lo.x + hi.x) * 0.5, cy * 0.5, lo.z + width * 0.5)
		var length := sqrt(run * run + cy * cy)
		var rot := Basis(Vector3.BACK, slope * float(up))
		Common.collider(body, Transform3D(rot, mid - rot.y * 0.08), Vector3(length, 0.16, width))
		var steps := int(round(cy / 0.19))
		for k in steps:
			var f := (k + 0.5) / steps
			var p := Vector3(lerpf(lo.x, hi.x, f), cy * f, mid.z)
			mb.box("g", grate, Transform3D(Basis(), p - Vector3(0, 0.03, 0)), Vector3(run / steps + 0.02, 0.05, width))
		for zz in [lo.z + 0.05, lo.z + width - 0.05]:
			mb.box("s", steel, Transform3D(rot, Vector3(mid.x, cy * 0.5 - 0.15, zz)), Vector3(length, 0.3, 0.08))
			# Handrail on the open side only.
			if zz > lo.z + 0.1:
				mb.box("y", yellow, Transform3D(rot, Vector3(mid.x, cy * 0.5 + 1.0, zz)), Vector3(length, 0.06, 0.06))
		var outer_z := lo.z + width - 0.05
		Common.collider(body, Transform3D(rot, Vector3(mid.x, cy * 0.5 + 0.55, outer_z)), Vector3(length, 1.1, 0.08))
		# Supports under the high end.
		for k in 3:
			var f := 0.45 + 0.27 * k
			var p := Vector3(lerpf(lo.x, hi.x, f), 0.0, mid.z)
			mb.box("s", steel, Transform3D(Basis(), p + Vector3(0, cy * f * 0.5, 0)), Vector3(0.12, cy * f, 0.12))
	# Railing along the catwalk's open edge, gaps where the landings join it.
	var edge_z: float = world.call(Vector2(0, CATWALK.end.y)).z - 0.05
	var x0: float = world.call(Vector2(LANDING_W.end.x, 0)).x
	var x1: float = world.call(Vector2(LANDING_E.position.x, 0)).x
	var rl := x1 - x0
	mb.box("y", yellow, Transform3D(Basis(), Vector3((x0 + x1) * 0.5, cy + 1.05, edge_z)), Vector3(rl, 0.06, 0.06))
	mb.box("y", yellow, Transform3D(Basis(), Vector3((x0 + x1) * 0.5, cy + 0.55, edge_z)), Vector3(rl, 0.05, 0.05))
	Common.collider(body, Transform3D(Basis(), Vector3((x0 + x1) * 0.5, cy + 0.55, edge_z)), Vector3(rl, 1.1, 0.08))
	var n := int(rl / 1.5)
	for k in n + 1:
		mb.box("s", steel, Transform3D(Basis(), Vector3(x0 + k * rl / n, cy + 0.55, edge_z)), Vector3(0.05, 1.1, 0.05))
	# Hangers up into the dark.
	for k in range(0, int((world.call(Vector2(CATWALK.end.x, 0)).x - world.call(Vector2(CATWALK.position.x, 0)).x) / 9.0) + 1):
		var p: Vector3 = world.call(Vector2(CATWALK.position.x + k * 6, CATWALK.end.y), cy)
		mb.box("s", steel, Transform3D(Basis(), Vector3(p.x, cy + (CEIL - cy) * 0.5, p.z - 0.1)), Vector3(0.05, CEIL - cy, 0.05))
		mb.box("s", steel, Transform3D(Basis(), Vector3(p.x, cy - 0.2, (p.z + world.call(Vector2(0, CATWALK.position.y)).z) * 0.5)), Vector3(0.08, 0.25, CATWALK.size.y * T))
	var mi := MeshInstance3D.new()
	mi.name = "Catwalk"
	mi.mesh = mb.commit()
	mi.layers = 1
	root.add_child(mi)
	for k in 3:
		var t := Vector2(CATWALK.position.x + 8 + k * 18, CATWALK.position.y + 1)
		Common.anchor(out, world.call(t, cy), 0.0, "floor", "factory_catwalk")


static func _build_offices(root: Node3D, body: StaticBody3D, props: Common.Props, lay: Dictionary, world: Callable, out: Dictionary) -> void:
	var slab := Common.tri_mat("fac_slab", "mat/concrete", Color(0.30, 0.30, 0.29), 0.4, 0.9)
	var mb := Common.MeshBuilder.new()
	var a: Vector3 = world.call(Vector2(OFFICE_BLOCK.position), OFFICE_CEIL)
	var b: Vector3 = world.call(Vector2(OFFICE_BLOCK.end), OFFICE_TOP)
	mb.box("s", slab, Transform3D(Basis(), (a + b) * 0.5), b - a)
	Common.collider(body, Transform3D(Basis(), (a + b) * 0.5), b - a)
	var desk := Common.tri_mat("fac_desk", "mat/metal", Color(0.35, 0.37, 0.36), 1.0, 0.6, 0.4)
	var wood := Common.tri_mat("fac_wood", "mat/floor", Color(0.40, 0.30, 0.20), 1.0, 0.8)
	var paper := Common.mat("fac_paper", Color(0.80, 0.78, 0.70), 0.9)
	var glass := Common.mat("fac_window", Color(0.02, 0.03, 0.03), 0.1, 0.4)
	for i in OFFICES.size():
		var r: Rect2i = OFFICES[i]
		# A desk with papers against the back wall, a chair, a clipboard board on the side wall.
		var dp: Vector3 = world.call(Vector2(r.position.x + 3, r.end.y - 0.55))
		mb.box("d", desk, Transform3D(Basis(), dp + Vector3(0, 0.74, 0)), Vector3(1.8, 0.05, 0.8))
		for sx in [-0.85, 0.85]:
			mb.box("d", desk, Transform3D(Basis(), dp + Vector3(sx, 0.37, 0)), Vector3(0.05, 0.74, 0.75))
		mb.box("p", paper, Transform3D(Basis(Vector3.UP, 0.2 + i * 0.3), dp + Vector3(-0.3, 0.775, 0.05)), Vector3(0.3, 0.01, 0.22))
		mb.box("w", wood, Transform3D(Basis(), dp + Vector3(0.1, 0.45, -0.9)), Vector3(0.45, 0.06, 0.45))
		Common.collider(body, Transform3D(Basis(), dp + Vector3(0, 0.38, 0)), Vector3(1.8, 0.76, 0.8))
		Common.anchor(out, dp + Vector3(0.45, 0.77, 0.0), 0.0, "counter", "factory_office")
		# A dark window onto the hall beside the door.
		var wp: Vector3 = world.call(Vector2(r.position.x + 4.5, r.position.y - 0.5))
		mb.box("g", glass, Transform3D(Basis(), wp + Vector3(0, 1.6, -T * 0.51)), Vector3(1.8, 0.9, 0.02))
		mb.box("g", glass, Transform3D(Basis(), wp + Vector3(0, 1.6, T * 0.51)), Vector3(1.8, 0.9, 0.02))
	var mi := MeshInstance3D.new()
	mi.name = "Offices"
	mi.mesh = mb.commit()
	root.add_child(mi)


static func _build_floor_marks(props: Common.Props, lay: Dictionary, world: Callable) -> void:
	var mark := Common.cached_mesh("fac_mark", func():
		var mb := Common.MeshBuilder.new()
		mb.box("y", Common.mat("fac_mark_y", Color(0.55, 0.45, 0.08), 0.9), Transform3D(), Vector3(T, 0.01, 0.12))
		return mb.commit())
	for ln: Rect2i in lay.lines:
		for side in [-1.2, 2.2]:
			for x in range(ln.position.x - 2, ln.end.x + 2):
				var p: Vector3 = world.call(Vector2(x + 0.5, ln.position.y + side), 0.006)
				props.add(mark, Transform3D(Basis(), p), 40.0, false)
	var stain := Common.cached_mesh("fac_stain", func():
		var mb := Common.MeshBuilder.new()
		mb.cylinder("o", Common.mat("fac_oil", Color(0.05, 0.05, 0.045), 0.35, 0.2), Transform3D(), 1.0, 0.004, 14)
		return mb.commit())
	var rng := RandomNumberGenerator.new()
	rng.seed = int(lay.columns.size()) * 31 + int(lay.machines.size())
	for i in 30:
		var t := Vector2(rng.randf_range(HALL.position.x + 1, HALL.end.x - 1), rng.randf_range(HALL.position.y + 1, HALL.end.y - 1))
		var s := rng.randf_range(0.3, 1.4)
		props.add(stain, Transform3D(Basis().scaled(Vector3(s, 1, s * rng.randf_range(0.5, 1.0))).rotated(Vector3.UP, rng.randf() * TAU), world.call(t, 0.004)), 30.0, false)


static func _build_lamps(root: Node3D, props: Common.Props, lay: Dictionary, world: Callable, out: Dictionary) -> void:
	var lights := Node3D.new()
	lights.name = "HighBays"
	root.add_child(lights)
	var shade := Common.cached_mesh("fac_lamp_on", func():
		var mb := Common.MeshBuilder.new()
		var metal := Common.mat("fac_lamp_metal", Color(0.12, 0.13, 0.13), 0.5, 0.6)
		mb.cylinder("m", metal, Transform3D(Basis(), Vector3(0, 0.35, 0)), 0.55, 0.5, 16, 0.2, false)
		mb.cylinder("e", Common.mat("fac_lamp_glow", Color(1.0, 0.86, 0.6), 0.3, 0.0, Color(1.0, 0.82, 0.55), 5.0), Transform3D(Basis(), Vector3(0, 0.1, 0)), 0.5, 0.02, 16)
		mb.box("m", metal, Transform3D(Basis(), Vector3(0, (CEIL - LAMP_Y) * 0.5 + 0.6, 0)), Vector3(0.04, CEIL - LAMP_Y, 0.04))
		return mb.commit())
	var shade_dead := Common.cached_mesh("fac_lamp_dead", func():
		var mb := Common.MeshBuilder.new()
		var metal := Common.mat("fac_lamp_metal", Color(0.12, 0.13, 0.13), 0.5, 0.6)
		mb.cylinder("m", metal, Transform3D(Basis(), Vector3(0, 0.35, 0)), 0.55, 0.5, 16, 0.2, false)
		mb.cylinder("d", Common.mat("fac_lamp_dead", Color(0.15, 0.14, 0.12), 0.4), Transform3D(Basis(), Vector3(0, 0.1, 0)), 0.5, 0.02, 16)
		mb.box("m", metal, Transform3D(Basis(), Vector3(0, (CEIL - LAMP_Y) * 0.5 + 0.6, 0)), Vector3(0.04, CEIL - LAMP_Y, 0.04))
		return mb.commit())
	var shadows := 0
	for l in lay.lamps:
		var t: Vector2i = l.tile
		var p: Vector3 = world.call(Vector2(t) + Vector2(0.5, 0.5), LAMP_Y)
		var mode := int(l.mode)
		props.add(shade if mode != 2 else shade_dead, Transform3D(Basis(), p), 0.0, false)
		var node := Common.omni(lights, p - Vector3(0, 0.3, 0), 4.2, 21.0, Color(1.0, 0.82, 0.58), 1.4, mode == 0 and shadows < 2, 1.0)
		if mode == 0 and shadows < 2:
			shadows += 1
		var bulb: OmniLight3D = node.get_node("Bulb")
		bulb.distance_fade_enabled = true
		bulb.distance_fade_begin = 60.0
		bulb.distance_fade_length = 12.0
		if mode == 2:
			bulb.visible = false
			bulb.light_energy = 0.0
		elif mode == 1:
			bulb.set_meta("mode", 1)
			bulb.set_meta("seed", hash(t))
			var flick := LightFlicker.new()
			flick.buzz_enabled = false
			bulb.add_child(flick)
		out.lights.append({"tile": t, "position": p, "mode": mode, "node": node, "pocket": "factory"})
	# One tube in each office.
	for r: Rect2i in OFFICES:
		var p: Vector3 = world.call(Vector2(r.get_center()), OFFICE_CEIL - 0.3)
		var node := Common.omni(lights, p, 1.0, 5.5, Color(0.95, 0.98, 1.0), 1.0)
		var panel := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.2, 0.05, 0.3)
		panel.mesh = bm
		panel.material_override = Common.mat("fac_tube", Color(0.9, 0.95, 0.9), 0.3, 0.0, Color(0.95, 1.0, 0.95), 2.2)
		panel.position = Vector3(0, 0.27, 0)
		node.add_child(panel)
		out.lights.append({"tile": r.get_center(), "position": p, "mode": 0, "node": node, "pocket": "factory"})
