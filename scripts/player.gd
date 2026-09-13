class_name Player
extends CharacterBody3D
## A surgeon. Every player owns their own body and reports it to the host;
## the host owns everything that happens *to* them (damage, tools, revival).

const GLOW_RANGE := 3.6
const MOUSE_SENS := 0.0022
## The field of view the first-person hands and held item were placed for.
const BASE_FOV := 78.0
const ACCEL := 14.0
const AIR_ACCEL := 3.0
const JUMP_FORCE := 0.0  # no jumping: this is a hospital

var peer_id: int = 1
var player_name: String = "Surgeon"
var is_local: bool = false
var colour: Color = Color.WHITE

var hp: int = 3
var max_hp: int = 3
var alive: bool = true
var dead_time: float = 0.0
var stamina: float = 1.0
var sprinting: bool = false
var moving: bool = false
var operating: bool = false
var flashlight_on: bool = true
var invuln: float = 0.0

## Two hands. Each holds one stack {kind, count}; kind "" is an empty hand.
## Host authoritative, replicated in the snapshot. `selected` is the hand G, the shelf
## and the guide act on; the player chooses it locally.
var slots: Array = [{"kind": "", "count": 0}, {"kind": "", "count": 0}]
var selected: int = 0

## What the camera is pointed at: the interact_id of an interactable in reach, the prompt
## it offers this player ("!..." means a reason you cannot), and whether it is a hold.
var aim_id: String = ""
var aim_prompt: String = ""
var aim_hold: float = 0.0

## Counters the host watches so each press fires exactly once.
var shove_count: int = 0
var drop_count: int = 0
var interact_count: int = 0
var wants_interact: bool = false

## Test seam: when bot_active is set, these stand in for keyboard and mouse so a
## script can play the game headlessly. Nothing in the shipped game touches them.
var bot_active: bool = false
var bot_move: Vector2 = Vector2.ZERO
var bot_yaw: float = 0.0
var bot_interact: bool = false
var bot_sprint: bool = false
var bot_invulnerable: bool = false
var bot_pitch: float = 0.0
## When set, the bot "looks at" this interactable instead of raycasting.
var bot_aim_id: String = ""
## Bump to press E once on whatever the bot aims at.
var bot_press: int = 0

var _shove_seen: int = 0
var _drop_seen: int = 0
var _interact_seen: int = 0
var _bot_press_seen: int = 0
var _held_key: String = ""
var _held_fp: Node3D
var _held_tp: Node3D
var _shove_cd: float = 0.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _knock: Vector3 = Vector3.ZERO
var _step_accum: float = 0.0
var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _was_on_floor: bool = true

var head: Node3D
var fx: Node3D
var camera: Camera3D
var flashlight: SpotLight3D
var body_visual: Node3D
var name_tag: Label3D
var hands: Node3D
var game: Node = null


static func new_player(id: int, display_name: String, local: bool) -> CharacterBody3D:
	var p: Player = Player.new()
	p.name = "Player_%d" % id
	p.peer_id = id
	p.player_name = display_name
	p.is_local = local
	p.colour = C.PLAYER_COLORS[(id - 1) % C.PLAYER_COLORS.size()]
	p._build()
	return p


