extends "res://scripts/surgery/minigame.gd"
## The eye steps (GRAFTING part one): Eyeball Extraction on a strapped Hive today, the graft's surgeon
## steps later. Three variants on a work plane centred on the eye (`ctx.variant`):
##
##   cut    (scalpel)   The pre-op marking (violet dashes and hash ticks, the saw's style) rings the eye.
##                      Hold the scalpel over the eye and LEFT CLICK to lower it, then trace the marking:
##                      the cut opens along it as you go. Trace too fast, or wander off the eye, and the
##                      scalpel slips out: line up over the eye and click to lower it again. The cut so
##                      far stays. A slip costs nothing.
##   scoop  (eye spoon) The spoon is on the cursor. LEFT CLICK inside the socket to lower it, then circle the
##                      inside of the socket slowly and lightly. Too fast and it slips out (click to
##                      lower it again; the turns so far stay). Two turns ease the eye out.
##   snip   (scalpel)   The eye is out of its socket but still on its nerve, resting over the socket, seen
##                      from a low angle. Hold W to pull it up and the nerve shows. Then aim the scalpel
##                      at the nerve and LEFT CLICK to slice.
##   seat   (eye spoon) GRAFTING chunk C, the graft only: the new eye waits over the empty socket. LEFT
##                      CLICK inside the socket to lower it, then circle slowly: two turns settle it in.
##                      The scoop's rules exactly, run the other way round (the eye sinks as it goes).
##   stitch (suture kit) GRAFTING chunk C: the cut is open all the way round. Trace the ring the same way
##                      the cut was made and it closes behind the needle, stitch by stitch.
##
## Inputs read: the cursor, BUTTON_PRIMARY (left click) and BUTTON_UP (W). Botches: only a nick of the
## eyeball itself (the cut lowered onto the eye) and a slice that misses the nerve; a slip never botches.
##
## ctx knobs (all optional, so the graft can reuse this on a surgeon):
##   no_fail: true    never botches (grafting: mistakes cost nothing)
##   eye_kind         "eye_hive" | "eye_surgeon" (the eye's look); default from patient_id
##   eye_kind_in      the eye going IN, for the graft's seat step (default: eye_kind)
##   eye_radius       metres, default 0.0155
## Results: cut {"eye_cut": true}, scoop {"eye_out": true}, snip {"eye_removed": true},
##          seat {"eye_seated": true}, stitch {"eye_stitched": true}.

const RING_GAP := 0.0145               # marking ring radius = eye radius + this
const CUT_MAX_SPEED := 0.075           # m/s of cursor speed the scalpel tolerates while cutting
const CUT_LINE_TOL := 0.009            # how far off the marking still cuts
const CUT_LEAVE := 0.022               # past the ring by this and the scalpel slips out
const CUT_AHEAD := 0.5                 # radians ahead of the cut front the cursor may be and still extend it
const CUT_BEHIND := 0.15
const NICK_BOTCH := 5.0                # lowering the scalpel onto the eyeball itself
const SCOOP_MAX_SPEED := 0.06
const SCOOP_R_MIN := 0.005
const SCOOP_R_MAX := 0.026
const SCOOP_LEAVE := 0.034
const SCOOP_TURNS := 2.0
const LIFT_UP_SECONDS := 2.4
const LIFT_DOWN_SECONDS := 1.5
const REVEAL_FROM := 0.35
const SLICE_READY := 0.8
const NERVE_AT := Vector2(0.0, 0.008)   # where on the plane the nerve middle is (the cursor aims here)
const SLICE_TIME := 0.8                 # the slice plays out (blade drops, nerve parts, flush) before it finishes
const NERVE_BASE := Vector3(0.0, -0.004, 0.012)   # the nerve end in the back of the socket
const SLICE_TOL := 0.014
const MISS_BOTCH := 6.0
const DASHES := 30
const STITCHES := 14                   # the graft's stitch step: marks laid round the socket
const CUT_SEGS := 72
const CUT_SAMPLES := 96                # ring samples the incision ribbon is built from
const WOUND_HW := 0.0019               # half width of the slit
const WOUND_LIFT := 0.0004             # sits just off the skin so it never z-fights
const SCOOP_TIP_Y := 0.006             # the lowered spoon's bowl height: in the socket, beside the eye
const CUT_TIP_Y := 0.008               # the lowered scalpel's tip height: on the skin around the eye, in view
const TIP_X := 0.09                    # where the item model's tip is along its X
const INK_SHEEN := Color(0.55, 0.3, 1.0)   # the saw's marking sheen

var variant := "cut"
var no_fail := false
var eye_kind := "eye_hive"
var eye_r := 0.0155
var ring_r := 0.03

# replicated
var down := false                       # the tool is lowered onto the eye
var cut := 0.0                          # radians of the ring cut so far (0..TAU)
var turns := 0.0                        # radians circled inside the socket
var lift := 0.0                         # snip: how far the eye is pulled up, 0..1
var slips := 0                          # counts up on every slip
var cursor := Vector2(0.0, 0.05)
var _t := 0.0

