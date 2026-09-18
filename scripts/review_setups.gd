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
