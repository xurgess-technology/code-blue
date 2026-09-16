extends Node
## Headless checks for the inventory sweep: four hand slots, merging, bulky loot, drops on a hit,
## loot spawning and colour coding, selling into the furnace, buying at the pharmacy, placebo
## pills and the charged throw, persistence across shifts and the reset.
##
##   godot --headless --fixed-fps 60 --path . tools/inventorytest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

const LootSpawner := preload("res://scripts/economy/loot_spawner.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")
# PillLines is a class_name (scripts/economy/pill_lines.gd), used directly below.

var main: Node3D
var game: Game
var me: Player
var seed_value := 12345
var _failures: Array = []
var _checks := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv[0] == "seed" and kv.size() > 1:
			seed_value = int(kv[1])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Tester")
	game.start_session(seed_value)
	await _frames(10)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = false
	await _run()
	_finish()


func _run() -> void:
	await _slots()
	await _bulky()
	await _hit_drops()
	await _loot_spawn()
	await _money()
	await _pharmacy_pills()
	await _hand_supplies()
	await _persistence()


# =========================================================================

func _slots() -> void:
	_say("---- four slots")
	_check(me.slots.size() == 4 and C.CARRY_CAP == 4, "four hand slots (CARRY_CAP %d, slots %d)" % [C.CARRY_CAP, me.slots.size()])
	for i in 4:
		var action := "slot_%d" % (i + 1)
		var has_key := false
		if InputMap.has_action(action):
			for ev in InputMap.action_get_events(action):
				if ev is InputEventKey and (ev.physical_keycode == KEY_1 + i or ev.keycode == KEY_1 + i):
					has_key = true
		_check(has_key, "key %d selects slot %d" % [i + 1, i + 1])
	_clear()
	me.selected = 0
	_check(me.take_into("gauze", 2) == 0, "gauze goes into the selected empty slot")
	_check(me.take_into("gauze", 3) == 0 and int(me.slots[0].count) == 5, "a second gauze stack merges (count %d)" % int(me.slots[0].count))
	_check(me.take_into("anesthetic", 2) == 1, "anesthetic takes the next free slot")
	_check(me.take_into("forceps", 1) == 2 and me.take_into("tourniquet", 1) == 3, "slots 3 and 4 fill")
	_check(not me.can_take("bone_saw"), "a fifth stack does not fit")
	_check(me.can_take("gauze") and me.can_take("anesthetic"), "matching consumables still merge when full")
	# Picking up from the world merges too, through the real pickup path.
	var it = _world("gauze", 2)
	game.pickup_item(me, it)
	_check(int(me.slots[0].count) == 7 and not game.world_items.has(it.item_id), "picking up gauze merges into the stack")
	var saw = _world("bone_saw", 1)
	game.pickup_item(me, saw)
	_check(game.world_items.has(saw.item_id) and not me.holding("bone_saw"), "a pickup with full hands leaves the item where it is")
	# The wheel steps through all four slots and wraps.
	me.selected = 3
	me.select_step(1)
	_check(me.selected == 0, "the wheel wraps from slot 4 to slot 1")
	me.select_step(-1)
	_check(me.selected == 3, "and back from slot 1 to slot 4")
	# Loot stacks merge with their values.
	_clear()
	me.take_into("pill_bottle", 1, 20)
	me.take_into("pill_bottle", 2, 36)
	_check(int(me.slots[0].count) == 3 and int(me.slots[0].v) == 56, "pill bottles merge and their values add (%s)" % str(me.slots[0]))
	# The shelf only takes the selected surgical stack.
	_clear()
	me.take_into("gauze", 3)
	me.selected = 0
	var before := game.shelf_count("gauze")
	game.shelf_place(me)
	_check(game.shelf_count("gauze") == before + 3 and me.hands_empty(), "the shelf takes the selected stack out of four slots")
	game.shelf = {}
	game.world_items.erase(saw.item_id)
	saw.queue_free()


