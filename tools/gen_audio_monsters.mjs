#!/usr/bin/env node
// tools/gen_audio_monsters.mjs — offline synthesiser for the two monsters.
//
//   node tools/gen_audio_monsters.mjs           # write audio/sfx/monsters_*.wav
//   node tools/gen_audio_monsters.mjs --check   # render + report, do not write
//
// Same rules as tools/gen_audio.mjs: dependency free, deterministic (one seeded PRNG
// stream per file), 16-bit mono PCM at 44.1 kHz. Numbered _01.._NN files are variants
// the Audio autoload picks between at random.
//
// Cues (all meant to be unsettling rather than loud; the game plays them in 3D):
//   monsters_iv_rattle   squeaky caster + loose pole rattle, short, retriggered while walking
//   monsters_inhale      the Discharged's wet listening inhale when it hears something
//   monsters_shriek      the lunge shriek, both monsters
//   monsters_squeak      the Night Nurse's shoe squeaks, one per footfall
//   monsters_lullaby     a faint, slightly wrong humming the Nurse breathes when unobserved
//   monsters_grab        the hit / grab when a monster connects
//   monsters_hive_groan    sweep 3: the Hive's occasional groan, louder when it sees you
//   monsters_hive_shuffle  sweep 3: a dragged bare foot, one per Hive step
//   monsters_flesh_hit       sweep 3: a monster struck by the saw
//   monsters_hive_death    sweep 3: the Hive killed
//   monsters_sedated_breath  sweep 3: a sedated monster's slow snoring breath

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

// ---------------------------------------------------------------- DSP helpers

/** RBJ biquad as a stateful per-sample function. Frequency may be changed per call. */
function biquad(type, q = 0.707) {
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x, f0) => {
    const w = TAU * Math.min(f0, SR * 0.45) / SR;
    const cw = Math.cos(w), sw = Math.sin(w), alpha = sw / (2 * q);
    let b0, b1, b2;
    const a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; }
    else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; }
    else { b0 = alpha; b1 = 0; b2 = -alpha; } // bandpass, 0 dB peak
    const y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}
const buf = (sec) => new Float32Array(Math.ceil(sec * SR));
function add(dst, src, at = 0, gain = 1) {
  const o = Math.floor(at * SR);
  for (let i = 0; i < src.length && o + i < dst.length; i++) if (o + i >= 0) dst[o + i] += src[i] * gain;
}
function peak(a) { let p = 0; for (const v of a) p = Math.max(p, Math.abs(v)); return p; }
function normalise(a, db) { const p = peak(a); if (p > 0) { const k = Math.pow(10, db / 20) / p; for (let i = 0; i < a.length; i++) a[i] *= k; } return a; }
function fadeEdges(a, inMs = 2, outMs = 12) {
  const fi = Math.ceil(inMs / 1000 * SR), fo = Math.ceil(outMs / 1000 * SR);
  for (let i = 0; i < fi && i < a.length; i++) a[i] *= i / fi;
  for (let i = 0; i < fo && i < a.length; i++) a[a.length - 1 - i] *= i / fo;
  return a;
}
const env = (t, a, d) => (t < 0 ? 0 : t < a ? t / a : Math.exp(-(t - a) / d));
/** Tiny feedback comb "room" so dry voices sit in a corridor instead of in your ear. */
function room(a, mix = 0.25, size = 1) {
  const taps = [0.0297, 0.0371, 0.0411, 0.0437].map((s) => Math.floor(s * size * SR));
  const out = new Float32Array(a.length);
  const lines = taps.map((n) => ({ d: new Float32Array(n), i: 0 }));
  const lp = biquad('lowpass', 0.6);
  for (let i = 0; i < a.length; i++) {
    let w = 0;
    for (const l of lines) {
      const y = l.d[l.i];
      l.d[l.i] = a[i] + y * 0.72;
      l.i = (l.i + 1) % l.d.length;
      w += y;
    }
    out[i] = a[i] * (1 - mix) + lp(w * 0.25, 3200) * mix;
  }
  return out;
}

// ---------------------------------------------------------------- cues

