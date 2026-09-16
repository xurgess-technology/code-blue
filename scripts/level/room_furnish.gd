extends RefCounted
## Wing room kinds and how each one is furnished.
##
## Every template works in a room-local frame so it reads the same whatever wall the door is
## in: u runs along the door wall (0 .. W), v runs from the door wall into the room (0 .. D),
## both in tiles. The door opens onto cell (door_u, 0); the back wall is at v = D.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Rng := preload("res://scripts/level/rng.gd")

## w / d: interior size ranges along / away from the door wall. open: archway width instead of
## a door (0 = door). weight: how often it fills leftover frontage. label: the sign over the door.
const KINDS := {
	"patient_room": {"w": [3, 6], "d": [3, 4], "weight": 26.0, "open": 0, "label": "WARD"},
	"supply_closet": {"w": [3, 5], "d": [3, 4], "weight": 7.0, "open": 0, "label": "SUPPLY"},
	"pharmacy": {"w": [4, 7], "d": [4, 5], "weight": 1.5, "open": 0, "label": "PHARMACY"},
	"nurse_station": {"w": [4, 6], "d": [3, 4], "weight": 2.5, "open": 3, "label": "NURSES"},
	"waiting_room": {"w": [5, 8], "d": [4, 5], "weight": 0.8, "open": 3, "label": "WAITING"},
	"restroom": {"w": [3, 5], "d": [3, 4], "weight": 3.5, "open": 0, "label": "RESTROOM"},
	"office": {"w": [3, 4], "d": [3, 4], "weight": 7.0, "open": 0, "label": "OFFICE"},
	"lab": {"w": [4, 7], "d": [4, 5], "weight": 1.5, "open": 0, "label": "LABORATORY"},
	"radiology": {"w": [4, 6], "d": [4, 6], "weight": 1.0, "open": 0, "double": true, "label": "RADIOLOGY"},
	"morgue": {"w": [4, 7], "d": [4, 5], "weight": 0.6, "open": 0, "double": true, "label": "MORGUE"},
	"janitor_closet": {"w": [3, 3], "d": [3, 3], "weight": 3.0, "open": 0, "label": "JANITOR"},
	"cafeteria": {"w": [7, 11], "d": [5, 6], "weight": 0.3, "open": 0, "double": true, "label": "CAFETERIA"},
}
## `double`: the wide rooms get a two-tile doorway with double doors instead of one door.

## Most of a kind on one map, and in one wing.
const MAP_CAP := {"pharmacy": 3, "lab": 2, "radiology": 2, "morgue": 2, "cafeteria": 1, "waiting_room": 2}
const WING_CAP := {"nurse_station": 2, "waiting_room": 1, "cafeteria": 1, "restroom": 2, "pharmacy": 1,
		"lab": 1, "radiology": 1, "morgue": 1}

## Which room kinds a container type may stand in. This is the placement rule the generator and
## tools/mapcheck.gd enforce ("corridor" means a wing hallway wall).
const CONTAINER_ROOMS := {
	"med_fridge": ["pharmacy", "supply_closet", "lab"],
	"drawer_unit": ["supply_closet", "janitor_closet", "lab", "morgue"],
	"station_drawers": ["nurse_station"],
	"trauma_bag": ["corridor", "nurse_station", "patient_room"],
	"pegboard": ["janitor_closet", "supply_closet", "morgue"],
}

## Pieces every room of a kind must end up with. An inner array means "any one of these".
const REQUIRED := {
	"patient_room": ["hospital_bed", "iv_stand", "bedside", "visitor_chair", "curtain"],
	"supply_closet": ["steel_shelves"],
	"pharmacy": ["pharmacy_counter", "med_shelf"],
	"nurse_station": ["office_chair"],
	"waiting_room": ["chair_row", "magazine_table", "tv_wall"],
	"restroom": ["stall", "wall_sink"],
	"office": ["office_desk", "office_chair", "filing_cabinet"],
	"lab": [["lab_bench", "lab_bench_scope"], "fume_hood"],
	"radiology": ["ct_scanner", "lightbox"],
	"morgue": [["morgue_fridge", "morgue_fridge_open"], "autopsy_table"],
	"janitor_closet": ["mop_sink"],
	"cafeteria": ["serving_counter", "cafeteria_table", "school_chair"],
	# The hub (scripts/level/entrance.gd, hub rebuild 2026-09-16).
	"break_room": ["time_clock", "break_table"],
	"or": ["or_table", "surgical_lamp", "scrub_sink"],
	"or_lockers": ["lockers"],
	"lobby": ["reception_desk", "office_desk"],
	"hub_pharmacy": ["med_shelf"],
	"hub_waiting": ["chair_row", "tv_wall"],
}

