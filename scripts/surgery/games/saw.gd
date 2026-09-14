extends "res://scripts/surgery/minigame.gd"
## Step "cut" (amputation 3): saw through the limb with the bone saw.
##
## Frame: the plane is the `limb_cut` site. Local X runs along the limb (toward the hand /
## flipper tip), +Y out of the skin, Z across the limb. The marked cut line runs along Z at
## x = 0 and the saw lies along it, so the operator strokes the cursor along Z (screen
## up/down) while holding primary.
##
## Everything reads in the world; the HUD needs one short hint and no gauges.
##
## Rules
##   - A PASS is the blade's travel between two turn-arounds. Each one is judged on LENGTH
##     (full credit from GOOD_LEN) and SPEED (blade metres per second). There is no tempo to
##     match: anything from a slow drag to a brisk stroke bites; only rushing is punished.
##   - Each pass advances the depth by k / layer_resistance * (FLOOR + (1 - FLOOR) * length) *
##     (1 - 0.5 * rushed) * (1 - 0.6 * off_line). Short passes still cut a little.
##   - RUSHED: faster than the layer allows (bone allows less) and the saw jumps in the kerf:
##     blood and chips spray, the kerf goes ragged and the guide flashes red; enough of it
##     botches ("The saw jumped and tore the muscle").
##   - OFF LINE: the blade follows the cursor across the line, but once the kerf is started it
##     holds the blade (KERF_GRIP). Beyond the tolerance it scores the skin beside the cut, the
##     guide turns red, and it botches at a rate.
##   - The GUIDE: a glowing line on the limb along the cut, and a glow along the saw's teeth.
##     It flashes green on a good biting pass, amber on a short one, red when rushed or off line.
##   - LAYERS: skin (fast) -> muscle -> bone (slow, grinding, bone dust) -> far soft tissue. The
##     kerf shows the colour of the layer, and the sound changes from a rasp to a grind.
##   - TOURNIQUET (ctx.flags.tourniquet, missing = 0.5): a weak one makes every pass spurt,
##     splatter the work area, pool blood over the cut line and drip off the saw, and a
##     heavy flow botches a little. A strong one gives a clean, dark cut.
##   - At depth 1 the limb comes off: body.apply_flags(flags + amputated), a thunk, and
##     finish({"amputated": true, "cut_quality": q}); q falls with tearing and off-line cutting.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Verdict { NONE, GOOD, SHORT, RUSHED, OFF }

const GOOD_LEN := 0.12            # metres of blade travel per pass for full credit
const MIN_LEN := 0.03             # passes shorter than this cut almost nothing
const TURN_HYST := 0.018          # the blade must come back this far to count a turn-around
const IGNORE_LEN := 0.025         # a "pass" shorter than this is jitter or a jolt, ignored
const STALL_TIME := 2.0           # a pass slower than this is not a stroke
const V_FAST := 0.72              # m/s of blade travel before soft tissue tears
const V_FAST_BONE := 0.56         # and before the teeth skip on bone
const LINE_TOL := 0.012           # metres off the line before it counts
const LINE_SPAN := 0.03           # metres beyond the tolerance to be fully off the line
const KERF_GRIP := 0.65           # once started, how strongly the kerf holds the blade on it
const KERF_FROM := 0.05           # depth at which the kerf starts guiding the blade
const K_BASE := 0.036             # depth per full-length pass at resistance 1, Bob, difficulty 1
const FLOOR := 0.45               # fraction of a pass's cut you get even when it is short
const OFF_BOTCH_RATE := 0.35      # botch units per second fully off the line while sawing
const TEAR_BOTCH_RATE := 0.14     # botch units per fully rushed pass, times the layer factor
const BLEED_BOTCH_RATE := 0.08    # botch units per unit of spurt
const OFF_BOTCH := 2.0
const TEAR_BOTCH := 3.0
const BLEED_BOTCH := 1.0
const SAW_LAYER := OWN_LAYER      # visual layer for the saw so blood decals do not paint it

