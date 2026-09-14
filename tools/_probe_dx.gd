extends SceneTree
# Throwaway probe (deleted before the final commit).

func _init() -> void:
	var BodyScript = load("res://scripts/patient_body.gd")
	var b = BodyScript.create("walk_in")
	get_root().add_child(b)
	for mi in b.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = mi.mesh
		if m is ArrayMesh:
			var arr: Array = (m as ArrayMesh).surface_get_arrays(0)
			var cols = arr[Mesh.ARRAY_COLOR]
			var mat = mi.material_override
			print(mi.name, " colors=", (cols.size() if cols != null else -1), " first=", (cols[0] if cols != null and cols.size() > 0 else null), " mat=", mat.resource_name if mat else "", " vc=", mat.vertex_color_use_as_albedo if mat is StandardMaterial3D else "?")
	quit()
