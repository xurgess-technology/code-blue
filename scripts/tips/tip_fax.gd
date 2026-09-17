extends CanvasLayer
## The tip fax: a little fax machine that slides up in the bottom left corner of the screen (the
## health hearts moved to the top left for it), and prints a short memo the first time something is worth explaining.
## The same paper, ink and stamp red as the other fax pages (scripts/fax_printer.gd), smaller.
##
## A memo prints line by line, stays until TEAR_AFTER seconds have passed since it started (or Esc,
## main.gd -> dismiss()), then is torn off and flies away; queued memos print one after another, and
## the machine sinks away when there are none left. Each tip is shown once per player, remembered on
## this machine (user://tips.cfg). Purely local: every player's own fax, triggered by where they are.
##
## Tips today (Zach, 2026-09-16): walking into the break room (the time clock) and into the
## crematorium (the furnace) for the first time.
##
##   game                 set by main.gd
##   show_tip(id)         queue a tip now (ignores whether it was seen; tests and the dev panel)
##   dismiss() -> bool    tear off the memo on screen; false when there is none (Esc does nothing)
##   is_showing() -> bool
##   reset_seen()         forget every tip this machine has shown

const Fax := preload("res://scripts/fax_printer.gd")

const LAYER := 5
const SAVE_PATH := "user://tips.cfg"

## First time the local player stands in a room of this kind -> the tip it shows.
const ROOM_TIPS := {
	"break_room": "time_clock",
	"hub_crematorium": "furnace",
}
const TIPS := {
	"time_clock": {
		"title": "THE TIME CLOCK",
		"text": [
			"This is the break room. The time clock is on the wall by the door.",
			"Hold E on it to clock in and start the shift. The phone rings the moment you do.",
			"Once every patient is stable or gone, hold E on it again to clock out and get paid.",
		],
	},
	"bodies": {
		"title": "THE DEAD",
		"text": [
			"Nobody who dies on a table stays there. Hold E on the body to lift it.",
			"Carry it to the crematorium and press E at the furnace window to put it in.",
			"Nobody clocks out while a body is still in the building.",
		],
	},
	"furnace": {
		"title": "THE FURNACE",
		"text": [
			"Anything worth money gets sold here: loot, brains, the lot.",
			"Press E at the window to open the hatch. Hold G to charge a throw, let go to toss what you are holding into the fire.",
			"Surgical tools and supplies bounce back out. Pills burn for nothing.",
		],
	},
}

## Seconds after a memo starts before it is torn off on its own.
const TEAR_AFTER := 20.0
const CPS := 75.0
const LINE_PAUSE := 0.08
const TEAR_SECONDS := 0.45
const MACHINE_SECONDS := 0.3
const CHECK_EVERY := 0.25

const FONT := 18
const TITLE_FONT := 22
const LINE_H := 25.0
const WRAP_CHARS := 34
const MACHINE := Vector2(450, 52)
const PAPER_W := 414.0
const PAPER_PAD := 18.0
## Tucked into the bottom left corner: the machine's left and bottom edges are the screen's.
const LEFT := 0.0
const BOTTOM_GAP := 0.0

var game: Node = null
var _canvas: Control
var _font: Font
var _seen := {}
var _queue: Array = []
var _cur := {}            # {id, lines: [{text, kind}], total_chars, chars, pause, t, tear_t}
var _machine_k := 0.0
var _check_t := 0.0
var _last_line := -1


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("tip_fax")   # the settings page's RESET TIPS finds it here
	_font = Fax.make_font()
	_canvas = Control.new()
	_canvas.name = "TipFax"
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_fax)
	add_child(_canvas)
	_load()


# ---------------------------------------------------------------------------
# public

func show_tip(id: String) -> void:
	if not TIPS.has(id):
		return
	if String(_cur.get("id", "")) == id or _queue.has(id):
		return
	_queue.append(id)


func is_showing() -> bool:
	return not _cur.is_empty() and float(_cur.get("tear_t", -1.0)) < 0.0


func dismiss() -> bool:
	if not is_showing():
		return false
	_tear()
	return true


func reset_seen() -> void:
	_seen.clear()
	_save()


# ---------------------------------------------------------------------------
# triggers

