extends RefCounted
## The generator's working state: the tile grid plus everything placed on it.
##
## Tile characters (the `rows` every other system reads):
##   #  wall or solid            .  indoor floor          +  doorway (walkable)
##   ,  outdoor ground            =  outdoor fence (solid)
##   P  player spawn (break room) T  tool spawn candidate  M  monster spawn candidate
## Furniture never changes a character; it marks `blocked` instead.

const Defs := preload("res://scripts/level/piece_defs.gd")

const CH_WALL := 35     # '#'
const CH_FLOOR := 46    # '.'
const CH_DOOR := 43     # '+'
const CH_OUT := 44      # ','
const CH_FENCE := 61    # '='
const CH_PLAYER := 80   # 'P'
const CH_TOOL := 84     # 'T'
const CH_MON := 77      # 'M'

const ZONE_NONE := 0
const ZONE_ENTRANCE := 1
## Wing i lives in zone ZONE_WING0 + i.
const ZONE_WING0 := 2
const ZONE_OUTDOOR := 9

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

var w: int
var h: int
var cells: PackedByteArray
var zone: PackedByteArray
## Room index per tile, -1 outside rooms.
var room_at: PackedInt32Array
## Tiles filled by blocking furniture.
var blocked: PackedByteArray
## Tiles that must stay clear: 1 = no blocking furniture (container fronts, markers, paths),
## 2 = nothing at all (doorways and the step inside them).
var keep: PackedByteArray

var rooms: Array = []
## [{id, rect: Rect2i (tiles, walls included), depth, zone, entry: [Vector2i], dir: Vector2i}]
var wings: Array = []
## [{kind, pos: Vector2 (tile space), yaw, room, zone}]
var furniture: Array = []
## [{tile, wall, type, room_kind, room, zone}]
var containers: Array = []
## [{tile, mode, zone}]
var lights: Array = []
## Named spots: {name: {pos: Vector2 (tile space), yaw}} plus lists.
var spots: Dictionary = {}


func _init(w_: int, h_: int) -> void:
	w = w_
	h = h_
	var n := w * h
	cells = PackedByteArray()
	cells.resize(n)
	cells.fill(CH_WALL)
	zone = PackedByteArray()
	zone.resize(n)
	room_at = PackedInt32Array()
	room_at.resize(n)
	room_at.fill(-1)
	blocked = PackedByteArray()
	blocked.resize(n)
	keep = PackedByteArray()
	keep.resize(n)


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < w and y < h


func idx(x: int, y: int) -> int:
	return y * w + x


func get_c(x: int, y: int) -> int:
	return cells[y * w + x] if in_bounds(x, y) else CH_WALL


func set_c(x: int, y: int, c: int) -> void:
	if in_bounds(x, y):
		cells[y * w + x] = c


static func walkable_code(c: int) -> bool:
	return c == CH_FLOOR or c == CH_DOOR or c == CH_OUT or c == CH_PLAYER or c == CH_TOOL or c == CH_MON


func walkable(x: int, y: int) -> bool:
	return walkable_code(get_c(x, y))


## Walkable and not filled by furniture.
func open(x: int, y: int) -> bool:
	return in_bounds(x, y) and walkable_code(cells[y * w + x]) and blocked[y * w + x] == 0


func zone_at(x: int, y: int) -> int:
	return zone[y * w + x] if in_bounds(x, y) else ZONE_NONE


func room_index(x: int, y: int) -> int:
	return room_at[y * w + x] if in_bounds(x, y) else -1


func set_keep(x: int, y: int, level := 1) -> void:
	if in_bounds(x, y):
		keep[y * w + x] = maxi(keep[y * w + x], level)