func _build() -> void:
	collision_layer = C.L_PLAYER
	collision_mask = C.L_WORLD
	floor_max_angle = deg_to_rad(50)

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = C.PLAYER_RADIUS
	capsule.height = C.PLAYER_HEIGHT
	shape.shape = capsule
	shape.position.y = C.PLAYER_HEIGHT * 0.5
	add_child(shape)

	body_visual = _make_body()
	add_child(body_visual)

	name_tag = Label3D.new()
	name_tag.text = player_name
	name_tag.position.y = C.PLAYER_HEIGHT + 0.35
	name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_tag.no_depth_test = true
	name_tag.font_size = 48
	name_tag.pixel_size = 0.003
	name_tag.modulate = colour.lightened(0.4)
	name_tag.outline_size = 12
	add_child(name_tag)

	head = Node3D.new()
	head.name = "Head"
	head.position.y = C.EYE_H
	add_child(head)

	# The camera-feel node comes from the look pass; a plain pivot works without it.
	var fx_path := "res://scripts/camera_fx.gd"
	if ResourceLoader.exists(fx_path):
		fx = (load(fx_path) as GDScript).new()
	else:
		fx = Node3D.new()
	fx.name = "FX"
	head.add_child(fx)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = BASE_FOV
	camera.near = 0.05
	camera.far = 120.0
	camera.current = is_local
	fx.add_child(camera)

	# These numbers are the look pass's, tuned against its environment. Changing one
	# without the others (especially the fog energy) breaks the beam.
	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	flashlight.position = Vector3(0.18, -0.16, 0.0)
	flashlight.light_color = Color(1.0, 0.86, 0.62)   # warm tungsten against the teal
	flashlight.light_energy = 4.5
	flashlight.spot_range = C.CONE_RANGE
	flashlight.spot_angle = C.CONE_DEG
	flashlight.spot_angle_attenuation = 0.55
	flashlight.spot_attenuation = 1.1
	flashlight.shadow_enabled = true
	flashlight.shadow_bias = 0.03
	flashlight.shadow_normal_bias = 1.0
	# Without this the beam is a bright spot painted on a wall instead of a shaft through the haze.
	flashlight.light_volumetric_fog_energy = 2.8
	camera.add_child(flashlight)

	# A soft bubble so you are never blind at your own feet. Deliberately weak:
	# it should read as "my eyes adjusted", not as a second lamp.
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.72, 0.80, 0.86)
	glow.light_energy = 0.22
	glow.omni_range = GLOW_RANGE
	glow.omni_attenuation = 2.0
	glow.light_volumetric_fog_energy = 0.0
	glow.shadow_enabled = false
	head.add_child(glow)

	hands = _make_hands()
	camera.add_child(hands)

	# Whatever is in the selected hand: in front of the camera for you, in front of the
	# body for everyone else.
	_held_fp = Node3D.new()
	_held_fp.name = "HeldFirstPerson"
	_held_fp.position = Vector3(-0.26, -0.3, -0.48)
	_held_fp.rotation_degrees = Vector3(18, 20, 0)
	camera.add_child(_held_fp)
	_held_tp = Node3D.new()
	_held_tp.name = "HeldThirdPerson"
	_held_tp.position = Vector3(-0.25, 1.05, -0.35)
	body_visual.add_child(_held_tp)

	set_process_input(is_local)


func _ready() -> void:
	game = get_tree().get_first_node_in_group("game")
	_target_pos = global_position
	if is_local:
		body_visual.visible = false
		name_tag.visible = false
		hands.visible = true
		# Settings hook: the local camera follows the field of view setting, live.
		apply_fov(float(Settings.get_value("fov")))
		Settings.changed.connect(_on_setting_changed)
	else:
		hands.visible = false


## Settings hook.
func _on_setting_changed(key: String, value) -> void:
	if key == "fov":
		apply_fov(float(value))


## Settings hook: set the resting field of view (the sprint kick in CameraFX adds on top),
## and move the first-person hands and held stack so they keep their place on screen:
## their x/y offsets scale with tan(fov / 2), their depth stays.
func apply_fov(fov_deg: float) -> void:
	if camera == null:
		return
	camera.fov = fov_deg
	if fx != null and "_base_fov" in fx:
		fx.set("_base_fov", fov_deg)
	var k := tan(deg_to_rad(fov_deg) * 0.5) / tan(deg_to_rad(BASE_FOV) * 0.5)
	var placed: Array = hands.get_children() if hands != null else []
	if _held_fp != null:
		placed.append(_held_fp)
	for n in placed:
		if not n.has_meta("fov_base_pos"):
			n.set_meta("fov_base_pos", n.position)
		var b: Vector3 = n.get_meta("fov_base_pos")
		n.position = Vector3(b.x * k, b.y * k, b.z)


func _make_body() -> Node3D:
	var root := Node3D.new()
	root.name = "Body"
	var real: Node3D = Assets.spawn("char/surgeon") if Assets.has("char/surgeon") else null
	if real != null:
		root.add_child(real)
		return root
	# Placeholder: scrubs in the player's colour.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 0.9
	var torso := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.28
	capsule.height = 1.1
	torso.mesh = capsule
	torso.material_override = mat
	torso.position.y = 1.0
	root.add_child(torso)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color("e2b998")
	var head_mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.17
	sphere.height = 0.34
	head_mesh.mesh = sphere
	head_mesh.material_override = skin
	head_mesh.position.y = 1.68
	root.add_child(head_mesh)
	var cap := MeshInstance3D.new()
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.3, 0.07, 0.32)
	cap.mesh = cap_mesh
	cap.material_override = mat
	cap.position.y = 1.82
	root.add_child(cap)
	return root


