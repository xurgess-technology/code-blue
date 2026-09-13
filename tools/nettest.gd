extends Node
## Real multi-process multiplayer tests over ENet on localhost. One process per machine:
## a host and up to three clients, each running the real main scene with bot-driven players.
## Normally started by the runner, which runs every scenario with one command:
##
##   godot --headless --path . --script tools/nettest_run.gd [-- --only=names,deliver] [--lag=120]
##
## One process by hand (what the runner launches):
##
##   godot --headless --fixed-fps 60 --path . tools/nettest.tscn -- --role=host --scenario=deliver --clients=2 [--port=7790] [--seed=N]
##   godot --headless --fixed-fps 60 --path . tools/nettest.tscn -- --role=client --index=1 --scenario=deliver --clients=2 [--net-lag=120 --net-jitter=30 --net-loss=0.05]
##
## Scenarios (see tools/nettest_run.gd for the process layout of each):
##   names            host + 3 clients: everyone's name arrives intact on every machine
##   deliver          host + 2 clients: each client fetches a different supply and puts it on the shelf
##   surgery          host + 2 clients: client 1 operates a whole step, client 2 watches, the host sees it finish
##   leave_items      client 1 leaves holding supplies: they drop where it stood, nothing smashes
##   leave_operating  client 1 is killed mid-step: the step pauses, client 2 resumes from the saved progress
##   late_join        client 2 joins mid-shift: spectates, then spawns when the next shift's lobby starts
##   host_quit        the host leaves: clients return to the menu with a message
##   host_kill        the host process dies without saying goodbye: same, through the ENet timeout
##   full_shift       host + N clients play a whole shift to the win screen (the runner adds lag)
##
## Every process exits 0 on success and 1 on failure, printing "PASS:" or "FAIL:" and why.
## Coordination between processes travels over the game's own connection (the _msg RPC).
## Timeouts are wall-clock, so the test behaves the same with or without --fixed-fps.
## `--stats` prints bandwidth: bytes each process sent per game second while the shift ran.

const NAMES := ["Host", "Álvaro", "Bea O'Neil", "Surgeon Chris"]

var role := "host"
var scenario := "deliver"
var index := 0          # 0 host, 1..3 clients
var clients := 2
var port := 7790
var seed_value := 4242
var timeout_s := 150.0
var stats := false

var main: Node3D
var game: Game
var _done := false
var _t0 := 0.0
var _inbox: Array = []
var _press_at_ms := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"role": role = v
			"scenario": scenario = v
			"index": index = int(v)
			"clients": clients = int(v)
			"port": port = int(v)
			"seed": seed_value = int(v)
			"timeout": timeout_s = float(v)
			"stats": stats = true
	if role == "host":
		index = 0
	_t0 = _wall()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	game.net_measure = stats
	main.menu.hide_menu()
	_say("started scenario=%s port=%d clients=%d lag=%dms loss=%.2f" % [scenario, port, clients, Net.sim_lag_ms, Net.sim_loss])
	if role == "host":
		var err := Net.host(NAMES[0], port)
		if err != "":
			_end(false, "host failed: " + err)
			return
		game.start_session(seed_value)
	else:
		# Exactly what the menu does, so the join-name path is the real one.
		main._start_join(NAMES[index], "127.0.0.1:%d" % port)
	_run()


func _process(_delta: float) -> void:
	if not _done and _wall() - _t0 > timeout_s:
		_end(false, "timed out after %.0f s" % timeout_s)


func _physics_process(_delta: float) -> void:
	# Bots never die in these tests: the host keeps every surgeon invulnerable, including
	# remote ones (whose own bot flag only exists on their machine).
	if role == "host" and game != null:
		for p in game.players.values():
			p.invuln = 9.0


func _run() -> void:
	match scenario:
		"names": await _sc_names()
		"deliver": await _sc_deliver()
		"surgery": await _sc_surgery()
		"leave_items": await _sc_leave_items()
		"leave_operating": await _sc_leave_operating()
		"late_join": await _sc_late_join()
		"host_quit", "host_kill": await _sc_host_quit()
		"full_shift": await _sc_full_shift()
		_: _end(false, "unknown scenario " + scenario)


# =========================================================================
# scenarios
# =========================================================================

