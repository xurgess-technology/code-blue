// The whole simulation lives here and it is 2D: a tile grid, circles, line of sight, A* and rules.
// The host runs simulate(); every player owns their own surgeon's movement; clients mirror the
// host's world through snapshots. Solo play is hosting with nobody connected.
import { GameMap, TILE, Vec, addClutter } from './map';
import { Input } from './input';
import { AudioSys } from './audio';
import { PATIENTS, PatientDef, ToolKind, TOOL_KINDS, toolsFor, scaledStep, SurgeryStep } from './patients';
import type { GameEvent, Phase, PlayerState, Snapshot } from './net/protocol';

export { TOOL_KINDS };
export type { ToolKind, Phase };
export const CARRY_CAP = 2;
export const CONE_HALF = Math.PI / 6.5;
export const CONE_RANGE = 9 * TILE;
export const GLOW_RANGE = 2.4 * TILE;
export const LOOK_SENS = 0.0022;
export const PLAYER_COLORS = [0x3d8f80, 0x8f3d6e, 0x8f7a3d, 0x3d5f8f, 0x6e8f3d, 0x8f4a3d];
const WALK_SPEED = 3.0 * TILE;
const SPRINT_SPEED = 4.7 * TILE;
const INTERACT_RANGE = 1.7 * TILE;
const TABLE_RANGE = 3.0 * TILE;
const SNAP_END_SECONDS = 7;

export interface Tool {
  id: number; kind: ToolKind; x: number; y: number;
  state: 'floor' | 'carried' | 'delivered';
  carrier: number; seen: boolean; bob: number; cool: number;
}
export type MonsterKind = 'nurse' | 'lurker' | 'orderly';
export interface Monster {
  id: number; kind: MonsterKind; x: number; y: number; r: number;
  state: 'wander' | 'chase' | 'stunned';
  path: Vec[]; goal: Vec | null; lastSeen: Vec | null; targetId: number;
  lostTimer: number; replan: number; stun: number; facing: number;
  frozen: boolean; anim: number; sound: number; stuck: number; forcePath: number;
  calm: number; moving: boolean; shoved: boolean;
}
export interface Player {
  id: number; name: string; col: number; local: boolean;
  x: number; y: number; r: number; facing: number; pitch: number;
  hp: number; maxHp: number; stamina: number;
  sprinting: boolean; moving: boolean; carried: Tool[];
  invuln: number; flashlight: boolean; step: number; knock: Vec;
  alive: boolean; deadTime: number;
  operating: boolean; interact: boolean;
  shoveCount: number; shoveSeen: number; dropCount: number; dropSeen: number; shoveCd: number;
}
export type MapSource = (seed: number) => { rows: string[]; lights: Vec[] };

