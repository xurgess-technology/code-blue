shader_type spatial;
// The seal: mottled harbor-seal coat, pallor, infection and breathing.
// Vertex colour channels (baked by seal_builder.gd):
//   r = belly lightness (0 dark back .. 1 pale belly), g = infection weight,
//   b = breathing weight, a = spot amount

uniform float pallor : hint_range(0.0, 1.0) = 0.0;
uniform float grey : hint_range(0.0, 1.0) = 0.0;
uniform float infect : hint_range(0.0, 1.0) = 0.0;
uniform float breath = 0.0;
uniform vec3 back_col : source_color = vec3(0.36, 0.38, 0.40);
uniform vec3 belly_col : source_color = vec3(0.74, 0.73, 0.68);
uniform vec3 spot_col : source_color = vec3(0.13, 0.14, 0.16);

varying vec3 mpos;
varying vec4 vcol;

// Colour literals below are written as sRGB and converted, like the source_color uniforms.
vec3 lin(vec3 c) { return pow(c, vec3(2.2)); }

float h3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
vec3 h33(vec3 p) {
	return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)), dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}
float n3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h3(i), h3(i + vec3(1,0,0)), f.x), mix(h3(i + vec3(0,1,0)), h3(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(h3(i + vec3(0,0,1)), h3(i + vec3(1,0,1)), f.x), mix(h3(i + vec3(0,1,1)), h3(i + vec3(1,1,1)), f.x), f.y), f.z);
}
// Nearest random cell point: distance and that cell's random value (irregular spots).
vec2 cells(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	float d = 8.0; float h = 0.0;
	for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++) for (int z = -1; z <= 1; z++) {
		vec3 o = vec3(float(x), float(y), float(z));
		vec3 r = o + h33(i + o) * 0.8 + 0.1 - f;
		float dd = dot(r, r);
		if (dd < d) { d = dd; h = h3(i + o + 17.0); }
	}
	return vec2(sqrt(d), h);
}

void vertex() {
	mpos = VERTEX;
	vcol = COLOR;
	VERTEX += NORMAL * COLOR.b * breath;
	VERTEX += NORMAL * COLOR.g * infect * 0.018;
}

void fragment() {
	float belly = vcol.r;
	vec3 base = mix(back_col, belly_col, belly);
	base *= 0.9 + 0.2 * n3(mpos * 9.0);
	// Harbor seal: dense irregular dark spots and blotches, a few pale rings, fewer on the belly.
	vec3 wp = mpos + (vec3(n3(mpos * 6.0), n3(mpos * 6.0 + 5.0), n3(mpos * 6.0 + 9.0)) - 0.5) * 0.09;
	vec2 c = cells(wp * 21.0);
	float rad = mix(0.12, 0.36, c.y * c.y) * step(0.3, c.y + 0.25 * n3(mpos * 3.0));
	float spot = 1.0 - smoothstep(rad - 0.05, rad + 0.02, c.x + 0.1 * n3(mpos * 55.0));
	float ring = step(0.9, c.y) * (1.0 - smoothstep(rad + 0.04, rad + 0.14, c.x)) * (1.0 - spot);
	vec2 c2 = cells(wp * 38.0 + 3.0);
	float speck = (1.0 - smoothstep(0.1, 0.2, c2.x)) * step(0.35, c2.y);
	float amount = vcol.a * mix(1.0, 0.45, belly);
	vec3 col = mix(base, base * 1.3 + 0.01, ring * amount * 0.4);
	col = mix(col, spot_col, max(spot, speck * 0.8) * amount * 0.9);
	float lum = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, lin(vec3(0.66, 0.72, 0.8)) * (lum * 1.3 + 0.03), pallor * 0.7);
	float w = vcol.g * infect;
	if (w > 0.001) {
		float m = n3(mpos * 30.0);
		float m2 = n3(mpos * 80.0 + 3.0);
		vec3 sick = mix(vec3(0.42, 0.47, 0.3), vec3(0.37, 0.27, 0.36), smoothstep(0.35, 0.65, m));
		sick = mix(sick, vec3(0.1, 0.05, 0.07), smoothstep(0.6, 0.8, m2) * 0.8);
		sick = mix(sick, vec3(0.5, 0.46, 0.22), smoothstep(0.75, 0.9, m2 * m) * 0.25);
		col = mix(col, lin(sick), clamp(w * 1.1, 0.0, 1.0));
	}
	vec3 dead = vec3(dot(col, vec3(0.3, 0.55, 0.15))) * vec3(0.82, 0.9, 1.05) * 1.1;
	col = mix(col, dead, grey);
	ALBEDO = col;
	ROUGHNESS = mix(0.62, 0.4, w);
	SPECULAR = 0.45;
}
