extends SceneTree
const MG := preload("res://scripts/mapgen.gd")
const Plan := preload("res://scripts/level/pockets/pocket_plan.gd")
func _initialize() -> void:
	for seed in [4242, 4243, 4244, 4245, 4246, 4247, 4248, 802, 112, 7, 1, 2, 3]:
		var g: Dictionary = MG.generate(seed)
		var p := Plan.of(g)
		print(seed, " ", p.get("kind", "-"), " ", p.get("stubs", []).size())
	quit(0)
