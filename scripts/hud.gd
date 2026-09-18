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
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	var me = game.local_player() if game != null else null
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
	var me = game.local_player()
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
	var me = game.local_player()
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
			_text(Vector2(0, y), me.aim_prompt.substr(1), 14, Color("e0a020"), HORIZONTAL_ALIGNMENT_CENTER, w)
		else:
			var key := "[E]" if me.aim_hold <= 0.0 or me.aim_prompt.begins_with("Hold E") else "[Hold E]"
			# HANDS HOOK: a prompt that names its own key ("[Click] Jab it") is shown as it is.
			var text: String = me.aim_prompt if me.aim_prompt.begins_with("Hold E") or me.aim_prompt.begins_with("[") else "%s %s" % [key, me.aim_prompt]
			_text(Vector2(0, y), text, 16, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)
		y += 20.0


const SLOT_TEAL := Color(0.3, 0.9, 0.82)
const SLOT_GOLD := Color(1.0, 0.74, 0.28)


## The slot bar (inventory, sweep 2): four compact boxes at the bottom centre. A surgical stack
## has a teal edge, loot a gold one with its value; a bulky stack's second slot is hatched in
## gold and bridged to its stack. The selected stack (both halves when bulky) is outlined.
func _draw_hands(w: float, h: float, me) -> void:
	drawn.append("hands")
	var n: int = me.slots.size()
	var box := Vector2(112, 40)
	var gap := 6.0
	var x0 := w * 0.5 - (box.x * n + gap * (n - 1)) * 0.5
	var y := h - 66.0
	var sel_head: int = me.selected_head()
	# SWEEP 4A HOOK (controls): while Alt is held, the item bar slides up and shrinks into the same
	# small top-left row the ability bar's icons occupy when idle (_draw_ability_bar), and the
	# ability bar grows into this row instead. `t` is the same `_alt_t` both bars share, so they
	# cross-fade into each other's spot over ~0.12 s rather than overlapping.
	var t := clampf(_alt_t, 0.0, 1.0)
	var small := Vector2(30, 20)
	var small_y := y - small.y - 6.0
	var rects := []
	for i in n:
		var big_r := Rect2(x0 + i * (box.x + gap), y, box.x, box.y)
		var small_r := Rect2(x0 + i * (small.x + 4.0), small_y, small.x, small.y)
		rects.append(Rect2(big_r.position.lerp(small_r.position, t), big_r.size.lerp(small_r.size, t)))
	# Bridges between a bulky stack and its second half, drawn under the boxes (full size only).
	if t < 0.5:
		for i in n:
			var tail: int = me.tail_of(i)
			if tail < 0 or String(me.slots[i].kind) == "":
				continue
			var a: Rect2 = rects[mini(i, tail)]
			var b: Rect2 = rects[maxi(i, tail)]
			if absi(i - tail) == 1:
				draw_rect(Rect2(a.end.x - 2, a.position.y + 12, b.position.x - a.end.x + 4, box.y - 24), Color(SLOT_GOLD, 0.55))
			else:
				var ya := a.position.y - 4.0
				draw_line(Vector2(a.get_center().x, ya), Vector2(b.get_center().x, ya), Color(SLOT_GOLD, 0.75), 2.0)
				draw_line(Vector2(a.get_center().x, ya), Vector2(a.get_center().x, a.position.y), Color(SLOT_GOLD, 0.75), 2.0)
				draw_line(Vector2(b.get_center().x, ya), Vector2(b.get_center().x, b.position.y), Color(SLOT_GOLD, 0.75), 2.0)
	for i in n:
		var s: Dictionary = me.slots[i]
		var r: Rect2 = rects[i]
		var head: int = me.head_of(i)
		var sel: bool = head == sel_head
		var kind := String(me.slots[head].kind)
		draw_rect(r, Color(0, 0, 0, 0.72 if sel else 0.55))
		var accent := Color(0.5, 0.55, 0.6, 0.55)
		if kind != "" and Items.is_surgical(kind):
			accent = SLOT_TEAL
		elif kind != "" and Items.is_loot(kind):
			accent = SLOT_GOLD
		if kind != "":
			draw_rect(Rect2(r.position.x, r.end.y - 3, r.size.x, 3), Color(accent, 0.85))
		draw_rect(r, Color("f0e6c8") if sel else Color(0.5, 0.55, 0.6, 0.5), false, 2.0 if sel else 1.0)
		if t < 0.5:
			_text(r.position + Vector2(5, 13), "%d" % (i + 1), 10, Color("8a9aa0"))
		if kind == "":
			continue
		if t >= 0.5:
			# Shrunk: just the key and a one-letter/short hint, same spirit as the ability bar's
			# small idle icons.
			_text(r.position + Vector2(3, 14), "%d" % (i + 1), 9, Color("8a9aa0"))
			continue
		if s.has("of"):
			# Second half of a bulky stack: hatched.
			for k in 6:
				var x := r.position.x + 12.0 + k * 16.0
				draw_line(Vector2(x, r.end.y - 5), Vector2(x + 10, r.position.y + 5), Color(SLOT_GOLD, 0.18), 1.5)
			var head_name := _fit(Items.display_name(kind), 11, box.x - 10)
			_text(r.position + Vector2(0, 22), head_name, 11, Color(SLOT_GOLD, 0.75), HORIZONTAL_ALIGNMENT_CENTER, box.x)
			_text(r.position + Vector2(0, 35), "(2nd slot)", 10, Color(0.75, 0.75, 0.75, 0.7), HORIZONTAL_ALIGNMENT_CENTER, box.x)
			continue
		var label: String = Items.def(kind).get("short", Items.display_name(kind)) if int(s.count) > 1 else Items.display_name(kind)
		label = _fit(label, 12, box.x - 10)
		_text(r.position + Vector2(0, 25), label, 12, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		if int(s.count) > 1:
			_text(r.position + Vector2(0, 37), "x%d" % int(s.count), 10, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		elif int(s.get("v", 0)) > 0:
			# SWEEP 3 HOOK (brains): a brain shows what it is worth now.
			var worth: int = int(game.brains.current_value(s)) if game.brains != null else int(s.v)
			_text(r.position + Vector2(0, 37), "$%d" % worth, 10, Color(SLOT_GOLD, 0.95), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		if int(s.count) > 1 and int(s.get("v", 0)) > 0:
			_text(r.position + Vector2(box.x - 34, 13), "$%d" % int(s.v), 10, Color(SLOT_GOLD, 0.95))


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
	var box := Vector2(52, 52)
	var gap := 14.0
	var x0 := w * 0.5 - (box.x * n + gap * (n - 1)) * 0.5
	# Big (Alt-held) circles centre on the old hands-bar top edge, leaving room below for the pip
	# row and the ability name/reason text without crowding the bottom control-hint line.
	var big_y := h - 66.0 - box.y * 0.5
	var small := Vector2(26, 26)
	var small_y := (h - 66.0) - small.y - 6.0
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
		draw_circle(c, rad, Color(0, 0, 0, 0.55))
		var ready_pulse := 0.0
		# SWEEP 4A HOOK (Hive Eyes, chunk 4): a subtle pulse on the ring while a Hive is in range
		# and the slot is otherwise idle, so you know it is worth pressing.
		if id == "hive_in" and cd <= 0.0 and not me.get("hive_view") and b.nearest_hive(me, b.hive_range(lvl)) != null:
			ready_pulse = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
			draw_arc(c, rad + 3.0, 0.0, TAU, 28, Color("9fe8a0", 0.35 + 0.35 * ready_pulse), 2.0 + ready_pulse * 1.5)
		var border := Color("f0e6c8", 0.85) if id != "" else Color(0.5, 0.55, 0.6, 0.4)
		draw_arc(c, rad - 0.75, 0.0, TAU, 28, border, 1.5)
		if id == "":
			continue
		_draw_ability_icon(id, c, rad, usable)
		if not usable:
			draw_circle(c, rad, Color(0, 0, 0, 0.45))
		if cd > 0.0:
			# A radial sweep standing in for the old bottom cooldown bar: it drains clockwise from
			# the top as the ability comes back off cooldown.
			var frac: float = clampf(cd / (20.0 if id == "echo" else 12.0), 0.0, 1.0)
			draw_arc(c, rad - 3.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 24, Color("5ce0d0", 0.85), 3.0)
		if t < 0.7:
			_text(Vector2(c.x - rad, r.position.y - 2), "Alt+%d" % (i + 1), 9, Color("8a9aa0"))
		for pip in lvl:
			draw_circle(c + Vector2((pip - (lvl - 1) * 0.5) * 8.0, rad + 8.0), 2.5, Color("9fe8a0"))
		var cost := String(ABILITY_COST.get(id, ""))
		if cost != "" and t < 0.7:
			_text(Vector2(c.x + rad - 30.0, r.position.y + 10.0), cost, 9, Color("e0a020"))
		if t > 0.4:
			_text(Vector2(c.x - box.x, c.y + rad + 16.0), _fit(name, 11, box.x * 2.0), 11, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, box.x * 2.0)
			if reason != "":
				_text(Vector2(0, r.position.y - 6), reason, 11, Color("e0a020"), HORIZONTAL_ALIGNMENT_CENTER, w)


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
	var me = game.local_player()
	if game.phase == Game.Phase.LOBBY and game.punch > 0.0:
		progress = game.punch
		label = "CLOCKING IN"
	elif game.phase == Game.Phase.SHIFT and game.punch > 0.0:
		progress = game.punch   # loop: clocking out
		label = "CLOCKING OUT"
	elif me != null and me.carry_hold > 0.0:   # downed hook
		progress = clampf(me.carry_hold / Game.CARRY_HOLD, 0.0, 1.0)
		label = "LIFTING"
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
