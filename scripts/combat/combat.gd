extends Node
## Combat (sweep 3, docs/SWEEP3.md "Combat"): bone saw swings, anesthetic jabs, dragging a sedated
## monster and strapping it to a patient table, and the first-person swing / jab animations.
##
## Host authoritative. The player presses left mouse (Player.use_count, game.player_used -> use());
## the local machine plays the animation at once (local_try_use) and everyone else sees it through
## the reliable event `cb_swing`. Dragging is Player.dragging_monster (report key `dm`); every machine
## pins the monster behind its dragger with monster_pin(m).
##
## The monster API (take_hit, can_sedate, sedate, is_sedated, wake, dragged_by, sedation_left) comes
## from the `monsters` worker. Every call is guarded, with simple stand-ins while it is missing: a
## monster dies after FALLBACK_HITS hits (or its `max_hp`), a stagger is game.knock_down_monster,
## "sedated" is a long knock-down tracked here (and replicated in net_state `s`), and the lying
## look is this file tipping the monster's model over.

const MonsterScript := preload("res://scripts/monster.gd")

const SAW_BREAK_CHANCE := 0.12
const SWING_COOLDOWN := 0.8
const SAW_REACH := 2.0
const SEDATE_SECONDS := 75.0
const JAB_COOLDOWN := 1.0
const JAB_REACH := 1.8

## Hold E this long on a sedated monster to start dragging it.
const DRAG_HOLD := 1.0
## A dragger walks at this fraction of their normal speed (Player reads it).
const DRAG_SPEED_K := 0.55
## Metres from the dragger's feet back to the middle of the dragged body.
const DRAG_BEHIND := 1.15
## A teammate jabbed with anesthetic is out for this long.
const JAB_KNOCKOUT := 8.0
## Half-angles of the hit cones around the aim.
const SWING_CONE_DEG := 38.0
const JAB_CONE_DEG := 30.0
const NOISE_HIT := 0.9
const NOISE_SWING := 0.3
## Hits a monster takes without the monsters API (or a max_hp) before it dies.
const FALLBACK_HITS := 2
## The server accepts a use a little before the client's own cooldown ends (timing jitter).
const HOST_COOLDOWN_SLACK := 0.8
## Strapping maps sedation left (0 .. SEDATE_SECONDS) onto the case's flags.sedation.
const STRAP_SEDATION_MIN := 0.35

const SWING_TIME := 0.55
const JAB_TIME := 0.45

var game: Node = null
## Host: the break roll. Tests seed it and may change break_chance.
var rng := RandomNumberGenerator.new()
var break_chance := SAW_BREAK_CHANCE
## Host: what the last use did, for tests: {what: "air"|"monster"|"player"|"refused"|..., result, id}.
var last_result: Dictionary = {}
## Every machine: cb_swing animations started per peer id (tests).
var swings_seen: Dictionary = {}
## Tools: hold every animation at its current time (screenshots set _anims[peer].t themselves).
var anim_freeze := false

var _cd: Dictionary = {}          # host: peer id -> world_time its next use is accepted
var _local_next := 0.0            # this machine: the local player's own cooldown (msec)
var _holds: Dictionary = {}       # host: peer id -> seconds held on a sedated monster
var _fb_hits: Dictionary = {}     # fallback: monster id -> saw hits taken
var _fb_sedated: Dictionary = {}  # fallback: host monster id -> world_time it wakes; clients id -> 0.0
var _anims: Dictionary = {}       # every machine: peer id -> {k, t, prop: [nodes]}
var _aims: Dictionary = {}        # every machine: monster id -> MonsterAim
var _lying: Dictionary = {}       # fallback look: monster id -> true while its model is tipped over


func setup(g: Node) -> void:
	game = g
	rng.randomize()


## Every machine: does left mouse "use" this held kind instead of shoving?
func is_usable(kind: String) -> bool:
	return kind == "bone_saw" or kind == "anesthetic"


# =========================================================================
# using the saw and the needle
# =========================================================================

## The local machine, the moment the player clicks: false while its own cooldown runs (the click
## is ignored); otherwise it starts the animation and the whoosh right away and returns true.
func local_try_use(p: Node) -> bool:
	var kind := String(p.selected_stack().kind)
	if not is_usable(kind):
		return false
	var now := Time.get_ticks_msec()
	if now < _local_next:
		return false
	_local_next = now + int((SWING_COOLDOWN if kind == "bone_saw" else JAB_COOLDOWN) * 1000.0)
	_start_anim(p, "saw" if kind == "bone_saw" else "jab")
	return true


