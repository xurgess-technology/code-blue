class_name PatientBody
extends Node3D
## The patient on the operating table (see docs/CONTRACTS.md, "Patient body").
##
## Frame: lying along local X, head toward -X, feet / tail toward +X, on the table top at y = 0,
## centred on the origin. The removable limb (Bob's forearm, the seal's left front flipper) is on
## local +Z. Site transforms are body-local frames returned as global_transform * local:
## +Y out of the skin toward a camera above, X along the limb (distal) for limb / limb_cut,
## X along the body toward the feet / tail for gunshot and along the arm for Bob's injection.
##
## Per-patient geometry lives in scripts/patients/<id>_builder.gd; this file owns the state:
## ailment, vitals (breathing, pallor, twitching), sedation (fidgeting), stirs, bleeding, flags.

const Kit := preload("res://scripts/patients/patient_kit.gd")
const BobBuilder := preload("res://scripts/patients/bob_builder.gd")
const SealBuilder := preload("res://scripts/patients/seal_builder.gd")
const DummyBuilder := preload("res://scripts/patients/dummy_builder.gd")
const MonsterBuilder := preload("res://scripts/dissection/monster_builder.gd")

var patient_id := "bob"
var ailment_id := ""

# Filled by the builder ---------------------------------------------------------
## The moving part of the body. Its transform stays identity; builders animate below it.
var rig: Node3D
## site -> body-local Transform3D (the rest pose; stirs never move these)
var _sites := {}
## site -> Node3D that follows the body part the site is on (overlays hang here)
var anchors := {}
## site -> [start: Vector3, end_on_table: Vector3] body-local drip path
var drips := {}
## Builder-specific nodes: "tourniquet", "stump", "dress_stump", "wound" {root, bullet, emptied}, "dress_wound", ...
## Minigames must not read these; use site_section / infection_start / make_severed_limb.
var parts := {}
## limb site -> {half_up, half_side, axis_depth, shape} (see site_section)
var sections := {}
## limb site -> metres along the site's +X to where the painted infection begins
var infection := {}
## ShaderMaterials with pallor / grey / infect / breath uniforms
var skin_mats: Array[ShaderMaterial] = []
var breath_amp := 0.01
var _builder: GDScript

# State ---------------------------------------------------------------------------
var _vitals := 100.0
var _sedation := 0.0
var _flat := false
var _flags := {}
var _limb_removed := false
var _t := 0.0
var _phase := 0.0
var _pallor := 0.0
var _grey := 0.0
var _infect := 0.0
var _jolt := 0.0
var _jolt_v := 0.0
var _env := 0.0
var _twitch := 0.0
var _fidget := 0.0
var _next_fidget := 2.0
var _next_twitch := 1.0
var _rng := RandomNumberGenerator.new()
var _bleed := {}


static func create(id: String) -> Node3D:
	var b := PatientBody.new()
	b.patient_id = id
	b.name = "Patient_%s" % id
	b.rig = Node3D.new()
	b.rig.name = "Rig"
	b.add_child(b.rig)
	var body_kind := String(Procedures.PATIENTS.get(id, {}).get("body", id))
	var ok := false
	if Procedures.is_monster(id):
		# dissection (sweep 3): a strapped monster; scripts/dissection/monster_builder.gd builds it.
		ok = MonsterBuilder.build(b)
		b._builder = MonsterBuilder
	elif body_kind == "seal":
		ok = SealBuilder.build(b)
		b._builder = SealBuilder
	else:
		if not Procedures.PATIENTS.has(id):
			push_warning("PatientBody: unknown patient '%s', using Bob" % id)
		ok = BobBuilder.build(b)
		b._builder = BobBuilder
	if not ok:
		DummyBuilder.build(b)
		b._builder = DummyBuilder
	b._rng.seed = hash(id)
	b._apply_visuals()
	for s in b.skin_mats:
		s.set_shader_parameter(&"pallor", 0.0)
		s.set_shader_parameter(&"grey", 0.0)
		s.set_shader_parameter(&"infect", 0.0)
	return b


# -- contract API --------------------------------------------------------------------------------

func set_ailment(id: String) -> void:
	ailment_id = id
	_apply_visuals()


func has_site(site: String) -> bool:
	return _sites.has(site)


func site_transform(site: String) -> Transform3D:
	var local: Transform3D = _sites.get(site, Transform3D(Basis(), Vector3(0, 0.3, 0)))
	return (global_transform if is_inside_tree() else transform) * local


## Cross-section of the limb under a limb site (`limb`, `limb_cut`), in metres:
##   half_up: skin at the site down to the limb axis, half_side: half width across the limb (site Z),
##   axis_depth: how far below the site origin the axis runs, shape: superellipse exponent
##   (2 round, 6 boxy). {} when the site is not on a limb.
func site_section(site: String) -> Dictionary:
	return sections.get(site, {})