func _sc_names():
	if not await _until(func(): return Net.names.size() == clients + 1 and game.players.size() == clients + 1, 60.0, "everyone in the roster"):
		return
	await _frames(30)
	var want := {}
	for i in clients + 1:
		want[NAMES[i]] = true
	for id in Net.names.keys():
		var nm: String = Net.names[id]
		if not want.has(nm):
			return _end(false, "unexpected name '%s' for peer %d (roster %s)" % [nm, id, str(Net.names)])
		want.erase(nm)
		var p = game.players.get(id)
		if p == null or p.player_name != nm:
			return _end(false, "player node for %d is named '%s', roster says '%s'" % [id, p.player_name if p else "?", nm])
	if not want.is_empty():
		return _end(false, "missing names %s (roster %s)" % [str(want.keys()), str(Net.names)])
	if Net.names.get(Net.my_id(), "") != NAMES[index]:
		return _end(false, "my own name is '%s', expected '%s'" % [Net.names.get(Net.my_id(), ""), NAMES[index]])
	_say("roster %s" % str(Net.names))
	await _finish_together("all %d names correct" % (clients + 1))


func _sc_deliver():
	if role == "host":
		if not await _start_shift_when_full():
			return
		if not await _until(func(): return _count_msgs("delivered") >= clients, 90.0, "clients to deliver"):
			return
		for m in _msgs("delivered"):
			var kind: String = m.data.kind
			if game.shelf_count(kind) < int(m.data.count):
				return _end(false, "client says it delivered %s but the host shelf is %s" % [kind, str(game.shelf)])
		_say("host shelf %s" % str(game.shelf))
		await _finish_together("both deliveries on the host's shelf")
		return
	if not await _wait_shift_as_client():
		return
	var need := Procedures.requirements(game.case.ailment_id).keys()
	need.sort()
	var kind: String = need[(index - 1) % need.size()]
	_say("fetching %s" % kind)
	if not await _fetch(kind):
		return
	var count: int = _me().slots[_slot_of(kind)].count
	if not await _deliver(kind):
		return
	if not await _until(func(): return game.shelf_count(kind) >= count, 20.0, "own delivery in the snapshot"):
		return
	_send("delivered", {"kind": kind, "count": count})
	await _finish_together("delivered %d %s, visible on my shelf %s" % [count, kind, str(game.shelf)])


func _sc_surgery():
	if role == "host":
		if not await _start_shift_when_full():
			return
		_stock_shelf()
		var op_id: int = _peer_of(1)
		_send("operate", {"peer": op_id})
		var seen := {"op": false}
		var watch := func():
			if game.surgery.operator_id == op_id:
				seen.op = true
		if not await _do_until(watch, func(): return int(game.case.step_index) >= 1, 120.0, "the step to finish"):
			return
		if not seen.op:
			return _end(false, "the host never saw client %d operating" % op_id)
		if not game.case.flags.has("sedation"):
			return _end(false, "step finished without its result flags: %s" % str(game.case.flags))
		_say("step 0 done by %d, flags %s, vitals %.1f" % [op_id, str(game.case.flags), game.vitals])
		if not await _until(func(): return _count_msgs("watched") >= 1, 30.0, "the spectator's report"):
			return
		await _finish_together("client operated, spectator watched, host saw completion")
		return
	if not await _wait_shift_as_client():
		return
	if not await _until(func(): return _count_msgs("operate") > 0, 30.0, "operate order"):
		return
	var op_id: int = _msgs("operate")[0].data.peer
	if op_id == Net.my_id():
		if not await _begin_operating():
			return
		if not await _until(func(): return int(game.case.step_index) >= 1, 120.0, "my step to be accepted"):
			return
		await _finish_together("operated step 0 to completion")
	else:
		var st := {"states": {}, "op": false}
		var watch := func():
			if game.surgery.operator_id == op_id:
				st.op = true
			if game.surgery.mg != null:
				st.states[str(game.surgery.mg.net_state())] = true
		if not await _do_until(watch, func(): return int(game.case.step_index) >= 1, 120.0, "the operator to finish"):
			return
		if not st.op or st.states.size() < 5:
			return _end(false, "spectator saw operator=%s and only %d distinct tool states" % [str(st.op), st.states.size()])
		_send("watched", {"states": st.states.size()})
		await _finish_together("watched %d distinct tool states and the step completing" % st.states.size())


