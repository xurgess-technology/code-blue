extends Node
## Headless checks for brains (sweep 3): spoilage over time, value through pickup, drop, a violent
## drop and the dumpster, the rot shown on the model, the blender (points, levels, the cap), R with
## nothing absorbed, Echo (noise, the view, cooldown), Hive Eyes (needs a Walk-In in range, freezes
## the body, ends on R, on time, on a hit and when the Walk-In dies), and the reset on game over.
##
##   godot --headless --fixed-fps 60 --path . tools/braintest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

const Brains := preload("res://scripts/brains/brains.gd")
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
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(10)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = false
	await _run()
	_finish()


func _run() -> void:
	await _data_and_math()
	await _items()
	await _blender()
	await _abilities_nothing_and_echo()
	await _hive_eyes()
	await _ability_slots()
	await _reset_on_game_over()


# =========================================================================

func _data_and_math() -> void:
	_say("---- loot data and spoil math")
	for kind in ["brain_walk_in", "brain_discharged"]:
		_check(Items.is_loot(kind) and Items.is_fragile(kind) and not Items.stacks(kind) and not Items.is_bulky(kind),
			"%s is fragile, single, one-handed loot" % kind)
	_check(Brains.base_value("brain_walk_in") == 150 and Brains.base_value("brain_discharged") == 350, "base values $150 / $350")
	var spawned := false
	for s in [seed_value, 4242, 777, 90210]:
		for sh in [1, 3]:
			for e in LootSpawner.plan(s, sh, game.level_info, {}):
				if Brains.is_brain(String(e.kind)):
					spawned = true
	_check(not spawned, "the loot spawner never places a brain (4 seeds, 2 shifts)")
	_check(is_equal_approx(Brains.spoil_factor(0.0), 1.0) and is_equal_approx(Brains.spoil_factor(45.0), 1.0), "a brain keeps its full value for 45 s")
	_check(absf(Brains.spoil_factor(135.0) - 0.575) < 0.001, "halfway down at 135 s (%.3f)" % Brains.spoil_factor(135.0))
	_check(absf(Brains.spoil_factor(225.0) - 0.15) < 0.001 and absf(Brains.spoil_factor(900.0) - 0.15) < 0.001, "0.15 at 225 s and after")
	_check(Brains.condition(1.0) == "fresh" and Brains.condition(0.6) == "fresh" and Brains.condition(0.45) == "spoiling" and Brains.condition(0.2) == "rotten", "fresh / spoiling / rotten thresholds")
	var mono := true
	var last := 2.0
	for i in 50:
		var f := Brains.spoil_factor(i * 6.0)
		mono = mono and f <= last + 0.0001
		last = f
	_check(mono, "spoilage never goes back up")


