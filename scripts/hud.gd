class_name Hud
extends Control
## Everything drawn over the 3D view. One immediate-mode Control keeps it in one
## readable place instead of a pile of nodes. The surgery view draws its own panel
## (scripts/surgery/surgery_hud.gd) when that exists.

var game: Game = null
var host_info: String = ""

var _t: float = 0.0
var _hint_timer: float = 45.0
var _font: Font
var _surgery_has_hud: bool = false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_surgery_has_hud = ResourceLoader.exists("res://scripts/surgery/surgery_hud.gd")


func _process(delta: float) -> void:
	_t += delta
	if _hint_timer > 0.0:
		_hint_timer -= delta
	queue_redraw()


func _draw() -> void:
	if game == null or game.phase == Game.Phase.MENU:
		return
	var w := size.x
	var h := size.y
	var in_surgery: bool = game.surgery != null and game.surgery.camera() != null
	_draw_vignette(w, h)
	_draw_party()
	_draw_objective(w)
	_draw_case_panel(w)
	var me = game.local_player()
	if me != null and me.alive and not game.paused and not in_surgery:
		_draw_crosshair(w, h)
		_draw_prompt(w, h, me)
	if me != null and me.alive and not in_surgery:
		_draw_hands(w, h, me)
	if me != null and not in_surgery:
		_draw_money(w, h, me)
	if me != null and not me.alive:
		_draw_dead_banner(w)
	_draw_holds(w, h)
	if not _surgery_has_hud:
		_draw_surgery_fallback(w, h)
	_draw_message(w, h, in_surgery)
	_draw_hint(w, h)
	if game.paused:
		_overlay(w, h, "PAUSED", "Esc to resume, Q to walk out." if not Net.solo else "The night shift waits for no one.", "", Color("c9d1d9"))
	elif game.phase == Game.Phase.LOST:
		_overlay(w, h, "FLATLINE", game.message, "Back to the clock-in room in %d" % ceili(game.end_timer), Color("ff2a2a"))
	elif game.phase == Game.Phase.WON:
		_overlay(w, h, "PATIENT STABILIZED", "Shift %d complete. Punch out." % game.shift,
			"Shift %d starts in %d" % [game.shift + 1, ceili(game.end_timer)], Color("5cff8a"))


