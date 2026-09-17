extends Node
## Headless checks for the database terminal (sweep 4a chunk 4, docs/SWEEP4A.md "Chunk 4:
## Database terminal, guide removal, Hive Eyes and Echo polish"): a completed scan unlocks tier 2,
## a harvest (dissection or an absorbed brain) unlocks tier 3, the database survives a wipe and a
## reload (saved under user://), each player's database is their own (another player's scan never
## lands in yours), the waiting room's Night Nurse can be scanned, and no `read` action or guide
## binder code remains in the project. Terminal redesign, chunk 4: on the break room screen, holding
## the laser on HOLD TO SIGN IN signs in and fills the cards with your database (nobody signed in:
## "???"), and SIGN OUT, walking away and the idle timeout each sign you out.
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
	await _guest_scan_stays_theirs()
	await _scan_waiting_nurse()
	await _wall_sign_in_and_out()
	_persists_across_wipe_and_reload()
	_no_guide_code_remains()


# =========================================================================

func _scan_unlocks_tier2() -> void:
	_say("---- a completed scan unlocks tier 2 in the host database")
	game.database.clear()
	# The OR is always open floor around the patient table, clear of furniture that could block
	# the scanner's raycast (a lobby spawn point can have chairs/desks within a few metres).
	me.teleport(game.table_pos() + Vector3(0, 0, -2.0))
	await _frames(3)
	var here: Vector3 = me.global_position
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(here + Vector3(0, 0, 4))) as Node3D
	await _frames(2)
	var to: Vector3 = wi.global_position - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_pitch = 0.0
	me.bot_scan = true
	var pin: Vector3 = wi.global_position
	# Aim from the real camera position/basis rather than the player's own position, so this still
	# works correctly whenever the camera isn't exactly at the head (e.g. while carrying/dragging;
	# same idea as carrycamtest.gd's _aim_camera).
	var track := func():
		wi.global_position = pin
		var cam: Vector3 = me.camera.global_position
		# Aim at the monster's centre (game.gd's own `_scan_aim` measures distance the same way),
		# not its floor-level origin, or a raised camera would pitch down onto its feet and miss.
		var d: Vector3 = (pin + Vector3.UP * 1.0) - cam
		var fwd: Vector3 = -me.camera.global_transform.basis.z
		var yaw_err := wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		me.bot_yaw += yaw_err
		var pitch_err := atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length())
		me.bot_pitch = clampf(me.bot_pitch + pitch_err, -1.2, 1.2)
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


func _guest_scan_stays_theirs() -> void:
	_say("---- another player's scan goes in their database, not this one")
	game.database.erase("walk_in")
	var guest: Player = Player.new_player(-501, "Guest", false)
	guest.is_bot = true
	guest.bot_active = true
	guest.bot_invulnerable = true
	game.players[-501] = guest
	game.get_node("Entities").add_child(guest)
	guest.teleport(game.table_pos() + Vector3(2.0, 0.0, -2.0))   # open OR floor, see _scan_unlocks_tier2
	await _frames(3)
	var wi: Node3D = game.brains.spawn_walk_in(game._floor_at(guest.global_position + Vector3(0, 0, 4))) as Node3D
	await _frames(2)
	# This machine's own player looks away, so only the guest sights and scans it.
	me.bot_yaw = atan2(-(guest.global_position - wi.global_position).x, -(guest.global_position - wi.global_position).z)
	var to: Vector3 = wi.global_position - guest.global_position
	guest.bot_yaw = atan2(-to.x, -to.z)
	guest.bot_pitch = 0.0
	guest.bot_scan = true
	var pin: Vector3 = wi.global_position
	var track := func():
		wi.global_position = pin
		var d: Vector3 = pin - guest.global_position
		guest.bot_yaw = atan2(-d.x, -d.z)
		return int(game._scan_target.get(-501, -1)) >= 0 and float(game._scan_progress.get(-501, 0.0)) > 0.9
	var scanning := await _until(track, 8.0)
	await _frames(20)
	_check(scanning, "the guest's scan ran on the host")
	_check(not game.db_record("walk_in").scanned, "the guest's scan did not land in this player's database")
	guest.bot_scan = false
	game.kill_monster(wi)
	game.players.erase(-501)
	guest.queue_free()


func _scan_waiting_nurse() -> void:
	_say("---- the waiting room's Night Nurse can be scanned")
	var wn: Node3D = game.economy.waiting_nurse if game.economy != null else null
	_check(wn != null and game.scan_props.has(wn), "the waiting Night Nurse is a scan prop")
	if wn == null:
		return
	game.database.erase("night_nurse")
	wn.set_process(false)   # hold her still in her chair
	var target: Vector3 = wn.global_position + Vector3.UP * 1.0
	var from: Vector3 = wn.global_position + wn.global_basis.z * 3.0
	me.teleport(game._floor_at(Vector3(from.x, wn.global_position.y, from.z)))
	await _frames(3)
	me.bot_scan = true
	var track := func():
		var cam: Vector3 = me.camera.global_position
		var d: Vector3 = target - cam
		var fwd: Vector3 = -me.camera.global_transform.basis.z
		me.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		var pitch_err := atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length())
		me.bot_pitch = clampf(me.bot_pitch + pitch_err, -1.2, 1.2)
		return game.db_record("night_nurse").scanned
	var done := await _until(track, 8.0)
	me.bot_scan = false
	wn.set_process(true)
	_check(me.scan_target_id == -10 or done, "the local scan ray finds her (target %d)" % me.scan_target_id)
	_check(done and game.db_record("night_nurse").sighted, "scanning her fills in the Night Nurse's entry (tiers 1 and 2)")


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


