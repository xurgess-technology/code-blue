extends Node
## The in-world surgery framework. One per patient table (loop, sweep 2): `table_index` is the
## table (index into level_info.tables) whose case it operates on, through
## game.case_on_table(table_index). The contract is in docs/CONTRACTS.md ("Surgery") and
## scripts/surgery/minigame.gd.
##
## Flow
##   Every machine builds the current step's minigame on the patient as soon as the step
##   becomes active (from game.case), ticks it, and draws it.
##   The host decides who operates (can_begin / begin / end). The operator's machine feeds
##   the mouse (or bot_input) into handle_cursor and is the authority for that step's
##   progress; it reports to the host through game.send_operator_report:
##     {"k": step_key, "ms": minigame.net_state()}                 ~20 Hz, unreliable
##     {"k": step_key, "botches": [[amount, reason], ...]}         immediately, reliable
##     {"k": step_key, "finished": result, "ms": {...}}            immediately, reliable
##     {"k": step_key, "stir": strength, "reliable": true}         the patient jerked
##     {"k": step_key, "ms": {...}, "exit": true}                  operator stepped away
##   Every report also carries "tb": table_index, so the host routes it to this table's system.
##   The host applies botches and completion to the game, keeps the latest minigame state
##   and relays it in net_state() {"op", "k", "ms", "sc", "ss"}; spectators apply "ms" to
##   their own copy of the minigame so they see the tool move. Progress lives in "ms", so
##   whoever operates next resumes exactly where the last operator stopped.
##   Solo is the host operating: send_operator_report calls receive_operator_report directly.

const MinigameBase := preload("res://scripts/surgery/minigame.gd")
const HudScript := preload("res://scripts/surgery/surgery_hud.gd")

const TWEEN_TIME := 0.6
const REPORT_INTERVAL := 0.05
const WALK_AWAY_M := 3.0
const NOISE_EVERY := 0.8
const REBEGIN_COOLDOWN := 0.4
const STIR_JOLT_TIME := 0.35
const STIR_SHAKE_M := 0.09

## Automated playtests: >= 0 makes the LOCAL operator play with the minigame's bot_input.
## loop: shared by every table's system (stored on the game as `surgery_bot_skill`).
var bot_skill: float:
	get:
		return float(game.get("surgery_bot_skill")) if game != null and game.get("surgery_bot_skill") != null else _own_bot_skill
	set(value):
		if game != null and game.get("surgery_bot_skill") != null:
			game.set("surgery_bot_skill", value)
		else:
			_own_bot_skill = value
var _own_bot_skill: float = -1.0

var game: Node = null
## loop: the table this system operates at (index into level_info.tables); -1 when unused.
var table_index: int = 0

# ---- replicated (host authoritative) ----
var operator_id: int = 0
var _mg_state: Dictionary = {}
var _mg_state_key := ""
var _stir_count := 0
var _stir_strength := 0.0

# ---- local ----
var mg: Node3D = null
var mg_key := ""
var _mg_t := 0.0
var _mg_step: Dictionary = {}
var _missing_warned := {}

var _local_op := false
var _exit_requested := false
var _op_time := 0.0
var _report_accum := 0.0
var _cursor := Vector2.ZERO
var _seen_stirs := 0

var _cam: Camera3D
var _lamp: SpotLight3D
var _cam_blend := 0.0
var _cam_dir := 0
var _head_fov := 75.0
var _last_pose := Transform3D()
var _last_pose_fov := 55.0

var _stir_rng := RandomNumberGenerator.new()
var _stir_timer := 0.0
var _stir_jolt := 0.0
var _stir_dir := Vector2.RIGHT
var _stir_amp := 0.0
var _stir_flash := 0.0

# ---- host ----
var _last_operator := 0
var _finished_keys := {}
var _exit_times := {}
var _noise_timer := 0.0
var _beep_timer := 0.0

var hud: CanvasLayer = null


