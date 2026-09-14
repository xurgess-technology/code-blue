extends Node
## Headless checks for the dev room.
##
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn
##       Solo: types the secret code on the menu, enters the dev room, shoots a monster, a
##       dummy and a bot (kills and knock-downs), orders a bot to carry to the shelf and to you,
##       to operate one surgery step, checks god mode and noclip. Exits 0 when all pass.
##
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn -- --net=host [--port=7791]
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn -- --net=client [--port=7791]
##       Two processes: the host opens the dev room with a dummy and a monster; the client joins,
##       takes a dispenser item, asks for the dev gun, kills the monster and the dummy and spawns
##       a bot through the host. Both exit 0 when the client's actions landed on the host.
##
##   godot --path . tools/devtest.tscn -- --shots
##       Windowed screenshots of the room, the panel and the gun into tools/dev_shots/.

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const LootTableScript := preload("res://scripts/economy/loot_table.gd")
const SHOT_DIR := "res://tools/dev_shots"

var main: Node3D
var game: Game
var dev: Node
var me: Player
var net_role := ""
var port := 7791
var shots := false
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"net": net_role = v
			"port": port = int(v)
			"shots": shots = true
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	match net_role:
		"host": _run_host()
		"client": _run_client()
		_: _run_solo()


func _physics_process(delta: float) -> void:
	t += delta
	if _now() > (480.0 if net_role == "" else 150.0) and not _done:
		_fail("timed out")
		_finish()


# =========================================================================
# solo
# =========================================================================

