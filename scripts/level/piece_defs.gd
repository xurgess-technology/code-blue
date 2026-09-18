extends RefCounted
## Every furniture and outdoor piece the level generator can place, as data.
##
## Shared by the generator (footprints decide which tiles a piece blocks) and the builder
## (collider size, loose-item anchors, wall mounting). Visuals live in piece_factory.gd.
##
## Frame of every piece: origin on the floor at the centre of its footprint, front toward -Z.
## Wall-mounted pieces: origin on the floor at the wall face, the piece hangs toward -Z at
## `mount` metres (the builder never gives them a collider).
##
## Fields:
##   size    Vector3(width X, height Y, depth Z) in metres
##   block   true when the piece fills the tiles under it (generator connectivity and markers)
##   collide false for things you can walk through or that sit on other furniture
##   mount   wall-mounted, bottom edge height in metres
##   anchors [[Vector3 local offset, surface]] where a loose item may rest; surface is one of
##           "counter", "tray", "gurney" (the builder adds "floor" spots itself)

const TILE := 1.5

const P := {
	# ---- patient rooms ----------------------------------------------------
	"hospital_bed": {"size": Vector3(1.0, 0.72, 2.15), "block": true, "anchors": [[Vector3(0.18, 0.72, -0.45), "gurney"]]},
	"bed_tray": {"size": Vector3(0.8, 1.0, 0.45)},
	"curtain": {"size": Vector3(1.9, 2.45, 0.12), "collide": false},
	"iv_stand": {"size": Vector3(0.45, 1.95, 0.45)},
	"bedside": {"size": Vector3(0.8, 0.58, 0.34), "block": true, "anchors": [[Vector3(0.18, 0.58, 0.0), "tray"]]},
	"visitor_chair": {"size": Vector3(0.45, 0.9, 0.45)},
	"wall_monitor": {"size": Vector3(0.55, 0.42, 0.14), "mount": 1.6},
	"wall_sink": {"size": Vector3(0.55, 0.9, 0.46)},
	"bin": {"size": Vector3(0.36, 0.7, 0.38)},
	# ---- storage ----------------------------------------------------------
	"steel_shelves": {"size": Vector3(0.6, 2.14, 0.5), "block": true},
	"storage_cabinet": {"size": Vector3(0.84, 1.78, 0.53), "block": true},
	"box_stack": {"size": Vector3(0.5, 0.62, 0.5)},
	"counter": {"size": Vector3(1.5, 0.95, 0.7), "block": true, "anchors": [[Vector3(0.0, 0.95, -0.05), "counter"]]},
	"sink_counter": {"size": Vector3(1.5, 0.95, 0.7), "block": true},
	"pharmacy_counter": {"size": Vector3(1.5, 1.08, 0.62), "block": true, "anchors": [[Vector3(0.25, 1.08, 0.08), "counter"]]},
	"med_shelf": {"size": Vector3(1.5, 2.0, 0.45), "block": true},
	# ---- offices, stations, waiting ---------------------------------------
	"office_desk": {"size": Vector3(1.9, 0.75, 0.9), "block": true, "anchors": [[Vector3(-0.55, 0.75, 0.1), "counter"]]},
	"office_chair": {"size": Vector3(0.55, 1.0, 0.52)},
	"filing_cabinet": {"size": Vector3(0.91, 1.51, 0.4), "block": true},
	"bookcase": {"size": Vector3(0.84, 1.85, 0.53), "block": true},
	"whiteboard": {"size": Vector3(1.4, 0.9, 0.05), "mount": 1.0},
	"notice_board": {"size": Vector3(1.2, 0.85, 0.04), "mount": 1.1},
	"chair_row": {"size": Vector3(1.8, 0.85, 0.62), "block": true},
	"school_chair": {"size": Vector3(0.52, 0.93, 0.62)},
	"magazine_table": {"size": Vector3(1.19, 0.41, 0.72), "block": true, "anchors": [[Vector3(0.2, 0.41, 0.0), "counter"]]},
	"reception_desk": {"size": Vector3(3.0, 1.1, 0.9), "block": true, "anchors": [[Vector3(-0.8, 1.1, -0.28), "counter"], [Vector3(0.8, 1.1, -0.28), "counter"]]},
	"tv_wall": {"size": Vector3(1.3, 0.86, 0.24), "mount": 1.75},
	"plant": {"size": Vector3(0.45, 1.31, 0.48)},
	"vending": {"size": Vector3(0.81, 1.97, 0.87), "block": true},
	"med_cart": {"size": Vector3(0.7, 1.05, 0.5), "block": true},
	"computer": {"size": Vector3(0.44, 0.52, 0.5), "collide": false},   # the standard desk computer
	"wheelchair": {"size": Vector3(0.82, 1.1, 1.09), "block": true},
	# ---- restrooms --------------------------------------------------------
	"stall": {"size": Vector3(1.5, 2.0, 1.9), "block": true},
	"hand_dryer": {"size": Vector3(0.3, 0.3, 0.2), "mount": 1.2},
	"mirror": {"size": Vector3(0.57, 0.83, 0.1), "mount": 1.15},
	"coat_rack": {"size": Vector3(0.6, 1.69, 0.6), "collide": false},
	# ---- lab ---------------------------------------------------------------
	"lab_bench": {"size": Vector3(1.5, 0.92, 0.75), "block": true, "anchors": [[Vector3(0.35, 0.92, -0.1), "counter"]]},
	"lab_bench_scope": {"size": Vector3(1.5, 0.92, 0.75), "block": true, "anchors": [[Vector3(0.4, 0.92, -0.12), "counter"]]},
	"lab_island": {"size": Vector3(1.5, 0.92, 1.2), "block": true, "anchors": [[Vector3(-0.3, 0.92, -0.3), "counter"]]},
	"fume_hood": {"size": Vector3(1.5, 2.3, 0.85), "block": true},
	# ---- radiology ----------------------------------------------------------
	"ct_scanner": {"size": Vector3(2.3, 2.0, 3.6), "block": true},
	"console_desk": {"size": Vector3(1.8, 0.76, 0.8), "block": true, "anchors": [[Vector3(0.6, 0.76, 0.05), "counter"]]},
	"lead_partition": {"size": Vector3(1.5, 2.1, 0.16), "block": true},
	"lightbox": {"size": Vector3(1.2, 0.6, 0.08), "mount": 1.3},
	"radiation_sign": {"size": Vector3(0.4, 0.4, 0.02), "mount": 1.5},
	# ---- morgue -------------------------------------------------------------
	"morgue_fridge": {"size": Vector3(1.5, 2.1, 0.9), "block": true},
	"morgue_fridge_open": {"size": Vector3(1.5, 2.1, 0.9), "block": true},
	"autopsy_table": {"size": Vector3(0.85, 0.92, 2.1), "block": true, "anchors": [[Vector3(0.0, 0.92, 0.65), "gurney"]]},
	"covered_body": {"size": Vector3(0.6, 0.35, 1.8), "collide": false},
	"gurney": {"size": Vector3(0.75, 0.85, 2.0), "block": true, "anchors": [[Vector3(0.0, 0.85, 0.0), "gurney"]]},
	"gurney_body": {"size": Vector3(0.75, 1.1, 2.0), "block": true},
	# Hub rebuild, chunk 5: the hallway's dead (set dressing, no mechanics).
	"gurney_bag": {"size": Vector3(0.75, 1.05, 2.0), "block": true},
	"body_bag": {"size": Vector3(0.62, 0.3, 1.95), "collide": false},
	"gurney_toppled": {"size": Vector3(0.9, 0.75, 2.0), "block": true},
	"blood_trail": {"size": Vector3(0.7, 0.02, 3.0), "collide": false},
	"blood_pool": {"size": Vector3(1.2, 0.02, 1.0), "collide": false},
	"instrument_cart": {"size": Vector3(1.27, 0.96, 0.75), "block": true, "anchors": [[Vector3(0.0, 0.96, 0.0), "tray"]]},
	# ---- janitor ------------------------------------------------------------
	"mop_sink": {"size": Vector3(0.9, 0.55, 0.7), "block": true},
	"mop_bucket": {"size": Vector3(0.45, 1.3, 0.45)},
	"wet_floor": {"size": Vector3(0.3, 0.63, 0.36), "collide": false},
	"broom": {"size": Vector3(0.3, 1.4, 0.2), "collide": false},
	"washer": {"size": Vector3(0.78, 0.94, 0.78), "block": true},
	# ---- cafeteria ------------------------------------------------------------
	"cafeteria_table": {"size": Vector3(1.94, 0.75, 1.03), "block": true, "anchors": [[Vector3(0.3, 0.75, 0.0), "tray"]]},
	"tray": {"size": Vector3(0.45, 0.03, 0.33), "collide": false},
	"serving_counter": {"size": Vector3(1.5, 0.93, 0.8), "block": true, "anchors": [[Vector3(0.0, 0.93, -0.1), "counter"]]},
	"tray_stack": {"size": Vector3(0.5, 0.3, 0.4), "collide": false},
	"register": {"size": Vector3(1.36, 0.95, 1.36), "block": true},
	# ---- break room, lockers, lobby --------------------------------------------
	"lockers": {"size": Vector3(1.5, 1.9, 0.5), "block": true},
	"bench": {"size": Vector3(1.8, 0.46, 0.42), "block": true},
	"fridge_kitchen": {"size": Vector3(1.04, 1.84, 0.81), "block": true},
	"kitchen_counter": {"size": Vector3(1.5, 0.95, 0.65), "block": true},
	"kitchen_counter_coffee": {"size": Vector3(1.5, 0.95, 0.65), "block": true},
	"kitchen_counter_sink": {"size": Vector3(1.5, 0.95, 0.65), "block": true},
	"sofa": {"size": Vector3(1.96, 0.92, 0.82), "block": true},
	"armchair": {"size": Vector3(0.98, 0.92, 0.82)},
	"break_table": {"size": Vector3(1.94, 0.75, 1.03), "block": true},
	"wall_phone": {"size": Vector3(0.34, 0.5, 0.2), "mount": 1.25, "collide": false},
	"wall_clock": {"size": Vector3(0.32, 0.32, 0.05), "mount": 2.25},
	"extinguisher": {"size": Vector3(0.28, 0.66, 0.37), "mount": 0.55},
	"security_camera": {"size": Vector3(0.17, 0.29, 0.55), "mount": 2.55},
	"time_clock": {"size": Vector3(0.8, 1.35, 0.4)},
	"doormat": {"size": Vector3(1.5, 0.04, 0.83), "collide": false},
	"directory_board": {"size": Vector3(1.4, 1.1, 0.06), "mount": 0.9},
	# ---- operating room --------------------------------------------------------
	"or_table": {"size": Vector3(2.2, 0.945, 0.7), "block": true},
	"surgical_lamp": {"size": Vector3(0.9, 0.9, 0.9), "collide": false},
	"anesthesia_cart": {"size": Vector3(0.7, 1.6, 0.6), "block": true},
	"crash_cart": {"size": Vector3(0.8, 1.1, 0.6), "block": true},
	"scrub_sink": {"size": Vector3(0.82, 0.93, 0.86), "block": true},
	"glass_cabinet": {"size": Vector3(1.2, 1.9, 0.45), "block": true},
	"or_screen_mount": {"size": Vector3(2.2, 1.3, 0.1), "mount": 1.25},
	"table_monitor_mount": {"size": Vector3(1.2, 0.72, 0.1), "mount": 1.45},   # hub: one per OR table
	# The OR's lab wall (hub): one tile-wide station each, counter below and a shelf of bottles above.
	"lab_centrifuge": {"size": Vector3(1.5, 2.3, 0.75), "block": true},   # the vial spinner
	"lab_vials": {"size": Vector3(1.5, 2.3, 0.75), "block": true},
	"lab_microscope": {"size": Vector3(1.5, 2.3, 0.75), "block": true},
	"lab_analyzer": {"size": Vector3(1.5, 2.3, 0.75), "block": true},
	"lab_specimens": {"size": Vector3(1.5, 2.3, 0.75), "block": true},
	"lab_sink": {"size": Vector3(1.5, 2.3, 0.75), "block": true},
	"blood_fridge": {"size": Vector3(1.5, 2.1, 0.75), "block": true},   # with gas cylinders beside it
	# ---- crematorium (hub): the junk and the dead waiting their turn in the fire ------------
	# Mounds heaped against the long walls, tallest at the wall, sloping down to the lane from the
	# doors to the hatch. Sized to whole tiles so each blocks exactly the tiles it covers.
	"junk_mound_n1": {"size": Vector3(6.24, 2.5, 2.95), "block": true},
	"junk_mound_n2": {"size": Vector3(4.5, 2.2, 2.95), "block": true},
	"junk_mound_n3": {"size": Vector3(4.14, 0.85, 2.95), "block": true},   # low: under the hatch's swing
	"junk_mound_s1": {"size": Vector3(6.24, 2.7, 4.45), "block": true},
	"junk_mound_s2": {"size": Vector3(4.5, 2.3, 4.45), "block": true},
	"junk_mound_s3": {"size": Vector3(4.14, 0.85, 4.45), "block": true},
	"ash_pile": {"size": Vector3(1.4, 0.3, 1.1), "collide": false},
	"litter": {"size": Vector3(1.6, 0.02, 1.3), "collide": false},
	# ---- personnel (hub): the staff locker room ---------------------------
	"staff_lockers": {"size": Vector3(2.4, 1.95, 0.5), "block": true},   # four, one per player
	"vanity": {"size": Vector3(1.2, 2.3, 0.55)},   # a sink with its mirror and light over it
	"full_mirror": {"size": Vector3(1.8, 2.86, 0.08), "mount": 0.06},   # practically floor to ceiling
	"vein_machine": {"size": Vector3(7.2, 2.95, 1.5), "block": true},   # the whole back wall
	"shower": {"size": Vector3(0.5, 1.4, 0.4), "mount": 0.95},
	"floor_drain": {"size": Vector3(0.3, 0.01, 0.3), "collide": false},
	"tile_floor": {"size": Vector3(7.5, 0.012, 9.0), "collide": false},   # the tiled back half: showers, the machine
	"tile_wall": {"size": Vector3(9.0, 2.98, 0.02), "mount": 0.0},
	"tile_wall_end": {"size": Vector3(7.5, 2.98, 0.02), "mount": 0.0},
	# ---- outdoors --------------------------------------------------------------
	"ambulance": {"size": Vector3(2.18, 2.61, 4.71), "block": true},
	"van": {"size": Vector3(2.18, 1.96, 3.99), "block": true},
	"sedan": {"size": Vector3(2.18, 1.88, 3.7), "block": true},
	"suv": {"size": Vector3(2.18, 1.89, 3.92), "block": true},
	"hatchback": {"size": Vector3(1.89, 1.6, 4.13), "block": true},
	"covered_car": {"size": Vector3(1.79, 1.41, 4.38), "block": true},
	"street_light": {"size": Vector3(0.35, 5.4, 0.35)},
	"dumpster": {"size": Vector3(1.79, 1.36, 2.41), "block": true},
	"bollard": {"size": Vector3(0.22, 1.0, 0.22)},
	"canopy_post": {"size": Vector3(0.22, 3.2, 0.22)},
	"cone": {"size": Vector3(0.45, 0.71, 0.45), "collide": false},
	"barrier": {"size": Vector3(1.46, 0.84, 0.5), "block": true},
	"shop_table": {"size": Vector3(1.8, 0.8, 0.75), "block": true},
	"shop_crates": {"size": Vector3(0.9, 0.9, 0.7)},
	"pallet": {"size": Vector3(1.2, 0.14, 1.0), "collide": false},
	"outdoor_bench": {"size": Vector3(1.8, 0.85, 0.6), "block": true},
}


