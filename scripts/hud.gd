class_name Hud
extends Control
## Everything drawn over the 3D view. One immediate-mode Control keeps it in one
## readable place instead of a pile of nodes.
##
## MINIMAL HUD (sweep 2, orscreen). The patient, vitals, step checklist and supplies live on the OR
## wall monitor (scripts/orscreen/), so the HUD keeps only:
##   hands     the four slots (inventory's slot bar)
##   prompt    crosshair dot, the interact prompt and hold-E progress
##   health    the player's own hearts (and stamina while it is not full), bottom left
##   message   short messages / subtitles, the dead / spectating banner
##   money     the money readout (hides itself away from the economy spots)
##   hint      the controls line for the first seconds of a session
##   overlay   pause, flatline and shift-won overlays; the host's join address in the lobby
## The surgery step's title and one-line hint are drawn by scripts/surgery/surgery_hud.gd; the FPS
## counter (F3) by main.gd; settings and the dev panel are their own layers.
## Removed: the party list, the objective banner, the case panel, the flashlight label and the
## surgery gauges fallback. `drawn` lists what the last frame drew (tools/orscreentest.gd reads it).

var game: Game = null
var host_info: String = ""
## Element ids drawn in the last _draw(), for tests.
var drawn: PackedStringArray = []

var _t: float = 0.0
var _font: Font
var _stamina_show: float = 0.0
## ROCKET BOOTS: the fuel bar under stamina, only while wearing a pair and it isn't full.
var _fuel_show: float = 0.0
## SWEEP 4A HOOK (controls): the ability bar (Alt) and the scanner ring, both local-only.
## 0 = Alt not held (abilities small top-left, items at full size); 1 = Alt held (abilities fill
## the bar, items shrink to a small top-left row). ~0.12 s each way per docs/SWEEP4A.md.
var _alt_t: float = 0.0
## Ability id -> world_time its first-ability card should stop showing itself, and which ids have
## already had their card (so it only shows once per id per session).
var _card_until: Dictionary = {}
# SWEEP 4A HOOK (scanner): the "SCAN COMPLETE" banner (scan_fx.gd), until _t passes this.
var _scan_banner_until := -1.0
var _scan_banner_name := ""
var _card_seen: Dictionary = {}
const ABILITY_LABEL := {"echo": "Echo", "hive_in": "Hive Eyes"}
const ABILITY_COST := {"echo": "LOUD", "hive_in": ""}
const ABILITY_DESC := {
	"echo": "A shriek that outlines everything nearby through walls for a few seconds.",
	"hive_in": "See through a nearby Hive's eyes for a few seconds.",
}


func _ready() -> void:
	add_to_group("hud")   # SWEEP 4A HOOK (scanner): scan_fx.gd finds the banner here
	_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS   # the icons are imported with mipmaps
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	var me = game.driving_player() if game != null else null   # GRAFT HOOK: or Dr. Botsworth
	var tired: bool = me != null and me.stamina < 0.995
	_stamina_show = clampf(_stamina_show + (delta * 4.0 if tired else -delta * 1.5), 0.0, 1.0)
	var fuel_low: bool = me != null and me.boots and (me.fuel < 0.995 or me.rocketing)
	_fuel_show = clampf(_fuel_show + (delta * 4.0 if fuel_low else -delta * 1.5), 0.0, 1.0)
	var alt_held: bool = Input.is_action_pressed("ability_alt")
	_alt_t = move_toward(_alt_t, 1.0 if alt_held else 0.0, delta / 0.12)
	# SWEEP 4A HOOK: the first time an ability lands in a slot, a short card for it.
	if me != null and game.brains != null:
		for id in (game.brains.slots_for(me.peer_id) as Array):
			if String(id) != "" and not _card_seen.has(id):
				_card_seen[id] = true
				_card_until[id] = _t + 5.0
	if _card_until.size() > 0 and Input.is_anything_pressed():
		_card_until.clear()
	queue_redraw()


func _draw() -> void:
	drawn = PackedStringArray()
	if game == null or game.phase == Game.Phase.MENU:
		return
	var w := size.x
	var h := size.y
	var in_surgery: bool = game.surgery_camera() != null  # downed hook: either table
	_draw_vignette(w, h)
	var me = game.driving_player()   # GRAFT HOOK: the hands and prompt of whoever you are driving
	if me != null and me.alive and not game.paused and not in_surgery:
		_draw_crosshair(w, h)
		_draw_prompt(w, h, me)
	if me != null and me.alive and not in_surgery:
		_draw_hands(w, h, me)
		_draw_ability_bar(w, h, me)   # SWEEP 4A HOOK (controls)
		_draw_health(h, me)
	if me != null and me.alive and not game.paused and not in_surgery:
		_draw_scan_ring(w, h, me)   # SWEEP 4A HOOK (scanner)
		_draw_scan_banner(w, h)
		_draw_ability_card(w, h)
	if me != null and not in_surgery:
		_draw_money(w, h, me)
	if me != null and not me.alive:
		_draw_dead_banner(w)
	_draw_holds(w, h)
	_draw_host_info(w)
	_draw_message(w, h, in_surgery)
	# Paused: the settings fax is the pause menu (settings_screen.gd), nothing drawn here.
	if game.paused:
		pass
	elif game.phase == Game.Phase.LOST:
		# loop: a team failure ends the run.
		_overlay(w, h, "GAME OVER", game.message, "Money reset. A new run starts in %d" % ceili(game.end_timer), Color("ff2a2a"))
	elif game.phase == Game.Phase.WON:
		# loop: clocked out, the paycheck.
		_overlay(w, h, "SHIFT %d COMPLETE" % game.shift, String(game.loop.pay_note),
			"Walk out to sell and shop, then clock in for shift %d (%d)" % [game.shift + 1, ceili(game.end_timer)], Color("5cff8a"))


