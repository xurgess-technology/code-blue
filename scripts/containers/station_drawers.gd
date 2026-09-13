extends "res://scripts/containers/drawer_unit.gd"
## A nurse-station counter with two drawers under the worktop. Like the drawer unit, each
## drawer is its own container ("ct_<tx>_<ty>_0" on the unit's -X side, "_1" on +X).
## The counter is exactly one tile wide so neighbouring counters join into one long desk.
##
## `create_unit()` returns the counter Node3D with metas "drawers" and "anchors" (two
## "counter" spots on the worktop).

const COUNTER_W := 1.5
const COUNTER_D := 0.62
const TOP_Y := 0.96
const TOP_T := 0.045
const S_FRONT_H := 0.19
const S_DRAWER_W := 0.64
const S_PULL := 0.4


static func create_unit(tile: Vector2i) -> Node3D:
	var root := Node3D.new()
	root.name = "NurseStation_%d_%d" % [tile.x, tile.y]
	var body := Mats.get_mat("laminate")
	var zc := -COUNTER_D * 0.5
	var base_h := TOP_Y - TOP_T
	box(root, Vector3(COUNTER_W, base_h - 0.08, COUNTER_D - 0.02), Vector3(0, 0.08 + (base_h - 0.08) * 0.5, zc + 0.01), body, "Base")
	box(root, Vector3(COUNTER_W, 0.08, COUNTER_D - 0.08), Vector3(0, 0.04, zc + 0.04), Mats.get_mat("rubber"))
	box(root, Vector3(COUNTER_W, TOP_T, COUNTER_D + 0.05), Vector3(0, TOP_Y - TOP_T * 0.5, zc - 0.025), Mats.get_mat("counter_top"))
	box(root, Vector3(COUNTER_W, 0.012, 0.012), Vector3(0, TOP_Y - TOP_T, -COUNTER_D - 0.05), Mats.get_mat("laminate_dark"))
	# Drawer openings and cupboard doors below them.
	var drawer_y := base_h - 0.02 - S_FRONT_H
	box(root, Vector3(COUNTER_W - 0.06, S_FRONT_H + 0.02, 0.005), Vector3(0, drawer_y + S_FRONT_H * 0.5, -COUNTER_D - 0.001), Mats.get_mat("cavity"))
	for sx in [-1.0, 1.0]:
		var door_h := drawer_y - 0.12
		box(root, Vector3(0.68, door_h, 0.02), Vector3(sx * 0.36, 0.1 + door_h * 0.5, -COUNTER_D - 0.01), Mats.get_mat("laminate_dark"))
		box(root, Vector3(0.018, 0.16, 0.02), Vector3(sx * 0.06, 0.1 + door_h - 0.14, -COUNTER_D - 0.03), Mats.get_mat("chrome"))
	# A back upstand and a dim monitor, so it reads as a station and not a kitchen.
	box(root, Vector3(COUNTER_W, 0.22, 0.03), Vector3(0, TOP_Y + 0.11, -0.015), body)
	var mon := Node3D.new()
	mon.name = "Monitor"
	mon.position = Vector3(0.42 if (tile.x + tile.y) % 2 == 0 else -0.42, TOP_Y, -0.16)
	mon.rotation.y = 0.18 if (tile.x + tile.y) % 2 == 0 else -0.18
	root.add_child(mon)
	box(mon, Vector3(0.16, 0.012, 0.12), Vector3(0, 0.006, 0), Mats.get_mat("enamel_dark"))
	box(mon, Vector3(0.03, 0.14, 0.03), Vector3(0, 0.08, 0.02), Mats.get_mat("enamel_dark"))
	box(mon, Vector3(0.42, 0.27, 0.03), Vector3(0, 0.29, 0.0), Mats.get_mat("enamel_dark"))
	box(mon, Vector3(0.38, 0.23, 0.004), Vector3(0, 0.29, -0.017), Mats.get_mat("screen"))
	collider(root, C.L_WORLD, Vector3(COUNTER_W, TOP_Y, COUNTER_D), Vector3(0, TOP_Y * 0.5, zc), "Body")

	var drawers: Array = []
	for n in 2:
		var d = new()
		d.init_container("station_drawers", "ct_%d_%d_%d" % [tile.x, tile.y, n])
		d.display_name = "drawer"
		d.pull = S_PULL
		# n = 0 is the drawer on the unit's -X side (the right-hand one as you face the counter).
		d.position = Vector3((-0.36 if n == 0 else 0.36), drawer_y, -COUNTER_D)
		d._build_drawer(S_DRAWER_W, S_FRONT_H, 0.48, 0.1, [-0.15, 0.15], 0.25, "laminate_dark", n + 1)
		root.add_child(d)
		drawers.append(d)
	bake(root)
	bake(mon)
	root.set_meta("drawers", drawers)
	var free_x := -0.35 if mon.position.x > 0.0 else 0.35
	root.set_meta("anchors", [
		{"xform": Transform3D(Basis.IDENTITY, Vector3(free_x, TOP_Y, -0.4)), "surface": "counter"},
		{"xform": Transform3D(Basis.IDENTITY, Vector3(mon.position.x * 0.2, TOP_Y, -0.44)), "surface": "counter"},
	])
	return root
