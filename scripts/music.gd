class_name MusicDirector
extends RefCounted
## Maps game state to a single music intensity number, and that number to the three
## stem gains. One obvious place for game code to decide how scared the score is.
##
## The score is three 60-second stems that play in sync forever (see audio_manager.gd):
##   0 — dread     sparse detuned piano, sub pulses, distant metal, slow pad swells
##   1 — hunt      72 BPM tom pulse, a tension tone gliding up a semitone, gated shimmer
##   2 — critical  144 BPM off-beat answer, minor-second cluster stabs, a steady drone
##
## Fractional values crossfade, so the layers arrive and leave without a cut.
##
## Typical use from the game loop:
##     Audio.set_music_intensity(MusicDirector.intensity(phase, hunting, operating, danger))

## Phases where the score should be quiet regardless of anything else.
const CALM_PHASES: PackedStringArray = ["menu", "lobby", "clock_in", "won", "lost", "end"]

## Danger below this is just nerves, not a hunt.
const DANGER_FLOOR := 0.05
## Danger is scaled up a little so "fairly close" already reads as pressure.
const DANGER_GAIN := 1.3


## Game state -> 0..2 intensity.
##   phase            free-form string; anything in CALM_PHASES parks the score at dread
##   monsters_hunting true when at least one monster is actively chasing someone
##   operating        true when a surgeon is holding E at the table
##   danger           0..1, how close the nearest monster is (the heartbeat input)
static func intensity(phase: String, monsters_hunting: bool, operating: bool, danger: float) -> float:
	if CALM_PHASES.has(phase):
		return 0.0
	var d := clampf(danger, 0.0, 1.0)
	if d < DANGER_FLOOR:
		d = 0.0
	var pressure := clampf(d * DANGER_GAIN, 0.0, 1.0)
	var level := pressure
	if monsters_hunting:
		level = maxf(level, 1.0)
	if operating:
		# Surgery hammers on its own; add whatever pressure is in the room on top.
		level = maxf(level, 1.35 + 0.65 * pressure)
	if monsters_hunting and operating:
		# The signature moment: something lumbering at the OR mid-procedure.
		level = 2.0
	return clampf(level, 0.0, 2.0)


## Intensity -> linear gain per stem. Ported from Music.setIntensity(): the dread
## layer thins out under the critical layer rather than disappearing.
static func layer_gains(level: float) -> Dictionary:
	var l := clampf(level, 0.0, 2.0)
	var cl := clampf(l - 1.0, 0.0, 1.0)
	return {
		"dread": 1.0 - 0.35 * cl,
		"hunt": minf(l, 1.0),
		"critical": cl,
	}


## One step of an exponential crossfade toward `target`, framerate independent.
## `tau` is the time constant in seconds (the ~1.5 s the audio manager uses).
static func approach(current: float, target: float, tau: float, delta: float) -> float:
	if tau <= 0.0:
		return target
	return target + (current - target) * exp(-delta / tau)
