extends Node
## Windowed screenshots of the downed flow into tools/downed_shots/ (gitignored):
##
##   godot --path . --resolution 1280x720 tools/downedshot.tscn
##
##   01_downed_view        your own view lying on the dev room's floor: vignette, bleed clock, blood trail
##   02_bot_carrying       a bot carrying a downed dummy in the OR, toward a patient table
##   03a_lifting           your view half-way through the hold to lift someone
##   03_carrying_fp        your view while carrying someone to a free patient table ("Place X on the table")
##   03b_carried_view      your view riding over a bot's shoulder
##   04_on_table_view      lying on a patient table: the surgeon
##   04b_on_table_ceiling  lying on a patient table: the ceiling
##   05_on_table_wide      the patient table from the side with a bot stitching
##   06_stitches_start     the stitches minigame as it starts
##   07_stitches_mistake   right after a bad bite
##   08_stitches_done      the gash closed
##   08b_after_done        a moment later
##
## A normal hospital (seed 4242) with dev mode on (No monsters, No game over), clocked in with the
## phone hung up. 01 is on the hidden dev room's floor; everything with a table is in the hospital's
## OR, on its first free patient table (the room has no table, and its navigation is an island of
## its own, so bots carry and operate in the OR).

const SHOT_DIR := "res://tools/downed_shots"
const SEED := 4242

var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0
## The hidden dev room's corner (its own frame's origin) in world space.
var o := Vector3.ZERO


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	main.menu.hide_menu()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	Net.start_solo("Zach")
	game.start_session(SEED)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(1.0)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	o = dev.room.global_position
	dev.request("monsters_off", {"on": true})
	dev.request("no_game_over", {"on": true})
	dev.request("god", {"on": true})
	game.clock_in()
	await _until(func(): return game.phase == Game.Phase.SHIFT, 90.0)
	game.loop._end_call()
	game.loop.first_called = true
	game.loop.extra_done = true
	await _run()
	get_tree().quit(0)


func _physics_process(delta: float) -> void:
	t += delta


func _run() -> void:
	var ti: int = game.free_patient_table()
	var tid: String = game.table_interact_id(ti)
	var pt: Vector3 = game.table_position(ti)
	var tb := Basis(Vector3.UP, game.table_yaw_of(ti))
	var side: Vector3 = tb * Vector3(0, 0, 1)   # where a revived player gets up
	var along: Vector3 = tb * Vector3(1, 0, 0)   # the body's length
	print("[downedshot] table %d '%s' at %s, dev room at %s" % [ti, tid, str(pt), str(o)])

	# ---- 01: downed on the dev room's floor, after crawling a bit
	dev.request("god", {"on": false})
	_stand(o + Vector3(17.0, 0, 16.0), 0.0)
	await _frames(2)
	game.knock_down_player(me, "test")
	await _seconds(1.0)
	me.bot_move = Vector2(0, -1)
	await _seconds(4.0)
	me.bot_move = Vector2.ZERO
	me.bot_yaw = PI * 0.85
	me.bot_pitch = -0.25
	await _seconds(0.8)
	await _shot("01_downed_view")
	dev.request("revive_all")
	await _frames(3)
	dev.request("god", {"on": true})

	# ---- 02: a bot carrying a downed dummy in the OR
	_stand(pt + side * 3.0, 0.0)
	await _frames(2)
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	var bid: int = dev.spawn_bot("bot", me)
	var bot: Player = game.players[bid]
	await _frames(4)
	dummy.teleport(game._floor_at(pt + side * 2.6 + along * 1.6))
	bot.teleport(game._floor_at(pt + side * 2.6 - along * 1.4))
	await _frames(2)
	game.knock_down_player(dummy, "test")
	await _seconds(0.5)
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return bot.carrying == did, 20.0)
	await _seconds(1.2)
	dev.order_bot(bid, "stay")
	await _frames(2)
	var bside: Vector3 = bot.global_transform.basis.x * 2.6 - bot.global_transform.basis.z * 1.2
	_stand(bot.global_position + bside, 0.0)
	_look_at(bot.global_position + Vector3.UP * 1.2)
	await _seconds(0.4)
	_look_at(bot.global_position + Vector3.UP * 1.2)
	await _frames(2)
	await _shot("02_bot_carrying")
	dev.order_bot(bid, "carry", "", "table")
	await _bot_lays_on_table(bid, did, ti)

	# ---- 03: your own view while carrying (put the dummy down, pick it up yourself)
	game.player_surgery.clear()
	dummy.on_table = false
	dummy.teleport(game._floor_at(pt + side * 2.6 + along * 1.0))
	dummy.refresh_downed_visuals()
	dev.order_bot(bid, "stay")
	bot.teleport(game._floor_at(pt + side * 4.5 + along * 1.5))   # behind you, out of the shots
	await _frames(3)
	_stand(dummy.global_position + side * 1.4, 0.0)
	_look_at(dummy.global_position)
	me.bot_aim_id = "pl_%d" % did
	me.bot_interact = true
	await _seconds(0.6)
	me.bot_interact = false
	await _frames(1)
	await _shot("03a_lifting")
	me.bot_interact = true
	await _until(func(): return me.carrying == did, 3.0)
	me.bot_interact = false
	me.bot_aim_id = ""
	_stand(pt + side * 2.3 - along * 1.0, 0.0)
	_look_at(pt + Vector3.UP * 0.9)
	await _seconds(0.5)
	me.bot_aim_id = tid
	await _frames(3)
	await _shot("03_carrying_fp")
	me.bot_press += 1
	await _until(func(): return dummy.on_table, 3.0)
	me.bot_aim_id = ""

	# ---- 06-08 the stitches minigame, operated by you with a sloppy hand
	game.give_hand(me, "suture_kit", 3)
	_stand(pt + side * 1.2, 0.0)
	_look_at(pt + Vector3.UP * 0.9)
	me.bot_aim_id = tid
	await _frames(3)
	game.player_surgery.surgery.bot_skill = 0.0
	me.bot_press += 1
	await _until(func(): return game.player_surgery.surgery.is_local_operating(), 5.0)
	await _seconds(1.2)
	await _shot("06_stitches_start")
	var mg = game.player_surgery.surgery.mg
	await _until(func(): return mg != null and is_instance_valid(mg) and mg.bads > 0, 25.0)
	await _frames(4)
	await _shot("07_stitches_mistake")
	await _until(func(): return mg == null or not is_instance_valid(mg) or mg.stitch >= mg.N_STITCHES, 40.0)
	await _seconds(0.28)
	await _shot("08_stitches_done")
	await _seconds(0.5)
	await _shot("08b_after_done")
	game.player_surgery.surgery.bot_skill = -1.0
	me.bot_aim_id = ""
	await _until(func(): return not dummy.downed, 10.0)
	await _seconds(1.0)

	# ---- 03b / 04 / 05: you on the table, a bot stitching
	dev.request("god", {"on": false})
	_stand(pt + side * 2.5 + along * 2.0, 0.0)
	bot.teleport(game._floor_at(pt + side * 2.5 - along * 1.0))
	await _frames(2)
	game.knock_down_player(me, "test")
	await _seconds(0.8)
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return me.carried_by == bid, 30.0)
	await _seconds(0.6)
	me.bot_yaw = bot.rotation.y
	me.bot_pitch = -0.2
	await _frames(3)
	await _shot("03b_carried_view")
	await _bot_lays_on_table(bid, me.peer_id, ti)
	await _bot_operates(bid, ti)
	await _seconds(2.0)
	me.bot_yaw = game.player_table_yaw() - PI * 0.5
	me.bot_pitch = 0.55
	await _seconds(0.5)
	await _shot("04_on_table_view")
	me.bot_pitch = 1.45
	await _frames(3)
	await _shot("04b_on_table_ceiling")
	dev.request("revive_all")
	await _frames(3)
	dev.request("god", {"on": true})
	var did2: int = dev.spawn_bot("dummy")
	var d2: Player = game.players[did2]
	await _frames(3)
	d2.teleport(game._floor_at(pt + side * 1.6))
	game.knock_down_player(d2, "test")
	await _frames(2)
	d2.bot_interact = false
	# Lay it straight on the table the way a carrier would.
	bot.teleport(game._floor_at(pt + side * 1.4 + along * 0.5))
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return bot.carrying == did2, 10.0)
	await _bot_lays_on_table(bid, did2, ti)
	await _bot_operates(bid, ti)
	await _seconds(3.0)
	_stand(pt + side * 2.4 - along * 2.6, 0.0)
	_look_at(pt + Vector3.UP * 0.9)
	await _seconds(0.5)
	_look_at(pt + Vector3.UP * 0.9)
	await _frames(2)
	await _shot("05_on_table_wide")