## Host: p pressed left mouse with a usable item selected.
func use(p: Node) -> void:
	if game == null or not game.is_host() or p == null or not is_instance_valid(p):
		return
	if not p.alive or p.downed or p.stun > 0.0 or p.carrying != 0 or p.carried_by != 0 or dragging(p) >= 0 or p.operating:
		last_result = {"what": "refused"}
		return
	var kind := String(p.selected_stack().kind)
	if not is_usable(kind):
		return
	var now: float = game.world_time
	if now < float(_cd.get(p.peer_id, -INF)):
		last_result = {"what": "cooldown"}
		return
	var saw := kind == "bone_saw"
	_cd[p.peer_id] = now + (SWING_COOLDOWN if saw else JAB_COOLDOWN) * HOST_COOLDOWN_SLACK
	var k := "saw" if saw else "jab"
	if not p.is_local or not _anim_recent(p):
		_start_anim(p, k)
	game._broadcast("cb_swing", {"id": p.peer_id, "k": k})
	if saw:
		_swing(p)
	else:
		_jab(p)


func _swing(p: Node) -> void:
	var t := find_target(p, SAW_REACH, SWING_CONE_DEG)
	if t.is_empty():
		game.emit_noise(p.global_position, NOISE_SWING, "swing")
		last_result = {"what": "air"}
		return
	var at: Vector3 = t.point
	game.emit_noise(at, NOISE_HIT, "saw")
	var dir := _aim_dir(p)
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	if t.kind == "monster":
		var m: Node = t.node
		var mid: int = m.monster_id
		var mname := monster_name(String(m.kind))
		var res := _hit_monster(m, dir, p)
		last_result = {"what": "monster", "result": res, "id": mid}
		match res:
			"immune":
				game._sound("combat_clang", at)
				game.tell(p, "The saw skids off her. She does not even notice.", 2.5)
			"killed":
				game._sound("combat_hit", at)
				game.kill_monster(m)
				game.tell(p, "The %s is dead. Nothing to harvest from it now." % mname, 3.0)
			_:
				game._sound("combat_hit", at)
	else:
		var q: Node = t.node
		last_result = {"what": "player", "id": q.peer_id}
		game._sound("combat_hit", at)
		var god: bool = game.dev_mode and game.dev.is_god(q)
		if q.invuln <= 0.0 and not god:
			game.damage_player(q, 1, "saw:%s" % p.player_name, dir * 6.0 + Vector3.UP * 1.5)
			game.say("%s took a bone saw to %s." % [p.player_name, q.player_name], 3.0)
	if breaks():
		_snap_saw(p)


## Host: one break roll (tests call it directly to measure the rate).
func breaks() -> bool:
	return rng.randf() < break_chance


func _snap_saw(p: Node) -> void:
	var i: int = p.selected_head()
	if String(p.slots[i].kind) != "bone_saw":
		i = -1
		for j in p.slots.size():
			if String(p.slots[j].kind) == "bone_saw":
				i = j
				break
	if i < 0:
		return
	p.clear_slot(i)
	last_result["snapped"] = true
	game._sound("combat_snap", p.global_position + Vector3.UP * 1.3)
	game.say("%s's bone saw snapped." % p.player_name, 3.0)


## Host: the saw connects with a monster. "stagger", "killed" or "immune".
func _hit_monster(m: Node, dir: Vector3, p: Node) -> String:
	if m.has_method("take_hit"):
		return String(m.take_hit(dir, 1, "saw:%s" % p.player_name))
	if not _hurtable(m):
		return "immune"
	var id: int = m.monster_id
	var n := int(_fb_hits.get(id, 0)) + 1
	_fb_hits[id] = n
	var hp := int(m.get("max_hp")) if "max_hp" in m else FALLBACK_HITS
	if n >= maxi(1, hp):
		return "killed"
	if not is_sedated(m):
		game.knock_down_monster(m, dir, 1.0)   # stand-in for the stagger
	return "stagger"


func _jab(p: Node) -> void:
	var t := find_target(p, JAB_REACH, JAB_CONE_DEG)
	if t.is_empty():
		last_result = {"what": "air"}
		return
	if t.kind == "player":
		var q: Node = t.node
		_use_vial(p)
		last_result = {"what": "player", "id": q.peer_id}
		game._sound("combat_jab", q.global_position + Vector3.UP * 1.2)
		knock_out(q, JAB_KNOCKOUT)
		game.say("%s jabbed %s with anesthetic. Out cold." % [p.player_name, q.player_name], 3.0)
		return
	var m: Node = t.node
	var mname := monster_name(String(m.kind))
	var id: int = m.monster_id
	if not _capturable(m):
		last_result = {"what": "monster", "result": "refused", "id": id}
		game._sound("combat_needle_fail", t.point)
		game.tell(p, "The needle will not go in.", 2.5)
		return
	if is_sedated(m):
		last_result = {"what": "monster", "result": "already", "id": id}
		game.tell(p, "It is already under. Hold E to drag it.", 2.5)
		return
	if not can_sedate(m):
		last_result = {"what": "monster", "result": "shrugged", "id": id}
		game._sound("combat_needle_fail", t.point)
		if m.has_method("alert_to"):
			m.alert_to(p.global_position)
		game.tell(p, "It shrugged off the needle. Shove it first.", 2.5)
		return
	_use_vial(p)
	_sedate(m)
	last_result = {"what": "monster", "result": "sedated", "id": id}
	game._sound("combat_jab", t.point)
	game.say("%s put the %s under. Hold E to drag it to a table." % [p.player_name, mname], 3.5)