func _items() -> void:
	_say("---- a brain through pickup, drop, a hit and the dumpster")
	_clear()
	var b: Node = game.brains
	var at: Vector3 = me.global_position + Vector3(0.8, 0.0, 0.0)
	var it = b.spawn_brain("brain_walk_in", 0.8, at)
	_check(it != null and it.kind == "brain_walk_in" and int(it.value) == 120, "spawn_brain: a Walk-In brain at quality 0.8 is worth $120 (%s)" % (str(it.value) if it != null else "null"))
	_check(absf(float(it.bt) - game.world_time) < 0.05, "its spoil clock starts now")
	_check(it.find_children("Brain", "MeshInstance3D", true, false).size() == 1, "it has the brain model")
	_check(_overlay_of(it) == ItemModels.tint_material("brain_walk_in"), "and wears the gold loot rim")
	_check(it.interact_prompt(me).contains("$120") and it.interact_prompt(me).contains("fresh"), "its prompt tells value and condition: '%s'" % it.interact_prompt(me))
	_check(int(it.report().get("bt", -1)) >= 0, "the item report carries bt")
	# Age it: 135 s old is worth 57.5%.
	it.bt = game.world_time - 135.0
	_check(b.current_value(it) == roundi(120 * 0.575), "at 135 s it is worth $%d (want %d)" % [b.current_value(it), roundi(120 * 0.575)])
	await _frames(8)
	var mi: MeshInstance3D = it.find_children("Brain", "MeshInstance3D", true, false)[0]
	var rot_shown = mi.get_instance_shader_parameter("rot")
	_check(rot_shown != null and float(rot_shown) > 0.4 and float(rot_shown) < 0.6, "the model shows the rot (%s)" % str(rot_shown))
	var bt0 := float(it.bt)
	game.pickup_item(me, it)
	var i := _slot_of("brain_walk_in")
	_check(i >= 0 and absf(float(me.slots[i].get("bt", -1.0)) - bt0) < 0.001 and int(me.slots[i].v) == 120, "picked up: the hand slot keeps bt and the value (%s)" % (str(me.slots[i]) if i >= 0 else "none"))
	_check(b.current_value(me.slots[i]) == roundi(120 * 0.575), "the stack in hand is worth the same")
	_check(me.report_full().sl[i].has("bt"), "the player report carries bt in the slot")
	await _frames(12)
	var held: Node = me.get_node("Head/FX/Camera/HeldFirstPerson")
	var hm: Array = held.find_children("Brain", "MeshInstance3D", true, false)
	_check(not hm.is_empty() and float(hm[0].get_instance_shader_parameter("rot")) > 0.4, "the held brain shows its rot too")
	me.selected = i
	game.drop_selected(me)
	var dropped = _newest("brain_walk_in")
	_check(dropped != null and absf(float(dropped.bt) - bt0) < 0.001 and int(dropped.value) == 120, "set down with G: bt and value stay")
	game.pickup_item(me, dropped)
	# A hit: fragile, it cracks (keeps LOOT_CRACK_KEEPS of its value) and still spoils from the same time.
	me.revive_full()
	me.take_into("brain_discharged", 1, 300)
	me.slots[_slot_of("brain_discharged")]["bt"] = game.world_time - 10.0
	var bt1: float = game.world_time - 10.0
	i = _slot_of("brain_walk_in")
	me.slots[i]["bt"] = bt0
	me.invuln = 0.0
	game.damage_player(me, 1, "test")
	var cracked = _newest("brain_discharged")
	_check(me.hands_empty() and cracked != null and int(cracked.value) == maxi(1, roundi(300 * Game.LOOT_CRACK_KEEPS)), "a hit drops the brain and it cracks ($%s)" % (str(cracked.value) if cracked != null else "?"))
	_check(cracked != null and absf(float(cracked.bt) - bt1) < 0.001, "the cracked brain keeps its spoil clock")
	# SWEEP 4A HOOK (pharmacy, chunk 3): the furnace pays the spoiled value; selling is throwing.
	me.revive_full()
	_clear()
	await _until(func(): return game.economy.placed(), 5.0)
	var furn: Node3D = game.economy.furnace
	me.take_into("brain_discharged", 1, 300)
	i = _slot_of("brain_discharged")
	me.slots[i]["bt"] = game.world_time - 135.0
	me.selected = i
	await _frames(20)
	_check(me.slots[_slot_of("brain_discharged")].has("bt"), "a brain in hand keeps its spoil clock (host stamp)")
	me.slots[_slot_of("brain_discharged")]["bt"] = game.world_time - 135.0
	var want: int = b.current_value(me.slots[_slot_of("brain_discharged")])
	var m0 := game.money
	me.teleport(furn.global_position + furn.global_basis.z * 1.1)
	var to := furn.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me._yaw = me.bot_yaw
	me.rotation.y = me.bot_yaw
	me.head.rotation.x = 0.0
	me._pitch = 0.0
	await _frames(3)
	game.drop_selected(me, 1.0)
	await _until(func(): return not me.holding("brain_discharged"), 3.0)
	await _frames(10)
	_check(absi(game.money - m0 - want) <= 1 and not me.holding("brain_discharged"), "throwing it into the furnace pays the spoiled price, about $%d (got %d)" % [want, game.money - m0])
	# Clean the floor of test brains.
	for node in game.world_items.values().duplicate():
		if Brains.is_brain(String(node.kind)):
			game.world_items.erase(node.item_id)
			node.queue_free()