func _bulky() -> void:
	_say("---- bulky loot")
	_clear()
	me.take_into("gauze", 2)
	me.take_into("anesthetic", 2)
	me.take_into("forceps", 1)
	_check(me.free_slot_count() == 1, "one free slot left")
	_check(not me.can_take("defibrillator"), "bulky loot needs two free slots")
	var defib = _world("defibrillator", 1, 300)
	game.pickup_item(me, defib)
	_check(game.world_items.has(defib.item_id) and not me.holding("defibrillator"), "a bulky pickup with one free slot fails")
	_check(defib.interact_prompt(me).begins_with("!"), "and its prompt says why: '%s'" % defib.interact_prompt(me))
	me.clear_slot(1)   # free slot 2: now slots 2 and 4 are free
	me.selected = 0
	_check(me.can_take("defibrillator"), "two free slots (not next to each other) take bulky loot")
	game.pickup_item(me, defib)
	var head := -1
	for i in 4:
		if String(me.slots[i].kind) == "defibrillator":
			head = i
	var tail: int = me.tail_of(head) if head >= 0 else -1
	_check(head >= 0 and tail >= 0 and tail != head, "the defibrillator fills a slot and a second one (head %d, tail %d)" % [head, tail])
	_check(me.free_slot_count() == 0 and not me.can_take("bone_saw"), "with bulky loot and three stacks the hands are full")
	var total := 0
	for s in me.slots:
		if String(s.kind) == "defibrillator":
			total += 1
	_check(total == 1, "walking the slots sees the bulky stack once")
	_check(int(me.slots[head].get("v", 0)) == 300, "its value came along into the hand")
	me.selected = tail
	_check(String(me.selected_stack().kind) == "defibrillator", "selecting its second slot selects the defibrillator")
	var n_items := game.world_items.size()
	game.drop_selected(me)
	_check(game.world_items.size() == n_items + 1 and not me.holding("defibrillator") and me.slot_free(head) and me.slot_free(tail),
		"G on the second slot sets down the whole defibrillator and frees both slots")
	var dropped = _newest_item()
	_check(dropped != null and dropped.kind == "defibrillator" and int(dropped.value) == 300, "the dropped defibrillator keeps its value")
	# A stale second half (its stack removed by code that did not use clear_slot) is tidied.
	_clear()
	me.take_into("heart_monitor", 1, 200)
	var hm_tail: int = me.tail_of(0)
	me.slots[0] = Player.empty_slot()
	await _frames(2)
	_check(hm_tail >= 0 and me.slot_free(hm_tail), "an orphaned second half frees itself")
	# Replication: the report is a copy and carries the pairing.
	_clear()
	me.take_into("microscope", 1, 250)
	var rep: Dictionary = me.report_full()
	rep.sl[0].count = 99
	_check(int(me.slots[0].count) == 1 and rep.sl.size() == 4 and (rep.sl as Array).any(func(s): return s.has("of")), "report_full copies the four slots, pairing included")
	_clear()
	game.world_items.erase(dropped.item_id)
	dropped.queue_free()


func _hit_drops() -> void:
	_say("---- getting hit drops everything")
	_clear()
	me.revive_full()
	me.take_into("anesthetic", 3)
	me.take_into("gauze", 2)
	me.take_into("laptop", 1, 200)     # fragile loot
	me.take_into("wheelchair_wheel", 1, 40)
	var before := game.world_items.size()
	me.invuln = 0.0
	game.damage_player(me, 1, "test")
	_check(me.hands_empty(), "a hit empties all four slots")
	var dropped := {}
	for it in game.world_items.values():
		if it.item_id >= 0 and not dropped.has(it.kind) and it.state == WorldItem.State.LOOSE:
			dropped[it.kind] = it
	_check(game.world_items.size() == before + 4, "four stacks hit the floor (%d)" % (game.world_items.size() - before))
	_check(dropped.has("anesthetic") and int(dropped.anesthetic.count) == 2, "the vials lose one to breakage")
	_check(dropped.has("laptop") and int(dropped.laptop.value) < 200 and int(dropped.laptop.value) > 0, "the laptop cracks and is worth less (%d)" % int(dropped.get("laptop", {"value": -1}).value))
	_check(dropped.has("wheelchair_wheel") and int(dropped.wheelchair_wheel.value) == 40, "sturdy loot keeps its value")
	# Bulky loot drops on a shove too.
	me.revive_full()
	me.take_into("iv_pump", 1, 180)
	var other = _add_dummy()
	await _frames(2)
	other.teleport(me.global_position + Vector3(1.2, 0.0, 0.0))
	var to: Vector3 = me.global_position - other.global_position
	other.bot_yaw = atan2(-to.x, -to.z)
	await _frames(2)
	var holder_before := game.world_items.size()
	game.player_shoved(other)
	_check(me.hands_empty() and game.world_items.size() == holder_before + 1, "a shove drops the bulky IV pump")
	game.players.erase(other.peer_id)
	other.queue_free()
	me.revive_full()


