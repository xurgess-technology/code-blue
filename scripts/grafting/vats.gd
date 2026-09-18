class_name Vats
extends Node
## Grafting part one (docs/GRAFTING.md): specimen vats. A glass jar of cloudy fluid an eye floats
## in, and an eye in a vat does not spoil.
##
## The vat is the ordinary bulky item `specimen_vat` (two hands). What it holds is the stack's /
## world item's `x` string (Eyes.pack: kind, owner, age, value), so it rides every existing
## carry / drop / snapshot path with no new replication. An eye going in freezes its age; coming
## out, its spoil clock `bt` is rebuilt from that age.
##
## Inputs (docs/CONTRACTS.md "Grafting"):
##   E on a vat (on a bench or dropped) with an eye selected     puts the eye in
##   E with a vat AND an eye in your hands, aimed at nothing      puts the eye in
##   V ("vat_take") aimed at a vat, or with one in your hands     takes the eye back out
##   E on a free lab-bench spot while carrying a vat              sets it down there
## Three empty vats stand on the lab wall at the start of a run (level_info.vat_spots, from the
## entrance building; the host spawns them once per run).

const KIND := "specimen_vat"
const HAND_AIM := "vat_hand"
const SPOT_RADIUS := 0.13
const SPOT_TAKEN_XZ := 0.2
const START_VATS := 3

var game: Node = null

var spots: Array = []           # [{position: Vector3, yaw: float}], every machine
var _markers: Array = []        # Marker per spot
var _t := 0.0
var _stamp_t := 0.0


class Marker extends Area3D:
	var vats: Node
	var index := 0

	func interact_prompt(p) -> String:
		return vats.spot_prompt(p, index)

	func interact_hold() -> float:
		return 0.0

	func interact(p) -> void:
		vats.set_down(p, index)


func setup(g: Node) -> void:
	game = g


# =============================================================================== the model

static var _glass_mat: StandardMaterial3D = null
static var _fluid_mat: StandardMaterial3D = null


