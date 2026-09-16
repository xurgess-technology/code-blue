extends Node
## Headless checks for the database terminal (sweep 4a chunk 4, docs/SWEEP4A.md "Chunk 4:
## Database terminal, guide removal, Hive Eyes and Echo polish"): a completed scan unlocks tier 2,
## a harvest (dissection or an absorbed brain) unlocks tier 3, the database survives a wipe and a
## reload (saved under user://), a second peer's scan lands in the (single) host database, and no
## `read` action or guide binder code remains in the project.
##
##   godot --headless --fixed-fps 60 --path . tools/databasetest.tscn [-- --seed=N]
##
## Exits 0 when every check passes.

const DatabaseStore := preload("res://scripts/database/database_store.gd")
const DbRecordScript := preload("res://scripts/database/db_record.gd")

var main: Node3D
var game: Game
var me: Player
var seed_value := 12345
var _failures: Array = []
var _checks := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv[0] == "seed" and kv.size() > 1:
			seed_value = int(kv[1])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Tester")
	game.start_session(seed_value)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(10)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	await _run()
	_finish()


func _run() -> void:
	await _scan_unlocks_tier2()
	await _harvest_unlocks_tier3()
	await _guest_scan_lands_in_host_db()
	_persists_across_wipe_and_reload()
	_no_guide_code_remains()


# =========================================================================

func _scan_unlocks_tier2() -> void:
	_say("---- a completed scan unlocks tier 2 in the host database")
	game.database.clear()
	var here: Vector3 = me.global_position
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 6))) as Node3D
	await _frames(2)
	var to: Vector3 = wi.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_pitch = 0.0
	me.bot_scan = true
	var pin: Vector3 = wi.global_position
	var track := func():
		wi.global_position = pin
		var d: Vector3 = pin - me.global_position
		me.bot_yaw = atan2(-d.x, -d.z)
		return game.db_record("walk_in").scanned
	var done := await _until(track, 8.0)
	me.bot_scan = false
	_check(done and game.db_record("walk_in").sighted, "tier 1 (sighted) and tier 2 (scanned) both set")
	_check(not game.db_record("walk_in").harvested, "tier 3 (harvested) is still locked")
	game.kill_monster(wi)


func _harvest_unlocks_tier3() -> void:
	_say("---- a harvest (absorbed at the blender) unlocks tier 3")
	var b: Node = game.brains
	b.on_reset()
	game.database.erase("discharged")
	_check(not game.db_record("discharged").harvested, "tier 3 starts locked for the Discharged")
	me.take_into("brain_discharged", 1, 350)
	var slot := _slot_of("brain_discharged")
	me.slots[slot]["bt"] = game.world_time
	me.selected = slot
	b.drink(me)
	await _frames(2)
	_check(game.db_record("discharged").harvested, "drinking an absorbed brain marks tier 3 harvested")


func _guest_scan_lands_in_host_db() -> void:
	_say("---- a second peer's scan lands in the host's database")
	game.database.erase("walk_in")
	var guest: Player = Player.new_player(-501, "Guest", false)
	guest.is_bot = true
	guest.bot_active = true
	guest.bot_invulnerable = true
	game.players[-501] = guest
	game.get_node("Entities").add_child(guest)
	guest.teleport(me.global_position + Vector3(2.0, 0.0, 0.0))
	await _frames(3)
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(guest.global_position + Vector3(0, 0, 6))) as Node3D
	await _frames(2)
	var to: Vector3 = wi.global_position - guest.global_position
	guest.bot_yaw = atan2(-to.x, -to.z)
	guest.bot_pitch = 0.0
	guest.bot_scan = true
	var pin: Vector3 = wi.global_position
	var track := func():
		wi.global_position = pin
		var d: Vector3 = pin - guest.global_position
		guest.bot_yaw = atan2(-d.x, -d.z)
		return game.db_record("walk_in").scanned
	var done := await _until(track, 8.0)
	_check(done, "the guest peer's own scan marks the species scanned in game.database (the host's copy)")
	guest.bot_scan = false
	game.kill_monster(wi)
	game.players.erase(-501)
	guest.queue_free()


func _persists_across_wipe_and_reload() -> void:
	_say("---- the database persists across a wipe and a reload")
	game.database.clear()
	game.mark_db("night_nurse", "sighted")
	game.reset_money()   # a "wipe": money and absorbed brains reset, the database must not
	_check(game.db_record("night_nurse").sighted, "sighted survives reset_money() (a wipe)")
	# A "reload": nothing at all in memory (a fresh process would start here), then load from disk.
	var fresh: Dictionary = {}
	DatabaseStore.load_into(fresh)
	_check(fresh.has("night_nurse") and bool(fresh["night_nurse"].sighted), "the save file on disk also has it (survives a reload)")


func _no_guide_code_remains() -> void:
	_say("---- the guide binder and its `read` action are gone")
	_check(not ResourceLoader.exists("res://scripts/guide/guide_ui.gd"), "guide_ui.gd is gone")
	_check(not ResourceLoader.exists("res://scripts/guide/guide_models.gd"), "guide_models.gd is gone")
	_check(not InputMap.has_action("read"), "the `read` input action is gone")
	_check(Items.def("guide").is_empty(), "\"guide\" is no longer an item kind")
	_check(main.terminal_ui != null, "the database terminal UI replaces it")


# =========================================================================
# helpers
# =========================================================================

func _slot_of(kind: String) -> int:
	for i in me.slots.size():
		if String(me.slots[i].kind) == kind:
			return i
	return -1


func _check(ok: bool, what: String) -> void:
	_checks += 1
	_say(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures.append(what)


func _say(line: String) -> void:
	print("[databasetest] " + line)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while t < seconds:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return cond.call()


func _finish() -> void:
	_say("------------------------------------------")
	_say("result=%s checks=%d failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
