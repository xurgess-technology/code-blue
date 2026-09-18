extends Control
## What the break room's wall terminal shows (wall_terminal.gd projects it), 1280x720. Driven like a
## computer by the scan laser: the terminal pushes mouse motion and clicks into its viewport, and
## this draws the laser's cursor on top (a viewport has no OS cursor of its own).
##
## Terminal redesign, chunk 2: one drill-down of cards (content in wall_pages.gd).
##   HOME      a 2x2 grid: Monsters, Procedures, Surgery Items, Other Items, each with an icon
##   SECTION   a 3x3 grid of its entries, PREV / NEXT through more; an unscanned entry is an empty
##             slot in the tray (no title, can't be opened)
##   ENTRY     a header, a subtitle and a paragraph or two on the left (a monster's ability and its
##             three levels, a procedure's steps, each step opening its surgery item), the entry's
##             3D model turning on the right (model_preview.gd)
## BACK goes up one page (a procedure's item goes back to the procedure), HOME to the top.
## Chunks 3 and 4 (wall_session.gd): nobody signed in is NO TRAY LOADED, one big HOLD TO LOAD YOUR TRAY and
## nothing else; signed in, SIGN OUT sits in the header and the player's name in the title; whose database fills the cards comes from the session; the host's
## screen takes every click and everyone else's follows it (set_view); other players' laser dots.
##
##   page, history(), set_view(page, history), refresh()
##   link_at(px) -> String, open_link(key)   a procedure's tool on the turntable under px, and opening it
##   sign_rect() -> Rect2      where HOLD TO LOAD YOUR TRAY is (empty while someone is signed in)
## Projector redesign, chunk 3: the tray wording above, empty slots, and the carousel misbehaving now
## and then (a slide in upside down, a slide jammed until someone clicks); `quirks` turns that off.
##   set_hold(k)               how far this machine's player's hold on it is, 0..1
##   set_cursor(px, on), set_remote_cursors([px]), pulse(px)

## A slide change started: wall_terminal.gd plays the carousel's clack out in the room.
signal advanced
## A slide caught in the gate: wall_terminal.gd plays the carousel grinding.
signal jammed

const Pages := preload("res://scripts/database/wall_pages.gd")
const ModelPreview := preload("res://scripts/database/model_preview.gd")
const MonsterModel := preload("res://scripts/monsters/monster_model.gd")
const MonsterPages := preload("res://scripts/database/monster_pages.gd")

const W := 1280.0
const H := 720.0
const MARGIN := 48.0
const BODY_Y := 128.0

## The slide in the gate: ivory paper inside a black mount, typed in near-black, red for anything
## the hospital wanted to stand out. The projector's lamp and fabric do the rest (wall_terminal.gd).
const MOUNT := Color(0.02, 0.02, 0.025)
const MOUNT_PX := 16.0
const BG := Color(0.88, 0.85, 0.77)
const INK := Color(0.04, 0.04, 0.05)
const INK_DIM := Color(0.24, 0.23, 0.21)
const RED := Color(0.52, 0.13, 0.12)
const CARD := Color(0.88, 0.85, 0.77)
const CARD_HOT := Color(0.98, 0.96, 0.89)
const CURSOR := Color(0.88, 0.13, 0.10)
const PER_PAGE := 9

## A slide change: the shutter passes (black), then the new slide lands and rocks to a stop.
const SHUTTER := 0.07
const SETTLE := 0.16
## Now and then the carousel misbehaves: one slide in FLIP_ODDS goes in upside down, one in JAM_ODDS
## catches in the gate (dark until someone clicks, or it frees itself after JAM_SECONDS).
const FLIP_ODDS := 40
const JAM_ODDS := 30
const JAM_SECONDS := 1.6

