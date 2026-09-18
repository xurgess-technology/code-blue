// 2D overlay drawn on a transparent canvas above the 3D view.
import { Game, CARRY_CAP } from './game';
import { Tile, TILE } from './map';
import { Input } from './input';
import { toolsFor } from './patients';

const MONO = '"Courier New", Courier, monospace';
const fmt = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const hex = (c: number) => '#' + c.toString(16).padStart(6, '0');

export class Hud {
  ctx: CanvasRenderingContext2D;
  W = 0; H = 0;
  hostInfo = '';
  private t = 0;
  private hintTimer = 40;

  constructor(public canvas: HTMLCanvasElement) {
    this.ctx = canvas.getContext('2d')!;
  }

  resize(w: number, h: number) {
    if (w === this.W && h === this.H) return;
    this.W = w; this.H = h;
    this.canvas.width = w; this.canvas.height = h;
  }

  draw(game: Game, input: Input, dt: number) {
    this.t += dt;
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.W, this.H);
    if (game.phase === 'menu') return;
    this.drawVignette(game);
    this.drawHUD(game, dt);
    const me = game.local;
    if (me?.alive && !game.paused) this.drawCrosshair(game);
    if (me && !me.alive) this.drawSpectator(game);
    if (game.phase === 'shift') this.drawSurgery(game);
    if (game.phase === 'lobby') this.drawHold(game.punch, 'CLOCKING IN', game.map.clock);
    if (game.phase === 'shift') this.drawHold(game.pod, 'RE-GEN POD', game.map.pod);
    if (game.paused) this.drawOverlay('PAUSED', game.solo ? 'The night shift waits for no one.' : 'The shift goes on without you.', input.lockEverAcquired ? 'Click to resume' : 'Press P to resume', '#c9d1d9');
    if (game.phase === 'lost') this.drawOverlay('FLATLINE', game.message, `Back to the clock-in room in ${Math.ceil(game.endTimer)}`, '#ff2a2a');
    if (game.phase === 'won') this.drawOverlay('PATIENT STABILIZED', `Shift ${game.shift} done in ${fmt(game.time)}. Punch out.`, `Shift ${game.shift + 1} starts in ${Math.ceil(game.endTimer)}`, '#5cff8a');
  }

  private drawCrosshair(game: Game) {
    const ctx = this.ctx, cx = this.W / 2, cy = this.H / 2;
    const me = game.local!;
    const spread = me.moving ? (me.sprinting ? 9 : 6) : 4;
    ctx.strokeStyle = 'rgba(255,255,255,0.55)'; ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(cx - spread - 4, cy); ctx.lineTo(cx - spread, cy);
    ctx.moveTo(cx + spread, cy); ctx.lineTo(cx + spread + 4, cy);
    ctx.moveTo(cx, cy - spread - 4); ctx.lineTo(cx, cy - spread);
    ctx.moveTo(cx, cy + spread); ctx.lineTo(cx, cy + spread + 4);
    ctx.stroke();
    ctx.fillStyle = 'rgba(255,255,255,0.8)'; ctx.fillRect(cx - 1, cy - 1, 2, 2);
  }

  private drawSpectator(game: Game) {
    const ctx = this.ctx, w = game.spectated;
    ctx.save();
    ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.font = `bold 16px ${MONO}`;
    ctx.fillStyle = 'rgba(0,0,0,0.6)'; ctx.fillRect(this.W / 2 - 220, 40, 440, 48);
    ctx.fillStyle = '#ff6a6a'; ctx.fillText('YOU ARE DEAD', this.W / 2, 46);
    ctx.fillStyle = '#c9d1d9'; ctx.font = `13px ${MONO}`;
    ctx.fillText(w && w !== game.local ? `Watching ${w.name}. Click to switch. A teammate can revive you at the pod.` : 'Nobody left to watch.', this.W / 2, 68);
    ctx.restore();
  }

  /** Hold-E progress for the time clock and the pod, shown when you are near them. */
  private drawHold(progress: number, label: string, at: { x: number; y: number } | null) {
    const me = this.lastView;
    if (!at || !me) return;
    const d = Math.hypot(at.x - me.x, at.y - me.y);
    if (d > 2.2 * TILE && progress <= 0) return;
    const ctx = this.ctx, cx = this.W / 2, y = this.H / 2 + 70;
    ctx.save();
    ctx.fillStyle = 'rgba(0,0,0,0.7)'; ctx.fillRect(cx - 112, y - 8, 224, 16);
    ctx.fillStyle = '#5ce0d0'; ctx.fillRect(cx - 110, y - 6, 220 * progress, 12);
    ctx.fillStyle = '#fff'; ctx.font = `bold 13px ${MONO}`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(progress > 0 ? `${label}...` : `HOLD E: ${label}`, cx, y - 20);
    ctx.restore();
  }

  private lastView: { x: number; y: number } | null = null;

  /** The steady-hand bar and the current step. Only when near the table. */
  private drawSurgery(game: Game) {
    const me = game.spectated, step = game.step;
    if (!me || !step || !game.patient) return;
    if (Math.hypot(me.x - game.map.table.x, me.y - game.map.table.y) > 3.2 * TILE) return;
    const ctx = this.ctx, cx = this.W / 2, y = this.H / 2 + 110;
    const delivered = game.tools.some((t) => t.kind === step.tool && t.state === 'delivered');
    ctx.save();
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillStyle = 'rgba(0,0,0,0.7)'; ctx.fillRect(cx - 170, y - 44, 340, 88);
    ctx.fillStyle = '#f0e6c8'; ctx.font = `bold 14px ${MONO}`;
    ctx.fillText(`STEP ${game.stepIndex + 1}/${game.patient.steps.length}: ${step.label.toUpperCase()}`, cx, y - 28);
    ctx.fillStyle = delivered ? '#5cff8a' : '#ff6a6a'; ctx.font = `12px ${MONO}`;
    ctx.fillText(delivered ? `${step.tool} ready. Hold E and keep the marker in the zone.` : `Needs the ${step.tool}. It is not on the tray yet.`, cx, y - 10);
    // bar
    const bw = 300, bx = cx - bw / 2, by = y + 8;
    ctx.fillStyle = '#2a2f36'; ctx.fillRect(bx, by, bw, 14);
    const zw = step.zone * bw / 2;
    ctx.fillStyle = 'rgba(92,255,138,0.6)'; ctx.fillRect(cx - zw, by, zw * 2, 14);
    const marker = Math.sin(game.time * step.speed);
    const mx = cx + marker * (bw / 2);
    ctx.fillStyle = Math.abs(marker) <= step.zone ? '#fff' : '#ff6a6a'; ctx.fillRect(mx - 2, by - 3, 4, 20);
    ctx.fillStyle = '#c9d1d9'; ctx.fillRect(bx, by + 18, bw * game.stepProgress, 4);
    ctx.restore();
  }

  private drawVignette(game: Game) {
    const ctx = this.ctx, { W, H } = this;
    const g = ctx.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.35, W / 2, H / 2, Math.max(W, H) * 0.75);
    g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(1, 'rgba(0,0,0,0.65)');
    ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    const red = Math.max(game.hurt, game.danger * 0.35 * (0.5 + 0.5 * Math.sin(this.t * 6)));
    if (red > 0.01) {
      const r = ctx.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.25, W / 2, H / 2, Math.max(W, H) * 0.7);
      r.addColorStop(0, 'rgba(120,0,0,0)'); r.addColorStop(1, `rgba(140,0,0,${0.7 * red})`);
      ctx.fillStyle = r; ctx.fillRect(0, 0, W, H);
    }
  }

  private drawHUD(game: Game, dt: number) {
    const ctx = this.ctx, { W, H } = this, me = game.local, view = game.spectated;
    this.lastView = view ? { x: view.x, y: view.y } : null;
    const fs = Math.min(1, W / 1000);
    ctx.save();
    ctx.textBaseline = 'top'; ctx.textAlign = 'left';

    // Party: hearts per surgeon, you first.
    const party = [...game.players.values()].sort((a, b) => (a.local ? -1 : b.local ? 1 : a.id - b.id));
    ctx.font = `13px ${MONO}`;
    let py = 18;
    for (const p of party) {
      ctx.fillStyle = 'rgba(0,0,0,0.5)'; ctx.fillRect(12, py - 4, 190, 24);
      ctx.fillStyle = hex(p.col); ctx.fillRect(12, py - 4, 4, 24);
      ctx.fillStyle = p.alive ? '#eee' : '#777';
      ctx.fillText((p.local ? '> ' : '  ') + p.name.slice(0, 12), 22, py + 1);
      for (let i = 0; i < p.maxHp; i++) this.heart(150 + i * 16, py + 8, i < p.hp ? '#e02a2a' : '#3a1414', 0.55);
      if (!p.alive) { ctx.fillStyle = '#ff6a6a'; ctx.fillText('DEAD', 150, py + 1); }
      py += 26;
    }
    if (me) {
      ctx.fillStyle = 'rgba(0,0,0,0.55)'; ctx.fillRect(12, py, 108, 10);
      ctx.fillStyle = me.stamina < 0.25 ? '#e0a020' : '#7ad0c0'; ctx.fillRect(14, py + 2, 104 * me.stamina, 6);
      ctx.fillStyle = me.flashlight ? '#ffe9a8' : '#777'; ctx.font = `12px ${MONO}`;
      ctx.fillText(me.flashlight ? 'LIGHT ON  [F]' : 'LIGHT OFF [F]', 14, py + 14);
      ctx.fillStyle = '#aaa'; ctx.fillText(`In hand: ${me.carried.map((t) => t.kind).join(', ') || '-'} (${me.carried.length}/${CARRY_CAP})`, 14, py + 30);
    }

    // Objective line.
    ctx.textAlign = 'center'; ctx.font = `bold ${Math.round(13 * fs)}px ${MONO}`; ctx.fillStyle = '#ff6a6a';
    let objective = '';
    if (game.phase === 'lobby') objective = `SHIFT ${game.shift}. HOLD E AT THE TIME CLOCK TO CLOCK IN.`;
    else if (game.phase === 'shift') {
      const missing = game.tools.filter((t) => t.state !== 'delivered').length;
      objective = missing ? `FIND ${missing} TOOL${missing > 1 ? 'S' : ''} AND BRING THEM TO THE OR.` : 'OPERATE. HOLD E AT THE TABLE.';
    }
    ctx.fillText(objective, W / 2, 12);
    if (game.phase === 'lobby' && this.hostInfo) { ctx.fillStyle = '#5ce0d0'; ctx.font = `${Math.round(13 * fs)}px ${MONO}`; ctx.fillText(this.hostInfo, W / 2, 32); }

    // Patient panel.
    ctx.textAlign = 'left'; ctx.font = `14px ${MONO}`;
    const bx = W - 250;
    if (game.phase === 'shift' && game.patient) {
      const needed = toolsFor(game.patient);
      const bh = 96 + needed.length * 19 + 12;
      ctx.fillStyle = 'rgba(0,0,0,0.55)'; ctx.fillRect(bx - 12, 12, 250, bh);
      ctx.fillStyle = '#ddd'; ctx.font = `bold 14px ${MONO}`; ctx.fillText(game.patient.name.toUpperCase().slice(0, 26), bx, 20);
      ctx.fillStyle = '#8a9aa0'; ctx.font = `11px ${MONO}`; ctx.fillText(game.patient.blurb.slice(0, 38), bx, 38);
      // vitals
      const v = Math.max(0, game.vitals);
      const pulse = v > 30 ? 1 : 0.7 + 0.3 * Math.sin(this.t * 10);
      ctx.fillStyle = '#2a2f36'; ctx.fillRect(bx, 56, 226, 12);
      ctx.fillStyle = v > 50 ? '#5cff8a' : v > 25 ? '#ffd35c' : `rgba(255,42,42,${pulse})`; ctx.fillRect(bx, 56, 226 * v / 100, 12);
      ctx.fillStyle = '#eee'; ctx.font = `bold 11px ${MONO}`; ctx.fillText(`VITALS ${Math.ceil(v)}%   ${Math.round(40 + v * 0.6 + Math.sin(this.t * 8) * 2)} BPM`, bx, 72);
      ctx.font = `13px ${MONO}`;
      needed.forEach((kind, i) => {
        const tool = game.tools.find((t) => t.kind === kind);
        let col = '#777', tag = '[?]';
        if (tool?.state === 'delivered') { col = '#5cff8a'; tag = '[x]'; }
        else if (tool?.state === 'carried') { col = '#ffd35c'; tag = `[${game.players.get(tool.carrier)?.name.slice(0, 6) ?? '~'}]`; }
        else if (tool?.seen) { col = '#eee'; tag = '[ ]'; }
        ctx.fillStyle = col; ctx.fillText(`${tag} ${kind}`, bx, 92 + i * 19);
      });
      const step = game.step;
      ctx.fillStyle = '#c9d1d9'; ctx.font = `11px ${MONO}`;
      ctx.fillText(step ? `Next: ${step.label} (${step.tool})` : 'Procedure complete', bx, 92 + needed.length * 19 + 2);
    }

    if (game.messageTimer > 0 && (game.phase === 'shift' || game.phase === 'lobby')) {
      ctx.font = `${Math.round(16 * fs)}px ${MONO}`; ctx.textAlign = 'center';
      const tw = ctx.measureText(game.message).width;
      ctx.fillStyle = 'rgba(0,0,0,0.65)'; ctx.fillRect(W / 2 - tw / 2 - 14, H - 96, tw + 28, 30);
      ctx.fillStyle = '#f0e6c8'; ctx.fillText(game.message, W / 2, H - 89);
    }
    if (this.hintTimer > 0) {
      this.hintTimer -= dt;
      ctx.font = `${Math.round(12 * fs)}px ${MONO}`; ctx.textAlign = 'right';
      ctx.fillStyle = `rgba(170,170,170,${Math.min(1, this.hintTimer / 2)})`;
      ctx.fillText('WASD move  MOUSE look  SHIFT sprint  F light  E interact  Q shove  G drop  P pause', W - 16, H - 28);
    }
    this.drawMinimap(game);
    ctx.restore();
  }

  private heart(x: number, y: number, color: string, s = 1) {
    const ctx = this.ctx;
    ctx.fillStyle = color; ctx.beginPath();
    ctx.moveTo(x, y + 8 * s);
    ctx.bezierCurveTo(x - 12 * s, y - 2 * s, x - 6 * s, y - 12 * s, x, y - 4 * s);
    ctx.bezierCurveTo(x + 6 * s, y - 12 * s, x + 12 * s, y - 2 * s, x, y + 8 * s);
    ctx.fill();
  }

  private drawMinimap(game: Game) {
    const ctx = this.ctx, map = game.map, s = Math.max(2, Math.min(3, Math.floor(200 / map.w)));
    const mw = map.w * s, mh = map.h * s, ox = 16, oy = this.H - mh - 16;
    ctx.fillStyle = 'rgba(0,0,0,0.6)'; ctx.fillRect(ox - 4, oy - 4, mw + 8, mh + 8);
    for (let y = 0; y < map.h; y++) {
      for (let x = 0; x < map.w; x++) {
        if (!map.isExplored(x, y)) continue;
        const t = map.get(x, y);
        ctx.fillStyle = t === Tile.Wall ? '#3a3f4a' : t === Tile.Door ? '#7a5a3a' : t === Tile.Floor ? '#8a9490' : t === Tile.Clock || t === Tile.Pod ? '#5ce0d0' : '#5b6470';
        ctx.fillRect(ox + x * s, oy + y * s, s, s);
      }
    }
    const tb = map.table, tx = ox + (tb.x / TILE) * s, ty = oy + (tb.y / TILE) * s;
    ctx.fillStyle = '#ff4040'; ctx.fillRect(tx - 3, ty - 1, 6, 2); ctx.fillRect(tx - 1, ty - 3, 2, 6);
    for (const t of game.tools) {
      if (t.state === 'floor' && t.seen) { ctx.fillStyle = '#ffd35c'; ctx.fillRect(ox + (t.x / TILE) * s - 1.5, oy + (t.y / TILE) * s - 1.5, 3, 3); }
    }
    for (const p of game.players.values()) {
      if (!p.alive) continue;
      const px = ox + (p.x / TILE) * s, py = oy + (p.y / TILE) * s;
      ctx.strokeStyle = hex(p.col); ctx.lineWidth = 1.5; ctx.beginPath();
      ctx.moveTo(px, py); ctx.lineTo(px + Math.cos(p.facing) * 8, py + Math.sin(p.facing) * 8); ctx.stroke();
      ctx.fillStyle = p.local ? '#5ce0d0' : hex(p.col); ctx.beginPath(); ctx.arc(px, py, 2.5, 0, Math.PI * 2); ctx.fill();
    }
  }

  private drawOverlay(title: string, sub: string, prompt: string, color: string) {
    const ctx = this.ctx, { W, H } = this;
    ctx.fillStyle = 'rgba(0,0,0,0.72)'; ctx.fillRect(0, 0, W, H);
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillStyle = color; ctx.font = `bold ${Math.min(72, W / 12)}px ${MONO}`; ctx.fillText(title, W / 2, H * 0.4);
    ctx.fillStyle = '#ccc'; ctx.font = `16px ${MONO}`; ctx.fillText(sub, W / 2, H * 0.4 + 56);
    ctx.fillStyle = '#eee'; ctx.font = `bold 16px ${MONO}`; ctx.fillText(prompt, W / 2, H * 0.4 + 100);
  }
}
