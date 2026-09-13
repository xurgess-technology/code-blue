extends "res://scripts/surgery/minigame.gd"
## Step "extract": pull the bullet out of a gunshot wound with forceps. Operation, in flesh.
##
## The work plane shows the wound opening and a winding wound channel generated from ctx.seed,
## with the slug lodged at the far end. The forceps tips follow the cursor and are pinned inside
## the channel.
##
## ENTER   bring the tips to the opening; they drop into the wound.
## SEEK    follow the channel down. Pushing past a wall or moving faster than SPEED_MAX is
##         scraping: a flinch, a spurt of blood, HIT_COST once per contact, then a steady rate.
##         The channel gets darker the deeper it goes.
## GRIP    over the bullet and roughly still, hold primary: the jaws close on the slug. Closing
##         anywhere else closes on nothing; let go and try again.
## EXTRACT keep holding primary and draw it back to the opening. The slug makes the tool wider,
##         so the free margin is smaller and the speed limit is lower. Letting go (or ramming a
##         wall hard) drops it and it slides back down the channel. Leaving the opening with
##         the slug in the jaws finishes: {"bullet_removed": true}, and it clinks into the dish.
##
## Tip positions are in plane metres. The channel is a polyline sampled every SAMPLE metres;
## s is the arc length from the opening (s = 0) to the bullet end (s = length).

enum Stage { OUTSIDE, SEEK, AT_BULLET, GRIPPED, DONE }

# Channel ---------------------------------------------------------------------
const SAMPLE := 0.001
const RIM := 1.8               # rim width beyond the wall, in half-widths
const PATCH_Y := 0.02          # exposed-skin window height above the plane (clears gown folds)
const LIFT := 0.029            # wound rim height above the plane
const DEPTH_NEAR := 0.0035     # trench depth at the opening
const DEPTH_FAR := 0.0078      # trench depth at the bullet
const DISH_Y := 0.012          # kidney dish base height on the plane
const MOUTH_S := 0.008         # within this far of the opening the tips can leave the wound

# Tool ------------------------------------------------------------------------
const TOOL_R_OPEN := 0.0028    # half-width of the open jaws
const BULLET_R := 0.0045
const BULLET_LEN := 0.012
const TOOL_R_GRIP := 0.0058    # half-width of jaws holding the slug
const GRAB_R := 0.008          # tip within this of the slug centre can grip
const GRAB_SPEED := 0.04       # and moving slower than this
const JAW_CLOSE_RATE := 3.5
const JAW_OPEN_RATE := 6.0
const JAW_ON_BULLET := 0.62
const ARM_LEN := 0.125
const TOOL_PITCH := deg_to_rad(48.0)

# Rules -----------------------------------------------------------------------
const SPEED_MAX_OPEN := 0.10   # m/s
const SPEED_MAX_GRIP := 0.07
const SPEED_TAU := 0.12
const JOLT_DIST := 0.015       # a cursor jump bigger than this in one frame is a jolt, not speed
const CONTACT_PEN := 0.0004
const HIT_COST := 1.0
const HIT_COOLDOWN := 0.6
const SCRAPE_RATE := 3.2       # vitals per second at 3 mm past the wall
const SPEED_RATE := 2.2        # vitals per second when too fast
const DROP_PEN := 0.006        # grinding the slug this hard into a wall...
const DROP_TIME := 0.35        # ...for this long makes it slip out of the jaws
const SLIDE_BACK := 0.022
const SLIDE_SPEED := 0.05
const EMIT_CHUNK := 0.75

# Channel data
var pts := PackedVector2Array()
var widths := PackedFloat32Array()
var length := 0.14
var hw_base := 0.012
var bends := 3
var bullet_home := 0.13
var dish_pos := Vector2(0.15, 0.0)
var bbox := Rect2()

# Simulation (operator)
var inside := false
var tip := Vector2.ZERO
var tip_s := 0.0
var jaw := 0.0
var gripped := false
var empty_closed := false
var bullet_s := 0.13
var slide_target := 0.13
var speed := 0.0
var contact := false
var scraping := false
var too_fast := false
var hits := 0
var drops := 0
var damage := 0.0
var stage: int = Stage.OUTSIDE
var _last_cursor = null
var _hit_cd := 0.0
var _spurt_cd := 0.0
var _acc := 0.0
var _acc_reason := ""
var _time := 0.0
var _grind := 0.0

# Display state (written by the operator's simulation and by apply_net_state)
var _d_tip := Vector2.ZERO
var _d_inside := false
var _d_jaw := 0.0
var _d_gripped := false
var _d_bullet_s := 0.13
var _d_stage: int = Stage.OUTSIDE
var _d_hits := 0
var _d_damage := 0.0

# Visuals
var _vis_tip := Vector2.ZERO
var _vis_s := 0.0
var _vis_y := 0.03
var _vis_yaw := 0.0
var _vis_jaw := 0.0
var _seen_hits := 0
var _shake := 0.0
var _bleed := 0.0
var _bleed_sent := -1.0
var _bleed_cd := 0.0
var _squelch_cd := 0.0
var _squelch_from := Vector2.ZERO
var _was_closed := false
var _done_anim := -1.0
var _clinked := false
var _dish_rest := Vector2.ZERO
var _vrng := RandomNumberGenerator.new()
var _built := false

var _tool: Node3D
var _arms: Array[Node3D] = []
var _bullet: Node3D
var _bullet_mat: StandardMaterial3D
var _lead_mat: StandardMaterial3D
var _drops_nodes: Array = []   # [{node, vel: Vector3}]
var _splats: Array[Node3D] = []
var _splat_mat: StandardMaterial3D
var _drop_mesh: SphereMesh
var _splat_mesh: CylinderMesh

# Bot
var _b_last_t := -1.0
var _b_phase := "enter"
var _b_sb := 0.0
var _b_cursor = null
var _b_wait := 0.0
var _b_dropped_once := false
var _b_burst := 0.0
var _b_burst_cd := 2.0
var _b_rng := RandomNumberGenerator.new()


func setup(context: Dictionary) -> void:
	ctx = context
	var ch := generate_channel(int(ctx.get("seed", 0)), float(ctx.get("difficulty", 1.0)))
	pts = ch.pts
	widths = ch.widths
	length = ch.length
	hw_base = ch.hw
	bends = ch.bends
	bbox = ch.bbox
	bullet_home = length - BULLET_LEN * 0.5 - 0.002
	bullet_s = bullet_home
	slide_target = bullet_home
	_d_bullet_s = bullet_home
	dish_pos = Vector2(bbox.end.x + 0.055, clampf(pts[0].y, -0.03, 0.03))
	_vrng.seed = hash("forceps_fx|%d" % int(ctx.get("seed", 0)))
	_b_rng.seed = hash("forceps_bot|%d" % int(ctx.get("seed", 0)))
	_dish_rest = dish_pos + Vector2(_vrng.randf_range(-0.02, 0.02), _vrng.randf_range(-0.008, 0.008))
	tip = _bot_start()
	_d_tip = tip
	_vis_tip = tip
	_vis_yaw = _default_yaw()
	_build_visuals()


# =============================================================================
# Channel generation
# =============================================================================

