extends Node
## POCKETS: the runtime side of pocket spaces. `game.pockets` (child "Pockets" of Game, every machine).
##
##   build(gen, info, parent)   after the hospital (with doors: after each shift's wings) is built:
##                              builds the rolled pocket far from the hospital, the pocket copy of
##                              every entrance stub, the navigation region and the seam links, and
##                              adds the pocket's lights, containers, anchors and monster spawns to
##                              `info` (see docs/CONTRACTS.md "Hospital", pockets).
##   build_kind(kind, info, parent, seed)   a pocket with no hospital entrances (the dev room).
##   teardown()                 forget everything (the nodes live under `parent` and go with it).
##
## Every physics frame, on every machine, anything a machine owns that stands past a seam is moved
## to the other copy of its stub (the move keeps its offset from the seam, its velocity and its
## facing): the local player and host bots on their own machine, monsters and loose world items on
## the host. Carried players and dragged monsters follow whoever pins them. Everything else (remote
## players and monsters on a client) arrives through the snapshots and snaps instead of lerping
## (`snap_distance`).

const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
const Stub := preload("res://scripts/level/pockets/stub.gd")
const Factory := preload("res://scripts/level/pockets/factory.gd")
const Restaurant := preload("res://scripts/level/pockets/restaurant.gd")
const Common := preload("res://scripts/level/pockets/pocket_common.gd")

## World tile of each pocket's local tile (0, 0): far outside any hospital (maps are ~110 m).
const ORIGINS := {"factory": Vector2i(800, 0), "restaurant": Vector2i(800, 500)}
## A remote body that jumps further than this between snapshots is moved, not interpolated.
const SNAP_DISTANCE := 6.0
## Noises within this many metres of a seam (on its own side) are also heard on the other side.
const NOISE_REACH := 26.0
const LINK_OFFSET := 0.6

var game: Node = null
## {kind, origin: Vector2i, rect: Rect2 (world XZ), root: Node3D, spawn: Vector3, wing, depth} or {}
var pocket: Dictionary = {}
## Seam records, see _make_seam.
var seams: Array = []
## Crossings this machine performed (tests): [{what, id, seam, to_pocket, time}]
var crossings: Array = []
## Tools (screenshots of both copies): false stops moving anything across seams.
var crossing_enabled := true
var _ghosts := {}


func setup(g: Node) -> void:
	game = g


func active() -> bool:
	return not pocket.is_empty()


# =========================================================================
# build / teardown
# =========================================================================

## Build the pocket planned into `gen` (MapGen, gen.spots.pocket). Does nothing without a plan.
func build(gen: Dictionary, info: Dictionary, parent: Node3D) -> void:
	teardown()
	var plan := Plan.of(gen)
	if plan.is_empty():
		info["pockets"] = {}
		return
	pocket = build_into(String(plan.kind), plan.stubs, int(plan.seed), int(gen.get("seed", 0)), gen.get("lights", []), info, parent, seams)
	# The pocket's depth and wing for spawning rules: the deepest wing it connects to.
	for s in seams:
		if int(s.depth) > int(pocket.get("depth", -1)):
			pocket["depth"] = int(s.depth)
			pocket["wing"] = String(s.wing)


## A pocket with no hospital (the dev room): two stand-in stubs, both sealed on the far side.
func build_kind(kind: String, info: Dictionary, parent: Node3D, pocket_seed: int) -> void:
	teardown()
	var stubs := [
		{"id": 0, "wing": "dev", "depth": 2, "zone": Plan.ZONE_STUB, "o": Vector2i(-400, -400), "eu": Vector2i(1, 0), "ev": Vector2i(0, 1), "w": 10, "d": 6, "lights": []},
		{"id": 1, "wing": "dev", "depth": 2, "zone": Plan.ZONE_STUB, "o": Vector2i(-400, -380), "eu": Vector2i(-1, 0), "ev": Vector2i(0, 1), "w": 10, "d": 6, "lights": []},
	]
	pocket = build_into(kind, stubs, pocket_seed, pocket_seed, [], info, parent, seams, false)
	pocket["depth"] = 2
	pocket["wing"] = "dev"


