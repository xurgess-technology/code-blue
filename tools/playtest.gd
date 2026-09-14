extends Node
## Headless play-through of whole shifts, the way a player would do it (sweep 2 loop): walk to
## the time clock and clock in, wait out the grace period, answer the break-room phone, find
## the supplies the case needs (opening containers on the way) while the paramedics wheel the
## patient in, carry them to the OR shelf, operate step by step until every patient is stable,
## then clock out and get paid.
##
##   godot --headless --fixed-fps 60 --path . tools/playtest.tscn -- [--god] [--seed=N] [--shifts=N]
##         [--skill=1.0] [--ailment=gunshot|amputation] [--patient=bob|seal] [--extra]
##         [--skip-grace]
##
## `--extra` answers the mid-shift call and saves the extra patient too (otherwise it is declined).
## Exits 0 only if every requested shift was clocked out with every accepted patient stable.

const MAX_SECONDS := 1500.0
const REACH := 1.9

var main: Node3D
var game: Game
var bot: Player

var god := false
var skill := 1.0
var want_shifts := 1
var fixed_seed := 12345
var force_ailment := ""
var force_patient := ""

var elapsed := 0.0
var hits := 0
var last_hp := 3
var shifts_won := 0
var _path := PackedVector3Array()
var _repath := 0.0
var _goal := Vector3.INF
var _press_cooldown := 0.0
var _finished := false
var _lobby_forced := false
var _log_timer := 0.0
var _last_step := -1
var _stuck_timer := 0.0
var _last_pos := Vector3.ZERO
var _blacklist := {}
var _heartbeat := 30.0
var _beat_pos := Vector3.INF   # DOORS: where the bot was at the last heartbeat
var _target_item := -1
var _stare_t := 0.0
var _shove_ready := 0.0
var take_extra := false
var skip_grace := false
var _was_phase := -1
var _money_before := 0
var _logged_call := ""
var _extra_seen := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"god": god = true
			"skill": skill = float(v)
			"shifts": want_shifts = int(v)
			"seed": fixed_seed = int(v)
			"ailment": force_ailment = v
			"patient": force_patient = v
			"extra": take_extra = true
			"skip-grace": skip_grace = true

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Bot")
	game.start_session(fixed_seed)
	await get_tree().process_frame
	bot = game.local_player()
	if bot == null:
		_fail("no local player was created")
		return
	bot.bot_active = true
	bot.bot_invulnerable = god
	last_hp = bot.hp
	_say("level=%s containers=%d anchors=%d shelf=%s lectern=%s surgery=%s" % [
		"fallback" if game.level_info.get("fallback", false) else "generated",
		game.level_info.get("containers", []).size(), game.level_info.get("loose_anchors", []).size(),
		str(game.level_info.has("shelf")), str(game.level_info.has("lectern")),
		"real" if "bot_skill" in game.surgery else "stub"])


func _physics_process(delta: float) -> void:
	if _finished or bot == null or game == null:
		return
	elapsed += delta
	_press_cooldown = maxf(0.0, _press_cooldown - delta)
	if elapsed > MAX_SECONDS:
		_fail("timed out after %ds (phase=%d)" % [int(elapsed), game.phase])
		return
	if bot.hp < last_hp:
		hits += 1
		var by := "?"
		var near := INF
		for m in game.monsters.values():
			var md: float = m.global_position.distance_to(bot.global_position)
			if md < near:
				near = md
				by = "%s (%s, %.1f m)" % [m.kind, Monster.State.keys()[m.state], md]
		_say("t=%.0f hit by %s, hp=%d" % [elapsed, by, bot.hp])
	last_hp = bot.hp
	if bot.downed:
		# Solo, nobody can carry you to the table: the shift is lost (all_players_out).
		_fail("the bot went down at t=%.0f after %d hits (bleeding out, alive=%s)" % [elapsed, hits, str(bot.alive)])
		return
	if not bot.alive:
		_fail("the bot died at t=%.0f after %d hits" % [elapsed, hits])
		return

	var entered := game.phase != _was_phase
	_was_phase = game.phase
	match game.phase:
		Game.Phase.LOBBY:
			if entered:
				_force_case()
				_money_before = game.money
			_go_use("clock", game.clock_pos(), true)
		Game.Phase.SHIFT:
			if entered and skip_grace:
				game.dev_skip_grace()
			_log_cases()
			if not god and _flee_if_hunted():
				return
			if _handle_phone():
				return
			if game.loop.can_clock_out() and not (take_extra and not game.loop.extra_done):
				for c in game.cases:
					if String(c.state) == "dead":
						_fail("%s died at t=%.0f" % [c.patient_id, elapsed])
						return
				_go_use("clock", game.clock_pos(), true)
				return
			_play_shift(delta)
		Game.Phase.WON:
			if not entered:
				return
			shifts_won += 1
			_say("t=%.0f CLOCKED OUT of shift %d: %s money $%d -> $%d (%d hits)" % [elapsed, game.shift, game.loop.pay_note, _money_before, game.money, hits])
			if game.money <= _money_before:
				_fail("clocked out without being paid")
				return
			if take_extra:
				_say("extra patient this shift: %s" % ("saved" if _extra_seen else "missed the call"))
			_extra_seen = false
			if shifts_won >= want_shifts:
				_finish(true)
		Game.Phase.LOST:
			_fail("game over at t=%.0f: %s" % [elapsed, game.message])


