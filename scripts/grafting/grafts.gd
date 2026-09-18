class_name Grafts
extends Node
## GRAFTING chunk C (docs/GRAFTING.md): Eyeball Grafting. A child "Grafts" of Game on every machine.
##
## The loop: a surgeon straps themselves to a free OR table (chunk B), somebody sets a specimen vat
## holding an eye on that table's VAT STAND (vats.gd), and another surgeon operates. Four steps --
## scalpel cut, eye spoon scoop the old eye out, eye spoon seat the new one, suture kit stitch it in
## (Procedures.AILMENTS.eye_graft). The eye that comes out goes into the same vat, so a graft is
## always a swap and never an empty socket. Nothing can be botched (the case sets `no_fail`) and the
## patient is awake the whole time, looking up at it.
##
## Generic on purpose: everything below works on a PART KIND (Eyes.KINDS), so part two's trachea
## (docs/GRAFTING_TRACHEA.md) slots in through PART_ABILITY and Eyes.NOUN without a rewrite.
##
## Authority: the host runs the case (through scripts/downed/player_surgery.gd, which already stands
## in as a game for one table's surgery system) and owns `_graft`; every machine gets `_graft` in the
## snapshot ("gf") and draws the swapped eye, its glow and the first-person tint from it.

const PartScript := preload("res://scripts/grafting/graft_eye.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")

## Part kind -> the ability grafting it grants at level 1. Removing the part takes the ability away.
const PART_ABILITY := {"eye_hive": "hive_in"}
## The eyeball's radius on a surgeon (the minigames' work plane).
const EYE_RADIUS := 0.0135
## How fast the Hive eye's `Lock` climbs and falls as Hive Eyes starts and stops.
const LOCK_RATE := 3.0

var game: Node = null

## Replicated (snapshot "gf"): peer id -> the part kind grafted into them ("eye_hive"). A player who
## is not in here has their own eyes. It lasts the run, through death, and is cleared on a game over.
var _graft: Dictionary = {}

## Local, per peer: how lit the grafted eye is right now (0 low pinpoint, 1 the whole ball).
var _lock: Dictionary = {}
var _shown: Dictionary = {}


func setup(g: Node) -> void:
	game = g


# =============================================================================== state

## The part kind grafted into this player, or "".
func graft_of(peer_id: int) -> String:
	return String(_graft.get(peer_id, ""))


func has_graft(p) -> bool:
	return p != null and graft_of(int(p.peer_id)) != ""


## Host: game over. Grafts are lost, like abilities from brains.
func on_reset() -> void:
	_graft.clear()
	_lock.clear()


func net_state() -> Dictionary:
	return _graft.duplicate()


func apply_net_state(s: Dictionary) -> void:
	if game != null and game.is_host():
		return
	_graft = s.duplicate()


# =============================================================================== the offer and its refusals

## The vat standing on the stand of the table `p` is strapped to, or null.
func vat_for(p) -> Node:
	if p == null or game == null or game.vats == null:
		return null
	var ti := int(game.player_table.get("index", -1))
	if ti >= 0:
		return game.vats.vat_on_stand(ti)
	# A level with a player table of its own has no table index: go by where the table is.
	var i: int = game.vats.nearest_stand(game.player_table_top())
	return game.vats.vat_at(game.vats.stands[i].position as Vector3) if i >= 0 else null


## What the table offers `q` while a surgeon lies strapped to it: "Operate: ..." , a "!reason", or ""
## when the graft is not on offer at all. A pure function of replicated state, so every machine says
## the same thing. The refusals are the ones docs/GRAFTING.md lists: no vat on the stand, the eye is
## spoiled, they already have one, nobody is strapped down.
func table_prompt(q) -> String:
	if game == null or q == null or not q.alive or q.downed or q.on_table:
		return ""
	var p = game.someone_on_table()
	if p == null or not p.strapped():
		return ""
	if q == p:
		return "!You cannot operate on yourself."
	var vat := vat_for(p)
	if vat == null:
		return "!No vat on the stand beside the table."
	var d := Eyes.unpack(String(vat.x))
	if d.is_empty():
		return "!The vat on the stand is empty."
	var kind := String(d.kind)
	var owner := String(d.owner)
	var have := graft_of(int(p.peer_id))
	if Eyes.is_spoiled_factor(Eyes.spoil_factor(float(d.age))):
		return "!%s is spoiled." % Eyes.label(kind, owner)
	if kind == "eye_hive":
		if have != "":
			return "!%s already has one." % p.player_name
	elif have == "":
		return "!%s has two normal eyes." % p.player_name
	var held := String(q.selected_stack().get("kind", "")) if q.has_method("selected_stack") else ""
	if held != "scalpel":
		return "!Hold the scalpel to start the graft."
	return "Operate: graft %s into %s" % [Eyes.label(kind, owner), p.player_name]


## What a free table says to someone holding a graft tool while nobody lies on it.
func empty_table_prompt(q, table_index: int) -> String:
	if game == null or q == null or game.vats == null:
		return ""
	var kind := String(q.selected_stack().get("kind", "")) if q.has_method("selected_stack") else ""
	if kind != "scalpel" and kind != "eye_spoon":
		return ""
	var vat: Node = game.vats.vat_on_stand(table_index)
	if vat == null or String(vat.x) == "":
		return ""
	return "!Nobody is strapped to this table."


# =============================================================================== the case (host)

