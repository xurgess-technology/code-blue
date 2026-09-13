#!/usr/bin/env node
// tools/gen_audio_surgery_saw.mjs: offline synthesiser for the bone saw minigame.
//
//   node tools/gen_audio_surgery_saw.mjs           # write audio/sfx/surgery_saw_*.wav
//   node tools/gen_audio_surgery_saw.mjs --check   # render + report, do not write
//
// Same approach as tools/gen_audio.mjs: dependency-free, one seeded PRNG stream per
// asset so re-running is byte-identical, 16-bit mono PCM, normalised and trimmed.
//
// Cues (numbered variants are picked at random by Audio.play):
//   surgery_saw_rasp_01..04   one pass of the saw through skin / muscle (soft, fleshy)
//   surgery_saw_grind_01..04  one pass through bone (harsh teeth chatter, gritty)
//   surgery_saw_squelch_01..03 wet squelch / spurt
//   surgery_saw_thunk         the limb coming off and hitting the table

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 44100;
const TAU = Math.PI * 2;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'audio', 'sfx');
const DRY_RUN = process.argv.includes('--check');

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function seedOf(name) {
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) { h ^= name.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function rngFor(name) {
  const r = mulberry32(seedOf(name));
  r.range = (a, b) => a + r() * (b - a);
  return r;
}

/** RBJ biquad, stateful; call f(x) or f(x, newCutoff). */
function biquad(type, f0, Q) {
  const coeffs = (f) => {
    f = Math.min(Math.max(f, 10), SR * 0.45);
    const w0 = (TAU * f) / SR, cw = Math.cos(w0), sw = Math.sin(w0), al = sw / (2 * Q);
    let b0, b1, b2;
    const a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; }
    else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; }
    else { b0 = al; b1 = 0; b2 = -al; }
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  };
  let c = coeffs(f0), cur = f0, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x, f) => {
    if (f !== undefined && Math.abs(f - cur) > 1) { c = coeffs(f); cur = f; }
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

const buf = (sec) => new Float32Array(Math.ceil(sec * SR));
const add = (dst, src, at = 0, gain = 1) => {
  const o = Math.round(at * SR);
  for (let i = 0; i < src.length && o + i < dst.length; i++) if (o + i >= 0) dst[o + i] += src[i] * gain;
};
/** Attack / decay envelope shaped like a stroke: fast rise, body, fall. */
const strokeEnv = (i, n, att = 0.08, rel = 0.35) => {
  const x = i / n;
  if (x < att) return Math.sin((x / att) * Math.PI * 0.5);
  if (x > 1 - rel) return Math.pow(Math.max(0, (1 - x) / rel), 1.6);
  return 1;
};

function rasp(v) {
  const r = rngFor(`surgery_saw_rasp${v}`);
  const dur = r.range(0.26, 0.36);
  const out = buf(dur + 0.05), n = Math.ceil(dur * SR);
  const bp = biquad('bandpass', r.range(700, 1100), 0.9);
  const lp = biquad('lowpass', 2600, 0.7);
  const body = biquad('lowpass', 380, 0.8);
  const toothHz = r.range(55, 80);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const e = strokeEnv(i, n, 0.12, 0.4);
    const x = i / n;
    // Tooth rate rises and falls with the stroke speed.
    const rate = toothHz * (0.7 + 0.6 * Math.sin(Math.PI * x));
    ph += rate / SR; if (ph >= 1) ph -= 1;
    const tooth = Math.pow(1 - ph, 5);
    const w = r() * 2 - 1;
    let s = bp(w, 700 + 700 * Math.sin(Math.PI * x)) * (0.45 + 0.9 * tooth);
    s += body(w) * 1.6 * (0.5 + 0.5 * tooth);           // meaty low drag
    out[i] = lp(s) * e;
  }
  return out;
}

function grind(v) {
  const r = rngFor(`surgery_saw_grind${v}`);
  const dur = r.range(0.28, 0.38);
  const out = buf(dur + 0.06), n = Math.ceil(dur * SR);
  const hi = biquad('bandpass', r.range(2600, 3400), 2.2);
  const mid = biquad('bandpass', r.range(900, 1300), 3.5);
  const hp = biquad('highpass', 180, 0.7);
  const toothHz = r.range(120, 170);
  const ring = r.range(520, 760);
  let ph = 0, rp = 0;
  for (let i = 0; i < n; i++) {
    const e = strokeEnv(i, n, 0.06, 0.3);
    const x = i / n;
    const rate = toothHz * (0.75 + 0.5 * Math.sin(Math.PI * x)) * (1 + 0.08 * (r() - 0.5));
    ph += rate / SR; if (ph >= 1) { ph -= 1; }
    const tooth = Math.pow(1 - ph, 9);                       // hard clicks: teeth on bone
    const w = r() * 2 - 1;
    rp += ring * (1 + 0.03 * Math.sin(TAU * 7 * i / SR)) / SR; if (rp >= 1) rp -= 1;
    let s = hi(w) * (0.4 + 1.6 * tooth) + mid(w) * 0.9 * tooth;
    s += (rp < 0.5 ? 1 : -1) * 0.07 * (0.3 + tooth);        // gritty metallic buzz
    s += w * 0.25 * tooth;                                   // raw crunch
    out[i] = Math.tanh(hp(s) * 2.2) * e;
  }
  return out;
}

