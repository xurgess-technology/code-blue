class_name Game
extends Node3D
## The world and the whole shift simulation.
##
## The host owns the truth: monsters, items, containers, the shelf, the case on the table,
## damage and phase changes. Every player owns their own surgeon's movement and aim and
## reports it. Clients mirror the host through a 20 Hz snapshot. Solo play is hosting with
## nobody connected.
##
## Level geometry is never networked: each peer builds it locally from the shared seed, so
## anything derived from the level (containers, their ids) matches on every machine.

enum Phase { MENU, LOBBY, SHIFT, WON, LOST }

const SNAPSHOT_HZ := 20.0
const NOISE_MEMORY := 2.0
const SUPPLY_CHECK_SECONDS := 3.0

signal phase_changed(phase: int)
signal notice(text: String, seconds: float)

# ---- replicated state ----
var phase: int = Phase.MENU
var seed_value: int = 0
var shift: int = 1
var world_time: float = 0.0
var vitals: float = 100.0
var punch: float = 0.0
var pod: float = 0.0
var end_timer: float = 0.0
## The patient and ailment on the table this shift: {patient_id, ailment_id, step_index, flags}.
var case: Dictionary = {}
## The OR supply shelf: item kind -> count.
var shelf: Dictionary = {}

# ---- local ----
var level: Node3D = null
var level_info: Dictionary = {}
var players: Dictionary = {}      # peer id -> Player
var monsters: Dictionary = {}     # monster id -> Monster
var world_items: Dictionary = {}  # item id -> WorldItem
var patient_body: Node3D = null
var surgery: Node = null
var shelf_node: Node3D = null
var message: String = ""
var message_timer: float = 0.0
var danger: float = 0.0
var spectating: int = 0
var paused: bool = false

var _entities: Node3D
var _snap_accum: float = 0.0
var _next_monster_id: int = 0
var _next_item_id: int = 0
var _rng := RandomNumberGenerator.new()
var _noises: Array = []
var _footstep_acc: Dictionary = {}
var _supply_timer: float = 0.0
var _botch_say_timer: float = 0.0
var _complication_timer: float = 0.0
var _case_key: String = ""
var _flags_key: String = ""

const PlayerScene := preload("res://scripts/player.gd")
const MonsterScript := preload("res://scripts/monster.gd")
const WorldItemScript := preload("res://scripts/world_item.gd")
const ShelfScript := preload("res://scripts/supply_shelf.gd")
const BodyScript := preload("res://scripts/patient_body.gd")
const SpawnerScript := preload("res://scripts/item_spawner.gd")
const SurgeryScript := preload("res://scripts/surgery/surgery_system.gd")


func _ready() -> void:
	_entities = Node3D.new()
	_entities.name = "Entities"
	add_child(_entities)
	surgery = SurgeryScript.new()
	surgery.name = "Surgery"
	add_child(surgery)
	surgery.setup(self)
	Net.roster_changed.connect(_on_roster_changed)
	Net.host_left.connect(func(): end_session("The host left the game."))


func is_host() -> bool:
	return Net.is_host()


func local_player() -> Node:
	return players.get(Net.my_id())


## Whose eyes we are looking through: yours, or a teammate's while you are dead.
func viewed_player() -> Node:
	var me := local_player()
	if me != null and me.alive:
		return me
	if players.has(spectating) and players[spectating].alive:
		return players[spectating]
	for p in players.values():
		if p.alive:
			return p
	return me


# =========================================================================
# session lifecycle
# =========================================================================

func start_session(first_seed: int) -> void:
	shift = 1
	spectating = 0
	start_lobby(first_seed, 1)


func end_session(reason: String) -> void:
	_clear_case()
	_clear_items()
	_clear_monsters()
	_clear_level()
	for p in players.values():
		p.queue_free()
	players.clear()
	phase = Phase.MENU
	phase_changed.emit(phase)
	if not reason.is_empty():
		notice.emit(reason, 6.0)


## Build the hospital for a shift and put everyone in the clock-in room.
func start_lobby(new_seed: int, new_shift: int) -> void:
	seed_value = new_seed
	shift = new_shift
	_rng.seed = hash(str(new_seed) + "|" + str(new_shift))
	_clear_case()
	_clear_items()
	_clear_monsters()
	_build_level(new_seed)
	vitals = 100.0
	punch = 0.0
	pod = 0.0
	end_timer = 0.0
	world_time = 0.0
	_noises.clear()
	# net: a new hospital invalidates every snapshot baseline; late joiners get to play now.
	waiting_peers.clear()
	if is_host():
		_net_reset_history()
	else:
		_net_client_reset()
	_set_phase(Phase.LOBBY)
	_sync_players()
	for p in players.values():
		_respawn_at_start(p)
	if is_host():
		_spawn_guide()
	# First lobby of the session: build and draw one of everything behind a short cover so
	# nothing hitches the first time it appears later.
	Warmup.run(self)
	say("Shift %d. Hold E at the time clock when everyone is ready." % shift, 6.0)
	if is_host() and Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


## Host only: the patient arrives, supplies scatter, monsters wake up.
func begin_shift() -> void:
	if not is_host():
		return
	var roll := Procedures.roll(seed_value, shift)
	case = {"patient_id": roll.patient, "ailment_id": roll.ailment, "step_index": 0, "flags": {}}
	vitals = 100.0
	shelf = {}
	_apply_case_locally()
	_spawn_supplies()
	_spawn_monsters()
	_set_phase(Phase.SHIFT)
	_broadcast("sound", {"cue": "punch"})
	Audio.play("punch")
	var pt := Procedures.patient(case.patient_id)
	var ail := Procedures.ailment(case.ailment_id)
	say("Incoming: %s. %s. %s" % [pt.full_name, ail.name, Procedures.blurb(case.patient_id, case.ailment_id)], 8.0)
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


func _set_phase(p: int) -> void:
	if phase == p:
		return
	phase = p
	phase_changed.emit(p)


func _end_shift(won: bool, text: String) -> void:
	_set_phase(Phase.WON if won else Phase.LOST)
	end_timer = C.END_SCREEN_SECONDS
	Audio.sting("saved" if won else "flatline")
	if not won and patient_body != null and patient_body.has_method("flatline"):
		patient_body.flatline()
	say(text, C.END_SCREEN_SECONDS)
	if Net.active:
		_rpc_shift.rpc(seed_value, shift, phase, _net_seq)


func say(text: String, seconds: float = 3.0) -> void:
	message = text
	message_timer = seconds
	notice.emit(text, seconds)
	if is_host():
		_broadcast("say", {"text": text, "secs": seconds})


## A message only one player sees.
func tell(p: Node, text: String, seconds: float = 2.5) -> void:
	if p == null:
		return
	if p.is_local:
		message = text
		message_timer = seconds
		notice.emit(text, seconds)
	elif Net.active and is_host():
		_event.rpc_id(p.peer_id, "say", {"text": text, "secs": seconds})


