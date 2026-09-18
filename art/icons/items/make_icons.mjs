// Draws every item icon as its own SVG from shared rules, then a contact sheet. Run: node make_icons.mjs
// Rules: rounded-square slot, the main object centred, flat fills, a thick dark outline,
// the slot border tinted by category, and a glow only on monster parts.
import { writeFileSync, mkdirSync } from "node:fs";

const O = "#1c2226";            // outline
const STEEL = "#b9c4c9", STEEL_HI = "#eef4f6";
const WHITE = "#f4f4f0", PALE = "#9cc8e8", BLUE = "#5b93d6", TEAL = "#3fb8c0";
const RED = "#d9453a", RED_DK = "#9e2a22", GOLD = "#f2b632", GOLD_DK = "#9a6a10";
const BORDER = {
  surgery: "#3f86d6", shop: "#3fa860", monster: "#a3182c", equipment: "#c9b98f",
  loot: "#c9b98f", trinket: "#f0b429",
};

function glowFilter(id, color) {
  return `<filter id="${id}" x="-40%" y="-40%" width="180%" height="180%">
<feGaussianBlur in="SourceAlpha" stdDeviation="9" result="b"/>
<feFlood flood-color="${color}" flood-opacity="0.95"/><feComposite in2="b" operator="in" result="g"/>
<feMerge><feMergeNode in="g"/><feMergeNode in="SourceGraphic"/></feMerge></filter>`;
}

function badge(text) {
  return `<circle cx="208" cy="208" r="28" fill="${O}" stroke="#f1f4f6" stroke-width="4"/>
<text x="208" y="218" text-anchor="middle" font-family="Arial Black, Arial, sans-serif" font-weight="900" font-size="28" fill="#f1f4f6">${text}</text>`;
}