func _text(pos: Vector2, s: String, size_px: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(_font, pos, s, align, width, size_px, col)


func _draw_vignette(w: float, h: float) -> void:
	var red: float = maxf(0.0, game.danger * 0.28 * (0.5 + 0.5 * sin(_t * 6.0)))
	if red > 0.01:
		draw_rect(Rect2(0, 0, w, h), Color(0.55, 0.0, 0.0, red * 0.45))


## Your own hearts, top left, with a thin stamina bar under them while it is not full. (The bottom
## left corner is the tip fax's, scripts/tips/tip_fax.gd.)
func _draw_health(_h: float, me) -> void:
	drawn.append("health")
	var x := 24.0
	var y := 44.0
	var n: int = me.max_hp
	var step := 30.0
	draw_rect(Rect2(x - 12, y - 20, 16 + n * step, 38), Color(0, 0, 0, 0.5))
	var hurt: bool = me.hp <= 1 and n > 1
	for i in n:
		var full: bool = i < me.hp
		var col := Color("e8322e") if full else Color(0.3, 0.1, 0.1, 0.9)
		if full and hurt:
			col = col.lerp(Color("ff9a9a"), 0.35 + 0.35 * sin(_t * 7.0))
		_heart(Vector2(x + 10 + i * step, y - 2), col, 1.45)
	if _stamina_show > 0.01:
		drawn.append("stamina")
		var bw := n * step - 8.0
		draw_rect(Rect2(x, y + 22, bw, 4), Color(0, 0, 0, 0.55 * _stamina_show))
		var sc := Color("e0a020") if me.stamina < 0.25 else Color("7ad0c0")
		draw_rect(Rect2(x, y + 22, bw * clampf(me.stamina, 0.0, 1.0), 4), Color(sc, 0.9 * _stamina_show))
	if _fuel_show > 0.01:
		drawn.append("fuel")   # ROCKET BOOTS
		var fw := n * step - 8.0
		draw_rect(Rect2(x, y + 29, fw, 4), Color(0, 0, 0, 0.55 * _fuel_show))
		var fc := Color("ff5a1e") if me.fuel < 0.25 else Color("ff9a2e")
		if me.rocketing:
			fc = fc.lerp(Color("ffe08a"), 0.4 + 0.4 * sin(_t * 30.0))
		draw_rect(Rect2(x, y + 29, fw * clampf(me.fuel, 0.0, 1.0), 4), Color(fc, 0.95 * _fuel_show))


func _heart(at: Vector2, col: Color, k := 1.0) -> void:
	draw_circle(at + Vector2(-3.5, -2) * k, 4.0 * k, col)
	draw_circle(at + Vector2(3.5, -2) * k, 4.0 * k, col)
	draw_colored_polygon(PackedVector2Array([at + Vector2(-7.4, -0.4) * k, at + Vector2(7.4, -0.4) * k, at + Vector2(0, 8) * k]), col)


## Hosting: where friends join, small, while everyone is still in the lobby.
func _draw_host_info(w: float) -> void:
	if game.phase != Game.Phase.LOBBY or host_info == "":
		return
	drawn.append("host_info")
	_text(Vector2(0, 24), host_info, 14, Color("5ce0d0"), HORIZONTAL_ALIGNMENT_CENTER, w)


func _draw_crosshair(w: float, h: float) -> void:
	var me = game.driving_player()
	# The camera facing you (the "front" camera setting): the middle of the screen is your own face.
	if me != null and me.carry_cam != null and me.carry_cam.front_view():
		return
	drawn.append("crosshair")
	var c := Vector2(w, h) * 0.5
	var spread: float = 9.0 if me.sprinting else (6.0 if me.moving else 4.0)
	var usable: bool = me.aim_id != "" and not String(me.aim_prompt).begins_with("!")
	var col := Color(1, 1, 1, 0.55) if me.aim_id == "" else Color(1.0, 0.95, 0.7, 0.9)
	# On something you can use, a small ring opens in the middle (aim_highlight.gd brightens it).
	if usable:
		drawn.append("crosshair_ring")
		draw_arc(c, 5.0, 0.0, TAU, 24, col, 1.5, true)
	draw_line(c + Vector2(-spread - 4, 0), c + Vector2(-spread, 0), col, 1.5)
	draw_line(c + Vector2(spread, 0), c + Vector2(spread + 4, 0), col, 1.5)
	draw_line(c + Vector2(0, -spread - 4), c + Vector2(0, -spread), col, 1.5)
	draw_line(c + Vector2(0, spread), c + Vector2(0, spread + 4), col, 1.5)


## "[E] Take 3 Anesthetic" under the crosshair, or a dim reason you cannot.
func _draw_prompt(w: float, h: float, me) -> void:
	var y := h * 0.5 + 34.0
	if me.aim_prompt != "":
		drawn.append("prompt")
		if me.aim_prompt.begins_with("!"):
			var msg: String = me.aim_prompt.substr(1)
			_text(Vector2(0, y), msg, 14, Color("e0a020"), HORIZONTAL_ALIGNMENT_CENTER, w)
			# The table's "Hold Forceps to do this.": the item it names, as its icon.
			var need := _prompt_item(msg)
			var icon: Texture2D = ItemIcons.bare(need) if need != "" else null
			if icon != null:
				drawn.append("prompt_icon")
				var tw := _font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
				var ir := Rect2(w * 0.5 - tw * 0.5 - 40.0, y - 24.0, 32.0, 32.0)
				var sb := StyleBoxFlat.new()
				sb.bg_color = Color(SLOT_BG, 0.85)
				sb.border_color = ItemIcons.border(need)
				sb.set_border_width_all(2)
				sb.set_corner_radius_all(6)
				draw_style_box(sb, ir)
				draw_texture_rect(icon, ir.grow(-3.0), false)
		else:
			var key := "[E]" if me.aim_hold <= 0.0 or me.aim_prompt.begins_with("Hold E") else "[Hold E]"
			# HANDS HOOK: a prompt that names its own key ("[Click] Jab it") is shown as it is.
			var text: String = me.aim_prompt if me.aim_prompt.begins_with("Hold E") or me.aim_prompt.begins_with("[") else "%s %s" % [key, me.aim_prompt]
			_text(Vector2(0, y), text, 16, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)
		y += 20.0


## The item a "Hold [2] Forceps to do this." prompt names ("" when it is not that prompt).
func _prompt_item(msg: String) -> String:
	if not (msg.begins_with("Hold ") and msg.ends_with(" to do this.")):
		return ""
	var name := msg.substr(5, msg.length() - 5 - " to do this.".length())
	var sp := name.find(" ")
	if sp > 0 and name.substr(0, sp).is_valid_int():
		name = name.substr(sp + 1)
	return ItemIcons.kind_named(name)


const SLOT_TEAL := Color(0.3, 0.9, 0.82)
const SLOT_GOLD := Color(1.0, 0.74, 0.28)


const SLOT_PX := 56.0          # one hand slot, square
const SLOT_GAP := 8.0
const BAR_MARGIN := 16.0       # from the bottom of the screen
const SMALL_PX := 28.0         # a slot in the Alt (shrunk) row
const NAME_SECONDS := 2.0      # how long a held item's name hangs above the bar
const POP_SECONDS := 0.3       # the pickup pop: crosshair to slot
const SLOT_BG := Color(0.04, 0.05, 0.07)
const SELECT_COL := Color("f6efd4")

# The item bar's own memory: what each slot held last frame (for the pickup pop), what the hands
# held last frame (for the name flash) and what is flying right now.
var _seen: Array = []
var _seen_owner := -1
var _held_sig := ""
var _flash_name := ""
var _flash_until := -1.0
var _pops: Array = []          # [{kind, t0}]
var _slot_ctr: Dictionary = {} # slot index -> where its icon is on screen (last draw)
## Element ids the last _draw_hands drew as slots, for tests: "slot" per hand slot, "wide" per bulky stack.
var slots_drawn: Array = []


## The icon item bar (docs/ITEMS_AND_ICONS.md, chunk C): one square per hand slot along the bottom
## centre, each showing the item's bare icon on a dark rounded square with its category border, the
## key number in a corner and a live count on stacks. The selected slot is lifted and outlined; a bulky
## stack is ONE wide slot across its two (adjacent) slots. No prices. While Alt is held the row slides
## up and shrinks to the small row the ability icons sit in when idle (and they grow into the bar).
func _draw_hands(w: float, h: float, me) -> void:
	drawn.append("hands")
	var n: int = me.slots.size()
	var t := clampf(_alt_t, 0.0, 1.0)
	var sel_head: int = me.selected_head()
	_track_hands(me, sel_head)
	slots_drawn = []
	_slot_ctr.clear()
	var full := t < 0.5
	var units := bar_units(w, h, me.slots, sel_head, t)
	# Non-adjacent bulky halves (the pair wraps round the bar): a bracket over both, full size only.
	if full:
		for u in units:
			var tail: int = me.tail_of(int(u.slot))
			if tail >= 0 and not bool(u.wide) and not bool(u.ghost) and String(me.slots[int(u.slot)].kind) != "":
				var a: Rect2 = u.rect
				var b: Rect2 = _unit_rect(units, tail)
				var ya := minf(a.position.y, b.position.y) - 5.0
				var col := Color(ItemIcons.border(String(me.slots[int(u.slot)].kind)), 0.8)
				draw_polyline(PackedVector2Array([Vector2(a.get_center().x, a.position.y - 1), Vector2(a.get_center().x, ya),
					Vector2(b.get_center().x, ya), Vector2(b.get_center().x, b.position.y - 1)]), col, 2.0)
	for u in units:
		var i: int = u.slot
		var head: int = me.head_of(i)
		var kind := String(me.slots[head].kind)
		var wide: bool = u.wide
		_draw_slot(u.rect, kind, me.slots[head], String(u.keys), bool(u.sel), full, bool(u.ghost), wide)
		slots_drawn.append("wide" if wide else "slot")
		var ctr: Vector2 = (u.rect as Rect2).get_center()
		_slot_ctr[i] = ctr
		if wide:
			_slot_ctr[int(u.other)] = ctr
	_draw_name_flash(w, h - BAR_MARGIN - SLOT_PX, t)
	_draw_pops(w, h)


func _unit_rect(units: Array, slot: int) -> Rect2:
	for u in units:
		if int(u.slot) == slot:
			return u.rect
	return Rect2()


## Where every slot of the bar goes (pure, so a headless test can read it): one unit per square drawn,
## {slot, rect, wide, ghost, sel, keys, other}. `t` is the Alt blend (0 full bar, 1 the small row). A
## bulky stack whose two slots sit side by side (and the bar is full size) is ONE unit, wide, holding
## its head; the unit for a second half that cannot join its head is `ghost`. The selected unit is
## lifted and grown.
static func bar_units(w: float, h: float, slots: Array, selected_head: int, t: float) -> Array:
	var n := slots.size()
	var x0 := w * 0.5 - (SLOT_PX * n + SLOT_GAP * (n - 1)) * 0.5
	var y := h - BAR_MARGIN - SLOT_PX
	var small_y := y - SMALL_PX - 6.0
	var rects := []
	for i in n:
		var big_r := Rect2(x0 + i * (SLOT_PX + SLOT_GAP), y, SLOT_PX, SLOT_PX)
		var small_r := Rect2(x0 + i * (SMALL_PX + 4.0), small_y, SMALL_PX, SMALL_PX)
		rects.append(Rect2(big_r.position.lerp(small_r.position, t), big_r.size.lerp(small_r.size, t)))
	var full := t < 0.5
	var out := []
	var done := {}
	for i in n:
		if done.has(i):
			continue
		var is_tail: bool = slots[i].has("of")
		var head: int = int(slots[i].of) if is_tail else i
		var kind := String(slots[head].kind) if head >= 0 and head < n else ""
		var r: Rect2 = rects[i]
		var keys := "%d" % (i + 1)
		var wide := false
		var other := -1
		if full and kind != "":
			# The stack's other slot.
			for j in n:
				if j != head and slots[j].has("of") and int(slots[j].of) == head:
					other = j
			var mine := i
			var pair := head if is_tail else other
			if pair >= 0 and absi(pair - mine) == 1:
				if is_tail:
					continue   # its head draws the wide slot
				wide = true
				r = (rects[mini(mine, pair)] as Rect2).merge(rects[maxi(mine, pair)])
				keys = "%d" % (mini(mine, pair) + 1)
				done[pair] = true
		var sel := head == selected_head
		if sel and full:
			r.position.y -= 8.0
			r = r.grow(4.0)
		out.append({"slot": i, "rect": r, "wide": wide, "ghost": is_tail and not wide, "sel": sel, "keys": keys, "other": other})
	return out


## One slot. `r` is where it is, `small` its Alt-row size (no text), `ghost` the second half of a bulky
## stack that could not be joined to its head (drawn fainter, no count).
func _draw_slot(r: Rect2, kind: String, s: Dictionary, keys: String, sel: bool, full: bool, ghost: bool, wide: bool) -> void:
	var radius := 10 if full else 6
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(radius)
	if kind == "":
		sb.bg_color = Color(0, 0, 0, 0.32)
		sb.border_color = Color(0.5, 0.55, 0.6, 0.22)
		sb.set_border_width_all(1)
		draw_style_box(sb, r)
		if full:
			_text(r.position + Vector2(6, 13), keys, 10, Color("8a9aa0", 0.4))
		return
	var border := ItemIcons.border(kind)
	if sel:
		var ob := StyleBoxFlat.new()
		ob.bg_color = Color(0, 0, 0, 0)
		ob.border_color = SELECT_COL
		ob.set_border_width_all(2)
		ob.set_corner_radius_all(radius + 3)
		draw_style_box(ob, r.grow(3.0))
	sb.bg_color = Color(SLOT_BG, 0.94 if sel else 0.8)
	sb.border_color = Color(border, 0.45 if ghost else 1.0)
	sb.set_border_width_all(3 if full else 2)
	draw_style_box(sb, r)
	var trinket := ItemIcons.is_trinket(kind)
	if trinket and full:
		var inner := StyleBoxFlat.new()
		inner.bg_color = Color(0, 0, 0, 0)
		inner.border_color = Color(1.0, 0.96, 0.75, 0.5)
		inner.set_border_width_all(1)
		inner.set_corner_radius_all(radius - 3)
		draw_style_box(inner, r.grow(-4.0))
	# The icon: as tall as the slot allows, centred (across both halves of a wide slot).
	var side := minf(r.size.y, SLOT_PX + 8.0 if sel else SLOT_PX) - (12.0 if full else 6.0)
	var box := Rect2(r.get_center() - Vector2(side, side) * 0.5, Vector2(side, side))
	var tex := ItemIcons.bare(kind)
	var spoil := _spoil_of(kind, s)
	var used: bool = bool(s.get("used", false))
	var grey_k := 0.0
	if not spoil.is_empty():
		grey_k = 1.0 if bool(spoil.spoiled) else clampf(1.0 - float(spoil.frac), 0.0, 1.0)
	if used:
		grey_k = 1.0
	var a := 0.45 if ghost else 1.0
	if tex != null:
		draw_texture_rect(tex, box, false, Color(1, 1, 1, a))
		if grey_k > 0.01:
			var gt := ItemIcons.grey(kind)
			if gt != null:
				draw_texture_rect(gt, box, false, Color(0.86, 0.86, 0.86, a * grey_k))
	else:
		# No icon yet (a new kind): its first letters on a plain slot, in its category colour.
		var abbr := Items.display_name(kind).substr(0, 2).to_upper()
		_text(r.position + Vector2(0, r.size.y * 0.5 + 8), abbr, 22, Color(border, 0.9 * a), HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	if used and full:
		_draw_crack(box)
	if not full:
		return
	if not spoil.is_empty() and not bool(spoil.spoiled):
		var f: float = clampf(float(spoil.frac), 0.0, 1.0)
		var rc := Color("5ccf6a").lerp(Color("e0a020"), clampf((1.0 - f) * 2.0, 0.0, 1.0)).lerp(Color("e8322e"), clampf((0.5 - f) * 2.0, 0.0, 1.0))
		_draw_ring(r.grow(2.5), f, rc)
	_text(r.position + Vector2(6, 13), keys, 10, Color("dfe8ee", 0.75))
	if wide:
		_text(r.position + Vector2(r.size.x - 14, 13), "%d" % (int(keys) + 1), 10, Color("dfe8ee", 0.75))
	if trinket:
		_glint(r.position + Vector2(11, r.size.y - 11), 6.0)
	var count := int(s.get("count", 0))
	if count > 1 and not ghost:
		var label := "x%d" % count
		var tw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var pill := Rect2(r.end.x - tw - 12.0, r.end.y - 20.0, tw + 9.0, 16.0)
		var pb := StyleBoxFlat.new()
		pb.bg_color = Color(0, 0, 0, 0.82)
		pb.border_color = Color(border, 0.9)
		pb.set_border_width_all(1)
		pb.set_corner_radius_all(6)
		draw_style_box(pb, pill)
		_text(Vector2(pill.position.x + 4.5, pill.end.y - 3.5), label, 13, Color("ffffff"))


## A small four-point sparkle.
func _glint(c: Vector2, k: float) -> void:
	var col := Color(1.0, 0.96, 0.75, 0.9)
	draw_line(c + Vector2(-k, 0), c + Vector2(k, 0), col, 1.5)
	draw_line(c + Vector2(0, -k), c + Vector2(0, k), col, 1.5)
	draw_line(c + Vector2(-k, -k) * 0.4, c + Vector2(k, k) * 0.4, col, 1.0)
	draw_line(c + Vector2(-k, k) * 0.4, c + Vector2(k, -k) * 0.4, col, 1.0)


## A jagged crack across an icon box: a used-up trinket.
func _draw_crack(b: Rect2) -> void:
	var p := PackedVector2Array([b.position + b.size * Vector2(0.72, 0.02), b.position + b.size * Vector2(0.56, 0.24),
		b.position + b.size * Vector2(0.64, 0.38), b.position + b.size * Vector2(0.44, 0.55),
		b.position + b.size * Vector2(0.52, 0.68), b.position + b.size * Vector2(0.3, 0.98)])
	draw_polyline(p, Color(0, 0, 0, 0.85), 4.0)
	draw_polyline(p, Color(1, 1, 1, 0.75), 1.5)


## A ring around a slot that drains clockwise from the top as `f` (1 full .. 0 gone) falls.
func _draw_ring(r: Rect2, f: float, col: Color) -> void:
	var c := r.get_center()
	var pts := [Vector2(c.x, r.position.y), Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
		r.position, Vector2(c.x, r.position.y)]
	var total := 0.0
	for k in range(pts.size() - 1):
		total += (pts[k + 1] - pts[k]).length()
	draw_polyline(PackedVector2Array(pts), Color(0, 0, 0, 0.5), 3.0)
	var left := total * clampf(f, 0.0, 1.0)
	var line := PackedVector2Array([pts[0]])
	for k in range(pts.size() - 1):
		var seg: float = (pts[k + 1] - pts[k]).length()
		if left >= seg:
			line.append(pts[k + 1])
			left -= seg
		else:
			line.append(pts[k].lerp(pts[k + 1], left / maxf(seg, 0.001)))
			break
	if line.size() > 1:
		draw_polyline(line, Color(col, 0.95), 3.0)


## How fresh a body part in `s` is: {frac: 1 fresh .. 0 gone, spoiled: bool}, or {} for anything that
## does not spoil. Eyes and brains come from their own systems; any other kind can carry the numbers in
## its stack as `fresh` (0..1) and `spoiled` (the seam grafting's other parts use).
func _spoil_of(kind: String, s: Dictionary) -> Dictionary:
	if game == null:
		return {}
	if Eyes.is_eye(kind) and game.get("vats") != null:
		var f: float = game.vats.eye_factor(s)
		return {"frac": 1.0 - Eyes.rot_of(f), "spoiled": Eyes.is_spoiled_factor(f)}
	if game.brains != null and game.brains.is_brain(kind):
		var f2: float = game.brains.factor_of(s)
		return {"frac": clampf((f2 - game.brains.MIN_FACTOR) / (1.0 - game.brains.MIN_FACTOR), 0.0, 1.0), "spoiled": f2 < game.brains.ROTTEN_FACTOR}
	if s.has("fresh"):
		return {"frac": float(s.fresh), "spoiled": bool(s.get("spoiled", float(s.fresh) <= 0.0))}
	return {}


## Watches the hands: a new item in a slot starts the pickup pop and (when it is what you hold now)
## the name above the bar; switching slots flashes the name of what you now hold.
func _track_hands(me, sel_head: int) -> void:
	var n: int = me.slots.size()
	var owner: int = int(me.peer_id)
	if owner != _seen_owner or _seen.size() != n:
		_seen_owner = owner
		_seen = []
		_pops.clear()
		for i in n:
			_seen.append([String(me.slots[i].kind), int(me.slots[i].count)])
		_held_sig = _sig_of(me, sel_head)
		_flash_until = -1.0
		return
	for i in n:
		var kind := String(me.slots[i].kind)
		var count: int = int(me.slots[i].count)
		var was: Array = _seen[i]
		if kind != "" and (was[0] != kind or count > int(was[1])) and not game.paused:
			_pops.append({"kind": kind, "t0": _t, "slot": i})
			if _pops.size() > 6:
				_pops.pop_front()
		_seen[i] = [kind, count]
	var sig := _sig_of(me, sel_head)
	if sig != _held_sig:
		_held_sig = sig
		var k := String(me.slots[sel_head].kind)
		if k != "":
			_flash_name = _held_name(k, me.slots[sel_head])
			_flash_until = _t + NAME_SECONDS


func _sig_of(me, sel_head: int) -> String:
	return "%d:%s" % [sel_head, String(me.slots[sel_head].kind)]


func _held_name(kind: String, s: Dictionary) -> String:
	if Eyes.is_eye(kind):
		return Eyes.label(kind, String(s.get("x", "")))
	return Items.display_name(kind)


## The held item's name over the bar, for NAME_SECONDS, fading over the last half second.
func _draw_name_flash(w: float, bar_y: float, t: float) -> void:
	if _t > _flash_until or t > 0.5 or _flash_name == "":
		return
	drawn.append("item_name")
	var left := _flash_until - _t
	var a := clampf(left / 0.5, 0.0, 1.0) * clampf((NAME_SECONDS - left) / 0.08, 0.0, 1.0)
	var y := bar_y - 28.0
	var tw := _font.get_string_size(_flash_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	draw_rect(Rect2(w * 0.5 - tw * 0.5 - 12, y - 19, tw + 24, 28), Color(0, 0, 0, 0.55 * a))
	_text(Vector2(0, y), _flash_name, 18, Color(SELECT_COL, a), HORIZONTAL_ALIGNMENT_CENTER, w)


## The pickup pop: the icon jumps up out of the crosshair and flies into the slot it landed in.
func _draw_pops(w: float, h: float) -> void:
	if _pops.is_empty():
		return
	var live := []
	var from := Vector2(w, h) * 0.5
	for p in _pops:
		var u: float = (_t - float(p.t0)) / POP_SECONDS
		if u >= 1.0:
			continue
		live.append(p)
		var to: Vector2 = _slot_ctr.get(int(p.slot), Vector2(w * 0.5, h - 50.0))
		var e := u * u * (3.0 - 2.0 * u)
		var pos := from.lerp(to, e) + Vector2(0, -34.0 * sin(u * PI))
		var side := lerpf(22.0, 44.0, e) + 26.0 * sin(u * PI)
		var tex := ItemIcons.bare(String(p.kind))
		var a := clampf((1.0 - u) / 0.15, 0.0, 1.0)
		if tex != null:
			draw_texture_rect(tex, Rect2(pos - Vector2(side, side) * 0.5, Vector2(side, side)), false, Color(1, 1, 1, a))
		else:
			draw_circle(pos, side * 0.35, Color(ItemIcons.border(String(p.kind)), 0.8 * a))
	_pops = live
	if not _pops.is_empty():
		drawn.append("pickup_pop")


## SWEEP 4A HOOK (controls): the 4 ability slots, drawn as circular icon slots (rebuilt from the
## original flat rectangles). Small top-left of the hands bar normally; while Alt is held they
## slide/grow into the bar itself (~0.12 s, `_alt_t`) and the item icons shrink to a small row
## where the abilities were -- the same big/small blend the rectangles used, just applied to a
## square bounding box that a circle is inscribed in. Each slot: a per-ability vector glyph, a
## cooldown sweep (now a radial arc instead of a bottom bar), level pips, a cost tag, the key hint,
## and (Alt held) the ability's name and, when it cannot fire, why.
func _draw_ability_bar(w: float, h: float, me) -> void:
	var b := game.brains
	if b == null:
		return
	drawn.append("abilities")
	var slots: Array = b.slots_for(me.peer_id)
	var n: int = slots.size()
	var box := Vector2(48, 48)
	var gap := 18.0
	var x0 := w * 0.5 - (box.x * n + gap * (n - 1)) * 0.5
	# Big (Alt-held) circles centre on the old hands-bar top edge, leaving room below for the pip
	# row and the ability name/reason text without crowding the bottom control-hint line.
	var bar_y := h - BAR_MARGIN - SLOT_PX
	var big_y := bar_y - 2.0   # just under the small item row, room below for the pips and the name
	var small := Vector2(26, 26)
	var small_y := bar_y - small.y - 6.0
	var t := clampf(_alt_t, 0.0, 1.0)
	for i in n:
		var big_r := Rect2(x0 + i * (box.x + gap), big_y, box.x, box.y)
		var small_r := Rect2(x0 + i * (small.x + 4.0), small_y, small.x, small.y)
		# Inverted from the hands bar's own t: idle (t=0, Alt not held) is the SMALL corner row and
		# Alt held (t=1) grows into the BIG bottom row -- the two bars swap spots rather than
		# overlapping (see _draw_hands's comment on the shared `_alt_t`).
		var r := Rect2(small_r.position.lerp(big_r.position, t), small_r.size.lerp(big_r.size, t))
		var c := r.get_center()
		var rad := r.size.x * 0.5
		var id := String(slots[i])
		var name: String = String(ABILITY_LABEL.get(id, ""))
		var lvl: int = b.level(me.peer_id, String(b.ABILITY_ID_TO_PATH.get(id, ""))) if id != "" else 0
		var cd: float = b.cooldown_left(me.peer_id, String(b.ABILITY_ID_TO_PATH.get(id, ""))) if id != "" else 0.0
		var reason := _slot_reason(me, id, cd)
		var usable := id != "" and reason == ""
		var icon := ItemIcons.ability(id) if id != "" else null
		var in_use := _ability_in_use(me, b, id, lvl, cd)
		if icon != null:
			# The round icon carries its own frame; the HUD adds the glow in the ability's colour:
			# steady when ready, stronger while it runs, dim on cooldown.
			var gcol: Color = ItemIcons.ABILITY_COLOR.get(id, Color.WHITE)
			var ga := 0.5 if usable else 0.14
			if in_use:
				ga = 0.85 + 0.15 * sin(_t * 9.0)
			for k in 4:
				draw_circle(c, rad + 1.0 + k * (3.0 if t > 0.3 else 1.6), Color(gcol, ga * (0.32 - k * 0.075)))
		else:
			draw_circle(c, rad, Color(0, 0, 0, 0.55))
		var ready_pulse := 0.0
		# SWEEP 4A HOOK (Hive Eyes, chunk 4): a subtle pulse on the ring while a Hive is in range
		# and the slot is otherwise idle, so you know it is worth pressing.
		if id == "hive_in" and cd <= 0.0 and not me.get("hive_view") and b.nearest_hive(me, b.hive_range(lvl)) != null:
			ready_pulse = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
			draw_arc(c, rad + 3.0, 0.0, TAU, 28, Color("9fe8a0", 0.35 + 0.35 * ready_pulse), 2.0 + ready_pulse * 1.5)
		var border := Color("f0e6c8", 0.85) if id != "" else Color(0.5, 0.55, 0.6, 0.4)
		if icon == null:
			draw_arc(c, rad - 0.75, 0.0, TAU, 28, border, 1.5)
		if id == "":
			continue
		if icon != null:
			draw_texture_rect(icon, Rect2(c - Vector2(rad, rad), Vector2(rad, rad) * 2.0), false, Color(1, 1, 1, 1.0 if usable else 0.6))
		else:
			_draw_ability_icon(id, c, rad, usable)
		if not usable:
			draw_circle(c, rad, Color(0, 0, 0, 0.45 if icon == null else 0.3))
		if cd > 0.0:
			# A radial sweep standing in for the old bottom cooldown bar: it drains clockwise from
			# the top as the ability comes back off cooldown.
			var frac: float = clampf(cd / (20.0 if id == "echo" else 12.0), 0.0, 1.0)
			draw_arc(c, rad - 3.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, Color("5ce0d0", 0.85), 3.0)
		if t < 0.7:
			_text(Vector2(c.x - rad, r.position.y - 2), "Alt+%d" % (i + 1), 9, Color("8a9aa0"))
		for pip in lvl:
			draw_circle(c + Vector2((pip - (lvl - 1) * 0.5) * 8.0, rad + 5.0), 2.0, Color("9fe8a0"))
		var cost := String(ABILITY_COST.get(id, ""))
		if cost != "" and t < 0.7:
			_text(Vector2(c.x + rad - 30.0, r.position.y + 10.0), cost, 9, Color("e0a020"))
		if t > 0.4:
			_text(Vector2(c.x - box.x, c.y + rad + 14.0), _fit(name, 11, box.x * 2.0), 11, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, box.x * 2.0)
			if reason != "":
				_text(Vector2(0, small_y - 8.0), reason, 11, Color("e0a020"), HORIZONTAL_ALIGNMENT_CENTER, w)


## Whether the ability is running right now (a Hive view open; Echo's outline still showing).
func _ability_in_use(me, b, id: String, lvl: int, cd: float) -> bool:
	if id == "hive_in":
		return bool(me.get("hive_view"))
	if id == "echo":
		return cd > b.ECHO_COOLDOWN - b.echo_seconds(lvl)
	return false


## A small procedural glyph per ability, centered at `c` and scaled off the slot radius `rad`.
## Echo: concentric arcs opening upward, like a sound pulse. Hive Eyes: a simple almond eye with
## a pupil. Dimmed (usable == false) glyphs draw at lower alpha, same spirit as the old dim tint.
func _draw_ability_icon(id: String, c: Vector2, rad: float, usable: bool) -> void:
	var a := 1.0 if usable else 0.45
	match id:
		"echo":
			var col := Color("5ce0d0", a)
			draw_circle(c, rad * 0.12, col)
			for ring in 3:
				var r2: float = rad * (0.32 + ring * 0.22)
				draw_arc(c, r2, -PI * 0.62, -PI * 0.38, 10, col, 2.0)
				draw_arc(c, r2, PI * 0.38, PI * 0.62, 10, col, 2.0)
		"hive_in":
			var col := Color("9fe8a0", a)
			var pts := PackedVector2Array()
			var k := rad * 0.62
			for i in 13:
				var u: float = lerpf(-1.0, 1.0, float(i) / 12.0)
				pts.append(c + Vector2(u * k, -sqrt(maxf(0.0, 1.0 - u * u)) * k * 0.55))
			for i in 13:
				var u: float = lerpf(1.0, -1.0, float(i) / 12.0)
				pts.append(c + Vector2(u * k, sqrt(maxf(0.0, 1.0 - u * u)) * k * 0.55))
			draw_polyline(pts, col, 1.75, true)
			draw_circle(c, rad * 0.22, col)
			draw_circle(c - Vector2(rad * 0.06, rad * 0.06), rad * 0.07, Color("0a0c0e", a))
		_:
			pass


## Why a slot cannot fire right now, "" when it can (or it is empty / not the local player's).
func _slot_reason(me, id: String, cd: float) -> String:
	if id == "":
		return ""
	if not me.alive or me.downed:
		return "Not now"
	if cd > 0.0:
		return "Cooling down (%d s)" % ceili(cd)
	if id == "hive_in" and (me.carrying != 0 or me.operating):
		return "Hands busy"
	if id == "hive_in" and not me.get("hive_view"):
		var b = game.brains
		var lvl: int = b.level(me.peer_id, "hive")
		if b.nearest_hive(me, b.hive_range(lvl)) == null:
			return "No Hive in range"
	return ""


## SWEEP 4A HOOK (scanner): a small progress ring at the crosshair while R is held on a monster.
func _draw_scan_ring(w: float, h: float, me) -> void:
	if not bool(me.get("scan_holding")) or float(me.get("scan_progress")) <= 0.001:
		return
	drawn.append("scan_ring")
	var c := Vector2(w, h) * 0.5
	var prog: float = float(me.scan_progress)
	draw_arc(c, 22.0, -PI * 0.5, -PI * 0.5 + TAU * prog, 32, Color("5ce0d0", 0.9), 3.0)
	draw_arc(c, 22.0, 0.0, TAU, 32, Color(1, 1, 1, 0.15), 1.5)


## SWEEP 4A HOOK (scanner): a scan just completed on this machine (scan_fx.gd).
func show_scan_banner(specimen: String) -> void:
	_scan_banner_name = specimen
	_scan_banner_until = _t + 2.4


func _draw_scan_banner(w: float, h: float) -> void:
	if _t > _scan_banner_until:
		return
	drawn.append("scan_banner")
	var left := _scan_banner_until - _t
	var a := clampf(left / 0.5, 0.0, 1.0) * clampf((2.4 - left) / 0.12, 0.0, 1.0)
	var col := Color("5ce0d0")
	var box := Rect2(w * 0.5 - 170, h * 0.5 + 44, 340, 70)
	draw_rect(box, Color(0.01, 0.06, 0.06, 0.78 * a))
	draw_rect(box, Color(col, 0.8 * a), false, 1.5)
	# Corner ticks, a scanner readout rather than a dialog box.
	for c in [box.position, Vector2(box.end.x, box.position.y), Vector2(box.position.x, box.end.y), box.end]:
		var sx := 1.0 if c.x < w * 0.5 else -1.0
		var sy := 1.0 if c.y < box.get_center().y else -1.0
		draw_line(c, c + Vector2(14 * sx, 0), Color(col, a), 3.0)
		draw_line(c, c + Vector2(0, 14 * sy), Color(col, a), 3.0)
	_text(Vector2(box.position.x, box.position.y + 26), "SCAN COMPLETE", 20, Color(col, a), HORIZONTAL_ALIGNMENT_CENTER, box.size.x)
	_text(Vector2(box.position.x, box.position.y + 50), "%s  -  database entry updated" % _scan_banner_name.to_upper(), 13, Color(0.8, 0.95, 0.92, a), HORIZONTAL_ALIGNMENT_CENTER, box.size.x)


## SWEEP 4A HOOK: the first-ability card, closing itself after a few seconds or on any key.
func _draw_ability_card(w: float, h: float) -> void:
	var id := ""
	var until := 0.0
	for k in _card_until.keys():
		if float(_card_until[k]) > until:
			until = float(_card_until[k])
			id = String(k)
	if id == "" or _t > until:
		return
	drawn.append("ability_card")
	var name: String = String(ABILITY_LABEL.get(id, id))
	var desc: String = String(ABILITY_DESC.get(id, ""))
	var cost: String = String(ABILITY_COST.get(id, ""))
	var box := Rect2(w * 0.5 - 190, h * 0.28, 380, 96)
	draw_rect(box, Color(0.03, 0.04, 0.06, 0.9))
	draw_rect(box, Color("f0e6c8", 0.6), false, 1.5)
	_text(Vector2(box.position.x, box.position.y + 24), "New ability: %s" % name, 18, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, box.size.x)
	_text(Vector2(box.position.x + 14, box.position.y + 48), desc, 12, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 28)
	var foot := "Press any key to close" if cost == "" else "Cost: %s   Press any key to close" % cost
	_text(Vector2(box.position.x, box.position.y + 82), foot, 11, Color("8a9aa0"), HORIZONTAL_ALIGNMENT_CENTER, box.size.x)


## Shorten a label with an ellipsis until it fits `width` pixels at `size_px`.
func _fit(s: String, size_px: int, width: float) -> String:
	if _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x <= width:
		return s
	while s.length() > 3 and _font.get_string_size(s + "..", HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x > width:
		s = s.substr(0, s.length() - 1)
	return s + ".."


## Team money, small, bottom right: only near the sell bin, the shop or the pile, or for a few
## seconds after it changed (with the change beside it).
func _draw_money(w: float, h: float, me) -> void:
	if game.economy == null or not game.economy.money_visible_for(me):
		return
	drawn.append("money")
	var text := "$%s" % _grouped(int(game.money))
	var size_px := 24
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	var x := w - tw - 22.0
	var y := h - 26.0
	draw_rect(Rect2(x - 10, y - 25, tw + 20, 34), Color(0, 0, 0, 0.62))
	_text(Vector2(x, y), text, size_px, SLOT_GOLD)
	var d: int = int(game.economy.last_delta)
	if game.economy.flash > 0.0 and d != 0:
		var a := clampf(game.economy.flash / 1.0, 0.0, 1.0)
		var dt := ("+$%s" if d > 0 else "-$%s") % _grouped(absi(d))
		var dw := _font.get_string_size(dt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_text(Vector2(w - dw - 22.0, y - 34), dt, 16, Color(Color("5cff8a") if d > 0 else Color("ff8a6a"), a))


static func _grouped(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if v < 0 else "") + s + out


func _draw_dead_banner(w: float) -> void:
	drawn.append("dead_banner")
	draw_rect(Rect2(w * 0.5 - 230, 60, 460, 50), Color(0, 0, 0, 0.6))
	# net hook: someone who joined mid-shift watches until the next shift starts.
	var waiting: bool = game.waiting_peers.has(Net.my_id())
	_text(Vector2(0, 82), "SHIFT IN PROGRESS" if waiting else "YOU ARE DEAD", 17, Color("ffd35c") if waiting else Color("ff6a6a"), HORIZONTAL_ALIGNMENT_CENTER, w)
	var watching = game.viewed_player()
	var text := "Nobody left to watch."
	if watching != null and watching != game.local_player():
		text = ("Watching %s. You clock in at the next shift." if waiting else "Watching %s. You are back next shift.") % watching.player_name
	_text(Vector2(0, 102), text, 13, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, w)


## Hold-E progress for the time clock and for lifting a downed teammate.
func _draw_holds(w: float, h: float) -> void:
	var progress := 0.0
	var label := ""
	var me = game.driving_player()
	if game.phase == Game.Phase.LOBBY and game.punch > 0.0:
		progress = game.punch
		label = "CLOCKING IN"
	elif game.phase == Game.Phase.SHIFT and game.punch > 0.0:
		progress = game.punch   # loop: clocking out
		label = "CLOCKING OUT"
	elif me != null and me.carry_hold > 0.0:   # downed hook
		# GRAFT HOOK: the table has two holds of its own -- lying down, and getting back up.
		var strapping: bool = String(me.aim_prompt) == Game.STRAP_IN_PROMPT
		var full: float = Game.TABLE_UP_HOLD if me.on_table else (Game.TABLE_STRAP_HOLD if strapping else Game.CARRY_HOLD)
		progress = clampf(me.carry_hold / full, 0.0, 1.0)
		label = "GETTING UP" if me.on_table else ("STRAPPING IN" if strapping else "LIFTING")
	elif me != null and game.brains != null and game.brains.blend_progress(me.peer_id) > 0.0:   # SWEEP 3 HOOK (brains)
		progress = game.brains.blend_progress(me.peer_id)
		label = "BLENDING"
	if progress <= 0.0:
		return
	drawn.append("hold")
	var cx := w * 0.5
	var y := h * 0.5 + 78.0
	draw_rect(Rect2(cx - 112, y - 8, 224, 16), Color(0, 0, 0, 0.7))
	draw_rect(Rect2(cx - 110, y - 6, 220 * progress, 12), Color("5ce0d0"))
	_text(Vector2(0, y - 16), "%s..." % label, 14, Color("ffffff"), HORIZONTAL_ALIGNMENT_CENTER, w)


func _draw_message(w: float, h: float, in_surgery: bool) -> void:
	if game.message_timer <= 0.0:
		return
	drawn.append("message")
	var text := game.message
	var y := h - 150.0 if not in_surgery else 90.0
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_rect(Rect2(w * 0.5 - tw * 0.5 - 14, y - 20, tw + 28, 30), Color(0, 0, 0, 0.65))
	_text(Vector2(0, y), text, 16, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)


func _overlay(w: float, h: float, title: String, sub: String, prompt: String, col: Color) -> void:
	drawn.append("overlay")
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.72))
	_text(Vector2(0, h * 0.4), title, maxi(18, int(minf(72, w / 12.0))), col, HORIZONTAL_ALIGNMENT_CENTER, w)
	_text(Vector2(0, h * 0.4 + 46), sub, 16, Color("cccccc"), HORIZONTAL_ALIGNMENT_CENTER, w)
	if prompt != "":
		_text(Vector2(0, h * 0.4 + 82), prompt, 16, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, w)
