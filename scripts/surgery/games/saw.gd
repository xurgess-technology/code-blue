extends "res://scripts/surgery/minigame.gd"
## Step "cut" (amputation 3): saw through the limb with the bone saw.
##
## Frame: the plane is the `limb_cut` site. Local X runs along the limb (toward the hand /
## flipper tip), +Y out of the skin, Z across the limb. The marked cut line runs along Z at
## x = 0 and the saw lies along it, so the operator strokes the cursor along Z (screen
## up/down) while holding primary.
##
## Rules
##   - A "stroke" is one push plus one pull. Every pass (half stroke) between two turn-arounds
##     is judged on its own: LENGTH (blade travel, full credit from GOOD_LEN), TEMPO (strokes
##     per second vs TEMPO_TARGET, inside a band that narrows with difficulty and in bone) and
##     STEADINESS (sudden tempo change from the previous pass).
##   - Each pass advances the depth by k / layer_resistance * (FLOOR + (1 - FLOOR) * good) *
##     (1 - 0.7 * off_line). Short, rushed or erratic passes still cut a little (no softlock)
##     but add tearing.
##   - OFF LINE: the blade follows the cursor across the line with lag. Beyond LINE_TOL from
##     the marked line it cuts slower, scores the skin beside the kerf, makes the kerf jagged
##     and botches at a rate.
##   - LAYERS: skin (fast) -> muscle -> bone (slow, tighter tempo band, grinding, bone dust)
##     -> far soft tissue. Total passes scale with limb_radius_m and difficulty.
##   - TOURNIQUET (ctx.flags.tourniquet, missing = 0.5): a weak one makes every pass spurt,
##     splatter the work area, pool blood over the cut line and drip off the saw, and a
##     heavy flow botches a little. A strong one gives a clean, dark cut.
##   - At depth 1 the limb comes off: body.apply_flags(flags + amputated), a thunk, and
##     finish({"amputated": true, "cut_quality": q}); q falls with tearing and off-line cutting.

const ItemModelsScript := preload("res://scripts/item_models.gd")

const TEMPO_TARGET := 1.55        # strokes (push + pull) per second
const TEMPO_BAND := 0.25          # half width of the good band at difficulty 1
const BONE_BAND_K := 0.7          # the band is this much narrower in bone
const GOOD_LEN := 0.19            # metres of blade travel per pass for full credit (half the blade)
const MIN_LEN := 0.05             # passes shorter than this cut almost nothing
const TURN_HYST := 0.018          # the blade must come back this far to count a turn-around
const IGNORE_LEN := 0.03          # a "pass" shorter than this is jitter or a jolt, ignored
const STALL_TIME := 1.5           # a pass slower than this is not a stroke
const LINE_TOL := 0.008           # metres off the marked line before it counts
const LINE_SPAN := 0.025          # metres beyond the tolerance to be fully off the line
const K_BASE := 0.034             # depth per perfect pass at resistance 1, Bob, difficulty 1
const FLOOR := 0.45               # fraction of a pass's cut you get even when it is awful (0.25 made a sloppy saw take a minute)
const OFF_BOTCH_RATE := 0.2      # botch units per second fully off the line while sawing
const TEAR_BOTCH_RATE := 0.083   # botch units per fully torn pass, times the layer factor (scaled with FLOOR so a sloppy cut costs the same)
const BLEED_BOTCH_RATE := 0.05    # botch units per unit of spurt
const OFF_BOTCH := 2.0
const TEAR_BOTCH := 1.5
const BLEED_BOTCH := 1.0
const SAW_LAYER := OWN_LAYER      # visual layer for the saw so blood decals do not paint it

## name, depth fraction where the layer ends, resistance, tearing factor, bleed factor, colour
const LAYERS := [
	{"name": "Skin", "to": 0.08, "res": 0.45, "tear": 0.35, "bleed": 0.3, "col": Color(0.86, 0.6, 0.42)},
	{"name": "Muscle", "to": 0.36, "res": 1.0, "tear": 0.7, "bleed": 1.0, "col": Color(0.6, 0.06, 0.06)},
	{"name": "Bone", "to": 0.64, "res": 2.4, "tear": 1.35, "bleed": 0.55, "col": Color(0.82, 0.76, 0.62)},
	{"name": "Far side", "to": 1.0, "res": 0.9, "tear": 0.7, "bleed": 1.0, "col": Color(0.55, 0.05, 0.06)},
]
const MAX_SPLATS := 28
const MAX_SCORES := 10

# -- tuning from ctx -----------------------------------------------------------------------------
var diff := 1.0
var limb_r := 0.05
var hu := 0.05                    # limb section half height and half width at the cut (probed)
var hs := 0.05
var k_cut := K_BASE
var tourniquet := 0.5
var bleed := 0.5                  # 0 clean .. 1 pouring, from the tourniquet
var line_tol := LINE_TOL
var distal := 1.0
var size_k := 1.0                 # botch rates per pass shrink for thick limbs so the total stays fair

# -- shared state (the operator simulates it, spectators get it from net_state) -------------------
var bz := 0.0                     # blade centre along the cut line (plane Z)
var bx := 0.0                     # blade offset across the line (plane X)
var depth := 0.0                  # 0..1 through the limb
var blood := 0.0                  # 0..1 pooled blood
var kx := 0.0                     # where the kerf actually runs
var jag := 0.0                    # 0..1 how ragged the kerf is
var held := false
var strokes := 0                  # passes that counted
var splats := 0
var scores := 0
var tear := 0.0                   # 0..1 current tearing (gauge)
var tempo := 0.0                  # last measured strokes per second (gauge)
var verdict := ""                 # last pass: good / short / fast / slow / erratic / off

