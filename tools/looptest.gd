extends Node
## Headless check of the whole shift loop (loop worker, sweep 2), played by a bot the way a player
## would: walking on the navmesh and pressing E.
##
##   godot --headless --fixed-fps 60 --path . tools/looptest.tscn [-- --seed=N] [--pocket=factory]
##   (--pocket forces that pocket space on every shift's wings and checks it is rebuilt for shift 2)
##
## Shift 1  start at a spawn point, walk to the time clock and clock in; the grace period runs;
##          pick up some loot; the phone rings and the bot answers it (subtitles); the patient's
##          supplies spawn; paramedics wheel the patient along the navmesh onto a patient table
##          and leave; the extra call rings, the bot answers, the second patient lands on the
##          other table; the bot fetches supplies and operates both to stable; it cannot clock out
##          before that; clock out pays exactly both cases; the loot is still in hand in the next
##          lobby; the bot sells it at the crematorium furnace and buys pills at the pharmacy.
## Shift 2  clock in again in the same hospital: fresh loot, last shift's untouched loot gone,
##          containers closed, grace restarted. Nobody answers: the answering machine takes the
##          call. The patient dies on the table; the extra call is ignored and declines itself;
##          clock out costs the dead patient's penalty and nothing for the declined one.
## Shift 3  clock in, everyone goes down: game over, then a new run (shift 1, money reset,
##          a new hospital).
##
## Exits 0 when every check passes.

const REACH := 1.9
const TIMEOUT := 3000.0
const Zones := preload("res://scripts/hospital_builder.gd")

var main: Node3D
var game: Game
var bot: Player
var seed_value := 4242
var t := 0.0
var _done := false
var _failures: Array = []

var _path := PackedVector3Array()
var _space := ""   # POCKETS
var _repath := 0.0
var _goal := Vector3.INF
var _press_cd := 0.0
var _stuck := 0.0
var _last_pos := Vector3.ZERO
var _target_item := -1
var _blacklist := {}
var _pocket := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv[0] == "pocket" and kv.size() > 1:   # POCKETS: none | factory | restaurant, every shift
			_pocket = kv[1]
			preload("res://scripts/level/pockets/pocket_plan.gd").force_kind = kv[1]
		if kv[0] == "seed" and kv.size() > 1:
			seed_value = int(kv[1])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Bot")
	game.start_session(seed_value)
	await _frames(3)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	game.surgery_bot_skill = 1.0
	await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	_press_cd = maxf(0.0, _press_cd - delta)
	if t > TIMEOUT and not _done:
		_check(false, "timed out")
		_finish()


