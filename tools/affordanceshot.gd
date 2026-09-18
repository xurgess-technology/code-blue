extends Node
## Interactable-affordance sweep: boots the real game and screenshots the supply shelf (a) from a
## distance with no aim, (b) close up while the bot aims at it (highlight on), and (c) the same
## close-up not aiming at it (highlight off), so the new rim can be checked against the old
## always-on label by eye. Same pattern as tools/gameshot.gd.
##
##   godot --path . tools/affordanceshot.tscn -- [--seed=N]

const OUT_DIR := "res://tools/game_shots"
const SETTLE_FRAMES := 26

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242


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
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.bot_move = Vector2.ZERO
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
	await get_tree().process_frame

	var shelf: Node3D = (game.storage_nodes[0] if not game.storage_nodes.is_empty() else null)
	print("[affordanceshot] shelf at ", shelf.global_position if shelf != null else "null")

	# (a) distant view of the OR, shelf visible, not aimed at anything.
	bot.bot_aim_id = ""
	var t := game.table_pos()
	_look_from(t + Vector3(2.4, 0.4, -1.0), shelf.global_position if shelf != null else t)
	await _settle_and_shot("a_shelf_distant_no_aim")

	# (b) close on the shelf, aimed at it, holding a surgical item so the prompt is a real one
	# (not the "!..." can't-use-it-yet line, which the highlight also skips): the highlight
	# should be on.
	for i in bot.slots.size():
		bot.clear_slot(i)
	bot.take_into("anesthetic", 2)
	bot.selected = 0
	if shelf != null:
		var out: Vector3 = -shelf.global_basis.z.normalized()   # the storage shelves face -Z
		_look_from(shelf.global_position + out * 1.4 + Vector3(0, 0.1, 0), shelf.global_position + Vector3(0, 0.9, 0))
	bot.bot_aim_id = "storage_0"
	await _settle_and_shot("b_shelf_aimed_highlight_on")

	# (c) identical framing, no aim: the highlight should be off.
	bot.bot_aim_id = ""
	await _settle_and_shot("c_shelf_not_aimed_highlight_off")

	# (d) the blender, aimed at while holding a brain (so the prompt is real, not "!Blender: bring
	# a brain"), for a second interactable's highlight.
	var blender: Node3D = game.brains.blender if game.brains != null else null
	if blender != null and is_instance_valid(blender):
		for i in bot.slots.size():
			bot.clear_slot(i)
		bot.take_into("brain_hive", 1)
		bot.selected = 0
		var bout: Vector3 = blender.global_basis.z.normalized()
		_look_from(blender.global_position + bout * 1.5 + Vector3(0, 1.05, 0), blender.global_position + Vector3(0, 0.95, 0))
		bot.bot_aim_id = "blender"
		await _settle_and_shot("d_blender_aimed_highlight_on")
		var shells := blender.find_children("AimOutlineFx", "MeshInstance3D", true, false)
		print("[affordanceshot] blender outline shells: ", shells.size())
		bot.bot_aim_id = ""
		await _settle_and_shot("e_blender_not_aimed_highlight_off")
	else:
		print("[affordanceshot] no blender placed this level")

	print("[affordanceshot] done")
	get_tree().quit(0)


func _settle_and_shot(name: String) -> void:
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[affordanceshot] wrote ", path, "  ", img.get_width(), "x", img.get_height())


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot._pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	bot.head.rotation.x = bot._pitch