func setup(g: Node) -> void:
	game = g
	_cam = Camera3D.new()
	_cam.name = "SurgeryCamera"
	_cam.near = 0.02
	_cam.far = 60.0
	_cam.current = false
	add_child(_cam)
	_lamp = make_work_lamp()
	_lamp.light_energy = 0.0
	_lamp.visible = false
	_cam.add_child(_lamp)
	hud = HudScript.new()
	hud.name = "SurgeryHud"
	add_child(hud)
	hud.system = self


## The surgical work lamp riding on the operator's camera: the OR is dark, the site must not be.
## ORSCREEN: tuned so close-up skin keeps its colour and the minigames' green / amber / red cues
## still read (it used to be energy 2.2 with a shallow falloff, which bleached skin nearly white
## at the 0.4-0.6 m the operating camera sits from the site). tools/minigame_lab.gd --look=or
## builds the same lamp through this function.
const LAMP_ENERGY := 0.5
const LAMP_COLOR := Color(1.0, 0.98, 0.95)
const LAMP_RANGE := 2.5
const LAMP_ANGLE := 40.0
const LAMP_ATTENUATION := 1.0


static func make_work_lamp() -> SpotLight3D:
	var lamp := SpotLight3D.new()
	lamp.name = "WorkLamp"
	lamp.light_color = LAMP_COLOR
	lamp.light_energy = LAMP_ENERGY
	lamp.spot_range = LAMP_RANGE
	lamp.spot_angle = LAMP_ANGLE
	lamp.spot_attenuation = LAMP_ATTENUATION
	lamp.shadow_enabled = false
	lamp.light_volumetric_fog_energy = 0.0
	lamp.light_specular = 0.3
	return lamp


func start_case(_patient_id: String, _ailment_id: String) -> void:
	_reset()


func clear_case() -> void:
	_reset()


func _reset() -> void:
	if _local_op:
		_stop_local_operating(false)
	_free_mg()
	operator_id = 0
	_last_operator = 0
	_mg_state = {}
	_mg_state_key = ""
	_stir_count = 0
	_seen_stirs = 0
	_finished_keys.clear()
	_exit_requested = false


# =============================================================================== host API

func can_begin(player) -> String:
	if game == null or _case().is_empty():
		return "Nobody is on the table."
	var s := _step()
	if s.is_empty():
		return "Nothing left to do."
	if operator_id != 0 and operator_id == player.peer_id:
		return "You are already operating."
	if operator_id != 0:
		var p = game.players.get(operator_id)
		return "%s is already operating." % (p.player_name if p != null else "Someone")
	# loop: one table at a time.
	if "surgeries" in game:
		for other in game.surgeries:
			if other != self and int(other.operator_id) == int(player.peer_id):
				return "You are operating at the other table."
	# 2026-09-18: the step's item has to be in your hands, selected (and enough of it).
	var needed: int = maxi(1, int(s.get("uses", 0)))
	var held: Dictionary = player.selected_stack() if player.has_method("selected_stack") else {}
	if String(held.get("kind", "")) != String(s.item) or int(held.get("count", 0)) < needed:
		if needed > 1:
			return "Hold %d %s to do this." % [needed, Items.display_name(String(s.item))]
		return "Hold %s to do this." % Items.display_name(String(s.item))
	var last: float = float(_exit_times.get(player.peer_id, -99.0))
	if float(game.world_time) - last < REBEGIN_COOLDOWN:
		return "Stepping back from the table."
	if not ResourceLoader.exists(String(Procedures.MINIGAME_SCRIPTS.get(String(s.game), ""))):
		return "This step is not ready yet."
	return ""


func begin(player) -> void:
	if can_begin(player) != "":
		return
	operator_id = player.peer_id
	_last_operator = operator_id


func end(player) -> void:
	if player == null:
		return
	if operator_id != 0 and player.peer_id == operator_id:
		_end_operation()


func operator_peer() -> int:
	return operator_id


## loop: the case finished (stable or dead) while someone operated: they step back.
func end_current() -> void:
	if operator_id != 0:
		_end_operation()


## The case on this system's table while it can be operated on ({} otherwise). Live dictionary.
func _case() -> Dictionary:
	if game == null:
		return {}
	if game.has_method("case_on_table"):
		var c: Dictionary = game.case_on_table(table_index)
		if c.is_empty() or String(c.get("state", "on_table")) != "on_table" or String(c.get("patient_id", "")) == "player":
			return {}
		return c
	return game.get("case") if game.get("case") is Dictionary else {}


