#!/usr/bin/env node
// tools/gen_audio_economy.mjs: offline synth for selling loot and buying gold bars.
//
//   node tools/gen_audio_economy.mjs          # write audio/sfx/economy_*.wav
//   node tools/gen_audio_economy.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   economy_sell       loot into the sell bin: a clattering drop, then a bright till "ka-ching"
//   economy_buy        buying at the shop: a till beep and the cash drawer thunking open
//   economy_bar_01/02  a gold bar landing on the pile: a heavy, ringing metal clunk

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

// A struck metal partial set: inharmonic ratios, each decaying at its own rate.
function strike(b, at, f0, ratios, decays, amps, gain) {
  const i0 = Math.round(at * SR);
  const phs = ratios.map(() => 0);
  for (let i = i0; i < b.d.length; i++) {
    const t = (i - i0) / SR;
    let v = 0;
    for (let k = 0; k < ratios.length; k++) {
      phs[k] += TAU * f0 * ratios[k] / SR;
      v += Math.sin(phs[k]) * amps[k] * Math.exp(-t * decays[k]);
    }
    if (t > 3) break;
    b.add(i, v * gain * Math.min(1, t / 0.0015));
  }
}

function noiseBurst(b, r, at, len, decay, lpF, gain) {
  const lp = biquad('lowpass', lpF, 0.7);
  const i0 = Math.round(at * SR);
  for (let i = 0; i < Math.round(len * SR); i++) {
    const t = i / SR;
    b.add(i0 + i, lp(r() * 2 - 1) * Math.exp(-t * decay) * gain);
  }
}

function sell() {
  const r = rngFor('sell'), b = new Buf(1.25);
  // The loot tumbling into the bin: two dull knocks and a rattle.
  noiseBurst(b, r, 0.0, 0.18, 30, 900, 0.9);
  noiseBurst(b, r, 0.09, 0.14, 38, 1400, 0.5);
  strike(b, 0.02, 180, [1, 2.3, 3.9], [18, 26, 40], [0.6, 0.3, 0.15], 0.6);
  // The till: a quick drawer thunk, then the bell "ching" and a few coins.
  noiseBurst(b, r, 0.3, 0.1, 50, 600, 0.6);
  strike(b, 0.34, 2093, [1, 2.76, 5.4, 8.9], [4.5, 6, 9, 14], [0.7, 0.35, 0.2, 0.1], 0.55);
  strike(b, 0.36, 2637, [1, 2.76, 5.4], [5, 7, 11], [0.5, 0.25, 0.12], 0.4);
  for (let k = 0; k < 5; k++) {
    strike(b, 0.42 + k * 0.045 + r() * 0.02, 3200 + r() * 1800, [1, 2.4], [30, 45], [0.4, 0.2], 0.18);
  }
  return b;
}

function buy() {
  const r = rngFor('buy'), b = new Buf(0.8);
  let ph = 0;
  // Two short till beeps.
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const on = (t < 0.07) || (t > 0.1 && t < 0.17);
    ph += TAU * 1760 / SR;
    if (on) b.add(i, Math.sign(Math.sin(ph)) * 0.18 * Math.min(1, (t % 0.1) / 0.004));
  }
  // The cash drawer: a spring slide and a thunk against the stop.
  noiseBurst(b, r, 0.2, 0.2, 14, 2500, 0.25);
  noiseBurst(b, r, 0.36, 0.12, 45, 500, 0.9);
  strike(b, 0.36, 140, [1, 2.1, 3.3], [22, 30, 45], [0.8, 0.3, 0.15], 0.7);
  strike(b, 0.37, 1450, [1, 2.7], [22, 35], [0.3, 0.15], 0.3);
  return b;
}

function bar(variant) {
  const r = rngFor('bar' + variant), b = new Buf(0.9);
  const f = variant === 1 ? 410 : 455;
  // Heavy: a low thud body, then a ringing, slightly detuned metal tone.
  noiseBurst(b, r, 0.0, 0.08, 60, 700, 1.0);
  strike(b, 0.0, 95, [1, 1.9], [30, 40], [1.0, 0.3], 0.8);
  strike(b, 0.002, f, [1, 2.71, 4.93, 7.6], [7, 10, 15, 22], [0.55, 0.35, 0.22, 0.12], 0.6);
  strike(b, 0.004, f * 1.013, [1, 2.71], [8, 12], [0.35, 0.2], 0.4);
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
  'economy_sell.wav': () => sell(),
  'economy_buy.wav': () => buy(),
  'economy_bar_01.wav': () => bar(1),
  'economy_bar_02.wav': () => bar(2),
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, build] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), name.includes('bar') ? -3 : -4);
}