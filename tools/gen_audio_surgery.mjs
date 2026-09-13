#!/usr/bin/env node
// tools/gen_audio_surgery.mjs — offline synthesiser for the surgery minigames' sounds.
//
//   node tools/gen_audio_surgery.mjs          # write audio/sfx/surgery_*.wav
//   node tools/gen_audio_surgery.mjs --check  # render + report, do not write
//
// Same deterministic, dependency-free style as tools/gen_audio.mjs (which this does not
// import, so the two generators can never break each other). Cues:
//   surgery_draw_0N    plunger pulling back: a rubbery squeak
//   surgery_click      syringe plunger / cap click
//   surgery_needle     needle going in: a tiny tick and a soft pop
//   surgery_inject     fluid pushing through: a short hiss
//   surgery_tear_0N    gauze tearing off the roll
//   surgery_pack_0N    pressing gauze into a wet wound
//   surgery_swish_0N   a turn of bandage wrapping around
//   surgery_beep       the OR monitor, calm
//   surgery_beep_low   the monitor when vitals sag: lower, harsher
//   surgery_beep_crit  the monitor when vitals are critical: a double alarm pip
//   surgery_botch      a mistake: a short sour buzz
//   surgery_stir       the patient jerking on the table: a muffled groan and a rattle
//   surgery_done       step complete

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 44100;
const TAU = Math.PI * 2;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'audio', 'sfx');
const DRY = process.argv.includes('--check');
const TARGET_DB = -3;

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
  const r = mulberry32(seedOf('surgery:' + name));
  r.range = (a, b) => a + r() * (b - a);
  return r;
}