# operator only
var _prev_primary := false
var _speed := 0.0
var _last_cursor := Vector2.ZERO
var _have_last := false
var _last_a := 0.0
var _hint := ""
var _hint_t := 0.0
var _bt := 0.0                          # bot clock
var _bang := 0.0
var _seen_slips := 0
var _flash := 0.0

# visuals
var _built := false
var _tool: Node3D
var _eye: MeshInstance3D
var _nerve: MeshInstance3D
var _nerve_mat: StandardMaterial3D
var _ring: Array[MeshInstance3D] = []   # marking dashes and ticks
var _dots: Array[MeshInstance3D] = []   # scoop guide dots
var _cut_segs: Array[MeshInstance3D] = []
var _front: MeshInstance3D
var _target: MeshInstance3D
var _mat_ink: StandardMaterial3D
var _mat_cut: StandardMaterial3D
var _mat_front: StandardMaterial3D
var _mat_good: StandardMaterial3D
var _mat_bad: StandardMaterial3D
var _hid_body_eye := false
var _cut_mesh: MeshInstance3D
var _cut_n := 0
var _skin_rows: Array = []              # per ring sample: [left, centre, right] on the skin, plane-local
var _mat_wound: StandardMaterial3D
var scoop_r := 0.0185                   # the circle the spoon follows, just outside the eye
var _eye_pivot: Node3D                  # the scoop's eye rocks and lifts about its centre
var _eye_base := Vector3.ZERO
var _eye_k := 0.0
var _stalk: MeshInstance3D
var _slice_t := -1.0                    # >= 0 while the slice plays out (replicated)
var _nerve2: MeshInstance3D             # the upper end of the parted nerve
var _flush: MeshInstance3D
var _flush_mat: StandardMaterial3D
var _mat_mark: StandardMaterial3D
var _mat_thread: StandardMaterial3D
var _stitches: Array[MeshInstance3D] = []
var _stitch_theta: Array[float] = []
var _ring_theta: Array[float] = []
var bot_slow := 1.0                     # tests and smoke looks: slow the cut bot down
var bot_wait := 0.0                     # ... and how long it waits before pulling the eye up
var bot_hold := 0.0                     # ... and make it hover this many seconds before lowering
var _dt := 0.016
var _cut_yaw := 0.0                     # the cut scalpel's heading, eased round as it follows the marking
var _cut_h := 0.03                      # its tip height above the plane: hovering, dropping onto the eye


func setup(context: Dictionary) -> void:
	super.setup(context)
	variant = String(ctx.get("variant", ctx.get("step", {}).get("variant", "cut")))
	no_fail = bool(ctx.get("no_fail", false))
	eye_kind = String(ctx.get("eye_kind", "eye_hive" if String(ctx.get("patient_id", "hive")) == "hive" else "eye_surgeon"))
	if variant == "seat":
		eye_kind = String(ctx.get("eye_kind_in", eye_kind))
	eye_r = float(ctx.get("eye_radius", eye_r))
	ring_r = eye_r + RING_GAP
	_build()
	if variant == "scoop" or variant == "seat":
		_hide_body_eye(true)
	_update_visuals()


func _exit_tree() -> void:
	_hide_body_eye(false)


## The scoop draws its own eye, so the body's is hidden while it plays (the body reads this meta).
func _hide_body_eye(on: bool) -> void:
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and (on or _hid_body_eye):
		body.set_meta("eye_hidden", on)
		_hid_body_eye = on


func plane_extent() -> Vector2:
	return Vector2(0.085, 0.06)


func camera_pose() -> Dictionary:
	if variant == "snip":
		# Low and from the side: the eye rests over the socket and rises off it.
		return {"height": 0.13, "back": 0.17, "fov": 42.0}
	return {"height": 0.3, "back": 0.06, "fov": 48.0}


# ---------------------------------------------------------------------------- rules

func _rel_angle(p: Vector2) -> float:
	return fposmod(atan2(p.y, p.x) + PI * 0.5, TAU)


func _ring_pos(theta: float, r: float) -> Vector2:
	return Vector2(cos(theta - PI * 0.5), sin(theta - PI * 0.5)) * r


func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	var raw := p.distance_to(_last_cursor) / maxf(delta, 0.0001) if _have_last else 0.0
	_speed = lerpf(_speed, raw, 0.3)
	_last_cursor = p
	_have_last = true
	cursor = p
	_hint_t = maxf(0.0, _hint_t - delta)
	_dt = delta
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var pressed := primary and not _prev_primary
	_prev_primary = primary
	match variant:
		"cut", "stitch":
			_rules_cut(p, pressed)
		"scoop", "seat":
			_rules_scoop(p, pressed)
		"snip":
			_rules_snip(p, pressed, (buttons & BUTTON_UP) != 0, delta)


func _slip(why: String) -> void:
	down = false
	slips += 1
	_flash = 0.5
	_speed = 0.0
	_hint = why
	_hint_t = 3.0


func _hurt(amount: float, why: String) -> void:
	if not no_fail:
		botch(amount, why)