## name, depth fraction where the layer ends, resistance, tearing factor, bleed factor, colour
const LAYERS := [
	{"name": "Skin", "to": 0.08, "res": 0.45, "tear": 0.5, "bleed": 0.3, "col": Color(0.86, 0.6, 0.42)},
	{"name": "Muscle", "to": 0.36, "res": 1.0, "tear": 0.8, "bleed": 1.0, "col": Color(0.6, 0.06, 0.06)},
	{"name": "Bone", "to": 0.64, "res": 2.2, "tear": 1.2, "bleed": 0.55, "col": Color(0.82, 0.76, 0.62)},
	{"name": "Far side", "to": 1.0, "res": 0.9, "tear": 0.8, "bleed": 1.0, "col": Color(0.55, 0.05, 0.06)},
]
## dissection (sweep 3), variant "skull": saw open a strapped monster's skull along the line across
## its forehead. Same strokes, guide and verdicts as the limb; its own layers, no tourniquet (the
## scalp bleeds a steady SKULL_BLEED), and at depth 1 the flags get `skull_open` instead of
## `amputated` (the body lifts the cap off and lays it beside the head).
const SKULL_LAYERS := [
	{"name": "Scalp", "to": 0.16, "res": 0.5, "tear": 0.5, "bleed": 0.5, "col": Color(0.5, 0.52, 0.42)},
	{"name": "Bone", "to": 0.84, "res": 2.0, "tear": 0.75, "bleed": 0.35, "col": Color(0.86, 0.8, 0.66)},
	{"name": "Dura", "to": 1.0, "res": 0.8, "tear": 0.9, "bleed": 0.8, "col": Color(0.6, 0.28, 0.3)},
]
const SKULL_BLEED := 0.35
const K_SKULL := 0.05
const MAX_SPLATS := 28
const MAX_SCORES := 10
const GUIDE_COLORS := {
	Verdict.NONE: Color(0.75, 0.9, 1.0),
	Verdict.GOOD: Color(0.15, 1.0, 0.35),
	Verdict.SHORT: Color(1.0, 0.72, 0.1),
	Verdict.RUSHED: Color(1.0, 0.12, 0.08),
	Verdict.OFF: Color(1.0, 0.12, 0.08),
}

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
var skull := false                # dissection: the "skull" variant
var layers: Array = LAYERS        # SKULL_LAYERS for the skull
var _bone_i := 2                  # index of the "Bone" layer in `layers`

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
var tear := 0.0                   # 0..1 recent tearing (the kerf's rawness)
var verdict: int = Verdict.NONE   # the last pass, for the guide's colour
var off_now := 0.0                # 0..1 how far off the line the blade is right now

# -- operator simulation --------------------------------------------------------------------------
var _t := 0.0
var _bv := 0.0
var _dir := 0
var _seg_start := 0.0
var _seg_t := 0.0
var _ext := 0.0
var _ext_t := 0.0
var _first_seg := true
var _seg_off := 0.0
var _seg_time := 0.0
var _seg_bx := 0.0
var _off_acc := 0.0
var _tear_acc := 0.0
var _bleed_acc := 0.0
var _adv_total := 0.0
var _sum_tear := 0.0
var _sum_off := 0.0
var _n_judged := 0
var _rng := RandomNumberGenerator.new()

# -- visuals --------------------------------------------------------------------------------------
var _built := false
var _saw: Node3D
var _saw_model: Node3D
var _teeth_mat: StandardMaterial3D
var _drips: Array[MeshInstance3D] = []
var _smear: MeshInstance3D
var _smear_mat: StandardMaterial3D
var _marker: Decal
var _guide: Decal
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
var _chips: CPUParticles3D
var _spurt: CPUParticles3D
var _vis_bz := 0.0
var _vis_bx := 0.0
var _vis_lift := 0.02
var _hop := 0.0
var _flash := 0.0
var _flash_col := Color.WHITE
var _seen_strokes := 0
var _seen_splats := 0
var _seen_scores := 0
var _seen_layer := 0
var _finale := false
var _vt := 0.0
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
	k_cut = K_BASE * pow(0.05 / maxf(0.02, limb_r), 0.75) / pow(diff, 0.8)
	line_tol = LINE_TOL / sqrt(diff)
	size_k = 0.05 / maxf(0.02, limb_r)
	if String(ctx.get("variant", "")) == "skull":
		skull = true
		layers = SKULL_LAYERS
		_bone_i = 1
		tourniquet = 1.0
		bleed = SKULL_BLEED
		k_cut = K_SKULL / pow(diff, 0.8)
		size_k = 1.0
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
	hs = clampf(float(sec.half_side), 0.01, 0.3)
	# Bob's section reports 7 mm up and 64 mm across; the arm is much rounder than that, and a
	# sliver would keep the blade and the kerf from sinking in.
	hu = clampf(maxf(float(sec.half_up), hs * 0.75), 0.01, 0.3)


