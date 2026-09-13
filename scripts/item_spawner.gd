class_name ItemSpawner
extends RefCounted
## Decides where every item stack starts a shift (see docs/CONTRACTS.md, "Item spawning").
##
## Rules `plan()` guarantees, all checked by tools/spawncheck.gd:
##   - every consumable the ailment needs totals more than Procedures.requirements(), in at
##     least two stacks at two different places (different container units / anchors);
##   - every needed tool exists at least once;
##   - nothing needed spawns in the OR, its anterooms or the clock-in room;
##   - at least one needed item is far (FAR_M) from the table;
##   - items the ailment does not need spawn too, as red herrings;
##   - stack counts are inside Items batch ranges; one stack per container slot and per anchor;
##   - choice between container types and loose surfaces follows Items.ITEMS[kind].found;
##   - the same seed, shift, ailment and level always give the same plan.
##
## Entries: {kind, count, container_id ("" when loose), slot, anchor (-1 when in a container)}.

const ItemsData := preload("res://scripts/items.gd")
const ProceduresData := preload("res://scripts/procedures.gd")

const SAFE_ROOMS := ["or", "anteroom", "clockin"]
## Horizontal metres from the table that count as "far".
const FAR_M := 24.0
## Stacks of one kind try to stay at least this far apart.
const SPREAD_M := 12.0


static func plan(seed_value: int, shift: int, ailment_id: String, info: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|items|%d|%s" % [seed_value, shift, ailment_id])
	var locs := _locations(info)
	var table: Vector3 = info.get("table", Vector3.ZERO)
	var need := ProceduresData.requirements(ailment_id)
	var used := {}
	var out: Array = []

	# Needed kinds first, in a stable order, so they get the pick of the locations.
	var needed: Array = []
	var herrings: Array = []
	for kind in ItemsData.SURGICAL:
		if need.has(kind):
			needed.append(kind)
		else:
			herrings.append(kind)
	var far_kind: String = needed[rng.randi_range(0, needed.size() - 1)] if not needed.is_empty() else ""

	for kind in needed:
		var counts := _needed_counts(kind, int(need[kind]), rng)
		var placed: Array[Vector3] = []
		var units := {}
		for i in counts.size():
			var must_far: bool = kind == far_kind and i == 0
			var loc := _choose(kind, locs, used, units, placed, rng, table, must_far, true)
			if loc.is_empty():
				continue
			_take(loc, used, units, placed)
			out.append(_entry(kind, counts[i], loc))

	for kind in herrings:
		var copies := 1
		if ItemsData.is_consumable(kind):
			copies = rng.randi_range(1, 2)
		var placed: Array[Vector3] = []
		var units := {}
		for i in copies:
			var loc := _choose(kind, locs, used, units, placed, rng, table, false, true)
			if loc.is_empty():
				continue
			_take(loc, used, units, placed)
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

## Every place a stack can go: [{key, unit, container_id, slot, anchor, type, room_kind, position}].
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
					"type": String(c.type), "room_kind": String(c.get("room_kind", "")), "position": pos})
	var anchors: Array = info.get("loose_anchors", [])
	for i in anchors.size():
		var a: Dictionary = anchors[i]
		out.append({"key": "anchor:%d" % i, "unit": "anchor:%d" % i, "container_id": "", "slot": 0, "anchor": i,
				"type": "loose:" + String(a.surface), "room_kind": String(a.get("room_kind", "")), "position": a.position})
	return out


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
## then a spot inside it, preferring spots away from this kind's other stacks.
static func _choose(kind: String, locs: Array, used: Dictionary, units: Dictionary, placed: Array[Vector3],
		rng: RandomNumberGenerator, table: Vector3, must_far: bool, distinct_units: bool) -> Dictionary:
	var pools := {}
	for loc in locs:
		if not _legal(kind, loc, used):
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
		if must_far:
			return _choose(kind, locs, used, units, placed, rng, table, false, distinct_units)
		if distinct_units:
			return _choose(kind, locs, used, units, placed, rng, table, false, false)
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


## Stack sizes for a needed kind: tools are one; consumables are two or three batches whose
## total is always more than the procedure uses.
static func _needed_counts(kind: String, need: int, rng: RandomNumberGenerator) -> Array[int]:
	var out: Array[int] = []
	if not ItemsData.is_consumable(kind):
		out.append(1)
		return out
	var stacks := rng.randi_range(2, 3)
	var total := 0
	for i in stacks:
		var c := _batch(kind, rng)
		out.append(c)
		total += c
	while total <= need:
		var c := _batch(kind, rng)
		out.append(c)
		total += c
	return out
