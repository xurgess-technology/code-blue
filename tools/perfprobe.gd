extends Node
## Frame-time probe across the situations most likely to lag, with vsync off so the numbers
## are the real cost rather than the monitor's refresh rate.
##
##   godot --path . tools/perfprobe.tscn -- [--seed=N] [--frames=N] [--shift=N] [--quality=0,1,2]
##   ... -- --hands   (what the first-person hands and teammates holding things cost)
##
## For each scenario and quality preset it prints average fps, the 1% low (99th percentile
## frame time), the worst frame, script time for physics and process, draw calls, and node count.

const WARMUP := 50

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _frames := 240
var _shift := 1
var _qualities := [1, 0, 2]
var _rows: Array = []
var _ab := false
var _tune := false
var _hitch := false
var _orscreen := false
var _models := false
var _brains := false   # SWEEP 3 HOOK (brains)
var _doors := false    # DOORS HOOK
var _hands := false    # HANDS HOOK
var _spikes: Array = []
var _phase_label := ""
var _phase_stats := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"seed": _seed = int(v)
			"frames": _frames = int(v)
			"shift": _shift = int(v)
			"ab": _ab = true
			"tune": _tune = true
			"hitch": _hitch = true
			"orscreen": _orscreen = true
			"models": _models = true
			"brains": _brains = true
			"doors": _doors = true
			"hands": _hands = true
			# SEAL HOOK: build the procedural seal instead of the Blender model (A/B the patient's cost).
			"seal-procedural": (load("res://scripts/patients/seal_model_builder.gd") as GDScript).set("procedural_only", true)
			"quality":
				_qualities = []
				for q in v.split(","):
					_qualities.append(int(q))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Probe")
	game.start_session(_seed)
	if _shift > 1:
		game.start_lobby(_seed, _shift)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	print("[perf] gpu=%s  window=%s  shift=%d" % [RenderingServer.get_video_adapter_name(), str(get_viewport().get_visible_rect().size), _shift])
	# Let the one-time warmup finish (it runs behind a cover) before measuring anything else.
	if not _hitch:
		while game.get_parent().has_node("WarmupCover"):
			await get_tree().process_frame
		for i in 30:
			await get_tree().process_frame

	if _ab:
		await _run_ab()
		return
	if _tune:
		await _run_tune()
		return
	if _hitch:
		await _run_hitch()
		return
	if _orscreen:
		await _run_orscreen()
		return
	if _models:
		await _run_models()
		return
	if _hands:
		await _run_hands()
		return
	if _brains:
		await _run_brains()
		return
	if _doors:
		await _run_doors()
		return
	var scenarios := [
		{"name": "lobby clock-in room", "setup": _lobby},
		{"name": "corridor, long sightline", "setup": _corridor},
		{"name": "pharmacy, containers open", "setup": _containers},
		{"name": "OR, patient + stocked shelf", "setup": _or_view},
		{"name": "OR, the seal close up", "setup": _or_seal},  # SEAL HOOK
		{"name": "operating: bone saw, bloody", "setup": _operating_saw},
		# INVENTORY HOOK: the same view of the gold pile empty and with 500 bars.
		{"name": "gold pile, 0 bars", "setup": func(): await _pile_view(0)},
		{"name": "gold pile, 500 bars", "setup": func(): await _pile_view(500)},
		{"name": "neutral area outside", "setup": _neutral},  # HOSPITAL HOOK: sweep 2 neutral area
	]
	for q in _qualities:
		main.set_quality(q, false)
		for s in scenarios:
			await s.setup.call()
			await _measure(s.name, q)
	print("[perf] ============================================================================")
	print("[perf] %-30s q  avg fps  1%%low fps  worst ms  phys ms  proc ms  draws  nodes" % "scenario")
	for r in _rows:
		print("[perf] %-30s %d  %7.0f  %9.0f  %8.1f  %7.2f  %7.2f  %5d  %5d" % [r.name, r.q, r.fps, r.low_fps, r.worst, r.phys, r.proc, r.draws, r.nodes])
	get_tree().quit(0)


