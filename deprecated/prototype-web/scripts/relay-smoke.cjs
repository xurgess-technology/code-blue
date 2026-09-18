'use strict';
/**
 * End-to-end smoke test for server/relay.cjs.
 * Starts a relay on a free port, connects a host and two clients, and asserts
 * every protocol rule. Exits 0 on success, 1 on any failure or a 20 s hang.
 *
 *   node scripts/relay-smoke.cjs
 */

const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createRelay } = require('../server/relay.cjs');

const STEP_TIMEOUT_MS = 2000;
const QUIET_MS = 250; // how long we watch to prove a frame did NOT arrive

const watchdog = setTimeout(() => {
  console.error('FAIL: smoke test hung for 20 s');
  process.exit(1);
}, 20_000);

let stepNo = 0;
const step = (label) => console.log(`  ${String(++stepNo).padStart(2)}. ${label}`);

/** Thin wrapper that queues incoming JSON frames so nothing is lost between awaits. */
class Peer {
  constructor(ws, label) {
    this.ws = ws;
    this.label = label;
    this.queue = [];
    this.waiters = [];
    this.closed = new Promise((res) =>
      ws.once('close', (code, reason) => res({ code, reason: reason.toString() })),
    );
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw.toString());
      const w = this.waiters.shift();
      if (w) w(msg);
      else this.queue.push(msg);
    });
  }
  static connect(url, label) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.once('open', () => resolve(new Peer(ws, label)));
      ws.once('error', reject);
    });
  }
  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }
  sendRaw(text) {
    this.ws.send(text);
  }
  next(timeout = STEP_TIMEOUT_MS) {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== done);
        reject(new Error(`${this.label}: timed out waiting for a frame`));
      }, timeout);
      const done = (m) => {
        clearTimeout(t);
        resolve(m);
      };
      this.waiters.push(done);
    });
  }
  async expectQuiet(ms = QUIET_MS) {
    await new Promise((r) => setTimeout(r, ms));
    assert.equal(this.queue.length, 0, `${this.label} unexpectedly received ${JSON.stringify(this.queue)}`);
  }
  hello(role, name) {
    this.send({ t: 'hello', role, name });
    return this.next();
  }
  close() {
    this.ws.close();
    return this.closed;
  }
}