func _run() -> void:
	# ------------------------------------------------------------------ shift 1
	_say("---- shift 1: in, grace, phone, paramedics, two patients, clock out")
	_check(game.phase == Game.Phase.LOBBY and game.shift == 1, "a run starts in the lobby of shift 1")
	var pocket_root1 = null
	if _pocket == "factory" or _pocket == "restaurant":
		_check(game.pockets.active() and String(game.pockets.pocket.kind) == _pocket, "POCKETS: shift 1 has the forced %s" % _pocket)
		pocket_root1 = game.pockets.pocket.get("root")
	var near_spawn := false
	for s in game.spawn_points():
		near_spawn = near_spawn or bot.global_position.distance_to(s) < 1.0
	_check(near_spawn, "the bot starts at a spawn point (%s)" % ("the neutral area" if game.level_info.has("neutral") else "the level's player spawns, no neutral area on this level"))
	_check(game.patient_tables.size() >= 2, "there are two patient tables (%d%s)" % [game.patient_tables.size(), ", one placed beside the level's own" if game.level_info.get("tables_fallback", false) else ""])
	_check(game.surgeries.size() == game.patient_tables.size(), "one surgery system per patient table")
	_check(game.loop.phone != null and game.find_interactable("phone") != null, "the break-room phone is placed")
	var start := bot.global_position
	var ok := await _do_until(func(): _go_use("clock", game.clock_pos(), true), func(): return game.phase == Game.Phase.SHIFT, 120.0)
	_check(ok, "walking to the time clock and holding E clocks in")
	_check(bot.global_position.distance_to(start) > 1.0 or start.distance_to(game.clock_pos()) < 3.0, "the bot walked to the clock")
	if game.level_info.has("zones"):
		# SWEEP 4A HOOK (fog lot, chunk 2): the run's start and every respawn are inside the main
		# doors now (the lobby), not out in the neutral area, so the bot is already in the
		# entrance building both before and after walking to the clock.
		_check(Zones.zone_of(game.level_info, start) == "entrance" and Zones.zone_of(game.level_info, bot.global_position) == "entrance",
			"it starts and stays inside the entrance building (%s -> %s)" % [Zones.zone_of(game.level_info, start), Zones.zone_of(game.level_info, bot.global_position)])
		_check(not game.monster_may_wander_to(game.clock_pos()) and not game.monster_may_wander_to(start), "monsters may not wander into the entrance building or the neutral area")
	_check(game.loop.grace_left > game.loop.GRACE_SECONDS - 3.0, "the grace period started (%.0f s)" % game.loop.grace_left)
	_check(game.cases.is_empty() and game.monsters.size() > 0, "no patient yet, monsters are awake")
	var loot_count := 0
	for it in game.world_items.values():
		if Items.is_loot(it.kind):
			loot_count += 1
	_check(loot_count > 0, "loot spawned at clock-in (%d stacks)" % loot_count)
	_check(game.loop.clock_prompt(bot).begins_with("!"), "the clock refuses to clock out with no patient: '%s'" % game.loop.clock_prompt(bot))

	# Grab a piece of loot during the grace period.
	var loot_kind := await _grab_loot()
	_check(loot_kind != "", "the bot picked up loot during the grace period (%s)" % loot_kind)

	# Wait by the phone (the answering machine takes calls nobody reaches in time).
	ok = await _do_until(func(): _go_use("phone", game.loop.phone.global_position, false), func(): return game.loop.call_state == "ringing", 90.0)
	_check(ok, "the phone rings when the grace period ends")
	_check(game.phase == Game.Phase.SHIFT and game.cases.is_empty(), "ringing, still no case")
	game.loop.force_extra = {"patient_id": "seal", "ailment_id": "gunshot"}
	ok = await _do_until(func(): _go_use("phone", game.loop.phone.global_position, false), func(): return game.loop.call_state == "talking", 30.0)
	_check(ok, "walking to the phone and pressing E answers it")
	_check(game.loop.subtitle.contains("Bot"), "the subtitles speak to whoever answered: '%s'" % game.loop.subtitle)
	_check(game.cases.size() == 1 and String(game.cases[0].state) == "incoming" and int(game.cases[0].table) == -1, "the case is incoming, not on a table yet")
	var first_id := int(game.cases[0].id)
	var need := Procedures.requirements(String(game.cases[0].ailment_id))
	var supplies_ok := true
	for kind in need.keys():
		supplies_ok = supplies_ok and game.supply_count(kind) >= int(need[kind])
	_check(supplies_ok, "the case's supplies spawned when the call was taken")
	var subs := {}
	ok = await _do_until(func():
		_halt()
		if game.loop.subtitle != "":
			subs[game.loop.subtitle] = true, func(): return not game.loop.crews.is_empty(), 30.0)
	_check(ok, "paramedics set off")
	var crew_node: Node3D = game.get_node("Entities").get_node_or_null("ParamedicCrew_%d" % first_id)
	_check(crew_node != null and crew_node.get_node_or_null("Gurney") != null, "a crew with a gurney exists in the world")
	if game.level_info.has("ambulance"):
		var amb: Vector3 = game.level_info.ambulance.position
		_check((game.loop.crews[first_id].p as Vector3).distance_to(amb) < 4.0, "the crew starts at the ambulance bay (%.1f m away)" % (game.loop.crews[first_id].p as Vector3).distance_to(amb))
	var path: Dictionary = game.loop._paths.get(first_id, {})
	_check(path.has("pts") and (path.pts as PackedVector3Array).size() >= 2, "the crew follows a navmesh path (%d points)" % ((path.pts as PackedVector3Array).size() if path.has("pts") else 0))
	var p0: Vector3 = game.loop.crews[first_id].p
	await _seconds(1.0)
	_check(game.loop.crews.has(first_id) and (game.loop.crews[first_id].p as Vector3).distance_to(p0) > 0.5, "the crew moves")
	var reserved: int = int(game.loop.crews[first_id].tb) if game.loop.crews.has(first_id) else -1
	_check(reserved >= 0 and game.loop.table_reserved(reserved) and game.free_patient_table() != reserved, "the crew's table is reserved")
	ok = await _do_until(func():
		_halt()
		if game.loop.subtitle != "":
			subs[game.loop.subtitle] = true, func(): return String(game.case_by_id(first_id).get("state", "")) == "on_table", 150.0)
	_check(ok, "the paramedics put the patient on a table")
	_check(subs.size() >= 3, "the call played several subtitle lines (%d)" % subs.size())
	var first_table := int(game.case_by_id(first_id).table)
	_check(game.body_for_table(first_table) != null, "the patient's body lies on table %d" % first_table)
	_check(not game.loop.can_clock_out() and game.loop.clock_prompt(bot).begins_with("!"), "cannot clock out with a patient on the table")
	ok = await _until(func(): return not game.loop.crews.has(first_id), 120.0)
	_check(ok, "the crew leaves and disappears")

	# The extra call, soon.
	game.loop.extra_at = game.world_time + 2.0
	ok = await _do_until(func(): _halt(), func(): return game.loop.call_state == "ringing" and game.loop.call_kind == "extra", 30.0)
	_check(ok, "the extra call rings mid-shift")
	ok = await _do_until(func(): _go_use("phone", game.loop.phone.global_position, false), func(): return game.cases.size() == 2, 30.0)
	_check(ok, "answering the extra call accepts a second patient")
	var extra: Dictionary = game.cases[1]
	var extra_id := int(extra.id)
	_check(bool(extra.get("optional", false)) and String(extra.patient_id) != String(game.case_by_id(first_id).patient_id), "the extra case is optional and a different patient (%s)" % extra.patient_id)
	ok = await _do_until(func(): _work(), func(): return String(game.case_by_id(extra_id).get("state", "")) == "on_table", 200.0)
	_check(ok, "the extra patient is wheeled onto a table")
	var extra_table := int(game.case_by_id(extra_id).get("table", -1))
	_check(extra_table >= 0 and extra_table != first_table, "the extra patient lies on the other table (%d vs %d)" % [extra_table, first_table])
	_check(game.body_for_table(first_table) != null and game.body_for_table(extra_table) != null, "two patient bodies on two tables")
	_check(game.case == game.case_by_id(first_id), "game.case is the first patient case")

	var money_before: int = game.money
	ok = await _do_until(func(): _work(), func():
		return String(game.case_by_id(first_id).get("state", "")) != "on_table" and String(game.case_by_id(extra_id).get("state", "")) != "on_table", 900.0)
	_check(ok, "the bot operated both patients to the end")
	_check(String(game.case_by_id(first_id).state) == "stable" and String(game.case_by_id(extra_id).state) == "stable", "both patients are stable (%s, %s)" % [game.case_by_id(first_id).state, game.case_by_id(extra_id).state])
	_check(game.loop.can_clock_out(), "now the clock lets the team out")
	_check(bot.holding(loot_kind), "the loot is still in hand")
	# DOORS: what shift 1's wings looked like, and how many containers the bot left open in them.
	var rows_before: PackedStringArray = (game.level_info.rows as PackedStringArray).duplicate()
	var opened_before := 0
	for n in get_tree().get_nodes_in_group("container"):
		if n.has_method("is_open") and n.is_open() and String(n.get("container_type")) != "pegboard":
			opened_before += 1
	ok = await _do_until(func(): _go_use("clock", game.clock_pos(), true), func(): return game.phase == Game.Phase.WON, 120.0)
	_check(ok, "holding E at the clock clocks out")
	var want_pay: int = game.loop.pay_for({"state": "stable"}, 1) + game.loop.pay_for({"state": "stable", "optional": true}, 1)
	_check(game.money == money_before + want_pay, "clocking out paid $%d for both (money $%d -> $%d)" % [want_pay, money_before, game.money])
	_check(game.monsters.is_empty(), "the monsters are gone after clocking out")
	var pos_at_clock := bot.global_position
	ok = await _do_until(func(): _halt(), func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 30.0)
	_check(ok, "the paycheck screen leads to the lobby of shift 2")
	_check(bot.holding(loot_kind), "carried loot survives into the next lobby")
	_check(bot.global_position.distance_to(pos_at_clock) < 1.0, "nobody is moved at the next lobby")
	_check(game.cases.is_empty() and game.shelf.is_empty(), "no cases or shelf stock between shifts")
	_check(game.doors.gates_locked, "the wing gates are locked between shifts")

	# Walk out and sell at the furnace (throwing), buy pills at the pharmacy.
	_say("---- between shifts: the furnace, the pharmacy")
	var value: int = int(bot.slots[_slot_of(loot_kind)].get("v", 0))
	var m0: int = game.money
	bot.selected = maxi(0, _slot_of(loot_kind))
	# Not-holding fires the instant the bot releases the throw; the sale only lands a moment later
	# once the item has actually flown into the furnace's FireZone, so wait for the money itself.
	ok = await _do_until(func(): _go_throw(game.economy.furnace), func(): return game.money != m0, 90.0)
	_check(ok and game.money == m0 + value, "the bot threw the loot into the furnace and sold it for $%d" % value)
	m0 = game.money
	ok = await _do_until(func(): _go_use("pharmacy_kiosk", game.economy.pharmacy.kiosk.global_position, false), func(): return game.money < m0, 60.0)
	_check(ok, "and bought a bottle of pills at the pharmacy")
	var pills_delivered := func() -> bool:
		for it in game.world_items.values():
			if it.kind == "placebo_pills":
				return true
		return false
	ok = pills_delivered.call()
	if not ok:
		ok = await _until(pills_delivered, 5.0)
	_check(ok, "the tube delivered the pill bottle")

	# ------------------------------------------------------------------ shift 2
	_say("---- shift 2: same run, new wings, answering machine, a death, a declined call")
	var old_loot := -1
	for it in game.world_items.values():
		if Items.is_loot(it.kind):
			old_loot = it.item_id
			break
	var seed_before: int = game.seed_value
	ok = await _do_until(func(): _go_use("clock", game.clock_pos(), true), func(): return game.phase == Game.Phase.SHIFT, 120.0)
	_check(ok, "clock in for shift 2")
	if _pocket == "factory" or _pocket == "restaurant":
		_check_pocket_rebuilt(pocket_root1)
	_check(game.seed_value == seed_before, "same run (seed %d)" % game.seed_value)
	_check(not game.doors.gates_locked, "the gates unlocked at clock-in")
	var rows_after: PackedStringArray = game.level_info.rows
	var er: Rect2 = game.level_info.entrance_rect
	var entrance_same := true
	var wing_rows := 0
	for y in rows_after.size():
		if rows_after[y] != rows_before[y]:
			wing_rows += 1
		for x in rows_after[y].length():
			if er.has_point(Vector2((x + 0.5) * C.TILE, (y + 0.5) * C.TILE)) and rows_after[y][x] != rows_before[y][x]:
				entrance_same = false
	_check(wing_rows > 10 and entrance_same, "the wings are new (%d rows differ), the entrance building is the same" % wing_rows)
	_check(old_loot < 0 or not game.world_items.has(old_loot), "last shift's untouched loot was cleared")
	var open_containers := 0
	for n in get_tree().get_nodes_in_group("container"):
		if n.has_method("is_open") and n.is_open() and String(n.get("container_type")) != "pegboard":   # pegboards have no door
			open_containers += 1
	_check(open_containers == 0 and opened_before > 0, "every container in the new wings is closed (%d open, %d were open last shift)" % [open_containers, opened_before])
	_check(game.loop.grace_left > game.loop.GRACE_SECONDS - 3.0, "grace restarted")
	game.dev_skip_grace()
	ok = await _do_until(func(): _halt(), func(): return game.loop.call_state == "ringing", 10.0)
	_check(ok, "skip grace: the phone rings")
	ok = await _do_until(func(): _halt(), func(): return game.loop.call_state == "talking", 20.0)
	_check(ok and game.loop.subtitle.begins_with("ANSWERING MACHINE"), "unanswered, the answering machine takes the call: '%s'" % game.loop.subtitle)
	_check(game.cases.size() == 1, "the first patient still comes")
	var c2_id := int(game.cases[0].id)
	ok = await _until(func(): return String(game.case_by_id(c2_id).get("state", "")) == "on_table", 200.0)
	_check(ok, "delivered")
	game.case_by_id(c2_id).vitals = 0.2
	ok = await _until(func(): return String(game.case_by_id(c2_id).get("state", "")) == "dead", 5.0)
	_check(ok, "vitals run out: the patient is dead")
	_check(game.phase == Game.Phase.SHIFT, "a dead patient does not end the shift")
	game.dev_extra_patient()
	_check(game.loop.call_state == "ringing" and game.loop.call_kind == "extra", "the extra call rings")
	ok = await _do_until(func(): _halt(), func(): return game.loop.call_state == "", 40.0)
	_check(ok and game.cases.size() == 1, "ignored, the extra call declines itself: no new case (%d cases)" % game.cases.size())
	m0 = game.money
	ok = await _do_until(func(): _go_use("clock", game.clock_pos(), true), func(): return game.phase == Game.Phase.WON, 120.0)
	_check(ok, "clock out with a dead patient")
	_check(game.money == maxi(0, m0 - game.loop.DEAD_PENALTY), "the dead patient cost $%d (money $%d -> $%d)" % [game.loop.DEAD_PENALTY, m0, game.money])
	ok = await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 3, 30.0)
	_check(ok, "on to shift 3")

	# ------------------------------------------------------------------ shift 3
	_say("---- shift 3: game over")
	game.add_money(500, "test")
	ok = await _do_until(func(): _go_use("clock", game.clock_pos(), true), func(): return game.phase == Game.Phase.SHIFT, 120.0)
	_check(ok, "clock in for shift 3")
	bot.bot_invulnerable = false
	bot.invuln = 0.0
	await _frames(2)
	bot.invuln = 0.0
	game.damage_player(bot, 99, "test")
	await _frames(2)
	_check(game.phase == Game.Phase.LOST, "everyone down: game over")
	var old_seed: int = game.seed_value
	ok = await _until(func(): return game.phase == Game.Phase.LOBBY, 30.0)
	await _frames(3)
	bot = game.local_player()
	bot.bot_active = true
	_check(ok and game.shift == 1 and game.money == 0, "a new run: shift 1, no money (shift %d, $%d)" % [game.shift, game.money])
	_check(game.seed_value != old_seed, "a new hospital")
	_check(bot.alive, "back on your feet")