## Host: `q` began Eyeball Grafting on the strapped surgeon. Builds the case for player_surgery.
func make_case(q) -> Dictionary:
	if game == null or not game.is_host():
		return {}
	if not table_prompt(q).begins_with("Operate"):
		return {}
	var p = game.someone_on_table()
	var vat := vat_for(p)
	var d := Eyes.unpack(String(vat.x))
	var in_kind := String(d.kind)
	var have := graft_of(int(p.peer_id))
	# What comes out is whatever is in the socket now: the Hive eye they were given, or their own.
	var out_kind := have if have != "" else "eye_surgeon"
	var out_owner := "" if out_kind == "eye_hive" else String(p.player_name)
	return {
		"patient_id": "player", "player_id": int(p.peer_id), "ailment_id": "eye_graft",
		"step_index": 0, "table": int(game.player_table.get("index", -1)),
		"in_kind": in_kind, "in_owner": String(d.owner), "in_value": int(d.value),
		"out_kind": out_kind, "out_owner": out_owner,
		"flags": {"sedation": 1.0, "no_fail": true, "eye_kind": out_kind, "eye_kind_in": in_kind,
			"eye_radius": EYE_RADIUS},
	}


## Host: a graft step finished. The scoop is the moment the swap happens: the old eye drops into the
## vat and the vat's eye comes up onto the stand, ready to be seated.
func on_step(case: Dictionary, result: Dictionary) -> void:
	if game == null or not game.is_host() or case.is_empty():
		return
	if not bool(result.get("eye_out", false)):
		return
	var p = game.players.get(int(case.get("player_id", 0)))
	var vat := vat_for(p)
	if vat == null or not is_instance_valid(vat):
		return
	var out_kind := String(case.get("out_kind", "eye_surgeon"))
	var out_owner := String(case.get("out_owner", ""))
	vat.x = Eyes.pack(out_kind, out_owner, 0.0, _value_of(out_kind))
	game._sound("items_glass", vat.global_position)
	game.say("%s is in the vat now." % Eyes.label(out_kind, out_owner), 3.0)


## Host: the last stitch went in. The graft takes.
func finish(case: Dictionary) -> void:
	if game == null or not game.is_host() or case.is_empty():
		return
	var p = game.players.get(int(case.get("player_id", 0)))
	if p == null or not is_instance_valid(p):
		return
	var in_kind := String(case.get("in_kind", ""))
	apply(int(p.peer_id), "eye_hive" if in_kind == "eye_hive" else "")
	var label := Eyes.label(in_kind, String(case.get("in_owner", "")))
	game.say("%s is stitched in. %s can get up." % [label, p.player_name], 4.0)


## Host: set (or clear) `peer_id`'s graft and the ability that comes with it.
func apply(peer_id: int, kind: String) -> void:
	if game == null or not game.is_host():
		return
	var had := graft_of(peer_id)
	if kind == "":
		_graft.erase(peer_id)
	else:
		_graft[peer_id] = kind
	var p = game.players.get(peer_id)
	# The ability the part teaches. It comes with the graft and goes with it.
	if had != "" and had != kind and PART_ABILITY.has(had):
		game.brains.clear_ability(peer_id, String(PART_ABILITY[had]))
		if p != null:
			game.tell(p, "The socket is your own again. Hive Eyes is gone.", 4.0)
	if kind != "" and kind != had and PART_ABILITY.has(kind):
		game.brains.set_level(peer_id, String(PART_ABILITY[kind]), 1)
		if p != null:
			game.tell(p, "The Hive eye settles in and starts to see. Hive Eyes 1.", 5.0)


func _value_of(kind: String) -> int:
	var e: Dictionary = LootTable.LOOT.get(kind, {})
	var v = e.get("value", [40, 40])
	return int(v[0]) if v is Array and not (v as Array).is_empty() else 40


# =============================================================================== the look (every machine)

func _physics_process(delta: float) -> void:
	if game == null or game.get("players") == null:
		return
	for p in game.players.values():
		if p == null or not is_instance_valid(p) or p.body_visual == null:
			continue
		var peer := int(p.peer_id)
		var kind := graft_of(peer)
		# The eye swap on the body: third person, other players' screens and the Personnel mirrors.
		if String(_shown.get(peer, "")) != kind:
			_shown[peer] = kind
			if kind == "":
				PartScript.detach(_human_of(p))
			else:
				PartScript.attach(_human_of(p), kind, EYE_RADIUS)
		if kind == "":
			continue
		# The glow: low normally, high while they are in Hive Eyes. Replicated, because `hive_view`
		# is (Player report key "hv"), so every machine works out the same value.
		var want := 1.0 if bool(p.get("hive_view")) else 0.0
		var v := move_toward(float(_lock.get(peer, 0.0)), want, delta * LOCK_RATE)
		_lock[peer] = v
		PartScript.set_lock(PartScript.node_on(_human_of(p)), v)


func _human_of(p) -> Node:
	if p == null or p.body_visual == null or not is_instance_valid(p.body_visual):
		return null
	for c in p.body_visual.get_children():
		if c is Node3D and (c as Node3D).has_meta("human_variant"):
			return c
	return null


## Every machine: how lit the grafted eye of whoever you are looking out of is, for the first-person
## tint (hud.gd). -1 when they have no graft. Driving Dr. Botsworth, it is his eyes you see through,
## so your own grafted eye does not tint his view.
func local_lock() -> float:
	var me = game.driving_player() if game != null else null
	if me == null or graft_of(int(me.peer_id)) == "":
		return -1.0
	return float(_lock.get(int(me.peer_id), 0.0))
