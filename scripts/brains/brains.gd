extends Node
## Brains (sweep 3, docs/SWEEP3.md "Brains"): harvested brains and their spoilage, the dumpster
## price, the break-room blender, per-player absorbed brains, and the two abilities they teach on R:
## Echo (Discharged brains) and Hive Eyes (Walk-In brains). A child "Brains" of Game on every machine.
##
## Authority: the host decides everything (spoil clocks, blending, points, abilities, who is looking
## through which Walk-In). Clients get it through `net_state()` (global snapshot field `br`), the
## Player field `hive_view` (report key `hv`), the world item / hand slot key `bt`, and reliable
## events `br_echo`, `br_drink`, `br_hive`. The visuals (rot, the blender, the Echo view, the Hive
## Eyes camera) run on every machine from that state.
##
## Spoilage: a brain carries `bt`, the world_time it was harvested (on the WorldItem and in the hand
## slot). It is worth its full value for FRESH_SECONDS, then falls linearly to MIN_FACTOR at
## ROTTEN_SECONDS and stays there. A brain that turns up without `bt` (dev spawns) starts now.

const BrainModel := preload("res://scripts/brains/brain_model.gd")
const BlenderScript := preload("res://scripts/brains/blender.gd")
const EchoViewScript := preload("res://scripts/brains/echo_view.gd")
const HiveViewScript := preload("res://scripts/brains/hive_view.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")

## Brain kind -> the path it teaches.
const PATH_OF := {"brain_walk_in": "walk_in", "brain_discharged": "discharged"}
const KIND_OF := {"walk_in": "brain_walk_in", "discharged": "brain_discharged"}
const PATHS := ["walk_in", "discharged"]
const ABILITY_NAME := {"walk_in": "Hive Eyes", "discharged": "Echo"}
## SWEEP 4A HOOK (controls): ability ids, and the ability-slot cap. add_ability()/set_level()/
## slot_of() are independent of how a level is earned (today: brains + blender points; grafting
## will source them later, docs/backlog/SWEEP4B.md), so slot code never reads `_points` directly
## except through level()/points().
const ABILITY_ID := {"discharged": "echo", "walk_in": "hive_in"}
const ABILITY_ID_TO_PATH := {"echo": "discharged", "hive_in": "walk_in"}
const MAX_SLOTS := 4
## A spoil time at or below this means "none" (WorldItem.bt defaults to -1e6; a real one can be negative).
const NO_BT := -100000.0
const WALK_IN := "walk_in"   # Monster.WALK_IN (monsters worker); the string, so this runs without it

const FRESH_SECONDS := 45.0
const ROTTEN_SECONDS := 225.0
const MIN_FACTOR := 0.15
const FRESH_FACTOR := 0.6     # at or above: fresh
const ROTTEN_FACTOR := 0.3    # below: rotten; between: spoiling

const BLEND_SECONDS := 1.5
const POINTS_FRESH := 1.0
const POINTS_SPOILING := 0.75
const POINTS_ROTTEN := 0.5
const MAX_LEVEL := 3

const ECHO_COOLDOWN := 20.0
const ECHO_NOISE := 1.2
const ECHO_RADIUS := 12.0
const ECHO_RADIUS_PER_LEVEL := 6.0
const ECHO_SECONDS := 2.5
const ECHO_SECONDS_PER_LEVEL := 0.75

const HIVE_COOLDOWN := 12.0   # counted from when the view ends
const HIVE_RANGE := 20.0
const HIVE_RANGE_PER_LEVEL := 10.0
const HIVE_SECONDS := 5.0
const HIVE_SECONDS_PER_LEVEL := 2.0
## After a Hive Eyes view ends, R presses from that player are ignored this long (the press that
## ended it on the client may arrive after the host already ended it).
const HIVE_PRESS_GRACE := 0.5

var game: Node = null

## Replicated. peer id -> [walk_in points, discharged points] (floats, multiples of 0.25).
var _points: Dictionary = {}
## Replicated. peer id -> [monster id, world_time it ends].
var _hive: Dictionary = {}
## Replicated. peer id -> blend progress 0..1 (only while someone holds E on the blender).
var _blend: Dictionary = {}
## Replicated. peer id -> Array[MAX_SLOTS] of ability id ("" empty). Host authoritative; a new
## ability goes into the first empty slot the moment its path first reaches level 1. See
## add_ability() / set_level() / slot_of() below.
var _slots: Dictionary = {}

