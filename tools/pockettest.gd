extends Node
## POCKETS: headless check of pocket spaces in the real game, for both the Factory and the Restaurant.
##
##   godot --headless --fixed-fps 60 --path . tools/pockettest.tscn [-- --seed=N] [--only=factory]
##
## For each space (forced on the run's hospital):
##   - the pocket, its seams and links exist; entrances lead to at least two different wings; a
##     navigation path from the neutral area reaches the pocket through a seam link
##   - through every entrance, both directions, a bot walks the stub carrying a downed bot over its
##     shoulder while a second bot walks right behind it holding supplies: each crosses once, keeps its
##     offset from the seam, its speed and heading; the carried body stays on the shoulder; the
##     supplies stay in hand; everyone ends up on the far side
##   - a Night Nurse follows a player from the hospital into the pocket through a seam
##   - a Discharged in the pocket hears a player on the hospital side of a seam and comes through
##   - a loose item dropped past a seam lands in the other copy
##   - noise near a seam is heard on the other side; nothing past a seam is reachable
##
## Exits 0 when every check passes.

const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")
const PlayerScript := preload("res://scripts/player.gd")

var main: Node3D
var game: Game
var bot: Player
var seed_value := 4242
var only := ""
var _failures: Array = []
var _checks := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"seed": seed_value = int(kv[1])
			"only": only = kv[1]
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Bot")
	for kind in ["factory", "restaurant"]:
		if only != "" and only != kind:
			continue
		await _run_space(kind)
	Plan.force_kind = ""
	_finish()


func _run_space(kind: String) -> void:
	_say("==== %s (seed %d)" % [kind, seed_value])
	Plan.force_kind = kind
	game.start_session(seed_value)
	await _frames(3)
	while game.get_parent().has_node("WarmupCover"):
		await _frames(1)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	game.begin_shift()
	game._clear_monsters()
	await _frames(20)
	var pk = game.pockets
	_check(pk.active() and String(pk.pocket.kind) == kind, "%s: the pocket is built" % kind)
	if not pk.active():
		return
	var wings := {}
	for s in pk.seams:
		wings[s.wing] = true
	_check(pk.seams.size() >= 2 and wings.size() >= 2, "%s: %d entrances into %d different wings" % [kind, pk.seams.size(), wings.size()])
	_check(game.level_info.get("pockets", {}).get("seams", []).size() == pk.seams.size(), "%s: level_info.pockets lists every seam" % kind)
	# Seams line up: the same stub-local point through both frames and the transform agree.
	for s in pk.seams:
		var worst := 0.0
		for p in [Vector2(0.5, 0.5), Vector2(Stub.seam_s(s.w), float(s.d) - 1.0), Vector2(float(s.w) - 0.5, 0.5)]:
			var h := Stub.local_point(s.xh, p.x, p.y, 1.0)
			var q := Stub.local_point(s.xp, p.x, p.y, 1.0)
			worst = maxf(worst, ((s.t as Transform3D) * h).distance_to(q))
			worst = maxf(worst, ((s.t_inv as Transform3D) * q).distance_to(h))
		_check(worst < 0.001, "%s seam %d: both copies line up (%.5f m)" % [kind, int(s.id), worst])
	await _check_nav(kind, pk)
	# Helpers: a downed bot to carry and a second bot holding supplies.
	var carried := _make_bot(-101, "Carried")
	var follower := _make_bot(-102, "Follower")
	await _frames(2)
	for s in pk.seams:
		for into in [true, false]:
			await _walk_through(kind, s, into, carried, follower)
	_remove_bot(carried)
	_remove_bot(follower)
	await _frames(2)
	await _nurse_follows(kind, pk)
	await _discharged_hears(kind, pk)
	await _item_crosses(kind, pk)
	game._clear_monsters()


# =========================================================================
# walking through
# =========================================================================