## Deterministic channel from a seed. Returns {pts, widths, hw, length, bends, bbox}.
## Length 12..20 cm and half-width 12.5..8 mm scale with difficulty; 3 to 5 smooth bends;
## minimum bend radius and wall-to-wall clearance are enforced so the rims never overlap.
static func generate_channel(seed_value: int, difficulty: float) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("forceps|%d" % seed_value)
	var dn := clampf((difficulty - 1.0) / 0.6, 0.0, 1.0)
	var target := clampf((0.135 + 0.065 * dn) * rng.randf_range(0.92, 1.08), 0.12, 0.20)
	var hw := clampf(0.0125 - 0.0045 * dn, 0.008, 0.0125)
	var best := PackedVector2Array()
	var nb := 3
	var want := rng.randi_range(3, 5)
	for attempt in 120:
		nb = maxi(3, want - attempt / 50)
		var ctrl := PackedVector2Array()
		var pos := Vector2.ZERO
		var heading := rng.randf() * TAU
		var turn_sign := 1.0 if rng.randf() < 0.5 else -1.0
		ctrl.append(pos)
		var seg := target / float(nb + 1)
		for b in nb + 1:
			pos += Vector2.from_angle(heading) * seg * rng.randf_range(0.8, 1.2)
			ctrl.append(pos)
			if rng.randf() < 0.75:
				turn_sign = -turn_sign
			heading += turn_sign * deg_to_rad(rng.randf_range(34.0, 70.0) * (1.0 - 0.1 * float(nb - 3)))
		var p := _smooth_resample(ctrl, target)
		# Bends and clearance do not change under rotation, so reject on them before paying
		# for _orient's 36-angle search. The skipped mirror draw keeps the random sequence,
		# and so every seed's channel, exactly as it was.
		if not _valid_shape(p, hw):
			rng.randf()
			continue
		p = _orient(p, rng)
		if _valid(p, hw):
			best = p
			break
	if best.is_empty():
		var ctrl2 := PackedVector2Array()
		for k in 5:
			ctrl2.append(Vector2(-0.06 + 0.03 * k, 0.018 * (1.0 if k % 2 == 0 else -1.0)))
		best = _orient(_smooth_resample(ctrl2, target), rng)
		nb = 3
	var n := best.size()
	var L := float(n - 1) * SAMPLE
	var ph1 := rng.randf() * TAU
	var ph2 := rng.randf() * TAU
	var w := PackedFloat32Array()
	w.resize(n)
	for i in n:
		var s := float(i) * SAMPLE
		var f := 1.0 + 0.09 * sin(s * 70.0 + ph1) + 0.05 * sin(s * 190.0 + ph2)
		f *= 1.0 + 0.3 * (1.0 - smoothstep(0.0, 0.012, s))
		f *= 1.0 + 0.28 * smoothstep(L - 0.022, L - 0.006, s)
		w[i] = hw * f
	var r := Rect2(best[0], Vector2.ZERO)
	for q in best:
		r = r.expand(q)
	return {"pts": best, "widths": w, "hw": hw, "length": L, "bends": nb, "bbox": r.grow(hw * (1.0 + RIM) * 1.3)}


static func _smooth_resample(ctrl: PackedVector2Array, target: float) -> PackedVector2Array:
	# Centripetal-ish Catmull-Rom through the control points, then resampled by arc length.
	var dense := PackedVector2Array()
	var m := ctrl.size()
	for i in m - 1:
		var p0 := ctrl[maxi(i - 1, 0)]
		var p1 := ctrl[i]
		var p2 := ctrl[i + 1]
		var p3 := ctrl[mini(i + 2, m - 1)]
		if i == 0:
			p0 = p1 - (p2 - p1)
		if i + 2 >= m:
			p3 = p2 + (p2 - p1)
		for k in 40:
			var t := float(k) / 40.0
			var t2 := t * t
			var t3 := t2 * t
			dense.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	dense.append(ctrl[m - 1])
	var total := 0.0
	for i in range(1, dense.size()):
		total += dense[i].distance_to(dense[i - 1])
	var k_scale := target / maxf(total, 1e-6)
	for i in dense.size():
		dense[i] *= k_scale
	var out := PackedVector2Array()
	out.append(dense[0])
	var need := SAMPLE
	var acc := 0.0
	for i in range(1, dense.size()):
		var a := dense[i - 1]
		var b := dense[i]
		var seg := a.distance_to(b)
		while acc + seg >= need and seg > 0.0:
			var t := (need - acc) / seg
			out.append(a.lerp(b, t))
			need += SAMPLE
		acc += seg
	return out


static func _orient(p: PackedVector2Array, rng: RandomNumberGenerator) -> PackedVector2Array:
	# Lay the channel out landscape (wide in X), the opening on the +X side near the dish,
	# optionally mirrored, and centre its bounding box on the site.
	var best_a := 0.0
	var best_h := INF
	for k in 36:
		var a := float(k) * PI / 36.0
		var lo := INF
		var hi := -INF
		for q in p:
			var y := q.rotated(a).y
			lo = minf(lo, y)
			hi = maxf(hi, y)
		if hi - lo < best_h:
			best_h = hi - lo
			best_a = a
	var out := PackedVector2Array()
	out.resize(p.size())
	for i in p.size():
		out[i] = p[i].rotated(best_a)
	if out[0].x < out[out.size() - 1].x:
		for i in out.size():
			out[i].x = -out[i].x
	if rng.randf() < 0.5:
		for i in out.size():
			out[i].y = -out[i].y
	var r := Rect2(out[0], Vector2.ZERO)
	for q in out:
		r = r.expand(q)
	var c := r.get_center()
	for i in out.size():
		out[i] -= c
	return out


static func _valid(p: PackedVector2Array, hw: float) -> bool:
	if not _valid_shape(p, hw):
		return false
	var r := Rect2(p[0], Vector2.ZERO)
	for q in p:
		r = r.expand(q)
	return r.size.x <= 0.19 and r.size.y <= 0.13


## The rotation-independent half of _valid: no bend too tight, no two stretches too close.
static func _valid_shape(p: PackedVector2Array, hw: float) -> bool:
	var n := p.size()
	if n < 50:
		return false
	# bend radius, measured over +-5 mm so resampling noise does not count
	for i in range(5, n - 5, 2):
		var a := (p[i] - p[i - 5]).normalized()
		var b := (p[i + 5] - p[i]).normalized()
		var ang := absf(a.angle_to(b))
		if ang > 0.0 and 0.005 / ang < 0.014:
			return false
	# wall-to-wall clearance between distant parts of the channel
	var clear := 2.0 * hw * 1.3 + 0.014
	for i in range(0, n, 3):
		for j in range(i + 60, n, 3):
			if p[i].distance_to(p[j]) < clear:
				return false
	return true


func _idx(s: float) -> int:
	return clampi(int(round(s / SAMPLE)), 0, pts.size() - 1)


func point_at(s: float) -> Vector2:
	var f := clampf(s / SAMPLE, 0.0, float(pts.size() - 1))
	var i := mini(int(f), pts.size() - 2)
	return pts[i].lerp(pts[i + 1], f - float(i))


func tangent_at(s: float) -> Vector2:
	var i := _idx(s)
	var a := pts[maxi(i - 2, 0)]
	var b := pts[mini(i + 2, pts.size() - 1)]
	return (b - a).normalized()


func hw_at(s: float) -> float:
	var f := clampf(s / SAMPLE, 0.0, float(widths.size() - 1))
	var i := mini(int(f), widths.size() - 2)
	return lerpf(widths[i], widths[i + 1], f - float(i))


