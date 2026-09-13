extends StaticBody3D
## A dev room dispenser: a lit steel pedestal showing one item. E hands you a fresh stack of it,
## forever. The "dev_gun" one is the gun rack: E takes the dev gun or puts it back.
##
## Interactable contract (docs/CONTRACTS.md): group "interactable", meta interact_id
## "dev_disp_<kind>", interact_prompt / interact_hold / interact (host only).
##
## Local frame: origin on the floor, front toward +Z.

const GunFx := preload("res://scripts/dev/dev_gun.gd")

var kind: String = ""


static func create(item_kind: String) -> StaticBody3D:
	var d = new()
	d.kind = item_kind
	d.name = "Dispenser_%s" % item_kind
	d._build()
	return d


func _build() -> void:
	collision_layer = C.L_WORLD | C.L_INTERACT
	collision_mask = 0
	add_to_group("interactable")
	set_meta("interact_id", "dev_disp_%s" % kind)

	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.55, 0.56, 0.58)
	steel.metallic = 0.3
	steel.roughness = 0.5
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.7, 0.95, 0.5)
	base.mesh = bm
	base.material_override = steel
	base.position = Vector3(0, 0.475, 0)
	add_child(base)

	var gun := kind == "dev_gun"
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.05, 0.05, 0.05)
	glow.emission_enabled = true
	glow.emission = Color(1.0, 0.35, 0.2) if gun else (Color(0.2, 0.9, 0.8) if Items.is_surgical(kind) else Color(0.9, 0.8, 0.4))
	glow.emission_energy_multiplier = 2.0
	var strip := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.66, 0.03, 0.02)
	strip.mesh = sm
	strip.material_override = glow
	strip.position = Vector3(0, 0.93, 0.255)
	add_child(strip)

	var shown: Node3D = GunFx.make_gun() if gun else ItemModels.make(kind, _batch())
	shown.name = "Shown"
	shown.position = Vector3(0, 0.955, 0)
	shown.scale = Vector3.ONE * 2.2
	if gun:
		shown.position = Vector3(0, 1.08, 0.05)
		shown.rotation = Vector3(0, PI / 2.0, 0)
		shown.scale = Vector3.ONE * 1.5
	add_child(shown)
	# A small spotlight over each one so the item reads against the wall.
	var spot := OmniLight3D.new()
	spot.light_color = glow.emission.lightened(0.5)
	spot.light_energy = 0.5
	spot.omni_range = 1.0
	spot.shadow_enabled = false
	spot.light_volumetric_fog_energy = 0.0
	spot.position = Vector3(0, 1.5, 0.3)
	add_child(spot)

	var label := Label3D.new()
	label.text = "DEV GUN" if gun else Items.display_name(kind).to_upper()
	label.font_size = 52
	label.pixel_size = 0.0028
	label.outline_size = 10
	label.modulate = glow.emission.lightened(0.45)
	label.position = Vector3(0, 0.72, 0.255)
	add_child(label)

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, 1.35, 0.5)
	cs.shape = box
	cs.position = Vector3(0, 0.675, 0)
	add_child(cs)


## How many a dispensed stack holds: the most a found batch can be.
func _batch() -> int:
	if kind == "dev_gun":
		return 1
	var b: Array = Items.def(kind).get("batch", [1, 1])
	return int(b[b.size() - 1]) if Items.is_consumable(kind) else 1


func interact_prompt(player) -> String:
	if player == null:
		return ""
	if kind == "dev_gun":
		var g := get_tree().get_first_node_in_group("game")
		var has: bool = g != null and g.dev != null and g.dev.has_gun(player.peer_id)
		return "Put back the dev gun" if has else "Take the dev gun"
	if player.has_method("can_take") and not player.can_take(kind):
		return "!Hands full"
	var n := _batch()
	return "Take %s" % (Items.display_name(kind) if n <= 1 else "%d %s" % [n, Items.def(kind).get("short", Items.display_name(kind))])


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g := get_tree().get_first_node_in_group("game")
	if g != null and g.dev != null:
		g.dev.dispense(player, kind, _batch(), global_position + Vector3.UP * 1.0)
