extends RefCounted
## The shared wind-up, strike, recover model for the shove, the anesthetic jab and the bone saw
## (docs/HANDS_AND_FEEDBACK.md "Wind-ups", docs/CONTRACTS.md "Combat"). One instance lives in
## game.combat on every machine.
##
## Phases per player: WINDUP (arm pulled back; a shove charges while the button is held), STRIKE
## (the hit resolves on the host as it starts), RECOVER (back to rest). Every machine keeps the same
## state so the whole team sees the pull-back before the blow:
##   owner    starts the wind-up locally the moment the input happens (begin_local / release_local)
##            and predicts its own strike; a client sends the reliable RPCs Combat._rpc_windup and
##            Combat._rpc_release (the shove's held seconds)
##   host     runs the authoritative timer: the jab and the saw strike WINDUP[k] after the wind-up
##            arrived, the shove strikes on release (never before SHOVE_MIN), or by itself once held
##            SHOVE_MAX (+ HOST_HOLD_SLACK). The shove's charge is capped from the two arrival
##            times. Broadcasts cb_windup {id, k, s}, cb_swing {id, k, s, c} and cb_cancel {id, s}
##   others   play what the events say
## Cooldowns start at the strike (and at a cancel). Getting hit, downed, shoved, stunned, carried or
## busy cancels a wind-up with no strike (host), and the cooldown still starts.

const WINDUP := 0
const STRIKE := 1
const RECOVER := 2

## Fixed wind-ups (seconds) for the click actions.
const WINDUP_TIME := {"jab": 0.35, "saw": 0.3}
## The shove: a tap still winds up this long; full charge at SHOVE_FULL held; it fires by itself at SHOVE_MAX.
const SHOVE_MIN := 0.2
const SHOVE_FULL := 0.9
const SHOVE_MAX := 1.5
const STRIKE_TIME := {"shove": 0.16, "jab": 0.18, "saw": 0.22}
const RECOVER_TIME := {"shove": 0.36, "jab": 0.32, "saw": 0.36}
## Host: extra seconds a released charge may claim over what the host measured between the two events,
## and how much longer than SHOVE_MAX the host waits for a release before firing it itself.
const HOST_CHARGE_SLACK := 0.3
const HOST_HOLD_SLACK := 0.4
## Stun the shove gives a capturable monster: a tap and a full charge (lerped by the charge).
const STUN_TAP := 2.0
const STUN_FULL := 3.5
## Knockback on a shoved player: a tap and a full charge.
const KNOCK_TAP := 11.0
const KNOCK_FULL := 16.0
## Noise (host): starting a wind-up, and a charging shove every CHARGE_NOISE_EVERY seconds.
const NOISE_WINDUP := 0.3
const NOISE_CHARGE_MIN := 0.3
const NOISE_CHARGE_MAX := 0.65
const CHARGE_NOISE_EVERY := 0.4
## Observers drop a wind-up whose strike never came after this long (a lost host).
const OBSERVER_TIMEOUT := 4.0
## Others always see at least this much of a wind-up before its strike, even when both events arrive
## in the same frame (a lost packet resent under lag); the hit itself already happened on the host.
const MIN_SHOWN_WINDUP := 0.15

var combat: Node
var game: Node

## Every machine: peer id -> state {k, s (seq), ph, t, held, c, rel (released), rheld (claimed held),
## full (full tick played), nz (next noise), charge_snd (Audio player), local (owner-driven here)}
var states: Dictionary = {}
## Host: peer id -> {kind: world_time the next wind-up of that kind is accepted}
var cooldown_until: Dictionary = {}
## Owner machine: peer id -> {kind: world_time its own cooldown ends}
var local_next: Dictionary = {}
## Tests (and the nettest): how many strikes / wind-ups / cancels this machine saw per peer, and the
## world_time and wall msec of the latest of each: {peer: {w, st, x, w_t, st_t, w_ms, st_ms, c}}.
var seen: Dictionary = {}
## Host: the last strike it resolved: {id, k, c, held, claim}.
var last_strike: Dictionary = {}
## Tests: a client claims this many held seconds on release instead of the real hold (-1 off).
var claim_override := -1.0
## Tools: hold every action where it is (screenshots).
var freeze := false

var _seq := 0
var _done: Dictionary = {}   # peer id -> seq of its last finished action (late events for it are ignored)


