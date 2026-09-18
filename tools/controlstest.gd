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
	await _stances()
	await _sprint_dive()
	await _rocket_boots()
	await _shoulder_camera()


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


## The crouch key as a toggle (bot_crouch_press = one press): stand -> crouch -> prone -> stand,
## the prone capsule and crawl speed, and getting up refusing to go higher than the ceiling allows.
func _stances() -> void:
	_say("---- crouch key: stand -> crouch -> prone -> stand")
	me.revive_full()
	me.teleport(game._floor_at(me.global_position))
	me.bot_crouch = false
	me.bot_prone = false
	me.bot_sprint = false
	me.bot_move = Vector2.ZERO
	await _frames(5)
	_check(not me.crouching and not me.prone, "set-up: standing")
	me.bot_crouch_press += 1
	await _frames(3)
	_check(me.crouching and not me.prone, "one press crouches")
	me.bot_crouch_press += 1
	await _frames(3)
	_check(me.prone and me.crouching, "a second press goes prone")
	_check(is_equal_approx(me._capsule.height, C.PRONE_HEIGHT), "prone capsule is %.2f m (%.2f)" % [C.PRONE_HEIGHT, me._capsule.height])
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _frames(40)
	var crawl: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(me.prone and crawl > 0.3 and crawl <= C.PRONE_SPEED + 0.05, "prone crawls, slowly (%.2f m/s)" % crawl)
	_check(not me.sprinting, "no sprinting while prone")
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	await _frames(5)
	me.bot_crouch_press += 1
	var up := await _until(func(): return not me.crouching and not me.prone, 1.0)
	_check(up, "a third press stands straight back up")


## SPRINT-DIVE HOOK: pressing crouch mid-sprint dives and lands prone. Checks the launch (burst
## speed plus an upward hop), full speed held through the air, the slide-out decay after
## touchdown, the prone capsule, that interacting is blocked while diving, that there is no cooldown
## but each dive costs stamina, the short grace window after sprint drops, and that getting up after
## a dive under a low ceiling only rises as far as there's room.
func _sprint_dive() -> void:
	_say("---- sprint + crouch-dive")
	me.revive_full()
	# A long clear run north: the hub's spine (cols 15-17, rows 5-19), else wherever the player is.
	var er: Rect2 = game.level_info.get("entrance_rect", Rect2())
	var run_from: Vector3 = me.global_position
	if er.size != Vector2.ZERO:
		var t := er.position + Vector2(16.5, 18.5) * C.TILE
		run_from = Vector3(t.x, 0.0, t.y)
	me.teleport(game._floor_at(run_from))
	me.bot_crouch = false
	me.bot_prone = false
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
	me.bot_crouch_press += 1   # the real crouch key, mid-sprint
	await _frames(1)
	_check(me.diving, "pressing crouch mid-sprint dives")
	_check(not me.prone and not me.crouching, "the body stays upright as it launches")
	_check(me.stamina < stamina_before - me.DIVE_STAMINA_COST * 0.9,
			"a dive costs stamina (%.2f -> %.2f)" % [stamina_before, me.stamina])
	var burst_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(burst_speed > C.SPRINT_SPEED * 1.15,
			"burst speed clears sprint speed (%.2f > %.2f*1.15)" % [burst_speed, C.SPRINT_SPEED])
	var ground_y: float = me.global_position.y
	me.bot_press += 1   # E must do nothing while diving
	var left_ground := await _until(func(): return not me.is_on_floor(), 0.3)
	_check(left_ground, "the dive launches the player off the ground")
	_check(me.interact_count == before_interact, "E does nothing while diving")
	var peak := [0.0]
	var air_frames := [0]
	var landed := await _until(func():
		peak[0] = maxf(peak[0], me.global_position.y - ground_y)
		air_frames[0] += 1
		return not me._dive_airborne
	, 1.5)
	var land_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	var land_eye: float = me.head.position.y
	var land_trauma: float = me.fx.get_trauma() if me.fx.has_method("get_trauma") else 0.0
	_check(land_eye < 1.0, "the view has sunk most of the way down by touchdown (eye %.2f m)" % land_eye)
	_check(land_trauma > 0.1, "touchdown shakes the camera (trauma %.2f)" % land_trauma)
	_check(peak[0] > 0.3, "real airtime: rises %.2f m" % peak[0])
	_check(air_frames[0] >= 18, "in the air for %d frames (~%.2f s)" % [air_frames[0], air_frames[0] / 60.0])
	_check(landed and me.diving, "the dive lands and is still going (sliding out)")
	_check(land_speed > C.SPRINT_SPEED * 1.15, "no speed lost in the air (%.2f at touchdown)" % land_speed)
	await _frames(2)
	_check(me.prone, "hits the floor prone")
	await _frames(12)   # partway through the ~0.4s slide-out
	var mid_speed: float = Vector2(me.velocity.x, me.velocity.z).length()
	_check(mid_speed < land_speed, "speed decays after touchdown (%.2f -> %.2f)" % [land_speed, mid_speed])

	var ended := await _until(func(): return not me.diving, 1.0)
	_check(ended, "the dive ends on its own")
	await _frames(3)
	_check(me.prone and not me.sprinting, "and leaves you lying prone")

	# No cooldown: get up, sprint, and a second dive fires straight away.
	await _stand_up()
	await _until(func(): return me.sprinting, 1.0)
	me.bot_dive += 1
	await _frames(1)
	_check(me.diving, "no cooldown: a second dive fires as soon as you're sprinting again")
	await _until(func(): return not me.diving, 2.0)

	# Out of breath: not enough stamina, no dive.
	await _stand_up()
	await _until(func(): return me.sprinting, 1.0)
	me.stamina = me.DIVE_STAMINA_COST * 0.5
	me.bot_dive += 1
	await _frames(3)
	_check(not me.diving, "too little stamina blocks a dive")
	me.stamina = 1.0

	# Grace window: a dive still fires a moment after sprint drops, but not long after.
	await _until(func(): return me.sprinting, 1.0)
	me.bot_sprint = false
	await _frames(4)
	_check(not me.sprinting, "set-up: sprint has dropped")
	me.bot_dive += 1
	await _frames(1)
	_check(me.diving, "a dive still fires just after sprint drops (grace window)")
	await _until(func(): return not me.diving, 2.0)
	await _stand_up()
	me.bot_sprint = true
	await _until(func(): return me.sprinting, 1.0)
	me.bot_sprint = false
	await _frames(30)   # 0.5 s, well past the 0.2 s grace
	me.bot_dive += 1
	await _frames(2)
	_check(not me.diving, "no dive once the grace window has passed")
	me.bot_move = Vector2.ZERO
	await _frames(3)

	# Low ceiling: dive, land, drop a ceiling in above the lying body (between crouch and standing height,
	# elongated along the dive's -Z travel), then ask to stand. There's room to crouch but not to
	# stand, so it stops at a crouch, and finishes standing up by itself once the ceiling is gone.
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _until(func(): return me.sprinting, 2.0)
	me.bot_dive += 1
	await _frames(1)
	await _until(func(): return not me._dive_airborne, 1.5)
	await _frames(2)
	_check(me.diving and me.prone, "landed prone, ready for the low-ceiling check")
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
	await _until(func(): return not me.diving, 2.0)
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	await _frames(5)
	await _stand_up()
	await _frames(10)
	_check(me.crouching and not me.prone, "under a low ceiling, getting up stops at a crouch")
	ceiling.queue_free()
	var stood := await _until(func(): return not me.crouching, 2.0)
	_check(stood, "and stands the rest of the way once the ceiling is gone")


