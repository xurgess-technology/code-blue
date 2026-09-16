extends StaticBody3D
## HUB REDESIGN (2026-09-15): the pharmacy's order kiosk. A standing podium next to the counter,
## the actual E-interactable order point -- the grate/counter itself (economy_props.gd) is now
## pure set dressing (the night nurse behind it, a price board), same as a real pharmacy where you
## order at a screen, not by shouting through the glass.
##
## Catalog-driven so a future item just needs an entry here plus a case in `_buy`: today there is
## exactly one (placebo pills, `game.buy_pills`), matching docs/CONTRACTS.md "The pharmacy and the
## crematorium furnace" (sells one item today).
##
## Local frame: origin on the floor, front (the side a player stands on) toward +Z, same
## convention as the Pharmacy counter it stands beside.

var game: Node = null
var _selected := 0
var _label: Label3D


static func create(g: Node) -> StaticBody3D:
	var n := new()
	n.game = g
	n.name = "PharmacyKiosk"
	n._build()
	return n


func _game() -> Node:
	if game != null and is_instance_valid(game):
		return game
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


## The catalog: {kind, name, price_fn: Callable (game) -> int, count_fn: Callable (game) -> int}.
## Adding a second item later is one more entry here (plus a matching branch in `_buy`) -- no
## other rewrite needed.
func _catalog() -> Array:
	return [
		{"kind": "placebo_pills", "name": "Placebo Pills",
				"price": func(g): return int(g.PILL_PRICE) if g != null else 0,
				"count": func(g): return int(g.PILL_COUNT) if g != null else 0},
	]


func _build() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "pharmacy_kiosk")
	collision_layer = C.L_WORLD | C.L_INTERACT
	collision_mask = 0

	var steel := _mat(Color(0.38, 0.4, 0.43), 0.4, 0.65)
	var dark := _mat(Color(0.06, 0.06, 0.07), 0.6)
	var glow := _mat(Color(0.55, 0.95, 1.0), 0.3)
	glow.emission_enabled = true
	glow.emission = Color(0.35, 0.8, 1.0)
	glow.emission_energy_multiplier = 1.2

	# A slanted screen on a steel podium, like a real order kiosk.
	_box(Vector3(0.4, 0.06, 0.4), Vector3(0, 0.03, 0), dark)
	_box(Vector3(0.16, 1.0, 0.16), Vector3(0, 0.56, 0.05), steel)
	var head := Node3D.new()
	head.position = Vector3(0, 1.08, 0.02)
	head.rotation_degrees = Vector3(-18, 0, 0)
	add_child(head)
	_box(Vector3(0.34, 0.24, 0.04), Vector3.ZERO, dark, head)
	var screen := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.27, 0.17)
	screen.mesh = qm
	screen.material_override = glow
	screen.position = Vector3(0, 0, 0.022)
	head.add_child(screen)

	_label = Label3D.new()
	_label.font_size = 26
	_label.pixel_size = 0.0028
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.modulate = Color(0.05, 0.05, 0.05)
	_label.position = Vector3(0, 1.14, 0.045)
	_label.rotation_degrees = Vector3(-18, 0, 0)
	add_child(_label)

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.4, 1.2, 0.4)
	cs.shape = bs
	cs.position = Vector3(0, 0.6, 0)
	add_child(cs)


func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _box(size: Vector3, pos: Vector3, mat: Material, parent: Node = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else self).add_child(mi)
	return mi


func _process(_delta: float) -> void:
	var g := _game()
	var cat := _catalog()
	if cat.is_empty() or _label == null:
		return
	_selected = clampi(_selected, 0, cat.size() - 1)
	var e: Dictionary = cat[_selected]
	var price := int((e.price as Callable).call(g))
	var count := int((e.count as Callable).call(g))
	_label.text = "%s\n$%d / %d" % [String(e.name), price, count]


# ---------------------------------------------------------------------------
# interaction

func interact_prompt(player) -> String:
	var g := _game()
	var cat := _catalog()
	if g == null or cat.is_empty():
		return ""
	var e: Dictionary = cat[_selected]
	var price := int((e.price as Callable).call(g))
	if int(g.money) < price:
		return "!%s: $%d (the team has $%d)" % [String(e.name), price, int(g.money)]
	return "Order %s ($%d)" % [String(e.name), price]


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g := _game()
	if g == null:
		return
	var cat := _catalog()
	if cat.is_empty():
		return
	_buy(g, player, String((cat[_selected] as Dictionary).kind))


## One case per catalog kind. Today there is only the one, so this is a single branch -- a second
## item adds a branch here (or a generic `g.buy_item(kind, count, price)` once the game side wants
## more than pills), never a rewrite of the kiosk itself.
func _buy(g: Node, player, kind: String) -> void:
	match kind:
		"placebo_pills":
			g.buy_pills(player)