func _blender() -> void:
	_say("---- the blender")
	var b: Node = game.brains
	await _until(func(): return b.blender != null, 5.0)
	_check(b.blender != null and game.find_interactable("blender") == b.blender, "a blender stands in the level (interact_id blender, %s)" % b.blender_mode)
	var rooms: Array = game.level_info.get("rooms", [])
	var br: Dictionary = {}
	for r in rooms:
		if String(r.kind) == "break_room":
			br = r
	if not br.is_empty():
		var rect: Rect2 = br.rect
		_check(rect.grow(0.3).has_point(Vector2(b.blender.global_position.x, b.blender.global_position.z)) and b.blender_mode == "counter",
			"it sits on a break-room counter (%s at %s)" % [b.blender_mode, str(b.blender.global_position)])
	b.on_reset()
	_clear()
	_check(b.blender.interact_prompt(me).begins_with("!"), "without a brain it says why: '%s'" % b.blender.interact_prompt(me))
	me.take_into("brain_walk_in", 1, 150)
	me.slots[_slot_of("brain_walk_in")]["bt"] = game.world_time
	me.selected = _slot_of("brain_walk_in")
	_check(b.blender.interact_prompt(me).begins_with("Hold E") and b.blender.interact_hold() > 1.0, "holding a brain: '%s'" % b.blender.interact_prompt(me))
	await _stand_at_blender()
	# A short hold does nothing.
	me.bot_interact = true
	await _frames(40)
	me.bot_interact = false
	_check(me.holding("brain_walk_in") and b.points(me.peer_id, "walk_in") == 0.0 and b.blend_progress(me.peer_id) > 0.0, "a short hold blends a little and keeps the brain (progress %.2f)" % b.blend_progress(me.peer_id))
	await _frames(40)
	_check(b.blend_progress(me.peer_id) == 0.0, "letting go winds the blend back down")
	me.bot_interact = true
	var drunk := await _until(func(): return not me.holding("brain_walk_in"), 3.0)
	me.bot_interact = false
	_check(drunk and b.points(me.peer_id, "walk_in") == 1.0 and b.level(me.peer_id, "walk_in") == 1, "a full 1.5 s hold drinks it: +1.0 fresh, Hive Eyes 1 (%.2f)" % b.points(me.peer_id, "walk_in"))
	# Spoiling +0.75, rotten +0.5.
	for e in [[160.0, 0.75], [300.0, 0.5]]:
		me.take_into("brain_discharged", 1, 350)
		var j := _slot_of("brain_discharged")
		me.slots[j]["bt"] = game.world_time - float(e[0])
		me.selected = j
		var before: float = b.points(me.peer_id, "discharged")
		me.bot_interact = true
		await _until(func(): return not me.holding("brain_discharged"), 3.0)
		me.bot_interact = false
		await _frames(2)
		_check(absf(b.points(me.peer_id, "discharged") - before - float(e[1])) < 0.001, "a brain %d s old adds %.2f" % [int(e[0]), float(e[1])])
	_check(b.level(me.peer_id, "discharged") == 1, "1.25 points is Echo level 1")
	b.add_points(me.peer_id, "walk_in", 9.0)
	_check(b.points(me.peer_id, "walk_in") == 3.0 and b.level(me.peer_id, "walk_in") == Brains.MAX_LEVEL, "points cap at level 3")
	var ns: Dictionary = b.net_state()
	(ns.p[me.peer_id] as Array)[0] = 99.0
	_check(b.points(me.peer_id, "walk_in") == 3.0, "net_state is a copy")
	_check(game._global_fields().has("br"), "br rides in the global snapshot")
	b.on_reset()


