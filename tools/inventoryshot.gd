extends Node
## Windowed screenshots for the inventory work: the slot bar with normal and bulky stacks, teal
## supplies against gold loot in a dark room and in hand, the sell bin, the shop, gold piles of
## 5, 50 and 500 bars (indoors, capped by the ceiling, and in an open outdoor stand-in with no
## cap), and the dev room's loot rack and shop corner.
##
##   godot --path . --resolution 1280x720 tools/inventoryshot.tscn -- [--seed=N] [--only=pile]
##
## Writes tools/inventory_shots/<name>.png.

const OUT_DIR := "res://tools/inventory_shots"
const GoldPileScript := preload("res://scripts/economy/gold_pile.gd")
const DevRoomScript := preload("res://scripts/dev/dev_room.gd")

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
	if _only == "" or _only == "game":
		await _game_shots()
	if _only == "" or _only == "dev":
		await _dev_shots()
	if _only == "" or _only == "pile":
		await _outdoor_piles()
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

	# ---- the sell bin and the shop
	var bin: Node3D = game.economy.sell_bin
	var shop: Node3D = game.economy.shop
	print("[inventoryshot] economy mode %s, bin %s, shop %s, pile %s" % [game.economy.mode, str(bin.global_position), str(shop.global_position), str(game.economy.pile.global_position)])
	_clear()
	bot.take_into("laptop", 1, 184)
	_look_from(bin.global_position + bin.global_basis.z * 1.7, bin.global_position + Vector3.UP * 0.7)
	bot.bot_aim_id = "sell_bin"
	await _frames(30)
	await _shot("05_sell_bin_prompt")
	bot.bot_press += 1
	await _frames(12)
	await _shot("06_sold_money_flash")
	bot.bot_aim_id = ""
	game.add_money(1500, "test")
	_look_from(shop.global_position + shop.global_basis.z * 2.3, shop.global_position + Vector3.UP * 1.3)
	bot.bot_aim_id = "shop"
	await _frames(30)
	await _shot("07_shop_prompt")
	bot.bot_press += 1
	await _frames(40)
	bot.bot_aim_id = ""

	# ---- the indoor pile (capped by the ceiling)
	var pile: Node3D = game.economy.pile
	for n in [5, 50, 500]:
		game.gold_bars = n
		await _frames(10)
		var d := 1.6 if n == 5 else (2.6 if n == 50 else 4.2)
		var p := pile.global_position
		var dir := (bot.global_position - p)
		dir.y = 0.0
		dir = dir.normalized() if dir.length() > 0.1 else Vector3(0, 0, 1)
		_look_from(_clear_floor_toward(p, dir, d), p + Vector3.UP * (0.3 if n == 5 else 0.9))
		await _frames(30)
		await _shot("08_pile_indoor_%03d" % n)


func _dev_shots() -> void:
	await _start(DevRoomScript.SEED)
	await _frames(40)
	var info: Dictionary = game.level_info
	var econ: Dictionary = info.get("economy", {})
	_look_from(Vector3(3.8, 0, 14.2), Vector3(3.8, 1.0, 18.0))
	await _frames(40)
	await _shot("10_dev_loot_rack")
	game.add_money(5000, "test")
	game.gold_bars = 60
	await _frames(30)
	_look_from(Vector3(16.0, 0, 13.0), econ.gold_pile.position + Vector3(1.2, 0.8, 1.5))
	await _frames(40)
	await _shot("11_dev_shop_corner")


## An open, dark outdoor stand-in (no level, no ceiling) for the neutral area's uncapped pile.
func _outdoor_piles() -> void:
	if main != null:
		main.queue_free()
		main = null
		await _frames(3)
	var root := Node3D.new()
	add_child(root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.025, 0.035)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.25, 0.28, 0.33)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	env.environment = e
	root.add_child(env)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.2, 0.2, 0.21)
	gm.roughness = 0.95
	ground.material_override = gm
	root.add_child(ground)
	for p in [Vector3(-4, 5, 3), Vector3(5, 5, -2)]:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.86, 0.62)
		l.light_energy = 2.2
		l.omni_range = 14.0
		l.shadow_enabled = true
		l.position = p
		root.add_child(l)
	var cam := Camera3D.new()
	cam.fov = 78
	root.add_child(cam)
	cam.current = true
	for n in [5, 50, 500]:
		var pile := GoldPileScript.create(1000.0)
		root.add_child(pile)
		pile.set_count(n, false)
		var top: float = pile.top_position().y
		var dist: float = 1.6 if n == 5 else (2.8 if n == 50 else maxf(6.0, top * 1.15))
		cam.position = Vector3(dist * 0.8, 1.7, dist * 0.6)
		cam.look_at(Vector3(0, top * 0.45 if n == 500 else 0.2, 0))
		await _frames(20)
		await _shot("09_pile_outdoor_%03d" % n)
		pile.queue_free()
		await _frames(2)
	root.queue_free()


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
