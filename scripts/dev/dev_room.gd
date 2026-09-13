extends Node
## The dev room: a secret level mode for showing off and testing. One per game, a child of
## Game named "Dev" (so its RPCs have the same path on every machine). Idle unless
## `game.dev_mode`.
##
## The room is a real session: solo or hosted, friends join into it, the host owns the truth.
## Everything here that changes the world runs on the host; clients ask through request()
## and fire() and see the result through the "dv" block of the game snapshot
## (net_state / apply_net_state) and one-off events (tracers, fallen monsters).
##
## Contracts other code relies on are in docs/CONTRACTS.md ("Dev room").

signal state_changed
## The panel's "phone call" button when the game has no dev_phone_call() yet (wave 2 builds it).
signal phone_call_requested

const SEED := -4077
const KILL := "kill"
const KNOCK := "knock"
const GUN_RANGE := 80.0
const GUN_COOLDOWN := 0.16
const KNOCK_STUN := 3.0
const MONSTER_KNOCK_SECONDS := 4.0
const AUTO_REVIVE_SECONDS := 4.0
## Where the first-person gun sits on the camera: low on the right, clear of the crosshair.
const GUN_FP_POS := Vector3(0.24, -0.23, -0.46)
## Render layer 18 for the first-person gun (layer 20 is the minigames').
const GUN_FP_LAYER := 1 << 17
const ORDERS := ["follow", "stay", "carry", "operate"]
const MONSTER_KINDS := ["discharged", "night_nurse"]
const BOT_NAMES := ["Dr. Botsworth", "Nurse Unit", "Intern 404", "Dr. Clank", "Orderly-9", "Dr. Servo", "Scrub Bot", "Dr. Byte"]

const LevelScript := preload("res://scripts/dev/dev_level.gd")
const BotBrain := preload("res://scripts/dev/dev_bot.gd")
const GunFx := preload("res://scripts/dev/dev_gun.gd")
const PlayerScript := preload("res://scripts/player.gd")
const WorldItemScript := preload("res://scripts/world_item.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")

var game: Node = null

# ---- replicated (host authoritative) ----
var time_scale := 1.0
var lights_on := true
var pen_open := false
var freeze_vitals := true
var auto_revive := true
var god := {}      # peer id -> true
var noclip := {}   # peer id -> true
var gun := {}      # peer id -> true
## Bots and dummies: id (negative) -> {name, kind: "bot"|"dummy", order, item, to, owner, status, done}
var bots := {}

# ---- host ----
var brains := {}   # id -> BotBrain
var _next_bot := 1
var _fire_at := {}  # peer id -> world_time of the last shot
var _dead_for := {}
var _applied_gate := false
var _applied_lights := true

# ---- local ----
var _recoil := {}   # peer id -> 0..1


func setup(g: Node) -> void:
	game = g


func active() -> bool:
	return game != null and game.dev_mode and game.phase != game.Phase.MENU


func is_host() -> bool:
	return game != null and game.is_host()


# =========================================================================
# lifecycle (called from game.gd hooks)
# =========================================================================

## Builds the room into `info` (game._build_level's dev branch).
func build_level(info: Dictionary) -> Node3D:
	return LevelScript.build(info)


## The level exists and everyone is in it (game.start_lobby's dev branch).
func on_enter() -> void:
	reset_state()
	game._set_phase(game.Phase.SHIFT)
	game.vitals = 100.0
	if is_host():
		_stock_containers()
	game.say("Dev room. F1 opens the dev panel.", 5.0)


## Fill every container with what that kind of container normally holds.
func _stock_containers() -> void:
	for e in game.level_info.get("containers", []):
		var ct = e.get("node")
		if ct == null or not is_instance_valid(ct) or not ct.is_inside_tree():
			continue
		var kinds := []
		for kind in Items.ITEMS.keys():
			if Items.def(kind).get("found", {}).has(String(e.type)):
				kinds.append(kind)
		if kinds.is_empty():
			continue
		for i in ct.slot_count():
			var kind: String = kinds[i % kinds.size()]
			var batch: Array = Items.def(kind).get("batch", [1, 1])
			game._spawn_item(kind, int(batch[batch.size() - 1]), ct.slot_transform(i), WorldItemScript.State.IN_CONTAINER, String(e.id), i)


