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
## in the snapshot. `selected` is the slot G, the shelf and the sell bin act on (a
## selected second half acts on its stack); the player chooses it locally.
## Change slots through take_into() / clear_slot(); _fix_links() tidies anything else.
var slots: Array = empty_slots()
var selected: int = 0

## What the camera is pointed at: the interact_id of an interactable in reach, the prompt
## it offers this player ("!..." means a reason you cannot), and whether it is a hold.
var aim_id: String = ""
var aim_prompt: String = ""
var aim_hold: float = 0.0
## AFFORDANCE HOOK: the node (if any) currently wearing the local player's aim highlight rim
## (scripts/aim_highlight.gd). Local-only presentation, never replicated or read elsewhere.
var _aim_highlighted: Node = null

## Counters the host watches so each press fires exactly once.
var shove_count: int = 0
var drop_count: int = 0
## SWEEP 4A HOOK (pharmacy, chunk 3): 0..1 charge the drop key had when it last fired
## (client-owned, sent alongside drop_count so the host reads them together). A quick tap
## reports ~0 (the old gentle toss); holding the key ramps it up to 1 by DROP_CHARGE_FULL.
var drop_charge: float = 0.0
var _drop_holding: bool = false
var _drop_hold_t: float = 0.0
const DROP_TAP_MAX := 0.15
const DROP_CHARGE_FULL := 1.1
var interact_count: int = 0
var wants_interact: bool = false
## SWEEP 3 HOOK: left mouse with a usable item in hand (bone saw swing, anesthetic jab; see
## scripts/combat/combat.gd), and R for the absorbed-brain ability (scripts/brains/brains.gd).
var use_count: int = 0
## SWEEP 4A HOOK (controls): four ability slots (scripts/brains/brains.gd), each with its own
## bump counter (Alt+1..4), analogous to ability_count before it. Report keys "a1".."a4".
var ability_slot_press: Array = [0, 0, 0, 0]
## SWEEP 4A HOOK (controls): crouch (client-owned, replicated: report bit 16 / report_full "cr")
## and the scanner (client-owned aim/hold, report bit 32; the host checks range/LOS and records).
var crouching: bool = false
## Lying flat and crawling (replicated: report bit 64 / report_full "pr"). `crouching` is also true
## while prone, so everything gated on crouching (no sprint, no jump, silent steps) covers prone too.
var prone: bool = false
const STAND := 0
const CROUCH := 1
const PRONE := 2
var scan_holding: bool = false
## Terminal redesign: left clicks made while scanning (the laser's click), counted like bot_press;
## scan_fx.gd reads the count on the local machine.
var laser_clicks: int = 0
var bot_laser_click: int = 0
var _bot_laser_click_seen: int = 0
## SPRINT-DIVE HOOK: pressing crouch while sprinting forward launches a dive that lands prone.
## Purely client-owned local movement, like the rest of _local_step (see docs/KNOWN_ISSUES.md
## "Sprint + crouch-dive"). Not replicated as its own field: it forces `prone` for its duration
## through the same _apply_crouch() capsule-resize path, and `prone` replicates.
var diving: bool = false
var _dive_t: float = 0.0
var _dive_airborne: bool = false
var _dive_dir: Vector3 = Vector3.ZERO
var _bot_dive_seen: int = 0
var _bot_dive_fire: bool = false
## Toggle sprint: the sprint key flips this on/off instead of having to be held (Settings
## "sprint_mode" = "toggle", the default; "hold" restores hold-to-sprint).
var _sprint_toggle: bool = false
## Seconds left in which a crouch press still counts as "while sprinting", so the dive doesn't
## need frame-perfect timing against the moment sprint drops.
var _sprint_grace: float = 0.0
## Slide-out after landing, not counting the time in the air.
const DIVE_DURATION := 0.4
const DIVE_SPEED_MULT := 1.45
## Upward launch speed and the softer gravity used while airborne in a dive: ~0.54 m peak, ~0.6 s
## in the air. The view rises with the body, then sinks toward prone height on the way down so it
## meets the floor as the body does.
const DIVE_HOP_VELOCITY := 3.6
const DIVE_GRAVITY := 12.0
const DIVE_LAND_THUD := 0.8
const DIVE_LAND_SHAKE := 0.35
var _dive_launch_y: float = 0.0
var _dive_peak_y: float = 0.0
const DIVE_SPRINT_GRACE := 0.2
## Stamina (0..1) spent per dive; stamina also doesn't recover mid-dive. About five back-to-back
## dives from a full bar.
const DIVE_STAMINA_COST := 0.2
## Local-only cosmetic scan progress (0..1) and the monster id it is aimed at, for the HUD ring.
## Not replicated: every machine computes its own from its own aim, same as aim_id/aim_prompt.
var scan_progress: float = 0.0
var scan_target_id: int = -1
## SWEEP 3 HOOK (brains): looking through a Walk-In's eyes (Hive Eyes). Host authoritative, report
## key `hv`. The body stands still and helpless: no moving, looking, using or picking up; E or R
## (or Esc, main.gd) ends it; others see the head droop.
var hive_view: bool = false
var _hive_pitch := 0.0
var _was_hive := false

## SWEEP 4A HOOK (pharmacy, chunk 3): the placebo pill's warm screen effect. Purely local
## presentation (never replicated): the host tells the affected machine a pill landed
## (game._event "pill_warm") and that machine alone ticks and renders this. `warm_level` is what
## hud.gd draws (0..1, capped low so it never hurts visibility); `warm_target`/`warm_hold_left`
## drive the fade in / hold / fade out.
var warm_level: float = 0.0
var warm_target: float = 0.0
var warm_hold_left: float = 0.0
const WARM_FADE_IN := 2.0
const WARM_HOLD := 15.0
const WARM_FADE_OUT := 3.0
const WARM_CAP := 1.0
const WARM_STEP := 0.4

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
## Bump to use the held item once (left mouse) / the brain ability once (R).
var bot_use: int = 0
var bot_ability: int = 0
## SWEEP 4A HOOK: which slot bot_ability fires (default 0, back-compat with older bot scripts).
var bot_ability_slot: int = 0
## Bot stance: bot_prone wins over bot_crouch, neither means stand. Applied only when one of them
## changes, so a bot that dives stays prone until its script asks for something else.
var bot_crouch: bool = false
var bot_prone: bool = false
var bot_jump: int = 0
var bot_scan: bool = false
## Bump = one press of the crouch key, exactly as a human's: cycles stand -> crouch -> prone ->
## stand, or dives when pressed mid-sprint.
var bot_crouch_press: int = 0
## SPRINT-DIVE HOOK: bump to fire the sprint+crouch-dive once (only the dive, never a stance step).
var bot_dive: int = 0

## DEV HOOK (scripts/dev): a dev room bot or target dummy. The host simulates it like a local
## player through the bot_* seam; everyone else sees it like a remote player.
var is_bot: bool = false
## DEV HOOK: seconds left knocked down (no moving). Wave 3's downed state replaces this.
var stun: float = 0.0
## DEV HOOK: flying through walls (dev panel).
var noclip: bool = false

## Downed (sweep 2 wave 3, docs/CONTRACTS.md "Downed players"). All host authoritative and
## replicated in report_full. A downed player is still `alive` (not dead) but not standing: it lies
## on the floor, crawls, bleeds out over `bleed` seconds, and cannot use anything but E to call
## for help. `carried_by` / `carrying` are peer ids (0 = nobody). `on_table` means lying on the
## OR's player table. `carry_hold` is how long this player has held E on a downed teammate.
var downed: bool = false
var bleed: float = 0.0
var carried_by: int = 0
var carrying: int = 0
var on_table: bool = false
var carry_hold: float = 0.0
## The aim target teammates hold E on to pick this player up (layer on only while downed).
var downed_aim: Area3D

const CRAWL_SPEED := 0.75
const CARRY_SPEED_K := 0.6