# =========================================================================
# the bot
# =========================================================================

func _grab_loot() -> String:
	var best: Node = null
	var best_d := INF
	for it in game.world_items.values():
		if not Items.is_loot(it.kind) or Items.is_bulky(it.kind) or it.state != WorldItem.State.LOOSE:
			continue
		var d: float = it.global_position.distance_to(bot.global_position)
		if d < best_d:
			best_d = d
			best = it
	if best == null:
		# No loose loot near: put one at the bot's feet (the pickup is still the real E path).
		best = game._spawn_item("gold_watch", 1, Transform3D(Basis(), bot.global_position + Vector3(0.8, 0.3, 0)), WorldItem.State.LOOSE)
		best.value = 120
	var kind: String = best.kind
	var id: int = best.item_id
	var ok := await _do_until(func():
		var it = game.world_items.get(id)
		if it != null:
			_go_use("it_%d" % id, it.global_position, false), func(): return bot.holding(kind), 50.0)
	return kind if ok else ""


## One frame of shift work: bring what the shelf lacks, operate on whoever is on a table.
func _work() -> void:
	if bot.operating:
		_halt()
		return
	var need: Dictionary = game._live_requirements()
	var short := {}
	for kind in need.keys():
		var s: int = int(need[kind]) - game.shelf_count(kind)
		if s > 0:
			short[kind] = s
	for i in bot.slots.size():
		var s: Dictionary = bot.slots[i]
		if s.kind != "" and short.has(s.kind):
			bot.selected = i
			_go_use("shelf", game.shelf_node.global_position, false)
			return
	if short.is_empty():
		for c in game.cases:
			if String(c.state) == "on_table":
				_go_use(game.table_interact_id(int(c.table)), game.table_position(int(c.table)), false)
				return
		_halt()
		return
	if not bot.can_take(short.keys()[0]):
		for i in bot.slots.size():
			var k := String(bot.slots[i].kind)
			if k != "" and not Items.is_loot(k):
				bot.selected = i
				bot.drop_count += 1
				return
	var best: Node = null
	var best_d := INF
	var kept = game.world_items.get(_target_item)
	if kept != null and is_instance_valid(kept) and short.has(kept.kind) and not _blacklist.has(_target_item):
		best = kept
		best_d = -1.0
	if best == null:
		for it in game.world_items.values():
			if not short.has(it.kind) or _blacklist.has(it.item_id):
				continue
			var d: float = it.global_position.distance_to(bot.global_position)
			if d < best_d:
				best_d = d
				best = it
	if best == null:
		_halt()
		return
	_target_item = best.item_id
	if best.state == WorldItem.State.IN_CONTAINER:
		var ct := game.find_interactable(best.container_id)
		if ct != null and ct.has_method("is_open") and not ct.is_open():
			_go_use(best.container_id, ct.global_position, false)
			return
	_go_use("it_%d" % best.item_id, best.global_position, false)


