extends RefCounted
## One procedurally generated wing: long liminal hallways first, then rows of real rooms packed
## between them, then (after the map decides which room is which) furniture, hallway dressing
## and lights.
##
## Hallways: the wing's entry hallway runs straight from the entrance building's doorway across
## the whole wing. Every region it leaves is split again by hallways that start on an existing
## hallway and run until they reach another one or the wing's outer wall (a dead end), until each
## region can hold one row of rooms (facing one hallway) or two rows back to back (facing two).
## A few regions become open halls instead: wide, empty spaces, some with pillars.
##
## Rooms: `slots` lists every room rectangle with the hallway side its door goes in. The map
## assigns a kind to each slot (see mapgen.gd), then `place_rooms()` carves them and
## `finish()` furnishes, dresses the hallways and adds the ceiling fixtures.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Rng := preload("res://scripts/level/rng.gd")
const Rooms := preload("res://scripts/level/room_furnish.gd")

## Deepest room row (tiles, away from its hallway).
const MAX_ROW_DEPTH := 6
const MIN_ROW_DEPTH := 3
## Narrowest region a split may leave on either side of a new hallway.
const MIN_CHILD := 4
const MAX_ROOM_W := 13

## Hallway clutter along walls: kind, weight.
const CLUTTER := [["gurney", 3.0], ["wheelchair", 3.0], ["bench", 2.5], ["vending", 1.2], ["bin", 1.5],
		["wet_floor", 0.8], ["plant", 0.6], ["gurney_body", 0.4]]


class Seg extends RefCounted:
	var start: Vector2i
	var dir: Vector2i
	var side: Vector2i
	var width: int
	var length := 0
	var cells: Array[Vector2i] = []

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
## Open halls: Rect2i each.
var halls: Array = []
## Room slots: {rect: Rect2i (interior), front: Vector2i (room -> hallway), kind: String, wing: String}
var slots: Array = []


static func carve(state: S, wing_def: Dictionary, r: Rng) -> RefCounted:
	var g := new()
	g.st = state
	g.rng = r
	g.wing = wing_def
	g.rect = wing_def.rect
	g.z = wing_def.zone
	g._carve_all()
	return g


func inner() -> Rect2i:
	return rect.grow(-1)


func is_corr(p: Vector2i) -> bool:
	return st.in_bounds(p.x, p.y) and st.zone_at(p.x, p.y) == z and st.get_c(p.x, p.y) == S.CH_FLOOR \
			and st.room_index(p.x, p.y) < 0


# ---------------------------------------------------------------------------
# Hallways and regions
# ---------------------------------------------------------------------------

func _sides(n: bool, s: bool, w: bool, e: bool) -> Dictionary:
	return {"n": n, "s": s, "w": w, "e": e}


func _carve_all() -> void:
	var r := inner()
	var entry: Array = wing.entry
	var d: Vector2i = wing.dir
	if d.x != 0:
		# Horizontal entry hallway across the whole wing.
		var y0: int = mini(entry[0].y, entry[1].y)
		var cw := 2
		_hallway(Rect2i(r.position.x, y0, r.size.x, cw), Vector2i(-d.x, 0))
		_split(Rect2i(r.position.x, r.position.y, r.size.x, y0 - r.position.y), _sides(false, true, false, false))
		_split(Rect2i(r.position.x, y0 + cw, r.size.x, r.end.y - y0 - cw), _sides(true, false, false, false))
	else:
		var x0: int = mini(entry[0].x, entry[1].x)
		var cw := 2
		_hallway(Rect2i(x0, r.position.y, cw, r.size.y), Vector2i(0, -d.y))
		_split(Rect2i(r.position.x, r.position.y, x0 - r.position.x, r.size.y), _sides(false, false, false, true))
		_split(Rect2i(x0 + cw, r.position.y, r.end.x - x0 - cw, r.size.y), _sides(false, false, true, false))


