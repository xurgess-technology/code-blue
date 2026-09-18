extends Node3D
## The Sonographer's review stage (chunk A of docs/SONOGRAPHER.md).
##
##   godot --path . tools/sono_lab.tscn                      # watch it
##   godot --path . tools/sono_lab.tscn -- --capture         # and write what the window shows
##
## A plain lit box with the Sonographer standing in front of a fixed camera, head to toe, with
## headroom for the craned neck. It cycles its clips in place with a caption naming each, then walks
## a little to its left, cycles again, walks back to its right, and keeps going. Nothing here waits
## on the hospital, a player, a navmesh or a warmup: the model is in frame from the first frame, so
## the window can never open on an empty room. If the model fails to build, the room says so.

const MonsterModelScript := preload("res://scripts/monsters/monster_model.gd")
const Shapes := preload("res://scripts/monsters/shapes.gd")
const SHOT_DIR := "res://tools/monster_shots"

## The room, and where the camera stands. The box is tall enough that a fully craned neck (about
## 2.7 m) has air above it.
## Big enough that the camera stands well inside it: a camera outside the box sees the back of a
## wall, which is a flat screen of nothing.
const ROOM := Vector3(9.0, 4.6, 12.0)
const CAM_AT := Vector3(1.00, 1.50, 3.40)
const CAM_LOOK := Vector3(0.0, 1.45, 0.0)
## Which way it stands: turned to face the camera, and a little off square so the cocked head, the
## throat and the probe hand all read at once.
const FACING := PI + 0.35
## How far it steps to each side on the movement leg, in metres.
const STEP_ASIDE := 1.15

var model: Node3D = null
var holder: Node3D = null
var cap: Label = null
var cam: Camera3D = null


func _ready() -> void:
	_room()
	holder = Node3D.new()
	holder.name = "SonographerHolder"
	add_child(holder)
	holder.rotation.y = FACING
	model = MonsterModelScript.new()
	holder.add_child(model)
	model.setup("sonographer")

	cam = Camera3D.new()
	cam.name = "ReviewCamera"
	cam.fov = 60.0
	cam.position = CAM_AT
	cam.look_at_from_position(CAM_AT, CAM_LOOK, Vector3.UP)
	cam.current = true
	add_child(cam)

	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	cap = Label.new()
	cap.position = Vector2(26, 58)
	cap.add_theme_font_size_override("font_size", 22)
	cap.add_theme_color_override("font_color", Color(0.96, 0.97, 0.92))
	cap.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	cap.add_theme_constant_override("outline_size", 7)
	cap.text = "SONOGRAPHER"
	layer.add_child(cap)
	if model.sono == null:
		var bad := Label.new()
		bad.position = Vector2(26, 20)
		bad.add_theme_font_size_override("font_size", 26)
		bad.add_theme_color_override("font_color", Color(1.0, 0.42, 0.36))
		bad.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		bad.add_theme_constant_override("outline_size", 8)
		bad.text = "SONOGRAPHER NOT FOUND: monster/sonographer did not build. Run --import."
		layer.add_child(bad)
		push_error("[sono_lab] the Sonographer's model did not build")
	if OS.get_cmdline_user_args().has("--capture"):
		_capture()
	await _run()


