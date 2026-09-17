extends Node
## Saved patients leaving (patient exits, 2026-09-16): a couple of seconds after a patient is stable
## they get up off the table, turn to whoever operated, say thanks (a subtitle everyone sees) and
## walk out of the building through the main doors into the fog: Bob on his feet, the seal
## belly-flopping. Nothing stops them. They keep going through the clock-out and the next lobby
## until they are gone into the fog.
##
## The host runs it; `net_state()` rides in the loop's replication ("lp.wk") and every machine shows
## the walkers from it. Getting up frees the table (the case stays, `table` -1, `left` true, for the
## paycheck).

const HM := preload("res://scripts/human/human_model.gd")
const BodyScript := preload("res://scripts/patient_body.gd")

const WAKE_SECONDS := 2.5
const THANK_SECONDS := 2.8
const HUMAN_SPEED := 1.25
const SEAL_SPEED := 0.85
const GIVE_UP_SECONDS := 150.0

const LINES := {
	"human": [
		"Thanks, %s. I owe you one.",
		"%s, you're a miracle worker. A scary one, but still.",
		"I can feel my... most of me. Thanks, %s.",
		"Thanks, %s. I'm never doing that again.",
		"%s. Thank you. I'm going home.",
	],
	"seal": [
		"*grateful honk at %s*",
		"*slaps a flipper on the floor for %s*",
		"*happy bark in %s's direction*",
	],
}

var loop: Node = null
var game: Node = null
## Host truth, replicated: id -> {p: Vector3, y, ph: "thank" | "walk", pid, ail, flags}
var walkers := {}
var _pending := {}   # host: case id -> {at: world_time, thank: peer id}
var _paths := {}     # host: id -> {pts, i, age, t}
var _nodes := {}     # every machine: id -> {node, human: bool, ap, clip, shown_p, shown_y, walk_t}


func setup(l: Node) -> void:
	loop = l
	game = l.game


## Host (game.finish_case): a patient pulled through. `thank`: the peer who operated last, 0 if nobody.
func schedule(c: Dictionary, thank: int) -> void:
	if not game.is_host():
		return
	if Procedures.is_monster(String(c.get("patient_id", ""))) or String(c.get("patient_id", "")) == "player":
		return
	_pending[int(c.id)] = {"at": float(game.world_time) + WAKE_SECONDS, "thank": thank}


func clear() -> void:
	walkers.clear()
	_pending.clear()
	_paths.clear()
	_sync_nodes(0.0)


# ---------------------------------------------------------------------------
# host

func host_tick(delta: float) -> void:
	if not game.is_host():
		return
	for id in _pending.keys():
		if float(game.world_time) >= float(_pending[id].at):
			var thank := int(_pending[id].thank)
			_pending.erase(id)
			_get_up(int(id), thank)
	for id in walkers.keys():
		var w: Dictionary = walkers[id]
		var path: Dictionary = _paths.get(id, {})
		path.age = float(path.get("age", 0.0)) + delta
		_paths[id] = path
		if float(path.age) > GIVE_UP_SECONDS:
			_forget(id)
			continue
		match String(w.ph):
			"thank":
				path.t = float(path.get("t", 0.0)) + delta
				if float(path.t) >= THANK_SECONDS:
					w.ph = "walk"
					path.pts = _exit_path(w.p)
					path.i = 1
			"walk":
				if _walk(w, path, delta, SEAL_SPEED if _is_seal(String(w.pid)) else HUMAN_SPEED):
					_forget(id)


func _get_up(id: int, thank: int) -> void:
	var c: Dictionary = game.case_by_id(id)
	if c.is_empty() or String(c.state) != "stable" or int(c.get("table", -1)) < 0:
		return
	var table := int(c.table)
	var spot: Vector3 = loop._stand_spot(table, loop.arrival_point())
	var who = game.players.get(thank)
	if who == null or not is_instance_valid(who) or not who.alive:
		who = _nearest_player(spot)
	var face: Vector3 = who.global_position if who != null else loop.arrival_point()
	walkers[id] = {"p": spot, "y": loop._yaw_along(spot, face), "ph": "thank", "pid": String(c.patient_id),
		"ail": String(c.get("ailment_id", "")), "flags": (c.get("flags", {}) as Dictionary).duplicate()}
	_paths[id] = {"age": 0.0, "t": 0.0}
	c["table"] = -1
	c["left"] = true
	game._apply_cases_locally()
	var kind := "seal" if _is_seal(String(c.patient_id)) else "human"
	var pool: Array = LINES[kind]
	var name := String(Procedures.patient(String(c.patient_id)).get("name", "Patient")).to_upper()
	var line := String(pool[randi() % pool.size()]) % (who.player_name if who != null else "doc")
	game.say("%s: %s" % [name, line], 4.0)


func _nearest_player(at: Vector3) -> Node:
	var best: Node = null
	var best_d := INF
	for p in game.players.values():
		if not p.alive:
			continue
		var d: float = p.global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = p
	return best


## Out the main doors to the ambulance bay, then on down the lane into the fog.
func _exit_path(from: Vector3) -> PackedVector3Array:
	var info: Dictionary = game.level_info
	var doors: Vector3 = loop.arrival_point()
	var e = info.get("entrance")
	if e is Dictionary and e.has("position"):
		doors = e.position
	var pts: PackedVector3Array = loop._nav_path(from, doors)
	var amb = info.get("ambulance")
	if amb is Dictionary and amb.has("position"):
		pts.append(amb.position)
		if amb.has("lane_start"):
			pts.append(amb.lane_start)
	return pts