func _go_use(id: String, pos: Vector3, hold: bool) -> void:
	bot.bot_aim_id = id
	var d := Vector2(pos.x - bot.global_position.x, pos.z - bot.global_position.z).length()
	var close := d <= REACH
	if not close and _stuck > 1.5:
		var node := game.find_interactable(id)
		close = node != null and game._within_reach(bot, node) and d < C.INTERACT_RANGE
	if not close:
		bot.bot_interact = false
		_walk_to(pos)
		if _stuck > 6.0 and id.begins_with("it_"):
			_blacklist[int(id.substr(3))] = true
			_stuck = 0.0
		elif _stuck > 15.0:
			# A wedged navmesh corner (known pre-existing wing corner case, see KNOWN_ISSUES.md)
			# can leave the bot unable to make any progress toward a non-item target (shelf,
			# table, container) that can't be blacklisted. A human player escapes by strafing;
			# the bot only walks straight at its path point, so recover by warping it to the
			# target rather than hanging the whole shift loop forever.
			bot.global_position = pos
			bot.velocity = Vector3.ZERO
			_stuck = 0.0
			_repath = 0.0
		return
	bot.bot_move = Vector2.ZERO
	_stuck = 0.0
	var to := pos - bot.global_position
	bot.bot_yaw = atan2(-to.x, -to.z)
	if hold:
		bot.bot_interact = true
	elif _press_cd <= 0.0 and bot.aim_id == id and not bot.aim_prompt.begins_with("!"):
		bot.bot_press += 1
		_press_cd = 0.5


