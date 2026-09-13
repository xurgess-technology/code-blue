extends Node3D
## Patient lab: an operating table under a lamp in the real game environment, building each
## PatientBody and stepping through its states for screenshots.
##
##   godot --path . tools/patient_lab.tscn                      # all shots into tools/patient_shots/
##   godot --path . tools/patient_lab.tscn -- --only=seal       # one patient
##   godot --path . tools/patient_lab.tscn -- --filter=axes     # shots whose name contains "axes"
##   godot --path . tools/patient_lab.tscn -- --view            # no shots: orbit a seal/bob, stays open
##   godot --headless --path . tools/patient_lab.tscn -- --check  # API check for both patients, exit code = failures

const BodyScript := preload("res://scripts/patient_body.gd")
const Kit := preload("res://scripts/patients/patient_kit.gd")
const SHOT_DIR := "res://tools/patient_shots"
const SITES := ["injection", "gunshot", "limb", "limb_cut"]

var table_top := 0.9
var body: Node3D
var cam: Camera3D
var gizmos: Array[Node3D] = []
var failures := 0


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_build_room()
	if args.has("check"):
		await _run_check()
		get_tree().quit(failures)
		return
	if args.has("view"):
		_make_body(String(args.get("patient", "seal")), String(args.get("ailment", "amputation")), {"sedation": 0.2})
		_look("34")
		return
	await _run_shots(String(args.get("only", "")), String(args.get("filter", "")))
	get_tree().quit(0)


# -- room -----------------------------------------------------------------------------------------

func _build_room() -> void:
	add_child(Look.make_environment())
	Look.apply_quality(self, Look.QUALITY_HIGH)
	var floor_mat := Kit.mat("lab_floor", Color(0.32, 0.34, 0.33), 0.9)
	var assets = get_node_or_null("/root/Assets")
	if assets != null and assets.has("mat/floor"):
		floor_mat = assets.material("mat/floor")
	Kit.add_mesh(self, Kit.box(Vector3(8, 0.1, 8)), floor_mat, Transform3D(Basis(), Vector3(0, -0.05, 0)), "Floor")
	var wall := Kit.mat("lab_wall", Color(0.42, 0.5, 0.47), 0.9)
	if assets != null and assets.has("mat/wall_tile"):
		wall = assets.material("mat/wall_tile")
	Kit.add_mesh(self, Kit.box(Vector3(8, 3, 0.2)), wall, Transform3D(Basis(), Vector3(0, 1.5, -2.6)), "WallN")
	Kit.add_mesh(self, Kit.box(Vector3(0.2, 3, 8)), wall, Transform3D(Basis(), Vector3(-3.2, 1.5, 0)), "WallW")

	var table: Node3D = null
	if assets != null and assets.has("prop/table_op"):
		table = assets.spawn("prop/table_op")
	if table != null:
		add_child(table)
		var top := -1.0
		for mi in table.find_children("*", "MeshInstance3D", true, false):
			var aabb: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			top = maxf(top, aabb.end.y)
		table_top = top
	else:
		Kit.add_mesh(self, Kit.box(Vector3(2.0, 0.9, 1.1)), Kit.mat("lab_table", Color(0.6, 0.64, 0.66), 0.4, 0.5), Transform3D(Basis(), Vector3(0, 0.45, 0)), "Table")
		table_top = 0.9

	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0.1, table_top + 1.7, 0.2)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_angle = 42
	lamp.spot_range = 5.0
	lamp.light_energy = 2.2
	lamp.light_color = Color(1.0, 0.97, 0.9)
	lamp.shadow_enabled = true
	add_child(lamp)
	Kit.add_mesh(self, Kit.cyl(0.32, 0.4, 0.12, 20), Kit.mat("lamp_shell", Color(0.7, 0.72, 0.7), 0.4, 0.6), Transform3D(Basis(), lamp.position + Vector3(0, 0.1, 0)), "LampShell")
	Kit.add_mesh(self, Kit.cyl(0.3, 0.3, 0.02, 20), Kit.mat("lamp_glass", Color(1, 1, 0.95), 0.2, 0.0, Color(1, 0.97, 0.9), 1.2), Transform3D(Basis(), lamp.position + Vector3(0, 0.03, 0)), "LampGlass")
	var fill := OmniLight3D.new()
	fill.position = Vector3(1.8, 2.2, 1.8)
	fill.light_energy = 0.8
	fill.omni_range = 6.0
	fill.light_color = Color(0.7, 0.85, 0.8)
	add_child(fill)

	cam = Camera3D.new()
	cam.fov = 50
	add_child(cam)
	cam.current = true


# -- body helpers ---------------------------------------------------------------------------------

