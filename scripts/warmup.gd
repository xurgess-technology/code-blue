class_name Warmup
extends RefCounted
## Removes first-time hitches.
##
## Measured on a Radeon 890M: the first patient body cost 107 ms to build, the first
## Discharged 119 ms, the first anesthetic vial 37 ms, and every surgery step 70 to 150 ms,
## because each new kind of material has to be compiled. Worse, Godot frees a material's
## shader as soon as nothing uses it, so a step's minigame paid that cost again every time.
##
## Once per launch (main.gd runs it behind the launch printout, scripts/launch_screen.gd), this
## builds one of everything, shows it to the camera for a few frames, then keeps it all alive but
## hidden. After that the same things build in a millisecond or two and draw without compiling.
## The work is cut into slices of about SLICE_MS with a frame between them, so the printout keeps
## moving; `progress` (optional) is called with a stage name and a detail as each part finishes.

const RENDER_FRAMES := 8
const SLICE_MS := 30

const BodyScript := preload("res://scripts/patient_body.gd")
const MonsterModel := preload("res://scripts/monsters/monster_model.gd")
const DevGun := preload("res://scripts/dev/dev_gun.gd")  # DEV HOOK
const LootTable := preload("res://scripts/economy/loot_table.gd")  # INVENTORY HOOK
const EconomyScript := preload("res://scripts/economy/economy.gd")  # INVENTORY HOOK
const ExteriorScript := preload("res://scripts/level/exterior.gd")  # the hospital's front
const PlayerBodyScript := preload("res://scripts/downed/player_body.gd")  # DOWNED HOOK
const PlayerTableScript := preload("res://scripts/downed/player_table.gd")  # DOWNED HOOK
const OrScreenScript := preload("res://scripts/orscreen/or_screen.gd")  # ORSCREEN HOOK
const BrainsScript := preload("res://scripts/brains/brains.gd")  # SWEEP 3 HOOK (brains)
const DoorScript := preload("res://scripts/doors/door.gd")  # DOORS HOOK
const DoorModels := preload("res://scripts/doors/door_models.gd")  # DOORS HOOK
const HospitalBuilderScript := preload("res://scripts/hospital_builder.gd")  # DOORS HOOK
const HumanModelScript := preload("res://scripts/human/human_model.gd")  # HUMAN HOOK
const TerminalModelScript := preload("res://scripts/database/terminal_model.gd")  # HUB REDESIGN


