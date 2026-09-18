extends "res://scripts/surgery/minigame.gd"
## Steps of "Eyeball Extraction" (ailment `eye_extraction`, GRAFTING part one), three variants on one
## work plane centred on the eye (site "eye"):
##
##   cut    (scalpel)   Hold the button and follow the ring of green dots around the eye, in order.
##                      Wandering off the ring with the blade down slips it (botch).
##   scoop  (eye spoon) Hold the button with the spoon over the eye and ease it up out of the socket
##                      over a few seconds. Yanking (moving fast) pinches it (botch); letting go
##                      pauses.
##   snip   (scalpel)   The optic nerve runs back from the eye. A blade marker sweeps across it:
##                      click while the marker is on the green mark. Off it, the blade nicks the eye.
##
## Results: cut {"eye_cut": true}, scoop {"eye_out": true}, snip {"eye_removed": true}.
## The same script will play the graft's steps later (variants are data), so it only reads
## ctx.variant and the case flags.

const RING_R := 0.03
const DOTS := 12
const DOT_TOL := 0.011
const LINE_TOL := 0.017
const SLIP_BOTCH := 5.0
const SLIP_CD := 0.9
const SCOOP_SECONDS := 3.2
const SCOOP_REACH := 0.026
const SCOOP_MAX_SPEED := 0.16          # m/s of cursor speed the spoon tolerates
const YANK_BOTCH := 8.0
const YANK_CD := 1.2
const NERVE_AT := Vector2(0.0, 0.05)
const SWEEP_HALF := 0.045
const SWEEP_PERIOD := 2.4
const SNIP_ZONE := 0.009
const SNIP_REACH := 0.03
const NICK_BOTCH := 6.0
const NICK_CD := 0.7

var variant := "cut"
# replicated
var idx := 0                          # cut: dots reached
var cursor := Vector2(0.0, -0.06)
var lift := 0.0                       # scoop: 0..1
var held := false
var _t := 0.0                         # the sweep's clock

# operator only
var _prev_primary := false
var _cd := 0.0
var _jolt_t := 0.0
var _jolt_off := Vector2.ZERO
var _last_cursor := Vector2.ZERO
var _speed := 0.0
var _flash := 0.0
var _hint := ""
var _hint_t := 0.0

# visuals
var _built := false
var _dots: Array[MeshInstance3D] = []
var _tool: MeshInstance3D
var _eye_copy: MeshInstance3D
var _nerve: MeshInstance3D
var _marker: MeshInstance3D
var _zone: MeshInstance3D
var _mat_next: StandardMaterial3D
var _mat_done: StandardMaterial3D
var _mat_idle: StandardMaterial3D
var _mat_bad: StandardMaterial3D
var _mat_eye: StandardMaterial3D


func setup(context: Dictionary) -> void:
	super.setup(context)
	variant = String(ctx.get("variant", ctx.get("step", {}).get("variant", "cut")))
	_build()
	_update_visuals()


func plane_extent() -> Vector2:
	return Vector2(0.1, 0.085)


func camera_pose() -> Dictionary:
	return {"height": 0.34, "back": 0.1, "fov": 50.0}


# ---------------------------------------------------------------------------- rules

func _dot_pos(i: int) -> Vector2:
	# Start at the top of the ring and go round.
	var a := -PI * 0.5 + TAU * float(i) / float(DOTS)
	return Vector2(cos(a), sin(a)) * RING_R


func _marker_x() -> float:
	return sin(_t * TAU / SWEEP_PERIOD) * SWEEP_HALF


func handle_cursor(p: Vector2, buttons: int, delta: float) -> void:
	if done:
		return
	_speed = p.distance_to(_last_cursor) / maxf(delta, 0.0001) if _last_cursor != Vector2.ZERO else 0.0
	_last_cursor = p
	cursor = p
	_cd = maxf(0.0, _cd - delta)
	var primary := (buttons & BUTTON_PRIMARY) != 0
	var pressed := primary and not _prev_primary
	_prev_primary = primary
	held = primary
	match variant:
		"cut":
			_rules_cut(p, primary)
		"scoop":
			_rules_scoop(p, primary, delta)
		"snip":
			_rules_snip(p, pressed)


