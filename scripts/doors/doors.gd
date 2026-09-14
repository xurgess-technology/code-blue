extends Node
## Every door of the level: who opens what, the wing gates' locks, jams, sounds and noise,
## replication, and what doors do to sound. `game.doors`, child "Doors" of Game on every machine.
## The door nodes themselves (scripts/doors/door.gd) are built with the level (HospitalBuilder, the
## dev room) and registered here; the host decides, clients follow the replicated amounts.
##
## Who opens doors (host):
##   automatic (gates, the OR, the main entrance)  anyone close in front: players (downed and
##       carrying included), paramedic crews, monsters. A locked gate opens for nobody.
##   hinged (E)  players press E: it swings away from them (into the tunnel when the other side has
##       no room) and stays where it is left. Bots, and players carrying someone or dragging a
##       monster (E is taken), push it open by walking into it. The Walk-In pushes it open slowly,
##       the Discharged bursts through when it rushes (a slam), otherwise opens it with a creak, the
##       Night Nurse opens it silently and only while nobody is looking at her or at the door.
##   Doors never close by themselves except the automatic ones.
##
## Noise the Discharged hears: opening 0.25, a creaking push 0.5, a slam 0.95, a heavy gate 0.35.
## Sound through a closed door: `sound_factor(from, to)` (0.55 per closed door on the line).

const Plan := preload("res://scripts/level/door_plan.gd")
const DoorScript := preload("res://scripts/doors/door.gd")
const M := preload("res://scripts/monsters/modes.gd")
const Percept := preload("res://scripts/perception.gd")

const CELL := 6.0
const SENSOR_RANGE := 3.4
const SENSOR_SIDE := 1.3
const SENSOR_HOLD := 1.2
const CREW_SENSOR_RANGE := 4.6
## Hinged doors: how close in front (along the door's normal) an agent pushes, and to the side.
const PUSH_RANGE := 2.2
const PUSH_SIDE := 0.3
const CARRIER_RANGE := 1.4
const OUT_MIN_DEG := 80.0

const SPEED_OPEN := 1.9
const SPEED_CLOSE := 1.6
const SPEED_SLAM := 5.5
const SPEED_WALK_IN := 0.42
const SPEED_BURST := 7.0
const SPEED_NURSE := 2.2
const SPEED_AUTO_OPEN := 1.5
const SPEED_AUTO_CLOSE := 0.9
const SPEED_SLIDE_OPEN := 1.7
const SPEED_SLIDE_CLOSE := 1.1
const CLIENT_SPEED := 3.2

const NOISE_OPEN := 0.25
const NOISE_CREAK := 0.5
const NOISE_SLAM := 0.95
const NOISE_GATE := 0.35
const DOOR_SOUND_FACTOR := 0.55

const JAM_CHANCE := 0.3
const JAM_AMOUNT := 0.55
const JAM_SECONDS := Vector2(1.6, 3.4)
const JAM_COOLDOWN := Vector2(45.0, 90.0)
const UNLOCK_HOLD := 2.6

var game: Node = null
var doors := {}             # id -> door node
var _grid := {}             # Vector2i cell -> Array of door nodes
var _tile_door := {}        # Vector2i tile -> door node
var _moving := {}           # id -> door node
var gates_locked := true
## True while the wings are still being rebuilt and someone has clocked in (amber lamps).
var unlocking := false
## Tests: bots and carriers push hinged doors open by walking into them.
var agents_open_doors := true
## Tests: pin the jam roll (-1: random, 0: never, 1: always).
var force_jam := -1
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _locked_sound_at := {}
var _hold_open := {}        # id -> seconds a gate stays open after unlocking
var _cl_locked := true
var _applied_once := {}
## Counters for tests: opens by who ("player", "bot", "walk_in", "discharged", "night_nurse",
## "crew", "auto"), slams, jams.
var stats := {}


func setup(g: Node) -> void:
	game = g
	_rng.seed = 90210


