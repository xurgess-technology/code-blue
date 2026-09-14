extends Node
## Boots the real game, poses it, and saves screenshots so the look can be checked
## without a human sitting at the keyboard.
##
##   godot --path . tools/gameshot.tscn -- [--seed=N] [--tag=1600] [--only=orscreen]
##
## --tag suffixes the file names (one run per resolution); --only keeps the shots whose name
## contains the text (plus the three lobby shots before the OR, which set the scene up).

const OUT_DIR := "res://tools/game_shots"
const SETTLE_FRAMES := 26
const ModelScript := preload("res://scripts/orscreen/or_screen_model.gd")

var main: Node3D
var game: Game
var bot: Player
var shots: Array = []
var _i := 0
var _seed := 4242
var _tag := ""
var _only := ""
var _seal_table := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--tag="):
			_tag = "_" + a.split("=")[1]
		elif a.begins_with("--only="):
			_only = a.split("=")[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# Never outlive a broken run (a windowed Godot left behind holds the GPU).
	get_tree().create_timer(900.0).timeout.connect(func(): get_tree().quit(2))

	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.bot_move = Vector2.ZERO

	shots = [
		{"name": "01_clockin_room", "fn": _pose_clockin},
		{"name": "02_time_clock", "fn": _pose_clock},
		{"name": "03_corridor", "fn": _pose_corridor},
		{"name": "11_orscreen_idle", "fn": _pose_screen_idle, "settle": 40},
		{"name": "04_operating_room", "fn": _pose_or},
		{"name": "21_seal_on_table", "fn": _pose_seal, "settle": 40},
		{"name": "22_seal_on_table_close", "fn": _pose_seal_close, "settle": 20},
		{"name": "12_orscreen_door", "fn": _pose_screen_door, "settle": 40},
		{"name": "13_orscreen_close", "fn": _pose_screen_close, "settle": 40},
		{"name": "05_monster_close", "fn": _pose_monster},
		{"name": "06_surgery_hud", "fn": _pose_surgery},
		{"name": "14_orscreen_low_vitals", "fn": _pose_screen_low, "settle": 40},
		{"name": "18_orscreen_two_cases", "fn": _pose_screen_two_cases, "settle": 40},
		{"name": "19_orscreen_incoming", "fn": _pose_screen_incoming, "settle": 40},
		{"name": "20_orscreen_flatline", "fn": _pose_screen_flatline, "settle": 40},
		{"name": "07_dark_no_light", "fn": _pose_dark},
		{"name": "08_lectern_guide", "fn": _pose_lectern},
		{"name": "09_container_open", "fn": _pose_container},
		{"name": "15_hud_walking", "fn": _pose_hud_walking, "settle": 50},
		{"name": "16_hud_holding", "fn": _pose_hud_holding, "settle": 30},
		{"name": "17_orscreen_amputation", "fn": _pose_screen_amputation, "settle": 40},
	]
	# HANDS HOOK (docs/HANDS_AND_FEEDBACK.md "Done when"): hands, wind-ups, the stun window and the
	# carry camera. `--only=hands` runs just these (plus the lobby shots that set the scene up).
	for kind in _hand_kinds():
		shots.append({"name": "21_hands_fp_%s" % kind, "fn": _pose_hold.bind(kind), "settle": 24})
	shots.append_array([
		{"name": "22_hands_teammate_one_hand", "fn": _pose_teammate.bind("bone_saw", ""), "settle": 30},
		{"name": "22_hands_teammate_vials", "fn": _pose_teammate.bind("anesthetic", ""), "settle": 30},
		{"name": "23_hands_teammate_bulky", "fn": _pose_teammate.bind("heart_monitor", ""), "settle": 30},
		{"name": "24_hands_shove_full_fp", "fn": _pose_action_fp.bind("", "shove"), "settle": 20},
		{"name": "25_hands_shove_full_teammate", "fn": _pose_teammate.bind("", "shove"), "settle": 30},
		{"name": "26_hands_jab_windup_fp", "fn": _pose_action_fp.bind("anesthetic", "jab"), "settle": 20},
		{"name": "26_hands_jab_windup_teammate", "fn": _pose_teammate.bind("anesthetic", "jab"), "settle": 30},
		{"name": "27_hands_saw_windup_fp", "fn": _pose_action_fp.bind("bone_saw", "saw"), "settle": 20},
		{"name": "27_hands_saw_windup_teammate", "fn": _pose_teammate.bind("bone_saw", "saw"), "settle": 30},
		{"name": "27_hands_saw_strike_fp", "fn": _pose_action_fp.bind("bone_saw", "saw_strike"), "settle": 20},
		{"name": "28_hands_stun_window_down", "fn": _pose_stun.bind(false), "settle": 50},
		{"name": "28_hands_stun_window_rising", "fn": _pose_stun.bind(true), "settle": 30},
		{"name": "29_hands_carry_cam_player", "fn": _pose_carry.bind("player", false), "settle": 60},
		{"name": "29_hands_carry_cam_monster", "fn": _pose_carry.bind("monster", false), "settle": 60},
		{"name": "29_hands_carry_cam_player_corridor", "fn": _pose_carry.bind("player", true), "settle": 60},
		{"name": "29_hands_carry_cam_monster_corridor", "fn": _pose_carry.bind("monster", true), "settle": 60},
	])
	# HUMAN HOOK (art/human): the Blender humans in the game. `--only=human`.
	shots.append_array([
		{"name": "30_human_teammates_walk_sprint", "fn": _pose_human_gait, "settle": 22},
		{"name": "31_human_teammate_carrying", "fn": _pose_human_carry, "settle": 40},
		{"name": "32_human_teammate_crawling", "fn": _pose_human_crawl, "settle": 40},
		{"name": "34_human_paramedics_gurney", "fn": _pose_human_crew, "settle": 60},
	])
	for st in HUMAN_BOB_STATES:
		shots.append({"name": "33_human_bob_%s" % st[0], "fn": _pose_human_bob.bind(st[1], st[2]), "settle": 40})
	shots.append({"name": "10_operating_hud", "fn": _pose_operating, "settle": 140})
	if _only != "":
		shots = shots.filter(func(s): return _matches(String(s.name)) or String(s.name) < "04")
	_run()


func _run() -> void:
	for shot in shots:
		shot.fn.call()
		for i in int(shot.get("settle", SETTLE_FRAMES)):
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s%s.png" % [OUT_DIR, shot.name, _tag]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[gameshot] wrote ", path, "  ", img.get_width(), "x", img.get_height())
		_i += 1
	print("[gameshot] done, %d shots" % _i)
	get_tree().quit(0)