func _loot_spawn() -> void:
	_say("---- loot spawning")
	game.begin_shift()
	await _frames(5)
	var loot := []
	var in_container_bulky := 0
	var no_value := 0
	var kinds := {}
	for it in game.world_items.values():
		if Items.is_loot(it.kind):
			loot.append(it)
			kinds[it.kind] = true
			if it.value <= 0:
				no_value += 1
			if Items.is_bulky(it.kind) and it.state == WorldItem.State.IN_CONTAINER:
				in_container_bulky += 1
	_say("loot stacks %d, kinds %d, level %s" % [loot.size(), kinds.size(), "fallback" if game.level_info.get("fallback", false) else "generated"])
	_check(loot.size() >= LootSpawner.MIN_LOOT, "loot spawned with the shift (%d stacks)" % loot.size())
	_check(kinds.size() >= 5, "several loot kinds turned up (%d)" % kinds.size())
	_check(no_value == 0, "every loot stack has a value")
	_check(in_container_bulky == 0, "no bulky loot inside a container")
	_check(LootTable.LOOT.size() >= 15 and LootTable.LOOT.size() <= 25, "the loot table has 15 to 25 kinds (%d)" % LootTable.LOOT.size())
	var a := LootSpawner.plan(seed_value, game.shift, game.level_info, {})
	var b := LootSpawner.plan(seed_value, game.shift, game.level_info, {})
	_check(str(a) == str(b) and not a.is_empty(), "the loot plan is deterministic from the seed")
	var c := LootSpawner.plan(seed_value + 1, game.shift, game.level_info, {})
	_check(str(a) != str(c), "a different seed gives a different plan")
	# Deeper is worth more: the same roll at depth 3 beats depth 0.
	_check(LootTable.roll_value("laptop", 3, 0.5) > LootTable.roll_value("laptop", 0, 0.5), "deeper loot rolls higher values")
	_check(LootTable.weight("gold_watch", "waiting_room", 3) / LootTable.weight("stethoscope", "waiting_room", 3) \
		> LootTable.weight("gold_watch", "waiting_room", 0) / LootTable.weight("stethoscope", "waiting_room", 0), "rare loot is likelier deeper")
	# Colour coding: gold rim on loot, teal on supplies.
	var gold = ItemModels.tint_material("laptop")
	var teal = ItemModels.tint_material("gauze")
	_check(gold != null and teal != null and gold != teal, "gold and teal tints exist")
	var sample_loot = loot[0] if not loot.is_empty() else null
	_check(sample_loot != null and _overlay_of(sample_loot) == gold, "a loot world item wears the gold rim")
	var supply = null
	for it in game.world_items.values():
		if Items.is_surgical(it.kind) and supply == null:
			supply = it
	_check(supply != null and _overlay_of(supply) == teal, "a supply world item wears the teal rim")
	me.take_into("laptop", 1, 100)
	# Process frames, not physics frames: the held model is rebuilt in Player._process, and after the
	# shift's loot spawn several physics frames can run before the next process frame.
	for i in 3:
		await get_tree().process_frame
	var held: Node3D = me.get_node("Head/FX/Camera/HeldFirstPerson")
	var held_overlay = _overlay_of(held)
	_check(held_overlay == ItemModels.tint_material("laptop", true), "the held laptop wears the (softer) gold rim too")
	_clear()


