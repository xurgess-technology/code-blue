class_name Warmup
extends RefCounted
## Removes first-time hitches.
##
## Measured on a Radeon 890M: the first patient body cost 107 ms to build, the first
## Discharged 119 ms, the first anesthetic vial 37 ms, and every surgery step 70 to 150 ms,
## because each new kind of material has to be compiled. Worse, Godot frees a material's
## shader as soon as nothing uses it, so a step's minigame paid that cost again every time.
##
## Once per session, behind a short "scrubbing in" cover, this builds one of everything,
## shows it to the camera for a few frames, then keeps it all alive but hidden. After that
## the same things build in a millisecond or two and draw without compiling.

const COVER_LAYER := 120
const RENDER_FRAMES := 8

const BodyScript := preload("res://scripts/patient_body.gd")
const MonsterModel := preload("res://scripts/monsters/monster_model.gd")
const DevGun := preload("res://scripts/dev/dev_gun.gd")  # DEV HOOK
const LootTable := preload("res://scripts/economy/loot_table.gd")  # INVENTORY HOOK
const EconomyScript := preload("res://scripts/economy/economy.gd")  # INVENTORY HOOK
const PlayerBodyScript := preload("res://scripts/downed/player_body.gd")  # DOWNED HOOK
const PlayerTableScript := preload("res://scripts/downed/player_table.gd")  # DOWNED HOOK
const OrScreenScript := preload("res://scripts/orscreen/or_screen.gd")  # ORSCREEN HOOK