## Run once. Safe to call again; later calls return immediately.
static func run(game: Node, progress: Callable = Callable(), ready_to_draw: Callable = Callable(), may_work: Callable = Callable()) -> void:
	if game.has_meta("warmed_up"):
		return
	game.set_meta("warmed_up", true)
	var tree := game.get_tree()
	var started := Time.get_ticks_msec()
	var slice := {"t": Time.get_ticks_msec(), "tree": tree, "may_work": may_work}

	# tools/*.gd wait for this node to go away before they start driving the game.
	var cover := Node.new()
	cover.name = "WarmupCover"
	game.get_parent().add_child(cover)
	# Sound effects go quiet (the look-alike phone rings, minigames make noise). Ambience, music and
	# the UI bus (the launch printout, the loading screen) keep playing.
	var muted := {}
	for bus_name in [Audio.BUS_SFX]:
		var bi := AudioServer.get_bus_index(bus_name)
		if bi >= 0:
			muted[bi] = AudioServer.is_bus_mute(bi)
			AudioServer.set_bus_mute(bi, true)

	var root := Node3D.new()
	root.name = "WarmupKeepAlive"
	game.add_child(root)
	var shelf := Node3D.new()
	root.add_child(shelf)

	# No frame breaks until the patients: this part is a couple of seconds of script at most, and at
	# launch it runs before the first frame, while Godot's boot splash is still up. (The renderer's
	# own one-time setup, ~2.5 s on the first real 3D frames, can't be moved or split; the launch
	# printout covers it with its still "connecting" page.)
	# Items
	var x := -0.9
	for kind in Items.ITEMS.keys():
		for n in ([1, 3] if Items.is_consumable(kind) else [1]):
			var m := ItemModels.make(kind, n)
			shelf.add_child(m)
			m.position = Vector3(x, 0.35, 0.0)
			x += 0.26

	# INVENTORY HOOK: the teal / gold rim overlay on stacks, every loot kind, and (pharmacy chunk 3)
	# the pharmacy window and the furnace.
	for kind in Items.ITEMS.keys() + LootTable.kinds():
		var tm := ItemModels.make_tinted(kind, 1)
		shelf.add_child(tm)
		tm.position = Vector3(x, 0.05, 0.3)
		x += 0.2
	_inert(shelf)
	_report(progress, "items", Items.ITEMS.size())
	EconomyScript.warm(shelf)
	ExteriorScript.warm(shelf)   # the front: concrete, window glass, sign letters
	_inert(shelf)
	_report(progress, "economy")
	AimHighlight.warm(shelf)   # AFFORDANCE HOOK: the aim-highlight rim shader (scripts/aim_highlight.gd)
	OrScreenScript.warm(shelf)  # ORSCREEN HOOK: the wall monitor's glass shader and viewport
	# HUB REDESIGN: the database terminal's bigger desk, and (the more expensive part) its live
	# camera-mirror SubViewport and material.
	var term: Node3D = TerminalModelScript.make_terminal()
	shelf.add_child(term)
	term.position = Vector3(x, -0.9, 0.5)
	x += 1.4
	# SWEEP 3 HOOK (combat): the syringe the jab draws (its glass is alpha-blended).
	var syringe: Node3D = preload("res://scripts/combat/combat.gd").make_syringe()
	shelf.add_child(syringe)
	syringe.position = Vector3(x, 0.3, 0.3)
	_inert(shelf)
	_report(progress, "terminal")
	BrainsScript.warm(shelf)  # SWEEP 3 HOOK (brains): the blender, Echo's ghosts and veil, Hive Eyes' screen
	_inert(shelf)
	_report(progress, "brains")
	# POCKETS HOOK: the Factory's and the Restaurant's meshes, textures and materials, and a stub copy.
	preload("res://scripts/level/pockets/pocket_spaces.gd").warm(shelf)
	_inert(shelf)
	_report(progress, "pockets")
	# HANDS HOOK: the first-person forearms, hands and torch (their skin, sleeve and lens materials, on
	# the hands layer the flashlight skips). The wind-ups build nothing new: they pose these and the
	# syringe above.
	var fp_arm: Node3D = preload("res://scripts/hands/fp_arms.gd").make_arm(-1.0, C.PLAYER_COLORS[0])
	shelf.add_child(fp_arm)
	fp_arm.position = Vector3(x + 0.2, 0.3, 0.3)
	var fp_torch: Node3D = preload("res://scripts/hands/fp_arms.gd").make_torch()
	shelf.add_child(fp_torch)
	fp_torch.position = Vector3(x + 0.4, 0.3, 0.3)
	_inert(shelf)
	_report(progress, "hands")
	# Draw this first part for a few frames. At launch these are the printout's still "connecting"
	# frames, and nothing here waits on may_work: the renderer's one-time setup lands here anyway.
	for i in 3:
		await tree.process_frame

	# Human patients next, still before the printout starts moving. The amputation variants read mesh
	# data back from the GPU (Bob's forearm cut, the seal's paddle), which makes every shader still
	# compiling in the background finish first: measured as a 3.4 s frame. Here it lands on the
	# still page instead of in the middle of the printing.
	var bodies := {}
	var bx := -0.6
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
			# HUMAN HOOK: Bob's Blender model bakes his severed forearm the same way.
			if pid in ["seal", "bob"] and ail == "amputation" and b.has_method("make_severed_limb"):
				var sev: Node3D = b.make_severed_limb(shelf)
				if sev != null:
					sev.position = Vector3(bx, -0.3, -0.8)
					sev.scale = Vector3.ONE * 0.5
	# From here on the shelf is hidden: nothing built while the printout is animating draws, and so
	# compiles, until the final frames below, and work only runs when may_work allows.
	shelf.visible = false
	await _frame(slice)
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
			await _slice(slice)
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
		await _slice(slice)
	_inert(shelf)
	_report(progress, "patients", Procedures.human_patients().size())
	# HUMAN HOOK: every Blender surgeon a player can wear (their maps, the tinted cloth shader), posed
	# by the idle clip, so a teammate joining does not hitch.
	for v in HumanModelScript.SURGEONS:
		var hb: Node3D = HumanModelScript.spawn(v, C.PLAYER_COLORS[1])
		if hb != null:
			shelf.add_child(hb)
			hb.position = Vector3(bx, -0.3, -0.8)
			hb.scale = Vector3.ONE * 0.5
			HumanModelScript.show_piece(hb, "Human_TopRolled", true)
			HumanModelScript.show_piece(hb, "Human_GashSkin", true)
			var hap := HumanModelScript.anim_player(hb)
			if hap != null and hap.has_animation("Idle"):
				hap.play("Idle")
			bx += 0.4
		await _slice(slice)
	var ptable := PlayerTableScript.make()
	shelf.add_child(ptable)
	ptable.position = Vector3(0.0, -1.4, -2.2)
	ptable.scale = Vector3.ONE * 0.5
	_inert(shelf)
	_report(progress, "staff", HumanModelScript.SURGEONS.size())
	await _frame(slice)

	# Monsters: the visual model only, so nothing starts thinking or moving. NURSE HOOK: "night_nurse"
	# builds her Blender model (monster/night_nurse: its two skinned materials, shadow mesh and the
	# first load of its six maps), so the first Night Nurse of a session does not hitch.
	var mx := -1.0
	for kind in ["discharged", "night_nurse", "hive"]:  # SWEEP 3 HOOK (monsters): the Hive
		var model: Node3D = MonsterModel.new()
		shelf.add_child(model)
		model.setup(kind)
		model.position = Vector3(mx, -1.6, -2.0)
		model.scale = Vector3.ONE * 0.5
		mx += 1.0
		await _slice(slice)
	_inert(shelf)
	_report(progress, "monsters")

	# DEV HOOK (scripts/dev): the dev gun, its tracers and the target dummy.
	DevGun.warm(shelf)
	await _slice(slice)

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
	_inert(shelf)
	_report(progress, "crew")
	await _frame(slice)

	# DOORS HOOK: every furniture kind's shared meshes (the first level only built the kinds it uses;
	# the wing loader's thread needs them all), then one door of every kind (the laminate, steel and
	# glass leaves, the frames, the gate's lamp in each state), as look-alikes: no collision, not
	# interactable.
	var wp0 := Time.get_ticks_msec()
	var kinds: Array = HospitalBuilderScript.part_kinds()
	for kind in kinds:
		HospitalBuilderScript.warm_part(String(kind))
		await _slice(slice)
	var warm_parts_ms := Time.get_ticks_msec() - wp0
	_inert(shelf)
	_report(progress, "furniture", kinds.size())
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
		await _slice(slice)
	_inert(shelf)
	_report(progress, "doors")
	await _frame(slice)

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
				await _slice(slice)

	# Some steps build their geometry on a worker thread (the forceps wound channel). Wait for
	# it to land, or its material is never drawn here and compiles when the real step begins.
	for mg in games:
		var task = mg.get("_channel_task")
		if task != null and int(task) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(task))
			mg.set("_channel_task", -1)
	_inert(shelf)
	_report(progress, "procedures", games.size())
	await _frame(slice)

	# Everything is built. The caller may hold the first draw of it (a few frames, some long) for a
	# moment where a pause can't be seen: the launch printout waits for its stamped page.
	_report(progress, "built")
	while ready_to_draw.is_valid() and not ready_to_draw.call():
		await tree.process_frame
	shelf.visible = true
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
	for bi in muted.keys():
		AudioServer.set_bus_mute(bi, muted[bi])
	cover.queue_free()
	_inert(shelf)
	_report(progress, "done")
	print("[warmup] built and drew everything once in %d ms (furniture kinds %d ms)" % [Time.get_ticks_msec() - started, warm_parts_ms])