func _use_vial(p: Node) -> void:
	var i: int = p.selected_head()
	if String(p.slots[i].kind) != "anesthetic":
		return
	p.slots[i].count = int(p.slots[i].count) - 1
	if int(p.slots[i].count) <= 0:
		p.clear_slot(i)


## Host: q is knocked out for `seconds` (a jab from a teammate): hands drop, whoever they carried or
## dragged lands, the operation ends. Uses the dev room's `stun` (and its event).
func knock_out(q: Node, seconds: float) -> void:
	if not game.is_host() or q == null or not q.alive or q.downed:
		return
	game.end_operations(q)
	drop_dragged(q)
	if q.carrying != 0:
		game.drop_carried(q)
	game._drop_hands(q, true)
	q.stun = seconds
	game._broadcast("stun", {"id": q.peer_id, "t": seconds})
	game._sound("downed_fall", q.global_position)


# =========================================================================
# targets
# =========================================================================

## Where p looks, from yaw and pitch (the same on the host for a remote player as on its machine).
func _aim_dir(p: Node) -> Vector3:
	return Basis(Vector3.UP, p.rotation.y) * Basis(Vector3.RIGHT, p.head.rotation.x) * Vector3.FORWARD


## Host (any machine can ask): the nearest monster or standing player in the cone in front of p's
## eyes, with a clear line. {} or {node, kind: "monster"|"player", point, dist}.
func find_target(p: Node, reach: float, cone_deg: float) -> Dictionary:
	var eye: Vector3 = p.head.global_position
	var dir := _aim_dir(p)
	var best := {}
	var cos_cone := cos(deg_to_rad(cone_deg))
	var cands: Array = []
	for m in game.monsters.values():
		if m == null or not is_instance_valid(m) or not m.is_inside_tree():
			continue
		var pos: Vector3 = m.global_position
		var r := float(m.get("body_radius")) + 0.12 if "body_radius" in m else 0.5
		if is_sedated(m) or dragger_of(m) != null:
			var axis: Vector3 = m.global_transform.basis.z
			axis.y = 0.0
			axis = axis.normalized() if axis.length() > 0.01 else Vector3.BACK
			cands.append([m, "monster", pos + Vector3.UP * 0.25 - axis * 0.9, pos + Vector3.UP * 0.25 + axis * 0.9, 0.45])
		else:
			var h := float(m.get("height")) if "height" in m else 1.85
			cands.append([m, "monster", pos + Vector3.UP * 0.3, pos + Vector3.UP * maxf(0.4, h - 0.15), r])
	for q in game.players.values():
		if q == p or q == null or not is_instance_valid(q) or not q.alive or q.downed or q.carried_by != 0:
			continue
		if game.waiting_peers.has(q.peer_id):
			continue
		var qp: Vector3 = q.global_position
		cands.append([q, "player", qp + Vector3.UP * 0.3, qp + Vector3.UP * 1.75, C.PLAYER_RADIUS + 0.12])
	var far := eye + dir * (reach + 0.6)
	for c in cands:
		var r := float(c[4])
		var pts := Geometry3D.get_closest_points_between_segments(eye, far, c[2], c[3])
		var on_ray: Vector3 = pts[0]
		var on_body: Vector3 = pts[1]
		var to_body := on_body - eye
		var dist := to_body.length()
		if dist > reach + r:
			continue
		if on_ray.distance_to(on_body) > r and (dist < 0.001 or dir.dot(to_body / dist) < cos_cone):
			continue
		if (on_ray - eye).dot(dir) < 0.0 and dist > r:
			continue   # behind the eyes
		if not best.is_empty() and dist >= float(best.dist):
			continue
		if not _clear_line(eye, on_body, c[0]):
			continue
		best = {"node": c[0], "kind": c[1], "point": on_body, "dist": dist}
	return best


func _clear_line(from: Vector3, to: Vector3, _target: Node) -> bool:
	var world: World3D = game.get_viewport().world_3d if game.is_inside_tree() else null
	if world == null:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = C.L_WORLD
	return world.direct_space_state.intersect_ray(q).is_empty()


