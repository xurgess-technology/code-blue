extends RefCounted
## Sellable hospital loot, as data. None of it helps surgery; all of it sells at the sell bin.
##
## Items.def(kind) falls back to this table, so a loot kind works everywhere an item kind does
## (world items, hands, the HUD). It is kept out of Items.ITEMS on purpose: the medical guide,
## the dev panel's supply list and the supply spawner iterate that table and loot has no place
## in any of them.
##
## Fields
##   name / short   display names for one and for a stack
##   value          [min, max] dollars for one, rolled per spawned stack before the depth bonus
##   bulky          takes two hand slots (and never fits in a container)
##   fragile        a violent drop (hit, shove) cracks it: the stack loses value
##   stack          several merge into one hand slot (value adds up); batch is the spawn size
##   trinket_weight how often a shift's trinket draw picks it (see TRINKETS_PER_SHIFT)
##   max_per_shift  at most this many of the kind in a shift
##   trinket        sells, but a later chunk gives it one job too (the item list in docs/ITEMS_AND_ICONS.md)
##   tier           0 common junk .. 3 rare valuables; higher tiers get likelier deeper in
##   rooms          room kind -> weight; "*" is any other kind. Unlisted kinds without "*" never.
##   surfaces       loose anchor surfaces it may sit on ("counter", "tray", "gurney", "floor")
##   containers     container type -> weight, when it may also turn up inside one

const LOOT := {
	# ---- plain loot: it exists to be sold -----------------------------------------------------
	"pill_bottle": {
		"name": "Pill bottle", "short": "Pill bottles", "value": [26, 52], "tier": 0, "stack": true, "batch": [1, 3],
		"rooms": {"pharmacy": 2.72, "patient_room": 1.19, "nurse_station": 1.36, "restroom": 1.02, "supply_closet": 1.02, "janitor_closet": 0.68, "lab": 0.85, "cafeteria": 0.51, "*": 0.255},
		"surfaces": ["counter", "tray"], "containers": {"med_fridge": 0.35, "station_drawers": 0.4},
	},
	"xray_film": {
		"name": "X-ray film", "short": "X-ray films", "value": [50, 100], "tier": 0,
		"rooms": {"radiology": 3.2, "office": 0.64, "supply_closet": 0.4, "patient_room": 0.32, "lab": 0.32, "morgue": 0.32, "janitor_closet": 0.24, "*": 0.08},
		"surfaces": ["counter", "gurney", "floor"], "containers": {"drawer_unit": 0.3},
	},
	"heart_monitor": {
		"name": "Heart monitor", "short": "Heart monitors", "value": [130, 230], "tier": 2, "bulky": true, "fragile": true,
		"rooms": {"patient_room": 0.224, "nurse_station": 0.112, "supply_closet": 0.112, "janitor_closet": 0.09, "corridor": 0.067, "lab": 0.067, "*": 0.011},
		"surfaces": ["counter", "gurney", "floor"], "containers": {},
	},
	"gold_watch": {
		"name": "Gold watch", "short": "Gold watches", "value": [120, 280], "tier": 3,
		"rooms": {"office": 0.252, "waiting_room": 0.42, "morgue": 0.672, "restroom": 0.336, "cafeteria": 0.336, "lab": 0.168, "*": 0.063},
		"surfaces": ["counter", "tray", "floor"], "containers": {"station_drawers": 0.3, "drawer_unit": 0.3},
	},
	"ultrasound": {
		"name": "Portable ultrasound", "short": "Portable ultrasounds", "value": [260, 440], "tier": 3, "bulky": true, "fragile": true,
		"rooms": {"radiology": 0.7, "patient_room": 0.14, "supply_closet": 0.14, "lab": 0.14, "*": 0.017},
		"surfaces": ["counter", "gurney", "floor"], "containers": {},
	},
	# ---- trinkets: they sell, but each also does one thing (a later chunk). Rarer than plain loot.
	"desk_phone": {
		"name": "Desk phone", "short": "Desk phones", "value": [30, 60], "tier": 0, "trinket": true, "trinket_weight": 3.0,
		"rooms": {"office": 4.5, "nurse_station": 3.15, "waiting_room": 2.7, "cafeteria": 4.05, "patient_room": 1.05, "*": 0.225},
		"surfaces": ["counter"], "containers": {},
	},
	"laptop": {
		"name": "Laptop", "short": "Laptops", "value": [110, 200], "tier": 2, "fragile": true, "trinket": true, "trinket_weight": 1.2,
		"rooms": {"lab": 0.672, "office": 0.504, "nurse_station": 0.252, "radiology": 0.252, "cafeteria": 0.21, "*": 0.021},
		"surfaces": ["counter"], "containers": {},
	},
	"defibrillator": {
		"name": "Defibrillator", "short": "Defibrillators", "value": [170, 310], "tier": 3, "bulky": true, "trinket": true, "trinket_weight": 1.0, "max_per_shift": 1,
		"rooms": {"corridor": 0.21, "nurse_station": 0.168, "patient_room": 0.105, "waiting_room": 0.126, "supply_closet": 0.084, "janitor_closet": 0.084, "*": 0.006},
		"surfaces": ["floor", "counter", "gurney"], "containers": {},
	},
	"reflex_hammer": {
		"name": "Reflex hammer", "short": "Reflex hammers", "value": [30, 60], "tier": 0, "trinket": true, "trinket_weight": 3.0,
		"rooms": {"office": 1.0, "patient_room": 0.5, "nurse_station": 0.5, "janitor_closet": 0.375, "supply_closet": 0.375, "morgue": 0.375, "*": 0.063},
		"surfaces": ["counter", "tray"], "containers": {"drawer_unit": 0.4},
	},
	"epipen": {
		"name": "EpiPen", "short": "EpiPens", "value": [40, 80], "tier": 1, "trinket": true, "trinket_weight": 1.2,
		"rooms": {"nurse_station": 0.307, "pharmacy": 0.307, "patient_room": 0.154, "supply_closet": 0.154, "restroom": 0.115, "cafeteria": 0.115, "*": 0.019},
		"surfaces": ["counter", "tray"], "containers": {"station_drawers": 0.5, "med_fridge": 0.3},
	},
	"pulse_oximeter": {
		"name": "Pulse oximeter", "short": "Pulse oximeters", "value": [60, 110], "tier": 1, "trinket": true, "trinket_weight": 1.2,
		"rooms": {"patient_room": 0.072, "nurse_station": 0.096, "supply_closet": 0.036, "lab": 0.048, "morgue": 0.036, "*": 0.006},
		"surfaces": ["counter", "tray"], "containers": {"station_drawers": 0.5},
	},
	# BRAINS (sweep 3, scripts/brains): harvested from a dissected monster, never found. No rooms,
	# surfaces or containers, so the loot spawner never picks them; `value` is the full price of a
	# perfect brain (scaled by its condition when harvested, then by spoilage, see brains.gd).
	"brain_hive": {
		"name": "Hive brain", "short": "Hive brains", "value": [150, 150], "tier": 3, "fragile": true,
		"brain": true, "rooms": {}, "surfaces": [], "containers": {},
	},
	"brain_discharged": {
		"name": "Discharged brain", "short": "Discharged brains", "value": [350, 350], "tier": 3, "fragile": true,
		"brain": true, "rooms": {}, "surfaces": [], "containers": {},
	},
	# GRAFTING part one (scripts/grafting/eyes.gd): taken out of a strapped Hive, or a surgeon's own
	# eye swapped out; never found. They spoil like brains outside a vat (Eyes.spoil_factor).
	"eye_hive": {
		"name": "Hive's eyeball", "short": "Hive's eyeballs", "value": [120, 120], "tier": 3,
		"eye": true, "rooms": {}, "surfaces": [], "containers": {},
	},
	"eye_surgeon": {
		"name": "Surgeon's eyeball", "short": "Surgeon's eyeballs", "value": [45, 45], "tier": 3,
		"eye": true, "rooms": {}, "surfaces": [], "containers": {},
	},
}

