extends Node
## Windowed screenshots for the inventory work: the slot bar with normal and bulky stacks, teal
## supplies against gold loot in a dark room and in hand, the pharmacy window and the furnace
## (SWEEP 4A HOOK, pharmacy chunk 3: gold bars and the gold pile are gone), and with dev mode on,
## the hidden dev room's loot rack and the hospital's furnace with its hatch open.
##
##   godot --path . --resolution 1280x720 tools/inventoryshot.tscn -- [--seed=N] [--only=game]
##
## Writes tools/inventory_shots/<name>.png.

const OUT_DIR := "res://tools/inventory_shots"

var main: Node3D
var game: Game
var bot: Player
var _seed := 4242
var _only := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		if a.begins_with("--only="):
			_only = a.split("=")[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_run.call_deferred()


func _run() -> void:
	if _only == "" or _only == "models":
		await _model_shots()
	if _only == "" or _only == "game":
		await _game_shots()
	if _only == "" or _only == "dev":
		await _dev_shots()
	print("[inventoryshot] done")
	get_tree().quit(0)


func _start(seed_value: int) -> void:
	if main != null:
		main.queue_free()
		await _frames(3)
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	game = main.game
	main.menu.hide_menu()
	if not Net.active:
		Net.start_solo("Camera")
	game.start_session(seed_value)
	await _frames(2)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# =========================================================================

func _game_shots() -> void:
	await _start(_seed)
	game.begin_shift()
	await _frames(20)

	# ---- the slot bar
	var dark := _dark_spot()
	_look_from(dark, dark + Vector3(3.0, 1.0, 0.0))
	bot.set_flashlight(true)
	_clear()
	bot.take_into("gauze", 3)
	bot.selected = 1
	bot.take_into("defibrillator", 1, 330)
	bot.selected = 3
	bot.take_into("laptop", 1, 184)
	bot.selected = 1
	await _frames(30)
	await _shot("01_slots_gauze_bulky_laptop")
	# A bulky stack whose second half is not next to it.
	_clear()
	bot.slots[0] = {"kind": "anesthetic", "count": 2}
	bot.slots[1] = {"kind": "microscope", "count": 1, "v": 310}
	bot.slots[2] = {"kind": "forceps", "count": 1}
	bot.slots[3] = {"kind": "", "count": 0, "of": 1}
	bot.selected = 2
	await _frames(20)
	await _shot("02_slots_bulky_split_pair")

	# ---- teal against gold in a dark room, lit and unlit
	_clear()
	var row := ["anesthetic", "gauze", "forceps", "bone_saw", "laptop", "stethoscope", "gold_watch", "heart_monitor", "defibrillator"]
	var base := dark
	var fwd := Vector3(1, 0, 0)
	var side := Vector3(0, 0, 1)
	var placed := []
	for i in row.size():
		var at: Vector3 = base + fwd * (1.5 + (i % 2) * 0.5) + side * ((i - 4) * 0.42)
		var it = game._spawn_item(row[i], 3 if Items.is_consumable(row[i]) else 1, Transform3D(Basis(Vector3.UP, 0.4 * i), game._floor_at(at) + Vector3.UP * 0.01), WorldItem.State.LOOSE)
		it.value = 100
		placed.append(it)
	_look_from(base, base + fwd * 1.9 + Vector3.UP * 0.2)
	for light in [true, false]:
		bot.set_flashlight(light)
		await _frames(30)
		await _shot("03_items_floor_%s" % ("flashlight" if light else "dark"))
	bot.set_flashlight(true)
	for it in placed:
		if is_instance_valid(it):
			game.world_items.erase(it.item_id)
			it.queue_free()

	# ---- in hand
	for k in [["laptop", 184], ["defibrillator", 330], ["gauze", 0], ["gold_watch", 250]]:
		_clear()
		bot.selected = 0
		bot.take_into(k[0], 3 if k[0] == "gauze" else 1, k[1])
		await _frames(20)
		await _shot("04_held_%s" % k[0])
		bot.set_flashlight(false)
		await _frames(10)
		await _shot("04_held_%s_dark" % k[0])
		bot.set_flashlight(true)

	# ---- the pharmacy window and the furnace (SWEEP 4A HOOK, pharmacy chunk 3)
	var pharm: Node3D = game.economy.pharmacy
	var furn: Node3D = game.economy.furnace
	print("[inventoryshot] economy mode %s, pharmacy %s, furnace %s" % [game.economy.mode, str(pharm.global_position), str(furn.global_position)])
	_clear()
	game.add_money(1500, "test")
	_look_from(pharm.global_position + pharm.global_basis.z * 2.0, pharm.global_position + Vector3.UP * 1.2)
	bot.bot_aim_id = "pharmacy_fax"
	await _frames(30)
	await _shot("05_pharmacy_prompt")
	game.economy.request_order({"placebo_pills": 1})
	await _frames(60)
	await _shot("06_pharmacy_order")
	bot.bot_aim_id = ""
	bot.take_into("laptop", 1, 184)
	_look_from(furn.global_position + furn.global_basis.z * 2.4, furn.global_position + Vector3.UP * 0.9)
	await _frames(20)
	await _shot("07_furnace")
	game.drop_selected(bot, 1.0)
	await _frames(30)
	await _shot("08_furnace_burn")


## Dev mode on in a normal hospital: the hidden room (past the parking lot) and its loot rack on the
## south wall, then the hospital's own furnace (the room has no shop corner any more).
func _dev_shots() -> void:
	await _start(_seed)
	game.set_dev_tools(true, bot)
	await _frames(40)
	# The room's own frame (scripts/dev/dev_level.gd), offset to where it stands in the world.
	var o: Vector3 = game.dev.room.global_position
	_look_from(o + Vector3(3.8, 0, 14.2), o + Vector3(3.8, 1.0, 18.0))
	await _frames(40)
	await _shot("10_dev_loot_rack")
	game.add_money(5000, "test")
	await _frames(30)
	var furn: Node3D = game.economy.furnace
	furn.set_hatch(true, false)   # hub rebuild: the hatch over the window starts shut
	_look_from(furn.global_position + furn.global_basis.z * 2.4, furn.global_position + Vector3.UP * 0.9)
	await _frames(40)
	await _shot("11_dev_furnace")


# =========================================================================
# MODELS HOOK (models sweep 2): every loot kind's real model, in a row in a lit room and in a dark
# wing (flashlight on and off), each one held in first person, and the gold rim up close.

func _model_shots() -> void:
	await _start(_seed)
	game.begin_shift()
	await _frames(20)
	var kinds: Array = preload("res://scripts/economy/loot_table.gd").kinds()
	print("[inventoryshot] models: %s" % str(kinds.map(func(k): return "%s=%s" % [k, "model" if ItemModels.asset_mesh(k) != null else "primitive"])))
	# Lit: the clock-in room, looking along clear floor.
	var lit := game.clock_pos()
	var placed := await _model_rows(kinds, lit)
	bot.set_flashlight(false)
	await _frames(30)
	await _shot("20_models_lit_row")
	for g in range(0, kinds.size(), 4):
		_model_close(placed, g, g + 4)
		await _frames(20)
		await _shot("21_models_lit_close_%d" % (g / 4))
	_free_items(placed)
	# Dark wing.
	var dark := _dark_spot()
	placed = await _model_rows(kinds, dark)
	for light in [true, false]:
		bot.set_flashlight(light)
		await _frames(30)
		await _shot("23_models_dark_row_%s" % ("flashlight" if light else "unlit"))
	bot.set_flashlight(true)
	for g in range(0, kinds.size(), 4):
		_model_close(placed, g, g + 4)
		await _frames(20)
		await _shot("24_models_dark_close_%d" % (g / 4))
	_free_items(placed)
	# Held in first person, in the dark wing with the flashlight on.
	for k in kinds:
		_clear()
		bot.selected = 0
		bot.take_into(k, 3 if Items.stacks(k) else 1, 100)
		await _frames(8)
		await _shot("26_held_%s" % k)
	_clear()


var _row_from := Vector3.ZERO
var _row_dir := Vector3.FORWARD


## Two rows of loot on clear floor in front of a spot; the camera stands back to see them all.
func _model_rows(kinds: Array, near: Vector3) -> Array:
	var space := get_viewport().world_3d.direct_space_state
	var best_dir := Vector3(1, 0, 0)
	var best := -1.0
	for i in 16:
		var d := Vector3(cos(TAU * i / 16.0), 0, sin(TAU * i / 16.0))
		var q := PhysicsRayQueryParameters3D.create(near + Vector3.UP * 0.4, near + Vector3.UP * 0.4 + d * 5.0)
		q.collision_mask = C.L_WORLD
		var hit := space.intersect_ray(q)
		var reach: float = 5.0 if hit.is_empty() else (near + Vector3.UP * 0.4).distance_to(hit.position)
		if reach > best:
			best = reach
			best_dir = d
	_row_from = near
	_row_dir = best_dir
	var side := best_dir.cross(Vector3.UP)
	var out := []
	var half := int(ceil(kinds.size() / 2.0))
	for i in kinds.size():
		var row := 0 if i < half else 1
		var col := i if row == 0 else i - half
		var at: Vector3 = near + best_dir * (2.2 + row * 0.75) + side * ((col - (half - 1) * 0.5) * 0.36)
		# Groups of four (one close-up each) sit in 2 x 2 squares 0.5 m apart; the groups make a
		# 3 x 2 grid 1.2 m apart in front of the camera.
		var g := i / 4
		at = near + best_dir * (1.5 + (g / 3) * 1.5 + (i % 4) / 2 * 0.65) + side * ((g % 3 - 1) * 1.5 + (i % 2) * 0.65 - 0.33)
		var xf := Transform3D(Basis(Vector3.UP, 0.5), game._floor_at(at) + Vector3.UP * 0.005)
		var it = game._spawn_item(kinds[i], 3 if Items.stacks(kinds[i]) else 1, xf, WorldItem.State.LOOSE)
		it.value = 100
		it.place(xf, WorldItem.State.LOOSE)
		out.append(it)
	_look_from(near + best_dir * 0.2, near + best_dir * 2.6)
	bot.bot_pitch = -0.5
	await _frames(2)
	return out


## Stand close to items [a, b) of the rows.
func _model_close(items: Array, a: int, b: int) -> void:
	var c := Vector3.ZERO
	var n := 0
	for i in range(a, mini(b, items.size())):
		c += (items[i] as Node3D).global_position
		n += 1
	c /= maxf(1, n)
	_look_from(c - _row_dir * 1.1, c)
	bot.bot_pitch = -0.95


func _free_items(items: Array) -> void:
	for it in items:
		if is_instance_valid(it):
			game.world_items.erase(it.item_id)
			it.queue_free()


# =========================================================================
# helpers

func _clear() -> void:
	bot.slots = Player.empty_slots()
	bot.selected = 0


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[inventoryshot] wrote ", path)


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(game._floor_at(pos))
	var eye := bot.global_position + Vector3.UP * C.EYE_H
	var d := at - eye
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)


