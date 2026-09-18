extends Node
## Grafting part one (docs/GRAFTING.md, chunk A): the eyes, the specimen vat and Eyeball Extraction.
##
##   godot --headless --fixed-fps 60 --path . tools/grafttest.tscn
##
## Headless checks, solo in a normal hospital (seed 4242) with dev mode on: the data, three empty vats
## and the scalpel and spoon on the lab wall / in the OR's storage, an eye spoiling outside a vat and
## not inside, the vat's put-in / take-out / carry / set-down paths, a strapped Hive taking the scalpel
## into Eyeball Extraction and giving up its eye, and an eye selling at the furnace for less as it spoils.

var main: Node3D
var game: Game
var dev: Node
var me: Player
var t := 0.0
var _done := false
var _failures: Array = []


func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	dev = game.dev
	if main.launching:
		await main.launched
	main.menu.hide_menu()
	Net.start_solo("Tester")
	_data_checks()
	await _run()
	_finish()


func _physics_process(delta: float) -> void:
	t += delta
	if t > 900.0 and not _done:
		_check(false, "timed out")
		_finish()


func _data_checks() -> void:
	for k in ["scalpel", "eye_spoon", "specimen_vat"]:
		_check(Items.exists(k), "%s is an item" % k)
	_check(Items.is_surgical("scalpel") and not Items.is_consumable("scalpel") and Items.is_surgical("eye_spoon"), "scalpel and eye spoon are surgical, reusable tools")
	_check(Items.is_bulky("specimen_vat") and Items.slots_needed("specimen_vat") == 2, "the vat takes both hands")
	_check(Items.is_loot("eye_hive") and Items.is_loot("eye_surgeon") and Eyes.is_eye("eye_hive"), "both eyes are sellable loot")
	_check(Eyes.label("eye_hive", "") == "Hive eye" and Eyes.label("eye_surgeon", "Zach") == "Zach's eye", "eye labels")
	_check(Eyes.spoil_factor(0.0) == 1.0 and Eyes.spoil_factor(Eyes.FRESH_SECONDS) == 1.0 and Eyes.is_spoiled_factor(Eyes.spoil_factor(Eyes.ROTTEN_SECONDS)), "an eye is fresh, then spoils")
	var st: Array = Procedures.steps("eye_extraction")
	_check(st.size() == 3 and st[0].item == "scalpel" and st[1].item == "eye_spoon" and st[2].item == "scalpel" and st[0].site == "eye", "extraction steps: scalpel, spoon, scalpel")
	_check(Procedures.is_monster_only("eye_extraction") and not Procedures.patient_ailments().has("eye_extraction"), "extraction is monster-only")
	var packed := Eyes.pack("eye_surgeon", "Zach", 12.4, 45)
	var u := Eyes.unpack(packed)
	_check(String(u.get("kind", "")) == "eye_surgeon" and String(u.owner) == "Zach" and int(u.age) == 12 and int(u.value) == 45 and Eyes.unpack("").is_empty(), "vat contents round-trip")


