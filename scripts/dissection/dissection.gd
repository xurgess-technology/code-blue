extends Node
## dissection (sweep 3): strapped monsters on the patient tables. See docs/SWEEP3.md ("Dissection")
## and docs/CONTRACTS.md ("Dissection").
##
## A monster case is a normal game case with `monster: true`, `patient_id` hive | discharged and
## `ailment_id` "dissection" (Procedures). The surgery systems operate it like any patient; this
## node adds what only a monster has, all host authoritative:
##
## - Sedation (flags.sedation) wears off: SEDATION_SECONDS from 1 to 0, SAW_MULT faster while the
##   bone saw is in the kerf. 0.35..0.75 it stirs (the surgery system's stir code), under AWAKE it
##   is awake: it thrashes, shrieks (noise), and botches THRASH_BOTCH every THRASH_EVERY while
##   someone operates.
##   Replication: the host keeps the precise value here and writes the case flag snapped to
##   FLAG_STEP (so the case is not resent every tick); `dx.s` carries every monster case's value in
##   hundredths and clients put it back into their case flags right after the cases apply.
## - Re-dosing: anyone holding anesthetic presses E on the table (also while someone operates):
##   one vial, +DOSE * DOSE_FALLOFF^n (n = doses so far, case field `doses`), capped at 1.
## - Vitals are the brain's condition: nothing drains them and nothing gives them back (the step
##   bonus is taken away again). At 0 the case is lost. The last step hands the brain over by the
##   table (game.brains.spawn_brain, or a plain loot item), the monster flatlines, and the case stays
##   as a body until someone burns it (scripts/loop/corpses.gd).

const SEDATION_SECONDS := 120.0
const SAW_MULT := 2.5
const STIR := 0.75
const AWAKE := 0.35
const DOSE := 0.6
const DOSE_FALLOFF := 0.6
const THRASH_BOTCH := 1.5
const THRASH_EVERY := 3.0
const SHRIEK_NOISE := 0.7
const SHRIEK_EVERY := Vector2(3.5, 6.5)
const REMOVE_AFTER := 6.0
const FLAG_STEP := 0.05
const BRAIN_KINDS := {"hive": "brain_hive", "discharged": "brain_discharged"}
const LootTable := preload("res://scripts/economy/loot_table.gd")
## Fallback when the brains system has no spawn_brain: a plain loot item worth this much at quality 1.
const FALLBACK_KIND := "sample_rack"
const FALLBACK_VALUE := {"hive": 150, "discharged": 350}

var game: Node = null

# host
var _sed := {}          # case id -> precise sedation
var _cond := {}         # case id -> brain condition last tick (it never goes up)
var _thrash_t := {}     # case id -> seconds until the next thrash botch while operated
var _shriek_t := {}     # case id -> seconds until the next shriek while awake
var _remove_at := {}    # case id -> world_time to remove the finished case

# every machine (cosmetic)
var _creak_t := {}      # table -> seconds until the next strap creak
var _rng := RandomNumberGenerator.new()

## Tests: the last brain handed over {kind, quality, pos, node}.
var last_brain: Dictionary = {}
## GRAFTING part one: the peer who was operating when the last case finished (set by game.finish_case),
## who gets the extracted eye in their hand; tests read last_eye {kind, quality, node, peer}.
var last_operator := 0
var last_eye: Dictionary = {}


func setup(g: Node) -> void:
	game = g
	_rng.seed = 7127


## Every machine: is this case a strapped monster this system runs (no vitals drain, no pay)?
func owns_case(c: Dictionary) -> bool:
	return bool(c.get("monster", false)) or Procedures.is_monster(String(c.get("patient_id", "")))


## Every machine: the case lying on this table is a strapped monster (any state but incoming).
func owns_table(table_index: int) -> bool:
	if game == null or not game.has_method("case_on_table"):
		return false
	var c: Dictionary = game.case_on_table(table_index)
	return not c.is_empty() and owns_case(c)


## Every machine: a monster case's sedation (host: the precise value; clients: the replicated one).
func sedation(c: Dictionary) -> float:
	var id := int(c.get("id", -1))
	if game != null and game.is_host() and _sed.has(id):
		return float(_sed[id])
	var flags = c.get("flags", {})
	return float(flags.get("sedation", 1.0)) if flags is Dictionary else 1.0