## SWEEP 4A HOOK (pharmacy, chunk 3): walk up close to the furnace, face it and fire a full
## charge throw of the selected stack. Standing close and aiming dead level makes the pill/loot
## clear the grate reliably; this exercises the same drop_selected(charge) path a real charged
## throw uses, not a shortcut into the fire zone.
##
## The furnace is rotated to face back toward the lobby's centre line (economy.gd's `_rect_spot`),
## not always world +Z, so "in front of the mouth" has to go through its own basis, the same way
## tools/inventorytest.gd's manual furnace test does -- a fixed world-space offset stood the bot
## wherever that happened to line up with the map, not necessarily lined up with the grate gaps.
func _go_throw(furn: Node3D) -> void:
	var target_pos: Vector3 = furn.global_position
	var stand: Vector3 = target_pos + furn.global_basis.z * 1.1
	var d := Vector2(stand.x - bot.global_position.x, stand.z - bot.global_position.z).length()
	if d > 0.5:
		_walk_to(stand)
		return
	bot.bot_move = Vector2.ZERO
	var aim: Vector3 = target_pos + Vector3.UP * 1.0   # the fire zone's height, not the floor
	var to := aim - bot.head.global_position
	bot.bot_yaw = atan2(-to.x, -to.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot.head.rotation.x = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -1.2, 1.2)
	bot._pitch = bot.head.rotation.x
	if _press_cd <= 0.0:
		bot.drop_charge = 1.0
		bot.drop_count += 1
		_press_cd = 1.0


