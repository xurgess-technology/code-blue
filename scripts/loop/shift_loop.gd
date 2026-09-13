extends Node
## The shift loop (loop worker, sweep 2). One per game, child "Loop" of Game, on every machine.
##
##   LOBBY    players start outside (level_info.neutral) or where the level spawns them, walk in,
##            and hold E at the time clock.
##   SHIFT    clock in: loot and monsters spawn, GRACE_SECONDS to look around. Then the break-room
##            phone rings. Answering (E) plays the call as subtitles; nobody answering for
##            AUTO_ANSWER_SECONDS lets the answering machine take it, so the first patient always
##            comes. The patient's case is added as "incoming", their supplies spawn, and a
##            paramedic crew wheels them on a gurney along the navmesh from level_info.ambulance
##            to a free patient table, puts them on it and leaves.
##            Once the first patient is on a table, the phone rings again at a random time with an
##            optional extra patient: answering accepts (second table, bonus pay), not answering
##            for EXTRA_DECLINE_SECONDS declines without penalty.
##            Vitals are the only timer. Clock out (hold E) once every accepted patient is stable
##            or dead: pay per case through game.add_money, then a short paycheck screen.
##   WON      the paycheck screen, then the next shift's LOBBY in the same hospital (hands kept,
##            the dead get up outside).
##   LOST     everyone down or dead during the shift: game over, then a new run.
##
## The host runs all of it; clients mirror `net_state()` (inside the game snapshot, "lp.*") and
## play the ring, the subtitles and the crews locally.

const PhoneScript := preload("res://scripts/loop/phone.gd")
const CrewScript := preload("res://scripts/loop/crew.gd")
const HudScript := preload("res://scripts/loop/loop_hud.gd")

const GRACE_SECONDS := 60.0
const AUTO_ANSWER_SECONDS := 8.0
const EXTRA_DECLINE_SECONDS := 20.0
## The extra call rings this long after the first patient is on the table.
const EXTRA_DELAY := Vector2(45.0, 150.0)
## Paramedics set off this long after the call is picked up.
const DISPATCH_DELAY := 3.0
const RING_EVERY := 2.6
const CREW_SPEED := 2.1
## Longer walks start part of the way in (the fallback levels have no ambulance bay nearby).
const MAX_WALK := 55.0
const HANDOVER_SECONDS := 1.8
const CREW_GIVE_UP_SECONDS := 120.0
const PAYCHECK_SECONDS := 6.0
const GAME_OVER_SECONDS := 8.0
const PAY_STABLE := 200
const PAY_STABLE_PER_SHIFT := 25
const PAY_EXTRA := 300
const PAY_EXTRA_PER_SHIFT := 40
const DEAD_PENALTY := 150

var game: Node = null

# ---- replicated (host authoritative) ----
var grace_left := 0.0
var call_kind := ""        # "" | "first" | "extra"
var call_state := ""       # "" | "ringing" | "talking"
var call_t := 0.0
var subtitle := ""
var first_called := false
## case id -> {p: Vector3, y: float, ph: "in"|"hand"|"out", pt, ai, tb}
var crews := {}
var pay_note := ""

# ---- host ----
var extra_at := -1.0
var extra_done := false
## Tests: pin the patient and ailment the calls bring ({patient_id, ailment_id}).
var force_first := {}
var force_extra := {}
var _call_case := {}
var _lines: Array = []
var _line_i := 0
var _line_t := 0.0
var _dispatch: Array = []      # [{id, at}]
var _paths := {}               # case id -> {pts, i, t}
var _calls_made := 0
var _rng := RandomNumberGenerator.new()

# ---- local ----
var phone: Node3D = null
var hud: CanvasLayer = null
var _crew_nodes := {}
var _ring_timer := 0.0
var _rattle_timer := 0.0
var _last_call_state := ""


func setup(g: Node) -> void:
	game = g
	hud = HudScript.new()
	hud.name = "LoopHud"
	hud.loop = self
	add_child(hud)


## Everything back to "not on shift" (a new lobby, a new run, the menu). Every machine.
func reset() -> void:
	grace_left = 0.0
	call_kind = ""
	call_state = ""
	call_t = 0.0
	subtitle = ""
	first_called = false
	crews.clear()
	pay_note = pay_note if game != null and game.phase == game.Phase.WON else ""
	extra_at = -1.0
	extra_done = false
	_call_case = {}
	_lines = []
	_dispatch.clear()
	_paths.clear()
	_calls_made = 0
	_sync_crew_nodes()