func _rules_cut(p: Vector2, pressed: bool) -> void:
	if not down:
		if pressed:
			if p.length() <= ring_r + 0.02:
				down = true
				_speed = 0.0
				if p.length() < eye_r * 0.9:
					_slip("The scalpel touched the eyeball. Line up over the marking and click again.")
					_hurt(NICK_BOTCH, "The scalpel nicked the eyeball")
			else:
				_hint = "Hold the scalpel over the eye, then click to lower it."
				_hint_t = 2.0
		return
	var r := p.length()
	if r > ring_r + CUT_LEAVE:
		_slip("The scalpel slipped off the eye. Line up over it and click to lower it again.")
	elif _speed > CUT_MAX_SPEED:
		_slip("Too fast: the scalpel slipped out. Line up and click to lower it again.")
	elif r < eye_r * 0.9:
		_slip("The scalpel touched the eyeball. Line up over the marking and click again.")
		_hurt(NICK_BOTCH, "The scalpel nicked the eyeball")
	elif absf(r - ring_r) <= CUT_LINE_TOL:
		var a := _rel_angle(p)
		if a >= cut - CUT_BEHIND and a <= cut + CUT_AHEAD:
			cut = maxf(cut, a)
		elif cut > TAU - 0.7 and a < 0.4:
			cut = TAU
	progress = clampf(cut / TAU, 0.0, 0.99)
	if cut >= TAU - 0.06:
		cut = TAU
		progress = 1.0
		finish({"eye_stitched": true} if variant == "stitch" else {"eye_cut": true})


func _rules_scoop(p: Vector2, pressed: bool) -> void:
	if not down:
		if pressed:
			if p.length() <= SCOOP_R_MAX:
				down = true
				_speed = 0.0
				_last_a = atan2(p.y, p.x)
			else:
				_hint = "Hold the spoon over the socket, then click to lower it."
				_hint_t = 2.0
		return
	var r := p.length()
	if r > SCOOP_LEAVE:
		_slip("The spoon slipped out of the socket. Line up inside it and click again.")
		return
	if _speed > SCOOP_MAX_SPEED:
		_slip("Too fast: the spoon slipped out. Line up inside the socket and click again.")
		return
	if r >= SCOOP_R_MIN and r <= SCOOP_R_MAX:
		var a := atan2(p.y, p.x)
		turns += minf(absf(angle_difference(_last_a, a)), 0.3)
		_last_a = a
	progress = clampf(turns / (TAU * SCOOP_TURNS), 0.0, 0.99)
	if turns >= TAU * SCOOP_TURNS:
		progress = 1.0
		finish({"eye_seated": true} if variant == "seat" else {"eye_out": true})


func _rules_snip(p: Vector2, pressed: bool, up: bool, delta: float) -> void:
	if _slice_t >= 0.0:
		# the slice plays out, then the step is done
		_slice_t += delta
		progress = clampf(_slice_t / SLICE_TIME, 0.0, 0.99)
		if _slice_t >= SLICE_TIME:
			progress = 1.0
			finish({"eye_removed": true})
		return
	if up:
		lift = minf(1.0, lift + delta / LIFT_UP_SECONDS)
	else:
		lift = maxf(0.0, lift - delta / LIFT_DOWN_SECONDS)
	progress = 0.0
	if not pressed:
		return
	if lift < SLICE_READY:
		_hint = "Pull the eye up first: hold W."
		_hint_t = 2.0
	elif p.distance_to(NERVE_AT) <= SLICE_TOL:
		_slice_t = 0.0
	else:
		slips += 1
		_flash = 0.5
		_hint = "Missed the nerve. Aim the scalpel at it and click."
		_hint_t = 2.5
		_hurt(MISS_BOTCH, "The scalpel missed the nerve")


func tick(delta: float) -> void:
	_t += delta
	_dt = delta
	_flash = maxf(0.0, _flash - delta)
	if slips != _seen_slips:
		_seen_slips = slips
		_flash = 0.5
	_update_visuals()


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var hint := _hint if _hint_t > 0.0 else ""
	if hint == "":
		match variant:
			"cut":
				hint = "Click to lower the scalpel onto the eye, then trace the marking slowly." if not down else "Trace the marking. Not too fast."
			"scoop":
				hint = "Click to lower the spoon into the socket, then circle it slowly and lightly." if not down else "Circle the inside of the socket. Slowly."
			"snip":
				hint = "Hold W to pull the eye up. When the nerve shows, aim the scalpel at it and click."
			"seat":
				hint = "Click to lower the new eye into the socket, then circle it slowly to settle it in." if not down else "Circle slowly. It is nearly seated."
			"stitch":
				hint = "Click to set the needle on the cut, then trace it round. The socket closes behind you." if not down else "Trace the cut. Not too fast."
	return {"title": String(ctx.get("step", {}).get("label", "")), "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"d": down, "c": snappedf(cut, 0.01), "u": snappedf(turns, 0.02), "l": snappedf(lift, 0.01), "s": slips,
		"cur": cursor, "t": snappedf(_t, 0.05), "p": snappedf(progress, 0.001), "sl": snappedf(_slice_t, 0.02)}


