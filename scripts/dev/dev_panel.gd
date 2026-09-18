extends CanvasLayer
## The dev panel. F1 (or the key left of 1) toggles it anywhere in a session with dev mode on (the
## pharmacy fax's secret order); the mouse is free while it is open. Every world change goes through
## game.dev.request(), so on a client it is sent to the host. Local only: graphics quality, going
## somewhere (you own your position), this machine's database and tips.

const ACCENT := Color(0.3, 0.95, 0.8)
const DIM := Color(0.6, 0.68, 0.7)
const PANEL_W := 400.0
const LootTableScript := preload("res://scripts/economy/loot_table.gd")
const DevRoomScript := preload("res://scripts/dev/dev_room.gd")   # NURSE HOOK: pace names
const MonsterPages := preload("res://scripts/database/monster_pages.gd")
const OFF := Color(1.0, 0.4, 0.35)
const FreeCamScript := preload("res://scripts/dev/free_cam.gd")

var game: Node = null
var main: Node = null

var _root: PanelContainer
var _open := false
var _refresh_t := 0.0
var _c := {}              # control name -> Control
var _bots_box: VBoxContainer
var _bots_sig := ""
var _bot_rows := {}       # bot id -> {status: Label, order: OptionButton, item: OptionButton, to: OptionButton}
var _dragging := {}
var _places: Array = []      # [{name, pos}] for "Go to"
var _places_level: Node = null
var free_cam: Camera3D = null   # scripts/dev/free_cam.gd; local only, P swaps camera <-> surgeon


func setup(g: Node, m: Node) -> void:
	game = g
	main = m
	layer = 8
	free_cam = FreeCamScript.new()
	add_child(free_cam)
	_build()
	_root.visible = false


func is_open() -> bool:
	return _open


func toggle(on = null) -> void:
	_open = (not _open) if on == null else bool(on)
	_root.visible = _open
	if _open:
		_bots_sig = ""
		_refresh()
	else:
		get_viewport().gui_release_focus()


func _in_room() -> bool:
	return game != null and game.dev_on() and game.phase != game.Phase.MENU


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F1 or event.physical_keycode == KEY_QUOTELEFT:
		if _in_room():
			toggle()
			get_viewport().set_input_as_handled()
	elif _open and event.physical_keycode == KEY_ESCAPE:
		toggle(false)
		get_viewport().set_input_as_handled()
	elif event.physical_keycode == KEY_P and free_cam.is_on() and not _open \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		free_cam.swap()
		get_viewport().set_input_as_handled()


## True while the dev free camera should be the view (main.gd keeps it current).
func free_cam_on() -> bool:
	return free_cam != null and free_cam.is_on()


func _set_free_cam(on: bool) -> void:
	if on == free_cam.is_on():
		return
	if on:
		free_cam.start(game)
	else:
		free_cam.stop()


func _process(delta: float) -> void:
	if free_cam.is_on() and not _in_room():
		free_cam.stop()
	if _open and not _in_room():
		toggle(false)
	if not _open:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 0.2
		_refresh()


# =========================================================================
# building
# =========================================================================

