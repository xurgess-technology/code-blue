extends Node
## GRAFT HOOK (docs/GRAFTING.md, chunk B): the smoke look for strapping yourself down and driving
## Dr. Botsworth (RULES.md, "Tests that make sense"). Boots the real game windowed, walks through
## the thing once and saves screenshots so the look can be checked without a human at the keyboard.
##
##   tools\review.bat 2 "SMOKE" -Scene res://tools/strapshot.tscn     (minimized, never takes focus)
##
## Shots land in tools/strap_shots/.

const OUT_DIR := "res://tools/strap_shots"
const SETTLE := 24

var main: Node3D
var game: Game
var me: Player
var _i := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(600.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Smoke")
	game.start_session(12345)
	await get_tree().process_frame
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	game.set_dev_tools(true, me)
	game.dev.request("monsters_off", {"on": true})
	game.dev.request("no_game_over", {"on": true})
	game.begin_shift()
	await _frames(8)
	game.loop._end_call()
	game.loop.first_called = true
	me.take_into("suture_kit", 1)
	await _run()


func _run() -> void:
	var ti := _free_table()
	var aim := game.table_interact_id(ti) if ti >= 0 else "player_table"
	var top: Vector3 = game.table_position(ti) + Vector3(0, Game.OR_TABLE_TOP, 0) if ti >= 0 else game.player_table_top()

	# 1. aiming at the table, torch and suture kit in hand: the prompt should say Hold E.
	_look_from(game._floor_at(top + Vector3(1.6, -Game.OR_TABLE_TOP, 0.0)), top)
	me.bot_aim_id = aim
	await _shot("01_prompt")

	# 2. mid-hold: the ring says STRAPPING IN.
	me.bot_interact = true
	await _seconds(0.6)
	await _shot("02_holding")

	# 3. strapped: your own view, looking up. No arms, no torch, no suture kit.
	var ok := await _until(func(): return me.on_table, 6.0)
	print("[strapshot] strapped=%s flashlight=%s hands=%s held=%s" % [ok, me.flashlight_on, me.hands.visible, me._held_fp.visible])
	me.bot_interact = false
	await _shot("03_strapped_own_view")

	# 4-8. Dr. Botsworth, looking back at you on the table: the whole surgeon, lying ALONG it, head
	# at the head end. Both table orientations, from his eyes and from above.
	game.dev.control_botsworth()
	await _frames(6)
	var bw = game.dev.possessed_player()
	if bw != null:
		bw.noclip = true   # so the "from above" shots can leave the floor
		_look_at_with(bw, game._floor_at(top + Vector3(0.0, -Game.OR_TABLE_TOP, 2.2)), top)
		await _shot("04_from_botsworth")
		_look_at_with(bw, game._floor_at(top + Vector3(-2.2, -Game.OR_TABLE_TOP, 1.4)), top)
		await _shot("05_from_botsworth_side")
		# leaning over the head end: no torch and no head glow burning on the face
		var b0 := Basis(Vector3.UP, game.player_table_yaw())
		var head_end: Vector3 = top + b0 * Vector3(-0.95, 0.0, 0.0)
		_look_at_with(bw, game._floor_at(head_end + b0 * Vector3(-0.7, -Game.OR_TABLE_TOP, 0.0)), head_end + Vector3(0, 0.12, 0))
		await _shot("05b_face_close")
		print("[strapshot] lights burning on the strapped body: %s" % str(_lit(me)))
		_above(bw, top)
		await _shot("06_from_above")
		_report(top)
		# The other orientation. Every table in this OR sits at yaw 0, so this turns the table DATA a
		# quarter turn: the body and the camera follow it, the built table model does not, so the two
		# shots below are for the body's own alignment (the numbers printed with them), not for how it
		# sits on a table. straptest measures five yaws properly.
		_turn_table(ti, PI * 0.5)
		await _frames(20)
		top = game.player_table_top()
		_look_at_with(bw, game._floor_at(top + Vector3(2.2, -Game.OR_TABLE_TOP, 0.0)), top)
		await _shot("07_yaw_turned_from_botsworth")
		_above(bw, top)
		await _shot("08_yaw_turned_from_above")
		_report(top)
		_turn_table(ti, 0.0)
		await _frames(20)
		top = game.player_table_top()
		bw.noclip = false
	game.dev.control_botsworth()
	await _frames(6)

	# 5. back in your own body, and up off the table.
	me.bot_interact = true
	await _until(func(): return not me.on_table, 6.0)
	me.bot_interact = false
	await _seconds(0.5)
	_look_from(me.global_position, top)
	print("[strapshot] up again: torch on=%s lights burning=%s" % [me.flashlight_on, str(_lit(me))])
	await _shot("09_back_up")
	print("[strapshot] done, %d shots" % _i)
	get_tree().quit(0)


## Every light this player carries that is actually burning.
func _lit(p: Player) -> Array:
	var out := []
	for n in p.find_children("*", "Light3D", true, false):
		var l := n as Light3D
		if l.is_visible_in_tree() and l.light_energy > 0.0:
			out.append(l.name)
	return out


## A camera above the table, looking straight down the long axis from overhead.
func _above(p: Player, top: Vector3) -> void:
	p.teleport(top + Vector3(0.0, 3.4, 0.01))
	p.bot_yaw = game.player_table_yaw() - PI * 0.5
	p._yaw = p.bot_yaw
	p.rotation.y = p.bot_yaw
	p.bot_pitch = -1.45
	p._pitch = -1.45
	p.head.rotation.x = -1.45


func _turn_table(ti: int, yaw: float) -> void:
	for t in game.patient_tables:
		if int(t.index) == ti:
			t["yaw"] = yaw
	if ti < 0:
		game.player_table["yaw"] = yaw


## The numbers behind the picture: where the head and the feet actually are, along the table.
func _report(top: Vector3) -> void:
	var skel: Skeleton3D = me.body_hands.skeleton if me.body_hands != null else null
	if skel == null:
		return
	var b := Basis(Vector3.UP, game.player_table_yaw())
	var out := []
	for n in ["head", "hips", "foot.L"]:
		var bi := skel.find_bone(n)
		if bi >= 0:
			var w: Vector3 = skel.global_transform * skel.get_bone_global_pose(bi).origin
			var l: Vector3 = b.inverse() * (w - top)
			out.append("%s along %.2f across %.2f up %.2f" % [n, l.x, l.z, l.y])
	print("[strapshot] yaw %.2f  %s  (table top is 2.2 x 0.7)" % [game.player_table_yaw(), ", ".join(out)])


func _free_table() -> int:
	if not game.downed_any_table:
		return -1
	for tb in game.patient_tables:
		if game.table_free(int(tb.index)):
			return int(tb.index)
	return -1


func _shot(name: String) -> void:
	for i in SETTLE:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	_i += 1
	print("[strapshot] wrote %s  %dx%d" % [path, img.get_width(), img.get_height()])


func _look_from(pos: Vector3, at: Vector3) -> void:
	_look_at_with(me, pos, at)


func _look_at_with(p: Player, pos: Vector3, at: Vector3) -> void:
	p.teleport(pos)
	var d := at - (pos + Vector3(0, C.EYE_H, 0))
	var yaw := atan2(-d.x, -d.z)
	var pitch := clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	p.bot_yaw = yaw
	p.bot_pitch = pitch
	p._yaw = yaw
	p._pitch = pitch
	p.rotation.y = yaw
	p.head.rotation.x = pitch


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return false