async function main() {
  const relay = await createRelay({ port: 0, host: '127.0.0.1' });
  const url = `ws://127.0.0.1:${relay.port}`;
  console.log(`relay listening on ${url}`);

  // --- hello / welcome --------------------------------------------------------
  step('client before any host is rejected with "no host"');
  const early = await Peer.connect(url, 'early-client');
  assert.deepEqual(await early.hello('client', 'Early'), { t: 'error', msg: 'no host' });
  assert.equal((await early.closed).code, 4002);

  step('host joins and gets welcome id=1, hostId=1, no peers');
  const host = await Peer.connect(url, 'host');
  assert.deepEqual(await host.hello('host', 'Host'), { t: 'welcome', id: 1, hostId: 1, peers: [] });

  step('second host is rejected with "already hosting"');
  const host2 = await Peer.connect(url, 'host2');
  assert.deepEqual(await host2.hello('host', 'Impostor'), { t: 'error', msg: 'already hosting' });
  assert.equal((await host2.closed).code, 4001);

  step('client Alice joins: welcome lists the host; host is notified');
  const alice = await Peer.connect(url, 'alice');
  assert.deepEqual(await alice.hello('client', 'Alice'), {
    t: 'welcome',
    id: 2,
    hostId: 1,
    peers: [{ id: 1, name: 'Host' }],
  });
  assert.deepEqual(await host.next(), { t: 'peer', id: 2, name: 'Alice', joined: true });

  step('client Bob joins: welcome lists host+Alice; host and Alice are notified');
  const bob = await Peer.connect(url, 'bob');
  assert.deepEqual(await bob.hello('client', 'Bob'), {
    t: 'welcome',
    id: 3,
    hostId: 1,
    peers: [
      { id: 1, name: 'Host' },
      { id: 2, name: 'Alice' },
    ],
  });
  assert.deepEqual(await host.next(), { t: 'peer', id: 3, name: 'Bob', joined: true });
  assert.deepEqual(await alice.next(), { t: 'peer', id: 3, name: 'Bob', joined: true });

  // --- routing ----------------------------------------------------------------
  step('host broadcast to "all" reaches both clients, not the host');
  host.send({ t: 'msg', to: 'all', data: { tick: 1, state: [1, 2, 3] } });
  assert.deepEqual(await alice.next(), { t: 'msg', from: 1, data: { tick: 1, state: [1, 2, 3] } });
  assert.deepEqual(await bob.next(), { t: 'msg', from: 1, data: { tick: 1, state: [1, 2, 3] } });
  await host.expectQuiet();

  step('host direct message to id 3 reaches only Bob');
  host.send({ t: 'msg', to: 3, data: 'bob-only' });
  assert.deepEqual(await bob.next(), { t: 'msg', from: 1, data: 'bob-only' });
  await alice.expectQuiet();

  step('client -> "host" is delivered to the host');
  alice.send({ t: 'msg', to: 'host', data: { input: 'jump' } });
  assert.deepEqual(await host.next(), { t: 'msg', from: 2, data: { input: 'jump' } });

  step('client -> another client id is forced to the host');
  bob.send({ t: 'msg', to: 2, data: 'sneaky' });
  assert.deepEqual(await host.next(), { t: 'msg', from: 3, data: 'sneaky' });
  await alice.expectQuiet();

  step('client -> "all" is forced to the host');
  bob.send({ t: 'msg', to: 'all', data: 'shout' });
  assert.deepEqual(await host.next(), { t: 'msg', from: 3, data: 'shout' });
  await alice.expectQuiet();

  step('malformed JSON and unknown frame types are ignored; connection survives');
  alice.sendRaw('{not json');
  alice.send({ t: 'bogus', to: 'host', data: 1 });
  alice.send({ t: 'msg', to: 'host', data: 'still-here' });
  assert.deepEqual(await host.next(), { t: 'msg', from: 2, data: 'still-here' });
  await bob.expectQuiet();

  step('a frame over 256 KB gets the sender closed (1009) without disturbing others');
  const fat = await Peer.connect(url, 'fat');
  assert.equal((await fat.hello('client', 'Fat')).t, 'welcome');
  assert.deepEqual(await host.next(), { t: 'peer', id: 4, name: 'Fat', joined: true });
  await alice.next(); // peer joined
  await bob.next(); // peer joined
  fat.sendRaw(JSON.stringify({ t: 'msg', to: 'host', data: 'x'.repeat(300 * 1024) }));
  assert.equal((await fat.closed).code, 1009);
  assert.deepEqual(await host.next(), { t: 'peer', id: 4, name: 'Fat', joined: false });
  await alice.next();
  await bob.next();

  // --- leave notifications ----------------------------------------------------
  step('Alice leaves: host and Bob get peer joined:false');
  await alice.close();
  assert.deepEqual(await host.next(), { t: 'peer', id: 2, name: 'Alice', joined: false });
  assert.deepEqual(await bob.next(), { t: 'peer', id: 2, name: 'Alice', joined: false });

  step('host leaves: Bob gets hostLeft and is closed');
  await host.close();
  assert.deepEqual(await bob.next(), { t: 'hostLeft' });
  assert.equal((await bob.closed).code, 4003);

  step('a new host is accepted afterwards; ids keep incrementing');
  const host3 = await Peer.connect(url, 'host3');
  assert.deepEqual(await host3.hello('host', 'NewHost'), { t: 'welcome', id: 5, hostId: 5, peers: [] });
  const carol = await Peer.connect(url, 'carol');
  assert.deepEqual(await carol.hello('client', 'Carol'), {
    t: 'welcome',
    id: 6,
    hostId: 5,
    peers: [{ id: 5, name: 'NewHost' }],
  });
  assert.deepEqual(await host3.next(), { t: 'peer', id: 6, name: 'Carol', joined: true });

  step('relay.close() terminates remaining peers and stops the server');
  await relay.close();
  await Promise.all([host3.closed, carol.closed]);
  await assert.rejects(Peer.connect(url, 'after-close'), 'relay should refuse connections after close');

  clearTimeout(watchdog);
  console.log('RELAY SMOKE OK');
}

main().catch((err) => {
  console.error('RELAY SMOKE FAILED');
  console.error(err);
  process.exit(1);
});