# =========================================================================
# the monster API, guarded (the monsters worker builds the real one)
# =========================================================================

func _hurtable(m: Node) -> bool:
	if m.has_method("can_be_hurt"):
		return bool(m.can_be_hurt())
	return String(m.kind) != MonsterScript.NIGHT_NURSE


func _capturable(m: Node) -> bool:
	var s = m.get_script()
	if s != null and s.has_method("is_capturable"):
		return bool(s.is_capturable(String(m.kind)))
	return String(m.kind) != MonsterScript.NIGHT_NURSE


## Every machine.
func is_sedated(m: Node) -> bool:
	if m == null or not is_instance_valid(m):
		return false
	if m.has_method("is_sedated"):
		return bool(m.is_sedated())
	return _fb_sedated.has(int(m.monster_id))


## Host: may the needle put it under right now (capturable, not sedated, stunned).
func can_sedate(m: Node) -> bool:
	if m.has_method("can_sedate"):
		return bool(m.can_sedate())
	if not _capturable(m) or is_sedated(m):
		return false
	return "mode" in m and int(m.mode) == MonsterScript.Mode.STUNNED


func _sedate(m: Node) -> void:
	if m.has_method("sedate"):
		m.sedate(SEDATE_SECONDS)
		return
	_fb_sedated[int(m.monster_id)] = float(game.world_time) + SEDATE_SECONDS
	game.knock_down_monster(m, Vector3.ZERO, SEDATE_SECONDS + 1.0)


## Host: seconds of sedation left.
func sedation_left(m: Node) -> float:
	if "sedation_left" in m:
		return float(m.sedation_left)
	return maxf(0.0, float(_fb_sedated.get(int(m.monster_id), 0.0)) - float(game.world_time))


## Tests: make a sedated monster's sedation run out in `seconds`.
func set_sedation_left(m: Node, seconds: float) -> void:
	if "sedation_left" in m:
		m.sedation_left = seconds
	elif _fb_sedated.has(int(m.monster_id)):
		_fb_sedated[int(m.monster_id)] = float(game.world_time) + seconds


func _fallback_wake(m: Node) -> void:
	_fb_sedated.erase(int(m.monster_id))
	if m.brain != null and "timer" in m.brain:
		m.brain.timer = 0.0


static func monster_name(kind: String) -> String:
	match kind:
		"walk_in":
			return "Walk-In"
		"night_nurse":
			return "Night Nurse"
		"discharged":
			return "Discharged"
	return kind.capitalize()


# =========================================================================
# dragging and strapping
# =========================================================================

## Every machine: the monster id p drags, -1 for none.
func dragging(p: Node) -> int:
	if p == null or not is_instance_valid(p) or not "dragging_monster" in p:
		return -1
	return int(p.dragging_monster)


## Every machine: the player dragging m, or null.
func dragger_of(m: Node) -> Node:
	if m == null or not is_instance_valid(m):
		return null
	var id: int = m.monster_id
	for q in game.players.values():
		if is_instance_valid(q) and dragging(q) == id:
			return q
	return null


## Every machine: where a dragged monster lies this frame. The origin is on the floor under the
## middle of its body, DRAG_BEHIND metres behind the dragger; the basis has the dragger's yaw, so the
## pin's -Z points at the dragger: the body lies along Z with its feet toward -Z (held by the ankles)
## and its head toward +Z. Not dragged: the monster's own transform.
func monster_pin(m: Node) -> Transform3D:
	var q := dragger_of(m)
	if q == null:
		return m.global_transform if m != null and is_instance_valid(m) and m.is_inside_tree() else Transform3D.IDENTITY
	var b := Basis(Vector3.UP, q.rotation.y)
	return Transform3D(b, q.global_position + b * Vector3(0.0, 0.0, DRAG_BEHIND))


## Whether q may start dragging m (hands aside when check_hands is false).
func can_drag(q: Node, m: Node, check_hands := true) -> bool:
	if q == null or m == null or not is_instance_valid(m) or game.phase == game.Phase.MENU:
		return false
	if not q.alive or q.downed or q.stun > 0.0 or q.carrying != 0 or q.carried_by != 0 or dragging(q) >= 0 or q.operating:
		return false
	if not is_sedated(m) or dragger_of(m) != null:
		return false
	return not check_hands or q.hands_empty()


## The prompt on a sedated monster's aim box.
func drag_prompt(q: Node, m: Node) -> String:
	if q == null or not can_drag(q, m, false):
		return ""
	var mname := monster_name(String(m.kind))
	if not q.hands_empty():
		return "!Empty your hands to drag the %s." % mname
	return "Hold E: drag the %s" % mname


