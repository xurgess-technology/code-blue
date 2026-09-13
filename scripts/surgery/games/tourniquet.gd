extends "res://scripts/surgery/minigame.gd"
## Amputation step 2: apply the tourniquet.
##
## Work plane = the `limb` site: local X runs along the limb toward the hand / flipper tip,
## local +Y out of the skin, local Z across the limb. The infection creeps up from +X.
##
## PLACE: the open strap hangs off the cursor across the limb. Slide it along X and click to
##   cinch. The strap centre must sit BAND_NEAR..BAND_FAR above (toward -X) the infection's
##   most proximal visible point. On / below the infection or too close: botch, the strap
##   slips off, and a faint guide band appears. Further above than the band: allowed, lower q.
## CRANK: circle the cursor around the windlass rod. Clockwise tightens, counter-clockwise
##   loosens; one cursor circle = a quarter turn of the rod, a ratchet click every eighth of a
##   circle. Pressure rises nonlinearly with rod turns. Past the good band the limb goes purple
##   and vitals drain; under it the distal pulse keeps going. Hold in the band ~2 s, then
##   right-click (or click the red clip) to lock.
##
## Result: {"tourniquet": q}, q = placement quality * pressure quality * hold factor.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Stage { PLACE, CRANK, LOCKED }

# -- placement ---------------------------------------------------------------------------
const STRAP_W := 0.038           # a real CAT strap is 3.8 cm wide
const BAND_CENTER := 0.05        # ideal strap centre, metres above the infection front
const BAND_HALF := 0.02          # 3..7 cm at difficulty 1, narrower later
const BAND_HALF_MIN := 0.008
const INFECT_FRONT_MIN := 0.03   # infection front sits this far distal of the site marker..
const INFECT_FRONT_MAX := 0.055  # ..to this (the bodies paint their own infection from ~5 cm on)
const PLACE_REACH := 0.15        # strap slides over x in [-PLACE_REACH, PLACE_REACH]
const SLIP_TIME := 0.8
const BOTCH_ON_INFECTION := 9.0
const BOTCH_TOO_CLOSE := 5.0
const FAR_FALLOFF := 0.10        # placement quality loses 0.6 over this much past the band

# -- windlass / pressure ------------------------------------------------------------------
const TURNS_MAX := 2.75          # rod turns before it will not go further
const P_REF_TURNS := 2.6
const P_REF := 450.0             # mmHg at P_REF_TURNS
const P_EXP := 2.4
const P_GAUGE_MAX := 500.0
const GOOD_CENTER := 270.0       # mmHg
const GOOD_HALF := 30.0          # at difficulty 1
const GOOD_HALF_MIN := 12.0
const HOLD_TIME := 2.0
const OVER_RATE := 4.0           # vitals per second while over the band
const OVER_CHUNK := 0.5          # emitted in chunks of this many seconds
const TOO_LOOSE_MARGIN := 90.0   # locking this far under the band is refused (botch)
const BOTCH_TOO_LOOSE := 3.0
const MAX_STEP_ANGLE := 0.9      # cursor angle change per frame beyond this is a jolt, ignored
const MIN_ORBIT_R := 0.012
const CLIP_OFFSET := 0.045       # red clip sits this far distal of the rod pivot
const CLIP_PICK_R := 0.022
const WRAP_TIME := 0.4
const LOCK_FINISH_DELAY := 0.6

# -- state (replicated) --------------------------------------------------------------------
var stage: int = Stage.PLACE
var strap_x := -0.08
var rod_angle := 0.0             # radians of rod rotation, 0 = along the limb
var pressure := 0.0
var hold := 0.0
var slip := 0.0                  # 0 = hanging, >0 slipping off (0..1)
var guide := false

# -- operator-only --------------------------------------------------------------------------
var cursor := Vector2.ZERO
var misplaces := 0
var place_q := 1.0
var press_q := 0.0
var quality := 0.0
var _prev_buttons := 0
var _orbit_ref := INF
var _crank_wait := 0.0
var _jolt_t := 0.0
var _over_acc := 0.0
var _lock_t := -1.0
var _last_hint := ""
var _hint_t := 0.0

# -- derived from ctx -------------------------------------------------------------------------
var half_up := 0.05              # limb section half sizes at the site
var half_side := 0.05
var sec_n := 2.2                 # superellipse exponent of the section: 2 round, 6+ boxy
var infect_front := 0.06
## Ideal strap centre above the front. On a real body that puts the ideal right on the site,
## where the body draws its own tourniquet afterwards, a hand's width above the cut line.
var band_center := BAND_CENTER
var band_half := BAND_HALF
var good_min := GOOD_CENTER - GOOD_HALF
var good_max := GOOD_CENTER + GOOD_HALF
var _b0 := 0.06
var _amp := Vector3.ZERO
var _ph := Vector3.ZERO
var _skin := Color(0.93, 0.72, 0.56)
var _seal := false

# -- visuals ---------------------------------------------------------------------------------
var _built := false
var _t := 0.0
var _wrap := 0.0
var _stand := 0.0
var _vis_x := -0.08
var _lock_vis := 0.0
var _sway := 0.0
var _guide_a := 0.0
var _decal_infect: Decal
var _decal_blanch: Decal
var _decal_purple: Decal
var _decal_guide: Decal
var _guide_lines: Node3D
var _guide_mat: StandardMaterial3D
var _strap_root: Node3D
var _strap_mesh: MeshInstance3D
var _velcro_mesh: MeshInstance3D
var _tab: MeshInstance3D
var _windlass: Node3D
var _rod_pivot: Node3D
var _twist: MeshInstance3D
var _clip: Node3D
var _gauge: Node3D
var _needle: Node3D
var _gauge_label: Label3D
var _gauge_bands: Node3D
var _tube: MeshInstance3D
var _puck: Node3D
var _led_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _orbit: MeshInstance3D
var _orbit_mat: StandardMaterial3D
var _dot: MeshInstance3D
var _strap_mat: StandardMaterial3D
var _built_wrap := -1.0
var _built_sq := -1.0

# -- sounds -----------------------------------------------------------------------------------
var _snd_stage := -1
var _snd_slip := false
var _snd_click := 0
var _snd_click_cd := 0.0
var _snd_creak := 0
var _snd_first := true

# -- bot --------------------------------------------------------------------------------------
var _bt := 0.0
var _b_phase_t := 0.0
var _b_attempt := -1
var _b_from := -0.12
var _b_ang := -PI * 0.5
var _b_mode := 0
var _b_mode_t := 0.0
var _b_lock_frames := 0


