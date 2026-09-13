extends SceneTree
## Offline check for the hospital generator and the 3D builder.
##
##   godot --headless --path . --script tools/mapcheck.gd [-- --seeds=300 --builds=8 --first=1]
##
## Generation, for every seed: MapGen.validate() (walls and legend, one OR / scrub room / break
## room / locker room / lobby, three OR tables in the OR, 3-4 wings with depths 1..n and the
## rooms each needs, every special room on the map, the break room landmarks, the neutral area
## spots and spawns, monster spawns only on wing hallways and never in the entrance building or
## the neutral area, doors, container placement rules, required furniture per room kind, and
## every open tile and room reachable from the neutral area). Re-generates a few seeds to prove
## determinism and prints one map.
##
## Builds, for a few seeds: every level_info key the game and the sweep 2 contract promise,
## monster spawns outside `entrance_rect` / `neutral_rect`, navigation coverage of the open
## tiles, a navigation path from the neutral area to the OR table and into every wing, and every
## container and loose anchor reachable to within interaction range.
## Exits non-zero when anything fails.

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")

const DETERMINISM_SEEDS := [1, 7, 42, 137, 200]
const ASCII_SEED := 7
## How close the navigation mesh must bring a player to a container or loose item.
const REACH := 1.9

var failures: PackedStringArray = []
var first_seed := 1
var seed_count := 300
var build_count := 8


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"seeds": seed_count = int(kv[1])
			"builds": build_count = int(kv[1])
			"first": first_seed = int(kv[1])
	var t0 := Time.get_ticks_msec()
	_check_generation()
	_check_determinism()
	print("")
	print("--- seed %d ---" % ASCII_SEED)
	var g7: Dictionary = MG.generate(ASCII_SEED)
	for row in g7.rows:
		print(row)
	print("")
	print("generation checks took %d ms" % (Time.get_ticks_msec() - t0))

	# The 3D builds need real frames: the navigation map only syncs on the main loop.
	var runner := Runner.new()
	runner.check = self
	for i in build_count:
		runner.seeds.append(first_seed + i * maxi(1, seed_count / maxi(1, build_count)))
	root.add_child(runner)


func _finish() -> void:
	print("")
	if failures.is_empty():
		print("OK - everything passed")
		quit(0)
	else:
		print("FAILED (%d):" % failures.size())
		for i in mini(80, failures.size()):
			print("  " + failures[i])
		quit(1)


func fail(msg: String) -> void:
	failures.append(msg)


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

func _check_generation() -> void:
	var kinds := {}
	var stats := {"tools": [], "monsters": [], "doors": [], "lights": [], "furniture": [], "containers": [],
			"rooms": [], "wings": [], "width": [], "height": [], "attempts": [], "ms": [], "dead lights %": [],
			"longest hallway run": []}
	var bad := 0
	var t0 := Time.get_ticks_msec()
	var missing_types := {}
	for seed in range(first_seed, first_seed + seed_count):
		var ts := Time.get_ticks_msec()
		var gen: Dictionary = MG.generate(seed)
		stats.ms.append(Time.get_ticks_msec() - ts)
		var problems: PackedStringArray = MG.validate(gen)
		if not problems.is_empty():
			bad += 1
			for p in problems:
				fail("seed %d: %s" % [seed, p])
		var counts := _count_chars(gen.rows)
		stats.tools.append(counts.get("T", 0))
		stats.monsters.append(counts.get("M", 0))
		stats.doors.append(counts.get("+", 0))
		stats.lights.append(gen.lights.size())
		stats.furniture.append(gen.furniture.size())
		stats.containers.append(gen.containers.size())
		stats.rooms.append(gen.rooms.size())
		stats.wings.append(gen.wings.size())
		stats.width.append(gen.width)
		stats.height.append(gen.height)
		stats.attempts.append(gen.attempt)
		stats["longest hallway run"].append(_longest_run(gen))
		var dead := 0
		for l in gen.lights:
			if int(l.mode) == 2:
				dead += 1
		stats["dead lights %"].append(int(100.0 * dead / maxf(1.0, gen.lights.size())))
		for r in gen.rooms:
			kinds[r.kind] = int(kinds.get(r.kind, 0)) + 1
		var types := {}
		for s in gen.containers:
			types[s.type] = true
		for t in ["med_fridge", "drawer_unit", "station_drawers", "trauma_bag", "pegboard"]:
			if not types.has(t):
				missing_types[t] = int(missing_types.get(t, 0)) + 1
		_check_depth_lighting(seed, gen)
	print("validated seeds %d..%d in %d ms - %d invalid" % [first_seed, first_seed + seed_count - 1, Time.get_ticks_msec() - t0, bad])
	var keys := stats.keys()
	keys.sort()
	for k in keys:
		print("  %-22s %s" % [k, _stats(stats[k])])
	var kind_keys := kinds.keys()
	kind_keys.sort()
	var line := PackedStringArray()
	for k in kind_keys:
		line.append("%s %.1f" % [k, float(kinds[k]) / seed_count])
	print("  rooms/map    %s" % ", ".join(line))
	for t in missing_types.keys():
		fail("%d map(s) have no %s" % [missing_types[t], t])