## A patient was saved or lost in the dev room: clear the table, stay in the room. (loop: the game
## now clears a finished case's table itself a few seconds later; this stays for old callers.)
func on_case_over(_won: bool) -> void:
	game.case = {}
	game._apply_case_locally()
	game.end_timer = 0.0
	game._set_phase(game.Phase.SHIFT)
	for p in game.players.values():
		if not p.alive:
			_revive(p)


## Leaving the dev room (a normal lobby or the menu): undo anything global.
func reset_state() -> void:
	for id in bots.keys():
		_free_bot(id)
	bots.clear()
	brains.clear()
	god.clear()
	noclip.clear()
	gun.clear()
	_dead_for.clear()
	_fire_at.clear()
	time_scale = 1.0
	Engine.time_scale = 1.0
	lights_on = true
	pen_open = false
	freeze_vitals = true
	auto_revive = true
	_applied_gate = false
	_applied_lights = true
	state_changed.emit()


func has_gun(peer_id: int) -> bool:
	return gun.has(peer_id)


func is_god(p: Node) -> bool:
	return p != null and god.has(p.peer_id)


# =========================================================================
# frame
# =========================================================================

func _physics_process(delta: float) -> void:
	if not active():
		return
	if is_host():
		_host_tick(delta)


func _host_tick(delta: float) -> void:
	# Vitals: with freeze on every patient on a table waits (loop: every case, not just one).
	if game.phase == game.Phase.SHIFT and freeze_vitals:
		var drain: float = C.VITALS_DRAIN_SECONDS * pow(0.85, game.shift - 1)
		for c in game.cases:
			if String(c.get("state", "")) == "on_table" and float(c.vitals) > 0.0:
				c.vitals = minf(100.0, float(c.vitals) + delta * 100.0 / drain)
	for id in brains.keys():
		var b = brains[id]
		b.tick(delta)
		if bots.has(id):
			bots[id]["status"] = b.status
			bots[id]["done"] = b.completed
			bots[id]["order"] = b.order
	if auto_revive:
		for p in game.players.values():
			if p.alive or p.get("is_bot"):
				_dead_for.erase(p.peer_id)
				continue
			_dead_for[p.peer_id] = float(_dead_for.get(p.peer_id, 0.0)) + delta
			if _dead_for[p.peer_id] >= AUTO_REVIVE_SECONDS:
				_dead_for.erase(p.peer_id)
				_revive(p)


func _process(delta: float) -> void:
	if game == null or game.phase == game.Phase.MENU:
		return
	for p in game.players.values():
		_update_gun_visual(p, delta)
	if not game.dev_mode:
		return
	if _applied_gate != pen_open:
		_applied_gate = pen_open
		LevelScript.set_gate_open(game.level_info, pen_open)
	if _applied_lights != lights_on:
		_applied_lights = lights_on
		_apply_lights()
	if not is_equal_approx(Engine.time_scale, time_scale):
		Engine.time_scale = time_scale


func _apply_lights() -> void:
	for l in game.level_info.get("lights", []):
		var node = l.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var bulb = node.get_node_or_null("Bulb")
		if bulb != null:
			bulb.visible = lights_on
		var panel = node.get_node_or_null("Panel")
		if panel != null:
			panel.visible = lights_on


# =========================================================================
# the dev gun
# =========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not active() or not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT and event.button_index != MOUSE_BUTTON_RIGHT:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or game.paused:
		return
	var me = game.local_player()
	if me == null or not me.alive or me.operating or not has_gun(me.peer_id):
		return
	fire_local(KILL if event.button_index == MOUSE_BUTTON_LEFT else KNOCK)
	get_viewport().set_input_as_handled()


## The local player pulls the trigger along their own view.
func fire_local(mode: String) -> void:
	var me = game.local_player()
	if me == null:
		return
	var xf: Transform3D = me.camera.global_transform
	fire(me, xf.origin, -xf.basis.z, mode)


## Fire `shooter`'s dev gun from `from` along `dir`. On the host this applies the hit; on a
## client it draws the shot straight away and asks the host, which checks it and applies it.
func fire(shooter: Node, from: Vector3, dir: Vector3, mode: String) -> Dictionary:
	if shooter == null or not active():
		return {}
	dir = dir.normalized()
	if is_host():
		return _host_fire(shooter, from, dir, mode)
	var hit := _cast(shooter, from, dir)
	_shot_fx(shooter.peer_id, from, hit.get("position", from + dir * GUN_RANGE), mode, not hit.is_empty())
	_rpc_fire.rpc_id(Net.HOST_ID, from, dir, mode)
	return hit


