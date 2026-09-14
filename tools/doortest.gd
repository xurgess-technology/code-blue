extends Node
## Doors and the per-shift wings, headless (and windowed screenshots with --shots).
##
##   godot --headless --fixed-fps 60 --path . tools/doortest.tscn [-- --seed=N]
##   godot --path . tools/doortest.tscn --resolution 1280x720 -- --shots     # tools/door_shots/
##   godot --path . tools/doortest.tscn --resolution 1280x720 -- --frames    # windowed frame times
##
## Checks: a player opens and closes a hinged door with E (swinging away from them, staying where
## left); automatic doors open for a player and for the paramedic crew with the gurney and close
## after; a Walk-In pushes a door open slowly, a rushing Discharged bursts through, the Night Nurse
## opens one only while unobserved; closed doors block sight (perception, the Walk-In's eyes) and
## attenuate noise; gates are locked in the lobby and open after clock-in; the wings regenerate
## between two shifts with a different layout while the entrance stays identical; the rebuild is
## spread over frames; a jammed gate frees itself.

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")
const Percept := preload("res://scripts/perception.gd")
const SHOT_DIR := "res://tools/door_shots"

var main: Node3D
var game: Game
var me: Player
var seed_value := 4242
var t := 0.0
var _failures: Array = []
var _checks := 0
var _shots := false
var _frames_mode := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		match kv[0]:
			"seed": seed_value = int(kv[1])
			"shots": _shots = true
			"frames": _frames_mode = true
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Doors")
	game.start_session(seed_value)
	await _frames(3)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(5)
	if _shots:
		await _take_shots()
	elif _frames_mode:
		await _frame_times()
	else:
		await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta


# =========================================================================
# checks
# =========================================================================

func _run() -> void:
	var doors: Node = game.doors
	_check(doors.doors.size() > 20, "the hospital has doors (%d)" % doors.doors.size())
	var kinds := {}
	for d in doors.doors.values():
		kinds[d.kind] = int(kinds.get(d.kind, 0)) + 1
	_say("door kinds: %s" % str(kinds))
	for k in ["hinged", "gate", "auto", "sliding"]:
		_check(kinds.has(k), "there is a %s door" % k)
	# Every doorway tile has a door node.
	var rows: PackedStringArray = game.level_info.rows
	var missing := 0
	for y in rows.size():
		for x in rows[y].length():
			if rows[y][x] == "+" and doors.door_at_tile(Vector2i(x, y)) == null:
				missing += 1
	_check(missing == 0, "every doorway tile has a door (%d without)" % missing)

	# The test player is a bot, and bots push hinged doors open by walking into them: this test
	# drives it by hand with E, so it does not.
	doors.agents_open_doors = false
	await _hinged_by_player()
	await _bot_pushes()
	await _gates_and_lobby()
	await _auto_for_player_and_crew()
	await _sight_and_noise()
	await _monsters_and_doors()
	await _jam()
	await _regeneration()


