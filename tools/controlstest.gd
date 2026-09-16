extends Node
## Headless checks for sweep 4a chunk 1 (docs/SWEEP4A.md "Controls, ability slots and HUD,
## scanner"): crouch silences footsteps and jump works, Alt+1..4 fires the right ability slot with
## independent cooldowns, and the scanner needs range/line of sight, resets when either breaks,
## and marks the species scanned on the host when it completes.
##
##   godot --headless --fixed-fps 60 --path . tools/controlstest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

var main: Node3D
var game: Game
var me: Player
var seed_value := 12345
var _failures: Array = []
var _checks := 0


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
	Net.start_solo("Tester")
	game.start_session(seed_value)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(10)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	await _run()
	_finish()


func _run() -> void:
	await _crouch_and_jump()
	await _ability_slots()
	await _scanner()
	await _sprint_dive()


# =========================================================================

func _crouch_and_jump() -> void:
	_say("---- crouch and jump")
	me.revive_full()
	me.teleport(game._floor_at(me.global_position))
	await _frames(3)
	# Crouching: no footstep noise at all, even while walking.
	me.bot_crouch = true
	await _frames(10)
	_check(me.crouching, "holding crouch crouches (%s)" % str(me.crouching))
	var h0 := game.world_time
	me.bot_move = Vector2(0, -1)
	await _frames(90)
	me.bot_move = Vector2.ZERO
	var loud := false
	for n in game.recent_noises(2.0):
		if String(n.kind) == "footstep" and float(n.time) >= h0:
			loud = true
	_check(not loud, "a crouching player's footsteps make no noise event")
	me.bot_crouch = false
	await _until(func(): return not me.crouching, 3.0)
	_check(not me.crouching, "letting go stands back up")
	# Walking (not crouched) does make noise.
	var w0 := game.world_time
	me.bot_move = Vector2(0, -1)
	await _frames(90)
	me.bot_move = Vector2.ZERO
	var heard := false
	for n in game.recent_noises(2.0):
		if String(n.kind) == "footstep" and float(n.time) >= w0:
			heard = true
	_check(heard, "standing and walking still makes footstep noise")
	# Jump: a grounded jump nudges velocity.y up for a moment and comes back down.
	_check(me.is_on_floor(), "on the floor before jumping")
	me.bot_jump += 1
	await _frames(1)
	_check(me.velocity.y > 1.0, "jump gives an upward velocity (%.2f)" % me.velocity.y)
	var landed := await _until(func(): return me.is_on_floor() and me.velocity.y <= 0.01, 3.0)
	_check(landed, "and comes back down to the floor")