## Nearest point on the channel to p, found by walking along the centreline from s_guess so
## the answer never tunnels through a wall into a neighbouring bend.
func project(p: Vector2, s_guess: float) -> Dictionary:
	var n := pts.size()
	var i := _idx(s_guess)
	var best := p.distance_squared_to(pts[i])
	for _k in 600:
		var moved := false
		if i + 1 < n and p.distance_squared_to(pts[i + 1]) < best:
			i += 1
			best = p.distance_squared_to(pts[i])
			moved = true
		elif i > 0 and p.distance_squared_to(pts[i - 1]) < best:
			i -= 1
			best = p.distance_squared_to(pts[i])
			moved = true
		if not moved:
			break
	var out_s := float(i) * SAMPLE
	var centre := pts[i]
	var bd := best
	for j in [i - 1, i]:
		if j < 0 or j + 1 >= n:
			continue
		var a := pts[j]
		var ab := pts[j + 1] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
		var c := a + ab * t
		var d := p.distance_squared_to(c)
		if d < bd:
			bd = d
			centre = c
			out_s = (float(j) + t) * SAMPLE
	var off := p - centre
	var dist := sqrt(bd)
	var dir := off / dist if dist > 1e-7 else Vector2(-tangent_at(out_s).y, tangent_at(out_s).x)
	return {"s": out_s, "centre": centre, "d": dist, "dir": dir}


# =============================================================================
# Contract
# =============================================================================

func plane_extent() -> Vector2:
	var e := Vector2(maxf(absf(bbox.position.x), absf(bbox.end.x)), maxf(absf(bbox.position.y), absf(bbox.end.y)))
	return Vector2(maxf(e.x + 0.03, 0.10), maxf(e.y + 0.03, 0.08))


func camera_pose() -> Dictionary:
	# Fit the channel vertically and the channel plus the dish horizontally in a 16:9 view.
	var fov := 50.0
	var half_v := tan(deg_to_rad(fov * 0.5))
	var need_z := maxf(absf(bbox.position.y), absf(bbox.end.y)) + 0.012
	var need_x := maxf(absf(bbox.position.x), dish_pos.x + 0.05)
	var h := maxf(need_z / half_v, need_x / (half_v * 1.7)) * 1.06
	return {"height": h, "back": h * 0.2, "fov": fov}


func tool_radius() -> float:
	return TOOL_R_GRIP if gripped else TOOL_R_OPEN


func speed_max() -> float:
	return SPEED_MAX_GRIP if gripped else SPEED_MAX_OPEN


func bullet_pos() -> Vector2:
	return point_at(bullet_s)


func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done or pts.size() < 2:
		return
	delta = maxf(delta, 1e-4)
	_time += delta
	var primary := (buttons & BUTTON_PRIMARY) != 0

	# Cursor speed; a single-frame jump (a sedation jolt, a teleporting mouse) is not speed.
	var raw := 0.0
	if _last_cursor != null:
		var mv: float = (p - _last_cursor).length()
		raw = mv / delta if mv < JOLT_DIST else 0.0
	_last_cursor = p
	speed = lerpf(speed, raw, 1.0 - exp(-delta / SPEED_TAU))

	var pen := 0.0
	if not inside:
		tip = p
		if p.distance_to(pts[0]) < hw_at(0.0) - tool_radius():
			inside = true
			tip_s = 0.0
			speed = minf(speed, speed_max() * 0.5)
	else:
		var pr := project(p, tip_s)
		tip_s = pr.s
		var lim := hw_at(tip_s) - tool_radius()
		if pr.d <= lim:
			tip = p
		elif tip_s <= MOUTH_S:
			inside = false
			tip = p
			if gripped:
				_complete()
				return
		else:
			pen = pr.d - lim
			tip = pr.centre + pr.dir * lim

	# Scraping: past a wall, or tearing through too fast.
	too_fast = inside and speed > speed_max()
	var touching := inside and pen > CONTACT_PEN
	scraping = touching or too_fast
	_hit_cd -= delta
	_spurt_cd -= delta
	if scraping:
		var reason := "Scraped the wound channel" if touching else "Tore tissue moving too fast"
		if not contact:
			hits += 1
			_spurt_cd = 0.5
			if _hit_cd <= 0.0:
				_add_cost(HIT_COST, reason)
			_hit_cd = HIT_COOLDOWN
		elif _spurt_cd <= 0.0:
			hits += 1
			_spurt_cd = 0.5
		contact = true
		var rate := 0.0
		if touching:
			rate += SCRAPE_RATE * clampf(pen / 0.003, 0.4, 2.0)
		if too_fast:
			rate += SPEED_RATE * clampf((speed / speed_max() - 1.0) * 2.0 + 0.5, 0.5, 2.0)
		_add_cost(rate * delta, reason)
		_grind = _grind + delta if pen > DROP_PEN else 0.0
		if gripped and _grind > DROP_TIME:
			_grind = 0.0
			_drop()
	else:
		if contact and _acc >= 0.05:
			_flush()
		contact = false

	# Jaws and the grip.
	if gripped:
		if not primary:
			_drop()
		else:
			jaw = JAW_ON_BULLET
			bullet_s = tip_s
			slide_target = bullet_s
	if not gripped:
		if primary and not empty_closed:
			jaw = minf(jaw + JAW_CLOSE_RATE * delta, 1.0)
			var over := inside and tip.distance_to(bullet_pos()) < GRAB_R and speed < GRAB_SPEED and absf(bullet_s - slide_target) < 0.001
			if over and jaw >= JAW_ON_BULLET:
				gripped = true
				jaw = JAW_ON_BULLET
				bullet_s = tip_s
				slide_target = bullet_s
			elif jaw >= 1.0:
				empty_closed = true
		elif not primary:
			empty_closed = false
			jaw = maxf(jaw - JAW_OPEN_RATE * delta, 0.0)

	# A dropped slug slides back down toward where it was lodged.
	if not gripped and bullet_s < slide_target:
		bullet_s = move_toward(bullet_s, slide_target, SLIDE_SPEED * delta)

	if gripped:
		stage = Stage.GRIPPED
	elif not inside:
		stage = Stage.OUTSIDE
	elif tip.distance_to(bullet_pos()) < GRAB_R * 1.6:
		stage = Stage.AT_BULLET
	else:
		stage = Stage.SEEK
	_update_progress()
	_publish()


func _update_progress() -> void:
	if done:
		progress = 1.0
		return
	var extract := 0.55 * clampf(1.0 - bullet_s / bullet_home, 0.0, 1.0)
	if gripped:
		progress = 0.45 + 0.55 * clampf(1.0 - tip_s / bullet_home, 0.0, 1.0)
	else:
		var reach := clampf((tip_s if inside else 0.0) / maxf(bullet_s, 0.001), 0.0, 1.0)
		progress = clampf(0.4 * reach + extract, 0.0, 1.0)


func _add_cost(amount: float, reason: String) -> void:
	_acc += amount
	_acc_reason = reason
	if _acc >= EMIT_CHUNK:
		_flush()


func _flush() -> void:
	if _acc <= 0.0:
		return
	damage += _acc
	botch(_acc, _acc_reason)
	_acc = 0.0


func _drop() -> void:
	gripped = false
	empty_closed = true  # the hand has to let go before it can grip again
	jaw = 0.4
	drops += 1
	bullet_s = clampf(tip_s, 0.0, bullet_home)
	slide_target = minf(bullet_s + SLIDE_BACK, bullet_home)


func _complete() -> void:
	gripped = false
	stage = Stage.DONE
	bullet_s = 0.0
	if _acc >= 0.01:
		_flush()
	_acc = 0.0
	_publish()
	finish({"bullet_removed": true})


func _publish() -> void:
	_d_tip = tip
	_d_inside = inside
	_d_jaw = jaw
	_d_gripped = gripped
	_d_bullet_s = bullet_s
	_d_stage = stage
	_d_hits = hits
	_d_damage = damage


