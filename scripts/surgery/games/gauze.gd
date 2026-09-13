extends "res://scripts/surgery/minigame.gd"
## Step "dress": gauze. Two variants from ctx.variant.
##
## pack  (gunshot)    PACK: click over the wound to stuff gauze in while the bleeding
##                    meter climbs on its own. Clicking off the wound botches; letting the
##                    meter fill botches. Then WRAP.
## stump (amputation) WRAP only, around the cut limb, over more turns.
##
## WRAP: hold left click and circle the cursor around the site in one direction. The
## tension gauge is how fast you go round: too slow is loose (counts for less), too fast
## is too tight (botches). Going backwards or getting jolted slips the bandage (botches).
## Result {"dressed": true}.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Stage { PACK, WRAP, DONE }

const WOUND_R := 0.03
const ACCEPT_R := 0.05
const PACK_CLICKS := 12
const MIN_CLICK_GAP := 0.09
const BLEED_RISE := 0.07          # per second, times difficulty
const BLEED_PER_CLICK := 0.075
const WRAP_R_MIN := 0.035
const WRAP_R_MAX := 0.24
const GOOD_MIN_TPS := 0.45        # turns per second
const GOOD_MAX_TPS := 1.5
const JOLT_DIST := 0.06           # a cursor jump this big in one frame while wrapping is a jolt

var variant := "pack"
var stage: int = Stage.PACK
var packed: float = 0.0           # 0..1
var bleed: float = 0.5            # 0..1
var wrapped: float = 0.0          # radians wound in the chosen direction
var wrap_dir: int = 0             # +1 / -1 once chosen
var tension: float = 0.0          # turns per second, smoothed
var cursor := Vector2(0.12, 0.1)
var pressing := false

var turns_needed := 3.0
var good_max := GOOD_MAX_TPS
var diff := 1.0
var site_name := "gunshot"
var limb_r := 0.05
var limb_hu := 0.05               # limb section half height / half width at the cut, and its axis depth
var limb_hs := 0.05
var limb_axis_y := -0.05

var _prev_primary := false
var _last_click := -1.0
var _t := 0.0
var _prev_angle := 0.0
var _prev_valid := false
var _prev_cursor := Vector2.ZERO
var _dir_accum := 0.0
var _slip_accum := 0.0
var _slip_cd := 0.0
var _tight_time := 0.0
var _miss_cd := 0.0
var _flash := 0.0
var _press_anim := 0.0

# visuals
var _rolls: Node3D
var _roll_count := -1
var _blood: MeshInstance3D
var _blood_mat: StandardMaterial3D
var _wads: Array = []
var _pad: Node3D
var _ribbon: MeshInstance3D
var _ribbon_built := -1.0
var _feed: Node3D
var _guide: MeshInstance3D
var _guide_mat: StandardMaterial3D
var _cloth: StandardMaterial3D
var _last_stage := -1
var _last_packed := 0.0
var _swish_at := 0.0

# bot
var _bt := 0.0
var _bot_angle := 0.0
var _bot_wrap_t := -1.0


func setup(context: Dictionary) -> void:
	super.setup(context)
	variant = String(ctx.get("variant", "pack"))
	if variant == "":
		variant = "pack"
	diff = maxf(0.5, float(ctx.get("difficulty", 1.0)))
	site_name = String(ctx.get("step", {}).get("site", "limb_cut" if variant == "stump" else "gunshot"))
	limb_r = float(ctx.get("patient", {}).get("limb_radius_m", 0.05))
	limb_hu = limb_r
	limb_hs = limb_r
	limb_axis_y = -limb_r
	_probe_limb()
	var flags: Dictionary = ctx.get("flags", {})
	good_max = GOOD_MAX_TPS / sqrt(diff)
	if variant == "stump":
		stage = Stage.WRAP
		turns_needed = ceilf(5.0 * sqrt(diff))
		# A weak tourniquet leaves the stump bleeding.
		bleed = clampf(0.85 - 0.75 * float(flags.get("tourniquet", 1.0)), 0.1, 0.8)
	else:
		stage = Stage.PACK
		turns_needed = ceilf(3.0 * sqrt(diff))
		bleed = 0.5 if flags.get("bullet_removed", true) else 0.7
	_build()
	_update_visuals(0.0)


