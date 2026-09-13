#!/usr/bin/env node
// tools/gen_audio_dev.mjs: offline synth for the dev room sounds.
//
//   node tools/gen_audio_dev.mjs          # write audio/sfx/dev_*.wav
//   node tools/gen_audio_dev.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   dev_zap_01/_02   the dev gun's kill shot: a bright falling laser zap with a crackle
//   dev_thump        the knock-down shot: a low pneumatic whump
//   dev_defib        a defibrillator charging whine and the thump (the secret code on the menu)

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

function zap(variant) {
  const r = rngFor('zap' + variant), b = new Buf(0.42);
  const f0 = variant === 1 ? 2600 : 2200, f1 = variant === 1 ? 180 : 140;
  let ph = 0, ph2 = 0;
  const lp = biquad('lowpass', 6000, 0.7);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const k = Math.min(1, t / 0.28);
    const f = f0 * Math.pow(f1 / f0, Math.pow(k, 0.6));
    ph += TAU * f / SR;
    ph2 += TAU * f * 1.502 / SR;
    const env = Math.min(1, t / 0.003) * Math.exp(-t * 9.0);
    // Square-ish body plus a detuned partner, then a crackle of noise that fades faster.
    const body = Math.tanh(Math.sin(ph) * 3.0) * 0.6 + Math.sin(ph2) * 0.25;
    const crackle = (r() * 2 - 1) * Math.exp(-t * 28.0) * 0.6;
    b.add(i, lp(body * env + crackle));
  }
  return b;
}

function thump() {
  const r = rngFor('thump'), b = new Buf(0.55);
  let ph = 0;
  const lp = biquad('lowpass', 900, 0.8);
  const bp = biquad('bandpass', 1400, 1.2);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const f = 60 + 160 * Math.exp(-t * 30.0);
    ph += TAU * f / SR;
    const env = Math.min(1, t / 0.004) * Math.exp(-t * 8.0);
    const air = lp((r() * 2 - 1)) * Math.exp(-t * 14.0) * 0.8;
    const hiss = bp(r() * 2 - 1) * Math.exp(-t * 40.0) * 0.4;
    b.add(i, Math.sin(ph) * env * 1.1 + air + hiss);
  }
  return b;
}

function defib() {
  const r = rngFor('defib'), b = new Buf(1.6);
  let ph = 0, ph2 = 0;
  const charge = 1.05;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t < charge) {
      // The capacitor whine climbs and gets louder.
      const k = t / charge;
      const f = 900 + 3200 * k * k;
      ph += TAU * f / SR;
      const env = Math.min(1, t / 0.05) * (0.15 + 0.35 * k);
      b.add(i, Math.sin(ph) * env + Math.sin(ph * 2.01) * env * 0.2);
    } else {
      const tt = t - charge;
      const f = 50 + 120 * Math.exp(-tt * 25.0);
      ph2 += TAU * f / SR;
      const env = Math.min(1, tt / 0.003) * Math.exp(-tt * 6.0);
      const snap = (r() * 2 - 1) * Math.exp(-tt * 60.0) * 0.9;
      b.add(i, Math.sin(ph2) * env * 1.2 + snap);
    }
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
  'dev_zap_01.wav': () => zap(1),
  'dev_zap_02.wav': () => zap(2),
  'dev_thump.wav': () => thump(),
  'dev_defib.wav': () => defib(),
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, build] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), name.includes('defib') ? -4 : -3);
}
