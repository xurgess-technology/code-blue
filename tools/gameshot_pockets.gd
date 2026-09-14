extends RefCounted
## POCKETS: gameshot's pocket space shots (tools/gameshot.gd --pocket=factory|restaurant).
##
##   godot --path . tools/gameshot.tscn --resolution 1280x720 -- --pocket=factory [--seed=N]
##
## Writes tools/game_shots/p_<kind>_*.png: the space from a few places, an entrance opening from
## inside, and for every seam the hallway side (the mouth, the view from the first bend down leg 2),
## the same pose in both copies of the stub on each side of the seam (the image difference is
## printed: identical copies differ only by noise), and the frames just before and just after a
## walk through the seam.

const Stub := preload("res://scripts/level/pockets/stub.gd")
const OUT_DIR := "res://tools/game_shots"

var shot: Node
var game: Game
var bot: Player
var kind := ""
var tag := ""


func run(gs: Node, pocket_kind: String) -> void:
	shot = gs
	game = gs.game
	bot = gs.bot
	kind = pocket_kind
	tag = gs._tag
	var tree := gs.get_tree()
	while game.get_parent().has_node("WarmupCover"):
		await tree.process_frame
	game.begin_shift()
	game._clear_monsters()
	await _settle(30)
	var pk = game.pockets
	if not pk.active():
		print("[gameshot] no pocket was built")
		return
	bot.set_flashlight(true)
	var p: Dictionary = pk.pocket
	var lay: Dictionary = p.layout
	var o := Vector3(Vector2i(p.origin).x * C.TILE, 0.0, Vector2i(p.origin).y * C.TILE)
	var w := func(t: Vector2, y := 0.0) -> Vector3:
		return o + Vector3(t.x * C.TILE, y, t.y * C.TILE)
	if kind == "factory":
		bot.set_flashlight(false)
		await _shot("p_factory_1_hall", w.call(Vector2(14, 50)), w.call(Vector2(60, 16), 6.0))
		await _shot("p_factory_2_catwalk", w.call(Vector2(40, 12), 6.0), w.call(Vector2(38, 44), 1.0))
		bot.set_flashlight(true)
		await _shot("p_factory_3_line", w.call(Vector2(20, 30)), w.call(Vector2(34, 23), 1.5))
		await _shot("p_factory_4_up", w.call(Vector2(36, 32)), w.call(Vector2(40, 30), 20.0))
		await _shot("p_factory_5_offices", w.call(Vector2(24, 42)), w.call(Vector2(26, 49), 1.5))
	else:
		await _shot("p_restaurant_1_dining", w.call(Vector2(12.5, 25.5)), w.call(Vector2(34, 12), 1.0))
		await _shot("p_restaurant_2_host", w.call(Vector2(28, 22)), w.call(Vector2(28, 11), 1.6))
		await _shot("p_restaurant_3_bar", w.call(Vector2(33, 23)), w.call(Vector2(40, 14), 1.4))
		var t: Dictionary = lay.tables[mini(3, lay.tables.size() - 1)]
		var tp: Vector3 = w.call(Vector2(t.tile) + Vector2(0.5, 0.5))
		await _shot("p_restaurant_4_table", tp + Vector3(1.1, 0, 1.3), tp + Vector3(0, 0.8, 0))
		await _shot("p_restaurant_5_kitchen", w.call(Vector2(27, 29.5)), w.call(Vector2(40, 33), 1.2))
	# An entrance from inside the space.
	var s0: Dictionary = pk.seams[0]
	await _shot("p_%s_6_opening" % kind, Stub.local_point(s0.xp, float(s0.w) - 1.0, -7.0), Stub.local_point(s0.xp, float(s0.w) - 1.0, 0.0, 1.6))
	# Every seam from the hallway side, and the two copies compared.
	LightFlicker.sync_time(3.0)
	var fx = Look.get_post_fx(game.get_tree().root)
	for s in pk.seams:
		var i := int(s.id)
		var back := float(s.d) - 1.0
		pk.crossing_enabled = true
		await _shot("p_%s_s%d_a_hallway" % [kind, i], Stub.local_point(s.xh, -3.0, -2.5), Stub.local_point(s.xh, 1.0, 1.5, 1.5))
		await _shot("p_%s_s%d_b_bend" % [kind, i], Stub.local_point(s.xh, 0.9, back - 0.6), Stub.local_point(s.xh, float(s.w), back, 1.5))
		pk.crossing_enabled = false
		if fx != null:
			fx.set_enabled(false)
		var a: Image = await _grab("p_%s_s%d_c_forward_hospital" % [kind, i], Stub.local_point(s.xh, 1.1, back), Stub.local_point(s.xh, float(s.w), back, 1.6))
		var b: Image = await _grab("p_%s_s%d_c_forward_pocket" % [kind, i], Stub.local_point(s.xp, 1.1, back), Stub.local_point(s.xp, float(s.w), back, 1.6))
		print("[gameshot] seam %d forward (from the hospital side): copies differ by %s" % [i, _diff(a, b)])
		var c: Image = await _grab("p_%s_s%d_d_back_pocket" % [kind, i], Stub.local_point(s.xp, float(s.w) - 1.1, back), Stub.local_point(s.xp, 0.0, back, 1.6))
		var d: Image = await _grab("p_%s_s%d_d_back_hospital" % [kind, i], Stub.local_point(s.xh, float(s.w) - 1.1, back), Stub.local_point(s.xh, 0.0, back, 1.6))
		print("[gameshot] seam %d back (from the pocket side): copies differ by %s" % [i, _diff(c, d)])
		if fx != null:
			fx.set_enabled(true)
		pk.crossing_enabled = true
		await _walk_shot(s, i)
	await _ghost_shot(pk.seams[0])
	LightFlicker._clock_driven = false


