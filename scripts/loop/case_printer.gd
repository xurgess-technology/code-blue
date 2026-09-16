extends StaticBody3D
## The break room printer (hub rebuild, chunk 4): a dot-matrix printer on its own stand beside the
## database computer. Whenever the phone call for a patient is taken (a new case appears in
## game.cases as "incoming"), it prints that case's sheet: the page feeds up out of the back of the
## printer, line by line, and drops onto the pile in its tray. E on it opens the sheets
## (case_sheet_ui.gd, opened locally by main.gd). Sheets whose case is gone (clock-out, a new shift)
## leave the pile.
##
## Purely local on every machine, derived from the replicated game.cases: no network traffic. A case
## first seen already past "incoming" (a late join, a rebuilt level) goes straight onto the pile.
##
## Interact id `case_sheet`. Local frame: origin on the floor, the reader's side toward +Z.

const PRINT_SECONDS := 3.2
const LINE_EVERY := 0.34
const STAND_H := 0.72
const PAPER := Color(0.88, 0.87, 0.82)
const PAGE := Vector2(0.22, 0.3)
const MAX_PILE := 4

var game: Node = null
var _known := {}          # case id -> true, every case this printer has seen
var _queue: Array = []    # case ids waiting to print
var _printed: Array = []  # case ids on the pile, oldest first
var _printing := -1
var _print_t := 0.0
var _line_t := 0.0
var _page: MeshInstance3D
var _pile: Array = []     # MeshInstance3D sheets in the tray
var _light_mat: StandardMaterial3D

static var _sheet_tex: ImageTexture = null


static func create(g: Node) -> StaticBody3D:
	var n := new()
	n.game = g
	n.name = "CasePrinter"
	n._build()
	return n


func _build() -> void:
	add_to_group("interactable")
	set_meta("interact_id", "case_sheet")
	# Only the stand is solid (C.L_WORLD, below counter height, so the brains blender's counter search
	# never lands on the printer); the printer itself is just the aim target.
	collision_layer = C.L_INTERACT
	collision_mask = 0
	var steel := _mat(Color(0.3, 0.32, 0.34), 0.45, 0.6)
	var laminate := _mat(Color(0.45, 0.42, 0.38), 0.75)
	var beige := _mat(Color(0.72, 0.69, 0.6), 0.6)
	var dark := _mat(Color(0.1, 0.1, 0.11), 0.6)
	_light_mat = _mat(Color(0.1, 0.4, 0.15), 0.4)
	_light_mat.emission_enabled = true
	_light_mat.emission = Color(0.3, 1.0, 0.4)
	_light_mat.emission_energy_multiplier = 1.2

	# The stand: a small laminate top on a steel frame, a shelf of blank fanfold paper underneath.
	_box(Vector3(0.62, 0.035, 0.5), Vector3(0, STAND_H - 0.018, 0), laminate)
	for sx in [-0.28, 0.28]:
		for sz in [-0.21, 0.21]:
			_box(Vector3(0.035, STAND_H - 0.035, 0.035), Vector3(sx, (STAND_H - 0.035) * 0.5, sz), steel)
	_box(Vector3(0.58, 0.025, 0.46), Vector3(0, 0.2, 0), steel)
	_box(Vector3(0.3, 0.12, 0.34), Vector3(0, 0.275, 0), _mat(PAPER, 0.9))

	# The printer: a wide beige body, a dark platen slot along the back top, a paper-out tray at the
	# front sloping down toward the reader, a status light.
	var top := STAND_H
	_box(Vector3(0.5, 0.14, 0.32), Vector3(0, top + 0.07, -0.02), beige)
	_box(Vector3(0.44, 0.012, 0.05), Vector3(0, top + 0.146, -0.1), dark)          # the slot
	_box(Vector3(0.5, 0.05, 0.08), Vector3(0, top + 0.165, -0.15), beige)          # the paper guide
	var tray := _box(Vector3(0.3, 0.01, 0.2), Vector3(0, top + 0.09, 0.21), beige)
	tray.rotation_degrees.x = 12.0
	_box(Vector3(0.1, 0.03, 0.012), Vector3(0.14, top + 0.1, 0.141), dark)          # the panel
	_box(Vector3(0.018, 0.018, 0.006), Vector3(0.19, top + 0.1, 0.149), _light_mat)

	# The page being printed: grows up out of the slot, then drops into the tray.
	_page = _sheet_mesh()
	_page.visible = false

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.62, top + 0.2, 0.5)
	cs.shape = bs
	cs.position = Vector3(0, (top + 0.2) * 0.5, 0)
	add_child(cs)
	var stand := StaticBody3D.new()
	stand.name = "Stand"
	stand.collision_layer = C.L_WORLD
	stand.collision_mask = 0
	var ss := CollisionShape3D.new()
	var sb := BoxShape3D.new()
	sb.size = Vector3(0.62, STAND_H, 0.5)
	ss.shape = sb
	ss.position = Vector3(0, STAND_H * 0.5, 0)
	stand.add_child(ss)
	add_child(stand)


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


