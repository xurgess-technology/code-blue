extends RefCounted
## The entrance building (the hub): a fixed plan, 33 x 33 tiles (49.5 x 49.5 m), stamped at (ox, oy).
## Laid out after Zach's floorplan (hospital-entrance-floorplan_2.html, 2026-09-16), 1 tile = 1.5 m:
##
##   row 0       north wall, the gate into the north wing (cols 16-17)
##   rows 1-4    the hallway, gates into the west and east wings at either end (rows 2-3)
##   rows 6-12   OR (supply storage closet + locker alcove on its west side) | spine | crematorium
##   rows 14-18  break room                                                  | spine | unassigned
##   rows 20-28  waiting room | lobby (triage desk, the phone) | pharmacy behind its wall and window
##   rows 30-31  vestibule (cols 18-21), main doors in row 32 (cols 19-20) onto the neutral area
##
##   cols 1-13 the west rooms, col 14 wall, cols 15-17 the spine, col 18 wall, cols 19-31 the east rooms
##
## Chunk 1 of the hub rebuild is the building: walls, rooms, doors and today's working pieces in
## their new places. The OR's three monitored tables, the triage desk and its phone, the waiting
## room's Night Nurse, the pharmacy's bars and pickup drawer, the break room's wall terminal and the
## hallway's bodies, blood and dead lights (chunk 5).
##
## Monsters never spawn here and nothing a case needs is ever placed here.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")

const W := 33
const H := 33
const N := Vector2(0, -1)
const SOUTH := Vector2(0, 1)
const E := Vector2(1, 0)
const WEST := Vector2(-1, 0)

## Rows of the doorways to the west and east wings (the hallway's two ends).
const SIDE_DOOR_ROWS := [2, 3]
## Doorway columns on the north wall for the north wing, at the top of the spine.
const NORTH_DOORS := [16, 17]
const MAIN_DOORS := [19, 20]
## Tile-space x of the middle of the main doors, relative to the building.
const DOOR_X := 20.0
## The OR's double doors onto the spine.
const OR_DOORS := [Vector2i(14, 8), Vector2i(14, 9)]
## Every room kind the hub registers (all safe: no loot, no case supplies, no monsters).
const ROOM_KINDS := ["or", "or_storage", "or_lockers", "hub_crematorium", "break_room", "hub_unassigned",
		"hub_waiting", "lobby", "hub_pharmacy"]


