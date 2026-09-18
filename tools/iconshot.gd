extends Node
## Boots the real game and saves screenshots of the icon item bar, the ability bar and the database
## (docs/ITEMS_AND_ICONS.md, chunk C), for the smoke look. Windowed: run it minimized (tools/review.ps1
## style WMI launch), never in front of anyone.
##
##   godot --path . tools/iconshot.tscn -- [--seed=N]
##
## Writes tools/game_shots/icons_*.png.

const OUT_DIR := "res://tools/game_shots"

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _n := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(300.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Icons")
	game.start_session(_seed)
	await get_tree().process_frame
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.bot_move = Vector2.ZERO
	game.begin_shift()
	await _frames(30)
	var t := game.table_pos()
	_look_from(t + Vector3(0.6, 0, 3.4), t + Vector3(0, 1.0, 0))
	await _frames(20)

	game.brains.set_level(bot.peer_id, "echo", 3)
	game.brains.set_level(bot.peer_id, "hive_in", 2)
	var suf := "_%d" % int(get_viewport().get_visible_rect().size.x)
	for sel in 4:
		_clear()
		bot.take_into("anesthetic", 3)
		bot.take_into("forceps", 1)
		bot.take_into("gold_watch", 1, 90)
		bot.take_into("laptop", 1, 120)
		bot.selected = 0 if sel != 0 else 1
		await _frames(150)
		bot.selected = sel
		await _frames(14)
		await _shot("sel%d%s" % [sel + 1, suf])
	await _frames(150)
	await _shot("bar_four")
	# 3. a bulky item takes a wide slot.
	_clear()
	bot.take_into("anesthetic", 2)
	bot.selected = 1
	bot.take_into("heart_monitor", 1, 200)
	await _frames(4)
	await _shot("bar_bulky_pop")
	await _frames(200)
	await _shot("bar_bulky")
	bot.selected = 1
	await _frames(200)
	bot.selected = 1
	bot.selected = 3
	await _frames(200)
	bot.selected = 1
	await _frames(10)
	await _shot("bar_bulky_sel%s" % suf)
	# 4. spoiling eyes, a used trinket.
	_clear()
	bot.selected = 0
	bot.take_into("eye_hive", 1, 150)
	bot.slots[0]["bt"] = game.world_time - 8.0
	bot.selected = 1
	bot.take_into("eye_surgeon", 1, 150)
	bot.slots[1]["bt"] = game.world_time - 90.0
	bot.slots[1]["x"] = "Zach"
	bot.selected = 2
	bot.take_into("eye_hive", 1, 150)
	bot.slots[2]["bt"] = game.world_time - 400.0
	bot.selected = 3
	bot.take_into("laptop", 1, 120)
	bot.slots[3]["used"] = true
	await _frames(14)
	await _shot("bar_spoil_used")
	# 5. abilities: Alt held.
	game.brains.set_level(bot.peer_id, "echo", 3)
	game.brains.set_level(bot.peer_id, "hive_in", 2)
	game.brains._cd["echo:%d" % bot.peer_id] = game.world_time + 9.0
	game.brains._cd.erase("hive:%d" % bot.peer_id)
	await _shot("abilities_idle")
	Input.action_press("ability_alt")
	await _frames(30)
	await _shot("abilities_alt%s" % suf)
	Input.action_release("ability_alt")
	await _frames(20)
	# 6. the table's prompt naming its item.
	bot.aim_id = "table_0"
	bot.aim_prompt = "!Hold Forceps to do this."
	await _shot("table_prompt")
	# 6b. the OR monitor's steps, close up.
	var scr = game.get("or_screen")
	if scr != null and scr.mounted():
		var c: Vector3 = scr.screen_centre()
		var nrm: Vector3 = scr.screen_normal()
		_look_from(Vector3(c.x + nrm.x * 1.9, game.table_pos().y, c.z + nrm.z * 1.9), c)
		bot.aim_prompt = ""
		await _frames(40)
		await _shot("orscreen")
	# 7. the database, straight from its viewport.
	game.wall.user = bot.peer_id   # signed in (the hold and the walk-away sign-out are its own tests)
	game.wall.set_process(false)
	var wt: Node3D = game.wall_terminal()
	if wt != null:
		wt.ui.quirks = false
		wt.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		for v in [["section_surgery", {"kind": "section", "id": "surgery", "index": 0}], ["section_other", {"kind": "section", "id": "other", "index": 0}],
				["item", {"kind": "entry", "section": "surgery", "key": "forceps"}], ["procedure", {"kind": "entry", "section": "procedures", "key": "gunshot"}]]:
			game.wall.user = bot.peer_id
			wt.ui.set_view(v[1], [{"kind": "home"}])
			await _frames(20)
			game.wall.user = bot.peer_id
			wt.ui.refresh()
			await _frames(20)
			await _viewport_shot(wt.viewport, "db_" + String(v[0]))
	print("[iconshot] done, %d shots" % _n)
	get_tree().quit(0)


func _clear() -> void:
	for i in bot.slots.size():
		bot.slots[i] = Player.empty_slot()


func _frames(k: int) -> void:
	for i in k:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await get_tree().process_frame
	_save(get_viewport().get_texture().get_image(), name)


func _viewport_shot(vp: SubViewport, name: String) -> void:
	await get_tree().process_frame
	_save(vp.get_texture().get_image(), name)


func _save(img: Image, name: String) -> void:
	var path := "%s/icons_%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	_n += 1
	print("[iconshot] wrote ", path, "  ", img.get_width(), "x", img.get_height())


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot._pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	bot.head.rotation.x = bot._pitch