func _sc_leave_items():
	if role == "host":
		if not await _start_shift_when_full():
			return
		var leaver: int = _peer_of(1)
		var p = game.players[leaver]
		p.slots = [{"kind": "gauze", "count": 3}, {"kind": "anesthetic", "count": 2}]
		var before := {"gauze": game.supply_count("gauze"), "anesthetic": game.supply_count("anesthetic")}
		_send("leave", {"peer": leaver})
		if not await _until(func(): return _count_msgs("standing") > 0, 40.0, "the leaver to take position"):
			return
		var spot: Vector3 = _msgs("standing")[0].data.pos
		if not await _until(func(): return not game.players.has(leaver), 30.0, "the leaver to disconnect"):
			return
		await _frames(90)   # let the dropped stacks settle
		for kind in before.keys():
			if game.supply_count(kind) != int(before[kind]):
				return _end(false, "%s went from %d to %d: something broke or vanished" % [kind, before[kind], game.supply_count(kind)])
			var near := _items_near(kind, spot, 2.5)
			if near <= 0:
				return _end(false, "no %s within 2.5 m of where the client stood (%s)" % [kind, str(spot)])
		_send("check_drop", {"pos": spot})
		if not await _until(func(): return _count_msgs("drop_seen") >= clients - 1, 30.0, "the other client to see the drop"):
			return
		await _finish_together("the leaver's supplies lie where it stood, none broken")
		return
	if not await _wait_shift_as_client():
		return
	if not await _until(func(): return _count_msgs("leave") > 0, 30.0, "leave order"):
		return
	if _msgs("leave")[0].data.peer == Net.my_id():
		if not await _until(func(): return _me().holding("gauze") and _me().holding("anesthetic"), 20.0, "the host's supplies in my hands"):
			return
		var spot := game._floor_at(game.table_pos() + Vector3(0.0, 0.0, 3.0))
		_me().teleport(spot)
		await _wall_wait(1.5)
		_send("standing", {"pos": _me().global_position})
		await _wall_wait(0.5)
		_say("PASS: leaving with %s" % str(_me().slots))
		_done = true
		Net.leave()
		get_tree().quit(0)
		return
	if not await _until(func(): return _count_msgs("check_drop") > 0, 60.0, "drop check"):
		return
	var at: Vector3 = _msgs("check_drop")[0].data.pos
	if not await _until(func(): return _items_near("gauze", at, 2.5) > 0 and _items_near("anesthetic", at, 2.5) > 0, 20.0, "the dropped stacks in my world"):
		return
	_send("drop_seen", {})
	await _finish_together("I see the leaver's stacks on the floor")


func _sc_leave_operating():
	if role == "host":
		if not await _start_shift_when_full():
			return
		_stock_shelf()
		var first: int = _peer_of(1)
		var second: int = _peer_of(2)
		_send("operate", {"peer": first})
		if not await _until(func(): return game.surgery.operator_id == first, 60.0, "client 1 to operate"):
			return
		if not await _until(func(): return not game.players.has(first), 90.0, "client 1 to vanish"):
			return
		var saved: Dictionary = game.surgery._mg_state
		if game.surgery.operator_id != 0 or int(game.case.step_index) != 0 or float(saved.get("p", 0.0)) <= 0.0:
			return _end(false, "after the drop: operator=%d step=%d saved=%s" % [game.surgery.operator_id, game.case.step_index, str(saved)])
		_say("operator gone; step paused at progress %.2f" % float(saved.p))
		_send("resume", {"peer": second, "p": float(saved.p)})
		if not await _until(func(): return int(game.case.step_index) >= 1, 120.0, "client 2 to finish the step"):
			return
		await _finish_together("step paused on disconnect and was finished by client 2")
		return
	if not await _wait_shift_as_client():
		return
	if not await _until(func(): return _count_msgs("operate") > 0, 30.0, "operate order"):
		return
	if _msgs("operate")[0].data.peer == Net.my_id():
		if not await _begin_operating():
			return
		if not await _until(func(): return game.surgery.mg != null and game.surgery.mg.progress >= 0.5, 60.0, "half the step"):
			return
		_say("PASS: killing myself mid-step at progress %.2f" % game.surgery.mg.progress)
		_done = true
		OS.kill(OS.get_process_id())
		return
	if not await _until(func(): return _count_msgs("resume") > 0, 120.0, "resume order"):
		return
	var saved_p: float = _msgs("resume")[0].data.p
	var mine: float = game.surgery.mg.progress if game.surgery.mg != null else -1.0
	if mine < saved_p - 0.05:
		return _end(false, "my copy of the step is at %.2f, the host saved %.2f" % [mine, saved_p])
	if not await _begin_operating():
		return
	await _frames(2)
	if game.surgery.mg.progress < saved_p - 0.05:
		return _end(false, "resumed at %.2f instead of %.2f" % [game.surgery.mg.progress, saved_p])
	_say("resuming at %.2f (host saved %.2f)" % [game.surgery.mg.progress, saved_p])
	if not await _until(func(): return int(game.case.step_index) >= 1, 120.0, "my resumed step to finish"):
		return
	await _finish_together("resumed from %.2f and finished the step" % saved_p)