func _look(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y - C.EYE_H, Vector2(d.x, d.z).length()), -1.0, 1.0)


func _lobby() -> void:
	if game.phase != Game.Phase.LOBBY:
		return
	_look(game.spawn_points()[0], game.clock_pos())


func _ensure_shift() -> void:
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
		await get_tree().process_frame
	# Keep the monsters awake but away from the camera so they cost what they cost in play.
	for m in game.monsters.values():
		m.calm = 0.0


func _corridor() -> void:
	await _ensure_shift()
	var best_len := -1.0
	var best_from := game.table_pos()
	var best_dir := Vector3.FORWARD
	var space := bot.get_world_3d().direct_space_state
	for spot in game.level_info.get("monster_spawns", []):
		var eye: Vector3 = spot + Vector3.UP * C.EYE_H
		for i in 12:
			var dir := Vector3(cos(TAU * i / 12.0), 0, sin(TAU * i / 12.0))
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 45.0)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			var reach: float = 45.0 if hit.is_empty() else eye.distance_to(hit.position)
			if reach > best_len:
				best_len = reach
				best_from = spot
				best_dir = dir
	_look(best_from, best_from + best_dir * 20.0 + Vector3.UP * C.EYE_H)


func _containers() -> void:
	await _ensure_shift()
	var cts: Array = game.level_info.get("containers", [])
	var target: Dictionary = {}
	for e in cts:
		if String(e.get("room_kind", "")) == "pharmacy":
			target = e
			break
	if target.is_empty() and not cts.is_empty():
		target = cts[0]
	if target.is_empty():
		return
	var centre: Vector3 = target.get("position", Vector3.ZERO)
	for e in cts:
		var n = e.get("node")
		if n != null and is_instance_valid(n) and (e.get("position", Vector3.ZERO) as Vector3).distance_to(centre) < 8.0:
			n.set_open(true, false)
	var node: Node3D = target.get("node")
	var out := node.global_basis.z.normalized() if node != null else Vector3.BACK
	_look(centre + out * 3.2, centre + Vector3.UP * 1.0)


func _or_view() -> void:
	await _ensure_shift()
	for kind in Items.SURGICAL:
		game.shelf[kind] = 3 if Items.is_consumable(kind) else 1
	game.shelf_node.show_stock(game.shelf)
	var t := game.table_pos()
	_look(t + Vector3(0.8, 0, 3.0), t + Vector3.UP * 1.0)


## SEAL HOOK: the seal (Blender model unless --seal-procedural) on the table, idle and breathing, from
## a player standing beside it.
func _or_seal() -> void:
	await _ensure_shift()
	game.case = {"patient_id": "seal", "ailment_id": "amputation", "step_index": 0, "flags": {"sedation": 0.3}}
	game._apply_case_locally()
	var t := game.table_pos()
	_look(t + Vector3(0.9, 0, 1.6), t + Vector3.UP * 0.95)


## INVENTORY HOOK: look at the gold pile (and the sell bin and shop behind it) with `n` bars.
func _pile_view(n: int) -> void:
	if game.surgery.is_local_operating():
		game.surgery.end(bot)
	game.gold_bars = n
	for i in 30:
		await get_tree().process_frame
	var pile: Node3D = game.economy.pile
	if pile == null:
		return
	var p := pile.global_position
	var to_clock: Vector3 = game.clock_pos() - p
	to_clock.y = 0.0
	var from := game._floor_at(p + to_clock.normalized() * minf(3.5, to_clock.length()))
	_look(from, p + Vector3.UP * 1.6)


