extends Node
## Three windowed screenshots of the fog lot (sweep 4A chunk 2), the same way tools/gameshot.gd
## takes its shots.
##
##   godot --path . tools/fogshot.tscn -- [--seed=N]
##
## Writes tools/game_shots/40_fog_from_doors.png, 41_fog_inside.png, 42_fog_ambulance.png.

const OUT_DIR := "res://tools/game_shots"
const FogRing := preload("res://scripts/level/fog_ring.gd")

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
	# The fog belt (scripts/hospital_builder.gd's FogVolume) only shows up with volumetric fog on,
	# which the LOW preset disables; shoot at the doc's target hardware preset (MEDIUM) so these
	# screenshots reflect the real look instead of whatever quality a throwaway session lands on.
	Settings.set_value("quality", 1)
	await get_tree().process_frame

	var shots := [
		{"name": "40_fog_from_doors", "fn": _pose_from_doors, "settle": 40},
		{"name": "41_fog_inside", "fn": _pose_inside_fog, "settle": 40},
		{"name": "42_fog_ambulance", "fn": _pose_ambulance, "settle": 40},
	]
	for shot in shots:
		await shot.fn.call()
		for i in int(shot.get("settle", 30)):
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot.name]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[fogshot] wrote ", path, "  ", img.get_width(), "x", img.get_height())
	print("[fogshot] done")
	get_tree().quit(0)


func _look(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y - C.EYE_H, Vector2(d.x, d.z).length()), -1.0, 1.0)


## Standing just outside the main doors, looking out across the lot toward the fog.
func _pose_from_doors() -> void:
	var ent: Vector3 = game.level_info.entrance.position
	_look(ent + Vector3(0, 0, 3.0), ent + Vector3(0, 1.0, 14.0))


## Inside the fog belt, looking further out.
func _pose_inside_fog() -> void:
	var inner: Rect2 = FogRing.inner_rect(game.level_info)
	var deep := Vector3(inner.get_center().x, 0.0, inner.end.y + 4.0)
	bot.teleport(deep)
	await get_tree().process_frame   # let _local_step apply the fog camera/steering once
	bot.bot_yaw = 0.0
	bot.bot_pitch = 0.0


## The ambulance emerging from the fog on a delivery.
func _pose_ambulance() -> void:
	game.clock_in()
	await get_tree().process_frame
	game.dev_phone_call()
	var amb: Dictionary = game.level_info.get("ambulance", {})
	var bay: Vector3 = amb.get("position", Vector3.ZERO)
	var lane: Vector3 = amb.get("lane_start", bay)
	var side := Vector3(4.0, 0, 0)
	_look(bay + side + Vector3(0, 0, 4.0), lane)
	var t := 0.0
	while t < 8.0 and String(game.loop.ambulance.get("ph", "")) != "out":
		await get_tree().process_frame
		t += get_process_delta_time()