@rpc("any_peer", "reliable", "call_remote")
func _rpc_fire(from: Vector3, dir: Vector3, mode: String) -> void:
	if not is_host():
		return
	var p = game.players.get(multiplayer.get_remote_sender_id())
	if p != null:
		_host_fire(p, from, dir.normalized(), mode)


func _host_fire(shooter: Node, from: Vector3, dir: Vector3, mode: String) -> Dictionary:
	if not shooter.alive or not has_gun(shooter.peer_id) or (mode != KILL and mode != KNOCK):
		return {}
	var now: float = game.world_time
	if now - float(_fire_at.get(shooter.peer_id, -99.0)) < GUN_COOLDOWN * 0.8:
		return {}
	# The shot has to start at the shooter's eyes (a client reports its own position; allow lag).
	if from.distance_to(shooter.head.global_position) > 2.5:
		return {}
	_fire_at[shooter.peer_id] = now
	var hit := _cast(shooter, from, dir)
	var to: Vector3 = hit.get("position", from + dir * GUN_RANGE)
	var target = hit.get("target")
	if target != null:
		_apply_hit(shooter, target, mode, dir)
	game.emit_noise(from, 0.9, "gunshot")
	_shot_fx(shooter.peer_id, from, to, mode, target != null)
	if Net.active:
		_rpc_shot.rpc(shooter.peer_id, from, to, mode, target != null)
	return hit


@rpc("authority", "reliable", "call_remote")
func _rpc_shot(shooter_id: int, from: Vector3, to: Vector3, mode: String, hit: bool) -> void:
	if shooter_id == Net.my_id():
		return   # already drawn when we pulled the trigger
	_shot_fx(shooter_id, from, to, mode, hit)


## {position, target} of the first thing along the shot, or {} for a miss into nothing.
func _cast(shooter: Node, from: Vector3, dir: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * GUN_RANGE)
	q.collision_mask = C.L_WORLD | C.L_PLAYER | C.L_MONSTER
	q.exclude = [shooter.get_rid()]
	var hit: Dictionary = shooter.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {}
	var node: Node = hit.collider
	var target: Node = null
	while node != null:
		if node.is_in_group("monster") or (node is CharacterBody3D and "peer_id" in node):
			target = node
			break
		node = node.get_parent()
	return {"position": hit.position, "target": target}


func _apply_hit(shooter: Node, target: Node, mode: String, dir: Vector3) -> void:
	var knock := Vector3(dir.x, 0.0, dir.z).normalized() * 7.0 + Vector3.UP * 2.0
	if target.is_in_group("monster"):
		if mode == KILL:
			game.kill_monster(target)
		else:
			game.knock_down_monster(target, dir, MONSTER_KNOCK_SECONDS)
		return
	if not target.alive:
		return
	if mode == KILL:
		game.damage_player(target, maxi(1, target.hp), "dev_gun:%s" % shooter.player_name, knock)
	else:
		game.knock_down_player(target, "dev_gun:%s" % shooter.player_name, knock)


func _shot_fx(shooter_id: int, from: Vector3, to: Vector3, mode: String, hit: bool) -> void:
	var p = game.players.get(shooter_id)
	var start := from
	if p != null:
		_recoil[shooter_id] = 1.0
		var fp: Node3D = p.camera.get_node_or_null("DevGunFP") if p.is_local else p.body_visual.get_node_or_null("DevGunTP")
		if fp != null and fp.visible:
			var muzzle = fp.get_node_or_null("DevGun/Muzzle")
			if muzzle != null:
				start = muzzle.global_position
	GunFx.tracer(game.get_node("Entities"), start, to, mode, hit)
	Audio.play("dev_zap" if mode == KILL else "dev_thump", from, -2.0, 0.08)
	if hit:
		Audio.play("punch" if mode == KILL else "thud", to, -4.0, 0.1)


