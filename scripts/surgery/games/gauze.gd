extends "res://scripts/surgery/minigame.gd"
## Step "dress": gauze. Two variants from ctx.variant.
##
## pack  (gunshot)    PACK, then WRAP a pressure dressing over the wound.
## stump (amputation) WRAP only, around the cut limb, over more turns.
##
## Everything the player needs is in the world, not on the HUD:
##
## PACK  The wound pulses blood with the heartbeat and a pool spreads round it. Press (or hold)
##       the gauze pad on the wound: each wad goes in with a squelch and the spurting shrinks.
##       Pressing on bare skin drops the wad there (botch). If the pool gets too big the wound
##       gushes (botch).
## WRAP  Hold left click and circle the roll round the wound / stump. How far out you pull the
##       roll is the tension, and the gauze shows it:
##         close in  = LOOSE: the strip sags and flaps, the turns go on baggy (count for less),
##                     and a bleeding wound soaks red through them (botch over time);
##         middle    = GOOD: a taut white strip, a green trail behind the roll;
##         far out   = TIGHT: the strip thins and turns pink, it creaks, the skin next to the
##                     dressing blanches white, and if you keep it up that botches.
##       A faint ring shows the path that pulls it just right; it glows green while you are on it.
##       Going backwards unwinds the last turns. A stir yanks the wrap loose (botch).
## Result {"dressed": true}.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Stage { PACK, WRAP, DONE }
enum Pull { NONE, LOOSE, GOOD, TIGHT }

# -- pack ---------------------------------------------------------------------------------------
const WOUND_R := 0.03
const ACCEPT_R := 0.06            # a press this close to the wound centre goes in
const WADS := 8
const WAD_EVERY := 0.3            # seconds between wads while the pad is held on the wound
const BLEED_RISE := 0.055         # per second at difficulty 1, slower as the wound fills
const BLEED_PER_WAD := 0.1
const GUSH_BOTCH := 3.0
const MISS_BOTCH := 1.2
const HEART_HZ := 1.25
const MAX_MISSES := 5
const PATCH_Y := 0.021            # the drape and skin window sit this far above the site plane

# -- wrap ---------------------------------------------------------------------------------------
const R_IN := 0.03                # closer to the centre than this is not wrapping
const R_LOOSE := 0.075            # pulled out less than this: loose
const R_TIGHT := 0.165            # pulled out more than this: too tight (narrower later)
const LOOSE_GAIN := 0.55
const TIGHT_TIME := 1.0           # seconds of continuous over-tight pulling before it botches
const TIGHT_BOTCH := 4.0
const TIGHT_REPEAT := 1.5
const UNWIND_BOTCH := 2.0
const SLIP_BOTCH := 2.0
const SOAK_BOTCH := 2.0
const SEG := PI * 0.5             # one tension mark per quarter turn of gauze
const TRAIL_LIFE := 0.8

var variant := "pack"
var stage: int = Stage.PACK
var packed: int = 0               # wads in the wound
var bleed: float = 0.45           # 0..1
var wrapped: float = 0.0          # radians wound in the chosen direction
var wrap_dir: int = 0             # +1 / -1 once chosen
var pull: int = Pull.NONE         # how hard the roll is pulled right now
var marks := ""                   # tension of each quarter turn laid down: g / l / t
var tight: float = 0.0            # 0..1 blanching under an over-tight wrap
var cursor := Vector2(0.13, 0.1)
var pressing := false
var gushes := 0
var slips := 0
var misses: Array = []            # where wads landed on the skin (plane metres), last MAX_MISSES

var turns_needed := 3.0
var r_tight := R_TIGHT
var diff := 1.0
var site_name := "gunshot"
var limb_hu := 0.05               # limb section half height / half width at the cut, and its axis depth
var limb_hs := 0.05
var limb_axis_y := -0.05

var _prev_primary := false
var _hold_t := 0.0
var _t := 0.0
var _prev_angle := 0.0
var _prev_valid := false
var _dir_accum := 0.0
var _unwind := 0.0
var _soak := 0.0
var _jolt_t := 0.0
var _miss_cd := 0.0
var _slip_cd := 0.0
var _tight_hold := 0.0
var tq_x := -0.06                 # stump: the tourniquet's distal edge along the limb (plane X)

# visuals
var _built := false
var _cloth: StandardMaterial3D
var _rolls: Node3D
var _roll_count := -1
var _blood: MeshInstance3D
var _blood_mat: StandardMaterial3D
var _dome: MeshInstance3D
var _glow: MeshInstance3D
var _glow_mat: StandardMaterial3D
var _wads: Array[MeshInstance3D] = []
var _wad_mat: StandardMaterial3D
var _miss_nodes: Array[MeshInstance3D] = []
var _pad: Node3D
var _gush: CPUParticles3D
var _ribbon: MeshInstance3D
var _ribbon_key := ""
var _feed: Node3D
var _feed_spin := 0.0
var _strip: MeshInstance3D
var _strip_mesh: ImmediateMesh
var _strip_mat: StandardMaterial3D
var _trail: MeshInstance3D
var _trail_mesh: ImmediateMesh
var _trail_pts: Array = []        # [{p: Vector2, t: float, c: Color}]
var _path: MeshInstance3D
var _path_mat: StandardMaterial3D
var _blanch: Decal
var _blanch_ring: MeshInstance3D
var _blanch_mat: StandardMaterial3D
var _root: Node3D                 # everything we draw; raised over the gown for the pack variant
var _cap: MeshInstance3D
var _cap_mat: StandardMaterial3D
var _press_anim := 0.0
var _vis_pull := 0.0              # -1 loose .. 0 good .. 1 tight, smoothed for the strip
var _roll_pos := Vector3.ZERO

# sounds / effects, from the replicated state so spectators get the same
var _seen := {}
var _creak_t := 0.0
var _swish_at := 0.0

# bot
var _bt := 0.0
var _bot_angle := 0.0
var _bot_wrap_t := -1.0

static var _tex := {}


