extends RefCounted
## One procedurally generated wing: long liminal hallways grown from the entrance doorway,
## then real rooms packed along both sides of them, then furniture, lights and hallway dressing.
##
## Corridors first: a long spine leaves the entrance and turns into the wing, branches split
## off it (some very long, some dead ends, some rejoining another hallway), a few stretches
## widen into open halls, and a coverage pass reaches whatever corner is still far from any
## hallway. Rooms second: every wall tile beside a hallway is a possible door; a room of the
## wanted kind is fitted behind it when the whole rectangle (walls included) is still solid.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Rng := preload("res://scripts/level/rng.gd")
const Rooms := preload("res://scripts/level/room_furnish.gd")

## Perpendicular tiles a hallway keeps free of other parallel hallways, so rooms fit between.
const CLEAR := 5
## Share of the wing interior that may become hallway.
const CORRIDOR_BUDGET := 0.23
## Coverage: no interior tile further than this (tiles) from a hallway, where possible.
const COVER_DIST := 8

## Hallway clutter along walls: kind, chance per stretch.
const CLUTTER := [["gurney", 3.0], ["wheelchair", 3.0], ["bench", 2.5], ["vending", 1.2], ["bin", 1.5],
		["wet_floor", 0.8], ["plant", 0.6], ["gurney_body", 0.4]]


class Seg extends RefCounted:
	var start: Vector2i
	var dir: Vector2i
	var side: Vector2i
	var width: int
	var length := 0
	var cells: Array[Vector2i] = []
	var spine := false

	func _init(s: Vector2i, d: Vector2i, sd: Vector2i, wd: int) -> void:
		start = s
		dir = d
		side = sd
		width = wd

	func cell(i: int, j: int) -> Vector2i:
		return start + dir * i + side * j


var st: S
var rng: Rng
var wing: Dictionary
var rect: Rect2i
var z: int
var segs: Array = []
var corridor_cells := 0
var interior := 0
var wishlist: Array = []
var placed_kinds := {}
var map_counts: Dictionary


static func generate(state: S, wing_def: Dictionary, r: Rng, mandatory: Array, counts: Dictionary) -> Dictionary:
	var g := new()
	g.st = state
	g.rng = r
	g.wing = wing_def
	g.rect = wing_def.rect
	g.z = wing_def.zone
	g.map_counts = counts
	g.interior = (g.rect.size.x - 2) * (g.rect.size.y - 2)
	var big: Array = []
	var rest: Array = []
	for k in mandatory:
		if g._min_area(k) >= 36:
			big.append(k)
		else:
			rest.append(k)
	var pending_big := g._corridors(big)
	var pending := g._rooms(rest + pending_big)
	g._furnish()
	g._dress_corridors()
	g._lights()
	return {"pending": pending, "segments": g.segs.size(), "corridor_cells": g.corridor_cells}


func inside(p: Vector2i) -> bool:
	return p.x > rect.position.x and p.y > rect.position.y and p.x < rect.end.x - 1 and p.y < rect.end.y - 1


func is_corr(p: Vector2i) -> bool:
	return st.in_bounds(p.x, p.y) and st.zone_at(p.x, p.y) == z and st.get_c(p.x, p.y) == S.CH_FLOOR and st.room_index(p.x, p.y) < 0


# ---------------------------------------------------------------------------
# Corridors
# ---------------------------------------------------------------------------