## A player presses E on a hinged door: it swings away from them, stays open, closes on E again.
func _hinged_by_player() -> void:
	_say("---- hinged door and E")
	var d := _pick_hinged()
	if d == null:
		_check(false, "found a hinged wing door with room on both sides")
		return
	var front: Vector3 = d.global_position + d.normal * 1.2
	_stand(front)
	_look_at(d.centre)
	await _frames(4)
	_check(d.is_closed(), "the door starts closed")
	_check(me.aim_id == d.door_id, "aiming at the door gives its interact id (%s, got '%s', prompt '%s')" % [d.door_id, me.aim_id, me.aim_prompt])
	_check(me.aim_prompt == "Open door", "the prompt says Open door (%s)" % me.aim_prompt)
	me.bot_press += 1
	await _seconds(1.0)
	_check(d.amount < -0.85, "E from the face side swings it away, into the tunnel (%.2f)" % d.amount)
	await _seconds(2.0)
	_check(d.amount < -0.85, "it stays open (%.2f)" % d.amount)
	# Aim at the open leaf, folded against its jamb in the tunnel.
	var leaf: Node3D = d.leaf_bodies[0]
	_look_at(leaf.global_transform * Vector3(0.7, 1.1, 0.0))
	await _frames(4)
	_check(me.aim_prompt == "Close door", "the open door can be aimed at: %s" % me.aim_prompt)
	me.bot_press += 1
	await _seconds(1.2)
	_check(d.is_closed(), "E again closes it (%.2f)" % d.amount)
	# From the tunnel side it swings out, away from the player.
	var back: Vector3 = d.global_position - d.normal * 1.85
	_stand(back)
	_look_at(d.centre)
	await _frames(4)
	me.bot_press += 1
	await _seconds(1.0)
	var want := 0.85 if d.max_out >= 80.0 else -0.85
	_check((d.amount > want) if want > 0.0 else (d.amount < want), "E from the tunnel side swings it away from the player (%.2f, max_out %d)" % [d.amount, int(d.max_out)])
	# A player in the way stops a door; it waits where it is.
	_stand(d.global_position - d.normal * 0.9)
	_look_at(leaf.global_transform * Vector3(0.5, 1.1, 0.0))
	await _frames(4)
	me.bot_press += 1
	await _seconds(1.2)
	_check(d.is_closed(), "closed again")
	game.doors._drive(d, 1.0 if d.max_out >= 80.0 else -1.0, 1.9)
	_stand(d.global_position + (d.normal if d.max_out >= 80.0 else -d.normal) * 0.7 + d.along * 0.1)
	await _seconds(1.0)
	_check(absf(d.amount) < 0.6 and d.halted, "a player standing in its swing stops the door (%.2f, halted %s)" % [d.amount, str(d.halted)])
	_stand(front + d.normal * 3.0)
	await _seconds(1.2)
	_check(absf(d.amount) > 0.85, "once they step away it carries on (%.2f)" % d.amount)
	# A dropped item in the way stops a closing door; kicked away, the door shuts.
	var side := 1.0 if d.amount > 0.0 else -1.0
	var lying: Vector3 = d.global_position + d.normal * side * 0.45 + d.along * 0.05 + Vector3.UP * 0.3
	var it: Node = game._spawn_item("gauze", 2, Transform3D(Basis(), lying), WorldItem.State.LOOSE)
	await _seconds(0.8)
	game.doors._drive(d, 0.0, 1.6)
	await _seconds(1.5)
	_check(absf(d.amount) > 0.1, "a dropped item in its way stops the door closing (%.2f, item at %s)" % [d.amount, str(it.global_position.snappedf(0.1))])
	it.global_position = d.global_position + d.normal * side * 3.0 + Vector3.UP * 0.3
	await _seconds(1.5)
	_check(d.is_closed(), "with the item moved the door closes (%.2f)" % d.amount)
	game.world_items.erase(it.item_id)
	it.queue_free()
	game.doors.set_all(false)
	await _seconds(1.5)


## A bot walking into a closed hinged door pushes it open and walks through.
func _bot_pushes() -> void:
	_say("---- a bot walks through a closed door")
	game.doors.agents_open_doors = true
	var d := _pick_hinged()
	game.doors.set_all(false)
	await _seconds(1.2)
	var from: Vector3 = d.global_position + d.normal * 3.0
	var to: Vector3 = d.global_position - d.normal * 3.0
	_stand(from)
	var start := t
	var through := false
	while t < start + 10.0:
		var dir := to - me.global_position
		me.bot_yaw = atan2(-dir.x, -dir.z)
		me.bot_move = Vector2(0, -1)
		await get_tree().physics_frame
		if (me.global_position - to).length() < 0.8:
			through = true
			break
	me.bot_move = Vector2.ZERO
	_check(through, "the bot got through the door (%.1f s, door %.2f)" % [t - start, d.amount])
	_check(int(game.doors.stats.get("bot", 0)) >= 1, "it pushed the door open itself")
	game.doors.agents_open_doors = false
	game.doors.set_all(false)
	await _seconds(1.2)