function svg({ border, glow, defs = "", body, count }) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
<defs>${glow ? glowFilter("glow", glow) : ""}${defs}</defs>
<rect x="6" y="6" width="244" height="244" rx="36" fill="#0b1416"/>
<rect x="9" y="9" width="238" height="238" rx="33" fill="none" stroke="${border}" stroke-width="5"/>${border === BORDER.trinket ? `<rect x="14" y="14" width="228" height="228" rx="28" fill="none" stroke="#fff1b8" stroke-width="2" opacity="0.8"/><path d="M40 12 L96 12" stroke="#fffbe6" stroke-width="4" stroke-linecap="round"/>` : ""}
<g stroke-linejoin="round" stroke-linecap="round">${body}</g>
${count ? badge(count) : ""}
</svg>`;
}

// A thick outlined stroke: dark underneath, colour on top.
const line = (d, color, w) =>
  `<path d="${d}" fill="none" stroke="${O}" stroke-width="${w + 12}"/><path d="${d}" fill="none" stroke="${color}" stroke-width="${w}"/>`;

const ICONS = [];
const add = (id, name, cat, spec) => ICONS.push({ id, name, cat, ...spec });

// ---- Surgery ----
add("anesthetic", "Anesthetic", "surgery", { count: "x3", body: `
<g transform="translate(0 10) rotate(-12 128 128)" stroke="${O}" stroke-width="8">
<rect x="88" y="68" width="80" height="148" rx="20" fill="#dfeef6"/>
<path d="M92 132 L164 132 L164 196 Q164 212 148 212 L108 212 Q92 212 92 196 Z" fill="${PALE}" stroke="none"/>
<rect x="88" y="68" width="80" height="148" rx="20" fill="none"/>
<rect x="88" y="104" width="80" height="34" fill="#f7f9fa" stroke-width="5"/>
<path d="M128 111 L128 131 M118 121 L138 121" stroke="${BLUE}" stroke-width="7"/>
<rect x="96" y="30" width="64" height="42" rx="9" fill="${BLUE}"/>
<path d="M104 152 L104 196" stroke="#fff" stroke-width="7" opacity="0.8"/>
</g>` });

add("gauze", "Gauze", "surgery", { count: "x2", body: `
<g stroke="${O}" stroke-width="9">
<path d="M106 186 L150 186 L147 226 Q128 234 109 226 Z" fill="${WHITE}"/>
<path d="M76 58 L180 58 L180 180 L76 180 Z" fill="#e6e6df" stroke="none"/>
<path d="M76 58 L76 180 M180 58 L180 180" fill="none"/>
<ellipse cx="128" cy="180" rx="52" ry="18" fill="#e6e6df"/>
<ellipse cx="128" cy="58" rx="52" ry="18" fill="${WHITE}"/>
<ellipse cx="128" cy="58" rx="17" ry="6" fill="#b9b9b0" stroke-width="6"/>
</g>
<g fill="none" stroke="#c9c9bf" stroke-width="4"><path d="M86 94 Q128 106 170 94"/><path d="M86 122 Q128 134 170 122"/><path d="M86 150 Q128 162 170 150"/></g>
<path d="M104 76 L104 194" stroke="#5aa0e0" stroke-width="9"/><path d="M128 196 L128 228" stroke="#5aa0e0" stroke-width="6"/>` });

add("suture_kit", "Suture kit", "surgery", { count: "x2", body: `
${line("M70 150 A62 62 0 1 1 186 118", STEEL, 14)}
<path d="M72 146 A58 58 0 0 1 104 76" fill="none" stroke="${STEEL_HI}" stroke-width="5"/>
<path d="M186 118 L194 100 L176 108 Z" fill="${STEEL}" stroke="${O}" stroke-width="6"/>
<ellipse cx="70" cy="150" rx="6" ry="9" fill="#0b1416"/>
<path d="M68 162 Q56 196 92 200 Q128 204 122 176 Q116 150 150 164 Q180 178 170 212" fill="none" stroke="${O}" stroke-width="14"/>
<path d="M68 162 Q56 196 92 200 Q128 204 122 176 Q116 150 150 164 Q180 178 170 212" fill="none" stroke="${BLUE}" stroke-width="6"/>` });

add("forceps", "Forceps", "surgery", { body: `
<g transform="translate(-6 0)">
${line("M200 52 Q148 110 74 176", STEEL, 18)}
${line("M200 52 Q160 122 92 206", STEEL, 18)}
<path d="M192 60 Q148 106 104 144" fill="none" stroke="${STEEL_HI}" stroke-width="5"/>
<path d="M192 66 Q162 116 124 160" fill="none" stroke="${STEEL_HI}" stroke-width="5"/>
<g stroke="${O}" stroke-width="3">
<rect x="-14" y="-8" width="28" height="16" rx="5" fill="${TEAL}" transform="translate(142 114) rotate(-42)"/>
<rect x="-14" y="-8" width="28" height="16" rx="5" fill="${TEAL}" transform="translate(152 138) rotate(-54)"/>
</g></g>` });

add("tourniquet", "Tourniquet", "surgery", { body: `
<ellipse cx="128" cy="142" rx="74" ry="50" fill="none" stroke="${O}" stroke-width="40"/>
<ellipse cx="128" cy="142" rx="74" ry="50" fill="none" stroke="${RED}" stroke-width="26"/>
<path d="M70 150 Q128 196 186 150" fill="none" stroke="${RED_DK}" stroke-width="5"/>
<rect x="70" y="76" width="116" height="24" rx="12" fill="#3a3f44" stroke="${O}" stroke-width="8"/>
<rect x="104" y="80" width="48" height="16" rx="6" fill="#6b747a"/>
<rect x="176" y="118" width="34" height="42" rx="8" fill="#3a3f44" stroke="${O}" stroke-width="7"/>` });

add("bone_saw", "Bone saw", "surgery", { body: `
<g transform="rotate(-32 128 128) translate(4 0)">
<path d="M96 104 L222 104 L222 136 L212 146 L202 136 L192 146 L182 136 L172 146 L162 136 L152 146 L142 136 L132 146 L122 136 L112 146 L96 140 Z" fill="${STEEL}" stroke="${O}" stroke-width="8"/>
<path d="M104 112 L214 112" stroke="${STEEL_HI}" stroke-width="5"/>
<path d="M32 98 Q32 88 44 88 L100 88 Q108 88 108 98 L108 150 Q108 160 98 160 L44 160 Q32 160 32 148 Z" fill="#e8742a" stroke="${O}" stroke-width="9"/>
<ellipse cx="70" cy="124" rx="18" ry="14" fill="#0b1416" stroke="${O}" stroke-width="6"/>
</g>` });

add("scalpel", "Scalpel", "surgery", { body: `
<g transform="translate(128 128) scale(1.08) rotate(-40) translate(-128 -128)">
<rect x="40" y="114" width="118" height="28" rx="10" fill="${STEEL}" stroke="${O}" stroke-width="9"/>
<path d="M60 122 L60 134 M72 122 L72 134 M84 122 L84 134" stroke="#8a969c" stroke-width="4"/>
<rect x="112" y="116" width="22" height="24" fill="${TEAL}" stroke="${O}" stroke-width="5"/>
<path d="M156 116 L204 110 Q226 122 206 144 L156 142 Z" fill="${STEEL_HI}" stroke="${O}" stroke-width="9"/>
<path d="M164 138 L204 138" stroke="${STEEL}" stroke-width="4"/>
</g>` });

add("eye_spoon", "Eye spoon", "surgery", { body: `
<g transform="translate(128 128) scale(1.05) rotate(-40) translate(-118 -129)">
<rect x="34" y="118" width="130" height="22" rx="10" fill="${STEEL}" stroke="${O}" stroke-width="9"/>
<rect x="40" y="120" width="34" height="18" rx="7" fill="${TEAL}" stroke="${O}" stroke-width="4"/>
<ellipse cx="190" cy="129" rx="34" ry="26" fill="${STEEL}" stroke="${O}" stroke-width="9"/>
<ellipse cx="194" cy="131" rx="21" ry="15" fill="#8a969c"/>
<path d="M176 118 Q186 112 198 114" fill="none" stroke="${STEEL_HI}" stroke-width="5"/>
</g>` });

add("syringe", "Syringe", "surgery", { body: `
<g transform="translate(128 128) scale(1.05) rotate(-40) translate(-128 -128)">
<rect x="22" y="114" width="16" height="28" rx="4" fill="${STEEL}" stroke="${O}" stroke-width="7"/>
<rect x="36" y="124" width="40" height="8" fill="${STEEL}" stroke="${O}" stroke-width="5"/>
<rect x="70" y="102" width="12" height="52" rx="4" fill="${STEEL}" stroke="${O}" stroke-width="7"/>
<rect x="80" y="110" width="104" height="36" rx="8" fill="#e8f2f8" stroke="${O}" stroke-width="8"/>
<rect x="120" y="114" width="60" height="28" rx="4" fill="${PALE}"/>
<path d="M96 110 L96 122 M112 110 L112 122 M128 110 L128 122 M144 110 L144 122 M160 110 L160 122" stroke="#6b8290" stroke-width="3"/>
<rect x="80" y="110" width="104" height="36" rx="8" fill="none" stroke="${O}" stroke-width="8"/>
<path d="M184 120 L198 124 L198 132 L184 136 Z" fill="${STEEL}" stroke="${O}" stroke-width="6"/>
<path d="M198 128 L236 128" stroke="${O}" stroke-width="9"/><path d="M198 128 L234 128" stroke="${STEEL_HI}" stroke-width="3"/>
</g>` });

// ---- Shop ----
add("placebo_pills", "Placebo pills", "shop", { body: `
<g stroke="${O}" stroke-width="9">
<rect x="78" y="78" width="100" height="140" rx="18" fill="#f3a6c4"/>
<rect x="70" y="42" width="116" height="42" rx="10" fill="${WHITE}"/>
<rect x="78" y="116" width="100" height="62" fill="${WHITE}" stroke-width="6"/>
</g>
<path d="M128 166 C104 150 106 128 118 128 C124 128 128 134 128 138 C128 134 132 128 138 128 C150 128 152 150 128 166 Z" fill="${RED}" stroke="${O}" stroke-width="4"/>
<path d="M92 90 L92 108" stroke="#fff" stroke-width="7" opacity="0.7"/>` });

add("rocket_boots", "Rocket boots", "shop", { body: `
<path d="M62 150 Q26 168 34 204 Q52 180 64 194 Q70 170 86 170 Z" fill="${GOLD}" stroke="${O}" stroke-width="6"/>
<path d="M64 162 Q46 176 48 192 Q58 178 68 182 Z" fill="#fff4c2"/>
<path d="M96 40 L152 40 Q158 40 158 46 L158 122 Q166 132 188 136 Q222 142 222 172 L222 184 L84 184 L84 150 Q84 140 92 132 L92 46 Q92 40 96 40 Z" fill="${RED}" stroke="${O}" stroke-width="9"/>
<path d="M84 176 L222 176 L222 190 Q222 202 210 202 L96 202 Q84 202 84 190 Z" fill="#3a3f44" stroke="${O}" stroke-width="8"/>
<path d="M92 64 L158 64 M92 90 L158 90" stroke="${RED_DK}" stroke-width="6"/>
<rect x="62" y="136" width="30" height="36" rx="8" fill="${STEEL}" stroke="${O}" stroke-width="7"/>
<path d="M172 146 Q192 146 206 156" fill="none" stroke="#f08a80" stroke-width="5"/>` });

// ---- Monster parts ----
add("hive_eyeball", "Hive's eyeball", "monster", { glow: "#ff8a2a",
  defs: `<clipPath id="ball"><circle cx="118" cy="128" r="56"/></clipPath>`, body: `