func _look_from(pos: Vector3, at: Vector3) -> void:
	bot.teleport(pos)
	var d := at - pos
	bot.bot_yaw = atan2(-d.x, -d.z)
	bot._yaw = bot.bot_yaw
	bot.rotation.y = bot.bot_yaw
	bot._pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	bot.head.rotation.x = bot._pitch


func _pose_clockin() -> void:
	var spots := game.spawn_points()
	_look_from(spots[0] + Vector3(0, 0, 0), game.clock_pos())


func _pose_clock() -> void:
	var c := game.clock_pos()
	_look_from(c + Vector3(2.6, 0, 2.6), c + Vector3(0, 1.4, 0))


## Find the longest clear sightline in the level and stand at one end of it,
## so the shot shows a corridor rather than the inside of a wall.
func _pose_corridor() -> void:
	var candidates: Array = game.level_info.get("monster_spawns", [])
	if candidates.is_empty():
		candidates = game.level_info.get("tool_spawns", [])
	if candidates.is_empty():
		_look_from(game.table_pos() + Vector3(0, 0, 6), game.table_pos())
		return
	var space := bot.get_world_3d().direct_space_state
	var best_len := -1.0
	var best_from: Vector3 = candidates[0]
	var best_dir := Vector3.FORWARD
	for spot in candidates:
		var eye: Vector3 = spot + Vector3.UP * C.EYE_H
		for i in 16:
			var a := TAU * i / 16.0
			var dir := Vector3(cos(a), 0, sin(a))
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 40.0)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			var reach: float = 40.0 if hit.is_empty() else eye.distance_to(hit.position)
			if reach > best_len:
				best_len = reach
				best_from = spot
				best_dir = dir
	print("[gameshot] longest sightline %.1f m" % best_len)
	_look_from(best_from, best_from + Vector3.UP * (C.EYE_H - 0.1) + best_dir * best_len * 0.9)


