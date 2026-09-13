class_name Monster
extends CharacterBody3D
## Two creatures, two rules you can learn.
##
##   The Discharged  blind; hunts by sound. Freezes to listen, then rushes the noise.
##   The Night Nurse moves only while nobody is looking at it with light on it.
##
## Simulated only on the host (the behaviour lives in scripts/monsters/*_brain.gd).
## Clients receive report() snapshots and animate from them, so everything the
## visual needs (mode, observed, listen direction, lunge) is in the report.

enum State { WANDER, CHASE, STUNNED }

## What the monster is visibly doing. Replicated; drives animation and sound.
enum Mode { IDLE, WANDER, LISTEN, RUSH, SEARCH, STALK, STUNNED, RETREAT }

const DISCHARGED := "discharged"
const NIGHT_NURSE := "night_nurse"
const MAX_MONSTERS := 5

const Model := preload("res://scripts/monsters/monster_model.gd")
const DischargedBrain := preload("res://scripts/monsters/discharged_brain.gd")
const NurseBrain := preload("res://scripts/monsters/night_nurse_brain.gd")

var monster_id: int = 0
var kind: String = DISCHARGED
var state: int = State.WANDER
var damage: int = 1
var knockback: float = 9.0
var calm: float = 0.0
var moving: bool = false

var mode: int = Mode.WANDER
var speed: float = 0.0          ## current ground speed, m/s
var observed: bool = false      ## Night Nurse: someone is watching it in the light
var listen_yaw: float = 0.0     ## Discharged: head turn toward the sound, relative to facing
var lunge_t: float = 0.0        ## > 0 while the lunge plays
var body_radius: float = 0.38
var height: float = 1.85

var agent: NavigationAgent3D
var model: Node3D
var brain: RefCounted
var game: Node = null

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _repath := 0.0
var _blocked_t := 0.0
var _unjam_t := 0.0
var _unjam_side := 1.0
var _last_mode := -1
var _last_lunge := false
var _last_calm := false
var _sound_timer := 0.0
var _lullaby_timer := 0.0
var _twitch_timer := 0.0
var _twitch := Vector3.ZERO
var _listen_amt := 0.0
var _lunge_amt := 0.0
var _stagger := 0.0
var _rng := RandomNumberGenerator.new()


## Which monsters a shift gets: shift 1 is one Discharged; the Night Nurse joins on
## shift 2; one more of each every two shifts after that; one extra Discharged per two
## players beyond the first. Never more than MAX_MONSTERS.
static func roster(shift: int, player_count: int) -> Array[String]:
	var extra := maxi(0, (shift - 2) / 2) if shift >= 2 else 0
	var d := 1 + extra + maxi(0, (player_count - 1) / 2)
	var n := (1 + extra) if shift >= 2 else 0
	while d + n > MAX_MONSTERS:
		if n >= d and n > 1:
			n -= 1
		else:
			d -= 1
	var out: Array[String] = []
	var i := 0
	while d + n > 0:
		if (i % 2 == 0 and d > 0) or n == 0:
			out.append(DISCHARGED)
			d -= 1
		else:
			out.append(NIGHT_NURSE)
			n -= 1
		i += 1
	return out


static func new_monster(id: int, monster_kind: String, pos: Vector3) -> CharacterBody3D:
	var m: Monster = Monster.new()
	m.monster_id = id
	m.kind = monster_kind if monster_kind == NIGHT_NURSE else DISCHARGED
	m.name = "Monster_%d_%s" % [id, m.kind]
	m._rng.seed = hash("monster%d" % id)
	m._build()
	m.position = pos
	m._target_pos = pos
	return m