## Carve a straight hallway covering `hr`. `along` is the direction it runs (only its axis matters).
func _hallway(hr: Rect2i, along: Vector2i) -> void:
	var vertical := along.x == 0
	var sg: Seg
	if vertical:
		sg = Seg.new(hr.position, Vector2i(0, 1), Vector2i(1, 0), hr.size.x)
		sg.length = hr.size.y
	else:
		sg = Seg.new(hr.position, Vector2i(1, 0), Vector2i(0, 1), hr.size.y)
		sg.length = hr.size.x
	for i in sg.length:
		for j in sg.width:
			var c := sg.cell(i, j)
			st.set_c(c.x, c.y, S.CH_FLOOR)
			st.zone[st.idx(c.x, c.y)] = z
			sg.cells.append(c)
	segs.append(sg)


func _split(R: Rect2i, sd: Dictionary) -> void:
	if R.size.x < 3 or R.size.y < 3:
		return
	var plan := _leaf_plan(R, sd)
	var long := maxi(R.size.x, R.size.y)
	var stop := false
	if not plan.is_empty():
		stop = long <= rng.rint(12, 24) or (long <= 40 and rng.chance(0.3))
	if stop:
		_leaf(R, sd, plan)
		return
	# Hallways must start on a hallway: vertical ones need a hallway north or south.
	var can_v: bool = sd.n or sd.s
	var can_h: bool = sd.w or sd.e
	var order: Array = []
	var too_deep_h := R.size.y > MAX_ROW_DEPTH * 2 + 3
	var too_deep_v := R.size.x > MAX_ROW_DEPTH * 2 + 3
	if can_v and can_h:
		# Prefer long hallways: run along the longer side, cutting the shorter one.
		if R.size.x >= R.size.y:
			order = [false, true] if (too_deep_h or rng.chance(0.55)) else [true, false]
		else:
			order = [true, false] if (too_deep_v or rng.chance(0.55)) else [false, true]
	elif can_v:
		order = [true]
	elif can_h:
		order = [false]
	for vertical in order:
		if _try_split(R, sd, vertical):
			return
	if not plan.is_empty():
		_leaf(R, sd, plan)
	else:
		_fallback_leaf(R, sd)


func _hall_width() -> int:
	var roll := rng.nextf()
	if roll < 0.07:
		return 4
	if roll < 0.2:
		return 3
	return 2


func _try_split(R: Rect2i, sd: Dictionary, vertical: bool) -> bool:
	var cw := _hall_width()
	var span := R.size.x if vertical else R.size.y
	for attempt in 2:
		var lo := MIN_CHILD
		var hi := span - MIN_CHILD - cw
		if hi < lo:
			cw = 2
			hi = span - MIN_CHILD - cw
			if hi < lo:
				return false
		# Anywhere in the middle half, so rows of rooms vary in depth.
		var mid := (lo + hi) / 2
		var jitter := maxi(1, (hi - lo) / 2)
		var at := clampi(mid + rng.rint(-jitter, jitter), lo, hi)
		if vertical:
			var x := R.position.x + at
			_hallway(Rect2i(x, R.position.y, cw, R.size.y), Vector2i(0, 1))
			_split(Rect2i(R.position.x, R.position.y, at, R.size.y), _with(sd, "e"))
			_split(Rect2i(x + cw, R.position.y, R.end.x - x - cw, R.size.y), _with(sd, "w"))
		else:
			var y := R.position.y + at
			_hallway(Rect2i(R.position.x, y, R.size.x, cw), Vector2i(1, 0))
			_split(Rect2i(R.position.x, R.position.y, R.size.x, at), _with(sd, "s"))
			_split(Rect2i(R.position.x, y + cw, R.size.x, R.end.y - y - cw), _with(sd, "n"))
		return true
	return false


func _with(sd: Dictionary, key: String) -> Dictionary:
	var d := sd.duplicate()
	d[key] = true
	return d