func setup(context: Dictionary) -> void:
	super.setup(context)
	var diff := maxf(0.5, float(ctx.get("difficulty", 1.0)))
	band_half = maxf(BAND_HALF_MIN, BAND_HALF / diff)
	var gh := maxf(GOOD_HALF_MIN, GOOD_HALF / diff)
	good_min = GOOD_CENTER - gh
	good_max = GOOD_CENTER + gh
	_seal = String(ctx.get("patient", {}).get("body", ctx.get("patient_id", "bob"))) == "seal" or String(ctx.get("patient_id", "")) == "seal"
	_skin = Color(0.3, 0.32, 0.35) if _seal else Color(0.8, 0.58, 0.44)
	_read_limb_section()
	_roll_infection(int(ctx.get("seed", 1)))
	strap_x = -0.08
	_vis_x = strap_x
	_build()
	_update_visuals(0.0)


## Limb section at the site, from PatientBody.site_section; without a body (the self-test) it
## falls back to the patient's limb radius.
func _read_limb_section() -> void:
	var r := float(ctx.get("patient", {}).get("limb_radius_m", 0.085 if _seal else 0.05))
	half_up = r
	half_side = r
	# Bob's Kenney forearm is a box; the seal's flipper stub is a rounded oval.
	sec_n = 2.3 if _seal else 6.0
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or not body.has_method("site_section"):
		return
	var sec: Dictionary = body.site_section(String(ctx.get("step", {}).get("site", "limb")))
	if sec.is_empty():
		return
	half_up = clampf(float(sec.half_up), 0.02, 0.15)
	half_side = clampf(float(sec.half_side), 0.02, 0.15)
	sec_n = float(sec.get("shape", sec_n))


## Where the body paints its own infection, so the strap's rule and our decal line up with it.
## INF when there is no body; the minigame then rolls its own front.
func _body_infection_start() -> float:
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or not body.has_method("infection_start"):
		return INF
	return float(body.infection_start(String(ctx.get("step", {}).get("site", "limb"))))