## Gates: locked in the lobby (prompt, lamp, no opening), unlocked and open at clock-in.
func _gates_and_lobby() -> void:
	_say("---- wing gates in the lobby, then clock-in")
	_check(game.phase == Game.Phase.LOBBY, "a run starts in the lobby")
	var g := _first_gate()
	_check(g != null, "found a wing gate")
	if g == null:
		return
	_check(g.locked and game.doors.gates_locked, "gates are locked in the lobby")
	game.doors.force_jam = 0   # jams have their own check
	_stand(g.global_position + g.normal * 1.8)
	_look_at(g.centre)
	await _seconds(1.5)
	_check(g.is_closed(), "a locked gate stays shut with a player right in front of it (%.2f)" % g.amount)
	_check(g.lamp_state == "locked", "its lamp is red (%s)" % g.lamp_state)
	_check(me.aim_prompt.begins_with("!Locked"), "the prompt says locked (%s)" % me.aim_prompt)
	# A shove against a locked gate by walking into it: still shut.
	me.bot_yaw = atan2(g.normal.x, g.normal.z)
	me.bot_move = Vector2(0, -1)
	await _seconds(1.5)
	me.bot_move = Vector2.ZERO
	_check(g.is_closed(), "walking into a locked gate does not open it")
	var into_wing: Vector3 = g.global_position - g.normal * 1.0
	_check(HB.zone_of(game.level_info, me.global_position) == "entrance", "the gate kept the player in the entrance hall (zone %s)" % HB.zone_of(game.level_info, me.global_position))
	game.begin_shift()
	await _seconds(0.5)
	_check(not g.locked and not game.doors.gates_locked, "clock-in unlocks the gates")
	_check(g.lamp_state == "open", "the lamp turns green (%s)" % g.lamp_state)
	await _seconds(1.0)
	_check(g.amount > 0.8, "the gates open when the shift starts (%.2f)" % g.amount)
	_stand(g.global_position + g.normal * 12.0)
	await _seconds(5.0)
	_check(g.is_closed(), "with nobody near it closes again (%.2f)" % g.amount)
	_stand(g.global_position + g.normal * 2.5)
	await _seconds(1.2)
	_check(g.amount > 0.8, "and opens for a player walking up (%.2f)" % g.amount)
	_stand(into_wing - g.normal * 3.0)
	await _seconds(1.0)
	_check(HB.zone_of(game.level_info, me.global_position) != "entrance", "a player can go through into the wing")


## The OR's doors and the main entrance open for players and for the paramedics with the gurney.
func _auto_for_player_and_crew() -> void:
	_say("---- automatic doors, players and the crew")
	var ord: Node = null
	var main_doors: Node = null
	for d in game.doors.doors.values():
		if d.kind == "auto":
			ord = d
		elif d.kind == "sliding":
			main_doors = d
	_stand(game.table_pos() + Vector3(0, 0, 3))
	await _seconds(3.0)
	_check(ord.is_closed() and main_doors.is_closed(), "the OR and entrance doors are shut with nobody near")
	_stand(ord.global_position + ord.normal * 2.4)
	await _seconds(1.2)
	_check(ord.amount > 0.8, "the OR doors open for a player (%.2f)" % ord.amount)
	_stand(main_doors.global_position - main_doors.normal * 2.5)
	await _seconds(1.2)
	_check(main_doors.amount > 0.8, "the sliding doors open for a player (%.2f)" % main_doors.amount)
	_stand(game.clock_pos() + Vector3(1.0, 0, 1.0))
	await _seconds(3.5)
	_check(ord.is_closed() and main_doors.is_closed(), "both close when the player leaves (%.2f, %.2f)" % [ord.amount, main_doors.amount])
	# The crew: the test's first patient arrives by gurney.
	for c in game.cases.duplicate():
		game.remove_case(int(c.id))
	game.loop.dev_phone_call()
	var saw_main := false
	var saw_or := false
	var crew_blocked := false
	var end := t + 90.0
	while t < end:
		await get_tree().physics_frame
		for cr in game.loop.crews.values():
			var p: Vector3 = cr.p
			for pair in [[main_doors, "main"], [ord, "or"]]:
				var dn: Node = pair[0]
				var lp: Vector3 = dn.global_transform.affine_inverse() * p
				if absf(lp.z) < 0.9 and absf(lp.x) < dn.width * 0.5:
					if pair[1] == "main":
						saw_main = saw_main or dn.amount > 0.7
					else:
						saw_or = saw_or or dn.amount > 0.7
					crew_blocked = crew_blocked or dn.amount < 0.5
		var c: Dictionary = game.case_by_id(game.cases[0].id) if not game.cases.is_empty() else {}
		if not c.is_empty() and String(c.state) == "on_table" and game.loop.crews.is_empty():
			break
	_check(saw_main, "the entrance doors were open as the crew and gurney passed")
	_check(saw_or, "the OR doors were open as the crew and gurney passed")
	_check(not crew_blocked, "the crew never passed a doorway with its door mostly shut")
	_check(not game.cases.is_empty() and String(game.cases[0].state) == "on_table", "the patient reached the table")


