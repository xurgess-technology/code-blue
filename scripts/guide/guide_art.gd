extends RefCounted
## The guide's look in one place: fonts, ink colours, and the procedural paper, board and
## backdrop shaders. Nothing here is downloaded; every texture is a shader or generated once.
##
## Fonts are SystemFonts with fallback lists, so the binder uses Courier/Georgia/Ink Free on
## Windows and whatever the closest match is elsewhere (Godot's default font as a last resort).

const INK := Color("2b2119")
const INK_SOFT := Color("5c4b3b")
const PENCIL := Color("7a7068")
const RED_INK := Color("a8261d")
const BLUE_PEN := Color("22408e")
const PAPER := Color("efe4c9")
const HIGHLIGHT := Color(1.0, 0.9, 0.2, 0.42)
const TAPE := Color(0.93, 0.89, 0.72, 0.62)
const STICKY := Color("f3dd74")

## Index tab colours, in tab order. New entries cycle through the list.
const TAB_COLOURS: Array[Color] = [
	Color("d9b23c"), Color("4f86b8"), Color("3f9a8a"), Color("c0503a"), Color("7d5aa6"),
	Color("8a6a44"), Color("5d9a4a"), Color("c7678d"), Color("3f6f9a"),
]
const PROCEDURE_TAB := Color("b3322b")
const INDEX_TAB := Color("e9e2cf")
const LOCKED_TAB := Color("9a948a")

static var _fonts := {}
static var _shaders := {}


static func font(role: String) -> Font:
	if _fonts.has(role):
		return _fonts[role]
	var f := SystemFont.new()
	var names: Array = []
	var weight := 400
	var italic := false
	match role:
		"serif", "serif_bold", "serif_italic":
			names = ["Georgia", "Libre Baskerville", "Cambria", "Book Antiqua", "Palatino Linotype",
				"DejaVu Serif", "Liberation Serif", "Times New Roman", "serif"]
			weight = 700 if role == "serif_bold" else 400
			italic = role == "serif_italic"
		"type", "type_bold":
			names = ["Courier Prime", "Courier New", "Nimbus Mono PS", "Liberation Mono", "Courier",
				"DejaVu Sans Mono", "monospace"]
			weight = 700 if role == "type_bold" else 400
		"hand", "marker":
			names = ["Ink Free", "Segoe Print", "Kalam", "Caveat", "Comic Neue", "Bradley Hand",
				"Comic Sans MS", "cursive"]
		_:
			names = ["sans-serif"]
	f.font_names = PackedStringArray(names)
	f.font_weight = weight
	f.font_italic = italic
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.hinting = TextServer.HINTING_LIGHT
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	f.generate_mipmaps = true
	var out: Font = f
	if role == "marker":
		# Ink Free has no bold cut; embolden it so the scrawls read like felt tip.
		var v := FontVariation.new()
		v.base_font = f
		v.variation_embolden = 0.55
		out = v
	_fonts[role] = out
	return out


## A font for Label3D in the world.
static func world_font(role: String) -> Font:
	var key := "world_" + role
	if _fonts.has(key):
		return _fonts[key]
	var base := font(role)
	var sf: SystemFont = base if base is SystemFont else (base as FontVariation).base_font
	# Not distance-field: MSDF breaks on Ink Free's overlapping contours (black blocks).
	# A plain rasterised font with mipmaps holds up fine at book-on-a-lectern distances.
	var f: SystemFont = sf.duplicate()
	f.generate_mipmaps = true
	_fonts[key] = f
	return f


static func tab_colour(i: int) -> Color:
	return TAB_COLOURS[posmod(i, TAB_COLOURS.size())]


## Stable 0..1 pseudo-random from a string, so stains and scrawls sit in the same place every time.
static func rand01(key: String, salt := 0) -> float:
	return float(posmod(hash("%s|%d" % [key, salt]), 100003)) / 100003.0


# ---------------------------------------------------------------------------
# Shaders
# ---------------------------------------------------------------------------

static func shader(id: String) -> Shader:
	if _shaders.has(id):
		return _shaders[id]
	var s := Shader.new()
	match id:
		"paper": s.code = PAPER_SHADER
		"board": s.code = BOARD_SHADER
		"backdrop": s.code = BACKDROP_SHADER
	_shaders[id] = s
	return s


