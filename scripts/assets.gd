extends Node
##
## Assets — the single lookup point for every imported 3D asset in the game.
##
## Registered in project.godot as the autoload singleton `Assets`.
##
## Every call degrades gracefully: if a key is unknown, or the file behind it is
## missing or failed to import, the lookup returns `null` (or `false` / `""`)
## instead of erroring, so the caller can keep its primitive placeholder.
##
##     if Assets.has("prop/bed"):
##         add_child(Assets.spawn("prop/bed"))
##     else:
##         add_child(_placeholder_box())
##
## API
## ---
##   has(key)                 -> bool          is there a usable asset for this key
##   model(key)               -> PackedScene   the raw imported scene, or null
##   spawn(key)               -> Node3D        a corrected instance, or null
##   material(key)            -> Material      a ready StandardMaterial3D, or null
##   anim_name(key, logical)  -> String        pack-specific name for "idle"/"walk"/
##                                             "run"/"attack"/..., or "" if absent
##   anim_player(node)        -> AnimationPlayer  first AnimationPlayer under a spawn
##   play(node, key, logical) -> bool          convenience: look up + play
##   keys() / model_keys() / material_keys() -> Array[String]
##   missing()                -> Array[String] declared keys whose file is absent
##   info(key)                -> Dictionary    the raw registry entry (read-only-ish)
##
## What `spawn()` fixes up
## -----------------------
## Source packs disagree about scale and facing. Every entry below carries
## `scale`, `yaw` (degrees about +Y) and `x`/`y`/`z` offsets. `spawn()` applies
## them as translate * yaw * scale and returns a bare Node3D whose origin is at
## the FEET / BASE of the model, whose horizontal footprint is centred on that
## origin, and whose FORWARD is -Z (Godot's convention) — so game code can
## `look_at()` / `-transform.basis.z` it without caring where the art came from.
##
## Every source pack here is exported from Blender through the glTF exporter, so
## the authored front is +Z (the glTF convention). That is why every entry below
## carries `yaw: 180`. Verified directly: the Kenney face mask accessory sits at
## +Z, the Quaternius wolf head is at +Z, the Poly Pizza locker doors are at +Z.
## If a single prop ever turns out reversed, flip that one entry's `yaw`.
##
## `model()` returns the untouched imported scene; prefer `spawn()`.
##
## Adding or swapping an asset
## ---------------------------
## Drop the file under assets/models/<category>/, add (or edit) one row in
## MODELS below, re-run the headless import, then run assets/_selfcheck.gd.
## Nothing else in the game needs to change.
##

## Logical animation names the game is expected to ask for.
const LOGICAL_ANIMS := ["idle", "walk", "run", "attack", "die", "hit", "pick_up", "interact"]

## Kenney's character rigs (mini-characters, blocky-characters, graveyard-kit)
## all ship the identical animation set, so they share one map.
const _KENNEY_CHAR_ANIMS := {
	"idle": "idle",
	"walk": "walk",
	"run": "sprint",
	"attack": "attack-melee-right",
	"die": "die",
	"pick_up": "pick-up",
	"interact": "interact-right",
	"sit": "sit",
	"crouch": "crouch",
	"static": "static",
}

