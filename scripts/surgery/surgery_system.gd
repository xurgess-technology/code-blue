extends Node
## The in-world surgery framework. One per game; the contract is in docs/CONTRACTS.md
## ("Surgery") and scripts/surgery/minigame.gd.
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

## Automated playtests: >= 0 makes the LOCAL operator play with the minigame's bot_input.
var bot_skill: float = -1.0

var game: Node = null

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
	# A surgical work lamp riding on the operator's camera: the OR is dark, the site must not be.
	_lamp = SpotLight3D.new()
	_lamp.name = "WorkLamp"
	_lamp.light_color = Color(1.0, 0.97, 0.9)
	_lamp.light_energy = 0.0
	_lamp.spot_range = 2.5
	_lamp.spot_angle = 32.0
	_lamp.spot_attenuation = 0.6
	_lamp.shadow_enabled = false
	_lamp.light_volumetric_fog_energy = 0.0
	_lamp.visible = false
	_cam.add_child(_lamp)
	hud = HudScript.new()
	hud.name = "SurgeryHud"
	add_child(hud)
	hud.system = self


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
	if game == null or not ("case" in game) or game.case.is_empty():
		return "Nobody is on the table."
	var s := _step()
	if s.is_empty():
		return "Nothing left to do."
	if operator_id != 0 and operator_id == player.peer_id:
		return "You are already operating."
	if operator_id != 0:
		var p = game.players.get(operator_id)
		return "%s is already operating." % (p.player_name if p != null else "Someone")
	var needed: int = maxi(1, int(s.get("uses", 0)))
	if game.shelf_count(String(s.item)) < needed:
		if needed > 1:
			return "Put %d %s on the supply shelf first." % [needed, Items.display_name(String(s.item))]
		return "Put %s on the supply shelf first." % Items.display_name(String(s.item))
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
				game.surgery_botch(float(b[0]), String(b[1]))
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
			game.surgery_step_done(result if result is Dictionary else {})
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
	var v: float = clampf(float(game.get("vitals")) if game.get("vitals") != null else 100.0, 0.0, 100.0)
	_beep_timer = lerpf(0.38, 0.85, v / 100.0)
	var cue := "surgery_beep" if v > 50.0 else ("surgery_beep_low" if v > 25.0 else "surgery_beep_crit")
	_audio(cue, _table_pos(), -5.0)


# =============================================================================== minigame lifecycle

func _step() -> Dictionary:
	if game == null or not ("case" in game) or game.case.is_empty():
		return {}
	return Procedures.step(String(game.case.get("ailment_id", "")), int(game.case.get("step_index", 0)))


func _current_key() -> String:
	var s := _step()
	if s.is_empty():
		return ""
	return "%s|%s|%d" % [game.case.get("patient_id", ""), game.case.get("ailment_id", ""), int(game.case.get("step_index", 0))]


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
	if not ("flags" in game.case) or not (game.case.get("flags") is Dictionary):
		game.case["flags"] = {}
	var body = game.patient_body if ("patient_body" in game) and game.patient_body != null and is_instance_valid(game.patient_body) else null
	var shift := int(game.shift)
	mg.setup({
		"patient_id": String(game.case.get("patient_id", "")),
		"patient": Procedures.patient(String(game.case.get("patient_id", ""))),
		"ailment_id": String(game.case.get("ailment_id", "")),
		"step": step,
		"variant": String(step.get("variant", "")),
		"shift": shift,
		"difficulty": Procedures.difficulty(shift),
		"flags": game.case.flags,
		"seed": hash("%s|%d" % [mg_key, int(game.get("seed_value") if game.get("seed_value") != null else 0)]),
		"body": body,
		"operator": false,
	})
	if _mg_state_key == mg_key and not _mg_state.is_empty():
		mg.apply_net_state(_mg_state)


func _free_mg() -> void:
	if mg != null and is_instance_valid(mg):
		mg.queue_free()
	mg = null
	mg_key = ""
	_mg_step = {}


func _site_transform() -> Transform3D:
	var site := String(_mg_step.get("site", ""))
	var body = game.get("patient_body")
	if body != null and is_instance_valid(body) and body.has_method("site_transform") \
			and (not body.has_method("has_site") or body.has_site(site)):
		var xf: Transform3D = body.site_transform(site)
		return xf.orthonormalized()
	return Transform3D(Basis(), _table_pos() + Vector3.UP * 1.2)


func _place_mg() -> void:
	if mg != null:
		mg.global_transform = _site_transform()


func _table_pos() -> Vector3:
	if game.has_method("table_pos"):
		return game.table_pos()
	var body = game.get("patient_body")
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
			game.send_operator_report({"k": mg_key, "ms": mg.net_state(), "reliable": true})


func local_operator_exit() -> void:
	if not _local_op:
		return
	_exit_requested = true
	var report := {"k": mg_key, "exit": true}
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
		game.send_operator_report({"k": mg_key, "ms": mg.net_state()})


func _on_botched(amount: float, reason: String) -> void:
	if not _local_op or mg == null:
		return
	_audio("surgery_botch", null, -6.0)
	game.send_operator_report({"k": mg_key, "botches": [[amount, reason]]})


func _on_finished(result: Dictionary) -> void:
	if not _local_op or mg == null:
		return
	var key := mg_key
	var state: Dictionary = mg.net_state()
	_local_op = false
	_cam_dir = -1
	mg.ctx["operator"] = false
	game.send_operator_report({"k": key, "finished": result, "ms": state})


# ---- stirring: an underdosed patient jerks, which shakes the operator's hand

func _sedation() -> float:
	var flags = game.case.get("flags", {}) if "case" in game else {}
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
		_body_stir(strength)
		_audio("surgery_stir", _table_pos(), -2.0)
		game.send_operator_report({"k": mg_key, "stir": strength, "reliable": true})
	if _stir_jolt <= 0.0:
		return Vector2.ZERO
	_stir_jolt = maxf(0.0, _stir_jolt - delta)
	var k := _stir_jolt / STIR_JOLT_TIME
	var shake := _stir_dir.rotated(sin(_stir_jolt * 45.0) * 0.9)
	return shake * _stir_amp * 0.09 * k


func _body_stir(strength: float) -> void:
	var body = game.get("patient_body")
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
	_lamp.light_energy = 2.2 * e
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
	if not st.has("title"):
		st["title"] = st.step_label
	return st


func is_local_operating() -> bool:
	return _local_op


func _audio(cue: String, at, vol := 0.0) -> void:
	var a = get_node_or_null("/root/Audio")
	if a != null:
		a.play(cue, at, vol)