func _sc_late_join():
	if role == "host":
		# Start with client 1 only; the runner starts client 2 once it sees the marker.
		if not await _until(func(): return Net.names.size() >= 2 and game.players.size() >= 2, 60.0, "client 1"):
			return
		await _wall_wait(1.0)
		game.begin_shift()
		print("[marker] shift_started")
		if not await _until(func(): return Net.names.size() >= 3 and game.players.size() >= 3, 90.0, "the late joiner"):
			return
		var late: int = _peer_of(2)
		await _wall_wait(1.0)
		var lp = game.players[late]
		if lp.alive or game.alive_players().has(lp):
			return _end(false, "the late joiner is alive in the middle of the shift")
		if game._pod_prompt().contains(lp.player_name):
			return _end(false, "the Re-Gen Pod offers to revive the late joiner: %s" % game._pod_prompt())
		if not await _until(func(): return _count_msgs("spectating") > 0, 40.0, "the late joiner to spectate"):
			return
		game._end_shift(true, "Test: shift over.")
		if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 60.0, "the next lobby"):
			return
		await _wall_wait(1.0)
		if not lp.alive:
			return _end(false, "the late joiner is still not alive in the next lobby")
		if not await _until(func(): return _count_msgs("spawned") > 0, 40.0, "the late joiner to spawn"):
			return
		await _finish_together("late joiner spectated and spawned at the next shift")
		return
	if index == 1:
		if not await _wait_shift_as_client():
			return
		if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 150.0, "the next lobby"):
			return
		await _finish_together("saw the next lobby")
		return
	# The late joiner
	if not await _until(func(): return game.phase != Game.Phase.MENU and _me() != null and not game.level_info.is_empty(), 60.0, "the world"):
		return
	await _frames(20)
	if game.phase != Game.Phase.SHIFT:
		return _end(false, "expected to join mid-shift, phase is %d" % game.phase)
	var me := _me()
	if not await _until(func(): return not me.alive, 10.0, "being held out as a spectator"):
		return
	var view = game.viewed_player()
	if view == me or view == null:
		return _end(false, "not watching a teammate while waiting")
	_say("spectating %s during shift %d" % [view.player_name, game.shift])
	_send("spectating", {})
	if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 90.0, "the next shift"):
		return
	if not await _until(func(): return me.alive, 20.0, "spawning"):
		return
	var near_spawn := false
	for s in game.spawn_points():
		near_spawn = near_spawn or me.global_position.distance_to(s) < 1.5
	if not near_spawn:
		return _end(false, "spawned at %s, not at a spawn point" % str(me.global_position))
	_send("spawned", {})
	await _finish_together("spawned in the lobby of shift 2")


