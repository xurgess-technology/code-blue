extends Node3D
## Entry point: builds the world, the interface and the visual environment,
## and owns the mouse and pause behaviour.

var game: Game
var hud: Hud
var menu: Menu
var post = null
## The database terminal UI (a CanvasLayer with open/close/is_open).

## 0 low, 1 medium, 2 high. Medium is the default: it keeps the volumetric fog that
## sells the atmosphere, and renders below native resolution so integrated GPUs cope.
var quality: int = 1
## Internal render resolution per preset, upscaled with FSR 1 (spatial). The HUD stays sharp.
## FSR 2 was measured slower on integrated GPUs and caused 140 ms hitches, so it is not used.
const RENDER_SCALE := [0.6, 0.7, 1.0]
const QUALITY_NAMES := ["LOW", "MEDIUM", "HIGH"]

var _fps_label: Label
var _look: GDScript = null
## Settings hook: the settings screen (menu and pause), scripts/settings_screen.gd.
var settings_ui: CanvasLayer = null
## The tip fax (scripts/tips/tip_fax.gd): first-time memos at the bottom of the screen.
var tips: CanvasLayer = null

## The shift assignment fax (scripts/shift_fax.gd): covers a session start from the title menu.
var shift_fax: CanvasLayer = null

## DEV HOOK: the dev room panel (a CanvasLayer, hidden outside the dev room).
var dev_panel: CanvasLayer = null
const DevPanelScript := preload("res://scripts/dev/dev_panel.gd")


func _ready() -> void:
	randomize()

	game = Game.new()
	game.name = "Game"
	game.add_to_group("game")
	add_child(game)

	# Environment and post-processing come from the look pass; the game runs without them.
	var look_path := "res://scripts/look.gd"
	if ResourceLoader.exists(look_path):
		_look = load(look_path)
		if _look.has_method("make_environment"):
			add_child(_look.make_environment())
		if _look.has_method("make_post_layer"):
			post = _look.make_post_layer()
			add_child(post)
	else:
		add_child(_basic_environment())
	quality = _load_quality()
	set_quality(quality, false)
	# Settings hook: brightness now, and quality / brightness whenever they change.
	if _look != null and _look.has_method("apply_brightness"):
		_look.apply_brightness(self, float(Settings.get_value("brightness")))
	Settings.changed.connect(_on_setting_changed)

	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 10
	add_child(fps_layer)
	_fps_label = Label.new()
	_fps_label.position = Vector2(12, 0)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color("9fe8a0"))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_fps_label.visible = false
	fps_layer.add_child(_fps_label)

	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 2
	add_child(hud_layer)
	hud = Hud.new()
	hud.name = "HUD"
	hud.game = game
	hud_layer.add_child(hud)

	var menu_layer := CanvasLayer.new()
	# Above the look pass's grain and vignette (layer 50), like the launch printout it continues:
	# the paper looks the same on both sides of the hand-off. The settings screen sits just above.
	menu_layer.layer = 51
	add_child(menu_layer)
	menu = Menu.new()
	menu.name = "Menu"
	menu_layer.add_child(menu)

	shift_fax = load("res://scripts/shift_fax.gd").new()
	shift_fax.name = "ShiftFax"
	shift_fax.menu = menu
	add_child(shift_fax)

	menu.chose_solo.connect(_start_solo)
	menu.chose_host.connect(_start_host)
	menu.chose_join.connect(_start_join)
	# DEV HOOK (scripts/dev): the secret dev room and its panel.
	dev_panel = DevPanelScript.new()
	dev_panel.name = "DevPanel"
	add_child(dev_panel)
	dev_panel.setup(game, self)
	Net.joined_ok.connect(_on_joined)
	Net.join_failed.connect(_on_join_failed)
	Net.host_left.connect(func(): _back_to_menu("The host left the game."))
	# net hooks: Steam hosting, invites, and the pause-menu invite button.
	menu.chose_host_steam.connect(_start_host_steam)
	Net.host_ready.connect(_on_steam_hosted)
	Net.host_failed.connect(func(reason): _show_menu(reason))
	Net.invite_accepted.connect(_on_steam_invite)
	_build_invite_button()
	game.notice.connect(func(_t, _s): pass)

	# The tip fax: first-time memos (the break room's time clock, the crematorium's furnace).
	tips = load("res://scripts/tips/tip_fax.gd").new()
	tips.name = "TipFax"
	tips.game = game
	add_child(tips)

	# Settings hook: the settings screen, opened from the title menu and the pause overlay.
	settings_ui = load("res://scripts/settings_screen.gd").new()
	settings_ui.name = "SettingsUI"
	settings_ui.menu = menu
	add_child(settings_ui)
	menu.chose_settings.connect(func():
		if not shift_fax.is_active():   # the sign-in sheet may still be ejecting for a session start
			settings_ui.open())
	# Pause-only buttons: tear the session down and return to the menu (same path Q already
	# uses to walk out mid-shift), or quit the app outright.
	settings_ui.exit_to_menu_requested.connect(func(): _back_to_menu(""))
	settings_ui.exit_to_desktop_requested.connect(func(): get_tree().quit())
	# The pause fax was dismissed: back into the shift at once, while its page and printer animate away.
	settings_ui.closed.connect(func():
		if game.paused and game.phase != Game.Phase.MENU:
			game.paused = false
			_set_mouse(true))

	Audio.set_ambience(true)
	_set_mouse(false)
	_launch()