## Containers every room of a kind must end up with.
const REQUIRED_CONTAINERS := {
	"supply_closet": ["med_fridge", "drawer_unit"],
	"pharmacy": ["med_fridge"],
	"nurse_station": ["station_drawers"],
	"janitor_closet": ["pegboard"],
}


class Frame extends RefCounted:
	var st: S
	var room: int
	var x: int
	var y: int
	var w: int
	var h: int
	var side: String
	var W: int
	var D: int
	var door_u: int
	var rng: Rng

	func _init(st_: S, room_: int, rng_: Rng) -> void:
		st = st_
		room = room_
		rng = rng_
		var r: Dictionary = st.rooms[room]
		x = r.x
		y = r.y
		w = r.w
		h = r.h
		side = r.side
		W = w if side == "S" or side == "N" else h
		D = h if side == "S" or side == "N" else w
		door_u = u_of(r.door)

	## The u cell of a doorway tile in the door wall.
	func u_of(door: Vector2i) -> int:
		match side:
			"S": return door.x - x
			"N": return x + w - 1 - door.x
			"W": return door.y - y
		return y + h - 1 - door.y

	## Local (u, v) in tiles to tile space.
	func g(u: float, v: float) -> Vector2:
		match side:
			"S": return Vector2(x + u, y + h - v)
			"N": return Vector2(x + w - u, y + v)
			"W": return Vector2(x + v, y + u)
		return Vector2(x + w - v, y + h - u)

	## Local direction to tile space.
	func gdir(du: float, dv: float) -> Vector2:
		match side:
			"S": return Vector2(du, -dv)
			"N": return Vector2(-du, dv)
			"W": return Vector2(dv, du)
		return Vector2(-dv, -du)

	func cell(iu: int, iv: int) -> Vector2i:
		var p := g(iu + 0.5, iv + 0.5)
		return Vector2i(int(floor(p.x)), int(floor(p.y)))

	func open_cell(iu: int, iv: int) -> bool:
		if iu < 0 or iv < 0 or iu >= W or iv >= D:
			return false
		var c := cell(iu, iv)
		return st.open(c.x, c.y) and st.keep[st.idx(c.x, c.y)] == 0

	func keep_cell(iu: int, iv: int) -> void:
		if iu < 0 or iv < 0 or iu >= W or iv >= D:
			return
		var c := cell(iu, iv)
		st.set_keep(c.x, c.y, 2)

	## Half the depth of a piece in tiles: how far its centre sits from a wall it backs onto.
	func half(kind: String) -> float:
		return Defs.size(kind).z * 0.5 / Defs.TILE + 0.02

	## Place a piece at local (u, v) facing local (fu, fv). Blocking pieces that cut the room
	## in two are taken back out.
	func put(kind: String, u: float, v: float, fu: float, fv: float, extra := {}) -> bool:
		var p := g(u, v)
		if not Defs.blocks(kind) and not Defs.mounted(kind):
			var t := Vector2i(int(floor(p.x)), int(floor(p.y)))
			if not st.walkable(t.x, t.y) or st.room_index(t.x, t.y) != room or st.keep[st.idx(t.x, t.y)] == 2:
				return false
		if not st.put(kind, p, Defs.yaw_facing(gdir(fu, fv)), room, extra):
			return false
		if Defs.blocks(kind) and not st.room_connected(room):
			st.pop_piece()
			return false
		return true

	func back(kind: String, u: float, extra := {}) -> bool:
		return put(kind, u, D - half(kind), 0, -1, extra)

	func left(kind: String, v: float, extra := {}) -> bool:
		return put(kind, half(kind), v, 1, 0, extra)

	func right(kind: String, v: float, extra := {}) -> bool:
		return put(kind, W - half(kind), v, -1, 0, extra)

	func mount_back(kind: String, u: float) -> bool:
		return put(kind, u, D, 0, -1)

	func mount_left(kind: String, v: float) -> bool:
		return put(kind, 0.0, v, 1, 0)

	func mount_right(kind: String, v: float) -> bool:
		return put(kind, W, v, -1, 0)

	func mount_front(kind: String, u: float) -> bool:
		return put(kind, u, 0.0, 0, 1)

	## A container on cell (iu, iv) against the local wall direction (wu, wv).
	func container(iu: int, iv: int, wu: int, wv: int, type: String) -> bool:
		if iu < 0 or iv < 0 or iu >= W or iv >= D:
			return false
		var c := cell(iu, iv)
		var d := gdir(wu, wv)
		if not st.add_container(c, Vector2i(roundi(d.x), roundi(d.y)), type, room):
			return false
		if not st.room_connected(room):
			var gone: Dictionary = st.containers.pop_back()
			st.blocked[st.idx(gone.tile.x, gone.tile.y)] = 0
			var f: Vector2i = gone.tile - gone.wall
			st.keep[st.idx(f.x, f.y)] = 0
			return false
		return true

	func has_piece(kind: String) -> bool:
		for e in st.furniture:
			if e.room == room and e.kind == kind:
				return true
		return false

	## Try a container on each cell in `cells` ([[iu, iv], ...]) until one takes.
	func container_any(cells: Array, wu: int, wv: int, type: String) -> bool:
		for c in cells:
			if container(c[0], c[1], wu, wv, type):
				return true
		return false


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

