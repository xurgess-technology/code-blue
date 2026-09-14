extends Node3D
## dissection (sweep 3): the forceps step's "brain" variant, "Pull out the brain". forceps.gd
## creates this as a child when ctx.variant == "brain" and hands every Minigame call to it; it
## reports through the owner (owner.botch / owner.finish / owner.progress).
##
## The plane is the body's `brain` site: the centre of the open skull, +Y out of the opening. The
## body's site_section("brain") gives the opening, the brain's size and where the specimen tray
## stands (site-local). Nothing to read off a gauge:
##
## CORDS   The brain is held in by a few nerves running from its edge to the skull wall, each with
##         a ring where to take it. Bring the forceps to a ring (it turns green), hold left click
##         to clamp, and draw the nerve in along itself, toward the middle of the brain. It
##         stretches (green, then amber) and pops free. Yank it (a fast pull) and it tears the
##         brain as it goes (red flash, TEAR_COST). Letting go early just lets it relax.
## GRIP    Every nerve free: a green ring on the brain. Hold left click on it to take it.
## LIFT    Keep holding and keep the hand still over the opening: the brain rises out. Pull it
##         against the edge and it scrapes on the bone (the rim flushes red where it touches, the
##         lift stalls, SCRAPE_COST every SCRAPE_TIME of it). Let go and it sinks back, no harm.
## CARRY   Out of the skull the tray glows green: carry the brain there and let go over it. Let go
##         anywhere else and it is dropped (DROP_COST); pick it up again where it fell.
## DONE    finish({"brain_removed": true}); it drops into the tray.
## A stir's shake never tears a nerve or scrapes by itself (on_jolt); the dissection system's
## thrashing botches are separate.

const Head := preload("res://scripts/dissection/monster_head.gd")

enum Stage { CORDS, GRIP, LIFT, CARRY, LOOSE, DONE }

const TIP_SPEED := 0.4          # m/s the tips can follow the cursor
const TIP_TAU := 0.05
const GRAB_R := 0.013           # tips this close to a nerve's ring can clamp it
const GRIP_R := 0.03            # and this close to the brain's centre can take the brain
const JAW_CLOSE_RATE := 5.0
const JAW_OPEN_RATE := 7.0
const JAW_ON := 0.6
const SNAP := 0.04              # stretch (m) at which a nerve pops free
const V_YANK := 0.24            # m/s of stretching above which the nerve tears the brain
const SLIP := 0.03              # tips this far off the nerve's line lose it
const TEAR_COST := 2.0
const LIFT_TIME := 1.1
const SCRAPE_PUSH := 0.004      # the hand this far past the edge scrapes
const SCRAPE_TIME := 0.5
const SCRAPE_COST := 1.5
const DROP_COST := 3.0
const CARRY_SPEED := 0.35
const TRAY_HALF := Vector2(0.075, 0.055)

# Geometry (plane metres)
var open_u := 0.063             # inner opening half size along plane X
var open_z := 0.051             # and along plane Z
var brain_r := Vector3(0.05, 0.04, 0.042)
var brain_y := -0.026
var tray := Vector3(0.05, -0.16, 0.21)
var table_up := Vector3.UP
var cords: Array = []           # [{a: Vector2 (on the brain), w: Vector2 (at the wall), g: Vector2 (ring), dir: Vector2 (pull)}]
var brain_seed := 0

# Simulation (operator)
var owner_mg   # the forceps Minigame that owns this (untyped: done, progress, botch, finish)
var ctx: Dictionary = {}
var tip := Vector2(0.05, 0.12)
var tip_v := Vector2.ZERO
var jaw := 0.0
var cut_mask := 0
var clamped := -1
var stretch := 0.0
var stretch_v := 0.0
var gripped := false
var lift := 0.0
var bpos := Vector2.ZERO        # brain centre on the plane
var stage: int = Stage.CORDS
var tears := 0
var drops := 0
var scrapes := 0
var scrape := 0.0               # 0..1 how hard it is scraping right now
var _scrape_t := 0.0
var _empty := false
var _jolt_t := 0.0
var _last_stretch := 0.0
var _time := 0.0

# Display (the operator publishes, spectators apply)
var d := {"tip": Vector2(0.05, 0.12), "jaw": 0.0, "cut": 0, "k": -1, "s": 0.0, "g": false, "l": 0.0,
	"b": Vector2.ZERO, "st": Stage.CORDS, "h": 0, "r": 0.0, "dr": 0, "p": 0.0}

# Visuals
var _built := false
var _tool: Node3D
var _brain: Node3D
var _brain_mat: StandardMaterial3D
var _cord_nodes: Array = []     # [{a: MeshInstance3D, b: MeshInstance3D, mat, ring, ring_mat, stub_a, stub_w}]
var _brain_ring: MeshInstance3D
var _brain_ring_mat: StandardMaterial3D
var _tray_glow: MeshInstance3D
var _tray_glow_mat: StandardMaterial3D
var _flush: MeshInstance3D
var _flush_mat: StandardMaterial3D
var _vis_tip := Vector2.ZERO
var _vis_b := Vector2.ZERO
var _vis_l := 0.0
var _vis_y := 0.05
var _cue_t := 0.0
var _seen_cut := 0
var _seen_h := 0
var _seen_dr := 0
var _tear_flash := 0.0
var _done_t := -1.0
var _was_closed := false

