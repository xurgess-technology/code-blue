extends RefCounted
## The Discharged, host side. Completely blind: it knows only what it hears.
##
##   WANDER   drifts between corridor spots at 1.4 m/s, the IV pole rattling behind it
##   LISTEN   a noise reached it: it stops dead, cocks its head toward the sound for
##            0.8-1.2 s (the rattle stops, which is the tell)
##   RUSH     a fast awkward lope to where the noise was, 5.2 m/s
##   SEARCH   picks at that spot for a few seconds, twitching, then gives up
##   STUNNED  shoved: 2 s of staggering
##   RETREAT  after landing a hit it backs off, then stays calm (deaf) for a while
##
## Hearing: a noise of loudness L is heard within L * HEAR_PER_LOUDNESS metres, halved
## when a wall is between the noise and its head. Flashlights mean nothing to it.

const M := preload("res://scripts/monsters/modes.gd")

const HEAR_PER_LOUDNESS := 22.0
const OCCLUDED_FACTOR := 0.5
const SPEED_WANDER := 1.4
const SPEED_RUSH := 5.2
const SPEED_SEARCH := 1.1
const SPEED_RETREAT := 2.6
const LISTEN_MIN := 0.8
const LISTEN_MAX := 1.2
const SEARCH_MIN := 3.0
const SEARCH_MAX := 5.0
const RUSH_GIVE_UP := 12.0
const SHOVE_STUN := 2.0
const RETREAT_TIME := 1.3
const CALM_AFTER_HIT := 5.0
const LUNGE_RANGE := 1.35

var m: CharacterBody3D
var rng := RandomNumberGenerator.new()

var target := Vector3.ZERO     ## where the last noise it chased was
var timer := 0.0
var wander_goal = null
var heard_time := -1e9         ## newest noise time already considered
var retreat_from := Vector3.ZERO
var _stuck_check := 0.0
var _stuck_from := Vector3.ZERO
## Last noise it reacted to, for tests and debugging.
var last_heard: Dictionary = {}


func _init(monster: CharacterBody3D) -> void:
	m = monster
	rng.seed = hash("discharged%d" % monster.monster_id)
	m.mode = M.Mode.WANDER


func think(delta: float) -> void:
	var g: Node = m.game
	m.calm = maxf(0.0, m.calm - delta)
	timer -= delta

	# Hearing runs first so a noise can interrupt anything but a stun or a retreat.
	var noise := _hear(g)
	if not noise.is_empty():
		_react(noise)

	match m.mode:
		M.Mode.STUNNED:
			m.state = M.State.STUNNED
			m.stop()
			if timer <= 0.0:
				_start_wander()
			return
		M.Mode.RETREAT:
			m.state = M.State.STUNNED
			var away := m.global_position - retreat_from
			away.y = 0.0
			away = away.normalized() if away.length() > 0.05 else -m.global_transform.basis.z
			m.step_toward(m.global_position + away, SPEED_RETREAT, delta)
			if timer <= 0.0:
				_start_wander()
			return
		M.Mode.LISTEN:
			m.state = M.State.CHASE
			m.stop()
			m.listen_yaw = clampf(m.yaw_to(target), -1.2, 1.2)
			# It turns its body slowly toward the sound while it listens.
			m.face_dir(target - m.global_position, delta, 1.2)
			if timer <= 0.0:
				m.mode = M.Mode.RUSH
				timer = RUSH_GIVE_UP
		M.Mode.RUSH:
			m.state = M.State.CHASE
			var left: float = m.nav_move(target, SPEED_RUSH, delta)
			if left < 0.9 or timer <= 0.0 or _stuck(delta, 2.5):
				_start_search()
		M.Mode.SEARCH:
			m.state = M.State.CHASE
			if wander_goal == null or m.global_position.distance_to(wander_goal) < 0.5:
				wander_goal = target + Vector3(rng.randf_range(-2.0, 2.0), 0.0, rng.randf_range(-2.0, 2.0))
			m.nav_move(wander_goal, SPEED_SEARCH, delta)
			if timer <= 0.0:
				_start_wander()
		M.Mode.IDLE:
			m.state = M.State.WANDER
			m.stop()
			if timer <= 0.0:
				_start_wander()
		_:
			m.state = M.State.WANDER
			if wander_goal == null:
				wander_goal = m.random_nav_point(m.global_position, 6.0, 22.0)
			var left2: float = m.nav_move(wander_goal, SPEED_WANDER, delta)
			if left2 < 0.8 or _stuck(delta, 3.0):
				wander_goal = null
				m.mode = M.Mode.IDLE
				timer = rng.randf_range(0.8, 2.5)

	if m.calm <= 0.0:
		m.try_contact(LUNGE_RANGE)


