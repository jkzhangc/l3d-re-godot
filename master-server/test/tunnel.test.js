// 隧道中继自测（阶段 1 本机验证）
//
// 覆盖：
//   1. REGISTER → REGISTERED 流程
//   2. 外网客户端 UDP → 中继 → 房主 TCP（入站）
//   3. 房主 TCP → 中继 → 外网客户端 UDP（出站）
//   4. 多客户端按来源地址区分（不同 clientId）
//   5. RELEASE 释放端口
//   6. 端口池耗尽时拒绝注册
//   7. KEEPALIVE 刷新超时
//
// 用高端口避免与真实服务冲突：TCP 10081，UDP 40000-40002

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import net from 'node:net';
import dgram from 'node:dgram';
import { EventEmitter } from 'node:events';
import { TunnelRelay, MSG, encodeMessage } from '../src/tunnel_relay.js';

const TCP_PORT = 10090;
const UDP_START = 40000;
const UDP_END = 40002;

let relay;

function createHostClient(port = TCP_PORT) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1', () => resolve(sock));
    sock.on('error', reject);
    sock._recvBuf = Buffer.alloc(0);
    sock.on('data', (data) => {
      sock._recvBuf = Buffer.concat([sock._recvBuf, data]);
    });
  });
}

function readMessage(sock, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('readMessage timeout')), timeoutMs);
    const check = () => {
      if (sock._recvBuf && sock._recvBuf.length >= 4) {
        const msgLen = sock._recvBuf.readUInt32BE(0);
        if (sock._recvBuf.length >= 4 + msgLen) {
          clearTimeout(timer);
          const msg = sock._recvBuf.subarray(4, 4 + msgLen);
          sock._recvBuf = sock._recvBuf.subarray(4 + msgLen);
          resolve({ type: msg[0], payload: msg.subarray(1) });
          return;
        }
      }
      setTimeout(check, 10);
    };
    check();
  });
}

function createUdpClient() {
  const sock = dgram.createSocket('udp4');
  sock.bind(0, '127.0.0.1');
  return sock;
}

function udpRecv(sock, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('udpRecv timeout')), timeoutMs);
    sock.once('message', (msg, rinfo) => {
      clearTimeout(timer);
      resolve({ msg, rinfo });
    });
  });
}

// 以 Node write 语义模拟部分底层发送：整帧只接纳一次，未发送字节保留在 writableLength。
function createControlledSocket(relay, results = []) {
  const socket = new EventEmitter();
  socket.writes = [];
  socket.writableLength = 0;
  socket.destroyed = false;
  socket.destroyCalls = 0;
  socket.setNoDelay = (value) => { socket.noDelay = value; };
  socket.write = (frame) => {
    socket.writes.push(Buffer.from(frame));
    const result = results.shift();
    if (result === false) socket.writableLength += frame.length;
    return result;
  };
  socket.end = () => { socket.writableEnded = true; };
  socket.destroy = () => {
    socket.destroyCalls++;
    socket.destroyed = true;
    socket.writableLength = 0;
    socket.emit('close');
  };
  relay._handleConnection(socket);
  return socket;
}

function attachControlledTunnel(relay, socket) {
  const port = relay.availablePorts.values().next().value;
  let closeCalls = 0;
  const tunnel = {
    id: 'controlled', port, hostSocket: socket,
    udpSocket: { close: () => { closeCalls++; } },
    clients: new Map(), addrToClientId: new Map(),
    nextClientId: 1, freeClientIds: [], lastKeepalive: 1,
  };
  socket._tunnel = tunnel;
  relay.availablePorts.delete(port);
  relay.tunnels.set(tunnel.id, tunnel);
  return { tunnel, getCloseCalls: () => closeCalls };
}

function assertSendClean(relay, socket) {
  const stats = relay.getStats();
  for (const key of ['queuedFrames', 'queuedBytes', 'writableBytes', 'pendingBytes', 'backpressuredConnections']) {
    assert.strictEqual(stats[key], 0, `${key} 应清零`);
  }
  assert.strictEqual(socket._sendState.queue.length, 0);
  assert.strictEqual(socket._sendState.queuedBytes, 0);
  assert.strictEqual(socket.listenerCount('drain'), 0);
  assert.strictEqual(relay._sendSockets.size, 0);
}