## A plain box: pale walls, a floor, a ceiling well above its craned head, and enough light to see
## the gel on it.
func _room() -> void:
	var wall := Shapes.flat(Color("6f7a72"), 0.9)
	var floor_m := Shapes.flat(Color("8a8d85"), 0.85)
	add_child(Shapes.box(Vector3(ROOM.x, 0.2, ROOM.z), floor_m, Vector3(0, -0.1, 0)))
	add_child(Shapes.box(Vector3(ROOM.x, 0.2, ROOM.z), wall, Vector3(0, ROOM.y, 0)))
	for spec in [[Vector3(0.2, ROOM.y, ROOM.z), Vector3(-ROOM.x * 0.5, ROOM.y * 0.5, 0)],
			[Vector3(0.2, ROOM.y, ROOM.z), Vector3(ROOM.x * 0.5, ROOM.y * 0.5, 0)],
			[Vector3(ROOM.x, ROOM.y, 0.2), Vector3(0, ROOM.y * 0.5, -ROOM.z * 0.5)],
			[Vector3(ROOM.x, ROOM.y, 0.2), Vector3(0, ROOM.y * 0.5, ROOM.z * 0.5)]]:
		add_child(Shapes.box(spec[0], wall, spec[1]))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.06)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.60, 0.58)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var key := OmniLight3D.new()
	key.position = Vector3(1.8, 3.4, 2.6)
	key.omni_range = 14.0
	key.light_energy = 3.2
	key.light_color = Color(1.0, 0.96, 0.9)
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-2.4, 2.4, 1.6)
	fill.omni_range = 12.0
	fill.light_energy = 1.4
	fill.light_color = Color(0.82, 0.90, 1.0)
	add_child(fill)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-1.2, 3.2, -2.6)
	rim.omni_range = 12.0
	rim.light_energy = 1.8
	rim.light_color = Color(0.85, 0.92, 1.0)
	add_child(rim)


## name, clip, seconds, suspicion from -> to, charge from -> to, ears, crane_limit
func _steps() -> Array:
	return [
		{"say": "idle: neck low, head cocked, the free hand twitching", "clip": "idle", "s": 5.0, "sus": [0.0, 0.0], "chg": [0.0, 0.0], "ear": 0.0},
		{"say": "wander: careful high steps, the free hand feeling the air", "clip": "walk", "s": 5.0, "sus": [0.03, 0.08], "chg": [0.0, 0.0], "ear": 0.1},
		{"say": "listen: frozen, the ears snap round", "clip": "listen", "s": 4.0, "sus": [0.08, 0.35], "chg": [0.0, 0.0], "ear": 1.0},
		{"say": "crane: suspicion takes the neck up and the rings apart", "clip": "listen", "s": 5.0, "sus": [0.35, 1.0], "chg": [0.0, 0.0], "ear": 0.8},
		{"say": "crane under a ceiling: crane_limit 0.2, so it bends forward instead", "clip": "listen", "s": 4.5, "sus": [1.0, 1.0], "chg": [0.0, 0.0], "ear": 0.6, "limit": 0.2},
		{"say": "charge: head up, jaw down, the glow runs out to the probe", "clip": "charge", "s": 3.0, "sus": [1.0, 1.0], "chg": [0.0, 1.0], "ear": 0.6},
		{"say": "echo: mouth wide, rings out of the mouth and the probe", "clip": "echo", "s": 3.0, "sus": [1.0, 0.1], "chg": [1.0, 0.0], "ear": 0.3},
		{"say": "rush: neck low and forward, head leading, both arms out", "clip": "run", "s": 3.5, "sus": [0.2, 0.2], "chg": [0.0, 0.0], "ear": 0.1},
		{"say": "wail: clubbing and clawing, with listening pauses in it", "clip": "attack", "s": 6.4, "sus": [0.2, 0.2], "chg": [0.0, 0.0], "ear": 0.0},
		{"say": "search: still, the neck rising, the head sweeping", "clip": "search", "s": 6.0, "sus": [0.2, 0.7], "chg": [0.0, 0.0], "ear": 0.4},
		{"say": "stagger: shoved, ears pinned, the neck recoiling", "clip": "stagger", "s": 2.4, "sus": [0.3, 0.05], "chg": [0.0, 0.0], "ear": 0.0},
		{"say": "lying: how it goes on the table, the neck back at rest", "clip": "lying", "s": 4.0, "sus": [0.0, 0.0], "chg": [0.0, 0.0], "ear": 0.0},
	]


func _run() -> void:
	while true:
		for st in _steps():
			await _play(st)
		await _walk(-STEP_ASIDE, "walking to its left")
		for st in _steps():
			await _play(st)
		await _walk(STEP_ASIDE, "walking back to its right")


