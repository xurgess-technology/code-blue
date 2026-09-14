extends Node
## POCKETS: the runtime side of pocket spaces. `game.pockets` (child "Pockets" of Game, every machine).
##
##   build_wings(info, wing_seed, generation)   (game.wing_loader.extra_builders) after a level's or
##                              a new shift's wings are built: builds the pocket MapGen planned into
##                              them (info.pocket_plan) under info.wings_root, far from the hospital:
##                              the interior with its doors, the pocket copy of every entrance stub,
##                              the navigation region and the seam links, and adds the pocket's
##                              lights, containers, anchors and monster spawns to `info` (see
##                              docs/CONTRACTS.md "Hospital", pockets). Data on a worker thread, the
##                              nodes within FRAME_BUDGET_MS a frame; `busy` meanwhile, finish_now().
##   teardown_wings()           the wings are going: evict, forget, free the nodes a few at a time.
##   build_kind(kind, info, parent, seed)   a pocket with no hospital entrances (the dev room).
##   teardown()                 forget everything (the level is going, the nodes with it).
##
## Every physics frame, on every machine, anything a machine owns that stands past a seam is moved
## to the other copy of its stub (the move keeps its offset from the seam, its velocity and its
## facing): the local player and host bots on their own machine, monsters and loose world items on
## the host. Carried players and dragged monsters follow whoever pins them. Everything else (remote
## players and monsters on a client) arrives through the snapshots and snaps instead of lerping
## (`snap_distance`).

const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")
const Factory := preload("res://scripts/level/pockets/factory.gd")
const Restaurant := preload("res://scripts/level/pockets/restaurant.gd")
const Common := preload("res://scripts/level/pockets/pocket_common.gd")

## World tile of each pocket's local tile (0, 0): far outside any hospital (maps are ~110 m).
const ORIGINS := {"factory": Vector2i(800, 0), "restaurant": Vector2i(800, 500)}
## A remote body that jumps further than this between snapshots is moved, not interpolated.
const SNAP_DISTANCE := 6.0
## Noises within this many metres of a seam (on its own side) are also heard on the other side.
const NOISE_REACH := 26.0
const LINK_OFFSET := 0.6
const T2 := 1.5

## Main-thread work per frame while building for a new shift, milliseconds (the wing loader's).
const FRAME_BUDGET_MS := 5.0

var game: Node = null
## {kind, origin: Vector2i, rect: Rect2 (world XZ), root: Node3D, spawn: Vector3, wing, depth} or {}
var pocket: Dictionary = {}
## Seam records, see _make_seam.
var seams: Array = []
## Crossings this machine performed (tests): [{what, id, seam, to_pocket, time}]
var crossings: Array = []
## Tools (screenshots of both copies): false stops moving anything across seams.
var crossing_enabled := true
## A pocket is being built for this shift's wings (clock-in and the gates wait for it).
var busy := false
## The last per-shift build: {kind, generation, frames, steps, max_frame_ms, slowest_step_ms,
## thread_ms, wall_ms}.
var stats := {}

var _task := -1
var _job := {}
var _steps: Array = []
var _step_i := 0
## Detached nodes of the last pocket, freed a few at a time (post-order: leaves first).
var _trash: Array = []


func setup(g: Node) -> void:
	game = g


func active() -> bool:
	return not pocket.is_empty()


# =========================================================================
# per-shift build (scripts/level/wing_loader.gd extra_builders)
# =========================================================================

## The wings were built (a whole level, or a new shift's wings): build the pocket MapGen planned
## into them. The layout, the surface arrays and the navigation bake run on a worker thread, the
## nodes a few at a time within FRAME_BUDGET_MS per frame under info.wings_root.
func build_wings(info: Dictionary, _wing_seed: int, generation: int) -> void:
	_cancel_build()
	_forget()
	info["pockets"] = {}
	var plan: Dictionary = info.get("pocket_plan", {})
	var parent = info.get("wings_root")
	if plan.is_empty() or parent == null or not is_instance_valid(parent) or (game != null and bool(game.get("dev_mode"))):
		return
	busy = true
	stats = {"kind": String(plan.kind), "generation": generation, "frames": 0, "steps": 0, "max_frame_ms": 0.0,
			"slowest_step_ms": 0.0, "started_ms": Time.get_ticks_msec()}
	var job := {"kind": String(plan.kind), "stubs": plan.stubs, "seed": int(plan.seed), "map_seed": int(info.get("map_seed", 0)),
			"lights": info.get("map_lights", []), "info": info, "parent": parent, "generation": generation}
	_job = job
	_task = WorkerThreadPool.add_task(func(): _thread_prepare(job), false, "pocket")


