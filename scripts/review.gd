extends CanvasLayer
## Review windows (tools/review.ps1): `--review="HIVE: does the lunge read?"` after `--` puts that
## line in the window title and pinned to the top of the screen, so a window opened from a work
## slot says what it's for. Without the flag this does nothing and frees itself.

var text := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--review="):
			text = a.trim_prefix("--review=").strip_edges().trim_prefix("\"").trim_suffix("\"")
	if text == "" or DisplayServer.get_name() == "headless":
		queue_free()
		return
	layer = 128
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
	label.text = text
	label.add_theme_color_override("font_color", Color(0.08, 0.06, 0.02))
	label.add_theme_font_size_override("font_size", 18)
	panel.add_child(label)
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 8)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# The engine names the window after autoloads are ready, so ours goes on a frame later.
	await get_tree().process_frame
	DisplayServer.window_set_title(text)
	# tools/review.ps1 opens it minimized so it never grabs focus; flash the taskbar instead.
	DisplayServer.window_request_attention()
	# Diagnostics: what the window really does (frames drawn, camera, window state), every 3 s.
	var last_frames := 0
	var shown := false
	while true:
		await get_tree().create_timer(3.0, true, false, true).timeout
		var fd := Engine.get_frames_drawn()
		var cam := get_viewport().get_camera_3d()
		var fax = null
		for m in get_tree().root.get_children():
			for c in m.get_children():
				if c.get_script() != null and String(c.get_script().resource_path).ends_with("shift_fax.gd"):
					fax = c
		print("[review] frames_drawn=%d (+%d) mode=%d visible_cam=%s paused=%s fax=%s" % [fd, fd - last_frames, DisplayServer.window_get_mode(),
			str(cam.get_path()) if cam != null else "NONE", str(get_tree().paused), str(fax._state) if fax != null else "-"])
		if fd - last_frames > 5 and not shown:
			shown = true
			print("[review] first frame shown")
		last_frames = fd
