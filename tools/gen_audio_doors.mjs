#!/usr/bin/env node
// tools/gen_audio_doors.mjs: offline synth for the doors (hinged, automatic, the wing gates).
//
//   node tools/gen_audio_doors.mjs          # write audio/sfx/doors_*.wav
//   node tools/gen_audio_doors.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   doors_hiss       the main entrance's sliding glass doors: a pneumatic hiss and a soft stop
//   doors_heavy      a heavy automatic swing door: motor hum, the leaf groaning, the seal thumping
//   doors_creak_01/02 a hinged door pushed open: a stick-slip hinge creak
//   doors_latch      a hinged door swung shut: the latch clicking home
//   doors_slam       a door slammed or burst open: a hard wooden-steel impact and a rattle
//   doors_locked     a locked wing gate: a dead bolt clunk and a short denied buzz
//   doors_unlock     the wing gates unlocking at clock-in: a solenoid clack and a rising chime
//   doors_jam        a gate motor stuttering: grinding, jerks and a strained whine
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

// Stick-slip friction: short pulses of a resonant body at an irregular, rising-then-falling rate.
function creakInto(b, r, at, len, f0, gain) {
  const bp = biquad('bandpass', f0, 9);
  const bp2 = biquad('bandpass', f0 * 2.7, 7);
  const i0 = Math.round(at * SR);
  let next = 0, amp = 0;
  for (let i = 0; i < Math.round(len * SR); i++) {
    const t = i / SR;
    const u = t / len;
    const rate = 38 + 70 * Math.sin(Math.PI * u) + r() * 8;
    if (t >= next) { next = t + 1 / rate; amp = 0.6 + r() * 0.4; }
    const pulse = amp * Math.exp(-(t - (next - 1 / rate)) * 260);
    const x = (r() * 2 - 1) * pulse;
    const env = Math.min(1, t / 0.03) * Math.min(1, (len - t) / 0.08);
    b.add(i0 + i, (bp(x, f0 * (1 + 0.25 * Math.sin(TAU * 1.3 * t))) * 1.4 + bp2(x) * 0.5) * env * gain);
  }
}

function hiss() {
  const r = rngFor('hiss'), b = new Buf(1.3);
  const hp = biquad('highpass', 1800, 0.7);
  const lp = biquad('lowpass', 7000, 0.7);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const env = Math.min(1, t / 0.12) * Math.exp(-Math.max(0, t - 0.25) * 3.2);
    b.add(i, lp(hp(r() * 2 - 1)) * env * 0.45);
  }
  // The belt motor: a soft whine that slides up.
  let ph = 0;
  for (let i = 0; i < Math.round(0.9 * SR); i++) {
    const t = i / SR;
    ph += TAU * (180 + 90 * Math.min(1, t / 0.5)) / SR;
    b.add(i, (Math.sin(ph) * 0.6 + Math.sin(ph * 2) * 0.2) * 0.12 * Math.sin(Math.PI * t / 0.9));
  }
  noiseBurst(b, r, 0.82, 0.12, 60, 500, 0.5);   // the panels meet their stops
  strike(b, 0.82, 190, [1, 2.3], [40, 60], [0.4, 0.15], 0.25);
  return b;
}

function heavy() {
  const r = rngFor('heavy'), b = new Buf(1.6);
  let ph = 0;
  const lp = biquad('lowpass', 400, 0.8);
  for (let i = 0; i < Math.round(1.25 * SR); i++) {
    const t = i / SR;
    ph += TAU * (62 + 8 * Math.sin(TAU * 0.7 * t)) / SR;
    const env = Math.min(1, t / 0.1) * Math.min(1, (1.25 - t) / 0.2);
    b.add(i, lp(Math.sin(ph) + 0.4 * Math.sin(ph * 3) + (r() * 2 - 1) * 0.3) * env * 0.5);
  }
  creakInto(b, r, 0.15, 0.8, 310, 0.35);
  noiseBurst(b, r, 1.22, 0.2, 30, 260, 0.9);    // the rubber seal and the stop
  strike(b, 1.22, 85, [1, 1.9, 3.1], [14, 22, 35], [0.7, 0.3, 0.12], 0.55);
  return b;
}

function creak(seed, f0) {
  const r = rngFor('creak' + seed), b = new Buf(0.95);
  noiseBurst(b, r, 0.0, 0.03, 250, 3000, 0.35);   // the latch lets go
  strike(b, 0.0, 1850, [1, 1.6], [120, 170], [0.3, 0.12], 0.25);
  creakInto(b, r, 0.05, 0.8, f0, 0.8);
  return b;
}

