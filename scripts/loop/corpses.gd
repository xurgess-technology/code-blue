extends Node
## The dead (patient exits, 2026-09-16): anyone who dies on a patient table (a patient who
## flatlined, or a strapped monster at the end of its dissection) stays there as a body until a
## player carries it to the crematorium and puts it in the furnace. Clocking out waits for every
## body (shift_loop.gd). Burning a body pays nothing.
##
## A body is its case in `game.cases`, so it replicates with the cases: `table` -1 once it is off the
## table, `bc` the carrier's peer id (0 none), `bp` / `by` where it lies on the floor, `cremated` once
## it is gone. The carrier's `Player.carrying` holds BODY_BASE - the case id (the downed teammate carry
## otherwise: slower, over the shoulder, dropped when hit).
##
## Host: lift(q, id), put_down(q), cremate(q). Every machine: the bodies' nodes off the table (over a
## carrier's shoulder, on the floor with a lift proxy), and the slide into the fire ("cremate" event).

const BodyScript := preload("res://scripts/patient_body.gd")
const HM := preload("res://scripts/human/human_model.gd")

## Player.carrying at or below this is a body (BODY_BASE - case id); anything else non-zero is a
## teammate's id. Far below every id a player can have: peer ids are positive up to 2^31 - 1 (a
## client's is a large random one) and bots and dummies are small negatives.
const BODY_BASE := -1000000000
const PROXY_PREFIX := "corpse_"
const SLIDE_SECONDS := 1.9
## Where a body without a Carried clip rests in the carrier's frame (x right): its middle out over the
## left shoulder, so the end across the back stays left of the over-the-shoulder crosshair.
const SHOULDER_AT := Vector3(-0.38, 1.62, 0.18)

var game: Node = null
var _nodes := {}          # case id -> {node, proxy}
var _sliding: Array = []  # [{node, t, from: Transform3D, window: Vector3, inside: Vector3}]


func setup(g: Node) -> void:
	game = g


# ---------------------------------------------------------------------------
# queries (every machine)

static func is_body(carrying: int) -> bool:
	return carrying <= BODY_BASE


## A finished case that is a body still in the building: a death, or a strapped monster whose
## dissection ended (it dies on the table either way).
static func is_corpse(c: Dictionary) -> bool:
	if c.is_empty() or bool(c.get("cremated", false)) or String(c.get("patient_id", "")) == "player":
		return false
	var st := String(c.get("state", ""))
	if st == "dead":
		return true
	return st == "stable" and Procedures.is_monster(String(c.get("patient_id", "")))


func corpse_by_id(id: int) -> Dictionary:
	var c: Dictionary = game.case_by_id(id)
	return c if is_corpse(c) else {}


## "Bob's body", "the seal's body".
static func label(c: Dictionary) -> String:
	var n := String(Procedures.patient(String(c.get("patient_id", ""))).get("name", "The patient"))
	if n.begins_with("The "):
		n = "the " + n.substr(4)
	return "%s's body" % n


func carried_label(q: Node) -> String:
	var c := corpse_by_id(BODY_BASE - int(q.carrying))
	return label(c) if not c.is_empty() else "the body"


## The first body still in the building, or {} (shift_loop's clock-out rule).
func any_left() -> Dictionary:
	for c in game.cases:
		if is_corpse(c):
			return c
	return {}


## The body a player aiming at `aim` would lift: the corpse proxy on the floor, or a dead case lying
## on the aimed patient table. {} for none.
func aimed_body(aim: String) -> Dictionary:
	if aim.begins_with(PROXY_PREFIX):
		var c := corpse_by_id(int(aim.substr(PROXY_PREFIX.length())))
		return c if not c.is_empty() and int(c.get("table", -1)) < 0 and int(c.get("bc", 0)) == 0 else {}
	if aim.begins_with("table"):
		for t in game.patient_tables:
			if game.table_interact_id(int(t.index)) == aim:
				var c: Dictionary = game.case_on_table(int(t.index))
				return c if is_corpse(c) else {}
	return {}


func lift_prompt(q: Node, c: Dictionary) -> String:
	if q.carrying != 0 or not q.hands_empty():
		return "!Empty your hands to carry %s." % label(c)
	return "Hold E: lift %s" % label(c)


# ---------------------------------------------------------------------------
# host

func can_lift(q: Node, c: Dictionary) -> bool:
	return is_corpse(c) and q != null and q.alive and not q.downed and q.carrying == 0 and q.carried_by == 0 \
			and q.hands_empty() and int(c.get("bc", 0)) == 0 and (game.combat == null or game.combat.dragging(q) < 0)


func lift(q: Node, id: int) -> void:
	var c := corpse_by_id(id)
	if not game.is_host() or not can_lift(q, c):
		return
	c["table"] = -1
	c["bc"] = int(q.peer_id)
	q.carrying = BODY_BASE - id
	game._end_operations(q)
	q.refresh_downed_visuals()
	game._apply_cases_locally()
	game._sound("downed_lift", q.global_position)


