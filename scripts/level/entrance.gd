extends RefCounted
## The entrance building: a fixed plan, 28 x 20 tiles (42 x 30 m), stamped at (ox, oy).
##
##   row 0      north wall, doorways to the north wing(s)
##   rows 1-2   main hall, doorways to the west and east wings at either end
##   rows 4-8   break room (time clock, phone, lectern, pod, player spawns) | spine | OR | scrub room
##   rows 10-12 locker room                                                 | spine | OR | scrub room
##   rows 14-18 lobby, reception, waiting chairs
##   row 19     south wall with the main doors (cols 12-15) onto the neutral area
##
## Monsters never spawn here and nothing a case needs is ever placed here.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")

const W := 28
const H := 20
const N := Vector2(0, -1)
const SOUTH := Vector2(0, 1)
const E := Vector2(1, 0)
const WEST := Vector2(-1, 0)

## Rows of the doorways to the west and east wings.
const SIDE_DOOR_ROWS := [1, 2]
## Doorway columns on the north wall for one or two north wings.
const NORTH_DOORS_ONE := [13, 14]
const NORTH_DOORS_TWO := [[6, 7], [20, 21]]
const MAIN_DOORS := [12, 13, 14, 15]
## Tile-space x of the middle of the main doors, relative to the building.
const DOOR_X := 14.0


