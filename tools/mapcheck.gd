extends SceneTree
## Offline check for the hospital generator and the 3D builder.
##
##   godot --headless --path . --script tools/mapcheck.gd
##
## Generates and validates seeds 1..200, re-checks determinism, builds the level for three
## seeds (node/vertex counts plus a NavigationServer path test) and prints the seed 7 ASCII.
## Exits non-zero when anything fails.

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")

const FIRST_SEED := 1
const LAST_SEED := 200
const DETERMINISM_SEEDS := [1, 7, 42, 137, 200]
const BUILD_SEEDS := [1, 7, 200]
const ASCII_SEED := 7

var failures: PackedStringArray = []


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	_check_generation()
	_check_determinism()

	print("")
	print("--- seed %d ---" % ASCII_SEED)
	var g7: Dictionary = MG.generate(ASCII_SEED)
	for row in g7.rows:
		print(row)
	print("lights %d  props %d  rooms %d" % [g7.lights.size(), g7.props.size(), g7.rooms.size()])
	print("")
	print("generation checks took %d ms" % (Time.get_ticks_msec() - t0))

	# The 3D builds need real frames: the navigation map only syncs on the main loop.
	var runner := Runner.new()
	runner.check = self
	runner.seeds = BUILD_SEEDS.duplicate()
	root.add_child(runner)


func _finish() -> void:
	print("")
	if failures.is_empty():
		print("OK - everything passed")
		quit(0)
	else:
		print("FAILED (%d):" % failures.size())
		for f in failures:
			print("  " + f)
		quit(1)


func fail(msg: String) -> void:
	failures.append(msg)


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

func _check_generation() -> void:
	var kinds := {}
	var tools := []
	var monsters := []
	var doors := []
	var lights := []
	var props := []
	var prop_kinds := {}
	var spreads := []
	var sites := []
	var container_types := {}
	var missing_types := {}
	var bad := 0
	var t0 := Time.get_ticks_msec()

	for seed in range(FIRST_SEED, LAST_SEED + 1):
		var gen: Dictionary = MG.generate(seed)
		var problems: PackedStringArray = MG.validate(gen)
		if not problems.is_empty():
			bad += 1
			for p in problems:
				fail("seed %d: %s" % [seed, p])
		var counts := _count_chars(gen.rows)
		tools.append(counts.get("T", 0))
		monsters.append(counts.get("M", 0))
		doors.append(counts.get("+", 0))
		lights.append(gen.lights.size())
		props.append(gen.props.size())
		var map_kinds := {}
		for r in gen.rooms:
			kinds[r.kind] = kinds.get(r.kind, 0) + 1
			map_kinds[r.kind] = map_kinds.get(r.kind, 0) + 1
		for k in MG.SPECIAL_MIN.keys():
			if int(map_kinds.get(k, 0)) < int(MG.SPECIAL_MIN[k]):
				fail("seed %d: only %d '%s' rooms (need %d)" % [seed, map_kinds.get(k, 0), k, MG.SPECIAL_MIN[k]])
		# Special rooms should not huddle together.
		var specials: Array = []
		for r in gen.rooms:
			if MG.SPECIAL_KINDS.has(r.kind):
				specials.append(Vector2(r.x + r.w * 0.5, r.y + r.h * 0.5))
		var spread := 0.0
		for a in specials:
			for b in specials:
				spread = maxf(spread, a.distance_to(b))
		spreads.append(int(spread))
		var map_types := {}
		for s in gen.containers:
			map_types[s.type] = map_types.get(s.type, 0) + 1
			container_types[s.type] = container_types.get(s.type, 0) + 1
		sites.append(gen.containers.size())
		for t in ["med_fridge", "drawer_unit", "station_drawers", "trauma_bag", "pegboard"]:
			if not map_types.has(t):
				missing_types[t] = missing_types.get(t, 0) + 1
		for p in gen.props:
			prop_kinds[p.kind] = prop_kinds.get(p.kind, 0) + 1

	var n := LAST_SEED - FIRST_SEED + 1
	print("validated seeds %d..%d in %d ms - %d invalid" % [FIRST_SEED, LAST_SEED, Time.get_ticks_msec() - t0, bad])
	print("  tools/map    %s" % _stats(tools))
	print("  monsters/map %s" % _stats(monsters))
	print("  doors/map    %s" % _stats(doors))
	print("  lights/map   %s" % _stats(lights))
	print("  props/map    %s" % _stats(props))
	var kind_keys := kinds.keys()
	kind_keys.sort()
	var kind_line := PackedStringArray()
	for k in kind_keys:
		kind_line.append("%s %.1f" % [k, float(kinds[k]) / float(n)])
	print("  rooms/map    %s (avg)" % ", ".join(kind_line))
	var pk_keys := prop_kinds.keys()
	pk_keys.sort()
	var pk_line := PackedStringArray()
	for k in pk_keys:
		pk_line.append("%s %d" % [k, prop_kinds[k]])
	print("  prop kinds   %s (total)" % ", ".join(pk_line))
	print("  container sites/map %s" % _stats(sites))
	var ct_keys := container_types.keys()
	ct_keys.sort()
	var ct_line := PackedStringArray()
	for k in ct_keys:
		ct_line.append("%s %.1f" % [k, float(container_types[k]) / float(n)])
	print("  sites by type %s (avg)" % ", ".join(ct_line))
	print("  special-room spread (tiles between farthest two) %s" % _stats(spreads))
	if not missing_types.is_empty():
		print("  maps missing a container type: %s" % str(missing_types))
		for t in ["med_fridge", "drawer_unit", "station_drawers", "trauma_bag"]:
			if missing_types.has(t):
				fail("%d map(s) have no %s" % [missing_types[t], t])


