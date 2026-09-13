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

## Four hand slots (C.CARRY_CAP). Each holds one stack {kind, count} plus "v" (sell value in
## dollars) for loot; kind "" is an empty slot. Bulky loot fills its slot and a second one: that
## second slot is {kind: "", count: 0, of: <index of the stack>}, so it is not empty but code
## that walks slots for stacks never sees the bulky item twice. Host authoritative, replicated
## in the snapshot. `selected` is the slot G, the shelf, the sell bin and the guide act on (a
## selected second half acts on its stack); the player chooses it locally.
## Change slots through take_into() / clear_slot(); _fix_links() tidies anything else.
var slots: Array = empty_slots()
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

## DEV HOOK (scripts/dev): a dev room bot or target dummy. The host simulates it like a local
## player through the bot_* seam; everyone else sees it like a remote player.
var is_bot: bool = false
## DEV HOOK: seconds left knocked down (no moving). Wave 3's downed state replaces this.
var stun: float = 0.0
## DEV HOOK: flying through walls (dev panel).
var noclip: bool = false

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


## Keys 1..C.CARRY_CAP select a slot. project.godot ships slot_1 and slot_2; the rest are added
## here at runtime (idempotent) so no input map edit is needed.
static func ensure_slot_actions() -> void:
	for i in C.CARRY_CAP:
		var action := "slot_%d" % (i + 1)
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.5)
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_1 + i
		InputMap.action_add_event(action, ev)


func _build() -> void:
	ensure_slot_actions()
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
	# DEV HOOK: the host drives dev room bots as if they were its own players.
	if is_local or (is_bot and game != null and game.is_host()):
		_local_step(delta)
	else:
		_remote_step(delta)
	stun = maxf(0.0, stun - delta)
	invuln = maxf(0.0, invuln - delta)
	if game != null and game.is_host():
		_fix_links()
	if not alive:
		dead_time += delta


func _local_step(delta: float) -> void:
	var g: Node = game
	# The mouse is only free while a menu, the guide or the surgery view has it,
	# and then the surgeon stands still.
	var can_move: bool = alive and (g == null or not g.paused) and stun <= 0.0 \
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

	# DEV HOOK (scripts/dev): noclip flies through walls; nothing below applies.
	if noclip and g != null and g.dev != null:
		g.dev.noclip_move(self, input_dir, want_sprint, delta)
		if g.is_host():
			_consume_actions()
		return

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
		# DEV HOOK: with the dev gun out, the left mouse button fires instead of shoving.
		var gun_out: bool = g != null and g.dev_mode and g.dev.has_gun(peer_id) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if Input.is_action_just_pressed("shove") and _shove_cd <= 0.0 and not gun_out:
			_shove_cd = C.SHOVE_COOLDOWN
			shove_count += 1
		if Input.is_action_just_pressed("drop") and selected_stack().kind != "":
			drop_count += 1
		for i in C.CARRY_CAP:
			if Input.is_action_just_pressed("slot_%d" % (i + 1)):
				selected = i
		if Input.is_action_just_pressed("slot_next"):
			select_step(1)
		if Input.is_action_just_pressed("slot_prev"):
			select_step(-1)

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


static func empty_slot() -> Dictionary:
	return {"kind": "", "count": 0}


static func empty_slots() -> Array:
	var out := []
	for i in C.CARRY_CAP:
		out.append(empty_slot())
	return out


## Truly free: no stack and not the second half of a bulky one.
func slot_free(i: int) -> bool:
	return i >= 0 and i < slots.size() and String(slots[i].kind) == "" and not slots[i].has("of")


## The index of the stack occupying slot i (i itself unless it is a bulky second half).
func head_of(i: int) -> int:
	if i < 0 or i >= slots.size():
		return -1
	return int(slots[i].of) if slots[i].has("of") else i


## The second slot a bulky stack at `head` uses, or -1.
func tail_of(head: int) -> int:
	for i in slots.size():
		if i != head and slots[i].has("of") and int(slots[i].of) == head:
			return i
	return -1


func selected_head() -> int:
	return maxi(0, head_of(clampi(selected, 0, slots.size() - 1)))


## The stack the selected slot acts on ({kind: ""} when empty).
func selected_stack() -> Dictionary:
	return slots[selected_head()]


func free_slot_count() -> int:
	var n := 0
	for i in slots.size():
		if slot_free(i):
			n += 1
	return n