function biquad(type, f0, Q) {
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, c = null, cur = -1;
  const coeffs = (f) => {
    f = Math.min(Math.max(f, 10), SR * 0.45);
    const w0 = (TAU * f) / SR, cw = Math.cos(w0), sw = Math.sin(w0), al = sw / (2 * Math.max(1e-4, Q));
    let b0, b1, b2, a0, a1, a2;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    else { b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  };
  return (x, f = f0) => {
    if (c === null || Math.abs(f - cur) > 0.5) { c = coeffs(f); cur = f; }
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

/** Attack/decay envelope; `shape` 0..1 is where the peak sits within the duration. */
function env(i, n, attack, curve = 4) {
  const a = Math.max(1, attack * SR);
  if (i < a) return i / a;
  const k = (i - a) / Math.max(1, n - a);
  return Math.pow(Math.max(0, 1 - k), curve);
}

class Buf {
  constructor(sec) { this.d = new Float32Array(Math.ceil(sec * SR)); }
  add(t, arr, g = 1) {
    const s = Math.round(t * SR);
    for (let i = 0; i < arr.length && s + i < this.d.length; i++) if (s + i >= 0) this.d[s + i] += arr[i] * g;
  }
}

function tone({ f, f2 = f, dur, type = 'sine', attack = 0.004, curve = 3, lp = 0 }) {
  const n = Math.ceil(dur * SR), out = new Float32Array(n);
  const flt = lp ? biquad('lowpass', lp, 0.8) : null;
  let p = 0;
  for (let i = 0; i < n; i++) {
    const fr = f * Math.pow(f2 / f, i / n);
    let v;
    if (type === 'square') v = p < 0.5 ? 1 : -1;
    else if (type === 'saw') v = 2 * p - 1;
    else if (type === 'tri') v = 1 - 4 * Math.abs(p - 0.5);
    else v = Math.sin(TAU * p);
    p += fr / SR; if (p >= 1) p -= 1;
    v *= env(i, n, attack, curve);
    out[i] = flt ? flt(v) : v;
  }
  return out;
}

function noise({ dur, f, f2 = f, q = 1, type = 'bandpass', attack = 0.003, curve = 3, rnd, am = null }) {
  const n = Math.ceil(dur * SR), out = new Float32Array(n);
  const flt = biquad(type, f, q);
  for (let i = 0; i < n; i++) {
    const fr = f * Math.pow(f2 / f, i / n);
    let v = (rnd() * 2 - 1) * env(i, n, attack, curve);
    if (am) v *= am(i / SR, i / n);
    out[i] = flt(v, fr);
  }
  return out;
}

// ------------------------------------------------------------------ cues

function draw(v) {
  const rnd = rngFor('draw' + v), b = new Buf(0.5);
  const base = 520 + v * 60;
  // rubber stopper squeaking against the barrel: a wobbling narrow band
  b.add(0, noise({ dur: 0.32, f: base, f2: base * 1.5, q: 9, attack: 0.03, curve: 1.5, rnd,
    am: (t) => 0.6 + 0.4 * Math.sin(TAU * (28 + v * 4) * t) }), 1.0);
  b.add(0, tone({ f: base, f2: base * 1.45, dur: 0.3, type: 'tri', attack: 0.03, curve: 1.5, lp: 1800 }), 0.12);
  return b;
}

function click() {
  const rnd = rngFor('click'), b = new Buf(0.15);
  b.add(0, noise({ dur: 0.012, f: 4200, type: 'highpass', q: 0.7, rnd, curve: 2 }), 1.0);
  b.add(0.004, tone({ f: 2400, dur: 0.03, type: 'sine', curve: 6 }), 0.25);
  return b;
}

function needle() {
  const rnd = rngFor('needle'), b = new Buf(0.25);
  b.add(0, tone({ f: 3600, f2: 3000, dur: 0.02, curve: 5 }), 0.4);
  b.add(0.015, noise({ dur: 0.06, f: 900, f2: 500, q: 2, rnd, curve: 3 }), 0.8);
  b.add(0.02, tone({ f: 180, f2: 90, dur: 0.07, curve: 4 }), 0.35);
  return b;
}

function inject() {
  const rnd = rngFor('inject'), b = new Buf(0.7);
  b.add(0, noise({ dur: 0.6, f: 2200, f2: 1600, q: 1.2, attack: 0.08, curve: 1.2, rnd }), 0.7);
  b.add(0, noise({ dur: 0.6, f: 300, type: 'lowpass', q: 0.7, attack: 0.1, curve: 1.2, rnd }), 0.3);
  return b;
}

function tear(v) {
  const rnd = rngFor('tear' + v), b = new Buf(0.5);
  // many tiny fibre snaps riding on a dry rip
  const len = 0.22 + v * 0.04;
  b.add(0, noise({ dur: len, f: 2600 + v * 300, f2: 1400, q: 0.9, attack: 0.01, curve: 1.4, rnd,
    am: (t) => 0.35 + 0.65 * (Math.sin(TAU * (60 + v * 13) * t + rnd() * 0.8) > 0.2 ? 1 : 0.3) }), 1.0);
  for (let i = 0; i < 6; i++) {
    b.add(rnd.range(0, len), noise({ dur: 0.008, f: 5000, type: 'highpass', q: 0.7, rnd, curve: 2 }), 0.6);
  }
  return b;
}

function pack(v) {
  const rnd = rngFor('pack' + v), b = new Buf(0.3);
  // a damp press: low thump and a small wet squelch
  b.add(0, tone({ f: 140 + v * 15, f2: 70, dur: 0.09, curve: 3 }), 0.8);
  b.add(0.01, noise({ dur: 0.12, f: 700 + v * 120, f2: 380, q: 3, rnd, curve: 2.5 }), 0.6);
  b.add(0.05, noise({ dur: 0.05, f: 1500, q: 6, rnd, curve: 2 }), 0.25);
  return b;
}

function swish(v) {
  const rnd = rngFor('swish' + v), b = new Buf(0.5);
  const dur = 0.3 + v * 0.03;
  b.add(0, noise({ dur, f: 700 + v * 90, f2: 2300 + v * 150, q: 1.1, attack: dur * 0.45, curve: 2, rnd }), 1.0);
  return b;
}

function beep(kind) {
  const b = new Buf(0.4);
  if (kind === 'calm') {
    b.add(0, tone({ f: 988, dur: 0.11, type: 'sine', attack: 0.003, curve: 1.6 }), 0.9);
    b.add(0, tone({ f: 1976, dur: 0.06, type: 'sine', attack: 0.003, curve: 3 }), 0.08);
  } else if (kind === 'low') {
    b.add(0, tone({ f: 740, dur: 0.14, type: 'tri', attack: 0.003, curve: 1.2 }), 0.9);
    b.add(0, tone({ f: 745, dur: 0.14, type: 'square', attack: 0.003, curve: 1.6, lp: 2000 }), 0.12);
  } else {
    for (const t of [0, 0.13]) {
      b.add(t, tone({ f: 1320, dur: 0.09, type: 'square', attack: 0.002, curve: 1.2, lp: 3200 }), 0.45);
      b.add(t, tone({ f: 1320, dur: 0.09, type: 'sine', attack: 0.002, curve: 1.2 }), 0.5);
    }
  }
  return b;
}

function botch() {
  const b = new Buf(0.45);
  b.add(0, tone({ f: 220, f2: 180, dur: 0.28, type: 'saw', attack: 0.004, curve: 1.5, lp: 900 }), 0.7);
  b.add(0, tone({ f: 233, f2: 190, dur: 0.28, type: 'square', attack: 0.004, curve: 1.5, lp: 700 }), 0.3);
  return b;
}

function stir() {
  const rnd = rngFor('stir'), b = new Buf(0.9);
  // a muffled, voiced groan
  const n = Math.ceil(0.55 * SR), g = new Float32Array(n);
  const flt = biquad('bandpass', 500, 2.5), flt2 = biquad('lowpass', 900, 0.7);
  let p = 0;
  for (let i = 0; i < n; i++) {
    const k = i / n;
    const f = 120 + 40 * Math.sin(Math.PI * k) - 25 * k;
    p += f / SR; if (p >= 1) p -= 1;
    const src = (2 * p - 1) + (rnd() * 2 - 1) * 0.25;
    g[i] = flt2(flt(src, 450 + 300 * Math.sin(Math.PI * k))) * env(i, n, 0.06, 1.3);
  }
  b.add(0, g, 1.6);
  // the table and trays rattling
  for (let i = 0; i < 5; i++) b.add(0.02 + i * 0.045 + rnd() * 0.01, noise({ dur: 0.03, f: 3000, q: 4, rnd, curve: 2 }), 0.35);
  return b;
}

function done() {
  const b = new Buf(0.7);
  b.add(0, tone({ f: 784, dur: 0.14, type: 'tri', curve: 2 }), 0.6);
  b.add(0.11, tone({ f: 1175, dur: 0.3, type: 'tri', curve: 2 }), 0.6);
  return b;
}

// ------------------------------------------------------------------ output

function finish(buf) {
  const d = buf.d;
  let peak = 0, last = 0;
  for (let i = 0; i < d.length; i++) { const a = Math.abs(d[i]); if (a > peak) peak = a; }
  const thr = peak * 0.001;
  for (let i = d.length - 1; i >= 0; i--) if (Math.abs(d[i]) > thr) { last = i; break; }
  const n = Math.min(d.length, last + Math.ceil(0.01 * SR));
  const out = d.slice(0, n);
  const fade = Math.min(Math.ceil(0.004 * SR), n);
  for (let i = 0; i < fade; i++) out[n - 1 - i] *= i / fade;
  const k = peak > 0 ? Math.pow(10, TARGET_DB / 20) / peak : 1;
  for (let i = 0; i < n; i++) out[i] *= k;
  return out;
}

function writeWav(name, data) {
  const bytes = data.length * 2;
  const buf = Buffer.alloc(44 + bytes);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + bytes, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(bytes, 40);
  for (let i = 0; i < data.length; i++) {
    const v = Math.max(-1, Math.min(1, data[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  const file = path.join(OUT, name);
  if (!DRY) fs.writeFileSync(file, buf);
  console.log(`  audio/sfx/${name.padEnd(26)} ${(data.length / SR).toFixed(2)}s  ${(buf.length / 1024).toFixed(0)} KB`);
}

const cues = [];
for (let v = 1; v <= 3; v++) cues.push([`surgery_draw_0${v}.wav`, () => draw(v)]);
cues.push(['surgery_click.wav', click]);
cues.push(['surgery_needle.wav', needle]);
cues.push(['surgery_inject.wav', inject]);
for (let v = 1; v <= 3; v++) cues.push([`surgery_tear_0${v}.wav`, () => tear(v)]);
for (let v = 1; v <= 3; v++) cues.push([`surgery_pack_0${v}.wav`, () => pack(v)]);
for (let v = 1; v <= 4; v++) cues.push([`surgery_swish_0${v}.wav`, () => swish(v)]);
cues.push(['surgery_beep.wav', () => beep('calm')]);
cues.push(['surgery_beep_low.wav', () => beep('low')]);
cues.push(['surgery_beep_crit.wav', () => beep('crit')]);
cues.push(['surgery_botch.wav', botch]);
cues.push(['surgery_stir.wav', stir]);
cues.push(['surgery_done.wav', done]);

if (!DRY) fs.mkdirSync(OUT, { recursive: true });
console.log(DRY ? 'gen_audio_surgery (check only)' : 'gen_audio_surgery');
for (const [name, fn] of cues) writeWav(name, finish(fn()));
