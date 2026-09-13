extends Node3D
## The pile of gold bars the team has bought, one MultiMesh so hundreds cost a single draw.
##
## The layout is a pure function of the bar count (and the height cap), so every machine and
## every late joiner builds the same pile from `game.gold_bars` alone. Bars are laid like a
## Jenga tower: each layer crosses the one below. The main column starts on a wide stepped base
## (27 bars a layer, then 12) and then climbs 3 bars a layer, forever. Where a ceiling is in the
## way (`max_height`), the next bars start new 12-a-layer columns around it.
##
## Local frame: origin at the base centre, +Y up.

const BAR_L := 0.26
const BAR_W := 0.0867   # three side by side make a square layer
const BAR_H := 0.056
## [cells per side (r), layers]; the layer holds 3 * r * r bars. -1 layers means forever.
const MAIN_TIERS := [[3, 3], [2, 5], [1, -1]]
const SIDE_TIERS := [[2, -1]]
const SIDE_OFFSETS := [
	Vector2(1.05, 0.0), Vector2(0.0, 1.05), Vector2(-1.05, 0.0), Vector2(0.0, -1.05),
	Vector2(1.05, 1.05), Vector2(-1.05, 1.05), Vector2(-1.05, -1.05), Vector2(1.05, -1.05),
	Vector2(2.1, 0.0), Vector2(0.0, 2.1), Vector2(-2.1, 0.0), Vector2(0.0, -2.1),
]
const DROP_SECONDS := 0.28
const DROP_HEIGHT := 1.1

static var _bar_mesh: ArrayMesh = null
static var _bar_mat: StandardMaterial3D = null

var max_height := 1000.0
var shown := 0

var _mmi: MultiMeshInstance3D
var _mm: MultiMesh
var _body: StaticBody3D
var _label: Label3D
var _xf: Array[Transform3D] = []
var _filled := 0           # multimesh instances holding a real transform
var _column_top := {}      # column index -> top y
var _column_half := {}     # column index -> half footprint
# layout cursor
var _col := 0
var _tier := 0
var _layer_in_tier := 0
var _layer := 0            # layer index within the column
var _cell := 0             # next cell in the current layer
var _layer_cells: Array = []
var _base_y := 0.0         # y of the current column's layer 0
# drop animation
var _target := 0
var _falling: MeshInstance3D
var _fall_t := 0.0


static func create(height_cap: float) -> Node3D:
	var p = new()
	p.name = "GoldPile"
	p.max_height = height_cap
	p._build()
	return p


func _build() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = bar_mesh()
	_mm.instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Bars"
	_mmi.multimesh = _mm
	add_child(_mmi)
	_body = StaticBody3D.new()
	_body.name = "PileCollision"
	_body.collision_layer = C.L_WORLD
	_body.collision_mask = 0
	add_child(_body)
	_falling = MeshInstance3D.new()
	_falling.mesh = bar_mesh()
	_falling.visible = false
	add_child(_falling)
	_label = Label3D.new()
	_label.font_size = 40
	_label.pixel_size = 0.004
	_label.outline_size = 8
	_label.modulate = Color(1.0, 0.85, 0.45)
	_label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_label.position = Vector3(0, 0.25, 0)
	_label.visible = false
	add_child(_label)


