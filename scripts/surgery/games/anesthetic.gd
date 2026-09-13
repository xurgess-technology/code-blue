extends "res://scripts/surgery/minigame.gd"
## Step "sedate": put the needle in the vein and push the anesthetic until the patient goes under.
##
## There is no dose to read off a scale: the patient shows it.
##
## FIND    The syringe (already drawn up from the vial) follows the cursor; its tip lights up
##         blue over the vein. Press left click to put the needle in. Pressing off the vein
##         leaves a bead of blood and makes the patient flinch (botch).
## INJECT  Hold left click to push the plunger. The anesthetic glows its way up the vein and the
##         arm's twitching and fidgeting fade as the patient goes under; once it has stopped, let
##         go. Pushing on past that turns the skin grey-blue and sets off the monitor alarm (an
##         overdose, which botches when the step ends). Dragging the needle while pushing slides
##         it out of the vein (botch).
##         Letting go starts to withdraw the needle; press again within WITHDRAW_TIME to give more.
## Result {"sedation": s}: 1.0 for a good dose (0.8..1.25 of the patient's need), below 0.75 a
## clear underdose (the patient stirs in later steps), above 1.25 an overdose that also botches.

const ItemModelsScript := preload("res://scripts/item_models.gd")

enum Stage { FIND, INJECT, DONE }

const ML_PER_KG := 0.05
const PUSH_RATE := 0.8           # ml per second while pushing
const CAPACITY_K := 1.9          # the syringe holds this many doses, so an overdose is possible
const VEIN_HALF := 0.075         # the vein runs this far either side of the site along X
const VEIN_TOL := 0.02           # a press this close to the vein (across it) goes in
const SLIP_TOL := 0.03           # pushing with the tip this far from where it went in slides it out
const WITHDRAW_TIME := 1.2
const MIN_DOSE_K := 0.2          # withdrawing with less than this share of a dose gives nothing
const GOOD_LO := 0.8
const GOOD_HI := 1.25
const MISS_BOTCH := 2.0
const SLIP_BOTCH := 2.5
const MAX_BEADS := 4

# Syringe geometry (metres, in the syringe's own frame: needle tip at the origin, body along +X).
const NEEDLE_LEN := 0.05
const HUB_LEN := 0.012
const BARREL_LEN := 0.13
const BARREL_R := 0.0125
const B0 := NEEDLE_LEN + HUB_LEN

var stage: int = Stage.FIND
var injected: float = 0.0        # ml in the patient
var sedation: float = 1.0
var cursor := Vector2(0.1, 0.08)
var pressing := false
var inserted := false
var insert_at := Vector2.ZERO
var withdraw: float = 0.0        # seconds since letting go with the needle in
var beads: Array = []            # where the needle missed (plane metres)
var slips := 0

var target_ml := 4.0
var capacity_ml := 7.6
var vein_tol := VEIN_TOL
var _prev_primary := false
var _t := 0.0
var _miss_cd := 0.0

# visuals
var _built := false
var _syringe: Node3D
var _liquid: MeshInstance3D
var _stopper: Node3D
var _hub_mat: StandardMaterial3D

var _vein_mat: StandardMaterial3D
var _flow: MeshInstance3D
var _flow_mat: StandardMaterial3D
var _tip_glow: MeshInstance3D
var _tip_mat: StandardMaterial3D
var _bead_nodes: Array[MeshInstance3D] = []
var _grey: Decal
var _syr_xform := Transform3D()
var _prox := -1.0                # which way along X the vein runs toward the body
var _fill := 0.0                 # the draw-up animation at the start
var _twitch_t := 0.8
var _rng := RandomNumberGenerator.new()
var _seen := {}
var _alarm_t := 0.0
var _push_snd := 0.0

# bot
var _bt := 0.0
var _bc := Vector2(0.12, 0.1)
var _b_wait := 0.0
var _b_misses := 0


func setup(context: Dictionary) -> void:
	super.setup(context)
	var weight := float(ctx.get("patient", {}).get("weight_kg", 80.0))
	var diff := maxf(0.5, float(ctx.get("difficulty", 1.0)))
	target_ml = clampf(weight * ML_PER_KG, 1.0, 9.0)
	capacity_ml = target_ml * CAPACITY_K
	vein_tol = VEIN_TOL / sqrt(diff)
	_rng.seed = int(ctx.get("seed", 1))
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and is_inside_tree():
		var local: Vector3 = global_transform.affine_inverse() * (body as Node3D).global_position
		_prox = -1.0 if local.x < 0.0 else 1.0
	_build()
	_update_visuals(0.0, true)