# Bot
var _b_t := -1.0
var _b_phase := "to_cord"
var _b_cord := 0
var _b_wait := 0.0
var _b_cursor := Vector2(0.05, 0.12)
var _b_dropped := false
var _b_scrape_t := 0.0
var _b_rng := RandomNumberGenerator.new()


func setup(owner, context: Dictionary) -> void:
	owner_mg = owner
	ctx = context
	name = "BrainForceps"
	var body = ctx.get("body")
	var sec: Dictionary = {}
	if body != null and is_instance_valid(body) and body.has_method("site_section"):
		sec = body.site_section(String(ctx.get("step", {}).get("site", "brain")))
	if not sec.is_empty():
		open_u = float(sec.get("half_u", open_u))
		open_z = float(sec.get("half_side", open_z))
		brain_r = sec.get("brain_radii", brain_r)
		brain_y = float(sec.get("brain_y", brain_y))
		tray = sec.get("tray", tray)
		table_up = (sec.get("table_up", table_up) as Vector3).normalized()
		brain_seed = int(sec.get("brain_seed", 0))
		# The body's own brain hides while this step draws the one that moves.
		body.set_meta("dx_brain_hidden", true)
	else:
		var info := Head.cut_info(Vector3(0.112, 0.1, 0.09))
		open_u = float(info.half_u) * (1.0 - Head.BONE_T)
		open_z = float(info.half_z) * (1.0 - Head.BONE_T)
		brain_r = Head.brain_radii(info)
		brain_y = -(brain_r.y * 0.55 + 0.004)
		brain_seed = hash(String(ctx.get("patient_id", "walk_in"))) & 0xffff
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("brain_cords|%d" % int(ctx.get("seed", 0)))
	var n := 3 if float(ctx.get("difficulty", 1.0)) < 1.2 else 4
	var a0 := rng.randf() * TAU
	for i in n:
		var ang := a0 + TAU * float(i) / float(n) + rng.randf_range(-0.35, 0.35)
		var dirv := Vector2(cos(ang), sin(ang))
		var on_brain := Vector2(brain_r.x * dirv.x, brain_r.z * dirv.y) * 0.92
		var at_wall := Vector2(open_u * dirv.x, open_z * dirv.y) * 1.04
		var ring := on_brain.lerp(at_wall, 0.55)
		cords.append({"a": on_brain, "w": at_wall, "g": ring, "dir": (on_brain - at_wall).normalized(), "ang": ang})
	_b_rng.seed = hash("brain_bot|%d" % int(ctx.get("seed", 0)))
	tip = Vector2(0.0, open_z + 0.07)
	_b_cursor = tip
	_publish()
	_vis_tip = tip
	_build()


func _exit_tree() -> void:
	var body = ctx.get("body")
	if body != null and is_instance_valid(body):
		body.set_meta("dx_brain_hidden", false)


# =============================================================================== contract

func plane_extent() -> Vector2:
	return Vector2(maxf(open_u + 0.05, absf(tray.x) + TRAY_HALF.x + 0.02), maxf(open_z + 0.05, absf(tray.z) + TRAY_HALF.y + 0.03))


func camera_pose() -> Dictionary:
	var fov := 55.0
	var half_v := tan(deg_to_rad(fov * 0.5))
	var need := maxf(open_z + 0.04, absf(tray.z) + TRAY_HALF.y + 0.02)
	var h := need / half_v * 1.05
	return {"height": h, "back": h * 0.22, "fov": fov}


func on_jolt(_offset: Vector2, _strength: float, duration: float) -> void:
	_jolt_t = duration + 0.15


func all_cut() -> bool:
	return cut_mask == (1 << cords.size()) - 1


func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if owner_mg.done:
		return
	delta = clampf(delta, 1e-4, 0.1)
	_time += delta
	_jolt_t = maxf(0.0, _jolt_t - delta)
	var primary := (buttons & 1) != 0
	# The hand drags the tips: capped speed, a little lag.
	tip += ((p - tip) * (1.0 - exp(-delta / TIP_TAU))).limit_length(TIP_SPEED * delta)

	match stage:
		Stage.CORDS:
			_tick_cords(primary, delta)
		Stage.GRIP, Stage.LOOSE:
			_tick_take(primary, delta)
		Stage.LIFT:
			_tick_lift(primary, delta)
		Stage.CARRY:
			_tick_carry(primary, delta)
	if not primary:
		_empty = false
	_update_progress()
	_publish()


func _jaws(primary: bool, delta: float, can_take: bool) -> bool:
	# Returns true on the frame the jaws close on something.
	if primary and not _empty:
		jaw = minf(jaw + JAW_CLOSE_RATE * delta, 1.0)
		if can_take and jaw >= JAW_ON:
			jaw = JAW_ON
			return true
		if jaw >= 1.0:
			_empty = true
	elif not primary:
		jaw = maxf(jaw - JAW_OPEN_RATE * delta, 0.0)
	return false


