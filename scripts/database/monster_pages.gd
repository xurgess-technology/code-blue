extends RefCounted
## Static content for the database terminal's Monsters section (docs/SWEEP4A.md "Chunk 4").
## Not derived from game data (there is no shared "monster kind" registry yet), so this is the
## one place that lists every huntable species. Add a new monster kind here when one is added.
##
## Each entry: {kind, name, silhouette (a rough humanoid shape descriptor for the terminal's
## silhouette/X-ray drawing), behaviour, senses, threat, doses, brain_site, ability, growth_site}

const ENTRIES := {
	"walk_in": {
		"name": "The Walk-In",
		"height": 1.75,
		"hunch": 0.12,
		"behaviour": "Wanders the wings until it hears something. Investigates noise, loses interest if nothing follows.",
		"senses": "Hearing only. Footsteps at a walk make no noise it can pick up; running, dropped items and shoves do.",
		"threat": "Low alone. Dangerous in groups or once it has found you and closed the distance.",
		"doses": "About 2 doses of anesthetic to bring it under and keep it there for a full harvest.",
		"brain_site": "Skull, centre, just above eye level.",
		"ability": "Hive Eyes",
		"growth_site": "",
	},
	"discharged": {
		"name": "The Discharged",
		"height": 2.1,
		"hunch": 0.02,
		"behaviour": "Slower, heavier, hunts by scent and sound both. Does not lose interest once it has your trail.",
		"senses": "Hearing and scent. Standing still and stone quiet is the only way to lose it once it is close.",
		"threat": "High. Hits hard, keeps coming. Sedate it before it closes the distance.",
		"doses": "About 3 doses of anesthetic; it fights the sedative longer than a Walk-In.",
		"brain_site": "Skull, set slightly further back than a Walk-In's.",
		"ability": "Echo",
		"growth_site": "",
	},
	"night_nurse": {
		"name": "The Night Nurse",
		"height": 2.3,
		"hunch": 0.0,
		"behaviour": "Only moves while nobody is watching her. Freeze, and she freezes.",
		"senses": "Sight, in a way nothing else in the building has. Being seen is what stops her.",
		"threat": "Unknown. Nobody has gotten close enough, on purpose, to say.",
		"doses": "Unknown. She has never been strapped to a table.",
		"brain_site": "Unknown.",
		"ability": "",
		"growth_site": "unknown",
	},
}

const ORDER := ["walk_in", "discharged", "night_nurse"]


static func entry(kind: String) -> Dictionary:
	return ENTRIES.get(kind, {})