# host only
var _hive_hp: Dictionary = {}          # peer id -> hp when the view started
var _cd: Dictionary = {}               # "echo:<peer>" / "hive:<peer>" -> world_time it is ready
var _press_grace: Dictionary = {}      # peer id -> world_time before which R is ignored
var _hint_at: Dictionary = {}          # peer id -> world_time of the last "Nothing happens."
var _stamp_timer := 0.0
var _rot_timer := 0.0

var blender: Node3D = null
var blender_mode := ""                 # "counter" | "stand" | "" (not placed)
var _level: Node = null
var _place_wait := -1

var echo_view: Node = null
var hive_view: Node = null

## Test seams: the last Echo started on this machine and the last ability result on the host.
var last_echo := {}
var last_result := ""


func setup(g: Node) -> void:
	game = g
	echo_view = EchoViewScript.new()
	echo_view.name = "EchoView"
	add_child(echo_view)
	echo_view.setup(g)
	hive_view = HiveViewScript.new()
	hive_view.name = "HiveView"
	add_child(hive_view)
	hive_view.setup(g)


# =========================================================================
# spoilage and value
# =========================================================================

static func is_brain(kind: String) -> bool:
	return PATH_OF.has(kind)


## How much of its value a brain keeps after `age_seconds`: 1.0 for 45 s, then down to 0.15 at 225 s.
static func spoil_factor(age_seconds: float) -> float:
	if age_seconds <= FRESH_SECONDS:
		return 1.0
	var k := clampf((age_seconds - FRESH_SECONDS) / (ROTTEN_SECONDS - FRESH_SECONDS), 0.0, 1.0)
	return lerpf(1.0, MIN_FACTOR, k)


## "fresh", "spoiling" or "rotten" for a spoil factor.
static func condition(factor: float) -> String:
	if factor >= FRESH_FACTOR:
		return "fresh"
	return "spoiling" if factor >= ROTTEN_FACTOR else "rotten"


## The full value of a perfect brain of this kind.
static func base_value(kind: String) -> int:
	var v: Array = LootTable.LOOT.get(kind, {}).get("value", [0, 0])
	return int(v[0])


## Seconds since this stack or item was harvested (0 without a spoil time).
func age_of(stack_or_item) -> float:
	var bt := _bt_of(stack_or_item)
	if bt <= NO_BT or game == null:
		return 0.0
	return maxf(0.0, float(game.world_time) - bt)


func factor_of(stack_or_item) -> float:
	if not is_brain(_kind_of(stack_or_item)):
		return 1.0
	return spoil_factor(age_of(stack_or_item))


## What the dumpster pays for a hand slot ({kind, v, bt}) or a WorldItem right now: its value times
## the spoil factor for brains, the plain value for anything else.
func current_value(stack_or_item) -> int:
	var v := _value_of(stack_or_item)
	if v <= 0 or not is_brain(_kind_of(stack_or_item)):
		return maxi(0, v)
	return maxi(1, roundi(float(v) * factor_of(stack_or_item)))


static func _kind_of(x) -> String:
	if x is Dictionary:
		return String(x.get("kind", ""))
	if x is Object and is_instance_valid(x):
		return String(x.get("kind"))
	return ""


static func _value_of(x) -> int:
	if x is Dictionary:
		return int(x.get("v", 0))
	if x is Object and is_instance_valid(x):
		return int(x.get("value"))
	return 0


static func _bt_of(x) -> float:
	if x is Dictionary:
		return float(x.get("bt", NO_BT - 1.0))
	if x is Object and is_instance_valid(x) and x.get("bt") != null:
		return float(x.get("bt"))
	return NO_BT - 1.0