## The patient body may expose its stump overlay; if so, wrap around its real section.
func _probe_limb() -> void:
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or not ("parts" in body):
		return
	var parts = body.get("parts")
	if not (parts is Dictionary) or not parts.has("stump") or not (parts["stump"] is Node3D):
		return
	var rim := (parts["stump"] as Node3D).get_node_or_null("Rim") as Node3D
	if rim == null:
		return
	var sc := rim.transform.basis.get_scale()
	if sc.x > 0.01 and sc.x < 0.3 and sc.z > 0.01 and sc.z < 0.3:
		limb_hu = sc.x
		limb_hs = sc.z
		limb_axis_y = rim.transform.origin.y


func plane_extent() -> Vector2:
	return Vector2(0.25, 0.17)


func camera_pose() -> Dictionary:
	return {"height": 0.5, "back": 0.17, "fov": 55.0}


func _wrap_frac() -> float:
	return clampf(wrapped / (turns_needed * TAU), 0.0, 1.0)


# ---------------------------------------------------------------------------- rules

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var jump := p.distance_to(cursor)
	cursor = p
	pressing = primary
	_slip_cd = maxf(0.0, _slip_cd - delta)
	_miss_cd = maxf(0.0, _miss_cd - delta)
	match stage:
		Stage.PACK:
			_pack(p, primary, delta)
		Stage.WRAP:
			_wrap(p, primary, jump, delta)
	_prev_primary = primary
	_update_progress()


func _pack(p: Vector2, primary: bool, delta: float) -> void:
	bleed += BLEED_RISE * diff * delta * (1.0 - packed * 0.6)
	if primary and not _prev_primary:
		if p.length() <= ACCEPT_R:
			if _t - _last_click >= MIN_CLICK_GAP:
				_last_click = _t
				packed = minf(1.0, packed + 1.0 / PACK_CLICKS)
				bleed = maxf(0.0, bleed - BLEED_PER_CLICK)
				_press_anim = 1.0
		elif _miss_cd <= 0.0:
			botch(1.5, "Pressing on the wrong spot")
			bleed += 0.04
			_miss_cd = 0.3
			_flash = 0.35
	if bleed >= 1.0:
		botch(4.0, "The wound is pouring blood")
		bleed = 0.72
		_flash = 0.6
	if packed >= 1.0:
		stage = Stage.WRAP
		bleed = minf(bleed, 0.25)
		_prev_valid = false


func _wrap(p: Vector2, primary: bool, jump: float, delta: float) -> void:
	var r := p.length()
	var in_band := r >= WRAP_R_MIN and r <= WRAP_R_MAX
	if not primary or not in_band:
		_prev_valid = false
		tension = lerpf(tension, 0.0, clampf(delta * 4.0, 0.0, 1.0))
		_tight_time = maxf(0.0, _tight_time - delta)
		return
	var a := atan2(p.y, p.x)
	if not _prev_valid:
		_prev_valid = true
		_prev_angle = a
		return
	# A sudden jerk (the patient stirring) yanks the bandage.
	if jump > JOLT_DIST and wrapped > 0.0:
		wrapped = maxf(0.0, wrapped - 0.6)
		if _slip_cd <= 0.0:
			botch(2.0, "The patient jerked and the wrap slipped")
			_slip_cd = 0.8
			_flash = 0.5
		_prev_angle = a
		return
	var da := wrapf(a - _prev_angle, -PI, PI)
	_prev_angle = a
	if wrap_dir == 0:
		_dir_accum += da
		if absf(_dir_accum) > 0.35:
			wrap_dir = 1 if _dir_accum > 0.0 else -1
		return
	var fwd := da * wrap_dir
	var tps := (fwd / TAU) / maxf(delta, 1e-4)
	tension = lerpf(tension, tps, clampf(delta * 6.0, 0.0, 1.0))
	if fwd < -0.004:
		# Unwinding.
		wrapped = maxf(0.0, wrapped + fwd)
		_slip_accum += -fwd
		if _slip_accum > 0.5:
			_slip_accum = 0.0
			if _slip_cd <= 0.0:
				botch(2.0, "Wrong way: the bandage is unwinding")
				_slip_cd = 1.0
				_flash = 0.4
		return
	_slip_accum = maxf(0.0, _slip_accum - fwd * 0.5)
	var gain := fwd
	if tension < GOOD_MIN_TPS:
		gain *= 0.5
		_tight_time = maxf(0.0, _tight_time - delta)
	elif tension > good_max:
		gain *= 0.6
		_tight_time += delta
		if _tight_time > 0.5:
			_tight_time = 0.0
			botch(2.0, "Too tight: that cuts off the circulation")
			_flash = 0.4
	else:
		_tight_time = maxf(0.0, _tight_time - delta)
	wrapped += gain
	if _wrap_frac() >= 1.0:
		_complete()