func _init(c: Node) -> void:
	combat = c
	game = c.game


# =========================================================================
# queries (every machine)
# =========================================================================

## The visible action of p: {} or {k, ph, t, u (0..1 through the phase), charge (0..1 shown), c}.
func action_of(p: Node) -> Dictionary:
	if p == null or not is_instance_valid(p):
		return {}
	var s = states.get(int(p.peer_id))
	if s == null:
		return {}
	var dur := phase_length(String(s.k), int(s.ph))
	var u := clampf(float(s.t) / dur, 0.0, 1.0) if dur > 0.0 else 1.0
	var charge := float(s.c)
	if String(s.k) == "shove" and int(s.ph) == WINDUP:
		charge = charge_of(float(s.t))
		u = clampf(float(s.t) / SHOVE_FULL, 0.0, 1.0)
	return {"k": s.k, "ph": s.ph, "t": s.t, "u": u, "charge": charge, "c": s.c}


## Winding up or charging right now (walk speed, no sprint, no slot changes).
func is_winding(p: Node) -> bool:
	var s = states.get(int(p.peer_id)) if p != null else null
	return s != null and int(s.ph) == WINDUP


## Busy with an action (wind-up or strike): no new one starts.
func is_busy(p: Node) -> bool:
	var s = states.get(int(p.peer_id)) if p != null else null
	return s != null and int(s.ph) != RECOVER


static func phase_length(k: String, ph: int) -> float:
	match ph:
		WINDUP:
			return SHOVE_FULL if k == "shove" else float(WINDUP_TIME.get(k, 0.3))
		STRIKE:
			return float(STRIKE_TIME.get(k, 0.2))
	return float(RECOVER_TIME.get(k, 0.3))


## 0..1 charge from held seconds: 0 at a tap (SHOVE_MIN), 1 at SHOVE_FULL.
static func charge_of(held: float) -> float:
	return clampf((held - SHOVE_MIN) / (SHOVE_FULL - SHOVE_MIN), 0.0, 1.0)


static func stun_for(charge: float) -> float:
	return lerpf(STUN_TAP, STUN_FULL, clampf(charge, 0.0, 1.0))


static func cooldown_for(k: String) -> float:
	match k:
		"saw":
			return combat_const("SWING_COOLDOWN", 0.8)
		"jab":
			return combat_const("JAB_COOLDOWN", 1.0)
	return C.SHOVE_COOLDOWN


static func combat_const(n: String, fallback: float) -> float:
	var s: GDScript = load("res://scripts/combat/combat.gd")
	var m := s.get_script_constant_map()
	return float(m.get(n, fallback))


func _now() -> float:
	return float(game.world_time)


## Can p start an action at all (alive, standing, not carrying, dragging, operating, stunned...)?
func can_act(p: Node) -> bool:
	if p == null or not is_instance_valid(p) or not p.alive or p.downed or p.stun > 0.0:
		return false
	if p.carrying != 0 or p.carried_by != 0 or p.on_table or p.operating or p.hive_view:
		return false
	return combat.dragging(p) < 0


# =========================================================================
# the owner's machine
# =========================================================================

## The local player pressed the shove (k "shove") or clicked with the saw / the needle. False when
## the action cannot start (busy, cooling down, the wrong thing in hand).
func begin_local(p: Node, k: String) -> bool:
	if not can_act(p) or is_busy(p):
		return false
	if _now() < float((local_next.get(int(p.peer_id), {}) as Dictionary).get(k, -INF)):
		return false
	if k != "shove" and String(p.selected_stack().kind) != ("bone_saw" if k == "saw" else "anesthetic"):
		return false
	_seq += 1
	var seq := _seq * 8 + (int(p.peer_id) & 7)
	_start(p, k, seq, true)
	if game.is_host():
		host_begin(p, k, seq)
	elif Net.active:
		combat._rpc_windup.rpc_id(Net.HOST_ID, k, seq)
	return true


## The local player let go of a charging shove (or it hit SHOVE_MAX).
func release_local(p: Node) -> void:
	var s = states.get(int(p.peer_id))
	if s == null or String(s.k) != "shove" or int(s.ph) != WINDUP or bool(s.rel):
		return
	s.rel = true
	s.rheld = minf(float(s.t), SHOVE_MAX)
	var claim: float = s.rheld if claim_override < 0.0 else claim_override
	if game.is_host():
		host_release(p, int(s.s), claim)
	elif Net.active:
		combat._rpc_release.rpc_id(Net.HOST_ID, int(s.s), claim)