static func furnish(st: S, room: int, rng: Rng) -> void:
	var f := Frame.new(st, room, rng)
	var kind: String = st.rooms[room].kind
	# The doorway and one step inside it stay clear (both halves of a double doorway).
	f.keep_cell(f.door_u, 0)
	if f.D > 3 and kind != "pharmacy":
		f.keep_cell(f.door_u, 1)
	if st.rooms[room].has("door2"):
		var u2 := f.u_of(st.rooms[room].door2)
		f.keep_cell(u2, 0)
		if f.D > 3:
			f.keep_cell(u2, 1)
	match kind:
		"patient_room": _patient_room(f)
		"supply_closet": _supply_closet(f)
		"pharmacy": _pharmacy(f)
		"nurse_station": _nurse_station(f)
		"waiting_room": _waiting_room(f)
		"restroom": _restroom(f)
		"office": _office(f)
		"lab": _lab(f)
		"radiology": _radiology(f)
		"morgue": _morgue(f)
		"janitor_closet": _janitor(f)
		"cafeteria": _cafeteria(f)


static func _patient_room(f: Frame) -> void:
	var n := clampi(f.W / 3, 1, 2)
	var span := float(f.W) / n
	var trauma := f.rng.chance(0.4)
	for i in n:
		var bu := floorf((i + 0.5) * span) + 0.5
		var bv := f.D - Defs.size("hospital_bed").z * 0.5 / Defs.TILE - 0.03
		if not f.put("hospital_bed", bu, bv, 0, -1):
			continue
		f.put("iv_stand", bu + 0.62, f.D - 0.32, 0, -1)
		f.put("bedside", bu - 0.72, f.D - f.half("bedside"), 0, -1)
		f.mount_back("wall_monitor", bu + 0.02)
		f.put("bed_tray", bu + 0.5, f.D - 1.75, 0, -1)
		var chair_u := bu + 1.05
		if chair_u > f.W - 0.3:
			chair_u = bu - 1.05
		if not f.put("visitor_chair", chair_u, f.D - 2.0, -1 if chair_u > bu else 1, 0):
			for c in [[bu - 1.05, f.D - 2.0, 1, 0], [bu + 1.0, f.D - 1.3, -1, 0], [bu - 1.0, f.D - 1.3, 1, 0], [bu, f.D - 2.6, 0, -1]]:
				if f.put("visitor_chair", c[0], c[1], c[2], c[3]):
					break
		if n == 1:
			for c in [[bu + 0.25, f.D - 2.55, 0, -1], [bu - 0.25, f.D - 2.4, 0, -1], [bu + 0.62, f.D - 1.0, 1, 0], [bu - 0.62, f.D - 1.0, -1, 0]]:
				if f.put("curtain", c[0], c[1], c[2], c[3]):
					break
		elif i < n - 1:
			f.put("curtain", (i + 1) * span, f.D - 0.9, 1, 0)
	if not f.has_piece("curtain"):
		for c in [[f.W * 0.5, f.D - 2.55, 0, -1], [0.6, f.D - 1.0, 1, 0], [f.W - 0.6, f.D - 1.0, -1, 0], [f.W * 0.5, 1.4, 0, -1]]:
			if f.put("curtain", c[0], c[1], c[2], c[3]):
				break
	f.put("wall_sink", f.W - f.half("wall_sink"), 1.0, -1, 0)
	f.put("bin", 0.3, 0.35 if f.door_u > 0 else 1.4, 1, 0)
	if trauma:
		f.container_any([[0, 1], [0, 2], [f.W - 1, 2]], -1, 0, "trauma_bag")


