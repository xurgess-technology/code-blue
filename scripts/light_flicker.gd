class_name LightFlicker
extends Node
## Drives a ceiling fixture's light energy and its panel's emission.
##
## Attach as a child of an OmniLight3D or SpotLight3D:
## [codeblock]
## var light := SpotLight3D.new()
## light.set_meta("mode", 1)              # 0 steady, 1 flicker, 2 dead
## light.set_meta("seed", tile_hash)      # same on every peer
## light.set_meta("panel", panel_mesh)    # optional MeshInstance3D to glow
## var f := LightFlicker.new()
## light.add_child(f)
## [/codeblock]
##
## Determinism: the waveform is a pure function of (seed, time). Every peer
## running the same seed at the same clock sees the same flicker, so "the light
## went out just as it came round the corner" is a shared moment. The clock is
## [method LightFlicker.sync_time] — the host should feed it a world clock. Left
## alone it free-runs on local time, which is fine for single player and for
## the lookdev rig.

const MODE_STEADY := 0
const MODE_FLICKER := 1
const MODE_DEAD := 2

## Metadata keys read off the parent light.
const META_MODE := "mode"
const META_SEED := "seed"
const META_PANEL := "panel"          ## MeshInstance3D, or NodePath to one
const META_BASE_ENERGY := "base_energy"
const META_BASE_EMISSION := "base_emission"

# --- shared clock ---------------------------------------------------------
static var _clock := 0.0
static var _clock_driven := false
static var _clock_frame := -1

## Host calls this with the authoritative shift clock (seconds since the shift
## started). Clients call it from the snapshot. Once called, all instances use
## it instead of free-running.
static func sync_time(t: float) -> void:
	_clock = t
	_clock_driven = true

static func get_time() -> float:
	return _clock

## Advance the free-running clock. Every instance calls this, so it is guarded
## by the frame counter — otherwise a corridor with 12 fixtures would run the
## clock 12x too fast.
static func _advance(delta: float) -> void:
	if _clock_driven:
		return
	var f := Engine.get_process_frames()
	if f == _clock_frame:
		return
	_clock_frame = f
	_clock += delta

# ---------------------------------------------------------------------------

@export var mode := MODE_FLICKER
@export var flicker_seed := 0

## Energy the fixture sits at when healthy. Read from the light at _ready
## unless `base_energy` metadata overrides it.
@export var base_energy := 1.0
## Emission multiplier the panel mesh sits at when healthy.
@export var base_emission := 3.0
## How hard the panel follows the light. 1.0 = exactly.
@export var panel_follow := 1.0
## Emit the buzz cue. Turn off for fixtures in a room that already has ambience.
@export var buzz_enabled := true
## Minimum seconds between buzz cues from this fixture.
@export var buzz_cooldown := 0.9

var panel: MeshInstance3D

var _light: Light3D
var _panel_mat: StandardMaterial3D
var _seg_len := 1.0
var _last_factor := 1.0
var _buzz_timer := 0.0
var _was_dark := false
var _audio: Node
var _resolved := false


func _ready() -> void:
	_light = get_parent() as Light3D
	if _light == null:
		push_warning("LightFlicker must be a child of a Light3D; disabling.")
		set_process(false)
		return

	if _light.has_meta(META_MODE):
		mode = int(_light.get_meta(META_MODE))
	if _light.has_meta(META_SEED):
		flicker_seed = int(_light.get_meta(META_SEED))
	elif flicker_seed == 0:
		# Last resort: derive from the fixture's position so it is at least
		# stable across runs with the same generated map.
		var p := _light.global_position
		flicker_seed = hash(Vector3i(roundi(p.x * 16.0), roundi(p.y * 16.0), roundi(p.z * 16.0)))

	if _light.has_meta(META_BASE_ENERGY):
		base_energy = float(_light.get_meta(META_BASE_ENERGY))
	else:
		base_energy = _light.light_energy
	if _light.has_meta(META_BASE_EMISSION):
		base_emission = float(_light.get_meta(META_BASE_EMISSION))

	_resolve_panel()

	# Segment length: how often this fixture "decides" to do something new.
	# 0.55-1.5 s. Every fixture gets its own so a corridor never pulses in sync.
	_seg_len = lerpf(0.55, 1.5, _rand(0))
	_audio = _find_audio()
	_resolved = true
	set_process(true)
	_apply(_factor(LightFlicker.get_time()))