static func build(st: S, ox: int, oy: int) -> void:
	var z := S.ZONE_ENTRANCE
	# Everything inside the footprint belongs to the entrance zone, walls included, so the
	# builder can tell its walls and ceilings from the wings'.
	for y in H:
		for x in W:
			st.zone[st.idx(ox + x, oy + y)] = z
	var carve := func(x0: int, y0: int, w: int, h: int) -> void:
		st.carve_rect(Rect2i(ox + x0, oy + y0, w, h), S.CH_FLOOR, z)
	var room := func(x0: int, y0: int, w: int, h: int, kind: String) -> int:
		return st.add_room(Rect2i(ox + x0, oy + y0, w, h), kind, z, "entrance", 0)

	# ---- floor that belongs to no room ------------------------------------------------------
	carve.call(1, 1, 31, 4)     # the hallway
	carve.call(15, 5, 3, 15)    # the spine, hallway to lobby
	carve.call(12, 23, 1, 3)    # the wide opening between the waiting room and the lobby
	carve.call(23, 20, 1, 9)    # the pharmacy's barred front (economy_props.gd builds the bars in it)
	carve.call(29, 8, 1, 2)     # the furnace window through the crematorium's east wall
	carve.call(30, 8, 2, 2)     # the sealed fire chamber behind it (furnace.gd builds both)
	carve.call(18, 29, 4, 1)    # lobby into the vestibule
	carve.call(18, 30, 4, 2)    # the vestibule

	# ---- rooms --------------------------------------------------------------------------------
	var storage: int = room.call(1, 6, 3, 3, "or_storage")
	var locker_bay: int = room.call(1, 10, 4, 3, "or_lockers")   # open to the OR, no wall between
	var or_room: int = room.call(5, 6, 9, 7, "or")
	var crematorium: int = room.call(19, 6, 10, 7, "hub_crematorium")
	var break_room: int = room.call(1, 14, 13, 5, "break_room")
	var unassigned: int = room.call(19, 14, 13, 5, "hub_unassigned")
	var waiting: int = room.call(1, 20, 11, 9, "hub_waiting")
	var lobby: int = room.call(13, 20, 10, 9, "lobby")
	var pharmacy: int = room.call(24, 20, 8, 9, "hub_pharmacy")

	var door := func(x: int, y: int, r: int, entry: Vector2i) -> void:
		st.set_c(ox + x, oy + y, S.CH_DOOR)
		if r >= 0:
			(st.rooms[r].doors as Array).append(Vector2i(ox + x, oy + y))
			if not st.rooms[r].has("entry"):
				st.rooms[r]["entry"] = Vector2i(ox + entry.x, oy + entry.y)
			st.set_keep(ox + entry.x, oy + entry.y)
	for t in OR_DOORS:
		door.call(t.x, t.y, or_room, Vector2i(t.x - 1, t.y))
		st.set_keep(ox + t.x + 1, oy + t.y)
	door.call(18, 8, crematorium, Vector2i(19, 8))
	door.call(18, 9, crematorium, Vector2i(19, 9))
	door.call(4, 7, storage, Vector2i(3, 7))
	st.set_keep(ox + 5, oy + 7, 2)   # its door swings out into the OR
	st.set_keep(ox + 5, oy + 6)
	st.set_keep(ox + 5, oy + 8)
	door.call(14, 16, break_room, Vector2i(13, 16))
	door.call(18, 16, unassigned, Vector2i(19, 16))
	for c in MAIN_DOORS:
		door.call(c, H - 1, lobby, Vector2i(c, H - 2))
	st.rooms[lobby]["entry"] = Vector2i(ox + 19, oy + 28)
	st.rooms[locker_bay]["entry"] = Vector2i(ox + 4, oy + 11)
	st.rooms[waiting]["entry"] = Vector2i(ox + 11, oy + 24)
	st.rooms[pharmacy]["entry"] = Vector2i(ox + 24, oy + 24)

	# Wing doorways: the wing side of each is carved by the wing generator.
	for y in SIDE_DOOR_ROWS:
		st.set_c(ox, oy + y, S.CH_DOOR)
		st.set_c(ox + W - 1, oy + y, S.CH_DOOR)
		st.set_keep(ox + 1, oy + y)
		st.set_keep(ox + W - 2, oy + y)
	for c in NORTH_DOORS:
		st.set_c(ox + c, oy, S.CH_DOOR)
		st.set_keep(ox + c, oy + 1)
		st.set_keep(ox + c, oy + 2)

	# ---- paths that stay clear ------------------------------------------------------------------
	for y in range(1, 20):
		for c in range(15, 18):
			st.set_keep(ox + c, oy + y)
	for y in range(20, 22):
		for c in range(15, 22):
			st.set_keep(ox + c, oy + y)
	for y in range(20, 32):
		for c in range(18, 22):
			st.set_keep(ox + c, oy + y)
	for y in range(23, 26):
		for c in [11, 12, 13]:
			st.set_keep(ox + c, oy + y)
	for y in range(22, 27):
		st.set_keep(ox + 22, oy + y)   # the lobby fax terminal stands out here, in front of the bars
	for y in range(20, 29):
		st.set_keep(ox + 23, oy + y, 2)   # the bars
	for y in range(23, 26):
		st.set_keep(ox + 24, oy + y)      # the attendant and the drawer behind them

	var put := func(kind: String, x: float, y: float, face: Vector2, r := -1, extra := {}) -> bool:
		return st.put(kind, Vector2(ox + x, oy + y), Defs.yaw_facing(face), r, extra)
	var depth := func(kind: String) -> float:
		return Defs.size(kind).z * 0.5 / Defs.TILE + 0.01

	# ---- break room (x 1-13, y 14-18) ------------------------------------------------------------
	var spawns: Array[Vector2i] = [Vector2i(7, 15), Vector2i(8, 16), Vector2i(7, 17), Vector2i(10, 16)]
	for p in spawns:
		st.set_c(ox + p.x, oy + p.y, S.CH_PLAYER)
		st.set_keep(ox + p.x, oy + p.y)
	# The time clock by the door, on the wall the door is in.
	put.call("time_clock", 14.0 - depth.call("time_clock"), 15.0, WEST, break_room)
	st.spots["clock"] = {"pos": Vector2(ox + 14.0 - depth.call("time_clock"), oy + 15.0), "yaw": Defs.yaw_facing(WEST)}
	# Kitchenette along the north wall.
	put.call("kitchen_counter_sink", 1.55, 14.0 + depth.call("kitchen_counter"), SOUTH, break_room)
	put.call("kitchen_counter_coffee", 2.55, 14.0 + depth.call("kitchen_counter"), SOUTH, break_room)
	put.call("fridge_kitchen", 3.6, 14.0 + depth.call("fridge_kitchen"), SOUTH, break_room)
	put.call("wall_clock", 8.0, 14.0, SOUTH, break_room)
	# A small table and chairs.
	put.call("break_table", 4.5, 16.5, N, break_room)
	for c in [Vector2(3.95, 15.8), Vector2(5.05, 15.8)]:
		put.call("visitor_chair", c.x, c.y, SOUTH, break_room)
	for c in [Vector2(3.95, 17.2), Vector2(5.05, 17.2)]:
		put.call("visitor_chair", c.x, c.y, N, break_room)
	# The database terminal (the doc's "computer") against the south wall.
	var lectern_pos := Vector2(ox + 10.0, oy + 19.0 - 0.32 / Defs.TILE)
	st.spots["lectern"] = {"pos": lectern_pos, "yaw": Defs.yaw_facing(N)}
	st.blocked[st.idx(ox + 10, oy + 18)] = 1
	put.call("notice_board", 7.0, 19.0, N, break_room)
	put.call("plant", 12.6, 14.5, SOUTH, break_room)

	# ---- OR (x 5-13, y 6-12), supply storage (x 1-3, y 6-8), locker bay (x 1-4, y 10-12) -----------
	# Chunk 2: three patient tables in a row along the north wall, each with its own monitor on the
	# wall above its head end; a downed teammate goes on whichever is free (game.downed_any_table).
	# On a tile row's centre line: the table (0.7 m deep) only claims its tiles, and so gets its
	# collider, when its footprint reaches a tile's middle.
	var table_x := [7.3, 9.8, 12.2]
	st.spots["tables"] = []
	st.spots["or_screens"] = []
	var mon := "table_monitor_mount"
	for i in table_x.size():
		var tp := Vector2(ox + table_x[i], oy + 7.5)
		st.put("or_table", tp, 0.0, or_room, {"table": "patient"})
		st.put("surgical_lamp", tp, 0.0, or_room)
		(st.spots["tables"] as Array).append({"pos": tp, "yaw": 0.0, "kind": "patient"})
		put.call(mon, table_x[i], 6.0, SOUTH, or_room)
		(st.spots["or_screens"] as Array).append({"pos": Vector2(ox + table_x[i], oy + 6.0), "yaw": Defs.yaw_facing(SOUTH),
				"height": Defs.mount_height(mon) + Defs.size(mon).y * 0.5,
				"size": Vector2(Defs.size(mon).x, Defs.size(mon).y), "table": i})
	st.spots["or_screen"] = (st.spots["or_screens"] as Array)[1]
	put.call("wall_clock", 9.8, 13.0, N, or_room)
	put.call("crash_cart", 10.5, 12.5, N, or_room)
	for y in [10.5, 12.5]:
		put.call("scrub_sink", 14.0 - depth.call("scrub_sink"), y, WEST, or_room)
	put.call("gurney", 8.0, 12.55, E, or_room)
	put.call("bin", 5.5, 12.6, N, or_room)
	# The supply shelf stands in the storage closet, against its north wall.
	st.spots["shelf"] = {"pos": Vector2(ox + 2.0, oy + 6.0 + 0.25 / Defs.TILE), "yaw": Defs.yaw_facing(SOUTH)}
	st.blocked[st.idx(ox + 2, oy + 6)] = 1
	for x in [1.55, 2.55, 3.55]:
		put.call("lockers", x, 13.0 - depth.call("lockers"), N, locker_bay)

	# ---- crematorium (x 19-28, y 6-12) and the unassigned room (x 19-31, y 14-18) ----------------
	# The furnace is built into the east wall (col 29): a grated hatch over a window (rows 8-9, facing
	# the doors) into a sealed 2 x 2 fire chamber (cols 30-31) nobody can walk into. economy.gd builds
	# it at the spot below; its firelight is the room's light. Wide open, nothing else.
	for y in [8, 9]:
		st.set_keep(ox + 28, oy + y)
		st.set_keep(ox + 29, oy + y, 2)

	# ---- waiting room (x 1-11, y 20-28) ------------------------------------------------------------
	for y in [22.5, 24.5, 26.5]:
		for x in [2.5, 3.7, 6.3, 7.5]:
			put.call("chair_row", x, y, N, waiting)
	put.call("tv_wall", 3.1, 20.0, SOUTH, waiting)
	put.call("vending", 9.5, 20.0 + depth.call("vending"), SOUTH, waiting)
	put.call("magazine_table", 10.3, 27.8, N, waiting)
	put.call("plant", 1.5, 28.5, N, waiting)
	# Every seat, for the Night Nurse (economy's WaitingNurse picks one per shift): three to a bench,
	# facing the way the benches face.
	st.spots["waiting_seats"] = []
	for y in [22.5, 24.5, 26.5]:
		for x in [2.5, 3.7, 6.3, 7.5]:
			for off in [-0.4, 0.0, 0.4]:
				(st.spots["waiting_seats"] as Array).append({"pos": Vector2(ox + x + off, oy + y), "yaw": Defs.yaw_facing(N)})

	# Where she goes to stand when she leaves her chair: tucked into the corners, facing the walls.
	st.spots["waiting_corners"] = [
		{"pos": Vector2(ox + 1.35, oy + 20.35), "yaw": Defs.yaw_facing(Vector2(-1, -1))},
		{"pos": Vector2(ox + 11.6, oy + 20.4), "yaw": Defs.yaw_facing(Vector2(1, -1))},
		{"pos": Vector2(ox + 1.35, oy + 27.65), "yaw": Defs.yaw_facing(Vector2(-1, 1))},
		{"pos": Vector2(ox + 11.6, oy + 28.6), "yaw": Defs.yaw_facing(Vector2(1, 1))},
		{"pos": Vector2(ox + 5.4, oy + 20.35), "yaw": Defs.yaw_facing(N)},
	]

	# ---- lobby (x 13-22, y 20-28) and the vestibule -------------------------------------------------
	# SWEEP 4A HOOK (fog lot, chunk 2): the run's start and every respawn are inside the main doors.
	var lobby_spawn_tiles: Array[Vector2i] = [
		Vector2i(18, 27), Vector2i(19, 27), Vector2i(20, 27), Vector2i(21, 27),
		Vector2i(18, 28), Vector2i(19, 28), Vector2i(20, 28), Vector2i(21, 28),
	]
	var lobby_spawns: Array = []
	for t in lobby_spawn_tiles:
		st.set_keep(ox + t.x, oy + t.y)
		lobby_spawns.append(Vector2(ox + t.x + 0.5, oy + t.y + 0.5))
	st.spots["lobby_spawns"] = lobby_spawns
	# Triage (chunk 3): the front counter faces the path in from the doors, so everyone passes it; the
	# desk phone sits on its front edge (loop's phone.gd, desk build) and blinks red while a call waits.
	# Call-center workstations behind it, one each side of the opening to the waiting room.
	put.call("reception_desk", 16.5, 23.5, E, lobby)
	put.call("office_chair", 15.55, 23.5, E, lobby)
	# On the middle of the counter's raised front ledge (piece_factory reception_desk: 1.1 m high, 0.32 m
	# deep, 0.33 m in from the front), at the north end, clear of the potted plant at the south end.
	st.spots["phone"] = {"pos": Vector2(ox + 16.5 + 0.33 / Defs.TILE, oy + 23.5 - 0.9 / Defs.TILE), "yaw": Defs.yaw_facing(E),
			"height": 1.12, "desk": true}
	put.call("office_desk", 14.0, 20.0 + depth.call("office_desk"), SOUTH, lobby)
	put.call("computer", 14.0, 20.3, SOUTH, lobby, {"y": 0.75})
	put.call("office_chair", 14.0, 21.3, N, lobby)
	put.call("office_desk", 15.0, 27.0, N, lobby)
	put.call("computer", 15.0, 27.1, N, lobby, {"y": 0.75})
	put.call("office_chair", 15.0, 26.1, SOUTH, lobby)
	put.call("chair_row", 14.5, 28.5, N, lobby)
	put.call("directory_board", 20.0, 20.0, SOUTH, lobby)
	put.call("wall_clock", 21.6, 20.0, SOUTH, lobby)
	put.call("doormat", DOOR_X, 31.55, N)
	st.spots["entrance"] = {"pos": Vector2(ox + DOOR_X, oy + H + 0.5), "yaw": Defs.yaw_facing(SOUTH)}

	# ---- pharmacy (x 24-31, y 20-28) and the crematorium's furnace ------------------------------------
	# The rects are the rooms' floor ("reserve": mapgen validation and economy.gd key off it). The
	# spots are where economy.gd builds the pharmacy window (in the window in the pharmacy's west
	# wall, its front, +Z, toward the lobby) and the furnace (backed onto the crematorium's east wall,
	# mouth toward its doors). Both props face +Z, so their yaw is the one that turns +Z to face `f`.
	st.spots["reserve"] = {
		"pharmacy": Rect2i(ox + 24, oy + 20, 8, 9),
		"crematorium": Rect2i(ox + 19, oy + 6, 10, 7),
	}
	# Medicine shelves behind the bars, in three long rows facing the lobby.
	for x in [26.5, 28.5, 32.0 - depth.call("med_shelf")]:
		for y in range(21, 28):
			put.call("med_shelf", x, y + 0.5, WEST, pharmacy)
	st.spots["economy_spots"] = {
		# The middle of the barred front (col 23, rows 20-28), the lobby side is +Z.
		"pharmacy": {"pos": Vector2(ox + 23.5, oy + 24.5), "yaw": Defs.yaw_facing(-WEST)},
		# The room-side face of the furnace window (col 29's west face), the middle of rows 8-9.
		"crematorium": {"pos": Vector2(ox + 29.0, oy + 9.0), "yaw": Defs.yaw_facing(-WEST)},
	}

	# ---- the hallway (x 1-31, y 1-4): chunk 5, the dead parked in it --------------------------------
	# Set dressing only. Blocking pieces stay in rows 1 and 4 against the walls, so rows 2-3 are one
	# clear lane end to end; nothing within two tiles of the wing doorways or the spine.
	# West half: a body bag on a gurney, one on the floor with the drag mark it left, a gurney
	# knocked over by the spine with blood beside it.
	put.call("gurney_bag", 5.0, 1.27, E)
	put.call("body_bag", 8.2, 4.62, E)
	put.call("blood_trail", 9.9, 4.45, E)
	put.call("gurney_toppled", 12.0, 1.34, E)
	put.call("blood_pool", 12.4, 2.3, N)
	# East half: a wheelchair left in the lane, a sheeted body on a gurney, another bag, more blood.
	put.call("wheelchair", 20.8, 3.62, Vector2(-0.6, 0.8).normalized())
	put.call("gurney_body", 24.5, 1.27, WEST)
	put.call("blood_pool", 27.6, 4.2, E)
	put.call("gurney_bag", 27.8, 4.73, WEST)
	put.call("body_bag", 29.2, 1.25, WEST)

	# ---- lights -------------------------------------------------------------------------------------
	# The OR is always lit, and brighter than anywhere else: the one room that still works.
	for p in [Vector2i(7, 10), Vector2i(10, 7), Vector2i(12, 10)]:
		st.lights.append({"tile": Vector2i(ox + p.x, oy + p.y), "zone": z, "mode": 0, "bright": true})
	# Chunk 5: the hallway's fixtures are set, not rolled: two flicker, two are dead, the one over the
	# spine still works.
	for l in [[Vector2i(4, 2), 1], [Vector2i(10, 3), 2], [Vector2i(16, 2), 0], [Vector2i(22, 3), 1], [Vector2i(28, 2), 2]]:
		st.lights.append({"tile": Vector2i(ox + l[0].x, oy + l[0].y), "zone": z, "mode": l[1]})
	for p in [Vector2i(2, 7), Vector2i(2, 11), Vector2i(16, 9), Vector2i(16, 16), Vector2i(4, 16),
			Vector2i(10, 16), Vector2i(4, 22), Vector2i(8, 25), Vector2i(4, 27), Vector2i(16, 22), Vector2i(20, 25),
			Vector2i(16, 27), Vector2i(19, 30), Vector2i(27, 22), Vector2i(27, 26)]:
		st.lights.append({"tile": Vector2i(ox + p.x, oy + p.y), "zone": z, "mode": -1})
	# The unassigned room: one fixture, dead. The crematorium: one dead fixture; the fire lights it.
	st.lights.append({"tile": Vector2i(ox + 25, oy + 16), "zone": z, "mode": 2})
	st.lights.append({"tile": Vector2i(ox + 22, oy + 9), "zone": z, "mode": 2})