func apply_net_state(s: Dictionary) -> void:
	down = bool(s.get("d", down))
	cut = float(s.get("c", cut))
	turns = float(s.get("u", turns))
	lift = float(s.get("l", lift))
	slips = int(s.get("s", slips))
	cursor = s.get("cur", cursor)
	_t = float(s.get("t", _t))
	_slice_t = float(s.get("sl", _slice_t))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

## skill 1: slow and steady; skill 0: a heavy hand (too fast, so it slips and has to re-lower).
func bot_input(t: float, skill: float) -> Dictionary:
	var dt := clampf(t - _bt, 0.0, 0.1)
	_bt = t
	skill = clampf(skill, 0.0, 1.0)
	_bang += 1.0
	var click := int(_bang) % 2 == 0   # a click every other call, so the press registers
	match variant:
		"cut", "stitch":
			if cut >= TAU:
				return {"cursor": cursor, "buttons": 0}
			var front := _ring_pos(cut + 0.05, ring_r)
			if not down:
				var c := cursor.move_toward(front, 0.3 * bot_slow * dt)
				return {"cursor": c, "buttons": BUTTON_PRIMARY if c.distance_to(front) < 0.006 and click and t > bot_hold else 0}
			return {"cursor": cursor.move_toward(front, lerpf(0.12, 0.05, skill) * bot_slow * dt), "buttons": 0}
		"scoop", "seat":
			if not down:
				var c := cursor.move_toward(Vector2(0.012, 0.0), 0.2 * dt)
				return {"cursor": c, "buttons": BUTTON_PRIMARY if c.length() < 0.02 and click else 0}
			var a := atan2(cursor.y, cursor.x) + lerpf(0.1, 0.045, skill) * bot_slow * dt / scoop_r
			return {"cursor": Vector2(cos(a), sin(a)) * scoop_r, "buttons": 0}
		_:
			if _slice_t >= 0.0:
				return {"cursor": NERVE_AT, "buttons": 0}
			if t < bot_wait:
				return {"cursor": cursor.move_toward(NERVE_AT, 0.3 * dt), "buttons": 0}
			if lift < 0.95:
				return {"cursor": cursor.move_toward(NERVE_AT, 0.3 * dt), "buttons": BUTTON_UP}
			return {"cursor": NERVE_AT, "buttons": (BUTTON_PRIMARY | BUTTON_UP) if (click and t > bot_hold) else BUTTON_UP}


# ---------------------------------------------------------------------------- visuals

