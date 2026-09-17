extends Node3D
## The crematorium furnace, built into the wall (hub rebuild, 2026-09-16: Zach's "another room on the
## other side of a grated, openable window"). A window in the wall, a heavy grated hatch over it
## that anyone opens and shuts with E, and behind it a sealed fire chamber nobody can walk into.
## The fire's light spills out through the window and flickers across the room.
##
## Selling is throwing: with the hatch open, anything thrown through the window lands in `FireZone`
## (an Area3D that only monitors world items, C.L_PICKUP), where the host resolves a sale. Shut, the
## hatch is solid and throws bounce off it. Players can't climb in: the sill is higher than a jump.
## Unsellable things (surgical tools, the guide) are pushed back out of the window.
##
## Two builds of the same furnace:
##   deep (the hub)       the window is cut through a 1.5 m wall tile into a 3 m chamber: the level
##                        leaves those tiles as floor and walls around them (scripts/level/entrance.gd)
##   compact (dev room)   a free-standing brick block, 0.4 m of wall and a 1.4 m chamber
##
## The hatch state is host-authoritative (`hatch_open`, toggled by `interact`) and replicates in the
## game snapshot ("fh"); every machine animates it and plays the clank itself.
##
## Local frame: origin on the floor at the room-side face of the wall, the room toward +Z.

const ItemsDB := preload("res://scripts/items.gd")

const WIDTH := 3.3             # the facade across (the wall tiles' 3 m, a little into the neighbours)
const HOLE_W := 2.4
const SILL := 0.95             # above a standing jump (C.JUMP_VELOCITY: ~0.75 m)
const HEAD := 2.1
const HATCH_OPEN_DEG := -100.0
const HATCH_SECONDS := 0.45
const INTERACT_ID := "furnace_hatch"

var game: Node = null
var hatch_open := false
var wall_d := 1.5
var chamber_d := 3.0

var _fire_zone: Area3D
var _flame_cards: Array = []
var _flame_t := 0.0
var _burst_t := 0.0
var _amount_label: Label3D
var _hatch_pivot: Node3D
var _hatch_k := 0.0            # 0 shut .. 1 open, animated toward hatch_open
var _lights: Array = []        # [light, base energy]
var _noise := 0.0


static func create(g: Node, compact := false) -> Node3D:
	var n := new()
	n.game = g
	n.name = "Furnace"
	if compact:
		n.wall_d = 0.4
		n.chamber_d = 1.4
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