## SWEEP 3 HOOK (combat): the monster id this player drags (scripts/combat/combat.gd), -1 for none.
## Host authoritative, report key `dm`. A dragger walks slowly and cannot shove, use, drop or
## change slots; E straps the monster to a free patient table or puts it down.
var dragging_monster: int = -1
const CombatScript := preload("res://scripts/combat/combat.gd")

## HANDS HOOK (docs/HANDS_AND_FEEDBACK.md): the first-person hands (`hands`, scripts/hands/fp_hands.gd),
## the body's clips, poses and hand sockets (`body_hands`, scripts/hands/body_hands.gd), the wind-ups
## (game.combat.windup) and the over-the-shoulder carry camera (`carry_cam`, local player only).
const HandsFP := preload("res://scripts/hands/fp_hands.gd")
const BodyHandsScript := preload("res://scripts/hands/body_hands.gd")
const HumanModel := preload("res://scripts/human/human_model.gd")   # HUMAN HOOK
const CarryCameraScript := preload("res://scripts/camera/carry_camera.gd")
const Grips := preload("res://scripts/hands/grips.gd")
const FogRingScript := preload("res://scripts/level/fog_ring.gd")   # SWEEP 4A HOOK (fog lot, chunk 2)
var body_hands: RefCounted = null
var carry_cam: RefCounted = null
## Test seam: true holds the shove button (charging), false lets go (the shove fires).
var bot_charge: bool = false
var _bot_charging := false
var _charging_with := ""      # "shove" (Q) or "use" (left mouse): the button charging a shove here
var _jab_prompt := ""
var _jab_prompt_t := 0.0

var _shove_seen: int = 0
var _drop_seen: int = 0
var _interact_seen: int = 0
var _bot_press_seen: int = 0
var _use_seen: int = 0
var _ability_slot_seen: Array = [0, 0, 0, 0]
var _bot_use_seen: int = 0
var _bot_ability_seen: int = 0
var _bot_jump_seen: int = 0
var _bot_jump_fire: bool = false
## SWEEP 4A HOOK (controls): the collision capsule, resized crouched/standing.
var _capsule: CapsuleShape3D
var _coll_shape: CollisionShape3D
## Requested stance, client-owned: STAND / CROUCH / PRONE. The actual `crouching`/`prone` can sit
## lower than this while there's no headroom to rise.
var _stance_want: int = STAND
var _bot_crouch_press_seen: int = 0
var _bot_stance_prev: int = STAND
var _held_key: String = ""
var _held_fp: Node3D
var _held_tp: Node3D
var _shove_cd: float = 0.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _knock: Vector3 = Vector3.ZERO
var _step_accum: float = 0.0
var _scan_beep_accum: float = 0.0   # SWEEP 4A HOOK (scanner)
var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _was_on_floor: bool = true

var head: Node3D
var fx: Node3D
var _hive_glaze: MeshInstance3D   # SWEEP 4A HOOK (Hive Eyes, chunk 4): glazed eyes, teammates only
var camera: Camera3D
var flashlight: SpotLight3D
var body_visual: Node3D
## HUMAN HOOK: where a carried human's Carried clip origin (the belly) sits, in the carrier's frame: the
## human carrier's right shoulder.
const HUMAN_CARRIED_SHOULDER := Vector3(0.15, 1.535, 0.03)
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
	_capsule = capsule
	_coll_shape = shape

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

	# SWEEP 4A HOOK (Hive Eyes, chunk 4): a glazed-eyes glow teammates see on the existing head
	# while this player is in Hive Eyes (docs/SWEEP4A.md "Teammates can see it"). A material swap
	# on the exact eye geometry would need the specific rig (Blender human or the primitive
	# fallback); an emissive quad at eye height reads the same at a glance on either body.
	_hive_glaze = MeshInstance3D.new()
	_hive_glaze.name = "HiveGlaze"
	var glaze_q := QuadMesh.new()
	glaze_q.size = Vector2(0.16, 0.06)
	_hive_glaze.mesh = glaze_q
	var glaze_mat := StandardMaterial3D.new()
	glaze_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glaze_mat.albedo_color = Color(0.7, 1.0, 0.85, 0.8)
	glaze_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glaze_mat.emission_enabled = true
	glaze_mat.emission = Color(0.55, 1.0, 0.7)
	glaze_mat.emission_energy_multiplier = 2.2
	glaze_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hive_glaze.material_override = glaze_mat
	_hive_glaze.position = Vector3(0.0, 0.0, 0.09)
	_hive_glaze.visible = false
	head.add_child(_hive_glaze)

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
	# HANDS HOOK: the torch sits a hand's width from the hands; it does not light them (or the held stack).
	flashlight.light_cull_mask = flashlight.light_cull_mask & ~HandsFP.HANDS_LAYER
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

	# HANDS HOOK: forearms and hands (the torch in the right, the stack in the left).
	hands = HandsFP.new()
	hands.setup(self)
	camera.add_child(hands)

	# Whatever is in the selected hand: on your left palm (the hands place it every frame), and in
	# the right hand of your body for everyone else (body_hands places it on the rig's hand).
	_held_fp = Node3D.new()
	_held_fp.name = "HeldFirstPerson"
	camera.add_child(_held_fp)
	_held_tp = Node3D.new()
	_held_tp.name = "HeldThirdPerson"
	_held_tp.position = BodyHandsScript.FIXED_ATTACH
	body_visual.add_child(_held_tp)
	body_hands = BodyHandsScript.new(self, body_visual)   # HANDS HOOK
	if is_local:
		carry_cam = CarryCameraScript.new(self)   # HANDS HOOK

	# Downed: lying along -Z from the feet (see _update_down_pose), aimable from above.
	downed_aim = DownedAim.new()
	downed_aim.name = "DownedAim"
	downed_aim.collision_layer = 0
	downed_aim.collision_mask = 0
	downed_aim.monitoring = false
	downed_aim.add_to_group("interactable")
	downed_aim.set_meta("interact_id", "pl_%d" % peer_id)
	var aim_shape := CollisionShape3D.new()
	var aim_cap := CapsuleShape3D.new()
	aim_cap.radius = 0.42
	aim_cap.height = 1.9
	aim_shape.shape = aim_cap
	aim_shape.rotation_degrees = Vector3(90, 0, 0)
	aim_shape.position = Vector3(0, 0.3, -0.85)
	downed_aim.add_child(aim_shape)
	add_child(downed_aim)

	set_process_input(is_local)


## Downed hook: teammates aim at a downed player and hold E to pick them up. The hold itself is
## simulated by the host (game._tick_carry_holds); nothing happens on a press.
class DownedAim extends Area3D:
	func _owner_player() -> Node:
		return get_parent()

	func interact_prompt(q) -> String:
		var p = _owner_player()
		var g = p.game if p != null else null
		if g == null or q == p or not g.can_pick_up(q, p, false):
			return ""
		if not q.hands_empty():
			return "!Empty your hands to carry %s." % p.player_name
		return "Hold E: pick up %s" % p.player_name

	func interact_hold() -> float:
		return 1.0

	func interact(_q) -> void:
		pass


func _ready() -> void:
	game = get_tree().get_first_node_in_group("game")
	_target_pos = global_position
	if is_local:
		body_visual.visible = false
		body_hands.set_active(false)   # HANDS HOOK: nobody sees it (until the carry camera shows it)
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
	# HANDS HOOK: the hands (and the stack on the palm) are placed every frame with this scale.
	if hands != null and "fov_k" in hands:
		hands.fov_k = k


func _make_body() -> Node3D:
	var root := Node3D.new()
	root.name = "Body"
	# HUMAN HOOK: a Blender surgeon (variation by peer id, scrubs tinted to the player's colour); Kenney below.
	var human: Node3D = HumanModel.spawn(HumanModel.surgeon_for(peer_id), colour)
	if human != null:
		root.add_child(human)
		return root
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


