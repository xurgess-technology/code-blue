#!/usr/bin/env node
// tools/gen_audio_downed.mjs: offline synth for the downed players, carrying and stitches.
//
//   node tools/gen_audio_downed.mjs          # write audio/sfx/downed_*.wav
//   node tools/gen_audio_downed.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   downed_fall        a body hitting the floor: a heavy low thud and cloth
//   downed_call_01/_02 a downed player bangs on the floor for help: three hollow knocks
//   downed_lift        hoisting someone over the shoulder: cloth rustle and a grunt-like thump
//   downed_stitch_01/_02  the needle through skin and the thread pulled tight: a tick and a zip
//   downed_tug         a bad stitch tearing: a wet ragged rip

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
  return mulberry32(h >>> 0);
}

function biquad(type, f0, Q) {
  let b0, b1, b2, a1, a2, x1 = 0, x2 = 0, y1 = 0, y2 = 0, cur = -1;
  const set = (f) => {
    const w = TAU * Math.min(f, SR * 0.45) / SR, cw = Math.cos(w), al = Math.sin(w) / (2 * Q);
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

function thud(b, r, at, f0, decay, gain) {
  let ph = 0;
  const lp = biquad('lowpass', 700, 0.7);
  const start = Math.round(at * SR);
  for (let i = start; i < b.d.length; i++) {
    const t = (i - start) / SR;
    if (t > 0.6) break;
    const f = f0 + f0 * 1.6 * Math.exp(-t * 35.0);
    ph += TAU * f / SR;
    const env = Math.min(1, t / 0.003) * Math.exp(-t * decay);
    b.add(i, (Math.sin(ph) * env + lp(r() * 2 - 1) * Math.exp(-t * 30.0) * 0.5) * gain);
  }
}

function fall() {
  const r = rngFor('fall'), b = new Buf(0.9);
  thud(b, r, 0.0, 55, 9.0, 1.0);
  thud(b, r, 0.11, 80, 16.0, 0.45);
  const bp = biquad('bandpass', 2200, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    b.add(i, bp(r() * 2 - 1) * Math.exp(-t * 7.0) * 0.25);
  }
  return b;
}

function call(variant) {
  const r = rngFor('call' + variant), b = new Buf(1.1);
  const gaps = variant === 1 ? [0.0, 0.26, 0.5] : [0.0, 0.2, 0.48];
  for (const g of gaps) thud(b, r, g, variant === 1 ? 120 : 105, 22.0, 0.9);
  return b;
}

function lift() {
  const r = rngFor('lift'), b = new Buf(0.8);
  const bp = biquad('bandpass', 1600, 0.6);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    // Two swells of rustle.
    const env = Math.exp(-Math.pow((t - 0.12) / 0.08, 2)) + 0.7 * Math.exp(-Math.pow((t - 0.42) / 0.1, 2));
    b.add(i, bp(r() * 2 - 1) * env * 0.5);
  }
  thud(b, r, 0.36, 70, 12.0, 0.7);
  return b;
}

function stitch(variant) {
  const r = rngFor('stitch' + variant), b = new Buf(0.5);
  const hp = biquad('highpass', 3000, 0.7);
  const bp = biquad('bandpass', 2400, 2.0);
  const tick = 0.0, zip0 = variant === 1 ? 0.09 : 0.12, zipLen = variant === 1 ? 0.22 : 0.26;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    let v = 0;
    if (t - tick < 0.02) v += hp(r() * 2 - 1) * Math.exp(-(t - tick) * 300.0) * 1.2;
    if (t > zip0 && t < zip0 + zipLen) {
      const k = (t - zip0) / zipLen;
      const f = 1400 + 2600 * k;
      // A grainy rising zip: filtered noise gated by a fast buzz.
      const gate = 0.5 + 0.5 * Math.sin(TAU * (90 + 60 * k) * (t - zip0));
      v += bp(r() * 2 - 1, f) * gate * Math.sin(Math.PI * k) * 0.9;
    }
    b.add(i, v);
  }
  return b;
}

function tug() {
  const r = rngFor('tug'), b = new Buf(0.45);
  const lp = biquad('lowpass', 1800, 0.9);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const crackle = (r() < 0.08 ? (r() * 2 - 1) : 0) * Math.exp(-t * 9.0);
    const body = lp(r() * 2 - 1) * Math.min(1, t / 0.01) * Math.exp(-t * 11.0);
    b.add(i, body * 0.8 + crackle * 0.9);
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
  'downed_fall.wav': [() => fall(), -3],
  'downed_call_01.wav': [() => call(1), -5],
  'downed_call_02.wav': [() => call(2), -5],
  'downed_lift.wav': [() => lift(), -6],
  'downed_stitch_01.wav': [() => stitch(1), -8],
  'downed_stitch_02.wav': [() => stitch(2), -8],
  'downed_tug.wav': [() => tug(), -6],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
