class_name MapGen
extends RefCounted
## Deterministic procedural hospital generator.
##
## Faithful GDScript port of code-blue/src/mapgen.ts plus the `addClutter` pass from
## code-blue/src/map.ts. Same mulberry32 PRNG, same call order, so a given seed produces
## the same hospital as the TypeScript original.
##
## Legend:
##   #  wall                 .  floor            +  door (walkable)
##   b  bed (solid)          c  cabinet (solid)  O  operating table (2 tiles, solid)
##   K  time clock (solid)   C  cloning pod (solid)
##   P  player spawn (x4)    T  tool spawn candidate     M  monster spawn candidate
##   g w i v x l s           clutter props (solid): gurney wheelchair ivstand vending bin locker screen
##   f d n                   container furniture (solid): medicine fridge, drawer unit, nurse-station counter
##
## Room kinds: or, anteroom, clockin (template) and ward, storage, office, empty, pharmacy,
## maintenance, nurse_station (generated). Corridors are every walkable tile outside a room
## and count as the room kind "corridor" for container and item placement.
## The container pass (`_place_containers`) and room relabelling run on their own PRNG
## streams, after the TS-ported passes, so everything before them still matches map.ts.
## Walkable: . + P T M. Everything else is solid. Only # blocks line of sight.

const DEFAULT_WIDTH := 56
const DEFAULT_HEIGHT := 40
## Smallest size that still yields a valid map.
const MIN_WIDTH := 48
const MIN_HEIGHT := 36

const BLOCK_W := 30
const BLOCK_H := 19
## Central block: OR + two anterooms + clock-in room + 2-wide inner ring. Stamped verbatim, centered.
const BLOCK_TEMPLATE: PackedStringArray = [
	"##############################",
	"#............................#",
	"#............................#",
	"#..########################..#",
	"#..#.....#..........#.....#..#",
	"#..#cc...#c........c#...cc#..#",
	"#..+.....+..........+.....+..#",
	"#..+.....+....OO....+.....+..#",
	"#..#.....#..........#.....#..#",
	"#..#.....#..........#.....#..#",
	"#..###########++###########..#",
	"#..#ccc...C.........K..ccc#..#",
	"#..#..P....P......P....P..#..#",
	"#..#......................#..#",
	"#..#ccc................ccc#..#",
	"#..###########++###########..#",
	"#............................#",
	"#............................#",
	"##############################",
]

const WALKABLE_CHARS := ".+PTM"
const LEGEND_CHARS := "#.+bcOKCPTMfdn"
const MIN_TOOLS := 16
const MIN_MONSTERS := 6
const WANT_MONSTERS := 8
const MONSTER_MIN_DIST := 18
const CLUTTER_DENSITY := 0.06

## Clutter character -> prop kind.
const PROP_CHARS := {
	"g": "gurney", "w": "wheelchair", "i": "ivstand",
	"v": "vending", "x": "bin", "l": "locker", "s": "screen",
}
## Weighted draw pool, exactly as in map.ts.
const CLUTTER_KINDS := ["g", "w", "i", "x", "l", "v", "s", "i", "x", "g"]

# Character codes (cells are stored as bytes).
const CH_WALL := 35    # '#'
const CH_FLOOR := 46   # '.'
const CH_DOOR := 43    # '+'
const CH_BED := 98     # 'b'
const CH_CAB := 99     # 'c'
const CH_TABLE := 79   # 'O'
const CH_CLOCK := 75   # 'K'
const CH_POD := 67     # 'C'
const CH_PLAYER := 80  # 'P'
const CH_TOOL := 84    # 'T'
const CH_MON := 77     # 'M'
const CH_FRIDGE := 102  # 'f'
const CH_DRAWERS := 100 # 'd'
const CH_STATION := 110 # 'n'

const ItemsData := preload("res://scripts/items.gd")

## Solid container furniture chars. Wall-mounted containers (trauma_bag, pegboard) keep their tile walkable.
const CONTAINER_CHARS := {"med_fridge": "f", "drawer_unit": "d", "station_drawers": "n"}
const WALL_MOUNTED := ["trauma_bag", "pegboard"]
const SPECIAL_KINDS := ["pharmacy", "maintenance", "nurse_station"]
## Minimum rooms of each special kind on every map.
const SPECIAL_MIN := {"pharmacy": 1, "maintenance": 1, "nurse_station": 2}

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

const GENERATED_KINDS := ["ward", "storage", "office", "empty", "pharmacy", "maintenance", "nurse_station"]


static func is_walkable_char(c: String) -> bool:
	return WALKABLE_CHARS.contains(c)


static func _is_walkable_code(c: int) -> bool:
	return c == CH_FLOOR or c == CH_DOOR or c == CH_PLAYER or c == CH_TOOL or c == CH_MON


# ---------------------------------------------------------------------------
# PRNG - mulberry32, ported bit for bit.
# ---------------------------------------------------------------------------

