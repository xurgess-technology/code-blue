class_name MapGen
extends RefCounted
## Deterministic procedural hospital: one floor, an entrance building, three or four wings, and
## a fenced neutral area outside the main doors.
##
##   +------------+-----------------+------------+
##   |            |  north wing(s)  |            |
##   | west wing  +-----------------+ east wing  |
##   |            | entrance bldg.  |            |
##   +------------+-------++--------+------------+
##                |  neutral area   |
##                +-----------------+
##
## Wings are columns sharing walls with each other and the entrance building; each is entered
## through a doorway in the entrance building. Their `depth` (1 = shallowest) follows their
## area: deeper wings are bigger, darker (fewer working fixtures, more flicker) and meant for
## better loot. See scripts/level/*.gd for the parts and docs/CONTRACTS.md ("Hospital").
##
## Tile legend (rows):
##   #  wall / solid            .  indoor floor            +  doorway (walkable)
##   ,  outdoor ground           =  outdoor fence (solid)
##   P  player spawn (x4, break room)   T  tool spawn candidate   M  monster spawn candidate
## Walkable: . + , P T M. Furniture never changes a character; `blocked` marks the tiles it fills.
## Only # and = block line of sight.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Entrance := preload("res://scripts/level/entrance.gd")
const Neutral := preload("res://scripts/level/neutral.gd")
const WingGen := preload("res://scripts/level/wing_gen.gd")
const Rooms := preload("res://scripts/level/room_furnish.gd")
const DoorPlan := preload("res://scripts/level/door_plan.gd")
const ItemsData := preload("res://scripts/items.gd")

## Kept for callers that still pass a size; the layout decides the real size.
const DEFAULT_WIDTH := 100
const DEFAULT_HEIGHT := 84

const WALKABLE_CHARS := ".+,PTM"
const LEGEND_CHARS := "#.+,=PTM"
const MIN_TOOLS := 16
const MIN_MONSTERS := 8
const MONSTER_MIN_DIST := 18
const MAX_ATTEMPTS := 8

## Rooms where monsters never spawn and nothing a case needs is placed.
const SAFE_ROOMS := ["or", "scrub_room", "break_room", "locker_room", "lobby"]
## Wing ids of the zones that are not wings.
const SAFE_WINGS := ["entrance", "neutral"]

const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]

## Legacy: the builder used to scatter these from `props`; clutter is furniture now.
const PROP_CHARS := {}

## Fixture states per zone: [steady, flicker] cumulative chances, the rest are dead.
const LIGHTS_ENTRANCE := [0.86, 1.0]
## Wings by depth 1..4.
const LIGHTS_WING := [[0.36, 0.66], [0.27, 0.62], [0.19, 0.58], [0.12, 0.54]]


class Rng extends "res://scripts/level/rng.gd":
	func _init(s: int) -> void:
		super(s)


static func is_walkable_char(c: String) -> bool:
	return WALKABLE_CHARS.contains(c)


static func _is_walkable_code(c: int) -> bool:
	return S.walkable_code(c)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Generate a hospital. `seed` is the run: it fixes the entrance building, the neutral area and
## how many wings there are. `wing_seed` lays out the wings behind the gates (-1: the run seed,
## which is what shift 1 uses); every shift of a run regenerates them from its own wing seed
## (`wing_seed_for`) while the entrance and everything outside stay identical, tile for tile.
## Returns a dictionary; see docs/CONTRACTS.md "Hospital" for every key.
static func generate(seed: int, wing_seed := -1, _height := DEFAULT_HEIGHT) -> Dictionary:
	var ws := seed if wing_seed < 0 else wing_seed
	var best: Dictionary = {}
	for attempt in MAX_ATTEMPTS:
		var gen := _attempt(seed, ws, attempt)
		if gen.get("missing", []).is_empty():
			return gen
		if best.is_empty() or gen.missing.size() < best.missing.size():
			best = gen
	return best


## The wing seed of a run's shift: shift 1 lays out the wings from the run seed itself.
static func wing_seed_for(run_seed: int, generation: int) -> int:
	if generation <= 1:
		return run_seed
	return (run_seed * 2654435761 + generation * 40503 + 0x51ED27) & 0x7FFFFFFF