## SPRINT-DIVE HOOK: bot_dive (bumped like bot_jump) fires the sprint+crouch-dive. Checks the
## launch (burst speed plus an upward hop), full speed held through the air, the slide-out decay
## after touchdown, the forced crouch capsule, that interacting is blocked while diving, that there
## is no cooldown but each dive costs stamina, the short grace window after sprint drops, and that a
## dive ending under a low ceiling stays crouched (the same refusal-to-stand raycast a normal crouch
## release goes through).
func _sprint_dive() -> void:
	_say("---- sprint + crouch-dive")
	me.revive_full()
	me.teleport(game._floor_at(me.global_position))
	me.bot_crouch = false
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	me.bot_yaw = 0.0
	me.bot_pitch = 0.0
	me.stamina = 1.0
	await _frames(5)
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	var got_sprint := await _until(func(): return me.sprinting, 2.0)
	_check(got_sprint, "bot reaches sprinting before diving")

	var before_interact := me.interact_count
	var stamina_before: float = me.stamina
	me.bot_dive += 1
	await _frames(1)
	_check(me.diving, "bot_dive bump enters the dive state")
	_check(me.crouching, "the capsule flattens (crouching) the instant the dive starts")
	_check(me.stamina < stamina_before - me.DIVE_STAMINA_COST * 0.9,
			"a dive costs stamina (%.2f -> %.2f)" % [stamina_before, me.stamina])
	var burst_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(burst_speed > C.SPRINT_SPEED * 1.15,
			"burst speed clears sprint speed (%.2f > %.2f*1.15)" % [burst_speed, C.SPRINT_SPEED])
	var left_ground := await _until(func(): return not me.is_on_floor(), 0.3)
	_check(left_ground, "the dive launches the player off the ground")

	me.bot_press += 1   # E must do nothing while diving
	await _frames(2)
	_check(me.interact_count == before_interact, "E does nothing while diving")

	var landed := await _until(func(): return not me._dive_airborne, 1.5)
	_check(landed and me.diving, "the dive lands and is still going (sliding out)")
	var land_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(land_speed > C.SPRINT_SPEED * 1.15, "no speed lost in the air (%.2f at touchdown)" % land_speed)
	await _frames(12)   # partway through the ~0.4s slide-out
	var mid_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(mid_speed < land_speed, "speed decays after touchdown (%.2f -> %.2f)" % [land_speed, mid_speed])

	var ended := await _until(func(): return not me.diving, 1.0)
	_check(ended, "the dive ends on its own")
	var resprint := await _until(func(): return me.sprinting, 0.3)
	_check(resprint, "back to a normal sprint once the dive ends")

	# No cooldown: a second dive fires as soon as the first is over.
	var refired := await _until(func():
		if not me.diving:
			me.bot_dive += 1
		return me.diving
	, 0.3)
	_check(refired, "no cooldown: a second dive fires right after the first ends")
	await _until(func(): return not me.diving, 2.0)

	# Out of breath: not enough stamina, no dive.
	await _until(func(): return me.sprinting, 0.5)
	me.stamina = me.DIVE_STAMINA_COST * 0.5
	me.bot_dive += 1
	await _frames(3)
	_check(not me.diving, "too little stamina blocks a dive")
	me.stamina = 1.0

	# Grace window: a dive still fires a moment after sprint drops, but not long after.
	await _until(func(): return me.sprinting, 0.5)
	me.bot_sprint = false
	await _frames(4)
	_check(not me.sprinting, "set-up: sprint has dropped")
	me.bot_dive += 1
	await _frames(1)
	_check(me.diving, "a dive still fires just after sprint drops (grace window)")
	await _until(func(): return not me.diving, 2.0)
	me.bot_sprint = true
	await _until(func(): return me.sprinting, 0.5)
	me.bot_sprint = false
	await _frames(30)   # 0.5 s, well past the 0.2 s grace
	me.bot_dive += 1
	await _frames(2)
	_check(not me.diving, "no dive once the grace window has passed")
	me.bot_move = Vector2.ZERO
	await _frames(3)

	# Low-ceiling safety: a dive that ends under a low ceiling stays crouched, same as letting go
	# of an ordinary crouch already does (_apply_crouch's raycast refuses to stand there). Start a
	# dive on open ground first, then drop the ceiling in (elongated along the dive's -Z travel,
	# above the crouched capsule plus the hop's ~0.25 m peak, below standing height) only once the
	# player is already flattened -- same as a real low tunnel the player only ever enters crouched.
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _until(func(): return me.sprinting, 2.0)
	me.bot_dive += 1
	await _frames(1)
	_check(me.diving and me.crouching, "the dive starts crouched, ready for the low-ceiling check")
	var ceiling := StaticBody3D.new()
	ceiling.collision_layer = C.L_WORLD
	ceiling.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3, 0.2, 8)
	cs.shape = box
	ceiling.add_child(cs)
	add_child(ceiling)
	ceiling.global_position = me.global_position + Vector3(0, 1.6, -3.0)
	await _until(func(): return not me.diving, 1.0)
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	me.bot_crouch = false
	await _frames(10)
	_check(me.crouching, "a dive that ends under a low ceiling stays crouched (refuses to stand)")
	ceiling.queue_free()
	var stood := await _until(func(): return not me.crouching, 2.0)
	_check(stood, "removing the ceiling lets the same body stand back up")