## Host: a harvested brain lands at `pos` (on whatever is under it). `quality` 0..1 is the brain's
## condition; it scales the value. The spoil clock starts now.
func spawn_brain(kind: String, quality: float, pos: Vector3) -> Node:
	if game == null or not game.is_host():
		return null
	if not is_brain(kind):
		kind = "brain_walk_in"
	var q := clampf(quality, 0.0, 1.0)
	var at: Vector3 = game._surface_below(pos + Vector3.UP * 0.6, pos)
	var it: Node = game._spawn_item(kind, 1, Transform3D(Basis(Vector3.UP, randf() * TAU), at + Vector3.UP * 0.01), WorldItem.State.LOOSE)
	it.value = maxi(1, roundi(float(base_value(kind)) * q))
	it.bt = float(game.world_time)
	game._sound("brains_squelch", at)
	return it


# =========================================================================
# points and levels
# =========================================================================

func points(peer_id: int, path: String) -> float:
	var i := PATHS.find(path)
	if i < 0 or not _points.has(peer_id):
		return 0.0
	return float(_points[peer_id][i])


func level(peer_id: int, path: String) -> int:
	return mini(MAX_LEVEL, int(floor(points(peer_id, path) + 0.001)))


func add_points(peer_id: int, path: String, amount: float) -> void:
	var i := PATHS.find(path)
	if i < 0:
		return
	var before := level(peer_id, path)
	var arr: Array = _points.get(peer_id, [0.0, 0.0]).duplicate()
	arr[i] = clampf(float(arr[i]) + amount, 0.0, float(MAX_LEVEL))
	_points[peer_id] = arr
	if before == 0 and level(peer_id, path) >= 1 and ABILITY_ID.has(path):
		add_ability(peer_id, String(ABILITY_ID[path]))


# =========================================================================
# ability slots (sweep 4a, docs/SWEEP4A.md "Controls, ability slots and HUD, scanner")
# =========================================================================

## This player's 4 ability slots, ability id or "" for empty. Never call this to add an ability
## (it does not create the entry lazily on clients that should not invent one); use add_ability().
func slots_for(peer_id: int) -> Array:
	if not _slots.has(peer_id):
		_slots[peer_id] = ["", "", "", ""]
	return _slots[peer_id]


## Host: `id` goes into the first empty slot. Refuses (returns false, the slots unchanged) once
## the player already has MAX_SLOTS abilities, or if `id` is already in a slot (idempotent).
func add_ability(peer_id: int, id: String) -> bool:
	var arr: Array = slots_for(peer_id)
	if arr.has(id):
		return true
	var i := arr.find("")
	if i < 0:
		return false
	arr[i] = id
	return true


## Which slot `id` is in for this player, or -1.
func slot_of(peer_id: int, id: String) -> int:
	return slots_for(peer_id).find(id)


## Host (tests, dev, and later grafting): set the level of an ability directly, independent of
## how points are normally earned. `id` must be a known ability id (echo / hive_in); a level of
## 1 or more also grants the slot, same as reaching it through points.
func set_level(peer_id: int, id: String, lvl: int) -> void:
	var path: String = String(ABILITY_ID_TO_PATH.get(id, ""))
	if path == "":
		return
	var i := PATHS.find(path)
	var arr: Array = _points.get(peer_id, [0.0, 0.0]).duplicate()
	arr[i] = clampf(float(lvl), 0.0, float(MAX_LEVEL))
	_points[peer_id] = arr
	if lvl >= 1:
		add_ability(peer_id, id)


static func points_for(factor: float) -> float:
	match condition(factor):
		"fresh": return POINTS_FRESH
		"spoiling": return POINTS_SPOILING
	return POINTS_ROTTEN


func echo_radius(lvl: int) -> float:
	return ECHO_RADIUS + ECHO_RADIUS_PER_LEVEL * lvl


func echo_seconds(lvl: int) -> float:
	return ECHO_SECONDS + ECHO_SECONDS_PER_LEVEL * lvl


func hive_range(lvl: int) -> float:
	return HIVE_RANGE + HIVE_RANGE_PER_LEVEL * lvl


func hive_seconds(lvl: int) -> float:
	return HIVE_SECONDS + HIVE_SECONDS_PER_LEVEL * lvl


## Host: seconds until an ability is ready for this player (0 = ready).
func cooldown_left(peer_id: int, path: String) -> float:
	var key := ("hive:%d" if path == "walk_in" else "echo:%d") % peer_id
	return maxf(0.0, float(_cd.get(key, -1.0)) - float(game.world_time))


