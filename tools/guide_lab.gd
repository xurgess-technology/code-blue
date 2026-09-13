extends Node3D
## Medical guide lab: a clock-in room corner under the game's look (Look.make_environment and
## the post layer), the lectern with the binder on it, and the guide UI over the top.
## Standalone on purpose, so it runs while the level and game scripts are mid-edit.
##
##   godot --path . tools/guide_lab.tscn                         # interactive: R opens, Esc closes
##   godot --path . tools/guide_lab.tscn -- --shots              # screenshots into tools/guide_shots/
##   godot --headless --path . tools/guide_lab.tscn -- --headless-report
##         opens every page and turns through the whole binder; exits 0 when all checks pass

const GuideUIScript := preload("res://scripts/guide/guide_ui.gd")
const GuideModelsScript := preload("res://scripts/guide/guide_models.gd")
const Pages := preload("res://scripts/guide/guide_pages.gd")
const ItemModelsDB := preload("res://scripts/item_models.gd")

const SHOT_DIR := "res://tools/guide_shots"

var guide: CanvasLayer
var camera: Camera3D
var lectern: Node3D
var book: Node3D
var _failures: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_build_room()
	guide = GuideUIScript.new()
	guide.name = "Guide"
	add_child(guide)
	guide.closed.connect(func(): print("[guide_lab] closed signal"))
	if "--headless-report" in args:
		_report()
	elif "--shots" in args:
		_shots()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		guide.open("")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("read") and not guide.is_open():
		guide.open("")


# ---------------------------------------------------------------------------
# The room
# ---------------------------------------------------------------------------

func _build_room() -> void:
	add_child(Look.make_environment())
	add_child(Look.make_post_layer())
	Look.apply_quality(self, Look.QUALITY_MEDIUM)

	var floor_mat := _mat(Color(0.2, 0.26, 0.24), 0.72)
	var wall_lo := _mat(Color(0.30, 0.40, 0.34), 0.88)
	var wall_hi := _mat(Color(0.62, 0.66, 0.60), 0.92)
	var trim := _mat(Color(0.10, 0.13, 0.12), 0.6)
	var W := 6.0
	_box(Vector3(W, 0.2, W), Vector3(0, -0.1, 0), floor_mat)
	_box(Vector3(W, 0.2, W), Vector3(0, C.WALL_H + 0.1, 0), _mat(Color(0.42, 0.46, 0.44), 0.95))
	for side in [[Vector3(W, 1.1, 0.2), Vector3(0, 0.55, -2.0), Vector3(W, 1.9, 0.2), Vector3(0, 2.05, -2.0)],
			[Vector3(0.2, 1.1, W), Vector3(-1.6, 0.55, 0), Vector3(0.2, 1.9, W), Vector3(-1.6, 2.05, 0)],
			[Vector3(0.2, 1.1, W), Vector3(2.2, 0.55, 0), Vector3(0.2, 1.9, W), Vector3(2.2, 2.05, 0)]]:
		_box(side[0], side[1], wall_lo)
		_box(side[2], side[3], wall_hi)
	_box(Vector3(W, 0.06, 0.26), Vector3(0, 1.1, -1.95), trim)
	# Time clock and a locker bank, so the room reads as the clock-in room.
	_box(Vector3(0.3, 0.4, 0.14), Vector3(1.1, 1.45, -1.83), _mat(Color(0.55, 0.52, 0.45), 0.5, 0.4))
	_box(Vector3(0.2, 0.08, 0.02), Vector3(1.1, 1.52, -1.755), _mat(Color(0.05, 0.3, 0.12), 0.3))
	for i in 3:
		_box(Vector3(0.45, 1.9, 0.5), Vector3(-1.25, 0.95, -1.2 + i * 0.47), _mat(Color(0.28, 0.36, 0.42), 0.45, 0.5))

	lectern = GuideModelsScript.make_lectern()
	lectern.position = Vector3(0.1, 0, -1.2)
	lectern.rotation_degrees.y = 8.0
	add_child(lectern)
	book = ItemModelsDB.make("guide")
	var rest: Transform3D = lectern.get_meta("book_rest")
	book.transform = lectern.transform * rest
	add_child(book)

	# Ceiling fixture over the lectern and a dim one by the door.
	var l := SpotLight3D.new()
	l.position = Vector3(0.2, C.WALL_H - 0.15, -0.9)
	l.rotation_degrees = Vector3(-90, 0, 0)
	l.light_color = Color(0.78, 0.9, 1.0)
	l.light_energy = 3.6
	l.spot_range = 7.0
	l.spot_angle = 60.0
	l.spot_attenuation = 1.5
	l.shadow_enabled = true
	l.light_volumetric_fog_energy = 3.0
	add_child(l)
	var panel := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.62, 0.04, 1.2)
	panel.mesh = pm
	var em := _mat(Color(0.88, 0.94, 0.9), 0.4)
	em.emission_enabled = true
	em.emission = Color(0.8, 1.0, 0.92)
	em.emission_energy_multiplier = 1.5
	panel.material_override = em
	panel.position = l.position + Vector3(0, 0.04, 0)
	add_child(panel)

	camera = Camera3D.new()
	camera.fov = 75.0
	camera.near = 0.05
	add_child(camera)
	var focus: Vector3 = book.global_transform.origin if book.is_inside_tree() else book.transform.origin
	camera.look_at_from_position(focus + Vector3(0.12, C.EYE_H - focus.y, 0.62), focus + Vector3(0, -0.12, 0), Vector3.UP)
	camera.current = true
	# A flashlight, as the player would have.
	var torch := SpotLight3D.new()
	torch.light_color = Color(1.0, 0.86, 0.62)
	torch.light_energy = 2.2
	torch.spot_range = C.CONE_RANGE
	torch.spot_angle = C.CONE_DEG
	torch.shadow_enabled = true
	torch.position = Vector3(0.18, -0.16, 0)
	camera.add_child(torch)


