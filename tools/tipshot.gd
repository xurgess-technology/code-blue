extends Node
## Windowed screenshots of the tip fax (scripts/tips/tip_fax.gd): walking into the break room prints
## the time clock memo (mid-print and done), Esc tears it off, walking into the crematorium prints the
## furnace memo. Forgets the shown tips before and after, so a real game still shows them.
##
##   godot --path . tools/tipshot.tscn
##
## Writes tools/game_shots/tip_<n>_<name>.png.

const OUT_DIR := "res://tools/game_shots"

var main: Node3D
var game: Game
var bot: Player


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(240.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(0.5)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	main.tips.reset_seen()

	await _walk_into("break_room")
	await _seconds(1.4)
	await _shot("1_break_room_printing")
	await _stamped()
	await _shot("2_break_room_printed")
	var esc := InputEventAction.new()
	esc.action = "pause"
	esc.pressed = true
	get_viewport().push_input(esc)
	await _seconds(0.15)
	await _shot("3_torn_off")
	print("[tipshot] paused after Esc on a memo: ", game.paused)
	await _seconds(1.0)
	await _walk_into("hub_crematorium")
	await _stamped()
	await _shot("4_crematorium_printed")
	main.tips.reset_seen()
	get_tree().quit(0)


func _walk_into(kind: String) -> void:
	for r in game.level_info.get("rooms", []):
		if String(r.get("kind", "")) == kind:
			var c: Vector2 = (r.rect as Rect2).get_center()
			bot.teleport(game._floor_at(Vector3(c.x, 0.0, c.y)))
			return
	print("[tipshot] no room ", kind)


## Wait until the memo on screen has printed in full and its stamp has settled (the memo's length and
## the frame pacing decide when that is, so a fixed wait raced it).
func _stamped() -> void:
	var end := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < end and not main.tips.is_stamped():
		await get_tree().process_frame
	if not main.tips.is_stamped():
		print("[tipshot] memo never finished stamping")
	await _seconds(0.1)


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/tip_%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[tipshot] wrote ", path)
