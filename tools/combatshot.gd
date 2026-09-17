extends Node
## Windowed screenshots of combat into tools/combat_shots/ (gitignored):
##
##   godot --path . --resolution 1280x720 tools/combatshot.tscn
##
##   01_swing_windup     your view, the bone saw raised for the swing
##   02_swing_strike     your view, the saw coming down across the view
##   03_jab_thrust       your view, the syringe thrust forward at a stunned monster
##   04_swing_other      a bot raising the saw, seen from the front (04b: the strike)
##   05_sedated_prompt   a sedated monster lying down: "Hold E: drag"
##   06_drag_fp          your view while dragging, at a free table: "Strap ... to the table"
##   07_drag_other       a bot dragging a sedated monster, seen from the side
##   08_strapped         the monster case on the table
##
## A solo session on a normal hospital (seed 4242) with dev mode on, god mode, no monsters roaming
## and the phone quiet after clocking in. The fights and drags are in the hidden dev room past the
## parking lot (room metres offset by its corner `o`); 06 and 08 are at an OR patient table in the
## entrance building (the dragger is teleported there with the monster in tow).

const MonsterScript := preload("res://scripts/monster.gd")
const WindupScript := preload("res://scripts/combat/windup.gd")
const SHOT_DIR := "res://tools/combat_shots"

var main: Node3D
var game: Game
var dev: Node
var cb: Node
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
	cb = game.combat
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	Net.start_solo("Zach")
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(0.5)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	if not dev.room_ready():
		push_error("[combatshot] dev mode did not build the hidden room")
		get_tree().quit(1)
		return
	o = dev.room.global_position
	dev.request("god", {"on": true})
	dev.request("no_game_over", {"on": true})
	dev.request("monsters_off", {"on": true})
	game.clock_in()   # strapping needs a shift
	var end := t + 60.0
	while game.phase != Game.Phase.SHIFT and t < end:
		await get_tree().physics_frame
	game.loop.first_called = true
	game.loop._end_call()
	game.loop.extra_done = true
	dev.request("clear_patient")
	for m in game.monsters.values():
		game.kill_monster(m)
	await _seconds(3.5)   # the clock-in notices fade
	await _run()
	get_tree().quit(0)


func _physics_process(delta: float) -> void:
	t += delta