## One clip, for its time, with the look interface ramping across it. It never moves off its mark.
func _play(st: Dictionary) -> void:
	var mode: String = String(st.say).split(":")[0]
	model.play(String(st.clip), 1.0, 0.15)
	var t := 0.0
	var dur := float(st.s)
	var t0 := Time.get_ticks_msec()
	while t < dur:
		await get_tree().process_frame
		var now := (Time.get_ticks_msec() - t0) / 1000.0
		var dt: float = maxf(now - t, 0.0)
		t = now
		var k: float = clampf(t / maxf(dur, 0.01), 0.0, 1.0)
		var sus: Array = st.sus
		var chg: Array = st.chg
		var suspicion: float = lerpf(float(sus[0]), float(sus[1]), k)
		var charge: float = lerpf(float(chg[0]), float(chg[1]), k)
		var limit: float = float(st.get("limit", 1.0))
		_drive(st, suspicion, charge, mode, limit, dt, t)
		cap.text = "SONOGRAPHER  %s\n  suspicion %.2f   charge %.2f   crane %.2f   crane_limit %.2f" % [
			st.say, suspicion, charge, model.sono.crane() if model.sono != null else 0.0, limit]


## The movement leg: it turns, walks `dx` metres across the room on the wander clip, and turns back
## to face the camera. The room is 7 m across and it only ever steps about a metre, so it stays in
## frame the whole way.
func _walk(dx: float, say: String) -> void:
	var from := holder.global_position
	var to := from + Vector3(dx, 0.0, 0.0)
	model.play("walk", 1.0, 0.2)
	# it turns side on to walk across the room, so the walk reads as a walk
	var yaw := (0.5 * PI) if dx > 0.0 else (-0.5 * PI)
	var t := 0.0
	var dur := absf(dx) / 0.8
	var t0 := Time.get_ticks_msec()
	while t < dur:
		await get_tree().process_frame
		var now := (Time.get_ticks_msec() - t0) / 1000.0
		var dt: float = maxf(now - t, 0.0)
		t = now
		holder.rotation.y = lerp_angle(holder.rotation.y, yaw, clampf(dt * 6.0, 0.0, 1.0))
		holder.global_position = from.lerp(to, clampf(t / dur, 0.0, 1.0))
		_drive({"ear": 0.1}, 0.06, 0.0, "wander", 1.0, dt, t)
		cap.text = "SONOGRAPHER  wander: %s\n  suspicion 0.06   charge 0.00   crane %.2f   crane_limit 1.00" % [
			say, model.sono.crane() if model.sono != null else 0.0]
	# and back to facing the camera
	t = 0.0
	t0 = Time.get_ticks_msec()
	while t < 0.6:
		await get_tree().process_frame
		var now2 := (Time.get_ticks_msec() - t0) / 1000.0
		var dt2: float = maxf(now2 - t, 0.0)
		t = now2
		holder.rotation.y = lerp_angle(holder.rotation.y, FACING, clampf(dt2 * 6.0, 0.0, 1.0))
		_drive({"ear": 0.1}, 0.06, 0.0, "wander", 1.0, dt2, t)


func _drive(st: Dictionary, suspicion: float, charge: float, mode: String, limit: float, dt: float, t: float) -> void:
	var fwd: Vector3 = -holder.global_transform.basis.z
	model.set_sono_look(suspicion, charge, mode, fwd, limit)
	var ear: float = float(st.get("ear", 0.0))
	model.set_ears(ear, sin(t * 2.2) * 1.1 * ear, dt)
	if model.shaper != null:
		model.shaper.listen = ear
		model.shaper.listen_yaw = sin(t * 2.2) * 1.1 * ear
		model.shaper.lying = 1.0 if String(st.get("clip", "")) == "lying" else 0.0


## What the window is actually showing, so it can be looked at instead of guessed at.
func _capture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var t0 := Time.get_ticks_msec()
	for at in [5, 15, 30, 45, 60]:
		while Time.get_ticks_msec() - t0 < at * 1000:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/cap_%03ds.png" % [SHOT_DIR, at]
		var err := img.save_png(ProjectSettings.globalize_path(path))
		var c := get_viewport().get_camera_3d()
		var on := c.is_position_in_frustum(holder.global_position + Vector3.UP * 1.2) if c != null else false
		print("[sono_lab] %ds: %s err=%d %dx%d camera=%s holder=%s chest-in-frame=%s" % [
			at, path, err, img.get_width(), img.get_height(),
			c.name if c != null else "NONE", holder.global_position, str(on)])