func _unshaded(col: Color, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true   # the marking and the cut never hide under the skin's swell around the eye
	m.render_priority = 2
	return m


func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	add_child(mi)
	return mi


func _build() -> void:
	if _built:
		return
	_built = true
	_mat_wound = StandardMaterial3D.new()
	_mat_wound.albedo_color = Color(0.42, 0.02, 0.03)
	_mat_wound.emission_enabled = true
	_mat_wound.emission = Color(0.35, 0.0, 0.0)
	_mat_wound.emission_energy_multiplier = 0.7
	_mat_wound.roughness = 0.25
	_mat_wound.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_ink = _unshaded(INK_SHEEN, 0.95)
	_mat_cut = _unshaded(Color(0.55, 0.02, 0.03), 1.0)
	_mat_front = _unshaded(Color(1.0, 0.45, 0.4), 1.0)
	_mat_good = _unshaded(Color(0.35, 1.0, 0.55), 0.9)
	_mat_bad = _unshaded(Color(1.0, 0.25, 0.2), 0.95)
	# The eye (the scoop and snip draw their own; the cut leaves the body's).
	if variant == "scoop" or variant == "snip" or variant == "seat":
		_build_scoop_eye()
		if variant == "seat" and _eye != null:
			_eye.material_override = Eyes.material(eye_kind)   # the eye going IN, not the body's old one
	elif variant != "cut" and variant != "stitch":
		_eye = MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = eye_r * 1.02
		sph.height = eye_r * 2.04
		sph.radial_segments = 20
		sph.rings = 10
		_eye.mesh = sph
		_eye.material_override = Eyes.material(eye_kind)
		add_child(_eye)
	match variant:
		"cut", "stitch":
			# The marking: dashes round the ring with a hash tick across every other one, in surgical violet.
			# A fine, dim guide line: thin dashes and short ticks. Each hides once the cut has passed it.
			_mat_mark = _unshaded(Color(0.62, 0.5, 0.82), 0.6)
			for i in DASHES:
				var th := TAU * (float(i) + 0.5) / float(DASHES)
				var dash := _box(Vector3(TAU * ring_r / float(DASHES) * 0.5, 0.0006, 0.0011), _mat_mark)
				_place_on_ring(dash, th, ring_r, 0.0016)
				_ring.append(dash)
				_ring_theta.append(th)
				if i % 2 == 0:
					var tick := _box(Vector3(0.0006, 0.0006, 0.0055), _mat_mark)
					_place_on_ring(tick, th, ring_r, 0.0016)
					_ring.append(tick)
					_ring_theta.append(th)
			# The incision itself: a dark red ribbon laid on the body's real skin along the ring (heights from a
			# ray cast down onto its mesh), growing as the cut does.
			_sample_skin()
			_cut_mesh = MeshInstance3D.new()
			_cut_mesh.material_override = _mat_wound
			_cut_mesh.top_level = false
			add_child(_cut_mesh)
			_front = _box(Vector3(0.004, 0.002, 0.004), _mat_front)
			if variant == "stitch":
				# The cut is already open all the way round; the needle closes it behind itself.
				_mat_thread = _unshaded(Color(0.1, 0.08, 0.14), 1.0)
				for i in STITCHES:
					var sth := TAU * (float(i) + 0.5) / float(STITCHES)
					var st_box := _box(Vector3(0.0016, 0.0008, 0.0085), _mat_thread)
					_place_on_ring(st_box, sth, ring_r, 0.0022)
					st_box.visible = false
					_stitches.append(st_box)
					_stitch_theta.append(sth)
		"scoop", "seat":
			# A dim dotted circle just outside the eye to circle along; dots turn green as the turns add up.
			_mat_mark = _unshaded(Color(0.62, 0.5, 0.82), 0.6)
			for i in 24:
				var d := _box(Vector3(0.0022, 0.0006, 0.0022), _mat_mark)
				var th := TAU * float(i) / 24.0
				d.position = plane_to_local(Vector2(cos(th), sin(th)) * scoop_r, 0.0016)
				_dots.append(d)
			# The socket's wet dark rim: a ribbon on the skin all the way round, just outside the eye.
			var rim_mat := StandardMaterial3D.new()
			rim_mat.albedo_color = Color(0.13, 0.01, 0.02)
			rim_mat.roughness = 0.05
			rim_mat.metallic_specular = 0.9
			rim_mat.emission_enabled = true
			rim_mat.emission = Color(0.16, 0.0, 0.0)
			rim_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			var rim := MeshInstance3D.new()
			rim.mesh = _ribbon(_skin_ring(eye_r * 1.12, 0.0016), CUT_SAMPLES)
			rim.material_override = rim_mat
			add_child(rim)
		"snip":
			# The socket is empty: its wet rim on the skin. The eye rests over it on a pale nerve (two pieces
			# once sliced), and a small red flush blooms where the blade parts it.
			_add_rim()
			_nerve_mat = StandardMaterial3D.new()
			_nerve_mat.albedo_color = Color(0.9, 0.78, 0.66)
			_nerve_mat.roughness = 0.3
			_nerve_mat.emission_enabled = true
			_nerve_mat.emission = Color(0.5, 0.4, 0.3)
			_nerve_mat.emission_energy_multiplier = 0.0
			_nerve = _box(Vector3(1.0, 1.0, 1.0), _nerve_mat)
			_nerve2 = _box(Vector3(1.0, 1.0, 1.0), _nerve_mat)
			_nerve2.visible = false
			# the slice target: a thin ring of dots on the plane under the nerve, lit when it can be cut
			_target = MeshInstance3D.new()
			add_child(_target)
			for i in 16:
				var th := TAU * float(i) / 16.0
				var dot := MeshInstance3D.new()
				var dm := BoxMesh.new()
				dm.size = Vector3(0.0018, 0.0008, 0.0018)
				dot.mesh = dm
				dot.material_override = _mat_good
				dot.position = plane_to_local(NERVE_AT + Vector2(cos(th), sin(th)) * SLICE_TOL, 0.002)
				_target.add_child(dot)
			_target.visible = false
			_flush_mat = StandardMaterial3D.new()
			_flush_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_flush_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_flush_mat.albedo_color = Color(0.75, 0.02, 0.03, 0.0)
			_flush = MeshInstance3D.new()
			var fs := SphereMesh.new()
			fs.radius = 0.003
			fs.height = 0.006
			_flush.mesh = fs
			_flush.material_override = _flush_mat
			_flush.visible = false
			add_child(_flush)
	_tool = _make_cut_scalpel() if (variant == "cut" or variant == "snip" or variant == "stitch") else (_make_scoop_spoon() if (variant == "scoop" or variant == "seat") else ItemModels.make("scalpel"))
	add_child(_tool)
	_set_layers(self)


## The scoop's spoon: a slim handle and a shallow bowl, bowl down at the origin, handle up.
func _make_scoop_spoon() -> Node3D:
	var root := Node3D.new()
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.9, 0.92, 0.95)
	steel.metallic = 0.6
	steel.roughness = 0.22
	var bowl := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.0075
	sph.height = 0.015
	sph.radial_segments = 16
	sph.rings = 8
	bowl.mesh = sph
	bowl.material_override = steel
	bowl.scale = Vector3(1.0, 0.4, 1.25)
	bowl.position = Vector3(0, 0.0025, 0)
	root.add_child(bowl)
	var neck := MeshInstance3D.new()
	var nc := CylinderMesh.new()
	nc.top_radius = 0.0018
	nc.bottom_radius = 0.0011
	nc.height = 0.012
	neck.mesh = nc
	neck.material_override = steel
	neck.position = Vector3(0, 0.011, 0)
	root.add_child(neck)
	var handle := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.0034
	hc.bottom_radius = 0.0026
	hc.height = 0.06
	hc.radial_segments = 10
	handle.mesh = hc
	handle.material_override = steel
	handle.position = Vector3(0, 0.047, 0)
	root.add_child(handle)
	return root


