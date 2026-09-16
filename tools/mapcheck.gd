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
## every open tile and room reachable from the neutral area). Doors (DoorPlan.check, through
## validate): a door in every doorway, every leaf's whole swing clear of walls, furniture,
## containers and every other door, and every room reachable through doors that open wide enough.
## Wings per shift: the same run seed with another shift's wing seed keeps the entrance building
## and the neutral area identical tile for tile and changes the wings. Re-generates a few seeds to
## prove determinism and prints one map.
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

var failures: PackedStringArray = []
var first_seed := 1
var seed_count := 300
var build_count := 8
var build_pocket := ""   # POCKETS


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"seeds": seed_count = int(kv[1])
			"builds": build_count = int(kv[1])
			"first": first_seed = int(kv[1])
			"build_pocket": build_pocket = kv[1]   # POCKETS: "" alternate, none, factory, restaurant
	var t0 := Time.get_ticks_msec()
	_check_generation()
	_check_determinism()
	_check_pockets()   # POCKETS
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


# ---------------------------------------------------------------------------
# POCKETS: pocket spaces over many seeds (docs/POCKET_SPACES.md)
# ---------------------------------------------------------------------------

const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")
const PS := preload("res://scripts/level/pockets/pocket_spaces.gd")
const S := preload("res://scripts/level/level_state.gd")

## Every seed of the run again with a pocket forced (Factory on odd seeds, Restaurant on even), plus
## the natural roll: the plan, the stubs carved into the hospital, the pocket's own grid, and the
## seams lining up tile for tile both ways.
func _check_pockets() -> void:
	var t0 := Time.get_ticks_msec()
	var natural := {}
	var entrances := {}
	var placed := 0
	var tried := 0
	for seed in range(first_seed, first_seed + seed_count):
		Plan.force_kind = ""
		var g0: Dictionary = MG.generate(seed)
		var k0 := String(Plan.of(g0).get("kind", "none"))
		natural[k0] = int(natural.get(k0, 0)) + 1
		for kind in ["factory", "restaurant"]:
			if (seed % 2 == 1) != (kind == "factory") and seed > first_seed + 40:
				continue   # both kinds on the first 40 seeds, then alternate
			Plan.force_kind = kind
			tried += 1
			# Wings differ every shift: later shifts' wing seeds too (the plan is rolled with the wings).
			var gn := 1 + (seed + (1 if kind == "factory" else 0)) % 4
			var gen: Dictionary = MG.generate(seed, MG.wing_seed_for(seed, gn))
			var plan := Plan.of(gen)
			if plan.is_empty():
				fail("seed %d shift %d: a forced %s placed no pocket (%s)" % [seed, gn, kind, Plan.last_failure])
				continue
			placed += 1
			entrances[plan.stubs.size()] = int(entrances.get(plan.stubs.size(), 0)) + 1
			for p in MG.validate(gen):
				fail("seed %d shift %d (%s forced): %s" % [seed, gn, kind, p])
			_check_pocket_plan(seed, kind, gen, plan)
	Plan.force_kind = ""
	print("pockets: natural roll %s over %d seeds; forced %d/%d placed; entrances %s (%d ms)" % [str(natural), seed_count, placed, tried, str(entrances), Time.get_ticks_msec() - t0])


