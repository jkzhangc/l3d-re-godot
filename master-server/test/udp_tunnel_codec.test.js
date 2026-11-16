import { test } from 'node:test';
import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import { once } from 'node:events';
import { UdpTunnelCodec, MAX_PAYLOAD, MAX_DATAGRAM, REPLAY_WINDOW } from '../src/udp_tunnel_codec.js';

const SOURCE = { address: '127.0.0.1', port: 27994 };
const ID = Buffer.from('0001020304050607', 'hex');
const KEY = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const VECTOR = '4c3344550100000102030405060700000000000102ffb7b4cc6229cad9781e775cffcb80b798';
function codec(direction, extra = {}) {
  return new UdpTunnelCodec({ sessionId: ID, key: KEY, txDirection: direction,
    source: SOURCE, expiresAt: 20000, now: () => 1000, ...extra });
}

test('fixed big-endian HMAC vector matches Godot fixture', () => {
  const packet = codec(0).seal(Buffer.from('000102ff', 'hex'));
  assert.equal(packet.toString('hex'), VECTOR);
  assert.deepEqual(codec(1).open(packet, SOURCE), Buffer.from('000102ff', 'hex'));
});

test('source pinning rejects wrong endpoint without claiming replay sequence', () => {
  const rx = codec(1), packet = codec(0).seal(Buffer.from('one'));
  assert.equal(rx.open(packet, { ...SOURCE, port: 1 }), null);
  assert.equal(rx.open(packet, { ...SOURCE, address: '127.0.0.2' }), null);
  assert.equal(rx.highest, -1);
  assert.equal(rx.open(packet, SOURCE).toString(), 'one');
});

test('tamper, wrong key, direction reflection, session and malformed headers are rejected', () => {
  const tx = codec(0), rx = codec(1), packet = tx.seal(Buffer.from('one'));
  for (const offset of [0, 4, 5, 6, 14, 18, packet.length - 1]) {
    const bad = Buffer.from(packet); bad[offset] ^= 1;
    assert.equal(rx.open(bad, SOURCE), null);
  }
  assert.equal(codec(1, { key: Buffer.alloc(32, 7) }).open(packet, SOURCE), null);
  assert.equal(tx.open(packet, SOURCE), null);
  assert.equal(rx.open(Buffer.alloc(10), SOURCE), null);
  assert.equal(rx.open(Buffer.alloc(MAX_DATAGRAM + 1), SOURCE), null);
  assert.equal(rx.highest, -1);
});

test('loss and reorder do not create a head-of-line wait; duplicate is suppressed', () => {
  const tx = codec(0), rx = codec(1);
  const packets = [0, 1, 2, 3].map(i => tx.seal(Buffer.from([i])));
  assert.deepEqual(rx.open(packets[3], SOURCE), Buffer.from([3]));
  assert.deepEqual(rx.open(packets[1], SOURCE), Buffer.from([1]));
  assert.equal(rx.open(packets[1], SOURCE), null);
  assert.deepEqual(rx.open(packets[2], SOURCE), Buffer.from([2]));
  // packet 0 was deliberately lost. Reliable recovery belongs to ENet, not this codec.
});

test('replay window remains bounded and expires old datagrams', () => {
  const tx = codec(0), rx = codec(1), packets = [];
  for (let i = 0; i < REPLAY_WINDOW + 20; i++) packets.push(tx.seal(Buffer.from([1])));
  for (const p of packets) assert.ok(rx.open(p, SOURCE));
  assert.equal(rx.seen.size, REPLAY_WINDOW);
  assert.equal(rx.open(packets[0], SOURCE), null);
});

test('MTU accepts ENet upper bound and refuses oversize and empty payload', () => {
  const tx = codec(0), rx = codec(1), payload = Buffer.alloc(MAX_PAYLOAD, 9);
  const packet = tx.seal(payload);
  assert.equal(packet.length, MAX_DATAGRAM);
  assert.deepEqual(rx.open(packet, SOURCE), payload);
  assert.equal(tx.seal(Buffer.alloc(MAX_PAYLOAD + 1)), null);
  assert.equal(tx.seal(Buffer.alloc(0)), null);
});