func hud_state() -> Dictionary:
	var hint := ""
	match _d_stage:
		Stage.OUTSIDE:
			hint = "Guide the forceps into the wound opening."
		Stage.SEEK:
			hint = "Find the bullet: follow the channel down. Don't touch the walls."
		Stage.AT_BULLET:
			hint = "Grab it: hold still over the bullet and hold the left button."
		Stage.GRIPPED:
			hint = "Draw it out slowly, back along the channel. Let go and it slips."
		Stage.DONE:
			hint = "Bullet removed."
	if ctx.get("operator", false) and not done:
		if empty_closed and not gripped and _d_stage != Stage.GRIPPED:
			hint = "Closed on nothing. Let go, then grip over the bullet."
		if too_fast:
			hint = "Too fast! You are tearing tissue."
		elif scraping:
			hint = "You're scraping the wall!"
	return {
		"title": String(ctx.get("step", {}).get("label", "Remove the bullet")),
		"hint": hint,
		"progress": progress,
		"gauges": [{"label": "Tissue damage", "value": _d_damage, "min": 0.0, "max": 25.0, "good_min": 0.0, "good_max": 5.0}],
	}


func net_state() -> Dictionary:
	return {
		"x": snappedf(_d_tip.x, 0.0001), "y": snappedf(_d_tip.y, 0.0001),
		"i": 1 if _d_inside else 0, "j": snappedf(_d_jaw, 0.01), "g": 1 if _d_gripped else 0,
		"b": snappedf(_d_bullet_s, 0.0001), "st": _d_stage, "h": _d_hits,
		"dm": snappedf(_d_damage, 0.1), "p": snappedf(progress, 0.001),
	}


func apply_net_state(s: Dictionary) -> void:
	progress = float(s.get("p", progress))
	_d_tip = Vector2(float(s.get("x", _d_tip.x)), float(s.get("y", _d_tip.y)))
	_d_inside = int(s.get("i", 0)) == 1
	_d_jaw = float(s.get("j", _d_jaw))
	_d_gripped = int(s.get("g", 0)) == 1
	_d_bullet_s = float(s.get("b", _d_bullet_s))
	_d_stage = int(s.get("st", _d_stage))
	_d_hits = int(s.get("h", _d_hits))
	_d_damage = float(s.get("dm", _d_damage))


# =============================================================================
# Bot
# =============================================================================

func _bot_start() -> Vector2:
	return Vector2(dish_pos.x - 0.04, pts[0].y + 0.04)


func bot_input(t: float, skill: float) -> Dictionary:
	var dt := 1.0 / 60.0 if _b_last_t < 0.0 else clampf(t - _b_last_t, 0.0, 0.1)
	_b_last_t = t
	if _b_cursor == null:
		_b_cursor = _bot_start()
	# Never softlock: a sloppy surgeon who has been at it for ages steadies up.
	var sk := clampf(maxf(skill, (t - 32.0) / 10.0), 0.0, 1.0)
	var sloppy := 1.0 - sk
	var buttons := 0
	var v_in := lerpf(0.036, 0.036, sk)
	var v_out := lerpf(0.032, 0.028, sk)
	_b_burst_cd -= dt
	_b_burst -= dt
	if sloppy > 0.3 and _b_burst_cd <= 0.0:
		_b_burst = 0.35
		_b_burst_cd = _b_rng.randf_range(1.2, 2.6)
	var burst := 2.7 if _b_burst > 0.0 else 1.0
	var lateral := 0.0
	var wob := sin(t * 3.1) * (0.65 + 0.35 * sin(t * 0.83 + 1.0))
	var cur: Vector2 = _b_cursor

	match _b_phase:
		"enter":
			var m := pts[0]
			cur = cur.move_toward(m, 0.09 * dt)
			if inside:
				_b_phase = "descend"
				_b_sb = tip_s
		"descend":
			if not inside:
				_b_phase = "enter"
			_b_sb = minf(_b_sb + v_in * burst * dt, bullet_s)
			_b_sb = minf(_b_sb, tip_s + 0.006)
			lateral = wob * (hw_at(_b_sb) - TOOL_R_OPEN) * lerpf(2.3, 0.0, sk)
			if _b_sb >= bullet_s - 0.0005:
				_b_phase = "settle"
				_b_wait = lerpf(0.15, 0.3, sk)
			cur = cur.move_toward(point_at(_b_sb) + _normal(_b_sb) * lateral, lerpf(0.3, 0.06, sk) * dt)
		"settle":
			_b_sb = move_toward(_b_sb, bullet_s, 0.02 * dt)
			cur = cur.move_toward(bullet_pos(), 0.03 * dt)
			_b_wait -= dt
			if _b_wait <= 0.0 and speed < GRAB_SPEED * 0.6:
				_b_phase = "grip"
		"grip":
			cur = cur.move_toward(bullet_pos(), 0.02 * dt)
			buttons = BUTTON_PRIMARY
			if gripped:
				_b_phase = "extract"
				_b_sb = tip_s
			elif empty_closed:
				_b_phase = "settle"
				_b_wait = 0.25
				buttons = 0
		"extract":
			buttons = BUTTON_PRIMARY
			if not gripped:
				_b_phase = "release"
				_b_wait = 0.3
				buttons = 0
			else:
				_b_sb = maxf(_b_sb - v_out * burst * dt, 0.0)
				_b_sb = maxf(_b_sb, tip_s - 0.005)
				lateral = wob * (hw_at(_b_sb) - TOOL_R_GRIP) * lerpf(2.0, 0.0, sk)
				cur = cur.move_toward(point_at(_b_sb) + _normal(_b_sb) * lateral, lerpf(0.3, 0.05, sk) * dt)
				if sloppy > 0.5 and not _b_dropped_once and _b_sb < bullet_home * 0.5:
					_b_dropped_once = true
					_b_phase = "release"
					_b_wait = 0.45
					buttons = 0
				elif _b_sb <= 0.0005:
					_b_phase = "exit"
		"release":
			_b_wait -= dt
			if _b_wait <= 0.0:
				_b_phase = "descend"
				_b_sb = tip_s
		"exit":
			buttons = BUTTON_PRIMARY
			cur = cur - tangent_at(0.0) * 0.03 * dt
			if not gripped and not done:
				_b_phase = "descend" if inside else "enter"
				_b_sb = tip_s
	_b_cursor = cur
	return {"cursor": cur, "buttons": buttons}


func _normal(s: float) -> Vector2:
	var tg := tangent_at(s)
	return Vector2(-tg.y, tg.x)


# =============================================================================
# Visuals
# =============================================================================

func _skin_color() -> Color:
	return Color(0.2, 0.22, 0.25) if String(ctx.get("patient_id", "bob")) == "seal" else Color(0.52, 0.36, 0.28)


func _depth_at(s: float) -> float:
	return lerpf(DEPTH_NEAR, DEPTH_FAR, clampf(s / length, 0.0, 1.0))


## Height of the wound surface at arc length s and signed cross position u (in half-widths).
func _surface_y(s: float, u: float) -> float:
	var a := absf(u)
	if a <= 1.0:
		return LIFT + 0.0006 - _depth_at(s) * pow(1.0 - a * a, 0.35)
	if a <= 1.3:
		return LIFT + 0.0006 + 0.0010 * sin((a - 1.0) / 0.3 * PI * 0.5)
	# the outer slope dives under the skin patch, so the two meet along a smooth crossing line
	return lerpf(LIFT + 0.0006, PATCH_Y - 0.004, smoothstep(1.3, RIM + 1.5, a))