${line("M172 136 Q196 134 200 152 Q204 170 218 176", "#d98a8a", 13)}
<g filter="url(#glow)">
<circle cx="118" cy="128" r="58" fill="#ff8a2a"/>
<g clip-path="url(#ball)" fill="none" stroke="#c0341c" stroke-width="5">
<path d="M176 108 Q152 104 134 94"/><path d="M148 103 Q146 92 138 84"/><path d="M176 150 Q154 158 136 162"/><path d="M156 128 Q138 128 124 122"/></g>
<circle cx="118" cy="128" r="58" fill="none" stroke="#4a1a06" stroke-width="9"/>
<path d="M62 98 Q42 128 62 158" fill="#ffc45e" stroke="#4a1a06" stroke-width="7"/>
<ellipse cx="58" cy="128" rx="5" ry="15" fill="#2a0e03"/>
<ellipse cx="102" cy="100" rx="12" ry="7" fill="#ffd9a8" opacity="0.8" transform="rotate(-25 102 100)"/>
</g>` });

add("surgeon_eyeball", "Surgeon's eyeball", "monster", {
  defs: `<clipPath id="ball2"><circle cx="118" cy="120" r="56"/></clipPath>`, body: `
${line("M172 128 Q196 126 200 146 Q202 158 196 170", "#d98a8a", 13)}
<circle cx="118" cy="120" r="58" fill="#f6f1ea"/>
<g clip-path="url(#ball2)" fill="none" stroke="#d98a8a" stroke-width="4">
<path d="M176 100 Q152 96 134 86"/><path d="M176 142 Q154 150 136 154"/></g>
<circle cx="118" cy="120" r="58" fill="none" stroke="${O}" stroke-width="9"/>
<path d="M62 90 Q42 120 62 150" fill="#5a8fc8" stroke="${O}" stroke-width="7"/>
<ellipse cx="58" cy="120" rx="5" ry="15" fill="#10161a"/>
<ellipse cx="102" cy="92" rx="12" ry="7" fill="#fff" opacity="0.9" transform="rotate(-25 102 92)"/>` });

// A detached windpipe: a ribbed tube with its top opening showing.
const trachea = (fill, ring, inside, core) => `
<rect x="98" y="48" width="60" height="160" rx="12" fill="${fill}" stroke="${O}" stroke-width="9"/>
<g fill="none" stroke="${ring}" stroke-width="7">
<path d="M100 78 Q128 90 156 78"/><path d="M100 102 Q128 114 156 102"/><path d="M100 126 Q128 138 156 126"/>
<path d="M100 150 Q128 162 156 150"/><path d="M100 174 Q128 186 156 174"/></g>
${core ? `<path d="M128 66 L128 198" stroke="#f3ecff" stroke-width="12" opacity="0.85"/>` : `<path d="M108 66 L108 196" stroke="#fff" stroke-width="6" opacity="0.6"/>`}
<ellipse cx="128" cy="48" rx="30" ry="10" fill="${inside}" stroke="${O}" stroke-width="7"/>`;

add("sonographer_trachea", "Sonographer's trachea", "monster", { glow: "#9b6bff", body: `
<g filter="url(#glow)" transform="rotate(28 128 128)">${trachea("#9b6bff", "#6a3fd6", "#2a1650", true)}</g>` });

add("surgeon_trachea", "Surgeon's trachea", "monster", { body: `
<g transform="translate(6 -6) rotate(28 128 128)">${trachea("#efd3d3", "#c99a9a", "#6b2a2a", false)}</g>` });

// ---- Equipment ----
add("specimen_vat", "Specimen vat", "loot", { body: `
<rect x="70" y="58" width="116" height="160" rx="22" fill="#cfe9dc" stroke="${O}" stroke-width="9"/>
<path d="M75 96 L181 96 L181 196 Q181 213 164 213 L92 213 Q75 213 75 196 Z" fill="#8ccaa6"/>
<path d="M75 96 Q128 106 181 96" fill="none" stroke="#5fa882" stroke-width="5"/>
<circle cx="112" cy="160" r="7" fill="#e8f7ef"/><circle cx="148" cy="136" r="5" fill="#e8f7ef"/><circle cx="136" cy="186" r="9" fill="#e8f7ef"/>
<rect x="70" y="58" width="116" height="160" rx="22" fill="none" stroke="${O}" stroke-width="9"/>
<rect x="60" y="36" width="136" height="30" rx="8" fill="#6b747a" stroke="${O}" stroke-width="9"/>
<path d="M88 112 L88 192" stroke="#fff" stroke-width="8" opacity="0.6"/>` });

// ---- Plain loot ----
add("pill_bottle", "Pill bottle", "loot", { count: "x2", body: `
<g stroke="${O}" stroke-width="9">
<rect x="78" y="80" width="100" height="140" rx="16" fill="#e89a3a"/>
<rect x="70" y="42" width="116" height="44" rx="10" fill="${WHITE}"/>
<rect x="78" y="118" width="100" height="58" fill="${WHITE}" stroke-width="6"/>
</g>
<path d="M94 58 L94 72 M110 58 L110 72 M126 58 L126 72 M142 58 L142 72 M158 58 L158 72" stroke="#c9c9bf" stroke-width="4"/>
<path d="M94 136 L162 136 M94 152 L144 152" stroke="#8a8070" stroke-width="5"/>
<path d="M92 190 L92 206" stroke="#fff" stroke-width="7" opacity="0.6"/>` });

add("xray_film", "X-ray film", "loot", { body: `
<g transform="rotate(-8 128 128)">
<rect x="50" y="42" width="156" height="180" rx="10" fill="#1d2f44" stroke="${O}" stroke-width="9"/>
<path d="M128 64 L128 204" stroke="#dfe9f2" stroke-width="10"/>
<g fill="none" stroke="#dfe9f2" stroke-width="7">
<path d="M124 86 Q88 88 76 110"/><path d="M132 86 Q168 88 180 110"/>
<path d="M124 112 Q86 114 74 138"/><path d="M132 112 Q170 114 182 138"/>
<path d="M124 138 Q88 140 78 164"/><path d="M132 138 Q168 140 178 164"/></g>
<rect x="150" y="30" width="40" height="24" rx="4" fill="${STEEL}" stroke="${O}" stroke-width="6"/>
</g>` });

add("heart_monitor", "Heart monitor", "loot", { body: `
<rect x="44" y="66" width="168" height="130" rx="16" fill="#8a979d" stroke="${O}" stroke-width="9"/>
<rect x="60" y="82" width="104" height="96" rx="8" fill="#0d1c14" stroke="${O}" stroke-width="6"/>
<path d="M66 132 L88 132 L96 110 L106 156 L116 122 L124 132 L158 132" fill="none" stroke="#4be38a" stroke-width="6"/>
<circle cx="188" cy="104" r="11" fill="${RED}" stroke="${O}" stroke-width="5"/>
<circle cx="188" cy="140" r="11" fill="#6b747a" stroke="${O}" stroke-width="5"/>
<path d="M96 66 L96 50 L160 50 L160 66" fill="none" stroke="${O}" stroke-width="10"/>
<rect x="60" y="196" width="20" height="16" fill="#3a3f44" stroke="${O}" stroke-width="5"/>
<rect x="176" y="196" width="20" height="16" fill="#3a3f44" stroke="${O}" stroke-width="5"/>` });

add("gold_watch", "Gold watch", "loot", { body: `
<rect x="102" y="28" width="52" height="60" rx="8" fill="#6b4a2a" stroke="${O}" stroke-width="8"/>
<rect x="102" y="168" width="52" height="60" rx="8" fill="#6b4a2a" stroke="${O}" stroke-width="8"/>
<circle cx="128" cy="128" r="58" fill="${GOLD}" stroke="${O}" stroke-width="9"/>
<circle cx="128" cy="128" r="42" fill="#fbf4e2" stroke="${GOLD_DK}" stroke-width="5"/>
<path d="M128 128 L128 98 M128 128 L150 138" stroke="${O}" stroke-width="7"/>
<circle cx="128" cy="128" r="6" fill="${O}"/>
<rect x="184" y="120" width="14" height="16" rx="4" fill="${GOLD}" stroke="${O}" stroke-width="5"/>
<path d="M92 104 Q100 90 114 86" fill="none" stroke="#fff" stroke-width="5" opacity="0.8"/>` });

add("ultrasound", "Portable ultrasound", "loot", { body: `
<rect x="30" y="38" width="196" height="180" rx="16" fill="#dfe4e6" stroke="${O}" stroke-width="9"/>
<rect x="44" y="52" width="168" height="132" rx="6" fill="#0d1216" stroke="${O}" stroke-width="5"/>
<path d="M128 180 L56 60 L200 60 Z" fill="#2c363b"/>
<g transform="translate(128 120) scale(0.72) translate(-128 -132)">
<path d="M80 124 C66 162 90 200 132 200 C168 200 188 176 184 148 C180 124 158 118 144 132 C134 142 128 136 124 130 Z" fill="#e6eaec"/>
<circle cx="108" cy="100" r="38" fill="#e6eaec"/>
<circle cx="146" cy="106" r="7" fill="#e6eaec"/>
<circle cx="150" cy="134" r="10" fill="#e6eaec"/>
<path d="M118 94 Q126 100 134 94" fill="none" stroke="#2c363b" stroke-width="4"/>
<path d="M150 176 Q164 160 180 158" fill="none" stroke="#2c363b" stroke-width="4"/>
</g>
<rect x="44" y="192" width="80" height="12" rx="5" fill="#8a969c"/>
<circle cx="192" cy="198" r="9" fill="${TEAL}" stroke="${O}" stroke-width="5"/>` });

// ---- Trinkets ----
add("desk_phone", "Desk phone", "trinket", { body: `
<path d="M50 176 L66 108 L190 108 L206 176 Q206 194 188 194 L68 194 Q50 194 50 176 Z" fill="#cfc9b8" stroke="${O}" stroke-width="9"/>
<g fill="#8a8470" stroke="${O}" stroke-width="4">
<rect x="96" y="124" width="16" height="12" rx="3"/><rect x="120" y="124" width="16" height="12" rx="3"/><rect x="144" y="124" width="16" height="12" rx="3"/>
<rect x="96" y="144" width="16" height="12" rx="3"/><rect x="120" y="144" width="16" height="12" rx="3"/><rect x="144" y="144" width="16" height="12" rx="3"/>
<rect x="96" y="164" width="16" height="12" rx="3"/><rect x="120" y="164" width="16" height="12" rx="3"/><rect x="144" y="164" width="16" height="12" rx="3"/></g>
<path d="M58 92 Q58 62 88 62 L168 62 Q198 62 198 92 L176 100 L168 82 L88 82 L80 100 Z" fill="#3a3f44" stroke="${O}" stroke-width="9"/>
<circle cx="182" cy="130" r="8" fill="${RED}" stroke="${O}" stroke-width="4"/>` });

add("laptop", "Laptop", "trinket", { body: `
<path d="M62 50 L194 50 Q202 50 202 58 L202 150 L54 150 L54 58 Q54 50 62 50 Z" fill="#3a3f44" stroke="${O}" stroke-width="9"/>
<rect x="68" y="64" width="120" height="74" rx="4" fill="#0d1c14"/>
<g stroke="#2a6a44" stroke-width="3"><path d="M68 88 L188 88 M68 112 L188 112 M100 64 L100 138 M136 64 L136 138 M168 64 L168 138"/></g>
<circle cx="118" cy="100" r="7" fill="#4be38a"/><circle cx="156" cy="124" r="6" fill="${GOLD}"/><circle cx="86" cy="124" r="6" fill="${GOLD}"/>
<path d="M36 150 L220 150 L204 190 Q202 196 194 196 L62 196 Q54 196 52 190 Z" fill="#6b747a" stroke="${O}" stroke-width="9"/>
<rect x="104" y="168" width="48" height="12" rx="4" fill="#3a3f44"/>` });

add("defibrillator", "Defibrillator", "trinket", { body: `
<rect x="44" y="70" width="168" height="140" rx="20" fill="${GOLD}" stroke="${O}" stroke-width="9"/>
<path d="M96 70 L96 50 L160 50 L160 70" fill="none" stroke="${O}" stroke-width="12"/>
<path d="M128 184 C84 158 80 118 104 110 C116 106 124 114 128 122 C132 114 140 106 152 110 C176 118 172 158 128 184 Z" fill="${RED}" stroke="${O}" stroke-width="7"/>
<path d="M134 118 L116 146 L132 146 L120 172 L146 138 L130 138 L142 118 Z" fill="#fff" stroke="${O}" stroke-width="3"/>` });

add("pulse_oximeter", "Pulse oximeter", "trinket", { body: `
<path d="M24 134 L118 134 Q140 134 140 150 Q140 166 118 166 L24 166 Z" fill="#e8c4a8" stroke="${O}" stroke-width="8"/>
<path d="M112 140 Q126 142 128 150" fill="none" stroke="#c9a088" stroke-width="4"/>
<path d="M84 120 Q84 90 116 90 L196 90 Q220 90 220 114 L220 136 L84 136 Z" fill="#6aa8d8" stroke="${O}" stroke-width="9"/>
<path d="M84 164 L220 164 L220 180 Q220 204 196 204 L116 204 Q84 204 84 180 Z" fill="#3f78aa" stroke="${O}" stroke-width="9"/>
<rect x="124" y="54" width="84" height="48" rx="8" fill="#0d1216" stroke="${O}" stroke-width="7"/>
<text x="166" y="90" text-anchor="middle" font-family="Consolas, monospace" font-weight="700" font-size="34" fill="#ff5a4a">98</text>
<circle cx="204" cy="150" r="7" fill="${RED}"/>` });

add("reflex_hammer", "Reflex hammer", "trinket", { body: `
<g transform="translate(0 -10) rotate(35 128 138)">
<rect x="116" y="92" width="24" height="134" rx="9" fill="${STEEL}" stroke="${O}" stroke-width="9"/>
<path d="M123 104 L123 216" stroke="${STEEL_HI}" stroke-width="4"/>
<rect x="66" y="50" width="124" height="48" rx="24" fill="${RED}" stroke="${O}" stroke-width="10"/>
<path d="M88 62 L168 62" stroke="#f08a80" stroke-width="6"/>
<rect x="110" y="88" width="36" height="16" rx="5" fill="#8a969c" stroke="${O}" stroke-width="6"/>
</g>` });

add("epipen", "EpiPen", "trinket", { body: `
<g transform="translate(128 128) scale(1.2) rotate(-40) translate(-120 -128)">
<rect x="58" y="108" width="120" height="40" rx="14" fill="${GOLD}" stroke="${O}" stroke-width="9"/>
<rect x="84" y="112" width="60" height="32" fill="${WHITE}" stroke="${O}" stroke-width="5"/>
<path d="M94 122 L134 122 M94 134 L120 134" stroke="#8a8070" stroke-width="4"/>
<rect x="24" y="112" width="40" height="32" rx="10" fill="${BLUE}" stroke="${O}" stroke-width="9"/>
<path d="M176 114 L214 118 Q226 128 214 138 L176 142 Z" fill="#e8742a" stroke="${O}" stroke-width="9"/>
</g>` });

// ---- Write files and a contact sheet ----
// Two versions of each icon: framed (slot, border, a sample count badge) for sheets, the database
// and anywhere an icon stands alone; bare (just the object, transparent) for the HUD, which draws
// its own slot, border, selection and live count.
mkdirSync(new URL("./bare/", import.meta.url), { recursive: true });
for (const i of ICONS) {
  writeFileSync(new URL(`./${i.id}.svg`, import.meta.url), svg({ border: i.border ?? BORDER[i.cat], glow: i.glow, defs: i.defs, body: i.body, count: i.count }));
  writeFileSync(new URL(`./bare/${i.id}.svg`, import.meta.url), `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
