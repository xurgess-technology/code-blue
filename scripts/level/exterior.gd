extends RefCounted
## St. Doe's General from the parking lot (2026-09-17, a first pass): the storeys above the ground
## floor, lit and dark windows, the signs, planters by the wall. Set dressing only, all of it out of
## reach above the lot or against the building, built after the level on every machine from what
## level_info already says (neutral_rect, entrance, entrance_rect, ambulance), so nothing goes over
## the network.
##
##   - the building: a five-storey block over the entrance building, three storeys either side of
##     it along the rest of the lot's north edge; ribbon windows (a few lit), floor bands, a cornice
##   - "ST. DOE'S GENERAL HOSPITAL" in channel letters over the canopy (one letter dead, one
##     flickering), a blue "H" on the roof, "MAIN ENTRANCE" on the canopy, a red "EMERGENCY" box
##     on the canopy over the ambulance bay, "AMBULANCE ONLY" painted on the lane
##   - a lit monument sign at the head of the walk in, concrete planters along the wall
## Benches, bins and the abandoned wheelchair are ordinary pieces (level/neutral.gd).
##
## Lighting: everything sits on the lot's render bits (light_rooms.gd), so the lot's lamps light it
## and the rooms behind the wall don't; the root is marked light_dynamic so game.gd leaves it alone.

const LightRooms := preload("res://scripts/level/light_rooms.gd")

const FLOOR_H := 3.0
## The upper storeys' underside, above the ground floor's ceiling (see _building).
const CEILING_CLEAR := 0.12
## Storeys above the ground floor: the block over the entrance building, and either side of it.
const CENTRE_STOREYS := 4
const SIDE_STOREYS := 2
## How far back from the front wall the upper storeys run (their sides show from the lot's corners).
const DEPTH := 24.0
## Past the lot's ends, into the fog, so the building never visibly stops.
const SIDE_PAD := 10.0
const WINDOW_PITCH := 3.0
const WINDOW_W := 1.9
const WINDOW_H := 1.35
const WINDOW_SILL := 0.85
## Share of windows lit, and of those, lit sickly green instead of warm.
const LIT_SHARE := 0.14
const GREEN_SHARE := 0.25
const SIGN_TEXT := "ST. DOE'S GENERAL HOSPITAL"
const SIGN_Y := 4.95
const SIGN_ADVANCE := 0.8
## West of the doors, so the ambulance bay's EMERGENCY box (east of them) never covers its end.
const SIGN_OFFSET_X := -3.6
## Letter indices in SIGN_TEXT: one burnt out, one on the way.
const SIGN_DEAD := 11      # the first E of GENERAL
const SIGN_FLICKER := 21   # the P of HOSPITAL
const CANOPY_TOP := 3.5
const CANOPY_FRONT := 5.4  # metres out from the wall (neutral.gd's canopy, 3.6 tiles)

static var _mats := {}


## Build the front on `level` from `info`; null on levels without a lot (the dev room, the fallback).
static func build(level: Node3D, info: Dictionary) -> Node3D:
	if not info.has("neutral_rect") or not info.has("entrance") or not info.has("entrance_rect"):
		return null
	var lot: Rect2 = info.neutral_rect
	if lot.size == Vector2.ZERO:
		return null
	var root := Node3D.new()
	root.name = "Exterior"
	root.set_meta("light_dynamic", true)
	level.add_child(root)
	var door: Vector3 = info.entrance.position
	var er: Rect2 = info.entrance_rect
	var front := lot.position.y
	var seed := int(info.get("map_seed", 0))
	_building(root, lot, er, front, seed, door.x)
	_main_sign(root, door, front)
	_canopy_signs(root, info, door, front)
	_roof_h(root, door, front)
	_monument(root, door, front)
	_planters(root, lot, door, info, front)
	_bind_lighting(root, info, Vector3(door.x, 0.0, front + 4.0))
	return root