## Tests can pin the case so both ailments and both patients get covered: the first call brings
## exactly that patient.
func _force_case() -> void:
	if force_ailment == "" and force_patient == "":
		return
	var roll := Procedures.roll(game.seed_value, game.shift)
	game.loop.force_first = {"patient_id": force_patient if force_patient != "" else roll.patient,
		"ailment_id": force_ailment if force_ailment != "" else roll.ailment}


func _log_cases() -> void:
	var sig := "%s|%s" % [game.loop.call_state, game.loop.call_kind]
	if sig != _logged_call:
		_logged_call = sig
		_say("t=%.0f phone %s %s" % [elapsed, game.loop.call_state if game.loop.call_state != "" else "quiet", game.loop.call_kind])
	var steps := 0
	for c in game.cases:
		steps += int(c.step_index) * 10 + (1 if String(c.state) == "on_table" else 0) + (100 if String(c.state) == "stable" else 0)
		if bool(c.get("optional", false)) and String(c.state) == "stable":
			_extra_seen = true
	steps += game.cases.size() * 1000
	if steps != _last_step:
		_last_step = steps
		var parts := []
		for c in game.cases:
			parts.append("%s/%s t%d %s step %d vit %.0f" % [c.patient_id, c.ailment_id, int(c.table), c.state, int(c.step_index), float(c.vitals)])
		_say("t=%.0f cases: %s | shelf %s" % [elapsed, "; ".join(parts), str(game.shelf)])


## Answer the ringing phone when it is the first call, or the extra one with --extra. True while
## walking to it.
func _handle_phone() -> bool:
	if game.loop.call_state != "ringing" or game.loop.phone == null or bot.operating:
		return false
	if game.loop.call_kind == "extra" and not take_extra:
		return false
	_go_use("phone", game.loop.phone.global_position, false)
	return true


func _play_shift(delta: float) -> void:
	_log_timer -= delta
	var need: Dictionary = game._live_requirements()
	if need.is_empty() and not bot.operating:
		bot.bot_move = Vector2.ZERO
		return
	var short := {}
	for kind in need.keys():
		var s: int = int(need[kind]) - game.shelf_count(kind)
		if s > 0:
			short[kind] = s

	# Already operating: let the surgery system (and its bot input) do the work.
	if bot.operating:
		bot.bot_move = Vector2.ZERO
		bot.bot_interact = false
		return

	# Carrying something the shelf still needs: deliver it.
	for i in bot.slots.size():
		var s: Dictionary = bot.slots[i]
		if s.kind != "" and short.has(s.kind):
			bot.selected = i
			_go_use("shelf", game.shelf_node.global_position, false)
			return

	if short.is_empty():
		# Everything is on the shelf: operate on a patient who is on a table.
		game.surgery_bot_skill = skill
		for c in game.cases:
			if String(c.state) == "on_table" and String(c.patient_id) != "player":
				_go_use(game.table_interact_id(int(c.table)), game.table_position(int(c.table)), false)
				return
		bot.bot_move = Vector2.ZERO   # the patient is still on the way
		return

	# Hands full of things we do not need: set one down (the first slot holding a stack).
	if not bot.can_take(short.keys()[0]):
		for i in bot.slots.size():
			if String(bot.slots[i].kind) != "":
				bot.selected = i
				break
		bot.drop_count += 1
		return

	# Find the nearest stack of something still short. Keep the one already chosen while it is
	# still wanted: re-picking every frame made the bot dither between two equidistant stacks.
	var best: Node = null
	var best_d := INF
	var kept = game.world_items.get(_target_item)
	if kept != null and is_instance_valid(kept) and short.has(kept.kind) and not _blacklist.has(_target_item):
		best = kept
		best_d = -1.0
	for it in game.world_items.values():
		if best_d < 0.0:
			break
		if not short.has(it.kind) or _blacklist.has(it.item_id):
			continue
		var d: float = it.global_position.distance_to(bot.global_position)
		if d < best_d:
			best_d = d
			best = it
	if best == null:
		if _log_timer <= 0.0:
			_log_timer = 5.0
			_say("t=%.0f nothing left to fetch for %s, waiting for the supply guard" % [elapsed, str(short)])
		bot.bot_move = Vector2.ZERO
		return
	_target_item = best.item_id
	if best.state == WorldItem.State.IN_CONTAINER:
		var ct := game.find_interactable(best.container_id)
		if ct != null and ct.has_method("is_open") and not ct.is_open():
			_go_use(best.container_id, ct.global_position, false)
			return
	_go_use("it_%d" % best.item_id, best.global_position, false)