## ROCKET BOOTS: the pharmacy sells them; taking a pair puts them on (hands stay free); a tapped
## dive is still just a dive; holding crouch through the dive burns fuel flying level and fast, and
## letting go drops you; fuel refills on the ground; flying head first into a wall ends the burn and
## costs a heart.
func _rocket_boots() -> void:
	_say("---- rocket boots")
	var found := false
	for e in game.PHARMACY_CATALOG:
		if String(e.kind) == "rocket_boots":
			found = true
	_check(found, "the pharmacy fax lists rocket boots")
	game.money = game.ROCKET_BOOTS_PRICE + 5
	_check(game.order_pharmacy(me, {"rocket_boots": 1}), "the team can order a pair")
	_check(game.money == 5, "and it costs $%d (left $%d)" % [game.ROCKET_BOOTS_PRICE, game.money])
	me.revive_full()
	me.boots = false
	# Taking a pair off the floor puts them on, with full hands.
	game.give_hand(me, "gauze", 2)
	game.give_hand(me, "forceps", 1)
	var it: Node = game._spawn_item("rocket_boots", 2, Transform3D(Basis(), me.global_position + Vector3(0, 0.1, -0.5)), WorldItem.State.LOOSE)
	_check(it.interact_prompt(me).begins_with("Put on"), "the prompt offers to put them on, hands full or not (%s)" % it.interact_prompt(me))
	game.pickup_item(me, it)
	_check(me.boots, "taking a pair puts them on")
	_check(String(me.slots[0].kind) == "gauze" and String(me.slots[1].kind) == "forceps", "and the hands keep what they held")
	_check(is_instance_valid(it) and int(it.count) == 1, "an order of two leaves the other pair behind")
	_check(it.interact_prompt(me).begins_with("!"), "a second pair is refused (%s)" % it.interact_prompt(me))
	game.world_items.erase(it.item_id)
	it.queue_free()
	me.slots = me.empty_slots()

	# A tapped dive is still just a dive.
	await _run_up()
	me.bot_rocket_hold = false
	me.bot_dive += 1
	await _frames(20)
	_check(me.diving and not me.rocketing and is_equal_approx(me.fuel, 1.0), "a tapped dive doesn't light them")
	await _until(func(): return not me.diving, 2.0)

	# Held: the boots light and carry you level and fast, burning fuel.
	await _run_up()
	var start: Vector3 = me.global_position
	me.bot_rocket_hold = true
	me.bot_dive += 1
	var lit := await _until(func(): return me.rocketing, 0.5)
	_check(lit, "holding crouch through the dive lights the boots")
	await _frames(20)
	var v: Vector3 = me.velocity
	_check(Vector2(v.x, v.z).length() > me.ROCKET_SPEED * 0.9, "flying at rocket speed (%.2f m/s)" % Vector2(v.x, v.z).length())
	_check(absf(v.y) < 0.5 and not me.is_on_floor(), "level, off the floor (vy %.2f)" % v.y)
	_check(me.fuel < 0.9, "burning fuel (%.2f)" % me.fuel)
	_check(me._capsule.height <= C.PRONE_HEIGHT + 0.01, "flying flat: the capsule is prone height")
	me.bot_rocket_hold = false
	await _frames(2)
	_check(not me.rocketing, "letting go ends the burn")
	var fuel_left: float = me.fuel
	var landed := await _until(func(): return not me._dive_airborne, 1.5)
	_check(landed, "and the dive falls and lands")
	var flown := Vector2(me.global_position.x - start.x, me.global_position.z - start.z).length()
	_check(flown > 6.0, "a short burn still covers ground (%.1f m)" % flown)
	await _until(func(): return not me.diving, 2.0)
	await _frames(60)
	_check(me.fuel > fuel_left + 0.1, "fuel refills on the ground (%.2f -> %.2f)" % [fuel_left, me.fuel])

	# Faceplant: a wall across the heading, a few metres out.
	me.fuel = 1.0
	await _run_up()
	me.bot_invulnerable = false
	me.invuln = 0.0
	var hp0: int = me.hp
	var wall := StaticBody3D.new()
	wall.collision_layer = C.L_WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 3.0, 0.3)
	shape.shape = box
	wall.add_child(shape)
	game.add_child(wall)
	wall.global_position = me.global_position + Vector3(0, 1.5, -6.0)
	var fp0: int = me.faceplant_count
	me.bot_rocket_hold = true
	me.bot_dive += 1
	var hit := await _until(func(): return me.faceplant_count > fp0, 1.5)
	_check(hit, "flying into a wall is a faceplant")
	_check(not me.rocketing, "which ends the burn")
	await _frames(3)
	_check(me.hp == hp0 - 1, "and costs a heart (%d -> %d)" % [hp0, me.hp])
	me.bot_rocket_hold = false
	await _until(func(): return not me.diving, 2.0)
	_check(me.global_position.z > wall.global_position.z, "bounced back, not through (z %.2f, wall %.2f)" % [me.global_position.z, wall.global_position.z])
	wall.queue_free()
	me.bot_invulnerable = true

	# A new run takes them away with the money.
	game.reset_money()
	_check(not me.boots, "a new run takes the boots off")
	await _stand_up()


