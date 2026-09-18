extends Node
## The operation on the OR's player table: a downed teammate, the `stitches` ailment, one step --
## and, GRAFTING chunk C, Eyeball Grafting on a surgeon who strapped themselves to the same table
## (`eye_graft`, four steps, no botches; scripts/grafting/grafts.gd owns its rules and its result).
## Child "PlayerSurgery" of Game on every machine (so its RPCs line up), created in game._ready.
##
## Self-contained on purpose (docs/SWEEP2.md, "Faster schedule"): until `game.add_case` exists this
## runs its own copy of scripts/surgery/surgery_system.gd and stands in for the game towards it,
## exposing the same surface the surgery system reads from the game (case, patient_body, players,
## shelf_count, surgery_botch, surgery_step_done, send_operator_report, table_pos, ...), but for
## the player table. The integration wave rewires game.start_player_surgery() onto game.cases.
##
## Vitals for this case are the patient's bleed clock (100 = a full five minutes left); a botch
## costs BOTCH_BLEED_SECONDS of it per vitals point.

const SurgeryScript := preload("res://scripts/surgery/surgery_system.gd")
const PlayerBodyScript := preload("res://scripts/downed/player_body.gd")

const BOTCH_BLEED_SECONDS := 4.0
## Seconds between the last stitch and the patient getting up.
const REVIVE_DELAY := 1.2

var game: Node = null
var surgery: Node = null
## {patient_id: "player", player_id, ailment_id: "stitches", step_index, flags}; {} when the table is empty.
var case: Dictionary = {}
var patient_body: Node3D = null

var _case_key := ""
var _flags_key := ""
var _say_timer := 0.0
var _revive_in := 0.0

# ---- what the surgery system reads from its "game" ----
var players: Dictionary:
	get: return game.players if game != null else {}
var world_time: float:
	get: return float(game.world_time) if game != null else 0.0
var shift: int:
	get: return int(game.shift) if game != null else 1
var seed_value: int:
	get: return int(game.seed_value) + 7331 if game != null else 0
var phase: int:
	get: return int(game.phase) if game != null else 0
var vitals: float:
	get: return _vitals()


func setup(g: Node) -> void:
	game = g
	surgery = SurgeryScript.new()
	surgery.name = "Surgery"
	add_child(surgery)
	surgery.setup(self)


func is_host() -> bool:
	return game.is_host()


func local_player() -> Node:
	return game.local_player()


func viewed_player() -> Node:
	return game.viewed_player()


## GRAFT HOOK: the body this machine drives (your own, or a possessed Dr. Botsworth).
func driving_player() -> Node:
	return game.driving_player()


func driving_id() -> int:
	return int(game.driving_id())


func shelf_count(kind: String) -> int:
	return game.shelf_count(kind)


func emit_noise(pos: Vector3, loudness: float, kind: String) -> void:
	game.emit_noise(pos, loudness, kind)


func table_pos() -> Vector3:
	return game.player_table_top()


## The player on the table, or null.
func patient() -> Node:
	if case.is_empty():
		return null
	var p = game.players.get(int(case.get("player_id", 0)))
	return p if p != null and is_instance_valid(p) else null


func is_graft() -> bool:
	return String(case.get("ailment_id", "")) == "eye_graft"


func _vitals() -> float:
	var p := patient()
	if p == null or is_graft():
		return 100.0   # GRAFTING chunk C: a graft has nothing to lose, so the monitor stays calm
	return clampf(float(p.bleed) / float(game.BLEED_SECONDS) * 100.0, 0.0, 100.0)


## GRAFTING chunk C: why a strapped surgeon cannot get off the table right now ("" when they can).
## They are free to leave until the scoop; after it the socket is open and they are committed.
func graft_commit_block(p: Node) -> String:
	if p == null or not is_graft() or int(case.get("player_id", 0)) != int(p.peer_id):
		return ""
	if int(case.get("step_index", 0)) < 2:
		return ""
	return "Not with your eye out."


# =========================================================================
# the case (host starts and ends it; every machine applies it)
# =========================================================================