func _nearest_cord() -> int:
	var best := -1
	var bd := GRAB_R
	for i in cords.size():
		if cut_mask & (1 << i):
			continue
		var dd := tip.distance_to(cords[i].g)
		if dd < bd:
			bd = dd
			best = i
	return best


func _tick_cords(primary: bool, delta: float) -> void:
	if clamped < 0:
		stretch = move_toward(stretch, 0.0, delta * 0.2)
		var near := _nearest_cord()
		if _jaws(primary, delta, near >= 0):
			clamped = near
			stretch = 0.0
			_last_stretch = 0.0
			stretch_v = 0.0
		return
	var c: Dictionary = cords[clamped]
	if not primary:
		clamped = -1
		jaw = 0.3
		return
	jaw = JAW_ON
	var off: Vector2 = tip - c.g
	var along := off.dot(c.dir)
	var across := absf(off.dot(Vector2(-c.dir.y, c.dir.x)))
	if across > SLIP or along < -SLIP:
		# Off the nerve's line: the jaws slip off it.
		clamped = -1
		_empty = true
		jaw = 0.4
		return
	stretch = maxf(0.0, along)
	var v := (stretch - _last_stretch) / delta
	_last_stretch = stretch
	stretch_v = lerpf(stretch_v, v, 1.0 - exp(-delta / 0.025))
	if _jolt_t > 0.0:
		stretch_v = minf(stretch_v, V_YANK * 0.8)
	if stretch > SNAP * 0.2 and stretch_v > V_YANK:
		tears += 1
		_free_cord()
		owner_mg.botch(TEAR_COST, "Yanked a nerve and tore the brain")
		return
	if stretch >= SNAP:
		_free_cord()


func _free_cord() -> void:
	cut_mask |= 1 << clamped
	clamped = -1
	stretch = 0.0
	stretch_v = 0.0
	_empty = true
	jaw = 0.5
	if all_cut():
		stage = Stage.GRIP


func _tick_take(primary: bool, delta: float) -> void:
	var over := tip.distance_to(bpos) < GRIP_R
	if _jaws(primary, delta, over):
		gripped = true
		if stage == Stage.LOOSE:
			stage = Stage.CARRY
			lift = 1.0
		else:
			stage = Stage.LIFT


func _tick_lift(primary: bool, delta: float) -> void:
	if not primary:
		gripped = false
		_empty = true
		stage = Stage.GRIP
		return
	jaw = JAW_ON
	# The brain follows the hand but the bone holds it inside the opening until it is out.
	var cu := maxf(0.002, open_u - brain_r.x)
	var cz := maxf(0.002, open_z - brain_r.z)
	var e := Vector2(tip.x / cu, tip.y / cz)
	var push := 0.0
	var target := tip
	if e.length() > 1.0:
		target = Vector2(e.normalized().x * cu, e.normalized().y * cz)
		push = tip.distance_to(target)
	bpos = bpos.lerp(target, 1.0 - exp(-delta / 0.05))
	if _jolt_t > 0.0:
		push = minf(push, SCRAPE_PUSH * 0.9)
	scrape = clampf(push / 0.012, 0.0, 1.0) if push > SCRAPE_PUSH else 0.0
	if push > SCRAPE_PUSH:
		_scrape_t += delta
		if _scrape_t >= SCRAPE_TIME:
			_scrape_t -= SCRAPE_TIME
			scrapes += 1
			owner_mg.botch(SCRAPE_COST, "Scraped the brain against the skull")
	else:
		_scrape_t = maxf(0.0, _scrape_t - delta)
		lift = minf(1.0, lift + delta / LIFT_TIME)
	if lift >= 1.0:
		stage = Stage.CARRY
		scrape = 0.0


func _tick_carry(primary: bool, delta: float) -> void:
	bpos = bpos.lerp(tip, 1.0 - exp(-delta / 0.06))
	if primary:
		jaw = JAW_ON
		return
	gripped = false
	_empty = true
	jaw = 0.2
	var t2 := Vector2(tray.x, tray.z)
	var rel := bpos - t2
	if absf(rel.x) <= TRAY_HALF.x and absf(rel.y) <= TRAY_HALF.y:
		stage = Stage.DONE
		bpos = t2 + rel * 0.5
		_update_progress()
		_publish()
		owner_mg.finish({"brain_removed": true})
		return
	drops += 1
	if Vector2(bpos.x / (open_u + 0.01), bpos.y / (open_z + 0.01)).length() <= 1.0:
		# Back into the skull.
		stage = Stage.GRIP
		lift = 0.0
		bpos = Vector2.ZERO
		owner_mg.botch(DROP_COST, "Dropped the brain back into the skull")
	else:
		stage = Stage.LOOSE
		owner_mg.botch(DROP_COST, "Dropped the brain")


