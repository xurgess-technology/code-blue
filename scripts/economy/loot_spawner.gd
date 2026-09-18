extends RefCounted
## Where sellable loot starts a shift. The game calls plan() on the host after the supplies
## spawned and instantiates WorldItems from it (docs/CONTRACTS.md, "Loot and money").
##
## Rules
##   - deterministic from seed, shift and the level (same inputs, same plan);
##   - never in the OR, its anterooms, the clock-in / break room or the neutral area, and never
##     on a container slot or anchor a supply already took (`occupied`);
##   - every location rolls a chance that grows with its wing depth, then a kind weighted by the
##     room kind (LootTable.rooms), the surface or container type, and the tier (rare kinds get
##     likelier deeper); values roll per stack and rise with depth;
##   - bulky loot only on the floor, a counter or a gurney, never inside a container;
##   - at most MAX_PER_UNIT stacks per container unit, so one cabinet is not a treasure chest.
##
## Depth comes from, in order: the location entry's own `depth`, a `level_info.rooms` entry
## containing it, a `level_info.wings` rect containing it, else its distance from the OR table.
##
## Entries: {kind, count, value, container_id ("" when loose), slot, anchor (-1 when not an
## anchor), and `position` when neither (levels without anchors)}.

const LootTable := preload("res://scripts/economy/loot_table.gd")

const SAFE_ROOMS := ["or", "or_storage", "or_lab", "hub_crematorium", "break_room", "hub_personnel",
		"hub_waiting", "lobby", "hub_pharmacy", "anteroom", "clockin", "entrance", "neutral", "outdoor", "dev"]
## Chance a free location holds loot at depth 0; each depth step adds DEPTH_CHANCE_GAIN of it.
const BASE_CHANCE := 0.16
const DEPTH_CHANCE_GAIN := 0.45
const CONTAINER_CHANCE_SCALE := 0.45
const MAX_PER_UNIT := 1
const MIN_LOOT := 6
## Loot stacks a shift holds (inclusive range), trinkets included: few, so most rooms are empty.
const LOOT_PER_SHIFT := [15, 20]
## Without wing data, metres of distance from the table per depth step.
const METRES_PER_DEPTH := 22.0
const MAX_DEPTH := 4