func _run_solo() -> void:
	# The secret code on the title screen arms Solo.
	# Real key events, through the same input path the keyboard uses. Typing into the name
	# field must not count; typing on the bare menu must.
	var saved_name: String = main.menu._name_edit.text
	main.menu._name_edit.grab_focus()
	await _type("clear")
	_check(not main.menu.dev_code.armed, "typing the code into the name field does nothing")
	main.menu._name_edit.text = saved_name
	get_viewport().gui_release_focus()
	await _type("xxclear")
	_check(main.menu.dev_code.armed, "typing the code on the menu arms it")
	# What the Solo button does, minus saving the name to the player's prefs.
	_check(main.menu._dev_start(false), "Solo while armed goes to the dev room")
	await _frames(10)
	_check(game.dev_mode, "Solo while armed enters the dev room")
	_check(game.phase == Game.Phase.SHIFT, "the dev room is on shift")
	_check(bool(game.level_info.get("dev_room", false)), "the level is the dev room")
	_check(not main.menu.dev_code.armed, "the code disarms after use")
	me = game.local_player()
	me.bot_active = true
	await _seconds(2.0)
	if shots:
		await _take_shots()
		_finish()
		return

	# The panel: F1 opens it, its buttons ask the dev room, F1 closes it.
	await _key(KEY_F1)
	_check(main.dev_panel.is_open(), "F1 opens the dev panel in the dev room")
	var buttons: Array = main.dev_panel.find_children("*", "Button", true, false)
	for b in buttons:
		if b.text == "+ Dummy":
			b.pressed.emit()
	_check(dev.bots.size() == 1, "the panel's + Dummy button spawns a dummy")
	for b in buttons:
		if b.text == "Remove all":
			b.pressed.emit()
	_check(dev.bots.is_empty(), "the panel's Remove all button removes it")
	var gun_box: CheckBox = main.dev_panel._c["gun"]
	gun_box.button_pressed = true
	_check(dev.has_gun(me.peer_id), "the panel's Dev gun box hands you the gun")
	await _key(KEY_F1)
	_check(not main.dev_panel.is_open(), "F1 closes the dev panel")

	# ---- monsters: kill one, knock one down
	var m = dev.spawn_monster("discharged", "pen")
	var mid: int = m.monster_id
	await _seconds(0.5)
	_stand(Vector3(12.0, 0, 9.4))
	await _frames(2)
	_shoot(m, DevRoomScript.KILL)
	await _frames(3)
	_check(not game.monsters.has(mid), "a kill shot removes the monster")
	_check(game.get_node("Entities").find_child("DevCorpse", false, false) != null, "the killed monster leaves a falling body")
	var m2 = dev.spawn_monster("discharged", "pen")
	await _seconds(0.3)
	_shoot(m2, DevRoomScript.KNOCK)
	await _frames(3)
	_check(game.monsters.has(m2.monster_id) and m2.mode == Monster.Mode.STUNNED, "a knock-down shot stuns a monster without killing it")
	var nurse = dev.spawn_monster("night_nurse", "pen")
	await _seconds(0.3)
	_shoot(nurse, DevRoomScript.KNOCK)
	await _frames(2)
	_check(game.monsters.has(nurse.monster_id) and nurse.calm > 1.0, "a knock-down shot makes the Night Nurse stand down")
	dev.request("kill_monsters")
	await _frames(3)
	_check(game.monsters.is_empty(), "kill all monsters")
	await _seconds(0.5)
	_check(game.get_node("Entities").find_children("DevTracer", "", false, false).is_empty(), "tracers clean themselves up")

	# ---- a dummy
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	await _frames(5)
	_stand(dummy.global_position + Vector3(0, 0, 4.0))
	await _frames(2)
	_shoot(dummy, DevRoomScript.KNOCK)
	await _frames(2)
	_check(dummy.alive and dummy.downed and dummy.hp == 0 and dummy.bleed > 290.0, "a knock-down shot downs a dummy (hp=%d downed=%s bleed=%.0f)" % [dummy.hp, str(dummy.downed), dummy.bleed])
	await _seconds(0.5)
	_shoot(dummy, DevRoomScript.KILL, 0.3)
	await _frames(2)
	_check(not dummy.alive and not dummy.downed, "a kill shot kills a downed dummy outright")

	# ---- a bot: knock down, then work
	dev.request("revive_all")
	var bid: int = dev.spawn_bot("bot", me)
	var bot: Player = game.players[bid]
	var brain = dev.brains[bid]
	await _seconds(0.5)
	_stand(bot.global_position + Vector3(3.0, 0, 0))
	await _frames(2)
	_shoot(bot, DevRoomScript.KNOCK)
	await _frames(2)
	_check(bot.alive and bot.downed, "a knock-down shot downs a bot")
	await _seconds(0.6)   # the knock-back slide
	var pos_before := bot.global_position
	await _seconds(1.0)
	_check(bot.global_position.distance_to(pos_before) < 0.2 and brain.status == "downed", "a downed bot lies still (moved %.2f m, status '%s')" % [bot.global_position.distance_to(pos_before), brain.status])
	dev.request("revive_all")
	await _frames(2)
	_check(bot.alive and not bot.downed and bot.hp == bot.max_hp, "revive all gets a downed bot up")
	await _seconds(1.0)

	dev.order_bot(bid, "carry", "gauze", "shelf")
	var ok := await _until(func(): return brain.completed >= 1, 60.0)
	_check(ok and game.shelf_count("gauze") > 0, "a bot carries gauze to the shelf (shelf %s, status '%s')" % [str(game.shelf), brain.status])

	_stand(Vector3(16.0, 0, 15.0))
	dev.order_bot(bid, "carry", "forceps", "player", me.peer_id)
	ok = await _until(func(): return me.holding("forceps"), 60.0)
	_check(ok, "a bot brings forceps into your hands (status '%s')" % brain.status)

	dev.request("patient", {"patient": "bob", "ailment": "gunshot"})
	dev.request("clear_shelf")
	await _frames(5)
	_check(game.patient_body != null, "a patient is on the table")
	dev.order_bot(bid, "operate")
	ok = await _until(func(): return int(game.case.get("step_index", 0)) >= 1, 150.0)
	_check(ok, "a bot stocks the shelf and operates the first step (step %d, status '%s')" % [int(game.case.get("step_index", 0)), brain.status])
	_check(brain.completed >= 3 and brain.order == "stay", "the operate order completes")
	dev.request("clear_patient")

	# ---- downed (sweep 2 wave 3): a bot carries a downed dummy to the player table and stitches it
	var did2: int = dev.spawn_bot("dummy")
	var dummy2: Player = game.players[did2]
	await _frames(3)
	dev.request("down_me", {"id": did2})
	await _frames(2)
	_check(dummy2.downed, "the panel's Down button downs a dummy")
	_check(not game.player_table.is_empty() and game.find_interactable("player_table") != null, "the dev room has a player table")
	dev.request("clear_shelf")
	dev.order_bot(bid, "carry", "", "table")
	ok = await _until(func(): return dummy2.on_table, 60.0)
	_check(ok, "a bot lifts a downed dummy and lays it on the player table (status '%s')" % brain.status)
	_check(game.player_surgery.patient() == dummy2 and game.player_surgery.patient_body != null, "the stitches case starts with the lying body")
	dev.order_bot(bid, "operate")
	ok = await _until(func(): return bot.operating, 90.0)
	var kits_before: int = game.shelf_count("suture_kit")
	_check(ok and kits_before >= 1, "a bot stocks a suture kit and starts stitching (shelf %d, status '%s')" % [kits_before, brain.status])
	ok = await _until(func(): return dummy2.alive and not dummy2.downed, 60.0)
	_check(ok and dummy2.hp == Game.REVIVE_HP, "the bot stitches the dummy back up (status '%s', hp %d)" % [brain.status, dummy2.hp])
	_check(game.shelf_count("suture_kit") == kits_before - 1 and game.player_surgery.case.is_empty(), "one suture kit was used and the table is free")
	dev.remove_bot(did2)

	# ---- the shift loop's patient hooks (loop, sweep 2): phone call, extra patient, two tables
	await _loop_hooks()
	await _doors_hooks()   # DOORS HOOK

	_stand(bot.global_position + Vector3(0, 0, 3.0))
	await _frames(2)
	_shoot(bot, DevRoomScript.KILL)
	await _frames(2)
	_check(not bot.alive, "a kill shot kills a bot")

	# ---- the player: god mode and noclip, damage and knock-down APIs
	dev.request("god", {"on": true})
	var m3 = dev.spawn_monster("discharged", "front", me)
	var hp_before := me.hp
	game.monster_hit_player(m3, me)
	_check(me.hp == hp_before, "god mode ignores monster hits")
	dev.request("god", {"on": false})
	game.knock_down_player(me, "test")
	_check(me.alive and me.downed and me.hp == 0, "knock_down_player downs you")
	game.kill_monster(m3)
	await _seconds(0.5)
	me.revive_full()
	for b in main.dev_panel.find_children("*", "Button", true, false):
		if b.text == "Down me":
			b.pressed.emit()
	_check(me.downed, "the panel's Down me button downs you")
	me.revive_full()
	game.damage_player(me, 1, "test")
	_check(me.hp == me.max_hp - 1, "damage_player takes HP")
	game.damage_player(me, 9, "test")
	_check(me.alive and me.downed, "damage to 0 HP downs instead of killing")
	me.revive_full()

	dev.request("noclip", {"on": true})
	_stand(Vector3(12.0, 0, 16.5), PI)
	me.bot_move = Vector2(0, -1)
	await _seconds(1.2)
	me.bot_move = Vector2.ZERO
	_check(me.global_position.z > 18.5, "noclip walks through the south wall (z=%.1f)" % me.global_position.z)
	dev.request("noclip", {"on": false})
	_stand(Vector3(12.0, 0, 15.0))

	dev.request("time_scale", {"v": 0.5})
	await _frames(2)
	_check(is_equal_approx(Engine.time_scale, 0.5), "time scale applies")
	dev.request("time_scale", {"v": 1.0})
	dev.request("lights", {"on": false})
	await _frames(2)
	var bulb: OmniLight3D = game.level_info.lights[0].node.get_node("Bulb")
	_check(not bulb.visible, "lights toggle off")
	dev.request("lights", {"on": true})
	dev.request("pen", {"open": true})
	await _frames(2)
	_check(game.level_info.dev_gate.collision_layer == 0, "the pen gate opens")

	# ---- inventory (sweep 2): loot dispensers, the money panel, the dev room's sell bin and shop
	dev.request("pen", {"open": false})
	me.slots = Player.empty_slots()
	me.selected = 0
	var cubby = game.find_interactable("dev_disp_defibrillator")
	_check(cubby != null, "the loot rack has a defibrillator dispenser")
	var loot_disps := 0
	for k in LootTableScript.kinds():
		if game.find_interactable("dev_disp_%s" % k) != null:
			loot_disps += 1
	_check(loot_disps == LootTableScript.LOOT.size(), "every loot kind has a dispenser (%d)" % loot_disps)
	if cubby != null:
		_stand(cubby.global_position + Vector3(0, 0, -1.2), 0.0)
		me.bot_aim_id = "dev_disp_defibrillator"
		await _frames(3)
		me.bot_press += 1
		await _frames(4)
		me.bot_aim_id = ""
		_check(me.holding("defibrillator") and me.free_slot_count() == 2 and int(me.selected_stack().get("v", 0)) > 0,
			"the dispenser hands over a defibrillator worth money, in two slots")
	_check(game.economy.placed() and game.economy.mode == "economy", "the dev room has its sell bin, shop and pile (mode %s)" % game.economy.mode)
	await _key(KEY_F1)
	var money_before: int = game.money
	for b in main.dev_panel.find_children("*", "Button", true, false):
		if b.text == "+$1000":
			b.pressed.emit()
	_check(game.money == money_before + 1000, "the panel's +$1000 button gives money ($%d)" % game.money)
	await _key(KEY_F1)
	var bin: Node3D = game.economy.sell_bin
	_stand(bin.global_position + bin.global_basis.z * 1.2, 0.0)
	me.bot_aim_id = "sell_bin"
	await _frames(3)
	var value: int = int(me.selected_stack().get("v", 0))
	me.bot_press += 1
	await _frames(4)
	_check(not me.holding("defibrillator") and game.money == money_before + 1000 + value, "the dev room's sell bin buys the defibrillator for $%d" % value)
	var shop: Node3D = game.economy.shop
	_stand(shop.global_position + shop.global_basis.z * 1.3, 0.0)
	me.bot_aim_id = "shop"
	await _frames(3)
	var bars: int = game.gold_bars
	me.bot_press += 1
	await _frames(4)
	me.bot_aim_id = ""
	_check(game.gold_bars == bars + 1, "the dev room's shop sells a gold bar")
	dev.request("money", {"reset": true})
	_check(game.money == 0 and game.gold_bars == 0, "the panel's money reset clears money and bars")

	await _nurse_watch_solo()

	# Leaving resets the global state.
	main._back_to_menu("")
	await _frames(3)
	_check(not game.dev_mode and is_equal_approx(Engine.time_scale, 1.0), "leaving the dev room resets it")
	_check(not dev.nurse_ignore_watch and dev.nurse_walk == "" and dev.nurse_pace == 0, "leaving the dev room resets the Night Nurse settings")
	_finish()


