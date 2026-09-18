extends RefCounted
## A bot ally's brain, host only. It drives a real Player through the `bot_*` test seam
## (bot_move / bot_yaw / bot_aim_id / bot_press), the same way tools/playtest.gd plays, so it
## interacts through the game's own rules: reach checks, prompts, hands, the shelf, surgery.
##
## Orders
##   follow   walk after its owner and stand nearby
##   stay     stand still
##   carry    get a stack of `item` (loose, in a container, or from a dispenser) and bring it
##            to the OR's storage shelves (`to` = "shelf") or put it in its owner's hands
##            (`to` = "player")
##   operate  do the current surgery step: get the step's item into its own hands first (a step's
##            tool is used from the operator's hands), then operate with the minigame's bot input
##            (see the dev hook in surgery_system.gd)
## A finished carry or operate bumps `completed` and the bot falls back to stay.

const REACH := 1.6
const FOLLOW_NEAR := 2.2
const PRESS_EVERY := 0.45

var dev: Node
var game: Node
var p: Node
var order := "stay"
var item := "gauze"
var to := "shelf"
var owner_id := 1
var skill := 1.0
## What it is doing, for the panel.
var status := "standing by"
## Finished carry / operate jobs.
var completed := 0

var _path := PackedVector3Array()
var _repath := 0.0
var _goal := Vector3.INF
var _press_cd := 0.0
var _stuck := 0.0
var _last_pos := Vector3.ZERO
var _delivering := false
var _op_key := ""
var _op_table := -1
var _gave := false


func _init(dev_room: Node, player: Node) -> void:
	dev = dev_room
	game = dev_room.game
	p = player


func set_order(new_order: String, kind: String = "", target: String = "", owner: int = 0) -> void:
	order = new_order
	if kind != "":
		item = kind
	if target != "":
		to = target
	if owner != 0:
		owner_id = owner
	_delivering = false
	_op_key = ""
	_op_table = -1
	_gave = false
	_stuck = 0.0
	_path = PackedVector3Array()
	status = order


func tick(delta: float) -> void:
	if p == null or not is_instance_valid(p):
		return
	_press_cd = maxf(0.0, _press_cd - delta)
	p.bot_interact = false
	if not p.alive:
		_halt()
		status = "dead"
		return
	# downed hook: a downed bot lies there (carried, on the table, or bleeding on the floor).
	if p.downed:
		_halt()
		p.bot_interact = false
		status = "on the table" if p.on_table else ("being carried" if p.carried_by != 0 else "downed")
		return
	if p.stun > 0.0:
		_halt()
		status = "knocked down"
		return
	match order:
		"follow":
			_follow(delta)
		"carry":
			if to == "table":
				_carry_downed(delta)
			elif _carry(delta, item, to):
				_done("delivered %s" % Items.display_name(item))
		"operate":
			# downed hook: a teammate on the player table comes before the patient.
			if game.player_surgery.patient() != null:
				_operate_player_table(delta)
			else:
				_operate(delta)
		_:
			_halt()
			status = "staying"


func _done(what: String) -> void:
	completed += 1
	order = "stay"
	status = what
	_halt()


# ---------------------------------------------------------------------------
# orders

func _follow(delta: float) -> void:
	var who = _owner()
	if who == null:
		_halt()
		status = "nobody to follow"
		return
	var d: float = _flat(who.global_position).distance_to(_flat(p.global_position))
	if d > FOLLOW_NEAR:
		_walk_to(who.global_position, delta)
		status = "following %s" % who.player_name
	else:
		_halt()
		_face(who.global_position)


## One step of fetching and delivering. Returns true once the delivery landed.
func _carry(delta: float, kind: String, target: String) -> bool:
	var shelf := _storage()
	if target == "shelf" and shelf == null:
		target = "player"
	var hand := _hand_with(kind)
	if hand < 0:
		if _delivering:
			_delivering = false
			if target == "shelf":
				return true   # it left our hands at the shelves
			if target == "player" and _gave:
				return true
		_fetch(delta, kind)
		return false
	p.selected = hand
	if not _delivering:
		_delivering = true
		_gave = false
	if target == "shelf":
		status = "taking %s to the shelves" % Items.display_name(kind)
		_go_use(String(shelf.get_meta("interact_id")), shelf.global_position, delta)
		return false
	var who = _owner()
	if who == null or not who.alive:
		status = "nobody to hand it to"
		_halt()
		return false
	status = "bringing %s to %s" % [Items.display_name(kind), who.player_name]
	if _flat(who.global_position).distance_to(_flat(p.global_position)) > REACH + 0.2:
		_walk_to(who.global_position, delta)
		return false
	_halt()
	_face(who.global_position)
	_gave = dev.hand_over(p, who, hand)
	return false