## How a region packs into rooms, or {} when it cannot. Rows run along x ("h") with doors north
## or south, or along y ("v") with doors west or east. The longer row wins.
func _leaf_plan(R: Rect2i, sd: Dictionary) -> Dictionary:
	var best := {}
	for horiz in [true, false]:
		var depth := R.size.y if horiz else R.size.x
		var length := R.size.x if horiz else R.size.y
		var fa: bool = sd.n if horiz else sd.w
		var fb: bool = sd.s if horiz else sd.e
		var ea: bool = sd.w if horiz else sd.n
		var eb: bool = sd.e if horiz else sd.s
		var a := 1 if ea else 0
		var b := length - 1 - (1 if eb else 0)
		if b - a + 1 < MIN_ROW_DEPTH:
			continue
		var rows: Array = []
		if fa and fb:
			var inner_d := depth - 2
			if inner_d >= MIN_ROW_DEPTH * 2 + 1 and inner_d <= MAX_ROW_DEPTH * 2 + 1:
				var lo := maxi(MIN_ROW_DEPTH, inner_d - 1 - MAX_ROW_DEPTH)
				var hi := mini(MAX_ROW_DEPTH, inner_d - 1 - MIN_ROW_DEPTH)
				var d1 := rng.rint(lo, hi)
				rows.append({"lo": 1, "hi": d1, "front": -1})
				rows.append({"lo": d1 + 2, "hi": depth - 2, "front": 1})
			elif inner_d >= MIN_ROW_DEPTH and inner_d <= MAX_ROW_DEPTH:
				rows.append({"lo": 1, "hi": depth - 2, "front": -1 if rng.chance(0.5) else 1})
			else:
				continue
		elif fa:
			if depth - 1 < MIN_ROW_DEPTH or depth - 1 > MAX_ROW_DEPTH:
				continue
			rows.append({"lo": 1, "hi": depth - 1, "front": -1})
		elif fb:
			if depth - 1 < MIN_ROW_DEPTH or depth - 1 > MAX_ROW_DEPTH:
				continue
			rows.append({"lo": 0, "hi": depth - 2, "front": 1})
		else:
			continue
		var score := b - a + 1
		if best.is_empty() or score > int(best.score):
			best = {"horiz": horiz, "a": a, "b": b, "rows": rows, "score": score}
	return best


## A region too deep for rows that cannot be split: one row against its hallway, the rest solid.
func _fallback_leaf(R: Rect2i, sd: Dictionary) -> void:
	for key in ["n", "s", "w", "e"]:
		if not sd[key]:
			continue
		var horiz: bool = key == "n" or key == "s"
		var depth := R.size.y if horiz else R.size.x
		var opposite: String = {"n": "s", "s": "n", "w": "e", "e": "w"}[key]
		var back_open: bool = sd[opposite]
		var avail := depth - 1 - (1 if back_open else 0)
		if avail < MIN_ROW_DEPTH:
			continue
		var d := mini(MAX_ROW_DEPTH, avail)
		if d == avail and back_open:
			# The row reaches the hallway behind it: plan it with both sides.
			var both := sd.duplicate()
			var p2 := _leaf_plan(R, both)
			if not p2.is_empty():
				_leaf(R, both, p2)
				return
			continue
		var sub: Rect2i
		match key:
			"n": sub = Rect2i(R.position.x, R.position.y, R.size.x, d + 1)
			"s": sub = Rect2i(R.position.x, R.end.y - d - 1, R.size.x, d + 1)
			"w": sub = Rect2i(R.position.x, R.position.y, d + 1, R.size.y)
			_: sub = Rect2i(R.end.x - d - 1, R.position.y, d + 1, R.size.y)
		var only := _sides(key == "n", key == "s", key == "w", key == "e")
		# Hallways at the ends of the row still need their end walls.
		if horiz:
			only.w = sd.w
			only.e = sd.e
		else:
			only.n = sd.n
			only.s = sd.s
		var plan := _leaf_plan(sub, only)
		if not plan.is_empty():
			_leaf(sub, only, plan)
			return