static func build(st: S, ox: int, oy: int, north_wings: int) -> void:
	var z := S.ZONE_ENTRANCE
	# Everything inside the footprint belongs to the entrance zone, walls included, so the
	# builder can tell its walls and ceilings from the wings'.
	for y in H:
		for x in W:
			st.zone[st.idx(ox + x, oy + y)] = z
	var carve := func(x0: int, y0: int, w: int, h: int) -> void:
		st.carve_rect(Rect2i(ox + x0, oy + y0, w, h), S.CH_FLOOR, z)
	carve.call(1, 1, 26, 2)     # hall
	carve.call(10, 3, 3, 11)    # spine, from the hall down into the lobby
	var break_room := st.add_room(Rect2i(ox + 1, oy + 4, 8, 5), "break_room", z, "entrance", 0)
	var lockers := st.add_room(Rect2i(ox + 1, oy + 10, 8, 3), "locker_room", z, "entrance", 0)
	var or_room := st.add_room(Rect2i(ox + 14, oy + 4, 9, 9), "or", z, "entrance", 0)
	var scrub := st.add_room(Rect2i(ox + 24, oy + 4, 3, 9), "scrub_room", z, "entrance", 0)
	var lobby := st.add_room(Rect2i(ox + 1, oy + 14, 26, 5), "lobby", z, "entrance", 0)

	var door := func(x: int, y: int, room: int, entry: Vector2i) -> void:
		st.set_c(ox + x, oy + y, S.CH_DOOR)
		if room >= 0:
			(st.rooms[room].doors as Array).append(Vector2i(ox + x, oy + y))
			if not st.rooms[room].has("entry"):
				st.rooms[room]["entry"] = Vector2i(ox + entry.x, oy + entry.y)
			st.set_keep(ox + entry.x, oy + entry.y)
	door.call(9, 6, break_room, Vector2i(8, 6))
	door.call(4, 3, break_room, Vector2i(4, 4))
	door.call(9, 11, lockers, Vector2i(8, 11))
	door.call(13, 7, or_room, Vector2i(14, 7))
	door.call(13, 8, or_room, Vector2i(14, 8))
	door.call(23, 5, scrub, Vector2i(24, 5))
	st.set_keep(ox + 22, oy + 5)
	door.call(25, 13, scrub, Vector2i(25, 12))
	st.set_keep(ox + 25, oy + 14)
	for c in MAIN_DOORS:
		door.call(c, 19, lobby, Vector2i(c, 18))
	st.rooms[lobby]["entry"] = Vector2i(ox + 13, oy + 18)
	# Wing doorways: the wing side of each is carved by the wing generator.
	for y in SIDE_DOOR_ROWS:
		st.set_c(ox, oy + y, S.CH_DOOR)
		st.set_c(ox + W - 1, oy + y, S.CH_DOOR)
		st.set_keep(ox + 1, oy + y)
		st.set_keep(ox + W - 2, oy + y)
	var north_cols: Array = []
	if north_wings == 1:
		north_cols.append_array(NORTH_DOORS_ONE)
	else:
		for pair in NORTH_DOORS_TWO:
			north_cols.append_array(pair)
	for c in north_cols:
		st.set_c(ox + c, oy, S.CH_DOOR)
		st.set_keep(ox + c, oy + 1)
		st.set_keep(ox + c, oy + 2)
	# Keep the spine and its junctions clear.
	for y in range(1, 14):
		for c in range(10, 13):
			st.set_keep(ox + c, oy + y)
	for c in range(9, 14):
		st.set_keep(ox + c, oy + 14)
	for c in MAIN_DOORS:
		st.set_keep(ox + c, oy + 17)

	var put := func(kind: String, x: float, y: float, face: Vector2, room := -1, extra := {}) -> bool:
		return st.put(kind, Vector2(ox + x, oy + y), Defs.yaw_facing(face), room, extra)
	var depth := func(kind: String) -> float:
		return Defs.size(kind).z * 0.5 / Defs.TILE + 0.01

	# ---- break room (x 1-8, y 4-8) ------------------------------------------------------
	var spawns: Array[Vector2i] = [Vector2i(3, 5), Vector2i(2, 6), Vector2i(3, 7), Vector2i(7, 7)]
	for p in spawns:
		st.set_c(ox + p.x, oy + p.y, S.CH_PLAYER)
		st.set_keep(ox + p.x, oy + p.y)
	put.call("time_clock", 1.0 + depth.call("time_clock"), 5.5, E, break_room)
	st.spots["clock"] = {"pos": Vector2(ox + 1.0 + depth.call("time_clock"), oy + 5.5), "yaw": Defs.yaw_facing(E)}
	put.call("notice_board", 1.0, 6.7, E, break_room)
	put.call("wall_phone", 1.0, 7.9, E, break_room)
	st.spots["phone"] = {"pos": Vector2(ox + 1.0, oy + 7.9), "yaw": Defs.yaw_facing(E),
			"height": Defs.mount_height("wall_phone") + Defs.size("wall_phone").y * 0.5}
	put.call("regen_pod", 8.3, 4.7, SOUTH, break_room)
	st.spots["pod"] = {"pos": Vector2(ox + 8.3, oy + 4.7), "yaw": Defs.yaw_facing(SOUTH)}
	put.call("sofa", 6.4, 4.0 + depth.call("sofa"), SOUTH, break_room)
	put.call("wall_clock", 2.6, 4.0, SOUTH, break_room)
	put.call("fridge_kitchen", 1.4, 9.0 - depth.call("fridge_kitchen"), N, break_room)
	put.call("kitchen_counter_sink", 2.55, 9.0 - depth.call("kitchen_counter"), N, break_room)
	put.call("kitchen_counter_coffee", 3.55, 9.0 - depth.call("kitchen_counter"), N, break_room)
	put.call("break_table", 5.3, 6.4, N, break_room)
	for c in [Vector2(4.75, 5.72), Vector2(5.85, 5.72)]:
		put.call("visitor_chair", c.x, c.y, SOUTH, break_room)
	for c in [Vector2(4.75, 7.08), Vector2(5.85, 7.08)]:
		put.call("visitor_chair", c.x, c.y, N, break_room)
	put.call("tv_wall", 7.6, 9.0, N, break_room)
	put.call("plant", 8.6, 8.6, N, break_room)
	var lectern_pos := Vector2(ox + 5.7, oy + 9.0 - 0.32 / Defs.TILE)
	st.spots["lectern"] = {"pos": lectern_pos, "yaw": Defs.yaw_facing(N)}
	st.blocked[st.idx(ox + 5, oy + 8)] = 1

	# ---- locker room (x 1-8, y 10-12) ----------------------------------------------------
	for i in 5:
		put.call("lockers", 1.75 + i * 1.02, 10.0 + depth.call("lockers"), SOUTH, lockers)
	put.call("bench", 4.2, 11.85, N, lockers)
	put.call("wall_sink", 1.0 + depth.call("wall_sink"), 12.2, E, lockers)
	put.call("bin", 7.3, 12.6, N, lockers)

	# ---- operating room (x 14-22, y 4-12) --------------------------------------------------
	var tables := [
		{"pos": Vector2(ox + 16.2, oy + 5.5), "kind": "patient"},
		{"pos": Vector2(ox + 20.8, oy + 5.5), "kind": "patient"},
		{"pos": Vector2(ox + 18.5, oy + 10.5), "kind": "player"},
	]
	st.spots["tables"] = []
	for t in tables:
		st.put("or_table", t.pos, 0.0, or_room, {"table": t.kind})
		st.put("surgical_lamp", t.pos, 0.0, or_room)
		(st.spots["tables"] as Array).append({"pos": t.pos, "yaw": 0.0, "kind": t.kind})
	# The supply shelf stands against the north wall between the two patient tables.
	st.spots["shelf"] = {"pos": Vector2(ox + 18.5, oy + 4.0 + 0.25 / Defs.TILE), "yaw": Defs.yaw_facing(SOUTH)}
	st.blocked[st.idx(ox + 18, oy + 4)] = 1
	st.spots["or_screen"] = {"pos": Vector2(ox + 23.0, oy + 8.6), "yaw": Defs.yaw_facing(WEST),
			"height": Defs.mount_height("or_screen_mount") + Defs.size("or_screen_mount").y * 0.5,
			"size": Vector2(Defs.size("or_screen_mount").x, Defs.size("or_screen_mount").y)}
	put.call("or_screen_mount", 23.0, 8.6, WEST, or_room)
	put.call("anesthesia_cart", 14.55, 5.2, E, or_room)
	put.call("anesthesia_cart", 22.45, 5.2, WEST, or_room)
	put.call("instrument_cart", 16.2, 7.35, N, or_room)
	put.call("instrument_cart", 20.8, 7.35, N, or_room)
	put.call("crash_cart", 22.4, 11.6, WEST, or_room)
	put.call("glass_cabinet", 15.0, 13.0 - depth.call("glass_cabinet"), N, or_room)
	put.call("glass_cabinet", 16.3, 13.0 - depth.call("glass_cabinet"), N, or_room)
	put.call("wall_clock", 21.0, 4.0, SOUTH, or_room)
	put.call("bin", 14.35, 12.6, E, or_room)

	# ---- scrub room (x 24-26, y 4-12) -------------------------------------------------------
	for y in [7.0, 8.5, 10.0]:
		put.call("scrub_sink", 27.0 - depth.call("scrub_sink"), y, WEST, scrub)
	put.call("storage_cabinet", 24.0 + depth.call("storage_cabinet"), 9.5, E, scrub)
	put.call("gurney", 24.55, 11.4, N, scrub)
	put.call("wall_clock", 25.5, 4.0, SOUTH, scrub)

	# ---- lobby (x 1-26, y 14-18) ---------------------------------------------------------
	put.call("reception_desk", 20.5, 15.25, SOUTH, lobby)
	put.call("office_chair", 20.5, 14.5, SOUTH, lobby)
	for x in [2.4, 3.7, 5.0, 6.3]:
		put.call("chair_row", x, 15.9, N, lobby)
		put.call("chair_row", x, 17.3, N, lobby)
	put.call("tv_wall", 4.4, 14.0, SOUTH, lobby)
	put.call("magazine_table", 8.3, 16.6, N, lobby)
	put.call("plant", 1.4, 14.45, SOUTH, lobby)
	put.call("plant", 26.6, 14.45, SOUTH, lobby)
	put.call("plant", 11.4, 18.5, N, lobby)
	put.call("plant", 16.6, 18.5, N, lobby)
	put.call("vending", 8.6, 14.0 + depth.call("vending"), SOUTH, lobby)
	put.call("directory_board", 15.0, 14.0, SOUTH, lobby)
	put.call("wall_clock", 23.5, 14.0, SOUTH, lobby)
	put.call("doormat", DOOR_X, 18.55, N, lobby)
	st.spots["entrance"] = {"pos": Vector2(ox + DOOR_X, oy + 19.5), "yaw": Defs.yaw_facing(SOUTH)}

	# ---- hall and spine ------------------------------------------------------------------
	put.call("bench", 7.5, 1.0 + depth.call("bench"), SOUTH)
	put.call("bench", 20.5, 1.0 + depth.call("bench"), SOUTH)
	put.call("plant", 9.5, 2.6, N)
	put.call("plant", 18.5, 2.6, N)
	put.call("extinguisher", 3.0, 3.0, N)
	put.call("wall_clock", 16.5, 1.0, SOUTH)
	put.call("security_camera", 12.95, 3.3, WEST)

	# ---- lights -------------------------------------------------------------------------
	# The OR is always lit, and brighter than anywhere else: the one room that still works.
	for p in [Vector2i(16, 6), Vector2i(21, 6), Vector2i(18, 10)]:
		st.lights.append({"tile": Vector2i(ox + p.x, oy + p.y), "zone": z, "mode": 0, "bright": true})
	for p in [Vector2i(3, 6), Vector2i(7, 7), Vector2i(4, 11), Vector2i(25, 8), Vector2i(5, 16), Vector2i(14, 16),
			Vector2i(22, 16), Vector2i(4, 1), Vector2i(11, 2), Vector2i(17, 1), Vector2i(23, 2), Vector2i(11, 6),
			Vector2i(11, 11)]:
		st.lights.append({"tile": Vector2i(ox + p.x, oy + p.y), "zone": z, "mode": -1})
