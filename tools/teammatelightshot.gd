extends Node
## The teammate's flashlight on the forceps step, in the real game: boots a solo shift, puts Bob with
## a gunshot on the first table at the bullet step, has the local bot operate, stands a teammate bot
## across the table with its flashlight aimed at the wound, and saves the operator's view with that
## flashlight off and on (tools/game_shots/teammate_light_{off,on}.png). Prints the step's helper light.
##
##   godot --path . tools/teammatelightshot.tscn

const OUT_DIR := "res://tools/game_shots"

var main: Node3D
var game: Game
var bot: Player
var mate: Player


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(240.0).timeout.connect(func(): get_tree().quit(2))
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	game = main.game
	# The launch printout covers the screen until the one-time warmup is done.
	while bool(main.get("launching")):
		await get_tree().process_frame
	main.menu.hide_menu()
	Net.start_solo("Surgeon")
	game.start_session(4242)
	await get_tree().process_frame
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	bot.set_flashlight(false)
	if game.phase == Game.Phase.LOBBY:
		game.begin_shift()
	await _frames(10)

	var ti := int(game.patient_tables[0].index) if not game.patient_tables.is_empty() else 0
	var old: Dictionary = game.case_on_table(ti)
	if not old.is_empty():
		game.remove_case(int(old.id))
	game.add_case({"patient_id": "bob", "ailment_id": "gunshot", "table": ti, "step_index": 1, "flags": {"sedation": 1.0}})
	for kind in Items.SURGICAL:
		game.shelf[kind] = 3 if Items.is_consumable(kind) else 1
	await _frames(20)
	var body = game.body_for_table(ti)
	if body == null:
		print("[teammatelight] no body on table %d" % ti)
		get_tree().quit(1)
		return
	var site: Transform3D = body.site_transform("gunshot")

	# The surgeon walks up and operates (the minigame's own bot plays it).
	var tb: Vector3 = game.table_position(ti)
	var to_site := site.origin - tb
	var bbasis: Basis = body.global_transform.basis
	var stand: Vector3 = tb + Vector3(to_site.x, 0.0, 0.0) + bbasis.z * 1.0
	bot.teleport(game._floor_at(stand))
	_face(bot, site.origin)
	game.surgery_bot_skill = 0.9
	bot.bot_aim_id = "table"
	bot.bot_press += 1
	await _frames(20)
	bot.bot_press += 1

	# The teammate across the table, flashlight on the wound.
	mate = game.dev._make_bot_node(-50, "Teammate", "bot")
	var mstand: Vector3 = site.origin - bbasis.z * 1.0 + bbasis.x * 0.3
	mate.teleport(game._floor_at(mstand))
	await _frames(5)
	mate.set_flashlight(false)
	await _frames(200)
	# The shift fax (the loading page) can still be up over the view: let it go.
	var fax = main.get("shift_fax")
	if fax != null and fax.is_active():
		fax.end("session")
		await _frames(90)
	if fax is CanvasLayer:
		(fax as CanvasLayer).visible = false
	var sys = game.surgery
	print("[teammatelight] operating=%s mg=%s" % [str(bot.operating), str(sys.mg.name if sys.mg != null else "none")])
	_aim(mate, site.origin)
	await _frames(10)
	_shot("teammate_light_off", sys)
	mate.set_flashlight(true)
	_aim(mate, site.origin)
	await _frames(60)
	_shot("teammate_light_on", sys)
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _face(p: Player, at: Vector3) -> void:
	var d := at - p.global_position
	p.bot_yaw = atan2(-d.x, -d.z)
	p._yaw = p.bot_yaw
	p.rotation.y = p.bot_yaw


## Yaw and pitch so the flashlight (on the camera) points at `at`.
func _aim(p: Player, at: Vector3) -> void:
	_face(p, at)
	var from: Vector3 = p.flashlight.global_position
	var d := at - from
	p.bot_pitch = atan2(d.y, Vector2(d.x, d.z).length())


func _shot(name: String, sys) -> void:
	var help := -1.0
	if sys != null and sys.mg != null and "_help" in sys.mg:
		help = float(sys.mg._help)
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("[teammatelight] wrote %s  helper=%.2f  mate light=%s" % [path, help, str(mate.flashlight_on)])
