extends Node
## The wings behind the loading gates. `game.wing_loader`, child "WingLoader" of Game, every machine.
##
## A run keeps its entrance building and neutral area. The wings are rebuilt for every shift from
## that shift's wing seed (MapGen.wing_seed_for(run seed, generation)): the host starts it when the
## next shift's lobby begins (game._to_next_shift), clients follow the replicated generation ("wg").
## The gates are shut and locked the whole time (scripts/doors/doors.gd locks them outside a shift
## and while `wings_ready` is false), so nobody can be inside:
##
##   1. evict   (host) anyone still in a wing is put in the entrance hall in front of that wing's
##              gate (a reliable "dr_evict" to a client, which owns its position); items left in
##              the wings are gone (the guide goes back to its lectern).
##   2. tear    the old wings leave level_info at once (containers, lights, anchors, spawns, doors),
##      down    `wings_torn_down` fires (POCKETS HOOK: extra per-shift wing content tears down here)
##              and their nodes are freed a few at a time.
##   3. data    MapGen.generate, HospitalBuilder.prepare (meshes as arrays, furniture buffers, sign
##              and light lists) and the navigation bake run on a WorkerThreadPool task.
##   4. nodes   HospitalBuilder.commit_steps run within FRAME_BUDGET_MS per frame.
##   5. finish  level_info gets the new wings, the navigation mesh is swapped, fixtures get their
##              flicker, doors register, `wings_ready` turns true and `wings_built(info, wing_seed,
##              generation)` fires (POCKETS HOOK: extra per-shift wing content builds here; anything
##              in `extra_builders` with build_wings(info, wing_seed, generation) / teardown_wings()
##              is called too).
##
## Clock-in waits for `wings_ready` (game.clock_in_pending, the gates' amber "unlocking" lamps).

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")

signal wings_torn_down
signal wings_built(info: Dictionary, wing_seed: int, generation: int)

## Main-thread work per frame while building, milliseconds.
const FRAME_BUDGET_MS := 5.0

var game: Node = null
## The wing layout the level has, or is building.
var generation := 1
## The wings exist and match `generation`.
var wings_ready := true
var busy := false
## Client: the generation the next full level build should use (from the snapshot).
var next_generation := -1
## Objects with build_wings(info, wing_seed, generation) and teardown_wings() (POCKETS HOOK).
var extra_builders: Array = []

## Measurements of the last rebuild: frames, the longest frame of main-thread work (ms), the
## wall time (ms), the thread's time (ms).
var stats := {}

var _task := -1
var _job := {}
var _steps: Array = []
var _step_i := 0
var _teardown: Array = []
var _started_ms := 0
var _old_root: Node3D = null
var _wings_root: Node3D = null


func setup(g: Node) -> void:
	game = g


## Which wing generation a full level build should lay out for this shift.
func generation_for_build(shift: int) -> int:
	cancel()
	var gn := shift
	if next_generation > 0:
		gn = next_generation
		next_generation = -1
	generation = gn
	wings_ready = true
	return gn


## A full level was just built (game._build_level): its wings are current.
func on_level_built(info: Dictionary) -> void:
	wings_ready = true
	busy = false
	_wings_root = info.get("wings_root")
	if _wings_root != null:
		_notify_built(info)   # a hospital's wings (not the dev room or the fallback ward)


## Stop a rebuild in progress (a new level replaces everything anyway).
func cancel() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_job = {}
	_steps = []
	_step_i = 0
	for n in _teardown:
		if is_instance_valid(n):
			n.free()
	_teardown = []
	busy = false


## Quitting in the middle of a rebuild: wait for the thread and free the old wings still detached
## (nodes out of the tree are nobody else's to free; left alone they outlive the renderer).
func _exit_tree() -> void:
	cancel()


func has_wings() -> bool:
	return game != null and game.level != null and is_instance_valid(game.level) \
			and game.level_info.has("wings_root") and not game.dev_mode


# =========================================================================
# rebuilding
# =========================================================================

## Tear the wings down and build generation `gn`. Host: from _to_next_shift (and the dev panel);
## clients: when the snapshot's "wg" changes.
func regenerate(gn: int) -> void:
	if not has_wings():
		generation = gn
		return
	cancel()
	# The thread only reads the furniture mesh cache: every kind must be built before it starts.
	HB.warm_parts()
	generation = gn
	wings_ready = false
	busy = true
	_started_ms = Time.get_ticks_msec()
	stats = {"frames": 0, "max_frame_ms": 0.0, "generation": gn}
	if game.is_host():
		evict_players()
		_clear_wing_items()
		_clear_wing_monsters()
	else:
		_evict_local()
	_tear_down()
	var seed_value: int = game.seed_value
	var wing_seed := MG.wing_seed_for(seed_value, gn)
	var job := {"seed": seed_value, "wing_seed": wing_seed, "gn": gn}
	_job = job
	_task = WorkerThreadPool.add_task(func(): _thread_build(job), false, "wings")


