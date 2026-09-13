extends RefCounted
## What the guide says, derived from the shared data. No layout here, only content, so it can
## be checked headlessly and so a new entry in Items.ITEMS, Procedures.AILMENTS or Items.LOCKED
## shows up in the binder (tab, contents line, page) without touching the UI.

const ItemsDB := preload("res://scripts/items.gd")
const ProceduresDB := preload("res://scripts/procedures.gd")
const Art := preload("res://scripts/guide/guide_art.gd")

## One line per minigame id: what the step asks of your hands.
const GAME_HOW := {
	"anesthetic": "Draw to the dose line for the patient's weight, then hold the needle steady on the vein.",
	"forceps": "Steer through the wound to the bullet and back out without touching the sides.",
	"tourniquet": "Place it above the infection line and crank it to the right pressure.",
	"saw": "Long, steady strokes along the cut line.",
	"gauze:pack": "Pack the wound with even tension.",
	"gauze:stump": "Wrap the stump with even tension.",
	"gauze": "Pack the wound or wrap the stump with even tension.",
}

## Handwritten margin notes. Items without an entry get notes derived from their data.
const ITEM_NOTES := {
	"anesthetic": ["dose by WEIGHT. %s", "don't drop the vials"],
	"gauze": ["amputation eats %s rolls. bring spares"],
	"forceps": ["DON'T touch the sides!!"],
	"tourniquet": ["ABOVE the line. above."],
	"bone_saw": ["slow. slower than that."],
	"guide": ["who keeps taking this??", "chain cut AGAIN. - facilities"],
}

const PROCEDURE_NOTES := {
	"gunshot": "nobody is admitting to anything",
	"amputation": "count the rolls BEFORE you start",
}

const LOCKED_SCRAWLS := [
	"Supply says these pages are \"on order\".",
	"Torn out. Why would you tear these out.",
	"Coming next shift. Allegedly.",
	"Ask days. (Days will not know.)",
	"New section pending sign-off.",
]


## Every page of the binder, in order. Each entry is one two-page spread and one tab.
## {id, type: "index"|"item"|"procedure"|"locked", key, title, tab, colour, page}
static func entries() -> Array:
	var out: Array = []
	out.append({"id": "", "type": "index", "key": "", "title": "Contents", "tab": "Index", "colour": Art.INDEX_TAB})
	var i := 0
	for kind in item_order():
		out.append({"id": kind, "type": "item", "key": kind, "title": ItemsDB.display_name(kind),
			"tab": ItemsDB.display_name(kind), "colour": Art.tab_colour(i)})
		i += 1
	for ailment_id in ProceduresDB.AILMENTS.keys():
		var a: Dictionary = ProceduresDB.AILMENTS[ailment_id]
		out.append({"id": "procedure:" + ailment_id, "type": "procedure", "key": ailment_id,
			"title": a.get("name", ailment_id.capitalize()), "tab": a.get("name", ailment_id.capitalize()),
			"colour": Art.PROCEDURE_TAB})
	for locked_name in ItemsDB.LOCKED:
		out.append({"id": "locked:" + locked_name, "type": "locked", "key": locked_name, "title": locked_name,
			"tab": locked_name, "colour": Art.LOCKED_TAB})
	for n in out.size():
		out[n]["page"] = n * 2 + 1
	return out


## Surgical items in Items.SURGICAL order, any other surgical ones, then everything else.
static func item_order() -> Array:
	var out: Array = []
	for kind in ItemsDB.SURGICAL:
		if ItemsDB.ITEMS.has(kind):
			out.append(kind)
	for kind in ItemsDB.ITEMS.keys():
		if not out.has(kind) and ItemsDB.is_surgical(kind):
			out.append(kind)
	for kind in ItemsDB.ITEMS.keys():
		if not out.has(kind):
			out.append(kind)
	return out