## Host: the carrier sets the body down on the floor in front of them.
func put_down(q: Node) -> void:
	if not game.is_host() or q == null:
		return
	var c := corpse_by_id(BODY_BASE - int(q.carrying))
	q.carrying = 0
	q.refresh_downed_visuals()
	if c.is_empty():
		return
	var fwd: Vector3 = -q.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var spot: Vector3 = q.global_position + fwd * 0.9
	if not game._point_is_clear(spot):
		spot = q.global_position
	spot = game._floor_at(spot)
	c["bc"] = 0
	c["bp"] = spot
	c["by"] = q.rotation.y + PI * 0.5
	game._apply_cases_locally()
	game._sound("thud", spot)


## Host: the carrier pressed E. At the furnace's window: into the fire. Anywhere else: down.
func carrier_pressed(q: Node, aim: String) -> void:
	var furnace: Node3D = game.economy.furnace if game.economy != null else null
	if aim == "furnace_hatch" and furnace != null and is_instance_valid(furnace):
		var node: Node = game.find_interactable("furnace_hatch")
		if node != null and game._within_reach(q, node):
			cremate(q)
			return
	put_down(q)


func cremate(q: Node) -> void:
	var furnace: Node3D = game.economy.furnace if game.economy != null else null
	var id := BODY_BASE - int(q.carrying)
	var c := corpse_by_id(id)
	if not game.is_host() or c.is_empty() or furnace == null:
		return
	var from := shoulder_pose(q)
	q.carrying = 0
	q.refresh_downed_visuals()
	c["bc"] = 0
	c["cremated"] = true
	if not furnace.hatch_open:
		furnace.set_hatch(true)
	game._apply_cases_locally()
	var data := {"pid": String(c.patient_id), "ail": String(c.get("ailment_id", "")), "from": from, "by": int(q.peer_id)}
	play_cremation(data)
	game._broadcast("cremate", data)
	# A monster's case has nothing left to pay or show: it goes once it is burning.
	if Procedures.is_monster(String(c.patient_id)):
		game.remove_case(id)


# ---------------------------------------------------------------------------
# every machine: the nodes

## A body without a Carried clip (the seal, a monster): across the carrier's shoulders, face down,
## shifted onto the LEFT shoulder (the over-the-shoulder carry camera looks over the right one).
## The furnace roll-off starts from here too.
func shoulder_pose(q: Node) -> Transform3D:
	var cb := Basis(Vector3.UP, q.rotation.y)
	var b := cb * Basis(Vector3.RIGHT, PI)
	return Transform3D(b, q.global_position + cb * SHOULDER_AT)


## Bob and the other human patients: his own model on the Carried clip over the carrier's left
## shoulder, placed the way a carried teammate is (Player.human_carried_pose, mirrored).
static func _human(pid: String) -> bool:
	return not Procedures.is_monster(pid) and String(Procedures.patient(pid).get("body", pid)) != "seal" and HM.available("bob")


func _process(delta: float) -> void:
	if game == null:
		return
	_sync_nodes()
	_tick_slides(delta)


func _sync_nodes() -> void:
	var want := {}
	for c in game.cases:
		if is_corpse(c) and int(c.get("table", -1)) < 0:
			want[int(c.id)] = c
	for id in _nodes.keys():
		if not want.has(id):
			_free(id)
	for id in want.keys():
		var c: Dictionary = want[id]
		var e: Dictionary = _nodes.get(id, {})
		if e.is_empty():
			var body: Node3D = BodyScript.create(String(c.patient_id))
			if body.has_method("set_ailment"):
				body.set_ailment(String(c.get("ailment_id", "")))
			if body.has_method("apply_flags") and c.get("flags") is Dictionary:
				body.apply_flags(c.flags)   # what the operation already did stays done
			if body.has_method("set_vitals"):
				body.set_vitals(0.0)
			game.get_node("Entities").add_child(body)
			e = {"node": body, "proxy": null}
			_nodes[id] = e
		var node: Node3D = e.node
		var carrier = game.players.get(int(c.get("bc", 0)))
		if carrier != null and is_instance_valid(carrier):
			var slung: Node3D = _slung(e, c)
			if slung != null:
				node.visible = false
				slung.visible = true
				slung.global_transform = Player.human_carried_pose(carrier)
			else:
				node.global_transform = shoulder_pose(carrier)
			if e.proxy != null:
				(e.proxy as Node).queue_free()
				e.proxy = null
		else:
			node.visible = true
			if e.get("slung") != null and is_instance_valid(e.slung):
				(e.slung as Node3D).visible = false
			var at: Vector3 = c.get("bp", game.table_pos())
			node.global_transform = Transform3D(Basis(Vector3.UP, float(c.get("by", 0.0))), at + Vector3.UP * 0.12)
			if e.proxy == null:
				e.proxy = _make_proxy(int(id))
			(e.proxy as Node3D).global_position = at + Vector3.UP * 0.35