## key -> {
##   path:  res:// path to the imported model
##   scale: uniform scale applied by spawn()      (default 1.0)
##   yaw:   degrees about +Y applied by spawn()   (default 0.0)
##   x/y/z: metres of offset in the final frame   (default 0.0) — y lifts the
##          base onto the floor, x/z recentre the footprint on the origin
##   anims: logical -> actual animation name      (default {})
##   note:  free text, surfaced by info()/ASSETS.md
##   models sweep 2 (all optional):
##   pitch / roll: degrees about +X / +Z, applied before yaw (lay a watch face up)
##   size:   longest side in metres; height: height in metres (characters) — either one makes
##           spawn() measure the model and put its base on the floor, centred (no x/y/z needed)
##   hide:   mesh node names measure() and ItemModels skip
##   albedo: a replacement colour texture (the paramedics' recoloured colormaps)
## }
const MODELS := {
	# ---- characters -------------------------------------------------------
	"char/surgeon": {
		"path": "res://assets/models/characters/surgeon.glb",
		"scale": 2.687, "yaw": 180,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters, character-male-a. Authored 0.67 m, scaled to 1.80 m.",
	},
	# HUMAN HOOK (2026-09-14): the Blender-built humans (art/human/), made in-house. Authored facing +Z,
	# feet at y 0, 1 unit = 1 m; scripts/human/human_model.gd dresses them (tint, masks, pieces).
	"char/human_surgeon_a": {
		"path": "res://assets/models/characters/human/surgeon_a.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Jog", "run": "Sprint"},
		"note": "Player surgeon A, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},
	"char/human_surgeon_b": {
		"path": "res://assets/models/characters/human/surgeon_b.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Jog", "run": "Sprint"},
		"note": "Player surgeon B, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},
	"char/human_surgeon_c": {
		"path": "res://assets/models/characters/human/surgeon_c.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Jog", "run": "Sprint"},
		"note": "Player surgeon C, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},
	# The stylized surgeon (2026-09-18, art/stylized): the players' body. Same skeleton, clips and
	# piece/site contract as the surgeons above; eyes are separate pieces (Human_Eye_L / _R).
	"char/human_surgeon_st": {
		"path": "res://assets/models/characters/human/surgeon_st.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Jog", "run": "Sprint"},
		"note": "Player surgeon, stylized, made for Malpractice with Blender scripts (art/stylized). No third-party licence.",
	},
	"patient/human_bob": {
		"path": "res://assets/models/characters/human/bob.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Lying"},
		"note": "Bob the patient, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},
	"crew/human_paramedic_a": {
		"path": "res://assets/models/characters/human/paramedic_a.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Walk", "push": "Push"},
		"note": "Paramedic A, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},
	"crew/human_paramedic_b": {
		"path": "res://assets/models/characters/human/paramedic_b.glb", "scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Walk", "push": "Push"},
		"note": "Paramedic B, made for Malpractice with Blender scripts (art/human/blender_src). No third-party licence.",
	},

	# ---- monsters ---------------------------------------------------------
	# The Night Nurse (2026-09-14; the stylized model since 2026-09-18): built in-house from Python in
	# Blender (art/night_nurse/), 2.30 m, feet at y 0, authored facing +Z like every glTF here. 27k
	# triangles, 53 bones, textures as separate VRAM-compressed PNGs beside it. No root motion.
	"monster/night_nurse": {
		"path": "res://assets/models/monsters/night_nurse/night_nurse.glb",
		"scale": 1.0, "yaw": 180,
		"anims": {"idle": "Idle", "walk": "Walk", "run": "Walk", "attack": "Walk", "frozen": "Frozen", "static": "Frozen"},
		"note": "Night Nurse, made for Malpractice with Blender scripts (art/night_nurse/blender_src). No third-party licence.",
	},
	# The Hive (2026-09-18): the stylized kit (art/stylized, variant `hive`), 1.75 m, feet at y 0,
	# facing +Z, on the human skeleton with its own clips. Charcoal skin, the skull open with a shelf
	# fungus in place of the brain, glowing eyes (scripts/monsters/hive_rig.gd). No root motion.
	"monster/hive": {
		"path": "res://assets/models/monsters/hive/hive_st.glb",
		"scale": 1.0, "yaw": 180,
		"anims": {"idle": "HiveIdle", "walk": "HiveWalk", "run": "HiveWalk", "attack": "HiveAttack"},
		"note": "The Hive, made for Malpractice with Blender scripts (art/stylized). No third-party licence.",
	},
	# The Sonographer (2026-09-18): the stylized kit (art/stylized, variant `sonographer`), about
	# 2.1 m at rest and 2.7 m craned, feet at y 0, facing +Z. A standalone model: no cart. On the human
	# skeleton except for its neck, which is a chain of four bones (`neck`, `neck2`, `neck3`, `neck4`)
	# so it can stretch; the game drives that stretch from suspicion. Blind: the sockets are scarred
	# flat and there are no eye pieces. Its big swivelling ears (Human_Ear_L / _R), its glowing
	# windpipe (Human_Throat) behind the see-through skin of its throat (Human_ThroatSkin), the
	# ultrasound probe grown into its right hand (Human_Probe), the three runs of cable up that arm
	# (Human_Cable_A/B/C) and the gel drips (Human_Gel_*) are all their own pieces; Site_ear_L/_R,
	# Site_throat, Site_cable and Site_probe say where things go.
	# No root motion. scripts/monsters/sonographer_rig.gd.
	"monster/sonographer": {
		"path": "res://assets/models/monsters/sonographer/sonographer_st.glb",
		"scale": 1.0, "yaw": 180,
		"anims": {
			"idle": "SonoIdle", "walk": "SonoWander", "run": "SonoRush", "attack": "SonoWail",
			"listen": "SonoListen", "charge": "SonoCharge", "echo": "SonoEcho",
			"search": "SonoSearch", "stagger": "SonoStagger", "lying": "SonoLying",
		},
		"note": "The Sonographer, made for Malpractice with Blender scripts (art/stylized). No third-party licence.",
	},
	# ---- patients ---------------------------------------------------------
	# The seal patient (2026-09-14): built in-house from Python in Blender (art/seal/), authored in the
	# PatientBody frame (nose -X, belly on y 0, its left +Z), so no fix-ups. 16k triangles, 20 bones,
	# clips sampled by scripts/patients/seal_model_builder.gd. Textures are separate VRAM-compressed PNGs.
	"patient/seal": {
		"path": "res://assets/models/patients/seal/seal.glb",
		"scale": 1.0, "yaw": 0,
		"anims": {"idle": "Idle", "stir": "Stir", "fidget": "Fidget", "twitch": "Twitch", "dead": "Flatline"},
		"note": "Harbor seal patient, made for Malpractice with Blender scripts (art/seal/blender_src). No third-party licence.",
	},

	# ---- patients ---------------------------------------------------------
	"patient/human": {
		"path": "res://assets/models/patients/patient_human.glb",
		"scale": 2.278, "yaw": 180,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters, character-male-c. Lay it on the table with 'die' or 'static'.",
	},
	# "patient/elephant" is deliberately absent: no CC0 elephant exists in the
	# vetted sources. Callers get null and fall back; see ASSETS.md.

	# ---- props ------------------------------------------------------------
	"prop/bed": {
		"path": "res://assets/models/props/bed.glb",
		"scale": 1.770, "yaw": 180, "x": 1.186, "z": -1.000,
		"note": "Kenney Furniture Kit bedSingle.",
	},
	"prop/gurney": {
		"path": "res://assets/models/props/gurney.glb",
		"scale": 2.000, "yaw": 180,
		"note": "Kenney Space Station Kit bed-single. Metal-framed, reads as a gurney; no wheels.",
	},
	"prop/cabinet": {
		"path": "res://assets/models/props/cabinet.glb",
		"scale": 2.000, "yaw": 180, "x": 0.430, "z": -0.450,
		"note": "Kenney Furniture Kit kitchenCabinet.",
	},
	"prop/wheelchair": {
		"path": "res://assets/models/props/wheelchair.glb",
		"scale": 1.900, "yaw": 180, "z": -0.133,
		"note": "Kenney Mini Characters wheelchair.",
	},
	"prop/vending": {
		"path": "res://assets/models/props/vending.glb",
		"scale": 1.700, "yaw": 180, "z": -0.425,
		"note": "Kenney Mini Market freezers-standing — glass-front cooler as a vending machine.",
	},
	"prop/bin": {
		"path": "res://assets/models/props/bin.glb",
		"scale": 1.628, "yaw": 180,
		"note": "Kenney Furniture Kit trashcan.",
	},
	"prop/locker": {
		"path": "res://assets/models/props/locker.glb",
		"scale": 0.671, "yaw": 180, "y": 0.007,
		"note": "Quaternius closet via Poly Pizza. Tall two-door unit standing in for a staff locker.",
	},
	"prop/screen": {
		"path": "res://assets/models/props/screen.glb",
		"scale": 1.552, "yaw": 180, "x": 0.303, "z": -0.078,
		"note": "Kenney Furniture Kit computerScreen — vitals monitor.",
	},
	"prop/chair": {
		"path": "res://assets/models/props/chair.glb",
		"scale": 1.640, "yaw": 180, "x": 0.271, "z": -0.254,
		"note": "Kenney Furniture Kit chairDesk.",
	},
	"prop/curtain": {
		"path": "res://assets/models/props/curtain.glb",
		"scale": 0.553, "yaw": 180, "x": 0.022, "y": 0.003, "z": -0.069,
		"note": "Quaternius Curtains Double via Poly Pizza.",
	},
	"prop/table_op": {
		"path": "res://assets/models/props/table_op.glb",
		"scale": 1.820, "yaw": 180,
		"note": "Kenney Space Station Kit table — the operating table.",
	},
	"prop/clock": {
		"path": "res://assets/models/props/clock.glb",
		"scale": 1.580, "yaw": 180,
		"note": "CreativeTrio alarm clock via Poly Pizza. Desk clock, not a wall clock.",
	},
	# "prop/ivstand" is deliberately absent: no CC0 IV stand found. See ASSETS.md.

	# ---- hospital (sweep 2, hospital worker) ------------------------------
	# Room furniture, vehicles and outdoor props for the entrance building, the wings and
	# the neutral area. Offsets centre each footprint and put its base on the floor.
	"hosp/toilet": {
		"path": "res://assets/models/hospital/kenney_furniture/toilet.glb", "scale": 1.750, "yaw": 180, "x": 0.273, "y": -0.000, "z": 0.418,
		"note": "Kenney Furniture Kit toilet. Size 0.55 x 0.79 x 0.84 m.",
	},
	"hosp/sink_wall": {
		"path": "res://assets/models/hospital/kenney_furniture/bathroomSink.glb", "scale": 1.550, "yaw": 180, "x": 0.263, "y": 0.620, "z": -0.225,
		"note": "Kenney Furniture Kit bathroomSink, pedestal sink. Size 0.53 x 0.87 x 0.45 m.",
	},
	"hosp/mirror": {
		"path": "res://assets/models/hospital/kenney_furniture/bathroomMirror.glb", "scale": 1.900, "yaw": 180, "x": 0.286, "y": -0.000, "z": 0.044,
		"note": "Kenney Furniture Kit bathroomMirror. Size 0.57 x 0.83 x 0.27 m.",
	},
	"hosp/sink_cabinet": {
		"path": "res://assets/models/hospital/kenney_furniture/kitchenSink.glb", "scale": 1.900, "yaw": 180, "x": 0.408, "y": -0.000, "z": -0.428,
		"note": "Kenney Furniture Kit kitchenSink: utility / lab / scrub sink. Size 0.82 x 0.93 x 0.86 m.",
	},
	"hosp/chair_cushion": {
		"path": "res://assets/models/hospital/kenney_furniture/chairModernCushion.glb", "scale": 1.900, "yaw": 180, "x": 0.190, "y": 0.000, "z": -0.190,
		"note": "Kenney Furniture Kit chairModernCushion. Size 0.38 x 0.87 x 0.38 m.",
	},
	"hosp/bedside": {
		"path": "res://assets/models/hospital/kenney_furniture/sideTableDrawers.glb", "scale": 1.500, "yaw": 180, "x": 0.386, "y": -0.000, "z": -0.148,
		"note": "Kenney Furniture Kit sideTableDrawers: bedside cabinet. Size 0.80 x 0.58 x 0.33 m.",
	},
	"hosp/coffee_table": {
		"path": "res://assets/models/hospital/kenney_furniture/tableCoffee.glb", "scale": 1.800, "yaw": 180, "x": -0.235, "y": 0.000, "z": -0.180,
		"note": "Kenney Furniture Kit tableCoffee: magazine table. Size 1.19 x 0.41 x 0.72 m.",
	},
	"hosp/table": {
		"path": "res://assets/models/hospital/kenney_furniture/table.glb", "scale": 2.300, "yaw": 180, "x": 0.968, "y": -0.000, "z": -0.514,
		"note": "Kenney Furniture Kit table: cafeteria / break room table. Size 1.94 x 0.75 x 1.03 m.",
	},
	"hosp/coffee_machine": {
		"path": "res://assets/models/hospital/kenney_furniture/kitchenCoffeeMachine.glb", "scale": 1.900, "yaw": 180, "x": 0.180, "y": -0.000, "z": -0.228,
		"note": "Kenney Furniture Kit kitchenCoffeeMachine. Size 0.36 x 0.34 x 0.46 m.",
	},
	"hosp/fridge_kitchen": {
		"path": "res://assets/models/hospital/kenney_furniture/kitchenFridgeLarge.glb", "scale": 2.000, "yaw": 180, "x": 0.520, "y": 0.000, "z": -0.278,
		"note": "Kenney Furniture Kit kitchenFridgeLarge: break room fridge. Size 1.04 x 1.84 x 0.81 m.",
	},
	"hosp/microwave": {
		"path": "res://assets/models/hospital/kenney_furniture/kitchenMicrowave.glb", "scale": 1.900, "yaw": 180, "x": 0.275, "y": -0.000, "z": -0.199,
		"note": "Kenney Furniture Kit kitchenMicrowave. Size 0.55 x 0.34 x 0.44 m.",
	},
	"hosp/sofa": {
		"path": "res://assets/models/hospital/kenney_furniture/loungeSofa.glb", "scale": 2.000, "yaw": 180, "x": 0.980, "y": -0.000, "z": -0.410,
		"note": "Kenney Furniture Kit loungeSofa. Size 1.96 x 0.92 x 0.82 m.",
	},
	"hosp/armchair": {
		"path": "res://assets/models/hospital/kenney_furniture/loungeChair.glb", "scale": 2.000, "yaw": 180, "x": 0.490, "y": -0.000, "z": -0.410,
		"note": "Kenney Furniture Kit loungeChair. Size 0.98 x 0.92 x 0.82 m.",
	},
	"hosp/plant": {
		"path": "res://assets/models/hospital/kenney_furniture/pottedPlant.glb", "scale": 2.000, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Furniture Kit pottedPlant. Size 0.42 x 1.31 x 0.48 m.",
	},
	"hosp/plant_small": {
		"path": "res://assets/models/hospital/kenney_furniture/plantSmall1.glb", "scale": 1.900, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Furniture Kit plantSmall1. Size 0.18 x 0.27 x 0.18 m.",
	},
	"hosp/tv": {
		"path": "res://assets/models/hospital/kenney_furniture/televisionModern.glb", "scale": 1.900, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Furniture Kit televisionModern: wall TV. Size 1.30 x 0.86 x 0.24 m.",
	},
	"hosp/laptop": {
		"path": "res://assets/models/hospital/kenney_furniture/laptop.glb", "scale": 1.900, "yaw": 180, "x": 0.251, "y": -0.000, "z": -0.228,
		"note": "Kenney Furniture Kit laptop. Size 0.50 x 0.31 x 0.46 m.",
	},
	"hosp/cabinet_tall": {
		"path": "res://assets/models/hospital/kenney_furniture/bookcaseClosedDoors.glb", "scale": 2.100, "yaw": 180, "x": 0.420, "y": -0.000, "z": -0.263,
		"note": "Kenney Furniture Kit bookcaseClosedDoors: tall storage cabinet. Size 0.84 x 1.78 x 0.53 m.",
	},
	"hosp/bookcase": {
		"path": "res://assets/models/hospital/kenney_furniture/bookcaseOpen.glb", "scale": 2.100, "yaw": 180, "x": 0.420, "y": -0.000, "z": -0.263,
		"note": "Kenney Furniture Kit bookcaseOpen. Size 0.84 x 1.85 x 0.53 m.",
	},
	"hosp/washer": {
		"path": "res://assets/models/hospital/kenney_furniture/washer.glb", "scale": 2.000, "yaw": 180, "x": 0.390, "y": -0.000, "z": -0.310,
		"note": "Kenney Furniture Kit washer. Size 0.78 x 0.94 x 0.78 m.",
	},
	"hosp/doormat": {
		"path": "res://assets/models/hospital/kenney_furniture/rugDoormat.glb", "scale": 3.500, "yaw": 180, "x": 0.751, "y": -0.000, "z": -0.415,
		"note": "Kenney Furniture Kit rugDoormat. Size 1.50 x 0.04 x 0.83 m.",
	},
	"hosp/radio": {
		"path": "res://assets/models/hospital/kenney_furniture/radio.glb", "scale": 1.600, "yaw": 180, "x": 0.252, "y": -0.000, "z": -0.078,
		"note": "Kenney Furniture Kit radio. Size 0.50 x 0.37 x 0.16 m.",
	},
	"hosp/box_closed": {
		"path": "res://assets/models/hospital/kenney_furniture/cardboardBoxClosed.glb", "scale": 2.200, "yaw": 180, "x": 0.234, "y": -0.000, "z": -0.234,
		"note": "Kenney Furniture Kit cardboardBoxClosed. Size 0.47 x 0.62 x 0.47 m.",
	},
	"hosp/box_open": {
		"path": "res://assets/models/hospital/kenney_furniture/cardboardBoxOpen.glb", "scale": 2.200, "yaw": 180, "x": 0.234, "y": -0.000, "z": -0.234,
		"note": "Kenney Furniture Kit cardboardBoxOpen. Size 0.82 x 0.62 x 0.47 m.",
	},
	"hosp/coat_rack": {
		"path": "res://assets/models/hospital/kenney_furniture/coatRackStanding.glb", "scale": 2.200, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Furniture Kit coatRackStanding. Size 0.60 x 1.69 x 0.60 m.",
	},
	"hosp/books": {
		"path": "res://assets/models/hospital/kenney_furniture/books.glb", "scale": 1.900, "yaw": 180, "x": 0.143, "y": -0.000, "z": -0.090,
		"note": "Kenney Furniture Kit books. Size 0.29 x 0.20 x 0.18 m.",
	},
	"hosp/ambulance": {
		"path": "res://assets/models/hospital/kenney_car/ambulance.glb", "scale": 1.450, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.036,
		"note": "Kenney Car Kit ambulance. Size 2.18 x 2.61 x 4.71 m.",
	},
	"hosp/van": {
		"path": "res://assets/models/hospital/kenney_car/van.glb", "scale": 1.450, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.036,
		"note": "Kenney Car Kit van: the shop van. Size 2.18 x 1.96 x 3.99 m.",
	},
	"hosp/sedan": {
		"path": "res://assets/models/hospital/kenney_car/sedan.glb", "scale": 1.450, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.036,
		"note": "Kenney Car Kit sedan. Size 2.18 x 1.88 x 3.70 m.",
	},
	"hosp/suv": {
		"path": "res://assets/models/hospital/kenney_car/suv.glb", "scale": 1.450, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Car Kit suv. Size 2.18 x 1.89 x 3.92 m.",
	},
	"hosp/hatchback": {
		"path": "res://assets/models/hospital/kenney_car/hatchback-sports.glb", "scale": 1.450, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.036,
		"note": "Kenney Car Kit hatchback-sports. Size 1.89 x 1.60 x 4.13 m.",
	},
	"hosp/cone": {
		"path": "res://assets/models/hospital/kenney_car/cone.glb", "scale": 1.200, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Car Kit cone. Size 0.57 x 0.71 x 0.57 m.",
	},
	"hosp/street_light": {
		"path": "res://assets/models/hospital/kenney_roads/light-square.glb", "scale": 9.000, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.844,
		"note": "Kenney City Kit Roads light-square. Size 0.45 x 5.40 x 2.14 m.",
	},
	"hosp/dumpster": {
		"path": "res://assets/models/hospital/kenney_roads/dumpster.glb", "scale": 6.500, "yaw": 180, "x": 0.049, "y": -0.000, "z": 0.000,
		"note": "Kenney City Kit Roads dumpster: the sell bin. Size 1.79 x 1.36 x 2.41 m.",
	},
	"hosp/barrier": {
		"path": "res://assets/models/hospital/kenney_roads/construction-barrier.glb", "scale": 6.500, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney City Kit Roads construction-barrier. Size 0.88 x 0.84 x 1.46 m.",
	},
	"hosp/register": {
		"path": "res://assets/models/hospital/kenney_market/cash-register.glb", "scale": 1.600, "yaw": 180, "x": 0.040, "y": -0.000, "z": 0.040,
		"note": "Kenney Mini Market cash-register: cafeteria till. Size 1.36 x 0.95 x 1.36 m.",
	},
	"hosp/vending": {
		"path": "res://assets/models/hospital/kenney_market/bottle-return.glb", "scale": 1.800, "yaw": 180, "x": -0.000, "y": 0.000, "z": -0.051,
		"note": "Kenney Mini Market bottle-return: corridor vending machine. Size 0.81 x 1.97 x 0.87 m.",
	},
	"hosp/bucket": {
		"path": "res://assets/models/hospital/kenney_survival/bucket.glb", "scale": 2.500, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.000,
		"note": "Kenney Survival Kit bucket: mop bucket. Size 0.36 x 0.48 x 0.36 m.",
	},
	"hosp/school_chair": {
		"path": "res://assets/models/hospital/polyhaven/SchoolChair_01/SchoolChair_01.gltf", "scale": 0.920, "yaw": 180, "x": -0.000, "y": 0.002, "z": -0.000,
		"note": "Poly Haven SchoolChair_01: waiting / cafeteria chair. Size 0.52 x 0.93 x 0.62 m.",
	},
	"hosp/wet_floor": {
		"path": "res://assets/models/hospital/polyhaven/WetFloorSign_01/WetFloorSign_01.gltf", "scale": 1.000, "yaw": 180, "x": -0.000, "y": -0.002, "z": -0.014,
		"note": "Poly Haven WetFloorSign_01. Size 0.30 x 0.63 x 0.36 m.",
	},
	"hosp/covered_car": {
		"path": "res://assets/models/hospital/polyhaven/covered_car/covered_car.gltf", "scale": 1.000, "yaw": 180, "x": 0.048, "y": -0.000, "z": 0.024,
		"note": "Poly Haven covered_car. Size 1.79 x 1.41 x 4.38 m.",
	},
	"hosp/filing_cabinet": {
		"path": "res://assets/models/hospital/polyhaven/drawer_cabinet/drawer_cabinet.gltf", "scale": 0.800, "yaw": 180, "x": -0.000, "y": -0.000, "z": -0.003,
		"note": "Poly Haven drawer_cabinet: filing cabinet. Size 0.91 x 1.51 x 0.39 m.",
	},
	"hosp/microscope": {
		"path": "res://assets/models/hospital/polyhaven/industrial_microscope/industrial_microscope.gltf", "scale": 1.000, "yaw": 180, "x": 0.014, "y": 0.002, "z": -0.082,
		"note": "Poly Haven industrial_microscope. Size 0.21 x 0.46 x 0.50 m.",
	},
	"hosp/extinguisher": {
		"path": "res://assets/models/hospital/polyhaven/korean_fire_extinguisher_01/korean_fire_extinguisher_01.gltf", "scale": 1.000, "yaw": 180, "x": 0.000, "y": 0.000, "z": 0.060,
		"note": "Poly Haven korean_fire_extinguisher_01. Size 0.28 x 0.66 x 0.37 m.",
	},
	"hosp/medical_box": {
		"path": "res://assets/models/hospital/polyhaven/medical_box/medical_box.gltf", "scale": 1.000, "yaw": 180, "x": -0.000, "y": -0.000, "z": 0.003,
		"note": "Poly Haven medical_box. Size 0.53 x 0.10 x 0.35 m.",
	},
	"hosp/office_desk": {
		"path": "res://assets/models/hospital/polyhaven/metal_office_desk/metal_office_desk.gltf", "scale": 0.950, "yaw": 180, "x": -0.000, "y": -0.000, "z": 0.004,
		"note": "Poly Haven metal_office_desk. Size 1.90 x 0.75 x 0.90 m.",
	},
	"hosp/security_camera": {
		"path": "res://assets/models/hospital/polyhaven/security_camera_01/security_camera_01.gltf", "scale": 1.000, "yaw": 180, "x": 0.000, "y": 0.025, "z": -0.027,
		"note": "Poly Haven security_camera_01. Size 0.17 x 0.29 x 0.55 m.",
	},
	"hosp/steel_shelves": {
		"path": "res://assets/models/hospital/polyhaven/steel_frame_shelves_02/steel_frame_shelves_02.gltf", "scale": 1.000, "yaw": 180, "x": 0.000, "y": 0.001, "z": -0.000,
		"note": "Poly Haven steel_frame_shelves_02. Size 0.59 x 2.14 x 0.50 m.",
	},
	"hosp/tool_cart": {
		"path": "res://assets/models/hospital/polyhaven/tool_cart/tool_cart.gltf", "scale": 1.000, "yaw": 180, "x": -0.021, "y": 0.004, "z": -0.008,
		"note": "Poly Haven tool_cart: instrument cart. Size 1.27 x 0.96 x 0.75 m.",
	},
	"hosp/wall_phone": {
		"path": "res://assets/models/hospital/polyhaven/vintage_telephone_wall_clock/vintage_telephone_wall_clock.gltf", "scale": 1.000, "yaw": 180, "x": -0.005, "y": 0.074, "z": 0.096,
		"note": "Poly Haven vintage_telephone_wall_clock: break room phone. Size 0.34 x 0.50 x 0.19 m.",
	},
	"hosp/wall_clock": {
		"path": "res://assets/models/hospital/polyhaven/wall_clock/wall_clock.gltf", "scale": 1.000, "yaw": 180, "x": -0.000, "y": 0.160, "z": 0.024,
		"note": "Poly Haven wall_clock. Size 0.32 x 0.32 x 0.05 m.",
	},
	"hosp/wheelchair": {
		"path": "res://assets/models/hospital/polyhaven/wheelchair_01/wheelchair_01.gltf", "scale": 1.000, "yaw": 180, "x": -0.002, "y": -0.006, "z": 0.060,
		"note": "Poly Haven wheelchair_01. Size 0.82 x 1.10 x 1.09 m.",
	},
	# ---- end hospital ------------------------------------------------------

	# ---- loot items (models, sweep 2) -------------------------------------
	# ItemModels.make() checks `item/<loot kind>` first. `size` is the longest side in metres;
	# the fixup measures the model and puts its base on the floor, centred. `hide` skips mesh
	# nodes; `merge` lets ItemModels merge the parts into one mesh per material.
	"item/pill_bottle": {
		"path": "res://assets/models/items/bottles/bottle20.glb", "size": 0.075,
		"note": "Lyricsz 50 Bottles #20 (OpenGameArt): an amber bottle with a white cap.",
	},
	"item/desk_phone": {
		"path": "res://assets/models/items/baked/desk_phone.glb", "size": 0.24, "yaw": 180,
		"note": "JustinARay Red Table Phone (OpenGameArt), converted from FBX, cord decimated.",
	},
	"item/laptop": {
		"path": "res://assets/models/hospital/kenney_furniture/laptop.glb", "size": 0.34,
		"note": "Kenney Furniture Kit laptop (the file the lab islands use).",
	},
	"item/gold_watch": {
		"path": "res://assets/models/items/baked/gold_watch.glb", "size": 0.085, "pitch": -90,
		"note": "Poly Haven vintage_pocket_watch, lying face up.",
	},
	"item/heart_monitor": {
		"path": "res://assets/models/items/polyhaven/television_02/television_02_1k.gltf", "size": 0.38,
		"note": "Poly Haven television_02: a boxy CRT; ItemModels adds the green trace on the glass.",
	},
	"item/defibrillator": {
		"path": "res://assets/models/kenney_mini_characters/aid-defibrillator-green.glb", "size": 0.32,
		"note": "Kenney Mini Characters aid-defibrillator-green: an AED case with a heart.",
	},
	"item/ultrasound": {
		"path": "res://assets/models/items/baked/ultrasound.glb", "size": 0.42,
		"note": "Poly Haven classic_laptop without its stand: a beige clamshell with a trackball, as a portable ultrasound.",
	},
	# ---- paramedics (models, sweep 2) ---------------------------------------
	"crew/paramedic_a": {
		"path": "res://assets/models/kenney_mini_characters/character-male-b.glb", "height": 1.8, "yaw": 180,
		"albedo": "res://assets/models/kenney_mini_characters/Textures/paramedic_male.png",
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters character-male-b in a recoloured colormap (green uniform).",
	},
	"crew/paramedic_b": {
		"path": "res://assets/models/kenney_mini_characters/character-female-b.glb", "height": 1.74, "yaw": 180,
		"albedo": "res://assets/models/kenney_mini_characters/Textures/paramedic_female.png",
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters character-female-b in a recoloured colormap (green uniform).",
	},
	# ---- end models sweep 2 -------------------------------------------------
}