func setup(context: Dictionary) -> void:
	super.setup(context)
	variant = String(ctx.get("variant", "pack"))
	if variant == "":
		variant = "pack"
	diff = maxf(0.5, float(ctx.get("difficulty", 1.0)))
	site_name = String(ctx.get("step", {}).get("site", "limb_cut" if variant == "stump" else "gunshot"))
	var r := float(ctx.get("patient", {}).get("limb_radius_m", 0.05))
	limb_hu = r
	limb_hs = r
	limb_axis_y = -r
	_probe_limb()
	var flags: Dictionary = ctx.get("flags", {})
	r_tight = maxf(R_LOOSE + 0.06, R_TIGHT - 0.04 * (diff - 1.0))
	if variant == "stump":
		stage = Stage.WRAP
		turns_needed = ceilf(4.0 * sqrt(diff))
		# A weak tourniquet leaves the stump bleeding.
		var tq = flags.get("tourniquet", 1.0)
		var tqf := (1.0 if tq else 0.0) if tq is bool else float(tq)
		bleed = clampf(0.85 - 0.75 * tqf, 0.1, 0.8)
	else:
		stage = Stage.PACK
		turns_needed = ceilf(3.0 * sqrt(diff))
		bleed = 0.45 if flags.get("bullet_removed", true) else 0.65
	_build()
	_update_visuals(0.0)


## Wrap a stump around the real limb section at the site (PatientBody.site_section).
func _probe_limb() -> void:
	var body = ctx.get("body")
	if variant != "stump" or body == null or not is_instance_valid(body) or not body.has_method("site_section"):
		return
	var sec: Dictionary = body.site_section(site_name)
	if sec.is_empty():
		return
	limb_hs = clampf(float(sec.half_side), 0.01, 0.3)
	# Some sections report a sliver of a height (Bob's forearm: 7 mm up, 64 mm across); a wrap
	# round that would sink into the arm, so never go flatter than half the width.
	limb_hu = clampf(maxf(float(sec.half_up), limb_hs * 0.75), 0.01, 0.3)
	limb_axis_y = -maxf(float(sec.get("axis_depth", limb_hu)), limb_hu)
	if body.has_method("has_site") and body.has_site("limb") and is_inside_tree():
		var lx: Vector3 = body.site_transform("limb").origin
		tq_x = clampf((global_transform.affine_inverse() * lx).x + 0.024, -0.09, -0.02)


func plane_extent() -> Vector2:
	return Vector2(0.28, 0.21)


func camera_pose() -> Dictionary:
	return {"height": 0.42, "back": 0.14, "fov": 55.0}


func wrap_frac() -> float:
	return clampf(wrapped / (turns_needed * TAU), 0.0, 1.0)


func pull_at(p: Vector2) -> int:
	var r := p.length()
	if r < R_IN:
		return Pull.NONE
	if r < R_LOOSE:
		return Pull.LOOSE
	if r > r_tight:
		return Pull.TIGHT
	return Pull.GOOD


# ---------------------------------------------------------------------------- rules

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	var primary := (buttons & BUTTON_PRIMARY) != 0
	cursor = p
	pressing = primary
	_miss_cd = maxf(0.0, _miss_cd - delta)
	_slip_cd = maxf(0.0, _slip_cd - delta)
	_jolt_t = maxf(0.0, _jolt_t - delta)
	match stage:
		Stage.PACK:
			_pack(p, primary, delta)
		Stage.WRAP:
			_wrap(p, primary, delta)
	_prev_primary = primary
	_update_progress()


func _pack(p: Vector2, primary: bool, delta: float) -> void:
	bleed += BLEED_RISE * diff * delta * (1.0 - 0.08 * float(packed))
	var on := p.length() <= ACCEPT_R
	if primary and not _prev_primary:
		_hold_t = 0.0
		if on:
			_add_wad()
		elif _miss_cd <= 0.0:
			# The wad lands on the skin next to the wound, and stays there.
			misses.append(p)
			if misses.size() > MAX_MISSES:
				misses.pop_front()
			bleed += 0.03
			_miss_cd = 0.35
			botch(MISS_BOTCH, "Packed gauze onto the skin, not into the wound")
	elif primary and on:
		_hold_t += delta
		if _hold_t >= WAD_EVERY:
			_hold_t -= WAD_EVERY
			_add_wad()
	if bleed >= 1.0:
		gushes += 1
		bleed = 0.7
		botch(GUSH_BOTCH, "The wound gushed: pack it faster")
	if packed >= WADS:
		stage = Stage.WRAP
		bleed = minf(bleed, 0.2)
		_prev_valid = false


func _add_wad() -> void:
	if packed >= WADS:
		return
	packed += 1
	bleed = maxf(0.0, bleed - BLEED_PER_WAD)
	_press_anim = 1.0


## A sudden jerk (the patient stirring) yanks a bandage that is being wound.
func on_jolt(_offset: Vector2, _strength: float, duration: float) -> void:
	_jolt_t = duration
	if stage != Stage.WRAP or not pressing or wrapped <= 0.0:
		return
	wrapped = maxf(0.0, wrapped - 0.8)
	_trim_marks()
	if _slip_cd <= 0.0:
		slips += 1
		_slip_cd = 0.8
		botch(SLIP_BOTCH, "The patient jerked and the wrap slipped")


func _wrap(p: Vector2, primary: bool, delta: float) -> void:
	var r := p.length()
	if not primary or r < R_IN:
		_prev_valid = false
		pull = Pull.NONE
		tight = maxf(0.0, tight - delta * 0.8)
		return
	pull = pull_at(p)
	# Pulling far too hard strangles the skin, whether or not the roll is moving.
	# The skin blanches over TIGHT_TIME; fully white botches, and again every TIGHT_REPEAT.
	if pull == Pull.TIGHT and wrapped > 0.3:
		tight = minf(1.0, tight + delta / TIGHT_TIME)
		if tight >= 1.0:
			_tight_hold -= delta
			if _tight_hold <= 0.0:
				_tight_hold = TIGHT_REPEAT
				botch(TIGHT_BOTCH, "Too tight: the skin under the wrap went white")
	else:
		tight = maxf(0.0, tight - delta * 0.7)
		if tight < 0.5:
			_tight_hold = 0.0
	var a := atan2(p.y, p.x)
	if not _prev_valid:
		_prev_valid = true
		_prev_angle = a
		return
	# While the framework shakes the cursor after a jolt, the shake is not winding.
	if _jolt_t > 0.0:
		_prev_angle = a
		return
	var da := wrapf(a - _prev_angle, -PI, PI)
	_prev_angle = a
	if absf(da) > 1.4:
		return
	if wrap_dir == 0:
		_dir_accum += da
		if absf(_dir_accum) > 0.35:
			wrap_dir = 1 if _dir_accum > 0.0 else -1
		return
	var fwd := da * float(wrap_dir)
	if fwd < -0.002:
		# Unwinding: the last turns peel back off.
		wrapped = maxf(0.0, wrapped + fwd)
		_trim_marks()
		_unwind += -fwd
		if _unwind > 2.4:
			_unwind = 0.0
			botch(UNWIND_BOTCH, "Wrong way: the bandage is unwinding")
		return
	_unwind = maxf(0.0, _unwind - fwd * 0.5)
	var gain := fwd * (LOOSE_GAIN if pull == Pull.LOOSE else 1.0)
	wrapped += gain
	_mark(pull)
	if pull == Pull.LOOSE and bleed > 0.15:
		_soak += gain * bleed
		if _soak >= 0.8:
			_soak = 0.0
			botch(SOAK_BOTCH, "Blood is soaking through the loose wrap")
	if wrap_frac() >= 1.0:
		_complete()


