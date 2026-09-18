extends Node
## GRAFT HOOK (docs/GRAFTING.md, chunk B) headless checks: strapping yourself to the player table,
## holding E to get up, and driving Dr. Botsworth.
##
##   godot --headless --fixed-fps 60 --path . tools/straptest.tscn
##
## A dev-mode shift: aim at the table and press E to lie down strapped (awake, face up, no case),
## nobody else can strap in while you are there, holding E for TABLE_UP_HOLD puts you back on your
## feet, a second machine's copy of a strapped surgeon still shows a body (co-op), then "Control
## Dr. Botsworth" spawns him, moves the camera and input into him, and hands them back.

const LightRooms := preload("res://scripts/level/light_rooms.gd")

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
	game.start_session(12345)
	await _frames(5)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	dev.request("monsters_off", {"on": true})
	dev.request("no_game_over", {"on": true})
	game.begin_shift()
	await _frames(6)
	_quiet_loop()
	await _strapping()
	await _botsworth()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 600.0 and not _done:
		_check(false, "timed out")
		_finish()


# =========================================================================
# strapping yourself down
# =========================================================================

func _strapping() -> void:
	var ti := _free_table()
	_check(ti >= 0 or not game.player_table.is_empty(), "there is a table to lie on (free patient table %d)" % ti)
	var aim := _table_aim(ti)
	me.teleport(_beside_table(ti))
	await _frames(3)

	# ---- the offer
	var node := game.find_interactable(aim)
	_check(node != null, "the table has an aim spot (%s)" % aim)
	_check(String(node.interact_prompt(me)) == Game.STRAP_IN_PROMPT, "a healthy surgeon is offered the straps (%s)" % node.interact_prompt(me))

	# ---- a tap does nothing; E has to be held
	me.bot_aim_id = aim
	me.bot_press += 1
	await _frames(6)
	_check(not me.on_table, "a tap on the table does not strap you in: it is a hold")
	me.bot_interact = true
	await _frames(2)
	_check(me.carry_hold > 0.0 and not me.on_table, "holding E fills the hold ring (%.2f s)" % me.carry_hold)
	me.bot_interact = false
	await _frames(3)
	_check(me.carry_hold == 0.0 and not me.on_table, "letting go early throws the hold away")
	me.bot_interact = true
	var strapped_ok := await _until(func(): return me.on_table, 6.0)
	_check(strapped_ok, "holding E for TABLE_STRAP_HOLD straps you in")
	await _frames(4)
	_check(me.on_table and me.strapped(), "E straps you to the table (on_table=%s, strapped=%s)" % [me.on_table, me.strapped()])
	_check(me.alive and not me.downed and me.hp == me.max_hp, "strapped in, you are awake and unhurt")
	_check(game.player_surgery.case.is_empty(), "no stitches case: nothing is wrong with you")
	var top: Vector3 = game.player_table_top()
	_check(Vector2(me.global_position.x - top.x, me.global_position.z - top.z).length() < 1.2
		and absf(me.global_position.y - top.y) < 0.3, "your body lies on the table top")
	_check(me._pitch > 0.9, "you are looking up at the ceiling (pitch %.2f)" % me._pitch)
	_check(game.someone_on_table() == me, "the table reports you on it")
	_check(me.report_full().get("ot", false) == true, "the snapshot carries the strapped state (ot)")
	_check(not me.flashlight.is_visible_in_tree(), "your torch goes out with the straps")
	_check(_lit_lights(me).is_empty(), "no light of yours is left burning on your own face (%s)" % ", ".join(_lit_lights(me)))
	_check(not me.hands.visible and not me._held_fp.visible and not me._held_tp.visible,
		"your arms and whatever was in them are stowed, in first person and in third")
	me.take_into("suture_kit", 1)
	await _frames(3)
	_check(not me._held_fp.visible and not me._held_tp.visible, "and anything that lands in your hands stays out of sight")

	# ---- the table is taken
	var other_id: int = dev.spawn_bot("bot")
	var other: Player = game.players[other_id]
	dev.order_bot(other_id, "stay")
	await _frames(3)
	_check(game.strap_in_prompt(other) == "", "nobody else can strap in while you are on the table")
	game.strap_in(other, ti)
	await _frames(2)
	_check(not other.on_table, "strap_in refuses a second surgeon")

	# ---- co-op: a remote copy of a strapped surgeon still has a body to look at
	_check(not (me.on_table and me.downed), "a strapped surgeon is not a downed patient")
	var copy: Player = Player.new_player(4242, "Remote Copy", false)
	game.get_node("Entities").add_child(copy)
	await _frames(2)
	copy.on_table = true
	copy.downed = false
	copy.refresh_downed_visuals()
	await _frames(2)
	_check(copy.body_visual.visible, "another machine sees a strapped surgeon's body lying there")
	copy.downed = true
	copy.refresh_downed_visuals()
	_check(not copy.body_visual.visible, "a downed patient still hands over to the lying PlayerBody")
	copy.queue_free()

	# ---- the same held press must not stand you back up
	_check(String(game.get_up_prompt(me)) == "Hold E: get up", "strapped in, your own prompt is the straps (%s)" % game.get_up_prompt(me))
	_check(game.get_up_block(me) == "", "nothing blocks getting up today (chunk C blocks it after the scoop)")
	_check(me.bot_interact, "(E is still held from strapping in)")
	await _seconds(Game.TABLE_UP_HOLD + 0.5)
	_check(me.on_table and me.carry_hold == 0.0, "the press that strapped you in cannot also get you up")
	me.bot_interact = false
	await _frames(3)
	# ---- a fresh hold gets you up
	me.bot_interact = true
	var ok := await _until(func(): return not me.on_table, 6.0)
	me.bot_interact = false
	await _frames(3)
	_check(ok and not me.on_table, "a fresh press held for TABLE_UP_HOLD undoes the straps")
	_check(me.flashlight_on and me.flashlight.is_visible_in_tree(), "your torch comes back on when you get up")
	_check(not _lit_lights(me).is_empty(), "and your lights are burning again")
	_check(me.hands.visible, "and your arms are yours again")
	_check(me.alive and not me.downed and me.carry_hold == 0.0, "you get up on your feet, not downed")
	var d := Vector2(me.global_position.x - top.x, me.global_position.z - top.z).length()
	_check(d > 0.4 and d < 4.0, "you stand beside the table (%.1f m)" % d)
	_check(game.someone_on_table() == null and game.strap_table == -1, "the table is free again")
	_check(game.strap_in_prompt(other) == Game.STRAP_IN_PROMPT, "and the next surgeon can use it")

	# ---- the torch is remembered, not forced back on
	me.set_flashlight(false)
	game.strap_in(me, ti)
	await _frames(4)
	_check(me.on_table and _lit_lights(me).is_empty(), "lying down with the torch already off leaves it off")
	game.get_up_from_table(me)
	await _frames(4)
	_check(not me.on_table and not me.flashlight_on and not me.flashlight.is_visible_in_tree(),
		"and getting up does not switch it on for you")
	me.set_flashlight(true)
	await _frames(2)
	dev.request("remove_bots")
	await _frames(3)


