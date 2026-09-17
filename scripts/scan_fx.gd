extends Node
## SWEEP 4A HOOK (scanner): what scanning looks like, on the scanning player's own machine only.
## While R is held on a monster (Player.scan_progress / scan_target_id) the monster wears a cyan
## hologram overlay (scanlines, a rim, and a bright band sweeping up and down it, faster as the
## scan builds) and a thin beam runs from the player's hand to it. When the scan completes: the
## overlay flashes, a ring rolls out across the floor from its feet, a chime, and the HUD's
## "SCAN COMPLETE" banner (hud.gd show_scan_banner). Terminal redesign: holding R is a laser
## pointer, always: a beam from the hand and a dot where it lands. On the break room's wall screen
## (wall_terminal.gd) the dot is a mouse cursor and a left click (Player.laser_clicks) clicks under
## it; anywhere else a left click fires a surge down the beam. The host's _tick_scan still decides
## what the database records. Chunks 3 and 4: clicks go through game.wall (wall_session.gd, the host
## presses them); holding left click on HOLD TO SIGN IN for HOLD_SECONDS signs in; everyone else's
## laser shows too (from their flashlight, along their view), with its dot on the screen.

const MonsterPages := preload("res://scripts/database/monster_pages.gd")

const COLOR := Color(0.36, 0.88, 0.82)
const FLASH_SECONDS := 0.6
const RING_SECONDS := 0.9
const RING_RADIUS := 3.2
## The laser: how far it reaches, and a click's surge down the beam.
const LASER_RANGE := 14.0
const SURGE_SECONDS := 0.35

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.36, 0.88, 0.82);
uniform float band_y = 0.0;
uniform float strength = 1.0;
uniform float flash = 0.0;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float lines = smoothstep(0.55, 1.0, 0.5 + 0.5 * sin(wpos.y * 80.0 - TIME * 7.0));
	float band = 1.0 - smoothstep(0.0, 0.09, abs(wpos.y - band_y));
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	float a = strength * (0.12 * lines + 0.45 * rim + 1.1 * band) + flash;
	ALBEDO = tint * a;
}
"""

var game: Node = null
var _mat: ShaderMaterial
var _beam: MeshInstance3D
var _target: Node3D = null          # the monster wearing the overlay
var _saved := {}                    # GeometryInstance3D -> its own material_overlay
var _last_progress := 0.0
var _last_target := -1
var _flash := 0.0
var _flash_target: Node3D = null
var _rings: Array = []              # [{node, t}]
var _t := 0.0
var _dot: MeshInstance3D
var _dot_light: OmniLight3D
var _beam_mat: StandardMaterial3D
var _surge := 0.0
var _clicks_seen := -1
var _hold := 0.0                     # left click held on HOLD TO SIGN IN, seconds
var _hold_done := false              # signed in on this hold: let go before another
var _others := {}                    # peer id -> {beam, mat, dot}: other players' lasers
var _pointed: Node = null           # the wall terminal the laser is on, if any
var _lens: MeshInstance3D = null     # the local torch's lens while it is scanner-blue
var _lens_saved: Material = null
var _lens_mat: StandardMaterial3D
var _dimmed: Object = null           # the flashlight put out while the laser is on


func setup(g: Node) -> void:
	game = g
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005
	cyl.bottom_radius = 0.007
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 1
	_beam.mesh = cyl
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.albedo_color = Color(COLOR, 0.55)
	_beam.material_override = bm
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	_beam.top_level = true
	add_child(_beam)
	_beam_mat = bm
	# Where the laser lands: a bright dot and a little light of its own.
	_dot = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.018
	sph.height = 0.036
	sph.radial_segments = 10
	sph.rings = 5
	_dot.mesh = sph
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.albedo_color = Color(0.75, 1.0, 0.97)
	_dot.material_override = dm
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dot.top_level = true
	_dot.visible = false
	add_child(_dot)
	_dot_light = OmniLight3D.new()
	_dot_light.light_color = COLOR
	_dot_light.light_energy = 0.8
	_dot_light.omni_range = 0.7
	_dot_light.top_level = true
	_dot_light.visible = false
	add_child(_dot_light)


func _process(delta: float) -> void:
	if game == null:
		return
	_t += delta
	var me = game.local_player()
	var mid := -1
	var progress := 0.0
	if me != null and me.alive and bool(me.scan_holding):
		mid = int(me.scan_target_id)
		progress = float(me.scan_progress)
	var monster: Node3D = game.scan_target_node(mid) if mid != -1 else null
	if _flash_target != null and not is_instance_valid(_flash_target):
		_flash_target = null
		_flash = 0.0
	# A scan that just wrapped from nearly done back to the start completed.
	if monster != null and mid == _last_target and _last_progress > 0.8 and progress < 0.2:
		_complete(monster)
	_last_target = mid
	_last_progress = progress

	_set_target(monster if monster != null else (_flash_target if _flash > 0.0 else null))
	if _target != null:
		var h := _height_of(_target)
		var speed := lerpf(1.2, 3.5, progress)
		var base := _target.global_position.y
		_mat.set_shader_parameter("band_y", base + h * (0.5 - 0.5 * cos(_t * speed * PI)))
		_mat.set_shader_parameter("strength", 1.0 if monster != null else 0.0)
		_mat.set_shader_parameter("flash", _flash * 1.4)
	_flash = maxf(0.0, _flash - delta / FLASH_SECONDS)
	if _flash <= 0.0:
		_flash_target = null
	_update_laser(me, monster, delta)
	_update_others(me)
	_tick_rings(delta)


func _complete(monster: Node3D) -> void:
	_flash = 1.0
	_flash_target = monster
	_spawn_ring(monster.global_position)
	if DisplayServer.get_name() != "headless":
		Audio.play("beep", null, -2.0)
		Audio.play("deliver", null, -6.0)
	var name := String(MonsterPages.entry(String(monster.get("kind"))).get("name", "Unknown specimen"))
	var hud: Node = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("show_scan_banner"):
		hud.show_scan_banner(name)


# ---- the overlay ----

func _set_target(m) -> void:
	if _target != null and not is_instance_valid(_target):
		_saved.clear()
		_target = null
	if m == _target:
		return
	_restore()
	_target = m
	if m == null:
		return
	var model: Node = m.get("model")
	for gi in (model if model != null else m).find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		_saved[g] = g.material_overlay
		g.material_overlay = _mat


func _restore() -> void:
	for g in _saved.keys():
		if is_instance_valid(g):
			(g as GeometryInstance3D).material_overlay = _saved[g]
	_saved.clear()
	_target = null


func _height_of(m: Node3D) -> float:
	var h = m.get("height")
	return float(h) if h != null else 1.9


# ---- the laser ----

## Holding R: the beam from the hand to wherever it lands (a monster being scanned: its middle), the
## dot there, the wall screen's cursor, and clicks.
func _update_laser(me, monster: Node3D, delta: float) -> void:
	_surge = maxf(0.0, _surge - delta / SURGE_SECONDS)
	var holding: bool = me != null and me.alive and bool(me.scan_holding) and me.camera != null
	# One beam at a time: the torch's light goes out while it is a laser, back on (if it was) after.
	_dim_flashlight(me if holding else null)
	if not holding:
		_tint_lens(null)
		_beam.visible = false
		_dot.visible = false
		_dot_light.visible = false
		_point_at(null, Vector2(-1, -1))
		_clicks_seen = int(me.laser_clicks) if me != null else -1
		_set_hold(null, 0.0)
		return
	var cam: Camera3D = me.camera
	# Out of the torch's lens when the first-person torch is showing, else from about where it would be.
	var lens := _torch_lens(me)
	_tint_lens(lens)
	var from: Vector3 = lens.global_position if lens != null and lens.is_visible_in_tree() else cam.global_transform * Vector3(0.22, -0.24, -0.45)
	var aim_dir := -cam.global_transform.basis.z
	from += aim_dir * 0.03   # just past the lens, so the beam's end never hides the blue tip
	var to: Vector3
	var landed := false
	var terminal: Node = null
	var px := Vector2(-1, -1)
	if monster != null:
		to = monster.global_position + Vector3.UP * _height_of(monster) * 0.6
		landed = true
	else:
		var l: Dictionary = game.wall.laser_of(me)
		to = l.to
		landed = l.landed
		terminal = l.terminal
		px = l.px
	_point_at(terminal, px)
	# Held on HOLD TO SIGN IN: fills, then signs this player in.
	var on_sign: bool = terminal != null and bool(me.laser_held) and terminal.ui.sign_rect().has_point(px)
	if not bool(me.laser_held):
		_hold_done = false
	_set_hold(terminal, _hold + delta if on_sign and not _hold_done else 0.0)
	if _hold >= game.wall.HOLD_SECONDS:
		_hold_done = true
		_set_hold(terminal, 0.0)
		game.wall.sign_in()
		_sfx("click", -2.0)
	# A click: on the screen it presses what is under the dot; anywhere else, a surge down the beam.
	var clicks := int(me.laser_clicks)
	if _clicks_seen < 0:
		_clicks_seen = clicks
	if clicks != _clicks_seen:
		_clicks_seen = clicks
		if terminal != null:
			game.wall.click(px)
			_sfx("click", -4.0)
		else:
			_surge = 1.0
			_sfx("dev_zap_01", -10.0)
	_draw_beam(from, to, landed)


func _draw_beam(from: Vector3, to: Vector3, landed: bool) -> void:
	var d := to - from
	var len := d.length()
	if len < 0.05:
		_beam.visible = false
		return
	_beam.visible = true
	var y := d / len
	var x := y.cross(Vector3.UP)
	if x.length() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y)
	var thick := (1.0 + 0.25 * sin(_t * 40.0)) * (1.0 + 1.6 * _surge)
	_beam.global_transform = Transform3D(Basis(x * thick, y * len, z * thick), from + d * 0.5)
	_beam_mat.albedo_color = Color(COLOR.lerp(Color.WHITE, 0.6 * _surge), 0.55 + 0.45 * _surge)
	_dot.visible = landed
	_dot_light.visible = landed
	if landed:
		# Just off the surface toward the hand, so it never sinks into what it lights.
		var at := to - y * 0.01
		_dot.global_position = at
		_dot.scale = Vector3.ONE * (1.0 + 2.5 * _surge)
		_dot_light.global_position = at - y * 0.08
		_dot_light.light_energy = 0.8 + 2.5 * _surge


func _set_hold(terminal: Node, t: float) -> void:
	_hold = t
	var wt: Node = terminal if terminal != null else game.wall_terminal()
	if wt != null and is_instance_valid(wt):
		wt.ui.set_hold(t / game.wall.HOLD_SECONDS)


## Everyone else's laser: a beam from their flashlight to where their view lands, and their dot on the
## screen. Nothing on the wire: their aim and scan_holding already are.
func _update_others(me) -> void:
	var cursors: Array = []
	var seen := {}
	for p in game.players.values():
		if p == me or not is_instance_valid(p) or not p.alive or not bool(p.scan_holding) or p.flashlight == null:
			continue
		var id := int(p.peer_id)
		seen[id] = true
		if not _others.has(id):
			_others[id] = _new_other()
		var o: Dictionary = _others[id]
		var l: Dictionary = game.wall.laser_of(p)
		var from: Vector3 = (p.flashlight as Node3D).global_position
		var d: Vector3 = l.to - from
		var len := d.length()
		o.beam.visible = len > 0.05
		if len > 0.05:
			var y := d / len
			var x := y.cross(Vector3.UP)
			if x.length() < 0.01:
				x = y.cross(Vector3.RIGHT)
			x = x.normalized()
			o.beam.global_transform = Transform3D(Basis(x, y * len, x.cross(y)), from + d * 0.5)
		o.dot.visible = bool(l.landed)
		if l.landed:
			o.dot.global_position = l.to - d.normalized() * 0.01
		if l.terminal != null:
			cursors.append(l.px)
	for id in _others.keys():
		if not seen.has(id):
			_others[id].beam.queue_free()
			_others[id].dot.queue_free()
			_others.erase(id)
	var wt: Node = game.wall_terminal()
	if wt != null and is_instance_valid(wt):
		wt.ui.set_remote_cursors(cursors)


func _new_other() -> Dictionary:
	var beam := MeshInstance3D.new()
	beam.mesh = _beam.mesh
	beam.material_override = _beam_mat
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.top_level = true
	add_child(beam)
	var dot := MeshInstance3D.new()
	dot.mesh = _dot.mesh
	dot.material_override = _dot.material_override
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dot.top_level = true
	add_child(dot)
	return {"beam": beam, "dot": dot}


func _dim_flashlight(me) -> void:
	var flash: SpotLight3D = me.flashlight if me != null else null
	if flash == _dimmed:
		if flash != null and flash.visible:
			flash.visible = false   # toggled back on mid-scan: stays out until R is let go
		return
	if _dimmed != null and is_instance_valid(_dimmed):
		var owner = (_dimmed as Node).get_parent()
		while owner != null and not ("flashlight_on" in owner):
			owner = owner.get_parent()
		(_dimmed as SpotLight3D).visible = bool(owner.flashlight_on) if owner != null else true
	_dimmed = flash
	if flash != null:
		flash.visible = false


func _torch_lens(me) -> MeshInstance3D:
	var hands = me.get("hands")
	if hands == null or not is_instance_valid(hands) or hands.get("torch") == null:
		return null
	return hands.torch.get_node_or_null("Lens") as MeshInstance3D


## The lens glows the laser's blue while scanning; `lens` null puts the last one back.
func _tint_lens(lens: MeshInstance3D) -> void:
	if lens == _lens:
		return
	if _lens != null and is_instance_valid(_lens):
		_lens.material_override = _lens_saved
	_lens = lens
	_lens_saved = null
	if lens == null:
		return
	if _lens_mat == null:
		_lens_mat = StandardMaterial3D.new()
		_lens_mat.albedo_color = Color(0.1, 0.55, 0.62)
		_lens_mat.emission_enabled = true
		_lens_mat.emission = Color(0.05, 0.6, 0.85)
		_lens_mat.emission_energy_multiplier = 0.9
	_lens_saved = lens.material_override
	lens.material_override = _lens_mat


func _point_at(terminal: Node, px: Vector2) -> void:
	if _pointed != null and is_instance_valid(_pointed) and _pointed != terminal:
		_pointed.clear_pointer()
	_pointed = terminal
	if terminal != null:
		terminal.point(px)


func _sfx(cue: String, db: float) -> void:
	if DisplayServer.get_name() != "headless":
		Audio.play(cue, null, db, 0.05, Audio.BUS_UI)


# ---- the ring ----

func _spawn_ring(at: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.94
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 4
	mi.mesh = torus
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(COLOR, 0.9)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	add_child(mi)
	mi.global_position = at + Vector3.UP * 0.04
	_rings.append({"node": mi, "t": 0.0, "mat": m})


func _tick_rings(delta: float) -> void:
	for r in _rings.duplicate():
		r.t += delta
		var k := clampf(float(r.t) / RING_SECONDS, 0.0, 1.0)
		var node: MeshInstance3D = r.node
		var s := lerpf(0.2, RING_RADIUS, 1.0 - pow(1.0 - k, 3.0))
		node.scale = Vector3(s, 1.0, s)
		(r.mat as StandardMaterial3D).albedo_color = Color(COLOR, 0.9 * (1.0 - k))
		if k >= 1.0:
			node.queue_free()
			_rings.erase(r)


func _exit_tree() -> void:
	_restore()