## NURSE HOOK (night nurse model): the panel's "Night Nurse" section. Watched in the lit room she
## freezes; with "Nurse ignores being watched" she walks her loop in plain view, animating; off
## again she freezes; "Follows me" stops short of you and never hits; the pace sets her speed and
## the Walk clip's rate with it.
func _nurse_watch_solo() -> void:
	dev.request("kill_monsters")
	dev.request("god", {"on": false})
	dev.request("lights", {"on": true})
	await _frames(3)
	me.revive_full()
	_stand(Vector3(20.0, 0, 12.5), PI / 2.0)
	await _frames(3)
	_press_panel("Nurse in front")
	await _frames(3)
	var nurse = _first_nurse()
	_check(nurse != null and nurse.model.nurse != null and nurse.global_position.distance_to(me.global_position) < 5.0,
		"the panel's Nurse in front spawns a Night Nurse in her Blender model in front of you")
	if nurse == null:
		return
	var box: CheckBox = main.dev_panel._c["nurse_ignore"]
	_check(box.text == "Nurse ignores being watched", "the panel has the 'Nurse ignores being watched' toggle")
	var watch := func(seconds: float) -> Dictionary:
		var start: Vector3 = nurse.global_position
		var out := {"moved": 0.0, "observed_ever": false, "lit_and_seen": 0, "frames": 0, "anim_moving": 0, "walk": 0}
		var last: Vector3 = start
		var end := t + seconds
		while t < end:
			_look_at(nurse.global_position + Vector3.UP * 1.4)
			await get_tree().physics_frame
			out.moved += nurse.global_position.distance_to(last)
			last = nurse.global_position
			out.frames += 1
			if nurse.observed:
				out.observed_ever = true
			if Perception.observed_any(game, nurse.brain.body_points(nurse.global_position)):
				out.lit_and_seen += 1
			if nurse.model.anim.speed_scale > 0.0:
				out.anim_moving += 1
			if nurse.model.anim.current_animation == "Walk":
				out.walk += 1
		return out
	await watch.call(0.6)
	var w0: Dictionary = await watch.call(1.0)
	_check(w0.moved < 0.02 and nurse.observed and nurse.model.anim.speed_scale == 0.0,
		"watched in the lit room she stands frozen (moved %.3f m, clip rate %.2f)" % [w0.moved, nurse.model.anim.speed_scale])
	box.button_pressed = true
	var walk_opt: OptionButton = main.dev_panel._c["nurse_walk"]
	walk_opt.select(2)
	walk_opt.item_selected.emit(2)
	var pace_opt: OptionButton = main.dev_panel._c["nurse_pace"]
	pace_opt.select(1)
	pace_opt.item_selected.emit(1)
	await _frames(2)
	_check(dev.nurse_ignore_watch and dev.nurse_walk == "loop" and dev.nurse_loop.size() == 4 and dev.nurse_pace == 1,
		"the toggle, 'Walks a loop here' and the pace reach the dev room (loop %d corners)" % dev.nurse_loop.size())
	var w1: Dictionary = await watch.call(4.0)
	var hp_before: int = me.hp
	_check(w1.moved > 3.0 and not w1.observed_ever and w1.lit_and_seen > w1.frames * 0.8,
		"with the toggle on she walks her loop in plain view (%.1f m in 4 s, lit and seen %d of %d frames)" % [w1.moved, w1.lit_and_seen, w1.frames])
	_check(w1.anim_moving > w1.frames * 0.9 and w1.walk > w1.frames * 0.6 and absf(nurse.model.anim.speed_scale - 1.6) < 0.5,
		"and animates while watched: Walk %d of %d frames, rate %.2f at the stalk pace" % [w1.walk, w1.frames, nurse.model.anim.speed_scale])
	box.button_pressed = false
	await watch.call(0.4)
	var w2: Dictionary = await watch.call(1.0)
	_check(w2.moved < 0.02 and nurse.observed and nurse.model.anim.speed_scale == 0.0 and not dev.nurse_ignore_watch,
		"the toggle off: she freezes again (moved %.3f m)" % w2.moved)
	# Follow me: she comes to 2.5 m and stands; with the pace at creep she walks at 0.8 m/s.
	box.button_pressed = true
	walk_opt.select(1)
	walk_opt.item_selected.emit(1)
	pace_opt.select(2)
	pace_opt.item_selected.emit(2)
	_stand(Vector3(13.5, 0, 16.0), PI / 2.0)
	var sp := 0.0
	var rate := 0.0
	var end := t + 14.0
	while t < end:
		_look_at(nurse.global_position + Vector3.UP * 1.4)
		await get_tree().physics_frame
		if nurse.moving and nurse.global_position.distance_to(me.global_position) > 4.0:
			sp = nurse.speed
			rate = nurse.model.anim.speed_scale
		if not nurse.moving and nurse.global_position.distance_to(me.global_position) < 3.2 and t > end - 10.0:
			break
	await _seconds(1.0)
	var gap: float = Vector2(nurse.global_position.x - me.global_position.x, nurse.global_position.z - me.global_position.z).length()
	_check(gap > 2.0 and gap < 3.3 and not nurse.moving and me.hp == hp_before and me.hp == me.max_hp,
		"'Follows me' brings her to %.2f m and she stands there without hitting (hp %d)" % [gap, me.hp])
	_check(absf(sp - 0.8) < 0.15 and absf(rate - sp) < 0.2, "the creep pace: %.2f m/s, Walk at %.2fx" % [sp, rate])
	dev.request("kill_monsters")
	await _frames(3)