## Forget every door (a new level).
func clear() -> void:
	doors.clear()
	_grid.clear()
	_tile_door.clear()
	_moving.clear()
	_hold_open.clear()
	_applied_once.clear()
	stats.clear()


## Add doors that were just built (the whole level, or a fresh set of wings).
func register(nodes: Array) -> void:
	for n in nodes:
		if n == null or not is_instance_valid(n):
			continue
		doors[n.door_id] = n
		for t in n.data.get("tiles", []):
			_tile_door[t] = n
		var c := _cell(n.global_position if n.is_inside_tree() else n.transform.origin)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var k := c + Vector2i(dx, dy)
				if not _grid.has(k):
					_grid[k] = []
				(_grid[k] as Array).append(n)
		if n.kind == "gate":
			n.locked = gates_locked
			n.set_lamp("locked" if gates_locked else "open")


## Drop every door that is not part of the entrance building (the wings are being torn down).
func unregister_wings() -> void:
	for id in doors.keys():
		var n = doors[id]
		if n == null or not is_instance_valid(n) or not bool(n.data.get("base", false)):
			doors.erase(id)
			_moving.erase(id)
			_applied_once.erase(id)
	var keep := doors.values()
	_grid.clear()
	_tile_door.clear()
	register(keep)


func _cell(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))


func near(p: Vector3) -> Array:
	return _grid.get(_cell(p), [])


func door_at_tile(t: Vector2i) -> Node:
	return _tile_door.get(t)


func _count(what: String) -> void:
	stats[what] = int(stats.get(what, 0)) + 1


# =========================================================================
# frame
# =========================================================================

func physics_tick(delta: float) -> void:
	if game == null or doors.is_empty():
		return
	_t += delta
	if game.is_host():
		_host_tick(delta)
	for id in _moving.keys():
		var d = _moving[id]
		if d == null or not is_instance_valid(d):
			_moving.erase(id)
			continue
		# A door stopped by someone standing in its way stays on the list and tries again.
		if not d.step(delta, game.is_host()) and not d.halted:
			_moving.erase(id)
			if d.kind == "gate" and d.is_closed():
				d.set_meta("jam_rolled", false)


func _drive(d: Node, target: float, speed: float, opener: Node = null) -> void:
	if is_equal_approx(d.target, target) and is_equal_approx(d.speed, speed) and not d.halted:
		return
	d.target = target
	d.speed = speed
	d.halted = false
	d.opener = opener
	_moving[d.door_id] = d


func _host_tick(delta: float) -> void:
	var want_locked: bool = not game.dev_mode and (game.phase != game.Phase.SHIFT or not _wings_ready())
	if want_locked != gates_locked:
		set_gates_locked(want_locked, true)
	unlocking = want_locked and game.phase == game.Phase.LOBBY and bool(game.get("clock_in_pending"))
	var agents := _agents()
	for id in doors.keys():
		var d = doors[id]
		if d == null or not is_instance_valid(d):
			doors.erase(id)
			continue
		if d.kind == "gate":
			d.set_lamp("unlocking" if (unlocking and int(_t * 3.0) % 2 == 0) else ("locked" if d.locked else "open"))
		if d.is_automatic():
			_auto_tick(d, agents, delta)
	for a in agents:
		if a.kind == "crew" or a.kind == "auto":
			continue
		for d in near(a.pos):
			if d.is_hinged():
				_push_check(d, a)


func _wings_ready() -> bool:
	var wl = game.get("wing_loader")
	return wl == null or wl.wings_ready