## The level exists (game._add_landmarks, not in the dev room): place the break-room phone.
func on_level_built(level: Node3D, info: Dictionary) -> void:
	phone = null
	var spot := _phone_spot(info)
	if spot.is_empty():
		return
	phone = PhoneScript.create(bool(spot.get("wall", false)))
	level.add_child(phone)
	phone.global_position = spot.position
	phone.rotation.y = float(spot.yaw)


func on_clock_in() -> void:
	reset()
	pay_note = ""
	grace_left = GRACE_SECONDS
	_rng.seed = hash("%d|loop|%d" % [int(game.seed_value), int(game.shift)])


func on_game_over() -> void:
	call_kind = ""
	call_state = ""
	subtitle = ""
	_dispatch.clear()
	for id in crews.keys():
		crews[id]["ph"] = "out"


# =========================================================================
# host flow
# =========================================================================

func physics_tick(delta: float) -> void:
	if game == null or game.phase == game.Phase.MENU:
		return
	if game.is_host():
		_host_tick(delta)
	_local_tick(delta)


func _host_tick(delta: float) -> void:
	if game.phase == game.Phase.SHIFT and not game.dev_mode:
		if grace_left > 0.0:
			grace_left -= delta
			if grace_left <= 0.0:
				grace_left = 0.0
				if not first_called and call_state == "":
					start_call("first")
		if extra_at >= 0.0 and not extra_done and call_state == "" and game.world_time >= extra_at:
			if game.free_patient_table() >= 0 and _has_live_case():
				start_call("extra")
			else:
				extra_done = true
	if game.phase == game.Phase.SHIFT:
		_tick_call(delta)
		_tick_dispatch()
	_tick_crews(delta)


func _has_live_case() -> bool:
	for c in game.cases:
		if String(c.get("patient_id", "")) != "player" and (String(c.state) == "on_table" or String(c.state) == "incoming"):
			return true
	return false


## Host: the phone starts ringing with a call of `kind` ("first" or "extra").
func start_call(kind: String) -> void:
	if not game.is_host() or call_state != "":
		return
	call_kind = kind
	call_state = "ringing"
	call_t = 0.0
	_call_case = _roll(kind)
	if kind == "extra":
		extra_done = true
		game.say("The phone is ringing again.", 3.0)
	else:
		game.say("The phone is ringing in the break room.", 3.0)


## Host: someone pressed E on the ringing phone.
func answer(p: Node) -> void:
	if not game.is_host() or call_state != "ringing":
		return
	_begin_talk(p.player_name if p != null else "")


func _tick_call(delta: float) -> void:
	if call_state == "":
		return
	call_t += delta
	if call_state == "ringing":
		if call_kind == "first" and call_t >= AUTO_ANSWER_SECONDS:
			_begin_talk("")
		elif call_kind == "extra" and call_t >= EXTRA_DECLINE_SECONDS:
			_decline()
		return
	_line_t += delta
	if _line_i < _lines.size() and _line_t >= _line_seconds(String(_lines[_line_i])):
		_line_t = 0.0
		_line_i += 1
		if _line_i < _lines.size():
			subtitle = String(_lines[_line_i])
		else:
			_end_call()


func _begin_talk(who: String) -> void:
	var machine := who == ""
	call_state = "talking"
	call_t = 0.0
	_lines = call_lines(call_kind, _call_case, machine, who)
	_line_i = 0
	_line_t = 0.0
	subtitle = String(_lines[0]) if not _lines.is_empty() else ""
	if call_kind == "first":
		first_called = true
	_accept(_call_case, call_kind == "extra")


func _end_call() -> void:
	call_state = ""
	call_kind = ""
	subtitle = ""
	_lines = []


func _decline() -> void:
	_end_call()
	extra_done = true
	game.say("The phone stops ringing. Someone else can have that one.", 4.0)


## Host: the case exists from the moment the call is taken; its supplies spawn now and the
## paramedics set off shortly.
func _accept(cc: Dictionary, optional: bool) -> int:
	var id: int = game.add_case({"patient_id": cc.patient_id, "ailment_id": cc.ailment_id, "table": -1,
		"state": "incoming", "optional": optional})
	if id < 0:
		return -1
	_calls_made += 1
	game.spawn_supplies_for(game.case_by_id(id))
	_dispatch.append({"id": id, "at": float(game.world_time) + DISPATCH_DELAY})
	return id