func _rules_cut(p: Vector2, primary: bool) -> void:
	if not primary:
		return
	if idx < DOTS and p.distance_to(_dot_pos(idx)) <= DOT_TOL:
		idx += 1
		if idx >= DOTS:
			progress = 1.0
			finish({"eye_cut": true})
			return
	elif idx > 0 and _cd <= 0.0 and absf(p.length() - RING_R) > LINE_TOL:
		_cd = SLIP_CD
		_hint = "The blade slipped off the line."
		_hint_t = 2.0
		botch(SLIP_BOTCH, "The scalpel slipped off the line")
	progress = clampf(float(idx) / float(DOTS), 0.0, 0.99)


func _rules_scoop(p: Vector2, primary: bool, delta: float) -> void:
	if primary and p.length() <= SCOOP_REACH:
		if _speed > SCOOP_MAX_SPEED and _cd <= 0.0 and lift > 0.05:
			_cd = YANK_CD
			lift = maxf(0.0, lift - 0.12)
			_hint = "Slower: yanking pinches the eye."
			_hint_t = 2.0
			botch(YANK_BOTCH, "The spoon yanked at the eye")
		elif _speed <= SCOOP_MAX_SPEED:
			lift = minf(1.0, lift + delta / SCOOP_SECONDS)
	progress = clampf(lift, 0.0, 0.99)
	if lift >= 1.0:
		progress = 1.0
		finish({"eye_out": true})


func _rules_snip(p: Vector2, pressed: bool) -> void:
	progress = 0.0
	if not pressed or _cd > 0.0:
		return
	if p.distance_to(NERVE_AT) > SNIP_REACH:
		_cd = NICK_CD
		_hint = "Put the blade on the nerve first."
		_hint_t = 2.0
		return
	if absf(_marker_x()) <= SNIP_ZONE:
		progress = 1.0
		finish({"eye_removed": true})
	else:
		_cd = NICK_CD
		_flash = 0.4
		_hint = "Too early, too late: click on the green mark."
		_hint_t = 2.0
		botch(NICK_BOTCH, "The scalpel nicked the eye")


func on_jolt(offset: Vector2, _strength: float, duration: float) -> void:
	_jolt_off = offset
	_jolt_t = maxf(0.05, duration)


func tick(delta: float) -> void:
	_t += delta
	_flash = maxf(0.0, _flash - delta)
	_hint_t = maxf(0.0, _hint_t - delta)
	_update_visuals()


# ---------------------------------------------------------------------------- HUD / net

func hud_state() -> Dictionary:
	var hint := _hint if _hint_t > 0.0 else ""
	if hint == "":
		match variant:
			"cut":
				hint = "Hold the button and follow the green dots around the eye."
			"scoop":
				hint = "Hold the button with the spoon over the eye, and ease it up. Slowly."
			"snip":
				hint = "Put the blade on the nerve, then click when the marker is on the green mark."
	return {"title": String(ctx.get("step", {}).get("label", "")), "hint": hint, "progress": progress, "gauges": []}


func net_state() -> Dictionary:
	return {"i": idx, "c": cursor, "l": snappedf(lift, 0.01), "h": held, "t": snappedf(_t, 0.02), "p": snappedf(progress, 0.001)}


func apply_net_state(s: Dictionary) -> void:
	idx = int(s.get("i", idx))
	cursor = s.get("c", cursor)
	lift = float(s.get("l", lift))
	held = bool(s.get("h", held))
	_t = float(s.get("t", _t))
	progress = float(s.get("p", progress))


# ---------------------------------------------------------------------------- bot