static func paper_material(seed_key: String, side: float, torn := -1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader("paper")
	m.set_shader_parameter("side", side)
	m.set_shader_parameter("seed", rand01(seed_key) * 97.0)
	m.set_shader_parameter("torn", torn)
	return m


const PAPER_SHADER := """
shader_type canvas_item;
uniform vec2 page_size = vec2(600.0, 770.0);
uniform float side = 1.0;          // +1 right page (gutter on the left), -1 left page
uniform float seed = 0.0;
uniform vec4 paper : source_color = vec4(0.937, 0.894, 0.788, 1.0);
uniform vec3 ring = vec3(0.0, 0.0, -1.0);   // coffee ring centre (px) and radius, radius < 0 = none
uniform float ring_strength = 0.0;
uniform float stain = 0.35;
uniform float torn = -1.0;         // > 0: only a stub this many px wide survives at the gutter
uniform float shade = 0.0;         // page-flip darkening
uniform float shade_gutter = 0.0;  // shadow cast by a leaf turning over this page

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21) + seed * 0.1234);
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i), b = hash(i + vec2(1.0, 0.0)), c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.03; a *= 0.5; }
	return v;
}

void fragment() {
	vec2 px = UV * page_size;
	float gx = side > 0.0 ? px.x : page_size.x - px.x;
	float alpha = 1.0;
	float tear_edge = 0.0;
	if (torn > 0.0) {
		float jag = (fbm(vec2(px.y / 9.0, seed)) - 0.5) * 26.0 + (vnoise(vec2(px.y / 2.5, seed + 3.0)) - 0.5) * 7.0;
		float limit = torn + jag;
		alpha = 1.0 - smoothstep(limit - 0.8, limit + 0.8, gx);
		tear_edge = 1.0 - smoothstep(0.0, 5.0, limit - gx);
	}
	vec3 col = paper.rgb;
	col *= 0.93 + 0.09 * fbm(px / 150.0);
	col *= 0.985 + 0.03 * vnoise(vec2(px.x * 0.7, px.y * 0.06));
	col *= 0.975 + 0.035 * hash(floor(px));
	float e = min(min(px.x, page_size.x - px.x), min(px.y, page_size.y - px.y));
	float age = 1.0 - smoothstep(0.0, 18.0 + 34.0 * fbm(px / 45.0 + 7.0), e);
	col = mix(col, col * vec3(0.80, 0.67, 0.49), age * 0.55);
	float fox = smoothstep(0.70, 0.80, fbm(px / 24.0 + 31.0)) * stain;
	col = mix(col, col * vec3(0.80, 0.64, 0.46), fox * 0.55);
	float gut = 1.0 - smoothstep(0.0, 80.0, gx);
	col *= 1.0 - 0.30 * gut * gut;
	col *= 1.0 - 0.22 * (1.0 - smoothstep(0.0, 7.0, gx));
	if (ring.z > 0.0) {
		vec2 d = px - ring.xy;
		float ang = atan(d.y, d.x);
		float r = length(d) / ring.z + (vnoise(vec2(ang * 2.5 + 10.0, seed)) - 0.5) * 0.05;
		float rim = exp(-pow((r - 1.0) / 0.022, 2.0)) + 0.35 * exp(-pow((r - 0.94) / 0.05, 2.0));
		float arc = smoothstep(-0.35, 0.45, sin(ang + seed) + 0.55);
		float fill = (1.0 - smoothstep(0.88, 1.0, r)) * 0.22 * fbm(d / 28.0);
		col = mix(col, vec3(0.46, 0.29, 0.14), clamp((rim * arc + fill) * ring_strength, 0.0, 0.6));
	}
	col = mix(col, col * vec3(0.72, 0.62, 0.50), tear_edge * 0.6);
	col *= 1.0 - shade;
	col *= 1.0 - shade_gutter * (1.0 - smoothstep(0.0, page_size.x * 0.9, gx));
	COLOR = vec4(col, alpha);
}
"""

const BOARD_SHADER := """
shader_type canvas_item;
uniform vec2 board_size = vec2(1270.0, 796.0);
uniform vec4 base : source_color = vec4(0.30, 0.09, 0.07, 1.0);
uniform vec4 inner : source_color = vec4(0.16, 0.13, 0.11, 1.0);
uniform vec4 inner_rect = vec4(14.0, 14.0, 1242.0, 768.0);  // x, y, w, h of the inside lining
uniform float corner = 18.0;

float hash(vec2 p) { p = fract(p * vec2(233.34, 851.73)); p += dot(p, p + 23.45); return fract(p.x * p.y); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.1; a *= 0.5; } return v; }
float rbox(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }

void fragment() {
	vec2 px = UV * board_size;
	float d = rbox(px - board_size * 0.5, board_size * 0.5, corner);
	float alpha = 1.0 - smoothstep(-1.0, 0.5, d);
	vec3 col = base.rgb * (0.82 + 0.3 * fbm(px / 60.0));
	col *= 0.94 + 0.08 * hash(floor(px / 2.0));
	float scuff = smoothstep(0.62, 0.9, fbm(px / 14.0 + vec2(5.0, 9.0)));
	col = mix(col, vec3(0.55, 0.42, 0.34), scuff * 0.35);
	float edge = 1.0 - smoothstep(0.0, 10.0 + 14.0 * fbm(px / 30.0), -d);
	col = mix(col, vec3(0.62, 0.48, 0.38), edge * 0.45);
	vec2 ip = px - inner_rect.xy;
	if (ip.x > 0.0 && ip.y > 0.0 && ip.x < inner_rect.z && ip.y < inner_rect.w) {
		vec3 lin = inner.rgb * (0.85 + 0.25 * fbm(px / 9.0));
		float ie = min(min(ip.x, ip.y), min(inner_rect.z - ip.x, inner_rect.w - ip.y));
		lin *= 0.7 + 0.3 * smoothstep(0.0, 12.0, ie);
		col = lin;
	}
	COLOR = vec4(col, alpha);
}
"""

const BACKDROP_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float lod = 3.2 * amount;
	vec2 o = SCREEN_PIXEL_SIZE * 7.0 * amount;
	vec3 c = textureLod(screen_tex, SCREEN_UV, lod).rgb * 2.0;
	c += textureLod(screen_tex, SCREEN_UV + vec2(o.x, o.y), lod).rgb;
	c += textureLod(screen_tex, SCREEN_UV + vec2(-o.x, o.y), lod).rgb;
	c += textureLod(screen_tex, SCREEN_UV + vec2(o.x, -o.y), lod).rgb;
	c += textureLod(screen_tex, SCREEN_UV + vec2(-o.x, -o.y), lod).rgb;
	c /= 6.0;
	float lum = dot(c, vec3(0.3, 0.59, 0.11));
	c = mix(c, vec3(lum) * vec3(1.0, 0.95, 0.85), 0.35 * amount);
	c *= mix(1.0, 0.55, amount);
	vec2 uv = SCREEN_UV - 0.5;
	c *= 1.0 - dot(uv, uv) * 1.1 * amount;
	COLOR = vec4(c, 1.0);
}
"""