## Shared by build() and tools/mapcheck.gd (which builds without a Game). Fills `out_seams`.
static func build_into(kind: String, stubs: Array, pocket_seed: int, map_seed: int, hospital_lights: Array,
		info: Dictionary, parent: Node3D, out_seams: Array, links := true) -> Dictionary:
	var layout_script: GDScript = Factory if kind == "factory" else Restaurant
	var origin: Vector2i = ORIGINS.get(kind, Vector2i(800, 0))
	var lay: Dictionary = layout_script.layout(stubs, pocket_seed)
	var root := Node3D.new()
	root.name = "Pocket_" + kind
	parent.add_child(root)
	var out := {"lights": [], "containers": [], "loose_anchors": [], "monster_spawns": [], "nav_faces": PackedVector3Array()}
	var depth := 1
	var wing := ""
	for s in stubs:
		if int(s.depth) >= depth:
			depth = int(s.depth)
			wing = String(s.wing)
	out["wing"] = wing
	out["depth"] = depth
	root.add_child(layout_script.build(lay, origin, out))
	# Entrance copies, seams and links.
	var copies := Node3D.new()
	copies.name = "Stubs"
	root.add_child(copies)
	for i in stubs.size():
		var s: Dictionary = stubs[i]
		var port: Dictionary = lay.ports[i]
		var seam := _make_seam(s, port, origin)
		var holder := Node3D.new()
		holder.name = "Seam_%d" % i
		holder.transform = seam.t
		copies.add_child(holder)
		var copy := Stub.build_copy(s, map_seed, hospital_lights)
		holder.add_child(copy.node)
		for l in copy.lights:
			out.lights.append({"tile": l.tile, "position": seam.t * (l.position as Vector3), "mode": l.mode, "node": l.node, "pocket": kind})
		if links:
			var link := NavigationLink3D.new()
			link.name = "Link_%d" % i
			link.bidirectional = true
			link.start_position = seam.link_h
			link.end_position = seam.link_p
			# Far apart in the world, one step apart on foot: cost the distance actually walked.
			link.travel_cost = 1.0 / maxf(1.0, seam.link_h.distance_to(seam.link_p))
			link.enter_cost = 0.0
			root.add_child(link)
			seam["link"] = link
		out_seams.append(seam)
	# Navigation over the pocket's own grid (stub copies included, the halves never walked left out).
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	nav.navigation_mesh = Common.bake_nav(out.nav_faces)
	root.add_child(nav)
	var world_rect := Rect2(Vector2(origin) * C.TILE, Vector2(lay.size) * C.TILE)
	var p := {"kind": kind, "origin": origin, "rect": world_rect, "root": root, "nav_region": nav,
			"spawn": out.get("spawn", Vector3(world_rect.get_center().x, 0.0, world_rect.get_center().y)),
			"rows": lay.rows, "size": lay.size, "wing": wing, "depth": depth, "layout": lay}
	# The contract keys the rest of the game reads.
	for key in ["lights", "containers", "loose_anchors", "monster_spawns"]:
		if not info.has(key):
			info[key] = []
		(info[key] as Array).append_array(out[key])
	var seam_info: Array = []
	for s in out_seams:
		seam_info.append({"id": s.id, "wing": s.wing, "depth": s.depth, "w": s.w, "d": s.d,
				"hospital": s.xh, "pocket": s.xp, "transform": s.t,
				"mouth": s.mouth, "opening": s.opening, "link": [s.link_h, s.link_p]})
	info["pockets"] = {"kind": kind, "rect": world_rect, "origin": origin, "spawn": p.spawn, "wing": wing,
			"depth": depth, "seams": seam_info, "nav_region": nav}
	return p