func _tick_dispatch() -> void:
	for d in _dispatch.duplicate():
		if float(game.world_time) < float(d.at):
			continue
		var c: Dictionary = game.case_by_id(int(d.id))
		if c.is_empty() or String(c.state) != "incoming":
			_dispatch.erase(d)
			continue
		var table: int = game.free_patient_table()
		if table < 0:
			continue   # both tables busy: the crew waits outside until one frees up
		_dispatch.erase(d)
		_send_crew(int(d.id), c, table)


func _send_crew(id: int, c: Dictionary, table: int) -> void:
	var from := arrival_point()
	var stand := _stand_spot(table, from)
	var pts := _nav_path(from, stand)
	pts = _trim_path(pts, _max_walk())
	_paths[id] = {"pts": pts, "i": 1, "t": 0.0, "age": 0.0}
	var yaw := _yaw_along(pts[0], pts[1] if pts.size() > 1 else stand)
	crews[id] = {"p": pts[0], "y": yaw, "ph": "in", "pt": String(c.patient_id), "ai": String(c.ailment_id), "tb": table}
	if game.level_info.has("ambulance"):
		game._sound("loop_siren", from)


func _tick_crews(delta: float) -> void:
	if not game.is_host():
		return
	for id in crews.keys():
		var cr: Dictionary = crews[id]
		var path: Dictionary = _paths.get(id, {})
		if path.is_empty():
			crews.erase(id)
			continue
		path.age = float(path.age) + delta
		var c: Dictionary = game.case_by_id(int(id))
		if cr.ph != "out" and (c.is_empty() or String(c.state) != "incoming" or game.phase != game.Phase.SHIFT):
			_turn_back(id)
			continue
		match String(cr.ph):
			"in":
				if _walk(cr, path, delta) or float(path.age) > CREW_GIVE_UP_SECONDS:
					cr.ph = "hand"
					path.t = 0.0
					var tp: Vector3 = game.table_position(int(cr.tb))
					cr.y = _yaw_along(cr.p, tp) + PI * 0.5
			"hand":
				path.t = float(path.t) + delta
				if float(path.t) >= HANDOVER_SECONDS:
					_hand_over(int(id), cr, c)
			"out":
				if _walk(cr, path, delta) or float(path.age) > CREW_GIVE_UP_SECONDS:
					crews.erase(id)
					_paths.erase(id)


## Move a crew along its path; true once it reached the end.
func _walk(cr: Dictionary, path: Dictionary, delta: float) -> bool:
	var pts: PackedVector3Array = path.pts
	var i := int(path.i)
	var step := CREW_SPEED * delta
	var pos: Vector3 = cr.p
	while i < pts.size() and step > 0.0:
		var to := pts[i] - pos
		to.y = 0.0
		var d := to.length()
		if d <= step:
			pos = Vector3(pts[i].x, pts[i].y, pts[i].z)
			step -= d
			i += 1
		else:
			pos += to / d * step
			pos.y = lerpf(pos.y, pts[i].y, 0.2)
			step = 0.0
			cr.y = lerp_angle(float(cr.y), atan2(-to.x, -to.z), 0.25)
	cr.p = pos
	path.i = i
	return i >= pts.size()


func _turn_back(id) -> void:
	var cr: Dictionary = crews[id]
	cr.ph = "out"
	var back := _nav_path(cr.p, arrival_point())
	_paths[id] = {"pts": _trim_path_front(back, _max_walk()), "i": 1, "t": 0.0, "age": 0.0}


func _hand_over(id: int, cr: Dictionary, c: Dictionary) -> void:
	var table := int(cr.tb)
	if not game.case_on_table(table).is_empty():
		var other: int = game.free_patient_table()
		if other < 0:
			return   # wait with the patient until a table frees up
		table = other
		cr.tb = other
	c.table = table
	c.state = "on_table"
	c.vitals = float(c.get("vitals", 100.0))
	game._apply_cases_locally()
	var pname: String = Procedures.patient(String(c.patient_id)).get("name", "The patient")
	game.say("The paramedics put %s on the table. Good luck." % pname, 4.0)
	game._sound("deliver", game.table_position(table))
	if extra_at < 0.0 and not extra_done and not bool(c.get("optional", false)):
		extra_at = float(game.world_time) + _rng.randf_range(EXTRA_DELAY.x, EXTRA_DELAY.y)
	_turn_back(id)