static func _supply_closet(f: Frame) -> void:
	var cols := [0, f.W - 1]
	if f.rng.chance(0.5):
		cols.reverse()
	if not f.container(cols[0], f.D - 1, 0, 1, "med_fridge"):
		f.container_any([[cols[1], f.D - 1], [0, f.D - 2]], 0, 1, "med_fridge")
	if not f.container(cols[1], f.D - 1, 0, 1, "drawer_unit"):
		f.container_any([[1, f.D - 1], [f.W - 2, f.D - 1]], 0, 1, "drawer_unit")
	if f.W >= 3 and f.rng.chance(0.55):
		f.container_any([[f.W / 2, f.D - 1], [1, f.D - 1]], 0, 1, "pegboard")
	for iv in range(0, maxi(1, f.D - 2)):
		f.left("steel_shelves", iv + 0.5)
		f.right("steel_shelves", iv + 0.5)
	if f.D >= 4:
		f.left("steel_shelves", f.D - 1.5)
	f.put("box_stack", f.W * 0.5, 0.5, 0, 1)


static func _pharmacy(f: Frame) -> void:
	# The counter across the front with a gate at one end, then the back wall: fridges at the
	# ends (and the middle of a wide room), medicine shelves between them, more shelves down the
	# side walls of a deep room.
	var gate := f.W - 1 if f.door_u < f.W / 2 else 0
	f.keep_cell(gate, 1)
	for iu in f.W:
		if iu == gate:
			continue
		f.put("pharmacy_counter", iu + 0.5, 1.5, 0, -1)
	var fridge_cols := [0, f.W - 1]
	if f.W >= 6:
		fridge_cols.append(f.W / 2)
	for iu in f.W:
		if fridge_cols.has(iu):
			if not f.container(iu, f.D - 1, 0, 1, "med_fridge"):
				f.back("med_shelf", iu + 0.5)
		else:
			f.back("med_shelf", iu + 0.5)
	for iv in range(2, f.D - 2):
		f.left("med_shelf", iv + 0.5)
		f.right("med_shelf", iv + 0.5)
	f.mount_back("wall_clock", f.W - 0.5)
	f.put("bin", 0.3 if gate != 0 else f.W - 0.3, 0.35, 0, 1)


static func _nurse_station(f: Frame) -> void:
	var mid := f.W / 2
	f.container(mid - 1, f.D - 1, 0, 1, "station_drawers")
	f.container(mid, f.D - 1, 0, 1, "station_drawers")
	f.put("office_chair", mid - 0.5, f.D - 1.7, 0, 1)
	f.put("office_chair", mid + 0.5, f.D - 1.7, 0, 1)
	f.container_any([[0, f.D - 1], [0, 1], [f.W - 1, 1], [f.W - 1, f.D - 2]], -1 if f.rng.chance(0.5) else 1, 0, "trauma_bag")
	if not f.back("filing_cabinet", f.W - 0.8):
		f.right("filing_cabinet", f.D - 1.5)
	f.put("med_cart", 0.6, 1.4, 1, 0)
	f.mount_right("whiteboard", 1.5)
	f.mount_back("wall_clock", 0.8)


static func _waiting_room(f: Frame) -> void:
	# Rows of joined seats facing a television on the back wall, a reception desk down one side
	# of a wide room, magazines and a vending machine.
	var desk := f.W >= 7
	var right_edge := f.W - (2.2 if desk else 0.4)
	f.mount_back("tv_wall", right_edge * 0.5)
	var rows := [1.75]
	if f.D >= 5:
		rows.append(3.15)
	for v in rows:
		var u := 0.95
		while u + 0.6 <= right_edge:
			f.put("chair_row", u, v, 0, 1)
			u += 1.25
	if desk:
		f.put("reception_desk", f.W - 0.95, f.D * 0.5, -1, 0)
		f.put("office_chair", f.W - 0.3, f.D * 0.5, -1, 0)
	if not f.put("magazine_table", 0.6, f.D - 0.65, 1, 0):
		f.put("magazine_table", right_edge - 0.6, f.D - 0.65, -1, 0)
	f.put("plant", 0.35, f.D - 0.35, 0, -1)
	f.put("vending", f.half("vending"), 0.9, 1, 0)
	f.put("bin", right_edge - 0.3, 0.4, -1, 0)
	f.mount_left("wall_clock", f.D * 0.5)