## The bot (on a carry order to "table", already carrying `who`) lays them on patient table `ti`.
## Its own order first; if that stalls, walk it there and place them by hand (dev_bot.gd's carry
## order looks for the old fixed player table, which a hub level does not have).
func _bot_lays_on_table(bid: int, who: int, ti: int) -> void:
	var bot: Player = game.players[bid]
	var body: Player = game.players[who]
	if await _until(func(): return body.on_table, 8.0):
		return
	print("[downedshot] the bot's carry order did not reach table %d (status '%s'); placing by hand" % [ti, dev.brains[bid].status])
	dev.order_bot(bid, "stay")
	if bot.carrying != who:
		game.start_carry(bot, body)
	var side: Vector3 = Basis(Vector3.UP, game.table_yaw_of(ti)) * Vector3(0, 0, 1)
	bot.teleport(game._floor_at(game.table_position(ti) + side * 1.3))
	bot.bot_yaw = atan2(side.x, side.z)
	await _frames(3)
	game.place_on_player_table(bot, ti)
	await _until(func(): return body.on_table, 3.0)


## The bot stitches up whoever lies on patient table `ti`. Its own operate order first; if that
## stalls, stand it at the table, aim and press E (dev_bot.gd operates at the old "player_table").
func _bot_operates(bid: int, ti: int) -> void:
	var bot: Player = game.players[bid]
	dev.order_bot(bid, "operate")
	if await _until(func(): return bot.operating, 8.0):
		return
	print("[downedshot] the bot's operate order did not start at table %d (status '%s'); operating by hand" % [ti, dev.brains[bid].status])
	dev.order_bot(bid, "stay")
	game.give_hand(bot, "suture_kit", 1)   # 2026-09-18: a step's tool is used from the hands
	var side: Vector3 = Basis(Vector3.UP, game.table_yaw_of(ti)) * Vector3(0, 0, 1)
	bot.teleport(game._floor_at(game.table_position(ti) + side * 1.2))
	bot.bot_yaw = atan2(side.x, side.z)
	bot.bot_pitch = -0.4
	bot.bot_aim_id = game.table_interact_id(ti)
	bot.set_meta("bot_skill", 0.8)
	for i in 20:
		await _frames(10)
		if bot.operating:
			break
		bot.bot_press += 1
	bot.bot_aim_id = ""


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[downedshot] wrote %s" % path)


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
