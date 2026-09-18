extends Node
## Smoke look for a review setup: boots the game the way a review window does (main.gd reads
## `--setup=<name>`), waits for the setup to stage, and saves tools/game_shots/setup_<name>.png.
## Run minimized (WMI, like tools/review.ps1):  godot --path . tools/setupshot.tscn -- --setup=icons

func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func(): get_tree().quit(2))
	var setup := ReviewSetups.requested()
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	var game: Game = main.game
	var t := 0.0
	while t < 200.0:
		await get_tree().create_timer(1.0).timeout
		t += 1.0
		var p = game.local_player()
		if game.phase == Game.Phase.SHIFT and p != null and p.hands_empty() == false:
			break
	for i in 90:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://tools/game_shots/setup_%s.png" % setup)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("[setupshot] wrote ", path, " menu_visible=", main.menu.visible)
	get_tree().quit(0)
