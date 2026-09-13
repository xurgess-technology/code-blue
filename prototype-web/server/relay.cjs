'use strict';
/**
 * Code Blue co-op relay.
 *
 * A tiny star-topology WebSocket relay: exactly one host, any number of
 * clients. Clients only ever talk to the host; the host may talk to any
 * client or broadcast to all of them.
 *
 * Wire protocol (JSON text frames):
 *   peer  -> relay : {"t":"hello","role":"host"|"client","name":"..."}
 *   relay -> peer  : {"t":"welcome","id":N,"hostId":N|0,"peers":[{"id":N,"name":"..."}]}
 *                    (peers = everyone already connected, excluding yourself)
 *   relay -> peer  : {"t":"error","msg":"already hosting"|"no host"} then close
 *   relay -> others: {"t":"peer","id":N,"name":"...","joined":true|false}
 *   peer  -> relay : {"t":"msg","to":N|"all"|"host","data":<json>}
 *   relay -> target: {"t":"msg","from":N,"data":<json>}
 *                    (client messages are always delivered to the host only;
 *                     "all" from the host means every client)
 *   relay -> clients: {"t":"hostLeft"} then close, when the host disconnects
 *
 * Keepalive: ws ping every 15 s; a peer that misses two pongs is terminated.
 * Frames larger than 256 KB cause the ws library to close the connection.
 *
 * Usage as a module:
 *   const { createRelay } = require('./server/relay.cjs');
 *   const relay = await createRelay({ port: 7777 });   // -> { port, close() }
 *
 * Usage from the command line:
 *   node server/relay.cjs --port 7777 [--host 0.0.0.0]
 */

const os = require('node:os');
const { WebSocketServer } = require('ws');

const MAX_PAYLOAD_BYTES = 256 * 1024;
const PING_INTERVAL_MS = 15_000;
const MAX_MISSED_PONGS = 2;
const MAX_NAME_LENGTH = 64;

// Application-level close codes (4000-4999 are free for application use).
const CLOSE_ALREADY_HOSTING = 4001;
const CLOSE_NO_HOST = 4002;
const CLOSE_HOST_LEFT = 4003;
const CLOSE_BAD_HELLO = 4004;

/** Non-internal IPv4 addresses of this machine (for showing "join at ..."). */
function lanAddresses() {
  const out = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const e of entries || []) {
      if (e.internal) continue;
      const isV4 = e.family === 'IPv4' || e.family === 4;
      if (isV4 && e.address && !out.includes(e.address)) out.push(e.address);
    }
  }
  return out;
}

/**
 * @param {{ port?: number, host?: string, log?: (line: string) => void }} opts
 * @returns {Promise<{ port: number, close: () => Promise<void> }>}
 */