## Closed doors block the Night Nurse's watchers, the Walk-In's eyes and muffle noise.
func _sight_and_noise() -> void:
	_say("---- sight and noise through doors")
	var d := _pick_hinged()
	var inside: Vector3 = d.global_position + d.normal * 2.2
	var outside: Vector3 = d.global_position - d.normal * 3.0
	game.doors.set_all(false)
	await _seconds(1.2)
	var eye := outside + Vector3.UP * 1.6
	var target := inside + Vector3.UP * 1.3
	var space := me.get_world_3d().direct_space_state
	var ray := func() -> bool:
		var q := PhysicsRayQueryParameters3D.create(eye, target)
		q.collision_mask = C.L_WORLD
		return space.intersect_ray(q).is_empty()
	_check(not ray.call(), "a closed door blocks a line of sight through its doorway")
	_stand(outside)
	_look_at(target)
	me.set_flashlight(true)
	await _frames(4)
	_check(not Percept.is_observed(game, target), "perception: nobody sees a point behind a closed door")
	game.doors._drive(d, -1.0, 5.0)
	await _seconds(0.6)
	_check(ray.call(), "with the door open the line is clear")
	await _frames(4)
	var seen := Percept.is_observed(game, target)
	_check(seen, "perception: the lit point is seen through the open door")
	# The Walk-In's eyes: it stands in the room facing the doorway, the player outside.
	var wi: Node = game._add_monster("walk_in", inside)
	await _frames(2)
	var to_door: Vector3 = outside - wi.global_position
	wi.rotation.y = atan2(-to_door.x, -to_door.z)
	wi.brain.sight_timer = 99.0
	game.doors._drive(d, 0.0, 5.0)
	await _seconds(0.6)
	wi.rotation.y = atan2(-to_door.x, -to_door.z)
	wi.brain._look()
	var saw_closed: bool = wi.brain.seeing
	game.doors._drive(d, -1.0, 5.0)
	await _seconds(0.6)
	wi.rotation.y = atan2(-to_door.x, -to_door.z)
	wi.brain._look()
	var saw_open: bool = wi.brain.seeing
	_check(not saw_closed and saw_open, "a Walk-In sees the player through the open door, not the closed one (closed %s, open %s)" % [str(saw_closed), str(saw_open)])
	game.kill_monster(wi)
	await _frames(2)
	# Noise: a closed door on the line.
	game.doors._drive(d, 0.0, 5.0)
	await _seconds(0.6)
	var f_closed: float = game.doors.sound_factor(outside, inside)
	game.doors._drive(d, -1.0, 5.0)
	await _seconds(0.6)
	var f_open: float = game.doors.sound_factor(outside, inside)
	_check(f_closed < 0.6 and is_equal_approx(f_open, 1.0), "sound through the door: closed %.2f, open %.2f" % [f_closed, f_open])
	# A Discharged beyond a closed door does not hear a footstep that it hears with the door open.
	game.doors._drive(d, 0.0, 5.0)
	await _seconds(0.6)
	var m: Node = game._add_monster("discharged", inside + d.normal * 1.5)
	await _frames(3)
	m.brain.heard_time = game.world_time - 0.05
	var loud := 0.55
	var dist: float = (outside - m.global_position).length()
	_say("discharged %.1f m from the noise; hear per loudness %.1f" % [dist, m.brain.HEAR_PER_LOUDNESS])
	loud = clampf((dist + 0.8) / m.brain.HEAR_PER_LOUDNESS, 0.1, 2.0)
	game.emit_noise(outside, loud, "footstep")
	await _frames(2)
	var heard_closed: bool = not m.brain.last_heard.is_empty()
	m.brain.last_heard = {}
	game.doors._drive(d, -1.0, 5.0)
	await _seconds(0.8)
	m.brain.heard_time = game.world_time - 0.05
	game.emit_noise(outside, loud, "footstep")
	await _frames(2)
	var heard_open: bool = not m.brain.last_heard.is_empty()
	_check(not heard_closed and heard_open, "a Discharged hears a noise through the open door but not the closed one (closed %s, open %s)" % [str(heard_closed), str(heard_open)])
	game.kill_monster(m)
	await _frames(2)