## Tell the other machines about a one-off thing. Solo has nobody to tell.
func _broadcast(kind: String, data: Dictionary) -> void:
	if Net.active and is_host():
		_event.rpc(kind, data)


func _sound(cue: String, at = null) -> void:
	Audio.play(cue, at)
	_broadcast("sound", {"cue": cue, "at": at})


# =========================================================================
# level
# =========================================================================

func _build_level(for_seed: int) -> void:
	_clear_level()
	level_info = {}
	var gen: Dictionary = {}
	var mapgen_path := "res://scripts/mapgen.gd"
	var builder_path := "res://scripts/hospital_builder.gd"
	if ResourceLoader.exists(mapgen_path) and ResourceLoader.exists(builder_path):
		var MapGenScript: GDScript = load(mapgen_path)
		var BuilderScript: GDScript = load(builder_path)
		gen = MapGenScript.generate(for_seed)
		level = BuilderScript.build(gen, level_info)
	# A level missing its landmarks is worse than no level; fall back rather than ship a broken shift.
	if level == null or not _level_info_usable():
		if level != null:
			push_warning("Generated level for seed %d was incomplete; using the fallback ward." % for_seed)
			level.queue_free()
		level_info = {}
		var FallbackScript: GDScript = load("res://scripts/fallback_level.gd")
		level = FallbackScript.build(level_info)
	level.name = "Level"
	add_child(level)
	_attach_light_flicker(level)
	_add_occluders()
	_add_landmarks()


func _level_info_usable() -> bool:
	return level_info.get("player_spawns", []).size() >= 1 \
		and level_info.get("tool_spawns", []).size() >= Items.SURGICAL.size() \
		and level_info.get("monster_spawns", []).size() >= 1 \
		and level_info.has("table") and level_info.has("clock") and level_info.has("pod")


## Ceiling fixtures flicker, buzz and die. The behaviour lives in the look pass;
## here we just hand each one its controller.
func _attach_light_flicker(root: Node) -> void:
	var path := "res://scripts/light_flicker.gd"
	if not ResourceLoader.exists(path):
		return
	var Flicker: GDScript = load(path)
	for node in root.find_children("*", "Light3D", true, false):
		if not node.is_in_group("fixture"):
			continue
		if not node.has_meta("seed"):
			node.set_meta("seed", hash(str(seed_value) + str(node.get_path())))
		# A hospital's worth of fixtures is too many to light at once on a laptop.
		# Anything well past the fog's reach contributes nothing you can see.
		node.distance_fade_enabled = true
		node.distance_fade_begin = 16.0
		node.distance_fade_length = 6.0
		node.add_child(Flicker.new())


## Walls, as a occluder mesh. Indoors this is the single biggest performance win:
## without it the renderer draws the entire hospital from inside one corridor.
func _add_occluders() -> void:
	var rows: PackedStringArray = level_info.get("rows", PackedStringArray())
	if rows.is_empty():
		return
	var h := rows.size()
	var w: int = rows[0].length()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for ty in h:
		for tx in w:
			if rows[ty][tx] != "#":
				continue
			for d in dirs:
				var nx: int = tx + d.x
				var ny: int = ty + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h:
					continue
				if rows[ny][nx] == "#":
					continue  # interior face, never visible
				# The quad on this tile's boundary facing the open neighbour.
				var cx := (tx + 0.5) * C.TILE
				var cz := (ty + 0.5) * C.TILE
				var half := C.TILE * 0.5
				var ox: float = d.x * half
				var oz: float = d.y * half
				var ax: float = half if d.x == 0 else 0.0
				var az: float = half if d.y == 0 else 0.0
				var base := verts.size()
				verts.append(Vector3(cx + ox - ax, 0.0, cz + oz - az))
				verts.append(Vector3(cx + ox + ax, 0.0, cz + oz + az))
				verts.append(Vector3(cx + ox + ax, C.WALL_H, cz + oz + az))
				verts.append(Vector3(cx + ox - ax, C.WALL_H, cz + oz - az))
				# Two triangles, both windings: an occluder is not lit, so facing does not matter,
				# and doubling them keeps the rasteriser from missing a wall seen from behind.
				for t in [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]:
					idx.append(base + t)
	if verts.is_empty():
		return
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var node := OccluderInstance3D.new()
	node.name = "WallOccluders"
	node.occluder = occ
	level.add_child(node)


func _clear_level() -> void:
	if level != null and is_instance_valid(level):
		level.queue_free()
	level = null
	shelf_node = null


func spawn_points() -> Array:
	return level_info.get("player_spawns", [Vector3.ZERO])


func table_pos() -> Vector3:
	return level_info.get("table", Vector3.ZERO)


func clock_pos() -> Vector3:
	return level_info.get("clock", Vector3.ZERO)


func pod_pos() -> Vector3:
	return level_info.get("pod", Vector3.ZERO)


## The OR supply shelf and the aimable spots for the time clock, the pod and the table.
func _add_landmarks() -> void:
	var sinfo: Dictionary = level_info.get("shelf", {})
	var spos: Vector3 = sinfo.get("position", table_pos() + Vector3(2.2, 0.0, 1.4))
	shelf_node = ShelfScript.create()
	level.add_child(shelf_node)
	shelf_node.global_position = spos
	shelf_node.rotation.y = float(sinfo.get("yaw", 0.0))
	shelf_node.show_stock(shelf)

	_add_proxy("clock", clock_pos() + Vector3.UP * 1.1, 0.7, C.PUNCH_SECONDS,
		func(p): return "Hold E: clock in" if phase == Phase.LOBBY else "")
	_add_proxy("pod", pod_pos() + Vector3.UP * 1.1, 0.8, C.POD_SECONDS,
		func(p): return _pod_prompt())
	_add_proxy("table", table_pos() + Vector3.UP * 1.1, 1.2, 0.0,
		func(p): return _table_prompt(p))


class Proxy extends Area3D:
	var hold: float = 0.0
	var prompt_fn: Callable
	func interact_prompt(p) -> String: return prompt_fn.call(p)
	func interact_hold() -> float: return hold
	func interact(p) -> void:
		var g = get_tree().get_first_node_in_group("game")
		if g != null:
			g._proxy_used(get_meta("interact_id"), p)


func _add_proxy(id: String, pos: Vector3, radius: float, hold: float, prompt_fn: Callable) -> void:
	var a := Proxy.new()
	a.name = "Aim_%s" % id
	a.hold = hold
	a.prompt_fn = prompt_fn
	a.collision_layer = C.L_INTERACT
	a.collision_mask = 0
	a.monitoring = false
	a.add_to_group("interactable")
	a.set_meta("interact_id", id)
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	cs.shape = sph
	a.add_child(cs)
	level.add_child(a)
	a.global_position = pos