func _build() -> void:
	collision_layer = C.L_MONSTER
	collision_mask = C.L_WORLD
	if kind == NIGHT_NURSE:
		damage = 2
		knockback = 11.0
		body_radius = 0.34
		height = 2.3
		brain = NurseBrain.new(self)
	else:
		damage = 1
		knockback = 9.0
		body_radius = 0.38
		height = 1.85
		brain = DischargedBrain.new(self)

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = body_radius
	capsule.height = height
	shape.shape = capsule
	shape.position.y = height * 0.5
	add_child(shape)

	agent = NavigationAgent3D.new()
	agent.radius = 0.45
	agent.height = 1.8
	agent.path_desired_distance = 0.25
	agent.target_desired_distance = 0.5
	agent.avoidance_enabled = false
	add_child(agent)

	model = Model.new()
	add_child(model)
	model.setup(kind)
	_lullaby_timer = _rng.randf_range(6.0, 14.0)


func _ready() -> void:
	game = get_tree().get_first_node_in_group("game")
	add_to_group("monster")
	_target_pos = global_position
	_target_yaw = rotation.y


func _physics_process(delta: float) -> void:
	if game == null:
		game = get_tree().get_first_node_in_group("game")
		if game == null:
			return
	if game.is_host():
		brain.think(delta)
	else:
		var k := clampf(delta * 12.0, 0.0, 1.0)
		global_position = global_position.lerp(_target_pos, k)
		rotation.y = lerp_angle(rotation.y, _target_yaw, k)
	_update_visual(delta)
	_update_sound(delta)


# =========================================================================
# movement helpers the brains use (host)
# =========================================================================

## Walk toward a target on the navigation mesh. Returns the remaining straight distance.
func nav_move(target: Vector3, move_speed: float, delta: float, face := true) -> float:
	_repath -= delta
	if _repath <= 0.0:
		_repath = 0.35
		agent.target_position = target
	var next := target
	if NavigationServer3D.map_get_iteration_id(agent.get_navigation_map()) > 0:
		# Asking for the next point is what makes the agent (re)build its path.
		var p := agent.get_next_path_position()
		if Vector2(p.x - global_position.x, p.z - global_position.z).length() > 0.05:
			next = p
	return step_toward(next, move_speed, delta, face, target)


## Move straight toward a point this frame. Returns distance left to `goal` (or the point).
func step_toward(point: Vector3, move_speed: float, delta: float, face := true, goal = null) -> float:
	var dir := point - global_position
	dir.y = 0.0
	var goal_pos: Vector3 = goal if goal is Vector3 else point
	var left := Vector2(goal_pos.x - global_position.x, goal_pos.z - global_position.z).length()
	if dir.length() < 0.05 or move_speed <= 0.0:
		stop()
		return left
	dir = dir.normalized()
	var face_to := dir
	# Pinned on a corner (door frames, furniture the nav mesh does not know about):
	# sidestep for a moment, alternating sides, then try the path again.
	if _unjam_t > 0.0:
		_unjam_t -= delta
		dir = (dir.cross(Vector3.UP) * _unjam_side + dir * 0.3).normalized()
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	velocity.y = 0.0 if is_on_floor() else velocity.y - 18.0 * delta
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	moving = moved > 0.002
	speed = moved / maxf(delta, 0.0001)
	if speed < move_speed * 0.25:
		_blocked_t += delta
		if _blocked_t > 0.4 and _unjam_t <= 0.0:
			_blocked_t = 0.0
			_unjam_side = -_unjam_side
			_unjam_t = 0.35
			_repath = 0.0
	else:
		_blocked_t = 0.0
	if face:
		face_dir(face_to, delta, 7.0)
	return left


func stop() -> void:
	moving = false
	speed = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = 0.0 if is_on_floor() else velocity.y - 0.3
	move_and_slide()


func face_dir(dir: Vector3, delta: float, rate := 6.0) -> void:
	if Vector2(dir.x, dir.z).length() < 0.001:
		return
	# Models face -Z, so yaw = atan2(-x, -z).
	var want := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, want, clampf(delta * rate, 0.0, 1.0))


## Yaw from our facing to a world point, positive when it is to our left.
func yaw_to(point: Vector3) -> float:
	var to := point - global_position
	var fwd := -global_transform.basis.z
	return atan2(fwd.cross(to).y, Vector2(fwd.x, fwd.z).dot(Vector2(to.x, to.z)))