## First-person gun on your camera (hands hidden), third-person gun on everyone else's body.
func _update_gun_visual(p: Node, delta: float) -> void:
	var want: bool = game.dev_mode and gun.has(p.peer_id) and p.alive
	var fp: Node3D = p.camera.get_node_or_null("DevGunFP")
	var tp: Node3D = p.body_visual.get_node_or_null("DevGunTP")
	if not want:
		if fp != null:
			for n in [fp, tp]:
				if n != null:
					n.name = "DevGunGone"
					n.queue_free()
			if p.is_local:
				p.hands.visible = true
		return
	if fp == null:
		fp = Node3D.new()
		fp.name = "DevGunFP"
		fp.position = GUN_FP_POS
		fp.scale = Vector3.ONE * 0.75
		var g := GunFx.make_gun()
		g.rotation.y = 0.04
		fp.add_child(g)
		p.camera.add_child(fp)
		# The flashlight sits a hand's width from the gun and would bleach it white: keep the
		# first-person gun on its own render layer and out of the flashlight's cull mask.
		for mi in fp.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).layers = GUN_FP_LAYER
		p.flashlight.light_cull_mask = p.flashlight.light_cull_mask & ~GUN_FP_LAYER
		tp = Node3D.new()
		tp.name = "DevGunTP"
		tp.position = Vector3(0.28, 1.2, -0.38)
		tp.add_child(GunFx.make_gun())
		p.body_visual.add_child(tp)
	fp.visible = p.is_local
	if tp != null:
		tp.visible = not p.is_local
	if p.is_local:
		p.hands.visible = false
	var r: float = maxf(0.0, float(_recoil.get(p.peer_id, 0.0)) - delta * 7.0)
	_recoil[p.peer_id] = r
	fp.position = GUN_FP_POS + Vector3(0.0, r * 0.02, r * 0.06)
	fp.rotation.x = r * 0.35


# =========================================================================
# requests: the panel (and tests) change the world through here
# =========================================================================

## Ask for a change. The host applies it at once; a client sends it to the host.
func request(action: String, args: Dictionary = {}) -> void:
	if game == null or not game.dev_mode:
		return
	if is_host():
		_apply_request(Net.my_id(), action, args)
	elif Net.active:
		_rpc_request.rpc_id(Net.HOST_ID, action, args)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_request(action: String, args: Dictionary) -> void:
	if is_host() and game.dev_mode:
		_apply_request(multiplayer.get_remote_sender_id(), action, args)


func _apply_request(sender: int, action: String, a: Dictionary) -> void:
	var who = game.players.get(sender)
	match action:
		"god":
			_set_flag(god, sender, bool(a.get("on", not god.has(sender))))
		"noclip":
			_set_flag(noclip, sender, bool(a.get("on", not noclip.has(sender))))
		"gun":
			_set_flag(gun, sender, bool(a.get("on", not gun.has(sender))))
		"time_scale":
			time_scale = clampf(float(a.get("v", 1.0)), 0.05, 4.0)
		"lights":
			lights_on = bool(a.get("on", not lights_on))
		"pen":
			pen_open = bool(a.get("open", not pen_open))
		"freeze":
			freeze_vitals = bool(a.get("on", not freeze_vitals))
		"auto_revive":
			auto_revive = bool(a.get("on", not auto_revive))
		"difficulty":
			game.shift = clampi(int(a.get("shift", 1)), 1, 99)
			game.say("Difficulty: shift %d." % game.shift, 2.5)
		"spawn_item":
			_spawn_item(who, String(a.get("kind", "gauze")), int(a.get("count", 1)))
		"spawn_monster":
			spawn_monster(String(a.get("kind", "discharged")), String(a.get("where", "pen")), who)
		"kill_monsters":
			for m in game.monsters.values().duplicate():
				game.kill_monster(m)
		"patient":
			set_patient(String(a.get("patient", "bob")), String(a.get("ailment", "gunshot")))
		"clear_patient":
			# loop: every patient, on the tables and on the way.
			for c in game.cases.duplicate():
				game.remove_case(int(c.id))
		"vitals":
			for c in game.cases:
				if String(c.get("state", "")) == "on_table":
					c.vitals = clampf(float(a.get("v", 100.0)), 1.0, 100.0)
		"extra_patient":
			game.dev_extra_patient()
		"skip_grace":
			game.dev_skip_grace()
		"stock_shelf":
			stock_shelf()
		"clear_shelf":
			game.shelf = {}
			if game.shelf_node != null:
				game.shelf_node.show_stock(game.shelf)
		"phone":
			phone_call()
		"spawn_bot":
			spawn_bot(String(a.get("kind", "bot")), who)
		"remove_bot":
			remove_bot(int(a.get("id", 0)))
		"remove_bots":
			for id in bots.keys():
				remove_bot(id)
		"order":
			order_bot(int(a.get("id", 0)), String(a.get("order", "stay")), String(a.get("item", "")), String(a.get("to", "")), sender)
		"money":
			# inventory: the panel's money buttons (amount may be negative) and "reset"
			if bool(a.get("reset", false)):
				game.reset_money()
			else:
				game.add_money(int(a.get("amount", 1000)), "dev:panel")
		"revive_all":
			for p in game.players.values():
				if not p.alive:
					_revive(p)
	state_changed.emit()