func _resolve_panel() -> void:
	if panel == null and _light.has_meta(META_PANEL):
		var v: Variant = _light.get_meta(META_PANEL)
		if v is MeshInstance3D:
			panel = v
		elif v is NodePath:
			panel = _light.get_node_or_null(v) as MeshInstance3D
		elif v is String:
			panel = _light.get_node_or_null(NodePath(v)) as MeshInstance3D
	if panel == null:
		return
	# Per-instance material: a shared material would make every fixture in the
	# level flicker together.
	var src := panel.get_active_material(0)
	if src is StandardMaterial3D:
		_panel_mat = (src as StandardMaterial3D).duplicate()
	else:
		_panel_mat = StandardMaterial3D.new()
		_panel_mat.albedo_color = Color(0.85, 0.92, 0.88)
	_panel_mat.emission_enabled = true
	if not _light.has_meta(META_BASE_EMISSION):
		base_emission = maxf(_panel_mat.emission_energy_multiplier, 1.0)
	panel.set_surface_override_material(0, _panel_mat)


func _find_audio() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("Audio")


## Change mode at runtime (a fuse blows, a fixture is repaired).
func set_mode(m: int) -> void:
	mode = clampi(m, MODE_STEADY, MODE_DEAD)


# ---------------------------------------------------------------------------
# Deterministic noise
# ---------------------------------------------------------------------------

## Hash-based uniform in [0,1) from this fixture's seed plus an index.
## Integer hash (not fract(sin(x))) so it is stable across GPUs/platforms and
## has no visible period.
func _rand(i: int) -> float:
	var h := int(flicker_seed) * 374761393 + i * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x00FFFFFF) / 16777216.0


# ---------------------------------------------------------------------------
# Waveform
# ---------------------------------------------------------------------------

## Energy multiplier in roughly [0, 1.25] for time [param t].
func _factor(t: float) -> float:
	match mode:
		MODE_STEADY:
			# Not literally steady: a real fluorescent tube has a faint mains
			# ripple. Tiny, but it stops "steady" looking like a still image.
			return 0.985 + 0.015 * sin(t * 37.0 + float(flicker_seed % 97))
		MODE_DEAD:
			return _dead_factor(t)
		_:
			return _flicker_factor(t)


func _flicker_factor(t: float) -> float:
	var seg := int(floor(t / _seg_len))
	var u := (t / _seg_len) - float(seg)          # 0..1 within the segment
	var roll := _rand(seg * 3 + 1)

	# Mains buzz ripple, present in every branch. This is what sells it as
	# electrical rather than as a fade.
	var buzz := 1.0 - 0.06 * absf(sin(t * 61.0))

	if roll < 0.58:
		# Mostly fine. Slight sag and a couple of shallow dips.
		var sag := 0.92 + 0.08 * sin(u * TAU * (1.0 + _rand(seg * 3 + 2) * 2.0))
		return sag * buzz

	elif roll < 0.80:
		# Strobe burst: rapid on/off for part of the segment.
		var burst_len := lerpf(0.12, 0.40, _rand(seg * 3 + 2))
		if u > burst_len:
			return buzz
		var hz := lerpf(9.0, 26.0, _rand(seg * 3 + 3))
		var s := sin(u * _seg_len * hz * TAU)
		# Square-ish, not sinusoidal: tubes snap, they do not fade.
		var v := 1.0 if s > -0.15 else 0.06
		# Slight overdrive on the re-strike.
		return (v + (0.25 if s > 0.9 else 0.0)) * buzz

	elif roll < 0.95:
		# Brief dropout: out for a beat, then back.
		var start := lerpf(0.05, 0.5, _rand(seg * 3 + 2))
		var dur := lerpf(0.06, 0.30, _rand(seg * 3 + 3))
		if u < start or u > start + dur:
			return buzz
		# Not quite zero — a dying tube keeps a dull glow at the ends.
		return 0.03

	else:
		# Long dropout with a stuttering re-strike, the good one.
		var start2 := lerpf(0.02, 0.30, _rand(seg * 3 + 2))
		var dur2 := lerpf(0.35, 0.85, _rand(seg * 3 + 3))
		if u < start2:
			return buzz
		if u < start2 + dur2:
			return 0.02
		# Re-strike: three hard stutters before it holds.
		var rt := (u - start2 - dur2) * _seg_len
		if rt < 0.06:
			return 1.15
		if rt < 0.10:
			return 0.04
		if rt < 0.15:
			return 1.25
		if rt < 0.18:
			return 0.05
		return buzz