func _money() -> void:
	_say("---- money, the pharmacy, the furnace")
	_check(game.economy.placed(), "the pharmacy and the furnace are placed (mode %s)" % game.economy.mode)
	_check(game.find_interactable("pharmacy_kiosk") != null, "the pharmacy kiosk is an interactable")
	game.reset_money()
	_check(game.money == 0, "money starts at zero")
	game.add_money(-50, "test")
	_check(game.money == 0, "money never goes below zero by accident")
	# Selling is a charged throw into the furnace: stand close, face it, and fire.
	var furn: Node3D = game.economy.furnace
	_check(furn != null, "the furnace is placed")
	furn.set_hatch(true, false)   # hub rebuild: the hatch over the window starts shut
	me.teleport(furn.global_position + furn.global_basis.z * 1.05)
	var aim_furn: Vector3 = furn.global_position + Vector3.UP * 1.5   # the middle of the window
	var to := aim_furn - me.head.global_position
	me.rotation.y = atan2(-to.x, -to.z)
	me._yaw = me.rotation.y
	me.head.rotation.x = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -1.2, 1.2)
	me._pitch = me.head.rotation.x
	_clear()
	me.take_into("laptop", 1, 150)
	me.selected = 0
	var m0 := game.money
	game.drop_selected(me, 1.0)
	# not-holding fires the instant the throw releases; the sale only lands once the item has
	# actually flown into the furnace's FireZone a moment later, so wait for the money itself.
	var sold := await _until(func(): return game.money != m0, 3.0)
	if not sold:
		_say("DEBUG furnace pos=%s aim=%s me=%s head=%s pitch=%s" % [str(furn.global_position), str(aim_furn), str(me.global_position), str(me.head.global_position), str(me.head.rotation.x)])
		for it in game.world_items.values():
			_say("DEBUG item kind=%s pos=%s dist_to_furnace=%.2f" % [it.kind, str(it.global_position), it.global_position.distance_to(furn.global_position)])
	_check(sold and game.money == m0 + 150, "throwing the laptop into the furnace adds $150 (money %d)" % game.money)
	# Unsellable items bounce back out instead of being consumed.
	_clear()
	me.take_into("gauze", 2)
	me.selected = 0
	var before_items := game.world_items.size()
	game.drop_selected(me, 1.0)
	await _until(func(): return game.world_items.size() > before_items, 3.0)
	_check(game.world_items.size() > before_items, "gauze thrown into the furnace bounces back out instead of selling")
	for it in game.world_items.values().duplicate():
		if it.kind == "gauze":
			game.world_items.erase(it.item_id)
			it.queue_free()
	# The pharmacy: a flat price, unlimited buys, delivered through the tube. Ordering is at the
	# kiosk (HUB REDESIGN); the window itself is set dressing now.
	var pharm: Node3D = game.find_interactable("pharmacy_kiosk")
	_check(pharm != null, "the pharmacy kiosk is interactable")
	var price := int(game.PILL_PRICE)
	m0 = game.money
	await _press_on("pharmacy_kiosk")
	await _frames(120)
	var delivered := false
	for it in game.world_items.values():
		if it.kind == "placebo_pills" and int(it.count) == Game.PILL_COUNT:
			delivered = true
	_check(game.money == m0 - price, "buying pills takes $%d (money %d)" % [price, game.money])
	_check(delivered, "the tube delivered a bottle of %d pills" % Game.PILL_COUNT)
	game.money = 0
	_check(pharm.interact_prompt(me).begins_with("!"), "the pharmacy says you cannot afford it: '%s'" % pharm.interact_prompt(me))
	_check(not game.buy_pills(me), "without the money nothing is bought")
	game.add_money(100000, "test")
	_check(game.buy_pills(me) and game.buy_pills(me), "unlimited buys: pills never run out or get pricier")
	_check(game.economy.money_visible_for(me), "the money readout shows near the pharmacy")


