extends StaticBody3D
## The pharmacy (hub rebuild, chunk 3, after Zach's floorplan and playtest): a wall with a barred
## counter window in the middle, medicine shelves behind it, and nobody goes in. Ordering is by fax:
##
##   1. At the lobby's fax terminal (fax_terminal.gd) you tick what you want on a fax form
##      (fax_order_ui.gd) and send it. The host takes the money (game.order_pharmacy).
##   2. The page prints out of the fax machine behind the bars.
##   3. The Night Nurse comes out from behind the shelves, takes the page, reads it, and walks back
##      behind the shelves.
##   4. She comes back out to the pickup drawer in the bars, puts the order in, and the drawer slides
##      out into the lobby with the items in it (the host spawns them). Once they're taken it shuts.
##
## The attendant is the Night Nurse model (docs/CONTRACTS.md "The Night Nurse's model"): set dressing
## on a scripted walk, no Monster, no brain, never a threat. Orders are replicated as events
## (game "pharmacy_order"), and every machine plays the same timeline from them; only the host
## spawns the items.
##
## Local frame: origin on the floor in the middle of the bars, the lobby toward +Z. `span` is how wide
## the bars run (the hub's pharmacy front is 13.5 m; the dev room's stand-alone one 3 m).

const ItemsDB := preload("res://scripts/items.gd")
const FaxTerminalScript := preload("res://scripts/economy/fax_terminal.gd")
const MonsterModelScript := preload("res://scripts/monsters/monster_model.gd")

const DRAWER_SLIDE := 0.55
## The drawer stays out at least this long, then until nothing lies in it.
const DRAWER_MIN_OPEN := 1.5
const DRAWER_X := 0.0
const DRAWER_Y := 0.95
## The slot through the bars the drawer slides in and out of.
const SLOT_HALF_W := 0.44
const SLOT_BOTTOM := 0.9
const SLOT_TOP := 1.3
const BAR_GAP := 0.16
const HEIGHT := 3.0
## The counter window in the wall: the countertop is the drawer slot's sill, the bars run up to
## WINDOW_TOP, and the window is at most 2 * WINDOW_HALF_MAX wide.
const WALL_T := 0.2
const COUNTER_Y := SLOT_BOTTOM
const COUNTER_DEPTH := 0.45
const WINDOW_TOP := 2.2
const WINDOW_HALF_MAX := 3.0
## The attendant's walking speed and the pauses of the order timeline (seconds).
const NURSE_SPEED := 1.6
const PRINT_SECONDS := 2.0
const READ_SECONDS := 2.2
const GATHER_SECONDS := 2.0
const PLACE_SECONDS := 0.9

var game: Node = null
var span := 13.5
var terminal: StaticBody3D = null

var _price: Label3D
var _nurse: Node3D
var _nurse_page: MeshInstance3D
var _fax_page: MeshInstance3D
var _fax_at := Vector3.ZERO

## Where the attendant walks, local: behind the shelves, at the fax, at the drawer, and the corner
## she rounds at the end of the shelves.
var _hide := Vector3.ZERO
var _corner_back := Vector3.ZERO
var _corner_front := Vector3.ZERO
var _at_fax := Vector3.ZERO
var _at_drawer := Vector3.ZERO

## Orders waiting: [{items: [{kind, count}]}]. The one being served and where its timeline is.
var _queue: Array = []
var _order := {}
var _phase := ""   # "" idle | print | fetch | read | back | gather | bring | place | return
var _phase_t := 0.0
var _path: PackedVector3Array = PackedVector3Array()
var _path_len := 0.0

var _drawer: Node3D
var _drawer_k := 0.0          # 0 shut (inside the bars) .. 1 out in the lobby
var _drawer_state := "shut"   # shut | opening | open | closing
var _open_t := 0.0
var _serving := {}


static func create(g: Node, width := 13.5) -> StaticBody3D:
	var n := new()
	n.game = g
	n.span = width
	n.name = "Pharmacy"
	n._build()
	return n