func nearest_player(max_dist := 1e9) -> Node:
	var best: Node = null
	var bd := max_dist
	for p in game.alive_players():
		var d: float = global_position.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best


func random_nav_point(near: Vector3, min_d: float, max_d: float) -> Vector3:
	var map := agent.get_navigation_map()
	var map_ready := NavigationServer3D.map_get_iteration_id(map) > 0
	var spots: Array = game.level_info.get("monster_spawns", [])
	var fallback := near + Vector3(_rng.randf_range(-4.0, 4.0), 0.0, _rng.randf_range(-4.0, 4.0))
	for i in 12:
		var p: Vector3
		if not spots.is_empty() and _rng.randf() < 0.5:
			p = spots[_rng.randi() % spots.size()]
		elif map_ready:
			p = NavigationServer3D.map_get_random_point(map, 1, false)
		else:
			var a := _rng.randf() * TAU
			p = near + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(min_d, max_d)
		var d := p.distance_to(near)
		if d >= min_d and d <= max_d:
			return p
		if d >= min_d * 0.5:
			fallback = p
	return fallback


func clear_line(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = C.L_WORLD
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Lunge when a player is close and closing, hit on contact. Returns true on a hit attempt.
var _prev_close := 1e9
func try_contact(lunge_range: float) -> bool:
	var p := nearest_player(lunge_range + 1.0)
	if p == null:
		_prev_close = 1e9
		return false
	var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
	if d <= lunge_range and lunge_t <= 0.0 and (d < _prev_close - 0.0005 or d < lunge_range * 0.7):
		lunge_t = 0.5
	_prev_close = d
	if d < body_radius + C.PLAYER_RADIUS + 0.25:
		face_dir(p.global_position - global_position, 1.0, 1.0)
		game.monster_hit_player(self, p)
		return true
	return false


# =========================================================================
# visuals and sound (every machine)
# =========================================================================

func _update_visual(delta: float) -> void:
	var frozen := kind == NIGHT_NURSE and observed
	if not frozen:
		# A watched nurse stays frozen mid-reach; everything else plays out.
		lunge_t = maxf(0.0, lunge_t - delta)
		_lunge_amt = move_toward(_lunge_amt, 1.0 if lunge_t > 0.0 else 0.0, delta * (7.0 if lunge_t > 0.0 else 2.5))
	var listening := mode == Mode.LISTEN
	_listen_amt = move_toward(_listen_amt, 1.0 if listening else 0.0, delta * (5.0 if listening else 2.0))
	_stagger = move_toward(_stagger, 1.0 if mode == Mode.STUNNED else 0.0, delta * (6.0 if mode == Mode.STUNNED else 1.5))

	if model == null or model.shaper == null:
		return
	var sh = model.shaper
	sh.listen = _listen_amt
	sh.listen_yaw = listen_yaw
	sh.lunge = _lunge_amt
	sh.stagger = _stagger * (0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.02))

	if kind == NIGHT_NURSE:
		# One pose, frozen the instant anyone looks. It never idles, never fidgets.
		if lunge_t > 0.0:
			model.play("attack", 0.0 if observed else 1.0, 0.05)
		else:
			model.play("walk", (speed / 3.4) if (moving and not observed) else 0.0, 0.3)
		sh.twitch = Vector3.ZERO
		return

	# Twitches while it searches or stands: small, sudden, bird-like.
	_twitch_timer -= delta
	if _twitch_timer <= 0.0:
		var busy := mode == Mode.SEARCH or mode == Mode.IDLE
		_twitch_timer = _rng.randf_range(0.25, 0.7) if mode == Mode.SEARCH else _rng.randf_range(1.2, 3.5)
		_twitch = Vector3(_rng.randf_range(-0.25, 0.25), _rng.randf_range(-0.6, 0.6), _rng.randf_range(-0.3, 0.3)) * (1.0 if busy else 0.3)
	sh.twitch = sh.twitch.lerp(_twitch, clampf(delta * 18.0, 0.0, 1.0))

	if lunge_t > 0.0:
		model.play("attack", 1.2, 0.05)
	elif mode == Mode.LISTEN:
		model.play(model.current(), 0.0)
	elif mode == Mode.RUSH and moving:
		model.play("run", clampf(speed / 6.5, 0.4, 1.2), 0.15)
	elif moving:
		model.play("walk", clampf(speed / 3.6, 0.2, 1.0), 0.25)
	else:
		model.play("idle", 1.4 if mode == Mode.SEARCH else 0.7, 0.3)


