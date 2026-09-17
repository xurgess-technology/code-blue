extends Node
## Headless checks for the over-the-shoulder carry camera (docs/HANDS_AND_FEEDBACK.md "Done when"):
## with the camera behind the shoulder, the real aim ray (no bot_aim_id) still puts a carried player
## on a free patient table in the hospital's OR and straps a dragged monster to a patient table; the camera sits close
## behind the RIGHT shoulder while carrying (the load rides the LEFT: the carried player, a human
## body's mirrored Carried model, a seal/monster body), swings a little around the upper-back pivot
## as the player looks down and up, hides the first-person hands and shows the body, keeps its
## offset through a teleport, ignores an interactable between the camera and the head, frames a
## dragged monster over the right shoulder too, pulls in against a wall, and eases back to first
## person when the body is put down or the setting is off.
##
## A normal hospital (seed 4242) with dev mode on for its dummies, No monsters, clocked in (carrying
## and the tables work on shift) with the phone hung up.
##
##   godot --headless --fixed-fps 60 --path . tools/carrycamtest.tscn

const SEED := 4242
const HandsFP := preload("res://scripts/hands/fp_hands.gd")
const CarryCam := preload("res://scripts/camera/carry_camera.gd")

var main: Node3D
var game: Game
var me: Player
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Settings.use_path("user://carrycamtest_settings.cfg")
	Net.start_solo("Tester")
	game.start_session(SEED)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _frames(8)
	me = game.local_player()
	me.bot_active = true
	me.bot_invulnerable = true
	game.set_dev_tools(true, me)
	game.dev.request("monsters_off", {"on": true})
	game.dev.request("no_game_over", {"on": true})
	game.clock_in()
	var on_shift := await _until(func(): return game.phase == Game.Phase.SHIFT, 90.0)
	game.loop._end_call()
	game.loop.first_called = true
	game.loop.extra_done = true
	_check(on_shift and game.dev_on() and game.dev.room_ready(), "set-up: dev mode on, clocked in (phase %d)" % game.phase)
	await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 300.0 and not _done:
		_check(false, "timed out")
		_finish()


