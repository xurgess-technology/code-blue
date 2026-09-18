// Glues a Game to a Transport. The host simulates and broadcasts; clients report their surgeon and mirror.
import { Game } from '../game';
import { Transport } from './transport';
import type { ClientMsg, HostMsg } from './protocol';

const NET_HZ = 20;

export class Session {
  private acc = 0;
  private welcomed = false;
  closed = false;
  reason = '';

  constructor(public game: Game, public transport: Transport | null, public name: string) {
    game.solo = !transport;
    game.isHost = !transport || transport.isHost;
    if (!transport) {
      game.addPlayer(1, name, true);
      game.startLobby(Math.floor(Math.random() * 1e9), 1);
      return;
    }
    if (transport.isHost) {
      game.addPlayer(transport.id, name, true);
      game.startLobby(Math.floor(Math.random() * 1e9), 1);
      for (const peer of transport.peers.values()) this.hostAdd(peer.id, peer.name);
      transport.onPeer = (peer, joined) => { if (joined) this.hostAdd(peer.id, peer.name); else game.removePlayer(peer.id); };
      transport.onMessage = (from, data) => {
        const msg = data as ClientMsg;
        if (msg?.t === 'state') game.applyRemoteState(from, msg.s);
      };
    } else {
      game.localId = transport.id;
      transport.onMessage = (_from, data) => {
        const msg = data as HostMsg;
        if (msg?.t === 'welcome') {
          this.welcomed = true;
          game.localId = msg.id;
          game.startLobby(msg.seed, msg.shift);
          if (!game.players.has(msg.id)) game.addPlayer(msg.id, name, true);
          game.phase = msg.phase;
        } else if (msg?.t === 'snap') {
          if (!game.players.has(game.localId)) game.addPlayer(game.localId, name, true);
          game.applySnapshot(msg.snap);
        }
      };
    }
    transport.onClose = (reason) => { this.closed = true; this.reason = reason; };
  }

  private hostAdd(id: number, name: string) {
    const g = this.game;
    if (g.players.has(id)) return;
    g.addPlayer(id, name);
    g.say(`${name} clocked in.`, 3);
    const welcome: HostMsg = { t: 'welcome', id, seed: g.seed, shift: g.shift, phase: g.phase };
    this.transport!.send(id, welcome);
  }

  /** Call once per frame after game.update. */
  update(dt: number) {
    const t = this.transport;
    if (!t || this.closed) { this.game.events.length = 0; return; }
    this.acc += dt;
    if (this.acc < 1 / NET_HZ) return;
    this.acc = 0;
    if (t.isHost) {
      if (t.peers.size === 0) { this.game.events.length = 0; return; }
      const msg: HostMsg = { t: 'snap', snap: this.game.snapshot() };
      t.send('all', msg);
    } else if (this.welcomed && this.game.local) {
      const msg: ClientMsg = { t: 'state', s: this.game.localState() };
      t.send('host', msg);
    }
  }

  close() {
    this.transport?.close();
    this.closed = true;
  }
}