func _corridors(big: Array) -> Array:
	var entry: Array = wing.entry
	var d: Vector2i = wing.dir
	var sd := Vector2i(absi(d.y), absi(d.x))
	var first: Vector2i = entry[0] + d
	var spine := Seg.new(first, d, sd, 2)
	spine.spine = true
	# How far the spine can run before it has to turn.
	var room_ahead := _run_room(first, d)
	var q: Array = []
	_grow(spine, clampi(int(room_ahead * rng.rangef(0.45, 0.85)), 6, 60))
	q.append(spine)
	var turned := 0
	var plus0 := _run_room(spine.cell(spine.length - 1, 1) + spine.side, spine.side) > _run_room(spine.cell(spine.length - 1, 0) - spine.side, -spine.side)
	var t0 := _turn(spine, plus0, true)
	if t0 != null:
		turned = 1
		q.append(t0)
	# The big rooms claim their space along the first hallways, before branches fill the wing.
	var pending_big: Array = _rooms(big) if not big.is_empty() else []
	var qi := 0
	while qi < q.size():
		var s: Seg = q[qi]
		qi += 1
		if s.length < 2:
			continue
		# Children along the sides.
		var i := rng.rint(3, 6)
		while i < s.length - 2:
			if corridor_cells < interior * CORRIDOR_BUDGET and rng.chance(0.5 if not s.spine else 0.6):
				var plus := rng.chance(0.5)
				var cw := 2
				var roll := rng.nextf()
				if roll < 0.07 and i + 4 < s.length:
					cw = 4
				elif roll < 0.18 and i + 3 < s.length:
					cw = 3
				var c := _child(s, i, plus, cw)
				if c != null:
					q.append(c)
				i += cw
			i += rng.rint(6, 11)
		# The end: turn, split, carry on through an open hall, or stop dead.
		if corridor_cells >= interior * CORRIDOR_BUDGET:
			continue
		if s == spine and t0 != null:
			continue
		var end_roll := rng.nextf()
		if s.spine and turned == 0:
			end_roll = 0.0
		if end_roll < 0.42:
			var plus := rng.chance(0.5)
			if s.spine:
				plus = _run_room(s.cell(s.length - 1, 1) + s.side, s.side) > _run_room(s.cell(s.length - 1, 0) - s.side, -s.side)
			var t := _turn(s, plus, s.spine)
			if t != null:
				turned += 1
				q.append(t)
		elif end_roll < 0.62:
			for plus in [true, false]:
				var t := _turn(s, plus, false)
				if t != null:
					q.append(t)
		elif end_roll < 0.72:
			var t := _hall(s)
			if t != null:
				q.append(t)
	_cover()
	return pending_big


## Tiles of solid interior from `p` (inclusive) in direction `d`.
func _run_room(p: Vector2i, d: Vector2i) -> int:
	var n := 0
	while inside(p + d * n):
		n += 1
	return n


func _length() -> int:
	var roll := rng.nextf()
	if roll < 0.3:
		return rng.rint(4, 9)
	if roll < 0.78:
		return rng.rint(10, 22)
	return rng.rint(23, 44)


