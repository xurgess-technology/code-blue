// All sound is synthesized with WebAudio: no asset files needed.

interface ToneOpts { end?: number; attack?: number; filter?: number; delay?: number }

export class AudioSys {
  private ctx: AudioContext | null = null;
  private master!: GainNode;
  private nb: AudioBuffer | null = null;
  private danger = 0;
  private heartTimer = 0;

  /** The context and master bus, for the music module. Null until start(). */
  get context(): AudioContext | null { return this.ctx; }
  get bus(): AudioNode | null { return this.ctx ? this.master : null; }

  start() {
    if (this.ctx) { if (this.ctx.state === 'suspended') void this.ctx.resume(); return; }
    const Ctor = window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    this.ctx = new Ctor();
    this.master = this.ctx.createGain();
    this.master.gain.value = 0.55;
    this.master.connect(this.ctx.destination);
    this.drone();
  }

  private noiseBuffer(): AudioBuffer {
    if (this.nb) return this.nb;
    const c = this.ctx!;
    const b = c.createBuffer(1, c.sampleRate * 2, c.sampleRate);
    const d = b.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    return (this.nb = b);
  }

  /** Low ambient rumble plus vent hiss that runs the whole game. */
  private drone() {
    const c = this.ctx!;
    const g = c.createGain(); g.gain.value = 0.08;
    const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 160;
    g.connect(lp); lp.connect(this.master);
    const voices: [number, OscillatorType, number][] = [[38, 'sine', 0.6], [57.3, 'triangle', 0.4], [38.6, 'sawtooth', 0.12]];
    for (const [f, type, vol] of voices) {
      const o = c.createOscillator(); o.type = type; o.frequency.value = f;
      const og = c.createGain(); og.gain.value = vol;
      o.connect(og); og.connect(g); o.start();
    }
    const lfo = c.createOscillator(); lfo.frequency.value = 0.07;
    const lg = c.createGain(); lg.gain.value = 0.04;
    lfo.connect(lg); lg.connect(g.gain); lfo.start();
    const ns = c.createBufferSource(); ns.buffer = this.noiseBuffer(); ns.loop = true;
    const bp = c.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 320; bp.Q.value = 0.6;
    const ng = c.createGain(); ng.gain.value = 0.02;
    ns.connect(bp); bp.connect(ng); ng.connect(this.master); ns.start();
  }

  private tone(freq: number, type: OscillatorType, dur: number, vol: number, o: ToneOpts = {}) {
    const c = this.ctx; if (!c || vol <= 0.001) return;
    const t = c.currentTime + (o.delay ?? 0);
    const osc = c.createOscillator(); osc.type = type;
    osc.frequency.setValueAtTime(freq, t);
    if (o.end) osc.frequency.exponentialRampToValueAtTime(Math.max(1, o.end), t + dur);
    const g = c.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(vol, t + (o.attack ?? 0.01));
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    let node: AudioNode = osc;
    if (o.filter) { const f = c.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = o.filter; osc.connect(f); node = f; }
    node.connect(g); g.connect(this.master);
    osc.start(t); osc.stop(t + dur + 0.05);
  }

  private noise(dur: number, vol: number, freq: number, type: BiquadFilterType = 'bandpass', delay = 0, q = 1) {
    const c = this.ctx; if (!c || vol <= 0.001) return;
    const t = c.currentTime + delay;
    const src = c.createBufferSource(); src.buffer = this.noiseBuffer();
    src.loop = true; src.loopStart = Math.random() * 1.5;
    const f = c.createBiquadFilter(); f.type = type; f.frequency.value = freq; f.Q.value = q;
    const g = c.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(vol, t + 0.005);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    src.connect(f); f.connect(g); g.connect(this.master);
    src.start(t, src.loopStart); src.stop(t + dur + 0.05);
  }

