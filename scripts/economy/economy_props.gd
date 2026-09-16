extends StaticBody3D
## SWEEP 4A HOOK (pharmacy, chunk 3), HUB REDESIGN (2026-09-15): the outpatient pharmacy window,
## now inside its own walled room (docs/CONTRACTS.md "Hospital", scripts/level/entrance.gd) with a
## real order kiosk (pharmacy_kiosk.gd) next to it. The counter itself is pure set dressing: a
## price board, a steel grate, and the Night Nurse (docs/CONTRACTS.md "The Night Nurse's model")
## standing idle behind it -- see `_build_pharmacist` for why she replaced the old capsule
## silhouette. Ordering is E on the kiosk, not on this counter any more.
##
## Local frame: origin on the floor, front (the side a player stands on) toward +Z.

const ItemsDB := preload("res://scripts/items.gd")
const KioskScript := preload("res://scripts/economy/pharmacy_kiosk.gd")
const MonsterModelScript := preload("res://scripts/monsters/monster_model.gd")

var game: Node = null
var _price: Label3D
var _nurse: Node3D          # the idle Night Nurse model, pure set dressing behind the grate
var _nurse_base_x := 0.0
var _shape_t := 0.0
var kiosk: StaticBody3D = null

## Tube delivery: a queued {kind, count} list, each waiting DELIVER_SECONDS before it thunks out.
const DELIVER_SECONDS := 1.6
var _queue: Array = []
var _capsule: MeshInstance3D
var _capsule_t := 0.0
var _delivery_slot: Vector3


static func create(g: Node) -> StaticBody3D:
	var n := new()
	n.game = g
	n.name = "Pharmacy"
	n._build()
	return n


func _game() -> Node:
	if game != null and is_instance_valid(game):
		return game
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


func _build() -> void:
	# HUB REDESIGN: the counter is no longer itself interactable -- the kiosk beside it is the
	# order point now (still collides like any wall/counter, C.L_WORLD, so nobody walks through it).
	collision_layer = C.L_WORLD
	collision_mask = 0
	_build_window()
	_build_pharmacist()
	kiosk = KioskScript.create(game)
	add_child(kiosk)
	kiosk.position = Vector3(1.55, 0.0, 0.9)


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