## Everyone who can open a door this tick: {kind, pos, fwd, node, strength}.
func _agents() -> Array:
	var out: Array = []
	for p in game.players.values():
		if p == null or not is_instance_valid(p) or not p.alive:
			continue
		var kind := "player"
		if bool(p.get("is_bot")) or bool(p.get("bot_active")):
			kind = "bot"
		if int(p.get("carrying")) != 0 or int(p.get("dragging_monster")) >= 0:
			kind = "carrier" if kind == "player" else kind
		out.append({"kind": kind, "pos": p.global_position, "fwd": -p.global_transform.basis.z, "node": p})
	for m in game.monsters.values():
		if m == null or not is_instance_valid(m):
			continue
		if (m.has_method("is_sedated") and m.is_sedated()) or int(m.dragged_by) != 0:
			continue
		out.append({"kind": String(m.kind), "pos": m.global_position, "fwd": -m.global_transform.basis.z, "node": m})
	if game.loop != null:
		for cr in game.loop.crews.values():
			var yaw := float(cr.get("y", 0.0))
			out.append({"kind": "crew", "pos": cr.p, "fwd": Vector3(-sin(yaw), 0.0, -cos(yaw)), "node": null})
	return out


## Automatic doors: open while someone is close in front of either face; close a moment after.
func _auto_tick(d: Node, agents: Array, delta: float) -> void:
	if d.locked:
		d.jam_t = 0.0
		if d.target != 0.0 or not d.is_closed():
			_drive(d, 0.0, SPEED_AUTO_CLOSE)
		return
	var inv: Transform3D = d.global_transform.affine_inverse()
	var sensed := false
	var nearest_z := INF
	for a in agents:
		var lp: Vector3 = inv * (a.pos as Vector3)
		var reach := CREW_SENSOR_RANGE if a.kind == "crew" else SENSOR_RANGE
		if absf(lp.z) <= reach and absf(lp.x) <= d.width * 0.5 + SENSOR_SIDE:
			sensed = true
			if absf(lp.z) < absf(nearest_z):
				nearest_z = lp.z
	# A closed pair picks its way: away from whoever is nearest, into the tunnel unless they are
	# coming through it and there is room to swing out.
	if sensed and d.is_closed() and d.target <= 0.0 and d.kind != "sliding":
		d.swing = 1 if (nearest_z < 0.0 and d.can_swing_out()) else -1
	var hold := float(_hold_open.get(d.door_id, 0.0))
	if hold > 0.0:
		_hold_open[d.door_id] = hold - delta
		sensed = true
		d.set_meta("jam_rolled", true)   # the gates never stick on the way open at clock-in
	d.jam_cooldown = maxf(0.0, d.jam_cooldown - delta)
	var open_speed := SPEED_SLIDE_OPEN if d.kind == "sliding" else SPEED_AUTO_OPEN
	var close_speed := SPEED_SLIDE_CLOSE if d.kind == "sliding" else SPEED_AUTO_CLOSE
	if d.jam_t > 0.0:
		d.jam_t -= delta
		# Stuck part way: it shudders in place, then frees itself.
		var wobble := 0.07 if int(_t * 7.0) % 2 == 0 else -0.05
		d.target = JAM_AMOUNT + wobble
		d.speed = 1.4
		_moving[d.door_id] = d
		if _t - d.last_sound_t > 0.95:
			d.last_sound_t = _t
			game._sound("doors_jam", d.centre)
			game.emit_noise(d.centre, NOISE_GATE, "door")
		if d.jam_t <= 0.0:
			d.jam_cooldown = _rng.randf_range(JAM_COOLDOWN.x, JAM_COOLDOWN.y)
			_drive(d, 1.0, open_speed)
		return
	if sensed:
		d.sensor_t = SENSOR_HOLD
		if d.target < 1.0:
			if d.is_closed():
				_count("auto")
				game._sound("doors_hiss" if d.kind == "sliding" else "doors_heavy", d.centre)
				if d.kind != "sliding":
					game.emit_noise(d.centre, NOISE_GATE, "door")
			_drive(d, 1.0, open_speed)
		if d.kind == "gate" and d.amount > 0.18 and d.amount < JAM_AMOUNT - 0.05 and _jam_roll(d):
			d.jam_t = _rng.randf_range(JAM_SECONDS.x, JAM_SECONDS.y)
			d.last_sound_t = _t
			_count("jam")
			game._sound("doors_jam", d.centre)
			game.emit_noise(d.centre, NOISE_GATE, "door")
			game._broadcast("dr_jam", {"id": d.door_id, "t": d.jam_t})
	else:
		d.sensor_t -= delta
		if d.sensor_t <= 0.0 and d.target > 0.0:
			if d.amount > 0.6:
				game._sound("doors_hiss" if d.kind == "sliding" else "doors_heavy", d.centre)
			_drive(d, 0.0, close_speed)