func _pod_prompt() -> String:
	if phase != Phase.SHIFT:
		return ""
	var dead := _longest_dead()   # net: never a peer waiting for the next shift
	if dead != null:
		return "Hold E: revive %s" % dead.player_name
	return "!Re-Gen Pod: nobody to revive"


func _table_prompt(p) -> String:
	if phase != Phase.SHIFT or case.is_empty():
		return ""
	var step := Procedures.step(case.ailment_id, int(case.step_index))
	if step.is_empty():
		return ""
	var why: String = surgery.can_begin(p)
	if why != "":
		return "!" + why
	return "Operate: %s" % step.label


func _proxy_used(id: String, p: Node) -> void:
	if id == "table" and phase == Phase.SHIFT:
		var why: String = surgery.can_begin(p)
		if why == "":
			surgery.begin(p)
		else:
			tell(p, why)


func find_interactable(id: String) -> Node:
	if id == "":
		return null
	for n in get_tree().get_nodes_in_group("interactable"):
		if n.has_meta("interact_id") and n.get_meta("interact_id") == id:
			return n
	return null


# =========================================================================
# players
# =========================================================================

func _on_roster_changed() -> void:
	if phase != Phase.MENU:
		_sync_players()


## One Player node per peer in the roster; spawn points are keyed by peer id so
## every machine puts everyone in the same place without talking about it.
func _sync_players() -> void:
	var ids := Net.peer_ids()
	for id in ids:
		if players.has(id):
			continue
		var p: CharacterBody3D = PlayerScene.new_player(id, Net.name_for(id), id == Net.my_id())
		players[id] = p
		_entities.add_child(p)
		_respawn_at_start(p)
		# net: joining mid-shift means watching until the next lobby.
		if is_host() and phase != Phase.LOBBY:
			_hold_until_next_shift(p)
			say("%s joined. They clock in at the next shift." % Net.name_for(id), 3.0)
		elif not is_host() and _recv_states.has(_recv_latest) and _recv_states[_recv_latest].pl.has(id):
			p.apply_remote_full(_recv_states[_recv_latest].pl[id])
	for id in players.keys():
		if not ids.has(id):
			var gone: Node = players[id]
			if is_host():
				# net: a leaver's supplies land where they stood; an operation pauses for someone else.
				var dropped := _drop_hands_in_place(gone)
				surgery.end(gone)
				_net_acks.erase(id)
				_net_keyframe_at.erase(id)
				waiting_peers.erase(id)
				if phase == Phase.SHIFT:
					say("%s left the shift.%s" % [gone.player_name, " What they carried is on the floor." if dropped else ""], 3.0)
			gone.queue_free()
			players.erase(id)


func _respawn_at_start(p: Node) -> void:
	var spots := spawn_points()
	var idx: int = maxi(0, Net.peer_ids().find(p.peer_id))
	p.teleport(spots[idx % spots.size()])
	p.revive_full()


func alive_players() -> Array:
	var out := []
	for p in players.values():
		if p.alive:
			out.append(p)
	return out


func _longest_dead() -> Node:
	var best: Node = null
	for p in players.values():
		if not p.alive and not waiting_peers.has(p.peer_id) and (best == null or p.dead_time > best.dead_time):
			best = p
	return best


# =========================================================================
# interaction (host)
# =========================================================================

## Called by a Player on the host whenever its interact counter moved.
func player_pressed_interact(p: Node, target_id: String) -> void:
	if not is_host() or not p.alive:
		return
	var node := find_interactable(target_id)
	if node == null or not _within_reach(p, node):
		return
	if node.interact_hold() > 0.0:
		return  # holds are simulated every frame (clock, pod)
	if node.interact_prompt(p).begins_with("!") or node.interact_prompt(p) == "":
		return
	node.interact(p)


func _within_reach(p: Node, node: Node) -> bool:
	var eye: Vector3 = p.head.global_position
	var target: Vector3 = node.global_position if node is Node3D else eye
	return eye.distance_to(target) <= C.INTERACT_RANGE + 1.2


func _holding_aim(id: String) -> bool:
	for p in alive_players():
		if p.wants_interact and p.aim_id == id:
			var node := find_interactable(id)
			if node != null and _within_reach(p, node):
				return true
	return false


# =========================================================================
# items, hands and the shelf (host)
# =========================================================================

func _spawn_item(kind: String, count: int, xf: Transform3D, state: int, ct_id := "", slot := 0, anchor := -1) -> Node:
	var it: WorldItem = WorldItemScript.new_item(_next_item_id, kind, count)
	_next_item_id += 1
	it.container_id = ct_id
	it.slot = slot
	it.anchor = anchor
	world_items[it.item_id] = it
	_entities.add_child(it)
	it.place(xf, state)
	return it


func _clear_items() -> void:
	for it in world_items.values():
		if is_instance_valid(it):
			it.queue_free()
	world_items.clear()
	_next_item_id = 0


func _spawn_supplies() -> void:
	var plan: Array = SpawnerScript.plan(seed_value, shift, case.ailment_id, level_info)
	for e in plan:
		_spawn_from_plan(e)


func _spawn_from_plan(e: Dictionary) -> void:
	var anchors: Array = level_info.get("loose_anchors", [])
	var ct_id: String = String(e.get("container_id", ""))
	if ct_id != "":
		var ct := find_interactable(ct_id)
		if ct != null and ct.has_method("slot_transform"):
			var slot_i := int(e.get("slot", 0))
			_spawn_item(e.kind, int(e.count), ct.slot_transform(slot_i), WorldItem.State.IN_CONTAINER, ct_id, slot_i)
			return
	var anchor_i := int(e.get("anchor", -1))
	if anchor_i >= 0 and anchor_i < anchors.size():
		var a: Dictionary = anchors[anchor_i]
		var xf := Transform3D(Basis(Vector3.UP, float(a.get("yaw", 0.0))), a.position)
		_spawn_item(e.kind, int(e.count), xf, WorldItem.State.LOOSE, "", 0, anchor_i)
		return
	# No container or anchor: drop it on the floor at a spawn point well away from the OR.
	var spots: Array = level_info.get("tool_spawns", [])
	var pos: Vector3 = spots[_rng.randi_range(0, spots.size() - 1)] if spots.size() > 0 else table_pos() + Vector3(4, 0, 0)
	_spawn_item(e.kind, int(e.count), Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), _floor_at(pos)), WorldItem.State.LOOSE)


