extends Node3D
## Monster lab: a lit test corridor with doorways and fixtures, stand-in players, and the
## three monsters, driven by scripted scenarios that print PASS/FAIL.
##
##   godot --headless --fixed-fps 60 --path . tools/monster_lab.tscn            # scenarios
##   godot --path . tools/monster_lab.tscn -- --shots                             # screenshots
##   godot --path . tools/monster_lab.tscn -- --shots --only=nurse_door           # one shot
##   godot --path . --resolution 1600x900 tools/monster_lab.tscn -- --perf              # Hive frame cost
##   options: --dist=<m> overrides the camera distance, --nopost drops the post layer
##
## Exit code 0 only when every scenario passed.

const HB := preload("res://scripts/hospital_builder.gd")
const MonsterScript := preload("res://scripts/monster.gd")
const PlayerScript := preload("res://scripts/player.gd")
const Percept := preload("res://scripts/perception.gd")
const Modes := preload("res://scripts/monsters/modes.gd")
const NurseRig := preload("res://scripts/monsters/night_nurse_rig.gd")
const SHOT_DIR := "res://tools/monster_shots"

## The stand-in game: exactly the surface monsters and Perception use.
class LabGame extends Node3D:
	var players: Dictionary = {}
	var level_info: Dictionary = {}
	var world_time := 0.0
	var host := true
	var noises: Array = []
	var hits: Array = []
	var said: Array = []
	var combat: Node = null   # a LabCombat while a drag scenario runs

	func _ready() -> void:
		add_to_group("game")

	func _physics_process(delta: float) -> void:
		world_time += delta

	func is_host() -> bool:
		return host

	func alive_players() -> Array:
		return players.values().filter(func(p): return p.alive)

	func viewed_player() -> Node:
		var a := alive_players()
		return a[0] if not a.is_empty() else null

	func emit_noise(pos: Vector3, loudness: float, kind: String) -> void:
		noises.append({"pos": pos, "loudness": loudness, "kind": kind, "time": world_time})

	func recent_noises(max_age: float = 1.5) -> Array:
		return noises.filter(func(n): return world_time - float(n.time) <= max_age)

	func monster_hit_player(m: Node, p: Node) -> void:
		if not p.alive or p.invuln > 0.0:
			return
		var knock: Vector3 = (p.global_position - m.global_position).normalized() * m.knockback
		p.take_hit(m.damage, knock * 0.0)
		hits.append({"kind": m.kind, "damage": m.damage, "time": world_time, "hp": p.hp})
		m.recoil_after_hit()

	func say(text: String, _seconds: float = 3.0) -> void:
		said.append(text)


## Stand-in for game.combat: the drag pin and drop_dragged.
class LabCombat extends Node:
	var pin := Transform3D.IDENTITY
	var dropped: Array = []

	func monster_pin(_m: Node) -> Transform3D:
		return pin

	func animate_held(_p: Node, _delta: float, _fp: Node3D, _tp: Node3D) -> void:
		pass

	## The hands pose from this every frame (scripts/hands/); nobody winds anything up in the lab.
	func action_of(_p: Node) -> Dictionary:
		return {}

	func drop_dragged(p: Node) -> void:
		dropped.append(p)
		for m in p.get_tree().get_nodes_in_group("monster"):
			if int(m.dragged_by) == int(p.peer_id):
				m.dragged_by = 0


var game: LabGame
var level: Node3D
var p1: Node   # the watcher / victim
var results: Array = []
var shots := false
var only := ""
var bulbs: Array = []
var dist_override := 0.0


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--real"):
		await _run_real()
		return
	if OS.get_cmdline_user_args().has("--perf"):
		await _run_perf()
		return
	for a in OS.get_cmdline_user_args():
		if a == "--shots":
			shots = true
		elif a.begins_with("--only="):
			only = a.split("=")[1]
		elif a.begins_with("--dist="):
			dist_override = float(a.split("=")[1])
	game = LabGame.new()
	game.name = "LabGame"
	add_child(game)
	_build_level()
	add_child(Look.make_environment())
	if shots and not OS.get_cmdline_user_args().has("--nopost"):
		var post := Look.make_post_layer()
		add_child(post)
	p1 = PlayerScript.new_player(1, "Watcher", false)
	game.players[1] = p1
	game.add_child(p1)
	p1.body_visual.visible = false
	p1.name_tag.visible = false
	for i in 4:
		await get_tree().physics_frame
	if shots:
		await _run_shots()
	else:
		await _run_scenarios()


# =========================================================================
# level
# =========================================================================

## 50 x 11 tiles: rooms along the top, a 2-tile corridor, rooms along the bottom, and a
## room at the far east end reached through a doorway at the end of the corridor.
func _build_level() -> void:
	var w := 50
	var h := 11
	var rows := PackedStringArray()
	for y in h:
		var s := ""
		for x in w:
			var c := "#"
			var border := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if not border:
				if x == 43:
					c = "+" if y == 5 else "#"
				elif x > 43:
					c = "." if y >= 3 and y <= 8 else "#"
				elif y >= 1 and y <= 3:
					c = "#" if x % 11 == 0 else "."
				elif y == 4:
					c = "+" if x in [5, 16, 27, 38] else "#"
				elif y == 5 or y == 6:
					c = "."
				elif y == 7:
					c = "+" if x in [10, 32] else "#"
				elif y == 8 or y == 9:
					c = "#" if x == 22 else "."
			s += c
		rows.append(s)
	var lights := [Vector2i(4, 5), Vector2i(14, 6), Vector2i(24, 5), Vector2i(36, 6), Vector2i(46, 5)]
	var gen := {"rows": rows, "seed": 7, "lights": lights}
	var info := {}
	level = HB.build(gen, info)
	add_child(level)
	info["monster_spawns"] = [C.tile_to_world(8, 5), C.tile_to_world(20, 6), C.tile_to_world(30, 5), C.tile_to_world(40, 6)]
	game.level_info = info
	for l in info.get("lights", []):
		bulbs.append(l.node.get_node("Bulb"))
	set_all_lights(false)


func set_light(i: int, on: bool) -> void:
	var b: OmniLight3D = bulbs[i]
	b.light_energy = HB.LIGHT_ENERGY if on else 0.0
	b.visible = on
	var panel = b.get_meta("panel") if b.has_meta("panel") else null
	if panel is MeshInstance3D and panel.material_override is StandardMaterial3D:
		(panel.material_override as StandardMaterial3D).emission_energy_multiplier = 2.4 if on else 0.0


func set_all_lights(on: bool) -> void:
	for i in bulbs.size():
		set_light(i, on)


## Corridor coordinates: x metres along it, lane 0 = centre of the corridor.
func cor(x: float, lane := 0.0) -> Vector3:
	return Vector3(x, 0.0, 6.0 * C.TILE + lane)


func place_player(pos: Vector3, look_at_point: Vector3, flashlight := true) -> void:
	p1.teleport(pos)
	var d := look_at_point - (pos + Vector3.UP * C.EYE_H)
	var yaw := atan2(-d.x, -d.z)
	p1.rotation.y = yaw
	p1._target_yaw = yaw
	var pitch := atan2(d.y, Vector2(d.x, d.z).length())
	p1._pitch = pitch
	p1.head.rotation.x = pitch
	p1.set_flashlight(flashlight)
	p1.moving = false
	p1.revive_full()
	# revive shows a remote surgeon's body; the lab looks out through its eyes.
	p1.body_visual.visible = false
	p1.name_tag.visible = false


func spawn(kind: String, pos: Vector3, yaw := 0.0) -> Node:
	var m: Node = MonsterScript.new_monster(game.players.size() * 10 + randi() % 1000, kind, pos)
	game.add_child(m)
	m.rotation.y = yaw
	return m


func wait(seconds: float) -> void:
	for i in maxi(1, int(ceil(seconds * 60.0))):
		await get_tree().physics_frame


func check(name: String, ok: bool, detail := "") -> void:
	results.append({"name": name, "ok": ok})
	print("[monster_lab] %s  %s  %s" % ["PASS" if ok else "FAIL", name, detail])


func clear_monsters() -> void:
	for m in get_tree().get_nodes_in_group("monster"):
		m.queue_free()
	game.noises.clear()
	game.hits.clear()
	await get_tree().physics_frame


# =========================================================================
# scenarios
# =========================================================================

func _run_scenarios() -> void:
	await _scenario_hearing()
	await _scenario_dark_still()
	await _scenario_nurse()
	await _scenario_contact()
	_scenario_roster()
	await _scenario_client()
	await _scenario_hive()
	await _scenario_combat()
	await _scenario_drag_and_lying()
	_scenario_placement()
	var failed := results.filter(func(r): return not r.ok).size()
	print("[monster_lab] ------------------------------------------")
	print("[monster_lab] %d checks, %d failed" % [results.size(), failed])
	get_tree().quit(0 if failed == 0 else 1)