## Host: game over. Every player's absorbed brains are gone.
func on_reset() -> void:
	for peer in _hive.keys():
		_end_hive(peer, "")
	_points.clear()
	_blend.clear()
	_cd.clear()
	_press_grace.clear()
	_hint_at.clear()
	_slots.clear()


# =========================================================================
# the blender
# =========================================================================

func blender_prompt(p) -> String:
	if p == null:
		return ""
	var s: Dictionary = p.selected_stack() if p.has_method("selected_stack") else {}
	var kind := String(s.get("kind", ""))
	if not is_brain(kind):
		return "!Blender: bring a brain"
	var f := factor_of(s)
	return "Hold E: blend and drink the %s (%s)" % [Items.display_name(kind).to_lower(), condition(f)]


func blend_progress(peer_id: int) -> float:
	return float(_blend.get(peer_id, 0.0))


func _tick_blending(delta: float) -> void:
	var holding := {}
	if blender != null and is_instance_valid(blender):
		for p in game.alive_players():
			if not p.wants_interact or p.aim_id != "blender" or p.get("hive_view"):
				continue
			if not is_brain(String(p.selected_stack().kind)) or not game._within_reach(p, blender):
				continue
			holding[p.peer_id] = p
	for peer in _blend.keys():
		if not holding.has(peer):
			var left := float(_blend[peer]) - delta * 3.0
			if left <= 0.0:
				_blend.erase(peer)
			else:
				_blend[peer] = snappedf(left, 0.05)
	for peer in holding.keys():
		var prog := float(_blend.get(peer, 0.0)) + delta / BLEND_SECONDS
		if prog >= 1.0:
			_blend.erase(peer)
			drink(holding[peer])
		else:
			_blend[peer] = prog


## Host: p drinks the brain in the selected hand (the blender's hold finished).
func drink(p: Node) -> void:
	if game == null or not game.is_host() or p == null:
		return
	var head: int = p.selected_head()
	var s: Dictionary = p.slots[head]
	var kind := String(s.kind)
	if not is_brain(kind):
		return
	var f := factor_of(s)
	var pts := points_for(f)
	var path: String = PATH_OF[kind]
	var before := level(p.peer_id, path)
	p.clear_slot(head)
	add_points(p.peer_id, path, pts)
	var lvl := level(p.peer_id, path)
	var at: Vector3 = blender.global_position if blender != null and is_instance_valid(blender) else p.global_position
	_emit("br_drink", {"id": p.peer_id, "kind": kind, "pos": at, "cond": condition(f)})
	var ability: String = ABILITY_NAME[path]
	var what := "%s blended the %s %s and drank it." % [p.player_name, condition(f), Items.display_name(kind).to_lower()]
	if lvl > before:
		what += " %s %d." % [ability, lvl]
	game.say(what, 3.5)
	if before == 0 and points(p.peer_id, path) >= pts:
		game.tell(p, "Something new stirs behind your eyes. Press R: %s." % ability, 4.0)


# =========================================================================
# the ability (R)
# =========================================================================

## Host: p pressed Alt+(slot_idx+1). Per-slot dispatch: each slot's ability (if any) runs on its
## own cooldown (echo:/hive: keys in _cd, unchanged by the slot it sits in). Pressing the slot again
## while its ability is active (Hive Eyes) ends it, same as R used to.
func ability_slot(p: Node, slot_idx: int) -> void:
	if game == null or not game.is_host() or p == null:
		return
	var peer: int = p.peer_id
	var arr: Array = slots_for(peer)
	if slot_idx < 0 or slot_idx >= arr.size():
		return
	var id := String(arr[slot_idx])
	if id == "":
		last_result = "nothing"
		if float(game.world_time) - float(_hint_at.get(peer, -99.0)) > 1.0:
			_hint_at[peer] = game.world_time
			game.tell(p, "Nothing happens.", 1.5)
		return
	if id == "hive_in" and _hive.has(peer):
		_end_hive(peer, "")
		last_result = "hive_end"
		return
	if float(game.world_time) < float(_press_grace.get(peer, -1.0)):
		last_result = "grace"
		return
	if not p.alive or p.downed:
		last_result = "down"
		return
	var path: String = String(ABILITY_ID_TO_PATH.get(id, ""))
	var lvl := level(peer, path)
	var left := cooldown_left(peer, path)
	if left > 0.0:
		last_result = "cooldown"
		game.tell(p, "%s is not ready yet (%d s)." % [ABILITY_NAME[path], ceili(left)], 1.5)
		return
	if path == "discharged":
		_echo(p, lvl)
	else:
		_start_hive(p, lvl)