static func def(kind: String) -> Dictionary:
	return P.get(kind, {})


static func exists(kind: String) -> bool:
	return P.has(kind)


static func size(kind: String) -> Vector3:
	return P.get(kind, {}).get("size", Vector3.ONE)


static func blocks(kind: String) -> bool:
	return bool(P.get(kind, {}).get("block", false))


static func collides(kind: String) -> bool:
	var d: Dictionary = P.get(kind, {})
	return bool(d.get("collide", true)) and not d.has("mount")


static func mounted(kind: String) -> bool:
	return P.get(kind, {}).has("mount")


static func mount_height(kind: String) -> float:
	return float(P.get(kind, {}).get("mount", 0.0))


static func anchors(kind: String) -> Array:
	return P.get(kind, {}).get("anchors", [])


## Axis-aligned footprint in tile units, centred on `pos` (tile space), for a piece turned by `yaw`.
static func footprint_rect(kind: String, pos: Vector2, yaw: float) -> Rect2:
	var s := size(kind)
	var hw := s.x * 0.5 / TILE
	var hd := s.z * 0.5 / TILE
	var c := absf(cos(yaw))
	var n := absf(sin(yaw))
	var ex := hw * c + hd * n
	var ez := hw * n + hd * c
	if mounted(kind):
		# Hangs off the wall: the footprint is only its depth in front of the wall.
		var f := Vector2(-sin(yaw), -cos(yaw))
		var centre := pos + f * hd
		return Rect2(centre - Vector2(ex, ez), Vector2(ex, ez) * 2.0)
	return Rect2(pos - Vector2(ex, ez), Vector2(ex, ez) * 2.0)


## Tiles a blocking piece fills: every tile whose central square the footprint reaches.
static func blocked_tiles(kind: String, pos: Vector2, yaw: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not blocks(kind):
		return out
	var r := footprint_rect(kind, pos, yaw).grow(-0.02)
	for ty in range(int(floor(r.position.y)), int(ceil(r.end.y))):
		for tx in range(int(floor(r.position.x)), int(ceil(r.end.x))):
			var inner := Rect2(Vector2(tx + 0.22, ty + 0.22), Vector2(0.56, 0.56))
			if inner.intersects(r):
				out.append(Vector2i(tx, ty))
	return out


## Godot yaw for a piece whose front faces tile-space direction `f` (x right, y = world +Z).
static func yaw_facing(f: Vector2) -> float:
	return atan2(-f.x, -f.y)
