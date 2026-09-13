extends "res://scripts/surgery/minigame.gd"
## Step "sedate": draw the right dose into a syringe, then inject it into a vein.
##
## DRAW   hold primary to pull the plunger back; right button pushes it back down.
##        Let go for COMMIT_TIME with something drawn and the dose locks in.
##        The green sleeve on the barrel is the dose band: about 0.05 ml per kg.
## INJECT move the needle tip onto the vein marker and hold primary. The steadiness
##        ring shrinks while the tip stays within tolerance; the marker drifts.
##        Sliding off the vein with the needle in botches a little.
## Result {"sedation": s}: 1.0 for a good dose, < 0.75 a clear underdose (the patient
## stirs in later steps), > 1.25 an overdose that also botches vitals.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Stage { DRAW, INJECT, DONE }

const BARREL_ML := 10.0
const ML_PER_KG := 0.05
const DRAW_RATE := 2.0         # ml per second while pulling
const PUSH_RATE := 1.4         # ml per second while pushing back
const COMMIT_TIME := 0.9       # seconds released before the dose locks in
const MIN_COMMIT_ML := 0.5
const HOLD_TIME := 2.0         # seconds on the vein to inject

# Syringe geometry (metres, in the syringe's own frame: needle tip at the origin, body along +X).
const NEEDLE_LEN := 0.05
const HUB_LEN := 0.012
const BARREL_LEN := 0.13       # length of the 10 ml scale
const BARREL_R := 0.0125
const B0 := NEEDLE_LEN + HUB_LEN

var stage: int = Stage.DRAW
var volume: float = 0.0        # ml in the barrel
var dose: float = 0.0          # ml locked in
var sedation: float = 1.0
var hold: float = 0.0          # seconds of injection
var cursor := Vector2(0.06, 0.06)
var pressing := false
var inserted := false
var vein := Vector2.ZERO

var target_ml := 4.0
var band_half := 0.6
var tolerance := 0.016
var drift := 0.012

var _commit := 0.0
var _need_release := false
var _prev_primary := false
var _off_time := 0.0
var _wobble_cd := 0.0
var _miss_cd := 0.0
var _t := 0.0
var _flash := 0.0
var _phase := Vector2.ZERO

# visuals
var _syringe: Node3D
var _liquid: MeshInstance3D
var _stopper: Node3D
var _vial: Node3D
var _band: MeshInstance3D
var _vein_root: Node3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _dot: MeshInstance3D
var _syr_xform := Transform3D()
var _snd_draw := 0.0
var _last_vol := 0.0
var _last_stage := -1
var _last_inserted := false
var _inject_snd := 0.0

# bot
var _bt := 0.0
var _bc := Vector2(0.12, 0.1)
var _bot_over := false
var _bot_inject_t := -1.0


func setup(context: Dictionary) -> void:
	super.setup(context)
	var weight := float(ctx.get("patient", {}).get("weight_kg", 80.0))
	var diff := maxf(0.5, float(ctx.get("difficulty", 1.0)))
	target_ml = clampf(weight * ML_PER_KG, 1.0, BARREL_ML - 1.5)
	band_half = 0.6 / diff
	tolerance = 0.016 / diff
	drift = 0.011 * diff
	var rng := RandomNumberGenerator.new()
	rng.seed = int(ctx.get("seed", 1))
	_phase = Vector2(rng.randf() * TAU, rng.randf() * TAU)
	_build()
	_update_visuals(0.0, true)


func plane_extent() -> Vector2:
	return Vector2(0.24, 0.16)


func camera_pose() -> Dictionary:
	return {"height": 0.46, "back": 0.16, "fov": 55.0}