func _scenario_hearing() -> void:
	print("[monster_lab] --- 1. the Discharged hears ---")
	set_all_lights(false)
	place_player(cor(60.0), cor(0.0), false)
	var d: Node = spawn("discharged", cor(10.0), -PI * 0.5)
	await wait(0.3)

	# Far: a sprint-loud noise 30 m away.
	game.emit_noise(cor(40.0), 0.8, "footstep")
	await wait(1.0)
	check("far sprint noise (30 m, reach 17.6) is not heard", d.brain.last_heard.is_empty() and d.mode != Modes.Mode.LISTEN and d.mode != Modes.Mode.RUSH,
		"mode=%d" % d.mode)

	# Behind a wall: 12 m away in a bottom room, loudness 0.8 -> halved reach 8.8.
	var behind := Vector3(d.global_position.x + 10.0, 0.0, 8.5 * C.TILE + 0.75)
	var dist_wall: float = (d.global_position + Vector3.UP * 1.55).distance_to(behind + Vector3.UP * 0.5)
	game.emit_noise(behind, 0.8, "footstep")
	await wait(0.5)
	check("sprint noise behind a wall (%.1f m, reach 17.6 halved to 8.8) is not heard" % dist_wall, d.brain.last_heard.is_empty(), "mode=%d" % d.mode)

	# Near: a sprint-loud noise 8 m away in the corridor.
	d.global_position = cor(10.0)
	await wait(0.1)
	var before: Vector3 = d.global_position
	var noise_at := cor(18.0, 0.6)
	game.emit_noise(noise_at, 0.8, "footstep")
	var t0: float = game.world_time
	await wait(0.1)
	check("sprint noise 8 m away: it freezes to listen", d.mode == Modes.Mode.LISTEN, "mode=%d" % d.mode)
	var listen_end := -1.0
	var max_move_listen := 0.0
	var yaw_ok := false
	while game.world_time - t0 < 2.0:
		await get_tree().physics_frame
		if d.mode == Modes.Mode.LISTEN:
			max_move_listen = maxf(max_move_listen, d.global_position.distance_to(before))
			if d.model.shaper.listen > 0.8:
				yaw_ok = true
		elif listen_end < 0.0:
			listen_end = game.world_time - t0
	check("it stands still while listening (moved %.3f m)" % max_move_listen, max_move_listen < 0.05)
	check("its head tilts toward the sound (shaper.listen > 0.8, listen_yaw %.2f)" % d.listen_yaw, yaw_ok)
	check("the listen lasts 0.8-1.2 s (%.2f s)" % listen_end, listen_end >= 0.75 and listen_end <= 1.3)
	check("then it rushes (mode RUSH, state CHASE)", d.mode == Modes.Mode.RUSH or d.mode == Modes.Mode.SEARCH, "mode=%d" % d.mode)
	var r0: Vector3 = d.global_position
	var rt: float = game.world_time
	var top := 0.0
	while d.mode == Modes.Mode.RUSH and game.world_time - rt < 5.0:
		await get_tree().physics_frame
		top = maxf(top, d.speed)
	check("rush speed about 5.2 m/s (peak %.2f)" % top, top > 4.6 and top < 5.6)
	check("it reached the noise (%.2f m away) and searches" % d.global_position.distance_to(noise_at), d.global_position.distance_to(noise_at) < 1.6 and d.mode == Modes.Mode.SEARCH, "mode=%d" % d.mode)
	await wait(5.5)
	check("after searching it wanders again", d.mode == Modes.Mode.WANDER or d.mode == Modes.Mode.IDLE, "mode=%d" % d.mode)

	# Walk-loud noise: heard at 4 m, not at 7 m.
	await clear_monsters()
	d = spawn("discharged", cor(10.0), -PI * 0.5)
	await wait(0.2)
	game.emit_noise(cor(17.0), 0.25, "footstep")
	await wait(0.2)
	check("walk noise 7 m away (reach 5.5) is not heard", d.mode != Modes.Mode.LISTEN)
	d.global_position = cor(10.0)
	game.emit_noise(cor(13.5), 0.25, "footstep")
	await wait(0.2)
	check("walk noise 3.5 m away is heard", d.mode == Modes.Mode.LISTEN, "mode=%d" % d.mode)
	await clear_monsters()


func _scenario_dark_still() -> void:
	print("[monster_lab] --- 2. standing still in the dark ---")
	set_all_lights(false)
	var d: Node = spawn("discharged", cor(8.0), -PI * 0.5)
	# A surgeon 6 m down the corridor, dead still, even shining a light right at it.
	place_player(cor(14.0, 0.8), cor(8.0) + Vector3.UP * 1.2, true)
	var hunted := false
	var closest := 99.0
	for i in 20 * 60:
		await get_tree().physics_frame
		if d.mode == Modes.Mode.LISTEN or d.mode == Modes.Mode.RUSH or d.mode == Modes.Mode.SEARCH:
			hunted = true
		closest = minf(closest, d.global_position.distance_to(p1.global_position))
	check("20 s: it never listened, rushed or searched for a silent player", not hunted, "closest pass %.1f m, hits %d" % [closest, game.hits.size()])
	check("the flashlight on it changed nothing", not hunted)
	await clear_monsters()


func _scenario_nurse() -> void:
	print("[monster_lab] --- 3. the Night Nurse ---")
	set_all_lights(false)
	var n: Node = spawn("night_nurse", cor(20.0), PI * 0.5)
	place_player(cor(8.0), cor(20.0) + Vector3.UP * 1.3, true)
	await wait(0.3)
	check("the Night Nurse wears her Blender model (clips %s)" % (str(n.model.anim.get_animation_list()) if n.model.anim != null else "none"),
		n.model.nurse != null and n.model.anim.has_animation("Walk") and n.model.anim.has_animation("Idle") and n.model.anim.has_animation("Frozen"))
	var start: Vector3 = n.global_position
	var frozen_anim := true
	for i in 120:
		await get_tree().physics_frame
		if n.model.anim != null and n.model.anim.speed_scale != 0.0:
			frozen_anim = false
	var moved: float = n.global_position.distance_to(start)
	check("watched with a flashlight at 12 m: it does not move (%.3f m)" % moved, moved < 0.02, "observed=%s" % n.observed)
	check("its animation is frozen while watched", frozen_anim)

	# Turn away.
	place_player(cor(8.0), cor(-5.0) + Vector3.UP * 1.3, true)
	start = n.global_position
	await wait(1.0)
	moved = n.global_position.distance_to(start)
	check("the player turns away: it moves (%.2f m in 1 s)" % moved, moved > 2.0, "observed=%s mode=%d" % [n.observed, n.mode])
	check("it moves at about 3.4 m/s (%.2f)" % n.speed, n.speed > 3.0 and n.speed < 3.8)
	var clip: String = n.model.anim.current_animation
	var rate: float = n.model.anim.speed_scale
	check("walking: the Walk clip plays at speed / %.1f m/s so the feet keep pace (%s at %.2fx for %.2f m/s)" % [NurseRig.WALK_SPEED, clip, rate, n.speed],
		clip == "Walk" and absf(rate - n.speed / NurseRig.WALK_SPEED) < 0.35)
	var eyes: Transform3D = n.eye_transform()
	check("eye_transform on her head bone (%.2f m up, %.2f m from her feet)" % [eyes.origin.y, Vector2(eyes.origin.x - n.global_position.x, eyes.origin.z - n.global_position.z).length()],
		eyes.origin.y > 1.75 and eyes.origin.y < 2.3 and Vector2(eyes.origin.x - n.global_position.x, eyes.origin.z - n.global_position.z).length() < 0.5)

	# Look back at it: frozen within one observation tick.
	place_player(p1.global_position, n.global_position + Vector3.UP * 1.3, true)
	await wait(0.15)
	start = n.global_position
	await wait(1.0)
	moved = n.global_position.distance_to(start)
	check("looked at again: frozen within 0.15 s (moved %.3f m after)" % moved, moved < 0.02)

	# Total darkness: flashlight off, no fixtures, 12 m away.
	n.global_position = cor(20.0)
	n.rotation.y = PI * 0.5
	place_player(cor(8.0), cor(20.0) + Vector3.UP * 1.3, false)
	await wait(0.3)
	start = n.global_position
	await wait(1.0)
	moved = n.global_position.distance_to(start)
	check("looked at in total darkness: it moves (%.2f m in 1 s)" % moved, moved > 2.0)
	await wait(3.0)
	var gap: float = n.global_position.distance_to(p1.global_position)
	check("in the dark it closes in until the player's near-glow would light it, then holds (%.2f m)" % gap, gap < PlayerScript.GLOW_RANGE + 1.3 and not n.moving, "observed=%s mode=%d" % [n.observed, n.mode])

	# A ceiling fixture lights it; the player looks with the flashlight off.
	await clear_monsters()
	var fixture_pos: Vector3 = game.level_info.lights[2].position   # tile (24,5)
	n = spawn("night_nurse", Vector3(fixture_pos.x, 0.0, fixture_pos.z), PI * 0.5)
	set_light(2, true)
	place_player(cor(fixture_pos.x - 11.0), Vector3(fixture_pos.x, 1.3, fixture_pos.z), false)
	await wait(0.3)
	start = n.global_position
	await wait(1.5)
	moved = n.global_position.distance_to(start)
	check("lit by a working fixture and watched: it does not move (%.3f m)" % moved, moved < 0.02, "fixture_lit=%s" % Percept.fixture_lit(game, Vector3(fixture_pos.x, 1.3, fixture_pos.z)))
	set_light(2, false)
	start = n.global_position
	await wait(1.0)
	moved = n.global_position.distance_to(start)
	check("the fixture dies: it moves (%.2f m)" % moved, moved > 2.0)

	# A flickering fixture below 30% counts as off.
	n.global_position = Vector3(fixture_pos.x, 0.0, fixture_pos.z)
	set_light(2, true)
	(bulbs[2] as OmniLight3D).light_energy = HB.LIGHT_ENERGY * 0.2
	await wait(0.3)
	start = n.global_position
	await wait(0.5)
	check("a fixture dipped to 20% energy does not freeze it", n.global_position.distance_to(start) > 0.8)
	set_light(2, false)

	# Performance: evaluations per second and cost.
	await clear_monsters()
	n = spawn("night_nurse", cor(24.0), PI * 0.5)
	set_all_lights(true)
	place_player(cor(10.0), cor(24.0) + Vector3.UP * 1.3, true)
	await wait(0.2)
	n.brain.evaluations = 0
	await wait(5.0)
	var per_s: float = n.brain.evaluations / 5.0
	var t_us := Time.get_ticks_usec()
	for i in 200:
		Percept.observed_any(game, n.brain.body_points(n.global_position))
	var cost := float(Time.get_ticks_usec() - t_us) / 200.0
	var t2 := Time.get_ticks_usec()
	for i in 200:
		Percept.observed_any(game, n.brain.body_points(n.global_position + Vector3(0, 0, -20)))
	var cost_hidden := float(Time.get_ticks_usec() - t2) / 200.0
	check("observation runs %.1f times/s per nurse (<= 20), %.0f us per watched check, %.0f us unwatched" % [per_s, cost, cost_hidden], per_s <= 20.0 and cost < 2000.0)
	set_all_lights(false)
	await clear_monsters()