func plane_extent() -> Vector2:
	return Vector2(0.07, 0.16)


func camera_pose() -> Dictionary:
	return {"height": 0.45, "back": 0.1, "fov": 58.0}


func layer_index(f: float = -1.0) -> int:
	if f < 0.0:
		f = depth
	for i in layers.size():
		if f < float(layers[i].to):
			return i
	return layers.size() - 1


## Blade speed (m/s) above which this layer tears.
func fast_speed(li: int = -1) -> float:
	if li < 0:
		li = layer_index()
	return (V_FAST_BONE if layers[li].name == "Bone" else V_FAST) / sqrt(diff)


func _update_progress() -> void:
	progress = clampf(depth, 0.0, 1.0)


# ---------------------------------------------------------------------------- simulation

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	delta = clampf(delta, 0.0, 0.1)
	_t += delta
	var primary := (buttons & BUTTON_PRIMARY) != 0
	# The blade is heavy: a damped spring along the line, a slower follow across it. Once the
	# kerf is started it holds the blade in it.
	var w := 22.0
	_bv += ((p.y - bz) * w * w - _bv * 2.0 * 0.8 * w) * delta
	bz += _bv * delta
	var want_x := p.x
	if held and depth > KERF_FROM:
		want_x = lerpf(p.x, kx, KERF_GRIP)
	bx += (want_x - bx) * (1.0 - exp(-10.0 * delta))

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
	if not held:
		off_now = 0.0
		return

	var moving := absf(_bv) > 0.05
	var line := kx if depth > KERF_FROM else 0.0
	off_now = clampf((absf(bx - line) - line_tol) / LINE_SPAN, 0.0, 1.0)
	if moving:
		_seg_off += off_now * delta
		_seg_time += delta
		_seg_bx += bx * delta
		_off_acc += off_now * delta * OFF_BOTCH_RATE * size_k
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
	var layer: Dictionary = layers[li]
	var speed := length / dur
	var vf := fast_speed(li)
	var rushed := clampf((speed - vf) / (vf * 0.4), 0.0, 1.0)
	var len_q := clampf((length - MIN_LEN) / (GOOD_LEN - MIN_LEN), 0.0, 1.0)
	var off := _seg_off / _seg_time if _seg_time > 0.0 else off_now
	var seg_bx := _seg_bx / _seg_time if _seg_time > 0.0 else bx

	var adv := k_cut / float(layer.res) * (FLOOR + (1.0 - FLOOR) * len_q) * (1.0 - 0.85 * rushed) * (1.0 - 0.6 * off)
	depth = minf(1.0, depth + adv)
	strokes += 1

	# Kerf record: where the metal went and how ragged it is.
	var badness := clampf(rushed + 0.3 * (1.0 - len_q), 0.0, 1.0)
	var rag := clampf(absf(seg_bx - kx) / 0.02 + off * 0.8 + rushed * 0.7, 0.0, 1.0)
	kx = (kx * _adv_total + seg_bx * adv) / (_adv_total + adv)
	jag = (jag * _adv_total + rag * adv) / (_adv_total + adv)
	_adv_total += adv
	if off > 0.35:
		scores += 1

	tear = minf(1.0, tear + rushed * 0.5)
	_sum_tear += badness
	_sum_off += off
	_n_judged += 1
	_tear_acc += rushed * float(layer.tear) * TEAR_BOTCH_RATE * size_k
	if _tear_acc >= 1.0:
		_tear_acc -= 1.0
		botch(TEAR_BOTCH, "The saw jumped and tore the %s" % String(layer.name).to_lower())

	if off > 0.35:
		verdict = Verdict.OFF
	elif rushed > 0.15:
		verdict = Verdict.RUSHED
	elif len_q < 0.5:
		verdict = Verdict.SHORT
	else:
		verdict = Verdict.GOOD

	# Bleeding: the weaker the tourniquet, the more every pass spurts, and rushing makes it worse.
	if depth > float(layers[0].to) * 0.5:
		var spurt := bleed * float(layer.bleed) * (0.6 + 0.4 * badness)
		blood = minf(1.0, blood + spurt * 0.03)
		if spurt > 0.2 or rushed > 0.5:
			splats += 1 + (1 if (spurt > 0.6 or rushed > 0.8) and _rng.randf() < 0.5 else 0)
		_bleed_acc += spurt * BLEED_BOTCH_RATE * size_k
		if _bleed_acc >= 1.0:
			_bleed_acc -= 1.0
			botch(BLEED_BOTCH, "Blood is pouring out of the cut")

	_update_progress()
	if depth >= 1.0:
		var body = ctx.get("body")
		_amputate_body(body)
		if skull:
			finish({"skull_open": true, "cut_quality": cut_quality()})
		else:
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
	f["skull_open" if skull else "amputated"] = true
	body.apply_flags(f)