func _run() -> void:
	cb.break_chance = 0.0
	# ---- 01 / 02: the swing, first person, at a Discharged
	var m := await _monster(o + Vector3(15.0, 0, 12.5))
	_give("bone_saw", 1)
	_stand(o + Vector3(15.0, 0, 14.6), 0.0)
	_look_at(m.global_position + Vector3.UP * 1.2)
	await _seconds(0.6)
	cb.anim_freeze = true
	cb.pose_at(me, "saw", WindupScript.WINDUP, WindupScript.WINDUP_TIME.saw)   # HANDS: wind-up peak

	await _frames(3)
	await _shot("01_swing_windup")
	cb.pose_at(me, "saw", WindupScript.STRIKE, 0.1)
	await _frames(3)
	await _shot("02_swing_strike")
	cb.stop_anim(me)
	cb.anim_freeze = false
	await _frames(3)

	# ---- 03: the jab at a stunned monster
	_give("anesthetic", 3)
	await _frames(2)
	game.knock_down_monster(m, Vector3.ZERO, 20.0)
	_stand(o + Vector3(15.0, 0, 14.0), 0.0)
	_look_at(m.global_position + Vector3.UP * 1.1)
	await _seconds(0.5)
	cb.anim_freeze = true
	cb.pose_at(me, "jab", WindupScript.STRIKE, 0.12)

	await _frames(3)
	await _shot("03_jab_thrust")
	cb.stop_anim(me)
	cb.anim_freeze = false
	await _frames(2)

	# ---- 04: a bot swinging, seen from the side
	var bid: int = dev.spawn_bot("bot", me)
	var bot: Player = game.players[bid]
	dev.order_bot(bid, "stay")
	await _frames(3)
	bot.teleport(game._floor_at(o + Vector3(15.0, 0, 14.0)))
	bot.bot_yaw = 0.0
	bot.bot_pitch = 0.0
	bot.slots[0] = {"kind": "bone_saw", "count": 1}
	bot.selected = 0
	await _frames(3)
	_stand(o + Vector3(17.0, 0, 12.2), 0.0)
	_look_at(bot.global_position + Vector3.UP * 1.3)
	await _seconds(0.4)
	cb.anim_freeze = true
	cb.pose_at(bot, "saw", WindupScript.WINDUP, WindupScript.WINDUP_TIME.saw)

	await _frames(3)
	await _shot("04_swing_other")
	cb.pose_at(bot, "saw", WindupScript.STRIKE, 0.1)
	await _frames(3)
	await _shot("04b_swing_other_strike")
	cb.stop_anim(bot)
	cb.anim_freeze = false
	bot.slots = Player.empty_slots()
	bot.teleport(game._floor_at(o + Vector3(19.0, 0, 16.5)))
	await _frames(2)

	# ---- 05: sedated, lying, the drag prompt
	_give("anesthetic", 3)
	_stand(o + Vector3(15.0, 0, 14.0), 0.0)
	_look_at(m.global_position + Vector3.UP * 1.1)
	await _frames(2)
	game.player_shoved(me)
	await _frames(2)
	_stand(m.global_position + Vector3(0, 0, 1.3), 0.0)
	_look_at(m.global_position + Vector3.UP * 1.1)
	await _seconds(1.1)
	me.bot_use += 1
	await _seconds(1.0)
	me.slots = Player.empty_slots()
	_stand(m.global_position + Vector3(0.6, 0, 2.0), 0.0)
	_look_at(m.global_position + Vector3.UP * 0.25)
	me.bot_aim_id = "mo_%d" % m.monster_id
	await _seconds(0.5)
	await _shot("05_sedated_prompt")

	# ---- 06: dragging to a free table, first person
	me.bot_interact = true
	await _seconds(1.2)
	me.bot_interact = false
	me.bot_aim_id = ""
	var ti: int = game.free_patient_table()
	var tp: Vector3 = game.table_position(ti)
	var tyaw: float = game.table_yaw_of(ti)
	_stand(tp + Vector3(1.6, 0, 1.4).rotated(Vector3.UP, tyaw), 0.0)
	_look_at(tp + Vector3.UP * 0.9)
	await _seconds(0.6)
	me.bot_aim_id = game.table_interact_id(ti)
	await _frames(4)
	await _shot("06_drag_fp")
	me.bot_aim_id = ""
	cb.drop_dragged(me)
	await _frames(2)

	# ---- 07: a bot dragging it, from the side
	bot.teleport(game._floor_at(o + Vector3(15.5, 0, 13.0)))
	bot.bot_yaw = -PI / 2.0
	await _frames(3)
	bot.dragging_monster = m.monster_id
	m.dragged_by = bot.peer_id   # the monster pins itself behind its dragger (from the hospital's OR)
	await _frames(3)
	_stand(o + Vector3(16.5, 0, 16.2), 0.0)
	_look_at(bot.global_position + Vector3(0.6, 0.6, 0.0))
	await _seconds(0.6)
	await _shot("07_drag_other")
	var m_pos: Vector3 = m.global_position

	# ---- 08: strapped to the table
	bot.dragging_monster = -1
	me.dragging_monster = m.monster_id
	m.dragged_by = me.peer_id
	cb.strap(me, ti)
	await _seconds(1.5)
	_stand(tp + Vector3(1.2, 0, 2.2).rotated(Vector3.UP, tyaw), 0.0)
	_look_at(tp + Vector3.UP * 0.9)
	await _seconds(0.6)
	await _shot("08_strapped")
	print("[combatshot] monster was at %s" % str(m_pos))


func _monster(pos: Vector3) -> Node:
	var m = game._add_monster("discharged", game._floor_at(pos))
	await _frames(3)
	m.mode = MonsterScript.Mode.IDLE
	m.brain.timer = 999.0
	m.calm = 999.0
	m.rotation.y = 0.0
	return m


func _give(kind: String, count: int) -> void:
	me.slots = Player.empty_slots()
	me.slots[0] = {"kind": kind, "count": count}
	me.selected = 0


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[combatshot] wrote %s" % path)


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
