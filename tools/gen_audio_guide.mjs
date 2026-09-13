#!/usr/bin/env node
// tools/gen_audio_guide.mjs — sounds for the medical guide binder.
//
//   node tools/gen_audio_guide.mjs          # writes audio/sfx/guide_*.wav
//   node tools/gen_audio_guide.mjs --check  # render and report only
//
// guide_flip_01..04  a page turning: a papery swish with crinkle
// guide_open         the binder lands in your hands, cover opens, rings rattle, pages riffle
// guide_close        the cover slaps shut, rings clack
//
// Deterministic and dependency-free, in the style of gen_audio.mjs: one seeded PRNG per file.

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

/** RBJ biquad, sweepable. */
function biquad(type, f0, Q) {
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, c = null, cur = -1;
  const coeffs = (f) => {
    f = Math.min(Math.max(f, 20), SR * 0.45);
    const w = TAU * f / SR, cw = Math.cos(w), sw = Math.sin(w), al = sw / (2 * Q);
    let b0, b1, b2, a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
    if (type === 'lp') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; }
    else if (type === 'hp') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; }
    else { b0 = al; b1 = 0; b2 = -al; }
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  };
  return (x, f = f0) => {
    if (Math.abs(f - cur) > 1) { c = coeffs(f); cur = f; }
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

function buffer(seconds) { return new Float32Array(Math.ceil(seconds * SR)); }

/** A single page turn starting at `at` seconds. */
function flip(buf, rnd, at, len, gain, bright = 1) {
  const bp = biquad('bp', 2500, 0.8);
  const hp = biquad('hp', 900, 0.7);
  const lp = biquad('lp', 500, 0.7);
  const start = Math.floor(at * SR), n = Math.floor(len * SR);
  let crinkle = 0;
  for (let i = 0; i < n && start + i < buf.length; i++) {
    const t = i / n;
    // Swish: rises fast, holds, falls; the air "whump" at the end is a low thump.
    const env = Math.pow(Math.sin(Math.PI * Math.min(1, t * 1.15)), 1.6) * (t < 0.87 ? 1 : Math.max(0, 1 - (t - 0.87) / 0.13));
    const sweep = (1400 + 3200 * Math.sin(Math.PI * t)) * bright;
    const white = rnd() * 2 - 1;
    if (rnd() < 0.004 + 0.02 * env) crinkle = 0.8 + rnd() * 0.8;
    crinkle *= 0.93;
    const swish = bp(white, sweep) * env * 1.4;
    const crk = hp(white * crinkle) * 0.5;
    const whump = lp(white) * Math.exp(-Math.pow((t - 0.9) / 0.05, 2)) * 1.8;
    buf[start + i] += (swish + crk + whump) * gain;
  }
}

function thump(buf, rnd, at, freq, len, gain) {
  const lp = biquad('lp', 380, 0.8);
  const start = Math.floor(at * SR), n = Math.floor(len * SR);
  let ph = 0;
  for (let i = 0; i < n && start + i < buf.length; i++) {
    const t = i / SR;
    const env = Math.min(1, i / (0.002 * SR)) * Math.exp(-t * 22);
    ph += TAU * freq * (1 - 0.35 * Math.min(1, t * 12)) / SR;
    const body = Math.sin(ph) * env;
    const knock = lp(rnd() * 2 - 1) * Math.exp(-t * 45) * 1.6;
    buf[start + i] += (body + knock) * gain;
  }
}

/** Metal binder rings: short inharmonic pings. */
function rings(buf, rnd, at, hits, gain) {
  for (let h = 0; h < hits; h++) {
    const start = Math.floor((at + h * (0.018 + rnd() * 0.03)) * SR);
    const f = 2600 + rnd() * 1800;
    const n = Math.floor(0.09 * SR);
    const g = gain * (0.5 + rnd() * 0.5);
    for (let i = 0; i < n && start + i < buf.length; i++) {
      const t = i / SR;
      const env = Math.exp(-t * 60);
      buf[start + i] += (Math.sin(TAU * f * t) + 0.5 * Math.sin(TAU * f * 2.76 * t) + 0.25 * Math.sin(TAU * f * 5.4 * t)) * env * g;
    }
  }
}

function normalise(buf, db) {
  let peak = 0;
  for (const v of buf) peak = Math.max(peak, Math.abs(v));
  const target = Math.pow(10, db / 20);
  if (peak > 0) for (let i = 0; i < buf.length; i++) buf[i] *= target / peak;
  // 3 ms fades so nothing clicks
  const f = Math.floor(0.003 * SR);
  for (let i = 0; i < f; i++) { buf[i] *= i / f; buf[buf.length - 1 - i] *= i / f; }
  return buf;
}

function writeWav(name, buf) {
  const bytes = buf.length * 2;
  const b = Buffer.alloc(44 + bytes);
  b.write('RIFF', 0); b.writeUInt32LE(36 + bytes, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(bytes, 40);
  for (let i = 0; i < buf.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, buf[i])) * 32767), 44 + i * 2);
  const file = path.join(OUT, name + '.wav');
  if (!DRY) { fs.mkdirSync(OUT, { recursive: true }); fs.writeFileSync(file, b); }
  console.log(`  audio/sfx/${name}.wav  ${(buf.length / SR).toFixed(2)}s  ${(b.length / 1024).toFixed(0)} KB`);
}

const SOUNDS = {};
for (let v = 1; v <= 4; v++) {
  SOUNDS[`guide_flip_0${v}`] = (rnd) => {
    const buf = buffer(0.42);
    flip(buf, rnd, 0.0, 0.3 + rnd() * 0.08, 1, 0.85 + rnd() * 0.3);
    return normalise(buf, -9);
  };
}
SOUNDS.guide_open = (rnd) => {
  const buf = buffer(0.95);
  thump(buf, rnd, 0.0, 95, 0.3, 1.0);
  rings(buf, rnd, 0.02, 3, 0.12);
  flip(buf, rnd, 0.14, 0.34, 0.8, 0.7);     // cover swings open
  for (let i = 0; i < 5; i++) flip(buf, rnd, 0.42 + i * 0.07, 0.12, 0.35 * (1 - i * 0.12), 1.2);   // riffle
  return normalise(buf, -6);
};
SOUNDS.guide_close = (rnd) => {
  const buf = buffer(0.55);
  flip(buf, rnd, 0.0, 0.16, 0.6, 0.8);
  thump(buf, rnd, 0.13, 80, 0.35, 1.0);
  rings(buf, rnd, 0.14, 4, 0.18);
  return normalise(buf, -6);
};

console.log(DRY ? 'guide audio (check only):' : 'guide audio:');
for (const [name, fn] of Object.entries(SOUNDS)) writeWav(name, fn(mulberry32(seedOf(name))));