## Host: a case became stable or dead (game.finish_case).
func on_case_finished(_c: Dictionary) -> void:
	pass


func table_reserved(table_index: int) -> bool:
	for cr in crews.values():
		if int(cr.get("tb", -1)) == table_index and String(cr.get("ph", "")) != "out":
			return true
	return false


# =========================================================================
# clocking out and pay
# =========================================================================

## Every accepted patient is stable or dead and nobody is on the way. Every machine.
func can_clock_out() -> bool:
	if game.phase != game.Phase.SHIFT or game.dev_mode:
		return false
	return _clock_out_blocker() == ""


func _clock_out_blocker() -> String:
	if not first_called:
		if call_state == "ringing":
			return "Answer the phone first."
		return "No patient yet. The phone will ring."
	if call_state == "talking":
		return "Listen to the call first."
	for c in game.cases:
		if String(c.get("patient_id", "")) == "player":
			continue
		if String(c.state) == "incoming":
			return "A patient is on the way."
		if String(c.state) == "on_table":
			return "Every patient has to be stable first."
	return ""


func clock_prompt(_p) -> String:
	match game.phase:
		game.Phase.LOBBY:
			return "Hold E: clock in"
		game.Phase.SHIFT:
			if game.dev_mode:
				return ""
			var why := _clock_out_blocker()
			return "Hold E: clock out" if why == "" else "!" + why
	return ""


func phone_prompt() -> String:
	if game == null or game.phase != game.Phase.SHIFT or call_state != "ringing":
		return ""
	return "Answer the phone" if call_kind == "first" else "Answer the phone (take the extra patient)"


## What a case pays at clock-out.
static func pay_for(c: Dictionary, shift: int) -> int:
	match String(c.get("state", "")):
		"stable":
			if bool(c.get("optional", false)):
				return PAY_EXTRA + PAY_EXTRA_PER_SHIFT * maxi(0, shift - 1)
			return PAY_STABLE + PAY_STABLE_PER_SHIFT * maxi(0, shift - 1)
		"dead":
			return -DEAD_PENALTY
	return 0


## Host: clock the team out. `force` (tests) ends the shift even with patients still open.
func clock_out(force: bool) -> void:
	if not game.is_host() or game.phase != game.Phase.SHIFT:
		return
	if not force and not can_clock_out():
		return
	var parts := []
	var total := 0
	for c in game.cases:
		if String(c.get("patient_id", "")) == "player":
			continue
		var amount := pay_for(c, int(game.shift))
		total += amount
		var pname: String = Procedures.patient(String(c.patient_id)).get("name", "Patient")
		var label := "%s%s" % [pname, " (extra)" if bool(c.get("optional", false)) else ""]
		match String(c.state):
			"stable":
				parts.append("%s stable +$%d" % [label, amount])
			"dead":
				parts.append("%s died -$%d" % [label, absi(amount)])
			_:
				parts.append("%s unfinished $0" % label)
	pay_note = "No patients, no pay." if parts.is_empty() else "%s. Total %s$%d." % [", ".join(parts), "-" if total < 0 else "", absi(total)]
	if total != 0:
		game.add_money(total, "shift:%d" % int(game.shift))
	_end_call()
	_dispatch.clear()
	for id in crews.keys():
		crews.erase(id)
	_paths.clear()
	game._sound("loop_clockout", game.clock_pos() + Vector3.UP * 1.2)
	game.finish_shift("Clocked out. %s" % pay_note, PAYCHECK_SECONDS)


func after_case_hint() -> String:
	if game.dev_mode or game.phase != game.Phase.SHIFT:
		return ""
	return " Clock out when you are ready." if _clock_out_blocker() == "" else ""


# =========================================================================
# tests, the dev panel, the old begin_shift
# =========================================================================

## Host: the old instant start: the first patient straight onto a table, no grace, no call.
func skip_to_first_patient_on_table() -> void:
	if not game.is_host():
		return
	grace_left = 0.0
	first_called = true
	extra_done = true
	_end_call()
	var cc := _roll("first")
	var table: int = game.free_patient_table()
	if table < 0:
		table = int(game.patient_tables[0].index) if not game.patient_tables.is_empty() else 0
	var id: int = game.add_case({"patient_id": cc.patient_id, "ailment_id": cc.ailment_id, "table": table, "state": "on_table"})
	if id >= 0:
		game.spawn_supplies_for(game.case_by_id(id))


