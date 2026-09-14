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
##   full_shift       host + N clients play a whole shift of the loop: clock in, grace, answer the
##                    phone, paramedics deliver, fetch, operate, clock out and get paid (the runner
##                    adds lag)
##   economy          client 1 picks up loot, sells it and buys gold bars; the host and client 2
##                    see the money and the pile; client 1 keeps one piece of loot through a whole
##                    shift change; client 3 joins afterwards and sees the pile too
##   two_patients     host + 2 clients: two patients on two tables; client 1 and client 2 operate
##                    on different tables at the same time and each watches the other
##   downed           client 1 goes down and crawls; client 2 carries them to the player table and
##                    stitches them up; the host and both clients see each stage
##   brains           (sweep 3) the client picks up a Walk-In brain (its spoil clock replicated),
##                    blends and drinks it at the blender, looks through a Walk-In with Hive Eyes and
##                    comes back, then drinks a Discharged brain and shrieks Echo; the host sees the
##                    points, the hive view and the echo noise
##
## Shifts start the way the loop does (sweep 2): the host clocks in, skips the grace period,
## answers the phone, and the paramedics wheel the patient onto a table.
##
## Every process exits 0 on success and 1 on failure, printing "PASS:" or "FAIL:" and why.
## Coordination between processes travels over the game's own connection (the _msg RPC).
## Timeouts are wall-clock, so the test behaves the same with or without --fixed-fps.
## `--stats` prints bandwidth: bytes each process sent per game second while the shift ran.

const NAMES := ["Host", "Álvaro", "Bea O'Neil", "Surgeon Chris"]
const EconomyScript := preload("res://scripts/economy/economy.gd")

var role := "host"
var scenario := "deliver"
var index := 0          # 0 host, 1..3 clients
var clients := 2
var port := 7790
var seed_value := 4242
var timeout_s := 150.0
var stats := false
var lagged := false     # the runner simulates lag for the clients of this scenario

var main: Node3D
var game: Game
var _done := false
var _t0 := 0.0
var _inbox: Array = []
var _press_at_ms := 0
var _t_joined := 0.0    # client: wall time the connection came up (0 before)


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
			"lagged": lagged = true
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
		Net.joined_ok.connect(func(): _t_joined = _wall(), CONNECT_ONE_SHOT)
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
		"economy": await _sc_economy()
		"two_patients": await _sc_two_patients()
		"downed": await _sc_downed()
		"brains": await _sc_brains()
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
			if game.surgery_for_table(int(game.case.table)).operator_id == op_id:
				seen.op = true
		if not await _do_until(watch, func(): return int(game.case.get("step_index", 0)) >= 1, 120.0, "the step to finish"):
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
	# Watch from the start: the order can reach the spectator after the operation began.
	var st := {"states": {}, "ops": {}}
	var watch := func():
		var op := int(game.surgery.operator_id)
		if op != 0 and op != Net.my_id():
			st.ops[op] = true
			if game.surgery.mg != null:
				st.states[str(game.surgery.mg.net_state())] = true
	if not await _do_until(watch, func(): return _count_msgs("operate") > 0, 30.0, "operate order"):
		return
	var op_id: int = _msgs("operate")[0].data.peer
	if op_id == Net.my_id():
		if not await _begin_operating():
			return
		if not await _until(func(): return int(game.case.get("step_index", 0)) >= 1, 120.0, "my step to be accepted"):
			return
		await _finish_together("operated step 0 to completion")
	else:
		if not await _do_until(watch, func(): return int(game.case.get("step_index", 0)) >= 1, 120.0, "the operator to finish"):
			return
		if not st.ops.has(op_id) or st.states.size() < 5:
			return _end(false, "spectator saw operator=%s and only %d distinct tool states" % [str(st.ops.has(op_id)), st.states.size()])
		_send("watched", {"states": st.states.size()})
		await _finish_together("watched %d distinct tool states and the step completing" % st.states.size())


func _sc_leave_items():
	if role == "host":
		if not await _start_shift_when_full():
			return
		var leaver: int = _peer_of(1)
		var p = game.players[leaver]
		p.slots = [{"kind": "gauze", "count": 3}, {"kind": "anesthetic", "count": 2}, {"kind": "", "count": 0}, {"kind": "", "count": 0}]
		var before := {"gauze": game.supply_count("gauze"), "anesthetic": game.supply_count("anesthetic")}
		_send("leave", {"peer": leaver})
		if not await _until(func(): return _count_msgs("standing") > 0, 40.0, "the leaver to take position"):
			return
		var spot: Vector3 = _msgs("standing")[0].data.pos
		_send("standing_ok", {})
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
		# Leaving closes the connection: a reliable message still being retransmitted over a lossy
		# link would die with it, so wait for the host to confirm it heard us.
		await _until(func(): return _count_msgs("standing_ok") > 0, 20.0, "the host to hear where I stand")
		await _wall_wait(0.3)
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
		if game.surgery.operator_id != 0 or int(game.case.get("step_index", 0)) != 0 or float(saved.get("p", 0.0)) <= 0.0:
			return _end(false, "after the drop: operator=%d step=%d saved=%s" % [game.surgery.operator_id, game.case.step_index, str(saved)])
		_say("operator gone; step paused at progress %.2f" % float(saved.p))
		_send("resume", {"peer": second, "p": float(saved.p)})
		if not await _until(func(): return int(game.case.get("step_index", 0)) >= 1, 120.0, "client 2 to finish the step"):
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
	if not await _until(func(): return int(game.case.get("step_index", 0)) >= 1, 120.0, "my resumed step to finish"):
		return
	await _finish_together("resumed from %.2f and finished the step" % saved_p)


