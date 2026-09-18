class_name ItemIcons
extends RefCounted
## The icons (docs/ITEMS_AND_ICONS.md). Every item kind has a bare icon (art/icons/items/bare/<kind>.svg,
## just the object, for the HUD, which draws its own slot) and a framed one (art/icons/items/<kind>.svg,
## slot, border and a sample count, for anywhere an icon stands alone). Abilities have round framed ones
## in art/icons/. This is the one place that maps a kind to them, so a kind without an icon yet (anything
## added after the art) simply answers null and the caller draws a plain slot.
##
##   ItemIcons.bare(kind) / framed(kind) / grey(kind) -> Texture2D or null
##   ItemIcons.ability(id) -> Texture2D or null
##   ItemIcons.border(kind) -> Color, the category colour (works for kinds with no icon too)
##   ItemIcons.category(kind) -> "surgery" | "shop" | "monster" | "equipment" | "loot" | "trinket" | ""
##   ItemIcons.is_trinket(kind) / kind_named(name) / has_icon(kind)
## Textures are imported with mipmaps: draw them on a CanvasItem whose texture_filter is
## TEXTURE_FILTER_LINEAR_WITH_MIPMAPS (the HUD, the OR monitor canvas and the database do).

const DIR := "res://art/icons/items/"
const CATEGORIES := "res://art/icons/items/categories.json"
const ABILITY_FILES := {"hive_in": "res://art/icons/hive_eyes.svg", "echo": "res://art/icons/echolocation.svg"}
## Ability id -> its colour (the glow the HUD puts behind the round icon).
const ABILITY_COLOR := {"hive_in": Color("ff8a2a"), "echo": Color("9b6bff")}
## Game kinds whose art is filed under another name.
const ALIAS := {"eye_hive": "hive_eyeball", "eye_surgeon": "surgeon_eyeball"}
const DEFAULT_BORDER := Color("6a7378")

static var _data: Dictionary = {}
static var _loaded := false
static var _bare := {}
static var _framed := {}
static var _grey := {}
static var _abilities := {}


static func file_kind(kind: String) -> String:
	return String(ALIAS.get(kind, kind))


static func _load_data() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(CATEGORIES, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_data = parsed


static func _tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


static func has_icon(kind: String) -> bool:
	return bare(kind) != null


static func bare(kind: String) -> Texture2D:
	var k := file_kind(kind)
	if not _bare.has(k):
		_bare[k] = _tex("%sbare/%s.svg" % [DIR, k]) if k != "" else null
	return _bare[k]


static func framed(kind: String) -> Texture2D:
	var k := file_kind(kind)
	if not _framed.has(k):
		_framed[k] = _tex("%s%s.svg" % [DIR, k]) if k != "" else null
	return _framed[k]


## The bare icon in greyscale (made once per kind, 128 px): what a spoiled part and a used-up trinket
## are drawn as.
static func grey(kind: String) -> Texture2D:
	var k := file_kind(kind)
	if _grey.has(k):
		return _grey[k]
	var t := bare(kind)
	var out: Texture2D = null
	if t != null:
		var img := t.get_image()
		if img != null:
			img.decompress()
			img.clear_mipmaps()
			img.resize(128, 128, Image.INTERPOLATE_LANCZOS)
			img.convert(Image.FORMAT_LA8)
			img.convert(Image.FORMAT_RGBA8)
			img.generate_mipmaps()
			out = ImageTexture.create_from_image(img)
	_grey[k] = out
	return out


static func ability(id: String) -> Texture2D:
	if not _abilities.has(id):
		_abilities[id] = _tex(String(ABILITY_FILES[id])) if ABILITY_FILES.has(id) else null
	return _abilities[id]


static func category(kind: String) -> String:
	_load_data()
	var e: Dictionary = (_data.get("items", {}) as Dictionary).get(file_kind(kind), {})
	if e.has("category"):
		return String(e.category)
	# No art entry yet: the same split the tint uses.
	if kind == "":
		return ""
	if Items.is_surgical(kind):
		return "surgery"
	if Items.is_loot(kind):
		return "loot"
	if Items.exists(kind):
		return "shop"
	return ""


static func border(kind: String) -> Color:
	_load_data()
	var c := category(kind)
	var hex = (_data.get("borders", {}) as Dictionary).get(c, null)
	return Color(String(hex)) if hex != null else DEFAULT_BORDER


static func is_trinket(kind: String) -> bool:
	return category(kind) == "trinket"


## The glow colour of a monster part ("" -> none), from categories.json.
static func glow(kind: String) -> Color:
	_load_data()
	var e: Dictionary = (_data.get("items", {}) as Dictionary).get(file_kind(kind), {})
	var g = e.get("glow", null)
	return Color(String(g)) if g != null else Color(0, 0, 0, 0)


## The kind whose display name is `item_name` ("" when none): the table prompt names its item.
static func kind_named(item_name: String) -> String:
	for k in Items.ITEMS.keys():
		if Items.display_name(k) == item_name:
			return k
	return ""


## Register every icon (Warmup): loads the textures, and makes the greyscale ones the HUD may need.
static func preload_all() -> void:
	_load_data()
	for k in (_data.get("items", {}) as Dictionary).keys():
		bare(k)
		framed(k)
		if category(k) == "monster" or category(k) == "trinket":
			grey(k)
	for id in ABILITY_FILES.keys():
		ability(id)