## One of everything that draws, for scripts/warmup.gd.
static func warm(parent: Node3D) -> void:
	var n := Node3D.new()
	parent.add_child(n)
	_box(n, Vector3.ONE * 0.3, Vector3.ZERO, _concrete())
	_box(n, Vector3.ONE * 0.3, Vector3(0.4, 0, 0), _band())
	for key in ["glass", "lit_warm", "lit_green"]:
		_box(n, Vector3(0.3, 0.3, 0.02), Vector3(0.8, 0, 0), _window_mat(key))
	_box(n, Vector3.ONE * 0.3, Vector3(1.2, 0, 0), _mat("h_panel", Color(0.08, 0.25, 0.75), 0.4, Color(0.15, 0.4, 1.0), 1.6))
	_box(n, Vector3.ONE * 0.3, Vector3(1.6, 0, 0), _mat("shrub", Color(0.07, 0.13, 0.07), 0.95))
	_letter(n, "S", Vector3(2.0, 0, 0), 64, Color.WHITE)


# ---------------------------------------------------------------------------
# the building

static func _building(root: Node3D, lot: Rect2, er: Rect2, front: float, seed: int, door_x: float) -> void:
	var sign_half := _sign_width() * 0.5 + 1.2
	var x0 := lot.position.x - SIDE_PAD
	var x1 := lot.end.x + SIDE_PAD
	var cx0 := clampf(er.position.x, x0, x1)
	var cx1 := clampf(er.end.x, x0, x1)
	var centre_top := FLOOR_H * (1 + CENTRE_STOREYS)
	var side_top := FLOOR_H * (1 + SIDE_STOREYS)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("exterior|%d" % seed)
	# Masses: sit on the ground floor's walls (3 m) and run DEPTH back.
	var masses := [[cx0, cx1, centre_top], [x0, cx0, side_top], [cx1, x1, side_top]]
	var windows := {"glass": [], "lit_warm": [], "lit_green": []}
	for m in masses:
		var a: float = m[0]
		var b: float = m[1]
		var top: float = m[2]
		if b - a < 0.5:
			continue
		# The underside stands a little above the ground floor's ceiling (3 m): level with it, the two
		# z-fought and the lobby's ceiling flickered. The band at the floor line covers the gap outside.
		var bottom := FLOOR_H + CEILING_CLEAR
		var h := top - bottom
		_box(root, Vector3(b - a, h, DEPTH), Vector3((a + b) * 0.5, bottom + h * 0.5, front - DEPTH * 0.5), _concrete())
		# The cornice along the top, proud of the wall.
		_box(root, Vector3(b - a + 0.3, 0.45, 0.5), Vector3((a + b) * 0.5, top + 0.1, front + 0.1), _band())
		# A band at each floor line, and a row of windows on each storey above the ground floor.
		for f in range(1, int(round(top / FLOOR_H))):
			var fy := FLOOR_H * f
			_box(root, Vector3(b - a, 0.28, 0.2), Vector3((a + b) * 0.5, fy + 0.02, front + 0.1), _band())
			var n := int(floor((b - a - 0.6) / WINDOW_PITCH))
			var start := (a + b) * 0.5 - (n - 1) * WINDOW_PITCH * 0.5
			for i in n:
				var wx := start + i * WINDOW_PITCH
				# The main sign hangs on the first storey over the doors: no windows behind it.
				if f == 1 and absf(wx - (door_x + SIGN_OFFSET_X)) < sign_half:
					continue
				var key := "glass"
				if rng.randf() < LIT_SHARE:
					key = "lit_green" if rng.randf() < GREEN_SHARE else "lit_warm"
				(windows[key] as Array).append(Vector3(wx, fy + WINDOW_SILL + WINDOW_H * 0.5, front + 0.03))
			# The sill: one long ledge under the row.
			_box(root, Vector3(b - a - 0.4, 0.08, 0.16), Vector3((a + b) * 0.5, fy + WINDOW_SILL - 0.05, front + 0.08), _band())
	# The centre block's sides stand above its neighbours: windows there too, near the front.
	for side in [[cx0, -1.0], [cx1, 1.0]]:
		for f in range(1 + SIDE_STOREYS, 1 + CENTRE_STOREYS):
			for k in 3:
				var z := front - 2.5 - k * WINDOW_PITCH
				var key := "glass" if rng.randf() >= LIT_SHARE else "lit_warm"
				(windows[key] as Array).append(Vector4(float(side[0]) + float(side[1]) * 0.03, FLOOR_H * f + WINDOW_SILL + WINDOW_H * 0.5, z, float(side[1])))
	for key in windows.keys():
		_window_multimesh(root, key, windows[key])