## HOSPITAL HOOK: the parking lot outside the main doors, looking back at the building across
## the lot (street lights, cars, the van). Skipped on levels without a neutral area.
func _neutral() -> void:
	var n: Dictionary = game.level_info.get("neutral", {})
	if n.is_empty():
		return
	if game.surgery.camera() != null:
		game.surgery.end(bot)
	var gold: Vector3 = n.gold_pile.position
	var ent: Vector3 = game.level_info.entrance.position
	_look(gold + (gold - ent).normalized() * 8.0 + Vector3(-5.0, 0, 0), ent + Vector3(0, 2.0, 0))


## The heaviest thing surgery does: the saw with a weak tourniquet (blood decals, particles),
## with the bot actually operating through the real framework and camera.
func _operating_saw() -> void:
	await _ensure_shift()
	game.case = {"patient_id": "seal", "ailment_id": "amputation", "step_index": 2, "flags": {"sedation": 1.0, "tourniquet": 0.3}}
	game._apply_case_locally()
	game.shelf["bone_saw"] = 1
	game.shelf_node.show_stock(game.shelf)
	_look(game.table_pos() + Vector3(0, 0, 1.6), game.table_pos() + Vector3.UP * 1.0)
	for i in 5:
		await get_tree().process_frame
	game.surgery.bot_skill = 0.4
	game.surgery.begin(bot)
	for i in 60:
		await get_tree().process_frame


func _measure(label: String, q: int) -> void:
	for i in WARMUP:
		await get_tree().process_frame
	var times: Array[float] = []
	var phys := 0.0
	var proc := 0.0
	var draws := 0
	for i in _frames:
		await get_tree().process_frame
		times.append(get_process_delta_time() * 1000.0)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		draws = maxi(draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		# Sweep the view a little so we do not measure one lucky angle.
		bot.bot_yaw += sin(i * 0.05) * 0.012
	var total := 0.0
	for t in times:
		total += t
	var sorted := times.duplicate()
	sorted.sort()
	var p99: float = sorted[int(sorted.size() * 0.99) - 1]
	var avg := total / times.size()
	var row := {
		"name": label, "q": q, "fps": 1000.0 / avg, "low_fps": 1000.0 / p99, "worst": sorted[-1],
		"phys": phys / _frames, "proc": proc / _frames, "draws": draws,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
	}
	_rows.append(row)
	print("[perf] q%d %-30s avg %.0f fps, 1%% low %.0f fps, worst %.1f ms, draws %d" % [q, label, row.fps, row.low_fps, row.worst, draws])


## Which part of the frame costs the most in the worst scenes: toggle one thing at a time.
func _run_ab() -> void:
	main.set_quality(1, false)
	var env: Environment = null
	for n in main.find_children("*", "WorldEnvironment", true, false):
		env = n.environment
	var tests := [
		{"name": "baseline", "on": func(): pass, "off": func(): pass},
		{"name": "no volumetric fog", "on": func(): env.volumetric_fog_enabled = false, "off": func(): env.volumetric_fog_enabled = true},
		{"name": "no SSAO/SSIL", "on": func(): env.ssao_enabled = false; env.ssil_enabled = false, "off": func(): env.ssao_enabled = true; env.ssil_enabled = false},
		{"name": "no glow", "on": func(): env.glow_enabled = false, "off": func(): env.glow_enabled = true},
		{"name": "flashlight no shadow", "on": func(): bot.flashlight.shadow_enabled = false, "off": func(): bot.flashlight.shadow_enabled = true},
		{"name": "flashlight off", "on": func(): bot.set_flashlight(false), "off": func(): bot.set_flashlight(true)},
		{"name": "all omni lights hidden", "on": func(): _omni(false), "off": func(): _omni(true)},
		{"name": "post layer hidden", "on": func(): main.post.visible = false, "off": func(): main.post.visible = true},
		{"name": "render scale 0.5", "on": func(): get_viewport().scaling_3d_scale = 0.5, "off": func(): main.set_quality(1, false)},
		# INVENTORY HOOK: what the teal / gold rims and the loot cost.
		{"name": "no item rims", "on": func(): _rims(false), "off": func(): _rims(true)},
		{"name": "loot hidden", "on": func(): _loot(false), "off": func(): _loot(true)},
		# ORSCREEN HOOK: what the OR wall monitor costs (hidden and not refreshing).
		{"name": "no OR screen", "on": func(): game.or_screen.set_enabled(false), "off": func(): game.or_screen.set_enabled(true)},
	]
	for scen in [{"name": "OR", "setup": _or_view}, {"name": "lobby", "setup": _lobby}, {"name": "corridor", "setup": _corridor}]:
		await scen.setup.call()
		for t in tests:
			t.on.call()
			await _measure("%s: %s" % [scen.name, t.name], 1)
			t.off.call()
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-40s avg %4.0f fps  1%%low %4.0f  draws %d" % [r.name, r.fps, r.low_fps, r.draws])
	get_tree().quit(0)


## ORSCREEN HOOK (--orscreen): the OR from across the room and the monitor close up, each with the
## monitor on and off, at the chosen qualities (default medium).
func _run_orscreen() -> void:
	var qs: Array = _qualities if _qualities != [1, 0, 2] else [1]
	for q in qs:
		main.set_quality(q, false)
		for scen in [{"name": "OR view", "setup": _or_view}, {"name": "OR screen close", "setup": _screen_close}]:
			await scen.setup.call()
			game.or_screen.set_enabled(true)
			await _measure("%s, screen on" % scen.name, q)
			game.or_screen.set_enabled(false)
			await _measure("%s, screen off" % scen.name, q)
			game.or_screen.set_enabled(true)
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] q%d %-32s avg %4.0f fps  1%%low %4.0f  worst %.1f ms  draws %d" % [r.q, r.name, r.fps, r.low_fps, r.worst, r.draws])
	get_tree().quit(0)