func _sc_late_join():
	if role == "host":
		# Start with client 1 only; the runner starts client 2 once it sees the marker.
		if not await _until(func(): return Net.names.size() >= 2 and game.players.size() >= 2, 60.0, "client 1"):
			return
		await _wall_wait(1.0)
		game.clock_in()   # the real loop: the grace period is running when the late joiner arrives
		print("[marker] shift_started")
		if not await _until(func(): return Net.names.size() >= 3 and game.players.size() >= 3, 90.0, "the late joiner"):
			return
		var late: int = _peer_of(2)
		await _wall_wait(1.0)
		var lp = game.players[late]
		if lp.alive or game.alive_players().has(lp):
			return _end(false, "the late joiner is alive in the middle of the shift")
		if lp.downed or game.can_pick_up(game.players[_peer_of(1)], lp, false):
			return _end(false, "the late joiner counts as a downed teammate someone could carry")
		if not await _until(func(): return _count_msgs("spectating") > 0, 40.0, "the late joiner to spectate"):
			return
		var seed_before: int = game.seed_value
		game._end_shift(true, "Test: shift over.")   # clocks out: paycheck screen, then the next lobby
		if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 60.0, "the next lobby"):
			return
		await _wall_wait(1.0)
		if not lp.alive:
			return _end(false, "the late joiner is still not alive in the next lobby")
		if game.seed_value != seed_before:
			return _end(false, "the next shift rebuilt the hospital (seed %d -> %d)" % [seed_before, game.seed_value])
		if not await _until(func(): return _count_msgs("spawned") > 0, 40.0, "the late joiner to spawn"):
			return
		await _finish_together("late joiner spectated and spawned at the next shift")
		return
	if index == 1:
		if not await _until(func(): return game.phase == Game.Phase.SHIFT and _me() != null and game.shelf_node != null, 90.0, "the shift"):
			return
		var seed_then: int = game.seed_value
		if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 150.0, "the next lobby"):
			return
		if game.seed_value != seed_then or game.level == null:
			return _end(false, "the next lobby is not the same hospital on client 1")
		await _finish_together("saw the next lobby in the same hospital")
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
	var st := {"target": -1, "shift_t": -1.0, "sent": 0, "recv": 0, "last_step": -1, "crew": false, "money": game.money, "stable": false}
	var ok := await _do_until(func(): _shift_bot(st), func(): return game.phase == Game.Phase.WON or game.phase == Game.Phase.LOST, 900.0, "the shift to end")
	if not ok:
		return
	if game.phase == Game.Phase.LOST:
		return _end(false, "the shift was lost: %s" % game.message)
	if not st.crew:
		return _end(false, "never saw the paramedics bring the patient")
	if not st.stable:
		return _end(false, "clocked out without seeing the patient stable")
	if not await _until(func(): return game.money > int(st.money), 20.0, "the paycheck"):
		return
	if stats and st.shift_t >= 0.0:
		var secs: float = maxf(0.001, game.world_time - st.shift_t)
		var sent: int = Net.bytes_sent - int(st.sent)
		var recv: int = Net.bytes_received - int(st.recv)
		var per := float(sent) / secs / float(maxi(1, clients)) if role == "host" else float(sent) / secs
		print("[stats] %s sent=%d recv=%d game_s=%.1f sent_Bps=%.0f recv_Bps=%.0f %s=%.0f snapshot_payload_Bps=%.0f" % [
			_tag(), sent, recv, secs, sent / secs, recv / secs,
			"sent_per_client_Bps" if role == "host" else "upstream_Bps", per,
			float(game.net_payload_bytes - int(st.get("payload", 0))) / secs / float(maxi(1, clients)) if role == "host" else 0.0])
		var during := {}
		for k in game.net_counters.keys():
			if k != "max_msg":
				during[k] = int(game.net_counters[k]) - int(st.get("counters", {}).get(k, 0))
		print("[stats] %s snapshot messages while the shift ran %s, whole session %s" % [_tag(), str(during), str(game.net_counters)])
		if role == "host":
			var parts := []
			for k in game.net_section_bytes.keys():
				parts.append("%s=%.0f" % [k, float(game.net_section_bytes[k]) / secs / float(maxi(1, clients))])
			print("[stats] host snapshot payload by part, bytes/s per client: %s" % " ".join(parts))
	_me().bot_interact = false
	await _finish_together("shift %d clocked out, paid: $%d (%s)" % [game.shift, game.money, game.loop.pay_note])