## Run once. Safe to call again; later calls return immediately.
static func run(game: Node) -> void:
	if game.has_meta("warmed_up"):
		return
	game.set_meta("warmed_up", true)
	var tree := game.get_tree()
	var started := Time.get_ticks_msec()

	var cover := _make_cover()
	game.get_parent().add_child(cover)
	var master := AudioServer.get_bus_index("Master")
	var was_muted := AudioServer.is_bus_mute(master)
	AudioServer.set_bus_mute(master, true)

	var root := Node3D.new()
	root.name = "WarmupKeepAlive"
	game.add_child(root)
	var shelf := Node3D.new()
	root.add_child(shelf)

	# Items
	var x := -0.9
	for kind in Items.ITEMS.keys():
		for n in ([1, 3] if Items.is_consumable(kind) else [1]):
			var m := ItemModels.make(kind, n)
			shelf.add_child(m)
			m.position = Vector3(x, 0.35, 0.0)
			x += 0.26

	# INVENTORY HOOK: the teal / gold rim overlay on stacks, every loot kind, the sell bin, the
	# shop counter and a gold pile.
	for kind in Items.ITEMS.keys() + LootTable.kinds():
		var tm := ItemModels.make_tinted(kind, 1)
		shelf.add_child(tm)
		tm.position = Vector3(x, 0.05, 0.3)
		x += 0.2
	EconomyScript.warm(shelf)
	OrScreenScript.warm(shelf)  # ORSCREEN HOOK: the wall monitor's glass shader and viewport
	# SWEEP 3 HOOK (combat): the syringe the jab draws (its glass is alpha-blended).
	var syringe: Node3D = preload("res://scripts/combat/combat.gd").make_syringe()
	shelf.add_child(syringe)
	syringe.position = Vector3(x, 0.3, 0.3)

	# Patients, each showing every visual state a case can reach
	var bodies := {}
	var bx := -0.6
	for pid in Procedures.PATIENTS.keys():
		for ail in Procedures.patient_ailments():
			var b: Node3D = BodyScript.create(pid)
			shelf.add_child(b)
			b.position = Vector3(bx, -0.3, -0.8)
			b.scale = Vector3.ONE * 0.5
			b.set_ailment(ail)
			if ail == "amputation":
				b.apply_flags({"sedation": 0.5, "tourniquet": 0.8, "amputated": true, "dressed": true})
			else:
				b.apply_flags({"sedation": 0.5, "bullet_removed": true})
				b.set_bleeding("gunshot", 0.8)
			bodies["%s|%s" % [pid, ail]] = b
			bx += 0.4
	# DOWNED HOOK: the lying player on the player table (bleeding and stitched) and the table itself.
	for stitched in [false, true]:
		var pb: Node3D = PlayerBodyScript.create(1, Color("3d8f80"))
		shelf.add_child(pb)
		pb.position = Vector3(bx, -0.3, -0.8)
		pb.scale = Vector3.ONE * 0.5
		pb.set_bleeding("gash", 0.8)
		pb.apply_flags({"stitched": stitched})
		bodies["player|stitches"] = pb
		bx += 0.4
	var ptable := PlayerTableScript.make()
	shelf.add_child(ptable)
	ptable.position = Vector3(0.0, -1.4, -2.2)
	ptable.scale = Vector3.ONE * 0.5

	# Monsters: the visual model only, so nothing starts thinking or moving
	var mx := -0.5
	for kind in ["discharged", "night_nurse"]:
		var model: Node3D = MonsterModel.new()
		shelf.add_child(model)
		model.setup(kind)
		model.position = Vector3(mx, -1.6, -2.0)
		model.scale = Vector3.ONE * 0.5
		mx += 1.0

	# DEV HOOK (scripts/dev): the dev gun, its tracers and the target dummy.
	DevGun.warm(shelf)

	# LOOP HOOK: a paramedic crew with its gurney, and the break-room phone.
	var crew: Node3D = (load("res://scripts/loop/crew.gd") as GDScript).create("", "")
	crew.scale = Vector3.ONE * 0.4
	crew.position = Vector3(1.2, -0.6, -1.2)
	shelf.add_child(crew)
	# MODELS HOOK: the look-alike crew must not collide with anything (its paramedics are rigged
	# models now; their skinning and the merged gurney compile here).
	for n in crew.find_children("*", "CollisionObject3D", true, false):
		n.queue_free()
	var ph: Node3D = (load("res://scripts/loop/phone.gd") as GDScript).create()
	ph.remove_from_group("interactable")   # only a look-alike: never the real "phone"
	ph.remove_meta("interact_id")
	for n in ph.find_children("*", "CollisionObject3D", true, false):
		n.queue_free()
	ph.position = Vector3(-1.2, -0.6, -1.0)
	shelf.add_child(ph)
	ph.set_ringing(true)

	# Every surgery minigame, set up on a patient the way the surgery system does it
	var games := []
	for ail in Procedures.AILMENTS.keys():
		for i in Procedures.steps(ail).size():
			var step: Dictionary = Procedures.step(ail, i)
			var path: String = Procedures.MINIGAME_SCRIPTS.get(step.game, "")
			if path == "" or not ResourceLoader.exists(path):
				continue
			for pid in (["player"] if Procedures.is_player_only(ail) else Procedures.PATIENTS.keys()):
				var body: Node3D = bodies["%s|%s" % [pid, ail]]
				var mg: Node3D = (load(path) as GDScript).new()
				shelf.add_child(mg)
				mg.global_transform = body.site_transform(step.site)
				mg.setup({
					"patient_id": pid, "patient": Procedures.patient(pid), "ailment_id": ail,
					"step": step, "variant": step.get("variant", ""), "shift": 1,
					"difficulty": 1.0, "flags": {"sedation": 1.0, "tourniquet": 0.4},
					"seed": 7 + i, "body": body, "operator": false,
				})
				games.append(mg)

	# Some steps build their geometry on a worker thread (the forceps wound channel). Wait for
	# it to land, or its material is never drawn here and compiles when the real step begins.
	for mg in games:
		var task = mg.get("_channel_task")
		if task != null and int(task) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(task))
			mg.set("_channel_task", -1)
	await tree.process_frame

	# Put it all in front of whatever camera is live, and draw it for a few frames.
	for f in RENDER_FRAMES:
		var cam := game.get_viewport().get_camera_3d()
		if cam != null:
			shelf.global_transform = cam.global_transform * Transform3D(Basis(), Vector3(0.0, -0.2, -2.2))
		for mg in games:
			if is_instance_valid(mg):
				mg.tick(1.0 / 60.0)
		await tree.process_frame

	# Keep everything alive so its shaders stay compiled, but out of sight and asleep.
	shelf.visible = false
	root.process_mode = Node.PROCESS_MODE_DISABLED
	AudioServer.set_bus_mute(master, was_muted)
	cover.queue_free()
	print("[warmup] built and drew everything once in %d ms" % (Time.get_ticks_msec() - started))


static func _make_cover() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "WarmupCover"
	layer.layer = COVER_LAYER
	var bg := ColorRect.new()
	bg.color = Color("06080c")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bg)
	var label := Label.new()
	label.text = "SCRUBBING IN..."
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color("8a9aa0"))
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	layer.add_child(label)
	return layer