func _dead_factor(t: float) -> float:
	# Dead fixtures are off. Very occasionally one spasms back for a fraction
	# of a second, which is worth more than any amount of constant flickering.
	# Long segments (4-9 s) and only ~12% of them do anything at all.
	var seg_len := lerpf(4.0, 9.0, _rand(7))
	var seg := int(floor(t / seg_len))
	var u := (t / seg_len) - float(seg)
	if _rand(seg * 5 + 11) > 0.12:
		return 0.0
	var start := lerpf(0.1, 0.8, _rand(seg * 5 + 12))
	var rt := (u - start) * seg_len
	if rt < 0.0:
		return 0.0
	# A short, ugly, uneven spark.
	if rt < 0.035:
		return 1.30
	if rt < 0.055:
		return 0.0
	if rt < 0.075:
		return 0.85
	if rt < 0.105:
		return 0.0
	if rt < 0.125:
		return 1.05
	return 0.0


# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _resolved:
		return
	LightFlicker._advance(delta)
	var f := _factor(LightFlicker.get_time())
	_apply(f)

	if _buzz_timer > 0.0:
		_buzz_timer -= delta

	# Fire the buzz cue on the *transition*, not continuously: a fixture that
	# snaps back on is what you hear, not one that is simply lit.
	var dark := f < 0.12
	if dark != _was_dark:
		if not dark and buzz_enabled and _buzz_timer <= 0.0 and mode != MODE_STEADY:
			_play_buzz()
			_buzz_timer = buzz_cooldown
		_was_dark = dark

	_last_factor = f


func _apply(f: float) -> void:
	if _light != null:
		_light.light_energy = base_energy * f
		# Kill shadow work entirely while the tube is out. Free and it stops
		# the shadow atlas churning on a fixture nobody can see.
		_light.visible = f > 0.005
	if _panel_mat != null:
		var pf := lerpf(1.0, f, clampf(panel_follow, 0.0, 1.0))
		_panel_mat.emission_energy_multiplier = base_emission * pf


func _play_buzz() -> void:
	# The audio pass is another engineer's work and may not have landed, so
	# every step of this is guarded: the autoload may be a stub, may lack the
	# method, and may not have a "buzz" cue registered.
	if _audio == null or not is_instance_valid(_audio):
		_audio = _find_audio()
	if _audio == null:
		return
	if _audio.has_method("has_cue") and not _audio.call("has_cue", "buzz"):
		buzz_enabled = false
		return
	if not _audio.has_method("play"):
		return
	var at: Vector3 = _light.global_position if _light != null else Vector3.ZERO
	# Audio.play() returns the player it used, or null when the cue is not in
	# the library. There is no "buzz" cue yet, so stop asking after the first
	# miss rather than warning on every re-strike in the building.
	var used: Variant = _audio.call("play", "buzz", at)
	if used == null:
		buzz_enabled = false


## Current 0..1-ish energy multiplier. Handy for gameplay that cares whether a
## room is lit right now (the Nurse's sight checks, say).
func get_factor() -> float:
	return _last_factor


func is_lit() -> bool:
	return _last_factor > 0.12