func _run() -> void:
	var cc = me.carry_cam
	_check(cc != null and String(Settings.get_value("carry_camera")) == "shoulder", "the local player has a carry camera, setting 'shoulder' by default")
	_check(not cc.active and me.fx.position == Vector3.ZERO and me.camera.cull_mask & HandsFP.HANDS_LAYER != 0,
		"ordinary play (not carrying/dragging) is locked to true first person (blend %.2f)" % cc.blend)

	for m in game.monsters.values():
		game.kill_monster(m)
	await _frames(2)

	# ---- carry a downed dummy
	var did: int = game.dev.spawn_bot("dummy")
	var dummy: Player = game.players[did]
	await _frames(3)
	# Hub rebuild: no fixed player table; a downed teammate goes on whichever patient table is free.
	var pi: int = game.free_patient_table()
	var pid: String = game.table_interact_id(pi)
	var pt: Vector3 = game.table_position(pi)
	var pside: Vector3 = Basis(Vector3.UP, game.table_yaw_of(pi)) * Vector3(0, 0, 1)
	dummy.teleport(game._floor_at(pt + pside * 2.6))
	game.down_player(dummy, "test")
	await _frames(2)
	game.start_carry(me, dummy)
	await _frames(2)
	_check(me.carrying == did, "set-up: carrying the downed dummy")
	await _seconds(0.5)
	_check(cc.active and cc.blend >= 1.0, "carrying: the camera moved over the shoulder (blend %.2f)" % cc.blend)
	me.bot_pitch = 0.0
	await _frames(3)
	var level := _yaw_offset()
	_check(level.x > 0.4 and level.x < 0.65 and level.z > 1.0 and level.z < 1.45 and level.y > 0.05 and level.y < 0.3,
		"close behind and over the RIGHT shoulder: 0.4-0.65 m right, 1.0-1.45 m back, 0.05-0.3 m up (%s)" % str(level.snappedf(0.01)))
	_check(level.distance_to(CarryCam.rest_offset(CarryCam.CARRY_ARM, 0.0)) < 0.05, "in the open it sits at the rest offset (%s)" % str(CarryCam.rest_offset(CarryCam.CARRY_ARM, 0.0).snappedf(0.01)))
	var ride: Vector3 = Basis(Vector3.UP, me.global_rotation.y).inverse() * (dummy.global_position - me.global_position)
	_check(ride.x < -0.4, "the carried player rides the LEFT shoulder (%s in the carrier's frame)" % str(ride.snappedf(0.01)))
	var hc: Transform3D = Player.human_carried_pose(me)
	var hc_local: Vector3 = Basis(Vector3.UP, me.global_rotation.y).inverse() * (hc.origin - me.global_position)
	_check(hc_local.x < -0.1 and hc.basis.determinant() < 0.0, "a human's Carried clip goes on the left shoulder, mirrored (%s, det %.1f)" % [str(hc_local.snappedf(0.01)), hc.basis.determinant()])
	var sp: Transform3D = game.corpses.shoulder_pose(me)
	var sp_local: Vector3 = Basis(Vector3.UP, me.global_rotation.y).inverse() * (sp.origin - me.global_position)
	_check(sp_local.x < -0.1, "a seal/monster body (and the furnace roll-off) starts over the left shoulder (%s)" % str(sp_local.snappedf(0.01)))
	# Looking down lifts the camera a little over the shoulder, looking up lowers it: a swing around
	# the upper back, not a full orbit and not rigid.
	me.bot_pitch = -0.9
	await _frames(3)
	var down := _yaw_offset()
	me.bot_pitch = 0.9
	await _frames(3)
	var up := _yaw_offset()
	me.bot_pitch = 0.0
	await _frames(3)
	_check(down.y > level.y + 0.2 and down.y < level.y + 0.8 and up.y < level.y - 0.15 and up.y > level.y - 0.8,
		"the pitch swings the camera around the upper back: up %.2f / level %.2f / down %.2f m" % [up.y, level.y, down.y])
	_check(absf(down.x - level.x) < 0.02 and absf(up.x - level.x) < 0.02 and up.z < level.z, "it stays over the right shoulder and comes in a little looking up (z up %.2f, level %.2f)" % [up.z, level.z])
	_check(down.distance_to(CarryCam.rest_offset(CarryCam.CARRY_ARM, -0.9)) < 0.05 and up.distance_to(CarryCam.rest_offset(CarryCam.CARRY_ARM, 0.9)) < 0.05,
		"in the open the swung camera matches rest_offset (%s / %s)" % [str(down.snappedf(0.01)), str(up.snappedf(0.01))])
	_check(me.camera.cull_mask & HandsFP.HANDS_LAYER == 0, "the first-person hands and held stack are hidden")
	_check(me.body_visual.visible, "the carrier's own body shows")
	var flash_off: float = me.flashlight.global_position.distance_to(me.head.global_transform * CarryCam.FLASH_OFFSET)
	var flash_dir: float = (-me.flashlight.global_transform.basis.z).dot(-me.camera.global_transform.basis.z)
	_check(flash_off < 0.02 and flash_dir > 0.999, "the torch stays at the head and points where the camera looks (%.3f m, dot %.4f)" % [flash_off, flash_dir])

	# Aim at the patient table through the real ray from the shoulder.
	var top := pt + Vector3(0, Game.OR_TABLE_TOP, 0)
	_stand_facing(pt + pside * 1.6, top + Vector3(0, 0.25, 0))
	await _aim_camera(top + Vector3(0, 0.25, 0))
	await _frames(4)
	_check(me.aim_id == pid and me.aim_prompt.begins_with("Place "), "over the shoulder the aim ray finds the free patient table ('%s' / '%s')" % [me.aim_id, me.aim_prompt])
	# Teleport: the camera keeps its offset at once (no easing across the world).
	var before: Vector3 = cc.offset
	me.teleport(me.global_position + Vector3(6.0, 0, 0))
	await _frames(1)
	var rel: Vector3 = me.head.global_transform.affine_inverse() * me.camera.global_position
	_check(rel.distance_to(before) < 0.25, "a teleport keeps the shoulder offset on the very next frame (%s vs %s)" % [str(rel.snappedf(0.01)), str(before.snappedf(0.01))])
	_stand_facing(pt + pside * 1.6, top + Vector3(0, 0.25, 0))
	await _aim_camera(top + Vector3(0, 0.25, 0))
	await _frames(4)
	# An interactable between the camera and the head does not count.
	var cam_pos: Vector3 = me.camera.global_position
	var head_pos: Vector3 = me.head.global_position
	var blocker := game._spawn_item("gauze", 2, Transform3D(Basis(), cam_pos.lerp(head_pos, 0.5) + (-me.camera.global_transform.basis.z) * 0.0), WorldItem.State.LOOSE)
	blocker.freeze = true
	await _frames(3)
	var ray_mid: Vector3 = cam_pos + (-me.camera.global_transform.basis.z) * (head_pos - cam_pos).dot(-me.camera.global_transform.basis.z) * 0.5
	blocker.global_position = ray_mid
	await _frames(3)
	_check(me.aim_id == pid, "a stack between the camera and the head is ignored (aim '%s', prompt '%s', item at %s, start %s)" % [me.aim_id, me.aim_prompt, str(blocker.global_position.snappedf(0.01)), str((me.carry_cam.aim_segment()[0] as Vector3).snappedf(0.01))])
	game.world_items.erase(blocker.item_id)
	blocker.queue_free()
	await _frames(2)
	me.bot_press += 1
	await _frames(3)
	_check(dummy.on_table and me.carrying == 0 and int(game.player_table.get("index", -1)) == pi, "E from the shoulder lays the carried player on the patient table")
	await _seconds(0.5)
	_check(not cc.active and me.fx.position == Vector3.ZERO and me.camera.cull_mask & HandsFP.HANDS_LAYER != 0 and not me.body_visual.visible,
		"put down: back to first person, hands back, body hidden (blend %.2f)" % cc.blend)
	game.kill_player(dummy, "test")
	game.dev.remove_bot(did)
	await _frames(2)

	# ---- drag a sedated Walk-In and strap it down
	var ti: int = game.free_patient_table()
	var tpos: Vector3 = game.table_position(ti)
	var tside: Vector3 = Basis(Vector3.UP, game.table_yaw_of(ti)) * Vector3(0, 0, 1)
	var m = game._add_monster("walk_in", game._floor_at(tpos + tside * 3.2))
	await _frames(3)
	m.sedate(75.0)
	await _frames(2)
	game.combat.start_drag(me, m)
	await _seconds(0.5)
	me.bot_pitch = 0.0
	await _frames(3)
	var drag_off := _yaw_offset()
	_check(game.combat.dragging(me) == m.monster_id and cc.active and drag_off.z > 1.2 and drag_off.x > 0.4 and drag_off.y > 0.4,
		"dragging: the camera is over the right shoulder, higher and further back (%s from the eye)" % str(drag_off.snappedf(0.01)))
	_stand_facing(tpos + tside * 1.5, tpos + Vector3(0, 0.9, 0))
	await _aim_camera(tpos + Vector3(0, 0.9, 0))
	await _frames(4)
	var tid: String = game.table_interact_id(ti)
	_check(me.aim_id == tid and me.aim_prompt.begins_with("Strap the Walk-In"), "over the shoulder the aim ray finds the patient table ('%s' / '%s')" % [me.aim_id, me.aim_prompt])
	me.bot_press += 1
	await _frames(3)
	_check(bool(game.case_on_table(ti).get("monster", false)) and game.combat.dragging(me) < 0, "E from the shoulder straps the monster to the table")
	await _seconds(0.5)
	_check(not cc.active, "strapped: back to first person")

	# ---- a wall pulls the camera in; the setting turns it off
	var did2: int = game.dev.spawn_bot("dummy")
	var d2: Player = game.players[did2]
	await _frames(3)
	d2.teleport(me.global_position + Vector3(0, 0, -1.0))
	game.down_player(d2, "test")
	await _frames(2)
	game.start_carry(me, d2)
	await _seconds(0.6)
	var open_len: float = cc.arm_length
	var wall := _wall_spot()
	if wall.is_empty():
		_check(false, "found no wall to back into")
	else:
		me.teleport(wall.pos)
		me.bot_yaw = wall.yaw
		me.bot_pitch = 0.0
		await _frames(3)
		_check(cc.arm_length < open_len - 0.3, "backed against a wall the camera pulls in toward the head (%.2f m, open %.2f m)" % [cc.arm_length, open_len])
		var cam: Vector3 = me.camera.global_position
		var space := me.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(me.head.global_position, cam)
		q.collision_mask = C.L_WORLD
		_check(space.intersect_ray(q).is_empty(), "and it never ends up behind the wall")
		await _seconds(1.5)
		_check(cc.arm_length < open_len - 0.3, "it stays pulled in while the wall is there")
	Settings.set_value("carry_camera", "first_person")
	await _seconds(0.5)
	_check(not cc.active and me.carrying == did2 and me.fx.position == Vector3.ZERO, "setting 'first_person': carrying stays in first person")
	Settings.set_value("carry_camera", "shoulder")
	await _seconds(0.5)
	_check(cc.active, "setting back to 'shoulder': over the shoulder again")
	game.damage_player(me, 1, "monster:test")
	await _seconds(0.5)
	_check(me.carrying == 0 and not cc.active, "getting hit drops the body and the camera comes back")