## key -> texture-set folder + material tuning. All maps are optional; whichever
## files exist are wired into a StandardMaterial3D.
const MATERIALS := {
	"mat/floor": {
		"dir": "res://assets/textures/floor", "uv_scale": 2.0,
		"note": "ambientCG Tiles141 — dirty beige grid floor tile.",
	},
	"mat/wall": {
		"dir": "res://assets/textures/wall", "uv_scale": 2.0,
		"note": "ambientCG PaintedPlaster017 — painted plaster wall.",
	},
	"mat/wall_tile": {
		"dir": "res://assets/textures/wall_tile", "uv_scale": 2.0,
		"note": "ambientCG Tiles133D — cracked, dirty white wall tile.",
	},
	"mat/ceiling": {
		"dir": "res://assets/textures/ceiling", "uv_scale": 1.0,
		"note": "ambientCG OfficeCeiling005 — suspended ceiling panel.",
	},
	"mat/concrete": {
		"dir": "res://assets/textures/concrete", "uv_scale": 2.0,
		"note": "ambientCG Concrete034.",
	},
	# ---- hospital (sweep 2) ----
	"mat/asphalt": {"dir": "res://assets/textures/asphalt", "uv_scale": 0.25, "note": "Poly Haven asphalt_02 - parking lot."},
	"mat/pavement": {"dir": "res://assets/textures/pavement", "uv_scale": 0.5, "note": "Poly Haven concrete_pavement - sidewalk."},
	"mat/linoleum": {"dir": "res://assets/textures/linoleum", "uv_scale": 0.5, "note": "Poly Haven old_linoleum_flooring_01 - corridor floor."},
	"mat/tile_floor": {"dir": "res://assets/textures/tile_floor", "uv_scale": 0.6, "note": "Poly Haven worn_tile_floor - restroom, morgue, OR floor."},
	# ---- end hospital ----
	"mat/metal": {
		"dir": "res://assets/textures/metal", "uv_scale": 2.0, "metallic": 1.0,
		"note": "ambientCG MetalPlates001 — brushed steel.",
	},
	# models sweep 2: the x-ray film loot's picture.
	"mat/xray_film": {
		"dir": "res://assets/textures/xray_film", "uv_scale": 1.0,
		"note": "Mikael Häggström, normal PA chest radiograph (Wikimedia Commons, CC0), 224 x 256.",
	},
}

