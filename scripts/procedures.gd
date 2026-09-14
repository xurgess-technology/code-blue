class_name Procedures
extends RefCounted
## Patients, ailments and the steps of each surgery, as data.
##
## Ailments never know what a patient looks like. They refer to named sites
## ("injection", "gunshot", "limb_cut") and each patient body provides a marker
## for every site. Adding a patient means placing those markers on a new model.

const SITES := ["injection", "gunshot", "limb_cut", "limb", "skull", "brain"]

const PATIENTS := {
	"bob": {
		"name": "Bob",
		"full_name": "Bob Kowalski, 52",
		"body": "bob",
		"weight_kg": 82.0,
		"limb_name": "left forearm",
		"limb_radius_m": 0.06,
		"blurbs": {
			"gunshot": "Says he was cleaning it. It was not loaded, apparently.",
			"amputation": "Scraped his arm on a fence in June. Did not get it looked at.",
		},
	},
	"seal": {
		"name": "The seal",
		"full_name": "Harbor seal, adult, unnamed",
		"body": "seal",
		"weight_kg": 130.0,
		"limb_name": "left front flipper",
		"limb_radius_m": 0.08,
		"blurbs": {
			"gunshot": "Found behind the loading dock. Nobody is admitting to anything.",
			"amputation": "Tangled in fishing line for weeks. The flipper has to go.",
		},
	},
	# dissection (sweep 3): strapped monsters. `monster: true` keeps them out of roll(), the dev
	# panel's patient list and anything else that means a human patient (human_patients()). Their
	# bodies are built by scripts/dissection/monster_builder.gd; the only ailment they take is
	# `dissection`.
	"walk_in": {
		"name": "The Walk-In",
		"full_name": "Walk-In, unregistered",
		"body": "walk_in",
		"monster": true,
		"weight_kg": 70.0,
		"limb_name": "",
		"limb_radius_m": 0.05,
		"blurbs": {
			"dissection": "Came in through the front door and never left. Still in the gown.",
		},
	},
	"discharged": {
		"name": "The Discharged",
		"full_name": "Discharged patient, no records",
		"body": "discharged",
		"monster": true,
		"weight_kg": 88.0,
		"limb_name": "",
		"limb_radius_m": 0.05,
		"blurbs": {
			"dissection": "Signed out years ago. The IV line is still taped to its arm.",
		},
	},
}

## Each step names the item it needs, how many it uses up (0 for reusable tools),
## which minigame plays it, and the patient site it happens at.
const AILMENTS := {
	"gunshot": {
		"name": "Gunshot wound",
		"code": "GW",
		"steps": [
			{"id": "sedate", "label": "Sedate the patient", "item": "anesthetic", "uses": 1, "game": "anesthetic", "site": "injection"},
			{"id": "extract", "label": "Remove the bullet", "item": "forceps", "uses": 0, "game": "forceps", "site": "gunshot"},
			{"id": "dress", "label": "Pack and dress the wound", "item": "gauze", "uses": 1, "game": "gauze", "variant": "pack", "site": "gunshot"},
		],
	},
	"amputation": {
		"name": "Amputation",
		"code": "AM",
		"steps": [
			{"id": "sedate", "label": "Sedate the patient", "item": "anesthetic", "uses": 1, "game": "anesthetic", "site": "injection"},
			{"id": "tourniquet", "label": "Apply the tourniquet", "item": "tourniquet", "uses": 0, "game": "tourniquet", "site": "limb"},
			{"id": "cut", "label": "Saw through the limb", "item": "bone_saw", "uses": 0, "game": "saw", "site": "limb_cut"},
			{"id": "dress", "label": "Dress the stump", "item": "gauze", "uses": 2, "game": "gauze", "variant": "stump", "site": "limb_cut"},
		],
	},
	# downed (sweep 2 wave 3): a downed teammate on the OR's player table. `player_only` keeps it
	# out of roll() and off the patient tables; the body is scripts/downed/player_body.gd.
	"stitches": {
		"name": "Laceration",
		"code": "LC",
		"player_only": true,
		"steps": [
			{"id": "stitch", "label": "Stitch the wound closed", "item": "suture_kit", "uses": 1, "game": "stitches", "site": "gash"},
		],
	},
	# dissection (sweep 3): a strapped monster on a patient table. `monster_only` keeps it out of
	# roll() and patient_ailments(). The saw and forceps steps play their "skull" / "brain" variants.
	"dissection": {
		"name": "Dissection",
		"code": "DX",
		"monster_only": true,
		"steps": [
			{"id": "open", "label": "Saw open the skull", "item": "bone_saw", "uses": 0, "game": "saw", "variant": "skull", "site": "skull"},
			{"id": "harvest", "label": "Pull out the brain", "item": "forceps", "uses": 0, "game": "forceps", "variant": "brain", "site": "brain"},
		],
	},
}