## Deep wings' gates sometimes stick: once per opening, when the roll says so.
func _jam_roll(d: Node) -> bool:
	if d.jam_cooldown > 0.0 or d.get_meta("jam_rolled", false):
		return false
	d.set_meta("jam_rolled", true)
	if force_jam == 0:
		return false
	if force_jam == 1:
		return true
	var wings: Array = game.level_info.get("wings", [])
	var depth := int(_gate_depth(d))
	if wings.size() < 3 or depth < maxi(2, wings.size() - 1):
		return false
	return _rng.randf() < JAM_CHANCE


func _gate_depth(d: Node) -> int:
	for wd in game.level_info.get("wings", []):
		if String(wd.get("id", "")) == String(d.data.get("wing", "")):
			return int(wd.get("depth", 0))
	return int(d.data.get("depth", 0))


# =========================================================================
# hinged doors: E, and agents walking into them
# =========================================================================

func prompt_for(d: Node, _player) -> String:
	if game == null:
		return ""
	if d.kind == "gate":
		if _client_or_host_locked(d):
			if unlocking or bool(game.get("clock_in_pending")):
				return "!The wing doors are unlocking..."
			if game.phase == game.Phase.LOBBY:
				return "!Locked until the shift starts"
			return "!Locked"
		return ""
	if not d.is_hinged():
		return ""
	var plural: bool = d.kind == "double"
	var open_now: bool = absf(d.target) > 0.3 or absf(d.amount) > 0.3
	if open_now:
		return "Close doors" if plural else "Close door"
	return "Open doors" if plural else "Open door"


func _client_or_host_locked(d: Node) -> bool:
	if game.is_host():
		return d.locked
	return _cl_locked or not _wings_ready()


## Host: a player pressed E on a door.
func player_used(d: Node, p: Node) -> void:
	if not game.is_host():
		return
	if d.kind == "gate" and d.locked:
		var last := float(_locked_sound_at.get(d.door_id, -10.0))
		if _t - last > 0.8:
			_locked_sound_at[d.door_id] = _t
			game._sound("doors_locked", d.centre)
		return
	if not d.is_hinged():
		return
	var open_now: bool = absf(d.target) > 0.3 or (absf(d.amount) > 0.3 and not d.moving)
	if open_now:
		var slam: bool = d.moving or bool(p.get("sprinting"))
		_drive(d, 0.0, SPEED_SLAM if slam else SPEED_CLOSE)
		if slam:
			_count("slam")
			game._sound("doors_slam", d.centre)
			game.emit_noise(d.centre, NOISE_SLAM, "door_slam")
		else:
			game._sound("doors_latch", d.centre)
			game.emit_noise(d.centre, NOISE_OPEN * 0.8, "door")
		return
	var side := swing_side(d, p.global_position)
	_drive(d, float(side) * d.limit(side), SPEED_OPEN)
	_count("player")
	game._sound("doors_creak", d.centre)
	game.emit_noise(d.centre, NOISE_OPEN, "door")


## Which way a hinged door swings for someone standing at `pos`: away from them, unless the far
## side has no room (then into the tunnel, toward them).
func swing_side(d: Node, pos: Vector3) -> int:
	var lp: Vector3 = d.global_transform.affine_inverse() * pos
	var side := -1 if lp.z >= 0.0 else 1
	if side > 0 and d.max_out < OUT_MIN_DEG:
		side = -1
	return side