# =========================================================================
# the host
# =========================================================================

## Host: a wind-up starts (from the local player, a bot, or a client's RPC).
func host_begin(p: Node, k: String, seq: int) -> void:
	if not game.is_host() or p == null or not is_instance_valid(p):
		return
	var id := int(p.peer_id)
	var refuse := ""
	if not can_act(p):
		refuse = "busy"
	elif _now() < float((cooldown_until.get(id, {}) as Dictionary).get(k, -INF)):
		refuse = "cooldown"
	elif k != "shove" and String(p.selected_stack().kind) != ("bone_saw" if k == "saw" else "anesthetic"):
		refuse = "item"
	else:
		var cur = states.get(id)
		if cur != null and int(cur.s) != seq and int(cur.ph) != RECOVER:
			refuse = "busy"
	if refuse != "":
		combat.last_result = {"what": "refused" if refuse != "cooldown" else "cooldown", "why": refuse}
		if states.has(id) and int(states[id].s) == seq:
			states.erase(id)
		_stop_charge_sound(id)
		game._broadcast("cb_cancel", {"id": id, "s": seq, "cd": false})
		return
	var s = states.get(id)
	if s == null or int(s.s) != seq:
		s = _start(p, k, seq, p.is_local or p.is_bot)
	s["host"] = true
	s["nz"] = CHARGE_NOISE_EVERY
	game.emit_noise(p.global_position, NOISE_WINDUP, "windup")
	game._broadcast("cb_windup", {"id": id, "k": k, "s": seq})


## Host: the shove was released after `claim` held seconds (the owner's clock). The claim is capped
## by what the host measured between the wind-up and the release arriving.
func host_release(p: Node, seq: int, claim: float) -> void:
	if not game.is_host() or p == null:
		return
	var s = states.get(int(p.peer_id))
	if s == null or int(s.s) != seq or String(s.k) != "shove" or int(s.ph) != WINDUP:
		return
	var measured := float(s.t)
	var held := minf(minf(maxf(claim, 0.0), measured + HOST_CHARGE_SLACK), SHOVE_MAX)
	s.rel = true
	s.rheld = held
	s["claim"] = claim


## Host: stop p's wind-up without a strike (hit, shoved, downed, stunned...). The cooldown starts.
func cancel(p: Node, why := "") -> void:
	if p == null or not is_instance_valid(p):
		return
	var id := int(p.peer_id)
	var s = states.get(id)
	if s == null or int(s.ph) != WINDUP:
		return
	if game.is_host():
		_set_cooldown(id, String(s.k))
		game._broadcast("cb_cancel", {"id": id, "s": int(s.s), "cd": true, "why": why})
	_note(id, "x")
	_end_local(p, s, true)
	_done[id] = int(s.s)
	states.erase(id)


func _set_cooldown(id: int, k: String) -> void:
	if not cooldown_until.has(id):
		cooldown_until[id] = {}
	cooldown_until[id][k] = _now() + cooldown_for(k) * float(combat.HOST_COOLDOWN_SLACK)


# =========================================================================
# every machine
# =========================================================================

func _start(p: Node, k: String, seq: int, owner_here: bool) -> Dictionary:
	var id := int(p.peer_id)
	_stop_charge_sound(id)
	var s := {"k": k, "s": seq, "ph": WINDUP, "t": 0.0, "held": 0.0, "c": 0.0, "rel": false, "rheld": 0.0,
		"full": false, "nz": CHARGE_NOISE_EVERY, "local": owner_here, "host": false}
	states[id] = s
	_note(id, "w")
	var at: Vector3 = p.global_position + Vector3.UP * 1.3
	var mine: bool = p.is_local
	if k == "shove":
		var snd = Audio.play("hands_charge", at, -3.0 if mine else -11.0, 0.03)
		s["charge_snd"] = snd
		s["charge_stream"] = snd.stream if snd != null else null
	else:
		Audio.play("hands_windup", at, -4.0 if mine else -9.0, 0.08)
	return s