## Somewhere the player can stand with a wall about 0.6 m behind them: [pos, yaw] or {}.
func _wall_spot() -> Dictionary:
	var space := me.get_world_3d().direct_space_state
	var base: Vector3 = game.table_pos()
	for r in [4.0, 6.0, 8.0, 10.0]:
		for i in 16:
			var a := TAU * i / 16.0
			var dir := Vector3(cos(a), 0, sin(a))
			var from := base + Vector3.UP * 1.5
			var q := PhysicsRayQueryParameters3D.create(from, from + dir * r)
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var spot: Vector3 = hit.position - dir * 0.75
			if game._floor_at(Vector3(spot.x, base.y, spot.z)).y > base.y + 0.3:
				continue   # standing on something waist-high, not backed against a wall
			var high := Vector3(spot.x, base.y + 2.1, spot.z)
			var q2 := PhysicsRayQueryParameters3D.create(high, high + dir * 1.2)
			q2.collision_mask = C.L_WORLD
			if space.intersect_ray(q2).is_empty():
				continue   # not a wall up at camera height
			# Face away from the wall: the camera goes back into it.
			return {"pos": game._floor_at(Vector3(spot.x, base.y, spot.z)), "yaw": atan2(dir.x, dir.z)}
	return {}


## The camera's offset from the eye in the player's yaw frame (x right, y up, z back).
func _yaw_offset() -> Vector3:
	return Basis(Vector3.UP, me.global_rotation.y).inverse() * (me.camera.global_position - me.head.global_position)


