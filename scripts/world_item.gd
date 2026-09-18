class_name WorldItem
extends RigidBody3D
## A stack of one item kind lying somewhere in the world: inside a container, or loose on a
## surface. Picking it up removes it and fills a hand slot.
##
## The host owns items. When one is dropped the host lets real physics tumble it until it
## settles; clients never simulate it, they glide toward the host's transform from the
## snapshot. That keeps drops looking physical without anything desyncing.

const FogRingScript := preload("res://scripts/level/fog_ring.gd")   # SWEEP 4A HOOK (fog lot, chunk 2)

enum State { IN_CONTAINER, LOOSE }

const SETTLE_MAX := 3.0

var item_id: int = 0
var kind: String = ""
var count: int = 1
var state: int = State.LOOSE
var container_id: String = ""
var slot: int = 0
var anchor: int = -1
## Sell value of the whole stack in dollars (loot only; 0 for everything else). Rolled by the
## loot spawner, carried into a hand slot as "v" and back out when dropped.
var value: int = 0
## SWEEP 3 HOOK (brains): world_time a brain was harvested, -1 for everything else. Carried into a
## hand slot as "bt" and back out when dropped; the dumpster pays game.brains.current_value().
var bt: float = -1000000.0   # "no spoil clock" (a real one can be negative early in a run)
## GRAFTING part one: a small string that travels with the stack (into a hand slot as "x" and back):
## an eye's owner ("Zach"), or what a specimen vat holds (Eyes.pack). "" for everything else.
var x: String = ""

var _visual: Node3D
var _shape: CollisionShape3D
var _settle: float = 0.0
var _target: Transform3D
var _has_target := false


static func new_item(id: int, item_kind: String, item_count: int) -> WorldItem:
	var it := WorldItem.new()
	it.item_id = id
	it.kind = item_kind
	it.count = maxi(1, item_count)
	it.name = "Item_%d_%s" % [id, item_kind]
	it._build()
	return it


func _build() -> void:
	collision_layer = C.L_PICKUP
	collision_mask = C.L_WORLD
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	continuous_cd = true
	mass = 3.0 if Items.is_bulky(kind) else 0.4
	gravity_scale = 1.0
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.15
	physics_material_override = mat
	add_to_group("interactable")
	add_to_group("world_item")
	set_meta("interact_id", "it_%d" % item_id)

	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	_shape.shape = box
	add_child(_shape)
	_rebuild_visual()


func _rebuild_visual() -> void:
	if _visual != null:
		_visual.queue_free()
	_visual = ItemModels.make_tinted(kind, count)
	add_child(_visual)
	var fp := ItemModels.footprint(kind)
	# A slightly generous box so the aim ray finds small things like vials easily.
	(_shape.shape as BoxShape3D).size = Vector3(maxf(fp.x, 0.12), maxf(fp.y, 0.08), maxf(fp.z, 0.12))
	_shape.position.y = maxf(fp.y, 0.08) * 0.5


func set_count(n: int) -> void:
	if n == count:
		return
	count = maxi(1, n)
	_rebuild_visual()


func _game() -> Node:
	return get_tree().get_first_node_in_group("game")


## Put the stack somewhere at rest (container slot, anchor). No physics.
func place(xf: Transform3D, new_state: int) -> void:
	state = new_state
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = xf
	_target = xf
	_has_target = true


## Host only: let it fall with real physics from a hand, then settle.
func toss(from: Transform3D, velocity: Vector3) -> void:
	state = State.LOOSE
	container_id = ""
	anchor = -1
	global_transform = from
	freeze = false
	sleeping = false
	linear_velocity = velocity
	angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	_settle = SETTLE_MAX


var _container_node: Node = null


## The container this stack sits in, cached. Drawer slots move while a drawer slides,
## so items inside follow the slot every frame instead of trusting the snapshot.
func _container() -> Node:
	if _container_node != null and is_instance_valid(_container_node):
		return _container_node
	var g := _game()
	_container_node = g.find_interactable(container_id) if g != null and container_id != "" else null
	return _container_node