static func index_of(entries_list: Array, page_id: String) -> int:
	for n in entries_list.size():
		if entries_list[n].id == page_id:
			return n
	# Accept a bare ailment id or a locked name too.
	for n in entries_list.size():
		if entries_list[n].key == page_id and page_id != "":
			return n
	return 0


## Rough middle of the batch range, which is what you usually find.
static func typical_batch(kind: String) -> int:
	var b: Array = ItemsDB.def(kind).get("batch", [1, 1])
	return maxi(1, roundi((float(b[0]) + float(b[b.size() - 1])) * 0.5))


static func _humanise(room: String) -> String:
	return room.replace("_", " ")


static func _or_list(words: Array) -> String:
	if words.is_empty():
		return ""
	if words.size() == 1:
		return words[0]
	return ", ".join(words.slice(0, words.size() - 1)) + " or " + words[words.size() - 1]


## "the medicine fridge (pharmacy, storage)" or "left out loose on a counter or tray"
static func place_name(kind: String, place: String) -> String:
	if place == "loose":
		var surfaces: Array = ItemsDB.def(kind).get("loose_surfaces", [])
		if surfaces.is_empty():
			return "left out loose"
		var words: Array = []
		for s in surfaces:
			words.append(("the " if s == "floor" else "a ") + _humanise(s))
		return "left out on " + _or_list(words)
	var ct: Dictionary = ItemsDB.CONTAINER_TYPES.get(place, {})
	if ct.is_empty():
		return _humanise(place)
	var rooms: Array = []
	for r in ct.get("rooms", []):
		rooms.append(_humanise(r))
	var n: String = ct.get("name", _humanise(place))
	return "%s (%s)" % [n, ", ".join(rooms)] if not rooms.is_empty() else n


## {most: [names], sometimes: [names]} from the `found` weights, most likely first.
static func where_split(kind: String) -> Dictionary:
	var found: Dictionary = ItemsDB.def(kind).get("found", {})
	var places := found.keys()
	places.sort_custom(func(a, b): return float(found[a]) > float(found[b]))
	var most: Array = []
	var sometimes: Array = []
	if not places.is_empty():
		var top := float(found[places[0]])
		for p in places:
			if float(found[p]) >= top * 0.75:
				most.append(place_name(kind, p))
			else:
				sometimes.append(place_name(kind, p))
	return {"most": most, "sometimes": sometimes}


## "Gunshot wound, step 2: Remove the bullet" for every step that uses this item.
static func used_in(kind: String) -> Array:
	var out: Array = []
	for ailment_id in ProceduresDB.AILMENTS.keys():
		var a: Dictionary = ProceduresDB.AILMENTS[ailment_id]
		var steps: Array = a.get("steps", [])
		for n in steps.size():
			if steps[n].get("item", "") == kind:
				out.append({"text": "%s, step %d: %s" % [a.get("name", ailment_id), n + 1, steps[n].get("label", "")],
					"link": "procedure:" + ailment_id})
	return out


static func step_how(step: Dictionary) -> String:
	var g: String = step.get("game", "")
	var v: String = step.get("variant", "")
	if v != "" and GAME_HOW.has(g + ":" + v):
		return GAME_HOW[g + ":" + v]
	return GAME_HOW.get(g, "Do your best. Nobody wrote this one down.")


static func stamps(kind: String) -> Array:
	var d := ItemsDB.def(kind)
	var out: Array = []
	if not d.get("surgical", false):
		out.append("NOT SURGICAL")
	elif d.get("consumable", false):
		out.append("CONSUMABLE")
	else:
		out.append("REUSABLE")
	if d.get("fragile", false):
		out.append("FRAGILE")
	return out


static func weights_line() -> String:
	var parts: Array = []
	for pid in ProceduresDB.PATIENTS.keys():
		var p: Dictionary = ProceduresDB.PATIENTS[pid]
		parts.append("%s %d kg" % [p.get("name", pid), roundi(float(p.get("weight_kg", 0.0)))])
	return ", ".join(parts)