## This table's patient's vitals (a stand-in game without cases: its own `vitals`).
func _case_vitals() -> float:
	var c := _case()
	if c.has("vitals"):
		return float(c.vitals)
	return float(game.get("vitals")) if game != null and game.get("vitals") != null else 100.0


## The game's per-table callbacks; a stand-in "game" without cases (scripts/downed/player_surgery.gd)
## keeps the old one-table signatures.
func _game_botch(amount: float, reason: String) -> void:
	if game.has_method("case_on_table"):
		game.surgery_botch(amount, reason, table_index)
	else:
		game.surgery_botch(amount, reason)


## `operator_peer`: whoever's report finished the step, so its supply can be drawn from their
## hands when the shelf alone falls short (see game.surgery_step_done).
func _game_step_done(result: Dictionary, operator_peer: int = 0) -> void:
	if game.has_method("case_on_table"):
		game.surgery_step_done(result, table_index, operator_peer)
	else:
		game.surgery_step_done(result, operator_peer)


func _body():
	if game == null:
		return null
	var b = game.body_for_table(table_index) if game.has_method("body_for_table") else game.get("patient_body")
	return b if b != null and is_instance_valid(b) else null


func _end_operation() -> void:
	if operator_id != 0:
		_exit_times[operator_id] = float(game.world_time)
	operator_id = 0


func receive_operator_report(peer_id: int, report: Dictionary) -> void:
	if game == null or not game.is_host():
		return
	var key := String(report.get("k", ""))
	var valid := key != "" and key == mg_key and (peer_id == operator_id or peer_id == _last_operator)
	if valid:
		var ms = report.get("ms")
		if ms is Dictionary and not _finished_keys.has(key):
			_mg_state = ms
			_mg_state_key = key
			if mg != null and not _local_op:
				mg.apply_net_state(ms)
		for b in report.get("botches", []):
			if b is Array and b.size() >= 2:
				_game_botch(float(b[0]), String(b[1]))
		if report.has("stir"):
			_stir_count += 1
			_stir_strength = float(report.stir)
			if peer_id != Net.my_id():
				_body_stir(_stir_strength)
			_seen_stirs = _stir_count
		if report.has("finished") and not _finished_keys.has(key):
			_finished_keys[key] = true
			var result = report.get("finished")
			operator_id = 0
			_last_operator = 0
			_game_step_done(result if result is Dictionary else {}, peer_id)
	if report.has("exit") and peer_id == operator_id:
		_end_operation()


# =============================================================================== replication

func net_state() -> Dictionary:
	return {"op": operator_id, "k": _mg_state_key, "ms": _mg_state, "sc": _stir_count, "ss": snappedf(_stir_strength, 0.01)}


func apply_net_state(s: Dictionary) -> void:
	if game == null or game.is_host():
		return
	operator_id = int(s.get("op", 0))
	var key := String(s.get("k", ""))
	var ms = s.get("ms", {})
	if ms is Dictionary:
		_mg_state = ms
		_mg_state_key = key
		if mg != null and key == mg_key and not _local_op and not ms.is_empty():
			mg.apply_net_state(ms)
	_stir_count = int(s.get("sc", 0))
	_stir_strength = float(s.get("ss", 0.0))
	if _stir_count != _seen_stirs:
		if _stir_count > _seen_stirs and not _local_op:
			_body_stir(_stir_strength)
		_seen_stirs = _stir_count


# =============================================================================== frame

func physics_tick(delta: float) -> void:
	if game == null:
		return
	_sync_minigame()
	if game.is_host():
		_host_tick(delta)

	var me := Net.my_id()
	var should_op: bool = operator_id != 0 and operator_id == me and mg != null and not mg.done and not _exit_requested
	if should_op and not _local_op:
		_start_local_operating()
	elif not should_op and _local_op:
		_stop_local_operating(mg != null and not mg.done)
	if _exit_requested and operator_id != me:
		_exit_requested = false

	if mg != null:
		_place_mg()
		if _local_op:
			_drive(delta)
		elif game.is_host():
			_drive_bot_operator(delta)
		if mg != null:
			mg.tick(delta)
		_mg_t += delta
	_update_camera(delta)
	_monitor(delta)
	_stir_flash = maxf(0.0, _stir_flash - delta)