func _update_progress() -> void:
	var n := cords.size()
	var cut := 0
	for i in n:
		if cut_mask & (1 << i):
			cut += 1
	var p := 0.5 * float(cut) / maxf(1.0, float(n))
	if stage == Stage.LIFT or stage == Stage.CARRY or stage == Stage.LOOSE:
		p = 0.5 + 0.2 * lift
		if stage != Stage.LIFT:
			var t2 := Vector2(tray.x, tray.z)
			var total := t2.length()
			p = 0.7 + 0.3 * clampf(1.0 - bpos.distance_to(t2) / maxf(total, 0.01), 0.0, 1.0)
	if stage == Stage.DONE:
		p = 1.0
	owner_mg.progress = minf(p, 0.99) if stage != Stage.DONE else 1.0


func _publish() -> void:
	d.tip = tip
	d.jaw = jaw
	d.cut = cut_mask
	d.k = clamped
	d.s = clampf(stretch / SNAP, 0.0, 1.0) + (1.0 if stretch_v > V_YANK * 0.7 and stretch > SNAP * 0.2 else 0.0)
	d.g = gripped
	d.l = lift
	d.b = bpos
	d.st = stage
	d.h = tears
	d.r = scrape
	d.dr = drops
	d.p = owner_mg.progress


func hud_state() -> Dictionary:
	var hint := ""
	match int(d.st):
		Stage.CORDS:
			if int(d.k) >= 0:
				hint = "Ease it out along the nerve. Don't yank." if float(d.s) < 1.0 else "Too fast! Slow down."
			else:
				hint = "Clamp a nerve at its ring and pull it free."
		Stage.GRIP:
			hint = "Every nerve is free. Hold left click on the brain."
		Stage.LIFT:
			hint = "Hold steady, lift it straight out." if float(d.r) <= 0.0 else "It's catching on the bone. Centre it."
		Stage.CARRY:
			hint = "Into the tray. Let go over it."
		Stage.LOOSE:
			hint = "Pick the brain back up."
		Stage.DONE:
			hint = "Brain out."
	return {"title": String(ctx.get("step", {}).get("label", "Pull out the brain")), "hint": hint,
		"progress": owner_mg.progress, "gauges": []}


func net_state() -> Dictionary:
	var tp: Vector2 = d.tip
	var bp: Vector2 = d.b
	return {"x": snappedf(tp.x, 0.0005), "y": snappedf(tp.y, 0.0005), "j": snappedf(float(d.jaw), 0.02),
		"c": int(d.cut), "k": int(d.k), "s": snappedf(float(d.s), 0.02), "g": 1 if d.g else 0,
		"l": snappedf(float(d.l), 0.02), "bx": snappedf(bp.x, 0.0005), "bz": snappedf(bp.y, 0.0005),
		"st": int(d.st), "h": int(d.h), "r": snappedf(float(d.r), 0.05), "dr": int(d.dr), "p": snappedf(owner_mg.progress, 0.001)}


func apply_net_state(s: Dictionary) -> void:
	d.tip = Vector2(float(s.get("x", 0.0)), float(s.get("y", 0.0)))
	d.jaw = float(s.get("j", 0.0))
	d.cut = int(s.get("c", 0))
	d.k = int(s.get("k", -1))
	d.s = float(s.get("s", 0.0))
	d.g = int(s.get("g", 0)) == 1
	d.l = float(s.get("l", 0.0))
	d.b = Vector2(float(s.get("bx", 0.0)), float(s.get("bz", 0.0)))
	d.st = int(s.get("st", 0))
	d.h = int(s.get("h", 0))
	d.r = float(s.get("r", 0.0))
	d.dr = int(s.get("dr", 0))
	owner_mg.progress = float(s.get("p", owner_mg.progress))