static func _make_seam(s: Dictionary, port: Dictionary, origin: Vector2i) -> Dictionary:
	var w: int = s.w
	var d: int = s.d
	var xh := Stub.frame(s.o, s.eu, s.ev)
	var xp := Stub.frame(origin + (port.o as Vector2i), port.eu, port.ev)
	var t := xp * xh.affine_inverse()
	var mid := Stub.seam_s(w)
	var back := float(d) - Stub.CORRIDOR * 0.5
	return {"id": int(s.id), "wing": String(s.wing), "depth": int(s.depth), "w": w, "d": d,
			"xh": xh, "xp": xp, "t": t, "t_inv": t.affine_inverse(), "yaw": t.basis.get_euler().y,
			"link_h": Stub.local_point(xh, mid - LINK_OFFSET / Stub.T, back),
			"link_p": Stub.local_point(xp, mid + LINK_OFFSET / Stub.T, back),
			"seam_h": Stub.local_point(xh, mid, back), "seam_p": Stub.local_point(xp, mid, back),
			"mouth": Stub.local_point(xh, Stub.CORRIDOR * 0.5, -1.5),
			"opening": Stub.local_point(xp, float(w) - Stub.CORRIDOR * 0.5, -1.5)}


func teardown() -> void:
	_blend_environment(0.0)
	for g in _ghosts.values():
		if is_instance_valid(g):
			g.queue_free()
	_ghosts.clear()
	if not pocket.is_empty() and is_instance_valid(pocket.get("root")):
		(pocket.root as Node).queue_free()
	pocket = {}
	seams = []


# =========================================================================
# queries
# =========================================================================

## "" for the hospital (or no pocket), else the pocket's kind.
func space_of(p: Vector3) -> String:
	if pocket.is_empty():
		return ""
	return String(pocket.kind) if (pocket.rect as Rect2).grow(2.0).has_point(Vector2(p.x, p.z)) else ""


func in_pocket(p: Vector3) -> bool:
	return space_of(p) != ""


## [seam, to_pocket] when `p` stands in the half of a stub copy nobody should stand in, else [].
func phantom_at(p: Vector3) -> Array:
	for s in seams:
		for to_pocket in [true, false]:
			var l := Stub.to_local(s.xh if to_pocket else s.xp, p)
			if l.y < -1.5 or l.y > C.WALL_H + 1.0:
				continue
			if l.z < 0.0 or l.z > float(s.d) or l.x < 0.0 or l.x > float(s.w):
				continue
			var past: bool = l.x >= Stub.seam_s(s.w)
			if past == to_pocket:
				return [s, to_pocket]
	return []


## The real place a point stands for: a point in a stub's unwalked half maps to the other copy.
func real_point(p: Vector3) -> Vector3:
	var hit := phantom_at(p)
	if hit.is_empty():
		return p
	return (hit[0].t if hit[1] else hit[0].t_inv) * p


## Monster steering: the next path point after a seam link lies in the other space; walk toward
## where it is in this space instead (across the seam), and the crossing does the rest.
func steer_point(from: Vector3, next: Vector3) -> Vector3:
	if seams.is_empty() or space_of(from) == space_of(next):
		return next
	var into_pocket := in_pocket(next)
	var best := next
	var best_d := 8.0
	for s in seams:
		var m: Vector3 = (s.t_inv if into_pocket else s.t) * next
		var dd := Vector2(m.x - from.x, m.z - from.z).length()
		if dd < best_d:
			best_d = dd
			best = m
	return best


## Extra noise positions on the other side of each seam near `pos` (host, emit_noise).
func mirror_noise(pos: Vector3, loudness: float) -> Array:
	var out: Array = []
	if seams.is_empty():
		return out
	var here_pocket := in_pocket(pos)
	for s in seams:
		var seam_here: Vector3 = s.seam_p if here_pocket else s.seam_h
		if pos.distance_to(seam_here) > minf(NOISE_REACH, loudness * 22.0 + 4.0):
			continue
		# Where the noise is in this copy's own frame, pulled into the stub's walked half, then the
		# same spot in the other copy (its unwalked half: real_point() leads there through the seam).
		var own: Transform3D = s.xp if here_pocket else s.xh
		var other: Transform3D = s.xh if here_pocket else s.xp
		var l := Stub.to_local(own, pos)
		var mid := Stub.seam_s(s.w)
		var back := float(s.d) - Stub.CORRIDOR * 0.5
		var sl := clampf(l.x, 0.6, mid - 0.2) if not here_pocket else clampf(l.x, mid + 0.2, float(s.w) - 0.6)
		var tl := clampf(l.z, 0.4, back)
		out.append(Stub.local_point(other, sl, tl, clampf(l.y, 0.0, 2.5)))
	return out


