// Generative horror score, fully synthesized with WebAudio (no asset files).
// Three layers sit on their own gain buses that setIntensity() crossfades:
//   A (always on)   sparse detuned piano, sub pulses, distant clangs, a slow pad swell
//   B (hunt, 1)     72 BPM tom pulse, a tension tone gliding up a semitone, gated shimmer
//   C (critical, 2) pulse doubles to 140 BPM with an off-beat answer, cluster stabs, drone
// Everything is placed by a lookahead scheduler in update(); nothing relies on timers.
// Tonal center is D phrygian, so even the "melody" sits a half step from comfortable.

type StingKind = 'scare' | 'flatline' | 'saved';
type Slot = 'piano' | 'sub' | 'clang' | 'pad' | 'tom' | 'tension' | 'shimmer' | 'stab';
interface ToneOpts { end?: number; attack?: number; filter?: number; pan?: number; release?: number }
interface NoiseOpts { type?: BiquadFilterType; end?: number; attack?: number; pan?: number }

const MASTER = 0.35;
const LOOKAHEAD = 0.6;
const SEMI = 2 ** (1 / 12);
const D2 = 73.416, D3 = D2 * 2, D4 = D2 * 4;
const PHRYGIAN = [0, 1, 3, 5, 7, 8, 10] as const; // D Eb F G A Bb C
const st = (root: number, semis: number) => root * SEMI ** semis;
const rnd = (a: number, b: number) => a + Math.random() * (b - a);
const pick = <T>(arr: readonly T[]): T => arr[Math.floor(Math.random() * arr.length)];
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export class Music {
  private ctx: AudioContext;
  private master: GainNode;
  private clip: WaveShaperNode;
  private duck: GainNode;
  private verb: ConvolverNode;
  private a: GainNode; private b: GainNode; private c: GainNode; private fx: GainNode;
  private nb: AudioBuffer | null = null;
  private running = false;
  private intensity = 0;
  private acc = 0;
  private next: Record<Slot, number> = { piano: 0, sub: 0, clang: 0, pad: 0, tom: 0, tension: 0, shimmer: 0, stab: 0 };
  // Continuous voices, rebuilt by start() and released by stop().
  private live: AudioScheduledSourceNode[] = [];
  private padG!: GainNode;
  private tensionOsc!: OscillatorNode;
  private tensionG!: GainNode;
  private shimBP!: BiquadFilterNode;
  private shimG!: GainNode;

  constructor(ctx: AudioContext, out: AudioNode) {
    this.ctx = ctx;
    this.master = ctx.createGain(); this.master.gain.value = MASTER; this.master.connect(out);
    // tanh soft clipper: unity for normal levels, squashes stacked stabs/stings instead of clipping.
    this.clip = ctx.createWaveShaper(); this.clip.oversample = '2x';
    const curve = new Float32Array(2049);
    for (let i = 0; i < curve.length; i++) curve[i] = Math.tanh(i / 1024 - 1);
    this.clip.curve = curve; this.clip.connect(this.master);
    // Layers pass through `duck` (the flatline sting pulls it down); stings bypass it.
    this.duck = ctx.createGain(); this.duck.connect(this.clip);
    // Synthesized hall: a convolver fed with a decaying, darkened noise impulse.
    this.verb = ctx.createConvolver(); this.verb.buffer = this.impulse(3.2, 3); this.verb.connect(this.duck);
    this.a = this.bus(0.6, 1); this.b = this.bus(0.25, 0); this.c = this.bus(0.2, 0);
    this.fx = this.bus(0.4, 1, this.clip);
  }

  /** Gain bus feeding a dry path (ducked unless `dry` is given) plus a reverb send. */
  private bus(wet: number, level: number, dry: AudioNode = this.duck): GainNode {
    const g = this.ctx.createGain(), send = this.ctx.createGain();
    g.gain.value = level; send.gain.value = wet;
    g.connect(dry); g.connect(send); send.connect(this.verb);
    return g;
  }

  private noiseBuffer(): AudioBuffer {
    if (this.nb) return this.nb;
    const c = this.ctx, b = c.createBuffer(1, c.sampleRate * 2, c.sampleRate), d = b.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    return (this.nb = b);
  }

  /** Stereo impulse response: one-pole lowpassed noise under a power-curve decay. */
  private impulse(seconds: number, curve: number): AudioBuffer {
    const c = this.ctx, n = Math.floor(c.sampleRate * seconds), b = c.createBuffer(2, n, c.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = b.getChannelData(ch); let lp = 0;
      for (let i = 0; i < n; i++) { lp += (Math.random() * 2 - 1 - lp) * 0.25; d[i] = lp * (1 - i / n) ** curve; }
    }
    return b;
  }

  /** One-shot oscillator voice: fast attack, exponential decay, optional glide/filter/pan/sustain. */
  private tone(dest: AudioNode, t: number, freq: number, type: OscillatorType, dur: number, vol: number, o: ToneOpts = {}) {
    const c = this.ctx, osc = c.createOscillator(), g = c.createGain();
    osc.type = type; osc.frequency.setValueAtTime(freq, t);
    if (o.end) osc.frequency.exponentialRampToValueAtTime(Math.max(1, o.end), t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(vol, t + (o.attack ?? 0.01));
    if (o.release) g.gain.setValueAtTime(vol, t + dur - o.release);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    let node: AudioNode = osc;
    if (o.filter) { const f = c.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = o.filter; node.connect(f); node = f; }
    if (o.pan !== undefined) { const p = c.createStereoPanner(); p.pan.value = o.pan; node.connect(p); node = p; }
    node.connect(g); g.connect(dest);
    osc.start(t); osc.stop(t + dur + 0.05);
  }

  /** One-shot filtered noise burst from the cached buffer. */
  private noise(dest: AudioNode, t: number, dur: number, vol: number, freq: number, q = 1, o: NoiseOpts = {}) {
    const c = this.ctx, src = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain();
    src.buffer = this.noiseBuffer(); src.loop = true; src.loopStart = Math.random() * 1.5;
    f.type = o.type ?? 'bandpass'; f.Q.value = q; f.frequency.setValueAtTime(freq, t);
    if (o.end) f.frequency.exponentialRampToValueAtTime(o.end, t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(vol, t + (o.attack ?? 0.005));
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    let node: AudioNode = f;
    if (o.pan !== undefined) { const p = c.createStereoPanner(); p.pan.value = o.pan; node.connect(p); node = p; }
    src.connect(f); node.connect(g); g.connect(dest);
    src.start(t, src.loopStart); src.stop(t + dur + 0.05);
  }

  /** Start a continuous source; once it ends (after stop()) its chain is unplugged from the bus. */
  private keep(src: AudioScheduledSourceNode, tail: AudioNode) {
    src.onended = () => tail.disconnect();
    src.start(); this.live.push(src);
  }

  /** Continuous voices: the layer-A pad, layer-B tension tone and shimmer, layer-C drone. */
  private buildVoices() {
    const c = this.ctx;
    // A: three detuned saws under a 300 Hz lowpass; the scheduler swells padG in and out.
    this.padG = c.createGain(); this.padG.gain.value = 0;
    const padLP = c.createBiquadFilter(); padLP.type = 'lowpass'; padLP.frequency.value = 300;
    padLP.connect(this.padG); this.padG.connect(this.a);
    for (const f of [D2, D2 * 1.006, D2 * 0.9945]) {
      const o = c.createOscillator(); o.type = 'sawtooth'; o.frequency.value = f; o.connect(padLP); this.keep(o, this.padG);
    }
    // B: tension saw that glides up a semitone over 8 s (frequency and gain automated per cycle).
    this.tensionOsc = c.createOscillator(); this.tensionOsc.type = 'sawtooth'; this.tensionOsc.frequency.value = D3;
    const tLP = c.createBiquadFilter(); tLP.type = 'lowpass'; tLP.frequency.value = 700; tLP.Q.value = 2;
    this.tensionG = c.createGain(); this.tensionG.gain.value = 0;
    this.tensionOsc.connect(tLP); tLP.connect(this.tensionG); this.tensionG.connect(this.b);
    this.keep(this.tensionOsc, this.tensionG);
    // B: high shimmer, a looping noise source the scheduler gates open in rhythm.
    const ns = c.createBufferSource(); ns.buffer = this.noiseBuffer(); ns.loop = true;
    this.shimBP = c.createBiquadFilter(); this.shimBP.type = 'bandpass'; this.shimBP.frequency.value = 5000; this.shimBP.Q.value = 14;
    this.shimG = c.createGain(); this.shimG.gain.value = 0;
    ns.connect(this.shimBP); this.shimBP.connect(this.shimG); this.shimG.connect(this.b); this.keep(ns, this.shimG);
    // C: steady minor-second drone (D, Eb, a sharp A) with a slow filter wobble.
    const dLP = c.createBiquadFilter(); dLP.type = 'lowpass'; dLP.frequency.value = 260; dLP.Q.value = 1.5;
    const dG = c.createGain(); dG.gain.value = 0.07; dLP.connect(dG); dG.connect(this.c);
    for (const f of [D2, D2 * SEMI, D2 * 1.5 * 1.012]) {
      const o = c.createOscillator(); o.type = 'sawtooth'; o.frequency.value = f; o.connect(dLP); this.keep(o, dG);
    }
    const lfo = c.createOscillator(), lg = c.createGain();
    lfo.frequency.value = 0.05; lg.gain.value = 110; lfo.connect(lg); lg.connect(dLP.frequency); this.keep(lfo, lg);
  }

  /** Begin scheduling. Calling it again while running is a no-op. */
  start() {
    if (this.running) return;
    this.running = true;
    const now = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(now); this.master.gain.setTargetAtTime(MASTER, now, 0.3);
    this.buildVoices();
    this.next = {
      piano: now + rnd(1, 4), sub: now + rnd(4, 10), clang: now + rnd(10, 25), pad: now + rnd(1, 6),
      tom: now + 0.2, tension: now + 0.2, shimmer: now + 0.2, stab: now + 0.5,
    };
  }

  /** Fade out and release the continuous voices; start() may be called again afterwards. */
  stop() {
    if (!this.running) return;
    this.running = false;
    const now = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(now); this.master.gain.setTargetAtTime(0, now, 0.4);
    for (const s of this.live) s.stop(now + 1.5);
    this.live = [];
  }

  /** 0 = exploration dread, 1 = hunted, 2 = critical. Layer buses crossfade with a 1 s time constant. */
  setIntensity(level: number) {
    const l = clamp(Number.isFinite(level) ? level : 0, 0, 2);
    this.intensity = l;
    const cl = clamp(l - 1, 0, 1), now = this.ctx.currentTime;
    this.a.gain.setTargetAtTime(1 - 0.35 * cl, now, 1); // dread thins out under the critical layer
    this.b.gain.setTargetAtTime(Math.min(l, 1), now, 1);
    this.c.gain.setTargetAtTime(cl, now, 1);
  }

  /** Lookahead scheduler: every ~80 ms, fill each slot's timeline out to now + 0.6 s. */
  update(dt: number) {
    if (!this.running) return;
    this.acc += Number.isFinite(dt) && dt > 0 ? dt : 1 / 60;
    if (this.acc < 0.08) return;
    this.acc = 0;
    const horizon = this.ctx.currentTime + LOOKAHEAD;
    const cl = clamp(this.intensity - 1, 0, 1), beat = 60 / (72 + 68 * cl); // 72 BPM hunt -> 140 BPM critical
    // Layer A: always on.
    this.run('piano', horizon, () => rnd(6, 14), t => this.piano(t));
    this.run('sub', horizon, () => rnd(10, 20), t => this.tone(this.a, t, rnd(35, 45), 'sine', 3.5, 0.3, { attack: 1 }));
    this.run('clang', horizon, () => rnd(20, 40), t => this.clang(t));
    this.run('pad', horizon, () => rnd(30, 60), t => this.swell(t));
    // Layer B: skipped once inaudible; run() re-anchors a stale slot when the layer returns.
    if (this.intensity > 0.02 || this.b.gain.value > 0.01) {
      this.run('tom', horizon, () => beat, t => {
        this.tom(this.b, t, rnd(0.28, 0.38));
        if (cl > 0.05) this.tom(this.c, t + beat / 2, rnd(0.2, 0.26)); // off-beat answer lives on the C bus
      });
      this.run('tension', horizon, () => 8 + rnd(0.3, 1.5), t => this.tension(t));
      this.run('shimmer', horizon, () => beat / 2, t => { if (Math.random() < 0.55) this.shimmer(t); });
    }
    // Layer C: dissonant cluster stabs every two bars.
    if (cl > 0.02 || this.c.gain.value > 0.01) this.run('stab', horizon, () => 8 * beat + rnd(-0.15, 0.15), t => this.stab(t));
  }

  /** Advance one slot's clock, scheduling events until it passes the horizon. */
  private run(slot: Slot, horizon: number, gap: () => number, fn: (t: number) => void) {
    const now = this.ctx.currentTime;
    if (this.next[slot] < now - 0.05) this.next[slot] = now + Math.random() * 0.3; // stalled (hidden tab, muted layer)
    while (this.next[slot] < horizon) { fn(this.next[slot]); this.next[slot] += Math.max(0.05, gap()); }
  }

  // ---- Layer A events ----

  /** Detuned piano-like note: three sine partials, fast attack, long decay, sometimes a wrong neighbour. */
  private piano(t: number) {
    const f = st(D3, pick(PHRYGIAN) + 12 * Math.floor(rnd(0, 2.3))) * rnd(0.996, 1.004);
    const pan = rnd(-0.7, 0.7), dur = rnd(3, 5);
    for (const [m, amp] of [[1, 1], [2.004, 0.35], [3.009, 0.12]] as const) {
      this.tone(this.a, t, f * m, 'sine', dur / Math.sqrt(m), 0.16 * amp, { attack: 0.004, pan });
    }
    if (Math.random() < 0.3) { // a half step off, a beat late: the tune that is not quite right
      this.tone(this.a, t + rnd(0.35, 0.9), f * (Math.random() < 0.5 ? SEMI : 1 / SEMI), 'sine', dur * 0.7, 0.09, { attack: 0.004, pan: -pan * 0.5 });
    }
  }

  /** Distant metallic clang: resonant noise burst plus a ringing partial and an inharmonic overtone. */
  private clang(t: number) {
    const f = rnd(900, 2600), pan = rnd(-0.8, 0.8);
    this.noise(this.a, t, 0.3, 0.07, f, 18, { pan });
    this.tone(this.a, t, f * rnd(0.99, 1.01), 'sine', 2.5, 0.045, { pan });
    this.tone(this.a, t, f * 2.76, 'sine', 1.1, 0.015, { pan });
  }

  /** Pad swell: ease the pad gain up, hold, ease it back down. */
  private swell(t: number) {
    const g = this.padG.gain;
    g.setTargetAtTime(0.1, t, 3.5);
    g.setTargetAtTime(0, t + rnd(8, 14), 4);
  }

  // ---- Layer B events ----

  /** Tom-like pulse: sine dropping 80 -> 50 Hz with a dull beater click. */
  private tom(dest: AudioNode, t: number, vol: number) {
    this.tone(dest, t, 80, 'sine', 0.35, vol, { end: 50, attack: 0.004 });
    this.noise(dest, t, 0.04, vol * 0.35, 180, 1, { type: 'lowpass' });
  }

  /** Tension tone cycle: glide up a semitone over 8 s while swelling, then cut and reset. */
  private tension(t: number) {
    const base = pick([D3, st(D2, 19), st(D2, 20)]); // D3, A3, Bb3
    const f = this.tensionOsc.frequency, g = this.tensionG.gain;
    f.setValueAtTime(base, t); f.linearRampToValueAtTime(base * SEMI, t + 8);
    g.setValueAtTime(0.0001, t); g.linearRampToValueAtTime(0.09, t + 7.6); g.linearRampToValueAtTime(0.0001, t + 8);
  }

  /** Shimmer gate: retune the narrow bandpass and open the gain for a few tens of ms. */
  private shimmer(t: number) {
    const g = this.shimG.gain;
    this.shimBP.frequency.setValueAtTime(rnd(4000, 6000), t);
    g.setValueAtTime(0.0001, t); g.linearRampToValueAtTime(0.05, t + 0.008); g.exponentialRampToValueAtTime(0.0001, t + rnd(0.05, 0.12));
  }

  // ---- Layer C events ----

  /** Cluster stab: D Eb A Bb (two minor seconds) as short lowpassed saws, sometimes doubled. */
  private stab(t: number) {
    const up = Math.random() < 0.5 ? 0 : 1; // whole cluster sometimes sits a semitone higher
    const chord = [0, 1, 7, 8].map(s => st(D3, s + up));
    const hit = (tt: number, vol: number) => {
      for (const f of chord) this.tone(this.c, tt, f * rnd(0.997, 1.003), 'sawtooth', 0.32, vol, { attack: 0.003, filter: 1400 });
      this.noise(this.c, tt, 0.06, vol * 1.5, 900, 0.8, { type: 'lowpass' });
    };
    hit(t, 0.1);
    if (Math.random() < 0.35) hit(t + rnd(0.18, 0.25), 0.07);
  }

  // ---- One-shots ----

  /** Stings bypass the duck bus so they always cut through the layers. */
  sting(kind: StingKind) {
    const t = this.ctx.currentTime, fx = this.fx;
    if (kind === 'scare') {
      // Loud minor-second cluster over a sub thud, with a rising noise whoosh: about 1.2 s.
      for (const s of [0, 1, 6, 7]) this.tone(fx, t, st(D4, s) * rnd(0.995, 1.005), 'sawtooth', 1.2, 0.2, { attack: 0.003, filter: 2600 });
      this.tone(fx, t, 95, 'sine', 0.5, 0.6, { end: 38, attack: 0.003 });
      this.noise(fx, t, 1.2, 0.45, 400, 1.2, { end: 3800, attack: 0.35 });
    } else if (kind === 'flatline') {
      // Dry, steady 1 kHz monitor tone for 3 s while every layer ducks out from under it.
      this.tone(this.clip, t, 1000, 'sine', 3, 0.22, { attack: 0.005, release: 0.08 });
      this.duck.gain.setTargetAtTime(0.1, t, 0.15);
      this.duck.gain.setTargetAtTime(1, t + 3, 1.2);
    } else {
      // Someone made it: a D major add9 voicing, soft attack, fading over 3 s through the hall.
      [0, 7, 12, 16, 19, 26].forEach((s, i) => this.tone(fx, t + i * 0.04, st(D3, s) * rnd(0.998, 1.002), i < 2 ? 'triangle' : 'sine', 3, 0.11, { attack: 0.15 }));
    }
  }
}