func _leaf(R: Rect2i, sd: Dictionary, plan: Dictionary) -> void:
	# Some regions become open halls: the wide, empty spaces between the hallways.
	var w := R.size.x
	var h := R.size.y
	if w >= 5 and h >= 5 and w <= 14 and h <= 14 and rng.chance(0.08):
		_open_hall(R)
		return
	var horiz: bool = plan.horiz
	for row in plan.rows:
		var lo: int = row.lo
		var hi: int = row.hi
		var d := hi - lo + 1
		var front: Vector2i = (Vector2i(0, row.front) if horiz else Vector2i(row.front, 0))
		var pos: int = plan.a
		var end: int = plan.b
		while pos <= end:
			var rem := end - pos + 1
			var wv := _pick_width(d)
			if rem <= wv or (rem - wv - 1 < 3):
				wv = rem
				if wv > MAX_ROOM_W:
					wv = rem - 4
			wv = clampi(wv, 3, rem)
			var rr: Rect2i
			if horiz:
				rr = Rect2i(R.position.x + pos, R.position.y + lo, wv, d)
			else:
				rr = Rect2i(R.position.x + lo, R.position.y + pos, d, wv)
			slots.append({"rect": rr, "front": front, "kind": "", "wing": String(wing.id)})
			pos += wv + 1


func _pick_width(d: int) -> int:
	if d <= 3:
		return rng.pick([3, 3, 4, 4, 5])
	if d <= 4:
		return rng.pick([3, 3, 4, 4, 5, 5, 6, 6, 7])
	return rng.pick([4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11])


func _open_hall(R: Rect2i) -> void:
	for y in range(R.position.y, R.end.y):
		for x in range(R.position.x, R.end.x):
			st.set_c(x, y, S.CH_FLOOR)
			st.zone[st.idx(x, y)] = z
	# Square pillars in a grid when there is room to walk around them.
	if R.size.x >= 7 and R.size.y >= 7:
		var y := R.position.y + 2
		while y < R.end.y - 2:
			var x := R.position.x + 2
			while x < R.end.x - 2:
				st.set_c(x, y, S.CH_WALL)
				x += 3
			y += 3
	halls.append(R)


# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

## Slot size in the room frame: w along the door wall, d away from it.
static func slot_wd(slot: Dictionary) -> Vector2i:
	var r: Rect2i = slot.rect
	var f: Vector2i = slot.front
	return Vector2i(r.size.x, r.size.y) if f.x == 0 else Vector2i(r.size.y, r.size.x)


## Carve every slot that got a kind, with its door or archway.
func place_rooms() -> void:
	for slot in slots:
		if String(slot.kind) == "":
			continue
		_place_room(slot)


func _place_room(slot: Dictionary) -> void:
	var r: Rect2i = slot.rect
	var f: Vector2i = slot.front
	var kind: String = slot.kind
	var wd := slot_wd(slot)
	var open_w := int(Rooms.KINDS[kind].open)
	var a: int
	if open_w > 0:
		a = wd.x / 2
	elif wd.x <= 5:
		a = 1 if rng.chance(0.5) else wd.x - 2
	else:
		a = rng.pick([1, wd.x / 2, wd.x - 2])
	a = clampi(a, 0, wd.x - 1)
	var door: Vector2i
	var along := Vector2i(absi(f.y), absi(f.x))
	if f == Vector2i(0, 1):
		door = Vector2i(r.position.x + a, r.end.y)
	elif f == Vector2i(0, -1):
		door = Vector2i(r.position.x + a, r.position.y - 1)
	elif f == Vector2i(1, 0):
		door = Vector2i(r.end.x, r.position.y + a)
	else:
		door = Vector2i(r.position.x - 1, r.position.y + a)
	var side := "S"
	if f == Vector2i(0, -1):
		side = "N"
	elif f == Vector2i(1, 0):
		side = "E"
	elif f == Vector2i(-1, 0):
		side = "W"
	var n := -f
	var ri := st.add_room(r, kind, z, String(wing.id), int(wing.depth), {"side": side, "door": door, "entry": door + n})
	st.set_c(door.x, door.y, S.CH_DOOR)
	st.zone[st.idx(door.x, door.y)] = z
	(st.rooms[ri].doors as Array).append(door)
	if open_w > 0:
		# An archway instead of a door: the wall tiles either side of the door open too.
		st.set_c(door.x, door.y, S.CH_FLOOR)
		var half := (open_w - 1) / 2
		for k in range(-half, open_w - half):
			var t := door + along * k
			var inside := t + n
			if st.room_index(inside.x, inside.y) != ri or not is_corr(t + f):
				continue
			st.set_c(t.x, t.y, S.CH_FLOOR)
			st.zone[st.idx(t.x, t.y)] = z
			(st.rooms[ri].open as Array).append(t)
		(st.rooms[ri].doors as Array).clear()