## SWEEP 3 HOOK (brains, --brains): what Echo and Hive Eyes cost at medium. The pharmacy with its
## containers open and the long corridor, each with nothing, Echo at level 3 (30 m, as many outlines
## as it allows, held on for the whole measurement) and Hive Eyes through a Walk-In standing there;
## plus five brains on the floor in view. Twice, so the noise shows.
## DOORS HOOK (`-- --doors`): a hallway of doors, the longest corridor and the OR, each with every
## door shut, every door open (the automatic ones held open), and shut without the doors' occluders.
func _run_doors() -> void:
	main.set_quality(1, false)
	var ds: Node = game.doors
	var hide_doors := func(hidden: bool) -> void:
		for d in ds.doors.values():
			d.visible = not hidden
			if d.occluder != null:
				d.occluder.visible = not hidden and d.is_closed()
	var set_doors := func(open: bool, occluders: bool) -> void:
		ds.set_all(open)
		for d in ds.doors.values():
			if d.is_automatic():
				ds._hold_open[d.door_id] = 9999.0 if open else 0.0
				if not open:
					ds._drive(d, 0.0, 5.0)
		for i in 90:
			await get_tree().process_frame
		for d in ds.doors.values():
			if d.occluder != null:
				d.occluder.visible = occluders and d.is_closed()
	for pass_i in 2:
		for scen in [{"name": "hallway of doors", "setup": _doors_hallway}, {"name": "corridor", "setup": _corridor}, {"name": "OR", "setup": _or_view}]:
			await scen.setup.call()
			# As before the doors: every door open and hidden (no leaves drawn, no occluders).
			await set_doors.call(true, false)
			hide_doors.call(true)
			await _measure("%s: no doors (as before) %d" % [scen.name, pass_i + 1], 1)
			hide_doors.call(false)
			await set_doors.call(false, true)
			await _measure("%s: doors shut %d" % [scen.name, pass_i + 1], 1)
			await set_doors.call(false, false)
			await _measure("%s: shut, no door occluders %d" % [scen.name, pass_i + 1], 1)
			await set_doors.call(true, true)
			await _measure("%s: doors open %d" % [scen.name, pass_i + 1], 1)
			await set_doors.call(false, true)
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-44s avg %4.0f fps  1%%low %4.0f  worst %5.1f ms  draws %d" % [r.name, r.fps, r.low_fps, r.worst, r.draws])
	get_tree().quit(0)