# =========================================================================
# crossing
# =========================================================================

func _physics_process(_delta: float) -> void:
	if seams.is_empty() or game == null or not crossing_enabled:
		return
	var host: bool = game.is_host()
	for p in game.players.values():
		if not is_instance_valid(p) or not p.alive:
			continue
		var owns: bool = p.is_local or (p.is_bot and host)
		if not owns or p.carried_by != 0 or p.on_table:
			continue
		var hit := phantom_at(p.global_position)
		if not hit.is_empty():
			transfer_player(p, hit[0], hit[1])
	if host:
		for m in game.monsters.values():
			if not is_instance_valid(m) or int(m.get("dragged_by")) != 0:
				continue
			var hit := phantom_at(m.global_position)
			if not hit.is_empty():
				transfer_monster(m, hit[0], hit[1])
		for it in game.world_items.values():
			if not is_instance_valid(it) or it.get("state") != WorldItem.State.LOOSE:
				continue
			var hit := phantom_at(it.global_position)
			if not hit.is_empty():
				transfer_item(it, hit[0], hit[1])
	_update_ghosts()


func transfer_player(p: Node, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var yaw: float = s.yaw if to_pocket else -float(s.yaw)
	p.global_position = t * p.global_position
	p.velocity = t.basis * p.velocity
	p.rotation.y += yaw
	p.set("_yaw", float(p.get("_yaw")) + yaw)
	p.bot_yaw += yaw
	p.set("_knock", t.basis * (p.get("_knock") as Vector3))
	p.set("_target_pos", p.global_position)
	p.set("_target_yaw", p.rotation.y)
	# Whoever rides along is put where they belong now, not a frame later on the far side of the world.
	if int(p.carrying) != 0 and game != null:
		var q = game.players.get(int(p.carrying))
		if q != null and is_instance_valid(q):
			var pose: Transform3D = game.pinned_pose(q)
			q.global_position = pose.origin
			q.set("_target_pos", pose.origin)
	var dm := int(p.get("dragging_monster")) if p.get("dragging_monster") != null else -1
	if dm >= 0 and game != null and game.combat != null and game.combat.has_method("monster_pin"):
		var m = game.monsters.get(dm)
		if m != null and is_instance_valid(m):
			m.global_position = (game.combat.monster_pin(m) as Transform3D).origin
			m.set("_target_pos", m.global_position)
	_note("player", int(p.peer_id), s, to_pocket)


func transfer_monster(m: Node, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var yaw: float = s.yaw if to_pocket else -float(s.yaw)
	m.global_position = t * m.global_position
	m.velocity = t.basis * m.velocity
	m.rotation.y += yaw
	m.set("_target_pos", m.global_position)
	m.set("_target_yaw", m.rotation.y)
	m.set("_repath", 0.0)
	_note("monster", int(m.monster_id), s, to_pocket)


func transfer_item(it: RigidBody3D, s: Dictionary, to_pocket: bool) -> void:
	var t: Transform3D = s.t if to_pocket else s.t_inv
	var xf := t * it.global_transform
	var lv := t.basis * it.linear_velocity
	var av := t.basis * it.angular_velocity
	PhysicsServer3D.body_set_state(it.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	it.global_transform = xf
	it.linear_velocity = lv
	it.angular_velocity = av
	_note("item", int(it.item_id), s, to_pocket)


func _note(what: String, id: int, s: Dictionary, to_pocket: bool) -> void:
	crossings.append({"what": what, "id": id, "seam": int(s.id), "to_pocket": to_pocket,
			"time": float(game.world_time) if game != null else 0.0})
	if crossings.size() > 64:
		crossings.pop_front()


# =========================================================================
# the space's own air: fog tuned per pocket, blended in away from the entrances
# =========================================================================

## Environment values each pocket blends toward, deeper than a few metres inside it.
const AIR := {
	"factory": {"fog_depth_begin": 14.0, "fog_depth_end": 78.0, "fog_density": 0.5, "volumetric_fog_density": 0.03,
			"ambient_light_energy": 0.13, "ambient_light_color": Color(0.26, 0.55, 0.44)},
	"restaurant": {"fog_depth_begin": 16.0, "fog_depth_end": 60.0, "fog_density": 0.35, "volumetric_fog_density": 0.016,
			"ambient_light_energy": 0.3, "ambient_light_color": Color(0.62, 0.46, 0.34)},
}
var _air_base := {}
var _air_env: Environment = null
var _air_k := 0.0


func _process(_delta: float) -> void:
	if pocket.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	_blend_environment(air_factor(cam.global_position))


## 0 in the hospital, in an entrance stub and near its opening; 1 well inside the space.
func air_factor(p: Vector3) -> float:
	if pocket.is_empty() or not in_pocket(p):
		return 0.0
	var nearest := INF
	for s in seams:
		var l := Stub.to_local(s.xp, p)
		if l.x > -1.5 and l.x < float(s.w) + 1.5 and l.z > -1.2 and l.z < float(s.d) + 1.0:
			return 0.0
		nearest = minf(nearest, Vector2(p.x - s.opening.x, p.z - s.opening.z).length())
	return smoothstep(3.0, 14.0, nearest)


func _blend_environment(k: float) -> void:
	if k <= 0.0 and _air_k <= 0.0:
		return
	if _air_env == null or not is_instance_valid(_air_env):
		var we := get_tree().root.find_child("LookEnvironment", true, false) as WorldEnvironment if is_inside_tree() else null
		if we == null or we.environment == null:
			return
		_air_env = we.environment
	if _air_k <= 0.0:
		_air_base = {}
		for key in AIR.factory.keys():
			_air_base[key] = _air_env.get(key)
	_air_k = k
	var target: Dictionary = AIR.get(String(pocket.get("kind", "")), {})
	for key in _air_base.keys():
		var base = _air_base[key]
		var want = target.get(key, base)
		if base is Color:
			_air_env.set(key, (base as Color).lerp(want, k))
		else:
			_air_env.set(key, lerpf(float(base), float(want), k))


# =========================================================================
# ghosts: a teammate walking through a seam ahead of you does not vanish
# =========================================================================

## Remote players within reach of a seam also show in the other copy of the stub (visual only).
func _update_ghosts() -> void:
	var viewer: Node = game.viewed_player() if game.has_method("viewed_player") else null
	var want := {}
	if viewer != null:
		for p in game.players.values():
			if not is_instance_valid(p) or p == viewer or not p.alive or p.body_visual == null or not p.body_visual.visible:
				continue
			for s in seams:
				for from_h in [true, false]:
					var seam_here: Vector3 = s.seam_h if from_h else s.seam_p
					if p.global_position.distance_to(seam_here) > 7.0:
						continue
					var t: Transform3D = s.t if from_h else s.t_inv
					var key := "%d|%d|%s" % [p.peer_id, int(s.id), str(from_h)]
					want[key] = [p, t]
	for key in _ghosts.keys():
		if not want.has(key):
			if is_instance_valid(_ghosts[key]):
				_ghosts[key].queue_free()
			_ghosts.erase(key)
	for key in want.keys():
		var p: Node3D = want[key][0]
		var t: Transform3D = want[key][1]
		var g: Node3D = _ghosts.get(key)
		if g == null or not is_instance_valid(g):
			g = _make_ghost(p)
			if g == null:
				continue
			add_child(g)
			_ghosts[key] = g
		var src: Node3D = p.body_visual
		g.global_transform = t * src.global_transform


func _make_ghost(p: Node) -> Node3D:
	var src: Node3D = p.get("body_visual")
	if src == null:
		return null
	var g := src.duplicate(0) as Node3D
	g.name = "Ghost_%d" % int(p.peer_id)
	for n in g.find_children("*", "CollisionObject3D", true, false):
		n.queue_free()
	return g