func _set_flag(d: Dictionary, id: int, on: bool) -> void:
	if on:
		d[id] = true
	else:
		d.erase(id)
	var p = game.players.get(id)
	if p != null:
		p.noclip = noclip.has(id)


# =========================================================================
# host actions
# =========================================================================

func dispense(p: Node, kind: String, count: int, at: Vector3) -> void:
	if not is_host() or p == null:
		return
	if kind == "dev_gun":
		_set_flag(gun, p.peer_id, not gun.has(p.peer_id))
		game._sound("click", at)
		game.tell(p, "Dev gun: left click kills, right click knocks down." if gun.has(p.peer_id) else "Dev gun racked.", 3.0)
		state_changed.emit()
		return
	if not p.can_take(kind):
		game.tell(p, "That needs two free hands." if Items.is_bulky(kind) else "Your hands are full.")
		return
	var it = game._spawn_item(kind, maxi(1, count), Transform3D(Basis(), at), WorldItemScript.State.LOOSE)
	it.value = loot_value(kind, maxi(1, count))
	game.pickup_item(p, it)


## A dispensed or spawned stack of loot is worth what it would be one wing deep (0 otherwise).
static func loot_value(kind: String, count: int) -> int:
	if not Items.is_loot(kind):
		return 0
	var v := 0
	for i in count:
		v += LootTable.roll_value(kind, 1, 0.5)
	return v


## A bot hands the stack in `hand` to another player, straight into a free (or matching) hand.
func hand_over(from: Node, to: Node, hand: int) -> bool:
	if not is_host():
		return false
	hand = from.head_of(hand)  # inventory: a bulky stack hands over from either of its slots
	var s: Dictionary = from.slots[hand]
	if s.kind == "":
		return false
	if to.slot_for(s.kind) < 0:
		from.selected = hand
		game.drop_selected(from)
		game.tell(to, "%s put %s at your feet." % [from.player_name, Items.display_name(s.kind)], 2.5)
		return true
	to.take_into(String(s.kind), int(s.count), int(s.get("v", 0)))
	from.clear_slot(hand)
	game._sound("pickup", to.global_position)
	game.tell(to, "%s handed you %s." % [from.player_name, Items.display_name(s.kind)], 2.5)
	return true


func _spawn_item(who: Node, kind: String, count: int) -> void:
	if not Items.exists(kind):
		return
	var at := _in_front_of(who, 1.4) + Vector3.UP * 1.2
	var it = game._spawn_item(kind, clampi(count, 1, 20), Transform3D(Basis(), at), WorldItemScript.State.LOOSE)
	it.value = loot_value(kind, clampi(count, 1, 20))
	it.toss(Transform3D(Basis(), at), Vector3.UP * 1.0)


func spawn_monster(kind: String, where: String, who: Node = null) -> Node:
	if not is_host() or not MONSTER_KINDS.has(kind):
		return null
	var pos: Vector3
	if where == "front" and who != null:
		pos = _in_front_of(who, 4.0)
	else:
		var spots: Array = game.level_info.get("monster_spawns", [Vector3(12, 0, 3)])
		pos = spots[game.monsters.size() % spots.size()]
	var m = game._add_monster(kind, pos)
	game.say("A %s crawls out." % ("Discharged" if kind == "discharged" else "Night Nurse"), 2.0)
	return m