<defs>${i.glow ? glowFilter("glow", i.glow) : ""}${i.defs ?? ""}</defs>
<g stroke-linejoin="round" stroke-linecap="round">${i.body}</g>
</svg>`);
}
writeFileSync(new URL("./categories.json", import.meta.url), JSON.stringify({
  borders: BORDER, items: Object.fromEntries(ICONS.map(i => [i.id, { name: i.name, category: i.cat, glow: i.glow ?? null }])),
}, null, 2));
const groups = [["surgery", "Surgery"], ["shop", "Shop"], ["monster", "Body parts"], ["loot", "Plain loot (and the vat)"], ["trinket", "Trinkets"]];
const cell = i => `<div class="c"><img src="${i.id}.svg" width="96"><img class="s" src="${i.id}.svg" width="48"><div>${i.name}</div></div>`;
const html = `<!doctype html><html><head><meta charset="utf-8"><title>Item icons</title><style>
body{margin:0;background:#070d0e;color:#9fb3b3;font:13px system-ui,sans-serif;padding:8px 20px}
h3{font-weight:500;color:#c9d6d6;margin:14px 0 6px}.row{display:flex;flex-wrap:wrap;gap:18px}
.c{width:112px;text-align:center}.c img{display:block;margin:0 auto 4px}.c img.s{margin-bottom:6px}
</style></head><body>
<h3>Abilities</h3><div class="row"><div class="c"><img src="../hive_eyes.svg" width="96"><img class="s" src="../hive_eyes.svg" width="48"><div>Hive Eyes</div></div><div class="c"><img src="../echolocation.svg" width="96"><img class="s" src="../echolocation.svg" width="48"><div>Echolocation</div></div></div>
${groups.map(([k, t]) => `<h3>${t}</h3><div class="row">${ICONS.filter(i => i.cat === k).map(cell).join("")}</div>`).join("\n")}
</body></html>`;
writeFileSync(new URL("./sheet.html", import.meta.url), html);
console.log(ICONS.length, "icons");
