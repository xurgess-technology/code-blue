extends Node
## Windowed check of every fax transition (docs/FAX.md): the launch hand-off, title <-> settings, a
## solo start (the shift assignment), pause open / close / Esc mashing, pause -> Main menu, the tip fax
## memo and tear-off, and the pharmacy form (open, cancel, send, reopen while leaving), plus a window
## resize mid-feed. Logs how long each one takes by the wall clock.
##
##   godot --path . --resolution 1280x720 tools/faxshot.tscn               frames + timings
##   godot --path . --resolution 1280x720 tools/faxshot.tscn -- --timing   timings only (no captures)
##
## Frames: while a transition runs, every frame is read back and kept (a readback is a slow frame, but
## the fax screens step at most Fax.MAX_STEP of animation per frame, so the captures still walk through
## the motion in even steps). Each transition is saved as one contact sheet,
## tools/fax_shots/<n>_<name>.png, frames left to right, top to bottom. Timings are only honest with
## --timing. The player's tips.cfg and prefs are put back afterwards.

const Fax := preload("res://scripts/fax_printer.gd")
const OUT_DIR := "res://tools/fax_shots"
const THUMB := Vector2i(320, 180)
const COLS := 5
const MAX_FRAMES := 40
## The tip fax's corner of a 1280x720 window.
const TIP_CORNER := Rect2(0, 400, 569, 320)

var main: Node3D
var game: Game
var _capture := true
var _frames: Array[Image] = []
var _recording := false
var _every_ms := 30
var _last_shot := 0
var _crop := Rect2()
var _sheet_no := 0
var _tips_backup := ""


func _ready() -> void:
	_capture = not OS.get_cmdline_user_args().has("--timing") and not Fax.headless()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# Real seconds: headless frames run unthrottled, so a game-time timer would fire far too early.
	get_tree().create_timer(400.0 if not Fax.headless() else 4000.0).timeout.connect(func():
		print("[faxshot] TIMEOUT")
		_restore()
		get_tree().quit(2))
	if FileAccess.file_exists("user://tips.cfg"):
		_tips_backup = FileAccess.get_file_as_string("user://tips.cfg")
	_run.call_deferred()


func _process(_d: float) -> void:
	if not _recording or not _capture or _frames.size() >= MAX_FRAMES:
		return
	# One frame per `_every_ms` of wall clock at most: fast menu frames would otherwise fill the sheet
	# before the motion is half done.
	var now := Time.get_ticks_msec()
	if now - _last_shot < _every_ms:
		return
	_last_shot = now
	var img := get_viewport().get_texture().get_image()
	if _crop.has_area():
		var s := Vector2(img.get_size()) / Vector2(DisplayServer.window_get_size())
		img = img.get_region(Rect2i(Vector2i(_crop.position * s), Vector2i(_crop.size * s)))
	img.resize(THUMB.x, THUMB.y, Image.INTERPOLATE_BILINEAR)
	_frames.append(img)


## Start keeping frames, one per `every_ms` at most; `crop` (window pixels) zooms in on part of it.
func _rec(every_ms := 30, crop := Rect2()) -> void:
	_frames.clear()
	_recording = true
	_every_ms = every_ms
	_crop = crop
	_last_shot = 0


func _save(name: String) -> void:
	_recording = false
	if not _capture or _frames.is_empty():
		return
	var rows := int(ceil(float(_frames.size()) / COLS))
	var sheet := Image.create(THUMB.x * COLS + (COLS - 1) * 4, THUMB.y * rows + (rows - 1) * 4, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(1, 0, 1))
	for i in _frames.size():
		var img := _frames[i]
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, THUMB), Vector2i((i % COLS) * (THUMB.x + 4), (i / COLS) * (THUMB.y + 4)))
	_sheet_no += 1
	var path := "%s/%02d_%s.png" % [OUT_DIR, _sheet_no, name]
	sheet.save_png(ProjectSettings.globalize_path(path))
	print("[faxshot] %s: %d frames -> %s" % [name, _frames.size(), path])
	_frames.clear()


## Headless (every fax motion is instant there) a condition that needs a motion in progress never
## comes true; frames run unthrottled, so give up after a number of frames rather than seconds.
func _until(cond: Callable, seconds := 10.0) -> int:
	var t0 := Time.get_ticks_msec()
	var frames := 0
	while not cond.call():
		frames += 1
		if Time.get_ticks_msec() - t0 > int(seconds * 1000.0) or (Fax.headless() and frames > 30 and seconds < 30.0):
			print("[faxshot]   (timed out)")
			break
		await get_tree().process_frame
	return Time.get_ticks_msec() - t0