func _build() -> void:
	_root = PanelContainer.new()
	_root.name = "DevPanel"
	_root.anchor_top = 0.0
	_root.anchor_bottom = 1.0
	_root.offset_left = 10
	_root.offset_top = 10
	_root.offset_right = 10 + PANEL_W
	_root.offset_bottom = -10
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.05, 0.07, 0.93)
	sb.border_color = ACCENT.darkened(0.35)
	sb.border_width_left = 3
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 14
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_root.add_theme_stylebox_override("panel", sb)
	add_child(_root)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	scroll.add_child(col)

	var title := Label.new()
	title.text = "DEV MODE"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT)
	var top := _row(col)
	top.add_child(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var off := _button(top, "DEV MODE OFF", func(): _req("dev_off"); toggle(false))
	off.add_theme_color_override("font_color", OFF)
	off.add_theme_color_override("font_hover_color", OFF.lightened(0.3))
	_c["role"] = _label(col, "", 12, DIM)

	# ---- you
	_section(col, "You")
	var you := _row(col)
	_c["god"] = _check(you, "God mode", func(on): _req("god", {"on": on}))
	_c["noclip"] = _check(you, "Noclip", func(on): _req("noclip", {"on": on}))
	_c["gun"] = _check(you, "Dev gun", func(on): _req("gun", {"on": on}))
	var you2 := _row(col)
	_button(you2, "Down me", func(): _req("down_me"))   # downed hook
	_button(you2, "All abilities", func(): _req("abilities"))
	_button(you2, "Revive all", func(): _req("revive_all"))
	_label(col, "Gun: left click kills, right click downs. Noclip: Space up, Ctrl down.", 11, DIM)
	var fc := _row(col)
	_c["free_cam"] = _check(fc, "Free camera", func(on): _set_free_cam(on))
	_c["free_cam_mode"] = _label(fc, "", 12, DIM)
	_label(col, "Free camera: P swaps between flying the camera and walking the surgeon. WASD, mouse, Space up, Ctrl down, Shift fast.", 11, DIM)

	# ---- world
	_section(col, "World")
	var ts := _row(col)
	_label(ts, "Time", 13, Color.WHITE).custom_minimum_size.x = 44
	var slider := HSlider.new()
	slider.min_value = 0.05
	slider.max_value = 3.0
	slider.step = 0.05
	slider.value = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 20
	slider.drag_started.connect(func(): _dragging["ts"] = true)
	slider.drag_ended.connect(func(_c2): _dragging.erase("ts"); _req("time_scale", {"v": slider.value}))
	slider.value_changed.connect(func(v): (_c["ts_label"] as Label).text = "%.2fx" % v)
	ts.add_child(slider)
	_c["ts"] = slider
	_c["ts_label"] = _label(ts, "1.00x", 13, ACCENT)
	(_c["ts_label"] as Label).custom_minimum_size.x = 48
	var ts2 := _row(col)
	for v in [0.1, 0.25, 0.5, 1.0, 2.0]:
		_button(ts2, "%sx" % str(v), func(): _req("time_scale", {"v": v}))
	var w2 := _row(col)
	_c["freeze"] = _check(w2, "Infinite vitals", func(on): _req("freeze", {"on": on}))
	_c["auto_revive"] = _check(w2, "Auto-revive", func(on): _req("auto_revive", {"on": on}))
	var w2b := _row(col)
	_c["monsters_off"] = _check(w2b, "No monsters", func(on): _req("monsters_off", {"on": on}))
	_c["no_game_over"] = _check(w2b, "No game over", func(on): _req("no_game_over", {"on": on}))
	var w3 := _row(col)
	_label(w3, "Difficulty (shift)", 13, Color.WHITE)
	var shift := SpinBox.new()
	shift.min_value = 1
	shift.max_value = 20
	shift.value = 1
	shift.custom_minimum_size.x = 90
	w3.add_child(shift)
	_c["shift"] = shift
	_button(w3, "Set", func(): _req("difficulty", {"shift": int(shift.value)}))
	var w4 := _row(col)
	_label(w4, "Graphics", 13, Color.WHITE)
	var gfx := _option(w4, ["Low", "Medium", "High"])
	gfx.item_selected.connect(_set_quality)
	_c["gfx"] = gfx

	# ---- going places (local: you own your position)
	_section(col, "Go to")
	var g1 := _row(col)
	var places := _option(g1, [])
	places.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_c["places"] = places
	_button(g1, "Go", func(): _go_place(places.selected))
	var g2 := _row(col)
	_button(g2, "Dev room", func(): _go_dev_room())
	_button(g2, "Start", func(): game.dev.pocket_go(false))
	var g3 := _row(col)
	_c["lights"] = _check(g3, "Dev room lights", func(on): _req("lights", {"on": on}))
	_c["pen"] = _check(g3, "Pen gate open", func(on): _req("pen", {"open": on}))
	_label(col, "The dev room is behind the locked door in the OR supply closet.", 11, DIM)

	# ---- the shift loop
	_section(col, "Shift")
	var sh1 := _row(col)
	_button(sh1, "Clock in", func(): _req("clock_in"))
	_button(sh1, "Clock out (force)", func(): _req("clock_out"))
	var sh2 := _row(col)
	_button(sh2, "Phone call", func(): _req("phone"))
	_button(sh2, "Extra patient", func(): _req("extra_patient"))
	_button(sh2, "Skip grace", func(): _req("skip_grace"))
	var sh3 := _row(col)
	_button(sh3, "Skip to table", func(): _req("skip_to_table"))
	_c["shift_label"] = _label(col, "", 12, DIM)

	# ---- this machine's own database and tips
	_section(col, "Database and tips (this machine)")
	var db1 := _row(col)
	_button(db1, "Unlock every entry", func(): _database(true))
	_button(db1, "Reset database", func(): _database(false))
	var db2 := _row(col)
	_button(db2, "Reset tips", func():
		if main != null and main.get("tips") != null:
			main.tips.reset_seen()
			game.say("Every tip shows again.", 2.0))

	# ---- spawning
	_section(col, "Spawn")
	var s1 := _row(col)
	var item_names: Array = Items.ITEMS.keys() + LootTableScript.kinds()  # inventory: loot too
	var items := _option(s1, item_names.map(func(k): return Items.display_name(k)))
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var count := SpinBox.new()
	count.min_value = 1
	count.max_value = 20
	count.value = 3
	count.custom_minimum_size.x = 80
	s1.add_child(count)
	_button(s1, "Spawn item", func(): _req("spawn_item", {"kind": item_names[items.selected], "count": int(count.value)}))
	var s2 := _row(col)
	var monsters := _option(s2, ["The Walk-In", "The Discharged", "The Night Nurse"])  # SWEEP 3 HOOK (monsters): the Walk-In
	monsters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kinds := ["walk_in", "discharged", "night_nurse"]
	_button(s2, "In the dev room pen", func(): _req("spawn_monster", {"kind": kinds[monsters.selected], "where": "pen"}))
	_button(s2, "In front", func(): _req("spawn_monster", {"kind": kinds[monsters.selected], "where": "front"}))
	var s3 := _row(col)
	_button(s3, "Kill all monsters", func(): _req("kill_monsters"))
	_c["monster_count"] = _label(s3, "", 12, DIM)

	# ---- NURSE HOOK (night nurse model): watch her walk under a flashlight
	_section(col, "Night Nurse")
	var nn1 := _row(col)
	_c["nurse_ignore"] = _check(nn1, "Nurse ignores being watched", func(on): _req("nurse_ignore_watch", {"on": on}))
	_button(nn1, "Nurse in front", func(): _req("spawn_monster", {"kind": "night_nurse", "where": "front"}))
	var nn2 := _row(col)
	var walks := ["", "follow", "loop"]
	var walk := _option(nn2, ["Hunts players", "Follows me", "Walks a loop here"])
	walk.item_selected.connect(func(i): _req("nurse_walk", {"mode": walks[i]}))
	_c["nurse_walk"] = walk
	var pace := _option(nn2, DevRoomScript.NURSE_PACE_NAMES)
	pace.item_selected.connect(func(i): _req("nurse_pace", {"i": i}))
	_c["nurse_pace"] = pace
	_label(col, "Follows me: stops 2.5 m away, never attacks. A loop is a 6 x 3.5 m rectangle round where you stand, long side the way you face.", 11, DIM)

	# ---- POCKETS HOOK: a pocket space beside the dev room, and a way in and out
	_section(col, "Pocket spaces")
	var pk1 := _row(col)
	_button(pk1, "Factory", func(): _req("pocket", {"kind": "factory"}))
	_button(pk1, "Restaurant", func(): _req("pocket", {"kind": "restaurant"}))
	_button(pk1, "Remove", func(): _req("pocket", {"kind": ""}))
	var pk2 := _row(col)
	_button(pk2, "Go there", func(): game.dev.pocket_go(true))
	_button(pk2, "Back to the start", func(): game.dev.pocket_go(false))
	_label(col, "Builds the space beside the hospital for this session (no entrances to it).", 11, DIM)

	# ---- brains (SWEEP 3 HOOK, scripts/brains/brains.gd dev_request)
	_section(col, "Brains")
	var br1 := _row(col)
	_button(br1, "Spawn brain: Walk-In", func(): _req("br_spawn_brain", {"kind": "brain_walk_in"}))
	_button(br1, "Discharged", func(): _req("br_spawn_brain", {"kind": "brain_discharged"}))
	_button(br1, "Rotten", func(): _req("br_spawn_brain", {"kind": "brain_discharged", "age": 200.0}))
	var br2 := _row(col)
	_button(br2, "Give brain levels (+1)", func(): _req("br_levels", {"amount": 1.0}))
	_button(br2, "Reset", func(): _req("br_reset"))
	_button(br2, "Walk-In in front", func(): _req("br_walk_in"))

	# ---- money (inventory, sweep 2)
	_section(col, "Money")
	var mo1 := _row(col)
	for amt in [100, 1000, 10000, -1000]:
		_button(mo1, ("+$%d" if amt > 0 else "-$%d") % absi(amt), func(): _req("money", {"amount": amt}))
	_button(mo1, "Reset", func(): _req("money", {"reset": true}))
	_c["money_label"] = _label(col, "", 12, DIM)

	# ---- patient
	_section(col, "Patient")
	var p1 := _row(col)
	var pids: Array = Procedures.human_patients()  # SWEEP 3 HOOK (dissection): monsters strap below
	var aids: Array = Procedures.patient_ailments()  # downed hook: stitches is for players only
	var patients := _option(p1, pids.map(func(k): return Procedures.patient(k).name))
	var ailments := _option(p1, aids.map(func(k): return Procedures.ailment(k).name))
	patients.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ailments.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var p2 := _row(col)
	_button(p2, "Put on the table", func(): _req("patient", {"patient": pids[patients.selected], "ailment": aids[ailments.selected]}))
	_button(p2, "Flatlined", func(): _req("patient", {"patient": pids[patients.selected], "ailment": aids[ailments.selected], "dead": true}))
	_button(p2, "Clear tables", func(): _req("clear_patient"))
	var p3 := _row(col)
	_label(p3, "Vitals", 13, Color.WHITE).custom_minimum_size.x = 44
	var vit := HSlider.new()
	vit.min_value = 1
	vit.max_value = 100
	vit.step = 1
	vit.value = 100
	vit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vit.custom_minimum_size.y = 20
	vit.drag_started.connect(func(): _dragging["vit"] = true)
	vit.drag_ended.connect(func(_c2): _dragging.erase("vit"); _req("vitals", {"v": vit.value}))
	p3.add_child(vit)
	_c["vitals"] = vit
	_c["vitals_label"] = _label(p3, "100", 13, ACCENT)
	(_c["vitals_label"] as Label).custom_minimum_size.x = 40
	vit.value_changed.connect(func(v): (_c["vitals_label"] as Label).text = "%d" % int(v))
	# SWEEP 3 HOOK (dissection): strap a monster to a patient table, sedated or already waking.
	var pm := _row(col)
	_button(pm, "Strap Walk-In", func(): _req("strap_monster", {"kind": "walk_in"}))
	_button(pm, "Strap Discharged", func(): _req("strap_monster", {"kind": "discharged"}))
	_button(pm, "...waking", func(): _req("strap_monster", {"kind": "walk_in", "sedation": 0.4}))
	var p4 := _row(col)
	_button(p4, "Stock shelf", func(): _req("stock_shelf"))
	_button(p4, "Clear shelf", func(): _req("clear_shelf"))
	_c["case_label"] = _label(col, "", 12, DIM)

	# ---- bots
	_section(col, "Bots and dummies")
	var b1 := _row(col)
	_button(b1, "+ Bot", func(): _req("spawn_bot", {"kind": "bot"}))
	_button(b1, "+ Dummy", func(): _req("spawn_bot", {"kind": "dummy"}))
	_button(b1, "Remove all", func(): _req("remove_bots"))
	_bots_box = VBoxContainer.new()
	_bots_box.add_theme_constant_override("separation", 4)
	col.add_child(_bots_box)

	# ---- DOORS HOOK: every door, and the wings behind the gates
	_section(col, "Doors")
	_door_buttons(col)

	_label(col, "F1 or Esc closes this panel.", 11, DIM)


func _door_buttons(parent: Control) -> void:
	var d1 := _row(parent)
	_button(d1, "Open all doors", func(): _req("doors_all", {"open": true}))
	_button(d1, "Close all doors", func(): _req("doors_all", {"open": false}))
	var d2 := _row(parent)
	_button(d2, "Regenerate wings now", func(): _req("regen_wings"))
	_label(parent, "Hinged doors swing away from you on E.", 11, DIM)


func _section(parent: Control, text: String) -> void:
	var gap := Control.new()
	gap.custom_minimum_size.y = 4
	parent.add_child(gap)
	var l := _label(parent, text.to_upper(), 13, ACCENT)
	l.add_theme_constant_override("outline_size", 0)
	var line := ColorRect.new()
	line.color = ACCENT.darkened(0.6)
	line.custom_minimum_size.y = 1
	parent.add_child(line)


func _row(parent: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	parent.add_child(r)
	return r


func _label(parent: Control, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if parent is VBoxContainer else TextServer.AUTOWRAP_OFF
	parent.add_child(l)
	return l


func _check(parent: Control, text: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.add_theme_font_size_override("font_size", 14)
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _option(parent: Control, names: Array) -> OptionButton:
	var o := OptionButton.new()
	for n in names:
		o.add_item(String(n))
	o.add_theme_font_size_override("font_size", 13)
	o.focus_mode = Control.FOCUS_NONE
	parent.add_child(o)
	return o


# =========================================================================
# actions and refresh
# =========================================================================

func _req(action: String, args: Dictionary = {}) -> void:
	if game != null and game.dev != null:
		game.dev.request(action, args)


## Local: this machine's player's own database, every entry unlocked or wiped.
func _database(unlock: bool) -> void:
	if unlock:
		for kind in MonsterPages.ORDER:
			for field in ["sighted", "scanned", "harvested"]:
				game.mark_own_db(String(kind), field)
		game.say("Every database entry unlocked.", 2.0)
	else:
		game.database.clear()
		game.DatabaseStoreScript.save(game.database)
		game.say("Database wiped.", 2.0)


## Every room in this level worth going to: the entrance building's rooms by kind, the lot, one per wing.
func _rebuild_places() -> void:
	_places_level = game.level
	_places = []
	var seen := {}
	var info: Dictionary = game.level_info
	for r in info.get("rooms", []):
		var wing := String(r.get("wing", ""))
		var key := String(r.kind) if wing == "entrance" else "wing:" + wing
		if seen.has(key):
			continue
		seen[key] = true
		var rect: Rect2 = r.rect
		var label := String(r.kind).replace("hub_", "").capitalize() if wing == "entrance" else "Wing %s (%s)" % [wing, String(r.kind).capitalize()]
		_places.append({"name": label, "pos": Vector3(rect.get_center().x, 0.0, rect.get_center().y)})
	var lot: Rect2 = info.get("neutral_rect", Rect2())
	if lot.size != Vector2.ZERO:
		_places.append({"name": "Parking lot", "pos": Vector3(lot.get_center().x, 0.0, lot.position.y + 6.0)})
	var o := _c["places"] as OptionButton
	o.clear()
	for pl in _places:
		o.add_item(String(pl.name))


func _go_place(i: int) -> void:
	if i < 0 or i >= _places.size():
		return
	var me = game.local_player()
	if me == null:
		return
	var at: Vector3 = _places[i].pos
	var map: RID = me.get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		at = NavigationServer3D.map_get_closest_point(map, at)
	me.teleport(game._floor_at(at))


func _go_dev_room() -> void:
	var me = game.local_player()
	if me == null:
		return
	game.dev.build_room()
	if game.dev.room_ready():
		me.teleport(game.dev.room_info.arrive)


func _set_quality(q: int) -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.has_method("set_value"):
		settings.set_value("quality", q)
	elif main != null and main.has_method("set_quality"):
		main.set_quality(q)


func _refresh() -> void:
	if game == null or game.dev == null:
		return
	var dev = game.dev
	var me := Net.my_id()
	(_c["role"] as Label).text = ("Host. Friends who join land here." if Net.active else "Solo.") if game.is_host() \
		else "Client: every change is asked of the host."
	(_c["god"] as CheckBox).set_pressed_no_signal(dev.god.has(me))
	(_c["noclip"] as CheckBox).set_pressed_no_signal(dev.noclip.has(me))
	(_c["free_cam"] as CheckBox).set_pressed_no_signal(free_cam.is_on())
	(_c["free_cam_mode"] as Label).text = "" if not free_cam.is_on() else ("P: flying the camera" if free_cam.flying else "P: walking the surgeon")
	(_c["gun"] as CheckBox).set_pressed_no_signal(dev.gun.has(me))
	if _places_level != game.level:
		_rebuild_places()
	(_c["monsters_off"] as CheckBox).set_pressed_no_signal(dev.monsters_off)
	(_c["no_game_over"] as CheckBox).set_pressed_no_signal(dev.no_game_over)
	(_c["shift_label"] as Label).text = "Phase: %s, shift %d. %s" % [String(Game.Phase.keys()[int(game.phase)]).capitalize(),
		int(game.shift), game.loop.objective_text() if game.loop != null else ""]
	(_c["lights"] as CheckBox).set_pressed_no_signal(dev.lights_on)
	(_c["pen"] as CheckBox).set_pressed_no_signal(dev.pen_open)
	(_c["freeze"] as CheckBox).set_pressed_no_signal(dev.freeze_vitals)
	(_c["auto_revive"] as CheckBox).set_pressed_no_signal(dev.auto_revive)
	(_c["nurse_ignore"] as CheckBox).set_pressed_no_signal(dev.nurse_ignore_watch)   # NURSE HOOK
	var walk_i: int = ["", "follow", "loop"].find(dev.nurse_walk)
	if (_c["nurse_walk"] as OptionButton).selected != walk_i:
		(_c["nurse_walk"] as OptionButton).select(maxi(0, walk_i))
	if (_c["nurse_pace"] as OptionButton).selected != int(dev.nurse_pace):
		(_c["nurse_pace"] as OptionButton).select(int(dev.nurse_pace))
	if not _dragging.has("ts"):
		(_c["ts"] as HSlider).set_value_no_signal(dev.time_scale)
		(_c["ts_label"] as Label).text = "%.2fx" % dev.time_scale
	if not _dragging.has("vit"):
		(_c["vitals"] as HSlider).set_value_no_signal(game.vitals)
		(_c["vitals_label"] as Label).text = "%d" % int(game.vitals)
	var gfx := _c["gfx"] as OptionButton
	if main != null and "quality" in main and gfx.selected != int(main.quality):
		gfx.select(int(main.quality))
	(_c["monster_count"] as Label).text = "%d alive" % game.monsters.size()
	(_c["money_label"] as Label).text = "Team money $%d. Pills $%d/bottle at the pharmacy." % [int(game.money), int(game.PILL_PRICE)]
	# loop: every case, one line each.
	var lines := []
	for c in game.cases:
		if String(c.get("patient_id", "")) == "player":
			continue
		var step := Procedures.step(c.ailment_id, int(c.step_index))
		lines.append("%s, %s (%s, table %d, vitals %d). Step %d: %s." % [
			Procedures.patient(c.patient_id).name, Procedures.ailment(c.ailment_id).name, String(c.state),
			int(c.table), int(c.vitals), int(c.step_index) + 1, step.get("label", "done")])
	(_c["case_label"] as Label).text = ("Tables empty." if lines.is_empty() else "\n".join(lines)) + "\nShelf: " + _shelf_text()
	_refresh_bots(dev)


func _shelf_text() -> String:
	var parts := []
	for k in Items.SURGICAL:
		var n := int(game.shelf.get(k, 0))
		if n > 0:
			parts.append("%s %d" % [Items.display_name(k), n])
	return "empty" if parts.is_empty() else ", ".join(parts)


func _refresh_bots(dev: Node) -> void:
	var ids: Array = dev.bots.keys()
	ids.sort()
	ids.reverse()
	var sig := str(ids)
	if sig != _bots_sig:
		_bots_sig = sig
		for c in _bots_box.get_children():
			c.queue_free()
		_bot_rows.clear()
		if ids.is_empty():
			_label(_bots_box, "None yet.", 12, DIM)
		for id in ids:
			_bot_rows[id] = _make_bot_row(id, dev.bots[id])
	for id in ids:
		var e: Dictionary = dev.bots[id]
		var row: Dictionary = _bot_rows.get(id, {})
		if row.is_empty():
			continue
		var p = game.players.get(id)
		var hp := ""
		if p != null:
			hp = "dead" if not p.alive else ("down %ds" % int(p.bleed) if p.downed else ("stunned" if p.stun > 0.0 else "%d hp" % p.hp))
		(row.status as Label).text = "%s  |  %s" % [hp, String(e.get("status", ""))]


func _make_bot_row(id: int, e: Dictionary) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	_bots_box.add_child(box)
	var top := _row(box)
	var dummy: bool = String(e.get("kind", "bot")) == "dummy"
	var name_l := _label(top, String(e.get("name", "?")), 14, Color(1.0, 0.85, 0.35) if dummy else ACCENT)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status := _label(top, "", 12, DIM)
	_button(top, "Down", func(): _req("down_me", {"id": id}))   # downed hook
	_button(top, "X", func(): _req("remove_bot", {"id": id}))
	var out := {"status": status}
	if dummy:
		return out
	var ctl := _row(box)
	var order := _option(ctl, game.dev.ORDERS.map(func(o): return String(o).capitalize()))
	order.select(maxi(0, game.dev.ORDERS.find(String(e.get("order", "follow")))))
	var kinds: Array = Items.ITEMS.keys()
	var item := _option(ctl, kinds.map(func(k): return Items.display_name(k)))
	item.select(maxi(0, kinds.find(String(e.get("item", "gauze")))))
	# downed hook: "downed to table" makes carry pick up a downed player and lay them on the table.
	var targets := ["shelf", "player", "table"]
	var to := _option(ctl, ["to shelf", "to me", "downed to table"])
	to.select(maxi(0, targets.find(String(e.get("to", "shelf")))))
	_button(ctl, "Go", func():
		_req("order", {"id": id, "order": game.dev.ORDERS[order.selected], "item": kinds[item.selected],
			"to": targets[to.selected]}))
	out["order"] = order
	out["item"] = item
	out["to"] = to
	return out