# ---------------------------------------------------------------------------- rules

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	cursor = p
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var secondary := (buttons & BUTTON_SECONDARY) != 0
	_wobble_cd = maxf(0.0, _wobble_cd - delta)
	_miss_cd = maxf(0.0, _miss_cd - delta)
	match stage:
		Stage.DRAW:
			pressing = primary
			if primary:
				volume = minf(BARREL_ML, volume + DRAW_RATE * delta)
				_commit = 0.0
			elif secondary:
				volume = maxf(0.0, volume - PUSH_RATE * delta)
				_commit = 0.0
			elif volume >= MIN_COMMIT_ML:
				_commit += delta
				if _commit >= COMMIT_TIME:
					_lock_dose()
			progress = 0.35 * clampf(volume / target_ml, 0.0, 1.0)
		Stage.INJECT:
			if _need_release:
				if not primary:
					_need_release = false
				primary = false
			pressing = primary
			var dist := p.distance_to(vein)
			if primary and not _prev_primary:
				if dist > tolerance * 2.5 and _miss_cd <= 0.0:
					botch(2.5, "Missed the vein")
					_miss_cd = 0.6
					_flash = 0.4
				elif dist <= tolerance:
					inserted = true
			if primary and inserted:
				if dist <= tolerance:
					hold += delta
					_off_time = 0.0
				else:
					_off_time += delta
					hold = maxf(0.0, hold - delta * 0.8)
					if _off_time > 0.12:
						inserted = false
						hold = maxf(0.0, hold - 0.3)
						if _wobble_cd <= 0.0:
							botch(2.5, "The needle slid off the vein")
							_wobble_cd = 0.8
							_flash = 0.4
			elif primary and dist <= tolerance:
				inserted = true
			else:
				if not primary:
					inserted = false
				hold = maxf(0.0, hold - delta * 0.25)
			progress = 0.4 + 0.6 * clampf(hold / HOLD_TIME, 0.0, 1.0)
			if hold >= HOLD_TIME:
				_complete()
	_prev_primary = (buttons & BUTTON_PRIMARY) != 0


func _lock_dose() -> void:
	dose = volume
	var ratio := dose / target_ml
	sedation = ratio
	if absf(dose - target_ml) <= band_half:
		sedation = 1.0 + (ratio - 1.0) * 0.35
	sedation = clampf(sedation, 0.0, 2.0)
	stage = Stage.INJECT
	_need_release = true
	hold = 0.0
	progress = 0.4


func _complete() -> void:
	stage = Stage.DONE
	pressing = false
	inserted = false
	if sedation > 1.25:
		botch(4.0 + (sedation - 1.25) * 30.0, "Overdose: the patient's blood pressure crashed")
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_sedation"):
		body.set_sedation(clampf(sedation, 0.0, 1.0))
	finish({"sedation": snappedf(sedation, 0.01)})