func _pharmacy_pills() -> void:
	_say("---- placebo pills: charged throw, hits, burns for $0")
	PillLines.reset()
	_clear()
	# A charged throw goes further than a tap.
	me.take_into("placebo_pills", 10)
	me.selected = 0
	var from: Vector3 = me.global_position
	game.drop_selected(me, 0.0)
	await _frames(3)
	var tap := _newest_item()
	var tap_dist: float = tap.global_position.distance_to(from) if tap != null else -1.0
	if tap != null:
		game.world_items.erase(tap.item_id)
		tap.queue_free()
	_clear()
	me.take_into("placebo_pills", 10)
	me.selected = 0
	game.drop_selected(me, 1.0)
	await _frames(3)
	var thrown := _newest_item()
	var thrown_dist: float = thrown.global_position.distance_to(from) if thrown != null else -1.0
	await _frames(40)   # let both settle before comparing final rest distance
	_check(tap_dist >= 0.0 and thrown_dist >= 0.0 and thrown_dist > tap_dist, "a charged throw goes further than a tap (%.2fm vs %.2fm)" % [thrown_dist, tap_dist])
	if thrown != null and is_instance_valid(thrown):
		game.world_items.erase(thrown.item_id)
		thrown.queue_free()
	_check(int(me.slots[_slot_of("placebo_pills")].count) == 9, "the charged throw fired one pill, nine are left")
	# Pills burn for $0.
	_clear()
	me.take_into("placebo_pills", 10)
	me.selected = 0
	var furn: Node3D = game.economy.furnace
	furn.set_hatch(true, false)
	me.teleport(furn.global_position + furn.global_basis.z * 1.05)
	var aim_furn2: Vector3 = furn.global_position + Vector3.UP * 1.5
	var to := aim_furn2 - me.head.global_position
	me.rotation.y = atan2(-to.x, -to.z)
	me._yaw = me.rotation.y
	me.head.rotation.x = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -1.2, 1.2)
	me._pitch = me.head.rotation.x
	var m0 := game.money
	game.drop_selected(me, 1.0)
	await _until(func(): return int(me.slots[_slot_of("placebo_pills")].count) == 9, 3.0)
	await _frames(20)
	_check(game.money == m0, "a thrown pill burns for $0")
	me.slots[_slot_of("placebo_pills")] = Player.empty_slot()
	# A thrown pill on a teammate: the line and warm effect land only on that player's machine.
	# `_pill_hit_player` only actually applies the effect when the target is either networked
	# (Net.active) or the local player -- neither is true for a bare solo-mode dummy, so mark it
	# `is_local` here to stand in for "their own machine" the way a real second player would be.
	var other := _add_dummy()
	other.is_local = true
	await _frames(3)
	other.teleport(me.global_position + Vector3(1.4, 0.0, 0.0))
	_clear()
	me.take_into("placebo_pills", 10)
	me.selected = 0
	var aim_at2: Vector3 = other.global_position + Vector3.UP * 1.0
	var to2 := aim_at2 - me.head.global_position
	me.rotation.y = atan2(-to2.x, -to2.z)
	me._yaw = me.rotation.y
	me.head.rotation.x = clampf(atan2(to2.y, Vector2(to2.x, to2.z).length()), -1.2, 1.2)
	me._pitch = me.head.rotation.x
	other.warm_level = 0.0
	other.warm_target = 0.0
	other.warm_hold_left = 0.0
	game.drop_selected(me, 1.0)
	var hit := await _until(func(): return other.warm_target > 0.0 or other.warm_hold_left > 0.0, 3.0)
	_check(hit and other.warm_hold_left > 0.0, "a thrown pill on a teammate starts their warm effect (local)")
	other.is_local = false
	game.players.erase(other.peer_id)
	other.queue_free()
	# A pill on an OR-table patient: the note is set, vitals/sedation untouched.
	game.begin_shift()
	await _frames(5)
	if not game.patient_tables.is_empty():
		var tv: float = game.case_on_table(0).get("vitals", -1.0)
		var t: Vector3 = game.table_position(0)   # the tabletop surface, not floor height
		game.pill_notes.clear()
		# Stand on the floor near the table (not at tabletop height) and aim level at the
		# patient's body height, not the bare table position.
		me.teleport(game._floor_at(t + Vector3(0, 0, 1.4)))
		var aim_at: Vector3 = t + Vector3.UP * 0.15
		var to3 := aim_at - me.head.global_position
		me.rotation.y = atan2(-to3.x, -to3.z)
		me._yaw = me.rotation.y
		me.head.rotation.x = clampf(atan2(to3.y, Vector2(to3.x, to3.z).length()), -1.2, 1.2)
		me._pitch = me.head.rotation.x
		_clear()
		me.take_into("placebo_pills", 10)
		me.selected = 0
		game.drop_selected(me, 1.0)
		var noted := await _until(func(): return game.pill_notes.has(0), 3.0)
		_check(noted, "a pill on the OR table sets the green blip note")
		# The case still drains normally on its own table clock; the pill itself must add no jump
		# on top of that (a few seconds of ordinary drain is well under 5).
		var after: float = game.case_on_table(0).get("vitals", -1.0)
		_check(absf(after - tv) < 5.0, "vitals do not change from a pill beyond ordinary drain (%s -> %s)" % [str(tv), str(after)])
	else:
		_say("(no patient table this run: skipped the OR blip check)")
	_clear()