func _check_determinism() -> void:
	for seed in DETERMINISM_SEEDS:
		var a: Dictionary = MG.generate(seed)
		var b: Dictionary = MG.generate(seed)
		if a.rows != b.rows:
			fail("seed %d: rows differ between two generations" % seed)
		if a.lights != b.lights:
			fail("seed %d: lights differ between two generations" % seed)
		if str(a.props) != str(b.props):
			fail("seed %d: props differ between two generations" % seed)
		if str(a.containers) != str(b.containers):
			fail("seed %d: container sites differ between two generations" % seed)
		if str(a.rooms) != str(b.rooms):
			fail("seed %d: rooms differ between two generations" % seed)
	print("determinism: re-generated %d seeds, identical output" % DETERMINISM_SEEDS.size())


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
	var lo: int = values[0]
	var hi: int = values[0]
	var total := 0
	for v in values:
		lo = mini(lo, v)
		hi = maxi(hi, v)
		total += v
	return "min %d  avg %.1f  max %d" % [lo, float(total) / float(values.size()), hi]


# ---------------------------------------------------------------------------
# 3D build + navigation, one seed at a time so the regions never overlap.
# ---------------------------------------------------------------------------

class Runner extends Node:
	const MG := preload("res://scripts/mapgen.gd")
	const HB := preload("res://scripts/hospital_builder.gd")

	var check: Object
	var seeds: Array = []
	var index := 0
	var level: Node3D = null
	var info := {}
	var waited := 0
	var base_iter := 0

	func _ready() -> void:
		print("")
		# The first level is built on the first physics frame: a node added to the root
		# before the loop starts is not yet "inside world", and its region never registers.

	func _drop_level() -> void:
		if level == null:
			return
		# Free immediately (not queue_free) so the old navigation region is gone before the
		# next one is registered on the same map.
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
		var t0 := Time.get_ticks_msec()
		level = HB.build(MG.generate(seed), info)
		var build_ms := Time.get_ticks_msec() - t0
		var map_before := get_tree().root.world_3d.navigation_map
		base_iter = NavigationServer3D.map_get_iteration_id(map_before)
		get_tree().root.add_child(level)
		waited = 0
		print("seed %d: built in %d ms - %d nodes, %d mesh vertices, %d lights, %d signs, %d nav polys" % [
			seed, build_ms, _node_count(level), _vertex_count(level),
			info.lights.size(), level.get_node("Signs").get_child_count(),
			(info.nav_region as NavigationRegion3D).navigation_mesh.get_polygon_count(),
		])
		_check_info(seed)

	func _check_info(seed: int) -> void:
		if info.player_spawns.size() != 4:
			check.call("fail", "seed %d: %d player spawns, expected 4" % [seed, info.player_spawns.size()])
		if info.tool_spawns.size() < MG.MIN_TOOLS:
			check.call("fail", "seed %d: only %d tool spawns" % [seed, info.tool_spawns.size()])
		if info.monster_spawns.size() < MG.MIN_MONSTERS:
			check.call("fail", "seed %d: only %d monster spawns" % [seed, info.monster_spawns.size()])
		for key in ["table", "clock", "pod"]:
			if info[key] == Vector3.ZERO:
				check.call("fail", "seed %d: '%s' was never placed" % [seed, key])
		var surf := {}
		for a in info.get("loose_anchors", []):
			surf[a.surface] = surf.get(a.surface, 0) + 1
		var ids := {}
		for c in info.get("containers", []):
			if ids.has(c.id):
				check.call("fail", "seed %d: duplicate container id %s" % [seed, c.id])
			ids[c.id] = true
		print("  containers %d, loose anchors %d %s, shelf %s, lectern %s" % [
			info.get("containers", []).size(), info.get("loose_anchors", []).size(), str(surf),
			str(info.get("shelf", {}).get("position", "MISSING")), str(info.get("lectern", {}).get("position", "MISSING"))])
		for key in ["shelf", "lectern"]:
			if not info.has(key):
				check.call("fail", "seed %d: no %s spot" % [seed, key])
		if info.has("shelf") and Vector2(info.shelf.position.x - info.table.x, info.shelf.position.z - info.table.z).length() > 4.6:
			check.call("fail", "seed %d: OR shelf spot is far from the table" % seed)
		if (info.nav_region as NavigationRegion3D).navigation_mesh.get_polygon_count() <= 0:
			check.call("fail", "seed %d: navigation mesh has no polygons" % seed)

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
			check.call("fail", "seed %d: navigation map never synchronised" % seed)
		else:
			var from: Vector3 = info.player_spawns[0]
			var to: Vector3 = _farthest(from, info.monster_spawns + info.tool_spawns)
			var path := NavigationServer3D.map_get_path(map, from, to, true)
			print("  nav path %s -> %s: %d points over %.1f m (%d physics frames to sync)" % [
				_v(from), _v(to), path.size(), from.distance_to(to), waited])
			if path.size() < 2:
				check.call("fail", "seed %d: no navigation path between two far-apart walkable tiles" % seed)
			elif path[path.size() - 1].distance_to(to) > 1.5:
				check.call("fail", "seed %d: navigation path ends %.1f m short of the target" % [
					seed, path[path.size() - 1].distance_to(to)])
		index += 1
		_start_next()

	static func _v(p: Vector3) -> String:
		return "(%.1f, %.1f)" % [p.x, p.z]

	static func _farthest(from: Vector3, candidates: Array) -> Vector3:
		var best := from
		var best_d := -1.0
		for c in candidates:
			var d: float = from.distance_to(c)
			if d > best_d:
				best_d = d
				best = c
		return best

	static func _node_count(n: Node) -> int:
		var total := 1
		for c in n.get_children():
			total += _node_count(c)
		return total

	static func _vertex_count(n: Node) -> int:
		var total := 0
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var m: Mesh = (n as MeshInstance3D).mesh
			for s in m.get_surface_count():
				total += m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size()
		for c in n.get_children():
			total += _vertex_count(c)
		return total