func _build_visuals() -> void:
	if _built:
		return
	_built = true
	_build_skin()
	_build_channel()
	_build_bullet()
	_build_dish()
	_build_forceps()
	_splat_mat = StandardMaterial3D.new()
	_splat_mat.albedo_color = Color(0.28, 0.0, 0.02)
	_splat_mat.roughness = 0.12
	_splat_mat.metallic_specular = 0.8
	_drop_mesh = SphereMesh.new()
	_drop_mesh.radius = 0.0012
	_drop_mesh.height = 0.0024
	_drop_mesh.radial_segments = 6
	_drop_mesh.rings = 3
	_splat_mesh = CylinderMesh.new()
	_splat_mesh.top_radius = 1.0
	_splat_mesh.bottom_radius = 1.0
	_splat_mesh.height = 1.0
	_splat_mesh.radial_segments = 10
	_splat_mesh.rings = 1
	_set_layers(self)


## The patient's wound decals only project onto layer 1 (cull_mask = 1). Our raised wound model
## lives on layer 2 so a bruise decal's box does not stamp hard-edged rectangles across it.
const VIS_LAYER := 2


func _set_layers(n: Node) -> void:
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = VIS_LAYER
	for c in n.get_children():
		_set_layers(c)


## Skin colour of the exposed window: patient skin, an iodine prep stain and a bruise around the
## entry wound. Shared by the skin patch and the wound rim so the two meet without a seam.
const SKIN_GLSL := """
uniform vec3 skin_color = vec3(0.8, 0.62, 0.5);
uniform vec2 mouth = vec2(0.0);
uniform vec2 patch_c = vec2(0.0);
uniform vec2 patch_r = vec2(0.1);
float patch_radius(vec2 p) { return length((p - patch_c) / patch_r); }
vec3 skin_at(vec2 p) {
	float r = patch_radius(p);
	float n = vnoise(p * 90.0);
	float n2 = vnoise(p * 700.0);
	vec3 col = skin_color * (0.9 + 0.14 * n2);
	vec2 d = p - patch_c;
	float ang = atan(d.y, d.x);
	float wob = 0.06 * sin(ang * 5.0 + 1.3) + 0.04 * sin(ang * 11.0);
	float iod = 1.0 - smoothstep(0.62 + wob, 0.8 + wob, r);
	col = mix(col, col * vec3(0.8, 0.5, 0.25), iod * 0.5);
	float dm = distance(p, mouth);
	col = mix(col, vec3(0.2, 0.06, 0.1), (1.0 - smoothstep(0.015, 0.045 + 0.01 * n, dm)) * 0.6);
	return col * mix(1.0, 0.6, smoothstep(0.9, 0.99, r));
}
"""

const NOISE_GLSL := """
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
"""


func _skin_params(m: ShaderMaterial) -> void:
	m.set_shader_parameter("skin_color", _skin_color())
	m.set_shader_parameter("mouth", pts[0])
	m.set_shader_parameter("patch_c", bbox.get_center())
	m.set_shader_parameter("patch_r", bbox.size * 0.5 + Vector2(0.05, 0.05))