## Mouse wheel: the next or previous slot, stepping over a bulky stack's second half.
func select_step(dir: int) -> void:
	var n := slots.size()
	var head := selected_head()
	var i := selected
	for k in n:
		i = posmod(i + dir, n)
		if head_of(i) != head or n == 1:
			break
	selected = head_of(i)


## Which slot a stack of this kind would go into, or -1 when there is no room. A bulky kind also
## needs the next free slot after that one (wrapping round), see bulky_pair().
func slot_for(kind: String) -> int:
	if Items.stacks(kind) and not Items.is_bulky(kind):
		for i in slots.size():
			if String(slots[i].kind) == kind:
				return i
	if Items.is_bulky(kind):
		return bulky_pair()[0]
	if slot_free(selected):
		return selected
	for i in slots.size():
		if slot_free(i):
			return i
	return -1


## [head, tail] for a new bulky stack: the selected slot when free (else the first free one) and
## the next free slot after it. [-1, -1] without two free slots.
func bulky_pair() -> Array:
	var n := slots.size()
	var first := selected if slot_free(selected) else -1
	if first < 0:
		for i in n:
			if slot_free(i):
				first = i
				break
	if first < 0:
		return [-1, -1]
	for k in range(1, n):
		var j := (first + k) % n
		if slot_free(j):
			return [first, j]
	return [-1, -1]


func can_take(kind: String) -> bool:
	return slot_for(kind) >= 0


## Host: put a stack in the hands (merging, or filling two slots for bulky loot). Returns the
## slot it went into, or -1 without room. `value` is the stack's sell value (loot).
func take_into(kind: String, count: int, value: int = 0) -> int:
	var i := slot_for(kind)
	if i < 0:
		return -1
	if String(slots[i].kind) == kind:
		slots[i].count = int(slots[i].count) + count
		if value > 0 or slots[i].has("v"):
			slots[i]["v"] = int(slots[i].get("v", 0)) + value
		return i
	var s := {"kind": kind, "count": count}
	if value > 0:
		s["v"] = value
	slots[i] = s
	if Items.is_bulky(kind):
		var pair := bulky_pair_for(i)
		if pair >= 0:
			slots[pair] = {"kind": "", "count": 0, "of": i}
	return i


## The free slot a bulky stack placed at `head` takes as its second half.
func bulky_pair_for(head: int) -> int:
	var n := slots.size()
	for k in range(1, n):
		var j := (head + k) % n
		if slot_free(j):
			return j
	return -1


## Empty a stack's slot and its bulky second half (pass either one).
func clear_slot(i: int) -> void:
	var head := head_of(i)
	if head < 0:
		return
	var tail := tail_of(head)
	slots[head] = empty_slot()
	if tail >= 0:
		slots[tail] = empty_slot()


## Second halves whose stack is gone become empty again; a bulky stack that lost its second
## half gets one back if there is room. Cheap; the host runs it every tick.
func _fix_links() -> void:
	for i in slots.size():
		if not slots[i].has("of"):
			continue
		var h := int(slots[i].of)
		if h < 0 or h >= slots.size() or h == i or String(slots[h].kind) == "" or not Items.is_bulky(String(slots[h].kind)) or slots[h].has("of"):
			slots[i] = empty_slot()
	for i in slots.size():
		var k := String(slots[i].kind)
		if k != "" and Items.is_bulky(k) and tail_of(i) < 0:
			var j := bulky_pair_for(i)
			if j >= 0:
				slots[j] = {"kind": "", "count": 0, "of": i}


func hands_empty() -> bool:
	for s in slots:
		if String(s.kind) != "":
			return false
	return true


func holding(kind: String) -> bool:
	for s in slots:
		if s.kind == kind:
			return true
	return false


func _process(_delta: float) -> void:
	_update_down_pose(_delta)  # DEV HOOK
	var s: Dictionary = selected_stack()
	var key := "%s:%d" % [s.kind, s.count]
	if key == _held_key:
		return
	_held_key = key
	for holder in [_held_fp, _held_tp]:
		for c in holder.get_children():
			c.queue_free()
		if s.kind != "":
			holder.add_child(_held_model(String(s.kind), int(s.count), holder == _held_fp))
	# The flashlight hand hides nothing; the held stack sits in the other hand.
	_held_fp.visible = is_local
	_held_tp.visible = not is_local


