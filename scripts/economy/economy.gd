extends Node
## The pharmacy window and the crematorium furnace in the world, one of each per level. A child
## of Game named "Economy", on every machine. Money itself lives on the game (`game.money`,
## `game.add_money()`); this node places the pharmacy and the furnace and shows things.
##
## SWEEP 4A HOOK (pharmacy, chunk 3): gold bars, the sell bin and the shop van are gone. Buying is
## the pharmacy window (placebo pills only, for now); selling is throwing loot into the furnace.
##
## Where things go, first match wins:
##   level_info.safe_zone {pharmacy_rect, crematorium_rect}   the hospital's lobby: the rects
##                                          chunk 2 reserved off the lobby (docs/CONTRACTS.md,
##                                          "Hospital"). The pharmacy and the furnace go at the
##                                          centre of their rect.
##   level_info.economy {shop, furnace}     a hand-placed spot set (the dev room)
##   otherwise                              free floor in the clock-in room, found by a
##                                          deterministic search around the time clock
## Placement waits two physics frames after the level is built so shape queries see it; the
## search only looks at static level geometry, so every machine finds the same spots.

const PharmacyScript := preload("res://scripts/economy/economy_props.gd")
const FurnaceScript := preload("res://scripts/economy/furnace.gd")

const NEAR_METRES := 9.0
const FLASH_SECONDS := 4.0

var game: Node = null
var pharmacy: Node3D = null
var furnace: Node3D = null
## "", "reserve" (the lobby spots), "economy" (hand-placed) or "search": how this level's spots
## were chosen.
var mode := ""

## For the HUD: seconds the money readout stays up after a change, and the last change.
var flash := 0.0
var last_delta := 0

var _level: Node3D = null
var _info: Dictionary = {}
var _wait := -1


func setup(g: Node) -> void:
	game = g


## game._add_landmarks: a new level exists. Everything from the old one went with it.
func on_level_built(level: Node3D, info: Dictionary) -> void:
	_level = level
	_info = info
	pharmacy = null
	furnace = null
	mode = ""
	_wait = 2


func on_money_changed(delta: int, _reason: String) -> void:
	last_delta = delta
	flash = FLASH_SECONDS


func on_reset() -> void:
	flash = 0.0
	last_delta = 0


func placed() -> bool:
	return pharmacy != null and is_instance_valid(pharmacy) and furnace != null and is_instance_valid(furnace)


func pharmacy_position() -> Vector3:
	return pharmacy.global_position + Vector3.UP * 1.0 if pharmacy != null and is_instance_valid(pharmacy) else game.clock_pos()


func furnace_position() -> Vector3:
	return furnace.global_position if furnace != null and is_instance_valid(furnace) else game.clock_pos()


## Whether the money readout should show for this player: near the pharmacy or the furnace,
## aiming at the pharmacy, or right after the money changed.
func money_visible_for(p: Node) -> bool:
	if flash > 0.0:
		return true
	if p == null or not placed():
		return false
	if p.aim_id == "pharmacy":
		return true
	for n in [pharmacy, furnace]:
		if n != null and is_instance_valid(n) and (n as Node3D).global_position.distance_to(p.global_position) < NEAR_METRES:
			return true
	return false


func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta)


func _physics_process(_delta: float) -> void:
	if _wait < 0:
		return
	if _level == null or not is_instance_valid(_level) or not _level.is_inside_tree():
		_wait = -1
		return
	_wait -= 1
	if _wait <= 0:
		_wait = -1
		_place()


# ---------------------------------------------------------------------------
# placement

func _place() -> void:
	var safe_zone: Dictionary = _info.get("safe_zone", {}) if _info.get("safe_zone") is Dictionary else {}
	var spots: Dictionary = {}
	if safe_zone.has("pharmacy_rect") and safe_zone.has("crematorium_rect"):
		mode = "reserve"
		spots = {"shop": _rect_spot(safe_zone.pharmacy_rect), "furnace": _rect_spot(safe_zone.crematorium_rect)}
	elif _info.get("economy") is Dictionary and (_info.economy as Dictionary).has("shop"):
		mode = "economy"
		spots = _info.economy
	else:
		mode = "search"
		spots = _search_spots()
	var root := Node3D.new()
	root.name = "Economy"
	_level.add_child(root)

	pharmacy = PharmacyScript.create(game)
	root.add_child(pharmacy)
	_put(pharmacy, spots.get("shop"))
	furnace = FurnaceScript.create(game)
	root.add_child(furnace)
	_put(furnace, spots.get("furnace"))