func tick(delta: float) -> void:
	_t += delta
	_flash = maxf(0.0, _flash - delta)
	# The vein wanders a little: the arm breathes and the patient twitches.
	vein = Vector2(sin(_t * 0.8 + _phase.x) * drift, sin(_t * 1.13 + _phase.y) * drift * 0.6)
	_update_visuals(delta, false)
	_sounds(delta)


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Sedate the patient"))
	var hint := ""
	var gauges := []
	match stage:
		Stage.DRAW:
			if volume > target_ml + band_half:
				hint = "Too much. Right-click to push the plunger back into the green band."
			elif volume >= MIN_COMMIT_ML and not pressing and _commit > 0.0:
				hint = "Locking in %.1f ml..." % volume
			else:
				hint = "Hold left click to draw anesthetic. Release inside the green band (%.1f ml)." % target_ml
			gauges.append({"label": "Dose ml", "value": volume, "min": 0.0, "max": BARREL_ML,
				"good_min": target_ml - band_half, "good_max": target_ml + band_half})
		Stage.INJECT:
			if _need_release:
				hint = "Dose locked: %.1f ml. Release the button." % dose
			elif inserted:
				hint = "Hold steady. Keep the needle on the vein."
			else:
				hint = "Put the needle tip on the blue vein marker and hold left click."
			gauges.append({"label": "Steady", "value": clampf(1.0 - cursor.distance_to(vein) / (tolerance * 3.0), 0.0, 1.0),
				"min": 0.0, "max": 1.0, "good_min": 0.667, "good_max": 1.0})
			gauges.append({"label": "Injected", "value": hold / HOLD_TIME, "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 1.0})
			gauges.append({"label": "Dose", "value": sedation, "min": 0.0, "max": 2.0, "good_min": 0.75, "good_max": 1.25})
		Stage.DONE:
			hint = "Sedated (%.2f)." % sedation if sedation >= 0.75 and sedation <= 1.25 else \
				("Underdosed: expect the patient to stir." if sedation < 0.75 else "Overdosed.")
	return {"title": title, "hint": hint, "progress": progress, "gauges": gauges}


func net_state() -> Dictionary:
	return {"s": stage, "v": snappedf(volume, 0.01), "d": snappedf(dose, 0.01), "se": snappedf(sedation, 0.001),
		"h": snappedf(hold, 0.01), "c": cursor, "b": pressing, "i": inserted, "p": progress}


func apply_net_state(s: Dictionary) -> void:
	stage = int(s.get("s", stage))
	volume = float(s.get("v", volume))
	dose = float(s.get("d", dose))
	sedation = float(s.get("se", sedation))
	hold = float(s.get("h", hold))
	cursor = s.get("c", cursor)
	pressing = bool(s.get("b", pressing))
	inserted = bool(s.get("i", inserted))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := 1.0 - skill
	var buttons := 0
	match stage:
		Stage.DRAW:
			# A good surgeon stops just short (the release lag lands it on target);
			# a sloppy one overshoots, pushes back, and settles near the band's edge.
			var aim := target_ml - 0.05 + sloppy * 2.6
			var settle := target_ml + 1.7 * sloppy
			if not _bot_over and volume < aim:
				buttons = BUTTON_PRIMARY
			else:
				_bot_over = true
				if volume > settle + 0.02 and volume > target_ml + 0.05:
					buttons = BUTTON_SECONDARY
		Stage.INJECT:
			if _bot_inject_t < 0.0:
				_bot_inject_t = t
			# Even a sloppy hand settles down after a while, so the step always ends.
			var settle_k := clampf(1.0 - (t - _bot_inject_t) / 20.0, 0.3, 1.0)
			var wobble := Vector2(sin(t * 2.3) + 0.6 * sin(t * 5.1 + 1.0), cos(t * 1.9) + 0.5 * sin(t * 4.3)) * 0.02 * sloppy * settle_k
			var want := vein + wobble
			var speed := lerpf(0.18, 0.6, skill)
			_bc = _bc.move_toward(want, speed * dt) if _bc.distance_to(want) > 0.002 else _bc.lerp(want, clampf(dt * lerpf(4.0, 25.0, skill), 0.0, 1.0))
			var close := _bc.distance_to(vein) <= tolerance * lerpf(1.6, 0.7, skill)
			if close or inserted:
				buttons = BUTTON_PRIMARY
			return {"cursor": _bc, "buttons": buttons}
	return {"cursor": _bc, "buttons": buttons}


# ---------------------------------------------------------------------------- visuals

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
	m.no_depth_test = false
	return m


## A cylinder lying along +X from x0 to x1.
func _rod(parent: Node3D, x0: float, x1: float, r: float, mat: Material, sides := 16) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = 1.0
	c.radial_segments = sides
	c.rings = 1
	mi.mesh = c
	mi.material_override = mat
	mi.rotation_degrees = Vector3(0, 0, -90)
	mi.scale = Vector3(1, maxf(0.0005, x1 - x0), 1)
	mi.position = Vector3((x0 + x1) * 0.5, 0, 0)
	parent.add_child(mi)
	return mi


func _build() -> void:
	# The anesthetic vial, lying on its side with its cap toward the syringe.
	_vial = Node3D.new()
	_vial.name = "Vial"
	var model: Node3D = ItemModelsScript.make("anesthetic", 1)
	model.scale = Vector3.ONE * 1.7
	_vial.add_child(model)
	add_child(_vial)

	_syringe = Node3D.new()
	_syringe.name = "Syringe"
	add_child(_syringe)
	var steel := _mat(Color(0.85, 0.87, 0.9), 0.2, 1.0)
	var glass := _mat(Color(0.85, 0.93, 1.0, 0.28), 0.05)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.rim_enabled = true
	glass.rim = 0.6
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var plastic := _mat(Color(0.95, 0.95, 0.93), 0.45)
	var rubber := _mat(Color(0.12, 0.12, 0.13), 0.8)
	var liquid := _mat(Color(1.0, 0.8, 0.25), 0.2)
	liquid.emission_enabled = true
	liquid.emission = Color(0.9, 0.62, 0.12)
	liquid.emission_energy_multiplier = 0.7

	_rod(_syringe, 0.0, NEEDLE_LEN, 0.0012, steel, 6)
	_rod(_syringe, NEEDLE_LEN, B0, 0.004, _mat(Color(0.2, 0.55, 0.85), 0.5), 10)
	var barrel_end := B0 + BARREL_LEN + 0.012
	_rod(_syringe, B0 - 0.004, barrel_end, BARREL_R, glass, 20)
	# Finger flange
	var flange := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(0.004, 0.006, 0.055)
	flange.mesh = fb
	flange.material_override = plastic
	flange.position = Vector3(barrel_end, 0, 0)
	_syringe.add_child(flange)
	_liquid = _rod(_syringe, B0, B0 + 0.001, BARREL_R * 0.86, liquid, 16)
	# Graduations every ml, longer every 5, with numbers for 5 and 10.
	var tick_mat := _unshaded(Color(0.1, 0.12, 0.14))
	for i in range(1, 11):
		var tk := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.0011, 0.0006, 0.016 if i % 5 == 0 else 0.009)
		tk.mesh = tb
		tk.material_override = tick_mat
		tk.position = Vector3(B0 + BARREL_LEN * i / BARREL_ML, BARREL_R + 0.0004, -BARREL_R * 0.25)
		_syringe.add_child(tk)
		if i % 5 == 0:
			var lab := Label3D.new()
			lab.text = str(i)
			lab.font_size = 36
			lab.pixel_size = 0.00028
			lab.modulate = Color(0.05, 0.05, 0.06)
			lab.outline_size = 0
			lab.rotation_degrees = Vector3(-90, 0, 0)
			lab.position = Vector3(B0 + BARREL_LEN * i / BARREL_ML, BARREL_R + 0.001, -BARREL_R - 0.006)
			_syringe.add_child(lab)
	# The dose band: a green sleeve over the barrel.
	_band = MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(1, 0.0008, BARREL_R * 2.0 + 0.008)
	_band.mesh = bb
	_band.material_override = _unshaded(Color(0.25, 1.0, 0.45, 0.45))
	var x0 := B0 + BARREL_LEN * clampf(target_ml - band_half, 0.0, BARREL_ML) / BARREL_ML
	var x1 := B0 + BARREL_LEN * clampf(target_ml + band_half, 0.0, BARREL_ML) / BARREL_ML
	_band.scale = Vector3(x1 - x0, 1, 1)
	_band.position = Vector3((x0 + x1) * 0.5, BARREL_R + 0.0012, 0)
	_syringe.add_child(_band)
	# Plunger: black stopper, a rod, a thumb disc. Moves as one.
	_stopper = Node3D.new()
	_syringe.add_child(_stopper)
	_rod(_stopper, -0.006, 0.0, BARREL_R * 0.95, rubber, 16)
	var cross := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(BARREL_LEN + 0.03, 0.004, 0.012)
	cross.mesh = cb
	cross.material_override = plastic
	cross.position = Vector3((BARREL_LEN + 0.03) * 0.5, 0, 0)
	_stopper.add_child(cross)
	var thumb := _rod(_stopper, BARREL_LEN + 0.03, BARREL_LEN + 0.034, 0.016, plastic, 16)
	thumb.name = "Thumb"

	# The vein and the steadiness ring.
	_vein_root = Node3D.new()
	add_child(_vein_root)
	var line := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(0.16, 0.0015, 0.005)
	line.mesh = lb
	line.material_override = _unshaded(Color(0.25, 0.35, 0.95, 0.75))
	line.position = Vector3(0, 0.002, 0)
	line.name = "VeinLine"
	_vein_root.add_child(line)
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.0
	tm.rings = 32
	tm.ring_segments = 4
	_ring.mesh = tm
	_ring_mat = _unshaded(Color(1.0, 0.75, 0.2, 0.9))
	_ring.material_override = _ring_mat
	_vein_root.add_child(_ring)
	_dot = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.0035
	sm.height = 0.007
	_dot.mesh = sm
	_dot.material_override = _unshaded(Color(0.35, 0.55, 1.0))
	_vein_root.add_child(_dot)


func _update_visuals(delta: float, snap: bool) -> void:
	if _syringe == null:
		return
	# Plunger and liquid follow the volume in the barrel; injecting empties it.
	var shown := volume
	if stage == Stage.INJECT:
		shown = dose * (1.0 - clampf(hold / HOLD_TIME, 0.0, 1.0))
	elif stage == Stage.DONE:
		shown = 0.0
	var sx := B0 + BARREL_LEN * shown / BARREL_ML
	_stopper.position = Vector3(sx, 0, 0)
	_liquid.visible = shown > 0.02
	_liquid.scale = Vector3(1, maxf(0.0005, sx - 0.006 - B0), 1)
	_liquid.position = Vector3((B0 + sx - 0.006) * 0.5, 0, 0)
	_band.visible = stage == Stage.DRAW

	var target := Transform3D()
	var vial_target := Transform3D()
	if stage == Stage.DRAW:
		# Horizontal, needle in the vial's cap, laid out across the view.
		var tip := Vector3(-0.1, 0.028, 0.04)
		target = Transform3D(Basis(), tip)
		# Vial on its side: its +Y (base to cap) points along +X toward the needle.
		var cap_len := 0.062 * 1.7
		vial_target = Transform3D(Basis(Vector3(0, 0, 1), -PI / 2), tip + Vector3(-cap_len + 0.012, 0, 0))
	else:
		# The needle tip rides the cursor, body tilted up off the skin.
		var press_lift := 0.0 if (pressing and inserted) else (0.004 if pressing else 0.012)
		var tip2 := plane_to_local(cursor, 0.002 + press_lift)
		target = Transform3D(Basis(Vector3(0, 1, 0), 0.35) * Basis(Vector3(0, 0, 1), deg_to_rad(24)), tip2)
		# Set down on its side next to the injection site.
		vial_target = Transform3D(Basis(Vector3(0, 1, 0), 0.5) * Basis(Vector3(0, 0, 1), -PI / 2), Vector3(-0.17, 0.024, -0.05))
		if stage == Stage.DONE:
			target = Transform3D(Basis(Vector3(0, 1, 0), 0.35) * Basis(Vector3(0, 0, 1), deg_to_rad(10)), plane_to_local(Vector2(0.13, 0.09), 0.02))
	var k := 1.0 if snap else clampf(delta * 14.0, 0.0, 1.0)
	_syr_xform = _syr_xform.interpolate_with(target, k)
	_syringe.transform = _syr_xform
	_vial.transform = _vial.transform.interpolate_with(vial_target, 1.0 if snap else clampf(delta * 6.0, 0.0, 1.0))

	# Vein marker: only meaningful once injecting, faintly visible while drawing.
	_vein_root.visible = stage != Stage.DONE
	_vein_root.position = plane_to_local(vein, 0.004)
	var frac := clampf(hold / HOLD_TIME, 0.0, 1.0)
	var r := lerpf(0.045, tolerance, frac)
	_ring.scale = Vector3(r, 0.004, r) if stage == Stage.INJECT else Vector3(0.03, 0.004, 0.03)
	var on := stage == Stage.INJECT and cursor.distance_to(vein) <= tolerance
	var col := Color(1.0, 0.75, 0.2, 0.9)
	if stage == Stage.DRAW:
		col = Color(0.5, 0.6, 1.0, 0.35)
	elif _flash > 0.0:
		col = Color(1.0, 0.2, 0.15, 1.0)
	elif on and inserted:
		col = Color(0.3, 1.0, 0.45, 1.0)
	elif on:
		col = Color(0.75, 1.0, 0.5, 0.9)
	_ring_mat.albedo_color = col
	_dot.position = Vector3(0, 0.001, 0)


func _sounds(delta: float) -> void:
	var at = global_position if is_inside_tree() else null
	if stage == Stage.DRAW and volume > _last_vol + 0.001:
		_snd_draw -= delta
		if _snd_draw <= 0.0:
			_snd_draw = 0.3
			_audio("surgery_draw", at, -6.0, 0.05)
	else:
		_snd_draw = 0.0
	if stage != _last_stage and _last_stage != -1:
		_audio("surgery_click", at, -2.0)
		if stage == Stage.DONE:
			_audio("surgery_done", at, -4.0)
	if inserted and not _last_inserted:
		_audio("surgery_needle", at, -2.0)
	if inserted and stage == Stage.INJECT:
		_inject_snd -= delta
		if _inject_snd <= 0.0:
			_inject_snd = 0.6
			_audio("surgery_inject", at, -10.0, 0.04)
	else:
		_inject_snd = 0.0
	_last_vol = volume
	_last_stage = stage
	_last_inserted = inserted


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var a = Engine.get_main_loop().root.get_node_or_null("Audio") if Engine.get_main_loop() else null
	if a != null:
		a.play(cue, at, vol, jitter)
