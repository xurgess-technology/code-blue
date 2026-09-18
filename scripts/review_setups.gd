class_name ReviewSetups
extends RefCounted
## Named review setups: `--setup=<name>` after `--` (tools/review.ps1 passes it on) opens a review
## window straight in a shift, solo and hosting, with the player where the setup puts them and the thing
## to test already staged: no home screen, no lobby, no getting ready (RULES.md, Reviews).
##
## main.gd's launch calls requested(); when a name is given (and known) it skips the title menu, starts a
## solo session on the setup's seed (`--seed=N` overrides it), begins the shift and lets the world settle,
## then calls stage(name, game). An unknown name lists the known ones in the log and opens the menu.
##
## To add a setup (one function, one line):
##   1. add an entry to SETUPS:  "hive_lunge": {"seed": 4242, "stage": "_hive_lunge"},
##   2. write   static func _hive_lunge(game: Game) -> void:   using the helpers below.
## `seed` is optional (default DEFAULT_SEED). Stage functions may await (use game.get_tree()).
## Then open it:  tools\review.bat 2 "HIVE: does the lunge read?" --setup=hive_lunge

const DEFAULT_SEED := 4242

const SETUPS := {
	"icons": {"seed": 4242, "stage": "_icons"},
	"items": {"seed": 1, "stage": "_items"},
}


## The setup name asked for on the command line ("" for none).
static func requested() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--setup="):
			return a.trim_prefix("--setup=").strip_edges()
	return ""


static func exists(setup: String) -> bool:
	return SETUPS.has(setup)


static func names() -> Array:
	return SETUPS.keys()


static func seed_of(setup: String) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed=") and a.trim_prefix("--seed=").is_valid_int():
			return int(a.trim_prefix("--seed="))
	return int((SETUPS.get(setup, {}) as Dictionary).get("seed", DEFAULT_SEED))


## Run the setup's stage function (the shift has begun and the world has settled).
static func stage(setup: String, game: Game) -> void:
	if not exists(setup):
		return
	print("[review] setup '%s' (seed %d)" % [setup, seed_of(setup)])
	await Callable(ReviewSetups, String(SETUPS[setup].stage)).call(game)
	for n in game.get_tree().get_nodes_in_group("review_bar"):
		n.staged()


# ---------------------------------------------------------------------------
# helpers for setups

## Stand the local player at `pos` looking at `at`.
static func place(game: Game, pos: Vector3, at: Vector3) -> void:
	var p = game.local_player()
	p.teleport(pos)
	var d := at - (pos + Vector3.UP * 1.6)
	p._yaw = atan2(-d.x, -d.z)
	p.rotation.y = p._yaw
	p._pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.0, 1.0)
	p.head.rotation.x = p._pitch


## The horizontal direction (of the four axes) from `from` with the most room, so a spot beside a wall
## faces into the room.
static func open_direction(game: Game, from: Vector3, reach: float) -> Vector3:
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var best := Vector3.BACK
	var best_d := -1.0
	for d in [Vector3.BACK, Vector3.FORWARD, Vector3.LEFT, Vector3.RIGHT]:
		var q := PhysicsRayQueryParameters3D.create(from, from + d * reach)
		q.collision_mask = C.L_WORLD
		var hit := space.intersect_ray(q)
		var dist: float = reach if hit.is_empty() else from.distance_to(hit.position)
		if dist > best_d:
			best_d = dist
			best = d
	return best


## Empty the local player's hands.
static func clear_hands(game: Game) -> void:
	var p = game.local_player()
	for i in p.slots.size():
		p.slots[i] = Player.empty_slot()


## Put a stack in the local player's hands. `extra` keys go onto the stack (`bt` a spoil clock, `used`,
## `x` an owner name...). Returns the slot it landed in (-1 without room).
static func give(game: Game, kind: String, count := 1, value := 0, extra := {}) -> int:
	var p = game.local_player()
	var i: int = p.take_into(kind, count, value)
	if i >= 0:
		for k in extra.keys():
			p.slots[i][k] = extra[k]
	return i