## Where the entrance building's top-left tile is, for every run and every shift: wings of any
## size attach to it, so its gates, rooms and landmarks never move.
const ENTRANCE_ORIGIN := Vector2i(32, 34)
## Wing sizes (tiles): side wings' widths and every wing's reach north of the entrance.
const SIDE_WING_W := Vector2i(20, 32)
const WING_REACH := Vector2i(22, 34)


static func _attempt(seed: int, wing_seed: int, attempt: int) -> Dictionary:
	var sub := wing_seed if attempt == 0 else (wing_seed * 7919 + attempt * 104729) & 0x7FFFFFFF
	# The run's own stream: the wing count and the neutral area's parked cars never change
	# within a run.
	var run_rng := Rng.new(seed)
	var rng := Rng.new(sub)
	var four := run_rng.chance(0.42)
	var ww := rng.rint(SIDE_WING_W.x, SIDE_WING_W.y)
	var ew := rng.rint(SIDE_WING_W.x, SIDE_WING_W.y)
	var ex := ENTRANCE_ORIGIN.x
	var ey := ENTRANCE_ORIGIN.y
	var ey1 := ey + Entrance.H - 1
	var W := ex + Entrance.W - 1 + SIDE_WING_W.y + 1
	var H := ey1 + 1 + Neutral.OUT_H + 2
	var st := S.new(W, H)
	var top := func() -> int:
		return ey - rng.rint(WING_REACH.x, WING_REACH.y)

	# ---- wings: rects, doorways, depth by area ------------------------------------------
	var side: Array = Entrance.SIDE_DOOR_ROWS
	var defs: Array = []
	var tw: int = top.call()
	defs.append({"id": "west", "rect": Rect2i(ex - ww, tw, ww + 1, ey1 - tw + 1),
			"entry": [Vector2i(ex, ey + side[0]), Vector2i(ex, ey + side[1])], "dir": Vector2i(-1, 0)})
	if four:
		var a: Array = Entrance.NORTH_DOORS_TWO[0]
		var b: Array = Entrance.NORTH_DOORS_TWO[1]
		var t1: int = top.call()
		var t2: int = top.call()
		defs.append({"id": "north_west", "rect": Rect2i(ex, t1, 15, ey - t1 + 1),
				"entry": [Vector2i(ex + a[0], ey), Vector2i(ex + a[1], ey)], "dir": Vector2i(0, -1)})
		defs.append({"id": "north_east", "rect": Rect2i(ex + 14, t2, Entrance.W - 14, ey - t2 + 1),
				"entry": [Vector2i(ex + b[0], ey), Vector2i(ex + b[1], ey)], "dir": Vector2i(0, -1)})
	else:
		var c: Array = Entrance.NORTH_DOORS_ONE
		var tn: int = top.call()
		defs.append({"id": "north", "rect": Rect2i(ex, tn, Entrance.W, ey - tn + 1),
				"entry": [Vector2i(ex + c[0], ey), Vector2i(ex + c[1], ey)], "dir": Vector2i(0, -1)})
	var te: int = top.call()
	defs.append({"id": "east", "rect": Rect2i(ex + Entrance.W - 1, te, ew + 1, ey1 - te + 1),
			"entry": [Vector2i(ex + Entrance.W - 1, ey + side[0]), Vector2i(ex + Entrance.W - 1, ey + side[1])], "dir": Vector2i(1, 0)})
	var by_area := defs.duplicate()
	by_area.sort_custom(func(a, b):
		var aa: int = a.rect.size.x * a.rect.size.y
		var ba: int = b.rect.size.x * b.rect.size.y
		return aa < ba or (aa == ba and String(a.id) < String(b.id)))
	for i in by_area.size():
		by_area[i]["depth"] = i + 1
	for i in defs.size():
		defs[i]["zone"] = S.ZONE_WING0 + i
		var r: Rect2i = defs[i].rect
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if st.zone[st.idx(x, y)] == S.ZONE_NONE:
					st.zone[st.idx(x, y)] = S.ZONE_WING0 + i
	st.wings = defs

	# ---- entrance building and neutral area ----------------------------------------------
	Entrance.build(st, ex, ey, 2 if four else 1)
	var neutral_rect := Neutral.build(st, ex + Entrance.DOOR_X, ey1 + 1, run_rng)

	# ---- wings: hallways and room slots, then which room is which --------------------------
	var gens: Array = []
	for d in defs:
		gens.append(WingGen.carve(st, d, rng))
	var missing := _assign_kinds(gens, defs, rng)
	for g in gens:
		g.place_rooms()
	for g in gens:
		g.finish()

	_place_markers(st, rng)
	_light_modes(st, seed, sub)
	var doors := DoorPlan.plan(st, Rect2i(ex, ey, Entrance.W, Entrance.H))

	var rooms: Array = []
	for r in st.rooms:
		rooms.append(r)
	var wings: Array = []
	for d in defs:
		wings.append({"id": d.id, "rect": d.rect, "depth": d.depth, "zone": d.zone, "entry": d.entry, "dir": d.dir})

	return {
		"seed": seed,
		"wing_seed": wing_seed,
		"doors": doors,
		"attempt": attempt,
		"missing": missing,
		"width": W,
		"height": H,
		"rows": st.rows(),
		"zone": st.zone,
		"room_at": st.room_at,
		"blocked": st.blocked,
		"rooms": rooms,
		"wings": wings,
		"entrance_rect": Rect2i(ex, ey, Entrance.W, Entrance.H),
		"neutral_rect": neutral_rect,
		"furniture": st.furniture,
		"containers": st.containers,
		"lights": st.lights,
		"spots": st.spots,
		"props": [],
	}