## Looking along a wing hallway past the most doors in one wall.
func _doors_hallway() -> void:
	await _ensure_shift()
	var best_n := -1
	for d in game.doors.doors.values():
		if not d.is_hinged() or bool(d.data.get("base", false)):
			continue
		var n := 0
		for e in game.doors.doors.values():
			if e == d or not e.is_hinged():
				continue
			var rel: Vector3 = e.global_position - d.global_position
			if absf(rel.dot(d.normal)) < 0.2 and absf(rel.dot(d.along)) < 16.0 and e.normal.dot(d.normal) > 0.9:
				n += 1
		var from: Vector3 = d.global_position + d.normal * 2.0 - d.along * 2.5
		if n > best_n and game._point_is_clear(from):
			best_n = n
			_look(from, d.global_position + d.normal * 0.2 + d.along * 7.0 + Vector3.UP * 1.2)


func _run_brains() -> void:
	main.set_quality(1, false)
	var b: Node = game.brains
	for pass_i in 2:
		for scen in [{"name": "pharmacy", "setup": _containers}, {"name": "corridor", "setup": _corridor}]:
			await scen.setup.call()
			await _measure("%s: baseline %d" % [scen.name, pass_i + 1], 1)
			var t0 := Time.get_ticks_usec()
			b.echo_view.start(bot, bot.global_position, b.echo_radius(3), 60.0)
			print("[perf] %s: Echo start took %.2f ms (%d outlines of %d things)" % [scen.name, (Time.get_ticks_usec() - t0) / 1000.0, b.echo_view.ghosts.size(), b.echo_view.target_count])
			for i in 40:
				await get_tree().process_frame
			await _measure("%s: Echo L3 (%d outlines) %d" % [scen.name, b.echo_view.ghosts.size(), pass_i + 1], 1)
			b.echo_view.stop()
			var wi: Node = b.spawn_walk_in(bot.global_position - bot.global_transform.basis.z * 3.0)
			wi.set_physics_process(false)
			b._hive[bot.peer_id] = [int(wi.monster_id), game.world_time + 600.0]
			b._hive_hp[bot.peer_id] = bot.hp
			bot.hive_view = true
			await _measure("%s: Hive Eyes %d" % [scen.name, pass_i + 1], 1)
			b._end_hive(bot.peer_id, "")
			game.kill_monster(wi)
			for i in 10:
				await get_tree().process_frame
		var placed := []
		var fwd: Vector3 = -bot.global_transform.basis.z
		for i in 5:
			var it: Node = b.spawn_brain("brain_walk_in" if i % 2 == 0 else "brain_discharged", 1.0, bot.global_position + fwd * (1.2 + i * 0.25) + Vector3.UP * 0.5)
			it.bt = game.world_time - i * 50.0
			placed.append(it)
		bot.bot_pitch = -0.5
		await _measure("corridor: 5 brains in view %d" % (pass_i + 1), 1)
		bot.bot_pitch = 0.0
		for it in placed:
			game.world_items.erase(it.item_id)
			it.queue_free()
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-44s avg %4.0f fps  1%%low %4.0f  worst %.1f ms  draws %d" % [r.name, r.fps, r.low_fps, r.worst, r.draws])
	get_tree().quit(0)