## A shift holds this many trinkets in total (inclusive range); the kinds' room weights decide which.
const TRINKETS_PER_SHIFT := [3, 5]
## Room kinds whose spots are likelier to hold loot at all (radiology has few spots).
const ROOM_CHANCE := {"radiology": 3.0}

## Weight multiplier by tier on the surface (depth 0); deeper rooms lift the rare tiers.
const TIER_BASE := [1.0, 0.55, 0.28, 0.12]
## Per wing depth, each tier's weight gains (1 + depth * tier * TIER_DEPTH_GAIN).
const TIER_DEPTH_GAIN := 0.55
## Each depth step adds this share to a rolled value.
const DEPTH_VALUE_GAIN := 0.2


static func has(kind: String) -> bool:
	return LOOT.has(kind)


static func kinds() -> Array:
	var k := LOOT.keys()
	k.sort()
	return k


## The Items-style definition of a loot kind: every Items field a consumer might read.
static func def(kind: String) -> Dictionary:
	var d: Dictionary = LOOT.get(kind, {})
	if d.is_empty():
		return d
	var out := d.duplicate()
	out["loot"] = true
	out["surgical"] = false
	out["consumable"] = false
	out["fragile"] = bool(d.get("fragile", false))
	out["bulky"] = bool(d.get("bulky", false))
	out["stack"] = bool(d.get("stack", false))
	out["batch"] = d.get("batch", [1, 1])
	out["found"] = {}
	out["loose_surfaces"] = d.get("surfaces", [])
	return out


static func weight(kind: String, room_kind: String, depth: int) -> float:
	var d: Dictionary = LOOT.get(kind, {})
	var rooms: Dictionary = d.get("rooms", {})
	var w: float = float(rooms.get(room_kind, rooms.get("*", 0.0)))
	var tier: int = int(d.get("tier", 0))
	return w * float(TIER_BASE[clampi(tier, 0, 3)]) * (1.0 + float(maxi(0, depth) * tier) * TIER_DEPTH_GAIN)


## A value for one of `kind` found at `depth`, from a seeded roll in 0..1.
static func roll_value(kind: String, depth: int, roll: float) -> int:
	var v: Array = LOOT.get(kind, {}).get("value", [10, 10])
	var base := lerpf(float(v[0]), float(v[1]), clampf(roll, 0.0, 1.0))
	return maxi(1, roundi(base * (1.0 + float(maxi(0, depth)) * DEPTH_VALUE_GAIN)))


static func is_trinket(kind: String) -> bool:
	return bool(LOOT.get(kind, {}).get("trinket", false))
