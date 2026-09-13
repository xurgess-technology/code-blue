extends Node3D
## Runs one surgery minigame on a stand-in operating table, with no game around it.
##
##   godot --path . tools/minigame_lab.tscn -- --game=forceps [--patient=bob|seal]
##         [--ailment=gunshot|amputation] [--variant=pack|stump] [--bot=1.0] [--seconds=40]
##         [--shot=res://tools/lab_shots/forceps.png] [--shot-at=6.0] [--flags=sedation:0.6,tourniquet:0.9]
##         [--seed=N] [--wide] [--nohud] [--look=or] [--selftest=<game>]
##
## --flags with sedation under 0.75 makes the patient stir the way the surgery system does.
## --look=or lights it like the game: the hospital environment and post effects, a dim ceiling
##   light and the surgery system's work lamp on the camera (the default lab light is much brighter).
## --nohud hides the lab's text overlay (to judge a screenshot without the hint).
## --selftest=<game> runs that minigame's static self_test() and quits.
##
## Interactive (no --bot): move the mouse over the plane, left and right mouse buttons act.
## With --bot: plays the minigame's own bot_input(t, skill) and prints a report. Add --headless
## to run without a window. Exits 0 when the step finished, 1 otherwise.

const MinigameBase := preload("res://scripts/surgery/minigame.gd")
const BodyScript := preload("res://scripts/patient_body.gd")
const PlayerBodyScript := preload("res://scripts/downed/player_body.gd")

var game_id := "anesthetic"
var patient_id := "bob"
var ailment_id := ""
var variant := ""
var bot_skill := -1.0
var seconds := 45.0
var shot_path := ""
var shot_at := -1.0
var flags := {}
var seed_value := -1
var wide := false
var self_test := ""
var nohud := false
var look := ""

# Stirs, the way scripts/surgery/surgery_system.gd makes them when sedation is under 0.75.
const STIR_JOLT_TIME := 0.35
const STIR_SHAKE_M := 0.09
var _stir_rng := RandomNumberGenerator.new()
var _stir_timer := 1.5
var _stir_jolt := 0.0
var _stir_dir := Vector2.RIGHT
var _stir_amp := 0.0
var stir_count := 0

