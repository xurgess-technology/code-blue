extends RefCounted
## The Hive, host side. It only has eyes, and it forgets fast (the hive mind).
##
##   IDLE     stands swaying near where it was left, for a few seconds
##   WANDER   shuffles to a spot a few metres from its home at 0.8 m/s
##   RUSH     it SEES someone: lumbers straight at them at 1.8 m/s (a surgeon walks 3.4)
##            While it sees them it keeps re-aiming at where they are. Once it loses sight
##            it keeps walking to where it last saw them, for at most LOST_WALK seconds.
##   SEARCH   standing at that spot, turning its head this way and that for about 3 s,
##            then it gives up and goes back to wandering
##   STUNNED  shoved (2 s) or struck (a short stagger)
##   RETREAT  after landing a hit it backs off, then stays calm (it will not hit) a while
##
## Sight: a cone of SIGHT_DEG degrees, SIGHT_RANGE metres, a clear line from its eyes to the
## player's head or chest (walls block, darkness does not matter). Checked SIGHT_HZ times a
## second, staggered per Hive, and only for players already inside range and cone, so a
## crowd of Hives costs a handful of rays a second. It ignores noise completely.

const M := preload("res://scripts/monsters/modes.gd")

const SIGHT_RANGE := 12.0
const SIGHT_DEG := 110.0
const SIGHT_INTERVAL := 0.2        ## 5 Hz
const EYE_H := 1.5
const SPEED_WANDER := 0.8
const SPEED_CHASE := 1.8
const SPEED_RETREAT := 1.4
const LOST_WALK := 2.5             ## seconds it keeps walking to the last sighting
const SEARCH_TIME := 3.0
const HOME_RADIUS := 7.0
const SHOVE_STUN := 2.0
const RETREAT_TIME := 1.2
const CALM_AFTER_HIT := 4.0
const LUNGE_RANGE := 1.1

var m: CharacterBody3D
var rng := RandomNumberGenerator.new()

var home := Vector3.ZERO
var timer := 0.0
var wander_goal = null
var sight_timer := 0.0
var target_id := 0                 ## peer id of the player it is after, 0 none
var last_seen := Vector3.ZERO
var lost_t := 0.0                  ## seconds since it last saw its target
var seeing := false
var retreat_from := Vector3.ZERO
var _after_stun = null             ## Vector3: where to hunt when the stun ends
var _look_base := 0.0
var _stuck_check := 0.0
var _stuck_from := Vector3.ZERO
## How many line-of-sight rays it cast (tests and the perf report).
var rays := 0


func _init(monster: CharacterBody3D) -> void:
	m = monster
	rng.seed = hash("hive%d" % monster.monster_id)
	sight_timer = rng.randf_range(0.0, SIGHT_INTERVAL)
	m.mode = M.Mode.IDLE
	timer = rng.randf_range(0.5, 3.0)


func think(delta: float) -> void:
	if home == Vector3.ZERO:
		home = m.global_position
	m.calm = maxf(0.0, m.calm - delta)
	timer -= delta

	match m.mode:
		M.Mode.STUNNED:
			m.state = M.State.STUNNED
			m.stop()
			if timer <= 0.0:
				if _after_stun is Vector3:
					_hunt(_after_stun)
					_after_stun = null
				else:
					_start_idle()
			return
		M.Mode.RETREAT:
			m.state = M.State.STUNNED
			var away: Vector3 = m.global_position - retreat_from
			away.y = 0.0
			away = away.normalized() if away.length() > 0.05 else m.global_transform.basis.z
			m.step_toward(m.global_position + away, SPEED_RETREAT, delta, false)
			if timer <= 0.0:
				_start_idle()
			return

	sight_timer -= delta
	if sight_timer <= 0.0:
		sight_timer += SIGHT_INTERVAL
		_look()

	match m.mode:
		M.Mode.RUSH:
			m.state = M.State.CHASE
			var p: Node = _target()
			if seeing and p != null:
				lost_t = 0.0
			else:
				lost_t += delta
			var goal := last_seen
			var left: float = m.nav_move(goal, SPEED_CHASE, delta)
			if not seeing and (left < 0.7 or lost_t >= LOST_WALK or _stuck(delta, 2.0)):
				_start_search()
		M.Mode.SEARCH:
			m.state = M.State.CHASE
			m.stop()
			# Head and body swing slowly left and right, looking for what it lost.
			var swing := sin((SEARCH_TIME - timer) * 2.1) * 1.1
			m.face_dir(Vector3(-sin(_look_base + swing), 0.0, -cos(_look_base + swing)), delta, 2.0)
			if timer <= 0.0:
				target_id = 0
				_start_wander()
		M.Mode.WANDER:
			m.state = M.State.WANDER
			if wander_goal == null:
				wander_goal = _home_point()
			var left2: float = m.nav_move(wander_goal, SPEED_WANDER, delta)
			if left2 < 0.6 or _stuck(delta, 3.0):
				_start_idle()
		_:
			m.state = M.State.WANDER
			m.stop()
			if timer <= 0.0:
				_start_wander()

	if m.calm <= 0.0 and m.mode == M.Mode.RUSH:
		m.try_contact(LUNGE_RANGE)