func _run() -> void:
	game.start_session(4242)
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _seconds(0.5)
	me = game.local_player()
	me.bot_active = true
	game.set_dev_tools(true, me)
	dev.request("god", {"on": true})
	dev.request("no_game_over", {"on": true})
	dev.request("monsters_off", {"on": true})
	game.clock_in()
	await _until(func(): return game.phase == Game.Phase.SHIFT, 60.0)
	game.loop.first_called = true
	game.loop._end_call()
	game.loop.extra_done = true
	dev.request("clear_patient")
	await _frames(3)
	var vats: Node = game.vats

	# ---- the lab wall and the storage
	_check(vats.spots.size() == 6, "the lab has six vat spots (%d)" % vats.spots.size())
	var vat_items := _vat_items()
	_check(vat_items.size() == 3, "three vats stand on the lab wall (%d)" % vat_items.size())
	var all_empty := true
	for v in vat_items:
		all_empty = all_empty and String(v.x) == ""
	_check(all_empty, "they are empty")
	_check(game.shelf_count("scalpel") == 1 and game.shelf_count("eye_spoon") == 1, "a scalpel and an eye spoon wait in the OR's storage")
	_check(not vats.spot_free(0) and not vats.spot_free(2) and vats.spot_free(3), "spots 0-2 hold vats, 3-5 are free")

	# ---- spoiling, in and out of a vat
	var vat: WorldItem = vat_items[0]
	me.teleport(game._floor_at(vat.global_position + Vector3(0.0, 0.0, 0.9)))
	await _frames(2)
	var now := float(game.world_time)
	game.give_hand(me, "eye_hive", 1)
	var eh: int = me.selected_head()
	me.slots[eh]["bt"] = now - 20.0
	me.slots[eh]["v"] = 100
	_check(vats.item_prompt(me, vat).begins_with("Put Hive eye in the vat"), "aimed at a vat with an eye: '%s'" % vats.item_prompt(me, vat))
	game.pickup_item(me, vat)   # E on the vat with an eye selected
	await _frames(2)
	var got := Eyes.unpack(String(vat.x))
	_check(String(got.get("kind", "")) == "eye_hive" and absf(float(got.get("age", -1.0)) - 20.0) < 1.5 and int(got.get("value", 0)) == 100, "the eye went into the vat with its age frozen (%s)" % str(got))
	_check(String(me.slots[eh].kind) == "" and world_has(vat), "the eye left the hand; the vat stayed on the bench")
	var loose: Node = game._spawn_item("eye_hive", 1, Transform3D(Basis(), me.global_position + Vector3(0.4, 1.0, 0.0)), WorldItem.State.LOOSE)
	loose.value = 100
	loose.bt = now - 20.0
	game.world_time += 400.0
	await _frames(3)
	_check(Eyes.condition(vats.eye_factor(loose)) == "spoiled" and Eyes.is_spoiled_factor(vats.eye_factor(loose)), "an eye left outside spoils (factor %.2f)" % vats.eye_factor(loose))
	_check(vats.eye_value({"v": 100, "bt": float(game.world_time) - 400.0}) < 40 and vats.eye_value({"v": 100, "bt": float(game.world_time)}) == 100
		and game.furnace_value("eye_hive", {"v": 100, "bt": float(game.world_time) - 400.0}) < 40, "and it sells for less at the furnace")
	game.tell(me, "")
	vats.take_out(me, String(vat.get_meta("interact_id")))   # V aimed at the vat
	await _frames(2)
	var out_i := -1
	for i in me.slots.size():
		if String(me.slots[i].kind) == "eye_hive":
			out_i = i
	_check(out_i >= 0 and String(vat.x) == "", "V takes the eye back out (slot %d, vat '%s')" % [out_i, String(vat.x)])
	_check(out_i >= 0 and absf(vats.eye_age(me.slots[out_i]) - 20.0) < 1.5 and not Eyes.is_spoiled_factor(vats.eye_factor(me.slots[out_i])),
		"it was not spoiling inside: still fresh after 400 s in the vat (age %.1f)" % (vats.eye_age(me.slots[out_i]) if out_i >= 0 else -1.0))
	# Carry the vat (an eye selected would go in instead), put the eye back in with both in hand, set it down.
	me.selected = 3
	game.pickup_item(me, vat)
	await _frames(2)
	var vh := Vats.held_vat(me)
	_check(vh >= 0 and not world_has(vat), "the vat is carried in both hands (slot %d)" % vh)
	var eye_slot := -1
	for i in me.slots.size():
		if String(me.slots[i].kind) == "eye_hive":
			eye_slot = i
	me.selected = eye_slot
	_check(vats.hand_prompt(me).begins_with("Put Hive eye in the vat"), "eye and vat both in hand: '%s'" % vats.hand_prompt(me))
	vats.hand_put(me)
	await _frames(2)
	_check(String(me.slots[vh].get("x", "")) != "" and String(me.slots[eye_slot].kind) == "", "E aimed at nothing puts the carried eye into the carried vat")
	vats.set_down(me, 3)
	await _frames(3)
	var placed: WorldItem = null
	for v in _vat_items():
		if v.global_position.distance_to(vats.spots[3].position) < 0.1:
			placed = v
	_check(placed != null and Eyes.unpack(String(placed.x)).get("kind", "") == "eye_hive" and Vats.held_vat(me) < 0, "set down on a free bench spot with the eye still inside")
	_check(not vats.spot_free(3), "that spot is taken now")
	_clear_hands()

	# ---- Eyeball Extraction on a strapped Hive
	dev.request("strap_monster", {"kind": "hive", "sedation": 1.0})
	await _frames(3)
	var c := _monster_case("hive")
	_check(not c.is_empty() and String(c.ailment_id) == "dissection", "a strapped Hive starts as a dissection")
	if c.is_empty():
		return
	var table := int(c.table)
	var body = game.body_for_table(table)
	_check(body != null and body.has_site("eye"), "the Hive body has an eye site")
	var eye_node = body.parts.get("eye_node") if body != null else null
	_check(eye_node != null and (eye_node as Node3D).visible, "its left eye is in the socket")
	me.teleport(game._floor_at(game.table_position(table) + Vector3(0, 0, 1.0).rotated(Vector3.UP, game.table_yaw_of(table))))
	me.bot_move = Vector2.ZERO
	_clear_hands()
	var p0 := String(game._table_prompt(me, table))
	_check(p0.begins_with("!Hold the bone saw") and p0.contains("scalpel"), "empty-handed at a fresh Hive the prompt says what to hold ('%s')" % p0)
	game.give_hand(me, "bone_saw", 1)
	var p1 := String(game._table_prompt(me, table))
	_check(p1.begins_with("Operate: Saw open the skull"), "the bone saw offers dissection ('%s')" % p1)
	_clear_hands()
	var panels: Array = load("res://scripts/orscreen/or_screen_model.gd").build(game).panels
	var kinds := []
	for pn in panels:
		if String(pn.get("patient_id", "")) == "hive":
			for sp in pn.supplies:
				kinds.append(String(sp.kind))
	_check(not panels.is_empty() and (kinds.has("scalpel") and kinds.has("eye_spoon") and kinds.has("bone_saw")), "the OR screen lists both plans' tools for a fresh Hive (%s)" % str(kinds))
	game.give_hand(me, "scalpel", 1)
	await _frames(2)
	var prompt := String(game._table_prompt(me, table))
	_check(prompt.begins_with("Operate: Cut around the eye"), "holding the scalpel offers extraction ('%s')" % prompt)
	game.surgery_bot_skill = 1.0
	var sys = game.surgery_for_table(table)
	game._proxy_used(game.table_interact_id(table), me)
	var began := await _until(func(): return sys.is_local_operating() and sys.mg != null, 5.0)
	_check(began and String(c.ailment_id) == "eye_extraction" and String(sys.mg.get("variant")) == "cut", "E with the scalpel makes the case Eyeball Extraction and plays the cut")
	var ok1 := await _until(func(): return int(c.get("step_index", 0)) >= 1, 40.0)
	_check(ok1 and bool(c.flags.get("eye_cut", false)), "the cut finishes (flags %s)" % str(c.flags))
	await _seconds(0.5)
	game.give_hand(me, "eye_spoon", 1)
	game._proxy_used(game.table_interact_id(table), me)
	var began2 := await _until(func(): return sys.is_local_operating() and sys.mg != null and String(sys.mg.get("variant")) == "scoop", 5.0)
	_check(began2, "then the spoon step (scoop)")
	var ok2 := await _until(func(): return int(c.get("step_index", 0)) >= 2, 40.0)
	_check(ok2 and bool(c.flags.get("eye_out", false)), "the scoop finishes (flags %s)" % str(c.flags))
	await _frames(3)
	_check(eye_node != null and not (eye_node as Node3D).visible, "the socket is empty once the eye is scooped")
	await _seconds(0.5)
	game.give_hand(me, "scalpel", 1)
	me.selected = _slot_of("scalpel")
	game._proxy_used(game.table_interact_id(table), me)
	var began3 := await _until(func(): return sys.is_local_operating() and sys.mg != null and String(sys.mg.get("variant")) == "snip", 5.0)
	_check(began3, "then the nerve snip")
	var ok3 := await _until(func(): return String(c.get("state", "")) != "on_table", 60.0)
	_check(ok3 and String(c.state) == "stable" and bool(c.flags.get("eye_removed", false)), "the snip wins the case (state %s, flags %s)" % [String(c.get("state", "")), str(c.flags)])
	var le: Dictionary = game.dissection.last_eye
	_check(not le.is_empty() and String(le.kind) == "eye_hive", "the Hive's eye is handed over (%s)" % str(le.keys()))
	var in_hand := -1
	for i in me.slots.size():
		if String(me.slots[i].kind) == "eye_hive":
			in_hand = i
	_check(in_hand >= 0 or (le.get("node") != null and is_instance_valid(le.get("node"))), "the eye came out in the operator's hand (or on the tray)")
	_check(in_hand >= 0 and me.slots[in_hand].has("bt") and int(me.slots[in_hand].get("v", 0)) > 0, "it is a live eye with a spoil clock and a value")
	await _frames(3)
	_check(body != null and bool(body.get("_flat")), "the Hive dies on the table")


