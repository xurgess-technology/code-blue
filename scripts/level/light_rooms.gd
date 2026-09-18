extends RefCounted
## Room-bound lighting: why a lamp never lights the room on the other side of a wall.
##
## Every light in the hospital runs without shadows (the flashlight is the only shadow caster, for
## the frame rate), and a light without shadows ignores walls: it lights every surface in its range,
## so a room's glow showed up on the far side of its walls (the projector's green in the waiting room,
## the furnace's orange in the personnel room, every ceiling fixture a little into its neighbours).
##
## So light is bound to areas with render layers instead. The map is split into areas: each room,
## and each connected stretch of floor outside rooms (a corridor, a lobby strip, the lot). Areas close
## enough for a light to reach across (CONFLICT_TILES) get different AREA_BITS (a greedy colouring);
## doorways and archways, and small strips joining rooms, carry the bits of everything they join.
##   - the building's static surfaces (floors, ceilings, wall faces, furniture, props) render on the
##     bit of the area they face or stand in, and NOT on layer 1;
##   - every light's cull mask is the bits of the area it hangs in (3 x 3 tiles around it, so a lamp
##     by a doorway still reaches through it) plus DYNAMIC (layer 1);
##   - things that move (players, monsters, items, bodies) stay on layer 1, lit by every light near
##     them, as before.
## The entrance building and the lot are coloured first, on their own, so they keep the same bits
## whatever wings a shift generates.
##
##   ensure(gen)                  compute the grid once for a generated map (thread-safe data)
##   tile_mask(grid, x, y)        a tile's bits (ALL off the grid or on a wall)
##   mask_at(grid, world_pos)     the bits where a point is
##   light_mask(grid, world_pos)  the bits a light there may light (3 x 3 tiles)
##   apply(node, grid)            put a static node's meshes and lights on the bits where they are

const Store := preload("res://scripts/level/level_state.gd")

## Render layer bits free for areas (0 is DYNAMIC; 11 and 12 are the pocket spaces' copies; 16 is
## SELF; 17, 18 and 19 the dev gun, the first-person hands and the minigames). Real maps colour with
## at most 8 of them.
const AREA_BITS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15]
const DYNAMIC := 1
## The local player's own body, drawn only for mirror cameras (scripts/personnel/mirrors.gd) and the
## over-the-shoulder carry camera: the first-person camera leaves it out. Lit like DYNAMIC.
const SELF := 1 << 16
## Areas whose floors come within this many tiles of each other must not share a bit.
const CONFLICT_TILES := 6
## A strip of floor outside rooms this small that touches two or more areas is a joint, not an area;
## one that opens (through doorways) onto a single area is part of that area (a furnace's chamber).
const JOINT_MAX_TILES := 12

static var ALL := _all_bits()


static func _all_bits() -> int:
	var m := 0
	for b in AREA_BITS:
		m |= 1 << int(b)
	return m


## The grid for `gen`: {w, h, data: PackedInt32Array of per-tile masks}, cached on the gen.
static func ensure(gen: Dictionary) -> Dictionary:
	if gen.has("_light_grid"):
		return gen._light_grid
	var grid := _compute(gen)
	gen["_light_grid"] = grid
	return grid


static func tile_mask(grid: Dictionary, x: int, y: int) -> int:
	if grid.is_empty() or x < 0 or y < 0 or x >= int(grid.w) or y >= int(grid.h):
		return ALL
	var m := int((grid.data as PackedInt32Array)[y * int(grid.w) + x])
	return m if m != 0 else ALL


static func mask_at(grid: Dictionary, p: Vector3) -> int:
	return tile_mask(grid, int(floor(p.x / C.TILE)), int(floor(p.z / C.TILE)))


static func light_mask(grid: Dictionary, p: Vector3) -> int:
	var tx := int(floor(p.x / C.TILE))
	var ty := int(floor(p.z / C.TILE))
	var m := 0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var x: int = tx + dx
			var y: int = ty + dy
			if grid.is_empty() or x < 0 or y < 0 or x >= int(grid.w) or y >= int(grid.h):
				return ALL
			m |= int((grid.data as PackedInt32Array)[y * int(grid.w) + x])
	return m if m != 0 else ALL