func _scenario_contact() -> void:
	print("[monster_lab] --- 4. contact ---")
	set_all_lights(false)
	place_player(cor(14.0), cor(30.0) + Vector3.UP * 1.5, false)
	var d: Node = spawn("discharged", cor(9.0), -PI * 0.5)
	await wait(0.2)
	game.emit_noise(p1.global_position, 0.8, "footstep")
	var lunged := false
	for i in 4 * 60:
		await get_tree().physics_frame
		if d.lunge_t > 0.0 and game.hits.is_empty():
			lunged = true
		if not game.hits.is_empty():
			break
	check("the Discharged rushes the noise and hits the player standing there for 1", game.hits.size() == 1 and game.hits[0].damage == 1 and p1.hp == 2, "hits=%s" % [game.hits])
	check("it lunges before contact", lunged)
	check("after the hit it retreats and is calm", d.mode == Modes.Mode.RETREAT and d.calm > 0.0, "mode=%d calm=%.1f" % [d.mode, d.calm])
	var at_hit: Vector3 = d.global_position
	await wait(1.0)
	check("retreating: it backs away (%.2f m further)" % (d.global_position.distance_to(p1.global_position) - at_hit.distance_to(p1.global_position)), d.global_position.distance_to(p1.global_position) > at_hit.distance_to(p1.global_position) + 1.0)
	p1.invuln = 0.0
	game.emit_noise(p1.global_position, 0.9, "glass")
	await wait(1.0)
	check("while calm it ignores even breaking glass", d.mode != Modes.Mode.LISTEN and d.mode != Modes.Mode.RUSH, "mode=%d" % d.mode)
	p1.invuln = 99.0   # keep a wandering bump from muddying the next check
	await wait(4.0)
	var hits_before := game.hits.size()
	game.emit_noise(d.global_position + Vector3(3.0, 0, 0), 0.8, "footstep")
	await wait(0.2)
	check("calm wears off after a few seconds and it hears again", d.mode == Modes.Mode.LISTEN or d.mode == Modes.Mode.RUSH, "mode=%d calm=%.1f hits=%d" % [d.mode, d.calm, game.hits.size() - hits_before])
	p1.invuln = 0.0

	# Shove: 2 s stun.
	d.brain.shoved(Vector3.RIGHT)
	var st: Vector3 = d.global_position
	await wait(1.8)
	check("a shove stuns the Discharged for ~2 s", d.mode == Modes.Mode.STUNNED and d.global_position.distance_to(st) < 0.05)
	await wait(0.4)
	check("then it recovers", d.mode != Modes.Mode.STUNNED)
	await clear_monsters()

	# The Nurse from behind: 2 hearts.
	place_player(cor(14.0), cor(30.0) + Vector3.UP * 1.5, true)
	p1.invuln = 0.0
	var n: Node = spawn("night_nurse", cor(9.0), -PI * 0.5)
	for i in 4 * 60:
		await get_tree().physics_frame
		if not game.hits.is_empty():
			break
	check("the Night Nurse reaches an unaware player and hits for 2", game.hits.size() == 1 and game.hits[0].damage == 2 and p1.hp == 1, "hits=%s" % [game.hits])
	check("after the hit it retreats and is calm", n.mode == Modes.Mode.RETREAT and n.calm > 0.0)
	p1.invuln = 0.0
	await wait(1.5)
	check("no second hit while calm", game.hits.size() == 1, "hits=%d" % game.hits.size())
	var pos: Vector3 = n.global_position
	n.shoved(Vector3.RIGHT)
	await get_tree().physics_frame
	check("shoving the Nurse does nothing", n.mode != Modes.Mode.STUNNED and n.global_position.distance_to(pos) < 0.2)
	await clear_monsters()


func _scenario_roster() -> void:
	print("[monster_lab] --- 5. roster ---")
	var ok := true
	for shift in range(1, 7):
		var line := "  shift %d:" % shift
		for pc in range(1, 5):
			var r: Array[String] = MonsterScript.roster(shift, pc)
			var dd := r.count("discharged")
			var nn := r.count("night_nurse")
			var ww := r.count("hive")
			line += "  %dp D%d N%d W%d" % [pc, dd, nn, ww]
			if dd + nn > MonsterScript.MAX_MONSTERS or dd < 1 or (shift == 1 and nn != 0) or (shift >= 2 and nn < 1):
				ok = false
			if ww < 2 or ww > MonsterScript.MAX_HIVES or ww != MonsterScript.hive_count(shift, pc):
				ok = false
			if (shift > 1 or pc > 1) and ww < MonsterScript.roster(maxi(1, shift - 1), maxi(1, pc - 1)).count("hive"):
				ok = false
		print("[monster_lab]", line)
	var s1: Array[String] = MonsterScript.roster(1, 1)
	check("shift 1 solo is one Discharged and Hives", s1.count("discharged") == 1 and s1.count("night_nurse") == 0 and s1.count("hive") == 4, str(s1))
	check("roster rules hold for shifts 1-6, 1-4 players (cap 5 + Hive cap 8, nurse from shift 2, Hives grow)", ok)
	check("the Hive cap is reached late (shift 6, 4 players: %d)" % MonsterScript.roster(6, 4).count("hive"), MonsterScript.roster(6, 4).count("hive") == MonsterScript.MAX_HIVES)
	check("capturable: hive, discharged; not the Night Nurse", MonsterScript.is_capturable("hive") and MonsterScript.is_capturable("discharged") and not MonsterScript.is_capturable("night_nurse"))


## A client copy fed only report() must animate the same state.
func _scenario_client() -> void:
	print("[monster_lab] --- 6. client mirrors ---")
	set_all_lights(false)
	place_player(cor(8.0), cor(20.0) + Vector3.UP * 1.3, true)
	var host_n: Node = spawn("night_nurse", cor(20.0), PI * 0.5)
	var client_game := LabGame.new()
	client_game.host = false
	client_game.players = game.players
	client_game.level_info = game.level_info
	var client_n: Node = MonsterScript.new_monster(999, "night_nurse", cor(20.0, 1.0))
	add_child(client_n)
	client_n.game = client_game
	var host_d: Node = spawn("discharged", cor(30.0), -PI * 0.5)
	var client_d: Node = MonsterScript.new_monster(998, "discharged", cor(30.0, 1.0))
	add_child(client_d)
	client_d.game = client_game
	await wait(0.3)
	client_n.apply_remote(host_n.report())
	await wait(0.2)
	client_n.apply_remote(host_n.report())
	await get_tree().physics_frame
	check("client nurse freezes its clip when the host says observed", host_n.observed and client_n.model.anim.speed_scale == 0.0)
	game.emit_noise(cor(24.0), 0.8, "footstep")
	for i in 30:
		await get_tree().physics_frame
		client_d.apply_remote(host_d.report())
	check("client Discharged shows the listen tilt (listen %.2f)" % client_d.model.shaper.listen, client_d.mode == Modes.Mode.LISTEN and client_d.model.shaper.listen > 0.5)
	client_n.queue_free()
	client_d.queue_free()
	client_game.queue_free()
	await clear_monsters()