func _echo(p: Node, lvl: int) -> void:
	var pos: Vector3 = p.global_position
	_cd["echo:%d" % p.peer_id] = float(game.world_time) + ECHO_COOLDOWN
	game.emit_noise(pos + Vector3.UP * 1.5, ECHO_NOISE, "echo")
	_emit("br_echo", {"id": p.peer_id, "pos": pos, "r": echo_radius(lvl), "s": echo_seconds(lvl)})
	last_result = "echo"


## The nearest Walk-In within range of p, through walls; null if none. Sedated ones do not count.
func nearest_walk_in(p: Node, range_m: float) -> Node:
	var best: Node = null
	var best_d := range_m
	for m in game.monsters.values():
		if m == null or not is_instance_valid(m) or String(m.kind) != WALK_IN:
			continue
		if m.has_method("is_sedated") and m.is_sedated():
			continue
		var d: float = (m.global_position as Vector3).distance_to(p.global_position)
		if d <= best_d:
			best_d = d
			best = m
	return best


func _start_hive(p: Node, lvl: int) -> void:
	if p.carrying != 0 or p.operating:
		last_result = "busy"
		game.tell(p, "Not now: your hands are busy.", 1.5)
		return
	var m := nearest_walk_in(p, hive_range(lvl))
	if m == null:
		last_result = "no_walk_in"
		game.tell(p, "No Walk-In close enough to see through.", 2.0)
		return
	var peer: int = p.peer_id
	_hive[peer] = [int(m.monster_id), snappedf(float(game.world_time) + hive_seconds(lvl), 0.1)]
	_hive_hp[peer] = int(p.hp)
	p.hive_view = true
	_emit("br_hive", {"id": peer, "on": true})
	last_result = "hive"


## Host: the view ends. `why` ("" for a quiet end) goes to that player.
func _end_hive(peer: int, why: String) -> void:
	if not _hive.has(peer):
		return
	_hive.erase(peer)
	_hive_hp.erase(peer)
	_cd["hive:%d" % peer] = float(game.world_time) + HIVE_COOLDOWN
	_press_grace[peer] = float(game.world_time) + HIVE_PRESS_GRACE
	var p = game.players.get(peer)
	if p != null and is_instance_valid(p):
		p.hive_view = false
		if why != "":
			game.tell(p, why, 2.5)
	_emit("br_hive", {"id": peer, "on": false})


func _tick_hive() -> void:
	for peer in _hive.keys():
		var p = game.players.get(peer)
		if p == null or not is_instance_valid(p):
			_hive.erase(peer)
			_hive_hp.erase(peer)
			continue
		var m = game.monsters.get(int(_hive[peer][0]))
		if m == null or not is_instance_valid(m):
			_end_hive(peer, "The Walk-In is gone. You snap back into your body.")
		elif m.has_method("is_sedated") and m.is_sedated():
			_end_hive(peer, "The Walk-In goes under. You are back in your body.")
		elif not p.alive or p.downed or int(p.hp) < int(_hive_hp.get(peer, p.hp)) or float(p.stun) > 0.0 or p.carried_by != 0:
			_end_hive(peer, "Something hits you. You snap back into your body.")
		elif float(game.world_time) >= float(_hive[peer][1]):
			_end_hive(peer, "")


## Every machine: is the LOCAL player looking through a Walk-In right now?
func local_hive_active() -> bool:
	return hive_view != null and hive_view.active


## Every machine: the camera main.gd should render through (Hive Eyes), else null.
func camera() -> Camera3D:
	if local_hive_active() and game.monsters.has(hive_view.monster_id):
		return hive_view.camera
	return null