## Deeper wings must be darker: fewer working fixtures on average.
func _check_depth_lighting(seed: int, gen: Dictionary) -> void:
	var by_depth := {}
	for wd in gen.wings:
		var on := 0
		var total := 0
		for l in gen.lights:
			if int(l.zone) == int(wd.zone):
				total += 1
				if int(l.mode) != 2:
					on += 1
		by_depth[int(wd.depth)] = [on, total]
	var agg := {}
	for d in by_depth.keys():
		if not agg.has(d):
			agg[d] = [0, 0]
		agg[d][0] += by_depth[d][0]
		agg[d][1] += by_depth[d][1]
	var d_keys := agg.keys()
	d_keys.sort()
	if not _depth_totals.has("init"):
		_depth_totals["init"] = true
	for d in d_keys:
		if not _depth_totals.has(d):
			_depth_totals[d] = [0, 0]
		_depth_totals[d][0] += agg[d][0]
		_depth_totals[d][1] += agg[d][1]


var _depth_totals := {}


func _longest_run(gen: Dictionary) -> int:
	var rows: PackedStringArray = gen.rows
	var best := 0
	for y in rows.size():
		var run := 0
		for x in rows[y].length():
			var c := rows[y][x]
			if c != "#" and c != "," and c != "=":
				run += 1
				best = maxi(best, run)
			else:
				run = 0
	return best


func _check_determinism() -> void:
	for seed in DETERMINISM_SEEDS:
		var a: Dictionary = MG.generate(seed)
		var b: Dictionary = MG.generate(seed)
		for key in ["rows", "lights", "containers", "rooms", "furniture", "spots", "wings"]:
			if str(a[key]) != str(b[key]):
				fail("seed %d: %s differ between two generations" % [seed, key])
	var lit := PackedStringArray()
	var keys := _depth_totals.keys()
	keys.erase("init")
	keys.sort()
	var prev := 2.0
	for d in keys:
		var share: float = float(_depth_totals[d][0]) / maxf(1.0, _depth_totals[d][1])
		lit.append("depth %d %.0f%%" % [d, share * 100.0])
		if share > prev + 0.001:
			fail("wings at depth %d have more working fixtures (%.0f%%) than shallower ones" % [d, share * 100.0])
		prev = share
	print("determinism: re-generated %d seeds, identical output" % DETERMINISM_SEEDS.size())
	print("working fixtures by wing depth: %s" % ", ".join(lit))


func _count_chars(rows: PackedStringArray) -> Dictionary:
	var out := {}
	for row in rows:
		for i in row.length():
			var c := row[i]
			out[c] = out.get(c, 0) + 1
	return out