func _make_body(pid: String, ailment: String, flags: Dictionary) -> void:
	if body != null:
		body.queue_free()
		body = null
	for g in gizmos:
		g.queue_free()
	gizmos.clear()
	body = BodyScript.create(pid)
	add_child(body)
	body.position = Vector3(0, table_top, 0)
	body.set_ailment(ailment)
	body.set_sedation(1.0)
	body.apply_flags(flags)


func _show_axes() -> void:
	for s in SITES:
		var holder := Node3D.new()
		add_child(holder)
		holder.global_transform = body.site_transform(s)
		Kit.make_axes(holder, 0.14, s)
		gizmos.append(holder)


func _look(view: String) -> void:
	var o: Vector3 = body.global_position
	match view:
		"34":
			_place(o + Vector3(1.35, 1.25, 1.5), o + Vector3(0.05, 0.12, 0))
		"top":
			_place(o + Vector3(0, 1.6, 0.0), o, Vector3(0, 0, -1))
		"34b":
			_place(o + Vector3(-1.4, 1.2, -1.45), o + Vector3(0, 0.12, 0))
		"side":
			_place(o + Vector3(0.0, 0.35, 2.3), o + Vector3(0, 0.2, 0))
		_:
			# "site:<name>:<top|34>"
			var bits := view.split(":")
			var st: Transform3D = body.site_transform(bits[1])
			if bits.size() > 2 and bits[2] == "top":
				_place(st.origin + Vector3(0, 0.75, 0), st.origin, Vector3(0, 0, -1))
			else:
				_place(st.origin + Vector3(0.32, 0.42, 0.52), st.origin)


func _place(pos: Vector3, target: Vector3, up := Vector3.UP) -> void:
	cam.global_position = pos
	cam.look_at(target, up)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _snap(nm: String) -> void:
	await RenderingServer.frame_post_draw
	if DisplayServer.get_name() == "headless":
		return
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var p := "%s/%s.png" % [SHOT_DIR, nm]
	img.save_png(ProjectSettings.globalize_path(p))
	print("[patient_lab] wrote ", p)


# -- shots --------------------------------------------------------------------------------------------

func _run_shots(only: String, filter: String) -> void:
	var shots := [
		# name, ailment, flags, view, setup, wait
		["gunshot_34", "gunshot", {}, "34", "", 0.6],
		["gunshot_top", "gunshot", {}, "top", "", 0.6],
		["amputation_34", "amputation", {}, "34", "", 0.6],
		["amputation_top", "amputation", {}, "top", "", 0.6],
		["side", "amputation", {}, "side", "", 0.6],
		["wound_close", "gunshot", {}, "site:gunshot:34", "", 0.6],
		["bullet_removed", "gunshot", {"bullet_removed": true}, "site:gunshot:34", "", 0.6],
		["tourniquet", "amputation", {"tourniquet": 0.9}, "site:limb:34", "", 0.6],
		["amputated", "amputation", {"tourniquet": 0.9, "amputated": true}, "site:limb_cut:34", "", 0.6],
		["dressed_gunshot", "gunshot", {"bullet_removed": true, "dressed": true}, "34", "", 0.6],
		["dressed_gunshot_close", "gunshot", {"bullet_removed": true, "dressed": true}, "site:gunshot:34", "", 0.6],
		["dressed_amputation", "amputation", {"tourniquet": 0.9, "amputated": true, "dressed": true}, "site:limb_cut:34", "", 0.6],
		["bleeding_gunshot", "gunshot", {}, "34", "bleed:gunshot:0.9", 5.0],
		["bleeding_gunshot_far", "gunshot", {}, "34b", "bleed:gunshot:0.9", 5.0],
		["bleeding_stump", "amputation", {"tourniquet": 0.5, "amputated": true}, "site:limb_cut:34", "bleed:limb_cut:0.8", 4.0],
		["low_vitals", "gunshot", {}, "34", "vitals:12", 3.0],
		["flatline", "amputation", {}, "34", "flatline", 4.0],
		["stir", "gunshot", {}, "34", "stir", 0.12],
		["axes_top", "gunshot", {}, "top", "axes", 0.4],
		["axes_34", "amputation", {}, "34", "axes", 0.4],
		["axes_limb_top", "amputation", {}, "site:limb:top", "axes", 0.4],
		["axes_limb_34", "amputation", {}, "site:limb:34", "axes", 0.4],
	]
	for pid in ["bob", "seal"]:
		if only != "" and pid != only:
			continue
		for s in shots:
			var nm := "%s_%s" % [pid, s[0]]
			if filter != "" and not nm.contains(filter):
				continue
			_make_body(pid, s[1], s[2])
			await get_tree().process_frame
			_look(s[3])
			var setup: String = s[4]
			if setup.begins_with("bleed:"):
				var bits := setup.split(":")
				body.set_bleeding(bits[1], float(bits[2]))
			elif setup.begins_with("vitals:"):
				body.set_vitals(float(setup.split(":")[1]))
			elif setup == "flatline":
				body.flatline()
			elif setup == "axes":
				_show_axes()
			if setup == "stir":
				await _wait(0.5)
				body.stir(1.0)
			await _wait(float(s[5]))
			await _snap(nm)
	if body != null:
		body.queue_free()


