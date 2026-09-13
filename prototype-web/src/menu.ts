// The main menu is plain DOM: name, solo / host / join. Everything after that is canvas and WebGL.
import { connectRelay, relayUrl, Transport } from './net/transport';

declare global {
  interface Window {
    desktop?: {
      isDesktop: boolean;
      startRelay(port: number): Promise<{ port: number; addresses: string[] }>;
      stopRelay(): Promise<void>;
      getAddresses(): Promise<string[]>;
      toggleFullscreen(): void;
      quit(): void;
    };
  }
}

export type MenuChoice = { mode: 'solo'; name: string } | { mode: 'net'; name: string; transport: Transport; hostInfo: string };

const PORT = 7777;

export class Menu {
  root: HTMLDivElement;
  private status: HTMLDivElement;
  private nameInput: HTMLInputElement;
  private addrInput: HTMLInputElement;
  private buttons: HTMLButtonElement[] = [];
  onChoice: ((c: MenuChoice) => void) | null = null;

  constructor() {
    const desktop = !!window.desktop?.isDesktop;
    this.root = document.createElement('div');
    this.root.id = 'menu';
    this.root.innerHTML = `
      <div class="panel">
        <h1>CODE BLUE</h1>
        <p class="tag">Clock in. Find the tools. Save the patient. Try not to shove each other into the monsters.</p>
        <label>Your name <input id="m-name" maxlength="16" spellcheck="false"></label>
        <div class="row">
          <button id="m-solo">Solo shift</button>
          <button id="m-host">Host a shift</button>
        </div>
        <div class="row">
          <input id="m-addr" placeholder="${desktop ? 'host address, e.g. 192.168.1.20' : 'relay address, e.g. localhost:7777'}" spellcheck="false">
          <button id="m-join">Join</button>
        </div>
        <div id="m-status" class="status"></div>
        <p class="help">${desktop
          ? 'Hosting starts a relay on port 7777. Friends on your LAN join with your local address. Over the internet, forward port 7777 or use Tailscale and share that address.'
          : 'Browser build: run <code>npm run relay</code> in a terminal, then host or join through it.'}</p>
        <p class="controls">WASD move &middot; mouse look &middot; Shift sprint &middot; F flashlight &middot; E interact / operate &middot; Q shove &middot; G drop &middot; P pause &middot; F11 fullscreen</p>
      </div>`;
    document.body.appendChild(this.root);
    this.status = this.root.querySelector('#m-status')!;
    this.nameInput = this.root.querySelector('#m-name')!;
    this.addrInput = this.root.querySelector('#m-addr')!;
    let saved = '';
    try { saved = localStorage.getItem('cb-name') ?? ''; } catch { /* no storage */ }
    this.nameInput.value = saved || `Surgeon ${Math.floor(Math.random() * 90 + 10)}`;
    try { this.addrInput.value = localStorage.getItem('cb-addr') ?? ''; } catch { /* no storage */ }
    const solo = this.root.querySelector<HTMLButtonElement>('#m-solo')!;
    const host = this.root.querySelector<HTMLButtonElement>('#m-host')!;
    const join = this.root.querySelector<HTMLButtonElement>('#m-join')!;
    this.buttons = [solo, host, join];
    solo.onclick = () => this.pick('solo');
    host.onclick = () => this.pick('host');
    join.onclick = () => this.pick('join');
    this.addrInput.onkeydown = (e) => { if (e.key === 'Enter') this.pick('join'); };
    this.nameInput.onkeydown = (e) => { if (e.key === 'Enter') this.pick('solo'); };
  }

  private get name() { return this.nameInput.value.trim().slice(0, 16) || 'Surgeon'; }

  show(message = '') {
    this.root.hidden = false;
    this.status.textContent = message;
    this.enable(true);
    try { document.exitPointerLock(); } catch { /* not locked */ }
  }
  hide() { this.root.hidden = true; }

  private enable(on: boolean) { for (const b of this.buttons) b.disabled = !on; }

  private async pick(mode: 'solo' | 'host' | 'join') {
    try { localStorage.setItem('cb-name', this.name); localStorage.setItem('cb-addr', this.addrInput.value); } catch { /* no storage */ }
    this.enable(false);
    try {
      if (mode === 'solo') { this.onChoice?.({ mode: 'solo', name: this.name }); return; }
      if (mode === 'host') {
        let url = relayUrl(this.addrInput.value || 'localhost', PORT);
        let info = `Hosting through ${url}`;
        if (window.desktop?.isDesktop) {
          this.status.textContent = 'Starting relay...';
          const r = await window.desktop.startRelay(PORT);
          url = `ws://127.0.0.1:${r.port}`;
          info = r.addresses.length ? `Friends join: ${r.addresses.map((a) => `${a}:${r.port}`).join('  or  ')}` : `Hosting on port ${r.port}`;
        }
        this.status.textContent = 'Connecting...';
        const transport = await connectRelay(url, 'host', this.name);
        this.onChoice?.({ mode: 'net', name: this.name, transport, hostInfo: info });
        return;
      }
      const url = relayUrl(this.addrInput.value, PORT);
      this.status.textContent = `Joining ${url}...`;
      const transport = await connectRelay(url, 'client', this.name);
      this.onChoice?.({ mode: 'net', name: this.name, transport, hostInfo: '' });
    } catch (e) {
      this.status.textContent = (e as Error).message;
      this.enable(true);
    }
  }
}

export const MENU_CSS = `
#menu { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center; background: radial-gradient(ellipse at center, #10141a 0%, #04050a 70%); font-family: "Courier New", Courier, monospace; color: #c9d1d9; z-index: 10; }
#menu[hidden] { display: none; }
#menu .panel { width: min(560px, 92vw); padding: 28px 32px; background: rgba(0,0,0,0.55); border: 1px solid #2a3139; box-shadow: 0 0 60px rgba(200,20,30,0.25); }
#menu h1 { margin: 0 0 6px; font-size: 56px; letter-spacing: 6px; color: #d71e28; text-shadow: 0 0 24px rgba(255,40,40,0.6); }
#menu .tag { margin: 0 0 22px; color: #8a9aa0; font-size: 14px; }
#menu label { display: block; margin-bottom: 14px; font-size: 14px; }
#menu input { width: 100%; box-sizing: border-box; margin-top: 6px; padding: 10px 12px; font: inherit; font-size: 16px; color: #eee; background: #0b0e12; border: 1px solid #2a3139; outline: none; }
#menu input:focus { border-color: #d71e28; }
#menu .row { display: flex; gap: 10px; margin-bottom: 12px; }
#menu .row input { margin-top: 0; }
#menu button { flex: 1; padding: 12px 14px; font: inherit; font-size: 16px; font-weight: bold; letter-spacing: 1px; color: #f0e6c8; background: #1a2027; border: 1px solid #3a434d; cursor: pointer; }
#menu button:hover:not(:disabled) { background: #2a1418; border-color: #d71e28; }
#menu button:disabled { opacity: 0.5; cursor: default; }
#menu .status { min-height: 20px; margin: 6px 0 12px; color: #ffd35c; font-size: 14px; }
#menu .help { margin: 0 0 10px; color: #7a8790; font-size: 12px; line-height: 1.5; }
#menu .help code { color: #c9d1d9; }
#menu .controls { margin: 0; color: #5e6a73; font-size: 12px; line-height: 1.6; }
`;