func _mark(state: int) -> void:
	var idx := int(wrapped / SEG)
	var ch := "g"
	if state == Pull.LOOSE:
		ch = "l"
	elif state == Pull.TIGHT:
		ch = "t"
	while marks.length() <= idx:
		marks += ch
	# A quarter keeps the worst tension it saw: tight, then loose, then good.
	var cur := marks.substr(idx, 1)
	if ch == "t" or (ch == "l" and cur == "g"):
		marks = marks.substr(0, idx) + ch + marks.substr(idx + 1)


func _trim_marks() -> void:
	var keep := int(ceil(wrapped / SEG))
	if marks.length() > keep:
		marks = marks.substr(0, keep)


func _update_progress() -> void:
	if stage == Stage.DONE:
		progress = 1.0
	elif variant == "stump":
		progress = wrap_frac()
	else:
		progress = 0.4 * float(packed) / WADS + 0.6 * wrap_frac()


func _complete() -> void:
	stage = Stage.DONE
	pressing = false
	pull = Pull.NONE
	tight = 0.0
	bleed = 0.0
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding"):
		body.set_bleeding(site_name, 0.0)
	_update_progress()
	finish({"dressed": true})


func tick(delta: float) -> void:
	_t += delta
	_press_anim = maxf(0.0, _press_anim - delta * 5.0)
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding") and stage != Stage.DONE:
		body.set_bleeding(site_name, clampf(_shown_bleed(), 0.0, 1.0))
	_update_visuals(delta)
	_effects(delta)


func _shown_bleed() -> float:
	return bleed if stage == Stage.PACK else bleed * (1.0 - wrap_frac())


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Dress the wound"))
	var hint := ""
	match stage:
		Stage.PACK:
			hint = "Press gauze into the wound until it stops bleeding."
		Stage.WRAP:
			if not pressing:
				hint = "Hold left click and circle the roll along the ring."
			elif pull == Pull.TIGHT:
				hint = "Too tight! Bring the roll in closer."
			elif pull == Pull.LOOSE:
				hint = "Too loose. Pull the roll out a little."
			else:
				hint = "Keep circling the same way."
		Stage.DONE:
			hint = "Dressed."
	return {"title": title, "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"s": stage, "pk": packed, "bl": snappedf(bleed, 0.01), "w": snappedf(wrapped, 0.01),
		"d": wrap_dir, "pu": pull, "m": marks, "tg": snappedf(tight, 0.02), "c": cursor, "b": pressing,
		"gu": gushes, "sl": slips, "mi": misses, "p": snappedf(progress, 0.001)}


func apply_net_state(s: Dictionary) -> void:
	stage = int(s.get("s", stage))
	packed = int(s.get("pk", packed))
	bleed = float(s.get("bl", bleed))
	wrapped = float(s.get("w", wrapped))
	wrap_dir = int(s.get("d", wrap_dir))
	pull = int(s.get("pu", pull))
	marks = String(s.get("m", marks))
	tight = float(s.get("tg", tight))
	cursor = s.get("c", cursor)
	pressing = bool(s.get("b", pressing))
	gushes = int(s.get("gu", gushes))
	slips = int(s.get("sl", slips))
	var mi = s.get("mi", misses)
	if mi is Array:
		misses = mi
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := 1.0 - skill
	match stage:
		Stage.PACK:
			if t < 0.4:
				return {"cursor": cursor.lerp(Vector2.ZERO, 0.1), "buttons": 0}
			# A good surgeon holds the pad on the wound; a sloppy one jabs at it with a drifting hand.
			var off := Vector2(sin(t * 1.7) + 0.5 * sin(t * 4.1), cos(t * 1.3) + 0.4 * sin(t * 3.7)) * 0.062 * sloppy
			var c := Vector2(sin(t * 3.0), cos(t * 2.6)) * 0.006 + off
			var down := true
			if sloppy > 0.3:
				down = fmod(t, 0.85) < 0.08
			return {"cursor": c, "buttons": BUTTON_PRIMARY if down else 0}
		Stage.WRAP:
			if _bot_wrap_t < 0.0:
				_bot_wrap_t = t
				_bot_angle = atan2(cursor.y, cursor.x)
			var wt := t - _bot_wrap_t
			var settle_k := clampf(1.0 - wt / 25.0, 0.2, 1.0)
			# Turns per second: steady when good, lurching when sloppy, with a backwards twitch now and then.
			var rate := 0.5 + sloppy * settle_k * (0.35 * sin(wt * 1.4) + 0.15 * sin(wt * 3.3))
			if sloppy > 0.3 and fmod(wt, 4.0) > 3.45 and settle_k > 0.4:
				rate = -0.8
			_bot_angle += rate * TAU * dt
			# How far out the roll is pulled: steady in the middle, or wandering in and out.
			var rr := 0.11 + 0.008 * sin(wt * 0.7)
			rr += sloppy * settle_k * (0.1 * sin(wt * 0.9 + 0.6) + 0.02 * sin(wt * 2.3))
			var bc := Vector2(cos(_bot_angle), sin(_bot_angle)) * rr
			return {"cursor": bc, "buttons": BUTTON_PRIMARY}
	return {"cursor": cursor, "buttons": 0}