func _abilities_nothing_and_echo() -> void:
	_say("---- R with nothing, then Echo")
	var b: Node = game.brains
	b.on_reset()
	me.revive_full()
	_clear()
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "nothing" and game.message.contains("Nothing happens"), "no brains: R says 'Nothing happens.' (%s)" % b.last_result)
	# Something to see around us: loot, a supply, a monster.
	var here: Vector3 = me.global_position
	var props := []
	for k in [["laptop", 1], ["gauze", 2], ["stethoscope", 1]]:
		var p = game._spawn_item(k[0], k[1], Transform3D(Basis(), here + Vector3(randf_range(-4, 4), 0.3, randf_range(-4, 4))), WorldItem.State.LOOSE)
		props.append(p)
	var mon: Node = game._add_monster("discharged", game._floor_at(here + Vector3(6, 0, 0)))
	await _frames(4)
	b.add_points(me.peer_id, "discharged", 1.0)
	_check(b.slot_of(me.peer_id, "echo") == 0, "reaching level 1 puts Echo in the first empty slot")
	me.bot_ability_slot = b.slot_of(me.peer_id, "echo")
	var t0 := game.world_time
	me.bot_ability += 1
	await _frames(3)
	var heard := false
	for n in game.recent_noises(1.0):
		if String(n.kind) == "echo" and is_equal_approx(float(n.loudness), 1.2) and float(n.time) >= t0:
			heard = true
	_check(b.last_result == "echo" and heard, "Echo: the host hears noise 1.2 at the player (%s)" % b.last_result)
	_check(b.echo_view.active and b.echo_view.ghosts.size() > 0 and b.echo_view.target_count >= 3, "the Echo view is up with %d outlines of %d things" % [b.echo_view.ghosts.size(), b.echo_view.target_count])
	_check(b.echo_view.ghosts.size() <= b.echo_view.MAX_GHOSTS and b.echo_view.target_count <= b.echo_view.MAX_TARGETS, "and bounded")
	_check(absf(float(b.last_echo.r) - 18.0) < 0.01 and absf(float(b.last_echo.s) - 3.25) < 0.01, "level 1: 18 m for 3.25 s (%s)" % str(b.last_echo))
	var kinds := {}
	for e in b.echo_view.ghosts:
		kinds[str((e.ghost as MeshInstance3D).material_override.get_shader_parameter("col"))] = true
	_check(kinds.size() >= 3, "outlines come in several colours (%d)" % kinds.size())
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "cooldown", "a second R right away: cooldown (%s)" % b.last_result)
	await _until(func(): return not b.echo_view.active, 5.0)
	_check(not b.echo_view.active and b.echo_view.ghosts.is_empty(), "the Echo view ends by itself and frees its outlines")
	_check(b.cooldown_left(me.peer_id, "discharged") > 10.0, "Echo cooldown about 20 s (%.1f left)" % b.cooldown_left(me.peer_id, "discharged"))
	for p in props:
		game.world_items.erase(p.item_id)
		p.queue_free()
	game.kill_monster(mon)
	b.on_reset()


