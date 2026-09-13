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
## }
const MODELS := {
	# ---- characters -------------------------------------------------------
	"char/surgeon": {
		"path": "res://assets/models/characters/surgeon.glb",
		"scale": 2.687, "yaw": 180,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters, character-male-a. Authored 0.67 m, scaled to 1.80 m.",
	},
	"char/surgeon_b": {
		"path": "res://assets/models/characters/surgeon_b.glb",
		"scale": 2.308, "yaw": 180,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters, character-female-a. Second surgeon body.",
	},

	# ---- monsters ---------------------------------------------------------
	"monster/nurse": {
		"path": "res://assets/models/monsters/nurse.glb",
		"scale": 2.376, "yaw": 180, "y": -0.052,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Graveyard Kit zombie, scaled slightly over human height.",
	},
	"monster/lurker": {
		"path": "res://assets/models/monsters/lurker.gltf",
		"scale": 0.573, "yaw": 180, "y": 0.017,
		"anims": {
			"idle": "Idle", "walk": "Walk", "run": "Walk",
			"attack": "Bite_Front", "die": "Death", "hit": "HitRecieve",
		},
		"note": "Quaternius Cute Monsters crab: low, wide, many-legged. Closest CC0 Lurker.",
	},
	"monster/orderly": {
		"path": "res://assets/models/monsters/orderly.gltf",
		"scale": 0.919, "yaw": 180, "y": 0.010,
		"anims": {
			"idle": "Idle", "walk": "Walk", "run": "Run",
			"attack": "Punch", "die": "Death", "hit": "HitReact",
		},
		"note": "Quaternius Ultimate Monsters yeti, scaled to ~2.6 m.",
	},
	"monster/cthulhu": {
		"path": "res://assets/models/monsters/cthulhu.gltf",
		"scale": 1.026, "yaw": 180, "y": 0.058,
		"anims": {"idle": "Flying", "walk": "Flying", "attack": "Bite_Front", "die": "Death"},
		"note": "Quaternius Cute Monsters cthulhu. Spare monster, not wired to a game role.",
	},

	# ---- patients ---------------------------------------------------------
	"patient/human": {
		"path": "res://assets/models/patients/patient_human.glb",
		"scale": 2.278, "yaw": 180,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Mini Characters, character-male-c. Lay it on the table with 'die' or 'static'.",
	},
	"patient/ghost": {
		"path": "res://assets/models/patients/patient_ghost.glb",
		"scale": 2.338, "yaw": 180, "floats": true,
		"anims": _KENNEY_CHAR_ANIMS,
		"note": "Kenney Graveyard Kit sheet ghost, same rig as the surgeons. Hovers 0.26 m off the floor by design — it has no feet.",
	},
	"patient/wolf": {
		"path": "res://assets/models/patients/patient_wolf.gltf",
		"scale": 0.485, "yaw": 180, "y": 0.005,
		"anims": {
			"idle": "Idle", "walk": "Walk", "run": "Gallop",
			"attack": "Attack", "die": "Death", "hit": "Idle_HitReact1",
		},
		"note": "Quaternius Ultimate Animated Animals wolf. Stands in for the werewolf.",
	},
	"patient/bull": {
		"path": "res://assets/models/patients/bull.gltf",
		"scale": 0.479, "yaw": 180, "y": 0.027,
		"anims": {
			"idle": "Idle", "walk": "Walk", "run": "Gallop",
			"attack": "Attack_Headbutt", "die": "Death", "hit": "Idle_HitReact1",
		},
		"note": "Quaternius bull. Largest CC0 quadruped found — the elephant's understudy.",
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
	"prop/desk": {
		"path": "res://assets/models/props/desk.glb",
		"scale": 1.974, "yaw": 180, "x": 0.700, "z": -0.365,
		"note": "Kenney Furniture Kit desk.",
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
	"mat/metal": {
		"dir": "res://assets/textures/metal", "uv_scale": 2.0, "metallic": 1.0,
		"note": "ambientCG MetalPlates001 — brushed steel.",
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
var _material_cache: Dictionary = {}
var _warned: Dictionary = {}


func _ready() -> void:
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
	"desk": "prop/desk",
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
		return FileAccess.file_exists("%s/%s" % [MATERIALS[key]["dir"], _MAP_FILES["albedo"]])
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
	var s := _num(e, "scale", 1.0)
	var yaw := _num(e, "yaw", 0.0)
	var y := _num(e, "y", 0.0)
	var x := _num(e, "x", 0.0)
	var z := _num(e, "z", 0.0)
	var root := Node3D.new()
	root.name = key.get_file().to_pascal_case()
	root.add_child(inner)
	var n3 := inner as Node3D
	# scale, then yaw, then translate — offsets are expressed in the final frame.
	var basis := Basis.from_euler(Vector3(0.0, deg_to_rad(yaw), 0.0)).scaled(Vector3(s, s, s))
	n3.transform = Transform3D(basis, Vector3(x, y, z))
	root.set_meta("asset_key", key)
	return root


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
		if FileAccess.file_exists("%s/%s" % [MATERIALS[key]["dir"], _MAP_FILES[slot]]):
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