function latch() {
  const r = rngFor('latch'), b = new Buf(0.5);
  noiseBurst(b, r, 0.0, 0.1, 55, 700, 0.8);           // the leaf reaching the frame
  strike(b, 0.0, 140, [1, 2.2, 3.4], [30, 45, 70], [0.5, 0.2, 0.08], 0.5);
  noiseBurst(b, r, 0.035, 0.02, 400, 7000, 0.45);     // the latch bolt
  strike(b, 0.035, 2400, [1, 1.45, 2.9], [90, 120, 180], [0.5, 0.25, 0.1], 0.45);
  return b;
}

function slam() {
  const r = rngFor('slam'), b = new Buf(1.2);
  noiseBurst(b, r, 0.0, 0.35, 16, 1400, 1.2);
  strike(b, 0.0, 72, [1, 1.8, 2.9, 4.4], [8, 12, 18, 28], [0.9, 0.45, 0.2, 0.08], 0.9, 1.1);
  strike(b, 0.004, 510, [1, 2.4, 3.9], [20, 30, 45], [0.3, 0.15, 0.06], 0.4);
  // Glass and hinges rattling in the frame after the hit.
  for (let k = 0; k < 16; k++) {
    const at = 0.03 + r() * 0.5;
    strike(b, at, 1400 + r() * 2600, [1, 2.1], [80, 120], [0.3, 0.1], 0.18 * Math.exp(-at * 3));
  }
  return b;
}

function locked() {
  const r = rngFor('locked'), b = new Buf(0.8);
  noiseBurst(b, r, 0.0, 0.12, 45, 600, 1.0);
  strike(b, 0.0, 95, [1, 2.05, 3.3], [22, 35, 55], [0.8, 0.35, 0.12], 0.7);
  strike(b, 0.01, 780, [1, 1.52, 2.8], [45, 60, 90], [0.35, 0.2, 0.08], 0.35);   // the bolt in its keeper
  // A short denied buzz from the lock's reader.
  let ph = 0;
  for (let i = Math.round(0.22 * SR); i < Math.round(0.52 * SR); i++) {
    ph += TAU * 185 / SR;
    const sq = Math.sign(Math.sin(ph)) * 0.5 + Math.sin(ph * 3) * 0.2;
    b.add(i, sq * 0.14);
  }
  return b;
}

function unlock() {
  const r = rngFor('unlock'), b = new Buf(1.1);
  noiseBurst(b, r, 0.0, 0.05, 120, 2500, 0.8);                // solenoid
  strike(b, 0.0, 1300, [1, 1.7, 2.9], [60, 90, 140], [0.5, 0.25, 0.1], 0.5);
  strike(b, 0.08, 150, [1, 2.1], [28, 40], [0.6, 0.2], 0.5);   // the bolt drops back
  strike(b, 0.3, 988, [1, 2.0, 3.0], [6, 9, 13], [0.5, 0.12, 0.05], 0.35);
  strike(b, 0.48, 1480, [1, 2.0, 3.0], [5, 8, 12], [0.5, 0.12, 0.05], 0.35);
  return b;
}

function jam() {
  const r = rngFor('jam'), b = new Buf(1.1);
  let ph = 0;
  const bp = biquad('bandpass', 900, 2.5);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    // The motor catches and slips about six times a second.
    const catchIt = (Math.sin(TAU * 6.3 * t + Math.sin(TAU * 1.7 * t) * 2) > 0.2) ? 1 : 0.25;
    ph += TAU * (70 + 30 * catchIt) / SR;
    const grind = bp((r() * 2 - 1)) * catchIt;
    const env = Math.min(1, t / 0.04) * Math.min(1, (1.1 - t) / 0.12);
    b.add(i, (Math.sin(ph) * 0.35 + Math.sin(ph * 2.02) * 0.15 + grind * 0.55) * env * 0.6);
  }
  for (let k = 0; k < 6; k++) {
    const at = 0.1 + k * 0.16 + r() * 0.03;
    noiseBurst(b, r, at, 0.05, 90, 900, 0.45);
    strike(b, at, 220 + r() * 40, [1, 2.4], [40, 60], [0.35, 0.12], 0.3);
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
  'doors_hiss.wav': [hiss, -8],
  'doors_heavy.wav': [heavy, -6],
  'doors_creak_01.wav': [() => creak(1, 420), -9],
  'doors_creak_02.wav': [() => creak(2, 560), -9],
  'doors_latch.wav': [latch, -8],
  'doors_slam.wav': [slam, -3],
  'doors_locked.wav': [locked, -6],
  'doors_unlock.wav': [unlock, -7],
  'doors_jam.wav': [jam, -5],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