func skip_grace() -> void:
	if game.is_host() and grace_left > 0.0:
		grace_left = 0.001


## Host (dev panel "Phone call"): an incoming patient right now, the paramedics already on the way.
func dev_phone_call() -> void:
	if not game.is_host() or game.phase != game.Phase.SHIFT:
		return
	_make_room_for_a_patient()
	var cc := _roll("first" if not first_called else "extra")
	var optional := first_called
	first_called = true
	grace_left = 0.0
	var id := _accept(cc, optional)
	if id >= 0:
		for d in _dispatch:
			if int(d.id) == id:
				d.at = float(game.world_time)
		game.say("Dispatch: %s, %s, coming in now." % [Procedures.patient(cc.patient_id).name, Procedures.ailment(cc.ailment_id).name.to_lower()], 3.0)


## Host (dev panel "Extra patient"): outside the dev room the extra call rings now; in the dev room
## (which has no phone) the extra patient is simply accepted and wheeled in.
func dev_extra_patient() -> void:
	if not game.is_host() or game.phase != game.Phase.SHIFT:
		return
	if game.dev_mode or phone == null:
		_make_room_for_a_patient()
		var cc := _roll("extra")
		first_called = true
		var id := _accept(cc, true)
		for d in _dispatch:
			if int(d.id) == id:
				d.at = float(game.world_time)
		return
	if call_state == "":
		extra_done = false
		start_call("extra")


## The dev room keeps taking patients: with every table taken, the oldest finished one goes.
func _make_room_for_a_patient() -> void:
	if game.free_patient_table() >= 0 or not game.dev_mode:
		return
	for c in game.cases:
		if String(c.state) == "stable" or String(c.state) == "dead":
			game.remove_case(int(c.id))
			return
	if not game.patient_tables.is_empty():
		var first: Dictionary = game.case_on_table(int(game.patient_tables[0].index))
		if not first.is_empty():
			game.remove_case(int(first.id))


func _roll(kind: String) -> Dictionary:
	if kind == "first" and not force_first.is_empty():
		return force_first.duplicate()
	if kind == "extra" and not force_extra.is_empty():
		return force_extra.duplicate()
	var salt := 0 if kind == "first" and _calls_made == 0 else 7717 * (_calls_made + 1)
	var r := Procedures.roll(int(game.seed_value) + salt, int(game.shift))
	var pid := String(r.patient)
	if kind == "extra":
		# Two of the same patient at once reads as a bug: bring the other one.
		for c in game.cases:
			if String(c.get("patient_id", "")) == pid and (String(c.state) == "on_table" or String(c.state) == "incoming"):
				var ids: Array = Procedures.PATIENTS.keys()
				ids.sort()
				pid = String(ids[(ids.find(pid) + 1) % ids.size()])
				break
	return {"patient_id": pid, "ailment_id": String(r.ailment)}


# =========================================================================
# text
# =========================================================================

static func call_lines(kind: String, cc: Dictionary, machine: bool, who: String) -> Array:
	var pt := Procedures.patient(String(cc.get("patient_id", "bob")))
	var ail := Procedures.ailment(String(cc.get("ailment_id", "gunshot")))
	var blurb := Procedures.blurb(String(cc.get("patient_id", "bob")), String(cc.get("ailment_id", "gunshot")))
	var lines := []
	if kind == "extra":
		lines.append("DISPATCH: %s, you still there? Another one, and nobody else will take it." % (who if who != "" else "Night shift"))
		lines.append("DISPATCH: %s. %s." % [pt.get("full_name", "Unknown"), ail.get("name", "")])
		if blurb != "":
			lines.append("DISPATCH: %s" % blurb)
		lines.append("DISPATCH: Bonus pay if they make it. Paramedics are bringing them to your second table.")
		return lines
	if machine:
		lines.append("ANSWERING MACHINE: *beep* DISPATCH: Night shift, pick up... Fine. Message.")
	else:
		lines.append("DISPATCH: %s? Good. You've got one coming in." % who)
	lines.append("DISPATCH: %s. %s." % [pt.get("full_name", "Unknown"), ail.get("name", "")])
	if blurb != "":
		lines.append("DISPATCH: %s" % blurb)
	lines.append("DISPATCH: Paramedics are wheeling them straight to your OR. Get the shelf stocked.")
	return lines


