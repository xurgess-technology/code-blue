extends Node3D
## The Sonographer's ultrasound cart, and the cable that plugs it into the back of its neck.
##
## Chunky: a castored base, a boxy body with a probe holster, a monitor whose screen is simply on
## (a dim grey glow, nothing on it) and a handle it pushes. One castor squeaks: `squeak_wheel` is the
## node that wheel is on and `rolled` counts the metres it has travelled, so the sound can ride it
## (sono-brain does the sound).
##
## Top-level, like the Discharged's IV pole: it rolls on the floor and lags behind its Sonographer,
## in front of it while it walks and dragged behind while it rushes. It never blocks anything: it has
## no collider, it slides wherever it has to.
##
## The cable runs from the plug on the cart up to Site_cable at the back of the neck, sagging. Its
## glow is the same shader as the throat (shaders/sono_glow.gdshader): a steady level, plus a band
## that travels down it from the neck while an echo charges. Unplug it (`plugged = false`, what the
## model does when it is sedated or killed) and the cable drops off the neck onto the cart.
##
## What drives it: `follow(model, delta)` every frame from MonsterModel, and `set_look()` from
## MonsterModel.set_sono_look. Freeing this node (or hiding it and playing smoke over it) is all
## chunk B needs to do to make the cart go away.

const Shapes := preload("res://scripts/monsters/shapes.gd")
const GLOW_SHADER := "res://shaders/sono_glow.gdshader"

const HEIGHT := 1.18          ## the top of the monitor
const HANDLE_Y := 0.98        ## the bar it pushes
const PUSH := 0.66            ## metres in front of it while it walks
const DRAG := -0.80           ## and behind it while it rushes
const CABLE_SEGS := 12
const GLOW := Color(0.30, 0.78, 1.0)

## Where the cart wants to be, relative to the Sonographer: +forward while pushing, -back while
## dragging. sono-brain moves this between PUSH and DRAG; the cart eases to it.
var offset := PUSH
var rolled := 0.0             ## metres the castors have travelled
var squeak_wheel: Node3D = null
var plugged := true

var _cart: Node3D
var _wheels: Array = []
var _screen: StandardMaterial3D
var _plug: Node3D
var _cable: Array = []        ## [MeshInstance3D], each with its own slice of the cable's 0..1
var _cable_mats: Array = []
var _pos := Vector3.ZERO
var _yaw := 0.0
var _placed := false
var _level := 0.0
var _pulse := -1.0
var _screen_t := 0.0