const LaunchScreenScript := preload("res://scripts/launch_screen.gd")
## True until the launch warmup and its printout are done; session starts wait for it.
var launching := true
signal launched


## The one-time launch work: build and draw one of everything (scripts/warmup.gd) behind the
## admission-chart printout (scripts/launch_screen.gd), which then feeds straight into the title
## menu's sign-in sheet (scripts/menu.gd, same printer). The warmup starts inside _ready, so the
## game's very first frame is a lit 3D frame of its first models: the renderer's one-time setup
## (seconds, and it can't be split up) happens while Godot's boot splash is still on screen.
func _launch() -> void:
	var screen := LaunchScreenScript.new()
	screen.name = "LaunchScreen"
	add_child(screen)
	var rig := Node3D.new()
	rig.name = "LaunchRig"
	add_child(rig)
	var cam := Camera3D.new()
	rig.add_child(cam)
	cam.position = Vector3(0.0, 0.3, 2.4)
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	rig.add_child(sun)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(0.6, 1.2, 1.0)
	lamp.shadow_enabled = true
	rig.add_child(lamp)
	var spot := SpotLight3D.new()
	spot.position = Vector3(-0.5, 0.6, 2.0)
	spot.shadow_enabled = true
	rig.add_child(spot)
	await Warmup.run(game, screen.report, screen.can_draw, screen.may_work)
	rig.queue_free()
	if screen.is_processing():
		await screen.done
	# The admission page has fed off the top; the sign-in sheet carries the paper on from there.
	menu.feed_in(screen.paper_scroll_px(), screen.feed_speed(), screen.pages_printed() + 1)
	screen.queue_free()
	launching = false
	launched.emit()


func _after_launch() -> void:
	if launching:
		await launched


## Apply a quality preset: the look pass's environment toggles plus the render scale.
func set_quality(q: int, save: bool = true) -> void:
	quality = clampi(q, 0, 2)
	if _look != null and _look.has_method("apply_quality"):
		_look.apply_quality(self, quality)
	var vp := get_viewport()
	var scale: float = RENDER_SCALE[quality]
	vp.scaling_3d_scale = scale
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR if is_equal_approx(scale, 1.0) \
		else Viewport.SCALING_3D_MODE_FSR
	# Test tools change presets constantly; only a player's own choice is remembered.
	if not save:
		return
	# Settings hook: the preset is saved by the Settings autoload (user://settings.cfg).
	Settings.set_value("quality", quality)