function createRelay({ port = 0, host = '0.0.0.0', log = () => {} } = {}) {
  return new Promise((resolve, reject) => {
    const wss = new WebSocketServer({ port, host, maxPayload: MAX_PAYLOAD_BYTES });

    /** @type {Map<number, {id:number, ws:import('ws').WebSocket, name:string, role:'host'|'client', gone:boolean}>} */
    const peers = new Map();
    let nextId = 1;
    let hostId = 0;

    const sendRaw = (ws, text) => {
      if (ws.readyState === ws.OPEN) ws.send(text);
    };
    const send = (ws, obj) => sendRaw(ws, JSON.stringify(obj));
    const sendErrorAndClose = (ws, msg, code) => {
      send(ws, { t: 'error', msg });
      ws.close(code, msg);
    };
    const broadcastExcept = (exceptId, obj) => {
      const text = JSON.stringify(obj);
      for (const p of peers.values()) if (p.id !== exceptId) sendRaw(p.ws, text);
    };

    function handleHello(ws, msg) {
      const role = msg.role === 'host' || msg.role === 'client' ? msg.role : null;
      if (!role) {
        sendErrorAndClose(ws, 'bad role', CLOSE_BAD_HELLO);
        return null;
      }
      if (role === 'host' && hostId !== 0) {
        sendErrorAndClose(ws, 'already hosting', CLOSE_ALREADY_HOSTING);
        return null;
      }
      if (role === 'client' && hostId === 0) {
        sendErrorAndClose(ws, 'no host', CLOSE_NO_HOST);
        return null;
      }
      const name = typeof msg.name === 'string' ? msg.name.slice(0, MAX_NAME_LENGTH) : '';
      const id = nextId++;
      const peer = { id, ws, name, role, gone: false };

      const others = [...peers.values()].map((p) => ({ id: p.id, name: p.name }));
      peers.set(id, peer);
      if (role === 'host') hostId = id;

      send(ws, { t: 'welcome', id, hostId, peers: others });
      broadcastExcept(id, { t: 'peer', id, name, joined: true });
      log(`join  #${id} ${role} "${name}" (${peers.size} connected)`);
      return peer;
    }

    function handleMsg(peer, msg) {
      const out = JSON.stringify({ t: 'msg', from: peer.id, data: msg.data });

      // Clients can only ever reach the host, whatever they asked for.
      if (peer.role === 'client') {
        const h = peers.get(hostId);
        if (h) sendRaw(h.ws, out);
        return;
      }

      // Host -> one client / every client.
      const to = msg.to;
      if (to === 'all') {
        for (const p of peers.values()) if (p.id !== peer.id) sendRaw(p.ws, out);
        return;
      }
      const targetId =
        typeof to === 'number' ? to : typeof to === 'string' && /^\d+$/.test(to) ? Number(to) : NaN;
      if (Number.isInteger(targetId) && targetId !== peer.id) {
        const p = peers.get(targetId);
        if (p) sendRaw(p.ws, out);
      }
      // "host" from the host (or an unknown target) is dropped silently.
    }

    function handleLeave(peer) {
      if (peer.gone) return;
      peer.gone = true;
      peers.delete(peer.id);
      log(`leave #${peer.id} ${peer.role} "${peer.name}" (${peers.size} connected)`);

      if (peer.role === 'host' && hostId === peer.id) {
        hostId = 0;
        const clients = [...peers.values()];
        peers.clear(); // so the clients' own close handlers don't spam peer-left frames
        for (const c of clients) {
          c.gone = true;
          send(c.ws, { t: 'hostLeft' });
          c.ws.close(CLOSE_HOST_LEFT, 'host left');
        }
        if (clients.length) log(`host left; dropped ${clients.length} client(s)`);
        return;
      }
      broadcastExcept(peer.id, { t: 'peer', id: peer.id, name: peer.name, joined: false });
    }

    wss.on('connection', (ws) => {
      ws.missedPongs = 0;
      let peer = null;

      ws.on('pong', () => {
        ws.missedPongs = 0;
      });

      ws.on('message', (raw, isBinary) => {
        if (isBinary) return;
        let msg;
        try {
          msg = JSON.parse(raw.toString('utf8'));
        } catch {
          return; // malformed JSON is ignored
        }
        if (!msg || typeof msg !== 'object') return;

        if (!peer) {
          if (msg.t === 'hello') peer = handleHello(ws, msg);
          return; // anything before a valid hello is ignored
        }
        if (msg.t === 'msg') handleMsg(peer, msg);
      });

      ws.on('close', () => {
        if (peer) handleLeave(peer);
      });
      ws.on('error', () => {
        /* 'close' follows; nothing else to do */
      });
    });

    const pingTimer = setInterval(() => {
      for (const ws of wss.clients) {
        if (ws.missedPongs >= MAX_MISSED_PONGS) {
          ws.terminate();
          continue;
        }
        ws.missedPongs = (ws.missedPongs || 0) + 1;
        ws.ping();
      }
    }, PING_INTERVAL_MS);

    function close() {
      return new Promise((done) => {
        clearInterval(pingTimer);
        for (const ws of wss.clients) ws.terminate();
        peers.clear();
        hostId = 0;
        wss.close(() => done());
      });
    }

    wss.once('error', (err) => reject(err));
    wss.once('listening', () => {
      wss.removeAllListeners('error');
      wss.on('error', (err) => log(`server error: ${err.message}`));
      resolve({ port: wss.address().port, close });
    });
  });
}

module.exports = { createRelay, lanAddresses };

if (require.main === module) {
  const args = process.argv.slice(2);
  const argValue = (flag, fallback) => {
    const i = args.indexOf(flag);
    return i !== -1 && args[i + 1] !== undefined ? args[i + 1] : fallback;
  };
  const port = Number(argValue('--port', 7777));
  const host = argValue('--host', '0.0.0.0');
  const stamp = () => new Date().toISOString().slice(11, 19);

  createRelay({ port, host, log: (line) => console.log(`[${stamp()}] ${line}`) })
    .then((relay) => {
      console.log(`[${stamp()}] relay listening on ${host}:${relay.port}`);
      const addrs = lanAddresses();
      if (addrs.length) {
        console.log(`[${stamp()}] LAN addresses: ${addrs.map((a) => `ws://${a}:${relay.port}`).join('  ')}`);
      }
      const shutdown = () => {
        console.log(`[${stamp()}] shutting down`);
        relay.close().then(() => process.exit(0));
      };
      process.on('SIGINT', shutdown);
      process.on('SIGTERM', shutdown);
    })
    .catch((err) => {
      console.error(`relay failed to start: ${err.message}`);
      process.exit(1);
    });
}