# =========================================================================
# input and movement
# =========================================================================

func _input(event: InputEvent) -> void:
	if not is_local or not alive:
		return
	if hive_view:
		return   # SWEEP 3 HOOK (brains): the mouse is not yours while you look through a Walk-In
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Settings hook: "sensitivity" multiplies the base look speed.
		var sens: float = MOUSE_SENS * float(Settings.get_value("sensitivity"))
		_yaw -= event.relative.x * sens
		# Downed hook: flat on the player table you can look straight up at the ceiling.
		var lim := 1.55 if on_table else 1.3
		_pitch = clampf(_pitch - event.relative.y * sens, -lim, lim)


func _physics_process(delta: float) -> void:
	# Downed hook: carried or on the table, the body goes where the carrier or the table puts it.
	if carried_by != 0 or on_table:
		_pinned_step(delta)
	# DEV HOOK: the host drives dev room bots as if they were its own players.
	elif is_local or (is_bot and game != null and game.is_host()):
		_local_step(delta)
	else:
		_remote_step(delta)
	stun = maxf(0.0, stun - delta)
	invuln = maxf(0.0, invuln - delta)
	if game != null and game.is_host():
		_fix_links()
	if not alive:
		dead_time += delta
	# Downed hook: every machine runs the bleed clock (the host's is the truth, see apply_remote_full).
	if downed and alive and game != null:
		bleed = maxf(0.0, bleed - delta * float(game.bleed_rate(self)))
	downed_aim.collision_layer = C.L_INTERACT if downed and alive and carried_by == 0 and not on_table else 0