func _scenario_hive() -> void:
	print("[monster_lab] --- 7. the Hive sees ---")
	set_all_lights(false)
	# Facing east (+X) down the dark corridor, a player 8 m ahead, flashlight off.
	place_player(cor(18.0), cor(0.0) + Vector3.UP * 1.5, false)
	p1.invuln = 99.0
	var w: Node = spawn("hive", cor(10.0), -PI * 0.5)
	await wait(0.5)
	check("it sees a player 8 m ahead in the dark and comes (mode RUSH, state CHASE)", w.mode == Modes.Mode.RUSH and w.state == Modes.State.CHASE, "mode=%d" % w.mode)
	var eyes: Transform3D = w.eye_transform()
	var look_dir: Vector3 = -eyes.basis.z
	check("eye_transform: at eye height (%.2f m), looking the way it walks (%.2f, %.2f, %.2f)" % [eyes.origin.y, look_dir.x, look_dir.y, look_dir.z],
		eyes.origin.y > 1.3 and eyes.origin.y < 1.8 and look_dir.x > 0.6 and absf(eyes.origin.x - w.global_position.x) < 0.5)
	var top := 0.0
	for i in 90:
		await get_tree().physics_frame
		top = maxf(top, w.speed)
	check("it lumbers at about 1.8 m/s (peak %.2f)" % top, top > 1.6 and top < 2.0)

	# Behind it: not seen.
	await clear_monsters()
	place_player(cor(4.0), cor(30.0) + Vector3.UP * 1.5, false)
	w = spawn("hive", cor(10.0), -PI * 0.5)
	w.brain.home = cor(10.0)
	w.brain.timer = 30.0   # stands still
	var chased := false
	for i in 120:
		await get_tree().physics_frame
		if w.mode == Modes.Mode.RUSH:
			chased = true
	check("a player 6 m behind it is not seen", not chased, "mode=%d" % w.mode)
	# Deaf: a breaking-glass noise right behind it, and sprint footsteps.
	for i in 3:
		game.emit_noise(w.global_position + Vector3(-2.0, 0, 0), 0.9, "glass")
		game.emit_noise(p1.global_position, 0.8, "footstep")
		await wait(0.4)
	check("it ignores noise completely (glass 2 m behind it, sprinting)", w.mode != Modes.Mode.RUSH and w.mode != Modes.Mode.LISTEN and w.mode != Modes.Mode.SEARCH, "mode=%d" % w.mode)
	# Beyond range: 14 m ahead.
	await clear_monsters()
	place_player(cor(24.0), cor(0.0) + Vector3.UP * 1.5, false)
	w = spawn("hive", cor(10.0), -PI * 0.5)
	w.brain.home = cor(10.0)
	w.brain.timer = 30.0
	await wait(1.0)
	check("a player 14 m ahead (range 12) is not seen", w.mode != Modes.Mode.RUSH, "mode=%d" % w.mode)

	# Loses interest behind a wall.
	await clear_monsters()
	place_player(cor(17.0), cor(0.0) + Vector3.UP * 1.5, false)
	w = spawn("hive", cor(10.0), -PI * 0.5)
	await wait(1.0)
	var chasing: bool = w.mode == Modes.Mode.RUSH
	# The player ducks into the top room (doorway at tile 16,4) and stands behind its wall.
	p1.teleport(C.tile_to_world(19, 2))
	await wait(0.25)   # one sight tick for the old sighting to clear
	var t0: float = game.world_time
	var saw_again := false
	var searched := false
	var entered_room := false
	var gave_up := -1.0
	while game.world_time - t0 < 10.0:
		await get_tree().physics_frame
		if w.brain.seeing:
			saw_again = true
		if w.mode == Modes.Mode.SEARCH:
			searched = true
		if w.global_position.z < 4.0 * C.TILE:
			entered_room = true
		if gave_up < 0.0 and (w.mode == Modes.Mode.WANDER or w.mode == Modes.Mode.IDLE):
			gave_up = game.world_time - t0
	check("it was chasing before the player ducked away", chasing)
	check("behind the wall it never sees them again", not saw_again)
	check("it goes to where it last saw them and looks around", searched)
	check("it gives up within about 6 s (%.1f s)" % gave_up, gave_up > 2.0 and gave_up < 7.5, "mode=%d" % w.mode)
	check("it does not follow into the room", not entered_room)

	# Contact: hits for 1, backs off.
	await clear_monsters()
	place_player(cor(13.0), cor(0.0) + Vector3.UP * 1.5, false)
	p1.invuln = 0.0
	w = spawn("hive", cor(10.0), -PI * 0.5)
	for i in 5 * 60:
		await get_tree().physics_frame
		if not game.hits.is_empty():
			break
	check("it walks into a player standing still and hits for 1", game.hits.size() == 1 and game.hits[0].damage == 1 and game.hits[0].kind == "hive", "hits=%s" % [game.hits])
	check("after the hit it backs off and is calm", w.mode == Modes.Mode.RETREAT and w.calm > 0.0, "mode=%d" % w.mode)
	p1.invuln = 99.0

	# Shove: 2 s stun; the capture window.
	await wait(2.0)
	w.shoved(Vector3.RIGHT)
	var st: Vector3 = w.global_position
	await wait(1.8)
	check("a shove stuns the Hive for ~2 s (can_sedate %s)" % w.can_sedate(), w.mode == Modes.Mode.STUNNED and w.global_position.distance_to(st) < 0.05 and w.can_sedate())
	await wait(0.4)
	check("then it recovers (can_sedate false again)", w.mode != Modes.Mode.STUNNED and not w.can_sedate(), "mode=%d" % w.mode)

	# Cost of building one (the parts are baked once per session, then reused).
	var tb := Time.get_ticks_usec()
	var built: Node = MonsterScript.new_monster(990, "hive", cor(40.0))
	var build_ms := float(Time.get_ticks_usec() - tb) / 1000.0
	built.free()
	var others := ""
	for k in ["discharged", "night_nurse"]:
		var tk := Time.get_ticks_usec()
		var o: Node = MonsterScript.new_monster(991, k, cor(40.0))
		others += " %s %.1f ms" % [k, float(Time.get_ticks_usec() - tk) / 1000.0]
		o.free()
	check("building another Hive takes %.1f ms (parts baked once and cached;%s)" % [build_ms, others], build_ms < 15.0)

	# Cost: several Hives in sight of the player, rays per second.
	await clear_monsters()
	place_player(cor(20.0), cor(0.0) + Vector3.UP * 1.5, false)
	var crowd: Array = []
	for i in 6:
		var c: Node = spawn("hive", cor(8.0 + i * 1.5, -0.8 + (i % 2) * 1.6), -PI * 0.5)
		crowd.append(c)
	await wait(0.3)
	for c in crowd:
		c.brain.rays = 0
	await wait(3.0)
	var total := 0
	for c in crowd:
		total += int(c.brain.rays)
	check("6 Hives cast %.1f rays/s each (sight at 5 Hz, <= 12)" % (total / 3.0 / 6.0), total / 3.0 / 6.0 <= 12.0)
	var t_us := Time.get_ticks_usec()
	for i in 200:
		crowd[0].brain._look()
	var cost := float(Time.get_ticks_usec() - t_us) / 200.0
	check("one sight check costs %.0f us" % cost, cost < 500.0)
	await clear_monsters()


func _scenario_combat() -> void:
	print("[monster_lab] --- 8. hits, sedation, waking ---")
	set_all_lights(false)
	place_player(cor(40.0), cor(0.0) + Vector3.UP * 1.5, false)
	p1.invuln = 99.0
	var w: Node = spawn("hive", cor(10.0), -PI * 0.5)
	var d: Node = spawn("discharged", cor(20.0), -PI * 0.5)
	var n: Node = spawn("night_nurse", cor(30.0), -PI * 0.5)
	await wait(0.2)
	check("hp: hive 2, discharged 4, night_nurse 0", w.hp == 2 and w.max_hp == 2 and d.hp == 4 and d.max_hp == 4 and n.hp == 0 and n.max_hp == 0)
	check("can_be_hurt: not the Night Nurse", w.can_be_hurt() and d.can_be_hurt() and not n.can_be_hurt())
	var before: Vector3 = w.global_position
	var r1: String = w.take_hit(Vector3.RIGHT, 1, "saw:lab")
	await get_tree().physics_frame
	check("a first saw hit staggers the Hive (%s, knocked %.2f m, hp %d)" % [r1, w.global_position.distance_to(before), w.hp], r1 == "stagger" and w.mode == Modes.Mode.STUNNED and w.hp == 1 and w.global_position.distance_to(before) > 0.2)
	check("the hit bumps hit_count for every machine (%d)" % w.hit_count, w.hit_count == 1 and int(w.report().hc) == 1)
	await wait(1.0)
	check("after the stagger it goes after the hitter (mode RUSH)", w.mode == Modes.Mode.RUSH, "mode=%d" % w.mode)
	check("a second hit kills it", w.take_hit(Vector3.RIGHT, 1, "saw:lab") == "killed" and w.hp == 0)
	var results_d: Array = []
	for i in 4:
		results_d.append(d.take_hit(Vector3.RIGHT, 1, "saw:lab"))
	check("the Discharged takes 3 staggers, the 4th hit kills (%s)" % str(results_d), results_d == ["stagger", "stagger", "stagger", "killed"])
	var rn: String = n.take_hit(Vector3.RIGHT, 5, "saw:lab")
	check("the Night Nurse is immune (%s), hp unchanged" % rn, rn == "immune" and n.hp == 0 and n.hit_count == 0)
	n.shoved(Vector3.RIGHT)
	check("the Night Nurse can never be sedated", not n.can_sedate() and not n.sedate(10.0) and not n.is_sedated())
	await clear_monsters()

	# Sedation.
	place_player(cor(13.0), cor(0.0) + Vector3.UP * 1.5, false)
	p1.invuln = 0.0
	w = spawn("hive", cor(12.0), -PI * 0.5)
	await wait(0.1)
	check("not stunned: can_sedate is false", not w.can_sedate())
	w.shoved(Vector3.LEFT)
	check("shoved: can_sedate is true", w.can_sedate())
	check("sedate(3) works", w.sedate(3.0) and w.is_sedated() and w.mode == Modes.Mode.SEDATED and w.state == Modes.State.SEDATED)
	check("a second sedate while sedated is refused", not w.sedate(3.0))
	check("report says sd", w.report().sd == true)
	var at: Vector3 = w.global_position
	var hits_before := game.hits.size()
	await wait(1.5)
	check("sedated next to a player: it lies still (%.3f m) and never hits" % w.global_position.distance_to(at), w.global_position.distance_to(at) < 0.01 and game.hits.size() == hits_before)
	check("sedation_left counts down (%.2f)" % w.sedation_left, w.sedation_left > 1.3 and w.sedation_left < 1.6)
	check("lying pose: the model is tipped onto its back (rot %.2f)" % w.model.rotation.x, w.model.rotation.x > 1.45 and w.model.shaper.lying > 0.95)
	var r_sed: String = w.take_hit(Vector3.RIGHT, 1, "saw:lab")
	check("hit while sedated: %s, still sedated" % r_sed, r_sed == "stagger" and w.is_sedated())
	w.hp = w.max_hp
	await wait(1.7)
	check("it wakes when sedation runs out: staggering up (mode STUNNED)", not w.is_sedated() and w.mode == Modes.Mode.STUNNED, "mode=%d" % w.mode)
	await wait(1.3)
	check("then it hunts the nearest player", w.mode == Modes.Mode.RUSH or w.mode == Modes.Mode.RETREAT or game.hits.size() > hits_before, "mode=%d" % w.mode)
	await wait(1.0)
	check("and stands up again (rot %.2f)" % w.model.rotation.x, w.model.rotation.x < 0.2)
	p1.invuln = 99.0

	# wake() by hand, and the Discharged.
	await clear_monsters()
	place_player(cor(30.0), cor(0.0) + Vector3.UP * 1.5, false)
	d = spawn("discharged", cor(10.0), -PI * 0.5)
	await wait(0.1)
	d.shoved(Vector3.LEFT)
	check("the Discharged: shove then sedate", d.can_sedate() and d.sedate(60.0) and d.is_sedated())
	game.emit_noise(d.global_position + Vector3(2, 0, 0), 1.0, "glass")
	await wait(0.5)
	check("sedated, it does not hear breaking glass", d.is_sedated() and d.mode == Modes.Mode.SEDATED)
	d.wake()
	await wait(1.4)
	check("wake(): up and rushing toward the player (mode %d)" % d.mode, d.mode == Modes.Mode.RUSH and d.brain.target.distance_to(p1.global_position) < 1.0)
	await clear_monsters()