## Walk within reach of a target, look at it, and press (or hold) E.
func _go_use(id: String, pos: Vector3, hold: bool) -> void:
	_heartbeat -= 1.0 / 60.0
	if _heartbeat <= 0.0:
		_heartbeat = 30.0
		_say("t=%.0f heading for %s at %s, bot at %s, hands %s, aim '%s'" % [elapsed, id, str(pos.snappedf(0.1)),
			str(bot.global_position.snappedf(0.1)), str(bot.slots.map(func(s): return s.kind)), bot.aim_id])
		# DOORS: when the bot has not moved since the last heartbeat, say what is around it.
		if bot.global_position.distance_to(_beat_pos) < 0.3 and game.get("doors") != null:
			for d in game.doors.near(bot.global_position):
				if (d.global_position as Vector3).distance_to(bot.global_position) < 4.0:
					_say("    near %s %s amount %.2f target %.2f halted %s" % [d.kind, d.door_id, d.amount, d.target, str(d.halted)])
			for m in game.monsters.values():
				if m.global_position.distance_to(bot.global_position) < 6.0:
					_say("    monster %s mode %d at %.1f m" % [m.kind, m.mode, m.global_position.distance_to(bot.global_position)])
			_say("    path %s next %s stuck %.1f" % [str(_path.size()), str(_path[0].snappedf(0.1) if _path.size() > 0 else Vector3.ZERO), _stuck_timer])
		_beat_pos = bot.global_position
	var flat := Vector3(pos.x, bot.global_position.y, pos.z)
	var d := bot.global_position.distance_to(flat)
	bot.bot_aim_id = id
	# The navmesh can keep the bot just beyond REACH of something against a wall; once it has
	# stopped getting closer, use the game's own reach rule instead.
	var close_enough := d <= REACH
	if not close_enough and _stuck_timer > 1.5:
		var node := game.find_interactable(id)
		close_enough = node != null and game._within_reach(bot, node) and d < C.INTERACT_RANGE
	if not close_enough:
		bot.bot_interact = false
		_walk_to(pos)
		_watch_stuck(id)
		return
	bot.bot_move = Vector2.ZERO
	_stuck_timer = 0.0
	var to := pos - bot.global_position
	bot.bot_yaw = atan2(-to.x, -to.z)
	if hold:
		bot.bot_interact = true
	elif _press_cooldown <= 0.0 and bot.aim_id == id:
		bot.bot_press += 1
		_press_cooldown = 0.5


func _watch_stuck(id: String) -> void:
	if bot.global_position.distance_to(_last_pos) > 0.05:
		_last_pos = bot.global_position
		_stuck_timer = 0.0
		return
	_stuck_timer += 1.0 / 60.0
	if _stuck_timer > 6.0 and id.begins_with("it_"):
		_blacklist[int(id.substr(3))] = true
		_say("t=%.0f could not reach %s, skipping it" % [elapsed, id])
		_stuck_timer = 0.0


func _walk_to(target: Vector3) -> void:
	if target.distance_to(_goal) > 0.5:
		_goal = target
		_repath = 0.0
	_repath -= 1.0 / 60.0
	var map := get_viewport().world_3d.navigation_map
	if _repath <= 0.0:
		_repath = 0.5
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			var goal_on_nav := NavigationServer3D.map_get_closest_point(map, target)
			_path = NavigationServer3D.map_get_path(map, bot.global_position, goal_on_nav, true)
	var next := target
	for p in _path:
		if Vector2(p.x - bot.global_position.x, p.z - bot.global_position.z).length() > 0.7:
			next = p
			break
	var to_next := next - bot.global_position
	to_next.y = 0.0
	if to_next.length() < 0.05:
		bot.bot_move = Vector2.ZERO
		return
	bot.bot_yaw = atan2(-to_next.x, -to_next.z)
	bot.bot_move = Vector2(0, -1)
	bot.bot_sprint = false


