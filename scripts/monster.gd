class_name Monster
extends CharacterBody3D
## Three creatures, three rules you can learn: eyes, then ears, then being watched.
##
##   The Hive     sight only; lumbers slowly after anyone it sees, forgets them fast.
##   The Discharged  eyeless; hunts by sound. Freezes to listen, ears turning, then rushes.
##   The Night Nurse moves only while nobody is looking at it with light on it.
##
## Simulated only on the host (the behaviour lives in scripts/monsters/*_brain.gd).
## Clients receive report() snapshots and animate from them, so everything the
## visual needs (mode, observed, listen direction, lunge, sedated, dragged) is in the report.
##
## Sweep 3 combat surface (host): hp, take_hit, sedate / wake, dragged_by. See
## docs/CONTRACTS.md "Monsters (sweep 3)".

enum State { WANDER, CHASE, STUNNED, SEDATED }

## What the monster is visibly doing. Replicated; drives animation and sound. Append only.
enum Mode { IDLE, WANDER, LISTEN, RUSH, SEARCH, STALK, STUNNED, RETREAT, SEDATED }

const DISCHARGED := "discharged"
const NIGHT_NURSE := "night_nurse"
const HIVE := "hive"
const KINDS := [HIVE, DISCHARGED, NIGHT_NURSE]
## The Discharged and the Night Nurse together.
const MAX_MONSTERS := 5
## Hives have their own cap.
const MAX_HIVES := 8

## A saw blow knocks it back and off balance this long.
const STAGGER_SECONDS := 0.7
## Getting up after sedation wears off, before it hunts.
const WAKE_STAGGER := 1.2

const Model := preload("res://scripts/monsters/monster_model.gd")
const DischargedBrain := preload("res://scripts/monsters/discharged_brain.gd")
const NurseBrain := preload("res://scripts/monsters/night_nurse_brain.gd")
const HiveBrain := preload("res://scripts/monsters/hive_brain.gd")
const Zones := preload("res://scripts/hospital_builder.gd")
const NurseRig := preload("res://scripts/monsters/night_nurse_rig.gd")
const HiveRig := preload("res://scripts/monsters/hive_rig.gd")
const NurseGrab := preload("res://scripts/monsters/nurse_grab.gd")

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
## Night Nurse: the peer id of the surgeon she holds by the neck (0 nobody), and how long she has held
## them. Host authoritative (report `gp`); every machine counts grab_t itself (nurse_grab.gd).
var grab_peer: int = 0
var grab_t: float = 0.0
var _grab_cracked := false
var body_radius: float = 0.38
var height: float = 1.85

## Sweep 3: fighting and capturing.
var hp: int = 4
var max_hp: int = 4
var sedation_left: float = 0.0  ## host seconds; clients only know is_sedated()
var dragged_by: int = 0         ## peer id dragging it (set by combat), 0 nobody
var hit_count: int = 0          ## bumps on every take_hit; replicated so every machine flinches

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
var _last_hits := 0
var _sound_timer := 0.0
var _lullaby_timer := 0.0
var _groan_timer := 0.0
var _breath_timer := 0.0
var _twitch_timer := 0.0
var _twitch := Vector3.ZERO
var _listen_amt := 0.0
var _lunge_amt := 0.0
var _stagger := 0.0
var _flinch := 0.0
var _lie := 0.0
var _recoil := 0.0          ## the Night Nurse model: a knock-down's recoil pose, 1 -> 0
var _walk_lift := 0.0
var _vis_calm := false
var _shape: CollisionShape3D = null
var _shape_lying := false
var _sedated_remote := false
var _rng := RandomNumberGenerator.new()


## Which monsters a shift gets.
##   The Discharged / the Night Nurse (cap MAX_MONSTERS): shift 1 is one Discharged; the Night
##   Nurse joins on shift 2; one more of each every two shifts after that; one extra Discharged
##   per two players beyond the first.
##   Hives (cap MAX_HIVES), from shift 1: 4 solo on shift 1, one more per shift and per
##   extra player. They come last in the list; game._spawn_monsters places them in groups.
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
	for w in hive_count(shift, player_count):
		out.append(HIVE)
	return out


static func hive_count(shift: int, player_count: int) -> int:
	return clampi(3 + maxi(1, shift) + maxi(0, player_count - 1), 0, MAX_HIVES)


## Can it be sedated, strapped and dissected (it has a brain)?
static func is_capturable(monster_kind: String) -> bool:
	return monster_kind == HIVE or monster_kind == DISCHARGED