var mg: Node3D
var cam: Camera3D
var body: Node3D
var site := Transform3D()
var step_site := ""
var t := 0.0
var botch_total := 0.0
var botch_count := 0
var result: Dictionary = {}
var finished_at := -1.0
var _shot_taken := false
var _hud: Label


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var k := kv[0]
		var v := kv[1] if kv.size() > 1 else ""
		match k:
			"game": game_id = v
			"patient": patient_id = v
			"ailment": ailment_id = v
			"variant": variant = v
			"bot": bot_skill = float(v)
			"seconds": seconds = float(v)
			"shot": shot_path = v
			"shot-at": shot_at = float(v)
			"seed": seed_value = int(v)
			"wide": wide = true
			"selftest": self_test = v
			"nohud": nohud = true
			"look": look = v
			"flags":
				for pair in v.split(",", false):
					var pv := pair.split(":")
					if pv.size() == 2:
						flags[pv[0]] = float(pv[1])

	if self_test != "":
		_run_self_test.call_deferred()
		return
	if ailment_id == "":
		ailment_id = "amputation" if game_id in ["tourniquet", "saw"] or variant == "stump" else "gunshot"
		if game_id == "stitches":   # downed (sweep 2 wave 3): a downed surgeon on the player table
			ailment_id = "stitches"
			patient_id = "player"
	var step := _find_step()
	if variant == "" and step.has("variant"):
		variant = step.variant
	# The stump dressing comes after the saw: show the limb already off unless told otherwise.
	if game_id == "gauze" and variant == "stump" and not flags.has("amputated"):
		flags["amputated"] = true

	_build_room()
	body = PlayerBodyScript.create(1, Color("3d8f80")) if patient_id == "player" else BodyScript.create(patient_id)
	add_child(body)
	body.position = Vector3(0, 0.95, 0)
	if body.has_method("set_ailment"):
		body.set_ailment(ailment_id)
	if body.has_method("set_sedation"):
		body.set_sedation(float(flags.get("sedation", 1.0)))
	if body.has_method("apply_flags") and not flags.is_empty():
		body.apply_flags(flags)
	await get_tree().process_frame
	site = body.site_transform(step.site) if body.has_method("site_transform") else Transform3D(Basis(), Vector3(0, 1.2, 0))
	step_site = String(step.site)

	var path: String = Procedures.MINIGAME_SCRIPTS.get(game_id, "")
	if path == "" or not ResourceLoader.exists(path):
		push_error("No minigame script for '%s' at '%s'" % [game_id, path])
		get_tree().quit(2)
		return
	mg = (load(path) as GDScript).new()
	add_child(mg)
	mg.global_transform = site
	mg.botched.connect(func(amount, reason):
		botch_total += amount
		botch_count += 1
		print("[lab] t=%.1f botch %.2f %s" % [t, amount, reason]))
	mg.finished.connect(func(r):
		result = r
		finished_at = t
		print("[lab] t=%.1f finished %s" % [t, str(r)]))
	mg.setup({
		"patient_id": patient_id, "patient": Procedures.patient(patient_id),
		"ailment_id": ailment_id, "step": step, "variant": variant,
		"shift": 1, "difficulty": Procedures.difficulty(1), "flags": flags,
		"seed": seed_value if seed_value >= 0 else hash(game_id + patient_id), "body": body, "operator": true,
	})

	cam = Camera3D.new()
	add_child(cam)
	var pose: Dictionary = mg.camera_pose()
	var up := site.basis.y.normalized()
	var back := site.basis.z.normalized()
	cam.global_position = site.origin + up * float(pose.get("height", 0.55)) + back * float(pose.get("back", 0.18))
	cam.look_at(site.origin, -back if absf(up.dot(Vector3.UP)) > 0.9 else Vector3.UP)
	cam.fov = float(pose.get("fov", 55.0))
	if wide:
		# Pulled back and to the side, to judge the body around the site (infection, severed limb).
		cam.global_position = site.origin + Vector3(0.25, 0.75, 0.55)
		cam.look_at(site.origin, Vector3.UP)
	cam.current = true
	if look == "or":
		# The surgery system's work lamp (scripts/surgery/surgery_system.gd), riding on the camera.
		# ORSCREEN HOOK: the real lamp, so tuning it in surgery_system.gd shows up here.
		var work: SpotLight3D = (load("res://scripts/surgery/surgery_system.gd") as GDScript).make_work_lamp()
		cam.add_child(work)

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	_hud.visible = not nohud
	_stir_rng.seed = hash("lab_stir") + seed_value
	print("[lab] game=%s patient=%s ailment=%s variant=%s bot=%s" % [game_id, patient_id, ailment_id, variant, str(bot_skill)])


func _find_step() -> Dictionary:
	for s in Procedures.steps(ailment_id):
		if s.game == game_id:
			return s
	return {"id": game_id, "label": game_id, "item": "", "uses": 0, "game": game_id, "site": "gunshot"}


func _build_room() -> void:
	if look == "or":
		add_child(Look.make_environment())
		add_child(Look.make_post_layer())
		Look.apply_quality(self, Look.QUALITY_MEDIUM)
		var ceiling := OmniLight3D.new()
		ceiling.position = Vector3(0.0, 2.8, 0.4)
		ceiling.light_energy = 1.6
		ceiling.omni_range = 5.0
		ceiling.shadow_enabled = true
		add_child(ceiling)
		_add_table()
		return
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.03, 0.04, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.6, 0.65)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.environment = e
	add_child(env)
	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0.2, 3.0, 0.3)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_angle = 35
	lamp.light_energy = 7.0
	lamp.spot_range = 6.0
	lamp.shadow_enabled = true
	add_child(lamp)
	_add_table()


func _add_table() -> void:
	var table := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 0.9, 1.0)
	table.mesh = bm
	table.position = Vector3(0, 0.45, 0)
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color("9aa4a8")
	tm.metallic = 0.4
	table.material_override = tm
	add_child(table)