func _stats(values: Array) -> String:
	if values.is_empty():
		return "none"
	var lo: float = values[0]
	var hi: float = values[0]
	var total := 0.0
	for v in values:
		lo = minf(lo, v)
		hi = maxf(hi, v)
		total += v
	return "min %d  avg %.1f  max %d" % [lo, total / values.size(), hi]


# ---------------------------------------------------------------------------
# 3D build + navigation, one seed at a time so the regions never overlap.
# ---------------------------------------------------------------------------

class Runner extends Node:
	const MG := preload("res://scripts/mapgen.gd")
	const HB := preload("res://scripts/hospital_builder.gd")
	## Containers report the point on the wall behind them; their front is about half a metre
	## closer, so they get a little more.
	const REACH := 1.9
	const CONTAINER_REACH := 2.15

	var check: Object
	var seeds: Array = []
	var index := 0
	var level: Node3D = null
	var info := {}
	var gen := {}
	var waited := 0
	var base_iter := 0

	func _drop_level() -> void:
		if level == null:
			return
		get_tree().root.remove_child(level)
		level.free()
		level = null

	func _start_next() -> void:
		_drop_level()
		if index >= seeds.size():
			check.call("_finish")
			return
		var seed: int = seeds[index]
		info = {}
		gen = MG.generate(seed)
		var t0 := Time.get_ticks_msec()
		level = HB.build(gen, info)
		var build_ms := Time.get_ticks_msec() - t0
		var map_before := get_tree().root.world_3d.navigation_map
		base_iter = NavigationServer3D.map_get_iteration_id(map_before)
		get_tree().root.add_child(level)
		waited = 0
		print("seed %d: %dx%d built in %d ms - %d nodes, %d multimeshes, %d meshes, %d lights (%d omni visible), %d containers, %d anchors, %d nav polys" % [
			seed, gen.width, gen.height, build_ms, _node_count(level),
			level.find_children("*", "MultiMeshInstance3D", true, false).size(),
			level.find_children("*", "MeshInstance3D", true, false).size(),
			info.lights.size(), _visible_lights(level), info.containers.size(), info.loose_anchors.size(),
			(info.nav_region as NavigationRegion3D).navigation_mesh.get_polygon_count(),
		])
		_check_info(seed)

	func _visible_lights(n: Node) -> int:
		var c := 0
		for l in n.find_children("*", "OmniLight3D", true, false):
			if (l as OmniLight3D).visible:
				c += 1
		return c

	func _fail(msg: String) -> void:
		check.call("fail", msg)

	func _check_info(seed: int) -> void:
		var tag := "seed %d" % seed
		if info.player_spawns.size() != 4:
			_fail("%s: %d player spawns, expected 4" % [tag, info.player_spawns.size()])
		if info.tool_spawns.size() < MG.MIN_TOOLS:
			_fail("%s: only %d tool spawns" % [tag, info.tool_spawns.size()])
		if info.monster_spawns.size() < MG.MIN_MONSTERS:
			_fail("%s: only %d monster spawns" % [tag, info.monster_spawns.size()])
		for key in ["table", "clock", "pod"]:
			if not info.has(key) or info[key] == Vector3.ZERO:
				_fail("%s: '%s' was never placed" % [tag, key])
		# Every key of the sweep 2 hospital contract, with the right shape.
		var tables: Array = info.get("tables", [])
		var kinds := {"patient": 0, "player": 0}
		for t in tables:
			if not (t.position is Vector3) or not t.has("yaw") or not kinds.has(t.kind):
				_fail("%s: malformed table %s" % [tag, str(t)])
				continue
			kinds[t.kind] += 1
			if not (info.entrance_rect as Rect2).has_point(Vector2(t.position.x, t.position.z)):
				_fail("%s: table outside the entrance building" % tag)
		if kinds.patient != 2 or kinds.player != 1:
			_fail("%s: tables %s, expected 2 patient and 1 player" % [tag, str(kinds)])
		if not tables.is_empty() and info.table != tables[0].position:
			_fail("%s: table_pos() is not the first patient table" % tag)
		for key in ["or_screen", "phone", "entrance", "ambulance"]:
			var d: Dictionary = info.get(key, {})
			if not (d.get("position") is Vector3) or not d.has("yaw"):
				_fail("%s: level_info.%s is missing or malformed" % [tag, key])
		if not (info.get("or_screen", {}).get("size") is Vector2):
			_fail("%s: or_screen has no size" % tag)
		if not (info.get("entrance_rect") is Rect2):
			_fail("%s: entrance_rect is not a Rect2" % tag)
		var n: Dictionary = info.get("neutral", {})
		if (n.get("spawn_points", []) as Array).size() < 4:
			_fail("%s: neutral.spawn_points has fewer than 4 points" % tag)
		for key in ["shop", "sell_bin"]:
			if not (n.get(key, {}).get("position") is Vector3) or not n.get(key, {}).has("yaw"):
				_fail("%s: neutral.%s is missing or malformed" % [tag, key])
		if not (n.get("gold_pile", {}).get("position") is Vector3):
			_fail("%s: neutral.gold_pile is missing" % tag)
		var nr: Rect2 = info.get("neutral_rect", Rect2())
		for p in n.get("spawn_points", []):
			if not nr.has_point(Vector2(p.x, p.z)):
				_fail("%s: neutral spawn %s is outside the neutral area" % [tag, str(p)])
		var er: Rect2 = info.get("entrance_rect", Rect2())
		for key in ["shop", "sell_bin", "gold_pile"]:
			var p: Vector3 = n.get(key, {}).get("position", Vector3.ZERO)
			if not nr.has_point(Vector2(p.x, p.z)):
				_fail("%s: neutral.%s is outside the neutral area" % [tag, key])
		var amb: Vector3 = info.get("ambulance", {}).get("position", Vector3.ZERO)
		if not nr.grow(0.1).has_point(Vector2(amb.x, amb.z)):
			_fail("%s: the ambulance spot is not outside" % tag)
		var wings: Array = info.get("wings", [])
		if wings.size() < 3 or wings.size() > 4:
			_fail("%s: %d wings" % [tag, wings.size()])
		for wd in wings:
			if not (wd.rect is Rect2) or not wd.has("id") or not wd.has("depth"):
				_fail("%s: malformed wing %s" % [tag, str(wd)])
		for r in info.get("rooms", []):
			if not r.has("wing") or not r.has("depth"):
				_fail("%s: room %s has no wing or depth" % [tag, str(r.get("id"))])
		for m in info.monster_spawns:
			var q := Vector2(m.x, m.z)
			if er.has_point(q) or nr.grow(C.TILE).has_point(q):
				_fail("%s: monster spawn %s inside the entrance building or the neutral area" % [tag, str(m)])
			if HB.zone_of(info, m) in ["entrance", "neutral", ""]:
				_fail("%s: monster spawn %s is not in a wing" % [tag, str(m)])
		var ids := {}
		for c in info.get("containers", []):
			if ids.has(c.id):
				_fail("%s: duplicate container id %s" % [tag, c.id])
			ids[c.id] = true
		for key in ["shelf", "lectern"]:
			if not info.has(key):
				_fail("%s: no %s spot" % [tag, key])
		if info.has("shelf") and Vector2(info.shelf.position.x - info.table.x, info.shelf.position.z - info.table.z).length() > 4.6:
			_fail("%s: OR shelf spot is far from the table" % tag)
		if (info.nav_region as NavigationRegion3D).navigation_mesh.get_polygon_count() <= 0:
			_fail("%s: navigation mesh has no polygons" % tag)

	func _physics_process(_delta: float) -> void:
		if level == null:
			_start_next()
			return
		waited += 1
		var region: NavigationRegion3D = info.nav_region
		var map := region.get_navigation_map()
		var synced: bool = map.is_valid() and NavigationServer3D.map_get_iteration_id(map) >= base_iter + 2
		if not synced and waited < 240:
			return
		var seed: int = seeds[index]
		if not synced:
			_fail("seed %d: navigation map never synchronised" % seed)
		else:
			_check_nav(seed, map)
		index += 1
		_start_next()

	func _check_nav(seed: int, map: RID) -> void:
		var tag := "seed %d" % seed
		var start: Vector3 = info.neutral.spawn_points[0]
		# Coverage: open tiles whose centre has navigation mesh close by.
		var rows: PackedStringArray = gen.rows
		var blocked: PackedByteArray = gen.blocked
		var open := 0
		var covered := 0
		for ty in rows.size():
			for tx in rows[ty].length():
				if not MG.is_walkable_char(rows[ty][tx]) or blocked[ty * int(gen.width) + tx] != 0:
					continue
				open += 1
				var p := C.tile_to_world(tx, ty)
				if NavigationServer3D.map_get_closest_point(map, p).distance_to(p) < 0.8:
					covered += 1
		var coverage := float(covered) / maxf(1.0, open)
		if coverage < 0.93:
			_fail("%s: navigation covers only %.1f%% of the open tiles" % [tag, coverage * 100.0])
		# Paths from the neutral area: the OR table, the break room clock, every wing's farthest room.
		var goals := {"OR table": info.table, "time clock": info.clock}
		for wd in info.wings:
			var far := Vector3.ZERO
			var best := -1.0
			for r in info.rooms:
				if r.wing != wd.id:
					continue
				var c := Vector3((r.rect as Rect2).get_center().x, 0, (r.rect as Rect2).get_center().y)
				if c.distance_to(start) > best:
					best = c.distance_to(start)
					far = c
			goals["wing " + String(wd.id)] = far
		var longest := 0.0
		for name in goals.keys():
			var goal: Vector3 = goals[name]
			var target := NavigationServer3D.map_get_closest_point(map, goal)
			var path := NavigationServer3D.map_get_path(map, start, target, true)
			var length := _path_length(path)
			longest = maxf(longest, length)
			if path.size() < 2 or path[path.size() - 1].distance_to(target) > 0.6:
				_fail("%s: no navigation path from the neutral area to the %s" % [tag, name])
			elif Vector2(target.x - goal.x, target.z - goal.z).length() > 2.2:
				_fail("%s: the %s is %.1f m off the navigation mesh" % [tag, name, target.distance_to(goal)])
		# Every container and loose anchor must be reachable to within interaction range.
		var unreachable := 0
		var examples: Array = []
		var spots: Array = []
		for c in info.containers:
			spots.append([c.id, c.position, CONTAINER_REACH])
		for i in info.loose_anchors.size():
			spots.append(["anchor %d (%s, %s)" % [i, info.loose_anchors[i].surface, info.loose_anchors[i].room_kind], info.loose_anchors[i].position, REACH])
		for s in spots:
			var p: Vector3 = s[1]
			var q := NavigationServer3D.map_get_closest_point(map, Vector3(p.x, 0.0, p.z))
			var flat := Vector2(q.x - p.x, q.z - p.z).length()
			var ok := flat <= float(s[2])
			if ok:
				var path := NavigationServer3D.map_get_path(map, start, q, true)
				ok = path.size() >= 2 and path[path.size() - 1].distance_to(q) < 0.6
			if not ok:
				unreachable += 1
				if examples.size() < 4:
					examples.append("%s at (%.1f, %.1f), nav %.2f m away" % [s[0], p.x, p.z, flat])
		if unreachable > 0:
			_fail("%s: %d containers / anchors out of reach, e.g. %s" % [tag, unreachable, "; ".join(examples)])
		print("  nav: coverage %.1f%%, longest path from the neutral area %.0f m, %d spots checked, %d out of reach" % [
				coverage * 100.0, longest, spots.size(), unreachable])

	static func _path_length(path: PackedVector3Array) -> float:
		var total := 0.0
		for i in range(1, path.size()):
			total += path[i - 1].distance_to(path[i])
		return total

	static func _node_count(n: Node) -> int:
		var total := 1
		for c in n.get_children():
			total += _node_count(c)
		return total