func _pose_or() -> void:
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
	var t := game.table_pos()
	_look_from(t + Vector3(0.6, 0, 3.4), t + Vector3(0, 1.0, 0))


## A real seal case (the Blender model) on a free patient table, seen from the doorway side.
func _pose_seal() -> void:
	_ensure_shift()
	var ti := -1
	for c in game.cases:
		if String(c.get("patient_id", "")) == "seal" and int(c.get("table", -1)) >= 0:
			ti = int(c.table)
	if ti < 0:
		ti = game.free_patient_table()
		if ti < 0 and not game.patient_tables.is_empty():
			ti = int(game.patient_tables[game.patient_tables.size() - 1].index)
			var old: Dictionary = game.case_on_table(ti)
			if not old.is_empty():
				game.remove_case(int(old.id))
		game.add_case({"patient_id": "seal", "ailment_id": "amputation", "table": ti, "flags": {"sedation": 0.3}})
	_seal_table = ti
	var t: Vector3 = game.table_position(ti)
	_look_from(t + Vector3(1.4, 0, 1.9), t + Vector3(0, 0.95, 0))


func _pose_seal_close() -> void:
	var t: Vector3 = game.table_position(_seal_table)
	var body = game.body_for_table(_seal_table)
	var at: Vector3 = body.global_position if body != null else t + Vector3(0, 0.9, 0)
	if body == null:
		_look_from(t + Vector3(0.8, 0, 1.0), at)
		return
	var bx: Vector3 = body.global_transform.basis.x
	var bz: Vector3 = body.global_transform.basis.z
	# off its left side, eyes about 0.9 m over the table top
	_look_from(at - bx * 0.2 + bz * 1.7 + Vector3(0, 0.9 - 1.7, 0), at - bx * 0.25 + Vector3(0, 0.1, 0))


func _pose_monster() -> void:
	if game.monsters.is_empty():
		return
	var m = game.monsters.values()[0]
	var t := game.table_pos()
	m.global_position = t + Vector3(0, 0, -3.0)
	m.state = Monster.State.STUNNED
	if "stun" in m:  # the monster rewrite dropped this field
		m.stun = 99.0
	m.process_mode = Node.PROCESS_MODE_DISABLED
	_look_from(t + Vector3(0, 0, 2.0), m.global_position + Vector3(0, 1.4, 0))


## Stock the shelf and stand beside the table looking at the patient and the supplies.
func _pose_surgery() -> void:
	for kind in Items.SURGICAL:
		game.shelf[kind] = 3 if Items.is_consumable(kind) else 1
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)
	game.vitals = 38.0
	var tb := game.table_pos()
	var sh: Vector3 = game.shelf_node.global_position if game.shelf_node != null else tb
	_look_from(tb + (tb - sh).normalized() * 2.2 + Vector3(0, 0, 0.6), (tb + sh) * 0.5 + Vector3(0, 1.0, 0))
	bot.bot_aim_id = "table"


func _pose_dark() -> void:
	bot.bot_interact = false
	bot.set_flashlight(false)
	var spots: Array = game.level_info.get("tool_spawns", [])
	var p: Vector3 = spots[spots.size() / 2] if spots.size() > 0 else game.table_pos()
	_look_from(p, game.table_pos())


func _pose_lectern() -> void:
	bot.bot_aim_id = ""
	bot.set_flashlight(true)
	var info: Dictionary = game.level_info.get("lectern", {})
	var base: Vector3 = info.get("position", game.clock_pos() + Vector3(1.6, 0, 0))
	_look_from(base + Vector3(1.4, 0, 1.4), base + Vector3(0, 1.0, 0))


func _pose_container() -> void:
	var cts: Array = game.level_info.get("containers", [])
	for e in cts:
		var node: Node = e.get("node")
		if node == null or not is_instance_valid(node) or not node.has_method("set_open"):
			continue
		node.set_open(true, false)
		var p: Vector3 = (node as Node3D).global_position
		var out: Vector3 = (node as Node3D).global_basis.z.normalized()
		_look_from(p + out * 1.6, p + Vector3(0, 1.0, 0))
		return


## ORSCREEN: the OR wall monitor and the minimal HUD.

func _ensure_shift() -> void:
	bot.bot_move = Vector2.ZERO
	bot.bot_sprint = false
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()


func _screen() -> Node:
	return game.get("or_screen")


## Stand `dist` metres out from the monitor along its facing (shortened if a wall is closer),
## a little to one side, looking at the glass.
func _look_at_screen(dist: float, side: float) -> void:
	var s := _screen()
	if s == null or not s.mounted():
		print("[gameshot] no OR screen mounted")
		return
	var c: Vector3 = s.screen_centre()
	var n: Vector3 = s.screen_normal()
	var q := PhysicsRayQueryParameters3D.create(c + n * 0.3, c + n * (dist + 0.6))
	q.collision_mask = C.L_WORLD
	var hit := bot.get_world_3d().direct_space_state.intersect_ray(q)
	var d := dist
	if not hit.is_empty():
		d = minf(dist, c.distance_to(hit.position) - 0.7)
	bot.bot_aim_id = ""
	bot.set_flashlight(false)
	var sidev := n.cross(Vector3.UP).normalized()
	var feet := c + n * d + sidev * side
	feet.y = game.table_pos().y
	_look_from(feet, c)
	print("[gameshot] screen at %s (%s), camera %.1f m out" % [str(c.snappedf(0.1)), s.placement, d])


func _pose_screen_idle() -> void:
	bot.set_flashlight(false)
	_look_at_screen(4.0, 0.6)


func _pose_screen_door() -> void:
	_ensure_shift()
	bot.set_flashlight(false)
	_look_at_screen(9.0, 1.2)


func _pose_screen_close() -> void:
	_ensure_shift()
	game.shelf["anesthetic"] = 1
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)
	_look_at_screen(1.9, 0.0)


func _pose_screen_low() -> void:
	_ensure_shift()
	game.vitals = 18.0
	_look_at_screen(3.2, 0.5)


func _pose_screen_amputation() -> void:
	_ensure_shift()
	game.case.ailment_id = "amputation"
	game.case.step_index = 1
	game.shelf = {"tourniquet": 1, "gauze": 1}
	game._apply_case_locally()
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)
	game.vitals = 64.0
	_look_at_screen(4.5, -0.8)


## Several patients through the `loop` worker's game.cases shape, shown with the screen's test seam
## until that worker's cases exist on this branch.
func _fake_cases(cases: Array, shelf: Dictionary, vitals := 100.0) -> void:
	_ensure_shift()
	var fake := FakeCases.new()
	fake.cases = cases
	fake.shelf = shelf
	fake.vitals = vitals
	var s := _screen()
	if s != null:
		s.model_override = ModelScript.build(fake)
	fake.free()


func _pose_screen_two_cases() -> void:
	_fake_cases([
		{"id": 1, "table": 0, "patient_id": "bob", "ailment_id": "gunshot", "step_index": 1, "vitals": 74.0, "state": "on_table"},
		{"id": 2, "table": 1, "patient_id": "seal", "ailment_id": "amputation", "step_index": 0, "vitals": 21.0, "state": "on_table"},
	], {"forceps": 1, "anesthetic": 1, "gauze": 2})
	_look_at_screen(3.6, 0.4)


func _pose_screen_incoming() -> void:
	_fake_cases([
		{"id": 1, "table": 0, "patient_id": "bob", "ailment_id": "amputation", "step_index": 2, "vitals": 46.0, "state": "on_table"},
		{"id": 2, "table": 1, "patient_id": "seal", "ailment_id": "gunshot", "step_index": 0, "vitals": 100.0, "state": "incoming"},
	], {"bone_saw": 1, "gauze": 1})
	_look_at_screen(3.6, -0.4)


func _pose_screen_flatline() -> void:
	_fake_cases([
		{"id": 1, "table": 0, "patient_id": "seal", "ailment_id": "gunshot", "step_index": 1, "vitals": 0.0, "state": "dead"},
	], {})
	_look_at_screen(4.0, 0.0)


func _pose_screen_real() -> void:
	var s := _screen()
	if s != null:
		s.model_override = {}


class FakeCases extends Node:
	var phase := 2
	var shift := 1
	var vitals := 100.0
	var case := {}
	var cases: Array = []
	var shelf := {}
	var players := {}
	var surgery = null

	func shelf_count(kind: String) -> int:
		return int(shelf.get(kind, 0))


func _pose_hud_walking() -> void:
	_pose_screen_real()
	_pose_corridor()
	bot.set_flashlight(true)
	bot.stamina = 0.45
	bot.bot_move = Vector2(0, -1)
	bot.bot_sprint = true


func _pose_hud_holding() -> void:
	bot.bot_move = Vector2.ZERO
	bot.bot_sprint = false
	_ensure_shift()
	for i in bot.slots.size():
		bot.clear_slot(i)
	bot.take_into("anesthetic", 2)
	bot.take_into("forceps", 1)
	bot.take_into("guide", 1)
	bot.selected = 0
	bot.hp = maxi(1, bot.max_hp - 1)
	var sh: Vector3 = game.shelf_node.global_position if game.shelf_node != null else game.table_pos()
	var fwd: Vector3 = game.shelf_node.global_basis.z.normalized() if game.shelf_node != null else Vector3.BACK
	_look_from(sh + fwd * 1.6, sh + Vector3(0, 0.9, 0))
	bot.bot_aim_id = "shelf"


## Actually operating: the surgery camera, the minigame and the surgery HUD together.
func _pose_operating() -> void:
	_ensure_shift()
	_pose_surgery()
	var tb := game.table_pos()
	_look_from(tb + Vector3(0.0, 0.0, 1.2), tb + Vector3(0, 1.0, 0))
	game.surgery.bot_skill = 0.5
	bot.bot_aim_id = "table"
	bot.bot_press += 1


# =========================================================================
# HANDS HOOK: hands, wind-ups, the stun window and the carry camera
# =========================================================================

const WindupScript := preload("res://scripts/combat/windup.gd")
var _mate: Player = null
var _shot_monster: Node = null


static func _hand_kinds() -> Array:
	var out: Array = ["anesthetic", "gauze", "forceps", "tourniquet", "bone_saw", "suture_kit", "guide"]
	for k in preload("res://scripts/economy/loot_table.gd").kinds():
		out.append(k)
	return out


## A lit, uncluttered spot in the OR: beside the first patient table, looking across the room.
func _hands_spot() -> void:
	_ensure_shift()
	_reset_hands_scene()
	bot.set_flashlight(true)
	var t := game.table_pos()
	_look_from(t + Vector3(0.6, 0, 3.4), t + Vector3(-0.4, 1.0, 0))


func _reset_hands_scene() -> void:
	if _mate != null and is_instance_valid(_mate):
		game._release_downed_links(_mate)
		_mate.revive_full()
		_mate.refresh_downed_visuals()
		_mate.teleport(game.table_pos() + Vector3(0, -40, 0))
	game.combat.anim_freeze = false
	for p in game.players.values():
		game.combat.stop_anim(p)
	if _shot_monster != null and is_instance_valid(_shot_monster):
		game.kill_monster(_shot_monster)
	_shot_monster = null
	if bot.carrying != 0:
		game.drop_carried(bot)
	game.combat.drop_dragged(bot)
	for i in bot.slots.size():
		bot.clear_slot(i)
	bot.hp = bot.max_hp


func _give(p: Player, kind: String) -> void:
	for i in p.slots.size():
		p.clear_slot(i)
	if kind == "":
		return
	var n := 3 if Items.stacks(kind) else 1
	var i := p.take_into(kind, n, 50 if Items.is_loot(kind) else 0)
	p.selected = maxi(0, i)


func _pose_hold(kind: String) -> void:
	_hands_spot()
	_give(bot, kind)


## FP at the peak of a wind-up (k "jab" / "saw" / "shove" full charge) or at a strike ("saw_strike").
func _pose_action_fp(kind: String, k: String) -> void:
	_hands_spot()
	_give(bot, kind)
	# Past the lower-and-raise the new stack starts with.
	bot.hands._raise = 0.0
	match k:
		"shove":
			game.combat.pose_at(bot, "shove", WindupScript.WINDUP, WindupScript.SHOVE_FULL + 0.05)
		"saw_strike":
			game.combat.pose_at(bot, "saw", WindupScript.STRIKE, WindupScript.STRIKE_TIME.saw * 0.45)
		_:
			game.combat.pose_at(bot, k, WindupScript.WINDUP, float(WindupScript.WINDUP_TIME[k]))


func _teammate() -> Player:
	if _mate == null or not is_instance_valid(_mate):
		_mate = game.dev._make_bot_node(-50, "Teammate", "bot")
		_mate.name_tag.text = "Teammate"
		_mate.set_flashlight(true)
	game.combat.stop_anim(_mate)
	if not _mate.alive or _mate.downed:
		game._release_downed_links(_mate)
		_mate.revive_full()
		_mate.refresh_downed_visuals()
	return _mate


## A teammate 2.4 m in front, three-quarters on, holding `kind`, optionally frozen in action k.
func _pose_teammate(kind: String, k: String) -> void:
	_hands_spot()
	var mate := _teammate()
	_give(mate, kind)
	var t := game.table_pos()
	var eye := t + Vector3(0.6, 0, 3.4)
	var at := eye + Vector3(-1.1, 0, -2.6)
	mate.teleport(game._floor_at(at))
	var d := eye - at
	mate.bot_yaw = atan2(-d.x, -d.z) + (1.05 if k == "" else 0.7)
	mate.bot_pitch = 0.0
	_look_from(eye, at + Vector3(0, 0.8, 0))
	match k:
		"shove":
			game.combat.pose_at(mate, "shove", WindupScript.WINDUP, WindupScript.SHOVE_FULL + 0.05)
		"jab", "saw":
			game.combat.pose_at(mate, k, WindupScript.WINDUP, float(WindupScript.WINDUP_TIME[k]))


## A Walk-In just shoved (`rising` false: down in the window; true: the closing warning).
func _pose_stun(rising: bool) -> void:
	if not rising:
		_hands_spot()
		var t := game.table_pos()
		var eye := t + Vector3(0.6, 0, 3.4)
		if _mate != null and is_instance_valid(_mate):
			_mate.teleport(game.table_pos() + Vector3(0, 0, -30))
		var at := game._floor_at(eye + Vector3(-0.3, 0, -1.6))
		_shot_monster = game._add_monster("walk_in", at)
		_shot_monster.rotation.y = -PI * 0.4
		_shot_monster.brain.stun(Vector3.ZERO, 99.0, 0.0)
		game.combat.stun_window.host_stunned(_shot_monster, 99.0)
		_look_from(eye, at + Vector3(0, 0.8, 0))
		_give(bot, "anesthetic")
		bot.bot_aim_id = ""
		return
	if _shot_monster == null or not is_instance_valid(_shot_monster):
		return
	var s: Dictionary = game.combat.stun_window.stuns.get(_shot_monster.monster_id, {})
	if not s.is_empty():
		# About a third of the way into the rise when the shot is taken (30 frames from now).
		s.end = game.world_time + 0.5 + 0.4
		s.rose = false


## The carry camera: carrying a downed teammate or dragging a sedated monster, in the open OR or
## pressed against a corridor wall (the camera pulls in toward the head).
func _pose_carry(what: String, corridor: bool) -> void:
	_reset_hands_scene()
	_ensure_shift()
	Settings.set_value("carry_camera", "shoulder")
	bot.set_flashlight(true)
	var from: Vector3
	var dir: Vector3
	if corridor:
		var c := _corridor_wall_spot()
		from = c[0]
		dir = c[1]
	else:
		# Open ground: the neutral area outside the doors, looking at the entrance.
		var nz: Dictionary = game.level_info.get("neutral", {})
		var sp: Array = nz.get("spawn_points", [])
		from = sp[0] if not sp.is_empty() else game.table_pos() + Vector3(0.6, 0, 4.2)
		var ent: Vector3 = game.level_info.get("entrance", {}).get("position", game.table_pos())
		dir = Vector3(ent.x - from.x, 0, ent.z - from.z).normalized()
	_look_from(from, from + dir * 6.0 + Vector3(0, 1.2, 0))
	bot._pitch = -0.05
	bot.bot_pitch = -0.05
	if what == "player":
		var mate := _teammate()
		_give(mate, "")
		mate.teleport(game._floor_at(from + dir * 1.0))
		game.down_player(mate, "test")
		game.start_carry(bot, mate)
	else:
		_shot_monster = game._add_monster("walk_in", game._floor_at(from - dir * 1.0))
		_shot_monster.sedate(75.0)
		game.combat.start_drag(bot, _shot_monster)


