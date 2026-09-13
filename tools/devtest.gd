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
	if t > (240.0 if net_role == "" else 90.0) and not _done:
		_fail("timed out")
		_finish()


# =========================================================================
# solo
# =========================================================================

func _run_solo() -> void:
	# The secret code on the title screen arms Solo.
	for ch in "xxclear":
		main.menu.dev_code.feed(ch)
	_check(main.menu.dev_code.armed, "typing the code arms the menu")
	main.menu._on_solo()
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

	dev.request("gun", {"on": true})
	_check(dev.has_gun(me.peer_id), "the dev gun is out")

	# ---- monsters: kill one, knock one down
	var m = dev.spawn_monster("discharged", "pen")
	var mid: int = m.monster_id
	await _seconds(0.5)
	_stand(Vector3(12.0, 0, 9.4))
	await _frames(2)
	_shoot(m, DevRoomScript.KILL)
	await _frames(3)
	_check(not game.monsters.has(mid), "a kill shot removes the monster")
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

	# ---- a dummy
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	await _frames(5)
	_stand(dummy.global_position + Vector3(0, 0, 4.0))
	await _frames(2)
	_shoot(dummy, DevRoomScript.KNOCK)
	await _frames(2)
	_check(dummy.alive and dummy.hp == 1 and dummy.stun > 0.0, "a knock-down leaves a dummy at 1 HP, stunned (hp=%d stun=%.1f)" % [dummy.hp, dummy.stun])
	await _seconds(0.5)
	_shoot(dummy, DevRoomScript.KILL)
	await _frames(2)
	_check(not dummy.alive, "a kill shot kills a dummy")

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
	_check(bot.alive and bot.hp == 1 and bot.stun > 0.0, "a knock-down leaves a bot at 1 HP, stunned")
	await _seconds(0.6)   # the knock-back slide
	var pos_before := bot.global_position
	await _seconds(1.0)
	_check(bot.global_position.distance_to(pos_before) < 0.2, "a knocked-down bot does not walk (moved %.2f m)" % bot.global_position.distance_to(pos_before))
	await _seconds(2.0)

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
	_check(me.alive and me.hp == 1 and me.stun > 0.0, "knock_down_player leaves you at 1 HP, stunned")
	game.kill_monster(m3)
	await _seconds(3.2)
	me.revive_full()
	game.damage_player(me, 1, "test")
	_check(me.hp == me.max_hp - 1, "damage_player takes HP")
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

	# Leaving resets the global state.
	main._back_to_menu("")
	await _frames(3)
	_check(not game.dev_mode and is_equal_approx(Engine.time_scale, 1.0), "leaving the dev room resets it")
	_finish()


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
	ok = await _until(func(): return dummy.hp == 1, 4.0)
	_check(ok, "the client's knock-down reached the dummy (hp %d)" % dummy.hp)
	await _seconds(0.3)
	_shoot(dummy, DevRoomScript.KILL)
	ok = await _until(func(): return not dummy.alive, 4.0)
	_check(ok, "the client killed the dummy")

	dev.request("spawn_bot", {"kind": "bot"})
	ok = await _until(func():
		for p in game.players.values():
			if p.is_bot and dev.bots.get(p.peer_id, {}).get("kind", "") == "bot":
				return true
		return false, 5.0)
	_check(ok, "a bot the client asked for appears on the client")
	await _seconds(2.0)
	_finish()


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
	var bid: int = dev.spawn_bot("bot", me)
	dev.set_patient("seal", "amputation")
	dev.stock_shelf()
	await _seconds(1.0)
	_stand(Vector3(12.0, 0, 17.2))
	_look_at(Vector3(12.0, 1.2, 4.0))
	await _seconds(1.0)
	await _shot("01_room_from_spawn")
	_stand(Vector3(13.0, 0, 13.5))
	_look_at(Vector3(6.0, 1.0, 11.0))
	await _seconds(0.6)
	await _shot("02_or_table_and_containers")
	_stand(Vector3(18.0, 0, 14.0))
	_look_at(Vector3(23.5, 1.0, 13.0))
	await _seconds(0.6)
	await _shot("03_dispensers")
	_stand(Vector3(12.0, 0, 9.3))
	_look_at(Vector3(12.0, 1.3, 3.0))
	await _seconds(0.6)
	var m = game.monsters.values()[0]
	_shoot(m, DevRoomScript.KNOCK)
	await _frames(2)
	await _shot("04_gun_knock_tracer")
	await _seconds(0.5)
	_shoot(game.monsters.values()[1], DevRoomScript.KILL)
	await _frames(3)
	await _shot("05_gun_kill_tracer")
	await _seconds(0.8)
	await _shot("06_monster_falls")
	_stand(Vector3(17.75, 0, 14.5))
	_look_at(Vector3(17.75, 1.0, 10.2))
	await _seconds(0.5)
	var d: Player = game.players[dev.bots.keys()[1]]
	_shoot(d, DevRoomScript.KNOCK)
	await _seconds(0.6)
	await _shot("07_dummies_one_down")
	main.dev_panel.toggle(true)
	await _seconds(0.5)
	await _shot("08_panel")
	main.dev_panel.toggle(false)
	dev.set_patient("bob", "gunshot")
	dev.order_bot(bid, "operate")
	_stand(Vector3(8.5, 0, 14.0))
	_look_at(Vector3(8.5, 1.0, 11.5))
	await _until(func(): return game.players[bid].operating, 40.0)
	await _seconds(3.0)
	await _shot("09_bot_operating")


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
func _shoot(target: Node3D, mode: String) -> void:
	var aim: Vector3 = target.global_position + Vector3.UP * 1.3
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
	if Net.active:
		Net.leave()
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())
