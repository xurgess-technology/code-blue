extends "res://scripts/surgery/minigame.gd"
## Step "stitch" (ailment `stitches`): close a downed teammate's gash on the OR's player table.
##
## No gauges: the wound shows what is right.
##   A green ring marks where the next bite goes, just outside one edge of the gash. Click it: the
##   curved needle goes in and the thread follows. Then a ring appears across the gash: click that
##   and the thread pulls tight, visibly drawing that part of the wound shut (and it bleeds less).
##   Stitches alternate which side they start from, working along the gash.
##   Close to the ring but not on it (amber) still works: a loose stitch closes the wound less and
##   keeps oozing a little. Far off the ring (red) the needle tears the skin: it tugs, the body
##   flinches, blood wells up (botch). Stabbing into the open wound itself is worse (botch).
## Result {"stitched": true, "quality": 0..1}.

enum Stage { STITCH, DONE }

const N_STITCHES := 6
const BITE_OUT := 0.011          # a bite sits this far outside the wound edge
const TOL := 0.011               # a click this close to the ring is a good bite
const LOOSE_K := 2.3             # up to this many TOLs away it is a loose bite
const PULL_TIME := 0.32
const BAD_CD := 0.45
const BOTCH_SKIN := 1.5
const BOTCH_WOUND := 2.5
const LOOSE_CLOSE := 0.55
const MAX_BEADS := 5
const SEGS := 28

var stage: int = Stage.STITCH
var stitch := 0                  # stitches finished
var half := 0                    # 0: first bite of this stitch pending, 1: the bite across
var first_q := 0                 # quality of this stitch's first bite (1 loose, 2 good)
var quality: Array = []          # per finished stitch: 1 loose, 2 good
var cursor := Vector2(0.08, 0.07)
var pull := 0.0
var bads := 0
var last_bad := Vector2.ZERO
var beads: Array = []

var half_len := 0.1
var half_gap := 0.016
var tol := TOL
var _prev_primary := false
var _bad_cd := 0.0
var _t := 0.0
var _jolt_t := 0.0
var _jolt_dur := 0.35
var _jolt_off := Vector2.ZERO
var _seen_bads := 0
var _seen_stitch := 0
var _seen_half := 0
var _seen_stage := 0
var _bad_flash := 0.0
var _hint_bad := 0.0

# visuals
var _built := false
var _closure_shown: Array = []
var _lips: Array[MeshInstance3D] = []     # 2 per segment
var _cores: Array[MeshInstance3D] = []
var _threads: Array[MeshInstance3D] = []
var _knots: Array[MeshInstance3D] = []
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _needle: Node3D
var _live_thread: MeshInstance3D
var _flash: MeshInstance3D
var _flash_mat: StandardMaterial3D
var _bead_nodes: Array[MeshInstance3D] = []
var _thread_mat: StandardMaterial3D
var _loose_mat: StandardMaterial3D

# bot
var _bt := 0.0
var _bc := Vector2(0.09, 0.07)
var _b_err := Vector2.ZERO
var _b_key := -1
var _b_dwell := 0.0
var _b_cd := 0.0
var _b_rng := RandomNumberGenerator.new()


func setup(context: Dictionary) -> void:
	super.setup(context)
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("site_section"):
		var sec: Dictionary = body.site_section(String(ctx.get("step", {}).get("site", "gash")))
		half_len = float(sec.get("half_len", half_len))
		half_gap = float(sec.get("half_gap", half_gap))
	if body != null and is_instance_valid(body) and body.has_method("show_gash"):
		body.show_gash(false)
	var diff := maxf(0.5, float(ctx.get("difficulty", 1.0)))
	tol = TOL / sqrt(diff)
	_b_rng.seed = int(ctx.get("seed", 1))
	_build()
	_update_visuals(0.0, true)


func _exit_tree() -> void:
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("show_gash"):
		body.show_gash(true)


func plane_extent() -> Vector2:
	return Vector2(0.17, 0.11)


func camera_pose() -> Dictionary:
	return {"height": 0.38, "back": 0.13, "fov": 55.0}