func _scenario_drag_and_lying() -> void:
	print("[monster_lab] --- 9. dragging, clients, lying copies ---")
	set_all_lights(false)
	place_player(cor(14.0), cor(0.0) + Vector3.UP * 1.5, false)
	p1.invuln = 99.0
	var lc := LabCombat.new()
	game.add_child(lc)
	game.combat = lc
	var w: Node = spawn("hive", cor(10.0), -PI * 0.5)
	await wait(0.1)
	w.shoved(Vector3.LEFT)
	w.sedate(30.0)
	w.dragged_by = 1
	lc.pin = Transform3D(Basis(Vector3.UP, 0.7), cor(12.0, 0.5))
	await wait(0.2)
	check("dragged: it sits at combat.monster_pin (%.3f m off)" % w.global_position.distance_to(lc.pin.origin), w.global_position.distance_to(lc.pin.origin) < 0.01 and absf(angle_difference(w.rotation.y, 0.7)) < 0.01)
	check("report carries db", int(w.report().db) == 1)
	# A client copy follows the pin too, and lies down from sd.
	var client_game := LabGame.new()
	client_game.host = false
	client_game.players = game.players
	client_game.level_info = game.level_info
	client_game.combat = lc
	var cw: Node = MonsterScript.new_monster(997, "hive", cor(30.0))
	add_child(cw)
	cw.game = client_game
	cw.apply_remote(w.report())
	lc.pin = Transform3D(Basis(), cor(13.0, -0.5))
	await wait(1.5)
	check("client: dragged monster placed at the pin", cw.global_position.distance_to(lc.pin.origin) < 0.01)
	check("client: lying pose from sd (rot %.2f), is_sedated() true" % cw.model.rotation.x, cw.model.rotation.x > 1.45 and cw.is_sedated())
	var rep: Dictionary = w.report()
	rep.sd = false
	rep.md = Modes.Mode.WANDER
	rep.db = 0
	cw.apply_remote(rep)
	await wait(1.5)
	check("client: gets up when sd clears (rot %.2f)" % cw.model.rotation.x, cw.model.rotation.x < 0.2 and not cw.is_sedated())
	cw.queue_free()
	client_game.queue_free()
	# Waking while dragged: dropped through combat.drop_dragged, and it lashes out at the dragger.
	p1.invuln = 0.0
	p1.teleport(cor(13.2))
	lc.pin = Transform3D(Basis(), cor(12.6))
	await wait(0.1)
	var hits_before := game.hits.size()
	w.wake()
	check("wake while dragged: combat.drop_dragged(dragger) is called and dragged_by clears", lc.dropped.size() == 1 and lc.dropped[0] == p1 and w.dragged_by == 0)
	check("and it hits the dragger", game.hits.size() == hits_before + 1)
	game.combat = null
	lc.queue_free()
	await clear_monsters()
	p1.invuln = 99.0

	# make_lying: a still copy along X, head toward -X, origin at the middle of the back.
	for k in ["hive", "discharged"]:
		var copy: Node3D = MonsterScript.make_lying(k)
		copy.position = cor(20.0) + Vector3.UP * 1.0
		add_child(copy)
		await wait(0.2)
		var box := AABB()
		var first := true
		for mi in copy.find_children("*", "MeshInstance3D", true, false):
			if not (mi as MeshInstance3D).is_visible_in_tree() or (mi as MeshInstance3D).skin != null or mi.get_parent() is Skeleton3D and String(mi.name).ends_with("-mesh"):
				continue   # skinned rig meshes report their rest-pose box (A-pose arms)
			var b: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
		var head: Node3D = copy.find_child("Head", true, false)
		var hx: float = head.global_position.x - copy.global_position.x if head != null else 0.0
		var centre: Vector3 = box.get_center() - copy.global_position
		check("make_lying(%s): long along X (%.2f x %.2f x %.2f), head toward -X (%.2f), centred (%.2f, %.2f)" % [k, box.size.x, box.size.y, box.size.z, hx, centre.x, centre.y],
			box.size.x > box.size.y * 2.5 and box.size.x > box.size.z * 2.0 and hx < -0.5 and absf(centre.x) < 0.25 and absf(centre.y) < 0.2)
		copy.queue_free()
	await get_tree().physics_frame


## Hive placement in generated hospitals (no physics space: the tile rules only).
func _scenario_placement() -> void:
	print("[monster_lab] --- 10. Hive placement ---")
	var MG = load("res://scripts/mapgen.gd")
	var ok_zone := true
	var ok_room := true
	var ok_shallow := true
	var ok_groups := true
	var ok_count := true
	var detail := ""
	var t_ms := 0
	for seed in [11, 202, 4242, 777, 90210, 5]:
		var gen: Dictionary = MG.generate(seed)
		var info := {}
		var lvl: Node3D = HB.build(gen, info)
		for count in [4, 8]:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed
			var t0 := Time.get_ticks_msec()
			var spots: Array[Vector3] = MonsterScript.hive_spots(info, count, rng)
			t_ms = maxi(t_ms, Time.get_ticks_msec() - t0)
			if spots.size() != count:
				ok_count = false
			var per_wing := {}
			for p in spots:
				var z: String = HB.zone_of(info, p)
				var is_wing := false
				for wd in info.wings:
					if String(wd.id) == z:
						is_wing = true
				if not is_wing or (info.entrance_rect as Rect2).has_point(Vector2(p.x, p.z)):
					ok_zone = false
					detail = "seed %d spot %s zone %s" % [seed, p, z]
				for r in info.rooms:
					if (r.rect as Rect2).grow(0.1).has_point(Vector2(p.x, p.z)):
						ok_room = false
						detail = "seed %d spot %s in room %s" % [seed, p, r.kind]
				per_wing[z] = per_wing.get(z, []) + [p]
			var cands: Dictionary = MonsterScript._hive_candidates(info, null)
			for z in per_wing:
				var dmin: float = cands[z][0].d
				for p in per_wing[z]:
					var dd: float = MonsterScript._rect_dist(info.entrance_rect, Vector2(p.x, p.z))
					if dd > dmin + MonsterScript.SHALLOW_BAND + MonsterScript.GROUP_RADIUS + 1.0:
						ok_shallow = false
						detail = "seed %d wing %s: %.1f m deep, shallowest %.1f" % [seed, z, dd, dmin]
				if (per_wing[z] as Array).size() > 4 or (per_wing[z] as Array).size() < 2:
					ok_groups = false
					detail = "seed %d wing %s has %d" % [seed, z, (per_wing[z] as Array).size()]
			if count == 8 and per_wing.size() < mini(4, info.wings.size()) - 1:
				ok_groups = false
				detail = "seed %d: 8 Hives in only %d of %d wings" % [seed, per_wing.size(), info.wings.size()]
			print("[monster_lab]   seed %d, %d Hives: %s" % [seed, count, str(per_wing.keys().map(func(k): return "%s x%d" % [k, per_wing[k].size()]))])
		lvl.free()
	check("Hive spots: the requested count", ok_count)
	check("Hive spots: all in wings, never the entrance or neutral area", ok_zone, detail)
	check("Hive spots: hallways, not rooms", ok_room, detail)
	check("Hive spots: the shallow part of each wing", ok_shallow, detail)
	check("Hive spots: groups of 2-4 spread over the wings (worst %d ms)" % t_ms, ok_groups, detail)

# =========================================================================
# screenshots
# =========================================================================

