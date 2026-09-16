extends StaticBody3D
## The pharmacy's order station out in the lobby (hub rebuild, chunk 3; replaces the order kiosk): a
## small standing desk with a computer and a fax machine. E opens the order form on your own screen
## (scripts/economy/fax_order_ui.gd, opened by main.gd); sending it prints nothing here, the page
## feeds into this machine and comes out of the pharmacy's fax behind the bars (economy_props.gd).
##
## Interact id `pharmacy_fax`. interact() itself does nothing on the host: the form is local, and
## the order goes to the host through economy.request_order().
##
## Local frame: origin on the floor, the side you stand on toward +Z.

var game: Node = null
var _page: MeshInstance3D
var _page_t := -1.0
var _screen_mat: StandardMaterial3D

const FEED_SECONDS := 1.4


static func create(g: Node) -> StaticBody3D:
	var n := new()
	n.game = g
	n.name = "FaxTerminal"
	n._build()
	return n


func _build() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "pharmacy_fax")
	collision_layer = C.L_WORLD | C.L_INTERACT
	collision_mask = 0
	var steel := _mat(Color(0.36, 0.38, 0.4), 0.45, 0.6)
	var top := _mat(Color(0.55, 0.52, 0.47), 0.7)
	var dark := _mat(Color(0.07, 0.07, 0.08), 0.6)
	var beige := _mat(Color(0.74, 0.7, 0.6), 0.6)
	var paper := _mat(Color(0.86, 0.85, 0.8), 0.9)
	_screen_mat = _mat(Color(0.05, 0.12, 0.08), 0.3)
	_screen_mat.emission_enabled = true
	_screen_mat.emission = Color(0.35, 0.95, 0.5)
	_screen_mat.emission_energy_multiplier = 0.9

	# The desk: a laminate top on a steel frame.
	_box(Vector3(1.1, 0.04, 0.6), Vector3(0, 0.93, 0), top)
	for sx in [-0.5, 0.5]:
		_box(Vector3(0.05, 0.91, 0.5), Vector3(sx, 0.455, 0), steel)
	_box(Vector3(1.0, 0.03, 0.45), Vector3(0, 0.3, -0.02), steel)
	# The computer: a boxy monitor, a keyboard.
	_box(Vector3(0.44, 0.34, 0.3), Vector3(-0.22, 1.13, -0.12), beige)
	_box(Vector3(0.36, 0.26, 0.01), Vector3(-0.22, 1.14, 0.035), _screen_mat)
	_box(Vector3(0.4, 0.03, 0.15), Vector3(-0.22, 0.965, 0.17), beige)
	# The fax machine, facing whoever stands at the desk: the page tray sloping up toward them, a little
	# green display and keypad on the top in front of it.
	_box(Vector3(0.36, 0.13, 0.3), Vector3(0.3, 1.015, 0.0), dark)
	var tray := _box(Vector3(0.24, 0.01, 0.2), Vector3(0.3, 1.13, 0.13), beige)
	tray.rotation_degrees.x = 35.0
	var lcd := _box(Vector3(0.12, 0.012, 0.05), Vector3(0.22, 1.086, -0.08), _screen_mat)
	lcd.rotation_degrees.x = 10.0
	for i in 3:
		for j in 2:
			_box(Vector3(0.022, 0.01, 0.018), Vector3(0.35 + i * 0.03, 1.084, -0.1 + j * 0.03), beige)
	_page = _box(Vector3(0.21, 0.004, 0.28), Vector3(0.3, 1.15, 0.1), paper)
	_page.rotation_degrees.x = 35.0
	_page.visible = false

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.1, 1.3, 0.6)
	cs.shape = bs
	cs.position = Vector3(0, 0.65, 0)
	add_child(cs)


func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


## Every machine, when an order goes out: a page feeds down into the machine.
func play_send() -> void:
	_page_t = 0.0
	_page.visible = true
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		Audio.play("print_feed", global_position + Vector3.UP * 1.0, -4.0, 0.05)


func _process(delta: float) -> void:
	if _page_t < 0.0:
		return
	_page_t += delta
	var k := clampf(_page_t / FEED_SECONDS, 0.0, 1.0)
	# Down the slope of the tray and into the machine.
	_page.position = Vector3(0.3, 1.15 - 0.1 * k, 0.1 - 0.14 * k)
	_page.scale = Vector3(1.0, 1.0, maxf(0.05, 1.0 - k))
	if k >= 1.0:
		_page_t = -1.0
		_page.visible = false
		_page.scale = Vector3.ONE


# ---- interactable contract ----

func interact_prompt(_player) -> String:
	var g = game if game != null and is_instance_valid(game) else (get_tree().get_first_node_in_group("game") if is_inside_tree() else null)
	if g == null:
		return ""
	return "Fax the pharmacy an order"


func interact_hold() -> float:
	return 0.0


func interact(_player) -> void:
	pass   # the order form is opened locally (main.gd); the order reaches the host by RPC