## A surgical item can start a step whether it's on the OR shelf or in the operating player's
## own hands, and the finishing step draws the shelf down first, the operator's hands only for
## the shortfall (see surgery_system.gd can_begin / game.surgery_step_done).
func _hand_supplies() -> void:
	_say("---- surgery supplies: shelf or hands")
	_clear()
	# Earlier checks (_loot_spawn, _pharmacy_pills) already clocked in with random cases: end that
	# shift so this one starts clean, with only the pinned patient on a table.
	if game.phase == Game.Phase.SHIFT:
		game._end_shift(true, "Test: reset for the hand-supplies check.")
		await _until(func(): return game.phase == Game.Phase.LOBBY, 20.0)
	game.shelf.erase("anesthetic")
	game.loop.force_first = {"patient_id": "bob", "ailment_id": "gunshot"}
	game.begin_shift()
	await _frames(3)
	var c: Dictionary = game.cases[0]
	var table: int = int(c.table)
	var surgery: Node = game.surgeries[table]
	var step := Procedures.step(String(c.ailment_id), int(c.step_index))
	_check(String(step.id) == "sedate" and String(step.item) == "anesthetic" and int(step.uses) == 1, "gunshot's first step needs one anesthetic (%s)" % str(step))
	_check(game.shelf_count("anesthetic") == 0 and not me.holding("anesthetic"), "neither the shelf nor the bot's hands have it yet")
	_check(surgery.can_begin(me) != "", "can_begin refuses with no anesthetic anywhere (%s)" % surgery.can_begin(me))

	me.take_into("anesthetic", 1)
	_check(me.hand_count("anesthetic") == 1, "the bot now holds one anesthetic")
	_check(surgery.can_begin(me) == "", "can_begin accepts a hand-held anesthetic with none on the shelf")

	# Finish the step as if the bot had just operated: the shelf is empty, so the item comes out
	# of the operator's hands.
	game.surgery_step_done({}, table, me.peer_id)
	_check(me.hand_count("anesthetic") == 0, "finishing the step spent the hand-held anesthetic")
	_check(game.shelf_count("anesthetic") == 0, "the empty shelf is untouched")
	c = game.case_by_id(int(c.id))
	_check(int(c.step_index) == 1, "the case moved on to the next step")

	# The next step ("extract", forceps, uses 0) needs a forceps present but never consumes it;
	# hand-held is enough and nothing is taken from the bot.
	me.take_into("forceps", 1)
	_check(surgery.can_begin(me) == "", "a hand-held forceps satisfies a 0-use step too")
	game.surgery_step_done({}, table, me.peer_id)
	_check(me.hand_count("forceps") == 1, "a 0-use step never consumes the item, hand or shelf")
	c = game.case_by_id(int(c.id))
	_check(int(c.step_index) == 2, "the case moved on again")

	# Third step ("dress", gauze, uses 1): with one on the shelf AND one in hand, the shelf is
	# drawn down first and the hand-held one is left alone.
	me.clear_slot(me.slot_for("forceps"))
	game.shelf["gauze"] = 1
	me.take_into("gauze", 1)
	_check(surgery.can_begin(me) == "", "gauze on the shelf (plus a spare in hand) satisfies the step")
	game.surgery_step_done({}, table, me.peer_id)
	_check(game.shelf_count("gauze") == 0, "the shelf's gauze was spent first")
	_check(me.hand_count("gauze") == 1, "the hand-held spare gauze was left alone")
	game._end_shift(true, "Test: shift over.")
	await _until(func(): return game.phase == Game.Phase.LOBBY, 20.0)
	_clear()
	game.loop.force_first = {}


