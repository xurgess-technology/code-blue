// Code Blue — single-pass screen-space post stack.
//
// One cheap fullscreen pass. Order matters and is chosen so the expensive-looking
// bits (aberration) happen in UV space before we ever touch colour:
//
//   barrel distort -> pulse zoom -> chromatic aberration -> grain
//   -> edge desaturation -> vignette -> damage tint -> scanlines -> blackout
//
// Everything is driven from GDScript through Look.PostFX (scripts/look.gd);
// gameplay code should never touch these uniform names directly.

shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// --- vignette -------------------------------------------------------------
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.70;
// Radius (in aspect-corrected units from centre) at which the vignette reaches
// full strength. ~1.05 puts "full" just past the corners on 16:9.
uniform float vignette_softness : hint_range(0.2, 2.0) = 1.05;
uniform vec3 vignette_color : source_color = vec3(0.0, 0.012, 0.010);

// --- damage / danger ------------------------------------------------------
// damage: red edge pulse on taking a hit. danger: monster proximity dread.
uniform float damage : hint_range(0.0, 1.0) = 0.0;
uniform float danger : hint_range(0.0, 1.0) = 0.0;
uniform vec3 damage_color : source_color = vec3(0.62, 0.02, 0.03);

// --- film grain -----------------------------------------------------------
uniform float grain_amount : hint_range(0.0, 0.5) = 0.045;
uniform float grain_size : hint_range(0.5, 8.0) = 1.5;
// Grain is louder in the dark, which is where it actually reads.
uniform float grain_shadow_bias : hint_range(0.0, 2.0) = 1.0;

// --- chromatic aberration -------------------------------------------------
uniform float aberration : hint_range(0.0, 0.05) = 0.0016;
uniform float aberration_damage : hint_range(0.0, 0.1) = 0.010;
uniform float aberration_danger : hint_range(0.0, 0.1) = 0.004;

// --- CRT / scanlines (patient monitor only) -------------------------------
uniform float scanlines : hint_range(0.0, 1.0) = 0.0;
uniform float scanline_count : hint_range(64.0, 2048.0) = 700.0;
uniform float scanline_roll : hint_range(0.0, 4.0) = 0.35;

// --- lens -----------------------------------------------------------------
uniform float barrel : hint_range(-0.2, 0.2) = 0.022;
uniform float edge_desaturation : hint_range(0.0, 1.0) = 0.55;

// --- transitions / heartbeat ----------------------------------------------
uniform float blackout : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform float pulse_rate : hint_range(0.1, 6.0) = 1.55;

uniform float aspect : hint_range(0.25, 4.0) = 1.7777778;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Aspect-corrected vector from centre. Used by every radial term below so
	// the effects stay circular instead of stretching on ultrawide.
	vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
	float r2 = dot(c, c);
	float r = sqrt(r2);

	// --- heartbeat throb: a slow in/out breath of the whole frame ----------
	// Double-tap waveform (lub-dub) rather than a plain sine.
	float beat_t = TIME * pulse_rate;
	float beat = sin(beat_t * TAU) * 0.65 + sin(beat_t * TAU * 2.0 + 0.9) * 0.35;
	float throb = beat * pulse;

	// --- barrel distortion (very subtle) + pulse zoom ----------------------
	float k = barrel + throb * 0.030;
	vec2 duv = (uv - 0.5) * (1.0 + k * r2) * (1.0 - throb * 0.012);
	uv = duv + 0.5;

	// --- chromatic aberration, scaled toward the edges ---------------------
	float ab = aberration + damage * aberration_damage + danger * aberration_danger;
	ab += abs(throb) * 0.0035;
	// r2 keeps the centre of the screen perfectly clean.
	vec2 ab_dir = duv * (ab * (r2 * 4.0 + 0.15));

	vec3 col;
	if (ab > 0.00001) {
		col.r = textureLod(screen_tex, clamp(uv + ab_dir, vec2(0.0), vec2(1.0)), 0.0).r;
		col.g = textureLod(screen_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).g;
		col.b = textureLod(screen_tex, clamp(uv - ab_dir, vec2(0.0), vec2(1.0)), 0.0).b;
	} else {
		col = textureLod(screen_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).rgb;
	}

	// --- film grain --------------------------------------------------------
	if (grain_amount > 0.0001) {
		vec2 gp = floor(FRAGCOORD.xy / max(grain_size, 0.5));
		// Three decorrelated time slices so it never looks like a crawling pattern.
		float n = hash12(gp + vec2(fract(TIME * 31.7) * 512.0, fract(TIME * 17.3) * 512.0));
		n = n - 0.5;
		// Loudest in the shadows, nearly gone in the flashlight hotspot.
		float l = luma(col);
		float shadow_w = mix(1.0, 1.0 - l, clamp(grain_shadow_bias, 0.0, 1.0));
		col += n * grain_amount * shadow_w * 2.0;
	}

	// --- desaturation toward the edges -------------------------------------
	if (edge_desaturation > 0.0001) {
		float w = clamp(r2 * 1.35, 0.0, 1.0);
		w = w * w * edge_desaturation;
		// Desaturate toward a cold grey, not a neutral one: keeps the sickly cast.
		vec3 grey = vec3(luma(col)) * vec3(0.92, 1.0, 1.02);
		col = mix(col, grey, w);
	}

	// --- vignette ----------------------------------------------------------
	float vig_amt = clamp(vignette_strength + danger * 0.22 + damage * 0.18, 0.0, 1.0);
	if (vig_amt > 0.0001) {
		// Squared radial falloff rather than a smoothstep band. The smoothstep
		// version saturated to fully black over everything past r=0.62, which
		// ate two thirds of the frame; this keeps a gradient all the way out.
		float vr = clamp(r / max(vignette_softness, 0.05), 0.0, 1.0);
		float fall = vr * vr * vig_amt;
		col = mix(col, vignette_color, clamp(fall, 0.0, 1.0));
	}

	// --- damage red pulse --------------------------------------------------
	if (damage > 0.0001) {
		// Pulses fast at first, then settles; the caller decays `damage` itself.
		float dp = 0.68 + 0.32 * sin(TIME * 9.0);
		// Starts at r=0.5 (well outside the action) and only reaches full in
		// the corners. At damage=1.0 this must still leave the centre of the
		// screen playable -- you have to be able to see the thing hitting you.
		float edge = smoothstep(0.50, 1.05, r);
		col = mix(col, damage_color, clamp(damage * dp * edge * 0.80, 0.0, 0.80));
		// Plus a faint full-screen wash so a hit reads even looking at a wall.
		col = mix(col, damage_color, damage * 0.06);
	}

	// --- scanlines / CRT (off by default) ----------------------------------
	if (scanlines > 0.0001) {
		float sl = sin((uv.y + TIME * scanline_roll * 0.02) * scanline_count * PI);
		sl = 0.5 + 0.5 * sl;
		col *= mix(1.0, 0.55 + 0.45 * sl, scanlines);
		// Faint phosphor triad.
		float triad = 0.5 + 0.5 * sin(FRAGCOORD.x * PI * 0.6667);
		col *= mix(1.0, 0.88 + 0.12 * triad, scanlines * 0.6);
	}

	// --- blackout ----------------------------------------------------------
	col *= clamp(1.0 - blackout, 0.0, 1.0);

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