describe('TunnelRelay', () => {
  before(async () => {
    relay = new TunnelRelay({
      tcpPort: TCP_PORT,
      portStart: UDP_START,
      portEnd: UDP_END,
    });
    await relay.start();
  });

  after(async () => {
    await relay.stop();
  });

  test('REGISTER → REGISTERED，分配 UDP 端口', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, JSON.stringify({
      protocol: 'test_v1', gameVersion: 'v0.33',
    })));

    const msg = await readMessage(host);
    assert.strictEqual(msg.type, MSG.REGISTERED);
    const info = JSON.parse(msg.payload.toString());
    assert.ok(info.tunnelId, '应有 tunnelId');
    assert.ok(info.tunnelPort >= UDP_START && info.tunnelPort <= UDP_END, '端口在池范围内');
    host.end();
  });

  test('UDP 入站 → 房主收到 RELAY_TO_HOST', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;

    // 外网客户端发 UDP 包到隧道端口
    const client = createUdpClient();
    await new Promise(r => client.on('listening', r));
    const testData = Buffer.from('HELLO_FROM_CLIENT');
    client.send(testData, tunnelPort, '127.0.0.1');

    // 房主应收到 RELAY_TO_HOST
    const msg = await readMessage(host, 3000);
    assert.strictEqual(msg.type, MSG.RELAY_TO_HOST);
    assert.strictEqual(msg.payload.length, 2 + testData.length, '2字节clientId+数据');
    const clientId = msg.payload.readUInt16BE(0);
    const data = msg.payload.subarray(2);
    assert.deepStrictEqual(data, testData, '数据应原样到达');
    assert.ok(clientId >= 1, 'clientId ≥ 1');
    client.close();
    host.end();
  });

  test('房主 → UDP 出站回程送达外网客户端', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;

    // 客户端先发一个包（建立会话映射），然后等回包
    const client = createUdpClient();
    await new Promise(r => client.on('listening', r));
    const clientPort = client.address().port;
    client.send(Buffer.from('PING'), tunnelPort, '127.0.0.1');

    // 房主收到入站包，拿到 clientId
    const inbound = await readMessage(host, 3000);
    assert.strictEqual(inbound.type, MSG.RELAY_TO_HOST);
    const clientId = inbound.payload.readUInt16BE(0);

    // 房主发回包
    const echoData = Buffer.from('ECHO_REPLY');
    const relayPayload = Buffer.allocUnsafe(2 + echoData.length);
    relayPayload.writeUInt16BE(clientId, 0);
    echoData.copy(relayPayload, 2);
    host.write(encodeMessage(MSG.RELAY_FROM_HOST, relayPayload));

    // 客户端应收到回包
    const recv = await udpRecv(client, 3000);
    assert.deepStrictEqual(recv.msg, echoData, '回包数据应一致');
    client.close();
    host.end();
  });

  test('多客户端区分：两个客户端各自收到自己的回包', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;

    const c1 = createUdpClient();
    const c2 = createUdpClient();
    await Promise.all([
      new Promise(r => c1.on('listening', r)),
      new Promise(r => c2.on('listening', r)),
    ]);

    c1.send(Buffer.from('C1_PING'), tunnelPort, '127.0.0.1');
    c2.send(Buffer.from('C2_PING'), tunnelPort, '127.0.0.1');

    // 房主收到两个入站包，clientId 应不同
    const in1 = await readMessage(host, 3000);
    const in2 = await readMessage(host, 3000);
    const id1 = in1.payload.readUInt16BE(0);
    const id2 = in2.payload.readUInt16BE(0);
    assert.notStrictEqual(id1, id2, '两个客户端应有不同 clientId');

    // 回包给各自
    const reply1 = Buffer.from('REPLY_FOR_C1');
    const p1 = Buffer.allocUnsafe(2 + reply1.length);
    p1.writeUInt16BE(id1, 0); reply1.copy(p1, 2);
    host.write(encodeMessage(MSG.RELAY_FROM_HOST, p1));

    const reply2 = Buffer.from('REPLY_FOR_C2');
    const p2 = Buffer.allocUnsafe(2 + reply2.length);
    p2.writeUInt16BE(id2, 0); reply2.copy(p2, 2);
    host.write(encodeMessage(MSG.RELAY_FROM_HOST, p2));

    // 各自收到自己的回包
    const r1 = await udpRecv(c1, 3000);
    const r2 = await udpRecv(c2, 3000);
    assert.deepStrictEqual(r1.msg, reply1, 'C1 收到自己的回包');
    assert.deepStrictEqual(r2.msg, reply2, 'C2 收到自己的回包');

    c1.close(); c2.close(); host.end();
  });

  test('RELEASE 释放端口后端口回到池', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;

    // 注册后端口应被占用
    const statsBefore = relay.getStats();
    assert.ok(statsBefore.availablePorts < statsBefore.totalPorts, '注册后有空闲端口少于总数');

    host.write(encodeMessage(MSG.RELEASE, ''));
    await new Promise(r => setTimeout(r, 150));

    const statsAfter = relay.getStats();
    assert.ok(statsAfter.availablePorts > statsBefore.availablePorts, 'RELEASE 后空闲端口增加');
    host.end();
  });

  test('端口池耗尽时返回 ERROR', async () => {
    // 等前一个测试的连接清理完
    await new Promise(r => setTimeout(r, 200));
    // 池只有 3 个端口（40000-40002），开 3 个隧道占满
    const hosts = [];
    for (let i = 0; i < 3; i++) {
      const h = await createHostClient();
      h.write(encodeMessage(MSG.REGISTER, '{}'));
      await readMessage(h); // REGISTERED
      hosts.push(h);
    }
    // 第 4 个应被拒绝
    const h4 = await createHostClient();
    h4.write(encodeMessage(MSG.REGISTER, '{}'));
    const msg = await readMessage(h4);
    assert.strictEqual(msg.type, MSG.ERROR);
    const err = JSON.parse(msg.payload.toString());
    assert.match(err.message, /no_available_ports/);

    for (const h of hosts) h.end();
    h4.end();
  });

  // ── clientId 溢出 / 回收（2026-10 修：旧实现 nextClientId++ 无上限，
  //    超 65535 时 buf.writeUInt16BE 抛 ERR_OUT_OF_RANGE → dgram 回调未捕获 →
  //    中继进程退出，所有房间/隧道全挂）──

  test('★ clientId 用尽后从回收池复用，绝不抛 ERR_OUT_OF_RANGE', async () => {
    await new Promise(r => setTimeout(r, 200));   // 等端口池清理
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;
    const tunnel = [...relay.tunnels.values()].find(t => t.port === tunnelPort);

    // 前置：模拟"新 id 已耗尽、回收池里有 3 个空闲 id"
    tunnel.nextClientId = 0x10000;      // 已越界
    tunnel.freeClientIds = [7, 300, 65535];
    const errors = [];
    tunnel.udpSocket.on('error', (e) => errors.push(e));
    let uncaught = null;
    const onUncaught = (e) => { uncaught = e; };
    process.on('uncaughtException', onUncaught);

    // 3 个不同来源的客户端各发一包 → 应从回收池取到 3 个 id（且都 ≤ 65535）
    const clients = [];
    for (let i = 0; i < 3; i++) {
      const c = createUdpClient();
      await new Promise(r => c.on('listening', r));
      clients.push(c);
      c.send(Buffer.from(`C${i}`), tunnelPort, '127.0.0.1');
    }
    await new Promise(r => setTimeout(r, 400));

    process.off('uncaughtException', onUncaught);
    assert.strictEqual(uncaught, null, '不得抛未捕获异常（否则进程会退出）');
    assert.strictEqual(errors.length, 0, 'udp socket 不应报错');
    assert.strictEqual(tunnel.freeClientIds.length, 0, '回收池应被取空');
    // 每个 clientId 都在 16 位内
    for (const id of tunnel.clients.keys()) {
      assert.ok(id >= 1 && id <= 0xffff, `clientId ${id} 应在 1..65535`);
    }
    clients.forEach(c => c.close());
    host.end();
  });

  test('★ clientId 池彻底耗尽：丢弃并告警，不崩溃', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;
    const tunnel = [...relay.tunnels.values()].find(t => t.port === tunnelPort);

    // 前置：新 id 越界 + 回收池为空 → 无法再分配
    tunnel.nextClientId = 0x10000;
    tunnel.freeClientIds = [];
    const before = tunnel.clients.size;
    let uncaught = null;
    const onUncaught = (e) => { uncaught = e; };
    process.on('uncaughtException', onUncaught);

    const c = createUdpClient();
    await new Promise(r => c.on('listening', r));
    c.send(Buffer.from('DROP'), tunnelPort, '127.0.0.1');
    await new Promise(r => setTimeout(r, 400));

    process.off('uncaughtException', onUncaught);
    assert.strictEqual(uncaught, null, '池耗尽也必须不抛异常');
    assert.strictEqual(tunnel.clients.size, before, '池耗尽时不新增客户端映射');
    c.close();
    host.end();
  });

  test('clientId 回收：超时客户端的 id 被归还到回收池', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;
    const tunnel = [...relay.tunnels.values()].find(t => t.port === tunnelPort);

    const c = createUdpClient();
    await new Promise(r => c.on('listening', r));
    c.send(Buffer.from('X'), tunnelPort, '127.0.0.1');
    await new Promise(r => setTimeout(r, 300));
    assert.ok(tunnel.clients.size >= 1, '客户端应已被映射');
    const assignedIds = [...tunnel.clients.keys()];

    // 把所有客户端的 lastSeen 推到超时之外，触发 _sweep
    for (const cl of tunnel.clients.values()) cl.lastSeen = 0;
    relay._sweep();

    assert.strictEqual(tunnel.clients.size, 0, '超时客户端应被清理');
    for (const id of assignedIds) {
      assert.ok(tunnel.freeClientIds.includes(id), `id ${id} 应被归还到回收池`);
    }
    c.close();
    host.end();
  });

  // ── 接收缓冲上限（2026-10 修 P3：帧头是对端可控的 32 位值，旧实现直接信任 →
  //    伪造 msgLen=0xFFFFFFFF 后灌数据会让 _recvBuf 无限增长，实测 5MB→5MB）──

  test('★ 伪造超大帧头：立即断开连接，缓冲不无限增长', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    await readMessage(host);

    // 发一个声称 msgLen=0xFFFFFFFF 的帧头，随后灌 1MB 数据
    host.write(Buffer.from([0xff, 0xff, 0xff, 0xff]));
    const chunk = Buffer.alloc(64 * 1024, 0x41);
    for (let i = 0; i < 16; i++) host.write(chunk);

    const closed = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 2000);
      host.once('close', () => { clearTimeout(timer); resolve(true); });
    });
    assert.ok(closed, '协议违规连接应被中继断开（socket.destroy）');
  });

  test('正常帧长（≤ 上限）不受影响', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;
    assert.ok(tunnelPort > 0, '正常注册仍成功（帧长校验未误伤合法流量）');
    host.end();
  });

  // ── 每 IP 并发隧道上限（2026-10 补 P4：中继 REGISTER 无凭据 → 用每 IP 并发上限
  //    做纵深防御，防单 IP 刷满仅 27 个的公网端口池）──

  test('★ 每 IP 并发隧道达上限后被拒绝（too_many_tunnels）', async () => {
    const relay2 = new TunnelRelay({
      tcpPort: 10091,
      portStart: 40010,
      portEnd: 40012,
      maxTunnelsPerIp: 2,
    });
    await relay2.start();
    try {
      // 前 2 个同源（127.0.0.1）隧道应成功
      const h1 = await createHostClient(10091);
      h1.write(encodeMessage(MSG.REGISTER, '{}'));
      assert.strictEqual((await readMessage(h1)).type, MSG.REGISTERED);

      const h2 = await createHostClient(10091);
      h2.write(encodeMessage(MSG.REGISTER, '{}'));
      assert.strictEqual((await readMessage(h2)).type, MSG.REGISTERED);

      // 第 3 个应被拒绝
      const h3 = await createHostClient(10091);
      h3.write(encodeMessage(MSG.REGISTER, '{}'));
      const msg = await readMessage(h3);
      assert.strictEqual(msg.type, MSG.ERROR);
      assert.match(JSON.parse(msg.payload.toString()).message, /too_many_tunnels/);

      // 释放一个后，同 IP 应能再注册（计数随销毁递减）
      h1.end();
      await new Promise(r => setTimeout(r, 150));
      const h4 = await createHostClient(10091);
      h4.write(encodeMessage(MSG.REGISTER, '{}'));
      assert.strictEqual((await readMessage(h4)).type, MSG.REGISTERED, '释放后应可再注册');

      h2.end(); h3.end(); h4.end();
    } finally {
      await relay2.stop();
    }
  });

  // ── NAT 端口漂移（P5，2026-10 记录语义，非缺陷）──
  //   clientId 以来源 "addr:port" 为键；对称 NAT 下同一客户端源端口会变 →
  //   被当作新 clientId（ENet 视角里成为另一个 peer）。这是 UDP-over-TCP 的固有边界，
  //   硬按 IP 归并会误伤同 IP 的多玩家（NAT 后多人共用一个公网 IP），故不修，仅钉住语义。

  test('NAT 端口漂移：不同源端口 → 不同 clientId（记录固有语义）', async () => {
    const host = await createHostClient();
    host.write(encodeMessage(MSG.REGISTER, '{}'));
    const reg = await readMessage(host);
    const tunnelPort = JSON.parse(reg.payload.toString()).tunnelPort;
    const tunnel = [...relay.tunnels.values()].find(t => t.port === tunnelPort);

    const c1 = createUdpClient();
    await new Promise(r => c1.on('listening', r));
    c1.send(Buffer.from('A'), tunnelPort, '127.0.0.1');
    await new Promise(r => setTimeout(r, 200));
    const afterFirst = tunnel.clients.size;

    const c2 = createUdpClient();
    await new Promise(r => c2.on('listening', r));
    c2.send(Buffer.from('B'), tunnelPort, '127.0.0.1');
    await new Promise(r => setTimeout(r, 200));

    assert.strictEqual(tunnel.clients.size, afterFirst + 1,
      '不同源端口被登记为不同 clientId（端口漂移 = 新会话）');
    c1.close(); c2.close();
    host.end();
  });
});

