extends SceneTree
## Offline check for the item spawner and the container/anchor info it reads.
##
##   godot --headless --path . --script tools/spawncheck.gd [-- --seeds=300]
##
## For each seed: builds the level info headless, runs ItemSpawner.plan() for both ailments
## and asserts every rule in docs/CONTRACTS.md, then deletes the needed supply and checks
## shortfall_plan() puts it back legally and far away. Exits non-zero on any failure.

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")
const Spawner := preload("res://scripts/item_spawner.gd")
const ItemsData := preload("res://scripts/items.gd")
const ProceduresData := preload("res://scripts/procedures.gd")
const ModelsData := preload("res://scripts/item_models.gd")

var failures: PackedStringArray = []
var fail_count := 0
var stats := {}


func _initialize() -> void:
	var seeds := 300
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seeds="):
			seeds = int(a.split("=")[1])
	var t0 := Time.get_ticks_msec()
	for seed in range(1, seeds + 1):
		var gen: Dictionary = MG.generate(seed)
		var info := {}
		var level: Node3D = HB.build(gen, info)
		_count("containers", info.containers.size())
		_count("anchors", info.loose_anchors.size())
		_check_slots(seed, info)
		for ailment in ["gunshot", "amputation"]:
			var shift := 1 + seed % 4
			var p: Array = Spawner.plan(seed, shift, ailment, info)
			var again: Array = Spawner.plan(seed, shift, ailment, info)
			if str(p) != str(again):
				_fail("seed %d %s: plan is not deterministic" % [seed, ailment])
			_check_plan(seed, ailment, info, p, gen)
			_check_shortfall(seed, ailment, info, p)
		level.free()
	var ms := Time.get_ticks_msec() - t0
	print("")
	print("spawncheck: %d seeds x 2 ailments in %d ms" % [seeds, ms])
	var keys := stats.keys()
	keys.sort()
	for k in keys:
		var v: Array = stats[k]
		var lo: float = v.min()
		var hi: float = v.max()
		var sum := 0.0
		for x in v:
			sum += x
		print("  %-34s min %6.1f  avg %6.1f  max %6.1f" % [k, lo, sum / v.size(), hi])
	if fail_count == 0:
		print("OK - every rule held")
		quit(0)
	else:
		print("FAILED (%d):" % fail_count)
		for f in failures:
			print("  " + f)
		quit(1)


func _fail(msg: String) -> void:
	fail_count += 1
	if failures.size() < 60:
		failures.append(msg)


func _count(key: String, v: float) -> void:
	if not stats.has(key):
		stats[key] = []
	stats[key].append(v)


func _containers_by_id(info: Dictionary) -> Dictionary:
	var out := {}
	for c in info.containers:
		out[c.id] = c
	return out


func _loc_of(e: Dictionary, info: Dictionary, by_id: Dictionary) -> Dictionary:
	if e.container_id != "":
		var c: Dictionary = by_id.get(e.container_id, {})
		if c.is_empty():
			return {}
		return {"key": "%s:%d" % [e.container_id, e.slot], "unit": "%s_%s_%s" % Array(String(e.container_id).split("_")).slice(0, 3),
				"type": c.type, "room_kind": c.room_kind, "position": c.position, "slots": c.slots,
				"wing": String(c.get("wing", ""))}
	var anchors: Array = info.loose_anchors
	if e.anchor < 0 or e.anchor >= anchors.size():
		return {}
	var a: Dictionary = anchors[e.anchor]
	return {"key": "anchor:%d" % e.anchor, "unit": "anchor:%d" % e.anchor, "type": "loose:" + a.surface,
			"room_kind": a.room_kind, "position": a.position, "slots": 1, "wing": String(a.get("wing", ""))}