## The `camera` setting on "shoulder": the carry camera's rig in ordinary play, the body shown and the
## first-person hands hidden, aiming still from the crosshair; back on "first_person" it lets go.
## Uses the real settings file, so the old value goes back afterwards.
func _shoulder_camera() -> void:
	_say("---- over-the-shoulder camera")
	var was = Settings.get_value("camera")
	await _stand_up()
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	me.slots = me.empty_slots()
	Settings.set_value("camera", "first_person")
	await _frames(40)
	var cc = me.carry_cam
	_check(cc != null and not cc.active, "first person: the shoulder rig is off")
	Settings.set_value("camera", "shoulder")
	var on := await _until(func(): return cc.blend >= 1.0, 1.5)
	_check(on and cc.active, "the setting puts the camera over the shoulder in ordinary play")
	_check(cc.arm_length > 0.8, "the camera sits behind the head (%.2f m)" % cc.arm_length)
	_check(me._carry_body and me.body_visual.visible, "your own body shows")
	_check(cc.hides_hands(), "and the first-person hands hide")
	# Aiming still goes where the crosshair points: a stack on the floor ahead can be taken.
	var at: Vector3 = me.global_position + (-me.global_basis.z) * 1.2
	var it: Node3D = game._spawn_item("gauze", 2, Transform3D(Basis(), at + Vector3.UP * 0.05), WorldItem.State.LOOSE)
	await _frames(20)
	# Steer the crosshair (the camera's ray, not the head's) onto it; the camera moves as you turn.
	for i in 12:
		var d: Vector3 = it.global_position - me.camera.global_position
		me.bot_yaw = atan2(-d.x, -d.z)
		me.bot_pitch = atan2(d.y, Vector2(d.x, d.z).length())
		await _frames(3)
	var aimed := await _until(func(): return String(me.aim_prompt).begins_with("Take"), 1.0)
	_check(aimed, "aiming over the shoulder still finds the stack (%s)" % me.aim_prompt)
	me.bot_press += 1
	var took := await _until(func(): return me.holding("gauze"), 1.0)
	_check(took, "and E takes it")
	await _frames(5)
	_check(me._held_tp.visible, "the stack shows in the body's hand")
	me.bot_pitch = 0.0
	# Hive Eyes, surgery and the rest keep the head: going down drops back to first person.
	Settings.set_value("camera", "first_person")
	var off := await _until(func(): return not cc.active, 1.5)
	_check(off and not me._carry_body and not cc.hides_hands(), "back to first person: the rig lets go")
	Settings.set_value("camera", was)
	me.slots = me.empty_slots()