# -- operator simulation --------------------------------------------------------------------------
var _t := 0.0
var _bv := 0.0
var _dir := 0
var _seg_start := 0.0
var _seg_t := 0.0
var _ext := 0.0
var _ext_t := 0.0
var _first_seg := true
var _prev_tempo := -1.0
var _seg_off := 0.0
var _seg_time := 0.0
var _seg_bx := 0.0
var _off_now := 0.0
var _off_acc := 0.0
var _tear_acc := 0.0
var _bleed_acc := 0.0
var _adv_total := 0.0
var _sum_tear := 0.0
var _sum_off := 0.0
var _n_judged := 0
var _last_stroke_t := -10.0
var _rng := RandomNumberGenerator.new()

# -- visuals --------------------------------------------------------------------------------------
var _built := false
var _saw: Node3D
var _saw_model: Node3D
var _metro_mat: StandardMaterial3D
var _metro_light: OmniLight3D
var _drips: Array[MeshInstance3D] = []
var _smear: MeshInstance3D
var _smear_mat: StandardMaterial3D
var _marker: Decal
var _guides: Array[Decal] = []
var _bruise: Decal
var _opening: Decal
var _jagged: Decal
var _tissue: Decal
var _kerf_blood: Decal
var _pool: Decal
var _dust_decal: Decal
var _splat_decals: Array[Decal] = []
var _splat_born: Array[float] = []
var _score_decals: Array[Decal] = []
var _dust: CPUParticles3D
var _spurt: CPUParticles3D
var _vis_bz := 0.0
var _vis_bx := 0.0
var _vis_lift := 0.02
var _seen_strokes := 0
var _seen_splats := 0
var _seen_scores := 0
var _finale := false
var _metro_t := 0.0
var _severed: Node3D

# -- bot ------------------------------------------------------------------------------------------
var _bt := -1.0
var _bphase := 0.0

static var _tex := {}


func setup(context: Dictionary) -> void:
	super.setup(context)
	diff = maxf(0.5, float(ctx.get("difficulty", 1.0)))
	limb_r = float(ctx.get("patient", {}).get("limb_radius_m", 0.05))
	hu = limb_r
	hs = limb_r
	_probe_limb()
	var flags: Dictionary = ctx.get("flags", {})
	var tq = flags.get("tourniquet", 0.5)
	tourniquet = (1.0 if tq else 0.0) if tq is bool else clampf(float(tq), 0.0, 1.0)
	bleed = clampf((0.85 - tourniquet) / 0.6, 0.0, 1.0)
	k_cut = K_BASE * pow(0.05 / maxf(0.02, limb_r), 1.1) / pow(diff, 0.8)
	line_tol = LINE_TOL / sqrt(diff)
	size_k = 0.05 / maxf(0.02, limb_r)
	_rng.seed = int(ctx.get("seed", 1)) ^ 0x5a3
	_update_progress()


## The limb section at the cut, from PatientBody.site_section.
func _probe_limb() -> void:
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or not body.has_method("site_section"):
		return
	var sec: Dictionary = body.site_section(String(ctx.get("step", {}).get("site", "limb_cut")))
	if sec.is_empty():
		return
	hu = clampf(float(sec.half_up), 0.01, 0.3)
	hs = clampf(float(sec.half_side), 0.01, 0.3)


func plane_extent() -> Vector2:
	return Vector2(0.07, 0.16)


func camera_pose() -> Dictionary:
	return {"height": 0.45, "back": 0.1, "fov": 58.0}


func layer_index(f: float = -1.0) -> int:
	if f < 0.0:
		f = depth
	for i in LAYERS.size():
		if f < float(LAYERS[i].to):
			return i
	return LAYERS.size() - 1


func tempo_band(li: int = -1) -> float:
	if li < 0:
		li = layer_index()
	return TEMPO_BAND / sqrt(diff) * (BONE_BAND_K if LAYERS[li].name == "Bone" else 1.0)


func _update_progress() -> void:
	progress = clampf(depth, 0.0, 1.0)


# ---------------------------------------------------------------------------- simulation

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	delta = clampf(delta, 0.0, 0.1)
	_t += delta
	var primary := (buttons & BUTTON_PRIMARY) != 0
	# The blade is heavy: a damped spring along the line, a slower follow across it.
	var w := 22.0
	_bv += ((p.y - bz) * w * w - _bv * 2.0 * 0.8 * w) * delta
	bz += _bv * delta
	bx += (p.x - bx) * (1.0 - exp(-10.0 * delta))

	if primary and not held:
		_dir = 0
		_first_seg = true
		_seg_start = bz
		_seg_t = _t
		_ext = bz
		_ext_t = _t
		_seg_reset_acc()
	held = primary
	tear = maxf(0.0, tear - delta * 0.3)
	if _t - _last_stroke_t > 0.9:
		tempo = move_toward(tempo, 0.0, delta * 2.0)
	if not held:
		_off_now = 0.0
		return

	var moving := absf(_bv) > 0.05
	_off_now = clampf((absf(bx) - line_tol) / LINE_SPAN, 0.0, 1.0)
	if moving:
		_seg_off += _off_now * delta
		_seg_time += delta
		_seg_bx += bx * delta
		_off_acc += _off_now * delta * OFF_BOTCH_RATE * size_k
		if _off_acc >= 1.0:
			_off_acc -= 1.0
			botch(OFF_BOTCH, "The saw wandered off the line")

	# Turn-around detection with hysteresis, so jolts and jitter are not strokes.
	if _dir == 0:
		if absf(bz - _seg_start) > TURN_HYST:
			_dir = 1 if bz > _seg_start else -1
			_ext = bz
			_ext_t = _t
	elif (_dir > 0 and bz > _ext) or (_dir < 0 and bz < _ext):
		_ext = bz
		_ext_t = _t
	elif absf(_ext - bz) > TURN_HYST:
		var length := absf(_ext - _seg_start)
		var dur := _ext_t - _seg_t
		if not _first_seg and length >= IGNORE_LEN and dur > 0.04 and dur < STALL_TIME:
			_judge_pass(length, dur)
		_first_seg = false
		_seg_start = _ext
		_seg_t = _ext_t
		_dir = -_dir
		_ext = bz
		_ext_t = _t
		_seg_reset_acc()
	if _dir != 0 and _t - _ext_t > STALL_TIME:
		# Stopped mid-stroke: start over from here.
		_dir = 0
		_first_seg = true
		_seg_start = bz
		_seg_t = _t
		_seg_reset_acc()