func _sc_host_quit():
	if role == "host":
		if not await _start_shift_when_full():
			return
		if not await _until(func(): return _count_msgs("in_shift") >= clients, 60.0, "clients in the shift"):
			return
		await _wall_wait(1.0)
		_done = true
		if scenario == "host_kill":
			print("[net:host] PASS: killing the host process")
			OS.kill(OS.get_process_id())
			return
		print("[net:host] PASS: walking out")
		Net.leave()
		await _wall_wait(0.5)
		get_tree().quit(0)
		return
	if not await _wait_shift_as_client():
		return
	_send("in_shift", {})
	if not await _until(func(): return game.phase == Game.Phase.MENU and main.menu.visible, 40.0, "the menu after the host left"):
		return
	var status: String = main.menu._status.text
	if not status.to_lower().contains("host"):
		return _end(false, "back at the menu but the message is '%s'" % status)
	if Net.active or not game.players.is_empty() or game.level != null:
		return _end(false, "session not torn down: active=%s players=%d" % [str(Net.active), game.players.size()])
	_end(true, "back at the menu: '%s'" % status)


func _sc_full_shift():
	if role == "host":
		if not await _until(func(): return Net.names.size() == clients + 1 and game.players.size() == clients + 1, 90.0, "all clients"):
			return
		_send("start", {})
	else:
		if not await _until(func(): return _count_msgs("start") > 0 and _me() != null, 90.0, "start"):
			return
	var me := _me()
	me.bot_active = true
	me.bot_invulnerable = true
	game.surgery.bot_skill = 1.0
	var st := {"target": -1, "shift_t": -1.0, "sent": 0, "recv": 0, "last_step": -1}
	var ok := await _do_until(func(): _shift_bot(st), func(): return game.phase == Game.Phase.WON or game.phase == Game.Phase.LOST, 900.0, "the shift to end")
	if not ok:
		return
	if game.phase == Game.Phase.LOST:
		return _end(false, "the shift was lost: %s" % game.message)
	if stats and st.shift_t >= 0.0:
		var secs: float = maxf(0.001, game.world_time - st.shift_t)
		var sent: int = Net.bytes_sent - int(st.sent)
		var recv: int = Net.bytes_received - int(st.recv)
		var per := float(sent) / secs / float(maxi(1, clients)) if role == "host" else float(sent) / secs
		print("[stats] %s sent=%d recv=%d game_s=%.1f sent_Bps=%.0f recv_Bps=%.0f %s=%.0f snapshot_payload_Bps=%.0f" % [
			_tag(), sent, recv, secs, sent / secs, recv / secs,
			"sent_per_client_Bps" if role == "host" else "upstream_Bps", per,
			float(game.net_payload_bytes - int(st.get("payload", 0))) / secs / float(maxi(1, clients)) if role == "host" else 0.0])
		if role == "host":
			var parts := []
			for k in game.net_section_bytes.keys():
				parts.append("%s=%.0f" % [k, float(game.net_section_bytes[k]) / secs / float(maxi(1, clients))])
			print("[stats] host snapshot payload by part, bytes/s per client: %s" % " ".join(parts))
	_me().bot_interact = false
	await _finish_together("shift %d won with vitals %.0f" % [game.shift, game.vitals])


## One frame of a simple co-op bot: clock in, bring what the shelf lacks, operate.
func _shift_bot(st: Dictionary) -> void:
	var me := _me()
	if me == null:
		return
	me.bot_interact = false
	if game.phase == Game.Phase.LOBBY:
		if index == mini(1, clients):   # one client clocks everyone in, as a player would
			_press_at(game.clock_pos(), "clock", true)
		return
	if game.phase != Game.Phase.SHIFT or game.case.is_empty():
		return
	if st.shift_t < 0.0:
		st.shift_t = game.world_time
		st.sent = Net.bytes_sent
		st.recv = Net.bytes_received
		st.payload = game.net_payload_bytes
		game.net_section_bytes = {}
		_say("shift began: %s/%s" % [game.case.patient_id, game.case.ailment_id])
	if int(game.case.step_index) != int(st.last_step):
		st.last_step = int(game.case.step_index)
		_say("step %d, vitals %.0f, shelf %s, operator %d" % [st.last_step, game.vitals, str(game.shelf), game.surgery.operator_id])
	if me.operating or game.surgery.is_local_operating():
		return
	var need := Procedures.remaining_requirements(game.case.ailment_id, int(game.case.step_index))
	var short := {}
	for kind in need.keys():
		var n: int = int(need[kind]) - game.shelf_count(kind)
		if n > 0:
			short[kind] = n
	for i in 2:
		var s: Dictionary = me.slots[i]
		if s.kind != "" and short.has(s.kind):
			me.selected = i
			_press_at(game.shelf_node.global_position, "shelf")
			return
		if s.kind != "" and not short.has(s.kind) and s.kind != "guide":
			me.selected = i
			me.drop_count += 1   # not needed any more
			return
	if short.is_empty():
		if game.surgery.operator_id == 0:
			_press_at(game.table_pos(), "table")
		return
	var kinds := short.keys()
	kinds.sort()
	var kind: String = kinds[index % kinds.size()]
	var it = game.world_items.get(int(st.target))
	if it == null or not is_instance_valid(it) or it.kind != kind:
		st.target = _nearest_item(kind)
		it = game.world_items.get(int(st.target))
	if it == null:
		return
	_approach_item(it)


