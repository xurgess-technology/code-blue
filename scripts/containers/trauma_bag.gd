extends "res://scripts/containers/container_base.gd"
## A red trauma bag hanging from a wall hook. The lid unzips and flips back against the wall,
## showing two slots on the bag floor. The aimable parts are the lid and the front panel, so
## an item inside an open bag is still what the ray hits when you look into it.
##
## Local frame: origin on the floor at the wall, the bag hangs toward -Z.

const BW := 0.64
const BH := 0.27
const BD := 0.3
const BOTTOM := 0.98
const T := 0.022
const OFF_WALL := 0.03
const LID_OPEN_DEG := 88.0
const FRONT_OPEN_DEG := 78.0

var _lid: Node3D
var _front: Node3D


static func create(id: String) -> Node3D:
	var b = new()
	b.init_container("trauma_bag", id)
	b.display_name = "trauma bag"
	b.sound_open = "containers_zip"
	b.sound_close = "containers_thunk"
	b.open_time = 0.55
	b.close_time = 0.32
	b._build()
	return b


func _build() -> void:
	var red := Mats.get_mat("bag_red")
	var dark := Mats.get_mat("bag_red_dark")
	var z0 := -OFF_WALL
	var zc := z0 - BD * 0.5
	var zf := z0 - BD
	var yc := BOTTOM + BH * 0.5
	# Hook plate and hook on the wall, straps down to the bag's back corners.
	box(self, Vector3(0.12, 0.08, 0.012), Vector3(0, BOTTOM + BH + 0.42, -0.006), Mats.get_mat("steel_dark"))
	cyl(self, 0.012, 0.07, Vector3(0, BOTTOM + BH + 0.4, -0.04), Mats.get_mat("chrome"), Vector3(90, 0, 0), 8)
	for sx in [-1.0, 1.0]:
		var strap := box(self, Vector3(0.03, 0.46, 0.008), Vector3(sx * 0.12, BOTTOM + BH + 0.2, -0.012), Mats.get_mat("rubber"))
		strap.rotation.z = sx * 0.5
	# Body panels: bottom, back, two ends, and a front that carries the markings.
	box(self, Vector3(BW, T, BD), Vector3(0, BOTTOM + T * 0.5, zc), dark)
	box(self, Vector3(BW, BH, T), Vector3(0, yc, z0 - T * 0.5), red)
	for sx in [-1.0, 1.0]:
		box(self, Vector3(T, BH, BD), Vector3(sx * (BW - T) * 0.5, yc, zc), red)
		# Zipped end pocket.
		box(self, Vector3(0.05, BH * 0.7, BD * 0.7), Vector3(sx * (BW * 0.5 + 0.025), BOTTOM + BH * 0.4, zc), dark)
	box(self, Vector3(BW - 2 * T - 0.004, 0.01, BD - 2 * T), Vector3(0, BOTTOM + T + 0.005, zc), Mats.get_mat("bag_lining"))
	box(self, Vector3(BW - 2 * T - 0.004, BH - 0.03, 0.006), Vector3(0, yc, z0 - T - 0.003), Mats.get_mat("bag_lining"))
	_front = Node3D.new()
	_front.name = "Front"
	_front.position = Vector3(0, BOTTOM, zf)
	add_child(_front)
	box(_front, Vector3(BW, BH, T), Vector3(0, BH * 0.5, T * 0.5), red)
	box(_front, Vector3(BW + 0.004, 0.035, T + 0.004), Vector3(0, BH * 0.28, T * 0.5), Mats.get_mat("reflective"))
	box(_front, Vector3(0.1, 0.03, 0.004), Vector3(0, BH * 0.66, -0.002), Mats.get_mat("white_cross"))
	box(_front, Vector3(0.03, 0.1, 0.004), Vector3(0, BH * 0.66, -0.002), Mats.get_mat("white_cross"))
	collider(_front, C.L_INTERACT, Vector3(BW, BH, 0.05), Vector3(0, BH * 0.5, 0.0), "Aim")

	# Lid hinged along the back top edge, flips up toward the wall.
	_lid = Node3D.new()
	_lid.name = "Lid"
	_lid.position = Vector3(0, BOTTOM + BH, z0 - T)
	add_child(_lid)
	box(_lid, Vector3(BW + 0.01, 0.03, BD - T + 0.01), Vector3(0, 0.015, -(BD - T) * 0.5), red)
	box(_lid, Vector3(BW - 0.08, 0.004, 0.012), Vector3(0, 0.032, -BD + 0.04), Mats.get_mat("chrome"))
	box(_lid, Vector3(0.012, 0.04, 0.03), Vector3(BW * 0.5 - 0.06, 0.02, -(BD - T) - 0.012), Mats.get_mat("chrome"))
	box(_lid, Vector3(0.22, 0.02, 0.02), Vector3(0, 0.05, -(BD - T) * 0.5), Mats.get_mat("rubber"))
	box(_lid, Vector3(0.2, 0.004, 0.12), Vector3(0, 0.031, -BD * 0.5), Mats.get_mat("reflective"))
	collider(_lid, C.L_INTERACT, Vector3(BW, 0.05, BD), Vector3(0, 0.025, -BD * 0.5), "AimLid")

	for sx in [-0.145, 0.145]:
		add_slot(self, Transform3D(Basis.IDENTITY, Vector3(sx, BOTTOM + T + 0.01, zc - 0.01)))

	collider(self, C.L_WORLD, Vector3(BW + 0.1, BH, 0.04), Vector3(0, yc, z0 - 0.02), "BodyBack")
	collider(self, C.L_WORLD, Vector3(BW, T, BD), Vector3(0, BOTTOM + T * 0.5, zc), "BodyBottom")
	bake(self)
	bake(_front)
	bake(_lid)


func _trans(open: bool) -> Tween.TransitionType:
	return Tween.TRANS_BACK if open else Tween.TRANS_BOUNCE


func _apply_pose(t: float) -> void:
	if _lid != null:
		_lid.rotation.x = deg_to_rad(LID_OPEN_DEG) * t
	if _front != null:
		# Once unzipped the front flap drops open, so the contents face you.
		_front.rotation.x = -deg_to_rad(FRONT_OPEN_DEG) * clampf(t, 0.0, 1.15)
