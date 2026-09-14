extends Node
## Echo, on the shrieking player's machine only (brains, sweep 3). For a few seconds the view goes
## dark and everything that matters within the radius shows as a glowing outline through walls:
## monsters red, players white, surgical supplies teal, loot gold, containers dim.
##
## How it stays cheap: nothing exists until Echo starts. On start it picks at most MAX_TARGETS
## things (nearest first, by kind priority) and at most MAX_GHOSTS mesh copies in total (each
## target's biggest meshes), which share the source meshes and one of five materials. The dark
## veil is one quad in front of the camera. Ghosts drawn with depth test off after the veil, so
## walls do not hide them. Skinned meshes (surgeons) follow their own skeleton. Everything is freed
## when Echo ends.

const MAX_TARGETS := 40
const MAX_GHOSTS := 150
const MESHES_PER := {"monster": 8, "player": 6, "surgical": 2, "loot": 2, "container": 3}
const PRIORITY := ["monster", "player", "surgical", "loot", "container"]
const COLOURS := {
	"monster": Color(1.0, 0.16, 0.1),
	"player": Color(0.9, 0.95, 1.0),
	"surgical": Color(0.25, 0.95, 0.85),
	"loot": Color(1.0, 0.72, 0.22),
	"container": Color(0.16, 0.24, 0.28),
}
## Metres per second the echo's wave front travels: things light up as it passes them.
const WAVE_SPEED := 26.0
const FADE_OUT := 0.6