func _wall_sign_in_and_out() -> void:
	_say("---- the break room screen: sign in by holding, sign out three ways")
	var wt: Node3D = game.wall_terminal()
	_check(wt != null, "the level has the screen")
	if wt == null:
		return
	game._set_projector(true)
	game.database.clear()
	game.mark_own_db("walk_in", "sighted")
	game.mark_own_db("walk_in", "scanned")
	wt.ui.go_home()
	var glass: Node3D = wt.glass
	var out: Vector3 = glass.global_basis.z.normalized()
	var stand: Vector3 = glass.global_position + out * 4.6
	me.teleport(game._floor_at(Vector3(stand.x, 0.0, stand.z)))
	await _frames(3)
	_check(not _walk_in_known(), "signed out: the Walk-In is ??? on the screen")
	var aim := func(px: Vector2):
		var at: Vector3 = glass.global_transform * Vector3((px.x / wt.TEX.x - 0.5) * wt.SIZE.x, (0.5 - px.y / wt.TEX.y) * wt.SIZE.y, 0.0)
		var d: Vector3 = at - me.camera.global_position
		var fwd: Vector3 = -me.camera.global_transform.basis.z
		me.bot_yaw += wrapf(atan2(-d.x, -d.z) - atan2(-fwd.x, -fwd.z), -PI, PI)
		me.bot_pitch = clampf(me.bot_pitch + atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length()), -1.2, 1.2)
	var sign_px: Vector2 = wt.ui.sign_rect().get_center()
	me.bot_scan = true
	for i in 30:
		aim.call(sign_px)
		await _frames(1)
	me.bot_laser_hold = true
	for i in 45:   # 0.75 s: not yet
		aim.call(sign_px)
		await _frames(1)
	_check(int(game.wall.user) == 0, "half a hold does not sign in")
	for i in 60:
		aim.call(sign_px)
		await _frames(1)
	me.bot_laser_hold = false
	_check(int(game.wall.user) == me.peer_id, "a 1.5 s hold on HOLD TO SIGN IN signs in")
	_check(_walk_in_known(), "signed in: my scanned Walk-In fills its card")
	game.mark_own_db("discharged", "scanned")
	_check(int(game.wall.view().db.get("discharged", 0)) & 2 != 0, "a scan while signed in reaches the screen")
	# SIGN OUT is a click.
	wt.ui.open({"kind": "section", "id": "monsters", "index": 0})
	var out_px: Vector2 = wt.ui._sign.position + wt.ui._sign.size * 0.5
	for i in 20:
		aim.call(out_px)
		await _frames(1)
	me.bot_laser_click += 1
	await _frames(3)
	_check(int(game.wall.user) == 0 and String(wt.ui.page.kind) == "home", "SIGN OUT signs out and goes HOME")
	# Walking away.
	game.wall.sign_in()
	_check(int(game.wall.user) == me.peer_id, "signed in again")
	me.bot_scan = false
	me.teleport(game._floor_at(glass.global_position + out * 4.0 + glass.global_basis.x.normalized() * 12.0))
	await _frames(3)
	_check(int(game.wall.user) == 0, "walking %.0f m away signs out" % game.wall.WALK_AWAY_M)
	# Idle.
	me.teleport(game._floor_at(Vector3(stand.x, 0.0, stand.z)))
	await _frames(3)
	game.wall.sign_in()
	game.wall._idle = game.wall.IDLE_SECONDS - 0.5
	await _frames(10)
	_check(int(game.wall.user) == me.peer_id, "still signed in just before the idle timeout")
	await _frames(30)
	_check(int(game.wall.user) == 0, "nobody's laser on the screen for %.0f s signs out" % game.wall.IDLE_SECONDS)
	me.bot_scan = false


func _walk_in_known() -> bool:
	var wt: Node3D = game.wall_terminal()
	for e in wt.ui.Pages.entries("monsters", game.wall.view()):
		if String(e.key) == "walk_in":
			return bool(e.known)
	return false


func _no_guide_code_remains() -> void:
	_say("---- the guide binder and its `read` action are gone")
	_check(not ResourceLoader.exists("res://scripts/guide/guide_ui.gd"), "guide_ui.gd is gone")
	_check(not ResourceLoader.exists("res://scripts/guide/guide_models.gd"), "guide_models.gd is gone")
	_check(not InputMap.has_action("read"), "the `read` input action is gone")
	_check(Items.def("guide").is_empty(), "\"guide\" is no longer an item kind")
	_check(game.wall != null and game.wall_terminal() != null, "the break room screen replaces it")


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
		await get_tree().physics_frame


func _until(cond: Callable, seconds: float) -> bool:
	var frames := int(seconds * 60.0)
	for i in frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())


func _finish() -> void:
	_say("------------------------------------------")
	_say("result=%s checks=%d failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()])
	for f in _failures:
		_say("  failed: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
