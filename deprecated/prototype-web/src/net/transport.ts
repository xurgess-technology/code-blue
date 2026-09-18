// Transport abstraction. Today there is one implementation, a WebSocket relay (server/relay.cjs).
// Steam peer-to-peer can be added later as another implementation of the same interface.

export interface PeerInfo { id: number; name: string }

export interface Transport {
  readonly id: number;
  readonly hostId: number;
  readonly isHost: boolean;
  readonly peers: Map<number, PeerInfo>;
  send(to: number | 'all' | 'host', data: unknown): void;
  onMessage: ((from: number, data: unknown) => void) | null;
  onPeer: ((peer: PeerInfo, joined: boolean) => void) | null;
  onClose: ((reason: string) => void) | null;
  close(): void;
}

interface RelayFrame {
  t: string;
  id?: number; hostId?: number; peers?: PeerInfo[];
  name?: string; joined?: boolean;
  from?: number; data?: unknown; msg?: string;
}

class RelayTransport implements Transport {
  id = 0;
  hostId = 0;
  peers = new Map<number, PeerInfo>();
  onMessage: ((from: number, data: unknown) => void) | null = null;
  onPeer: ((peer: PeerInfo, joined: boolean) => void) | null = null;
  onClose: ((reason: string) => void) | null = null;
  private closed = false;

  constructor(private ws: WebSocket, public readonly isHost: boolean) {}

  send(to: number | 'all' | 'host', data: unknown) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify({ t: 'msg', to, data }));
  }

  handle(frame: RelayFrame) {
    switch (frame.t) {
      case 'peer': {
        const peer = { id: frame.id!, name: frame.name ?? 'Surgeon' };
        if (frame.joined) this.peers.set(peer.id, peer); else this.peers.delete(peer.id);
        this.onPeer?.(peer, !!frame.joined);
        break;
      }
      case 'msg':
        this.onMessage?.(frame.from ?? 0, frame.data);
        break;
      case 'hostLeft':
        this.fail('The host left the game.');
        break;
      case 'error':
        this.fail(frame.msg ?? 'Relay error');
        break;
    }
  }

  fail(reason: string) {
    if (this.closed) return;
    this.closed = true;
    this.onClose?.(reason);
    try { this.ws.close(); } catch { /* already closed */ }
  }

  close() {
    this.closed = true;
    try { this.ws.close(); } catch { /* already closed */ }
  }
}

/** Normalize what a friend typed into a ws:// URL. "10.0.0.5" becomes "ws://10.0.0.5:7777". */
export function relayUrl(input: string, defaultPort = 7777): string {
  let s = input.trim();
  if (!s) s = 'localhost';
  if (!/^wss?:\/\//.test(s)) s = 'ws://' + s;
  const u = new URL(s);
  if (!u.port) u.port = String(defaultPort);
  return u.toString().replace(/\/$/, '');
}

export function connectRelay(url: string, role: 'host' | 'client', name: string, timeoutMs = 8000): Promise<Transport> {
  return new Promise((resolve, reject) => {
    let ws: WebSocket;
    try { ws = new WebSocket(url); } catch (e) { reject(new Error(`Bad address: ${url}`)); return; }
    const transport = new RelayTransport(ws, role === 'host');
    let settled = false;
    const timer = setTimeout(() => { if (!settled) { settled = true; ws.close(); reject(new Error('Connection timed out')); } }, timeoutMs);
    ws.onopen = () => ws.send(JSON.stringify({ t: 'hello', role, name }));
    ws.onerror = () => { if (!settled) { settled = true; clearTimeout(timer); reject(new Error(`Could not reach ${url}`)); } };
    ws.onclose = () => {
      if (!settled) { settled = true; clearTimeout(timer); reject(new Error('Connection closed before joining')); return; }
      transport.fail('Disconnected');
    };
    ws.onmessage = (ev) => {
      let frame: RelayFrame;
      try { frame = JSON.parse(String(ev.data)); } catch { return; }
      if (!settled) {
        if (frame.t === 'welcome') {
          settled = true; clearTimeout(timer);
          transport.id = frame.id ?? 0;
          transport.hostId = frame.hostId ?? 0;
          for (const p of frame.peers ?? []) transport.peers.set(p.id, p);
          resolve(transport);
        } else if (frame.t === 'error') {
          settled = true; clearTimeout(timer);
          ws.close();
          reject(new Error(frame.msg ?? 'Rejected by relay'));
        }
        return;
      }
      transport.handle(frame);
    };
  });
}