# =========================================================================
# bot actions
# =========================================================================

func _me() -> Player:
	return game.local_player() as Player


func _wait_shift_as_client() -> bool:
	var ok := await _until(func(): return game.phase == Game.Phase.SHIFT and _me() != null and not game.case.is_empty() and game.world_items.size() > 0 and game.shelf_node != null, 90.0, "the shift")
	if ok:
		_me().bot_active = true
		_me().bot_invulnerable = true
		_say("in shift: case=%s/%s items=%d players=%d" % [game.case.patient_id, game.case.ailment_id, game.world_items.size(), game.players.size()])
	return ok


func _start_shift_when_full() -> bool:
	if not await _until(func(): return Net.names.size() == clients + 1 and game.players.size() == clients + 1, 90.0, "all %d clients" % clients):
		return false
	await _wall_wait(1.0)
	game.begin_shift()
	_say("shift begun: case=%s/%s items=%d monsters=%d" % [game.case.patient_id, game.case.ailment_id, game.world_items.size(), game.monsters.size()])
	return true


func _stock_shelf() -> void:
	var need := Procedures.requirements(game.case.ailment_id)
	for kind in need.keys():
		game.shelf[kind] = int(need[kind])
	game.shelf_node.show_stock(game.shelf)


func _fetch(kind: String) -> bool:
	var st := {"target": -1}
	var step := func():
		var it = game.world_items.get(int(st.target))
		if it == null or not is_instance_valid(it) or it.kind != kind:
			st.target = _nearest_item(kind)
			it = game.world_items.get(int(st.target))
		if it != null:
			_approach_item(it)
	return await _do_until(step, func(): return _me().holding(kind), 60.0, "picking up " + kind)


func _deliver(kind: String) -> bool:
	var step := func():
		var i := _slot_of(kind)
		if i >= 0:
			_me().selected = i
		_press_at(game.shelf_node.global_position, "shelf")
	return await _do_until(step, func(): return not _me().holding(kind), 40.0, "putting %s on the shelf" % kind)


## The peer id of the machine playing NAMES[i] (ENet peer ids are random).
func _peer_of(i: int) -> int:
	for id in Net.names.keys():
		if Net.names[id] == NAMES[i]:
			return id
	return -1


func _begin_operating() -> bool:
	game.surgery.bot_skill = 1.0
	var ok := await _do_until(func(): _press_at(game.table_pos(), "table"),
		func(): return game.surgery.is_local_operating(), 40.0, "the host to let me operate")
	if ok:
		_say("operating step %d" % int(game.case.step_index))
	return ok


func _approach_item(it: Node) -> void:
	if it.state == WorldItem.State.IN_CONTAINER:
		var ct := game.find_interactable(it.container_id)
		if ct != null and ct.has_method("is_open") and not ct.is_open():
			_press_at(ct.global_position, it.container_id)
			return
	_press_at(it.global_position, "it_%d" % it.item_id)


func _nearest_item(kind: String) -> int:
	var best := -1
	var best_d := INF
	var from := _me().global_position
	for it in game.world_items.values():
		if it.kind != kind:
			continue
		var d: float = it.global_position.distance_to(from)
		if d < best_d:
			best_d = d
			best = it.item_id
	return best


func _slot_of(kind: String) -> int:
	for i in 2:
		if _me().slots[i].kind == kind:
			return i
	return -1


