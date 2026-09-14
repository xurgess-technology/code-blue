extends RefCounted
## The dev room: one bright, hand-built room instead of a generated hospital.
##
## Fills the same `level_info` keys the game reads from HospitalBuilder (spawns, table, shelf,
## lectern, lights, containers, nav_region) so the rest of the game runs unchanged. Built the
## same way on every machine, so every interact_id matches.
##
## Layout, world metres (X east, Z south, you spawn at the south wall looking north):
##
##   z 0 .. 6.8    the specimen pen: monsters spawn here
##   z 6.8 .. 8    a waist-high barrier you shoot over, with a gate in the middle
##   z 8 .. 18     the lab: OR table and shelf (west half), open floor for bots and dummies
##                 (east half), one of every container on the west wall, a dispenser for
##                 every item and the dev gun rack on the east wall

const DispenserScript := preload("res://scripts/dev/dev_dispenser.gd")
const FridgeScript := preload("res://scripts/containers/med_fridge.gd")
const DrawerUnitScript := preload("res://scripts/containers/drawer_unit.gd")
const StationScript := preload("res://scripts/containers/station_drawers.gd")
const TraumaBagScript := preload("res://scripts/containers/trauma_bag.gd")
const PegboardScript := preload("res://scripts/containers/pegboard.gd")

const W := 24.0
const D := 18.0
const H := 3.0
const PEN_Z := 6.8
const BARRIER_D := 1.2
const BARRIER_H := 1.1
const GATE_X := Vector2(10.8, 13.2)
const LIGHT_RANGE := 6.0
const LIGHT_ENERGY := 1.05

const TABLE := Vector3(8.5, 0.0, 11.5)
const PLAYER_TABLE := Vector3(8.5, 0.0, 14.3)
const SHELF := Vector3(5.2, 0.0, 11.5)
const LECTERN := Vector3(13.0, 0.0, 17.3)
## inventory (sweep 2): the loot rack's first cubby x, and the economy spots.
const RACK_X0 := 1.4
const SELL_BIN := Vector3(21.2, 0.0, 17.3)
const SHOP := Vector3(17.6, 0.0, 17.25)
const GOLD_PILE := Vector3(19.4, 0.0, 15.2)
const LootTableScript := preload("res://scripts/economy/loot_table.gd")

## Every nav obstacle as [centre, size] on the floor; filled while building.
static var _obstacles: Array = []

## DOORS HOOK: the pen's partitions (west face x, doorway z range) and their doors.
const DoorScript := preload("res://scripts/doors/door.gd")
const DoorPlan := preload("res://scripts/level/door_plan.gd")
const PARTITIONS := [
	{"id": "dr_dev_hinged", "kind": "hinged", "x": 7.5, "gap": Vector2(3.0, 4.5)},
	{"id": "dr_dev_double", "kind": "double", "x": 15.0, "gap": Vector2(1.5, 4.5)},
]


