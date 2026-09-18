extends Node
## Smoke look for the loot cut: a shift's loot in the world (one shot per loot kind found, standing
## next to it), and every kept kind lying in a row and in the hand. Windowed; run it minimized.
##
##   godot --path . --resolution 1280x720 tools/lootshot.tscn -- [--seed=N]
##
## Writes tools/loot_shots/<name>.png and prints how many stacks of each kind the shift has.

const OUT_DIR := "res://tools/loot_shots"
const KINDS := ["pill_bottle", "xray_film", "heart_monitor", "gold_watch", "ultrasound", "desk_phone",
	"laptop", "defibrillator", "reflex_hammer", "epipen", "pulse_oximeter"]

var main: Node3D
var game: Game
var bot: Player
var _seed := 1


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_tree().create_timer(300.0).timeout.connect(func(): get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	game = main.game
	main.menu.hide_menu()
	Net.start_solo("Camera")
	game.start_session(_seed)
	await _frames(2)
	bot = game.local_player()
	bot.bot_active = true
	bot.bot_invulnerable = true
	while game.get_parent().has_node("WarmupCover"):
		await get_tree().process_frame
	game.begin_shift()
	await _frames(20)
	# What the shift holds, and one shot standing next to the first of each kind.
	var seen := {}
	var counts := {}
	for it in game.world_items.values():
		if Items.is_loot(it.kind) and it.state == WorldItem.State.LOOSE:
			counts[it.kind] = int(counts.get(it.kind, 0)) + 1
			if not seen.has(it.kind):
				seen[it.kind] = it
	print("[lootshot] loot on the floor and counters: ", counts)
	bot.set_flashlight(true)
	for kind in seen:
		var it = seen[kind]
		if not is_instance_valid(it):
			continue
		var p: Vector3 = it.global_position
		var from: Vector3 = _clear_toward(p, 1.3)
		bot.teleport(game._floor_at(from))
		var eye := bot.global_position + Vector3.UP * C.EYE_H
		var d := (p + Vector3.UP * 0.05) - eye
		bot.bot_yaw = atan2(-d.x, -d.z)
		bot.bot_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.2, 1.2)
		await _frames(25)
		await _shot("world_%s" % kind)
	# Every kept kind in a row, lit by the flashlight, then each new kind in the hand.
	var base: Vector3 = game.table_pos() + Vector3(0, 0, 9.0)
	base = _clear_toward(base, 0.0)
	var placed := []
	for i in KINDS.size():
		var at: Vector3 = base + Vector3(2.2 + (i % 2) * 0.45, 0, (i - 5) * 0.42)
		var it2 = game._spawn_item(KINDS[i], 1, Transform3D(Basis(Vector3.UP, 0.3 * i), game._floor_at(at) + Vector3.UP * 0.01), WorldItem.State.LOOSE)
		it2.value = 100
		placed.append(it2)
	bot.teleport(game._floor_at(base))
	bot.bot_yaw = atan2(-1.0, 0.0)
	bot.bot_pitch = -0.35
	await _frames(30)
	await _shot("row")
	for kind in ["epipen", "pulse_oximeter"]:
		bot.slots = Player.empty_slots()
		bot.selected = 0
		bot.take_into(kind, 1, 60)
		await _frames(20)
		await _shot("held_%s" % kind)
	print("[lootshot] done")
	get_tree().quit(0)


## A point `dist` metres from `p` on clear floor (no wall between), for standing at.
func _clear_toward(p: Vector3, dist: float) -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	for k in 16:
		var dd := Vector3(1, 0, 0).rotated(Vector3.UP, TAU * k / 16.0)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.2, p + Vector3.UP * 1.2 + dd * (dist + 0.4))
		q.collision_mask = C.L_WORLD
		if space.intersect_ray(q).is_empty():
			return p + dd * dist
	return p + Vector3(dist, 0, 0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name]))
	print("[lootshot] wrote ", shot_name)