func _walk_through(kind: String, s: Dictionary, into: bool, carried: Player, follower: Player) -> void:
	var pk = game.pockets
	var tag := "%s seam %d %s" % [kind, int(s.id), "into the pocket" if into else "back to the hospital"]
	var line: Array = Stub.centre_line(s.w, s.d)
	if into:
		line = [Vector2(1.0, -2.2)] + line + [Vector2(float(s.w) - 1.0, -3.6)]
	else:
		line.reverse()
		line = [Vector2(float(s.w) - 1.0, -4.2)] + line + [Vector2(1.0, -2.0)]
	var start_frame: Transform3D = s.xh if into else s.xp
	var p0: Vector2 = line[0]
	var p1: Vector2 = line[1]
	# The carrier at the start, facing along the path; the downed bot on its shoulder; the follower
	# a moment behind with gauze in hand.
	_revive(carried)
	_revive(follower)
	bot.slots = PlayerScript.empty_slots()
	var start := Stub.local_point(start_frame, p0.x, p0.y)
	var dir := (Stub.local_point(start_frame, p1.x, p1.y) - start).normalized()
	bot.teleport(start)
	follower.teleport(start)
	carried.teleport(start + Vector3(0.6, 0, 0.6))
	await _frames(2)
	game.down_player(carried, "test")
	await _frames(2)
	game.start_carry(bot, carried)
	follower.slots = PlayerScript.empty_slots()
	follower.take_into("gauze", 3)
	follower.selected = 0
	await _frames(2)
	_check(bot.carrying == carried.peer_id and carried.carried_by == bot.peer_id, "%s: carrying the downed bot" % tag)
	var crossings_before := _count_crossings("player", bot.peer_id)
	var follower_before := _count_crossings("player", follower.peer_id)
	var walkers := [{"p": bot, "i": 1, "wait": 0.0}, {"p": follower, "i": 1, "wait": 0.45}]
	var t0 := game.world_time
	var jump_worst := 0.0
	var carry_worst := 0.0
	var speed_break := 0.0
	var prev := {}
	var done := false
	while game.world_time - t0 < 40.0 and not done:
		done = true
		for w in walkers:
			var p: Player = w.p
			var i: int = w.i
			if game.world_time - t0 < float(w.wait):
				done = false
				continue
			if i >= line.size():
				p.bot_move = Vector2.ZERO
				continue
			done = false
			var frame: Transform3D = s.xp if pk.in_pocket(p.global_position) else s.xh
			var wp: Vector2 = line[i]
			var target := Stub.local_point(frame, wp.x, wp.y)
			var to := target - p.global_position
			to.y = 0.0
			if to.length() < 0.35:
				w.i = i + 1
				continue
			p.bot_yaw = atan2(-to.x, -to.z)
			p.bot_move = Vector2(0, -1)
			# Continuity in stub-local terms across the move: position and velocity.
			var l := Stub.to_local(frame, p.global_position)
			var lv := frame.basis.inverse() * p.velocity
			var key := p.peer_id
			if prev.has(key):
				var pl: Vector3 = prev[key][0]
				var plv: Vector3 = prev[key][1]
				jump_worst = maxf(jump_worst, Vector2(l.x - pl.x, l.z - pl.z).length() * Stub.T)
				if plv.length() > 1.0 and lv.length() > 1.0:
					speed_break = maxf(speed_break, (lv - plv).length())
			prev[key] = [l, lv]
		if bot.carrying == carried.peer_id:
			carry_worst = maxf(carry_worst, carried.global_position.distance_to(bot.global_position))
		await _frames(1)
	bot.bot_move = Vector2.ZERO
	follower.bot_move = Vector2.ZERO
	if not done:
		for w in walkers:
			var p: Player = w.p
			var fr: Transform3D = s.xp if pk.in_pocket(p.global_position) else s.xh
			_say("     %s stopped at waypoint %d/%d, stub-local %s, in pocket %s" % [p.player_name, int(w.i), line.size(), str(Stub.to_local(fr, p.global_position)), str(pk.in_pocket(p.global_position))])
	_check(done,"%s: both walkers reached the far end (%.1f s)" % [tag, game.world_time - t0])
	var want_pocket := into
	_check(pk.in_pocket(bot.global_position) == want_pocket and pk.in_pocket(follower.global_position) == want_pocket, "%s: carrier and follower end on the far side" % tag)
	_check(_count_crossings("player", bot.peer_id) - crossings_before == 1, "%s: the carrier crossed exactly once (%d)" % [tag, _count_crossings("player", bot.peer_id) - crossings_before])
	_check(_count_crossings("player", follower.peer_id) - follower_before == 1, "%s: the follower crossed exactly once" % tag)
	_check(jump_worst < 0.25, "%s: nobody jumped in stub-local terms (worst step %.3f m)" % [tag, jump_worst])
	_check(speed_break < 1.5, "%s: velocity carried across (worst change %.2f m/s in one frame)" % [tag, speed_break])
	_check(bot.carrying == carried.peer_id and carry_worst < 1.8, "%s: the carried bot stayed on the shoulder (worst %.2f m)" % [tag, carry_worst])
	_check(pk.in_pocket(carried.global_position) == want_pocket, "%s: the carried bot is on the far side too" % tag)
	_check(follower.holding("gauze") and int(follower.slots[follower.slot_for("gauze")].count) == 3, "%s: the follower still holds its gauze" % tag)
	_check(pk.phantom_at(bot.global_position).is_empty() and pk.phantom_at(follower.global_position).is_empty(), "%s: nobody stands in a stub's unwalked half" % tag)
	game.drop_carried(bot)
	await _frames(2)


