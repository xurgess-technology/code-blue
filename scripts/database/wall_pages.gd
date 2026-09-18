extends RefCounted
## What the break room's wall terminal shows (terminal redesign, chunk 2), as data: the four
## sections, the entries in each, and every entry's page. wall_terminal_ui.gd draws it.
##
##   SECTIONS                          [{id, title}] in home-grid order
##   entries(section, view) -> Array   [{key, title, known}]; unknown entries show "???" and can't open
##   page(section, key, view) -> Dict  {title, subtitle, paragraphs: [String], hint, models: [{monster} |
##                                      {item, count, link, label}], ability: {name, levels: [String]}
##                                      (monsters); a procedure's steps are a paragraph and its tools
##                                      links (link: a surgery item's key, label over it when pointed at)
##
## `view` is whose database the screen shows (wall_session.gd view()): {db: {kind: bits (1 sighted,
## 2 scanned, 4 harvested)}, peer, brains}; nobody signed in is an empty db and peer 0.
## Known: surgery items and procedures always; a monster once scanned; any other item once picked
## up (game.mark_db(kind, "sighted", player) in pickup_item). Ability names show once harvested,
## each level's numbers once the player's brain level reaches it.

const MonsterPages := preload("res://scripts/database/monster_pages.gd")
const Pages := preload("res://scripts/database/database_pages.gd")
const ItemsDB := preload("res://scripts/items.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")
const ProceduresDB := preload("res://scripts/procedures.gd")

const SECTIONS := [
	{"id": "monsters", "title": "MONSTERS"},
	{"id": "procedures", "title": "PROCEDURES"},
	{"id": "surgery", "title": "SURGERY ITEMS"},
	{"id": "other", "title": "OTHER ITEMS"},
]

## Which brain path a monster's ability grows on, and its name.
const ABILITY := {"hive": "Hive Eyes", "discharged": "Echo"}

const MONSTER_TEXT := {
	"hive": ["Wanders the wings until it hears something. It can't see: running, dropping things and shoving give you away.", "About 2 doses of anesthetic put it under."],
	"discharged": ["Big, slow and relentless. It hunts by sound and smell, and once it has your trail it doesn't let go.", "It takes about 3 doses to put it under."],
	"night_nurse": ["She only moves when nobody is looking at her. Keep your eyes on her.", "Nobody knows what happens if she reaches you."],
}

const PROCEDURE_TEXT := {
	"gunshot": "A bullet is still inside the patient. Get it out and stop the bleeding.",
	"amputation": "An infected limb that can't be saved. Take it off before the infection spreads.",
	"stitches": "A downed teammate with a deep gash. Stitch it shut and they get back up.",
	"dissection": "A sedated monster on the table. Open the skull and pull out the brain.",
}

const SURGERY_TEXT := {
	"anesthetic": ["Puts the patient under so they don't feel a thing. Too little and they wake up mid-surgery.", "Found in medicine fridges. Glass: dropping it breaks some."],
	"gauze": ["Rolls of dressing that pack wounds and soak up bleeding.", "Found in nurse station drawers."],
	"forceps": ["Long tongs for pulling out bullets, and brains.", "Found in steel drawer units. Kept after use."],
	"tourniquet": ["A strap that cuts off the blood to a limb before you saw.", "Found in trauma bags. Kept after use."],
	"bone_saw": ["Cuts through bone: infected limbs, and monster skulls.", "Found on pegboards. Kept after use."],
	"suture_kit": ["Needle and thread for closing a downed teammate's wound.", "Found in trauma bags and drawers."],
}

const LOOT_BLURBS := {
	"stethoscope": "A nurse's stethoscope.",
	"pulse_oximeter": "A fingertip clip that reads blood oxygen.",
	"bp_cuff": "A blood pressure cuff with its rubber bulb.",
	"thermometer": "An ear thermometer.",
	"reflex_hammer": "A little rubber reflex hammer.",
	"pill_bottle": "Somebody's prescription. Stacks with others.",
	"xray_film": "An X-ray of someone's ribs.",
	"patient_records": "A folder of patient files.",
	"desk_phone": "A desk phone, ripped off its cord.",
	"wheelchair_wheel": "A bent wheelchair wheel.",
	"sample_rack": "A rack of blood samples. Cracks if dropped.",
	"otoscope": "The light you look in ears with.",
	"laptop": "A hospital laptop. Fragile.",
	"gold_watch": "A patient's gold watch, still ticking.",
	"wedding_ring": "A wedding ring left on a tray.",
	"coffee_maker": "A coffee maker. Takes both hands.",
	"heart_monitor": "A bedside heart monitor. Takes both hands.",
	"iv_pump": "An IV pump. Takes both hands.",
	"defibrillator": "A portable defibrillator. Takes both hands.",
	"microscope": "A lab microscope. Fragile, takes both hands.",
	"ultrasound": "A portable ultrasound. The best find in the wings.",
	"brain_hive": "A Hive's brain. Drink it to grow Hive Eyes.",
	"brain_discharged": "A Discharged brain. Drink it to grow Echo.",
}


# ---------------------------------------------------------------------------
# entries