static func build(info: Dictionary) -> Node3D:
	_obstacles = []
	var root := Node3D.new()
	root.name = "DevRoom"

	var body := StaticBody3D.new()
	body.name = "WorldCollision"
	body.collision_layer = C.L_WORLD
	body.collision_mask = 0
	root.add_child(body)

	# ---- shell ---------------------------------------------------------------
	var floor_mat := _surface("mat/floor", Color(0.42, 0.44, 0.45), 0.85)
	var wall_mat := _surface("mat/wall_tile", Color(0.72, 0.75, 0.74), 0.8)
	var ceil_mat := _surface("mat/ceiling", Color(0.5, 0.52, 0.53), 0.95)
	var pen_floor := _surface("mat/concrete", Color(0.3, 0.3, 0.31), 0.95)
	root.add_child(_quad_mesh("Floor", [Vector3(0, 0, PEN_Z), Vector3(W, 0, PEN_Z), Vector3(W, 0, D), Vector3(0, 0, D)], Vector3.UP, floor_mat))
	root.add_child(_quad_mesh("PenFloor", [Vector3(0, 0, 0), Vector3(W, 0, 0), Vector3(W, 0, PEN_Z), Vector3(0, 0, PEN_Z)], Vector3.UP, pen_floor))
	root.add_child(_quad_mesh("Ceiling", [Vector3(0, H, 0), Vector3(0, H, D), Vector3(W, H, D), Vector3(W, H, 0)], Vector3.DOWN, ceil_mat))
	# Walls face inward.
	root.add_child(_quad_mesh("WallN", [Vector3(W, 0, 0), Vector3(0, 0, 0), Vector3(0, H, 0), Vector3(W, H, 0)], Vector3.BACK, wall_mat))
	root.add_child(_quad_mesh("WallS", [Vector3(0, 0, D), Vector3(W, 0, D), Vector3(W, H, D), Vector3(0, H, D)], Vector3.FORWARD, wall_mat))
	root.add_child(_quad_mesh("WallW", [Vector3(0, 0, 0), Vector3(0, 0, D), Vector3(0, H, D), Vector3(0, H, 0)], Vector3.RIGHT, wall_mat))
	root.add_child(_quad_mesh("WallE", [Vector3(W, 0, D), Vector3(W, 0, 0), Vector3(W, H, 0), Vector3(W, H, D)], Vector3.LEFT, wall_mat))
	_shape(body, Vector3(W, 0.4, D), Vector3(W * 0.5, -0.2, D * 0.5))
	_shape(body, Vector3(W, 0.4, D), Vector3(W * 0.5, H + 0.2, D * 0.5))
	_shape(body, Vector3(W, H, 0.4), Vector3(W * 0.5, H * 0.5, -0.2))
	_shape(body, Vector3(W, H, 0.4), Vector3(W * 0.5, H * 0.5, D + 0.2))
	_shape(body, Vector3(0.4, H, D), Vector3(-0.2, H * 0.5, D * 0.5))
	_shape(body, Vector3(0.4, H, D), Vector3(W + 0.2, H * 0.5, D * 0.5))

	# A hazard stripe along the lab side of the barrier, and signs.
	var stripe := _box_mesh(Vector3(W, 0.01, 0.25), Vector3(W * 0.5, 0.005, PEN_Z + BARRIER_D + 0.2), _mat(Color(0.85, 0.65, 0.1), 0.6))
	root.add_child(stripe)
	root.add_child(_sign("DEV ROOM", Vector3(W * 0.5, 2.45, D - 0.03), PI, 96, Color(0.35, 0.95, 0.85)))
	root.add_child(_sign("SPECIMENS", Vector3(W * 0.5, 2.3, 0.03), 0.0, 72, Color(1.0, 0.45, 0.35)))
	root.add_child(_sign("SUPPLY", Vector3(W - 0.03, 2.35, 13.2), -PI / 2.0, 64, Color(0.9, 0.95, 1.0)))
	root.add_child(_sign("STORAGE", Vector3(0.03, 2.35, 13.2), PI / 2.0, 64, Color(0.9, 0.95, 1.0)))

	# ---- the barrier and its gate ---------------------------------------------
	var steel := _mat(Color(0.36, 0.38, 0.41), 0.45)
	steel.metallic = 0.6
	var bz := PEN_Z + BARRIER_D * 0.5
	var left_w := GATE_X.x
	var right_w := W - GATE_X.y
	for seg in [[left_w * 0.5, left_w], [GATE_X.y + right_w * 0.5, right_w]]:
		root.add_child(_box_mesh(Vector3(seg[1], BARRIER_H, BARRIER_D), Vector3(seg[0], BARRIER_H * 0.5, bz), steel))
		_shape(body, Vector3(seg[1], BARRIER_H, BARRIER_D), Vector3(seg[0], BARRIER_H * 0.5, bz))
		_obstacles.append([Vector3(seg[0], 0, bz), Vector3(seg[1], 0, BARRIER_D)])
	var gate := StaticBody3D.new()
	gate.name = "PenGate"
	gate.collision_layer = C.L_WORLD
	gate.collision_mask = 0
	var gate_w := GATE_X.y - GATE_X.x
	var gate_mat := _mat(Color(0.75, 0.2, 0.15), 0.5)
	gate.add_child(_box_mesh(Vector3(gate_w, BARRIER_H * 0.9, 0.12), Vector3(0, BARRIER_H * 0.45, 0), gate_mat))
	_shape(gate, Vector3(gate_w, BARRIER_H, BARRIER_D), Vector3(0, BARRIER_H * 0.5, 0))
	gate.position = Vector3((GATE_X.x + GATE_X.y) * 0.5, 0, bz)
	root.add_child(gate)
	info["dev_gate"] = gate

	# ---- DOORS HOOK: two partitions split the pen into three bays, a hinged door in one and double
	# doors in the other, so monsters can be watched using doors (scripts/doors/doors.gd). Walls a tile
	# thick like the hospital's, so each door has its tunnel to fold into.
	var part_mat := _surface("mat/wall", Color(0.62, 0.64, 0.60), 0.85)
	var door_nodes: Array = []
	for pd in PARTITIONS:
		var x0: float = pd.x
		var gap: Vector2 = pd.gap
		for seg in [[0.0, gap.x], [gap.y, PEN_Z]]:
			var len: float = seg[1] - seg[0]
			if len <= 0.01:
				continue
			var c := Vector3(x0 + C.TILE * 0.5, H * 0.5, (seg[0] + seg[1]) * 0.5)
			var size := Vector3(C.TILE, H, len)
			root.add_child(_box_mesh(size, c, part_mat))
			_shape(body, size, c)
			_obstacles.append([Vector3(c.x, 0, c.z), Vector3(size.x, 0, size.z)])
		# The lintel above the doorway.
		var lc := Vector3(x0 + C.TILE * 0.5, (2.25 + H) * 0.5, (gap.x + gap.y) * 0.5)
		root.add_child(_box_mesh(Vector3(C.TILE, H - 2.25, gap.y - gap.x), lc, part_mat))
		var tiles: Array = []
		var tz := int(round(gap.x / C.TILE))
		var tx := int(round(x0 / C.TILE))
		var width := int(round((gap.y - gap.x) / C.TILE))
		for k in width:
			tiles.append(Vector2i(tx, tz + k))
		# Doors face +X (east): the plane just inside the east face of the partition.
		var d := {"id": String(pd.id), "kind": String(pd.kind), "tiles": tiles, "n": Vector2i(1, 0), "s": Vector2i(0, 1),
			"plane": Vector2(tx + 1.0 - DoorPlan.PLANE_INSET, (gap.x + gap.y) * 0.5 / C.TILE), "width": float(width),
			"hinge": -1, "max_in": 90.0, "max_out": 90.0, "room": -1, "zone": 0, "wing": "dev", "depth": 0, "base": true}
		var node: Node3D = DoorScript.create(d)
		root.add_child(node)
		door_nodes.append(node)
	info["door_nodes"] = door_nodes

	# ---- OR table, shelf, lectern -------------------------------------------------
	root.add_child(_operating_table(TABLE))
	_obstacles.append([TABLE, Vector3(2.3, 0, 1.0)])
	info["table"] = TABLE
	info["table_yaw"] = 0.0
	# downed (sweep 2 wave 3): the player table south of the OR table; game.gd builds its model.
	info["tables"] = [{"position": TABLE, "yaw": 0.0, "kind": "patient"}, {"position": PLAYER_TABLE, "yaw": 0.0, "kind": "player"}]
	_obstacles.append([PLAYER_TABLE, Vector3(2.1, 0, 0.9)])
	# Faces the table (+X), so the label reads from where the surgeon stands.
	info["shelf"] = {"position": SHELF, "yaw": PI / 2.0}
	_obstacles.append([SHELF, Vector3(0.5, 0, 1.35)])
	var lectern := StaticBody3D.new()
	lectern.name = "Lectern"
	lectern.collision_layer = C.L_WORLD
	lectern.collision_mask = 0
	lectern.position = LECTERN
	lectern.add_child(_box_mesh(Vector3(0.9, 0.05, 0.6), Vector3(0, 0.9, 0), _mat(Color(0.3, 0.21, 0.14), 0.7)))
	lectern.add_child(_box_mesh(Vector3(0.1, 0.88, 0.1), Vector3(0, 0.44, 0), steel))
	_shape(lectern, Vector3(0.9, 0.925, 0.6), Vector3(0, 0.4625, 0))
	root.add_child(lectern)
	info["lectern"] = {"position": LECTERN, "yaw": PI}
	_obstacles.append([LECTERN, Vector3(0.9, 0, 0.6)])

	# ---- one of every container on the west wall ------------------------------
	var holder := Node3D.new()
	holder.name = "Containers"
	root.add_child(holder)
	var entries: Array = []
	var types := ["med_fridge", "drawer_unit", "station_drawers", "trauma_bag", "pegboard"]
	var zs := [9.3, 10.9, 12.8, 14.7, 16.5]
	for i in types.size():
		var type: String = types[i]
		var tile := Vector2i(900 + i, 900)
		var id0 := "ct_%d_%d_0" % [tile.x, tile.y]
		var node: Node3D = null
		var list: Array = []
		match type:
			"med_fridge":
				node = _call_static(FridgeScript, "create", [id0])
				list = [node]
			"drawer_unit":
				node = _call_static(DrawerUnitScript, "create_unit", [tile])
				list = node.get_meta("drawers", []) if node != null else []
			"station_drawers":
				node = _call_static(StationScript, "create_unit", [tile])
				list = node.get_meta("drawers", []) if node != null else []
			"trauma_bag":
				node = _call_static(TraumaBagScript, "create", [id0])
				list = [node]
			"pegboard":
				node = _call_static(PegboardScript, "create", [id0])
				list = [node]
		if node == null:
			continue
		# Container frames stand toward -Z from a wall at their origin: turn -Z to face +X.
		var xf := Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(0.0, 0.0, zs[i]))
		node.transform = xf
		holder.add_child(node)
		_obstacles.append([Vector3(0.45, 0, zs[i]), Vector3(0.9, 0, 1.5)])
		for c in list:
			if c == null or not c.has_method("slot_count"):
				continue
			entries.append({"id": String(c.get_meta("interact_id")), "type": type, "room_kind": "dev",
				"node": c, "position": (c as Node3D).global_position if c.is_inside_tree() else xf.origin,
				"slots": c.slot_count()})
	info["containers"] = entries

	# ---- dispensers and the gun rack on the east wall ---------------------------
	var kinds: Array = Items.ITEMS.keys()
	kinds.append("dev_gun")
	var disp_root := Node3D.new()
	disp_root.name = "Dispensers"
	root.add_child(disp_root)
	var dz0 := 9.2
	var step := (D - 0.8 - dz0) / maxf(1.0, kinds.size() - 1)
	for i in kinds.size():
		var d = DispenserScript.create(String(kinds[i]))
		d.position = Vector3(W - 0.35, 0.0, dz0 + step * i)
		d.rotation.y = -PI / 2.0   # the dispenser's front (+Z) faces -X, into the room
		disp_root.add_child(d)
		_obstacles.append([d.position, Vector3(0.7, 0, 0.9)])

	# ---- inventory (sweep 2): the loot rack, the sell bin, the shop and the gold pile ----
	# A rack of cubbies on the south wall, west of the spawn line: one dispenser per loot kind,
	# bulky ones on the bottom row. The economy spots are read by scripts/economy/economy.gd.
	var loot_kinds: Array = LootTableScript.kinds()
	loot_kinds.sort_custom(func(a, b):
		var ba: bool = LootTableScript.LOOT[a].get("bulky", false)
		var bb: bool = LootTableScript.LOOT[b].get("bulky", false)
		return (ba and not bb) or (ba == bb and String(a) < String(b)))
	var rack := Node3D.new()
	rack.name = "LootRack"
	root.add_child(rack)
	var cols := 7
	for i in loot_kinds.size():
		var cubby = DispenserScript.create(String(loot_kinds[i]), true)
		var col := i % cols
		var row := i / cols
		cubby.position = Vector3(RACK_X0 + col * 0.8, 0.15 + row * 0.65, D - 0.25)
		cubby.rotation.y = PI   # front (+Z) faces north, into the room
		rack.add_child(cubby)
	var rows := ceili(float(loot_kinds.size()) / float(cols))
	_obstacles.append([Vector3(RACK_X0 + (cols - 1) * 0.4, 0, D - 0.25), Vector3(cols * 0.8, 0, 0.5)])
	root.add_child(_sign("LOOT", Vector3(RACK_X0 + (cols - 1) * 0.4, 0.15 + rows * 0.65 + 0.25, D - 0.03), PI, 64, Color(1.0, 0.8, 0.4)))
	var rack_lamp := OmniLight3D.new()
	rack_lamp.light_color = Color(1.0, 0.92, 0.8)
	rack_lamp.light_energy = 0.8
	rack_lamp.omni_range = 4.0
	rack_lamp.shadow_enabled = false
	rack_lamp.position = Vector3(RACK_X0 + (cols - 1) * 0.4, 2.6, D - 1.6)
	rack.add_child(rack_lamp)
	info["economy"] = {
		"sell_bin": {"position": SELL_BIN, "yaw": PI},
		"shop": {"position": SHOP, "yaw": PI},
		"gold_pile": {"position": GOLD_PILE},
	}
	_obstacles.append([SELL_BIN, Vector3(1.0, 0, 0.8)])
	_obstacles.append([SHOP, Vector3(1.6, 0, 0.8)])
	_obstacles.append([GOLD_PILE, Vector3(0.9, 0, 0.9)])

	# ---- lights ------------------------------------------------------------------
	var lights_root := Node3D.new()
	lights_root.name = "Lights"
	root.add_child(lights_root)
	var lights: Array = []
	for z in [2.2, 5.0, 10.0, 14.0, 16.8]:
		for x in [2.0, 6.0, 10.0, 14.0, 18.0, 22.0]:
			var pen: bool = z < PEN_Z
			var fx := _fixture(pen)
			fx.name = "Fixture_%d_%d" % [int(x), int(z * 10)]
			fx.position = Vector3(x, 0, z)
			lights_root.add_child(fx)
			lights.append({"tile": Vector2i(int(x), int(z)), "position": fx.position, "mode": 0, "node": fx})
	info["lights"] = lights

	# ---- markers -----------------------------------------------------------------
	var player_spawns: Array = []
	for i in 6:
		player_spawns.append(Vector3(9.0 + i * 1.3, 0.0, 16.3))
	var tool_spawns: Array = []
	for i in 8:
		tool_spawns.append(Vector3(13.5 + (i % 4) * 1.6, 0.0, 13.5 + (i / 4) * 1.4))
	info["player_spawns"] = player_spawns
	info["tool_spawns"] = tool_spawns
	# DOORS HOOK: all in the pen's middle bay (between the partitions at x 7.5-9 and 15-16.5), in
	# plain view of the lab; the side bays are through the doors.
	info["monster_spawns"] = [Vector3(10.2, 0, 3.2), Vector3(12.0, 0, 2.6), Vector3(13.8, 0, 3.4), Vector3(10.6, 0, 5.0), Vector3(13.4, 0, 5.0)]
	info["dummy_spots"] = [Vector3(15.5, 0, 10.2), Vector3(17.0, 0, 10.2), Vector3(18.5, 0, 10.2), Vector3(20.0, 0, 10.2), Vector3(15.5, 0, 11.8), Vector3(17.0, 0, 11.8), Vector3(18.5, 0, 11.8), Vector3(20.0, 0, 11.8)]
	# No time clock here: park its aim spot under the floor where nobody can aim.
	info["clock"] = Vector3(1.0, -40.0, 1.0)
	info["loose_anchors"] = []
	info["size"] = Vector2i(int(W / C.TILE), int(D / C.TILE))
	info["dev_room"] = true

	# ---- navigation ----------------------------------------------------------------
	var nav := NavigationRegion3D.new()
	nav.name = "Nav"
	root.add_child(nav)
	bake_nav(nav, false)
	info["nav_region"] = nav
	return root