## Distance along the site's +X (distal) from the site origin to where the body's own infection
## starts. INF when the site has none. Amputation sites put it just past `limb_cut`.
func infection_start(site: String) -> float:
	return float(infection.get(site, INF))


## Adds a static copy of the limb that an amputation removes, looking and posed as it is right now,
## under `parent`, and returns it (null if this body cannot). Works whether or not the flags have
## already removed the limb (a spectator may get the flag before its own saw finishes).
func make_severed_limb(parent: Node) -> Node3D:
	if parent == null:
		return null
	return _builder.make_severed_limb(self, parent)


func set_vitals(v: float) -> void:
	_vitals = clampf(v, 0.0, 100.0)


func set_sedation(s: float) -> void:
	_sedation = clampf(s, 0.0, 1.0)


func stir(strength: float) -> void:
	if _flat:
		return
	strength = clampf(strength, 0.0, 1.5)
	_jolt_v += strength * 7.0 * (1.0 if _rng.randf() < 0.5 else -1.0)
	_env = maxf(_env, strength)


func set_bleeding(site: String, amount: float) -> void:
	if not anchors.has(site):
		return
	amount = clampf(amount, 0.0, 1.0)
	if not _bleed.has(site):
		if amount <= 0.0:
			return
		_bleed[site] = _make_bleed(site)
	_bleed[site]["target"] = amount


## Replaces the whole flag set (it does not merge): always pass every flag the case has.
func apply_flags(flags: Dictionary) -> void:
	_flags = flags.duplicate()
	if flags.has("sedation"):
		set_sedation(float(flags["sedation"]))
	_apply_visuals()


func flatline() -> void:
	_flat = true
	_vitals = 0.0
	_jolt_v = 0.0
	_env = 0.0


# -- visuals from state ----------------------------------------------------------------------------

func _flag(k: String) -> bool:
	var v = _flags.get(k, false)
	if v is bool:
		return v
	if v is float or v is int:
		return float(v) > 0.0
	return v != null


func _apply_visuals() -> void:
	var gunshot := ailment_id == "gunshot"
	var amputation := ailment_id == "amputation"
	var dressed := _flag("dressed")
	var removed := _flag("bullet_removed")
	var tq := float(_flags.get("tourniquet", 0.0)) if not (_flags.get("tourniquet") is bool) else (1.0 if _flags["tourniquet"] else 0.0)
	var amputated := _flag("amputated") or (amputation and dressed)

	var wound: Dictionary = parts.get("wound", {})
	if not wound.is_empty():
		wound.root.visible = gunshot and not dressed
		wound.bullet.visible = not removed
		wound.emptied.visible = removed
	_vis("dress_wound", gunshot and dressed)
	_vis("tourniquet", tq > 0.0)
	var t: Node3D = parts.get("tourniquet")
	if t != null:
		var band := t.get_node_or_null("Band") as Node3D
		if band != null:
			var sq := lerpf(1.06, 0.97, clampf(tq, 0.0, 1.0))
			band.scale = Vector3(1.0, sq, sq)
	_vis("stump", amputated and not dressed)
	_vis("dress_stump", amputated and dressed and amputation)
	if amputated != _limb_removed:
		_limb_removed = amputated
		_builder.set_limb_removed(self, amputated)
	_infect = 1.0 if amputation else 0.0
	for s in skin_mats:
		s.set_shader_parameter(&"infect", _infect)


func _vis(key: String, on: bool) -> void:
	var n: Node3D = parts.get(key)
	if n != null:
		n.visible = on