func _push_check(d: Node, a: Dictionary) -> void:
	var lp: Vector3 = d.global_transform.affine_inverse() * (a.pos as Vector3)
	var kind: String = a.kind
	var reach := CARRIER_RANGE if (kind == "carrier" or kind == "player") else PUSH_RANGE
	if kind == "player":
		return   # players use E
	if absf(lp.z) > reach or absf(lp.x) > d.width * 0.5 + PUSH_SIDE:
		return
	# Heading into the door: facing across its plane toward it. Bots and carriers walking a path
	# around a corner often face the door at a slant, so for them being right at it is enough.
	var fwd_z: float = d.normal.dot(a.fwd)
	var pushing := fwd_z * signf(lp.z) <= -0.2
	if (kind == "bot" or kind == "carrier") and absf(lp.z) <= 1.3 and absf(lp.x) <= d.width * 0.5:
		pushing = pushing or fwd_z * signf(lp.z) <= 0.3
	if not pushing:
		return
	var side := swing_side(d, a.pos)
	var want: float = float(side) * d.limit(side)
	if absf(d.target) >= absf(want) - 0.05 and signf(d.target) == signf(want):
		return   # already opening (or open) that way
	if absf(d.amount) > 0.75 and not d.halted:
		return   # open enough to pass
	var m: Node = a.node
	match kind:
		"bot", "carrier":
			if not agents_open_doors:
				return
			_drive(d, want, SPEED_OPEN, m)
			_count("bot")
			game._sound("doors_creak", d.centre)
			game.emit_noise(d.centre, NOISE_OPEN, "door")
		"walk_in":
			if m == null or not _monster_wants_through(m):
				return
			_drive(d, want, SPEED_WALK_IN)
			_count("walk_in")
			game._sound("doors_creak", d.centre)
			game.emit_noise(d.centre, NOISE_CREAK, "door")
		"discharged":
			if m == null or not _monster_wants_through(m):
				return
			if int(m.mode) == M.Mode.RUSH:
				_drive(d, want, SPEED_BURST)
				_count("discharged_burst")
				game._sound("doors_slam", d.centre)
				game.emit_noise(d.centre, NOISE_SLAM, "door_slam")
			else:
				_drive(d, want, SPEED_CLOSE)
				game._sound("doors_creak", d.centre)
				game.emit_noise(d.centre, NOISE_CREAK, "door")
			_count("discharged")
		"night_nurse":
			if m == null or bool(m.observed) or not _monster_wants_through(m):
				return
			if _door_watched(d):
				return
			_drive(d, want, SPEED_NURSE)
			_count("night_nurse")


func _monster_wants_through(m: Node) -> bool:
	match int(m.mode):
		M.Mode.WANDER, M.Mode.RUSH:
			return true
	return false


## Is anybody looking at this door in the light right now? Sampled a few times a second per door.
func _door_watched(d: Node) -> bool:
	if _t - d.observed_t < 0.2:
		return d.observed
	d.observed_t = _t
	d.observed = Percept.observed_any(game, [d.centre, d.centre + d.normal * 0.4, d.centre - d.normal * 0.4])
	return d.observed


# =========================================================================
# gates, dev, tests
# =========================================================================

## Host: lock (close) or unlock every wing gate. Unlocking opens each one for a moment.
func set_gates_locked(locked: bool, sound: bool) -> void:
	gates_locked = locked
	for d in doors.values():
		if d == null or not is_instance_valid(d) or d.kind != "gate":
			continue
		d.locked = locked
		d.set_meta("jam_rolled", false)
		d.jam_t = 0.0
		if locked:
			_drive(d, 0.0, SPEED_SLAM if d.amount > 0.1 else SPEED_AUTO_CLOSE)
			d.set_lamp("locked")
			if sound:
				game._sound("doors_locked", d.centre)
		else:
			_hold_open[d.door_id] = UNLOCK_HOLD
			d.set_lamp("open")
			if sound:
				game._sound("doors_unlock", d.centre)