func _box(size: Vector3, pos: Vector3, mat: Material, rot := Vector3.ZERO, parent: Node = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot
	(parent if parent != null else self).add_child(mi)
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


## A counter behind a steel grate: a low wall, a grate of thin bars over the window opening, a
## price board, an order terminal, and a wall delivery station beside it.
func _build_window() -> void:
	var wall := _mat("wall", Color(0.66, 0.63, 0.58), 0.85)
	var steel := _mat("steel", Color(0.42, 0.44, 0.46), 0.35, 0.7)
	var counter := _mat("counter", Color(0.3, 0.32, 0.34), 0.5, 0.4)
	var board := _mat("board", Color(0.08, 0.07, 0.06), 0.8)
	var glow := _mat("glow", Color(0.02, 0.05, 0.02), 0.3, 0.0, Color(0.25, 0.9, 0.35), 1.3)
	var dark := _mat("dark", Color(0.05, 0.05, 0.06), 0.6)

	# Low counter wall either side of the window opening (opening is 1.1m wide, centred).
	_box(Vector3(0.5, 1.1, 0.4), Vector3(-0.8, 0.55, 0.0), wall)
	_box(Vector3(0.5, 1.1, 0.4), Vector3(0.8, 0.55, 0.0), wall)
	_box(Vector3(1.9, 0.08, 0.4), Vector3(0.0, 1.14, 0.0), counter)
	# Steel grate across the opening: vertical bars, close enough together nobody reaches through.
	for i in 8:
		var x := -0.5 + i * (1.0 / 7.0)
		_box(Vector3(0.02, 0.9, 0.02), Vector3(x, 1.6, 0.0), steel)
	_box(Vector3(1.1, 0.03, 0.03), Vector3(0.0, 1.15, 0.0), steel)
	_box(Vector3(1.1, 0.03, 0.03), Vector3(0.0, 2.05, 0.0), steel)

	# Price board and order terminal.
	_box(Vector3(1.0, 0.4, 0.03), Vector3(0.0, 2.35, -0.02), board)
	var head := _label("PHARMACY", 44, Color(0.85, 0.92, 1.0))
	head.position = Vector3(0.0, 2.46, 0.0)
	_price = _label("", 32, Color(0.8, 1.0, 0.85))
	_price.position = Vector3(0.0, 2.26, 0.0)
	_box(Vector3(0.18, 0.14, 0.05), Vector3(-0.8, 0.95, 0.21), dark)
	_box(Vector3(0.1, 0.07, 0.01), Vector3(-0.8, 0.97, 0.24), glow)

	# The wall delivery station: a steel box with a hatch the tube capsule drops out of.
	var station := Node3D.new()
	station.position = Vector3(1.35, 0.0, 0.05)
	add_child(station)
	_box(Vector3(0.42, 0.42, 0.22), Vector3(0.0, 1.0, 0.0), steel, Vector3.ZERO, station)
	_box(Vector3(0.3, 0.03, 0.2), Vector3(0.0, 0.83, 0.0), dark, Vector3.ZERO, station)
	var tube := _cyl(0.05, 0.25, steel)
	tube.rotation_degrees = Vector3(90, 0, 0)
	tube.position = Vector3(0.0, 1.5, -0.02)
	station.add_child(tube)
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(0.7, 0.9, 1.0)
	lamp.light_energy = 0.5
	lamp.omni_range = 1.6
	lamp.shadow_enabled = false
	lamp.position = Vector3(0.0, 1.3, 0.0)
	station.add_child(lamp)
	_delivery_slot = station.position + Vector3(0.0, 0.72, 0.14)

	_shape(Vector3(0.5, 1.4, 0.4), Vector3(-0.8, 0.7, 0.0))
	_shape(Vector3(0.5, 1.4, 0.4), Vector3(0.8, 0.7, 0.0))
	_shape(Vector3(0.5, 1.4, 0.3), Vector3(1.35, 0.7, 0.05))


## HUB REDESIGN: the pharmacist, standing idle behind the grate. Previously a plain capsule
## silhouette; now the actual Night Nurse model (docs/CONTRACTS.md "The Night Nurse's model"),
## reused purely as set dressing -- no Monster node, no brain, no AI, never watched, never a
## threat. Chosen over the capsule for two reasons: it costs nothing extra (her asset and
## materials are already warmed for the real encounters, `scripts/warmup.gd`) and it plants a
## quiet, deniable foreshadowing beat ("was that her?") consistent with the design doc's
## "you never clearly see the pharmacist" line, without adding any mechanic -- she just stands in
## Idle, dimly lit, and the same drift/duck-out-of-view timing the old silhouette used still hides
## her most of the time so she never reads as a real encounter.
func _build_pharmacist() -> void:
	_nurse_base_x = -0.15
	_nurse = MonsterModelScript.new()
	_nurse.name = "Pharmacist"
	add_child(_nurse)
	_nurse.setup("night_nurse")
	# Her rig's front is -Z (docs/CONTRACTS.md); turn her to face the grate/the player's side.
	_nurse.rotation_degrees.y = 180.0
	_nurse.position = Vector3(_nurse_base_x, 0.0, -1.05)


func _cyl(r: float, h: float, mat: Material, sides := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	c.rings = 1
	mi.mesh = c
	mi.material_override = mat
	return mi


func _process(delta: float) -> void:
	_shape_t += delta
	if _nurse != null:
		# A slow, small drift, like someone shifting their weight. Never a clear silhouette: she
		# ducks out of view (behind the counter wall, out of the grate's sightline) now and then.
		_nurse.position.x = _nurse_base_x + sin(_shape_t * 0.35) * 0.08
		_nurse.visible = sin(_shape_t * 0.19) > -0.7
	var g := _game()
	if _price != null and g != null:
		var text := "PLACEBO PILLS  $%d/10" % int(g.PILL_PRICE)
		if _price.text != text:
			_price.text = text
	_tick_delivery(delta)


# ---------------------------------------------------------------------------
# tube delivery

## Host and every machine that shows it: queue a capsule delivery. Called by game.buy_pills()
## right after the money is taken; DELIVER_SECONDS later a capsule thunks into the station and
## the host drops the item there. The animation itself is harmless to run on every machine (it
## reads the queue locally), but only the host actually spawns the world item.
func queue_delivery(kind: String, count: int) -> void:
	_queue.append({"kind": kind, "count": count, "t": DELIVER_SECONDS})


func _tick_delivery(delta: float) -> void:
	if _queue.is_empty():
		_capsule_t = 0.0
		if _capsule != null:
			_capsule.visible = false
		return
	var e: Dictionary = _queue[0]
	e.t -= delta
	if _capsule == null:
		_capsule = _cyl(0.045, 0.14, _mat("capsule", Color(0.85, 0.7, 0.2), 0.35, 0.3))
		_capsule.rotation_degrees = Vector3(90, 0, 0)
		add_child(_capsule)
	_capsule.visible = true
	_capsule.position = _delivery_slot + Vector3.UP * clampf(e.t / DELIVER_SECONDS, 0.0, 1.0) * 0.5
	if e.t <= 0.0:
		_queue.pop_front()
		_capsule.visible = false
		var g := _game()
		if g != null and g.is_host():
			g._sound("economy_buy", global_position + _delivery_slot)
			var xf := Transform3D(Basis(), global_position + _delivery_slot + Vector3.UP * 0.05)
			var it = g._spawn_item(String(e.kind), int(e.count), xf, WorldItem.State.LOOSE)
			if it != null:
				it.value = 0
	else:
		_queue[0] = e