func _physics_process(delta: float) -> void:
	if state == State.IN_CONTAINER:
		var ct := _container()
		if ct != null and ct.has_method("slot_transform"):
			global_transform = ct.slot_transform(slot)
		return
	var g := _game()
	if g != null and g.is_host():
		if not freeze:
			# SWEEP 4A HOOK (pharmacy, chunk 3): a thrown pill checks for a mid-air hit every
			# physics frame while it flies. A hit consumes it before it ever settles as a pickup.
			if kind == "placebo_pills" and get_meta("pill_thrown", false) and g.has_method("pill_check_hit") and g.pill_check_hit(self):
				g.world_items.erase(item_id)
				queue_free()
				return
			_settle -= delta
			if sleeping or _settle <= 0.0 or (linear_velocity.length() < 0.03 and _settle < SETTLE_MAX - 0.4):
				freeze = true
				linear_velocity = Vector3.ZERO
				angular_velocity = Vector3.ZERO
				# SWEEP 4A HOOK (fog lot, chunk 2): anything that settled in the lot's fog ring
				# comes back out at the edge instead of staying lost in the blind.
				if FogRingScript.on_lot(global_position, g.level_info):
					global_position = FogRingScript.pull_from_fog(global_position, g.level_info)
			elif global_position.y < -5.0:
				# Fell through something: put it back on the floor near where it went in.
				global_position = Vector3(global_position.x, 0.2, global_position.z)
				freeze = true
		return
	if _has_target:
		var k := clampf(delta * 14.0, 0.0, 1.0)
		if global_position.distance_squared_to(_target.origin) > 36.0:
			k = 1.0   # POCKETS HOOK: moved through a seam; never slide across the world
		global_position = global_position.lerp(_target.origin, k)
		global_basis = global_basis.slerp(_target.basis.orthonormalized(), k)


# ---------------------------------------------------------------------------
# interaction

func interact_prompt(player) -> String:
	if state == State.IN_CONTAINER:
		var g := _game()
		var ct = g.find_interactable(container_id) if g != null else null
		if ct != null and ct.has_method("is_open") and not ct.is_open():
			return ""
	# ROCKET BOOTS: worn, not carried, so full hands don't matter.
	if Items.is_worn(kind):
		if player != null and bool(player.get("boots")):
			return "!Already wearing rocket boots"
		return "Put on %s" % Items.display_name(kind)
	var label := Items.stack_label(kind, count)
	var g2 := _game()
	if kind == "specimen_vat" and g2 != null and g2.get("vats") != null:
		return g2.vats.item_prompt(player, self)   # GRAFTING: put an eye in, or take the vat
	if g2 != null and g2.get("vats") != null and Eyes.is_eye(kind):
		label = Eyes.label(kind, x)
		label += " ($%d, %s)" % [g2.vats.eye_value({"v": value, "bt": bt}), Eyes.condition(g2.vats.eye_factor(self))]
	elif g2 != null and g2.get("brains") != null and g2.brains.is_brain(kind):
		# SWEEP 3 HOOK (brains): what it is worth now, and how far gone it is.
		label += " ($%d, %s)" % [g2.brains.current_value(self), g2.brains.condition(g2.brains.factor_of(self))]
	elif value > 0:
		label += " ($%d)" % value
	if player != null and player.has_method("can_take") and not player.can_take(kind):
		return "!Needs two free hands" if Items.is_bulky(kind) else "!Hands full"
	return "Take %s" % label


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g := _game()
	if g != null:
		g.pickup_item(player, self)


# ---------------------------------------------------------------------------
# networking

## Quantized (5 mm, rotation components to 0.002) so a resting stack never changes between
## snapshots and costs nothing after the client has it. Items inside a container follow the
## slot on every machine, so their transform is not sent at all.
func report() -> Dictionary:
	var d := {"id": item_id, "k": kind, "n": count, "st": state, "ct": container_id, "sl": slot}
	if value > 0:
		d["v"] = value
	if bt > -100000.0:
		d["bt"] = snappedf(bt, 0.5)   # SWEEP 3 HOOK (brains)
	if x != "":
		d["x"] = x   # GRAFTING part one
	if state != State.IN_CONTAINER:
		var q := global_basis.get_rotation_quaternion()
		d["p"] = global_position.snappedf(0.005)
		d["q"] = Quaternion(snappedf(q.x, 0.002), snappedf(q.y, 0.002), snappedf(q.z, 0.002), snappedf(q.w, 0.002))
	return d


func apply_remote(s: Dictionary) -> void:
	state = int(s.st)
	if container_id != String(s.ct):
		_container_node = null
	container_id = String(s.ct)
	slot = int(s.sl)
	value = int(s.get("v", 0))
	bt = float(s.get("bt", -1000000.0))   # SWEEP 3 HOOK (brains)
	x = String(s.get("x", ""))   # GRAFTING part one
	set_count(int(s.n))
	if not s.has("p"):
		return   # in a container: _physics_process follows the slot
	var q := (s.get("q", Quaternion.IDENTITY) as Quaternion)
	q = q.normalized() if q.length_squared() > 0.0001 else Quaternion.IDENTITY
	_target = Transform3D(Basis(q), s.p as Vector3)
	if not _has_target:
		global_transform = _target
	_has_target = true