## Inventory (sweep 2): selling and buying replicate, and a late joiner sees the gold pile.
func _sc_economy():
	const SELL := {"laptop": 250, "gold_watch": 300}
	const KEEP := "stethoscope"
	const BARS := 3
	if role == "host":
		if not await _until(func(): return Net.names.size() >= 3 and game.players.size() >= 3 and game.economy.placed(), 90.0, "clients 1 and 2"):
			return
		await _wall_wait(1.0)
		var host_p := _me()
		var ids := []
		var k := 0
		for kind in SELL.keys() + [KEEP]:
			var at: Vector3 = game._floor_at(host_p.global_position + Vector3(1.2 + k * 0.8, 0.0, 0.6))
			var it = game._spawn_item(kind, 1, Transform3D(Basis(), at + Vector3.UP * 0.05), WorldItem.State.LOOSE)
			it.value = int(SELL.get(kind, 55))
			ids.append({"id": it.item_id, "kind": kind})
			k += 1
		_send("loot", {"items": ids})
		var total := 0
		for kind in SELL.keys():
			total += int(SELL[kind])
		var spent := 0
		for i in BARS:
			spent += EconomyScript.bar_price(i)
		var want_money := total - spent
		if not await _until(func(): return game.gold_bars >= BARS, 120.0, "client 1 to sell and buy"):
			return
		await _wall_wait(0.5)
		if game.money != want_money or game.gold_bars != BARS:
			return _end(false, "host has $%d and %d bars, expected $%d and %d" % [game.money, game.gold_bars, want_money, BARS])
		_say("host: $%d, %d bars" % [game.money, game.gold_bars])
		# loop: a whole shift goes by; client 1's loot must still be in its hands afterwards.
		if not await _until(func(): return _count_msgs("kept") > 0, 60.0, "client 1 to be holding its loot"):
			return
		if not await _host_clock_in_and_deliver():
			return
		game._end_shift(true, "Test: shift over.")
		if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 60.0, "the next lobby"):
			return
		var c1 = game.players.get(_peer_of(1))
		if not await _until(func(): return c1 != null and c1.holding(KEEP), 20.0, "client 1's loot on the host after the shift"):
			return
		if game.money != want_money:
			return _end(false, "an unfinished forced clock-out changed the money: $%d, expected $%d" % [game.money, want_money])
		_send("check", {"money": want_money, "bars": BARS})
		print("[marker] economy_bought")
		if not await _until(func(): return _count_msgs("late_seen") > 0, 120.0, "the late joiner to see the pile"):
			return
		await _finish_together("client sold $%d of loot and bought %d bars; everyone sees $%d and the pile" % [total, BARS, want_money])
		return
	if index == 3:
		# The late joiner: arrives after the purchase, must see the money and the whole pile.
		if not await _until(func(): return game.phase != Game.Phase.MENU and _me() != null and game.economy.placed(), 90.0, "the world"):
			return
		if not await _until(func(): return _count_msgs("check") > 0 or game.gold_bars > 0, 30.0, "the snapshot"):
			return
		if not await _until(func(): return game.gold_bars == BARS and int(game.economy.pile.get("_target")) == BARS and game.money > 0, 30.0, "the pile after joining"):
			return
		_send("late_seen", {"bars": game.gold_bars, "money": game.money})
		await _finish_together("joined late and see $%d and a pile of %d bars" % [game.money, int(game.economy.pile.get("_target"))])
		return
	if not await _until(func(): return game.phase != Game.Phase.MENU and _me() != null and game.economy.placed() and _count_msgs("loot") > 0, 90.0, "the loot"):
		return
	var me := _me()
	me.bot_active = true
	me.bot_invulnerable = true
	if index == 2:
		if not await _until(func(): return _count_msgs("check") > 0, 150.0, "the purchase"):
			return
		var want: Dictionary = _msgs("check")[0].data
		if not await _until(func(): return game.money == int(want.money) and game.gold_bars == int(want.bars) and int(game.economy.pile.shown) == int(want.bars), 20.0, "money and the pile on client 2"):
			return
		await _finish_together("see $%d and %d bars on the pile" % [game.money, int(game.economy.pile.shown)])
		return
	# Client 1 does the selling and the buying, through E like a player.
	for e in _msgs("loot")[0].data.items:
		var kind: String = e.kind
		var item_id := int(e.id)
		var take := func():
			var it = game.world_items.get(item_id)
			if it != null:
				_press_at(it.global_position, "it_%d" % item_id)
		if not await _do_until(take, func(): return me.holding(kind), 40.0, "picking up " + kind):
			return
	for kind in SELL.keys():
		var sell := func():
			var i := _slot_of(kind)
			if i >= 0:
				me.selected = i
			_press_at(game.economy.sell_bin.global_position, "sell_bin")
		if not await _do_until(sell, func(): return not me.holding(kind), 40.0, "selling " + kind):
			return
	_say("sold everything: $%d" % game.money)
	for i in BARS:
		if not await _do_until(func(): _press_at(game.economy.shop.global_position, "shop"), func(): return game.gold_bars >= i + 1, 40.0, "buying bar %d" % (i + 1)):
			return
	_say("bought %d bars, $%d left" % [game.gold_bars, game.money])
	if not me.holding(KEEP):
		return _end(false, "lost the %s before the shift even started" % KEEP)
	_send("kept", {})
	if not await _until(func(): return _count_msgs("check") > 0, 200.0, "the shift to go by"):
		return
	if not await _until(func(): return game.phase == Game.Phase.LOBBY and game.shift == 2, 20.0, "the next lobby"):
		return
	if not me.holding(KEEP):
		return _end(false, "the %s did not survive the shift change: %s" % [KEEP, str(me.slots)])
	await _finish_together("sold loot, bought %d bars, and kept the %s through a whole shift" % [game.gold_bars, KEEP])