func _local_step(delta: float) -> void:
	var g: Node = game
	# The mouse is only free while a menu, the terminal or the surgery view has it,
	# and then the surgeon stands still.
	var can_move: bool = alive and (g == null or not g.paused) and stun <= 0.0 \
		and (bot_active or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

	var input_dir := Vector2.ZERO
	var want_sprint := false
	var crouch_pressed := false
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
			# SPRINT-DIVE HOOK: no interacting while diving, same as the human E-press gates below.
			if not diving:
				interact_count += 1
		# SWEEP 3 HOOK: scripted item use and brain ability. HANDS HOOK: a use winds up first.
		# SPRINT-DIVE HOOK: no using/shoving/ability-firing while diving, same as the human paths.
		if bot_use != _bot_use_seen:
			_bot_use_seen = bot_use
			if not diving and g != null and g.combat != null and g.combat.is_usable(selected_stack().kind):
				g.combat.local_try_use(self)
		# HANDS HOOK: bot_charge true holds the shove, false lets it go.
		if bot_charge != _bot_charging and g != null and g.combat != null:
			_bot_charging = bot_charge
			if bot_charge and not diving:
				g.combat.local_shove_begin(self)
			else:
				g.combat.local_shove_release(self)
		if bot_ability != _bot_ability_seen:
			_bot_ability_seen = bot_ability
			if not diving:
				var bi: int = clampi(bot_ability_slot, 0, ability_slot_press.size() - 1)
				ability_slot_press[bi] = int(ability_slot_press[bi]) + 1
		var bot_stance: int = PRONE if bot_prone else (CROUCH if bot_crouch else STAND)
		if bot_stance != _bot_stance_prev:
			_bot_stance_prev = bot_stance
			_stance_want = bot_stance
		if bot_crouch_press != _bot_crouch_press_seen:
			_bot_crouch_press_seen = bot_crouch_press
			crouch_pressed = true
		scan_holding = bot_scan and not hive_view and not downed and not diving
		if bot_laser_click != _bot_laser_click_seen:
			_bot_laser_click_seen = bot_laser_click
			if scan_holding:
				laser_clicks += 1
		if bot_jump != _bot_jump_seen:
			_bot_jump_seen = bot_jump
			_bot_jump_fire = true
		# SPRINT-DIVE HOOK: same edge-triggered bump pattern as bot_jump just above.
		if bot_dive != _bot_dive_seen:
			_bot_dive_seen = bot_dive
			_bot_dive_fire = true
	elif can_move:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		wants_interact = Input.is_action_pressed("interact")
		if String(Settings.get_value("sprint_mode")) == "hold":
			want_sprint = Input.is_action_pressed("sprint")
		else:
			if Input.is_action_just_pressed("sprint"):
				_sprint_toggle = not _sprint_toggle
			# Letting go of every movement key ends a toggled sprint, like most shooters.
			if input_dir.length() < 0.1:
				_sprint_toggle = false
			want_sprint = _sprint_toggle
		# Starting a sprint from a crouch or prone gets you up (once there's room).
		if Input.is_action_just_pressed("sprint") and want_sprint and not diving:
			_stance_want = STAND
		crouch_pressed = Input.is_action_just_pressed("crouch")
		scan_holding = Input.is_action_pressed("scan") and not hive_view and not downed and not diving
	else:
		wants_interact = false
		scan_holding = false
	# SWEEP 3 HOOK (brains): Hive Eyes freezes the body; E or R asks to come back.
	if hive_view != _was_hive:
		_was_hive = hive_view
		if hive_view:
			_hive_pitch = _pitch
		else:
			_pitch = _hive_pitch
	if hive_view:
		input_dir = Vector2.ZERO
		want_sprint = false
		wants_interact = false
		_pitch = move_toward(_pitch, -0.95, delta * 2.5)
		if can_move and not bot_active and Input.is_action_just_pressed("interact") and game != null and game.brains != null:
			var hi: int = game.brains.slot_of(peer_id, "hive_in")
			if hi >= 0:
				ability_slot_press[hi] = int(ability_slot_press[hi]) + 1

	_update_aim()
	_update_scan_progress(delta)
	if can_move and not bot_active and not hive_view and not diving and Input.is_action_just_pressed("interact") \
			and aim_id != "" and aim_hold <= 0.0 and not aim_prompt.begins_with("!"):
		interact_count += 1
	# Downed hook: downed, E calls for help; carrying, E puts them down (or on the table, above).
	elif can_move and not bot_active and not diving and Input.is_action_just_pressed("interact") and (downed or carrying != 0 or dragging_monster >= 0):
		interact_count += 1

	rotation.y = _yaw
	head.rotation.x = _pitch

	# SWEEP 4A HOOK (fog lot, chunk 2): the lot's fog ring bends heading back and fades vision
	# and sound with depth. Every machine computes the same steering from the static level
	# geometry for whichever player it is actually driving here (client-owned movement, same as
	# everything else in this function); a carried player needs nothing extra, since their body
	# just follows whoever carries them, and that player is doing their own steering.
	if g != null and FogRingScript.on_lot(global_position, g.level_info):
		_yaw = FogRingScript.steer_yaw(global_position, _yaw, g.level_info, delta)
		rotation.y = _yaw
		var fog01 := FogRingScript.visibility01(FogRingScript.depth_m(global_position, g.level_info))
		if is_local:
			if fx != null:
				(fx as CameraFX).set_fog(fog01)
			Audio.set_fog_muffle(fog01)
			_set_flashlight_fog_dampen(fog01)
	elif is_local and fx != null:
		(fx as CameraFX).set_fog(0.0)
		Audio.set_fog_muffle(0.0)
		_set_flashlight_fog_dampen(0.0)

	# DEV HOOK (scripts/dev): noclip flies through walls; nothing below applies.
	if noclip and g != null and g.dev != null:
		g.dev.noclip_move(self, input_dir, want_sprint, delta)
		if g.is_host():
			_consume_actions()
		return

	moving = input_dir.length() > 0.1 and not operating
	# HANDS HOOK: winding up or charging walks (no sprint) and keeps the slot.
	var winding: bool = g != null and g.combat != null and g.combat.is_winding(self)
	var dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	# The crouch key: mid-sprint (or within the grace window just after) it dives, landing prone;
	# otherwise it steps stand -> crouch -> prone -> stand. `sprinting`/`crouching` here are still
	# last frame's (both are reassigned further down), i.e. the state the key was pressed in.
	var dive_fire: bool = crouch_pressed or _bot_dive_fire
	_bot_dive_fire = false
	_sprint_grace = DIVE_SPRINT_GRACE if sprinting else maxf(0.0, _sprint_grace - delta)
	var dive_hop := false
	# No cooldown timer: each dive costs DIVE_STAMINA_COST instead, so chaining them runs out of
	# breath rather than turning into a permanent speed boost.
	if dive_fire and (sprinting or _sprint_grace > 0.0) and not crouching and not diving and is_on_floor() \
			and stamina >= DIVE_STAMINA_COST and not downed and not winding and input_dir.y < -0.5:
		diving = true
		_dive_t = 0.0
		_dive_airborne = true
		_dive_dir = dir
		_sprint_grace = 0.0
		_sprint_toggle = false
		_stance_want = PRONE
		stamina -= DIVE_STAMINA_COST
		dive_hop = true
		_dive_launch_y = global_position.y
		_dive_peak_y = global_position.y
		# Instant burst, not a ramp-up: the acceleration-chase below would otherwise take several
		# frames to catch up to sprint*MULT, which reads as a slow speed-up rather than a lunge.
		velocity.x = dir.x * C.SPRINT_SPEED * DIVE_SPEED_MULT
		velocity.z = dir.z * C.SPRINT_SPEED * DIVE_SPEED_MULT
	elif crouch_pressed and not diving and not downed:
		var cur: int = PRONE if prone else (CROUCH if crouching else STAND)
		_stance_want = (cur + 1) % 3
		if _stance_want != STAND:
			_sprint_toggle = false
	if diving:
		# Airborne: full launch speed, no decay. The slide-out clock only starts on touchdown.
		if _dive_airborne:
			if is_on_floor() and velocity.y <= 0.0 and not dive_hop:
				_dive_airborne = false
		else:
			_dive_t += delta
			if _dive_t >= DIVE_DURATION:
				diving = false

	# SWEEP 4A HOOK (controls): crouch is client-owned. Standing back up is refused under a low
	# ceiling (a raycast from the crouched head to the standing head height); until there is room
	# the player stays crouched even if the key is let go. SPRINT-DIVE HOOK: _apply_crouch also
	# forces the capsule down for `diving`, through this same resize/ceiling-safe path, so a dive
	# that ends under a low ceiling correctly stays crouched instead of popping the capsule back up.
	_apply_crouch(delta)
	sprinting = moving and can_move and want_sprint and stamina > 0.0 and not downed and not crouching and carrying == 0 and dragging_monster < 0 and not winding and not diving
	stamina = clampf(stamina + (-delta / 4.5 if sprinting else (0.0 if diving else delta / 5.0)), 0.0, 1.0)

	var speed: float = 0.0 if operating else (C.SPRINT_SPEED if sprinting else C.WALK_SPEED)
	# Downed hook: crawling is slow; a teammate over your shoulder slows you down.
	if downed:
		speed = CRAWL_SPEED
	elif diving:
		# SPRINT-DIVE HOOK: an instant burst beyond sprint speed that decays back down to crouch
		# speed over DIVE_DURATION, so the dive reads as a lunge-then-slide rather than a teleport.
		var dive_k: float = 1.0 if _dive_airborne else 1.0 - clampf(_dive_t / DIVE_DURATION, 0.0, 1.0)
		speed = lerpf(C.PRONE_SPEED, C.SPRINT_SPEED * DIVE_SPEED_MULT, dive_k)
	elif prone:
		speed = C.PRONE_SPEED
	elif crouching:
		speed = C.CROUCH_SPEED   # SWEEP 4A HOOK (controls): crouching is slow, on top of everything else
	elif carrying != 0:
		speed *= CARRY_SPEED_K
	elif dragging_monster >= 0:
		speed *= CombatScript.DRAG_SPEED_K   # SWEEP 3 HOOK (combat): dragging a sedated monster
	# SPRINT-DIVE HOOK: the lunge keeps its launch heading fixed instead of following live steering,
	# so mid-air/mid-slide mouse turns don't let it curve like a normal walk.
	var target := (_dive_dir if diving else dir) * speed + _knock
	var a: float = ACCEL if is_on_floor() else AIR_ACCEL
	velocity.x = move_toward(velocity.x, target.x, a * delta * maxf(1.0, _knock.length()))
	velocity.z = move_toward(velocity.z, target.z, a * delta * maxf(1.0, _knock.length()))
	# SWEEP 4A HOOK (controls): a small grounded jump. Nothing floaty: gravity below still applies.
	var want_jump: bool = is_on_floor() and not downed and not crouching and carrying == 0 and dragging_monster < 0 and not winding \
			and ((can_move and not bot_active and Input.is_action_just_pressed("jump")) or (bot_active and _bot_jump_fire))
	_bot_jump_fire = false
	if not is_on_floor():
		velocity.y -= (DIVE_GRAVITY if diving and _dive_airborne else 18.0) * delta
	else:
		velocity.y = minf(velocity.y, 0.0) + _knock.y
	if want_jump:
		velocity.y = C.JUMP_VELOCITY
	# After the grounded clamp above, or it would zero the launch on the frame the dive fires.
	if dive_hop:
		velocity.y = DIVE_HOP_VELOCITY
	_knock = _knock.lerp(Vector3.ZERO, clampf(delta * 6.0, 0.0, 1.0))

	var was_air := not is_on_floor()
	var fall_speed := velocity.y
	move_and_slide()
	if diving and _dive_airborne:
		_dive_peak_y = maxf(_dive_peak_y, global_position.y)
	if diving and _dive_airborne and was_air and is_on_floor():
		# Touchdown: hit the floor prone, with a thud.
		_dive_airborne = false
		if fx.has_method("land"):
			fx.land(DIVE_LAND_THUD)
		if fx.has_method("add_shake"):
			fx.add_shake(DIVE_LAND_SHAKE, 0.35)
		Audio.play("thud", global_position, -6.0, 0.1)
	elif was_air and is_on_floor() and fall_speed < -4.0 and fx.has_method("land"):
		fx.land(clampf(-fall_speed / 14.0, 0.0, 1.0))

	if can_move and not bot_active and not hive_view:   # SWEEP 3 HOOK (brains): helpless in Hive Eyes
		if Input.is_action_just_pressed("flashlight"):
			set_flashlight(not flashlight_on)
			Audio.play("click")
		# DEV HOOK: with the dev gun out, the left mouse button fires instead of shoving.
		var gun_out: bool = g != null and g.dev_mode and g.dev.has_gun(peer_id) and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		# HANDS HOOK: the shove charges while Q (or left mouse with nothing usable) is held and fires on
		# release; left mouse with the saw or the needle winds that up (scripts/combat/windup.gd). The
		# combat system refuses while downed, carrying, dragging, busy or cooling down.
		if g != null and g.combat != null:
			# SPRINT-DIVE HOOK: no shoving/using mid-dive, same pattern as the other transient
			# states (downed/dragging/winding) already gate these two actions below.
			# Terminal redesign: while the scan laser is out, left mouse clicks with it; no shoving.
			if scan_holding and Input.is_action_just_pressed("use"):
				laser_clicks += 1
			if Input.is_action_just_pressed("shove") and not gun_out and _charging_with == "" and not diving and not scan_holding:
				if g.combat.local_shove_begin(self):
					_charging_with = "shove"
			# SWEEP 3 HOOK: left mouse uses the held item when it has a use (saw, anesthetic), else it
			# shoves like Q.
			if Input.is_action_just_pressed("use") and not gun_out and not downed and carrying == 0 and dragging_monster < 0 and not diving and not scan_holding:
				if g.combat.is_usable(selected_stack().kind):
					g.combat.local_try_use(self)
				elif _charging_with == "" and g.combat.local_shove_begin(self):
					_charging_with = "use"
			if _charging_with != "" and not Input.is_action_pressed(_charging_with):
				_charging_with = ""
				g.combat.local_shove_release(self)
		# SWEEP 4A HOOK (pharmacy, chunk 3): hold the drop key to charge a throw, release to fire
		# it; a quick tap still reports ~0 charge, the old gentle drop. Client-owned charge timer.
		# SPRINT-DIVE HOOK: no starting a drop charge mid-dive either.
		if Input.is_action_just_pressed("drop") and selected_stack().kind != "" and dragging_monster < 0 and not winding and not diving:
			_drop_holding = true
			_drop_hold_t = 0.0
		if _drop_holding:
			_drop_hold_t += delta
			if not Input.is_action_pressed("drop"):
				_drop_holding = false
				var held: float = _drop_hold_t
				drop_charge = 0.0 if held <= DROP_TAP_MAX else clampf((held - DROP_TAP_MAX) / (DROP_CHARGE_FULL - DROP_TAP_MAX), 0.0, 1.0)
				drop_count += 1
		# SWEEP 4A HOOK (controls): Alt+1..4 fires an ability slot; plain 1..4 still picks an item
		# slot. Holding Alt does not block movement or anything else.
		# SPRINT-DIVE HOOK: no ability use mid-dive; switching the selected item slot is still fine.
		var alt_down: bool = Input.is_action_pressed("ability_alt")
		if alt_down and not diving:
			for i in ability_slot_press.size():
				if Input.is_action_just_pressed("slot_%d" % (i + 1)):
					ability_slot_press[i] = int(ability_slot_press[i]) + 1
		elif dragging_monster < 0 and not winding:   # SWEEP 3 HOOK (combat): no slot changes while dragging (HANDS: or winding up)
			for i in C.CARRY_CAP:
				if Input.is_action_just_pressed("slot_%d" % (i + 1)):
					selected = i
			if Input.is_action_just_pressed("slot_next"):
				select_step(1)
			if Input.is_action_just_pressed("slot_prev"):
				select_step(-1)

	# HANDS HOOK: the mouse was freed (a menu, the terminal) mid-charge: the shove goes off.
	if _charging_with != "" and not (can_move and not hive_view) and g != null and g.combat != null:
		_charging_with = ""
		g.combat.local_shove_release(self)

	# Footsteps (a crawl makes none). SWEEP 4A HOOK (controls): crouching makes no sound at all,
	# on top of emit_noise() never firing for a crouching player (game.gd's _tick_noise).
	if moving and is_on_floor() and not downed and not crouching:
		_step_accum += delta * (3.0 if sprinting else 1.9)
		if _step_accum >= 1.0:
			_step_accum = 0.0
			Audio.play("step", global_position, -4.0, 0.12)

	if fx.has_method("set_motion"):
		fx.set_motion(clampf(Vector2(velocity.x, velocity.z).length() / C.SPRINT_SPEED, 0.0, 1.0), sprinting, is_on_floor())
	if fx.has_method("set_fov_kick"):
		fx.set_fov_kick(0.5 if sprinting or (diving and _dive_airborne) else 0.0)
	if fx.has_method("set_breathing") and game != null:
		fx.set_breathing(game.danger)

	# Solo has no host to talk to, so apply our own one-shot actions directly.
	if game != null and game.is_host():
		_consume_actions()


## SWEEP 4A HOOK (controls): resize the collision capsule for crouch. `authoritative` (local /
## host-simulated bots) decides `crouching` itself, including the "can't stand under a low
## ceiling" refusal; a remote copy just follows the replicated bit and only resizes visually.
func _apply_crouch(delta: float, authoritative: bool = true) -> void:
	if authoritative:
		var want: int = (STAND if _dive_airborne else PRONE) if diving else _stance_want
		if downed or carried_by != 0 or on_table:
			want = STAND
			_stance_want = STAND
		# Rising needs headroom: go as high as fits, up to what's wanted. The rest of the request
		# stays pending, so the body finishes getting up by itself once the ceiling clears.
		var cur: int = PRONE if prone else (CROUCH if crouching else STAND)
		if want < cur:
			var top: float = _stance_height(cur)
			var got := cur
			for s in range(cur - 1, want - 1, -1):
				if not _headroom(top, _stance_height(s)):
					break
				got = s
			want = got
		crouching = want != STAND
		prone = want == PRONE
	if _capsule != null:
		var target_h: float = C.PRONE_HEIGHT if prone else (C.CROUCH_HEIGHT if crouching else C.PLAYER_HEIGHT)
		_capsule.height = target_h
		_coll_shape.position.y = target_h * 0.5


static func _stance_height(s: int) -> float:
	return C.PRONE_HEIGHT if s == PRONE else (C.CROUCH_HEIGHT if s == CROUCH else C.PLAYER_HEIGHT)


## Nothing solid between the top of the current capsule and `to_h` above the feet.
func _headroom(from_h: float, to_h: float) -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * from_h, global_position + Vector3.UP * to_h)
	q.collision_mask = C.L_WORLD
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## SWEEP 4A HOOK (Echo polish, chunk 4): 0..1 while this player's shriek pose should show, driven
## by game.brains._echo_pose_until (peer -> world_time), a local one-shot timer every machine sets
## the same way from the reliable br_echo event (not a replicated Player field).
func _echo_pose_weight() -> float:
	if game == null or game.brains == null:
		return 0.0
	var until := float(game.brains._echo_pose_until.get(peer_id, -1.0))
	return clampf((until - float(game.world_time)) / 0.5, 0.0, 1.0) if until > 0.0 else 0.0


