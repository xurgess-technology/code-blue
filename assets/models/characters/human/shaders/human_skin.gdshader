shader_type spatial;
// Reference skin material for the human models (art pass; the game does not use it yet).
// Variation's Skin mask texture:
//   mask R = anesthetic vein (inner left elbow)  -> `vein_glow` shows it (the minigame's green target)
//   mask G = the players' belly gash             -> `gash` 0 closed skin .. 1 open raw wound (pair with the GashSkin blend shape)
//   mask B = Bob's gunshot entry site             -> `wound` 0..1
// UV2: x = metres along the arm from the shoulder joint (fingers continue past the knuckles),
//      y = +1 right arm (Bob's amputation arm), -1 left arm, 2 legs, 0 elsewhere.
//   `infect` 0..1 greys and rots the right arm from `infect_from` to `infect_full` (metres, see the sites JSON).
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap;
uniform float gash : hint_range(0.0, 1.0) = 0.0;
uniform float wound : hint_range(0.0, 1.0) = 0.0;
uniform float vein_glow : hint_range(0.0, 1.0) = 0.0;
uniform float infect : hint_range(0.0, 1.0) = 0.0;
uniform float infect_from = 0.43;
uniform float infect_full = 0.48;
uniform float pallor : hint_range(0.0, 1.0) = 0.0;

varying vec2 uv2v;

void vertex() {
	uv2v = UV2;
}

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	vec3 m = texture(mask_tex, UV).rgb;
	float rough = texture(rough_tex, UV).g;
	vec3 flesh = vec3(0.16, 0.012, 0.012);
	float g = smoothstep(0.15, 0.7, m.g) * gash;
	float w = smoothstep(0.2, 0.8, m.b) * wound;
	a = mix(a, flesh, max(g, w));
	rough = mix(rough, 0.2, max(g, w));
	// infection: past infect_from on the right arm the skin goes grey-green and dark-veined
	float on_arm = step(0.5, uv2v.y) * step(uv2v.y, 1.5);
	float k = smoothstep(infect_from, infect_full, uv2v.x) * on_arm * infect;
	vec3 rot = mix(vec3(0.22, 0.25, 0.15), vec3(0.08, 0.09, 0.05), smoothstep(0.3, 0.7, fract(sin(dot(UV * 311.0, vec2(12.9, 78.2))) * 43758.5)));
	a = mix(a, rot * (0.6 + 0.4 * dot(a, vec3(0.33))), k * 0.85);
	float grey = dot(a, vec3(0.3, 0.55, 0.15));
	a = mix(a, vec3(grey) * vec3(0.95, 0.97, 1.0), pallor * 0.7);
	ALBEDO = a;
	ROUGHNESS = rough;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	EMISSION = vec3(0.1, 0.9, 0.2) * smoothstep(0.1, 0.6, m.r) * vein_glow * 0.6;
	SSS_STRENGTH = 0.0;
}
