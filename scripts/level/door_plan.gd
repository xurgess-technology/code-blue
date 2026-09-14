extends RefCounted
## Which door hangs in every doorway of a generated map, as data (tile space).
##
## Kinds:
##   hinged   one leaf, press E; swings either way (double-acting)       room doors
##   double   two leaves, press E; swings either way                     cafeteria, radiology, morgue
##   gate     automatic heavy double doors with small windows, lockable  the doorways into the wings
##   auto     automatic heavy double doors with small windows            the OR
##   sliding  automatic sliding glass doors, four panels                 the main entrance
##
## Every doorway is a tunnel one tile deep (the walls are a tile thick). The door hangs in the
## plane just inside one face of that tunnel, the "face" side: a room door at the room's face, a
## gate or the OR's doors at the side you come from out of the entrance building, the main doors
## at the outside face. `n` points out of that face. A leaf swinging toward -n ("in") folds into the
## tunnel, which is always clear and deep enough for it; swinging toward +n ("out") needs the floor
## in front of the face, so `max_out` is the widest angle that meets no furniture, container, wall
## or other door. Automatic doors only ever swing in (they never hit anyone outside the tunnel).
##
## Entry: {id, kind, tiles: [Vector2i], n: Vector2i, s: Vector2i (along the doorway), plane: Vector2
##   (centre of the door plane), width (tiles), hinge: -1 | 1 (hinged: which end of `s` the hinge
##   is at), max_in, max_out (degrees), room (index or -1), zone, wing (id, "entrance"), base (true:
##   the entrance building's doors, which never change within a run)}

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Ent := preload("res://scripts/level/entrance.gd")

## How far inside the face the door plane sits, tiles.
const PLANE_INSET := 0.045
## Gap between a leaf and its jamb, tiles.
const JAMB := 0.045
## Gap between the two leaves of a pair, tiles.
const MID_GAP := 0.012
const LEAF_H := 2.2
## Swing sampling.
const ANGLE_STEP := 10.0
const POINT_STEP := 0.12
## Half the leaf thickness plus a little air, tiles.
const LEAF_HALF_T := 0.03
## A hinged door must open at least this far on some side for a body to pass (1.0 m gap).
const MIN_PASS_DEG := 75.0


## Every door of the map. `er` is the entrance building's tile rect.
static func plan(st: S, er: Rect2i) -> Array:
	var out: Array = []
	var taken := {}
	var occ := {}   # quarter-tile cell -> door index (swept areas already claimed)
	var ox := er.position.x
	var oy := er.position.y

	var groups: Array = []
	# The main doors.
	var main: Array = []
	for c in Ent.MAIN_DOORS:
		main.append(Vector2i(ox + c, oy + Ent.H - 1))
	groups.append({"kind": "sliding", "tiles": main})
	# The OR's doors.
	groups.append({"kind": "auto", "tiles": [Vector2i(ox + 13, oy + 7), Vector2i(ox + 13, oy + 8)]})
	# The gates into the wings.
	for wd in st.wings:
		groups.append({"kind": "gate", "tiles": (wd.entry as Array).duplicate(), "wing": String(wd.id)})
	for g in groups:
		for t in g.tiles:
			taken[t] = true
	# Room doors: every other doorway tile, one door per room doorway (two tiles for a double).
	for r in st.rooms:
		var tiles: Array = r.get("doors", [])
		var done := {}
		for t in tiles:
			if taken.has(t) or done.has(t):
				continue
			var pair: Array = [t]
			for u in tiles:
				if u != t and not taken.has(u) and not done.has(u) and (absi(u.x - t.x) + absi(u.y - t.y)) == 1:
					pair.append(u)
			for u in pair:
				done[u] = true
				taken[u] = true
			groups.append({"kind": "double" if pair.size() == 2 else "hinged", "tiles": pair, "room": int(r.id)})
	# Any doorway tile nobody claimed (a hand-made map): a hinged door of its own.
	for y in st.h:
		for x in st.w:
			if st.get_c(x, y) == S.CH_DOOR and not taken.has(Vector2i(x, y)):
				groups.append({"kind": "hinged", "tiles": [Vector2i(x, y)]})
				taken[Vector2i(x, y)] = true

	var grid := obstacle_grid(st.furniture, st.containers)
	for g in groups:
		var d := _describe(st, er, g)
		if d.is_empty():
			continue
		_fit_swing(st, d, occ, out.size(), grid)
		out.append(d)
	return out


