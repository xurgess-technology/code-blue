extends Node
## Windowed check of the title menu's sign-in sheet (scripts/menu.gd) at rest: a tick box with focus
## (the pencilled tick), Join with no address (the NOTE line), the dev code armed (blue stamp), a
## pending join (X'd and greyed), and Settings opened over it.
##
##   godot --path . tools/menushot.tscn
##
## Writes tools/game_shots/menu_state_<name>.png, then quits.

const OUT_DIR := "res://tools/game_shots"

var _main: Node3D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	if _main.launching:
		await _main.launched
	var menu: Menu = _main.menu
	while menu.is_feeding():
		await get_tree().process_frame
	await _shot("rest")

	var solo: Button = menu._buttons[0]
	solo.grab_focus()
	await _shot("focus_tick")

	menu._addr_edit.text = ""
	var join: Button = menu._buttons[2]
	join.pressed.emit()
	await _shot("join_no_address")

	# What a pending join looks like (without starting one): the choice X'd, the rest greyed.
	menu.set_enabled(false)
	menu._buttons[2].set_marked(true)
	menu.set_status("Joining 192.168.1.20:7777...")
	await _shot("busy")
	menu.show_menu("")

	_main.settings_ui.open()
	await _shot("settings_over")
	_main.settings_ui.close()
	get_tree().quit(0)


func _shot(tag: String) -> void:
	for i in 3:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/menu_state_%s.png" % [OUT_DIR, tag]))
	print("[menushot] %s" % tag)