## Player._update_aim while dragging: [aim_id, prompt]. A free patient table offers to strap the
## monster down; anything else puts it down.
func drag_aim(p: Node, node: Node) -> Array:
	var m = game.monsters.get(dragging(p))
	var mname := monster_name(String(m.kind)) if m != null and is_instance_valid(m) else "it"
	var id := ""
	if node != null and node.has_meta("interact_id"):
		id = String(node.get_meta("interact_id"))
	var ti := table_index_for(id)
	if ti >= 0:
		var why := strap_problem(ti)
		if why == "":
			return [id, "Strap the %s to the table" % mname]
		return ["", "Put the %s down  (%s)" % [mname, why]]
	return ["", "Put the %s down" % mname]


## The patient table index behind an interact id ("table", "table_<i>"), or -1.
func table_index_for(id: String) -> int:
	if not id.begins_with("table"):
		return -1
	for t in game.patient_tables:
		if game.table_interact_id(int(t.index)) == id:
			return int(t.index)
	return -1


## "" when a monster can be strapped to this patient table now, else why not.
func strap_problem(ti: int) -> String:
	if game.phase != game.Phase.SHIFT:
		return "not during the lobby"
	if not game.case_on_table(ti).is_empty():
		return "the table is taken"
	if game.loop != null and game.loop.has_method("table_reserved") and game.loop.table_reserved(ti):
		return "a patient is on the way to it"
	return ""


## Host: start dragging.
func start_drag(q: Node, m: Node) -> void:
	if not game.is_host() or not can_drag(q, m):
		return
	q.dragging_monster = int(m.monster_id)
	if "dragged_by" in m:
		m.dragged_by = q.peer_id
	game.end_operations(q)
	game._sound("combat_drag", m.global_position)
	game.tell(q, "E on a free patient table straps it down. E anywhere else lets go.", 3.5)


## Host: a dragger pressed E. On a free patient table it straps the monster down, anywhere else it
## puts it down.
func dragger_pressed_interact(q: Node, aim: String) -> void:
	if not game.is_host() or dragging(q) < 0:
		return
	var ti := table_index_for(aim)
	if ti >= 0 and strap_problem(ti) == "":
		var node: Node = game.find_interactable(aim)
		if node != null and game._within_reach(q, node):
			strap(q, ti)
			return
	drop_dragged(q)


## Host: strap the monster q drags onto patient table ti: a monster case, and the monster leaves.
func strap(q: Node, ti: int) -> int:
	if not game.is_host():
		return -1
	var m = game.monsters.get(dragging(q))
	if m == null or not is_instance_valid(m):
		q.dragging_monster = -1
		return -1
	var s := lerpf(STRAP_SEDATION_MIN, 1.0, clampf(sedation_left(m) / SEDATE_SECONDS, 0.0, 1.0))
	var kind := String(m.kind)
	var id: int = game.add_case({"table": ti, "patient_id": kind, "ailment_id": "dissection", "monster": true,
		"flags": {"sedation": snappedf(s, 0.01)}})
	if id < 0:
		game.tell(q, "The table is taken.", 2.0)
		return -1
	q.dragging_monster = -1
	if "dragged_by" in m:
		m.dragged_by = 0
	_remove_monster_quietly(m)
	var at: Vector3 = game.table_position(ti) + Vector3.UP * 1.0
	game._sound("combat_strap", at)
	game.say("%s strapped the %s to the table." % [q.player_name, monster_name(kind)], 3.5)
	last_result = {"what": "strapped", "case": id, "table": ti}
	return id


## Host: a monster leaves the game without a death (strapped onto a table).
func _remove_monster_quietly(m: Node) -> void:
	var id: int = m.monster_id
	game.monsters.erase(id)
	on_monster_removed(m)
	m.queue_free()


## Host: p lets go of the monster it drags; it lies where it was pinned.
func drop_dragged(p: Node) -> void:
	if game == null or not game.is_host() or p == null or not is_instance_valid(p):
		return
	var id := dragging(p)
	if id < 0:
		return
	var m = game.monsters.get(id)
	var pin := monster_pin(m) if m != null and is_instance_valid(m) else Transform3D.IDENTITY
	p.dragging_monster = -1
	if m == null or not is_instance_valid(m):
		return
	if "dragged_by" in m:
		m.dragged_by = 0
	var spot := pin.origin
	if not game._point_is_clear(spot + Vector3.UP * 0.2):
		spot = p.global_position
	spot = game._floor_at(spot)
	m.global_position = spot
	m.rotation.y = pin.basis.get_euler().y
	if "_target_pos" in m:
		m._target_pos = spot
		m._target_yaw = m.rotation.y
	game._sound("thud", spot)


