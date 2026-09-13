extends Node
## The sell bin, the shop and the gold pile in the world, one per level. A child of Game named
## "Economy", on every machine. Money itself lives on the game (`game.money`, `game.gold_bars`,
## `game.add_money()`); this node places and shows things and answers where they are.
##
## Where things go, first match wins:
##   level_info.neutral {shop, sell_bin, gold_pile}   the hospital's neutral area: the level has
##                                                    built the van and the dumpster, we attach
##   level_info.economy {shop, sell_bin, gold_pile}   a hand-placed spot set (the dev room)
##   otherwise                                        free floor in the clock-in room, found by a
##                                                    deterministic search around the time clock
## Placement waits two physics frames after the level is built so shape queries see it; the
## search only looks at static level geometry, so every machine finds the same spots.

const PropsScript := preload("res://scripts/economy/economy_props.gd")
const GoldPileScript := preload("res://scripts/economy/gold_pile.gd")

## Gold bar prices: the n-th bar (0-based) costs BAR_BASE + n * BAR_STEP, rounded to $5.
const BAR_BASE := 100
const BAR_STEP := 5
## Indoors (fallback and dev room) columns of bars stop short of a 3 m ceiling.
const INDOOR_PILE_CAP := 2.6
const NEAR_METRES := 9.0
const FLASH_SECONDS := 4.0

var game: Node = null
var sell_bin: Node3D = null
var shop: Node3D = null
var pile: Node3D = null
## "", "neutral", "economy" (hand-placed) or "search": how this level's spots were chosen.
var mode := ""

## For the HUD: seconds the money readout stays up after a change, and the last change.
var flash := 0.0
var last_delta := 0

var _level: Node3D = null
var _info: Dictionary = {}
var _wait := -1


func setup(g: Node) -> void:
	game = g


static func bar_price(bars_bought: int) -> int:
	return int(round(float(BAR_BASE + maxi(0, bars_bought) * BAR_STEP) / 5.0)) * 5


## game._add_landmarks: a new level exists. Everything from the old one went with it.
func on_level_built(level: Node3D, info: Dictionary) -> void:
	_level = level
	_info = info
	sell_bin = null
	shop = null
	pile = null
	mode = ""
	_wait = 2


func on_money_changed(delta: int, _reason: String) -> void:
	last_delta = delta
	flash = FLASH_SECONDS


func on_bar_bought() -> void:
	if pile != null and is_instance_valid(pile):
		pile.set_count(game.gold_bars)


func on_reset() -> void:
	flash = 0.0
	last_delta = 0
	if pile != null and is_instance_valid(pile):
		pile.set_count(0, false)


func placed() -> bool:
	return sell_bin != null and is_instance_valid(sell_bin)


func sell_bin_position() -> Vector3:
	return sell_bin.global_position + Vector3.UP * 0.9 if placed() else game.clock_pos()


func shop_position() -> Vector3:
	return shop.global_position + Vector3.UP * 1.0 if shop != null and is_instance_valid(shop) else game.clock_pos()


func pile_position() -> Vector3:
	return pile.global_position if pile != null and is_instance_valid(pile) else game.clock_pos()


func pile_top() -> Vector3:
	return pile.top_position() if pile != null and is_instance_valid(pile) else game.clock_pos()


## Whether the money readout should show for this player: near the sell bin, the shop or the
## pile, aiming at one of them, or right after the money changed.
func money_visible_for(p: Node) -> bool:
	if flash > 0.0:
		return true
	if p == null or not placed():
		return false
	if p.aim_id == "sell_bin" or p.aim_id == "shop":
		return true
	for n in [sell_bin, shop, pile]:
		if n != null and is_instance_valid(n) and (n as Node3D).global_position.distance_to(p.global_position) < NEAR_METRES:
			return true
	return false