## The page on screen: {kind: "home"} | {kind: "section", id, index} | {kind: "entry", section, key}
var page: Dictionary = {"kind": "home"}
var _history: Array = []
var _body: Control
var _crumb: Label
var _back: Button
var _home: Button
var _preview: SubViewportContainer
var _cursor := Vector2.ZERO
var _cursor_on := false
var _pulse_at := Vector2.ZERO
var _pulse_t := -1.0
var _overlay: Control
var _title: Label
var _sign: Button
var _lock_note: Label
var _hold := 0.0
var _remote: Array = []
var _frame: Control
var _plate: Control
var _tip: Label
## Seconds into the current slide change, < 0 when the slide is just sitting there.
var _slide_t := -1.0
## The slide on screen went in upside down (until the next one).
var _flipped := false
## Seconds a jammed slide has been stuck, < 0 when nothing is jammed.
var _jam_t := -1.0
## Screenshot tools and tests turn the misbehaving off; the dev panel can force one next.
var quirks := true
## What was last put in the gate (page, locked, whose tray): a refresh of the same slide redraws it
## without the carousel turning.
var _last_sig := ""
var next_quirk := ""   # "", "flip" or "jam": the next slide change does this for certain
## Dust on the gate and a fiber caught in it: the same specks whatever slide is up, because they are
## in the projector, not on the film.
var _dust: Array = []
var _fiber := PackedVector2Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	# The slide mount: black card, with the exposed frame of film inside it.
	var mount := ColorRect.new()
	mount.color = MOUNT
	mount.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mount.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(mount)
	var bg := ColorRect.new()
	bg.color = BG
	bg.position = Vector2(MOUNT_PX, MOUNT_PX)
	bg.size = Vector2(W - MOUNT_PX * 2.0, H - MOUNT_PX * 2.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# Everything printed on the slide hangs off this, so a new slide can land and rock to a stop.
	_frame = Control.new()
	_frame.name = "Frame"
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.pivot_offset = Vector2(W, H) * 0.5
	_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_frame)

	_title = _label("SLIDE LIBRARY", 30, INK)
	_title.position = Vector2(MARGIN, 26)
	_frame.add_child(_title)
	_crumb = _label("", 25, INK_DIM)
	_crumb.position = Vector2(MARGIN + 2, 70)
	_frame.add_child(_crumb)
	_home = _button("HOME", Vector2(130, 56), 24)
	_home.position = Vector2(W - MARGIN - 130, 30)
	_home.pressed.connect(go_home)
	_frame.add_child(_home)
	_back = _button("< BACK", Vector2(150, 56), 24)
	_back.position = Vector2(W - MARGIN - 130 - 16 - 150, 30)
	_back.pressed.connect(back)
	_frame.add_child(_back)
	# Signing in is a hold (scan_fx.gd times it) on the lock screen; SIGN OUT is a click in the header.
	_sign = _button("HOLD TO LOAD YOUR TRAY", Vector2(250, 56), 22)
	_sign.position = Vector2(_back.position.x - 16 - 250, 30)
	_sign.pressed.connect(func():
		var g := _game()
		if g != null and g.wall != null and int(g.wall.user) != 0:
			g.wall.sign_out())
	_frame.add_child(_sign)

	var line := ColorRect.new()
	line.color = Color(INK, 0.35)
	line.position = Vector2(MARGIN, 108)
	line.size = Vector2(W - MARGIN * 2, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(line)

	_body = Control.new()
	_body.position = Vector2(MARGIN, BODY_Y)
	_body.size = Vector2(W - MARGIN * 2, H - BODY_Y - 24)
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	_frame.add_child(_body)

	# Where the plate was shot: not a panel, just a soft oval of shade on the paper, the way an old
	# plate vignettes off at its edges.
	_plate = Vignette.new()
	_plate.position = Vector2(786.0, BODY_Y - 10.0)
	_plate.size = Vector2(W - 34.0 - 786.0, H - 34.0 - (BODY_Y - 10.0))
	_plate.visible = false
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_plate)
	_preview = ModelPreview.new()
	_preview.position = Vector2(800, BODY_Y)
	_preview.size = Vector2(W - MARGIN - 800, H - BODY_Y - 30)
	_preview.visible = false
	_frame.add_child(_preview)

	# The name of the tool the laser is over, typed on the slide above it.
	_tip = _label("", 26, INK)
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.visible = false
	_frame.add_child(_tip)

	_lock_note = _label("POINT YOUR LASER HERE AND HOLD CLICK", 26, INK_DIM)
	_lock_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_note.size = Vector2(W, 40)
	_lock_note.position = Vector2(0, H * 0.5 + 110)
	_frame.add_child(_lock_note)

	_seed_gate()
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_show()


