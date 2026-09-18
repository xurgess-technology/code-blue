class_name ItemSpawner
extends RefCounted
## Decides where every item stack starts a shift (see docs/CONTRACTS.md, "Item spawning").
##
## Rules `plan()` guarantees, all checked by tools/spawncheck.gd:
##   - every consumable the ailment needs totals at least twice Procedures.requirements(), in
##     at least four stacks at different places (different container units / anchors);
##   - every needed tool exists at least twice;
##   - every wing holds at least one stack of something the case needs;
##   - nothing needed spawns in the entrance building (OR, scrub room, break room, locker room,
##     lobby, its halls) or the neutral area outside;
##   - at least one needed item is far (FAR_M) from the table;
##   - items the ailment does not need spawn too, as red herrings;
##   - stack counts are inside Items batch ranges; one stack per container slot and per anchor;
##   - choice between container types and loose surfaces follows Items.ITEMS[kind].found;
##   - the same seed, shift, ailment and level always give the same plan.
## Extra needed stacks lean toward the deeper wings.
##
## Entries: {kind, count, container_id ("" when loose), slot, anchor (-1 when in a container)}.
## Levels without wings (the fallback ward, tool levels) count as one wing.

const ItemsData := preload("res://scripts/items.gd")
const ProceduresData := preload("res://scripts/procedures.gd")

const SAFE_ROOMS := ["or", "or_storage", "or_lab", "hub_crematorium", "break_room", "hub_personnel",
		"hub_waiting", "lobby", "hub_pharmacy", "entrance", "neutral", "anteroom", "clockin"]
## Horizontal metres from the table that count as "far".
const FAR_M := 24.0
## Stacks of one kind try to stay at least this far apart.
const SPREAD_M := 12.0
## Needed supply, as a multiple of the old amounts.
const TOOL_COPIES := 2
const CONSUMABLE_STACKS := [4, 6]