# ---------------------------------------------------------------------------- geometry

func stitch_x(i: int) -> float:
	return lerpf(-half_len * 0.78, half_len * 0.78, float(i) / float(N_STITCHES - 1))


## Which side (+1 / -1 along Z) stitch i starts from: they alternate.
func first_side(i: int) -> float:
	return 1.0 if i % 2 == 0 else -1.0


func closure_of(i: int, shown := false) -> float:
	if shown and i < _closure_shown.size():
		return float(_closure_shown[i])
	if i >= quality.size():
		return 0.0
	return 1.0 if int(quality[i]) == 2 else LOOSE_CLOSE


## Half-width of the open wound at x (metres), after the stitches so far pulled it in.
func gap_at(x: float, shown := false) -> float:
	var u := clampf(x / half_len, -1.0, 1.0)
	var shape := sqrt(maxf(0.0, 1.0 - u * u))
	var spacing := half_len * 1.56 / float(N_STITCHES - 1)
	var pinch := 0.0
	for i in N_STITCHES:
		var c := closure_of(i, shown)
		if c <= 0.0:
			continue
		var d := (x - stitch_x(i)) / (spacing * 0.75)
		pinch = maxf(pinch, c * exp(-d * d))
	return half_gap * shape * (1.0 - 0.88 * pinch)


func target() -> Vector2:
	var i := mini(stitch, N_STITCHES - 1)
	var x := stitch_x(i)
	var side := first_side(i) * (1.0 if half == 0 else -1.0)
	return Vector2(x, side * (half_gap * sqrt(maxf(0.0, 1.0 - pow(x / half_len, 2.0))) + BITE_OUT))


func open_fraction() -> float:
	var total := 0.0
	var open := 0.0
	for k in 12:
		var x := lerpf(-half_len, half_len, (k + 0.5) / 12.0)
		var full := half_gap * sqrt(maxf(0.0, 1.0 - pow(x / half_len, 2.0)))
		total += full
		open += gap_at(x)
	return open / maxf(total, 1e-6)


# ---------------------------------------------------------------------------- rules

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	cursor = p
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var pressed := primary and not _prev_primary
	_prev_primary = primary
	_bad_cd = maxf(0.0, _bad_cd - delta)
	if pull > 0.0:
		pull = maxf(0.0, pull - delta)
		_update_progress()
		return
	if stage != Stage.STITCH:
		return
	if stitch >= N_STITCHES:
		_complete()
		return
	if pressed:
		var d := p.distance_to(target())
		if d <= tol * LOOSE_K:
			var q := 2 if d <= tol else 1
			if half == 0:
				first_q = q
				half = 1
			else:
				quality.append(mini(first_q, q))
				stitch += 1
				half = 0
				first_q = 0
				pull = PULL_TIME
		elif _bad_cd <= 0.0:
			_bad_cd = BAD_CD
			bads += 1
			last_bad = p
			beads.append(p)
			if beads.size() > MAX_BEADS:
				beads.pop_front()
			if absf(p.x) < half_len and absf(p.y) < gap_at(p.x) + 0.002:
				botch(BOTCH_WOUND, "Stabbed into the open wound")
			else:
				botch(BOTCH_SKIN, "The needle tore the skin")
	_update_progress()


func _update_progress() -> void:
	if stage == Stage.DONE:
		progress = 1.0
		return
	progress = clampf((float(stitch) + 0.5 * half) / float(N_STITCHES), 0.0, 0.99)


func _complete() -> void:
	stage = Stage.DONE
	var sum := 0.0
	for q in quality:
		sum += 1.0 if int(q) == 2 else 0.5
	var qual := sum / float(maxi(1, quality.size()))
	progress = 1.0
	finish({"stitched": true, "quality": snappedf(qual, 0.01)})


func on_jolt(offset: Vector2, _strength: float, duration: float) -> void:
	_jolt_off = offset
	_jolt_dur = maxf(0.05, duration)
	_jolt_t = _jolt_dur


