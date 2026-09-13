extends Node
## Headless play-through of a whole shift, the way a player would do it: clock in, find
## the supplies the case needs (opening containers on the way), carry them to the OR
## shelf, then operate step by step until the patient is stable.
##
##   godot --headless --path . tools/playtest.tscn -- [--god] [--seed=N] [--shifts=N]
##         [--skill=1.0] [--ailment=gunshot|amputation] [--patient=bob|seal]
##
## Exits 0 only if every requested shift reached the win screen.

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
		_say("t=%.0f hit, hp=%d" % [elapsed, bot.hp])
	last_hp = bot.hp
	if not bot.alive:
		_fail("the bot died at t=%.0f after %d hits" % [elapsed, hits])
		return

	match game.phase:
		Game.Phase.LOBBY:
			_lobby_forced = false
			_go_use("clock", game.clock_pos(), true)
		Game.Phase.SHIFT:
			if not _lobby_forced:
				_lobby_forced = true
				_force_case()
			if not game.case.is_empty() and int(game.case.step_index) != _last_step:
				_last_step = int(game.case.step_index)
				_say("t=%.0f case %s/%s step %d vitals %.0f shelf %s" % [elapsed, game.case.patient_id, game.case.ailment_id, _last_step, game.vitals, str(game.shelf)])
			if not god and _flee_if_hunted():
				return
			_play_shift(delta)
		Game.Phase.WON:
			shifts_won += 1
			_say("t=%.0f WON shift %d (vitals %.0f, %d hits)" % [elapsed, game.shift, game.vitals, hits])
			if shifts_won >= want_shifts:
				_finish(true)
			else:
				set_physics_process(false)
				await get_tree().create_timer(C.END_SCREEN_SECONDS + 0.5).timeout
				set_physics_process(true)
		Game.Phase.LOST:
			_fail("lost at t=%.0f: %s" % [elapsed, game.message])


## Tests can pin the case so both ailments and both patients get covered.
func _force_case() -> void:
	if force_ailment == "" and force_patient == "":
		return
	if force_ailment != "":
		game.case.ailment_id = force_ailment
	if force_patient != "":
		game.case.patient_id = force_patient
	game.shelf = {}
	game._apply_case_locally()
	game._clear_items()
	game._spawn_supplies()


func _play_shift(delta: float) -> void:
	if game.case.is_empty():
		return
	_log_timer -= delta
	var need := Procedures.remaining_requirements(game.case.ailment_id, int(game.case.step_index))
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
	for i in 2:
		var s: Dictionary = bot.slots[i]
		if s.kind != "" and short.has(s.kind):
			bot.selected = i
			_go_use("shelf", game.shelf_node.global_position, false)
			return

	if short.is_empty():
		# Everything is on the shelf: operate.
		if "bot_skill" in game.surgery:
			game.surgery.bot_skill = skill
		_go_use("table", game.table_pos(), false)
		return

	# Hands full of things we do not need: set one down.
	if not bot.can_take(short.keys()[0]):
		bot.selected = 0
		bot.drop_count += 1
		return

	# Find the nearest stack of something still short.
	var best: Node = null
	var best_d := INF
	for it in game.world_items.values():
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
	if best.state == WorldItem.State.IN_CONTAINER:
		var ct := game.find_interactable(best.container_id)
		if ct != null and ct.has_method("is_open") and not ct.is_open():
			_go_use(best.container_id, ct.global_position, false)
			return
	_go_use("it_%d" % best.item_id, best.global_position, false)


## Walk within reach of a target, look at it, and press (or hold) E.
func _go_use(id: String, pos: Vector3, hold: bool) -> void:
	var flat := Vector3(pos.x, bot.global_position.y, pos.z)
	var d := bot.global_position.distance_to(flat)
	bot.bot_aim_id = id
	if d > REACH:
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