# =============================================================================== bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := 1.0 / 60.0 if _b_t < 0.0 else clampf(t - _b_t, 0.0, 0.1)
	_b_t = t
	# Never softlock: a sloppy surgeon steadies up after a while.
	var sk := clampf(maxf(skill, (t - 35.0) / 10.0), 0.0, 1.0)
	var sloppy := 1.0 - sk
	var cur := _b_cursor
	var buttons := 0
	var wob := Vector2(sin(t * 3.3), cos(t * 2.7)) * 0.006 * sloppy
	match _b_phase:
		"to_cord":
			var i := _next_uncut()
			if i < 0:
				_b_phase = "to_brain"
			else:
				_b_cord = i
				var g: Vector2 = cords[i].g
				cur = cur.move_toward(g, lerpf(0.35, 0.22, sk) * dt)
				if tip.distance_to(g) < 0.006:
					_b_wait -= dt
					if _b_wait <= 0.0:
						_b_phase = "clamp"
				else:
					_b_wait = lerpf(0.05, 0.12, sk)
		"clamp":
			var g2: Vector2 = cords[_b_cord].g
			cur = cur.move_toward(g2, 0.1 * dt)
			buttons = 1
			if clamped == _b_cord:
				_b_phase = "pull"
			elif _empty:
				_b_phase = "release"
				_b_wait = 0.2
				buttons = 0
		"pull":
			buttons = 1
			var c: Dictionary = cords[_b_cord]
			# A careful hand draws it in slowly; a sloppy one pulls faster than the nerve gives.
			var v := lerpf(0.3, 0.085, sk)
			cur += (c.dir as Vector2) * v * dt
			if clamped != _b_cord:
				_b_phase = "release"
				_b_wait = lerpf(0.15, 0.25, sk)
				buttons = 0
		"release":
			_b_wait -= dt
			if _b_wait <= 0.0:
				_b_phase = "to_cord" if not all_cut() else "to_brain"
		"to_brain":
			cur = cur.move_toward(bpos, 0.3 * dt)
			if tip.distance_to(bpos) < 0.008:
				_b_phase = "take"
		"take":
			buttons = 1
			cur = cur.move_toward(bpos, 0.1 * dt)
			if gripped:
				_b_phase = "lift"
			elif _empty:
				_b_phase = "retake"
				_b_wait = 0.2
				buttons = 0
		"retake":
			_b_wait -= dt
			if _b_wait <= 0.0:
				_b_phase = "to_brain"
		"lift":
			buttons = 1
			# A sloppy hand drifts toward the tray before the brain is clear of the bone, notices the
			# scrape and centres it again for a moment.
			_b_scrape_t = _b_scrape_t + dt if scrape > 0.0 else 0.0
			if _b_scrape_t > 0.7:
				_b_scrape_t = 0.0
				_b_wait = 0.6
			_b_wait -= dt
			var drift := Vector2(tray.x, tray.z).normalized() * 0.02 * sloppy if _b_wait <= 0.0 else Vector2.ZERO
			cur = cur.move_toward(drift + wob, 0.2 * dt)
			if stage == Stage.CARRY:
				_b_phase = "carry"
			elif not gripped:
				_b_phase = "to_brain"
		"carry":
			buttons = 1
			var t2 := Vector2(tray.x, tray.z)
			cur = cur.move_toward(t2 + wob, lerpf(0.3, 0.2, sk) * dt)
			if sloppy > 0.5 and not _b_dropped and bpos.distance_to(t2) < t2.length() * 0.45 and bpos.length() > open_u + 0.03:
				_b_dropped = true
				buttons = 0
				_b_phase = "to_brain"
			elif tip.distance_to(t2) < 0.012 and bpos.distance_to(t2) < 0.02:
				buttons = 0
				_b_phase = "done"
			elif not gripped:
				_b_phase = "to_brain"
		"done":
			buttons = 0
	if stage == Stage.LOOSE and _b_phase != "take" and _b_phase != "retake":
		_b_phase = "to_brain"
	_b_cursor = cur
	return {"cursor": cur, "buttons": buttons}


func _next_uncut() -> int:
	for i in cords.size():
		if not (cut_mask & (1 << i)):
			return i
	return -1


# =============================================================================== visuals

func _cue_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.no_depth_test = true
	m.render_priority = 2
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _build() -> void:
	if _built:
		return
	_built = true
	# The brain that moves, the same mesh as the body's.
	_brain = Node3D.new()
	_brain.name = "LooseBrain"
	add_child(_brain)
	var bm := MeshInstance3D.new()
	bm.mesh = Head.brain_mesh(brain_r, brain_seed)
	_brain_mat = Head.vmat("mh_brain", 0.35, 0.55).duplicate() as StandardMaterial3D
	bm.material_override = _brain_mat
	_brain.add_child(bm)
	# Brain-local X runs along u, which is plane -X.
	_brain.basis = Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))
	_brain.position = Vector3(0, brain_y, 0)

	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	tm.rings = 28
	tm.ring_segments = 6
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 8
	cyl.rings = 1
	for i in cords.size():
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.85, 0.66)
		mat.roughness = 0.4
		mat.emission_enabled = true
		mat.emission = Color(0, 0, 0)
		var seg_a := MeshInstance3D.new()
		seg_a.mesh = cyl
		seg_a.material_override = mat
		add_child(seg_a)
		var seg_b := MeshInstance3D.new()
		seg_b.mesh = cyl
		seg_b.material_override = mat
		add_child(seg_b)
		var ring_mat := _cue_mat(Color(1, 1, 1, 0.0))
		var ring := MeshInstance3D.new()
		ring.mesh = tm
		ring.material_override = ring_mat
		add_child(ring)
		_cord_nodes.append({"a": seg_a, "b": seg_b, "mat": mat, "ring": ring, "ring_mat": ring_mat})
	_brain_ring_mat = _cue_mat(Color(0.25, 1.0, 0.45, 0.0))
	_brain_ring = MeshInstance3D.new()
	_brain_ring.mesh = tm
	_brain_ring.material_override = _brain_ring_mat
	add_child(_brain_ring)
	_flush_mat = _cue_mat(Color(1.0, 0.1, 0.08, 0.0))
	_flush = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 12
	sm.rings = 6
	_flush.mesh = sm
	_flush.material_override = _flush_mat
	add_child(_flush)
	_build_tray()
	_tray_glow_mat = _cue_mat(Color(0.25, 1.0, 0.45, 0.0))
	_tray_glow = MeshInstance3D.new()
	var gl := BoxMesh.new()
	gl.size = Vector3(TRAY_HALF.x * 2.0 + 0.012, 0.004, TRAY_HALF.y * 2.0 + 0.012)
	_tray_glow.mesh = gl
	_tray_glow.material_override = _tray_glow_mat
	_tray_glow.transform = _tray_xf(0.028)
	add_child(_tray_glow)
	# The forceps themselves: the owner's model, a size up for a brain.
	owner_mg.call("_build_forceps")
	_tool = owner_mg.get("_tool")
	if _tool != null:
		_tool.get_parent().remove_child(_tool)
		add_child(_tool)
		_tool.scale = Vector3.ONE * 1.6
	for n in find_children("*", "VisualInstance3D", true, false):
		(n as VisualInstance3D).layers = 1 << 19   # Minigame.OWN_LAYER
	_vis_tip = d.tip


