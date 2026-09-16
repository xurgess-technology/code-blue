extends Node
## The `Audio` autoload: every sound in Code Blue goes through here.
##
## All of it is baked offline by `tools/gen_audio.mjs` into `audio/sfx/*.wav` and
## `audio/music/*.wav` (the browser build synthesised it live with WebAudio; Godot
## has no equivalent, so the character was ported and rendered to disk).
##
## Quick tour:
##     Audio.play("step")                      # random step_01..step_04, 2D
##     Audio.play("thud", monster.position)    # 3D, audible down a corridor
##     Audio.play("beep", null, -6.0, 0.08)    # quieter, +/-8% pitch jitter
##     Audio.set_music_intensity(1.4)          # crossfades the three stems
##     Audio.sting("flatline")                 # ducks the music under it
##     Audio.heartbeat(0.7)                    # call every frame with 0..1 danger
##     Audio.set_ambience(true)
##
## Nothing here crashes when a file is missing or when there is no audio device:
## every lookup is guarded and every miss is a no-op (warned about once).

const Director := preload("res://scripts/music.gd")

const SFX_DIR := "res://audio/sfx"
const MUSIC_DIR := "res://audio/music"

const STEMS: PackedStringArray = ["dread", "hunt", "critical"]
const STINGS: PackedStringArray = ["scare", "flatline", "saved"]
## Cues that are beds, not one-shots: these get their WAV loop flag set.
const LOOPING: PackedStringArray = ["ambience", "dread", "hunt", "critical"]

## Buses created at startup if the project has no default_bus_layout.tres.
const BUS_SFX := "SFX"
const BUS_MUSIC := "Music"
const BUS_AMBIENCE := "Ambience"
const BUS_HALL := "Hall"
## Loading-screen beeps: straight to Master, so the warmup can mute every game sound (SFX, Hall,
## Ambience) without muting the screen that covers it.
const BUS_UI := "UI"

const MUSIC_BASE_DB := -4.0
const AMBIENCE_BASE_DB := -8.0

const POOL_2D := 14
const POOL_3D := 18
## Roughly a long corridor. Past this the Orderly's footsteps are gone.
const MAX_DIST_3D := 30.0
const UNIT_SIZE_3D := 3.0

## Crossfade time constant for the music layers.
const FADE_TAU := 1.5
## Stem volume floor; below this the player keeps running (so it stays phase-locked)
## but is inaudible.
const SILENT_DB := -60.0

## Flatline duck.
const DUCK_DB := -16.0
const DUCK_HOLD := 3.0

# ------------------------------------------------------------------ state

var _cues: Dictionary = {}            ## base name -> Array[AudioStreamWAV]
var _pool_2d: Array[AudioStreamPlayer] = []
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _next_2d := 0
var _next_3d := 0

var _stem_players: Dictionary = {}    ## stem name -> AudioStreamPlayer
var _stem_gain: Dictionary = {}       ## stem name -> current linear gain
var _intensity := 0.0
var _music_started := false

var _ambience_player: AudioStreamPlayer = null
var _sting_player: AudioStreamPlayer = null
var _heart_player: AudioStreamPlayer = null

var _danger := 0.0
var _heart_timer := 0.0

var _duck := 0.0                      ## 0..1, how far the music is ducked right now
var _duck_hold := 0.0

var _rng := RandomNumberGenerator.new()
var _warned: Dictionary = {}

## Settings hook: the player's music volume in dB, set by the Settings autoload
## (Settings.slider_to_db of "music_volume"). Added on top of MUSIC_BASE_DB and the duck.
var music_volume_db := 0.0

## True when there is no real audio output (headless CI, dummy driver). Everything
## still runs; this only exists so callers and probes can tell.
var silent := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	silent = _detect_silent()
	_setup_buses()
	_load_library()
	_build_players()
	set_music_intensity(0.0)


func _detect_silent() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name() == "headless":
		return true
	if AudioServer.get_output_device_list().is_empty():
		return true
	return false


# ------------------------------------------------------------------ buses