func _spawn_guide() -> void:
	for it in world_items.values():
		if it.kind == "guide":
			return
	for p in players.values():
		for s in p.slots:
			if s.kind == "guide":
				return
	# The lectern knows where a book rests on its tilted desk; use that when it is there.
	var lectern = level_info.get("lectern_node")
	if lectern != null and is_instance_valid(lectern) and lectern.is_inside_tree() and lectern.has_meta("book_rest"):
		var rest: Transform3D = lectern.global_transform * (lectern.get_meta("book_rest") as Transform3D)
		_spawn_item("guide", 1, rest, WorldItem.State.ON_LECTERN)
		return
	var info: Dictionary = level_info.get("lectern", {})
	var base: Vector3 = info.get("position", clock_pos() + Vector3(1.6, 0.0, 0.0))
	var top := _surface_below(base + Vector3.UP * 2.0, base)
	var xf := Transform3D(Basis(Vector3.UP, float(info.get("yaw", 0.0))), top)
	_spawn_item("guide", 1, xf, WorldItem.State.ON_LECTERN)


func pickup_item(p: Node, it: Node) -> void:
	if not is_host() or not is_instance_valid(it) or not world_items.has(it.item_id):
		return
	var i: int = p.slot_for(it.kind)
	if i < 0:
		tell(p, "Your hands are full.")
		return
	if p.slots[i].kind == it.kind:
		p.slots[i].count += it.count
	else:
		p.slots[i] = {"kind": it.kind, "count": it.count}
	p.selected = i
	var pos: Vector3 = it.global_position
	world_items.erase(it.item_id)
	it.queue_free()
	_sound("pickup", pos)
	emit_noise(pos, 0.15, "pickup")


## G: set the selected stack down gently in front of you. Nothing breaks.
func drop_selected(p: Node) -> void:
	if not is_host():
		return
	var s: Dictionary = p.slots[p.selected]
	if s.kind == "":
		return
	var fwd: Vector3 = -p.camera.global_transform.basis.z
	var from := Transform3D(p.global_basis, p.head.global_position + fwd * 0.5 + Vector3.DOWN * 0.3)
	var it := _spawn_item(s.kind, s.count, from, WorldItem.State.LOOSE)
	it.toss(from, fwd * 1.2 + Vector3.UP * 0.6 + p.velocity * 0.5)
	p.slots[p.selected] = {"kind": "", "count": 0}
	_sound("thud", from.origin)
	emit_noise(from.origin, 0.4, "drop")


## Hit, shoved or gone: both hands let go and fragile stacks lose some of their contents.
func _drop_hands(p: Node, violent: bool) -> void:
	var broke := false
	for i in p.slots.size():
		var s: Dictionary = p.slots[i]
		if s.kind == "":
			continue
		var n: int = s.count
		if violent:
			var survivors := Items.survivors_after_drop(s.kind, n)
			broke = broke or survivors < n
			n = survivors
		var dir := Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)).normalized()
		var from := Transform3D(Basis(), p.global_position + Vector3.UP * 1.1 + dir * 0.3)
		var it := _spawn_item(s.kind, n, from, WorldItem.State.LOOSE)
		it.toss(from, dir * randf_range(2.0, 3.5) + Vector3.UP * 2.0)
		p.slots[i] = {"kind": "", "count": 0}
		emit_noise(from.origin, 0.4, "drop")
	if broke:
		_sound("items_glass", p.global_position)
		emit_noise(p.global_position, 0.9, "glass")
		say("%s dropped the vials. Some of them smashed." % p.player_name, 3.0)


func shelf_place(p: Node) -> void:
	if not is_host():
		return
	var s: Dictionary = p.slots[p.selected]
	if s.kind == "" or not Items.is_surgical(s.kind):
		return
	shelf[s.kind] = int(shelf.get(s.kind, 0)) + int(s.count)
	p.slots[p.selected] = {"kind": "", "count": 0}
	if shelf_node != null:
		shelf_node.show_stock(shelf)
		_sound("items_clink", shelf_node.global_position)
	say("%s put %s on the supply shelf." % [p.player_name, Items.display_name(s.kind)], 3.0)


func shelf_count(kind: String) -> int:
	return int(shelf.get(kind, 0))


## Everything of a kind that still exists anywhere: shelf, hands, floors and containers.
func supply_count(kind: String) -> int:
	var n := shelf_count(kind)
	for it in world_items.values():
		if it.kind == kind:
			n += it.count
	for p in players.values():
		for s in p.slots:
			if s.kind == kind:
				n += int(s.count)
	return n


## If breakage ever leaves the shift unwinnable, quietly put more supply somewhere far away.
func _check_supply() -> void:
	if case.is_empty():
		return
	var need := Procedures.remaining_requirements(case.ailment_id, int(case.step_index))
	var have := {}
	var short := false
	for kind in need.keys():
		have[kind] = supply_count(kind)
		if int(have[kind]) < int(need[kind]):
			short = true
	if not short:
		return
	var occupied := {}
	for it in world_items.values():
		if it.state == WorldItem.State.IN_CONTAINER:
			occupied["%s:%d" % [it.container_id, it.slot]] = true
		elif it.anchor >= 0:
			occupied["anchor:%d" % it.anchor] = true
	var avoid := []
	for p in players.values():
		avoid.append(p.global_position)
	avoid.append(table_pos())
	var plan: Array = SpawnerScript.shortfall_plan(seed_value + shift * 97 + int(world_time), need, have, level_info, occupied, avoid)
	for e in plan:
		_spawn_from_plan(e)


func _floor_at(p: Vector3) -> Vector3:
	return _surface_below(p + Vector3.UP * 1.5, p + Vector3.DOWN)


func _surface_below(from: Vector3, fallback: Vector3) -> Vector3:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 4.0)
	q.collision_mask = C.L_WORLD
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if not hit.is_empty() else fallback


# =========================================================================
# the case on the table
# =========================================================================

## Build or update the patient on the table and the surgery system to match `case`.
## Runs on every machine; idempotent.
func _apply_case_locally() -> void:
	var key := "" if case.is_empty() else "%s|%s" % [case.patient_id, case.ailment_id]
	if key != _case_key:
		_case_key = key
		_flags_key = ""
		if patient_body != null and is_instance_valid(patient_body):
			patient_body.queue_free()
		patient_body = null
		if key == "":
			surgery.clear_case()
			return
		var top := _surface_below(table_pos() + Vector3.UP * 3.0, table_pos() + Vector3.UP * 0.95)
		patient_body = BodyScript.create(case.patient_id)
		_entities.add_child(patient_body)
		patient_body.global_position = top
		patient_body.rotation.y = _table_yaw()
		if patient_body.has_method("set_ailment"):
			patient_body.set_ailment(case.ailment_id)
		surgery.start_case(case.patient_id, case.ailment_id)
	var fk := str(case.get("flags", {})) + str(case.get("step_index", 0))
	if fk != _flags_key and patient_body != null:
		_flags_key = fk
		if patient_body.has_method("apply_flags"):
			patient_body.apply_flags(case.get("flags", {}))