## The Carried-clip model for a human body, made the first time it is carried. null otherwise.
func _slung(e: Dictionary, c: Dictionary) -> Node3D:
	if e.get("slung") != null and is_instance_valid(e.slung):
		return e.slung
	if not _human(String(c.patient_id)):
		return null
	var rig: Node3D = HM.spawn("bob", HM.BAKED_TINT, true)
	if rig == null:
		return null
	HM.loop_clips(rig)
	var ap := HM.anim_player(rig)
	if ap != null and ap.has_animation("Carried"):
		ap.play("Carried")
	if String(c.get("ailment_id", "")) == "amputation" and bool((c.get("flags", {}) as Dictionary).get("amputated", false)):
		HM.show_piece(rig, "Human_Forearm_R", false)
	var skin := HM.skin_of(rig)
	if skin != null:
		skin.set_shader_parameter(&"pallor", 1.0)
		skin.set_shader_parameter(&"grey", 0.6)
	game.get_node("Entities").add_child(rig)
	e["slung"] = rig
	return rig


func _make_proxy(id: int) -> Area3D:
	var a := LiftProxy.new()
	a.corpses = self
	a.case_id = id
	a.name = "Aim_%s%d" % [PROXY_PREFIX, id]
	a.collision_layer = C.L_INTERACT
	a.collision_mask = 0
	a.monitoring = false
	a.add_to_group("interactable")
	a.set_meta("interact_id", "%s%d" % [PROXY_PREFIX, id])
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 0.6, 1.0)
	cs.shape = box
	a.add_child(cs)
	game.get_node("Entities").add_child(a)
	return a


func _free(id) -> void:
	var e: Dictionary = _nodes.get(id, {})
	for k in ["node", "proxy", "slung"]:
		var n = e.get(k)
		if n != null and is_instance_valid(n):
			n.queue_free()
	_nodes.erase(id)


func clear() -> void:
	for id in _nodes.keys():
		_free(id)
	for s in _sliding:
		if is_instance_valid(s.node):
			s.node.queue_free()
	_sliding.clear()


## Every machine (host directly, clients from the "cremate" event): the body goes off the carrier's
## shoulder, through the furnace window and down into the fire, which flares up.
func play_cremation(data: Dictionary) -> void:
	var furnace: Node3D = game.economy.furnace if game.economy != null else null
	if furnace == null or not is_instance_valid(furnace):
		return
	var body: Node3D = BodyScript.create(String(data.get("pid", "bob")))
	if body.has_method("set_ailment"):
		body.set_ailment(String(data.get("ail", "")))
	if body.has_method("set_vitals"):
		body.set_vitals(0.0)
	game.get_node("Entities").add_child(body)
	var from: Transform3D = data.get("from", Transform3D())
	body.global_transform = from
	# The carrier watches it go from over their shoulder (carry_camera.gd).
	var me = game.local_player()
	if me != null and int(data.get("by", 0)) == int(me.peer_id) and me.get("carry_cam") != null:
		me.carry_cam.linger()
	var ft: Transform3D = furnace.global_transform
	var sill := ft * Vector3(0.0, furnace.SILL + 0.15, 0.25)
	var inside := ft * Vector3(0.0, 0.35, -float(furnace.wall_d) - float(furnace.chamber_d) * 0.4)
	_sliding.append({"node": body, "t": 0.0, "from": from, "sill": sill, "inside": inside,
		"yaw": ft.basis.get_euler().y, "flared": false})


func _tick_slides(delta: float) -> void:
	if _sliding.is_empty():
		return
	var f = game.economy.furnace if game.economy != null else null
	var furnace: Node3D = f if is_instance_valid(f) else null   # gone with its level (the menu)
	for s in _sliding.duplicate():
		s.t = float(s.t) + delta
		var node: Node3D = s.node
		if not is_instance_valid(node):
			_sliding.erase(s)
			continue
		var k := clampf(float(s.t) / SLIDE_SECONDS, 0.0, 1.0)
		# Lying along the window (feet first into the fire), face up, as it goes over the sill.
		var lie := Basis(Vector3.UP, float(s.yaw) + PI * 0.5)
		if k < 0.5:
			# Rolled off the shoulders: it tips forward off them, turning over once on the way down onto
			# the sill, a little up first as the carrier heaves it.
			var a := k / 0.5
			var e := a * a * (3.0 - 2.0 * a)
			var from: Transform3D = s.from
			var pos: Vector3 = from.origin.lerp(s.sill, e)
			pos.y += sin(a * PI) * 0.22
			node.global_position = pos
			var roll := Basis((from.basis.x).normalized(), -PI * e)
			node.global_basis = (roll * from.basis).orthonormalized().slerp(lie, e * e)
		else:
			var b := (k - 0.5) / 0.5
			node.global_position = (s.sill as Vector3).lerp(s.inside, b * b)
			node.global_basis = lie
			if not bool(s.flared) and b > 0.45:
				s.flared = true
				if furnace != null and is_instance_valid(furnace):
					furnace.flare()
		if k >= 1.0:
			node.queue_free()
			_sliding.erase(s)


class LiftProxy extends Area3D:
	var corpses: Node
	var case_id := -1

	func interact_prompt(p) -> String:
		var c: Dictionary = corpses.corpse_by_id(case_id)
		return corpses.lift_prompt(p, c) if not c.is_empty() else ""

	func interact_hold() -> float:
		return 0.0

	func interact(_p) -> void:
		pass   # lifting is a hold (game._tick_carry_holds)