func _host_tick(delta: float) -> void:
	if operator_id == 0:
		_noise_timer = 0.0
		return
	var p = game.players.get(operator_id)
	var table := _table_pos()
	var gone: bool = p == null or not is_instance_valid(p) or not bool(p.get("alive"))
	if not gone:
		var flat: Vector3 = p.global_position - table
		flat.y = 0.0
		gone = flat.length() > WALK_AWAY_M
	if gone or mg == null:
		_end_operation()
		return
	_noise_timer -= delta
	if _noise_timer <= 0.0:
		_noise_timer = NOISE_EVERY
		game.emit_noise(table, 0.6, "monitor")


## The monitor beeps on every machine while someone operates; faster and harsher as vitals fall.
func _monitor(delta: float) -> void:
	if operator_id == 0:
		_beep_timer = 0.0
		return
	_beep_timer -= delta
	if _beep_timer > 0.0:
		return
	var v: float = clampf(_case_vitals(), 0.0, 100.0)
	_beep_timer = lerpf(0.38, 0.85, v / 100.0)
	var cue := "surgery_beep" if v > 50.0 else ("surgery_beep_low" if v > 25.0 else "surgery_beep_crit")
	_audio(cue, _table_pos(), -5.0)


# =============================================================================== minigame lifecycle

func _step() -> Dictionary:
	var c := _case()
	if c.is_empty():
		return {}
	return Procedures.step(String(c.get("ailment_id", "")), int(c.get("step_index", 0)))


func _current_key() -> String:
	var s := _step()
	if s.is_empty():
		return ""
	var c := _case()
	return "%d|%s|%s|%d" % [int(c.get("id", 0)), c.get("patient_id", ""), c.get("ailment_id", ""), int(c.get("step_index", 0))]


func _sync_minigame() -> void:
	var key := _current_key()
	if key == mg_key:
		return
	if _local_op:
		_stop_local_operating(false)
	_free_mg()
	mg_key = key
	if game.is_host():
		_mg_state = {}
		_mg_state_key = key
		# Completion already cleared the operator; someone who began the new step in the same
		# frame keeps it. Only a vanished case ends an operation here.
		_last_operator = operator_id
		if key == "" and operator_id != 0:
			_end_operation()
	if key == "":
		return
	_spawn_mg()


func _spawn_mg() -> void:
	var step := _step()
	var path := String(Procedures.MINIGAME_SCRIPTS.get(String(step.get("game", "")), ""))
	if path == "" or not ResourceLoader.exists(path):
		if not _missing_warned.has(path):
			_missing_warned[path] = true
			push_warning("Surgery: no minigame script for step '%s' at '%s'." % [step.get("id", "?"), path])
		return
	var script := load(path) as GDScript
	if script == null:
		return
	var inst = script.new()
	if not (inst is Node3D) or not inst.has_method("handle_cursor"):
		push_warning("Surgery: %s is not a Minigame." % path)
		if inst is Node:
			inst.free()
		return
	mg = inst
	_mg_step = step
	_mg_t = 0.0
	mg.name = "Minigame_%s" % String(step.get("id", "step"))
	add_child(mg)
	_place_mg()
	mg.botched.connect(_on_botched)
	mg.finished.connect(_on_finished)
	var c := _case()
	if not (c.get("flags") is Dictionary):
		c["flags"] = {}
	var body = _body()
	var shift := int(game.shift)
	mg.setup({
		"patient_id": String(c.get("patient_id", "")),
		"patient": Procedures.patient(String(c.get("patient_id", ""))),
		"ailment_id": String(c.get("ailment_id", "")),
		"step": step,
		"variant": String(step.get("variant", "")),
		"shift": shift,
		"difficulty": Procedures.difficulty(shift),
		"flags": c.flags,
		"seed": hash("%s|%d" % [mg_key, int(game.get("seed_value") if game.get("seed_value") != null else 0)]),
		"body": body,
		"operator": false,
		"helper_lights": _helper_lights,
	})
	if _mg_state_key == mg_key and not _mg_state.is_empty():
		mg.apply_net_state(_mg_state)