func _update_progress() -> void:
	if variant == "stump":
		progress = _wrap_frac()
	else:
		progress = 0.45 * packed + 0.55 * _wrap_frac()
	if stage == Stage.DONE:
		progress = 1.0


func _complete() -> void:
	stage = Stage.DONE
	pressing = false
	bleed = 0.0
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding"):
		body.set_bleeding(site_name, 0.0)
	finish({"dressed": true})


func tick(delta: float) -> void:
	_t += delta
	_flash = maxf(0.0, _flash - delta)
	_press_anim = maxf(0.0, _press_anim - delta * 5.0)
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_bleeding") and stage != Stage.DONE:
		var shown := bleed
		if stage == Stage.WRAP:
			shown = bleed * (1.0 - _wrap_frac())
		body.set_bleeding(site_name, clampf(shown, 0.0, 1.0))
	_update_visuals(delta)
	_sounds()


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Dress the wound"))
	var hint := ""
	var gauges := []
	match stage:
		Stage.PACK:
			hint = "Click on the wound, again and again, to pack gauze in. Keep the bleeding down."
			if bleed > 0.75:
				hint = "It is pouring! Pack faster."
			gauges.append({"label": "Bleeding", "value": bleed, "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 0.75})
			gauges.append({"label": "Packed", "value": packed, "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 1.0})
		Stage.WRAP:
			var turns := wrapped / TAU
			if not pressing:
				hint = "Hold left click and circle the cursor around the %s to wrap it." % ("stump" if variant == "stump" else "wound")
			elif wrap_dir == 0:
				hint = "Pick a direction and keep going round."
			elif tension > good_max:
				hint = "Too tight! Slow down."
			elif tension < GOOD_MIN_TPS:
				hint = "Too loose. Go round a bit faster, evenly."
			else:
				hint = "Good tension. Keep circling the same way."
			gauges.append({"label": "Tension", "value": tension, "min": 0.0, "max": 2.5, "good_min": GOOD_MIN_TPS, "good_max": good_max})
			gauges.append({"label": "Turns %.1f/%d" % [turns, int(turns_needed)], "value": _wrap_frac(), "min": 0.0, "max": 1.0, "good_min": 0.0, "good_max": 1.0})
		Stage.DONE:
			hint = "Dressed."
	return {"title": title, "hint": hint, "progress": progress, "gauges": gauges}


func net_state() -> Dictionary:
	return {"s": stage, "pk": snappedf(packed, 0.001), "bl": snappedf(bleed, 0.01), "w": snappedf(wrapped, 0.01),
		"d": wrap_dir, "tn": snappedf(tension, 0.01), "c": cursor, "b": pressing, "p": progress}


func apply_net_state(s: Dictionary) -> void:
	stage = int(s.get("s", stage))
	packed = float(s.get("pk", packed))
	bleed = float(s.get("bl", bleed))
	wrapped = float(s.get("w", wrapped))
	wrap_dir = int(s.get("d", wrap_dir))
	tension = float(s.get("tn", tension))
	cursor = s.get("c", cursor)
	pressing = bool(s.get("b", pressing))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := 1.0 - skill
	match stage:
		Stage.PACK:
			var period := lerpf(0.62, 0.2, skill)
			var ph := fmod(t, period)
			var down := ph < 0.06
			# Sloppy hands drift off the wound now and then.
			var off := Vector2(sin(t * 1.7) + 0.5 * sin(t * 4.1), cos(t * 1.3) + 0.4 * sin(t * 3.7)) * 0.042 * sloppy
			var c := Vector2(sin(t * 3.0), cos(t * 2.6)) * 0.008 + off
			return {"cursor": c, "buttons": BUTTON_PRIMARY if down else 0}
		Stage.WRAP:
			if _bot_wrap_t < 0.0:
				_bot_wrap_t = t
				_bot_angle = atan2(cursor.y, cursor.x)
			var wt := t - _bot_wrap_t
			var settle_k := clampf(1.0 - wt / 25.0, 0.2, 1.0)
			# Turns per second: steady for a good surgeon, lurching for a sloppy one,
			# with an occasional backwards twitch.
			var rate := 0.9 - 0.2 * sloppy + sloppy * settle_k * (1.25 * sin(wt * 1.4) + 0.35 * sin(wt * 3.3))
			if sloppy > 0.3 and fmod(wt, 3.6) > 3.2 and settle_k > 0.4:
				rate = -0.6
			_bot_angle += rate * TAU * dt
			var rr := 0.11 + 0.02 * sin(wt * 0.7)
			var bc := Vector2(cos(_bot_angle), sin(_bot_angle)) * rr
			# A sloppy hand jerks now and then, which yanks the bandage like a stir does.
			if sloppy > 0.3 and settle_k > 0.4 and fmod(wt + 1.3, 2.9) < 0.017:
				bc += Vector2(0.07, -0.05) * sloppy
			return {"cursor": bc, "buttons": BUTTON_PRIMARY}
	return {"cursor": cursor, "buttons": 0}


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
	if col.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _build() -> void:
	_cloth = _mat(Color(0.94, 0.92, 0.85), 1.0)
	_cloth.cull_mode = BaseMaterial3D.CULL_DISABLED


	_rolls = Node3D.new()
	_rolls.name = "Rolls"
	_rolls.position = Vector3(-0.17, 0.0, -0.1)
	add_child(_rolls)
	_set_rolls(maxi(1, int(ctx.get("step", {}).get("uses", 1))))

	if variant == "pack":
		# Blood pooling around the wound, and the wound itself.
		_blood = MeshInstance3D.new()
		var bc := CylinderMesh.new()
		bc.top_radius = 1.0
		bc.bottom_radius = 1.0
		bc.height = 1.0
		bc.radial_segments = 28
		_blood.mesh = bc
		_blood_mat = _mat(Color(0.45, 0.02, 0.03, 0.85), 0.15)
		_blood_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_blood_mat.metallic_specular = 0.9
		_blood.material_override = _blood_mat
		add_child(_blood)
		var hole := MeshInstance3D.new()
		var hc := CylinderMesh.new()
		hc.top_radius = 0.011
		hc.bottom_radius = 0.011
		hc.height = 0.002
		hole.mesh = hc
		hole.material_override = _mat(Color(0.12, 0.0, 0.01), 0.3)
		hole.position = Vector3(0, 0.0035, 0)
		add_child(hole)
		# Gauze wads stuffed into the wound, one per click.
		var rng := RandomNumberGenerator.new()
		rng.seed = int(ctx.get("seed", 7))
		var soaked := _mat(Color(0.85, 0.55, 0.55), 1.0)
		for i in PACK_CLICKS:
			var w := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.013
			sm.height = 0.013
			sm.radial_segments = 10
			sm.rings = 5
			w.mesh = sm
			w.material_override = soaked if i < 4 else _cloth
			var a := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * WOUND_R * 0.7
			w.position = Vector3(cos(a) * rr, 0.004 + i * 0.0006, sin(a) * rr)
			w.rotation = Vector3(rng.randf(), rng.randf() * TAU, rng.randf())
			w.scale = Vector3(1.0, 0.55, 0.8) * rng.randf_range(0.8, 1.15)
			w.visible = false
			add_child(w)
			_wads.append(w)
		# The pad in the surgeon's fingers.
		_pad = Node3D.new()
		var padm := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.03, 0.007, 0.024)
		padm.mesh = pb
		padm.material_override = _cloth
		_pad.add_child(padm)
		var fold := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(0.026, 0.004, 0.02)
		fold.mesh = fb
		fold.material_override = _mat(Color(0.9, 0.9, 0.86), 1.0)
		fold.position = Vector3(0.002, 0.005, -0.001)
		fold.rotation_degrees = Vector3(0, 12, 4)
		_pad.add_child(fold)
		add_child(_pad)

	_ribbon = MeshInstance3D.new()
	_ribbon.name = "Wrap"
	var ribbon_mat := _cloth.duplicate() as StandardMaterial3D
	ribbon_mat.vertex_color_use_as_albedo = true
	# A touch of glow so fresh gauze reads in a dim OR.
	ribbon_mat.emission_enabled = true
	ribbon_mat.emission = Color(0.9, 0.88, 0.8)
	ribbon_mat.emission_energy_multiplier = 0.18
	_ribbon.material_override = ribbon_mat
	add_child(_ribbon)

	_feed = Node3D.new()
	var roll: Node3D = ItemModelsScript.make("gauze", 1)
	roll.position = Vector3(0, -0.032, 0)
	_feed.add_child(roll)
	_feed.scale = Vector3.ONE * 0.6
	add_child(_feed)

	_guide = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.96
	tm.outer_radius = 1.0
	tm.rings = 48
	tm.ring_segments = 4
	_guide.mesh = tm
	_guide_mat = _unshaded(Color(1, 1, 1, 0.35))
	_guide.material_override = _guide_mat
	add_child(_guide)


func _set_rolls(n: int) -> void:
	if n == _roll_count:
		return
	_roll_count = n
	for c in _rolls.get_children():
		c.queue_free()
	if n > 0:
		_rolls.add_child(ItemModelsScript.make("gauze", n))


## Point on the wrap path at angle theta (radians wound), plus the band's normal.
func _wrap_point(theta: float) -> Array:
	var turns := theta / TAU
	if variant == "stump":
		# A helix around the limb, whose axis runs along plane X under the surface.
		# Winds from up the arm toward the cut end (+X is distal), a layer thicker each turn.
		var pad := 0.006 + 0.0015 * turns
		var x := -0.075 + 0.07 * clampf(turns / maxf(1.0, turns_needed), 0.0, 1.0)
		var n := Vector3(0, cos(theta), sin(theta))
		var pt := Vector3(x, limb_axis_y + (limb_hu + pad) * cos(theta), (limb_hs + pad) * sin(theta))
		return [pt, n, Vector3(1, 0, 0)]
	# A flat spiral dressing growing out from the wound.
	var r := 0.01 + turns * 0.024
	var h := 0.007 + turns * 0.003
	var radial := Vector3(cos(theta), 0, sin(theta))
	return [Vector3(0, h, 0) + radial * r, Vector3.UP, radial]


func _rebuild_ribbon() -> void:
	if absf(wrapped - _ribbon_built) < 0.04:
		return
	_ribbon_built = wrapped
	if wrapped <= 0.02:
		_ribbon.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var width := 0.026 if variant == "stump" else 0.02
	var steps := maxi(2, int(wrapped / 0.12))
	var prev: Array = []
	for i in steps + 1:
		var th := wrapped * float(i) / steps
		var wp := _wrap_point(th)
		var side: Vector3 = wp[2] * (width * 0.5)
		var n: Vector3 = wp[1]
		var a: Vector3 = wp[0] - side
		var m: Vector3 = wp[0] + n * 0.0015
		var b: Vector3 = wp[0] + side
		if not prev.is_empty():
			var edge := Color(0.72, 0.7, 0.64)
			var mid := Color(1, 1, 1)
			for tri in [[prev[0], edge, prev[1], mid, m, mid], [prev[0], edge, m, mid, a, edge],
					[prev[1], mid, prev[2], edge, b, edge], [prev[1], mid, b, edge, m, mid]]:
				for k in 3:
					st.set_color(tri[k * 2 + 1])
					st.set_normal(n)
					st.add_vertex(tri[k * 2])
		prev = [a, m, b]
	_ribbon.mesh = st.commit()


func _update_visuals(delta: float) -> void:
	if _ribbon == null:
		return
	var red := Color(1.0, 0.25, 0.2, 0.9) if _flash > 0.0 else Color()
	if variant == "pack":
		var shown := bleed if stage == Stage.PACK else bleed * (1.0 - _wrap_frac())
		var br := 0.018 + 0.05 * clampf(shown, 0.0, 1.0)
		_blood.scale = Vector3(br, 0.002, br * 0.85)
		_blood.position = Vector3(0, 0.002, 0.003)
		_blood.visible = stage != Stage.DONE or shown > 0.01
		_blood_mat.albedo_color = Color(0.45 + 0.25 * clampf(shown, 0.0, 1.0), 0.02, 0.03, 0.85)
		var n := int(round(packed * PACK_CLICKS))
		for i in _wads.size():
			_wads[i].visible = i < n
		_pad.visible = stage == Stage.PACK
		var lift := lerpf(0.035, 0.008, _press_anim) if not pressing else 0.01
		_pad.position = plane_to_local(cursor, lift)
	_rebuild_ribbon()
	# The feeding roll sits at the end of the wrap and follows the cursor's angle.
	_feed.visible = stage == Stage.WRAP
	if stage == Stage.WRAP:
		var end: Array = _wrap_point(maxf(wrapped, 0.001))
		var ang := atan2(cursor.y, cursor.x)
		var target := plane_to_local(cursor.normalized() * clampf(cursor.length(), 0.06, 0.13), 0.05)
		if variant == "stump":
			target = Vector3(end[0].x + 0.02, 0.05 + 0.02 * sin(ang), cursor.y * 0.5)
		_feed.position = _feed.position.lerp(target, clampf(delta * 12.0, 0.0, 1.0)) if delta > 0.0 else target
		_feed.rotation = Vector3(0, -ang, 0)
	if variant == "stump" and stage != Stage.DONE:
		_set_rolls(1 if _wrap_frac() >= 0.5 else maxi(1, int(ctx.get("step", {}).get("uses", 2))))
	elif stage == Stage.DONE:
		_set_rolls(maxi(0, _roll_count - 1) if _roll_count > 1 and variant == "stump" else _roll_count)

	# The circle to trace while wrapping, coloured by tension.
	_guide.visible = stage == Stage.WRAP
	var gr := 0.11
	_guide.scale = Vector3(gr, 0.01, gr)
	_guide.position = Vector3(0, 0.03 if variant == "pack" else 0.01, 0)
	var col := Color(1, 1, 1, 0.3)
	if pressing and wrap_dir != 0:
		if tension > good_max:
			col = Color(1.0, 0.3, 0.2, 0.75)
		elif tension < GOOD_MIN_TPS:
			col = Color(1.0, 0.8, 0.25, 0.6)
		else:
			col = Color(0.35, 1.0, 0.5, 0.7)
	if _flash > 0.0:
		col = red
	_guide_mat.albedo_color = col


func _sounds() -> void:
	var at = global_position if is_inside_tree() else null
	if _last_stage != -1 and stage != _last_stage:
		_audio("surgery_tear", at, -3.0, 0.05)
		if stage == Stage.DONE:
			_audio("surgery_done", at, -4.0)
	if packed > _last_packed + 0.001:
		_audio("surgery_pack", at, -2.0, 0.08)
	if stage == Stage.WRAP and wrapped > _swish_at + PI * 0.5:
		_swish_at = wrapped
		_audio("surgery_swish", at, -6.0, 0.1)
	elif wrapped < _swish_at - PI:
		_swish_at = wrapped
	if _last_stage == -1 and stage == Stage.WRAP:
		_audio("surgery_tear", at, -3.0, 0.05)
	_last_stage = stage
	_last_packed = packed


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var a = Engine.get_main_loop().root.get_node_or_null("Audio") if Engine.get_main_loop() else null
	if a != null:
		a.play(cue, at, vol, jitter)
