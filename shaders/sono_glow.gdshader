shader_type spatial;
// The Sonographer's light (scripts/monsters/sonographer_rig.gd, scripts/monsters/sono_cart.gd): the
// windpipe rings behind the thin skin of its throat, and the cable that runs from the back of its
// neck to the cart. One shader does both.
//
//   level   0..1  the steady glow: faint while it is suspicious, bright while it charges an echo
//   pulse   0..1  a band of light travelling along the piece; `pulse_at` is where the band is now,
//                 in the same 0..1 the piece measures itself in (below 0 or above 1 = nothing)
//   flow    0..1  how far the steady glow has climbed the piece (the cable fills from the neck down)
//
// A piece measures itself along its own local axis: t = (local coordinate) * t_scale + t_offset,
// picking the axis with `axis` (0 = X, 1 = Y, 2 = Z). The cable is built along Y, the throat along Y
// too (the neck's own up), so both use 1.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform bool use_tex = true;
uniform vec3 base_color : source_color = vec3(0.62, 0.64, 0.62);
uniform vec3 glow : source_color = vec3(0.30, 0.78, 1.0);
uniform float level : hint_range(0.0, 1.0) = 0.0;
uniform float idle_energy = 0.35;       // what it gives off at level 0 (never quite dark)
uniform float full_energy = 9.0;        // at level 1
uniform float pulse_at = -1.0;          // where the travelling band is, in t
uniform float pulse_width = 0.16;
uniform float pulse_energy = 12.0;
uniform float flow : hint_range(0.0, 1.0) = 1.0;
uniform float flow_soft = 0.25;
uniform int axis : hint_range(0, 2) = 1;
uniform bool uv_t = false;              // measure along UV.y instead of a local axis
uniform float t_scale = 1.0;
uniform float t_offset = 0.0;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.24;

varying float v_t;

void vertex() {
	float c = uv_t ? UV.y : (axis == 0 ? VERTEX.x : (axis == 1 ? VERTEX.y : VERTEX.z));
	v_t = c * t_scale + t_offset;
}

void fragment() {
	vec3 a = use_tex ? texture(albedo_tex, UV).rgb : base_color;
	float t = clamp(v_t, 0.0, 1.0);
	// the steady glow only reaches as far along the piece as `flow`
	float reach = 1.0 - smoothstep(flow, flow + flow_soft, t);
	float e = mix(idle_energy, full_energy, level) * reach;
	// plus a band travelling along it
	float band = pulse_at < -0.5 ? 0.0 : (1.0 - smoothstep(0.0, pulse_width, abs(t - pulse_at)));
	e += band * band * pulse_energy;
	ALBEDO = mix(a, glow, clamp(0.25 * level + band * 0.6, 0.0, 0.85));
	ROUGHNESS = roughness_v;
	SPECULAR = 0.55;
	EMISSION = glow * e;
}