## Every machine: the local player pressed Esc during Hive Eyes (same as pressing its slot again).
func local_exit() -> void:
	var me = game.local_player() if game != null else null
	if me == null:
		return
	var i := slot_of(me.peer_id, "hive_in")
	if i >= 0:
		me.ability_slot_press[i] = int(me.ability_slot_press[i]) + 1


# =========================================================================
# frame
# =========================================================================

func physics_tick(delta: float) -> void:
	if game == null:
		return
	_watch_level()
	if game.is_host():
		_stamp_timer -= delta
		if _stamp_timer <= 0.0:
			_stamp_timer = 0.25
			_stamp_spoil_times()
		_tick_blending(delta)
		_tick_hive()
	_rot_timer -= delta
	if _rot_timer <= 0.0:
		_rot_timer = 0.1
		_show_rot()
	if blender != null and is_instance_valid(blender):
		var prog := 0.0
		for v in _blend.values():
			prog = maxf(prog, float(v))
		blender.set_progress(prog)
	var me = game.local_player()
	var h = _hive.get(me.peer_id) if me != null else null
	if h != null:
		hive_view.set_target(int(h[0]), float(h[1]))
	else:
		hive_view.set_target(-1, 0.0)


## Host: a brain without a spoil time (a dev spawn, a fallback loot item) starts spoiling now.
func _stamp_spoil_times() -> void:
	for it in game.world_items.values():
		if is_brain(String(it.kind)) and float(it.bt) <= NO_BT:
			it.bt = float(game.world_time)
	for p in game.players.values():
		for s in p.slots:
			if is_brain(String(s.kind)) and not s.has("bt"):
				s["bt"] = float(game.world_time)


## Every machine: the rot on every brain in the world and in hands.
func _show_rot() -> void:
	for it in game.world_items.values():
		if is_brain(String(it.kind)):
			BrainModel.set_rot(it, 1.0 - (factor_of(it) - MIN_FACTOR) / (1.0 - MIN_FACTOR))
	for p in game.players.values():
		var s: Dictionary = p.selected_stack()
		if not is_brain(String(s.kind)):
			continue
		var r := 1.0 - (factor_of(s) - MIN_FACTOR) / (1.0 - MIN_FACTOR)
		for holder in ["Head/FX/Camera/HeldFirstPerson", "Body/HeldThirdPerson"]:
			BrainModel.set_rot(p.get_node_or_null(holder), r)


# =========================================================================
# the blender in the level
# =========================================================================

func _watch_level() -> void:
	if game.level != _level:
		_level = game.level
		blender = null
		blender_mode = ""
		_place_wait = 2 if _level != null else -1
		echo_view.stop()
	if _place_wait >= 0:
		if _level == null or not is_instance_valid(_level) or not _level.is_inside_tree():
			_place_wait = -1
			return
		_place_wait -= 1
		if _place_wait < 0:
			_place_blender()


func _place_blender() -> void:
	var spot := blender_spot(game.level_info)
	var stand: bool = spot.get("stand", true)
	blender = BlenderScript.create(stand)
	blender_mode = "stand" if stand else "counter"
	_level.add_child(blender)
	blender.global_position = spot.position
	blender.rotation.y = float(spot.get("yaw", 0.0))


## Where the blender goes: on a free end of a break-room counter (found with downward rays over the
## room, the end nearest the time clock), else on a stand beside the level's economy spots (the dev
## room), else on a stand on free floor near the time clock. Static geometry only, so every machine
## finds the same spot.
func blender_spot(info: Dictionary) -> Dictionary:
	var clock: Vector3 = info.get("clock", Vector3.ZERO)
	for r in info.get("rooms", []):
		if String(r.get("kind", "")) != "break_room":
			continue
		var c := _counter_spot(r.get("rect", Rect2()), clock)
		if not c.is_empty():
			return c
	var econ = info.get("economy")
	if econ is Dictionary and (econ as Dictionary).has("shop"):
		var shop: Dictionary = econ.shop if econ.shop is Dictionary else {"position": econ.shop}
		var base: Vector3 = shop.get("position", Vector3.ZERO)
		var f := _free_floor_near(base, 1.8, 3.2)
		if not f.is_empty():
			return f
	var near := _free_floor_near(game._floor_at(clock), 1.4, 3.0)
	if not near.is_empty():
		return near
	return {"position": game._floor_at(clock + Vector3(1.5, 0, 0)), "yaw": 0.0, "stand": true}


