extends Node
## Headless checks for combat (sweep 3): the bone saw as a weapon, anesthetic jabs, dragging a
## sedated monster and strapping it to a patient table.
##
##   godot --headless --fixed-fps 60 --path . tools/combattest.tscn
##
## Runs in the dev room with dummies: the saw kills a monster in the expected number of hits and
## pays nothing, cuts air loudly, respects its cooldown, breaks at the seeded roll (and at about 12%
## over many rolls), clangs off the Night Nurse; the needle needs the stun window, uses one vial only
## when it sedates, is refused by the Night Nurse; friendly fire (a saw hit costs a heart, a jab knocks
## a teammate out); dragging (hold, prompts, slow walk, the body behind, no shove or drop), putting it
## down, strapping it (the case's fields, the monster gone), a taken table, a wake-up while dragged,
## a hit dragger letting go. Exits 0 when every check passes.

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const CombatScript := preload("res://scripts/combat/combat.gd")
const MonsterScript := preload("res://scripts/monster.gd")

var main: Node3D
var game: Game
var dev: Node
var cb: Node
var me: Player
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	cb = game.combat
	main.menu.hide_menu()
	Net.start_solo("Tester")
	game.start_session(DevRoomScript.SEED)
	await _frames(8)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 600.0 and not _done:
		_check(false, "timed out")
		_finish()


