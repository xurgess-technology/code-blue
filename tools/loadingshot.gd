extends Node
## Windowed check of the two loading screens, the way a player meets them: the launch printout
## (scripts/launch_screen.gd, while the one-time warmup runs), then a Solo start from the title menu
## (the heart monitor, scripts/loading_screen.gd). Logs every frame slower than SLOW_MS (the screen
## visibly stalling) and saves screenshots.
##
##   godot --path . tools/loadingshot.tscn
##
## Writes tools/game_shots/launch_<n>.png and loading_<n>.png every 0.4 s, and menu_<n>.png every
## 0.3 s through the menu's feed-in, then quits.

const OUT_DIR := "res://tools/game_shots"
const SLOW_MS := 100

var _main: Node3D


var _pre_draw := 0


func _on_pre_draw() -> void:
	_pre_draw = Time.get_ticks_msec()


func _on_post_draw() -> void:
	var d := Time.get_ticks_msec() - _pre_draw
	if d > 150:
		print("[draw] %d ms draw ending abs %d" % [d, Time.get_ticks_msec()])


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	var t0 := Time.get_ticks_msec()
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	await _watch("launch", t0, func(): return not _main.launching)
	# The hand-off: the title menu's sign-in sheet feeding in, shot closely, then at rest.
	var tm := Time.get_ticks_msec()
	await _watch("menu", tm, func(): return Time.get_ticks_msec() - tm > 3000, 300)
	var t1 := Time.get_ticks_msec()
	_main._start_solo("Shot")
	await _watch("loading", t1, func(): return _main.game.phase != Game.Phase.MENU and not Loading.visible)
	RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
	RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	get_tree().quit(0)


func _watch(tag: String, t0: int, finished: Callable, shot_ms := 400) -> void:
	var n := 0
	var next := 0
	var last := t0
	var slow := 0
	var worst := 0
	var phase := ""
	while Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		var gap := now - last
		last = now
		var ms := now - t0
		if gap > SLOW_MS:
			slow += 1
			worst = maxi(worst, gap)
			print("[loadingshot] %s: slow frame %4d ms ending at %5d ms (abs %d)" % [tag, gap, ms, now])
		if ms >= next:
			next = ms + shot_ms
			var img := get_viewport().get_texture().get_image()
			img.save_png(ProjectSettings.globalize_path("%s/%s_%02d.png" % [OUT_DIR, tag, n]))
			n += 1
		var ls: Node = _main.get_node_or_null("LaunchScreen")
		if ls != null:
			var p := "connecting" if ls._connecting else ("stamped" if ls._stamp_at >= 0.0 else "printing")
			if ls._drawn:
				p = "drawn"
			if p != phase:
				phase = p
				print("[loadingshot] %s: phase %s at %d ms" % [tag, p, ms])
		if finished.call():
			break
	print("[loadingshot] %s done at %d ms: %d slow frames, worst %d ms, %d shots" % [tag, Time.get_ticks_msec() - t0, slow, worst, n])