## Rooms every wing must have, so each wing can supply every surgical item.
const WING_ROOMS := ["nurse_station", "supply_closet", "janitor_closet", "patient_room", "patient_room", "office", "restroom"]


## Does a slot of w x d (along the door wall x away from it) suit a room kind?
static func _fits(kind: String, wd: Vector2i, tol_w: int, tol_d: int, shrink := 0) -> bool:
	var k: Dictionary = Rooms.KINDS[kind]
	return wd.x >= int(k.w[0]) - shrink and wd.x <= int(k.w[1]) + tol_w \
			and wd.y >= maxi(3, int(k.d[0]) - shrink) and wd.y <= int(k.d[1]) + tol_d


static func _slack(kind: String, wd: Vector2i) -> int:
	var k: Dictionary = Rooms.KINDS[kind]
	return absi(wd.x - int(k.w[0])) + absi(wd.y - int(k.d[0]))


## Give every room slot a kind: the rooms each wing needs, the map's special rooms in the wings
## the design wants them (deeper wings get the lab, radiology and the morgue), then weighted
## filler. Returns what could not be placed anywhere.
static func _assign_kinds(gens: Array, defs: Array, rng: Rng) -> Array:
	var n := defs.size()
	var by_depth := {}
	for i in n:
		by_depth[int(defs[i].depth)] = i
	var want: Array = []
	for i in n:
		for k in WING_ROOMS:
			want.append({"wing": i, "kind": k, "roam": false})
	var special := [["waiting_room", 1], ["cafeteria", mini(2, n)], ["pharmacy", rng.rint(2, n)],
			["lab", n - 1], ["radiology", n], ["morgue", n]]
	for sp in special:
		want.append({"wing": by_depth[clampi(int(sp[1]), 1, n)], "kind": sp[0], "roam": true})
	var map_counts := {}
	var wing_counts: Array = []
	for i in n:
		wing_counts.append({})
	var missing: Array = []
	while not want.is_empty():
		# The most constrained room next: the one with the fewest free slots that suit it
		# exactly, bigger rooms first on a tie.
		var wi := 0
		var best_n := 1 << 30
		var best_area := -1
		# The rooms every wing needs go first; the map's special rooms can move to another wing.
		var any_fixed := false
		for cand in want:
			if not cand.roam:
				any_fixed = true
				break
		for i in want.size():
			var cand: Dictionary = want[i]
			if any_fixed and cand.roam:
				continue
			var fits := 0
			for slot in gens[cand.wing].slots:
				if String(slot.kind) == "" and _fits(cand.kind, WingGen.slot_wd(slot), 0, 0, 0):
					fits += 1
			var area := int(Rooms.KINDS[cand.kind].w[0]) * int(Rooms.KINDS[cand.kind].d[0])
			if fits < best_n or (fits == best_n and area > best_area):
				best_n = fits
				best_area = area
				wi = i
		var w: Dictionary = want[wi]
		want.remove_at(wi)
		var order: Array = [w.wing]
		if w.roam:
			# Nearest depth first.
			var others: Array = range(n)
			others.erase(w.wing)
			var d0 := int(defs[w.wing].depth)
			others.sort_custom(func(a, b): return absi(int(defs[a].depth) - d0) < absi(int(defs[b].depth) - d0))
			order.append_array(others)
		var done := false
		for tol in [[0, 0, 0], [1, 0, 0], [2, 1, 0], [3, 2, 1]]:
			for gi in order:
				var best: Array = []
				for slot in gens[gi].slots:
					if String(slot.kind) != "":
						continue
					var wd: Vector2i = WingGen.slot_wd(slot)
					if _fits(w.kind, wd, tol[0], tol[1], tol[2]):
						best.append([_slack(w.kind, wd), slot])
				if best.is_empty():
					continue
				best.sort_custom(func(a, b): return a[0] < b[0])
				var pick: Dictionary = best[rng.rint(0, mini(2, best.size() - 1))][1]
				pick.kind = w.kind
				map_counts[w.kind] = int(map_counts.get(w.kind, 0)) + 1
				wing_counts[gi][w.kind] = int(wing_counts[gi].get(w.kind, 0)) + 1
				done = true
				break
			if done:
				break
		if not done:
			# No free slot suits it: split the widest free slot of the wing in two and try again.
			if int(w.get("splits", 0)) < 3 and _split_slot(gens[w.wing], w.kind):
				w["splits"] = int(w.get("splits", 0)) + 1
				want.append(w)
			else:
				missing.append("%s: %s" % [defs[w.wing].id, w.kind])
	# Filler, weighted by depth.
	for gi in n:
		var depth := int(defs[gi].depth)
		for slot in gens[gi].slots:
			if String(slot.kind) != "":
				continue
			var wd: Vector2i = WingGen.slot_wd(slot)
			var kinds: Array = []
			var weights: Array = []
			for k in Rooms.KINDS.keys():
				if not _fits(k, wd, 2, 1):
					continue
				if Rooms.MAP_CAP.has(k) and int(map_counts.get(k, 0)) >= int(Rooms.MAP_CAP[k]):
					continue
				if Rooms.WING_CAP.has(k) and int(wing_counts[gi].get(k, 0)) >= int(Rooms.WING_CAP[k]):
					continue
				var wgt: float = Rooms.KINDS[k].weight
				if k == "morgue" or k == "radiology" or k == "lab":
					wgt *= 0.4 + 0.4 * depth
				if k == "waiting_room" or k == "cafeteria":
					wgt *= 1.6 if depth <= 1 else 0.3
				kinds.append(k)
				weights.append(wgt)
			var kind := ""
			var i := rng.weighted(weights)
			if i >= 0:
				kind = kinds[i]
			elif wd.x <= 5 and wd.y <= 5:
				kind = "supply_closet"
			else:
				kind = "patient_room"
			slot.kind = kind
			map_counts[kind] = int(map_counts.get(kind, 0)) + 1
			wing_counts[gi][kind] = int(wing_counts[gi].get(kind, 0)) + 1
	return missing


