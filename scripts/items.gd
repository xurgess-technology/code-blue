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
	"guide": {
		"name": "Medical guide",
		"short": "Medical guide",
		"surgical": false,
		"consumable": false,
		"batch": [1, 1],
		"fragile": false,
		"found": {},
		"loose_surfaces": [],
		"real_use": "A battered reference binder. Someone has written DO NOT REMOVE on the cover and then removed it anyway.",
		"where": "On the lectern in the clock-in room, unless somebody walked off with it.",
		"handling": "Takes a hand. Press R while holding it, or while looking at it, to read.",
	},
}

## Tabs the guide shows as locked, so it is obvious the pool will grow.
const LOCKED := ["Defibrillator", "Scalpel", "Sutures", "Clamp", "IV bag", "Sedative dart", "Battery", "Retractor"]


static func exists(kind: String) -> bool:
	return ITEMS.has(kind)


static func def(kind: String) -> Dictionary:
	return ITEMS.get(kind, {})


static func display_name(kind: String) -> String:
	return ITEMS.get(kind, {}).get("name", kind.capitalize())


static func is_consumable(kind: String) -> bool:
	return ITEMS.get(kind, {}).get("consumable", false)


static func is_fragile(kind: String) -> bool:
	return ITEMS.get(kind, {}).get("fragile", false)


static func is_surgical(kind: String) -> bool:
	return ITEMS.get(kind, {}).get("surgical", false)


## Whether two stacks of this kind merge into one hand slot.
static func stacks(kind: String) -> bool:
	return is_consumable(kind)


## How many of a fragile stack survive a drop. Roughly a third breaks, never the whole stack.
static func survivors_after_drop(kind: String, count: int) -> int:
	if not is_fragile(kind) or count <= 1:
		return count
	var broken := maxi(1, int(floor(count / 3.0)))
	return maxi(1, count - broken)