static func max_hp_for(monster_kind: String) -> int:
	match monster_kind:
		HIVE: return 2
		DISCHARGED: return 4
	return 0


static func display_name(monster_kind: String) -> String:
	match monster_kind:
		HIVE: return "Hive"
		NIGHT_NURSE: return "Night Nurse"
	return "Discharged"


## A still copy lying on its back (monster_model.gd), for dissection bodies.
static func make_lying(monster_kind: String) -> Node3D:
	return Model.make_lying(monster_kind)


static func new_monster(id: int, monster_kind: String, pos: Vector3) -> CharacterBody3D:
	var m: Monster = Monster.new()
	m.monster_id = id
	m.kind = monster_kind if KINDS.has(monster_kind) else DISCHARGED
	m.name = "Monster_%d_%s" % [id, m.kind]
	m._rng.seed = hash("monster%d" % id)
	m._build()
	m.position = pos
	m._target_pos = pos
	return m


func _build() -> void:
	collision_layer = C.L_MONSTER
	collision_mask = C.L_WORLD
	match kind:
		NIGHT_NURSE:
			damage = 2
			knockback = 11.0
			body_radius = 0.34
			height = 2.3
			brain = NurseBrain.new(self)
		HIVE:
			damage = 1
			knockback = 7.0
			body_radius = 0.36
			height = 1.75
			brain = HiveBrain.new(self)
		_:
			damage = 1
			knockback = 9.0
			body_radius = 0.36
			height = 2.1
			brain = DischargedBrain.new(self)
	max_hp = max_hp_for(kind)
	hp = max_hp

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = body_radius
	capsule.height = height
	shape.shape = capsule
	shape.position.y = height * 0.5
	add_child(shape)
	_shape = shape

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
	_groan_timer = _rng.randf_range(3.0, 12.0)
	_breath_timer = _rng.randf_range(0.5, 2.0)


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
		if is_sedated():
			sedation_left -= delta
			if sedation_left <= 0.0:
				wake()
		if is_sedated():
			moving = false
			speed = 0.0
			velocity = Vector3.ZERO
		elif dragged_by == 0:
			brain.think(delta)
		if dragged_by != 0:
			_apply_pin()
	else:
		if dragged_by != 0 and _apply_pin():
			pass
		else:
			var k := clampf(delta * 12.0, 0.0, 1.0)
			if global_position.distance_squared_to(_target_pos) > 36.0:
				k = 1.0   # POCKETS HOOK: through a seam the monster jumps; never lerp it across the world
			global_position = global_position.lerp(_target_pos, k)
			rotation.y = lerp_angle(rotation.y, _target_yaw, k)
	_update_visual(delta)
	_update_sound(delta)


## Dragged: sit where combat says. Only the origin and the yaw of the pin are used; the body
## lies along the monster's local +Z from its feet (see the contract). False when combat has no pin.
func _apply_pin() -> bool:
	var c = game.get("combat") if game != null else null
	if c == null or not c.has_method("monster_pin"):
		return false
	var t: Transform3D = c.monster_pin(self)
	global_position = t.origin
	var f: Vector3 = -t.basis.z
	if Vector2(f.x, f.z).length() > 0.01:
		rotation.y = atan2(-f.x, -f.z)
	moving = false
	speed = 0.0
	return true


# =========================================================================
# fighting and capturing (host)
# =========================================================================

func can_be_hurt() -> bool:
	return kind != NIGHT_NURSE


## A blow from `source` ("saw:<player name>", "dev", ...) travelling along `dir`.
## Returns "stagger" (a short stun, knocked back), "killed" (hp reached 0: the CALLER then calls
## game.kill_monster(m)) or "immune" (the Night Nurse; nothing happens).
func take_hit(dir: Vector3, amount: int, _source: String) -> String:
	if not can_be_hurt():
		return "immune"
	hp = maxi(0, hp - maxi(0, amount))
	hit_count = (hit_count + 1) % 64
	if hp <= 0:
		return "killed"
	if is_sedated():
		return "stagger"   # out cold: it takes the blow lying down
	var from: Vector3 = global_position - dir.normalized() * 1.5 if dir.length() > 0.01 else global_position
	var attacker: Node = nearest_player(3.5)
	if attacker != null:
		from = attacker.global_position
	if brain.has_method("stun"):
		brain.stun(dir, STAGGER_SECONDS, 0.45, from)
	lunge_t = 0.0
	return "stagger"


## Stunned right now (the shove window) and it has a brain worth taking.
func can_sedate() -> bool:
	return is_capturable(kind) and not is_sedated() and mode == Mode.STUNNED