## Split the widest free slot of a wing (along its door wall) into two with a wall between, so
## a small room that found no slot gets one. The first part is sized for `kind`.
static func _split_slot(g: RefCounted, kind: String) -> bool:
	var best: Dictionary = {}
	var best_w := 0
	for slot in g.slots:
		if String(slot.kind) != "":
			continue
		var wd: Vector2i = WingGen.slot_wd(slot)
		if wd.x >= 7 and wd.x > best_w and wd.y >= maxi(3, int(Rooms.KINDS[kind].d[0]) - 1):
			best_w = wd.x
			best = slot
	if best.is_empty():
		return false
	var r: Rect2i = best.rect
	var f: Vector2i = best.front
	var w1 := clampi(int(Rooms.KINDS[kind].w[1]), 3, best_w - 4)
	var a: Rect2i
	var b: Rect2i
	if f.x == 0:
		a = Rect2i(r.position.x, r.position.y, w1, r.size.y)
		b = Rect2i(r.position.x + w1 + 1, r.position.y, r.size.x - w1 - 1, r.size.y)
	else:
		a = Rect2i(r.position.x, r.position.y, r.size.x, w1)
		b = Rect2i(r.position.x, r.position.y + w1 + 1, r.size.x, r.size.y - w1 - 1)
	best.rect = a
	g.slots.append({"rect": b, "front": f, "kind": "", "wing": best.wing})
	return true