## Each monster uses a door by its own rule.
func _monsters_and_doors() -> void:
	_say("---- monsters and doors")
	me.bot_invulnerable = true
	game.doors.set_all(false)
	await _seconds(1.5)
	# The Walk-In: slow push.
	var d := _pick_hinged()
	var inside: Vector3 = d.global_position + d.normal * 2.4
	var outside: Vector3 = d.global_position - d.normal * 3.0
	_stand(inside + d.normal * 0.6)
	var w: Node = game._add_monster("walk_in", outside)
	await _frames(2)
	w.brain._hunt(inside)
	var first_move := -1.0
	var opened_at := -1.0
	var start := t
	while t < start + 12.0:
		await get_tree().physics_frame
		w.brain.last_seen = inside
		if first_move < 0.0 and absf(d.amount) > 0.05:
			first_move = t
		if opened_at < 0.0 and absf(d.amount) > 0.85:
			opened_at = t
			break
	_check(first_move > 0.0 and opened_at > 0.0, "a Walk-In pushes a closed door open")
	if first_move > 0.0 and opened_at > 0.0:
		_check(opened_at - first_move > 1.4, "slowly (%.1f s from first give to open)" % (opened_at - first_move))
	_check(int(game.doors.stats.get("walk_in", 0)) >= 1, "counted as the Walk-In's push")
	game.kill_monster(w)
	game.doors.set_all(false)
	await _seconds(1.5)
	# The Discharged, rushing: bursts through.
	var dm: Node = game._add_monster("discharged", outside)
	await _frames(2)
	dm.brain.target = inside
	dm.mode = dm.Mode.RUSH
	opened_at = -1.0
	first_move = -1.0
	start = t
	while t < start + 8.0:
		await get_tree().physics_frame
		if dm.mode != dm.Mode.RUSH:
			dm.brain.target = inside
			dm.mode = dm.Mode.RUSH
		if first_move < 0.0 and absf(d.amount) > 0.05:
			first_move = t
		if opened_at < 0.0 and absf(d.amount) > 0.85:
			opened_at = t
			break
	_check(opened_at > 0.0 and first_move > 0.0 and opened_at - first_move < 0.4, "a rushing Discharged bursts a door open (%.2f s)" % (opened_at - first_move if opened_at > 0.0 else -1.0))
	_check(int(game.doors.stats.get("discharged_burst", 0)) >= 1, "counted as a burst (slam)")
	game.kill_monster(dm)
	game.doors.set_all(false)
	await _seconds(1.5)
	# The Night Nurse: not while watched; silently once nobody looks.
	var nd := d
	var nurse: Node = game._add_monster("night_nurse", nd.global_position - nd.normal * 1.8)
	_stand(nd.global_position + nd.normal * 4.0)
	_look_at(nd.centre)
	me.set_flashlight(true)
	await _seconds(2.5)
	var watched_amount: float = nd.amount
	# Nobody watching: turn away and switch the light off.
	me.bot_yaw += PI
	me.set_flashlight(false)
	var opened := false
	var sounds_before := int(game.doors.stats.get("night_nurse", 0))
	start = t
	while t < start + 10.0:
		await get_tree().physics_frame
		if absf(nd.amount) > 0.5:
			opened = true
			break
	_check(absf(watched_amount) < 0.05, "the Night Nurse leaves a watched door shut (%.2f)" % watched_amount)
	_check(opened and int(game.doors.stats.get("night_nurse", 0)) > sounds_before, "she opens it once nobody is looking")
	game.kill_monster(nurse)
	await _frames(2)


## A deep gate jams part way open, shudders, and frees itself.
func _jam() -> void:
	_say("---- a jammed gate")
	var g := _first_gate()
	_stand(g.global_position + g.normal * 14.0)
	await _seconds(4.0)
	game.doors.force_jam = 1
	g.set_meta("jam_rolled", false)
	g.jam_cooldown = 0.0
	_stand(g.global_position + g.normal * 2.6)
	var jammed := false
	var freed_at := -1.0
	var jam_start := -1.0
	var start := t
	while t < start + 10.0:
		await get_tree().physics_frame
		if g.jam_t > 0.0 and jam_start < 0.0:
			jam_start = t
			jammed = true
		if jammed and g.jam_t <= 0.0 and g.amount > 0.9:
			freed_at = t
			break
	game.doors.force_jam = -1
	_check(jammed, "the gate jammed")
	_check(freed_at > 0.0 and freed_at - jam_start < 5.0, "it freed itself within a few seconds (%.1f s)" % (freed_at - jam_start if freed_at > 0.0 else -1.0))