func _flee_if_hunted() -> bool:
	return _shove_close_walk_in() or _stare_down_nurse() or _flee_discharged()


## Sweep 3: Walk-Ins crowd the wing entrances the bot walks through. Any awake one within arm's
## reach (calm after a hit or not; they come straight back) gets shoved off, like a player would.
func _shove_close_walk_in() -> bool:
	if bot.operating:
		return false
	for m in game.monsters.values():
		if m.kind != "walk_in" or m.mode == Monster.Mode.STUNNED or (m.has_method("is_sedated") and m.is_sedated()):
			continue
		var to: Vector3 = m.global_position - bot.global_position
		to.y = 0.0
		if to.length() > 2.2:
			continue
		# DOORS: one on the other side of a shut door (or a wall) is not within reach.
		var los := PhysicsRayQueryParameters3D.create(bot.head.global_position, m.global_position + Vector3.UP * 1.2)
		los.collision_mask = C.L_WORLD
		if not bot.get_world_3d().direct_space_state.intersect_ray(los).is_empty():
			continue
		bot.bot_yaw = atan2(-to.x, -to.z)
		bot.bot_move = Vector2.ZERO
		bot.bot_interact = false
		# HANDS HOOK: a tap on the shove: hold it a moment, let go (the wind-up fires on release).
		if bot.bot_charge:
			bot.bot_charge = false
		elif elapsed >= _shove_ready:
			_shove_ready = elapsed + C.SHOVE_COOLDOWN + 0.3
			bot.bot_charge = true
		return true
	bot.bot_charge = false
	return false


## The Night Nurse only moves while nobody watches her in light: face her with the flashlight
## on and back away, the way a player would.
func _stare_down_nurse() -> bool:
	if bot.operating:
		return false
	var nurse: Node = null
	var best := 9.0
	for m in game.monsters.values():
		if m.kind != "night_nurse" or m.calm > 0.0:
			continue
		var d: float = m.global_position.distance_to(bot.global_position)
		if d < best:
			best = d
			nurse = m
	if nurse == null:
		_stare_t = 0.0
		return false
	var q := PhysicsRayQueryParameters3D.create(bot.head.global_position, nurse.global_position + Vector3.UP * 1.4)
	q.collision_mask = C.L_WORLD
	if not bot.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
		return false
	_stare_t += 1.0 / 60.0
	if _stare_t > 12.0:
		# Look away for a few seconds now and then so the shift still moves on.
		if _stare_t > 15.0:
			_stare_t = 0.0
		return false
	var to: Vector3 = nurse.global_position - bot.global_position
	bot.flashlight_on = true
	bot.bot_yaw = atan2(-to.x, -to.z)
	bot.bot_pitch = -0.1
	bot.bot_move = Vector2(0, 1) if best < 5.0 else Vector2.ZERO
	bot.bot_sprint = false
	bot.bot_interact = false
	return true


func _flee_discharged() -> bool:
	var threat: Node = null
	var best := 1e9
	for m in game.monsters.values():
		if m.state != Monster.State.CHASE or m.calm > 0.0:
			continue
		var d: float = m.global_position.distance_to(bot.global_position)
		if d < best:
			best = d
			threat = m
	if threat == null or best > 6.0 or bot.operating:
		bot.bot_sprint = false
		return false
	var away: Vector3 = bot.global_position - threat.global_position
	away.y = 0.0
	bot.bot_yaw = atan2(-away.x, -away.z)
	bot.bot_move = Vector2(0, -1)
	bot.bot_sprint = true
	bot.bot_interact = false
	return true


func _say(line: String) -> void:
	print("[playtest] ", line)


func _fail(reason: String) -> void:
	_say("FAIL: " + reason)
	_finish(false)


func _finish(ok: bool) -> void:
	if _finished:
		return
	_finished = true
	print("[playtest] ------------------------------------------")
	print("[playtest] result=%s shifts_won=%d elapsed=%.0fs hits=%d" % ["PASS" if ok else "FAIL", shifts_won, elapsed, hits])
	get_tree().quit(0 if ok else 1)