## Worker thread: everything that is only data.
static func _thread_build(job: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var gen: Dictionary = MG.generate(int(job.seed), int(job.wing_seed))
	job["gen"] = gen
	job["prep"] = HB.prepare(gen, HB.PART_WINGS)
	job["nav"] = HB.bake_nav(gen)
	job["thread_ms"] = Time.get_ticks_msec() - t0


func _tear_down() -> void:
	var info: Dictionary = game.level_info
	var base: Dictionary = info.get("base_part", {})
	game.doors.unregister_wings()
	if not base.is_empty():
		info["containers"] = (base.out.containers as Array).duplicate()
		info["lights"] = (base.out.lights as Array).duplicate()
		info["loose_anchors"] = (base.out.anchors as Array).duplicate()
	info["tool_spawns"] = []
	info["monster_spawns"] = []
	wings_torn_down.emit()
	for b in extra_builders:
		if b != null and is_instance_valid(b) and b.has_method("teardown_wings"):
			b.teardown_wings()
	_old_root = info.get("wings_root")
	var fresh := Node3D.new()
	fresh.name = "WingsBuilding"
	game.level.add_child(fresh)
	_wings_root = fresh
	info["wings_root"] = fresh
	if _old_root != null and is_instance_valid(_old_root):
		# Out of the tree now (one cheap call), freed in pieces over the next frames.
		game.level.remove_child(_old_root)
		_teardown = [_old_root]
		for c in _old_root.get_children():
			_old_root.remove_child(c)
			_teardown.append(c)
			for gc in c.get_children():
				c.remove_child(gc)
				_teardown.append(gc)
	_old_root = null


## Finish a rebuild right now (tools, and begin_shift which cannot wait).
func finish_now() -> void:
	if not busy:
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_steps = _all_steps()
		_step_i = 0
	for n in _teardown:
		if is_instance_valid(n):
			n.free()
	_teardown = []
	while _step_i < _steps.size():
		_steps[_step_i].call()
		_step_i += 1
	_finish()


func _process(_delta: float) -> void:
	if not busy:
		return
	var t0 := Time.get_ticks_usec()
	var budget := int(FRAME_BUDGET_MS * 1000.0)
	stats.frames = int(stats.frames) + 1
	# Free the old wings a few nodes at a time.
	while not _teardown.is_empty() and Time.get_ticks_usec() - t0 < budget:
		var n = _teardown.pop_back()
		if is_instance_valid(n):
			n.free()
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			_note_frame(t0)
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		stats["thread_ms"] = int(_job.get("thread_ms", 0))
		_steps = _all_steps()
		_step_i = 0
	if not _teardown.is_empty():
		_note_frame(t0)
		return
	while _step_i < _steps.size() and Time.get_ticks_usec() - t0 < budget:
		var s0 := Time.get_ticks_usec()
		_steps[_step_i].call()
		var ms := float(Time.get_ticks_usec() - s0) / 1000.0
		var labels: Array = _job.prep.get("step_labels", []) if not _job.is_empty() else []
		var label: String = labels[_step_i] if _step_i < labels.size() else "flicker"
		if ms > float(stats.get("slowest_step_ms", 0.0)):
			stats["slowest_step_ms"] = ms
			stats["slowest_step"] = label
		# Per kind of step: [count, total ms, worst ms].
		var by: Dictionary = stats.get("steps", {})
		var e: Array = by.get(label, [0, 0.0, 0.0])
		by[label] = [int(e[0]) + 1, snappedf(float(e[1]) + ms, 0.1), snappedf(maxf(float(e[2]), ms), 0.1)]
		stats["steps"] = by
		_step_i += 1
	if _step_i >= _steps.size():
		_finish()
	_note_frame(t0)


## The builder's steps, then the fixtures' flicker controllers a dozen at a time (game.gd's
## _attach_light_flicker does the same for a whole level at once).
func _all_steps() -> Array:
	var steps: Array = HB.commit_steps(_job.prep, _wings_root)
	var prep: Dictionary = _job.prep
	var count := (prep.lights as Array).size()
	for i in range(0, count, 12):
		var from := i
		steps.append(func():
			var Flicker: GDScript = load("res://scripts/light_flicker.gd")
			var list: Array = prep.out.lights
			for k in range(from, mini(from + 12, list.size())):
				var node = list[k].get("node")
				if node == null or not is_instance_valid(node):
					continue
				for light in (node as Node).find_children("*", "Light3D", true, false):
					if not light.is_in_group("fixture"):
						continue
					light.distance_fade_enabled = true
					light.distance_fade_begin = 16.0
					light.distance_fade_length = 6.0
					light.add_child(Flicker.new()))
	return steps


func _note_frame(t0: int) -> void:
	stats.max_frame_ms = maxf(float(stats.get("max_frame_ms", 0.0)), float(Time.get_ticks_usec() - t0) / 1000.0)


func _finish() -> void:
	var info: Dictionary = game.level_info
	var gen: Dictionary = _job.gen
	var prep: Dictionary = _job.prep
	var base: Dictionary = info.get("base_part", {})
	var f0 := Time.get_ticks_usec()
	HB.finish_info(gen, info, base, prep)
	var f1 := Time.get_ticks_usec()
	var region: NavigationRegion3D = info.get("nav_region")
	if region != null and is_instance_valid(region):
		region.navigation_mesh = _job.nav
	var f2 := Time.get_ticks_usec()
	_wings_root.name = "Wings"
	info["wings_root"] = _wings_root
	info["wing_gen"] = generation
	var f3 := Time.get_ticks_usec()
	game.doors.register(prep.out.doors)
	stats["finish_ms"] = [snappedf((f1 - f0) / 1000.0, 0.1), snappedf((f2 - f1) / 1000.0, 0.1),
			snappedf((f3 - f2) / 1000.0, 0.1), snappedf((Time.get_ticks_usec() - f3) / 1000.0, 0.1)]
	busy = false
	wings_ready = true
	stats["wall_ms"] = Time.get_ticks_msec() - _started_ms
	_job = {}
	_steps = []
	print("[wings] generation %d built: %d frames, %d ms wall, %d ms on the thread, longest frame of work %.1f ms" % [
		generation, int(stats.frames), int(stats.wall_ms), int(stats.get("thread_ms", 0)), float(stats.max_frame_ms)])
	_notify_built(info)
	# A rebuild during a shift (the dev panel): the new wings get their loot and monsters now.
	if game.is_host() and game.phase == game.Phase.SHIFT:
		game.spawn_loot()
		game._spawn_monsters()


func _notify_built(info: Dictionary) -> void:
	var ws := int(info.get("wing_seed", 0))
	wings_built.emit(info, ws, generation)
	for b in extra_builders:
		if b != null and is_instance_valid(b) and b.has_method("build_wings"):
			b.build_wings(info, ws, generation)


# =========================================================================
# nobody inside
# =========================================================================

## Where someone standing in wing `wing_id` is put: in the entrance hall in front of its gate.
func gate_front(wing_id: String, slot: int) -> Vector3:
	for d in game.doors.doors.values():
		if d != null and is_instance_valid(d) and d.kind == "gate" and String(d.data.get("wing", "")) == wing_id:
			var lateral: float = (float(slot % 3) - 1.0) * 0.9
			return d.global_position + d.normal * (2.2 + 0.8 * float(slot / 3)) + d.along * lateral
	var spots: Array = game.spawn_points()
	return spots[slot % maxi(1, spots.size())] if not spots.is_empty() else Vector3.ZERO


func _wing_zone(p: Vector3) -> String:
	var z := HB.zone_of(game.level_info, p)
	return "" if z == "entrance" or z == "neutral" else z


## Host: every player (and bot) inside a wing goes to the entrance hall in front of its gate.
func evict_players() -> void:
	var slot := 0
	for p in game.players.values():
		if p == null or not is_instance_valid(p):
			continue
		var z := _wing_zone(p.global_position)
		if z == "":
			continue
		var to := gate_front(z, slot)
		slot += 1
		if p.is_local or bool(p.get("is_bot")) or not Net.active:
			p.teleport(to)
		else:
			game._event.rpc_id(p.peer_id, "dr_evict", {"pos": to})
		game.tell(p, "The night staff walked you out of the wing. It is being cleaned for the next shift.", 4.0)


## Client: if my own player is still in a wing when it goes, step out (the host's event may lag).
func _evict_local() -> void:
	var me = game.local_player()
	if me == null:
		return
	var z := _wing_zone(me.global_position)
	if z == "":
		return
	me.teleport(gate_front(z, 0))


## Host: monsters still in the wings (only a rebuild during a shift, from the dev panel, has any)
## leave quietly with them.
func _clear_wing_monsters() -> void:
	for id in game.monsters.keys():
		var m = game.monsters[id]
		if m == null or not is_instance_valid(m) or _wing_zone(m.global_position) == "":
			continue
		game.monsters.erase(id)
		if game.combat != null and game.combat.has_method("on_monster_removed"):
			game.combat.on_monster_removed(m)
		m.queue_free()


## Host: what was left lying in the wings (and in their containers) is gone with them.
func _clear_wing_items() -> void:
	var guide_gone := false
	for id in game.world_items.keys():
		var it = game.world_items[id]
		if it == null or not is_instance_valid(it):
			game.world_items.erase(id)
			continue
		if _wing_zone(it.global_position) == "":
			continue
		if String(it.kind) == "guide":
			guide_gone = true
		it.queue_free()
		game.world_items.erase(id)
		game._shift_item_ids.erase(id)
	if guide_gone:
		game.call_deferred("_spawn_guide")
