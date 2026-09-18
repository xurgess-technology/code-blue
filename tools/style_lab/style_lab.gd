extends Node3D
## Style lab: the stylized surgeon (art/stylized, assets/models/characters/human) in the real game look — the
## monster lab's corridor, the game's environment and post layer, a player's flashlight — worn by real
## Player nodes, so the game's own body code drives it (HumanModel dressing and tint, body_hands clips,
## the throw wind-up). For side-by-sides the lab repoints the Assets scene cache and the HumanModel mask
## cache between the stylized model and the old surgeon_a, for this run only.
##
##   godot --path . --resolution 1280x720 tools/style_lab/style_lab.tscn [-- --only=lit_3m,face_1m]
## Shots land in tools/style_lab/shots/.

const HB := preload("res://scripts/hospital_builder.gd")
const PlayerScript := preload("res://scripts/player.gd")
const HumanModel := preload("res://scripts/human/human_model.gd")
const SHOT_DIR := "res://tools/style_lab/shots"
const NEW_GLB := "res://assets/models/characters/human/surgeon_st.glb"
const NEW_TEX := "res://assets/models/characters/human/textures/surgeon_st_%s_mask.png"
const VARIANTS := ["surgeon_a", "surgeon_b", "surgeon_c"]


class LabGame extends Node3D:
	var players: Dictionary = {}
	var level_info: Dictionary = {}
	var world_time := 0.0
	var noises: Array = []
	var combat: Node = null   # set to a LabCombat for the shots that pose a wind-up

	func _ready() -> void:
		add_to_group("game")

	func _physics_process(delta: float) -> void:
		world_time += delta

	func is_host() -> bool:
		return true

	func alive_players() -> Array:
		return players.values().filter(func(p): return p.alive)

	func viewed_player() -> Node:
		var a := alive_players()
		return a[0] if not a.is_empty() else null

	func emit_noise(pos: Vector3, loudness: float, kind: String) -> void:
		noises.append({"pos": pos, "loudness": loudness, "kind": kind, "time": world_time})

	func recent_noises(_max_age: float = 1.5) -> Array:
		return []

	func say(_text: String, _seconds: float = 3.0) -> void:
		pass


## Stand-in for game.combat: every player is in the wind-up in `act` (combat.action_of's shape).
class LabCombat extends Node:
	var act := {}

	func action_of(_p: Node) -> Dictionary:
		return act

	func animate_held(_p: Node, _delta: float, _fp: Node3D, _tp: Node3D) -> void:
		pass


var game: LabGame
var level: Node3D
var watcher: Node
var bulbs: Array = []
var only := ""
var subjects: Array = []
var _old_scenes := {}
var _old_masks := {}
var _new_scene: PackedScene
var _new_masks := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.split("=")[1]
	_prepare_models()
	game = LabGame.new()
	game.name = "LabGame"
	add_child(game)
	_build_level()
	add_child(Look.make_environment())
	add_child(Look.make_post_layer())
	watcher = PlayerScript.new_player(99, "Watcher", false)
	game.add_child(watcher)
	watcher.body_visual.visible = false
	watcher.name_tag.visible = false
	for i in 4:
		await get_tree().physics_frame
	await _run_shots()


# -------------------------------------------------------------------- which surgeon model is live
## Every surgeon key a player can wear shows the stylized model; use_new(false) shows the old
## realistic surgeon_a instead, for side-by-side shots.
func _prepare_models() -> void:
	_new_scene = load(NEW_GLB) as PackedScene
	for which in ["Cloth", "Skin"]:
		var p := NEW_TEX % which
		_new_masks[which] = load(p) if ResourceLoader.exists(p) else null
	_old_scenes["old"] = Assets.model(HumanModel.KEYS["surgeon_a"])
	for which in ["Cloth", "Skin"]:
		var mp := "%s/textures/surgeon_a_%s_mask.png" % [HumanModel.DIR, which]
		_old_masks[which] = load(mp) if ResourceLoader.exists(mp) else null
	print("[style_lab] new model: ", _new_scene != null, "  masks: ", _new_masks.keys().filter(func(k): return _new_masks[k] != null))


## Point the surgeon keys at the stylized model (true) or at the old surgeon_a (false).
func use_new(on: bool) -> void:
	for v in HumanModel.SURGEONS + VARIANTS:
		Assets._scene_cache[HumanModel.KEYS[v]] = _new_scene if on else _old_scenes["old"]
		for which in ["Cloth", "Skin"]:
			var mp := "%s/textures/%s_%s_mask.png" % [HumanModel.DIR, v, which]
			HumanModel._tex[mp] = _new_masks[which] if on else _old_masks[which]
		HumanModel._skin_shared.erase(v)