## Where each minigame script lives. The surgery system loads these by id.
const MINIGAME_SCRIPTS := {
	"anesthetic": "res://scripts/surgery/games/anesthetic.gd",
	"forceps": "res://scripts/surgery/games/forceps.gd",
	"tourniquet": "res://scripts/surgery/games/tourniquet.gd",
	"saw": "res://scripts/surgery/games/saw.gd",
	"gauze": "res://scripts/surgery/games/gauze.gd",
	"stitches": "res://scripts/surgery/games/stitches.gd",
}


## One patient and one ailment per shift, chosen from the shift seed.
static func roll(seed_value: int, shift: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|case|%d" % [seed_value, shift])
	var patient_ids := human_patients()
	var ailment_ids := patient_ailments()
	return {
		"patient": patient_ids[rng.randi_range(0, patient_ids.size() - 1)],
		"ailment": ailment_ids[rng.randi_range(0, ailment_ids.size() - 1)],
	}


## Ailments a patient case can have, sorted (everything but the player-only ones such as stitches
## and the monster-only dissection).
static func patient_ailments() -> Array:
	var out := []
	for id in AILMENTS.keys():
		if not bool(AILMENTS[id].get("player_only", false)) and not bool(AILMENTS[id].get("monster_only", false)):
			out.append(id)
	out.sort()
	return out


static func is_player_only(ailment_id: String) -> bool:
	return bool(AILMENTS.get(ailment_id, {}).get("player_only", false))


## dissection (sweep 3): the ailment only a strapped monster has.
static func is_monster_only(ailment_id: String) -> bool:
	return bool(AILMENTS.get(ailment_id, {}).get("monster_only", false))


## dissection (sweep 3): a monster patient (walk_in, discharged).
static func is_monster(patient_id: String) -> bool:
	return bool(PATIENTS.get(patient_id, {}).get("monster", false))


## The human patients a phone call can bring, sorted (bob, seal): every patient but the monsters.
static func human_patients() -> Array:
	var out := []
	for id in PATIENTS.keys():
		if not bool(PATIENTS[id].get("monster", false)):
			out.append(id)
	out.sort()
	return out


## The monster patients, sorted.
static func monster_patients() -> Array:
	var out := []
	for id in PATIENTS.keys():
		if bool(PATIENTS[id].get("monster", false)):
			out.append(id)
	out.sort()
	return out


static func patient(id: String) -> Dictionary:
	return PATIENTS.get(id, {})


static func ailment(id: String) -> Dictionary:
	return AILMENTS.get(id, {})


static func steps(ailment_id: String) -> Array:
	return AILMENTS.get(ailment_id, {}).get("steps", [])


static func step(ailment_id: String, index: int) -> Dictionary:
	var s := steps(ailment_id)
	return s[index] if index >= 0 and index < s.size() else {}


static func blurb(patient_id: String, ailment_id: String) -> String:
	return PATIENTS.get(patient_id, {}).get("blurbs", {}).get(ailment_id, "")


## Total of each item the whole procedure needs: consumables by use count, tools as 1.
static func requirements(ailment_id: String) -> Dictionary:
	var need := {}
	for s in steps(ailment_id):
		var amount: int = maxi(1, int(s.uses))
		if Items.is_consumable(s.item):
			need[s.item] = int(need.get(s.item, 0)) + amount
		else:
			need[s.item] = maxi(int(need.get(s.item, 0)), 1)
	return need


## What is still needed from here on, counting from a step index. Used by the softlock guard.
static func remaining_requirements(ailment_id: String, from_step: int) -> Dictionary:
	var need := {}
	var all := steps(ailment_id)
	for i in range(maxi(0, from_step), all.size()):
		var s: Dictionary = all[i]
		if Items.is_consumable(s.item):
			need[s.item] = int(need.get(s.item, 0)) + maxi(1, int(s.uses))
		else:
			need[s.item] = maxi(int(need.get(s.item, 0)), 1)
	return need


## Shared difficulty knob every minigame reads. 1.0 on shift one, harder after.
static func difficulty(shift: int) -> float:
	return 1.0 + 0.12 * maxf(0.0, float(shift - 1))