func _process(delta: float) -> void:
	var active: bool = game != null and game.phase != Game.Phase.MENU
	if not active:
		_queue.clear()
		_cur = {}
		_machine_k = 0.0
		_canvas.queue_redraw()
		return
	if not game.paused:
		_check_t -= delta
		if _check_t <= 0.0:
			_check_t = CHECK_EVERY
			_check_rooms()
			_check_events()
		_tick(delta)
	_canvas.queue_redraw()


func _check_rooms() -> void:
	var me = game.local_player()
	if me == null or not me.alive or game.level_info.is_empty():
		return
	var at: Vector3 = me.global_position
	for r in game.level_info.get("rooms", []):
		var kind := String(r.get("kind", ""))
		if not ROOM_TIPS.has(kind):
			continue
		var rect: Rect2 = r.get("rect", Rect2())
		if not rect.has_point(Vector2(at.x, at.z)):
			continue
		var id: String = ROOM_TIPS[kind]
		if not _seen.has(id):
			_seen[id] = true
			_save()
			show_tip(id)


## Things that happen rather than places: the first body waiting for the furnace.
func _check_events() -> void:
	if _seen.has("bodies") or game.corpses == null or game.dev_mode:
		return
	if not game.corpses.any_left().is_empty():
		_seen["bodies"] = true
		_save()
		show_tip("bodies")


# ---------------------------------------------------------------------------
# printing and tearing

func _tick(delta: float) -> void:
	if _cur.is_empty() and not _queue.is_empty():
		_start(String(_queue.pop_front()))
	var want_machine := not _cur.is_empty() or not _queue.is_empty()
	_machine_k = move_toward(_machine_k, 1.0 if want_machine else 0.0, delta / MACHINE_SECONDS)
	if _cur.is_empty():
		return
	# The machine slides up before anything prints.
	if _machine_k < 1.0 and float(_cur.tear_t) < 0.0:
		return
	_cur.t = float(_cur.t) + delta
	if float(_cur.tear_t) >= 0.0:
		_cur.tear_t = float(_cur.tear_t) + delta
		if float(_cur.tear_t) >= TEAR_SECONDS:
			_cur = {}
		return
	if float(_cur.t) >= TEAR_AFTER:
		_tear()
		return
	if float(_cur.chars) < float(_cur.total_chars):
		if float(_cur.pause) > 0.0:
			_cur.pause = float(_cur.pause) - delta
			return
		var before := _line_at(float(_cur.chars))
		_cur.chars = minf(float(_cur.total_chars), float(_cur.chars) + CPS * delta)
		var after := _line_at(float(_cur.chars))
		if after != before:
			_cur.pause = LINE_PAUSE
		if after != _last_line:
			_last_line = after
			_sfx("print_line", -16.0)


func _start(id: String) -> void:
	var tip: Dictionary = TIPS[id]
	var lines: Array = [{"text": ">> MEMO  COUNTY GENERAL", "kind": "head"},
		{"text": String(tip.title), "kind": "title"}]
	for para in tip.text:
		for l in _wrap(String(para), WRAP_CHARS):
			lines.append({"text": l, "kind": "text"})
		lines.append({"text": "", "kind": "gap"})
	lines.append({"text": "ESC  TEAR OFF", "kind": "foot"})
	var total := 0
	for l in lines:
		total += maxi(1, String(l.text).length())
	_cur = {"id": id, "lines": lines, "total_chars": total, "chars": 0.0, "pause": 0.0, "t": 0.0, "tear_t": -1.0}
	_last_line = -1
	_sfx("beep", -10.0)


func _tear() -> void:
	if _cur.is_empty():
		return
	_cur.tear_t = 0.0
	_sfx("print_feed", -8.0)


## Which line the print head is on after `chars` characters.
func _line_at(chars: float) -> int:
	var n := 0
	var i := 0
	for l in _cur.lines:
		n += maxi(1, String(l.text).length())
		if chars < float(n):
			return i
		i += 1
	return i


static func _wrap(text: String, width: int) -> Array:
	var lines := []
	var cur := ""
	for word in text.split(" ", false):
		if cur == "":
			cur = word
		elif cur.length() + 1 + word.length() <= width:
			cur += " " + word
		else:
			lines.append(cur)
			cur = word
	if cur != "":
		lines.append(cur)
	return lines


func _sfx(cue: String, db: float) -> void:
	if DisplayServer.get_name() != "headless":
		Audio.play(cue, null, db, 0.05, Audio.BUS_UI)


# ---------------------------------------------------------------------------
# drawing