func _seg_reset_acc() -> void:
	_seg_off = 0.0
	_seg_time = 0.0
	_seg_bx = 0.0


func _judge_pass(length: float, dur: float) -> void:
	var li := layer_index()
	var layer: Dictionary = LAYERS[li]
	var t_now := 0.5 / dur
	var band := tempo_band(li)
	var dev := absf(t_now - TEMPO_TARGET)
	var tempo_q := 1.0 if dev <= band else clampf(1.0 - (dev - band) / (band * 2.0), 0.0, 1.0)
	var erratic := 0.0
	if _prev_tempo > 0.0:
		erratic = clampf((absf(log(t_now / _prev_tempo)) - 0.22) / 0.4, 0.0, 1.0)
		tempo_q *= 1.0 - erratic * (0.75 if layer.name == "Bone" else 0.4)
	_prev_tempo = t_now
	tempo = t_now
	_last_stroke_t = _t
	var len_q := clampf((length - MIN_LEN) / (GOOD_LEN - MIN_LEN), 0.0, 1.0)
	var off := _seg_off / _seg_time if _seg_time > 0.0 else _off_now
	var seg_bx := _seg_bx / _seg_time if _seg_time > 0.0 else bx
	var good := len_q * tempo_q

	var adv := k_cut / float(layer.res) * (FLOOR + (1.0 - FLOOR) * good) * (1.0 - 0.7 * off)
	depth = minf(1.0, depth + adv)
	strokes += 1

	# Kerf record: where the metal went and how ragged it is.
	var badness := clampf(1.0 - good + erratic * 0.3, 0.0, 1.0)
	var rag := clampf(absf(seg_bx - kx) / 0.02 + off * 0.8 + badness * 0.5, 0.0, 1.0)
	kx = (kx * _adv_total + seg_bx * adv) / (_adv_total + adv)
	jag = (jag * _adv_total + rag * adv) / (_adv_total + adv)
	_adv_total += adv
	if off > 0.35:
		scores += 1

	tear = minf(1.0, tear + badness * 0.4)
	_sum_tear += badness
	_sum_off += off
	_n_judged += 1
	_tear_acc += badness * badness * float(layer.tear) * TEAR_BOTCH_RATE * size_k
	if _tear_acc >= 1.0:
		_tear_acc -= 1.0
		botch(TEAR_BOTCH, "Tearing through the %s" % String(layer.name).to_lower())

	if length < MIN_LEN + 0.04:
		verdict = "short"
	elif off > 0.35:
		verdict = "off"
	elif erratic > 0.5:
		verdict = "erratic"
	elif t_now > TEMPO_TARGET + band:
		verdict = "fast"
	elif t_now < TEMPO_TARGET - band:
		verdict = "slow"
	else:
		verdict = "good"

	# Bleeding: the weaker the tourniquet, the more every pass spurts.
	if depth > float(LAYERS[0].to) * 0.5:
		var spurt := bleed * float(layer.bleed) * (0.6 + 0.4 * badness)
		blood = minf(1.0, blood + spurt * 0.03)
		if spurt > 0.2:
			splats += 1 + (1 if spurt > 0.6 and _rng.randf() < 0.5 else 0)
		_bleed_acc += spurt * BLEED_BOTCH_RATE * size_k
		if _bleed_acc >= 1.0:
			_bleed_acc -= 1.0
			botch(BLEED_BOTCH, "Blood is pouring out of the cut")

	_update_progress()
	if depth >= 1.0:
		var body = ctx.get("body")
		_amputate_body(body)
		finish({"amputated": true, "cut_quality": cut_quality()})


func cut_quality() -> float:
	if _n_judged == 0:
		return 1.0
	var mt := _sum_tear / float(_n_judged)
	var mo := _sum_off / float(_n_judged)
	return snappedf(clampf(1.0 - 0.5 * mt - 0.6 * mo, 0.05, 1.0), 0.01)


func _amputate_body(body) -> void:
	if body == null or not is_instance_valid(body) or not body.has_method("apply_flags"):
		return
	# apply_flags replaces the body's flag set, so carry the earlier results (the tourniquet).
	var f: Dictionary = (ctx.get("flags", {}) as Dictionary).duplicate()
	f["amputated"] = true
	body.apply_flags(f)


# ---------------------------------------------------------------------------- per frame