## Headless check: plays both variants on both patients at a few skills, with and without stirs,
## and prints time and botches. Run through the lab: `tools/minigame_lab.tscn -- --selftest=gauze`.
static func self_test() -> Array:
	var script: GDScript = load("res://scripts/surgery/games/gauze.gd")
	var out := []
	for v in ["pack", "stump"]:
		for pid in ["bob", "seal"]:
			for cond in [{"skill": 1.0, "sed": 1.0}, {"skill": 0.5, "sed": 1.0}, {"skill": 0.0, "sed": 1.0}, {"skill": 1.0, "sed": 0.4}]:
				var g = script.new()
				var tally := {"n": 0, "v": 0.0, "done": false, "reasons": {}}
				g.botched.connect(func(a, r): tally.n += 1; tally.v += a; tally.reasons[r] = int(tally.reasons.get(r, 0)) + 1)
				g.finished.connect(func(_r): tally.done = true)
				var ail := "amputation" if v == "stump" else "gunshot"
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": ail,
					"step": Procedures.step(ail, 3 if v == "stump" else 2), "variant": v, "shift": 1,
					"difficulty": 1.0, "flags": {"tourniquet": lerpf(0.5, 0.95, float(cond.skill)), "bullet_removed": true, "sedation": cond.sed},
					"seed": hash("gauze" + pid), "body": null, "operator": true})
				var t := _run_bot(g, float(cond.skill), float(cond.sed), hash(pid + v))
				var line := "[gauze self-test] %-5s %-4s skill=%.1f sed=%.1f  %s  time=%5.1fs  botches=%2d vitals=%5.1f  %s" % [
					v, pid, cond.skill, cond.sed, "DONE" if tally.done else "UNFINISHED", t, tally.n, tally.v, str(tally.reasons)]
				print(line)
				out.append({"variant": v, "patient": pid, "skill": cond.skill, "sed": cond.sed, "done": tally.done, "time": t, "vitals": tally.v})
				g.free()
	return out


