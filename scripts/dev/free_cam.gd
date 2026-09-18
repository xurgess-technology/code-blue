extends Camera3D
## The dev free camera (dev panel, "Free camera"). Local only: it takes over the view from where
## your eyes are and leaves your surgeon standing there, body showing. P hands the keyboard and
## mouse back and forth: flying the camera (WASD, mouse, Space up, Ctrl or C down, Shift fast),
## or walking the surgeon while the camera stays put. Real-time speed, whatever the time scale.

const FLY_SPEED := 6.0
const FAST_MUL := 4.0
const HandsFP := preload("res://scripts/hands/fp_hands.gd")

var game: Node = null
var player: Node = null      # the local player we left behind
var flying := true           # true: the camera has the input; false: the surgeon does
var _yaw := 0.0
var _pitch := 0.0


func _init() -> void:
	name = "DevFreeCam"
	near = 0.05
	far = 200.0
	cull_mask = cull_mask & ~HandsFP.HANDS_LAYER   # nobody's first-person hands float in the air
	set_process(false)
	set_process_input(false)


func is_on() -> bool:
	return player != null


## Start at the local player's eyes, flying. Returns false when there is nobody to leave behind.
func start(g: Node) -> bool:
	game = g
	var p = g.local_player() if g != null else null
	if p == null or p.camera == null:
		return false
	player = p
	var xf: Transform3D = p.camera.global_transform
	global_position = xf.origin
	var e := xf.basis.get_euler(EULER_ORDER_YXZ)
	_pitch = e.x
	_yaw = e.y
	fov = p.camera.fov
	_apply_look()
	make_current()
	_show_body(true)
	_set_flying(true)
	set_process(true)
	set_process_input(true)
	return true


func stop() -> void:
	set_process(false)
	set_process_input(false)
	var p = player
	player = null
	current = false
	if p != null and is_instance_valid(p):
		p.dev_input_held = false
		_show_body_on(p, false)
		p.camera.current = true


## P: flying the camera <-> walking the surgeon.
func swap() -> void:
	_set_flying(not flying)


func _set_flying(on: bool) -> void:
	flying = on
	if player != null and is_instance_valid(player):
		player.dev_input_held = on


func _input(event: InputEvent) -> void:
	if not flying or not (event is InputEventMouseMotion) or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var sens: float = 0.0022 * float(Settings.get_value("sensitivity"))
	_yaw -= event.relative.x * sens
	_pitch = clampf(_pitch - event.relative.y * sens, -1.55, 1.55)
	_apply_look()


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player) or not player.alive:
		stop()
		return
	# The carry camera turns the body off again whenever it lets go; keep showing it.
	if not player.body_visual.visible and player.carried_by == 0 and not player.on_table:
		_show_body(true)
	if not flying or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var real_dt := delta / maxf(Engine.time_scale, 0.01)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var v := global_transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	if Input.is_physical_key_pressed(KEY_SPACE):
		v += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C):
		v += Vector3.DOWN
	var speed := FLY_SPEED * (FAST_MUL if Input.is_action_pressed("sprint") else 1.0)
	global_position += v.limit_length(1.0) * speed * real_dt


func _apply_look() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)


func _show_body(on: bool) -> void:
	_show_body_on(player, on)


## Same as the carry camera's body swap (scripts/camera/carry_camera.gd): the torch sits inside
## the head, so the local body casts no shadow. Turning it off hands it back to the carry camera.
static func _show_body_on(p: Node, on: bool) -> void:
	if p == null or p.body_visual == null:
		return
	if not on:
		var cc = p.carry_cam
		on = cc != null and cc.active and cc._body_shown
	p.body_visual.visible = on
	if on:
		for mi in p.body_visual.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if p.body_hands != null:
		p.body_hands.set_active(on)