/** Caster squeal + a loose clamp ticking against the pole + wheels on lino. */
function ivRattle(v) {
  const r = rngFor('iv_rattle' + v);
  const len = r.range(0.34, 0.46);
  const out = buf(len);
  // Squeal: a stick-slip chirp, pitch wobbling, amplitude chattering.
  const f0 = r.range(1700, 2500), bp = biquad('bandpass', 6);
  const sq0 = r.range(0.0, 0.08), sqLen = r.range(0.12, 0.24);
  let ph = 0;
  for (let i = 0; i < out.length; i++) {
    const t = i / SR - sq0;
    if (t < 0 || t > sqLen) continue;
    const f = f0 * (1 + 0.06 * Math.sin(TAU * 7 * t) + 0.12 * (t / sqLen));
    ph += f / SR;
    const chatter = 0.5 + 0.5 * Math.sign(Math.sin(TAU * r.range(38, 44) * t + ph * 0.02));
    const e = Math.sin(Math.PI * t / sqLen) ** 1.5;
    out[i] += bp(Math.sin(TAU * ph) + 0.4 * Math.sin(TAU * ph * 2.01), f) * chatter * e * 0.55;
  }
  // Rattle: 3-6 metallic ticks, each an inharmonic ringing pole.
  const n = 3 + Math.floor(r() * 4);
  for (let k = 0; k < n; k++) {
    const at = r.range(0, len - 0.12);
    const modes = [r.range(780, 980), r.range(2300, 2600), r.range(4400, 5100), r.range(6900, 7600)];
    const tick = buf(0.14);
    const g = r.range(0.35, 1);
    for (let i = 0; i < tick.length; i++) {
      const t = i / SR;
      let s = 0;
      modes.forEach((m, j) => { s += Math.sin(TAU * m * t) * Math.exp(-t / (0.05 / (j + 1))) / (j + 1); });
      tick[i] = s * g * 0.35;
    }
    add(out, tick, at);
  }
  // Rolling: low filtered noise under everything.
  const lp = biquad('lowpass', 0.8);
  for (let i = 0; i < out.length; i++) out[i] += lp(r() * 2 - 1, 220) * 0.5 * Math.sin(Math.PI * i / out.length);
  return fadeEdges(room(out, 0.2, 0.8));
}

/** A slow, wet, rising inhale through something that is not quite a mouth. */
function inhale(v) {
  const r = rngFor('inhale' + v);
  const len = r.range(1.0, 1.25);
  const out = buf(len + 0.3);
  const bp = biquad('bandpass', 2.2), bp2 = biquad('bandpass', 5), lp = biquad('lowpass', 0.7);
  for (let i = 0; i < len * SR; i++) {
    const t = i / SR, u = t / len;
    const e = Math.pow(Math.sin(Math.PI * Math.min(1, u * 1.1)), 0.8) * (0.4 + 0.6 * u);
    const n = r() * 2 - 1;
    const flutter = 1 + 0.35 * Math.sin(TAU * 11 * t) * Math.sin(TAU * 0.7 * t);
    out[i] += bp(n, 500 + 1500 * u) * e * flutter * 1.2;
    out[i] += bp2(n, 2600 + 800 * Math.sin(TAU * 3 * t)) * e * 0.25;
    // A throat that is barely voiced.
    out[i] += lp(Math.sin(TAU * (82 + 10 * u) * t) * (r() * 0.6 + 0.4), 400) * e * 0.12;
  }
  // Wet crackles: short damped clicks clustered toward the end of the breath.
  const clicks = 14 + Math.floor(r() * 10);
  for (let k = 0; k < clicks; k++) {
    const at = len * Math.pow(r(), 0.6);
    const c = buf(0.03), f = r.range(900, 2400);
    for (let i = 0; i < c.length; i++) { const t = i / SR; c[i] = Math.sin(TAU * f * t) * Math.exp(-t / 0.004) * r.range(0.2, 0.6); }
    add(out, c, at);
  }
  return fadeEdges(room(out, 0.3));
}