## GRAFTING part one: what a strapped Hive would be given by what p holds, before its first step: the
## scalpel makes it Eyeball Extraction, the bone saw Dissection. Anything else keeps what it has.
func ailment_for(c: Dictionary, p) -> String:
	var cur := String(c.get("ailment_id", ""))
	if String(c.get("patient_id", "")) != "hive" or int(c.get("step_index", 0)) != 0:
		return cur
	if cur != "dissection" and cur != "eye_extraction":
		return cur
	if p == null or not p.has_method("selected_stack"):
		return cur
	match String(p.selected_stack().get("kind", "")):
		"scalpel":
			return "eye_extraction"
		"bone_saw":
			return "dissection"
	return cur


## Host: before an operation starts, the case takes the ailment p's tool asks for (ailment_for).
func _pick_ailment(p, c: Dictionary) -> void:
	var a := ailment_for(c, p)
	if a != String(c.get("ailment_id", "")):
		var sys = game.surgery_for_table(int(c.get("table", -1)))
		if sys != null and int(sys.operator_id) != 0:
			return
		c["ailment_id"] = a
		game._apply_cases_locally()


## 0 asleep .. "stirring" .. "awake".
static func sedation_state(s: float) -> String:
	if s < AWAKE:
		return "awake"
	if s < STIR:
		return "stirring"
	return "under"


## How much the next dose adds after `doses_given` doses.
static func dose_amount(doses_given: int) -> float:
	return DOSE * pow(DOSE_FALLOFF, float(maxi(0, doses_given)))


static func brain_kind(patient_id: String) -> String:
	return String(BRAIN_KINDS.get(patient_id, "brain_" + patient_id))


# =============================================================================== frame

func physics_tick(delta: float) -> void:
	if game == null or game.get("cases") == null:
		return
	if game.is_host():
		_host_tick(delta)
	_cosmetic_tick(delta)


func _host_tick(delta: float) -> void:
	var in_shift: bool = int(game.phase) == int(game.Phase.SHIFT)
	var seen := {}
	for c in (game.cases as Array).duplicate():
		if not owns_case(c):
			continue
		var id := int(c.get("id", -1))
		seen[id] = true
		var state := String(c.get("state", ""))
		if state == "stable" or state == "dead":
			# Patient exits: the dead monster is a body now (corpses.gd); it goes when it is burned.
			continue
		if state != "on_table" or not in_shift:
			continue
		var flags: Dictionary = c.get("flags", {})
		if not (c.get("flags") is Dictionary):
			c["flags"] = flags
		# Sedation wears off, faster while the saw is biting.
		var s := float(_sed.get(id, float(flags.get("sedation", 1.0))))
		var rate := 1.0 / SEDATION_SECONDS * (SAW_MULT if sawing(c) else 1.0)
		s = maxf(0.0, s - rate * delta)
		_sed[id] = s
		var snapped := snappedf(s, FLAG_STEP)
		if absf(float(flags.get("sedation", -1.0)) - snapped) > 0.001:
			flags["sedation"] = snapped
		# The brain's condition only ever goes down (surgery_step_done gives patients vitals back).
		var v := float(c.get("vitals", 100.0))
		var last := float(_cond.get(id, v))
		if v > last:
			v = last
			c["vitals"] = v
		_cond[id] = v
		if v <= 0.0:
			c["vitals"] = 0.0
			game.finish_case(id, false)
			continue
		var table := int(c.get("table", -1))
		if s < AWAKE:
			_shriek_t[id] = float(_shriek_t.get(id, 0.8)) - delta
			if float(_shriek_t[id]) <= 0.0:
				_shriek_t[id] = _rng.randf_range(SHRIEK_EVERY.x, SHRIEK_EVERY.y)
				var at: Vector3 = game.table_position(table)
				game.emit_noise(at, SHRIEK_NOISE, "shriek")
				_fx_shriek(table)
				game._broadcast("dx_shriek", {"tb": table})
			var sys = game.surgery_for_table(table)
			if sys != null and int(sys.operator_id) != 0:
				_thrash_t[id] = float(_thrash_t.get(id, THRASH_EVERY)) - delta
				if float(_thrash_t[id]) <= 0.0:
					_thrash_t[id] = THRASH_EVERY
					game.surgery_botch(THRASH_BOTCH, "It's awake and thrashing against the straps", table)
			else:
				_thrash_t[id] = THRASH_EVERY
		else:
			_thrash_t[id] = THRASH_EVERY
			_shriek_t[id] = 0.8
	for id in _sed.keys():
		if not seen.has(id):
			_forget(int(id))


func _forget(id: int) -> void:
	for dct in [_sed, _cond, _thrash_t, _shriek_t, _remove_at]:
		dct.erase(id)