func plane_extent() -> Vector2:
	return Vector2(0.24, 0.16)


func camera_pose() -> Dictionary:
	return {"height": 0.42, "back": 0.15, "fov": 55.0}


func ratio() -> float:
	return injected / maxf(target_ml, 0.01)


func on_vein(p: Vector2) -> bool:
	return absf(p.y) <= vein_tol and absf(p.x) <= VEIN_HALF


# ---------------------------------------------------------------------------- rules

func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	cursor = p
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var pressed := primary and not _prev_primary
	_prev_primary = primary
	_miss_cd = maxf(0.0, _miss_cd - delta)
	pressing = primary
	match stage:
		Stage.FIND:
			if pressed:
				if on_vein(p):
					stage = Stage.INJECT
					inserted = true
					insert_at = Vector2(p.x, clampf(p.y, -0.004, 0.004))
					withdraw = 0.0
				elif _miss_cd <= 0.0:
					_miss_cd = 0.5
					beads.append(p)
					if beads.size() > MAX_BEADS:
						beads.pop_front()
					botch(MISS_BOTCH, "Missed the vein")
		Stage.INJECT:
			if primary:
				withdraw = 0.0
				if p.distance_to(insert_at) > SLIP_TOL:
					# Dragged it out of the vein.
					slips += 1
					beads.append(insert_at)
					if beads.size() > MAX_BEADS:
						beads.pop_front()
					inserted = false
					stage = Stage.FIND
					_prev_primary = true
					botch(SLIP_BOTCH, "The needle slid out of the vein")
				else:
					injected = minf(capacity_ml, injected + PUSH_RATE * delta)
			else:
				withdraw += delta
				if withdraw >= WITHDRAW_TIME:
					if injected >= target_ml * MIN_DOSE_K:
						_complete()
					else:
						inserted = false
						stage = Stage.FIND
	_update_progress()


func _update_progress() -> void:
	if stage == Stage.DONE:
		progress = 1.0
		return
	progress = clampf(0.1 + 0.8 * ratio() + (0.1 * withdraw / WITHDRAW_TIME if stage == Stage.INJECT else 0.0), 0.0, 0.98)


func _complete() -> void:
	stage = Stage.DONE
	pressing = false
	inserted = false
	var r := ratio()
	sedation = r
	if r >= GOOD_LO and r <= GOOD_HI:
		sedation = 1.0 + (r - 1.0) * 0.35
	sedation = clampf(sedation, 0.0, 2.0)
	if sedation > 1.25:
		botch(4.0 + (sedation - 1.25) * 30.0, "Overdose: the patient's blood pressure crashed")
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and body.has_method("set_sedation"):
		body.set_sedation(clampf(sedation, 0.0, 1.0))
	progress = 1.0
	finish({"sedation": snappedf(sedation, 0.01)})


func tick(delta: float) -> void:
	_t += delta
	_fill = minf(1.0, _fill + delta / 0.8)
	_patient(delta)
	_update_visuals(delta, false)
	_sounds(delta)


## The patient shows the dose: an awake arm twitches and fidgets, less and less as the drug goes
## in, and not at all once it is enough. Runs on every machine from the replicated amount.
func _patient(delta: float) -> void:
	var body = ctx.get("body")
	if body == null or not is_instance_valid(body) or stage == Stage.DONE:
		return
	var r := ratio()
	if body.has_method("set_sedation"):
		body.set_sedation(clampf(r * 0.75, 0.0, 1.0))
	var awake := clampf(1.0 - r / 0.85, 0.0, 1.0)
	if awake <= 0.0 or not body.has_method("stir"):
		return
	_twitch_t -= delta
	if _twitch_t <= 0.0:
		_twitch_t = _rng.randf_range(0.45, 0.9) / (0.4 + awake)
		body.stir(0.12 + 0.45 * awake * _rng.randf_range(0.6, 1.0))


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var title := String(ctx.get("step", {}).get("label", "Sedate the patient"))
	var hint := ""
	match stage:
		Stage.FIND:
			hint = "Put the needle on the blue vein and hold left click to inject."
		Stage.INJECT:
			if pressing:
				hint = "That's plenty! Let go." if ratio() > 1.1 else "Keep pushing until the arm stops twitching."
			else:
				hint = "Letting go withdraws the needle. Hold again to give more."
		Stage.DONE:
			hint = "Sedated." if sedation >= 0.75 and sedation <= 1.25 else \
				("Underdosed: expect the patient to stir." if sedation < 0.75 else "Overdosed.")
	return {"title": title, "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"s": stage, "v": snappedf(injected, 0.01), "se": snappedf(sedation, 0.001), "c": cursor, "b": pressing,
		"i": inserted, "ia": insert_at, "w": snappedf(withdraw, 0.02), "be": beads, "sl": slips, "p": snappedf(progress, 0.001)}