func _remote_step(delta: float) -> void:
	_apply_crouch(delta, false)
	var k := clampf(delta * 12.0, 0.0, 1.0)
	# POCKETS HOOK: through a seam (or any teleport) the body jumps; never lerp it across the world.
	if global_position.distance_squared_to(_target_pos) > 36.0:
		k = 1.0
	global_position = global_position.lerp(_target_pos, k)
	rotation.y = lerp_angle(rotation.y, _target_yaw, k)
	head.rotation.x = lerpf(head.rotation.x, -0.95 if hive_view else _pitch, k)   # SWEEP 3 HOOK (brains): head droops
	if _hive_glaze != null:
		_hive_glaze.visible = hive_view   # SWEEP 4A HOOK (Hive Eyes, chunk 4): glazed eyes for teammates
	if moving and not downed and not crouching:
		_step_accum += delta * (3.0 if sprinting else 1.9)
		if _step_accum >= 1.0:
			_step_accum = 0.0
			Audio.play("step", global_position, -8.0, 0.12)


## Downed hook: carried or lying on the player table. Every machine puts the body where the carrier
## or the table says (game.pinned_pose); the local player keeps looking around with the mouse and
## E still calls for help.
func _pinned_step(delta: float) -> void:
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO
	moving = false
	sprinting = false
	diving = false   # SPRINT-DIVE HOOK: picked up or tabled mid-dive ends it
	var pose: Transform3D = game.pinned_pose(self) if game != null else global_transform
	global_position = pose.origin
	_target_pos = pose.origin
	var local_driver: bool = is_local or (is_bot and game != null and game.is_host())
	if local_driver:
		if bot_active:
			_yaw = bot_yaw
			_pitch = bot_pitch
			if bot_press != _bot_press_seen:
				_bot_press_seen = bot_press
				interact_count += 1
		elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_action_just_pressed("interact") and (game == null or not game.paused):
			interact_count += 1
		wants_interact = false
		rotation.y = _yaw
		head.rotation.x = _pitch
		_update_aim()
		if game != null and game.is_host():
			_consume_actions()
	else:
		rotation.y = pose.basis.get_euler().y
		head.rotation.x = lerpf(head.rotation.x, _pitch, clampf(delta * 12.0, 0.0, 1.0))


