#!/usr/bin/env node
// tools/gen_audio.mjs — offline synthesiser for Code Blue's sound and music.
//
// The browser build (code-blue/src/audio.ts + music.ts) synthesised everything live
// with WebAudio. Godot has no equivalent, so this script ports the *character* of
// those cues and bakes them into 16-bit PCM WAV files under audio/.
//
//   node tools/gen_audio.mjs            # write audio/sfx/*.wav and audio/music/*.wav
//   node tools/gen_audio.mjs --check    # render + report, do not write
//
// Everything is deterministic: one seeded PRNG stream per asset, so re-running
// produces byte-identical files. Safe to re-run; existing files are overwritten.
//
// Music stems are *sample-exact loops*: every voice is written into the loop buffer
// modulo its length, continuous oscillators are snapped to integer multiples of
// 1/loopSeconds, and the reverb network is run over the buffer several times so its
// state converges to the periodic steady state. No crossfade is needed and the
// join is mathematically seamless.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 44100;
const TAU = Math.PI * 2;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_SFX = path.join(ROOT, 'audio', 'sfx');
const OUT_MUS = path.join(ROOT, 'audio', 'music');
const DRY_RUN = process.argv.includes('--check');

// ---------------------------------------------------------------- determinism

/** mulberry32: tiny, fast, fully deterministic from a 32-bit seed. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
/** Hash a name to a seed so each asset gets its own reproducible stream. */
function seedOf(name) {
  let h = 2166136261;
  for (let i = 0; i < name.length; i++) { h ^= name.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function rngFor(name) {
  const r = mulberry32(seedOf(name));
  r.range = (a, b) => a + r() * (b - a);
  r.pick = (arr) => arr[Math.floor(r() * arr.length) % arr.length];
  r.chance = (p) => r() < p;
  return r;
}

// A single shared white-noise table, generated once from a fixed seed. Voices read
// it at a (deterministic) random offset, exactly like the WebAudio version looped a
// 2-second noise buffer from a random loopStart.
const NOISE_LEN = SR * 4;
const NOISE = (() => {
  const r = mulberry32(0xc0de51ee);
  const n = new Float32Array(NOISE_LEN);
  for (let i = 0; i < n.length; i++) n[i] = r() * 2 - 1;
  return n;
})();

// ---------------------------------------------------------------- oscillators

/** PolyBLEP step correction; keeps saw/square from aliasing into hash. */
function blep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}
function osc(type, p, dt) {
  switch (type) {
    case 'sine': return Math.sin(TAU * p);
    case 'triangle': return 1 - 4 * Math.abs(p - 0.5);
    case 'sawtooth': return (2 * p - 1) - blep(p, dt);
    case 'square': {
      let v = p < 0.5 ? 1 : -1;
      v -= blep(p, dt);
      v += blep((p + 0.5) % 1, dt);
      return v;
    }
    default: return Math.sin(TAU * p);
  }
}

// ---------------------------------------------------------------- filters

/** RBJ biquad coefficients. bandpass is the constant-0-dB-peak form WebAudio uses. */
function biquadCoeffs(type, f0, Q) {
  f0 = Math.min(Math.max(f0, 10), SR * 0.45);
  Q = Math.max(0.0001, Q);
  const w0 = (TAU * f0) / SR, cw = Math.cos(w0), sw = Math.sin(w0), al = sw / (2 * Q);
  let b0, b1, b2, a0, a1, a2;
  if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
  else if (type === 'highpass') { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
  else { b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; }
  return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
}
/** Stateful biquad. Call with (x) for a fixed cutoff, or (x, f0) to sweep it. */
function makeBiquad(type, f0, Q) {
  let c = biquadCoeffs(type, f0, Q), cur = f0;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x, f) => {
    if (f !== undefined && Math.abs(f - cur) > 0.5) { c = biquadCoeffs(type, f, Q); cur = f; }
    const y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

// ---------------------------------------------------------------- envelopes

/**
 * WebAudio-shaped one-shot envelope: silence -> linear ramp to `vol` over `attack`,
 * optional hold, then an exponential fall to -80 dB by `dur`.
 */
function makeEnv(dur, vol, attack, release) {
  const D = Math.max(1, dur * SR);
  const A = Math.max(1, attack * SR);
  const R = (release || 0) * SR;
  const hold = R > 0 ? Math.max(A, D - R) : A;
  return (i) => {
    if (i >= D) return 0;
    if (i < A) return vol * (i / A);
    if (i < hold) return vol;
    return vol * Math.pow(0.0001, (i - hold) / Math.max(1, D - hold));
  };
}

// ---------------------------------------------------------------- voices

/** One-shot oscillator voice. Mirrors AudioSys.tone()/Music.tone(). */
function renderTone({ freq, end = 0, type = 'sine', dur, vol = 1, attack = 0.01, release = 0, filter = 0, filterQ = 1 }) {
  const pad = Math.ceil(0.06 * SR);
  const D = Math.max(1, dur * SR);
  const N = Math.ceil(D) + pad;
  const out = new Float32Array(N);
  const env = makeEnv(dur, vol, attack, release);
  const ratio = end > 0 ? Math.max(1, end) / freq : 1;
  const flt = filter ? makeBiquad('lowpass', filter, filterQ) : null;
  let p = 0;
  for (let i = 0; i < N; i++) {
    const f = freq * Math.pow(ratio, Math.min(i, D) / D);
    const dt = f / SR;
    let s = osc(type, p, dt) * env(i);
    p += dt; if (p >= 1) p -= 1;
    out[i] = flt ? flt(s) : s;
  }
  return out;
}

/** One-shot filtered noise burst. Mirrors AudioSys.noise()/Music.noise(). */
function renderNoise({ dur, vol = 1, freq, endFreq = 0, type = 'bandpass', q = 1, attack = 0.005, rnd }) {
  const pad = Math.ceil(0.06 * SR);
  const D = Math.max(1, dur * SR);
  const N = Math.ceil(D) + pad;
  const out = new Float32Array(N);
  const env = makeEnv(dur, vol, attack, 0);
  const flt = makeBiquad(type, freq, q);
  const ratio = endFreq > 0 ? endFreq / freq : 1;
  const off = Math.floor((rnd ? rnd() : 0) * (NOISE_LEN - N - 1));
  for (let i = 0; i < N; i++) {
    const f = endFreq > 0 ? freq * Math.pow(ratio, Math.min(i, D) / D) : undefined;
    out[i] = flt(NOISE[off + i] * env(i), f);
  }
  return out;
}

// ---------------------------------------------------------------- tracks

/**
 * A multi-channel render target. `wrap` tracks are loops: anything written past the
 * end folds back to the start, which is what makes the stems seamless.
 */
class Track {
  constructor(seconds, nch, wrap = false, tailSeconds = 6) {
    this.n = Math.round(seconds * SR);
    this.len = wrap ? this.n : this.n + Math.round(tailSeconds * SR);
    this.nch = nch;
    this.wrap = wrap;
    this.ch = [];
    for (let c = 0; c < nch; c++) this.ch.push(new Float32Array(this.len));
  }
  /** Equal-power pan gains; a mono track ignores pan. */
  gains(pan = 0) {
    if (this.nch === 1) return [1];
    const a = ((Math.max(-1, Math.min(1, pan)) + 1) * Math.PI) / 4;
    return [Math.cos(a), Math.sin(a)];
  }
  mix(tSec, data, pan = 0, gain = 1) {
    const g = this.gains(pan);
    const start = Math.round(tSec * SR);
    for (let i = 0; i < data.length; i++) {
      let idx = start + i;
      if (this.wrap) idx = ((idx % this.n) + this.n) % this.n;
      else if (idx < 0 || idx >= this.len) continue;
      const v = data[i] * gain;
      for (let c = 0; c < this.nch; c++) this.ch[c][idx] += v * g[c];
    }
  }
  peak() {
    let p = 0;
    for (const c of this.ch) for (let i = 0; i < c.length; i++) { const a = Math.abs(c[i]); if (a > p) p = a; }
    return p;
  }
  scale(k) { for (const c of this.ch) for (let i = 0; i < c.length; i++) c[i] *= k; }
}

/**
 * A voice destination: a dry track plus a reverb send, so every cue can be placed
 * "in the hall" by the same amount the WebAudio bus used.
 */
class Bus {
  constructor(dry, send, wet) { this.dry = dry; this.send = send; this.wet = wet; }
  tone(t, opts, pan = 0, gain = 1) { this.emit(t, renderTone(opts), pan, gain); }
  noise(t, opts, pan = 0, gain = 1) { this.emit(t, renderNoise(opts), pan, gain); }
  emit(t, data, pan = 0, gain = 1) {
    this.dry.mix(t, data, pan, gain);
    if (this.send) this.send.mix(t, data, pan, gain * this.wet);
  }
}

// ---------------------------------------------------------------- reverb

const COMB = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const ALLP = [556, 441, 341, 225];
const SPREAD = 23;

/** Freeverb-style hall. Long, dark, and cheap enough to run several passes. */
class Reverb {
  constructor(room = 0.88, damp = 0.28, width = 1) {
    this.fb = room * 0.28 + 0.7;
    this.d1 = damp * 0.4; this.d2 = 1 - this.d1;
    this.width = width;
    this.combs = [[], []];
    this.allps = [[], []];
    for (let ch = 0; ch < 2; ch++) {
      const off = ch * SPREAD;
      for (const t of COMB) this.combs[ch].push({ b: new Float32Array(t + off), i: 0, s: 0 });
      for (const t of ALLP) this.allps[ch].push({ b: new Float32Array(t + off), i: 0 });
    }
  }
  step(ch, x) {
    let out = 0;
    for (const c of this.combs[ch]) {
      const y = c.b[c.i];
      c.s = y * this.d2 + c.s * this.d1;
      c.b[c.i] = x + c.s * this.fb;
      if (++c.i >= c.b.length) c.i = 0;
      out += y;
    }
    out *= 0.12;
    for (const a of this.allps[ch]) {
      const y = a.b[a.i];
      a.b[a.i] = out + y * 0.5;
      if (++a.i >= a.b.length) a.i = 0;
      out = y - out;
    }
    return out;
  }
  /**
   * Render `send` into a new wet track. For a looping send the network is run
   * `passes` times over the same periodic input so its internal state settles into
   * the periodic steady state; only the final pass is kept. That is what lets the
   * reverb tail wrap across the loop point without a seam.
   */
  render(send) {
    const wet = new Track(send.len / SR, 2, send.wrap);
    const passes = send.wrap ? 4 : 1;
    const inL = send.ch[0], inR = send.nch > 1 ? send.ch[1] : send.ch[0];
    for (let p = 0; p < passes; p++) {
      const keep = p === passes - 1;
      for (let i = 0; i < send.len; i++) {
        const l = this.step(0, inL[i]);
        const r = this.step(1, inR[i]);
        if (keep) {
          wet.ch[0][i] = l * this.width + r * (1 - this.width);
          wet.ch[1][i] = r * this.width + l * (1 - this.width);
        }
      }
    }
    return wet;
  }
}

// ---------------------------------------------------------------- output helpers

const tanh = Math.tanh;
function softclip(t, drive = 1) {
  for (const c of t.ch) for (let i = 0; i < c.length; i++) c[i] = tanh(c[i] * drive);
}
function mixTracks(dst, src, gain = 1) {
  for (let c = 0; c < dst.nch; c++) {
    const a = dst.ch[c], b = src.ch[Math.min(c, src.nch - 1)];
    for (let i = 0; i < Math.min(a.length, b.length); i++) a[i] += b[i] * gain;
  }
}
const dbfs = (peak) => (peak > 0 ? 20 * Math.log10(peak) : -Infinity);
const toGain = (db) => Math.pow(10, db / 20);

/** Trim a one-shot to its tail and fade the last few ms so it cannot click. */
function trim(t, floorDb = -60, fadeMs = 4) {
  const thresh = t.peak() * toGain(floorDb);
  let last = 0;
  for (let c = 0; c < t.nch; c++) {
    const a = t.ch[c];
    for (let i = a.length - 1; i > last; i--) if (Math.abs(a[i]) > thresh) { last = i; break; }
  }
  const n = Math.min(t.len, last + Math.ceil(0.01 * SR));
  const fade = Math.min(Math.ceil((fadeMs / 1000) * SR), n);
  const out = new Track(n / SR, t.nch, false, 0);
  for (let c = 0; c < t.nch; c++) {
    for (let i = 0; i < n; i++) {
      const g = i >= n - fade ? (n - i) / fade : 1;
      out.ch[c][i] = t.ch[c][i] * g;
    }
  }
  return out;
}

function writeWav(file, t) {
  const nch = t.nch, n = t.ch[0].length, bytes = n * nch * 2;
  const buf = Buffer.alloc(44 + bytes);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + bytes, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(nch, 22); buf.writeUInt32LE(SR, 24);
  buf.writeUInt32LE(SR * nch * 2, 28); buf.writeUInt16LE(nch * 2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(bytes, 40);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < nch; c++) {
      let v = t.ch[c][i];
      v = v > 1 ? 1 : v < -1 ? -1 : v;
      buf.writeInt16LE(Math.round(v * 32767), o);
      o += 2;
    }
  }
  if (!DRY_RUN) fs.writeFileSync(file, buf);
  return buf.length;
}

const LOG = [];
function emitFile(dir, name, t, targetDb) {
  if (targetDb !== null && targetDb !== undefined) {
    const p = t.peak();
    if (p > 0) t.scale(toGain(targetDb) / p);
  }
  const file = path.join(dir, name);
  const bytes = writeWav(file, t);
  const secs = t.ch[0].length / SR;
  const peak = t.peak();
  // Loop seam: for a wrap track the buffer is periodic, so compare the wrap-around
  // step (last -> first) against the biggest ordinary step inside the buffer.
  let seam = '';
  if (t.wrap) {
    let jump = 0, worst = 0;
    for (let c = 0; c < t.nch; c++) {
      jump = Math.max(jump, Math.abs(t.ch[c][0] - t.ch[c][t.n - 1]));
      for (let i = 1; i < t.n; i++) {
        const d = Math.abs(t.ch[c][i] - t.ch[c][i - 1]);
        if (d > worst) worst = d;
      }
    }
    seam = `  seam=${jump.toExponential(2)} (max internal step ${worst.toExponential(2)})`;
  }
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  const line = `  ${rel.padEnd(30)} ${secs.toFixed(2).padStart(6)}s  ${t.nch === 1 ? 'mono  ' : 'stereo'}  peak ${dbfs(peak).toFixed(2).padStart(6)} dBFS  ${(bytes / 1024).toFixed(0).padStart(6)} KB${seam}`;
  LOG.push({ line, bytes });
  console.log(line);
}

// ================================================================ SFX
// Ported one for one from code-blue/src/audio.ts. The WebAudio version scaled every
// cue by a distance volume; here the cue is baked at full level and the game's
// AudioStreamPlayer3D does the distance work.

const SFX_TARGET_DB = -3;

function sfxTrack(seconds = 4) { return new Track(seconds, 1, false, 0.5); }

function build_step(variant, sprint) {
  const rnd = rngFor(`${sprint ? 'sprint' : 'step'}${variant}`);
  const t = sfxTrack(0.4);
  const bus = new Bus(t, null, 0);
  bus.noise(0, { dur: 0.06, vol: sprint ? 0.14 : 0.08, freq: 700 + rnd() * 400, q: 1.5, rnd });
  // A touch of heel body so the footstep reads as a boot on lino, not just hiss.
  bus.tone(0, { freq: rnd.range(95, 130), end: 60, type: 'sine', dur: 0.05, vol: sprint ? 0.05 : 0.03, attack: 0.002 });
  return t;
}

function build_skitter(variant) {
  const rnd = rngFor(`skitter${variant}`);
  const t = sfxTrack(0.6);
  const bus = new Bus(t, null, 0);
  for (let i = 0; i < 4; i++) {
    bus.noise(i * 0.055 + rnd.range(-0.008, 0.008), { dur: 0.03, vol: 0.09, freq: 2400 + rnd() * 1600, q: 3, rnd });
  }
  return t;
}

// Launch printout (scripts/launch_screen.gd): a dot-matrix head printing one line. Needle strikes
// grouped into characters and words, over the carriage motor.
function build_print_line(variant) {
  const rnd = rngFor(`print_line${variant}`);
  const len = rnd.range(0.24, 0.36);
  const t = sfxTrack(len + 0.15), b = new Bus(t, null, 0);
  let at = 0.005;
  while (at < len) {
    const chars = 2 + Math.floor(rnd() * 5);
    for (let c = 0; c < chars && at < len; c++) {
      for (let k = 0; k < 4; k++) {
        b.noise(at, { dur: 0.0035, vol: rnd.range(0.09, 0.15), freq: rnd.range(2600, 3800), q: 2.2, attack: 0.0004, rnd });
        at += rnd.range(0.004, 0.0058);
      }
      at += rnd.range(0.003, 0.008);
    }
    at += rnd.range(0.014, 0.03);
  }
  b.tone(0, { freq: rnd.range(92, 110), type: 'sawtooth', dur: len, vol: 0.02, attack: 0.02, release: 0.03, filter: 380 });
  return t;
}

const SFX_BUILDERS = {
  print_feed: () => {
    const rnd = rngFor('print_feed');
    const t = sfxTrack(0.4), b = new Bus(t, null, 0);
    for (let i = 0; i < 5; i++) b.noise(i * 0.03, { dur: 0.01, vol: 0.12, freq: 1300, q: 2, attack: 0.001, rnd });
    b.tone(0, { freq: 64, end: 86, type: 'triangle', dur: 0.16, vol: 0.07, attack: 0.01 });
    return t;
  },
  print_stamp: () => {
    const rnd = rngFor('print_stamp');
    const t = sfxTrack(0.5), b = new Bus(t, null, 0);
    b.noise(0, { dur: 0.018, vol: 0.4, freq: 2400, q: 1, attack: 0.0005, rnd });
    b.tone(0.004, { freq: 110, end: 48, type: 'sine', dur: 0.16, vol: 0.5, attack: 0.001 });
    b.noise(0.004, { dur: 0.09, vol: 0.25, freq: 380, type: 'lowpass', rnd });
    return t;
  },
  // A fax machine connecting: calling tones, the answer tone, the negotiation warble, line hiss.
  fax_connect: () => {
    const rnd = rngFor('fax_connect');
    const t = sfxTrack(3.6), b = new Bus(t, null, 0);
    b.tone(0.0, { freq: 1100, type: 'sine', dur: 0.45, vol: 0.06, attack: 0.005, release: 0.02 });
    b.tone(0.95, { freq: 2100, type: 'sine', dur: 0.9, vol: 0.055, attack: 0.01, release: 0.05 });
    let at = 1.95;
    for (let i = 0; i < 26; i++) {
      b.tone(at, { freq: rnd.chance(0.5) ? 1650 : 1850, type: 'sine', dur: 0.034, vol: 0.045, attack: 0.002, release: 0.004 });
      at += 0.0333;
    }
    b.noise(2.85, { dur: 0.7, vol: 0.05, freq: 1500, endFreq: 2600, q: 0.8, attack: 0.03, rnd });
    b.tone(2.85, { freq: 1300, type: 'sine', dur: 0.5, vol: 0.02, attack: 0.02, release: 0.1 });
    return t;
  },
  pickup: () => {
    const t = sfxTrack(0.4), b = new Bus(t, null, 0);
    b.tone(0, { freq: 620, type: 'square', dur: 0.07, vol: 0.07 });
    b.tone(0.07, { freq: 930, type: 'square', dur: 0.1, vol: 0.07 });
    return t;
  },
  deliver: () => {
    const t = sfxTrack(1.0), b = new Bus(t, null, 0);
    b.tone(0, { freq: 523, type: 'triangle', dur: 0.15, vol: 0.12 });
    b.tone(0.12, { freq: 659, type: 'triangle', dur: 0.15, vol: 0.12 });
    b.tone(0.24, { freq: 784, type: 'triangle', dur: 0.3, vol: 0.12 });
    return t;
  },
  hurt: () => {
    const rnd = rngFor('hurt');
    const t = sfxTrack(0.8), b = new Bus(t, null, 0);
    b.noise(0, { dur: 0.35, vol: 0.5, freq: 220, type: 'lowpass', rnd });
    b.tone(0, { freq: 160, end: 50, type: 'sawtooth', dur: 0.35, vol: 0.3, filter: 600 });
    return t;
  },
  screech: () => {
    const rnd = rngFor('screech');
    const t = sfxTrack(1.4), b = new Bus(t, null, 0);
    b.tone(0, { freq: 1100, end: 220, type: 'sawtooth', dur: 0.7, vol: 0.22, filter: 2400 });
    b.noise(0, { dur: 0.6, vol: 0.18, freq: 1600, q: 0.7, rnd });
    return t;
  },
  thud: () => {
    const rnd = rngFor('thud');
    const t = sfxTrack(0.8), b = new Bus(t, null, 0);
    b.tone(0, { freq: 48, end: 28, type: 'sine', dur: 0.35, vol: 0.5 });
    b.noise(0, { dur: 0.12, vol: 0.25, freq: 140, type: 'lowpass', rnd });
    return t;
  },
  beep: () => {
    const t = sfxTrack(0.3), b = new Bus(t, null, 0);
    b.tone(0, { freq: 880, type: 'sine', dur: 0.1, vol: 0.1 });
    return t;
  },
  click: () => {
    const rnd = rngFor('click');
    const t = sfxTrack(0.15), b = new Bus(t, null, 0);
    b.noise(0, { dur: 0.02, vol: 0.12, freq: 3200, type: 'highpass', rnd });
    return t;
  },
  shove: () => {
    const rnd = rngFor('shove');
    const t = sfxTrack(0.5), b = new Bus(t, null, 0);
    b.noise(0, { dur: 0.12, vol: 0.3, freq: 500, type: 'lowpass', rnd });
    b.tone(0, { freq: 120, end: 60, type: 'triangle', dur: 0.15, vol: 0.2 });
    return t;
  },
  step_done: () => {
    const t = sfxTrack(0.8), b = new Bus(t, null, 0);
    b.tone(0, { freq: 659, type: 'triangle', dur: 0.2, vol: 0.12 });
    b.tone(0.15, { freq: 988, type: 'triangle', dur: 0.35, vol: 0.12 });
    return t;
  },
  complication: () => {
    const t = sfxTrack(0.6), b = new Bus(t, null, 0);
    b.tone(0, { freq: 330, type: 'square', dur: 0.12, vol: 0.08 });
    b.tone(0.12, { freq: 311, type: 'square', dur: 0.18, vol: 0.08 });
    return t;
  },
  punch: () => {
    const rnd = rngFor('punch');
    const t = sfxTrack(0.4), b = new Bus(t, null, 0);
    b.noise(0, { dur: 0.05, vol: 0.3, freq: 2000, q: 2, rnd });
    b.tone(0.05, { freq: 220, type: 'square', dur: 0.08, vol: 0.1 });
    return t;
  },
  revive: () => {
    const rnd = rngFor('revive');
    const t = sfxTrack(2.4), b = new Bus(t, null, 0);
    [392, 523, 659, 784].forEach((f, i) => b.tone(i * 0.1, { freq: f, type: 'sine', dur: 0.5, vol: 0.12 }));
    b.noise(0, { dur: 1.2, vol: 0.08, freq: 900, q: 0.5, rnd });
    return t;
  },
  flatline: () => {
    const t = sfxTrack(3.0), b = new Bus(t, null, 0);
    b.tone(0, { freq: 880, type: 'sine', dur: 2.5, vol: 0.18, attack: 0.005, release: 0.06 });
    return t;
  },
  win: () => {
    const t = sfxTrack(1.6), b = new Bus(t, null, 0);
    [523, 659, 784, 1047].forEach((f, i) => b.tone(i * 0.15, { freq: f, type: 'triangle', dur: 0.5, vol: 0.14 }));
    return t;
  },
  // One heartbeat pair. audio_manager.gd re-triggers it and scales rate + volume with
  // danger, which is how AudioSys.update() did it (1.3 - danger*0.85 second period).
  heartbeat: () => {
    const t = sfxTrack(0.7), b = new Bus(t, null, 0);
    b.tone(0, { freq: 58, end: 32, type: 'sine', dur: 0.2, vol: 0.6 });
    b.tone(0.17, { freq: 52, end: 28, type: 'sine', dur: 0.18, vol: 0.45 });
    return t;
  },
};

// ================================================================ ambience
// AudioSys.drone(): three low voices under a 160 Hz lowpass with a slow LFO, plus a
// bandpassed vent hiss. Extended here with far-off building noises so a 40 s loop
// does not read as a static tone.

const AMB_SECONDS = 40;

function buildAmbience() {
  const rnd = rngFor('ambience');
  const n = AMB_SECONDS * SR;
  const t = new Track(AMB_SECONDS, 1, true);
  // Snap every continuous frequency to a whole number of cycles per loop so the
  // buffer is exactly periodic.
  const snap = (f) => Math.max(1, Math.round(f * AMB_SECONDS)) / AMB_SECONDS;

  // --- low rumble: sine + triangle + saw through a 160 Hz lowpass, LFO on level.
  const rumble = new Float32Array(n);
  const voices = [[snap(38), 'sine', 0.6], [snap(57.3), 'triangle', 0.4], [snap(38.6), 'sawtooth', 0.12]];
  const lfoF = snap(0.07);
  for (const [f, type, vol] of voices) {
    let p = 0; const dt = f / SR;
    for (let i = 0; i < n; i++) { rumble[i] += osc(type, p, dt) * vol; p += dt; if (p >= 1) p -= 1; }
  }
  for (let i = 0; i < n; i++) rumble[i] *= 0.08 + 0.04 * Math.sin(TAU * lfoF * (i / SR));
  periodicFilter(rumble, () => makeBiquad('lowpass', 160, 0.7), 2);
  for (let i = 0; i < n; i++) t.ch[0][i] += rumble[i];

  // --- vent hiss: looping noise through a wide bandpass at 320 Hz.
  const hiss = new Float32Array(n);
  for (let i = 0; i < n; i++) hiss[i] = NOISE[i % NOISE_LEN];
  // Crossfade the noise so the hiss itself is periodic (the table is not a whole loop).
  const xf = Math.round(0.5 * SR);
  for (let i = 0; i < xf; i++) {
    const k = i / xf;
    hiss[i] = hiss[i] * k + NOISE[(n + i) % NOISE_LEN] * (1 - k);
  }
  periodicFilter(hiss, () => makeBiquad('bandpass', 320, 0.6), 2);
  for (let i = 0; i < n; i++) t.ch[0][i] += hiss[i] * 0.09;

  // --- distant building: far clangs, pipe groans, a lift somewhere below.
  const bus = new Bus(t, null, 0);
  let at = rnd.range(1, 5);
  while (at < AMB_SECONDS) {
    const kind = rnd();
    if (kind < 0.4) {
      const f = rnd.range(700, 2200);
      bus.noise(at, { dur: 0.25, vol: 0.02, freq: f, q: 16, rnd });
      bus.tone(at, { freq: f * rnd.range(0.99, 1.01), type: 'sine', dur: 1.8, vol: 0.012 });
    } else if (kind < 0.75) {
      bus.tone(at, { freq: rnd.range(70, 130), end: rnd.range(45, 80), type: 'sawtooth', dur: rnd.range(2.5, 4.5), vol: 0.035, attack: 0.8, filter: 260 });
    } else {
      bus.noise(at, { dur: rnd.range(1.2, 2.2), vol: 0.03, freq: 180, endFreq: 90, type: 'lowpass', q: 0.8, attack: 0.4, rnd });
    }
    at += rnd.range(3.5, 8);
  }
  return t;
}

/** Run a filter over a periodic buffer repeatedly so its state converges; in place. */
function periodicFilter(arr, make, passes) {
  const f = make();
  let out = null;
  for (let p = 0; p < passes; p++) {
    const keep = p === passes - 1;
    if (keep) out = new Float32Array(arr.length);
    for (let i = 0; i < arr.length; i++) {
      const y = f(arr[i]);
      if (keep) out[i] = y;
    }
  }
  arr.set(out);
}

// ================================================================ music
// Ported from code-blue/src/music.ts. D phrygian, three layers that must sit on top
// of each other, so all three stems share one 60 s loop length and one tempo grid:
//   hunt     = 72 BPM  (0.8333 s beat, 72 beats in 60 s)
//   critical = 144 BPM (exactly double, so the off-beat answers lock to the toms)

const LOOP = 60;
const BEAT = 60 / 72;
const SEMI = Math.pow(2, 1 / 12);
const D2 = 73.416, D3 = D2 * 2, D4 = D2 * 4;
const PHRYGIAN = [0, 1, 3, 5, 7, 8, 10];
const st = (root, semis) => root * Math.pow(SEMI, semis);
const msnap = (f) => Math.max(1, Math.round(f * LOOP)) / LOOP;

function musicTrack() { return new Track(LOOP, 2, true); }

/** Continuous detuned oscillator stack written straight into a periodic buffer. */
function stackInto(arr, freqs, type, filterHz, filterQ, gain) {
  const n = arr.length;
  const tmp = new Float32Array(n);
  for (const f0 of freqs) {
    const f = msnap(f0), dt = f / SR;
    let p = 0;
    for (let i = 0; i < n; i++) { tmp[i] += osc(type, p, dt); p += dt; if (p >= 1) p -= 1; }
  }
  periodicFilter(tmp, () => makeBiquad('lowpass', filterHz, filterQ), 2);
  for (let i = 0; i < n; i++) arr[i] += tmp[i] * gain;
}

/**
 * setTargetAtTime-style envelope over a looping timeline. Events are (t, target, tau);
 * the one-pole is run twice around the loop so the curve is periodic.
 */
function targetEnvelope(seconds, events, start = 0) {
  const n = Math.round(seconds * SR);
  const out = new Float32Array(n);
  const evs = events.slice().sort((a, b) => a[0] - b[0]);
  let v = start;
  for (let pass = 0; pass < 2; pass++) {
    let ei = 0, target = evs.length ? evs[evs.length - 1][1] : start, tau = 1;
    for (let i = 0; i < n; i++) {
      const tSec = i / SR;
      while (ei < evs.length && evs[ei][0] <= tSec) { target = evs[ei][1]; tau = evs[ei][2]; ei++; }
      v += (target - v) * (1 - Math.exp(-1 / (tau * SR)));
      if (pass === 1) out[i] = v;
    }
  }
  return out;
}

/** Layer A — exploration dread. */
function buildDread() {
  const rnd = rngFor('dread');
  const dry = musicTrack(), send = musicTrack();
  const bus = new Bus(dry, send, 0.6);

  // Sparse detuned "piano": three sine partials, fast attack, long tail, and a 30%
  // chance of a half-step neighbour arriving a beat late.
  for (let t = rnd.range(1, 4); t < LOOP; t += rnd.range(6, 14)) {
    const f = st(D3, rnd.pick(PHRYGIAN) + 12 * Math.floor(rnd.range(0, 2.3))) * rnd.range(0.996, 1.004);
    const pan = rnd.range(-0.7, 0.7), dur = rnd.range(3, 5);
    for (const [m, amp] of [[1, 1], [2.004, 0.35], [3.009, 0.12]]) {
      bus.tone(t, { freq: f * m, type: 'sine', dur: dur / Math.sqrt(m), vol: 0.16 * amp, attack: 0.004 }, pan);
    }
    if (rnd.chance(0.3)) {
      bus.tone(t + rnd.range(0.35, 0.9), { freq: f * (rnd.chance(0.5) ? SEMI : 1 / SEMI), type: 'sine', dur: dur * 0.7, vol: 0.09, attack: 0.004 }, -pan * 0.5);
    }
  }
  // Sub pulses.
  for (let t = rnd.range(4, 10); t < LOOP; t += rnd.range(10, 20)) {
    bus.tone(t, { freq: rnd.range(35, 45), type: 'sine', dur: 3.5, vol: 0.3, attack: 1 });
  }
  // Distant metal.
  for (let t = rnd.range(10, 25); t < LOOP; t += rnd.range(20, 40)) {
    const f = rnd.range(900, 2600), pan = rnd.range(-0.8, 0.8);
    bus.noise(t, { dur: 0.3, vol: 0.07, freq: f, q: 18, rnd }, pan);
    bus.tone(t, { freq: f * rnd.range(0.99, 1.01), type: 'sine', dur: 2.5, vol: 0.045 }, pan);
    bus.tone(t, { freq: f * 2.76, type: 'sine', dur: 1.1, vol: 0.015 }, pan);
  }
  // Slow pad swell: three detuned saws at D2 under a 300 Hz lowpass, gain eased in
  // and out by the swell schedule.
  const swells = [];
  for (let t = rnd.range(1, 6); t < LOOP; t += rnd.range(30, 60)) {
    swells.push([t, 0.1, 3.5]);
    swells.push([(t + rnd.range(8, 14)) % LOOP, 0, 4]);
  }
  const padGain = targetEnvelope(LOOP, swells, 0.02);
  const pad = new Float32Array(dry.n);
  stackInto(pad, [D2, D2 * 1.006, D2 * 0.9945], 'sawtooth', 300, 0.707, 1);
  for (let i = 0; i < pad.length; i++) pad[i] *= padGain[i];
  for (let i = 0; i < pad.length; i++) { dry.ch[0][i] += pad[i]; dry.ch[1][i] += pad[i]; send.ch[0][i] += pad[i] * 0.6; send.ch[1][i] += pad[i] * 0.6; }

  return finishStem(dry, send);
}

/** Layer B — something is hunting. */
function buildHunt() {
  const rnd = rngFor('hunt');
  const dry = musicTrack(), send = musicTrack();
  const bus = new Bus(dry, send, 0.25);

  // 72 BPM tom pulse.
  for (let i = 0; i < Math.round(LOOP / BEAT); i++) {
    const t = i * BEAT, vol = rnd.range(0.28, 0.38);
    bus.tone(t, { freq: 80, end: 50, type: 'sine', dur: 0.35, vol, attack: 0.004 });
    bus.noise(t, { dur: 0.04, vol: vol * 0.35, freq: 180, type: 'lowpass', rnd });
  }
  // Tension tone: a saw gliding up a semitone over 8 s while swelling, then cut.
  // Rendered as self-contained voices so each cycle wraps cleanly.
  for (let t = 0; t < LOOP; t += 8 + rnd.range(0.3, 1.5)) {
    const base = rnd.pick([D3, st(D2, 19), st(D2, 20)]);
    bus.emit(t, tensionVoice(base), rnd.range(-0.25, 0.25));
  }
  // Gated shimmer on the eighths.
  for (let i = 0; i < Math.round((LOOP / BEAT) * 2); i++) {
    if (!rnd.chance(0.55)) continue;
    const t = (i * BEAT) / 2;
    bus.noise(t, { dur: rnd.range(0.05, 0.12), vol: 0.05, freq: rnd.range(4000, 6000), q: 14, attack: 0.008, rnd }, rnd.range(-0.6, 0.6));
  }
  return finishStem(dry, send);
}

/** The 8-second tension glide as one rendered voice (linear pitch + linear swell). */
function tensionVoice(base) {
  const dur = 8, D = dur * SR, N = D + Math.ceil(0.05 * SR);
  const out = new Float32Array(N);
  const flt = makeBiquad('lowpass', 700, 2);
  let p = 0;
  for (let i = 0; i < N; i++) {
    const k = Math.min(i, D) / D;
    const f = base + (base * SEMI - base) * k;
    const dt = f / SR;
    // Swell to 0.09 over 7.6 s, then snap back to silence by 8 s.
    const g = k < 0.95 ? 0.09 * (k / 0.95) : 0.09 * (1 - (k - 0.95) / 0.05);
    out[i] = flt(osc('sawtooth', p, dt)) * Math.max(0, g);
    p += dt; if (p >= 1) p -= 1;
  }
  return out;
}

/** Layer C — surgery / critical. */
function buildCritical() {
  const rnd = rngFor('critical');
  const dry = musicTrack(), send = musicTrack();
  const bus = new Bus(dry, send, 0.2);
  const half = BEAT / 2; // 144 BPM, exactly double the hunt grid

  // Off-beat tom answers that interlock with the hunt stem's downbeats.
  for (let i = 0; i < Math.round(LOOP / BEAT); i++) {
    const t = i * BEAT + half, vol = rnd.range(0.2, 0.26);
    bus.tone(t, { freq: 80, end: 50, type: 'sine', dur: 0.35, vol, attack: 0.004 });
    bus.noise(t, { dur: 0.04, vol: vol * 0.35, freq: 180, type: 'lowpass', rnd });
  }
  // Dissonant minor-second cluster stabs every two bars (8 beats).
  for (let i = 0; i * 8 * BEAT < LOOP; i++) {
    const t = i * 8 * BEAT;
    const up = rnd.chance(0.5) ? 0 : 1;
    const chord = [0, 1, 7, 8].map((s) => st(D3, s + up));
    const hit = (tt, vol) => {
      for (const f of chord) bus.tone(tt, { freq: f * rnd.range(0.997, 1.003), type: 'sawtooth', dur: 0.32, vol, attack: 0.003, filter: 1400 });
      bus.noise(tt, { dur: 0.06, vol: vol * 1.5, freq: 900, type: 'lowpass', q: 0.8, rnd });
    };
    hit(t, 0.1);
    if (rnd.chance(0.35)) hit(t + rnd.range(0.18, 0.25), 0.07);
  }
  // Steady minor-second drone (D, Eb, a sharp A) with a slow filter wobble.
  const drone = new Float32Array(dry.n);
  const freqs = [D2, D2 * SEMI, D2 * 1.5 * 1.012].map(msnap);
  const tmp = new Float32Array(dry.n);
  for (const f of freqs) {
    const dt = f / SR; let p = 0;
    for (let i = 0; i < tmp.length; i++) { tmp[i] += osc('sawtooth', p, dt); p += dt; if (p >= 1) p -= 1; }
  }
  // 0.05 Hz wobble = exactly 3 cycles across the 60 s loop.
  const lfo = msnap(0.05);
  const wob = makeBiquad('lowpass', 260, 1.5);
  for (let pass = 0; pass < 2; pass++) {
    for (let i = 0; i < tmp.length; i++) {
      const f = 260 + 110 * Math.sin(TAU * lfo * (i / SR));
      const y = wob(tmp[i], f);
      if (pass === 1) drone[i] = y;
    }
  }
  for (let i = 0; i < drone.length; i++) {
    const v = drone[i] * 0.07;
    dry.ch[0][i] += v; dry.ch[1][i] += v;
    send.ch[0][i] += v * 0.2; send.ch[1][i] += v * 0.2;
  }
  return finishStem(dry, send);
}

/** Dry + convolved-style hall, soft clipped exactly like the WebAudio WaveShaper. */
function finishStem(dry, send) {
  const wet = new Reverb(0.88, 0.28, 1).render(send);
  mixTracks(dry, wet, 1);
  softclip(dry, 1);
  return dry;
}

// --- stings -------------------------------------------------------------------

function buildSting(kind) {
  const rnd = rngFor(`sting_${kind}`);
  const secs = kind === 'scare' ? 4.5 : 6.0;
  const dry = new Track(secs, 2, false, 0);
  const send = new Track(secs, 2, false, 0);
  const bus = new Bus(dry, send, 0.4);
  if (kind === 'scare') {
    for (const s of [0, 1, 6, 7]) {
      bus.tone(0, { freq: st(D4, s) * rnd.range(0.995, 1.005), type: 'sawtooth', dur: 1.2, vol: 0.2, attack: 0.003, filter: 2600 }, rnd.range(-0.5, 0.5));
    }
    bus.tone(0, { freq: 95, end: 38, type: 'sine', dur: 0.5, vol: 0.6, attack: 0.003 });
    bus.noise(0, { dur: 1.2, vol: 0.45, freq: 400, endFreq: 3800, q: 1.2, attack: 0.35, rnd });
  } else if (kind === 'flatline') {
    // Dry monitor tone; audio_manager ducks the music under it rather than a bus.
    bus.tone(0, { freq: 1000, type: 'sine', dur: 3, vol: 0.22, attack: 0.005, release: 0.08 }, 0, 1);
  } else {
    [0, 7, 12, 16, 19, 26].forEach((s, i) => {
      bus.tone(i * 0.04, { freq: st(D3, s) * rnd.range(0.998, 1.002), type: i < 2 ? 'triangle' : 'sine', dur: 3, vol: 0.11, attack: 0.15 }, rnd.range(-0.4, 0.4));
    });
  }
  const wet = new Reverb(kind === 'flatline' ? 0.6 : 0.88, 0.3, 1).render(send);
  mixTracks(dry, wet, kind === 'flatline' ? 0.3 : 1);
  softclip(dry, 1);
  return trim(dry, -62, 8);
}

// ================================================================ main

function main() {
  for (const d of [OUT_SFX, OUT_MUS]) if (!DRY_RUN) fs.mkdirSync(d, { recursive: true });
  console.log(`Code Blue audio generator — ${DRY_RUN ? 'DRY RUN (nothing written)' : 'writing to ' + path.relative(process.cwd(), path.join(ROOT, 'audio'))}`);
  console.log('\nSFX (mono, 44100 Hz, normalised to -3 dBFS, trimmed):');

  for (let v = 1; v <= 4; v++) emitFile(OUT_SFX, `step_0${v}.wav`, trim(build_step(v, false)), SFX_TARGET_DB);
  for (let v = 1; v <= 4; v++) emitFile(OUT_SFX, `sprint_0${v}.wav`, trim(build_step(v, true)), SFX_TARGET_DB);
  for (let v = 1; v <= 3; v++) emitFile(OUT_SFX, `skitter_0${v}.wav`, trim(build_skitter(v)), SFX_TARGET_DB);
  for (let v = 1; v <= 4; v++) emitFile(OUT_SFX, `print_line_0${v}.wav`, trim(build_print_line(v)), SFX_TARGET_DB);
  for (const [name, fn] of Object.entries(SFX_BUILDERS)) {
    emitFile(OUT_SFX, `${name}.wav`, trim(fn()), SFX_TARGET_DB);
  }

  console.log('\nAmbience (mono, seamless loop):');
  emitFile(OUT_SFX, 'ambience.wav', buildAmbience(), -6);

  console.log('\nMusic stems (stereo, 60.00 s seamless loop, shared gain so the three layer coherently):');
  const stems = { dread: buildDread(), hunt: buildHunt(), critical: buildCritical() };
  // A mix decision, not a normalisation: the hunt layer is all short tom transients,
  // so at matched peaks it sits ~9 dB below dread and never announces itself. These
  // trims put the three at roughly equal perceived weight when fully layered.
  const STEM_TRIM_DB = { dread: 0, hunt: 7, critical: 1.5 };
  for (const [name, t] of Object.entries(stems)) t.scale(toGain(STEM_TRIM_DB[name]));
  // Then ONE normalisation factor across all three. Normalising each stem on its own
  // would destroy the balance the crossfader relies on.
  let loudest = 0;
  for (const t of Object.values(stems)) loudest = Math.max(loudest, t.peak());
  const k = toGain(-4.5) / loudest;
  for (const t of Object.values(stems)) t.scale(k);
  for (const [name, t] of Object.entries(stems)) emitFile(OUT_MUS, `${name}.wav`, t, null);

  console.log('\nStings (stereo, one-shot):');
  for (const kind of ['scare', 'flatline', 'saved']) {
    emitFile(OUT_MUS, `sting_${kind}.wav`, buildSting(kind), -3);
  }

  const total = LOG.reduce((a, b) => a + b.bytes, 0);
  console.log(`\n${LOG.length} files, ${(total / 1048576).toFixed(2)} MB total.`);
  if (total > 42 * 1048576) { console.error('ERROR: over the 40 MB budget.'); process.exit(1); }
}

main();
