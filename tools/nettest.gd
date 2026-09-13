extends Node
## Real two-process multiplayer test over ENet on localhost. Run a host and a client:
##
##   godot --headless --path . tools/nettest.tscn -- --role=host [--port=7790] [--seed=N]
##   godot --headless --path . tools/nettest.tscn -- --role=client [--port=7790]
##
## The client joins, waits for the shift, opens a container if its target item is inside one,
## picks the item up, carries it to the OR shelf and places it. Both sides print what they
## see; the client exits 0 only if the host's shelf (as mirrored back to the client) shows the
## delivery, and the host exits 0 only if it received it.

var role := "host"
var port := 7790
var seed_value := 4242
var main: Node3D
var game: Game
var t := 0.0
var _stage := "boot"
var _target_id := -1
var _target_kind := ""
var _done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"role": role = v
			"port": port = int(v)
			"seed": seed_value = int(v)
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	main.menu.hide_menu()
	if role == "host":
		var err := Net.host("Host", port)
		if err != "":
			_end(false, "host failed: " + err)
			return
		game.start_session(seed_value)
		_stage = "waiting_for_client"
	else:
		Net.local_name = "Client"
		var err2 := Net.join("127.0.0.1", port)
		if err2 != "":
			_end(false, "join failed: " + err2)
			return
		_stage = "joining"
	_say("started as %s on port %d" % [role, port])


func _physics_process(delta: float) -> void:
	if _done or game == null:
		return
	t += delta
	if t > 90.0:
		_end(false, "timed out in stage " + _stage)
		return
	if role == "host":
		_host_tick()
	else:
		_client_tick()


func _host_tick() -> void:
	match _stage:
		"waiting_for_client":
			if Net.names.size() >= 2:
				_say("client connected: %s" % str(Net.names))
				await get_tree().create_timer(1.0).timeout
				game.begin_shift()
				_say("shift begun: case=%s items=%d containers=%d" % [str(game.case), game.world_items.size(), game.level_info.get("containers", []).size()])
				_stage = "watching"
		"watching":
			var total := 0
			for k in game.shelf.keys():
				total += int(game.shelf[k])
			if total > 0:
				var client = game.players.get(Net.peer_ids()[-1])
				_say("shelf received %s; client at %s holding %s" % [str(game.shelf), str(client.global_position) if client else "?", str(client.slots) if client else "?"])
				await get_tree().create_timer(3.0).timeout
				_end(true, "delivery received from the client")
			elif Net.names.size() < 2:
				_end(false, "client left before delivering")


func _client_tick() -> void:
	var me: Player = game.local_player()
	match _stage:
		"joining":
			if game.phase == Game.Phase.SHIFT and me != null and not game.case.is_empty() and game.world_items.size() > 0:
				_say("client sees shift: case=%s items=%d players=%d shelf=%s" % [str(game.case), game.world_items.size(), game.players.size(), str(game.shelf)])
				me.bot_active = true
				me.bot_invulnerable = true
				_pick_target()
				_stage = "fetch"
		"fetch":
			var it = game.world_items.get(_target_id)
			if it == null:
				if me.holding(_target_kind):
					_say("client now holds %s (slots %s)" % [_target_kind, str(me.slots)])
					_stage = "deliver"
				return
			if it.state == WorldItem.State.IN_CONTAINER:
				var ct := game.find_interactable(it.container_id)
				if ct != null and ct.has_method("is_open") and not ct.is_open():
					_stand_and_press(ct.global_position, it.container_id)
					return
			_stand_and_press(it.global_position, "it_%d" % _target_id)
		"deliver":
			for i in 2:
				if me.slots[i].kind == _target_kind:
					me.selected = i
			_stand_and_press(game.shelf_node.global_position, "shelf")
			if game.shelf_count(_target_kind) > 0:
				_say("client sees shelf %s" % str(game.shelf))
				_end(true, "delivery visible in the host's snapshot")


func _pick_target() -> void:
	var need := Procedures.requirements(game.case.ailment_id)
	var me: Player = game.local_player()
	var best_d := INF
	for it in game.world_items.values():
		if not need.has(it.kind):
			continue
		var d: float = it.global_position.distance_to(me.global_position)
		if d < best_d:
			best_d = d
			_target_id = it.item_id
			_target_kind = it.kind
	_say("client target: item %d (%s)" % [_target_id, _target_kind])


var _press_cd := 0.0
func _stand_and_press(pos: Vector3, id: String) -> void:
	var me: Player = game.local_player()
	_press_cd -= 1.0 / 60.0
	# The client owns its own position, so standing next to the target is a legal move.
	var flat := Vector3(pos.x, 0.0, pos.z)
	if me.global_position.distance_to(flat + Vector3(0, me.global_position.y, 0)) > 1.4:
		var dir := (me.global_position - flat)
		dir.y = 0.0
		dir = dir.normalized() if dir.length() > 0.01 else Vector3.BACK
		me.teleport(game._floor_at(flat + dir * 1.1))
	me.bot_aim_id = id
	if _press_cd <= 0.0 and me.aim_id == id:
		me.bot_press += 1
		_press_cd = 0.6


func _say(line: String) -> void:
	print("[net:%s] t=%.1f %s" % [role, t, line])


func _end(ok: bool, why: String) -> void:
	if _done:
		return
	_done = true
	_say(("PASS: " if ok else "FAIL: ") + why)
	Net.leave()
	get_tree().quit(0 if ok else 1)
