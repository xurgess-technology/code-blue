extends StaticBody3D
## The sell bin and the shop counter: interactables (docs/CONTRACTS.md, "Interaction") with
## interact_id "sell_bin" and "shop".
##
## Two ways to exist:
##   built     (fallback levels and the dev room) this node builds its own model: a steel drop
##             bin with a lit slot, or a counter with a price board and a till;
##   attached  (the neutral area, where the hospital builds the dumpster and the van) only a
##             generous aim box and a sign, around the level's own geometry.
## Local frame: origin on the floor, front toward +Z.

const GoldPileScript := preload("res://scripts/economy/gold_pile.gd")

var role := "sell_bin"   # "sell_bin" | "shop"
var _price: Label3D


static func create(which: String, attached: bool) -> StaticBody3D:
	var n = new()
	n.role = which
	n.name = "SellBin" if which == "sell_bin" else "Shop"
	n._build(attached)
	return n


func _game() -> Node:
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


func _build(attached: bool) -> void:
	add_to_group("interactable")
	set_meta("interact_id", role)
	collision_mask = 0
	if attached:
		collision_layer = C.L_INTERACT
		var size := Vector3(2.4, 1.7, 1.8) if role == "sell_bin" else Vector3(1.6, 1.8, 1.6)
		_shape(size, Vector3(0, size.y * 0.5, 0))
		var tag := _label("SELL LOOT" if role == "sell_bin" else "GOLD BARS", 64, Color(1.0, 0.82, 0.4))
		tag.position = Vector3(0, 2.25 if role == "sell_bin" else 2.5, 0)
		tag.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		if role == "shop":
			_price = _label("", 44, Color(1.0, 0.95, 0.8))
			_price.position = Vector3(0, 2.2, 0)
			_price.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		return
	collision_layer = C.L_WORLD | C.L_INTERACT
	if role == "sell_bin":
		_build_bin()
	else:
		_build_counter()


# ---------------------------------------------------------------------------
# models

static var _mats := {}