func _first_nurse():
	for m in game.monsters.values():
		if m.kind == "night_nurse":
			return m
	return null


func _loop_hooks() -> void:
	_check(game.patient_tables.size() >= 2, "the dev room has two patient tables (%d)" % game.patient_tables.size())
	_press_panel("Clear tables")
	await _frames(3)
	_check(game.cases.is_empty() and game.patient_body == null, "the panel's Clear tables empties both tables")
	_press_panel("Phone call")
	await _frames(2)
	_check(game.cases.size() == 1 and String(game.cases[0].state) == "incoming", "the panel's Phone call sends an incoming patient")
	var ok := await _until(func(): return not game.loop.crews.is_empty(), 5.0)
	_check(ok, "paramedics come at once")
	ok = await _until(func(): return not game.cases.is_empty() and String(game.cases[0].state) == "on_table", 90.0)
	_check(ok, "the paramedics put the patient on a table")
	_press_panel("Extra patient")
	await _frames(2)
	ok = await _until(func(): return game.cases.size() == 2 and String(game.cases[1].state) == "on_table", 90.0)
	_check(ok, "the panel's Extra patient brings a second patient")
	if ok:
		var t0 := int(game.cases[0].table)
		var t1 := int(game.cases[1].table)
		_check(t0 != t1 and game.body_for_table(t0) != null and game.body_for_table(t1) != null, "two patients on two tables (%d, %d)" % [t0, t1])
		_check(bool(game.cases[1].get("optional", false)), "the extra patient is optional")
	_press_panel("Skip grace")   # no grace in the dev room: must do nothing harmful
	await _frames(2)
	_check(game.phase == Game.Phase.SHIFT and game.cases.size() == 2, "Skip grace in the dev room changes nothing")
	# A third call with both tables full makes room (the dev room keeps taking patients).
	game.finish_case(int(game.cases[0].id), true)
	_press_panel("Phone call")
	await _frames(2)
	ok = await _until(func(): return game.cases.filter(func(c): return String(c.state) == "on_table").size() == 2, 90.0)
	_check(ok, "another call with a stable patient on a table replaces them")
	_press_panel("Clear tables")
	await _frames(3)
	ok = await _until(func(): return game.loop.crews.is_empty(), 60.0)
	_check(game.cases.is_empty() and ok, "cleared again")