func _tray_xf(lift_off: float) -> Transform3D:
	var up := table_up
	var x := Vector3(1, 0, 0) - up * up.x
	x = x.normalized() if x.length() > 0.1 else Vector3(0, 0, 1).cross(up).normalized()
	var z := x.cross(up).normalized()
	return Transform3D(Basis(x, up, z), tray + up * lift_off)


func _build_tray() -> void:
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.72, 0.74, 0.76)
	steel.metallic = 0.25
	steel.roughness = 0.4
	var root := Node3D.new()
	root.name = "SpecimenTray"
	root.transform = _tray_xf(0.0)
	add_child(root)
	var base := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(TRAY_HALF.x * 2.0, 0.004, TRAY_HALF.y * 2.0)
	base.mesh = bb
	base.material_override = steel
	base.position = Vector3(0, 0.002, 0)
	root.add_child(base)
	for side in [[Vector3(TRAY_HALF.x, 0.014, 0), Vector3(0.004, 0.028, TRAY_HALF.y * 2.0)],
			[Vector3(-TRAY_HALF.x, 0.014, 0), Vector3(0.004, 0.028, TRAY_HALF.y * 2.0)],
			[Vector3(0, 0.014, TRAY_HALF.y), Vector3(TRAY_HALF.x * 2.0, 0.028, 0.004)],
			[Vector3(0, 0.014, -TRAY_HALF.y), Vector3(TRAY_HALF.x * 2.0, 0.028, 0.004)]]:
		var wall := MeshInstance3D.new()
		var wb := BoxMesh.new()
		wb.size = side[1]
		wall.mesh = wb
		wall.material_override = steel
		wall.position = side[0]
		root.add_child(wall)