func _fetch(delta: float, kind: String) -> void:
	status = "looking for %s" % Items.display_name(kind)
	# Hands full of something else: put one down.
	if not p.can_take(kind):
		p.selected = 0
		p.drop_count += 1
		return
	var best_id := ""
	var best_pos := Vector3.ZERO
	var best_d := INF
	for it in game.world_items.values():
		if it.kind != kind or not is_instance_valid(it):
			continue
		var id := "it_%d" % it.item_id
		var pos: Vector3 = it.global_position
		if it.state == WorldItem.State.IN_CONTAINER:
			var ct = game.find_interactable(it.container_id)
			if ct != null and ct.has_method("is_open") and not ct.is_open():
				id = it.container_id
				pos = ct.global_position
		var d := pos.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best_id = id
			best_pos = pos
	var disp = game.find_interactable("dev_disp_%s" % kind)
	if disp != null and dev.in_room(p.global_position):   # the room's floor doesn't reach the hospital
		var dd: float = disp.global_position.distance_to(p.global_position)
		# Prefer a dispenser unless the loose stack is clearly closer.
		if best_id == "" or dd < best_d + 3.0:
			best_id = "dev_disp_%s" % kind
			best_pos = disp.global_position
	if best_id == "":
		status = "no %s anywhere" % Items.display_name(kind)
		_halt()
		return
	_go_use(best_id, best_pos, delta)


func _operate(delta: float) -> void:
	# loop: pick a table with a patient nobody else is operating on, and stick with it.
	var c: Dictionary = game.case_on_table(_op_table) if _op_table >= 0 else {}
	if _op_key == "" and (c.is_empty() or String(c.get("state", "")) != "on_table"):
		_op_table = -1
		for t in game.patient_tables:
			var tc: Dictionary = game.case_on_table(int(t.index))
			var sys = game.surgery_for_table(int(t.index))
			if not tc.is_empty() and String(tc.state) == "on_table" and String(tc.patient_id) != "player" \
					and sys != null and (int(sys.operator_id) == 0 or int(sys.operator_id) == p.peer_id):
				_op_table = int(t.index)
				c = tc
				break
	if c.is_empty():
		if _op_key != "":
			_done("finished the step")
			return
		_halt()
		status = "no patient on the table"
		return
	var key := "%d|%s|%s|%d" % [int(c.id), c.patient_id, c.ailment_id, int(c.step_index)]
	if _op_key == "":
		_op_key = key
	if key != _op_key or String(c.state) != "on_table":
		_done("finished the step")
		return
	var step := Procedures.step(c.ailment_id, int(c.step_index))
	if step.is_empty():
		_done("nothing left to do")
		return
	if p.operating:
		_halt()
		status = "operating: %s" % step.label
		return
	if not _hold(delta, String(step.item), maxi(1, int(step.get("uses", 0)))):
		return
	status = "walking to the table"
	p.set_meta("bot_skill", skill)
	_go_use(game.table_interact_id(_op_table), game.table_position(_op_table), delta)


## downed hook: find a downed player, hold E to lift them, walk to the player table and lay them on it.
func _carry_downed(delta: float) -> void:
	if p.carrying != 0:
		var who = game.players.get(p.carrying)
		status = "carrying %s to the table" % (who.player_name if who != null else "someone")
		if game.downed_any_table:
			# The hospital: whichever patient table is free.
			var ti: int = game.free_patient_table()
			if ti < 0:
				_halt()
				status = "no free table for %s" % (who.player_name if who != null else "someone")
				return
			_go_use(game.table_interact_id(ti), game.table_position(ti), delta)
			return
		if game.player_table.is_empty():
			_halt()
			return
		_go_use("player_table", game.player_table.position, delta)
		return
	for other in game.players.values():
		if other.on_table and _was_carrying == other.peer_id:
			_was_carrying = 0
			_done("put %s on the table" % other.player_name)
			return
	var target: Node = null
	var best := INF
	for other in game.players.values():
		if game.can_pick_up(p, other, false):
			var d: float = other.global_position.distance_to(p.global_position)
			if d < best:
				best = d
				target = other
	if target == null:
		_halt()
		p.bot_interact = false
		status = "nobody downed to carry"
		return
	if not p.hands_empty():
		for i in p.slots.size():
			if String(p.slots[i].kind) != "":
				p.selected = i
				break
		p.drop_count += 1
		return
	status = "lifting %s" % target.player_name
	p.bot_aim_id = "pl_%d" % target.peer_id
	var d2: float = _flat(target.global_position).distance_to(_flat(p.global_position))
	if d2 > REACH:
		p.bot_interact = false
		_walk_to(target.global_position, delta)
		return
	_halt()
	_face(target.global_position)
	p.bot_interact = true
	_was_carrying = target.peer_id


