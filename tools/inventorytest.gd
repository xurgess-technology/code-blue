extends Node
## Headless checks for the inventory sweep: four hand slots, merging, bulky loot, drops on a hit,
## loot spawning and colour coding, selling, money, the gold bar shop and the pile, persistence
## across shifts and the reset.
##
##   godot --headless --fixed-fps 60 --path . tools/inventorytest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

const LootSpawner := preload("res://scripts/economy/loot_spawner.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")

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
	await _frames(3)
	var held: Node3D = me.get_node("Head/FX/Camera/HeldFirstPerson")
	var held_overlay = _overlay_of(held)
	_check(held_overlay == ItemModels.tint_material("laptop", true), "the held laptop wears the (softer) gold rim too")
	_clear()


func _money() -> void:
	_say("---- money, the sell bin, the shop")
	_check(game.economy.placed(), "the sell bin, shop and pile are placed (mode %s)" % game.economy.mode)
	_check(game.find_interactable("sell_bin") != null and game.find_interactable("shop") != null, "sell_bin and shop are interactables")
	game.reset_money()
	_check(game.money == 0 and game.gold_bars == 0, "money starts at zero")
	game.add_money(-50, "test")
	_check(game.money == 0, "money never goes below zero by accident")
	# Sell through the real interaction path: stand at the bin, aim, press E.
	_clear()
	me.take_into("laptop", 1, 150)
	me.selected = 0
	var bin: Node3D = game.find_interactable("sell_bin")
	_check(bin.interact_prompt(me).begins_with("Sell Laptop for $150"), "the sell bin offers $150: '%s'" % bin.interact_prompt(me))
	me.take_into("gauze", 2)
	me.selected = 1
	_check(bin.interact_prompt(me).begins_with("!"), "the sell bin refuses surgical supplies: '%s'" % bin.interact_prompt(me))
	me.selected = 0
	await _press_on("sell_bin")
	_check(game.money == 150 and not me.holding("laptop"), "selling the laptop adds $150 and empties the hand (money %d)" % game.money)
	_check(me.holding("gauze"), "the gauze stays in its slot")
	# A bulky one through sell_selected, selected by its second half.
	me.take_into("ultrasound", 1, 400)
	var t: int = me.tail_of(me.slots.find(me.slots.filter(func(s): return s.kind == "ultrasound")[0]))
	me.selected = t
	game.sell_selected(me)
	_check(game.money == 550 and me.free_slot_count() == 3, "selling bulky loot from its second slot adds $400 and frees two slots")
	# The shop.
	var shop: Node3D = game.find_interactable("shop")
	var price := game.gold_bar_price()
	_check(price == 100, "the first gold bar costs $100 (%d)" % price)
	await _press_on("shop")
	_check(game.gold_bars == 1 and game.money == 450, "buying a bar adds it and takes $100 (bars %d, money %d)" % [game.gold_bars, game.money])
	_check(game.gold_bar_price() > price, "the next bar costs more ($%d)" % game.gold_bar_price())
	game.money = 50
	_check(shop.interact_prompt(me).begins_with("!"), "the shop says you cannot afford it: '%s'" % shop.interact_prompt(me))
	_check(not game.buy_gold_bar(me) and game.money == 50 and game.gold_bars == 1, "without the money nothing is bought")
	game.add_money(100000, "test")
	for i in 49:
		game.buy_gold_bar(me)
	_check(game.gold_bars == 50, "fifty bars bought")
	await _frames(40)
	var pile: Node3D = game.economy.pile
	_check(pile != null and int(pile.shown) == 50, "the pile shows 50 bars (%d)" % (int(pile.shown) if pile != null else -1))
	var mm: MultiMesh = pile.get_node("Bars").multimesh
	_check(mm.visible_instance_count == 50 and mm.instance_count >= 50, "one MultiMesh draws them")
	_check(game.economy.money_visible_for(me), "the money readout shows near the shop")


func _persistence() -> void:
	_say("---- persistence across shifts, reset")
	var money := game.money
	var bars := game.gold_bars
	var start_shift := game.shift
	for k in 2:
		if game.phase != Game.Phase.SHIFT:
			game.begin_shift()
			await _frames(3)
		game._end_shift(true, "Test: shift over.")
		var ok := await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == start_shift + k + 1, 20.0)
		_check(ok, "shift %d ends and the next lobby starts" % (start_shift + k))
		await _frames(6)
		_check(game.money == money and game.gold_bars == bars, "money and bars survive into shift %d ($%d, %d bars)" % [game.shift, game.money, game.gold_bars])
		_check(game.economy.placed() and int(game.economy.pile.get("_target")) == bars, "the new level's pile holds all %d bars" % bars)
	game.reset_money()
	await _frames(3)
	_check(game.money == 0 and game.gold_bars == 0 and int(game.economy.pile.shown) == 0, "reset_money empties the money and the pile")


# =========================================================================
# helpers

func _clear() -> void:
	me.slots = Player.empty_slots()
	me.selected = 0


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
