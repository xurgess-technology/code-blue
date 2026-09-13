extends RefCounted
## The neutral area outside the main doors: sidewalk and canopy, the ambulance bay, a parking
## lot with the shop van, the sell bin and an open plaza where the gold bars stack.
##
## A fenced rectangle of outdoor ground, OUT_W x OUT_H tiles, centred on the main doors.
## Lit by street lights, never dark, never a monster spawn.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Rng := preload("res://scripts/level/rng.gd")

const OUT_W := 44
const OUT_H := 18
const N := Vector2(0, -1)
const SOUTH := Vector2(0, 1)
const E := Vector2(1, 0)
const WEST := Vector2(-1, 0)

const CAR_KINDS := ["sedan", "suv", "hatchback", "covered_car", "sedan", "suv"]


## `door_x` is the tile-space x of the centre of the main doors; `oy` the first outdoor row.
static func build(st: S, door_x: float, oy: int, rng: Rng) -> Rect2i:
	var ox := int(door_x) - 22
	var rect := Rect2i(ox, oy, OUT_W, OUT_H)
	st.carve_rect(rect, S.CH_OUT, S.ZONE_OUTDOOR)
	# Fence on the three open sides.
	for y in range(oy, oy + OUT_H + 1):
		for x in [ox - 1, ox + OUT_W]:
			st.set_c(x, y, S.CH_FENCE)
			st.zone[st.idx(x, y)] = S.ZONE_OUTDOOR
	for x in range(ox - 1, ox + OUT_W + 1):
		st.set_c(x, oy + OUT_H, S.CH_FENCE)
		st.zone[st.idx(x, oy + OUT_H)] = S.ZONE_OUTDOOR

	var at := func(c: float, r: float) -> Vector2:
		return Vector2(ox + c, oy + r)
	var put := func(kind: String, c: float, r: float, face: Vector2, extra := {}) -> bool:
		return st.put(kind, at.call(c, r), Defs.yaw_facing(face), -1, extra)

	# Keep the walk from the doors to the plaza clear.
	for r in range(0, 12):
		for c in range(20, 25):
			st.set_keep(ox + c, oy + r)

	# ---- sidewalk, canopy, bollards ------------------------------------------------------
	st.spots["canopy"] = {"rect": Rect2(at.call(12.0, 0.0), Vector2(20.0, 3.6))}
	for c in [12.4, 18.6, 25.4, 31.6]:
		put.call("bollard", c, 3.4, SOUTH, {"canopy_post": true})
	for c in range(2, 13, 2):
		put.call("bollard", c + 0.5, 3.2, SOUTH)
	for c in range(35, 43, 2):
		put.call("bollard", c + 0.5, 3.2, SOUTH)
	put.call("outdoor_bench", 7.0, 0.45, SOUTH)
	put.call("outdoor_bench", 38.5, 0.45, SOUTH)

	# ---- sell bin: a steel dumpster against the facade east of the canopy -----------------
	put.call("dumpster", 34.8, Defs.size("dumpster").z * 0.5 / Defs.TILE + 0.05, SOUTH)
	var bin_pos: Vector2 = at.call(34.8, Defs.size("dumpster").z / Defs.TILE + 0.45)
	st.spots["sell_bin"] = {"pos": at.call(34.8, Defs.size("dumpster").z * 0.5 / Defs.TILE + 0.05), "yaw": Defs.yaw_facing(SOUTH), "front": bin_pos}

	# ---- ambulance bay --------------------------------------------------------------------
	var amb_len := Defs.size("ambulance").z / Defs.TILE
	put.call("ambulance", 28.0, 3.6 + amb_len * 0.5, SOUTH)
	st.spots["ambulance"] = {"pos": at.call(28.0, 3.1), "yaw": Defs.yaw_facing(N), "vehicle": at.call(28.0, 3.6 + amb_len * 0.5)}
	put.call("cone", 26.2, 9.4, N)
	put.call("cone", 29.8, 9.4, N)
	st.spots["bay_marking"] = {"pos": at.call(28.0, 6.8), "yaw": 0.0}

	# ---- parking lot (west): two rows of stalls ------------------------------------------
	var stalls: Array = []
	for i in 7:
		stalls.append({"pos": Vector2(2.0 + i * 2.0, 7.3), "face": N})
		stalls.append({"pos": Vector2(2.0 + i * 2.0, 13.7), "face": SOUTH})
	st.spots["stalls"] = []
	for s in stalls:
		(st.spots["stalls"] as Array).append({"pos": at.call(s.pos.x, s.pos.y), "yaw": Defs.yaw_facing(s.face)})
	rng.shuffle(stalls)
	var cars := rng.rint(4, 6)
	for i in cars:
		var s: Dictionary = stalls[i]
		put.call(CAR_KINDS[rng.rint(0, CAR_KINDS.size() - 1)], s.pos.x, s.pos.y, s.face)

	# ---- shop van at the east end of the lot, back doors open to the plaza ----------------
	var van_len := Defs.size("van").z / Defs.TILE
	put.call("van", 17.6, 10.5, WEST)
	var rear := 17.6 + van_len * 0.5
	st.spots["shop"] = {"pos": at.call(rear + 0.55, 10.5), "yaw": Defs.yaw_facing(E), "vehicle": at.call(17.6, 10.5)}
	put.call("shop_crates", rear + 0.2, 12.0, E)
	put.call("cone", rear + 0.5, 8.6, E)

	# ---- plaza: where the gold bars stack -------------------------------------------------
	st.spots["gold_pile"] = {"pos": at.call(25.0, 12.5), "yaw": 0.0}
	put.call("pallet", 25.0, 12.5, N)
	for c in range(23, 28):
		for r in range(11, 15):
			st.set_keep(ox + c, oy + r)
	var spawns: Array = []
	for p in [Vector2(21.0, 15.5), Vector2(23.0, 16.2), Vector2(27.0, 16.2), Vector2(29.0, 15.5),
			Vector2(22.0, 10.0), Vector2(28.5, 12.0), Vector2(20.5, 13.0), Vector2(30.0, 13.8)]:
		spawns.append(at.call(p.x, p.y))
		st.set_keep(int(ox + p.x), int(oy + p.y))
	st.spots["neutral_spawns"] = spawns

	# ---- east side: barriers, a bench, a second, empty ambulance slot ----------------------
	put.call("barrier", 38.0, 9.0, WEST)
	put.call("barrier", 38.0, 11.0, WEST)
	put.call("cone", 40.5, 14.5, N)
	put.call("outdoor_bench", 43.6 - Defs.size("outdoor_bench").z * 0.5 / Defs.TILE, 13.0, WEST)

	# ---- street lights: bright, warm, steady ------------------------------------------------
	var lamps := [
		[Vector2(0.4, 4.5), E], [Vector2(0.4, 16.8), E], [Vector2(5.0, 10.5), SOUTH], [Vector2(12.0, 10.5), SOUTH],
		[Vector2(43.6, 4.5), WEST], [Vector2(43.6, 16.8), WEST], [Vector2(25.0, 17.6), N],
		[Vector2(36.6, 10.0), WEST], [Vector2(17.0, 17.6), N], [Vector2(33.0, 17.6), N],
	]
	for l in lamps:
		put.call("street_light", l[0].x, l[0].y, l[1], {"lamp": true})
		var head: Vector2 = at.call(l[0].x, l[0].y) + (l[1] as Vector2) * 1.25
		st.lights.append({"tile": Vector2i(int(floor(head.x)), int(floor(head.y))), "pos": head, "zone": S.ZONE_OUTDOOR,
				"mode": 0, "kind": "street"})
	for c in [17.0, 29.0]:
		var p: Vector2 = at.call(c, 1.6)
		st.lights.append({"tile": Vector2i(int(floor(p.x)), int(floor(p.y))), "pos": p, "zone": S.ZONE_OUTDOOR,
				"mode": 0, "kind": "canopy"})
	return rect
