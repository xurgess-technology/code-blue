#!/usr/bin/env node
// tools/gen_audio_combat.mjs: offline synth for combat (sweep 3): the bone saw as a weapon, the
// anesthetic jab, dragging and strapping a sedated monster.
//
//   node tools/gen_audio_combat.mjs          # write audio/sfx/combat_*.wav
//   node tools/gen_audio_combat.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, so re-running
// produces byte-identical output.
//
//   combat_swing_01/_02   the saw cutting air: a short rising-falling whoosh with a thin metal ring
//   combat_jab_swish      a quick small swish for the needle thrust
//   combat_hit_01/_02     the saw biting flesh: a wet chop with a rasp of teeth
//   combat_clang          the saw skidding off the Night Nurse: a dull bell-like clank
//   combat_snap           the saw snapping: a sharp crack and a ringing, wobbling blade
//   combat_jab            the needle going in: a tiny tick and a short hiss of the plunger
//   combat_needle_fail    the needle refused or shrugged off: a bent tick and a plastic click
//   combat_drag           grabbing a sedated body: cloth and a heavy scrape
//   combat_strap          strapping it down: two buckle clacks and a leather tug

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

// Inharmonic partials with slightly detuned beating: struck metal.
function ring(b, at, base, partials, decay, gain, wobble = 0) {
  const start = Math.round(at * SR);
  const phs = partials.map(() => 0);
  for (let i = start; i < b.d.length; i++) {
    const t = (i - start) / SR;
    if (t > 2.0) break;
    let v = 0;
    for (let k = 0; k < partials.length; k++) {
      const [ratio, amp, dk] = partials[k];
      const f = base * ratio * (1 + wobble * Math.sin(TAU * 7.5 * t) * Math.exp(-t * 3));
      phs[k] += TAU * f / SR;
      v += Math.sin(phs[k]) * amp * Math.exp(-t * decay * dk);
    }
    b.add(i, v * Math.min(1, t / 0.001) * gain);
  }
}

function whoosh(b, r, at, len, fLo, fHi, gain) {
  const bp = biquad('bandpass', fLo, 1.2);
  const start = Math.round(at * SR);
  for (let i = start; i < start + Math.round(len * SR) && i < b.d.length; i++) {
    const k = (i - start) / (len * SR);
    const env = Math.pow(Math.sin(Math.PI * Math.min(1, k * 1.15)), 2);
    const f = fLo + (fHi - fLo) * Math.sin(Math.PI * k);
    b.add(i, bp(r() * 2 - 1, f) * env * gain);
  }
}

function swing(variant) {
  const r = rngFor('swing' + variant), b = new Buf(0.5);
  whoosh(b, r, 0.0, variant === 1 ? 0.3 : 0.36, 380, variant === 1 ? 1500 : 1250, 1.0);
  ring(b, 0.12, variant === 1 ? 2900 : 3300, [[1, 1, 1], [1.51, 0.5, 1.4], [2.37, 0.3, 2.0]], 12.0, 0.03);
  return b;
}

function jabSwish() {
  const r = rngFor('jabswish'), b = new Buf(0.2);
  whoosh(b, r, 0.0, 0.14, 1400, 3200, 1.0);
  return b;
}

function hit(variant) {
  const r = rngFor('hit' + variant), b = new Buf(0.6);
  thud(b, r, 0.0, variant === 1 ? 90 : 75, 14.0, 1.0);
  // Wet squelch: low-passed noise with a fast wobble.
  const lp = biquad('lowpass', 900, 1.4);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const wob = 0.6 + 0.4 * Math.sin(TAU * (38 + variant * 7) * t);
    b.add(i, lp(r() * 2 - 1, 500 + 900 * Math.exp(-t * 10)) * Math.exp(-t * 9.0) * wob * 0.9);
  }
  // Teeth rasp: gated high noise bursts.
  const hp = biquad('highpass', 2500, 0.7);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t > 0.12) break;
    const gate = Math.sin(TAU * 110 * t) > 0.2 ? 1 : 0.2;
    b.add(i, hp(r() * 2 - 1) * gate * Math.exp(-t * 25) * 0.35);
  }
  return b;
}

function clang() {
  const r = rngFor('clang'), b = new Buf(1.2);
  ring(b, 0.0, 520, [[1, 1, 1], [2.76, 0.6, 1.6], [5.4, 0.35, 2.4], [8.9, 0.2, 3.0]], 5.0, 0.6);
  const hp = biquad('highpass', 3000, 0.7);
  for (let i = 0; i < 2000; i++) b.add(i, hp(r() * 2 - 1) * Math.exp(-i / SR * 120) * 0.8);
  return b;
}