static func item_notes(kind: String) -> Array:
	var out: Array = []
	for note in ITEM_NOTES.get(kind, []):
		var s: String = note
		if s.contains("%s"):
			if kind == "anesthetic":
				s = s % weights_line()
			else:
				var most := 0
				for ailment_id in ProceduresDB.AILMENTS.keys():
					most = maxi(most, int(ProceduresDB.requirements(ailment_id).get(kind, 0)))
				s = s % str(most)
		out.append(s)
	if out.is_empty():
		if ItemsDB.is_fragile(kind):
			out.append("DON'T drop it")
		elif used_in(kind).is_empty():
			out.append("not needed for anything yet?")
		else:
			out.append("check the checklist first")
	return out


static func item_page(kind: String) -> Dictionary:
	var d := ItemsDB.def(kind)
	var batch: Array = d.get("batch", [1, 1])
	var count := typical_batch(kind)
	var caption := ""
	if int(batch[batch.size() - 1]) <= 1:
		caption = "one (1). that's all there is."
	else:
		caption = "a batch of %d, as found" % count
	return {
		"kind": kind,
		"name": d.get("name", kind.capitalize()),
		"real_use": d.get("real_use", ""),
		"where": d.get("where", ""),
		"where_split": where_split(kind),
		"used_in": used_in(kind),
		"handling": d.get("handling", ""),
		"stamps": stamps(kind),
		"notes": item_notes(kind),
		"count": count,
		"caption": caption,
	}


static func procedure_page(ailment_id: String) -> Dictionary:
	var a := ProceduresDB.ailment(ailment_id)
	var steps: Array = []
	var has_sedation := false
	var has_tourniquet := false
	for s in a.get("steps", []):
		var item: String = s.get("item", "")
		var uses := int(s.get("uses", 0))
		if s.get("game", "") == "anesthetic":
			has_sedation = true
		if s.get("game", "") == "tourniquet":
			has_tourniquet = true
		steps.append({
			"label": s.get("label", ""),
			"item": item,
			"item_name": ItemsDB.display_name(item),
			"needs": ("%s, uses %d" % [ItemsDB.display_name(item), maxi(1, uses)]) if ItemsDB.is_consumable(item)
				else ("%s (kept)" % ItemsDB.display_name(item)),
			"how": step_how(s),
		})
	var shopping: Array = []
	var req := ProceduresDB.requirements(ailment_id)
	for kind in item_order():
		if req.has(kind):
			shopping.append({"kind": kind, "name": ItemsDB.display_name(kind), "count": int(req[kind]),
				"consumable": ItemsDB.is_consumable(kind), "fragile": ItemsDB.is_fragile(kind)})
	for kind in req.keys():
		if not item_order().has(kind):
			shopping.append({"kind": kind, "name": ItemsDB.display_name(kind), "count": int(req[kind]),
				"consumable": ItemsDB.is_consumable(kind), "fragile": ItemsDB.is_fragile(kind)})
	var warnings: Array = []
	if has_sedation:
		warnings.append("Underdose and the patient stirs in the later steps.")
	if has_tourniquet:
		warnings.append("A weak tourniquet makes the saw step bloody.")
	warnings.append("Every botch costs vitals. Vitals do not come back on their own.")
	var patients: Array = []
	for pid in ProceduresDB.PATIENTS.keys():
		var p: Dictionary = ProceduresDB.PATIENTS[pid]
		patients.append("%s: %d kg" % [p.get("full_name", pid), roundi(float(p.get("weight_kg", 0.0)))])
	return {
		"id": ailment_id,
		"name": a.get("name", ailment_id.capitalize()),
		"code": a.get("code", ""),
		"steps": steps,
		"shopping": shopping,
		"warnings": warnings,
		"patients": patients,
		"note": PROCEDURE_NOTES.get(ailment_id, "tick them off as you go"),
	}


static func locked_page(locked_name: String) -> Dictionary:
	var pick := posmod(hash(locked_name), LOCKED_SCRAWLS.size())
	return {"name": locked_name, "scrawl": LOCKED_SCRAWLS[pick]}