var _was_carrying := 0


## downed hook: get a suture kit in hand, then stitch up whoever lies on the player table.
func _operate_player_table(delta: float) -> void:
	var patient = game.player_surgery.patient()
	if patient == null:
		_done("finished at the player table")
		return
	if p.operating:
		_halt()
		status = "stitching up %s" % patient.player_name
		return
	var step := Procedures.step("stitches", int(game.player_surgery.case.get("step_index", 0)))
	if step.is_empty():
		_done("stitched up %s" % patient.player_name)
		return
	if not _hold(delta, String(step.item), maxi(1, int(step.get("uses", 0)))):
		return
	status = "walking to the player table"
	p.set_meta("bot_skill", skill)
	if game.downed_any_table and game.player_table.has("index"):
		var ti := int(game.player_table.index)   # the hospital: the patient table they lie on
		_go_use(game.table_interact_id(ti), game.table_position(ti), delta)
		return
	_go_use("player_table", game.player_table.position, delta)


# ---------------------------------------------------------------------------
# movement and pressing E

func _owner() -> Node:
	var who = game.players.get(owner_id)
	if who == null or not is_instance_valid(who):
		who = game.local_player()
	return who


func _hand_with(kind: String) -> int:
	for i in p.slots.size():
		if p.slots[i].kind == kind:
			return i
	return -1


## Walk within reach of an interactable, look at it and press E.
func _go_use(id: String, pos: Vector3, delta: float) -> void:
	p.bot_aim_id = id
	var d: float = _flat(pos).distance_to(_flat(p.global_position))
	var close := d <= REACH
	if not close and _stuck > 1.2:
		var node = game.find_interactable(id)
		close = node != null and game._within_reach(p, node) and d < C.INTERACT_RANGE + 0.6
	if not close:
		_walk_to(pos, delta)
		return
	_halt()
	_stuck = 0.0
	_face(pos)
	if _press_cd <= 0.0 and p.aim_id == id and not p.aim_prompt.begins_with("!"):
		p.bot_press += 1
		_press_cd = PRESS_EVERY


func _walk_to(target: Vector3, delta: float) -> void:
	if target.distance_to(_goal) > 0.5:
		_goal = target
		_repath = 0.0
	_repath -= delta
	var map: RID = p.get_world_3d().navigation_map
	if _repath <= 0.0:
		_repath = 0.5
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			var goal_on_nav := NavigationServer3D.map_get_closest_point(map, target)
			_path = NavigationServer3D.map_get_path(map, p.global_position, goal_on_nav, true)
	var next: Vector3 = target
	for q in _path:
		if Vector2(q.x - p.global_position.x, q.z - p.global_position.z).length() > 0.6:
			next = q
			break
	var to_next: Vector3 = next - p.global_position
	to_next.y = 0.0
	if to_next.length() < 0.05:
		_halt()
		return
	p.bot_yaw = atan2(-to_next.x, -to_next.z)
	p.bot_pitch = 0.0
	p.bot_move = Vector2(0, -1)
	p.bot_sprint = to_next.length() > 6.0
	if p.global_position.distance_to(_last_pos) > 0.03:
		_last_pos = p.global_position
		_stuck = 0.0
	else:
		_stuck += delta


func _halt() -> void:
	p.bot_move = Vector2.ZERO
	p.bot_sprint = false


func _face(pos: Vector3) -> void:
	var to_p: Vector3 = pos - p.global_position
	if Vector2(to_p.x, to_p.z).length() > 0.05:
		p.bot_yaw = atan2(-to_p.x, -to_p.z)


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## 2026-09-18: the step's item in our own hands and selected, `need` of it; fetches it otherwise.
## True once it is.
func _hold(delta: float, kind: String, need: int) -> bool:
	var hand := _hand_with(kind)
	if hand >= 0 and int(p.slots[hand].count) >= need:
		p.selected = hand
		return true
	_fetch(delta, kind)
	return false


## The OR's first storage shelf, or null.
func _storage() -> Node3D:
	for ct in game.storage_nodes:
		if is_instance_valid(ct):
			return ct
	return null