## Furniture, hallway dressing and lights, once every room on the map exists.
func finish() -> void:
	for ri in st.rooms.size():
		if int(st.rooms[ri].zone) == z:
			Rooms.furnish(st, ri, rng)
	_dress_corridors()
	_lights()


# ---------------------------------------------------------------------------
# Hallway dressing, trauma bags, lights
# ---------------------------------------------------------------------------

func _wall_side_ok(c: Vector2i, n: Vector2i) -> bool:
	if not is_corr(c) or st.get_c(c.x + n.x, c.y + n.y) != S.CH_WALL:
		return false
	if st.door_near(c.x, c.y) or st.keep[st.idx(c.x, c.y)] != 0 or st.blocked[st.idx(c.x, c.y)] != 0:
		return false
	# Not in an archway's mouth, and not against a pillar.
	for d in S.DIRS:
		var q := c + d
		if st.get_c(q.x, q.y) == S.CH_FLOOR and st.room_index(q.x, q.y) >= 0:
			return false
	for hr: Rect2i in halls:
		if hr.grow(1).has_point(c):
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
				elif roll < 0.42:
					var weights: Array = []
					for e in CLUTTER:
						weights.append(e[1])
					var kind: String = CLUTTER[rng.weighted(weights)][0]
					var depth := Defs.size(kind).z * 0.5 / Defs.TILE + 0.03
					var face := Vector2(-n.x, -n.y)
					var pos := Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * (0.5 - depth)
					if kind == "gurney" or kind == "gurney_body":
						# Long things lie along the wall.
						face = Vector2(s.dir.x, s.dir.y) * (1 if rng.chance(0.5) else -1)
						var hw := Defs.size(kind).x * 0.5 / Defs.TILE + 0.03
						pos = Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * (0.5 - hw)
					st.put(kind, pos, Defs.yaw_facing(face), -1)
				elif roll < 0.52:
					var mount := "extinguisher" if rng.chance(0.6) else "wall_clock"
					st.put(mount, Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * 0.5, Defs.yaw_facing(Vector2(-n.x, -n.y)), -1)
			i += rng.rint(4, 9)
	# Cameras watch a few long hallways from their far end.
	for s: Seg in segs:
		if s.length >= 14 and rng.chance(0.35):
			var c := s.cell(s.length - 1, 0)
			var n := -s.side
			if st.get_c(c.x + n.x, c.y + n.y) == S.CH_WALL and is_corr(c):
				st.put("security_camera", Vector2(c.x + 0.5, c.y + 0.5) + Vector2(n.x, n.y) * 0.5, Defs.yaw_facing(Vector2(-s.dir.x, -s.dir.y)), -1)
	# Every wing gets at least one trauma bag on a hallway wall.
	if bags == 0:
		for s: Seg in segs:
			if bags > 0:
				break
			for i in range(1, s.length - 1):
				var c := s.cell(i, 0)
				if _wall_side_ok(c, -s.side) and st.add_container(c, -s.side, "trauma_bag", -1):
					bags += 1
					break
	# Benches and a plant or two in the open halls.
	for hr: Rect2i in halls:
		if rng.chance(0.6):
			var p := Vector2(hr.position.x + hr.size.x * 0.5, hr.position.y + 1.0)
			st.put("bench", p, Defs.yaw_facing(Vector2(0, 1)), -1)
		if rng.chance(0.4):
			st.put("plant", Vector2(hr.position.x + 0.5, hr.end.y - 0.5), 0.0, -1)


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
	for hr: Rect2i in halls:
		var y := hr.position.y + 1
		while y < hr.end.y:
			var x := hr.position.x + 1
			while x < hr.end.x:
				var t := Vector2i(x, y)
				if not seen.has(t) and st.walkable(t.x, t.y):
					seen[t] = true
					st.lights.append({"tile": t, "zone": z, "mode": -1})
				x += 4
			y += 4
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