## Host: someone is sawing this monster's skull right now (the blade held in the kerf).
func sawing(c: Dictionary) -> bool:
	var sys = game.surgery_for_table(int(c.get("table", -1))) if game.has_method("surgery_for_table") else null
	if sys == null or int(sys.operator_id) == 0:
		return false
	var step := Procedures.step(String(c.get("ailment_id", "")), int(c.get("step_index", 0)))
	if String(step.get("game", "")) != "saw":
		return false
	var mg = sys.get("mg")
	return mg != null and is_instance_valid(mg) and bool(mg.get("held"))


## Every machine: strap creaks while a monster thrashes (local, cosmetic).
func _cosmetic_tick(delta: float) -> void:
	for c in game.cases:
		if not owns_case(c) or String(c.get("state", "")) != "on_table":
			continue
		var table := int(c.get("table", -1))
		if sedation(c) >= AWAKE:
			_creak_t.erase(table)
			continue
		var t := float(_creak_t.get(table, 0.3)) - delta
		if t <= 0.0:
			t = _rng.randf_range(0.5, 1.3)
			_audio("dissection_strap", game.table_position(table) + Vector3.UP * 0.9, -4.0)
		_creak_t[table] = t


# =============================================================================== replication

func net_state() -> Dictionary:
	var s := {}
	if game == null or game.get("cases") == null:
		return {}
	for c in game.cases:
		if owns_case(c) and String(c.get("state", "")) == "on_table":
			var id := int(c.get("id", -1))
			s[str(id)] = roundi(float(_sed.get(id, float(c.get("flags", {}).get("sedation", 1.0)))) * 100.0)
	return {"s": s} if not s.is_empty() else {}


func apply_net_state(d: Dictionary) -> void:
	if game == null or game.is_host():
		return
	var s: Dictionary = d.get("s", {})
	if s.is_empty():
		return
	for c in game.cases:
		var key := str(int(c.get("id", -1)))
		if s.has(key) and owns_case(c):
			if not (c.get("flags") is Dictionary):
				c["flags"] = {}
			c.flags["sedation"] = float(s[key]) / 100.0


func on_event(kind: String, data: Dictionary) -> void:
	match kind:
		"dx_shriek":
			_fx_shriek(int(data.get("tb", -1)))
		"dx_dose":
			_fx_dose(int(data.get("tb", -1)))
		"dx_flatline":
			_fx_flatline(int(data.get("tb", -1)))


func _fx_shriek(table: int) -> void:
	if table < 0:
		return
	var at: Vector3 = game.table_position(table) + Vector3.UP * 1.0
	_audio("dissection_shriek", at, 0.0)
	var body = game.body_for_table(table)
	if body != null and body.has_method("stir"):
		body.stir(0.9)


func _fx_dose(table: int) -> void:
	if table < 0:
		return
	_audio("dissection_inject", game.table_position(table) + Vector3.UP * 1.0, -2.0)


func _fx_flatline(table: int) -> void:
	var body = game.body_for_table(table)
	if body != null and body.has_method("flatline"):
		body.flatline()


# =============================================================================== the table

## The table's interact prompt for a strapped monster (game._table_prompt hands over to this).
func table_prompt(p, table_index: int) -> String:
	var c: Dictionary = game.case_on_table(table_index)
	if c.is_empty():
		return ""
	var pname := String(Procedures.patient(String(c.patient_id)).get("name", "The monster"))
	match String(c.get("state", "")):
		"stable":
			return "!The brain is out."
		"dead":
			return "!The brain is ruined."
	var s := sedation(c)
	var sed_txt := "sedation %d%%" % roundi(s * 100.0)
	if s < AWAKE:
		sed_txt = "AWAKE, sedation %d%%" % roundi(s * 100.0)
	if p != null and _anesthetic_slot(p) >= 0:
		var next := minf(1.0, s + dose_amount(int(c.get("doses", 0)))) - s
		return "Re-dose %s (%s, +%d%%)" % [pname, sed_txt, roundi(next * 100.0)]
	if p != null and String(c.patient_id) == "hive" and int(c.step_index) == 0:
		var held_kind := String(p.selected_stack().get("kind", ""))
		if held_kind != "scalpel" and held_kind != "bone_saw":
			return "!Hold the bone saw to dissect, or the scalpel to take an eye (%s)" % sed_txt
	var step := Procedures.step(ailment_for(c, p), int(c.step_index))
	var sys = game.surgery_for_table(table_index)
	if step.is_empty() or sys == null:
		return ""
	var why: String = sys.can_begin(p)
	if why != "":
		return "!%s (%s)" % [why, sed_txt]
	return "Operate: %s (%s)" % [step.label, sed_txt]