## The scoop's eye is a copy of the body's own eye (same mesh and material, same place), wrapped in a pivot at
## its centre so it can rock and lift; the body's eye is hidden while this plays. Without a body it is a sphere.
func _build_scoop_eye() -> void:
	_eye_pivot = Node3D.new()
	add_child(_eye_pivot)
	var src: MeshInstance3D = null
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and is_inside_tree():
		src = body.parts.get("eye_node") as MeshInstance3D if body.get("parts") != null else null
	if src != null and src.mesh != null:
		var ab := src.mesh.get_aabb()
		var center_l := to_local(src.global_transform * ab.get_center())
		_eye_base = center_l
		_eye_pivot.position = center_l
		_eye = MeshInstance3D.new()
		_eye.mesh = src.mesh
		_eye.material_override = src.get_active_material(0)
		_eye_pivot.add_child(_eye)
		# put the copy exactly over the body's eye
		_eye.global_transform = src.global_transform
	else:
		_eye = MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = eye_r * 1.02
		sph.height = eye_r * 2.04
		sph.radial_segments = 20
		sph.rings = 10
		_eye.mesh = sph
		_eye.material_override = Eyes.material(eye_kind)
		_eye.basis = Basis(Vector3.RIGHT, deg_to_rad(90.0))
		_eye_pivot.add_child(_eye)
		_eye_base = plane_to_local(Vector2.ZERO, eye_r * 0.85)
		_eye_pivot.position = _eye_base
	var stalk_mat := StandardMaterial3D.new()
	stalk_mat.albedo_color = Color(0.85, 0.7, 0.62)
	stalk_mat.roughness = 0.3
	_stalk = _box(Vector3(0.0045, 0.0045, 1.0), stalk_mat)
	_stalk.visible = false


## The empty socket wet dark rim, laid on the skin (as the scoop has).
func _add_rim() -> void:
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.13, 0.01, 0.02)
	rim_mat.roughness = 0.05
	rim_mat.metallic_specular = 0.9
	rim_mat.emission_enabled = true
	rim_mat.emission = Color(0.16, 0.0, 0.0)
	rim_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var rim := MeshInstance3D.new()
	rim.mesh = _ribbon(_skin_ring(eye_r * 1.12, 0.0016), CUT_SAMPLES)
	rim.material_override = rim_mat
	add_child(rim)


## Ray-cast rows [left, centre, right] on the body's skin along a ring of radius `r` (see _sample_skin).
func _skin_ring(r: float, hw: float) -> Array:
	var tri: TriangleMesh = null
	var mi: MeshInstance3D = null
	var body = ctx.get("body")
	if body != null and is_instance_valid(body) and is_inside_tree():
		mi = body.find_child("Human", true, false) as MeshInstance3D
		if mi != null and mi.mesh != null and mi.is_inside_tree():
			tri = mi.mesh.generate_triangle_mesh()
	var to_mesh: Transform3D = mi.global_transform.affine_inverse() if tri != null else Transform3D()
	var rows := []
	for i in CUT_SAMPLES + 1:
		var c2 := _ring_pos(TAU * float(i) / float(CUT_SAMPLES), r)
		var radial := c2.normalized()
		var row := []
		for off in [-hw, 0.0, hw]:
			var q: Vector2 = c2 + radial * off
			var lp := plane_to_local(q, 0.002)
			if tri != null:
				var from := to_mesh * to_global(plane_to_local(q, 0.06))
				var dir := (to_mesh.basis * (global_transform.basis * Vector3.DOWN)).normalized()
				var hit: Dictionary = tri.intersect_ray(from, dir)
				if not hit.is_empty():
					lp = to_local(mi.global_transform * (hit.position as Vector3) + (mi.global_transform.basis * (hit.normal as Vector3)).normalized() * WOUND_LIFT)
			row.append(lp)
		rows.append(row)
	return rows


func _ribbon(rows: Array, n: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in mini(n, rows.size() - 1):
		var a: Array = rows[i]
		var b: Array = rows[i + 1]
		for v in [a[0], a[2], b[0], a[2], b[2], b[0]]:
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


## The cut's scalpel: a slim handle and a small pointed blade, tip down at the origin, handle up, so it hangs
## over the eye and drops onto it.
func _make_cut_scalpel() -> Node3D:
	var root := Node3D.new()
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.9, 0.92, 0.95)
	steel.metallic = 0.6
	steel.roughness = 0.25
	var grip := StandardMaterial3D.new()
	grip.albedo_color = Color(0.6, 0.63, 0.68)
	grip.metallic = 0.5
	grip.roughness = 0.4
	var blade := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.006, 0.017, 0.0011)
	blade.mesh = prism
	blade.material_override = steel
	blade.rotation_degrees = Vector3(0, 0, 180)   # the point down
	blade.position = Vector3(0, 0.0085, 0)
	root.add_child(blade)
	var neck := MeshInstance3D.new()
	var nc := CylinderMesh.new()
	nc.top_radius = 0.0028
	nc.bottom_radius = 0.0012
	nc.height = 0.008
	neck.mesh = nc
	neck.material_override = grip
	neck.position = Vector3(0, 0.021, 0)
	root.add_child(neck)
	var handle := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.0034
	hc.bottom_radius = 0.0028
	hc.height = 0.06
	hc.radial_segments = 10
	handle.mesh = hc
	handle.material_override = grip
	handle.position = Vector3(0, 0.055, 0)
	root.add_child(handle)
	return root


