extends Node
## Headless checks for dev mode.
##
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn
##       Solo, in a normal hospital: the OR supply closet has no dev door and F1 does nothing; the
##       pharmacy fax's secret order (3141592653 placebo pills, no money) prints a reply page, turns
##       dev mode on and builds the hidden room past the parking lot. Then the closet door, the room
##       (the gun on monsters, dummies and bots; dispensers, the pen doors, lights and gate), the
##       panel's tools (shift, go to, database, abilities, no monsters, no game over, infinite
##       vitals, money, god mode, noclip, the Night Nurse, pockets) and DEV MODE OFF. Exits 0 when
##       all pass.
##
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn -- --net=host [--port=7791]
##   godot --headless --fixed-fps 60 --path . tools/devtest.tscn -- --net=client [--port=7791]
##       Two processes: the host turns dev mode on and puts a dummy and a monster in the room; the
##       client joins, sees dev mode and builds the room, takes a dispenser item, asks for the dev
##       gun, kills the monster and the dummy and spawns a bot through the host. Both exit 0 when
##       the client's actions landed on the host.
##
##   godot --path . tools/devtest.tscn -- --shots
##       Windowed screenshots of the reply fax, the closet door, the room, the panel and the gun into
##       tools/dev_shots/.

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const LootTableScript := preload("res://scripts/economy/loot_table.gd")
const SHOT_DIR := "res://tools/dev_shots"
const SEED := 4242
## This machine's player files the panel's tools touch; put back as they were at the end.
const KEEP_FILES := ["user://database.save", "user://tips.cfg"]

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
var _kept := {}
## The hidden room's corner (its own frame's origin) in world space.
var o := Vector3.ZERO


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"net": net_role = v
			"port": port = int(v)
			"shots": shots = true
	for path in KEEP_FILES:
		_kept[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
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
	if _now() > (600.0 if net_role == "" else 180.0) and not _done:
		_fail("timed out")
		_finish()


func _start_solo() -> void:
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Tester")
	game.start_session(SEED)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(0.5)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true


# =========================================================================
# solo
# =========================================================================

func _run_solo() -> void:
	await _start_solo()
	_check(not game.dev_on() and not dev.room_ready(), "a new session starts without dev mode or the room")
	_check(game.find_interactable("dev_door_closet") == null, "no dev door in the OR supply closet before dev mode")
	await _key(KEY_F1)
	_check(not main.dev_panel.is_open(), "F1 does nothing without dev mode")

	# ---- the secret order: the pharmacy fax with no money
	var money_before: int = game.money
	await _secret_order()
	_check(game.money == money_before, "the secret order costs nothing ($%d -> $%d)" % [money_before, game.money])
	_check(game.economy.pharmacy == null or game.economy.pharmacy._queue.is_empty(), "and no delivery comes")
	o = dev.room.global_position if dev.room_ready() else Vector3.ZERO
	var lot: Rect2 = game.level_info.get("neutral_rect", Rect2())
	_check(lot.size != Vector2.ZERO and o.z > lot.end.y + 10.0, "the room stands past the parking lot (room z %.0f, lot ends %.0f)" % [o.z, lot.end.y])
	var closet = game.find_interactable("dev_door_closet")
	_check(closet != null, "dev mode puts the dev door in the OR supply closet")
	if closet == null:
		_finish()
		return
	_check(closet.interact_prompt(me) == "Enter the dev room", "the closet door opens for dev mode")
	var normal: int = game.money
	game.add_money(100, "test")
	game.economy.request_order({"placebo_pills": 2})
	_check(game.money == normal + 100 - 2 * game.PILL_PRICE, "an ordinary pill order still charges")

	if shots:
		await _take_shots()
		_finish()
		return

	# ---- through the closet door and back
	_stand(closet.global_position + closet.global_basis.z * 1.0, closet.rotation.y + PI)
	await _use("dev_door_closet")
	_check(dev.in_room(me.global_position), "the closet door walks you into the hidden room (%s)" % str(me.global_position))
	_stand(o + Vector3(DevRoomScript.LevelScript.EXIT_X, 0, 16.6), PI)
	await _use("dev_door_exit")
	_check(me.global_position.distance_to(closet.global_position) < 2.0, "the room's door walks you back to the closet")

	# ---- the panel: F1 anywhere, its buttons ask the host
	await _key(KEY_F1)
	_check(main.dev_panel.is_open(), "F1 opens the dev panel in the hospital")
	_press_panel("+ Dummy")
	_check(dev.bots.size() == 1, "the panel's + Dummy button spawns a dummy")
	var dummy0: Player = game.players[dev.bots.keys()[0]]
	_check(dev.in_room(dummy0.global_position), "on the room's dummy floor")
	_press_panel("Remove all")
	_check(dev.bots.is_empty(), "the panel's Remove all button removes it")
	var gun_box: CheckBox = main.dev_panel._c["gun"]
	gun_box.button_pressed = true
	_check(dev.has_gun(me.peer_id), "the panel's Dev gun box hands you the gun")
	await _key(KEY_F1)
	_check(not main.dev_panel.is_open(), "F1 closes the dev panel")

	# ---- monsters in the pen: kill one, knock one down
	var m = dev.spawn_monster("discharged", "pen")
	var mid: int = m.monster_id
	_check(dev.in_room(m.global_position), "a pen monster spawns in the room's pen")
	await _seconds(0.5)
	_stand(o + Vector3(12.0, 0, 9.4))
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
	dev.remove_bot(did)

	# ---- a bot in the OR: knock down, then work
	await _bot_work()

	# ---- the shift loop from the panel
	await _shift_tools()
	await _doors_hooks()   # DOORS HOOK

	# ---- the player: god mode and noclip, damage and knock-down APIs (the only player going down
	# would end the run otherwise)
	dev.request("no_game_over", {"on": true})
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
	_press_panel("Down me")
	_check(me.downed, "the panel's Down me button downs you")
	me.revive_full()
	game.damage_player(me, 1, "test")
	_check(me.hp == me.max_hp - 1, "damage_player takes HP")
	game.damage_player(me, 9, "test")
	_check(me.alive and me.downed, "damage to 0 HP downs instead of killing")
	me.revive_full()
	await _frames(2)
	dev.request("no_game_over", {"on": false})
	_check(game.phase == Game.Phase.SHIFT, "still on shift after the downing checks")

	dev.request("noclip", {"on": true})
	_stand(o + Vector3(12.0, 0, 16.5), PI)
	me.bot_move = Vector2(0, -1)
	await _seconds(1.2)
	me.bot_move = Vector2.ZERO
	_check(me.global_position.z > o.z + 18.5, "noclip walks through the room's south wall (z=%.1f)" % (me.global_position.z - o.z))
	dev.request("noclip", {"on": false})
	_stand(o + Vector3(12.0, 0, 15.0))
	await _free_cam()

	dev.request("time_scale", {"v": 0.5})
	await _frames(2)
	_check(is_equal_approx(Engine.time_scale, 0.5), "time scale applies")
	dev.request("time_scale", {"v": 1.0})
	dev.request("lights", {"on": false})
	await _frames(2)
	var bulb: OmniLight3D = dev.room_info.lights[0].node.get_node("Bulb")
	_check(not bulb.visible, "the room's lights toggle off")
	dev.request("lights", {"on": true})
	dev.request("pen", {"open": true})
	await _frames(2)
	_check(dev.room_info.dev_gate.collision_layer == 0, "the pen gate opens")
	dev.request("pen", {"open": false})

	await _loot_and_money()
	await _panel_extras()
	await _nurse_watch_solo()

	# POCKETS HOOK: the panel builds a pocket space beside the hospital and walks you in and out.
	for kind in ["Factory", "Restaurant"]:
		_press_panel(kind)
		await _frames(3)
		_check(game.pockets.active() and String(game.pockets.pocket.kind) == kind.to_lower(), "the panel's %s button builds the %s" % [kind, kind.to_lower()])
		_press_panel("Go there")
		await _frames(3)
		_check(game.pockets.in_pocket(me.global_position), "Go there puts you in the %s" % kind.to_lower())
		_press_panel("Back to the start")
		await _frames(3)
		_check(not game.pockets.in_pocket(me.global_position), "Back to the start brings you back")
	_press_panel("Remove")
	await _frames(3)
	_check(not game.pockets.active() and dev.dev_pocket == "", "Remove takes the pocket away")

	# ---- DEV MODE OFF
	dev.request("god", {"on": true})
	dev.spawn_bot("dummy")
	await _key(KEY_F1)
	_press_panel("DEV MODE OFF")
	await _frames(3)
	_check(not game.dev_on() and not main.dev_panel.is_open(), "DEV MODE OFF turns dev mode off and closes the panel")
	_check(dev.bots.is_empty() and not dev.is_god(me) and not dev.has_gun(me.peer_id), "and drops the bots, god mode and the gun")
	_check(game.find_interactable("dev_door_closet") == null, "the closet's dev door is gone again")
	await _key(KEY_F1)
	_check(not main.dev_panel.is_open(), "F1 does nothing again")

	# Leaving resets the global state.
	game.set_dev_tools(true)
	dev.request("nurse_pace", {"i": 2})
	main._back_to_menu("")
	await _frames(3)
	_check(not game.dev_on() and is_equal_approx(Engine.time_scale, 1.0), "leaving the session ends dev mode")
	_check(not dev.nurse_ignore_watch and dev.nurse_walk == "" and dev.nurse_pace == 0, "leaving resets the Night Nurse settings")
	_finish()


## The pharmacy fax UI: tick placebo pills, type the code, SEND FAX. The reply page prints while
## the room builds, then the fax closes.
func _secret_order() -> void:
	var ui = game.economy.fax_ui
	game.economy.open_fax_ui()
	await _frames(3)
	var row: Dictionary = {}
	for r in ui._rows:
		if String(r.kind) == "placebo_pills":
			row = r
	_check(not row.is_empty(), "the fax has placebo pills")
	if row.is_empty():
		return
	row.box.pressed.emit()
	row.edit.text = "3141592653"
	row.edit.text_changed.emit(row.edit.text)
	ui._refresh()
	_check(ui._qty(row) == 3141592653 and not ui._send.disabled, "SEND FAX takes 3141592653 placebo pills with $%d" % game.money)
	row.edit.focus_exited.emit()
	_check(String(row.edit.text) == "3141592653", "the quantity keeps all ten digits")
	ui._send.pressed.emit()
	var replying := await _until(func(): return ui._reply >= 0.0, 5.0)
	_check(replying and ui.is_open(), "the fax stays open and prints a reply page")
	var early: bool = game.dev_on()
	var ok := await _until(func(): return not ui.is_open(), 25.0)
	_check(not early, "dev mode comes on after the reply starts printing")
	_check(ok and game.dev_on() and dev.room_ready(), "the fax closes with dev mode on and the room built")
	_check(game.message.contains("DEV MODE"), "everyone is told (%s)" % game.message)


func _bot_work() -> void:
	var t0: int = int(game.patient_tables[0].index)
	var or_spot: Vector3 = game.table_position(t0) + Vector3(0, 0, 2.6)
	_stand(or_spot, 0.0)
	await _frames(3)
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

	_stand(or_spot, 0.0)
	dev.request("spawn_item", {"kind": "gauze", "count": 3})
	dev.order_bot(bid, "carry", "gauze", "shelf")
	var ok := await _until(func(): return brain.completed >= 1, 60.0)
	_check(ok and game.shelf_count("gauze") > 0 and not bot.holding("gauze"), "a bot carries gauze to the OR's storage shelves (%d there, status '%s')" % [game.shelf_count("gauze"), brain.status])

	dev.request("spawn_item", {"kind": "forceps", "count": 1})
	dev.order_bot(bid, "carry", "forceps", "player", me.peer_id)
	ok = await _until(func(): return me.holding("forceps"), 60.0)
	_check(ok, "a bot brings forceps into your hands (status '%s')" % brain.status)
	me.slots = Player.empty_slots()

	_press_panel("Put on the table")
	await _frames(5)
	_check(game.phase == Game.Phase.SHIFT and not game.cases.is_empty(), "the panel's Put on the table clocks in and puts a patient on a table")
	dev.request("clear_shelf")
	for kind in Items.SURGICAL:
		dev.request("spawn_item", {"kind": kind, "count": 6})
	var cid: int = int(game.cases[0].id) if not game.cases.is_empty() else -1
	dev.order_bot(bid, "operate")
	ok = await _until(func(): return int(game.case_by_id(cid).get("step_index", 0)) >= 1, 150.0)
	_check(ok, "a bot gets the step's item in hand and operates the first step (status '%s')" % brain.status)
	_check(brain.completed >= 3 and brain.order == "stay", "the operate order completes")
	dev.request("clear_patient")
	await _frames(3)

	# ---- downed: a bot carries a downed dummy to a free hospital table and stitches it up
	var did2: int = dev.spawn_bot("dummy")
	var dummy2: Player = game.players[did2]
	dummy2.teleport(game._floor_at(or_spot + Vector3(1.5, 0, 0.5)))
	await _frames(3)
	dev.request("down_me", {"id": did2})
	await _frames(2)
	_check(dummy2.downed, "the panel's Down button downs a dummy")
	dev.request("clear_shelf")
	dev.order_bot(bid, "carry", "", "table")
	ok = await _until(func(): return dummy2.on_table, 60.0)
	_check(ok, "a bot lifts a downed dummy and lays it on a free patient table (status '%s')" % brain.status)
	_check(game.player_surgery.patient() == dummy2, "the stitches case starts")
	dev.request("spawn_item", {"kind": "suture_kit", "count": 2})
	dev.order_bot(bid, "operate")
	ok = await _until(func(): return dummy2.alive and not dummy2.downed, 120.0)
	_check(ok and dummy2.hp == Game.REVIVE_HP, "the bot stitches the dummy back up (status '%s', hp %d)" % [brain.status, dummy2.hp])
	dev.remove_bot(did2)
	_stand(bot.global_position + Vector3(0, 0, 3.0))
	await _frames(2)
	_shoot(bot, DevRoomScript.KILL)
	await _frames(2)
	_check(not bot.alive, "a kill shot kills a bot")
	dev.remove_bot(bid)


func _shift_tools() -> void:
	_press_panel("Clear tables")
	await _frames(3)
	_check(game.cases.is_empty(), "the panel's Clear tables empties the tables")
	_press_panel("Phone call")
	await _frames(2)
	_check(game.cases.size() == 1 and String(game.cases[0].state) == "incoming", "the panel's Phone call sends an incoming patient")
	_press_panel("Skip to table")
	await _frames(2)
	_check(game.cases.size() == 1 and String(game.cases[0].state) == "on_table", "the panel's Skip to table puts them straight on a table")
	game.loop._end_call()
	_press_panel("Extra patient")
	await _frames(2)
	_check(game.loop.call_state == "ringing", "the panel's Extra patient rings the phone (%s)" % game.loop.call_state)
	game.loop._end_call()
	_press_panel("Clear tables")
	await _frames(2)
	_press_panel("Clock out (force)")
	await _frames(3)
	_check(game.phase != Game.Phase.SHIFT, "the panel's Clock out (force) ends the shift (phase %d)" % game.phase)
	var ok := await _until(func(): return game.phase == Game.Phase.LOBBY, 90.0)
	_check(ok, "the next shift's lobby")
	# No monsters: the next shift comes up empty.
	var box: CheckBox = main.dev_panel._c["monsters_off"]
	box.button_pressed = true
	await _frames(2)
	_press_panel("Clock in")
	ok = await _until(func(): return game.phase == Game.Phase.SHIFT, 90.0)
	_check(ok and game.monsters.is_empty(), "with No monsters the panel's Clock in starts an empty shift (%d monsters)" % game.monsters.size())
	box.button_pressed = false
	await _frames(2)
	# Infinite vitals: a patient at 50 stays at 50.
	dev.request("patient", {"patient": "bob", "ailment": "gunshot"})
	await _frames(3)
	dev.request("vitals", {"v": 50.0})
	(main.dev_panel._c["freeze"] as CheckBox).button_pressed = true
	await _seconds(6.0)
	var c: Dictionary = game.cases.filter(func(x): return String(x.state) == "on_table")[0] if not game.cases.is_empty() else {}
	_check(not c.is_empty() and absf(float(c.vitals) - 50.0) < 0.3, "Infinite vitals holds a patient's vitals (%.2f)" % float(c.get("vitals", -1)))
	(main.dev_panel._c["freeze"] as CheckBox).button_pressed = false
	_press_panel("Clear tables")
	# No game over: nobody standing and the run goes on.
	(main.dev_panel._c["no_game_over"] as CheckBox).button_pressed = true
	me.bot_invulnerable = false
	game.knock_down_player(me, "test")
	await _seconds(1.0)
	_check(game.phase == Game.Phase.SHIFT, "No game over: everyone down and the shift goes on")
	me.revive_full()
	me.refresh_downed_visuals()
	me.bot_invulnerable = true
	(main.dev_panel._c["no_game_over"] as CheckBox).button_pressed = false


## DOORS HOOK: the pen's two doors and the panel's door buttons.
func _doors_hooks() -> void:
	var doors: Node = game.doors
	_check(doors.doors.has("dr_dev_hinged") and doors.doors.has("dr_dev_double"), "the room's pen has a hinged door and double doors")
	if not doors.doors.has("dr_dev_hinged"):
		return
	var h: Node = doors.doors["dr_dev_hinged"]
	var dd: Node = doors.doors["dr_dev_double"]
	dev.request("kill_monsters")
	_press_panel("Close all doors")
	await _seconds(1.5)
	_check(h.is_closed() and dd.is_closed(), "both shut")
	_press_panel("Open all doors")
	await _seconds(1.2)
	_check(absf(h.amount) > 0.85 and absf(dd.amount) > 0.85, "the panel's Open all doors opens them (%.2f, %.2f)" % [h.amount, dd.amount])
	_press_panel("Close all doors")
	await _seconds(1.2)
	_check(h.is_closed() and dd.is_closed(), "the panel's Close all doors shuts them")
	# A monster in one bay reaches the next through the hinged door.
	var m = dev.spawn_monster("discharged", "pen")
	m.global_position = o + Vector3(4.0, 0.0, 3.75)
	m.brain.target = o + Vector3(12.0, 0.0, 3.75)
	m.mode = m.Mode.RUSH
	var through := await _until(func():
		if m.mode != m.Mode.RUSH:
			m.brain.target = o + Vector3(12.0, 0.0, 3.75)
			m.mode = m.Mode.RUSH
		return m.global_position.x > o.x + 9.5, 12.0)
	_check(through and absf(h.amount) > 0.5, "a Discharged rushing across the pen bursts through the hinged door (x %.1f, door %.2f)" % [m.global_position.x - o.x, h.amount])
	dev.request("kill_monsters")
	_press_panel("Close all doors")
	await _seconds(1.0)


## inventory (sweep 2): the room's loot dispensers, the money panel, the hospital's furnace.
## The panel's Free camera: the view leaves your eyes, main keeps it, P swaps who has the input.
func _free_cam() -> void:
	var fc = main.dev_panel.free_cam
	var box: CheckBox = main.dev_panel._c["free_cam"]
	var eye: Vector3 = me.camera.global_position
	box.button_pressed = true
	await _frames(3)
	_check(fc.is_on() and fc.current and fc.global_position.distance_to(eye) < 0.5, "the Free camera box takes the view from your eyes")
	_check(me.dev_input_held and me.body_visual.visible, "flying, the surgeon stands still and shows")
	fc.swap()
	await _frames(2)
	_check(not fc.flying and not me.dev_input_held and fc.current, "P hands the surgeon back; the view stays on the free camera")
	fc.swap()
	_check(fc.flying and me.dev_input_held, "and P again flies the camera")
	box.button_pressed = false
	await _frames(2)
	_check(not fc.is_on() and me.camera.current and not me.dev_input_held and not me.body_visual.visible, "unticking it puts you back behind your eyes")


func _loot_and_money() -> void:
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
		await _use("dev_disp_defibrillator")
		_check(me.holding("defibrillator") and me.free_slot_count() == 2 and int(me.selected_stack().get("v", 0)) > 0,
			"the dispenser hands over a defibrillator worth money, in two slots")
	var money_before: int = game.money
	_press_panel("+$1000")
	_check(game.money == money_before + 1000, "the panel's +$1000 button gives money ($%d)" % game.money)
	# SWEEP 4A HOOK (pharmacy, chunk 3): selling is throwing into the furnace, not an E-press.
	var furn: Node3D = game.economy.furnace
	furn.set_hatch(true, false)   # hub rebuild: the hatch over the window starts shut
	var value: int = int(me.selected_stack().get("v", 0))
	# The throw itself is inventorytest's and looptest's; here the dropped stack goes straight into
	# the fire chamber, which is what selling needs.
	me.teleport(furn.global_position + furn.global_basis.z * 1.1)
	await _frames(2)
	game.drop_selected(me, 0.0)
	await _frames(2)
	var chamber: Node3D = furn.get_node("FireZone").get_child(1)
	for it in game.world_items.values():
		if it.kind == "defibrillator":
			it.global_position = chamber.global_position
	var sold := false
	if not sold:
		sold = await _until(func(): return game.money != money_before + 1000, 3.0)
	_check(sold and game.money == money_before + 1000 + value, "the furnace burns a dispensed defibrillator for $%d" % value)
	dev.request("money", {"reset": true})
	_check(game.money == 0, "the panel's money reset clears money")


## The tools new with dev mode: go to, the database and abilities.
func _panel_extras() -> void:
	var places: OptionButton = main.dev_panel._c["places"]
	main.dev_panel._refresh()
	var or_i := -1
	for i in places.item_count:
		if places.get_item_text(i) == "Or":
			or_i = i
	_check(or_i >= 0 and places.item_count >= 6, "Go to lists the hospital's rooms (%d)" % places.item_count)
	if or_i >= 0:
		places.select(or_i)
		_press_panel("Go")
		await _frames(2)
		var or_rect: Rect2
		for r in game.level_info.rooms:
			if String(r.kind) == "or":
				or_rect = r.rect
		_check(or_rect.grow(0.5).has_point(Vector2(me.global_position.x, me.global_position.z)), "Go takes you to the OR")
	_press_panel("Dev room")
	await _frames(2)
	_check(dev.in_room(me.global_position), "the panel's Dev room button takes you there")
	_press_panel("All abilities")
	await _frames(2)
	_check(game.brains.slot_of(me.peer_id, "echo") >= 0 and game.brains.slot_of(me.peer_id, "hive_in") >= 0, "the panel's All abilities grants Echo and Hive Eyes")
	_press_panel("Unlock every entry")
	_check(game.db_record("hive").harvested and game.db_record("night_nurse").scanned, "Unlock every entry fills this machine's database")
	_press_panel("Reset database")
	_check(game.database.is_empty(), "Reset database wipes it")


## NURSE HOOK (night nurse model): the panel's "Night Nurse" section, in the lit room.
func _nurse_watch_solo() -> void:
	dev.request("kill_monsters")
	dev.request("god", {"on": false})
	dev.request("lights", {"on": true})
	await _frames(3)
	me.revive_full()
	_stand(o + Vector3(20.0, 0, 12.5), PI / 2.0)
	await _frames(3)
	_press_panel("Nurse in front")
	await _frames(3)
	var nurse = _first_nurse()
	_check(nurse != null and nurse.model.nurse != null and nurse.global_position.distance_to(me.global_position) < 5.0,
		"the panel's Nurse in front spawns a Night Nurse in her Blender model in front of you")
	if nurse == null:
		return
	var box: CheckBox = main.dev_panel._c["nurse_ignore"]
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
		"the toggle, 'Walks a loop here' and the pace reach the host (loop %d corners)" % dev.nurse_loop.size())
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
	box.button_pressed = true
	walk_opt.select(1)
	walk_opt.item_selected.emit(1)
	pace_opt.select(2)
	pace_opt.item_selected.emit(2)
	_stand(o + Vector3(13.5, 0, 16.0), PI / 2.0)
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
	box.button_pressed = false
	walk_opt.select(0)
	walk_opt.item_selected.emit(0)
	dev.request("kill_monsters")
	await _frames(3)


