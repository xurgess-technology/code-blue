extends RefCounted
## The shove's stun window on a monster, readable without any HUD (docs/HANDS_AND_FEEDBACK.md):
## it staggers back and goes down hard, a dazed loop plays while it is down, and for the last
## RISE_WARNING seconds it twitches and starts to get up, so players can tell the window is closing.
## Every machine: the host records the stun when a shove lands and broadcasts `cb_stun {m, s}`;
## clients start the same countdown when it arrives. The pose is applied through
## Monster._update_visual -> game.combat.stun_pose(m, shaper, lying) (RigShaper `daze` / `rise`).

const MonsterScript := preload("res://scripts/monster.gd")

const RISE_WARNING := 0.6
## How fast it goes down after the shove lands, seconds.
const FALL_TIME := 0.3
## The stagger's first moments are pushed harder than a saw stagger.
const STAGGER_BOOST := 1.7
const DAZED_EVERY := 1.25
const HEAR_RANGE := 22.0

var game: Node
## monster id -> {start: world_time, end: world_time, snd: next dazed sound time, rose: bool}
var stuns: Dictionary = {}


func _init(g: Node) -> void:
	game = g


## Host: a shove stunned m for `seconds`. Tells every machine.
func host_stunned(m: Node, seconds: float) -> void:
	if m == null or not is_instance_valid(m) or seconds <= 0.0:
		return
	_record(int(m.monster_id), seconds)
	game._broadcast("cb_stun", {"m": int(m.monster_id), "s": snappedf(seconds, 0.01)})


func on_event(data: Dictionary) -> void:
	_record(int(data.get("m", -1)), float(data.get("s", 0.0)))


func _record(id: int, seconds: float) -> void:
	var now: float = game.world_time
	stuns[id] = {"start": now, "end": now + seconds, "snd": now + 0.35, "rose": false}


## Seconds of the window left for m (0 when it is not in one).
func left(m: Node) -> float:
	var s = stuns.get(int(m.monster_id)) if m != null else null
	if s == null:
		return 0.0
	return maxf(0.0, float(s.end) - float(game.world_time))


func tick(_delta: float) -> void:
	var now: float = game.world_time
	var viewer: Node = game.viewed_player() if game.has_method("viewed_player") else null
	for id in stuns.keys():
		var s: Dictionary = stuns[id]
		var m = game.monsters.get(id)
		if m == null or not is_instance_valid(m):
			stuns.erase(id)
			continue
		var stunned: bool = "mode" in m and int(m.mode) == MonsterScript.Mode.STUNNED
		# Over: time ran out, or it stopped being stunned (sedated, woken early) once the snapshot agrees.
		if now > float(s.end) + 0.25 or (not stunned and now - float(s.start) > 0.5):
			stuns.erase(id)
			continue
		var near: bool = viewer == null or (viewer as Node3D).global_position.distance_to(m.global_position) < HEAR_RANGE
		var remaining := float(s.end) - now
		if remaining > RISE_WARNING and now >= float(s.snd):
			s.snd = now + DAZED_EVERY
			if near:
				Audio.play("hands_dazed", m.global_position + Vector3.UP * 0.9, -4.0, 0.06)
		if remaining <= RISE_WARNING and not bool(s.rose):
			s.rose = true
			if near:
				Audio.play("hands_rise", m.global_position + Vector3.UP * 1.1, -1.0, 0.05)


## Monster._update_visual (every machine, every frame): push the shaper's pose for the window.
## `lying` is the monster's own lying blend (a sedated body ignores all this).
func pose(m: Node, sh: Object, lying: float) -> void:
	var s = stuns.get(int(m.monster_id))
	var daze := 0.0
	var rise := 0.0
	if s != null and lying <= 0.0:
		var now: float = game.world_time
		var since := now - float(s.start)
		var remaining := float(s.end) - now
		daze = clampf(since / FALL_TIME, 0.0, 1.0)
		daze = daze * daze * (3.0 - 2.0 * daze)
		if remaining < RISE_WARNING:
			rise = clampf(1.0 - remaining / RISE_WARNING, 0.0, 1.0)
			# Getting up in jerks: the body lifts, catches, lifts again.
			var jerk := absf(sin(rise * 17.0)) * 0.22 * (1.0 - rise)
			daze = minf(daze, clampf(1.0 - rise * rise * (3.0 - 2.0 * rise) + jerk, 0.0, 1.0))
		# The first moments stagger back harder than a saw blow, then the stagger gives way to the fall.
		var boost := STAGGER_BOOST if since < FALL_TIME else 1.0
		sh.stagger = clampf(float(sh.stagger) * boost * (1.0 - 0.75 * daze), 0.0, 1.0)
	if "daze" in sh:
		sh.daze = daze
		sh.rise = rise
