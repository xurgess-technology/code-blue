extends Node3D
## The Night Nurse in the hub's waiting room (hub rebuild, chunk 3, Zach's playtest): scenery, never a
## threat, never comes for anyone. She sits in one of the chairs; now and then, only while nobody is
## watching, she gets up and moves: to another chair, or to stand in a corner facing the wall. The
## moment someone sees her (Perception: in view, clear line, lit) she freezes in whatever she was
## doing, mid-step or half out of her chair, and carries on once they look away.
##
## The host decides everything (mode, path, timers) and the result replicates in the game snapshot
## ("wn": position, yaw, how seated, walking, seen); every machine shows it the same way. A new shift
## sits her down in a fresh chair.

const MonsterModelScript := preload("res://scripts/monsters/monster_model.gd")
const Percept := preload("res://scripts/perception.gd")
const NurseRig := preload("res://scripts/monsters/night_nurse_rig.gd")

const SPEED := 0.9
const RISE_SECONDS := 1.5
const OBSERVE_EVERY := 0.2
const SIT_HOLD := Vector2(25.0, 70.0)
const STAND_HOLD := Vector2(15.0, 40.0)
## How far in front of a chair she stops before turning and sitting down.
const SEAT_APPROACH := 0.55
## Share of moves that go to another chair rather than a corner.
const SEAT_CHANCE := 0.55

var game: Node = null
## Scannable (game.scan_props): the scan system reads these like a monster's.
var kind := "night_nurse"
var height := 2.3
var scan_id := -10
var seats: Array = []      # [{position, yaw}]
var corners: Array = []    # [{position, yaw}]
var model: Node3D = null

# ---- replicated (host truth) ----
var pos := Vector3.ZERO    # where she stands, or the seat she sits on
var yaw := 0.0
var sit := 1.0
var walking := false
var seen := false

# ---- host only ----
var _mode := "sit"         # sit | rise | walk | sitdown | stand
var _hold := 0.0
var _obs_t := 0.0
var _path := PackedVector3Array()
var _path_d := 0.0
var _path_len := 0.0
var _goal := {}
var _approach := Vector3.ZERO
var _shift := -1
var _rng := RandomNumberGenerator.new()

# ---- shown ----
var _shown_pos := Vector3.ZERO
var _shown_yaw := 0.0
var _clip := ""


static func create(g: Node, info: Dictionary) -> Node3D:
	var n: Node3D = (load("res://scripts/economy/waiting_nurse.gd") as GDScript).new()
	n.name = "WaitingNurse"
	n.set_meta("light_dynamic", true)   # she walks between chairs: lit like anyone else (light_rooms.gd)
	n.game = g
	n.seats = info.get("waiting_seats", [])
	n.corners = info.get("waiting_corners", [])
	return n


func _ready() -> void:
	model = MonsterModelScript.new()
	add_child(model)
	model.setup("night_nurse")
	_skirt_follows_thighs()
	top_level = true
	# Scannable like a monster, but on its own layer: nothing else collides with or hits her.
	var body := StaticBody3D.new()
	body.name = "ScanBody"
	body.collision_layer = C.L_SCAN
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32
	cap.height = 1.9
	cs.shape = cap
	cs.position = Vector3(0.0, 1.15, 0.0)
	body.add_child(cs)
	add_child(body)
	if game != null:
		game.scan_props.append(self)
	if not seats.is_empty():
		_sit_in(seats[0])


func _process(delta: float) -> void:
	if game == null or seats.is_empty():
		return
	if game.is_host():
		if int(game.shift) != _shift:
			_reseat()
		_tick_host(delta)
		_shown_pos = pos
		_shown_yaw = yaw
	else:
		var k := clampf(delta * 10.0, 0.0, 1.0)
		_shown_pos = _shown_pos.lerp(pos, k) if _shown_pos.distance_to(pos) < 3.0 else pos
		_shown_yaw = lerp_angle(_shown_yaw, yaw, k)
	_apply_visual()


func _exit_tree() -> void:
	if game != null and is_instance_valid(game):
		game.scan_props.erase(self)


# ---------------------------------------------------------------------------
# host

func _reseat() -> void:
	_shift = int(game.shift)
	_rng.seed = hash("%d|waiting_nurse|%d" % [int(game.seed_value), _shift])
	_sit_in(seats[_rng.randi_range(0, seats.size() - 1)])
	_mode = "sit"
	_hold = _rng.randf_range(SIT_HOLD.x, SIT_HOLD.y)


func _sit_in(seat: Dictionary) -> void:
	pos = seat.position
	yaw = float(seat.yaw)
	sit = 1.0
	walking = false
	_shown_pos = pos
	_shown_yaw = yaw


func _body_points() -> Array:
	var squash := 1.0 - 0.4 * sit
	return [pos + Vector3.UP * 0.35 * squash, pos + Vector3.UP * 1.3 * squash, pos + Vector3.UP * 2.0 * squash]