## Windows of one kind as one MultiMesh: Vector3 (front face) or Vector4 (x, y, z, side: -1 west
## face, 1 east face).
static func _window_multimesh(root: Node3D, key: String, spots: Array) -> void:
	if spots.is_empty():
		return
	var q := QuadMesh.new()
	q.size = Vector2(WINDOW_W, WINDOW_H)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = q
	mm.instance_count = spots.size()
	for i in spots.size():
		var s = spots[i]
		if s is Vector4:
			var basis := Basis(Vector3.UP, PI * 0.5 * float(s.w))
			mm.set_instance_transform(i, Transform3D(basis, Vector3(s.x, s.y, s.z)))
		else:
			mm.set_instance_transform(i, Transform3D(Basis(), s))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Windows_" + key
	mmi.multimesh = mm
	mmi.material_override = _window_mat(key)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)


# ---------------------------------------------------------------------------
# signs

## Channel letters along the wall over the canopy, a raceway behind them, and a cold wash of light
## down the wall from them.
static func _main_sign(root: Node3D, door: Vector3, front: float) -> void:
	var text := SIGN_TEXT
	var width := _sign_width()
	var cx := door.x + SIGN_OFFSET_X
	_box(root, Vector3(width + 0.6, 0.18, 0.12), Vector3(cx, SIGN_Y - 0.62, front + 0.07), _band())
	var x := cx - width * 0.5
	for i in text.length():
		var c := text[i]
		var adv := _advance(c)
		if c != " ":
			# Brighter than white: the letters bloom a little through the fog.
			var col := Color(1.5, 1.7, 1.9)
			if i == SIGN_DEAD:
				col = Color(0.16, 0.17, 0.18)
			var l := _letter(root, c, Vector3(x + adv * 0.5, SIGN_Y, front + 0.16), 150, col)
			l.pixel_size = 0.0078
			if i == SIGN_FLICKER:
				var f := Flicker.new()
				f.label = l
				f.on_color = col
				l.add_child(f)
		x += adv
	var wash := OmniLight3D.new()
	wash.name = "SignWash"
	wash.light_color = Color(0.8, 0.9, 1.0)
	wash.light_energy = 1.1
	wash.omni_range = 7.5
	wash.shadow_enabled = false
	wash.position = Vector3(cx, SIGN_Y + 0.2, front + 1.6)
	root.add_child(wash)


## "MAIN ENTRANCE" on the canopy's front over the doors; a red "EMERGENCY" box standing on the
## canopy's edge over the ambulance bay, lighting the bay red; "AMBULANCE ONLY" on the lane.
static func _canopy_signs(root: Node3D, info: Dictionary, door: Vector3, front: float) -> void:
	var main := _letter(root, "MAIN ENTRANCE", Vector3(door.x, CANOPY_TOP - 0.17, front + CANOPY_FRONT + 0.02), 56, Color(0.9, 0.95, 1.0))
	main.pixel_size = 0.006
	if not info.has("ambulance"):
		return
	var bay: Vector3 = info.ambulance.position
	var at := Vector3(bay.x, CANOPY_TOP + 0.45, front + CANOPY_FRONT - 0.2)
	_box(root, Vector3(4.9, 0.9, 0.3), at, _mat("sign_white", Color(0.9, 0.9, 0.88), 0.5, Color(1, 1, 1), 0.35))
	var em := _letter(root, "EMERGENCY", at + Vector3(0, 0, 0.16), 120, Color(0.95, 0.08, 0.06))
	em.pixel_size = 0.006
	em.outline_size = 0
	var red := OmniLight3D.new()
	red.name = "EmergencyGlow"
	red.light_color = Color(1.0, 0.12, 0.1)
	red.light_energy = 1.6
	red.omni_range = 7.0
	red.shadow_enabled = false
	red.position = at + Vector3(0, 0.2, 1.0)
	root.add_child(red)
	# Painted on the lane in front of the bay, reading from the fog side.
	var lane: Vector3 = info.ambulance.get("lane_start", bay)
	var paint := _letter(root, "AMBULANCE ONLY", Vector3(bay.x, 0.02, lerpf(bay.z, lane.z, 0.45)), 96, Color(0.85, 0.72, 0.2, 0.85))
	paint.pixel_size = 0.009
	paint.shaded = true
	paint.outline_size = 0
	paint.rotation = Vector3(-PI * 0.5, 0.0, 0.0)


