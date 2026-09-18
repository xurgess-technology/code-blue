shader_type spatial;
// The Hive's eyes (scripts/monsters/hive_rig.gd). The ball is painted dark glass with an ember of an
// iris round a bright orange point (art/stylized, eye_paint 'hive'); the glow comes from that paint:
// `lock` 0 lights only the point (it wanders), 1 floods the whole eyeball orange (it has seen you).

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec3 glow : source_color = vec3(1.0, 0.42, 0.06);
uniform float lock : hint_range(0.0, 1.0) = 0.0;
uniform float pin_energy = 5.0;
uniform float lock_energy = 3.5;

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	// the painted point is the only bright orange on the ball
	float pin = smoothstep(0.30, 0.85, a.r);
	ALBEDO = mix(a, glow, lock);
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
	EMISSION = glow * (pin * pin_energy * (1.0 - 0.4 * lock) + lock * lock_energy);
}