## Player spawns are stamped by the entrance; here: tool spawn candidates in wing rooms and
## monster spawns on wing hallways, spread out and far from the break room.
static func _place_markers(st: S, rng: Rng) -> void:
	var furniture_tiles := {}
	for e in st.furniture:
		furniture_tiles[Vector2i(int(floor(e.pos.x)), int(floor(e.pos.y)))] = true
	var free := func(x: int, y: int) -> bool:
		return st.get_c(x, y) == S.CH_FLOOR and st.open(x, y) and st.keep[st.idx(x, y)] == 0 \
				and not furniture_tiles.has(Vector2i(x, y)) and not st.door_near(x, y)
	var tools := 0
	for r in st.rooms:
		if String(r.wing) in SAFE_WINGS:
			continue
		var cands: Array = []
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if free.call(x, y):
					cands.append(Vector2i(x, y))
		rng.shuffle(cands)
		for i in mini(cands.size(), rng.rint(1, 2)):
			st.set_c(cands[i].x, cands[i].y, S.CH_TOOL)
			tools += 1
	var spawns: Array[Vector2i] = []
	for y in st.h:
		for x in st.w:
			if st.get_c(x, y) == S.CH_PLAYER:
				spawns.append(Vector2i(x, y))
	var cands: Array = []
	for y in st.h:
		for x in st.w:
			var zn := st.zone_at(x, y)
			if zn < S.ZONE_WING0 or zn == S.ZONE_OUTDOOR or st.room_index(x, y) >= 0:
				continue
			if not free.call(x, y):
				continue
			var ok := true
			for p in spawns:
				if absi(p.x - x) + absi(p.y - y) < MONSTER_MIN_DIST:
					ok = false
					break
			if ok:
				cands.append(Vector2i(x, y))
	if cands.is_empty():
		return
	# Farthest-point sampling, a couple per wing and more in the deeper ones.
	var want := 0
	for wdef in st.wings:
		want += 1 + int(wdef.depth)
	var chosen: Array[Vector2i] = [rng.pick(cands)]
	while chosen.size() < want and chosen.size() < cands.size():
		var best := Vector2i.ZERO
		var best_d := -1
		for c in cands:
			var d := 1 << 30
			for k in chosen:
				d = mini(d, absi(c.x - k.x) + absi(c.y - k.y))
			if d > best_d:
				best_d = d
				best = c
		if best_d <= 0:
			break
		chosen.append(best)
	for c in chosen:
		st.set_c(c.x, c.y, S.CH_MON)