## Dust and the fiber, rolled once.
func _seed_gate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5D0E   # the same gate every session
	for _i in 46:
		_dust.append({"p": Vector2(rng.randf_range(MOUNT_PX, W - MOUNT_PX), rng.randf_range(MOUNT_PX, H - MOUNT_PX)),
			"r": rng.randf_range(0.7, 2.4), "a": rng.randf_range(0.05, 0.16)})
	var at := Vector2(rng.randf_range(W * 0.25, W * 0.75), MOUNT_PX)
	var pts := PackedVector2Array([at])
	for _i in 7:
		at += Vector2(rng.randf_range(-16.0, 16.0), rng.randf_range(12.0, 26.0))
		pts.append(at)
	_fiber = pts


func _process(delta: float) -> void:
	if _jam_t >= 0.0:
		# Stuck half way into the gate: nothing lands until a click frees it (or it frees itself).
		_jam_t += delta
		if _jam_t >= JAM_SECONDS:
			_unjam()
		_overlay.queue_redraw()
	elif _slide_t >= 0.0:
		_slide_t += delta
		# Through the shutter the gate is black; after it, the slide drops in and rocks level.
		var k := clampf((_slide_t - SHUTTER) / SETTLE, 0.0, 1.0)
		var fall := 1.0 - k
		var base := PI if _flipped else 0.0
		_frame.position.y = -26.0 * fall * fall
		_frame.rotation = base + 0.012 * fall * cos(k * 9.0)
		if _slide_t >= SHUTTER + SETTLE:
			_slide_t = -1.0
			_frame.position.y = 0.0
			_frame.rotation = base
		_overlay.queue_redraw()
	if _pulse_t >= 0.0:
		_pulse_t += delta
		if _pulse_t > 0.35:
			_pulse_t = -1.0
		_overlay.queue_redraw()


func _game() -> Node:
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null


# ---------------------------------------------------------------------------
# navigation

func history() -> Array:
	return _history


## The host's screen: this page, got to by `hist`.
func set_view(to: Dictionary, hist: Array) -> void:
	page = to
	_history = hist
	_show()


## Redraw the page (whose database it shows changed).
func refresh() -> void:
	_show()


func _view() -> Dictionary:
	var g := _game()
	if g == null or g.get("wall") == null:
		return {"db": {}, "peer": 0, "brains": null}
	return g.wall.view()


func sign_rect() -> Rect2:
	if not _sign.visible or not _locked():
		return Rect2()
	return Rect2(_sign.position, _sign.size)


## Nobody signed in: the whole screen is the lock screen.
func _locked() -> bool:
	var g := _game()
	return g == null or g.get("wall") == null or int(g.wall.user) == 0


func set_hold(k: float) -> void:
	if not is_equal_approx(k, _hold):
		_hold = k
		_overlay.queue_redraw()


func set_remote_cursors(points: Array) -> void:
	if points != _remote:
		_remote = points
		_overlay.queue_redraw()


func go_home() -> void:
	_history.clear()
	page = {"kind": "home"}
	_show()


func back() -> void:
	page = _history.pop_back() if not _history.is_empty() else {"kind": "home"}
	_show()


func open(to: Dictionary) -> void:
	_history.append(page)
	page = to
	_show()