func _persistence() -> void:
	_say("---- persistence across shifts, reset")
	var money := game.money
	var start_shift := game.shift
	for k in 2:
		if game.phase != Game.Phase.SHIFT:
			game.begin_shift()
			await _frames(3)
		game._end_shift(true, "Test: shift over.")
		var ok := await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == start_shift + k + 1, 20.0)
		_check(ok, "shift %d ends and the next lobby starts" % (start_shift + k))
		await _frames(6)
		_check(game.money == money, "money survives into shift %d ($%d)" % [game.shift, game.money])
		_check(game.economy.placed(), "the new level's pharmacy and furnace are placed")
	game.reset_money()
	await _frames(3)
	_check(game.money == 0, "reset_money empties the money")
	# no gold bar code paths remain: grep -ri gold scripts tools finds nothing economy-related.
	_check(not game.has_method("buy_gold_bar") and not game.has_method("sell_selected") and not ("gold_bars" in game), "no gold bar code paths remain on Game")


# =========================================================================
# helpers

func _clear() -> void:
	me.slots = Player.empty_slots()
	me.selected = 0


func _slot_of(kind: String) -> int:
	for i in me.slots.size():
		if String(me.slots[i].kind) == kind:
			return i
	return -1


func _world(kind: String, count: int, value := 0) -> Node:
	var at: Vector3 = me.global_position + Vector3(0.6, 0.5, 0.0)
	var it = game._spawn_item(kind, count, Transform3D(Basis(), at), WorldItem.State.LOOSE)
	it.value = value
	return it


func _newest_item() -> Node:
	var best = null
	for it in game.world_items.values():
		if best == null or it.item_id > best.item_id:
			best = it
	return best


func _overlay_of(node: Node) -> Material:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).material_overlay != null:
			return (mi as MeshInstance3D).material_overlay
	return null


func _add_dummy() -> Player:
	var p: Player = Player.new_player(-77, "Shover", false)
	p.is_bot = true
	p.bot_active = true
	game.players[-77] = p
	game.get_node("Entities").add_child(p)
	return p


## Stand in reach of an interactable, aim at it and press E once, through the host's checks.
func _press_on(id: String) -> void:
	var node: Node3D = game.find_interactable(id)
	var spot: Vector3 = node.global_position + node.global_transform.basis.z * 1.1
	me.teleport(game._floor_at(spot))
	var to := node.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_aim_id = id
	await _frames(3)
	me.bot_press += 1
	await _frames(3)
	me.bot_aim_id = ""


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _say(line: String) -> void:
	print("[inventorytest] ", line)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _until(cond: Callable, seconds: float) -> bool:
	var frames := int(seconds * 60.0)
	for i in frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())


func _finish() -> void:
	_say("------------------------------------------")
	_say("result=%s checks=%d failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