test('expiry, close, sequence exhaustion and new session reject old data', () => {
  let now = 1000;
  const tx = codec(0), rx = codec(1, { now: () => now });
  const packet = tx.seal(Buffer.from([1]));
  now = 20000;
  assert.equal(rx.open(packet, SOURCE), null);
  const renewed = codec(1, { sessionId: Buffer.alloc(8, 9), key: Buffer.alloc(32, 8) });
  assert.equal(renewed.open(packet, SOURCE), null);
  tx.nextSequence = 0xffffffff;
  assert.ok(tx.seal(Buffer.from([1])));
  assert.equal(tx.seal(Buffer.from([1])), null);
  rx.close();
  assert.ok(rx.key.every(x => x === 0));
  assert.equal(rx.open(packet, SOURCE), null);
});

test('authenticated token bucket refills and rejected sequence may be retried', () => {
  let now = 1000;
  const tx = codec(0), rx = codec(1, { packetsPerSecond: 1, now: () => now });
  const a = tx.seal(Buffer.from([1])), b = tx.seal(Buffer.from([2]));
  assert.ok(rx.open(a, SOURCE));
  assert.equal(rx.open(b, SOURCE), null);
  now += 1000;
  assert.deepEqual(rx.open(b, SOURCE), Buffer.from([2]));
});

test('configuration rejects non-IP source and already expired deadline', () => {
  assert.throws(() => codec(0, { source: { address: 'not-an-ip', port: 1 } }), TypeError);
  assert.throws(() => codec(0, { expiresAt: 1000 }), TypeError);
});

test('unseen replay-window edges and high-bit sequences are accepted exactly once', () => {
  const tx = codec(0), rx = codec(1);
  tx.nextSequence = 44; const outside = tx.seal(Buffer.from([44]));
  const edge = tx.seal(Buffer.from([45]));
  tx.nextSequence = 300;
  assert.ok(rx.open(tx.seal(Buffer.from([1])), SOURCE));
  assert.ok(rx.open(edge, SOURCE));
  assert.equal(rx.open(outside, SOURCE), null);
  tx.nextSequence = 0x80000000;
  assert.ok(rx.open(tx.seal(Buffer.from([2])), SOURCE));
  tx.nextSequence = 0xffffffff;
  assert.ok(rx.open(tx.seal(Buffer.from([3])), SOURCE));
});

test('byte bucket independently limits large packets and refills', () => {
  let now = 1000;
  const tx = codec(0), rx = codec(1, { bytesPerSecond: MAX_DATAGRAM, now: () => now });
  assert.ok(rx.open(tx.seal(Buffer.alloc(MAX_PAYLOAD)), SOURCE));
  const next = tx.seal(Buffer.from([1]));
  assert.equal(rx.open(next, SOURCE), null);
  now += 1000;
  assert.ok(rx.open(next, SOURCE));
});

test('real localhost UDP loss/reorder/duplicates preserve accepted payloads', async () => {
  const socket = dgram.createSocket('udp4');
  const sender = dgram.createSocket('udp4');
  try {
    socket.bind(0, '127.0.0.1'); sender.bind(0, '127.0.0.1');
    await Promise.all([once(socket, 'listening'), once(sender, 'listening')]);
    const port = socket.address().port;
    const tx = codec(0), rx = codec(1, { source: { address: '127.0.0.1', port: sender.address().port } });
    const packets = Array.from({ length: 12 }, (_, i) => tx.seal(Buffer.from([i])));
    // Lost 0/4/8; pairwise reorder; inject duplicate and corruption.
    const order = [2, 1, 3, 6, 5, 7, 10, 9, 11, 3];
    const accepted = [], received = [];
    const completed = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('UDP fixture timeout')), 2000);
      socket.on('message', (data, source) => {
        const payload = rx.open(data, source);
        if (payload) accepted.push(payload[0]);
        received.push(data);
        if (received.length === order.length + 1) { clearTimeout(timer); resolve(); }
      });
    });
    for (const i of order) await new Promise((resolve, reject) => sender.send(packets[i], port, '127.0.0.1', e => e ? reject(e) : resolve()));
    const bad = Buffer.from(packets[0]); bad[18] ^= 1;
    await new Promise((resolve, reject) => sender.send(bad, port, '127.0.0.1', e => e ? reject(e) : resolve()));
    await completed;
    assert.deepEqual(accepted, [2, 1, 3, 6, 5, 7, 10, 9, 11]);
  } finally {
    socket.close(); sender.close();
  }
});