func _show() -> void:
	var sig := "%s|%s|%s" % [str(page), str(_locked()), _who()]
	if sig != _last_sig:
		_last_sig = sig
		_advance()
	for c in _body.get_children():
		c.queue_free()
	_preview.visible = false
	_plate.visible = false
	_tip.visible = false
	var locked := _locked()
	_lock_note.visible = locked
	if locked:
		_title.text = "SLIDE LIBRARY"
		_crumb.text = "NO TRAY LOADED"
		_back.visible = false
		_home.visible = false
		_sign.text = "HOLD TO LOAD YOUR TRAY"
		_sign.add_theme_font_size_override("font_size", 44)
		_sign.custom_minimum_size = Vector2(820, 150)
		_sign.size = _sign.custom_minimum_size
		_sign.position = Vector2((W - _sign.size.x) * 0.5, H * 0.5 - 80)
		return
	var at_home := String(page.kind) == "home"
	_back.visible = not at_home
	_home.visible = not at_home
	var g := _game()
	var who: String = g.wall.user_name() if g != null and g.get("wall") != null else ""
	_title.text = "SLIDE LIBRARY  /  %s'S TRAY" % who.to_upper()
	_sign.text = "UNLOAD TRAY"
	_sign.add_theme_font_size_override("font_size", 22)
	_sign.custom_minimum_size = Vector2(210, 56)
	_sign.size = _sign.custom_minimum_size
	_sign.position = Vector2((_back.position.x - 16 - 210) if not at_home else (W - MARGIN - 210), 30)
	match String(page.kind):
		"home":
			_crumb.text = "HOME"
			_draw_home()
		"section":
			_crumb.text = "HOME  >  %s" % _section_title(String(page.id))
			_draw_section(String(page.id), int(page.get("index", 0)))
		"entry":
			_draw_entry(String(page.section), String(page.key))


## A new slide: the carousel clacks round (wall_terminal.gd plays it), the gate goes dark for a
## moment, and the slide lands. Skipped headless and while one is already on its way.
func _advance() -> void:
	if _frame == null or Engine.is_editor_hint():
		return
	if DisplayServer.get_name() == "headless":
		advanced.emit()   # no picture to animate: the page is simply there (tests, dedicated hosts)
		return
	if _jam_t >= 0.0:
		return   # a new page while jammed: it just waits behind the stuck slide
	if _slide_t < 0.0:
		# The shutter is drawn over the page (_draw_overlay), not by hiding it: a click in that instant
		# still lands on the page underneath.
		_slide_t = 0.0
		var quirk := _roll_quirk()
		_flipped = quirk == "flip"
		if quirk == "jam":
			_jam_t = 0.0
			_frame.visible = false   # jammed: a click frees the slide rather than pressing what's on it
			jammed.emit()
		else:
			advanced.emit()


## Whether this slide change misbehaves: never on the lock screen, never while quirks are off.
func _roll_quirk() -> String:
	var forced := next_quirk
	next_quirk = ""
	if forced != "":
		return forced
	if not quirks or _locked() or DisplayServer.get_name() == "headless":
		return ""
	if randi() % JAM_ODDS == 0:
		return "jam"
	if randi() % FLIP_ODDS == 0:
		return "flip"
	return ""


## The jammed slide shakes loose: the carousel clacks after all and the slide lands.
func _unjam() -> void:
	if _jam_t < 0.0:
		return
	_jam_t = -1.0
	_slide_t = 0.0
	_frame.visible = true
	advanced.emit()


func _who() -> String:
	var g := _game()
	return String(g.wall.user_name()) if g != null and g.get("wall") != null else ""


func _section_title(id: String) -> String:
	for s in Pages.SECTIONS:
		if s.id == id:
			return String(s.title)
	return id.to_upper()


# ---------------------------------------------------------------------------
# home: the 2x2 grid