  // Every cue takes a volume factor so sounds from other players and monsters fade with distance.
  step(sprint: boolean, v = 1) { this.noise(0.06, (sprint ? 0.14 : 0.08) * v, 700 + Math.random() * 400, 'bandpass', 0, 1.5); }
  pickup(v = 1) { this.tone(620, 'square', 0.07, 0.07 * v); this.tone(930, 'square', 0.1, 0.07 * v, { delay: 0.07 }); }
  deliver(v = 1) {
    this.tone(523, 'triangle', 0.15, 0.12 * v);
    this.tone(659, 'triangle', 0.15, 0.12 * v, { delay: 0.12 });
    this.tone(784, 'triangle', 0.3, 0.12 * v, { delay: 0.24 });
  }
  hurt(v = 1) { this.noise(0.35, 0.5 * v, 220, 'lowpass'); this.tone(160, 'sawtooth', 0.35, 0.3 * v, { end: 50, filter: 600 }); }
  screech(v = 1) { this.tone(1100, 'sawtooth', 0.7, 0.22 * v, { end: 220, filter: 2400 }); this.noise(0.6, 0.18 * v, 1600, 'bandpass', 0, 0.7); }
  skitter(v = 1) { for (let i = 0; i < 4; i++) this.noise(0.03, 0.09 * v, 2400 + Math.random() * 1600, 'bandpass', i * 0.055, 3); }
  thud(v = 1) { this.tone(48, 'sine', 0.35, 0.5 * v, { end: 28 }); this.noise(0.12, 0.25 * v, 140, 'lowpass'); }
  beep(v = 1) { this.tone(880, 'sine', 0.1, 0.1 * v); }
  click(v = 1) { this.noise(0.02, 0.12 * v, 3200, 'highpass'); }
  shove(v = 1) { this.noise(0.12, 0.3 * v, 500, 'lowpass'); this.tone(120, 'triangle', 0.15, 0.2 * v, { end: 60 }); }
  stepDone(v = 1) { this.tone(659, 'triangle', 0.2, 0.12 * v); this.tone(988, 'triangle', 0.35, 0.12 * v, { delay: 0.15 }); }
  complication(v = 1) { this.tone(330, 'square', 0.12, 0.08 * v); this.tone(311, 'square', 0.18, 0.08 * v, { delay: 0.12 }); }
  punch(v = 1) { this.noise(0.05, 0.3 * v, 2000, 'bandpass', 0, 2); this.tone(220, 'square', 0.08, 0.1 * v, { delay: 0.05 }); }
  revive(v = 1) { [392, 523, 659, 784].forEach((f, i) => this.tone(f, 'sine', 0.5, 0.12 * v, { delay: i * 0.1 })); this.noise(1.2, 0.08 * v, 900, 'bandpass', 0, 0.5); }
  flatline(v = 1) { this.tone(880, 'sine', 2.5, 0.18 * v, { attack: 0.005 }); }
  win(v = 1) { [523, 659, 784, 1047].forEach((f, i) => this.tone(f, 'triangle', 0.5, 0.14 * v, { delay: i * 0.15 })); }

  /** Play a named cue by string, used for events that arrive over the network. */
  cue(name: string, v = 1) {
    switch (name) {
      case 'step': this.step(false, v); break;
      case 'sprint': this.step(true, v); break;
      case 'pickup': this.pickup(v); break;
      case 'deliver': this.deliver(v); break;
      case 'hurt': this.hurt(v); break;
      case 'screech': this.screech(v); break;
      case 'skitter': this.skitter(v); break;
      case 'thud': this.thud(v); break;
      case 'beep': this.beep(v); break;
      case 'shove': this.shove(v); break;
      case 'stepDone': this.stepDone(v); break;
      case 'complication': this.complication(v); break;
      case 'punch': this.punch(v); break;
      case 'revive': this.revive(v); break;
      case 'flatline': this.flatline(v); break;
      case 'win': this.win(v); break;
    }
  }

  setDanger(d: number) { this.danger = d; }

  /** Heartbeat that speeds up as monsters get close. */
  update(dt: number) {
    if (!this.ctx) return;
    if (this.danger < 0.05) return;
    this.heartTimer -= dt;
    if (this.heartTimer <= 0) {
      this.heartTimer = 1.3 - this.danger * 0.85;
      this.tone(58, 'sine', 0.2, 0.15 + 0.45 * this.danger, { end: 32 });
      this.tone(52, 'sine', 0.18, 0.1 + 0.35 * this.danger, { end: 28, delay: 0.17 });
    }
  }
}
