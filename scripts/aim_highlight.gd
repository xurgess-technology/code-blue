class_name AimHighlight
extends RefCounted
## Interactable-affordance sweep: the primary "you can use this" signal is now a thin glowing rim
## on whatever the local player is aiming at (R.E.P.O.'s look, per DESIGN.md), not a permanently
## floating label. Purely local and cosmetic: each player highlights only what THEY personally
## aim at (driven by `Player.aim_id` / `_update_aim_highlight`, itself already local-only), so
## this adds no network traffic and never touches host-authoritative interaction logic.
##
## Technique: a duplicated inverted-hull mesh, added as a CHILD of each of the target's own
## MeshInstance3Ds (so it inherits that instance's transform for free instead of needing its own
## copy of it), pushed out along its own normals in the vertex shader and drawn back-face-only
## (`cull_front`) so only the sliver of "extra" geometry beyond the real silhouette is visible: a
## clean rim around the object. One shared shader/material for every highlighted thing in the
## game; at most a handful of extra draws for whatever is currently aimed at (never more than one
## thing per local player), so it costs nothing worth measuring even with many interactables
## on screen (see tools/perfprobe.gd). Warmed once in scripts/warmup.gd like item_models.gd's
## teal/gold rim (docs/CONTRACTS.md, "Inventory and money").

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_always, shadows_disabled;

uniform vec3 tint : source_color = vec3(1.0, 0.95, 0.6);
uniform float width = 0.016;

void vertex() {
	VERTEX += NORMAL * width;
}

void fragment() {
	float pulse = 0.85 + 0.15 * sin(TIME * 5.0);
	ALBEDO = tint * pulse * 1.4;
}
"""

## Same spirit as ItemModels.TINT_MAX_MESHES: outline the big readable shapes of a target, not
## every screw and bolt (cheaper, and the rim reads better without dozens of tiny outline slivers).
const MAX_MESHES := 6
const _SHELL_NAME := "AimOutlineFx"
const _META_KEY := "_aim_outlined"

static var _shader: Shader = null
static var _mat: ShaderMaterial = null


static func _material() -> ShaderMaterial:
	if _mat == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
		_mat = ShaderMaterial.new()
		_mat.shader = _shader
	return _mat


## Warmup hook (parity with ItemModels.make_tinted / warmup.gd): compiles the shader once, up
## front, against a throwaway mesh instance so the first real highlight in a session never hitches.
static func warm(parent: Node3D) -> void:
	var probe := MeshInstance3D.new()
	probe.name = "AimHighlightWarm"
	probe.mesh = BoxMesh.new()
	parent.add_child(probe)
	set_highlighted(probe, true)


## Turn the highlight on for `node` (a no-op if it already has one) or off. `node` may be any node
## in the tree with `MeshInstance3D` descendants; nothing happens if it has none.
static func set_highlighted(node: Node, on: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not on:
		_clear(node)
		return
	if node.has_meta(_META_KEY):
		return
	node.set_meta(_META_KEY, true)
	var parts: Array = []
	if node is MeshInstance3D:
		parts.append(node)
	parts.append_array(node.find_children("*", "MeshInstance3D", true, false))
	parts.sort_custom(func(a, b): return _aabb_vol(a) > _aabb_vol(b))
	var mat := _material()
	for i in mini(parts.size(), MAX_MESHES):
		var mi: MeshInstance3D = parts[i]
		if mi.mesh == null or mi.has_node(_SHELL_NAME):
			continue
		var shell := MeshInstance3D.new()
		shell.name = _SHELL_NAME
		shell.mesh = mi.mesh
		shell.material_override = mat
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.add_child(shell)


static func _clear(node: Node) -> void:
	if not node.has_meta(_META_KEY):
		return
	node.remove_meta(_META_KEY)
	var parts: Array = []
	if node is MeshInstance3D:
		parts.append(node)
	parts.append_array(node.find_children("*", "MeshInstance3D", true, false))
	for mi in parts:
		if mi.has_node(_SHELL_NAME):
			mi.get_node(_SHELL_NAME).queue_free()


static func _aabb_vol(mi: MeshInstance3D) -> float:
	if mi.mesh == null:
		return 0.0
	var sz := mi.mesh.get_aabb().size
	return sz.x * sz.y * sz.z