func _draw_fax() -> void:
	if _machine_k <= 0.0:
		return
	var sz := _canvas.size
	var drop := (1.0 - ease(_machine_k, 0.4)) * (MACHINE.y + BOTTOM_GAP + 8.0)
	var body := Rect2(LEFT, sz.y - BOTTOM_GAP - MACHINE.y + drop, MACHINE.x, MACHINE.y)
	var slot_y := body.position.y
	var paper_x := body.position.x + (MACHINE.x - PAPER_W) * 0.5

	if not _cur.is_empty():
		_draw_memo(paper_x, slot_y)

	# The machine: a dark body with a lighter lid edge, the paper slot along the top, a green light.
	_canvas.draw_rect(body, Fax.PRINTER)
	_canvas.draw_line(body.position, Vector2(body.end.x, body.position.y), Fax.PRINTER_EDGE, 3.0)
	_canvas.draw_rect(Rect2(paper_x - 4.0, slot_y - 2.0, PAPER_W + 8.0, 5.0), Color(0, 0, 0, 0.65))
	var busy := not _cur.is_empty() and float(_cur.chars) < float(_cur.total_chars) and float(_cur.tear_t) < 0.0
	var light := Fax.LCD_WAIT if busy else Fax.LCD_TEXT
	_canvas.draw_circle(Vector2(body.end.x - 24.0, body.position.y + 26.0), 4.5, Color(light, 0.9 if busy and int(_cur.t * 8.0) % 2 == 0 else 0.6))
	_canvas.draw_string(_font, Vector2(body.position.x + 18.0, body.position.y + 32.0), "TIPS", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("7d8a93"))


func _draw_memo(x: float, slot_y: float) -> void:
	var lines: Array = _cur.lines
	var chars := float(_cur.chars)
	var text_h := 0.0
	var n := 0
	for l in lines:
		if chars <= float(n):
			break
		text_h += LINE_H * (0.55 if String(l.kind) == "gap" else 1.0)
		n += maxi(1, String(l.text).length())
	var height := PAPER_PAD * 2.0 + text_h + 6.0
	var lift := 0.0
	var alpha := 1.0
	if float(_cur.tear_t) >= 0.0:
		var k := clampf(float(_cur.tear_t) / TEAR_SECONDS, 0.0, 1.0)
		lift = k * k * 340.0
		alpha = 1.0 - k
	var bottom := slot_y + 4.0 - lift
	var top := bottom - height
	var paper := Rect2(x, top, PAPER_W, height)
	_canvas.draw_rect(paper, Color(Fax.PAPER, alpha))
	# A torn edge along the top once it has been torn off, a faint tractor line down each side.
	for side in [x + 9.0, x + PAPER_W - 9.0]:
		var hy := top + 8.0
		while hy < bottom - 4.0:
			_canvas.draw_circle(Vector2(side, hy), 2.8, Color(0, 0, 0, 0.35 * alpha))
			hy += 18.0
	var y := top + PAPER_PAD + LINE_H * 0.75
	n = 0
	for l in lines:
		var len := maxi(1, String(l.text).length())
		if chars <= float(n):
			break
		var shown := int(clampf(chars - float(n), 0.0, float(len)))
		var text := String(l.text).substr(0, shown)
		match String(l.kind):
			"head":
				_canvas.draw_string(_font, Vector2(x + 24.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT - 2, Color(Fax.INK_FAINT, alpha))
			"title":
				_canvas.draw_string(_font, Vector2(x + 24.0, y + 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FONT, Color(Fax.STAMP_INK, alpha))
			"foot":
				_canvas.draw_string(_font, Vector2(x + 24.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT - 3, Color(Fax.INK_FAINT, 0.8 * alpha))
			"gap":
				pass
			_:
				_canvas.draw_string(_font, Vector2(x + 24.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT, Color(Fax.INK, 0.92 * alpha))
		y += LINE_H * (0.55 if String(l.kind) == "gap" else 1.0)
		n += len


# ---------------------------------------------------------------------------
# saving

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	for k in cf.get_section_keys("seen") if cf.has_section("seen") else []:
		if bool(cf.get_value("seen", k, false)):
			_seen[k] = true


func _save() -> void:
	var cf := ConfigFile.new()
	for k in _seen.keys():
		cf.set_value("seen", String(k), true)
	cf.save(SAVE_PATH)