## DOORS HOOK: the pen's two doors and the panel's door buttons.
func _doors_hooks() -> void:
	var doors: Node = game.doors
	_check(doors.doors.has("dr_dev_hinged") and doors.doors.has("dr_dev_double"), "the dev room has a hinged door and double doors (%s)" % str(doors.doors.keys()))
	if not doors.doors.has("dr_dev_hinged"):
		return
	var h: Node = doors.doors["dr_dev_hinged"]
	var dd: Node = doors.doors["dr_dev_double"]
	dev.request("kill_monsters")   # earlier monsters may have wandered through them
	game.doors.set_all(false)
	await _seconds(1.5)
	_check(h.is_closed() and dd.is_closed(), "both shut")
	_press_panel("Open all doors")
	await _seconds(1.2)
	_check(absf(h.amount) > 0.85 and absf(dd.amount) > 0.85, "the panel's Open all doors opens them (%.2f, %.2f)" % [h.amount, dd.amount])
	_press_panel("Close all doors")
	await _seconds(1.2)
	_check(h.is_closed() and dd.is_closed(), "the panel's Close all doors shuts them")
	_press_panel("Regenerate wings now")
	await _frames(3)
	_check(game.message.contains("No wings"), "Regenerate wings now in the dev room explains there are none (%s)" % game.message)
	# A monster in one bay reaches the next through the hinged door.
	var m = dev.spawn_monster("discharged", "pen")
	m.global_position = Vector3(4.0, 0.0, 3.75)
	m.brain.target = Vector3(12.0, 0.0, 3.75)
	m.mode = m.Mode.RUSH
	var through := await _until(func():
		if m.mode != m.Mode.RUSH:
			m.brain.target = Vector3(12.0, 0.0, 3.75)
			m.mode = m.Mode.RUSH
		return m.global_position.x > 9.5, 12.0)
	_check(through and absf(h.amount) > 0.5, "a Discharged rushing across the pen bursts through the hinged door (x %.1f, door %.2f)" % [m.global_position.x, h.amount])
	dev.request("kill_monsters")
	_press_panel("Close all doors")
	await _seconds(1.0)


