extends Node
## Headless checks for downed players, carrying, the player table and the stitches operation.
##
##   godot --headless --fixed-fps 60 --path . tools/downedtest.tscn
##
## A generated hospital first (the Re-Gen Pod is gone, suture kits spawn, the fallback player table
## lands beside the OR table, 0 HP downs, nobody standing fails the shift), then the dev room with a
## bot and dummies (crawling, carrying and dropping, getting hit while carrying, the player table,
## stitches with bot skill 1.0 reviving, a kit used up, bleeding out to dead at five minutes,
## all_players_out, monsters ignoring the downed). Exits 0 when every check passes.

const DevRoomScript := preload("res://scripts/dev/dev_room.gd")

var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	main.menu.hide_menu()
	Net.start_solo("Tester")
	await _hospital()
	await _dev_room()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 900.0 and not _done:
		_check(false, "timed out")
		_finish()


# =========================================================================
# the generated hospital
# =========================================================================

func _hospital() -> void:
	game.start_session(12345)
	await _frames(5)
	me = game.local_player()
	me.bot_active = true
	_check(not game.has_method("pod_pos") and game.find_interactable("pod") == null, "the Re-Gen Pod has no aim spot or API")
	_check(game.level.find_child("RegenPod", true, false) == null and not ("pod" in game), "no Re-Gen Pod in the level or the game state")
	_check(not game._global_fields().has("po"), "the snapshot carries no pod progress")
	game.begin_shift()
	await _frames(6)
	var kits := 0
	var stacks := 0
	var wrong := 0
	for it in game.world_items.values():
		if it.kind != "suture_kit":
			continue
		kits += int(it.count)
		stacks += 1
		if it.state == WorldItem.State.IN_CONTAINER:
			var ct := game.find_interactable(it.container_id)
			if ct == null or not ["trauma_bag", "station_drawers", "drawer_unit"].has(String(ct.container_type)):
				wrong += 1
	_check(stacks >= 3 and kits >= 3 and wrong == 0, "suture kits spawn every shift (%d kits in %d stacks, %d misplaced)" % [kits, stacks, wrong])
	_check(Items.is_surgical("suture_kit") and ItemModels.tint_material("suture_kit") != null, "suture kits are surgical and tinted teal")
	_check(not game.player_table.is_empty() and game.find_interactable("player_table") != null, "a player table stands in the OR (%s)" % str(game.player_table))
	if not game.player_table.is_empty():
		var entry := {}
		for tb in game.level_info.get("tables", []):
			if String(tb.get("kind", "")) == "player":
				entry = tb
		if entry.is_empty():
			var d := Vector2(game.player_table.position.x - game.table_pos().x, game.player_table.position.z - game.table_pos().z).length()
			_check(d > 2.0 and d < 4.5, "the fallback player table is beside the OR table (%.1f m)" % d)
		else:
			_check(game.player_table.position.distance_to(entry.position) < 0.01 and game.level.find_child("PlayerTable", true, false) == null,
				"the level's own player table is used, no extra model (top %.2f m)" % float(game.player_table.top))
			_check(float(game.player_table.top) > 0.7 and float(game.player_table.top) < 1.2, "the player table top was found on the level's table")
	_check(Procedures.patient_ailments() == ["amputation", "gunshot"] and not Procedures.patient_ailments().has("stitches"), "patients never roll stitches")

	# 0 HP downs.
	for m in game.monsters.values():
		m.global_position += Vector3(0, -60, 0)   # out of the way
	game.damage_player(me, me.hp, "monster:test")
	await _frames(1)
	_check(me.alive and me.downed and me.hp == 0 and me.bleed > 295.0, "damage to 0 HP downs instead of killing")
	_check(not game.alive_players().has(me), "a downed player is not among the standing players monsters hunt")
	_check(game.all_players_out(), "all_players_out when the only player is downed")
	await _frames(3)
	_check(game.phase == Game.Phase.LOST, "everyone down fails the shift (phase %d: %s)" % [game.phase, game.message])
	await _seconds(C.END_SCREEN_SECONDS + 1.0)
	_check(game.phase == Game.Phase.LOBBY and me.alive and not me.downed, "the next lobby has everyone back up")
	main._back_to_menu("")
	await _frames(3)


# =========================================================================
# the dev room
# =========================================================================