/** Not a scream: a strangled rising shriek, breath first, then the voice tears. */
function shriek(v) {
  const r = rngFor('shriek' + v);
  const len = r.range(0.75, 0.95);
  const out = buf(len + 0.35);
  const voices = [0, 1, 2, 3].map(() => ({ ph: 0, det: r.range(-0.035, 0.035) }));
  const f1 = biquad('bandpass', 4), f2 = biquad('bandpass', 5), hp = biquad('highpass', 0.7), nb = biquad('bandpass', 1.4);
  for (let i = 0; i < len * SR; i++) {
    const t = i / SR, u = t / len;
    const e = env(t, 0.06, len * 0.45) * (u < 0.85 ? 1 : (1 - u) / 0.15);
    const base = 520 * Math.pow(2.3, Math.min(1, u * 1.6)) * (1 + 0.03 * Math.sin(TAU * 23 * t) + 0.02 * (r() - 0.5));
    let s = 0;
    for (const vo of voices) {
      vo.ph += base * (1 + vo.det) / SR; vo.ph -= Math.floor(vo.ph);
      s += (2 * vo.ph - 1);
    }
    s = Math.tanh(s * 0.8);
    const formant = f1(s, 1100 + 900 * u) * 1.2 + f2(s, 2900 + 600 * Math.sin(TAU * 5 * t)) * 0.8;
    const breath = nb(r() * 2 - 1, 1800 + 1200 * u) * (1 - u * 0.5);
    out[i] += hp(formant * 0.7 + breath * 0.9, 250) * e;
  }
  return fadeEdges(room(out, 0.28, 1.2));
}

/** Rubber sole on waxed lino: a short stick-slip squeak. */
function squeak(v) {
  const r = rngFor('squeak' + v);
  const len = r.range(0.07, 0.17);
  const out = buf(len + 0.12);
  const bp = biquad('bandpass', 3.5);
  const fA = r.range(850, 1300), fB = fA * r.range(1.15, 1.6), am = r.range(45, 95);
  let ph = 0;
  for (let i = 0; i < len * SR; i++) {
    const t = i / SR, u = t / len;
    const f = fA + (fB - fA) * Math.sin(Math.PI * 0.5 * u);
    ph += f / SR;
    const stick = Math.pow(0.5 + 0.5 * Math.sin(TAU * am * t), 3);
    const e = Math.sin(Math.PI * u);
    const s = Math.sin(TAU * ph) * 0.7 + (2 * (ph % 1) - 1) * 0.3;
    out[i] = bp(s * stick * e + (r() * 2 - 1) * 0.08 * e, f * 1.2);
  }
  return fadeEdges(room(out, 0.25, 0.9));
}

/** Humming through a mask, a lullaby that goes one note wrong every time. */
function lullaby(v) {
  const r = rngFor('lullaby' + v);
  const A3 = 220;
  const semis = (n) => A3 * Math.pow(2, n / 12);
  // Minor, simple, descending; the flattened second-to-last note is the wrongness.
  const tunes = [
    [[12, 0.7], [7, 0.45], [8, 0.45], [7, 0.9], [5, 0.45], [3, 0.45], [2, 0.6], [1, 0.5], [0, 1.6]],
    [[7, 0.6], [12, 0.6], [10, 0.4], [8, 0.4], [7, 1.0], [8, 0.5], [7, 0.5], [6, 0.7], [0, 1.8]],
  ];
  const tune = tunes[(v - 1) % tunes.length];
  const total = tune.reduce((s, n) => s + n[1], 0);
  const out = buf(total + 1.2);
  const lp = biquad('lowpass', 0.9), nasal = biquad('bandpass', 3), br = biquad('bandpass', 1.2);
  let t0 = 0, ph = 0, prevF = semis(tune[0][0]);
  for (const [note, dur] of tune) {
    const target = semis(note) * (1 + r.range(-0.012, 0.012));
    const n = Math.floor(dur * SR);
    const start = Math.floor(t0 * SR);
    for (let i = 0; i < n; i++) {
      const t = i / SR, gt = t0 + t;
      const glide = Math.min(1, t / 0.09);
      const f = (prevF + (target - prevF) * glide) * (1 + 0.009 * Math.sin(TAU * 5.1 * gt) + 0.004 * Math.sin(TAU * 0.37 * gt));
      ph += f / SR; ph -= Math.floor(ph);
      let s = 0;
      for (let h = 1; h <= 7; h++) s += Math.sin(TAU * ph * h) / (h * h * 0.8 + 0.2);
      const e = Math.min(1, t / 0.08) * (t > dur - 0.12 ? Math.max(0, (dur - t) / 0.12) * 0.7 + 0.3 : 1);
      const hum = lp(s, 700) * 0.8 + nasal(s, 250) * 0.5;
      const breath = br(r() * 2 - 1, 900) * 0.18;
      out[start + i] += (hum + breath) * e * 0.5;
    }
    prevF = target;
    t0 += dur;
  }
  // The whole phrase swells in and falls away, like someone turning their head.
  for (let i = 0; i < out.length; i++) {
    const u = i / out.length;
    out[i] *= Math.min(1, u * 5) * Math.min(1, (1 - u) * 2.5);
  }
  return fadeEdges(room(out, 0.4, 1.4), 20, 200);
}