## One sight check: the nearest player it can see, if any, becomes (or stays) its target.
func _look() -> void:
	seeing = false
	var eye: Vector3 = m.global_position + Vector3.UP * EYE_H
	var fwd: Vector3 = -m.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var cos_half := cos(deg_to_rad(SIGHT_DEG * 0.5))
	var best: Node = null
	var best_d := SIGHT_RANGE
	for p in m.game.alive_players():
		var to: Vector3 = p.global_position - m.global_position
		to.y = 0.0
		var d := to.length()
		if d > best_d:
			continue
		# Anyone practically touching it is noticed whichever way it faces.
		if d > 1.2 and fwd.dot(to / maxf(d, 0.001)) < cos_half:
			continue
		var head: Vector3 = p.global_position + Vector3.UP * 1.6
		rays += 1
		var visible: bool = m.clear_line(eye, head)
		if not visible:
			rays += 1
			visible = m.clear_line(eye, p.global_position + Vector3.UP * 1.0)
		if visible:
			best = p
			best_d = d
	if best == null:
		return
	seeing = true
	target_id = int(best.get("peer_id")) if "peer_id" in best else 0
	last_seen = best.global_position
	if m.mode != M.Mode.RUSH:
		m.mode = M.Mode.RUSH
		m._repath = 0.0
		wander_goal = null
	lost_t = 0.0


func _target() -> Node:
	if target_id == 0:
		return null
	for p in m.game.alive_players():
		if "peer_id" in p and int(p.peer_id) == target_id:
			return p
	return null


func _hunt(pos: Vector3) -> void:
	last_seen = pos
	lost_t = 0.0
	m.mode = M.Mode.RUSH
	m.state = M.State.CHASE
	m._repath = 0.0
	wander_goal = null


func _start_search() -> void:
	m.mode = M.Mode.SEARCH
	timer = SEARCH_TIME * rng.randf_range(0.85, 1.15)
	_look_base = m.rotation.y
	wander_goal = null


func _start_wander() -> void:
	m.mode = M.Mode.WANDER
	m.state = M.State.WANDER
	wander_goal = null


func _start_idle() -> void:
	m.mode = M.Mode.IDLE
	m.state = M.State.WANDER
	timer = rng.randf_range(2.0, 6.0)
	wander_goal = null


## A point a few metres from home on the navigation mesh, where wandering monsters may go.
func _home_point() -> Vector3:
	var map: RID = m.agent.get_navigation_map()
	var ready := NavigationServer3D.map_get_iteration_id(map) > 0
	for i in 8:
		var a := rng.randf() * TAU
		var p := home + Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(2.0, HOME_RADIUS)
		if ready:
			p = NavigationServer3D.map_get_closest_point(map, p)
		if m.game != null and m.game.has_method("monster_may_wander_to") and not m.game.monster_may_wander_to(p):
			continue
		if p.distance_to(m.global_position) > 1.0:
			return p
	return home


func _stuck(delta: float, window: float) -> bool:
	_stuck_check += delta
	if _stuck_check < window:
		return false
	var moved: float = m.global_position.distance_to(_stuck_from)
	_stuck_check = 0.0
	_stuck_from = m.global_position
	return moved < 0.3


## Deaf: a noise means nothing. Something certain (the game says so: a needle that did not
## take) turns it toward that spot, and it comes to look.
func alert_to(pos: Vector3) -> void:
	if m.mode == M.Mode.STUNNED or m.mode == M.Mode.RETREAT or m.mode == M.Mode.SEDATED:
		_after_stun = pos
		return
	_hunt(pos)


func shoved(dir: Vector3) -> void:
	stun(dir, SHOVE_STUN, 1.0)


## Knocked off its feet for `seconds`; `push` metres along dir. `then_hunt` (Vector3) is where
## it goes once it recovers.
func stun(dir: Vector3, seconds: float, push := 0.6, then_hunt = null) -> void:
	dir.y = 0.0
	if dir.length() > 0.01 and push > 0.0:
		m.move_and_collide(dir.normalized() * push)
	var was_stunned: bool = m.mode == M.Mode.STUNNED
	m.mode = M.Mode.STUNNED
	m.state = M.State.STUNNED
	m.lunge_t = 0.0
	timer = maxf(timer, seconds) if was_stunned else seconds
	if then_hunt is Vector3:
		_after_stun = then_hunt


func sedated() -> void:
	target_id = 0
	seeing = false
	wander_goal = null
	_after_stun = null
	home = m.global_position


func woke(hunt_pos) -> void:
	stun(Vector3.ZERO, 1.2, 0.0, hunt_pos)


func recoil_after_hit() -> void:
	var p: Node = m.nearest_player(4.0)
	retreat_from = p.global_position if p != null else m.global_position - m.global_transform.basis.z
	m.mode = M.Mode.RETREAT
	m.state = M.State.STUNNED
	m.calm = CALM_AFTER_HIT
	timer = RETREAT_TIME