function squelch(v) {
  const r = rngFor(`surgery_saw_squelch${v}`);
  const dur = r.range(0.3, 0.45);
  const out = buf(dur + 0.08), n = Math.ceil(dur * SR);
  const lp = biquad('lowpass', 900, 1.2);
  for (let i = 0; i < n; i++) {
    const x = i / n;
    const e = Math.pow(1 - x, 2.2) * Math.min(1, i / (0.004 * SR));
    out[i] = lp(r() * 2 - 1, 1400 - 1000 * x) * e * 0.9;
  }
  // Bubbly blips: short sines with a fast downward pitch drop.
  const blips = 4 + Math.floor(r() * 4);
  for (let b = 0; b < blips; b++) {
    const at = r.range(0, dur * 0.7), len = r.range(0.025, 0.06);
    const f0 = r.range(260, 620), f1 = f0 * r.range(0.35, 0.6);
    const bl = buf(len); let p = 0;
    for (let i = 0; i < bl.length; i++) {
      const x = i / bl.length;
      p += (f0 * Math.pow(f1 / f0, x)) / SR;
      bl[i] = Math.sin(TAU * p) * Math.sin(Math.PI * x);
    }
    add(out, bl, at, r.range(0.25, 0.5));
  }
  return out;
}

function thunk() {
  const r = rngFor('surgery_saw_thunk');
  const out = buf(1.2);
  // Bone giving way: a sharp crack first.
  const crack = buf(0.05), chp = biquad('highpass', 1500, 0.8);
  for (let i = 0; i < crack.length; i++) crack[i] = chp(r() * 2 - 1) * Math.pow(1 - i / crack.length, 4);
  add(out, crack, 0, 0.7);
  // The heavy limb hitting the table: low body thump.
  const T = 0.14;
  const body = buf(0.6); let p = 0;
  for (let i = 0; i < body.length; i++) {
    const x = i / body.length;
    p += (80 * Math.pow(38 / 80, Math.min(1, x * 2))) / SR;
    body[i] = Math.sin(TAU * p) * Math.pow(1 - x, 3) * Math.min(1, i / (0.003 * SR));
  }
  add(out, body, T, 1.0);
  const slap = buf(0.22), slp = biquad('lowpass', 1100, 0.9);
  for (let i = 0; i < slap.length; i++) slap[i] = slp(r() * 2 - 1) * Math.pow(1 - i / slap.length, 3);
  add(out, slap, T, 0.9);
  // A wet settle after.
  add(out, squelch(9), T + 0.12, 0.45);
  for (let i = 0; i < out.length; i++) out[i] = Math.tanh(out[i] * 1.4);
  return out;
}

function finalize(a, targetDb = -3) {
  let peak = 0, last = 0;
  for (let i = 0; i < a.length; i++) peak = Math.max(peak, Math.abs(a[i]));
  const thresh = peak * Math.pow(10, -60 / 20);
  for (let i = a.length - 1; i > 0; i--) if (Math.abs(a[i]) > thresh) { last = i; break; }
  const n = Math.min(a.length, last + Math.ceil(0.01 * SR));
  const g = peak > 0 ? Math.pow(10, targetDb / 20) / peak : 1;
  const fade = Math.ceil(0.004 * SR);
  const o = new Float32Array(n);
  for (let i = 0; i < n; i++) o[i] = a[i] * g * (i >= n - fade ? (n - i) / fade : 1);
  return o;
}

function writeWav(name, a) {
  const bytes = a.length * 2, b = Buffer.alloc(44 + bytes);
  b.write('RIFF', 0); b.writeUInt32LE(36 + bytes, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(bytes, 40);
  for (let i = 0; i < a.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, a[i])) * 32767), 44 + i * 2);
  if (!DRY_RUN) fs.writeFileSync(path.join(OUT, name), b);
  console.log(`  audio/sfx/${name.padEnd(28)} ${(a.length / SR).toFixed(2)}s  ${(b.length / 1024).toFixed(0)} KB`);
}

if (!DRY_RUN) fs.mkdirSync(OUT, { recursive: true });
console.log(`Bone saw sfx ${DRY_RUN ? '(dry run)' : ''}`);
for (let v = 1; v <= 4; v++) writeWav(`surgery_saw_rasp_0${v}.wav`, finalize(rasp(v), -4));
for (let v = 1; v <= 4; v++) writeWav(`surgery_saw_grind_0${v}.wav`, finalize(grind(v), -3));
for (let v = 1; v <= 3; v++) writeWav(`surgery_saw_squelch_0${v}.wav`, finalize(squelch(v), -4));
writeWav('surgery_saw_thunk.wav', finalize(thunk(), -1.5));