## Host: falls down and lies still; the brain stops. Wakes when `seconds` run out.
func sedate(seconds: float) -> bool:
	if not is_capturable(kind) or is_sedated() or seconds <= 0.0:
		return false
	sedation_left = seconds
	mode = Mode.SEDATED
	state = State.SEDATED
	lunge_t = 0.0
	calm = 0.0
	listen_yaw = 0.0
	moving = false
	speed = 0.0
	velocity = Vector3.ZERO
	if is_inside_tree():
		rotation.y = _lying_yaw()
	if brain.has_method("sedated"):
		brain.sedated()
	return true


## The facing closest to the current one that leaves room to lie down (the body runs half its
## height each way along the facing axis), so it never falls into a wall.
func _lying_yaw() -> float:
	var space := get_world_3d().direct_space_state
	var half := height * 0.5 + 0.15
	var from := global_position + Vector3.UP * 0.35
	var best := rotation.y
	var best_room := -1.0
	for i in 12:
		var step := (i + 1) / 2 * (1 if i % 2 == 0 else -1)   # 0, +1, -1, +2, -2 ...
		var yaw := rotation.y + step * TAU / 12.0
		var axis := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var room := INF
		for sgn in [1.0, -1.0]:
			var q := PhysicsRayQueryParameters3D.create(from, from + axis * sgn * half)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			room = minf(room, half if hit.is_empty() else from.distance_to(hit.position))
		if room >= half - 0.001:
			return yaw
		if room > best_room:
			best_room = room
			best = yaw
	return best


func is_sedated() -> bool:
	if game != null and not game.is_host():
		return _sedated_remote
	return mode == Mode.SEDATED


## Host: gets up staggering, then hunts the nearest player. If someone was dragging it, it is
## dropped (combat.drop_dragged) and lashes out at them.
func wake() -> void:
	if mode != Mode.SEDATED:
		return
	sedation_left = 0.0
	var dragger: Node = null
	if dragged_by != 0 and game != null:
		dragger = game.players.get(dragged_by) if "players" in game else null
		var c = game.get("combat")
		if dragger != null and c != null and c.has_method("drop_dragged"):
			c.drop_dragged(dragger)
		dragged_by = 0
	var target: Node = dragger if dragger != null else nearest_player(40.0)
	var hunt = target.global_position if target != null else null
	if brain.has_method("woke"):
		brain.woke(hunt)
	else:
		mode = Mode.STUNNED
		state = State.STUNNED
	if dragger != null and is_instance_valid(dragger) and dragger.global_position.distance_to(global_position) < 3.0 \
			and game.has_method("monster_hit_player"):
		game.monster_hit_player(self, dragger)


## Every machine: where its eyes are and which way they look (-Z forward), following the
## animated head (for a camera riding a Hive). Falls back to a fixed height on the body.
func eye_transform() -> Transform3D:
	var head: Node3D = model.find_child("Head", true, false) as Node3D if model != null else null
	if head != null and head.is_inside_tree():
		# Head attachments face +Z; the eyes sit about 13 cm up and 9 cm forward of the neck bone.
		var hb := head.global_transform.basis.orthonormalized()
		var eo: Vector3 = model.eye_offset() if model.has_method("eye_offset") else Vector3(0.0, 0.13, 0.1)
		var origin := head.global_transform.origin + hb.x * eo.x + hb.y * eo.y + hb.z * eo.z
		return Transform3D(Basis(-hb.x, hb.y, -hb.z), origin)
	var eye_h := 1.5 if kind == HIVE else height - 0.25
	return Transform3D(global_transform.basis.orthonormalized(), global_position + Vector3.UP * eye_h)


# =========================================================================
# movement helpers the brains use (host)
# =========================================================================

## Walk toward a target on the navigation mesh. Returns the remaining straight distance.
func nav_move(target: Vector3, move_speed: float, delta: float, face := true) -> float:
	# POCKETS HOOK: a target standing in the unwalked half of an entrance stub is really in the other
	# copy; a path through a seam link continues on the far side of the world, so steer across the
	# seam here and let the crossing move the monster (scripts/level/pockets/pocket_spaces.gd).
	var pk = game.get("pockets") if game != null else null
	if pk != null and pk.active():
		target = pk.real_point(target)
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
	if pk != null and pk.active():
		next = pk.steer_point(global_position, next)
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
	if game == null:
		return null
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
		# LOOP HOOK: no wandering into the entrance building or the neutral area (noise still draws them).
		if game != null and game.has_method("monster_may_wander_to") and not game.monster_may_wander_to(p):
			continue
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
		if kind == NIGHT_NURSE and game.has_method("nurse_grab"):
			game.nurse_grab(self, p)   # she never hits: she takes hold (nurse_grab.gd)
		else:
			game.monster_hit_player(self, p)
		return true
	return false