func _vat_items() -> Array:
	var out := []
	for it in game.world_items.values():
		if is_instance_valid(it) and String(it.kind) == "specimen_vat":
			out.append(it)
	return out


func world_has(it) -> bool:
	return is_instance_valid(it) and game.world_items.has(it.item_id)


func _slot_of(kind: String) -> int:
	for i in me.slots.size():
		if String(me.slots[i].kind) == kind:
			return i
	return 0


func _clear_hands() -> void:
	for i in me.slots.size():
		me.slots[i] = Player.empty_slot()


func _monster_case(kind: String) -> Dictionary:
	for c in game.cases:
		if String(c.get("patient_id", "")) == kind:
			return c
	return {}


func _check(ok: bool, what: String) -> void:
	print("[grafttest] t=%.1f %s  %s" % [t, "PASS" if ok else "FAIL", what])
	if not ok:
		_failures.append(what)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("[grafttest] ------------------------------------------")
	print("[grafttest] result=%s failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _failures.size()])
	for f in _failures:
		print("[grafttest]   FAILED: ", f)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	var end := t + s
	while t < end:
		await get_tree().physics_frame


func _until(cond: Callable, timeout: float) -> bool:
	var end := t + timeout
	while t < end:
		if cond.call():
			return true
		await get_tree().physics_frame
	return bool(cond.call())
