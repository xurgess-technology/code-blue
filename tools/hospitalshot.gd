extends Node
## Windowed screenshots of the generated hospital: the neutral area, the entrance building, the
## break room, the OR, one of each wing room kind and the longest hallway.
##
##   godot --path . tools/hospitalshot.tscn --resolution 1280x720 -- [--seed=N] [--only=or,lab] [--light=off]
##
## Writes tools/hospital_shots/<seed>_<name>.png.

const OUT_DIR := "res://tools/hospital_shots"
const SETTLE_FRAMES := 30
const ROOM_KINDS := ["patient_room", "supply_closet", "pharmacy", "nurse_station", "waiting_room", "restroom",
		"office", "lab", "radiology", "morgue", "janitor_closet", "cafeteria"]

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _only: Array = []
var _flashlight := true


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--only="):
			_only = Array(a.split("=")[1].split(","))
		elif a == "--light=off":
			_flashlight = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
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
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	for i in 10:
		await get_tree().process_frame
	if bot.has_method("set_flashlight"):
		bot.set_flashlight(_flashlight)

	var shots: Array = [
		["neutral_lot", _pose_neutral],
		["neutral_doors", _pose_neutral_doors],
		["entrance_lobby", _pose_lobby],
		["entrance_hall", _pose_hall],
		["break_room", _pose_break_room],
		["or_tables", _pose_or],
		["hallway_long", _pose_hallway],
	]
	for k in ROOM_KINDS:
		shots.append(["room_" + k, _pose_room.bind(k)])
	for s in shots:
		if not _only.is_empty() and not _only.has(s[0]):
			continue
		var ok: bool = await s[1].call()
		if not ok:
			print("[hospitalshot] no pose for ", s[0])
			continue
		for i in SETTLE_FRAMES:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%d_%s.png" % [OUT_DIR, _seed, s[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[hospitalshot] wrote ", path)
	get_tree().quit(0)


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - (pos + Vector3.UP * C.EYE_H)
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	bot._pitch = bot.bot_pitch
	bot.head.rotation.x = bot._pitch


func _pose_neutral() -> bool:
	var n: Dictionary = game.level_info.get("neutral", {})
	if n.is_empty() or (n.get("spawn_points", []) as Array).is_empty():
		return false
	# SWEEP 4A HOOK (pharmacy, chunk 3): the lot is empty asphalt and fog now; the gold pile spot
	# is gone, so anchor on a spawn point instead.
	var anchor: Vector3 = (n.spawn_points[0] as Vector3)
	var ent: Vector3 = game.level_info.entrance.position
	_look_from(anchor + (anchor - ent).normalized() * 9.0 + Vector3(-6.0, 0, 0), ent + Vector3(0, 2.0, 0))
	return true


func _pose_neutral_doors() -> bool:
	var n: Dictionary = game.level_info.get("neutral", {})
	if n.is_empty():
		return false
	var ent: Vector3 = game.level_info.entrance.position
	_look_from(ent + Vector3(0, 0, 2.2), n.shop.position + Vector3(0, 1.0, 0))
	return true


func _room(kind: String) -> Dictionary:
	for r in game.level_info.get("rooms", []):
		if r.kind == kind:
			return r
	return {}


func _pose_lobby() -> bool:
	var r := _room("lobby")
	if r.is_empty():
		return false
	var rect: Rect2 = r.rect
	_look_from(Vector3(rect.end.x - 1.0, 0, rect.end.y - 1.0), Vector3(rect.position.x + 3.0, 1.2, rect.position.y + 1.0))
	return true


func _pose_hall() -> bool:
	var er: Rect2 = game.level_info.get("entrance_rect", Rect2())
	if er.size == Vector2.ZERO:
		return false
	_look_from(Vector3(er.position.x + 2.0, 0, er.position.y + 3.2), Vector3(er.end.x - 2.0, 1.4, er.position.y + 3.0))
	return true


func _pose_break_room() -> bool:
	var r := _room("break_room")
	if r.is_empty():
		return false
	var rect: Rect2 = r.rect
	_look_from(Vector3(rect.end.x - 0.9, 0, rect.end.y - 0.9), Vector3(rect.position.x + 1.0, 1.0, rect.position.y + rect.size.y * 0.45))
	return true


func _pose_or() -> bool:
	var r := _room("or")
	if r.is_empty():
		return false
	var rect: Rect2 = r.rect
	var tables: Array = game.level_info.get("tables", [])
	var c := Vector3.ZERO
	for t in tables:
		c += t.position
	c /= maxf(1.0, tables.size())
	_look_from(Vector3(rect.position.x + 1.0, 0, rect.end.y - 0.9), c + Vector3(0, 0.8, -1.0))
	return true


func _pose_hallway() -> bool:
	# The monster spawn with the longest clear view down a hallway.
	var space := bot.get_world_3d().direct_space_state
	var best_len := -1.0
	var best_from := Vector3.ZERO
	var best_dir := Vector3.FORWARD
	for spot in game.level_info.get("monster_spawns", []):
		var eye: Vector3 = spot + Vector3.UP * C.EYE_H
		for i in 4:
			var dir := Vector3(cos(TAU * i / 4.0), 0, sin(TAU * i / 4.0))
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 80.0)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			var reach: float = 80.0 if hit.is_empty() else eye.distance_to(hit.position)
			if reach > best_len:
				best_len = reach
				best_from = spot
				best_dir = dir
	if best_len < 0.0:
		return false
	print("[hospitalshot] hallway sightline %.1f m" % best_len)
	_look_from(best_from, best_from + best_dir * 20.0 + Vector3.UP * 1.5)
	return true


func _pose_room(kind: String) -> bool:
	var r := _room(kind)
	if r.is_empty():
		return false
	var rect: Rect2 = r.rect
	var doors: Array = r.doors
	var centre := Vector3(rect.get_center().x, 0, rect.get_center().y)
	if doors.is_empty():
		_look_from(centre, centre + Vector3(1, 1.0, 0))
		return true
	var door: Vector3 = doors[0]
	# Stand just outside the doorway, looking across the room to its far side.
	var into := (centre - door)
	into.y = 0.0
	var dir := Vector3(signf(into.x), 0, 0) if absf(into.x) > absf(into.z) else Vector3(0, 0, signf(into.z))
	var far := door + dir * (rect.size.x if dir.x != 0.0 else rect.size.y)
	_look_from(door - dir * 1.1, (far + centre) * 0.5 + Vector3.UP * 0.9)
	return true