## The blue "H" standing on the centre block's roof, over the doors.
static func _roof_h(root: Node3D, door: Vector3, front: float) -> void:
	var top := FLOOR_H * (1 + CENTRE_STOREYS) + 0.35
	var at := Vector3(door.x, top + 1.5, front - 0.4)
	_box(root, Vector3(2.8, 2.8, 0.3), at, _mat("h_panel", Color(0.08, 0.25, 0.75), 0.4, Color(0.15, 0.4, 1.0), 1.6))
	var h := _letter(root, "H", at + Vector3(0, -0.05, 0.16), 320, Color(1, 1, 1))
	h.pixel_size = 0.0085
	h.outline_size = 0
	var glow := OmniLight3D.new()
	glow.name = "RoofGlow"
	glow.light_color = Color(0.3, 0.5, 1.0)
	glow.light_energy = 1.4
	glow.omni_range = 6.0
	glow.shadow_enabled = false
	glow.position = at + Vector3(0, 0, 1.2)
	root.add_child(glow)


## A low concrete sign at the head of the walk in, west of the walkway, facing the fog.
static func _monument(root: Node3D, door: Vector3, front: float) -> void:
	var at := Vector3(door.x - 6.2, 0.0, front + 9.8)
	var body := StaticBody3D.new()
	body.name = "MonumentSign"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)
	var size := Vector3(3.6, 1.15, 0.5)
	_box(body, size, at + Vector3(0, size.y * 0.5, 0), _concrete())
	_box(body, Vector3(3.2, 0.8, 0.04), at + Vector3(0, 0.62, 0.26), _mat("sign_face", Color(0.05, 0.12, 0.2), 0.5))
	_shape(body, size, at + Vector3(0, size.y * 0.5, 0))
	var name_l := _letter(root, "ST. DOE'S GENERAL", at + Vector3(0, 0.82, 0.29), 64, Color(0.92, 0.96, 1.0))
	name_l.pixel_size = 0.0045
	var sub := _letter(root, "HOSPITAL", at + Vector3(0, 0.6, 0.29), 40, Color(0.8, 0.88, 0.95))
	sub.pixel_size = 0.0045
	var dirs := _letter(root, "<  EMERGENCY     MAIN ENTRANCE  >", at + Vector3(0, 0.36, 0.29), 26, Color(0.95, 0.35, 0.3))
	dirs.pixel_size = 0.0045
	var up := SpotLight3D.new()
	up.name = "MonumentUplight"
	up.light_color = Color(0.9, 0.95, 1.0)
	up.light_energy = 2.0
	up.spot_range = 3.0
	up.spot_angle = 50.0
	up.shadow_enabled = false
	up.position = at + Vector3(0, 0.05, 1.3)
	root.add_child(up)
	up.look_at(at + Vector3(0, 0.8, 0.25), Vector3.UP)


## Concrete planters with low shrubs against the wall, clear of the doors, the walk and the
## ambulance bay.
static func _planters(root: Node3D, lot: Rect2, door: Vector3, info: Dictionary, front: float) -> void:
	var bay_x: float = (info.ambulance.position as Vector3).x if info.has("ambulance") else INF
	var spans := [[-13.0, -8.5], [-25.0, -20.5], [17.0, 21.5]]
	var body := StaticBody3D.new()
	body.name = "Planters"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)
	for s in spans:
		var a: float = door.x + float(s[0])
		var b: float = door.x + float(s[1])
		if a < lot.position.x + 1.0 or b > lot.end.x - 1.0 or (bay_x >= a - 2.0 and bay_x <= b + 2.0):
			continue
		var size := Vector3(b - a, 0.55, 0.9)
		var at := Vector3((a + b) * 0.5, size.y * 0.5, front + size.z * 0.5 + 0.05)
		_box(body, size, at, _band())
		_box(body, Vector3(size.x - 0.2, 0.04, size.z - 0.2), at + Vector3(0, size.y * 0.5, 0), _mat("soil", Color(0.1, 0.08, 0.06), 1.0))
		_shape(body, size, at)
		var shrubs := int(floor(size.x / 0.9))
		for k in shrubs:
			var sm := SphereMesh.new()
			sm.radius = 0.38
			sm.height = 0.62
			sm.radial_segments = 8
			sm.rings = 4
			var mi := MeshInstance3D.new()
			mi.mesh = sm
			mi.material_override = _mat("shrub", Color(0.07, 0.13, 0.07), 0.95)
			mi.position = Vector3(a + 0.45 + k * (size.x - 0.9) / maxf(1.0, shrubs - 1), size.y + 0.22, at.z)
			body.add_child(mi)