func _roll_infection(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("tourniquet|%d" % seed_value)
	_amp = Vector3(rng.randf_range(0.004, 0.008), rng.randf_range(0.002, 0.005), rng.randf_range(0.001, 0.0025))
	_ph = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
	var target := rng.randf_range(INFECT_FRONT_MIN, INFECT_FRONT_MAX)
	var body_front := _body_infection_start()
	if body_front < PLACE_REACH:
		target = body_front
		band_center = maxf(body_front, band_half + STRAP_W * 0.5 + 0.006)
	var lowest := INF
	for i in 121:
		var th := lerpf(-1.3, 1.3, float(i) / 120.0)
		lowest = minf(lowest, _boundary_shape(th))
	# The shader adds up to 3 mm of jagged noise on top of the smooth shape.
	_b0 = target - lowest + 0.003
	infect_front = target


func _boundary_shape(th: float) -> float:
	return _amp.x * sin(2.0 * th + _ph.x) + _amp.y * sin(3.0 * th + _ph.y) + _amp.z * sin(5.0 * th + _ph.z)


func plane_extent() -> Vector2:
	return Vector2(PLACE_REACH, maxf(0.12, half_side + 0.085))


func camera_pose() -> Dictionary:
	return {"height": 0.40 + maxf(0.0, half_side - 0.05) * 1.2, "back": 0.15, "fov": 55.0}


# ======================================================================== rules

func pressure_at(turns: float) -> float:
	return minf(P_GAUGE_MAX, P_REF * pow(maxf(0.0, turns) / P_REF_TURNS, P_EXP))


func distance_above_infection(x: float) -> float:
	return infect_front - x


## The shake after a stir must not crank the windlass: drop the orbit reference until it passes.
func on_jolt(_offset: Vector2, _strength: float, duration: float) -> void:
	_jolt_t = duration
	_orbit_ref = INF


func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	_jolt_t = maxf(0.0, _jolt_t - delta)
	cursor = p
	var pressed := buttons & ~_prev_buttons
	_prev_buttons = buttons
	match stage:
		Stage.PLACE:
			if slip > 0.0:
				slip += delta / SLIP_TIME
				if slip >= 1.0:
					slip = 0.0
					strap_x = clampf(p.x, -PLACE_REACH, PLACE_REACH)
				return
			strap_x = lerpf(strap_x, clampf(p.x, -PLACE_REACH, PLACE_REACH), clampf(delta * 18.0, 0.0, 1.0))
			if pressed & BUTTON_PRIMARY:
				_try_cinch()
		Stage.CRANK:
			if _crank_wait > 0.0:
				_crank_wait -= delta
				_orbit_ref = INF
				return
			_crank(p, delta)
			if (pressed & BUTTON_SECONDARY) or ((pressed & BUTTON_PRIMARY) and p.distance_to(Vector2(strap_x + CLIP_OFFSET, 0.0)) <= CLIP_PICK_R):
				_try_lock()
		Stage.LOCKED:
			_lock_t += delta
			if _lock_t >= LOCK_FINISH_DELAY:
				finish({"tourniquet": snappedf(quality, 0.001)})


func _try_cinch() -> void:
	var d := distance_above_infection(strap_x)
	var near := band_center - band_half
	var far := band_center + band_half
	if d < near - 0.004:
		misplaces += 1
		guide = true
		slip = 0.001
		if d < STRAP_W * 0.5 + 0.002:
			botch(BOTCH_ON_INFECTION, "The strap is on the infection: it slipped off")
		else:
			botch(BOTCH_TOO_CLOSE, "Too close to the infection: the strap slipped off")
		return
	if d <= far:
		var e := absf(d - band_center) / band_half
		place_q = 1.0 - 0.08 * e * e
	else:
		place_q = clampf(0.92 - 0.6 * (d - far) / FAR_FALLOFF, 0.3, 0.92)
	stage = Stage.CRANK
	rod_angle = 0.0
	pressure = 0.0
	hold = 0.0
	_crank_wait = WRAP_TIME
	_orbit_ref = INF
	progress = 0.2


func _crank(p: Vector2, delta: float) -> void:
	var rel := p - Vector2(strap_x, 0.0)
	if _jolt_t > 0.0:
		_orbit_ref = INF
	elif rel.length() >= MIN_ORBIT_R:
		var a := atan2(rel.y, rel.x)
		if _orbit_ref != INF:
			var da := wrapf(a - _orbit_ref, -PI, PI)
			if absf(da) <= MAX_STEP_ANGLE:
				rod_angle = clampf(rod_angle + da * 0.25, 0.0, TURNS_MAX * TAU)
		_orbit_ref = a
	else:
		_orbit_ref = INF
	pressure = pressure_at(rod_angle / TAU)
	if pressure >= good_min and pressure <= good_max:
		hold = minf(hold + delta, HOLD_TIME + 1.0)
	else:
		hold = 0.0
	if pressure > good_max:
		_over_acc += delta
		if _over_acc >= OVER_CHUNK:
			_over_acc -= OVER_CHUNK
			botch(OVER_RATE * OVER_CHUNK, "Too tight: the limb is going purple")
	else:
		_over_acc = 0.0
	progress = 0.2 + 0.55 * clampf(pressure / GOOD_CENTER, 0.0, 1.0) + 0.2 * clampf(hold / HOLD_TIME, 0.0, 1.0)
	progress = minf(progress, 0.95)


func _try_lock() -> void:
	if pressure < good_min - TOO_LOOSE_MARGIN:
		botch(BOTCH_TOO_LOOSE, "Far too loose: the windlass spun free")
		rod_angle *= 0.6
		pressure = pressure_at(rod_angle / TAU)
		hold = 0.0
		return
	var gh := (good_max - good_min) * 0.5
	if pressure >= good_min and pressure <= good_max:
		var e := absf(pressure - GOOD_CENTER) / gh
		press_q = 1.0 - 0.1 * e * e
	elif pressure < good_min:
		press_q = clampf(0.9 - 0.55 * (good_min - pressure) / TOO_LOOSE_MARGIN, 0.3, 0.9)
	else:
		press_q = clampf(0.9 - 0.6 * (pressure - good_max) / 80.0, 0.2, 0.9)
	var hold_f := 0.75 + 0.25 * clampf(hold / HOLD_TIME, 0.0, 1.0)
	quality = clampf(place_q * press_q * hold_f, 0.0, 1.0)
	stage = Stage.LOCKED
	_lock_t = 0.0
	progress = 0.97
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding"):
		body.set_bleeding("limb", 0.0)


func tick(delta: float) -> void:
	_t += delta
	_update_visuals(delta)
	_sounds(delta)


# ======================================================================== HUD / net

func pulse_strength() -> float:
	if stage == Stage.PLACE:
		return 1.0
	return clampf(1.0 - smoothstep(good_min * 0.35, good_min, pressure), 0.0, 1.0)


func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Apply the tourniquet"))
	var hint := ""
	match stage:
		Stage.PLACE:
			if slip > 0.0:
				hint = "It slipped off. It has to go above the infection, in the green band."
			elif guide:
				hint = "Slide the strap into the green band, %d to %d cm above the infection, and click to cinch." % [
					int(round((band_center - band_half) * 100.0)), int(round((band_center + band_half) * 100.0))]
			else:
				hint = "Slide the strap along the limb and click to cinch it a few centimetres above the infection."
		Stage.CRANK:
			if _crank_wait > 0.0:
				hint = "Strap cinched. Now turn the windlass."
			elif pressure > good_max:
				hint = "Too tight! The limb is going purple. Circle counter-clockwise to loosen."
			elif pressure >= good_min:
				if hold < HOLD_TIME:
					hint = "Good pressure. Hold it there... %.1f s" % maxf(0.0, HOLD_TIME - hold)
				else:
					hint = "Pulse gone. Right-click (or click the red clip) to lock the windlass."
			elif pressure > good_min * 0.35:
				hint = "Distal pulse still there. Keep circling clockwise around the rod."
			else:
				hint = "Circle the cursor clockwise around the red rod to tighten (counter-clockwise loosens)."
		Stage.LOCKED:
			hint = "Locked. Tourniquet %d%%." % int(round(quality * 100.0))
	return {"title": title, "hint": hint, "progress": progress, "gauges": [
		{"label": "Pressure", "value": pressure, "min": 0.0, "max": P_GAUGE_MAX, "good_min": good_min, "good_max": good_max},
		{"label": "Distal pulse", "value": pulse_strength(), "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 0.1},
	]}


func net_state() -> Dictionary:
	return {"s": stage, "x": strap_x, "a": rod_angle, "pr": pressure, "h": hold, "sl": slip, "g": guide, "q": quality, "p": progress}


func apply_net_state(s: Dictionary) -> void:
	stage = int(s.get("s", stage))
	strap_x = float(s.get("x", strap_x))
	rod_angle = float(s.get("a", rod_angle))
	pressure = float(s.get("pr", pressure))
	hold = float(s.get("h", hold))
	slip = float(s.get("sl", slip))
	guide = bool(s.get("g", guide))
	quality = float(s.get("q", quality))
	progress = float(s.get("p", progress))


# ======================================================================== bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := skill < 0.5
	var buttons := 0
	match stage:
		Stage.PLACE:
			if slip > 0.0:
				_b_attempt = -1
				return {"cursor": Vector2(strap_x, 0.02), "buttons": 0}
			if _b_attempt != misplaces:
				_b_attempt = misplaces
				_b_phase_t = 0.0
				_b_from = strap_x
			_b_phase_t += dt
			var target: float
			if sloppy and misplaces == 0:
				target = infect_front + 0.012
			else:
				target = infect_front - band_center - band_half * lerpf(0.6, 0.0, skill)
			var move_t := lerpf(1.4, 0.9, skill)
			var k := smoothstep(0.0, move_t, _b_phase_t)
			var x := lerpf(_b_from, target, k)
			if sloppy:
				x += sin(t * 3.7) * 0.003 * (1.0 - k * 0.5)
			var click_at := move_t + lerpf(0.5, 0.3, skill)
			if _b_phase_t >= click_at and _b_phase_t < click_at + 0.1:
				buttons = BUTTON_PRIMARY
			return {"cursor": Vector2(x, 0.02), "buttons": buttons}
		Stage.CRANK:
			_b_mode_t += dt
			var omega := 0.0   # cursor circles per second, + = clockwise
			if _crank_wait > 0.0:
				_b_mode = 0
				_b_mode_t = 0.0
			elif not sloppy:
				match _b_mode:
					0:
						if pressure < GOOD_CENTER - 0.4 * (good_max - good_min) * 0.5:
							omega = 1.6
						elif pressure < GOOD_CENTER - 0.08 * (good_max - good_min) * 0.5:
							omega = 0.3
						else:
							_b_mode = 1
							_b_mode_t = 0.0
					1:
						if hold >= HOLD_TIME + 0.1:
							_b_mode = 2
							_b_lock_frames = 0
					2:
						_b_lock_frames += 1
						if _b_lock_frames <= 3:
							buttons = BUTTON_SECONDARY
						elif _b_lock_frames > 30:
							_b_mode = 0
			else:
				match _b_mode:
					0:
						omega = 2.2
						if pressure > good_max + 45.0:
							_b_mode = 1
							_b_mode_t = 0.0
					1:
						omega = 2.2   # reaction lag: keeps cranking a moment
						if _b_mode_t > 0.45:
							_b_mode = 2
					2:
						omega = -1.0
						if pressure < good_min - 35.0:
							_b_mode = 3
							_b_mode_t = 0.0
					3:
						if _b_mode_t > 0.6:
							_b_mode = 4
							_b_lock_frames = 0
					4:
						_b_lock_frames += 1
						if _b_lock_frames <= 3:
							buttons = BUTTON_SECONDARY
						elif _b_lock_frames > 30:
							_b_mode = 3
							_b_mode_t = 0.0
			_b_ang += omega * TAU * dt
			var r := 0.05 + (sin(t * 5.3) * 0.008 if sloppy else 0.0)
			return {"cursor": Vector2(strap_x, 0.0) + Vector2(cos(_b_ang), sin(_b_ang)) * r, "buttons": buttons}
	return {"cursor": cursor, "buttons": 0}


## Plays 20 generated cases per skill through the bot, headless, and prints the stats.
## Run: godot --headless --path . -s <a probe that calls this>
static func self_test() -> Dictionary:
	var script: GDScript = load("res://scripts/surgery/games/tourniquet.gd")
	var patients := {
		"bob": {"name": "Bob", "body": "bob", "weight_kg": 82.0, "limb_radius_m": 0.05},
		"seal": {"name": "The seal", "body": "seal", "weight_kg": 130.0, "limb_radius_m": 0.085},
	}
	var out := {}
	for skill in [1.0, 0.0]:
		var qs: Array[float] = []
		var botches: Array[float] = []
		var counts: Array[int] = []
		var times: Array[float] = []
		var unfinished := 0
		for i in 20:
			var pid := "bob" if i % 2 == 0 else "seal"
			var mg = script.new()
			var rec := {"q": -1.0, "botch": 0.0, "n": 0, "t": -1.0}
			mg.botched.connect(func(amount, _reason): rec.botch += amount; rec.n += 1)
			mg.finished.connect(func(r): rec.q = float(r.get("tourniquet", -1.0)))
			mg.setup({"patient_id": pid, "patient": patients[pid], "ailment_id": "amputation",
				"step": {"id": "tourniquet", "label": "Apply the tourniquet", "game": "tourniquet", "site": "limb"},
				"variant": "", "shift": 1 + i % 4, "difficulty": 1.0 + 0.12 * float(i % 4), "flags": {"sedation": 1.0},
				"seed": hash("selftest|%d" % i), "body": null, "operator": true})
			var t := 0.0
			var dt := 1.0 / 60.0
			var ext: Vector2 = mg.plane_extent()
			while t < 60.0 and not mg.done:
				t += dt
				var inp: Dictionary = mg.bot_input(t, skill)
				var c: Vector2 = inp.get("cursor", Vector2.ZERO)
				# Every third case is an underdosed patient: the framework jolts the cursor now and then.
				if i % 3 == 2 and fmod(t, 1.7) < 0.12:
					c += Vector2(sin(t * 13.0), cos(t * 11.0)) * 0.035
				c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
				mg.handle_cursor(c, int(inp.get("buttons", 0)), dt)
				mg.tick(dt)
				mg.apply_net_state(mg.net_state())
			if mg.done:
				rec.t = t
			else:
				unfinished += 1
			print("[tourniquet self-test] skill=%.1f case=%02d %s diff=%.2f front=%.3f q=%.3f botches=%d (%.1f vitals) t=%.1f" % [
				skill, i, pid, 1.0 + 0.12 * float(i % 4), mg.infect_front, rec.q, rec.n, rec.botch, rec.t])
			qs.append(rec.q)
			botches.append(rec.botch)
			counts.append(rec.n)
			times.append(rec.t)
			mg.free()
		var s := {"q_min": qs.min(), "q_max": qs.max(), "q_mean": _mean(qs), "botch_mean": _mean(botches),
			"botch_max": botches.max(), "count_mean": _mean(counts), "t_mean": _mean(times), "t_max": times.max(), "unfinished": unfinished}
		print("[tourniquet self-test] SUMMARY skill=%.1f q mean %.3f [%.3f..%.3f]  botch vitals mean %.1f max %.1f  botch count mean %.1f  time mean %.1f s max %.1f s  unfinished %d" % [
			skill, s.q_mean, s.q_min, s.q_max, s.botch_mean, s.botch_max, s.count_mean, s.t_mean, s.t_max, unfinished])
		out[skill] = s
	return out


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())


# ======================================================================== visuals

const SLEEVE_PAD := 0.003


func _mat(col: Color, rough := 0.5, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _unshaded(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	if col.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, xf := Transform3D()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = OWN_LAYER
	parent.add_child(mi)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _cyl(r: float, h: float, sides := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	c.rings = 1
	return c


## Transform turning a Y-axis primitive to lie along +X.
func _along_x(pos: Vector3, scale := Vector3.ONE) -> Transform3D:
	return Transform3D(Basis(Vector3(0, 0, 1), -PI * 0.5).scaled_local(scale), pos)


## Point on the limb section, `off` metres outside the skin, at parameter angle th (0 = top, + toward +Z).
func _section_point(th: float, off: float) -> Vector2:
	var e := 2.0 / sec_n
	var sn := sin(th)
	var cs := cos(th)
	var z := signf(sn) * pow(absf(sn), e) * (_sleeve_side() + off)
	var y := signf(cs) * pow(absf(cs), e) * (_sleeve_up() + off)
	return Vector2(z, -half_up + y)  # (z, y)


## Outward normal of the section at th, as (z, y).
func _section_normal(th: float) -> Vector2:
	var p := _section_point(th, 0.0)
	var z := p.x / _sleeve_side()
	var y := (p.y + half_up) / _sleeve_up()
	return Vector2(signf(z) * pow(absf(z), sec_n - 1.0) / _sleeve_side(), signf(y) * pow(absf(y), sec_n - 1.0) / _sleeve_up()).normalized()


func _sleeve_side() -> float:
	return half_side * 1.05 + SLEEVE_PAD


func _sleeve_up() -> float:
	return half_up * 1.0 + SLEEVE_PAD


func _build() -> void:
	if _built:
		return
	_built = true
	# Materials: start from the item model so the strap matches the one on the shelf.
	_strap_mat = _mat(Color(0.05, 0.05, 0.055), 0.95)
	var red := _mat(Color(0.8, 0.07, 0.05), 0.45)
	var model: Node3D = ItemModelsScript.make("tourniquet", 1)
	for c in model.find_children("*", "MeshInstance3D", true, false):
		var m := (c as MeshInstance3D).material_override as StandardMaterial3D
		if m == null:
			continue
		if (c as MeshInstance3D).mesh is TorusMesh:
			_strap_mat = m.duplicate()
			_strap_mat.albedo_color = m.albedo_color.darkened(0.55)
			_strap_mat.roughness = 0.95
		elif (c as MeshInstance3D).mesh is BoxMesh and m.albedo_color.r > 0.5:
			red = m.duplicate()
	model.free()
	_strap_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# The infection, blanching, purple and guide are decals projected down onto the real limb,
	# so they follow whatever shape the patient's arm or flipper has.
	_build_decals()

	# The strap, rebuilt as it wraps.
	_strap_root = Node3D.new()
	_strap_root.name = "Tourniquet"
	add_child(_strap_root)
	_strap_mesh = _mesh(_strap_root, ArrayMesh.new(), _strap_mat)
	var velcro := _mat(Color(0.11, 0.11, 0.12), 1.0)
	velcro.cull_mode = BaseMaterial3D.CULL_DISABLED
	_velcro_mesh = _mesh(_strap_root, ArrayMesh.new(), velcro)
	_tab = _mesh(_strap_root, _box(Vector3(STRAP_W * 0.8, 0.004, 0.02)), red)

	# Windlass: stabilisation plate, the clip, and the rod on its pivot.
	_windlass = Node3D.new()
	_strap_root.add_child(_windlass)
	var plate := _mat(Color(0.07, 0.07, 0.08), 0.6)
	_mesh(_windlass, _box(Vector3(0.082, 0.005, 0.032)), plate, Transform3D(Basis(), Vector3(0.012, 0.0025, 0)))
	var white := _mat(Color(0.9, 0.9, 0.86), 0.8)
	_mesh(_windlass, _box(Vector3(0.018, 0.0012, 0.026)), white, Transform3D(Basis(), Vector3(-0.022, 0.0055, 0)))  # the TIME label
	_clip = Node3D.new()
	_clip.position = Vector3(CLIP_OFFSET, 0.004, 0)
	_windlass.add_child(_clip)
	_mesh(_clip, _box(Vector3(0.02, 0.004, 0.03)), red, Transform3D(Basis(), Vector3(0, 0.002, 0)))
	for s in [-1.0, 1.0]:
		_mesh(_clip, _box(Vector3(0.018, 0.017, 0.004)), red, Transform3D(Basis(Vector3.RIGHT, s * 0.25), Vector3(0, 0.011, s * 0.0095)))
	_rod_pivot = Node3D.new()
	_windlass.add_child(_rod_pivot)
	_twist = _mesh(_rod_pivot, _cyl(0.011, 1.0, 10), _strap_mat)
	var rod := Node3D.new()
	_rod_pivot.add_child(rod)
	rod.name = "Rod"
	_mesh(rod, _cyl(0.0058, 0.088, 14), red, _along_x(Vector3.ZERO))
	for s in [-1.0, 1.0]:
		_mesh(rod, _cyl(0.0064, 0.008, 14), _mat(Color(0.55, 0.04, 0.03), 0.5), _along_x(Vector3(s * 0.042, 0, 0)))

	# Pressure gauge beside the limb, on a line from the strap.
	_gauge = Node3D.new()
	_gauge.name = "Gauge"
	add_child(_gauge)
	var face := Node3D.new()
	face.rotation = Vector3(0.75, 0, 0)
	_gauge.add_child(face)
	_mesh(face, _cyl(0.034, 0.012, 28), _mat(Color(0.06, 0.06, 0.07), 0.35, 0.5), Transform3D(Basis(), Vector3(0, 0, 0)))
	var face_mat := _unshaded(Color(0.93, 0.92, 0.86))
	_mesh(face, _cyl(0.029, 0.002, 28), face_mat, Transform3D(Basis(), Vector3(0, 0.0065, 0)))
	_gauge_bands = Node3D.new()
	face.add_child(_gauge_bands)
	_gauge_bands.position = Vector3(0, 0.0078, 0)
	var green := _unshaded(Color(0.1, 0.7, 0.25))
	var red_zone := _unshaded(Color(0.85, 0.1, 0.08))
	var tick := _unshaded(Color(0.08, 0.08, 0.08))
	var v := 0.0
	while v <= P_GAUGE_MAX + 0.1:
		var big := int(v) % 100 == 0
		_gauge_mark(tick, v, 0.0245, Vector3(0.0012, 0.0008, 0.006 if big else 0.0035))
		v += 25.0
	v = good_min
	while v <= good_max + 0.1:
		_gauge_mark(green, v, 0.0195, Vector3(0.0035, 0.0006, 0.005))
		v += (good_max - good_min) / 6.0
	v = good_max + 10.0
	while v <= P_GAUGE_MAX:
		_gauge_mark(red_zone, v, 0.0195, Vector3(0.0035, 0.0006, 0.005))
		v += 12.0
	_needle = Node3D.new()
	_needle.position = Vector3(0, 0.009, 0)
	face.add_child(_needle)
	_mesh(_needle, _box(Vector3(0.0022, 0.0012, 0.025)), _unshaded(Color(0.8, 0.05, 0.05)), Transform3D(Basis(), Vector3(0, 0, -0.009)))
	_mesh(_needle, _cyl(0.0028, 0.002, 10), _unshaded(Color(0.1, 0.1, 0.1)), Transform3D(Basis(), Vector3(0, 0.001, 0)))
	_gauge_label = Label3D.new()
	_gauge_label.pixel_size = 0.0001
	_gauge_label.font_size = 64
	_gauge_label.outline_size = 0
	_gauge_label.modulate = Color(0.1, 0.1, 0.1)
	_gauge_label.rotation = Vector3(-PI * 0.5, 0, 0)
	_gauge_label.position = Vector3(0, 0.0085, 0.0175)
	_gauge_label.shaded = false
	_gauge_label.double_sided = false
	face.add_child(_gauge_label)
	_tube = _mesh(self, _cyl(0.0022, 1.0, 8), _mat(Color(0.05, 0.05, 0.06), 0.4))

	# Distal pulse indicator: a probe on the skin below the strap with a blinking light.
	_puck = Node3D.new()
	_puck.name = "PulseProbe"
	add_child(_puck)
	_mesh(_puck, _cyl(0.011, 0.007, 18), _mat(Color(0.85, 0.86, 0.88), 0.4), Transform3D(Basis(), Vector3(0, 0.0035, 0)))
	_led_mat = _unshaded(Color(0.2, 0.05, 0.05))
	_mesh(_puck, _cyl(0.0065, 0.002, 18), _led_mat, Transform3D(Basis(), Vector3(0, 0.0075, 0)))
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	tm.rings = 24
	tm.ring_segments = 4
	_ring_mat = _unshaded(Color(1.0, 0.25, 0.2, 0.0))
	_ring = _mesh(_puck, tm, _ring_mat, Transform3D(Basis().scaled(Vector3(0.012, 0.001, 0.012)), Vector3(0, 0.008, 0)))

	# Crank aids: a faint orbit ring round the rod and a cursor dot.
	var om := TorusMesh.new()
	om.inner_radius = 0.97
	om.outer_radius = 1.0
	om.rings = 48
	om.ring_segments = 4
	_orbit_mat = _unshaded(Color(0.85, 0.95, 1.0, 0.0))
	_orbit = _mesh(self, om, _orbit_mat)
	for i in 3:
		var a := TAU * float(i) / 3.0
		var arrow := _mesh(_orbit, PrismMesh.new(), _orbit_mat)
		# In ring units (the ring node is scaled): a small chevron pointing clockwise.
		arrow.transform = Transform3D(Basis(Vector3.UP, -a) * Basis(Vector3.RIGHT, -PI * 0.5) * Basis(Vector3.BACK, -PI * 0.5), Vector3(cos(a), 0, sin(a)))
		arrow.scale = Vector3(0.14, 0.2, 1.0)
	_dot = _mesh(self, SphereMesh.new(), _unshaded(Color(1, 1, 1, 0.85)), Transform3D(Basis().scaled(Vector3.ONE * 0.006), Vector3.ZERO))


func _build_decals() -> void:
	var x0 := infect_front - 0.035
	# Long enough to cover the whole seal paddle, so the body's own infection never shows past it.
	var x1 := infect_front + (0.24 if _seal else 0.15)
	# Tight across the limb so the torso beside it stays clean; the seal's paddle widens distally.
	var wz := (_sleeve_side() * 1.12 + (0.04 if _seal else 0.02)) * 2.0
	var h := 0.03 + half_up * 1.35
	# Deeper, with a short lower fade, so it also covers the sides of the limb, where the body's
	# own infection used to show through in its different style.
	var hi := 0.03 + half_up * 1.9
	_decal_infect = _decal(_infection_texture(x0, x1, wz), Vector3(x1 - x0, hi, wz), Vector3((x0 + x1) * 0.5, 0.03 - hi * 0.5, 0), 1)
	_decal_infect.lower_fade = 0.08
	var soft := _soft_texture(false)
	_decal_blanch = _decal(soft, Vector3(0.2, h, wz), Vector3.ZERO, 0)
	_decal_blanch.modulate = Color(0.62, 0.64, 0.68) if _seal else Color(0.96, 0.9, 0.86)
	_decal_purple = _decal(soft, Vector3(0.2, h, wz), Vector3.ZERO, 2)
	_decal_purple.modulate = Color(0.36, 0.1, 0.46)
	_decal_guide = _decal(_soft_texture(true), Vector3(band_half * 2.0 + 0.004, h, wz * 0.85), Vector3(infect_front - band_center, 0.03 - h * 0.5, 0), 3)
	_decal_guide.modulate = Color(0.05, 0.9, 0.3, 0.0)
	_decal_guide.emission_energy = 2.5
	_decal_guide.texture_emission = _decal_guide.texture_albedo
	# Plus two unshaded marker lines floating just over the skin, readable under any light.
	_guide_lines = Node3D.new()
	add_child(_guide_lines)
	_guide_mat = _unshaded(Color(0.2, 1.0, 0.4, 0.0))
	var gc := infect_front - band_center
	for gx in [gc - band_half, gc + band_half]:
		var path := PackedVector2Array()
		for i in 25:
			path.append(_section_point(lerpf(-1.2, 1.2, float(i) / 24.0), 0.0025))
		_mesh(_guide_lines, _ribbon(path, 0.0025, 0.0008), _guide_mat, Transform3D(Basis(), Vector3(gx, 0, 0)))


func _decal(tex: Texture2D, size: Vector3, pos: Vector3, order: int) -> Decal:
	var d := Decal.new()
	d.texture_albedo = tex
	d.size = size
	d.position = pos
	d.upper_fade = 0.05
	d.lower_fade = 0.35
	d.normal_fade = 0.0
	d.cull_mask = 1
	d.sorting_offset = float(order)
	add_child(d)
	return d


## The infection painted from above: u along +X (x0..x1), v across Z (-wz/2..wz/2).
func _infection_texture(x0: float, x1: float, wz: float) -> ImageTexture:
	# 128x80 (was 256x160): a quarter of the per-pixel noise work. It is a decal viewed from
	# half a metre with linear filtering, so the mottling reads the same.
	var w := 128
	var hh := 80
	var img := Image.create(w, hh, false, Image.FORMAT_RGBA8)
	var n1 := FastNoiseLite.new()
	n1.seed = int(_ph.x * 1000.0)
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n1.fractal_octaves = 4
	n1.frequency = 0.45
	var n2 := FastNoiseLite.new()
	n2.seed = int(_ph.y * 1000.0) + 7
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n2.fractal_octaves = 3
	n2.frequency = 1.6
	var n4 := FastNoiseLite.new()
	n4.seed = int(_ph.x * 777.0) + 3
	n4.noise_type = FastNoiseLite.TYPE_CELLULAR
	n4.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	n4.frequency = 0.55
	var n3 := FastNoiseLite.new()
	n3.seed = int(_ph.z * 1000.0) + 13
	n3.frequency = 2.5
	var side := _sleeve_side()
	for j in hh:
		var z := (float(j) + 0.5) / float(hh) * wz - wz * 0.5
		var th := asin(clampf(z / side, -1.0, 1.0))
		var jag := n3.get_noise_1d(z * 100.0) * 0.003
		var bnd := _b0 + _boundary_shape(th) + jag
		var zfade := 1.0 - smoothstep(wz * 0.5 - 0.012, wz * 0.5, absf(z))
		for i in w:
			var x := x0 + (float(i) + 0.5) / float(w) * (x1 - x0)
			var d := x - bnd
			var cx := x * 100.0
			var cz := z * 100.0
			var a1 := n1.get_noise_2d(cx, cz) * 0.5 + 0.5
			var a2 := n2.get_noise_2d(cx, cz) * 0.5 + 0.5
			var col := Color(0, 0, 0, 0)
			if d < 0.0:
				var flush := pow(smoothstep(-0.026, 0.0, d), 1.6) * (0.45 + 0.25 * a1)
				col = Color(0.78, 0.26, 0.2, flush)
				var streak := smoothstep(0.62, 0.9, n3.get_noise_2d(cz * 5.0, cx * 0.4) * 0.5 + 0.5) * smoothstep(-0.022, -0.004, d)
				if streak > 0.0:
					col = col.lerp(Color(0.55, 0.06, 0.07, 0.85), streak)
			else:
				var deep := smoothstep(0.003, 0.03, d + (a1 - 0.5) * 0.016)
				var margin := Color(0.52, 0.07, 0.09).lerp(Color(0.33, 0.06, 0.2), smoothstep(0.35, 0.7, a2))
				var necro := Color(0.28, 0.06, 0.18).lerp(Color(0.06, 0.025, 0.035), smoothstep(0.42, 0.68, a1))
				necro = necro.lerp(Color(0.3, 0.31, 0.18), smoothstep(0.7, 0.85, a2) * 0.75)
				col = margin.lerp(necro, deep)
				var spot := (1.0 - smoothstep(0.03, 0.09, n4.get_noise_2d(cx, cz) * 0.5 + 0.5)) * smoothstep(0.55, 0.7, a1)
				col = col.lerp(Color(0.62, 0.55, 0.22), spot * deep * 0.8)
				col.a = 1.0
				# A dark ridge right at the margin.
				col = col.lerp(Color(0.22, 0.02, 0.04, 1.0), (1.0 - smoothstep(0.0, 0.004, d)) * 0.6)
			col.a *= zfade * (1.0 - smoothstep(x1 - 0.045, x1, x))
			img.set_pixel(i, j, col)
	return ImageTexture.create_from_image(img)


## Soft-edged mask: a ramp in along +X (or a band with bright edges when `band`).
static var _soft_cache := {}

## Soft-edged masks never change, so they are built once per game session.
func _soft_texture(band: bool) -> ImageTexture:
	if _soft_cache.has(band):
		return _soft_cache[band]
	var tex := _make_soft_texture(band)
	_soft_cache[band] = tex
	return tex


func _make_soft_texture(band: bool) -> ImageTexture:
	var w := 64
	var hh := 32
	var img := Image.create(w, hh, false, Image.FORMAT_RGBA8)
	for j in hh:
		var v := (float(j) + 0.5) / float(hh)
		var vf := smoothstep(0.0, 0.15, v) * smoothstep(1.0, 0.85, v)
		for i in w:
			var u := (float(i) + 0.5) / float(w)
			var a: float
			if band:
				var edge := maxf(1.0 - smoothstep(0.0, 0.06, u), smoothstep(0.94, 1.0, u))
				a = 0.45 + 0.55 * edge
			else:
				a = smoothstep(0.0, 0.18, u) * smoothstep(1.0, 0.7, u)
			img.set_pixel(i, j, Color(1, 1, 1, a * vf))
	return ImageTexture.create_from_image(img)


func _gauge_mark(mat: Material, value: float, radius: float, size: Vector3) -> void:
	var phi := _gauge_angle(value)
	var basis := Basis(Vector3.UP, -phi)
	_mesh(_gauge_bands, _box(size), mat, Transform3D(basis, basis * Vector3(0, 0, -radius)))


func _gauge_angle(value: float) -> float:
	return lerpf(-0.75 * PI, 0.75 * PI, clampf(value / P_GAUGE_MAX, 0.0, 1.0))


## A flat strap with thickness following a (z, y) path; STRAP_W wide along X.
func _ribbon(path: PackedVector2Array, width: float, thick: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := path.size()
	var normals: Array[Vector2] = []
	for i in n:
		var a := path[maxi(0, i - 1)]
		var b := path[mini(n - 1, i + 1)]
		var tg := (b - a).normalized()
		normals.append(Vector2(-tg.y, tg.x))
	var hw := width * 0.5
	for i in n - 1:
		var p0 := path[i]
		var p1 := path[i + 1]
		var n0 := normals[i]
		var n1 := normals[i + 1]
		var o0 := p0 + n0 * thick * 0.5
		var o1 := p1 + n1 * thick * 0.5
		var i0 := p0 - n0 * thick * 0.5
		var i1 := p1 - n1 * thick * 0.5
		_quad(st, Vector3(-hw, o0.y, o0.x), Vector3(hw, o0.y, o0.x), Vector3(hw, o1.y, o1.x), Vector3(-hw, o1.y, o1.x), Vector3(0, n0.y, n0.x))
		_quad(st, Vector3(-hw, i1.y, i1.x), Vector3(hw, i1.y, i1.x), Vector3(hw, i0.y, i0.x), Vector3(-hw, i0.y, i0.x), Vector3(0, -n0.y, -n0.x))
		_quad(st, Vector3(hw, o0.y, o0.x), Vector3(hw, i0.y, i0.x), Vector3(hw, i1.y, i1.x), Vector3(hw, o1.y, o1.x), Vector3.RIGHT)
		_quad(st, Vector3(-hw, o1.y, o1.x), Vector3(-hw, i1.y, i1.x), Vector3(-hw, i0.y, i0.x), Vector3(-hw, o0.y, o0.x), Vector3.LEFT)
	return st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3) -> void:
	st.set_normal(nrm)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


func _rebuild_strap(w: float, squeeze: float) -> void:
	if absf(w - _built_wrap) < 0.01 and absf(squeeze - _built_sq) < 0.0004:
		return
	_built_wrap = w
	_built_sq = squeeze
	var off := lerpf(0.016, 0.0045, w) - squeeze
	var span := lerpf(1.95, PI + 0.35, w)
	var path := PackedVector2Array()
	var segs := 56
	for i in segs + 1:
		var th := lerpf(-span, span if w < 0.999 else PI + 0.35, float(i) / float(segs))
		if w >= 0.999:
			th = lerpf(-PI, PI + 0.35, float(i) / float(segs))
		var grow := 0.0035 * float(i) / float(segs) * w
		path.append(_section_point(th, off + grow))
	# Tails hang off both sides while the strap is open.
	var tail := (1.0 - w)
	if tail > 0.02:
		var head := PackedVector2Array()
		var p := path[0]
		var dir := (path[0] - path[1]).normalized()
		for k in 8:
			dir = dir.lerp(Vector2(0, -1), 0.3).normalized()
			p += dir * 0.07 * tail / 8.0
			head.append(p)
		head.reverse()
		var full := head
		full.append_array(path)
		p = path[path.size() - 1]
		dir = (path[path.size() - 1] - path[path.size() - 2]).normalized()
		for k in 10:
			dir = dir.lerp(Vector2(0.15, -1), 0.3).normalized()
			p += dir * 0.1 * tail / 10.0
			full.append(p)
		path = full
	_strap_mesh.mesh = _ribbon(path, STRAP_W, 0.0028)
	var vpath := PackedVector2Array()
	for i in 25:
		vpath.append(_section_point(lerpf(-0.9, 0.9, float(i) / 24.0), off + 0.0018 + 0.0035 * w))
	_velcro_mesh.mesh = _ribbon(vpath, STRAP_W * 0.62, 0.0012)
	var end := path[path.size() - 1]
	_tab.position = Vector3(0, end.y, end.x)
	_windlass.position = Vector3(0, off + 0.0014 + 0.0035 * w * 0.5, 0)


func _update_visuals(delta: float) -> void:
	if not _built:
		return
	var k := clampf(delta * 14.0, 0.0, 1.0)
	_vis_x = strap_x if delta <= 0.0 else lerpf(_vis_x, strap_x, clampf(delta * 30.0, 0.0, 1.0))
	var wrapping := stage != Stage.PLACE
	_wrap = move_toward(_wrap, 1.0 if wrapping else 0.0, delta / WRAP_TIME if delta > 0.0 else 1.0)
	_stand = move_toward(_stand, 1.0 if (wrapping and _wrap >= 1.0 and stage == Stage.CRANK) else 0.0, delta * 4.0)
	_lock_vis = move_toward(_lock_vis, 1.0 if stage == Stage.LOCKED else 0.0, delta * 5.0)
	var we := _wrap * _wrap * (3.0 - 2.0 * _wrap)
	var tight := clampf(pressure / P_GAUGE_MAX, 0.0, 1.0)
	_rebuild_strap(we, 0.002 * tight * we)

	# Strap placement, sway while held, slipping off after a bad cinch.
	var sway_target := 0.0
	if stage == Stage.PLACE and slip <= 0.0:
		sway_target = clampf((strap_x - _vis_x) * 30.0, -0.35, 0.35)
	_sway = lerpf(_sway, sway_target, k)
	var pos := Vector3(_vis_x, 0.0, 0.0)
	var rot := Vector3(sin(_t * 1.7) * 0.03 * (1.0 - we), 0.0, -_sway)
	_strap_root.visible = true
	if stage == Stage.PLACE:
		pos.y = 0.004 + sin(_t * 2.1) * 0.0015
		if slip > 0.0:
			var s := slip
			pos.x += s * s * 0.09
			pos.y += 0.01 * sin(s * PI) - s * 0.02
			rot.z = -s * 0.5
			rot.x = s * 0.3
			_strap_root.visible = s < 0.9
	_strap_root.position = pos
	_strap_root.rotation = rot

	# Windlass rod: stands up to crank, snaps into the clip when locked.
	var lift := lerpf(0.0065, 0.017, _stand)
	var vis_angle := rod_angle
	if _lock_vis > 0.0:
		var snap_to: float = roundf(rod_angle / PI) * PI
		vis_angle = lerpf(rod_angle, snap_to, _lock_vis)
		lift = lerpf(lift, 0.012, _lock_vis)
	_rod_pivot.position = Vector3(0, lift, 0)
	_rod_pivot.rotation = Vector3(0, -vis_angle, 0)
	_twist.scale = Vector3(1.0 + 0.25 * tight, maxf(0.001, lift), 1.0 - 0.3 * tight)
	_twist.position = Vector3(0, -lift * 0.5, 0)
	_twist.visible = _stand > 0.05 or _lock_vis > 0.0

	# Gauge and tube appear once the strap is round the limb.
	var show_crank := stage != Stage.PLACE and _wrap > 0.6
	_gauge.visible = show_crank
	_tube.visible = show_crank
	_puck.visible = show_crank
	if show_crank:
		var gz := _sleeve_side() + 0.055
		_gauge.position = Vector3(strap_x, -half_up * 0.35, gz)
		_needle.rotation = Vector3(0, -_gauge_angle(pressure), 0)
		_gauge_label.text = "%d mmHg" % int(round(pressure))
		var a := _section_point(PI * 0.5, 0.006)
		var from := Vector3(strap_x, a.y, a.x)
		var to := _gauge.position + Vector3(0, 0, -0.028)
		var mid := (from + to) * 0.5
		var dir := to - from
		_tube.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir.normalized())).scaled_local(Vector3(1, dir.length(), 1)), mid)
		# Pulse probe below the strap, on the near side of the limb.
		var th := -0.45
		var sp := _section_point(th, 0.0)
		var nrm := _section_normal(th)
		_puck.position = Vector3(strap_x + 0.05, sp.y, sp.x)
		_puck.rotation = Vector3(atan2(nrm.x, nrm.y), 0, 0)
		var pulse := pulse_strength()
		var beat := fmod(_t * 1.25, 1.0)
		var env := exp(-beat * 7.0)
		var lit := pulse * env
		_led_mat.albedo_color = Color(0.25, 0.08, 0.08).lerp(Color(1.0, 0.2, 0.15), lit) if pulse > 0.02 else Color(0.22, 0.22, 0.24)
		var rs := 0.012 + beat * 0.03
		_ring.scale = Vector3(rs, 0.001, rs)
		_ring_mat.albedo_color = Color(1.0, 0.3, 0.25, pulse * (1.0 - beat) * 0.8)
		# Limb shader: blanch as blood stops, purple past the band.
		var hx := _decal_blanch.size.x
		var dpos := Vector3(strap_x + STRAP_W * 0.5 + 0.002 + hx * 0.5, _decal_infect.position.y, 0)
		_decal_blanch.position = dpos
		_decal_purple.position = dpos
		_decal_blanch.modulate.a = 0.6 * smoothstep(good_min * 0.3, good_min, pressure) * we
		_decal_purple.modulate.a = 0.6 * smoothstep(good_max, good_max + 70.0, pressure) * we
	_decal_blanch.visible = show_crank
	_decal_purple.visible = show_crank
	_guide_a = move_toward(_guide_a, 1.0 if (guide and stage == Stage.PLACE) else 0.0, maxf(delta, 0.0) * 2.5)
	_decal_guide.modulate.a = _guide_a
	_decal_guide.visible = _guide_a > 0.01
	_guide_mat.albedo_color.a = _guide_a * 0.85
	_guide_lines.visible = _guide_a > 0.01

	# Crank aids.
	var orbit_on := stage == Stage.CRANK and _stand > 0.5
	var oa := move_toward(_orbit_mat.albedo_color.a, 0.35 if orbit_on else 0.0, maxf(delta, 0.0) * 2.0)
	_orbit_mat.albedo_color = Color(0.85, 0.95, 1.0, oa)
	_orbit.visible = oa > 0.01
	_orbit.transform = Transform3D(Basis().scaled(Vector3(0.05, 1.0, 0.05)), Vector3(strap_x, 0.03, 0))
	_orbit.rotation = Vector3(0, -_t * 0.6, 0)
	_orbit.scale = Vector3(0.05, 1.0, 0.05)
	_dot.visible = ctx.get("operator", false) and stage == Stage.CRANK
	_dot.position = Vector3(cursor.x, 0.03, cursor.y)


func _sounds(delta: float) -> void:
	var at = global_position if is_inside_tree() else null
	_snd_click_cd = maxf(0.0, _snd_click_cd - delta)
	if _snd_first:
		_snd_first = false
		_snd_stage = stage
		_snd_click = int(floor(rod_angle / (TAU / 32.0)))
		_audio("surgery_tourniquet_swish", at, -6.0, 0.05)
		return
	if stage != _snd_stage:
		if stage == Stage.CRANK:
			_audio("surgery_tourniquet_cinch", at, -2.0)
		elif stage == Stage.LOCKED:
			_audio("surgery_tourniquet_lock", at, 0.0)
		_snd_stage = stage
	var slipping := slip > 0.0
	if slipping != _snd_slip:
		_audio("surgery_tourniquet_swish", at, -4.0 if slipping else -8.0, 0.1)
		_snd_slip = slipping
	# One eighth of a cursor circle is a 32nd of a rod turn.
	var ci := int(floor(rod_angle / (TAU / 32.0)))
	if ci != _snd_click and stage == Stage.CRANK:
		if _snd_click_cd <= 0.0:
			_audio("surgery_tourniquet_ratchet", at, -4.0, 0.06)
			_snd_click_cd = 0.04
		_snd_click = ci
	var cr := int(floor(maxf(0.0, pressure - 60.0) / 55.0))
	if cr > _snd_creak and stage == Stage.CRANK:
		_audio("surgery_tourniquet_creak", at, -8.0 + 4.0 * clampf(pressure / P_GAUGE_MAX, 0.0, 1.0), 0.08)
	_snd_creak = cr


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var ml = Engine.get_main_loop()
	var a = ml.root.get_node_or_null("Audio") if ml is SceneTree else null
	if a != null:
		a.play(cue, at, vol, jitter)