func _game() -> Node:
	if game != null and is_instance_valid(game):
		return game
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


func _build() -> void:
	collision_layer = C.L_WORLD
	collision_mask = 0
	var half := span * 0.5
	if span >= 8.0:
		# The hub: the first shelf row stands 4.5 m in and runs to 5.25 m either side of the middle.
		_hide = Vector3(3.6, 0, -6.0)
		_corner_back = Vector3(half - 0.55, 0, -6.0)
		_corner_front = Vector3(half - 0.55, 0, -2.0)
	else:
		_hide = Vector3(half - 0.4, 0, -2.4)
		_corner_back = _hide
		_corner_front = Vector3(half - 0.4, 0, -1.2)
	_fax_at = Vector3(DRAWER_X + minf(2.4, half - 0.6), 0, -0.45)
	_at_fax = _fax_at + Vector3(0, 0, -0.75)
	_at_drawer = Vector3(DRAWER_X, 0, -0.95)
	_build_bars()
	_build_drawer()
	_build_fax()
	_build_pharmacist()
	terminal = FaxTerminalScript.create(game)
	add_child(terminal)
	# Out in the lobby beside the bars, a step north of the drawer, facing the bars.
	terminal.position = Vector3(DRAWER_X - minf(2.4, half - 0.7), 0.0, 1.0)


# ---------------------------------------------------------------------------
# model

static var _mats := {}


