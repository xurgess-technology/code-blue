extends CanvasLayer
## The dev panel. F1 (or the key left of 1) toggles it while in the dev room; the mouse is free
## while it is open. Every world change goes through game.dev.request(), so on a client it is
## sent to the host; only graphics quality is local.

const ACCENT := Color(0.3, 0.95, 0.8)
const DIM := Color(0.6, 0.68, 0.7)
const PANEL_W := 400.0
const LootTableScript := preload("res://scripts/economy/loot_table.gd")

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


func setup(g: Node, m: Node) -> void:
	game = g
	main = m
	layer = 8
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
	return game != null and game.dev_mode and game.phase != game.Phase.MENU


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


func _process(delta: float) -> void:
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
	title.text = "DEV ROOM"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT)
	col.add_child(title)
	_c["role"] = _label(col, "", 12, DIM)

	# ---- you
	_section(col, "You")
	var you := _row(col)
	_c["god"] = _check(you, "God mode", func(on): _req("god", {"on": on}))
	_c["noclip"] = _check(you, "Noclip", func(on): _req("noclip", {"on": on}))
	_c["gun"] = _check(you, "Dev gun", func(on): _req("gun", {"on": on}))
	var you2 := _row(col)
	_button(you2, "Down me", func(): _req("down_me"))   # downed hook
	_label(col, "Gun: left click kills, right click downs. Noclip: Space up, Ctrl down.", 11, DIM)

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
	var w1 := _row(col)
	_c["lights"] = _check(w1, "Lights", func(on): _req("lights", {"on": on}))
	_c["pen"] = _check(w1, "Pen gate open", func(on): _req("pen", {"open": on}))
	var w2 := _row(col)
	_c["freeze"] = _check(w2, "Freeze vitals", func(on): _req("freeze", {"on": on}))
	_c["auto_revive"] = _check(w2, "Auto-revive", func(on): _req("auto_revive", {"on": on}))
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
	var monsters := _option(s2, ["The Discharged", "The Night Nurse"])
	monsters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kinds := ["discharged", "night_nurse"]
	_button(s2, "In the pen", func(): _req("spawn_monster", {"kind": kinds[monsters.selected], "where": "pen"}))
	_button(s2, "In front", func(): _req("spawn_monster", {"kind": kinds[monsters.selected], "where": "front"}))
	var s3 := _row(col)
	_button(s3, "Kill all monsters", func(): _req("kill_monsters"))
	_c["monster_count"] = _label(s3, "", 12, DIM)

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
	var pids: Array = Procedures.PATIENTS.keys()
	var aids: Array = Procedures.patient_ailments()  # downed hook: stitches is for players only
	var patients := _option(p1, pids.map(func(k): return Procedures.patient(k).name))
	var ailments := _option(p1, aids.map(func(k): return Procedures.ailment(k).name))
	patients.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ailments.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var p2 := _row(col)
	_button(p2, "Put on the table", func(): _req("patient", {"patient": pids[patients.selected], "ailment": aids[ailments.selected]}))
	_button(p2, "Clear table", func(): _req("clear_patient"))
	_button(p2, "Phone call", func(): _req("phone"))
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
	_button(b1, "Revive all", func(): _req("revive_all"))
	_bots_box = VBoxContainer.new()
	_bots_box.add_theme_constant_override("separation", 4)
	col.add_child(_bots_box)

	_label(col, "F1 or Esc closes this panel.", 11, DIM)


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
	(_c["gun"] as CheckBox).set_pressed_no_signal(dev.gun.has(me))
	(_c["lights"] as CheckBox).set_pressed_no_signal(dev.lights_on)
	(_c["pen"] as CheckBox).set_pressed_no_signal(dev.pen_open)
	(_c["freeze"] as CheckBox).set_pressed_no_signal(dev.freeze_vitals)
	(_c["auto_revive"] as CheckBox).set_pressed_no_signal(dev.auto_revive)
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
	(_c["money_label"] as Label).text = "Team money $%d, %d gold bars (next $%d)." % [int(game.money), int(game.gold_bars), int(game.gold_bar_price())]
	if game.case.is_empty():
		(_c["case_label"] as Label).text = "Table empty."
	else:
		var step := Procedures.step(game.case.ailment_id, int(game.case.step_index))
		(_c["case_label"] as Label).text = "%s, %s. Step %d: %s. Shelf: %s" % [
			Procedures.patient(game.case.patient_id).name, Procedures.ailment(game.case.ailment_id).name,
			int(game.case.step_index) + 1, step.get("label", "done"), _shelf_text()]
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