## Teammates' flashlights for the minigame (ctx.helper_lights): every living player's light that is
## on, except whoever is operating. Remote players' aim and flashlight are replicated, so every
## machine sees the same lights.
func _helper_lights() -> Array:
	var out: Array = []
	var players = game.get("players") if game != null else null
	if not (players is Dictionary):
		return out
	for p in (players as Dictionary).values():
		if p == null or not is_instance_valid(p) or not bool(p.get("alive")):
			continue
		if int(p.get("peer_id")) == operator_id or bool(p.get("operating")):
			continue
		var fl = p.get("flashlight")
		if fl is SpotLight3D and bool(p.get("flashlight_on")) and (fl as SpotLight3D).visible:
			out.append(fl)
	return out


func _free_mg() -> void:
	if mg != null and is_instance_valid(mg):
		mg.queue_free()
	mg = null
	mg_key = ""
	_mg_step = {}


func _site_transform() -> Transform3D:
	var site := String(_mg_step.get("site", ""))
	var body = _body()
	if body != null and is_instance_valid(body) and body.has_method("site_transform") \
			and (not body.has_method("has_site") or body.has_site(site)):
		var xf: Transform3D = body.site_transform(site)
		return xf.orthonormalized()
	return Transform3D(Basis(), _table_pos() + Vector3.UP * 1.2)


func _place_mg() -> void:
	if mg != null:
		mg.global_transform = _site_transform()


func _table_pos() -> Vector3:
	if game.has_method("table_position"):
		return game.table_position(table_index)
	if game.has_method("table_pos"):
		return game.table_pos()
	var body = _body()
	return body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO


# =============================================================================== the local operator

func _start_local_operating() -> void:
	_local_op = true
	_op_time = 0.0
	_report_accum = 0.0
	mg.ctx["operator"] = true
	var p = game.local_player()
	var head_cam: Camera3D = p.camera if p != null and "camera" in p and p.camera != null else null
	if head_cam != null:
		_head_fov = head_cam.fov
		if _cam_dir == 0 and _cam_blend <= 0.0:
			_cam.global_transform = head_cam.global_transform
	_cam_dir = 1
	_cursor = Vector2.ZERO
	_stir_rng.seed = int(mg.ctx.get("seed", 0)) + 7919 * (_stir_count + 1)
	_stir_timer = _stir_interval() * 0.5
	_stir_jolt = 0.0


func _stop_local_operating(send_state: bool) -> void:
	_local_op = false
	_cam_dir = -1
	if mg != null and is_instance_valid(mg):
		mg.ctx["operator"] = false
		if send_state:
			game.send_operator_report({"k": mg_key, "ms": mg.net_state(), "reliable": true, "tb": table_index})


func local_operator_exit() -> void:
	if not _local_op:
		return
	_exit_requested = true
	var report := {"k": mg_key, "exit": true, "tb": table_index}
	if mg != null and not mg.done:
		report["ms"] = mg.net_state()
	_local_op = false
	_cam_dir = -1
	if mg != null:
		mg.ctx["operator"] = false
	game.send_operator_report(report)


func _unhandled_input(event: InputEvent) -> void:
	if _local_op and _op_time > 0.35 and event.is_action_pressed("interact"):
		local_operator_exit()
		get_viewport().set_input_as_handled()


func _bot_driving() -> bool:
	return bot_skill >= 0.0