# ---------------------------------------------------------------------------- per frame

func tick(delta: float) -> void:
	if not _built and is_inside_tree():
		_build()
	if not _built:
		return
	_vt += delta
	_update_visuals(delta)


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Saw through the limb"))
	var hint := "Hold left click and saw back and forth along the line."
	if done or depth >= 1.0:
		hint = "It's open." if skull else "It's off."
	elif held:
		if off_now > 0.35 or verdict == Verdict.OFF:
			hint = "Off the line! Steer back onto the cut."
		elif verdict == Verdict.RUSHED:
			hint = "Too fast, the saw is jumping. Ease off."
		elif verdict == Verdict.SHORT:
			hint = "Longer strokes. Use the whole blade."
		elif layers[layer_index()].name == "Bone":
			hint = "Bone. Steady strokes, don't rush it."
		else:
			hint = "That's biting. Keep going."
	return {"title": title, "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"z": snappedf(bz, 0.0005), "x": snappedf(bx, 0.0005), "d": snappedf(depth, 0.001),
		"b": snappedf(blood, 0.005), "k": snappedf(kx, 0.0005), "j": snappedf(jag, 0.01), "h": held,
		"g": strokes, "n": splats, "c": scores, "t": snappedf(tear, 0.01), "v": verdict, "o": snappedf(off_now, 0.02)}


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
	verdict = int(s.get("v", verdict))
	off_now = float(s.get("o", off_now))
	_update_progress()


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1) if _bt >= 0.0 else 0.0
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sl := 1.0 - skill
	if t < 0.25:
		return {"cursor": Vector2(0.0, 0.0), "buttons": 0}
	# Strokes per second: calm when competent, frantic and lurching when sloppy.
	var f := 1.3 + sl * (2.1 + 0.9 * sin(t * 0.9) + 0.5 * sin(t * 2.3 + 0.7))
	_bphase += f * dt
	var amp := 0.1 - sl * (0.01 + 0.02 * sin(t * 1.3 + 1.0))
	var z := amp * sin(TAU * _bphase)
	var x := sl * (0.045 * sin(t * 0.7 + 0.4) + 0.012 * sin(t * 2.9)) + 0.0015 * sin(t * 5.3)
	return {"cursor": Vector2(x, z), "buttons": BUTTON_PRIMARY}


