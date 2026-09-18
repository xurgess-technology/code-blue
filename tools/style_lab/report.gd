extends SceneTree
## Import check for the stylized characters (art/stylized): loads each surgeon_st*.glb in
## assets/models/characters/human and prints what the game's human contract cares about.
##   godot --headless --path . --script tools/style_lab/report.gd

const DIR := "res://assets/models/characters/human"


func _init() -> void:
	var da := DirAccess.open(DIR)
	if da == null:
		print("[style_lab] no models folder")
		quit(1)
		return
	for f in da.get_files():
		if f.begins_with("surgeon_st") and f.ends_with(".glb"):
			_report(DIR + "/" + f)
	quit(0)


func _report(path: String) -> void:
	var ps := load(path) as PackedScene
	if ps == null:
		print("[style_lab] FAIL could not load ", path)
		return
	var root := ps.instantiate()
	print("[style_lab] ", path)
	var tris := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var t := 0
		var mats := []
		for i in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(i)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			t += idx.size() / 3
			var mat := m.mesh.surface_get_material(i)
			mats.append("%s(%s)" % [mat.resource_name if mat else "none", "tex" if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture else "no tex"])
		tris += t
		print("  mesh %-14s %6d tris  skin:%s  %s" % [m.name, t, str(m.skin != null), ", ".join(mats)])
	print("  total tris ", tris)
	var sk := root.find_children("*", "Skeleton3D", true, false)
	print("  skeleton bones ", (sk[0] as Skeleton3D).get_bone_count() if not sk.is_empty() else -1)
	var ap := root.find_children("*", "AnimationPlayer", true, false)
	if not ap.is_empty():
		var names := (ap[0] as AnimationPlayer).get_animation_list()
		print("  clips (%d) %s" % [names.size(), ", ".join(names)])
	for s in root.find_children("Site_*", "", true, false):
		var p := s.get_parent()
		print("  site %s under %s (%s)" % [s.name, p.name, (p as BoneAttachment3D).bone_name if p is BoneAttachment3D else p.get_class()])
	root.free()
