extends RefCounted
## The Night Nurse, host side. It can only move while nobody is watching it.
##
## "Watching" is Percept.observed_any() over three points up its body (feet, chest,
## head): some living player has one of them in view, with a clear line, and it is lit
## by a flashlight or a working ceiling fixture. Looking at it in the dark does nothing.
##
##   observed    stops dead in whatever pose it was in; the clip freezes. No sound.
##   unobserved  walks at 3.4 m/s along the navigation path toward the nearest living
##               player, shoes squeaking, humming now and then.
##   stalking    it looks ahead along its path; if the next stretch would put it in
##               someone's light, it holds where it is (in the dark, just outside the beam)
##               for up to STALK_PATIENCE seconds. It also lingers in doorways it passes.
##   contact     no hearts: she grabs (nurse_grab.gd, game.nurse_grab). The surgeon hangs by the
##               neck from her hand for NurseGrab.DROP_AT seconds, staring into her face while her
##               head snaps over; then she drops them downed and is gone, somewhere far off and out
##               of everyone's light, calm for NurseGrab.VANISH_CALM. Watching her changes nothing
##               while she holds someone. Shoves do nothing.
##
## Cost: observation is evaluated OBSERVE_NEAR times a second when a player is within
## NEAR_RANGE, OBSERVE_FAR otherwise, staggered per nurse; never per frame.
##
## Dev room (Monster.dev_nurse(), the dev panel's "Night Nurse" section): `ignore_watch` makes her
## move as if nobody were looking (observed stays false, no stalking), `walk` "follow" walks her to
## FOLLOW_GAP from the player who asked and stops, "loop" walks her round the dev room's loop
## points; neither ever touches a player. `speed` replaces SPEED for every walk.

const M := preload("res://scripts/monsters/modes.gd")
const NurseGrab := preload("res://scripts/monsters/nurse_grab.gd")
const Percept := preload("res://scripts/perception.gd")

const SPEED := 3.4
const SPEED_RETREAT := 3.0
const OBSERVE_NEAR := 0.1
const OBSERVE_FAR := 0.4
const NEAR_RANGE := 30.0
const LOOKAHEAD := 0.9
const STALK_PATIENCE := 4.0
const STALK_MIN_HOLD := 0.7
const STALK_COMMIT := 3.0
const DOOR_LINGER := Vector2(0.5, 1.4)
const RETREAT_TIME := 1.6
const CALM_AFTER_HIT := 3.0
const LUNGE_RANGE := 1.3
const FOLLOW_GAP := 2.5
const LOOP_REACHED := 0.6

var m: CharacterBody3D
var rng := RandomNumberGenerator.new()
var observe_timer := 0.0
var ahead_blocked := false
var stalk_time := 0.0
var hold_timer := 0.0
var linger := 0.0
var retreat_timer := 0.0
var retreat_from := Vector3.ZERO
var _last_door := Vector2i(-999, -999)
var _loop_i := 0
## How many observation evaluations ran, for the lab's performance report.
var evaluations := 0


func _init(monster: CharacterBody3D) -> void:
	m = monster
	rng.seed = hash("nurse%d" % monster.monster_id)
	observe_timer = rng.randf_range(0.0, OBSERVE_NEAR)
	m.mode = M.Mode.WANDER


func body_points(at: Vector3) -> Array:
	return [at + Vector3.UP * 0.15, at + Vector3.UP * 1.3, at + Vector3.UP * (m.height - 0.2)]


func think(delta: float) -> void:
	var g: Node = m.game
	if m.grab_peer != 0:
		_grabbing()
		return
	m.calm = maxf(0.0, m.calm - delta)
	observe_timer -= delta
	var target: Node = m.nearest_player()
	var dev: Dictionary = m.dev_nurse()
	var ignore_watch := bool(dev.get("ignore_watch", false))
	var walk := String(dev.get("walk", ""))
	var speed := float(dev.get("speed", SPEED))
	if ignore_watch:
		m.observed = false
		ahead_blocked = false
	elif observe_timer <= 0.0:
		var near: bool = target != null and target.global_position.distance_to(m.global_position) < NEAR_RANGE
		observe_timer = OBSERVE_NEAR if near else OBSERVE_FAR
		evaluations += 1
		m.observed = Percept.observed_any(g, body_points(m.global_position))
		ahead_blocked = false
		if not m.observed and near and m.calm <= 0.0 and walk == "":
			var next: Vector3 = m.agent.get_next_path_position()
			if next.distance_to(m.global_position) < 0.05:
				next = target.global_position
			var fwd: Vector3 = next - m.global_position
			fwd.y = 0.0
			if fwd.length() > 0.1:
				evaluations += 1
				ahead_blocked = Percept.observed_any(g, body_points(m.global_position + fwd.normalized() * LOOKAHEAD))

	if m.observed:
		# Not a single frame of motion while watched: no turning, no sliding.
		m.moving = false
		m.speed = 0.0
		m.velocity = Vector3.ZERO
		m.state = M.State.WANDER if m.calm > 0.0 else M.State.CHASE
		return

	if retreat_timer > 0.0:
		retreat_timer -= delta
		m.mode = M.Mode.RETREAT
		m.state = M.State.STUNNED
		var away: Vector3 = m.global_position - retreat_from
		away.y = 0.0
		m.step_toward(m.global_position + (away.normalized() if away.length() > 0.05 else Vector3.FORWARD), SPEED_RETREAT, delta)
		return

	if walk != "" and m.calm <= 0.0:
		_dev_walk(dev, walk, speed, delta)
		return

	if target == null or m.calm > 0.0:
		m.mode = M.Mode.IDLE
		m.state = M.State.WANDER
		m.stop()
		if target != null:
			m.face_dir(target.global_position - m.global_position, delta, 2.0)
		return

	m.state = M.State.CHASE
	var d: float = m.global_position.distance_to(target.global_position)

	# Hold in the dark just outside someone's light, but not forever. Once it decides to
	# wait it waits a beat, so a sweeping beam does not make it stutter.
	hold_timer -= delta
	if stalk_time >= STALK_PATIENCE:
		# Patience ran out: it commits to the approach for a while before it will wait again.
		stalk_time = -STALK_COMMIT
		hold_timer = 0.0
	if ahead_blocked and d > LUNGE_RANGE + 0.5 and stalk_time >= 0.0:
		hold_timer = maxf(hold_timer, STALK_MIN_HOLD)
	if hold_timer > 0.0:
		stalk_time += delta
		_hold(target, delta)
		return
	stalk_time = minf(stalk_time + delta, 0.0) if stalk_time < 0.0 else maxf(0.0, stalk_time - delta * 0.5)

	if linger > 0.0:
		linger -= delta
		_hold(target, delta)
		return
	if d < 14.0 and d > 3.0 and _at_new_door():
		linger = rng.randf_range(DOOR_LINGER.x, DOOR_LINGER.y)

	m.mode = M.Mode.WANDER
	m.nav_move(target.global_position, speed, delta)
	m.try_contact(LUNGE_RANGE)