func _tick_host(delta: float) -> void:
	_obs_t -= delta
	if _obs_t <= 0.0:
		_obs_t = OBSERVE_EVERY
		seen = Percept.observed_any(game, _body_points())
	match _mode:
		"sit":
			_hold -= delta
			if _hold <= 0.0 and not seen:
				_pick_goal()
				_mode = "rise"
		"rise":
			if not seen:
				sit = move_toward(sit, 0.0, delta / RISE_SECONDS)
				# Up out of the chair and a step forward, clear of it.
				pos = pos.lerp(_approach, clampf(delta / RISE_SECONDS, 0.0, 1.0) * 2.0) if sit < 0.5 else pos
				if sit <= 0.0:
					_start_walk()
		"walk":
			if not seen:
				_path_d += SPEED * delta
				var at := _along(_path_d)
				pos = at[0]
				var dir: Vector3 = at[1]
				if Vector2(dir.x, dir.z).length() > 0.01:
					yaw = atan2(-dir.x, -dir.z)
				if _path_d >= _path_len:
					walking = false
					yaw = float(_goal.yaw)
					if bool(_goal.get("seat", false)):
						_mode = "sitdown"
					else:
						pos = _goal.position
						_mode = "stand"
						_hold = _rng.randf_range(STAND_HOLD.x, STAND_HOLD.y)
		"sitdown":
			if not seen:
				sit = move_toward(sit, 1.0, delta / RISE_SECONDS)
				pos = _approach.lerp(_goal.position, clampf(sit * 1.6, 0.0, 1.0))
				if sit >= 1.0:
					pos = _goal.position
					_mode = "sit"
					_hold = _rng.randf_range(SIT_HOLD.x, SIT_HOLD.y)
		"stand":
			_hold -= delta
			if _hold <= 0.0 and not seen:
				_pick_goal(true)
				_start_walk()


## Where to next: another chair, or a corner (after a corner, always a chair).
func _pick_goal(from_corner := false) -> void:
	var to_seat := from_corner or corners.is_empty() or _rng.randf() < SEAT_CHANCE
	if to_seat:
		var s: Dictionary = seats[_rng.randi_range(0, seats.size() - 1)]
		for i in 6:
			if (s.position as Vector3).distance_to(pos) > 1.0:
				break
			s = seats[_rng.randi_range(0, seats.size() - 1)]
		var front := Vector3(-sin(float(s.yaw)), 0.0, -cos(float(s.yaw)))
		_goal = {"position": s.position, "yaw": float(s.yaw), "seat": true, "approach": (s.position as Vector3) + front * SEAT_APPROACH}
	else:
		var c: Dictionary = corners[_rng.randi_range(0, corners.size() - 1)]
		_goal = {"position": c.position, "yaw": float(c.yaw), "seat": false, "approach": c.position}
	if _mode == "sit":
		# Getting up: the first step is straight out in front of the chair she's in.
		_approach = pos + Vector3(-sin(yaw), 0.0, -cos(yaw)) * SEAT_APPROACH


func _start_walk() -> void:
	var target: Vector3 = _goal.approach
	_path = _nav_path(pos, target)
	_path_len = 0.0
	for i in range(1, _path.size()):
		_path_len += _path[i].distance_to(_path[i - 1])
	_path_d = 0.0
	_approach = target
	walking = true
	_mode = "walk"


func _nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var map: RID = get_world_3d().navigation_map
	var pts := PackedVector3Array()
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		pts = NavigationServer3D.map_get_path(map, NavigationServer3D.map_get_closest_point(map, from),
				NavigationServer3D.map_get_closest_point(map, to), true)
	if pts.size() < 2:
		pts = PackedVector3Array([from, to])
	pts[0] = from
	pts[pts.size() - 1] = to
	return pts


func _along(d: float) -> Array:
	var left := d
	for i in range(1, _path.size()):
		var seg := _path[i].distance_to(_path[i - 1])
		if left <= seg or i == _path.size() - 1:
			var k := clampf(left / maxf(seg, 0.001), 0.0, 1.0)
			return [_path[i - 1].lerp(_path[i], k), _path[i] - _path[i - 1]]
		left -= seg
	return [_path[_path.size() - 1], Vector3.ZERO]


# ---------------------------------------------------------------------------
# the skirt