func _walk(w: Dictionary, path: Dictionary, delta: float, speed: float) -> bool:
	var pts: PackedVector3Array = path.get("pts", PackedVector3Array())
	var i := int(path.get("i", 1))
	var step := speed * delta
	var pos: Vector3 = w.p
	while i < pts.size() and step > 0.0:
		var to := pts[i] - pos
		to.y = 0.0
		var d := to.length()
		if d <= step:
			pos = Vector3(pts[i].x, pts[i].y, pts[i].z)
			step -= d
			i += 1
		else:
			pos += to / d * step
			pos.y = lerpf(pos.y, pts[i].y, 0.2)
			step = 0.0
			w.y = lerp_angle(float(w.y), atan2(-to.x, -to.z), 0.2)
	w.p = pos
	path.i = i
	return i >= pts.size()


func _forget(id) -> void:
	walkers.erase(id)
	_paths.erase(id)


static func _is_seal(pid: String) -> bool:
	return String(Procedures.patient(pid).get("body", pid)) == "seal"


# ---------------------------------------------------------------------------
# replication

func net_state() -> Dictionary:
	var out := {}
	for id in walkers.keys():
		var w: Dictionary = walkers[id]
		out[id] = [(w.p as Vector3).snappedf(0.02), snappedf(float(w.y), 1.0 / 64.0), String(w.ph), String(w.pid), String(w.ail), w.get("flags", {})]
	return out


func apply_net_state(s: Dictionary) -> void:
	if game.is_host():
		return
	walkers.clear()
	for id in s.keys():
		var a: Array = s[id]
		if a.size() >= 6:
			walkers[int(id)] = {"p": a[0], "y": float(a[1]), "ph": String(a[2]), "pid": String(a[3]), "ail": String(a[4]), "flags": a[5]}


# ---------------------------------------------------------------------------
# every machine: the people walking out

func local_tick(delta: float) -> void:
	_sync_nodes(delta)


func _sync_nodes(delta: float) -> void:
	for id in _nodes.keys():
		if not walkers.has(id):
			var n = _nodes[id].node
			if n != null and is_instance_valid(n):
				n.queue_free()
			_nodes.erase(id)
	if game == null or game.get_node_or_null("Entities") == null:
		return
	for id in walkers.keys():
		var w: Dictionary = walkers[id]
		var e: Dictionary = _nodes.get(id, {})
		if e.is_empty():
			e = _make(w)
			if e.is_empty():
				continue
			_nodes[id] = e
		var target: Vector3 = w.p
		var k := clampf(delta * 8.0, 0.0, 1.0)
		var moving: bool = (e.shown_p as Vector3).distance_to(target) > 0.01 or String(w.ph) == "walk"
		e.shown_p = (e.shown_p as Vector3).lerp(target, k) if (e.shown_p as Vector3).distance_to(target) < 3.0 else target
		e.shown_y = lerp_angle(float(e.shown_y), float(w.y), k)
		var node: Node3D = e.node
		if bool(e.human):
			node.global_position = e.shown_p
			node.rotation.y = float(e.shown_y)
			var want := "Walk" if String(w.ph) == "walk" else "Idle"
			if e.ap != null and want != String(e.clip):
				e.clip = want
				(e.ap as AnimationPlayer).play(want, 0.35)
				(e.ap as AnimationPlayer).speed_scale = HUMAN_SPEED / 1.4 if want == "Walk" else 1.0
		else:
			# The seal: flopping along on its belly, a hop and a rock every stride.
			e.walk_t = float(e.walk_t) + delta * (7.0 if String(w.ph) == "walk" else 0.0)
			var hop := absf(sin(float(e.walk_t))) * 0.14
			node.global_position = (e.shown_p as Vector3) + Vector3.UP * (0.05 + hop)
			node.rotation = Vector3(0.0, float(e.shown_y) - PI * 0.5, sin(float(e.walk_t) * 2.0) * 0.12 if moving else 0.0)


func _make(w: Dictionary) -> Dictionary:
	var pid := String(w.pid)
	var holder := game.get_node("Entities")
	if not _is_seal(pid) and HM.available("bob"):
		var rig: Node3D = HM.spawn("bob", HM.BAKED_TINT, true)
		if rig != null:
			var root := Node3D.new()
			root.name = "Leaving_%s" % pid
			holder.add_child(root)
			root.add_child(rig)
			HM.loop_clips(rig)
			var ap := HM.anim_player(rig)
			# What the operation did stays done: the forearm is gone after an amputation.
			if String(w.ail) == "amputation":
				HM.show_piece(rig, "Human_Forearm_R", false)
			if ap != null:
				ap.play("Idle")
			root.global_position = w.p
			return {"node": root, "human": true, "ap": ap, "clip": "Idle", "shown_p": w.p, "shown_y": float(w.y), "walk_t": 0.0}
	var body: Node3D = BodyScript.create(pid)
	body.name = "Leaving_%s" % pid
	holder.add_child(body)
	if body.has_method("set_ailment"):
		body.set_ailment(String(w.ail))
	if body.has_method("apply_flags") and w.get("flags") is Dictionary:
		body.apply_flags(w.flags)
	if body.has_method("set_vitals"):
		body.set_vitals(100.0)
	body.global_position = w.p
	return {"node": body, "human": false, "ap": null, "clip": "", "shown_p": w.p, "shown_y": float(w.y), "walk_t": 0.0}