func _stand_facing(pos: Vector3, at: Vector3) -> void:
	me.teleport(game._floor_at(pos))
	var eye := me.global_position + Vector3.UP * C.EYE_H
	var d := at - eye
	me.bot_yaw = atan2(-d.x, -d.z)
	me.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)
	me.bot_move = Vector2.ZERO
	me.bot_aim_id = ""


func _check(ok: bool, what: String) -> void:
	print("[carrycamtest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[carrycamtest] ------------------------------------------")
	print("[carrycamtest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
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


## Turn so the CAMERA's crosshair (over the shoulder, beside the head) lies on `at`, the way a
## player lines the crosshair up. A few rounds: the camera orbits the head as the yaw changes.
func _aim_camera(at: Vector3) -> void:
	for i in 6:
		await _frames(2)
		var cam: Vector3 = me.camera.global_position
		var d := at - cam
		var yaw_err := wrapf(atan2(-d.x, -d.z) - atan2(-(-me.camera.global_transform.basis.z).x, -(-me.camera.global_transform.basis.z).z), -PI, PI)
		me.bot_yaw += yaw_err
		var fwd: Vector3 = -me.camera.global_transform.basis.z
		var pitch_err := atan2(d.y, Vector2(d.x, d.z).length()) - atan2(fwd.y, Vector2(fwd.x, fwd.z).length())
		me.bot_pitch = clampf(me.bot_pitch + pitch_err, -1.2, 1.2)
	await _frames(3)