func _press_panel(text: String) -> void:
	for b in main.dev_panel.find_children("*", "Button", true, false):
		if b.text == text:
			b.pressed.emit()
			return
	_check(false, "the dev panel has a '%s' button" % text)


# =========================================================================
# two processes
# =========================================================================

var _host_dummy := 0
var _host_monster = null


func _run_host() -> void:
	var err := Net.host("Host", port)
	if err != "":
		_fail("host failed: " + err)
		_finish()
		return
	game.start_session(DevRoomScript.SEED)
	main.menu.hide_menu()
	await _seconds(1.0)
	me = game.local_player()
	me.bot_active = true
	_host_dummy = dev.spawn_bot("dummy")
	_host_monster = dev.spawn_monster("discharged", "pen")
	_say("dev room up; waiting for the client")
	var joined := await _until(func(): return Net.names.size() >= 2, 40.0)
	_check(joined, "a client joined")
	if not joined:
		_finish()
		return
	var ok := await _until(func():
		var bots := 0
		for p in game.players.values():
			if p.is_bot and dev.bots.get(p.peer_id, {}).get("kind", "") == "bot":
				bots += 1
		return game.monsters.is_empty() and not game.players[_host_dummy].alive and bots >= 1, 60.0)
	_check(ok, "the client's shots and bot request landed on the host (monsters %d, dummy alive %s)" % [game.monsters.size(), str(game.players[_host_dummy].alive)])
	var client_id: int = Net.peer_ids()[-1]
	_check(dev.has_gun(client_id), "the client holds the dev gun on the host")
	# NURSE HOOK: the client turns "Nurse ignores being watched" on (with a loop), off, then asks for
	# "follow" as its last request.
	var seen := {"on": false, "loop": 0}
	ok = await _until(func():
		if dev.nurse_ignore_watch:
			seen.on = true
		seen.loop = maxi(int(seen.loop), dev.nurse_loop.size())
		return seen.on and dev.nurse_walk == "follow" and not dev.nurse_ignore_watch, 70.0)
	_check(ok and int(seen.loop) == 4 and dev.nurse_who == client_id,
		"the client's Night Nurse requests landed on the host (loop corners %d, follows peer %d)" % [int(seen.loop), dev.nurse_who])
	await _seconds(1.0)
	_finish()


