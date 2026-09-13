#!/usr/bin/env node
// tools/gen_audio_surgery_tourniquet.mjs: offline synthesiser for the tourniquet minigame.
//
//   node tools/gen_audio_surgery_tourniquet.mjs          # write audio/sfx/surgery_tourniquet_*.wav
//   node tools/gen_audio_surgery_tourniquet.mjs --check  # render + report, do not write
//
// Same dependency-free, deterministic approach as tools/gen_audio.mjs: one seeded PRNG
// stream per asset, 16-bit mono PCM, re-running produces byte-identical files.
//
// Cues (Audio.play("surgery_tourniquet_<name>")):
//   swish       nylon strap swung over the limb
//   cinch       strap pulled through the buckle and velcro pressed down
//   ratchet_01..03  one windlass click
//   creak_01..02    nylon and plastic groaning under load
//   lock        the rod snapping into the windlass clip

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 44100;
const TAU = Math.PI * 2;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'audio', 'sfx');
const DRY = process.argv.includes('--check');
const PREFIX = 'surgery_tourniquet_';

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

/** RBJ biquad (lowpass / highpass / bandpass with 0 dB peak). Call f(x) or f(x, cutoff). */
function biquad(type, f0, Q) {
  let c, cur = -1, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  const coeffs = (f) => {
    f = Math.min(Math.max(f, 10), SR * 0.45);
    const w0 = (TAU * f) / SR, cw = Math.cos(w0), sw = Math.sin(w0), al = sw / (2 * Q);
    let b0, b1, b2, a0, a1, a2;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    else { b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
    c = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
    cur = f;
  };
  coeffs(f0);
  return (x, f) => {
    if (f !== undefined && Math.abs(f - cur) > 1) coeffs(f);
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

const buf = (sec) => new Float32Array(Math.ceil(sec * SR));
const env = (t, a, d) => (t < 0 ? 0 : t < a ? t / a : Math.exp(-(t - a) / d));

/** A single hard plastic click: a noise transient through a resonant band plus a short tonal ping. */
function click(out, at, rnd, { freq = 3200, q = 6, decay = 0.006, ping = 1800, pingDecay = 0.012, gain = 1 }) {
  const bp = biquad('bandpass', freq, q);
  const start = Math.round(at * SR);
  const n = Math.round(0.08 * SR);
  for (let i = 0; i < n && start + i < out.length; i++) {
    const t = i / SR;
    const nz = (rnd() * 2 - 1) * env(t, 0.0004, decay);
    const tone = Math.sin(TAU * ping * t) * env(t, 0.0003, pingDecay) * 0.35;
    out[start + i] += (bp(nz) * 2.2 + tone) * gain;
  }
}

function buildSwish() {
  const r = rngFor('swish');
  const dur = 0.42, out = buf(dur + 0.05);
  const bp = biquad('bandpass', 900, 0.9);
  const hp = biquad('highpass', 250, 0.7);
  for (let i = 0; i < out.length; i++) {
    const t = i / SR, u = t / dur;
    const shape = u < 1 ? Math.pow(Math.sin(Math.PI * Math.min(1, u)), 1.6) : 0;
    const f = 500 + 2600 * Math.sin(Math.PI * Math.min(1, u)); // doppler-ish sweep up and down
    // Nylon flutter: amplitude modulation at a wobbling rate.
    const flutter = 0.75 + 0.25 * Math.sin(TAU * (38 + 20 * u) * t);
    out[i] = hp(bp(r() * 2 - 1, f)) * shape * flutter;
  }
  // The buckle rattles at the end of the swing.
  click(out, 0.33, r, { freq: 4200, q: 5, decay: 0.004, ping: 2600, gain: 0.35 });
  click(out, 0.37, r, { freq: 3800, q: 5, decay: 0.004, ping: 2300, gain: 0.25 });
  return out;
}

function buildCinch() {
  const r = rngFor('cinch');
  const out = buf(0.75);
  // Strap drawn through the buckle: a rising zip of rough friction.
  const bp = biquad('bandpass', 1200, 1.4);
  const zipDur = 0.32;
  for (let i = 0; i < Math.round(zipDur * SR); i++) {
    const t = i / SR, u = t / zipDur;
    const grain = (Math.sin(TAU * (60 + 140 * u) * t) > 0.6 ? 1 : 0.35); // webbing ribs
    const shape = Math.min(1, u * 6) * (1 - Math.pow(u, 3));
    out[i] += bp(r() * 2 - 1, 900 + 1800 * u) * grain * shape * 1.2;
  }
  // Velcro pressed down: dense crackle of micro clicks.
  const hp = biquad('highpass', 1800, 0.8);
  const vs = 0.36, vd = 0.3;
  for (let i = 0; i < Math.round(vd * SR); i++) {
    const t = i / SR;
    const dens = Math.exp(-t / 0.12);
    const crackle = r() < 0.08 * dens + 0.01 ? (r() * 2 - 1) : (r() * 2 - 1) * 0.08;
    out[Math.round(vs * SR) + i] += hp(crackle) * dens * 0.9;
  }
  // The final tug: a low thump.
  for (let i = 0; i < Math.round(0.12 * SR); i++) {
    const t = i / SR;
    out[Math.round(0.3 * SR) + i] += Math.sin(TAU * (110 - 40 * t / 0.12) * t) * env(t, 0.002, 0.03) * 0.6;
  }
  return out;
}

function buildRatchet(v) {
  const r = rngFor('ratchet' + v);
  const out = buf(0.12);
  const f = [3000, 3400, 2750][v - 1];
  click(out, 0.002, r, { freq: f, q: 7, decay: 0.005, ping: f * 0.55, pingDecay: 0.009, gain: 1 });
  // A smaller pawl bounce.
  click(out, 0.018 + r() * 0.004, r, { freq: f * 1.2, q: 7, decay: 0.003, ping: f * 0.6, pingDecay: 0.005, gain: 0.3 });
  return out;
}

function buildCreak(v) {
  const r = rngFor('creak' + v);
  const dur = 0.55 + 0.15 * v, out = buf(dur + 0.05);
  const bp = biquad('bandpass', 400, 5);
  const lp = biquad('lowpass', 2500, 0.7);
  const base = [140, 175][v - 1];
  let phase = 0, stick = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR, u = t / dur;
    const shape = u < 1 ? Math.sin(Math.PI * Math.min(1, u)) : 0;
    // Stick-slip friction: an irregular pulse train whose rate wanders up.
    const rate = base * (1 + 0.35 * u) * (1 + 0.08 * Math.sin(TAU * 3.1 * t + v));
    phase += rate / SR;
    if (phase >= 1) { phase -= 1; stick = 0.7 + r() * 0.3; }
    stick *= 0.992;
    const pulse = stick * (r() * 0.4 + 0.6);
    out[i] = lp(bp(pulse * 2 - stick, rate * 3.2)) * shape * 2.5;
  }
  return out;
}

function buildLock() {
  const r = rngFor('lock');
  const out = buf(0.4);
  // Rod pushed past the clip lip: two sharp snaps, the second louder, then a hollow plastic knock.
  click(out, 0.004, r, { freq: 2600, q: 4, decay: 0.006, ping: 1500, pingDecay: 0.015, gain: 0.55 });
  click(out, 0.045, r, { freq: 2200, q: 3.5, decay: 0.01, ping: 1250, pingDecay: 0.03, gain: 1.2 });
  const lp = biquad('lowpass', 900, 1.2);
  for (let i = 0; i < Math.round(0.2 * SR); i++) {
    const t = i / SR;
    const k = Math.sin(TAU * 420 * t) * 0.5 + Math.sin(TAU * 690 * t) * 0.3 + (r() * 2 - 1) * 0.4;
    out[Math.round(0.045 * SR) + i] += lp(k) * env(t, 0.001, 0.04) * 0.9;
  }
  return out;
}

function normalize(a, peakDb) {
  let p = 0;
  for (const v of a) p = Math.max(p, Math.abs(v));
  const g = p > 0 ? Math.pow(10, peakDb / 20) / p : 1;
  const fade = Math.min(a.length, Math.round(0.004 * SR));
  for (let i = 0; i < a.length; i++) {
    a[i] *= g;
    if (i >= a.length - fade) a[i] *= (a.length - i) / fade;
  }
  return a;
}

function writeWav(name, data) {
  const n = data.length, bytes = n * 2;
  const b = Buffer.alloc(44 + bytes);
  b.write('RIFF', 0); b.writeUInt32LE(36 + bytes, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(bytes, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, data[i]));
    b.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  const file = path.join(OUT, PREFIX + name + '.wav');
  if (!DRY) fs.writeFileSync(file, b);
  console.log(`  audio/sfx/${PREFIX}${name}.wav`.padEnd(48) + `${(n / SR).toFixed(2)}s  ${(b.length / 1024).toFixed(0)} KB`);
}

fs.mkdirSync(OUT, { recursive: true });
writeWav('swish', normalize(buildSwish(), -4));
writeWav('cinch', normalize(buildCinch(), -3));
for (let v = 1; v <= 3; v++) writeWav(`ratchet_0${v}`, normalize(buildRatchet(v), -6));
for (let v = 1; v <= 2; v++) writeWav(`creak_0${v}`, normalize(buildCreak(v), -8));
writeWav('lock', normalize(buildLock(), -2));