## Host: `p` lies on the player table; the stitches step can begin. `table`: which patient table
## they lie on, on levels where downed players use any free one (the hub), else -1.
func start(p: Node, table := -1) -> void:
	if not is_host() or p == null:
		return
	_revive_in = 0.0
	case = {"patient_id": "player", "player_id": p.peer_id, "ailment_id": "stitches", "step_index": 0,
		"flags": {"sedation": 1.0}, "table": table}
	apply_locally()


## GRAFTING chunk C, host: `q` began Eyeball Grafting on the strapped surgeon lying on the table.
func start_graft(q: Node) -> void:
	if not is_host() or not case.is_empty():
		return
	var c: Dictionary = game.grafts.make_case(q)
	if c.is_empty():
		return
	_revive_in = 0.0
	case = c
	apply_locally()


## Host: the table is empty again (revived, dead, or gone).
func clear() -> void:
	_revive_in = 0.0
	if case.is_empty():
		return
	case = {}
	apply_locally()


## Every machine, idempotent: the body on the table and the surgery system follow `case`.
func apply_locally() -> void:
	var key := "" if case.is_empty() else "%d|%s|%d" % [int(case.get("player_id", 0)), String(case.get("ailment_id", "")), int(case.get("table", -1))]
	if key != _case_key:
		_case_key = key
		_flags_key = ""
		game.set_downed_table(int(case.get("table", -1)) if not case.is_empty() else -1)
		if patient_body != null and is_instance_valid(patient_body):
			patient_body.queue_free()
		patient_body = null
		if key == "":
			surgery.clear_case()
			_refresh_stand_in()
			return
		var p := patient()
		patient_body = PlayerBodyScript.create(int(case.player_id), p.colour if p != null else Color("3d8f80"))
		game.get_node("Entities").add_child(patient_body)
		patient_body.global_position = game.player_table_top()
		patient_body.rotation.y = game.player_table_yaw()
		patient_body.set_ailment(String(case.ailment_id))
		surgery.start_case("player", String(case.ailment_id))
	_refresh_stand_in()
	var fk := str(case.get("flags", {})) + str(case.get("step_index", 0))
	if fk != _flags_key and patient_body != null:
		_flags_key = fk
		patient_body.apply_flags(case.get("flags", {}))
	# GRAFTING chunk C: what is in the socket follows the step. The old eye is there until the
	# scoop takes it out, the socket is empty until the seat puts the new one in, and from then on
	# the new one sits there (stitched in by the last step).
	if is_graft() and patient_body != null and patient_body.has_method("set_eye"):
		var si := int(case.get("step_index", 0))
		var out_kind := String(case.get("out_kind", "eye_surgeon"))
		var in_kind := String(case.get("in_kind", ""))
		if si < 2:
			patient_body.set_eye("" if out_kind != "eye_hive" else "eye_hive", false)
		elif si == 2:
			patient_body.set_eye("", true)
		else:
			patient_body.set_eye("" if in_kind != "eye_hive" else "eye_hive", false)


## Every machine: the player on the table has a lying stand-in body, so their own must not draw.
func _refresh_stand_in() -> void:
	for p in game.players.values():
		var want: bool = not case.is_empty() and int(p.peer_id) == int(case.get("player_id", 0)) and patient_body != null
		p.set_stand_in(want)


# =========================================================================
# the game surface the surgery system calls
# =========================================================================

func surgery_botch(amount: float, reason: String) -> void:
	if not is_host():
		return
	var p := patient()
	if p != null:
		p.bleed = maxf(1.0, float(p.bleed) - amount * BOTCH_BLEED_SECONDS)
	if reason != "" and _say_timer <= 0.0:
		_say_timer = 2.0
		game.say(reason, 1.8)