## MODELS HOOK (--models): what the loot and paramedic models cost. A room floor with every loot
## kind three times over (63 stacks in view, the teal/gold rims on), the OR with its stocked shelf,
## and the paramedic crew with its gurney in view, at medium: real models, then the old
## primitives, twice, so the noise shows and both see the same machine load.
func _run_models() -> void:
	main.set_quality(1, false)
	var crew_script: GDScript = load("res://scripts/loop/crew.gd")
	# Alternate real models and the old primitives in the same run, twice, so the comparison
	# shares whatever else the machine is doing.
	for pass_i in 4:
		var prim := pass_i % 2 == 1
		ItemModels.primitives_only = prim
		crew_script.set("shapes_only", prim)
		var tag := "%s %d" % ["primitives" if prim else "models", pass_i / 2 + 1]
		await _loot_room()
		await _measure("loot room, 63 stacks (%s)" % tag, 1)
		_clear_probe_loot()
		await _or_view()
		await _measure("OR, patient + shelf (%s)" % tag, 1)
		await _crew_view()
		await _measure("paramedics + gurney (%s)" % tag, 1)
	ItemModels.primitives_only = false
	crew_script.set("shapes_only", false)
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-40s avg %4.0f fps  1%%low %4.0f  worst %5.1f ms  draws %d" % [r.name, r.fps, r.low_fps, r.worst, r.draws])
	get_tree().quit(0)


var _probe_loot: Array = []


func _loot_room() -> void:
	await _ensure_shift()
	if game.surgery.is_local_operating():
		game.surgery.end(bot)
	# The widest clear floor near a wing room: a monster spawn with 4 m free ahead.
	var space := bot.get_world_3d().direct_space_state
	var from: Vector3 = game.table_pos() + Vector3(0, 0, 3)
	var dir := Vector3.FORWARD
	for spot in game.level_info.get("monster_spawns", []):
		var ok := false
		for i in 8:
			var d := Vector3(cos(TAU * i / 8.0), 0, sin(TAU * i / 8.0))
			var q := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 0.5, spot + Vector3.UP * 0.5 + d * 4.5)
			q.collision_mask = C.L_WORLD
			if space.intersect_ray(q).is_empty():
				from = spot
				dir = d
				ok = true
				break
		if ok:
			break
	var side := dir.cross(Vector3.UP)
	var kinds: Array = preload("res://scripts/economy/loot_table.gd").kinds()
	var n := 0
	for rep in 3:
		for k in kinds.size():
			var at: Vector3 = from + dir * (1.4 + rep * 0.9) + side * ((k - kinds.size() * 0.5) * 0.16)
			var it = game._spawn_item(kinds[k], 1, Transform3D(Basis(Vector3.UP, 0.3 * n), game._floor_at(at) + Vector3.UP * 0.02), WorldItem.State.LOOSE)
			_probe_loot.append(it)
			n += 1
	_look(from - dir * 0.6, from + dir * 2.5)


func _clear_probe_loot() -> void:
	for it in _probe_loot:
		if is_instance_valid(it):
			game.world_items.erase(it.item_id)
			it.queue_free()
	_probe_loot.clear()


func _crew_view() -> void:
	var crew: Node3D = (load("res://scripts/loop/crew.gd") as GDScript).create("bob", "gunshot")
	game.get_node("Entities").add_child(crew)
	var t := game.table_pos()
	crew.snap(t + Vector3(0, 0, 4.0), 0.0)
	_look(t + Vector3(2.2, 0, 6.5), t + Vector3(0, 1.0, 4.0))
	get_tree().create_timer(12.0).timeout.connect(crew.queue_free)


func _screen_close() -> void:
	await _ensure_shift()
	var s = game.or_screen
	if not s.mounted():
		return
	var c: Vector3 = s.screen_centre()
	var feet: Vector3 = c + s.screen_normal() * 2.5
	feet.y = game.table_pos().y
	_look(feet, c)