static func _line_seconds(line: String) -> float:
	return clampf(1.6 + 0.045 * line.length(), 2.6, 6.0)


func lobby_message() -> String:
	if game.dev_mode:
		return ""
	return "Shift %d. Walk in and hold E at the time clock when everyone is ready." % int(game.shift)


func clock_in_message() -> String:
	return "Clocked in. %d seconds to look around before the phone rings." % int(GRACE_SECONDS)


## The one-line objective the HUD shows, or "".
func objective_text() -> String:
	match game.phase:
		game.Phase.LOBBY:
			return "SHIFT %d. WALK IN AND HOLD E AT THE TIME CLOCK TO CLOCK IN." % int(game.shift)
		game.Phase.SHIFT:
			pass
		_:
			return ""
	if call_state == "ringing":
		if call_kind == "extra":
			return "THE PHONE IS RINGING: ANSWER TO TAKE AN EXTRA PATIENT (%d S)." % maxi(0, ceili(EXTRA_DECLINE_SECONDS - call_t))
		return "THE PHONE IS RINGING IN THE BREAK ROOM. ANSWER IT."
	if not game.dev_mode and not first_called and grace_left > 0.0:
		return "GRACE PERIOD: LOOK AROUND. THE PHONE RINGS IN %d S." % ceili(grace_left)
	var missing := missing_supplies()
	if not missing.is_empty():
		return "BRING TO THE OR SHELF: " + ", ".join(missing)
	for c in game.cases:
		if String(c.get("patient_id", "")) == "player" or String(c.state) != "on_table":
			continue
		var step := Procedures.step(String(c.ailment_id), int(c.step_index))
		var sys: Node = game.surgery_for_table(int(c.table))
		if step.is_empty() or sys == null:
			continue
		if sys.is_local_operating():
			return ""
		if int(sys.operator_id) != 0:
			continue
		var pname: String = String(Procedures.patient(String(c.patient_id)).get("name", "the patient")).to_upper()
		return "OPERATE ON %s: %s. AIM AT THE TABLE AND PRESS E." % [pname, String(step.label).to_upper()]
	for c in game.cases:
		if String(c.get("state", "")) == "on_table" and String(c.get("patient_id", "")) != "player":
			var sys: Node = game.surgery_for_table(int(c.table))
			if sys != null and int(sys.operator_id) != 0:
				var op = game.players.get(int(sys.operator_id))
				var step := Procedures.step(String(c.ailment_id), int(c.step_index))
				return "%s IS OPERATING: %s." % [(op.player_name if op != null else "SOMEONE").to_upper(), String(step.get("label", "")).to_upper()]
	if not crews.is_empty() or _any_incoming():
		return "A PATIENT IS ON THE WAY. THE PARAMEDICS BRING THEM TO THE OR."
	if can_clock_out():
		return "EVERY PATIENT IS STABLE OR GONE. HOLD E AT THE TIME CLOCK TO CLOCK OUT."
	return ""


func _any_incoming() -> bool:
	for c in game.cases:
		if String(c.get("state", "")) == "incoming":
			return true
	return false


## Items every live case still needs that are not on the shelf yet, as "Anesthetic x1" labels.
func missing_supplies() -> Array:
	var need: Dictionary = game._live_requirements()
	var out := []
	for kind in Items.SURGICAL:
		if not need.has(kind):
			continue
		var short: int = int(need[kind]) - int(game.shelf_count(kind))
		if short <= 0:
			continue
		out.append(Items.display_name(kind) + (" x%d" % short if Items.is_consumable(kind) else ""))
	return out


# =========================================================================
# where things are
# =========================================================================

## Where the paramedics come from and go back to: level_info.ambulance, else the entrance, else
## the spawn point farthest from the first table.
func arrival_point() -> Vector3:
	var info: Dictionary = game.level_info
	for key in ["ambulance", "entrance"]:
		var d = info.get(key)
		if d is Dictionary and d.has("position"):
			return d.position
	var table: Vector3 = game.table_pos()
	var best := table + Vector3(6, 0, 0)
	var best_d := -1.0
	for key in ["tool_spawns", "player_spawns", "monster_spawns"]:
		for p in info.get(key, []):
			var dd: float = (p as Vector3).distance_to(table)
			if dd > best_d:
				best_d = dd
				best = p
		if best_d > 0.0:
			break
	return best


