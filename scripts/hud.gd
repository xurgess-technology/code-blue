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
var _hint_timer: float = 45.0
var _font: Font
var _stamina_show: float = 0.0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	if _hint_timer > 0.0:
		_hint_timer -= delta
	var me = game.local_player() if game != null else null
	var tired: bool = me != null and me.stamina < 0.995
	_stamina_show = clampf(_stamina_show + (delta * 4.0 if tired else -delta * 1.5), 0.0, 1.0)
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
		_draw_health(h, me)
	if me != null and not in_surgery:
		_draw_money(w, h, me)
	if me != null and not me.alive:
		_draw_dead_banner(w)
	_draw_holds(w, h)
	_draw_host_info(w)
	_draw_message(w, h, in_surgery)
	if not in_surgery:
		_draw_hint(w, h)
	if game.paused:
		_overlay(w, h, "PAUSED", "Esc to resume, Q to walk out." if not Net.solo else "The night shift waits for no one.", "", Color("c9d1d9"))
	elif game.phase == Game.Phase.LOST:
		# loop: a team failure ends the run.
		_overlay(w, h, "GAME OVER", game.message, "Money and gold reset. A new run starts in %d" % ceili(game.end_timer), Color("ff2a2a"))
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


## Your own hearts, bottom left, with a thin stamina bar under them while it is not full.
func _draw_health(h: float, me) -> void:
	drawn.append("health")
	var x := 24.0
	var y := h - 46.0
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
	drawn.append("crosshair")
	var c := Vector2(w, h) * 0.5
	var me = game.local_player()
	var spread: float = 9.0 if me.sprinting else (6.0 if me.moving else 4.0)
	var col := Color(1, 1, 1, 0.55) if me.aim_id == "" else Color(1.0, 0.95, 0.7, 0.9)
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
			var text: String = me.aim_prompt if me.aim_prompt.begins_with("Hold E") else "%s %s" % [key, me.aim_prompt]
			_text(Vector2(0, y), text, 16, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)
		y += 20.0
	var guide_here: bool = me.holding("guide")
	if not guide_here and me.aim_id.begins_with("it_"):
		var node := game.find_interactable(me.aim_id)
		guide_here = node != null and node.get("kind") == "guide"
	if guide_here:
		_text(Vector2(0, y), "[R] Read the medical guide", 13, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, w)


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
	var rects := []
	for i in n:
		rects.append(Rect2(x0 + i * (box.x + gap), y, box.x, box.y))
	# Bridges between a bulky stack and its second half, drawn under the boxes.
	for i in n:
		var t: int = me.tail_of(i)
		if t < 0 or String(me.slots[i].kind) == "":
			continue
		var a: Rect2 = rects[mini(i, t)]
		var b: Rect2 = rects[maxi(i, t)]
		if absi(i - t) == 1:
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
		_text(r.position + Vector2(5, 13), "%d" % (i + 1), 10, Color("8a9aa0"))
		if s.has("of"):
			# Second half of a bulky stack: hatched.
			for k in 6:
				var x := r.position.x + 12.0 + k * 16.0
				draw_line(Vector2(x, r.end.y - 5), Vector2(x + 10, r.position.y + 5), Color(SLOT_GOLD, 0.18), 1.5)
			var head_name := _fit(Items.display_name(kind), 11, box.x - 10)
			_text(r.position + Vector2(0, 22), head_name, 11, Color(SLOT_GOLD, 0.75), HORIZONTAL_ALIGNMENT_CENTER, box.x)
			_text(r.position + Vector2(0, 35), "(2nd slot)", 10, Color(0.75, 0.75, 0.75, 0.7), HORIZONTAL_ALIGNMENT_CENTER, box.x)
			continue
		if kind == "":
			continue
		var label: String = Items.def(kind).get("short", Items.display_name(kind)) if int(s.count) > 1 else Items.display_name(kind)
		label = _fit(label, 12, box.x - 10)
		_text(r.position + Vector2(0, 25), label, 12, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		if int(s.count) > 1:
			_text(r.position + Vector2(0, 37), "x%d" % int(s.count), 10, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		elif int(s.get("v", 0)) > 0:
			_text(r.position + Vector2(0, 37), "$%d" % int(s.v), 10, Color(SLOT_GOLD, 0.95), HORIZONTAL_ALIGNMENT_CENTER, box.x)
		if int(s.count) > 1 and int(s.get("v", 0)) > 0:
			_text(r.position + Vector2(box.x - 34, 13), "$%d" % int(s.v), 10, Color(SLOT_GOLD, 0.95))


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


func _draw_hint(w: float, h: float) -> void:
	if _hint_timer <= 0.0:
		return
	drawn.append("hint")
	_text(Vector2(0, h - 8),
		"WASD move   MOUSE look   SHIFT sprint   F light   E use   G set down   1-4 slots   R read guide   Q shove   ESC pause",
		12, Color(0.67, 0.67, 0.67, minf(1.0, _hint_timer / 2.0)), HORIZONTAL_ALIGNMENT_CENTER, w)


func _overlay(w: float, h: float, title: String, sub: String, prompt: String, col: Color) -> void:
	drawn.append("overlay")
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.72))
	_text(Vector2(0, h * 0.4), title, maxi(18, int(minf(72, w / 12.0))), col, HORIZONTAL_ALIGNMENT_CENTER, w)
	_text(Vector2(0, h * 0.4 + 46), sub, 16, Color("cccccc"), HORIZONTAL_ALIGNMENT_CENTER, w)
	if prompt != "":
		_text(Vector2(0, h * 0.4 + 82), prompt, 16, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, w)