func _physics_process(delta: float) -> void:
	if mg == null:
		return
	t += delta
	# Follow the site as the body breathes and stirs, as the surgery system's _place_mg does.
	if body != null and body.has_method("site_transform") and step_site != "":
		mg.global_transform = body.site_transform(step_site).orthonormalized()
	if not mg.done:
		var shake := _stir_tick(delta)
		if bot_skill >= 0.0:
			var inp: Dictionary = mg.bot_input(t, bot_skill)
			mg.handle_cursor(_clamp(inp.get("cursor", Vector2.ZERO) + shake), int(inp.get("buttons", 0)), delta)
		elif cam != null:
			var hit = MinigameBase.screen_to_plane(cam, get_viewport().get_mouse_position(), mg.global_transform)
			if hit != null:
				var b := 0
				if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT): b |= MinigameBase.BUTTON_PRIMARY
				if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): b |= MinigameBase.BUTTON_SECONDARY
				mg.handle_cursor(_clamp(hit + shake), b, delta)
	mg.tick(delta)
	# Round-trip the net state every frame so a broken apply_net_state shows up in the lab.
	mg.apply_net_state(mg.net_state())
	_draw_hud()

	if shot_path != "" and not _shot_taken and ((shot_at >= 0.0 and t >= shot_at) or (shot_at < 0.0 and finished_at >= 0.0 and t >= finished_at + 0.4)):
		_take_shot()
	var over := t >= seconds or (finished_at >= 0.0 and t >= finished_at + 0.6 and (shot_path == "" or _shot_taken))
	if over:
		print("[lab] ------------------------------------------")
		print("[lab] result=%s finished_at=%.1f botches=%d vitals_cost=%.1f progress=%.2f flags=%s" % [
			"DONE" if finished_at >= 0.0 else "UNFINISHED", finished_at, botch_count, botch_total, mg.progress, str(result)] + ("  stirs=%d" % stir_count if stir_count > 0 else ""))
		get_tree().quit(0 if finished_at >= 0.0 else 1)


## Mirrors the surgery system: an underdosed patient jerks now and then, which calls on_jolt,
## shakes the cursor for a moment and jolts the body.
func _stir_tick(delta: float) -> Vector2:
	var sed := float(flags.get("sedation", 1.0))
	if game_id == "anesthetic" or sed >= 0.75:
		return Vector2.ZERO
	_stir_timer -= delta
	if _stir_timer <= 0.0:
		_stir_timer = lerpf(2.5, 11.0, clampf(sed, 0.0, 0.75) / 0.75) * _stir_rng.randf_range(0.7, 1.3)
		var strength := clampf((0.75 - sed) / 0.75, 0.0, 1.0) * 0.8 + 0.2
		_stir_jolt = STIR_JOLT_TIME
		_stir_amp = strength
		_stir_dir = Vector2.RIGHT.rotated(_stir_rng.randf() * TAU)
		stir_count += 1
		mg.on_jolt(_stir_dir * _stir_amp * STIR_SHAKE_M, strength, STIR_JOLT_TIME)
		if body != null and body.has_method("stir"):
			body.stir(strength)
		print("[lab] t=%.1f stir %.2f" % [t, strength])
	if _stir_jolt <= 0.0:
		return Vector2.ZERO
	_stir_jolt = maxf(0.0, _stir_jolt - delta)
	var k := _stir_jolt / STIR_JOLT_TIME
	return _stir_dir.rotated(sin(_stir_jolt * 45.0) * 0.9) * _stir_amp * STIR_SHAKE_M * k


## `--selftest=<game>`: runs that minigame's static self_test() headless and quits.
func _run_self_test() -> void:
	var path: String = Procedures.MINIGAME_SCRIPTS.get(self_test, "")
	var script := load(path) as GDScript if path != "" else null
	if script == null:
		push_error("No minigame '%s'" % self_test)
		get_tree().quit(2)
		return
	var started := Time.get_ticks_msec()
	if self_test == "forceps":
		script.call("self_test", self, 12)
	else:
		script.call("self_test")
	print("[lab] self-test %s took %d ms" % [self_test, Time.get_ticks_msec() - started])
	get_tree().quit(0)


func _clamp(p: Vector2) -> Vector2:
	var ext: Vector2 = mg.plane_extent()
	return Vector2(clampf(p.x, -ext.x, ext.x), clampf(p.y, -ext.y, ext.y))


func _draw_hud() -> void:
	var h: Dictionary = mg.hud_state()
	var text := "%s\n%s\nprogress %d%%   botches %d (%.1f vitals)" % [h.get("title", ""), h.get("hint", ""), int(float(h.get("progress", mg.progress)) * 100), botch_count, botch_total]
	for g in h.get("gauges", []):
		text += "\n%s: %.2f  (good %.2f..%.2f)" % [g.label, float(g.value), float(g.good_min), float(g.good_max)]
	if not h.get("cross_section", {}).is_empty():
		text += "\n(cross-section strip)"
	_hud.text = text


func _take_shot() -> void:
	_shot_taken = true
	if DisplayServer.get_name() == "headless":
		return
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shot_path.get_base_dir()))
	img.save_png(ProjectSettings.globalize_path(shot_path))
	print("[lab] wrote ", shot_path)