## SWEEP 3 (brains): a client picks up a brain, blends it, uses Hive Eyes and Echo.
func _sc_brains():
	if role == "host":
		if not await _until(func(): return Net.names.size() == clients + 1 and game.players.size() == clients + 1 and game.brains.blender != null, 90.0, "the client and the blender"):
			return
		await _wall_wait(1.0)
		var c1 = game.players.get(_peer_of(1))
		var at: Vector3 = c1.global_position
		var map := get_viewport().world_3d.navigation_map
		var b1: Node = game.brains.spawn_brain("brain_walk_in", 1.0, at + Vector3(1.0, 0.3, 0.0))
		var b2: Node = game.brains.spawn_brain("brain_discharged", 0.5, at + Vector3(-1.0, 0.3, 0.0))
		var b3: Node = game.brains.spawn_brain("brain_discharged", 0.3, at + Vector3(0.0, 0.3, 1.0))
		b3.bt = game.world_time - 400.0   # rotten long ago (fresh / spoiling depend on how fast the bot is)
		var wi: Node = game.brains.spawn_walk_in(NavigationServer3D.map_get_closest_point(map, at + Vector3(0, 0, 9)))
		wi.set_physics_process(false)   # a still Walk-In: the test is about the view, not the chase
		_send("brains", {"items": [b1.item_id, b2.item_id, b3.item_id], "bts": [b1.bt, b2.bt, b3.bt], "walk_in": wi.monster_id})
		var seen := {"hive": false, "echo": false}
		var watch := func():
			if c1.hive_view and not seen.hive:
				seen.hive = true
				_say("the client is looking through a Walk-In (hv)")
			for n in game.recent_noises(1.5):
				if String(n.kind) == "echo" and is_equal_approx(float(n.loudness), 1.2) and (n.pos as Vector3).distance_to(c1.global_position) < 4.0:
					if not seen.echo:
						_say("heard the client's Echo (noise 1.2)")
					seen.echo = true
		if not await _do_until(watch, func(): return seen.hive and seen.echo and _count_msgs("ok") >= 1, 200.0, "the client's hive view and echo (hive %s echo %s)" % [str(seen.hive), str(seen.echo)]):
			return
		var w: float = game.brains.points(c1.peer_id, "walk_in")
		var d: float = game.brains.points(c1.peer_id, "discharged")
		# Walk-In fresh 1.0; the second Discharged brain was fresh or spoiling by the time it was drunk
		# (1.0 or 0.75), the third rotten (0.5).
		if w != 1.0 or not (is_equal_approx(d, 1.25) or is_equal_approx(d, 1.5)):
			return _end(false, "host points for the client: walk_in %.2f discharged %.2f, expected 1.00 / 1.25..1.5" % [w, d])
		await _finish_together("the client drank three brains (%.2f / %.2f), looked through a Walk-In and shrieked Echo" % [w, d])
		return
	if not await _until(func(): return game.phase != Game.Phase.MENU and _me() != null and _count_msgs("brains") > 0 and game.brains.blender != null, 90.0, "the brains"):
		return
	var me := _me()
	me.bot_active = true
	me.bot_invulnerable = true
	var ids: Dictionary = _msgs("brains")[0].data
	var bs := game.brains
	for pass_i in 3:
		var kind := "brain_walk_in" if pass_i == 0 else "brain_discharged"
		var item_id := int(ids.items[pass_i])
		if not await _until(func(): return game.world_items.has(item_id), 20.0, "the %s on my machine" % kind):
			return
		var it = game.world_items[item_id]
		if not await _until(func(): return float(it.bt) > -100000.0, 10.0, "the %s's spoil clock on my machine" % kind):
			return
		if absf(float(it.bt) - float(ids.bts[pass_i])) > 0.51:
			return _end(false, "brain %d's spoil clock is %.1f here, %.1f on the host" % [pass_i, float(it.bt), float(ids.bts[pass_i])])
		if pass_i == 2 and bs.condition(bs.factor_of(it)) != "rotten":
			return _end(false, "the old brain should look rotten on my machine, factor %.2f" % bs.factor_of(it))
		var take := func():
			var node = game.world_items.get(item_id)
			if node != null:
				_press_at(node.global_position, "it_%d" % item_id)
		if not await _do_until(take, func(): return me.holding(kind), 40.0, "picking up the " + kind):
			return
		me.selected = _slot_of(kind)
		if not await _until(func(): return me.slots[_slot_of(kind)].has("bt"), 10.0, "bt in my hand slot"):
			return
		var path := "walk_in" if pass_i == 0 else "discharged"
		var blend := func():
			var i := _slot_of(kind)
			if i >= 0:
				me.selected = i
			_press_at(bs.blender.global_position, "blender", true)
		var before: float = bs.points(Net.my_id(), path)
		if not await _do_until(blend, func(): return not me.holding(kind) and bs.points(Net.my_id(), path) > before, 40.0, "blending the " + kind):
			return
		me.bot_interact = false
		me.bot_aim_id = ""
		_say("drank the %s: walk_in %.2f discharged %.2f" % [kind, bs.points(Net.my_id(), "walk_in"), bs.points(Net.my_id(), "discharged")])
		if pass_i == 0:
			# Hive Eyes: R, then R again to come back.
			me.teleport(_stand_spot(game.monsters[int(ids.walk_in)].global_position + Vector3(0, 0, -8)))
			await _wall_wait(0.5)
			me.bot_ability += 1
			if not await _until(func(): return me.hive_view and bs.local_hive_active() and bs.camera() != null, 20.0, "Hive Eyes on my machine"):
				return
			_say("hive view on at t=%.1f: %s" % [game.world_time, str(bs._hive)])
			await _frames(30)   # game time: the view lasts 7 game seconds at level 1
			var cam: Camera3D = bs.camera()
			var wm = game.monsters.get(int(ids.walk_in))
			if cam == null or wm == null or cam.global_position.distance_to(wm.global_position) > 2.5:
				return _end(false, "the Hive Eyes camera is not at the Walk-In: cam %s, walk-in %s, target %d, hive %s" % [str(cam.global_position if cam != null else null), str(wm.global_position if wm != null else null), int(bs.hive_view.monster_id), str(bs._hive)] + " msg=" + game.message + " t=%.1f" % game.world_time)
			me.bot_ability += 1
			if not await _until(func(): return not me.hive_view and not bs.local_hive_active(), 20.0, "coming back from Hive Eyes"):
				return
			_say("looked through the Walk-In and came back")
	# 1.00 Walk-In against 1.25 Discharged: R is Echo now.
	if bs.best_path(Net.my_id()) != "discharged":
		return _end(false, "expected Echo to be the stronger path (walk_in %.2f discharged %.2f)" % [bs.points(Net.my_id(), "walk_in"), bs.points(Net.my_id(), "discharged")])
	await _wall_wait(0.5)
	me.bot_ability += 1
	if not await _until(func(): return bs.echo_view.active and float(bs.last_echo.get("r", 0.0)) >= 18.0, 20.0, "Echo on my machine"):
		return
	_say("Echo: %d outlines of %d things" % [bs.echo_view.ghosts.size(), bs.echo_view.target_count])
	await _finish_together("picked up and drank three brains, used Hive Eyes and Echo")


