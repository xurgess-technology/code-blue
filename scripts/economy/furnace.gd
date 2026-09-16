extends Node3D
## SWEEP 4A HOOK (pharmacy, chunk 3), HUB REDESIGN (2026-09-15): the crematorium furnace, now
## inside its own walled room (docs/CONTRACTS.md "Hospital", scripts/level/entrance.gd) instead of
## a generic room. The brick shell is built wide and tall enough to read as part of the room's own
## back wall rather than a standalone box sitting in it: a hole with fire raging behind it, not a
## furnace-shaped prop parked in a room. All primitives, no new Blender models.
##
## Selling is throwing: there is no walk-up-and-click interactable here. A steel grate of bars
## across the mouth blocks players, monsters and carried bodies (a normal C.L_WORLD collider, the
## same as any wall) while still leaving gaps a thrown item can fly through; anything that gets
## through lands in `FireZone`, an Area3D that only monitors world items (C.L_PICKUP), where the
## host resolves a sale. A throw that hits a bar instead bounces off onto the floor, same as any
## other miss. Unsellable items (surgical tools, the guide, an empty pill bottle already eaten to
## nothing) are given a bounce back out rather than consumed. HUB REDESIGN touched only the shell
## and the dressing around it -- the grate, FireZone and selling logic below are unchanged.
##
## Local frame: origin on the floor, mouth facing +Z (a player stands in +Z looking at -Z).

const ItemsDB := preload("res://scripts/items.gd")
const LightFlickerScript := preload("res://scripts/light_flicker.gd")

var game: Node = null
var _fire_zone: Area3D
var _flame_cards: Array = []
var _flame_t := 0.0
var _burst_t := 0.0
var _amount_label: Label3D


static func create(g: Node) -> Node3D:
	var n := new()
	n.game = g
	n.name = "Furnace"
	n._build()
	return n


func _game() -> Node:
	if game != null and is_instance_valid(game):
		return game
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


# ---------------------------------------------------------------------------
# model

static var _mats := {}