func _legal_for(kind: String, loc: Dictionary) -> bool:
	var def := ItemsData.def(kind)
	var t: String = loc.type
	if t.begins_with("loose:"):
		return float(def.found.get("loose", 0.0)) > 0.0 and (def.loose_surfaces as Array).has(t.substr(6))
	return float(def.found.get(t, 0.0)) > 0.0


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Slots must be distinct, inside the level and roomy enough for every kind that can go there.
func _check_slots(seed: int, info: Dictionary) -> void:
	for c in info.containers:
		var node: Node3D = c.node
		if node.slot_count() != c.slots or c.slots <= 0:
			_fail("seed %d: %s reports %d slots" % [seed, c.id, c.slots])
		if not node.is_in_group("container") or not node.is_in_group("interactable") or node.get_meta("interact_id", "") != c.id:
			_fail("seed %d: %s is missing groups or its interact_id" % [seed, c.id])
		var widest := 0.0
		for kind in ItemsData.SURGICAL:
			if float(ItemsData.def(kind).found.get(c.type, 0.0)) > 0.0:
				widest = maxf(widest, ModelsData.footprint(kind).x)
		for i in c.slots:
			var t: Transform3D = node.slot_transform(i)
			if _flat(t.origin, c.position) > 1.0:
				_fail("seed %d: %s slot %d is %.2f m from its container" % [seed, c.id, i, _flat(t.origin, c.position)])
			for j in range(i + 1, c.slots):
				var u: Transform3D = node.slot_transform(j)
				if t.origin.distance_to(u.origin) < widest - 0.001 and absf(t.origin.y - u.origin.y) < 0.05:
					_fail("seed %d: %s slots %d and %d are %.2f m apart, stacks need %.2f" % [seed, c.id, i, j, t.origin.distance_to(u.origin), widest])
		if info.lectern.is_empty() or info.get("storage", []).is_empty():
			_fail("seed %d: missing storage shelves or lectern" % seed)


func _check_plan(seed: int, ailment: String, info: Dictionary, p: Array, gen: Dictionary) -> void:
	var tag := "seed %d %s" % [seed, ailment]
	var by_id := _containers_by_id(info)
	var need := ProceduresData.requirements(ailment)
	var table: Vector3 = info.table
	var keys := {}
	var totals := {}
	var units := {}
	var loose := 0
	var far_needed := false
	var far_best := 0.0
	var needed_wings := {}
	for e in p:
		if not ItemsData.exists(e.kind):
			_fail("%s: unknown kind %s" % [tag, e.kind])
			continue
		var b: Array = ItemsData.def(e.kind).batch
		if e.count < int(b[0]) or e.count > int(b[1]):
			_fail("%s: %s stack of %d is outside batch %s" % [tag, e.kind, e.count, str(b)])
		if (e.container_id == "") == (e.anchor < 0):
			_fail("%s: entry %s must name exactly one of container_id / anchor" % [tag, str(e)])
		var loc := _loc_of(e, info, by_id)
		if loc.is_empty():
			_fail("%s: entry %s points nowhere" % [tag, str(e)])
			continue
		if e.container_id != "" and (e.slot < 0 or e.slot >= loc.slots):
			_fail("%s: %s slot %d out of range" % [tag, e.container_id, e.slot])
		if keys.has(loc.key):
			_fail("%s: two stacks share %s" % [tag, loc.key])
		keys[loc.key] = true
		if not _legal_for(e.kind, loc):
			_fail("%s: %s placed in %s, which Items.found does not allow" % [tag, e.kind, loc.type])
		if String(loc.type).begins_with("loose:"):
			loose += 1
		_count("loose share % " + e.kind, 100.0 if String(loc.type).begins_with("loose:") else 0.0)
		totals[e.kind] = int(totals.get(e.kind, 0)) + int(e.count)
		if not units.has(e.kind):
			units[e.kind] = {}
		units[e.kind][loc.unit] = true
		if need.has(e.kind):
			if Spawner.SAFE_ROOMS.has(loc.room_kind):
				_fail("%s: needed %s spawns in the %s" % [tag, e.kind, loc.room_kind])
			needed_wings[String(loc.wing)] = int(needed_wings.get(String(loc.wing), 0)) + 1
			var d := _flat(loc.position, table)
			far_best = maxf(far_best, d)
			if d >= Spawner.FAR_M:
				far_needed = true
	for kind in need.keys():
		var have: int = int(totals.get(kind, 0))
		if ItemsData.is_consumable(kind):
			if have < int(need[kind]) * 2:
				_fail("%s: %s totals %d, needs at least twice %d" % [tag, kind, have, need[kind]])
			if units.get(kind, {}).size() < Spawner.CONSUMABLE_STACKS[0]:
				_fail("%s: %s is in only %d places" % [tag, kind, units.get(kind, {}).size()])
			_count("surplus " + kind + " (" + ailment + ")", have - int(need[kind]))
		elif have < Spawner.TOOL_COPIES:
			_fail("%s: needed tool %s exists only %d times" % [tag, kind, have])
	for wd in info.get("wings", []):
		if int(needed_wings.get(String(wd.id), 0)) < 1:
			_fail("%s: wing %s holds nothing the case needs" % [tag, wd.id])
		_count("needed stacks in a depth-%d wing" % int(wd.depth), int(needed_wings.get(String(wd.id), 0)))
	for kind in ItemsData.SURGICAL:
		if not need.has(kind) and int(totals.get(kind, 0)) < 1:
			_fail("%s: no red herring %s" % [tag, kind])
	if not far_needed:
		_fail("%s: no needed item is %.0f m from the table (best %.1f)" % [tag, Spawner.FAR_M, far_best])
	_count("stacks per plan", p.size())
	_count("farthest needed item m", far_best)