## The centre of a reserved world-space rect (Rect2, x/z plane), floor height found by a ray, and
## a yaw facing back toward the lobby's centre line (south, the same wall row every reserved rect
## sits against).
func _rect_spot(r: Rect2) -> Dictionary:
	var cx: float = r.position.x + r.size.x * 0.5
	var cz: float = r.position.y + r.size.y * 0.5
	var probe := Vector3(cx, 2.0, cz)
	var pos: Vector3 = game._floor_at(probe) if game != null else probe
	return {"position": pos, "yaw": 0.0}


## Put a node at a {position, yaw} spot.
func _put(n: Node3D, spot) -> void:
	var s: Dictionary = spot if spot is Dictionary else {"position": spot}
	var pos: Vector3 = s.get("position", s.get("pos", game.clock_pos()))
	n.global_position = pos
	n.rotation.y = float(s.get("yaw", 0.0))


## Free floor near the time clock, in its room, clear of everything the room already holds.
func _search_spots() -> Dictionary:
	var clock_raw: Vector3 = game.clock_pos()
	var clock: Vector3 = game._floor_at(clock_raw)
	var keep_clear: Array = [clock, game.table_pos()]
	for key in ["lectern", "shelf"]:
		var e = _info.get(key)
		if e is Dictionary and e.has("position"):
			keep_clear.append(e.position)
	for sp in _info.get("player_spawns", []):
		keep_clear.append(sp)
	var out := {}
	var taken: Array = []
	for want in [["shop", 1.1], ["furnace", 1.1]]:
		var best = null
		for ring in range(0, 12):
			var r := 1.8 + ring * 0.5
			var steps := 12 + ring * 2
			for k in steps:
				var a := TAU * float(k) / float(steps)
				var p := clock + Vector3(cos(a) * r, 0.0, sin(a) * r)
				if _spot_ok(p, float(want[1]), clock, keep_clear, taken):
					best = p
					break
			if best != null:
				break
		if best == null:
			best = clock + Vector3(1.5 + taken.size() * 1.6, 0.0, 1.5)
		var floor_p: Vector3 = game._floor_at(best)
		taken.append(floor_p)
		var to: Vector3 = clock - floor_p
		out[want[0]] = {"position": floor_p, "yaw": atan2(to.x, to.z)}
	return out


func _spot_ok(p: Vector3, radius: float, clock: Vector3, keep_clear: Array, taken: Array) -> bool:
	for q in keep_clear:
		if Vector2(p.x - q.x, p.z - q.z).length() < radius + 0.9:
			return false
	for q in taken:
		if Vector2(p.x - q.x, p.z - q.z).length() < radius + 1.3:
			return false
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var down := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.2, p + Vector3.DOWN * 0.5)
	down.collision_mask = C.L_WORLD
	var hit := space.intersect_ray(down)
	if hit.is_empty() or absf((hit.position as Vector3).y - clock.y) > 0.25:
		return false
	var los := PhysicsRayQueryParameters3D.create(clock + Vector3.UP * 1.3, p + Vector3.UP * 1.3)
	los.collision_mask = C.L_WORLD
	if not space.intersect_ray(los).is_empty():
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(radius * 2.0 + 0.3, 1.6, radius * 2.0 + 0.3)
	q.shape = box
	q.transform = Transform3D(Basis(), (hit.position as Vector3) + Vector3.UP * 1.0)
	q.collision_mask = C.L_WORLD
	return space.intersect_shape(q, 1).is_empty()


## Warmup hook: build and show one of each economy visual so nothing compiles later.
static func warm(parent: Node3D) -> void:
	var win := PharmacyScript.create(null)
	parent.add_child(win)
	win.position = Vector3(-1.2, -1.2, -1.5)
	var f := FurnaceScript.create(null)
	parent.add_child(f)
	f.position = Vector3(1.6, -1.2, -1.2)
