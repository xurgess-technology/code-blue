import { Input } from './input';
import { AudioSys } from './audio';
import { Game } from './game';
import { Scene3D } from './scene';
import { Hud } from './hud';
import { Menu, MENU_CSS } from './menu';
import { Session } from './net/session';
import { generateHospital } from './mapgen';
import { Music } from './music';
import { FALLBACK_LAYOUT, TILE } from './map';

const style = document.createElement('style');
style.textContent = MENU_CSS;
document.head.appendChild(style);

const gl = document.getElementById('gl') as HTMLCanvasElement;
const hudCanvas = document.getElementById('hud') as HTMLCanvasElement;
const input = new Input(gl);
const audio = new AudioSys();
const mapSource = (seed: number) => {
  try {
    const g = generateHospital(seed);
    return { rows: g.rows, lights: g.lights };
  } catch (e) {
    console.error('Hospital generation failed, using the fallback layout', e);
    return { rows: FALLBACK_LAYOUT, lights: [] };
  }
};
const game = new Game(audio, mapSource);
const scene = new Scene3D(gl);
const hud = new Hud(hudCanvas);
const menu = new Menu();
let session: Session | null = null;
let music: Music | null = null;
let prevPhase = game.phase;

menu.onChoice = (choice) => {
  audio.start();
  if (!music && audio.context && audio.bus) { music = new Music(audio.context, audio.bus); music.start(); }
  session?.close();
  game.players.clear();
  session = choice.mode === 'solo' ? new Session(game, null, choice.name) : new Session(game, choice.transport, choice.name);
  hud.hostInfo = choice.mode === 'net' ? choice.hostInfo : '';
  menu.hide();
};

function backToMenu(reason: string) {
  session?.close();
  session = null;
  game.phase = 'menu';
  game.players.clear();
  game.monsters = [];
  game.tools = [];
  hud.hostInfo = '';
  music?.setIntensity(0);
  void window.desktop?.stopRelay?.();
  menu.show(reason);
}

// Handy for poking at state from the browser console and for headless tests.
Object.assign(window as unknown as Record<string, unknown>, { game, scene3d: scene, getSession: () => session, menu });

let last = performance.now();
function frame(now: number) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  const w = window.innerWidth, h = window.innerHeight;
  scene.resize(w, h);
  hud.resize(w, h);

  game.update(dt, input);
  session?.update(dt);
  if (session?.closed) backToMenu(session.reason || 'Disconnected.');
  // A second Escape while paused leaves the shift.
  if (game.phase !== 'menu' && game.paused && input.justPressed('Escape')) backToMenu('You walked out mid-shift.');

  if (music) {
    const view = game.spectated;
    const hunting = !!view && game.monsters.some((m) => m.state === 'chase' && Math.hypot(m.x - view.x, m.y - view.y) < 12 * TILE);
    const operating = [...game.players.values()].some((p) => p.operating);
    const level = game.phase !== 'shift' ? 0 : operating ? 2 : hunting ? 1 : Math.min(0.6, game.danger);
    music.setIntensity(level);
    if (game.phase !== prevPhase) {
      if (game.phase === 'lost') music.sting('flatline');
      else if (game.phase === 'won') music.sting('saved');
    }
    music.update(dt);
  }
  prevPhase = game.phase;

  if (game.phase !== 'menu') {
    scene.sync(game, dt);
    scene.render();
  }
  hud.draw(game, input, dt);
  input.endFrame();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
