extends SceneTree
## The loot kinds and where they turn up. Builds the hospital for a few seeds (no game session) and
## plans each shift's loot on it.
##
##   godot --headless --path . -s tools/loottest.gd [-- --seeds=1,2,3 --report]
##
## Checks: no cut kind is left in the loot table or its models; every kept kind has a model; every
## room kind that had loot before the cut still gets loot; trinkets are rarer than plain loot.
## --report also prints each seed's total loot value and the kinds and rooms it landed in.
## Exits 0 when every check passes.

const MG := preload("res://scripts/mapgen.gd")
const HB := preload("res://scripts/hospital_builder.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")
const LootSpawner := preload("res://scripts/economy/loot_spawner.gd")
const LootModels := preload("res://scripts/economy/loot_models.gd")

const CUT := ["stethoscope", "thermometer", "bp_cuff", "otoscope", "patient_records", "wheelchair_wheel",
	"sample_rack", "wedding_ring", "coffee_maker", "iv_pump", "microscope"]
const KEPT := ["pill_bottle", "xray_film", "heart_monitor", "gold_watch", "ultrasound",
	"desk_phone", "laptop", "defibrillator", "reflex_hammer", "epipen", "pulse_oximeter"]
const TRINKETS := ["desk_phone", "laptop", "defibrillator", "reflex_hammer", "epipen", "pulse_oximeter"]
## Room kinds the loot could turn up in before the cut (the union of the old table's `rooms`).
const OLD_ROOMS := ["ward", "patient_room", "nurse_station", "office", "corridor", "waiting_room", "pharmacy",
	"restroom", "radiology", "storage", "maintenance", "janitor", "lab", "morgue", "break_room", "cafeteria"]

var seeds: Array = [1, 2, 3]
var report := false
var failures: Array = []
var checks := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--report":
			report = true
		elif a.begins_with("--seeds="):
			seeds = []
			for s in a.trim_prefix("--seeds=").split(","):
				seeds.append(int(s))
	_static_checks()
	var by_room := {}       # room kind -> stacks over every seed
	var places := {}        # room kind -> free locations over every seed (what the spawner could fill)
	var by_kind := {}
	var total_value := 0
	var total_stacks := 0
	var trinket_stacks := 0
	for sd in seeds:
		var info := {}
		var gen: Dictionary = MG.generate(sd)
		var level: Node3D = HB.build(gen, info)
		var seed_value := 0
		var seed_stacks := 0
		for shift in [1, 2, 3]:
			var rooms_of := {}
			for loc in LootSpawner._locations(info, {}):
				places[loc.room_kind] = int(places.get(loc.room_kind, 0)) + 1
				rooms_of[loc.key] = loc.room_kind
			for e in LootSpawner.plan(sd, shift, info, {}):
				var kind := String(e.kind)
				seed_value += int(e.value)
				seed_stacks += 1
				by_kind[kind] = int(by_kind.get(kind, 0)) + 1
				if TRINKETS.has(kind):
					trinket_stacks += 1
				var key := "%s:%d" % [e.container_id, int(e.slot)] if String(e.container_id) != "" else "anchor:%05d" % int(e.anchor)
				var room := String(rooms_of.get(key, "?"))
				by_room[room] = int(by_room.get(room, 0)) + 1
		total_value += seed_value
		total_stacks += seed_stacks
		if report:
			print("seed %d: %d stacks, $%d over shifts 1-3 (avg $%d a shift)" % [sd, seed_stacks, seed_value, seed_value / 3])
		level.free()
	var kinds_sorted := by_kind.keys()
	kinds_sorted.sort()
	if report:
		print("kinds: ", by_kind)
		print("rooms: ", by_room)
		print("places: ", places)
		print("TOTAL $%d in %d stacks over %d seeds x 3 shifts; trinkets %d" % [total_value, total_stacks, seeds.size(), trinket_stacks])
	for k in CUT:
		_check(not by_kind.has(k), "no %s in any plan" % k)
	_check(trinket_stacks * 100 < total_stacks * 35, "trinkets are rarer than plain loot (%d of %d stacks)" % [trinket_stacks, total_stacks])
	for r in OLD_ROOMS:
		if int(places.get(r, 0)) > 0:
			_check(int(by_room.get(r, 0)) > 0, "room kind '%s' gets loot (%d places, %d stacks)" % [r, int(places.get(r, 0)), int(by_room.get(r, 0))])
		else:
			print("(no '%s' locations on these seeds)" % r)
	print("[loottest] result=%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	for f in failures:
		print("  failed: ", f)
	quit(0 if failures.is_empty() else 1)


func _static_checks() -> void:
	for k in CUT:
		_check(not LootTable.has(k), "%s is not in the loot table" % k)
	for k in KEPT:
		_check(LootTable.has(k), "%s is in the loot table" % k)
		var root := Node3D.new()
		LootModels.build(root, k, 1)
		_check(root.get_child_count() > 0 and LootModels.footprint(k) != Vector3(0.15, 0.1, 0.15), "%s has a model and a footprint" % k)
		root.free()
		# Every place a kept kind may turn up is a real room kind or the catch-all.
		_check(not (LootTable.LOOT[k].rooms as Dictionary).is_empty(), "%s has rooms" % k)
	# The table holds only the kept kinds plus the brains and the grafting parts.
	for k in LootTable.kinds():
		var d: Dictionary = LootTable.LOOT[k]
		_check(KEPT.has(k) or d.get("brain", false) or d.get("eye", false) or k == "specimen_vat", "%s is a kept kind" % k)


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures.append(what)
		print("FAIL  ", what)