func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	p1.camera.current = true
	game.host = false   # monsters are posed through apply_remote, exactly like a client
	var list := [
		["discharged_4m", _shot_discharged.bind(4.0, false)],
		["discharged_1_5m", _shot_discharged.bind(1.5, false)],
		["discharged_listen", _shot_discharged.bind(3.0, true)],
		["nurse_4m", _shot_nurse.bind(4.0)],
		["nurse_1_5m", _shot_nurse.bind(1.5)],
		["nurse_door", _shot_nurse_door],
		["nurse_walk_flashlight", _shot_nurse_walk.bind(4.5, 1.6)],
		["nurse_frozen_watched", _shot_nurse_frozen],
		["nurse_idle", _shot_nurse_idle],
		["nurse_knocked", _shot_nurse_knocked],
		["nurse_lunge", _shot_nurse_lunge],
		["nurse_face", _shot_head.bind("night_nurse", false, 0.9, 0.35)],
		["nurse_corpse", _shot_nurse_corpse],
		["hive_4m", _shot_hive.bind(4.0, false)],
		["hive_1_5m", _shot_hive.bind(1.5, false)],
		["hive_face", _shot_head.bind("hive", false, 0.75, 0.45)],
		["hive_sees_you", _shot_hive_rush],
		["hive_group", _shot_hive_group],
		["discharged_head", _shot_head.bind("discharged", false, 0.8, 0.2)],
		["discharged_side", _shot_head.bind("discharged", false, 0.7, 1.35)],
		["discharged_ears_listen", _shot_head.bind("discharged", true, 0.8, 0.5)],
		["discharged_height", _shot_height],
		["sedated", _shot_sedated],
		["lying_copies", _shot_lying],
	]
	for s in list:
		if only != "" and not only.split(",").has(s[0]):
			continue
		await clear_monsters()
		set_all_lights(false)
		await s[1].call()
		await wait(1.2)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [SHOT_DIR, s[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[monster_lab] wrote ", path)
		_shot_tick = Callable()
	get_tree().quit(0)


func _pose(m: Node, pos: Vector3, yaw: float, mode: int, moving: bool, spd: float, extra := {}) -> void:
	var r := {"pos": pos, "y": yaw, "st": 0, "md": mode, "mv": moving, "sp": spd, "ob": false, "ly": 0.0, "lg": false, "cm": false}
	r.merge(extra, true)
	m.global_position = pos
	m.rotation.y = yaw
	m.apply_remote(r)


func _shot_discharged(dist: float, listen: bool) -> void:
	if dist_override > 0.0:
		dist = dist_override
	var d: Node = spawn("discharged", cor(20.0, -0.3), PI * 0.5)
	# Facing the camera, which stands `dist` metres east of it.
	var pos := cor(20.0, -0.3)
	var yaw := -PI * 0.5
	if listen:
		_pose(d, pos, yaw + 0.5, Modes.Mode.LISTEN, false, 0.0, {"ly": -0.9})
	else:
		_pose(d, pos, yaw, Modes.Mode.WANDER, true, 1.4)
	place_player(pos + Vector3(dist, 0, 0.35), pos + Vector3.UP * (1.25 if dist > 2.0 else 1.45), true)
	for i in 40:
		await get_tree().physics_frame
		d.apply_remote({"pos": pos, "y": yaw + (0.5 if listen else 0.0), "md": Modes.Mode.LISTEN if listen else Modes.Mode.WANDER, "mv": not listen, "sp": 1.4, "ly": -0.9 if listen else 0.0})
	if not listen:
		# Freeze mid-stride for a readable silhouette.
		d.model.anim.speed_scale = 0.0


func _shot_nurse(dist: float) -> void:
	if dist_override > 0.0:
		dist = dist_override
	var n: Node = spawn("night_nurse", cor(20.0, 0.2), -PI * 0.5)
	var pos := cor(20.0, 0.2)
	_pose(n, pos, -PI * 0.5 + 0.15, Modes.Mode.WANDER, true, 3.4)
	place_player(pos + Vector3(dist, 0, -0.3), pos + Vector3.UP * (1.5 if dist > 2.0 else 1.9), true)
	await wait(0.35)
	_pose(n, pos, -PI * 0.5 + 0.15, Modes.Mode.WANDER, false, 0.0, {"ob": true})


func _shot_nurse_door() -> void:
	# The east doorway at the end of the corridor, 20 m away, one flickering light between.
	var door := C.tile_to_world(43, 5)
	var n: Node = spawn("night_nurse", door, PI * 0.5)
	_pose(n, door, PI * 0.5 - 0.2, Modes.Mode.WANDER, false, 0.0, {"ob": true})
	set_light(4, true)
	(bulbs[4] as OmniLight3D).light_energy = HB.LIGHT_ENERGY * 0.6
	place_player(cor(door.x - 10.0, 0.3), door + Vector3.UP * 1.3, true)
	await wait(0.3)


## Called every physics frame while a shot waits for its capture (cleared after each capture).
var _shot_tick := Callable()


func _physics_process(_delta: float) -> void:
	if _shot_tick.is_valid():
		_shot_tick.call()


## Walking across the dark corridor toward the camera's side, nobody watching it (the dev room's
## "ignores being watched"), lit only by the flashlight. The clip runs right up to the capture.
func _shot_nurse_walk(dist: float, spd: float) -> void:
	var pos := cor(20.0, 0.6)
	var n: Node = spawn("night_nurse", pos, -PI * 0.5)
	var yaw := -PI * 0.5 - 0.75
	place_player(cor(20.0 + dist, -1.0), pos + Vector3.UP * 1.3, true)
	_shot_tick = func():
		if is_instance_valid(n):
			_pose(n, pos, yaw, Modes.Mode.WANDER, true, spd)
	await wait(0.5)


## Caught mid-stride: walking, then the host says observed; the capture is 1 s after the freeze.
func _shot_nurse_frozen() -> void:
	var pos := cor(20.0, 0.5)
	var n: Node = spawn("night_nurse", pos, -PI * 0.5)
	var yaw := -PI * 0.5 - 0.9
	place_player(cor(23.8, -0.9), pos + Vector3.UP * 1.3, true)
	var frame := [0]
	_shot_tick = func():
		frame[0] += 1
		if is_instance_valid(n):
			_pose(n, pos, yaw, Modes.Mode.WANDER, frame[0] < 23, 1.6 if frame[0] < 23 else 0.0, {"ob": frame[0] >= 23})
	await wait(0.0)


func _shot_nurse_idle() -> void:
	var pos := cor(20.0, 0.2)
	var n: Node = spawn("night_nurse", pos, -PI * 0.5)
	set_light(1, true)
	(bulbs[1] as OmniLight3D).light_energy = HB.LIGHT_ENERGY * 0.45
	_pose(n, pos, -PI * 0.5 - 0.35, Modes.Mode.IDLE, false, 0.0)
	place_player(pos + Vector3(3.6, 0, 0.6), pos + Vector3.UP * 1.3, true)
	await wait(1.5)


## A dev gun knock-down: calm starts outside a retreat, she is thrown back, then holds the Frozen pose.
func _shot_nurse_knocked() -> void:
	var pos := cor(20.0, 0.3)
	var n: Node = spawn("night_nurse", pos, -PI * 0.5)
	var yaw := -PI * 0.5 - 0.6
	place_player(cor(23.4, -0.9), pos + Vector3.UP * 1.4, true)
	var frame := [0]
	# Walking, then (about 0.25 s before the capture) the knock-down lands.
	_shot_tick = func():
		frame[0] += 1
		if is_instance_valid(n):
			if frame[0] < 62:
				_pose(n, pos, yaw, Modes.Mode.WANDER, true, 1.6)
			else:
				_pose(n, pos, yaw, Modes.Mode.IDLE, false, 0.0, {"cm": true})
	await wait(0.0)


func _shot_nurse_lunge() -> void:
	var pos := cor(20.0, 0.3)
	var n: Node = spawn("night_nurse", pos, -PI * 0.5)
	place_player(cor(22.6, -0.7), pos + Vector3.UP * 1.5, true)
	_shot_tick = func():
		if is_instance_valid(n):
			_pose(n, pos, -PI * 0.5 - 0.45, Modes.Mode.WANDER, true, 3.4, {"lg": true})
	await wait(0.3)


func _shot_nurse_corpse() -> void:
	var pos := cor(20.0, 0.0)
	var root := Node3D.new()
	root.add_to_group("monster")
	add_child(root)
	(load("res://scripts/dev/dev_gun.gd") as GDScript).monster_corpse(root, "night_nurse", pos, -PI * 0.5 + 0.6)
	set_light(1, true)
	place_player(pos + Vector3(2.6, 0, 1.6), pos + Vector3.UP * 0.3, true)
	await wait(0.2)


func _shot_hive(dist: float, _unused: bool) -> void:
	if dist_override > 0.0:
		dist = dist_override
	var pos := cor(20.0, -0.2)
	var w: Node = spawn("hive", pos, -PI * 0.5)
	var yaw := -PI * 0.5 + 0.25
	_pose(w, pos, yaw, Modes.Mode.WANDER, true, 0.8)
	var look_h := 1.0 if dist > 2.0 else (1.3 if dist > 1.0 else 1.45)
	place_player(pos + Vector3(dist, 0, 0.3), pos + Vector3.UP * look_h, true)
	for i in 40:
		await get_tree().physics_frame
		w.apply_remote({"pos": pos, "y": yaw, "md": Modes.Mode.WANDER, "mv": true, "sp": 0.8})
	w.model.anim.speed_scale = 0.0


func _shot_hive_rush() -> void:
	# It has seen the camera and comes: head up, 2 m away, a fixture behind it.
	var pos := cor(21.0, -0.2)
	var w: Node = spawn("hive", pos, -PI * 0.5)
	set_light(1, true)
	for f in 90:
		await get_tree().physics_frame
		w.apply_remote({"pos": pos, "y": -PI * 0.5 + 0.15, "md": Modes.Mode.RUSH, "mv": true, "sp": 1.8})
	w.model.anim.speed_scale = 0.0
	place_player(pos + Vector3(2.0, 0, 0.25), pos + Vector3.UP * 1.45, true)


func _shot_hive_group() -> void:
	var yaws := [-PI * 0.5 + 0.4, -PI * 0.5 - 0.2, -PI * 0.5 + 0.1]
	var spots := [cor(18.0, -0.7), cor(16.5, 0.6), cor(14.5, -0.2)]
	var ws: Array = []
	for i in 3:
		ws.append(spawn("hive", spots[i], yaws[i]))
	set_light(1, true)
	place_player(cor(25.0, 0.2), cor(16.0) + Vector3.UP * 1.1, true)
	for f in 50:
		await get_tree().physics_frame
		for i in 3:
			ws[i].apply_remote({"pos": spots[i], "y": yaws[i], "md": Modes.Mode.RUSH if i == 0 else Modes.Mode.WANDER, "mv": true, "sp": 1.8 if i == 0 else 0.8})


## A head close-up: the camera `dist` metres from the face, `view` radians around from straight
## in front (positive: toward the monster's left), eye level with the head. `listen`: the
## Discharged listens to a sound on its left.
func _shot_head(kind: String, listen: bool, dist: float, view: float) -> void:
	var pos := cor(21.0, -0.3)
	var m: Node = spawn(kind, pos, -PI * 0.5)
	var yaw := -PI * 0.5
	var ly := 0.9 if listen else 0.0
	var md: int = Modes.Mode.LISTEN if listen else Modes.Mode.IDLE
	_pose(m, pos, yaw, md, false, 0.0, {"ly": ly})
	set_light(1, true)
	for i in 60:
		await get_tree().physics_frame
		m.apply_remote({"pos": pos, "y": yaw, "md": md, "mv": false, "sp": 0.0, "ly": ly})
	m.model.anim.speed_scale = 0.0
	var head: Node3D = m.model.find_child("Head", true, false)
	var hp: Vector3 = head.global_position + head.global_transform.basis.y.normalized() * 0.11
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var dir := fwd.rotated(Vector3.UP, view)
	var eye := hp + dir * dist + Vector3.UP * 0.05
	place_player(Vector3(eye.x, 0.0, eye.z), hp, true)
	p1.teleport(Vector3(eye.x, eye.y - C.EYE_H, eye.z))
	var dvec: Vector3 = hp - eye
	var cam_yaw := atan2(-dvec.x, -dvec.z)
	p1.rotation.y = cam_yaw
	p1._target_yaw = cam_yaw
	p1._pitch = atan2(dvec.y, Vector2(dvec.x, dvec.z).length())
	p1.head.rotation.x = p1._pitch
	await wait(0.2)


func _shot_height() -> void:
	# Left to right: the Discharged, a surgeon, a Hive, side by side across the corridor.
	var d: Node = spawn("discharged", cor(21.0, -1.0), -PI * 0.5)
	_pose(d, cor(21.0, -1.0), -PI * 0.5, Modes.Mode.IDLE, false, 0.0)
	var surgeon: Node = PlayerScript.new_player(2, "Surgeon", false)
	game.add_child(surgeon)
	surgeon.teleport(cor(21.0, 0.05))
	surgeon.rotation.y = -PI * 0.5
	surgeon._target_yaw = -PI * 0.5
	surgeon.add_to_group("monster")   # cleared with the monsters after the shot
	var w: Node = spawn("hive", cor(21.0, 1.0), -PI * 0.5)
	_pose(w, cor(21.0, 1.0), -PI * 0.5, Modes.Mode.IDLE, false, 0.0)
	set_light(1, true)
	place_player(cor(27.5, 0.0), cor(21.0, 0.0) + Vector3.UP * 1.1, true)
	await wait(1.0)
	var head: Node3D = d.model.find_child("Head", true, false)
	print("[monster_lab] Discharged head bone at %.2f m (top of skull about %.2f)" % [head.global_position.y, head.global_position.y + 0.25])
	var wh: Node3D = w.model.find_child("Head", true, false)
	print("[monster_lab] Hive head bone at %.2f m (top of skull about %.2f)" % [wh.global_position.y, wh.global_position.y + 0.22])


func _shot_sedated() -> void:
	var pos := cor(21.0, -0.5)
	var w: Node = spawn("hive", pos, PI * 0.5 + 0.3)
	var d: Node = spawn("discharged", cor(18.0, 0.6), -PI * 0.5 - 0.2)
	for f in 120:
		await get_tree().physics_frame
		w.apply_remote({"pos": pos, "y": PI * 0.5 + 0.3, "md": Modes.Mode.SEDATED, "sd": true, "mv": false, "sp": 0.0})
		d.apply_remote({"pos": cor(18.0, 0.6), "y": -PI * 0.5 - 0.2, "md": Modes.Mode.SEDATED, "sd": true, "mv": false, "sp": 0.0})
	set_light(1, true)
	place_player(cor(24.5, 0.8), cor(19.8, 0.0) + Vector3.UP * 0.1, true)


func _shot_lying() -> void:
	var a: Node3D = MonsterScript.make_lying("hive")
	a.position = cor(21.0, -0.7) + Vector3.UP * 0.9
	add_child(a)
	a.add_to_group("monster")
	var b: Node3D = MonsterScript.make_lying("discharged")
	b.position = cor(21.0, 0.7) + Vector3.UP * 0.9
	add_child(b)
	b.add_to_group("monster")
	set_light(1, true)
	place_player(cor(21.3, 1.4) + Vector3(0, 0.9, 0), cor(21.0, 0.0) + Vector3.UP * 0.9, true)
	await wait(0.4)


# =========================================================================
# the real game: boot main.tscn, walk a bot around a generated hospital, log the monsters
#   godot --headless --fixed-fps 60 --path . tools/monster_lab.tscn -- --real [--seed=4242]
#         [--shift=4] [--seconds=240]
# =========================================================================

func _run_real() -> void:
	var seed := 4242
	var shift := 4
	var seconds := 240.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed = int(a.split("=")[1])
		elif a.begins_with("--shift="):
			shift = int(a.split("=")[1])
		elif a.begins_with("--seconds="):
			seconds = float(a.split("=")[1])
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var g: Node = main.game
	if main.get("menu") != null:
		main.menu.hide_menu()
	Net.start_solo("Observer")
	g.start_session(seed)
	await get_tree().process_frame
	g.start_lobby(seed, shift)
	await wait(0.5)
	g.begin_shift()
	await wait(0.5)
	var bot: Node = g.local_player()
	bot.bot_active = true
	var roster := []
	for m in g.monsters.values():
		roster.append("%d:%s" % [m.monster_id, m.kind])
	print("[real] seed=%d shift=%d monsters=%s (roster() says %s)" % [seed, shift, roster, MonsterScript.roster(shift, 1)])

	var names := {0: "IDLE", 1: "WANDER", 2: "LISTEN", 3: "RUSH", 4: "SEARCH", 5: "STALK", 6: "STUNNED", 7: "RETREAT", 8: "SEDATED"}
	var last_mode := {}
	var last_pos := {}
	var watched_move := {}
	var watched_time := {}
	var free_time := {}
	var top_speed := {}
	var mode_count := {}
	var hits := 0
	var last_hp: int = bot.hp
	var goal: Vector3 = bot.global_position
	var path := PackedVector3Array()
	var repath := 0.0
	var pause := 0.0
	var leg_sprint := false
	var t := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var map: RID = bot.get_world_3d().navigation_map
	var slow_frames := 0
	while t < seconds and g.phase == 2:
		await get_tree().physics_frame
		var dt := 1.0 / 60.0
		t += dt
		if Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) > 0.016:
			slow_frames += 1
		# ---- bot: walk leg to leg, sometimes sprint, sometimes stop and look at the nearest monster
		if not bot.alive:
			print("[real] t=%.1f the bot died; reviving to keep watching" % t)
			bot.revive_full()
			last_hp = bot.hp
		if bot.hp < last_hp:
			hits += 1
			print("[real] t=%.1f bot hit, hp %d -> %d" % [t, last_hp, bot.hp])
		last_hp = bot.hp
		if pause > 0.0:
			pause -= dt
			bot.bot_move = Vector2.ZERO
			bot.bot_sprint = false
			var near: Node = null
			var nd := 16.0
			for m in g.monsters.values():
				var d: float = m.global_position.distance_to(bot.global_position)
				if d < nd:
					nd = d
					near = m
			if near != null:
				var to: Vector3 = near.global_position + Vector3.UP * 1.4 - (bot.global_position + Vector3.UP * C.EYE_H)
				bot.bot_yaw = atan2(-to.x, -to.z)
				bot.bot_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -1.0, 1.0)
		else:
			repath -= dt
			if bot.global_position.distance_to(goal) < 1.2 or repath <= -8.0:
				goal = NavigationServer3D.map_get_random_point(map, 1, false)
				leg_sprint = rng.randf() < 0.35
				repath = 0.0
				if rng.randf() < 0.4:
					pause = rng.randf_range(2.0, 5.0)
			if repath <= 0.0:
				repath = 0.5
				path = NavigationServer3D.map_get_path(map, bot.global_position, goal, true)
			var next: Vector3 = goal
			for p in path:
				if p.distance_to(bot.global_position) > 0.8:
					next = p
					break
			var dir: Vector3 = next - bot.global_position
			bot.bot_yaw = atan2(-dir.x, -dir.z)
			bot.bot_pitch = 0.0
			bot.bot_move = Vector2(0, -1)
			bot.bot_sprint = leg_sprint

		# ---- monsters
		if int(t * 60.0) % 600 == 0:
			var line := "[real] t=%.0f status:" % t
			for m in g.monsters.values():
				line += "  %s#%d %s d=%.1f v=%.1f%s" % [m.kind, m.monster_id, names[m.mode], m.global_position.distance_to(bot.global_position), m.speed, " watched" if m.observed else ""]
				if OS.get_cmdline_user_args().has("--debug") and m.speed < 0.1 and not m.observed:
					line += " [pos %s next %s fin %s reach %s tgt %s]" % [m.global_position, m.agent.get_next_path_position(), m.agent.is_navigation_finished(), m.agent.is_target_reachable(), m.agent.target_position]
			print(line)
		for m in g.monsters.values():
			var id: int = m.monster_id
			var md: int = m.mode
			mode_count["%s %s" % [m.kind, names[md]]] = mode_count.get("%s %s" % [m.kind, names[md]], 0) + 1
			if last_mode.get(id, -1) != md:
				var extra := ""
				if md == 2 and m.brain.last_heard.size() > 0:
					extra = " heard %s %.2f at %.1f m" % [m.brain.last_heard.kind, m.brain.last_heard.loudness, m.global_position.distance_to(m.brain.last_heard.pos)]
				print("[real] t=%.1f %s#%d %s -> %s  (bot %.1f m)%s" % [t, m.kind, id, names.get(last_mode.get(id, -1), "-"), names[md], m.global_position.distance_to(bot.global_position), extra])
				last_mode[id] = md
			top_speed[m.kind + " " + names[md]] = maxf(top_speed.get(m.kind + " " + names[md], 0.0), m.speed)
			if m.kind == "night_nurse":
				var lp: Vector3 = last_pos.get(id, m.global_position)
				if m.observed:
					watched_time[id] = watched_time.get(id, 0.0) + dt
					watched_move[id] = watched_move.get(id, 0.0) + m.global_position.distance_to(lp)
				else:
					free_time[id] = free_time.get(id, 0.0) + dt
			last_pos[id] = m.global_position

	print("[real] ---- after %.0f s (phase %d) ----" % [t, g.phase])
	print("[real] bot hits taken: %d" % hits)
	for k in mode_count:
		print("[real]   %-26s %6.1f s   top speed %.2f m/s" % [k, mode_count[k] / 60.0, top_speed.get(k, 0.0)])
	for id in watched_time:
		print("[real]   nurse#%d watched %.1f s (moved %.3f m while watched), unwatched %.1f s" % [id, watched_time[id], watched_move.get(id, 0.0), free_time.get(id, 0.0)])
	print("[real] physics frames over 16 ms: %d of %d" % [slow_frames, int(t * 60.0)])
	# Cost of the monsters' own per-tick work (brains, perception, visual state), timed directly.
	for m in g.monsters.values():
		m.set_physics_process(false)
	var usec := 0
	for i in 300:
		await get_tree().physics_frame
		var t0 := Time.get_ticks_usec()
		for m in g.monsters.values():
			m._physics_process(1.0 / 60.0)
		usec += Time.get_ticks_usec() - t0
	print("[real] monster tick: %.3f ms per physics frame for %d monsters" % [usec / 300.0 / 1000.0, g.monsters.size()])
	get_tree().quit(0)