## Host-side: turn the shove/drop counters into actual events, exactly once each.
func _consume_actions() -> void:
	if game == null:
		return
	# Downed hook: a downed player only calls for help; a carrier only puts down or places.
	var busy := downed or carrying != 0 or dragging_monster >= 0 or hive_view   # SWEEP 3 HOOK (combat: dragging; brains: helpless in Hive Eyes)
	# SWEEP 3 HOOK: item use and the brain ability (the systems decide what a busy player may do).
	if use_count != _use_seen:
		_use_seen = use_count
		if alive and not busy:
			game.player_used(self)
	for i in ability_slot_press.size():
		if int(ability_slot_press[i]) != int(_ability_slot_seen[i]):
			_ability_slot_seen[i] = ability_slot_press[i]
			if alive and not downed:
				game.player_ability_slot(self, i)
	if shove_count != _shove_seen:
		_shove_seen = shove_count
		if alive and not busy:
			game.player_shoved(self)
	if drop_count != _drop_seen:
		_drop_seen = drop_count
		if alive and not busy:
			game.drop_selected(self, drop_charge)   # SWEEP 4A HOOK (pharmacy, chunk 3): charged throw
	if interact_count != _interact_seen:
		_interact_seen = interact_count
		if hive_view:
			pass   # SWEEP 3 HOOK (brains)
		elif alive and downed:
			game.downed_call_out(self)
		elif alive and carrying != 0:
			game.carrier_pressed_interact(self, aim_id)
		elif alive and dragging_monster >= 0 and game.combat != null:
			game.combat.dragger_pressed_interact(self, aim_id)   # SWEEP 3 HOOK (combat)
		elif alive:
			game.player_pressed_interact(self, aim_id)


# =========================================================================
# aiming and hands
# =========================================================================

## Find what the camera points at and what it would let this player do.
func _update_aim() -> void:
	_update_aim_core()
	# HANDS HOOK: holding the needle and aiming at a monster in its stun window: "Jab it" (a few Hz).
	if aim_prompt == "" and alive and not downed and game != null and game.combat != null and game.combat.has_method("jab_prompt") \
			and String(selected_stack().kind) == "anesthetic":
		_jab_prompt_t -= get_physics_process_delta_time()
		if _jab_prompt_t <= 0.0:
			_jab_prompt_t = 0.1
			_jab_prompt = game.combat.jab_prompt(self)
		aim_prompt = _jab_prompt
	else:
		_jab_prompt = ""
		_jab_prompt_t = 0.0
	# AFFORDANCE HOOK: only the local player ever sees their own highlight (a bot's aim is a host
	# decision, not something drawn to anyone's screen).
	if is_local:
		_update_aim_highlight()


## AFFORDANCE HOOK: swap the aim-highlight rim (scripts/aim_highlight.gd) onto whatever `aim_id`
## now points at, replacing the old always-on floating labels as the primary "you can interact
## with this" signal (docs/CONTRACTS.md, "Interaction"). Skips anything whose prompt begins with
## "!" (the existing "can't use this right now" convention), same as the crosshair prompt already
## does for its own styling.
func _update_aim_highlight() -> void:
	var want: Node = null
	if aim_id != "" and not aim_prompt.begins_with("!") and game != null:
		var n: Node = game.find_interactable(aim_id)
		if n != null and n.is_in_group("interactable"):
			want = n
	if want == _aim_highlighted:
		return
	if _aim_highlighted != null and is_instance_valid(_aim_highlighted):
		AimHighlight.set_highlighted(_aim_highlighted, false)
	_aim_highlighted = want
	if _aim_highlighted != null:
		AimHighlight.set_highlighted(_aim_highlighted, true)


func _update_aim_core() -> void:
	aim_id = ""
	aim_prompt = ""
	aim_hold = 0.0
	if not alive or hive_view:   # SWEEP 3 HOOK (brains): nothing in reach while you are elsewhere
		return
	# Downed hook: on the floor or the table there is nothing to use, only a call for help.
	if downed:
		aim_prompt = "Call for help"
		return
	var node: Node = null
	if bot_active and bot_aim_id != "" and game != null:
		node = game.find_interactable(bot_aim_id)
	else:
		var from := camera.global_position
		var to := from - camera.global_transform.basis.z * C.INTERACT_RANGE
		if carry_cam != null and carry_cam.active:
			# HANDS HOOK: over the shoulder, the ray runs along the camera's line from beside the head
			# (nothing between the camera and the head counts) and reaches INTERACT_RANGE from the head.
			var seg: Array = carry_cam.aim_segment()
			from = seg[0]
			to = seg[1]
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = C.L_WORLD | C.L_INTERACT | C.L_PICKUP
		q.collide_with_areas = true
		q.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty() and dragging_monster < 0:   # SWEEP 3 HOOK (combat): a dragger always gets a prompt
			return
		node = hit.get("collider")
		while node != null and not node.has_meta("interact_id"):
			node = node.get_parent()
	# SWEEP 3 HOOK (combat): a dragger can only strap the monster to a free patient table, or put it down.
	if dragging_monster >= 0 and game != null and game.combat != null:
		var da: Array = game.combat.drag_aim(self, node)
		aim_id = String(da[0])
		aim_prompt = String(da[1])
		return
	# Downed hook: a carrier can only put someone on the player table, or down anywhere else.
	if carrying != 0:
		var who = game.players.get(carrying) if game != null else null
		var drop_text := "Put %s down" % (who.player_name if who != null else "them")
		# Hub rebuild: on the hub any free patient table ("table", "table_<i>") takes them too.
		var tid := String(node.get_meta("interact_id")) if node != null and node.has_meta("interact_id") else ""
		if tid != "player_table" and not tid.begins_with("table"):
			aim_prompt = drop_text
			return
		var tp: String = node.interact_prompt(self)
		if tp == "" or tp.begins_with("!"):
			aim_prompt = drop_text
			return
	if node == null or not node.has_method("interact_prompt"):
		return
	var prompt: String = node.interact_prompt(self)
	if prompt == "":
		return
	aim_id = String(node.get_meta("interact_id"))
	aim_prompt = prompt
	aim_hold = node.interact_hold()


## SWEEP 4A HOOK (scanner): a purely local, cosmetic progress ring for the HUD. Every machine
## computes its own (same as aim_id/aim_prompt); the host runs the authoritative range/LOS check
## and records the scan separately in game.gd/_tick_scan.
func _update_scan_progress(delta: float) -> void:
	if not scan_holding or camera == null:
		scan_progress = 0.0
		scan_target_id = -1
		return
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * C.SCAN_RANGE
	if carry_cam != null and carry_cam.active:
		# HANDS HOOK: same correction as the aim ray -- over the shoulder, nothing between the
		# camera and the head counts, and the reach is measured from the head.
		var seg: Array = carry_cam.aim_segment(C.SCAN_RANGE)
		from = seg[0]
		to = seg[1]
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = C.L_WORLD | C.L_MONSTER | C.L_SCAN
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var target_id := -1
	if not hit.is_empty():
		var collider = hit.get("collider")
		if collider != null and "monster_id" in collider:
			target_id = int(collider.monster_id)
		elif collider is Node and (collider as Node).get_parent() != null and "scan_id" in (collider as Node).get_parent():
			target_id = int((collider as Node).get_parent().scan_id)   # a scan prop (the waiting Night Nurse)
	if target_id != scan_target_id:
		scan_progress = 0.0
		scan_target_id = target_id
		_scan_beep_accum = 0.0
	if target_id >= 0:
		scan_progress = clampf(scan_progress + delta / C.SCAN_SECONDS, 0.0, 1.0)
		# SWEEP 4A HOOK (scanner): a beep while scanning, faster as progress builds. This is a
		# plain 2D sound (Audio.play), never game.emit_noise(): it is not a noise event, so
		# monsters cannot hear it. is_local only, so it plays on the scanning player's own machine.
		if is_local:
			_scan_beep_accum += delta
			var period: float = lerpf(0.45, 0.12, scan_progress)
			if _scan_beep_accum >= period:
				_scan_beep_accum = 0.0
				Audio.play("beep", null, -6.0, 0.08)
		if scan_progress >= 1.0:
			scan_progress = 0.0
	else:
		scan_progress = 0.0
		_scan_beep_accum = 0.0


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