## A printed page: a thin card with rows of grey "type" on its face (+Y).
func _sheet_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = PAGE
	mi.mesh = pm
	var m := StandardMaterial3D.new()
	m.albedo_texture = _texture()
	m.roughness = 0.95
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)
	return mi


static func _texture() -> ImageTexture:
	if _sheet_tex != null:
		return _sheet_tex
	var img := Image.create(66, 90, false, Image.FORMAT_RGB8)
	img.fill(PAPER)
	var ink := Color(0.35, 0.35, 0.37)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4417
	var y := 8
	while y < 84:
		var w := rng.randi_range(22, 54) if y > 12 else 40
		if y == 26 or y == 58:
			for x in range(6, 60, 3):
				img.set_pixel(x, y, ink)
		else:
			for x in range(6, 6 + w):
				img.set_pixel(x, y, ink)
				img.set_pixel(x, y + 1, Color(ink, 0.5).lerp(PAPER, 0.5))
		y += 5
	_sheet_tex = ImageTexture.create_from_image(img)
	return _sheet_tex


# ---- the sheets ----

## The sheets on the pile, newest first (what the reader opens).
func sheet_ids() -> Array:
	var out := _printed.duplicate()
	out.reverse()
	return out


func is_printing() -> bool:
	return _printing >= 0


func _process(delta: float) -> void:
	if game == null or not is_instance_valid(game):
		return
	_track_cases()
	if _printing < 0 and not _queue.is_empty():
		_printing = int(_queue.pop_front())
		_print_t = 0.0
		_line_t = 0.0
		_page.visible = true
	if _printing >= 0:
		_tick_print(delta)
	_light_mat.emission_energy_multiplier = (0.6 + 1.4 * float(int(_print_t * 6.0) % 2)) if _printing >= 0 else 1.2


func _track_cases() -> void:
	var live := {}
	for c in game.cases:
		if not (c is Dictionary) or bool(c.get("mirror", false)) or String(c.get("patient_id", "")) == "player":
			continue
		var id := int(c.get("id", -1))
		if id < 0:
			continue
		live[id] = true
		if _known.has(id):
			continue
		_known[id] = true
		if String(c.get("state", "")) == "incoming":
			_queue.append(id)
		else:
			_printed.append(id)
			_update_pile()
	var gone := false
	for id in _printed.duplicate():
		if not live.has(id):
			_printed.erase(id)
			gone = true
	for id in _queue.duplicate():
		if not live.has(id):
			_queue.erase(id)
	if gone:
		_update_pile()
	if live.is_empty():
		_known.clear()


func _tick_print(delta: float) -> void:
	_print_t += delta
	var k := clampf(_print_t / PRINT_SECONDS, 0.0, 1.0)
	var top := STAND_H
	if k < 0.85:
		# Up out of the slot, a line at a time, leaning back against the paper guide.
		var rise := PAGE.y * (k / 0.85)
		_page.rotation = Vector3(deg_to_rad(-80.0), 0.0, 0.0)
		_page.position = Vector3(0, top + 0.15 + rise * 0.5, -0.1 - rise * 0.08)
		_page.scale = Vector3(1.0, 1.0, maxf(0.02, k / 0.85))
		_line_t -= delta
		if _line_t <= 0.0:
			_line_t = LINE_EVERY
			_sfx("print_line", -10.0)
	else:
		# Torn off and dropped forward into the tray.
		var d := (k - 0.85) / 0.15
		_page.scale = Vector3.ONE
		_page.rotation = Vector3(deg_to_rad(lerpf(-80.0, 12.0, d)), 0.0, 0.0)
		_page.position = Vector3(0, lerpf(top + 0.3, _pile_y(_printed.size()), d), lerpf(-0.12, 0.2, d))
	if k >= 1.0:
		_page.visible = false
		_printed.append(_printing)
		_printing = -1
		_update_pile()
		_sfx("print_feed", -8.0)


func _pile_y(i: int) -> float:
	return STAND_H + 0.1 + 0.004 * float(i)


func _update_pile() -> void:
	var n := mini(_printed.size(), MAX_PILE)
	while _pile.size() < n:
		_pile.append(_sheet_mesh())
	while _pile.size() > n:
		(_pile.pop_back() as Node).queue_free()
	for i in _pile.size():
		var s: MeshInstance3D = _pile[i]
		s.rotation = Vector3(deg_to_rad(12.0), deg_to_rad(float((i * 7) % 9) - 4.0), 0.0)
		s.position = Vector3(0.01 * float((i * 3) % 3 - 1), _pile_y(i), 0.2)


func _sfx(cue: String, db: float) -> void:
	if is_inside_tree() and DisplayServer.get_name() != "headless":
		Audio.play(cue, global_position + Vector3.UP * 0.9, db, 0.05)


# ---- interactable contract ----

func interact_prompt(_player) -> String:
	if not _printed.is_empty():
		return "Read the case sheet" if _printed.size() == 1 else "Read the case sheets (%d)" % _printed.size()
	if _printing >= 0:
		return "!Printing a case sheet..."
	return ""


func interact_hold() -> float:
	return 0.0


func interact(_player) -> void:
	pass   # the sheets open locally (main.gd)
