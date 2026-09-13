extends Node3D
## Entry point: builds the world, the interface and the visual environment,
## and owns the mouse and pause behaviour.

var game: Game
var hud: Hud
var menu: Menu
var post = null
## The medical guide UI (a CanvasLayer with open/close/is_open).
var guide: CanvasLayer = null

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

## DEV HOOK: the dev room panel (a CanvasLayer, hidden outside the dev room).
var dev_panel: CanvasLayer = null
const DevPanelScript := preload("res://scripts/dev/dev_panel.gd")
const DevRoomScript := preload("res://scripts/dev/dev_room.gd")


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
	menu_layer.layer = 5
	add_child(menu_layer)
	menu = Menu.new()
	menu.name = "Menu"
	menu_layer.add_child(menu)

	menu.chose_solo.connect(_start_solo)
	menu.chose_host.connect(_start_host)
	menu.chose_join.connect(_start_join)
	# DEV HOOK (scripts/dev): the secret dev room and its panel.
	menu.chose_dev.connect(start_dev)
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
	Net.host_failed.connect(func(reason): menu.show_menu(reason))
	Net.invite_accepted.connect(_on_steam_invite)
	_build_invite_button()
	game.notice.connect(func(_t, _s): pass)

	# The medical guide binder. The guide worker's UI when present, the stub otherwise.
	var guide_script: GDScript = load("res://scripts/guide/guide_ui.gd")
	guide = guide_script.new()
	guide.name = "Guide"
	add_child(guide)

	# Settings hook: the settings screen, opened from the title menu and the pause overlay.
	settings_ui = load("res://scripts/settings_screen.gd").new()
	settings_ui.name = "SettingsUI"
	settings_ui.menu = menu
	add_child(settings_ui)
	menu.chose_settings.connect(settings_ui.open)

	Audio.set_ambience(true)
	_set_mouse(false)


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
	Net.start_solo(player_name)
	game.start_session(randi())
	hud.host_info = ""
	_enter_game()


func _start_host(player_name: String) -> void:
	var err := Net.host(player_name)
	if not err.is_empty():
		menu.show_menu(err)
		return
	game.start_session(randi())
	var addresses := Net.local_addresses()
	hud.host_info = "Friends join at: %s" % ", ".join(addresses.map(func(a): return "%s:%d" % [a, C.DEFAULT_PORT])) \
		if not addresses.is_empty() else "Hosting on port %d" % C.DEFAULT_PORT
	_enter_game()


func _start_join(player_name: String, address: String) -> void:
	var parsed := Net.parse_address(address)
	menu.set_status("Joining %s:%d..." % [parsed.address, parsed.port])
	var err := Net.join(parsed.address, parsed.port, player_name)
	if not err.is_empty():
		menu.show_menu(err)


## DEV HOOK: into the dev room, alone or hosting (friends then join it like any hosted game).
func start_dev(player_name: String, host: bool) -> void:
	if host:
		var err := Net.host(player_name)
		if not err.is_empty():
			menu.show_menu(err)
			return
		var addresses := Net.local_addresses()
		hud.host_info = "Friends join at: %s" % ", ".join(addresses.map(func(a): return "%s:%d" % [a, C.DEFAULT_PORT])) \
			if not addresses.is_empty() else "Hosting on port %d" % C.DEFAULT_PORT
	else:
		Net.start_solo(player_name)
		hud.host_info = ""
	game.start_session(DevRoomScript.SEED)
	_enter_game()



## Steam: names come from Steam personas, so the typed name is not used.
func _start_host_steam(_player_name: String) -> void:
	var err := Net.host_steam()
	if not err.is_empty():
		menu.show_menu(err)


func _on_steam_hosted() -> void:
	game.start_session(randi())
	hud.host_info = "Steam lobby open (friends only). Esc, then Invite friends, or invite from the Steam overlay."
	_enter_game()


## Accepted an invite or clicked "Join game" on a friend: leave whatever we were doing and go.
func _on_steam_invite(lobby: int) -> void:
	if game.phase != Game.Phase.MENU:
		_back_to_menu("")
	menu.set_enabled(false)
	menu.set_status("Joining your friend's Steam lobby...")
	var err := Net.join_steam(lobby)
	if not err.is_empty():
		menu.show_menu(err)


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
	menu.show_menu(reason)


func _enter_game() -> void:
	menu.hide_menu()
	game.paused = false
	_set_mouse(true)


func _back_to_menu(reason: String) -> void:
	Net.leave()
	game.end_session("")
	game.paused = false
	_set_mouse(false)
	menu.show_menu(reason)
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

	# The open guide owns the keyboard until it closes itself.
	if guide != null and guide.is_open():
		return

	# Esc while operating leaves the operation instead of pausing.
	if event.is_action_pressed("pause") and game.surgery != null and game.surgery.wants_mouse():
		game.surgery.local_operator_exit()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("pause"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("read") and not game.paused:
		var me = game.local_player()
		if me != null and me.alive and _can_read(me):
			guide.open("")
			get_viewport().set_input_as_handled()
			return

	# While paused: click to resume, Q to leave the shift.
	if game.paused:
		if event is InputEventMouseButton and event.pressed:
			_toggle_pause()
		elif event.is_action_pressed("shove"):
			_back_to_menu("You walked out mid-shift.")
		return

	# Dead players click to change who they are watching.
	var me = game.local_player()
	if me != null and not me.alive and event is InputEventMouseButton and event.pressed:
		_cycle_spectate()


func _toggle_pause() -> void:
	game.paused = not game.paused
	_set_mouse(not game.paused)


## You can read the guide while holding it or while looking at it.
func _can_read(me) -> bool:
	if me.holding("guide"):
		return true
	if me.aim_id.begins_with("it_"):
		var node := game.find_interactable(me.aim_id)
		return node != null and node.get("kind") == "guide"
	return false


## One place decides the mouse: free for menus, pause, the guide and the surgery view,
## captured for walking around.
func _update_mouse() -> void:
	var free: bool = menu.visible or game.phase == Game.Phase.MENU or game.paused \
		or (guide != null and guide.is_open()) \
		or (game.surgery != null and game.surgery.wants_mouse()) \
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
	_invite_button.visible = game.paused and Net.backend == "steam" and game.phase != Game.Phase.MENU
	# While operating, the surgery view's camera wins; otherwise whoever we are watching.
	var surgery_cam: Camera3D = game.surgery.camera() if game.surgery != null and game.phase != Game.Phase.MENU else null
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