func _items_near(kind: String, pos: Vector3, radius: float) -> int:
	var n := 0
	for it in game.world_items.values():
		if it.kind == kind and Vector2(it.global_position.x - pos.x, it.global_position.z - pos.z).length() <= radius:
			n += int(it.count)
	return n


## Stand within reach of a target (the client owns its position, so a teleport is a legal
## move), look at it, and press E at most once a wall-clock second (or hold it).
func _press_at(pos: Vector3, id: String, hold := false) -> void:
	var me := _me()
	var flat := Vector2(pos.x - me.global_position.x, pos.z - me.global_position.z)
	if flat.length() > 1.7:
		me.teleport(_stand_spot(pos))
	var to := pos - me.global_position
	me.bot_yaw = atan2(-to.x, -to.z)
	me.bot_move = Vector2.ZERO
	me.bot_aim_id = id
	if hold:
		me.bot_interact = me.aim_id == id
		return
	if me.aim_id == id and not me.aim_prompt.begins_with("!") and Time.get_ticks_msec() >= _press_at_ms:
		me.bot_press += 1
		_press_at_ms = Time.get_ticks_msec() + 1000


func _stand_spot(pos: Vector3) -> Vector3:
	var map := get_viewport().world_3d.navigation_map
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		var p := NavigationServer3D.map_get_closest_point(map, pos)
		if Vector2(p.x - pos.x, p.z - pos.z).length() < 1.6:
			return p
	var dir := _me().global_position - pos
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.BACK
	return game._floor_at(pos + dir * 1.1)


# =========================================================================
# coordination
# =========================================================================

@rpc("any_peer", "reliable", "call_remote")
func _msg(kind: String, data: Dictionary) -> void:
	_inbox.append({"from": multiplayer.get_remote_sender_id(), "kind": kind, "data": data})


func _send(kind: String, data: Dictionary) -> void:
	if Net.active:
		_msg.rpc(kind, data)


func _msgs(kind: String) -> Array:
	return _inbox.filter(func(m): return m.kind == kind)


func _count_msgs(kind: String) -> int:
	return _msgs(kind).size()


## Host: wait for every client's "ok", then tell them to exit. Client: say ok, wait for "done".
func _finish_together(why: String):
	if _done:
		return
	if role == "host":
		if not await _until(func(): return _count_msgs("ok") >= _live_clients() or _count_msgs("fail") > 0, 60.0, "clients to report"):
			return
		if _count_msgs("fail") > 0:
			return _end(false, "a client failed: %s" % str(_msgs("fail")[0].data))
		_send("done", {})
		await _wall_wait(1.0)
		_end(true, why)
	else:
		_send("ok", {"why": why})
		_say("ok: %s" % why)
		if not await _until(func(): return _count_msgs("done") > 0 or not Net.active, 60.0, "the host's done"):
			return
		_end(true, why)


func _live_clients() -> int:
	return Net.names.size() - 1


func _until(cond: Callable, seconds: float, what: String) -> bool:
	return await _do_until(func(): pass, cond, seconds, what)


func _do_until(step: Callable, cond: Callable, seconds: float, what: String) -> bool:
	var start := _wall()
	while not cond.call():
		if _done:
			return false
		if _wall() - start > seconds:
			_end(false, "timed out after %.0f s waiting for %s" % [seconds, what])
			return false
		step.call()
		await get_tree().physics_frame
	return not _done


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _wall_wait(seconds: float) -> void:
	var start := _wall()
	while _wall() - start < seconds:
		await get_tree().process_frame


func _wall() -> float:
	return Time.get_ticks_msec() / 1000.0


func _tag() -> String:
	return "host" if role == "host" else "c%d" % index


func _say(line: String) -> void:
	print("[net:%s] t=%.1f %s" % [_tag(), _wall() - _t0, line])


func _end(ok: bool, why: String) -> bool:
	if _done:
		return ok
	_done = true
	_say(("PASS: " if ok else "FAIL: ") + why)
	if not ok and role != "host" and Net.active:
		_send("fail", {"who": _tag(), "why": why})
	# A moment for the last reliable packets to leave, in wall-clock time.
	get_tree().create_timer(0.3, true, false, true).timeout.connect(func():
		Net.leave()
		get_tree().quit(0 if ok else 1))
	return ok