const _MAP_FILES := {
	"albedo": "color.jpg",
	"normal": "normalgl.jpg",
	"roughness": "roughness.jpg",
	"metallic": "metalness.jpg",
	"ao": "ao.jpg",
}

var _scene_cache: Dictionary = {}
var _fixup_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _warned: Dictionary = {}


func _ready() -> void:
	# No threaded preload: meshes created on loader threads raced the main thread's own mesh
	# building (level build, warmup) and crashed Godot (signal 11) in about half of the headless
	# test runs on 2026-09-13. Models load on first use; the warmup cover hides it.
	var gone := missing()
	if not gone.is_empty():
		push_warning("Assets: %d declared key(s) have no file on disk: %s"
			% [gone.size(), ", ".join(gone)])


# -- queries -----------------------------------------------------------------

## Short names other systems already use, mapped onto the canonical keys above.
## The hospital builder names its factories after the furniture, not the category,
## so both spellings resolve to the same asset.
const ALIASES := {
	"bed": "prop/bed",
	"cabinet": "prop/cabinet",
	"operating_table": "prop/table_op",
	"time_clock": "prop/clock",
	"gurney": "prop/gurney",
	"wheelchair": "prop/wheelchair",
	"ivstand": "prop/ivstand",
	"vending": "prop/vending",
	"bin": "prop/bin",
	"locker": "prop/locker",
	"screen": "prop/screen",
	"chair": "prop/chair",
	"curtain": "prop/curtain",
	"floor": "mat/floor",
	"wall": "mat/wall",
	"wall_tile": "mat/wall_tile",
	"ceiling": "mat/ceiling",
	"concrete": "mat/concrete",
	"metal": "mat/metal",
	"surgeon": "char/surgeon",
}