func _drive(delta: float) -> void:
	_op_time += delta
	var buttons := 0
	if _bot_driving():
		var inp: Dictionary = mg.bot_input(_mg_t, bot_skill)
		_cursor = inp.get("cursor", _cursor)
		buttons = int(inp.get("buttons", 0))
	elif _cam_blend > 0.7:
		var vp := get_viewport()
		var hit = MinigameBase.screen_to_plane(_cam, vp.get_mouse_position(), mg.global_transform)
		if hit != null:
			_cursor = hit
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			buttons |= MinigameBase.BUTTON_PRIMARY
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			buttons |= MinigameBase.BUTTON_SECONDARY
	var c := _cursor + _stir_tick(delta)
	var ext: Vector2 = mg.plane_extent()
	c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
	var key := mg_key
	mg.handle_cursor(c, buttons, delta)
	if mg == null or key != mg_key:
		return
	_report_accum += delta
	if _report_accum >= REPORT_INTERVAL and not mg.done:
		_report_accum = 0.0
		game.send_operator_report({"k": mg_key, "ms": mg.net_state(), "tb": table_index})


## DEV HOOK (scripts/dev): a dev room bot (a Player with is_bot, simulated by the host) operates
## on the host's own copy of the minigame with its bot_input, reporting as if it were a remote
## operator. Spectators, including the host, see the tool move as usual.
var _bot_op_t := 0.0
var _bot_op_key := ""


func _bot_operator() -> Node:
	if operator_id == 0 or operator_id == Net.my_id():
		return null
	var p = game.players.get(operator_id)
	return p if p != null and is_instance_valid(p) and bool(p.get("is_bot")) else null


func _drive_bot_operator(delta: float) -> void:
	var bot := _bot_operator()
	if bot == null or mg == null or mg.done:
		if mg != null and _bot_op_key != "":
			mg.ctx["operator"] = false
			_bot_op_key = ""
		return
	if _bot_op_key != mg_key:
		_bot_op_key = mg_key
		_bot_op_t = 0.0
	mg.ctx["operator"] = true
	_bot_op_t += delta
	var inp: Dictionary = mg.bot_input(_bot_op_t, float(bot.get_meta("bot_skill", 1.0)))
	var ext: Vector2 = mg.plane_extent()
	var c: Vector2 = inp.get("cursor", Vector2.ZERO)
	c = Vector2(clampf(c.x, -ext.x, ext.x), clampf(c.y, -ext.y, ext.y))
	var key := mg_key
	mg.handle_cursor(c, int(inp.get("buttons", 0)), delta)
	if mg != null and key == mg_key and not mg.done:
		_mg_state = mg.net_state()
		_mg_state_key = mg_key


func _on_botched(amount: float, reason: String) -> void:
	var bot := _bot_operator() if game.is_host() and not _local_op else null  # DEV HOOK
	if bot != null and mg != null:
		receive_operator_report(bot.peer_id, {"k": mg_key, "botches": [[amount, reason]]})
		return
	if not _local_op or mg == null:
		return
	_audio("surgery_botch", null, -6.0)
	game.send_operator_report({"k": mg_key, "botches": [[amount, reason]], "tb": table_index})


func _on_finished(result: Dictionary) -> void:
	var bot := _bot_operator() if game.is_host() and not _local_op else null  # DEV HOOK
	if bot != null and mg != null:
		mg.ctx["operator"] = false
		receive_operator_report(bot.peer_id, {"k": mg_key, "finished": result, "ms": mg.net_state()})
		return
	if not _local_op or mg == null:
		return
	var key := mg_key
	var state: Dictionary = mg.net_state()
	_local_op = false
	_cam_dir = -1
	mg.ctx["operator"] = false
	game.send_operator_report({"k": key, "finished": result, "ms": state, "tb": table_index})


# ---- stirring: an underdosed patient jerks, which shakes the operator's hand

func _sedation() -> float:
	var flags = _case().get("flags", {})
	return float(flags.get("sedation", 1.0)) if flags is Dictionary else 1.0


func _stirs_now() -> bool:
	return String(_mg_step.get("game", "")) != "anesthetic" and _sedation() < 0.75


func _stir_interval() -> float:
	var s := clampf(_sedation(), 0.0, 0.75)
	return lerpf(2.5, 11.0, s / 0.75) * _stir_rng.randf_range(0.7, 1.3)