func _counter_spot(rect: Rect2, clock: Vector3) -> Dictionary:
	if rect.size.x <= 0.0:
		return {}
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var floor_y: float = clock.y if rect.grow(0.5).has_point(Vector2(clock.x, clock.z)) else 0.0
	const STEP := 0.1
	var tops := {}   # Vector2i cell -> height
	var nx := int(rect.size.x / STEP)
	var nz := int(rect.size.y / STEP)
	for ix in nx + 1:
		for iz in nz + 1:
			var x := rect.position.x + ix * STEP
			var z := rect.position.y + iz * STEP
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, floor_y + 2.2, z), Vector3(x, floor_y - 0.2, z))
			q.collision_mask = C.L_WORLD
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var hy: float = (hit.position as Vector3).y - floor_y
			if hy > 0.8 and hy < 1.1 and (hit.normal as Vector3).y > 0.9:
				tops[Vector2i(ix, iz)] = (hit.position as Vector3).y
	var best := Vector2i(-1, -1)
	var best_d := INF
	for cell in tops.keys():
		var ok := true
		for dx in [-2, 0, 2]:
			for dz in [-2, 0, 2]:
				var n: Vector2i = cell + Vector2i(dx, dz)
				if not tops.has(n) or absf(float(tops[n]) - float(tops[cell])) > 0.03:
					ok = false
		if not ok:
			continue
		var wp := Vector3(rect.position.x + cell.x * STEP, 0, rect.position.y + cell.y * STEP)
		var d := Vector2(wp.x - clock.x, wp.z - clock.z).length()
		if d < best_d:
			best_d = d
			best = cell
	if best.x < 0:
		return {}
	var pos := Vector3(rect.position.x + best.x * STEP, float(tops[best]), rect.position.y + best.y * STEP)
	# Back it toward the wall behind the counter and face the room.
	var yaw := 0.0
	var nearest := INF
	for dir in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		var from := pos + Vector3.UP * 0.3
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 1.0)
		q.collision_mask = C.L_WORLD
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d: float = from.distance_to(hit.position)
			if d < nearest:
				nearest = d
				yaw = atan2(-dir.x, -dir.z)
	if nearest < INF:
		var back := Vector3(sin(yaw), 0, cos(yaw))   # the blender's -Z (its back) points at the wall
		pos -= back * clampf(nearest - 0.14, 0.0, 0.2)
	return {"position": pos, "yaw": yaw, "stand": false}


func _free_floor_near(centre: Vector3, r_min: float, r_max: float) -> Dictionary:
	for ring in 5:
		var r := lerpf(r_min, r_max, ring / 4.0)
		for k in 16:
			var a := TAU * float(k) / 16.0
			var p := centre + Vector3(cos(a) * r, 0.0, sin(a) * r)
			var fp: Vector3 = game._floor_at(p)
			if absf(fp.y - centre.y) > 0.3 or not game._point_is_clear(fp):
				continue
			var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
			var los := PhysicsRayQueryParameters3D.create(centre + Vector3.UP * 1.2, fp + Vector3.UP * 1.2)
			los.collision_mask = C.L_WORLD
			if not space.intersect_ray(los).is_empty():
				continue
			var to := centre - fp
			return {"position": fp, "yaw": atan2(to.x, to.z), "stand": true}
	return {}


# =========================================================================
# networking
# =========================================================================

## Host -> clients in the global snapshot field `br`. Copies, quantized.
func net_state() -> Dictionary:
	var pts := {}
	for peer in _points.keys():
		var a: Array = _points[peer]
		pts[peer] = [snappedf(float(a[0]), 0.25), snappedf(float(a[1]), 0.25)]
	var hv := {}
	for peer in _hive.keys():
		hv[peer] = [int(_hive[peer][0]), snappedf(float(_hive[peer][1]), 0.1)]
	var bh := {}
	for peer in _blend.keys():
		bh[peer] = snappedf(float(_blend[peer]), 0.05)
	var ab := {}
	for peer in _slots.keys():
		ab[peer] = (_slots[peer] as Array).duplicate()
	return {"p": pts, "hv": hv, "bh": bh, "ab": ab}