static func entries(section: String, view: Dictionary) -> Array:
	var out: Array = []
	match section:
		"monsters":
			for kind in MonsterPages.ORDER:
				out.append({"key": kind, "title": String(MonsterPages.entry(kind).get("name", kind)), "known": _tier(view, kind) >= 2})
		"procedures":
			for id in ProceduresDB.AILMENTS.keys():
				out.append({"key": id, "title": String(ProceduresDB.AILMENTS[id].get("name", id)), "known": true})
		"surgery":
			for kind in Pages.item_order():
				if ItemsDB.is_surgical(kind):
					out.append({"key": kind, "title": ItemsDB.display_name(kind), "known": true})
		"other":
			for kind in _other_kinds():
				out.append({"key": kind, "title": ItemsDB.display_name(kind), "known": _found(view, kind)})
	return out


static func _other_kinds() -> Array:
	var out: Array = []
	for kind in Pages.item_order():
		if not ItemsDB.is_surgical(kind):
			out.append(kind)
	for kind in LootTable.kinds():
		if not out.has(kind):
			out.append(kind)
	return out


# ---------------------------------------------------------------------------
# pages

static func page(section: String, key: String, view: Dictionary) -> Dictionary:
	match section:
		"monsters":
			return _monster(key, view)
		"procedures":
			return _procedure(key)
		"surgery":
			return _item(key)
		"other":
			return _other(key)
	return {}


static func _monster(kind: String, view: Dictionary) -> Dictionary:
	var e := MonsterPages.entry(kind)
	var p := {
		"title": String(e.get("name", kind)).to_upper(),
		"subtitle": "SCANNED SPECIMEN",
		"paragraphs": MONSTER_TEXT.get(kind, []),
		"models": [{"monster": kind}],
	}
	var tier := _tier(view, kind)
	var name := "???"
	var levels: Array = ["???", "???", "???"]
	if ABILITY.has(kind):
		var lvl := _level(view, kind)
		if tier >= 3 or lvl >= 1:
			name = String(ABILITY[kind]).to_upper()
		for n in range(1, 4):
			var brains = view.get("brains")
			if lvl >= n and brains != null:
				if kind == "hive":
					levels[n - 1] = "Reach %.0f m, watch for %.1f s" % [brains.hive_range(n), brains.hive_seconds(n)]
				else:
					levels[n - 1] = "Radius %.0f m, lasts %.1f s" % [brains.echo_radius(n), brains.echo_seconds(n)]
	p["ability"] = {"name": name, "levels": levels}
	return p


static func _procedure(id: String) -> Dictionary:
	var d := Pages.procedure_page(id)
	var steps: Array = []
	var kinds: Array = []
	for s in d.steps:
		steps.append({"label": String(s.label), "item": String(s.item), "item_name": String(s.item_name)})
		if String(s.item) != "" and not kinds.has(String(s.item)):
			kinds.append(String(s.item))
	# Each tool on the turntable is a link: point at it for its name, click it for its page.
	var models: Array = []
	for k in kinds:
		models.append({"item": k, "count": 2 if ItemsDB.is_consumable(k) else 1, "link": k, "label": ItemsDB.display_name(k)})
	var lines: Array = []
	for n in steps.size():
		lines.append("%d.  %s  (%s)" % [n + 1, steps[n].label, steps[n].item_name])
	return {
		"title": String(d.name).to_upper(),
		"subtitle": "PROCEDURE  %s" % String(d.get("code", "")),
		"paragraphs": [String(PROCEDURE_TEXT.get(id, "")), "\n".join(lines)],
		"hint": "Point at a tool for its name. Click it to look it up.",
		"models": models,
	}


static func _item(kind: String) -> Dictionary:
	var d := Pages.item_page(kind)
	return {
		"title": String(d.name).to_upper(),
		"subtitle": "SURGERY ITEM",
		"paragraphs": SURGERY_TEXT.get(kind, [String(d.real_use)]),
		"models": [{"item": kind, "count": 3 if ItemsDB.is_consumable(kind) else 1}],
	}


static func _other(kind: String) -> Dictionary:
	if kind == "placebo_pills":
		return {
			"title": "PLACEBO PILLS",
			"subtitle": "PHARMACY",
			"paragraphs": ["Sugar pills from the pharmacy. They do nothing. Probably.", "Order them on the lobby fax."],
			"models": [{"item": kind, "count": 1}],
		}
	var def := LootTable.def(kind)
	var value: Array = def.get("value", [0, 0])
	var worth := "Sells for $%d to $%d at the furnace." % [int(value[0]), int(value[value.size() - 1])]
	if kind.begins_with("brain_"):
		worth = "Or sell it at the furnace, before it spoils."
	return {
		"title": ItemsDB.display_name(kind).to_upper(),
		"subtitle": "SALVAGE",
		"paragraphs": [String(LOOT_BLURBS.get(kind, "")), worth],
		"models": [{"item": kind, "count": 1}],
	}


# ---------------------------------------------------------------------------
# what this player knows

static func _tier(view: Dictionary, kind: String) -> int:
	var bits := int((view.get("db", {}) as Dictionary).get(kind, 0))
	if bits & 4:
		return 3
	if bits & 2:
		return 2
	return 1 if bits & 1 else 0


static func _found(view: Dictionary, kind: String) -> bool:
	return _tier(view, kind) >= 1


static func _level(view: Dictionary, path: String) -> int:
	var brains = view.get("brains")
	if brains == null or int(view.get("peer", 0)) == 0:
		return 0
	return int(brains.level(int(view.peer), path))