## A teammate (a bot) walks ahead through the seam while we watch from the first bend: once it is past
## the seam it is really in the pocket, and its ghost must still stand where we see it.
func _ghost_shot(s: Dictionary) -> void:
	var pk = game.pockets
	var back := float(s.d) - 1.0
	var mate = preload("res://scripts/player.gd").new_player(-77, "Teammate", false)
	mate.is_bot = true
	mate.bot_active = true
	mate.bot_invulnerable = true
	game.players[-77] = mate
	game.get_node("Entities").add_child(mate)
	mate.teleport(Stub.local_point(s.xh, 2.6, back))
	_pose(Stub.local_point(s.xh, 0.8, back - 0.3), Stub.local_point(s.xh, float(s.w), back, 1.4))
	await _settle(20)
	var n0: int = pk.crossings.size()
	for k in 400:
		var frame: Transform3D = s.xp if pk.in_pocket(mate.global_position) else s.xh
		var to: Vector3 = Stub.local_point(frame, float(s.w) - 1.0, back) - mate.global_position
		to.y = 0.0
		mate.bot_yaw = atan2(-to.x, -to.z)
		mate.bot_move = Vector2(0, -1) if to.length() > 0.4 else Vector2.ZERO
		await shot.get_tree().process_frame
		var l := Stub.to_local(frame, mate.global_position)
		if pk.in_pocket(mate.global_position) and l.x > Stub.seam_s(s.w) + 0.9:
			break
	mate.bot_move = Vector2.ZERO
	await _settle(4)
	var img := shot.get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/p_%s_ghost%s.png" % [OUT_DIR, kind, tag]))
	print("[gameshot] teammate crossed %d time(s), in the pocket %s, ghosts %d" % [pk.crossings.size() - n0, str(pk.in_pocket(mate.global_position)), pk._mirrors.size()])
	game.players.erase(-77)
	mate.queue_free()


func _settle(n: int) -> void:
	for k in n:
		await shot.get_tree().process_frame


func _pose(from: Vector3, at: Vector3) -> void:
	bot.teleport(from)
	var d := at - (from + Vector3.UP * C.EYE_H)
	var yaw := atan2(-d.x, -d.z)
	var pitch := clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)
	bot.bot_yaw = yaw
	bot._yaw = yaw
	bot.rotation.y = yaw
	bot.bot_pitch = pitch
	bot._pitch = pitch
	bot.head.rotation.x = pitch
	bot.bot_move = Vector2.ZERO


func _shot(name: String, from: Vector3, at: Vector3, settle := 34) -> void:
	await _grab(name, from, at, settle)


func _grab(name: String, from: Vector3, at: Vector3, settle := 40) -> Image:
	_pose(from, at)
	await _settle(settle)
	var img := shot.get_viewport().get_texture().get_image()
	var path := "%s/%s%s.png" % [OUT_DIR, name, tag]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[gameshot] wrote ", path)
	return img


## Mean and 99th percentile absolute difference, in % of full scale, over a downsampled image.
func _diff(a: Image, b: Image) -> String:
	var x := a.duplicate() as Image
	var y := b.duplicate() as Image
	x.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	y.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var vals := PackedFloat32Array()
	var total := 0.0
	for j in 180:
		for i in 320:
			var ca := x.get_pixel(i, j)
			var cb := y.get_pixel(i, j)
			var dv := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			vals.append(dv)
			total += dv
	vals.sort()
	return "mean %.2f%%, 99th percentile %.2f%%, max %.2f%%" % [100.0 * total / vals.size(), 100.0 * vals[int(vals.size() * 0.99)], 100.0 * vals[vals.size() - 1]]


## Walk through the seam from the hospital side and keep the frame before and after the move.
func _walk_shot(s: Dictionary, i: int) -> void:
	var pk = game.pockets
	var back := float(s.d) - 1.0
	_pose(Stub.local_point(s.xh, 2.4, back), Stub.local_point(s.xh, float(s.w), back, 1.6))
	await _settle(40)
	var target_h := Stub.local_point(s.xh, float(s.w) - 1.0, back)
	var before: Image = null
	var n0: int = pk.crossings.size()
	for k in 240:
		var frame: Transform3D = s.xp if pk.in_pocket(bot.global_position) else s.xh
		var to := Stub.local_point(frame, float(s.w) - 1.0, back) - bot.global_position
		to.y = 0.0
		bot.bot_yaw = atan2(-to.x, -to.z)
		bot.bot_move = Vector2(0, -1)
		await shot.get_tree().process_frame
		if pk.crossings.size() > n0:
			var after := shot.get_viewport().get_texture().get_image()
			after.save_png(ProjectSettings.globalize_path("%s/p_%s_s%d_e_after%s.png" % [OUT_DIR, kind, i, tag]))
			if before != null:
				before.save_png(ProjectSettings.globalize_path("%s/p_%s_s%d_e_before%s.png" % [OUT_DIR, kind, i, tag]))
				print("[gameshot] seam %d walk: the frame before and after the move differ by %s" % [i, _diff(before, after)])
			break
		before = shot.get_viewport().get_texture().get_image()
	bot.bot_move = Vector2.ZERO
