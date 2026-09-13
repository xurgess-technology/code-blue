extends Node3D
## Runs one surgery minigame on a stand-in operating table, with no game around it.
##
##   godot --path . tools/minigame_lab.tscn -- --game=forceps [--patient=bob|seal]
##         [--ailment=gunshot|amputation] [--variant=pack|stump] [--bot=1.0] [--seconds=40]
##         [--shot=res://tools/lab_shots/forceps.png] [--shot-at=6.0] [--flags=sedation:0.6,tourniquet:0.9]
##
## Interactive (no --bot): move the mouse over the plane, left and right mouse buttons act.
## With --bot: plays the minigame's own bot_input(t, skill) and prints a report. Add --headless
## to run without a window. Exits 0 when the step finished, 1 otherwise.

const MinigameBase := preload("res://scripts/surgery/minigame.gd")
const BodyScript := preload("res://scripts/patient_body.gd")

var game_id := "anesthetic"
var patient_id := "bob"
var ailment_id := ""
var variant := ""
var bot_skill := -1.0
var seconds := 45.0
var shot_path := ""
var shot_at := -1.0
var flags := {}

var mg: Node3D
var cam: Camera3D
var body: Node3D
var site := Transform3D()
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
			"flags":
				for pair in v.split(",", false):
					var pv := pair.split(":")
					if pv.size() == 2:
						flags[pv[0]] = float(pv[1])

	if ailment_id == "":
		ailment_id = "amputation" if game_id in ["tourniquet", "saw"] else "gunshot"
	var step := _find_step()
	if variant == "" and step.has("variant"):
		variant = step.variant

	_build_room()
	body = BodyScript.create(patient_id)
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
		"seed": hash(game_id + patient_id), "body": body, "operator": true,
	})

	cam = Camera3D.new()
	add_child(cam)
	var pose: Dictionary = mg.camera_pose()
	var up := site.basis.y.normalized()
	var back := site.basis.z.normalized()
	cam.global_position = site.origin + up * float(pose.get("height", 0.55)) + back * float(pose.get("back", 0.18))
	cam.look_at(site.origin, -back if absf(up.dot(Vector3.UP)) > 0.9 else Vector3.UP)
	cam.fov = float(pose.get("fov", 55.0))
	cam.current = true

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	print("[lab] game=%s patient=%s ailment=%s variant=%s bot=%s" % [game_id, patient_id, ailment_id, variant, str(bot_skill)])


func _find_step() -> Dictionary:
	for s in Procedures.steps(ailment_id):
		if s.game == game_id:
			return s
	return {"id": game_id, "label": game_id, "item": "", "uses": 0, "game": game_id, "site": "gunshot"}


func _build_room() -> void:
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
	if not mg.done:
		if bot_skill >= 0.0:
			var inp: Dictionary = mg.bot_input(t, bot_skill)
			mg.handle_cursor(_clamp(inp.get("cursor", Vector2.ZERO)), int(inp.get("buttons", 0)), delta)
		elif cam != null:
			var hit = MinigameBase.screen_to_plane(cam, get_viewport().get_mouse_position(), mg.global_transform)
			if hit != null:
				var b := 0
				if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT): b |= MinigameBase.BUTTON_PRIMARY
				if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT): b |= MinigameBase.BUTTON_SECONDARY
				mg.handle_cursor(_clamp(hit), b, delta)
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
			"DONE" if finished_at >= 0.0 else "UNFINISHED", finished_at, botch_count, botch_total, mg.progress, str(result)])
		get_tree().quit(0 if finished_at >= 0.0 else 1)


func _clamp(p: Vector2) -> Vector2:
	var ext: Vector2 = mg.plane_extent()
	return Vector2(clampf(p.x, -ext.x, ext.x), clampf(p.y, -ext.y, ext.y))


func _draw_hud() -> void:
	var h: Dictionary = mg.hud_state()
	var text := "%s\n%s\nprogress %d%%   botches %d (%.1f vitals)" % [h.get("title", ""), h.get("hint", ""), int(float(h.get("progress", mg.progress)) * 100), botch_count, botch_total]
	for g in h.get("gauges", []):
		text += "\n%s: %.2f  (good %.2f..%.2f)" % [g.label, float(g.value), float(g.good_min), float(g.good_max)]
	_hud.text = text


func _take_shot() -> void:
	_shot_taken = true
	if DisplayServer.get_name() == "headless":
		return
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shot_path.get_base_dir()))
	img.save_png(ProjectSettings.globalize_path(shot_path))
	print("[lab] wrote ", shot_path)
