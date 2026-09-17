shader_type spatial;
// Skin material for the human models (players, surgeons, Bob).
// Variation's Skin mask texture:
//   mask R = anesthetic vein (inner left elbow)  -> `vein_glow` shows it (the minigame's green target)
//   mask G = the players' belly gash             -> `gash` 0 closed skin .. 1 open raw wound (pair with the GashSkin blend shape)
//   mask B = Bob's gunshot entry site             -> `wound` 0..1
// UV2: x = metres along the arm from the shoulder joint (fingers continue past the knuckles),
//      y = +1 right arm (Bob's amputation arm), -1 left arm, 2 legs, 0 elsewhere, as authored. The
//      glTF import flips V (y -> 1 - y), so in the game the right arm reads 0, elsewhere 1, the
//      left arm 2 and the legs -1.
//   `infect` 0..1 paints the right arm's infection past `infect_from` (metres, see the sites JSON):
//      a flushed band ahead of a dark ridged margin, raw red margin, then necrotic purple-black
//      with raw patches, yellow slough and pus spots by `infect_full`. The same palette as the
//      seal's baked Seal_Infect, so both patients' limbs read as one infection in and out of surgery.
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
uniform float grey : hint_range(0.0, 1.0) = 0.0;     // flatlined
uniform float breath = 0.0;                            // PatientBody sets it; the model breathes by its chest bone
uniform float infect_uv_scale = 90.0;                  // noise cells per UV unit for the infection's mottling

varying vec2 uv2v;

float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

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
	// infection on the right arm (UV2.y reads 0 there, see the header)
	float on_inf = (1.0 - step(0.5, abs(uv2v.y))) * infect;
	if (on_inf > 0.001 && uv2v.x > infect_from - 0.05) {
		vec2 q = UV * infect_uv_scale;
		float n1 = vnoise(q);
		float n2 = vnoise(q * 3.1 + 7.3);
		float n3 = vnoise(q * 4.0 + 3.1);
		float nj = vnoise(q * 1.7 + 11.0) * 0.65 + vnoise(q * 5.3 + 2.0) * 0.35;
		// metres past a ragged margin
		float d = uv2v.x - infect_from - (nj - 0.5) * 0.03 - (n2 - 0.5) * 0.008;
		float span = max(infect_full - infect_from, 0.01) + 0.02;
		float k = smoothstep(-0.001, 0.002, d) * on_inf;
		float deep = smoothstep(0.0, span, d + (n2 - 0.5) * 0.025);
		vec3 raw = mix(vec3(0.34, 0.03, 0.035), vec3(0.52, 0.11, 0.09), n3);
		vec3 bruise = mix(vec3(0.13, 0.05, 0.1), vec3(0.09, 0.07, 0.08), n3);
		vec3 necro = vec3(0.028, 0.015, 0.012);
		vec3 body = mix(bruise, necro, smoothstep(0.3, 0.6, n1));
		body = mix(body, raw, smoothstep(0.7, 0.75, n2) * 0.85);                    // raw patches
		float crust = 1.0 - smoothstep(0.0, 0.025, abs(n2 - 0.68));
		body = mix(body, vec3(0.42, 0.36, 0.12), crust * 0.75);                      // yellow slough round them
		vec2 cell = floor(q * 6.0);
		vec2 cf = fract(q * 6.0) - 0.5;
		float pus = step(0.9, hash21(cell)) * (1.0 - smoothstep(0.12, 0.26, length(cf)));
		body = mix(body, vec3(0.55, 0.5, 0.3), pus * 0.9);
		vec3 col = mix(raw, body, deep);
		col = mix(col, vec3(0.08, 0.004, 0.01), (1.0 - smoothstep(0.0, 0.004, d)) * 0.65);   // dark ridge at the margin
		// ahead of the margin: flushed, angry skin fading out over 4 cm
		float flush = pow(smoothstep(-0.04, 0.0, d), 1.5) * (1.0 - step(0.0, d)) * on_inf * (0.45 + 0.3 * n1);
		a = mix(a, a * vec3(0.95, 0.42, 0.38), flush);
		a = mix(a, col, k);
		rough = mix(rough, mix(0.22, 0.55, n2 * deep + (1.0 - deep) * 0.2), k);
	}
	float grey_l = dot(a, vec3(0.3, 0.55, 0.15));
	a = mix(a, vec3(grey_l) * vec3(0.95, 0.97, 1.0), pallor * 0.7);
	a = mix(a, vec3(grey_l) * vec3(0.78, 0.82, 0.86), grey * 0.8);
	ALBEDO = a;
	ROUGHNESS = rough;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	EMISSION = vec3(0.1, 0.9, 0.2) * smoothstep(0.1, 0.6, m.r) * vein_glow * 0.6;
	SSS_STRENGTH = 0.0;
}