## The operating table's long axis runs along world X unless the level says otherwise.
func _table_yaw() -> float:
	return float(level_info.get("table_yaw", 0.0))


func _clear_case() -> void:
	case = {}
	shelf = {}
	_apply_case_locally()
	if shelf_node != null and is_instance_valid(shelf_node):
		shelf_node.show_stock(shelf)


## Host: a surgery mistake. Costs vitals and nothing else.
func surgery_botch(amount: float, reason: String) -> void:
	if not is_host() or phase != Phase.SHIFT:
		return
	vitals -= amount
	if reason != "" and _botch_say_timer <= 0.0:
		_botch_say_timer = 2.0
		say(reason, 1.8)
	if amount >= 0.5 and _complication_timer <= 0.0:
		_complication_timer = 1.2
		_sound("complication", table_pos())


## Host: the current step is finished. Uses up its supplies, remembers its result, moves on.
func surgery_step_done(result: Dictionary) -> void:
	if not is_host() or phase != Phase.SHIFT or case.is_empty():
		return
	var step := Procedures.step(case.ailment_id, int(case.step_index))
	if step.is_empty():
		return
	var uses := int(step.uses)
	if uses > 0:
		shelf[step.item] = maxi(0, shelf_count(step.item) - uses)
	var flags: Dictionary = case.get("flags", {})
	flags.merge(result, true)
	case.flags = flags
	case.step_index = int(case.step_index) + 1
	vitals = minf(100.0, vitals + 8.0)
	if shelf_node != null:
		shelf_node.show_stock(shelf)
	_apply_case_locally()
	_sound("step_done", table_pos())
	var next := Procedures.step(case.ailment_id, int(case.step_index))
	if next.is_empty():
		_end_shift(true, "%s is stable. Punch out!" % Procedures.patient(case.patient_id).name)
	else:
		say("Done: %s. Next: %s (%s)." % [step.label, next.label, Items.display_name(next.item)], 4.0)