func _init() -> void:
	name = "SonoCart"
	top_level = true
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color("8f9296")
	steel.metallic = 0.7
	steel.roughness = 0.45
	var shell := Shapes.mat(Color("c9c6b8"), {
		"mottle": 0.1, "stain_col": Color("7c7458"), "stain_amt": 0.28, "stain_low": 1.1,
		"stain_scale": 7.0, "edge_dark": 0.35, "rough": 0.55, "seed": 9.0,
	})
	var rubber := Shapes.flat(Color("15161a"), 0.85)
	var dark := Shapes.flat(Color("0e1013"), 0.7)

	_cart = Node3D.new()
	_cart.name = "Cart"
	add_child(_cart)

	# ---- base: a chunky slab on four castors, one of them the squeaky one
	_cart.add_child(Shapes.box(Vector3(0.50, 0.075, 0.42), shell, Vector3(0, 0.115, 0)))
	_cart.add_child(Shapes.box(Vector3(0.44, 0.03, 0.36), steel, Vector3(0, 0.165, 0)))
	var i := 0
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var fork := Node3D.new()
			fork.position = Vector3(sx * 0.19, 0.075, sz * 0.155)
			_cart.add_child(fork)
			fork.add_child(Shapes.box(Vector3(0.035, 0.07, 0.05), steel, Vector3(0, 0.035, 0)))
			var wheel := Shapes.cylinder(0.044, 0.028, rubber, Vector3.ZERO, -1.0, 12)
			wheel.rotation.z = PI * 0.5
			var spin := Node3D.new()
			spin.name = "Wheel%d" % i
			spin.add_child(wheel)
			fork.add_child(spin)
			_wheels.append(spin)
			if i == 2:
				# the one that squeaks: a bent fork, so it also sits a little crooked
				fork.rotation.y = 0.22
				squeak_wheel = spin
			i += 1

	# ---- body: a boxy column of drawers with a probe holster hung off its side
	_cart.add_child(Shapes.box(Vector3(0.42, 0.44, 0.34), shell, Vector3(0, 0.40, 0)))
	for d in 3:
		_cart.add_child(Shapes.box(Vector3(0.36, 0.012, 0.012), steel, Vector3(0, 0.27 + d * 0.13, -0.175)))
	var holster := Node3D.new()
	holster.position = Vector3(0.235, 0.52, 0.02)
	_cart.add_child(holster)
	holster.add_child(Shapes.mesh_node(Shapes.lathe([
		[0.0, 0.035, 0.030], [0.10, 0.038, 0.032], [0.14, 0.040, 0.034],
	], 10, 0.9, 0.0, 0.0, 3), dark))
	# the probe sitting in it, and its lead looped back to the body
	holster.add_child(Shapes.cylinder(0.019, 0.17, Shapes.flat(Color("d8d4c6"), 0.4), Vector3(0, 0.15, 0), 0.026, 10))
	holster.add_child(Shapes.ellipsoid(Vector3(0.022, 0.012, 0.028), dark, Vector3(0, 0.235, 0), 8))

	# ---- the post, the monitor and the handle
	_cart.add_child(Shapes.cylinder(0.026, 0.30, steel, Vector3(0, 0.76, -0.02), -1.0, 8))
	var mon := Node3D.new()
	mon.position = Vector3(0, 1.00, -0.02)
	mon.rotation.x = 0.22
	_cart.add_child(mon)
	mon.add_child(Shapes.box(Vector3(0.40, 0.30, 0.07), Shapes.flat(Color("2a2c30"), 0.55)))
	_screen = StandardMaterial3D.new()
	_screen.albedo_color = Color("20272b")
	_screen.emission_enabled = true
	_screen.emission = Color("7f8f96")
	_screen.emission_energy_multiplier = 0.55
	_screen.roughness = 0.25
	mon.add_child(Shapes.box(Vector3(0.345, 0.245, 0.006), _screen, Vector3(0, 0.005, 0.039)))
	# a row of dead buttons under the screen
	for b in 5:
		mon.add_child(Shapes.box(Vector3(0.022, 0.012, 0.008), steel, Vector3(-0.09 + b * 0.045, -0.135, 0.038)))
	var bar := Shapes.cylinder(0.018, 0.40, steel, Vector3(0, HANDLE_Y, 0.20), -1.0, 8)
	bar.rotation.z = PI * 0.5
	_cart.add_child(bar)
	for sx in [-1.0, 1.0]:
		_cart.add_child(Shapes.cylinder(0.016, 0.16, steel, Vector3(sx * 0.20, HANDLE_Y - 0.08, 0.11), -1.0, 6))

	# ---- the socket the cable comes out of
	_plug = Node3D.new()
	_plug.position = Vector3(0, 0.62, 0.17)
	_cart.add_child(_plug)
	_plug.add_child(Shapes.cylinder(0.026, 0.05, dark, Vector3(0, 0, 0.02), -1.0, 8))
	# not baked: the castors turn, the screen's material breathes and the plug is a live point.

	# ---- the cable: a chain of segments, each holding its own slice of the run
	var shader := load(GLOW_SHADER) as Shader
	for seg in CABLE_SEGS:
		var m := ShaderMaterial.new()
		m.shader = shader
		m.set_shader_parameter("use_tex", false)
		m.set_shader_parameter("base_color", Color("3b4046"))
		m.set_shader_parameter("glow", GLOW)
		m.set_shader_parameter("idle_energy", 0.10)
		m.set_shader_parameter("full_energy", 5.0)
		m.set_shader_parameter("roughness_v", 0.5)
		# t runs 0 at the neck to 1 at the cart, continuously across the segments
		m.set_shader_parameter("t_scale", 1.0 / float(CABLE_SEGS))
		m.set_shader_parameter("t_offset", (float(seg) + 0.5) / float(CABLE_SEGS))
		var c := Shapes.cylinder(0.013, 1.0, m, Vector3.ZERO, -1.0, 6)
		add_child(c)
		_cable.append(c)
		_cable_mats.append(m)


