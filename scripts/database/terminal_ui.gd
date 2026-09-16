class_name TerminalUI
extends CanvasLayer
## The database terminal: full-screen UI on the break-room computer (docs/CONTRACTS.md "Brains"
## -> "The database terminal", sweep 4a chunk 4). Replaces the old medical guide binder: no
## carryable version, opens with E while looking at the terminal (scripts/main.gd), the player
## cannot move while it is open (main.gd frees the mouse the same way it did for the guide).
##
##   open()    show the terminal, freeze the local player (via main.gd's mouse-mode hook)
##   close()   hide it
##   is_open() true between open() and close()
##
## Sections: Monsters, Abilities, Items & Procedures. Monster entries unlock in tiers (sighted /
## scanned / harvested) read from `game.database` (host-authoritative, mirrored to clients through
## game.gd's "db_update" / "db_full" events). Items & procedures are unlocked from the start, same
## content as the old guide (scripts/database/database_pages.gd, moved unchanged).

const Pages := preload("res://scripts/database/database_pages.gd")
const MonsterPages := preload("res://scripts/database/monster_pages.gd")
const ModelPreview := preload("res://scripts/database/model_preview.gd")
const MonsterModel := preload("res://scripts/monsters/monster_model.gd")
## The text column's width beside the 3D viewer.
const TEXT_W := 540.0

var game: Node = null

enum Tab { MONSTERS, ABILITIES, ITEMS }

var _open := false
var _tab: int = Tab.MONSTERS
var _index: int = 0

var _root: Control
var _tab_bar: HBoxContainer
var _list: VBoxContainer
var _list_scroll: ScrollContainer
var _detail: Control
var _hint: Label
var _preview: SubViewportContainer


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_index = 0
	_refresh()
	_sfx("click")


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	_sfx("click")


func is_open() -> bool:
	return _open


func _process(_delta: float) -> void:
	if _open:
		_refresh()   # cheap: rebuilt lists, not per-frame allocation-heavy art


func _input(event: InputEvent) -> void:
	if not _open:
		return
	var handled := true
	if event.is_action_pressed("pause") or event.is_action_pressed("database"):
		close()
	elif event is InputEventKey and event.pressed:
		match event.physical_keycode:
			KEY_1: _tab = Tab.MONSTERS; _index = 0
			KEY_2: _tab = Tab.ABILITIES; _index = 0
			KEY_3: _tab = Tab.ITEMS; _index = 0
			KEY_UP, KEY_W: _index = maxi(0, _index - 1)
			KEY_DOWN, KEY_S: _index += 1
			_: handled = false
	else:
		handled = false
	if handled:
		_refresh()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.05, 0.035, 0.97)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var title := Label.new()
	title.text = "HOSPITAL DATABASE TERMINAL"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	title.position = Vector2(40, 24)
	_root.add_child(title)

	_tab_bar = HBoxContainer.new()
	_tab_bar.position = Vector2(40, 66)
	_tab_bar.add_theme_constant_override("separation", 28)
	_root.add_child(_tab_bar)
	for t in ["[1] MONSTERS", "[2] ABILITIES", "[3] ITEMS & PROCEDURES"]:
		var l := Label.new()
		l.text = t
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Color(0.6, 0.85, 0.65))
		_tab_bar.add_child(l)

	_list_scroll = ScrollContainer.new()
	_list_scroll.position = Vector2(40, 110)
	_list_scroll.size = Vector2(420, 640)
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(_list_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list)

	_detail = Control.new()
	_detail.position = Vector2(500, 110)
	_detail.size = Vector2(1060, 640)
	_root.add_child(_detail)

	_preview = ModelPreview.new()
	_preview.position = Vector2(1080, 96)
	_preview.size = Vector2(480, 620)
	_root.add_child(_preview)

	_hint = Label.new()
	_hint.text = "1-3 sections    Up/Down select    Esc / E  close"
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.5, 0.7, 0.55, 0.85))
	_hint.position = Vector2(40, 780)
	_root.add_child(_hint)


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _refresh() -> void:
	for t in _tab_bar.get_child_count():
		(_tab_bar.get_child(t) as Label).modulate = Color(1, 1, 1, 1) if t == _tab else Color(1, 1, 1, 0.4)
	var names := _row_names()
	_index = clampi(_index, 0, maxi(0, names.size() - 1))
	for c in _list.get_children():
		c.queue_free()
	for i in names.size():
		var l := Label.new()
		l.text = names[i]
		l.add_theme_font_size_override("font_size", 15)
		l.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5) if i == _index else Color(0.55, 0.75, 0.6, 0.8))
		_list.add_child(l)
	for c in _detail.get_children():
		c.queue_free()
	match _tab:
		Tab.MONSTERS: _draw_monster(_index)
		Tab.ABILITIES: _draw_ability(_index)
		Tab.ITEMS: _draw_item(_index)
	_update_preview()