func _first_nurse():
	for m in game.monsters.values():
		if m.kind == "night_nurse":
			return m
	return null


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
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	game.start_session(SEED)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(1.0)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	_check(game.dev_on() and dev.room_ready(), "the host turned dev mode on and built the room")
	_host_dummy = dev.spawn_bot("dummy")
	_host_monster = dev.spawn_monster("discharged", "pen")
	_say("dev mode up; waiting for the client")
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
		return game.monsters.is_empty() and not game.players[_host_dummy].alive and bots >= 1, 80.0)
	_check(ok, "the client's shots and bot request landed on the host (monsters %d, dummy alive %s)" % [game.monsters.size(), str(game.players[_host_dummy].alive)])
	var client_id: int = Net.peer_ids()[-1]
	_check(dev.has_gun(client_id), "the client holds the dev gun on the host")
	var client = game.players.get(client_id)
	_check(client != null and dev.in_room(client.global_position), "the client walked through the closet door into the room")
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
	if main.launching:
		await main.launched
	var err := Net.join("127.0.0.1", port)
	if err != "":
		_fail("join failed: " + err)
		_finish()
		return
	main.menu.hide_menu()
	var ok := await _until(func():
		me = game.local_player()
		return game.dev_on() and dev.room_ready() and me != null and not game.monsters.is_empty() and dev.bots.size() >= 1, 60.0)
	_check(ok, "the client sees dev mode, builds the room and sees the dummy and the monster")
	if not ok:
		_finish()
		return
	o = dev.room.global_position
	me.bot_active = true
	var dummy_id: int = dev.bots.keys()[0]
	var dummy: Player = game.players[dummy_id]
	_check(dummy.is_bot, "the dummy replicated as a Player")

	# The closet door, used by a client, walks it into the room.
	var closet = game.find_interactable("dev_door_closet")
	_stand(closet.global_position + closet.global_basis.z * 1.0, closet.rotation.y + PI)
	await _seconds(0.5)
	me.bot_aim_id = "dev_door_closet"
	await _frames(3)
	me.bot_press += 1
	ok = await _until(func(): return dev.in_room(me.global_position), 6.0)
	me.bot_aim_id = ""
	_check(ok, "the host walks a client through the closet door")

	# A dispenser works for a client.
	_stand(o + Vector3(22.4, 0, 9.2), -PI / 2.0)
	await _seconds(0.5)
	me.bot_aim_id = "dev_disp_anesthetic"
	await _frames(3)
	me.bot_press += 1
	ok = await _until(func(): return me.holding("anesthetic"), 5.0)
	me.bot_aim_id = ""
	_check(ok, "a client takes from a dispenser")

	dev.request("gun", {"on": true})
	ok = await _until(func(): return dev.has_gun(me.peer_id), 5.0)
	_check(ok, "the client's gun request came back from the host")

	_stand(o + Vector3(12.0, 0, 9.4))
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

	# NURSE HOOK: a Night Nurse the client watches under the lights.
	_stand(o + Vector3(20.0, 0, 12.5), PI / 2.0)
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
	game.set_dev_tools(false)
	await _frames(2)
	# The reply page, mid-print.
	var ui = game.economy.fax_ui
	game.economy.open_fax_ui()
	await _frames(3)
	for r in ui._rows:
		if String(r.kind) == "placebo_pills":
			r.box.pressed.emit()
			r.edit.text = "3141592653"
			ui._refresh()
	await _seconds(0.3)
	await _shot("01_secret_order")
	ui._send_order()
	await _until(func(): return ui._reply_wait != null, 15.0)
	await _seconds(0.2)
	await _shot("02_reply_building")
	await _until(func(): return not ui.is_open(), 20.0)
	var closet = game.find_interactable("dev_door_closet")
	_stand(closet.global_position + closet.global_basis.z * 2.3, closet.rotation.y + PI)
	_look_at(closet.global_position + Vector3.UP * 1.2)
	await _seconds(0.8)
	await _shot("03_closet_door")
	dev.request("gun", {"on": true})
	dev.request("god", {"on": true})
	dev.spawn_monster("discharged", "pen")
	dev.spawn_monster("night_nurse", "pen")
	for i in 3:
		dev.spawn_bot("dummy")
	await _seconds(1.0)
	_stand(o + Vector3(12.0, 0, 17.4))
	_look_at(o + Vector3(12.0, 1.0, 4.0))
	await _seconds(1.0)
	await _shot("04_room_from_the_door")
	_stand(o + Vector3(5.0, 0, 13.0))
	_look_at(o + Vector3(0.5, 0.9, 13.0))
	await _seconds(0.6)
	await _shot("05_containers")
	_stand(o + Vector3(19.0, 0, 13.4))
	_look_at(o + Vector3(23.6, 0.9, 13.2))
	await _seconds(0.6)
	await _shot("06_dispensers")
	_stand(o + Vector3(12.0, 0, 9.5))
	_look_at(o + Vector3(12.0, 0.8, 3.0))
	await _seconds(0.6)
	_shoot(game.monsters.values()[0], DevRoomScript.KNOCK)
	await _frames(2)
	await _shot("07_gun_knock_tracer")
	await _seconds(0.5)
	_shoot(game.monsters.values()[game.monsters.size() - 1], DevRoomScript.KILL)
	await _frames(3)
	await _shot("08_gun_kill_tracer")
	main.dev_panel.toggle(true)
	await _seconds(0.5)
	await _shot("09_panel")
	main.dev_panel._root.get_child(0).scroll_vertical = 900
	await _seconds(0.3)
	await _shot("10_panel_tools")
	main.dev_panel.toggle(false)
	# The room from outside, over the parking lot (it should be lost in the fog).
	var lot: Rect2 = game.level_info.get("neutral_rect", Rect2())
	dev.request("noclip", {"on": true})
	me.teleport(Vector3(lot.get_center().x, 0.0, lot.end.y - 9.0))
	_look_at(o + Vector3(12.0, 1.0, 9.0))
	await _seconds(1.0)
	await _shot("11_from_the_lot")


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


## Aim at an interactable by id and press E.
func _use(id: String) -> void:
	me.bot_aim_id = id
	await _frames(3)
	me.bot_press += 1
	await _frames(4)
	me.bot_aim_id = ""


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
	for path in _kept.keys():
		if _kept[path] == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(_kept[path])
				f.close()
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
