#!/usr/bin/env node
// tools/gen_audio_brains.mjs: offline synth for brains (sweep 3): harvested brains, the blender,
// Echo and Hive Eyes.
//
//   node tools/gen_audio_brains.mjs          # write audio/sfx/brains_*.wav
//   node tools/gen_audio_brains.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   brains_squelch   a brain landing: a wet slap and a soft settle
//   brains_blend     the blender: motor spin-up, a chunky grind, a wet whirr, spin-down (1.6 s)
//   brains_gulp      drinking it: three thick gulps and a shudder
//   brains_shriek    Echo: a rising, throat-tearing shriek with a ringing tail
//   brains_hive_in   into a Hive's eyes: a sucking whoosh into a sick low drone
//   brains_hive_out  back into your body: a snap and a falling breath

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 44100;
const TAU = Math.PI * 2;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'audio', 'sfx');
const DRY = process.argv.includes('--check');

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function rngFor(name) {
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) { h ^= name.charCodeAt(i); h = Math.imul(h, 16777619); }
  const r = mulberry32(h >>> 0);
  r.range = (a, b) => a + r() * (b - a);
  return r;
}

function biquad(type, f0, Q) {
  let b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0, cur = -1;
  const set = (f) => {
    const w = TAU * Math.max(20, Math.min(f, SR * 0.45)) / SR, cw = Math.cos(w), al = Math.sin(w) / (2 * Q);
    let n0, n1, n2;
    if (type === 'lowpass') { n0 = (1 - cw) / 2; n1 = 1 - cw; n2 = n0; }
    else if (type === 'highpass') { n0 = (1 + cw) / 2; n1 = -(1 + cw); n2 = n0; }
    else { n0 = al; n1 = 0; n2 = -al; }
    const d0 = 1 + al, d1 = -2 * cw, d2 = 1 - al;
    b0 = n0 / d0; b1 = n1 / d0; b2 = n2 / d0; a1 = d1 / d0; a2 = d2 / d0; cur = f;
  };
  set(f0);
  return (x, f) => {
    if (f !== undefined && Math.abs(f - cur) > 1) set(f);
    const y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

class Buf {
  constructor(sec) { this.d = new Float32Array(Math.round(sec * SR)); }
  add(i, v) { if (i >= 0 && i < this.d.length) this.d[i] += v; }
  peak() { let p = 0; for (const v of this.d) p = Math.max(p, Math.abs(v)); return p; }
}

const env = (t, a, d) => Math.min(1, t / a) * Math.exp(-t * d);

function squelch() {
  const r = rngFor('squelch'), b = new Buf(0.55);
  const lp = biquad('lowpass', 900, 0.9);
  const bp = biquad('bandpass', 420, 2.5);
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const n = r() * 2 - 1;
    // The slap: a low wet thump with a falling pitch, bubbles of band-passed noise after it.
    ph += TAU * (140 * Math.exp(-t * 18) + 55) / SR;
    let v = Math.sin(ph) * env(t, 0.002, 22) * 0.9;
    v += lp(n) * env(t, 0.001, 30) * 0.8;
    const bub = Math.max(0, Math.sin(TAU * 23 * t + Math.sin(TAU * 7 * t) * 3));
    v += bp(n, 380 + 300 * bub) * bub * env(t, 0.04, 7) * 0.6;
    b.add(i, v);
  }
  return b;
}

function blend() {
  const r = rngFor('blend'), b = new Buf(1.6);
  const motor = biquad('bandpass', 600, 1.2);
  const grind = biquad('lowpass', 1400, 0.8);
  const wet = biquad('bandpass', 900, 3);
  let ph = 0, ph2 = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const up = Math.min(1, t / 0.25);
    const down = Math.min(1, (1.6 - t) / 0.25);
    const speed = up * down;
    const f = 90 + 230 * speed;
    ph += TAU * f / SR;
    ph2 += TAU * f * 3.02 / SR;
    const saw = ((ph / TAU) % 1) * 2 - 1;
    const n = r() * 2 - 1;
    let v = motor(saw * 0.6 + n * 0.25, 400 + 900 * speed) * 0.9 * speed;
    v += Math.sin(ph2) * 0.08 * speed;
    // Chunks hitting the blades: random clunks in the first half, fewer as it liquefies.
    const chunky = Math.max(0, 1 - t / 0.9);
    if (r() < 0.0009 * chunky) {
      for (let k = 0; k < 900; k++) b.add(i + k, grind(r() * 2 - 1) * Math.exp(-k / 140) * 0.9 * chunky);
    }
    v += wet(n, 700 + 500 * Math.sin(TAU * 11 * t)) * 0.35 * speed * (1 - chunky * 0.5);
    b.add(i, v);
  }
  return b;
}