# ---------------------------------------------------------------------------
# The 3D viewer: the models this page talks about, rebuilt only when the page changes
# ---------------------------------------------------------------------------

func _update_preview() -> void:
	var spec := _preview_spec()
	if String(spec.key) == _preview.current_key():
		return
	var models: Array = []
	for m in spec.models:
		var d: Dictionary = m
		if d.has("monster"):
			var mm: Node3D = MonsterModel.new()
			mm.set_meta("preview_monster", String(d.monster))
			var h := float(MonsterPages.entry(String(d.monster)).get("height", 1.9))
			mm.set_meta("preview_bounds", AABB(Vector3(-0.35, 0.0, -0.3), Vector3(0.7, h, 0.6)))
			models.append(mm)
		else:
			var n: Node3D = ItemModels.make(String(d.item), int(d.get("count", 1)))
			if d.has("scale"):
				n.set_meta("preview_scale", float(d.scale))
			models.append(n)
	_preview.show_models(String(spec.key), models, bool(spec.get("silhouette", false)))


## {key, models: [{monster} | {item, count, scale}], silhouette} for the page on screen.
func _preview_spec() -> Dictionary:
	match _tab:
		Tab.MONSTERS:
			if _index < 0 or _index >= MonsterPages.ORDER.size():
				return {"key": "none", "models": []}
			var kind: String = MonsterPages.ORDER[_index]
			var tier := _tier(kind)
			if tier == 0:
				return {"key": "none", "models": []}
			var models: Array = [{"monster": kind}]
			if tier >= 3 and String(MonsterPages.entry(kind).get("ability", "")) != "":
				models.append({"item": "brain_" + kind, "scale": 5.0})
			return {"key": "mon:%s:%d" % [kind, mini(tier, 3)], "models": models, "silhouette": tier == 1}
		Tab.ABILITIES:
			var brain := "brain_discharged" if _index == 0 else "brain_walk_in"
			return {"key": "ability:" + brain, "models": [{"item": brain, "scale": 3.0}]}
		Tab.ITEMS:
			var entries := Pages.entries()
			if _index < 0 or _index >= entries.size():
				return {"key": "none", "models": []}
			var e: Dictionary = entries[_index]
			match String(e.type):
				"item":
					var kind2 := String(e.key)
					return {"key": "item:" + kind2, "models": [{"item": kind2, "count": 3 if Items.is_consumable(kind2) else 1}]}
				"placebo":
					return {"key": "item:placebo_pills", "models": [{"item": "placebo_pills"}]}
				"procedure":
					var kinds: Array = []
					for s in Procedures.ailment(String(e.key)).get("steps", []):
						var it := String(s.get("item", ""))
						if it != "" and not kinds.has(it):
							kinds.append(it)
					var models2: Array = []
					for k in kinds:
						models2.append({"item": k, "count": 2 if Items.is_consumable(k) else 1})
					return {"key": "procedure:" + String(e.key), "models": models2}
	return {"key": "none", "models": []}


func _row_names() -> Array:
	match _tab:
		Tab.MONSTERS:
			var out: Array = []
			for kind in MonsterPages.ORDER:
				var e := MonsterPages.entry(kind)
				out.append(e.name if _tier(kind) >= 1 else "??? unidentified")
			return out
		Tab.ABILITIES:
			return ["Echo", "Hive Eyes"]
		Tab.ITEMS:
			var out2: Array = []
			for e in Pages.entries():
				out2.append(e.title)
			return out2
	return []