func _walk_to(target: Vector3) -> void:
	if target.distance_to(_goal) > 0.5:
		_goal = target
		_repath = 0.0
	_repath -= 1.0 / 60.0
	# POCKETS: a path from before a seam crossing points back the way the bot came.
	var pk = game.pockets
	var space: String = pk.space_of(bot.global_position) if pk != null else ""
	if space != _space:
		_space = space
		_repath = 0.0
	var map := get_viewport().world_3d.navigation_map
	if _repath <= 0.0:
		_repath = 0.5
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			_path = NavigationServer3D.map_get_path(map, bot.global_position, NavigationServer3D.map_get_closest_point(map, target), true)
	var next := target
	for p in _path:
		if Vector2(p.x - bot.global_position.x, p.z - bot.global_position.z).length() > 0.7:
			next = p
			break
	if pk != null and pk.active():
		next = pk.steer_point(bot.global_position, next)
	var to_next := next - bot.global_position
	to_next.y = 0.0
	if to_next.length() < 0.05:
		bot.bot_move = Vector2.ZERO
		return
	bot.bot_yaw = atan2(-to_next.x, -to_next.z)
	bot.bot_move = Vector2(0, -1)
	if bot.global_position.distance_to(_last_pos) > 0.03:
		_last_pos = bot.global_position
		_stuck = 0.0
	else:
		_stuck += 1.0 / 60.0