## Dev room: walk for watching. "follow": to FOLLOW_GAP from the player who asked (else the nearest),
## then stand facing them. "loop": round the loop points. Never lunges or hits.
func _dev_walk(dev: Dictionary, walk: String, speed: float, delta: float) -> void:
	m.state = M.State.WANDER
	if walk == "loop":
		var pts: Array = dev.get("loop", [])
		if pts.is_empty():
			m.mode = M.Mode.IDLE
			m.stop()
			return
		_loop_i = _loop_i % pts.size()
		var goal: Vector3 = pts[_loop_i]
		if Vector2(goal.x - m.global_position.x, goal.z - m.global_position.z).length() < LOOP_REACHED:
			_loop_i = (_loop_i + 1) % pts.size()
			goal = pts[_loop_i]
		m.mode = M.Mode.WANDER
		m.nav_move(goal, speed, delta)
		return
	var who: Node = m.game.players.get(int(dev.get("who", 0)))
	if who == null or not is_instance_valid(who) or not who.alive:
		who = m.nearest_player()
	if who == null:
		m.mode = M.Mode.IDLE
		m.stop()
		return
	var d: float = Vector2(who.global_position.x - m.global_position.x, who.global_position.z - m.global_position.z).length()
	if d > FOLLOW_GAP:
		m.mode = M.Mode.WANDER
		# Eases in over the last metre so she does not stop dead from full pace.
		m.nav_move(who.global_position, speed * clampf(d - FOLLOW_GAP + 0.3, 0.35, 1.0), delta)
	else:
		m.mode = M.Mode.IDLE
		m.stop()
		m.face_dir(who.global_position - m.global_position, delta, 3.0)


func _hold(target: Node, delta: float) -> void:
	m.mode = M.Mode.STALK
	m.stop()
	m.face_dir(target.global_position - m.global_position, delta, 3.0)


## True once each time it steps onto a door tile ('+') of the generated map.
func _at_new_door() -> bool:
	var rows: PackedStringArray = m.game.level_info.get("rows", PackedStringArray())
	if rows.is_empty():
		return false
	var t := C.world_to_tile(m.global_position)
	if t.y < 0 or t.y >= rows.size() or t.x < 0 or t.x >= rows[t.y].length():
		return false
	if rows[t.y][t.x] != "+":
		return false
	if t == _last_door:
		return false
	_last_door = t
	return true


## Holding someone: stand still (being watched does not matter now), then let go and vanish.
func _grabbing() -> void:
	m.observed = false
	m.moving = false
	m.speed = 0.0
	m.velocity = Vector3.ZERO
	m.mode = M.Mode.STALK
	m.state = M.State.CHASE
	if m.grab_t < NurseGrab.DROP_AT:
		return
	var p: Node = m.game.players.get(m.grab_peer)
	m.end_grab()
	if m.game.has_method("nurse_drop"):
		m.game.nurse_drop(m, p)
	_vanish()


## Gone: somewhere at least VANISH_MIN from every living surgeon and out of everyone's light
## (the farthest candidate if none qualifies). Clients snap monsters that jump more than 6 m.
func _vanish() -> void:
	var g: Node = m.game
	var best := m.global_position
	var best_d := -1.0
	for i in 24:
		var spot: Vector3 = m.random_nav_point(m.global_position, NurseGrab.VANISH_MIN, 400.0)
		var nearest := 1e9
		for q in g.alive_players():
			nearest = minf(nearest, spot.distance_to(q.global_position))
		if nearest < NurseGrab.VANISH_MIN or Percept.observed_any(g, body_points(spot)):
			if nearest > best_d:
				best_d = nearest
				best = spot
			continue
		best = spot
		break
	m.global_position = best
	m.velocity = Vector3.ZERO
	m.stop()
	m.observed = false
	m.calm = NurseGrab.VANISH_CALM
	m.mode = M.Mode.IDLE
	m.state = M.State.WANDER
	stalk_time = 0.0
	hold_timer = 0.0
	linger = 0.0
	retreat_timer = 0.0
	ahead_blocked = false


func shoved(_dir: Vector3) -> void:
	pass   # it does not even look at you


func recoil_after_hit() -> void:
	var p: Node = m.nearest_player(4.0)
	retreat_from = p.global_position if p != null else m.global_position - m.global_transform.basis.z
	retreat_timer = RETREAT_TIME
	m.calm = CALM_AFTER_HIT + RETREAT_TIME
	m.mode = M.Mode.RETREAT
	m.state = M.State.STUNNED