## Shared by the self-tests: feed bot_input through handle_cursor at 60 Hz, with the surgery
## system's stirs when sedation is under 0.75. Returns the time taken.
static func _run_bot(g, skill: float, sed: float, seed_v: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var t := 0.0
	var dt := 1.0 / 60.0
	var ext: Vector2 = g.plane_extent()
	var next_stir := 2.0
	var jolt_t := 0.0
	var jolt := Vector2.ZERO
	while t < 90.0 and not g.done:
		t += dt
		var inp: Dictionary = g.bot_input(t, skill)
		var c: Vector2 = inp.get("cursor", Vector2.ZERO)
		if sed < 0.75:
			next_stir -= dt
			if next_stir <= 0.0:
				next_stir = lerpf(2.5, 11.0, sed / 0.75) * rng.randf_range(0.7, 1.3)
				var strength := clampf((0.75 - sed) / 0.75, 0.0, 1.0) * 0.8 + 0.2
				jolt = Vector2.RIGHT.rotated(rng.randf() * TAU) * strength * 0.09
				jolt_t = 0.35
				g.on_jolt(jolt, strength, 0.35)
			if jolt_t > 0.0:
				jolt_t -= dt
				c += jolt * (jolt_t / 0.35)
		c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
		g.handle_cursor(c, int(inp.get("buttons", 0)), dt)
		g.apply_net_state(g.net_state())
	return t


# ---------------------------------------------------------------------------- visuals

func _mat(col: Color, rough := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


func _unshaded(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _mesh_node(mesh: Mesh, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else _root).add_child(mi)
	return mi


## A flat sheet with a round window: outer half sizes ax x az, window radius `hole` (0 = none).
func _drape_mesh(hole: float, ax: float, az: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 32
	for i in segs:
		var a0 := TAU * float(i) / segs
		var a1 := TAU * float(i + 1) / segs
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		# Outer points on the rectangle, along the same rays.
		var o0 := d0 * minf(ax / maxf(absf(d0.x), 1e-4), az / maxf(absf(d0.y), 1e-4))
		var o1 := d1 * minf(ax / maxf(absf(d1.x), 1e-4), az / maxf(absf(d1.y), 1e-4))
		var i0 := d0 * hole
		var i1 := d1 * hole
		st.set_normal(Vector3.UP)
		for v in [i0, o0, o1, i0, o1, i1]:
			st.add_vertex(Vector3(v.x, 0.0, v.y))
	return st.commit()


func _build() -> void:
	if _built:
		return
	_built = true
	_cloth = _mat(Color(0.8, 0.79, 0.74), 1.0)
	_cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	_root = Node3D.new()
	_root.name = "Work"
	add_child(_root)

	_rolls = Node3D.new()
	_rolls.name = "Rolls"
	_rolls.position = Vector3(-0.2, 0.0, -0.13)
	_root.add_child(_rolls)
	_set_rolls(maxi(1, int(ctx.get("step", {}).get("uses", 1))))

	if variant == "pack":
		# A sterile drape with a window of skin round the wound, raised over the gown's folds
		# (they stand up to 2 cm off the site). White gauze and red blood read on the blue.
		_root.position = Vector3(0, PATCH_Y, 0)
		_mesh_node(_drape_mesh(0.07, 0.34, 0.26), _mat(Color(0.16, 0.42, 0.5), 0.9))
		var skin := CylinderMesh.new()
		skin.top_radius = 0.075
		skin.bottom_radius = 0.075
		skin.height = 0.002
		skin.radial_segments = 32
		var seal := String(ctx.get("patient_id", "bob")) == "seal"
		_mesh_node(skin, _mat(Color(0.2, 0.22, 0.25) if seal else Color(0.5, 0.35, 0.27), 0.6)).position = Vector3(0, -0.001, 0)
		# Skin blanching round a dressing that is too tight.
		var ring := TorusMesh.new()
		ring.inner_radius = 0.55
		ring.outer_radius = 1.0
		ring.rings = 36
		ring.ring_segments = 4
		_blanch_mat = _unshaded(Color(0.97, 0.95, 0.93, 0.0))
		_blanch_ring = _mesh_node(ring, _blanch_mat)
		_blanch_ring.scale = Vector3(0.075, 0.002, 0.075)
		_blanch_ring.position = Vector3(0, 0.0005, 0)
	else:
		# Skin blanching above a stump wrapped too tight: a pale decal on the limb itself.
		_blanch = Decal.new()
		_blanch.texture_albedo = _texture("blanch_band")
		_blanch.cull_mask = 1
		_blanch.upper_fade = 0.05
		_blanch.lower_fade = 0.3
		_blanch.normal_fade = 0.0
		_blanch.size = Vector3(0.11, limb_hu * 3.0 + 0.06, limb_hs * 2.0 + 0.08)
		_blanch.position = Vector3(tq_x - 0.085, limb_axis_y + limb_hu * 0.5, 0)
		_blanch.modulate = Color(1, 1, 1, 0)
		add_child(_blanch)
		# A drape flat on the table past the cut, so the roll and its trail read against it.
		var body = ctx.get("body")
		if body != null and is_instance_valid(body) and is_inside_tree():
			var drape := _mesh_node(_drape_mesh(0.0, 0.2, 0.2), _mat(Color(0.16, 0.42, 0.5), 0.9))
			drape.top_level = true
			var at: Vector3 = global_transform * Vector3(0.17, 0, 0)
			var dx: Vector3 = global_transform.basis.x
			at.y = (body as Node3D).global_position.y + 0.004
			drape.global_transform = Transform3D(Basis(Vector3.UP, atan2(-dx.z, dx.x)), at)

	if variant == "pack":
		_blood_mat = _mat(Color(0.45, 0.02, 0.03, 0.9), 0.12)
		_blood_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_blood_mat.metallic_specular = 0.9
		var bc := CylinderMesh.new()
		bc.top_radius = 1.0
		bc.bottom_radius = 1.0
		bc.height = 1.0
		bc.radial_segments = 28
		_blood = _mesh_node(bc, _blood_mat)
		var hole := CylinderMesh.new()
		hole.top_radius = 0.012
		hole.bottom_radius = 0.012
		hole.height = 0.002
		_mesh_node(hole, _mat(Color(0.12, 0.0, 0.01), 0.3)).position = Vector3(0, 0.0045, 0)
		# The blood welling up out of the hole with every heartbeat.
		var dm := SphereMesh.new()
		dm.radius = 1.0
		dm.height = 1.0
		dm.radial_segments = 14
		dm.rings = 7
		_dome = _mesh_node(dm, _blood_mat)
		# A soft glow round the wound: brighter when the pad is over it.
		var tm := TorusMesh.new()
		tm.inner_radius = 0.78
		tm.outer_radius = 1.0
		tm.rings = 40
		tm.ring_segments = 6
		_glow_mat = _unshaded(Color(1.0, 0.95, 0.85, 0.0))
		_glow = _mesh_node(tm, _glow_mat)
		# Gauze wads stuffed into the wound, one per press.
		var rng := RandomNumberGenerator.new()
		rng.seed = int(ctx.get("seed", 7))
		_wad_mat = _mat(Color(0.85, 0.55, 0.55), 1.0)
		var sm := SphereMesh.new()
		sm.radius = 0.015
		sm.height = 0.015
		sm.radial_segments = 10
		sm.rings = 5
		for i in WADS:
			var w := _mesh_node(sm, _wad_mat)
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * WOUND_R * 0.6
			w.position = Vector3(cos(a) * rr, 0.004 + i * 0.0009, sin(a) * rr)
			w.rotation = Vector3(rng.randf(), rng.randf() * TAU, rng.randf())
			w.scale = Vector3(1.0, 0.55, 0.8) * rng.randf_range(0.85, 1.15)
			w.visible = false
			_wads.append(w)
		var soiled := _mat(Color(0.8, 0.45, 0.45), 1.0)
		for i in MAX_MISSES:
			var w := _mesh_node(sm, soiled)
			w.scale = Vector3(1.1, 0.4, 0.9)
			w.rotation = Vector3(0.3, i * 1.3, 0.2)
			w.visible = false
			_miss_nodes.append(w)
		# The pad in the surgeon's fingers.
		_pad = Node3D.new()
		_root.add_child(_pad)
		var pb := BoxMesh.new()
		pb.size = Vector3(0.032, 0.008, 0.026)
		_mesh_node(pb, _cloth, _pad)
		var fb := BoxMesh.new()
		fb.size = Vector3(0.028, 0.005, 0.022)
		var fold := _mesh_node(fb, _mat(Color(0.9, 0.9, 0.86), 1.0), _pad)
		fold.position = Vector3(0.002, 0.006, -0.001)
		fold.rotation_degrees = Vector3(0, 12, 4)
		# A gush of blood when the pool gets too big.
		_gush = CPUParticles3D.new()
		var gm := SphereMesh.new()
		gm.radius = 0.004
		gm.height = 0.008
		gm.radial_segments = 5
		gm.rings = 3
		_gush.mesh = gm
		_gush.material_override = _mat(Color(0.4, 0.0, 0.02), 0.2)
		_gush.amount = 40
		_gush.lifetime = 0.8
		_gush.one_shot = true
		_gush.explosiveness = 0.9
		_gush.emitting = false
		_gush.direction = Vector3.UP
		_gush.spread = 40.0
		_gush.initial_velocity_min = 0.5
		_gush.initial_velocity_max = 1.2
		_gush.gravity = Vector3(0, -5.0, 0)
		_gush.position = Vector3(0, 0.01, 0)
		_root.add_child(_gush)

	var ribbon_mat := _cloth.duplicate() as StandardMaterial3D
	ribbon_mat.vertex_color_use_as_albedo = true
	_ribbon = _mesh_node(null, ribbon_mat)
	_ribbon.name = "Dressing"

	if variant == "stump":
		# Gauze folded over the cut end, growing with every turn.
		var cm := SphereMesh.new()
		cm.radius = 1.0
		cm.height = 2.0
		cm.radial_segments = 20
		cm.rings = 10
		_cap_mat = _cloth.duplicate() as StandardMaterial3D
		_cap = _mesh_node(cm, _cap_mat)
		_cap.visible = false

	# The live strip from the dressing to the roll.
	_strip_mesh = ImmediateMesh.new()
	_strip_mat = _cloth.duplicate() as StandardMaterial3D
	_strip_mat.vertex_color_use_as_albedo = true
	_strip = _mesh_node(_strip_mesh, _strip_mat)

	_feed = Node3D.new()
	var roll: Node3D = ItemModelsScript.make("gauze", 1)
	roll.position = Vector3(0, -0.032, 0)
	_feed.add_child(roll)
	_feed.scale = Vector3.ONE * 0.55
	_root.add_child(_feed)

	# The trail the roll leaves, coloured by the tension: green good, amber loose, red tight.
	_trail_mesh = ImmediateMesh.new()
	_trail = _mesh_node(_trail_mesh, _unshaded(Color.WHITE))
	# A faint ring where the roll does the most good: circle along it. Not a band to match, just
	# a path; it glows green while the pull is right and fades while the trail says otherwise.
	var path_ring := TorusMesh.new()
	path_ring.inner_radius = 0.975
	path_ring.outer_radius = 1.0
	path_ring.rings = 64
	path_ring.ring_segments = 4
	_path_mat = _unshaded(Color(1, 1, 1, 0.0))
	_path = _mesh_node(path_ring, _path_mat)
	var pr := (R_LOOSE + r_tight) * 0.5
	_path.scale = Vector3(pr, 0.02, pr)
	_path.position = Vector3(0, 0.044, 0)
	_path.visible = false
	_set_layers(self)
	if _blanch_ring != null:
		_blanch_ring.visible = false
	_draw_trail()
	_draw_strip(Vector3(0, 0.01, 0), Vector3(0.001, 0.01, 0.0), 0.0)


## Props go on the minigame's own layer so the patient's blood decals never paint them.
func _set_layers(n: Node) -> void:
	if n is GeometryInstance3D and not (n is Decal):
		(n as VisualInstance3D).layers = OWN_LAYER
	for c in n.get_children():
		_set_layers(c)


func _set_rolls(n: int) -> void:
	if n == _roll_count:
		return
	_roll_count = n
	for c in _rolls.get_children():
		c.queue_free()
	if n > 0:
		var m: Node3D = ItemModelsScript.make("gauze", n)
		_rolls.add_child(m)
		_set_layers(m)


## Point on the dressing at angle theta (radians wound), the band's normal and its width axis.
## `bulge` pushes it out (a loose turn sits baggy).
func _wrap_point(theta: float, bulge := 0.0) -> Array:
	var turns := theta / TAU
	if variant == "stump":
		# A helix around the limb, whose axis runs along plane X under the surface.
		# Winds from up the arm toward the cut end (+X is distal), a layer thicker each turn.
		var pad := 0.008 + 0.002 * turns + bulge
		# From just below the tourniquet out over the cut end, back and forth once per turn.
		var x0 := clampf(tq_x + 0.012, -0.03, -0.012)
		var x1 := 0.014
		var sweep := 0.5 - 0.5 * cos(turns * PI)
		var x := lerpf(x0, x1, sweep)
		var n := Vector3(0, cos(theta), sin(theta))
		var pt := Vector3(x, limb_axis_y + (limb_hu * 1.08 + pad) * cos(theta), (limb_hs * 1.08 + pad) * sin(theta))
		return [pt, n, Vector3(1, 0, 0)]
	# A flat spiral dressing growing out from the wound.
	var r := 0.014 + turns * 0.021
	var h := 0.009 + turns * 0.0035 + bulge
	var radial := Vector3(cos(theta), 0, sin(theta))
	return [Vector3(0, h, 0) + radial * r, Vector3.UP, radial]


func _mark_at(theta: float) -> String:
	var i := int(theta / SEG)
	return marks.substr(i, 1) if i >= 0 and i < marks.length() else "g"


func _rebuild_ribbon() -> void:
	var key := "%.2f|%s|%.1f" % [wrapped, marks, bleed]
	if key == _ribbon_key:
		return
	_ribbon_key = key
	if wrapped <= 0.02:
		_ribbon.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var width := 0.028 if variant == "stump" else 0.016
	var steps := maxi(2, int(wrapped / 0.1))
	var prev: Array = []
	var prev_cols: Array = []
	for i in steps + 1:
		var th := wrapped * float(i) / steps
		var mk := _mark_at(minf(th, wrapped - 0.001))
		var bulge := 0.0
		var w := width
		var mid := Color(1, 1, 1)
		var edge := Color(0.5, 0.49, 0.45)
		if mk == "l":
			# Baggy, wrinkled and grey; bleeding soaks red through it.
			bulge = 0.004 + 0.003 * sin(th * 7.0)
			w = width * 1.2
			mid = Color(0.82, 0.8, 0.74).lerp(Color(0.62, 0.08, 0.08), clampf(bleed * 1.4, 0.0, 0.8))
			edge = mid.darkened(0.2)
		elif mk == "t":
			# Stretched thin, cutting in: pink edges.
			bulge = -0.002
			w = width * 0.7
			edge = Color(0.95, 0.55, 0.55)
		var wp := _wrap_point(th, bulge)
		var side: Vector3 = wp[2] * (w * 0.5)
		var n: Vector3 = wp[1]
		var a: Vector3 = wp[0] - side
		var m: Vector3 = wp[0] + n * 0.0015
		var b: Vector3 = wp[0] + side
		if not prev.is_empty():
			var pe: Color = prev_cols[0]
			var pm: Color = prev_cols[1]
			for tri in [[prev[0], pe, prev[1], pm, m, mid], [prev[0], pe, m, mid, a, edge],
					[prev[1], pm, prev[2], pe, b, edge], [prev[1], pm, b, edge, m, mid]]:
				for k in 3:
					st.set_color(tri[k * 2 + 1])
					st.set_normal(n)
					st.add_vertex(tri[k * 2])
		prev = [a, m, b]
		prev_cols = [edge, mid]
	_ribbon.mesh = st.commit()


func _update_visuals(delta: float) -> void:
	if not _built:
		return
	var shown := _shown_bleed()
	if variant == "pack":
		var beat := fmod(_t * HEART_HZ, 1.0)
		var pulse := exp(-beat * 6.0)
		var br := 0.02 + 0.055 * clampf(shown, 0.0, 1.0)
		_blood.scale = Vector3(br, 0.002, br * 0.85)
		_blood.position = Vector3(0, 0.002, 0.003)
		_blood.visible = stage != Stage.DONE or shown > 0.01
		_blood_mat.albedo_color = Color(0.42 + 0.3 * clampf(shown, 0.0, 1.0), 0.02, 0.03, 0.9)
		# Welling blood: tall, throbbing spurts when it bleeds hard, a flat film once packed.
		var well := clampf(shown, 0.0, 1.0) * (1.0 - 0.09 * float(packed))
		var dh := maxf(0.001, (0.004 + 0.022 * well) * (0.45 + 0.55 * pulse))
		var dr := 0.012 + 0.012 * well
		_dome.scale = Vector3(dr, dh, dr)
		_dome.position = Vector3(0, 0.004, 0)
		_dome.visible = stage == Stage.PACK and well > 0.05
		var n := packed
		for i in _wads.size():
			_wads[i].visible = i < n
		# Wads soak red while it bleeds, whiten as it stops.
		_wad_mat.albedo_color = Color(0.93, 0.9, 0.86).lerp(Color(0.62, 0.08, 0.08), clampf(shown * 1.4, 0.0, 0.9))
		for i in _miss_nodes.size():
			var mn := _miss_nodes[i]
			mn.visible = i < misses.size() and stage != Stage.DONE
			if mn.visible:
				mn.position = plane_to_local(misses[i], 0.006)
		_pad.visible = stage == Stage.PACK
		var over := cursor.length() <= ACCEPT_R
		var lift := 0.035
		if pressing:
			lift = 0.012 if over else 0.008
		lift = lerpf(lift, 0.006, _press_anim)
		_pad.position = _pad.position.lerp(plane_to_local(cursor, lift), 1.0 if delta <= 0.0 else clampf(delta * 20.0, 0.0, 1.0))
		_pad.rotation = Vector3(0.0, 0.3, (-0.25 if over and not pressing else 0.0))
		_glow.visible = stage == Stage.PACK
		var ga := 0.18 + 0.1 * pulse
		if over:
			ga = 0.55 + 0.25 * pulse
		_glow_mat.albedo_color = Color(1.0, 0.82, 0.3, ga)
		var gr := ACCEPT_R * 0.95
		_glow.scale = Vector3(gr, 0.01, gr)
		_glow.position = Vector3(0, 0.03, 0)
	_rebuild_ribbon()
	if _cap != null:
		var f := wrap_frac()
		_cap.visible = wrapped > PI
		var pad := 0.008 + 0.006 * f
		_cap.scale = Vector3(0.008 + 0.018 * f, limb_hu * 1.08 + pad, limb_hs * 1.08 + pad)
		_cap.position = Vector3(0.008, limb_axis_y, 0.0)
		var loose_share := float(marks.count("l")) / maxf(1.0, float(marks.length()))
		_cap_mat.albedo_color = Color(0.94, 0.92, 0.85).lerp(Color(0.6, 0.1, 0.09), clampf(bleed * loose_share * 2.0, 0.0, 0.75))

	# Tension, smoothed for the strip.
	var target_pull := 0.0
	if pull == Pull.LOOSE:
		target_pull = -1.0
	elif pull == Pull.TIGHT:
		target_pull = 1.0
	_vis_pull = move_toward(_vis_pull, target_pull, maxf(delta, 0.0) * 6.0) if delta > 0.0 else target_pull
	var blanch_a := clampf(tight * 1.1, 0.0, 0.9) if stage == Stage.WRAP else 0.0
	if _blanch != null:
		_blanch.modulate = Color(1, 1, 1, blanch_a)
		_blanch.visible = blanch_a > 0.01
	if _blanch_ring != null:
		_blanch_mat.albedo_color = Color(0.97, 0.95, 0.93, blanch_a)
		_blanch_ring.visible = blanch_a > 0.01
		var rr := 0.03 + wrapped / TAU * 0.021 + 0.03
		_blanch_ring.scale = Vector3(rr, 0.002, rr)

	var wrapping := stage == Stage.WRAP
	_feed.visible = wrapping
	_strip.visible = wrapping and wrapped > 0.05
	if wrapping:
		var end: Array = _wrap_point(maxf(wrapped, 0.001))
		var end_p: Vector3 = end[0]
		var target: Vector3
		var ang := atan2(cursor.y, cursor.x)
		if variant == "stump" and pressing and cursor.length() >= R_IN:
			# The roll goes round the limb with the winding; how far out it rides shows the pull.
			var th := wrapped
			var out := 0.03 + 0.02 * clampf(-_vis_pull, 0.0, 1.0) - 0.012 * clampf(_vis_pull, 0.0, 1.0)
			out += 0.006 * sin(_t * 17.0) * clampf(-_vis_pull, 0.0, 1.0)
			target = Vector3(end_p.x + 0.02, limb_axis_y + (limb_hu + out) * cos(th), (limb_hs + out) * sin(th))
		elif variant == "stump":
			target = plane_to_local(cursor, 0.06)
		else:
			target = plane_to_local(cursor, 0.04)
		var k := 1.0 if delta <= 0.0 else clampf(delta * 16.0, 0.0, 1.0)
		_roll_pos = _roll_pos.lerp(target, k)
		_feed.position = _roll_pos
		_feed_spin += maxf(delta, 0.0) * (6.0 if pressing else 0.0)
		# The roll's axis lies across the strip it pays out, and it spins as it feeds.
		var yaw := 0.0
		if variant == "pack":
			var d := end_p - _roll_pos
			yaw = atan2(-d.x, -d.z) if Vector2(d.x, d.z).length() > 0.005 else -ang
		_feed.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, _feed_spin)
		if _strip.visible:
			_draw_strip(end_p, _roll_pos, _vis_pull)
	if variant == "stump" and stage != Stage.DONE:
		_set_rolls(1 if wrap_frac() >= 0.5 else maxi(1, int(ctx.get("step", {}).get("uses", 2))))
	elif stage == Stage.DONE and variant == "stump":
		_set_rolls(0)

	# The path ring.
	_path.visible = wrapping
	if wrapping:
		var pa := 0.22 + 0.12 * sin(_t * 4.0)
		var pc := Color(1, 1, 1)
		if pressing and pull == Pull.GOOD:
			pc = Color(0.2, 1.0, 0.4)
			pa = 0.5
		elif pressing and pull != Pull.NONE:
			pa = 0.3
		_path_mat.albedo_color = Color(pc.r, pc.g, pc.b, pa)

	# The trail.
	if wrapping and pressing and cursor.length() >= R_IN:
		var col := Color(0.1, 0.95, 0.3)
		if pull == Pull.LOOSE:
			col = Color(1.0, 0.7, 0.0)
		elif pull == Pull.TIGHT:
			col = Color(1.0, 0.12, 0.08)
		if _trail_pts.is_empty() or (_trail_pts[-1].p as Vector2).distance_to(cursor) > 0.004:
			_trail_pts.append({"p": cursor, "t": _t, "c": col})
	while not _trail_pts.is_empty() and _t - float(_trail_pts[0].t) > TRAIL_LIFE:
		_trail_pts.pop_front()
	if _trail_pts.size() > 60:
		_trail_pts = _trail_pts.slice(_trail_pts.size() - 60)
	_draw_trail()


## The strip between the dressing and the roll: sagging and flapping when loose, a straight taut
## band when good, thin and pink when too tight.
func _draw_strip(a: Vector3, b: Vector3, tension: float) -> void:
	_strip_mesh.clear_surfaces()
	var loose := clampf(-tension, 0.0, 1.0)
	var taut := clampf(tension, 0.0, 1.0)
	var width := 0.02 * (1.0 + 0.2 * loose - 0.45 * taut)
	var col := Color(1, 1, 1).lerp(Color(0.8, 0.78, 0.72), loose).lerp(Color(1.0, 0.62, 0.6), taut)
	var dir := b - a
	if dir.length() < 0.002:
		dir = Vector3(0.002, 0, 0)
	var side := dir.normalized().cross(Vector3.UP)
	if side.length() < 0.01:
		side = Vector3(0, 0, 1)
	side = side.normalized()
	# Three columns (edge, middle, edge) so the darker edges outline it against a white gown.
	var edge := col.darkened(0.35)
	_strip_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 14
	var prev: Array = []
	for i in segs + 1:
		var f := float(i) / segs
		var p := a.lerp(b, f)
		var bow := 4.0 * f * (1.0 - f)
		p.y -= bow * 0.035 * loose
		p += side * bow * loose * 0.016 * sin(_t * 19.0 + f * 7.0)
		p.y += bow * taut * 0.0015 * sin(_t * 70.0)
		var row := [p - side * width * 0.5, p + Vector3(0, 0.001, 0), p + side * width * 0.5]
		if not prev.is_empty():
			for c in 2:
				var ca: Color = edge if c == 0 else col
				var cb: Color = col if c == 0 else edge
				for v in [[prev[c], ca], [row[c + 1], cb], [prev[c + 1], cb], [prev[c], ca], [row[c], ca], [row[c + 1], cb]]:
					_strip_mesh.surface_set_color(v[1])
					_strip_mesh.surface_set_normal(Vector3.UP)
					_strip_mesh.surface_add_vertex(v[0])
		prev = row
	_strip_mesh.surface_end()


func _draw_trail() -> void:
	_trail_mesh.clear_surfaces()
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := 0.045
	var n := _trail_pts.size()
	if n < 2:
		# An invisible sliver keeps the material drawn (and compiled) from the first frame.
		for v in [Vector3(0, -0.05, 0), Vector3(0.0001, -0.05, 0), Vector3(0, -0.05, 0.0001)]:
			_trail_mesh.surface_set_color(Color(1, 1, 1, 0))
			_trail_mesh.surface_add_vertex(v)
	else:
		for i in n - 1:
			var p0: Vector2 = _trail_pts[i].p
			var p1: Vector2 = _trail_pts[i + 1].p
			var d := p1 - p0
			if d.length() < 1e-5:
				continue
			var nrm := Vector2(-d.y, d.x).normalized()
			var age0 := clampf(1.0 - (_t - float(_trail_pts[i].t)) / TRAIL_LIFE, 0.0, 1.0)
			var age1 := clampf(1.0 - (_t - float(_trail_pts[i + 1].t)) / TRAIL_LIFE, 0.0, 1.0)
			var w0 := 0.002 + 0.006 * age0
			var w1 := 0.002 + 0.006 * age1
			var c0: Color = _trail_pts[i].c
			var c1: Color = _trail_pts[i + 1].c
			c0.a = minf(1.0, 1.3 * age0)
			c1.a = minf(1.0, 1.3 * age1)
			var q := [plane_to_local(p0 - nrm * w0, lift), plane_to_local(p0 + nrm * w0, lift),
				plane_to_local(p1 + nrm * w1, lift), plane_to_local(p1 - nrm * w1, lift)]
			for idx in [0, 1, 2, 0, 2, 3]:
				_trail_mesh.surface_set_color(c0 if idx < 2 else c1)
				_trail_mesh.surface_add_vertex(q[idx])
	_trail_mesh.surface_end()


func _effects(delta: float) -> void:
	var at = global_position if is_inside_tree() else null
	if _seen.is_empty():
		_seen = {"stage": stage, "packed": packed, "gushes": gushes, "slips": slips, "misses_arr": misses.duplicate()}
		if stage == Stage.WRAP:
			_audio("surgery_tear", at, -3.0, 0.05)
		return
	if stage != int(_seen.stage):
		_audio("surgery_tear", at, -3.0, 0.05)
		if stage == Stage.DONE:
			_audio("surgery_done", at, -4.0)
		_trail_pts.clear()
	if packed > int(_seen.packed):
		_audio("surgery_pack", at, -2.0, 0.08)
	if gushes > int(_seen.gushes) and _gush != null:
		_gush.restart()
		_audio("surgery_saw_squelch", at, -1.0, 0.05)
	if slips > int(_seen.slips):
		_audio("surgery_tear", at, 0.0, 0.1)
	if misses != _seen.misses_arr:
		_audio("surgery_pack", at, -8.0, 0.25)
	_seen = {"stage": stage, "packed": packed, "gushes": gushes, "slips": slips, "misses_arr": misses.duplicate()}

	if stage == Stage.WRAP:
		if wrapped > _swish_at + PI * 0.5:
			_swish_at = wrapped
			if pull == Pull.LOOSE:
				_audio("surgery_swish", at, -9.0, 0.25)
			else:
				_audio("surgery_swish", at, -6.0, 0.1)
		elif wrapped < _swish_at - PI:
			_swish_at = wrapped
		_creak_t -= delta
		if pull == Pull.TIGHT and pressing and _creak_t <= 0.0:
			_creak_t = 0.45
			_audio("surgery_tourniquet_creak", at, -6.0 + 4.0 * tight, 0.1)


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var ml = Engine.get_main_loop()
	var a = ml.root.get_node_or_null("Audio") if ml is SceneTree else null
	if a != null:
		a.play(cue, at, vol, jitter)


# ---------------------------------------------------------------------------- textures

static func _texture(key: String) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var a := 0.0
			if key == "blanch_ring":
				# Pale skin in a ring just outside the dressing.
				var r := sqrt(u * u + v * v)
				a = smoothstep(0.25, 0.45, r) * (1.0 - smoothstep(0.7, 1.0, r))
			else:
				# A band across the limb (decal X is along the limb), fading at its ends.
				a = (1.0 - smoothstep(0.5, 1.0, absf(u))) * (1.0 - smoothstep(0.8, 1.0, absf(v)))
			img.set_pixel(x, y, Color(0.98, 0.96, 0.95, a))
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t
