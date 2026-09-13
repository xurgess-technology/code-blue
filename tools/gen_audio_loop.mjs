#!/usr/bin/env node
// tools/gen_audio_loop.mjs: offline synth for the shift loop (phone, paramedics, clock out).
//
//   node tools/gen_audio_loop.mjs          # write audio/sfx/loop_*.wav
//   node tools/gen_audio_loop.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   loop_ring      the break-room phone: an old electromechanical bell, two trills (about 2 s)
//   loop_pickup    lifting the handset: a plastic knock and the hook switch clicking
//   loop_hangup    the handset dropped back on its cradle
//   loop_gurney    a gurney being wheeled: casters rattling over tiles (about 1.2 s)
//   loop_siren     a distant ambulance siren winding down as it pulls into the bay
//   loop_clockout  the time clock stamping a card, then a short two-note chime

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
function strike(b, at, f0, ratios, decays, amps, gain, maxT = 3) {
  const i0 = Math.round(at * SR);
  const phs = ratios.map(() => 0);
  for (let i = i0; i < b.d.length; i++) {
    const t = (i - i0) / SR;
    if (t > maxT) break;
    let v = 0;
    for (let k = 0; k < ratios.length; k++) {
      phs[k] += TAU * f0 * ratios[k] / SR;
      v += Math.sin(phs[k]) * amps[k] * Math.exp(-t * decays[k]);
    }
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

// The bell: a clapper hitting two small bells 22 times a second, for two trills.
function ring() {
  const b = new Buf(2.2);
  for (const [start, len] of [[0.0, 0.75], [1.05, 0.75]]) {
    const hits = Math.round(len * 22);
    for (let k = 0; k < hits; k++) {
      const at = start + k / 22;
      const f = k % 2 === 0 ? 1180 : 1245;
      strike(b, at, f, [1, 2.32, 4.1, 6.3], [9, 13, 20, 30], [0.6, 0.35, 0.18, 0.08], 0.32, 0.5);
    }
  }
  // The bell housing buzzes a little under the ring.
  const bp = biquad('bandpass', 2400, 3);
  const r = rngFor('ring');
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const on = (t < 0.8) || (t > 1.05 && t < 1.85);
    if (on) b.add(i, bp(r() * 2 - 1) * 0.05);
  }
  return b;
}

function pickup() {
  const r = rngFor('pickup'), b = new Buf(0.45);
  noiseBurst(b, r, 0.0, 0.08, 70, 1800, 0.8);           // handset knocks the cradle
  strike(b, 0.0, 320, [1, 2.4], [40, 60], [0.5, 0.2], 0.5);
  noiseBurst(b, r, 0.14, 0.02, 300, 6000, 0.5);           // hook switch
  strike(b, 0.14, 2900, [1, 1.7], [120, 160], [0.4, 0.2], 0.4);
  // Line noise as the handset comes up.
  const bp = biquad('bandpass', 1200, 1.2);
  for (let i = Math.round(0.18 * SR); i < b.d.length; i++) {
    const t = i / SR - 0.18;
    b.add(i, bp(r() * 2 - 1) * 0.08 * Math.exp(-t * 6));
  }
  return b;
}

function hangup() {
  const r = rngFor('hangup'), b = new Buf(0.4);
  noiseBurst(b, r, 0.0, 0.12, 50, 1200, 1.0);
  strike(b, 0.0, 240, [1, 2.1, 3.7], [35, 50, 70], [0.6, 0.3, 0.1], 0.6);
  strike(b, 0.01, 1150, [1, 2.32], [30, 45], [0.2, 0.1], 0.3);   // the bell answers faintly
  return b;
}

// Casters over tile joints: a low roll, regular clacks and a loose rattle.
function gurney() {
  const r = rngFor('gurney'), b = new Buf(1.2);
  const lp = biquad('lowpass', 260, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    b.add(i, lp(r() * 2 - 1) * 0.35 * (0.8 + 0.2 * Math.sin(TAU * 3.1 * t)));
  }
  for (let k = 0; k < 6; k++) {
    const at = 0.05 + k * 0.2 + r() * 0.015;
    noiseBurst(b, r, at, 0.05, 90, 1600, 0.5);
    strike(b, at, 520 + r() * 60, [1, 2.6], [60, 90], [0.3, 0.15], 0.25);
  }
  for (let k = 0; k < 14; k++) {
    strike(b, r() * 1.1, 1900 + r() * 1400, [1, 2.2], [90, 130], [0.25, 0.1], 0.12);
  }
  return b;
}

// A two-tone wail, low-passed like it is outside, pitch sagging as the vehicle slows.
function siren() {
  const b = new Buf(3.0);
  const lp = biquad('lowpass', 1500, 0.7);
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const sweep = 0.5 + 0.5 * Math.sin(TAU * 0.9 * t);
    const sag = 1.0 - 0.28 * Math.min(1, t / 3.0);
    const f = (640 + 420 * sweep) * sag;
    ph += TAU * f / SR;
    const v = Math.sin(ph) * 0.6 + Math.sin(ph * 2) * 0.25 + Math.sin(ph * 3) * 0.1;
    const env = Math.min(1, t / 0.25) * Math.exp(-Math.max(0, t - 1.8) * 2.2);
    b.add(i, lp(v) * env * 0.6);
  }
  return b;
}

function clockout() {
  const r = rngFor('clockout'), b = new Buf(1.1);
  noiseBurst(b, r, 0.0, 0.1, 55, 900, 1.0);                // the stamp
  strike(b, 0.0, 150, [1, 2.2, 3.5], [30, 45, 60], [0.8, 0.3, 0.1], 0.7);
  noiseBurst(b, r, 0.06, 0.03, 200, 5000, 0.35);           // the card's edge
  strike(b, 0.32, 880, [1, 2.0, 3.0], [5, 8, 12], [0.5, 0.15, 0.06], 0.45);
  strike(b, 0.52, 1318.5, [1, 2.0, 3.0], [4, 7, 11], [0.5, 0.15, 0.06], 0.45);
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
  'loop_ring.wav': [ring, -4],
  'loop_pickup.wav': [pickup, -5],
  'loop_hangup.wav': [hangup, -5],
  'loop_gurney.wav': [gurney, -8],
  'loop_siren.wav': [siren, -6],
  'loop_clockout.wav': [clockout, -4],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
