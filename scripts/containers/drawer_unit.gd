extends "res://scripts/containers/container_base.gd"
## Steel multi-drawer cabinet. Each drawer is its own container with its own id
## ("ct_<tx>_<ty>_<n>", n counted from the bottom drawer), so E opens exactly the drawer
## you aim at. The aimable part is the drawer front, which stands proud of the carcass.
##
## `create_unit()` builds the whole cabinet: a plain Node3D holding the carcass (world
## collision) and the drawer containers. Its meta "drawers" lists them and "anchors" lists
## loose-item anchors on top ({xform: Transform3D local to the unit, surface}).
##
## Local frame: origin on the floor at the wall, the unit stands toward -Z.

const UNIT_W := 0.9
const UNIT_D := 0.56
const UNIT_H := 1.06
const DRAWERS := 3
const FRONT_H := 0.29
const PITCH := 0.32
const BASE_Y := 0.075
const PULL := 0.44
const TRAY_DEPTH := 0.5
const SIDE_H := 0.13

## How far the drawer slides out, set per drawer.
var pull := PULL
var _slide: Node3D


static func create_unit(tile: Vector2i) -> Node3D:
	var root := Node3D.new()
	root.name = "DrawerUnit_%d_%d" % [tile.x, tile.y]
	var steel := Mats.get_mat("steel")
	var zc := -UNIT_D * 0.5
	box(root, Vector3(UNIT_W, UNIT_H, UNIT_D), Vector3(0, UNIT_H * 0.5, zc), steel, "Carcass")
	box(root, Vector3(UNIT_W - 0.04, UNIT_H - 0.12, 0.006), Vector3(0, UNIT_H * 0.5 + 0.01, -UNIT_D - 0.002), Mats.get_mat("cavity"))
	box(root, Vector3(UNIT_W - 0.02, 0.06, 0.02), Vector3(0, 0.03, -UNIT_D + 0.03), Mats.get_mat("rubber"))
	# A steel instrument tray on top, where loose things get left.
	box(root, Vector3(0.5, 0.012, 0.34), Vector3(-0.12, UNIT_H + 0.006, zc - 0.02), Mats.get_mat("tray"))
	for e in [[Vector3(0.5, 0.025, 0.008), Vector3(-0.12, UNIT_H + 0.016, zc - 0.19)],
			[Vector3(0.5, 0.025, 0.008), Vector3(-0.12, UNIT_H + 0.016, zc + 0.15)],
			[Vector3(0.008, 0.025, 0.34), Vector3(-0.37, UNIT_H + 0.016, zc - 0.02)],
			[Vector3(0.008, 0.025, 0.34), Vector3(0.13, UNIT_H + 0.016, zc - 0.02)]]:
		box(root, e[0], e[1], Mats.get_mat("tray"))
	collider(root, C.L_WORLD, Vector3(UNIT_W, UNIT_H, UNIT_D), Vector3(0, UNIT_H * 0.5, zc), "Body")
	var drawers: Array = []
	for n in DRAWERS:
		var d = new()
		d.init_container("drawer_unit", "ct_%d_%d_%d" % [tile.x, tile.y, n])
		d.display_name = "drawer"
		d.position = Vector3(0, BASE_Y + n * PITCH, -UNIT_D)
		d._build_drawer(UNIT_W - 0.05, FRONT_H, TRAY_DEPTH, SIDE_H, [-0.19, 0.19], 0.27, "steel", n)
		root.add_child(d)
		drawers.append(d)
	bake(root)
	root.set_meta("drawers", drawers)
	root.set_meta("anchors", [{"xform": Transform3D(Basis.IDENTITY, Vector3(-0.12, UNIT_H + 0.012, zc - 0.02)), "surface": "tray"}])
	return root


## Build one drawer below this node: origin at the carcass front plane, bottom centre.
func _build_drawer(width: float, front_h: float, depth: float, side_h: float, slot_xs: Array,
		slot_z: float, front_key: String, index: int) -> void:
	sound_open = "containers_drawer_open"
	sound_close = "containers_drawer_close"
	open_time = 0.42
	close_time = 0.3
	_slide = Node3D.new()
	_slide.name = "Slide"
	add_child(_slide)
	var tray := Mats.get_mat("tray")
	var inner := width - 0.06
	box(_slide, Vector3(inner, 0.012, depth), Vector3(0, 0.02, depth * 0.5), Mats.get_mat("steel_dark"))
	for sx in [-1.0, 1.0]:
		box(_slide, Vector3(0.01, side_h, depth), Vector3(sx * inner * 0.5, 0.02 + side_h * 0.5, depth * 0.5), tray)
	box(_slide, Vector3(inner, side_h, 0.01), Vector3(0, 0.02 + side_h * 0.5, depth), tray)
	# Front panel, handle and a label card.
	box(_slide, Vector3(width, front_h, 0.022), Vector3(0, front_h * 0.5, -0.013), Mats.get_mat(front_key))
	box(_slide, Vector3(width * 0.42, 0.022, 0.02), Vector3(0, front_h * 0.62, -0.045), Mats.get_mat("chrome"))
	for hx in [-width * 0.2, width * 0.2]:
		box(_slide, Vector3(0.018, 0.022, 0.025), Vector3(hx, front_h * 0.62, -0.03), Mats.get_mat("chrome"))
	var label := box(_slide, Vector3(0.1, 0.045, 0.004), Vector3(0, front_h * 0.3, -0.025), Mats.get_mat("label"))
	label.position.x = -width * 0.28 if index % 2 == 0 else width * 0.28
	for sx in slot_xs:
		add_slot(_slide, Transform3D(Basis.IDENTITY, Vector3(float(sx), 0.026, slot_z)))
	collider(_slide, C.L_INTERACT, Vector3(width, front_h, 0.05), Vector3(0, front_h * 0.5, -0.03), "Aim")
	bake(_slide)


func _trans(open: bool) -> Tween.TransitionType:
	return Tween.TRANS_EXPO if open else Tween.TRANS_CUBIC


func _apply_pose(t: float) -> void:
	if _slide != null:
		_slide.position.z = -pull * t