func door_near(x: int, y: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if (dx != 0 or dy != 0) and get_c(x + dx, y + dy) == CH_DOOR:
				return true
	return false


func door_adjacent(x: int, y: int) -> bool:
	for d in DIRS:
		if get_c(x + d.x, y + d.y) == CH_DOOR:
			return true
	return false


## Carve a rectangle of floor into a zone. `r` is inclusive of its cells.
func carve_rect(r: Rect2i, ch: int, z: int) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if in_bounds(x, y):
				cells[y * w + x] = ch
				zone[y * w + x] = z


func add_room(r: Rect2i, kind: String, z: int, wing_id: String, depth: int, extra := {}) -> int:
	var i := rooms.size()
	var room := {"id": i, "x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y,
			"kind": kind, "wing": wing_id, "depth": depth, "zone": z, "doors": [], "open": []}
	room.merge(extra, true)
	rooms.append(room)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if in_bounds(x, y):
				room_at[y * w + x] = i
				zone[y * w + x] = z
				if cells[y * w + x] == CH_WALL:
					cells[y * w + x] = CH_FLOOR
	return i


## Place a piece. Refuses (returns false) when a blocking piece would fill a kept tile, a wall,
## or a tile another blocking piece already fills.
func put(kind: String, pos: Vector2, yaw: float, room := -1, extra := {}) -> bool:
	var tiles := Defs.blocked_tiles(kind, pos, yaw)
	for t in tiles:
		if not in_bounds(t.x, t.y):
			return false
		var i := t.y * w + t.x
		if keep[i] != 0 or blocked[i] == 1 or not walkable_code(cells[i]):
			return false
	for t in tiles:
		blocked[t.y * w + t.x] = 1
	var z := zone_at(int(floor(pos.x)), int(floor(pos.y)))
	var e := {"kind": kind, "pos": pos, "yaw": yaw, "room": room, "zone": z}
	e.merge(extra, true)
	furniture.append(e)
	return true


## Remove the most recent piece (used when a template breaks a room's connectivity).
func pop_piece() -> void:
	if furniture.is_empty():
		return
	var e: Dictionary = furniture.pop_back()
	for t in Defs.blocked_tiles(e.kind, e.pos, e.yaw):
		if in_bounds(t.x, t.y):
			blocked[t.y * w + t.x] = 0


## A container standing (or hanging) on `tile` against the wall in direction `wall`.
func add_container(tile: Vector2i, wall: Vector2i, type: String, room := -1) -> bool:
	if not open(tile.x, tile.y) or keep[idx(tile.x, tile.y)] != 0:
		return false
	if get_c(tile.x + wall.x, tile.y + wall.y) != CH_WALL:
		return false
	var fx := tile.x - wall.x
	var fy := tile.y - wall.y
	if not open(fx, fy) or door_adjacent(tile.x, tile.y):
		return false
	for c in containers:
		if c.tile == tile:
			return false
	var kind := "corridor"
	if room >= 0:
		kind = String(rooms[room].kind)
	containers.append({"tile": tile, "wall": wall, "type": type, "room_kind": kind, "room": room, "zone": zone_at(tile.x, tile.y)})
	if type != "trauma_bag" and type != "pegboard":
		blocked[idx(tile.x, tile.y)] = 1
	set_keep(fx, fy, 1)
	return true


## Open tiles of a room reachable from `start` without leaving the room.
func room_reach(room: int, start: Vector2i) -> Dictionary:
	var out := {}
	if not open(start.x, start.y):
		return out
	var q: Array[Vector2i] = [start]
	out[start] = true
	var qi := 0
	while qi < q.size():
		var p: Vector2i = q[qi]
		qi += 1
		for d in DIRS:
			var n := p + d
			if out.has(n) or room_index(n.x, n.y) != room or not open(n.x, n.y):
				continue
			out[n] = true
			q.append(n)
	return out


## Every open tile of the room is reachable from its door tile.
func room_connected(room: int) -> bool:
	var r: Dictionary = rooms[room]
	var entry: Vector2i = r.get("entry", Vector2i(-1, -1))
	if entry.x < 0:
		return true
	var reach := room_reach(room, entry)
	for y in range(r.y, r.y + r.h):
		for x in range(r.x, r.x + r.w):
			if room_at[y * w + x] == room and open(x, y) and not reach.has(Vector2i(x, y)):
				return false
	return true


## Flood over open tiles (4-neighbour) from `starts`.
func flood(starts: Array) -> PackedByteArray:
	var reached := PackedByteArray()
	reached.resize(w * h)
	var q: Array[int] = []
	for s in starts:
		var i: int = s.y * w + s.x
		if in_bounds(s.x, s.y) and reached[i] == 0 and open(s.x, s.y):
			reached[i] = 1
			q.append(i)
	var qi := 0
	while qi < q.size():
		var i: int = q[qi]
		qi += 1
		var x := i % w
		var y := i / w
		for d in DIRS:
			var nx := x + d.x
			var ny := y + d.y
			if not in_bounds(nx, ny):
				continue
			var ni := ny * w + nx
			if reached[ni] == 1 or not open(nx, ny):
				continue
			reached[ni] = 1
			q.append(ni)
	return reached


func rows() -> PackedStringArray:
	var out := PackedStringArray()
	for y in h:
		out.append(cells.slice(y * w, (y + 1) * w).get_string_from_ascii())
	return out