func set_patient(patient_id: String, ailment_id: String) -> void:
	if not is_host() or Procedures.patient(patient_id).is_empty() or Procedures.ailment(ailment_id).is_empty():
		return
	# loop: the first free patient table; with both taken, the first table's patient makes room.
	var table: int = game.free_patient_table()
	if table < 0:
		table = int(game.patient_tables[0].index) if not game.patient_tables.is_empty() else 0
		var there: Dictionary = game.case_on_table(table)
		if not there.is_empty():
			game.remove_case(int(there.id))
	game.add_case({"patient_id": patient_id, "ailment_id": ailment_id, "table": table, "state": "on_table"})
	game._set_phase(game.Phase.SHIFT)
	game.say("%s is on the table: %s." % [Procedures.patient(patient_id).name, Procedures.ailment(ailment_id).name], 3.0)


func stock_shelf() -> void:
	for kind in Items.SURGICAL:
		game.shelf[kind] = maxi(int(game.shelf.get(kind, 0)), 6 if Items.is_consumable(kind) else 1)
	if game.shelf_node != null:
		game.shelf_node.show_stock(game.shelf)


func phone_call() -> void:
	if game.has_method("dev_phone_call"):
		game.dev_phone_call()
		return
	phone_call_requested.emit()
	game.say("*ring ring* (the phone call arrives with the shift loop)", 3.0)


func spawn_bot(kind: String, who: Node = null) -> int:
	if not is_host():
		return 0
	kind = "dummy" if kind == "dummy" else "bot"
	var id := -_next_bot
	_next_bot += 1
	var n_bots := 0
	var n_dummies := 0
	for b in bots.values():
		if b.kind == "dummy":
			n_dummies += 1
		else:
			n_bots += 1
	var bot_name: String = "Dummy %d" % (n_dummies + 1) if kind == "dummy" else BOT_NAMES[n_bots % BOT_NAMES.size()]
	var owner_id: int = who.peer_id if who != null else Net.my_id()
	bots[id] = {"name": bot_name, "kind": kind, "order": "stay" if kind == "dummy" else "follow",
		"item": "gauze", "to": "shelf", "owner": owner_id, "status": "", "done": 0}
	var p := _make_bot_node(id, bot_name, kind)
	var pos: Vector3
	if kind == "dummy":
		var spots: Array = game.level_info.get("dummy_spots", [Vector3(16, 0, 11)])
		pos = spots[n_dummies % spots.size()]
		p.bot_yaw = PI   # face the spawn so the target rings show
	else:
		pos = _in_front_of(who, 2.0) if who != null else game.spawn_points()[0]
	p.teleport(pos)
	if kind == "bot":
		var brain = BotBrain.new(self, p)
		brain.set_order("follow", "gauze", "shelf", owner_id)
		brains[id] = brain
	state_changed.emit()
	return id


func remove_bot(id: int) -> void:
	if not bots.has(id):
		return
	var p = game.players.get(id)
	if p != null and is_host():
		game.end_operations(p)
		game._drop_hands(p, false)
	_free_bot(id)
	bots.erase(id)
	brains.erase(id)
	state_changed.emit()


func order_bot(id: int, new_order: String, kind: String = "", target: String = "", owner: int = 0) -> void:
	if not ORDERS.has(new_order) or not brains.has(id):
		return
	if kind != "" and not Items.exists(kind):
		kind = ""
	brains[id].set_order(new_order, kind, target, owner)
	bots[id]["order"] = new_order
	if kind != "":
		bots[id]["item"] = kind
	if target != "":
		bots[id]["to"] = target
	state_changed.emit()


func _make_bot_node(id: int, bot_name: String, kind: String) -> Node:
	var p = PlayerScript.new_player(id, bot_name, false)
	p.is_bot = true
	p.bot_active = true
	p.set_flashlight(false)
	if kind == "dummy":
		GunFx.dress_dummy(p.body_visual)
		p.name_tag.modulate = Color(1.0, 0.85, 0.35)
	else:
		p.name_tag.modulate = Color(0.55, 1.0, 0.9)
		p.name_tag.text = "[BOT] " + bot_name
	game.players[id] = p
	game.get_node("Entities").add_child(p)
	return p


func _free_bot(id: int) -> void:
	var p = game.players.get(id)
	if p != null:
		game.players.erase(id)
		p.queue_free()