## Headless check: plays the bot through the simulation (no scene tree) for 20 cases and
## prints strokes, time, botches and quality. Run: `tools/minigame_lab.tscn -- --selftest=saw`.
static func self_test() -> Array:
	var script: GDScript = load("res://scripts/surgery/games/saw.gd")
	var out := []
	for cond in [{"tq": 0.95, "sed": 1.0}, {"tq": 0.5, "sed": 0.4}]:
		for pid in ["bob", "seal"]:
			for skill in [1.0, 0.75, 0.5, 0.25, 0.0]:
				var g = script.new()
				var tally := {"n": 0, "v": 0.0, "done": false, "q": 0.0, "reasons": {}}
				g.botched.connect(func(a, r): tally.n += 1; tally.v += a; tally.reasons[r] = int(tally.reasons.get(r, 0)) + 1)
				g.finished.connect(func(r): tally.done = true; tally.q = float(r.get("cut_quality", 0.0)))
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": "amputation",
					"step": Procedures.step("amputation", 2), "variant": "", "shift": 1,
					"difficulty": Procedures.difficulty(1), "flags": {"tourniquet": cond.tq, "sedation": cond.sed},
					"seed": hash("saw" + pid), "body": null, "operator": true})
				var t: float = load("res://scripts/surgery/games/gauze.gd")._run_bot(g, skill, float(cond.sed), hash(pid) + int(skill * 100))
				var line := "[saw self-test] %-4s skill=%.2f tq=%.2f sed=%.1f  %s  passes=%3d  time=%5.1fs  botches=%2d vitals=%5.1f  q=%.2f  %s" % [
					pid, skill, cond.tq, cond.sed, "DONE" if tally.done else "UNFINISHED", g.strokes, t, tally.n, tally.v, tally.q, str(tally.reasons)]
				print(line)
				out.append({"patient": pid, "skill": skill, "tq": cond.tq, "done": tally.done, "time": t, "botches": tally.n, "vitals": tally.v, "q": tally.q})
				g.free()
	# dissection (sweep 3): the skull variant on both monsters, sedated, stirring and awake (the
	# awake thrashing botches come from the dissection system, not from here).
	for sed in [1.0, 0.5, 0.2]:
		for pid in ["walk_in", "discharged"]:
			for skill in [1.0, 0.5, 0.0]:
				var g = script.new()
				var tally := {"n": 0, "v": 0.0, "done": false, "q": 0.0, "flag": false, "reasons": {}}
				g.botched.connect(func(a, r): tally.n += 1; tally.v += a; tally.reasons[r] = int(tally.reasons.get(r, 0)) + 1)
				g.finished.connect(func(r): tally.done = true; tally.q = float(r.get("cut_quality", 0.0)); tally.flag = bool(r.get("skull_open", false)) and not r.has("amputated"))
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": "dissection",
					"step": Procedures.step("dissection", 0), "variant": "skull", "shift": 1,
					"difficulty": Procedures.difficulty(1), "flags": {"sedation": sed},
					"seed": hash("skull" + pid), "body": null, "operator": true})
				var t2: float = load("res://scripts/surgery/games/gauze.gd")._run_bot(g, skill, float(sed), hash(pid) + int(skill * 100))
				var line2 := "[saw self-test] skull %-10s skill=%.2f sed=%.1f  %s  passes=%3d  time=%5.1fs  botches=%2d vitals=%5.1f  q=%.2f  skull_open=%s  %s" % [
					pid, skill, sed, "DONE" if tally.done else "UNFINISHED", g.strokes, t2, tally.n, tally.v, tally.q, str(tally.flag), str(tally.reasons)]
				print(line2)
				out.append({"patient": pid, "variant": "skull", "skill": skill, "sed": sed, "done": tally.done and tally.flag, "time": t2, "botches": tally.n, "vitals": tally.v, "q": tally.q})
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
	# The glowing guide along the cut: it flashes green, amber or red with each pass.
	_guide = _decal(_texture("glow_line"), Vector3(0.09, proj_h, hs * 3.2 + 0.05), Vector3(0, proj_y, 0), 10)
	_guide.texture_emission = _guide.texture_albedo
	# Bright enough to read under the work lamp, not so bright it blooms the limb away.
	_guide.emission_energy = 1.3
	_guide.modulate = GUIDE_COLORS[Verdict.NONE]
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
	# A glow along the teeth, the same colour as the guide on the limb.
	var teeth := MeshInstance3D.new()
	var tb := BoxMesh.new()
	tb.size = Vector3(0.02, 0.002, 0.27)
	teeth.mesh = tb
	_teeth_mat = StandardMaterial3D.new()
	_teeth_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_teeth_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_teeth_mat.albedo_color = Color(GUIDE_COLORS[Verdict.NONE], 0.0)
	teeth.material_override = _teeth_mat
	teeth.position = Vector3(0.0, 0.003, -0.02)
	teeth.name = "TeethGlow"
	_saw.add_child(teeth)
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
	# Chips of whatever the teeth are biting into, thrown out of the kerf on a good pass.
	_chips = _particles(Color(1, 1, 1), 0.0022, 14, 0.5)
	(_chips.material_override as StandardMaterial3D).vertex_color_use_as_albedo = true
	_chips.direction = Vector3(0, 1, 0)
	_chips.spread = 55.0
	_chips.initial_velocity_min = 0.25
	_chips.initial_velocity_max = 0.6
	_chips.gravity = Vector3(0, -4.0, 0)

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
	var tcol: Color = layers[li].col
	_tissue.modulate = Color(tcol.r, tcol.g, tcol.b, 0.8)
	var kb := clampf(0.12 + 0.25 * f + blood * 1.6, 0.0, 1.0)
	if layers[li].name == "Bone":
		kb = minf(kb, 0.35 + blood * 0.4)
	_kerf_blood.size = Vector3(width * 0.8, _kerf_blood.size.y, len_z * 0.95)
	_kerf_blood.modulate = Color(1, 1, 1, kb)
	# Bone dust builds up once the saw reaches bone.
	var bone_from := float(layers[_bone_i - 1].to)
	var bone_amt := clampf((f - bone_from) / (float(layers[_bone_i].to) - bone_from), 0.0, 1.0)
	_dust_decal.visible = bone_amt > 0.02 and not _finale
	_dust_decal.position.x = kx
	_dust_decal.size = Vector3(width * 1.8, _dust_decal.size.y, len_z + 0.02)
	_dust_decal.modulate = Color(1, 1, 1, clampf(bone_amt * 1.2, 0.0, 0.55) * (1.0 - blood * 0.8) * clampf(1.0 - (f - float(layers[_bone_i].to)) / 0.12, 0.0, 1.0))
	# Pooled blood grows over the cut line and hides the marks.
	_pool.visible = blood > 0.02
	var ps := lerpf(0.03, 0.2, sqrt(blood))
	_pool.size = Vector3(ps * 1.3, _pool.size.y, ps)
	_pool.position.x = kx + 0.01 * distal
	_pool.modulate = Color(1, 1, 1, clampf(blood * 2.5, 0.0, 0.95))
	_marker.modulate = Color(1, 1, 1, clampf(1.0 - blood * 1.1, 0.15, 1.0))
	# The guide: a calm glow until the saw is working, then the colour of the last pass, brightest
	# right after it; red at once while the blade is off the line.
	_flash = maxf(0.0, _flash - delta * 1.6)
	var gcol: Color = GUIDE_COLORS[Verdict.NONE]
	var glow := 0.25
	if held and off_now > 0.35:
		gcol = GUIDE_COLORS[Verdict.OFF]
		glow = 0.9
	elif held and verdict != Verdict.NONE:
		gcol = _flash_col
		glow = 0.55 + 0.45 * _flash
	_guide.visible = not _finale
	_guide.position.x = kx if depth > KERF_FROM else 0.0
	_guide.modulate = Color(gcol.r, gcol.g, gcol.b, glow)
	_teeth_mat.albedo_color = Color(gcol.r, gcol.g, gcol.b, (0.25 + 0.6 * _flash) if held else 0.0)

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
			var age := _vt - _splat_born[i]
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
	# The blade sinks with the cut; a rushed pass makes it hop out of the kerf.
	var sink := minf(d_m * 1.4, 0.05)
	_hop = maxf(0.0, _hop - delta * 5.0)
	var hop := _hop * _hop * 0.012 * absf(sin(_vt * 60.0))
	_saw.position = Vector3(_vis_bx - sin(deg_to_rad(8.0)) * (0.05 - sink * 0.5), _vis_lift - sink + hop, _vis_bz)
	_saw.rotation.y = clampf((_vis_bx - kx) * 3.0, -0.25, 0.25)
	_smear_mat.albedo_color.a = clampf(0.25 * f + blood * 1.5, 0.0, 0.92)
	var nd := int(clampf(blood * 9.0, 0.0, 6.0))
	for i in _drips.size():
		var dr := _drips[i]
		dr.visible = i < nd
		if dr.visible:
			var fall := fmod(_vt * (0.7 + 0.13 * i) + i * 0.37, 1.0)
			dr.position = Vector3(-0.08 + i * 0.05, 0.012, 0.045 + fall * 0.018)
			dr.scale = Vector3(1, 1, 1.0 + fall)

	# A new pass: the guide flashes its verdict, the teeth bite (chips and a rasp or a grind), or
	# skip and hop when rushed.
	if strokes != _seen_strokes:
		var fresh := strokes > _seen_strokes
		_seen_strokes = strokes
		var at := global_position
		if fresh:
			_flash = 1.0
			_flash_col = GUIDE_COLORS.get(verdict, GUIDE_COLORS[Verdict.NONE])
		var side := open_half * (1.0 if strokes % 2 == 0 else -1.0)
		if verdict == Verdict.RUSHED:
			_hop = 1.0
			_audio("surgery_saw_grind", at, 0.0, 0.25)
			_audio("surgery_saw_squelch", at, -6.0, 0.15)
		elif layers[li].name == "Bone":
			_audio("surgery_saw_grind", at, -3.0 if verdict == Verdict.GOOD else -8.0, 0.08)
			_dust.position = Vector3(kx, 0.004, side)
			_dust.restart()
		else:
			_audio("surgery_saw_rasp", at, -3.0 if verdict == Verdict.GOOD else -9.0, 0.1)
			if blood > 0.25 and strokes % 3 == 0:
				_audio("surgery_saw_squelch", at, -9.0, 0.1)
		if verdict == Verdict.GOOD or verdict == Verdict.RUSHED:
			_chips.color = layers[li].col.lightened(0.1)
			_chips.position = Vector3(kx, 0.006, side * 0.6)
			_chips.restart()
	if li != _seen_layer:
		# Into the next layer: a clunk as the teeth meet bone, a softer give past it.
		if li > _seen_layer and _built and not _finale:
			_audio("surgery_saw_thunk" if layers[li].name == "Bone" else "surgery_saw_squelch", global_position, -12.0 if layers[li].name == "Bone" else -8.0, 0.1)
		_seen_layer = li

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
	_splat_born[i % MAX_SPLATS] = _vt


