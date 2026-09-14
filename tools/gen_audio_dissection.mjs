#!/usr/bin/env node
// tools/gen_audio_dissection.mjs: offline synth for dissecting strapped monsters (sweep 3).
//
//   node tools/gen_audio_dissection.mjs          # write audio/sfx/dissection_*.wav
//   node tools/gen_audio_dissection.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   dissection_shriek_01/_02  an awake monster screaming on the table: a torn, wavering howl
//   dissection_strap_01/_02   a limb yanking against a strap: leather creak and a buckle rattle
//   dissection_snap           a nerve popping free of the brain: a wet elastic pluck
//   dissection_plop           a brain landing (in the tray or on the drapes): a soft wet slap
//   dissection_crack          the skull cap coming away: a dry crack and a suck of air
//   dissection_inject         a re-dose going in: a short plunger hiss

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

function shriek(variant) {
  const r = rngFor('shriek' + variant), b = new Buf(variant === 1 ? 1.5 : 1.2);
  const f1 = biquad('bandpass', 900, 3.0), f2 = biquad('bandpass', 2300, 4.0), f3 = biquad('bandpass', 3400, 5.0);
  const hiss = biquad('highpass', 2500, 0.7);
  let ph = 0;
  const dur = b.d.length / SR;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const k = t / dur;
    // Rises fast, cracks, sags: pitch with a wide, uneven vibrato.
    const base = (variant === 1 ? 420 : 520) * (1 + 0.5 * Math.min(1, t / 0.12)) * (1 - 0.35 * k);
    const vib = 1 + 0.06 * Math.sin(TAU * 7.3 * t) + 0.03 * Math.sin(TAU * 13.1 * t + 1.0);
    const crack = (t > 0.3 && t < 0.42) ? 1.35 : 1.0;
    ph += TAU * base * vib * crack / SR;
    // A buzzy source: a clipped saw.
    let src = ((ph / TAU) % 1) * 2 - 1;
    src = Math.tanh(src * 2.5 + (r() * 2 - 1) * 0.35);
    const env = Math.min(1, t / 0.04) * Math.pow(1 - k, 1.4);
    const voice = f1(src) * 1.0 + f2(src) * 0.8 + f3(src) * 0.45;
    b.add(i, (voice * 1.2 + hiss(r() * 2 - 1) * 0.25) * env);
  }
  return b;
}

function strap(variant) {
  const r = rngFor('strap' + variant), b = new Buf(0.55);
  const creak = biquad('bandpass', variant === 1 ? 480 : 620, 6.0);
  const lp = biquad('lowpass', 900, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    let v = 0;
    // Leather creak: a stick-slip train of clicks through a resonance.
    const rate = 55 + 40 * Math.sin(t * 9.0);
    if (t < 0.32 && r() < rate / SR * 1.6) v += (r() * 2 - 1) * 3.0;
    v = creak(v) * Math.exp(-t * 4.0);
    // The table and the body taking the jolt.
    v += lp(r() * 2 - 1) * Math.min(1, t / 0.005) * Math.exp(-t * 18.0) * 0.8;
    // Buckle rattle.
    for (const at of [0.03, 0.09, 0.14]) {
      const dt = t - at - (variant === 1 ? 0 : 0.02);
      if (dt > 0 && dt < 0.06) v += Math.sin(TAU * 3100 * dt) * Math.exp(-dt * 90) * 0.35 + Math.sin(TAU * 4700 * dt) * Math.exp(-dt * 120) * 0.2;
    }
    b.add(i, v);
  }
  return b;
}

function snap() {
  const r = rngFor('snap'), b = new Buf(0.35);
  const bp = biquad('bandpass', 1200, 1.5);
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    // An elastic pluck: a falling blip plus a wet burst.
    const f = 900 * Math.exp(-t * 30) + 180;
    ph += TAU * f / SR;
    const pluck = Math.sin(ph) * Math.exp(-t * 28) * 0.8;
    const wet = bp(r() * 2 - 1, 700 + 1600 * Math.exp(-t * 20)) * Math.exp(-t * 22) * 1.3;
    b.add(i, pluck + wet);
  }
  return b;
}

function plop() {
  const r = rngFor('plop'), b = new Buf(0.5);
  const lp = biquad('lowpass', 1400, 0.9);
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const f = 140 + 260 * Math.exp(-t * 40);
    ph += TAU * f / SR;
    const body = Math.sin(ph) * Math.min(1, t / 0.004) * Math.exp(-t * 16) * 0.9;
    const slap = lp(r() * 2 - 1) * Math.exp(-t * 35) * 0.9;
    const drip = t > 0.18 ? Math.sin(TAU * (1100 - 1500 * (t - 0.18)) * (t - 0.18)) * Math.exp(-(t - 0.18) * 40) * 0.25 : 0;
    b.add(i, body + slap + drip);
  }
  return b;
}

function crack() {
  const r = rngFor('crack'), b = new Buf(0.8);
  const hp = biquad('highpass', 1800, 0.7);
  const suck = biquad('bandpass', 500, 1.2);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    let v = 0;
    // Dry bone crack: a dense cluster of sharp ticks.
    if (t < 0.09 && r() < 0.05) v += (r() * 2 - 1) * 2.0 * Math.exp(-t * 25);
    v = hp(v);
    // Then the suction as the cap lifts away.
    if (t > 0.08) {
      const k = t - 0.08;
      v += suck(r() * 2 - 1, 380 + 900 * Math.min(1, k / 0.3)) * Math.sin(Math.PI * Math.min(1, k / 0.5)) * 0.9;
    }
    b.add(i, v);
  }
  return b;
}

function inject() {
  const r = rngFor('inject'), b = new Buf(0.4);
  const bp = biquad('bandpass', 5200, 2.0);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const click = t < 0.012 ? Math.sin(TAU * 2600 * t) * Math.exp(-t * 400) : 0;
    const hiss = bp(r() * 2 - 1, 4200 + 2000 * t) * Math.sin(Math.PI * Math.min(1, t / 0.36)) * 0.6;
    b.add(i, click + hiss);
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
  'dissection_shriek_01.wav': [() => shriek(1), -3],
  'dissection_shriek_02.wav': [() => shriek(2), -3],
  'dissection_strap_01.wav': [() => strap(1), -6],
  'dissection_strap_02.wav': [() => strap(2), -6],
  'dissection_snap.wav': [() => snap(), -6],
  'dissection_plop.wav': [() => plop(), -5],
  'dissection_crack.wav': [() => crack(), -5],
  'dissection_inject.wav': [() => inject(), -9],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