## A spot in a wing hallway 0.55 m from its left-hand wall, looking along the hallway.
func _corridor_wall_spot() -> Array:
	var space := bot.get_world_3d().direct_space_state
	var best := [game.table_pos() + Vector3(0, 0, 6), Vector3.FORWARD]
	var best_len := -1.0
	for spot in game.level_info.get("monster_spawns", []):
		var eye: Vector3 = spot + Vector3.UP * 1.2
		for i in 8:
			var a := TAU * i / 8.0
			var d := Vector3(cos(a), 0, sin(a))
			var reach := _ray_len(space, eye, d, 30.0)
			var left := d.cross(Vector3.UP) * -1.0
			var wl := _ray_len(space, eye, left, 4.0)
			var wr := _ray_len(space, eye, -left, 4.0)
			if reach > best_len and wl + wr < 3.4 and reach > 8.0:
				best_len = reach
				# Slide toward the left wall.
				var shift := (wl - wr) * 0.5 + 0.25   # a little left of the middle
				best = [game._floor_at(spot + left * shift), d]
	return best


func _ray_len(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, max_len: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * max_len)
	q.collision_mask = C.L_WORLD
	var hit := space.intersect_ray(q)
	return max_len if hit.is_empty() else from.distance_to(hit.position)


## --only=a,b: a shot runs when its name contains any of the parts.
func _matches(shot_name: String) -> bool:
	for part in _only.split(","):
		if part != "" and shot_name.contains(part):
			return true
	return false


# =========================================================================
# HUMAN HOOK: the Blender humans (players, Bob, paramedics)
# =========================================================================

const HUMAN_BOB_STATES := [
	["gunshot_open", "gunshot", {"sedation": 1.0}],
	["gunshot_bullet_out", "gunshot", {"sedation": 1.0, "bullet_removed": true}],
	["gunshot_dressed", "gunshot", {"sedation": 1.0, "bullet_removed": true, "dressed": true}],
	["amputation_infected", "amputation", {"sedation": 1.0}],
	["amputation_tourniquet", "amputation", {"sedation": 1.0, "tourniquet": 0.9}],
	["amputation_sawn", "amputation", {"sedation": 1.0, "tourniquet": 0.9, "amputated": true}],
	["amputation_dressed", "amputation", {"sedation": 1.0, "tourniquet": 0.9, "amputated": true, "dressed": true}],
]
var _mate2: Player = null


func _second_mate() -> Player:
	if _mate2 == null or not is_instance_valid(_mate2):
		_mate2 = game.dev._make_bot_node(-51, "Teammate2", "bot")
		_mate2.name_tag.text = "Teammate 2"
		_mate2.set_flashlight(true)
	if not _mate2.alive or _mate2.downed:
		game._release_downed_links(_mate2)
		_mate2.revive_full()
		_mate2.refresh_downed_visuals()
	return _mate2


## Open ground outside the entrance: [from, dir].
func _open_ground() -> Array:
	var nz: Dictionary = game.level_info.get("neutral", {})
	var sp: Array = nz.get("spawn_points", [])
	var from: Vector3 = sp[0] if not sp.is_empty() else game.table_pos() + Vector3(0.6, 0, 4.2)
	var ent: Vector3 = game.level_info.get("entrance", {}).get("position", game.table_pos())
	return [from, Vector3(ent.x - from.x, 0, ent.z - from.z).normalized()]


func _pose_human_gait() -> void:
	_reset_hands_scene()
	_ensure_shift()
	var og := _open_ground()
	var from: Vector3 = og[0]
	var dir: Vector3 = og[1]
	var side := dir.cross(Vector3.UP)
	var a := _teammate()
	var b := _second_mate()
	_give(a, "bone_saw")
	_give(b, "")
	a.teleport(game._floor_at(from + dir * 6.0 - side * 0.8))
	b.teleport(game._floor_at(from + dir * 8.5 + side * 0.9))
	for m in [a, b]:
		m.bot_yaw = atan2(dir.x, dir.z)
		m.bot_move = Vector2(0, -1)
	b.bot_sprint = true
	bot.set_flashlight(true)
	_look_from(from, from + dir * 5.0 + Vector3(0, 1.0, 0))