## The bar mesh: a trapezoid prism (narrower on top) like a cast ingot, origin at its base centre,
## long axis along X.
static func bar_mesh() -> ArrayMesh:
	if _bar_mesh != null:
		return _bar_mesh
	var l := BAR_L * 0.96
	var w := BAR_W * 0.9
	var top_l := l * 0.84
	var top_w := w * 0.72
	var h := BAR_H * 0.94
	var b := [Vector3(-l / 2, 0, -w / 2), Vector3(l / 2, 0, -w / 2), Vector3(l / 2, 0, w / 2), Vector3(-l / 2, 0, w / 2)]
	var t := [Vector3(-top_l / 2, h, -top_w / 2), Vector3(top_l / 2, h, -top_w / 2), Vector3(top_l / 2, h, top_w / 2), Vector3(-top_l / 2, h, top_w / 2)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quad := func(a: Vector3, bb: Vector3, c: Vector3, d: Vector3) -> void:
		var n := (c - a).cross(bb - a).normalized()
		for v in [a, bb, c, a, c, d]:
			st.set_normal(n)
			st.add_vertex(v)
	quad.call(t[0], t[1], t[2], t[3])          # top
	quad.call(b[3], b[2], b[1], b[0])          # bottom
	quad.call(b[0], b[1], t[1], t[0])          # -Z
	quad.call(b[2], b[3], t[3], t[2])          # +Z
	quad.call(b[3], b[0], t[0], t[3])          # -X
	quad.call(b[1], b[2], t[2], t[1])          # +X
	_bar_mesh = st.commit()
	_bar_mesh.surface_set_material(0, bar_material())
	return _bar_mesh


static func bar_material() -> StandardMaterial3D:
	if _bar_mat != null:
		return _bar_mat
	_bar_mat = StandardMaterial3D.new()
	_bar_mat.resource_name = "gold_bar"
	_bar_mat.albedo_color = Color(1.0, 0.78, 0.34)
	_bar_mat.vertex_color_use_as_albedo = true
	_bar_mat.metallic = 1.0
	_bar_mat.roughness = 0.28
	# A touch of emission so the pile still reads as gold under dim or no light.
	_bar_mat.emission_enabled = true
	_bar_mat.emission = Color(0.55, 0.36, 0.08)
	_bar_mat.emission_energy_multiplier = 0.18
	return _bar_mat


## Show `n` bars. Growing by a few at a time animates the new ones dropping onto the pile.
func set_count(n: int, animate := true) -> void:
	n = maxi(0, n)
	if n == _target:
		return
	_ensure(n)
	if n < shown or not animate or n - shown > 3 or not is_inside_tree():
		shown = n
		_target = n
		_fall_t = 0.0
		_falling.visible = false
	else:
		_target = n
	_apply()


func top_position() -> Vector3:
	var i := maxi(0, maxi(shown, _target) - 1)
	if _xf.is_empty():
		return global_position
	return to_global(_xf[mini(i, _xf.size() - 1)].origin + Vector3.UP * BAR_H)


func _process(delta: float) -> void:
	if shown >= _target:
		return
	if not _falling.visible:
		_falling.visible = true
		_fall_t = 0.0
	_fall_t += delta
	var k := clampf(_fall_t / DROP_SECONDS, 0.0, 1.0)
	var xf: Transform3D = _xf[shown]
	_falling.transform = Transform3D(xf.basis, xf.origin + Vector3.UP * DROP_HEIGHT * (1.0 - k * k))
	if k >= 1.0:
		_falling.visible = false
		shown += 1
		_apply()


func _apply() -> void:
	_mm.visible_instance_count = shown
	_label.visible = shown > 0
	_label.text = "%d GOLD BAR%s" % [maxi(shown, _target), "" if maxi(shown, _target) == 1 else "S"]
	_update_collision(maxi(shown, _target))


func _ensure(n: int) -> void:
	while _xf.size() < n:
		_xf.append(_next_transform())
	if _mm.instance_count < n:
		var cap := 64
		while cap < n:
			cap *= 2
		# Resizing clears the buffer: fill every instance again.
		_mm.instance_count = cap
		_filled = 0
	while _filled < n:
		_mm.set_instance_transform(_filled, _xf[_filled])
		_mm.set_instance_color(_filled, _tone(_filled))
		_filled += 1
	_update_aabb()
	_mm.visible_instance_count = shown


func _update_aabb() -> void:
	var top := 0.5
	var reach := 0.6
	for c in _column_top.keys():
		top = maxf(top, float(_column_top[c]))
		if int(c) > 0:
			var o: Vector2 = SIDE_OFFSETS[(int(c) - 1) % SIDE_OFFSETS.size()]
			reach = maxf(reach, maxf(absf(o.x), absf(o.y)) + 0.4)
	# Leave room for the pile to grow a while before the next resize.
	_mm.custom_aabb = AABB(Vector3(-reach, -0.1, -reach), Vector3(reach * 2.0, top + 2.0, reach * 2.0))


static func _tone(i: int) -> Color:
	var h := float(hash(i) % 1000) / 1000.0
	var v := 0.9 + h * 0.16
	return Color(v, v * (0.98 + h * 0.03), v * 0.95, 1.0)


# ---------------------------------------------------------------------------
# layout

func _tiers() -> Array:
	return MAIN_TIERS if _col == 0 else SIDE_TIERS


func _column_origin(c: int) -> Vector2:
	return Vector2.ZERO if c == 0 else SIDE_OFFSETS[(c - 1) % SIDE_OFFSETS.size()] * (1.0 + float((c - 1) / SIDE_OFFSETS.size()))


func _start_layer() -> void:
	var tiers := _tiers()
	var r: int = int(tiers[_tier][0])
	var s := float(r) * BAR_L
	var rows := 3 * r
	var cells: Array = []
	var along_x := _layer % 2 == 0
	for a in rows:
		for b in r:
			var along := -s * 0.5 + BAR_L * (float(b) + 0.5)
			var across := -s * 0.5 + (s / float(rows)) * (float(a) + 0.5)
			var p := Vector2(along, across) if along_x else Vector2(across, along)
			cells.append([p.length(), cells.size(), p])
	# Centre-out, so a half-finished layer looks placed on purpose.
	cells.sort_custom(func(x, y): return x[0] < y[0] - 0.0001 or (absf(x[0] - y[0]) <= 0.0001 and x[1] < y[1]))
	_layer_cells = cells
	_cell = 0
	_column_half[_col] = maxf(float(_column_half.get(_col, 0.0)), s * 0.5)


func _next_transform() -> Transform3D:
	if _layer_cells.is_empty() or _cell >= _layer_cells.size():
		_advance_layer()
	var along_x := _layer % 2 == 0
	var p: Vector2 = _layer_cells[_cell][2]
	_cell += 1
	var o := _column_origin(_col)
	var y := _base_y + float(_layer) * BAR_H
	_column_top[_col] = y + BAR_H
	var basis := Basis() if along_x else Basis(Vector3.UP, PI * 0.5)
	# The tiniest wobble so the stack reads as hand-placed, never enough to look unstable.
	var j := float(hash(_xf.size() * 7919) % 1000) / 1000.0 - 0.5
	basis = basis.rotated(Vector3.UP, j * 0.03)
	return Transform3D(basis, Vector3(o.x + p.x, y, o.y + p.y))


func _advance_layer() -> void:
	if not _layer_cells.is_empty():
		_layer += 1
		_layer_in_tier += 1
		var tiers := _tiers()
		var layers: int = int(tiers[_tier][1])
		if layers >= 0 and _layer_in_tier >= layers and _tier < tiers.size() - 1:
			_tier += 1
			_layer_in_tier = 0
		# A ceiling in the way: start the next column on the floor beside this one.
		if _base_y + float(_layer + 1) * BAR_H > max_height:
			_col += 1
			_tier = 0
			_layer = 0
			_layer_in_tier = 0
			_base_y = 0.0
	_start_layer()


func _update_collision(n: int) -> void:
	# One box per column, as tall as its bars (layout already covers n).
	var want := {}
	if n > 0:
		for c in _column_top.keys():
			want[c] = true
	for child in _body.get_children():
		var c := int(String(child.name).trim_prefix("Col"))
		if not want.has(c):
			child.queue_free()
	for c in want.keys():
		var cs: CollisionShape3D = _body.get_node_or_null("Col%d" % c)
		if cs == null:
			cs = CollisionShape3D.new()
			cs.name = "Col%d" % c
			cs.shape = BoxShape3D.new()
			_body.add_child(cs)
		var top: float = _top_of_column(c, n)
		var half: float = float(_column_half.get(c, BAR_L * 0.5))
		(cs.shape as BoxShape3D).size = Vector3(half * 2.0, maxf(0.02, top), half * 2.0)
		var o := _column_origin(int(c))
		cs.position = Vector3(o.x, top * 0.5, o.y)


func _top_of_column(c: int, n: int) -> float:
	var top := 0.0
	var origin := _column_origin(c)
	for i in mini(n, _xf.size()):
		var p: Vector3 = _xf[i].origin
		if Vector2(p.x - origin.x, p.z - origin.y).length() < 0.5:
			top = maxf(top, p.y + BAR_H)
	return top