func _check_pocket_plan(seed: int, kind: String, gen: Dictionary, plan: Dictionary) -> void:
	var tag := "seed %d %s" % [seed, kind]
	var rows: PackedStringArray = gen.rows
	var w: int = gen.width
	var h: int = gen.height
	var zone: PackedByteArray = gen.zone
	var blocked: PackedByteArray = gen.blocked
	var er: Rect2i = gen.entrance_rect
	var nr: Rect2i = gen.neutral_rect
	var stubs: Array = plan.stubs
	if stubs.size() < Plan.MIN_ENTRANCES or stubs.size() > Plan.MAX_ENTRANCES:
		fail("%s: %d entrances" % [tag, stubs.size()])
	var wings := {}
	var wing_zone := {}
	for wd in gen.wings:
		wing_zone[String(wd.id)] = int(wd.zone)
	var at := func(p: Vector2i) -> String:
		return "#" if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h else rows[p.y][p.x]
	# Reachability over the hospital's tiles (the stub halves past a seam are blocked, like the nav).
	var st := S.new(w, h)
	for y in h:
		for x in w:
			st.cells[y * w + x] = rows[y].unicode_at(x)
	st.blocked = blocked
	var start: Vector2 = gen.spots.neutral_spawns[0]
	var reach := st.flood([Vector2i(int(start.x), int(start.y))])
	for s in stubs:
		wings[s.wing] = true
		var o: Vector2i = s.o
		var eu: Vector2i = s.eu
		var ev: Vector2i = s.ev
		if not Stub.size_ok(s.w, s.d):
			fail("%s stub %d: %dx%d is too small to hide its seam" % [tag, s.id, s.w, s.d])
		var open := {}
		for t in Stub.open_tiles(s.w, s.d, true):
			open[t] = true
		for v in range(-1, s.d + 1):
			for u in range(-1, s.w + 1):
				var t := Vector2i(u, v)
				var p: Vector2i = o + eu * u + ev * v
				var c: String = at.call(p)
				if open.has(t):
					if c != ".":
						fail("%s stub %d: tile %s should be floor, is '%s'" % [tag, s.id, str(t), c])
					elif zone[p.y * w + p.x] != Plan.ZONE_STUB:
						fail("%s stub %d: tile %s is not in the stub zone" % [tag, s.id, str(t)])
					if Stub.phantom_hospital(s.w, t) != (blocked[p.y * w + p.x] == 1):
						fail("%s stub %d: tile %s blocked=%d but past the seam=%s" % [tag, s.id, str(t), blocked[p.y * w + p.x], str(Stub.phantom_hospital(s.w, t))])
					if er.has_point(p) or nr.has_point(p):
						fail("%s stub %d: tile %s inside the entrance building or neutral area" % [tag, s.id, str(t)])
				elif v >= 0 and v < s.d and u >= 0 and u < s.w and c != "#":
					fail("%s stub %d: the middle block tile %s is '%s'" % [tag, s.id, str(t), c])
				elif (v == -1 or v == s.d or u == -1 or u == s.w) and not open.has(t) and c != "#":
					fail("%s stub %d: the wall around it is open at %s ('%s')" % [tag, s.id, str(t), c])
		# Its mouth opens onto a hallway of its own wing, reachable from outside.
		for u in Stub.CORRIDOR:
			var hall: Vector2i = o + eu * u - ev * 2
			if int(zone[hall.y * w + hall.x]) != int(wing_zone.get(String(s.wing), -1)) or at.call(hall) == "#":
				fail("%s stub %d: its mouth does not open onto a %s hallway" % [tag, s.id, s.wing])
			var m: Vector2i = o + eu * u + ev * 0
			if reach[m.y * w + m.x] == 0:
				fail("%s stub %d: leg 1 is not reachable from the neutral area" % [tag, s.id])
	if wings.size() < 2:
		fail("%s: every entrance leads to the same wing" % tag)
	# The pocket's own grid: every stub has a port, the copies line up tile for tile with the hospital's
	# stubs through the seam transform (both ways), and everything open is reachable from each opening.
	var layout_script: GDScript = PS.Factory if kind == "factory" else PS.Restaurant
	var lay: Dictionary = layout_script.layout(stubs, int(plan.seed))
	var g: Dictionary = lay.grid
	var origin: Vector2i = PS.ORIGINS[kind]
	for i in stubs.size():
		var s: Dictionary = stubs[i]
		var port: Dictionary = lay.ports[i]
		if port.is_empty():
			fail("%s stub %d: no place for it on the pocket's walls" % [tag, s.id])
			continue
		var seam := PS._make_seam(s, port, origin)
		var t: Transform3D = seam.t
		var ti: Transform3D = seam.t_inv
		for v in range(-1, s.d + 1):
			for u in range(-1, s.w + 1):
				var hp: Vector2i = (s.o as Vector2i) + (s.eu as Vector2i) * u + (s.ev as Vector2i) * v
				var pp: Vector2i = (port.o as Vector2i) + (port.eu as Vector2i) * u + (port.ev as Vector2i) * v
				var hc := C.tile_to_world(hp.x, hp.y)
				var pc := C.tile_to_world(origin.x + pp.x, origin.y + pp.y)
				if (t * hc).distance_to(pc) > 0.001 or (ti * pc).distance_to(hc) > 0.001:
					fail("%s stub %d: tile %d,%d does not map onto its copy" % [tag, s.id, u, v])
					break
				if v < 0 or v >= s.d or u < 0 or u >= s.w:
					# The ring: walls in both copies except each copy's own mouth / opening.
					var h_open: bool = at.call(hp) != "#"
					var p_open := Common_is_open(g, pp)
					var mouth: bool = v == -1 and u >= 0 and u < Stub.CORRIDOR
					var opening: bool = v == -1 and u >= int(s.w) - Stub.CORRIDOR and u < int(s.w)
					if h_open != mouth or p_open != opening:
						fail("%s stub %d: ring tile %d,%d hospital open=%s pocket open=%s" % [tag, s.id, u, v, str(h_open), str(p_open)])
				else:
					var h_open: bool = at.call(hp) != "#"
					var p_open := Common_is_open(g, pp)
					if h_open != p_open:
						fail("%s stub %d: tile %d,%d open in one copy only (hospital %s, pocket %s)" % [tag, s.id, u, v, str(h_open), str(p_open)])
	# Flood the pocket from each opening over walkable tiles (the nav mask stands in for props).
	var gw: int = g.w
	var gh: int = g.h
	for i in stubs.size():
		var port: Dictionary = lay.ports[i]
		if port.is_empty():
			continue
		var s: Dictionary = stubs[i]
		var from: Vector2i = (port.o as Vector2i) + (port.eu as Vector2i) * (s.w - 1) + (port.ev as Vector2i) * 0
		var seen := PackedByteArray()
		seen.resize(gw * gh)
		var q: Array[Vector2i] = [from]
		seen[from.y * gw + from.x] = 1
		var qi := 0
		while qi < q.size():
			var c: Vector2i = q[qi]
			qi += 1
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if n.x < 0 or n.y < 0 or n.x >= gw or n.y >= gh or seen[n.y * gw + n.x] == 1:
					continue
				if not Common_is_open(g, n) or g.nav[n.y * gw + n.x] == 1:
					continue
				seen[n.y * gw + n.x] = 1
				q.append(n)
		var missed := 0
		var example := Vector2i(-1, -1)
		for y in gh:
			for x in gw:
				if Common_is_open(g, Vector2i(x, y)) and g.nav[y * gw + x] == 0 and seen[y * gw + x] == 0:
					missed += 1
					if example.x < 0:
						example = Vector2i(x, y)
		if missed > 0:
			fail("%s: %d walkable pocket tiles unreachable from entrance %d (e.g. %s)" % [tag, missed, i, str(example)])
	# The pocket's doors (scripts/doors): each in a doorway one tile deep between two walkable tiles,
	# the whole outward swing (the tile in front of each leaf) clear of props, containers and stubs.
	var ct_tiles := {}
	for c in lay.containers:
		ct_tiles[c.tile] = true
	for d in layout_script.door_entries(lay, origin):
		var n: Vector2i = d.n
		var side := Vector2i(n.y, n.x).abs()
		for wt: Vector2i in d.tiles:
			var t: Vector2i = wt - origin
			var front: Vector2i = t + n
			var back: Vector2i = t - n
			if not Common_is_open(g, t) or Common_is_open(g, t + side) and Common_is_open(g, t - side) and d.tiles.size() == 1:
				fail("%s: door %s is not in a one-tile doorway" % [tag, d.id])
			for p: Vector2i in [front, back]:
				if not Common_is_open(g, p) or g.nav[p.y * gw + p.x] == 1 or g.stub[p.y * gw + p.x] == 1:
					fail("%s: door %s opens onto a blocked tile %s" % [tag, d.id, str(p)])
			if ct_tiles.has(front) or ct_tiles.has(back):
				fail("%s: door %s swings into a container at %s" % [tag, d.id, str(front)])