func _hive_eyes() -> void:
	_say("---- Hive Eyes")
	var b: Node = game.brains
	b.on_reset()
	me.revive_full()
	# The stand-in Walk-In is a Discharged body that hunts by sound: keep it from ending the view by
	# hitting me, except where the test hits me on purpose.
	me.bot_invulnerable = true
	b.add_points(me.peer_id, "walk_in", 1.0)
	b.add_points(me.peer_id, "discharged", 0.5)
	_check(b.slot_of(me.peer_id, "hive_in") == 0 and b.slot_of(me.peer_id, "echo") == -1, "Walk-In reached level 1 (0.5 points is not): Hive Eyes took the first slot, Echo has none yet")
	me.bot_ability_slot = 0
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "no_walk_in" and not me.hive_view, "no Walk-In nearby: nothing happens but a hint (%s)" % b.last_result)
	var here: Vector3 = me.global_position
	var far: Node = b.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 0)) + Vector3(80, 0, 0))
	await _frames(2)
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "no_walk_in", "a Walk-In 80 m away is out of range (level 1: 30 m)")
	var wi: Node = b.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 12)))
	_check(wi != null and String(wi.kind) == "walk_in", "a Walk-In to borrow (%s)" % (wi.name if wi != null else "null"))
	await _frames(2)
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "hive" and me.hive_view and b.local_hive_active() and b.camera() != null, "Hive Eyes: my view jumps into the Walk-In (%s)" % b.last_result)
	await _frames(3)
	var cam: Camera3D = b.camera()
	var eye_d := cam.global_position.distance_to(wi.global_position + Vector3.UP * 1.7) if cam != null else 99.0
	_check(eye_d < 0.7, "the camera rides at the Walk-In's eyes (%.2f m off)" % eye_d)
	_check(bool(me.report_full().get("hv", false)), "the player report carries hv")
	# Helpless: the body does not move.
	var p0 := me.global_position
	me.bot_move = Vector2(0, -1)
	await _frames(30)
	me.bot_move = Vector2.ZERO
	_check(me.global_position.distance_to(p0) < 0.05, "the body stands still while looking elsewhere (moved %.2f)" % me.global_position.distance_to(p0))
	# R ends it.
	me.bot_ability += 1
	await _frames(3)
	_check(not me.hive_view and not b.local_hive_active() and b.camera() == null, "R brings me back")
	_check(b.cooldown_left(me.peer_id, "walk_in") > 10.0, "Hive Eyes cooldown about 12 s after it ends")
	me.bot_ability += 1
	await _frames(40)
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "cooldown", "R during the cooldown: not ready (%s)" % b.last_result)
	# Ends by itself: 5 s + 2 per level.
	b._cd.clear()
	me.bot_ability += 1
	await _frames(3)
	var started := game.world_time
	await _until(func(): return not me.hive_view, 10.0)
	var lasted := game.world_time - started
	_check(absf(lasted - 7.0) < 0.3, "level 1 lasts about 7 s (%.2f)" % lasted)
	# A hit ends it.
	b._cd.clear()
	b._press_grace.clear()
	me.bot_ability += 1
	await _frames(3)
	_check(me.hive_view, "back in the Walk-In's eyes")
	game.damage_player(me, 1, "test")
	await _frames(3)
	_check(not me.hive_view and not b.local_hive_active(), "getting hit snaps me back")
	# The Walk-In dies: it ends.
	me.revive_full()
	b._cd.clear()
	b._press_grace.clear()
	me.bot_ability += 1
	await _frames(3)
	_check(me.hive_view, "looking through it again")
	game.kill_monster(wi)
	await _frames(3)
	_check(not me.hive_view and b.camera() == null, "the Walk-In dies: back in my body")
	# Sedated (when the monsters worker's sedation exists): the same rule, checked through the method.
	var wi2: Node = b.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 8)))
	b._cd.clear()
	b._press_grace.clear()
	await _frames(2)
	me.bot_ability += 1
	await _frames(3)
	if wi2.has_method("sedate"):
		wi2.sedate(30.0)
		await _frames(3)
		_check(not me.hive_view, "the Walk-In is sedated: back in my body")
	else:
		me.bot_ability += 1
		await _frames(3)
		_say("(no Monster.sedate on this branch: the sedation end is covered by has_method only)")
	# Both paths at once: each gets its own slot, independent of order.
	b.on_reset()
	b.add_points(me.peer_id, "walk_in", 1.0)
	b.add_points(me.peer_id, "discharged", 1.0)
	_check(b.slot_of(me.peer_id, "hive_in") == 0 and b.slot_of(me.peer_id, "echo") == 1, "Hive Eyes and Echo each land in their own slot")
	game.kill_monster(wi2)
	game.kill_monster(far)
	b.echo_view.stop()
	me.bot_invulnerable = false