function gulp() {
  const r = rngFor('gulp'), b = new Buf(1.1);
  for (let k = 0; k < 3; k++) {
    const at = 0.05 + k * 0.27;
    const i0 = Math.round(at * SR);
    const bp = biquad('bandpass', 300, 4);
    let ph = 0;
    for (let i = 0; i < Math.round(0.22 * SR); i++) {
      const t = i / SR;
      // A throat bloop: a pitch that drops fast, with a wet noise edge.
      const f = 320 * Math.exp(-t * 9) + 90 + k * 12;
      ph += TAU * f / SR;
      const e = env(t, 0.008, 14);
      b.add(i0 + i, (Math.sin(ph) * 0.8 + bp(r() * 2 - 1, f * 2) * 0.6) * e);
    }
  }
  // A shudder of breath after.
  const hp = biquad('bandpass', 1800, 0.8);
  for (let i = Math.round(0.85 * SR); i < b.d.length; i++) {
    const t = i / SR - 0.85;
    b.add(i, hp(r() * 2 - 1) * env(t, 0.03, 9) * 0.25 * (0.6 + 0.4 * Math.sin(TAU * 18 * t)));
  }
  return b;
}

function shriek() {
  const r = rngFor('shriek'), b = new Buf(2.1);
  // Two formants over a rough glottal source whose pitch climbs, wavers and breaks.
  const f1 = biquad('bandpass', 800, 5);
  const f2 = biquad('bandpass', 2400, 6);
  const f3 = biquad('bandpass', 3600, 8);
  const air = biquad('highpass', 2500, 0.7);
  let ph = 0, ph2 = 0, vib = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const e = Math.min(1, t / 0.06) * (t < 1.1 ? 1 : Math.exp(-(t - 1.1) * 3.2));
    vib += TAU * (7 + 5 * t) / SR;
    const pitch = 420 + 520 * Math.min(1, t / 0.5) + 60 * Math.sin(vib) + (r() - 0.5) * 60;
    ph += TAU * pitch / SR;
    ph2 += TAU * pitch * 1.013 / SR;
    const src = (((ph / TAU) % 1) * 2 - 1) * 0.6 + (((ph2 / TAU) % 1) * 2 - 1) * 0.4 + (r() * 2 - 1) * 0.35;
    let v = f1(src, 900 + 300 * Math.sin(t * 5)) * 1.1 + f2(src, 2300 + 400 * Math.min(1, t)) * 0.9 + f3(src) * 0.5;
    v += air(r() * 2 - 1) * 0.25;
    // A metallic ring under it: the echo part of Echo.
    v += Math.sin(TAU * 1760 * t + Math.sin(TAU * 3 * t) * 2) * 0.12 * Math.exp(-Math.max(0, t - 0.3) * 1.6) * Math.min(1, t / 0.3);
    b.add(i, Math.tanh(v * 1.6) * e);
  }
  return b;
}

function hiveIn() {
  const r = rngFor('hive_in'), b = new Buf(1.2);
  const sweep = biquad('bandpass', 300, 1.5);
  let a = 0, c = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const s = Math.min(1, t / 0.35);
    let v = sweep(r() * 2 - 1, 2400 - 2100 * s) * Math.sin(Math.PI * Math.min(1, t / 0.5)) * 0.9;
    a += TAU * 55 / SR;
    c += TAU * 55.9 / SR;
    const drone = (Math.sin(a) + Math.sin(c) + 0.4 * Math.sin(a * 3.01)) * 0.35;
    v += drone * Math.min(1, Math.max(0, t - 0.2) / 0.3) * Math.exp(-Math.max(0, t - 0.7) * 4);
    b.add(i, v);
  }
  return b;
}

function hiveOut() {
  const r = rngFor('hive_out'), b = new Buf(0.7);
  const lp = biquad('lowpass', 3000, 0.7);
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    ph += TAU * (900 * Math.exp(-t * 10) + 60) / SR;
    let v = Math.sin(ph) * env(t, 0.002, 12) * 0.6;
    v += lp(r() * 2 - 1, 3000 * Math.exp(-t * 4) + 200) * env(t, 0.02, 5) * 0.5;
    b.add(i, v);
  }
  return b;
}

function writeWav(file, buf, targetDb = -3) {
  const p = buf.peak();
  const k = p > 0 ? Math.pow(10, targetDb / 20) / p : 1;
  const n = buf.d.length, bytes = n * 2;
  const out = Buffer.alloc(44 + bytes);
  out.write('RIFF', 0); out.writeUInt32LE(36 + bytes, 4); out.write('WAVE', 8);
  out.write('fmt ', 12); out.writeUInt32LE(16, 16); out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22);
  out.writeUInt32LE(SR, 24); out.writeUInt32LE(SR * 2, 28); out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34);
  out.write('data', 36); out.writeUInt32LE(bytes, 40);
  for (let i = 0; i < n; i++) {
    let v = buf.d[i] * k;
    const edge = Math.min(i, n - 1 - i);
    if (edge < 132) v *= edge / 132;
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), 44 + i * 2);
  }
  if (DRY) {
    console.log(`${path.basename(file)}  ${(n / SR).toFixed(2)} s  peak ${p.toFixed(2)}`);
    return;
  }
  fs.writeFileSync(file, out);
  console.log('wrote', path.relative(ROOT, file));
}

const FILES = {
  'brains_squelch.wav': [squelch, -5],
  'brains_blend.wav': [blend, -6],
  'brains_gulp.wav': [gulp, -5],
  'brains_shriek.wav': [shriek, -2],
  'brains_hive_in.wav': [hiveIn, -6],
  'brains_hive_out.wav': [hiveOut, -7],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