## Host: the dragged monster woke up: it drops, gets up and hits whoever dragged it.
func _wake_drop(q: Node, m: Node) -> void:
	drop_dragged(q)
	var to: Vector3 = q.global_position - m.global_position
	to.y = 0.0
	if to.length() > 0.01:
		m.rotation.y = atan2(-to.x, -to.z)
	game.say("The %s woke up on %s!" % [monster_name(String(m.kind)), q.player_name], 3.0)
	if m.has_method("alert_to"):
		m.alert_to(q.global_position)
	game.monster_hit_player(m, q)


# =========================================================================
# ticking
# =========================================================================

func physics_tick(delta: float) -> void:
	if game == null:
		return
	if game.is_host():
		_host_tick(delta)
	_tick_aims()
	_pin_fallback()


func _host_tick(delta: float) -> void:
	var now: float = game.world_time
	# Fallback sedation running out.
	for id in _fb_sedated.keys():
		if now >= float(_fb_sedated[id]):
			var fm = game.monsters.get(id)
			if fm != null and is_instance_valid(fm):
				_fallback_wake(fm)
			else:
				_fb_sedated.erase(id)
	# Draggers who cannot drag any more, monsters that woke up.
	for q in game.players.values():
		var id := dragging(q)
		if id < 0:
			continue
		var m = game.monsters.get(id)
		if m == null or not is_instance_valid(m):
			q.dragging_monster = -1
		elif not q.alive or q.downed or q.stun > 0.0 or q.carried_by != 0:
			drop_dragged(q)
		elif not is_sedated(m):
			_wake_drop(q, m)
	# Monsters still marked as dragged by someone who let go or left.
	for m in game.monsters.values():
		if is_instance_valid(m) and "dragged_by" in m and int(m.dragged_by) != 0:
			var q = game.players.get(int(m.dragged_by))
			if q == null or not is_instance_valid(q) or dragging(q) != int(m.monster_id):
				m.dragged_by = 0
	# Holding E on a sedated monster.
	for q in game.players.values():
		var aim := String(q.aim_id)
		var m = null
		if q.wants_interact and aim.begins_with("mo_"):
			m = game.monsters.get(int(aim.substr(3)))
		var box = _aims.get(int(m.monster_id)) if m != null and is_instance_valid(m) else null
		if m != null and box != null and can_drag(q, m) and game._within_reach(q, box):
			var h := float(_holds.get(q.peer_id, 0.0)) + delta
			if h >= DRAG_HOLD:
				_holds.erase(q.peer_id)
				start_drag(q, m)
			else:
				_holds[q.peer_id] = h
				q.carry_hold = h   # the HUD's hold bar (game._tick_carry_holds zeroed it this frame)
		else:
			_holds.erase(q.peer_id)


## Every machine: each monster carries an aim box (interact_id "mo_<id>"), aimable only while it
## lies sedated and nobody drags it.
func _tick_aims() -> void:
	for id in _aims.keys():
		if not game.monsters.has(id) or not is_instance_valid(_aims[id]):
			_aims.erase(id)
	for m in game.monsters.values():
		if m == null or not is_instance_valid(m):
			continue
		var id: int = m.monster_id
		var box = _aims.get(id)
		if box == null:
			box = MonsterAim.new()
			box.name = "CombatAim"
			box.combat = self
			box.monster = m
			box.collision_layer = 0
			box.collision_mask = 0
			box.monitoring = false
			box.monitorable = false
			box.add_to_group("interactable")
			box.set_meta("interact_id", "mo_%d" % id)
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(0.9, 0.7, 2.1)
			cs.shape = shape
			cs.position = Vector3(0.0, 0.35, 0.0)
			box.add_child(cs)
			m.add_child(box)
			_aims[id] = box
		var on := is_sedated(m) and dragger_of(m) == null
		box.collision_layer = C.L_INTERACT if on else 0


## The dragged look without the monsters API: pinned behind the dragger on every machine, lying down
## while sedated. With the API (`dragged_by`), monster.gd places itself.
func _pin_fallback() -> void:
	for m in game.monsters.values():
		if m == null or not is_instance_valid(m) or not m.is_inside_tree():
			continue
		var id: int = m.monster_id
		if not "dragged_by" in m:
			if dragger_of(m) != null:
				var pin := monster_pin(m)
				m.global_position = pin.origin
				m.rotation.y = pin.basis.get_euler().y
				if "_target_pos" in m:
					m._target_pos = pin.origin
					m._target_yaw = m.rotation.y
		if m.has_method("is_sedated") or m.model == null:
			continue
		var lie := is_sedated(m) or dragger_of(m) != null
		if lie != _lying.has(id):
			if lie:
				_lying[id] = true
				# Tipped onto its back along Z, feet toward -Z, the middle of the body at the origin.
				m.model.rotation = Vector3(PI * 0.5, 0.0, 0.0)
				m.model.position = Vector3(0.0, 0.2, -0.9)
			else:
				_lying.erase(id)
				m.model.rotation = Vector3.ZERO
				m.model.position = Vector3.ZERO