## A flame tongue: a radial glow anchored at the bottom, white-yellow at the root through orange to
## nothing at the tip and edges, added onto whatever is behind it. `deep` is a redder, dimmer one.
static func _flame_mat(deep: bool) -> StandardMaterial3D:
	var key := "flame_deep" if deep else "flame"
	if _mats.has(key):
		return _mats[key]
	var grad := Gradient.new()
	if deep:
		grad.set_color(0, Color(1.0, 0.45, 0.1, 0.9))
		grad.set_color(1, Color(0.6, 0.08, 0.0, 0.0))
		grad.add_point(0.45, Color(0.95, 0.25, 0.04, 0.55))
	else:
		grad.set_color(0, Color(1.0, 0.92, 0.6, 1.0))
		grad.set_color(1, Color(0.9, 0.18, 0.0, 0.0))
		grad.add_point(0.3, Color(1.0, 0.62, 0.15, 0.85))
		grad.add_point(0.65, Color(1.0, 0.32, 0.04, 0.35))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	# Radius just past half the card: fully faded before the sides, and on a tall card the circle in
	# UV space stretches into a tongue.
	tex.fill_from = Vector2(0.5, 1.0)
	tex.fill_to = Vector2(0.5, 0.45)
	tex.width = 64
	tex.height = 128
	var m := StandardMaterial3D.new()
	m.resource_name = "furn_" + key
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.albedo_texture = tex
	m.albedo_color = Color(1.6, 1.3, 1.1) if not deep else Color(1.2, 1.0, 1.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
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


func _solid(body: CollisionObject3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)


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
	var steel := _mat("steel", Color(0.36, 0.36, 0.38), 0.4, 0.7)
	var dark_steel := _mat("dark_steel", Color(0.12, 0.12, 0.13), 0.5, 0.6)
	# The same charred black as the crematorium's floor, walls and ceiling (HospitalBuilder.CHAR_COLOR).
	var brick := _mat("brick", Color(0.11, 0.085, 0.07), 0.9)
	var soot := _mat("soot", Color(0.05, 0.045, 0.04), 0.95)
	var ember := _mat("ember", Color(0.5, 0.12, 0.02), 0.8, 0.0, Color(1.0, 0.32, 0.05), 2.2)
	var hw := WIDTH * 0.5
	var hole := HOLE_W * 0.5
	var back := -(wall_d + chamber_d)
	var mid_c := -wall_d - chamber_d * 0.5

	var body := StaticBody3D.new()
	body.name = "Shell"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	add_child(body)

	# ---- the wall around the window: jambs, sill and lintel, 1 cm proud of the level's wall ------
	var jamb_w := hw - hole
	for s in [-1.0, 1.0]:
		var jx: float = s * (hole + jamb_w * 0.5)
		_box(Vector3(jamb_w, C.WALL_H, wall_d), Vector3(jx, C.WALL_H * 0.5, 0.01 - wall_d * 0.5), brick)
		_solid(body, Vector3(jamb_w, C.WALL_H, wall_d), Vector3(jx, C.WALL_H * 0.5, 0.01 - wall_d * 0.5))
	_box(Vector3(HOLE_W, SILL, wall_d), Vector3(0, SILL * 0.5, 0.01 - wall_d * 0.5), brick)
	_solid(body, Vector3(HOLE_W, SILL, wall_d), Vector3(0, SILL * 0.5, 0.01 - wall_d * 0.5))
	_box(Vector3(HOLE_W, C.WALL_H - HEAD, wall_d), Vector3(0, (HEAD + C.WALL_H) * 0.5, 0.01 - wall_d * 0.5), brick)
	_solid(body, Vector3(HOLE_W, C.WALL_H - HEAD, wall_d), Vector3(0, (HEAD + C.WALL_H) * 0.5, 0.01 - wall_d * 0.5))
	# A steel frame round the opening, on the room face.
	var fz := 0.035
	_box(Vector3(HOLE_W + 0.24, 0.12, 0.05), Vector3(0, HEAD + 0.06, fz), dark_steel)
	_box(Vector3(HOLE_W + 0.24, 0.12, 0.05), Vector3(0, SILL - 0.06, fz), dark_steel)
	for s in [-1.0, 1.0]:
		_box(Vector3(0.12, HEAD - SILL + 0.24, 0.05), Vector3(s * (hole + 0.06), (SILL + HEAD) * 0.5, fz), dark_steel)
	# Soot on the lintel above the opening, where the heat comes out.
	_box(Vector3(HOLE_W * 0.8, 0.5, 0.02), Vector3(0, HEAD + 0.38, 0.02), soot)

	# ---- the chamber: brick lining a little inside the level's pocket, a bed of embers, the fire ----
	var inner := hw - 0.2
	for s in [-1.0, 1.0]:
		_box(Vector3(0.2, C.WALL_H, chamber_d), Vector3(s * (inner + 0.1), C.WALL_H * 0.5, mid_c), brick)
		_solid(body, Vector3(0.2, C.WALL_H, chamber_d), Vector3(s * (inner + 0.1), C.WALL_H * 0.5, mid_c))
	_box(Vector3(WIDTH, C.WALL_H, 0.2), Vector3(0, C.WALL_H * 0.5, back + 0.1), brick)
	_solid(body, Vector3(WIDTH, C.WALL_H, 0.2), Vector3(0, C.WALL_H * 0.5, back + 0.1))
	_box(Vector3(WIDTH, 0.1, chamber_d), Vector3(0, C.WALL_H - 0.05, mid_c), soot)
	# A raised brick hearth, so the fire burns at the window's height rather than behind the sill.
	var hearth := 0.6
	_box(Vector3(inner * 2.0, hearth, chamber_d - 0.1), Vector3(0, hearth * 0.5, mid_c), brick)
	_box(Vector3(inner * 2.0 - 0.1, 0.04, chamber_d - 0.3), Vector3(0, hearth + 0.02, mid_c), soot)
	_solid(body, Vector3(inner * 2.0, hearth, chamber_d), Vector3(0, hearth * 0.5, mid_c))
	var rng := RandomNumberGenerator.new()
	rng.seed = 911
	for i in 18:
		var coal := _box(Vector3(rng.randf_range(0.2, 0.45), rng.randf_range(0.08, 0.18), rng.randf_range(0.2, 0.4)),
				Vector3(rng.randf_range(-inner + 0.3, inner - 0.3), hearth + 0.08, rng.randf_range(back + 0.4, -wall_d - 0.3)), ember if i % 3 != 0 else soot)
		coal.rotation.y = rng.randf_range(0.0, TAU)

	# Flames: soft additive tongues (a glow that fades out at the edges and tip), facing the camera,
	# overlapping in two rows so the fire has depth. Cards sway and stretch in _process.
	for i in 16:
		var card := MeshInstance3D.new()
		var qm := QuadMesh.new()
		var h := rng.randf_range(0.9, 2.0)
		qm.size = Vector2(rng.randf_range(0.5, 0.9), h)
		qm.center_offset = Vector3(0, h * 0.5, 0)
		card.mesh = qm
		card.material_override = _flame_mat(i % 3 == 0)
		card.position = Vector3(rng.randf_range(-inner + 0.4, inner - 0.4), hearth + 0.02,
				lerpf(-wall_d - 0.5, back + 0.45, float(i % 2) * 0.6 + rng.randf() * 0.4))
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(card)
		_flame_cards.append(card)

	# ---- light: inside the chamber, and thrown out through the window into the room -----------------
	var chamber_light := OmniLight3D.new()
	chamber_light.light_color = Color(1.0, 0.5, 0.18)
	chamber_light.omni_range = maxf(3.0, chamber_d + 1.2)
	chamber_light.shadow_enabled = false
	chamber_light.position = Vector3(0, 1.3, mid_c)
	add_child(chamber_light)
	_lights.append([chamber_light, 1.1])
	var spill := SpotLight3D.new()
	spill.light_color = Color(1.0, 0.52, 0.2)
	spill.spot_range = 18.0
	spill.spot_angle = 80.0
	spill.spot_attenuation = 0.9
	spill.shadow_enabled = false
	spill.light_volumetric_fog_energy = 0.6
	spill.position = Vector3(0, 1.0, -wall_d - 0.4)
	spill.rotation_degrees = Vector3(12, 180, 0)   # out of the window (+Z), tipped up onto the ceiling
	add_child(spill)
	_lights.append([spill, 12.0])   # the room is black brick: it takes a lot of fire to glow on it
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.45, 0.15)
	glow.omni_range = 9.0
	glow.shadow_enabled = false
	glow.position = Vector3(0, 1.6, 0.6)
	add_child(glow)
	_lights.append([glow, 2.6])

	# ---- the hatch: a heavy grate hinged at one side of the opening, swinging out into the room -----
	_hatch_pivot = Node3D.new()
	_hatch_pivot.name = "Hatch"
	_hatch_pivot.position = Vector3(-hole, 0, 0.09)
	add_child(_hatch_pivot)
	var leaf_h := HEAD - SILL
	var leaf_y := (SILL + HEAD) * 0.5
	for y in [SILL + 0.04, HEAD - 0.04]:
		_box(Vector3(HOLE_W, 0.07, 0.07), Vector3(hole, y, 0), steel, _hatch_pivot)
	for x in [0.035, HOLE_W - 0.035]:
		_box(Vector3(0.07, leaf_h, 0.07), Vector3(x, leaf_y, 0), steel, _hatch_pivot)
	var bars := 11
	for i in bars:
		_box(Vector3(0.035, leaf_h - 0.08, 0.035), Vector3(0.2 + i * (HOLE_W - 0.4) / float(bars - 1), leaf_y, 0), steel, _hatch_pivot)
	_box(Vector3(HOLE_W, 0.04, 0.04), Vector3(hole, leaf_y, 0), steel, _hatch_pivot)
	_box(Vector3(0.05, 0.3, 0.12), Vector3(HOLE_W - 0.18, leaf_y, 0.08), dark_steel, _hatch_pivot)   # handle
	var hatch_body := AnimatableBody3D.new()
	hatch_body.name = "HatchBody"
	hatch_body.collision_layer = C.L_WORLD
	hatch_body.collision_mask = 0
	hatch_body.sync_to_physics = false
	_hatch_pivot.add_child(hatch_body)
	_solid(hatch_body, Vector3(HOLE_W, leaf_h, 0.08), Vector3(hole, leaf_y, 0))

	# What you aim at to open or shut it: the opening itself, on the interact layer only (throws and
	# players pass straight through it).
	var aim := HatchAim.new()
	aim.furnace = self
	aim.name = "HatchAim"
	aim.add_to_group("interactable")
	aim.set_meta("interact_id", INTERACT_ID)
	aim.collision_layer = C.L_INTERACT
	aim.collision_mask = 0
	aim.monitoring = false
	aim.monitorable = true
	aim.position = Vector3(0, leaf_y, 0.2)
	_solid(aim, Vector3(HOLE_W, leaf_h, 0.2), Vector3.ZERO)
	add_child(aim)

	_amount_label = _label("", 40, Color(0.55, 1.0, 0.6))
	_amount_label.position = Vector3(0, 1.8, 0.5)
	_amount_label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_amount_label.visible = false
	add_child(_amount_label)

	# FireZone: the window's depth above the sill and the whole chamber.
	_fire_zone = Area3D.new()
	_fire_zone.name = "FireZone"
	_fire_zone.collision_layer = 0
	_fire_zone.collision_mask = C.L_PICKUP
	_fire_zone.monitoring = true
	_fire_zone.monitorable = false
	var fz_hole := CollisionShape3D.new()
	var hole_box := BoxShape3D.new()
	hole_box.size = Vector3(HOLE_W, leaf_h, wall_d - 0.1)
	fz_hole.shape = hole_box
	fz_hole.position = Vector3(0, leaf_y, -wall_d * 0.5 - 0.05)
	_fire_zone.add_child(fz_hole)
	var fz_chamber := CollisionShape3D.new()
	var chamber_box := BoxShape3D.new()
	chamber_box.size = Vector3(inner * 2.0, C.WALL_H - 0.3, chamber_d)
	fz_chamber.shape = chamber_box
	fz_chamber.position = Vector3(0, C.WALL_H * 0.5, mid_c)
	_fire_zone.add_child(fz_chamber)
	add_child(_fire_zone)
	_fire_zone.body_entered.connect(_on_body_entered)
	_apply_hatch()