static func _mat(key: String, col: Color, rough := 0.6, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "pharm_" + key
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	_mats[key] = m
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


func _shape(size: Vector3, pos: Vector3, body: CollisionObject3D = null) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	(body if body != null else self).add_child(cs)


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


## Half the width of the barred counter window in the middle of the wall (the hub: 6 m of bars in a
## 13.5 m wall; the dev room's 3 m one is nearly all window).
func _window_half() -> float:
	return minf(WINDOW_HALF_MAX, span * 0.5 - 0.3)


## A pharmacy counter: solid wall across the front, and in the middle of it a window over a counter,
## barred from the countertop to the window head, with the drawer's slot through the bars. Walls,
## counter and bars all collide (thrown things bounce off too).
func _build_bars() -> void:
	var steel := _mat("steel", Color(0.42, 0.44, 0.46), 0.35, 0.7)
	var dark := _mat("dark", Color(0.08, 0.08, 0.09), 0.6)
	var wall := _wall_mat()
	var top := _mat("countertop", Color(0.52, 0.5, 0.45), 0.45)
	var half := span * 0.5
	var win := _window_half()

	# The wall: either side of the window full height, under it up to the counter, over it to the
	# ceiling.
	for s in [-1.0, 1.0]:
		var w := half - win
		if w > 0.01:
			var cx: float = s * (win + w * 0.5)
			_box(Vector3(w, HEIGHT, WALL_T), Vector3(cx, HEIGHT * 0.5, 0), wall)
			_shape(Vector3(w, HEIGHT, WALL_T), Vector3(cx, HEIGHT * 0.5, 0))
	_box(Vector3(win * 2.0, COUNTER_Y, WALL_T), Vector3(0, COUNTER_Y * 0.5, 0), wall)
	_shape(Vector3(win * 2.0, COUNTER_Y, WALL_T), Vector3(0, COUNTER_Y * 0.5, 0))
	_box(Vector3(win * 2.0, HEIGHT - WINDOW_TOP, WALL_T), Vector3(0, (WINDOW_TOP + HEIGHT) * 0.5, 0), wall)
	_shape(Vector3(win * 2.0, HEIGHT - WINDOW_TOP, WALL_T), Vector3(0, (WINDOW_TOP + HEIGHT) * 0.5, 0))

	# The countertop: a slab along the window's sill, sticking out into the lobby.
	var top_size := Vector3(win * 2.0 + 0.1, 0.05, COUNTER_DEPTH)
	var top_at := Vector3(0, COUNTER_Y - 0.025, -WALL_T * 0.5 + COUNTER_DEPTH * 0.5)
	_box(top_size, top_at, top)
	_shape(top_size, top_at)

	# The bars, countertop to window head. Bars in front of the drawer's slot start above it, so the
	# drawer slides through an opening instead of through the bars.
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(0.035, HEIGHT, 0.035)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = bar_mesh
	var width := win * 2.0
	var n := int(width / BAR_GAP)
	var xforms: Array = []
	for i in n:
		var x := -win + BAR_GAP * 0.5 + i * (width - BAR_GAP) / float(maxi(1, n - 1))
		if absf(x - DRAWER_X) < SLOT_HALF_W + 0.02:
			xforms.append(_bar_xform(x, SLOT_TOP, WINDOW_TOP))
		else:
			xforms.append(_bar_xform(x, COUNTER_Y, WINDOW_TOP))
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Bars"
	mmi.multimesh = mm
	mmi.material_override = steel
	add_child(mmi)
	# A steel frame round the window: a rail under the head, and a post at each jamb.
	_box(Vector3(width, 0.06, 0.07), Vector3(0, WINDOW_TOP - 0.03, 0), steel)
	for s in [-1.0, 1.0]:
		_box(Vector3(0.06, WINDOW_TOP - COUNTER_Y, 0.07), Vector3(s * (win - 0.03), (COUNTER_Y + WINDOW_TOP) * 0.5, 0), steel)
	# Colliders for the bars: left and right of the slot, and over it.
	for s in [-1.0, 1.0]:
		var w := win - SLOT_HALF_W
		_shape(Vector3(w, WINDOW_TOP - COUNTER_Y, 0.08), Vector3(DRAWER_X + s * (SLOT_HALF_W + w * 0.5), (COUNTER_Y + WINDOW_TOP) * 0.5, 0))
	_shape(Vector3(SLOT_HALF_W * 2.0, WINDOW_TOP - SLOT_TOP, 0.08), Vector3(DRAWER_X, (SLOT_TOP + WINDOW_TOP) * 0.5, 0))

	# The sign on the wall over the window, on the lobby side.
	var face := WALL_T * 0.5
	_box(Vector3(1.9, 0.42, 0.03), Vector3(DRAWER_X, 2.5, face + 0.015), dark)
	var head := _label("PHARMACY", 44, Color(0.85, 0.92, 1.0))
	head.position = Vector3(DRAWER_X, 2.6, face + 0.035)
	_price = _label("ORDERS BY FAX", 30, Color(0.8, 1.0, 0.85))
	_price.position = Vector3(DRAWER_X, 2.4, face + 0.035)


## The hub's painted plaster, mapped in world space so the texture doesn't stretch over a box.
static func _wall_mat() -> Material:
	if _mats.has("wall"):
		return _mats["wall"]
	var base := HospitalBuilder.surface_mat("mat/wall", Color(0.62, 0.64, 0.60), 0.85)
	var m: Material = base
	if base is StandardMaterial3D:
		var d: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
		d.uv1_triplanar = true
		d.uv1_world_triplanar = true
		d.uv1_scale = Vector3(0.5, 0.5, 0.5)
		m = d
	_mats["wall"] = m
	return m


func _bar_xform(x: float, from_y: float, to_y: float) -> Transform3D:
	var h := to_y - from_y
	return Transform3D(Basis().scaled(Vector3(1.0, h / HEIGHT, 1.0)), Vector3(x, from_y + h * 0.5, 0.0))


## The pickup drawer: a steel sleeve through a slot in the bars at counter height, framed on the
## lobby side, and a tray that slides out through it. Its floor is a moving collider so whatever is
## served rides out on it.
func _build_drawer() -> void:
	var steel := _mat("steel", Color(0.42, 0.44, 0.46), 0.35, 0.7)
	var dark := _mat("drawer_dark", Color(0.16, 0.17, 0.18), 0.5, 0.5)
	var lamp := _mat("drawer_lamp", Color(0.1, 0.25, 0.12), 0.4, 0.0, Color(0.35, 1.0, 0.45), 0.001)
	var sleeve_h := SLOT_TOP - SLOT_BOTTOM
	var mid_y := (SLOT_TOP + SLOT_BOTTOM) * 0.5
	# The sleeve: sides, roof and floor, 0.9 m deep, the slot's size.
	for s in [-1.0, 1.0]:
		_box(Vector3(0.04, sleeve_h, 0.9), Vector3(DRAWER_X + s * (SLOT_HALF_W - 0.02), mid_y, 0.0), dark)
	_box(Vector3(SLOT_HALF_W * 2.0, 0.04, 0.9), Vector3(DRAWER_X, SLOT_TOP - 0.02, 0.0), dark)
	_box(Vector3(SLOT_HALF_W * 2.0, 0.04, 0.9), Vector3(DRAWER_X, SLOT_BOTTOM + 0.02, 0.0), dark)
	# A steel frame round the slot on the lobby face (the countertop is its sill), and the "ready"
	# lamp above it.
	_box(Vector3(SLOT_HALF_W * 2.0 + 0.16, 0.08, 0.05), Vector3(DRAWER_X, SLOT_TOP + 0.04, 0.06), steel)
	for s in [-1.0, 1.0]:
		_box(Vector3(0.08, sleeve_h + 0.16, 0.05), Vector3(DRAWER_X + s * (SLOT_HALF_W + 0.04), mid_y, 0.06), steel)
	_box(Vector3(0.12, 0.05, 0.02), Vector3(DRAWER_X + 0.3, SLOT_TOP + 0.13, 0.09), lamp)
	_drawer = Node3D.new()
	_drawer.name = "Drawer"
	add_child(_drawer)
	_box(Vector3(0.78, 0.04, 0.7), Vector3(0, 0.0, 0), steel, _drawer)
	_box(Vector3(0.78, 0.22, 0.03), Vector3(0, 0.1, 0.34), steel, _drawer)       # the front plate
	_box(Vector3(0.22, 0.03, 0.05), Vector3(0, 0.12, 0.38), dark, _drawer)       # the handle
	for s in [-1.0, 1.0]:
		_box(Vector3(0.03, 0.12, 0.7), Vector3(s * 0.375, 0.06, 0), steel, _drawer)
	var tray := AnimatableBody3D.new()
	tray.name = "Tray"
	tray.collision_layer = C.L_WORLD
	tray.collision_mask = 0
	tray.sync_to_physics = false
	_drawer.add_child(tray)
	_shape(Vector3(0.78, 0.04, 0.7), Vector3.ZERO, tray)
	_shape(Vector3(0.78, 0.22, 0.03), Vector3(0, 0.1, 0.34), tray)
	_apply_drawer()


func _apply_drawer() -> void:
	if _drawer == null:
		return
	var z := lerpf(-0.45, 0.5, ease(_drawer_k, -1.6))
	_drawer.position = Vector3(DRAWER_X, DRAWER_Y, z)
	var lamp: StandardMaterial3D = _mats.get("drawer_lamp")
	if lamp != null:
		lamp.emission_energy_multiplier = 2.2 if _drawer_state == "open" else 0.0


## The fax machine the orders come out of: on a little stand just behind the bars, where the lobby can
## watch the page print.
func _build_fax() -> void:
	var dark := _mat("fax_dark", Color(0.07, 0.07, 0.08), 0.6)
	var steel := _mat("steel", Color(0.42, 0.44, 0.46), 0.35, 0.7)
	var paper := _mat("paper", Color(0.88, 0.87, 0.82), 0.9)
	var at := _fax_at
	_box(Vector3(0.6, 0.04, 0.45), at + Vector3(0, 0.9, 0), steel)
	for sx in [-0.26, 0.26]:
		_box(Vector3(0.04, 0.9, 0.04), at + Vector3(sx, 0.45, 0), steel)
	_box(Vector3(0.4, 0.14, 0.32), at + Vector3(0, 0.99, 0), dark)
	_box(Vector3(0.28, 0.01, 0.14), at + Vector3(0, 1.065, 0.12), _mat("fax_tray", Color(0.7, 0.66, 0.56), 0.6))
	_fax_page = _box(Vector3(0.21, 0.004, 0.28), at + Vector3(0, 1.07, 0.18), paper)
	_fax_page.visible = false


## The attendant: the Night Nurse model, waiting behind the shelves until an order comes in.
func _build_pharmacist() -> void:
	_nurse = MonsterModelScript.new()
	_nurse.name = "Pharmacist"
	add_child(_nurse)
	_nurse.setup("night_nurse")
	_nurse.position = _hide
	_face(Vector3(0, 0, 1))
	# The page she carries: pinned to her raised right hand every frame (_hold_page).
	var paper := _mat("paper", Color(0.88, 0.87, 0.82), 0.9)
	_nurse_page = _box(Vector3(0.24, 0.32, 0.006), Vector3.ZERO, paper)
	_nurse_page.top_level = true
	_nurse_page.visible = false


## Turn her to face a local direction (her model's front is -Z).
func _face(dir: Vector3) -> void:
	if _nurse == null or Vector2(dir.x, dir.z).length() < 0.001:
		return
	_nurse.rotation.y = atan2(-dir.x, -dir.z)


func _process(delta: float) -> void:
	_tick_order(delta)
	_tick_drawer(delta)
	_hold_page(delta)


## While she has the fax (reading it, carrying it back), her right hand comes up and the page sits in
## it, turned toward her face.
func _hold_page(delta: float) -> void:
	var poser = _nurse.get("nurse") if _nurse != null else null
	var holding := _phase == "read" or _phase == "back"
	if poser != null:
		poser.hold = move_toward(float(poser.hold), 1.0 if holding else 0.0, delta / 0.35)
	if _nurse_page == null or not _nurse_page.visible or poser == null:
		return
	var hand: Vector3 = poser.held_hand_world
	if hand == Vector3.ZERO:
		return
	# Her front in the world (the model's -Z); the page stands up in her fingers, a little in front of
	# her hand, tipped back toward her face.
	var fwd: Vector3 = -(_nurse.global_basis.z)
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	var at := hand + Vector3.UP * 0.1 + fwd * 0.06
	var basis := Basis.looking_at(fwd, Vector3.UP).rotated(fwd.cross(Vector3.UP).normalized(), -0.35)
	_nurse_page.global_transform = Transform3D(basis, at)


# ---------------------------------------------------------------------------
# orders

## Every machine, when an order is placed (host: game.order_pharmacy; clients: its broadcast):
## queue it. `items`: [{kind, count}].
func queue_order(items: Array) -> void:
	_queue.append({"items": items.duplicate(true)})
	if terminal != null and is_instance_valid(terminal):
		terminal.play_send()


## Older callers: one item.
func queue_delivery(kind: String, count: int) -> void:
	queue_order([{"kind": kind, "count": count}])


## Where a served item sits: on the drawer's tray, pulled out into the lobby.
func pickup_point() -> Vector3:
	return global_transform * Vector3(DRAWER_X, DRAWER_Y + 0.08, 0.5)


func busy() -> bool:
	return _phase != "" or not _queue.is_empty()


func _start(phase: String) -> void:
	_phase = phase
	_phase_t = 0.0
	match phase:
		"print":
			_fax_page.visible = true
			_sfx("print_line", _fax_at + Vector3.UP)
		"fetch":
			_walk([_hide, _corner_back, _corner_front, _at_fax])
		"read":
			_fax_page.visible = false
			_nurse_page.visible = true
			_face(_fax_at - _at_fax)
			_sfx("print_feed", _at_fax + Vector3.UP)
		"back":
			_walk([_at_fax, _corner_front, _corner_back, _hide])
		"gather":
			_nurse_page.visible = false
		"bring":
			_walk([_hide, _corner_back, _corner_front, _at_drawer])
		"place":
			_face(Vector3(0, 0, 1))
		"return":
			_walk([_at_drawer, _corner_front, _corner_back, _hide])


func _walk(points: Array) -> void:
	_path = PackedVector3Array(points)
	_path_len = 0.0
	for i in range(1, _path.size()):
		_path_len += _path[i].distance_to(_path[i - 1])
	if _nurse != null:
		_nurse.play("walk", NURSE_SPEED)


## Position along the current walk after `d` metres, and the direction there.
func _along(d: float) -> Array:
	var left := d
	for i in range(1, _path.size()):
		var seg := _path[i].distance_to(_path[i - 1])
		if left <= seg or i == _path.size() - 1:
			var k := clampf(left / maxf(seg, 0.001), 0.0, 1.0)
			return [_path[i - 1].lerp(_path[i], k), _path[i] - _path[i - 1]]
		left -= seg
	return [_path[_path.size() - 1], Vector3.ZERO]


func _tick_order(delta: float) -> void:
	if _phase == "":
		if _queue.is_empty():
			return
		_order = _queue.pop_front()
		_start("print")
		return
	_phase_t += delta
	match _phase:
		"print":
			# The page creeps out of the machine as it prints.
			var k := clampf(_phase_t / PRINT_SECONDS, 0.0, 1.0)
			_fax_page.position = _fax_at + Vector3(0, 1.07, 0.02 + 0.16 * k)
			if _phase_t >= PRINT_SECONDS:
				_start("fetch")
		"fetch", "back", "bring", "return":
			var d := _phase_t * NURSE_SPEED
			var at: Array = _along(d)
			_nurse.position = at[0]
			_face(at[1])
			if d >= _path_len:
				_nurse.play("idle")
				match _phase:
					"fetch": _start("read")
					"back": _start("gather")
					"bring": _start("place")
					"return":
						_phase = ""
						_face(Vector3(0, 0, 1))
		"read":
			if _phase_t >= READ_SECONDS:
				_start("back")
		"gather":
			if _phase_t >= GATHER_SECONDS:
				_start("bring")
		"place":
			if _phase_t >= PLACE_SECONDS:
				_serve(_order)
				_start("return")


## The order goes into the drawer: it slides out, and once it's out the host puts the items on its
## tray.
func _serve(order: Dictionary) -> void:
	_drawer_state = "opening"
	_serving = order
	_sfx("economy_buy", Vector3(DRAWER_X, DRAWER_Y, 0.3))


func _spawn_served(order: Dictionary) -> void:
	var g := _game()
	if g == null or not g.is_host():
		return
	var n := 0
	for e in order.get("items", []):
		var off := Vector3(-0.18 + 0.18 * (n % 3), 0.04 + 0.08 * (n / 3), 0.0)
		var xf := Transform3D(Basis(), pickup_point() + off)
		var it = g._spawn_item(String(e.kind), int(e.count), xf, WorldItem.State.LOOSE)
		if it != null:
			it.value = 0
		n += 1


func _sfx(cue: String, local_at: Vector3) -> void:
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		Audio.play(cue, global_transform * local_at, -4.0, 0.05)


# ---------------------------------------------------------------------------
# the pickup drawer

func _tick_drawer(delta: float) -> void:
	match _drawer_state:
		"opening":
			_drawer_k = minf(1.0, _drawer_k + delta / DRAWER_SLIDE)
			if _drawer_k >= 1.0:
				_drawer_state = "open"
				_open_t = 0.0
				_spawn_served(_serving)
				_serving = {}
		"open":
			_open_t += delta
			if _open_t >= DRAWER_MIN_OPEN and not _item_in_drawer():
				_drawer_state = "closing"
		"closing":
			_drawer_k = maxf(0.0, _drawer_k - delta / DRAWER_SLIDE)
			if _drawer_k <= 0.0:
				_drawer_state = "shut"
	_apply_drawer()


func _item_in_drawer() -> bool:
	var g := _game()
	if g == null:
		return false
	var at := pickup_point()
	for it in g.world_items.values():
		if is_instance_valid(it) and it.state == WorldItem.State.LOOSE and (it.global_position as Vector3).distance_to(at) < 0.6:
			return true
	return false
