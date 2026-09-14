shader_type spatial;
// Reference cloth material for the human models (art pass; the game does not use it yet).
// Same maps as the imported StandardMaterial3D, plus the variation's Cloth mask texture:
//   mask R = player tint zone (scrubs, trousers, cap; blood and heavy dirt excluded)
//   mask G = reflective strips (paramedic uniform): a little retro-reflection towards the viewer
// Scrubs are baked in C.PLAYER_COLORS[0]; `tint` recolours them by luminance, keeping all the dirt.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic;   // glTF metallicRoughness: G
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap;
uniform vec3 tint : source_color = vec3(0.239, 0.561, 0.502);
uniform vec3 baked_tint : source_color = vec3(0.239, 0.561, 0.502);
uniform float reflect_boost = 1.5;

float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	vec3 m = texture(mask_tex, UV).rgb;
	float shade = lum(a) / max(lum(baked_tint), 0.002);
	vec3 recol = tint * shade;
	// keep a little of the original hue variation so grime stays grime
	ALBEDO = mix(a, recol + (a - baked_tint * shade) * 0.35, clamp(m.r, 0.0, 1.0));
	ROUGHNESS = texture(rough_tex, UV).g;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	EMISSION = ALBEDO * m.g * reflect_boost * pow(facing, 6.0) * 0.25;
}