func apply_net_state(s: Dictionary) -> void:
	stage = int(s.get("s", stage))
	injected = float(s.get("v", injected))
	sedation = float(s.get("se", sedation))
	cursor = s.get("c", cursor)
	pressing = bool(s.get("b", pressing))
	inserted = bool(s.get("i", inserted))
	insert_at = s.get("ia", insert_at)
	withdraw = float(s.get("w", withdraw))
	var be = s.get("be", beads)
	if be is Array:
		beads = be
	slips = int(s.get("sl", slips))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	var sloppy := 1.0 - skill
	var buttons := 0
	# Even a sloppy hand settles down after a while, so the step always ends.
	var settle := clampf(1.0 - t / 25.0, 0.2, 1.0)
	var wobble := Vector2(sin(t * 2.3) + 0.6 * sin(t * 5.1 + 1.0), cos(t * 1.9) + 0.5 * sin(t * 4.3)) * 0.028 * sloppy * settle
	match stage:
		Stage.FIND:
			if t < 0.6:
				return {"cursor": _bc, "buttons": 0}
			var want := Vector2(0.02, 0.0) + wobble
			_bc = _bc.move_toward(want, lerpf(0.2, 0.5, skill) * dt)
			_b_wait -= dt
			# A good hand presses once it is on the vein; a sloppy one jabs as soon as it is close.
			var close := _bc.distance_to(Vector2(0.02, 0.0)) <= lerpf(0.045, 0.006, skill)
			if close and _b_wait <= 0.0:
				buttons = BUTTON_PRIMARY
				_b_wait = 0.5
		Stage.INJECT:
			# Push until the patient is under: a good surgeon stops right there, a sloppy one keeps going.
			var stop_at := lerpf(1.55, 1.02, skill)
			var hand := wobble * 1.4 if sloppy > 0.3 and ratio() > 0.4 and slips == 0 else Vector2.ZERO
			_bc = insert_at + hand
			if ratio() < stop_at:
				buttons = BUTTON_PRIMARY
	return {"cursor": _bc, "buttons": buttons}