## Ray-cast down onto the body's skin (its mesh at rest) at every ring sample, left / centre / right of the
## line, and keep the hits plane-local. Without a body (tests) the ribbon lies flat on the plane.
func _sample_skin() -> void:
	var tri: TriangleMesh = null
	var mi: MeshInstance3D = null
	var body = ctx.get("body")
	if body != null and is_instance_valid(body):
		mi = body.find_child("Human", true, false) as MeshInstance3D
		if mi != null and mi.mesh != null:
			tri = mi.mesh.generate_triangle_mesh()
	var to_mesh: Transform3D = mi.global_transform.affine_inverse() if tri != null and mi.is_inside_tree() and is_inside_tree() else Transform3D()
	if tri != null and not (mi.is_inside_tree() and is_inside_tree()):
		tri = null
	for i in CUT_SAMPLES + 1:
		var th := TAU * float(i) / float(CUT_SAMPLES)
		var c2 := _ring_pos(th, ring_r)
		var radial := c2.normalized()
		var row := []
		for off in [-WOUND_HW, 0.0, WOUND_HW]:
			var q: Vector2 = c2 + radial * off
			var lp := plane_to_local(q, 0.002)
			if tri != null:
				var from := to_mesh * to_global(plane_to_local(q, 0.06))
				var dir := (to_mesh.basis * (global_transform.basis * Vector3.DOWN)).normalized()
				var hit: Dictionary = tri.intersect_ray(from, dir)
				if not hit.is_empty():
					var gp: Vector3 = mi.global_transform * (hit.position as Vector3)
					var gn: Vector3 = (mi.global_transform.basis * (hit.normal as Vector3)).normalized()
					lp = to_local(gp + gn * WOUND_LIFT)
			row.append(lp)
		_skin_rows.append(row)


## Rebuild the ribbon up to the cut so far, when it has grown by a sample.
func _grow_cut() -> void:
	var n := clampi(int(floor(cut / TAU * float(CUT_SAMPLES))), 0, CUT_SAMPLES)
	if cut >= TAU:
		n = CUT_SAMPLES
	if n == _cut_n or _cut_mesh == null or _skin_rows.is_empty():
		return
	_cut_n = n
	var lo := n if variant == "stitch" else 0
	var hi := CUT_SAMPLES if variant == "stitch" else n
	if hi <= lo:
		_cut_mesh.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(lo, hi):
		var a: Array = _skin_rows[i]
		var b: Array = _skin_rows[i + 1]
		for tri_v in [a[0], a[2], b[0], a[2], b[2], b[0]]:
			st.add_vertex(tri_v)
	st.generate_normals()
	_cut_mesh.mesh = st.commit()


func _place_on_ring(mi: MeshInstance3D, theta: float, r: float, lift_y: float) -> void:
	mi.position = plane_to_local(_ring_pos(theta, r), lift_y)
	# the box's long side (its X) along the tangent, so the ring reads as a marked line
	var tangent := _ring_pos(theta + 0.01, r) - _ring_pos(theta - 0.01, r)
	mi.rotation = Vector3(0.0, -atan2(tangent.y, tangent.x), 0.0)


func _set_layers(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as VisualInstance3D).layers = OWN_LAYER
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c)


