#!/usr/bin/env node
// tools/gen_audio_hands.mjs: offline synth for the hands sweep: wind-ups, the charging shove and the
// stun window on a monster.
//
//   node tools/gen_audio_hands.mjs          # write audio/sfx/hands_*.wav
//   node tools/gen_audio_hands.mjs --check  # render and report, write nothing
//
// Same style as gen_audio.mjs: dependency-free, one seeded PRNG stream per file, byte-identical reruns.
//
//   hands_windup_01/_02  an arm pulled back: a short cloth rustle and a sharp breath in
//   hands_charge         a shove building: a strained breath and a rising low tension, 1.6 s
//   hands_full           the charge maxed out: a tight knuckle-crack tick with a small thump
//   hands_dazed_01/_02   a monster down in the stun window: a wet, wobbling groan with a slow tremble
//   hands_rise           it starts to get up: a rising snarl and a scrape, 0.6 s

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

function windup(variant) {
  const r = rngFor('windup' + variant), b = new Buf(0.42);
  // Cloth: band-passed noise in two quick rubs.
  const bp = biquad('bandpass', 1800, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const rub = Math.exp(-Math.pow((t - 0.05) / 0.035, 2)) + 0.7 * Math.exp(-Math.pow((t - (variant === 1 ? 0.14 : 0.12)) / 0.04, 2));
    b.add(i, bp(r() * 2 - 1, 1400 + 900 * rub) * rub * 0.8);
  }
  // A sharp breath in through the teeth.
  const hp = biquad('highpass', 2600, 0.7);
  const bp2 = biquad('bandpass', 3800, 2.0);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    if (t < 0.08) continue;
    const k = (t - 0.08) / 0.3;
    if (k > 1) break;
    const env = Math.sin(Math.PI * Math.min(1, k * 1.4)) * (1 - k);
    b.add(i, bp2(hp(r() * 2 - 1), 3200 + 1600 * k) * env * 0.55);
  }
  return b;
}

function charge() {
  const r = rngFor('charge'), b = new Buf(1.6);
  const lp = biquad('lowpass', 300, 0.9);
  const bp = biquad('bandpass', 900, 1.1);
  let ph = 0, ph2 = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const k = t / 1.6;
    // Rising tension: a low detuned drone climbing and getting rougher.
    const f = 55 + 70 * k * k;
    ph += TAU * f / SR;
    ph2 += TAU * f * 1.51 / SR;
    const rough = 1 + 0.35 * Math.sin(TAU * (6 + 14 * k) * t);
    const drone = (Math.sin(ph) + 0.45 * Math.sin(ph2)) * rough;
    const env = Math.min(1, t / 0.12) * (0.35 + 0.65 * k) * (t > 1.52 ? (1.6 - t) / 0.08 : 1);
    b.add(i, lp(drone, 180 + 700 * k) * env * 0.9);
    // Strained breath held behind the teeth.
    const breath = bp(r() * 2 - 1, 700 + 1100 * k) * (0.15 + 0.5 * k) * env;
    b.add(i, breath * (0.8 + 0.2 * Math.sin(TAU * 9 * t)));
  }
  return b;
}

function full() {
  const r = rngFor('full'), b = new Buf(0.3);
  const hp = biquad('highpass', 2000, 0.8);
  for (const at of [0.0, 0.028]) {
    const s = Math.round(at * SR);
    for (let i = s; i < s + 1400 && i < b.d.length; i++) b.add(i, hp(r() * 2 - 1) * Math.exp(-(i - s) / SR * 220) * (at === 0 ? 1.0 : 0.6));
  }
  let ph = 0;
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    ph += TAU * (120 + 160 * Math.exp(-t * 40)) / SR;
    b.add(i, Math.sin(ph) * Math.exp(-t * 26) * 0.7);
  }
  return b;
}

function dazed(variant) {
  const r = rngFor('dazed' + variant), b = new Buf(1.3);
  let ph = 0;
  const lp = biquad('lowpass', 500, 1.5);
  const bp = biquad('bandpass', 420, 3.0);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const k = t / 1.3;
    // A slurred, sinking groan with a wobble.
    const f = (variant === 1 ? 92 : 78) * (1.1 - 0.25 * k) * (1 + 0.06 * Math.sin(TAU * 4.5 * t + Math.sin(TAU * 0.9 * t)));
    ph += TAU * f / SR;
    const voice = Math.sin(ph) + 0.5 * Math.sin(ph * 2 + 0.3) + 0.25 * Math.sin(ph * 3);
    const env = Math.pow(Math.sin(Math.PI * Math.min(1, k * 1.05)), 0.7);
    const wet = bp(r() * 2 - 1, 380 + 220 * Math.sin(TAU * 2.2 * t)) * 0.6;
    b.add(i, lp(voice * 0.6 + wet, 350 + 300 * env) * env * (0.75 + 0.25 * Math.sin(TAU * 7 * t)));
  }
  return b;
}

function rise() {
  const r = rngFor('rise'), b = new Buf(0.7);
  let ph = 0;
  const bp = biquad('bandpass', 700, 1.4);
  const lp = biquad('lowpass', 1200, 0.8);
  for (let i = 0; i < b.d.length; i++) {
    const t = i / SR;
    const k = t / 0.7;
    const f = 70 + 130 * Math.pow(k, 1.5);
    ph += TAU * f / SR;
    const growl = Math.sin(ph) * (1 + 0.6 * Math.sin(TAU * 31 * t)) + 0.4 * (r() * 2 - 1);
    const env = Math.min(1, t / 0.05) * (1 - Math.pow(k, 3));
    b.add(i, bp(growl, 500 + 900 * k) * env * 0.9);
    // Feet scraping for purchase.
    if (t > 0.15 && t < 0.45) {
      const s = (t - 0.15) / 0.3;
      b.add(i, lp(r() * 2 - 1) * Math.sin(Math.PI * s) * (0.6 + 0.4 * Math.sin(TAU * 17 * t)) * 0.5);
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
  'hands_windup_01.wav': [() => windup(1), -8],
  'hands_windup_02.wav': [() => windup(2), -8],
  'hands_charge.wav': [() => charge(), -6],
  'hands_full.wav': [() => full(), -5],
  'hands_dazed_01.wav': [() => dazed(1), -6],
  'hands_dazed_02.wav': [() => dazed(2), -6],
  'hands_rise.wav': [() => rise(), -4],
};

fs.mkdirSync(OUT, { recursive: true });
for (const [name, [build, db]] of Object.entries(FILES)) {
  writeWav(path.join(OUT, name), build(), db);
}