func tick(delta: float) -> void:
	if not _built and is_inside_tree():
		_build()
	if not _built:
		return
	_metro_t += delta
	_update_visuals(delta)


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var li := layer_index()
	var layer: Dictionary = LAYERS[li]
	var title := String(ctx.get("step", {}).get("label", "Saw through the limb"))
	var hint := ""
	if done or depth >= 1.0:
		hint = "It's off."
	elif not held:
		hint = "Hold left click and saw back and forth along the marked line."
	elif _off_now > 0.35:
		hint = "You're off the line! Steer back onto the marks."
	else:
		match verdict:
			"short": hint = "Longer strokes. Use the whole blade."
			"fast": hint = "Too fast, you're tearing. Match the ticking light."
			"slow": hint = "Too slow. Keep up with the ticking light."
			"erratic": hint = "Keep the rhythm even."
			_:
				match String(layer.name):
					"Skin": hint = "Long, even strokes on the line. Match the ticking light on the handle."
					"Muscle": hint = "Through the muscle. Keep the length and the rhythm."
					"Bone": hint = "Bone. Slow and steady, don't rush it."
					_: hint = "Almost through. Keep it straight, don't tear the far side."
	var band := tempo_band(li)
	var gauges := [
		{"label": "Tempo", "value": tempo, "min": 0.0, "max": 3.2, "good_min": TEMPO_TARGET - band, "good_max": TEMPO_TARGET + band},
		{"label": "Off line (cm)", "value": absf(bx) * 100.0, "min": 0.0, "max": 4.0, "good_min": 0.0, "good_max": line_tol * 100.0},
		{"label": "Tearing", "value": tear, "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 0.35},
	]
	# Depth through the layers is drawn by the surgery HUD's cross-section strip.
	var xs := []
	var from := 0.0
	for l in LAYERS:
		xs.append({"name": l.name, "from": from, "to": l.to, "color": l.col})
		from = l.to
	return {"title": title, "hint": hint, "progress": progress, "gauges": gauges,
		"cross_section": {"layers": xs, "depth": depth, "layer": li}}


func net_state() -> Dictionary:
	return {"z": snappedf(bz, 0.0005), "x": snappedf(bx, 0.0005), "d": snappedf(depth, 0.001),
		"b": snappedf(blood, 0.005), "k": snappedf(kx, 0.0005), "j": snappedf(jag, 0.01), "h": held,
		"g": strokes, "n": splats, "c": scores, "t": snappedf(tear, 0.01), "tp": snappedf(tempo, 0.01)}


func apply_net_state(s: Dictionary) -> void:
	bz = float(s.get("z", bz))
	bx = float(s.get("x", bx))
	depth = float(s.get("d", depth))
	blood = float(s.get("b", blood))
	kx = float(s.get("k", kx))
	jag = float(s.get("j", jag))
	held = bool(s.get("h", held))
	strokes = int(s.get("g", strokes))
	splats = int(s.get("n", splats))
	scores = int(s.get("c", scores))
	tear = float(s.get("t", tear))
	tempo = float(s.get("tp", tempo))
	_update_progress()


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1) if _bt >= 0.0 else 0.0
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sl := 1.0 - skill
	if t < 0.25:
		return {"cursor": Vector2(0.0, 0.0), "buttons": 0}
	# Strokes per second: on tempo when competent, rushing and lurching when sloppy.
	var f := TEMPO_TARGET + sl * (0.85 + 0.55 * sin(t * 0.9) + 0.35 * sin(t * 2.3 + 0.7))
	_bphase += f * dt
	var amp := 0.118 - sl * (0.045 + 0.03 * sin(t * 1.3 + 1.0))
	var z := amp * sin(TAU * _bphase)
	var x := sl * (0.03 * sin(t * 0.7 + 0.4) + 0.012 * sin(t * 2.9)) + 0.0015 * sin(t * 5.3)
	return {"cursor": Vector2(x, z), "buttons": BUTTON_PRIMARY}


## Headless check: plays the bot through the simulation (no scene tree) for 20 cases and
## prints strokes, time, botches and quality. Run from a throwaway SceneTree script:
##   load("res://scripts/surgery/games/saw.gd").self_test()
static func self_test() -> Array:
	var script: GDScript = load("res://scripts/surgery/games/saw.gd")
	var out := []
	for cond in [{"tq": 0.95, "sed": 1.0}, {"tq": 0.3, "sed": 0.6}]:
		for pid in ["bob", "seal"]:
			for skill in [1.0, 0.75, 0.5, 0.25, 0.0]:
				var g = script.new()
				var tally := {"n": 0, "v": 0.0, "done": false, "q": 0.0}
				g.botched.connect(func(a, _r): tally.n += 1; tally.v += a)
				g.finished.connect(func(r): tally.done = true; tally.q = float(r.get("cut_quality", 0.0)))
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": "amputation",
					"step": Procedures.step("amputation", 2), "variant": "", "shift": 1,
					"difficulty": Procedures.difficulty(1), "flags": {"tourniquet": cond.tq, "sedation": cond.sed},
					"seed": hash("saw" + pid), "body": null, "operator": true})
				var rng := RandomNumberGenerator.new()
				rng.seed = hash(pid) + int(skill * 100)
				var t := 0.0
				var dt := 1.0 / 60.0
				var jolt := Vector2.ZERO
				var next_jolt := rng.randf_range(1.5, 4.0)
				var ext: Vector2 = g.plane_extent()
				while t < 120.0 and not tally.done:
					t += dt
					var inp: Dictionary = g.bot_input(t, skill)
					# Mimic the framework's sedation jolts below 0.75.
					if cond.sed < 0.75:
						next_jolt -= dt
						if next_jolt <= 0.0:
							next_jolt = rng.randf_range(2.0, 4.5)
							jolt = Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * rng.randf_range(0.03, 0.06) * (0.75 - cond.sed) / 0.15
						jolt *= exp(-dt * 6.0)
					var c: Vector2 = inp.cursor + jolt
					c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
					g.handle_cursor(c, int(inp.buttons), dt)
				var line := "[saw self-test] %-4s skill=%.2f tq=%.2f sed=%.1f  %s  strokes=%3d (passes %3d)  time=%5.1fs  botches=%2d vitals=%5.1f  q=%.2f" % [
					pid, skill, cond.tq, cond.sed, "DONE" if tally.done else "UNFINISHED", g.strokes / 2, g.strokes, t, tally.n, tally.v, tally.q]
				print(line)
				out.append({"patient": pid, "skill": skill, "tq": cond.tq, "done": tally.done, "time": t, "botches": tally.n, "vitals": tally.v, "q": tally.q})
				g.free()
	return out


# ---------------------------------------------------------------------------- visuals

func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _decal(tex: Texture2D, size: Vector3, pos: Vector3, sort := 0) -> Decal:
	var d := Decal.new()
	d.texture_albedo = tex
	d.size = size
	d.position = pos
	d.upper_fade = 0.05
	d.lower_fade = 0.1
	d.normal_fade = 0.0
	d.cull_mask = 1
	d.sorting_offset = float(sort)
	add_child(d)
	return d


