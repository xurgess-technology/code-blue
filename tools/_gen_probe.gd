extends SceneTree

const MG := preload("res://scripts/mapgen.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var first := 1
	var count := 3
	var ascii := true
	for a in args:
		if a.begins_with("--first="):
			first = int(a.split("=")[1])
		if a.begins_with("--count="):
			count = int(a.split("=")[1])
		if a == "--quiet":
			ascii = false
	var bad := 0
	var hist := {}
	for seed in range(first, first + count):
		var t0 := Time.get_ticks_msec()
		var g: Dictionary = MG.generate(seed)
		var ms := Time.get_ticks_msec() - t0
		var p := MG.validate(g)
		var kinds := {}
		for r in g.rooms:
			kinds[r.kind] = kinds.get(r.kind, 0) + 1
		print("seed %d: %dx%d attempt %d, %d ms, rooms %d, furniture %d, containers %d, lights %d, problems %d" % [seed, g.width, g.height, g.attempt, ms, g.rooms.size(), g.furniture.size(), g.containers.size(), g.lights.size(), p.size()])
		if not p.is_empty():
			bad += 1
			for i in mini(12, p.size()):
				print("   ", p[i])
				var key := p[i].get_slice(" at ", 0).left(40)
				hist[key] = hist.get(key, 0) + 1
		if ascii:
			for row in g.rows:
				print(row)
	print("bad %d / %d" % [bad, count])
	for k in hist:
		print("  %4d  %s" % [hist[k], k])
	quit(0)