# -------------------------------------------------------------------- level (the monster lab's corridor)
func _build_level() -> void:
	var w := 50
	var h := 11
	var rows := PackedStringArray()
	for y in h:
		var s := ""
		for x in w:
			var c := "#"
			var border := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if not border:
				if x == 43:
					c = "+" if y == 5 else "#"
				elif x > 43:
					c = "." if y >= 3 and y <= 8 else "#"
				elif y >= 1 and y <= 3:
					c = "#" if x % 11 == 0 else "."
				elif y == 4:
					c = "+" if x in [5, 16, 27, 38] else "#"
				elif y == 5 or y == 6:
					c = "."
				elif y == 7:
					c = "+" if x in [10, 32] else "#"
				elif y == 8 or y == 9:
					c = "#" if x == 22 else "."
			s += c
		rows.append(s)
	var lights := [Vector2i(4, 5), Vector2i(14, 6), Vector2i(24, 5), Vector2i(36, 6), Vector2i(46, 5)]
	var info := {}
	level = HB.build({"rows": rows, "seed": 7, "lights": lights}, info)
	add_child(level)
	game.level_info = info
	for l in info.get("lights", []):
		bulbs.append(l.node.get_node("Bulb"))
	set_all_lights(false)


func set_light(i: int, on: bool) -> void:
	var b: OmniLight3D = bulbs[i]
	b.light_energy = HB.LIGHT_ENERGY if on else 0.0
	b.visible = on
	var panel = b.get_meta("panel") if b.has_meta("panel") else null
	if panel is MeshInstance3D and panel.material_override is StandardMaterial3D:
		(panel.material_override as StandardMaterial3D).emission_energy_multiplier = 2.4 if on else 0.0


func set_all_lights(on: bool) -> void:
	for i in bulbs.size():
		set_light(i, on)


func cor(x: float, lane := 0.0) -> Vector3:
	return Vector3(x, 0.0, 6.0 * C.TILE + lane)


# -------------------------------------------------------------------- people
## The camera: the watcher's eyes at `eye`, looking at `at`, flashlight on or off.
func look_from(eye: Vector3, at: Vector3, flashlight := true) -> void:
	watcher.teleport(Vector3(eye.x, eye.y - C.EYE_H, eye.z))
	var d := at - eye
	var yaw := atan2(-d.x, -d.z)
	watcher.rotation.y = yaw
	watcher._target_yaw = yaw
	watcher._pitch = atan2(d.y, Vector2(d.x, d.z).length())
	watcher.head.rotation.x = watcher._pitch
	watcher.set_flashlight(flashlight)
	watcher.moving = false
	watcher.body_visual.visible = false
	watcher.name_tag.visible = false


## A surgeon standing at `pos` facing `yaw` (0 faces -Z; -PI/2 faces +X, towards the camera end).
func surgeon(id: int, pos: Vector3, yaw: float, new_model := true) -> Node:
	use_new(new_model)
	var p: Node = PlayerScript.new_player(id, "S%d" % id, false)
	game.add_child(p)
	game.players[id] = p
	p.teleport(pos)
	p.rotation.y = yaw
	p._target_yaw = yaw
	p.name_tag.visible = false
	subjects.append(p)
	use_new(true)
	return p


func clear_subjects() -> void:
	if game.combat != null:
		game.combat.queue_free()
		game.combat = null
	for p in subjects:
		game.players.erase(p.peer_id)
		p.queue_free()
	subjects.clear()
	await get_tree().physics_frame


func wait(seconds: float) -> void:
	for i in maxi(1, int(ceil(seconds * 60.0))):
		await get_tree().physics_frame