## The darkest spot (farthest from any working ceiling light) with 3 m of clear floor in front
## (+X) and 2 m to each side.
func _dark_spot() -> Vector3:
	var spots: Array = game.level_info.get("monster_spawns", []) + game.level_info.get("tool_spawns", [])
	var lights: Array = game.level_info.get("lights", [])
	var space := get_viewport().world_3d.direct_space_state
	var best: Vector3 = game.table_pos() + Vector3(4, 0, 0)
	var best_d := -1.0
	for s in spots:
		var eye: Vector3 = s + Vector3.UP * 0.6
		var clear := true
		for dir in [Vector3(3.0, 0, 0), Vector3(1.5, 0, 2.0), Vector3(1.5, 0, -2.0)]:
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir)
			q.collision_mask = C.L_WORLD
			if not space.intersect_ray(q).is_empty():
				clear = false
		if not clear:
			continue
		var d := 99.0
		for l in lights:
			if int(l.get("mode", 0)) == 2:
				continue
			d = minf(d, (l.position as Vector3).distance_to(s))
		if d > best_d:
			best_d = d
			best = s
	return best


func _clear_floor_toward(p: Vector3, dir: Vector3, dist: float) -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	var best := p + dir * dist
	for k in 16:
		var a := TAU * k / 16.0
		var dd := dir.rotated(Vector3.UP, a)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.2, p + Vector3.UP * 1.2 + dd * (dist + 0.5))
		q.collision_mask = C.L_WORLD
		if space.intersect_ray(q).is_empty():
			return p + dd * dist
	return best