## SWEEP 4A HOOK (controls): add_ability() / set_level() / slot_of(), the 4-slot cap, and a
## refusal past it. Synthetic ids so this does not depend on how many real abilities exist.
func _ability_slots() -> void:
	_say("---- ability slots (sweep 4a)")
	var b: Node = game.brains
	b.on_reset()
	_check(b.add_ability(me.peer_id, "test_a"), "slot 1 accepts a new ability")
	_check(b.add_ability(me.peer_id, "test_b"), "slot 2 accepts a new ability")
	_check(b.add_ability(me.peer_id, "test_c"), "slot 3 accepts a new ability")
	_check(b.add_ability(me.peer_id, "test_d"), "slot 4 accepts a new ability")
	_check(not b.add_ability(me.peer_id, "test_e"), "a 5th ability is refused")
	_check(b.slots_for(me.peer_id) == ["test_a", "test_b", "test_c", "test_d"], "each landed in the first empty slot, in order")
	_check(b.add_ability(me.peer_id, "test_a") and b.slot_of(me.peer_id, "test_a") == 0, "adding an ability already in a slot is a no-op, not a refusal")
	b.on_reset()
	_check(b.slots_for(me.peer_id) == ["", "", "", ""], "a reset clears the slots")
	b.set_level(me.peer_id, "echo", 2)
	_check(b.level(me.peer_id, "discharged") == 2 and b.slot_of(me.peer_id, "echo") == 0, "set_level(peer, id, lvl) sets the level and grants the slot directly")
	b.on_reset()


func _reset_on_game_over() -> void:
	_say("---- game over resets absorbed brains")
	var b: Node = game.brains
	b.on_reset()
	me.revive_full()
	b.add_points(me.peer_id, "walk_in", 2.0)
	b.add_points(me.peer_id, "discharged", 1.0)
	var wi: Node = b.spawn_walk_in(game._floor_at(me.global_position + Vector3(0, 0, 6)))
	await _frames(2)
	me.bot_ability += 1
	await _frames(3)
	_check(me.hive_view, "(looking through a Walk-In when the run ends)")
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
		await _frames(3)
	game._end_shift(false, "Test: everyone is out.")
	var ok := await _until(func(): return game.phase == Game.Phase.LOBBY, 30.0)
	await _frames(5)
	_check(ok and b.points(me.peer_id, "walk_in") == 0.0 and b.points(me.peer_id, "discharged") == 0.0 and b.net_state().p.is_empty(), "after game over every absorbed brain is gone")
	_check(not me.hive_view and not b.local_hive_active(), "and nobody is left looking through a Walk-In")
	if is_instance_valid(wi):
		game.kill_monster(wi)
	await _until(func(): return b.blender != null, 5.0)
	_check(b.blender != null and is_instance_valid(b.blender), "the new hospital has a blender again")


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


func _newest(kind: String) -> Node:
	var best = null
	for it in game.world_items.values():
		if it.kind == kind and (best == null or it.item_id > best.item_id):
			best = it
	return best


func _overlay_of(node: Node) -> Material:
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).material_overlay != null:
			return (mi as MeshInstance3D).material_overlay
	return null


func _stand_at_blender() -> void:
	var bl: Node3D = game.brains.blender
	var front: Vector3 = bl.global_position + bl.global_transform.basis.z * 0.75
	me.teleport(game._floor_at(Vector3(front.x, bl.global_position.y, front.z)))
	var to := bl.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_aim_id = "blender"
	await _frames(3)


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
	print("[braintest] ", line)


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