func _update_visuals() -> void:
	if not _built:
		return
	# The tool's tip on the cursor: on the plane when lowered, hovering above it when not. The model's tip
	# is at +X, so the handle trails to the left of the screen, tilted up.
	if variant != "":
		# Upright over the eye, leaning a little away from its centre; it turns slowly to stay that way as it
		# follows the marking (or circles the socket), and drops onto the eye when lowered.
		if cursor.length() > 0.004:
			_cut_yaw = lerp_angle(_cut_yaw, atan2(cursor.x, cursor.y), clampf(_dt * 2.5, 0.0, 1.0))
		if variant == "snip":
			# hangs over the nerve; drops onto it the moment the slice starts
			_cut_h = move_toward(_cut_h, 0.012 if _slice_t >= 0.0 else 0.04, _dt * 0.4)
		else:
			_cut_h = move_toward(_cut_h, (CUT_TIP_Y if (variant == "cut" or variant == "stitch") else SCOOP_TIP_Y) if down else 0.03, _dt * 0.25)
		_tool.basis = Basis(Vector3.UP, _cut_yaw) * Basis(Vector3.RIGHT, deg_to_rad(22.0))
		_tool.position = plane_to_local(cursor, _cut_h)
	else:
		var tip_y := 0.004 if (down or variant == "snip") else 0.03
		var tilt := Basis(Vector3(0, 0, 1), deg_to_rad(18.0))
		_tool.basis = tilt
		_tool.position = plane_to_local(cursor, tip_y) - tilt * Vector3(TIP_X, 0.0, 0.0)
	match variant:
		"cut", "stitch":
			_grow_cut()
			for i in _stitches.size():
				_stitches[i].visible = _stitch_theta[i] <= cut
			_front.visible = cut < TAU
			_front.position = plane_to_local(_ring_pos(cut, ring_r), 0.003)
			_front.material_override = _mat_bad if _flash > 0.0 else _mat_front
			var col := _mat_bad if _flash > 0.0 else _mat_mark
			for i in _ring.size():
				_ring[i].material_override = col
				_ring[i].visible = _ring_theta[i] > cut
		"scoop", "seat":
			var k := clampf(turns / (TAU * SCOOP_TURNS), 0.0, 1.0)
			if variant == "seat":
				k = 1.0 - k   # the new eye comes down into the socket instead of rising out of it
			# The eye rocks toward the spoon and lifts a little more each turn on its stalk; when the spoon
			# slips out it settles back (the turns stay).
			_eye_k = move_toward(_eye_k, k if down else k * 0.7, _dt * 0.5)
			var lean := cursor.normalized() if cursor.length() > 0.002 else Vector2.ZERO
			var axis := Vector3(lean.y, 0.0, -lean.x)
			var rock := (0.05 + 0.2 * _eye_k) if down else 0.0
			_eye_pivot.basis = Basis(axis.normalized(), rock) if axis.length() > 0.001 else Basis()
			_eye_pivot.position = _eye_base + Vector3(0.0, _eye_k * 0.009, 0.0)
			# the stalk from the bottom of the socket up to the eye, stretching as it lifts
			var sa := plane_to_local(Vector2.ZERO, -0.004)
			var sb := _eye_pivot.position - Vector3(0.0, eye_r * 0.7, 0.0)
			var sd := sb - sa
			var sl := maxf(sd.length(), 0.001)
			var sz := sd / sl
			var sy := sz.cross(Vector3.RIGHT).normalized()
			var sx := sy.cross(sz).normalized()
			_stalk.transform = Transform3D(Basis(sx, sy, sz * sl), (sa + sb) * 0.5)
			_stalk.visible = _eye_k > 0.03
			for i in _dots.size():
				_dots[i].material_override = _mat_good if float(i) / 24.0 < k else (_mat_bad if _flash > 0.0 else _mat_mark)
		"snip":
			var slicing := _slice_t >= 0.0
			var sp := clampf(_slice_t / SLICE_TIME, 0.0, 1.0) if slicing else 0.0
			var ready := lift >= SLICE_READY and not slicing
			# The eye rests over the socket and rises on its nerve as W is held (a slight tremble when taut);
			# once the nerve is parted it settles back down.
			var rise := lift * (1.0 - 0.6 * sp)
			var tremble := sin(_t * 47.0) * 0.0003 * clampf((lift - 0.7) / 0.3, 0.0, 1.0) * (1.0 - sp)
			_eye_pivot.position = _eye_base + Vector3(tremble, 0.003 + rise * 0.036, 0.0)
			_eye_pivot.basis = Basis(Vector3.RIGHT, rise * 0.6)
			var a := NERVE_BASE
			var b := _eye_pivot.position + Vector3(0.0, -eye_r * 0.7, eye_r * 0.7)
			var d := b - a
			var len := maxf(d.length(), 0.001)
			var z := d / len
			var y := z.cross(Vector3.RIGHT).normalized()
			var x := y.cross(z).normalized()
			# stretching thins it; the whole thing is only shown once the eye is clear of the socket
			var thick := lerpf(0.0065, 0.003, lift)
			var reveal := clampf((lift - 0.08) / 0.3, 0.0, 1.0)
			_nerve_mat.emission_energy_multiplier = (0.9 + 0.3 * sin(_t * 8.0)) if ready else 0.0
			if not slicing:
				_nerve.transform = Transform3D(Basis(x * thick, y * thick, z * len), (a + b) * 0.5)
				_nerve.visible = reveal > 0.02
				_nerve2.visible = false
			else:
				# two ends parting and recoiling from the middle
				var mid := (a + b) * 0.5
				var gap := 0.002 + sp * 0.007
				var lo_end := mid - z * gap
				var up_start := mid + z * gap
				var lo_b := a.lerp(lo_end, 1.0 - 0.55 * sp)
				var up_a := b.lerp(up_start, 1.0 - 0.55 * sp)
				var ll := maxf(lo_b.distance_to(a), 0.001)
				var ul := maxf(up_a.distance_to(b), 0.001)
				_nerve.transform = Transform3D(Basis(x * thick, y * thick, z * ll), (a + lo_b) * 0.5)
				_nerve2.transform = Transform3D(Basis(x * thick, y * thick, z * ul), (b + up_a) * 0.5)
				_nerve.visible = true
				_nerve2.visible = true
				_flush.visible = true
				_flush.position = mid
				_flush.scale = Vector3.ONE * (0.6 + sp * 1.2)
				_flush_mat.albedo_color.a = 0.5 * (1.0 - sp)
			_target.visible = ready
			for dot in _target.get_children():
				(dot as MeshInstance3D).material_override = _mat_bad if _flash > 0.0 else _mat_good