## loop (sweep 2): two patients on two tables, two clients operating on different tables at once.
func _sc_two_patients():
	if role == "host":
		if not await _start_shift_when_full():
			return
		var first: Dictionary = game.case
		game.loop.force_extra = {"patient_id": "seal" if String(first.patient_id) == "bob" else "bob", "ailment_id": "gunshot"}
		game.dev_extra_patient()   # the extra call rings now
		if not await _until(func(): return game.loop.call_state == "ringing" and game.loop.call_kind == "extra", 20.0, "the extra call"):
			return
		game.loop.answer(_me())
		if not await _until(func(): return game.cases.size() == 2 and String(game.cases[1].state) == "on_table", 120.0, "the extra patient on a table"):
			return
		var tables := [int(game.cases[0].table), int(game.cases[1].table)]
		if tables[0] == tables[1]:
			return _end(false, "both patients on table %d" % tables[0])
		_stock_shelf()
		var ops := {_peer_of(1): tables[0], _peer_of(2): tables[1]}
		_send("operate_tables", {"ops": ops})
		var seen := {"both": false, "a": false, "b": false}
		var watch := func():
			var a = game.surgery_for_table(tables[0])
			var b = game.surgery_for_table(tables[1])
			seen.a = seen.a or a.operator_id == _peer_of(1)
			seen.b = seen.b or b.operator_id == _peer_of(2)
			if a.operator_id == _peer_of(1) and b.operator_id == _peer_of(2):
				seen.both = true
		if not await _do_until(watch, func(): return int(game.cases[0].step_index) >= 1 and int(game.cases[1].step_index) >= 1, 150.0, "both first steps"):
			return
		if not seen.both:
			# Over a lagged link one bot can finish its short step before the other's request
			# even reaches the host; then each must at least have operated its own table.
			if not (lagged and seen.a and seen.b):
				return _end(false, "never saw both clients operating at the same time (a=%s b=%s)" % [str(seen.a), str(seen.b)])
			_say("the two operations did not overlap (lagged link); both tables were operated")
		for c in game.cases:
			if not (c.flags as Dictionary).has("sedation"):
				return _end(false, "a step finished without its flags: %s" % str(c))
		_say("both tables advanced: %s" % str(game.cases.map(func(c): return "%s t%d step %d vit %.0f" % [c.patient_id, c.table, c.step_index, c.vitals])))
		if not await _until(func(): return _count_msgs("watched_other") >= 2, 40.0, "both clients' reports"):
			return
		await _finish_together("two clients operated on two tables at once")
		return
	if not await _wait_shift_as_client():
		return
	if not await _until(func(): return _count_msgs("operate_tables") > 0 and game.cases.size() == 2 and String(game.cases[1].get("state", "")) == "on_table", 150.0, "the second patient and the order"):
		return
	var ops: Dictionary = _msgs("operate_tables")[0].data.ops
	var mine := int(ops.get(Net.my_id(), -1))
	var other := -1
	for id in ops.keys():
		if int(id) != Net.my_id():
			other = int(ops[id])
	if mine < 0 or other < 0:
		return _end(false, "no table for me in %s" % str(ops))
	if game.body_for_table(mine) == null or game.body_for_table(other) == null:
		return _end(false, "missing a patient body: mine %s other %s" % [str(game.body_for_table(mine)), str(game.body_for_table(other))])
	var sys = game.surgery_for_table(mine)
	var other_sys = game.surgery_for_table(other)
	game.surgery_bot_skill = 1.0
	# Watch the other table from the start: over a lagged link its operation can begin (or even
	# end) before the host has let me operate.
	var st := {"states": {}}
	var watch := func():
		if other_sys.mg != null and other_sys.operator_id != 0 and other_sys.operator_id != Net.my_id():
			st.states[str(other_sys.mg.net_state())] = true
	if not await _do_until(func(): watch.call(); _press_at(game.table_position(mine), game.table_interact_id(mine)),
			func(): return sys.is_local_operating(), 40.0, "the host to let me operate on table %d" % mine):
		return
	if not await _do_until(watch, func(): return int(game.case_on_table(mine).get("step_index", 0)) >= 1 and int(game.case_on_table(other).get("step_index", 0)) >= 1, 150.0, "both steps"):
		return
	if st.states.size() < 3:
		return _end(false, "watched only %d distinct tool states at the other table" % st.states.size())
	_send("watched_other", {"n": st.states.size()})
	await _finish_together("operated table %d while watching %d tool states at table %d" % [mine, st.states.size(), other])