## Clock out, and the next lobby's wings are new while the entrance stays exactly where it was.
func _regeneration() -> void:
	_say("---- the wings between two shifts")
	for m in game.monsters.values().duplicate():
		game.kill_monster(m)
	var before_rows: PackedStringArray = game.level_info.rows.duplicate()
	var before := _entrance_signature()
	var gen_before: int = game.wing_loader.generation
	# Leave the player inside a wing, and an item there, to see them handled.
	var g := _first_gate()
	var wing_id := String(g.data.get("wing", ""))
	_stand(g.global_position - g.normal * 4.0)
	await _frames(3)
	_check(HB.zone_of(game.level_info, me.global_position) == wing_id, "the player waits inside the %s wing" % wing_id)
	game._end_shift(true, "")
	await _seconds(1.0)
	_check(game.doors.gates_locked, "clock-out locks the gates")
	await _until(func(): return game.phase == Game.Phase.LOBBY, 30.0)
	await _frames(1)
	_check(game.wing_loader.busy or not game.wing_loader.wings_ready or game.wing_loader.generation == gen_before + 1, "the next lobby starts rebuilding the wings")
	_check(HB.zone_of(game.level_info, me.global_position) == "entrance", "the player left in a wing was walked out to the entrance hall (%s)" % HB.zone_of(game.level_info, me.global_position))
	var max_frame := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while game.wing_loader.busy and Time.get_ticks_msec() - t0 < 60000:
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		frames += 1
		max_frame = maxf(max_frame, float(Time.get_ticks_usec() - f0) / 1000.0)
	_check(game.wing_loader.wings_ready and game.wing_loader.generation == gen_before + 1, "the wings finished rebuilding (generation %d)" % game.wing_loader.generation)
	_check(frames > 10, "the rebuild was spread over %d frames" % frames)
	_say("rebuild stats: %s" % str(game.wing_loader.stats))
	# Headless timings on a busy machine are noisy; the windowed `--frames` run is the real 50 ms check.
	_check(float(game.wing_loader.stats.get("max_frame_ms", 99.0)) < 50.0, "no frame of rebuild work over 50 ms (%.1f, slowest step %s %.1f ms)" % [
			float(game.wing_loader.stats.get("max_frame_ms", 0.0)), str(game.wing_loader.stats.get("slowest_step", "")),
			float(game.wing_loader.stats.get("slowest_step_ms", 0.0))])
	var after_rows: PackedStringArray = game.level_info.rows
	var differ := 0
	for y in before_rows.size():
		if before_rows[y] != after_rows[y]:
			differ += 1
	_check(differ > 10, "the wings have a new layout (%d rows differ)" % differ)
	_check(_entrance_signature() == before, "the entrance building, its landmarks and the neutral area are identical")
	_check(game.doors.gates_locked, "the gates stay locked in the lobby")
	# Clock in on the new wings: the loop's ordinary path (pending until ready, then unlocked).
	game.clock_in()
	await _seconds(1.0)
	_check(game.phase == Game.Phase.SHIFT and not game.doors.gates_locked, "clock-in on the new wings unlocks the gates")
	_check(game.level_info.containers.size() > 10 and game.level_info.monster_spawns.size() > 3, "the new wings have containers and monster spawns")
	var nav_ok := false
	var map := me.get_world_3d().navigation_map
	await _frames(5)
	for wd in game.level_info.wings:
		var far := Vector3.ZERO
		for r in game.level_info.rooms:
			if String(r.wing) == String(wd.id):
				far = Vector3((r.rect as Rect2).get_center().x, 0, (r.rect as Rect2).get_center().y)
		var path := NavigationServer3D.map_get_path(map, game.spawn_points()[0], NavigationServer3D.map_get_closest_point(map, far), true)
		nav_ok = path.size() >= 2 and path[path.size() - 1].distance_to(NavigationServer3D.map_get_closest_point(map, far)) < 0.6
		if not nav_ok:
			break
	_check(nav_ok, "the navigation mesh reaches every new wing")