## Headless check through the lab: `tools/minigame_lab.tscn -- --selftest=anesthetic`.
static func self_test() -> Array:
	var script: GDScript = load("res://scripts/surgery/games/anesthetic.gd")
	var runner: GDScript = load("res://scripts/surgery/games/gauze.gd")
	var out := []
	for pid in ["bob", "seal"]:
		for skill in [1.0, 0.5, 0.0]:
			for diff in [1.0, 1.36]:
				var g = script.new()
				var tally := {"n": 0, "v": 0.0, "done": false, "sed": -1.0, "reasons": {}}
				g.botched.connect(func(a, r): tally.n += 1; tally.v += a; tally.reasons[r] = int(tally.reasons.get(r, 0)) + 1)
				g.finished.connect(func(r): tally.done = true; tally.sed = float(r.get("sedation", -1.0)))
				g.setup({"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": "gunshot",
					"step": Procedures.step("gunshot", 0), "variant": "", "shift": 1, "difficulty": diff,
					"flags": {}, "seed": hash("anes" + pid), "body": null, "operator": true})
				var t: float = runner._run_bot(g, skill, 1.0, hash(pid))
				print("[anesthetic self-test] %-4s skill=%.1f diff=%.2f  %s  time=%5.1fs  sedation=%.2f  botches=%d vitals=%5.1f  %s" % [
					pid, skill, diff, "DONE" if tally.done else "UNFINISHED", t, tally.sed, tally.n, tally.v, str(tally.reasons)])
				out.append({"patient": pid, "skill": skill, "done": tally.done, "time": t, "vitals": tally.v, "sedation": tally.sed})
				g.free()
	return out


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
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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
	if _built:
		return
	_built = true
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
	# The hub: clear blue, flashing red with blood once the needle is in the vein.
	_hub_mat = _mat(Color(0.2, 0.55, 0.85), 0.5)
	_rod(_syringe, NEEDLE_LEN, B0, 0.004, _hub_mat, 10)
	var barrel_end := B0 + BARREL_LEN + 0.012
	_rod(_syringe, B0 - 0.004, barrel_end, BARREL_R, glass, 20)
	var flange := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(0.004, 0.006, 0.055)
	flange.mesh = fb
	flange.material_override = plastic
	flange.position = Vector3(barrel_end, 0, 0)
	_syringe.add_child(flange)
	_liquid = _rod(_syringe, B0, B0 + 0.001, BARREL_R * 0.86, liquid, 16)
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
	# A soft glow at the needle tip: blue when it is over the vein.
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 12
	sm.rings = 6
	_tip_mat = _unshaded(Color(0.4, 0.75, 1.0, 0.0))
	_tip_glow = MeshInstance3D.new()
	_tip_glow.mesh = sm
	_tip_glow.material_override = _tip_mat
	_tip_glow.scale = Vector3.ONE * 0.007
	add_child(_tip_glow)

	# The vein, raised a little on the skin, and the anesthetic glowing its way along it.
	var vb := BoxMesh.new()
	vb.size = Vector3(1.0, 0.002, 0.009)
	_vein_mat = _unshaded(Color(0.2, 0.3, 0.85, 0.8))
	# The target must never hide: a fidgeting arm or a gown fold used to swallow the vein.
	_vein_mat.no_depth_test = true
	_vein_mat.render_priority = 1
	var vein := MeshInstance3D.new()
	vein.mesh = vb
	vein.material_override = _vein_mat
	vein.scale = Vector3(VEIN_HALF * 2.0 + 0.04, 1, 1)
	vein.position = Vector3(0, 0.0055, 0)
	vein.name = "Vein"
	add_child(vein)
	_flow_mat = _unshaded(Color(1.0, 0.72, 0.15, 0.9))
	_flow_mat.no_depth_test = true
	_flow_mat.render_priority = 2
	_flow = MeshInstance3D.new()
	_flow.mesh = vb
	_flow.material_override = _flow_mat
	_flow.name = "Flow"
	add_child(_flow)
	var bm := SphereMesh.new()
	bm.radius = 0.004
	bm.height = 0.005
	bm.radial_segments = 10
	bm.rings = 5
	var blood := _mat(Color(0.45, 0.0, 0.02), 0.1)
	for i in MAX_BEADS:
		var b := MeshInstance3D.new()
		b.mesh = bm
		b.material_override = blood
		b.visible = false
		add_child(b)
		_bead_nodes.append(b)
	# Overdose: the skin round the site greys and goes blue.
	_grey = Decal.new()
	_grey.texture_albedo = _grey_texture()
	_grey.size = Vector3(0.3, 0.2, 0.22)
	_grey.position = Vector3(0, -0.05, 0)
	_grey.cull_mask = 1
	_grey.upper_fade = 0.1
	_grey.lower_fade = 0.3
	_grey.modulate = Color(0.16, 0.22, 0.48, 0.0)
	_grey.visible = false
	add_child(_grey)
	_set_layers(self)


func _set_layers(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as VisualInstance3D).layers = OWN_LAYER
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c)


static var _grey_tex: Texture2D


static func _grey_texture() -> Texture2D:
	if _grey_tex != null:
		return _grey_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (x + 0.5) / n * 2.0 - 1.0
			var v := (y + 0.5) / n * 2.0 - 1.0
			var a := pow(clampf(1.0 - sqrt(u * u + v * v), 0.0, 1.0), 0.8)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_grey_tex = ImageTexture.create_from_image(img)
	return _grey_tex


