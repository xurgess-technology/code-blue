extends RefCounted
## Grip data: where an item model sits in a hand (docs/HANDS_AND_FEEDBACK.md, docs/CONTRACTS.md
## "Player: hands"). `ItemModels.grip(kind)` returns this file's answer.
##
## A hand socket is a frame at the middle of the palm:
##   -Z  the way the fingers point
##   +Y  out of the palm (what a thing lying on an open palm rests against)
##   +X  to the right of the hand (the same for both hands, so the frame stays right-handed)
## A grip names, in the item model's own space (ItemModels.make: origin at the base of the stack):
##   pos    the point that lands in the palm
##   fwd    the model direction that follows the fingers (socket -Z)
##   up     the model direction that points out of the palm (socket +Y)
##   style  "palm" (lies on an open palm, palm up) or "fist" (a handle in a closed hand, thumb up)
##   hands  1, or 2 for bulky things carried in front with both hands
##   bundle the most copies of a stack shown in the hand (a batch is held as a small bundle)
## grip_transform(kind) is the model's transform in socket space: socket * grip_transform places it.

const LootTable := preload("res://scripts/economy/loot_table.gd")
const ItemsDB := preload("res://scripts/items.gd")

const DEFAULT := {"pos": Vector3.ZERO, "fwd": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "style": "palm", "hands": 1, "bundle": 1}

## Per kind. Anything missing takes DEFAULT (and loot its footprint-based default, see grip()).
const GRIPS := {
	# Surgical supplies (primitive models in item_models.gd).
	"anesthetic": {"pos": Vector3(0.0, 0.004, 0.012), "fwd": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "style": "palm", "bundle": 3},
	# Rolls lie across the palm (their axis along the model X).
	"gauze": {"pos": Vector3(0.0, 0.0, 0.0), "fwd": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "style": "palm", "bundle": 2},
	# Blade along +X from the handle, teeth toward +Z, flat face +Y: the teeth point down in a fist.
	"bone_saw": {"pos": Vector3(-0.17, 0.016, 0.0), "fwd": Vector3(1, 0, 0), "up": Vector3(0, -1, 0), "style": "fist"},
	# Hinge at -X, tips toward +X.
	"forceps": {"pos": Vector3(-0.05, 0.016, 0.0), "fwd": Vector3(1, 0, 0), "up": Vector3(0, -1, 0), "style": "fist"},
	"tourniquet": {"pos": Vector3(0.0, 0.0, 0.0), "fwd": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "style": "palm"},
	"suture_kit": {"pos": Vector3(0.0, 0.0, 0.0), "fwd": Vector3(1, 0, 0), "up": Vector3(0, 1, 0), "style": "palm", "bundle": 2},
	# Loot with a handle (lying models, handle along their long side).
	"reflex_hammer": {"pos": Vector3(-0.06, 0.02, 0.0), "fwd": Vector3(1, 0, 0), "up": Vector3(0, -1, 0), "style": "fist"},
	"thermometer": {"pos": Vector3(0.03, 0.02, 0.0), "fwd": Vector3(-1, 0, 0), "up": Vector3(0, -1, 0), "style": "fist"},
	"otoscope": {"pos": Vector3(0.04, 0.025, 0.0), "fwd": Vector3(-1, 0, 0), "up": Vector3(0, -1, 0), "style": "fist"},
	"wheelchair_wheel": {"pos": Vector3(0.0, 0.03, 0.26), "fwd": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "style": "palm"},
	"pill_bottle": {"bundle": 3},
}


static var _cache := {}


## Where in its model a kind is held. Always every key of DEFAULT. Cached per kind: do not edit the
## returned dictionary (duplicate it first).
static func grip(kind: String) -> Dictionary:
	if _cache.has(kind):
		return _cache[kind]
	var g := DEFAULT.duplicate()
	if ItemsDB.is_bulky(kind) or (LootTable.has(kind) and bool(LootTable.LOOT[kind].get("bulky", false))):
		# Bulky loot: both hands on its sides, a little below the middle of the model.
		var fp := _footprint(kind)
		g["pos"] = Vector3(0.0, fp.y * 0.35, 0.0)
		g["hands"] = 2
	g.merge(GRIPS.get(kind, {}), true)
	_cache[kind] = g
	return g


## The model's transform in socket space (see the header).
static func grip_transform(kind: String) -> Transform3D:
	return transform_of(grip(kind))


static func transform_of(g: Dictionary) -> Transform3D:
	var fwd: Vector3 = (g.fwd as Vector3).normalized()
	var up: Vector3 = g.up
	up = (up - fwd * up.dot(fwd)).normalized()
	# The model's fwd maps to socket -Z, its up to +Y: rows of the rotation are the model axes.
	var right := up.cross(-fwd)   # model direction that maps to socket +X
	var model_to_socket := Basis(right, up, -fwd).transposed()
	return Transform3D(model_to_socket, -(model_to_socket * (g.pos as Vector3)))


## How many copies of a stack the hand shows.
static func shown_count(kind: String, count: int) -> int:
	return clampi(count, 1, maxi(1, int(grip(kind).bundle)))


static func _footprint(kind: String) -> Vector3:
	var im = load("res://scripts/item_models.gd")
	return im.footprint(kind)