func _process(_delta: float) -> void:
	if game != null and game.phase != game.Phase.MENU:
		_pin_fallback()   # after the monsters' own physics, before drawing


class MonsterAim extends Area3D:
	var combat: Node
	var monster: Node

	func interact_prompt(q) -> String:
		return combat.drag_prompt(q, monster) if combat != null else ""

	func interact_hold() -> float:
		return DRAG_HOLD

	func interact(_q) -> void:
		pass   # the hold is simulated by the host (combat._host_tick)


# =========================================================================
# first-person and third-person swing / jab animation
# =========================================================================

func _anim_recent(p: Node) -> bool:
	var a = _anims.get(p.peer_id)
	return a != null and float(a.t) < 0.25


func _start_anim(p: Node, k: String) -> void:
	if p == null or not is_instance_valid(p):
		return
	_clear_props(p.peer_id)
	_anims[p.peer_id] = {"k": k, "t": 0.0, "props": []}
	swings_seen[p.peer_id] = int(swings_seen.get(p.peer_id, 0)) + 1
	var at: Vector3 = p.global_position + Vector3.UP * 1.4
	if k == "saw":
		Audio.play("combat_swing", at, -2.0, 0.1)
	else:
		Audio.play("combat_jab_swish", at, -6.0, 0.1)


## Tools: end p's animation now; the held model goes back to rest next frame.
func stop_anim(p: Node) -> void:
	var a = _anims.get(p.peer_id)
	if a != null:
		a.t = 99.0
		var was := anim_freeze
		anim_freeze = true
		animate_held(p, 0.0, p._held_fp, p._held_tp)
		anim_freeze = was


func _clear_props(peer: int) -> void:
	var a = _anims.get(peer)
	if a == null:
		return
	for n in a.props:
		if is_instance_valid(n):
			n.queue_free()
	a.props = []


## Player._process, every machine, every frame: move the held stack's model through the swing or
## the jab. `fp` / `tp` are HeldFirstPerson (under the camera) / HeldThirdPerson (under the body).
func animate_held(p: Node, delta: float, fp: Node3D, tp: Node3D) -> void:
	var a = _anims.get(p.peer_id)
	if a == null:
		return
	if not anim_freeze:
		a.t = float(a.t) + delta
	var jab: bool = a.k == "jab"
	var done := float(a.t) >= (JAB_TIME if jab else SWING_TIME)
	for holder in [fp, tp]:
		if holder == null or holder.get_child_count() == 0:
			continue
		var pivot := holder.get_child(holder.get_child_count() - 1) as Node3D
		if pivot == null or pivot.is_queued_for_deletion():
			continue
		if done:
			pivot.transform = Transform3D.IDENTITY
		else:
			var pose := anim_pose(String(a.k), float(a.t), holder.transform, holder == tp)
			pivot.transform = holder.transform.affine_inverse() * pose
		if jab:
			# The syringe drawn from the vials does the jab; the vials stay out of sight meanwhile.
			for c in pivot.get_children():
				if c.name != "CombatSyringe" and c is Node3D:
					(c as Node3D).visible = done
			if not done and not pivot.has_node("CombatSyringe"):
				var syr := make_syringe()
				syr.name = "CombatSyringe"
				pivot.add_child(syr)
				a.props.append(syr)
	if done:
		_clear_props(p.peer_id)
		_anims.erase(p.peer_id)


## Where the held model is `t` seconds into a swing ("saw") or a jab, in the holder's parent space
## (camera space in first person; body space for others, `third`). `rest` is the holder's own
## transform: the pose starts and ends there.
##   Saw model: blade along +X from the grip, teeth toward +Z, flat face +Y.
##   Syringe: needle along -Z.
static func anim_pose(k: String, t: float, rest: Transform3D, third := false) -> Transform3D:
	# Keys: [time, origin, blade (+X) direction, teeth (+Z) direction]; null: the resting pose.
	var keys: Array
	if k == "saw":
		# A diagonal chop from high on the right down across the view to the lower left.
		keys = [
			[0.0, null],
			[0.14, Vector3(0.2, 0.02, -0.5), Vector3(0.3, 1.0, 0.25), Vector3(-0.3, 0.0, -1.0)],
			[0.26, Vector3(0.05, -0.2, -0.5), Vector3(-1.0, -0.45, -0.55), Vector3(-0.3, -1.0, 0.2)],
			[0.34, Vector3(-0.08, -0.34, -0.46), Vector3(-1.0, -0.8, -0.35), Vector3(-0.4, -1.0, 0.4)],
			[SWING_TIME, null],
		]
	else:
		# The syringe comes up from the lower left and stabs forward toward the middle of the view.
		keys = [
			[0.0, null],
			[0.12, Vector3(-0.16, -0.18, -0.34), Vector3(1.0, 0.0, -0.3), Vector3(-0.3, -0.3, 1.0)],
			[0.2, Vector3(-0.06, -0.1, -0.5), Vector3(1.0, 0.0, -0.3), Vector3(-0.3, -0.22, 1.0)],
			[0.28, Vector3(-0.06, -0.1, -0.49), Vector3(1.0, 0.0, -0.3), Vector3(-0.3, -0.22, 1.0)],
			[JAB_TIME, null],
		]
	for i in range(1, keys.size()):
		if t <= float(keys[i][0]) or i == keys.size() - 1:
			var t0 := float(keys[i - 1][0])
			var t1 := float(keys[i][0])
			var u := clampf((t - t0) / maxf(0.001, t1 - t0), 0.0, 1.0)
			u = u * u * (3.0 - 2.0 * u)
			var from := _key_pose(keys[i - 1], rest, third)
			var to := _key_pose(keys[i], rest, third)
			return from.interpolate_with(to, u)
	return rest