## A static node and everything under it: meshes still on the default layer go on the bits where
## each one is; lights get their area as their cull mask. Nodes marked with the "light_dynamic" meta
## (and their children) are left alone, as is anything inside a SubViewport.
static func apply(node: Node, grid: Dictionary) -> void:
	if grid.is_empty() or node == null:
		return
	if node.has_meta("light_dynamic") or node is SubViewport:
		return
	if node is Light3D:
		var l := node as Light3D
		if not (l is DirectionalLight3D):
			l.light_cull_mask = (l.light_cull_mask & ~ALL) | light_mask(grid, l.global_position) | DYNAMIC
	elif node is VisualInstance3D:
		var v := node as VisualInstance3D
		if v.layers == DYNAMIC and not (v is ReflectionProbe) and not (v is Decal):
			v.layers = mask_at(grid, (v as Node3D).global_position)
	for c in node.get_children():
		apply(c, grid)


# ---------------------------------------------------------------------------
# computing the areas

static func _compute(gen: Dictionary) -> Dictionary:
	var rows: PackedStringArray = gen.rows
	var h := rows.size()
	var w: int = rows[0].length() if h > 0 else 0
	var room_at: PackedInt32Array = gen.get("room_at", PackedInt32Array())
	var zone: PackedByteArray = gen.get("zone", PackedByteArray())
	var n := w * h
	var area := PackedInt32Array()
	area.resize(n)
	area.fill(-1)
	var joint := {}   # tile index -> true: doorways and archways
	for r in gen.get("rooms", []):
		for t in r.get("open", []):
			joint[int(t.y) * w + int(t.x)] = true
	var room_count: int = gen.get("rooms", []).size()
	for y in h:
		for x in w:
			var i := y * w + x
			var c := rows[y][x]
			if not _open(c):
				continue
			if c == "+":
				joint[i] = true
				continue
			if joint.has(i):
				continue
			if room_at.size() == n and room_at[i] >= 0:
				area[i] = room_at[i]
	# Floor outside rooms: connected strips, split at doorways and archways.
	var next_id := room_count
	var strips := {}   # strip id -> its tiles
	for y in h:
		for x in w:
			var i := y * w + x
			if area[i] != -1 or joint.has(i) or not _open(rows[y][x]):
				continue
			var id := next_id
			next_id += 1
			var stack: Array[int] = [i]
			area[i] = id
			var tiles := PackedInt32Array()
			while not stack.is_empty():
				var k: int = stack.pop_back()
				tiles.append(k)
				var kx := k % w
				var ky := k / w
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = kx + d.x
					var ny: int = ky + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var ni := ny * w + nx
					if area[ni] != -1 or joint.has(ni) or not _open(rows[ny][nx]):
						continue
					if room_at.size() == n and room_at[ni] >= 0:
						continue
					area[ni] = id
					stack.append(ni)
			strips[id] = tiles
	# Small strips joining two or more areas become joints too (a barred counter between two rooms).
	for id in strips.keys():
		var tiles: PackedInt32Array = strips[id]
		if tiles.size() > JOINT_MAX_TILES:
			continue
		var touches := {}
		for i in tiles:
			var ix := i % w
			var iy := i / w
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = ix + d.x
				var ny: int = iy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				var a := area[ny * w + nx]
				if a >= 0 and a != int(id):
					touches[a] = true
		if touches.size() >= 2:
			for i in tiles:
				area[i] = -1
				joint[i] = true
		elif touches.size() == 1:
			# A nook opening onto one area (a furnace's window and chamber): part of that area.
			var into_one: int = touches.keys()[0]
			for i in tiles:
				area[i] = into_one
		else:
			# Only joints around it: the one area on the far side of them, if there is exactly one.
			var beyond := {}
			for i in tiles:
				var ix := i % w
				var iy := i / w
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var jx: int = ix + d.x
					var jy: int = iy + d.y
					if jx < 0 or jy < 0 or jx >= w or jy >= h or not joint.has(jy * w + jx):
						continue
					for e in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var kx: int = jx + e.x
						var ky: int = jy + e.y
						if kx < 0 or ky < 0 or kx >= w or ky >= h:
							continue
						var b := area[ky * w + kx]
						if b >= 0 and b != int(id):
							beyond[b] = true
			if beyond.size() == 1:
				var into: int = beyond.keys()[0]
				for i in tiles:
					area[i] = into

	# Which areas are close enough to light each other, and which are the entrance building's.
	var conflicts := {}
	var base_area := {}
	var first_tile := {}   # area -> its first tile index: a stable order (the entrance's tiles never move)
	for y in h:
		for x in w:
			var a := area[y * w + x]
			if a < 0:
				continue
			if not first_tile.has(a):
				first_tile[a] = y * w + x
			if zone.size() == n and (zone[y * w + x] == Store.ZONE_ENTRANCE or zone[y * w + x] == Store.ZONE_OUTDOOR):
				base_area[a] = true
			if not conflicts.has(a):
				conflicts[a] = {}
			for dy in range(0, CONFLICT_TILES + 1):
				for dx in range(-CONFLICT_TILES, CONFLICT_TILES + 1):
					if dy == 0 and dx <= 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var b := area[ny * w + nx]
					if b < 0 or b == a:
						continue
					(conflicts[a] as Dictionary)[b] = true
					if not conflicts.has(b):
						conflicts[b] = {}
					(conflicts[b] as Dictionary)[a] = true

	# Colour: the entrance building and the lot first (stable whatever the wings are), then the wings.
	var bit_of := {}
	var base_list: Array = []
	var wing_list: Array = []
	for a in conflicts.keys():
		(base_list if base_area.has(a) else wing_list).append(a)
	# Most constrained first; the entrance building counts only its own neighbours and orders by tile, so
	# its colours come out the same for every set of wings.
	var degree := func(a) -> int:
		if not base_area.has(a):
			return (conflicts[a] as Dictionary).size()
		var k := 0
		for b in (conflicts[a] as Dictionary).keys():
			if base_area.has(b):
				k += 1
		return k
	for group in [base_list, wing_list]:
		group.sort_custom(func(p, q):
			var dp: int = degree.call(p)
			var dq: int = degree.call(q)
			return dp > dq if dp != dq else int(first_tile[p]) < int(first_tile[q]))
		for a in group:
			var used := {}
			for b in (conflicts[a] as Dictionary).keys():
				if bit_of.has(b) and (base_area.has(b) or not base_area.has(a)):
					used[int(bit_of[b])] = int(used.get(int(bit_of[b]), 0)) + 1
			var pick := -1
			for bit in AREA_BITS:
				if not used.has(int(bit)):
					pick = int(bit)
					break
			if pick < 0:
				# More neighbours than bits: share with the fewest.
				var best := 1 << 30
				for bit in AREA_BITS:
					if int(used.get(int(bit), 0)) < best:
						best = int(used.get(int(bit), 0))
						pick = int(bit)
			bit_of[a] = pick

	var data := PackedInt32Array()
	data.resize(n)
	for i in n:
		var a := area[i]
		if a >= 0:
			data[i] = 1 << int(bit_of.get(a, AREA_BITS[0]))
	# Joints: the bits of everything around them (through other joint tiles too, two steps out).
	for pass_i in 2:
		var add := PackedInt32Array()
		add.resize(n)
		for i in joint.keys():
			var ix: int = int(i) % w
			var iy: int = int(i) / w
			var m := data[i]
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = ix + d.x
				var ny: int = iy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				m |= data[ny * w + nx]
			add[i] = m
		for i in joint.keys():
			data[i] = add[i]
	return {"w": w, "h": h, "data": data}


static func _open(c: String) -> bool:
	return ".+,PTM".contains(c)