static func plan(seed_value: int, shift: int, info: Dictionary, occupied: Dictionary = {}) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|loot|%d" % [seed_value, shift])
	var locs := _locations(info, occupied)
	if locs.is_empty():
		return []
	# A stable shuffle so the budget cut does not always favour the first rooms built.
	for i in range(locs.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = locs[i]
		locs[i] = locs[j]
		locs[j] = tmp
	var budget := clampi(roundi(locs.size() * 0.22), MIN_LOOT,
			rng.randi_range(int(LOOT_PER_SHIFT[0]), int(LOOT_PER_SHIFT[1])))
	var out: Array = []
	var units := {}
	var kinds := LootTable.kinds()
	# Trinkets are finds: a few a shift in total, some kinds capped (LootTable max_per_shift).
	var wanted := _draw_trinkets(rng)   # kind -> how many are still to place
	var placed := {}
	var out_locs: Array = []
	# Two passes: the first honours the chance roll; the second tops up to MIN_LOOT.
	for pass_i in 2:
		for loc in locs:
			if out.size() >= budget or (pass_i == 1 and out.size() >= MIN_LOOT):
				break
			if loc.get("taken", false) or int(units.get(loc.unit, 0)) >= MAX_PER_UNIT:
				continue
			var depth: int = loc.depth
			var chance := BASE_CHANCE * (1.0 + DEPTH_CHANCE_GAIN * float(depth))
			if loc.container_id != "":
				chance *= CONTAINER_CHANCE_SCALE
			chance *= float(LootTable.ROOM_CHANCE.get(String(loc.room_kind), 1.0))
			if pass_i == 0 and rng.randf() > chance:
				continue
			var kind := _pick_kind(kinds, loc, rng, placed, wanted)
			if kind == "":
				continue
			out.append(_entry(kind, loc, rng))
			out_locs.append(loc)
			placed[kind] = int(placed.get(kind, 0)) + 1
			if wanted.has(kind):
				wanted[kind] = int(wanted[kind]) - 1
			loc["taken"] = true
			units[loc.unit] = int(units.get(loc.unit, 0)) + 1
	# A wanted trinket that found no fitting spot swaps into a plain stack whose spot suits it.
	for kind in wanted.keys():
		for n in maxi(0, int(wanted[kind])):
			var order: Array = range(out.size())
			for i in range(order.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t = order[i]
				order[i] = order[j]
				order[j] = t
			for i in order:
				if not LootTable.is_trinket(String(out[i].kind)) and _fits(kind, out_locs[i]):
					out[i] = _entry(kind, out_locs[i], rng)
					break
	return out


## The shift's trinkets: LootTable.TRINKETS_PER_SHIFT of them, drawn by each kind's trinket_weight,
## a kind with max_per_shift no more than that. {kind: count}.
static func _draw_trinkets(rng: RandomNumberGenerator) -> Dictionary:
	var n := rng.randi_range(int(LootTable.TRINKETS_PER_SHIFT[0]), int(LootTable.TRINKETS_PER_SHIFT[1]))
	var got := {}
	for k in n:
		var open: Array = []
		var total := 0.0
		for kind in LootTable.kinds():
			if LootTable.is_trinket(kind) and int(got.get(kind, 0)) < int(LootTable.LOOT[kind].get("max_per_shift", 1000000)):
				open.append(kind)
				total += float(LootTable.LOOT[kind].get("trinket_weight", 1.0))
		var roll := rng.randf() * total
		for kind in open:
			roll -= float(LootTable.LOOT[kind].get("trinket_weight", 1.0))
			if roll <= 0.0 or kind == open[open.size() - 1]:
				got[kind] = int(got.get(kind, 0)) + 1
				break
	return got


static func _entry(kind: String, loc: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var depth: int = loc.depth
	var d := LootTable.def(kind)
	var b: Array = d.get("batch", [1, 1])
	var count := rng.randi_range(int(b[0]), int(b[1])) if d.get("stack", false) else 1
	var value := 0
	for n in count:
		value += LootTable.roll_value(kind, depth, rng.randf())
	var e := {"kind": kind, "count": count, "value": value, "container_id": loc.container_id,
		"slot": int(loc.slot), "anchor": int(loc.anchor), "depth": depth}
	if loc.container_id == "" and int(loc.anchor) < 0:
		e["position"] = loc.position
		e["yaw"] = rng.randf() * TAU
	return e


## Whether `kind` can sit at `loc` at all (surface, container, bulky rules), whatever the room.
static func _fits(kind: String, loc: Dictionary) -> bool:
	var d: Dictionary = LootTable.LOOT[kind]
	var t: String = loc.type
	if t.begins_with("container:"):
		return not d.get("bulky", false) and float(d.get("containers", {}).get(t.substr(10), 0.0)) > 0.0
	if t.begins_with("loose:"):
		var surf := t.substr(6)
		return (d.get("surfaces", []) as Array).has(surf) and not (d.get("bulky", false) and surf == "tray")
	return true


static func _pick_kind(kinds: Array, loc: Dictionary, rng: RandomNumberGenerator, placed := {}, wanted := {}) -> String:
	var weights: Array = []
	var total := 0.0
	for kind in kinds:
		var d: Dictionary = LootTable.LOOT[kind]
		var w := LootTable.weight(kind, String(loc.room_kind), int(loc.depth))
		if (LootTable.is_trinket(kind) and int(wanted.get(kind, 0)) <= 0) or int(placed.get(kind, 0)) >= int(d.get("max_per_shift", 1000000)):
			w = 0.0
		if w <= 0.0:
			weights.append(0.0)
			continue
		var t: String = loc.type
		if t.begins_with("container:"):
			if d.get("bulky", false):
				w = 0.0
			else:
				w *= float(d.get("containers", {}).get(t.substr(10), 0.0))
		elif t.begins_with("loose:"):
			var surf := t.substr(6)
			if not (d.get("surfaces", []) as Array).has(surf):
				w = 0.0
			elif d.get("bulky", false) and surf == "tray":
				w = 0.0
		weights.append(w)
		total += w
	if total <= 0.0:
		return ""
	var roll := rng.randf() * total
	for i in kinds.size():
		roll -= float(weights[i])
		if roll <= 0.0 and float(weights[i]) > 0.0:
			return kinds[i]
	for i in range(kinds.size() - 1, -1, -1):
		if float(weights[i]) > 0.0:
			return kinds[i]
	return ""


## [{key, unit, container_id, slot, anchor, type ("container:<t>" | "loose:<surface>"), room_kind,
##   position, depth}], sorted by key, without safe rooms or occupied spots.
static func _locations(info: Dictionary, occupied: Dictionary) -> Array:
	var out: Array = []
	var table: Vector3 = info.get("table", Vector3.ZERO)
	for c in info.get("containers", []):
		var node = c.get("node", null)
		var n: int = int(c.get("slots", -1))
		if n < 0 and node != null and is_instance_valid(node) and node.has_method("slot_count"):
			n = node.slot_count()
		var pos: Vector3 = c.get("position", Vector3.ZERO)
		if not c.has("position") and node != null and is_instance_valid(node) and node.is_inside_tree():
			pos = node.global_position
		var room := String(c.get("room_kind", ""))
		if SAFE_ROOMS.has(room):
			continue
		var id := String(c.get("id", ""))
		var parts := id.split("_")
		var unit := "%s_%s_%s" % [parts[0], parts[1], parts[2]] if parts.size() >= 4 else id
		var depth := _depth_of(info, c, pos, table)
		for s in maxi(0, n):
			var key := "%s:%d" % [id, s]
			if occupied.has(key):
				continue
			out.append({"key": key, "unit": unit, "container_id": id, "slot": s, "anchor": -1,
				"type": "container:" + String(c.get("type", "")), "room_kind": room, "position": pos, "depth": depth})
	var anchors: Array = info.get("loose_anchors", [])
	for i in anchors.size():
		var a: Dictionary = anchors[i]
		var room := String(a.get("room_kind", ""))
		if SAFE_ROOMS.has(room) or occupied.has("anchor:%d" % i):
			continue
		out.append({"key": "anchor:%05d" % i, "unit": "anchor:%d" % i, "container_id": "", "slot": 0, "anchor": i,
			"type": "loose:" + String(a.get("surface", "floor")), "room_kind": room, "position": a.position,
			"depth": _depth_of(info, a, a.position, table)})
	if out.is_empty():
		# A level with no containers or anchors (the fallback ward): loot on the floor at the
		# tool spawn points, nudged so it does not sit exactly where a supply might.
		var spots: Array = info.get("tool_spawns", [])
		for i in spots.size():
			var p: Vector3 = spots[i] + Vector3(0.45, 0.0, -0.35)
			out.append({"key": "spot:%05d" % i, "unit": "spot:%d" % i, "container_id": "", "slot": 0, "anchor": -1,
				"type": "loose:floor", "room_kind": "*", "position": p, "depth": _depth_of(info, {}, p, table)})
	out.sort_custom(func(x, y): return String(x.key) < String(y.key))
	return out


static func _depth_of(info: Dictionary, entry: Dictionary, pos: Vector3, table: Vector3) -> int:
	if entry.has("depth"):
		return clampi(int(entry.depth), 0, MAX_DEPTH)
	var tile := Vector2(floor(pos.x / C.TILE), floor(pos.z / C.TILE))
	var world := Vector2(pos.x, pos.z)
	var size = info.get("size", Vector2i.ZERO)
	var tiles_w := float(size.x) if size is Vector2i else 0.0
	for r in info.get("rooms", []):
		if r is Dictionary and r.has("depth") and _rect_has(r, tile, world, tiles_w):
			return clampi(int(r.depth), 0, MAX_DEPTH)
	for w in info.get("wings", []):
		if w is Dictionary and w.has("depth") and _rect_has(w, tile, world, tiles_w):
			return clampi(int(w.depth), 0, MAX_DEPTH)
	var d := Vector2(pos.x - table.x, pos.z - table.z).length()
	return clampi(int(d / METRES_PER_DEPTH), 0, MAX_DEPTH)


## A room or wing rect may be a Rect2 / Rect2i in tiles or in world metres (XZ), or x/y/w/h in
## tiles. A rect reaching past the map's width in tiles must be in metres.
static func _rect_has(r: Dictionary, tile: Vector2, world: Vector2, tiles_w: float) -> bool:
	var rect = r.get("rect", null)
	if rect is Rect2i:
		rect = Rect2(rect)
	if rect is Rect2:
		var rr := rect as Rect2
		var in_world: bool = r.get("space", "") == "world" or (tiles_w > 0.0 and rr.end.x > tiles_w + 1.0)
		return rr.has_point(world) if in_world else rr.has_point(tile + Vector2(0.5, 0.5))
	if r.has("x") and r.has("w"):
		return Rect2(float(r.x), float(r.y), float(r.w), float(r.h)).has_point(tile + Vector2(0.5, 0.5))
	return false