## Break every needed item: remove all but one stack of each needed consumable and every
## needed tool, then ask for a top-up away from the table and a player.
func _check_shortfall(seed: int, ailment: String, info: Dictionary, p: Array) -> void:
	var tag := "seed %d %s shortfall" % [seed, ailment]
	var by_id := _containers_by_id(info)
	var need := ProceduresData.requirements(ailment)
	var kept: Array = []
	var dropped := {}
	for e in p:
		if need.has(e.kind) and not dropped.has(e.kind):
			dropped[e.kind] = true
			continue
		if need.has(e.kind) and not ItemsData.is_consumable(e.kind):
			continue
		kept.append(e)
	var have := {}
	var occupied := {}
	for e in kept:
		if need.has(e.kind):
			have[e.kind] = int(have.get(e.kind, 0)) + e.count
		var loc := _loc_of(e, info, by_id)
		occupied[loc.key] = true
	# Pretend a consumable shattered down to nothing.
	for kind in need.keys():
		if ItemsData.is_consumable(kind):
			have[kind] = mini(int(have.get(kind, 0)), int(need[kind]) - 1)
	var player: Vector3 = info.player_spawns[0] if info.player_spawns.size() > 0 else info.table
	var avoid: Array = [info.table, player]
	var sp: Array = Spawner.shortfall_plan(seed, need, have, info, occupied, avoid)
	var sp2: Array = Spawner.shortfall_plan(seed, need, have, info, occupied, avoid)
	if str(sp) != str(sp2):
		_fail("%s: not deterministic" % tag)
	var added := {}
	var used := occupied.duplicate()
	# Distances of every free legal spot, to judge "far".
	for e in sp:
		var loc := _loc_of(e, info, by_id)
		if loc.is_empty():
			_fail("%s: entry %s points nowhere" % [tag, str(e)])
			continue
		if used.has(loc.key):
			_fail("%s: %s placed in occupied %s" % [tag, e.kind, loc.key])
		var prior := used.duplicate()
		used[loc.key] = true
		if not _legal_for(e.kind, loc):
			_fail("%s: %s in illegal %s" % [tag, e.kind, loc.type])
		if Spawner.SAFE_ROOMS.has(loc.room_kind):
			_fail("%s: %s restored into the %s" % [tag, e.kind, loc.room_kind])
		var b: Array = ItemsData.def(e.kind).batch
		if e.count < int(b[0]) or e.count > int(b[1]):
			_fail("%s: stack of %d outside batch" % [tag, e.count])
		added[e.kind] = int(added.get(e.kind, 0)) + e.count
		var d := minf(_flat(loc.position, avoid[0]), _flat(loc.position, avoid[1]))
		# Compare against every legal free spot for this kind.
		var ds: Array = []
		for c in info.containers:
			for s in c.slots:
				var l := {"key": "%s:%d" % [c.id, s], "type": c.type, "position": c.position, "room_kind": c.room_kind}
				if not prior.has(l.key) and _legal_for(e.kind, l) and not Spawner.SAFE_ROOMS.has(c.room_kind):
					ds.append(minf(_flat(c.position, avoid[0]), _flat(c.position, avoid[1])))
		for i in info.loose_anchors.size():
			var a: Dictionary = info.loose_anchors[i]
			var l := {"type": "loose:" + a.surface}
			if not prior.has("anchor:%d" % i) and _legal_for(e.kind, l) and not Spawner.SAFE_ROOMS.has(a.room_kind):
				ds.append(minf(_flat(a.position, avoid[0]), _flat(a.position, avoid[1])))
		ds.sort()
		if ds.size() > 0:
			var pct := float(ds.bsearch(d, false)) / float(ds.size())
			_count("shortfall distance percentile", pct * 100.0)
			if pct < 0.75:
				_fail("%s: %s restored only %.0f m away (percentile %.0f)" % [tag, e.kind, d, pct * 100.0])
	for kind in need.keys():
		if int(have.get(kind, 0)) + int(added.get(kind, 0)) < int(need[kind]):
			_fail("%s: %s still short (%d + %d < %d)" % [tag, kind, have.get(kind, 0), added.get(kind, 0), need[kind]])
	for kind in added.keys():
		if not need.has(kind):
			_fail("%s: added unneeded %s" % [tag, kind])
