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
##   contact     2 hearts; then it backs off and stays calm briefly. Shoves do nothing.
##
## Cost: observation is evaluated OBSERVE_NEAR times a second when a player is within
## NEAR_RANGE, OBSERVE_FAR otherwise, staggered per nurse; never per frame.

const M := preload("res://scripts/monsters/modes.gd")
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
	m.calm = maxf(0.0, m.calm - delta)
	observe_timer -= delta
	var target: Node = m.nearest_player()
	if observe_timer <= 0.0:
		var near: bool = target != null and target.global_position.distance_to(m.global_position) < NEAR_RANGE
		observe_timer = OBSERVE_NEAR if near else OBSERVE_FAR
		evaluations += 1
		m.observed = Percept.observed_any(g, body_points(m.global_position))
		ahead_blocked = false
		if not m.observed and near and m.calm <= 0.0:
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
	m.nav_move(target.global_position, SPEED, delta)
	m.try_contact(LUNGE_RANGE)


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


func shoved(_dir: Vector3) -> void:
	pass   # it does not even look at you


func recoil_after_hit() -> void:
	var p: Node = m.nearest_player(4.0)
	retreat_from = p.global_position if p != null else m.global_position - m.global_transform.basis.z
	retreat_timer = RETREAT_TIME
	m.calm = CALM_AFTER_HIT + RETREAT_TIME
	m.mode = M.Mode.RETREAT
	m.state = M.State.STUNNED