func _update_visuals(delta: float, snap: bool) -> void:
	if not _built:
		return
	var r := ratio()
	# The barrel empties as the dose goes in; it fills up from the vial at the very start.
	var shown := (capacity_ml - injected) * _fill
	var sx := B0 + BARREL_LEN * shown / maxf(capacity_ml, 0.01)
	_stopper.position = Vector3(sx, 0, 0)
	_liquid.visible = shown > 0.02
	_liquid.scale = Vector3(1, maxf(0.0005, sx - 0.006 - B0), 1)
	_liquid.position = Vector3((B0 + sx - 0.006) * 0.5, 0, 0)
	_hub_mat.albedo_color = Color(0.7, 0.05, 0.08) if inserted else Color(0.2, 0.55, 0.85)

	var target := Transform3D()
	var tip_at := cursor
	if stage == Stage.DONE:
		target = Transform3D(Basis(Vector3(0, 1, 0), 0.35) * Basis(Vector3(0, 0, 1), deg_to_rad(10)), plane_to_local(Vector2(0.14, 0.09), 0.02))
	else:
		var depth := 0.0
		var lift := 0.012
		if inserted:
			tip_at = insert_at
			# In the vein; letting go backs it slowly out.
			var back := clampf(withdraw / WITHDRAW_TIME, 0.0, 1.0)
			depth = 0.006 * (1.0 - back)
			lift = 0.001 + 0.008 * back
		elif pressing:
			lift = 0.004
		var tip := plane_to_local(tip_at, lift - depth)
		target = Transform3D(Basis(Vector3(0, 1, 0), 0.35) * Basis(Vector3(0, 0, 1), deg_to_rad(24)), tip)
	var k := 1.0 if snap else clampf(delta * 16.0, 0.0, 1.0)
	_syr_xform = _syr_xform.interpolate_with(target, k)
	_syringe.transform = _syr_xform

	var over := stage == Stage.FIND and on_vein(cursor)
	_tip_glow.visible = stage == Stage.FIND
	_tip_glow.position = plane_to_local(cursor, 0.004)
	_tip_mat.albedo_color = Color(0.4, 0.8, 1.0, (0.6 + 0.3 * sin(_t * 10.0)) if over else 0.12)
	_tip_glow.scale = Vector3.ONE * (0.009 if over else 0.005)

	# The anesthetic travels up the vein from the needle toward the body, reaching the end of the
	# vein just as the dose is enough, and turns the vein dark past that.
	var reach := clampf(r, 0.0, 1.0)
	var x0 := insert_at.x if injected > 0.0 else 0.0
	var end_x := VEIN_HALF * _prox + 0.02 * _prox
	var x1 := lerpf(x0, end_x, reach)
	_flow.visible = injected > 0.01 and stage != Stage.DONE
	_flow.scale = Vector3(maxf(0.001, absf(x1 - x0)), 1.5, 1.3)
	_flow.position = Vector3((x0 + x1) * 0.5, 0.0075, 0)
	var pulse := 1.0
	_flow_mat.albedo_color = Color(1.0, 0.72, 0.15, pulse).lerp(Color(0.25, 0.2, 0.45, 0.95), clampf((r - 1.1) / 0.4, 0.0, 1.0))
	var od := clampf((r - 1.15) / 0.4, 0.0, 1.0)
	_vein_mat.albedo_color = Color(0.2, 0.3, 0.85, 0.8).lerp(Color(0.12, 0.1, 0.3, 0.95), od)
	_grey.visible = od > 0.01 and stage != Stage.DONE or (stage == Stage.DONE and sedation > 1.25)
	_grey.modulate.a = 0.95 * (od if stage != Stage.DONE else clampf((sedation - 1.15) / 0.4, 0.0, 1.0))

	for i in _bead_nodes.size():
		var b := _bead_nodes[i]
		b.visible = i < beads.size()
		if b.visible:
			b.position = plane_to_local(beads[i], 0.004)


func _sounds(delta: float) -> void:
	var at = global_position if is_inside_tree() else null
	if _seen.is_empty():
		_seen = {"stage": stage, "inserted": inserted, "beads": beads.size(), "slips": slips}
		_audio("surgery_draw", at, -6.0, 0.05)
		return
	if inserted and not bool(_seen.inserted):
		_audio("surgery_needle", at, -2.0)
	if beads.size() != int(_seen.beads) or slips != int(_seen.slips):
		_audio("surgery_needle", at, -4.0, 0.3)
		var body = ctx.get("body")
		if body != null and is_instance_valid(body) and body.has_method("stir"):
			body.stir(0.6)
	if stage != int(_seen.stage) and stage == Stage.DONE:
		_audio("surgery_click", at, -2.0)
		_audio("surgery_done", at, -4.0)
	_seen = {"stage": stage, "inserted": inserted, "beads": beads.size(), "slips": slips}
	# The push: a soft hiss while the plunger moves.
	if pressing and inserted and stage == Stage.INJECT:
		_push_snd -= delta
		if _push_snd <= 0.0:
			_push_snd = 0.55
			_audio("surgery_inject", at, -9.0, 0.04)
	else:
		_push_snd = 0.0
	# Too much: the monitor alarm.
	if stage == Stage.INJECT and ratio() > 1.3:
		_alarm_t -= delta
		if _alarm_t <= 0.0:
			_alarm_t = 0.45
			_audio("surgery_beep_crit", at, -3.0)
	else:
		_alarm_t = 0.0


func _audio(cue: String, at, vol := 0.0, jitter := 0.0) -> void:
	var ml = Engine.get_main_loop()
	var a = ml.root.get_node_or_null("Audio") if ml is SceneTree else null
	if a != null:
		a.play(cue, at, vol, jitter)