function shuffle<T>(a: T[], rng: () => number = Math.random): T[] {
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}
const tileOf = (v: number) => Math.floor(v / TILE);
const wrapAngle = (a: number) => Math.atan2(Math.sin(a), Math.cos(a));
const dist = (a: Vec, b: Vec) => Math.hypot(a.x - b.x, a.y - b.y);
function mulberry32(seed: number) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class Game {
  map = new GameMap();
  seed = 0;
  shift = 1;
  players = new Map<number, Player>();
  localId = 0;
  tools: Tool[] = [];
  monsters: Monster[] = [];
  patient: PatientDef | null = null;
  patientIndex = -1;
  vitals = 100;
  stepIndex = 0;
  stepProgress = 0;
  punch = 0;
  pod = 0;
  endTimer = 0;
  phase: Phase = 'menu';
  time = 0;
  tick = 0;
  message = '';
  messageTimer = 0;
  hurt = 0;
  shake = 0;
  danger = 0;
  paused = false;
  /** True when this instance runs the world (host or solo). */
  isHost = true;
  /** Solo runs stop when paused; a host with friends keeps the world going. */
  solo = true;
  /** Host-side event queue, drained into snapshots by the session after each update. */
  events: GameEvent[] = [];
  /** Dead players watch this teammate. */
  spectating = 0;
  glow: Vec[] = [];
  cone: Vec[] = [];
  lastComplication = 0;
  private alertTimer = 0;
  private beepTimer = 0;
  private lockedPrev = false;
  private shoveCdLocal = 0;

  constructor(public audio: AudioSys, public mapSource: MapSource) {}

  // ---------- setup ----------

  get local(): Player | undefined { return this.players.get(this.localId); }
  get spectated(): Player | undefined {
    const me = this.local;
    if (me?.alive) return me;
    return this.players.get(this.spectating) ?? [...this.players.values()].find((p) => p.alive) ?? me;
  }
  get step(): SurgeryStep | null {
    if (!this.patient || this.stepIndex >= this.patient.steps.length) return null;
    return scaledStep(this.patient.steps[this.stepIndex], this.shift);
  }
  get nearTable(): boolean {
    const me = this.spectated;
    return !!me && dist(me, this.map.table) < TABLE_RANGE;
  }

  /** Spawn points are picked by player id so host and clients agree without talking. */
  private spawnFor(id: number): Vec {
    return this.map.spawns[(Math.max(1, id) - 1) % this.map.spawns.length];
  }

  addPlayer(id: number, name: string, local = false): Player {
    const spawn = this.spawnFor(id);
    const p: Player = {
      id, name, col: PLAYER_COLORS[this.players.size % PLAYER_COLORS.length], local,
      x: spawn.x, y: spawn.y, r: 11, facing: -Math.PI / 2, pitch: 0,
      hp: 3, maxHp: 3, stamina: 1, sprinting: false, moving: false, carried: [],
      invuln: 0, flashlight: true, step: 0, knock: { x: 0, y: 0 },
      alive: true, deadTime: 0, operating: false, interact: false,
      shoveCount: 0, shoveSeen: 0, dropCount: 0, dropSeen: 0, shoveCd: 0,
    };
    this.players.set(id, p);
    if (local) this.localId = id;
    return p;
  }

  removePlayer(id: number) {
    const p = this.players.get(id);
    if (!p) return;
    for (const t of p.carried) { const s = this.scatterSpot(p); t.x = s.x; t.y = s.y; t.state = 'floor'; t.carrier = -1; }
    this.players.delete(id);
    if (this.phase !== 'menu') this.say(`${p.name} left the shift.`, 3);
  }

  /** Build the hospital for a shift and put everyone in the clock-in room. */
  startLobby(seed: number, shift: number) {
    this.seed = seed;
    this.shift = shift;
    let built: { rows: string[]; lights: Vec[] };
    try { built = this.mapSource(seed); } catch (e) { console.error('map generation failed, using fallback', e); built = { rows: [], lights: [] }; }
    this.map = built.rows.length ? new GameMap(addClutter(built.rows, seed), { lights: built.lights }) : new GameMap();
    this.tools = [];
    this.monsters = [];
    this.patient = null; this.patientIndex = -1;
    this.vitals = 100; this.stepIndex = 0; this.stepProgress = 0;
    this.punch = 0; this.pod = 0; this.endTimer = 0;
    this.phase = 'lobby';
    this.paused = false;
    this.hurt = 0; this.shake = 0;
    for (const p of this.players.values()) {
      const s = this.spawnFor(p.id);
      p.x = s.x; p.y = s.y; p.facing = -Math.PI / 2; p.pitch = 0;
      p.alive = true; p.hp = p.maxHp; p.carried = []; p.invuln = 0; p.knock = { x: 0, y: 0 }; p.operating = false;
    }
    this.computeLight();
    this.say(`Shift ${shift}. Hold E at the time clock when everyone is ready.`, 6);
  }

  /** Host only: the patient arrives, tools scatter, monsters wake up. */
  beginShift() {
    const rng = mulberry32(this.seed * 31 + this.shift * 7);
    this.patientIndex = Math.floor(rng() * PATIENTS.length);
    this.patient = PATIENTS[this.patientIndex];
    const spots = shuffle([...this.map.toolSpawns], rng);
    this.tools = toolsFor(this.patient).map((kind, i): Tool => {
      const s = spots[i % spots.length] ?? this.randomFloorPoint();
      return { id: i, kind, x: s.x, y: s.y, state: 'floor', carrier: -1, seen: false, bob: rng() * 6, cool: 0 };
    });
    this.monsters = [];
    const roster: MonsterKind[] = ['nurse', 'orderly'];
    if (this.shift >= 2) roster.push('lurker');
    if (this.shift >= 3) roster.push('nurse');
    if (this.shift >= 4) roster.push('orderly');
    for (let s = 5; s <= this.shift; s++) roster.push(s % 2 ? 'lurker' : 'nurse');
    const extra = Math.floor((this.players.size - 1) / 2);
    for (let i = 0; i < extra; i++) roster.push('nurse');
    const spawns = shuffle([...this.map.monsterSpawns]);
    roster.forEach((kind, i) => {
      const at = spawns[i % Math.max(1, spawns.length)] ?? this.randomFloorFar(this.map.spawns[0], 18);
      this.monsters.push({
        id: i, kind, x: at.x, y: at.y, r: kind === 'orderly' ? 16 : kind === 'nurse' ? 12 : 11, state: 'wander', path: [], goal: null,
        lastSeen: null, targetId: -1, lostTimer: 0, replan: 0, stun: 0, facing: 0, frozen: false, anim: Math.random() * 10,
        sound: 0, stuck: 0, forcePath: 0, calm: 0, moving: false, shoved: false,
      });
    });
    this.vitals = 100; this.stepIndex = 0; this.stepProgress = 0;
    this.punch = 0; this.pod = 0;
    this.phase = 'shift';
    this.emit({ type: 'sound', name: 'punch' });
    this.say(`Incoming: ${this.patient.name}. ${this.patient.blurb}`, 7);
  }

  say(text: string, secs = 3, broadcast = true) {
    this.message = text;
    this.messageTimer = secs;
    if (broadcast && this.isHost && !this.solo) this.events.push({ type: 'msg', text, secs });
  }

  emit(e: GameEvent) {
    this.events.push(e);
    this.playEvent(e);
  }

  /** Local reaction to an event, whether it was raised here or arrived in a snapshot. */
  playEvent(e: GameEvent) {
    const me = this.spectated;
    const volAt = (x?: number, y?: number) => (x === undefined || y === undefined || !me ? 1 : Math.max(0.05, 1 - Math.hypot(x - me.x, y - me.y) / (16 * TILE)));
    switch (e.type) {
      case 'sound': this.audio.cue(e.name, volAt(e.x, e.y)); break;
      case 'msg': this.message = e.text; this.messageTimer = e.secs; break;
      case 'hit': {
        const p = this.players.get(e.player);
        if (p) p.hp = e.hp;
        if (e.player === this.localId) { const p2 = this.local!; p2.knock.x = e.kx; p2.knock.y = e.ky; p2.invuln = 3; this.hurt = 1; this.shake = 1; this.audio.hurt(); }
        else this.audio.hurt(0.5);
        break;
      }
      case 'shoved': {
        if (e.player === this.localId) { const p = this.local!; p.knock.x = e.kx; p.knock.y = e.ky; this.shake = 0.5; }
        this.audio.shove(volAt());
        break;
      }
      case 'respawn': {
        const p = this.players.get(e.player);
        if (p) { p.x = e.x; p.y = e.y; p.alive = true; }
        this.audio.revive(0.8);
        break;
      }
    }
  }

  // ---------- frame update ----------

  update(dt: number, input: Input) {
    if (this.phase === 'menu') { input.takeLook(); return; }
    // Pause: P toggles it, losing pointer lock (Esc) forces it, clicking back into the game lifts it.
    const regained = input.locked && !this.lockedPrev;
    this.lockedPrev = input.locked;
    if (regained) this.paused = false;
    if (input.justPressed('KeyP')) this.paused = !this.paused;
    if (input.lockEverAcquired && !input.locked) this.paused = true;
    if (this.paused && this.solo) { input.takeLook(); return; }

    this.time += dt;
    const me = this.local;
    if (me) {
      if (this.paused) input.takeLook();
      else if (me.alive) this.updateLocalPlayer(me, dt, input);
      else this.updateSpectator(me, dt, input);
    }
    this.computeLight();
    if (this.isHost) this.simulate(dt);
    this.updateFx(dt);
  }

  private updateLocalPlayer(p: Player, dt: number, input: Input) {
    const look = input.takeLook();
    p.facing = wrapAngle(p.facing + look.dx * LOOK_SENS);
    p.pitch = Math.max(-1.25, Math.min(1.25, p.pitch - look.dy * LOOK_SENS));

    let fwd = 0, strafe = 0;
    if (input.down('KeyW') || input.down('ArrowUp')) fwd += 1;
    if (input.down('KeyS') || input.down('ArrowDown')) fwd -= 1;
    if (input.down('KeyD') || input.down('ArrowRight')) strafe += 1;
    if (input.down('KeyA') || input.down('ArrowLeft')) strafe -= 1;
    const len = Math.hypot(fwd, strafe);
    p.interact = input.down('KeyE');
    p.operating = p.interact && this.phase === 'shift' && dist(p, this.map.table) < TABLE_RANGE;
    p.moving = len > 0 && !p.operating;
    if (len > 0) { fwd /= len; strafe /= len; }
    const cf = Math.cos(p.facing), sf = Math.sin(p.facing);
    const ix = fwd * cf - strafe * sf, iy = fwd * sf + strafe * cf;

    p.sprinting = p.moving && (input.down('ShiftLeft') || input.down('ShiftRight')) && p.stamina > 0;
    if (p.sprinting) p.stamina = Math.max(0, p.stamina - dt / 4.5);
    else p.stamina = Math.min(1, p.stamina + dt / 5);
    const speed = p.operating ? 0 : p.sprinting ? SPRINT_SPEED : WALK_SPEED;
    const vx = ix * speed + p.knock.x, vy = iy * speed + p.knock.y;
    const decay = Math.pow(0.002, dt);
    p.knock.x *= decay; p.knock.y *= decay;
    this.moveCircle(p, vx * dt, vy * dt);

    if (input.justPressed('KeyF')) { p.flashlight = !p.flashlight; this.audio.click(); }
    this.shoveCdLocal = Math.max(0, this.shoveCdLocal - dt);
    if (input.justPressed('KeyQ') && this.shoveCdLocal <= 0) { this.shoveCdLocal = 2; p.shoveCount++; }
    if (input.justPressed('KeyG') && p.carried.length) p.dropCount++;
    if (p.moving) {
      p.step += dt * (p.sprinting ? 3 : 1.9);
      if (p.step >= 1) { p.step = 0; this.audio.step(p.sprinting); }
    }
  }

  private updateSpectator(p: Player, dt: number, input: Input) {
    input.takeLook();
    p.moving = false; p.sprinting = false; p.operating = false; p.interact = false;
    const living = [...this.players.values()].filter((q) => q.alive && q.id !== p.id);
    if (!living.length) return;
    if (!living.some((q) => q.id === this.spectating)) this.spectating = living[0].id;
    if (input.clicked || input.justPressed('Space')) {
      const i = living.findIndex((q) => q.id === this.spectating);
      this.spectating = living[(i + 1) % living.length].id;
    }
    void dt;
  }

  private moveCircle(e: { x: number; y: number; r: number }, dx: number, dy: number) {
    const m = this.map;
    if (dx !== 0) { const nx = e.x + dx; if (!m.circleHitsSolid(nx, e.y, e.r)) e.x = nx; }
    if (dy !== 0) { const ny = e.y + dy; if (!m.circleHitsSolid(e.x, ny, e.r)) e.y = ny; }
  }

  /** Light polygons for the local surgeon (fog of war on the minimap). */
  computeLight() {
    const p = this.spectated, m = this.map;
    this.glow = []; this.cone = [];
    if (!p) return;
    const EXT = 12;
    for (let i = 0; i < 48; i++) {
      const a = (i / 48) * Math.PI * 2, cx = Math.cos(a), cy = Math.sin(a);
      const h = m.raycast(p.x, p.y, cx, cy, GLOW_RANGE, true);
      const d = Math.min(h.dist + EXT, GLOW_RANGE);
      this.glow.push({ x: p.x + cx * d, y: p.y + cy * d });
    }
    if (p.flashlight) {
      for (let i = 0; i <= 72; i++) {
        const a = p.facing - CONE_HALF + (i / 72) * CONE_HALF * 2, cx = Math.cos(a), cy = Math.sin(a);
        const h = m.raycast(p.x, p.y, cx, cy, CONE_RANGE, true);
        const d = Math.min(h.dist + EXT, CONE_RANGE);
        this.cone.push({ x: p.x + cx * d, y: p.y + cy * d });
      }
    }
  }

  /** Is a world point inside some living surgeon's light with clear line of sight? */
  isLit(x: number, y: number): boolean {
    for (const p of this.players.values()) {
      if (!p.alive) continue;
      const dx = x - p.x, dy = y - p.y, d = Math.hypot(dx, dy);
      if (d <= GLOW_RANGE + 8) { if (this.map.hasLOS(p.x, p.y, x, y)) return true; continue; }
      if (!p.flashlight || d > CONE_RANGE) continue;
      let diff = Math.abs(Math.atan2(dy, dx) - p.facing);
      diff = Math.min(diff, Math.PI * 2 - diff);
      if (diff > CONE_HALF + 0.05) continue;
      if (this.map.hasLOS(p.x, p.y, x, y)) return true;
    }
    return false;
  }

  // ---------- host simulation ----------

  simulate(dt: number) {
    this.tick++;
    for (const p of this.players.values()) {
      p.invuln = Math.max(0, p.invuln - dt);
      p.shoveCd = Math.max(0, p.shoveCd - dt);
      if (!p.alive) p.deadTime += dt;
      if (p.shoveCount !== p.shoveSeen) { p.shoveSeen = p.shoveCount; if (p.alive && p.shoveCd <= 0) { p.shoveCd = 1.5; this.doShove(p); } }
      if (p.dropCount !== p.dropSeen) { p.dropSeen = p.dropCount; if (p.alive) this.dropTools(p, true); }
    }
    switch (this.phase) {
      case 'lobby': this.simLobby(dt); break;
      case 'shift': this.simShift(dt); break;
      case 'won':
      case 'lost':
        this.endTimer -= dt;
        if (this.endTimer <= 0) this.startLobby(this.seed + 1, this.phase === 'won' ? this.shift + 1 : this.shift);
        break;
    }
  }

  private simLobby(dt: number) {
    const clock = this.map.clock;
    const holding = clock ? [...this.players.values()].some((p) => p.alive && p.interact && dist(p, clock) < INTERACT_RANGE) : false;
    if (holding) {
      this.punch = Math.min(1, this.punch + dt / 2);
      if (this.punch >= 1) this.beginShift();
    } else this.punch = Math.max(0, this.punch - dt * 1.5);
  }

  private simShift(dt: number) {
    const alive = [...this.players.values()].filter((p) => p.alive);
    // Tools: walk over a tray to take it, walk into the OR to deliver it.
    for (const t of this.tools) {
      if (t.state !== 'floor') continue;
      t.cool = Math.max(0, t.cool - dt);
      if (!t.seen && this.isLit(t.x, t.y)) t.seen = true;
      if (t.cool > 0) continue;
      for (const p of alive) {
        if (dist(p, t) >= 0.7 * TILE) continue;
        if (p.carried.length < CARRY_CAP) {
          t.state = 'carried'; t.carrier = p.id; p.carried.push(t);
          this.emit({ type: 'sound', name: 'pickup', x: t.x, y: t.y });
          this.say(`${p.name} picked up the ${t.kind}.`, 3);
        }
        break;
      }
    }
    for (const p of alive) {
      if (p.carried.length && dist(p, this.map.table) < TABLE_RANGE) {
        for (const t of p.carried) { t.state = 'delivered'; t.carrier = -1; t.x = this.map.table.x; t.y = this.map.table.y; }
        p.carried = [];
        this.emit({ type: 'sound', name: 'deliver', x: p.x, y: p.y });
        const left = this.tools.filter((t) => t.state !== 'delivered').length;
        this.say(left ? `${p.name} delivered tools. ${left} still out there.` : 'Full kit on the tray. Hold E at the table to operate.', 4);
      }
    }
    this.simSurgery(dt, alive);
    // The patient is always dying.
    const drainSeconds = 840 * Math.pow(0.85, this.shift - 1);
    this.vitals -= (dt * 100) / drainSeconds;
    for (const m of this.monsters) this.updateMonster(m, dt);
    this.simPod(dt, alive);
    if (this.vitals <= 0 && this.phase === 'shift') this.endShift(false, 'The patient flatlined.');
    else if (!alive.length && this.phase === 'shift') this.endShift(false, 'Everyone is dead. The patient is next.');
  }

  private simSurgery(dt: number, alive: Player[]) {
    const step = this.step;
    if (!step || !this.patient) return;
    const ready = this.tools.some((t) => t.kind === step.tool && t.state === 'delivered');
    const operators = alive.filter((p) => p.operating && dist(p, this.map.table) < TABLE_RANGE);
    if (!operators.length) return;
    if (!ready) { if (this.messageTimer <= 0) this.say(`Need the ${step.tool} for: ${step.label}.`, 2); return; }
    const marker = Math.sin(this.time * step.speed);
    if (Math.abs(marker) <= step.zone) {
      const rate = 1 + 0.6 * (operators.length - 1);
      this.stepProgress += (dt / step.duration) * rate;
      this.beepTimer -= dt;
      if (this.beepTimer <= 0) { this.beepTimer = 0.8; this.emit({ type: 'sound', name: 'beep', x: this.map.table.x, y: this.map.table.y }); }
    } else {
      this.vitals -= 3 * dt * operators.length;
      if (this.time - this.lastComplication > 1.5) { this.lastComplication = this.time; this.emit({ type: 'sound', name: 'complication', x: this.map.table.x, y: this.map.table.y }); this.say('Complication! Keep the marker in the zone.', 1.5); }
    }
    // Operating is loud. Everything in the building hears the monitors.
    this.alertTimer -= dt;
    if (this.alertTimer <= 0) {
      this.alertTimer = 4;
      for (const m of this.monsters) {
        if (m.state === 'stunned' || m.calm > 0) continue;
        m.state = 'chase'; m.lastSeen = { x: this.map.table.x, y: this.map.table.y + TILE }; m.lostTimer = 0; m.replan = 0;
      }
    }
    if (this.stepProgress >= 1) {
      this.stepProgress = 0;
      this.stepIndex++;
      this.vitals = Math.min(100, this.vitals + 8);
      this.emit({ type: 'sound', name: 'stepDone', x: this.map.table.x, y: this.map.table.y });
      const next = this.step;
      if (next) this.say(`Done: ${step.label}. Next: ${next.label} (${next.tool}).`, 4);
      else this.endShift(true, `${this.patient.name} is stable. Punch out!`);
    }
  }

  private simPod(dt: number, alive: Player[]) {
    const pod = this.map.pod;
    const dead = [...this.players.values()].filter((p) => !p.alive).sort((a, b) => b.deadTime - a.deadTime);
    if (!pod || !dead.length) { this.pod = 0; return; }
    const holding = alive.some((p) => p.interact && dist(p, pod) < INTERACT_RANGE);
    if (!holding) { this.pod = Math.max(0, this.pod - dt); return; }
    this.pod = Math.min(1, this.pod + dt / 5);
    if (this.pod >= 1) {
      this.pod = 0;
      const p = dead[0];
      const spot = this.scatterSpot(pod);
      p.alive = true; p.hp = 2; p.invuln = 3; p.carried = []; p.knock = { x: 0, y: 0 }; p.x = spot.x; p.y = spot.y;
      this.emit({ type: 'respawn', player: p.id, x: spot.x, y: spot.y });
      this.say(`${p.name} crawled out of the Re-Gen Pod. Mostly intact.`, 4);
    }
  }

  private endShift(won: boolean, text: string) {
    this.phase = won ? 'won' : 'lost';
    this.endTimer = SNAP_END_SECONDS;
    this.emit({ type: 'sound', name: won ? 'win' : 'flatline' });
    this.say(text, SNAP_END_SECONDS);
  }

  private doShove(p: Player) {
    this.emit({ type: 'sound', name: 'shove', x: p.x, y: p.y });
    const inCone = (t: Vec) => {
      const d = dist(p, t);
      if (d > 1.7 * TILE) return false;
      let diff = Math.abs(Math.atan2(t.y - p.y, t.x - p.x) - p.facing);
      diff = Math.min(diff, Math.PI * 2 - diff);
      return diff < 0.7;
    };
    for (const m of this.monsters) {
      if (!inCone(m)) continue;
      const d = dist(p, m) || 1, kx = (m.x - p.x) / d, ky = (m.y - p.y) / d;
      const push = m.kind === 'orderly' ? 0.5 : 1.5;
      this.moveCircle(m, kx * push * TILE, ky * push * TILE);
      if (m.kind !== 'orderly') { m.state = 'stunned'; m.stun = 1.4; m.shoved = true; m.path = []; }
      this.emit({ type: 'sound', name: 'thud', x: m.x, y: m.y });
    }
    for (const q of this.players.values()) {
      if (q.id === p.id || !q.alive || !inCone(q)) continue;
      const d = dist(p, q) || 1, kx = (q.x - p.x) / d, ky = (q.y - p.y) / d;
      this.emit({ type: 'shoved', player: q.id, kx: kx * 9 * TILE, ky: ky * 9 * TILE, by: p.name });
      if (q.local) { q.knock.x = kx * 9 * TILE; q.knock.y = ky * 9 * TILE; }
      if (q.carried.length) { this.dropTools(q, false); this.say(`${p.name} shoved ${q.name}. Tools everywhere.`, 3); }
      else this.say(`${p.name} shoved ${q.name}. Very professional.`, 3);
    }
  }

  private dropTools(p: Player, gentle: boolean) {
    for (const t of p.carried) {
      const s = gentle ? this.frontSpot(p) : this.scatterSpot(p);
      t.x = s.x; t.y = s.y; t.state = 'floor'; t.carrier = -1; t.cool = 1.2;
    }
    if (p.carried.length) this.emit({ type: 'sound', name: 'thud', x: p.x, y: p.y });
    p.carried = [];
  }

  private updateMonster(m: Monster, dt: number) {
    const map = this.map;
    m.anim += dt;
    m.moving = false;
    if (m.state === 'stunned') {
      m.stun -= dt;
      if (m.stun <= 0) {
        if (m.shoved) { m.shoved = false; m.state = 'chase'; m.lostTimer = 0; m.replan = 0; }
        else { m.state = 'wander'; m.goal = this.randomFloorFar(this.nearestAlive(m)?.p ?? m, 8); m.path = []; m.lastSeen = null; m.lostTimer = 0; m.replan = 0; m.calm = m.kind === 'orderly' ? 5 : 4; }
      }
      return;
    }
    m.calm = Math.max(0, m.calm - dt);
    const near = this.nearestAlive(m);
    let speed = 0, direct = false;
    let target: Vec | null = null;
    const anyoneOperating = [...this.players.values()].some((p) => p.alive && p.operating);

    if (m.kind === 'nurse') {
      // Hunts by sight. Your flashlight makes you visible from much farther away; sprinting is loud.
      let seen: Player | null = null;
      for (const p of this.players.values()) {
        if (!p.alive) continue;
        const d = dist(m, p);
        const range = (p.flashlight ? 7 : 3.5) * TILE;
        const los = d < 14 * TILE && map.hasLOS(m.x, m.y, p.x, p.y);
        if ((los && d < range) || (p.sprinting && d < 5 * TILE)) if (!seen || d < dist(m, seen)) seen = p;
      }
      if (m.calm > 0) seen = null;
      if (seen) {
        if (m.state !== 'chase') { this.emit({ type: 'sound', name: 'screech', x: m.x, y: m.y }); this.say(`Something saw ${seen.name}.`, 2); }
        m.state = 'chase'; m.targetId = seen.id; m.lastSeen = { x: seen.x, y: seen.y }; m.lostTimer = 0;
      }
      if (m.state === 'chase') {
        speed = (seen ? 3.2 : 2.2) * TILE;
        m.lostTimer += dt;
        target = m.lastSeen;
        direct = !!seen;
        if (target && !seen && dist(target, m) < 14) { m.lastSeen = this.randomFloorNear(m, 5); m.path = []; m.replan = 0; }
        if (m.lostTimer > 4.5) { m.state = 'wander'; m.goal = null; m.path = []; }
      } else {
        speed = 1.5 * TILE;
        if (!m.goal || dist(m.goal, m) < 14) { m.goal = this.randomFloorPoint(); m.path = []; m.replan = 0; }
        target = m.goal;
      }
    } else if (m.kind === 'lurker') {
      // Cannot move while any light is on it. In the dark it creeps toward the nearest surgeon.
      m.frozen = this.isLit(m.x, m.y);
      if (m.frozen) speed = 0;
      else if (near && near.d < 12 * TILE) {
        m.state = 'chase'; speed = 2.6 * TILE; target = { x: near.p.x, y: near.p.y }; m.targetId = near.p.id;
        direct = map.hasLOS(m.x, m.y, near.p.x, near.p.y); m.lastSeen = null;
      } else if (m.lastSeen) {
        m.state = 'chase'; speed = 3.2 * TILE; target = m.lastSeen;
        if (dist(target, m) < 14) m.lastSeen = null;
      } else {
        m.state = 'wander'; speed = 1.2 * TILE;
        if (!m.goal || dist(m.goal, m) < 14) { m.goal = this.randomFloorPoint(); m.path = []; m.replan = 0; }
        target = m.goal;
      }
      if (speed > 0 && near && near.d < 9 * TILE) {
        m.sound -= dt;
        if (m.sound <= 0) { m.sound = 0.4 + Math.random() * 0.4; this.emit({ type: 'sound', name: 'skitter', x: m.x, y: m.y }); }
      }
    } else {
      // The Orderly: slow, never stops, knows where you are when you are anywhere near, goes to the OR when it hears the monitors.
      speed = 1.3 * TILE;
      if (near && near.d < 16 * TILE) {
        m.state = 'chase'; target = { x: near.p.x, y: near.p.y }; m.targetId = near.p.id; direct = map.hasLOS(m.x, m.y, near.p.x, near.p.y);
      } else if (anyoneOperating || m.lastSeen) {
        m.state = 'chase'; target = m.lastSeen ?? { x: map.table.x, y: map.table.y + TILE };
        if (dist(target, m) < 20) m.lastSeen = null;
      } else {
        m.state = 'wander';
        if (!m.goal || dist(m.goal, m) < 14) { m.goal = this.randomFloorNear(map.table, 10); m.path = []; m.replan = 0; }
        target = m.goal;
      }
      m.sound -= dt;
      if (m.sound <= 0 && near && near.d < 12 * TILE) { m.sound = 1.1; this.emit({ type: 'sound', name: 'thud', x: m.x, y: m.y }); }
    }

    if (speed > 0 && target) this.steer(m, target, direct, speed, dt);
    // A lit lurker is a statue you can walk right past, and a monster in its post-hit daze does not bite.
    const harmless = (m.kind === 'lurker' && m.frozen) || m.calm > 0;
    if (!harmless) {
      for (const p of this.players.values()) {
        if (p.alive && p.invuln <= 0 && dist(m, p) < m.r + p.r) { this.hitPlayer(m, p); break; }
      }
    }
  }

  private nearestAlive(from: Vec): { p: Player; d: number } | null {
    let best: { p: Player; d: number } | null = null;
    for (const p of this.players.values()) {
      if (!p.alive) continue;
      const d = dist(from, p);
      if (!best || d < best.d) best = { p, d };
    }
    return best;
  }

  private steer(m: Monster, target: Vec, direct: boolean, speed: number, dt: number) {
    let tx = target.x, ty = target.y;
    if (m.forcePath > 0) { m.forcePath -= dt; direct = false; }
    if (!direct) {
      m.replan -= dt;
      if (m.replan <= 0) {
        m.replan = 0.4;
        m.path = this.map.findPath(tileOf(m.x), tileOf(m.y), tileOf(target.x), tileOf(target.y));
      }
      while (m.path.length && Math.hypot((m.path[0].x + 0.5) * TILE - m.x, (m.path[0].y + 0.5) * TILE - m.y) < 6) m.path.shift();
      if (m.path.length) { tx = (m.path[0].x + 0.5) * TILE; ty = (m.path[0].y + 0.5) * TILE; }
    }
    const dx = tx - m.x, dy = ty - m.y, d = Math.hypot(dx, dy);
    if (d < 0.5) return;
    m.facing = Math.atan2(dy, dx);
    const step = Math.min(d, speed * dt);
    const ox = m.x, oy = m.y;
    this.moveCircle(m, (dx / d) * step, (dy / d) * step);
    const moved = Math.hypot(m.x - ox, m.y - oy);
    m.moving = moved > 0.01;
    if (moved < step * 0.3) {
      m.stuck += dt;
      if (m.stuck > 0.15) { m.stuck = 0; m.forcePath = 1; m.path = []; m.replan = 0; }
    } else m.stuck = 0;
  }

  private hitPlayer(m: Monster, p: Player) {
    const dmg = m.kind === 'orderly' ? 2 : 1;
    p.hp = Math.max(0, p.hp - dmg);
    p.invuln = 3;
    const dx = p.x - m.x, dy = p.y - m.y, d = Math.hypot(dx, dy) || 1;
    const k = (m.kind === 'orderly' ? 14 : 10) * TILE;
    this.emit({ type: 'hit', player: p.id, kx: (dx / d) * k, ky: (dy / d) * k, hp: p.hp });
    m.state = 'stunned'; m.stun = m.kind === 'orderly' ? 2 : m.kind === 'nurse' ? 3.5 : 4; m.path = []; m.shoved = false;
    if (p.carried.length) { this.dropTools(p, false); this.say(`${p.name} dropped their tools!`, 3); }
    if (p.hp <= 0) {
      p.alive = false; p.deadTime = 0; p.operating = false;
      this.emit({ type: 'sound', name: 'flatline', x: p.x, y: p.y });
      this.say(this.players.size > 1 ? `${p.name} is down. The Re-Gen Pod can bring them back.` : 'You are down.', 4);
      if (p.local) this.spectating = [...this.players.values()].find((q) => q.alive)?.id ?? 0;
    }
  }

  private scatterSpot(p: Vec): Vec {
    for (let i = 0; i < 24; i++) {
      const a = Math.random() * Math.PI * 2, r = TILE * (0.8 + Math.random() * 1.2);
      const x = p.x + Math.cos(a) * r, y = p.y + Math.sin(a) * r;
      if (!this.map.circleHitsSolid(x, y, 8) && this.map.hasLOS(p.x, p.y, x, y)) return { x, y };
    }
    return { x: p.x, y: p.y };
  }

  private frontSpot(p: Player): Vec {
    const x = p.x + Math.cos(p.facing) * TILE, y = p.y + Math.sin(p.facing) * TILE;
    if (!this.map.circleHitsSolid(x, y, 8) && this.map.hasLOS(p.x, p.y, x, y)) return { x, y };
    return this.scatterSpot(p);
  }

  private randomFloorPoint(): Vec {
    const t = this.map.randomFloorTile();
    return { x: (t.x + 0.5) * TILE, y: (t.y + 0.5) * TILE };
  }
  private randomFloorFar(v: Vec, minTiles: number): Vec {
    for (let i = 0; i < 30; i++) {
      const t = this.map.randomFloorTile();
      const x = (t.x + 0.5) * TILE, y = (t.y + 0.5) * TILE;
      if (Math.hypot(x - v.x, y - v.y) >= minTiles * TILE) return { x, y };
    }
    return this.randomFloorPoint();
  }
  private randomFloorNear(v: Vec, radiusTiles: number): Vec {
    for (let i = 0; i < 30; i++) {
      const t = this.map.randomFloorTile();
      const x = (t.x + 0.5) * TILE, y = (t.y + 0.5) * TILE;
      if (Math.hypot(x - v.x, y - v.y) < radiusTiles * TILE) return { x, y };
    }
    return this.randomFloorPoint();
  }

  private updateFx(dt: number) {
    this.messageTimer = Math.max(0, this.messageTimer - dt);
    this.hurt = Math.max(0, this.hurt - dt * 1.5);
    this.shake = Math.max(0, this.shake - dt * 2.5);
    const me = this.spectated;
    let nearest = Infinity;
    if (me) for (const m of this.monsters) nearest = Math.min(nearest, dist(m, me));
    this.danger = this.phase === 'shift' ? Math.max(0, Math.min(1, 1 - nearest / (9 * TILE))) : 0;
    this.audio.setDanger(this.danger);
    this.audio.update(dt);
  }

  // ---------- networking glue ----------

  /** What this client tells the host about its own surgeon. */
  localState(): PlayerState {
    const p = this.local!;
    return { x: p.x, y: p.y, f: p.facing, p: p.pitch, fl: p.flashlight, sp: p.sprinting, mv: p.moving, op: p.operating, ia: p.interact, sh: p.shoveCount, dr: p.dropCount };
  }

  /** Host: accept a client's report about its own surgeon. */
  applyRemoteState(id: number, s: PlayerState) {
    const p = this.players.get(id);
    if (!p || p.local) return;
    if (p.alive) { p.x = s.x; p.y = s.y; }
    p.facing = s.f; p.pitch = s.p; p.flashlight = s.fl; p.sprinting = s.sp; p.moving = s.mv;
    p.operating = s.op && p.alive; p.interact = s.ia; p.shoveCount = s.sh; p.dropCount = s.dr;
  }

  snapshot(): Snapshot {
    const events = this.events;
    this.events = [];
    return {
      tick: this.tick, time: this.time, phase: this.phase, shift: this.shift, seed: this.seed,
      vit: this.vitals, pat: this.patientIndex, step: this.stepIndex, prog: this.stepProgress,
      punch: this.punch, pod: this.pod, endT: this.endTimer,
      players: [...this.players.values()].map((p) => ({
        id: p.id, name: p.name, col: p.col, x: p.x, y: p.y, f: p.facing, p: p.pitch,
        fl: p.flashlight, sp: p.sprinting, mv: p.moving, op: p.operating,
        hp: p.hp, alive: p.alive, inv: p.invuln > 0, carried: p.carried.map((t) => t.id),
      })),
      monsters: this.monsters.map((m) => ({ id: m.id, kind: m.kind, x: m.x, y: m.y, f: m.facing, st: m.state, fz: m.frozen, mv: m.moving })),
      tools: this.tools.map((t) => ({ id: t.id, kind: t.kind, x: t.x, y: t.y, st: t.state, car: t.carrier })),
      events,
    };
  }

  /** Client: mirror the host's world. */
  applySnapshot(snap: Snapshot) {
    if (snap.seed !== this.seed || (this.phase === 'menu')) this.startLobby(snap.seed, snap.shift);
    const wasPhase = this.phase;
    this.phase = snap.phase; this.shift = snap.shift; this.time = snap.time; this.tick = snap.tick;
    this.vitals = snap.vit; this.stepIndex = snap.step; this.stepProgress = snap.prog;
    this.punch = snap.punch; this.pod = snap.pod; this.endTimer = snap.endT;
    if (snap.pat !== this.patientIndex) { this.patientIndex = snap.pat; this.patient = snap.pat >= 0 ? PATIENTS[snap.pat] : null; }
    if (wasPhase !== 'shift' && snap.phase === 'shift') { this.lastComplication = 0; }

    // Tools first so carried lists can reference them.
    const byId = new Map(this.tools.map((t) => [t.id, t]));
    this.tools = snap.tools.map((s) => {
      const t = byId.get(s.id) ?? { id: s.id, kind: s.kind, x: s.x, y: s.y, state: s.st, carrier: s.car, seen: false, bob: Math.random() * 6, cool: 0 };
      t.kind = s.kind; t.x = s.x; t.y = s.y; t.state = s.st; t.carrier = s.car;
      if (!t.seen && t.state === 'floor' && this.isLit(t.x, t.y)) t.seen = true;
      return t;
    });
    const toolById = new Map(this.tools.map((t) => [t.id, t]));

    const seen = new Set<number>();
    for (const s of snap.players) {
      seen.add(s.id);
      let p = this.players.get(s.id);
      if (!p) p = this.addPlayer(s.id, s.name, s.id === this.localId);
      p.name = s.name; p.col = s.col; p.hp = s.hp; p.invuln = s.inv ? Math.max(p.invuln, 0.1) : 0;
      p.carried = s.carried.map((id) => toolById.get(id)).filter((t): t is Tool => !!t);
      if (p.local) {
        if (p.alive && !s.alive) { p.alive = false; p.deadTime = 0; }
        else if (!p.alive && s.alive) { p.alive = true; }
      } else {
        p.x = s.x; p.y = s.y; p.facing = s.f; p.pitch = s.p; p.flashlight = s.fl; p.sprinting = s.sp; p.moving = s.mv; p.operating = s.op; p.alive = s.alive;
      }
    }
    for (const id of [...this.players.keys()]) if (!seen.has(id)) this.players.delete(id);

    const sameMonsters = this.monsters.length === snap.monsters.length && this.monsters.every((m, i) => m.id === snap.monsters[i].id && m.kind === snap.monsters[i].kind);
    if (!sameMonsters) {
      this.monsters = snap.monsters.map((s) => ({
        id: s.id, kind: s.kind as MonsterKind, x: s.x, y: s.y, r: 12, state: s.st as Monster['state'], path: [], goal: null, lastSeen: null, targetId: -1,
        lostTimer: 0, replan: 0, stun: 0, facing: s.f, frozen: s.fz, anim: Math.random() * 10, sound: 0, stuck: 0, forcePath: 0, calm: 0, moving: s.mv, shoved: false,
      }));
    } else {
      snap.monsters.forEach((s, i) => { const m = this.monsters[i]; m.x = s.x; m.y = s.y; m.facing = s.f; m.state = s.st as Monster['state']; m.frozen = s.fz; m.moving = s.mv; });
    }
    for (const e of snap.events) this.playEvent(e);
  }
}
