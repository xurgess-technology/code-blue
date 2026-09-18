class_name AimHighlight
extends RefCounted
## Interactable-affordance sweep: what the local player is aiming at, if they can use it, catches
## the light a little: it brightens slightly (a faint warm lift, a touch more at its edges) and
## fades in over a tenth of a second. Together with the crosshair ring (hud.gd) and the prompt
## under it, that says "you can use this" without the glowing silhouette this used to draw (Zach:
## the outline was far too harsh). Purely local and cosmetic: each player highlights only what
## THEY aim at (`Player.aim_id` / `_update_aim_highlight`), no network traffic, no change to
## interaction logic.
##
## Technique: a copy of each of the target's biggest MeshInstance3Ds, added as a CHILD of it (so it
## inherits its transform for free), a hair proud of its surface and drawn front faces only with an
## additive, unlit material. One material per highlight (only ever one per local player), faded in
## with a tween. Warmed once in scripts/warmup.gd.

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform vec3 tint : source_color = vec3(1.0, 0.93, 0.78);
uniform float amount = 0.0;

void vertex() {
	VERTEX += NORMAL * 0.002;
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float edge = pow(1.0 - facing, 3.0);
	ALBEDO = tint * (0.055 + 0.09 * edge) * amount;
}
"""
## Seconds for the brightening to fade in.
const FADE_IN := 0.1


## Same spirit as ItemModels.TINT_MAX_MESHES: brighten the big readable shapes of a target, not
## every screw and bolt (each one is another draw).
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
	var mat: ShaderMaterial = _material().duplicate()
	if node.is_inside_tree():
		var tw := node.create_tween()
		tw.tween_method(func(v: float) -> void: mat.set_shader_parameter("amount", v), 0.0, 1.0, FADE_IN)
	else:
		mat.set_shader_parameter("amount", 1.0)
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