func _place_cyl(mi: MeshInstance3D, from: Vector3, to: Vector3, r: float) -> void:
	var dv := to - from
	var l := dv.length()
	mi.visible = l > 0.001
	if not mi.visible:
		return
	var yv := dv / l
	var ref := Vector3.UP if absf(yv.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var xv := ref.cross(yv).normalized()
	var zv := xv.cross(yv).normalized()
	mi.transform = Transform3D(Basis(xv * r, yv * l, zv * r), (from + to) * 0.5)


func tick(delta: float) -> void:
	if not _built:
		return
	_cue_t += delta
	var operator := bool(ctx.get("operator", false))
	var k := 1.0 if operator else 1.0 - exp(-delta * 18.0)
	_vis_tip = _vis_tip.lerp(d.tip, k)
	_vis_b = _vis_b.lerp(d.b, k)
	_vis_l = lerpf(_vis_l, float(d.l), k)
	var st := int(d.st)
	var lift_h := brain_r.y * 2.0 + 0.02

	# The brain.
	var by := brain_y + lift_h * smoothstep(0.0, 1.0, _vis_l)
	var bxz := _vis_b
	if st == Stage.LOOSE:
		by = tray.y + brain_r.y * 0.5 + 0.01
	elif st == Stage.DONE:
		if _done_t < 0.0:
			_done_t = 0.0
			_sfx("surgery_forceps_clink", -2.0)
			_sfx("dissection_plop", -2.0)
		_done_t += delta
		var f := clampf(_done_t / 0.35, 0.0, 1.0)
		by = lerpf(brain_y + lift_h, tray.y + brain_r.y * 0.45 + 0.004, f * f)
		bxz = _vis_b.lerp(Vector2(tray.x, tray.z), f)
	_brain.position = Vector3(bxz.x, by, bxz.y)
	# A torn brain goes darker and bloodier with every tear and drop.
	var harm := clampf(float(int(d.h) + int(d.dr)) * 0.12, 0.0, 0.6)
	_brain_mat.albedo_color = Color(1, 1, 1).lerp(Color(0.55, 0.25, 0.25), harm)

	# The nerves.
	var cut := int(d.cut)
	var clamp_i := int(d.k)
	var s_raw := float(d.s)
	var yank := s_raw > 1.0
	var s01 := clampf(s_raw - (1.0 if yank else 0.0), 0.0, 1.0)
	var wall_y := -0.012
	var brain_top := brain_y + brain_r.y * 0.35
	var tip_y := brain_top + 0.012
	for i in cords.size():
		var cn: Dictionary = _cord_nodes[i]
		var c: Dictionary = cords[i]
		var a3 := Vector3(c.a.x, brain_top, c.a.y) + Vector3(bxz.x, by - brain_y, bxz.y) * (1.0 if st != Stage.CORDS else 0.0)
		var w3 := Vector3(c.w.x, wall_y, c.w.y)
		var gone := (cut & (1 << i)) != 0
		var ring_mi: MeshInstance3D = cn.ring
		var rmat: StandardMaterial3D = cn.ring_mat
		var mat: StandardMaterial3D = cn.mat
		if gone:
			# Two limp stubs.
			_place_cyl(cn.a, a3, a3.lerp(w3, 0.18) + Vector3(0, -0.006, 0), 0.0028)
			_place_cyl(cn.b, w3, w3.lerp(a3, 0.18) + Vector3(0, -0.006, 0), 0.0028)
			ring_mi.visible = false
			mat.emission = Color(0, 0, 0)
			continue
		var mid := Vector3(c.g.x, wall_y * 0.5 + brain_top * 0.5, c.g.y)
		if clamp_i == i:
			mid = Vector3(_vis_tip.x, tip_y - 0.004, _vis_tip.y)
		_place_cyl(cn.a, a3, mid, 0.0036 * (1.0 - 0.35 * s01))
		_place_cyl(cn.b, mid, w3, 0.0036 * (1.0 - 0.35 * s01))
		var col := Color(0.25, 1.0, 0.4).lerp(Color(1.0, 0.72, 0.1), smoothstep(0.45, 0.9, s01)) if clamp_i == i else Color(0.3, 0.26, 0.14)
		if clamp_i == i and yank:
			col = Color(1.0, 0.1, 0.05)
		mat.emission = col
		mat.emission_energy_multiplier = 1.4
		# Ring where to take it: a slow white pulse, steady green when the tips are on it.
		ring_mi.visible = st == Stage.CORDS and clamp_i < 0
		if ring_mi.visible:
			ring_mi.position = Vector3(c.g.x, mid.y + 0.004, c.g.y)
			var on := _vis_tip.distance_to(c.g) < GRAB_R
			var sc := 0.014 if on else 0.011 + 0.005 * fmod(_cue_t * 0.9 + float(i) * 0.3, 1.0)
			ring_mi.scale = Vector3(sc, sc * 0.3, sc)
			rmat.albedo_color = Color(0.25, 1.0, 0.45, 0.9) if on else Color(1.0, 0.95, 0.8, 0.75 * (1.0 - fmod(_cue_t * 0.9 + float(i) * 0.3, 1.0)))

	# The brain's own ring once it can be taken.
	var show_ring := st == Stage.GRIP or st == Stage.LOOSE
	_brain_ring.visible = show_ring
	if show_ring:
		var on_b := _vis_tip.distance_to(_vis_b) < GRIP_R
		var rs := maxf(brain_r.x, brain_r.z) * (0.75 if on_b else 0.7 + 0.08 * sin(_cue_t * 5.0))
		_brain_ring.position = Vector3(_vis_b.x, by + brain_r.y * 0.6, _vis_b.y)
		_brain_ring.scale = Vector3(rs, rs * 0.25, rs)
		_brain_ring_mat.albedo_color = Color(0.25, 1.0, 0.45, 0.9 if on_b else 0.55)
	# Scraping: the bone flushes red where the brain touches it.
	_tear_flash = maxf(0.0, _tear_flash - delta * 2.5)
	var r := float(d.r)
	_flush.visible = (r > 0.02 and st == Stage.LIFT) or _tear_flash > 0.02
	if _flush.visible:
		var dir := _vis_b.normalized() if _vis_b.length() > 0.001 else Vector2(1, 0)
		var at := Vector2(dir.x * open_u, dir.y * open_z)
		if _tear_flash > 0.02 and r <= 0.02:
			at = _vis_tip
		_flush.position = Vector3(at.x, -0.004, at.y)
		var fr := 0.006 + 0.01 * maxf(r, _tear_flash)
		_flush.scale = Vector3(fr, 0.002, fr)
		_flush_mat.albedo_color = Color(1.0, 0.12, 0.08, clampf(0.35 + 0.6 * maxf(r, _tear_flash), 0.0, 0.9))
	# The tray glows while the brain is out and in hand.
	var carry := st == Stage.CARRY
	_tray_glow_mat.albedo_color = Color(0.25, 1.0, 0.45, (0.45 + 0.25 * sin(_cue_t * 5.0)) if carry else 0.0)
	_tray_glow.visible = carry

	# The forceps.
	if _tool != null:
		var ty := tip_y
		if st == Stage.LIFT or st == Stage.CARRY:
			ty = by + brain_r.y * 0.9
		elif st == Stage.LOOSE or (st == Stage.GRIP and _vis_tip.distance_to(_vis_b) < GRIP_R * 1.5):
			ty = by + brain_r.y * 0.9
		elif clamp_i < 0 and st == Stage.CORDS:
			ty = tip_y + 0.02
		_vis_y = lerpf(_vis_y, ty, 1.0 - exp(-delta * 14.0))
		_tool.position = Vector3(_vis_tip.x, _vis_y, _vis_tip.y)
		_tool.basis = Basis(Vector3.UP, atan2(-0.83, 0.55)).scaled(Vector3.ONE * 1.6)
		var arms: Array = owner_mg.get("_arms")
		var spread := lerpf(0.0062, 0.0006, float(d.jaw))
		for i in arms.size():
			var side := -1.0 if i == 0 else 1.0
			var dz := side * spread - side * 0.0034
			(arms[i] as Node3D).basis = Basis(Vector3.UP, -atan2(dz, 0.125))
	# Sounds from the displayed state, so spectators hear them too.
	var closed := float(d.jaw) >= JAW_ON - 0.05
	if closed and not _was_closed:
		_sfx("surgery_forceps_click", -6.0)
	_was_closed = closed
	if cut != _seen_cut:
		if cut > _seen_cut:
			_sfx("dissection_snap", -3.0)
			_sfx("surgery_forceps_squelch", -6.0)
		_seen_cut = cut
	if int(d.h) > _seen_h:
		_tear_flash = 1.0
		_sfx("surgery_forceps_scrape", -3.0)
		var body = ctx.get("body")
		if body != null and is_instance_valid(body) and body.has_method("stir"):
			body.stir(0.4)
	_seen_h = int(d.h)
	if int(d.dr) > _seen_dr:
		_sfx("dissection_plop", -1.0)
	_seen_dr = int(d.dr)


func _sfx(cue: String, vol_db := 0.0) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	var a = loop.root.get_node_or_null("Audio")
	if a == null:
		return
	a.play(cue, global_position if is_inside_tree() else null, vol_db, 0.08)


# =============================================================================== self-test

## Plays the bot on both monsters at three skills, with and without stir jolts, headless.
static func self_test(parent: Node) -> Dictionary:
	var fscript: GDScript = load("res://scripts/surgery/games/forceps.gd")
	var out := {}
	for pid in ["walk_in", "discharged"]:
		for mode in [["skill1.0", 1.0, false], ["skill0.5", 0.5, false], ["skill0.0", 0.0, false], ["skill1.0+jolts", 1.0, true], ["skill0.0+jolts", 0.0, true]]:
			var runs := 4
			var agg := {"done": 0, "time": 0.0, "botch": 0.0, "n": 0, "max_botch": 0.0, "tears": 0, "scrapes": 0, "drops": 0}
			for r in runs:
				var g = fscript.new()
				parent.add_child(g)
				var stats := {"botch": 0.0, "n": 0, "done": false, "flag": false}
				g.botched.connect(func(a, _r): stats.botch += a; stats.n += 1)
				g.finished.connect(func(res): stats.done = true; stats.flag = bool(res.get("brain_removed", false)))
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": "dissection",
					"step": Procedures.step("dissection", 1), "variant": "brain", "difficulty": 1.0 + 0.12 * float(r),
					"seed": hash("brain_selftest_%s_%d" % [pid, r]), "flags": {}, "body": null, "operator": true})
				var rng := RandomNumberGenerator.new()
				rng.seed = hash("brain_jolts_%d" % r)
				var t := 0.0
				var dt := 1.0 / 60.0
				var jolt := Vector2.ZERO
				var jolt_t := 0.0
				var ext: Vector2 = g.plane_extent()
				while t < 80.0 and not stats.done:
					t += dt
					var inp: Dictionary = g.bot_input(t, float(mode[1]))
					var c: Vector2 = inp.cursor
					if mode[2]:
						jolt_t -= dt
						if jolt_t <= 0.0 and rng.randf() < dt / 3.0:
							jolt = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.03, 0.07)
							jolt_t = 0.35
							g.on_jolt(jolt, 0.8, 0.35)
						if jolt_t > 0.0:
							c += jolt * (jolt_t / 0.35)
					c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
					g.handle_cursor(c, int(inp.buttons), dt)
					g.tick(dt)
					g.apply_net_state(g.net_state())
				var bf = g.get("_brain_game")
				agg.done += 1 if stats.done and stats.flag else 0
				agg.time += t
				agg.botch += stats.botch
				agg.n += stats.n
				agg.max_botch = maxf(agg.max_botch, stats.botch)
				agg.tears += int(bf.tears)
				agg.scrapes += int(bf.scrapes)
				agg.drops += int(bf.drops)
				print("[forceps-selftest] brain %-10s %-15s run=%d %s t=%.1fs botches=%d condition-=%.1f tears=%d scrapes=%d drops=%d" % [
					pid, mode[0], r, "DONE" if stats.done and stats.flag else "UNFINISHED", t, stats.n, stats.botch, bf.tears, bf.scrapes, bf.drops])
				g.queue_free()
			print("[forceps-selftest] brain %-10s %-15s done %d/%d  mean time %.1fs  mean condition lost %.1f (max %.1f)  tears %d scrapes %d drops %d" % [
				pid, mode[0], agg.done, runs, agg.time / runs, agg.botch / runs, agg.max_botch, agg.tears, agg.scrapes, agg.drops])
			out["%s|%s" % [pid, mode[0]]] = agg
	return out
