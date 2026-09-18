extends CanvasLayer
## Review windows (tools/review.ps1): `--review="HIVE: does the lunge read?"` after `--` puts that
## line in the window title and pinned to the top of the screen, so a window opened from a work
## slot says what it's for. Without the flag this does nothing and frees itself.

var text := ""
var _label: Label = null
var _loading := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--review="):
			text = a.trim_prefix("--review=").strip_edges().trim_prefix("\"").trim_suffix("\"")
	if text == "" or DisplayServer.get_name() == "headless":
		queue_free()
		return
	layer = 128
	add_to_group("review_bar")
	# A --setup window boots a whole shift (warmup, then the world): say so until it is staged, so a
	# black or splash-screen window is not mistaken for a broken one. ReviewSetups.stage calls staged().
	_loading = ReviewSetups.requested() != "" and ReviewSetups.exists(ReviewSetups.requested())
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[review] %s (saves in %s)" % [text, OS.get_user_data_dir()])
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.9, 0.75, 0.1, 0.92)
	box.set_content_margin_all(6)
	box.content_margin_left = 12
	box.content_margin_right = 12
	panel.add_theme_stylebox_override("panel", box)
	var label := Label.new()
	label.text = text + "   (loading, about 30 s...)" if _loading else text
	_label = label
	label.add_theme_color_override("font_color", Color(0.08, 0.06, 0.02))
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 8)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# The engine names the window after autoloads are ready, so ours goes on a frame later.
	await get_tree().process_frame
	DisplayServer.window_set_title(label.text)
	# tools/review.ps1 opens it minimized so it never grabs focus; flash the taskbar instead.
	if not _loading:
		DisplayServer.window_request_attention()


## The setup is staged: the window is ready to look at.
func staged() -> void:
	_loading = false
	_label.text = text
	DisplayServer.window_set_title(text)
	DisplayServer.window_request_attention()