func _build() -> void:
	_built = true
	var body = ctx.get("body")
	var proj_h := hu * 2.0 + 0.06
	var proj_y := -hu + 0.03
	_marker = _decal(_texture("marker"), Vector3(0.006, proj_h, hs * 3.0 + 0.04), Vector3(0, proj_y, 0), 1)
	# Two fainter guide lines either side, so the line still reads while the blade sits on it.
	for side in [-1.0, 1.0]:
		_guides.append(_decal(_texture("marker"), Vector3(0.005, proj_h, hs * 2.6 + 0.03), Vector3(side * 0.03, proj_y, 0), 1))
	_bruise = _decal(_texture("bruise"), Vector3(0.05, proj_h, 0.05), Vector3(0, proj_y, 0), 2)
	_dust_decal = _decal(_texture("dust"), Vector3(0.08, proj_h, 0.1), Vector3(0, proj_y, 0), 3)
	_opening = _decal(_texture("slit"), Vector3(0.02, proj_h, 0.05), Vector3(0, proj_y, 0), 4)
	_jagged = _decal(_texture("slit_jag"), Vector3(0.03, proj_h, 0.05), Vector3(0, proj_y, 0), 5)
	_tissue = _decal(_texture("tissue"), Vector3(0.01, proj_h, 0.05), Vector3(0, proj_y, 0), 6)
	_kerf_blood = _decal(_texture("kerf_blood"), Vector3(0.02, proj_h, 0.05), Vector3(0, proj_y, 0), 7)
	_pool = _decal(_texture("splat0"), Vector3(0.05, proj_h + 0.1, 0.05), Vector3(0, proj_y - 0.05, 0), 8)
	for n in [_bruise, _dust_decal, _opening, _jagged, _tissue, _kerf_blood, _pool]:
		(n as Decal).visible = false
	for i in MAX_SPLATS:
		var d := _decal(_texture("splat%d" % (i % 3)), Vector3(0.05, 0.4, 0.05), Vector3.ZERO, 9)
		d.visible = false
		_splat_decals.append(d)
		_splat_born.append(-10.0)
	for i in MAX_SCORES:
		var d := _decal(_texture("score"), Vector3(0.006, proj_h, 0.1), Vector3.ZERO, 3)
		d.visible = false
		_score_decals.append(d)

	# The saw: the item model on its side, teeth down along the cut line, handle toward the operator.
	_saw = Node3D.new()
	_saw.name = "Saw"
	add_child(_saw)
	_saw_model = ItemModelsScript.make("bone_saw")
	var tilt := Basis(Vector3(0, 0, 1), deg_to_rad(-8.0))
	var basis := tilt * Basis(Vector3.UP, PI * 0.5) * Basis(Vector3.RIGHT, PI * 0.5)
	_saw_model.transform = Transform3D(basis, -(basis * Vector3(0.07, 0.012, 0.044)))
	_saw.add_child(_saw_model)
	# Metronome on the grip: a small lamp that pulses at the target tempo.
	var lamp := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.008
	sm.height = 0.016
	lamp.mesh = sm
	_metro_mat = _mat(Color(0.2, 1.0, 0.35), 0.3)
	_metro_mat.emission_enabled = true
	_metro_mat.emission = Color(0.2, 1.0, 0.35)
	lamp.material_override = _metro_mat
	lamp.position = Vector3(-0.15, 0.036, 0.0)
	_saw_model.add_child(lamp)
	_metro_light = OmniLight3D.new()
	_metro_light.light_color = Color(0.3, 1.0, 0.4)
	_metro_light.omni_range = 0.14
	_metro_light.light_energy = 0.0
	_metro_light.position = Vector3(-0.15, 0.05, 0.0)
	_saw_model.add_child(_metro_light)
	# Blood on the blade: a smear along the teeth and drops hanging off it.
	_smear_mat = _mat(Color(0.32, 0.0, 0.01, 0.0), 0.15)
	_smear_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_smear = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.3, 0.0055, 0.03)
	_smear.mesh = bm
	_smear.material_override = _smear_mat
	_smear.position = Vector3(0.09, 0.012, 0.024)
	_saw_model.add_child(_smear)
	var drop_mat := _mat(Color(0.3, 0.0, 0.01), 0.1)
	for i in 6:
		var d := MeshInstance3D.new()
		var ds := SphereMesh.new()
		ds.radius = 0.0035
		ds.height = 0.012
		d.mesh = ds
		d.material_override = drop_mat
		d.visible = false
		_saw_model.add_child(d)
		_drips.append(d)
	_dull_steel(_saw_model)
	_set_layers(_saw, SAW_LAYER)

	_dust = _particles(Color(0.95, 0.92, 0.82), 0.0025, 26, 0.9)
	_dust.direction = Vector3(0, 1, 0)
	_dust.spread = 70.0
	_dust.initial_velocity_min = 0.15
	_dust.initial_velocity_max = 0.45
	_dust.gravity = Vector3(0, -1.2, 0)
	_spurt = _particles(Color(0.45, 0.0, 0.02), 0.004, 34, 0.7)
	_spurt.direction = Vector3(0, 1, 0)
	_spurt.spread = 35.0
	_spurt.initial_velocity_min = 0.5
	_spurt.initial_velocity_max = 1.3
	_spurt.gravity = Vector3(0, -6.0, 0)

	_vis_bz = bz
	_vis_bx = bx
	_seen_strokes = strokes
	_seen_splats = splats
	_seen_scores = scores
	# Distal direction for the severed part: the body's own site frame knows.
	if body != null and is_instance_valid(body) and body.has_method("site_transform") and body.has_method("has_site") and body.has_site("limb"):
		var lx: Vector3 = body.site_transform("limb").origin
		distal = 1.0 if (global_transform.affine_inverse() * lx).x < 0.0 else -1.0