# -- per frame -------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	delta = minf(delta, 0.1)
	_t += delta
	var v01 := _vitals / 100.0

	# Breathing: slow and deep when healthy, fast and shallow when failing, none when flat.
	var rate := lerpf(0.75, 0.24, v01)
	var depth := 0.0 if _flat else lerpf(0.35, 1.0, v01)
	_phase = fmod(_phase + delta * TAU * rate, TAU)
	var br := 0.5 - 0.5 * cos(_phase)
	br = br * br * (3.0 - 2.0 * br) * depth * breath_amp

	# Pallor under 40, grey when flat.
	var pal_target := 1.0 if _flat else clampf((40.0 - _vitals) / 40.0, 0.0, 1.0)
	_pallor = move_toward(_pallor, pal_target, delta * 0.5)
	_grey = move_toward(_grey, 1.0 if _flat else 0.0, delta * 0.35)
	for s in skin_mats:
		s.set_shader_parameter(&"breath", br)
		s.set_shader_parameter(&"pallor", _pallor)
		s.set_shader_parameter(&"grey", _grey)

	# Stir spring: an oscillating jolt plus a decaying tension envelope.
	_jolt_v += (-120.0 * _jolt - 9.0 * _jolt_v) * delta
	_jolt += _jolt_v * delta
	_env = move_toward(_env, 0.0, delta * (1.6 + _env))

	if not _flat:
		# Awake-ish patients fidget and now and then flinch.
		var awake := clampf(1.0 - _sedation / 0.7, 0.0, 1.0)
		_fidget = move_toward(_fidget, awake, delta)
		if awake > 0.0:
			_next_fidget -= delta
			if _next_fidget <= 0.0:
				_next_fidget = _rng.randf_range(1.2, 4.0) / (0.5 + awake)
				stir(awake * _rng.randf_range(0.15, 0.45))
		# Small twitches when vitals are very low.
		var tw_target := clampf((25.0 - _vitals) / 25.0, 0.0, 1.0)
		if tw_target > 0.0:
			_next_twitch -= delta
			if _next_twitch <= 0.0:
				_next_twitch = _rng.randf_range(0.4, 1.8)
				_twitch = tw_target * _rng.randf_range(0.3, 0.8)
		_twitch = move_toward(_twitch, 0.0, delta * 3.0)
	else:
		_fidget = move_toward(_fidget, 0.0, delta * 2.0)
		_twitch = 0.0
		_jolt = move_toward(_jolt, 0.0, delta)

	rig.position = Vector3(0.0, maxf(0.0, _env) * 0.025 + absf(_jolt) * 0.01, _jolt * 0.006)
	_builder.animate(self, _jolt, _env, _fidget, _twitch, _t)

	for site in _bleed:
		_tick_bleed(_bleed[site], delta)


# -- bleeding --------------------------------------------------------------------------------------

func _make_bleed(site: String) -> Dictionary:
	var anchor: Node3D = anchors[site]
	var skin := Kit.decal(anchor, Kit.blood_tex(), Vector3(0.1, 0.25, 0.1))
	skin.visible = false
	var path: Array = drips.get(site, [Vector3.ZERO, Vector3.ZERO])
	var pool := Kit.decal(self, Kit.blood_tex(), Vector3(0.1, 0.1, 0.1), Transform3D(Basis(Vector3.UP, float(hash(site) % 100) * 0.06), path[1]))
	pool.visible = false
	var drops: Array[MeshInstance3D] = []
	for i in 3:
		var d := Kit.add_mesh(self, Kit.sphere(0.009, 6, 4), Kit.blood_mat(), Transform3D(Basis().scaled(Vector3(1, 1.6, 1)), path[0]))
		d.visible = false
		drops.append(d)
	return {"target": 0.0, "cur": 0.0, "pool_amt": 0.0, "skin": skin, "pool": pool, "drops": drops,
		"from": path[0], "to": path[1], "phase": 0.0}


func _tick_bleed(bl: Dictionary, delta: float) -> void:
	var target: float = bl.target
	var cur: float = move_toward(bl.cur, target, delta * (0.35 if target > bl.cur else 0.15))
	bl.cur = cur
	var flowing := target > 0.02 and not _flat
	var pool_amt: float = bl.pool_amt
	if flowing:
		pool_amt = minf(1.0, pool_amt + delta * target * 0.12)
		bl.pool_amt = pool_amt
	var skin: Decal = bl.skin
	skin.visible = cur > 0.01
	var ss := lerpf(0.08, 0.36, cur)
	skin.size = Vector3(ss, 0.3, ss * 0.85)
	skin.modulate = Color(1, 1, 1, clampf(cur * 2.0, 0.0, 1.0))
	var pool: Decal = bl.pool
	pool.visible = pool_amt > 0.005
	var ps := lerpf(0.06, 0.7, sqrt(pool_amt))
	pool.size = Vector3(ps, 0.12, ps * 0.8)
	# Three drops take turns: each falls during one unit of a three-unit cycle.
	var phase: float = fmod(float(bl.phase) + delta * (0.6 + target * 2.2), 3.0) if flowing else 0.0
	bl.phase = phase
	var drops: Array = bl.drops
	for i in drops.size():
		var d: MeshInstance3D = drops[i]
		var p := fmod(phase + float(i), 3.0) - 2.0
		if not flowing or p < 0.0 or i >= 1 + int(target * 2.99):
			d.visible = false
			continue
		d.visible = true
		var f: Vector3 = bl.from
		var to: Vector3 = bl.to
		d.position = Vector3(lerpf(f.x, to.x, p), lerpf(f.y, to.y, p * p), lerpf(f.z, to.z, p))