# -------------------------------------------------------------------- shots
func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	watcher.camera.current = true
	var list := [
		["lit_3m", _shot_lit],
		["dark_flashlight_5m", _shot_dark],
		["face_1m", _shot_face],
		["old_vs_new", _shot_old_new],
		["lineup_tints", _shot_lineup],
		["walking", _shot_walk],
		["throw_windup", _shot_throw.bind(true)],
		["throw_release", _shot_throw.bind(false)],
		["walk_no_gashskin", _shot_walk_hiding.bind("Human_GashSkin")],
		["walk_no_toplower", _shot_walk_hiding.bind("Human_TopLower")],
		["dive_air", _shot_dive],
		["shove_charge_lights", _shot_shove.bind(true)],
		["shove_charge_nolights", _shot_shove.bind(false)],
	]
	for s in list:
		if only != "" and not only.split(",").has(s[0]):
			continue
		await clear_subjects()
		set_all_lights(false)
		await s[1].call()
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [SHOT_DIR, s[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("[style_lab] wrote ", path)
	get_tree().quit(0)


func _shot_lit() -> void:
	surgeon(1, cor(21.0, -0.2), -PI * 0.5 + 0.35)
	set_light(1, true)
	set_light(2, true)
	look_from(cor(24.0, 0.4) + Vector3.UP * C.EYE_H, cor(21.0, -0.2) + Vector3.UP * 1.0)
	await wait(1.2)


func _shot_dark() -> void:
	surgeon(1, cor(21.0, 0.0), -PI * 0.5 + 0.2)
	look_from(cor(26.0, 0.3) + Vector3.UP * C.EYE_H, cor(21.0, 0.0) + Vector3.UP * 1.1)
	await wait(1.2)


func _shot_face() -> void:
	var p := surgeon(1, cor(21.0, 0.0), -PI * 0.5 + 0.3)
	set_light(1, true)
	await wait(0.8)
	var head_pos: Vector3 = p.global_position + Vector3.UP * 1.66
	var fwd := Vector3(cos(0.3), 0.0, -sin(0.3))
	look_from(head_pos + fwd * 0.95 + Vector3(0, 0.02, 0.25), head_pos)
	await wait(0.6)


func _shot_old_new() -> void:
	surgeon(1, cor(21.0, -0.55), -PI * 0.5, false)
	surgeon(1 + 3, cor(21.0, 0.55), -PI * 0.5, true)   # id 4: same colour as id 1, surgeon_a again
	set_light(1, true)
	set_light(2, true)
	look_from(cor(24.2, 0.0) + Vector3.UP * C.EYE_H, cor(21.0, 0.0) + Vector3.UP * 1.0)
	await wait(1.2)


func _shot_lineup() -> void:
	for i in 4:
		surgeon(i + 1, cor(21.0, -1.2 + i * 0.8), -PI * 0.5)
	set_light(1, true)
	set_light(2, true)
	look_from(cor(25.5, 0.0) + Vector3.UP * C.EYE_H, cor(21.0, 0.0) + Vector3.UP * 0.95)
	await wait(1.2)


func _shot_walk() -> void:
	var p := surgeon(1, cor(21.0, 0.0), -PI * 0.5 + 0.9)
	set_light(1, true)
	set_light(2, true)
	look_from(cor(24.0, 1.2) + Vector3.UP * C.EYE_H, cor(21.0, 0.0) + Vector3.UP * 1.0)
	p.moving = true
	await wait(0.55)


## Mid-dive, as a teammate sees it: the replicated in-the-air bit, the body half a metre up.
func _shot_dive() -> void:
	var pos := cor(21.0, 0.0) + Vector3.UP * 0.35
	var p := surgeon(1, pos, -PI * 0.5 + 1.1)
	p._remote_dive_air = true
	set_light(1, true)
	set_light(2, true)
	look_from(cor(23.4, 1.6) + Vector3.UP * 1.3, cor(21.0, 0.0) + Vector3.UP * 0.7)
	for i in 40:
		p.global_position = pos
		await get_tree().physics_frame


## The walking shot with one body piece hidden (to see which piece shows through which).
func _shot_walk_hiding(piece: String) -> void:
	var p := surgeon(1, cor(21.0, 0.0), -PI * 0.5 + 0.9)
	HumanModel.show_piece(p.body_visual, piece, false)
	set_light(1, true)
	set_light(2, true)
	look_from(cor(22.6, 0.9) + Vector3.UP * 1.3, cor(21.0, 0.0) + Vector3.UP * 1.1)
	p.moving = true
	await wait(0.55)


## A full-charge shove wind-up seen from the front, with the shover's own flashlight and glow on or off.
func _shot_shove(own_lights: bool) -> void:
	var lc := LabCombat.new()
	lc.act = {"k": "shove", "ph": 0, "u": 1.0, "charge": 1.0}
	game.add_child(lc)
	game.combat = lc
	var p := surgeon(1, cor(21.0, 0.0), -PI * 0.5)
	p.set_flashlight(own_lights)
	for l in p.find_children("*", "OmniLight3D", true, false):
		(l as OmniLight3D).visible = own_lights
	set_light(1, true)
	look_from(cor(22.6, 0.25) + Vector3.UP * 1.62, cor(21.0, 0.0) + Vector3.UP * 1.5, false)
	await wait(1.0)


func _shot_throw(windup: bool) -> void:
	var p := surgeon(1, cor(21.0, 0.0), -PI * 0.5 + 1.2)
	set_light(1, true)
	set_light(2, true)
	look_from(cor(23.2, 1.3) + Vector3.UP * C.EYE_H, cor(21.0, 0.0) + Vector3.UP * 1.2)
	await wait(0.6)
	if windup:
		for i in 60:
			p.throw_wind = minf(1.0, i / 40.0)
			await get_tree().physics_frame
	else:
		for i in 45:
			p.throw_wind = 1.0
			await get_tree().physics_frame
		p.throw_wind = -1.0
		for i in 5:
			await get_tree().physics_frame
