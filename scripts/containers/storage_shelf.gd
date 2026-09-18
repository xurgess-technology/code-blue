extends "res://scripts/containers/container_base.gd"
## Steel storage shelving in the OR (2026-09-18): put down whatever you are holding and it sits on
## a shelf until someone takes it again. Any item, any stack: it goes into the free spot nearest to
## where you are looking. Always open. What is on it are ordinary world items in its slots
## (WorldItem.State.IN_CONTAINER), so taking one back is the item's own "Take" and the network
## carries them like any other container's.
##
## Local frame: origin on the floor at the wall, the shelves face -Z (into the room), like the level's
## pieces (Defs.yaw_facing).

const Items := preload("res://scripts/items.gd")

const W := 1.2
const D := 0.45
const H := 1.95
## The height of each shelf board; three spots on each.
const BOARDS := [0.1, 0.58, 1.06, 1.54]
const SPOT_X := [-0.38, 0.0, 0.38]


static func create(id: String) -> Node3D:
	var s = new()
	s.init_container("storage_shelf", id)
	s.display_name = "shelves"
	s._open = true
	s._build()
	return s


func _build() -> void:
	var steel := Mats.get_mat("steel")
	var dark := Mats.get_mat("steel_dark")
	for sx in [-1.0, 1.0]:
		for sz in [-0.02, -(D - 0.02)]:
			box(self, Vector3(0.035, H, 0.035), Vector3(sx * (W * 0.5 - 0.02), H * 0.5, sz), dark)
	for y in BOARDS:
		box(self, Vector3(W, 0.025, D), Vector3(0, y, -D * 0.5), steel)
		# A lip along the front edge.
		box(self, Vector3(W, 0.04, 0.012), Vector3(0, y + 0.01, -(D - 0.006)), dark)
	box(self, Vector3(W, 0.025, D), Vector3(0, H - 0.0125, -D * 0.5), steel)
	# Spots numbered easiest reach first (waist, knee, head height, the floor board), so filling them
	# in order (game.stock_storage) starts where people look.
	for y in [BOARDS[2], BOARDS[1], BOARDS[3], BOARDS[0]]:
		for x in SPOT_X:
			add_slot(self, Transform3D(Basis(), Vector3(x, float(y) + 0.015, -D * 0.5)))
	# Solid where the steel is (uprights and boards), not a box round it all: the aim ray stops at
	# world collision, so a box would hide what sits on the shelves.
	for sx in [-1.0, 1.0]:
		collider(self, C.L_WORLD, Vector3(0.05, H, D), Vector3(sx * (W * 0.5 - 0.025), H * 0.5, -D * 0.5), "Side")
	for y in BOARDS + [H - 0.0125]:
		collider(self, C.L_WORLD, Vector3(W, 0.03, D), Vector3(0, float(y), -D * 0.5), "Board")
	# Aimed at through the gaps: a plane at the back, so anything on the shelves is hit first.
	collider(self, C.L_INTERACT, Vector3(W, H, 0.01), Vector3(0, H * 0.5, -0.03), "Aim")
	bake(self)


## Open shelving never closes (the game closes every container between shifts, and a closed
## container's items can't be taken).
func set_open(_open_now: bool, _animate: bool = true) -> void:
	_open = true


## Holding something and there is room: put it down. Empty-handed: nothing to do here (take things
## off by aiming at them).
func interact_prompt(player) -> String:
	if player == null or not player.has_method("selected_stack"):
		return ""
	var s: Dictionary = player.selected_stack()
	if String(s.get("kind", "")) == "":
		return ""
	if _free_slots().is_empty():
		return "!The shelves are full"
	return "Put %s on the shelf" % Items.stack_label(String(s.kind), int(s.count))


## Host: the selected stack goes into the free spot nearest the player's line of sight.
func interact(player) -> void:
	var g := _game()
	if g == null or player == null:
		return
	var free := _free_slots()
	if free.is_empty():
		return
	var best: int = free[0]
	var eye: Vector3 = player.head.global_position
	var fwd: Vector3 = -player.camera.global_transform.basis.z
	var best_d := INF
	for i in free:
		var at: Vector3 = slot_transform(i).origin
		# Distance from the spot to the look ray.
		var t := maxf(0.0, (at - eye).dot(fwd))
		var d := at.distance_to(eye + fwd * t)
		if d < best_d:
			best_d = d
			best = i
	g.storage_place(player, self, best)


## Spot indices nothing sits in.
func _free_slots() -> Array:
	var used := {}
	var g := _game()
	if g != null:
		var id := String(get_meta("interact_id"))
		for it in g.world_items.values():
			if is_instance_valid(it) and it.state == WorldItem.State.IN_CONTAINER and String(it.container_id) == id:
				used[int(it.slot)] = true
	var out: Array = []
	for i in slot_count():
		if not used.has(i):
			out.append(i)
	return out


func _game() -> Node:
	return get_tree().get_first_node_in_group("game") if is_inside_tree() else null