## INVENTORY HOOK: strip / restore the item rim overlays; hide / show loot world items.
func _rims(on: bool) -> void:
	for g in game.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		if not on and gi.material_overlay != null:
			gi.set_meta("perf_overlay", gi.material_overlay)
			gi.material_overlay = null
		elif on and gi.has_meta("perf_overlay"):
			gi.material_overlay = gi.get_meta("perf_overlay")
			gi.remove_meta("perf_overlay")


func _loot(on: bool) -> void:
	for it in game.world_items.values():
		if Items.is_loot(it.kind):
			it.visible = on


func _omni(on: bool) -> void:
	for l in game.find_children("*", "OmniLight3D", true, false):
		l.visible = on


## Candidate medium presets, measured in the scenes that were slowest.
func _run_tune() -> void:
	var env: Environment = null
	for n in main.find_children("*", "WorldEnvironment", true, false):
		env = n.environment
	var vp := get_viewport()
	var configs := [
		{"name": "medium", "apply": func(): main.set_quality(1, false)},
		{"name": "medium, FXAA off", "apply": func(): main.set_quality(1, false); vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED},
		{"name": "medium, SSAO on", "apply": func(): main.set_quality(1, false); env.ssao_enabled = true},
		{"name": "low", "apply": func(): main.set_quality(0, false)},
		{"name": "medium (repeat, shows noise)", "apply": func(): main.set_quality(1, false)},
	]
	for scen in [{"name": "OR", "setup": _or_view}, {"name": "lobby", "setup": _lobby}, {"name": "corridor", "setup": _corridor}]:
		await scen.setup.call()
		for c in configs:
			c.apply.call()
			await _measure("%s: %s" % [scen.name, c.name], 1)
	main.set_quality(1, false)
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-42s avg %4.0f fps  1%%low %4.0f  worst %5.1f ms" % [r.name, r.fps, r.low_fps, r.worst])
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# Hitches: first sightings of everything, counting pipeline compiles per frame.

func _compiles() -> int:
	return int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW)) 		+ int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION))


func _watch(label: String, frames: int) -> void:
	_phase_label = label
	if not _phase_stats.has(label):
		_phase_stats[label] = {"frames": 0, "worst": 0.0, "spikes": 0, "compiles": 0}
	var st: Dictionary = _phase_stats[label]
	var before := _compiles()
	for i in frames:
		var c0 := _compiles()
		await get_tree().process_frame
		var ms := get_process_delta_time() * 1000.0
		var dc := _compiles() - c0
		st.frames += 1
		st.worst = maxf(st.worst, ms)
		if ms > 25.0:
			st.spikes += 1
			_spikes.append("%-34s frame %3d  %6.1f ms  compiles %d" % [label, i, ms, dc])
	st.compiles += _compiles() - before


func _run_hitch() -> void:
	# The menu->lobby transition already happened in _ready. The warmup runs behind its
	# cover during these first frames; spikes there are hidden from the player.
	await _watch("warmup (behind cover)", 30)
	await _watch("lobby: look around", 90)
	bot.bot_yaw += PI
	await _watch("lobby: turn around", 60)
	game.begin_shift()
	await _watch("shift begins", 60)
	await _corridor()
	await _watch("corridor", 90)
	for m in game.monsters.values():
		var p: Vector3 = m.global_position
		_look(p + Vector3(2.5, 0, 0.5), p + Vector3.UP * 1.4)
		await _watch("monster: %s" % m.kind, 60)
	await _containers()
	await _watch("containers open", 90)
	await _or_view()
	await _watch("OR + shelf", 60)
	var steps := [["gunshot", 0, {}], ["gunshot", 1, {"sedation": 1.0}], ["gunshot", 2, {"sedation": 1.0, "bullet_removed": true}],
		["amputation", 1, {"sedation": 1.0}], ["amputation", 2, {"sedation": 1.0, "tourniquet": 0.4}], ["amputation", 3, {"sedation": 1.0, "tourniquet": 0.4, "amputated": true}]]
	for st in steps:
		for kind in Items.SURGICAL:
			game.shelf[kind] = 4
		game.case = {"patient_id": "bob" if st[0] == "gunshot" else "seal", "ailment_id": st[0], "step_index": st[1], "flags": st[2]}
		game._apply_case_locally()
		await _watch("case switch %s/%d" % [st[0], st[1]], 20)
		game.surgery.bot_skill = 0.3
		game.surgery.begin(bot)
		var g: String = Procedures.step(st[0], st[1]).game
		await _watch("operating: %s" % g, 150)
		game.surgery.end(bot)
		await _watch("back from %s" % g, 40)
	print("[perf] ============================================================================")
	print("[perf] spikes over 25 ms:")
	for sp in _spikes:
		print("[perf]   " + sp)
	print("[perf] per phase:")
	var total_spikes := 0
	for k in _phase_stats.keys():
		var st2: Dictionary = _phase_stats[k]
		total_spikes += int(st2.spikes)
		print("[perf]   %-34s worst %6.1f ms  spikes %2d  pipeline compiles %d" % [k, st2.worst, st2.spikes, st2.compiles])
	print("[perf] total spikes %d" % total_spikes)
	get_tree().quit(0)