## A held stack, tinted, sized for the hands: bulky loot is carried low in front with both hands
## and scaled down in first person so it does not fill the screen.
func _held_model(kind: String, count: int, first_person: bool) -> Node3D:
	var model := ItemModels.make_tinted(kind, count)
	var fp := ItemModels.footprint(kind)
	var biggest := maxf(fp.x, maxf(fp.y, fp.z))
	var pivot := Node3D.new()
	pivot.name = "Held"
	pivot.add_child(model)
	if Items.is_bulky(kind):
		var limit := 0.3 if first_person else 0.55
		var k := minf(1.0, limit / maxf(0.01, biggest))
		model.scale = Vector3.ONE * k
		model.position = Vector3(-fp.x * 0.5 * k, 0.0, 0.0)
		if first_person:
			# Centre-low, both hands: undo most of the one-hand tilt of HeldFirstPerson.
			pivot.position = Vector3(0.2, -0.04, 0.02)
			pivot.rotation_degrees = Vector3(-12, -20, 0)
		else:
			pivot.position = Vector3(0.25, -0.15, 0.0)
	return pivot


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
	slots = empty_slots()
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
		body_visual.visible = a or is_bot  # DEV HOOK: dead bots stay, lying where they fell
		name_tag.visible = a
	collision_layer = C.L_PLAYER if a else 0


## DEV HOOK (scripts/dev): knocked down (stun) you see the floor; everyone else sees you lying
## on it. Dead bots lie there too. Wave 3's downed state replaces this.
func _update_down_pose(delta: float) -> void:
	var down := stun > 0.0 or (is_bot and not alive)
	if is_local and not is_bot:
		var eye := 0.45 if down and alive else C.EYE_H
		if not is_equal_approx(head.position.y, eye):
			head.position.y = move_toward(head.position.y, eye, delta * 6.0)
		return
	var tilt := -PI * 0.47 if down else 0.0
	if not is_equal_approx(body_visual.rotation.x, tilt):
		body_visual.rotation.x = move_toward(body_visual.rotation.x, tilt, delta * 6.0)
		body_visual.position.y = 0.3 * (body_visual.rotation.x / (-PI * 0.47))


# =========================================================================
# networking
# =========================================================================

## Client -> host, 20 Hz: everything about my own surgeon. A positional array rather than a
## dictionary: no key strings on the wire, about a third of the size.
##   [position, yaw, pitch, flag bits (1 light, 2 sprint, 4 moving, 8 holding E),
##    shove count, drop count, aim id, interact count, selected hand]
func report_state() -> Array:
	var bits := (1 if flashlight_on else 0) | (2 if sprinting else 0) | (4 if moving else 0) | (8 if wants_interact else 0)
	return [global_position, rotation.y, head.rotation.x, bits, shove_count, drop_count, aim_id, interact_count, selected]


func apply_remote_state(s: Array) -> void:
	if s.size() < 9:
		return
	var bits := int(s[3])
	if alive:
		_target_pos = s[0]
		global_position = s[0]
	_target_yaw = float(s[1])
	rotation.y = float(s[1])
	_pitch = float(s[2])
	head.rotation.x = float(s[2])
	set_flashlight(bits & 1 != 0)
	sprinting = bits & 2 != 0
	moving = bits & 4 != 0
	wants_interact = bits & 8 != 0
	shove_count = int(s[4])
	drop_count = int(s[5])
	aim_id = String(s[6])
	selected = clampi(int(s[8]), 0, slots.size() - 1)
	# Drop before interacting so a count that moved in the same tick uses the right hand.
	interact_count = int(s[7])
	_consume_actions()


## Host -> everyone, 20 Hz: the authoritative view of every surgeon. Values are quantized
## (1 cm, ~0.6 degrees) so a surgeon standing still produces no snapshot delta, and `sl` is a
## deep copy because the host edits hand stacks in place.
func report_full() -> Dictionary:
	return {
		"id": peer_id, "p": global_position.snappedf(0.01), "y": snappedf(rotation.y, 1.0 / 128.0),
		"pi": snappedf(head.rotation.x, 1.0 / 128.0),
		"fl": flashlight_on, "sp": sprinting, "mv": moving, "op": operating,
		"hp": hp, "al": alive, "iv": invuln > 0.0, "sl": slots.duplicate(true), "sel": selected,
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
	while slots.size() < C.CARRY_CAP:
		slots.append(empty_slot())
	selected = clampi(selected, 0, slots.size() - 1)
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