func surgery_step_done(result: Dictionary, operator_peer: int = 0) -> void:
	if not is_host() or case.is_empty():
		return
	var step := Procedures.step(String(case.ailment_id), int(case.step_index))
	if step.is_empty():
		return
	var uses := int(step.get("uses", 0))
	if uses > 0 and operator_peer != 0:
		# 2026-09-18: from the operator's hands (the supply shelf is gone).
		var p = game.players.get(operator_peer)
		if p != null and p.has_method("consume_hand"):
			p.consume_hand(String(step.item), uses)
	var flags: Dictionary = case.get("flags", {})
	flags.merge(result, true)
	case.flags = flags
	case.step_index = int(case.step_index) + 1
	apply_locally()
	game._sound("step_done", table_pos())
	game.grafts.on_step(case, result)   # GRAFTING chunk C: the scoop drops the old eye in the vat
	var next := Procedures.step(String(case.ailment_id), int(case.step_index))
	if next.is_empty():
		if is_graft():
			# GRAFTING chunk C: nobody is revived; the surgeon simply gets their new eye and is
			# free to hold E and get up again.
			game.grafts.finish(case)
			clear()
			return
		# A moment to see the closed wound before they sit up and climb off the table.
		_revive_in = REVIVE_DELAY


func send_operator_report(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(driving_id(), report)   # GRAFT HOOK: Dr. Botsworth's, when driven
	elif Net.active:
		if report.has("botches") or report.has("finished") or report.has("exit") or report.has("reliable"):
			_rpc_report_reliable.rpc_id(Net.HOST_ID, report)
		else:
			_rpc_report.rpc_id(Net.HOST_ID, report)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_report(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(multiplayer.get_remote_sender_id(), report)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_report_reliable(report: Dictionary) -> void:
	if is_host():
		surgery.receive_operator_report(multiplayer.get_remote_sender_id(), report)


# =========================================================================
# frame, prompts, replication
# =========================================================================

func physics_tick(delta: float) -> void:
	_say_timer = maxf(0.0, _say_timer - delta)
	if is_host() and not case.is_empty():
		var p := patient()
		if p == null or not p.alive or not p.on_table:
			clear()
		elif is_graft():
			pass   # GRAFTING chunk C: nothing to bleed out, and nobody to revive
		elif _revive_in > 0.0:
			_revive_in -= delta
			if _revive_in <= 0.0:
				game.revive_player(p, "stitches")
				clear()
	surgery.physics_tick(delta)
	if patient_body != null and is_instance_valid(patient_body):
		patient_body.set_vitals(_vitals())


## The prompt for someone aiming at the player table while nobody is being carried.
func operate_prompt(q: Node) -> String:
	var p := patient()
	if p == null:
		return game.grafts.table_prompt(q)   # GRAFTING chunk C: a strapped surgeon and a loaded vat
	if q == p:
		return ""
	if is_graft():
		var step_g := Procedures.step(String(case.ailment_id), int(case.step_index))
		if step_g.is_empty():
			return ""
		var why_g: String = surgery.can_begin(q)
		return "!" + why_g if why_g != "" else "Operate: %s" % step_g.label
	var step := Procedures.step(String(case.get("ailment_id", "")), int(case.get("step_index", 0)))
	if step.is_empty():
		return ""
	var why: String = surgery.can_begin(q)
	if why != "":
		return "!" + why
	return "Operate: stitch up %s" % p.player_name


func begin(q: Node) -> void:
	if not operate_prompt(q).begins_with("Operate"):
		return
	if case.is_empty():
		start_graft(q)   # GRAFTING chunk C: the case starts with the first step someone begins
	surgery.begin(q)


func end(q: Node) -> void:
	surgery.end(q)


func operator_peer() -> int:
	return surgery.operator_peer()


func net_state() -> Dictionary:
	return {"c": case.duplicate(true), "s": surgery.net_state().duplicate(true)}


func apply_net_state(s: Dictionary) -> void:
	if is_host():
		return
	var c = s.get("c", {})
	case = (c as Dictionary).duplicate(true) if c is Dictionary else {}
	apply_locally()
	var ss = s.get("s", {})
	if ss is Dictionary:
		surgery.apply_net_state(ss)


func reset() -> void:
	_revive_in = 0.0
	case = {}
	apply_locally()


## GRAFTING chunk C: test seam -- the graft case on the table right now ({} when there is none).
func graft_case() -> Dictionary:
	return case if is_graft() else {}