func _mat(c: Color, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.material_override = mat
	add_child(mi)


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [SHOT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[guide_lab] wrote %s  %dx%d" % [path, img.get_width(), img.get_height()])


func _shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.split("=")[1]
	var size_arg := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--size="):
			size_arg = a.split("=")[1]
	var suffix := ""
	if size_arg != "":
		var parts := size_arg.split("x")
		get_window().size = Vector2i(int(parts[0]), int(parts[1]))
		suffix = "_" + size_arg
	await _frames(20)

	var plan := [
		["01_lectern", ""],
		["02_index", ""],
		["03_anesthetic", "anesthetic"],
		["04_bone_saw", "bone_saw"],
		["05_procedure_gunshot", "procedure:gunshot"],
		["06_procedure_amputation", "procedure:amputation"],
		["07_locked", "locked:Defibrillator"],
		["08_guide_entry", "guide"],
		["09_mid_flip", "forceps"],
	]
	for step in plan:
		var name: String = step[0]
		if only != "" and not name.contains(only):
			continue
		var page: String = step[1]
		if name == "01_lectern":
			if guide.is_open():
				guide.close()
			await _frames(60)
			await _snap(name + suffix)
			continue
		if name == "09_mid_flip":
			guide.open("anesthetic")
			await _frames(70)
			guide.debug_hold_flip(page, 0.3)
			await _frames(30)
			await _snap(name + "_a" + suffix)
			guide.debug_hold_flip(page, 0.72)
			await _frames(10)
			await _snap(name + "_b" + suffix)
			guide.debug_hold_flip("", -1.0)
			await _frames(40)
			continue
		guide.open(page)
		await _frames(70)
		await _snap(name + suffix)
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# Headless report
# ---------------------------------------------------------------------------

func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		print("[guide_lab] FAIL ", what)


func _report() -> void:
	await _frames(3)
	var entries: Array = guide.entries
	print("[guide_lab] %d spreads" % entries.size())
	_check(entries.size() == 1 + Items.ITEMS.size() + Procedures.AILMENTS.size() + Items.LOCKED.size(), "entry count")
	_check(Pages.item_order()[0] == Items.SURGICAL[0], "surgical items first")
	_check(Pages.item_order().back() == "guide", "guide last")
	for kind in Items.ITEMS.keys():
		var d := Pages.item_page(kind)
		_check(d.real_use != "" and d.handling != "", "item text for " + kind)
		if not Items.ITEMS[kind].found.is_empty():
			_check(not d.where_split.most.is_empty(), "most-often for " + kind)
		print("  %-11s used in: %s | most: %s | sometimes: %s" % [kind,
			", ".join(d.used_in.map(func(u): return u.text)), "; ".join(d.where_split.most), "; ".join(d.where_split.sometimes)])
	for aid in Procedures.AILMENTS.keys():
		var p := Pages.procedure_page(aid)
		_check(p.steps.size() == Procedures.steps(aid).size(), "steps for " + aid)
		var total := 0
		for s in p.shopping:
			total += s.count
		print("  %-11s shopping: %s" % [aid, ", ".join(p.shopping.map(func(s): return "%s x%d" % [s.name, s.count]))])
		_check(total > 0, "shopping list for " + aid)

	# Open every page directly.
	for e in entries:
		guide.open(e.id)
		await _frames(2)
		_check(guide.is_open(), "open " + e.id)
		await _frames(int(guide.FLIP_TIME * 60) + 6)
		_check(guide.current_page() == e.id, "landed on '%s' (got '%s')" % [e.id, guide.current_page()])
	# Turn through the whole book with the keys, both ways.
	guide.open("")
	await _frames(40)
	for i in entries.size() - 1:
		_key(KEY_D)
		await _frames(4)   # faster than a flip, so turns interrupt each other
	await _frames(40)
	_check(guide.current_page() == entries.back().id, "keyboard flip to the end")
	for i in entries.size() - 1:
		_key(KEY_LEFT)
		await _frames(32)
	_check(guide.current_page() == "", "keyboard flip back to the index")
	_key(KEY_3)
	await _frames(40)
	_check(guide.current_page() == entries[3].id, "number key jump")
	_key(KEY_S)
	await _frames(2)
	_key(KEY_ESCAPE)
	await _frames(2)
	_check(not guide.is_open(), "Esc closes")
	await get_tree().create_timer(0.8).timeout
	_check(not guide.visible, "hidden after close")
	# Closed guide ignores keys.
	_key(KEY_D)
	await _frames(2)
	_check(guide.current_page() == entries[3].id, "closed guide ignores input")
	guide.open("procedure:amputation")
	await _frames(3)
	_key(KEY_R)
	await _frames(3)
	_check(not guide.is_open(), "R closes")
	await _frames(30)

	# World models build.
	var b: Node3D = GuideModelsScript.make_book()
	var box := preload("res://scripts/guide/guide_viewer.gd").merged_aabb(b)
	print("  book aabb %s" % box)
	_check(absf(box.position.y) < 0.01, "book origin at its base")
	_check(box.size.x > 0.2 and box.size.z > 0.28 and box.size.z < 0.36, "book size")
	b.free()
	var lec: Node3D = GuideModelsScript.make_lectern()
	var lbox := preload("res://scripts/guide/guide_viewer.gd").merged_aabb(lec)
	print("  lectern aabb %s  book_rest %s" % [lbox, lec.get_meta("book_rest").origin])
	_check(lbox.position.y > -0.01 and lbox.end.y > 1.0 and lbox.end.y < 1.4, "lectern origin at floor, sensible height")
	lec.free()

	print("[guide_lab] %s (%d failures)" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _key(k: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.physical_keycode = k
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