class Rng extends RefCounted:
	var a: int

	func _init(s: int) -> void:
		a = s & 0xFFFFFFFF

	## 32-bit multiply (Math.imul), split so the intermediate never overflows int64.
	static func imul(x: int, y: int) -> int:
		x &= 0xFFFFFFFF
		y &= 0xFFFFFFFF
		return (((((x >> 16) * y) & 0xFFFF) << 16) + ((x & 0xFFFF) * y)) & 0xFFFFFFFF

	func nextf() -> float:
		a = (a + 0x6d2b79f5) & 0xFFFFFFFF
		var t := a
		t = imul(t ^ (t >> 15), t | 1)
		t = ((t + imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF) ^ t
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0

	## Integer in [lo, hi], inclusive.
	func rint(lo: int, hi: int) -> int:
		return lo + int(floor(nextf() * float(hi - lo + 1)))

	func chance(p: float) -> bool:
		return nextf() < p

	func pick(arr: Array):
		return arr[int(floor(nextf() * float(arr.size())))]

	func shuffle(arr: Array) -> Array:
		for i in range(arr.size() - 1, 0, -1):
			var j := int(floor(nextf() * float(i + 1)))
			var tmp = arr[i]
			arr[i] = arr[j]
			arr[j] = tmp
		return arr


# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------

class Grid extends RefCounted:
	var w: int
	var h: int
	var cells: PackedByteArray
	var corridor: PackedByteArray
	var locked: PackedByteArray

	func _init(w_: int, h_: int) -> void:
		w = w_
		h = h_
		cells = PackedByteArray()
		cells.resize(w * h)
		cells.fill(MapGen.CH_WALL)
		corridor = PackedByteArray()
		corridor.resize(w * h)
		locked = PackedByteArray()
		locked.resize(w * h)

	func in_bounds(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < w and y < h

	func get_c(x: int, y: int) -> int:
		return cells[y * w + x] if in_bounds(x, y) else MapGen.CH_WALL

	func set_c(x: int, y: int, c: int) -> void:
		if in_bounds(x, y):
			cells[y * w + x] = c

	func is_corridor(x: int, y: int) -> bool:
		return in_bounds(x, y) and corridor[y * w + x] == 1

	func is_corridor_floor(x: int, y: int) -> bool:
		return is_corridor(x, y) and get_c(x, y) == MapGen.CH_FLOOR

	func mark_corridor(x: int, y: int) -> void:
		if in_bounds(x, y):
			corridor[y * w + x] = 1

	func carve(x: int, y: int) -> void:
		set_c(x, y, MapGen.CH_FLOOR)
		mark_corridor(x, y)

	func is_locked(x: int, y: int) -> bool:
		return in_bounds(x, y) and locked[y * w + x] == 1

	func lock(x: int, y: int) -> void:
		if in_bounds(x, y):
			locked[y * w + x] = 1

	func walkable(x: int, y: int) -> bool:
		return MapGen._is_walkable_code(get_c(x, y))

	func find_c(c: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for i in cells.size():
			if cells[i] == c:
				out.append(Vector2i(i % w, i / w))
		return out

	func rows() -> PackedStringArray:
		var out := PackedStringArray()
		for y in h:
			out.append(cells.slice(y * w, (y + 1) * w).get_string_from_ascii())
		return out


static func _flood(g: Grid, starts: Array) -> PackedByteArray:
	var reached := PackedByteArray()
	reached.resize(g.w * g.h)
	var queue: Array[int] = []
	for s in starts:
		if reached[s] == 0 and _is_walkable_code(g.cells[s]):
			reached[s] = 1
			queue.append(s)
	var qi := 0
	while qi < queue.size():
		var i: int = queue[qi]
		qi += 1
		var x := i % g.w
		var y := i / g.w
		for d in DIRS:
			var nx := x + d.x
			var ny := y + d.y
			if not g.in_bounds(nx, ny):
				continue
			var ni := ny * g.w + nx
			if reached[ni] == 1 or not _is_walkable_code(g.cells[ni]):
				continue
			reached[ni] = 1
			queue.append(ni)
	return reached


static func _door_near(g: Grid, x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if (dx != 0 or dy != 0) and g.get_c(x + dx, y + dy) == CH_DOOR:
				return true
	return false


static func _in_room(r: Dictionary, x: int, y: int) -> bool:
	return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h


static func _room(x: int, y: int, w: int, h: int, kind: String) -> Dictionary:
	return {"x": x, "y": y, "w": w, "h": h, "kind": kind}


# ---------------------------------------------------------------------------
# Layout: central block, rings, spokes, regions
# ---------------------------------------------------------------------------

static func _seg(horizontal: bool, lane: int, a: int, b: int) -> Dictionary:
	return {"horizontal": horizontal, "lane": lane, "a": a, "b": b}


static func _stamp_block(g: Grid, bx: int, by: int, rooms: Array, segs: Array) -> void:
	for ty in BLOCK_H:
		var row: String = BLOCK_TEMPLATE[ty]
		for tx in BLOCK_W:
			g.set_c(bx + tx, by + ty, row.unicode_at(tx))
			g.lock(bx + tx, by + ty)
	# Inner ring corridor: template rows 1-2 / 16-17 and cols 1-2 / 27-28.
	for ty in range(1, 18):
		for tx in range(1, 29):
			if ty <= 2 or ty >= 16 or tx <= 2 or tx >= 27:
				g.mark_corridor(bx + tx, by + ty)
	segs.append(_seg(true, by + 1, bx + 1, bx + 28))
	segs.append(_seg(true, by + 16, bx + 1, bx + 28))
	segs.append(_seg(false, bx + 1, by + 3, by + 15))
	segs.append(_seg(false, bx + 27, by + 3, by + 15))
	rooms.append(_room(bx + 10, by + 4, 10, 6, "or"))
	rooms.append(_room(bx + 4, by + 4, 5, 6, "anteroom"))
	rooms.append(_room(bx + 21, by + 4, 5, 6, "anteroom"))
	rooms.append(_room(bx + 4, by + 11, 22, 4, "clockin"))


static func _carve_outer_ring(g: Grid, segs: Array) -> void:
	var w := g.w
	var h := g.h
	for x in range(1, w - 1):
		for y in [1, 2, h - 3, h - 2]:
			g.carve(x, y)
	for y in range(1, h - 1):
		for x in [1, 2, w - 3, w - 2]:
			g.carve(x, y)
	segs.append(_seg(true, 1, 1, w - 2))
	segs.append(_seg(true, h - 3, 1, w - 2))
	segs.append(_seg(false, 1, 3, h - 4))
	segs.append(_seg(false, w - 3, 3, h - 4))


static func _carve_spokes(g: Grid, bx: int, by: int, segs: Array) -> void:
	var w := g.w
	var h := g.h
	var sx := bx + 14
	var sy := by + 9
	for y in range(3, by + 1):
		g.carve(sx, y)
		g.carve(sx + 1, y)
	for y in range(by + BLOCK_H - 1, h - 3):
		g.carve(sx, y)
		g.carve(sx + 1, y)
	for x in range(3, bx + 1):
		g.carve(x, sy)
		g.carve(x, sy + 1)
	for x in range(bx + BLOCK_W - 1, w - 3):
		g.carve(x, sy)
		g.carve(x, sy + 1)
	segs.append(_seg(false, sx, 3, by))
	segs.append(_seg(false, sx, by + BLOCK_H - 1, h - 4))
	segs.append(_seg(true, sy, 3, bx))
	segs.append(_seg(true, sy, bx + BLOCK_W - 1, w - 4))


static func _region(x0: int, y0: int, x1: int, y1: int, wall: Dictionary, open: Dictionary) -> Dictionary:
	return {"x0": x0, "y0": y0, "x1": x1, "y1": y1, "wall": wall, "open": open}


static func _sides(n: bool, s: bool, e: bool, w: bool) -> Dictionary:
	return {"n": n, "s": s, "e": e, "w": w}


static func _build_arms(g: Grid, bx: int, by: int) -> Array:
	var w := g.w
	var h := g.h
	var sx0 := bx + 14
	var sx1 := bx + 15
	var sy0 := by + 9
	var sy1 := by + 10
	var bxe := bx + BLOCK_W - 1
	var bye := by + BLOCK_H - 1
	return [
		# top-left
		_region(3, 3, sx0 - 1, by - 1, _sides(true, false, true, true), _sides(true, false, true, true)),
		_region(3, by, bx - 1, sy0 - 1, _sides(true, true, false, true), _sides(false, true, false, true)),
		# top-right
		_region(sx1 + 1, 3, w - 4, by - 1, _sides(true, false, true, true), _sides(true, false, true, true)),
		_region(bxe + 1, by, w - 4, sy0 - 1, _sides(true, true, true, false), _sides(false, true, true, false)),
		# bottom-left
		_region(3, sy1 + 1, bx - 1, bye, _sides(true, true, false, true), _sides(true, false, false, true)),
		_region(3, bye + 1, sx0 - 1, h - 4, _sides(false, true, true, true), _sides(false, true, true, true)),
		# bottom-right
		_region(bxe + 1, sy1 + 1, w - 4, bye, _sides(true, true, true, false), _sides(true, false, true, false)),
		_region(sx1 + 1, bye + 1, w - 4, h - 4, _sides(false, true, true, true), _sides(false, true, true, true)),
	]


static func _clampi(v: int, lo: int, hi: int) -> int:
	return lo if v < lo else (hi if v > hi else v)


static func _with(sides: Dictionary, key: String, value: bool) -> Dictionary:
	var d := sides.duplicate()
	d[key] = value
	return d


static func _split_region(g: Grid, r: Dictionary, rng: Rng, segs: Array, out: Array) -> void:
	var rw: int = r.x1 - r.x0 + 1
	var rh: int = r.y1 - r.y0 + 1
	if rw <= 13 or rh <= 13:
		out.append(r)
		return
	var open: Dictionary = r.open
	var wall: Dictionary = r.wall
	var can_v: bool = open.n or open.s
	var can_h: bool = open.w or open.e
	var vertical: bool
	if can_v and can_h:
		vertical = rng.chance(0.5)
	elif can_v:
		vertical = true
	elif can_h:
		vertical = false
	else:
		vertical = rng.chance(0.5)

	if vertical:
		var cx := _clampi(r.x0 + int((rw - 2) / 2.0) + rng.rint(-2, 2), r.x0 + 6, r.x1 - 7)
		var top: int = r.y0 if (open.n or not wall.n) else r.y0 + 1
		var bot: int = r.y1 if (open.s or not wall.s) else r.y1 - 1
		for y in range(top, bot + 1):
			g.carve(cx, y)
			g.carve(cx + 1, y)
		segs.append(_seg(false, cx, top, bot))
		_split_region(g, _region(r.x0, r.y0, cx - 1, r.y1, _with(wall, "e", true), _with(open, "e", true)), rng, segs, out)
		_split_region(g, _region(cx + 2, r.y0, r.x1, r.y1, _with(wall, "w", true), _with(open, "w", true)), rng, segs, out)
	else:
		var cy := _clampi(r.y0 + int((rh - 2) / 2.0) + rng.rint(-2, 2), r.y0 + 6, r.y1 - 7)
		var left: int = r.x0 if (open.w or not wall.w) else r.x0 + 1
		var right: int = r.x1 if (open.e or not wall.e) else r.x1 - 1
		for x in range(left, right + 1):
			g.carve(x, cy)
			g.carve(x, cy + 1)
		segs.append(_seg(true, cy, left, right))
		_split_region(g, _region(r.x0, r.y0, r.x1, cy - 1, _with(wall, "s", true), _with(open, "s", true)), rng, segs, out)
		_split_region(g, _region(r.x0, cy + 2, r.x1, r.y1, _with(wall, "n", true), _with(open, "n", true)), rng, segs, out)


# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

static func _partition(total: int, rng: Rng) -> Array[int]:
	var out: Array[int] = []
	var rem := total
	while rem >= 4:
		if rem < 9 or (rem == 9 and rng.chance(0.5)):
			out.append(rem)
			break
		var len_ := rng.rint(4, mini(9, rem - 5))
		out.append(len_)
		rem -= len_ + 1
	return out


static func _carve_rooms(g: Grid, leaves: Array, rng: Rng, rooms: Array) -> void:
	for r in leaves:
		var wall: Dictionary = r.wall
		var open: Dictionary = r.open
		var ix0: int = r.x0 + (1 if wall.w else 0)
		var ix1: int = r.x1 - (1 if wall.e else 0)
		var iy0: int = r.y0 + (1 if wall.n else 0)
		var iy1: int = r.y1 - (1 if wall.s else 0)
		var iw := ix1 - ix0 + 1
		var ih := iy1 - iy0 + 1
		if iw < 4 or ih < 4:
			continue
		var along_x := iw >= ih
		var depth := ih if along_x else iw
		var length := iw if along_x else ih
		var two_rows: bool = depth > 8 and ((open.n and open.s) if along_x else (open.w and open.e))
		var strips: Array = []
		if two_rows:
			var d1 := int((depth - 1) / 2.0)
			strips.append([0, d1])
			strips.append([d1 + 1, depth - 1 - d1])
		else:
			strips.append([0, depth])
		for strip in strips:
			var off: int = strip[0]
			var d: int = strip[1]
			var pos := 0
			for len_ in _partition(length, rng):
				var room: Dictionary
				if along_x:
					room = _room(ix0 + pos, iy0 + off, len_, d, "empty")
				else:
					room = _room(ix0 + off, iy0 + pos, d, len_, "empty")
				for y in range(room.y, room.y + room.h):
					for x in range(room.x, room.x + room.w):
						g.set_c(x, y, CH_FLOOR)
				rooms.append(room)
				pos += len_ + 1


# ---------------------------------------------------------------------------
# Doors
# ---------------------------------------------------------------------------

## Perimeter wall tiles with the outward direction. Returns [[wx, wy, dx, dy], ...].
static func _perimeter(r: Dictionary) -> Array:
	var out: Array = []
	for x in range(r.x, r.x + r.w):
		out.append([x, r.y - 1, 0, -1])
		out.append([x, r.y + r.h, 0, 1])
	for y in range(r.y, r.y + r.h):
		out.append([r.x - 1, y, -1, 0])
		out.append([r.x + r.w, y, 1, 0])
	return out


## Candidate door tiles: unlocked wall with room floor inside and corridor floor directly outside.
static func _door_spots(g: Grid, r: Dictionary) -> Array:
	var out: Array = []
	for p in _perimeter(r):
		var wx: int = p[0]
		var wy: int = p[1]
		var dx: int = p[2]
		var dy: int = p[3]
		if g.get_c(wx, wy) != CH_WALL or g.is_locked(wx, wy):
			continue
		if not g.is_corridor_floor(wx + dx, wy + dy):
			continue
		if g.get_c(wx - dx, wy - dy) != CH_FLOOR:
			continue
		out.append({"x": wx, "y": wy, "ix": wx - dx, "iy": wy - dy})
	return out


static func _room_doors(g: Grid, r: Dictionary) -> Array:
	var out: Array = []
	for p in _perimeter(r):
		var wx: int = p[0]
		var wy: int = p[1]
		if g.get_c(wx, wy) == CH_DOOR:
			out.append({"x": wx, "y": wy, "ix": wx - p[2], "iy": wy - p[3]})
	return out


static func _place_doors(g: Grid, rooms: Array, rng: Rng) -> void:
	for r in rooms:
		var spots: Array = []
		for s in _door_spots(g, r):
			if not _door_near(g, s.x, s.y):
				spots.append(s)
		if spots.is_empty():
			continue
		var first: Dictionary = rng.pick(spots)
		g.set_c(first.x, first.y, CH_DOOR)
		if not rng.chance(0.45):
			continue
		var remaining: Array = []
		for s in spots:
			if not _door_near(g, s.x, s.y):
				remaining.append(s)
		var fdx: int = first.x - first.ix
		var fdy: int = first.y - first.iy
		var other: Array = []
		for s in remaining:
			if not (s.x - s.ix == fdx and s.y - s.iy == fdy):
				other.append(s)
		var pool: Array = other
		if pool.is_empty():
			pool = []
			for s in remaining:
				if abs(s.x - first.x) + abs(s.y - first.y) >= 3:
					pool.append(s)
		if not pool.is_empty():
			var d: Dictionary = rng.pick(pool)
			g.set_c(d.x, d.y, CH_DOOR)


# ---------------------------------------------------------------------------
# Furniture
# ---------------------------------------------------------------------------

static func _interior_connected(g: Grid, r: Dictionary) -> bool:
	var total := 0
	var start := -1
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if g.walkable(x, y):
				total += 1
				if start < 0:
					start = y * g.w + x
	if total == 0:
		return true
	var reached := PackedByteArray()
	reached.resize(g.w * g.h)
	var queue: Array[int] = [start]
	reached[start] = 1
	var count := 0
	var qi := 0
	while qi < queue.size():
		var i: int = queue[qi]
		qi += 1
		count += 1
		var x := i % g.w
		var y := i / g.w
		for d in DIRS:
			var nx := x + d.x
			var ny := y + d.y
			if not _in_room(r, nx, ny) or not g.walkable(nx, ny):
				continue
			var ni := ny * g.w + nx
			if reached[ni] == 1:
				continue
			reached[ni] = 1
			queue.append(ni)
	return count == total


static func _count_walkable(g: Grid, r: Dictionary) -> int:
	var n := 0
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if g.walkable(x, y):
				n += 1
	return n


static func _furnish(g: Grid, rooms: Array, rng: Rng) -> void:
	for r in rooms:
		var roll := rng.nextf()
		r.kind = "ward" if roll < 0.4 else ("storage" if roll < 0.65 else ("office" if roll < 0.8 else "empty"))
		if r.kind == "empty":
			continue

		var keep := {}
		for d in _room_doors(g, r):
			keep[d.iy * g.w + d.ix] = true

		var x0: int = r.x
		var y0: int = r.y
		var x1: int = r.x + r.w - 1
		var y1: int = r.y + r.h - 1

		if r.kind == "ward":
			var bed_rows: Array[int] = [y0]
			var y := y0 + 3
			while y <= y1 - 3:
				bed_rows.append(y)
				y += 3
			if r.h >= 4:
				bed_rows.append(y1)
			var start := x0 + rng.rint(0, 1)
			for by in bed_rows:
				var bx := start
				while bx <= x1:
					_place_furniture(g, r, keep, bx, by, CH_BED)
					bx += 2
		elif r.kind == "storage":
			# GDScript evaluates call arguments before the callee's base expression, so the
			# shuffle and the count are drawn in two statements to match the TS draw order.
			var all_sides: Array = rng.shuffle([0, 1, 2, 3])
			var sides: Array = all_sides.slice(0, rng.rint(2, 4))
			for side in sides:
				if side == 0:
					for x in range(x0, x1 + 1):
						if not rng.chance(0.2):
							_place_furniture(g, r, keep, x, y0, CH_CAB)
				if side == 1:
					for x in range(x0, x1 + 1):
						if not rng.chance(0.2):
							_place_furniture(g, r, keep, x, y1, CH_CAB)
				if side == 2:
					for y in range(y0, y1 + 1):
						if not rng.chance(0.2):
							_place_furniture(g, r, keep, x0, y, CH_CAB)
				if side == 3:
					for y in range(y0, y1 + 1):
						if not rng.chance(0.2):
							_place_furniture(g, r, keep, x1, y, CH_CAB)
		elif r.kind == "office":
			var n := rng.rint(2, 4)
			var corners: Array = rng.shuffle([[x0, y0], [x1, y0], [x0, y1], [x1, y1]])
			for c in corners:
				if n <= 0:
					break
				if _place_furniture(g, r, keep, c[0], c[1], CH_CAB):
					n -= 1
			if n > 0:
				var px := rng.rint(x0, x1)
				var py := y0 if rng.chance(0.5) else y1
				_place_furniture(g, r, keep, px, py, CH_CAB)


static func _place_furniture(g: Grid, r: Dictionary, keep: Dictionary, x: int, y: int, ch: int) -> bool:
	if not _in_room(r, x, y) or keep.has(y * g.w + x) or g.get_c(x, y) != CH_FLOOR:
		return false
	g.set_c(x, y, ch)
	if _interior_connected(g, r):
		return true
	g.set_c(x, y, CH_FLOOR)
	return false


# ---------------------------------------------------------------------------
# Connectivity repair
# ---------------------------------------------------------------------------

static func _fix_connectivity(g: Grid) -> void:
	var n := g.w * g.h
	var ps := g.find_c(CH_PLAYER)
	if ps.is_empty():
		return
	var start: int = ps[0].y * g.w + ps[0].x
	for guard in 1000:
		var reach := _flood(g, [start])
		var pocket_start := -1
		for i in n:
			if reach[i] == 0 and _is_walkable_code(g.cells[i]):
				pocket_start = i
				break
		if pocket_start < 0:
			return
		var pocket_mask := _flood(g, [pocket_start])
		var pocket: Array[int] = []
		for i in n:
			if pocket_mask[i] == 1:
				pocket.append(i)

		var punched := false
		for i in pocket:
			var x := i % g.w
			var y := i / g.w
			for d in DIRS:
				var wx := x + d.x
				var wy := y + d.y
				if wx <= 0 or wy <= 0 or wx >= g.w - 1 or wy >= g.h - 1:
					continue
				if g.get_c(wx, wy) != CH_WALL or g.is_locked(wx, wy) or _door_near(g, wx, wy):
					continue
				var ox := wx + d.x
				var oy := wy + d.y
				if not g.in_bounds(ox, oy) or reach[oy * g.w + ox] == 0:
					continue
				g.set_c(wx, wy, CH_DOOR)
				punched = true
				break
			if punched:
				break
		if not punched:
			for i in pocket:
				g.cells[i] = CH_WALL


# ---------------------------------------------------------------------------
# Spawn candidates
# ---------------------------------------------------------------------------

static func _tool_candidates(g: Grid, r: Dictionary) -> Array:
	var out: Array = []
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if g.get_c(x, y) == CH_FLOOR and not _door_near(g, x, y):
				out.append(Vector2i(x, y))
	return out


static func _place_tools(g: Grid, rooms: Array, rng: Rng, min_total: int) -> int:
	var total := 0
	for r in rooms:
		var c: Array = rng.shuffle(_tool_candidates(g, r))
		var n := mini(c.size(), rng.rint(1, 3))
		for i in n:
			g.set_c(c[i].x, c[i].y, CH_TOOL)
		total += n
	for pass_ in 20:
		if total >= min_total:
			break
		var placed := false
		for r in rooms:
			if total >= min_total:
				break
			var c := _tool_candidates(g, r)
			if c.is_empty():
				continue
			var t: Vector2i = rng.pick(c)
			g.set_c(t.x, t.y, CH_TOOL)
			total += 1
			placed = true
		if not placed:
			break
	return total


static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


static func _place_monsters(g: Grid, rng: Rng, min_dist: int, want: int) -> int:
	var ps := g.find_c(CH_PLAYER)
	var cands: Array = []
	for y in g.h:
		for x in g.w:
			if not g.is_corridor_floor(x, y):
				continue
			var p := Vector2i(x, y)
			var ok := true
			for s in ps:
				if _manhattan(p, s) < min_dist:
					ok = false
					break
			if ok:
				cands.append(p)
	if cands.is_empty():
		return 0
	var chosen: Array = [rng.pick(cands)]
	while chosen.size() < want and chosen.size() < cands.size():
		var best: Vector2i = Vector2i.ZERO
		var has_best := false
		var best_d := -1
		for c in cands:
			var d := 1 << 30
			for k in chosen:
				d = mini(d, _manhattan(c, k))
			if d > best_d:
				best_d = d
				best = c
				has_best = true
		if not has_best or best_d <= 0:
			break
		chosen.append(best)
	for c in chosen:
		g.set_c(c.x, c.y, CH_MON)
	return chosen.size()


# ---------------------------------------------------------------------------
# Clutter (ported from map.ts addClutter)
# ---------------------------------------------------------------------------

static func _is_clutter_code(c: int) -> bool:
	return PROP_CHARS.has(char(c))


## Scatter hospital clutter along corridor walls using its own PRNG stream, so the main
## generation stream is untouched. A placement is reverted when it would break global
## connectivity or wall a bed in - the ASCII stays valid either way.
static func _add_clutter(g: Grid, seed_: int, density: float) -> Array[Dictionary]:
	var rng := Rng.new((seed_ ^ 0x9e3779b9) & 0xFFFFFFFF)
	var props: Array[Dictionary] = []
	for y in range(1, g.h - 1):
		for x in range(1, g.w - 1):
			if g.get_c(x, y) != CH_FLOOR:
				continue
			if rng.nextf() > density:
				continue
			var wall_n := g.get_c(x, y - 1) == CH_WALL
			var wall_s := g.get_c(x, y + 1) == CH_WALL
			var wall_w := g.get_c(x - 1, y) == CH_WALL
			var wall_e := g.get_c(x + 1, y) == CH_WALL
			if not (wall_n or wall_s or wall_w or wall_e):
				continue
			var clear := true
			for dy in range(-2, 3):
				if not clear:
					break
				for dx in range(-2, 3):
					var c := g.get_c(x + dx, y + dy)
					if c == CH_DOOR or c == CH_PLAYER or c == CH_CLOCK or c == CH_POD \
							or c == CH_TABLE or c == CH_TOOL or c == CH_MON or _is_clutter_code(c):
						clear = false
						break
			if not clear:
				continue
			var open_across := (wall_n and g.get_c(x, y + 1) == CH_FLOOR) \
					or (wall_s and g.get_c(x, y - 1) == CH_FLOOR) \
					or (wall_w and g.get_c(x + 1, y) == CH_FLOOR) \
					or (wall_e and g.get_c(x - 1, y) == CH_FLOOR)
			if not open_across:
				continue
			var kind_char: String = CLUTTER_KINDS[int(floor(rng.nextf() * float(CLUTTER_KINDS.size())))]
			var code := kind_char.unicode_at(0)
			g.set_c(x, y, code)
			if not _clutter_ok(g, x, y):
				g.set_c(x, y, CH_FLOOR)
				continue
			# Face away from the wall it leans on.
			var rot := 0.0
			if wall_n:
				rot = PI / 2.0
			elif wall_s:
				rot = -PI / 2.0
			elif wall_w:
				rot = 0.0
			else:
				rot = PI
			props.append({"tile": Vector2i(x, y), "kind": PROP_CHARS[kind_char], "rot": rot})
	return props


## A clutter tile is acceptable when the map stays fully connected and no neighbouring bed
## is left with fewer than two walkable neighbours.
static func _clutter_ok(g: Grid, x: int, y: int) -> bool:
	for d in DIRS:
		if g.get_c(x + d.x, y + d.y) != CH_BED:
			continue
		var open := 0
		for e in DIRS:
			if g.walkable(x + d.x + e.x, y + d.y + e.y):
				open += 1
		if open < 2:
			return false
	var ps := g.find_c(CH_PLAYER)
	if ps.is_empty():
		return true
	var reach := _flood(g, [ps[0].y * g.w + ps[0].x])
	for i in g.cells.size():
		if _is_walkable_code(g.cells[i]) and reach[i] == 0:
			return false
	return true


# ---------------------------------------------------------------------------
# Special rooms and containers (Godot-only passes, their own PRNG streams)
# ---------------------------------------------------------------------------

## Directions from a room tile toward a wall that bounds the room.
static func _wall_dirs(g: Grid, r: Dictionary, x: int, y: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in DIRS:
		if not _in_room(r, x + d.x, y + d.y) and g.get_c(x + d.x, y + d.y) == CH_WALL:
			out.append(d)
	return out


## Wall directions at which a solid container could stand on (x, y): floor tile, no door
## nearby, and the tile in front of it (away from the wall) is walkable room floor.
static func _solid_dirs(g: Grid, r: Dictionary, x: int, y: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if g.get_c(x, y) != CH_FLOOR or _door_near(g, x, y):
		return out
	for d in _wall_dirs(g, r, x, y):
		var fx := x - d.x
		var fy := y - d.y
		if _in_room(r, fx, fy) and g.walkable(fx, fy):
			out.append(d)
	return out


static func _room_capacity(g: Grid, r: Dictionary) -> int:
	var n := 0
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if not _solid_dirs(g, r, x, y).is_empty():
				n += 1
	return n


static func _room_center(r: Dictionary) -> Vector2:
	return Vector2(r.x + r.w * 0.5, r.y + r.h * 0.5)


## Turn some generated rooms into pharmacies, maintenance rooms and nurse stations, spread
## apart from each other. Guarantees SPECIAL_MIN whenever enough rooms have wall space.
static func _assign_special_rooms(g: Grid, rooms: Array, seed_: int) -> void:
	var rng := Rng.new((seed_ ^ 0x2545f491) & 0xFFFFFFFF)
	var want: Array[String] = ["pharmacy", "maintenance", "nurse_station", "nurse_station"]
	if rng.chance(0.35):
		want.append("pharmacy")
	if rng.chance(0.3):
		want.append("maintenance")
	if rng.chance(0.45):
		want.append("nurse_station")
	var prefs := {
		"pharmacy": {"storage": 1.0, "office": 0.85, "empty": 0.8, "ward": 0.35},
		"maintenance": {"storage": 1.0, "empty": 0.95, "office": 0.8, "ward": 0.35},
		"nurse_station": {"empty": 1.0, "office": 1.0, "ward": 0.6, "storage": 0.45},
	}
	var cap: Array[int] = []
	for r in rooms:
		cap.append(_room_capacity(g, r))
	var chosen: Array = []
	for kind in want:
		var best := -1
		var best_s := -1.0
		var pref: Dictionary = prefs[kind]
		for i in rooms.size():
			var r: Dictionary = rooms[i]
			if not pref.has(r.kind) or cap[i] < 1:
				continue
			var md := 40.0
			for o in chosen:
				md = minf(md, _room_center(r).distance_to(_room_center(o)))
			var s: float = float(pref[r.kind]) * (1.0 if cap[i] >= 2 else 0.3) * (md + 6.0) * (0.75 + 0.5 * rng.nextf())
			if s > best_s:
				best_s = s
				best = i
		if best >= 0:
			rooms[best].kind = kind
			chosen.append(rooms[best])


static func _container_allowed(type: String, room_kind: String) -> bool:
	var def: Dictionary = ItemsData.CONTAINER_TYPES.get(type, {})
	return def.has("rooms") and (def.rooms as Array).has(room_kind)


static func _room_container_plan(kind: String, rng: Rng) -> Array[String]:
	var out: Array[String] = []
	match kind:
		"pharmacy":
			for i in rng.rint(2, 3):
				out.append("med_fridge")
		"storage":
			for i in rng.rint(1, 2):
				out.append(rng.pick(["med_fridge", "drawer_unit", "pegboard"]))
		"maintenance":
			for i in rng.rint(1, 2):
				out.append("drawer_unit")
			for i in rng.rint(1, 2):
				out.append("pegboard")
		"nurse_station":
			for i in rng.rint(1, 2):
				out.append("station_drawers")
			out.append("trauma_bag")
		"ward":
			if rng.chance(0.4):
				out.append("station_drawers")
	# Solid furniture first, so wall-mounted pieces take what wall is left.
	var solid: Array[String] = []
	var mounted: Array[String] = []
	for t in out:
		if WALL_MOUNTED.has(t):
			mounted.append(t)
		else:
			solid.append(t)
	solid.append_array(mounted)
	return solid


static func _site(x: int, y: int, d: Vector2i, type: String, room_kind: String) -> Dictionary:
	return {"tile": Vector2i(x, y), "wall": d, "type": type, "room_kind": room_kind}


static func _beds_ok(g: Grid, x: int, y: int) -> bool:
	for d in DIRS:
		if g.get_c(x + d.x, y + d.y) != CH_BED:
			continue
		var open := 0
		for e in DIRS:
			if g.walkable(x + d.x + e.x, y + d.y + e.y):
				open += 1
		if open < 2:
			return false
	return true


static func _put_solid(g: Grid, r: Dictionary, type: String, rng: Rng, sites: Array, fronts: Dictionary) -> bool:
	var ch: int = String(CONTAINER_CHARS[type]).unicode_at(0)
	var cands: Array = []
	var preferred: Array = []
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if fronts.has(y * g.w + x):
				continue
			for d in _solid_dirs(g, r, x, y):
				var c := [x, y, d]
				cands.append(c)
				# A second counter lines up with the first one along the same wall.
				if type == "station_drawers":
					for s in sites:
						if s.type == type and s.wall == d and _in_room(r, s.tile.x, s.tile.y) \
								and absi(s.tile.x - x) + absi(s.tile.y - y) == 1:
							preferred.append(c)
	rng.shuffle(cands)
	var order: Array = preferred + cands
	for c in order:
		var x: int = c[0]
		var y: int = c[1]
		var d: Vector2i = c[2]
		if g.get_c(x, y) != CH_FLOOR or not g.walkable(x - d.x, y - d.y):
			continue
		g.set_c(x, y, ch)
		if _interior_connected(g, r) and _beds_ok(g, x, y):
			fronts[(y - d.y) * g.w + (x - d.x)] = true
			sites.append(_site(x, y, d, type, r.kind))
			return true
		g.set_c(x, y, CH_FLOOR)
	return false


static func _put_mounted(g: Grid, r: Dictionary, type: String, rng: Rng, sites: Array, mounts: Dictionary) -> bool:
	var cands: Array = []
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if g.get_c(x, y) != CH_FLOOR or _door_near(g, x, y) or mounts.has(y * g.w + x):
				continue
			for d in _wall_dirs(g, r, x, y):
				if _in_room(r, x - d.x, y - d.y) and g.walkable(x - d.x, y - d.y):
					cands.append([x, y, d])
	rng.shuffle(cands)
	for c in cands:
		mounts[c[1] * g.w + c[0]] = true
		sites.append(_site(c[0], c[1], c[2], type, r.kind))
		return true
	return false


## Plan every container site. Returns [{tile, wall, type, room_kind}], where `wall` points
## from the tile toward the wall the container stands against.
static func _place_containers(g: Grid, rooms: Array, seed_: int) -> Array:
	var rng := Rng.new((seed_ ^ 0x68e31da4) & 0xFFFFFFFF)
	var sites: Array = []
	var fronts := {}
	var mounts := {}
	for r in rooms:
		for type in _room_container_plan(r.kind, rng):
			if not _container_allowed(type, r.kind):
				continue
			if WALL_MOUNTED.has(type):
				_put_mounted(g, r, type, rng, sites, mounts)
			else:
				_put_solid(g, r, type, rng, sites, fronts)
	# Trauma bags on corridor walls, well apart.
	if _container_allowed("trauma_bag", "corridor"):
		var cands: Array = []
		for y in range(1, g.h - 1):
			for x in range(1, g.w - 1):
				if not g.is_corridor_floor(x, y) or _door_near(g, x, y):
					continue
				var near_prop := false
				for d in DIRS:
					if _is_clutter_code(g.get_c(x + d.x, y + d.y)):
						near_prop = true
				if near_prop:
					continue
				for d in DIRS:
					if g.get_c(x + d.x, y + d.y) == CH_WALL and g.walkable(x - d.x, y - d.y):
						cands.append([x, y, d])
						break
		rng.shuffle(cands)
		var want := rng.rint(4, 6)
		var placed: Array[Vector2i] = []
		for c in cands:
			if placed.size() >= want:
				break
			var p := Vector2i(c[0], c[1])
			var ok := true
			for q in placed:
				if _manhattan(p, q) < 12:
					ok = false
					break
			if ok:
				placed.append(p)
				sites.append(_site(p.x, p.y, c[2], "trauma_bag", "corridor"))
	return sites


# ---------------------------------------------------------------------------
# Lights
# ---------------------------------------------------------------------------

static func _nearest_walkable_in_room(g: Grid, r: Dictionary, cx: int, cy: int) -> Variant:
	var best: Vector2i = Vector2i.ZERO
	var has := false
	var best_d := 1 << 30
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if not g.walkable(x, y):
				continue
			var d: int = abs(x - cx) + abs(y - cy)
			if d < best_d:
				best_d = d
				best = Vector2i(x, y)
				has = true
	return best if has else null


static func _place_lights(g: Grid, bx: int, by: int, rooms: Array, segs: Array) -> Array[Vector2i]:
	var lights: Array[Vector2i] = []
	var seen := {}
	var add := func(x: int, y: int) -> void:
		if not g.walkable(x, y):
			return
		var key := y * g.w + x
		if seen.has(key):
			return
		seen[key] = true
		lights.append(Vector2i(x, y))
	for r in rooms:
		var p = _nearest_walkable_in_room(g, r, r.x + int((r.w - 1) / 2.0), r.y + int((r.h - 1) / 2.0))
		if p != null:
			add.call(p.x, p.y)
	add.call(bx + 6, by + 6)
	add.call(bx + 23, by + 6)
	add.call(bx + 12, by + 7)
	add.call(bx + 17, by + 7)
	add.call(bx + 14, by + 12)
	for s in segs:
		var len_: int = s.b - s.a + 1
		if len_ <= 0:
			continue
		var n: int = maxi(1, int(round(float(len_) / 4.5)))
		for i in n:
			var p: int = s.a + int(floor((float(i) + 0.5) * float(len_) / float(n)))
			var lane: int = s.lane + (i % 2)
			if s.horizontal:
				add.call(p, lane)
			else:
				add.call(lane, p)
	return lights


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Generate a hospital. Returns:
##   rows: PackedStringArray, lights: Array[Vector2i], rooms: Array[Dictionary],
##   props: Array[Dictionary] ({tile, kind, rot}), seed: int, width: int, height: int
static func generate(seed: int, width := DEFAULT_WIDTH, height := DEFAULT_HEIGHT) -> Dictionary:
	var w := int(width)
	var h := int(height)
	assert(w >= MIN_WIDTH and h >= MIN_HEIGHT, "map must be at least %dx%d" % [MIN_WIDTH, MIN_HEIGHT])
	var rng := Rng.new(seed)
	var g := Grid.new(w, h)
	var bx := int((w - BLOCK_W) / 2.0)
	var by := int((h - BLOCK_H) / 2.0)
	var segs: Array = []
	var template_rooms: Array = []

	_stamp_block(g, bx, by, template_rooms, segs)
	_carve_outer_ring(g, segs)
	_carve_spokes(g, bx, by, segs)

	var leaves: Array = []
	for arm in _build_arms(g, bx, by):
		_split_region(g, arm, rng, segs, leaves)

	var gen_rooms: Array = []
	_carve_rooms(g, leaves, rng, gen_rooms)
	_place_doors(g, gen_rooms, rng)
	_furnish(g, gen_rooms, rng)
	_fix_connectivity(g)
	var live_rooms: Array = []
	for r in gen_rooms:
		if _count_walkable(g, r) > 0:
			live_rooms.append(r)

	_place_tools(g, live_rooms, rng, MIN_TOOLS)
	_place_monsters(g, rng, MONSTER_MIN_DIST, WANT_MONSTERS)
	# Clutter before lights so no fixture lands on a tile a prop just made solid.
	var props := _add_clutter(g, seed, CLUTTER_DENSITY)
	_assign_special_rooms(g, live_rooms, seed)
	var containers := _place_containers(g, live_rooms, seed)
	var lights := _place_lights(g, bx, by, live_rooms, segs)

	var rooms: Array[Dictionary] = []
	for r in template_rooms:
		rooms.append(r)
	for r in live_rooms:
		rooms.append(r)

	return {
		"seed": seed,
		"width": w,
		"height": h,
		"rows": g.rows(),
		"lights": lights,
		"rooms": rooms,
		"props": props,
		"containers": containers,
	}


## Returns a list of problems; empty when the map is valid.
static func validate(gen: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var rows: PackedStringArray = gen.get("rows", PackedStringArray())
	if rows.is_empty():
		problems.append("map has no rows")
		return problems
	var h := rows.size()
	var w := rows[0].length()
	for i in h:
		if rows[i].length() != w:
			problems.append("row %d has length %d, expected %d" % [i, rows[i].length(), w])
	if not problems.is_empty():
		return problems

	var at := func(x: int, y: int) -> String:
		if x < 0 or y < 0 or x >= w or y >= h:
			return "#"
		return rows[y][x]
	var walk := func(x: int, y: int) -> bool:
		if x < 0 or y < 0 or x >= w or y >= h:
			return false
		return is_walkable_char(rows[y][x])

	var pos := {}
	var legend := LEGEND_CHARS
	for y in h:
		var row := rows[y]
		for x in w:
			var c := row[x]
			if not legend.contains(c) and not PROP_CHARS.has(c):
				problems.append("unknown tile '%s' at %d,%d" % [c, x, y])
			if not pos.has(c):
				pos[c] = []
			pos[c].append(Vector2i(x, y))
	var of := func(c: String) -> Array:
		return pos.get(c, [])

	for x in w:
		if at.call(x, 0) != "#":
			problems.append("border not wall at %d,0" % x)
		if at.call(x, h - 1) != "#":
			problems.append("border not wall at %d,%d" % [x, h - 1])
	for y in h:
		if at.call(0, y) != "#":
			problems.append("border not wall at 0,%d" % y)
		if at.call(w - 1, y) != "#":
			problems.append("border not wall at %d,%d" % [w - 1, y])

	var os: Array = of.call("O")
	if os.size() != 2:
		problems.append("expected exactly 2 'O', found %d" % os.size())
	elif os[0].y != os[1].y or abs(os[0].x - os[1].x) != 1:
		problems.append("'O' tiles are not horizontally adjacent")
	if of.call("K").size() != 1:
		problems.append("expected exactly 1 'K', found %d" % of.call("K").size())
	if of.call("C").size() != 1:
		problems.append("expected exactly 1 'C', found %d" % of.call("C").size())
	var ps: Array = of.call("P")
	if ps.size() != 4:
		problems.append("expected exactly 4 'P', found %d" % ps.size())

	# Rooms.
	var kind_count := {}
	var rooms: Array = gen.get("rooms", [])
	for r in rooms:
		kind_count[r.kind] = kind_count.get(r.kind, 0) + 1
		if r.w < 1 or r.h < 1 or r.x < 1 or r.y < 1 or r.x + r.w > w - 1 or r.y + r.h > h - 1:
			problems.append("room %s at %d,%d %dx%d is out of bounds" % [r.kind, r.x, r.y, r.w, r.h])
			continue
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if at.call(x, y) == "#":
					problems.append("room %s at %d,%d contains a wall at %d,%d" % [r.kind, r.x, r.y, x, y])
	if kind_count.get("or", 0) != 1:
		problems.append("expected 1 'or' room, found %d" % kind_count.get("or", 0))
	if kind_count.get("clockin", 0) != 1:
		problems.append("expected 1 'clockin' room, found %d" % kind_count.get("clockin", 0))
	if kind_count.get("anteroom", 0) != 2:
		problems.append("expected 2 'anteroom' rooms, found %d" % kind_count.get("anteroom", 0))
	var clockin: Variant = null
	var or_room: Variant = null
	for r in rooms:
		if r.kind == "clockin" and clockin == null:
			clockin = r
		if r.kind == "or" and or_room == null:
			or_room = r
	if clockin != null:
		var group: Array = []
		group.append_array(ps)
		group.append_array(of.call("K"))
		group.append_array(of.call("C"))
		for p in group:
			if not _in_room(clockin, p.x, p.y):
				problems.append("'%s' at %d,%d is outside the clock-in room" % [at.call(p.x, p.y), p.x, p.y])
	if or_room != null:
		for p in os:
			if not _in_room(or_room, p.x, p.y):
				problems.append("'O' at %d,%d is outside the OR" % [p.x, p.y])

	# Tool candidates.
	var ts: Array = of.call("T")
	if ts.size() < MIN_TOOLS:
		problems.append("expected >= %d 'T', found %d" % [MIN_TOOLS, ts.size()])
	for t in ts:
		var inside := false
		for r in rooms:
			if GENERATED_KINDS.has(r.kind) and _in_room(r, t.x, t.y):
				inside = true
				break
		if not inside:
			problems.append("'T' at %d,%d is not inside a generated room" % [t.x, t.y])

	# Monster candidates.
	var ms: Array = of.call("M")
	if ms.size() < MIN_MONSTERS:
		problems.append("expected >= %d 'M', found %d" % [MIN_MONSTERS, ms.size()])
	for m in ms:
		for r in rooms:
			if _in_room(r, m.x, m.y):
				problems.append("'M' at %d,%d is inside a room" % [m.x, m.y])
				break
		for p in ps:
			var d := _manhattan(m, p)
			if d < MONSTER_MIN_DIST:
				problems.append("'M' at %d,%d is only %d tiles from 'P' at %d,%d" % [m.x, m.y, d, p.x, p.y])

	# Doors.
	var bx := int((w - BLOCK_W) / 2.0)
	var by := int((h - BLOCK_H) / 2.0)
	var in_block := func(x: int, y: int) -> bool:
		return x >= bx and x < bx + BLOCK_W and y >= by and y < by + BLOCK_H
	for d in of.call("+"):
		var ns: bool = walk.call(d.x, d.y - 1) and walk.call(d.x, d.y + 1)
		var ew: bool = walk.call(d.x - 1, d.y) and walk.call(d.x + 1, d.y)
		if not ns and not ew:
			problems.append("door at %d,%d lacks walkable tiles on two opposite sides" % [d.x, d.y])
		for off in [Vector2i(1, 0), Vector2i(0, 1)]:
			var nx: int = d.x + off.x
			var ny: int = d.y + off.y
			if at.call(nx, ny) == "+" and not (in_block.call(d.x, d.y) and in_block.call(nx, ny)):
				problems.append("doors at %d,%d and %d,%d are adjacent" % [d.x, d.y, nx, ny])

	# Beds must be walkable-adjacent on at least two sides.
	for b in of.call("b"):
		var open := 0
		for dd in DIRS:
			if walk.call(b.x + dd.x, b.y + dd.y):
				open += 1
		if open < 2:
			problems.append("bed at %d,%d has only %d walkable neighbour(s)" % [b.x, b.y, open])

	# Lights sit on walkable floor tiles.
	for l in gen.get("lights", []):
		if not walk.call(l.x, l.y):
			problems.append("light at %d,%d is not on a walkable tile" % [l.x, l.y])

	# Props sit on tiles that still carry their prop character.
	for p in gen.get("props", []):
		var t: Vector2i = p.tile
		var c: String = at.call(t.x, t.y)
		if not PROP_CHARS.has(c):
			problems.append("prop '%s' at %d,%d is not on a prop tile" % [p.kind, t.x, t.y])
		elif PROP_CHARS[c] != p.kind:
			problems.append("prop at %d,%d says '%s' but the map says '%s'" % [t.x, t.y, p.kind, PROP_CHARS[c]])

	# Special room minimums.
	for k in SPECIAL_MIN.keys():
		if int(kind_count.get(k, 0)) < int(SPECIAL_MIN[k]):
			problems.append("expected >= %d '%s' rooms, found %d" % [SPECIAL_MIN[k], k, kind_count.get(k, 0)])

	# Container sites.
	var site_keys := {}
	for s in gen.get("containers", []):
		var t: Vector2i = s.tile
		var d: Vector2i = s.wall
		var type: String = s.type
		if not ItemsData.CONTAINER_TYPES.has(type):
			problems.append("container at %d,%d has unknown type '%s'" % [t.x, t.y, type])
			continue
		if not _container_allowed(type, s.room_kind):
			problems.append("%s at %d,%d is not allowed in a %s" % [type, t.x, t.y, s.room_kind])
		var c: String = at.call(t.x, t.y)
		if CONTAINER_CHARS.has(type):
			if c != CONTAINER_CHARS[type]:
				problems.append("%s at %d,%d sits on '%s'" % [type, t.x, t.y, c])
		elif not walk.call(t.x, t.y):
			problems.append("%s at %d,%d is on a solid tile" % [type, t.x, t.y])
		if at.call(t.x + d.x, t.y + d.y) != "#":
			problems.append("%s at %d,%d has no wall behind it" % [type, t.x, t.y])
		if not walk.call(t.x - d.x, t.y - d.y):
			problems.append("%s at %d,%d cannot be reached from the front" % [type, t.x, t.y])
		for dd in DIRS:
			if at.call(t.x + dd.x, t.y + dd.y) == "+":
				problems.append("%s at %d,%d is next to a door" % [type, t.x, t.y])
		var key := "%d,%d" % [t.x, t.y]
		if site_keys.has(key):
			problems.append("two containers share the tile %d,%d" % [t.x, t.y])
		site_keys[key] = true
	for ch in CONTAINER_CHARS.values():
		var n_sites := 0
		for s in gen.get("containers", []):
			if CONTAINER_CHARS.get(s.type, "") == ch:
				n_sites += 1
		if of.call(ch).size() != n_sites:
			problems.append("%d '%s' tiles but %d matching container sites" % [of.call(ch).size(), ch, n_sites])

	# Everything walkable must be reachable from a P.
	if not ps.is_empty():
		var reached := PackedByteArray()
		reached.resize(w * h)
		var queue: Array[int] = [ps[0].y * w + ps[0].x]
		reached[queue[0]] = 1
		var count := 0
		var qi := 0
		while qi < queue.size():
			var i: int = queue[qi]
			qi += 1
			count += 1
			var x := i % w
			var y := i / w
			for dd in DIRS:
				var nx := x + dd.x
				var ny := y + dd.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var ni := ny * w + nx
				if reached[ni] == 1 or not walk.call(nx, ny):
					continue
				reached[ni] = 1
				queue.append(ni)
		var total := 0
		var example := Vector2i(-1, -1)
		for y in h:
			for x in w:
				if not walk.call(x, y):
					continue
				total += 1
				if reached[y * w + x] == 0 and example.x < 0:
					example = Vector2i(x, y)
		if count != total:
			problems.append("%d walkable tile(s) unreachable from 'P' (e.g. %d,%d)" % [total - count, example.x, example.y])

	return problems