## Both abilities (Hive Eyes and Echo) at the given level.
static func give_abilities(game: Game, level := 2) -> void:
	var p = game.local_player()
	game.brains.set_level(p.peer_id, "echo", level)
	game.brains.set_level(p.peer_id, "hive_in", level)
	# No "New ability" cards in the way: they are for a first play.
	var hud = game.get_tree().get_first_node_in_group("hud")
	if hud != null:
		hud._card_seen["echo"] = true
		hud._card_seen["hive_in"] = true


## Drop an item on the floor at `pos` (host).
static func floor_item(game: Game, kind: String, pos: Vector3, count := 1, value := 0) -> void:
	var it = game._spawn_item(kind, count, Transform3D(Basis(), pos + Vector3.UP * 0.3), WorldItem.State.LOOSE)
	it.value = value


# ---------------------------------------------------------------------------
# the setups

## ICONS (docs/ITEMS_AND_ICONS.md chunk C): in the operating room facing the table (patient, monitors,
## lamp all in view), hands holding a stack, a body part that is starting to spoil, a used-up trinket and
## a small loot item, with a heart monitor and a defibrillator on the floor in front to pick up (bulky,
## wide slot), and both abilities. Switch slots, hold Alt, pick things up; the database is in the break
## room, a walk away.
static func _icons(game: Game) -> void:
	var t: Vector3 = game.table_pos()
	place(game, t + Vector3(0.6, 0, 3.4), t + Vector3(0, 1.0, 0))
	clear_hands(game)
	give(game, "anesthetic", 3)
	give(game, "eye_hive", 1, 150, {"bt": game.world_time - 25.0})
	give(game, "laptop", 1, 120, {"used": true})
	give(game, "gold_watch", 1, 90)
	give_abilities(game)
	game.local_player().selected = 0
	floor_item(game, "heart_monitor", t + Vector3(0.1, 0, 2.3), 1, 200)
	floor_item(game, "defibrillator", t + Vector3(1.1, 0, 2.3), 1, 300)


## ITEMS (docs/ITEMS_AND_ICONS.md chunk A): a normal shift; you start in the room with the most loot near
## it, an EpiPen in hand and the other trinkets (desk phone, laptop, pulse oximeter, reflex hammer,
## defibrillator) laid out on the floor in front of you. The log has the shift's loot count per kind.
## Walk the wings and see what turns up.
static func _items(game: Game) -> void:
	var loot: Array = []
	var counts := {}
	for it in game.world_items.values():
		if Items.is_loot(it.kind) and it.state == WorldItem.State.LOOSE:
			loot.append(it)
			counts[it.kind] = int(counts.get(it.kind, 0)) + 1
	print("[review] items: %d loot stacks lying out, by kind: %s" % [loot.size(), str(counts)])
	# The loose loot with the most other loot within 14 m.
	var best: Node3D = null
	var best_n := -1
	for it in loot:
		var n := 0
		for o in loot:
			if it.global_position.distance_to(o.global_position) < 14.0:
				n += 1
		if n > best_n:
			best_n = n
			best = it
	var base: Vector3 = game.clock_pos() if best == null else game._floor_at(best.global_position)
	var out := open_direction(game, base + Vector3.UP * 1.2, 3.0)
	var side := out.cross(Vector3.UP).normalized()
	place(game, base + out * 0.8, base + out * 3.0 + Vector3(0, 0.5, 0))
	clear_hands(game)
	give(game, "epipen", 1, 60)
	game.local_player().selected = 0
	var row := ["desk_phone", "laptop", "pulse_oximeter", "reflex_hammer", "defibrillator"]
	for i in row.size():
		floor_item(game, row[i], base + out * 2.0 + side * (float(i) - 2.0) * 0.55, 1, 100)
	print("[review] items: standing among %d loot stacks; trinkets on the floor ahead, an EpiPen in hand" % best_n)