class HatchAim extends Area3D:
	var furnace: Node

	func interact_prompt(_p) -> String:
		return "Shut the furnace hatch" if furnace.hatch_open else "Open the furnace hatch"

	func interact_hold() -> float:
		return 0.0

	func interact(_p) -> void:
		furnace.set_hatch(not furnace.hatch_open)


# ---------------------------------------------------------------------------
# the hatch

## Open or shut the hatch. The host calls it (interact); clients from the snapshot (game "fh").
func set_hatch(open: bool, animate := true) -> void:
	if open == hatch_open:
		return
	hatch_open = open
	if not animate:
		_hatch_k = 1.0 if open else 0.0
		_apply_hatch()
		return
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		Audio.play("doors_heavy" if open else "doors_slam", global_position + global_basis * Vector3(0, 1.5, 0.3), -3.0, 0.05)


func _apply_hatch() -> void:
	if _hatch_pivot != null:
		_hatch_pivot.rotation_degrees.y = HATCH_OPEN_DEG * ease(_hatch_k, -1.8)


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
		# Unsellable: back out of the window onto the floor in front of it.
		var out := Transform3D(it.global_basis, global_transform * Vector3(randf_range(-0.6, 0.6), HEAD - 0.3, 0.45))
		it.toss(out, global_basis * Vector3(0, 1.2, 2.2))
		return
	# A hand-slot shaped stack ({kind, count, v, bt}): brains price by kind and their spoil clock.
	var s := {"kind": kind, "count": count, "v": int(it.value), "bt": float(it.bt)}
	var value: int = int(g.furnace_value(kind, s))
	g.world_items.erase(it.item_id)
	it.queue_free()
	_burst()
	g.furnace_sell(kind, count, value, global_transform * Vector3(0, 1.4, 0.3))
	_show_amount(value)