# =========================================================================
# Dr. Botsworth
# =========================================================================

func _botsworth() -> void:
	# Strapped down again: what he sees is the whole point (chunk C operates on you here).
	game.strap_in(me, _free_table())
	await _frames(4)
	_check(me.strapped(), "strapped in again for the swap")
	var before: Vector3 = me.global_position
	dev.control_botsworth()
	await _frames(4)
	var bw = dev.possessed_player()
	_check(bw != null, "Control Dr. Botsworth spawns him and takes him over")
	if bw == null:
		return
	_check(String(bw.player_name) == "Dr. Botsworth" and bw.is_bot, "he is Dr. Botsworth, a bot body")
	_check(bw.possessed_local and not bw.bot_active, "your input is his: the brain is off")
	_check(game.viewed_player() == bw and game.driving_player() == bw and game.driving_id() == bw.peer_id,
		"the camera and the mouse are his")
	_check(bw.view_local() and not bw.body_visual.visible and bw.hands.visible, "you see out of his eyes, in first person")
	_check(me.dev_input_held and me.body_visual.visible, "your own body stays where you left it, and is drawn")
	_check(me.dev_body_shown and not me.hands.visible and not me._held_fp.visible,
		"no first-person arms of yours floating where you were")
	var layers_ok := true
	for n in me.body_visual.find_children("*", "VisualInstance3D", true, false):
		if int((n as VisualInstance3D).layers) & LightRooms.SELF != 0:
			layers_ok = false
	_check(layers_ok, "your body is on ordinary layers, so his camera draws it (not the mirrors' SELF layer)")
	_check(me.global_position.distance_to(before) < 0.6, "you did not move")
	# A full surgeon: hands that take things and an operator the surgery system accepts.
	_check(bw.has_method("take_into") and bw.slots.size() == C.CARRY_CAP, "he has a surgeon's hands")
	_check(bw.take_into("suture_kit", 1) >= 0 and bw.holding("suture_kit"), "he can hold a tool")
	_check(game.players.has(bw.peer_id) and game.alive_players().has(bw), "he counts as a player at the table")
	# ---- what he is looking at: your whole body, lying on the table
	await _frames(4)
	var top: Vector3 = game.player_table_top()
	var bp: Vector3 = me.body_visual.global_position
	_check(me.body_visual.visible and me.strapped(), "your strapped body is still drawn while he looks")
	_check(Vector2(bp.x - top.x, bp.z - top.z).length() < 1.2 and absf(bp.y - top.y) < 0.35,
		"and it lies on the table top, not standing somewhere else (%.2f m off)" % bp.distance_to(top))
	var meshes := 0
	for n in me.body_visual.find_children("*", "VisualInstance3D", true, false):
		if (n as VisualInstance3D).visible:
			meshes += 1
	_check(meshes > 0, "the whole surgeon model is there, not a pair of arms (%d visible meshes)" % meshes)
	_check(_lit_lights(me).is_empty(), "and nothing of yours lights your own face while he looks (%s)" % ", ".join(_lit_lights(me)))
	await _lies_along_the_table()
	_check(bw.global_position.distance_to(top) < 4.0, "he stands beside the table, in reach of you")
	dev.control_botsworth()
	await _frames(4)
	_check(dev.possessed_player() == null and game.possessed == 0, "the same option puts you back")
	_check(not me.dev_input_held and game.viewed_player() == me, "your input and camera are yours again")
	_check(not me.dev_body_shown and me.hands.visible == false, "back in your own body, strapped, with no floating arms")
	var still = game.players.get(bw.peer_id)
	_check(still != null and not still.possessed_local and still.bot_active and still.body_visual.visible,
		"Dr. Botsworth stays behind with his body and his brain")


