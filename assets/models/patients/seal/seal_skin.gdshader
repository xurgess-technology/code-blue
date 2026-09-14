shader_type spatial;
// The Blender seal patient (art/seal/README.md). One shader for both of its materials:
// Seal_Coat (use_infection = true) and Seal_Detail (eyes, whiskers, claws, cut faces, fishing line).
//
// Uniforms the game already drives on the procedural seal's coat shader keep their names:
//   pallor, grey, infect, breath.
// Mesh data baked by seal_build.py:
//   COLOR.r  infection weight (0 before the cut + 2 cm, 1 from 6 cm past it; left paddle only)
//   COLOR.g  breathing weight (thorax)
//   COLOR.b  injection site (a stripe along the back of the neck)
//   COLOR.a  gunshot site (a disc on the right flank)
//            (the eyes carry b = a = 1, which never happens on the skin; the shader gives them a catchlight)
//   UV2      the left paddle's own atlas for the infected maps. Along the paddle it is linear in
//            distance: 1.0 - UV2.y runs 0.01 at the cut line to 0.985 at the tip (0.167 m; glTF flips V),
//            so infect_front can creep the infection along it. UV2 is (0, 0) everywhere else.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap;
uniform sampler2D infect_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool use_infection = false;
uniform float normal_strength = 1.0;
uniform float specular_amount = 0.45;

uniform float pallor : hint_range(0.0, 1.0) = 0.0;
uniform float grey : hint_range(0.0, 1.0) = 0.0;
uniform float infect : hint_range(0.0, 1.0) = 0.0;
uniform float breath = 0.0;
// 0..1 of the paddle past the cut that is infected (1 = all of it, the baked look)
uniform float infect_front : hint_range(0.0, 1.0) = 1.0;
uniform float infect_swell = 0.004;
uniform float infect_bump = 0.0025;

uniform float highlight_injection : hint_range(0.0, 1.0) = 0.0;
uniform float highlight_gunshot : hint_range(0.0, 1.0) = 0.0;
uniform vec3 injection_color : source_color = vec3(0.25, 0.55, 1.0);
uniform vec3 gunshot_color : source_color = vec3(1.0, 0.55, 0.15);
// a fake catchlight on the wet eyes so they read in the dark OR
uniform float eye_glint = 1.0;

varying vec4 mask;
varying vec2 uv_inf;

vec3 lin(vec3 c) { return pow(c, vec3(2.2)); }

void vertex() {
	mask = COLOR;
	uv_inf = UV2;
	VERTEX += NORMAL * COLOR.g * breath;
	if (use_infection) {
		VERTEX += NORMAL * COLOR.r * infect * infect_swell;
	}
}

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb;
	float rough = texture(rough_tex, UV).r;
	float w = 0.0;
	if (use_infection && mask.r > 0.001 && infect > 0.001) {
		float along = 1.0 - uv_inf.y;
		w = clamp(mask.r * infect, 0.0, 1.0) * (1.0 - smoothstep(infect_front - 0.08, infect_front + 0.02, along));
		vec4 it = texture(infect_tex, uv_inf);
		col = mix(col, it.rgb, w);
		// wet: roughness from the infected height (raw hollows glossiest)
		rough = mix(rough, mix(0.12, 0.42, smoothstep(0.35, 0.7, it.a)), w);
		// surface-gradient bump from the infected height map (independent of the UV1 tangents)
		vec3 dpdx = dFdx(VERTEX);
		vec3 dpdy = dFdy(VERTEX);
		float h = (it.a - 0.5) * infect_bump * w;
		float dhx = dFdx(h);
		float dhy = dFdy(h);
		vec3 r1 = cross(dpdy, NORMAL);
		vec3 r2 = cross(NORMAL, dpdx);
		float det = dot(dpdx, r1);
		if (abs(det) > 1e-12) {
			vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
			NORMAL = normalize(abs(det) * NORMAL - grad);
		}
	}
	float lum = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, lin(vec3(0.66, 0.72, 0.8)) * (lum * 1.3 + 0.03), pallor * 0.7);
	vec3 dead = vec3(dot(col, vec3(0.3, 0.55, 0.15))) * vec3(0.82, 0.9, 1.05) * 1.1;
	col = mix(col, dead, grey);
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = specular_amount;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	float eye = use_infection ? 0.0 : step(0.5, min(mask.b, mask.a));
	float pulse = 0.65 + 0.35 * sin(TIME * 4.0);
	EMISSION = (injection_color * mask.b * highlight_injection + gunshot_color * mask.a * highlight_gunshot) * pulse * (1.0 - eye);
	if (eye > 0.5 && eye_glint > 0.0) {
		// pow() of 0 can be NaN on some drivers, and a NaN blooms: keep the bases positive
		vec3 refl = normalize(reflect(-VIEW, NORMAL));
		float glint = pow(clamp(dot(refl, normalize(vec3(-0.35, 0.75, 0.55))), 1e-4, 1.0), 260.0);
		float sheen = pow(clamp(refl.y, 1e-4, 1.0), 18.0) * 0.015;
		EMISSION += vec3(glint * 1.2 + sheen) * eye_glint * (1.0 - 0.5 * grey);
	}
}