func tick(delta: float) -> void:
	if freeze:
		return
	for id in states.keys():
		var s: Dictionary = states[id]
		var p = game.players.get(id)
		if p == null or not is_instance_valid(p):
			_stop_charge_sound(id)
			states.erase(id)
			continue
		s.t = float(s.t) + delta
		if int(s.ph) == WINDUP:
			_tick_windup(p, s, delta)
		elif int(s.ph) == STRIKE:
			if float(s.t) >= phase_length(String(s.k), STRIKE):
				s.ph = RECOVER
				s.t = 0.0
		elif float(s.t) >= phase_length(String(s.k), RECOVER):
			_done[id] = int(s.s)
			states.erase(id)
		var snd = s.get("charge_snd")
		if snd != null and is_instance_valid(snd) and snd is Node3D:
			(snd as Node3D).global_position = p.global_position + Vector3.UP * 1.3


func _tick_windup(p: Node, s: Dictionary, delta: float) -> void:
	var k := String(s.k)
	var id := int(p.peer_id)
	var host: bool = game.is_host()
	if s.has("pend") and not host:
		if float(s.t) >= MIN_SHOWN_WINDUP:
			_to_strike(p, s, float(s.pend))
		return
	if host and not can_act(p):
		cancel(p, "busy")
		return
	if k == "shove":
		var held := float(s.t)
		if not bool(s.full) and held >= SHOVE_FULL:
			s.full = true
			Audio.play("hands_full", p.global_position + Vector3.UP * 1.4, -2.0 if p.is_local else -12.0, 0.0)
			if p.is_local and p.fx != null and p.fx.has_method("add_shake"):
				p.fx.add_shake(0.18, 0.2)
		if host and bool(s.get("host", false)):
			s.nz = float(s.nz) - delta
			if float(s.nz) <= 0.0:
				s.nz = CHARGE_NOISE_EVERY
				game.emit_noise(p.global_position, lerpf(NOISE_CHARGE_MIN, NOISE_CHARGE_MAX, charge_of(held)), "charge")
		# The owner lets go at SHOVE_MAX by itself.
		if bool(s.local) and not bool(s.rel) and held >= SHOVE_MAX:
			release_local(p)
		if host and bool(s.get("host", false)):
			var fire := bool(s.rel) and held >= SHOVE_MIN
			if not bool(s.rel) and held >= SHOVE_MAX + HOST_HOLD_SLACK:
				s.rel = true
				s.rheld = SHOVE_MAX
				fire = true
			if fire:
				_host_strike(p, s)
		elif not host and bool(s.local) and bool(s.rel) and held >= SHOVE_MIN:
			_to_strike(p, s, charge_of(float(s.rheld)))   # the owner predicts its own shove
		elif not host and not bool(s.local) and held >= SHOVE_MAX + OBSERVER_TIMEOUT:
			states.erase(id)
			_stop_charge_sound(id)
		return
	var w := float(WINDUP_TIME.get(k, 0.3))
	if host and bool(s.get("host", false)):
		if float(s.t) >= w:
			_host_strike(p, s)
	elif not host and bool(s.local):
		if float(s.t) >= w:
			_to_strike(p, s, 0.0)   # predicted: the host's strike lands a lag later
	elif float(s.t) >= w + OBSERVER_TIMEOUT:
		states.erase(id)


func _host_strike(p: Node, s: Dictionary) -> void:
	var k := String(s.k)
	var id := int(p.peer_id)
	var c := charge_of(float(s.rheld)) if k == "shove" else 0.0
	c = snappedf(c, 0.01)
	_set_cooldown(id, k)
	_to_strike(p, s, c)
	last_strike = {"id": id, "k": k, "c": c, "held": float(s.rheld), "claim": float(s.get("claim", s.rheld)), "t": _now()}
	game._broadcast("cb_swing", {"id": id, "k": k, "s": int(s.s), "c": c})
	match k:
		"shove":
			combat.strike_shove(p, c)
		"saw":
			if String(p.selected_stack().kind) == "bone_saw":
				combat._swing(p)
		"jab":
			if String(p.selected_stack().kind) == "anesthetic":
				combat._jab(p)
			else:
				combat.last_result = {"what": "air"}