func _ability_slots() -> void:
	_say("---- Alt+1..4 fires the right slot, each with its own cooldown")
	var b: Node = game.brains
	b.on_reset()
	me.revive_full()
	me.bot_move = Vector2.ZERO
	me.bot_crouch = false
	b.add_points(me.peer_id, "walk_in", 1.0)     # -> slot 0, hive_in
	b.add_points(me.peer_id, "discharged", 1.0)  # -> slot 1, echo
	_check(b.slot_of(me.peer_id, "hive_in") == 0 and b.slot_of(me.peer_id, "echo") == 1, "hive_in in slot 1, echo in slot 2")
	# Fire slot 2 (Echo). Slot 1 (Hive Eyes) must still be off cooldown.
	me.bot_ability_slot = 1
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "echo", "Alt+2 fires Echo (%s)" % b.last_result)
	_check(b.cooldown_left(me.peer_id, "discharged") > 0.0, "Echo's own cooldown is running")
	_check(b.cooldown_left(me.peer_id, "walk_in") <= 0.0, "Hive Eyes' cooldown is untouched: each slot cools down on its own")
	# Now fire slot 1 (Hive Eyes): a Walk-In to borrow.
	var wi: Node = b.spawn_walk_in(game._floor_at(me.global_position + Vector3(0, 0, 10)))
	await _frames(2)
	me.bot_ability_slot = 0
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "hive" and me.hive_view, "Alt+1 fires Hive Eyes (%s)" % b.last_result)
	# Pressing the same slot again ends it, like R used to.
	me.bot_ability += 1
	await _frames(3)
	_check(not me.hive_view, "pressing slot 1 again ends the active ability")
	game.kill_monster(wi)
	b.on_reset()


func _scanner() -> void:
	_say("---- scanner: range, line of sight, reset, scanned")
	var here: Vector3 = me.global_position
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 6))) as Node3D
	await _frames(2)
	var to: Vector3 = wi.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_pitch = 0.0
	await _frames(3)
	_check(game.db_record("walk_in").sighted, "in range and in view: sighted (host record)")
	_check(not game.db_record("walk_in").scanned, "not scanned yet")
	me.bot_scan = true
	await _frames(20)
	var mid_progress: float = me.scan_progress
	_check(mid_progress > 0.0, "holding R aimed at it builds progress (%.2f)" % mid_progress)
	# Breaking line of sight resets it.
	me.bot_yaw = atan2(-to.x, -to.z) + PI   # look the other way
	await _frames(10)
	_check(me.scan_progress < mid_progress, "looking away resets progress (%.2f)" % me.scan_progress)
	me.bot_yaw = atan2(-to.x, -to.z)
	await _frames(3)
	# A full hold completes the scan. The stand-in Walk-In (a wandering Discharged body, since
	# Monster.WALK_IN's real AI does not exist on this branch) would drift off-centre over a full
	# 3 s hold; pin it in place so this test is about the scanner, not about tracking a moving
	# target (a real player's aim would need to track it, same as Perception's other callers do).
	var pin: Vector3 = wi.global_position
	var track := func():
		wi.global_position = pin
		var d: Vector3 = pin - me.global_position
		me.bot_yaw = atan2(-d.x, -d.z)
		return game.db_record("walk_in").scanned
	var done := await _until(track, 8.0)
	_check(done, "a full hold marks the species scanned on the host")
	me.bot_scan = false
	game.kill_monster(wi)


# =========================================================================
# helpers

func _check(ok: bool, what: String) -> void:
	_checks += 1
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _say(line: String) -> void:
	print("[controlstest] ", line)


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


func _finish() -> void:
	_say("------------------------------------------")
	_say("result=%s checks=%d failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