describe('TunnelRelay 发送背压', () => {
  test('非法注册JSON不抛异常、不占UDP端口，按协议返回错误并结束', () => {
    for (const payload of ['null', '[]', '123', '"scalar"', '{broken']) {
      const relay = new TunnelRelay();
      const socket = createControlledSocket(relay);
      const ports = relay.availablePorts.size;
      assert.doesNotThrow(() => socket.emit('data', encodeMessage(MSG.REGISTER, payload)));
      assert.strictEqual(relay.tunnels.size, 0);
      assert.strictEqual(relay.availablePorts.size, ports);
      assert.strictEqual(socket.writableEnded, true);
      const frame = socket.writes[0];
      assert.strictEqual(frame[4], MSG.ERROR);
      assert.strictEqual(JSON.parse(frame.subarray(5).toString()).message, 'invalid_register');
      socket.destroy();
      assertSendClean(relay, socket);
    }
  });

  test('write 返回 undefined 的正常 stub 兼容，协议及字节统计不变', () => {
    const relay = new TunnelRelay();
    const socket = createControlledSocket(relay);
    for (const data of [undefined, '中文', Buffer.from([0, 255])]) {
      assert.strictEqual(relay._sendMsg(socket, MSG.RELAY_TO_HOST, data), true);
      assert.deepStrictEqual(socket.writes.at(-1), encodeMessage(MSG.RELAY_TO_HOST, data));
    }
    assert.strictEqual(socket.noDelay, true);
    const stats = relay.getStats();
    assert.strictEqual(stats.tcpAcceptedFrames, 3);
    assert.strictEqual(stats.tcpAcceptedBytes, socket.writes.reduce((n, frame) => n + frame.length, 0));
    assert.strictEqual(stats.backpressureEvents, 0);
    assert.strictEqual(stats.queuedFrames, 0);
    socket.destroy();
    assertSendClean(relay, socket);
  });

  test('部分底层写入后等待 drain，连续背压按序恢复且不重复接纳已写帧', () => {
    const relay = new TunnelRelay();
    const socket = createControlledSocket(relay, [false, false, undefined]);
    const payloads = ['first', 'second', 'third'];
    const frames = payloads.map(data => encodeMessage(MSG.ERROR, data));
    for (const data of payloads) assert.strictEqual(relay._sendMsg(socket, MSG.ERROR, data), true);
    assert.strictEqual(socket.writes.length, 1);
    let stats = relay.getStats();
    assert.strictEqual(stats.queuedFrames, 2);
    assert.strictEqual(stats.queuedBytes, frames[1].length + frames[2].length);
    assert.strictEqual(stats.writableBytes, frames[0].length);
    assert.strictEqual(stats.pendingBytes, frames.reduce((n, frame) => n + frame.length, 0));
    assert.strictEqual(stats.backpressuredConnections, 1);
    assert.strictEqual(stats.peakQueuedFrames, 2);
    assert.strictEqual(stats.peakQueuedBytes, stats.queuedBytes);
    assert.strictEqual(stats.peakPendingBytes, stats.pendingBytes);

    socket.writableLength -= 3;
    assert.strictEqual(relay.getStats().writableBytes, frames[0].length - 3);
    assert.strictEqual(socket.writes.length, 1, '部分完成不能触发重发或提前发送后续帧');
    socket.writableLength = 0;
    socket.emit('drain');
    assert.strictEqual(socket.writes.length, 2, '第二帧再次 false 后必须停止');
    assert.strictEqual(relay.getStats().queuedFrames, 1);
    socket.writableLength = 0;
    socket.emit('drain');
    socket.emit('drain');
    assert.deepStrictEqual(socket.writes, frames, '整帧按序且恰好写一次');
    stats = relay.getStats();
    assert.strictEqual(stats.tcpAcceptedFrames, 3);
    assert.strictEqual(stats.tcpAcceptedBytes, frames.reduce((n, frame) => n + frame.length, 0));
    assert.strictEqual(stats.queuedBytes, 0);
    assert.strictEqual(stats.pendingBytes, 0);
    assert.strictEqual(stats.backpressuredConnections, 0);
    assert.strictEqual(stats.backpressureEvents, 2);
    assert.strictEqual(stats.drainEvents, 2);
    socket.destroy();
    assertSendClean(relay, socket);
    assert.strictEqual(relay.getStats().backpressureEvents, 2, '累计观测不随清理丢失');
  });

  for (const [label, opts] of [
    ['帧数', { maxQueuedFrames: 2 }],
    ['应用字节', { maxQueuedBytes: 18 }],
    ['总待写字节', { maxPendingBytes: 27 }],
  ]) {
    test(`${label}预算：等于上限可接纳，持续 UDP 超限立即断连释放且不假成功`, () => {
      const relay = new TunnelRelay(opts);
      const socket = createControlledSocket(relay, [false]);
      const { tunnel, getCloseCalls } = attachControlledTunnel(relay, socket);
      const rinfo = { address: '127.0.0.1', port: 50000 };
      // 每个 UDP 帧 4B 长度 + 1B 类型 + 2B clientId + 2B 数据 = 9B。
      for (let i = 0; i < 3; i++) relay._handleUdpMessage(tunnel, Buffer.from('AB'), rinfo);
      assert.strictEqual(relay.getStats().queuedFrames, 2);
      assert.strictEqual(relay.getStats().queuedBytes, 18);
      assert.strictEqual(relay.getStats().pendingBytes, 27);
      relay._handleUdpMessage(tunnel, Buffer.from('CD'), rinfo);
      assert.strictEqual(socket.destroyed, true);
      assert.strictEqual(relay.getStats().activeTunnels, 0);
      assert.strictEqual(relay.getStats().availablePorts, relay.getStats().totalPorts);
      assert.strictEqual(relay.getStats().totalClients, 0);
      assert.strictEqual(relay.getStats().sendOverflowDisconnects, 1);
      assert.strictEqual(getCloseCalls(), 1);
      assert.strictEqual(tunnel.clients.size, 0);
      assert.strictEqual(tunnel.addrToClientId.size, 0);
      assert.strictEqual(socket._tunnel, null);
      for (let i = 0; i < 100; i++) relay._handleUdpMessage(tunnel, Buffer.from('late'), rinfo);
      socket.emit('drain');
      assert.strictEqual(socket.writes.length, 1, '销毁后晚到 UDP/drain 不得继续写或入队');
      assert.strictEqual(relay._sendMsg(socket, MSG.KEEPALIVE), false);
      assert.strictEqual(socket.destroyCalls, 1);
      assertSendClean(relay, socket);
    });
  }

  test('无背压时单帧已超过总预算也拒绝，零队列预算不允许额外入队', () => {
    const relay = new TunnelRelay({ maxPendingBytes: 5 });
    const socket = createControlledSocket(relay);
    assert.strictEqual(relay._sendMsg(socket, MSG.ERROR, 'X'), false);
    assert.strictEqual(socket.writes.length, 0);
    assert.strictEqual(relay.getStats().tcpAcceptedFrames, 0);
    assert.strictEqual(relay.getStats().sendOverflowDisconnects, 1);
    assertSendClean(relay, socket);

    const relay2 = new TunnelRelay({ maxQueuedFrames: 0, maxQueuedBytes: 0 });
    const socket2 = createControlledSocket(relay2, [false]);
    assert.strictEqual(relay2._sendMsg(socket2, MSG.KEEPALIVE), true);
    assert.strictEqual(relay2._sendMsg(socket2, MSG.KEEPALIVE), false);
    assert.strictEqual(socket2.writes.length, 1);
    assertSendClean(relay2, socket2);
  });

  for (const reason of ['release', 'close', 'error', 'write_throw', 'timeout', 'stop']) {
    test(`${reason} 清理队列、UDP、映射和监听器，重复清理及晚到 drain 无副作用`, async () => {
      const relay = new TunnelRelay({ now: () => 200000 });
      const socket = createControlledSocket(relay, [false]);
      const { tunnel, getCloseCalls } = attachControlledTunnel(relay, socket);
      relay._handleUdpMessage(tunnel, Buffer.from('first'), { address: '127.0.0.1', port: 50001 });
      relay._sendMsg(socket, MSG.KEEPALIVE);
      assert.strictEqual(relay.getStats().queuedFrames, 1);
      socket._recvBuf = Buffer.from([0, 0]);
      const lateDrain = socket._sendState.onDrain;
      if (reason === 'release') {
        const released = Buffer.concat([encodeMessage(MSG.RELEASE), encodeMessage(MSG.REGISTER, '{}')]);
        socket._recvBuf = released.subarray(0, 2);
        socket.emit('data', released.subarray(2));
      } else if (reason === 'close') socket.destroy();
      else if (reason === 'error') socket.emit('error', new Error('测试连接错误'));
      else if (reason === 'write_throw') {
        socket.write = () => { throw new Error('测试写错误'); };
        socket.writableLength = 0;
        socket.emit('drain');
      } else if (reason === 'timeout') relay._sweep();
      else await relay.stop();
      lateDrain();
      socket.emit('close');
      relay._destroyTunnel(tunnel, 'again');
      assert.strictEqual(getCloseCalls(), 1);
      assert.strictEqual(socket.destroyCalls, 1);
      assert.strictEqual(socket._tunnel, null);
      assert.strictEqual(socket._recvBuf.length, 0);
      assert.strictEqual(relay.getStats().activeTunnels, 0);
      assert.strictEqual(relay.getStats().availablePorts, relay.getStats().totalPorts);
      assert.strictEqual(socket.writes.length, 1);
      assert.strictEqual(relay.getStats().writeErrors, reason === 'write_throw' ? 1 : 0);
      assertSendClean(relay, socket);
    });
  }

  test('分片帧头/载荷和粘包跨背压恢复仍按 TCP framing 解析', () => {
    let now = 10;
    const relay = new TunnelRelay({ now: () => now });
    const socket = createControlledSocket(relay, [false]);
    const { tunnel } = attachControlledTunnel(relay, socket);
    const frames = [encodeMessage(MSG.RELAY_TO_HOST, Buffer.from([0, 1, 2, 3])), encodeMessage(MSG.KEEPALIVE)];
    relay._sendMsg(socket, MSG.RELAY_TO_HOST, Buffer.from([0, 1, 2, 3]));
    relay._sendMsg(socket, MSG.KEEPALIVE);
    const received = [];
    const receiverRelay = new TunnelRelay();
    const peer = createControlledSocket(receiverRelay);
    receiverRelay._handleMessage = (_socket, frame) => received.push(Buffer.from(frame));
    const first = socket.writes[0];
    peer.emit('data', first.subarray(0, 2));
    assert.strictEqual(received.length, 0);
    peer.emit('data', first.subarray(2, 6));
    assert.strictEqual(received.length, 0);
    socket.writableLength = 0;
    socket.emit('drain');
    peer.emit('data', Buffer.concat([first.subarray(6), socket.writes[1]]));
    assert.deepStrictEqual(received, frames.map(frame => frame.subarray(4)));
    assert.strictEqual(peer._recvBuf.length, 0);

    now = 99;
    const keepalive = encodeMessage(MSG.KEEPALIVE);
    socket.emit('data', keepalive.subarray(0, 3));
    assert.strictEqual(tunnel.lastKeepalive, 1);
    socket.emit('data', keepalive.subarray(3));
    assert.strictEqual(tunnel.lastKeepalive, 99);
    socket.destroy(); peer.destroy();
  });

  test('配置上限必须有限且为非负安全整数', () => {
    for (const key of ['maxQueuedFrames', 'maxQueuedBytes', 'maxPendingBytes']) {
      for (const value of [-1, NaN, Infinity, 1.5, '10']) {
        assert.throws(() => new TunnelRelay({ [key]: value }), RangeError);
      }
    }
  });
});