func _revive(p: Node) -> void:
	var spots: Array = game.spawn_points()
	var at: Vector3 = p.global_position if p.get("is_bot") else spots[randi() % spots.size()]
	p.teleport(at)
	p.revive_full()
	p.stun = 0.0
	game._broadcast("revive", {"id": p.peer_id, "pos": at})


func _in_front_of(who: Node, dist: float) -> Vector3:
	if who == null:
		return game.spawn_points()[0]
	var fwd: Vector3 = -who.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var from: Vector3 = who.global_position + Vector3.UP * 1.0
	var q := PhysicsRayQueryParameters3D.create(from, from + fwd * dist)
	q.collision_mask = C.L_WORLD
	var hit: Dictionary = who.get_world_3d().direct_space_state.intersect_ray(q)
	var d := dist if hit.is_empty() else maxf(0.3, from.distance_to(hit.position) - 0.6)
	return game._floor_at(who.global_position + fwd * d)


# =========================================================================
# noclip (player.gd calls this for a noclipping local player or bot)
# =========================================================================

func noclip_move(p: Node, input_dir: Vector2, fast: bool, delta: float) -> void:
	var basis: Basis = p.camera.global_transform.basis
	var v: Vector3 = basis * Vector3(input_dir.x, 0.0, input_dir.y)
	if p.is_local and not p.bot_active:
		if Input.is_physical_key_pressed(KEY_SPACE):
			v += Vector3.UP
		if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C):
			v += Vector3.DOWN
	var speed := (C.SPRINT_SPEED * 3.0) if fast else (C.WALK_SPEED * 2.0)
	p.velocity = Vector3.ZERO
	p.global_position += v.limit_length(1.0) * speed * delta
	p.moving = v.length() > 0.1


# =========================================================================
# replication
# =========================================================================

func net_state() -> Dictionary:
	var stun := {}
	for p in game.players.values():
		if p.stun > 0.0:
			stun[p.peer_id] = snappedf(p.stun, 0.1)
	return {
		"ts": time_scale, "lo": lights_on, "po": pen_open, "fv": freeze_vitals, "ar": auto_revive,
		"gd": god.keys(), "nc": noclip.keys(), "gn": gun.keys(), "bt": bots, "st": stun,
	}


## Client: mirror the host's dev state. Runs before the snapshot's player list is applied, so
## bot Player nodes exist by the time their entries arrive.
func apply_net_state(s: Dictionary) -> void:
	if is_host():
		return
	time_scale = float(s.get("ts", 1.0))
	lights_on = bool(s.get("lo", true))
	pen_open = bool(s.get("po", false))
	freeze_vitals = bool(s.get("fv", true))
	auto_revive = bool(s.get("ar", true))
	god = _as_set(s.get("gd", []))
	noclip = _as_set(s.get("nc", []))
	gun = _as_set(s.get("gn", []))
	var remote_bots: Dictionary = s.get("bt", {})
	var changed := remote_bots.size() != bots.size()
	for id in remote_bots.keys():
		var e: Dictionary = remote_bots[id]
		if not game.players.has(id):
			_make_bot_node(int(id), String(e.get("name", "Bot")), String(e.get("kind", "bot")))
			changed = true
	for id in bots.keys():
		if not remote_bots.has(id):
			_free_bot(id)
	bots = remote_bots
	var stun: Dictionary = s.get("st", {})
	for p in game.players.values():
		p.noclip = noclip.has(p.peer_id)
		var t := float(stun.get(p.peer_id, 0.0))
		if p.is_local:
			if t > p.stun + 0.3:
				p.stun = t
		else:
			p.stun = t
	if changed:
		state_changed.emit()


static func _as_set(ids: Array) -> Dictionary:
	var out := {}
	for id in ids:
		out[int(id)] = true
	return out


## One-off events from game._event that belong to the dev room.
func on_event(kind: String, data: Dictionary) -> void:
	match kind:
		"monster_killed":
			monster_died_fx(data)


func monster_died_fx(data: Dictionary) -> void:
	GunFx.monster_corpse(game.get_node("Entities"), String(data.get("kind", "discharged")), data.get("pos", Vector3.ZERO), float(data.get("y", 0.0)))
	Audio.play("monsters_shriek", data.get("pos", Vector3.ZERO) + Vector3.UP * 1.5, -4.0, 0.15)
