class_name ItemModels
extends RefCounted
## Visuals for item stacks. A registered asset under `item/<kind>` always wins (models sweep 2:
## merged into one shared mesh per kind, see asset_mesh()); everything else is built from
## primitives. Origin sits at the base of the stack, there is no collision, and a stack of N
## looks like N things.


const LootModels := preload("res://scripts/economy/loot_models.gd")
const LootTable := preload("res://scripts/economy/loot_table.gd")
const ItemsDB := preload("res://scripts/items.gd")

## Colour coding (inventory worker, sweep 2): surgical supplies get a teal rim, sellable loot a
## gold one, so it is obvious in the dark what the surgery needs. One cached overlay shader,
## two cached materials, applied as `material_overlay` so shared or imported materials are
## never modified.
const TINT_TEAL := Color(0.25, 0.95, 0.85)
const TINT_GOLD := Color(1.0, 0.72, 0.22)
const TINT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform vec3 tint : source_color = vec3(1.0, 0.72, 0.22);
uniform float rim = 0.9;
uniform float base = 0.035;

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float edge = pow(1.0 - facing, 4.5);
	float breathe = 0.92 + 0.08 * sin(TIME * 1.6);
	ALBEDO = tint * (edge * rim * breathe + base);
}
"""

static var _tint_shader: Shader = null
static var _tint_mats := {}


static func make(kind: String, count: int = 1) -> Node3D:
	var mesh := asset_mesh(kind)
	if mesh != null:
		return _from_template(kind, mesh, count)
	var root := Node3D.new()
	root.name = "Model_%s" % kind
	match kind:
		"anesthetic": _vials(root, clampi(count, 1, 6))
		"gauze": _gauze(root, clampi(count, 1, 6))
		"forceps": _forceps(root)
		"tourniquet": _tourniquet(root)
		"bone_saw": _bone_saw(root)
		"suture_kit": _suture_kits(root, clampi(count, 1, 4))
		"placebo_pills": _placebo_bottle(root)   # SWEEP 4A HOOK (pharmacy, chunk 3)
		_:
			if LootTable.has(kind):
				LootModels.build(root, kind, count)
			else:
				_add(root, _box(Vector3(0.15, 0.1, 0.15), Color.MAGENTA), Vector3(0, 0.05, 0))
	return root


## make() plus the teal (surgical) or gold (loot) rim. Use this for items in the world, in hands
## and on the shelf; minigames keep the plain make() for their close-up tools.
static func make_tinted(kind: String, count: int = 1, soft := false) -> Node3D:
	var n := make(kind, count)
	apply_tint(n, kind, soft)
	return n


## The overlay material for a kind: teal for surgical supplies, gold for loot, null otherwise.
## `soft` is a fainter rim for stacks held in first person, which fill a big part of the view.
static func tint_material(kind: String, soft := false) -> Material:
	var key := ""
	if ItemsDB.is_surgical(kind):
		key = "teal"
	elif ItemsDB.is_loot(kind):
		key = "gold"
	if key == "":
		return null
	var cache_key := key + ("_soft" if soft else "")
	if _tint_mats.has(cache_key):
		return _tint_mats[cache_key]
	if _tint_shader == null:
		_tint_shader = Shader.new()
		_tint_shader.code = TINT_SHADER
	var m := ShaderMaterial.new()
	m.shader = _tint_shader
	var col: Color = TINT_TEAL if key == "teal" else TINT_GOLD
	m.set_shader_parameter("tint", Vector3(col.r, col.g, col.b))
	# Gold loot is often dark metal and plastic; teal supplies are mostly bright: even them out.
	var soft_k := 0.4 if soft else 1.0
	# Toned down (Zach: too harsh): a soft edge you notice in the dark, not a glowing outline.
	m.set_shader_parameter("rim", (0.32 if key == "teal" else 0.38) * soft_k)
	m.set_shader_parameter("base", (0.012 if key == "teal" else 0.015) * soft_k)
	_tint_mats[cache_key] = m
	return m


## Put the kind's rim on every mesh under `node` (no-op for kinds without one).
## Every overlay is one more draw of that mesh, so only the TINT_MAX_MESHES biggest parts of a
## model get it: the outline reads from the big shapes, the screws and labels do not matter.
const TINT_MAX_MESHES := 5


static func apply_tint(node: Node, kind: String, soft := false) -> void:
	var mat := tint_material(kind, soft)
	if mat == null or node == null:
		return
	var parts: Array = []
	if node is MeshInstance3D:
		parts.append(node)
	parts.append_array(node.find_children("*", "MeshInstance3D", true, false))
	var sized: Array = []
	for p in parts:
		var mi := p as MeshInstance3D
		if mi.mesh == null:
			continue
		var s := mi.mesh.get_aabb().size * mi.scale
		sized.append([s.x * s.y + s.y * s.z + s.x * s.z, sized.size(), mi])
	sized.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	for i in mini(TINT_MAX_MESHES, sized.size()):
		(sized[i][2] as MeshInstance3D).material_overlay = mat


## Rough footprint so containers and shelves can space stacks out.
static func footprint(kind: String) -> Vector3:
	# models sweep 2: a real model's measured size (stacks keep the table's footprint for the pile).
	if not ItemsDB.def(kind).get("stack", false):
		var mesh := asset_mesh(kind)
		if mesh != null:
			return (asset_transform(kind) * mesh.get_aabb()).size
	match kind:
		"anesthetic": return Vector3(0.14, 0.09, 0.08)
		"gauze": return Vector3(0.22, 0.1, 0.12)
		"forceps": return Vector3(0.2, 0.03, 0.08)
		"tourniquet": return Vector3(0.28, 0.05, 0.1)
		"bone_saw": return Vector3(0.52, 0.05, 0.16)
		"suture_kit": return Vector3(0.16, 0.05, 0.11)
		"placebo_pills": return Vector3(0.045, 0.07, 0.045)
	if LootTable.has(kind):
		return LootModels.footprint(kind)
	return Vector3(0.15, 0.1, 0.15)


## HANDS HOOK: where a kind sits in a hand (the palm position plus the model's forward and up):
## {pos, fwd, up, style "palm"|"fist", hands 1|2, bundle}. The table lives in scripts/hands/grips.gd.
static func grip(kind: String) -> Dictionary:
	return (load("res://scripts/hands/grips.gd") as GDScript).grip(kind)


# ---------------------------------------------------------------------------
# models sweep 2: real models from Assets (`item/<kind>`)
#
# The first time a kind is asked for, its model (plus the extra parts LootModels.asset_extras()
# adds: tubes in the rack, the trace on the monitor) is flattened into ONE ArrayMesh with one
# surface per material, the Assets fixup baked in, decimated to a triangle budget and given fresh
# LODs. Every stack of that kind then shares the mesh: one MeshInstance3D, one draw per material,
# one rim overlay. Kinds without a model (or a missing file) keep their primitive.

## Triangle budget per model after decimation (small loot / bulky loot / surgical supplies).
const TRI_BUDGET_SMALL := 2600
const TRI_BUDGET_BULKY := 6000

## Tools only (perfprobe --models): build every item from primitives, as before the models sweep.
static var primitives_only := false
static var _asset_meshes := {}   # kind -> ArrayMesh, or null when the kind has no usable model
static var _asset_xforms := {}   # kind -> Transform3D the shared mesh is drawn with


static func _assets() -> Node:
	var loop := Engine.get_main_loop()
	return (loop as SceneTree).root.get_node_or_null("Assets") if loop is SceneTree else null


## The shared mesh for a kind's real model, or null (no model registered or the file is missing).
static func asset_mesh(kind: String) -> ArrayMesh:
	if primitives_only:
		return null
	if _asset_meshes.has(kind):
		return _asset_meshes[kind]
	var mesh: ArrayMesh = null
	var assets := _assets()
	if assets != null and assets.has("item/" + kind):
		var parts := _model_parts(assets, "item/" + kind, Transform3D())
		var extras: Dictionary = LootModels.asset_extras(kind) if LootTable.has(kind) else {}
		for c in extras.get("copies", []):
			if assets.has(String(c[0])):
				parts.append_array(_model_parts(assets, String(c[0]), c[1]))
		for p in extras.get("parts", []):
			parts.append(p)
		var recolour: Dictionary = extras.get("recolour", {})
		if not recolour.is_empty():
			for p in parts:
				p[3] = _recoloured(p[3], recolour)
		var budget := TRI_BUDGET_BULKY if ItemsDB.is_bulky(kind) else TRI_BUDGET_SMALL
		# Fast path: one imported mesh already under budget (the heavy models are baked that way,
		# see ASSETS.md) is used as it is, keeping its import LODs; only the fixup moves it.
		var single := extras.is_empty() and not parts.is_empty() and parts[0][0] is ArrayMesh and _tris(parts) <= budget
		for p in parts:
			single = single and p[0] == parts[0][0] and p[2] == parts[0][2] and p[3] == (p[0] as Mesh).surface_get_material(int(p[1]))
		if single:
			mesh = parts[0][0]
			_asset_xforms[kind] = parts[0][2]
		else:
			mesh = merge_parts(parts, budget)
			if mesh != null:
				mesh.resource_name = "item_" + kind
	_asset_meshes[kind] = mesh
	return mesh


## The transform the shared mesh of a kind is drawn with (identity for merged meshes).
static func asset_transform(kind: String) -> Transform3D:
	return _asset_xforms.get(kind, Transform3D())


static func _tris(parts: Array) -> int:
	var n := 0
	for p in parts:
		if p[0] is ArrayMesh:
			n += (p[0] as ArrayMesh).surface_get_array_index_len(int(p[1])) / 3
	return n


## [Mesh, surface, Transform3D, Material] for every surface of a model key, in the frame of its
## Assets fixup then `xf`.
static func _model_parts(assets: Node, key: String, xf: Transform3D) -> Array:
	var out: Array = []
	var scene: PackedScene = assets.model(key)
	if scene == null:
		return out
	var fix: Transform3D = xf * assets.fixup(key)
	var hide: Array = assets.info(key).get("hide", [])
	var inst := scene.instantiate()
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or hide.has(String(mi.name)):
			continue
		var t := Transform3D()
		var p: Node = mi
		while p != null and p != inst:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		for s in mi.mesh.get_surface_count():
			var mat: Material = mi.material_override
			if mat == null:
				mat = mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			out.append([mi.mesh, s, fix * t, mat])
	inst.free()
	return out


static var _recolour_cache := {}


static func _recoloured(mat: Material, recolour: Dictionary) -> Material:
	if not (mat is BaseMaterial3D):
		return mat
	var col = recolour.get(String(mat.resource_name), recolour.get("*", null))
	if col == null:
		return mat
	var key := "%d|%s" % [mat.get_instance_id(), str(col)]
	if not _recolour_cache.has(key):
		var m := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
		m.albedo_color = col
		_recolour_cache[key] = m
	return _recolour_cache[key]


## Merge [Mesh, surface, xf, material] parts into one ArrayMesh, one surface per material,
## decimated to `budget` triangles in total, with LODs. Null when there is nothing to merge.
static func merge_parts(parts: Array, budget: int) -> ArrayMesh:
	var groups := {}    # material instance id -> {mat, arrays list}
	var order: Array = []
	var total := 0
	for p in parts:
		var mesh: Mesh = p[0]
		var s: int = p[1]
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var mat: Material = p[3]
		var gid := mat.get_instance_id() if mat != null else 0
		if not groups.has(gid):
			groups[gid] = {"mat": mat, "list": []}
			order.append(gid)
		var arr := mesh.surface_get_arrays(s)
		groups[gid].list.append([arr, p[2]])
		var idx = arr[Mesh.ARRAY_INDEX]
		total += (idx.size() if idx != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	if order.is_empty():
		return null
	var keep := clampf(float(budget) / maxf(1.0, float(total)), 0.0, 1.0)
	var im := ImporterMesh.new()
	for gid in order:
		var arrays := _combine(groups[gid].list)
		var tris := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if keep < 0.95 and tris > 200:
			arrays[Mesh.ARRAY_INDEX] = _decimated(arrays, int(tris * keep))
		if (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() * 0.6:
			arrays = _compact(arrays)
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, groups[gid].mat)
	im.generate_lods(25.0, 60.0, [])
	return im.get_mesh()


## One surface's worth of arrays from several [arrays, xf], transformed, with tangents when the
## parts had UVs and normals.
static func _combine(list: Array) -> Array:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var has_uv := true
	var has_col := false
	for e in list:
		var a: Array = e[0]
		if a[Mesh.ARRAY_TEX_UV] == null:
			has_uv = false
		if a[Mesh.ARRAY_COLOR] != null:
			has_col = true
	for e in list:
		var a: Array = e[0]
		var xf: Transform3D = e[1]
		var nb := xf.basis.inverse().transposed()
		var base := verts.size()
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n = a[Mesh.ARRAY_NORMAL]
		for i in v.size():
			verts.append(xf * v[i])
			norms.append((nb * (n[i] if n != null else Vector3.UP)).normalized())
		if has_uv:
			uvs.append_array(a[Mesh.ARRAY_TEX_UV])
		if has_col:
			if a[Mesh.ARRAY_COLOR] != null:
				cols.append_array(a[Mesh.ARRAY_COLOR])
			else:
				for i in v.size():
					cols.append(Color.WHITE)
		var ia = a[Mesh.ARRAY_INDEX]
		if ia != null:
			for i in (ia as PackedInt32Array):
				idx.append(base + i)
		else:
			for i in v.size():
				idx.append(base + i)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	out[Mesh.ARRAY_INDEX] = idx
	if has_uv:
		out[Mesh.ARRAY_TEX_UV] = uvs
	if has_col:
		out[Mesh.ARRAY_COLOR] = cols
	if has_uv:
		var st := SurfaceTool.new()
		st.create_from_arrays(out)
		st.generate_tangents()
		out = st.commit_to_arrays()
	return out


## Drop the vertices a decimated index list no longer uses.
static func _compact(arrays: Array) -> Array:
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var remap := PackedInt32Array()
	remap.resize(count)
	remap.fill(-1)
	var order := PackedInt32Array()
	for i in idx.size():
		var v := idx[i]
		if remap[v] < 0:
			remap[v] = order.size()
			order.append(v)
		idx[i] = remap[v]
	var out := arrays.duplicate()
	out[Mesh.ARRAY_INDEX] = idx
	for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_COLOR]:
		var src = arrays[slot]
		if src == null:
			continue
		var dst = src.duplicate()
		dst.resize(order.size())
		for j in order.size():
			dst[j] = src[order[j]]
		out[slot] = dst
	var tan = arrays[Mesh.ARRAY_TANGENT]
	if tan != null:
		var t := PackedFloat32Array()
		t.resize(order.size() * 4)
		for j in order.size():
			for c in 4:
				t[j * 4 + c] = tan[order[j] * 4 + c]
		out[Mesh.ARRAY_TANGENT] = t
	return out


## The meshoptimizer LOD level closest to (and not under) `target` triangles, as base indices.
static func _decimated(arrays: Array, target: int) -> PackedInt32Array:
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	im.generate_lods(25.0, 60.0, [])
	var best: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var best_err := absf(float(best.size() / 3 - target))
	for l in im.get_surface_lod_count(0):
		var li := im.get_surface_lod_indices(0, l)
		var tris := li.size() / 3
		if tris < target * 0.6:
			continue
		var err := absf(float(tris - target))
		if err < best_err:
			best = li
			best_err = err
	return best


## A stack of a real model: one shared mesh per copy, laid out like the primitive stacks.
static func _from_template(kind: String, mesh: ArrayMesh, count: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Model_%s" % kind
	var n := 1
	if ItemsDB.def(kind).get("stack", false) or ItemsDB.is_consumable(kind):
		n = clampi(count, 1, 6)
	var xf := asset_transform(kind)
	var size := (xf * mesh.get_aabb()).size
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var x := (i % 3 - (mini(n, 3) - 1) * 0.5) * size.x * 1.25
		var z := 0.0 if i < 3 else size.z * 1.2
		var spin := Basis(Vector3.UP, i * 0.72) if n > 1 else Basis()
		mi.transform = Transform3D(spin, Vector3(x, 0.0, z)) * xf
		root.add_child(mi)
	return root


static func _mat(col: Color, rough := 0.6, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _glass(col: Color) -> StandardMaterial3D:
	var m := _mat(col, 0.08, 0.0)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.55
	m.rim_enabled = true
	m.rim = 0.5
	return m


static func _box(size: Vector3, col: Color, rough := 0.6, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = _mat(col, rough, metal)
	return mi


static func _cyl(r: float, h: float, mat: Material, sides := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	mi.mesh = c
	mi.material_override = mat
	return mi


static func _add(root: Node3D, n: Node3D, pos: Vector3, rot_deg := Vector3.ZERO) -> Node3D:
	n.position = pos
	n.rotation_degrees = rot_deg
	root.add_child(n)
	return n


static func _vials(root: Node3D, n: int) -> void:
	var glass := _glass(Color(0.75, 0.88, 0.95))
	var liquid := _mat(Color(0.95, 0.85, 0.35), 0.2)
	liquid.emission_enabled = true
	liquid.emission = Color(0.6, 0.5, 0.15)
	liquid.emission_energy_multiplier = 0.25
	var cap := _mat(Color(0.7, 0.15, 0.12), 0.5)
	var label := _mat(Color(0.93, 0.93, 0.9), 0.9)
	for i in n:
		var x := (i % 3 - 1) * 0.036 + (0.018 if i >= 3 else 0.0)
		var z := (0.0 if i < 3 else 0.034)
		var v := Node3D.new()
		_add(v, _cyl(0.014, 0.05, glass), Vector3(0, 0.025, 0))
		_add(v, _cyl(0.011, 0.034, liquid), Vector3(0, 0.019, 0))
		_add(v, _cyl(0.0145, 0.016, label), Vector3(0, 0.03, 0))
		_add(v, _cyl(0.009, 0.012, cap), Vector3(0, 0.056, 0))
		_add(root, v, Vector3(x, 0, z), Vector3(0, i * 37.0, 0))


static func _gauze(root: Node3D, n: int) -> void:
	var cloth := _mat(Color(0.95, 0.95, 0.92), 1.0)
	var wrap := _mat(Color(0.35, 0.55, 0.75), 0.8)
	for i in n:
		var roll := Node3D.new()
		_add(roll, _cyl(0.032, 0.07, cloth, 14), Vector3.ZERO, Vector3(0, 0, 90))
		_add(roll, _cyl(0.033, 0.012, wrap, 14), Vector3.ZERO, Vector3(0, 0, 90))
		var row := i % 3
		var layer := i / 3
		_add(root, roll, Vector3((row - 1) * 0.075, 0.032 + layer * 0.06, layer * 0.01), Vector3(0, (i * 13) % 20 - 10, 0))


static func _forceps(root: Node3D) -> void:
	var steel := _mat(Color(0.86, 0.89, 0.92), 0.3, 0.45)
	var pouch := _mat(Color(0.85, 0.9, 0.95), 0.4)
	pouch.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pouch.albedo_color.a = 0.35
	_add(root, _box(Vector3(0.24, 0.012, 0.07), Color.WHITE), Vector3(0, 0.006, 0)).material_override = pouch
	for side in [-1.0, 1.0]:
		var arm := _box(Vector3(0.19, 0.006, 0.008), Color.WHITE)
		arm.material_override = steel
		_add(root, arm, Vector3(0.0, 0.016, side * 0.008), Vector3(0, side * 4.0, 0))
	var joint := _cyl(0.008, 0.012, steel)
	_add(root, joint, Vector3(-0.08, 0.016, 0))


static func _tourniquet(root: Node3D) -> void:
	var strap := _mat(Color(0.12, 0.12, 0.13), 0.9)
	var buckle := _mat(Color(0.75, 0.1, 0.08), 0.5)
	var rod := _mat(Color(0.3, 0.3, 0.33), 0.45, 0.3)
	# A coiled strap, the red windlass clip and the rod
	for i in 3:
		var loop := MeshInstance3D.new()
		var t := TorusMesh.new()
		t.inner_radius = 0.045 - i * 0.009
		t.outer_radius = 0.06 - i * 0.009
		t.rings = 16
		t.ring_segments = 6
		loop.mesh = t
		loop.material_override = strap
		_add(root, loop, Vector3(0, 0.012 + i * 0.01, 0))
	_add(root, _box(Vector3(0.05, 0.02, 0.035), Color.WHITE), Vector3(0.07, 0.02, 0)).material_override = buckle
	var r := _cyl(0.006, 0.12, rod)
	_add(root, r, Vector3(0.0, 0.045, 0.0), Vector3(0, 0, 90))


static func _bone_saw(root: Node3D) -> void:
	var steel := _mat(Color(0.84, 0.86, 0.89), 0.32, 0.45)
	var grip := _mat(Color(0.18, 0.12, 0.08), 0.7)
	var blade := _box(Vector3(0.38, 0.004, 0.07), Color.WHITE)
	blade.material_override = steel
	_add(root, blade, Vector3(0.07, 0.012, 0.0))
	# Teeth along one edge: small wedges in a single shared mesh.
	var prism := PrismMesh.new()
	prism.size = Vector3(0.012, 0.004, 0.012)
	for i in 22:
		var tooth := MeshInstance3D.new()
		tooth.mesh = prism
		tooth.material_override = steel
		_add(root, tooth, Vector3(-0.09 + i * 0.015, 0.012, 0.041), Vector3(90, 0, 0))
	var handle := _box(Vector3(0.13, 0.03, 0.05), Color.WHITE)
	handle.material_override = grip
	_add(root, handle, Vector3(-0.17, 0.016, 0))
	var hole := _cyl(0.012, 0.032, _mat(Color(0.05, 0.05, 0.05)))
	_add(root, hole, Vector3(-0.17, 0.016, 0))


## downed (sweep 2 wave 3): sterile suture packs, a stack of flat peel pouches. Each shows the curved
## needle and a coil of dark thread through its clear window.
static func _suture_kits(root: Node3D, n: int) -> void:
	var paper := _mat(Color(0.93, 0.94, 0.95), 0.85)
	var band := _mat(Color(0.2, 0.45, 0.75), 0.6)
	var window := _mat(Color(0.8, 0.88, 0.92), 0.2)
	var steel := _mat(Color(0.82, 0.85, 0.88), 0.3, 0.5)
	var thread := _mat(Color(0.12, 0.1, 0.18), 0.7)
	for i in n:
		var pack := Node3D.new()
		var y := 0.006 + i * 0.013
		_add(pack, _box(Vector3(0.14, 0.012, 0.095), Color.WHITE), Vector3.ZERO).material_override = paper
		_add(pack, _box(Vector3(0.022, 0.0125, 0.096), Color.WHITE), Vector3(-0.055, 0, 0)).material_override = band
		_add(pack, _box(Vector3(0.075, 0.0128, 0.06), Color.WHITE), Vector3(0.018, 0, 0)).material_override = window
		if i == n - 1:
			var needle := MeshInstance3D.new()
			var t := TorusMesh.new()
			t.inner_radius = 0.016
			t.outer_radius = 0.0185
			t.rings = 12
			t.ring_segments = 4
			needle.mesh = t
			needle.material_override = steel
			_add(pack, needle, Vector3(0.012, 0.0075, 0.004)).scale = Vector3(1, 0.3, 1)
			var coil := MeshInstance3D.new()
			var ct := TorusMesh.new()
			ct.inner_radius = 0.008
			ct.outer_radius = 0.011
			ct.rings = 10
			ct.ring_segments = 4
			coil.mesh = ct
			coil.material_override = thread
			_add(pack, coil, Vector3(0.035, 0.0072, -0.012)).scale = Vector3(1, 0.25, 1)
		_add(root, pack, Vector3(i * 0.004, y, i * 0.003), Vector3(0, (i * 11) % 14 - 7, 0))


## SWEEP 4A HOOK (pharmacy, chunk 3): one small amber bottle, same shape family as the loot
## pill_bottle (loot_models.gd) but its own primitives so it stays independent of the loot table.
static func _placebo_bottle(root: Node3D) -> void:
	var amber := _glass(Color(0.95, 0.5, 0.12))
	var cap := _mat(Color(0.93, 0.93, 0.9), 0.45)
	var label := _mat(Color(0.98, 0.97, 0.94), 0.9)
	var pills := _mat(Color(0.95, 0.92, 0.85), 0.8)
	_add(root, _cyl(0.021, 0.07, amber), Vector3(0, 0.035, 0))
	_add(root, _cyl(0.017, 0.04, pills), Vector3(0, 0.022, 0))
	_add(root, _cyl(0.0215, 0.03, label), Vector3(0, 0.036, 0))
	_add(root, _cyl(0.023, 0.014, cap), Vector3(0, 0.077, 0))
