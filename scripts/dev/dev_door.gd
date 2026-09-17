extends StaticBody3D
## A door flat against a wall that never opens. Two of them: one in the OR supply closet (locked for
## good, until dev mode is on, then E walks you into the hidden dev room) and the dev room's own way
## back to the closet. There is nothing behind either; the host moves you (dev_room.send_player).
##
## Interactable contract (docs/CONTRACTS.md): group "interactable", meta interact_id
## "dev_door_<which>", interact_prompt / interact_hold / interact (host only).
##
## Local frame: origin on the floor at the wall's face, the door's front toward +Z.

const WIDTH := 1.05
const HEIGHT := 2.1

## "closet" (the supply closet's locked door) or "exit" (the dev room's door back).
var which := "closet"
var _lamp: MeshInstance3D
var _lamp_on := -1


static func create(door_which: String) -> StaticBody3D:
	var d = new()
	d.which = door_which
	d.name = "DevDoor_%s" % door_which
	d._build()
	return d


func _build() -> void:
	collision_layer = C.L_WORLD | C.L_INTERACT
	collision_mask = 0
	add_to_group("interactable")
	set_meta("interact_id", "dev_door_%s" % which)

	var frame := _mat(Color(0.2, 0.21, 0.22), 0.6)
	var slab := _mat(Color(0.34, 0.4, 0.38) if which == "closet" else Color(0.25, 0.3, 0.34), 0.55)
	slab.metallic = 0.35
	var steel := _mat(Color(0.7, 0.72, 0.74), 0.3)
	steel.metallic = 0.8
	# The frame, the slab (a few centimetres proud of the wall), a push plate and a handle.
	for part in [[Vector3(0.08, HEIGHT + 0.08, 0.1), Vector3(-WIDTH * 0.5 - 0.04, (HEIGHT + 0.08) * 0.5, 0.05)],
			[Vector3(0.08, HEIGHT + 0.08, 0.1), Vector3(WIDTH * 0.5 + 0.04, (HEIGHT + 0.08) * 0.5, 0.05)],
			[Vector3(WIDTH + 0.16, 0.08, 0.1), Vector3(0, HEIGHT + 0.04, 0.05)]]:
		add_child(_box(part[0], part[1], frame))
	add_child(_box(Vector3(WIDTH, HEIGHT, 0.05), Vector3(0, HEIGHT * 0.5, 0.025), slab))
	add_child(_box(Vector3(0.12, 0.03, 0.06), Vector3(WIDTH * 0.5 - 0.16, 1.02, 0.08), steel))
	add_child(_box(Vector3(0.05, 0.16, 0.02), Vector3(WIDTH * 0.5 - 0.1, 1.02, 0.055), steel))
	# A small lamp over the frame: red while locked, green once dev mode opens it.
	_lamp = _box(Vector3(0.14, 0.07, 0.05), Vector3(0, HEIGHT + 0.2, 0.04), _mat(Color.BLACK, 0.4))
	add_child(_lamp)
	var sign := Label3D.new()
	sign.text = "NO ENTRY" if which == "closet" else "SUPPLY CLOSET"
	sign.font_size = 40
	sign.pixel_size = 0.004
	sign.modulate = Color(0.9, 0.9, 0.85)
	sign.outline_size = 6
	sign.outline_modulate = Color(0, 0, 0, 0.7)
	sign.position = Vector3(0, 1.6, 0.06)
	add_child(sign)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(WIDTH + 0.16, HEIGHT + 0.08, 0.12)
	cs.shape = box
	cs.position = Vector3(0, (HEIGHT + 0.08) * 0.5, 0.06)
	add_child(cs)
	_set_lamp(false)


func _process(_delta: float) -> void:
	var g := get_tree().get_first_node_in_group("game")
	_set_lamp(g != null and g.dev_on())


func _set_lamp(on: bool) -> void:
	if int(on) == _lamp_on:
		return
	_lamp_on = int(on)
	var m := _lamp.material_override as StandardMaterial3D
	var col := Color(0.1, 0.9, 0.3) if on else Color(0.95, 0.1, 0.05)
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.9


func interact_prompt(_player) -> String:
	var g := get_tree().get_first_node_in_group("game")
	if g == null or not g.dev_on():
		return "!Locked"
	return "Enter the dev room" if which == "closet" else "Back to the supply closet"


func interact_hold() -> float:
	return 0.0


func interact(player) -> void:
	var g := get_tree().get_first_node_in_group("game")
	if g != null and g.dev != null and g.dev_on():
		g.dev.walk_through(player, which)


static func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	return mi


static func _mat(albedo: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	return m