## Canonical form of a key, so callers may use either spelling.
func _resolve(key: String) -> String:
	return ALIASES.get(key, key)


## True when `key` is declared and its file is actually present.
func has(key: String) -> bool:
	key = _resolve(key)
	if MODELS.has(key):
		return ResourceLoader.exists(MODELS[key]["path"])
	if MATERIALS.has(key):
		# ResourceLoader, not FileAccess: an exported build ships only the imported texture,
		# so the raw .jpg isn't there.
		return ResourceLoader.exists("%s/%s" % [MATERIALS[key]["dir"], _MAP_FILES["albedo"]])
	return false


## Every declared key, models and materials.
func keys() -> Array:
	var out: Array = MODELS.keys()
	out.append_array(MATERIALS.keys())
	return out


func model_keys() -> Array:
	return MODELS.keys()


func material_keys() -> Array:
	return MATERIALS.keys()


## Declared keys whose backing file is not on disk.
func missing() -> Array:
	var out: Array = []
	for k in keys():
		if not has(k):
			out.append(k)
	return out


## The registry entry for a key (path, scale, yaw, y, anims, note), or {}.
func info(key: String) -> Dictionary:
	key = _resolve(key)
	if MODELS.has(key):
		var d: Dictionary = (MODELS[key] as Dictionary).duplicate(true)
		d["scale"] = _num(MODELS[key], "scale", 1.0)
		d["yaw"] = _num(MODELS[key], "yaw", 0.0)
		d["y"] = _num(MODELS[key], "y", 0.0)
		return d
	if MATERIALS.has(key):
		return (MATERIALS[key] as Dictionary).duplicate(true)
	return {}


