extends RefCounted
## The entrance building: a fixed plan, 34 x 24 tiles, stamped at (ox, oy).
##
##   row 0      north wall, doorways to the north wing(s)
##   rows 1-3   main hall, doorways to the west and east wings at either end
##   rows 5-12  break room (time clock, phone, lectern, pod, player spawns) | spine | OR
##   rows 14-17 locker room                                                 | spine | OR
##   rows 19-22 lobby, reception, waiting chairs
##   row 23     south wall with the main doors (cols 15-18) onto the neutral area
##
## Monsters never spawn here and nothing a case needs is ever placed here.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")

const W := 34
const H := 24
const N := Vector2(0, -1)
const SOUTH := Vector2(0, 1)
const E := Vector2(1, 0)
const WEST := Vector2(-1, 0)

## Doorway columns on the north wall for one or two north wings.
const NORTH_DOORS_ONE := [16, 17]
const NORTH_DOORS_TWO := [[7, 8], [25, 26]]
const MAIN_DOORS := [15, 16, 17, 18]


static func build(st: S, ox: int, oy: int, north_wings: int) -> void:
	var z := S.ZONE_ENTRANCE
	# Everything inside the footprint belongs to the entrance zone, walls included, so the
	# builder can tell its walls and ceilings from the wings'.
	for y in H:
		for x in W:
			st.zone[st.idx(ox + x, oy + y)] = z
	var carve := func(x0: int, y0: int, w: int, h: int) -> void:
		st.carve_rect(Rect2i(ox + x0, oy + y0, w, h), S.CH_FLOOR, z)
	carve.call(1, 1, 32, 3)     # hall
	carve.call(14, 4, 6, 15)    # spine, down to the lobby
	var break_room := st.add_room(Rect2i(ox + 1, oy + 5, 12, 8), "break_room", z, "entrance", 0)
	var lockers := st.add_room(Rect2i(ox + 1, oy + 14, 12, 4), "locker_room", z, "entrance", 0)
	var or_room := st.add_room(Rect2i(ox + 21, oy + 5, 12, 13), "or", z, "entrance", 0)
	var lobby := st.add_room(Rect2i(ox + 1, oy + 19, 32, 4), "lobby", z, "entrance", 0)

	var door := func(x: int, y: int, room: int, entry: Vector2i) -> void:
		st.set_c(ox + x, oy + y, S.CH_DOOR)
		if room >= 0:
			(st.rooms[room].doors as Array).append(Vector2i(ox + x, oy + y))
			if not st.rooms[room].has("entry"):
				st.rooms[room]["entry"] = Vector2i(ox + entry.x, oy + entry.y)
			st.set_keep(ox + entry.x, oy + entry.y)
	door.call(13, 8, break_room, Vector2i(12, 8))
	door.call(6, 4, break_room, Vector2i(6, 5))
	door.call(13, 16, lockers, Vector2i(12, 16))
	door.call(20, 14, or_room, Vector2i(21, 14))
	door.call(20, 15, or_room, Vector2i(21, 15))
	for c in MAIN_DOORS:
		door.call(c, 23, lobby, Vector2i(c, 22))
	st.rooms[lobby]["entry"] = Vector2i(ox + 16, oy + 22)
	# Wing doorways: the wing side of each is carved by the wing generator.
	for y in [2, 3]:
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
	# Keep the spine and hall junctions clear.
	for c in range(14, 20):
		st.set_keep(ox + c, oy + 4)
		st.set_keep(ox + c, oy + 18)
	for c in MAIN_DOORS:
		st.set_keep(ox + c, oy + 21)

	var put := func(kind: String, x: float, y: float, face: Vector2, room := -1, extra := {}) -> bool:
		return st.put(kind, Vector2(ox + x, oy + y), Defs.yaw_facing(face), room, extra)
	var depth := func(kind: String) -> float:
		return Defs.size(kind).z * 0.5 / Defs.TILE

	# ---- break room (x 1-12, y 5-12) ----------------------------------------------------
	var clock := Vector2(ox + 1.5, oy + 7.5)
	put.call("time_clock", 1.5, 7.5, E, break_room)
	st.spots["clock"] = {"pos": clock, "yaw": Defs.yaw_facing(E)}
	put.call("notice_board", 1.0, 9.0, E, break_room)
	put.call("wall_phone", 1.0, 10.4, E, break_room)
	st.spots["phone"] = {"pos": Vector2(ox + 1.0, oy + 10.4), "yaw": Defs.yaw_facing(E), "height": Defs.mount_height("wall_phone") + Defs.size("wall_phone").y * 0.5}
	for i in 4:
		put.call("lockers", 1.5 + i, 5.0 + depth.call("lockers"), SOUTH, break_room)
	put.call("wall_clock", 7.5, 5.0, SOUTH, break_room)
	put.call("regen_pod", 11.5, 5.8, SOUTH, break_room)
	st.spots["pod"] = {"pos": Vector2(ox + 11.5, oy + 5.8), "yaw": Defs.yaw_facing(SOUTH)}
	put.call("fridge_kitchen", 1.6, 13.0 - depth.call("fridge_kitchen"), N, break_room)
	put.call("kitchen_counter_sink", 2.75, 13.0 - depth.call("kitchen_counter"), N, break_room)
	put.call("kitchen_counter_coffee", 3.75, 13.0 - depth.call("kitchen_counter"), N, break_room)
	put.call("kitchen_counter", 4.75, 13.0 - depth.call("kitchen_counter"), N, break_room)
	put.call("break_table", 7.0, 9.3, N, break_room)
	for c in [Vector2(6.45, 8.45), Vector2(7.55, 8.45)]:
		put.call("visitor_chair", c.x, c.y, SOUTH, break_room)
	for c in [Vector2(6.45, 10.2), Vector2(7.55, 10.2)]:
		put.call("visitor_chair", c.x, c.y, N, break_room)
	put.call("sofa", 13.0 - depth.call("sofa"), 11.2, WEST, break_room)
	put.call("tv_wall", 7.5, 13.0, N, break_room)
	put.call("plant", 12.6, 12.6, N, break_room)
	var lectern_pos := Vector2(ox + 9.0, oy + 13.0 - 0.3 / Defs.TILE)
	st.spots["lectern"] = {"pos": lectern_pos, "yaw": Defs.yaw_facing(N)}
	st.blocked[st.idx(ox + 9, oy + 12)] = 1
	var spawns: Array[Vector2i] = [Vector2i(3, 8), Vector2i(4, 10), Vector2i(10, 8), Vector2i(10, 10)]
	for p in spawns:
		st.set_c(ox + p.x, oy + p.y, S.CH_PLAYER)
		st.set_keep(ox + p.x, oy + p.y)

	# ---- locker room (x 1-12, y 14-17) --------------------------------------------------
	for i in 10:
		put.call("lockers", 1.5 + i, 14.0 + depth.call("lockers"), SOUTH, lockers)
	put.call("bench", 4.5, 16.1, N, lockers)
	put.call("bench", 8.5, 16.1, N, lockers)
	put.call("wall_sink", 1.0 + depth.call("wall_sink"), 16.5, E, lockers)

	# ---- operating room (x 21-32, y 5-17) -------------------------------------------------
	var tables := [
		{"pos": Vector2(ox + 25.0, oy + 7.0), "kind": "patient"},
		{"pos": Vector2(ox + 29.0, oy + 7.0), "kind": "patient"},
		{"pos": Vector2(ox + 27.0, oy + 12.5), "kind": "player"},
	]
	st.spots["tables"] = []
	for t in tables:
		st.put("or_table", t.pos, 0.0, or_room, {"table": t.kind})
		st.put("surgical_lamp", t.pos, 0.0, or_room)
		(st.spots["tables"] as Array).append({"pos": t.pos, "yaw": 0.0, "kind": t.kind})
	# The supply shelf stands against the north wall between the two patient tables.
	st.spots["shelf"] = {"pos": Vector2(ox + 27.0, oy + 5.0 + 0.25 / Defs.TILE), "yaw": Defs.yaw_facing(SOUTH)}
	st.blocked[st.idx(ox + 26, oy + 5)] = 1
	st.blocked[st.idx(ox + 27, oy + 5)] = 1
	st.spots["or_screen"] = {"pos": Vector2(ox + 33.0, oy + 9.5), "yaw": Defs.yaw_facing(WEST),
			"height": Defs.mount_height("or_screen_mount") + Defs.size("or_screen_mount").y * 0.5,
			"size": Vector2(Defs.size("or_screen_mount").x, Defs.size("or_screen_mount").y)}
	put.call("or_screen_mount", 33.0, 9.5, WEST, or_room)
	put.call("anesthesia_cart", 23.3, 6.3, E, or_room)
	put.call("anesthesia_cart", 30.7, 6.3, WEST, or_room)
	put.call("scrub_sink", 21.0 + depth.call("scrub_sink"), 6.5, E, or_room)
	put.call("scrub_sink", 21.0 + depth.call("scrub_sink"), 8.0, E, or_room)
	put.call("instrument_cart", 27.0, 9.4, N, or_room)
	put.call("crash_cart", 31.9, 12.5, WEST, or_room)
	for x in [23.5, 25.0, 29.0, 30.5]:
		put.call("glass_cabinet", x, 18.0 - depth.call("glass_cabinet"), N, or_room)
	put.call("wall_clock", 30.0, 5.0, SOUTH, or_room)

	# ---- lobby (x 1-32, y 19-22) ---------------------------------------------------------
	put.call("reception_desk", 25.0, 20.2, SOUTH, lobby)
	put.call("office_chair", 25.0, 19.45, SOUTH, lobby)
	for x in [3.0, 4.4, 5.8, 7.2]:
		put.call("chair_row", x, 20.35, N, lobby)
		put.call("chair_row", x, 21.75, N, lobby)
	put.call("tv_wall", 5.1, 19.0, SOUTH, lobby)
	put.call("magazine_table", 9.3, 21.0, N, lobby)
	put.call("plant", 1.4, 19.45, SOUTH, lobby)
	put.call("plant", 32.6, 19.45, SOUTH, lobby)
	put.call("plant", 13.6, 22.5, N, lobby)
	put.call("plant", 20.4, 22.5, N, lobby)
	put.call("vending", 11.3, 19.0 + depth.call("vending"), SOUTH, lobby)
	put.call("directory_board", 21.6, 19.0, SOUTH, lobby)
	put.call("wall_clock", 29.5, 19.0, SOUTH, lobby)
	put.call("doormat", 17.0, 22.55, N, lobby)
	st.spots["entrance"] = {"pos": Vector2(ox + 17.0, oy + 23.5), "yaw": Defs.yaw_facing(SOUTH)}

	# ---- hall and spine ------------------------------------------------------------------
	put.call("bench", 9.0, 1.0 + depth.call("bench"), SOUTH)
	put.call("bench", 25.0, 1.0 + depth.call("bench"), SOUTH)
	put.call("plant", 12.5, 3.5, N)
	put.call("plant", 21.5, 3.5, N)
	put.call("extinguisher", 4.0, 4.0, N)
	put.call("wall_clock", 17.0, 1.0, SOUTH)
	put.call("wheelchair", 14.45, 11.5, E)
	put.call("bench", 20.0 - depth.call("bench"), 9.5, WEST)
	put.call("security_camera", 19.9, 4.2, WEST)

	# ---- lights -------------------------------------------------------------------------
	for p in [Vector2i(4, 7), Vector2i(9, 10), Vector2i(6, 15), Vector2i(25, 7), Vector2i(29, 7),
			Vector2i(27, 12), Vector2i(23, 15), Vector2i(31, 15), Vector2i(5, 20), Vector2i(16, 20),
			Vector2i(27, 21), Vector2i(4, 2), Vector2i(11, 2), Vector2i(17, 2), Vector2i(23, 2),
			Vector2i(29, 2), Vector2i(16, 7), Vector2i(17, 12), Vector2i(16, 16)]:
		st.lights.append({"tile": Vector2i(ox + p.x, oy + p.y), "zone": z, "mode": -1})