## (Re)bake the room's navigation mesh. With the gate open, the pen joins the lab.
static func bake_nav(region: NavigationRegion3D, gate_open: bool) -> void:
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 45.0
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	var faces := PackedVector3Array()
	faces.append_array([Vector3(0, 0, 0), Vector3(W, 0, 0), Vector3(W, 0, D), Vector3(0, 0, 0), Vector3(W, 0, D), Vector3(0, 0, D)])
	# Obstacles are extruded nearly to the ceiling so their tops never become walkable islands.
	var obstacles := _obstacles.duplicate()
	if not gate_open:
		obstacles.append([Vector3((GATE_X.x + GATE_X.y) * 0.5, 0, PEN_Z + BARRIER_D * 0.5), Vector3(GATE_X.y - GATE_X.x, 0, BARRIER_D)])
	for o in obstacles:
		_box_faces(faces, o[0] + Vector3(0, 1.3, 0), Vector3(o[1].x, 2.6, o[1].z))
	# The ceiling, so the space under it counts as tall enough and nothing above it does.
	faces.append_array([Vector3(0, H, 0), Vector3(W, H, D), Vector3(W, H, 0), Vector3(0, H, 0), Vector3(0, H, D), Vector3(W, H, D)])
	var src := NavigationMeshSourceGeometryData3D.new()
	src.add_faces(faces, Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	# Recast lifts the surface by a voxel; put it back on the floor.
	var vs := nm.get_vertices()
	if not vs.is_empty():
		var min_y := vs[0].y
		for v in vs:
			min_y = minf(min_y, v.y)
		if absf(min_y) > 0.001 and min_y < 0.6:
			for i in vs.size():
				vs[i] = Vector3(vs[i].x, vs[i].y - min_y, vs[i].z)
			nm.set_vertices(vs)
	region.navigation_mesh = nm


## Show or hide the gate (collision too). Every machine calls this from the replicated state.
static func set_gate_open(info: Dictionary, open: bool) -> void:
	var gate = info.get("dev_gate")
	if gate == null or not is_instance_valid(gate):
		return
	gate.visible = not open
	gate.collision_layer = 0 if open else C.L_WORLD
	var nav = info.get("nav_region")
	if nav != null and is_instance_valid(nav):
		bake_nav(nav, open)


# ---------------------------------------------------------------------------
# pieces

static func _operating_table(pos: Vector3) -> Node3D:
	var sb := StaticBody3D.new()
	sb.name = "OperatingTable"
	sb.collision_layer = C.L_WORLD
	sb.collision_mask = 0
	sb.position = pos
	var model := _asset("prop/table_op")
	var top := 0.95
	if model != null:
		sb.add_child(model)
		var box := _mesh_aabb(model)
		if box.size.y > 0.3 and box.size.y < 1.6:
			top = box.position.y + box.size.y
		_shape(sb, Vector3(clampf(box.size.x, 1.6, 2.6), top, clampf(box.size.z, 0.6, 1.2)), Vector3(0, top * 0.5, 0))
	else:
		sb.add_child(_box_mesh(Vector3(2.2, 0.14, 0.95), Vector3(0, 0.88, 0), _mat(Color(0.78, 0.82, 0.84), 0.35)))
		sb.add_child(_box_mesh(Vector3(0.5, 0.8, 0.5), Vector3(0, 0.4, 0), _mat(Color(0.45, 0.47, 0.5), 0.4)))
		_shape(sb, Vector3(2.2, top, 0.95), Vector3(0, top * 0.5, 0))
	# A surgical lamp overhead so the patient always reads.
	var lamp := SpotLight3D.new()
	lamp.name = "SurgicalLamp"
	lamp.position = Vector3(0, H - 0.2, 0)
	lamp.rotation_degrees = Vector3(-90, 0, 0)
	lamp.spot_range = 4.0
	lamp.spot_angle = 30.0
	lamp.light_energy = 2.2
	lamp.light_color = Color(1.0, 0.98, 0.92)
	lamp.shadow_enabled = false
	sb.add_child(lamp)
	sb.add_child(_box_mesh(Vector3(0.6, 0.06, 0.6), Vector3(0, H - 0.12, 0), _mat(Color(0.9, 0.9, 0.85), 0.3, Color(1, 1, 0.9), 1.5)))
	return sb


static func _fixture(pen: bool) -> Node3D:
	var n := Node3D.new()
	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	var bm := BoxMesh.new()
	bm.size = Vector3(1.1, 0.05, 1.1)
	panel.mesh = bm
	panel.position = Vector3(0, H - 0.03, 0)
	var col := Color(0.75, 0.9, 1.0) if pen else Color(1.0, 0.97, 0.9)
	panel.material_override = _mat(Color(0.9, 0.9, 0.88), 0.35, col, 2.6)
	n.add_child(panel)
	var bulb := OmniLight3D.new()
	bulb.name = "Bulb"
	bulb.position = Vector3(0, H - 0.35, 0)
	bulb.omni_range = LIGHT_RANGE
	bulb.light_energy = LIGHT_ENERGY * (0.75 if pen else 1.0)
	bulb.light_color = col
	bulb.light_volumetric_fog_energy = 0.35   # a clean, clinical room: little haze
	bulb.shadow_enabled = false
	bulb.set_meta("base_energy", bulb.light_energy)
	n.add_child(bulb)
	return n


static func _sign(text: String, pos: Vector3, yaw: float, size: int, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.006
	l.modulate = col
	l.outline_size = 10
	l.outline_modulate = Color(0, 0, 0, 0.8)
	l.position = pos
	l.rotation.y = yaw
	return l


# ---------------------------------------------------------------------------
# helpers

static func _call_static(script: GDScript, method: String, args: Array) -> Node3D:
	for m in script.get_script_method_list():
		if m.name == method:
			var n = script.callv(method, args)
			return n if n is Node3D else null
	push_warning("Dev room: %s has no %s(); skipping that container." % [script.resource_path, method])
	return null


static func _quad_mesh(nm: String, corners: Array, normal: Vector3, mat: Material) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# World-metre UVs, which the Assets PBR sets expect.
	var uvs := []
	for c in corners:
		var v: Vector3 = c
		if absf(normal.y) > 0.5:
			uvs.append(Vector2(v.x, v.z))
		elif absf(normal.x) > 0.5:
			uvs.append(Vector2(v.z, H - v.y))
		else:
			uvs.append(Vector2(v.x, H - v.y))
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(normal)
		st.set_uv(uvs[idx])
		st.add_vertex(corners[idx])
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.name = nm
	# Corners are given clockwise as seen from the side the normal points to (Godot's front face).
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi


static func _box_faces(faces: PackedVector3Array, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var p := [
		c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(-h.x, -h.y, h.z),
		c + Vector3(-h.x, h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z),
	]
	for q in [[4, 5, 6, 7], [0, 3, 2, 1], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [3, 0, 4, 7]]:
		faces.append_array([p[q[0]], p[q[1]], p[q[2]], p[q[0]], p[q[2]], p[q[3]]])


static func _shape(body: Node3D, size: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)


static func _box_mesh(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	return mi


static func _mat(albedo: Color, rough := 0.8, emission := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = energy
	return m


static func _surface(key: String, fallback: Color, rough: float) -> Material:
	var a = _assets()
	if a != null and a.call("has", key):
		var m = a.call("material", key)
		if m is Material:
			return m
	return _mat(fallback, rough)


static func _assets() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Assets")
	return null


static func _asset(key: String) -> Node3D:
	var a = _assets()
	if a == null or not a.call("has", key):
		return null
	var n = a.call("spawn", key)
	return n if n is Node3D else null


static func _mesh_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != root:
			t = (n as Node3D).transform * t
			n = n.get_parent()
		var box := t * mi.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out