func _start_finale(body) -> void:
	_finale = true
	# A static copy of the limb drops away while the body shows its stump. (The skull: the body
	# itself lifts the cap off when it gets `skull_open`.)
	if not skull and body != null and is_instance_valid(body) and body.has_method("make_severed_limb"):
		_severed = body.make_severed_limb(self)
	_amputate_body(body)
	var at := global_position
	_audio("surgery_saw_thunk", at, 0.0, 0.03)
	_audio("surgery_saw_squelch", at, -4.0, 0.05)
	_spurt.position = Vector3(kx, 0.0, 0.0)
	_spurt.restart()
	for d in [_marker, _pool, _guide]:
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
		"glow_line": img = _img_glow_line()
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


## A soft glowing band along the image's long axis (decal Z): a bright core, a wide halo, and
## faded ends. Tinted by the decal's modulate.
static func _img_glow_line() -> Image:
	var w := 32
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var v := absf((y + 0.5) / h * 2.0 - 1.0)
		var ends := 1.0 - smoothstep(0.8, 1.0, v)
		for x in w:
			var u := absf((x + 0.5) / w * 2.0 - 1.0)
			var core := 1.0 - smoothstep(0.06, 0.16, u)
			var halo := pow(clampf(1.0 - u, 0.0, 1.0), 3.0) * 0.45
			img.set_pixel(x, y, Color(1, 1, 1, clampf(core + halo, 0.0, 1.0) * ends))
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