func tick(delta: float) -> void:
	_t += delta
	_jolt_t = maxf(0.0, _jolt_t - delta)
	_bad_flash = maxf(0.0, _bad_flash - delta)
	_hint_bad = maxf(0.0, _hint_bad - delta)
	_react()
	_update_visuals(delta, false)


## Sounds and the body's reactions, on every machine, from the replicated state.
func _react() -> void:
	var at = global_position if is_inside_tree() else null
	var body = ctx.get("body")
	var has_body: bool = body != null and is_instance_valid(body)
	if bads > _seen_bads:
		_bad_flash = 0.5
		_hint_bad = 2.2
		_audio("downed_tug", at, -2.0, 0.1)
		if has_body and body.has_method("stir"):
			body.stir(0.5)
	if quality.size() > _seen_stitch or half > _seen_half:
		_audio("downed_stitch", at, -3.0, 0.08)
	if stage == Stage.DONE and _seen_stage != Stage.DONE:
		_audio("surgery_done", at, -4.0)
	_seen_stage = stage
	_seen_stitch = quality.size()
	_seen_bads = bads
	_seen_half = half
	if has_body and body.has_method("set_bleeding"):
		body.set_bleeding("gash", clampf(open_fraction() * 0.55 + _bad_flash * 0.8 + 0.08 * _loose_count(), 0.0, 1.0) if stage != Stage.DONE else 0.05 * _loose_count())


func _loose_count() -> int:
	var n := 0
	for q in quality:
		if int(q) == 1:
			n += 1
	return n


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Stitch the wound closed"))
	var hint := ""
	if stage == Stage.DONE:
		hint = "Closed up." if _loose_count() == 0 else "Closed, a little loose in places."
	elif _hint_bad > 0.0:
		hint = "Too far off: put the needle in on the green ring."
	elif stitch == 0 and half == 0:
		hint = "Click the green ring, then the one across, to pull the gash shut."
	elif half == 1:
		hint = "Now across the gash: click the other ring to pull it tight."
	else:
		hint = "Stitch %d of %d: green ring, then across." % [stitch + 1, N_STITCHES]
	return {"title": title, "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"s": stitch, "h": half, "fq": first_q, "q": quality.duplicate(), "c": cursor, "pu": snappedf(pull, 0.02),
		"b": bads, "bt": last_bad, "be": beads.duplicate(), "st": stage, "p": snappedf(progress, 0.001)}


func apply_net_state(s: Dictionary) -> void:
	stitch = int(s.get("s", stitch))
	half = int(s.get("h", half))
	first_q = int(s.get("fq", first_q))
	var q = s.get("q", quality)
	if q is Array:
		quality = q.duplicate()
	cursor = s.get("c", cursor)
	pull = float(s.get("pu", pull))
	bads = int(s.get("b", bads))
	last_bad = s.get("bt", last_bad)
	var be = s.get("be", beads)
	if be is Array:
		beads = be.duplicate()
	stage = int(s.get("st", stage))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := 1.0 - skill
	_b_cd = maxf(0.0, _b_cd - dt)
	if t < 0.5 or pull > 0.0 or stage == Stage.DONE:
		return {"cursor": _bc, "buttons": 0}
	var key := stitch * 2 + half + bads * 100
	if key != _b_key:
		_b_key = key
		_b_dwell = 0.0
		# A sloppy hand lands off the ring, less so as it settles in.
		var settle := clampf(1.0 - t / 30.0, 0.2, 1.0)
		var r := _b_rng.randf_range(0.3, 1.0) * 0.042 * sloppy * settle
		_b_err = Vector2.RIGHT.rotated(_b_rng.randf() * TAU) * r
	var aim := target() + _b_err
	_bc = _bc.move_toward(aim, lerpf(0.07, 0.15, skill) * dt)
	if _bc.distance_to(aim) < 0.0015:
		_b_dwell += dt
	var buttons := 0
	if _b_dwell >= lerpf(0.2, 0.32, skill) and _b_cd <= 0.0:
		buttons = BUTTON_PRIMARY
		_b_cd = 0.15
		_b_dwell = 0.0
	return {"cursor": _bc, "buttons": buttons}