func _update_sound(delta: float) -> void:
	var viewer: Node = game.viewed_player() if game.has_method("viewed_player") else null
	var near_viewer: bool = viewer == null or viewer.global_position.distance_to(global_position) < 30.0

	if mode != _last_mode:
		if mode == Mode.LISTEN and near_viewer:
			Audio.play("monsters_inhale", global_position + Vector3.UP * 1.5, -2.0, 0.08)
		_last_mode = mode
	var lunging := lunge_t > 0.0
	if lunging and not _last_lunge and near_viewer:
		Audio.play("monsters_shriek", global_position + Vector3.UP * 1.6, -3.0 if kind == DISCHARGED else -6.0, 0.1)
	_last_lunge = lunging
	var calm_now := calm > 0.0
	if calm_now and not _last_calm and mode == Mode.RETREAT:
		Audio.play("monsters_grab", global_position + Vector3.UP * 1.2, 0.0, 0.05)
	_last_calm = calm_now

	_sound_timer -= delta
	if not near_viewer:
		return
	if kind == DISCHARGED:
		# The rattle only while it walks. When it stops to listen, the silence is the tell.
		if moving and mode != Mode.LISTEN and _sound_timer <= 0.0:
			_sound_timer = clampf(0.62 - speed * 0.07, 0.24, 0.55) * _rng.randf_range(0.85, 1.15)
			Audio.play("monsters_iv_rattle", global_position + Vector3.UP * 0.2, -4.0 if speed < 2.0 else -1.0, 0.1)
	else:
		if moving and not observed:
			if _sound_timer <= 0.0:
				_sound_timer = 0.667 / (2.0 * maxf(0.3, speed / 3.4))
				Audio.play("monsters_squeak", global_position + Vector3.UP * 0.05, -3.0, 0.08)
			_lullaby_timer -= delta
			if _lullaby_timer <= 0.0 and viewer != null and viewer.global_position.distance_to(global_position) < 14.0:
				_lullaby_timer = _rng.randf_range(11.0, 20.0)
				Audio.play("monsters_lullaby", global_position + Vector3.UP * 2.0, -6.0, 0.0)


# =========================================================================
# events from the game (host)
# =========================================================================

func alert_to(pos: Vector3) -> void:
	if brain.has_method("alert_to"):
		brain.alert_to(pos)


func shoved(dir: Vector3) -> void:
	brain.shoved(dir)


func recoil_after_hit() -> void:
	brain.recoil_after_hit()


# =========================================================================
# networking
# =========================================================================

func report() -> Dictionary:
	return {
		# Quantized (1 cm, 1/128 rad; power-of-two steps stay 4-byte floats on the wire) so a monster standing still costs no snapshot delta.
		"id": monster_id, "kind": kind, "pos": global_position.snappedf(0.01), "y": snappedf(rotation.y, 1.0 / 128.0),
		"st": state, "md": mode, "mv": moving, "sp": snappedf(speed, 1.0 / 16.0),
		"ob": observed, "ly": snappedf(listen_yaw, 1.0 / 64.0), "lg": lunge_t > 0.0, "cm": calm > 0.0,
	}


func apply_remote(s: Dictionary) -> void:
	_target_pos = s.get("pos", _target_pos)
	_target_yaw = s.get("y", _target_yaw)
	state = s.get("st", state)
	mode = s.get("md", mode)
	moving = s.get("mv", moving)
	speed = s.get("sp", speed)
	observed = s.get("ob", observed)
	listen_yaw = s.get("ly", listen_yaw)
	calm = 1.0 if s.get("cm", false) else 0.0
	if s.get("lg", false) and lunge_t <= 0.0:
		lunge_t = 0.5