/** Cold hands closing on scrubs: a heavy thump, cloth, and something wet. */
function grab(v) {
  const r = rngFor('grab' + v);
  const out = buf(0.7);
  let ph = 0;
  for (let i = 0; i < 0.3 * SR; i++) {
    const t = i / SR;
    const f = 95 * Math.exp(-t * 9) + 45;
    ph += f / SR;
    out[i] += Math.sin(TAU * ph) * env(t, 0.003, 0.08) * 0.9;
  }
  const cloth = biquad('bandpass', 0.9), wet = biquad('bandpass', 7);
  for (let i = 0; i < 0.35 * SR; i++) {
    const t = i / SR;
    out[i] += cloth(r() * 2 - 1, 1400 + 1800 * Math.exp(-t * 20)) * env(t, 0.002, 0.05) * 0.8;
  }
  const w0 = r.range(0.05, 0.1);
  for (let i = 0; i < 0.25 * SR; i++) {
    const t = i / SR;
    const f = 600 + 900 * Math.sin(TAU * 13 * t) ** 2;
    out[Math.floor(w0 * SR) + i] += wet(r() * 2 - 1, f) * env(t, 0.01, 0.07) * 0.9;
  }
  return fadeEdges(room(out, 0.22));
}

// ---------------------------------------------------------------- sweep 3: the Hive, hits, sedation

/** A voiced vowel through a slack jaw: a sawtooth-ish glottal source into two formants. */
function voice(out, at, len, f0From, f0To, formants, gain, r, rough = 0.3) {
  const f1 = biquad('bandpass', 3.5), f2 = biquad('bandpass', 4.5), f3 = biquad('bandpass', 6);
  let ph = 0;
  const o = Math.floor(at * SR);
  for (let i = 0; i < len * SR && o + i < out.length; i++) {
    const t = i / SR, u = t / len;
    const f0 = (f0From + (f0To - f0From) * u) * (1 + 0.025 * Math.sin(TAU * 4.3 * t) + rough * 0.04 * (r() - 0.5));
    ph += f0 / SR; ph -= Math.floor(ph);
    // Vocal fry: every few cycles the pulse skips.
    const fry = 1 - rough * 0.6 * Math.max(0, Math.sin(TAU * f0 * 0.25 * t));
    const src = (2 * ph - 1) * fry + (r() * 2 - 1) * rough * 0.35;
    const e = Math.min(1, t / 0.08) * Math.pow(Math.max(0, 1 - u), 0.6);
    const [a, b, c] = formants;
    out[o + i] += (f1(src, a) * 1.0 + f2(src, b) * 0.55 + f3(src, c) * 0.2) * e * gain;
  }
}

