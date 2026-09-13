extends SceneTree
##
## Asset self-check. Instantiates every key the Assets singleton declares and
## prints the resolved path, the world-space bounding box of the spawned node,
## and the animation list.
##
## Run it headless from the project root:
##
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       --script assets/_selfcheck.gd
##
## Exit code is 0 when every declared key resolved, 1 otherwise. Keys that are
## deliberately absent (no CC0 source exists) are listed under EXPECTED GAPS and
## do not fail the run — they are the keys the game must keep a placeholder for.
##

## Keys the game asks for that we could not source. Documented in ASSETS.md.
const EXPECTED_GAPS := ["patient/elephant", "prop/ivstand"]


func _initialize() -> void:
	var A := _assets()
	if A == null:
		printerr("could not obtain the Assets singleton")
		quit(1)
		return

	var fails: Array = []
	print("\n=== MODELS ===")
	for key in A.model_keys():
		var line := _check_model(A, key)
		if line == "":
			fails.append(key)

	print("\n=== MATERIALS ===")
	for key in A.material_keys():
		if not _check_material(A, key):
			fails.append(key)

	print("\n=== EXPECTED GAPS (game keeps its placeholder) ===")
	for key in EXPECTED_GAPS:
		var ok_null: bool = not A.has(key) and A.spawn(key) == null
		print("  %-20s has()=%s spawn()=null  -> %s"
			% [key, A.has(key), "graceful" if ok_null else "BROKEN"])
		if not ok_null:
			fails.append(key)

	print("\n=== SUMMARY ===")
	print("  declared keys : %d models, %d materials"
		% [A.model_keys().size(), A.material_keys().size()])
	print("  missing files : %s" % [A.missing() if not A.missing().is_empty() else "none"])
	print("  failures      : %s" % [fails if not fails.is_empty() else "none"])
	quit(1 if not fails.is_empty() else 0)


func _assets() -> Node:
	# Prefer the real autoload; fall back to a fresh instance so the check also
	# works if the singleton has not been registered yet.
	if root != null and root.has_node("Assets"):
		return root.get_node("Assets")
	var script := load("res://scripts/assets.gd")
	if script == null:
		return null
	var n: Node = script.new()
	root.add_child(n)
	return n


func _check_model(A: Node, key: String) -> String:
	var e: Dictionary = A.info(key)
	var p: String = e.get("path", "?")
	if not A.has(key):
		print("  %-20s MISSING  %s" % [key, p])
		return ""
	var node: Node3D = A.spawn(key)
	if node == null:
		print("  %-20s SPAWN FAILED  %s" % [key, p])
		return ""

	var box := _aabb(node, Transform3D.IDENTITY)
	var ap: AnimationPlayer = A.anim_player(node)
	var clips: Array = []
	if ap != null:
		clips = Array(ap.get_animation_list())

	print("  %s" % key)
	print("      path     : %s" % p)
	print("      fixups   : scale=%.3f yaw=%.0f offset=(%+.3f, %+.3f, %+.3f)"
		% [e.get("scale", 1.0), e.get("yaw", 0.0), e.get("x", 0.0), e.get("y", 0.0), e.get("z", 0.0)])
	print("      size     : %.2f w x %.2f h x %.2f d  (m)" % [box.size.x, box.size.y, box.size.z])
	print("      bounds   : min(%+.2f, %+.2f, %+.2f)  max(%+.2f, %+.2f, %+.2f)"
		% [box.position.x, box.position.y, box.position.z,
		   box.end.x, box.end.y, box.end.z])
	print("      base-at-0: %s (base y %+.3f m, footprint centre x %+.3f z %+.3f)"
		% ["yes" if absf(box.position.y) < 0.02 else ("floats, by design" if e.get("floats", false) else "NO"),
		   box.position.y, box.position.x + box.size.x * 0.5, box.position.z + box.size.z * 0.5])

	var logical: Array = []
	for l in A.LOGICAL_ANIMS:
		var n: String = A.anim_name(key, l)
		if n != "" and ap != null and ap.has_animation(n):
			logical.append("%s->%s" % [l, n])
	if ap == null:
		print("      anims    : (static, no AnimationPlayer)")
	else:
		print("      anims    : %d clips; logical: %s"
			% [clips.size(), ", ".join(logical) if not logical.is_empty() else "(none mapped)"])
		print("      clips    : %s" % ", ".join(clips))
		for l in ["idle", "walk", "run", "attack"]:
			var n2: String = A.anim_name(key, l)
			if n2 != "" and not ap.has_animation(n2):
				print("      WARNING  : mapped '%s' -> '%s' which the pack does not have" % [l, n2])

	node.queue_free()
	return p


func _check_material(A: Node, key: String) -> bool:
	var e: Dictionary = A.info(key)
	var m: Material = A.material(key)
	if m == null:
		print("  %-20s MISSING  %s" % [key, e.get("dir", "?")])
		return false
	var sm := m as StandardMaterial3D
	print("  %s" % key)
	print("      dir      : %s" % e.get("dir", "?"))
	print("      maps     : %s" % ", ".join(A.material_maps(key)))
	print("      uv1_scale: %.1f   metallic: %.2f" % [sm.uv1_scale.x, sm.metallic])
	return true


## Bounding box of everything under `node`, in `node`'s own space. Walks the
## tree accumulating transforms by hand so it works on a detached scene.
func _aabb(node: Node, xf: Transform3D) -> AABB:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	var out := AABB()
	var seen := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var local: AABB = mi.mesh.get_aabb()
			if local.size != Vector3.ZERO:
				out = here * local
				seen = true
	for c in node.get_children():
		var b := _aabb(c, here)
		if b.size == Vector3.ZERO:
			continue
		out = b if not seen else out.merge(b)
		seen = true
	return out