## The res:// path behind a key, or "".
func path(key: String) -> String:
	key = _resolve(key)
	if MODELS.has(key):
		return MODELS[key]["path"]
	if MATERIALS.has(key):
		return MATERIALS[key]["dir"]
	return ""


# -- models ------------------------------------------------------------------

## The imported scene for a model key, untouched. Null if unknown or missing.
func model(key: String) -> PackedScene:
	key = _resolve(key)
	if not MODELS.has(key):
		_warn_once(key, "Assets.model(): unknown key '%s'" % key)
		return null
	if _scene_cache.has(key):
		return _scene_cache[key]
	var p: String = MODELS[key]["path"]
	if not ResourceLoader.exists(p):
		_warn_once(key, "Assets.model(): '%s' has no file at %s" % [key, p])
		return null
	var res := ResourceLoader.load(p)
	if res == null or not (res is PackedScene):
		_warn_once(key, "Assets.model(): '%s' did not load as a PackedScene" % key)
		return null
	_scene_cache[key] = res
	return res


## An instance of a model key, wrapped in a Node3D whose origin is at the base
## of the model and whose forward is -Z. Null if unknown or missing.
func spawn(key: String) -> Node3D:
	key = _resolve(key)
	var scene := model(key)
	if scene == null:
		return null
	var inner := scene.instantiate()
	if not (inner is Node3D):
		_warn_once(key, "Assets.spawn(): '%s' is not a 3D scene" % key)
		if inner:
			inner.queue_free()
		return null
	var e: Dictionary = MODELS[key]
	var root := Node3D.new()
	root.name = key.get_file().to_pascal_case()
	root.add_child(inner)
	(inner as Node3D).transform = fixup(key)
	root.set_meta("asset_key", key)
	return root