## Master -> SFX / Music / Ambience, with Hall (reverb) sitting between the music and
## Master. res://default_bus_layout.tres ships the same buses (Ambience sends to SFX there,
## so the effects volume setting covers it); the existing buses are reused and only
## missing ones are added, so this still works without the layout.
func _setup_buses() -> void:
	var hall := _ensure_bus(BUS_HALL, "Master")
	if hall > 0 and AudioServer.get_bus_effect_count(hall) == 0:
		var verb := AudioEffectReverb.new()
		verb.room_size = 0.9
		verb.damping = 0.45
		verb.spread = 1.0
		verb.dry = 1.0
		verb.wet = 0.28
		verb.predelay_msec = 35.0
		AudioServer.add_bus_effect(hall, verb)
	_ensure_bus(BUS_SFX, "Master")
	# The stems were rendered with their own hall; the send glues the layers and the
	# stings into one space, and SFX can opt in per cue via play(..., bus).
	_ensure_bus(BUS_MUSIC, BUS_HALL)
	_ensure_bus(BUS_AMBIENCE, "Master")
	_ensure_bus(BUS_UI, "Master")
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_MUSIC), MUSIC_BASE_DB)
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_AMBIENCE), AMBIENCE_BASE_DB)
	_ensure_fog_filters()


# ------------------------------------------------------------------ fog (SWEEP 4A HOOK, chunk 2)

## Sound gets muffled in the lot's fog ring: a low-pass on SFX and Ambience, driven locally by
## whatever the local player's fog depth is this frame (scripts/level/fog_ring.gd). 0 = clear.
var fog_muffle := 0.0
var _fog_lpf_sfx: AudioEffectLowPassFilter
var _fog_lpf_amb: AudioEffectLowPassFilter


func _ensure_fog_filters() -> void:
	if _fog_lpf_sfx == null:
		var sfx := AudioServer.get_bus_index(BUS_SFX)
		if sfx >= 0:
			_fog_lpf_sfx = AudioEffectLowPassFilter.new()
			_fog_lpf_sfx.cutoff_hz = 20000.0
			AudioServer.add_bus_effect(sfx, _fog_lpf_sfx)
	if _fog_lpf_amb == null:
		var amb := AudioServer.get_bus_index(BUS_AMBIENCE)
		if amb >= 0:
			_fog_lpf_amb = AudioEffectLowPassFilter.new()
			_fog_lpf_amb.cutoff_hz = 20000.0
			AudioServer.add_bus_effect(amb, _fog_lpf_amb)


func set_fog_muffle(amount01: float) -> void:
	amount01 = clampf(amount01, 0.0, 1.0)
	if is_equal_approx(amount01, fog_muffle):
		return
	fog_muffle = amount01
	_ensure_fog_filters()
	var hz := lerpf(20000.0, 400.0, amount01)
	if _fog_lpf_sfx != null:
		_fog_lpf_sfx.cutoff_hz = hz
	if _fog_lpf_amb != null:
		_fog_lpf_amb.cutoff_hz = hz