func _draw_home() -> void:
	var gap := 28.0
	var cw := (_body.size.x - gap) * 0.5
	var ch := (_body.size.y - gap - 10.0) * 0.5
	for i in Pages.SECTIONS.size():
		var s: Dictionary = Pages.SECTIONS[i]
		var card := _button("", Vector2(cw, ch), 40)
		card.position = Vector2((i % 2) * (cw + gap), (i / 2) * (ch + gap))
		var id: String = s.id
		card.pressed.connect(func(): open({"kind": "section", "id": id, "index": 0}))
		_body.add_child(card)
		var icon := Icon.new()
		icon.kind = id
		icon.position = Vector2(34, (ch - 170) * 0.5)
		icon.size = Vector2(170, 170)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(icon)
		# Two-word titles on two lines (SURGERY / ITEMS), so they never run off the card.
		var t := _label(String(s.title).replace(" ", "
"), 46, INK)
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		t.position = Vector2(240, 0)
		t.size = Vector2(cw - 260, ch)
		card.add_child(t)


# ---------------------------------------------------------------------------
# a section: 3x3 cards, a page at a time

func _draw_section(id: String, index: int) -> void:
	var list := Pages.entries(id, _view())
	var pages := maxi(1, ceili(float(list.size()) / PER_PAGE))
	index = clampi(index, 0, pages - 1)
	page["index"] = index
	var gap := 18.0
	var grid_h := _body.size.y - 76.0
	var cw := (_body.size.x - gap * 2.0) / 3.0
	var ch := (grid_h - gap * 2.0) / 3.0
	for n in PER_PAGE:
		var i := index * PER_PAGE + n
		if i >= list.size():
			break
		var e: Dictionary = list[i]
		var known := bool(e.known)
		# Nothing scanned yet: not a "???" card, just an empty slot in the tray.
		var card := _button(String(e.title).to_upper() if known else "", Vector2(cw, ch), 30)
		card.position = Vector2((n % 3) * (cw + gap), (n / 3) * (ch + gap))
		card.disabled = not known
		var key: String = e.key
		card.pressed.connect(func(): open({"kind": "entry", "section": id, "key": key}))
		_body.add_child(card)
		# A contact sheet: every frame numbered in its corner, the way a tray is.
		var num := _label("%d" % (i + 1), 20, Color(INK_DIM, 0.8 if known else 0.4))
		num.position = Vector2(12, 8)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(num)
	if pages > 1:
		var prev := _button("< PREV", Vector2(190, 56), 26)
		prev.position = Vector2(0, grid_h + 14)
		prev.disabled = index <= 0
		prev.pressed.connect(func():
			page["index"] = index - 1
			_show())
		_body.add_child(prev)
		var nxt := _button("NEXT >", Vector2(190, 56), 26)
		nxt.position = Vector2(_body.size.x - 190, grid_h + 14)
		nxt.disabled = index >= pages - 1
		nxt.pressed.connect(func():
			page["index"] = index + 1
			_show())
		_body.add_child(nxt)
		var of := _label("SLIDE %d OF %d" % [index + 1, pages], 26, INK_DIM)
		of.position = Vector2(_body.size.x * 0.5 - 70, grid_h + 26)
		_body.add_child(of)


# ---------------------------------------------------------------------------
# an entry: text on the left, the model turning on the right

func _draw_entry(section: String, key: String) -> void:
	var p := Pages.page(section, key, _view())
	_crumb.text = "HOME  >  %s  >  %s" % [_section_title(section), String(p.get("title", key))]
	var col_w := 640.0
	var y := 0.0
	var head := _label(String(p.get("title", "")), 48, INK)
	head.position = Vector2(0, y)
	_body.add_child(head)
	y += 62.0
	var sub := _label(String(p.get("subtitle", "")), 24, INK_DIM)
	sub.position = Vector2(2, y)
	_body.add_child(sub)
	y += 46.0
	for text in p.get("paragraphs", []):
		if String(text).strip_edges() == "":
			continue
		var para := _para(String(text), 28, INK, col_w)
		para.position = Vector2(0, y)
		_body.add_child(para)
		y += float(para.get_line_count()) * 38.0 + 18.0
	if p.has("ability"):
		var ab: Dictionary = p.ability
		var at := _label("ABILITY:  %s" % String(ab.name), 28, INK)
		at.position = Vector2(0, y + 4)
		_body.add_child(at)
		y += 50.0
		for n in (ab.levels as Array).size():
			var known := String(ab.levels[n]) != "???"
			var lv := _label("LEVEL %d    %s" % [n + 1, String(ab.levels[n])], 26, INK if known else INK_DIM)
			lv.position = Vector2(20, y)
			_body.add_child(lv)
			y += 38.0
	if String(p.get("hint", "")) != "":
		var hint := _para(String(p.hint), 23, INK_DIM, col_w)
		hint.position = Vector2(0, y + 6)
		_body.add_child(hint)
	var specs: Array = p.get("models", [])
	_show_models(section + ":" + key, specs)
	if not specs.is_empty():
		_plate.visible = true
		# Four sides of the specimen, one slide each: stepping round it is another slide change.
		var n := posmod(int(page.get("angle", 0)), ModelPreview.ANGLES)
		_preview.set_angle(n)
		# Turning the specimen: two buttons under it, centred on the plate.
		var mid := _plate.position.x + _plate.size.x * 0.5 - _body.position.x
		var y_row := _body.size.y - 52.0
		var left := _button("<", Vector2(60, 46), 26)
		left.position = Vector2(mid - 72.0, y_row)
		left.pressed.connect(func():
			page["angle"] = n - 1
			_show())
		_body.add_child(left)
		var right := _button(">", Vector2(60, 46), 26)
		right.position = Vector2(mid + 12.0, y_row)
		right.pressed.connect(func():
			page["angle"] = n + 1
			_show())
		_body.add_child(right)


## A wrapped paragraph `width` wide (it never runs under the model on the right).
func _para(text: String, size_px: int, col: Color, width: float) -> Label:
	var l := _label(text, size_px, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(width, 0)
	l.size = Vector2(width, 0)
	return l


func _show_models(key: String, specs: Array) -> void:
	_preview.visible = true
	_plate.visible = true
	if _preview.current_key() == key:
		return
	var models: Array = []
	for m in specs:
		var d: Dictionary = m
		if d.has("monster"):
			var mm: Node3D = MonsterModel.new()
			mm.set_meta("preview_monster", String(d.monster))
			var h := float(MonsterPages.entry(String(d.monster)).get("height", 1.9))
			mm.set_meta("preview_bounds", AABB(Vector3(-0.35, 0.0, -0.3), Vector3(0.7, h, 0.6)))
			models.append(mm)
		else:
			var im: Node3D = ItemModels.make(String(d.item), int(d.get("count", 1)))
			if d.has("link"):
				im.set_meta("preview_link", String(d.link))
				im.set_meta("preview_label", String(d.get("label", d.link)))
			models.append(im)
	_preview.show_models(key, models, false)


## The laser on the screen: over a linked model its name shows; a click on it opens its page. Motion
## never reaches _gui_input here (nothing under the pointer takes it), so hovering reads every motion.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_preview.set_hover(_preview.pick((event as InputEventMouse).position - _preview.position) if _preview.visible else null)
		_show_tip()


## Type the hovered tool's name over it (nothing hovered: nothing typed).
func _show_tip() -> void:
	var text: String = _preview.hover_label() if _preview.visible else ""
	_tip.visible = text != ""
	if not _tip.visible:
		return
	_tip.text = text
	var r: Rect2 = _preview.hover_rect()
	_tip.size = Vector2(300.0, 34.0)
	_tip.position = Vector2(_preview.position.x + r.get_center().x - 150.0,
		maxf(_preview.position.y + r.position.y - 40.0, BODY_Y - 6.0))


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	if _jam_t >= 0.0:
		_unjam()
		accept_event()
		return
	var link := link_at((event as InputEventMouse).position)
	if link != "":
		open_link(link)
		accept_event()


## The linked model under px on this machine's turntable ("" for none). Each machine turns its own, so
## a guest's click says which one it hit (wall_session.gd).
func link_at(px: Vector2) -> String:
	if not _preview.visible:
		return ""
	var hit: Node3D = _preview.pick(px - _preview.position)
	return String(hit.get_meta("preview_link")) if hit != null and hit.has_meta("preview_link") else ""


func open_link(key: String) -> void:
	if String(page.kind) == "entry" and String(page.get("section", "")) == "procedures":
		open({"kind": "entry", "section": "surgery", "key": key})


# ---------------------------------------------------------------------------
# the laser cursor

func set_cursor(px: Vector2, on: bool) -> void:
	_cursor = px
	_cursor_on = on
	_overlay.queue_redraw()


func pulse(px: Vector2) -> void:
	_pulse_at = px
	_pulse_t = 0.0
	_overlay.queue_redraw()


func _draw_overlay() -> void:
	# In the projector, not on the slide: dust on the gate, a fiber that never moves, and the dark
	# corners of the lamp's throw.
	for d in _dust:
		_overlay.draw_circle(d.p, float(d.r), Color(MOUNT, float(d.a)))
	_overlay.draw_polyline(_fiber, Color(MOUNT, 0.10), 1.6)
	for n in 5:
		var inset := MOUNT_PX + float(n) * 7.0
		_overlay.draw_rect(Rect2(inset, inset, W - inset * 2.0, H - inset * 2.0), Color(MOUNT, 0.05), false, 7.0)
	# The shutter passing between slides, or a slide stuck half way in: the gate dark, a bright sliver
	# of the stuck slide along the top edge, trembling.
	if _jam_t >= 0.0:
		_overlay.draw_rect(Rect2(MOUNT_PX, MOUNT_PX, W - MOUNT_PX * 2.0, H - MOUNT_PX * 2.0), MOUNT)
		var jitter := 2.0 * sin(_jam_t * 70.0)
		_overlay.draw_rect(Rect2(MOUNT_PX + 40.0, MOUNT_PX, W - MOUNT_PX * 2.0 - 80.0, 46.0 + jitter), Color(BG, 0.85))
		var note := "SLIDE JAMMED  -  CLICK TO FREE IT"
		_overlay.draw_string(get_theme_default_font(), Vector2(0, H * 0.5), note, HORIZONTAL_ALIGNMENT_CENTER, W, 28, Color(BG, 0.55))
		return
	if _slide_t >= 0.0 and _slide_t < SHUTTER:
		_overlay.draw_rect(Rect2(MOUNT_PX, MOUNT_PX, W - MOUNT_PX * 2.0, H - MOUNT_PX * 2.0), MOUNT)
		return
	if _hold > 0.0 and _sign.visible:
		var r := Rect2(_sign.position, Vector2(_sign.size.x * clampf(_hold, 0.0, 1.0), _sign.size.y))
		_overlay.draw_rect(r.grow(-3.0), Color(CURSOR, 0.45), true)
	for rp in _remote:
		_overlay.draw_circle(rp, 6.0, Color(CURSOR, 0.8))
		_overlay.draw_arc(rp, 13.0, 0.0, TAU, 28, Color(CURSOR, 0.45), 2.0)
	if _pulse_t >= 0.0:
		var k := _pulse_t / 0.35
		_overlay.draw_arc(_pulse_at, lerpf(8.0, 46.0, k), 0.0, TAU, 32, Color(CURSOR, 1.0 - k), 4.0)
	if not _cursor_on:
		return
	_overlay.draw_circle(_cursor, 7.0, Color(CURSOR, 0.95))
	_overlay.draw_arc(_cursor, 16.0, 0.0, TAU, 32, Color(CURSOR, 0.6), 2.5)


# ---------------------------------------------------------------------------
# pieces

func _label(text: String, size_px: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, sz: Vector2, font_px: int) -> Button:
	var b := Button.new()
	b.text = text
	b.size = sz
	b.custom_minimum_size = sz
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.add_theme_font_size_override("font_size", font_px)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", RED)
	b.add_theme_color_override("font_pressed_color", RED)
	b.add_theme_color_override("font_disabled_color", Color(INK_DIM, 0.45))
	var states := {"normal": [CARD, Color(INK, 0.55)], "hover": [CARD_HOT, RED], "pressed": [Color(0.75, 0.72, 0.64), Color.WHITE],
		"disabled": [Color(CARD, 0.55), Color(INK_DIM, 0.25)]}
	for st in states.keys():
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[st][0]
		sb.border_color = states[st][1]
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 18
		sb.content_margin_right = 18
		b.add_theme_stylebox_override(st, sb)
	return b


## The soft shade a plate was photographed against: rings of it, fading out, so nothing on the slide
## has a hard edge the printer never made.
class Vignette extends Control:
	func _draw() -> void:
		var c := size * 0.5
		for n in 14:
			var k := 1.0 - float(n) / 14.0
			draw_set_transform(c, 0.0, Vector2(1.0, size.y / size.x))
			draw_circle(Vector2.ZERO, size.x * 0.5 * k, Color(0.05, 0.05, 0.06, 0.016))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A section's icon, inked on the slide: a hunched figure with eyes, a clipboard, crossed
## surgical tools, a pill bottle and a box.
class Icon extends Control:
	var kind := ""

	func _draw() -> void:
		var c := Color(0.04, 0.04, 0.05)          # INK; an inner class can't see the outer consts
		var dim := Color(0.04, 0.04, 0.05, 0.45)
		var s := size
		var w := 5.0
		match kind:
			"monsters":
				var head := Vector2(s.x * 0.5, s.y * 0.3)
				draw_arc(head, s.x * 0.2, 0.0, TAU, 32, c, w)
				draw_circle(head + Vector2(-s.x * 0.07, -2), 7.0, c)
				draw_circle(head + Vector2(s.x * 0.07, -2), 7.0, c)
				draw_polyline(PackedVector2Array([Vector2(s.x * 0.18, s.y * 0.98), Vector2(s.x * 0.24, s.y * 0.6),
					Vector2(s.x * 0.5, s.y * 0.5), Vector2(s.x * 0.76, s.y * 0.6), Vector2(s.x * 0.82, s.y * 0.98)]), c, w)
				for k in 3:
					draw_line(Vector2(s.x * (0.3 + k * 0.08), s.y * 0.95), Vector2(s.x * (0.33 + k * 0.08), s.y * 0.78), dim, 3.0)
			"procedures":
				var r := Rect2(s.x * 0.2, s.y * 0.12, s.x * 0.6, s.y * 0.84)
				draw_rect(r, c, false, w)
				draw_rect(Rect2(s.x * 0.38, s.y * 0.05, s.x * 0.24, s.y * 0.12), c, true)
				for k in 4:
					var yy := s.y * (0.34 + k * 0.15)
					draw_rect(Rect2(s.x * 0.28, yy - 8, 16, 16), c, false, 3.0)
					draw_line(Vector2(s.x * 0.42, yy), Vector2(s.x * 0.72, yy), dim if k > 1 else c, 4.0)
			"surgery":
				draw_line(Vector2(s.x * 0.15, s.y * 0.85), Vector2(s.x * 0.85, s.y * 0.15), c, w + 3)
				draw_line(Vector2(s.x * 0.62, s.y * 0.38), Vector2(s.x * 0.85, s.y * 0.15), Color(0.93, 0.90, 0.82), 2.0)
				draw_line(Vector2(s.x * 0.2, s.y * 0.15), Vector2(s.x * 0.62, s.y * 0.6), c, w)
				draw_line(Vector2(s.x * 0.15, s.y * 0.22), Vector2(s.x * 0.55, s.y * 0.68), c, w)
				draw_arc(Vector2(s.x * 0.68, s.y * 0.72), s.x * 0.1, 0.0, TAU, 24, c, w)
			"other":
				var body := Rect2(s.x * 0.12, s.y * 0.38, s.x * 0.34, s.y * 0.56)
				draw_rect(body, c, false, w)
				draw_rect(Rect2(s.x * 0.1, s.y * 0.26, s.x * 0.38, s.y * 0.12), c, true)
				draw_line(Vector2(s.x * 0.12, s.y * 0.58), Vector2(s.x * 0.46, s.y * 0.58), dim, 4.0)
				var box := Rect2(s.x * 0.54, s.y * 0.5, s.x * 0.36, s.y * 0.44)
				draw_rect(box, c, false, w)
				draw_line(Vector2(s.x * 0.54, s.y * 0.5), Vector2(s.x * 0.64, s.y * 0.38), c, w)
				draw_line(Vector2(s.x * 0.9, s.y * 0.5), Vector2(s.x * 0.98, s.y * 0.38), c, w)
				draw_line(Vector2(s.x * 0.64, s.y * 0.38), Vector2(s.x * 0.98, s.y * 0.38), c, w)