## The player's saved choice, otherwise MEDIUM.
## Measured on a Radeon 890M (integrated) at 1600x900 after the 2026-09-12 tuning pass:
## MEDIUM holds 75+ fps (1% low) in the heaviest rooms, LOW about 80-130, HIGH is for
## dedicated GPUs.
func _load_quality() -> int:
	# Settings hook: Settings migrated the old prefs.cfg video/quality on first run.
	return int(Settings.get_value("quality"))


## Settings hook: apply what main owns when the player changes it (settings screen, F2).
func _on_setting_changed(key: String, value) -> void:
	match key:
		"quality":
			if int(value) != quality:
				set_quality(int(value), false)
		"brightness":
			if _look != null and _look.has_method("apply_brightness"):
				_look.apply_brightness(self, float(value))


## A plain environment so the game is playable before the look pass lands.
func _basic_environment() -> WorldEnvironment:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.42, 0.55)
	env.ambient_light_energy = 0.08
	env.fog_enabled = true
	env.fog_light_color = Color(0.02, 0.03, 0.04)
	env.fog_density = 0.035
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.15
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	we.environment = env
	return we


# =========================================================================
# session start
# =========================================================================

func _start_solo(player_name: String) -> void:
	if not await _loading_screen_up("solo", player_name):
		return
	var run_seed := randi()
	await game.prebuild_level(run_seed, 1)
	Net.start_solo(player_name)
	game.start_session(run_seed)
	hud.host_info = ""
	_enter_game()
	shift_fax.end("session")


## Put the shift assignment fax up (the sign-in sheet ejects, the new page feeds in) and let it
## draw before any loading work starts. It stays until the player is in and frames have settled.
## False if a session start is already underway (a double click).
func _loading_screen_up(mode: String, player_name: String) -> bool:
	await _after_launch()
	if _starting():
		return false
	shift_fax.begin("session", mode, player_name)
	await shift_fax.drawn()
	return true


## A session start (or its fax) is underway.
func _starting() -> bool:
	return shift_fax.is_active() or Loading.is_active()


## Back to the title menu with `reason` on the sign-in sheet. If the shift fax is up (a start that
## failed), its page ejects first and a fresh sign-in sheet feeds into the same printer.
func _show_menu(reason: String) -> void:
	if not shift_fax.is_active():
		menu.show_menu(reason)
		return
	shift_fax.cancel(func():
		menu.show_menu(reason)
		menu.feed_in(0.0, 0.0, int(menu.page_no) + 2))


func _start_host(player_name: String) -> void:
	if not await _loading_screen_up("host", player_name):
		return
	# The hospital first, then open the server: nobody can connect to a session that isn't there yet.
	var run_seed := randi()
	await game.prebuild_level(run_seed, 1)
	var err := Net.host(player_name)
	if not err.is_empty():
		game._discard_prebuilt()
		_show_menu(err)
		return
	game.start_session(run_seed)
	var addresses := Net.local_addresses()
	hud.host_info = "Friends join at: %s" % ", ".join(addresses.map(func(a): return "%s:%d" % [a, C.DEFAULT_PORT])) \
		if not addresses.is_empty() else "Hosting on port %d" % C.DEFAULT_PORT
	_enter_game()
	shift_fax.end("session")


## Joining: the fax stays up from the click until the host's hospital is built here (or the
## join fails / is abandoned).
func _start_join(player_name: String, address: String) -> void:
	await _after_launch()
	if _starting():
		return
	var parsed := Net.parse_address(address)
	menu.set_status("Joining %s:%d..." % [parsed.address, parsed.port])
	shift_fax.begin("join", "join", player_name)
	var err := Net.join(parsed.address, parsed.port, player_name)
	if not err.is_empty():
		_show_menu(err)



## Steam: names come from Steam personas, so the typed name is not used.
func _start_host_steam(_player_name: String) -> void:
	var err := Net.host_steam()
	if not err.is_empty():
		menu.show_menu(err)