/** The Hive's groan: low, wet, falling, half a word. Not loud. */
function hiveGroan(v) {
  const r = rngFor('walkin' + '_groan' + v);   // seeded by the old name: the same sound
  const len = r.range(1.1, 1.7);
  const out = buf(len + 0.5);
  const base = r.range(78, 98);
  voice(out, 0.0, len, base * 1.15, base * 0.82, [r.range(420, 560), r.range(850, 1050), 2500], 1.0, r, 0.55);
  // A second, shorter swell partway through, like it tries again.
  voice(out, len * r.range(0.35, 0.5), len * 0.45, base * 1.05, base * 0.9, [r.range(380, 460), r.range(760, 900), 2300], 0.6, r, 0.7);
  // Wet throat noise underneath.
  const bp = biquad('bandpass', 1.5);
  for (let i = 0; i < len * SR; i++) {
    const t = i / SR, u = t / len;
    out[i] += bp(r() * 2 - 1, 700 + 300 * Math.sin(TAU * 2 * t)) * Math.sin(Math.PI * u) * 0.12;
  }
  return fadeEdges(room(out, 0.3, 1.1), 10, 150);
}

/** One heavy bare foot dragged across lino, then set down. */
function hiveShuffle(v) {
  const r = rngFor('walkin' + '_shuffle' + v);   // seeded by the old name: the same sound
  const drag = r.range(0.22, 0.36);
  const out = buf(drag + 0.3);
  const bp = biquad('bandpass', 1.1), lp = biquad('lowpass', 0.7);
  for (let i = 0; i < drag * SR; i++) {
    const t = i / SR, u = t / drag;
    const grain = r() < 0.08 ? (r() * 2 - 1) * 2.5 : r() * 2 - 1;  // skin catching and letting go
    const e = Math.sin(Math.PI * Math.min(1, u * 1.2)) * (0.6 + 0.4 * Math.sin(TAU * r.range(9, 15) * t));
    out[i] += bp(grain, 900 + 900 * u) * e * 0.5;
  }
  // The foot lands: a dull thud.
  let ph = 0;
  const o = Math.floor(drag * 0.85 * SR);
  for (let i = 0; i < 0.18 * SR && o + i < out.length; i++) {
    const t = i / SR;
    ph += (70 * Math.exp(-t * 20) + 45) / SR;
    out[o + i] += lp(Math.sin(TAU * ph) + (r() * 2 - 1) * 0.3, 500) * env(t, 0.004, 0.05) * 0.9;
  }
  return fadeEdges(room(out, 0.18, 0.8));
}

/** A blade into a body: the chop, a meaty slap, a short spatter. Any monster that is struck. */
function fleshHit(v) {
  const r = rngFor('flesh_hit' + v);
  const out = buf(0.55);
  const lp = biquad('lowpass', 0.8), hp = biquad('highpass', 0.7), wet = biquad('bandpass', 2.5);
  let ph = 0;
  for (let i = 0; i < 0.25 * SR; i++) {
    const t = i / SR;
    ph += (120 * Math.exp(-t * 25) + 55) / SR;
    out[i] += Math.sin(TAU * ph) * env(t, 0.002, 0.06) * 0.9;             // body thump
    out[i] += lp(r() * 2 - 1, 2400) * env(t, 0.001, 0.02) * 0.9;          // slap
    out[i] += hp(r() * 2 - 1, 3000) * env(t, 0.0005, 0.008) * 0.5;       // edge
  }
  const n = 6 + Math.floor(r() * 6);
  for (let k = 0; k < n; k++) {
    const at = r.range(0.03, 0.3), f = r.range(500, 1600);
    const c = buf(0.05);
    for (let i = 0; i < c.length; i++) { const t = i / SR; c[i] = wet(r() * 2 - 1, f) * Math.exp(-t / 0.012) * r.range(0.3, 0.8); }
    add(out, c, at);
  }
  return fadeEdges(room(out, 0.2, 0.9));
}

