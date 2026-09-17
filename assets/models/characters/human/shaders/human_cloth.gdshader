shader_type spatial;
// Reference cloth material for the human models (art pass; the game does not use it yet).
// Same maps as the imported StandardMaterial3D, plus the variation's Cloth mask texture:
//   mask R = player tint zone (scrubs, trousers, cap; blood and heavy dirt excluded)
//   mask G = reflective strips (paramedic uniform): a little retro-reflection towards the viewer
// Scrubs are baked in C.PLAYER_COLORS[0]; `tint` recolours them by luminance, keeping all the dirt.
// `expose` (patients): the cloth is cut away inside an ellipse round a surgery site, as if pulled back,
// with a shaded fold round the opening. `expose_inv` is world -> site frame (+Y out of the skin),
// `expose_c` / `expose_r` the ellipse's centre and radii on the site plane (site X, Z). Only for a
// removable panel over real skin (Bob's gunshot panel): elsewhere the gown is a shell over nothing.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic;   // glTF metallicRoughness: G
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap;
uniform vec3 tint : source_color = vec3(0.239, 0.561, 0.502);
uniform vec3 baked_tint : source_color = vec3(0.239, 0.561, 0.502);
uniform float reflect_boost = 1.5;
uniform float expose = 0.0;
uniform mat4 expose_inv = mat4(1.0);
uniform vec2 expose_c = vec2(0.0);
uniform vec2 expose_r = vec2(0.1);

varying vec3 wpos;

float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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
	if (expose > 0.5) {
		vec3 l = (expose_inv * vec4(wpos, 1.0)).xyz;
		if (abs(l.y) < 0.3) {
			float r = length((l.xz - expose_c) / expose_r);
			if (r < 1.0) {
				discard;
			}
			ALBEDO *= mix(0.55, 1.0, smoothstep(1.0, 1.12, r));
		}
	}
}