func _ensure_bus(bus_name: String, send_to: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	if AudioServer.get_bus_index(send_to) >= 0:
		AudioServer.set_bus_send(idx, send_to)
	return idx


# ------------------------------------------------------------------ loading

func _load_library() -> void:
	for entry in _scan(SFX_DIR):
		_register(SFX_DIR + "/" + entry)
	for entry in _scan(MUSIC_DIR):
		_register(MUSIC_DIR + "/" + entry)
	if _cues.is_empty():
		push_warning("Audio: no WAVs found under res://audio. Run `node tools/gen_audio.mjs`.")


## List the .wav files in a directory. Handles the editor case (raw .wav plus
## .wav.import sidecars) and the exported case (only the imported resource is there).
func _scan(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".import"):
			f = f.trim_suffix(".import")
		elif f.ends_with(".remap"):
			f = f.trim_suffix(".remap")
		if f.ends_with(".wav") and not out.has(f):
			out.append(f)
	return out


func _register(path: String) -> void:
	var stream := _load_wav(path)
	if stream == null:
		return
	var base := path.get_file().get_basename()
	# step_01 / skitter_03 are variants of "step" / "skitter"; step_done is not.
	var parts := base.rsplit("_", true, 1)
	if parts.size() == 2 and parts[1].length() >= 2 and parts[1].is_valid_int():
		base = parts[0]
	if LOOPING.has(base):
		_set_loop(stream)
	if not _cues.has(base):
		_cues[base] = []
	(_cues[base] as Array).append(stream)


## Load a WAV whether or not Godot's import pipeline has touched it. `load()` covers
## the normal (imported / exported) case; AudioStreamWAV.load_from_file covers a fresh
## checkout where the generator has just run and nothing has been imported yet.
func _load_wav(path: String) -> AudioStreamWAV:
	if ResourceLoader.exists(path):
		var res := load(path)
		if res is AudioStreamWAV:
			# Duplicate so setting loop_mode cannot leak into the shared resource cache.
			return (res as AudioStreamWAV).duplicate() as AudioStreamWAV
		if res is AudioStream:
			push_warning("Audio: %s imported as %s, not AudioStreamWAV." % [path, res.get_class()])
			return null
	if not FileAccess.file_exists(path):
		return null
	var w := AudioStreamWAV.load_from_file(path)
	if w == null:
		push_warning("Audio: could not load %s" % path)
	return w


## Godot's WAV importer defaults to loop disabled and the generator writes no smpl
## chunk, so the loop points are set here instead. The stems and the ambience bed are
## sample-exact loops, so the whole file is the loop.
func _set_loop(w: AudioStreamWAV) -> void:
	var bytes_per_frame := (2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if w.stereo else 1)
	var frames := w.data.size() / maxi(1, bytes_per_frame)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = frames


# ------------------------------------------------------------------ players

func _build_players() -> void:
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(p)
		_pool_2d.append(p)
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.bus = BUS_SFX
		p3.process_mode = Node.PROCESS_MODE_ALWAYS
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.unit_size = UNIT_SIZE_3D
		p3.max_distance = MAX_DIST_3D
		p3.panning_strength = 1.2
		add_child(p3)
		_pool_3d.append(p3)

	for stem in STEMS:
		var sp := AudioStreamPlayer.new()
		sp.bus = BUS_MUSIC
		sp.process_mode = Node.PROCESS_MODE_ALWAYS
		sp.volume_db = SILENT_DB
		add_child(sp)
		sp.stream = _first(stem)
		_stem_players[stem] = sp
		_stem_gain[stem] = 0.0

	_sting_player = AudioStreamPlayer.new()
	_sting_player.bus = BUS_MUSIC
	_sting_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_sting_player)

	_ambience_player = AudioStreamPlayer.new()
	_ambience_player.bus = BUS_AMBIENCE
	_ambience_player.process_mode = Node.PROCESS_MODE_ALWAYS
	_ambience_player.stream = _first("ambience")
	add_child(_ambience_player)

	_heart_player = AudioStreamPlayer.new()
	_heart_player.bus = BUS_SFX
	_heart_player.process_mode = Node.PROCESS_MODE_ALWAYS
	_heart_player.stream = _first("heartbeat")
	add_child(_heart_player)


func _first(cue: String) -> AudioStreamWAV:
	if not _cues.has(cue):
		return null
	var arr: Array = _cues[cue]
	return arr[0] if arr.size() > 0 else null


func _miss(cue: String) -> void:
	if _warned.has(cue):
		return
	_warned[cue] = true
	push_warning("Audio: no cue named '%s' (run `node tools/gen_audio.mjs`)." % cue)


# ------------------------------------------------------------------ public API

## Play a cue.
##   name         cue name; numbered variants (step_01..step_04) are picked at random
##   at           a Vector3 for a 3D positional one-shot, null for 2D/global
##   vol_db       offset in decibels
##   pitch_jitter 0..1, randomises pitch by +/- this fraction
##   bus          "" for the default SFX bus, or Audio.BUS_HALL to send it to the reverb
## Returns the player that was used, or null if the cue is missing.
func play(name: String, at = null, vol_db := 0.0, pitch_jitter := 0.0, bus := "") -> Node:
	if not _cues.has(name):
		_miss(name)
		return null
	var arr: Array = _cues[name]
	if arr.is_empty():
		return null
	var stream: AudioStreamWAV = arr[_rng.randi_range(0, arr.size() - 1)]
	var pitch := 1.0
	if pitch_jitter > 0.0:
		pitch = clampf(1.0 + _rng.randf_range(-pitch_jitter, pitch_jitter), 0.05, 4.0)

	if at is Vector3:
		var p3 := _take_3d()
		if p3 == null:
			return null
		p3.bus = bus if bus != "" else BUS_SFX
		p3.stream = stream
		p3.global_position = at
		p3.volume_db = vol_db
		p3.pitch_scale = pitch
		p3.play()
		return p3

	var p := _take_2d()
	if p == null:
		return null
	p.bus = bus if bus != "" else BUS_SFX
	p.stream = stream
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.play()
	return p


## 0 = exploration dread, 1 = something is hunting, 2 = surgery/critical.
## Fractional values crossfade. All three stems are started in the same frame on
## looping players, so they stay phase-locked no matter how the mix moves.
func set_music_intensity(level: float) -> void:
	_intensity = clampf(level, 0.0, 2.0)
	_start_music()


func music_intensity() -> float:
	return _intensity