func _wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _log(what: String, ms: int) -> void:
	print("[faxshot] %-44s %5d ms" % [what, ms])


func _esc() -> void:
	var e := InputEventAction.new()
	e.action = "pause"
	e.pressed = true
	get_viewport().push_input(e)
	var up := InputEventAction.new()
	up.action = "pause"
	up.pressed = false
	get_viewport().push_input(up)


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	var menu: Menu = main.menu
	var ui = main.settings_ui
	var sf = main.shift_fax

	# 1. Launch: the stamped page ejects and the sign-in sheet feeds in.
	var ls: WeakRef = weakref(main.get_node_or_null("LaunchScreen"))
	if ls.get_ref() != null:
		await _until(func(): return ls.get_ref() == null or float(ls.get_ref()._feed_t) >= 0.0, 60.0)
		_log("launch: boot to page feeding out", Time.get_ticks_msec() - t0)
		_rec()
	var tf := Time.get_ticks_msec()
	if main.launching:
		await main.launched
	_log("launch: page ejecting off the top", Time.get_ticks_msec() - tf)
	var ms := await _until(func(): return not menu.is_feeding())
	_log("launch: sign-in sheet feeding in", ms)
	_save("launch_handoff")

	# 2. Title -> settings -> back.
	await _wait(0.3)
	_rec()
	ms = Time.get_ticks_msec()
	ui.open()
	await _until(func(): return ui._root.visible and ui._feed.at(1.0))
	_log("title -> settings (eject + feed)", Time.get_ticks_msec() - ms)
	_save("title_to_settings")
	_rec()
	ms = Time.get_ticks_msec()
	_esc()
	await _until(func(): return not ui._root.visible and menu.visible and not menu.is_feeding())
	_log("settings -> title (Esc: eject + feed)", Time.get_ticks_msec() - ms)
	_save("settings_to_title")

	# 3. Mashing: Settings while the sign-in sheet is still feeding in, then Esc twice mid-feed, and a
	# window resize while the settings page feeds.
	ui.open()
	await _until(func(): return ui._root.visible and ui._feed.at(1.0))
	_esc()
	await _until(func(): return menu.visible and menu.is_feeding())
	await _wait(0.2)
	_rec()
	ui.open()   # the sheet is half way out of the slot: it ejects from there
	await _wait(0.1)
	ui.open()   # ignored
	await _until(func(): return ui._root.visible)
	await _wait(0.15)
	DisplayServer.window_set_size(Vector2i(1024, 700))
	_esc()
	_esc()
	await _until(func(): return not ui._root.visible and not menu.is_feeding())
	_save("mash_settings_and_resize")
	DisplayServer.window_set_size(Vector2i(1280, 720))
	await _wait(0.3)
	print("[faxshot] after mashing: settings open=%s visible=%s opening=%s menu visible=%s ejecting=%s" % [
		ui.is_open(), ui._root.visible, ui._opening, menu.visible, menu.is_ejecting()])
	if OS.get_cmdline_user_args().has("--menu-only"):
		_restore()
		get_tree().quit(0)
		return

	# 4. Solo: the shift assignment. Timed state by state; frames only for the eject + feed (capturing
	# during the load would keep the frames from ever settling).
	_rec()
	var start := Time.get_ticks_msec()
	main._start_solo("Fax")
	main._start_solo("Fax")   # a double click
	var last_state := -1
	var marks := {}
	while Time.get_ticks_msec() - start < 90000:
		var s: int = sf._state
		if s != last_state:
			var nm: String = sf.State.keys()[s]
			marks[nm] = Time.get_ticks_msec() - start
			print("[faxshot]   shift fax %-10s at %5d ms" % [nm, marks[nm]])
			last_state = s
			if nm == "LOADING":
				_save("solo_eject_and_feed")
			if nm == "FADE":
				_rec(45)   # the frames have settled by now, so reading them back can't hold the fade up
			if nm == "OUT":
				print("[faxshot]   holds input at OUT: %s, mouse %d" % [sf.holds_input(), Input.mouse_mode])
			if nm == "IDLE" and marks.size() > 1:
				_save("solo_tail")
				break
		await get_tree().process_frame
	if marks.has("SETTLE"):
		_log("shift fax tail after the world is ready", int(marks["IDLE"]) - int(marks["SETTLE"]))
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	await _wait(0.5)

	# 5. Pause: open, close (control back at once), Esc mashing.
	_rec()
	ms = Time.get_ticks_msec()
	_esc()
	await _until(func(): return ui._feed.at(1.0) and ui._printer.at(1.0))
	_log("pause open (printer rises, page feeds)", Time.get_ticks_msec() - ms)
	_save("pause_open")
	_rec()
	ms = Time.get_ticks_msec()
	_esc()
	await get_tree().process_frame
	await get_tree().process_frame
	print("[faxshot] two frames after Esc: paused=%s mouse=%d" % [game.paused, Input.mouse_mode])
	await _until(func(): return not ui._root.visible)
	_log("pause close (page ejects, printer sinks)", Time.get_ticks_msec() - ms)
	_save("pause_close")
	_rec()
	_esc()
	await _wait(0.15)
	_esc()
	await _wait(0.12)
	_esc()
	await _wait(0.1)
	_esc()
	await _until(func(): return not ui._root.visible)
	_save("pause_mash")
	print("[faxshot] after pause mashing: paused=%s open=%s" % [game.paused, ui.is_open()])

	# 6. The tip fax: a memo prints, Esc tears it off, the machine sinks.
	_rec(90, TIP_CORNER)
	ms = Time.get_ticks_msec()
	main.tips.show_tip("furnace")
	await _until(func(): return main.tips.is_showing() and main.tips._machine.at(1.0))
	_log("tip: machine up", Time.get_ticks_msec() - ms)
	await _wait(2.2)
	_save("tip_print")
	_rec(30, TIP_CORNER)
	ms = Time.get_ticks_msec()
	_esc()
	await _until(func(): return main.tips._machine.at(0.0) and main.tips._cur.is_empty())
	_log("tip: tear off + machine sinks", Time.get_ticks_msec() - ms)
	_save("tip_tear")
	print("[faxshot] Esc on the memo left paused=%s" % game.paused)

	# 7. The pharmacy form: open, cancel, reopen while it leaves, send.
	var fx = game.economy.fax_ui if game.economy != null else null
	if fx != null:
		game.add_money(500, "faxshot")
		_rec()
		ms = Time.get_ticks_msec()
		game.economy.open_fax_ui()
		await _until(func(): return fx._feed.at(1.0) and fx._printer.at(1.0))
		_log("pharmacy open (rises, form feeds)", Time.get_ticks_msec() - ms)
		_save("pharmacy_open")
		_rec()
		ms = Time.get_ticks_msec()
		_esc()
		await _wait(0.12)
		print("[faxshot] pharmacy after Esc: open=%s visible=%s" % [fx.is_open(), fx.visible])
		game.economy.open_fax_ui()   # E again while it was leaving
		await _until(func(): return fx._feed.at(1.0) and fx._lift.at(0.0) and fx._printer.at(1.0))
		_save("pharmacy_cancel_and_reopen")
		_log("pharmacy Esc then reopen", Time.get_ticks_msec() - ms)
		_rec()
		ms = Time.get_ticks_msec()
		fx.close()
		await _until(func(): return not fx.visible)
		_log("pharmacy cancel (form ejects, machine sinks)", Time.get_ticks_msec() - ms)
		_save("pharmacy_cancel")
		game.economy.open_fax_ui()
		await _until(func(): return fx._feed.at(1.0))
		print("[faxshot] pharmacy reopened: open=%s visible=%s feed=%.2f wait=%.2f" % [fx.is_open(), fx.visible, fx._feed.value, fx._feed_wait])
		var row: Dictionary = fx._rows[0]
		row.box.pressed.emit()
		fx._refresh()
		await _wait(0.2)
		_rec()
		ms = Time.get_ticks_msec()
		fx._send_order()
		await _until(func(): return not fx.visible)
		_log("pharmacy send (into the machine, sinks)", Time.get_ticks_msec() - ms)
		_save("pharmacy_send")

	# 8. Pause -> Main menu: the pause page ejects over the title printer, the sign-in sheet feeds in.
	_esc()
	await _until(func(): return ui._feed.at(1.0) and ui._printer.at(1.0))
	_rec()
	ms = Time.get_ticks_msec()
	ui._exit_menu_button.pressed.emit()
	await _until(func(): return not ui._root.visible and menu.visible and not menu.is_feeding())
	_log("pause -> Main menu (eject + sign-in feeds)", Time.get_ticks_msec() - ms)
	_save("pause_to_main_menu")

	_restore()
	print("[faxshot] done")
	get_tree().quit(0)


func _restore() -> void:
	if _tips_backup != "":
		var f := FileAccess.open("user://tips.cfg", FileAccess.WRITE)
		if f != null:
			f.store_string(_tips_backup)
	elif FileAccess.file_exists("user://tips.cfg"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://tips.cfg"))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