func _count_crossings(what: String, id: int) -> int:
	var n := 0
	for c in game.pockets.crossings:
		if c.what == what and int(c.id) == id:
			n += 1
	return n


func _make_bot(id: int, nm: String) -> Player:
	var p = PlayerScript.new_player(id, nm, false)
	p.is_bot = true
	p.bot_active = true
	p.bot_invulnerable = true
	p.set_flashlight(false)
	game.players[id] = p
	game.get_node("Entities").add_child(p)
	return p


func _remove_bot(p: Player) -> void:
	if p.carried_by != 0:
		var q = game.players.get(p.carried_by)
		if q != null:
			game.drop_carried(q)
	game.players.erase(p.peer_id)
	p.queue_free()


func _revive(p: Player) -> void:
	if p.carried_by != 0:
		var q = game.players.get(p.carried_by)
		if q != null:
			game.drop_carried(q)
	p.revive_full()
	p.refresh_downed_visuals()


# =========================================================================
# navigation, monsters, items, noise
# =========================================================================

func _check_nav(kind: String, pk) -> void:
	var map := get_viewport().world_3d.navigation_map
	for i in 120:
		if NavigationServer3D.map_get_iteration_id(map) > 0:
			break
		await _frames(1)
	await _frames(4)
	var start: Vector3 = game.spawn_points()[0]
	var goal: Vector3 = pk.pocket.spawn
	var path := NavigationServer3D.map_get_path(map, start, NavigationServer3D.map_get_closest_point(map, goal), true)
	var jump := 0.0
	for i in range(1, path.size()):
		jump = maxf(jump, path[i - 1].distance_to(path[i]))
	_check(path.size() >= 2 and path[path.size() - 1].distance_to(goal) < 3.0 and jump > 200.0,
			"%s: a navigation path from the neutral area into the pocket goes through a seam link (ends %.1f m off, longest step %.0f m)" % [kind, path[path.size() - 1].distance_to(goal) if path.size() > 0 else -1.0, jump])
	# Nothing past a seam is on the navigation mesh.
	for s in pk.seams:
		var ph := Stub.local_point(s.xh, float(s.w) - 1.0, 1.0)
		var pp := Stub.local_point(s.xp, 1.0, 1.0)
		var qh := NavigationServer3D.map_get_closest_point(map, ph)
		var qp := NavigationServer3D.map_get_closest_point(map, pp)
		_check(qh.distance_to(ph) > 1.0 and qp.distance_to(pp) > 1.0, "%s seam %d: the unwalked halves are off the navigation mesh (%.1f, %.1f m)" % [kind, int(s.id), qh.distance_to(ph), qp.distance_to(pp)])
		# Through this seam both ways: from its hospital leg 1 to its pocket leg 3 and back.
		var a := NavigationServer3D.map_get_closest_point(map, Stub.local_point(s.xh, 1.0, 1.0))
		var b := NavigationServer3D.map_get_closest_point(map, Stub.local_point(s.xp, float(s.w) - 1.0, 1.0))
		for pair in [[a, b], [b, a]]:
			var pth := NavigationServer3D.map_get_path(map, pair[0], pair[1], true)
			var longest := 0.0
			var walked := 0.0
			for i in range(1, pth.size()):
				var dd: float = pth[i - 1].distance_to(pth[i])
				longest = maxf(longest, dd)
				if dd < 100.0:
					walked += dd
			_check(pth.size() >= 2 and pth[pth.size() - 1].distance_to(pair[1]) < 0.5 and longest > 100.0 and walked < float(s.w + s.d * 2) * 1.5 + 4.0,
					"%s seam %d: a path straight through its link (%d points, walks %.1f m, link %s)" % [kind, int(s.id), pth.size(), walked, str([NavigationServer3D.map_get_closest_point(map, s.link_h).distance_to(s.link_h), NavigationServer3D.map_get_closest_point(map, s.link_p).distance_to(s.link_p)])])