## Downed (sweep 2 wave 3): client 1 goes down, client 2 carries them to the player table and
## stitches them up; the host and both clients see every stage.
func _sc_downed():
	if role == "host":
		if not await _start_shift_when_full():
			return
		game._clear_monsters()
		if not await _until(func(): return not game.player_table.is_empty(), 20.0, "the player table"):
			return
		var downed_id: int = _peer_of(1)
		var carrier_id: int = _peer_of(2)
		var p1 = game.players[downed_id]
		var p2 = game.players[carrier_id]
		# Down client 1 a few metres from the player table.
		_send("stand", {"peer": downed_id, "pos": game.player_table.position + Vector3(0.0, 0.0, 3.5)})
		if not await _until(func(): return _count_msgs("standing") > 0, 30.0, "client 1 in place"):
			return
		await _wall_wait(0.5)
		game.knock_down_player(p1, "test")
		game.shelf["suture_kit"] = 1
		game.shelf_node.show_stock(game.shelf)
		if not await _until(func(): return _count_msgs("crawled") > 0, 30.0, "client 1 to crawl"):
			return
		_send("downed", {"peer": downed_id, "carrier": carrier_id})
		var seen := {"carry": false, "follow": false, "table": false, "op": false}
		var watch := func():
			if p2.carrying == downed_id and p1.carried_by == carrier_id:
				seen.carry = true
				if p1.global_position.distance_to(p2.global_position) < 1.8:
					seen.follow = true
			if p1.on_table and game.player_surgery.patient() == p1:
				seen.table = true
			if game.player_surgery.operator_peer() == carrier_id:
				seen.op = true
		if not await _do_until(watch, func(): return seen.op and not p1.downed and p1.alive, 150.0, "client 1 to be stitched up"):
			return
		if not (seen.carry and seen.follow and seen.table):
			return _end(false, "host saw carry=%s follow=%s table=%s" % [str(seen.carry), str(seen.follow), str(seen.table)])
		if p1.hp != Game.REVIVE_HP or game.shelf_count("suture_kit") != 0 or not game.player_surgery.case.is_empty():
			return _end(false, "after the stitches: hp %d, kits %d, case %s" % [p1.hp, game.shelf_count("suture_kit"), str(game.player_surgery.case)])
		_say("client 1 carried, laid on the table and stitched up by client 2; hp %d" % p1.hp)
		await _finish_together("downed, carried, stitched and revived, seen by the host")
		return
	if not await _wait_shift_as_client():
		return
	if not await _until(func(): return _count_msgs("downed") > 0 or _count_msgs("stand") > 0, 60.0, "the setup"):
		return
	var me := _me()
	if index == 1:
		if not await _until(func(): return _count_msgs("stand") > 0, 30.0, "stand order"):
			return
		me.teleport(game._floor_at(_msgs("stand")[0].data.pos))
		await _wall_wait(1.0)
		_send("standing", {})
		if not await _until(func(): return me.downed, 30.0, "going down"):
			return
		if not await _until(func(): return game.downed_view._layer.visible, 5.0, "the bleed-out overlay"):
			return
		var from := me.global_position
		me.bot_move = Vector2(0, -1)
		await _wall_wait(0.8)
		me.bot_move = Vector2.ZERO
		if me.global_position.distance_to(from) < 0.2:
			return _end(false, "could not crawl while downed")
		_send("crawled", {})
		var seen := {"carried": false, "table": false, "op": false}
		var watch := func():
			if me.carried_by != 0:
				seen.carried = true
			if me.on_table:
				seen.table = true
				if game.player_surgery.surgery.mg != null:
					seen.op = true
		if not await _do_until(watch, func(): return me.alive and not me.downed, 150.0, "being stitched up"):
			return
		if not (seen.carried and seen.table and seen.op):
			return _end(false, "downed client saw carried=%s table=%s minigame=%s" % [str(seen.carried), str(seen.table), str(seen.op)])
		# The snapshot saying "standing" and the reliable revive event (which puts me beside the
		# table) travel separately; over a lossy link either can land first.
		var t_rev := _wall()
		while (me.hp != Game.REVIVE_HP or me.global_position.y > 0.5) and _wall() - t_rev < 10.0:
			await _frames(1)
		if me.hp != Game.REVIVE_HP or me.global_position.y > 0.5:
			return _end(false, "revived with hp %d at %s" % [me.hp, str(me.global_position)])
		await _finish_together("went down, crawled, was carried and stitched back up (hp %d)" % me.hp)
		return
	# Client 2: the rescuer.
	if not await _until(func(): return _count_msgs("downed") > 0, 60.0, "downed order"):
		return
	var target_id: int = _msgs("downed")[0].data.peer
	if not await _until(func(): return game.players.has(target_id) and game.players[target_id].downed, 20.0, "the teammate to be down"):
		return
	var target = game.players[target_id]
	var lift := func(): _press_at(target.global_position, "pl_%d" % target_id, true)
	if not await _do_until(lift, func(): return me.carrying == target_id, 40.0, "lifting the teammate"):
		return
	me.bot_interact = false
	# Walk a few steps with them over the shoulder, as a player would.
	me.bot_aim_id = ""
	me.bot_move = Vector2(0, -1)
	await _wall_wait(1.2)
	me.bot_move = Vector2.ZERO
	if target.global_position.distance_to(me.global_position) > 1.8 or me.carrying != target_id:
		return _end(false, "the carried teammate is not on my shoulder")
	var place := func(): _press_at(game.player_table.position, "player_table")
	if not await _do_until(place, func(): return target.on_table, 40.0, "laying them on the table"):
		return
	game.player_surgery.surgery.bot_skill = 1.0
	var operate := func():
		if not game.player_surgery.surgery.is_local_operating():
			_press_at(game.player_table.position, "player_table")
	if not await _do_until(operate, func(): return game.player_surgery.surgery.is_local_operating() or not target.downed, 40.0, "starting the stitches"):
		return
	if not await _until(func(): return not target.downed and target.alive, 90.0, "the stitches to finish"):
		return
	await _finish_together("carried a downed teammate to the table and stitched them up")