func _to_strike(p: Node, s: Dictionary, c: float) -> void:
	if int(s.ph) != WINDUP:
		s.c = c
		return
	s.ph = STRIKE
	s.t = 0.0
	s.c = c
	var id := int(p.peer_id)
	_note(id, "st")
	(seen[id] as Dictionary)["c"] = c
	_end_local(p, s, false)
	combat.swings_seen[id] = int(combat.swings_seen.get(id, 0)) + 1
	var at: Vector3 = p.global_position + Vector3.UP * 1.4
	match String(s.k):
		"saw":
			Audio.play("combat_swing", at, -2.0, 0.1)
		"jab":
			Audio.play("combat_jab_swish", at, -6.0, 0.1)
		"shove":
			if p.is_local and p.fx != null and p.fx.has_method("recoil"):
				p.fx.recoil(Vector3(0, 0, -0.6 - 0.6 * c))


## The owner's own cooldown and the charge sound when an action strikes or is cancelled.
func _end_local(p: Node, s: Dictionary, cancelled: bool) -> void:
	var id := int(p.peer_id)
	_stop_charge_sound(id)
	if bool(s.local) or p.is_local:
		if not local_next.has(id):
			local_next[id] = {}
		local_next[id][String(s.k)] = _now() + cooldown_for(String(s.k))
	if cancelled and p.is_local and String(s.k) == "shove":
		Audio.play("hands_full", p.global_position + Vector3.UP * 1.4, -16.0, 0.0)


func _stop_charge_sound(id: int) -> void:
	var s = states.get(id)
	if s == null:
		return
	var snd = s.get("charge_snd")
	# Audio pools its players: only stop it while it still plays our charge.
	if snd != null and is_instance_valid(snd) and snd.has_method("stop") and snd.stream == s.get("charge_stream") and snd.playing:
		snd.stop()
	s.erase("charge_snd")


func _note(id: int, what: String) -> void:
	if not seen.has(id):
		seen[id] = {"w": 0, "st": 0, "x": 0, "w_t": -1.0, "st_t": -1.0, "w_ms": 0, "st_ms": 0, "c": 0.0}
	var e: Dictionary = seen[id]
	e[what] = int(e.get(what, 0)) + 1
	if what != "x":
		e[what + "_t"] = _now()
		e[what + "_ms"] = Time.get_ticks_msec()


# =========================================================================
# events (every machine but the host)
# =========================================================================

func on_event(kind: String, data: Dictionary) -> void:
	var id := int(data.get("id", 0))
	var p = game.players.get(id)
	if p == null or not is_instance_valid(p):
		return
	var seq := int(data.get("s", -1))
	if int(_done.get(id, -1)) == seq:
		return   # that action already played out here (the owner predicted it)
	var s = states.get(id)
	match kind:
		"cb_windup":
			if s != null and int(s.s) == seq:
				return   # the owner started it on the input
			_start(p, String(data.get("k", "shove")), seq, false)
		"cb_swing":
			if s == null or int(s.s) != seq:
				s = _start(p, String(data.get("k", "saw")), seq, false)
			if int(s.ph) == WINDUP and not bool(s.local) and float(s.t) < MIN_SHOWN_WINDUP:
				# The wind-up and the strike arrived together (a resent packet): show the pull-back first.
				s["pend"] = float(data.get("c", 0.0))
				return
			_to_strike(p, s, float(data.get("c", 0.0)))
		"cb_cancel":
			if s == null or int(s.s) != seq:
				return
			_note(id, "x")
			if bool(data.get("cd", true)):
				_end_local(p, s, true)
			else:
				_stop_charge_sound(id)
			_done[id] = seq
			states.erase(id)


func clear() -> void:
	for id in states.keys():
		_stop_charge_sound(id)
	states.clear()


## Host: a sequence number for a wind-up the host starts itself (the old use_count path).
func next_seq(p: Node) -> int:
	_seq += 1
	return _seq * 8 + (int(p.peer_id) & 7)


## Tools: put p in phase ph of action k, t seconds in, charge c (freeze keeps it there).
func pose_at(p: Node, k: String, ph: int, t: float, c := 0.0) -> void:
	var id := int(p.peer_id)
	_stop_charge_sound(id)
	states[id] = {"k": k, "s": -1, "ph": ph, "t": t, "held": t, "c": c, "rel": false, "rheld": 0.0,
		"full": true, "nz": 99.0, "local": false, "host": false}