## The transform spawn() puts on the imported scene: scale, then roll / pitch / yaw, then the
## offsets (expressed in the final frame). Entries with `size` (the longest side in metres) or
## `height` (metres, characters) or `fit: true` measure the model once and compute the scale and the offsets that put its base on
## the floor with the footprint centred (models sweep 2: every item/* entry works that way).
func fixup(key: String) -> Transform3D:
	key = _resolve(key)
	if _fixup_cache.has(key):
		return _fixup_cache[key]
	var e: Dictionary = MODELS.get(key, {})
	var rot := Basis.from_euler(Vector3(deg_to_rad(_num(e, "pitch", 0.0)), deg_to_rad(_num(e, "yaw", 0.0)), deg_to_rad(_num(e, "roll", 0.0))))
	var s := _num(e, "scale", 1.0)
	var off := Vector3(_num(e, "x", 0.0), _num(e, "y", 0.0), _num(e, "z", 0.0))
	if e.has("size") or e.has("height") or bool(e.get("fit", false)):
		var box := measure(key, Transform3D(rot, Vector3.ZERO))
		if e.has("size") and box.size != Vector3.ZERO:
			s = _num(e, "size", 1.0) / maxf(box.size.x, maxf(box.size.y, box.size.z))
		elif e.has("height") and box.size.y > 0.0:
			s = _num(e, "height", 1.0) / box.size.y
		var c := box.get_center() * s
		off += Vector3(-c.x, -box.position.y * s, -c.z)
	var xf := Transform3D(rot.scaled(Vector3(s, s, s)), off)
	_fixup_cache[key] = xf
	return xf