const GHOST_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform vec3 col : source_color = vec3(1.0);
uniform float fill = 0.06;
instance uniform float fade = 0.0;
void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = pow(1.0 - facing, 2.0);
	ALBEDO = col * (edge * 2.2 + fill) * fade;
}
"""

const VEIL_SHADER := """
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform float amount = 0.0;
uniform float ring = 0.0;
void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d * vec2(1.6, 1.0));
	// Dark, bluish at the edges, with a faint ring rushing outward as the shriek goes out.
	float band = smoothstep(0.05, 0.0, abs(r - ring)) * (1.0 - ring) * 0.35;
	ALBEDO = vec3(0.004, 0.008, 0.016) + vec3(0.05, 0.12, 0.16) * band;
	ALPHA = clamp(amount * (0.9 + r * 0.1), 0.0, 0.97);
}
"""

static var _ghost_shader: Shader = null
static var _veil_shader: Shader = null
static var _mats := {}
static var _veil_mat: ShaderMaterial = null

var game: Node = null
var active := false
var origin := Vector3.ZERO
var radius := 12.0
var seconds := 2.5
var t := 0.0
## [{src: MeshInstance3D, ghost: MeshInstance3D, dist: float}]
var ghosts: Array = []
var target_count := 0
var _root: Node3D = null
var _veil: MeshInstance3D = null


static func ghost_material(kind: String) -> ShaderMaterial:
	if _mats.has(kind):
		return _mats[kind]
	if _ghost_shader == null:
		_ghost_shader = Shader.new()
		_ghost_shader.code = GHOST_SHADER
	var m := ShaderMaterial.new()
	m.shader = _ghost_shader
	var c: Color = COLOURS.get(kind, Color.WHITE)
	m.set_shader_parameter("col", Vector3(c.r, c.g, c.b))
	m.set_shader_parameter("fill", 0.03 if kind == "container" else 0.07)
	# Later in the transparent pass than the veil (and than everything else).
	m.render_priority = 100
	_mats[kind] = m
	return m


static func veil_material() -> ShaderMaterial:
	if _veil_mat != null:
		return _veil_mat
	_veil_shader = Shader.new()
	_veil_shader.code = VEIL_SHADER
	_veil_mat = ShaderMaterial.new()
	_veil_mat.shader = _veil_shader
	_veil_mat.render_priority = 90
	return _veil_mat


func setup(g: Node) -> void:
	game = g


## Start (or restart) Echo around `me`.
func start(me: Node, at: Vector3, r: float, secs: float) -> void:
	stop()
	if me == null or not is_instance_valid(me) or me.camera == null:
		return
	active = true
	origin = at
	radius = r
	seconds = secs
	t = 0.0
	_root = Node3D.new()
	_root.name = "EchoGhosts"
	add_child(_root)
	_veil = MeshInstance3D.new()
	_veil.name = "EchoVeil"
	var q := QuadMesh.new()
	q.size = Vector2(3.2, 2.0)
	_veil.mesh = q
	_veil.material_override = veil_material()
	_veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_veil.position = Vector3(0, 0, -0.12)
	_veil.extra_cull_margin = 16.0
	me.camera.add_child(_veil)
	_collect(me)


func stop() -> void:
	active = false
	ghosts.clear()
	target_count = 0
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	if _veil != null and is_instance_valid(_veil):
		_veil.queue_free()
	_veil = null


func _collect(me: Node) -> void:
	var found: Array = []   # [priority, dist, category, node]
	var r2 := radius * radius
	var add := func(n: Node, cat: String) -> void:
		if n == null or not is_instance_valid(n) or not (n is Node3D) or not (n as Node3D).is_visible_in_tree():
			return
		var d2 := ((n as Node3D).global_position - origin).length_squared()
		if d2 <= r2:
			found.append([PRIORITY.find(cat), sqrt(d2), cat, n])
	for m in game.monsters.values():
		add.call(m, "monster")
	for p in game.players.values():
		if p != me and p.alive:
			add.call(p, "player")
	for it in game.world_items.values():
		var k := String(it.kind)
		if Items.is_surgical(k):
			add.call(it, "surgical")
		elif Items.is_loot(k):
			add.call(it, "loot")
	for ct in game.get_tree().get_nodes_in_group("container"):
		add.call(ct, "container")
	found.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for e in found:
		if target_count >= MAX_TARGETS or ghosts.size() >= MAX_GHOSTS:
			break
		var n: Node3D = e[3]
		var cat: String = e[2]
		var root: Node = n
		if cat == "player" and n.get("body_visual") != null:
			root = n.body_visual
		elif cat == "monster" and n.get("model") != null:
			root = n.model
		var meshes := _biggest_meshes(root, int(MESHES_PER[cat]))
		if meshes.is_empty():
			continue
		target_count += 1
		for mi in meshes:
			if ghosts.size() >= MAX_GHOSTS:
				break
			_ghost(mi, cat, float(e[1]))


func _biggest_meshes(root: Node, n: int) -> Array:
	var list: Array = []
	var all: Array = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		all.append(root)
	for mi in all:
		var m := mi as MeshInstance3D
		if m.mesh == null or not m.is_visible_in_tree():
			continue
		var s := m.mesh.get_aabb().size * m.global_basis.get_scale()
		list.append([s.x * s.y + s.y * s.z + s.x * s.z, m])
	list.sort_custom(func(a, b): return a[0] > b[0])
	var out: Array = []
	for i in mini(n, list.size()):
		out.append(list[i][1])
	return out


func _ghost(src: MeshInstance3D, cat: String, dist: float) -> void:
	var g := MeshInstance3D.new()
	g.mesh = src.mesh
	g.material_override = ghost_material(cat)
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	g.ignore_occlusion_culling = true   # the level's occluders would hide exactly what Echo is for
	g.extra_cull_margin = 0.5
	_root.add_child(g)
	g.global_transform = src.global_transform
	if src.skin != null and not src.skeleton.is_empty():
		var skel := src.get_node_or_null(src.skeleton)
		if skel != null:
			g.skin = src.skin
			g.skeleton = g.get_path_to(skel)
	g.set_instance_shader_parameter("fade", 0.0)
	ghosts.append({"src": src, "ghost": g, "dist": dist})


func _process(delta: float) -> void:
	if not active:
		return
	t += delta
	if t >= seconds or game == null or game.phase == game.Phase.MENU or _veil == null or not is_instance_valid(_veil):
		stop()
		return
	var out := clampf((seconds - t) / FADE_OUT, 0.0, 1.0)
	var fade_in := clampf(t / 0.12, 0.0, 1.0)
	var veil: ShaderMaterial = veil_material()
	veil.set_shader_parameter("amount", fade_in * out)
	veil.set_shader_parameter("ring", clampf(t / 0.9, 0.0, 1.0))
	var front := t * WAVE_SPEED
	for e in ghosts:
		var g: MeshInstance3D = e.ghost
		var src = e.src
		if src != null and is_instance_valid(src) and src.is_inside_tree():
			g.global_transform = (src as MeshInstance3D).global_transform
		# Lit as the wave front passes, a bright flash, then a steady glow that fades out at the end.
		var since := (front - float(e.dist)) / WAVE_SPEED
		var f := 0.0
		if since > 0.0:
			f = 0.75 + 0.6 * exp(-since * 5.0)
		g.set_instance_shader_parameter("fade", f * out)


## Warmup hook: compile the ghost and veil shaders once.
static func warm(parent: Node3D) -> void:
	for kind in COLOURS.keys():
		var mi := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.1
		s.height = 0.2
		mi.mesh = s
		mi.material_override = ghost_material(kind)
		mi.position = Vector3(-0.6 + PRIORITY.find(kind) * 0.25, 0.9, -1.0)
		parent.add_child(mi)
		mi.set_instance_shader_parameter("fade", 1.0)
	var v := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.3, 0.2)
	v.mesh = q
	v.material_override = veil_material()
	v.position = Vector3(0.9, 0.9, -1.0)
	parent.add_child(v)