## Host (game.nurse_grab): she has `p` by the neck. Snaps round to face them; stands still.
func start_grab(p: Node) -> void:
	grab_peer = int(p.peer_id)
	grab_t = 0.0
	_grab_cracked = false
	lunge_t = 0.0
	stop()
	face_dir(p.global_position - global_position, 1.0, 1.0)


func end_grab() -> void:
	grab_peer = 0
	grab_t = 0.0


## Where the surgeon she holds hangs (every machine; game.pinned_pose): by the neck from her grip,
## facing her, carried up off the spot they were taken from over NurseGrab.LIFT.
func grab_victim_pose(p: Node) -> Transform3D:
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
	var grip := Vector3.ZERO
	if model != null and model.get("nurse") != null:
		grip = model.nurse.grip_world
	if grip == Vector3.ZERO:
		grip = global_position + fwd * 0.85 + Vector3.UP * 1.95   # no posed model (fallback rig, headless)
	var hang := grip + fwd * NurseRig.NECK_DEPTH - Vector3.UP * (C.EYE_H - NurseGrab.NECK_BELOW_EYES)
	var o: Vector3 = (p.held_from as Vector3).lerp(hang, NurseGrab.lift(grab_t))
	return Transform3D(Basis(Vector3.UP, rotation.y + PI), o)


# =========================================================================
# spawn placement (host; game._spawn_monsters)
# =========================================================================

## Where `count` Hives stand: small groups (2-3) on hallway tiles of the shallowest part of
## each wing (nearest the entrance building), never in the entrance building, the neutral area
## or a room. Without hospital data (the dev room, the lab) they group around monster_spawns.
## `space` (optional) rejects spots blocked by furniture.
static func hive_spots(info: Dictionary, count: int, rng: RandomNumberGenerator, space: PhysicsDirectSpaceState3D = null) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if count <= 0:
		return out
	var by_wing := _hive_candidates(info, space)
	var wings: Array = by_wing.keys()
	if wings.is_empty():
		var spawns: Array = info.get("monster_spawns", [])
		for i in count:
			var base: Vector3 = spawns[(i / 2) % spawns.size()] if not spawns.is_empty() else Vector3.ZERO
			out.append(base + Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8)))
		return out
	wings.sort()
	for i in range(wings.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = wings[i]
		wings[i] = wings[j]
		wings[j] = tmp
	# Groups of 2-3, one per wing while there are wings to spare.
	var groups := clampi(maxi(ceili(count / 3.0), mini(wings.size(), count / 2)), 1, wings.size())
	var sizes: Array[int] = []
	for g in groups:
		sizes.append(count / groups + (1 if g < count % groups else 0))
	for g in groups:
		var cands: Array = by_wing[wings[g]]   # [{pos, d}], sorted shallow first
		var shallow: Array = cands.filter(func(c): return float(c.d) <= float(cands[0].d) + SHALLOW_BAND)
		var centre: Vector3 = shallow[rng.randi() % shallow.size()].pos
		var near: Array = cands.filter(func(c): return (c.pos as Vector3).distance_to(centre) <= GROUP_RADIUS)
		var picked: Array[Vector3] = [centre]
		var tries := 0
		while picked.size() < sizes[g] and tries < 40:
			tries += 1
			var c: Vector3 = near[rng.randi() % near.size()].pos
			var ok := true
			for q in picked:
				if q.distance_to(c) < 1.2:
					ok = false
					break
			if ok:
				picked.append(c)
		while picked.size() < sizes[g]:
			picked.append(centre + Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6)))
		out.append_array(picked)
	return out


const MIN_ENTRANCE_DIST := 5.0   ## metres inside the wing, past its doorway
const SHALLOW_BAND := 12.0       ## the "shallow part": within this of the wing's nearest hallway tile
const GROUP_RADIUS := 3.5