func _burst() -> void:
	_burst_t = 0.6


## Patient exits (corpses.gd): a body went in. A bigger, longer flare than a sale, and a roar.
func flare() -> void:
	_burst_t = 1.6
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		Audio.play("economy_sell", global_transform * Vector3(0, 1.4, 0.3), 2.0, 0.05)
		Audio.play("dissection_crack", global_transform * Vector3(0, 1.2, -0.8), -6.0, 0.1)


func _show_amount(value: int) -> void:
	if _amount_label == null:
		return
	_amount_label.text = "+$%d" % value if value > 0 else "$0"
	_amount_label.visible = true
	_amount_label.modulate.a = 1.0
	_amount_label.position.y = 1.6
	var tw := create_tween()
	tw.tween_property(_amount_label, "position:y", 2.2, 1.2)
	tw.parallel().tween_property(_amount_label, "modulate:a", 0.0, 1.2).set_delay(0.4)
	tw.tween_callback(func(): _amount_label.visible = false)


func _process(delta: float) -> void:
	_flame_t += delta
	var target := 1.0 if hatch_open else 0.0
	if not is_equal_approx(_hatch_k, target):
		_hatch_k = move_toward(_hatch_k, target, delta / HATCH_SECONDS)
		_apply_hatch()
	var boost := 0.0
	if _burst_t > 0.0:
		_burst_t -= delta
		boost = clampf(_burst_t / 0.6, 0.0, 1.6)
	for i in _flame_cards.size():
		var c: MeshInstance3D = _flame_cards[i]
		c.scale = Vector3(1.0 + 0.1 * sin(_flame_t * (4.0 + i) + i),
				0.85 + 0.25 * absf(sin(_flame_t * (3.1 + i * 0.53) + i * 2.1)) + 0.1 * sin(_flame_t * 11.0 + i) + boost * 0.7, 1.0)
	# Firelight: two slow swells and a quick shiver, with a little random drift so it never loops.
	_noise = lerpf(_noise, randf_range(-1.0, 1.0), clampf(delta * 9.0, 0.0, 1.0))
	var k := 0.8 + 0.1 * sin(_flame_t * 2.3) + 0.07 * sin(_flame_t * 6.7 + 1.3) + 0.09 * _noise + boost * 0.7
	for l in _lights:
		(l[0] as Light3D).light_energy = float(l[1]) * k