func _tier(kind: String) -> int:
	if game == null:
		return 0
	var db: Dictionary = game.database
	if not db.has(kind):
		return 0
	var rec = db[kind]
	if bool(rec.harvested):
		return 3
	if bool(rec.scanned):
		return 2
	if bool(rec.sighted):
		return 1
	return 0


# ---------------------------------------------------------------------------
# Monsters
# ---------------------------------------------------------------------------

func _draw_monster(i: int) -> void:
	if i < 0 or i >= MonsterPages.ORDER.size():
		return
	var kind: String = MonsterPages.ORDER[i]
	var e := MonsterPages.entry(kind)
	var tier := _tier(kind)
	var y := 0.0
	if tier == 0:
		_label("No data on file. Sight this species (get within range and line of sight) to open an entry.",
			Vector2(0, 0), Color(0.6, 0.6, 0.6), 16)
		return
	_label(String(e.name).to_upper(), Vector2(0, y), Color(0.45, 1.0, 0.55), 30)
	y += 44.0
	# The model itself turns in the 3D viewer beside this column (_update_preview): a black
	# silhouette at tier 1, the real thing once scanned, its brain beside it once harvested.
	var tx := 0.0
	if tier == 1:
		_label("Tier 1: SIGHTED\nSeen at range. Not yet scanned.", Vector2(tx, y), Color(0.6, 0.85, 0.65), 16)
		return
	_label("Behaviour: %s" % e.behaviour, Vector2(tx, y), Color(0.75, 0.9, 0.78), 15, TEXT_W)
	_label("Senses: %s" % e.senses, Vector2(tx, y + 60), Color(0.75, 0.9, 0.78), 15, TEXT_W)
	_label("Threat: %s" % e.threat, Vector2(tx, y + 120), Color(0.9, 0.7, 0.4), 15, TEXT_W)
	_label("Sedation: %s" % e.doses, Vector2(tx, y + 180), Color(0.75, 0.9, 0.78), 15, TEXT_W)
	_label("Brain site: %s" % e.brain_site, Vector2(tx, y + 240), Color(0.75, 0.9, 0.78), 15, TEXT_W)
	if tier == 2:
		_label("Tier 2: SCANNED\nHarvest a brain of this species to unlock its growth.", Vector2(tx, y + 300), Color(0.6, 0.85, 0.65), 16)
		return
	# Tier 3: harvested / absorbed.
	var growth: String = String(e.get("growth_site", ""))
	var ability_line: String
	if growth == "unknown" or String(e.get("ability", "")) == "":
		ability_line = "Growth site: unknown. No brain has ever been harvested from her."
	else:
		ability_line = "Grants: %s" % e.ability
	_label("Tier 3: HARVESTED\n%s" % ability_line, Vector2(tx, y + 300), Color(0.55, 0.95, 0.65), 16, TEXT_W)
	if String(e.get("ability", "")) != "" and game != null and game.brains != null:
		var path := kind
		var lines: Array = []
		for lvl2 in range(0, 4):
			if path == "walk_in":
				lines.append("Lv %d  range %.0fm  duration %.1fs  cooldown 12s" % [lvl2, game.brains.hive_range(lvl2), game.brains.hive_seconds(lvl2)])
			elif path == "discharged":
				lines.append("Lv %d  radius %.0fm  duration %.1fs  cooldown 20s" % [lvl2, game.brains.echo_radius(lvl2), game.brains.echo_seconds(lvl2)])
		_label("\n".join(lines), Vector2(tx, y + 360), Color(0.7, 0.85, 0.72), 14)


# ---------------------------------------------------------------------------
# Abilities
# ---------------------------------------------------------------------------