static func plan(seed_value: int, shift: int, ailment_id: String, info: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|items|%d|%s" % [seed_value, shift, ailment_id])
	var locs := _locations(info)
	var table: Vector3 = info.get("table", Vector3.ZERO)
	var need := ProceduresData.requirements(ailment_id)
	var used := {}
	var out: Array = []

	var needed: Array = []
	var herrings: Array = []
	for kind in ItemsData.SURGICAL:
		if need.has(kind):
			needed.append(kind)
		else:
			herrings.append(kind)

	# Every needed stack, interleaved by kind so the first few cover every kind.
	var per_kind := {}
	var longest := 0
	for kind in needed:
		per_kind[kind] = _needed_counts(kind, int(need[kind]), rng)
		longest = maxi(longest, (per_kind[kind] as Array).size())
	var stacks: Array = []
	for i in longest:
		for kind in needed:
			var counts: Array = per_kind[kind]
			if i < counts.size():
				stacks.append({"kind": kind, "count": counts[i], "first": i == 0})

	# Which wing each stack aims for: one for every wing first, then weighted toward depth.
	var wings := _wings(locs)
	var order: Array = wings.keys()
	order.sort()
	_shuffle(order, rng)
	var targets: Array = []
	for i in stacks.size():
		if i < order.size():
			targets.append(order[i])
		else:
			targets.append(_weighted_wing(wings, order, rng))
	# The stack sent to the deepest wing is the one that must be far from the table.
	var far_i := -1
	var far_depth := -1
	for i in mini(stacks.size(), order.size()):
		if int(wings[order[i]]) > far_depth:
			far_depth = int(wings[order[i]])
			far_i = i
	if far_i < 0 and not stacks.is_empty():
		far_i = 0

	var placed := {}
	var units := {}
	for i in stacks.size():
		var s: Dictionary = stacks[i]
		var kind: String = s.kind
		if not placed.has(kind):
			placed[kind] = [] as Array[Vector3]
			units[kind] = {}
		var loc := _choose(kind, locs, used, units[kind], placed[kind], rng, table, i == far_i, true, targets[i])
		if loc.is_empty():
			continue
		var pl: Array[Vector3] = placed[kind]
		_take(loc, used, units[kind], pl)
		out.append(_entry(kind, int(s.count), loc))

	for kind in herrings:
		var copies := 1
		if ItemsData.is_consumable(kind):
			copies = rng.randi_range(1, 2)
		var pl: Array[Vector3] = []
		var un := {}
		for i in copies:
			var loc := _choose(kind, locs, used, un, pl, rng, table, false, true, "")
			if loc.is_empty():
				continue
			_take(loc, used, un, pl)
			out.append(_entry(kind, _batch(kind, rng), loc))
	return out


static func shortfall_plan(seed_value: int, need: Dictionary, have: Dictionary, info: Dictionary,
		occupied: Dictionary, avoid: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	var locs := _locations(info)
	var used := occupied.duplicate()
	var out: Array = []
	var kinds := need.keys()
	kinds.sort()
	for kind in kinds:
		var short: int = int(need[kind]) - int(have.get(kind, 0))
		if short <= 0 or not ItemsData.exists(kind):
			continue
		rng.seed = hash("%d|shortfall|%s|%d|%d" % [seed_value, kind, short, used.size()])
		var counts: Array[int] = []
		if ItemsData.is_consumable(kind):
			var total := 0
			# Top up with one spare so a single fumble does not softlock again.
			while total < short + 1:
				var c := _batch(kind, rng)
				counts.append(c)
				total += c
		else:
			counts.append(1)
		var placed: Array[Vector3] = []
		var units := {}
		for c in counts:
			var loc := _farthest(kind, locs, used, units, avoid, rng)
			if loc.is_empty():
				break
			_take(loc, used, units, placed)
			out.append(_entry(kind, c, loc))
	return out


# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

## Every place a stack can go: [{key, unit, container_id, slot, anchor, type, room_kind, wing, depth, position}].
## `type` is a container type, or "loose:<surface>" for an anchor.
static func _locations(info: Dictionary) -> Array:
	var out: Array = []
	for c in info.get("containers", []):
		var n: int = int(c.get("slots", -1))
		var node = c.get("node", null)
		if n < 0 and node != null and is_instance_valid(node):
			n = node.slot_count()
		var pos: Vector3 = c.get("position", Vector3.ZERO)
		if not c.has("position") and node != null and is_instance_valid(node) and node.is_inside_tree():
			pos = node.global_position
		var id: String = c.id
		# Drawers of one cabinet share a unit, so two stacks of a kind are never in the same cabinet.
		var parts := id.split("_")
		var unit := "%s_%s_%s" % [parts[0], parts[1], parts[2]] if parts.size() >= 4 else id
		for s in n:
			out.append({"key": "%s:%d" % [id, s], "unit": unit, "container_id": id, "slot": s, "anchor": -1,
					"type": String(c.type), "room_kind": String(c.get("room_kind", "")),
					"wing": String(c.get("wing", "")), "depth": int(c.get("depth", 1)), "position": pos})
	var anchors: Array = info.get("loose_anchors", [])
	for i in anchors.size():
		var a: Dictionary = anchors[i]
		out.append({"key": "anchor:%d" % i, "unit": "anchor:%d" % i, "container_id": "", "slot": 0, "anchor": i,
				"type": "loose:" + String(a.surface), "room_kind": String(a.get("room_kind", "")),
				"wing": String(a.get("wing", "")), "depth": int(a.get("depth", 1)), "position": a.position})
	return out


## Wing id -> depth, for every wing a needed item could go in.
static func _wings(locs: Array) -> Dictionary:
	var out := {}
	for loc in locs:
		if SAFE_ROOMS.has(loc.room_kind):
			continue
		out[String(loc.wing)] = maxi(1, int(loc.depth))
	return out


static func _weighted_wing(wings: Dictionary, order: Array, rng: RandomNumberGenerator) -> String:
	if order.is_empty():
		return ""
	var total := 0.0
	for w in order:
		total += 1.0 + 0.6 * float(wings[w])
	var roll := rng.randf() * total
	for w in order:
		roll -= 1.0 + 0.6 * float(wings[w])
		if roll <= 0.0:
			return w
	return order[order.size() - 1]


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = arr[i]
		arr[i] = arr[j]
		arr[j] = t


static func _legal(kind: String, loc: Dictionary, used: Dictionary) -> bool:
	if used.has(loc.key) or SAFE_ROOMS.has(loc.room_kind):
		return false
	var def := ItemsData.def(kind)
	var t: String = loc.type
	if t.begins_with("loose:"):
		return float(def.get("found", {}).get("loose", 0.0)) > 0.0 and (def.get("loose_surfaces", []) as Array).has(t.substr(6))
	return float(def.get("found", {}).get(t, 0.0)) > 0.0


static func _category(loc: Dictionary) -> String:
	return "loose" if String(loc.type).begins_with("loose:") else String(loc.type)


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Weighted pick: first a category from `found` (only categories with a free legal spot),
## then a spot inside it, preferring spots away from this kind's other stacks. `wing` ("" for
## any) narrows the search to one wing while that wing still has a legal spot.
static func _choose(kind: String, locs: Array, used: Dictionary, units: Dictionary, placed: Array[Vector3],
		rng: RandomNumberGenerator, table: Vector3, must_far: bool, distinct_units: bool, wing: String) -> Dictionary:
	var pools := {}
	for loc in locs:
		if not _legal(kind, loc, used):
			continue
		if wing != "" and String(loc.wing) != wing:
			continue
		if distinct_units and units.has(loc.unit):
			continue
		if must_far and _flat_dist(loc.position, table) < FAR_M:
			continue
		var cat := _category(loc)
		if not pools.has(cat):
			pools[cat] = []
		pools[cat].append(loc)
	if pools.is_empty():
		if must_far and wing != "":
			var anywhere := _choose(kind, locs, used, units, placed, rng, table, true, distinct_units, "")
			if not anywhere.is_empty() and _flat_dist(anywhere.position, table) >= FAR_M:
				return anywhere
		if must_far:
			return _choose(kind, locs, used, units, placed, rng, table, false, distinct_units, wing)
		if distinct_units:
			return _choose(kind, locs, used, units, placed, rng, table, false, false, wing)
		if wing != "":
			return _choose(kind, locs, used, units, placed, rng, table, false, true, "")
		return {}
	var found: Dictionary = ItemsData.def(kind).get("found", {})
	var cats := pools.keys()
	cats.sort()
	var total := 0.0
	for cat in cats:
		total += float(found.get(cat, 0.0))
	var pick: String = cats[0]
	var roll := rng.randf() * total
	for cat in cats:
		roll -= float(found.get(cat, 0.0))
		if roll <= 0.0:
			pick = cat
			break
	var pool: Array = pools[pick]
	# Prefer spots at least SPREAD_M from this kind's other stacks.
	var spread: Array = []
	for loc in pool:
		var ok := true
		for p in placed:
			if _flat_dist(loc.position, p) < SPREAD_M:
				ok = false
				break
		if ok:
			spread.append(loc)
	if not spread.is_empty():
		pool = spread
	return pool[rng.randi_range(0, pool.size() - 1)]


## The legal free spot farthest from every `avoid` point, with a little randomness among the best few.
static func _farthest(kind: String, locs: Array, used: Dictionary, units: Dictionary, avoid: Array,
		rng: RandomNumberGenerator) -> Dictionary:
	var scored: Array = []
	for loc in locs:
		if not _legal(kind, loc, used) or units.has(loc.unit):
			continue
		var d := 1.0e9
		for a in avoid:
			d = minf(d, _flat_dist(loc.position, a))
		if avoid.is_empty():
			d = 0.0
		scored.append([d, loc.key, loc])
	if scored.is_empty():
		for loc in locs:
			if _legal(kind, loc, used):
				scored.append([0.0, loc.key, loc])
	if scored.is_empty():
		return {}
	scored.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and String(a[1]) < String(b[1])))
	var top := mini(3, scored.size())
	return scored[rng.randi_range(0, top - 1)][2]