func _particles(col: Color, size: float, amount: int, life: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var m := SphereMesh.new()
	m.radius = size
	m.height = size * 2.0
	m.radial_segments = 4
	m.rings = 2
	p.mesh = m
	var mat := _mat(col, 0.3)
	p.material_override = mat
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.85
	p.emitting = false
	p.local_coords = false
	add_child(p)
	p.layers = SAW_LAYER
	return p


func _set_layers(n: Node, mask: int) -> void:
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = mask
	if n is GeometryInstance3D:
		# No shadow: the OR lamp is straight above and the blade's shadow would hide the kerf.
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c, mask)


func _update_visuals(delta: float) -> void:
	var operator := bool(ctx.get("operator", false))
	var k := 1.0 if operator else 1.0 - exp(-18.0 * delta)
	_vis_bz = lerpf(_vis_bz, bz, k)
	_vis_bx = lerpf(_vis_bx, bx, k)
	var f := clampf(depth, 0.0, 1.0)
	var d_m := f * hu * 2.0
	var li := layer_index()
	var body = ctx.get("body")

	# Kerf geometry: the opening spans the section chord at the deepest point cut so far.
	var below := maxf(0.0, hu - d_m) / hu
	var open_half := hs * sqrt(maxf(0.0, 1.0 - below * below)) if f > 0.0 else 0.0
	var width := 0.03 + 0.022 * f + 0.02 * jag
	var shown := f > 0.004 and not _finale
	var len_z := open_half * 2.0 + 0.004
	for dcl in [_bruise, _opening, _jagged, _tissue, _kerf_blood]:
		(dcl as Decal).visible = shown
		(dcl as Decal).position.x = kx
	_bruise.size = Vector3(width * 3.2 + 0.012, _bruise.size.y, len_z * 1.15 + 0.01)
	_bruise.modulate = Color(1, 1, 1, clampf(0.4 + f, 0.0, 0.9))
	_opening.size = Vector3(width, _opening.size.y, len_z)
	_jagged.size = Vector3(width * 1.7, _jagged.size.y, len_z * 1.06)
	_jagged.modulate = Color(1, 1, 1, clampf(jag * 1.8 - 0.1, 0.0, 1.0))
	_tissue.size = Vector3(width * 0.3, _tissue.size.y, len_z * 0.9)
	var tcol: Color = LAYERS[li].col
	_tissue.modulate = Color(tcol.r, tcol.g, tcol.b, 0.8)
	var kb := clampf(0.12 + 0.25 * f + blood * 1.6, 0.0, 1.0)
	if LAYERS[li].name == "Bone":
		kb = minf(kb, 0.35 + blood * 0.4)
	_kerf_blood.size = Vector3(width * 0.8, _kerf_blood.size.y, len_z * 0.95)
	_kerf_blood.modulate = Color(1, 1, 1, kb)
	# Bone dust builds up once the saw reaches bone.
	var bone_from := float(LAYERS[1].to)
	var bone_amt := clampf((f - bone_from) / (float(LAYERS[2].to) - bone_from), 0.0, 1.0)
	_dust_decal.visible = bone_amt > 0.02 and not _finale
	_dust_decal.position.x = kx
	_dust_decal.size = Vector3(width * 1.8, _dust_decal.size.y, len_z + 0.02)
	_dust_decal.modulate = Color(1, 1, 1, clampf(bone_amt * 1.2, 0.0, 0.55) * (1.0 - blood * 0.8) * clampf(1.0 - (f - float(LAYERS[2].to)) / 0.12, 0.0, 1.0))
	# Pooled blood grows over the cut line and hides the marks.
	_pool.visible = blood > 0.02
	var ps := lerpf(0.03, 0.2, sqrt(blood))
	_pool.size = Vector3(ps * 1.3, _pool.size.y, ps)
	_pool.position.x = kx + 0.01 * distal
	_pool.modulate = Color(1, 1, 1, clampf(blood * 2.5, 0.0, 0.95))
	_marker.modulate = Color(1, 1, 1, clampf(1.0 - blood * 1.1, 0.15, 1.0))
	for g in _guides:
		g.modulate = Color(1, 1, 1, clampf(0.75 - blood * 1.1, 0.1, 0.75))

	# Splatter from each spurt, placed from the seed so every machine agrees.
	if splats != _seen_splats:
		for i in range(maxi(_seen_splats, splats - MAX_SPLATS), splats):
			_place_splat(i)
		_seen_splats = splats
		if _built:
			_spurt.position = Vector3(kx, 0.01, _vis_bz * 0.2)
			_spurt.restart()
			_audio("surgery_saw_squelch", global_position, -5.0, 0.1)
	for i in MAX_SPLATS:
		var sd := _splat_decals[i]
		if sd.visible:
			var age := _metro_t - _splat_born[i]
			var grow := clampf(age / 0.12, 0.2, 1.0)
			var base: float = sd.get_meta("s", 0.05)
			sd.size = Vector3(base * grow, sd.size.y, base * grow * float(sd.get_meta("a", 1.0)))
	if scores != _seen_scores:
		for i in range(maxi(_seen_scores, scores - MAX_SCORES), scores):
			var sc := _score_decals[i % MAX_SCORES]
			sc.visible = true
			sc.position = Vector3(_vis_bx + 0.004 * signf(_vis_bx - kx), -hu + 0.03, _rng.randf_range(-0.3, 0.3) * hs)
			sc.size = Vector3(0.006, sc.size.y, hs * _rng.randf_range(0.9, 1.6))
			sc.rotation.y = _rng.randf_range(-0.25, 0.25)
		_seen_scores = scores

	# The saw.
	var lift_target := 0.0 if held else 0.018
	if _finale:
		lift_target = 0.07
	_vis_lift = lerpf(_vis_lift, lift_target, 1.0 - exp(-12.0 * delta))
	var sink := minf(d_m, 0.04)
	_saw.position = Vector3(_vis_bx - sin(deg_to_rad(8.0)) * (0.05 - sink * 0.5), _vis_lift - sink, _vis_bz)
	_saw.rotation.y = clampf((_vis_bx - kx) * 3.0, -0.25, 0.25)
	var ph := fmod(_metro_t * TEMPO_TARGET * 2.0, 2.0)
	var beat := fmod(ph, 1.0) / (TEMPO_TARGET * 2.0)
	var pulse := exp(-beat * 16.0) * (1.0 if ph < 1.0 else 0.55)
	_metro_mat.emission_energy_multiplier = 0.3 + 5.0 * pulse
	_metro_light.light_energy = 1.4 * pulse
	_smear_mat.albedo_color.a = clampf(0.25 * f + blood * 1.5, 0.0, 0.92)
	var nd := int(clampf(blood * 9.0, 0.0, 6.0))
	for i in _drips.size():
		var dr := _drips[i]
		dr.visible = i < nd
		if dr.visible:
			var fall := fmod(_metro_t * (0.7 + 0.13 * i) + i * 0.37, 1.0)
			dr.position = Vector3(-0.08 + i * 0.05, 0.012, 0.045 + fall * 0.018)
			dr.scale = Vector3(1, 1, 1.0 + fall)

	# A new pass: sound, dust in bone.
	if strokes != _seen_strokes:
		_seen_strokes = strokes
		var at := global_position
		if LAYERS[li].name == "Bone":
			_audio("surgery_saw_grind", at, -3.0, 0.08)
			_dust.position = Vector3(kx, 0.004, open_half * (1.0 if strokes % 2 == 0 else -1.0))
			_dust.restart()
		else:
			_audio("surgery_saw_rasp", at, -4.0, 0.1)
			if blood > 0.25 and strokes % 3 == 0:
				_audio("surgery_saw_squelch", at, -9.0, 0.1)

	if body != null and is_instance_valid(body) and body.has_method("set_bleeding") and not _finale:
		body.set_bleeding(String(ctx.get("step", {}).get("site", "limb_cut")), clampf(blood * 1.3 + 0.08 * f * bleed, 0.0, 1.0))

	if depth >= 1.0 and not _finale:
		_start_finale(body)