func _run_client() -> void:
	Net.local_name = "Client"
	var err := Net.join("127.0.0.1", port)
	if err != "":
		_fail("join failed: " + err)
		_finish()
		return
	main.menu.hide_menu()
	var ok := await _until(func():
		me = game.local_player()
		return game.dev_mode and me != null and game.phase == Game.Phase.SHIFT and not game.monsters.is_empty() and dev.bots.size() >= 1, 40.0)
	_check(ok, "the client lands in the dev room and sees the dummy and the monster")
	if not ok:
		_finish()
		return
	_check(bool(game.level_info.get("dev_room", false)), "the client built the dev room")
	me.bot_active = true
	var dummy_id: int = dev.bots.keys()[0]
	var dummy: Player = game.players[dummy_id]
	_check(dummy.is_bot, "the dummy replicated as a Player")

	# A dispenser works for a client.
	_stand(Vector3(22.4, 0, 9.2), -PI / 2.0)
	me.bot_aim_id = "dev_disp_anesthetic"
	await _frames(3)
	me.bot_press += 1
	ok = await _until(func(): return me.holding("anesthetic"), 5.0)
	_check(ok, "a client takes from a dispenser")

	dev.request("gun", {"on": true})
	ok = await _until(func(): return dev.has_gun(me.peer_id), 5.0)
	_check(ok, "the client's gun request came back from the host")

	var m = game.monsters.values()[0]
	_stand(Vector3(12.0, 0, 9.4))
	await _seconds(0.5)
	for i in 3:
		if game.monsters.is_empty():
			break
		_shoot(game.monsters.values()[0], DevRoomScript.KILL)
		await _seconds(0.6)
	_check(game.monsters.is_empty(), "the client killed the monster on the host")

	_stand(dummy.global_position + Vector3(0, 0, 4.0))
	await _seconds(0.5)
	_shoot(dummy, DevRoomScript.KNOCK)
	ok = await _until(func(): return dummy.downed, 4.0)
	_check(ok, "the client's knock-down downed the dummy (hp %d)" % dummy.hp)
	await _seconds(0.3)
	_shoot(dummy, DevRoomScript.KILL, 0.3)
	ok = await _until(func(): return not dummy.alive, 4.0)
	_check(ok, "the client killed the dummy")

	dev.request("spawn_bot", {"kind": "bot"})
	ok = await _until(func():
		for p in game.players.values():
			if p.is_bot and dev.bots.get(p.peer_id, {}).get("kind", "") == "bot":
				return true
		return false, 5.0)
	_check(ok, "a bot the client asked for appears on the client")

	# NURSE HOOK: a Night Nurse the client watches under the lights: frozen, then walking with the
	# host's "ignores being watched" on, then frozen again when it goes off.
	_stand(Vector3(20.0, 0, 12.5), PI / 2.0)
	await _seconds(0.8)
	dev.request("spawn_monster", {"kind": "night_nurse", "where": "front"})
	ok = await _until(func(): return _first_nurse() != null, 6.0)
	_check(ok and _first_nurse().model.nurse != null, "the client sees the Night Nurse it asked for, in her model")
	if ok:
		var nurse = _first_nurse()
		await _watch_client(nurse, 1.5)
		var f0: Dictionary = await _watch_client(nurse, 1.5)
		_check(f0.moved < 0.05 and nurse.observed and nurse.model.anim.speed_scale == 0.0,
			"client: watched, she is frozen and her clip is stopped (moved %.3f m)" % f0.moved)
		dev.request("nurse_pace", {"i": 1})
		dev.request("nurse_walk", {"mode": "loop"})
		dev.request("nurse_ignore_watch", {"on": true})
		ok = await _until(func(): return dev.nurse_ignore_watch and dev.nurse_walk == "loop" and dev.nurse_pace == 1, 6.0)
		_check(ok, "client: the host's Night Nurse settings replicate back (ignore %s, walk '%s', pace %d)" % [str(dev.nurse_ignore_watch), dev.nurse_walk, dev.nurse_pace])
		await _watch_client(nurse, 1.0)
		var f1: Dictionary = await _watch_client(nurse, 4.0)
		if shots:
			# Windowed client (`-- --net=client --shots`): what the client sees while she walks.
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
			dev.request("lights", {"on": false})
			await _watch_client(nurse, 2.0)
			await _shot("12_client_nurse_walking_watched")
			dev.request("lights", {"on": true})
		_check(f1.moved > 2.0 and not f1.observed_ever and f1.anim_moving > f1.frames * 0.8 and f1.walk > f1.frames * 0.5,
			"client: with the toggle on she keeps walking while it watches (%.1f m in 4 s, animating %d / walk %d of %d frames)" % [f1.moved, f1.anim_moving, f1.walk, f1.frames])
		dev.request("nurse_ignore_watch", {"on": false})
		await _until(func(): return not dev.nurse_ignore_watch, 6.0)
		await _watch_client(nurse, 1.5)
		var f2: Dictionary = await _watch_client(nurse, 1.5)
		_check(f2.moved < 0.05 and nurse.observed and nurse.model.anim.speed_scale == 0.0,
			"client: toggle off, she freezes again (moved %.3f m)" % f2.moved)
	dev.request("nurse_walk", {"mode": "follow"})
	await _seconds(2.0)
	_finish()


## Client: look at the nurse for `seconds` (real time) and report what it did.
func _watch_client(nurse: Node, seconds: float) -> Dictionary:
	var out := {"moved": 0.0, "observed_ever": false, "frames": 0, "anim_moving": 0, "walk": 0}
	var last: Vector3 = nurse.global_position
	var end := _now() + seconds
	while _now() < end and is_instance_valid(nurse):
		_look_at(nurse.global_position + Vector3.UP * 1.4)
		await get_tree().physics_frame
		out.moved += nurse.global_position.distance_to(last)
		last = nurse.global_position
		out.frames += 1
		out.observed_ever = out.observed_ever or nurse.observed
		if nurse.model.anim.speed_scale > 0.0:
			out.anim_moving += 1
		if nurse.model.anim.current_animation == "Walk":
			out.walk += 1
	return out


# =========================================================================
# screenshots
# =========================================================================

