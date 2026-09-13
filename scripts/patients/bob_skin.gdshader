shader_type spatial;
// Bob: the Kenney colormap, re-dressed in a hospital gown, with pallor, infection and breathing.
// Vertex colour channels (baked by bob_builder.gd):
//   r = gown (1 = cloth), g = infection mask, b = breathing weight, a = skin (1 = bare skin)
// UV2.x = distance along the removable arm (rest units); the infection grades in from
// infect_from to infect_full along it, per pixel, because the forearm faces are long.

uniform sampler2D colormap : source_color, filter_linear_mipmap;
uniform float pallor : hint_range(0.0, 1.0) = 0.0;
uniform float grey : hint_range(0.0, 1.0) = 0.0;
uniform float infect : hint_range(0.0, 1.0) = 0.0;
uniform float infect_from = 0.212;
uniform float infect_full = 0.236;
uniform float breath = 0.0;
uniform vec3 breath_axis = vec3(0.0, 0.0, 1.0);
instance uniform float is_head = 0.0;
uniform float knee_y = 0.085;
uniform float ankle_y = 0.03;
uniform vec3 gown_a : source_color = vec3(0.50, 0.66, 0.70);
uniform vec3 gown_b : source_color = vec3(0.30, 0.45, 0.55);
uniform vec3 skin_tone : source_color = vec3(0.93, 0.72, 0.56);
uniform vec3 sock : source_color = vec3(0.80, 0.78, 0.62);

varying vec3 mpos;
varying vec4 vcol;
varying float along;

// Colour literals below are written as sRGB and converted, like the source_color uniforms.
vec3 lin(vec3 c) { return pow(c, vec3(2.2)); }

float h3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float n3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1,0,0)), f.x), mix(h3(i + vec3(0,1,0)), h3(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(h3(i + vec3(0,0,1)), h3(i + vec3(1,0,1)), f.x), mix(h3(i + vec3(0,1,1)), h3(i + vec3(1,1,1)), f.x), f.y), f.z);
}

void vertex() {
	mpos = VERTEX;
	vcol = COLOR;
	along = UV2.x;
	VERTEX += breath_axis * breath * COLOR.b;
	VERTEX += NORMAL * COLOR.g * smoothstep(infect_from, infect_full, UV2.x) * infect * 0.012;
}

void fragment() {
	vec3 tex = texture(colormap, UV).rgb;
	vec3 col = tex;
	float skin = vcol.a;
	float gown = step(0.5, vcol.r) * (1.0 - is_head);
	if (is_head > 0.5 && vcol.r > 0.5) {
		// Thinning salt-and-pepper hair instead of the Kenney cap.
		float streak = n3(mpos * vec3(90.0, 20.0, 90.0));
		col = lin(mix(vec3(0.36, 0.34, 0.32), vec3(0.72, 0.71, 0.69), smoothstep(0.3, 0.7, streak)));
	}
	if (gown > 0.5) {
		if (mpos.y < ankle_y) {
			col = sock;
		} else if (mpos.y < knee_y) {
			col = skin_tone * (0.9 + 0.1 * n3(mpos * 60.0));
			skin = 1.0;
		} else {
			// Pale gown with a small diamond print.
			vec2 g = fract(vec2(mpos.x + mpos.y, mpos.y - mpos.x + mpos.z) * 38.0) - 0.5;
			float dot_print = 1.0 - smoothstep(0.12, 0.2, abs(g.x) + abs(g.y));
			float fold = 0.88 + 0.12 * n3(mpos * vec3(20.0, 6.0, 20.0));
			col = mix(gown_a, gown_b, dot_print * 0.8) * fold;
		}
	}
	// Pallor toward grey-blue on bare skin.
	float lum = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, lin(vec3(0.62, 0.70, 0.78)) * (lum * 1.4 + 0.02), pallor * skin * 0.85);
	// Infection: sickly green / purple mottling, dark necrotic blotches.
	float w = vcol.g * smoothstep(infect_from, infect_full, along) * infect;
	if (w > 0.001) {
		float m = n3(mpos * 55.0);
		float m2 = n3(mpos * 140.0 + 3.0);
		vec3 sick = mix(vec3(0.42, 0.47, 0.3), vec3(0.37, 0.27, 0.36), smoothstep(0.35, 0.65, m));
		sick = mix(sick, vec3(0.12, 0.06, 0.08), smoothstep(0.62, 0.8, m2) * 0.8);
		sick = mix(sick, vec3(0.5, 0.46, 0.22), smoothstep(0.78, 0.9, m2 * m) * 0.25);
		col = mix(col, lin(sick), clamp(w * 1.1, 0.0, 1.0));
	}
	vec3 dead = vec3(dot(col, vec3(0.3, 0.55, 0.15))) * vec3(0.82, 0.9, 1.05) * 1.15;
	col = mix(col, dead, grey);
	ALBEDO = col;
	ROUGHNESS = mix(0.75, 0.45, w);
	SPECULAR = 0.3;
}