func _entrance_signature() -> String:
	var info: Dictionary = game.level_info
	var parts := [str(info.get("clock")), str(info.get("phone")), str(info.get("tables")), str(info.get("shelf")),
		str(info.get("or_screen")), str(info.get("entrance")), str(info.get("neutral")), str(info.get("lectern"))]
	var er: Rect2 = info.entrance_rect
	var nr: Rect2 = info.neutral_rect
	var rows: PackedStringArray = info.rows
	for y in rows.size():
		var line := ""
		for x in rows[y].length():
			var p := Vector2((x + 0.5) * C.TILE, (y + 0.5) * C.TILE)
			if er.has_point(p) or nr.grow(2.0).has_point(p):
				line += rows[y][x]
		parts.append(line)
	for d in game.doors.doors.values():
		if bool(d.data.get("base", false)):
			parts.append("%s %s" % [d.door_id, str(d.global_position.snappedf(0.01))])
	return "|".join(parts)


# =========================================================================
# frame times (windowed): the rebuild while standing in the hall looking at a gate
# =========================================================================

func _frame_times() -> void:
	var g := _first_gate()
	_stand(g.global_position + g.normal * 4.0)
	_look_at(g.centre)
	await _seconds(2.0)
	var worst := 0.0
	var frames := 0
	var sum := 0.0
	game._end_shift(true, "")
	await _until(func(): return game.phase == Game.Phase.LOBBY, 30.0)
	_stand(g.global_position + g.normal * 4.0)
	_look_at(g.centre)
	var last := Time.get_ticks_usec()
	var t0 := Time.get_ticks_msec()
	while (game.wing_loader.busy or Time.get_ticks_msec() - t0 < 1000) and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := float(now - last) / 1000.0
		last = now
		frames += 1
		sum += ms
		worst = maxf(worst, ms)
	_say("windowed rebuild: %d frames, average %.1f ms, worst frame %.1f ms, stats %s" % [frames, sum / maxf(1, frames), worst, str(game.wing_loader.stats)])
	_check(worst < 50.0, "no frame over 50 ms while the wings rebuild (worst %.1f ms)" % worst)


# =========================================================================
# screenshots
# =========================================================================

func _take_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	me.set_flashlight(true)
	var doors: Node = game.doors
	var main_doors: Node = null
	for d in doors.doors.values():
		if d.kind == "sliding":
			main_doors = d
	# 1. The entrance from outside, then from inside with them open.
	_stand(main_doors.global_position + main_doors.normal * 6.5 + main_doors.along * 1.5)
	_look_at(main_doors.centre)
	await _seconds(1.0)
	await _shot("01_entrance_sliding_closed")
	_stand(main_doors.global_position + main_doors.normal * 3.0)
	_look_at(main_doors.centre)
	await _seconds(1.2)
	_stand(main_doors.global_position + main_doors.normal * 6.5 - main_doors.along * 1.0)
	_look_at(main_doors.centre)
	await _frames(2)
	await _shot("02_entrance_sliding_open")
	# 2. A wing gate locked in the lobby, then opening at clock-in.
	var g := _first_gate()
	_stand(g.global_position + g.normal * 4.5 + g.along * 0.8)
	_look_at(g.centre + Vector3.UP * 0.3)
	await _seconds(1.0)
	await _shot("03_gate_locked_lobby")
	game.begin_shift()
	await _seconds(0.45)
	await _shot("04_gate_opening_clock_in")
	await _seconds(1.2)
	await _shot("05_gate_open")
	# 3. A hinged door opening, seen from its corridor.
	var d := _pick_hinged()
	_stand(d.global_position + d.normal * 2.3 + d.along * 1.0)
	_look_at(d.centre)
	await _seconds(0.6)
	await _shot("06_hinged_closed")
	doors._drive(d, -1.0, 1.0)
	await _seconds(0.5)
	await _shot("07_hinged_opening")
	await _seconds(0.8)
	await _shot("08_hinged_open")
	_stand(d.global_position - d.normal * 3.9 - d.along * 0.5)
	_look_at(d.centre)
	await _seconds(0.4)
	await _shot("09_hinged_open_from_room")
	# 4. Double doors.
	var dd: Node = null
	for x in doors.doors.values():
		if x.kind == "double":
			dd = x
			break
	if dd != null:
		_stand(dd.global_position + dd.normal * 2.35 - dd.along * 0.6)
		_look_at(dd.centre)
		await _seconds(0.5)
		await _shot("10_double_closed")
		doors._drive(dd, -1.0, 0.8)
		await _seconds(0.7)
		await _shot("11_double_opening")
	# 5. A jammed gate.
	var jg := g
	_stand(jg.global_position + jg.normal * 16.0)
	await _seconds(4.0)
	doors.force_jam = 1
	jg.set_meta("jam_rolled", false)
	jg.jam_cooldown = 0.0
	_stand(jg.global_position + jg.normal * 3.2 + jg.along * 0.6)
	_look_at(jg.centre)
	await _until(func(): return jg.jam_t > 0.0, 4.0)
	await _seconds(0.6)
	await _shot("12_gate_jammed")
	doors.force_jam = 0
	# 6. A monster coming through a door.
	doors.set_all(false)
	await _seconds(1.0)
	var md := _pick_hinged()
	var inside: Vector3 = md.global_position - md.normal * 4.2
	var outside: Vector3 = md.global_position + md.normal * 2.2
	_stand(inside)
	_look_at(md.centre)
	var w: Node = game._add_monster("walk_in", outside)
	await _frames(2)
	w.brain._hunt(inside)
	await _until(func(): return absf(md.amount) > 0.45, 12.0)
	await _seconds(0.5)
	await _shot("13_walk_in_pushing_through")
	game.kill_monster(w)
	# 7. A hallway of closed doors.
	doors.set_all(false)
	await _seconds(1.2)
	var best := _hallway_view()
	_stand(best[0])
	_look_at(best[1])
	me.set_flashlight(true)
	await _seconds(0.8)
	await _shot("14_hallway_closed_doors")