func _make_hands() -> Node3D:
	var root := Node3D.new()
	root.name = "Hands"
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color("2a2c30")
	metal.metallic = 0.6
	metal.roughness = 0.4
	var torch := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.032
	cyl.bottom_radius = 0.038
	cyl.height = 0.26
	torch.mesh = cyl
	torch.material_override = metal
	torch.rotation_degrees.x = 90
	torch.position = Vector3(0.32, -0.28, -0.45)
	root.add_child(torch)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color("e2b998")
	var hand := MeshInstance3D.new()
	var hsphere := SphereMesh.new()
	hsphere.radius = 0.06
	hsphere.height = 0.12
	hand.mesh = hsphere
	hand.material_override = skin
	hand.position = Vector3(0.32, -0.33, -0.38)
	root.add_child(hand)
	return root


# =========================================================================
# input and movement
# =========================================================================

func _input(event: InputEvent) -> void:
	if not is_local or not alive:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Settings hook: "sensitivity" multiplies the base look speed.
		var sens: float = MOUSE_SENS * float(Settings.get_value("sensitivity"))
		_yaw -= event.relative.x * sens
		_pitch = clampf(_pitch - event.relative.y * sens, -1.3, 1.3)


func _physics_process(delta: float) -> void:
	if is_local:
		_local_step(delta)
	else:
		_remote_step(delta)
	invuln = maxf(0.0, invuln - delta)
	if not alive:
		dead_time += delta