func _run() -> void:
	_check(cb.is_usable("bone_saw") and cb.is_usable("anesthetic") and not cb.is_usable("gauze") and not cb.is_usable(""),
		"left mouse uses the bone saw and anesthetic, nothing else")
	for m in game.monsters.values():
		game.kill_monster(m)
	await _frames(2)
	var money0: int = game.money

	# ---- the saw kills
	cb.break_chance = 0.0
	_give("bone_saw", 1)
	var m := await _monster("discharged", Vector3(12.0, 0, 12.0))
	var want_hits := int(m.get("max_hp")) if "max_hp" in m else CombatScript.FALLBACK_HITS
	var hits := 0
	var results: Array = []
	var mid: int = m.monster_id
	while game.monsters.has(mid) and hits < 10:
		_face(m)
		await _frames(2)
		await _use()
		if String(cb.last_result.get("what", "")) == "monster":
			hits += 1
			results.append(String(cb.last_result.result))
		await _seconds(CombatScript.SWING_COOLDOWN + 0.05)
		if game.monsters.has(mid):
			_calm(m)
	_check(not game.monsters.has(mid) and hits == want_hits, "the saw kills the Discharged in %d hits (took %d: %s)" % [want_hits, hits, str(results)])
	_check(results.size() > 0 and results[-1] == "killed" and not results.slice(0, -1).has("killed"), "every hit but the last staggers, the last kills")
	_check(game.money == money0, "a kill pays nothing ($%d -> $%d)" % [money0, game.money])
	_check(me.holding("bone_saw"), "break chance 0: the saw survives")
	var loud := _noise_near(me.global_position, "saw", 3.0)
	_check(loud >= CombatScript.NOISE_HIT - 0.01, "a hit is loud (noise %.2f)" % loud)

	# ---- air, cooldown
	_stand(Vector3(12.0, 0, 16.0), 0.0)
	await _seconds(CombatScript.NOISE_HIT + 1.6)   # older noises age out of recent_noises(1.5)
	await _use()
	_check(String(cb.last_result.get("what", "")) == "air", "a swing at nothing cuts air")
	var hush := _noise_near(me.global_position, "swing", 3.0)
	_check(absf(hush - CombatScript.NOISE_SWING) < 0.01, "a swing through air makes some noise (%.2f)" % hush)
	cb.last_result = {}
	await _use(false)
	_check(String(cb.last_result.get("what", "")) == "cooldown", "a second swing inside the cooldown does nothing")
	await _seconds(CombatScript.SWING_COOLDOWN)

	# ---- the Night Nurse: immune, and the saw breaks at the seeded roll
	var nurse := await _monster("night_nurse", Vector3(16.0, 0, 12.0))
	var nid: int = nurse.monster_id
	cb.break_chance = CombatScript.SAW_BREAK_CHANCE
	var seed := 90210
	cb.rng.seed = seed
	var pred := RandomNumberGenerator.new()
	pred.seed = seed
	var expect_snap := 1
	while pred.randf() >= CombatScript.SAW_BREAK_CHANCE:
		expect_snap += 1
	var connects := 0
	var immune := 0
	while me.holding("bone_saw") and connects < 60:
		_face(nurse)
		await _frames(2)
		await _use()
		if String(cb.last_result.get("what", "")) == "monster":
			connects += 1
			if String(cb.last_result.result) == "immune":
				immune += 1
		await _seconds(CombatScript.SWING_COOLDOWN + 0.02)
	_check(connects == expect_snap and not me.holding("bone_saw"), "seeded roll: the saw snaps on hit %d (expected %d)" % [connects, expect_snap])
	_check(immune == connects and game.monsters.has(nid), "the Night Nurse is immune to every hit (%d/%d) and still there" % [immune, connects])
	_check(game.message.contains("bone saw snapped"), "the snap is announced ('%s')" % game.message)
	_check(me.selected_stack().kind == "", "the snapped saw is gone from the hand")
	var n_break := 0
	cb.rng.seed = 7
	for i in 5000:
		if cb.breaks():
			n_break += 1
	_check(n_break > 5000 * 0.105 and n_break < 5000 * 0.135, "about 12%% of hits break the saw (%d / 5000)" % n_break)
	cb.break_chance = 0.0

	# ---- the needle
	_give("anesthetic", 3)
	await _use_on(nurse)
	_check(_vials() == 3 and String(cb.last_result.get("result", "")) == "refused" and game.message.contains("needle will not go in"),
		"the Night Nurse refuses the needle, no vial used ('%s')" % game.message)
	game.knock_down_monster(nurse, Vector3.ZERO, 30.0)   # a calm nurse, out of the way
	nurse.global_position = Vector3(3.0, 0.0, 3.0)
	var b := await _monster("discharged", Vector3(12.0, 0, 12.0))
	var bid: int = b.monster_id
	b.calm = 0.0
	await _use_on(b)
	_check(_vials() == 3 and not cb.is_sedated(b) and String(cb.last_result.get("result", "")) == "shrugged",
		"not stunned: it shrugs the needle off, no vial used (%s)" % str(cb.last_result))
	_check(int(b.mode) == MonsterScript.Mode.LISTEN or int(b.mode) == MonsterScript.Mode.RUSH, "the needle alerts it (mode %d)" % int(b.mode))
	_calm(b)
	_face(b)
	await _frames(2)
	game.player_shoved(me)
	await _frames(2)
	_check(cb.can_sedate(b), "a shove opens the stun window")
	await _use_on(b)
	_check(_vials() == 2 and cb.is_sedated(b), "jabbed inside the stun window: sedated, one vial used (%d left)" % _vials())
	_check(absf(cb.sedation_left(b) - CombatScript.SEDATE_SECONDS) < 2.0, "sedated for about %.0f s (%.1f)" % [CombatScript.SEDATE_SECONDS, cb.sedation_left(b)])
	await _seconds(3.0)
	_check(cb.is_sedated(b) and b.global_position.distance_to(Vector3(12.0, 0, 12.0)) < 3.0, "it stays down after the stun would have ended")

	# ---- friendly fire
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	await _frames(3)
	dummy.teleport(game._floor_at(Vector3(20.0, 0, 16.0)))
	dummy.invuln = 0.0
	await _frames(2)
	_give("bone_saw", 1)
	me.slots[1] = {"kind": "anesthetic", "count": 2}
	me.selected = 0
	var hp0 := dummy.hp
	await _use_on(dummy)
	_check(dummy.hp == hp0 - 1 and String(cb.last_result.get("what", "")) == "player", "the saw hits a teammate for one heart (%d -> %d)" % [hp0, dummy.hp])
	dummy.slots[0] = {"kind": "gauze", "count": 2}
	for i in me.slots.size():
		if me.slots[i].kind == "anesthetic":
			me.selected = i
	var v0 := _vials()
	await _seconds(CombatScript.JAB_COOLDOWN)
	await _use_on(dummy)
	_check(_vials() == v0 - 1 and dummy.stun > CombatScript.JAB_KNOCKOUT - 0.5, "a jab knocks a teammate out for ~8 s and uses a vial (stun %.1f, vials %d)" % [dummy.stun, _vials()])
	_check(dummy.hands_empty(), "the knocked-out teammate drops everything")
	var dpos := dummy.global_position
	dummy.bot_active = true
	dummy.bot_move = Vector2(0, -1)
	await _seconds(1.0)
	dummy.bot_move = Vector2.ZERO
	_check(dummy.global_position.distance_to(dpos) < 0.2, "knocked out, they cannot move")
	game.kill_player(dummy, "test")
	dev.remove_bot(did)
	await _frames(2)

	# ---- dragging
	_stand(b.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % bid
	await _frames(3)
	_check(me.aim_prompt.begins_with("!Empty your hands"), "dragging needs empty hands ('%s')" % me.aim_prompt)
	me.slots = Player.empty_slots()
	await _frames(3)
	_check(me.aim_prompt.begins_with("Hold E: drag the"), "a sedated monster offers to be dragged ('%s')" % me.aim_prompt)
	_check(game.find_interactable("mo_%d" % bid) != null and game.find_interactable("mo_%d" % bid).collision_layer == C.L_INTERACT, "its aim box is aimable")
	me.bot_interact = true
	await _seconds(0.5)
	_check(cb.dragging(me) < 0 and me.carry_hold > 0.3, "dragging is a hold (%.2f s so far)" % me.carry_hold)
	await _seconds(0.7)
	me.bot_interact = false
	_check(cb.dragging(me) == bid, "holding E for a second drags it")
	if "dragged_by" in b:
		_check(int(b.dragged_by) == me.peer_id, "the monster knows who drags it")
	await _frames(3)
	_check(game.find_interactable("mo_%d" % bid).collision_layer == 0, "a dragged monster is not aimable")
	# Walk speed with and without.
	_stand(Vector3(13.0, 0, 13.8), -PI / 2.0)
	await _frames(3)
	var start := me.global_position
	me.bot_move = Vector2(0, -1)
	await _seconds(1.0)
	me.bot_move = Vector2.ZERO
	var drag_walk := me.global_position.distance_to(start)
	await _frames(3)
	var back: Vector3 = b.global_position - me.global_position
	back.y = 0.0
	var fwd := -me.global_transform.basis.z
	_check(absf(back.length() - CombatScript.DRAG_BEHIND) < 0.25 and fwd.dot(back.normalized()) < -0.9, "the monster lies behind the dragger (%.2f m, dot %.2f)" % [back.length(), fwd.dot(back.normalized())])
	var pin: Transform3D = cb.monster_pin(b)
	_check(b.global_position.distance_to(pin.origin) < 0.3, "it sits at monster_pin (%.2f m off)" % b.global_position.distance_to(pin.origin))
	# Shove and drop do nothing.
	await _seconds(CombatScript.NOISE_HIT + 1.6)
	me.shove_count += 1
	me.drop_count += 1
	await _frames(3)
	_check(_noise_near(me.global_position, "shove", 4.0) == 0.0 and cb.dragging(me) == bid, "a dragger cannot shove or drop")
	me.bot_aim_id = ""
	cb.drop_dragged(me)
	await _frames(2)
	_stand(Vector3(13.0, 0, 13.8), -PI / 2.0)
	await _frames(3)
	start = me.global_position
	me.bot_move = Vector2(0, -1)
	await _seconds(1.0)
	me.bot_move = Vector2.ZERO
	var walk := me.global_position.distance_to(start)
	_check(drag_walk < walk * 0.65 and drag_walk > walk * 0.45, "dragging slows you to about 0.55 (%.2f m vs %.2f m)" % [drag_walk, walk])
	# E anywhere puts it down.
	_stand(b.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % bid
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	me.bot_aim_id = ""
	await _frames(2)
	_check(cb.dragging(me) == bid and me.aim_prompt.begins_with("Put the Discharged down"), "dragging again; the prompt says put it down ('%s')" % me.aim_prompt)
	me.bot_press += 1
	await _frames(3)
	_check(cb.dragging(me) < 0 and cb.is_sedated(b) and b.global_position.y < 0.3, "E away from a table puts it down, still sedated")

	# ---- strapping
	var ti: int = game.free_patient_table()
	_check(ti >= 0, "a free patient table (%d)" % ti)
	var tpos: Vector3 = game.table_position(ti)
	_stand(b.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % bid
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	_stand(tpos + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = game.table_interact_id(ti)
	await _frames(3)
	_check(me.aim_prompt.begins_with("Strap the Discharged") and me.aim_id == game.table_interact_id(ti), "a free patient table offers to strap it ('%s')" % me.aim_prompt)
	var left: float = cb.sedation_left(b)
	var n_cases: int = game.cases.size()
	me.bot_press += 1
	await _frames(3)
	var c: Dictionary = game.case_on_table(ti)
	var want_sed := lerpf(CombatScript.STRAP_SEDATION_MIN, 1.0, clampf(left / CombatScript.SEDATE_SECONDS, 0.0, 1.0))
	_check(not c.is_empty() and game.cases.size() == n_cases + 1, "strapping adds a case on table %d" % ti)
	if not c.is_empty():
		_check(String(c.patient_id) == "discharged" and String(c.ailment_id) == "dissection" and bool(c.get("monster", false)) and String(c.state) == "on_table" and int(c.table) == ti,
			"the case is the monster: %s" % str(c))
		var s := float(c.flags.get("sedation", -1.0))
		_check(s >= 0.35 and s <= 1.0 and absf(s - want_sed) < 0.03, "flags.sedation from the sedation left (%.2f, expected %.2f)" % [s, want_sed])
	_check(not game.monsters.has(bid) and cb.dragging(me) < 0, "the monster is gone from the game and nobody drags")
	await _frames(2)
	_check(not is_instance_valid(b), "its node is freed")
	_check(game.money == money0 and game.loop.pay_for(c, game.shift) == 0, "a strapped monster pays nothing by itself")

	# ---- a taken table, waking up while dragged, a hit dragger
	var c2 := await _sedated_monster(Vector3(15.0, 0, 13.0))
	_stand(c2.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % c2.monster_id
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	_check(cb.dragging(me) == c2.monster_id, "dragging a second monster")
	_stand(tpos + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = game.table_interact_id(ti)
	await _frames(3)
	_check(me.aim_id == "" and me.aim_prompt.contains("taken"), "a taken table does not offer to strap ('%s')" % me.aim_prompt)
	me.bot_press += 1
	await _frames(3)
	_check(cb.dragging(me) < 0 and game.monsters.has(c2.monster_id) and game.cases.size() == n_cases + 1, "E there puts it down instead, no second case")
	# Wake up while dragged.
	_stand(c2.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % c2.monster_id
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	me.bot_aim_id = ""
	_check(cb.dragging(me) == c2.monster_id, "dragging it again")
	me.bot_invulnerable = false
	await _frames(2)
	me.invuln = 0.0
	var hp1 := me.hp
	cb.set_sedation_left(c2, 0.3)
	await _seconds(0.8)
	_check(cb.dragging(me) < 0 and not cb.is_sedated(c2), "waking up while dragged drops it")
	_check(me.hp == hp1 - 1, "and it hits the dragger (hp %d -> %d)" % [hp1, me.hp])
	me.bot_invulnerable = true
	await _frames(2)
	game.kill_monster(c2)
	# Getting hit makes the dragger let go.
	var c3 := await _sedated_monster(Vector3(15.0, 0, 13.0))
	_stand(c3.global_position + Vector3(0, 0, 1.6), 0.0)
	me.bot_aim_id = "mo_%d" % c3.monster_id
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	me.bot_aim_id = ""
	_check(cb.dragging(me) == c3.monster_id, "dragging a third monster")
	game.damage_player(me, 1, "monster:test")
	await _frames(2)
	_check(cb.dragging(me) < 0 and cb.is_sedated(c3), "getting hit makes the dragger let go")
	_check(str(cb.net_state()).length() < 120, "combat's snapshot field stays small (%s)" % str(cb.net_state()))
	game.kill_monster(c3)
	await _frames(2)
	_check(cb.net_state().is_empty() or not cb.net_state().get("s", []).has(c3.monster_id if is_instance_valid(c3) else -99), "a killed monster leaves the sedated set")


# =========================================================================
# helpers
# =========================================================================

func _monster(kind: String, pos: Vector3) -> Node:
	var m = game._add_monster(kind, game._floor_at(pos))
	await _frames(3)
	_calm(m)
	return m


## A monster that stands still and ignores everything until something happens to it.
func _calm(m: Node) -> void:
	if m == null or not is_instance_valid(m):
		return
	if m.brain != null and "timer" in m.brain and int(m.mode) != MonsterScript.Mode.STUNNED:
		m.mode = MonsterScript.Mode.IDLE
		m.brain.timer = 999.0
	m.calm = 999.0


func _sedated_monster(pos: Vector3) -> Node:
	var m := await _monster("discharged", pos)
	var hands: Array = me.slots.duplicate(true)
	me.slots = Player.empty_slots()
	me.slots[0] = {"kind": "anesthetic", "count": 1}
	me.selected = 0
	_face(m)
	await _frames(2)
	game.player_shoved(me)
	await _frames(2)
	await _seconds(CombatScript.JAB_COOLDOWN)
	_face(m)
	await _use()
	_check(cb.is_sedated(m), "set-up: monster %d sedated" % m.monster_id)
	me.slots = Player.empty_slots()
	return m


func _give(kind: String, count: int) -> void:
	me.slots = Player.empty_slots()
	me.slots[0] = {"kind": kind, "count": count}
	me.selected = 0


func _vials() -> int:
	var n := 0
	for s in me.slots:
		if s.kind == "anesthetic":
			n += int(s.count)
	return n


## Stand 1.3 m from the target on the side it is, and look at its chest.
func _face(target: Node) -> void:
	var tp: Vector3 = target.global_position
	var from := me.global_position - tp
	from.y = 0.0
	from = from.normalized() if from.length() > 0.2 else Vector3.BACK
	me.teleport(game._floor_at(tp + from * 1.3))
	var lying: bool = not (target is Player) and cb.is_sedated(target)
	var chest := tp + Vector3.UP * (0.3 if lying else 1.1)
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var d := chest - eye
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)
	me.bot_move = Vector2.ZERO


func _use_on(target: Node) -> void:
	_face(target)
	await _frames(2)
	await _use()


## Press left mouse once; by default first waits out the host's cooldown from the previous use.
func _use(wait_cooldown := true) -> void:
	if wait_cooldown:
		while game.world_time < float(cb._cd.get(me.peer_id, -INF)):
			await get_tree().physics_frame
	cb.last_result = {}
	me.bot_use += 1
	await _frames(2)


func _noise_near(pos: Vector3, kind: String, radius: float) -> float:
	var best := 0.0
	for n in game.recent_noises(1.5):
		if String(n.kind) == kind and (n.pos as Vector3).distance_to(pos) <= radius:
			best = maxf(best, float(n.loudness))
	return best


func _stand(pos: Vector3, yaw := 0.0) -> void:
	me.teleport(game._floor_at(pos))
	me.bot_yaw = yaw
	me.bot_pitch = 0.0
	me.bot_move = Vector2.ZERO


func _check(ok: bool, what: String) -> void:
	print("[combattest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[combattest] ------------------------------------------")
	print("[combattest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame
