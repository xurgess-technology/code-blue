#!/usr/bin/env node
// tools/gen_audio_containers.mjs: offline synth for the searchable-container sounds.
//
//   node tools/gen_audio_containers.mjs          # write audio/sfx/containers_*.wav
//   node tools/gen_audio_containers.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so
// re-running produces byte-identical output.
//
//   containers_fridge_open    seal pop, a short hinge creak
//   containers_fridge_close   rubber-seal thump
//   containers_fridge_hum     2 s sample-exact compressor hum loop (looped by med_fridge.gd)
//   containers_click          relay click of the interior light
//   containers_drawer_open_01/_02   steel runners rolling out, soft stop
//   containers_drawer_close_01/_02  runners rolling in, firmer clack
//   containers_zip_01/_02     zipper teeth
//   containers_thunk          soft fabric/lid thunk

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

function biquad(type, f0, Q) {
  let b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0, cur = -1;
  const set = (f) => {
    const w = TAU * Math.min(f, SR * 0.45) / SR, cw = Math.cos(w), al = Math.sin(w) / (2 * Q);
    let n0, n1, n2, d0, d1, d2;
    if (type === 'lowpass') { n0 = (1 - cw) / 2; n1 = 1 - cw; n2 = n0; }
    else if (type === 'highpass') { n0 = (1 + cw) / 2; n1 = -(1 + cw); n2 = n0; }
    else { n0 = al; n1 = 0; n2 = -al; }
    d0 = 1 + al; d1 = -2 * cw; d2 = 1 - al;
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

// Decaying filtered noise burst starting at t seconds.
function noise(buf, rnd, t, { dur, vol, freq, endFreq = 0, q = 1, type = 'bandpass', attack = 0.002 }) {
  const f = biquad(type, freq, q);
  const s = Math.round(t * SR), n = Math.round(dur * SR), a = Math.max(1, attack * SR);
  for (let i = 0; i < n; i++) {
    const env = (i < a ? i / a : 1) * Math.pow(0.001, i / n);
    const fr = endFreq ? freq * Math.pow(endFreq / freq, i / n) : undefined;
    buf.add(s + i, f((rnd() * 2 - 1) * env * vol, fr));
  }
}
// Decaying sine with a pitch glide.
function tone(buf, t, { dur, vol, freq, end = 0, attack = 0.002 }) {
  const s = Math.round(t * SR), n = Math.round(dur * SR), a = Math.max(1, attack * SR);
  let p = 0;
  for (let i = 0; i < n; i++) {
    const fr = end ? freq * Math.pow(end / freq, i / n) : freq;
    p += fr / SR;
    const env = (i < a ? i / a : 1) * Math.pow(0.001, i / n);
    buf.add(s + i, Math.sin(TAU * p) * env * vol);
  }
}

function fridgeOpen() {
  const r = rngFor('fridge_open'), b = new Buf(0.9);
  // The seal lets go: a low suck and a pop.
  noise(b, r, 0.0, { dur: 0.09, vol: 0.9, freq: 260, endFreq: 900, q: 0.8 });
  tone(b, 0.01, { dur: 0.08, vol: 0.5, freq: 180, end: 90 });
  // A dry hinge creak: bursts of narrow resonant noise with a wobbling centre.
  for (let k = 0; k < 14; k++) {
    const t = 0.12 + k * 0.028 + r.range(-0.004, 0.004);
    noise(b, r, t, { dur: 0.03, vol: 0.18 * (1 - k / 16), freq: 1300 + 250 * Math.sin(k * 0.9), q: 14 });
  }
  // Cold air rush.
  noise(b, r, 0.05, { dur: 0.6, vol: 0.12, freq: 3000, endFreq: 1200, q: 0.5, attack: 0.08 });
  return b;
}
function fridgeClose() {
  const r = rngFor('fridge_close'), b = new Buf(0.6);
  noise(b, r, 0.0, { dur: 0.05, vol: 0.25, freq: 2000, q: 0.7 });
  tone(b, 0.02, { dur: 0.22, vol: 0.9, freq: 110, end: 55 });
  noise(b, r, 0.02, { dur: 0.16, vol: 0.7, freq: 180, q: 0.9, type: 'lowpass' });
  // Bottles on the shelves chink once.
  tone(b, 0.05, { dur: 0.12, vol: 0.05, freq: 3150 });
  tone(b, 0.07, { dur: 0.1, vol: 0.04, freq: 3710 });
  return b;
}
function fridgeHum() {
  // Every partial completes a whole number of cycles in 2 s, and the flutter is
  // one cycle long, so the buffer loops without a seam.
  const sec = 2, n = sec * SR, b = new Buf(sec);
  const parts = [[60, 0.5], [120, 0.32], [180, 0.12], [240, 0.08], [300, 0.03], [420, 0.02]];
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    let v = 0;
    for (const [f, a] of parts) v += Math.sin(TAU * f * t + f * 0.01) * a;
    const flutter = 1 + 0.12 * Math.sin(TAU * 0.5 * t) + 0.05 * Math.sin(TAU * 3.5 * t);
    b.d[i] = Math.tanh(v * 1.4) * flutter * 0.6;
  }
  return b;
}
function click() {
  const r = rngFor('click'), b = new Buf(0.2);
  noise(b, r, 0.0, { dur: 0.012, vol: 0.9, freq: 4200, q: 1.5 });
  noise(b, r, 0.03, { dur: 0.01, vol: 0.4, freq: 3000, q: 2 });
  tone(b, 0.0, { dur: 0.03, vol: 0.2, freq: 1800 });
  return b;
}
function drawer(variant, closing) {
  const r = rngFor(`drawer_${closing ? 'close' : 'open'}_${variant}`), b = new Buf(0.7);
  const len = closing ? 0.26 : 0.34;
  // Ball-bearing runners: a stream of tiny ticks through a bright band, over a rolling rumble.
  noise(b, r, 0.0, { dur: len, vol: 0.22, freq: 900 + variant * 120, endFreq: closing ? 1400 : 700, q: 1.2, attack: 0.03 });
  let t = 0.01;
  while (t < len) {
    noise(b, r, t, { dur: 0.008, vol: r.range(0.08, 0.2), freq: r.range(3500, 6500), q: 3 });
    t += r.range(0.009, 0.022);
  }
  // The stop: a soft bump when opening, a steel clack when shutting.
  if (closing) {
    noise(b, r, len, { dur: 0.05, vol: 0.9, freq: 1800, q: 1.2 });
    tone(b, len, { dur: 0.18, vol: 0.5, freq: 240 + variant * 15, end: 160 });
    tone(b, len + 0.004, { dur: 0.25, vol: 0.08, freq: 1760 + variant * 90 });
  } else {
    noise(b, r, len, { dur: 0.06, vol: 0.45, freq: 500, q: 0.9 });
    tone(b, len, { dur: 0.12, vol: 0.25, freq: 170, end: 120 });
    tone(b, len + 0.01, { dur: 0.2, vol: 0.05, freq: 2210 + variant * 70 });
  }
  return b;
}
function zip(variant) {
  const r = rngFor(`zip_${variant}`), b = new Buf(0.7);
  const len = 0.42 + variant * 0.04;
  let t = 0.0, k = 0;
  while (t < len) {
    const prog = t / len;
    noise(b, r, t, { dur: 0.006, vol: r.range(0.35, 0.6), freq: 2600 + prog * 1800 + r.range(-300, 300), q: 2.5 });
    // Teeth come faster as the pull speeds up, then slow at the end.
    const speed = Math.sin(Math.PI * Math.min(1, prog * 1.1)) + 0.25;
    t += 0.011 / speed + r.range(0, 0.002);
    k++;
  }
  noise(b, r, 0.0, { dur: len, vol: 0.12, freq: 5000, q: 0.7, attack: 0.05 });
  // Tag flick at the end.
  noise(b, r, len + 0.01, { dur: 0.02, vol: 0.3, freq: 3500, q: 2 });
  return b;
}
function thunk() {
  const r = rngFor('thunk'), b = new Buf(0.5);
  noise(b, r, 0.0, { dur: 0.14, vol: 0.9, freq: 220, q: 0.8, type: 'lowpass' });
  tone(b, 0.0, { dur: 0.16, vol: 0.6, freq: 130, end: 70 });
  noise(b, r, 0.0, { dur: 0.05, vol: 0.12, freq: 1600, q: 0.8 });
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
    // 3 ms fade at the ends so one-shots never click (the loop is left untouched).
    if (!file.includes('hum')) {
      const edge = Math.min(i, n - 1 - i);
      if (edge < 132) v *= edge / 132;
    }
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), 44 + i * 2);
  }
  if (!DRY) fs.writeFileSync(file, out);
  console.log(`${DRY ? '[check] ' : ''}${path.basename(file).padEnd(34)} ${(n / SR).toFixed(2)} s  ${out.length} bytes`);
}

const FILES = {
  'containers_fridge_open.wav': () => fridgeOpen(),
  'containers_fridge_close.wav': () => fridgeClose(),
  'containers_fridge_hum.wav': () => fridgeHum(),
  'containers_click.wav': () => click(),
  'containers_drawer_open_01.wav': () => drawer(1, false),
  'containers_drawer_open_02.wav': () => drawer(2, false),
  'containers_drawer_close_01.wav': () => drawer(1, true),
  'containers_drawer_close_02.wav': () => drawer(2, true),
  'containers_zip_01.wav': () => zip(1),
  'containers_zip_02.wav': () => zip(2),
  'containers_thunk.wav': () => thunk(),
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, build] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), name.includes('hum') ? -6 : -3);
}