func _local_step(delta: float) -> void:
	var g: Node = game
	# The mouse is only free while a menu, the guide or the surgery view has it,
	# and then the surgeon stands still.
	var can_move: bool = alive and (g == null or not g.paused) \
		and (bot_active or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	var input_dir := Vector2.ZERO
	var want_sprint := false
	if can_move and bot_active:
		input_dir = bot_move
		wants_interact = bot_interact
		want_sprint = bot_sprint
		_yaw = bot_yaw
		_pitch = bot_pitch
		if bot_invulnerable:
			invuln = 9.0
		if bot_press != _bot_press_seen:
			_bot_press_seen = bot_press
			interact_count += 1
	elif can_move:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		wants_interact = Input.is_action_pressed("interact")
		want_sprint = Input.is_action_pressed("sprint")
	else:
		wants_interact = false

	_update_aim()
	if can_move and not bot_active and Input.is_action_just_pressed("interact") \
			and aim_id != "" and aim_hold <= 0.0 and not aim_prompt.begins_with("!"):
		interact_count += 1

	rotation.y = _yaw
	head.rotation.x = _pitch

	moving = input_dir.length() > 0.1 and not operating
	sprinting = moving and can_move and want_sprint and stamina > 0.0
	stamina = clampf(stamina + (-delta / 4.5 if sprinting else delta / 5.0), 0.0, 1.0)

	var speed: float = 0.0 if operating else (C.SPRINT_SPEED if sprinting else C.WALK_SPEED)
	var dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var target := dir * speed + _knock
	var a: float = ACCEL if is_on_floor() else AIR_ACCEL
	velocity.x = move_toward(velocity.x, target.x, a * delta * maxf(1.0, _knock.length()))
	velocity.z = move_toward(velocity.z, target.z, a * delta * maxf(1.0, _knock.length()))
	if not is_on_floor():
		velocity.y -= 18.0 * delta
	else:
		velocity.y = minf(velocity.y, 0.0) + _knock.y
	_knock = _knock.lerp(Vector3.ZERO, clampf(delta * 6.0, 0.0, 1.0))

	var was_air := not is_on_floor()
	var fall_speed := velocity.y
	move_and_slide()
	if was_air and is_on_floor() and fall_speed < -4.0 and fx.has_method("land"):
		fx.land(clampf(-fall_speed / 14.0, 0.0, 1.0))

	if can_move and not bot_active:
		if Input.is_action_just_pressed("flashlight"):
			set_flashlight(not flashlight_on)
			Audio.play("click")
		_shove_cd = maxf(0.0, _shove_cd - delta)
		if Input.is_action_just_pressed("shove") and _shove_cd <= 0.0:
			_shove_cd = C.SHOVE_COOLDOWN
			shove_count += 1
		if Input.is_action_just_pressed("drop") and slots[selected].kind != "":
			drop_count += 1
		if Input.is_action_just_pressed("slot_1"):
			selected = 0
		if Input.is_action_just_pressed("slot_2"):
			selected = 1
		if Input.is_action_just_pressed("slot_next") or Input.is_action_just_pressed("slot_prev"):
			selected = 1 - selected

	# Footsteps
	if moving and is_on_floor():
		_step_accum += delta * (3.0 if sprinting else 1.9)
		if _step_accum >= 1.0:
			_step_accum = 0.0
			Audio.play("step", global_position, -4.0, 0.12)

	if fx.has_method("set_motion"):
		fx.set_motion(clampf(Vector2(velocity.x, velocity.z).length() / C.SPRINT_SPEED, 0.0, 1.0), sprinting, is_on_floor())
	if fx.has_method("set_fov_kick"):
		fx.set_fov_kick(0.5 if sprinting else 0.0)
	if fx.has_method("set_breathing") and game != null:
		fx.set_breathing(game.danger)

	# Solo has no host to talk to, so apply our own one-shot actions directly.
	if game != null and game.is_host():
		_consume_actions()


func _remote_step(delta: float) -> void:
	var k := clampf(delta * 12.0, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, k)
	rotation.y = lerp_angle(rotation.y, _target_yaw, k)
	head.rotation.x = lerpf(head.rotation.x, _pitch, k)
	if moving:
		_step_accum += delta * (3.0 if sprinting else 1.9)
		if _step_accum >= 1.0:
			_step_accum = 0.0
			Audio.play("step", global_position, -8.0, 0.12)


## Host-side: turn the shove/drop counters into actual events, exactly once each.
func _consume_actions() -> void:
	if game == null:
		return
	if shove_count != _shove_seen:
		_shove_seen = shove_count
		if alive:
			game.player_shoved(self)
	if drop_count != _drop_seen:
		_drop_seen = drop_count
		if alive:
			game.drop_selected(self)
	if interact_count != _interact_seen:
		_interact_seen = interact_count
		if alive:
			game.player_pressed_interact(self, aim_id)


# =========================================================================
# aiming and hands
# =========================================================================

## Find what the camera points at and what it would let this player do.
func _update_aim() -> void:
	aim_id = ""
	aim_prompt = ""
	aim_hold = 0.0
	if not alive:
		return
	var node: Node = null
	if bot_active and bot_aim_id != "" and game != null:
		node = game.find_interactable(bot_aim_id)
	else:
		var from := camera.global_position
		var to := from - camera.global_transform.basis.z * C.INTERACT_RANGE
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = C.L_WORLD | C.L_INTERACT | C.L_PICKUP
		q.collide_with_areas = true
		q.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			return
		node = hit.collider
		while node != null and not node.has_meta("interact_id"):
			node = node.get_parent()
	if node == null or not node.has_method("interact_prompt"):
		return
	var prompt: String = node.interact_prompt(self)
	if prompt == "":
		return
	aim_id = String(node.get_meta("interact_id"))
	aim_prompt = prompt
	aim_hold = node.interact_hold()


## Which hand a stack of this kind would go into, or -1 when both are busy.
func slot_for(kind: String) -> int:
	if Items.stacks(kind):
		for i in slots.size():
			if slots[i].kind == kind:
				return i
	if slots[selected].kind == "":
		return selected
	for i in slots.size():
		if slots[i].kind == "":
			return i
	return -1


func can_take(kind: String) -> bool:
	return slot_for(kind) >= 0


func hands_empty() -> bool:
	for s in slots:
		if s.kind != "":
			return false
	return true


func holding(kind: String) -> bool:
	for s in slots:
		if s.kind == kind:
			return true
	return false


func _process(_delta: float) -> void:
	var s: Dictionary = slots[selected]
	var key := "%s:%d" % [s.kind, s.count]
	if key == _held_key:
		return
	_held_key = key
	for holder in [_held_fp, _held_tp]:
		for c in holder.get_children():
			c.queue_free()
		if s.kind != "":
			holder.add_child(ItemModels.make(s.kind, s.count))
	# The flashlight hand hides nothing; the held stack sits in the other hand.
	_held_fp.visible = is_local
	_held_tp.visible = not is_local


func set_flashlight(on: bool) -> void:
	flashlight_on = on
	flashlight.visible = on


## Does this surgeon's light fall on a world point? Used by the Lurker's freeze rule.
func lights_point(p: Vector3) -> bool:
	var eye := head.global_position
	var to_p := p - eye
	var d := to_p.length()
	if d > C.CONE_RANGE:
		return false
	if d > GLOW_RANGE:
		if not flashlight_on:
			return false
		var forward: Vector3 = -camera.global_transform.basis.z
		if forward.dot(to_p.normalized()) < cos(deg_to_rad(C.CONE_DEG)):
			return false
	# Clear line of sight?
	var q := PhysicsRayQueryParameters3D.create(eye, p)
	q.collision_mask = C.L_WORLD
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty()


# =========================================================================
# state changes (host authority)
# =========================================================================

func teleport(pos: Vector3) -> void:
	global_position = pos
	_target_pos = pos
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO


func revive_full() -> void:
	hp = max_hp
	alive = true
	dead_time = 0.0
	invuln = 0.0
	stamina = 1.0
	slots = [{"kind": "", "count": 0}, {"kind": "", "count": 0}]
	selected = 0
	operating = false
	_set_visible_alive(true)


func revive(with_hp: int) -> void:
	hp = with_hp
	alive = true
	dead_time = 0.0
	invuln = 3.0
	_set_visible_alive(true)


func take_hit(dmg: int, knock: Vector3) -> void:
	hp = maxi(0, hp - dmg)
	invuln = 3.0
	apply_knock(knock)
	flinch()
	if hp <= 0:
		alive = false
		dead_time = 0.0
		operating = false
		_set_visible_alive(false)


func apply_knock(knock: Vector3) -> void:
	_knock = knock
	velocity += knock * 0.5


func flinch() -> void:
	if fx.has_method("add_shake"):
		fx.add_shake(1.0, 0.5)
	if fx.has_method("impact"):
		fx.impact(-global_transform.basis.z, true)  # second arg: this is a direction, not a point


func _set_visible_alive(a: bool) -> void:
	if not is_local:
		body_visual.visible = a
		name_tag.visible = a
	collision_layer = C.L_PLAYER if a else 0


# =========================================================================
# networking
# =========================================================================

## Client -> host, 20 Hz: everything about my own surgeon.
func report_state() -> Dictionary:
	return {
		"p": global_position, "y": rotation.y, "pi": head.rotation.x,
		"fl": flashlight_on, "sp": sprinting, "mv": moving,
		"ia": wants_interact, "sh": shove_count, "dr": drop_count,
		"ai": aim_id, "ic": interact_count, "sel": selected,
	}


func apply_remote_state(s: Dictionary) -> void:
	if alive:
		_target_pos = s.p
		global_position = s.p
	_target_yaw = s.y
	rotation.y = s.y
	_pitch = s.pi
	head.rotation.x = s.pi
	set_flashlight(s.fl)
	sprinting = s.sp
	moving = s.mv
	wants_interact = s.ia
	shove_count = s.sh
	drop_count = s.dr
	aim_id = String(s.get("ai", ""))
	selected = clampi(int(s.get("sel", selected)), 0, 1)
	# Drop before interacting so a count that moved in the same tick uses the right hand.
	var ic := int(s.get("ic", interact_count))
	interact_count = ic
	_consume_actions()


## Host -> everyone, 20 Hz: the authoritative view of every surgeon.
func report_full() -> Dictionary:
	return {
		"id": peer_id, "p": global_position, "y": rotation.y, "pi": head.rotation.x,
		"fl": flashlight_on, "sp": sprinting, "mv": moving, "op": operating,
		"hp": hp, "al": alive, "iv": invuln > 0.0, "sl": slots, "sel": selected,
	}


func apply_remote_full(s: Dictionary) -> void:
	hp = s.hp
	var new_slots: Array = s.get("sl", slots)
	if is_local:
		# Something just landed in an empty hand: select it, like picking it up would.
		for i in mini(new_slots.size(), slots.size()):
			if slots[i].kind == "" and new_slots[i].kind != "":
				selected = i
	else:
		selected = int(s.get("sel", selected))
	slots = new_slots.duplicate(true)
	if alive != s.al:
		if s.al:
			revive(s.hp)
		else:
			alive = false
			dead_time = 0.0
			_set_visible_alive(false)
	operating = s.op
	if is_local:
		return
	_target_pos = s.p
	_target_yaw = s.y
	_pitch = s.pi
	set_flashlight(s.fl)
	sprinting = s.sp
	moving = s.mv