## Headless check through the lab: `tools/minigame_lab.tscn -- --selftest=stitches`.
static func self_test() -> Array:
	var script: GDScript = load("res://scripts/surgery/games/stitches.gd")
	var runner: GDScript = load("res://scripts/surgery/games/gauze.gd")
	var out := []
	for skill in [1.0, 0.5, 0.0]:
		for diff in [1.0, 1.36]:
			var g = script.new()
			var tally := {"n": 0, "v": 0.0, "done": false, "q": -1.0, "reasons": {}}
			g.botched.connect(func(a, r): tally.n += 1; tally.v += a; tally.reasons[r] = int(tally.reasons.get(r, 0)) + 1)
			g.finished.connect(func(r): tally.done = true; tally.q = float(r.get("quality", -1.0)))
			g.setup({"patient_id": "player", "patient": {}, "ailment_id": "stitches",
				"step": Procedures.step("stitches", 0), "variant": "", "shift": 1, "difficulty": diff,
				"flags": {"sedation": 1.0}, "seed": hash("stitch%.1f" % skill), "body": null, "operator": true})
			var t: float = runner._run_bot(g, skill, 1.0, 7)
			print("[stitches self-test] skill=%.1f diff=%.2f  %s  time=%5.1fs  quality=%.2f  botches=%d vitals=%5.1f  %s" % [
				skill, diff, "DONE" if tally.done else "UNFINISHED", t, tally.q, tally.n, tally.v, str(tally.reasons)])
			out.append({"skill": skill, "diff": diff, "done": tally.done, "time": t, "vitals": tally.v, "quality": tally.q})
			g.free()
	return out


# ---------------------------------------------------------------------------- visuals