static func Common_is_open(g: Dictionary, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < int(g.w) and p.y < int(g.h) and (g.cells as PackedByteArray)[p.y * int(g.w) + p.x] != 35


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
	# DOORS: later shifts of a run rebuild the wings only.
	for seed in DETERMINISM_SEEDS:
		var s1: Dictionary = MG.generate(seed)
		for shift in [2, 3]:
			var sn: Dictionary = MG.generate(seed, MG.wing_seed_for(seed, shift))
			var problems := MG.validate(sn)
			for p in problems:
				fail("seed %d shift %d: %s" % [seed, shift, p])
			var er: Rect2i = s1.entrance_rect
			var nr: Rect2i = s1.neutral_rect
			var same := true
			var wings_differ := 0
			for y in (s1.rows as PackedStringArray).size():
				var a: String = s1.rows[y]
				var b: String = sn.rows[y]
				for x in a.length():
					var t := Vector2i(x, y)
					if er.has_point(t) or nr.grow(1).has_point(t):
						if a[x] != b[x]:
							same = false
					elif a[x] != b[x]:
						wings_differ += 1
			if not same:
				fail("seed %d shift %d: the entrance building or neutral area changed" % [seed, shift])
			# POCKETS: the pocket plan is rolled with the wings, so it may change (spots.pocket).
			var sp1: Dictionary = (s1.spots as Dictionary).duplicate()
			var spn: Dictionary = (sn.spots as Dictionary).duplicate()
			sp1.erase("pocket")
			spn.erase("pocket")
			if str(sp1) != str(spn) or er != (sn.entrance_rect as Rect2i):
				fail("seed %d shift %d: a landmark moved" % [seed, shift])
			if wings_differ < 100:
				fail("seed %d shift %d: the wings barely changed (%d tiles)" % [seed, shift, wings_differ])
	print("wings per shift: %d seeds x 2 later shifts, entrance identical, wings regenerated" % DETERMINISM_SEEDS.size())
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

	const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
	const PS := preload("res://scripts/level/pockets/pocket_spaces.gd")
	const Stub := preload("res://scripts/level/pockets/stub.gd")
	var pocket_seams: Array = []
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
		# POCKETS: every build seed gets a pocket, the Factory and the Restaurant in turn.
		Plan.force_kind = ("factory" if index % 2 == 0 else "restaurant") if check.build_pocket == "" else check.build_pocket
		gen = MG.generate(seed)
		Plan.force_kind = ""
		var t0 := Time.get_ticks_msec()
		level = HB.build(gen, info)
		var build_ms := Time.get_ticks_msec() - t0
		var plan := Plan.of(gen)
		pocket_seams = []
		if not plan.is_empty():
			var tp := Time.get_ticks_msec()
			PS.build_into(String(plan.kind), plan.stubs, int(plan.seed), int(gen.seed), gen.lights, info, level, pocket_seams)
			print("seed %d: %s with %d entrances built in %d ms" % [seed, plan.kind, plan.stubs.size(), Time.get_ticks_msec() - tp])
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
		for key in ["table", "clock"]:
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
		if kinds.patient != 3 or kinds.player != 0:
			_fail("%s: tables %s, expected 3 patient tables" % [tag, str(kinds)])
		if (info.get("or_screens", []) as Array).size() != kinds.patient:
			_fail("%s: %d OR monitors for %d tables" % [tag, (info.get("or_screens", []) as Array).size(), kinds.patient])
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
		if not (n.get("shop", {}).get("position") is Vector3) or not n.get("shop", {}).has("yaw"):
			_fail("%s: neutral.shop is missing or malformed" % tag)
		var nr: Rect2 = info.get("neutral_rect", Rect2())
		var er: Rect2 = info.get("entrance_rect", Rect2())
		# SWEEP 4A HOOK (fog lot, chunk 2): player spawns and the shop moved indoors.
		for p in n.get("spawn_points", []):
			if not er.has_point(Vector2(p.x, p.z)):
				_fail("%s: player spawn %s is outside the entrance building" % [tag, str(p)])
		var shop_p: Vector3 = n.get("shop", {}).get("position", Vector3.ZERO)
		if not er.has_point(Vector2(shop_p.x, shop_p.z)):
			_fail("%s: neutral.shop is outside the entrance building" % tag)
		# SWEEP 4A HOOK (pharmacy, chunk 3): the pharmacy and the furnace (crematorium) both sit
		# inside the reserved lobby rects, which must themselves be inside the entrance building
		# (the indoor neutral zone) -- not the outdoor lot.
		var sz: Dictionary = info.get("safe_zone", {})
		if not (sz.get("pharmacy_rect") is Rect2) or not (sz.get("crematorium_rect") is Rect2):
			_fail("%s: safe_zone pharmacy/crematorium reservation is missing" % tag)
		else:
			for key in ["pharmacy_rect", "crematorium_rect"]:
				var r: Rect2 = sz[key]
				if not er.grow(0.1).encloses(r):
					_fail("%s: safe_zone.%s is not inside the entrance building" % [tag, key])
		var amb: Vector3 = info.get("ambulance", {}).get("position", Vector3.ZERO)
		if not nr.grow(0.1).has_point(Vector2(amb.x, amb.z)):
			_fail("%s: the ambulance spot is not outside" % tag)
		var wings: Array = info.get("wings", [])
		if wings.size() != 3:
			_fail("%s: %d wings, expected 3" % [tag, wings.size()])
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
			var in_pocket: bool = not info.get("pockets", {}).is_empty() and (info.pockets.rect as Rect2).has_point(q)   # POCKETS
			if HB.zone_of(info, m) in ["entrance", "neutral", ""] and not in_pocket:
				_fail("%s: monster spawn %s is not in a wing" % [tag, str(m)])
		var ids := {}
		for c in info.get("containers", []):
			if ids.has(c.id):
				_fail("%s: duplicate container id %s" % [tag, c.id])
			ids[c.id] = true
		for key in ["shelf", "lectern"]:
			if not info.has(key):
				_fail("%s: no %s spot" % [tag, key])
		# Hub rebuild (2026-09-16): the supply shelf stands in the OR's storage closet, a few steps
		# from the tables rather than beside them.
		if info.has("shelf"):
			var in_closet := false
			for r in info.get("rooms", []):
				if String(r.kind) == "or_storage" and (r.rect as Rect2).has_point(Vector2(info.shelf.position.x, info.shelf.position.z)):
					in_closet = true
			if not in_closet:
				_fail("%s: the supply shelf is not in the OR's storage closet" % tag)
			if Vector2(info.shelf.position.x - info.table.x, info.shelf.position.z - info.table.z).length() > 10.0:
				_fail("%s: OR shelf spot is far from the table" % tag)
		if (info.nav_region as NavigationRegion3D).navigation_mesh.get_polygon_count() <= 0:
			_fail("%s: navigation mesh has no polygons" % tag)
		# DOORS: a door node in every doorway, standing in its doorway, closed, blocking it.
		var by_tile := {}
		for dn in info.get("door_nodes", []):
			for t in dn.data.tiles:
				by_tile[t] = dn
			var tile := C.world_to_tile(dn.transform.origin - dn.transform.basis.z * 0.2)
			if not (dn.data.tiles as Array).has(tile):
				_fail("%s: door %s stands outside its doorway (%s)" % [tag, dn.door_id, str(tile)])
		var rows2: PackedStringArray = info.rows
		var bare := 0
		for y in rows2.size():
			for x in rows2[y].length():
				if rows2[y][x] == "+" and not by_tile.has(Vector2i(x, y)):
					bare += 1
		if bare > 0:
			_fail("%s: %d doorway tiles without a door node" % [tag, bare])
		var gates := 0
		for dn in info.get("door_nodes", []):
			if dn.kind == "gate":
				gates += 1
		if gates != (info.get("wings", []) as Array).size():
			_fail("%s: %d wing gates for %d wings" % [tag, gates, (info.get("wings", []) as Array).size()])

	func _physics_process(_delta: float) -> void:
		if level == null:
			_start_next()
			return
		waited += 1
		var region: NavigationRegion3D = info.nav_region
		var map := region.get_navigation_map()
		var synced: bool = map.is_valid() and NavigationServer3D.map_get_iteration_id(map) >= base_iter + 2
		# POCKETS: regions update asynchronously; wait until both the hospital's and the pocket's are in.
		if synced:
			var t: Vector3 = info.table
			synced = NavigationServer3D.map_get_closest_point(map, t).distance_to(t) < 5.0
			if synced and not info.get("pockets", {}).is_empty():
				var sp: Vector3 = info.pockets.spawn
				synced = NavigationServer3D.map_get_closest_point(map, sp).distance_to(sp) < 5.0
		if not synced and waited < 600:
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
		_check_pocket_nav(tag, map, start)
		# Every container and loose anchor must be reachable to within interaction range.
		var unreachable := 0
		var examples: Array = []
		var spots: Array = []
		for c in info.containers:
			# Aim at the container's front, half a metre out from the wall, at waist height.
			var node: Node3D = c.node
			var front: Vector3 = c.position + node.global_basis.z.normalized() * -0.45 if node.is_inside_tree() else c.position
			spots.append([c.id, Vector3(front.x, 1.0, front.z)])
		for i in info.loose_anchors.size():
			spots.append(["anchor %d (%s, %s)" % [i, info.loose_anchors[i].surface, info.loose_anchors[i].room_kind], info.loose_anchors[i].position])
		var los_space := get_tree().root.world_3d.direct_space_state
		for s in spots:
			var p: Vector3 = s[1]
			# A standing spot on the navigation mesh, reachable from outside, from which the eye
			# (1.7 m) is within interaction range of the target with nothing solid in between.
			var ok := false
			var best_flat := INF
			# POCKETS: stand on the level the spot is on (the Factory's catwalk is 6 m up).
			var floor_y := maxf(0.0, p.y - 1.2)
			var cands: Array = [NavigationServer3D.map_get_closest_point(map, Vector3(p.x, floor_y, p.z))]
			for k in 8:
				for rad in [0.9, 1.5]:
					var a := TAU * k / 8.0
					cands.append(NavigationServer3D.map_get_closest_point(map, Vector3(p.x + cos(a) * rad, floor_y, p.z + sin(a) * rad)))
			for q in cands:
				var flat := Vector2(q.x - p.x, q.z - p.z).length()
				best_flat = minf(best_flat, flat)
				var eye: Vector3 = q + Vector3.UP * C.EYE_H
				if eye.distance_to(p) > C.INTERACT_RANGE:
					continue
				var ray := PhysicsRayQueryParameters3D.create(eye, p)
				ray.collision_mask = C.L_WORLD
				var hit := los_space.intersect_ray(ray)
				if not hit.is_empty() and (hit.position as Vector3).distance_to(p) > 0.5:
					continue
				var path := NavigationServer3D.map_get_path(map, start, q, true)
				if path.size() >= 2 and path[path.size() - 1].distance_to(q) < 0.6:
					ok = true
					break
			if not ok:
				unreachable += 1
				if examples.size() < 4:
					examples.append("%s at (%.1f, %.2f, %.1f), nav %.2f m away" % [s[0], p.x, p.y, p.z, best_flat])
		if unreachable > 0:
			_fail("%s: %d containers / anchors out of reach, e.g. %s" % [tag, unreachable, "; ".join(examples)])
		# Things resting on furniture need a collider under them: loose items on counters, trays
		# and gurneys, and the patient on each OR table.
		var space := get_tree().root.world_3d.direct_space_state
		var unsupported: Array = []
		var rests: Array = []
		for a in info.loose_anchors:
			if a.surface != "floor":
				rests.append(["%s anchor (%s)" % [a.surface, a.room_kind], a.position])
		for t in info.tables:
			rests.append(["%s table" % t.kind, t.position + Vector3(0, 0.945, 0)])
		for rest in rests:
			var p: Vector3 = rest[1]
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.4, p + Vector3.DOWN * 0.5)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			if hit.is_empty() or absf(hit.position.y - p.y) > 0.12:
				if unsupported.size() < 4:
					unsupported.append("%s at (%.1f, %.2f, %.1f) lands at %s" % [rest[0], p.x, p.y, p.z, "nothing" if hit.is_empty() else "%.2f" % hit.position.y])
				else:
					unsupported.append("")
		if not unsupported.is_empty():
			_fail("%s: %d resting spots have no surface under them, e.g. %s" % [tag, unsupported.size(), "; ".join(unsupported.slice(0, 4))])
		print("  nav: coverage %.1f%%, longest path from the neutral area %.0f m, %d spots checked, %d out of reach" % [
				coverage * 100.0, longest, spots.size(), unreachable])

	## POCKETS: into the pocket from outside through a seam link; from inside the pocket out through
	## every entrance's link to its hospital mouth; the pocket's open tiles covered by its navigation.
	func _check_pocket_nav(tag: String, map: RID, start: Vector3) -> void:
		var pk: Dictionary = info.get("pockets", {})
		if pk.is_empty():
			return
		var spawn: Vector3 = pk.spawn
		var path := NavigationServer3D.map_get_path(map, start, NavigationServer3D.map_get_closest_point(map, spawn), true)
		if path.size() < 2 or path[path.size() - 1].distance_to(spawn) > 2.5 or _longest_step(path) < 100.0:
			_fail("%s: no navigation path from the neutral area into the %s through a seam" % [tag, pk.kind])
		var through := 0
		for s in pocket_seams:
			var mouth := NavigationServer3D.map_get_closest_point(map, Stub.local_point(s.xh, 1.0, 0.6))
			var p2 := NavigationServer3D.map_get_path(map, NavigationServer3D.map_get_closest_point(map, spawn), mouth, true)
			if p2.size() < 2 or p2[p2.size() - 1].distance_to(mouth) > 0.6 or _longest_step(p2) < 100.0:
				_fail("%s: no navigation path from inside the %s out to entrance %d" % [tag, pk.kind, s.id])
				continue
			# From just inside its own opening, out through its own link.
			var inside := NavigationServer3D.map_get_closest_point(map, Stub.local_point(s.xp, float(s.w) - 1.0, 0.6))
			var p3 := NavigationServer3D.map_get_path(map, inside, mouth, true)
			var own := false
			for i in range(1, p3.size()):
				if p3[i - 1].distance_to(s.link_p) < 1.2 and p3[i].distance_to(s.link_h) < 1.2:
					own = true
					break
			if own:
				through += 1
			else:
				var jumps := []
				for i in range(1, p3.size()):
					if p3[i - 1].distance_to(p3[i]) > 100.0:
						jumps.append([p3[i - 1], p3[i]])
				print("  entrance %d: from %s to %s the path jumps %s; its link is %s -> %s" % [s.id, str(inside), str(mouth), str(jumps), str(s.link_p), str(s.link_h)])
		if through < pocket_seams.size():
			_fail("%s: only %d of %d entrances were walked straight through their own seam" % [tag, through, pocket_seams.size()])
		var origin: Vector2i = pk.origin
		var covered := 0
		var open := 0
		# Coverage from the pocket's grid, rebuilt from the plan (layouts are pure).
		var plan := Plan.of(gen)
		var layout_script: GDScript = PS.Factory if String(plan.kind) == "factory" else PS.Restaurant
		var g: Dictionary = layout_script.layout(plan.stubs, int(plan.seed)).grid
		for y in int(g.h):
			for x in int(g.w):
				var i: int = y * int(g.w) + x
				if g.cells[i] == 35 or g.nav[i] == 1:
					continue
				open += 1
				var p := C.tile_to_world(origin.x + x, origin.y + y)
				if NavigationServer3D.map_get_closest_point(map, p).distance_to(p) < 0.8:
					covered += 1
		var coverage := float(covered) / maxf(1.0, open)
		if coverage < 0.9:
			_fail("%s: the %s's navigation covers only %.1f%% of its open tiles" % [tag, pk.kind, coverage * 100.0])
		print("  pocket nav: %s coverage %.1f%%, %d/%d entrances walked out through their seam" % [pk.kind, coverage * 100.0, through, pocket_seams.size()])

	static func _longest_step(path: PackedVector3Array) -> float:
		var best := 0.0
		for i in range(1, path.size()):
			best = maxf(best, path[i - 1].distance_to(path[i]))
		return best

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