## A standing spot beside a table, on the side facing where the crew comes from.
func _stand_spot(table: int, from: Vector3) -> Vector3:
	var pos: Vector3 = game.table_position(table)
	var side := Basis(Vector3.UP, float(game.table_yaw_of(table))) * Vector3(0, 0, 1)
	var sgn := 1.0 if (from - pos).dot(side) >= 0.0 else -1.0
	var cands := [pos + side * 1.5 * sgn, pos - side * 1.5 * sgn, pos + Basis(Vector3.UP, float(game.table_yaw_of(table))) * Vector3(2.0, 0, 0)]
	var map: RID = game.get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		for cnd in cands:
			var on_nav := NavigationServer3D.map_get_closest_point(map, cnd)
			if Vector2(on_nav.x - cnd.x, on_nav.z - cnd.z).length() < 0.7:
				return on_nav
	return cands[0]


func _nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var map: RID = game.get_world_3d().navigation_map
	var pts := PackedVector3Array()
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		var a := NavigationServer3D.map_get_closest_point(map, from)
		var b := NavigationServer3D.map_get_closest_point(map, to)
		pts = NavigationServer3D.map_get_path(map, a, b, true)
	if pts.size() < 2:
		pts = PackedVector3Array([from, to])
	return pts


## Keep only the last `max_len` metres of a path.
static func _trim_path(pts: PackedVector3Array, max_len: float) -> PackedVector3Array:
	var total := 0.0
	var i := pts.size() - 1
	while i > 0:
		var seg := pts[i].distance_to(pts[i - 1])
		if total + seg > max_len:
			var start := pts[i].lerp(pts[i - 1], (max_len - total) / maxf(seg, 1e-4))
			var out := PackedVector3Array([start])
			out.append_array(pts.slice(i))
			return out
		total += seg
		i -= 1
	return pts


## Keep only the first `max_len` metres of a path.
static func _trim_path_front(pts: PackedVector3Array, max_len: float) -> PackedVector3Array:
	var rev := pts.duplicate()
	rev.reverse()
	var t := _trim_path(rev, max_len)
	t.reverse()
	return t


## With a real ambulance bay the crew walks the whole way; fallback start points can be deep in
## the hospital, so those walks start part of the way in.
func _max_walk() -> float:
	return 250.0 if game.level_info.has("ambulance") else MAX_WALK


static func _yaw_along(a: Vector3, b: Vector3) -> float:
	var d := b - a
	if Vector2(d.x, d.z).length() < 0.01:
		return 0.0
	return atan2(-d.x, -d.z)


## The phone: level_info.phone, else a free floor spot beside the time clock.
func _phone_spot(info: Dictionary) -> Dictionary:
	var given = info.get("phone")
	if given is Dictionary and given.has("position"):
		# The hospital builds a wall phone there (position at its centre): add to it, no desk phone.
		return {"position": given.position, "yaw": float(given.get("yaw", 0.0)), "wall": (given.position as Vector3).y > 0.5}
	if not info.has("clock"):
		return {}
	var clock: Vector3 = info.clock
	var rows: PackedStringArray = info.get("rows", PackedStringArray())
	var avoid: Array = []
	for key in ["pod", "table"]:
		if info.has(key):
			avoid.append(info[key])
	var lectern: Dictionary = info.get("lectern", {})
	if lectern.has("position"):
		avoid.append(lectern.position)
	var offsets := [Vector3(-1.5, 0, 0), Vector3(1.5, 0, 0), Vector3(-2.2, 0, 0), Vector3(2.2, 0, 0),
		Vector3(0, 0, 1.5), Vector3(0, 0, -1.5), Vector3(-1.5, 0, 1.2), Vector3(1.5, 0, 1.2)]
	for off in offsets:
		var p: Vector3 = clock + off
		if not rows.is_empty() and not _floor_free(rows, p, 0.45):
			continue
		var ok := true
		for a in avoid:
			if Vector2(a.x - p.x, a.z - p.z).length() < 1.3:
				ok = false
		if not ok:
			continue
		return {"position": p, "yaw": _facing_away_from_wall(rows, p)}
	return {"position": clock + Vector3(1.5, 0, 0), "yaw": 0.0}


static func _floor_free(rows: PackedStringArray, p: Vector3, r: float) -> bool:
	for dx in [-r, 0.0, r]:
		for dz in [-r, 0.0, r]:
			var t := C.world_to_tile(p + Vector3(dx, 0, dz))
			if t.y < 0 or t.y >= rows.size() or t.x < 0 or t.x >= rows[t.y].length():
				return false
			var ch := rows[t.y][t.x]
			if ch != "." and ch != "P":
				return false
	return true


