class_name Items
extends RefCounted
## Every item in the game, as data. The world, the hands, the OR shelf, the spawner and the
## medical guide all read from here, so adding an item means adding one entry.

## Where an item can turn up. Container types are built by the containers system;
## "loose" means sitting on a counter, tray, gurney or floor edge.
const CONTAINER_TYPES := {
	"med_fridge": {"name": "medicine fridge", "rooms": ["pharmacy", "storage"]},
	"drawer_unit": {"name": "steel drawer unit", "rooms": ["storage", "maintenance"]},
	"station_drawers": {"name": "nurse station drawers", "rooms": ["nurse_station", "ward"]},
	"trauma_bag": {"name": "trauma bag", "rooms": ["corridor", "nurse_station"]},
	"pegboard": {"name": "pegboard", "rooms": ["maintenance", "storage"]},
}

const SURGICAL := ["anesthetic", "gauze", "forceps", "tourniquet", "bone_saw"]

const ITEMS := {
	"anesthetic": {
		"name": "Anesthetic",
		"short": "Anesthetic vials",
		"surgical": true,
		"consumable": true,
		"batch": [2, 3],
		"fragile": true,
		"found": {"med_fridge": 0.85, "loose": 0.15},
		"loose_surfaces": ["counter", "tray"],
		"real_use": "A general anesthetic puts a patient into a controlled, reversible unconsciousness so they feel nothing during surgery. The dose depends on body weight: too little and they can wake mid-procedure, too much and breathing and heart rate crash.",
		"where": "Almost always in the medicine fridges of pharmacy and storage rooms. Now and then a vial or two left out on a counter or a bedside tray.",
		"handling": "Consumable. Found in batches of 2 to 3. Glass: dropping the batch smashes some of it.",
	},
	"gauze": {
		"name": "Gauze",
		"short": "Gauze rolls",
		"surgical": true,
		"consumable": true,
		"batch": [2, 4],
		"fragile": false,
		"found": {"station_drawers": 0.7, "loose": 0.3},
		"loose_surfaces": ["counter", "tray", "gurney"],
		"real_use": "Gauze is a loose woven cotton dressing. Packed into a wound it applies pressure from the inside and helps blood clot; wrapped around a limb or stump it holds that pressure and keeps the wound covered.",
		"where": "Usually in the drawers of nurse stations and ward counters. Often a few rolls left loose on counters, trays or gurneys.",
		"handling": "Consumable. Found in rolls of 2 to 4. Survives being dropped.",
	},
	"forceps": {
		"name": "Forceps",
		"short": "Forceps",
		"surgical": true,
		"consumable": false,
		"batch": [1, 1],
		"fragile": false,
		"found": {"drawer_unit": 0.8, "loose": 0.2},
		"loose_surfaces": ["tray", "counter"],
		"real_use": "Surgical forceps are long, hinged tweezers used to grip tissue or remove foreign objects without putting fingers into a wound. In a gunshot wound they are how a surgeon reaches in and draws out the bullet or its fragments.",
		"where": "Sealed in sterile packs inside the steel drawer units of storage and maintenance rooms. Occasionally abandoned on an instrument tray.",
		"handling": "Reusable. One pair. Stays in the OR once delivered.",
	},
	"tourniquet": {
		"name": "Tourniquet",
		"short": "Tourniquet",
		"surgical": true,
		"consumable": false,
		"batch": [1, 1],
		"fragile": false,
		"found": {"trauma_bag": 0.8, "loose": 0.2},
		"loose_surfaces": ["gurney", "floor"],
		"real_use": "A tourniquet is a strap tightened around a limb, above an injury, until it stops blood flowing past it. It is placed before an amputation so the cut does not bleed the patient out, and it has to be tight enough to work without crushing the limb.",
		"where": "In the red trauma bags hung on corridor walls and in nurse stations. Sometimes dropped on a gurney or the floor.",
		"handling": "Reusable. One. Stays in the OR once delivered.",
	},
	"bone_saw": {
		"name": "Bone saw",
		"short": "Bone saw",
		"surgical": true,
		"consumable": false,
		"batch": [1, 1],
		"fragile": false,
		"found": {"pegboard": 0.75, "loose": 0.25},
		"loose_surfaces": ["gurney", "counter", "floor"],
		"real_use": "An amputation saw cuts through bone once skin and muscle have been opened. It is worked in long, steady strokes: rushing it tears tissue and leaves a ragged edge that heals badly.",
		"where": "Hung on pegboards in maintenance and storage rooms. Sometimes left leaning against a gurney somewhere it has no business being.",
		"handling": "Reusable. Heavy. Stays in the OR once delivered.",
	},
	# downed (sweep 2 wave 3): closes a downed teammate's wound on the OR's player table. Not in
	# SURGICAL (that list is what a patient case can need); game.gd spawns a few every shift.
	"suture_kit": {
		"name": "Suture kit",
		"short": "Suture kits",
		"surgical": true,
		"consumable": true,
		"batch": [1, 2],
		"fragile": false,
		"found": {"trauma_bag": 0.4, "station_drawers": 0.35, "drawer_unit": 0.25},
		"loose_surfaces": [],
		"real_use": "A sterile pack with a curved needle already threaded with suture. Each bite goes in on one side of a gash and out the other, and pulling the thread snug draws the edges together so the bleeding stops and the wound can heal.",
		"where": "In trauma bags on corridor walls, in nurse station drawers and in the steel drawer units of storage rooms.",
		"handling": "Consumable. Found in packs of 1 or 2. Put one on the OR supply shelf, carry a downed teammate to the player table and stitch them up.",
	},
}