static func _restroom(f: Frame) -> void:
	var stalls := clampi(f.W - 2, 2, 4)
	var start := 0 if f.door_u >= stalls else f.W - stalls
	for i in stalls:
		f.back("stall", start + i + 0.5)
	var sink_u := f.W - f.half("wall_sink") if start == 0 else f.half("wall_sink")
	var face := -1 if start == 0 else 1
	for v in [0.9, 1.9]:
		if f.put("wall_sink", sink_u, v, face, 0):
			if start == 0:
				f.mount_right("mirror", v)
			else:
				f.mount_left("mirror", v)
	if start == 0:
		f.mount_right("hand_dryer", 2.9)
	else:
		f.mount_left("hand_dryer", 2.9)
	f.put("bin", sink_u + face * 0.1, 2.7, face, 0)


static func _office(f: Frame) -> void:
	var du := f.W * 0.5
	f.put("office_desk", du, f.D - 1.45, 0, -1)
	f.put("office_chair", du, f.D - 0.6, 0, -1)
	f.put("visitor_chair", du - 0.35, f.D - 2.45, 0, 1)
	if not f.put("coat_rack", 0.35, 0.4, 0, 1):
		f.put("coat_rack", f.W - 0.35, 0.4, 0, 1)
	if not f.left("filing_cabinet", f.D - 0.6):
		f.left("filing_cabinet", 1.5)
	f.left("filing_cabinet", f.D - 1.25)
	f.right("bookcase", f.D - 0.8)
	f.put("plant", f.W - 0.35, 0.4, 0, 1)
	f.mount_back("wall_clock", 0.6)


static func _lab(f: Frame) -> void:
	f.put("fume_hood", f.W * 0.5, f.D - f.half("fume_hood"), 0, -1)
	f.container_any([[1, f.D - 1], [f.W - 2, f.D - 1]], 0, 1, "drawer_unit")
	f.container_any([[f.W - 2, f.D - 1], [1, f.D - 1], [f.W - 1, f.D - 1]], 0, 1, "med_fridge")
	var scope := false
	for iv in range(1, f.D - 1):
		f.left("lab_bench_scope" if scope else "lab_bench", iv + 0.5)
		f.right("lab_bench" if scope else "lab_bench_scope", iv + 0.5)
		scope = not scope
	if f.W >= 8:
		for iv in range(2, f.D - 2):
			f.put("lab_island", f.W * 0.5, iv + 0.5, 1, 0)
	f.mount_back("whiteboard", 1.2)


static func _radiology(f: Frame) -> void:
	# The scanner along the room's long axis, couch toward the door, then the console desk
	# behind a lead partition wherever there is space.
	var placed := false
	var tries: Array = []
	if f.D >= f.W:
		for du in [0.0, 0.5, -0.5, 1.0, -1.0]:
			tries.append([f.W * 0.5 + du, f.D * 0.5 + 0.35, 0, -1])
	for dv in [0.0, 0.5, -0.5, 1.0]:
		tries.append([f.W * 0.5 + 0.3, f.D * 0.5 + dv, 1, 0])
		tries.append([f.W * 0.5 - 0.3, f.D * 0.5 + dv, -1, 0])
	if f.D < f.W:
		for du in [0.0, 0.5, -0.5]:
			tries.append([f.W * 0.5 + du, f.D * 0.5 + 0.35, 0, -1])
	for t in tries:
		if f.put("ct_scanner", t[0], t[1], t[2], t[3]):
			placed = true
			break
	if not f.left("console_desk", 1.4) and not f.right("console_desk", 1.4) and not f.back("console_desk", 0.9):
		f.back("console_desk", f.W - 0.9)
	f.put("lead_partition", 1.0, 2.4, 0, 1)
	if not f.right("gurney", f.D - 1.6):
		f.left("gurney", f.D - 1.6)
	f.mount_left("lightbox", f.D - 1.5)
	f.mount_front("radiation_sign", clampf(f.door_u + 1.3, 0.3, f.W - 0.3))
	f.st.rooms[f.room]["door_style"] = "lead"


