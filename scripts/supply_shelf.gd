class_name SupplyShelf
extends StaticBody3D
## The steel supply rack in the OR. Surgery only uses what is on it. Its contents are the
## game's `shelf` dictionary (kind -> count); this node just shows them and takes deliveries.

const SLOT_KINDS := ["anesthetic", "gauze", "forceps", "tourniquet", "bone_saw"]

var _stock_root: Node3D
var _shown := {}
var _labels := {}


static func create() -> SupplyShelf:
	var s := SupplyShelf.new()
	s.name = "SupplyShelf"
	s._build()
	return s


func _build() -> void:
	collision_layer = C.L_WORLD | C.L_INTERACT
	collision_mask = 0
	add_to_group("interactable")
	set_meta("interact_id", "shelf")

	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color("9aa3a8")
	steel.metallic = 0.85
	steel.roughness = 0.35
	var w := 1.3
	var d := 0.45
	for y in [0.35, 0.85, 1.35]:
		var board := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, 0.03, d)
		board.mesh = bm
		board.material_override = steel
		board.position = Vector3(0, y, 0)
		add_child(board)
	for x in [-w * 0.5 + 0.02, w * 0.5 - 0.02]:
		for z in [-d * 0.5 + 0.02, d * 0.5 - 0.02]:
			var leg := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.03, 1.6, 0.03)
			leg.mesh = lm
			leg.material_override = steel
			leg.position = Vector3(x, 0.8, z)
			add_child(leg)
	# AFFORDANCE HOOK: no more permanently-visible label here (it duplicated the aim highlight,
	# scripts/aim_highlight.gd, docs/CONTRACTS.md "Interaction"). The shelf is unmistakable on
	# sight (steel rack, tinted surgical stock on it) and the crosshair prompt still names it
	# ("Put <item> on the shelf" / the reasons you cannot) whenever a player aims at it.

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(w, 1.6, d)
	cs.shape = box
	cs.position.y = 0.8
	add_child(cs)

	var lamp := OmniLight3D.new()
	lamp.light_color = Color(0.8, 0.95, 1.0)
	lamp.light_energy = 0.6
	lamp.omni_range = 2.2
	lamp.shadow_enabled = false
	lamp.position = Vector3(0, 1.5, 0.35)
	add_child(lamp)

	_stock_root = Node3D.new()
	add_child(_stock_root)


## Rebuild the visible stock to match the shelf dictionary. Cheap: only kinds that changed.
func show_stock(stock: Dictionary) -> void:
	for i in SLOT_KINDS.size():
		var kind: String = SLOT_KINDS[i]
		var n := int(stock.get(kind, 0))
		if int(_shown.get(kind, -1)) == n:
			continue
		_shown[kind] = n
		if _stock_root.has_node(kind):
			_stock_root.get_node(kind).free()
		if n <= 0:
			continue
		var holder := Node3D.new()
		holder.name = kind
		holder.add_child(ItemModels.make_tinted(kind, n))
		var shelf_y: float = [0.865, 0.865, 1.365, 1.365, 0.365][i]
		var x: float = [-0.35, 0.3, -0.35, 0.3, 0.0][i]
		holder.position = Vector3(x, shelf_y, 0.0)
		_stock_root.add_child(holder)


# ---------------------------------------------------------------------------

func interact_prompt(player) -> String:
	if player == null:
		return ""
	var s: Dictionary = player.selected_stack() if player.has_method("selected_stack") else player.slots[player.selected]
	if s.kind == "":
		return "!Supply shelf: bring surgical items here (the teal glow)"
	if not Items.is_surgical(s.kind):
		return "!Loot goes in the sell bin, not on the shelf" if Items.is_loot(s.kind) else "!Only surgical supplies go on the shelf"
	return "Put %s on the shelf" % Items.stack_label(s.kind, int(s.count))


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g = get_tree().get_first_node_in_group("game")
	if g != null:
		g.shelf_place(player)