func _nurse_follows(kind: String, pk) -> void:
	var s: Dictionary = pk.seams[0]
	var map := get_viewport().world_3d.navigation_map
	var hall := NavigationServer3D.map_get_closest_point(map, Stub.local_point(s.xh, 1.0, -4.5))
	var stand := Stub.local_point(s.xp, float(s.w) - 1.0, -6.0)
	bot.teleport(stand)
	var away := stand - Stub.local_point(s.xp, float(s.w) - 1.0, -1.0)
	bot.bot_yaw = atan2(-away.x, -away.z)
	bot.set_flashlight(false)
	bot.bot_move = Vector2.ZERO
	var nurse = game._add_monster("night_nurse", hall)
	await _frames(2)
	var before := _count_crossings("monster", int(nurse.monster_id))
	var t0 := game.world_time
	while game.world_time - t0 < 60.0:
		if pk.in_pocket(nurse.global_position) and nurse.global_position.distance_to(bot.global_position) < 4.0:
			break
		await _frames(1)
	_check(pk.in_pocket(nurse.global_position), "%s: the Night Nurse followed the player through the seam (%.1f s, %.1f m away)" % [kind, game.world_time - t0, nurse.global_position.distance_to(bot.global_position)])
	_check(_count_crossings("monster", int(nurse.monster_id)) - before == 1, "%s: she crossed exactly once" % kind)
	bot.set_flashlight(true)
	game._clear_monsters()
	await _frames(2)


func _discharged_hears(kind: String, pk) -> void:
	var s: Dictionary = pk.seams[pk.seams.size() - 1]
	var back := float(s.d) - 1.0
	var listener := Stub.local_point(s.xp, float(s.w) - 1.0, back)
	var speaker := Stub.local_point(s.xh, 2.6, back)
	# Mirrors: a noise at the speaker is also heard in the pocket copy, and that point means the speaker's side.
	var mirrors: Array = pk.mirror_noise(speaker, 0.8)
	var ok := false
	for m in mirrors:
		if pk.in_pocket(m) and (pk.real_point(m) as Vector3).distance_to(Stub.local_point(s.xh, 2.6, back)) < 2.5:
			ok = true
	_check(ok, "%s: a noise near a seam is mirrored into the other copy (%d mirrors)" % [kind, mirrors.size()])
	bot.teleport(speaker)
	bot.bot_move = Vector2.ZERO
	var d = game._add_monster("discharged", listener)
	await _frames(2)
	var before := _count_crossings("monster", int(d.monster_id))
	var t0 := game.world_time
	var last_noise := -10.0
	while game.world_time - t0 < 40.0:
		if game.world_time - last_noise > 1.2:
			last_noise = game.world_time
			game.emit_noise(bot.global_position, 0.8, "test")
		if not pk.in_pocket(d.global_position) and d.global_position.distance_to(bot.global_position) < 3.0:
			break
		await _frames(1)
	if pk.in_pocket(d.global_position):
		_say("     Discharged mode %d at stub-local %s, last heard %s" % [int(d.mode), str(Stub.to_local(s.xp, d.global_position)), str(d.brain.last_heard)])
	_check(not pk.in_pocket(d.global_position), "%s: the Discharged heard the player through the seam and came through (%.1f s)" % [kind, game.world_time - t0])
	_check(_count_crossings("monster", int(d.monster_id)) - before == 1, "%s: the Discharged crossed exactly once" % kind)
	game._clear_monsters()
	await _frames(2)


func _item_crosses(kind: String, pk) -> void:
	var s: Dictionary = pk.seams[0]
	var drop := Stub.local_point(s.xh, Stub.seam_s(s.w) + 0.35, float(s.d) - 1.0, 0.6)
	var it = game._spawn_item("gauze", 2, Transform3D(Basis(), drop), WorldItem.State.LOOSE)
	await _frames(30)
	_check(is_instance_valid(it) and pk.in_pocket(it.global_position), "%s: an item dropped past the seam lands in the pocket copy" % kind)
	if is_instance_valid(it):
		var l := Stub.to_local(s.xp, it.global_position)
		_check(l.x > Stub.seam_s(s.w) - 0.2 and l.x < float(s.w) and l.z > 0.0 and l.z < float(s.d), "%s: ... at the same spot of the stub (%.2f, %.2f)" % [kind, l.x, l.z])
		game.world_items.erase(it.item_id)
		it.queue_free()


# =========================================================================

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		_say("ok   " + what)
	else:
		_say("FAIL " + what)
		_failures.append(what)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _say(line: String) -> void:
	print("[pockettest] " + line)


func _finish() -> void:
	if _failures.is_empty():
		_say("PASS: %d checks" % _checks)
		get_tree().quit(0)
	else:
		_say("FAILED %d of %d checks" % [_failures.size(), _checks])
		for f in _failures:
			_say("  " + f)
		get_tree().quit(1)