static func _morgue(f: Frame) -> void:
	var open_at := f.rng.rint(1, maxi(1, f.W - 2))
	for iu in range(1, f.W - 1):
		f.back("morgue_fridge_open" if iu == open_at else "morgue_fridge", iu + 0.5)
	var tables := [f.W * 0.5] if f.W < 7 else [f.W * 0.5 - 1.5, f.W * 0.5 + 1.5]
	var placed_u: Array = []
	for i in tables.size():
		# Keep clear of the doorway: try the planned spot, then either side of it, then lying
		# across the room.
		var tries: Array = []
		for du in [0.0, 1.0, -1.0, 2.0, -2.0]:
			var u: float = clampf(tables[i] + du, 0.8, f.W - 0.8)
			tries.append([u, f.D * 0.5 - 0.2, 0, -1])
			tries.append([u, f.D * 0.5 + 0.3, 0, -1])
		for dv in [0.0, -0.5, 0.5]:
			tries.append([tables[i], f.D * 0.5 - 0.3 + dv, 1, 0])
		for t in tries:
			if f.put("autopsy_table", t[0], t[1], t[2], t[3]):
				if placed_u.is_empty():
					f.put("covered_body", t[0], t[1], t[2], t[3], {"y": 0.92})
				placed_u.append(t[0])
				break
	if placed_u.is_empty():
		placed_u.append(f.W * 0.5)
	tables = placed_u
	f.container_any([[0, 1], [0, 2]], -1, 0, "drawer_unit")
	f.container_any([[f.W - 1, 2], [f.W - 1, 3], [0, 3]], 1, 0, "pegboard")
	f.put("instrument_cart", tables[0] + 1.1, f.D * 0.5 + 0.9, -1, 0)
	f.right("scrub_sink", 1.0)
	f.mount_left("wall_clock", f.D - 1.0)


static func _janitor(f: Frame) -> void:
	f.container_any([[1, f.D - 1], [f.W - 2, f.D - 1]], 0, 1, "pegboard")
	if not f.back("mop_sink", 0.5):
		f.back("mop_sink", f.W - 0.5)
	for iv in range(1, f.D - 1):
		f.right("steel_shelves", iv + 0.5)
	if f.rng.chance(0.5):
		f.container_any([[0, 1], [0, 2]], -1, 0, "drawer_unit")
	f.put("mop_bucket", 0.55, f.D - 1.5, 1, 0)
	f.put("wet_floor", f.W - 1.2, 0.6, 0, 1)
	f.put("broom", 0.2, 0.4, 1, 0)


static func _cafeteria(f: Frame) -> void:
	for iu in range(1, f.W - 3):
		f.put("serving_counter", iu + 0.5, f.D - 1.55, 0, -1)
	f.put("tray_stack", 1.5, f.D - 1.55, 0, -1, {"y": 0.92})
	f.put("register", f.W - 2.5, f.D - 1.6, 0, -1)
	var v := 2.2
	while v < f.D - 3.0:
		var u := 2.0
		while u < f.W - 1.6:
			if f.put("cafeteria_table", u, v, 0, -1):
				for cu in [u - 0.45, u + 0.45]:
					f.put("school_chair", cu, v - 0.78, 0, 1)
					f.put("school_chair", cu, v + 0.78, 0, -1)
				if f.rng.chance(0.5):
					f.put("tray", u + 0.3, v, 0, -1, {"y": 0.75})
			u += 3.2
		v += 2.8
	if not f.has_piece("cafeteria_table"):
		# A shallow cafeteria: one table where there is room.
		for c in [[f.W * 0.5, 2.0], [f.W * 0.5 - 1.5, 2.0], [f.W * 0.5 + 1.5, 2.0], [f.W * 0.5, 1.6]]:
			if f.put("cafeteria_table", c[0], c[1], 0, -1):
				f.put("school_chair", c[0] - 0.45, c[1] - 0.78, 0, 1)
				f.put("school_chair", c[0] + 0.45, c[1] + 0.78, 0, -1)
				break
	f.put("vending", f.half("vending"), f.D - 3.5, 1, 0)
	f.put("bin", f.W - 0.35, 0.5, -1, 0)
	f.mount_left("wall_clock", 1.5)