static func _facing_away_from_wall(rows: PackedStringArray, p: Vector3) -> float:
	if rows.is_empty():
		return 0.0
	var t := C.world_to_tile(p)
	var best := 0.0
	var best_d := 99
	for dir in [[Vector2i(0, -1), PI], [Vector2i(0, 1), 0.0], [Vector2i(-1, 0), -PI / 2.0], [Vector2i(1, 0), PI / 2.0]]:
		for k in range(1, 4):
			var q: Vector2i = t + dir[0] * k
			if q.y < 0 or q.y >= rows.size() or q.x < 0 or q.x >= rows[q.y].length() or rows[q.y][q.x] == "#":
				if k < best_d:
					best_d = k
					best = dir[1]
				break
	return best


# =========================================================================
# replication and local presentation
# =========================================================================

func net_state() -> Dictionary:
	var cr := {}
	for id in crews.keys():
		var c: Dictionary = crews[id]
		cr[id] = [(c.p as Vector3).snappedf(0.02), snappedf(float(c.y), 1.0 / 64.0), String(c.ph), String(c.pt), String(c.ai), int(c.tb)]
	return {
		"gr": ceili(grace_left), "ck": call_kind, "cs": call_state, "ct": floori(call_t), "sub": subtitle,
		"fc": first_called, "cr": cr, "pay": pay_note,
	}


func apply_net_state(s: Dictionary) -> void:
	if game.is_host():
		return
	grace_left = float(s.get("gr", 0))
	call_kind = String(s.get("ck", ""))
	call_state = String(s.get("cs", ""))
	call_t = float(s.get("ct", 0))
	subtitle = String(s.get("sub", ""))
	first_called = bool(s.get("fc", false))
	pay_note = String(s.get("pay", ""))
	crews.clear()
	var cr: Dictionary = s.get("cr", {})
	for id in cr.keys():
		var a: Array = cr[id]
		if a.size() >= 6:
			crews[int(id)] = {"p": a[0], "y": float(a[1]), "ph": String(a[2]), "pt": String(a[3]), "ai": String(a[4]), "tb": int(a[5])}


func on_event(_data: Dictionary) -> void:
	pass


func _local_tick(delta: float) -> void:
	var ringing: bool = call_state == "ringing" and game.phase == game.Phase.SHIFT
	var at = phone.global_position + Vector3.UP * 0.9 if phone != null and is_instance_valid(phone) else null
	if ringing:
		_ring_timer -= delta
		if _ring_timer <= 0.0:
			_ring_timer = RING_EVERY
			Audio.play("loop_ring", at, 0.0)
	else:
		_ring_timer = 0.0
	if phone != null and is_instance_valid(phone):
		phone.set_ringing(ringing)
	if call_state != _last_call_state:
		if _last_call_state == "ringing" and call_state == "talking":
			Audio.play("loop_pickup", at)
		elif _last_call_state == "talking" and call_state == "":
			Audio.play("loop_hangup", at)
		_last_call_state = call_state
	_sync_crew_nodes()
	_rattle_timer -= delta
	var rattle := _rattle_timer <= 0.0
	if rattle:
		_rattle_timer = 1.15
	for id in _crew_nodes.keys():
		var n: Node3D = _crew_nodes[id]
		var c: Dictionary = crews[id]
		n.set_target(c.p, float(c.y), String(c.ph))
		if rattle and n.is_moving():
			Audio.play("loop_gurney", n.global_position + Vector3.UP * 0.6, -6.0, 0.06)


func _sync_crew_nodes() -> void:
	if game == null:
		return
	for id in _crew_nodes.keys():
		if not crews.has(id):
			var n = _crew_nodes[id]
			if is_instance_valid(n):
				n.queue_free()
			_crew_nodes.erase(id)
	var parent: Node = game.get_node_or_null("Entities")
	if parent == null or game.phase == game.Phase.MENU:
		return
	for id in crews.keys():
		if _crew_nodes.has(id):
			continue
		var c: Dictionary = crews[id]
		var n: Node3D = CrewScript.create(String(c.pt), String(c.ai))
		n.name = "ParamedicCrew_%d" % int(id)
		parent.add_child(n)
		n.snap(c.p, float(c.y))
		_crew_nodes[id] = n
