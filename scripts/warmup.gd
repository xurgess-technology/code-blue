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
const BrainsScript := preload("res://scripts/brains/brains.gd")  # SWEEP 3 HOOK (brains)
const DoorScript := preload("res://scripts/doors/door.gd")  # DOORS HOOK
const DoorModels := preload("res://scripts/doors/door_models.gd")  # DOORS HOOK
const HospitalBuilderScript := preload("res://scripts/hospital_builder.gd")  # DOORS HOOK


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
	BrainsScript.warm(shelf)  # SWEEP 3 HOOK (brains): the blender, Echo's ghosts and veil, Hive Eyes' screen
	# POCKETS HOOK: the Factory's and the Restaurant's meshes, textures and materials, and a stub copy.
	preload("res://scripts/level/pockets/pocket_spaces.gd").warm(shelf)
	# HANDS HOOK: the first-person forearms, hands and torch (their skin, sleeve and lens materials, on
	# the hands layer the flashlight skips). The wind-ups build nothing new: they pose these and the
	# syringe above.
	var fp_arm: Node3D = preload("res://scripts/hands/fp_arms.gd").make_arm(-1.0, C.PLAYER_COLORS[0])
	shelf.add_child(fp_arm)
	fp_arm.position = Vector3(x + 0.2, 0.3, 0.3)
	var fp_torch: Node3D = preload("res://scripts/hands/fp_arms.gd").make_torch()
	shelf.add_child(fp_torch)
	fp_torch.position = Vector3(x + 0.4, 0.3, 0.3)

	# Patients, each showing every visual state a case can reach
	var bodies := {}
	var bx := -0.6
	# SWEEP 3 HOOK (dissection): strapped monsters, one closed and awake (thrashing), one opened.
	for mpid in Procedures.monster_patients():
		for opened in [false, true]:
			var mb: Node3D = BodyScript.create(mpid)
			shelf.add_child(mb)
			mb.position = Vector3(bx, -0.3, -0.8)
			mb.scale = Vector3.ONE * 0.5
			mb.set_ailment("dissection")
			mb.apply_flags({"sedation": 1.0 if opened else 0.1, "skull_open": opened})
			mb.set_bleeding("skull", 0.6)
			if opened:
				bodies["%s|dissection" % mpid] = mb
			bx += 0.4
	for pid in Procedures.human_patients():
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
			# SEAL HOOK: the seal's Blender model (patient/seal) builds here; its stump cap is shown by
			# the amputated flags above. The severed paddle the saw drops is a static (unskinned) mesh
			# with the same materials, a different shader variant, so draw one copy too.
			if pid == "seal" and ail == "amputation" and b.has_method("make_severed_limb"):
				var sev: Node3D = b.make_severed_limb(shelf)
				if sev != null:
					sev.position = Vector3(bx, -0.3, -0.8)
					sev.scale = Vector3.ONE * 0.5
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

	# Monsters: the visual model only, so nothing starts thinking or moving. NURSE HOOK: "night_nurse"
	# builds her Blender model (monster/night_nurse: its two skinned materials, shadow mesh and the
	# first load of its six maps), so the first Night Nurse of a session does not hitch.
	var mx := -1.0
	for kind in ["discharged", "night_nurse", "walk_in"]:  # SWEEP 3 HOOK (monsters): the Walk-In
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

	# DOORS HOOK: every furniture kind's shared meshes (the first level only built the kinds it uses;
	# the wing loader's thread needs them all), then one door of every kind (the laminate, steel and glass leaves, the frames, the gate's
	# lamp in each state), as look-alikes: no collision, not interactable.
	var wp0 := Time.get_ticks_msec()
	HospitalBuilderScript.warm_parts()
	var warm_parts_ms := Time.get_ticks_msec() - wp0
	var dx := -1.5
	for kind in ["hinged", "double", "gate", "auto", "sliding"]:
		var w := 4.0 if kind == "sliding" else (2.0 if kind != "hinged" else 1.0)
		var door: Node3D = DoorScript.create({"id": "warm_" + kind, "kind": kind, "tiles": [], "n": Vector2i(0, 1),
				"s": Vector2i(1, 0), "plane": Vector2.ZERO, "width": w, "hinge": -1, "max_in": 90.0, "max_out": 90.0,
				"base": true})
		door.remove_from_group("interactable")
		door.remove_from_group("door")
		door.remove_meta("interact_id")
		door.snap_to(0.4)
		for n in door.find_children("*", "CollisionObject3D", true, false):
			n.collision_layer = 0
		shelf.add_child(door)
		door.position = Vector3(dx, -1.2, -3.0)
		door.scale = Vector3.ONE * 0.3
		dx += 1.0
		if kind == "gate":
			for state in ["unlocking", "open", "locked"]:
				var lens := MeshInstance3D.new()
				lens.mesh = DoorModels.lamp_lens()
				lens.material_override = DoorModels.lamp_material(state)
				door.add_child(lens)

	# Every surgery minigame, set up on a patient the way the surgery system does it
	var games := []
	for ail in Procedures.AILMENTS.keys():
		for i in Procedures.steps(ail).size():
			var step: Dictionary = Procedures.step(ail, i)
			var path: String = Procedures.MINIGAME_SCRIPTS.get(step.game, "")
			if path == "" or not ResourceLoader.exists(path):
				continue
			# SWEEP 3 HOOK (dissection): the skull saw and brain forceps on the monster bodies.
			var pids: Array = ["player"] if Procedures.is_player_only(ail) else (Procedures.monster_patients() if Procedures.is_monster_only(ail) else Procedures.human_patients())
			for pid in pids:
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
	print("[warmup] built and drew everything once in %d ms (furniture kinds %d ms)" % [Time.get_ticks_msec() - started, warm_parts_ms])


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