## A spot in a hallway looking along a wall with several doors in it: [from, look at].
func _hallway_view() -> Array:
	var best_n := -1
	var out := [me.global_position, me.global_position + Vector3.FORWARD]
	for d in game.doors.doors.values():
		if not d.is_hinged() or bool(d.data.get("base", false)):
			continue
		# Doors further along the same wall, in one direction, within 14 m.
		for dirn in [1.0, -1.0]:
			var n := 0
			var far := 0.0
			for e in game.doors.doors.values():
				if e == d or not e.is_hinged():
					continue
				var rel: Vector3 = e.global_position - d.global_position
				var ahead: float = rel.dot(d.along) * dirn
				if absf(rel.dot(d.normal)) < 0.2 and ahead > 1.0 and ahead < 14.0 and e.normal.dot(d.normal) > 0.9:
					n += 1
					far = maxf(far, ahead)
			if n > best_n:
				var from: Vector3 = d.global_position + d.normal * 2.2 - d.along * dirn * 2.0
				var at: Vector3 = d.global_position + d.normal * 0.4 + d.along * dirn * maxf(6.0, far * 0.6) + Vector3.UP * 1.15
				if HB.zone_of(game.level_info, from) != "" and game._point_is_clear(from):
					best_n = n
					out = [from, at]
	return out


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	_say("wrote %s" % path)


# =========================================================================
# helpers
# =========================================================================

## A hinged wing door with a clear floor on both sides of it.
func _pick_hinged() -> Node:
	var best: Node = null
	var best_d := INF
	for d in game.doors.doors.values():
		if d.kind != "hinged" or bool(d.data.get("base", false)) or d.max_out < 80.0:
			continue
		var a: Vector3 = d.global_position + d.normal * 2.2
		var b: Vector3 = d.global_position - d.normal * 3.0
		if not game._point_is_clear(a) or not game._point_is_clear(b) or not game._point_is_clear(d.global_position + d.normal * 3.4):
			continue
		var dist: float = d.global_position.distance_to(game.clock_pos())
		if dist < best_d:
			best_d = dist
			best = d
	return best


func _first_gate() -> Node:
	var best: Node = null
	for d in game.doors.doors.values():
		if d.kind == "gate" and (best == null or String(d.door_id) < String(best.door_id)):
			best = d
	return best


func _stand(pos: Vector3, yaw := 0.0) -> void:
	me.teleport(game._floor_at(pos))
	me.bot_yaw = yaw
	me.bot_pitch = 0.0
	me.bot_move = Vector2.ZERO


func _look_at(target: Vector3) -> void:
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var d := target - eye
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("[doortest] ok   %s" % what)
	else:
		print("[doortest] FAIL %s" % what)
		_failures.append(what)


func _say(line: String) -> void:
	print("[doortest] %s" % line)


func _finish() -> void:
	print("[doortest] ------------------------------------------")
	if _failures.is_empty():
		print("[doortest] PASS (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		print("[doortest] FAIL (%d of %d checks)" % [_failures.size(), _checks])
		for f in _failures:
			print("[doortest]   " + f)
		get_tree().quit(1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()