func _unshaded(col: Color, on_top := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if on_top:
		m.no_depth_test = true
		m.render_priority = 2
	return m


func _lit(col: Color, rough := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _build() -> void:
	if _built:
		return
	_built = true
	for i in N_STITCHES:
		_closure_shown.append(0.0)
	var seg_len := half_len * 2.0 / float(SEGS)
	var lip_mat := _lit(Color(0.45, 0.07, 0.07), 0.3)
	var core_mat := _lit(Color(0.09, 0.0, 0.005), 0.2)
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or not body.has_method("show_gash"):
		# No player body under us (a bare lab run): a patch of skin so the wound reads.
		var skin := MeshInstance3D.new()
		skin.mesh = _box_mesh(Vector3(half_len * 2.0 + 0.08, 0.002, half_gap * 2.0 + 0.1))
		skin.material_override = _lit(Color(0.6, 0.44, 0.36), 0.7)
		skin.position = Vector3(0, -0.001, 0)
		add_child(skin)
	var lip_mesh := _box_mesh(Vector3(seg_len * 1.1, 0.004, 0.005))
	var core_mesh := _box_mesh(Vector3(seg_len * 1.02, 0.003, 1.0))
	for k in SEGS:
		for s in 2:
			var lip := MeshInstance3D.new()
			lip.mesh = lip_mesh
			lip.material_override = lip_mat
			add_child(lip)
			_lips.append(lip)
		var core := MeshInstance3D.new()
		core.mesh = core_mesh
		core.material_override = core_mat
		add_child(core)
		_cores.append(core)
	_thread_mat = _lit(Color(0.05, 0.08, 0.2), 0.5)
	_loose_mat = _lit(Color(0.85, 0.55, 0.1), 0.5)
	var thread_mesh := _box_mesh(Vector3(1.0, 0.0026, 0.0026))
	var knot_mesh := SphereMesh.new()
	knot_mesh.radius = 0.0032
	knot_mesh.height = 0.0064
	knot_mesh.radial_segments = 8
	knot_mesh.rings = 4
	for i in N_STITCHES:
		var th := MeshInstance3D.new()
		th.mesh = thread_mesh
		th.material_override = _thread_mat
		th.visible = false
		add_child(th)
		_threads.append(th)
		var kn := MeshInstance3D.new()
		kn.mesh = knot_mesh
		kn.material_override = _thread_mat
		kn.visible = false
		add_child(kn)
		_knots.append(kn)
	_live_thread = MeshInstance3D.new()
	_live_thread.mesh = thread_mesh
	_live_thread.material_override = _thread_mat
	_live_thread.visible = false
	add_child(_live_thread)

	# The ring: where the needle goes next. Never hidden.
	var torus := TorusMesh.new()
	torus.inner_radius = 0.68
	torus.outer_radius = 1.0
	torus.rings = 24
	torus.ring_segments = 6
	_ring_mat = _unshaded(Color(0.3, 1.0, 0.45, 0.9), true)
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = _ring_mat
	add_child(_ring)
	_ghost_mat = _unshaded(Color(0.75, 0.8, 0.8, 0.35), true)
	_ghost = MeshInstance3D.new()
	_ghost.mesh = torus
	_ghost.material_override = _ghost_mat
	add_child(_ghost)

	# The curved needle: a half ring of steel with its point at the cursor.
	_needle = Node3D.new()
	_needle.name = "Needle"
	add_child(_needle)
	var steel := _lit(Color(0.86, 0.88, 0.92), 0.2)
	steel.metallic = 1.0
	var arc := MeshInstance3D.new()
	var nt := TorusMesh.new()
	nt.inner_radius = 0.0105
	nt.outer_radius = 0.0125
	nt.rings = 20
	nt.ring_segments = 5
	arc.mesh = nt
	arc.material_override = steel
	arc.rotation_degrees = Vector3(90, 0, 0)
	arc.position = Vector3(0.0, 0.0115, 0.0)
	_needle.add_child(arc)
	# The back half of the ring is hidden inside the skin: a cheap way to read as a curved needle.
	var holder := MeshInstance3D.new()
	holder.mesh = _box_mesh(Vector3(0.004, 0.05, 0.003))
	holder.material_override = _lit(Color(0.3, 0.32, 0.36), 0.4)
	holder.position = Vector3(0.0, 0.045, 0.0)
	_needle.add_child(holder)

	_flash_mat = _unshaded(Color(1.0, 0.15, 0.1, 0.0), true)
	_flash = MeshInstance3D.new()
	var fs := SphereMesh.new()
	fs.radius = 1.0
	fs.height = 2.0
	fs.radial_segments = 12
	fs.rings = 6
	_flash.mesh = fs
	_flash.material_override = _flash_mat
	_flash.visible = false
	add_child(_flash)
	var bm := SphereMesh.new()
	bm.radius = 0.0035
	bm.height = 0.004
	bm.radial_segments = 8
	bm.rings = 4
	var blood := _lit(Color(0.45, 0.0, 0.02), 0.1)
	for i in MAX_BEADS:
		var b := MeshInstance3D.new()
		b.mesh = bm
		b.material_override = blood
		b.visible = false
		add_child(b)
		_bead_nodes.append(b)
	_set_layers(self)


func _set_layers(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as VisualInstance3D).layers = OWN_LAYER
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c)


func _place_thread(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var len := d.length()
	if len < 0.0005:
		mi.visible = false
		return
	mi.visible = true
	var x := d / len
	var up := Vector3.UP if absf(x.dot(Vector3.UP)) < 0.95 else Vector3.BACK
	var z := x.cross(up).normalized()
	var y := z.cross(x).normalized()
	mi.transform = Transform3D(Basis(x * len, y, z), (a + b) * 0.5)


func _update_visuals(delta: float, snap: bool) -> void:
	if not _built:
		return
	var k := 1.0 if snap else clampf(delta / PULL_TIME * 1.6, 0.0, 1.0)
	for i in N_STITCHES:
		var want := closure_of(i)
		_closure_shown[i] = want if snap else move_toward(float(_closure_shown[i]), want, k)
	var shake := Vector2.ZERO
	if _jolt_t > 0.0:
		shake = _jolt_off * (_jolt_t / _jolt_dur) * sin(_jolt_t * 50.0)
	# Wound lips and the dark gap between them.
	var seg_len := half_len * 2.0 / float(SEGS)
	for s in SEGS:
		var x := -half_len + (s + 0.5) * seg_len
		var g := gap_at(x, true)
		var twitch := shake.y * 0.15
		(_lips[s * 2] as MeshInstance3D).position = Vector3(x, 0.0025, g + 0.003 + twitch)
		(_lips[s * 2 + 1] as MeshInstance3D).position = Vector3(x, 0.0025, -g - 0.003 + twitch)
		var core := _cores[s] as MeshInstance3D
		core.visible = g > 0.0004
		core.scale = Vector3(1, 1, maxf(0.0005, g * 2.0))
		core.position = Vector3(x, 0.001, twitch)
	# Finished stitches: thread across the (now narrow) gap, knotted on top.
	for i in N_STITCHES:
		var th := _threads[i] as MeshInstance3D
		var kn := _knots[i] as MeshInstance3D
		if i >= quality.size():
			th.visible = false
			kn.visible = false
			continue
		var x := stitch_x(i)
		var reach := gap_at(x, true) + BITE_OUT * 0.8
		var slant := 0.004 * first_side(i)
		_place_thread(th, Vector3(x - slant, 0.004, reach), Vector3(x + slant, 0.004, -reach))
		th.material_override = _thread_mat if int(quality[i]) == 2 else _loose_mat
		kn.visible = true
		kn.position = Vector3(x + slant, 0.005, -reach * first_side(i))
	# The ring for the next bite, and a faint one across the gap for the bite after.
	var active := stage == Stage.STITCH and stitch < N_STITCHES and pull <= 0.0
	_ring.visible = active
	_ghost.visible = active and half == 0
	var tgt := target()
	if active:
		var d := cursor.distance_to(tgt)
		var pulse := 0.5 + 0.5 * sin(_t * 7.0)
		var col := Color(0.3, 1.0, 0.45, 0.65 + 0.3 * pulse)
		var r := tol * 1.15
		if d <= tol:
			col = Color(0.45, 1.0, 0.55, 1.0)
			r = tol * 0.85
		elif d <= tol * LOOSE_K:
			col = Color(1.0, 0.72, 0.18, 0.95)
		_ring_mat.albedo_color = col
		_ring.position = plane_to_local(tgt, 0.004)
		_ring.scale = Vector3(r, 0.4 * r, r)
		var across := Vector2(tgt.x, -tgt.y)
		_ghost.position = plane_to_local(across, 0.004)
		_ghost.scale = Vector3(tol * 0.7, 0.3 * tol, tol * 0.7)
	# The needle at the cursor (dipping while a stitch pulls tight), trailing thread to its anchor.
	var tip := cursor + shake
	var dip := 0.0
	if pull > 0.0:
		dip = -0.004 * sin(clampf(1.0 - pull / PULL_TIME, 0.0, 1.0) * PI)
	_needle.visible = stage == Stage.STITCH
	_needle.position = plane_to_local(tip, 0.002 + dip)
	_needle.rotation = Vector3(0.0, 0.5 if half == 0 else -0.5, -0.25)
	if half == 1:
		var i := mini(stitch, N_STITCHES - 1)
		var x := stitch_x(i)
		var anchor := Vector2(x, first_side(i) * (gap_at(x, true) + BITE_OUT))
		_place_thread(_live_thread, plane_to_local(anchor, 0.004), plane_to_local(tip, 0.01))
	else:
		_live_thread.visible = false
	# A mistake: a red burst where the needle tore, and a bead of blood that stays.
	_flash.visible = _bad_flash > 0.0
	if _flash.visible:
		var a := _bad_flash / 0.5
		_flash_mat.albedo_color = Color(1.0, 0.12, 0.08, 0.55 * a)
		_flash.position = plane_to_local(last_bad, 0.004)
		_flash.scale = Vector3.ONE * lerpf(0.035, 0.01, a)
	for i in _bead_nodes.size():
		var b := _bead_nodes[i]
		b.visible = i < beads.size()
		if b.visible:
			b.position = plane_to_local(beads[i], 0.003)


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var ml = Engine.get_main_loop()
	var a = ml.root.get_node_or_null("Audio") if ml is SceneTree else null
	if a != null:
		a.play(cue, at, vol, jitter)