static func _take(loc: Dictionary, used: Dictionary, units: Dictionary, placed: Array[Vector3]) -> void:
	used[loc.key] = true
	units[loc.unit] = true
	placed.append(loc.position)


static func _entry(kind: String, count: int, loc: Dictionary) -> Dictionary:
	return {"kind": kind, "count": count, "container_id": loc.container_id, "slot": int(loc.slot),
			"anchor": int(loc.anchor)}


static func _batch(kind: String, rng: RandomNumberGenerator) -> int:
	var b: Array = ItemsData.def(kind).get("batch", [1, 1])
	return rng.randi_range(int(b[0]), int(b[1]))


## Stack sizes for a needed kind: tools come TOOL_COPIES times; consumables in 4 to 6 batches
## totalling at least twice what the procedure uses.
static func _needed_counts(kind: String, need: int, rng: RandomNumberGenerator) -> Array[int]:
	var out: Array[int] = []
	if not ItemsData.is_consumable(kind):
		for i in TOOL_COPIES:
			out.append(1)
		return out
	var stacks := rng.randi_range(CONSUMABLE_STACKS[0], CONSUMABLE_STACKS[1])
	var total := 0
	for i in stacks:
		var c := _batch(kind, rng)
		out.append(c)
		total += c
	while total < need * 2:
		var c := _batch(kind, rng)
		out.append(c)
		total += c
	return out