## Fixture modes. The entrance building and the outdoor lights roll from the run seed (they are
## stamped first, so their order never changes); the wings from the wing seed.
static func _light_modes(st: S, run_seed: int, wing_seed: int) -> void:
	var run_rng := Rng.new((run_seed ^ 0x5f356495) & 0xFFFFFFFF)
	var wing_rng := Rng.new((wing_seed ^ 0x5f356495) & 0xFFFFFFFF)
	var depth_of := {}
	for wdef in st.wings:
		depth_of[int(wdef.zone)] = int(wdef.depth)
	for l in st.lights:
		var zl := int(l.zone)
		var roll := run_rng.nextf() if zl == S.ZONE_ENTRANCE or zl == S.ZONE_OUTDOOR else wing_rng.nextf()
		if int(l.mode) >= 0:
			continue
		var table: Array = LIGHTS_ENTRANCE
		var zn := int(l.zone)
		if depth_of.has(zn):
			table = LIGHTS_WING[clampi(int(depth_of[zn]) - 1, 0, LIGHTS_WING.size() - 1)]
		l["mode"] = 0 if roll < float(table[0]) else (1 if roll < float(table[1]) else 2)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

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
	for m in gen.get("missing", []):
		problems.append("room never placed: %s" % m)

	# Rebuild a state over the rows so the same helpers answer every question.
	var st := S.new(w, h)
	for y in h:
		var row := rows[y]
		for x in w:
			st.cells[y * w + x] = row.unicode_at(x)
			if not LEGEND_CHARS.contains(row[x]):
				problems.append("unknown tile '%s' at %d,%d" % [row[x], x, y])
	st.zone = gen.zone
	st.room_at = gen.room_at
	st.blocked = gen.blocked
	var at := func(x: int, y: int) -> String:
		return "#" if x < 0 or y < 0 or x >= w or y >= h else rows[y][x]

	for x in w:
		for y in [0, h - 1]:
			if at.call(x, y) != "#":
				problems.append("border not wall at %d,%d" % [x, y])
	for y in h:
		for x in [0, w - 1]:
			if at.call(x, y) != "#":
				problems.append("border not wall at %d,%d" % [x, y])

	var rooms: Array = gen.get("rooms", [])
	var wings: Array = gen.get("wings", [])
	var er: Rect2i = gen.entrance_rect
	var nr: Rect2i = gen.neutral_rect
	var kind_count := {}
	for r in rooms:
		kind_count[r.kind] = int(kind_count.get(r.kind, 0)) + 1
		if not r.has("wing") or not r.has("depth"):
			problems.append("room %d (%s) has no wing or depth" % [r.id, r.kind])
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if at.call(x, y) == "#":
					problems.append("room %s at %d,%d contains a wall at %d,%d" % [r.kind, r.x, r.y, x, y])
				elif st.room_at[y * w + x] != int(r.id):
					problems.append("room %s at %d,%d overlaps another room at %d,%d" % [r.kind, r.x, r.y, x, y])
	for k in ["or", "scrub_room", "break_room", "lobby", "locker_room"]:
		if int(kind_count.get(k, 0)) != 1:
			problems.append("expected 1 '%s' room, found %d" % [k, kind_count.get(k, 0)])
	for k in ["pharmacy", "morgue", "lab", "radiology", "cafeteria", "waiting_room"]:
		if int(kind_count.get(k, 0)) < 1:
			problems.append("no %s on the map" % k)

	# Wings: 3 or 4, depths 1..n, each with its essential rooms.
	if wings.size() < 3 or wings.size() > 4:
		problems.append("expected 3 or 4 wings, found %d" % wings.size())
	var depths := {}
	for wd in wings:
		depths[int(wd.depth)] = true
		var kinds := {}
		for r in rooms:
			if String(r.wing) == String(wd.id):
				kinds[r.kind] = true
		for k in ["nurse_station", "supply_closet", "janitor_closet", "patient_room"]:
			if not kinds.has(k):
				problems.append("wing %s has no %s" % [wd.id, k])
	for i in wings.size():
		if not depths.has(i + 1):
			problems.append("no wing at depth %d" % (i + 1))

	# Landmarks.
	var spots: Dictionary = gen.get("spots", {})
	for key in ["clock", "phone", "lectern", "shelf", "or_screen", "entrance", "ambulance", "shop", "sell_bin", "gold_pile"]:
		if not spots.has(key):
			problems.append("spot '%s' was never placed" % key)
	var room_of := func(p: Vector2) -> Dictionary:
		var ri: int = st.room_at[int(floor(p.y)) * w + int(floor(p.x))] if Rect2i(0, 0, w, h).has_point(Vector2i(int(floor(p.x)), int(floor(p.y)))) else -1
		return rooms[ri] if ri >= 0 else {}
	var tables: Array = spots.get("tables", [])
	var patient := 0
	var player := 0
	for t in tables:
		if String(room_of.call(t.pos).get("kind", "")) != "or":
			problems.append("table at %s is not in the OR" % str(t.pos))
		if t.kind == "patient":
			patient += 1
		elif t.kind == "player":
			player += 1
	if patient != 2 or player != 1:
		problems.append("expected 2 patient tables and 1 player table, found %d and %d" % [patient, player])
	for key in ["clock", "lectern"]:
		if spots.has(key) and String(room_of.call(spots[key].pos).get("kind", "")) != "break_room":
			problems.append("%s is not in the break room" % key)
	if spots.has("phone") and String(room_of.call(spots.phone.pos + Vector2(0.3, 0.0)).get("kind", "")) != "break_room":
		problems.append("phone is not on a break room wall")
	for key in ["shop", "sell_bin", "gold_pile", "ambulance"]:
		if spots.has(key) and not Rect2(nr).grow(0.01).has_point(spots[key].pos):
			problems.append("%s is outside the neutral area" % key)
	for p in spots.get("neutral_spawns", []):
		var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
		if not nr.has_point(t) or not st.open(t.x, t.y):
			problems.append("neutral spawn %s is not open outdoor ground" % str(p))
	if spots.get("neutral_spawns", []).size() < 4:
		problems.append("fewer than 4 neutral spawn points")

	# Markers.
	var ps: Array[Vector2i] = []
	var ts := 0
	var ms: Array[Vector2i] = []
	for y in h:
		for x in w:
			match rows[y][x]:
				"P": ps.append(Vector2i(x, y))
				"T": ts += 1
				"M": ms.append(Vector2i(x, y))
	if ps.size() != 4:
		problems.append("expected 4 'P', found %d" % ps.size())
	for p in ps:
		if String(room_of.call(Vector2(p) + Vector2(0.5, 0.5)).get("kind", "")) != "break_room":
			problems.append("'P' at %d,%d is outside the break room" % [p.x, p.y])
	if ts < MIN_TOOLS:
		problems.append("expected >= %d 'T', found %d" % [MIN_TOOLS, ts])
	if ms.size() < MIN_MONSTERS:
		problems.append("expected >= %d 'M', found %d" % [MIN_MONSTERS, ms.size()])
	for m in ms:
		if er.has_point(m) or nr.grow(1).has_point(m):
			problems.append("'M' at %d,%d is in the entrance building or neutral area" % [m.x, m.y])
		if st.zone_at(m.x, m.y) < S.ZONE_WING0 or st.zone_at(m.x, m.y) == S.ZONE_OUTDOOR:
			problems.append("'M' at %d,%d is not in a wing" % [m.x, m.y])
		for p in ps:
			if absi(m.x - p.x) + absi(m.y - p.y) < MONSTER_MIN_DIST:
				problems.append("'M' at %d,%d is too close to a player spawn" % [m.x, m.y])

	# Doorways, and the door hanging in each.
	var door_of := {}
	for d in gen.get("doors", []):
		for t in d.tiles:
			if door_of.has(t):
				problems.append("doorway %s has two doors" % str(t))
			door_of[t] = d
		if not DoorPlan.passable(d):
			problems.append("%s door %s opens only %d/%d degrees" % [d.kind, d.id, int(d.max_in), int(d.max_out)])
	for y in h:
		for x in w:
			if rows[y][x] != "+":
				continue
			if not door_of.has(Vector2i(x, y)):
				problems.append("doorway at %d,%d has no door" % [x, y])
			var ns: bool = st.walkable(x, y - 1) and st.walkable(x, y + 1)
			var ew: bool = st.walkable(x - 1, y) and st.walkable(x + 1, y)
			if not ns and not ew:
				problems.append("door at %d,%d lacks walkable tiles on two opposite sides" % [x, y])
			for off in [Vector2i(1, 0), Vector2i(0, 1)]:
				var o := Vector2i(x + off.x, y + off.y)
				if at.call(o.x, o.y) == "+" and not er.grow(0).has_point(Vector2i(x, y)):
					# The two halves of one double doorway are fine.
					if not (door_of.has(o) and door_of.has(Vector2i(x, y)) and door_of[o] == door_of[Vector2i(x, y)]):
						problems.append("doors at %d,%d and %d,%d are adjacent" % [x, y, o.x, o.y])

	# Lights on walkable tiles.
	for l in gen.get("lights", []):
		if not st.walkable(l.tile.x, l.tile.y):
			problems.append("light at %d,%d is not on a walkable tile" % [l.tile.x, l.tile.y])

	# Containers.
	var site_keys := {}
	for s in gen.get("containers", []):
		var t: Vector2i = s.tile
		var d: Vector2i = s.wall
		if not ItemsData.CONTAINER_TYPES.has(s.type):
			problems.append("container at %d,%d has unknown type '%s'" % [t.x, t.y, s.type])
			continue
		if not (Rooms.CONTAINER_ROOMS.get(s.type, []) as Array).has(s.room_kind):
			problems.append("%s at %d,%d is not allowed in a %s" % [s.type, t.x, t.y, s.room_kind])
		if not st.walkable(t.x, t.y):
			problems.append("%s at %d,%d is on a solid tile" % [s.type, t.x, t.y])
		if at.call(t.x + d.x, t.y + d.y) != "#":
			problems.append("%s at %d,%d has no wall behind it" % [s.type, t.x, t.y])
		if not st.open(t.x - d.x, t.y - d.y):
			problems.append("%s at %d,%d cannot be reached from the front" % [s.type, t.x, t.y])
		if st.door_adjacent(t.x, t.y):
			problems.append("%s at %d,%d is next to a door" % [s.type, t.x, t.y])
		if site_keys.has(t):
			problems.append("two containers share the tile %d,%d" % [t.x, t.y])
		site_keys[t] = true
		if er.has_point(t) or nr.has_point(t):
			problems.append("%s at %d,%d is in the entrance building or neutral area" % [s.type, t.x, t.y])

	# Required furniture and containers per room kind.
	var pieces := {}
	for e in gen.get("furniture", []):
		if int(e.room) < 0:
			continue
		if not pieces.has(int(e.room)):
			pieces[int(e.room)] = {}
		pieces[int(e.room)][e.kind] = true
	var cts := {}
	for s in gen.get("containers", []):
		if int(s.room) < 0:
			continue
		if not cts.has(int(s.room)):
			cts[int(s.room)] = {}
		cts[int(s.room)][s.type] = true
	for r in rooms:
		var have: Dictionary = pieces.get(int(r.id), {})
		for req in Rooms.REQUIRED.get(r.kind, []):
			var options: Array = req if req is Array else [req]
			var ok := false
			for o in options:
				if have.has(o):
					ok = true
			if not ok:
				problems.append("%s %d at %d,%d has no %s" % [r.kind, r.id, r.x, r.y, "/".join(options)])
		for req in Rooms.REQUIRED_CONTAINERS.get(r.kind, []):
			if not cts.get(int(r.id), {}).has(req):
				problems.append("%s %d at %d,%d has no %s" % [r.kind, r.id, r.x, r.y, req])

	# Connectivity: everything open is reachable from the neutral area.
	var start := Vector2i(-1, -1)
	if not spots.get("neutral_spawns", []).is_empty():
		var p: Vector2 = spots.neutral_spawns[0]
		start = Vector2i(int(floor(p.x)), int(floor(p.y)))
	if start.x < 0:
		problems.append("no neutral spawn to test connectivity from")
		return problems
	var reach := st.flood([start])
	var unreached := 0
	var example := Vector2i(-1, -1)
	for y in h:
		for x in w:
			if st.open(x, y) and reach[y * w + x] == 0:
				unreached += 1
				if example.x < 0:
					example = Vector2i(x, y)
	if unreached > 0:
		problems.append("%d open tile(s) unreachable from the neutral area (e.g. %d,%d)" % [unreached, example.x, example.y])
	for r in rooms:
		var any := false
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if reach[y * w + x] == 1:
					any = true
		if not any:
			problems.append("room %s %d at %d,%d is unreachable" % [r.kind, r.id, r.x, r.y])
	return problems