## Her dress below the hips is skinned to her hips, so when she sits and her thighs swing forward they
## push straight through the front of it. On this copy of her mesh only, the skirt below the hips
## follows the thigh on its side instead (fully at the front, a little at the back), so it drapes
## over her lap. Every machine, once, on its own copy of the mesh.
func _skirt_follows_thighs() -> void:
	if model == null or model.rig == null or model.skeleton == null:
		return
	var sk: Skeleton3D = model.skeleton
	for mi: MeshInstance3D in model.rig.find_children("*", "MeshInstance3D", true, false):
		var mesh := mi.mesh as ArrayMesh
		if mesh == null or mi.skin == null:
			continue
		# Skin bind index -> bone name.
		var bind_name := {}
		for b in mi.skin.get_bind_count():
			var n := String(mi.skin.get_bind_name(b))
			if n == "" and mi.skin.get_bind_bone(b) >= 0:
				n = sk.get_bone_name(mi.skin.get_bind_bone(b))
			bind_name[b] = n
		var thigh := {"L": -1, "R": -1}
		for b in bind_name.keys():
			if bind_name[b] == "thigh.L":
				thigh.L = b
			elif bind_name[b] == "thigh.R":
				thigh.R = b
		if thigh.L < 0 or thigh.R < 0:
			continue
		var out := ArrayMesh.new()
		for s in mesh.get_surface_count():
			var mdt := MeshDataTool.new()
			if mdt.create_from_surface(mesh, s) != OK:
				continue
			for v in mdt.get_vertex_count():
				var p := mdt.get_vertex(v)
				var bones := mdt.get_vertex_bones(v)
				var weights := mdt.get_vertex_weights(v)
				var hip_w := 0.0
				for i in bones.size():
					if bind_name.get(bones[i], "") in ["hips", "spine"]:
						hip_w += weights[i]
				if hip_w < 0.4 or p.y > 1.08:
					continue
				var f := smoothstep(1.08, 0.8, p.y) * lerpf(0.3, 1.0, clampf(p.z / 0.1 + 0.5, 0.0, 1.0))
				# Split between the thighs across the middle, so the front of the skirt stretches over
				# both knees instead of tearing open between them.
				var left := smoothstep(-0.09, 0.09, p.x)
				var w := {}
				for i in bones.size():
					if weights[i] > 0.0:
						w[bones[i]] = float(w.get(bones[i], 0.0)) + weights[i] * (1.0 - f)
				w[thigh.L] = float(w.get(thigh.L, 0.0)) + f * left
				w[thigh.R] = float(w.get(thigh.R, 0.0)) + f * (1.0 - left)
				var keys: Array = w.keys()
				keys.sort_custom(func(a, b): return float(w[a]) > float(w[b]))
				var total := 0.0
				for i in mini(bones.size(), keys.size()):
					total += float(w[keys[i]])
				for i in bones.size():
					if i < keys.size():
						bones[i] = int(keys[i])
						weights[i] = float(w[keys[i]]) / maxf(total, 0.0001)
					else:
						weights[i] = 0.0
				mdt.set_vertex_bones(v, bones)
				mdt.set_vertex_weights(v, weights)
			mdt.commit_to_surface(out)
			out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(s))
		if out.get_surface_count() == mesh.get_surface_count():
			var overrides: Array = []
			for s in mesh.get_surface_count():
				overrides.append(mi.get_surface_override_material(s))
			mi.mesh = out
			for s in overrides.size():
				# Both sides of the cloth drawn: seated, you look down into the skirt from above, and its
				# inside should read as cloth, not a hole onto her stockings.
				var m: Material = overrides[s] if overrides[s] != null else out.surface_get_material(s)
				if m is BaseMaterial3D:
					var two := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
					two.cull_mode = BaseMaterial3D.CULL_DISABLED
					mi.set_surface_override_material(s, two)
				elif overrides[s] != null:
					mi.set_surface_override_material(s, overrides[s])


# ---------------------------------------------------------------------------
# every machine

func _apply_visual() -> void:
	if model == null:
		return
	global_position = _shown_pos + Vector3.DOWN * NurseRig.SIT_DROP * sit
	rotation = Vector3(0.0, _shown_yaw, 0.0)
	var poser = model.get("nurse")
	if poser != null:
		poser.sit = sit
	if model.anim == null:
		return
	if walking:
		if _clip != "walk":
			_clip = "walk"
			model.play("walk", 1.0)
		model.anim.speed_scale = 0.0 if seen else SPEED
	elif sit > 0.0:
		if _clip != "sit":
			_clip = "sit"
			model.anim.stop()
			model.skeleton.reset_bone_poses()
	else:
		if _clip != "still":
			_clip = "still"
			model.play("idle", 0.0)
		model.anim.speed_scale = 0.0


func net_state() -> Dictionary:
	return {"p": pos.snappedf(0.01), "y": snappedf(yaw, 0.01), "s": snappedf(sit, 0.01), "w": walking, "f": seen}


func apply_net_state(s: Dictionary) -> void:
	if game != null and game.is_host():
		return
	pos = s.get("p", pos)
	yaw = float(s.get("y", yaw))
	sit = float(s.get("s", sit))
	walking = bool(s.get("w", walking))
	seen = bool(s.get("f", seen))
