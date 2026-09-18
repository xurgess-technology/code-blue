extends RefCounted
## The neutral area outside the main doors (sweep 4A chunk 2: the fog lot). Sidewalk and canopy,
## the ambulance bay and faded stall lines. Nothing else: the dumpster and the gold pile are gone
## (chunk 3: selling is the crematorium furnace and buying is the pharmacy, both off the lobby,
## not out here). Past the lot's edge is thick fog (`scripts/level/fog_ring.gd`), not a fence, and
## the ambulance is a driven vehicle (`scripts/loop/shift_loop.gd`), not a parked prop.
##
## A rectangle of outdoor ground, OUT_W x OUT_H tiles, centred on the main doors. Lit by street
## lights, never dark, never a monster spawn.

const S := preload("res://scripts/level/level_state.gd")
const Defs := preload("res://scripts/level/piece_defs.gd")
const Rng := preload("res://scripts/level/rng.gd")

const OUT_W := 44
const OUT_H := 18
const N := Vector2(0, -1)
const SOUTH := Vector2(0, 1)
const E := Vector2(1, 0)
const WEST := Vector2(-1, 0)


## `door_x` is the tile-space x of the centre of the main doors; `oy` the first outdoor row.
## `rng` is kept in the signature (mapgen still hands us the run's own stream) even though the
## lot no longer scatters cars from it.
static func build(st: S, door_x: float, oy: int, rng: Rng) -> Rect2i:
	var ox := int(door_x) - 22
	var rect := Rect2i(ox, oy, OUT_W, OUT_H)
	st.carve_rect(rect, S.CH_OUT, S.ZONE_OUTDOOR)
	# No fence: the lot just runs out into fog (fog_ring.gd computes the belt from neutral_rect
	# at runtime), and the map border wall a few metres further out is never reached.

	var at := func(c: float, r: float) -> Vector2:
		return Vector2(ox + c, oy + r)
	var put := func(kind: String, c: float, r: float, face: Vector2, extra := {}) -> bool:
		return st.put(kind, at.call(c, r), Defs.yaw_facing(face), -1, extra)

	# Keep the walk from the doors to the plaza clear.
	for r in range(0, 12):
		for c in range(20, 25):
			st.set_keep(ox + c, oy + r)

	# ---- sidewalk, canopy ------------------------------------------------------------------
	st.spots["canopy"] = {"rect": Rect2(at.call(12.0, 0.0), Vector2(20.0, 3.6))}
	for c in [12.4, 18.6, 25.4, 31.6]:
		put.call("bollard", c, 3.4, SOUTH, {"canopy_post": true})

	# ---- by the doors: benches, bins, a wheelchair somebody left (2026-09-17, exterior pass) -----
	# The planters against the wall, the signs and the storeys above are level/exterior.gd.
	put.call("outdoor_bench", 14.8, 1.7, SOUTH)
	put.call("outdoor_bench", 17.3, 1.7, SOUTH)
	put.call("bin", 18.9, 0.9, SOUTH)
	put.call("bin", 25.4, 0.9, SOUTH)
	put.call("wheelchair", 25.9, 2.5, Vector2(0.8, 0.6).normalized())

	# ---- ambulance bay: a marking and a lane, no parked prop --------------------------------
	# The ambulance itself is a driven vehicle now (shift_loop.gd / ambulance.gd), not a static
	# piece. `ambulance.position` is the bay parking spot; the lane runs south into the fog.
	st.spots["ambulance"] = {"pos": at.call(28.0, 3.1), "yaw": Defs.yaw_facing(N),
			"lane_start": at.call(28.0, float(OUT_H) - 1.0)}
	st.spots["bay_marking"] = {"pos": at.call(28.0, 6.8), "yaw": 0.0}

	# ---- parking lot (west): faded stall lines, no cars -------------------------------------
	var stalls: Array = []
	for i in 7:
		stalls.append({"pos": Vector2(2.0 + i * 2.0, 7.3), "face": N})
		stalls.append({"pos": Vector2(2.0 + i * 2.0, 13.7), "face": SOUTH})
	st.spots["stalls"] = []
	for s in stalls:
		(st.spots["stalls"] as Array).append({"pos": at.call(s.pos.x, s.pos.y), "yaw": Defs.yaw_facing(s.face)})


	# ---- street lights: bright, warm, steady -------------------------------------------------
	# SWEEP 4A FOLLOW-UP (fog lot, chunk 2): kept within FogRing.inner_rect's clear area (roughly
	# x in [MARGIN_M/TILE, OUT_W - MARGIN_M/TILE], y in [0, OUT_H - MARGIN_M/TILE], no margin on
	# the entrance/north side). The old parking-lot layout lit the outer edge tiles directly, which
	# lit up the border wall itself and defeated the fog belt around it; a few lamps over the
	# walkable plaza is what the doc actually asks for ("keep... a few street lights").
	var lamps := [
		# 2026-09-17: the clear area is a half-oval now (fog_ring.gd), so the far corners are fog: the
		# two outer lamps there stand further in.
		[Vector2(6.0, 4.0), E], [Vector2(10.0, 8.0), E],
		[Vector2(38.0, 4.0), WEST], [Vector2(34.0, 8.0), WEST],
		[Vector2(15.0, 9.5), SOUTH], [Vector2(31.0, 8.5), SOUTH],
		# 2026-09-17: the walk in from the fog, lit both sides from the fog's edge to the canopy
		# (runs start out there now, game._arrive_at_start), and the middle of each half of the lot.
		[Vector2(18.5, 7.5), E], [Vector2(25.5, 7.5), WEST],
		[Vector2(18.5, 11.5), E], [Vector2(25.5, 11.5), WEST],
		[Vector2(11.0, 8.0), SOUTH], [Vector2(33.0, 5.5), SOUTH],
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