function snap() {
  const r = rngFor('snap'), b = new Buf(1.3);
  // Crack: a very short broadband burst with a click.
  const hp = biquad('highpass', 1200, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t > 0.05) break;
    b.add(i, hp(r() * 2 - 1) * Math.exp(-t * 90) * 1.3);
  }
  // The broken blade ringing and wobbling, a second piece clattering down.
  ring(b, 0.004, 1850, [[1, 1, 1], [1.83, 0.6, 1.3], [3.1, 0.35, 2.0]], 4.5, 0.35, 0.04);
  ring(b, 0.42, 2600, [[1, 1, 1], [2.2, 0.5, 1.8]], 18.0, 0.18);
  ring(b, 0.61, 2450, [[1, 1, 1], [2.3, 0.4, 1.8]], 22.0, 0.12);
  return b;
}

function jab() {
  const r = rngFor('jab'), b = new Buf(0.55);
  const hp = biquad('highpass', 3500, 0.7);
  for (let i = 0; i < 900; i++) b.add(i, hp(r() * 2 - 1) * Math.exp(-i / SR * 250) * 1.0);
  thud(b, r, 0.01, 180, 40.0, 0.25);
  // Plunger hiss.
  const bp = biquad('bandpass', 5000, 1.5);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t < 0.08 || t > 0.45) continue;
    const k = (t - 0.08) / 0.37;
    b.add(i, bp(r() * 2 - 1, 5000 - 1800 * k) * Math.sin(Math.PI * k) * 0.35);
  }
  return b;
}

function needleFail() {
  const r = rngFor('needlefail'), b = new Buf(0.4);
  const hp = biquad('highpass', 2800, 0.7);
  for (let i = 0; i < 700; i++) b.add(i, hp(r() * 2 - 1) * Math.exp(-i / SR * 300) * 0.9);
  ring(b, 0.0, 4200, [[1, 1, 1], [1.4, 0.5, 1.5]], 45.0, 0.25, 0.08);
  // Plastic click.
  const bp = biquad('bandpass', 1800, 3.0);
  const s = Math.round(0.14 * SR);
  for (let i = s; i < s + 1500; i++) b.add(i, bp(r() * 2 - 1) * Math.exp(-(i - s) / SR * 160) * 1.2);
  return b;
}

function drag() {
  const r = rngFor('drag'), b = new Buf(1.0);
  const bp = biquad('bandpass', 1500, 0.6);
  const lp = biquad('lowpass', 400, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const rustle = Math.exp(-Math.pow((t - 0.1) / 0.07, 2));
    b.add(i, bp(r() * 2 - 1) * rustle * 0.5);
    // Scrape of the body starting to slide: low rough noise with a stick-slip wobble.
    if (t > 0.25) {
      const k = (t - 0.25) / 0.75;
      const slip = 0.55 + 0.45 * Math.sin(TAU * 13 * t + Math.sin(TAU * 3 * t));
      b.add(i, lp(r() * 2 - 1) * Math.sin(Math.PI * k) * slip * 1.3);
    }
  }
  thud(b, r, 0.16, 65, 14.0, 0.45);
  return b;
}

function strap() {
  const r = rngFor('strap'), b = new Buf(0.9);
  const clack = (at, f) => {
    const bp = biquad('bandpass', f, 4.0);
    const s = Math.round(at * SR);
    for (let i = s; i < s + 3000 && i < b.d.length; i++) b.add(i, bp(r() * 2 - 1) * Math.exp(-(i - s) / SR * 90) * 1.4);
    ring(b, at, f * 1.9, [[1, 1, 1], [2.6, 0.4, 2]], 40.0, 0.12);
  };
  // Leather pulled tight between the buckles.
  const bp = biquad('bandpass', 900, 1.2);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t < 0.12 || t > 0.42) continue;
    const k = (t - 0.12) / 0.3;
    const creak = 0.5 + 0.5 * Math.sin(TAU * (60 + 40 * k) * t);
    b.add(i, bp(r() * 2 - 1, 700 + 500 * k) * Math.sin(Math.PI * k) * creak * 0.6);
  }
  clack(0.05, 1300);
  clack(0.5, 1150);
  thud(b, r, 0.5, 110, 30.0, 0.3);
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
  'combat_swing_01.wav': [() => swing(1), -6],
  'combat_swing_02.wav': [() => swing(2), -6],
  'combat_jab_swish.wav': [() => jabSwish(), -10],
  'combat_hit_01.wav': [() => hit(1), -3],
  'combat_hit_02.wav': [() => hit(2), -3],
  'combat_clang.wav': [() => clang(), -4],
  'combat_snap.wav': [() => snap(), -3],
  'combat_jab.wav': [() => jab(), -8],
  'combat_needle_fail.wav': [() => needleFail(), -8],
  'combat_drag.wav': [() => drag(), -5],
  'combat_strap.wav': [() => strap(), -5],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
