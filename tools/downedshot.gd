extends Node
## Windowed screenshots of the downed flow into tools/downed_shots/ (gitignored):
##
##   godot --path . --resolution 1280x720 tools/downedshot.tscn
##
##   01_downed_view        your own view lying on the floor: vignette, bleed clock, blood trail
##   02_bot_carrying       a bot carrying a downed dummy toward the player table
##   03_carrying_fp        your view while carrying someone ("Put X down")
##   04_on_table_view      lying on the player table: the ceiling and the surgeon
##   05_on_table_wide      the player table from the side with a bot stitching
##   06_stitches_start     the stitches minigame as it starts
##   07_stitches_mistake   right after a bad bite
##   08_stitches_done      the gash closed

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")
const SHOT_DIR := "res://tools/downed_shots"

var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	main.menu.hide_menu()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	Net.start_solo("Zach")
	game.start_session(DevRoomScript.SEED)
	await _seconds(2.5)
	me = game.local_player()
	me.bot_active = true
	dev.request("god", {"on": true})
	await _run()
	get_tree().quit(0)


func _physics_process(delta: float) -> void:
	t += delta


func _run() -> void:
	var pt: Vector3 = game.player_table.position
	# ---- 01: downed on the floor, after crawling a bit
	dev.request("god", {"on": false})
	_stand(Vector3(17.0, 0, 16.0), 0.0)
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

	# ---- 02: a bot carrying a downed dummy
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	var bid: int = dev.spawn_bot("bot", me)
	var bot: Player = game.players[bid]
	await _frames(4)
	dummy.teleport(game._floor_at(Vector3(18.0, 0, 11.0)))
	bot.teleport(game._floor_at(Vector3(16.0, 0, 13.0)))
	await _frames(2)
	game.knock_down_player(dummy, "test")
	await _seconds(0.5)
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return bot.carrying == did, 20.0)
	await _seconds(1.2)
	dev.order_bot(bid, "stay")
	await _frames(2)
	var side: Vector3 = bot.global_transform.basis.x * 2.6 - bot.global_transform.basis.z * 1.2
	_stand(bot.global_position + side, 0.0)
	_look_at(bot.global_position + Vector3.UP * 1.2)
	await _seconds(0.4)
	_look_at(bot.global_position + Vector3.UP * 1.2)
	await _frames(2)
	await _shot("02_bot_carrying")
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return dummy.on_table, 30.0)

	# ---- 03: your own view while carrying (put the dummy down, pick it up yourself)
	game.player_surgery.clear()
	dummy.on_table = false
	dummy.teleport(game._floor_at(Vector3(15.0, 0, 13.5)))
	dummy.refresh_downed_visuals()
	dev.order_bot(bid, "stay")
	await _frames(3)
	_stand(dummy.global_position + Vector3(0, 0, 1.4), 0.0)
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
	_stand(pt + Vector3(-1.0, 0, 2.3), 0.0)
	_look_at(pt + Vector3.UP * 0.9)
	await _seconds(0.5)
	me.bot_aim_id = "player_table"
	await _frames(3)
	await _shot("03_carrying_fp")
	me.bot_press += 1
	await _until(func(): return dummy.on_table, 3.0)
	me.bot_aim_id = ""

	# ---- 05 / 06-08 the stitches minigame, operated by you with a sloppy hand
	game.shelf["suture_kit"] = 3
	game.shelf_node.show_stock(game.shelf)
	_stand(pt + Vector3(0.0, 0, 1.2), 0.0)
	me.bot_aim_id = "player_table"
	await _frames(3)
	game.player_surgery.surgery.bot_skill = 0.0
	me.bot_press += 1
	await _until(func(): return game.player_surgery.surgery.is_local_operating(), 5.0)
	await _seconds(1.2)
	await _shot("06_stitches_start")
	var mg = game.player_surgery.surgery.mg
	var bads := {"n": 0}
	await _until(func(): return mg != null and is_instance_valid(mg) and mg.bads > 0, 25.0)
	await _frames(4)
	await _shot("07_stitches_mistake")
	await _until(func(): return mg == null or not is_instance_valid(mg) or mg.stitch >= mg.N_STITCHES, 40.0)
	await _seconds(0.28)
	await _shot("08_stitches_done")
	await _seconds(0.5)
	await _shot("08b_after_done")
	game.player_surgery.surgery.bot_skill = -1.0
	await _until(func(): return not dummy.downed, 10.0)
	await _seconds(1.0)

	# ---- 04 / 05: you on the table, a bot stitching
	dev.request("god", {"on": false})
	_stand(pt + Vector3(2.5, 0, 2.0), 0.0)
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
	await _until(func(): return me.on_table, 30.0)
	dev.order_bot(bid, "operate")
	await _until(func(): return bot.operating, 30.0)
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
	var did2: int = dev.spawn_bot("dummy")
	var d2: Player = game.players[did2]
	await _frames(3)
	d2.teleport(game._floor_at(pt + Vector3(0, 0, 1.6)))
	game.knock_down_player(d2, "test")
	await _frames(2)
	d2.bot_interact = false
	# Lay it straight on the table the way a carrier would.
	bot.teleport(game._floor_at(pt + Vector3(0.5, 0, 1.4)))
	dev.order_bot(bid, "carry", "", "table")
	await _until(func(): return d2.on_table, 30.0)
	dev.order_bot(bid, "operate")
	await _until(func(): return bot.operating, 30.0)
	await _seconds(3.0)
	_stand(pt + Vector3(-2.6, 0, 2.4), 0.0)
	_look_at(pt + Vector3.UP * 0.9)
	await _seconds(0.5)
	_look_at(pt + Vector3.UP * 0.9)
	await _frames(2)
	await _shot("05_on_table_wide")


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