## "scare", "flatline" or "saved". The flatline sting ducks the music out from under
## itself, the way the WebAudio version pulled the layer bus down.
func sting(kind: String) -> void:
	var cue := "sting_" + kind
	if not _cues.has(cue):
		_miss(cue)
		return
	if _sting_player != null:
		_sting_player.stream = _first(cue)
		_sting_player.volume_db = 0.0
		_sting_player.play()
	if kind == "flatline":
		_duck = 1.0
		_duck_hold = DUCK_HOLD


## Call every frame with 0..1 danger (how close the nearest monster is). The heartbeat
## rate and level scale with it exactly like AudioSys.update() did: a 1.3 s period at
## rest tightening to 0.45 s at full danger. Below 0.05 it goes quiet.
func heartbeat(danger: float) -> void:
	_danger = clampf(danger, 0.0, 1.0)


func set_ambience(on: bool) -> void:
	if _ambience_player == null or _ambience_player.stream == null:
		if on:
			_miss("ambience")
		return
	if on and not _ambience_player.playing:
		_ambience_player.play()
	elif not on and _ambience_player.playing:
		_ambience_player.stop()


func stop_music() -> void:
	for stem in STEMS:
		var p: AudioStreamPlayer = _stem_players.get(stem)
		if p != null and p.playing:
			p.stop()
	_music_started = false


## Every cue that resolved to a real stream, with its variant count. Used by the
## headless probe; handy in a debug overlay too.
func cue_manifest() -> Dictionary:
	var out := {}
	for k in _cues.keys():
		out[k] = (_cues[k] as Array).size()
	return out


# ------------------------------------------------------------------ internals

func _take_2d() -> AudioStreamPlayer:
	for i in _pool_2d.size():
		var p := _pool_2d[(_next_2d + i) % _pool_2d.size()]
		if not p.playing:
			_next_2d = (_next_2d + i + 1) % _pool_2d.size()
			return p
	# Everything is busy: steal the oldest slot rather than allocating.
	var victim := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % _pool_2d.size()
	return victim


func _take_3d() -> AudioStreamPlayer3D:
	for i in _pool_3d.size():
		var p := _pool_3d[(_next_3d + i) % _pool_3d.size()]
		if not p.playing:
			_next_3d = (_next_3d + i + 1) % _pool_3d.size()
			return p
	var victim := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _pool_3d.size()
	return victim


## Start every stem in the same frame so the three loops share a phase forever.
func _start_music() -> void:
	if _music_started:
		return
	var any := false
	for stem in STEMS:
		var p: AudioStreamPlayer = _stem_players.get(stem)
		if p == null or p.stream == null:
			_miss(stem)
			continue
		p.volume_db = SILENT_DB
		p.play(0.0)
		any = true
	_music_started = any


func _process(delta: float) -> void:
	_update_music(delta)
	_update_heartbeat(delta)


func _update_music(delta: float) -> void:
	var target: Dictionary = Director.layer_gains(_intensity)
	for stem in STEMS:
		var p: AudioStreamPlayer = _stem_players.get(stem)
		if p == null or p.stream == null:
			continue
		var g: float = Director.approach(_stem_gain[stem], float(target[stem]), FADE_TAU, delta)
		_stem_gain[stem] = g
		p.volume_db = linear_to_db(g) if g > 0.001 else SILENT_DB

	# Flatline duck: hold, then release with a slower time constant.
	if _duck_hold > 0.0:
		_duck_hold -= delta
	else:
		_duck = Director.approach(_duck, 0.0, 1.2, delta)
		if _duck < 0.0001:
			_duck = 0.0
	var idx := AudioServer.get_bus_index(BUS_MUSIC)
	if idx >= 0:
		# Settings hook: music_volume_db is the player's music slider (-80 dB means off).
		AudioServer.set_bus_volume_db(idx, maxf(-80.0, MUSIC_BASE_DB + DUCK_DB * _duck + music_volume_db))
		AudioServer.set_bus_mute(idx, music_volume_db <= -79.9)


func _update_heartbeat(delta: float) -> void:
	if _danger < 0.05 or _heart_player == null or _heart_player.stream == null:
		_heart_timer = 0.0
		return
	_heart_timer -= delta
	if _heart_timer > 0.0:
		return
	_heart_timer = 1.3 - _danger * 0.85
	# The rendered cue peaks at -3 dBFS; scale it the way the original scaled its gain
	# (0.15 + 0.45 * danger against a 0.6 reference).
	_heart_player.volume_db = linear_to_db(0.25 + 0.75 * _danger)
	_heart_player.pitch_scale = 1.0 + 0.12 * _danger
	_heart_player.play()