## Host, from game._proxy_used: E on a strapped monster's table. True when it was a re-dose (the
## press is used up), false to let the table start an operation as usual.
func table_used(p, table_index: int) -> bool:
	if p == null or not game.is_host():
		return false
	var c: Dictionary = game.case_on_table(table_index)
	if c.is_empty() or not owns_case(c) or String(c.get("state", "")) != "on_table":
		return false
	if _anesthetic_slot(p) < 0:
		_pick_ailment(p, c)   # GRAFTING part one: the scalpel means Eyeball Extraction
		return false
	redose(p, table_index)
	return true


## Host: one vial from p's hands into the monster on this table. Returns the sedation added (0 when
## nothing happened).
func redose(p, table_index: int) -> float:
	var c: Dictionary = game.case_on_table(table_index)
	if c.is_empty() or not owns_case(c) or String(c.get("state", "")) != "on_table":
		return 0.0
	var slot := _anesthetic_slot(p)
	if slot < 0:
		return 0.0
	var st: Dictionary = p.slots[slot]
	st["count"] = int(st.get("count", 0)) - 1
	if int(st.count) <= 0:
		p.clear_slot(slot)
	var id := int(c.get("id", -1))
	var n := int(c.get("doses", 0))
	var s := sedation(c)
	var ns := minf(1.0, s + dose_amount(n))
	_sed[id] = ns
	c["doses"] = n + 1
	var flags: Dictionary = c.get("flags", {})
	flags["sedation"] = snappedf(ns, FLAG_STEP)
	c["flags"] = flags
	_thrash_t[id] = THRASH_EVERY
	_fx_dose(table_index)
	game._broadcast("dx_dose", {"tb": table_index})
	var pname := String(Procedures.patient(String(c.patient_id)).get("name", "The monster"))
	var weaker := "" if n == 0 else " Each dose works for less time."
	game.tell(p, "%s is under again: sedation %d%%.%s" % [pname, roundi(ns * 100.0), weaker], 3.0)
	return ns - s


## The hand slot p would re-dose from: the selected stack when it is anesthetic, else any.
func _anesthetic_slot(p) -> int:
	if p == null or not ("slots" in p):
		return -1
	if p.has_method("selected_head"):
		var h: int = p.selected_head()
		if h >= 0 and h < p.slots.size() and String(p.slots[h].kind) == "anesthetic" and int(p.slots[h].count) > 0:
			return h
	for i in p.slots.size():
		if String(p.slots[i].kind) == "anesthetic" and int(p.slots[i].count) > 0:
			return i
	return -1


# =============================================================================== the end

## Host, from game.finish_case: the monster case is over. Won: the brain is handed over by the table
## and the monster dies on it. Lost: the brain is ruined. Its own wording, no paycheck sting.
func on_case_finished(c: Dictionary, won: bool) -> void:
	var id := int(c.get("id", -1))
	var table := int(c.get("table", -1))
	var at: Vector3 = game.table_position(table)
	var pname := String(Procedures.patient(String(c.patient_id)).get("name", "The monster"))
	_remove_at[id] = float(game.world_time) + REMOVE_AFTER
	if String(c.get("ailment_id", "")) == "eye_extraction":
		_finish_eye(c, won, table, at, pname)
		return
	if not won:
		game._sound("flatline", at)
		game.say("The brain is ruined. %s died on the table." % pname, 5.0)
		return
	var cond := minf(float(c.get("vitals", 100.0)), float(_cond.get(id, float(c.get("vitals", 100.0)))))
	c["vitals"] = cond
	var quality := clampf(cond / 100.0, 0.0, 1.0)
	var pos := _brain_spot(table)
	var node = spawn_brain(String(c.patient_id), quality, pos)
	last_brain = {"kind": brain_kind(String(c.patient_id)), "quality": quality, "pos": pos, "node": node}
	game.mark_db(String(c.patient_id), "harvested")   # SWEEP 4A HOOK (database terminal, chunk 4): tier 3, for the whole team
	_fx_flatline(table)
	game._broadcast("dx_flatline", {"tb": table})
	game._sound("flatline", at)
	game.say("Brain out, condition %d%%. %s is dead. Get the brain to the dumpster before it spoils." % [roundi(cond), pname], 5.0)