func apply_net_state(s: Dictionary) -> void:
	if game == null or game.is_host():
		return
	_points = (s.get("p", {}) as Dictionary).duplicate(true)
	_hive = (s.get("hv", {}) as Dictionary).duplicate(true)
	_blend = (s.get("bh", {}) as Dictionary).duplicate(true)
	_slots = (s.get("ab", {}) as Dictionary).duplicate(true)


## Host: an event everywhere, this machine included.
func _emit(kind: String, data: Dictionary) -> void:
	on_event(kind, data)
	game._broadcast(kind, data)


func on_event(kind: String, data: Dictionary) -> void:
	match kind:
		"br_echo":
			var pos: Vector3 = data.get("pos", Vector3.ZERO)
			var mine := int(data.get("id", 0)) == Net.my_id()
			if mine:
				Audio.play("brains_shriek", null, 0.0)
				var me = game.local_player()
				if me != null:
					last_echo = {"pos": pos, "r": float(data.get("r", ECHO_RADIUS)), "s": float(data.get("s", ECHO_SECONDS)), "t": game.world_time}
					echo_view.start(me, pos, float(data.get("r", ECHO_RADIUS)), float(data.get("s", ECHO_SECONDS)))
			else:
				Audio.play("brains_shriek", pos + Vector3.UP * 1.5, 6.0)
		"br_drink":
			var at: Vector3 = data.get("pos", Vector3.ZERO)
			Audio.play("brains_gulp", at + Vector3.UP * 1.0)
			if blender != null and is_instance_valid(blender):
				blender.drain()
		"br_hive":
			pass   # the local view follows `_hive`; the event keeps the one-off moment ordered


# =========================================================================
# dev room (scripts/dev/dev_room.gd forwards "br_*" requests here) and warmup
# =========================================================================

func dev_request(sender: int, action: String, a: Dictionary) -> void:
	if not game.is_host():
		return
	var who = game.players.get(sender)
	var front: Vector3 = Vector3.ZERO
	if who != null:
		var fwd: Vector3 = -who.global_transform.basis.z
		front = who.global_position + fwd * 1.2 + Vector3.UP * 0.8
	match action:
		"br_spawn_brain":
			var it := spawn_brain(String(a.get("kind", "brain_walk_in")), float(a.get("quality", 1.0)), front)
			if it != null and a.has("age"):
				it.bt = float(game.world_time) - float(a.age)
		"br_levels":
			var id := int(a.get("id", sender))
			for path in PATHS:
				add_points(id, path, float(a.get("amount", 1.0)))
			game.say("Brain levels: Hive Eyes %d, Echo %d." % [level(id, "walk_in"), level(id, "discharged")], 2.5)
		"br_reset":
			on_reset()
			game.say("Absorbed brains reset.", 2.0)
		"br_walk_in":
			spawn_walk_in(who.global_position - who.global_transform.basis.z * 4.0 if who != null else Vector3.ZERO)


## Host (dev and tests): a Walk-In at `pos`. Until the monsters worker's Walk-In exists this is a
## stand-in: a Discharged body with kind "walk_in" (Hive Eyes only reads the kind).
func spawn_walk_in(pos: Vector3) -> Node:
	if not game.is_host():
		return null
	var ms: GDScript = load("res://scripts/monster.gd")
	var real: bool = ms.get_script_constant_map().has("WALK_IN")
	var m: Node = game._add_monster(WALK_IN if real else "discharged", pos)
	if m != null and not real:
		m.kind = WALK_IN
		m.name = "Monster_%d_walk_in_standin" % int(m.monster_id)
	return m


static func warm(parent: Node3D) -> void:
	var b := BlenderScript.create(true)
	b.remove_from_group("interactable")
	b.remove_meta("interact_id")
	for n in b.find_children("*", "CollisionObject3D", true, false):
		n.queue_free()
	b.position = Vector3(0.6, -1.2, -1.6)
	b.set_progress(0.6)
	parent.add_child(b)
	EchoViewScript.warm(parent)
	HiveViewScript.warm(parent)