## Tabs the database terminal shows as locked, so it is obvious the pool will grow.
const LOCKED := ["Defibrillator", "Scalpel", "Clamp", "IV bag", "Sedative dart", "Battery", "Retractor"]


## Sellable loot (scripts/economy/loot_table.gd). Not in ITEMS so the terminal, the supply spawner
## and the dev panel's supply list leave it alone; def() and every helper below still know it.
const LootTable := preload("res://scripts/economy/loot_table.gd")

static var _loot_defs := {}


static func exists(kind: String) -> bool:
	return ITEMS.has(kind) or LootTable.has(kind)


static func def(kind: String) -> Dictionary:
	if ITEMS.has(kind):
		return ITEMS[kind]
	if not LootTable.has(kind):
		return {}
	if not _loot_defs.has(kind):
		_loot_defs[kind] = LootTable.def(kind)
	return _loot_defs[kind]


static func display_name(kind: String) -> String:
	return def(kind).get("name", kind.capitalize())


static func is_consumable(kind: String) -> bool:
	return def(kind).get("consumable", false)


static func is_fragile(kind: String) -> bool:
	return def(kind).get("fragile", false)


static func is_surgical(kind: String) -> bool:
	return def(kind).get("surgical", false)


## Sellable loot: gold tint, goes in the sell bin, never on the shelf.
static func is_loot(kind: String) -> bool:
	return LootTable.has(kind)


## Takes two hand slots.
static func is_bulky(kind: String) -> bool:
	return def(kind).get("bulky", false)


## How many hand slots one stack of this kind occupies.
static func slots_needed(kind: String) -> int:
	return 2 if is_bulky(kind) else 1


## "Anesthetic vials" style label for a stack of `count`.
static func stack_label(kind: String, count: int) -> String:
	if count <= 1:
		return display_name(kind)
	return "%d %s" % [count, def(kind).get("short", display_name(kind))]


## Whether two stacks of this kind merge into one hand slot.
static func stacks(kind: String) -> bool:
	return is_consumable(kind) or bool(def(kind).get("stack", false))


## How many of a fragile stack survive a drop. Roughly a third breaks, never the whole stack.
static func survivors_after_drop(kind: String, count: int) -> int:
	if not is_fragile(kind) or count <= 1:
		return count
	var broken := maxi(1, int(floor(count / 3.0)))
	return maxi(1, count - broken)