## A wall tile that is part of a room's shell (next to its floor or a doorway) never becomes hallway.
func _touches_room(c: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var q := c + Vector2i(dx, dy)
			if st.room_index(q.x, q.y) >= 0 or st.get_c(q.x, q.y) == S.CH_DOOR:
				return true
	return false


## Carve up to `max_len` rows of a segment; stops at the wing edge, at another hallway it joins,
## or where it would run too close alongside one. Stubs shorter than two rows are undone.
func _grow(s: Seg, max_len: int) -> void:
	var i := 0
	while i < max_len:
		var ok := true
		var hit := false
		for j in s.width:
			var c := s.cell(i, j)
			if not inside(c):
				ok = false
				break
			if st.get_c(c.x, c.y) != S.CH_WALL:
				if is_corr(c):
					hit = true
				else:
					ok = false
					break
			elif _touches_room(c):
				ok = false
				break
		if not ok or hit:
			break
		if i >= 1:
			var near := false
			for k in range(1, CLEAR + 1):
				if is_corr(s.cell(i, -k)) or is_corr(s.cell(i, s.width - 1 + k)):
					near = true
					break
			if near:
				break
		for j in s.width:
			var c := s.cell(i, j)
			st.set_c(c.x, c.y, S.CH_FLOOR)
			st.zone[st.idx(c.x, c.y)] = z
			s.cells.append(c)
		corridor_cells += s.width
		i += 1
	s.length = i
	if s.length < 2 and not s.spine:
		for c in s.cells:
			st.set_c(c.x, c.y, S.CH_WALL)
		corridor_cells -= s.cells.size()
		s.cells.clear()
		s.length = 0
	else:
		segs.append(s)


func _child(s: Seg, i: int, plus: bool, cw: int) -> Seg:
	var start: Vector2i
	var d: Vector2i
	if plus:
		start = s.cell(i, s.width)
		d = s.side
	else:
		start = s.cell(i, -1)
		d = -s.side
	var c := Seg.new(start, d, s.dir, cw)
	_grow(c, _length() if cw <= 3 else rng.rint(4, 8))
	return c if c.length >= 2 else null


func _turn(s: Seg, plus: bool, long: bool) -> Seg:
	var base := s.length - s.width
	if base < 0:
		return null
	var start := s.cell(base, s.width) if plus else s.cell(base, -1)
	var d := s.side if plus else -s.side
	var t := Seg.new(start, d, s.dir, s.width)
	t.spine = long
	_grow(t, rng.rint(18, 60) if long else _length())
	return t if t.length >= 2 else null


## A short open hall where a hallway widens out, then a hallway carrying on beyond it.
func _hall(s: Seg) -> Seg:
	var wd := rng.rint(5, 7)
	var start := s.cell(s.length, 0) - s.side * ((wd - s.width) / 2)
	var hall := Seg.new(start, s.dir, s.side, wd)
	_grow(hall, rng.rint(5, 8))
	if hall.length < 4:
		return null
	var on := Seg.new(hall.cell(hall.length, (wd - 2) / 2), s.dir, s.side, 2)
	_grow(on, _length())
	return on if on.length >= 2 else null


## Reach far corners: from the hallway tile nearest to the farthest uncovered tile, run a
## hallway toward it (straight along the longer axis, then turn).
func _cover() -> void:
	var tries := 0
	var skip := {}
	while tries < 14:
		tries += 1
		var dist := _distance_map()
		var far := Vector2i(-1, -1)
		var best := COVER_DIST
		for y in range(rect.position.y + 1, rect.end.y - 1):
			for x in range(rect.position.x + 1, rect.end.x - 1):
				var v: int = dist.get(Vector2i(x, y), 9999)
				if v > best and not skip.has(Vector2i(x, y)):
					best = v
					far = Vector2i(x, y)
		if far.x < 0:
			return
		skip[far] = true
		var from := _nearest_corr(far)
		if from.x < 0:
			return
		var delta := far - from
		var d := Vector2i(signi(delta.x), 0) if absi(delta.x) >= absi(delta.y) else Vector2i(0, signi(delta.y))
		var sd := Vector2i(absi(d.y), absi(d.x))
		# Start just outside the hallway, two wide along it.
		var start := from + d
		while is_corr(start) and inside(start):
			start += d
		var seg := Seg.new(start, d, sd, 2)
		var run := absi(delta.x) if d.x != 0 else absi(delta.y)
		_grow(seg, maxi(3, run))
		if seg.length >= 3:
			var other := Vector2i(0, signi(delta.y)) if d.x != 0 else Vector2i(signi(delta.x), 0)
			if other != Vector2i.ZERO:
				var t := _turn(seg, other == seg.side, false)
				if t != null:
					t.spine = false


func _distance_map() -> Dictionary:
	var dist := {}
	var q: Array[Vector2i] = []
	for s: Seg in segs:
		for c in s.cells:
			if not dist.has(c):
				dist[c] = 0
				q.append(c)
	var qi := 0
	while qi < q.size():
		var p: Vector2i = q[qi]
		qi += 1
		var dv: int = dist[p]
		for d in S.DIRS:
			var n := p + d
			if dist.has(n) or not inside(n):
				continue
			dist[n] = dv + 1
			q.append(n)
	return dist


func _nearest_corr(p: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 1 << 30
	for s: Seg in segs:
		for c in s.cells:
			var d := absi(c.x - p.x) + absi(c.y - p.y)
			if d < bd:
				bd = d
				best = c
	return best


# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

## Summed-area table of carved tiles over the wing rect, for O(1) "is this rectangle solid".
var _sat := PackedInt32Array()
var _sw := 0


func _rebuild_sat() -> void:
	_sw = rect.size.x + 1
	_sat.resize(_sw * (rect.size.y + 1))
	_sat.fill(0)
	for y in rect.size.y:
		var row := 0
		for x in rect.size.x:
			var gx := rect.position.x + x
			var gy := rect.position.y + y
			if st.cells[st.idx(gx, gy)] != S.CH_WALL:
				row += 1
			_sat[(y + 1) * _sw + x + 1] = _sat[y * _sw + x + 1] + row


## Carved tiles inside [x0, x1] x [y0, y1] (global, inclusive).
func _carved(x0: int, y0: int, x1: int, y1: int) -> int:
	var lx0 := x0 - rect.position.x
	var ly0 := y0 - rect.position.y
	var lx1 := x1 - rect.position.x + 1
	var ly1 := y1 - rect.position.y + 1
	return _sat[ly1 * _sw + lx1] - _sat[ly0 * _sw + lx1] - _sat[ly1 * _sw + lx0] + _sat[ly0 * _sw + lx0]


func _rooms(mandatory: Array) -> Array:
	var pending: Array = mandatory.duplicate()
	pending.sort_custom(func(a, b): return _min_area(a) > _min_area(b))
	var cands := _frontage()
	_rebuild_sat()
	for pass_i in 2:
		for cand in cands:
			var wall_t: Vector2i = cand[0]
			var n: Vector2i = cand[1]
			if st.get_c(wall_t.x, wall_t.y) != S.CH_WALL or not is_corr(wall_t - n):
				continue
			var beyond := wall_t + n
			if not inside(beyond) or st.get_c(beyond.x, beyond.y) != S.CH_WALL:
				continue
			var avail := _depth_avail(wall_t, n, 11)
			if avail < 3:
				continue
			var order: Array = []
			for k in pending:
				order.append(k)
			if pass_i == 0:
				for i in 3:
					var k := _fill_kind()
					if k != "":
						order.append(k)
			for kind in order:
				if _try_room(wall_t, n, kind, pass_i == 1, avail):
					var idx := pending.find(kind)
					if idx >= 0:
						pending.remove_at(idx)
					break
		if pending.is_empty():
			break
	return pending


func _min_area(kind: String) -> int:
	var k: Dictionary = Rooms.KINDS[kind]
	return int(k.w[0]) * int(k.d[0])


func _fill_kind() -> String:
	var kinds: Array = []
	var weights: Array = []
	for k in Rooms.KINDS.keys():
		if Rooms.MAP_CAP.has(k) and int(map_counts.get(k, 0)) >= int(Rooms.MAP_CAP[k]):
			continue
		if Rooms.WING_CAP.has(k) and int(placed_kinds.get(k, 0)) >= int(Rooms.WING_CAP[k]):
			continue
		var wgt: float = Rooms.KINDS[k].weight
		# Deeper wings lean toward the grim rooms.
		if k == "morgue" or k == "radiology" or k == "lab":
			wgt *= 0.4 + 0.4 * int(wing.depth)
		if k == "waiting_room" or k == "cafeteria":
			wgt *= 1.6 if int(wing.depth) <= 1 else 0.3
		kinds.append(k)
		weights.append(wgt)
	var i := rng.weighted(weights)
	return kinds[i] if i >= 0 else ""


## Hallway side tiles with solid wall beyond them: [[wall tile, outward dir]], in hallway order.
func _frontage() -> Array:
	var out: Array = []
	var seen := {}
	for s: Seg in segs:
		for i in s.length:
			for pair in [[0, -s.side], [s.width - 1, s.side]]:
				var c := s.cell(i, pair[0])
				var n: Vector2i = pair[1]
				var key := _fkey(c + n, n)
				if not seen.has(key):
					seen[key] = true
					out.append([c + n, n])
		# Rooms at the dead end of a hallway, facing back down it.
		if s.length >= 2:
			for j in s.width:
				var c := s.cell(s.length - 1, j)
				var key := _fkey(c + s.dir, s.dir)
				if not seen.has(key):
					seen[key] = true
					out.append([c + s.dir, s.dir])
	return out


func _fkey(p: Vector2i, n: Vector2i) -> int:
	return ((p.y * 4096 + p.x) * 4) + (0 if n.y < 0 else (1 if n.y > 0 else (2 if n.x < 0 else 3)))


## Solid interior rows straight behind a doorway (three tiles wide), up to cap.
func _depth_avail(door: Vector2i, n: Vector2i, cap: int) -> int:
	var along := Vector2i(absi(n.y), absi(n.x))
	var k := 1
	while k <= cap:
		for j in [-1, 0, 1]:
			var p := door + n * k + along * j
			if not inside(p) or st.get_c(p.x, p.y) != S.CH_WALL:
				return k - 1
		k += 1
	return cap


func _try_room(door: Vector2i, n: Vector2i, kind: String, smallest: bool, avail: int) -> bool:
	var k: Dictionary = Rooms.KINDS[kind]
	if int(k.d[0]) > avail:
		return false
	var ws := range(int(k.w[1]), int(k.w[0]) - 1, -1)
	var ds := range(mini(int(k.d[1]), avail), int(k.d[0]) - 1, -1)
	if smallest:
		ws.reverse()
		ds.reverse()
	elif rng.chance(0.35):
		# Not always the biggest room that fits: some variety in size.
		ws = [int(k.w[0]) + rng.rint(0, int(k.w[1]) - int(k.w[0]))] + ws
	var vertical := n.x == 0
	for D in ds:
		for Wd in ws:
			var offsets := [1, Wd - 2, Wd / 2]
			if int(k.open) > 0:
				offsets = [Wd / 2, Wd / 2 - 1, Wd / 2 + 1]
			for a in offsets:
				if a < 0 or a > Wd - 1:
					continue
				var r := _rect_for(door, n, Wd, D, a)
				if not _solid_with_walls(r):
					continue
				_place_room(r, door, n, kind, a)
				return true
	return false


func _rect_for(door: Vector2i, n: Vector2i, Wd: int, D: int, a: int) -> Rect2i:
	if n == Vector2i(0, -1):
		return Rect2i(door.x - a, door.y - D, Wd, D)
	if n == Vector2i(0, 1):
		return Rect2i(door.x - a, door.y + 1, Wd, D)
	if n == Vector2i(-1, 0):
		return Rect2i(door.x - D, door.y - a, D, Wd)
	return Rect2i(door.x + 1, door.y - a, D, Wd)


func _solid_with_walls(r: Rect2i) -> bool:
	var x0 := r.position.x - 1
	var y0 := r.position.y - 1
	var x1 := r.end.x
	var y1 := r.end.y
	if x0 < rect.position.x or y0 < rect.position.y or x1 > rect.end.x - 1 or y1 > rect.end.y - 1:
		return false
	return _carved(x0, y0, x1, y1) == 0


func _place_room(r: Rect2i, door: Vector2i, n: Vector2i, kind: String, a: int) -> void:
	var side := "S"
	if n == Vector2i(0, 1):
		side = "N"
	elif n == Vector2i(-1, 0):
		side = "E"
	elif n == Vector2i(1, 0):
		side = "W"
	var ri := st.add_room(r, kind, z, String(wing.id), int(wing.depth), {"side": side, "door": door, "entry": door + n})
	placed_kinds[kind] = int(placed_kinds.get(kind, 0)) + 1
	map_counts[kind] = int(map_counts.get(kind, 0)) + 1
	st.set_c(door.x, door.y, S.CH_DOOR)
	st.zone[st.idx(door.x, door.y)] = z
	(st.rooms[ri].doors as Array).append(door)
	var open_w := int(Rooms.KINDS[kind].open)
	if open_w > 0:
		# An archway instead of a door: the wall tiles either side of the door open too.
		st.set_c(door.x, door.y, S.CH_FLOOR)
		var along := Vector2i(absi(n.y), absi(n.x))
		var half := (open_w - 1) / 2
		for k in range(-half, open_w - half):
			var t := door + along * k
			var inner := t + n
			if st.room_index(inner.x, inner.y) != ri or not is_corr(t - n):
				continue
			st.set_c(t.x, t.y, S.CH_FLOOR)
			st.zone[st.idx(t.x, t.y)] = z
			(st.rooms[ri].open as Array).append(t)
		(st.rooms[ri].doors as Array).clear()
	_rebuild_sat()


func _furnish() -> void:
	for ri in st.rooms.size():
		if int(st.rooms[ri].zone) == z:
			Rooms.furnish(st, ri, rng)


# ---------------------------------------------------------------------------
# Hallway dressing, trauma bags, lights
# ---------------------------------------------------------------------------

func _wall_side_ok(c: Vector2i, n: Vector2i) -> bool:
	if not is_corr(c) or st.get_c(c.x + n.x, c.y + n.y) != S.CH_WALL:
		return false
	if st.door_near(c.x, c.y) or st.keep[st.idx(c.x, c.y)] != 0 or st.blocked[st.idx(c.x, c.y)] != 0:
		return false
	# Not in an archway's mouth.
	for d in S.DIRS:
		var q := c + d
		if st.get_c(q.x, q.y) == S.CH_FLOOR and st.room_index(q.x, q.y) >= 0:
			return false
	return true


func _dress_corridors() -> void:
	var bags := 0
	var want_bags := 1 + int(wing.depth) / 2
	var bag_spots: Array[Vector2i] = []
	for s: Seg in segs:
		if s.width > 3:
			continue
		var i := rng.rint(2, 6)
		while i < s.length - 1:
			var plus := rng.chance(0.5)
			var j := s.width - 1 if plus else 0
			var n := s.side if plus else -s.side
			var c := s.cell(i, j)
			if _wall_side_ok(c, n):
				var roll := rng.nextf()
				if roll < 0.16 and bags < want_bags:
					var far := true
					for b in bag_spots:
						if absi(b.x - c.x) + absi(b.y - c.y) < 12:
							far = false
					if far and st.add_container(c, n, "trauma_bag", -1):
						bags += 1
						bag_spots.append(c)
				elif roll < 0.5:
					var weights: Array = []
					for e in CLUTTER:
						weights.append(e[1])
					var kind: String = CLUTTER[rng.weighted(weights)][0]
					var depth := Defs.size(kind).z * 0.5 / Defs.TILE + 0.03
					var face := Vector2(-n.x, -n.y)
					var pos := Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * (0.5 - depth)
					if kind == "gurney" or kind == "gurney_body" or kind == "bench":
						# Long things lie along the wall.
						face = Vector2(s.dir.x, s.dir.y) * (1 if rng.chance(0.5) else -1)
						var hw := Defs.size(kind).x * 0.5 / Defs.TILE + 0.03
						pos = Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * (0.5 - hw)
						if kind == "bench":
							face = Vector2(-n.x, -n.y)
							pos = Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * (0.5 - depth)
					st.put(kind, pos, Defs.yaw_facing(face), -1)
				elif roll < 0.6:
					var mount := "extinguisher" if rng.chance(0.6) else "wall_clock"
					st.put(mount, Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * 0.5, Defs.yaw_facing(Vector2(-n.x, -n.y)), -1)
			i += rng.rint(4, 9)
	# Cameras watch a few long hallways from their far end.
	for s: Seg in segs:
		if s.length >= 14 and rng.chance(0.35):
			var c := s.cell(s.length - 1, 0)
			var n := -s.side
			if st.get_c(c.x + n.x, c.y + n.y) == S.CH_WALL:
				st.put("security_camera", Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * 0.5, Defs.yaw_facing(Vector2(-s.dir.x, -s.dir.y)), -1)
	# Any trauma bags still missing go on the longest free walls.
	if bags == 0:
		for s: Seg in segs:
			if bags > 0:
				break
			for i in range(1, s.length - 1):
				var c := s.cell(i, 0)
				if _wall_side_ok(c, -s.side) and st.add_container(c, -s.side, "trauma_bag", -1):
					bags += 1
					break


func _lights() -> void:
	var seen := {}
	for s: Seg in segs:
		var count := maxi(1, int(round(float(s.length) / 5.5)))
		for k in count:
			var i := int(floor((k + 0.5) * float(s.length) / count))
			var j := (s.width - 1) / 2 if s.width > 2 else (k % s.width)
			var c := s.cell(i, j)
			if not seen.has(c) and st.walkable(c.x, c.y):
				seen[c] = true
				st.lights.append({"tile": c, "zone": z, "mode": -1})
	for r in st.rooms:
		if int(r.zone) != z:
			continue
		var area: int = r.w * r.h
		if area <= 12 and rng.chance(0.45):
			continue
		var centres: Array[Vector2] = []
		if area >= 42:
			if r.w >= r.h:
				centres.append(Vector2(r.x + r.w * 0.3, r.y + r.h * 0.5))
				centres.append(Vector2(r.x + r.w * 0.7, r.y + r.h * 0.5))
			else:
				centres.append(Vector2(r.x + r.w * 0.5, r.y + r.h * 0.3))
				centres.append(Vector2(r.x + r.w * 0.5, r.y + r.h * 0.7))
		else:
			centres.append(Vector2(r.x + r.w * 0.5, r.y + r.h * 0.5))
		for c in centres:
			var t := Vector2i(int(floor(c.x)), int(floor(c.y)))
			if not seen.has(t) and st.walkable(t.x, t.y):
				seen[t] = true
				st.lights.append({"tile": t, "zone": z, "mode": -1})