## Orientation, plane and ownership of one door.
static func _describe(st: S, er: Rect2i, g: Dictionary) -> Dictionary:
	var tiles: Array = g.tiles
	if tiles.is_empty():
		return {}
	var t0: Vector2i = tiles[0]
	var pass_y: bool = st.walkable(t0.x, t0.y - 1) and st.walkable(t0.x, t0.y + 1)
	var n := Vector2i(0, 1) if pass_y else Vector2i(1, 0)
	var s := Vector2i(1, 0) if pass_y else Vector2i(0, 1)
	tiles.sort_custom(func(a, b): return (a.x + a.y) < (b.x + b.y))
	var kind: String = g.kind
	var room := int(g.get("room", -1))
	# Which face the door hangs at.
	var face := 1
	var centre := Vector2.ZERO
	for t in tiles:
		centre += Vector2(t) + Vector2(0.5, 0.5)
	centre /= float(tiles.size())
	var p_plus := t0 + n
	var p_minus := t0 - n
	match kind:
		"hinged", "double":
			if room >= 0:
				face = 1 if st.room_index(p_plus.x, p_plus.y) == room else -1
			else:
				face = 1 if st.room_index(p_plus.x, p_plus.y) >= 0 else -1
		"gate":
			face = 1 if er.has_point(p_plus) else -1
		"auto":
			face = 1 if st.room_index(p_plus.x, p_plus.y) < 0 else -1
		"sliding":
			face = 1 if st.zone_at(p_plus.x, p_plus.y) == S.ZONE_OUTDOOR else -1
	n *= face
	var zone := st.zone_at(t0.x, t0.y)
	var wing := String(g.get("wing", ""))
	var depth := 0
	if room >= 0:
		wing = String(st.rooms[room].wing)
		depth = int(st.rooms[room].depth)
	elif wing == "":
		wing = "entrance" if er.has_point(t0) else ""
	if kind == "gate":
		for wd in st.wings:
			if String(wd.id) == wing:
				depth = int(wd.depth)
	var base := er.has_point(t0)
	return {
		"id": "dr_%d_%d" % [t0.x, t0.y],
		"kind": kind,
		"tiles": tiles,
		"n": n,
		"s": s,
		"plane": centre + Vector2(n) * (0.5 - PLANE_INSET),
		"width": float(tiles.size()),
		"hinge": -1,
		"max_in": 90.0 if kind != "sliding" else 0.0,
		"max_out": 0.0,
		"room": room,
		"zone": zone,
		"wing": wing,
		"depth": depth,
		"base": base,
	}


## Leaves of a door: [[hinge point, closed direction (hinge -> tip), length]] in tile space.
static func leaves(d: Dictionary) -> Array:
	var s := Vector2(d.s)
	var plane: Vector2 = d.plane
	var half: float = float(d.width) * 0.5
	match String(d.kind):
		"hinged":
			var h := int(d.hinge)
			return [[plane + s * (half - JAMB) * h, -s * h, float(d.width) - 2.0 * JAMB]]
		"sliding":
			return []
	var l := half - JAMB - MID_GAP * 0.5
	return [[plane - s * (half - JAMB), s, l], [plane + s * (half - JAMB), -s, l]]