## HANDS HOOK (--hands): what the hands sweep costs at medium. The OR and the long corridor, each with
## the first-person hands hidden, the hands holding a bone saw, and the hands plus three teammates in
## view holding things (animated bodies with pose overrides, one mid wind-up). Twice, so the noise shows.
func _run_hands() -> void:
	main.set_quality(1, false)
	var HandsFP = load("res://scripts/hands/fp_hands.gd")
	var mates: Array = []
	for i in 3:
		var m = game.dev._make_bot_node(-60 - i, "Mate %d" % i, "bot")
		m.teleport(Vector3(0, -50, 0))
		mates.append(m)
	await get_tree().process_frame
	bot.slots = Player.empty_slots()
	bot.slots[0] = {"kind": "bone_saw", "count": 1}
	bot.selected = 0
	for pass_i in 2:
		for scen in [{"name": "OR", "setup": _or_view}, {"name": "corridor", "setup": _corridor}]:
			await scen.setup.call()
			for m in mates:
				m.teleport(Vector3(0, -50, 0))
			bot.camera.cull_mask = bot.camera.cull_mask & ~HandsFP.HANDS_LAYER
			bot.hands.visible = false
			await _measure("%s: no hands (%d)" % [scen.name, pass_i + 1], 1)
			bot.camera.cull_mask = bot.camera.cull_mask | HandsFP.HANDS_LAYER
			bot.hands.visible = true
			await _measure("%s: hands + saw (%d)" % [scen.name, pass_i + 1], 1)
			var eye: Vector3 = bot.global_position
			var fwd: Vector3 = -Vector3(sin(bot.bot_yaw), 0, cos(bot.bot_yaw))
			var side := fwd.cross(Vector3.UP)
			var kinds := ["anesthetic", "heart_monitor", "bone_saw"]
			for i in mates.size():
				var m: Player = mates[i]
				m.slots = Player.empty_slots()
				m.take_into(kinds[i], 2 if kinds[i] == "anesthetic" else 1, 0)
				m.teleport(game._floor_at(eye + fwd * (2.6 + i * 0.9) + side * (float(i) - 1.0) * 1.1))
				m.bot_yaw = bot.bot_yaw + PI
			game.combat.pose_at(mates[2], "saw", 0, 0.3)
			await _measure("%s: hands + 3 teammates (%d)" % [scen.name, pass_i + 1], 1)
			game.combat.stop_anim(mates[2])
			game.combat.anim_freeze = false
	print("[perf] ============================================================================")
	for r in _rows:
		print("[perf] %-36s avg %4.0f fps  1%%low %4.0f  worst %5.1f ms  proc %5.2f ms  draws %d" % [r.name, r.fps, r.low_fps, r.worst, r.proc, r.draws])
	get_tree().quit(0)
