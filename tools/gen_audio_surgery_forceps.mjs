#!/usr/bin/env node
// tools/gen_audio_surgery_forceps.mjs — sounds for the forceps (bullet removal) minigame.
//
//   node tools/gen_audio_surgery_forceps.mjs          # write audio/sfx/surgery_forceps_*.wav
//   node tools/gen_audio_surgery_forceps.mjs --check  # render + report, do not write
//
// Same approach as tools/gen_audio.mjs: dependency-free, one seeded PRNG stream per file,
// 16-bit mono PCM, byte-identical on every run.
//
// Cues (Audio.play name -> files):
//   surgery_forceps_squelch  _01.._04  wet squelch while the tips move in the wound
//   surgery_forceps_scrape   _01.._03  sharp flinch: gritty scrape on tissue plus a wet squish
//   surgery_forceps_click              the forceps snapping shut on the slug
//   surgery_forceps_clink              the bullet dropping into a steel kidney dish

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
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, c = null, cur = -1;
  const coeffs = (f) => {
    f = Math.min(Math.max(f, 10), SR * 0.45);
    const w0 = (TAU * f) / SR, cw = Math.cos(w0), sw = Math.sin(w0), al = sw / (2 * Q);
    let b0, b1, b2; const a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; }
    else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; }
    else { b0 = al; b1 = 0; b2 = -al; }
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  };
  return (x, f = f0) => {
    if (Math.abs(f - cur) > 0.5) { c = coeffs(f); cur = f; }
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

const buf = (sec) => new Float32Array(Math.ceil(sec * SR));
function add(dst, src, at = 0, gain = 1) {
  const o = Math.round(at * SR);
  for (let i = 0; i < src.length && o + i < dst.length; i++) if (o + i >= 0) dst[o + i] += src[i] * gain;
}
function normalize(b, db) {
  let p = 0;
  for (const v of b) p = Math.max(p, Math.abs(v));
  const g = p > 0 ? Math.pow(10, db / 20) / p : 1;
  for (let i = 0; i < b.length; i++) b[i] *= g;
  const fade = Math.min(b.length, Math.round(0.004 * SR));
  for (let i = 0; i < fade; i++) b[b.length - 1 - i] *= i / fade;
  return b;
}

/** A wet blip: a sine whose pitch drops fast, like a bubble popping in fluid. */
function blip(r, dur, f0, f1, vol) {
  const b = buf(dur);
  let p = 0;
  for (let i = 0; i < b.length; i++) {
    const t = i / b.length;
    const f = f0 * Math.pow(f1 / f0, t);
    p += f / SR;
    b[i] = Math.sin(TAU * p) * vol * Math.pow(1 - t, 2) * Math.min(1, i / (0.002 * SR));
  }
  return b;
}

/** Filtered noise with a sweeping band. */
function swoosh(r, dur, type, f0, f1, Q, attack, vol, shape = 2) {
  const b = buf(dur);
  const flt = biquad(type, f0, Q);
  for (let i = 0; i < b.length; i++) {
    const t = i / b.length;
    const env = Math.min(1, i / Math.max(1, attack * SR)) * Math.pow(1 - t, shape);
    b[i] = flt((r() * 2 - 1) * env * vol, f0 * Math.pow(f1 / f0, t));
  }
  return b;
}

function squelch(name) {
  const r = rngFor(name);
  const dur = r.range(0.16, 0.26);
  const out = buf(dur + 0.05);
  add(out, swoosh(r, dur, 'bandpass', r.range(700, 1000), r.range(220, 320), 3.5, 0.02, 0.9, 1.6));
  add(out, swoosh(r, dur * 0.8, 'lowpass', 500, 180, 0.9, 0.01, 0.5), 0.01);
  const pops = 3 + Math.floor(r() * 4);
  for (let k = 0; k < pops; k++) {
    add(out, blip(r, r.range(0.012, 0.03), r.range(500, 1100), r.range(150, 260), r.range(0.3, 0.7)), r.range(0, dur * 0.8));
  }
  return normalize(out, -9);
}

function scrape(name) {
  const r = rngFor(name);
  const out = buf(0.42);
  // gritty rasp: several quick bandpassed grains
  const grains = 7 + Math.floor(r() * 5);
  for (let k = 0; k < grains; k++) {
    add(out, swoosh(r, r.range(0.02, 0.05), 'bandpass', r.range(2600, 4200), r.range(1800, 2600), 6, 0.002, 1.0, 1),
      r.range(0, 0.16), r.range(0.4, 1.0));
  }
  add(out, swoosh(r, 0.22, 'bandpass', 3200, 1500, 2.0, 0.003, 0.7, 3));
  // wet squish under it
  add(out, swoosh(r, 0.25, 'lowpass', 900, 160, 1.2, 0.004, 0.9, 2), 0.01);
  add(out, blip(r, 0.07, 320, 80, 0.8), 0.0);
  // a short metallic squeal from steel on tissue
  add(out, blip(r, 0.09, r.range(1900, 2300), r.range(1500, 1700), 0.25), 0.02);
  return normalize(out, -3);
}

function click(name) {
  const r = rngFor(name);
  const out = buf(0.14);
  const parts = [[3150, 0.03, 0.7], [4870, 0.02, 0.5], [6930, 0.012, 0.35], [2210, 0.05, 0.25]];
  for (const [f, d, v] of parts) {
    const b = buf(d * 3);
    for (let i = 0; i < b.length; i++) b[i] = Math.sin((TAU * f * i) / SR) * v * Math.exp(-i / (d * SR));
    add(out, b);
  }
  add(out, swoosh(r, 0.012, 'highpass', 5000, 5000, 0.7, 0.0005, 0.8, 3));
  // the second, softer click of the far jaw a moment later
  const b2 = buf(0.05);
  for (let i = 0; i < b2.length; i++) b2[i] = Math.sin((TAU * 3620 * i) / SR) * 0.35 * Math.exp(-i / (0.012 * SR));
  add(out, b2, 0.018);
  return normalize(out, -6);
}

function clink(name) {
  const r = rngFor(name);
  const out = buf(1.5);
  // inharmonic partials of a thin stainless dish struck by a small lead slug
  const partials = [[1870, 0.9, 0.55], [2990, 0.6, 0.42], [4410, 0.45, 0.3], [5770, 0.3, 0.2], [7650, 0.2, 0.12], [960, 0.35, 0.5]];
  const strike = (at, gain, detune) => {
    const b = buf(1.2);
    for (const [f, v, d] of partials) {
      const fr = f * detune * r.range(0.997, 1.003);
      const ph = r();
      for (let i = 0; i < b.length; i++) {
        const t = i / SR;
        b[i] += Math.sin(TAU * (fr * t + ph)) * v * Math.exp(-t / d) * (1 + 0.15 * Math.sin(TAU * 5.3 * t));
      }
    }
    add(b, swoosh(r, 0.008, 'highpass', 3000, 3000, 0.7, 0.0003, 2.5, 2));
    add(out, b, at, gain);
  };
  strike(0.0, 1.0, 1.0);
  strike(0.11, 0.38, 1.004);
  strike(0.19, 0.16, 0.998);
  strike(0.24, 0.07, 1.002);
  return normalize(out, -5);
}

function writeWav(file, data) {
  const n = data.length, bytes = n * 2;
  const b = Buffer.alloc(44 + bytes);
  b.write('RIFF', 0); b.writeUInt32LE(36 + bytes, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(bytes, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, data[i])) * 32767), 44 + i * 2);
  if (!DRY) fs.writeFileSync(file, b);
  return b.length;
}

const jobs = [];
for (let i = 1; i <= 4; i++) jobs.push([`surgery_forceps_squelch_0${i}`, squelch]);
for (let i = 1; i <= 3; i++) jobs.push([`surgery_forceps_scrape_0${i}`, scrape]);
jobs.push(['surgery_forceps_click', click]);
jobs.push(['surgery_forceps_clink', clink]);

if (!DRY) fs.mkdirSync(OUT, { recursive: true });
for (const [name, fn] of jobs) {
  const data = fn(name);
  const bytes = writeWav(path.join(OUT, name + '.wav'), data);
  console.log(`${DRY ? 'rendered' : 'wrote'} audio/sfx/${name}.wav  ${(data.length / SR).toFixed(2)}s  ${bytes} bytes`);
}