static func _mat(col: Color, rough := 0.5, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


## A glass jar on a steel foot with a steel lid, cloudy fluid inside. `Content` (a Node3D) holds both
## eyes, hidden until the vat's `x` says which one floats there. Origin at the base.
static func build_model(root: Node3D) -> void:
	if _glass_mat == null:
		_glass_mat = _mat(Color(0.8, 0.9, 0.92, 0.22), 0.05)
		_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_fluid_mat = _mat(Color(0.78, 0.85, 0.55, 0.28), 0.25)
		_fluid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var steel := _mat(Color(0.5, 0.52, 0.55), 0.35, 0.6)
	var parts := [
		[0.07, 0.014, 0.007, steel],       # foot
		[0.062, 0.2, 0.114, _glass_mat],   # the jar
		[0.056, 0.17, 0.105, _fluid_mat],  # the fluid
		[0.066, 0.02, 0.222, steel],       # the lid
	]
	for e in parts:
		var mi := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = float(e[0])
		c.bottom_radius = float(e[0])
		c.height = float(e[1])
		c.radial_segments = 16
		c.rings = 1
		mi.mesh = c
		mi.material_override = e[3]
		mi.position = Vector3(0, float(e[2]), 0)
		root.add_child(mi)
	var content := Node3D.new()
	content.name = "Content"
	content.position = Vector3(0, 0.08, 0)
	content.scale = Vector3.ONE * 1.5   # a bigger eye reads through the fluid
	root.add_child(content)
	for k in Eyes.KINDS:
		var holder := Node3D.new()
		holder.name = "VatEye_" + k
		holder.visible = false
		content.add_child(holder)
		Eyes.build(holder, k)


## Show what `x` says is inside under `node` (a vat's model, a world item or a hand's holder).
static func set_contents(node: Node, x: String) -> void:
	if node == null or not is_instance_valid(node):
		return
	var content := node.find_child("Content", true, false)
	if content == null:
		return
	var d := Eyes.unpack(x)
	for k in Eyes.KINDS:
		var holder := content.get_node_or_null("VatEye_" + k) as Node3D
		if holder == null:
			continue
		var on: bool = not d.is_empty() and String(d.kind) == k
		holder.visible = on
		if on:
			Eyes.set_rot(holder, Eyes.rot_of(Eyes.spoil_factor(float(d.age))))


# =============================================================================== helpers

## The head slot of a vat in p's hands, or -1. Prefers the selected one.
static func held_vat(p) -> int:
	if p == null or not ("slots" in p):
		return -1
	var sel: int = p.selected_head()
	if String(p.slots[sel].kind) == KIND:
		return sel
	for i in p.slots.size():
		if String(p.slots[i].kind) == KIND and not p.slots[i].has("of"):
			return i
	return -1


func _now() -> float:
	return float(game.world_time)


## "Zach's eye, fresh" for a vat's contents string.
static func describe(x: String) -> String:
	var d := Eyes.unpack(x)
	if d.is_empty():
		return ""
	return "%s, %s" % [Eyes.label(String(d.kind), String(d.owner)), Eyes.condition(Eyes.spoil_factor(float(d.age)))]


## Seconds an eye stack / item has been out of a vat.
func eye_age(stack_or_item) -> float:
	var bt := -1000000.0
	if stack_or_item is Dictionary:
		bt = float(stack_or_item.get("bt", -1000000.0))
	elif stack_or_item is Object and is_instance_valid(stack_or_item):
		bt = float(stack_or_item.get("bt"))
	if bt <= -100000.0 or game == null:
		return 0.0
	return maxf(0.0, _now() - bt)


func eye_factor(stack_or_item) -> float:
	return Eyes.spoil_factor(eye_age(stack_or_item))


## What the furnace pays for an eye stack ({kind, v, bt}) right now.
func eye_value(s: Dictionary) -> int:
	var v := int(s.get("v", 0))
	if v <= 0:
		return 0
	return maxi(1, roundi(float(v) * eye_factor(s)))


func _pack_stack(s: Dictionary) -> String:
	return Eyes.pack(String(s.kind), String(s.get("x", "")), eye_age(s), int(s.get("v", 0)))


# =============================================================================== prompts

## WorldItem.interact_prompt for a vat lying somewhere.
func item_prompt(player, it) -> String:
	var d := Eyes.unpack(String(it.x))
	var sel: Dictionary = player.selected_stack() if player != null and player.has_method("selected_stack") else {}
	if Eyes.is_eye(String(sel.get("kind", ""))):
		if d.is_empty():
			return "Put %s in the vat" % Eyes.label(String(sel.kind), String(sel.get("x", "")))
		return "!The vat already holds an eye"
	if player != null and player.has_method("can_take") and not player.can_take(KIND):
		return "!Needs two free hands"
	if d.is_empty():
		return "Take the empty specimen vat"
	return "Take the specimen vat (%s)  [V: take the eye out]" % describe(String(it.x))


## The local prompt for E aimed at nothing: an eye and a vat both in hand.
func hand_prompt(p) -> String:
	var vh := held_vat(p)
	if vh < 0 or String(p.slots[vh].get("x", "")) != "":
		return ""
	var sel: Dictionary = p.selected_stack()
	if not Eyes.is_eye(String(sel.kind)):
		return ""
	return "Put %s in the vat" % Eyes.label(String(sel.kind), String(sel.get("x", "")))


func spot_prompt(p, index: int) -> String:
	if p == null or held_vat(p) < 0 or not spot_free(index):
		return ""
	return "Set the vat down on the bench"


# =============================================================================== actions (host)

## E on a vat item. True when it was an eye going in (the press is used up).
func item_used(p, it: Node) -> bool:
	if not game.is_host() or p == null or String(it.kind) != KIND:
		return false
	var h: int = p.selected_head()
	var s: Dictionary = p.slots[h]
	if not Eyes.is_eye(String(s.kind)):
		return false
	if String(it.x) != "":
		game.tell(p, "The vat already holds an eye.", 2.5)
		return true
	it.x = _pack_stack(s)
	game.tell(p, "%s is floating in the vat now. It won't spoil there." % Eyes.label(String(s.kind), String(s.get("x", ""))), 3.0)
	p.clear_slot(h)
	game._sound("items_glass", it.global_position)
	return true


## E aimed at nothing with a vat and an eye in hand.
func hand_put(p) -> void:
	if not game.is_host() or p == null:
		return
	var vh := held_vat(p)
	if vh < 0 or String(p.slots[vh].get("x", "")) != "":
		return
	var eh: int = p.selected_head()
	var s: Dictionary = p.slots[eh]
	if not Eyes.is_eye(String(s.kind)):
		return
	p.slots[vh]["x"] = _pack_stack(s)
	game.tell(p, "%s is floating in the vat now. It won't spoil there." % Eyes.label(String(s.kind), String(s.get("x", ""))), 3.0)
	p.clear_slot(eh)
	game._sound("items_glass", p.global_position)


## The vat key: the eye out of the vat you aim at, else the one in your hands.
func take_out(p, aim_id: String) -> void:
	if not game.is_host() or p == null or not p.alive:
		return
	var node: Node = game.find_interactable(aim_id) if aim_id != "" else null
	if node is WorldItem and String(node.kind) == KIND and game._within_reach(p, node):
		if String(node.x) == "":
			game.tell(p, "The vat is empty.", 2.0)
			return
		if _to_hand(p, String(node.x)):
			node.x = ""
		return
	var vh := held_vat(p)
	if vh < 0:
		return
	var x := String(p.slots[vh].get("x", ""))
	if x == "":
		game.tell(p, "The vat is empty.", 2.0)
		return
	if _to_hand(p, x):
		p.slots[vh]["x"] = ""


## Contents string -> an eye in p's hands, its spoil clock running again from its frozen age.
func _to_hand(p, x: String) -> bool:
	var d := Eyes.unpack(x)
	if d.is_empty():
		return false
	var i: int = p.take_into(String(d.kind), 1, int(d.value))
	if i < 0:
		game.tell(p, "Your hands are full.", 2.0)
		return false
	p.selected = i
	p.slots[i]["bt"] = _now() - float(d.age)
	if String(d.owner) != "":
		p.slots[i]["x"] = String(d.owner)
	game.tell(p, "You took %s out of the vat. It spoils again out here." % Eyes.label(String(d.kind), String(d.owner)), 3.0)
	game._sound("pickup", p.global_position)
	return true


## E on a free bench spot while carrying a vat.
func set_down(p, index: int) -> void:
	if not game.is_host() or p == null or index < 0 or index >= spots.size() or not spot_free(index):
		return
	var vh := held_vat(p)
	if vh < 0:
		return
	var sp: Dictionary = spots[index]
	var xf := Transform3D(Basis(Vector3.UP, float(sp.get("yaw", 0.0))), sp.position as Vector3)
	var it: Node = game._spawn_item(KIND, 1, xf, WorldItem.State.LOOSE)
	it.x = String(p.slots[vh].get("x", ""))
	p.clear_slot(vh)
	game._sound("items_clink", xf.origin)
	game.tell(p, "Vat set down on the bench.", 2.0)


# =============================================================================== the lab wall

## Every machine, right after the level is built: markers for the bench spots. The host also stands
## the starting vats on the first spots and stocks the scalpel and the eye spoon in the OR's storage.
func on_level_built(info: Dictionary) -> void:
	for m in _markers:
		if is_instance_valid(m):
			m.queue_free()
	_markers.clear()
	spots = info.get("vat_spots", [])
	for i in spots.size():
		var m := Marker.new()
		m.name = "VatSpot_%d" % i
		m.vats = self
		m.index = i
		m.collision_layer = 0
		m.collision_mask = 0
		m.monitoring = false
		m.add_to_group("interactable")
		m.set_meta("interact_id", "vatspot_%d" % i)
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = SPOT_RADIUS
		cs.shape = sph
		m.add_child(cs)
		game.level.add_child(m)
		m.global_position = (spots[i].position as Vector3) + Vector3.UP * 0.1
		_markers.append(m)
	if game.is_host():
		for i in mini(START_VATS, spots.size()):
			var sp: Dictionary = spots[i]
			game._spawn_item(KIND, 1, Transform3D(Basis(Vector3.UP, float(sp.get("yaw", 0.0))), sp.position as Vector3), WorldItem.State.LOOSE)
		game.stock_storage("scalpel", 1)
		game.stock_storage("eye_spoon", 1)


## Is there no vat standing on this spot?
func spot_free(index: int) -> bool:
	if index < 0 or index >= spots.size():
		return false
	var at: Vector3 = spots[index].position
	for it in game.world_items.values():
		if not is_instance_valid(it) or String(it.kind) != KIND:
			continue
		var d: Vector3 = it.global_position - at
		if Vector2(d.x, d.z).length() < SPOT_TAKEN_XZ and absf(d.y) < 0.35:
			return false
	return true


# =============================================================================== per frame

func _physics_process(delta: float) -> void:
	if game == null or game.get("world_items") == null:
		return
	_t -= delta
	if _t <= 0.0:
		_t = 0.15
		_show()
		_arm_markers()
	if game.is_host():
		_stamp_t -= delta
		if _stamp_t <= 0.0:
			_stamp_t = 0.5
			_stamp_spoil_times()


## Host: an eye that came from nowhere (a dev spawn) starts spoiling now.
func _stamp_spoil_times() -> void:
	for it in game.world_items.values():
		if is_instance_valid(it) and Eyes.is_eye(String(it.kind)) and float(it.bt) <= -100000.0:
			it.bt = _now()
	for p in game.players.values():
		for s in p.slots:
			if Eyes.is_eye(String(s.kind)) and not s.has("bt"):
				s["bt"] = _now()


## Every machine: the rot on every eye lying about or in hand, and what floats in every vat.
func _show() -> void:
	for it in game.world_items.values():
		if not is_instance_valid(it):
			continue
		var k := String(it.kind)
		if Eyes.is_eye(k):
			Eyes.set_rot(it, Eyes.rot_of(eye_factor(it)))
		elif k == KIND:
			set_contents(it, String(it.x))
	for p in game.players.values():
		var s: Dictionary = p.selected_stack()
		var k := String(s.kind)
		if k != KIND and not Eyes.is_eye(k):
			continue
		for holder in ["Head/FX/Camera/HeldFirstPerson", "Body/HeldThirdPerson"]:
			var n = p.get_node_or_null(holder)
			if n == null:
				continue
			if k == KIND:
				set_contents(n, String(s.get("x", "")))
			else:
				Eyes.set_rot(n, Eyes.rot_of(eye_factor(s)))


## Local: a bench spot only takes an aim ray while you carry a vat and nobody has put one there.
func _arm_markers() -> void:
	var me = game.local_player()
	var carrying: bool = me != null and held_vat(me) >= 0
	for i in _markers.size():
		var m: Area3D = _markers[i]
		if is_instance_valid(m):
			m.collision_layer = C.L_INTERACT if (carrying and spot_free(i)) else 0
