extends Node
## Windowed screenshots of the loading screen during a real Solo start (the main menu's button path,
## including the first-session warmup).
##
##   godot --path . tools/loadingshot.tscn
##
## Writes tools/game_shots/loading_<n>.png every 0.4 s while the screen is up, then quits.

const OUT_DIR := "res://tools/game_shots"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	main._start_solo("Shot")
	var n := 0
	var next := 0
	while Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
		var ms := Time.get_ticks_msec() - t0
		if ms >= next:
			next = ms + 400
			var img := get_viewport().get_texture().get_image()
			var path := "%s/loading_%02d.png" % [OUT_DIR, n]
			img.save_png(ProjectSettings.globalize_path(path))
			print("[loadingshot] %5d ms  up=%s  %s" % [ms, str(Loading.visible), path])
			n += 1
		if n > 2 and not Loading.visible:
			break
	get_tree().quit(0)