func _on_steam_hosted() -> void:
	await _loading_screen_up("steam", menu.player_name())
	var run_seed := randi()
	await game.prebuild_level(run_seed, 1)
	game.start_session(run_seed)
	hud.host_info = "Steam lobby open (friends only). Esc, then Invite friends, or invite from the Steam overlay."
	_enter_game()
	shift_fax.end("session")


## Accepted an invite or clicked "Join game" on a friend: leave whatever we were doing and go.
func _on_steam_invite(lobby: int) -> void:
	await _after_launch()
	if game.phase != Game.Phase.MENU:
		_back_to_menu("")
	menu.set_enabled(false)
	menu.set_status("Joining your friend's Steam lobby...")
	shift_fax.begin("join", "join", menu.player_name())
	var err := Net.join_steam(lobby)
	if not err.is_empty():
		_show_menu(err)


var _invite_button: Button


func _build_invite_button() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	_invite_button = Button.new()
	_invite_button.text = "Invite Steam friends"
	_invite_button.custom_minimum_size = Vector2(240, 44)
	_invite_button.add_theme_font_size_override("font_size", 17)
	_invite_button.anchor_left = 0.5
	_invite_button.anchor_right = 0.5
	_invite_button.anchor_top = 0.4
	_invite_button.anchor_bottom = 0.4
	_invite_button.offset_left = -120
	_invite_button.offset_right = 120
	_invite_button.offset_top = 130
	_invite_button.offset_bottom = 174
	_invite_button.visible = false
	_invite_button.pressed.connect(func(): Net.invite_friends())
	layer.add_child(_invite_button)


func _on_joined() -> void:
	hud.host_info = ""
	_enter_game()


func _on_join_failed(reason: String) -> void:
	_show_menu(reason)


func _enter_game() -> void:
	menu.hide_menu()
	game.paused = false
	# The shift fax keeps the mouse (and so the surgeon) until its page has gone: _update_mouse.
	_set_mouse(not shift_fax.holds_input())


func _back_to_menu(reason: String) -> void:
	Net.leave()
	game.end_session("")
	game.paused = false
	_set_mouse(false)
	# From the pause page (Main menu, or the host leaving while paused): the title's printer takes over
	# in place, the pause page ejects, and then the sign-in sheet feeds in (settings_ui._finish_close).
	if not shift_fax.is_active() and settings_ui.leave_to_menu():
		menu.show_menu(reason)
		menu.hold_in_printer()
	else:
		_show_menu(reason)
	Audio.set_music_intensity(0.0)


# =========================================================================
# mouse and pause
# =========================================================================

func _set_mouse(captured: bool) -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE)


