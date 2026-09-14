extends SceneTree

const MG := preload("res://scripts/mapgen.gd")
const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")


func _initialize() -> void:
	var n := 80
	var fails := 0
	var invalid := 0
	var entr := {}
	var attempts := 0
	for seed in range(1, n + 1):
		Plan.force_kind = "factory"
		var gen: Dictionary = MG.generate(seed)
		attempts += int(gen.attempt)
		if Plan.of(gen).is_empty():
			fails += 1
			print(seed, " ", Plan.last_failure)
		else:
			entr[Plan.of(gen).stubs.size()] = int(entr.get(Plan.of(gen).stubs.size(), 0)) + 1
		var probs := MG.validate(gen)
		if not probs.is_empty():
			invalid += 1
			print(seed, " invalid ", probs.slice(0, 3))
	Plan.force_kind = "none"
	var base_attempts := 0
	for seed in range(1, n + 1):
		base_attempts += int(MG.generate(seed).attempt)
	print("fails %d/%d invalid %d entrances %s attempts %d (no pocket %d)" % [fails, n, invalid, str(entr), attempts, base_attempts])
	quit(0)
