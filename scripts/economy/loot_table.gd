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
##   tier           0 common junk .. 3 rare valuables; higher tiers get likelier deeper in
##   rooms          room kind -> weight; "*" is any other kind. Unlisted kinds without "*" never.
##   surfaces       loose anchor surfaces it may sit on ("counter", "tray", "gurney", "floor")
##   containers     container type -> weight, when it may also turn up inside one

const LOOT := {
	"stethoscope": {
		"name": "Stethoscope", "short": "Stethoscopes", "value": [30, 60], "tier": 0,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "nurse_station": 1.2, "office": 0.5, "corridor": 0.3, "*": 0.15},
		"surfaces": ["counter", "tray", "gurney"], "containers": {"station_drawers": 0.5},
	},
	"pulse_oximeter": {
		"name": "Pulse oximeter", "short": "Pulse oximeters", "value": [25, 50], "tier": 0,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "nurse_station": 1.0, "*": 0.1},
		"surfaces": ["counter", "tray"], "containers": {"station_drawers": 0.6},
	},
	"bp_cuff": {
		"name": "Blood pressure cuff", "short": "Blood pressure cuffs", "value": [35, 70], "tier": 0,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "nurse_station": 0.9, "waiting_room": 0.3, "*": 0.1},
		"surfaces": ["counter", "tray", "gurney"], "containers": {"station_drawers": 0.4},
	},
	"thermometer": {
		"name": "Ear thermometer", "short": "Ear thermometers", "value": [15, 30], "tier": 0,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "nurse_station": 1.0, "*": 0.2},
		"surfaces": ["counter", "tray"], "containers": {"station_drawers": 0.7, "drawer_unit": 0.3},
	},
	"reflex_hammer": {
		"name": "Reflex hammer", "short": "Reflex hammers", "value": [10, 22], "tier": 0,
		"rooms": {"office": 1.0, "ward": 0.6, "patient_room": 0.6, "*": 0.2},
		"surfaces": ["counter", "tray"], "containers": {"drawer_unit": 0.4},
	},
	"pill_bottle": {
		"name": "Pill bottle", "short": "Pill bottles", "value": [12, 26], "tier": 0, "stack": true, "batch": [1, 3],
		"rooms": {"pharmacy": 1.6, "ward": 0.6, "patient_room": 0.6, "restroom": 0.5, "nurse_station": 0.6, "*": 0.15},
		"surfaces": ["counter", "tray"], "containers": {"med_fridge": 0.35, "station_drawers": 0.4},
	},
	"xray_film": {
		"name": "X-ray film", "short": "X-ray films", "value": [20, 45], "tier": 0,
		"rooms": {"radiology": 2.0, "office": 0.8, "storage": 0.4, "*": 0.1},
		"surfaces": ["counter", "gurney"], "containers": {"drawer_unit": 0.3},
	},
	"patient_records": {
		"name": "Patient records", "short": "Patient records", "value": [18, 40], "tier": 0,
		"rooms": {"office": 1.4, "nurse_station": 1.0, "waiting_room": 0.4, "*": 0.1},
		"surfaces": ["counter"], "containers": {"station_drawers": 0.5},
	},
	"desk_phone": {
		"name": "Desk phone", "short": "Desk phones", "value": [20, 40], "tier": 0,
		"rooms": {"office": 1.4, "nurse_station": 1.0, "waiting_room": 0.6, "break_room": 0.5, "*": 0.1},
		"surfaces": ["counter"], "containers": {},
	},
	"wheelchair_wheel": {
		"name": "Wheelchair wheel", "short": "Wheelchair wheels", "value": [25, 55], "tier": 0,
		"rooms": {"maintenance": 1.4, "storage": 1.0, "corridor": 0.6, "janitor": 0.8, "*": 0.1},
		"surfaces": ["floor", "gurney"], "containers": {},
	},
	"sample_rack": {
		"name": "Blood sample rack", "short": "Blood sample racks", "value": [40, 80], "tier": 1, "fragile": true,
		"rooms": {"lab": 2.0, "pharmacy": 0.8, "storage": 0.3, "*": 0.08},
		"surfaces": ["counter", "tray"], "containers": {"med_fridge": 0.5},
	},
	"otoscope": {
		"name": "Otoscope", "short": "Otoscopes", "value": [45, 90], "tier": 1,
		"rooms": {"office": 1.0, "ward": 0.7, "patient_room": 0.7, "nurse_station": 0.5, "*": 0.1},
		"surfaces": ["counter", "tray"], "containers": {"drawer_unit": 0.4, "station_drawers": 0.3},
	},
	"laptop": {
		"name": "Laptop", "short": "Laptops", "value": [110, 220], "tier": 2, "fragile": true,
		"rooms": {"office": 1.6, "nurse_station": 0.9, "lab": 0.8, "radiology": 0.6, "*": 0.08},
		"surfaces": ["counter"], "containers": {},
	},
	"gold_watch": {
		"name": "Gold watch", "short": "Gold watches", "value": [160, 380], "tier": 3,
		"rooms": {"office": 0.6, "waiting_room": 1.0, "morgue": 1.6, "restroom": 0.6, "*": 0.15},
		"surfaces": ["counter", "tray", "floor"], "containers": {"station_drawers": 0.3, "drawer_unit": 0.3},
	},
	"wedding_ring": {
		"name": "Wedding ring", "short": "Wedding rings", "value": [90, 240], "tier": 3,
		"rooms": {"restroom": 1.2, "morgue": 1.4, "waiting_room": 0.6, "*": 0.1},
		"surfaces": ["counter", "tray", "floor"], "containers": {"station_drawers": 0.2},
	},
	"coffee_maker": {
		"name": "Coffee maker", "short": "Coffee makers", "value": [40, 90], "tier": 0, "bulky": true, "fragile": true,
		"rooms": {"break_room": 1.6, "office": 1.0, "nurse_station": 1.0, "cafeteria": 1.4, "waiting_room": 0.5, "*": 0.05},
		"surfaces": ["counter"], "containers": {},
	},
	"heart_monitor": {
		"name": "Heart monitor", "short": "Heart monitors", "value": [170, 300], "tier": 2, "bulky": true, "fragile": true,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "nurse_station": 0.5, "storage": 0.4, "*": 0.05},
		"surfaces": ["counter", "gurney", "floor"], "containers": {},
	},
	"iv_pump": {
		"name": "IV pump", "short": "IV pumps", "value": [150, 270], "tier": 2, "bulky": true,
		"rooms": {"ward": 1.0, "patient_room": 1.0, "storage": 0.8, "corridor": 0.3, "*": 0.05},
		"surfaces": ["counter", "gurney", "floor"], "containers": {},
	},
	"defibrillator": {
		"name": "Defibrillator", "short": "Defibrillators", "value": [240, 440], "tier": 3, "bulky": true,
		"rooms": {"corridor": 1.0, "nurse_station": 1.0, "ward": 0.6, "waiting_room": 0.6, "*": 0.05},
		"surfaces": ["floor", "counter", "gurney"], "containers": {},
	},
	"microscope": {
		"name": "Microscope", "short": "Microscopes", "value": [220, 380], "tier": 3, "bulky": true, "fragile": true,
		"rooms": {"lab": 2.0, "pharmacy": 0.6, "storage": 0.3, "*": 0.03},
		"surfaces": ["counter"], "containers": {},
	},
	"ultrasound": {
		"name": "Portable ultrasound", "short": "Portable ultrasounds", "value": [320, 560], "tier": 3, "bulky": true, "fragile": true,
		"rooms": {"radiology": 2.0, "ward": 0.3, "storage": 0.3, "*": 0.02},
		"surfaces": ["counter", "gurney"], "containers": {},
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
}

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