## Total count of `kind` held across every hand slot (both halves of a bulky stack carry the
## same kind, so this only counts the head; see clear_slot/bulky_pair_for).
func hand_count(kind: String) -> int:
	var n := 0
	for s in slots:
		if String(s.kind) == kind:
			n += int(s.count)
	return n


## Host: takes up to `n` of `kind` out of hand slots (oldest slot index first), clearing any
## slot it empties. Returns how many were actually removed (0 to n).
func consume_hand(kind: String, n: int) -> int:
	var left := n
	for i in slots.size():
		if left <= 0:
			break
		if String(slots[i].kind) != kind:
			continue
		var have := int(slots[i].count)
		var take := mini(have, left)
		if take <= 0:
			continue
		if take >= have:
			clear_slot(i)
		else:
			slots[i]["count"] = have - take
		left -= take
	return n - left


func holding(kind: String) -> bool:
	for s in slots:
		if s.kind == kind:
			return true
	return false


## SWEEP 4A HOOK (pharmacy, chunk 3): a placebo pill just landed on me. Local-only; stacking
## resets the hold and nudges the strength up, capped low.
func add_warm() -> void:
	warm_target = clampf(warm_target + WARM_STEP, WARM_STEP, WARM_CAP)
	warm_hold_left = WARM_HOLD


func _tick_warm(delta: float) -> void:
	if warm_hold_left > 0.0:
		warm_hold_left -= delta
		warm_level = move_toward(warm_level, warm_target, delta / WARM_FADE_IN)
	else:
		warm_target = 0.0
		warm_level = move_toward(warm_level, 0.0, delta / WARM_FADE_OUT)


func _process(_delta: float) -> void:
	if is_local:
		_tick_warm(_delta)
	_update_down_pose(_delta)  # DEV HOOK
	var s: Dictionary = selected_stack()
	var key := "%s:%d" % [s.kind, s.count]
	if key != _held_key:
		_held_key = key
		for holder in [_held_fp, _held_tp]:
			for c in holder.get_children():
				c.queue_free()
			if s.kind != "":
				holder.add_child(_held_model(String(s.kind), int(s.count), holder == _held_fp))
		# The flashlight hand hides nothing; the held stack sits in the other hand.
		_held_fp.visible = is_local
		_held_tp.visible = not is_local
		if is_local:
			hands.held_changed(String(s.kind), int(s.count))   # HANDS HOOK: lower and raise
	# HANDS HOOK: the carry camera, then both hands posed from what is held and the wind-up state.
	if carry_cam != null:
		carry_cam.update(_delta)
		var cm := camera.cull_mask
		var want_mask: int = (cm & ~HandsFP.HANDS_LAYER) if carry_cam.hides_hands() else (cm | HandsFP.HANDS_LAYER)
		if want_mask != cm:
			camera.cull_mask = want_mask
	if is_local and hands.visible:
		hands.update(_delta)
	if body_hands != null:
		body_hands.update(_delta)


## A held stack, tinted, placed by the kind's grip (scripts/hands/grips.gd) so its grip point sits
## in the palm of the holder (HeldFirstPerson / HeldThirdPerson are the palm sockets, placed every
## frame by the hands). Batches show as a small bundle; bulky loot and big loot are scaled down in
## first person so they do not fill the screen. HANDS HOOK.
func _held_model(kind: String, count: int, first_person: bool) -> Node3D:
	var model := ItemModels.make_tinted(kind, Grips.shown_count(kind, count), first_person)
	var k: float = HandsFP.fp_scale(kind) if first_person else _tp_scale(kind)
	model.scale = Vector3.ONE * k
	var pivot := Node3D.new()
	pivot.name = "Held"
	pivot.add_child(model)
	var g := Grips.grip(kind).duplicate()
	g.pos = (g.pos as Vector3) * k
	pivot.transform = Grips.transform_of(g)
	if first_person:
		HandsFP.dress(pivot)
	return pivot


static func _tp_scale(kind: String) -> float:
	if int(Grips.grip(kind).hands) < 2:
		return 1.0
	var fp := ItemModels.footprint(kind)
	return minf(1.0, BodyHandsScript.TP_BOTH_SIZE / maxf(0.01, maxf(fp.x, maxf(fp.y, fp.z))))


func set_flashlight(on: bool) -> void:
	flashlight_on = on
	flashlight.visible = on


## SWEEP 4A FOLLOW-UP (fog lot): "the flashlight shouldn't permeate the fog" -- cranking the
## screen-space/volumetric fog density alone still let a bright close-range light carve a visible
## beam and light up whatever it hit (the whole point of a spotlight). Cut the flashlight's own
## range and energy directly as fog01 rises, local-only (every other machine still sees this
## player's flashlight at full strength -- from their own body it's just as swallowed by the fog
## in front of them, not literally dimmer). Reaches zero well before full blindness (BLIND_M)
## so there is no beam left by the time nothing should be visible at all.
const FLASHLIGHT_BASE_ENERGY := 4.5
var _flashlight_fog01 := -1.0


func _set_flashlight_fog_dampen(fog01: float) -> void:
	if flashlight == null or is_equal_approx(_flashlight_fog01, fog01):
		return
	_flashlight_fog01 = fog01
	var k := clampf(1.0 - fog01 / 0.6, 0.0, 1.0)   # fully gone by 60% of the way to blind
	flashlight.spot_range = C.CONE_RANGE * k
	flashlight.light_energy = FLASHLIGHT_BASE_ENERGY * k
	flashlight.light_volumetric_fog_energy = 2.8 * k


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
	dragging_monster = -1   # SWEEP 3 HOOK (combat)
	hive_view = false   # SWEEP 3 HOOK (brains)
	crouching = false   # SWEEP 4A HOOK (controls)
	prone = false
	_stance_want = STAND
	scan_holding = false
	diving = false   # SPRINT-DIVE HOOK
	_dive_airborne = false
	_sprint_toggle = false
	_sprint_grace = 0.0
	_clear_downed()
	_set_visible_alive(true)


func revive(with_hp: int) -> void:
	hp = with_hp
	alive = true
	dead_time = 0.0
	invuln = 3.0
	_clear_downed()
	_set_visible_alive(true)


var _downed_seen := false


## Downed hook: laid on the player table you look up at the ceiling, feet (and the surgeon) ahead.
func look_up_from_table() -> void:
	var yaw := float(game.player_table_yaw()) - PI * 0.5 if game != null else rotation.y
	_yaw = yaw
	_pitch = 1.15
	bot_yaw = yaw
	bot_pitch = 1.15
	rotation.y = yaw
	head.rotation.x = _pitch


## Downed hook: back on your feet, nobody carrying anybody, off the table.
func _clear_downed() -> void:
	downed = false
	bleed = 0.0
	carried_by = 0
	carrying = 0
	on_table = false
	carry_hold = 0.0


## Host: the hit lands. At 0 HP the game downs the player (game.damage_player); nobody dies of a hit.
func take_hit(dmg: int, knock: Vector3) -> void:
	hp = maxi(0, hp - dmg)
	invuln = 3.0
	apply_knock(knock)
	flinch()


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
	# Downed hook: a downed body is walked over, not bumped into (teammates aim at DownedAim).
	collision_layer = C.L_PLAYER if a and not downed else 0


## Downed hook: set every visual that follows from downed / carried / on_table. Idempotent.
func refresh_downed_visuals() -> void:
	_set_visible_alive(alive)
	if on_table and not is_local:
		body_visual.visible = false   # the lying PlayerBody on the table stands in
		name_tag.visible = false
	if is_local:
		hands.visible = alive and not downed and (game == null or not game.dev_mode or not game.dev.has_gun(peer_id))