## One frame of a simple co-op bot through the loop: clock in, answer the phone, bring what the
## shelf lacks, operate, clock out.
func _shift_bot(st: Dictionary) -> void:
	var me := _me()
	if me == null:
		return
	me.bot_interact = false
	if game.phase == Game.Phase.LOBBY:
		if index == mini(1, clients):   # one client clocks everyone in, as a player would
			_press_at(game.clock_pos(), "clock", true)
		return
	if game.phase != Game.Phase.SHIFT:
		return
	if not game.loop.crews.is_empty():
		st.crew = true
	for c in game.cases:
		if String(c.state) == "stable":
			st.stable = true
	# The phone: the last client answers the first call (the extra one is left to ring out).
	if game.loop.call_state == "ringing" and game.loop.call_kind == "first" and index == mini(2, clients) and game.loop.phone != null:
		_press_at(game.loop.phone.global_position, "phone")
		return
	if game.loop.can_clock_out():
		if index == mini(1, clients):
			_press_at(game.clock_pos(), "clock", true)
		return
	if game.case.is_empty() or String(game.case.get("state", "")) != "on_table":
		return
	if st.shift_t < 0.0:
		st.shift_t = game.world_time
		st.sent = Net.bytes_sent
		st.recv = Net.bytes_received
		st.payload = game.net_payload_bytes
		st.counters = game.net_counters.duplicate()
		game.net_section_bytes = {}
		_say("patient on the table: %s/%s" % [game.case.patient_id, game.case.ailment_id])
	if int(game.case.get("step_index", 0)) != int(st.last_step):
		st.last_step = int(game.case.get("step_index", 0))
		_say("step %d, vitals %.0f, shelf %s, operator %d" % [st.last_step, game.vitals, str(game.shelf), game.surgery.operator_id])
	if me.operating or game.surgery.is_local_operating():
		return
	var need := Procedures.remaining_requirements(game.case.ailment_id, int(game.case.get("step_index", 0)))
	var short := {}
	for kind in need.keys():
		var n: int = int(need[kind]) - game.shelf_count(kind)
		if n > 0:
			short[kind] = n
	for i in me.slots.size():
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
			_press_at(game.table_position(int(game.case.table)), game.table_interact_id(int(game.case.table)))
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