## Client operator -> host. On the host itself it goes straight to the surgery system.
func send_operator_report(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(Net.my_id(), report)
	elif Net.active:
		if report.has("botches") or report.has("finished") or report.has("exit") or report.has("reliable"):
			_rpc_operator_report_reliable.rpc_id(Net.HOST_ID, report)
		else:
			_rpc_operator_report.rpc_id(Net.HOST_ID, report)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_operator_report(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(multiplayer.get_remote_sender_id(), report)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_operator_report_reliable(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(multiplayer.get_remote_sender_id(), report)


# =========================================================================
# noise and perception (host)
# =========================================================================

func emit_noise(pos: Vector3, loudness: float, kind: String) -> void:
	if not is_host():
		return
	_noises.append({"pos": pos, "loudness": loudness, "kind": kind, "time": world_time})


func recent_noises(max_age: float = 1.5) -> Array:
	var out := []
	for n in _noises:
		if world_time - float(n.time) <= max_age:
			out.append(n)
	return out


func _tick_noise(delta: float) -> void:
	var cut := world_time - NOISE_MEMORY
	while not _noises.is_empty() and float(_noises[0].time) < cut:
		_noises.pop_front()
	for p in alive_players():
		if not p.moving:
			_footstep_acc[p.peer_id] = 0.0
			continue
		var acc: float = float(_footstep_acc.get(p.peer_id, 0.0)) + delta
		var interval := 0.3 if p.sprinting else 0.5
		if acc >= interval:
			acc = 0.0
			emit_noise(p.global_position, 0.8 if p.sprinting else 0.25, "footstep")
		_footstep_acc[p.peer_id] = acc


## Any living surgeon's flashlight shining on this point.
func point_is_lit(p: Vector3) -> bool:
	for pl in players.values():
		if pl.alive and pl.lights_point(p):
			return true
	return false


# =========================================================================
# monsters
# =========================================================================

func _spawn_monsters() -> void:
	_clear_monsters()
	var roster: Array = MonsterScript.roster(shift, players.size())
	var spots: Array = level_info.get("monster_spawns", []).duplicate()
	_shuffle(spots, _rng)
	for i in roster.size():
		var pos: Vector3 = spots[i % maxi(1, spots.size())] if spots.size() > 0 else Vector3.ZERO
		_add_monster(roster[i], pos)


func _add_monster(kind: String, pos: Vector3) -> Node:
	var m: CharacterBody3D = MonsterScript.new_monster(_next_monster_id, kind, pos)
	monsters[_next_monster_id] = m
	_next_monster_id += 1
	_entities.add_child(m)
	return m


func _clear_monsters() -> void:
	for m in monsters.values():
		m.queue_free()
	monsters.clear()
	_next_monster_id = 0


# =========================================================================
# frame
# =========================================================================

func _physics_process(delta: float) -> void:
	if phase == Phase.MENU:
		return
	if paused and Net.solo:
		return
	world_time += delta
	message_timer = maxf(0.0, message_timer - delta)
	_botch_say_timer = maxf(0.0, _botch_say_timer - delta)
	_complication_timer = maxf(0.0, _complication_timer - delta)

	if is_host():
		_simulate(delta)
	surgery.physics_tick(delta)
	if patient_body != null and is_instance_valid(patient_body):
		if patient_body.has_method("set_vitals"):
			patient_body.set_vitals(vitals)
		if patient_body.has_method("set_sedation"):
			patient_body.set_sedation(float(case.get("flags", {}).get("sedation", 0.0)))

	_update_danger()
	_net_tick(delta)


func _simulate(delta: float) -> void:
	_tick_noise(delta)
	var op: int = surgery.operator_peer() if surgery.has_method("operator_peer") else 0
	for p in players.values():
		p.operating = p.peer_id == op
	match phase:
		Phase.LOBBY:
			_sim_lobby(delta)
		Phase.SHIFT:
			_sim_shift(delta)
		Phase.WON, Phase.LOST:
			end_timer -= delta
			if end_timer <= 0.0:
				var won := phase == Phase.WON
				start_lobby(seed_value + 1, shift + 1 if won else shift)


func _sim_lobby(delta: float) -> void:
	if _holding_aim("clock"):
		punch = minf(1.0, punch + delta / C.PUNCH_SECONDS)
		if punch >= 1.0:
			punch = 0.0
			begin_shift()
	else:
		punch = maxf(0.0, punch - delta * 1.5)


func _sim_shift(delta: float) -> void:
	var living := alive_players()

	# The patient is always dying.
	var drain: float = C.VITALS_DRAIN_SECONDS * pow(0.85, shift - 1)
	vitals -= delta * 100.0 / drain

	_sim_pod(delta, living)

	_supply_timer -= delta
	if _supply_timer <= 0.0:
		_supply_timer = SUPPLY_CHECK_SECONDS
		_check_supply()

	if vitals <= 0.0:
		vitals = 0.0
		_end_shift(false, "The patient flatlined.")
	elif living.is_empty():
		_end_shift(false, "Everyone is dead. The patient is next.")


func _sim_pod(delta: float, _living: Array) -> void:
	var dead := _longest_dead()
	if dead == null:
		pod = 0.0
		return
	if not _holding_aim("pod"):
		pod = maxf(0.0, pod - delta)
		return
	pod = minf(1.0, pod + delta / C.POD_SECONDS)
	if pod >= 1.0:
		pod = 0.0
		var spot := _scatter_spot(pod_pos())
		dead.teleport(spot)
		dead.revive(2)
		_broadcast("revive", {"id": dead.peer_id, "pos": spot})
		Audio.play("revive", spot)
		say("%s crawled out of the Re-Gen Pod. Mostly intact." % dead.player_name, 4.0)


func _scatter_spot(from: Vector3) -> Vector3:
	for i in 24:
		var a := randf() * TAU
		var r := randf_range(1.0, 2.6)
		var candidate := from + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if _point_is_clear(candidate):
			return candidate
	return from


func _point_is_clear(p: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	q.shape = shape
	q.transform = Transform3D(Basis(), p + Vector3.UP * 0.4)
	q.collision_mask = C.L_WORLD
	return space.intersect_shape(q, 1).is_empty()


func _update_danger() -> void:
	var view := viewed_player()
	if view == null or phase != Phase.SHIFT:
		danger = 0.0
	else:
		var nearest := 999.0
		for m in monsters.values():
			nearest = minf(nearest, m.global_position.distance_to(view.global_position))
		danger = clampf(1.0 - nearest / 14.0, 0.0, 1.0)
	Audio.heartbeat(danger)
	var hunting := false
	for m in monsters.values():
		if m.state == MonsterScript.State.CHASE:
			hunting = true
			break
	var operating := false
	for p in players.values():
		if p.operating:
			operating = true
			break
	var level_intensity := 0.0
	if phase == Phase.SHIFT:
		level_intensity = 2.0 if operating else (1.0 if hunting else minf(0.6, danger))
	Audio.set_music_intensity(level_intensity)


# =========================================================================
# damage
# =========================================================================

## Host only. A monster connected with a surgeon.
func monster_hit_player(m: Node, p: Node) -> void:
	if not is_host() or not p.alive or p.invuln > 0.0:
		return
	var dmg: int = m.damage
	var knock: Vector3 = (p.global_position - m.global_position).normalized() * m.knockback
	p.take_hit(dmg, knock)
	_broadcast("hit", {"id": p.peer_id, "hp": p.hp, "knock": knock})
	Audio.play("hurt", p.global_position)
	surgery.end(p)
	_drop_hands(p, true)
	m.recoil_after_hit()
	if not p.alive:
		Audio.play("flatline", p.global_position)
		say("%s is down. The Re-Gen Pod can bring them back." % p.player_name if players.size() > 1
			else "You are down.", 4.0)


## Host only. Someone pressed Q.
func player_shoved(p: Node) -> void:
	if not is_host():
		return
	_sound("shove", p.global_position)
	emit_noise(p.global_position, 0.6, "shove")
	var forward: Vector3 = -p.global_transform.basis.z
	for m in monsters.values():
		if not _in_shove_cone(p, m.global_position, forward):
			continue
		m.shoved(forward)
		_sound("thud", m.global_position)
	for q in players.values():
		if q == p or not q.alive or not _in_shove_cone(p, q.global_position, forward):
			continue
		var knock := forward * 11.0 + Vector3.UP * 2.0
		q.apply_knock(knock)
		_broadcast("shoved", {"id": q.peer_id, "knock": knock})
		surgery.end(q)
		if q.hands_empty():
			say("%s shoved %s. Very professional." % [p.player_name, q.player_name], 3.0)
		else:
			_drop_hands(q, true)
			say("%s shoved %s. Supplies everywhere." % [p.player_name, q.player_name], 3.0)


func _in_shove_cone(from: Node, target: Vector3, forward: Vector3) -> bool:
	var to_target: Vector3 = target - from.global_position
	to_target.y = 0.0
	if to_target.length() > C.SHOVE_RANGE:
		return false
	return forward.normalized().dot(to_target.normalized()) > 0.6


# =========================================================================
# networking
# =========================================================================
#
# Snapshots (host -> each client, unreliable, SNAPSHOT_HZ):
#   The host builds one "state" per tick: sections of entity reports keyed by id
#     g   the global fields (time, phase, vitals, case, shelf, surgery, waiting peers)
#     pl  players, mo monsters, it world items: id -> report dictionary
#     ct  open containers: interact_id -> true (absent means closed)
#   Each client acks the last snapshot it decoded (field "ak" of its player state). The host
#   keeps the last HISTORY states and sends each client only what differs from the state that
#   client acked: new or changed entities (only their changed fields) and removed ids. Loss
#   costs nothing but a slightly larger next delta, because the base is always something the
#   client provably has. A full keyframe goes out when the client has acked nothing usable
#   and every KEYFRAME_SECONDS regardless, so any divergence heals.
#   Wire format: {s: seq, b: base seq (0 = keyframe), g: {fields}, pl/mo/it/ct: {id: fields},
#                 x: {section: [removed ids]}}; empty parts are omitted.
# Discrete one-off things (sounds, messages, hits, phase changes) stay reliable RPCs.
#
# Joining mid-shift: a peer that arrives outside the lobby waits as a spectator (not alive,
# in `waiting_peers`, ignored by the Re-Gen Pod) and spawns with everyone at the next lobby.
# Leaving: the host drops what the leaver carried where it stood (nothing breaks) and ends
# its operation; the step keeps its progress for whoever operates next.

const KEYFRAME_SECONDS := 10.0
const HISTORY := 100   # 5 s of snapshots: a client that stalls or lags still has a usable base
const SECTIONS := ["pl", "mo", "it", "ct"]

## Peers that joined mid-shift and spectate until the next lobby: peer id -> true. Replicated.
var waiting_peers: Dictionary = {}

## Test instrumentation: when set, counts the serialized size of every snapshot sent.
var net_measure := false
var net_payload_bytes: int = 0
var net_section_bytes: Dictionary = {}

# host
var _net_seq: int = 0
var _net_history: Dictionary = {}     # seq -> state
var _net_acks: Dictionary = {}        # peer id -> last seq that peer decoded
var _net_keyframe_at: Dictionary = {} # peer id -> world_time of its last keyframe
# client
var _recv_states: Dictionary = {}     # seq -> decoded state
var _recv_latest: int = 0
var _recv_floor: int = 0              # snapshots at or below this seq predate the current lobby


func _net_tick(delta: float) -> void:
	if not Net.active:
		return
	_snap_accum += delta
	if _snap_accum < 1.0 / SNAPSHOT_HZ:
		return
	_snap_accum = 0.0
	if is_host():
		if Net.names.size() > 1:
			_send_snapshots()
	else:
		var me := local_player()
		var ack := _recv_latest if _recv_states.has(_recv_latest) else 0
		_player_state.rpc_id(Net.HOST_ID, ack, me.report_state() if me != null else [])


## Host: build this tick's state and send every client its delta.
func _send_snapshots() -> void:
	_net_seq += 1
	var state := _build_state()
	_net_history[_net_seq] = state
	_net_history.erase(_net_seq - HISTORY)
	var cache := {}   # base seq -> encoded message, shared by clients on the same base
	for id in Net.peer_ids():
		if id == Net.HOST_ID:
			continue
		var base_seq := int(_net_acks.get(id, 0))
		if not _net_history.has(base_seq) or world_time - float(_net_keyframe_at.get(id, -INF)) >= KEYFRAME_SECONDS:
			base_seq = 0
		if base_seq == 0:
			_net_keyframe_at[id] = world_time
		if not cache.has(base_seq):
			cache[base_seq] = _encode_delta(_net_history.get(base_seq, {}), state, _net_seq, base_seq)
		var msg: Dictionary = cache[base_seq]
		if net_measure:
			net_payload_bytes += var_to_bytes(msg).size()
			for k in msg.keys():
				net_section_bytes[k] = int(net_section_bytes.get(k, 0)) + var_to_bytes(msg[k]).size()
			if base_seq == 0:
				net_section_bytes["keyframes"] = int(net_section_bytes.get("keyframes", 0)) + var_to_bytes(msg).size()
				net_section_bytes["keyframe_count"] = int(net_section_bytes.get("keyframe_count", 0)) + 1
		_snapshot.rpc_id(id, msg)


func _build_state() -> Dictionary:
	var pl := {}
	for p in players.values():
		pl[p.peer_id] = p.report_full()
	var mo := {}
	for m in monsters.values():
		mo[m.monster_id] = m.report()
	var it := {}
	for i in world_items.values():
		it[i.item_id] = i.report()
	var ct := {}
	for n in get_tree().get_nodes_in_group("container"):
		if n.has_meta("interact_id") and n.has_method("is_open") and n.is_open():
			ct[String(n.get_meta("interact_id"))] = true
	return {"g": _global_fields(), "pl": pl, "mo": mo, "it": it, "ct": ct}


static func _encode_delta(base: Dictionary, state: Dictionary, seq: int, base_seq: int) -> Dictionary:
	var msg := {"s": seq, "b": base_seq}
	var gd := _diff_fields(base.get("g", {}), state.g)
	if not gd.is_empty():
		msg["g"] = gd
	var removed := {}
	for sec in SECTIONS:
		var old: Dictionary = base.get(sec, {})
		var cur: Dictionary = state[sec]
		var changed := {}
		for id in cur.keys():
			var v = cur[id]
			if not old.has(id):
				changed[id] = v
			elif v is Dictionary:
				var d := _diff_fields(old[id], v)
				if not d.is_empty():
					changed[id] = d
			elif _differs(old[id], v):
				changed[id] = v
		if not changed.is_empty():
			msg[sec] = changed
		var gone := []
		for id in old.keys():
			if not cur.has(id):
				gone.append(id)
		if not gone.is_empty():
			removed[sec] = gone
	if not removed.is_empty():
		msg["x"] = removed
	return msg


## The fields of `cur` that differ from `old`; fields that disappeared are listed under "~".
static func _diff_fields(old: Dictionary, cur: Dictionary) -> Dictionary:
	var d := {}
	for k in cur.keys():
		if not old.has(k) or _differs(old[k], cur[k]):
			d[k] = cur[k]
	var gone := []
	for k in old.keys():
		if not cur.has(k):
			gone.append(k)
	if not gone.is_empty():
		d["~"] = gone
	return d


static func _differs(a, b) -> bool:
	return typeof(a) != typeof(b) or a != b


static func _merge_fields(old: Dictionary, d: Dictionary) -> Dictionary:
	var out := old.duplicate()
	for k in d.get("~", []):
		out.erase(k)
	out.merge(d, true)
	out.erase("~")
	return out


## The global fields, flattened one level so a changing tool position does not resend the
## whole surgery state: {"sg": {"op":.., "ms": {"c":..}}} becomes {"sg.op":.., "ms.c":..}.
func _global_fields() -> Dictionary:
	var g := {
		"t": snappedf(world_time, 0.5), "ph": phase, "sh": shift, "sd": seed_value,
		"vit": snappedf(vitals, 0.1), "pu": snappedf(punch, 0.01), "po": snappedf(pod, 0.01),
		"et": snappedf(end_timer, 0.1), "cs": case.duplicate(true), "sf": shelf.duplicate(),
		"wp": waiting_peers.keys(),
	}
	var sg: Dictionary = surgery.net_state()
	for k in sg.keys():
		if k == "ms" and sg[k] is Dictionary:
			for mk in sg.ms.keys():
				g["ms." + str(mk)] = sg.ms[mk]
		else:
			g["sg." + str(k)] = sg[k]
	return g


static func _surgery_state_from(g: Dictionary) -> Dictionary:
	var sg := {}
	var ms := {}
	for k in g.keys():
		var key := String(k)
		if key.begins_with("sg."):
			sg[key.substr(3)] = g[k]
		elif key.begins_with("ms."):
			ms[key.substr(3)] = g[k]
	sg["ms"] = ms
	return sg


## Client: rebuild the full state the host meant from the base we acked plus this delta.
static func _decode_delta(base: Dictionary, msg: Dictionary) -> Dictionary:
	var g := _merge_fields(base.get("g", {}), msg.get("g", {}))
	var state := {"g": g}
	var removed: Dictionary = msg.get("x", {})
	for sec in SECTIONS:
		var sec_state: Dictionary = base.get(sec, {}).duplicate()
		for id in removed.get(sec, []):
			sec_state.erase(id)
		var changed: Dictionary = msg.get(sec, {})
		for id in changed.keys():
			var v = changed[id]
			if v is Dictionary and sec_state.get(id) is Dictionary:
				sec_state[id] = _merge_fields(sec_state[id], v)
			else:
				sec_state[id] = v
		state[sec] = sec_state
	return state


@rpc("authority", "unreliable_ordered", "call_remote")
func _snapshot(msg: Dictionary) -> void:
	var seq := int(msg.get("s", 0))
	var base_seq := int(msg.get("b", 0))
	if seq <= _recv_floor or seq <= _recv_latest:
		return
	var base: Dictionary = {}
	if base_seq != 0:
		if not _recv_states.has(base_seq):
			return   # we no longer have that base; our ack will fall back to a keyframe
		base = _recv_states[base_seq]
	var state := _decode_delta(base, msg)
	var g: Dictionary = state.g
	if not g.has("sd"):
		return
	var keyframe := base_seq == 0
	if int(g.sd) != seed_value or phase == Phase.MENU:
		if not keyframe:
			return
		start_lobby(int(g.sd), int(g.sh))   # clears _recv_states
	_recv_states[seq] = state
	for old in _recv_states.keys():
		if int(old) <= seq - HISTORY:
			_recv_states.erase(old)
	_recv_latest = seq
	_apply_state(state, msg, keyframe)


func _apply_state(state: Dictionary, msg: Dictionary, keyframe: bool) -> void:
	var g: Dictionary = state.g
	# The clock runs locally; the host's (sent in half-second steps) only corrects drift.
	if absf(world_time - float(g.t)) > 1.0:
		world_time = float(g.t)
	_set_phase(int(g.ph))
	shift = int(g.sh)
	vitals = float(g.vit)
	punch = float(g.pu)
	pod = float(g.po)
	end_timer = float(g.et)
	waiting_peers.clear()
	for id in g.get("wp", []):
		waiting_peers[id] = true
	case = (g.cs as Dictionary).duplicate(true)
	_apply_case_locally()
	if str(shelf) != str(g.sf):
		shelf = (g.sf as Dictionary).duplicate()
		if shelf_node != null:
			shelf_node.show_stock(shelf)
	surgery.apply_net_state(_surgery_state_from(g))

	var removed: Dictionary = msg.get("x", {})
	# Players: nodes come from the roster; apply what changed (everything on a keyframe).
	var pl_ids: Array = state.pl.keys() if keyframe else msg.get("pl", {}).keys()
	for id in pl_ids:
		var p = players.get(id)
		if p != null and state.pl.has(id):
			p.apply_remote_full(state.pl[id])

	# Monsters and items are created and destroyed to match the host.
	_apply_entities(monsters, state.mo, msg.get("mo", {}), removed.get("mo", []), keyframe,
		func(id, e): return MonsterScript.new_monster(id, String(e.kind), e.pos))
	_apply_entities(world_items, state.it, msg.get("it", {}), removed.get("it", []), keyframe,
		func(id, e): return WorldItemScript.new_item(id, String(e.k), int(e.n)))

	if keyframe:
		for n in get_tree().get_nodes_in_group("container"):
			if n.has_meta("interact_id") and n.has_method("is_open"):
				var want: bool = state.ct.has(String(n.get_meta("interact_id")))
				if n.is_open() != want:
					n.set_open(want, true)
	else:
		for id in msg.get("ct", {}).keys():
			_set_container_open(id, true)
		for id in removed.get("ct", []):
			_set_container_open(id, false)


func _apply_entities(nodes: Dictionary, entities: Dictionary, changed: Dictionary, removed: Array, keyframe: bool, make: Callable) -> void:
	for id in removed:
		if nodes.has(id):
			nodes[id].queue_free()
			nodes.erase(id)
	var ids: Array = entities.keys() if keyframe else changed.keys()
	for id in ids:
		var e: Dictionary = entities.get(id, {})
		if e.is_empty():
			continue
		var node = nodes.get(id)
		if node == null or not is_instance_valid(node):
			node = make.call(id, e)
			nodes[id] = node
			_entities.add_child(node)
		node.apply_remote(e)
	if keyframe:
		for id in nodes.keys():
			if not entities.has(id):
				nodes[id].queue_free()
				nodes.erase(id)


func _set_container_open(id: String, open: bool) -> void:
	var node := find_interactable(id)
	if node != null and node.has_method("is_open") and node.is_open() != open:
		node.set_open(open, true)


## Host: forget what clients have, so the next snapshot to everyone is a keyframe.
func _net_reset_history() -> void:
	_net_history.clear()
	_net_keyframe_at.clear()


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _player_state(ack: int, s: Array) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	# The newest base this client can decode. Unreliable-ordered, so it never goes backwards,
	# except to 0 after the client dropped its states for a new lobby.
	_net_acks[id] = ack
	var p = players.get(id)
	if p != null and not s.is_empty():
		p.apply_remote_state(s)


@rpc("authority", "reliable", "call_remote")
func _rpc_shift(new_seed: int, new_shift: int, new_phase: int, net_seq: int = 0) -> void:
	if new_seed != seed_value:
		start_lobby(new_seed, new_shift)
		_recv_floor = maxi(_recv_floor, net_seq)
	shift = new_shift
	_set_phase(new_phase)


## Client side of a new lobby: every decoded state belongs to the old hospital.
func _net_client_reset() -> void:
	_recv_states.clear()
	_recv_latest = 0


## Host: a peer joined outside the lobby. It watches until the next shift.
func _hold_until_next_shift(p: Node) -> void:
	waiting_peers[p.peer_id] = true
	p.alive = false
	p.dead_time = 0.0
	p._set_visible_alive(false)


## Host: someone left. What they carried lands where they stood, gently: nothing smashes.
func _drop_hands_in_place(p: Node) -> bool:
	var any := false
	for i in p.slots.size():
		var s: Dictionary = p.slots[i]
		if s.kind == "":
			continue
		any = true
		var a := TAU * float(i) / float(maxi(1, p.slots.size())) + randf() * 0.5
		var at: Vector3 = p.global_position + Vector3(cos(a) * 0.3, 0.5, sin(a) * 0.3)
		var xf := Transform3D(Basis(Vector3.UP, randf() * TAU), at)
		var it := _spawn_item(s.kind, int(s.count), xf, WorldItem.State.LOOSE)
		it.toss(xf, Vector3(cos(a), 0.0, sin(a)) * 0.4)
		p.slots[i] = {"kind": "", "count": 0}
	if any:
		emit_noise(p.global_position, 0.4, "drop")
	return any


## Discrete one-off things the host wants everyone to see or hear.
@rpc("authority", "reliable", "call_remote")
func _event(kind: String, data: Dictionary) -> void:
	match kind:
		"sound":
			Audio.play(data.cue, data.get("at"))
		"say":
			message = data.text
			message_timer = data.secs
			notice.emit(data.text, data.secs)
		"hit":
			var p = players.get(data.id)
			if p != null:
				p.hp = data.hp
				if data.id == Net.my_id():
					p.apply_knock(data.knock)
					p.flinch()
			Audio.play("hurt", p.global_position if p != null else null)
		"shoved":
			var q = players.get(data.id)
			if q != null and data.id == Net.my_id():
				q.apply_knock(data.knock)
		"revive":
			var r = players.get(data.id)
			if r != null:
				r.teleport(data.pos)
				r.revive(2)
			Audio.play("revive", data.pos)


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