func _draw_ability(i: int) -> void:
	var id := "echo" if i == 0 else "hive_in"
	var path := "discharged" if id == "echo" else "walk_in"
	var name := "Echo" if id == "echo" else "Hive Eyes"
	_label(name.to_upper(), Vector2(0, 0), Color(0.45, 1.0, 0.55), 30)
	var lvl := 0
	var peer := 0
	if game != null and game.local_player() != null:
		peer = game.local_player().peer_id
	if game != null and game.brains != null:
		lvl = game.brains.level(peer, path)
	var slot := -1
	if game != null and game.brains != null:
		slot = game.brains.slot_of(peer, id)
	_label("Your level: %d%s" % [lvl, "  (slot %d)" % (slot + 1) if slot >= 0 else "  (not learned yet)"],
		Vector2(0, 44), Color(0.75, 0.9, 0.78), 16)
	var lines: Array = []
	if id == "echo":
		lines.append("A shriek that lights up the wing through walls for a moment. Costs noise: LOUD (monsters can hear it).")
		lines.append("Keys: Alt+slot fires it; pressing the slot again ends it early.")
		lines.append("")
		for lvl2 in range(0, 4):
			if game != null and game.brains != null:
				lines.append("Lv %d   radius %.0f m   duration %.1f s   cooldown 20 s" % [lvl2, game.brains.echo_radius(lvl2), game.brains.echo_seconds(lvl2)])
	else:
		lines.append("Your camera flies along the navmesh to a Walk-In in range and watches through its eyes.")
		lines.append("Flight takes about 1-1.5 s. The duration timer starts once you land in its eyes.")
		lines.append("Taking a hit snaps you back instantly, no fly-back.")
		lines.append("Keys, level 1: tap the slot again to end it.")
		lines.append("Keys, level 2+: tap the slot to cycle to another Walk-In in range; hold it about 0.4 s to end it.")
		lines.append("")
		for lvl2 in range(0, 4):
			if game != null and game.brains != null:
				lines.append("Lv %d   range %.0f m   duration %.1f s   cooldown 12 s" % [lvl2, game.brains.hive_range(lvl2), game.brains.hive_seconds(lvl2)])
	_label("\n".join(lines), Vector2(0, 90), Color(0.75, 0.9, 0.78), 15, TEXT_W)


# ---------------------------------------------------------------------------
# Items & Procedures
# ---------------------------------------------------------------------------

func _draw_item(i: int) -> void:
	var entries := Pages.entries()
	if i < 0 or i >= entries.size():
		return
	var e: Dictionary = entries[i]
	match e.type:
		"item":
			var d := Pages.item_page(e.key)
			_label(String(d.name).to_upper(), Vector2(0, 0), Color(0.45, 1.0, 0.55), 26)
			_label("Real-world use: %s" % d.real_use, Vector2(0, 44), Color(0.75, 0.9, 0.78), 15, TEXT_W)
			_label("Where to find: %s" % d.where, Vector2(0, 140), Color(0.75, 0.9, 0.78), 15, TEXT_W)
			_label("Handling: %s" % d.handling, Vector2(0, 220), Color(0.75, 0.9, 0.78), 15, TEXT_W)
		"placebo":
			var d2 := Pages.placebo_page()
			_label(String(d2.name).to_upper(), Vector2(0, 0), Color(0.45, 1.0, 0.55), 26)
			_label(String(d2.real_use), Vector2(0, 44), Color(0.75, 0.9, 0.78), 15, TEXT_W)
			_label("Where: %s" % d2.where, Vector2(0, 90), Color(0.75, 0.9, 0.78), 15, TEXT_W)
			_label("Handling: %s" % d2.handling, Vector2(0, 136), Color(0.75, 0.9, 0.78), 15, TEXT_W)
		"procedure":
			var d3 := Pages.procedure_page(e.key)
			_label(String(d3.name).to_upper(), Vector2(0, 0), Color(0.45, 1.0, 0.55), 26)
			var lines: Array = []
			var n := 1
			for s in d3.steps:
				lines.append("%d. %s (needs %s)" % [n, s.label, s.needs])
				n += 1
			_label("\n".join(lines), Vector2(0, 44), Color(0.75, 0.9, 0.78), 15, TEXT_W)
		"locked":
			var d4 := Pages.locked_page(e.key)
			_label(String(d4.name).to_upper(), Vector2(0, 0), Color(0.6, 0.6, 0.6), 26)
			_label(String(d4.scrawl), Vector2(0, 44), Color(0.6, 0.6, 0.6), 15, TEXT_W)


func _label(text: String, pos: Vector2, col: Color, size: int, wrap: float = 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap > 0.0:
		l.custom_minimum_size = Vector2(wrap, 0)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(l)
	return l


func _sfx(cue: String) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play"):
		audio.play(cue)