func _take_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	dev.request("gun", {"on": true})
	dev.request("god", {"on": true})
	dev.spawn_monster("discharged", "pen")
	dev.spawn_monster("night_nurse", "pen")
	for i in 3:
		dev.spawn_bot("dummy")
	dev.set_patient("seal", "amputation")
	dev.stock_shelf()
	await _seconds(1.0)
	_stand(Vector3(12.0, 0, 17.4))
	_look_at(Vector3(12.0, 1.0, 4.0))
	await _seconds(1.0)
	await _shot("01_room_from_spawn")
	_stand(Vector3(14.0, 0, 15.5))
	_look_at(Vector3(4.0, 0.9, 11.5))
	await _seconds(0.6)
	await _shot("02_or_table_and_containers")
	_stand(Vector3(19.0, 0, 13.4))
	_look_at(Vector3(23.6, 0.9, 13.2))
	await _seconds(0.6)
	await _shot("03_dispensers")
	# The gun, from the lab side of the barrier.
	_stand(Vector3(12.0, 0, 9.5))
	_look_at(Vector3(12.0, 0.8, 3.0))
	await _seconds(0.6)
	_shoot(game.monsters.values()[0], DevRoomScript.KNOCK)
	await _frames(2)
	await _shot("04_gun_knock_tracer")
	await _seconds(0.5)
	_shoot(game.monsters.values()[game.monsters.size() - 1], DevRoomScript.KILL)
	await _frames(3)
	await _shot("05_gun_kill_tracer")
	await _seconds(0.9)
	await _shot("06_monster_falls")
	dev.request("kill_monsters")
	_stand(Vector3(17.75, 0, 14.8))
	_look_at(Vector3(17.75, 1.0, 10.2))
	await _seconds(0.5)
	var d: Player = game.players[dev.bots.keys()[1]]
	_shoot(d, DevRoomScript.KNOCK)
	await _seconds(0.7)
	await _shot("07_dummies_one_down")
	main.dev_panel.toggle(true)
	await _seconds(0.5)
	await _shot("08_panel")
	main.dev_panel.toggle(false)
	var bid: int = dev.spawn_bot("bot", me)
	dev.set_patient("bob", "gunshot")
	dev.request("clear_shelf")
	dev.order_bot(bid, "operate")
	_stand(Vector3(10.5, 0, 14.2))
	_look_at(Vector3(8.5, 1.0, 11.5))
	await _until(func(): return game.players[bid].operating, 60.0)
	await _seconds(3.0)
	await _shot("09_bot_operating")
	# NURSE HOOK: the Night Nurse section. Lights off, flashlight on her, "ignores being watched" on,
	# walking a loop round you at the stalk pace.
	dev.remove_bot(bid)
	dev.request("clear_patient")
	dev.request("kill_monsters")
	dev.request("lights", {"on": false})
	_stand(Vector3(20.0, 0, 12.5), PI / 2.0)
	await _seconds(0.3)
	dev.request("spawn_monster", {"kind": "night_nurse", "where": "front"})
	dev.request("nurse_ignore_watch", {"on": true})
	dev.request("nurse_pace", {"i": 1})
	dev.request("nurse_walk", {"mode": "loop"})
	me.set_flashlight(true)
	var nurse = _first_nurse()
	var end := t + 3.3
	while t < end:
		_look_at(nurse.global_position + Vector3.UP * 1.3)
		await get_tree().physics_frame
	await _shot("10_nurse_walks_in_the_flashlight")
	main.dev_panel.toggle(true)
	await _seconds(0.4)
	await _shot("11_panel_night_nurse")
	main.dev_panel.toggle(false)
	dev.request("nurse_ignore_watch", {"on": false})
	end = t + 1.5
	while t < end:
		_look_at(nurse.global_position + Vector3.UP * 1.3)
		await get_tree().physics_frame
	await _shot("12_nurse_frozen_toggle_off")


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	_say("wrote %s" % path)


# =========================================================================
# helpers
# =========================================================================

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


## Aim at a target's chest and fire through the real gun path (client prediction included).
func _shoot(target: Node3D, mode: String, height := 1.3) -> void:
	var aim: Vector3 = target.global_position + Vector3.UP * height
	_look_at(aim)
	var from := me.head.global_position
	dev.fire(me, from, aim - from, mode)


func _check(ok: bool, what: String) -> void:
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _fail(what: String) -> void:
	_check(false, what)


func _say(line: String) -> void:
	var tag := "devtest" if net_role == "" else "devtest:%s" % net_role
	print("[%s] t=%.1f %s" % [tag, t, line])


func _finish() -> void:
	if _done:
		return
	_done = true
	_say("------------------------------------------")
	_say("result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _key(code: Key) -> void:
	for down in [true, false]:
		var ev := InputEventKey.new()
		ev.pressed = down
		ev.keycode = code
		ev.physical_keycode = code
		Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame


func _type(text: String) -> void:
	for ch in text:
		for down in [true, false]:
			var ev := InputEventKey.new()
			ev.pressed = down
			ev.unicode = ch.unicode_at(0)
			ev.keycode = OS.find_keycode_from_string(ch.to_upper())
			ev.physical_keycode = ev.keycode
			Input.parse_input_event(ev)
		await get_tree().process_frame


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


## Waits on game time solo; on real time in the network test, where the other process runs at
## its own pace (--fixed-fps makes game time race ahead of the wall clock).
func _until(cond: Callable, timeout: float) -> bool:
	var end := _now() + timeout
	while _now() < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())


func _now() -> float:
	return t if net_role == "" else Time.get_ticks_msec() / 1000.0