static func _mat(key: String, col: Color, rough := 0.6, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "furn_" + key
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


func _label(text: String, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.0035
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.modulate = col
	return l


func _build() -> void:
	var steel := _mat("steel", Color(0.4, 0.4, 0.42), 0.4, 0.65)
	var soot := _mat("soot", Color(0.08, 0.08, 0.08), 0.9)
	var brick := _mat("brick", Color(0.28, 0.16, 0.12), 0.85)
	var fire := _mat("fire", Color(1.0, 0.45, 0.1), 0.4, 0.0, Color(1.0, 0.45, 0.08), 2.4)
	var fire2 := _mat("fire2", Color(1.0, 0.75, 0.2), 0.4, 0.0, Color(1.0, 0.65, 0.15), 2.0)
	var urn := _mat("urn", Color(0.35, 0.32, 0.24), 0.55, 0.2)
	var cart := _mat("cart", Color(0.3, 0.3, 0.32), 0.45, 0.5)

	# The furnace body: a brick block with an open steel door and a dark mouth. The mouth runs
	# tall (about knee to well over head height) so a throw released around chest/eye height,
	# arcing up a little on a full charge, still clears the grate instead of sailing over it.
	# HUB REDESIGN: wide brick wings and a wide back wall (matching the invisible collision
	# `_furnace_solid` adds further down, docs comment there) so the furnace reads as built into
	# the crematorium room's own back wall, not a box standing in the middle of it. Kept at the
	# original 2.3 m height rather than reaching the room's full ceiling (`C.WALL_H`, 3.0 m): a
	# full-height collider here made a fully-charged throw's upward arc occasionally clip the top
	# edge on its way to the grate and miss FireZone entirely, an intermittent
	# `tools/devtest.gd` "dev room's furnace burns the defibrillator" failure this room's tighter
	# quarters exposed (docs/KNOWN_ISSUES.md). Widening only in X, not Y, keeps the mouth's own
	# clearance exactly as wide as it always was.
	var wing_h := 2.3
	_box(Vector3(1.3, wing_h, 1.3), Vector3(-1.15, wing_h * 0.5, -0.9), brick)
	_box(Vector3(1.3, wing_h, 1.3), Vector3(1.15, wing_h * 0.5, -0.9), brick)
	_box(Vector3(3.9, wing_h, 0.4), Vector3(0, wing_h * 0.5, -1.55), brick)
	_box(Vector3(1.6, 2.3, 1.3), Vector3(0, 1.15, -0.9), brick)
	_box(Vector3(1.0, 1.7, 0.05), Vector3(-0.75, 1.0, -0.3), steel, Vector3(0, -40, 0))   # open door, swung out
	_box(Vector3(1.0, 1.7, 0.9), Vector3(0.0, 1.0, -0.4), soot)   # dark mouth interior
	# Steel grate across the mouth: bars close enough nobody (and no bulky item) fits between them,
	# with gaps generous enough that a reasonably-aimed thrown pill or stack of loot reliably sails
	# through (a narrower grate looked right but meant a few centimetres of throw drift -- from a
	# walked-up player, not just a test bot -- was enough to clip a bar instead of scoring).
	# SWEEP 4A FOLLOW-UP: 0.4 m spacing (~0.36-0.37 m gaps) was still borderline for the widest
	# loot (the defibrillator, 0.36 m) -- widened to 0.45 m (~0.40-0.42 m gaps), still nowhere
	# near C.PLAYER_RADIUS*2 (0.8 m) so the "no body fits through" rule holds comfortably.
	for i in 3:
		var x := -0.45 + i * 0.45
		_box(Vector3(0.03, 1.55, 0.03), Vector3(x, 1.0, -0.02), steel)
	_box(Vector3(0.9, 0.03, 0.03), Vector3(0.0, 0.24, -0.02), steel)
	_box(Vector3(0.9, 0.03, 0.03), Vector3(0.0, 1.76, -0.02), steel)

	# A handful of emissive cards for the fire glow, cheap and billboard-ish (perfprobe target).
	for i in 4:
		var card := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(0.5 - i * 0.06, 0.55 - i * 0.06)
		card.mesh = pm
		card.material_override = fire if i % 2 == 0 else fire2
		card.position = Vector3((i - 1.5) * 0.14, 0.75 + i * 0.03, -0.55 + i * 0.05)
		card.rotation_degrees = Vector3(0, 25.0 * i, 0)
		add_child(card)
		_flame_cards.append(card)

	var fire_light := OmniLight3D.new()
	fire_light.light_color = Color(1.0, 0.55, 0.2)
	fire_light.light_energy = 1.4
	fire_light.omni_range = 3.2
	fire_light.shadow_enabled = false
	fire_light.light_volumetric_fog_energy = 0.2
	fire_light.position = Vector3(0.0, 0.95, -0.5)
	fire_light.set_meta("mode", LightFlickerScript.MODE_FLICKER)
	fire_light.set_meta("seed", 4177)
	fire_light.set_meta("base_energy", 1.4)
	add_child(fire_light)
	var flick := LightFlickerScript.new()
	flick.buzz_enabled = false
	fire_light.add_child(flick)

	# Set dressing: a cremation cart and a shelf of empty urns, off to the side.
	var cart_node := Node3D.new()
	cart_node.position = Vector3(1.1, 0.0, 0.5)
	add_child(cart_node)
	_box(Vector3(0.7, 0.06, 0.36), Vector3(0, 0.55, 0), cart, Vector3.ZERO, cart_node)
	for x in [-0.3, 0.3]:
		for z in [-0.15, 0.15]:
			_box(Vector3(0.04, 0.5, 0.04), Vector3(x, 0.27, z), cart, Vector3.ZERO, cart_node)
	for x in [-0.3, 0.3]:
		var wheel := _cyl(0.06, 0.03, _mat("wheel", Color(0.05, 0.05, 0.05), 0.9), 10)
		wheel.rotation_degrees = Vector3(90, 0, 0)
		wheel.position = Vector3(x, 0.06, 0.16)
		cart_node.add_child(wheel)

	var shelf := Node3D.new()
	shelf.position = Vector3(-1.1, 0.0, 0.4)
	add_child(shelf)
	_box(Vector3(0.5, 0.04, 0.24), Vector3(0, 0.6, 0), cart, Vector3.ZERO, shelf)
	_box(Vector3(0.5, 0.04, 0.24), Vector3(0, 0.95, 0), cart, Vector3.ZERO, shelf)
	for i in 4:
		var u := _cyl(0.06 - (i % 2) * 0.01, 0.14, urn, 10)
		u.position = Vector3(-0.18 + i * 0.12, 0.62 if i < 2 else 0.97, 0.0)
		shelf.add_child(u)

	# HUB REDESIGN: a scorched floor patch and a small hazard light -- cheap dressing that sells
	# the room as a real crematorium rather than a furnace standing on ordinary lobby flooring.
	var scorch := MeshInstance3D.new()
	var scorch_mesh := PlaneMesh.new()
	scorch_mesh.size = Vector2(2.6, 2.2)
	scorch.mesh = scorch_mesh
	scorch.material_override = _mat("scorch", Color(0.05, 0.045, 0.04), 0.95)
	scorch.position = Vector3(0.0, 0.01, -0.2)
	scorch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(scorch)
	var hazard := OmniLight3D.new()
	hazard.light_color = Color(1.0, 0.2, 0.15)
	hazard.light_energy = 0.35
	hazard.omni_range = 2.0
	hazard.shadow_enabled = false
	hazard.position = Vector3(0.0, C.WALL_H - 0.2, -0.3)
	add_child(hazard)

	var sign := _label("CREMATORIUM: THROW TO SELL", 30, Color(1.0, 0.65, 0.4))
	sign.position = Vector3(0.0, 2.0, -0.5)
	sign.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	add_child(sign)

	_amount_label = _label("", 40, Color(0.55, 1.0, 0.6))
	_amount_label.position = Vector3(0.0, 1.8, -0.4)
	_amount_label.visible = false
	add_child(_amount_label)

	# The grate frame: a real collider (C.L_WORLD, like any wall) so players, monsters and carried
	# bodies bounce off it and can never go in; thrown items pass through the gaps to FireZone.
	var body := StaticBody3D.new()
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	add_child(body)
	for i in 3:
		var x := -0.45 + i * 0.45
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.05, 1.6, 0.05)
		cs.shape = bs
		cs.position = Vector3(x, 1.0, -0.02)
		body.add_child(cs)
	# The brick shell, as a frame around the mouth rather than one solid block: a solid block
	# spanning the whole body would also block the opening BEHIND the grate, defeating the gaps
	# the bars leave for a thrown item to reach FireZone through. Side wings, a back wall (set
	# back past FireZone) and a lid; nothing covers the mouth's own footprint.
	# HUB REDESIGN: the wings and back wall are built wide enough to fill most of the crematorium
	# room's back wall, so the furnace reads as built into the room rather than a box standing in
	# it, matched to the same (unchanged, 2.3 m) height as the visual brick above -- see that
	# comment for why this stayed at the mouth's original height instead of reaching the ceiling.
	# The mouth/grate/FireZone footprint above is untouched.
	_furnace_solid(body, Vector3(1.3, wing_h, 1.3), Vector3(-1.15, wing_h * 0.5, -0.9))    # west wing
	_furnace_solid(body, Vector3(1.3, wing_h, 1.3), Vector3(1.15, wing_h * 0.5, -0.9))     # east wing
	_furnace_solid(body, Vector3(3.9, wing_h, 0.4), Vector3(0, wing_h * 0.5, -1.55))       # back wall
	_furnace_solid(body, Vector3(1.6, 0.45, 1.3), Vector3(0, 2.075, -0.9))      # lid over the mouth

	# FireZone: only sees world items (C.L_PICKUP). A body that reaches here got through the grate.
	_fire_zone = Area3D.new()
	_fire_zone.name = "FireZone"
	_fire_zone.collision_layer = 0
	_fire_zone.collision_mask = C.L_PICKUP
	_fire_zone.monitoring = true
	_fire_zone.monitorable = false
	var fz_shape := CollisionShape3D.new()
	var fz_box := BoxShape3D.new()
	fz_box.size = Vector3(0.85, 1.7, 0.8)
	fz_shape.shape = fz_box
	fz_shape.position = Vector3(0.0, 1.0, -0.5)
	_fire_zone.add_child(fz_shape)
	add_child(_fire_zone)
	_fire_zone.body_entered.connect(_on_body_entered)


## The furnace's outer brick block, as a coarse blocker (so nobody clips through the sides).
func _furnace_solid(body: StaticBody3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)


# ---------------------------------------------------------------------------
# selling

func _on_body_entered(body: Node) -> void:
	var g := _game()
	if g == null or not g.is_host() or not (body is WorldItem):
		return
	var it: WorldItem = body
	var kind := String(it.kind)
	var count := int(it.count)
	if not g.furnace_can_sell(kind):
		# Unsellable: bounce it back out through the mouth rather than consuming it.
		it.toss(it.global_transform, global_transform.basis * Vector3(0, 2.0, 3.0))
		return
	var s := {"count": count, "v": int(it.value)}
	var value: int = int(g.furnace_value(kind, s))
	g.world_items.erase(it.item_id)
	it.queue_free()
	_burst()
	g.furnace_sell(kind, count, value, global_position + Vector3.UP * 1.0)
	_show_amount(value)


func _burst() -> void:
	_burst_t = 0.45


func _show_amount(value: int) -> void:
	if _amount_label == null:
		return
	_amount_label.text = "+$%d" % value if value > 0 else "$0"
	_amount_label.visible = true
	_amount_label.modulate.a = 1.0
	_amount_label.position.y = 1.4
	var tw := create_tween()
	tw.tween_property(_amount_label, "position:y", 2.0, 1.2)
	tw.parallel().tween_property(_amount_label, "modulate:a", 0.0, 1.2).set_delay(0.4)
	tw.tween_callback(func(): _amount_label.visible = false)


func _process(delta: float) -> void:
	_flame_t += delta
	for i in _flame_cards.size():
		var c: MeshInstance3D = _flame_cards[i]
		c.scale = Vector3.ONE * (1.0 + 0.06 * sin(_flame_t * (3.0 + i) + i))
	if _burst_t > 0.0:
		_burst_t -= delta
		var k := clampf(_burst_t / 0.45, 0.0, 1.0)
		for c in _flame_cards:
			c.scale = Vector3.ONE * (1.0 + 0.06 * sin(_flame_t * 4.0) + k * 0.5)