## Client: wait until the patient is on a table (the loop brings them); also require having seen
## the paramedics' crew and the phone call's subtitles replicate on the way.
func _wait_shift_as_client() -> bool:
	var seen := {"crew": false, "sub": false}
	var watch := func():
		if not game.loop.crews.is_empty() and game.get_node("Entities").find_child("ParamedicCrew_*", false, false) != null:
			seen.crew = true
		if game.loop.subtitle != "":
			seen.sub = true
	var ok := await _do_until(watch, func(): return game.phase == Game.Phase.SHIFT and _me() != null and not game.case.is_empty() \
		and String(game.case.get("state", "")) == "on_table" and game.body_for_table(int(game.case.table)) != null \
		and game.world_items.size() > 0 and game.shelf_node != null, 120.0, "the patient on a table")
	if ok:
		_me().bot_active = true
		_me().bot_invulnerable = true
		if not seen.crew or not seen.sub:
			_end(false, "the patient arrived but I saw crew=%s subtitles=%s" % [str(seen.crew), str(seen.sub)])
			return false
		_say("in shift: case=%s/%s on table %d, items=%d players=%d, saw the paramedics and the call" % [game.case.patient_id, game.case.ailment_id, int(game.case.table), game.world_items.size(), game.players.size()])
	return ok


## Host: the loop's start of a shift: clock in, skip the grace period, answer the phone, wait for
## the paramedics to put the patient on a table.
func _start_shift_when_full() -> bool:
	if not await _until(func(): return Net.names.size() == clients + 1 and game.players.size() == clients + 1, 90.0, "all %d clients" % clients):
		return false
	await _wall_wait(1.0)
	return await _host_clock_in_and_deliver()


func _host_clock_in_and_deliver() -> bool:
	game.clock_in()
	game.dev_skip_grace()
	if not await _until(func(): return game.loop.call_state == "ringing", 30.0, "the phone to ring"):
		return false
	game.loop.answer(_me())
	if not await _until(func(): return String(game.case.get("state", "")) == "on_table", 120.0, "the paramedics to deliver"):
		return false
	# Let the subtitles run on so every client sees some.
	await _wall_wait(0.5)
	_say("shift begun: case=%s/%s on table %d items=%d monsters=%d" % [game.case.patient_id, game.case.ailment_id, int(game.case.table), game.world_items.size(), game.monsters.size()])
	return true


func _stock_shelf() -> void:
	var need: Dictionary = game._live_requirements()
	for kind in need.keys():
		game.shelf[kind] = maxi(int(game.shelf.get(kind, 0)), int(need[kind]))
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
		_say("operating step %d" % int(game.case.get("step_index", 0)))
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
	for i in _me().slots.size():
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
		if role != "host" and not Net.active and scenario != "host_quit" and scenario != "host_kill" and game.phase == Game.Phase.MENU and _t_joined > 0.0:
			_end(false, "lost the connection to the host while waiting for %s" % what)
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