## Stand, face north on the spine, and sprint.
func _run_up() -> void:
	await _stand_up()
	var er: Rect2 = game.level_info.get("entrance_rect", Rect2())
	var run_from: Vector3 = me.global_position
	if er.size != Vector2.ZERO:
		var t := er.position + Vector2(16.5, 18.5) * C.TILE
		run_from = Vector3(t.x, 0.0, t.y)
	me.teleport(game._floor_at(run_from))
	me.bot_move = Vector2.ZERO
	me.bot_sprint = false
	me.bot_yaw = 0.0
	me.stamina = 1.0
	await _frames(5)
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _until(func(): return me.sprinting, 2.0)


## Bot stance changes apply on change, so toggle bot_prone to request standing.
func _stand_up() -> void:
	me.bot_prone = true
	await _frames(1)
	me.bot_prone = false
	await _frames(3)


func _ability_slots() -> void:
	_say("---- Alt+1..4 fires the right slot, each with its own cooldown")
	var b: Node = game.brains
	b.on_reset()
	me.revive_full()
	me.bot_move = Vector2.ZERO
	me.bot_crouch = false
	b.add_points(me.peer_id, "hive", 1.0)     # -> slot 0, hive_in
	b.add_points(me.peer_id, "discharged", 1.0)  # -> slot 1, echo
	_check(b.slot_of(me.peer_id, "hive_in") == 0 and b.slot_of(me.peer_id, "echo") == 1, "hive_in in slot 1, echo in slot 2")
	# Fire slot 2 (Echo). Slot 1 (Hive Eyes) must still be off cooldown.
	me.bot_ability_slot = 1
	me.bot_ability += 1
	await _frames(3)
	_check(b.last_result == "echo", "Alt+2 fires Echo (%s)" % b.last_result)
	_check(b.cooldown_left(me.peer_id, "discharged") > 0.0, "Echo's own cooldown is running")
	_check(b.cooldown_left(me.peer_id, "hive") <= 0.0, "Hive Eyes' cooldown is untouched: each slot cools down on its own")
	# Now fire slot 1 (Hive Eyes): a Hive to borrow.
	var wi: Node = b.spawn_hive(game._floor_at(me.global_position + Vector3(0, 0, 10)))
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
	# The database persists in user://, shared with any other run or open copy of the game.
	game.database.clear()
	var here: Vector3 = me.global_position
	var wi: Node3D = game.brains.spawn_hive(game._floor_at(here + Vector3(0, 0, 6))) as Node3D
	await _frames(2)
	var to: Vector3 = wi.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_pitch = 0.0
	await _frames(3)
	_check(game.db_record("hive").sighted, "in range and in view: sighted (host record)")
	_check(not game.db_record("hive").scanned, "not scanned yet")
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
	# A full hold completes the scan. The stand-in Hive (a wandering Discharged body, since
	# Monster.HIVE's real AI does not exist on this branch) would drift off-centre over a full
	# 3 s hold; pin it in place so this test is about the scanner, not about tracking a moving
	# target (a real player's aim would need to track it, same as Perception's other callers do).
	var pin: Vector3 = wi.global_position
	var track := func():
		wi.global_position = pin
		var d: Vector3 = pin - me.global_position
		me.bot_yaw = atan2(-d.x, -d.z)
		return game.db_record("hive").scanned
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