func _pose_human_carry() -> void:
	for m in [_mate, _mate2]:
		if m != null and is_instance_valid(m):
			m.bot_move = Vector2.ZERO
			m.bot_sprint = false
	_reset_hands_scene()
	var og := _open_ground()
	var from: Vector3 = og[0]
	var dir: Vector3 = og[1]
	var side := dir.cross(Vector3.UP)
	var carrier := _second_mate()
	var carried := _teammate()
	_give(carrier, "")
	_give(carried, "")
	carrier.teleport(game._floor_at(from + dir * 3.2 + side * 0.4))
	carried.teleport(game._floor_at(from + dir * 3.6 + side * 0.4))
	game.down_player(carried, "test")
	game.start_carry(carrier, carried)
	carrier.bot_yaw = atan2(side.x, side.z) + 0.5
	carrier.bot_move = Vector2(0, -0.6)
	bot.set_flashlight(true)
	_look_from(from, from + dir * 3.2 + Vector3(0, 1.1, 0))


func _pose_human_crawl() -> void:
	if _mate2 != null and is_instance_valid(_mate2):
		_mate2.bot_move = Vector2.ZERO
	_reset_hands_scene()
	var og := _open_ground()
	var from: Vector3 = og[0]
	var dir: Vector3 = og[1]
	var m := _teammate()
	_give(m, "")
	m.teleport(game._floor_at(from + dir * 2.6))
	game.down_player(m, "test")
	m.bot_yaw = atan2(dir.x, dir.z) + 0.6
	m.bot_move = Vector2(0, -1)
	bot.set_flashlight(true)
	_look_from(from, from + dir * 2.6 + Vector3(0, 0.3, 0))


func _pose_human_bob(ailment: String, flags: Dictionary) -> void:
	if _mate != null and is_instance_valid(_mate):
		_mate.bot_move = Vector2.ZERO
	_reset_hands_scene()
	_ensure_shift()
	var ti := int(game.patient_tables[0].index) if not game.patient_tables.is_empty() else 0
	var old: Dictionary = game.case_on_table(ti)
	if old.is_empty() or String(old.get("patient_id", "")) != "bob" or String(old.get("ailment_id", "")) != ailment:
		if not old.is_empty():
			game.remove_case(int(old.id))
		game.add_case({"patient_id": "bob", "ailment_id": ailment, "table": ti, "flags": flags.duplicate()})
	else:
		old.flags = flags.duplicate()
		var bd = game.body_for_table(ti)
		if bd != null:
			bd.apply_flags(flags)
	var body = game.body_for_table(ti)
	var t: Vector3 = game.table_position(ti)
	if body == null:
		_look_from(t + Vector3(1.2, 0, 1.2), t + Vector3(0, 0.9, 0))
		return
	var site := "gunshot" if ailment == "gunshot" else "limb_cut"
	var at: Vector3 = body.site_transform(site).origin
	var bz: Vector3 = body.global_transform.basis.z
	var bx: Vector3 = body.global_transform.basis.x
	_look_from(at + bz * 1.15 - bx * 0.35 + Vector3(0, -0.55, 0), at)
	bot.set_flashlight(false)


func _pose_human_crew() -> void:
	_reset_hands_scene()
	var og := _open_ground()
	var from: Vector3 = og[0]
	var dir: Vector3 = og[1]
	var side := dir.cross(Vector3.UP)
	var crew: Node3D = (load("res://scripts/loop/crew.gd") as GDScript).create("bob", "amputation")
	game.level.add_child(crew)
	var yaw := atan2(-side.x, -side.z)
	var start := game._floor_at(from + dir * 3.8 - side * 3.0)
	crew.snap(start, yaw)
	# roll it along at the crew's 1.25 m/s so the stride matches
	var tw := create_tween()
	tw.tween_method(func(v: float): crew.set_target(start + side * v, yaw, "in"), 0.0, 3.0, 2.4)
	_look_from(from, from + dir * 3.8 + Vector3(0, 0.9, 0))