## Host (dev panel): every hinged door open or shut at once; automatic doors are left alone.
func set_all(open: bool) -> void:
	for d in doors.values():
		if d == null or not is_instance_valid(d) or not d.is_hinged():
			continue
		if open:
			var side := -1 if d.max_out < OUT_MIN_DEG else 1
			_drive(d, float(side) * d.limit(side), SPEED_OPEN)
		else:
			_drive(d, 0.0, SPEED_CLOSE)


## Host: a door's state right now, for tests.
func amount_of(id: String) -> float:
	var d = doors.get(id)
	return float(d.amount) if d != null else 0.0


## Every agent path through doors needs them to open: the nearest door to a point, or null.
func nearest(p: Vector3, max_dist := 3.0) -> Node:
	var best: Node = null
	var bd := max_dist
	for d in near(p):
		var dist: float = (d.global_position as Vector3).distance_to(Vector3(p.x, 0.0, p.z))
		if dist < bd:
			bd = dist
			best = d
	return best


# =========================================================================
# sound through doors
# =========================================================================

## How much of a sound gets from `a` to `b` through the doors on the straight line between them:
## 1.0 with every door open, DOOR_SOUND_FACTOR for each closed one.
func sound_factor(a: Vector3, b: Vector3) -> float:
	if _tile_door.is_empty():
		return 1.0
	var ta := Vector2(a.x, a.z) / C.TILE
	var tb := Vector2(b.x, b.z) / C.TILE
	var steps := int(ceil(ta.distance_to(tb) * 2.5)) + 1
	var f := 1.0
	var seen := {}
	for i in steps + 1:
		var p := ta.lerp(tb, float(i) / float(steps))
		var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
		var d = _tile_door.get(t)
		if d == null or seen.has(d.door_id):
			continue
		seen[d.door_id] = true
		if absf(d.amount) < 0.3:
			f *= DOOR_SOUND_FACTOR
	return f


# =========================================================================
# replication
# =========================================================================

## Host: flat global fields for the snapshot ("d.<id>" amounts in fiftieths, "dl" gates locked).
func net_fields() -> Dictionary:
	var out := {"dl": gates_locked, "du": unlocking}
	for id in doors.keys():
		var d = doors[id]
		if d == null or not is_instance_valid(d):
			continue
		var q := int(round(float(d.amount) * 50.0))
		if d.kind == "gate" or d.kind == "auto":
			q *= -1 if d.swing < 0 else 1   # automatic pairs: the sign is the way they swing
		out["d." + String(id)] = q
	return out


## Client: follow the host's doors.
func apply_net(g: Dictionary) -> void:
	if game.is_host():
		return
	_cl_locked = bool(g.get("dl", true))
	unlocking = bool(g.get("du", false))
	for k in g.keys():
		var key := String(k)
		if not key.begins_with("d."):
			continue
		var id := key.substr(2)
		var d = doors.get(id)
		if d == null or not is_instance_valid(d):
			continue
		var a := float(int(g[k])) / 50.0
		if d.kind == "gate" or d.kind == "auto":
			if a < 0.0:
				d.swing = -1
			elif a > 0.0:
				d.swing = 1
			a = absf(a)
		if not _applied_once.has(id):
			_applied_once[id] = true
			d.snap_to(a)
			continue
		if not is_equal_approx(d.target, a):
			d.target = a
			d.speed = maxf(CLIENT_SPEED, absf(a - float(d.amount)) * 8.0)
			_moving[id] = d
	var locked := _cl_locked or not _wings_ready()
	for d in doors.values():
		if d != null and is_instance_valid(d) and d.kind == "gate":
			d.locked = locked
			d.set_lamp("unlocking" if (unlocking and int(_t * 3.0) % 2 == 0) else ("locked" if locked else "open"))
			if locked and not _wings_ready() and not d.is_closed():
				d.target = 0.0
				d.speed = SPEED_SLAM
				_moving[d.door_id] = d


func on_event(kind: String, data: Dictionary) -> void:
	match kind:
		"dr_jam":
			pass   # the stutter arrives with the amounts; the sound came as a sound event