func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta)
	if pile != null and is_instance_valid(pile) and game != null and pile.get("_target") != game.gold_bars:
		pile.set_count(game.gold_bars)


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
	var neutral: Dictionary = _info.get("neutral", {}) if _info.get("neutral") is Dictionary else {}
	var spots: Dictionary = {}
	var attached := false
	var cap := INDOOR_PILE_CAP
	if neutral.has("sell_bin") and neutral.has("shop") and neutral.has("gold_pile"):
		mode = "neutral"
		spots = neutral
		attached = true
		cap = 1000.0
	elif _info.get("economy") is Dictionary and (_info.economy as Dictionary).has("sell_bin"):
		mode = "economy"
		spots = _info.economy
	else:
		mode = "search"
		spots = _search_spots()
	var root := Node3D.new()
	root.name = "Economy"
	_level.add_child(root)

	sell_bin = PropsScript.create("sell_bin", attached)
	root.add_child(sell_bin)
	_put(sell_bin, spots.sell_bin, false)
	shop = PropsScript.create("shop", attached)
	root.add_child(shop)
	_put(shop, spots.shop, false)
	pile = GoldPileScript.create(cap)
	root.add_child(pile)
	_put(pile, spots.gold_pile, attached)
	if not attached:
		# A warm lamp over the pile indoors; the neutral area has street lights.
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.85, 0.55)
		lamp.light_energy = 0.9
		lamp.omni_range = 3.2
		lamp.shadow_enabled = false
		lamp.light_volumetric_fog_energy = 0.15
		lamp.position = Vector3(0, 2.5, 0)
		pile.add_child(lamp)
	pile.set_count(game.gold_bars, false)


## Put a node at a {position, yaw} spot. `on_surface` lifts it onto whatever is under the spot
## (the neutral area's pallet).
func _put(n: Node3D, spot, on_surface: bool) -> void:
	var s: Dictionary = spot if spot is Dictionary else {"position": spot}
	var pos: Vector3 = s.get("position", s.get("pos", game.clock_pos()))
	if pos is Vector3 and on_surface:
		pos = game._surface_below(pos + Vector3.UP * 2.5, pos)
	n.global_position = pos
	n.rotation.y = float(s.get("yaw", 0.0))


## Free floor near the time clock, in its room, clear of everything the room already holds.
func _search_spots() -> Dictionary:
	var clock_raw: Vector3 = game.clock_pos()
	var clock: Vector3 = game._floor_at(clock_raw)
	var keep_clear: Array = [clock, game.table_pos()]  # downed: the Re-Gen Pod is gone
	for key in ["lectern", "shelf"]:
		var e = _info.get(key)
		if e is Dictionary and e.has("position"):
			keep_clear.append(e.position)
	for sp in _info.get("player_spawns", []):
		keep_clear.append(sp)
	var out := {}
	var taken: Array = []
	for want in [["sell_bin", 0.6], ["shop", 0.95], ["gold_pile", 0.75]]:
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
	# Floor under it.
	var down := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.2, p + Vector3.DOWN * 0.5)
	down.collision_mask = C.L_WORLD
	var hit := space.intersect_ray(down)
	if hit.is_empty() or absf((hit.position as Vector3).y - clock.y) > 0.25:
		return false
	# In the same room: nothing solid between the clock and the spot.
	var los := PhysicsRayQueryParameters3D.create(clock + Vector3.UP * 1.3, p + Vector3.UP * 1.3)
	los.collision_mask = C.L_WORLD
	if not space.intersect_ray(los).is_empty():
		return false
	# Room to stand in: a box from knee to head height, a little wider than the thing.
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(radius * 2.0 + 0.3, 1.6, radius * 2.0 + 0.3)
	q.shape = box
	q.transform = Transform3D(Basis(), (hit.position as Vector3) + Vector3.UP * 1.0)
	q.collision_mask = C.L_WORLD
	return space.intersect_shape(q, 1).is_empty()


## Warmup hook: build and show one of each economy visual so nothing compiles later.
static func warm(parent: Node3D) -> void:
	var bin := PropsScript.create("sell_bin", false)
	parent.add_child(bin)
	bin.position = Vector3(-1.2, -1.2, -1.5)
	var counter := PropsScript.create("shop", false)
	parent.add_child(counter)
	counter.position = Vector3(0.4, -1.6, -2.2)
	var p := GoldPileScript.create(INDOOR_PILE_CAP)
	parent.add_child(p)
	p.position = Vector3(1.4, -0.8, -1.2)
	p.set_count(40, false)