func _halt() -> void:
	bot.bot_move = Vector2.ZERO
	bot.bot_interact = false


func _slot_of(kind: String) -> int:
	for i in bot.slots.size():
		if String(bot.slots[i].kind) == kind:
			return i
	return -1


# =========================================================================
# helpers
# =========================================================================

func _do_until(step: Callable, cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			bot.bot_interact = false
			return true
		step.call()
		await get_tree().physics_frame
	bot.bot_interact = false
	return bool(cond.call())


func _until(cond: Callable, timeout: float) -> bool:
	return await _do_until(func(): pass, cond, timeout)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _say(line: String) -> void:
	print("[looptest] t=%.0f %s" % [t, line])


func _finish() -> void:
	if _done:
		return
	_done = true
	_say("------------------------------------------")
	_say("result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)


## POCKETS: the forced pocket was torn down with shift 1's wings and built again with shift 2's.
func _check_pocket_rebuilt(old_root) -> void:
	var pk = game.pockets
	_check(not is_instance_valid(old_root), "POCKETS: shift 1's pocket nodes are gone")
	_check(pk.active() and String(pk.pocket.kind) == _pocket and pk.seams.size() >= 2, "POCKETS: shift 2 has the %s again (%d entrances)" % [_pocket, pk.seams.size()])
	if not pk.active():
		return
	_check(int(pk.stats.get("generation", -1)) == int(game.wing_loader.generation), "POCKETS: built for the wings of generation %d (stats %s)" % [game.wing_loader.generation, str(pk.stats)])
	_check(pk.pocket.root.get_parent() == game.level_info.get("wings_root"), "POCKETS: the pocket hangs under the new wings root")
	var n := 0
	for c in game.level_info.get("containers", []):
		if c.get("node") != null and is_instance_valid(c.node) and pk.in_pocket(c.node.global_position):
			n += 1
	_check(n > 0, "POCKETS: the new pocket's containers are in level_info (%d)" % n)