## Host, GRAFTING part one: an Eyeball Extraction case is over. Won: the Hive's eye comes out in the
## operator's hand (else lies by the head) and the Hive dies on the table like a dissection. Lost: the
## eye burst.
func _finish_eye(c: Dictionary, won: bool, table: int, at: Vector3, pname: String) -> void:
	var id := int(c.get("id", -1))
	if not won:
		game._sound("flatline", at)
		game.say("The eye burst. %s died on the table." % pname, 5.0)
		return
	var cond := minf(float(c.get("vitals", 100.0)), float(_cond.get(id, float(c.get("vitals", 100.0)))))
	c["vitals"] = cond
	var quality := clampf(cond / 100.0, 0.0, 1.0)
	var value := maxi(1, roundi(float(_base_value("eye_hive")) * quality))
	var who = game.players.get(last_operator) if last_operator != 0 else null
	var node: Node = null
	var given := false
	if who != null and is_instance_valid(who) and who.alive:
		var i: int = who.take_into("eye_hive", 1, value)
		if i >= 0:
			who.selected = i
			who.slots[i]["bt"] = float(game.world_time)
			given = true
	if not given:
		var pos := _brain_spot(table)
		node = game._spawn_item("eye_hive", 1, Transform3D(Basis(Vector3.UP, randf() * TAU), pos), WorldItem.State.LOOSE)
		node.value = value
		node.bt = float(game.world_time)
	last_eye = {"kind": "eye_hive", "quality": quality, "node": node, "peer": last_operator}
	_fx_flatline(table)
	game._broadcast("dx_flatline", {"tb": table})
	game._sound("flatline", at)
	game.say("Eye out, condition %d%%. %s is dead. Put it in a vat before it spoils." % [roundi(cond), pname], 5.0)


func _base_value(kind: String) -> int:
	return int(LootTable.LOOT.get(kind, {}).get("value", [0, 0])[0])


## Host: hands a brain over at pos through the brains system, or a plain loot item.
func spawn_brain(patient_id: String, quality: float, pos: Vector3) -> Node:
	var kind := brain_kind(patient_id)
	var br = game.get("brains")
	if br != null and br.has_method("spawn_brain"):
		return br.spawn_brain(kind, quality, pos)
	var loot_kind := kind if not Items.def(kind).is_empty() else FALLBACK_KIND
	var it = game._spawn_item(loot_kind, 1, Transform3D(Basis(), pos), WorldItem.State.LOOSE)
	if it != null:
		it.value = maxi(1, roundi(float(FALLBACK_VALUE.get(patient_id, 150)) * quality))
	return it


## Where the brain lands: the specimen tray beside the head (the brain step's tray), a little above.
func _brain_spot(table: int) -> Vector3:
	var body = game.body_for_table(table)
	if body != null and body.has_method("site_section") and body.has_method("site_transform"):
		var sec: Dictionary = body.site_section("brain")
		if sec.has("tray"):
			return body.site_transform("brain") * (sec.tray as Vector3) + Vector3.UP * 0.12
	return game.table_position(table) + Vector3.UP * 1.15


# =============================================================================== dev and tests

## Host: strap a monster to a patient table for testing (the dev panel, tools/dissectiontest).
## Uses the first free table, else clears the first table. Returns the case id or -1.
func dev_strap(kind: String, sed := 1.0, table := -1) -> int:
	if game == null or not game.is_host() or not Procedures.is_monster(kind):
		return -1
	if table < 0:
		table = game.free_patient_table()
	if table < 0 and not game.patient_tables.is_empty():
		table = int(game.patient_tables[0].index)
	if table < 0:
		return -1
	var there: Dictionary = game.case_on_table(table)
	if not there.is_empty():
		game.remove_case(int(there.id))
	var id: int = game.add_case({"table": table, "patient_id": kind, "ailment_id": "dissection", "monster": true,
		"flags": {"sedation": clampf(sed, 0.0, 1.0)}, "state": "on_table"})
	if id >= 0:
		_sed[id] = clampf(sed, 0.0, 1.0)
		game.say("Strapped %s to table %d." % [Procedures.patient(kind).get("name", kind), table + 1], 3.0)
	return id


## Host, tests: set a monster case's sedation directly.
func set_sedation(case_id: int, s: float) -> void:
	var c: Dictionary = game.case_by_id(case_id)
	if c.is_empty():
		return
	_sed[case_id] = clampf(s, 0.0, 1.0)
	(c.flags as Dictionary)["sedation"] = snappedf(clampf(s, 0.0, 1.0), FLAG_STEP)


func _audio(cue: String, at, vol := 0.0) -> void:
	var a = get_node_or_null("/root/Audio")
	if a != null:
		a.play(cue, at, vol, 0.06)