func _build_skin() -> void:
	var c := bbox.get_center()
	var rx := bbox.size.x * 0.5 + 0.05
	var rz := bbox.size.y * 0.5 + 0.05
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 10
	var segs := 48
	for k in rings + 1:
		for j in segs:
			var r := float(k) / float(rings)
			var a := float(j) / float(segs) * TAU
			var y := PATCH_Y * (1.0 - smoothstep(0.93, 1.0, r))
			st.set_uv(Vector2(r, 0.0))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(c.x + cos(a) * rx * r, y, c.y + sin(a) * rz * r))
	for k in rings:
		for j in segs:
			var a0 := k * segs + j
			var a1 := k * segs + (j + 1) % segs
			var b0 := (k + 1) * segs + j
			var b1 := (k + 1) * segs + (j + 1) % segs
			st.add_index(a0); st.add_index(b0); st.add_index(a1)
			st.add_index(a1); st.add_index(b0); st.add_index(b1)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "SkinPatch"
	mi.mesh = st.commit()
	var sh := cached_shader("""
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;
varying vec2 pp;
""" + NOISE_GLSL + SKIN_GLSL + """
void vertex() { pp = VERTEX.xz; }
void fragment() {
	float r = patch_radius(pp);
	ALBEDO = skin_at(pp);
	ROUGHNESS = 0.55;
	ALPHA = 1.0 - smoothstep(0.985, 1.0, r);
}
""")
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("skin_color", _skin_color())
	_skin_params(m)
	m.render_priority = -1
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_channel() -> void:
	# The material and node are made here on the main thread; the heightfield itself is
	# built on a worker thread, because it is tens of milliseconds of script maths and it
	# would otherwise stall the frame in which the step begins. It lands a few frames later,
	# while the operator's camera is still swooping in.
	var mi := MeshInstance3D.new()
	mi.name = "WoundChannel"
	var sh := cached_shader("""
shader_type spatial;
render_mode cull_disabled;
uniform float dark_floor = 0.06;
varying vec2 pp;
varying float lvis;
varying float shine;
varying float gloss;
""" + ("const float RIMW = %.2f;
" % (RIM + 1.0)) + NOISE_GLSL + SKIN_GLSL + """
void vertex() { pp = VERTEX.xz; }
void fragment() {
	float s = UV.x;
	float u = abs(UV.y);
	float n1 = vnoise(pp * 420.0);
	float n2 = vnoise(pp * 260.0 + 7.0);
	float n4 = vnoise(vec2(s * 60.0, UV.y * 2.0) + 11.0);
	// darkness: light reaching into the tract falls off with depth
	float vis = mix(1.0, dark_floor, smoothstep(0.03, 0.85, s));
	float mouth_f = 1.0 - smoothstep(0.0, 0.09, s);
	float inside = 1.0 - smoothstep(0.97, 1.03, u);
	float wall = smoothstep(0.4, 1.0, u);
	vec3 floor_col = mix(vec3(0.05, 0.002, 0.004), vec3(0.16, 0.008, 0.012), smoothstep(0.0, 0.25, s));
	vec3 wall_col = mix(vec3(0.42, 0.04, 0.05), vec3(0.6, 0.1, 0.09), n2) * (0.7 + 0.5 * n4);
	vec3 trench = mix(floor_col, wall_col, wall) * (0.8 + 0.3 * n1);
	float pool = clamp(smoothstep(0.5, 0.95, s) * (1.0 - smoothstep(0.4, 0.95, u)) + 0.45 * (1.0 - smoothstep(0.0, 0.45, u)), 0.0, 1.0);
	trench = mix(trench, vec3(0.06, 0.0, 0.004), pool);
	float rt = smoothstep(1.05, RIMW, u);
	vec3 raw = mix(vec3(0.55, 0.1, 0.1), vec3(0.72, 0.22, 0.2), n2) * (0.8 + 0.3 * n1);
	vec3 rim = mix(raw, vec3(0.34, 0.1, 0.14), smoothstep(0.15, 0.6, rt));
	rim = mix(rim, skin_at(pp), smoothstep(0.45, 0.75, rt));
	trench *= mix(1.0, 0.35, mouth_f * (1.0 - wall));
	ALBEDO = mix(rim, trench, inside);
	lvis = mix(mix(1.0, vis, 0.6 * (1.0 - rt)), vis, inside);
	shine = mix(mix(0.5, 0.15, rt), mix(0.9, 1.6, pool), inside);
	gloss = mix(mix(60.0, 12.0, rt), mix(40.0, 160.0, pool), inside);
	ROUGHNESS = 0.5;
	AO = mix(1.0, mix(0.1, 0.9, wall) * vis, inside);
	AO_LIGHT_AFFECT = 0.0;
	vec3 bump = vec3(n1 - 0.5, 0.0, n4 - 0.5) * 0.22 * (1.0 - rt) * mix(1.0, 0.3, pool);
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(bump, 0.0)).xyz);
}
void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR / PI * lvis;
	vec3 h = normalize(VIEW + LIGHT);
	float sp = pow(clamp(dot(NORMAL, h), 0.0, 1.0), gloss);
	SPECULAR_LIGHT += sp * ATTENUATION * LIGHT_COLOR * shine * 0.035 * lvis;
}
""")
	var m := ShaderMaterial.new()
	m.shader = sh
	_skin_params(m)
	mi.material_override = m
	add_child(mi)
	_channel_task = WorkerThreadPool.add_task(_build_channel_geometry.bind(mi), false, "forceps channel")


var _channel_task := -1


func _exit_tree() -> void:
	# Never free the node while its geometry is still being built on another thread.
	if _channel_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_channel_task)
		_channel_task = -1


## Worker thread: reads only the channel data fixed in setup, touches no scene nodes.
func _build_channel_geometry(mi: MeshInstance3D) -> void:
	# A heightfield over the channel's neighbourhood. Each grid vertex takes the nearest
	# centreline point (arc length s, distance d), so the caps round themselves off and the
	# rims of neighbouring bends merge into one ridge instead of overlapping.
	# 2.5 mm cells (was 1.25 mm): a quarter of the vertices and a quarter of the search area
	# per sample. At the operator camera's distance the difference does not show, and the
	# step now builds in a few tens of milliseconds instead of a quarter of a second.
	var cell := 0.0025
	var hw_max := 0.0
	for w in widths:
		hw_max = maxf(hw_max, w)
	var r_out := hw_max * (RIM + 1.7)
	var origin := bbox.position - Vector2(cell, cell) * 2.0
	var nx := int(ceil(bbox.size.x / cell)) + 5
	var nz := int(ceil(bbox.size.y / cell)) + 5
	var count := nx * nz
	var best_u := PackedFloat32Array()
	var best_s := PackedFloat32Array()
	best_u.resize(count)
	best_s.resize(count)
	best_u.fill(1e9)
	var n := pts.size()
	var rad := int(ceil(r_out / cell)) + 1
	# Samples are 1 mm apart; every other one is plenty for a 2.5 mm grid.
	for i in range(0, n, 2):
		var q := pts[i]
		var w := widths[i]
		var reach := w * (RIM + 1.7)
		var cx := int((q.x - origin.x) / cell)
		var cz := int((q.y - origin.y) / cell)
		var s_i := float(i) * SAMPLE
		for gz in range(maxi(cz - rad, 0), mini(cz + rad + 1, nz)):
			var pz := origin.y + gz * cell
			var dz := pz - q.y
			var row := gz * nx
			for gx in range(maxi(cx - rad, 0), mini(cx + rad + 1, nx)):
				var dx := origin.x + gx * cell - q.x
				var u := sqrt(dx * dx + dz * dz) / w
				if u < best_u[row + gx] and u * w < reach:
					best_u[row + gx] = u
					best_s[row + gx] = s_i
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var remap := PackedInt32Array()
	remap.resize(count)
	remap.fill(-1)
	var used := 0
	for gz in nz:
		for gx in nx:
			var k := gz * nx + gx
			var u := best_u[k]
			if u > RIM + 1.6:
				continue
			remap[k] = used
			used += 1
			var sv := best_s[k]
			st.set_uv(Vector2(sv / length, u))
			st.add_vertex(Vector3(origin.x + gx * cell, _surface_y(sv, u), origin.y + gz * cell))
	for gz in nz - 1:
		for gx in nx - 1:
			var a0 := remap[gz * nx + gx]
			var a1 := remap[gz * nx + gx + 1]
			var b0 := remap[(gz + 1) * nx + gx]
			var b1 := remap[(gz + 1) * nx + gx + 1]
			if a0 < 0 or a1 < 0 or b0 < 0 or b1 < 0:
				continue
			st.add_index(a0); st.add_index(b0); st.add_index(a1)
			st.add_index(a1); st.add_index(b0); st.add_index(b1)
	st.generate_normals()
	var mesh := st.commit()
	_apply_channel_mesh.call_deferred(mi, mesh)


func _apply_channel_mesh(mi: MeshInstance3D, mesh: Mesh) -> void:
	if is_instance_valid(mi):
		mi.mesh = mesh


func _build_bullet() -> void:
	_bullet = Node3D.new()
	_bullet.name = "Bullet"
	_bullet_mat = StandardMaterial3D.new()
	_bullet_mat.albedo_color = Color(0.62, 0.46, 0.26)
	_bullet_mat.metallic = 0.55
	_bullet_mat.roughness = 0.5
	var lead := StandardMaterial3D.new()
	lead.albedo_color = Color(0.3, 0.3, 0.32)
	lead.metallic = 0.4
	lead.roughness = 0.6
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BULLET_R
	cyl.bottom_radius = BULLET_R * 0.92
	cyl.height = BULLET_LEN * 0.62
	cyl.radial_segments = 12
	body.mesh = cyl
	body.material_override = _bullet_mat
	body.rotation_degrees = Vector3(0, 0, 90)
	_bullet.add_child(body)
	var nose := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = BULLET_R * 1.05
	sph.height = BULLET_R * 1.6
	sph.radial_segments = 12
	sph.rings = 6
	nose.mesh = sph
	nose.material_override = lead
	_lead_mat = lead
	nose.position = Vector3(-BULLET_LEN * 0.32, 0, 0)
	nose.rotation_degrees = Vector3(0, 0, 90)
	nose.scale = Vector3(1.0, 1.0, 1.15)  # mushroomed
	_bullet.add_child(nose)
	add_child(_bullet)


func _build_dish() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := 0.052
	var b := 0.025
	var d := 0.009
	var fr := [0.0, 0.45, 0.72, 0.86, 0.95, 1.0, 1.04, 1.055, 1.04]
	var hh := [0.003, 0.003, 0.004, 0.009, 0.016, 0.021, 0.0225, 0.021, 0.019]
	var segs := 40
	for k in fr.size():
		for j in segs:
			var th := float(j) / float(segs) * TAU
			var x := a * cos(th) * float(fr[k])
			var z := (b * sin(th) + d * cos(2.0 * th)) * float(fr[k]) - d * float(fr[k]) * 0.0
			st.add_vertex(Vector3(x, float(hh[k]), z))
	for k in fr.size() - 1:
		for j in segs:
			var a0 := k * segs + j
			var a1 := k * segs + (j + 1) % segs
			var b0 := a0 + segs
			var b1 := a1 + segs
			st.add_index(a0); st.add_index(b0); st.add_index(a1)
			st.add_index(a1); st.add_index(b0); st.add_index(b1)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "KidneyDish"
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.38, 0.4, 0.43)
	m.metallic = 0.45
	m.roughness = 0.28
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.position = Vector3(dish_pos.x, DISH_Y, dish_pos.y)
	mi.rotation.y = PI * 0.5 if bbox.size.y > 0.2 else 0.0
	add_child(mi)


func _build_forceps() -> void:
	_tool = Node3D.new()
	_tool.name = "Forceps"
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.8, 0.83, 0.86)
	steel.metallic = 0.5
	steel.roughness = 0.25
	var grip := StandardMaterial3D.new()
	grip.albedo_color = Color(0.2, 0.21, 0.23)
	grip.metallic = 0.4
	grip.roughness = 0.6
	var pitched := Node3D.new()
	pitched.name = "Pitched"
	pitched.basis = Basis(Vector3(0, 0, 1), TOOL_PITCH)
	_tool.add_child(pitched)
	for side in [-1.0, 1.0]:
		var arm := Node3D.new()
		arm.position = Vector3(ARM_LEN, 0, side * 0.0034)
		pitched.add_child(arm)
		# tapered blade from the joint (x = 0) to the tip (x = -ARM_LEN)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var prof := [[0.0, 0.0034, 0.0019], [-0.07, 0.0030, 0.0017], [-0.105, 0.0016, 0.0014], [-ARM_LEN + 0.004, 0.0009, 0.0012], [-ARM_LEN, 0.0007, 0.0011]]
		var verts: Array[Vector3] = []
		for pr in prof:
			var x: float = pr[0]
			var w: float = pr[1]
			var th: float = pr[2]
			verts.append(Vector3(x, th, -w)); verts.append(Vector3(x, th, w))
			verts.append(Vector3(x, -th, w)); verts.append(Vector3(x, -th, -w))
		for q in prof.size() - 1:
			for f in 4:
				var a0: int = q * 4 + f
				var a1: int = q * 4 + (f + 1) % 4
				var b0: int = a0 + 4
				var b1: int = a1 + 4
				for vi in [a0, a1, b0, a1, b1, b0]:
					st.add_vertex(verts[vi])
		var last := (prof.size() - 1) * 4
		for vi in [0, 2, 1, 0, 3, 2, last, last + 1, last + 2, last, last + 2, last + 3]:
			st.add_vertex(verts[vi])
		st.generate_normals()
		var blade := MeshInstance3D.new()
		blade.mesh = st.commit()
		blade.material_override = steel
		arm.add_child(blade)
		# serrated grip ridges on the handle half
		for g in 7:
			var ridge := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.0022, 0.0006, 0.0058)
			ridge.mesh = bm
			ridge.material_override = grip
			ridge.position = Vector3(-0.022 - g * 0.0055, 0.0019, 0)
			arm.add_child(ridge)
		# inward-bent jaw teeth at the tip
		var tooth := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.005, 0.0022, 0.0016)
		tooth.mesh = tb
		tooth.material_override = steel
		tooth.position = Vector3(-ARM_LEN + 0.0025, -0.0004, -side * 0.0008)
		arm.add_child(tooth)
		_arms.append(arm)
	var joint := MeshInstance3D.new()
	var jb := BoxMesh.new()
	jb.size = Vector3(0.009, 0.004, 0.0078)
	joint.mesh = jb
	joint.material_override = steel
	joint.position = Vector3(ARM_LEN + 0.005, 0, 0)
	pitched.add_child(joint)
	add_child(_tool)


func _default_yaw() -> float:
	# Handle toward the operator's right, i.e. +X and +Z on the plane.
	# direction on the plane (0.55, 0.83): yaw = atan2(-dz, dx)
	return atan2(-0.83, 0.55)


func tick(delta: float) -> void:
	if not _built or pts.size() < 2:
		return
	var operator: bool = ctx.get("operator", false)
	var k := 1.0 if operator else 1.0 - exp(-delta * 18.0)
	_vis_tip = _vis_tip.lerp(_d_tip, k)
	_vis_jaw = move_toward(_vis_jaw, _d_jaw, delta * 8.0)

	# Where the tips sit: on the channel floor inside, hovering above the skin outside.
	var target_y := LIFT + 0.028
	var tip_s_vis := 0.0
	if _d_inside and _d_stage != Stage.DONE:
		var pr := project(_vis_tip, _vis_s)
		_vis_s = pr.s
		tip_s_vis = pr.s
		target_y = _surface_y(pr.s, pr.d / maxf(hw_at(pr.s), 1e-4)) + 0.0014
	else:
		_vis_s = 0.0
	_vis_y = lerpf(_vis_y, target_y, 1.0 - exp(-delta * 14.0))

	# The shaft points back out through the opening, like a real tool in a tract.
	var yaw := _default_yaw()
	if _d_inside:
		var to_mouth := pts[0] - _vis_tip
		if to_mouth.length() > 0.012:
			var a := atan2(-to_mouth.y, to_mouth.x)
			yaw = lerp_angle(a, _default_yaw(), 0.8)
	_vis_yaw = lerp_angle(_vis_yaw, yaw, 1.0 - exp(-delta * 6.0))

	# New contacts: flinch, spurt, shake.
	if _d_hits > _seen_hits:
		if _d_hits - _seen_hits < 20:
			_on_hit(_vis_tip)
		_seen_hits = _d_hits
	elif _d_hits < _seen_hits:
		_seen_hits = _d_hits
	_shake = maxf(_shake - delta * 4.0, 0.0)
	var jitter := Vector3(_vrng.randf_range(-1, 1), _vrng.randf_range(0, 1) * 0.3, _vrng.randf_range(-1, 1)) * _shake * 0.0022

	_tool.position = plane_to_local(_vis_tip, _vis_y) + jitter
	_tool.basis = Basis(Vector3.UP, _vis_yaw)
	var spread := lerpf(0.0062, 0.0006, _vis_jaw)
	for i in _arms.size():
		var side := -1.0 if i == 0 else 1.0
		# the arm pivots at the joint; aim its tip at +-spread across the shaft
		var dz := side * spread - side * 0.0034
		_arms[i].basis = Basis(Vector3.UP, -atan2(dz, ARM_LEN))

	# Sounds from the displayed state, so spectators hear the same thing.
	var closed := _vis_jaw >= JAW_ON_BULLET - 0.05
	if closed and not _was_closed and _d_jaw >= JAW_ON_BULLET - 0.05:
		_sfx("surgery_forceps_click", -4.0 if _d_gripped else -9.0)
	_was_closed = closed
	_squelch_cd -= delta
	if _d_inside and _squelch_cd <= 0.0 and _vis_tip.distance_to(_squelch_from) > 0.005:
		_sfx("surgery_forceps_squelch", -12.0 + clampf(_vis_tip.distance_to(_squelch_from) * 900.0, 0.0, 8.0), 0.12)
		_squelch_from = _vis_tip
		_squelch_cd = 0.3
	if not _d_inside:
		_squelch_from = _vis_tip

	# Bullet: in the jaws, lying in the channel, or flying to the dish.
	var depth_vis := 1.0
	if _d_stage == Stage.DONE:
		if _done_anim < 0.0:
			_done_anim = 0.0
		_done_anim += delta
		var t := clampf(_done_anim / 0.55, 0.0, 1.0)
		var from := pts[0]
		var p2 := from.lerp(_dish_rest, t)
		var y := lerpf(LIFT + 0.02, DISH_Y + 0.003 + BULLET_R * 0.8, t) + sin(t * PI) * 0.06
		if t >= 1.0:
			y = DISH_Y + 0.003 + BULLET_R * 0.8
			if not _clinked:
				_clinked = true
				_sfx("surgery_forceps_clink", -2.0)
		_bullet.position = plane_to_local(p2, y)
		_bullet.rotation = Vector3(0, _done_anim * (0.0 if t >= 1.0 else 9.0) + 0.6, 0)
	elif _d_gripped:
		_bullet.position = _tool.position + Vector3(0, BULLET_R * 0.6, 0)
		_bullet.basis = Basis(Vector3.UP, _vis_yaw)
		depth_vis = _vis_dark(tip_s_vis)
	else:
		var bs := _d_bullet_s
		var bp := point_at(bs)
		var tg := tangent_at(bs)
		_bullet.position = plane_to_local(bp, _surface_y(bs, 0.0) + BULLET_R * 0.55)
		_bullet.basis = Basis(Vector3.UP, atan2(tg.y, -tg.x))
		depth_vis = _vis_dark(bs)
	var bc := Color(0.62, 0.46, 0.26).lerp(Color(0.35, 0.05, 0.04), 0.35 if _d_stage != Stage.DONE else 0.2)
	_bullet_mat.albedo_color = bc * lerpf(0.35, 1.0, depth_vis)
	_lead_mat.albedo_color = Color(0.3, 0.3, 0.32) * lerpf(0.3, 1.0, depth_vis)

	# Blood.
	_bleed = maxf(_bleed - delta * 0.12, 0.0)
	_bleed_cd -= delta
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding") and _bleed_cd <= 0.0 and absf(_bleed - _bleed_sent) > 0.02:
		body.set_bleeding("gunshot", _bleed)
		_bleed_sent = _bleed
		_bleed_cd = 0.2
	_tick_droplets(delta)


func _vis_dark(s: float) -> float:
	return lerpf(1.0, 0.1, smoothstep(0.05, 0.92, s / length))


func _on_hit(at: Vector2) -> void:
	_shake = 1.0
	_bleed = minf(_bleed + 0.25, 1.0)
	_sfx("surgery_forceps_scrape", -3.0, 0.1)
	var origin := plane_to_local(at, _vis_y + 0.002)
	for i in 7:
		var mi := MeshInstance3D.new()
		mi.mesh = _drop_mesh
		mi.material_override = _splat_mat
		mi.position = origin
		mi.layers = VIS_LAYER
		add_child(mi)
		var dir := Vector2.from_angle(_vrng.randf() * TAU) * _vrng.randf_range(0.08, 0.3)
		_drops_nodes.append({"node": mi, "vel": Vector3(dir.x, _vrng.randf_range(0.25, 0.55), dir.y)})


func _tick_droplets(delta: float) -> void:
	var keep: Array = []
	for d in _drops_nodes:
		var mi: MeshInstance3D = d.node
		var v: Vector3 = d.vel
		v.y -= 9.8 * delta
		mi.position += v * delta
		d.vel = v
		var p2 := Vector2(mi.position.x, mi.position.z)
		var pr := project(p2, _vis_s)
		var ground := _surface_y(pr.s, pr.d / maxf(hw_at(pr.s), 1e-4)) + 0.0003 if pr.d < hw_at(pr.s) * (RIM + 1.0) else PATCH_Y
		if v.y < 0.0 and mi.position.y <= ground:
			mi.queue_free()
			_add_splat(Vector3(mi.position.x, ground, mi.position.z))
		else:
			keep.append(d)
	_drops_nodes = keep


func _add_splat(at: Vector3) -> void:
	var s := MeshInstance3D.new()
	s.mesh = _splat_mesh
	s.material_override = _splat_mat
	var r := _vrng.randf_range(0.0012, 0.0035)
	s.scale = Vector3(r * _vrng.randf_range(1.0, 1.8), 0.0004, r)
	s.rotation.y = _vrng.randf() * TAU
	s.position = at + Vector3(0, 0.0002, 0)
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.layers = VIS_LAYER
	add_child(s)
	_splats.append(s)
	if _splats.size() > 80:
		_splats.pop_front().queue_free()


func _sfx(cue: String, vol_db := 0.0, jitter := 0.05) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	var a = loop.root.get_node_or_null("Audio")
	if a == null:
		return
	var at = null
	if is_inside_tree():
		at = global_transform * plane_to_local(_vis_tip, LIFT)
	a.play(cue, at, vol_db, jitter)


# =============================================================================
# Self-test
# =============================================================================

## Plays `count` generated channels with the bot at skill 1.0, 0.0 and 1.0 with sedation
## jolts (random 2..4 cm cursor offsets every few seconds), headless, and prints stats.
## Run: a SceneTree script calling
##   load("res://scripts/surgery/games/forceps.gd").self_test(root, 20)
static func self_test(parent: Node, count: int = 20) -> Dictionary:
	var script: GDScript = load("res://scripts/surgery/games/forceps.gd")
	var modes := [["skill1.0", 1.0, false], ["skill0.0", 0.0, false], ["skill1.0+jolts", 1.0, true]]
	var agg := {}
	for m in modes:
		agg[m[0]] = {"runs": 0, "done": 0, "time": 0.0, "botch": 0.0, "botches": 0, "max_botch": 0.0, "min_botch": INF, "max_time": 0.0, "drops": 0}
	var chan_len := 0.0
	var chan_hw := 0.0
	var bend_hist := {}
	for i in count:
		var seed_value := hash("forceps_selftest_%d" % i)
		var diff := 1.0 + 0.12 * float(i % 6)
		for m in modes:
			var g = script.new()
			parent.add_child(g)
			var stats := {"botch": 0.0, "n": 0, "done": false}
			g.botched.connect(func(a, _r): stats.botch += a; stats.n += 1)
			g.finished.connect(func(_r): stats.done = true)
			g.setup({"patient_id": "bob" if i % 2 == 0 else "seal", "step": {"label": "Remove the bullet"},
				"difficulty": diff, "seed": seed_value, "flags": {}, "body": null, "operator": true})
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_value
			var jolt := Vector2.ZERO
			var jolt_t := 0.0
			var t := 0.0
			var dt := 1.0 / 60.0
			var ext: Vector2 = g.plane_extent()
			while t < 60.0 and not stats.done:
				t += dt
				var inp: Dictionary = g.bot_input(t, m[1])
				var c: Vector2 = inp.cursor
				if m[2]:
					jolt_t -= dt
					if jolt_t <= 0.0 and rng.randf() < dt / 4.0:
						jolt = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.02, 0.04)
						jolt_t = 0.2
					if jolt_t <= 0.0:
						jolt = Vector2.ZERO
					c += jolt
				c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
				g.handle_cursor(c, int(inp.buttons), dt)
				g.tick(dt)
				g.apply_net_state(g.net_state())
			var a: Dictionary = agg[m[0]]
			a.runs += 1
			if stats.done:
				a.done += 1
			a.time += t
			a.max_time = maxf(a.max_time, t)
			a.botch += stats.botch
			a.botches += stats.n
			a.max_botch = maxf(a.max_botch, stats.botch)
			a.min_botch = minf(a.min_botch, stats.botch)
			a.drops += g.drops
			if m[1] == 1.0 and not m[2]:
				chan_len += g.length
				chan_hw += g.hw_base
				bend_hist[g.bends] = int(bend_hist.get(g.bends, 0)) + 1
			print("[forceps-selftest] ch=%02d diff=%.2f len=%.1fcm hw=%.1fmm bends=%d %-15s %s t=%.1fs botches=%d vitals=%.1f drops=%d" % [
				i, diff, g.length * 100.0, g.hw_base * 1000.0, g.bends, m[0], "DONE" if stats.done else "UNFINISHED", t, stats.n, stats.botch, g.drops])
			g.free()
	print("[forceps-selftest] channels=%d mean length=%.1fcm mean half-width=%.1fmm bends=%s" % [count, chan_len / count * 100.0, chan_hw / count * 1000.0, str(bend_hist)])
	for m in modes:
		var a: Dictionary = agg[m[0]]
		print("[forceps-selftest] %-15s done %d/%d  mean time %.1fs (max %.1f)  mean vitals %.1f (min %.1f max %.1f)  mean botch events %.1f  drops %d" % [
			m[0], a.done, a.runs, a.time / a.runs, a.max_time, a.botch / a.runs, a.min_botch, a.max_botch, float(a.botches) / a.runs, a.drops])
	return agg