## The loudest new noise it can hear, or {}.
func _hear(g: Node) -> Dictionary:
	if not g.has_method("recent_noises"):
		return {}
	var noises: Array = g.recent_noises(1.5)
	var newest := heard_time
	var best := {}
	var best_margin := 0.0
	var deaf: bool = m.calm > 0.0 or m.mode == M.Mode.STUNNED or m.mode == M.Mode.RETREAT
	var ear: Vector3 = m.global_position + Vector3.UP * 1.55
	for n in noises:
		var t := float(n.time)
		if t <= heard_time:
			continue
		newest = maxf(newest, t)
		if deaf:
			continue
		var pos: Vector3 = n.pos
		var reach := float(n.loudness) * HEAR_PER_LOUDNESS
		var d := ear.distance_to(pos + Vector3.UP * 0.5)
		if d > reach:
			continue
		if d > reach * OCCLUDED_FACTOR and not m.clear_line(ear, pos + Vector3.UP * 0.5):
			continue
		var margin := reach - d
		if margin > best_margin:
			best_margin = margin
			best = n
	heard_time = newest
	return best


func _react(noise: Dictionary) -> void:
	last_heard = noise
	target = noise.pos
	match m.mode:
		M.Mode.WANDER, M.Mode.IDLE, M.Mode.SEARCH:
			m.mode = M.Mode.LISTEN
			m.stop()
			timer = rng.randf_range(LISTEN_MIN, LISTEN_MAX)
			wander_goal = null
		M.Mode.RUSH:
			timer = RUSH_GIVE_UP
			m._repath = 0.0
		_:
			pass   # already listening: just re-aim


func _start_search() -> void:
	m.mode = M.Mode.SEARCH
	timer = rng.randf_range(SEARCH_MIN, SEARCH_MAX)
	wander_goal = null


func _start_wander() -> void:
	m.mode = M.Mode.WANDER
	m.state = M.State.WANDER
	m.listen_yaw = 0.0
	wander_goal = null


func _stuck(delta: float, window: float) -> bool:
	_stuck_check += delta
	if _stuck_check < window:
		return false
	var moved: float = m.global_position.distance_to(_stuck_from)
	_stuck_check = 0.0
	_stuck_from = m.global_position
	return moved < 0.4


## Something very loud and certain (the game may still call this): treat it as a noise.
func alert_to(pos: Vector3) -> void:
	if m.calm > 0.0 or m.mode == M.Mode.STUNNED or m.mode == M.Mode.RETREAT:
		return
	_react({"pos": pos, "loudness": 1.0, "kind": "alert", "time": 0.0})


func shoved(dir: Vector3) -> void:
	dir.y = 0.0
	m.move_and_collide(dir.normalized() * 1.1)
	m.mode = M.Mode.STUNNED
	m.state = M.State.STUNNED
	m.lunge_t = 0.0
	timer = SHOVE_STUN


func recoil_after_hit() -> void:
	var p: Node = m.nearest_player(4.0)
	retreat_from = p.global_position if p != null else m.global_position - m.global_transform.basis.z
	m.mode = M.Mode.RETREAT
	m.state = M.State.STUNNED
	m.calm = CALM_AFTER_HIT
	timer = RETREAT_TIME