## GRAFT HOOK: the drawn body has to lie ALONG the table, head at the head end, whichever way the
## table faces -- the rig's "Lying" clip runs along its own Z, the table's long axis is its X, and
## pinned_pose puts the strapped player's camera at the -X end looking down +X at their own feet.
func _lies_along_the_table() -> void:
	var skel: Skeleton3D = me.body_hands.skeleton if me.body_hands != null else null
	if skel == null or skel.find_bone("head") < 0:
		_check(false, "the surgeon rig has a skeleton to measure")
		return
	var ti := int(game.player_table.get("index", -1))
	var was := game.player_table_yaw()
	for yaw in [0.0, PI * 0.5, PI, -PI * 0.5, 0.7]:
		_set_table_yaw(ti, yaw)
		await _frames(12)
		var head: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("head")).origin
		var hips: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("hips")).origin
		var foot: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("foot.L")).origin
		var b := Basis(Vector3.UP, game.player_table_yaw())
		var along: Vector3 = b * Vector3(-1.0, 0.0, 0.0)   # the table's long axis, toward the head end
		var dir: Vector3 = head - hips
		dir.y = 0.0
		_check(dir.length() > 0.2 and dir.normalized().dot(along) > 0.95,
			"yaw %.2f: the body lies along the table, head toward the head end (%.2f)" % [yaw, dir.normalized().dot(along) if dir.length() > 0.001 else 0.0])
		# and not sticking out over the sides: everything within half the table's width of its middle
		var top: Vector3 = game.player_table_top()
		for part in [["head", head], ["hips", hips], ["foot", foot]]:
			var local: Vector3 = b.inverse() * ((part[1] as Vector3) - top)
			_check(absf(local.z) < 0.45 and absf(local.x) < 1.05,
				"yaw %.2f: the %s is on the table, not over the side (%.2f across, %.2f along)" % [yaw, part[0], local.z, local.x])
		# the camera the strapped player looks out of is at the same end as their head
		var cam: Vector3 = b.inverse() * (game.pinned_pose(me).origin - top)
		var head_l: Vector3 = b.inverse() * (head - top)
		_check(signf(cam.x) == signf(head_l.x),
			"yaw %.2f: your own camera sits at the end your head is at (%.2f vs %.2f)" % [yaw, cam.x, head_l.x])
	_set_table_yaw(ti, was)
	await _frames(6)


func _set_table_yaw(ti: int, yaw: float) -> void:
	for t in game.patient_tables:
		if int(t.index) == ti:
			t["yaw"] = yaw
	if ti < 0:
		game.player_table["yaw"] = yaw


## GRAFT HOOK: every light this player carries that is actually burning right now.
func _lit_lights(p: Player) -> Array:
	var out := []
	for n in p.find_children("*", "Light3D", true, false):
		var l := n as Light3D
		if l.is_visible_in_tree() and l.light_energy > 0.0:
			out.append("%s (energy %.2f)" % [l.name, l.light_energy])
	return out


# =========================================================================
# helpers
# =========================================================================

## The patient table a strapped surgeon would use on this level, or -1 on a level with its own
## player table.
func _free_table() -> int:
	if not game.downed_any_table:
		return -1
	for tb in game.patient_tables:
		if game.case_on_table(int(tb.index)).is_empty() and not game.loop.table_reserved(int(tb.index)):
			return int(tb.index)
	return -1


func _table_aim(ti: int) -> String:
	return game.table_interact_id(ti) if ti >= 0 else "player_table"


func _beside_table(ti: int) -> Vector3:
	var at: Vector3 = game.table_position(ti) if ti >= 0 else (game.player_table.position as Vector3)
	return game._floor_at(at + Vector3(1.1, 0.0, 0.0))


## The phone rings on clock-in: hang it up and skip the extra call so no patient arrives.
func _quiet_loop() -> void:
	game.loop._end_call()
	game.loop.first_called = true


func _check(ok: bool, what: String) -> void:
	print("[straptest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[straptest] ------------------------------------------")
	print("[straptest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(sec: float) -> void:
	var end := t + sec
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return false