func _stir_tick(delta: float) -> Vector2:
	if not _stirs_now():
		return Vector2.ZERO
	_stir_timer -= delta
	if _stir_timer <= 0.0:
		_stir_timer = _stir_interval()
		var strength := clampf((0.75 - _sedation()) / 0.75, 0.0, 1.0) * 0.8 + 0.2
		_stir_jolt = STIR_JOLT_TIME
		_stir_amp = strength
		_stir_dir = Vector2.RIGHT.rotated(_stir_rng.randf() * TAU)
		_stir_flash = 1.2
		if mg != null and mg.has_method("on_jolt"):
			mg.on_jolt(_stir_dir * _stir_amp * STIR_SHAKE_M, strength, STIR_JOLT_TIME)
		_body_stir(strength)
		_audio("surgery_stir", _table_pos(), -2.0)
		game.send_operator_report({"k": mg_key, "stir": strength, "reliable": true, "tb": table_index})
	if _stir_jolt <= 0.0:
		return Vector2.ZERO
	_stir_jolt = maxf(0.0, _stir_jolt - delta)
	var k := _stir_jolt / STIR_JOLT_TIME
	var shake := _stir_dir.rotated(sin(_stir_jolt * 45.0) * 0.9)
	return shake * _stir_amp * STIR_SHAKE_M * k


func _body_stir(strength: float) -> void:
	var body = _body()
	if body != null and is_instance_valid(body) and body.has_method("stir"):
		body.stir(strength)


# =============================================================================== camera

func _pose() -> Transform3D:
	if mg == null:
		return _last_pose
	var site := mg.global_transform
	var pose: Dictionary = mg.camera_pose()
	var up := site.basis.y.normalized()
	var back := site.basis.z.normalized()
	var pos := site.origin + up * float(pose.get("height", 0.55)) + back * float(pose.get("back", 0.18))
	var upv := -back if absf(up.dot(Vector3.UP)) > 0.9 else Vector3.UP
	_last_pose = Transform3D(Basis.looking_at(site.origin - pos, upv), pos)
	_last_pose_fov = float(pose.get("fov", 55.0))
	return _last_pose


func _update_camera(delta: float) -> void:
	if _cam_dir == 0:
		return
	_cam_blend = clampf(_cam_blend + float(_cam_dir) * delta / TWEEN_TIME, 0.0, 1.0)
	var target := _pose()
	var p = game.local_player()
	var head: Transform3D = target
	if p != null and "camera" in p and p.camera != null:
		head = p.camera.global_transform
		_head_fov = p.camera.fov
	var e := smoothstep(0.0, 1.0, _cam_blend)
	_cam.global_transform = head.interpolate_with(target, e)
	_cam.fov = lerpf(_head_fov, _last_pose_fov, e)
	_lamp.visible = e > 0.02
	_lamp.light_energy = LAMP_ENERGY * e
	if _cam_dir < 0 and _cam_blend <= 0.0:
		_cam_dir = 0
		_cam.current = false
		_lamp.visible = false
		if p != null and "camera" in p and p.camera != null and p.alive:
			p.camera.current = true


func camera() -> Camera3D:
	if _local_op or _cam_dir != 0:
		return _cam
	return null


func wants_mouse() -> bool:
	return _local_op


# =============================================================================== HUD

func hud_state() -> Dictionary:
	if mg == null or operator_id == 0:
		return {}
	var st: Dictionary = mg.hud_state().duplicate()
	var p = game.players.get(operator_id)
	st["operator_id"] = operator_id
	st["operator_name"] = p.player_name if p != null else "Someone"
	st["local"] = _local_op
	st["stirring"] = _stir_flash > 0.0
	st["step_label"] = String(_mg_step.get("label", ""))
	st["table"] = table_index
	var c := _case()
	st["step_index"] = int(c.get("step_index", 0))
	st["steps"] = Procedures.steps(String(c.get("ailment_id", ""))).size()
	st["vitals"] = _case_vitals()
	if not st.has("title"):
		st["title"] = st.step_label
	return st


func is_local_operating() -> bool:
	return _local_op


func _audio(cue: String, at, vol := 0.0) -> void:
	var a = get_node_or_null("/root/Audio")
	if a != null:
		a.play(cue, at, vol)
