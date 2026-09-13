extends Node3D
## Monster lab: a lit test corridor with doorways and fixtures, stand-in players, and the
## two monsters, driven by scripted scenarios that print PASS/FAIL.
##
##   godot --headless --fixed-fps 60 --path . tools/monster_lab.tscn            # scenarios
##   godot --path . tools/monster_lab.tscn -- --shots                             # screenshots
##   godot --path . tools/monster_lab.tscn -- --shots --only=nurse_door           # one shot
##   options: --dist=<m> overrides the camera distance, --nopost drops the post layer
##
## Exit code 0 only when every scenario passed.

const HB := preload("res://scripts/hospital_builder.gd")
const MonsterScript := preload("res://scripts/monster.gd")
const PlayerScript := preload("res://scripts/player.gd")
const Percept := preload("res://scripts/perception.gd")
const Modes := preload("res://scripts/monsters/modes.gd")
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
			line += "  %dp D%d N%d" % [pc, dd, nn]
			if r.size() > 5 or dd < 1 or (shift == 1 and nn != 0) or (shift >= 2 and nn < 1):
				ok = false
		print("[monster_lab]", line)
	var s1: Array[String] = MonsterScript.roster(1, 1)
	check("shift 1 solo is exactly one Discharged", s1.size() == 1 and s1[0] == "discharged", str(s1))
	check("roster rules hold for shifts 1-6, 1-4 players (cap 5, nurse from shift 2)", ok)


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
	]
	for s in list:
		if only != "" and s[0] != only:
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

	var names := {0: "IDLE", 1: "WANDER", 2: "LISTEN", 3: "RUSH", 4: "SEARCH", 5: "STALK", 6: "STUNNED", 7: "RETREAT"}
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
