extends Node
## Measures real frame times at each quality preset so tuning is based on numbers
## rather than vibes.
##
##   godot --path . tools/bench.tscn -- [--seed=N] [--frames=N]

const WARMUP := 40

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _frames := 220
var _results: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--frames="):
			_frames = int(a.split("=")[1])

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Bench")
	game.start_session(_seed)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	game.begin_shift()
	await get_tree().process_frame

	print("[bench] resolution %s  gpu=%s" % [
		str(get_viewport().get_visible_rect().size),
		RenderingServer.get_video_adapter_name()])
	print("[bench] level: %d lights, %d monsters, %d tools" % [
		game.level_info.get("lights", []).size(), game.monsters.size(), game.world_items.size()])

	for q in [2, 1, 0]:
		await _measure(q)
	print("[bench] --------------------------------------------")
	for r in _results:
		print("[bench] quality %d: avg %.1f fps (%.1f ms)  worst %.1f ms" % [r.q, r.fps, r.avg_ms, r.worst_ms])
	get_tree().quit(0)


func _measure(q: int) -> void:
	main.set_quality(q, false)
	# Stand in the middle of the map looking down the longest corridor.
	bot.teleport(game.table_pos() + Vector3(0, 0, 5.0))
	bot.bot_yaw = 0.0
	bot.rotation.y = 0.0
	for i in WARMUP:
		await get_tree().process_frame

	var total := 0.0
	var worst := 0.0
	var spin := 0.0
	for i in _frames:
		await get_tree().process_frame
		var ms := get_process_delta_time() * 1000.0
		total += ms
		worst = maxf(worst, ms)
		# Sweep the view so we are not measuring one lucky angle.
		spin += 0.02
		bot.bot_yaw = sin(spin) * 1.6
		bot.rotation.y = bot.bot_yaw
	var avg := total / _frames
	_results.append({"q": q, "avg_ms": avg, "fps": 1000.0 / avg, "worst_ms": worst})
	print("[bench] quality %d -> %.1f fps" % [q, 1000.0 / avg])