func _place_splat(i: int) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = hash("%d|splat|%d" % [int(ctx.get("seed", 1)), i])
	var d := _splat_decals[i % MAX_SPLATS]
	var ang := r.randf() * TAU
	var dist := pow(r.randf(), 1.6) * 0.17 + 0.012
	var pos := Vector3(kx + cos(ang) * dist * 0.8, 0.05, sin(ang) * dist)
	d.position = pos
	d.rotation.y = r.randf() * TAU
	var s := r.randf_range(0.02, 0.07) * (1.0 - 0.4 * dist / 0.18) * lerpf(0.6, 1.2, bleed)
	d.set_meta("s", s)
	d.set_meta("a", r.randf_range(0.6, 1.4))
	d.size = Vector3(s * 0.2, 0.5, s * 0.2)
	d.modulate = Color(1, 1, 1, r.randf_range(0.75, 1.0))
	d.visible = true
	_splat_born[i % MAX_SPLATS] = _metro_t


func _start_finale(body) -> void:
	_finale = true
	# A static copy of the limb drops away while the body shows its stump.
	if body != null and is_instance_valid(body) and body.has_method("make_severed_limb"):
		_severed = body.make_severed_limb(self)
	_amputate_body(body)
	var at := global_position
	_audio("surgery_saw_thunk", at, 0.0, 0.03)
	_audio("surgery_saw_squelch", at, -4.0, 0.05)
	_spurt.position = Vector3(kx, 0.0, 0.0)
	_spurt.restart()
	for d in [_marker, _pool] + _guides:
		(d as Decal).visible = false
	if _severed != null:
		var start := _severed.transform
		var tw := create_tween()
		tw.set_parallel(true)
		var end_xf := Transform3D(Basis(Vector3(0, 0, 1), -0.35 * distal) * start.basis, start.origin + Vector3(0.07 * distal, -hu * 0.6, 0.02))
		tw.tween_property(_severed, "transform", end_xf, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var a = Engine.get_main_loop().root.get_node_or_null("Audio") if Engine.get_main_loop() else null
	if a != null:
		a.play(cue, at, vol, jitter)


# ---------------------------------------------------------------------------- textures

static func _hash2(x: float, y: float) -> float:
	var h := sin(x * 127.1 + y * 311.7) * 43758.5453
	return h - floorf(h)


static func _noise1(x: float, seed_v: float) -> float:
	var i := floorf(x)
	var fr := x - i
	var a := _hash2(i, seed_v)
	var b := _hash2(i + 1.0, seed_v)
	var s := fr * fr * (3.0 - 2.0 * fr)
	return lerpf(a, b, s) * 2.0 - 1.0


static func _texture(key: String) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var img: Image
	match key:
		"marker": img = _img_marker()
		"bruise": img = _img_soft(Color(0.45, 0.08, 0.12), 0.7, 1.4)
		"dust": img = _img_dust()
		"slit": img = _img_slit(false)
		"slit_jag": img = _img_slit(true)
		"tissue": img = _img_soft(Color(1, 1, 1), 1.0, 0.6)
		"kerf_blood": img = _img_soft(Color(0.2, 0.0, 0.005), 1.0, 0.35)
		"score": img = _img_score()
		_: img = _img_splat(int(key.trim_prefix("splat")))
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t


## Purple surgical-marker dashes along the image's long axis (decal Z).
static func _img_marker() -> Image:
	var w := 8
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := float(y) / h
		var on := fmod(v * 14.0, 1.0) < 0.62
		var wob := _noise1(v * 40.0, 3.0) * 0.15
		for x in w:
			var u := absf((x + 0.5) / w * 2.0 - 1.0 + wob)
			var a := clampf((1.0 - u) * 2.2, 0.0, 1.0) if on else 0.0
			img.set_pixel(x, y, Color(0.22, 0.06, 0.4, a * 0.95))
	return img


## A soft lens shape, alpha falling to the edges; `power` sharpens it.
static func _img_soft(col: Color, alpha: float, power: float) -> Image:
	var w := 32
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := (y + 0.5) / h * 2.0 - 1.0
		for x in w:
			var u := (x + 0.5) / w * 2.0 - 1.0
			var r := sqrt(u * u + v * v * v * v)
			var a := pow(clampf(1.0 - r, 0.0, 1.0), power) * alpha
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return img


## The cut: pink torn lips, dark red walls, a near-black core. `jagged` tears the edges.
static func _img_slit(jagged: bool) -> Image:
	var w := 48
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := (y + 0.5) / h * 2.0 - 1.0
		var taper := pow(maxf(0.0, 1.0 - v * v), 0.3)
		var e1 := _noise1(y * 0.09, 1.0) * 0.08
		var e2 := _noise1(y * 0.09, 2.0) * 0.08
		if jagged:
			var zig := absf(fmod(y * 0.23, 2.0) - 1.0) * 2.0 - 1.0
			e1 = _noise1(y * 0.21, 5.0) * 0.45 + zig * 0.18
			e2 = _noise1(y * 0.19, 6.0) * 0.45 - zig * 0.18
		for x in w:
			var u := (x + 0.5) / w * 2.0 - 1.0
			var half := taper * (0.78 + (e1 if u < 0.0 else e2))
			var t := absf(u) / maxf(0.01, half)
			var c := Color(0, 0, 0, 0)
			if t <= 1.0:
				if t < 0.4:
					c = Color(0.06, 0.0, 0.0, 1.0)
				elif t < 0.78:
					c = Color(0.06, 0.0, 0.0).lerp(Color(0.5, 0.03, 0.04), (t - 0.4) / 0.38)
				else:
					c = Color(0.5, 0.03, 0.04).lerp(Color(0.78, 0.36, 0.33), (t - 0.78) / 0.22)
				c.a = clampf((1.0 - t) * 12.0, 0.0, 1.0)
			elif jagged and t < 1.9 and _hash2(x * 1.3, y * 0.7) > 0.82 + (t - 1.0) * 0.15:
				c = Color(0.42, 0.02, 0.03, 0.85)
			img.set_pixel(x, y, c)
	return img


static func _img_dust() -> Image:
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var r := sqrt(u * u * 1.4 + v * v)
			var speck := _hash2(float(x), float(y))
			var a := clampf(1.0 - r, 0.0, 1.0)
			a = a * 0.45 + (0.55 if speck > 0.72 else 0.0) * a
			img.set_pixel(x, y, Color(0.96, 0.93, 0.84, a))
	return img


static func _img_score() -> Image:
	var w := 8
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := (y + 0.5) / h * 2.0 - 1.0
		var wob := _noise1(y * 0.15, 9.0) * 0.3
		var fade := clampf((1.0 - absf(v)) * 3.0, 0.0, 1.0)
		for x in w:
			var u := absf((x + 0.5) / w * 2.0 - 1.0 + wob)
			var a := clampf(1.0 - u * 1.3, 0.0, 1.0) * fade * (0.6 + 0.4 * _hash2(float(y), 3.0))
			img.set_pixel(x, y, Color(0.5, 0.02, 0.04, a))
	return img


## Blood splatter: a blob, satellite droplets and a couple of streaks.
static func _img_splat(variant: int) -> Image:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var blobs := []
	var r := RandomNumberGenerator.new()
	r.seed = 9100 + variant
	blobs.append([Vector2(0.5, 0.5), 0.2 + r.randf() * 0.05])
	for i in 5:
		blobs.append([Vector2(0.5, 0.5) + Vector2.from_angle(r.randf() * TAU) * r.randf_range(0.05, 0.14), r.randf_range(0.06, 0.12)])
	for i in 16:
		var ang := r.randf() * TAU
		var dist := r.randf_range(0.22, 0.46)
		blobs.append([Vector2(0.5, 0.5) + Vector2.from_angle(ang) * dist, r.randf_range(0.008, 0.035) * (1.2 - dist)])
	var streaks := []
	for i in 3:
		streaks.append([r.randf() * TAU, r.randf_range(0.28, 0.45)])
	for y in n:
		for x in n:
			var p := Vector2((x + 0.5) / n, (y + 0.5) / n)
			var field := 0.0
			for b in blobs:
				var rr: float = b[1]
				var dd: float = p.distance_to(b[0])
				field = maxf(field, clampf((rr - dd) / 0.012 + 0.5, 0.0, 1.0))
			var off := p - Vector2(0.5, 0.5)
			for s in streaks:
				var dir := Vector2.from_angle(float(s[0]))
				var along := off.dot(dir)
				var across := absf(off.dot(dir.orthogonal()))
				if along > 0.0 and along < float(s[1]):
					var wdt := 0.018 * (1.0 - along / float(s[1]))
					field = maxf(field, clampf((wdt - across) / 0.006 + 0.5, 0.0, 1.0))
			var shade := 0.14 + 0.06 * _hash2(float(x) * 0.1, float(y) * 0.1)
			img.set_pixel(x, y, Color(shade, 0.0, 0.015, field))
	return img


## The shared item materials are mirror steel, which blows out under the OR lamp. Our copy is duller.
func _dull_steel(n: Node) -> void:
	if n is GeometryInstance3D:
		var m := (n as GeometryInstance3D).material_override as StandardMaterial3D
		if m != null and m.metallic > 0.2:
			var d := m.duplicate() as StandardMaterial3D
			d.albedo_color = m.albedo_color * Color(0.55, 0.55, 0.58)
			d.roughness = maxf(m.roughness, 0.45)
			d.metallic = 0.7
			(n as GeometryInstance3D).material_override = d
	for c in n.get_children():
		_dull_steel(c)