## wing id -> [{pos, d}] hallway tiles sorted by distance to the entrance building.
static func _hive_candidates(info: Dictionary, space: PhysicsDirectSpaceState3D) -> Dictionary:
	var out := {}
	var rows: PackedStringArray = info.get("rows", PackedStringArray())
	var wings: Array = info.get("wings", [])
	if rows.is_empty() or wings.is_empty() or not info.has("zones") or not info.has("entrance_rect"):
		return out
	var h := rows.size()
	var w := rows[0].length()
	var in_room := PackedByteArray()
	in_room.resize(w * h)
	for r in info.get("rooms", []):
		var t: Rect2i = r.get("tiles", Rect2i())
		for y in range(maxi(0, t.position.y - 1), mini(h, t.end.y + 1)):
			for x in range(maxi(0, t.position.x - 1), mini(w, t.end.x + 1)):
				in_room[y * w + x] = 1
	var ent: Rect2 = info.entrance_rect
	var neutral: Rect2 = info.get("neutral_rect", Rect2())
	for wd in wings:
		var id := String(wd.get("id", ""))
		var tr: Rect2i = wd.get("tile_rect", Rect2i())
		var list: Array = []
		for y in range(maxi(1, tr.position.y), mini(h - 1, tr.end.y)):
			var row := rows[y]
			for x in range(maxi(1, tr.position.x), mini(w - 1, tr.end.x)):
				var ch := row[x]
				if (ch != "." and ch != "M") or in_room[y * w + x] == 1:
					continue
				# Not in a doorway's mouth.
				if rows[y - 1][x] == "+" or rows[y + 1][x] == "+" or row[x - 1] == "+" or row[x + 1] == "+":
					continue
				var p := C.tile_to_world(x, y)
				if Zones.zone_of(info, p) != id or neutral.has_point(Vector2(p.x, p.z)):
					continue
				var d := _rect_dist(ent, Vector2(p.x, p.z))
				if d < MIN_ENTRANCE_DIST:
					continue
				list.append({"pos": p, "d": d})
		if list.is_empty():
			continue
		list.sort_custom(func(a, b): return float(a.d) < float(b.d))
		if space != null:
			# Only the shallow end needs checking; furniture blocks some hallway tiles.
			var band := float(list[0].d) + SHALLOW_BAND + GROUP_RADIUS
			list = list.filter(func(c): return float(c.d) > band or _spot_clear(space, c.pos))
			if list.is_empty():
				continue
		out[id] = list
	return out