static func _mat(key: String, col: Color, rough := 0.6, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "econ_" + key
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	_mats[key] = m
	return m


func _box(size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot
	add_child(mi)
	return mi


func _shape(size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	add_child(cs)


func _label(text: String, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.0035
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = col
	add_child(l)
	return l


func _lamp(pos: Vector3, col: Color, energy: float, reach: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = reach
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 0.2
	l.position = pos
	add_child(l)


## A green steel drop bin: a box on short legs, a sloped hopper lid with a lit slot.
func _build_bin() -> void:
	var paint := _mat("bin_paint", Color(0.16, 0.3, 0.22), 0.55, 0.35)
	var steel := _mat("bin_steel", Color(0.45, 0.47, 0.48), 0.35, 0.7)
	var gold := _mat("bin_gold", Color(0.3, 0.2, 0.05), 0.4, 0.0, Color(1.0, 0.7, 0.22), 2.2)
	_box(Vector3(0.9, 0.9, 0.62), Vector3(0, 0.55, 0), paint)
	for x in [-0.4, 0.4]:
		for z in [-0.26, 0.26]:
			_box(Vector3(0.06, 0.1, 0.06), Vector3(x, 0.05, z), steel)
	_box(Vector3(0.94, 0.06, 0.66), Vector3(0, 1.02, -0.02), steel, Vector3(-12, 0, 0))
	_box(Vector3(0.62, 0.02, 0.1), Vector3(0, 1.07, 0.1), _mat("bin_slot", Color(0.02, 0.02, 0.02), 0.9), Vector3(-12, 0, 0))
	_box(Vector3(0.66, 0.012, 0.012), Vector3(0, 1.085, 0.16), gold, Vector3(-12, 0, 0))
	_box(Vector3(0.66, 0.012, 0.012), Vector3(0, 1.07, 0.04), gold, Vector3(-12, 0, 0))
	_box(Vector3(0.5, 0.16, 0.01), Vector3(0, 0.72, 0.315), _mat("bin_plate", Color(0.85, 0.8, 0.6), 0.5, 0.6))
	var l := _label("SELL", 72, Color(0.15, 0.1, 0.02))
	l.outline_size = 0
	l.position = Vector3(0, 0.72, 0.322)
	var tag := _label("LOOT IN, CASH OUT", 36, Color(1.0, 0.85, 0.45))
	tag.position = Vector3(0, 1.35, 0.1)
	_lamp(Vector3(0, 1.5, 0.5), Color(1.0, 0.8, 0.45), 0.7, 2.6)
	_shape(Vector3(0.94, 1.1, 0.66), Vector3(0, 0.55, 0))


## A shop counter: a wooden top on a steel cabinet, a till, a price board on two posts and a
## few sample bars under a lamp.
func _build_counter() -> void:
	var wood := _mat("counter_wood", Color(0.36, 0.22, 0.12), 0.7)
	var steel := _mat("counter_steel", Color(0.3, 0.32, 0.34), 0.45, 0.5)
	var board := _mat("counter_board", Color(0.08, 0.07, 0.06), 0.8)
	_box(Vector3(1.4, 0.95, 0.55), Vector3(0, 0.475, 0), steel)
	_box(Vector3(1.5, 0.05, 0.65), Vector3(0, 0.975, 0.02), wood)
	_box(Vector3(0.26, 0.14, 0.22), Vector3(0.45, 1.07, -0.05), _mat("till", Color(0.12, 0.12, 0.13), 0.5), Vector3(-10, 0, 0))
	_box(Vector3(0.14, 0.004, 0.06), Vector3(0.45, 1.145, -0.02), _mat("till_screen", Color(0.02, 0.05, 0.02), 0.3, 0.0, Color(0.3, 1.0, 0.4), 1.4), Vector3(-10, 0, 0))
	for x in [-0.66, 0.66]:
		_box(Vector3(0.05, 1.3, 0.05), Vector3(x, 1.6, -0.22), steel)
	_box(Vector3(1.4, 0.5, 0.04), Vector3(0, 2.0, -0.22), board)
	var head := _label("GOLD BARS", 64, Color(1.0, 0.8, 0.35))
	head.position = Vector3(0, 2.1, -0.195)
	_price = _label("", 48, Color(1.0, 0.95, 0.85))
	_price.position = Vector3(0, 1.88, -0.195)
	for i in 3:
		var bar := MeshInstance3D.new()
		bar.mesh = GoldPileScript.bar_mesh()
		bar.position = Vector3(-0.35 + i * 0.1, 1.0, 0.05)
		bar.rotation.y = PI * 0.5
		add_child(bar)
	var top := MeshInstance3D.new()
	top.mesh = GoldPileScript.bar_mesh()
	top.position = Vector3(-0.25, 1.0 + GoldPileScript.BAR_H, 0.05)
	add_child(top)
	_lamp(Vector3(0, 2.4, 0.6), Color(1.0, 0.82, 0.5), 1.1, 3.5)
	_shape(Vector3(1.5, 1.0, 0.65), Vector3(0, 0.5, 0.02))
	_shape(Vector3(1.4, 1.5, 0.1), Vector3(0, 1.75, -0.22))


func _process(_delta: float) -> void:
	if _price == null:
		return
	var g := _game()
	if g == null:
		return
	var text := "$%d EACH" % int(g.gold_bar_price())
	if _price.text != text:
		_price.text = text


# ---------------------------------------------------------------------------
# interaction

func interact_prompt(player) -> String:
	if player == null:
		return ""
	var g := _game()
	if g == null:
		return ""
	if role == "shop":
		var price: int = g.gold_bar_price()
		if int(g.money) < price:
			return "!Gold bar: $%d (the team has $%d)" % [price, int(g.money)]
		return "Buy a gold bar ($%d)" % price
	var s: Dictionary = player.selected_stack() if player.has_method("selected_stack") else player.slots[player.selected]
	var kind := String(s.kind)
	if kind == "":
		return "!Sell bin: bring loot (the gold glow)"
	if not Items.is_loot(kind):
		return "!Surgical supplies go on the OR shelf" if Items.is_surgical(kind) else "!Not worth anything"
	return "Sell %s for $%d" % [Items.stack_label(kind, int(s.count)), int(s.get("v", 0))]


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g := _game()
	if g == null:
		return
	if role == "shop":
		g.buy_gold_bar(player)
	else:
		g.sell_selected(player)