func bot_input(t: float, skill: float) -> Dictionary:
	skill = clampf(skill, 0.0, 1.0)
	match variant:
		"cut":
			if idx >= DOTS:
				return {"cursor": cursor, "buttons": 0}
			var aim := _dot_pos(idx)
			if skill < 0.4 and int(t * 2.0) % 9 == 8:
				aim *= 1.9   # a sloppy hand strays wide now and then
			return {"cursor": cursor.move_toward(aim, 0.09 * 0.05), "buttons": BUTTON_PRIMARY}
		"scoop":
			return {"cursor": Vector2.ZERO, "buttons": BUTTON_PRIMARY}
		_:
			var on := absf(_marker_x()) <= SNIP_ZONE * lerpf(0.6, 1.0, skill)
			return {"cursor": NERVE_AT, "buttons": BUTTON_PRIMARY if on and int(t * 30.0) % 2 == 0 else 0}


# ---------------------------------------------------------------------------- visuals

func _unshaded(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.render_priority = 2
	return m


func _mesh(mesh: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 12
	s.rings = 6
	return s


func _build() -> void:
	if _built:
		return
	_built = true
	_mat_next = _unshaded(Color(0.3, 1.0, 0.45, 0.95))
	_mat_done = _unshaded(Color(0.3, 1.0, 0.45, 0.35))
	_mat_idle = _unshaded(Color(0.95, 0.95, 0.9, 0.55))
	_mat_bad = _unshaded(Color(1.0, 0.25, 0.2, 0.9))
	_mat_eye = StandardMaterial3D.new()
	_mat_eye.albedo_color = Color(0.95, 0.55, 0.15)
	_mat_eye.roughness = 0.2
	_mat_eye.emission_enabled = true
	_mat_eye.emission = Color(1.0, 0.45, 0.05)
	_mat_eye.emission_energy_multiplier = 0.6
	match variant:
		"cut":
			for i in DOTS:
				var d := _mesh(_sphere(0.0032), _mat_idle, plane_to_local(_dot_pos(i), 0.012))
				_dots.append(d)
		"scoop":
			_eye_copy = _mesh(_sphere(0.0155), _mat_eye, plane_to_local(Vector2.ZERO, 0.012))
		"snip":
			_eye_copy = _mesh(_sphere(0.0155), _mat_eye, plane_to_local(Vector2.ZERO, 0.02))
			var line := BoxMesh.new()
			line.size = Vector3(0.006, 0.004, NERVE_AT.y - 0.005)
			_nerve = _mesh(line, _mat_idle, plane_to_local(Vector2(0.0, NERVE_AT.y * 0.5), 0.014))
			var zone := BoxMesh.new()
			zone.size = Vector3(SNIP_ZONE * 2.0, 0.002, 0.03)
			_zone = _mesh(zone, _mat_next, plane_to_local(NERVE_AT, 0.013))
			var mk := BoxMesh.new()
			mk.size = Vector3(0.003, 0.003, 0.04)
			_marker = _mesh(mk, _mat_idle, plane_to_local(NERVE_AT, 0.02))
	var tool := BoxMesh.new()
	tool.size = Vector3(0.004, 0.004, 0.03)
	_tool = _mesh(tool, _mat_idle, plane_to_local(cursor, 0.02))
	_set_layers(self)


func _set_layers(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as VisualInstance3D).layers = OWN_LAYER
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_layers(c)


func _update_visuals() -> void:
	if not _built:
		return
	if _tool != null:
		_tool.position = plane_to_local(cursor, 0.02)
		_tool.material_override = _mat_bad if _flash > 0.0 or _cd > 0.55 else _mat_idle
	match variant:
		"cut":
			for i in _dots.size():
				_dots[i].material_override = _mat_done if i < idx else (_mat_next if i == idx else _mat_idle)
		"scoop":
			if _eye_copy != null:
				_eye_copy.position = plane_to_local(Vector2.ZERO, 0.012 + lift * 0.03)
		"snip":
			if _marker != null:
				_marker.position = plane_to_local(Vector2(_marker_x(), NERVE_AT.y), 0.02)
				_marker.material_override = _mat_next if absf(_marker_x()) <= SNIP_ZONE else _mat_idle