# =========================================================================
# frame time with Hives (windowed, vsync off)
#   godot --path . --resolution 1600x900 tools/monster_lab.tscn -- --perf [--seed=4242] [--frames=300]
# Same session, same view, alternating: no Hives, the shift's roster, 8 Hives in view.
# =========================================================================

var _perf_rows: Array = []

func _run_perf() -> void:
	var seed := 4242
	var frames := 300
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed = int(a.split("=")[1])
		elif a.begins_with("--frames="):
			frames = int(a.split("=")[1])
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var g: Node = main.game
	main.menu.hide_menu()
	Net.start_solo("Probe")
	g.start_session(seed)
	await get_tree().process_frame
	while g.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	main.set_quality(1, false)
	g.begin_shift()
	for i in 30:
		await get_tree().process_frame
	var bot: Node = g.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	print("[perf] gpu=%s window=%s monsters=%s" % [RenderingServer.get_video_adapter_name(), str(get_viewport().get_visible_rect().size), str(g.monsters.values().map(func(m): return m.kind))])

	# The view: from 9 m down the most open line from the first Hive, looking back at it.
	var first: Vector3 = Vector3.ZERO
	for m in g.monsters.values():
		if m.kind == "hive":
			first = m.global_position
			break
	var space: PhysicsDirectSpaceState3D = bot.get_world_3d().direct_space_state
	var best_dir := Vector3.FORWARD
	var best_len := -1.0
	for i in 16:
		var dir := Vector3(cos(TAU * i / 16.0), 0, sin(TAU * i / 16.0))
		var q := PhysicsRayQueryParameters3D.create(first + Vector3.UP * 1.5, first + Vector3.UP * 1.5 + dir * 12.0)
		q.collision_mask = C.L_WORLD
		var hit := space.intersect_ray(q)
		var reach: float = 12.0 if hit.is_empty() else first.distance_to(hit.position)
		if reach > best_len:
			best_len = reach
			best_dir = dir
	var cam := first + best_dir * minf(9.0, best_len - 0.8)
	var look := func():
		bot.teleport(cam)
		var d: Vector3 = first - cam
		bot.bot_yaw = atan2(-d.x, -d.z)
		bot.bot_pitch = -0.08
		bot.bot_move = Vector2.ZERO
		bot.flashlight_on = true

	if OS.get_cmdline_user_args().has("--nurses"):
		await _perf_nurses(g, bot, first, best_dir, look, frames)
		return
	for pass_i in 2:
		# A: no Hives at all (what the game had before).
		g._spawn_monsters()
		for m in g.monsters.values().duplicate():
			if m.kind == "hive":
				g.monsters.erase(m.monster_id)
				m.queue_free()
		look.call()
		await _perf_measure("no Hives (%d monsters) #%d" % [g.monsters.size(), pass_i + 1], frames, bot)
		# B: the shift's roster.
		g._spawn_monsters()
		look.call()
		await _perf_measure("shift 1 roster (%d monsters) #%d" % [g.monsters.size(), pass_i + 1], frames, bot)
		# C: 8 Hives right in view, chasing the camera.
		for m in g.monsters.values().duplicate():
			if m.kind == "hive":
				g.monsters.erase(m.monster_id)
				m.queue_free()
		for i in 8:
			var p: Vector3 = first + best_dir * (1.0 + i * 0.7) + best_dir.cross(Vector3.UP) * (0.6 if i % 2 == 0 else -0.6)
			g._add_monster("hive", p)
		look.call()
		await _perf_measure("8 Hives in view (%d monsters) #%d" % [g.monsters.size(), pass_i + 1], frames, bot)
	print("[perf] ============================================================================")
	print("[perf] %-40s avg fps  1%%low  worst ms  phys ms  proc ms  draws" % "scenario")
	for r in _perf_rows:
		print("[perf] %-40s %7.0f  %5.0f  %8.1f  %7.2f  %7.2f  %5d" % [r.name, r.fps, r.low, r.worst, r.phys, r.proc, r.draws])
	get_tree().quit(0)