## The look interface, forwarded by MonsterModel.set_sono_look. `charge` lights the cable and sends
## a band of light travelling down it; `plug` false drops the cable off the neck.
func set_look(suspicion: float, charge: float, _mode: String, plug: bool) -> void:
	plugged = plug
	_level = clampf(maxf(charge, suspicion * 0.35), 0.0, 1.0)
	for m in _cable_mats:
		(m as ShaderMaterial).set_shader_parameter("level", _level if plug else 0.0)
		(m as ShaderMaterial).set_shader_parameter("pulse_at", _pulse if plug else -1.0)


## Called by MonsterModel every frame.
func follow(model: Node3D, delta: float) -> void:
	var body: Node3D = model.get_parent() as Node3D
	if body == null:
		return
	var fwd: Vector3 = -body.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var floor_y := body.global_position.y
	var target := body.global_position + fwd * offset
	target.y = floor_y
	if not _placed or _pos.distance_to(target) > 4.0:
		_pos = target
		_yaw = body.rotation.y
		_placed = true
	var before := _pos
	_pos = _pos.lerp(target, clampf(delta * 4.5, 0.0, 1.0))
	_pos.y = floor_y
	var moved := Vector2(_pos.x - before.x, _pos.z - before.z).length()
	rolled += moved
	# it swings round to point the way it is going, which is what makes it clatter on corners
	# the handle, the screen and the cable's socket are all on the cart's +Z face, and that face has to
	# look at the Sonographer: from in front of it while it pushes, from behind while it drags
	var want := atan2(fwd.x, fwd.z) + (PI if offset >= 0.0 else 0.0)
	_yaw = _yaw + wrapf(want - _yaw, -PI, PI) * clampf(delta * 3.0, 0.0, 1.0)
	global_transform = Transform3D.IDENTITY
	_cart.global_transform = Transform3D(Basis(Vector3.UP, _yaw), _pos)
	for w in _wheels:
		(w as Node3D).rotation.x -= moved / 0.044
	# the screen is just on: a dim panel with a slow crawl in it, never anything to read
	_screen_t += delta
	_screen.emission_energy_multiplier = 0.50 + 0.08 * sin(_screen_t * 1.7) + 0.03 * sin(_screen_t * 11.0)

	# the charge travels down the cable, from the neck to the cart, then goes out
	if _level > 0.02 and plugged:
		_pulse = fposmod(_pulse + delta * (0.9 + 2.4 * _level), 1.35) if _pulse >= 0.0 else 0.0
		if _pulse > 1.0:
			_pulse = -1.0
	else:
		_pulse = -1.0
	for m in _cable_mats:
		(m as ShaderMaterial).set_shader_parameter("pulse_at", _pulse if plugged else -1.0)
		(m as ShaderMaterial).set_shader_parameter("level", _level if plugged else 0.0)
	_draw_cable(model)


## From the socket at the back of its neck, out over its left shoulder and down to the cart's plug.
## It has to go round the body, not through it, so the middle of the run is pushed out to the side.
## Unplugged, the top end lets go and lies over the cart.
func _draw_cable(model: Node3D) -> void:
	var p3: Vector3 = _plug.global_position
	var p0 := p3 + Vector3(0.0, 0.22, 0.0)
	var left := Vector3.RIGHT
	if plugged and model.has_method("cable_point"):
		p0 = model.cable_point()
		var body: Node3D = model.get_parent() as Node3D
		if body != null:
			left = body.global_transform.basis.x.normalized()
	# out over the shoulder, then down and round to the cart
	var p1 := p0 + left * 0.26 + Vector3.DOWN * 0.06
	var p2 := p3.lerp(p0, 0.35) + left * 0.32 + Vector3.UP * 0.10
	for i in CABLE_SEGS:
		Shapes.stretch_between(_cable[i], _bezier(p0, p1, p2, p3, float(i) / CABLE_SEGS),
			_bezier(p0, p1, p2, p3, float(i + 1) / CABLE_SEGS))


func _bezier(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * (u * u * u) + b * (3.0 * u * u * t) + c * (3.0 * u * t * t) + d * (t * t * t)