# -- headless API check -------------------------------------------------------------------------------

func _fail(msg: String) -> void:
	failures += 1
	push_error("[patient_lab check] " + msg)


func _run_check() -> void:
	var up := Vector3.UP
	for pid in ["bob", "seal"]:
		for ailment in ["gunshot", "amputation"]:
			_make_body(pid, ailment, {})
			body.rotation.y = 0.7   # a table not aligned with the world axes
			body.position = Vector3(3.0, table_top, -1.0)
			await get_tree().process_frame
			var bt: Transform3D = body.global_transform
			for s in SITES:
				if not body.has_site(s):
					_fail("%s has no site %s" % [pid, s])
					continue
				var st: Transform3D = body.site_transform(s)
				var bz := st.basis
				var ortho := absf(bz.x.dot(bz.y)) + absf(bz.y.dot(bz.z)) + absf(bz.x.dot(bz.z))
				if ortho > 0.01 or absf(bz.determinant() - 1.0) > 0.01:
					_fail("%s %s basis not orthonormal right-handed (det %.3f)" % [pid, s, bz.determinant()])
				if bz.y.dot(up) < 0.85:
					_fail("%s %s +Y not up enough (%.2f)" % [pid, s, bz.y.dot(up)])
				var local := bt.affine_inverse() * st
				if s in ["limb", "limb_cut"] and local.origin.z <= 0.0:
					_fail("%s %s is not on the +Z side (z=%.3f)" % [pid, s, local.origin.z])
				print("[check] %s/%s %-9s local pos=(%.3f, %.3f, %.3f) X=(%.2f, %.2f, %.2f) Y=(%.2f, %.2f, %.2f) Z=(%.2f, %.2f, %.2f)" % [
					pid, ailment, s, local.origin.x, local.origin.y, local.origin.z,
					local.basis.x.x, local.basis.x.y, local.basis.x.z, local.basis.y.x, local.basis.y.y, local.basis.y.z,
					local.basis.z.x, local.basis.z.y, local.basis.z.z])
			if body.has_site("nope"):
				_fail("has_site accepted a bogus site")
			body.site_transform("nope")
			for v in [100.0, 60.0, 35.0, 20.0, 5.0]:
				body.set_vitals(v)
				await get_tree().process_frame
			for sd in [0.0, 0.3, 1.0]:
				body.set_sedation(sd)
				await get_tree().process_frame
			body.set_sedation(0.0)
			body.stir(1.0)
			body.stir(0.2)
			for s in SITES:
				body.set_bleeding(s, 0.7)
			body.set_bleeding("nope", 1.0)
			await _wait(0.6)
			var seq := [
				{},
				{"sedation": 0.8},
				{"sedation": 0.8, "bullet_removed": true},
				{"sedation": 0.8, "tourniquet": 0.95},
				{"sedation": 0.8, "tourniquet": 0.95, "amputated": true},
				{"sedation": 0.8, "tourniquet": 0.95, "amputated": true, "dressed": true},
				{"sedation": 0.8, "bullet_removed": true, "dressed": true},
				{"tourniquet": true, "amputated": 1.0},
			]
			for f in seq:
				body.apply_flags(f)
				var snap1 := _vis_snapshot(body)
				body.apply_flags(f)
				body.apply_flags(f)
				if _vis_snapshot(body) != snap1:
					_fail("%s apply_flags not idempotent for %s" % [pid, str(f)])
				await get_tree().process_frame
			for s in SITES:
				body.set_bleeding(s, 0.0)
			body.flatline()
			body.stir(1.0)
			await _wait(0.4)
			body.set_vitals(50.0)
			await get_tree().process_frame
			print("[check] %s/%s ok so far, failures=%d" % [pid, ailment, failures])
	body.queue_free()
	body = null
	await get_tree().process_frame
	print("[check] done, failures=%d" % failures)


func _vis_snapshot(n: Node) -> String:
	var out := PackedStringArray()
	for c in n.find_children("*", "Node3D", true, false):
		out.append("%s:%s:%s" % [c.name, str((c as Node3D).visible), str((c as Node3D).scale)])
	return ",".join(out)