func _unhandled_input(event: InputEvent) -> void:
	# F2 cycles graphics quality, F3 toggles the frame counter. Work anywhere, even on the menu.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F2:
			set_quality((quality + 2) % 3)   # HIGH -> MEDIUM -> LOW -> HIGH
			game.say("Graphics: %s" % QUALITY_NAMES[quality], 2.0)
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_F3:
			_fps_label.visible = not _fps_label.visible
			get_viewport().set_input_as_handled()
			return

	if event.is_action_pressed("fullscreen"):
		# Settings hook: F11 flips the saved window mode (windowed <-> fullscreen).
		var full: bool = Settings.get_value("window_mode") != "windowed"
		Settings.set_value("window_mode", "windowed" if full else "fullscreen")
		get_viewport().set_input_as_handled()
		return

	if game.phase == Game.Phase.MENU:
		return
	# The shift fax is still going: nothing reaches the shift (no pause fax over it) until it has gone.
	if shift_fax.holds_input():
		get_viewport().set_input_as_handled()
		return
	# Its last moments (the page lifting, the printer sinking) are already the shift's, except that the
	# pause fax waits the fraction of a second for that printer to be gone.
	if shift_fax.is_active() and event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		return

	# Hub rebuild, chunk 3: the pharmacy's fax order form owns the keyboard until it closes.
	if game.economy != null and game.economy.fax_ui_open():
		return
	if event.is_action_pressed("interact") and not game.paused:
		var fax_me = game.local_player()
		if fax_me != null and fax_me.alive and not fax_me.downed and fax_me.aim_id == "pharmacy_fax":
			game.economy.open_fax_ui()
			get_viewport().set_input_as_handled()
			return

	# SWEEP 3 HOOK (brains): Esc while looking through a Walk-In's eyes comes back instead of pausing.
	if event.is_action_pressed("pause") and not game.paused and game.brains != null and game.brains.local_hive_active():
		game.brains.local_exit()
		get_viewport().set_input_as_handled()
		return

	# Esc while operating leaves the operation instead of pausing.
	if event.is_action_pressed("pause") and game.surgery_wants_mouse():  # downed hook: either table
		game.surgery_local_exit()
		get_viewport().set_input_as_handled()
		return

	# A memo on the tip fax: Esc tears it off, and the pause menu stays shut until it has gone.
	if event.is_action_pressed("pause") and not game.paused and tips != null and tips.is_showing():
		tips.dismiss()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("pause"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return

	# While paused the settings fax owns input (Resume, Main menu, Quit game on the page).
	if game.paused:
		return

	# Dead players click to change who they are watching.
	var me = game.local_player()
	if me != null and not me.alive and event is InputEventMouseButton and event.pressed:
		_cycle_spectate()


## Esc in a shift: pause and bring up the settings fax; again (or Resume on the page) sends the page
## away, and settings_ui.closed unpauses straight away while it goes.
func _toggle_pause() -> void:
	if game.paused:
		settings_ui.close()
		return
	game.paused = true
	_set_mouse(false)
	settings_ui.open_pause()


## One place decides the mouse: free for menus, pause, the terminal and the surgery view,
## captured for walking around.
func _update_mouse() -> void:
	var free: bool = menu.visible or game.phase == Game.Phase.MENU or game.paused \
		or shift_fax.holds_input() \
\
		or (game.economy != null and game.economy.fax_ui_open()) \
		or game.surgery_wants_mouse() \
		or (dev_panel != null and dev_panel.is_open())  # DEV HOOK
	var want := Input.MOUSE_MODE_VISIBLE if free else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want:
		Input.set_mouse_mode(want)


func _cycle_spectate() -> void:
	var living := game.alive_players()
	if living.is_empty():
		return
	var ids := []
	for p in living:
		ids.append(p.peer_id)
	ids.sort()
	var at := ids.find(game.spectating)
	game.spectating = ids[(at + 1) % ids.size()]
	for p in game.players.values():
		p.camera.current = (p.peer_id == game.spectating)


func _process(_delta: float) -> void:
	if _fps_label.visible:
		_fps_label.text = "%d fps  %s" % [Engine.get_frames_per_second(), QUALITY_NAMES[quality]]
	_update_mouse()
	if game.phase != Game.Phase.MENU and shift_fax.has_reason("join"):
		shift_fax.end("join")   # the host's hospital is built here; the fax goes once frames settle
	_invite_button.visible = game.paused and Net.backend == "steam" and game.phase != Game.Phase.MENU
	# While operating, the surgery view's camera wins; otherwise whoever we are watching.
	var surgery_cam: Camera3D = game.surgery_camera() if game.phase != Game.Phase.MENU else null  # downed hook: either table
	# SWEEP 3 HOOK (brains): Hive Eyes renders through the Walk-In's eyes.
	var brain_cam: Camera3D = game.brains.camera() if game.phase != Game.Phase.MENU and game.brains != null else null
	if brain_cam != null:
		surgery_cam = brain_cam
	if surgery_cam != null:
		if not surgery_cam.current:
			surgery_cam.make_current()
	else:
		var view = game.viewed_player() if game.phase != Game.Phase.MENU else null
		if view != null and not view.camera.current:
			for p in game.players.values():
				p.camera.current = (p == view)
	if post != null and post.has_method("set_state"):
		post.set_state(game.danger, 0.0 if game.local_player() == null else (1.0 - float(game.local_player().hp) / 3.0))