static func _rect_dist(r: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dy := maxf(maxf(r.position.y - p.y, 0.0), p.y - r.end.y)
	return Vector2(dx, dy).length()


static func _spot_clear(space: PhysicsDirectSpaceState3D, p: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.35
	q.shape = s
	q.transform = Transform3D(Basis(), p + Vector3.UP * 0.5)
	q.collision_mask = C.L_WORLD
	return space.intersect_shape(q, 1).is_empty()


# =========================================================================
# visuals and sound (every machine)
# =========================================================================

func _update_visual(delta: float) -> void:
	var frozen := kind == NIGHT_NURSE and observed and grab_peer == 0
	if grab_peer != 0:
		grab_t += delta
	if not frozen:
		# A watched nurse stays frozen mid-reach; everything else plays out.
		lunge_t = maxf(0.0, lunge_t - delta)
		_lunge_amt = move_toward(_lunge_amt, 1.0 if lunge_t > 0.0 else 0.0, delta * (7.0 if lunge_t > 0.0 else 2.5))
	var listening := mode == Mode.LISTEN
	_listen_amt = move_toward(_listen_amt, 1.0 if listening else 0.0, delta * (5.0 if listening else 2.0))
	_stagger = move_toward(_stagger, 1.0 if mode == Mode.STUNNED else 0.0, delta * (6.0 if mode == Mode.STUNNED else 1.5))
	_flinch = maxf(0.0, _flinch - delta * 3.0)
	if hit_count != _last_hits:
		_flinch = 1.0
	var lying := mode == Mode.SEDATED
	if lying != _shape_lying and _shape != null:
		# The capsule lies down with the body (along local Z, centred), so aim and hits find it.
		_shape_lying = lying
		var r: float = (_shape.shape as CapsuleShape3D).radius
		_shape.rotation.x = PI * 0.5 if lying else 0.0
		_shape.position = Vector3(0.0, r if lying else height * 0.5, 0.0)
	_lie = move_toward(_lie, 1.0 if lying else 0.0, delta * (2.2 if lying else 1.4))

	if model == null:
		return
	if model.nurse != null:
		_nurse_visual(delta)
		return
	# Lying down: the whole model tips over backwards, face up, and settles centred on the
	# monster's origin (head toward local +Z) so it is no longer than it needs to be either way.
	var e := _lie * _lie * (3.0 - 2.0 * _lie)
	model.rotation.x = e * PI * 0.5
	model.position = Vector3(0.0, e * 0.13, -e * height * 0.47)
	if model.shaper == null:
		return
	var sh = model.shaper
	sh.lying = e
	sh.listen = _listen_amt * (1.0 - e)
	sh.listen_yaw = listen_yaw
	sh.lunge = _lunge_amt * (1.0 - e)
	sh.stagger = maxf(_stagger * (0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.02)), _flinch) * (1.0 - e)
	# HANDS HOOK (scripts/combat/stun_window.gd): the shove's stun window, down hard then a twitching rise.
	var cbt = game.get("combat") if game != null else null
	if cbt != null and cbt.has_method("stun_pose"):
		cbt.stun_pose(self, sh, e)
	if model.has_method("set_ears"):
		model.set_ears(_listen_amt, listen_yaw, delta)

	if kind == NIGHT_NURSE:
		# One pose, frozen the instant anyone looks. It never idles, never fidgets.
		if lunge_t > 0.0:
			model.play("attack", 0.0 if observed else 1.0, 0.05)
		else:
			model.play("walk", (speed / 3.4) if (moving and not observed) else 0.0, 0.3)
		sh.twitch = Vector3.ZERO
		return

	if e > 0.0:
		# Out cold: a slow idle that reads as shallow breathing.
		model.play("idle", 0.25, 0.4)
		if model.hive != null:
			model.hive.lock = 0.0
		sh.twitch = sh.twitch.lerp(Vector3.ZERO, clampf(delta * 6.0, 0.0, 1.0))
		return

	if kind == HIVE:
		# Sluggish head lolls; it looks around slowly while it searches.
		_twitch_timer -= delta
		if _twitch_timer <= 0.0:
			_twitch_timer = _rng.randf_range(1.0, 2.2) if mode == Mode.SEARCH else _rng.randf_range(2.5, 5.0)
			_twitch = Vector3(_rng.randf_range(-0.15, 0.2), _rng.randf_range(-0.7, 0.7) if mode == Mode.SEARCH else _rng.randf_range(-0.25, 0.25), _rng.randf_range(-0.2, 0.2))
		if model.hive != null:
			_hive_visual(delta)
			return
		# When it has seen someone the head comes up and stays on them.
		var want := _twitch + (Vector3(-0.3, -_twitch.y * 0.8, -_twitch.z * 0.5) if mode == Mode.RUSH else Vector3.ZERO)
		sh.twitch = sh.twitch.lerp(want, clampf(delta * 2.5, 0.0, 1.0))
		if lunge_t > 0.0:
			model.play("attack", 0.8, 0.1)
		elif moving:
			model.play("walk", clampf(speed / 2.6, 0.22, 0.75), 0.35)
		else:
			model.play("idle", 0.45, 0.4)
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


## The Hive's own model (monster/hive, hive_rig.gd): which clip and how fast, the idle head lolling,
## and the lock-on: once it has seen someone (RUSH) the head comes up out of its hang to look at them
## and its eyes light up fully; losing them, it lets the head sink back and the eyes dim to a point.
## Every machine: the look target is whoever is nearest in front of it, so clients need no extra state.
func _hive_visual(delta: float) -> void:
	var hv = model.hive
	var locked := mode == Mode.RUSH
	hv.lock = move_toward(hv.lock, 1.0 if locked else 0.0, delta * (3.0 if locked else 0.8))
	if locked or hv.lock > 0.0:
		var t := _hive_look_target()
		if t != Vector3.INF:
			hv.look_target = t if hv.lock < 0.05 else hv.look_target.lerp(t, clampf(delta * 8.0, 0.0, 1.0))
		elif not locked:
			hv.lock = 0.0
	_twitch_timer -= delta
	if _twitch_timer <= 0.0:
		_twitch_timer = _rng.randf_range(1.0, 2.2) if mode == Mode.SEARCH else _rng.randf_range(2.5, 5.0)
		_twitch = Vector3(_rng.randf_range(-0.1, 0.15), _rng.randf_range(-0.6, 0.6) if mode == Mode.SEARCH else _rng.randf_range(-0.2, 0.2), _rng.randf_range(-0.15, 0.15))
	hv.twitch = hv.twitch.lerp(_twitch, clampf(delta * 2.5, 0.0, 1.0))
	if lunge_t > 0.0:
		model.play("attack", 1.0, 0.08)
	elif moving:
		model.play("walk", clampf(speed / HiveRig.WALK_SPEED, 0.4, 2.4), 0.3)
	else:
		model.play("idle", 1.0, 0.4)


## The player the Hive's head turns to: the nearest living one within sight range in front of it,
## aimed at their eyes. Vector3.INF when there is nobody.
func _hive_look_target() -> Vector3:
	if game == null or not ("players" in game):
		return Vector3.INF
	var best := Vector3.INF
	var best_d := 14.0
	var fwd := -global_transform.basis.z
	for p in (game.players as Dictionary).values():
		if p == null or not is_instance_valid(p) or not (p is Node3D):
			continue
		if "downed" in p and bool(p.downed):
			continue
		var eye: Vector3 = (p as Node3D).global_position + Vector3.UP * 1.6
		var to := eye - global_position
		var d := to.length()
		if d < best_d and Vector3(to.x, 0.0, to.z).normalized().dot(fwd) > -0.2:
			best_d = d
			best = eye
	return best


## The Night Nurse's own model (monster/night_nurse): which clip, how fast, and the procedural poses.
##   watched      the clip stops on the frame it is on (speed_scale 0) and every pose holds
##   moving       Walk, played at speed / WALK_SPEED so the planted foot keeps pace with the ground
##   lunging      Walk plus both arms reaching (poser `lunge`)
##   knocked down calm starts outside a retreat: thrown back (poser `recoil`), then the Frozen pose
##                while it stands down
##   standing     Idle (stalking in the dark, waiting, calm after a retreat)
## She never lies down: she cannot be sedated, and a kill is the dev room's corpse (dev_gun.gd).
func _nurse_visual(delta: float) -> void:
	var nr = model.nurse
	if grab_peer != 0:
		# The grab (nurse_grab.gd): the clip stops dead and every bit of motion is the pose; being
		# watched changes nothing now.
		model.play(model.current() if model.current() != "" else "idle", 0.0)
		_recoil = 0.0
		nr.recoil = 0.0
		nr.lunge = 0.0
		nr.grab = NurseGrab.reach(grab_t)
		nr.cock = NurseGrab.cock(grab_t)
		return
	nr.grab = 0.0
	nr.cock = 0.0
	var calm_now := calm > 0.0
	if observed:
		model.play(model.current(), 0.0)
		_vis_calm = calm_now
		return
	if calm_now and not _vis_calm and mode != Mode.RETREAT:
		_recoil = 1.0
	_vis_calm = calm_now
	_recoil = maxf(0.0, _recoil - delta * 1.6)
	nr.recoil = _recoil * _recoil * (3.0 - 2.0 * _recoil)
	nr.lunge = _lunge_amt
	var walking := moving or lunge_t > 0.0
	if walking:
		model.play("walk", clampf(maxf(speed, 0.6) / NurseRig.WALK_SPEED, 0.3, 4.0), 0.2)
	elif calm_now and mode != Mode.RETREAT:
		model.play("frozen", 1.0, 0.15)
	else:
		model.play("idle", 1.0, 0.35)
	_walk_lift = move_toward(_walk_lift, 1.0 if walking else 0.0, delta * 4.0)
	if model.rig != null:
		model.rig.position.y = NurseRig.WALK_LIFT * _walk_lift


## Dev room settings for the Night Nurse (dev_room.gd `nurse_settings()`): {ignore_watch, walk
## ("" | "follow" | "loop"), who, loop: Array of Vector3, speed}. Empty outside the dev room.
func dev_nurse() -> Dictionary:
	if game == null or not game.has_method("dev_on") or not game.dev_on():
		return {}
	var dv = game.get("dev")
	if dv == null or not dv.has_method("nurse_settings"):
		return {}
	return dv.nurse_settings()


func _update_sound(delta: float) -> void:
	var viewer: Node = game.viewed_player() if game.has_method("viewed_player") else null
	var near_viewer: bool = viewer == null or viewer.global_position.distance_to(global_position) < 30.0

	if hit_count != _last_hits:
		_last_hits = hit_count
		if near_viewer:
			Audio.play("monsters_flesh_hit", global_position + Vector3.UP * 1.2, -1.0, 0.1)
	if mode != _last_mode:
		if mode == Mode.LISTEN and near_viewer:
			Audio.play("monsters_inhale", global_position + Vector3.UP * 1.5, -2.0, 0.08)
		elif kind == HIVE and mode == Mode.RUSH and _last_mode != Mode.RUSH and near_viewer:
			# It has seen you: the groan is the tell.
			Audio.play("monsters_hive_groan", global_position + Vector3.UP * 1.5, 0.0, 0.1)
			_groan_timer = _rng.randf_range(6.0, 11.0)
		_last_mode = mode
	var lunging := lunge_t > 0.0
	if lunging and not _last_lunge and near_viewer:
		if kind == HIVE:
			Audio.play("monsters_hive_groan", global_position + Vector3.UP * 1.5, 2.0, 0.15)
		else:
			Audio.play("monsters_shriek", global_position + Vector3.UP * 1.6, -3.0 if kind == DISCHARGED else -6.0, 0.1)
	_last_lunge = lunging
	var calm_now := calm > 0.0
	if calm_now and not _last_calm and mode == Mode.RETREAT:
		Audio.play("monsters_grab", global_position + Vector3.UP * 1.2, 0.0, 0.05)
	_last_calm = calm_now
	if grab_peer != 0 and not _grab_cracked and grab_t >= NurseGrab.SNAP_AT:
		# Her head snapping over: a crack, right in the held surgeon's face.
		_grab_cracked = true
		Audio.play("dissection_crack", eye_transform().origin, 3.0, 0.05)

	_sound_timer -= delta
	if not near_viewer:
		return
	if mode == Mode.SEDATED:
		_breath_timer -= delta
		if _breath_timer <= 0.0 and viewer != null and viewer.global_position.distance_to(global_position) < 12.0:
			_breath_timer = _rng.randf_range(3.2, 4.4)
			Audio.play("monsters_sedated_breath", global_position + Vector3.UP * 0.3, -8.0, 0.1)
		return
	if kind == HIVE:
		if moving and _sound_timer <= 0.0:
			# One dragging step per footfall; slow feet, slow shuffle.
			_sound_timer = clampf(1.05 - speed * 0.25, 0.5, 0.95) * _rng.randf_range(0.9, 1.1)
			Audio.play("monsters_hive_shuffle", global_position + Vector3.UP * 0.05, -7.0, 0.1)
		_groan_timer -= delta
		if _groan_timer <= 0.0:
			_groan_timer = _rng.randf_range(9.0, 20.0)
			if viewer == null or viewer.global_position.distance_to(global_position) < 18.0:
				Audio.play("monsters_hive_groan", global_position + Vector3.UP * 1.5, -7.0, 0.12)
	elif kind == DISCHARGED:
		# The rattle only while it walks. When it stops to listen, the silence is the tell.
		if moving and mode != Mode.LISTEN and _sound_timer <= 0.0:
			_sound_timer = clampf(0.62 - speed * 0.07, 0.24, 0.55) * _rng.randf_range(0.85, 1.15)
			Audio.play("monsters_iv_rattle", global_position + Vector3.UP * 0.2, -4.0 if speed < 2.0 else -1.0, 0.1)
	else:
		if moving and not observed:
			if _sound_timer <= 0.0:
				# One squeak per footfall of the Walk clip (two steps per 1.6 s at WALK_SPEED).
				_sound_timer = 0.8 * NurseRig.WALK_SPEED / maxf(0.3, speed)
				Audio.play("monsters_squeak", global_position + Vector3.UP * 0.05, -3.0, 0.08)
			_lullaby_timer -= delta
			if _lullaby_timer <= 0.0 and viewer != null and viewer.global_position.distance_to(global_position) < 14.0:
				_lullaby_timer = _rng.randf_range(11.0, 20.0)
				Audio.play("monsters_lullaby", global_position + Vector3.UP * 2.0, -6.0, 0.0)


# =========================================================================
# events from the game (host)
# =========================================================================

func alert_to(pos: Vector3) -> void:
	if is_sedated():
		return
	if brain.has_method("alert_to"):
		brain.alert_to(pos)


## HANDS HOOK: `charge` 0..1 is how long the shove was charged (scripts/combat/windup.gd); a charged
## shove stuns a capturable monster longer (Windup.stun_for) and pushes it further. -1: the plain shove.
func shoved(dir: Vector3, charge := -1.0) -> void:
	if is_sedated():
		return
	if charge > 0.0 and is_capturable(kind) and brain.has_method("stun"):
		brain.stun(dir, lerpf(2.0, 3.5, clampf(charge, 0.0, 1.0)), lerpf(1.05, 1.9, clampf(charge, 0.0, 1.0)))
		return
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
		# Sweep 3: sedated flag, who drags it, hit counter (flinch + sound on every machine).
		"sd": mode == Mode.SEDATED, "db": dragged_by, "hc": hit_count,
		"gp": grab_peer,   # the Night Nurse's grab: who she holds
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
	_sedated_remote = bool(s.get("sd", false))
	if _sedated_remote:
		mode = Mode.SEDATED
	dragged_by = int(s.get("db", 0))
	hit_count = int(s.get("hc", hit_count))
	var gp := int(s.get("gp", 0))
	if gp != grab_peer:
		grab_peer = gp
		grab_t = 0.0
		_grab_cracked = false