# ---------------------------------------------------------------------------
# helpers

static func _advance(c: String) -> float:
	return SIGN_ADVANCE * (0.55 if c == " " else (0.5 if c in ".'" else 1.0))


static func _sign_width() -> float:
	var w := 0.0
	for c in SIGN_TEXT:
		w += _advance(c)
	return w


static func _bind_lighting(root: Node3D, info: Dictionary, lot_point: Vector3) -> void:
	var grid: Dictionary = info.get("light_grid", {})
	if grid.is_empty():
		return
	var mask := LightRooms.mask_at(grid, lot_point)
	for n in root.find_children("*", "VisualInstance3D", true, false):
		if n is Light3D:
			(n as Light3D).light_cull_mask = mask | LightRooms.DYNAMIC
		else:
			(n as VisualInstance3D).layers = mask


static func _box(parent: Node, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _shape(body: StaticBody3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)


static func _letter(parent: Node, text: String, pos: Vector3, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.0055
	l.modulate = col
	l.outline_size = 6
	l.outline_modulate = Color(0, 0, 0, 0.6)
	l.shaded = false
	l.double_sided = false
	l.position = pos
	parent.add_child(l)
	return l


static func _mat(key: String, col: Color, rough := 0.8, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.resource_name = "ext_" + key
	m.albedo_color = col
	m.roughness = rough
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	_mats[key] = m
	return m


## The lot-facing concrete, mapped in world space so it doesn't stretch over a big box.
static func _concrete() -> Material:
	return _triplanar("concrete", Color(0.42, 0.42, 0.40), Color.WHITE)


## Floor bands, the cornice, planters: the same concrete, paler.
static func _band() -> Material:
	return _triplanar("band", Color(0.55, 0.55, 0.52), Color(1.25, 1.25, 1.2))


static func _triplanar(key: String, fallback: Color, tint: Color) -> Material:
	if _mats.has(key):
		return _mats[key]
	var base := HospitalBuilder.surface_mat("mat/concrete", fallback, 0.9)
	var m: Material = base
	if base is StandardMaterial3D:
		var d: StandardMaterial3D = (base as StandardMaterial3D).duplicate()
		d.uv1_triplanar = true
		d.uv1_world_triplanar = true
		d.uv1_scale = Vector3(0.35, 0.35, 0.35)
		d.albedo_color = d.albedo_color * tint
		m = d
	_mats[key] = m
	return m


static func _window_mat(key: String) -> StandardMaterial3D:
	match key:
		"lit_warm":
			return _mat("lit_warm", Color(0.35, 0.3, 0.2), 0.4, Color(1.0, 0.78, 0.45), 1.5)
		"lit_green":
			return _mat("lit_green", Color(0.2, 0.3, 0.25), 0.4, Color(0.55, 0.95, 0.7), 1.0)
	var g := _mat("glass", Color(0.05, 0.07, 0.09), 0.12)
	g.metallic = 0.55
	return g


## The sign letter on its way out: mostly on, now and then a stutter, now and then dark a while.
class Flicker extends Node:
	var label: Label3D
	var on_color := Color.WHITE
	var _t := 0.0
	var _next := 2.0
	var _off := 0.0

	func _process(delta: float) -> void:
		if label == null:
			return
		_t += delta
		if _off > 0.0:
			_off -= delta
			label.modulate = on_color * Color(0.2, 0.2, 0.2, 1.0) if fmod(_off, 0.13) < 0.07 or _off > 0.35 else on_color
			if _off <= 0.0:
				label.modulate = on_color
				_next = randf_range(1.5, 7.0)
			return
		_next -= delta
		if _next <= 0.0:
			_off = randf_range(0.15, 1.6)