func _text(pos: Vector2, s: String, size_px: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(_font, pos, s, align, width, size_px, col)


func _draw_vignette(w: float, h: float) -> void:
	var red: float = maxf(0.0, game.danger * 0.28 * (0.5 + 0.5 * sin(_t * 6.0)))
	if red > 0.01:
		draw_rect(Rect2(0, 0, w, h), Color(0.55, 0.0, 0.0, red * 0.45))


func _draw_party() -> void:
	var y := 18.0
	var ids := Net.peer_ids()
	var mine := Net.my_id()
	ids.sort_custom(func(a, b): return a == mine or (b != mine and a < b))
	for id in ids:
		var p = game.players.get(id)
		if p == null:
			continue
		draw_rect(Rect2(12, y - 4, 230, 24), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(12, y - 4, 4, 24), p.colour)
		var label: String = ("> " if id == mine else "  ") + p.player_name.substr(0, 12)
		_text(Vector2(24, y + 13), label, 15, Color("eeeeee") if p.alive else Color("777777"))
		if p.operating:
			_text(Vector2(150, y + 13), "OPERATING", 11, Color("5cff8a"))
		elif p.alive:
			for i in p.max_hp:
				_heart(Vector2(160 + i * 18, y + 8), Color("e02a2a") if i < p.hp else Color("3a1414"))
		else:
			_text(Vector2(160, y + 13), "DEAD", 14, Color("ff6a6a"))
		y += 26.0

	var me = game.local_player()
	if me == null:
		return
	draw_rect(Rect2(12, y, 108, 10), Color(0, 0, 0, 0.55))
	draw_rect(Rect2(14, y + 2, 104 * me.stamina, 6), Color("e0a020") if me.stamina < 0.25 else Color("7ad0c0"))
	_text(Vector2(14, y + 30), "LIGHT ON  [F]" if me.flashlight_on else "LIGHT OFF [F]", 14,
		Color("ffe9a8") if me.flashlight_on else Color("777777"))


func _heart(at: Vector2, col: Color) -> void:
	draw_circle(at + Vector2(-3.5, -2), 4.0, col)
	draw_circle(at + Vector2(3.5, -2), 4.0, col)
	draw_colored_polygon(PackedVector2Array([at + Vector2(-7.4, -0.4), at + Vector2(7.4, -0.4), at + Vector2(0, 8)]), col)


## What the team still has to do, in one line.
func _draw_objective(w: float) -> void:
	var text := ""
	match game.phase:
		Game.Phase.LOBBY:
			text = "SHIFT %d. AIM AT THE TIME CLOCK AND HOLD E TO CLOCK IN." % game.shift
		Game.Phase.SHIFT:
			if game.case.is_empty():
				return
			var missing := _missing_supplies()
			if not missing.is_empty():
				text = "BRING TO THE OR SHELF: " + ", ".join(missing)
			else:
				var step := Procedures.step(game.case.ailment_id, int(game.case.step_index))
				var op_id: int = game.surgery.operator_id if game.surgery != null else 0
				if step.is_empty() or game.surgery.is_local_operating():
					pass   # the surgery HUD carries the step while operating
				elif op_id != 0:
					var op = game.players.get(op_id)
					text = "%s IS OPERATING: %s." % [(op.player_name if op != null else "SOMEONE").to_upper(), step.label.to_upper()]
				else:
					text = "OPERATE: %s. AIM AT THE TABLE AND PRESS E." % step.label.to_upper()
	if text != "":
		_text(Vector2(0, 24), text, 15, Color("ff6a6a"), HORIZONTAL_ALIGNMENT_CENTER, w)
	if game.phase == Game.Phase.LOBBY and host_info != "":
		_text(Vector2(0, 46), host_info, 14, Color("5ce0d0"), HORIZONTAL_ALIGNMENT_CENTER, w)


## Items the remaining steps need that are not on the shelf yet, as "Anesthetic x1" labels.
func _missing_supplies() -> Array:
	var need := Procedures.remaining_requirements(game.case.ailment_id, int(game.case.step_index))
	var out := []
	for kind in Items.SURGICAL:
		if not need.has(kind):
			continue
		var short: int = int(need[kind]) - game.shelf_count(kind)
		if short <= 0:
			continue
		out.append(Items.display_name(kind) + (" x%d" % short if Items.is_consumable(kind) else ""))
	return out


func _draw_case_panel(w: float) -> void:
	if game.phase != Game.Phase.SHIFT or game.case.is_empty():
		return
	var pt := Procedures.patient(game.case.patient_id)
	var ail := Procedures.ailment(game.case.ailment_id)
	var steps := Procedures.steps(game.case.ailment_id)
	var cur := int(game.case.step_index)
	var x := w - 318.0
	var panel_h := 124.0 + steps.size() * 22.0
	draw_rect(Rect2(x - 12, 12, 318, panel_h), Color(0, 0, 0, 0.58))
	_text(Vector2(x, 32), String(pt.full_name).to_upper().substr(0, 30), 15, Color("dddddd"))
	_text(Vector2(x, 50), "%s (%s)" % [ail.name, ail.code], 13, Color("ff8a6a"))
	_text(Vector2(x, 67), Procedures.blurb(game.case.patient_id, game.case.ailment_id).substr(0, 44), 11, Color("8a9aa0"))
	var v: float = maxf(0.0, game.vitals)
	var pulse: float = 1.0 if v > 30.0 else 0.7 + 0.3 * sin(_t * 10.0)
	draw_rect(Rect2(x, 76, 290, 12), Color("2a2f36"))
	var vcol := Color("5cff8a") if v > 50.0 else (Color("ffd35c") if v > 25.0 else Color(1, 0.16, 0.16, pulse))
	draw_rect(Rect2(x, 76, 290 * v / 100.0, 12), vcol)
	_text(Vector2(x, 104), "VITALS %d%%    %d BPM" % [ceili(v), roundi(40 + v * 0.6 + sin(_t * 8.0) * 2.0)], 13, Color("eeeeee"))
	var y := 128.0
	for i in steps.size():
		var s: Dictionary = steps[i]
		var needed: int = maxi(1, int(s.uses))
		var on_shelf := game.shelf_count(s.item)
		var col := Color("5cff8a") if i < cur else (Color("f0e6c8") if i == cur else Color("8a9aa0"))
		var mark := "[x]" if i < cur else ("[>]" if i == cur else "[ ]")
		_text(Vector2(x, y), "%s %s" % [mark, s.label], 13, col)
		if i >= cur:
			var have_col := Color("5cff8a") if on_shelf >= needed else Color("ff6a6a")
			var item_text := "%s %d/%d" % [Items.display_name(s.item), mini(on_shelf, needed), needed]
			_text(Vector2(x + 190, y), item_text, 11, have_col)
		y += 22.0


func _draw_crosshair(w: float, h: float) -> void:
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
	draw_rect(Rect2(w * 0.5 - 230, 60, 460, 50), Color(0, 0, 0, 0.6))
	# net hook: someone who joined mid-shift watches until the next shift starts.
	var waiting: bool = game.waiting_peers.has(Net.my_id())
	_text(Vector2(0, 82), "SHIFT IN PROGRESS" if waiting else "YOU ARE DEAD", 17, Color("ffd35c") if waiting else Color("ff6a6a"), HORIZONTAL_ALIGNMENT_CENTER, w)
	var watching = game.viewed_player()
	var text := "Nobody left to watch."
	if watching != null and watching != game.local_player():
		text = ("Watching %s. You clock in at the next shift." if waiting else "Watching %s. A teammate can revive you at the Re-Gen Pod.") % watching.player_name
	_text(Vector2(0, 102), text, 13, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, w)


## Hold-E progress for the time clock and the Re-Gen Pod.
func _draw_holds(w: float, h: float) -> void:
	var progress := 0.0
	var label := ""
	if game.phase == Game.Phase.LOBBY and game.punch > 0.0:
		progress = game.punch
		label = "CLOCKING IN"
	elif game.phase == Game.Phase.SHIFT and game.pod > 0.0:
		progress = game.pod
		label = "RE-GEN POD"
	if progress <= 0.0:
		return
	var cx := w * 0.5
	var y := h * 0.5 + 78.0
	draw_rect(Rect2(cx - 112, y - 8, 224, 16), Color(0, 0, 0, 0.7))
	draw_rect(Rect2(cx - 110, y - 6, 220 * progress, 12), Color("5ce0d0"))
	_text(Vector2(0, y - 16), "%s..." % label, 14, Color("ffffff"), HORIZONTAL_ALIGNMENT_CENTER, w)


## Only used while the surgery system is still the stub (no surgery_hud.gd of its own).
func _draw_surgery_fallback(w: float, h: float) -> void:
	if game.phase != Game.Phase.SHIFT or game.surgery == null:
		return
	var st: Dictionary = game.surgery.hud_state()
	if st.is_empty():
		return
	var cx := w * 0.5
	var y := h * 0.5 + 130.0
	draw_rect(Rect2(cx - 180, y - 46, 360, 96), Color(0, 0, 0, 0.7))
	_text(Vector2(0, y - 26), String(st.get("title", "")).to_upper(), 15, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)
	_text(Vector2(0, y - 6), String(st.get("hint", "")), 12, Color("c9d1d9"), HORIZONTAL_ALIGNMENT_CENTER, w)
	var bw := 320.0
	var bx := cx - bw * 0.5
	var by := y + 10.0
	for g in st.get("gauges", []):
		draw_rect(Rect2(bx, by, bw, 14), Color("2a2f36"))
		var span: float = maxf(0.001, float(g.max) - float(g.min))
		var gx0: float = bx + (float(g.good_min) - float(g.min)) / span * bw
		var gx1: float = bx + (float(g.good_max) - float(g.min)) / span * bw
		draw_rect(Rect2(gx0, by, gx1 - gx0, 14), Color(0.36, 1.0, 0.54, 0.55))
		var vx: float = bx + (float(g.value) - float(g.min)) / span * bw
		var ok: bool = float(g.value) >= float(g.good_min) and float(g.value) <= float(g.good_max)
		draw_rect(Rect2(vx - 2, by - 3, 4, 20), Color("ffffff") if ok else Color("ff6a6a"))
		by += 20.0
	draw_rect(Rect2(bx, by + 4, bw * float(st.get("progress", 0.0)), 4), Color("c9d1d9"))


func _draw_message(w: float, h: float, in_surgery: bool) -> void:
	if game.message_timer <= 0.0:
		return
	var text := game.message
	var y := h - 150.0 if not in_surgery else 90.0
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_rect(Rect2(w * 0.5 - tw * 0.5 - 14, y - 20, tw + 28, 30), Color(0, 0, 0, 0.65))
	_text(Vector2(0, y), text, 16, Color("f0e6c8"), HORIZONTAL_ALIGNMENT_CENTER, w)


func _draw_hint(w: float, h: float) -> void:
	if _hint_timer <= 0.0:
		return
	_text(Vector2(0, h - 8),
		"WASD move   MOUSE look   SHIFT sprint   F light   E use   G set down   1-4 slots   R read guide   Q shove   ESC pause",
		12, Color(0.67, 0.67, 0.67, minf(1.0, _hint_timer / 2.0)), HORIZONTAL_ALIGNMENT_CENTER, w)


func _overlay(w: float, h: float, title: String, sub: String, prompt: String, col: Color) -> void:
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.72))
	_text(Vector2(0, h * 0.4), title, maxi(18, int(minf(72, w / 12.0))), col, HORIZONTAL_ALIGNMENT_CENTER, w)
	_text(Vector2(0, h * 0.4 + 46), sub, 16, Color("cccccc"), HORIZONTAL_ALIGNMENT_CENTER, w)
	if prompt != "":
		_text(Vector2(0, h * 0.4 + 82), prompt, 16, Color("eeeeee"), HORIZONTAL_ALIGNMENT_CENTER, w)