## Bounding box of a model key's meshes in the frame `xf` (applied to the imported scene root),
## skipping mesh nodes listed in the entry's `hide`. Empty AABB when the model is missing.
func measure(key: String, xf: Transform3D) -> AABB:
	key = _resolve(key)
	var scene := model(key)
	if scene == null:
		return AABB()
	var inst := scene.instantiate()
	var hide: Array = MODELS[key].get("hide", [])
	var out := AABB()
	var first := true
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or hide.has(String(mi.name)):
			continue
		var t := Transform3D()
		var p: Node = mi
		while p != null and p != inst:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var ab: AABB = (xf * t) * mi.mesh.get_aabb()
		out = ab if first else out.merge(ab)
		first = false
	inst.free()
	return out


## First AnimationPlayer anywhere under `node` (works on a spawn() result).
func anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found := anim_player(c)
		if found != null:
			return found
	return null


## The pack's real animation name for a logical one ("idle", "walk", "run",
## "attack", ...). Returns "" when the pack has nothing for it.
func anim_name(key: String, logical: String) -> String:
	key = _resolve(key)
	if not MODELS.has(key):
		return ""
	var map: Dictionary = MODELS[key].get("anims", {})
	if map.has(logical):
		return map[logical]
	# Let callers pass a literal pack name through unchanged.
	if map.values().has(logical):
		return logical
	return ""


## Convenience: resolve a logical animation on a spawn() result and play it.
## Returns false when the asset, the player or the clip is missing.
func play(node: Node, key: String, logical: String, custom_blend: float = -1.0) -> bool:
	key = _resolve(key)
	var ap := anim_player(node)
	if ap == null:
		return false
	var name := anim_name(key, logical)
	if name == "" or not ap.has_animation(name):
		return false
	ap.play(name, custom_blend)
	return true


## Every logical animation a model key can actually serve.
func anims(key: String) -> Array:
	key = _resolve(key)
	if not MODELS.has(key):
		return []
	return (MODELS[key].get("anims", {}) as Dictionary).keys()


# -- materials ---------------------------------------------------------------

## A ready StandardMaterial3D for a texture-set key, or null.
## The same instance is handed out every time; duplicate() before mutating.
func material(key: String) -> Material:
	key = _resolve(key)
	if not MATERIALS.has(key):
		_warn_once(key, "Assets.material(): unknown key '%s'" % key)
		return null
	if _material_cache.has(key):
		return _material_cache[key]
	var e: Dictionary = MATERIALS[key]
	var dir: String = e["dir"]
	var albedo := _tex(dir, _MAP_FILES["albedo"])
	if albedo == null:
		_warn_once(key, "Assets.material(): '%s' has no colour map in %s" % [key, dir])
		return null
	var m := StandardMaterial3D.new()
	m.resource_name = key
	m.albedo_texture = albedo
	var uv := _num(e, "uv_scale", 1.0)
	m.uv1_scale = Vector3(uv, uv, uv)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	var nrm := _tex(dir, _MAP_FILES["normal"])
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm

	var rgh := _tex(dir, _MAP_FILES["roughness"])
	if rgh != null:
		m.roughness_texture = rgh
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE

	var met := _tex(dir, _MAP_FILES["metallic"])
	if met != null:
		m.metallic = 1.0
		m.metallic_texture = met
		m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	elif e.has("metallic"):
		m.metallic = _num(e, "metallic", 0.0)

	var ao := _tex(dir, _MAP_FILES["ao"])
	if ao != null:
		m.ao_enabled = true
		m.ao_texture = ao
		m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE

	_material_cache[key] = m
	return m


## Which PBR maps a material key actually resolved to files.
func material_maps(key: String) -> Array:
	key = _resolve(key)
	var out: Array = []
	if not MATERIALS.has(key):
		return out
	for slot in _MAP_FILES:
		if ResourceLoader.exists("%s/%s" % [MATERIALS[key]["dir"], _MAP_FILES[slot]]):
			out.append(slot)
	return out


# -- internals ---------------------------------------------------------------

func _tex(dir: String, file: String) -> Texture2D:
	var p := "%s/%s" % [dir, file]
	if not ResourceLoader.exists(p):
		return null
	var r := ResourceLoader.load(p)
	return r as Texture2D


func _num(d: Dictionary, k: String, fallback: float) -> float:
	return float(d[k]) if d.has(k) else fallback


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)