## A frame once the current slice has run for SLICE_MS.
static func _slice(s: Dictionary) -> void:
	if Time.get_ticks_msec() - int(s.t) >= SLICE_MS:
		await _frame(s)


## A frame, then (if the caller gave may_work) more frames until the caller says work may go on:
## the launch printout only lets it run while its print head is idle, so a slow frame never lands
## in the middle of a line being printed.
static func _frame(s: Dictionary) -> void:
	await (s.tree as SceneTree).process_frame
	var may: Callable = s.get("may_work", Callable())
	while may.is_valid() and not may.call():
		await (s.tree as SceneTree).process_frame
	s.t = Time.get_ticks_msec()


## Look-alikes only: nothing on the shelf may answer find_interactable() or collide. It is built
## before any level exists, so it comes first in the "interactable" group and would otherwise
## shadow the real fax terminal, furnace or phone with the same interact id.
static func _inert(shelf: Node) -> void:
	for n in shelf.find_children("*", "", true, false):
		if n.is_in_group("interactable"):
			n.remove_from_group("interactable")
		if n.has_meta("interact_id"):
			n.remove_meta("interact_id")
		if n is CollisionObject3D:
			(n as CollisionObject3D).collision_layer = 0
			(n as CollisionObject3D).collision_mask = 0
		if n is Area3D:
			n.set_deferred("monitoring", false)
			n.set_deferred("monitorable", false)


static func _report(progress: Callable, stage: String, detail = null) -> void:
	if progress.is_valid():
		progress.call(stage, detail)