## `-- --perf --nurses`: the same view with no monsters, then 1 and 4 Night Nurses 3-6 m in front of
## the camera, walking in place (posed like a client, so they animate and never reach the camera).
func _perf_nurses(g: Node, bot: Node, first: Vector3, best_dir: Vector3, look: Callable, frames: int) -> void:
	for pass_i in 2:
		for count in [0, 1, 4]:
			g._clear_monsters()
			await get_tree().process_frame
			var list: Array = []
			for i in count:
				var side := best_dir.cross(Vector3.UP) * (0.7 if i % 2 == 0 else -0.7)
				var p: Vector3 = first + best_dir * (3.0 + i * 1.0) + side * (0.0 if count == 1 else 1.0)
				var m: Node = g._add_monster("night_nurse", p)
				m.set_physics_process(false)
				list.append(m)
			look.call()
			_perf_tick = func():
				for m in list:
					if is_instance_valid(m):
						var to: Vector3 = bot.global_position - m.global_position
						m.rotation.y = atan2(-to.x, -to.z)
						m.apply_remote({"pos": m.global_position, "y": m.rotation.y, "md": Modes.Mode.WANDER, "mv": true, "sp": 1.6, "ob": false})
						m._update_visual(get_process_delta_time())
			await _perf_measure("%d Night Nurse%s in view #%d" % [count, "" if count == 1 else "s", pass_i + 1], frames, bot)
			if pass_i == 0 and count > 0:
				# What was measured, to check the nurses really were in view.
				await RenderingServer.frame_post_draw
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
				get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("%s/perf_%d_nurses.png" % [SHOT_DIR, count]))
			_perf_tick = Callable()
	print("[perf] ============================================================================")
	print("[perf] %-40s avg fps  1%%low  worst ms  phys ms  proc ms  draws" % "scenario")
	for r in _perf_rows:
		print("[perf] %-40s %7.0f  %5.0f  %8.1f  %7.2f  %7.2f  %5d" % [r.name, r.fps, r.low, r.worst, r.phys, r.proc, r.draws])
	get_tree().quit(0)


var _perf_tick := Callable()


func _perf_measure(label: String, frames: int, bot: Node) -> void:
	for i in 60:
		await get_tree().process_frame
		if _perf_tick.is_valid():
			_perf_tick.call()
	var times: Array[float] = []
	var phys := 0.0
	var proc := 0.0
	var draws := 0
	var cam_pos: Vector3 = bot.global_position
	for i in frames:
		await get_tree().process_frame
		if _perf_tick.is_valid():
			_perf_tick.call()
		if bot.global_position.distance_to(cam_pos) > 0.3:
			bot.teleport(cam_pos)
		times.append(get_process_delta_time() * 1000.0)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		draws = maxi(draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	var total := 0.0
	for t in times:
		total += t
	var sorted := times.duplicate()
	sorted.sort()
	var row := {"name": label, "fps": 1000.0 * times.size() / total, "low": 1000.0 / sorted[int(sorted.size() * 0.99) - 1],
		"worst": sorted[-1], "phys": phys / frames, "proc": proc / frames, "draws": draws}
	_perf_rows.append(row)
	print("[perf] %-40s avg %.0f fps, 1%% low %.0f, phys %.2f ms, draws %d" % [label, row.fps, row.low, row.phys, draws])