static func _thread_prepare(job: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	job["prep"] = prepare(String(job.kind), job.stubs, int(job.seed))
	job["thread_ms"] = Time.get_ticks_msec() - t0


## The wings are going (a new shift): nobody may stay in the pocket or its entrance stubs, what was
## left in there is gone, and the pocket's nodes are freed over the next frames.
func teardown_wings() -> void:
	_evict()
	_cancel_build()
	_forget()


## Finish a build in progress right now (a whole level being built, begin_shift, tools).
func finish_now() -> void:
	if not busy:
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_start_steps()
	while _step_i < _steps.size():
		_run_step()
	_finish_build()


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var budget := int(FRAME_BUDGET_MS * 1000.0)
	while not _trash.is_empty() and Time.get_ticks_usec() - t0 < budget:
		var n = _trash.pop_back()
		if is_instance_valid(n):
			(n as Node).free()
	if busy:
		_build_tick(t0, budget)
	if pocket.is_empty():
		return
	_process_mirrors()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	_blend_environment(air_factor(cam.global_position))


func _build_tick(t0: int, budget: int) -> void:
	stats.frames = int(stats.frames) + 1
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		stats["thread_ms"] = int(_job.get("thread_ms", 0))
		_start_steps()
	while _step_i < _steps.size() and Time.get_ticks_usec() - t0 < budget:
		_run_step()
	stats.max_frame_ms = maxf(float(stats.max_frame_ms), float(Time.get_ticks_usec() - t0) / 1000.0)
	if _step_i >= _steps.size():
		_finish_build()


func _start_steps() -> void:
	var j := _job
	j["seams"] = []
	j["result"] = {}
	_steps = build_steps(j.prep, j.stubs, int(j.map_seed), j.lights, j.info, j.parent, j.seams, true, j.result)
	_step_i = 0


func _run_step() -> void:
	var s0 := Time.get_ticks_usec()
	var more = (_steps[_step_i] as Callable).call()
	_step_i += 1
	if more is Array and not (more as Array).is_empty():
		_steps = _steps.slice(0, _step_i) + more + _steps.slice(_step_i)
	stats.steps = int(stats.steps) + 1
	stats.slowest_step_ms = maxf(float(stats.slowest_step_ms), float(Time.get_ticks_usec() - s0) / 1000.0)


func _finish_build() -> void:
	var j := _job
	var result: Dictionary = j.result
	pocket = result
	seams = j.seams
	for s in seams:
		if int(s.depth) > int(pocket.get("depth", -1)):
			pocket["depth"] = int(s.depth)
			pocket["wing"] = String(s.wing)
	if game != null:
		_attach_flicker(pocket.root)
		if game.get("doors") != null:
			game.doors.register(result.get("doors", []))
	busy = false
	_job = {}
	_steps = []
	_step_i = 0
	stats["wall_ms"] = Time.get_ticks_msec() - int(stats.get("started_ms", 0))
	print("[pockets] %s built for wings generation %d: %d frames, %d steps, %d ms wall, %d ms on the thread, longest frame of work %.1f ms, slowest step %.1f ms" % [
		String(pocket.kind), int(stats.generation), int(stats.frames), int(stats.steps), int(stats.wall_ms),
		int(stats.get("thread_ms", 0)), float(stats.max_frame_ms), float(stats.slowest_step_ms)])


func _cancel_build() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not _job.is_empty():
		var result: Dictionary = _job.get("result", {})
		if is_instance_valid(result.get("root")):
			_trash_node(result.root)
	_job = {}
	_steps = []
	_step_i = 0
	busy = false


## Forget the pocket (its nodes go to the trash, unless the whole level is going anyway).
func _forget(free_nodes := true) -> void:
	_blend_environment(0.0)
	for e in _mirrors.values():
		_free_mirror(e)
	_mirrors.clear()
	if free_nodes and not pocket.is_empty() and is_instance_valid(pocket.get("root")):
		_trash_node(pocket.root)
	pocket = {}
	seams = []


func _trash_node(root: Node) -> void:
	if root.get_parent() != null:
		root.get_parent().remove_child(root)
	# Post-order, so each free has no children left and costs next to nothing.
	var stack: Array = [root]
	var order: Array = []
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		order.append(n)
		for c in n.get_children():
			stack.append(c)
	# `order` is parents before children; the trash pops from the back, so children go first.
	_trash.append_array(order)


## Host: players (and bots) in the pocket or in an entrance stub go out in front of that wing's gate;
## monsters and loose items in there are gone. A client steps its own player out.
func _evict() -> void:
	if game == null or (pocket.is_empty() and seams.is_empty()):
		return
	var wl = game.get("wing_loader")
	var slot := 3
	for p in game.players.values():
		if p == null or not is_instance_valid(p):
			continue
		var wing := _wing_inside(p.global_position)
		if wing == "":
			continue
		if not game.is_host() and not p.is_local:
			continue
		var to: Vector3 = wl.gate_front(wing, slot) if wl != null else Vector3.ZERO
		slot += 1
		if p.is_local or bool(p.get("is_bot")) or not Net.active:
			p.teleport(to)
		else:
			game._event.rpc_id(p.peer_id, "dr_evict", {"pos": to})
	if not game.is_host():
		return
	for id in game.monsters.keys():
		var m = game.monsters[id]
		if m == null or not is_instance_valid(m) or _wing_inside(m.global_position) == "":
			continue
		game.monsters.erase(id)
		if game.combat != null and game.combat.has_method("on_monster_removed"):
			game.combat.on_monster_removed(m)
		m.queue_free()
	for id in game.world_items.keys():
		var it = game.world_items[id]
		if it == null or not is_instance_valid(it) or _wing_inside(it.global_position) == "":
			continue
		it.queue_free()
		game.world_items.erase(id)
		game._shift_item_ids.erase(id)


## The wing whose gate someone at `p` leaves by: the pocket's (its deepest), or the stub's.
func _wing_inside(p: Vector3) -> String:
	if in_pocket(p):
		return String(pocket.get("wing", ""))
	for s in seams:
		if _in_stub(s, p, true):
			return String(s.wing)
	return ""


## The stub copies' ceiling fixtures flicker like the hospital's (game._attach_light_flicker ran
## before the pocket existed).
func _attach_flicker(root: Node) -> void:
	var stubs := root.get_node_or_null("Stubs")
	if stubs == null:
		return
	for light in stubs.find_children("*", "Light3D", true, false):
		if not light.is_in_group("fixture"):
			continue
		if not light.has_meta("seed"):
			light.set_meta("seed", hash(str(game.seed_value) + str(light.name)))
		light.distance_fade_enabled = true
		light.distance_fade_begin = 16.0
		light.distance_fade_length = 6.0
		light.add_child(LightFlicker.new())


# =========================================================================
# build
# =========================================================================

## A pocket with no hospital (the dev room): two stand-in stubs, both sealed on the far side.
func build_kind(kind: String, info: Dictionary, parent: Node3D, pocket_seed: int) -> void:
	teardown()
	var stubs := [
		{"id": 0, "wing": "dev", "depth": 2, "zone": Plan.ZONE_STUB, "o": Vector2i(-400, -400), "eu": Vector2i(1, 0), "ev": Vector2i(0, 1), "w": 10, "d": 6, "lights": []},
		{"id": 1, "wing": "dev", "depth": 2, "zone": Plan.ZONE_STUB, "o": Vector2i(-400, -380), "eu": Vector2i(-1, 0), "ev": Vector2i(0, 1), "w": 10, "d": 6, "lights": []},
	]
	# No hospital behind these stubs: their seams are not registered (nothing crosses; both ends dead-end).
	var unused: Array = []
	pocket = build_into(kind, stubs, pocket_seed, pocket_seed, [], info, parent, unused, false)
	pocket["depth"] = 2
	pocket["wing"] = "dev"
	if game != null and game.get("doors") != null:
		game.doors.register(pocket.get("doors", []))


## Data only (a worker thread): the layout, the surface arrays, the navigation mesh.
static func prepare(kind: String, stubs: Array, pocket_seed: int) -> Dictionary:
	var layout_script: GDScript = Factory if kind == "factory" else Restaurant
	var origin: Vector2i = ORIGINS.get(kind, Vector2i(800, 0))
	var lay: Dictionary = layout_script.layout(stubs, pocket_seed)
	var interior: Dictionary = layout_script.prepare(lay, origin)
	return {"kind": kind, "origin": origin, "lay": lay, "interior": interior, "nav": Common.bake_nav(interior.nav_faces)}


## Everything at once (tools/mapcheck.gd builds without a Game, the dev room). Fills `out_seams`.
static func build_into(kind: String, stubs: Array, pocket_seed: int, map_seed: int, hospital_lights: Array,
		info: Dictionary, parent: Node3D, out_seams: Array, links := true) -> Dictionary:
	var result := {}
	Common.run_steps(build_steps(prepare(kind, stubs, pocket_seed), stubs, map_seed, hospital_lights, info, parent, out_seams, links, result))
	return result


## The nodes of a prepared pocket as small steps (see Common.run_steps). When the last one ran,
## `result` is the pocket record, `out_seams` the seams and `info` has the pocket's contract keys.
static func build_steps(prep: Dictionary, stubs: Array, map_seed: int, hospital_lights: Array,
		info: Dictionary, parent: Node3D, out_seams: Array, links: bool, result: Dictionary) -> Array:
	var kind: String = prep.kind
	var layout_script: GDScript = Factory if kind == "factory" else Restaurant
	var origin: Vector2i = prep.origin
	var lay: Dictionary = prep.lay
	var out := {"lights": [], "containers": [], "loose_anchors": [], "monster_spawns": [], "nav_faces": PackedVector3Array()}
	var depth := 1
	var wing := ""
	for s in stubs:
		if int(s.depth) >= depth:
			depth = int(s.depth)
			wing = String(s.wing)
	out["wing"] = wing
	out["depth"] = depth
	var root := Node3D.new()
	root.name = "Pocket_" + kind
	result["root"] = root
	var interior := Node3D.new()
	interior.name = kind.capitalize()
	var copies := Node3D.new()
	copies.name = "Stubs"
	var steps: Array = []
	steps.append(func():
		root.add_child(interior)
		root.add_child(copies)
		parent.add_child(root)
		return layout_script.build_steps(lay, origin, out, interior, prep.interior))
	# Doors in the pocket's own doorways (scripts/doors), under the interior so they share its layer.
	var doors: Array = []
	steps.append(func():
		for d in layout_script.door_entries(lay, origin):
			d["wing"] = wing
			d["depth"] = depth
			var node: Node3D = Common.HB.DoorsScript.create(d)
			interior.add_child(node)
			doors.append(node))
	# Entrance copies, seams and links: a step each.
	for i in stubs.size():
		steps.append(func():
			var s: Dictionary = stubs[i]
			var port: Dictionary = lay.ports[i]
			var seam := _make_seam(s, port, origin)
			var holder := Node3D.new()
			holder.name = "Seam_%d" % i
			holder.transform = seam.t
			copies.add_child(holder)
			var copy := Stub.build_copy(s, map_seed, hospital_lights)
			holder.add_child(copy.node)
			for l in copy.lights:
				out.lights.append({"tile": l.tile, "position": seam.t * (l.position as Vector3), "mode": l.mode, "node": l.node, "pocket": kind})
			if links:
				var link := NavigationLink3D.new()
				link.name = "Link_%d" % i
				link.bidirectional = true
				link.start_position = seam.link_h
				link.end_position = seam.link_p
				# Far apart in the world, one step apart on foot: cost the distance actually walked.
				link.travel_cost = 1.0 / maxf(1.0, seam.link_h.distance_to(seam.link_p))
				link.enter_cost = 0.0
				root.add_child(link)
				seam["link"] = link
			out_seams.append(seam))
	steps.append(func():
		for gi in interior.find_children("*", "GeometryInstance3D", true, false):
			(gi as GeometryInstance3D).layers = 1 << Stub.POCKET_LAYER_BIT)
	# Navigation over the pocket's own grid (stub copies included, the halves never walked left out).
	steps.append(func():
		var nav := NavigationRegion3D.new()
		nav.name = "Nav"
		nav.navigation_mesh = prep.nav
		root.add_child(nav)
		var world_rect := Rect2(Vector2(origin) * C.TILE, Vector2(lay.size) * C.TILE)
		result.merge({"kind": kind, "origin": origin, "rect": world_rect, "nav_region": nav,
				"spawn": out.get("spawn", Vector3(world_rect.get_center().x, 0.0, world_rect.get_center().y)),
				"rows": lay.rows, "size": lay.size, "wing": wing, "depth": depth, "layout": lay, "doors": doors}, true)
		# The contract keys the rest of the game reads.
		for key in ["lights", "containers", "loose_anchors", "monster_spawns"]:
			if not info.has(key):
				info[key] = []
			(info[key] as Array).append_array(out[key])
		var seam_info: Array = []
		for s in out_seams:
			seam_info.append({"id": s.id, "wing": s.wing, "depth": s.depth, "w": s.w, "d": s.d,
					"hospital": s.xh, "pocket": s.xp, "transform": s.t,
					"mouth": s.mouth, "opening": s.opening, "link": [s.link_h, s.link_p]})
		info["pockets"] = {"kind": kind, "rect": world_rect, "origin": origin, "spawn": result.spawn, "wing": wing,
				"depth": depth, "seams": seam_info, "nav_region": nav})
	return steps


## Warmup (scripts/warmup.gd): both spaces' meshes and materials, shrunk in front of the camera for
## a few frames so nothing compiles the first time a pocket comes into view. No lights, colliders,
## occluders or containers (they would act in the world while kept alive).
static func warm(parent: Node3D) -> void:
	var fake := [
		{"id": 0, "wing": "", "depth": 1, "o": Vector2i(0, 0), "eu": Vector2i(1, 0), "ev": Vector2i(0, 1), "w": 10, "d": 6, "lights": []},
		{"id": 1, "wing": "", "depth": 1, "o": Vector2i(0, 20), "eu": Vector2i(-1, 0), "ev": Vector2i(0, 1), "w": 12, "d": 5, "lights": []},
	]
	var x := -1.2
	for script: GDScript in [Factory, Restaurant]:
		var lay: Dictionary = script.layout(fake, 1)
		var out := {"lights": [], "containers": [], "loose_anchors": [], "monster_spawns": [], "nav_faces": PackedVector3Array(), "wing": "", "depth": 1}
		var root: Node3D = script.build(lay, Vector2i.ZERO, out)
		for n in root.find_children("*", "CollisionObject3D", true, false) + root.find_children("*", "OccluderInstance3D", true, false) \
				+ root.find_children("*", "Light3D", true, false):
			n.get_parent().remove_child(n)
			n.free()
		for n in ["Containers"]:
			var c := root.get_node_or_null(n)
			if c != null:
				root.remove_child(c)
				c.free()
		root.scale = Vector3.ONE * 0.012
		root.position = Vector3(x, -0.4, -0.6)
		parent.add_child(root)
		x += 1.1
	var copy := Stub.build_copy(fake[0], 1, [])
	for n in copy.node.find_children("*", "CollisionObject3D", true, false) + copy.node.find_children("*", "OccluderInstance3D", true, false) \
			+ copy.node.find_children("*", "Light3D", true, false):
		n.get_parent().remove_child(n)
		n.free()
	(copy.node as Node3D).scale = Vector3.ONE * 0.05
	(copy.node as Node3D).position = Vector3(1.0, -0.4, -0.6)
	parent.add_child(copy.node)


static func _make_seam(s: Dictionary, port: Dictionary, origin: Vector2i) -> Dictionary:
	var w: int = s.w
	var d: int = s.d
	var xh := Stub.frame(s.o, s.eu, s.ev)
	var xp := Stub.frame(origin + (port.o as Vector2i), port.eu, port.ev)
	var t := xp * xh.affine_inverse()
	var mid := Stub.seam_s(w)
	var back := float(d) - Stub.CORRIDOR * 0.5
	# World XZ bounds of each copy (the stub block and a margin), for a cheap first test.
	var bounds := func(xf: Transform3D) -> Rect2:
		var a: Vector3 = xf * Vector3(-T2, 0.0, -T2)
		var r := Rect2(Vector2(a.x, a.z), Vector2.ZERO)
		for c in [Vector3((w + 1) * Stub.T, 0.0, -T2), Vector3(-T2, 0.0, (d + 1) * Stub.T), Vector3((w + 1) * Stub.T, 0.0, (d + 1) * Stub.T)]:
			var b: Vector3 = xf * c
			r = r.expand(Vector2(b.x, b.z))
		return r
	return {"id": int(s.id), "bounds_h": bounds.call(xh), "bounds_p": bounds.call(xp),
			"xh_inv": xh.affine_inverse(), "xp_inv": xp.affine_inverse(), "wing": String(s.wing), "depth": int(s.depth), "w": w, "d": d,
			"xh": xh, "xp": xp, "t": t, "t_inv": t.affine_inverse(), "yaw": t.basis.get_euler().y,
			"link_h": Stub.local_point(xh, mid - LINK_OFFSET / Stub.T, back),
			"link_p": Stub.local_point(xp, mid + LINK_OFFSET / Stub.T, back),
			"seam_h": Stub.local_point(xh, mid, back), "seam_p": Stub.local_point(xp, mid, back),
			"mouth": Stub.local_point(xh, Stub.CORRIDOR * 0.5, -1.5),
			"opening": Stub.local_point(xp, float(w) - Stub.CORRIDOR * 0.5, -1.5)}


## The whole level is going (game._clear_level): stop, forget; the nodes go with the level.
func teardown() -> void:
	_cancel_build()
	_forget(false)



# =========================================================================
# queries
# =========================================================================

## "" for the hospital (or no pocket), else the pocket's kind.
func space_of(p: Vector3) -> String:
	if pocket.is_empty():
		return ""
	return String(pocket.kind) if (pocket.rect as Rect2).grow(2.0).has_point(Vector2(p.x, p.z)) else ""


func in_pocket(p: Vector3) -> bool:
	return space_of(p) != ""


## [seam, to_pocket] when `p` stands in the half of a stub copy nobody should stand in, else [].
func phantom_at(p: Vector3) -> Array:
	var q := Vector2(p.x, p.z)
	for s in seams:
		for to_pocket in [true, false]:
			if not (s.bounds_h if to_pocket else s.bounds_p).has_point(q):
				continue
			var l0: Vector3 = (s.xh_inv if to_pocket else s.xp_inv) * p
			var l := Vector3(l0.x / Stub.T, l0.y, l0.z / Stub.T)
			if l.y < -1.5 or l.y > C.WALL_H + 1.0:
				continue
			if l.z < 0.0 or l.z > float(s.d) or l.x < 0.0 or l.x > float(s.w):
				continue
			var past: bool = l.x >= Stub.seam_s(s.w)
			if past == to_pocket:
				return [s, to_pocket]
	return []


## The real place a point stands for: a point in a stub's unwalked half maps to the other copy.
func real_point(p: Vector3) -> Vector3:
	var hit := phantom_at(p)
	if hit.is_empty():
		return p
	return (hit[0].t if hit[1] else hit[0].t_inv) * p


## Monster steering: the next path point after a seam link lies in the other space; walk toward
## where it is in this space instead (across the seam), and the crossing does the rest.
func steer_point(from: Vector3, next: Vector3) -> Vector3:
	if seams.is_empty() or space_of(from) == space_of(next):
		return next
	var into_pocket := in_pocket(next)
	var best := next
	var best_d := 8.0
	for s in seams:
		var m: Vector3 = (s.t_inv if into_pocket else s.t) * next
		var dd := Vector2(m.x - from.x, m.z - from.z).length()
		if dd < best_d:
			best_d = dd
			best = m
	return best


## Extra noise positions on the other side of each seam near `pos` (host, emit_noise).
func mirror_noise(pos: Vector3, loudness: float) -> Array:
	var out: Array = []
	if seams.is_empty():
		return out
	var here_pocket := in_pocket(pos)
	for s in seams:
		var seam_here: Vector3 = s.seam_p if here_pocket else s.seam_h
		if pos.distance_to(seam_here) > minf(NOISE_REACH, loudness * 22.0 + 4.0):
			continue
		# Where the noise is in this copy's own frame, pulled into the stub's walked half, then the
		# same spot in the other copy (its unwalked half: real_point() leads there through the seam).
		var own: Transform3D = s.xp if here_pocket else s.xh
		var other: Transform3D = s.xh if here_pocket else s.xp
		var l := Stub.to_local(own, pos)
		var mid := Stub.seam_s(s.w)
		var back := float(s.d) - Stub.CORRIDOR * 0.5
		var sl := clampf(l.x, 0.6, mid - 0.2) if not here_pocket else clampf(l.x, mid + 0.2, float(s.w) - 0.6)
		var tl := clampf(l.z, 0.4, back)
		out.append(Stub.local_point(other, sl, tl, clampf(l.y, 0.0, 2.5)))
	return out


# =========================================================================
# crossing
# =========================================================================

func _physics_process(_delta: float) -> void:
	if seams.is_empty() or game == null or not crossing_enabled:
		return
	var host: bool = game.is_host()
	for p in game.players.values():
		if not is_instance_valid(p) or not p.alive:
			continue
		var owns: bool = p.is_local or (p.is_bot and host)
		if not owns or p.carried_by != 0 or p.on_table:
			continue
		var hit := phantom_at(p.global_position)
		if not hit.is_empty():
			transfer_player(p, hit[0], hit[1])
	if host:
		for m in game.monsters.values():
			if not is_instance_valid(m) or int(m.get("dragged_by")) != 0:
				continue
			var hit := phantom_at(m.global_position)
			if not hit.is_empty():
				transfer_monster(m, hit[0], hit[1])
		for it in game.world_items.values():
			# Only what is moving: a settled item never slides across a seam.
			if not is_instance_valid(it) or it.freeze or it.get("state") != WorldItem.State.LOOSE:
				continue
			var hit := phantom_at(it.global_position)
			if not hit.is_empty():
				transfer_item(it, hit[0], hit[1])
	_update_ghosts()


func transfer_player(p: Node, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var yaw: float = s.yaw if to_pocket else -float(s.yaw)
	p.global_position = t * p.global_position
	p.velocity = t.basis * p.velocity
	p.rotation.y += yaw
	p.set("_yaw", float(p.get("_yaw")) + yaw)
	p.bot_yaw += yaw
	p.set("_knock", t.basis * (p.get("_knock") as Vector3))
	p.set("_target_pos", p.global_position)
	p.set("_target_yaw", p.rotation.y)
	# Whoever rides along is put where they belong now, not a frame later on the far side of the world.
	if int(p.carrying) != 0 and game != null:
		var q = game.players.get(int(p.carrying))
		if q != null and is_instance_valid(q):
			var pose: Transform3D = game.pinned_pose(q)
			q.global_position = pose.origin
			q.set("_target_pos", pose.origin)
	var dm := int(p.get("dragging_monster")) if p.get("dragging_monster") != null else -1
	if dm >= 0 and game != null and game.combat != null and game.combat.has_method("monster_pin"):
		var m = game.monsters.get(dm)
		if m != null and is_instance_valid(m):
			m.global_position = (game.combat.monster_pin(m) as Transform3D).origin
			m.set("_target_pos", m.global_position)
	_note("player", int(p.peer_id), s, to_pocket)


func transfer_monster(m: Node, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var yaw: float = s.yaw if to_pocket else -float(s.yaw)
	m.global_position = t * m.global_position
	m.velocity = t.basis * m.velocity
	m.rotation.y += yaw
	m.set("_target_pos", m.global_position)
	m.set("_target_yaw", m.rotation.y)
	m.set("_repath", 0.0)
	_note("monster", int(m.monster_id), s, to_pocket)


func transfer_item(it: RigidBody3D, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var xf := t * it.global_transform
	var lv := t.basis * it.linear_velocity
	var av := t.basis * it.angular_velocity
	PhysicsServer3D.body_set_state(it.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	it.global_transform = xf
	it.linear_velocity = lv
	it.angular_velocity = av
	_note("item", int(it.item_id), s, to_pocket)


func _note(what: String, id: int, s: Dictionary, to_pocket: bool) -> void:
	crossings.append({"what": what, "id": id, "seam": int(s.id), "to_pocket": to_pocket,
			"time": float(game.world_time) if game != null else 0.0})
	if crossings.size() > 64:
		crossings.pop_front()


# =========================================================================
# the space's own air: fog tuned per pocket, blended in away from the entrances
# =========================================================================

## Environment values each pocket blends toward, deeper than a few metres inside it.
const AIR := {
	"factory": {"fog_depth_begin": 14.0, "fog_depth_end": 78.0, "fog_density": 0.5, "volumetric_fog_density": 0.03,
			"ambient_light_energy": 0.13, "ambient_light_color": Color(0.26, 0.55, 0.44)},
	"restaurant": {"fog_depth_begin": 16.0, "fog_depth_end": 60.0, "fog_density": 0.35, "volumetric_fog_density": 0.016,
			"ambient_light_energy": 0.3, "ambient_light_color": Color(0.62, 0.46, 0.34)},
}
var _air_base := {}
var _air_env: Environment = null
var _air_k := 0.0


## 0 in the hospital, in an entrance stub and near its opening; 1 well inside the space.
func air_factor(p: Vector3) -> float:
	if pocket.is_empty() or not in_pocket(p):
		return 0.0
	var nearest := INF
	for s in seams:
		var l := Stub.to_local(s.xp, p)
		if l.x > -1.5 and l.x < float(s.w) + 1.5 and l.z > -1.2 and l.z < float(s.d) + 1.0:
			return 0.0
		nearest = minf(nearest, Vector2(p.x - s.opening.x, p.z - s.opening.z).length())
	return smoothstep(3.0, 14.0, nearest)


func _blend_environment(k: float) -> void:
	if k <= 0.0 and _air_k <= 0.0:
		return
	if _air_env == null or not is_instance_valid(_air_env):
		var we := get_tree().root.find_child("LookEnvironment", true, false) as WorldEnvironment if is_inside_tree() else null
		if we == null or we.environment == null:
			return
		_air_env = we.environment
	if absf(k - _air_k) < 0.002 and k > 0.0:
		return
	if _air_k <= 0.0:
		_air_base = {}
		for key in AIR.factory.keys():
			_air_base[key] = _air_env.get(key)
	_air_k = k
	var target: Dictionary = AIR.get(String(pocket.get("kind", "")), {})
	for key in _air_base.keys():
		var base = _air_base[key]
		var want = target.get(key, base)
		if base is Color:
			_air_env.set(key, (base as Color).lerp(want, k))
		else:
			_air_env.set(key, lerpf(float(base), float(want), k))


# =========================================================================
# mirrors: someone walking through a seam ahead of you does not vanish
# =========================================================================

## Players and monsters within MIRROR_REACH of a seam are also drawn in the other copy of the stub:
## every visible MeshInstance3D under them gets a RenderingServer instance with the same mesh,
## materials and skeleton, placed through the seam transform. Visual only; nothing else sees it
## except Perception (mirror_points), so a watched Night Nurse past a seam still freezes.
const MIRROR_REACH := 8.0
var _mirrors := {}   # key -> {src: Node3D, t: Transform3D, parts: [[MeshInstance3D, RID]]}


func _update_ghosts() -> void:
	var want := {}
	var viewer: Node = game.viewed_player() if game.has_method("viewed_player") else null
	var bodies: Array = []
	for p in game.players.values():
		if is_instance_valid(p) and p != viewer and p.alive and p.body_visual != null and p.body_visual.visible:
			bodies.append([p, p.body_visual, "p%d" % int(p.peer_id)])
	for m in game.monsters.values():
		if is_instance_valid(m) and m.model != null:
			bodies.append([m, m.model, "m%d" % int(m.monster_id)])
	for b in bodies:
		var pos: Vector3 = (b[0] as Node3D).global_position
		for s in seams:
			for from_h in [true, false]:
				# Only inside the stub (its mirror must land inside the other copy of the stub, never out
				# in the pocket or the hospital hallway).
				if not _in_stub(s, pos, from_h):
					continue
				want["%s|%d|%s" % [b[2], int(s.id), str(from_h)]] = [b[1], s.t if from_h else s.t_inv]
				# A teammate's flashlight lights the other copy too (the hospital's layers from the
				# pocket side, only the copy's layer from the hospital side).
				var fl = (b[0] as Node).get("flashlight")
				if fl != null and (fl as Light3D).is_visible_in_tree():
					want["%s|%d|%s|light" % [b[2], int(s.id), str(from_h)]] = [fl, s.t if from_h else s.t_inv, from_h]
	for key in _mirrors.keys():
		if not want.has(key) or not is_instance_valid(_mirrors[key].src):
			_free_mirror(_mirrors[key])
			_mirrors.erase(key)
	for key in want.keys():
		if not _mirrors.has(key):
			if want[key].size() > 2:
				_mirrors[key] = _make_light_mirror(want[key][0], want[key][1], bool(want[key][2]))
			else:
				_mirrors[key] = _make_mirror(want[key][0], want[key][1])
		else:
			_mirrors[key].t = want[key][1]


func _make_light_mirror(src: SpotLight3D, t: Transform3D, into_pocket_copy: bool) -> Dictionary:
	var l := SpotLight3D.new()
	for prop in ["light_color", "light_energy", "spot_range", "spot_angle", "spot_angle_attenuation", "spot_attenuation",
			"shadow_enabled", "shadow_bias", "shadow_normal_bias", "light_volumetric_fog_energy"]:
		l.set(prop, src.get(prop))
	l.light_cull_mask = (src.light_cull_mask & ~(1 << Stub.POCKET_LAYER_BIT)) if into_pocket_copy else (src.light_cull_mask & ~(1 << Stub.COPY_LAYER_BIT))
	add_child(l)
	l.global_transform = t * src.global_transform
	return {"src": src, "t": t, "parts": [], "light": l}


func _process_mirrors() -> void:
	for key in _mirrors.keys():
		var e: Dictionary = _mirrors[key]
		if not is_instance_valid(e.src):
			continue
		var t: Transform3D = e.t
		if e.has("light"):
			var l: SpotLight3D = e.light
			l.global_transform = t * (e.src as Node3D).global_transform
			l.visible = (e.src as Node3D).is_visible_in_tree()
			continue
		for part in e.parts:
			var mi: MeshInstance3D = part[0]
			if not is_instance_valid(mi):
				continue
			RenderingServer.instance_set_visible(part[1], mi.is_visible_in_tree())
			RenderingServer.instance_set_transform(part[1], t * mi.global_transform)


func _make_mirror(src: Node3D, t: Transform3D) -> Dictionary:
	var parts: Array = []
	var scenario := src.get_world_3d().scenario
	var meshes: Array = src.find_children("*", "MeshInstance3D", true, false)
	if src is MeshInstance3D:
		meshes.append(src)
	for mi: MeshInstance3D in meshes:
		if mi.mesh == null:
			continue
		var rid := RenderingServer.instance_create2(mi.mesh.get_rid(), scenario)
		var skin := mi.get_skin_reference()
		if skin != null:
			RenderingServer.instance_attach_skeleton(rid, skin.get_skeleton())
		if mi.material_override != null:
			RenderingServer.instance_geometry_set_material_override(rid, mi.material_override.get_rid())
		if mi.material_overlay != null:
			RenderingServer.instance_geometry_set_material_overlay(rid, mi.material_overlay.get_rid())
		for i in mi.get_surface_override_material_count():
			var sm := mi.get_surface_override_material(i)
			if sm != null:
				RenderingServer.instance_set_surface_override_material(rid, i, sm.get_rid())
		RenderingServer.instance_set_layer_mask(rid, mi.layers)
		RenderingServer.instance_geometry_set_cast_shadows_setting(rid, RenderingServer.SHADOW_CASTING_SETTING_ON if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else RenderingServer.SHADOW_CASTING_SETTING_OFF)
		RenderingServer.instance_set_transform(rid, t * mi.global_transform)
		parts.append([mi, rid])
	return {"src": src, "t": t, "parts": parts}


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_job = {}
	_steps = []
	for e in _mirrors.values():
		_free_mirror(e)
	_mirrors.clear()
	# Detached nodes are nobody else's to free.
	while not _trash.is_empty():
		var n = _trash.pop_back()
		if is_instance_valid(n):
			(n as Node).free()


func _free_mirror(e: Dictionary) -> void:
	if e.has("light") and is_instance_valid(e.light):
		(e.light as Node).queue_free()
	for part in e.parts:
		RenderingServer.free_rid(part[1])


## Perception: world points of anything past a seam, as they appear in the other copy (a watcher
## there sees the mirror, so it counts as seen).
func mirror_points(points: Array) -> Array:
	var out: Array = []
	if seams.is_empty():
		return out
	for p: Vector3 in points:
		for s in seams:
			if _in_stub(s, p, true):
				out.append((s.t as Transform3D) * p)
			elif _in_stub(s, p, false):
				out.append((s.t_inv as Transform3D) * p)
	return out


## Inside a stub's corridors in one copy (with half a tile of slack past the walls, not past the
## mouth or the opening).
func _in_stub(s: Dictionary, p: Vector3, hospital_copy: bool) -> bool:
	if not (s.bounds_h if hospital_copy else s.bounds_p).has_point(Vector2(p.x, p.z)):
		return false
	var l0: Vector3 = (s.xh_inv if hospital_copy else s.xp_inv) * p
	var sx := l0.x / Stub.T
	var tz := l0.z / Stub.T
	return sx > -0.5 and sx < float(s.w) + 0.5 and tz > -0.3 and tz < float(s.d) + 0.5 and l0.y > -2.0 and l0.y < C.WALL_H + 1.0
