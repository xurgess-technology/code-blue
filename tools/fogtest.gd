extends Node
## Headless check of the fog lot (sweep 4A chunk 2): the fog ring steers a walker back out and
## pulls a settled item back with it, and the driven ambulance comes out, delivers, leaves, and
## stops for a player standing in its lane.
##
##   godot --headless --fixed-fps 60 --path . tools/fogtest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

const FogRing := preload("res://scripts/level/fog_ring.gd")
const WorldItemScript := preload("res://scripts/world_item.gd")

const TIMEOUT := 240.0

var main: Node3D
var game: Game
var bot: Player
var seed_value := 4242
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv[0] == "seed" and kv.size() > 1:
			seed_value = int(kv[1])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Bot")
	game.start_session(seed_value)
	await _frames(3)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > TIMEOUT and not _done:
		_check(false, "timed out")
		_finish()


func _run() -> void:
	_check(game.level_info.has("neutral_rect"), "the level has a neutral_rect")
	var info: Dictionary = game.level_info
	var outer: Rect2 = info.neutral_rect
	var inner := FogRing.inner_rect(info)
	_check(inner.size.x < outer.size.x and inner.size.y < outer.size.y, "the fog belt shrinks the clear area")

	await _check_steering(info, inner)
	await _check_item_pullback(info, inner)
	await _check_ambulance(info)


## A walker deep in the fog, holding forward, bends back toward the lot and comes out without
## ever reaching the map's outer edge.
func _check_steering(info: Dictionary, inner: Rect2) -> void:
	var start := Vector3(inner.position.x - 6.0, 0.0, inner.get_center().y)
	var pos := start
	var yaw := 0.0   # facing further away from the lot at first, the hard case
	var max_depth := 0.0
	var got_out := false
	var steps := 0
	while steps < 1200:
		steps += 1
		yaw = FogRing.steer_yaw(pos, yaw, info, 1.0 / 30.0)
		var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
		pos += fwd * (3.0 / 30.0)
		var d := FogRing.depth_m(pos, info)
		max_depth = maxf(max_depth, d)
		if d <= 0.0 and steps > 5:
			got_out = true
			break
	_check(got_out, "a walker deep in the fog, facing away, steers back and comes out (%d steps)" % steps)
	var outer: Rect2 = info.neutral_rect
	var margin_left := minf(pos.x - outer.position.x, outer.end.x - pos.x)
	_check(max_depth < FogRing.MARGIN_M + 1.0, "it never got deep enough to reach the border wall (max depth %.1f m)" % max_depth)
	_check(margin_left > -0.5, "it stayed inside the lot's own outdoor rect the whole way (%.1f m to spare)" % margin_left)


## A dropped item that comes to rest in the fog is nudged back to the clear area's edge.
func _check_item_pullback(info: Dictionary, inner: Rect2) -> void:
	var deep := Vector3(inner.position.x - 5.0, 0.2, inner.get_center().y)
	_check(FogRing.depth_m(deep, info) > 0.0, "the drop point used for this check is actually in the fog")
	var it := WorldItemScript.new_item(999001, "gauze", 1)
	get_tree().root.add_child(it)
	it.toss(Transform3D(Basis.IDENTITY, deep), Vector3.ZERO)
	var settled := await _until(func(): return it.freeze, 5.0)
	_check(settled, "the dropped item settles")
	_check(FogRing.depth_m(it.global_position, info) <= 0.01, "it settled back on the clear lot, not in the fog (%.1f m deep)" % FogRing.depth_m(it.global_position, info))
	it.queue_free()


## The ambulance emerges from the fog for a delivery, parks, unloads, and drives back once done;
## it stops and honks for a player standing in its lane.
func _check_ambulance(info: Dictionary) -> void:
	if not info.has("ambulance"):
		_say("no level_info.ambulance on this level (fallback map) -- skipping the ambulance checks")
		return
	var amb: Dictionary = info.ambulance
	var bay: Vector3 = amb.position
	var lane: Vector3 = amb.get("lane_start", bay)
	game.clock_in()
	await _frames(2)
	game.dev_phone_call()
	var started := await _until(func(): return String(game.loop.ambulance.get("ph", "")) == "out", 10.0)
	_check(started, "the ambulance leaves the fog for a delivery")

	# Stand a bot in the lane while it is driving out: it should stop and honk.
	var mid := lane.lerp(bay, 0.5)
	bot.teleport(mid + Vector3(0, 0.9, 0))
	await _frames(4)
	var blocked := await _until(func(): return bool(game.loop.ambulance.get("honk", false)), 3.0)
	_check(blocked, "it stops and honks for a player standing in its lane")
	var held_pos: Vector3 = game.loop.ambulance.p
	await _frames(20)
	_check((game.loop.ambulance.p as Vector3).distance_to(held_pos) < 0.05, "it does not move while the lane is blocked")

	bot.teleport(game.spawn_points()[0])
	await _frames(4)
	var resumed := await _until(func(): return not bool(game.loop.ambulance.get("honk", false)), 3.0)
	_check(resumed, "it goes again once the lane clears")

	var parked := await _until(func(): return String(game.loop.ambulance.get("ph", "")) == "parked", 15.0)
	_check(parked, "it parks at the bay")
	_check((game.loop.ambulance.p as Vector3).distance_to(bay) < 1.0, "parked at the bay position")

	var delivered := await _until(func():
		for c in game.cases:
			if String(c.get("state", "")) == "on_table":
				return true
		return false, 40.0)
	_check(delivered, "the patient is unloaded onto a table while the ambulance waits")

	# Finish the case so the loop has nothing more incoming, and clock out so nothing is on the
	# way: the ambulance should then drive back into the fog and disappear.
	for c in game.cases.duplicate():
		if String(c.get("state", "")) == "on_table":
			game.finish_case(int(c.id), true)
	var left := await _until(func(): return String(game.loop.ambulance.get("ph", "")) == "hidden", 20.0)
	_check(left, "once the delivery is done it drives back into the fog and disappears")


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _say(line: String) -> void:
	print("[fogtest] t=%.0f %s" % [t, line])


func _finish() -> void:
	if _done:
		return
	_done = true
	_say("------------------------------------------")
	_say("result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