func _dev_room() -> void:
	Net.start_solo("Tester")
	game.start_session(DevRoomScript.SEED)
	await _frames(6)
	me = game.local_player()
	me.bot_active = true
	_check(game.dev_mode and not game.player_table.is_empty(), "the dev room has its player table")

	# ---- crawling
	_stand(Vector3(14.0, 0, 15.0), 0.0)
	await _frames(2)
	game.knock_down_player(me, "test")
	await _seconds(0.8)
	_stand(Vector3(14.0, 0, 15.0), 0.0)
	await _frames(2)
	var start := me.global_position
	me.bot_move = Vector2(0, -1)
	me.bot_sprint = true
	await _seconds(2.0)
	me.bot_move = Vector2.ZERO
	var crawled := me.global_position.distance_to(start)
	_check(me.downed and crawled > 1.0 and crawled < 1.8, "a downed player crawls slowly, sprint or not (%.2f m in 2 s)" % crawled)
	_check(me.aim_prompt == "Call for help" and me.aim_id == "", "downed, E only calls for help")
	me.bot_press += 1
	await _frames(3)
	_check(float(game._call_at.get(me.peer_id, -1.0)) > 0.0, "calling for help reaches the host")
	var m = dev.spawn_monster("discharged", "front", me)
	await _frames(2)
	var hp0 := me.hp
	game.monster_hit_player(m, me)
	_check(me.hp == hp0 and me.downed and me.alive, "monsters do nothing to a downed player")
	game.kill_monster(m)
	dev.request("revive_all")
	await _frames(3)
	_check(me.alive and not me.downed and me.hp == me.max_hp, "revive all gets you up")

	# ---- carrying
	var did: int = dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	var bid: int = dev.spawn_bot("bot", me)
	var bot: Player = game.players[bid]
	dev.order_bot(bid, "stay")
	await _frames(4)
	dummy.teleport(game._floor_at(Vector3(16.0, 0, 13.0)))
	await _frames(2)
	game.knock_down_player(dummy, "test")
	await _seconds(0.6)
	_check(dummy.downed and game.all_players_out() == false, "a downed dummy; others standing, so not all out")
	# Walking speed first, to compare.
	_stand(Vector3(20.0, 0, 15.5), -PI / 2.0)
	await _frames(2)
	start = me.global_position
	me.bot_move = Vector2(0, -1)
	await _seconds(1.0)
	me.bot_move = Vector2.ZERO
	var walk := me.global_position.distance_to(start)
	me.slots[0] = {"kind": "gauze", "count": 2}
	_stand(dummy.global_position + Vector3(0, 0, 1.6), 0.0)
	await _frames(2)
	me.bot_aim_id = "pl_%d" % did
	await _frames(2)
	_check(me.aim_prompt.begins_with("!Empty your hands"), "carrying needs empty hands ('%s')" % me.aim_prompt)
	me.slots = Player.empty_slots()
	await _frames(2)
	_check(me.aim_prompt.begins_with("Hold E: pick up"), "aiming at a downed teammate offers to pick them up ('%s')" % me.aim_prompt)
	me.bot_interact = true
	await _seconds(0.5)
	_check(me.carrying == 0 and me.carry_hold > 0.3, "picking up is a hold (%.2f s so far)" % me.carry_hold)
	await _seconds(0.7)
	me.bot_interact = false
	_check(me.carrying == did and dummy.carried_by == me.peer_id, "holding E picks the downed dummy up")
	await _frames(2)
	_check(dummy.global_position.distance_to(me.global_position + Vector3.UP * 1.35) < 0.6, "the carried body rides on the carrier's shoulder")
	_stand(Vector3(20.0, 0, 15.5), -PI / 2.0)
	await _frames(2)
	start = me.global_position
	me.bot_move = Vector2(0, -1)
	await _seconds(1.0)
	me.bot_move = Vector2.ZERO
	var carry_walk := me.global_position.distance_to(start)
	_check(carry_walk < walk * 0.75 and carry_walk > walk * 0.4, "carrying slows you (%.2f m vs %.2f m walking)" % [carry_walk, walk])
	_check(dummy.global_position.distance_to(me.global_position) < 1.6, "the carried body follows the carrier")
	me.bot_aim_id = ""
	me.bot_press += 1
	await _frames(3)
	_check(me.carrying == 0 and dummy.carried_by == 0 and dummy.downed and dummy.global_position.y < 0.3, "E again puts them down on the floor")
	# Getting hit drops them.
	_stand(dummy.global_position + Vector3(0, 0, 1.4), 0.0)
	me.bot_aim_id = "pl_%d" % did
	me.bot_interact = true
	await _seconds(1.3)
	me.bot_interact = false
	_check(me.carrying == did, "picked up again")
	game.damage_player(me, 1, "monster:test")
	await _frames(2)
	_check(me.carrying == 0 and dummy.carried_by == 0 and me.hp == me.max_hp - 1, "getting hit drops the carried teammate")
	await _seconds(3.2)   # the hit's invulnerability
	me.revive_full()

	# ---- the player table
	_stand(dummy.global_position + Vector3(0, 0, 1.4), 0.0)
	me.bot_aim_id = "pl_%d" % did
	me.bot_interact = true
	await _seconds(1.3)
	me.bot_interact = false
	var pt: Vector3 = game.player_table.position
	_stand(pt + Vector3(0, 0, 1.5), 0.0)
	me.bot_aim_id = "player_table"
	await _frames(3)
	_check(me.aim_prompt.begins_with("Place "), "carrying to the player table offers to place them ('%s')" % me.aim_prompt)
	me.bot_press += 1
	await _frames(3)
	_check(dummy.on_table and me.carrying == 0 and dummy.carried_by == 0, "E at the player table lays them on it")
	var top := game.player_table_top()
	_check(Vector2(dummy.global_position.x - top.x, dummy.global_position.z - top.z).length() < 1.0 and absf(dummy.global_position.y - top.y) < 0.05, "the body lies on the table top")
	_check(game.player_surgery.patient() == dummy and game.player_surgery.patient_body != null and game.player_surgery.patient_body.has_site("gash"), "the stitches case starts with a lying body and a gash site")
	_check(dummy.body_visual.visible == false, "the dummy's standing body hides while the lying one shows")
	await _frames(2)
	_check(me.aim_prompt.begins_with("!Put Suture kit") or me.aim_prompt.contains("Suture kit"), "operating needs a suture kit on the shelf ('%s')" % me.aim_prompt)
	var bleed_a: float = dummy.bleed
	await _seconds(2.0)
	var bled := bleed_a - dummy.bleed
	_check(bled > 0.8 and bled < 1.2, "bleeding slows to half on the table (%.2f s in 2 s)" % bled)
	game.shelf["suture_kit"] = 1
	game.shelf_node.show_stock(game.shelf)
	await _frames(2)
	_check(me.aim_prompt.begins_with("Operate"), "with a kit on the shelf the table offers to operate ('%s')" % me.aim_prompt)
	game.player_surgery.surgery.bot_skill = 1.0
	me.bot_press += 1
	var ok := await _until(func(): return me.operating, 5.0)
	_check(ok and game.player_surgery.surgery.mg != null, "the stitches minigame starts on the table")
	var op_started := t
	ok = await _until(func(): return not dummy.downed, 40.0)
	var took := t - op_started
	_check(ok and dummy.alive and dummy.hp == Game.REVIVE_HP and not dummy.on_table, "stitches with bot 1.0 revive the dummy with partial HP (%.1f s)" % took)
	_check(took > 6.0 and took < 20.0, "stitching takes a believable time (%.1f s)" % took)
	_check(game.shelf_count("suture_kit") == 0, "the suture kit is used up")
	_check(game.player_surgery.case.is_empty() and game.player_surgery.patient_body == null, "the player table is free again")
	_check(dummy.global_position.distance_to(pt) < 3.5 and dummy.global_position.y < 0.3, "the revived player stands beside the table")
	game.player_surgery.surgery.bot_skill = -1.0

	# ---- all out
	game.knock_down_player(me, "test")
	game.knock_down_player(bot, "test")
	await _frames(2)
	_check(not game.all_players_out(), "one standing dummy keeps the team in (all_players_out false)")
	game.knock_down_player(dummy, "test")
	await _frames(2)
	_check(game.all_players_out() and game.phase == Game.Phase.SHIFT, "everyone down: all_players_out (the dev room does not end)")
	dev.request("revive_all")
	await _frames(2)

	# ---- bleeding out
	var did2: int = dev.spawn_bot("dummy")
	var d2: Player = game.players[did2]
	await _frames(3)
	game.knock_down_player(d2, "test")
	var bleed_start := t
	ok = await _until(func(): return not d2.alive, 320.0)
	var lasted := t - bleed_start
	_check(ok and not d2.downed and lasted > 295.0 and lasted < 305.0, "a downed player bleeds out to dead after five minutes (%.1f s)" % lasted)
	_check(not game.alive_players().has(d2) and not d2.alive, "bled out means dead until the next shift")
	main._back_to_menu("")
	await _frames(3)


# =========================================================================
# helpers
# =========================================================================

func _stand(pos: Vector3, yaw := 0.0) -> void:
	me.teleport(game._floor_at(pos))
	me.bot_yaw = yaw
	me.bot_pitch = 0.0
	me.bot_move = Vector2.ZERO


func _check(ok: bool, what: String) -> void:
	print("[downedtest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[downedtest] ------------------------------------------")
	print("[downedtest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())