## Knocked down (dev stun) or downed you see the floor; everyone else sees you lying on it. Carried,
## you hang over the carrier's shoulder. Dead bots lie there too.
func _update_down_pose(delta: float) -> void:
	# Prone lies and crawls with the same body pose as being downed.
	var down := stun > 0.0 or downed or (is_bot and not alive) or prone
	# SWEEP 4A HOOK (controls): the third-person crouch pose (body_poser.gd): a torso lean blended
	# in independently of the hold/carry/wind-up targets body_hands sets every frame.
	if body_hands != null and "poser" in body_hands and body_hands.poser != null:
		var want_crouch_w: float = 1.0 if (crouching and not down) else 0.0
		body_hands.poser.crouch = move_toward(float(body_hands.poser.crouch), want_crouch_w, delta * 6.0)
	if is_local and not is_bot:
		var eye := C.EYE_H
		if on_table:
			eye = 0.28
		elif carried_by != 0:
			eye = 0.3
		elif diving and _dive_airborne:
			# Rising: stay at full height. Falling: sink toward prone eye height in step with the fall.
			var fall01 := 0.0
			if velocity.y < 0.0:
				fall01 = clampf((_dive_peak_y - global_position.y) / maxf(_dive_peak_y - _dive_launch_y, 0.05), 0.0, 1.0)
			eye = lerpf(C.EYE_H, C.PRONE_EYE_H, fall01)
		elif prone:
			eye = C.PRONE_EYE_H
		elif down and alive:
			eye = 0.45
		elif crouching:   # SWEEP 4A HOOK (controls)
			eye = C.CROUCH_EYE_H
		if not is_equal_approx(head.position.y, eye):
			# Hitting the floor out of a dive drops the view fast; everything else eases.
			var eye_rate := 14.0 if diving else 6.0
			head.position.y = eye if carried_by != 0 or on_table else move_toward(head.position.y, eye, delta * eye_rate)
		# Carried, your view hangs back over the carrier's shoulder instead of inside their head.
		var back := 1.0 if carried_by != 0 else 0.0
		if not is_equal_approx(head.position.z, back):
			head.position.z = back
		return
	if body_hands != null and body_hands.lies_by_clip():
		# HUMAN HOOK: the human lies, crawls and hangs over the shoulder by its own clips; the Carried
		# clip's origin (the belly on the shoulder) goes onto the carrier's right shoulder.
		body_visual.rotation = Vector3(-0.2 if hive_view else 0.0, 0.0, 0.0)
		body_visual.position = Vector3.ZERO
		var carrier = game.players.get(carried_by) if carried_by != 0 and game != null else null
		if carrier != null and is_instance_valid(carrier):
			# on the carrier's right shoulder, facing where the carrier faces, whatever this body's own yaw
			var cb := Basis(Vector3.UP, carrier.rotation.y)
			body_visual.global_transform = Transform3D(cb, carrier.global_position + cb * HUMAN_CARRIED_SHOULDER)
		return
	if carried_by != 0:
		# A fireman's carry over the right shoulder (game.pinned_pose puts the root there): legs
		# down the front, the rest of the body down the carrier's back.
		body_visual.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		body_visual.position = Vector3(0.0, 0.0, -0.6)
		return
	if not is_zero_approx(body_visual.position.z):
		body_visual.rotation = Vector3.ZERO
		body_visual.position = Vector3.ZERO
	# SWEEP 4A HOOK (Echo polish, chunk 4): a brief lean-back as the shriek goes out, so it visibly
	# comes from whoever used it (docs/SWEEP4A.md "Echo"), on every machine's copy of that player.
	var echo_tilt := -0.4 * _echo_pose_weight()
	var tilt := -PI * 0.47 if down else (-0.2 if hive_view else echo_tilt)   # SWEEP 3 HOOK (brains): slumped in Hive Eyes
	if not is_equal_approx(body_visual.rotation.x, tilt):
		body_visual.rotation.x = move_toward(body_visual.rotation.x, tilt, delta * 6.0)
		body_visual.position.y = 0.3 * (body_visual.rotation.x / (-PI * 0.47))


# =========================================================================
# networking
# =========================================================================

## Client -> host, 20 Hz: everything about my own surgeon. A positional array rather than a
## dictionary: no key strings on the wire, about a third of the size.
##   [position, yaw, pitch, flag bits (1 light, 2 sprint, 4 moving, 8 holding E, 16 crouching,
##    32 scan-holding, 64 prone), shove count, drop count, aim id, interact count, selected hand, use count,
##    ability slot 1..4 press counts]
func report_state() -> Array:
	var bits := (1 if flashlight_on else 0) | (2 if sprinting else 0) | (4 if moving else 0) | (8 if wants_interact else 0) \
		| (16 if crouching else 0) | (32 if scan_holding else 0) | (64 if prone else 0)
	return [global_position, rotation.y, head.rotation.x, bits, shove_count, drop_count, aim_id, interact_count, selected, use_count,
		ability_slot_press[0], ability_slot_press[1], ability_slot_press[2], ability_slot_press[3],
		snappedf(drop_charge, 0.02)]   # SWEEP 4A HOOK (pharmacy, chunk 3)


func apply_remote_state(s: Array) -> void:
	if s.size() < 9:
		return
	var bits := int(s[3])
	if alive and carried_by == 0 and not on_table:   # downed hook: pinned bodies follow the host
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
	crouching = bits & 16 != 0   # SWEEP 4A HOOK (controls): the host trusts the client's own crouch
	scan_holding = bits & 32 != 0
	prone = bits & 64 != 0
	shove_count = int(s[4])
	drop_count = int(s[5])
	aim_id = String(s[6])
	selected = clampi(int(s[8]), 0, slots.size() - 1)
	# Drop before interacting so a count that moved in the same tick uses the right hand.
	interact_count = int(s[7])
	if s.size() >= 11:   # sweep 3
		use_count = int(s[9])
	if s.size() >= 14:   # sweep 4a: ability slots
		for i in 4:
			ability_slot_press[i] = int(s[10 + i])
	if s.size() >= 15:   # SWEEP 4A HOOK (pharmacy, chunk 3): charged throw
		drop_charge = float(s[14])
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
		# downed hook
		"dn": downed, "bl": snappedf(bleed, 1.0), "cb": carried_by, "ca": carrying, "ot": on_table,
		"ch": snappedf(carry_hold, 0.1),
		"dm": dragging_monster,   # SWEEP 3 HOOK (combat)
		"hv": hive_view,   # SWEEP 3 HOOK (brains)
		"cr": crouching,   # SWEEP 4A HOOK (controls)
		"pr": prone,
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
	# Downed hook: the host's downed state. The bleed clock runs locally between corrections.
	var was := [downed, carried_by, carrying, on_table, alive]
	downed = bool(s.get("dn", false))
	carried_by = int(s.get("cb", 0))
	carrying = int(s.get("ca", 0))
	on_table = bool(s.get("ot", false))
	carry_hold = float(s.get("ch", 0.0))
	dragging_monster = int(s.get("dm", -1))   # SWEEP 3 HOOK (combat)
	hive_view = bool(s.get("hv", false))   # SWEEP 3 HOOK (brains)
	var host_bleed := float(s.get("bl", 0.0))
	if not downed or absf(host_bleed - bleed) > 1.5:
		bleed = host_bleed
	if was != [downed, carried_by, carrying, on_table, alive] or not _downed_seen:
		_downed_seen = true
		if on_table and not bool(was[3]) and is_local:
			look_up_from_table()
		refresh_downed_visuals()
	operating = s.op
	if is_local:
		return
	_target_pos = s.p
	_target_yaw = s.y
	_pitch = s.pi
	set_flashlight(s.fl)
	sprinting = s.sp
	crouching = bool(s.get("cr", false))   # SWEEP 4A HOOK (controls)
	prone = bool(s.get("pr", false))
	moving = s.mv
