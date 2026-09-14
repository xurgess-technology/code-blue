class_name Perception
extends RefCounted
## "Is anybody looking at this, and can they actually see it?"
##
## A point counts as observed when some living player
##   1. has it inside their camera's view frustum,
##   2. with a clear line of sight from the camera (ray on C.L_WORLD), and
##   3. the point is lit: by any living player's flashlight cone or near-glow
##      (Player.lights_point), or by a ceiling fixture that is on right now, in range,
##      with line of sight to the point.
##
## Cost, cheapest test first, early out on the first success:
##   frustum: pure maths per player. Rays only for players whose view contains the point.
##   flashlight: one ray per player whose cone/glow reaches the point.
##   fixtures: a squared-distance cull over level_info.lights, then an energy check,
##   then one ray per candidate (in practice 0-2 fixtures are within 5 m of a point).
## Callers (the Night Nurse) sample this a few times per second, not every frame.

const HB := preload("res://scripts/hospital_builder.gd")

## A fixture counts as on above this share of its healthy energy.
const LIT_FRACTION := 0.3
## Pools of fixture light fade out toward the edge of omni_range; the last stretch is dark.
const RANGE_USE := 0.85
## Stops a ray from counting the target surface itself as a blocker.
const RAY_SLACK := 0.08


static func is_observed(game: Node, point: Vector3) -> bool:
	return observed_any(game, [point])


## True when any of `points` is observed. The lighting test only runs for points some
## player can see, so sampling feet/chest/head costs about one frustum check per point.
static func observed_any(game: Node, points: Array) -> bool:
	if game == null:
		return false
	var watchers := _living(game)
	if watchers.is_empty():
		return false
	var space: PhysicsDirectSpaceState3D = (watchers[0] as Node3D).get_world_3d().direct_space_state
	# POCKETS HOOK: near a seam the body is also drawn in the other copy of the stub; seen there is seen.
	var pk = game.get("pockets")
	if pk != null and pk.active():
		points = points + pk.mirror_points(points)
	for point in points:
		var seen := false
		for p in watchers:
			if in_view(p, point) and _clear(space, _eye(p), point):
				seen = true
				break
		if seen and is_lit(game, point, watchers, space):
			return true
	return false


## Is the point lit right now, regardless of who is looking?
static func is_lit(game: Node, point: Vector3, watchers: Array = [], space: PhysicsDirectSpaceState3D = null) -> bool:
	if watchers.is_empty():
		watchers = _living(game)
	for p in watchers:
		if p.has_method("lights_point") and p.lights_point(point):
			return true
	return fixture_lit(game, point, space)


## Lit by a ceiling fixture that is currently on, in range, with line of sight.
static func fixture_lit(game: Node, point: Vector3, space: PhysicsDirectSpaceState3D = null) -> bool:
	var lights: Array = game.level_info.get("lights", []) if "level_info" in game else []
	for l in lights:
		var node = l.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var bulb := (node as Node).get_node_or_null("Bulb") as OmniLight3D
		if bulb == null or not bulb.is_visible_in_tree():
			continue
		var from := bulb.global_position
		var r := bulb.omni_range * RANGE_USE
		if from.distance_squared_to(point) > r * r:
			continue
		if bulb.light_energy <= _base_energy(bulb) * LIT_FRACTION:
			continue
		if space == null:
			space = bulb.get_world_3d().direct_space_state
		if _clear(space, from, point):
			return true
	return false


## Inside this player's camera frustum (vertical FOV, viewport aspect), ignoring walls.
static func in_view(p: Node, point: Vector3) -> bool:
	var cam: Camera3D = p.get("camera")
	if cam == null or not cam.is_inside_tree():
		return false
	var xf := cam.global_transform
	var to := point - xf.origin
	var fwd := -xf.basis.z
	var depth := to.dot(fwd)
	if depth < cam.near or depth > cam.far:
		return false
	var half_v := deg_to_rad(cam.fov) * 0.5
	var aspect := 16.0 / 9.0
	var vp := cam.get_viewport()
	if vp != null:
		var sz := vp.get_visible_rect().size
		if sz.y > 1.0:
			aspect = sz.x / sz.y
	var tan_v := tan(half_v)
	var tan_h := tan_v * aspect
	var up := xf.basis.y
	var right := xf.basis.x
	return absf(to.dot(up)) <= depth * tan_v and absf(to.dot(right)) <= depth * tan_h


static func _eye(p: Node) -> Vector3:
	var cam: Camera3D = p.get("camera")
	return cam.global_position if cam != null else (p as Node3D).global_position + Vector3.UP * C.EYE_H


static func _clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	var d := to - from
	var l := d.length()
	if l < 0.01:
		return true
	var q := PhysicsRayQueryParameters3D.create(from, from + d * ((l - RAY_SLACK) / l))
	q.collision_mask = C.L_WORLD
	return space.intersect_ray(q).is_empty()


static func _living(game: Node) -> Array:
	if game.has_method("alive_players"):
		return game.alive_players()
	var out := []
	for p in game.players.values():
		if p.alive:
			out.append(p)
	return out


## The fixture's healthy energy. LightFlicker stores it; dead fixtures start at 0, so fall
## back to the builder's constant rather than treating "0 of 0" as lit.
static func _base_energy(bulb: OmniLight3D) -> float:
	if bulb.has_meta("base_energy"):
		return maxf(0.05, float(bulb.get_meta("base_energy")))
	for c in bulb.get_children():
		if "base_energy" in c and float(c.base_energy) > 0.05:
			return float(c.base_energy)
	return HB.LIGHT_ENERGY