static func _key_pose(key: Array, rest: Transform3D, third: bool) -> Transform3D:
	if key.size() < 4 or key[1] == null:
		return rest
	var x: Vector3 = (key[2] as Vector3).normalized()
	var z: Vector3 = key[3]
	z = (z - x * z.dot(x)).normalized()
	var o: Vector3 = key[1]
	if third:
		o = Vector3(o.x * 1.6, 1.4 + o.y * 1.5, o.z * 1.2 - 0.4)   # out in front of the body's (big) head
	return Transform3D(Basis(x, z.cross(x), z), o)


## A syringe drawn from the vial for the jab: the needle points along -Z.
static func make_syringe() -> Node3D:
	var root := Node3D.new()
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.85, 0.93, 0.97, 0.55)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.1
	var liquid := StandardMaterial3D.new()
	liquid.albedo_color = Color(0.95, 0.85, 0.35)
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.85, 0.87, 0.9)
	steel.metallic = 0.8
	steel.roughness = 0.3
	var parts := [
		[0.011, 0.11, glass, Vector3(0.0, 0.0, 0.0)],
		[0.008, 0.07, liquid, Vector3(0.0, 0.0, -0.015)],
		[0.004, 0.06, steel, Vector3(0.0, 0.0, 0.08)],     # plunger rod
		[0.014, 0.004, steel, Vector3(0.0, 0.0, 0.11)],    # thumb rest
		[0.0012, 0.06, steel, Vector3(0.0, 0.0, -0.085)],  # needle
	]
	for e in parts:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = float(e[0])
		cyl.bottom_radius = float(e[0])
		cyl.height = float(e[1])
		cyl.radial_segments = 8
		cyl.rings = 1
		mi.mesh = cyl
		mi.material_override = e[2]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		mi.position = e[3]
		root.add_child(mi)
	root.scale = Vector3.ONE * 1.6
	return root


# =========================================================================
# networking and events
# =========================================================================

## Host -> clients in the global snapshot `cb`: only the fallback sedated set (the monsters API
## replicates its own `sd`). Drags ride on the players (`dm`).
func net_state() -> Dictionary:
	if _fb_sedated.is_empty():
		return {}
	var ids: Array = _fb_sedated.keys()
	ids.sort()
	return {"s": ids}


func apply_net_state(s: Dictionary) -> void:
	if game.is_host():
		return
	var want := {}
	for id in s.get("s", []):
		want[int(id)] = 0.0
	_fb_sedated = want


func on_event(kind: String, data: Dictionary) -> void:
	match kind:
		"cb_swing":
			var p = game.players.get(int(data.get("id", 0)))
			if p == null or not is_instance_valid(p):
				return
			if p.is_local and _anim_recent(p):
				return   # already playing: this machine started it on the click
			_start_anim(p, String(data.get("k", "saw")))


## Host: every monster is about to be freed (clock-out, new level).
func on_monsters_cleared() -> void:
	if game != null:
		for p in game.players.values():
			if is_instance_valid(p) and "dragging_monster" in p:
				p.dragging_monster = -1
	_holds.clear()
	_fb_hits.clear()
	_fb_sedated.clear()
	_aims.clear()
	_lying.clear()


## Host: one monster is leaving the game (killed, or strapped onto a table).
func on_monster_removed(m: Node) -> void:
	if m == null:
		return
	var id: int = m.monster_id
	if game != null:
		for p in game.players.values():
			if is_instance_valid(p) and dragging(p) == id:
				p.dragging_monster = -1
	_fb_hits.erase(id)
	_fb_sedated.erase(id)
	_aims.erase(id)
	_lying.erase(id)