/** The Hive goes down: a long collapsing exhale that breaks into a rattle. */
function hiveDeath(v) {
  const r = rngFor('walkin' + '_death' + v);   // seeded by the old name: the same sound
  const len = r.range(1.4, 1.8);
  const out = buf(len + 0.7);
  const base = r.range(95, 115);
  voice(out, 0.0, len * 0.6, base * 1.3, base * 0.7, [r.range(500, 620), r.range(950, 1150), 2600], 1.0, r, 0.5);
  // The rattle: slow irregular clicks of air through fluid.
  let t = len * 0.45;
  while (t < len) {
    const c = buf(0.06), f = r.range(250, 600);
    for (let i = 0; i < c.length; i++) { const tt = i / SR; c[i] = Math.sin(TAU * f * tt) * Math.exp(-tt / 0.015) * 0.5 + (r() - 0.5) * Math.exp(-tt / 0.01) * 0.4; }
    add(out, c, t, 1 - (t - len * 0.45) / (len * 0.55));
    t += r.range(0.04, 0.11) * (1 + (t / len));
  }
  // And the body hitting the floor.
  let ph = 0;
  const o = Math.floor(len * 0.35 * SR);
  for (let i = 0; i < 0.35 * SR && o + i < out.length; i++) {
    const tt = i / SR;
    ph += (60 * Math.exp(-tt * 12) + 38) / SR;
    out[o + i] += Math.sin(TAU * ph) * env(tt, 0.004, 0.12) * 0.8;
  }
  return fadeEdges(room(out, 0.3, 1.2), 5, 250);
}

/** Out cold: one slow, deep, slightly snoring breath (in and out). */
function sedatedBreath(v) {
  const r = rngFor('sedated_breath' + v);
  const inLen = r.range(1.1, 1.4), outLen = r.range(1.4, 1.8);
  const out = buf(inLen + outLen + 0.4);
  const bp = biquad('bandpass', 1.8), lp = biquad('lowpass', 0.7);
  let ph = 0;
  for (let i = 0; i < (inLen + outLen) * SR; i++) {
    const t = i / SR;
    const inhale = t < inLen;
    const u = inhale ? t / inLen : (t - inLen) / outLen;
    const e = Math.sin(Math.PI * u) ** (inhale ? 1.2 : 0.8) * (inhale ? 0.7 : 1.0);
    const n = r() * 2 - 1;
    out[i] += bp(n, inhale ? 900 + 500 * u : 1300 - 700 * u) * e * 0.8;
    // A soft palate flutter on the in-breath: the snore.
    ph += r.range(28, 34) / SR;
    if (inhale) out[i] += lp(Math.sin(TAU * ph) * (0.5 + 0.5 * Math.sign(Math.sin(TAU * ph))) * (r() * 0.5 + 0.5), 350) * e * 0.35;
  }
  return fadeEdges(room(out, 0.25), 30, 200);
}

// ---------------------------------------------------------------- main

const CUES = [
  ['monsters_iv_rattle', 4, ivRattle, -9],
  ['monsters_inhale', 2, inhale, -6],
  ['monsters_shriek', 3, shriek, -5],
  ['monsters_squeak', 5, squeak, -10],
  ['monsters_lullaby', 2, lullaby, -12],
  ['monsters_grab', 2, grab, -4],
  // sweep 3
  ['monsters_hive_groan', 3, hiveGroan, -7],
  ['monsters_hive_shuffle', 4, hiveShuffle, -12],
  ['monsters_flesh_hit', 3, fleshHit, -3],
  ['monsters_hive_death', 2, hiveDeath, -5],
  ['monsters_sedated_breath', 2, sedatedBreath, -14],
];

function writeWav(file, a) {
  const bytes = a.length * 2;
  const b = Buffer.alloc(44 + bytes);
  b.write('RIFF', 0); b.writeUInt32LE(36 + bytes, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(bytes, 40);
  for (let i = 0; i < a.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, a[i])) * 32767), 44 + i * 2);
  if (!DRY) fs.writeFileSync(file, b);
  return b.length;
}

if (!DRY) fs.mkdirSync(OUT, { recursive: true });
console.log(`monster audio -> ${DRY ? '(dry run)' : path.relative(process.cwd(), OUT)}`);
for (const [name, count, fn, db] of CUES) {
  for (let v = 1; v <= count; v++) {
    const a = normalise(fn(v), db);
    const file = path.join(OUT, `${name}_0${v}.wav`);
    const size = writeWav(file, a);
    console.log(`  ${path.basename(file).padEnd(28)} ${(a.length / SR).toFixed(2)}s  peak ${db} dBFS  ${(size / 1024).toFixed(0)} KB`);
  }
}