## Points along the middle of one leaf opened `deg` degrees toward `side` (+1 out of the face,
## -1 into the tunnel). Obstacles are grown by the leaf's half thickness instead.
static func leaf_points(d: Dictionary, leaf: Array, deg: float, side: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var a := deg_to_rad(deg)
	var dir: Vector2 = (leaf[1] as Vector2) * cos(a) + Vector2(d.n) * float(side) * sin(a)
	var l := float(leaf[2])
	var steps := int(ceil(l / POINT_STEP))
	for i in steps + 1:
		pts.append((leaf[0] as Vector2) + dir * (l * float(i) / float(steps)))
	return pts


## The widest out-swing that stays clear, the hinge end for a single leaf, and the claimed cells.
## The swing into the tunnel is always a full 90 degrees: nothing ever stands in a doorway.
static func _fit_swing(st: S, d: Dictionary, occ: Dictionary, index: int, grid: Dictionary) -> void:
	var kind := String(d.kind)
	if kind == "sliding":
		return
	if kind == "hinged":
		var best := -1.0
		var best_h := -1
		for h in [-1, 1]:
			d.hinge = h
			var a := _max_angle(st, d, 1, grid, occ, index)
			if a > best + 0.01:
				best = a
				best_h = h
		d.hinge = best_h
		d.max_out = best
	elif kind == "double":
		d.max_out = _max_angle(st, d, 1, grid, occ, index)
	for leaf in leaves(d):
		var a := 0.0
		while a <= float(d.max_out) + 0.001 and float(d.max_out) > 0.0:
			for p in leaf_points(d, leaf, a, 1):
				occ[_cell(p)] = index
			a += ANGLE_STEP


static func _max_angle(st: S, d: Dictionary, side: int, grid: Dictionary, occ: Dictionary, index: int) -> float:
	var best := 0.0
	var a := ANGLE_STEP
	var ls := leaves(d)
	while a <= 90.001:
		for leaf in ls:
			for p in leaf_points(d, leaf, a, side):
				if blocked_at(st, p, grid, occ, index):
					return best
		best = a
		a += ANGLE_STEP
	return best

static func _cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x * 4.0)), int(floor(p.y * 4.0)))


## Does a leaf point at `p` hit a wall, an obstacle in `grid` or another door's swing in `occ`?
static func blocked_at(st: S, p: Vector2, grid: Dictionary, occ: Dictionary, index: int) -> bool:
	var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
	if not st.walkable(t.x, t.y):
		return true
	var c := _cell(p)
	if occ.has(c) and int(occ[c]) != index:
		return true
	for r: Rect2 in grid.get(t, []):
		if r.has_point(p):
			return true
	return false


## Footprints (tile space) a leaf must not pass through, bucketed by tile: furniture lower than
## the leaf and the containers against the walls.
static func obstacle_grid(furniture: Array, containers: Array) -> Dictionary:
	var grid := {}
	var add := func(r: Rect2) -> void:
		for ty in range(int(floor(r.position.y)), int(floor(r.end.y)) + 1):
			for tx in range(int(floor(r.position.x)), int(floor(r.end.x)) + 1):
				var k := Vector2i(tx, ty)
				if not grid.has(k):
					grid[k] = []
				(grid[k] as Array).append(r)
	for e in furniture:
		var kind: String = e.kind
		if Defs.mounted(kind) and Defs.mount_height(kind) >= LEAF_H:
			continue
		if float(e.get("y", 0.0)) >= LEAF_H:
			continue
		add.call(Defs.footprint_rect(kind, e.pos, float(e.yaw)).grow(0.01 + LEAF_HALF_T))
	for ct in containers:
		add.call(container_rect(ct.tile, ct.wall).grow(LEAF_HALF_T))
	return grid


## The half of a container's tile against its wall.
static func container_rect(tile: Vector2i, wall: Vector2i) -> Rect2:
	var depth := 0.42
	if wall.x > 0:
		return Rect2(Vector2(tile.x + 1.0 - depth, tile.y), Vector2(depth, 1.0))
	elif wall.x < 0:
		return Rect2(Vector2(tile.x, tile.y), Vector2(depth, 1.0))
	elif wall.y > 0:
		return Rect2(Vector2(tile.x, tile.y + 1.0 - depth), Vector2(1.0, depth))
	return Rect2(Vector2(tile.x, tile.y), Vector2(1.0, depth))


## Can a body get through this door when it opens as far as it may? (mapcheck, validate)
static func passable(d: Dictionary) -> bool:
	match String(d.kind):
		"sliding", "gate", "auto":
			return true
		"double":
			return maxf(float(d.max_in), float(d.max_out)) >= 40.0
	return maxf(float(d.max_in), float(d.max_out)) >= MIN_PASS_DEG
