class_name PillLines
extends RefCounted
## SWEEP 4A HOOK (pharmacy, chunk 3): the exact 50-line list from docs/SWEEP4A.md section 3e,
## copied verbatim. Small, casual, lowercase; picked at random and never the same line twice in a
## row to the same player (the host tracks the last line shown per peer id).

const LINES := [
	"oh yeah, that's working",
	"you feel fine. you already felt fine",
	"tastes like a tums",
	"your back pops",
	"you're gonna be okay",
	"huh. neat",
	"that hit different",
	"you feel like calling your mom",
	"your headache is gone. you didn't have a headache",
	"swallowed it dry. bold",
	"chalky",
	"you feel slightly taller",
	"this is definitely doing something",
	"your left arm feels normal. good",
	"you feel ready to clock in",
	"that'll be $40",
	"you stop worrying about the noise down the hall. you should not stop worrying",
	"you can breathe through both nostrils",
	"you feel like you could lift the seal",
	"your hands stop shaking. they weren't shaking",
	"you think about getting a dog",
	"that went down wrong",
	"ten out of ten, would swallow again",
	"you're cured",
	"the ringing in your ears changes key",
	"you suddenly remember where you left your keys",
	"you feel like you slept eight hours. you did not",
	"your blood pressure is probably fine",
	"kinda sweet actually",
	"pretty sure that was a tic tac",
	"you feel brave. don't",
	"you're doing great, champ",
	"a warm feeling. hopefully from the pill",
	"your joints feel oiled",
	"you feel like a real doctor now",
	"you could go another shift",
	"you take a deep breath. it smells like bleach",
	"best pill you've ever had",
	"you feel like everyone likes you",
	"your eye stops twitching",
	"you're not scared of the dark anymore. for like a minute",
	"it's working. it has to be working",
	"you should probably read the label",
	"you don't need to see a doctor. you are one. kind of",
	"your stomach makes a noise",
	"you get the urge to organize the supply closet",
	"you feel like humming",
	"something in your chest unclenches",
	"you can hear colors. no you can't",
	"one more couldn't hurt",
]

## peer id (0 for "no specific player": patients and monsters share this key) -> last line shown.
static var _last := {}


## A random line, never the same as the last one shown to this key.
static func pick(key: int = 0) -> String:
	var prev: String = String(_last.get(key, ""))
	var line: String = LINES[randi() % LINES.size()]
	if LINES.size() > 1:
		while line == prev:
			line = LINES[randi() % LINES.size()]
	_last[key] = line
	return line


## Tools/tests: forget every player's last line (a fresh run).
static func reset() -> void:
	_last.clear()
