extends Node
## Windowed screenshots for brains (sweep 3): fresh, spoiling and rotten brains up close and in
## hand, the blender (idle and blending), the dumpster sign, the Echo view and the Hive Eyes view.
##
##   godot --path . --resolution 1280x720 tools/brainshot.tscn -- [--seed=N] [--only=brains,blender,echo,hive,dumpster]
##
## Writes tools/brain_shots/<name>.png.

const OUT_DIR := "res://tools/brain_shots"

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _only := ""
var _cam: Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		if a.begins_with("--only="):
			_only = a.split("=")[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_run.call_deferred()


func _want(k: String) -> bool:
	return _only == "" or _only.split(",").has(k)


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await _frames(2)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await _frames(30)
	if _want("brains"):
		await _brain_shots()
	if _want("blender"):
		await _blender_shots()
	if _want("dumpster"):
		await _dumpster_shot()
	game.begin_shift()
	await _frames(30)
	for m in game.monsters.values().duplicate():
		game.kill_monster(m)
	await _frames(5)
	if _want("echo"):
		await _echo_shots()
	if _want("hive"):
		await _hive_shots()
	print("[brainshot] done")
	get_tree().quit(0)


# =========================================================================

func _brain_shots() -> void:
	var b: Node = game.brains
	await _until(func(): return b.blender != null, 5.0)
	# A row of brains on the break-room floor, from fresh to rotten, under the room's own lights.
	var bl: Node3D = b.blender
	var room_c := _break_room_centre()
	var base: Vector3 = game._floor_at(room_c)
	var row := [["brain_walk_in", 0.0], ["brain_walk_in", 150.0], ["brain_walk_in", 260.0], ["brain_discharged", 0.0], ["brain_discharged", 260.0]]
	var placed := []
	for i in row.size():
		var it: Node = b.spawn_brain(row[i][0], 1.0, base + Vector3((i - 2) * 0.24, 0.2, 0.0))
		it.bt = game.world_time - float(row[i][1])
		it.global_rotation.y = 0.5 + i * 0.3
		placed.append(it)
	await _frames(20)
	_free_cam(base + Vector3(0.05, 0.55, 0.85), base + Vector3(0.0, 0.05, 0.0), 50.0)
	await _frames(10)
	await _shot("01_brains_row_fresh_to_rotten")
	# Under a flashlight, closer.
	var spot := SpotLight3D.new()
	spot.light_color = Color(1.0, 0.86, 0.62)
	spot.light_energy = 3.0
	spot.spot_range = 5.0
	spot.spot_angle = 30.0
	_cam.add_child(spot)
	_free_cam(base + Vector3(-0.2, 0.32, 0.4), base + Vector3(-0.22, 0.05, 0.0), 45.0)
	await _frames(10)
	await _shot("02_brains_closeup_flashlight_fresh_spoiling")
	_free_cam(base + Vector3(0.3, 0.32, 0.4), base + Vector3(0.36, 0.05, 0.0), 45.0)
	await _frames(10)
	await _shot("03_brains_closeup_flashlight_discharged_fresh_rotten")
	_end_free_cam()
	for it in placed:
		if is_instance_valid(it):
			game.world_items.erase(it.item_id)
			it.queue_free()
	# In hand, first person.
	for e in [["fresh", 0.0], ["rotten", 260.0]]:
		_clear()
		bot.take_into("brain_walk_in", 1, 150)
		bot.slots[0]["bt"] = game.world_time - float(e[1])
		bot.selected = 0
		_look_from(room_c, room_c + Vector3(2.0, 0.6, 0.0))
		await _frames(25)
		await _shot("04_held_brain_%s" % e[0])
	_clear()


func _blender_shots() -> void:
	var b: Node = game.brains
	await _until(func(): return b.blender != null, 5.0)
	var bl: Node3D = b.blender
	var front: Vector3 = bl.global_position + bl.global_transform.basis.z * 1.3
	_clear()
	bot.take_into("brain_discharged", 1, 350)
	bot.slots[0]["bt"] = game.world_time
	bot.selected = 0
	_look_from(Vector3(front.x, bl.global_position.y, front.z), bl.global_position + Vector3.UP * 0.15)
	bot.bot_aim_id = "blender"
	await _frames(30)
	await _shot("05_blender_prompt")
	# From the room, to see where it stands.
	var room_c := _break_room_centre()
	_free_cam(room_c + Vector3.UP * 1.7 + (room_c - bl.global_position).normalized() * 0.5, bl.global_position + Vector3.UP * 0.2, 70.0)
	await _frames(15)
	await _shot("06_blender_in_break_room")
	_end_free_cam()
	bot.bot_interact = true
	await _frames(55)
	await _shot("07_blender_blending")
	_free_cam(bl.global_position + bl.global_transform.basis.z * 0.55 + Vector3.UP * 0.35, bl.global_position + Vector3.UP * 0.18, 45.0)
	await _frames(8)
	await _shot("08_blender_blending_closeup")
	_end_free_cam()
	await _until(func(): return not bot.holding("brain_discharged"), 3.0)
	bot.bot_interact = false
	bot.bot_aim_id = ""
	await _frames(20)
	await _shot("09_blender_drunk_message")
	game.brains.on_reset()


func _dumpster_shot() -> void:
	await _until(func(): return game.economy.placed(), 5.0)
	var bin: Node3D = game.economy.sell_bin
	var out: Vector3 = bin.global_transform.basis.z
	var nsb = game.level_info.get("neutral", {}).get("sell_bin", {})
	if nsb is Dictionary and nsb.has("front"):
		out = (nsb.front as Vector3) - bin.global_position
		out.y = 0.0
		out = out.normalized()
	var f: Vector3 = bin.global_position + out * 4.5
	_clear()
	bot.take_into("brain_walk_in", 1, 150)
	bot.slots[0]["bt"] = game.world_time - 120.0
	_look_from(f, bin.global_position + Vector3.UP * 1.5)
	bot.bot_aim_id = "sell_bin"
	await _frames(30)
	await _shot("10_dumpster_sign")
	var near: Vector3 = bin.global_position + out * 1.8
	_look_from(near, bin.global_position + Vector3.UP * 0.9)
	await _frames(20)
	await _shot("11_dumpster_prompt")
	bot.bot_aim_id = ""
	_clear()


func _echo_shots() -> void:
	var b: Node = game.brains
	# A spot in a wing with containers and loot around: the container with the most loot near it.
	var best: Vector3 = game.table_pos()
	var best_n := -1
	for c in game.level_info.get("containers", []):
		var p: Vector3 = c.get("position", Vector3.ZERO)
		var n := 0
		for it in game.world_items.values():
			if (it.global_position as Vector3).distance_to(p) < 12.0:
				n += 1
		if n > best_n:
			best_n = n
			best = p
	var stand: Vector3 = game._floor_at(best)
	var map := get_viewport().world_3d.navigation_map
	stand = NavigationServer3D.map_get_closest_point(map, stand + Vector3(2.0, 0, 0))
	# Company: a Discharged and a Walk-In stand-in behind walls, and a teammate dummy.
	var yaw := _open_direction(stand)
	var dirv := Vector3(-sin(yaw), 0, -cos(yaw))
	var side := Vector3(cos(yaw), 0, -sin(yaw))
	# In front but off to the sides, where walls are likely to hide them.
	var m1: Node = game._add_monster("discharged", NavigationServer3D.map_get_closest_point(map, stand + dirv * 9.0 + side * 5.0))
	var m2: Node = b.spawn_walk_in(NavigationServer3D.map_get_closest_point(map, stand + dirv * 7.0 - side * 5.0))
	var mate := _dummy(NavigationServer3D.map_get_closest_point(map, stand + dirv * 12.0 - side * 1.0))
	_look_from(stand, stand + dirv * 6.0 + Vector3.UP * 1.2)
	await _frames(20)
	for m in [m1, m2]:
		if m != null:
			m.set_physics_process(false)
	await _shot("12_echo_before")
	b.add_points(bot.peer_id, "discharged", 2.0)
	bot.bot_ability += 1
	await _frames(20)
	await _shot("13_echo_wave")
	await _frames(40)
	await _shot("14_echo_full")
	# Turned around, the other way.
	bot.bot_yaw = yaw + PI
	await _frames(12)
	await _shot("15_echo_full_behind")
	_say("echo: %d outlines of %d things" % [b.echo_view.ghosts.size(), b.echo_view.target_count])
	await _until(func(): return not b.echo_view.active, 8.0)
	b.on_reset()
	for m in [m1, m2]:
		if m != null and is_instance_valid(m):
			game.kill_monster(m)
	if is_instance_valid(mate):
		game.players.erase(mate.peer_id)
		mate.queue_free()


func _hive_shots() -> void:
	var b: Node = game.brains
	# Stand in a corridor; a Walk-In a room or two away looks down its own hallway.
	var spots: Array = game.level_info.get("monster_spawns", [])
	var map := get_viewport().world_3d.navigation_map
	var stand: Vector3 = spots[0] if not spots.is_empty() else game.table_pos()
	var sy := _open_direction(stand)
	# The Walk-In a room away: 12 m down the longest open line from where I stand, then a few metres aside.
	var wpos: Vector3 = stand + Vector3(-sin(sy), 0, -cos(sy)) * 12.0 + Vector3(cos(sy), 0, -sin(sy)) * 3.0
	var wi: Node = b.spawn_walk_in(NavigationServer3D.map_get_closest_point(map, wpos))
	await _frames(5)
	wi.set_physics_process(false)
	var yaw := _open_direction(wi.global_position)
	wi.rotation.y = yaw
	var dirv := Vector3(-sin(yaw), 0, -cos(yaw))
	_look_from(stand, stand + Vector3(1, 1.5, 0))
	await _frames(10)
	b.add_points(bot.peer_id, "walk_in", 2.0)
	_say("hive: me %s, walk-in %s (%s), %.1f m, monsters %d" % [str(bot.global_position), str(wi.global_position), wi.kind, bot.global_position.distance_to(wi.global_position), game.monsters.size()])
	bot.bot_ability += 1
	await _frames(30)
	_say("hive: result %s" % b.last_result)
	await _shot("16_hive_eyes")
	# Looking at a teammate from the Walk-In's eyes: put a dummy in front of it.
	var dummy := _dummy(wi.global_position + dirv * 4.0)
	await _frames(20)
	await _shot("17_hive_eyes_teammate_in_view")
	_say("hive: active=%s view=%s" % [str(b.local_hive_active()), str(bot.hive_view)])
	bot.bot_ability += 1
	await _frames(20)
	# The helpless body, seen by someone else: the dummy's view is not rendered, so a free camera.
	b._cd.clear()
	b._press_grace.clear()
	bot.bot_ability += 1
	await _frames(40)
	main.set_process(false)
	var body_cam := Camera3D.new()
	add_child(body_cam)
	body_cam.global_transform = Transform3D(Basis(), bot.global_position + Vector3(1.8, 1.5, 1.8)).looking_at(bot.global_position + Vector3.UP * 1.1)
	body_cam.make_current()
	bot.body_visual.visible = true
	bot.is_local = false
	await _frames(40)
	await _shot("18_hive_eyes_body_slumped")
	bot.is_local = true
	bot.body_visual.visible = false
	body_cam.queue_free()
	main.set_process(true)
	if is_instance_valid(dummy):
		game.players.erase(dummy.peer_id)
		dummy.queue_free()


# =========================================================================
# helpers

func _break_room_centre() -> Vector3:
	for r in game.level_info.get("rooms", []):
		if String(r.kind) == "break_room":
			var rect: Rect2 = r.rect
			var c := rect.get_center()
			return Vector3(c.x, game.clock_pos().y, c.y)
	return game.clock_pos() + Vector3(2, 0, 0)


## The yaw (Godot facing) with the longest clear line from a point at eye height.
func _open_direction(p: Vector3) -> float:
	var space := get_viewport().world_3d.direct_space_state
	var best := 0.0
	var best_len := -1.0
	for i in 16:
		var yaw := TAU * i / 16.0
		var dir := Vector3(-sin(yaw), 0, -cos(yaw))
		var eye := p + Vector3.UP * 1.6
		var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 30.0)
		q.collision_mask = C.L_WORLD
		var hit := space.intersect_ray(q)
		var l: float = 30.0 if hit.is_empty() else eye.distance_to(hit.position)
		if l > best_len:
			best_len = l
			best = yaw
	return best


func _dummy(at: Vector3) -> Player:
	var p: Player = Player.new_player(-66, "Teammate", false)
	p.is_bot = true
	p.bot_active = true
	game.players[-66] = p
	game.get_node("Entities").add_child(p)
	p.teleport(game._floor_at(at))
	return p


func _free_cam(pos: Vector3, at: Vector3, fov: float) -> void:
	main.set_process(false)
	if _cam == null:
		_cam = Camera3D.new()
		_cam.near = 0.02
		add_child(_cam)
	_cam.fov = fov
	_cam.global_transform = Transform3D(Basis(), pos).looking_at(at)
	_cam.make_current()


func _end_free_cam() -> void:
	if _cam != null:
		_cam.queue_free()
		_cam = null
	main.set_process(true)


func _clear() -> void:
	bot.slots = Player.empty_slots()
	bot.selected = 0


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(game._floor_at(pos))
	var eye := bot.global_position + Vector3.UP * C.EYE_H
	var d := at - eye
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	_say("wrote " + path)


func _say(line: String) -> void:
	print("[brainshot] ", line)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _until(cond: Callable, seconds: float) -> bool:
	var frames := int(seconds * 60.0)
	for i in frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())
