import test from 'node:test';
import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import { spawn } from 'node:child_process';
import { setTimeout as wait } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { UdpEnetLab } from './network_udp_enet_proxy.mjs';
import { UdpTunnelCodec, MAX_PAYLOAD, MAX_DATAGRAM } from '../master-server/src/udp_tunnel_codec.js';

const ADDRESS = '127.0.0.1';

async function until(predicate, message, timeout = 8000) {
  const deadline = performance.now() + timeout;
  while (!predicate()) {
    if (performance.now() >= deadline) assert.fail(message);
    await wait(10);
  }
}

async function socket(t, onMessage = () => {}) {
  const result = dgram.createSocket('udp4');
  const errors = [];
  result.on('error', error => errors.push(error));
  result.on('message', onMessage);
  await new Promise((resolve, reject) => {
    result.once('error', reject);
    result.bind(0, ADDRESS, () => { result.off('error', reject); resolve(); });
  });
  t.after(async () => {
    await new Promise(resolve => {
      try { result.close(resolve); } catch (error) {
        if (error.code !== 'ERR_SOCKET_DGRAM_NOT_RUNNING') throw error;
        resolve();
      }
    });
    assert.deepEqual(errors, [], '测试 socket 不应产生 I/O 错误');
  });
  return result;
}

function send(from, payload, port) {
  return new Promise((resolve, reject) => {
    from.send(payload, port, ADDRESS, error => error ? reject(error) : resolve());
  });
}

async function fixture(t, options = {}) {
  const hostPackets = [];
  const host = await socket(t, (packet, source) => {
    hostPackets.push({ packet: Buffer.from(packet), source });
    host.send(packet, source.port, source.address, error => {
      assert.ifError(error);
    });
  });
  const lab = new UdpEnetLab({ hostPort: host.address().port, ...options });
  t.after(() => lab.close());
  const ready = await lab.start();
  return { host, hostPackets, lab, ready };
}

test('真实 UDP 双客户端 echo、身份隔离、来源锁定和原始包边界', async t => {
  const { lab, ready, hostPackets } = await fixture(t);
  assert.equal(ready.address, ADDRESS);
  assert.equal(new Set(ready.ports).size, 2);
  assert.deepEqual(await lab.start(), ready);
  const received = [[], []];
  const clients = await Promise.all(received.map(messages => socket(t, packet => messages.push(Buffer.from(packet)))));
  const payloads = [Buffer.from('client-0'), Buffer.alloc(1392, 0x71)];
  await Promise.all(clients.map((client, index) => send(client, payloads[index], ready.ports[index])));
  await until(() => received.every(messages => messages.length === 1), '两个客户端应收到自己的 echo');
  for (let index = 0; index < clients.length; index++) assert.deepEqual(received[index], [payloads[index]]);
  assert.equal(new Set(hostPackets.map(entry => entry.source.port)).size, 2, '后端必须使用不同的源端口');
  for (const entry of hostPackets) assert.equal(entry.source.address, ADDRESS);
  const stranger = await socket(t);
  await send(stranger, Buffer.from('not-the-owner'), ready.ports[0]);
  await send(clients[0], Buffer.alloc(1393), ready.ports[0]);
  await send(clients[0], Buffer.alloc(0), ready.ports[0]);
  await until(() => {
    const totals = lab.getStats().totals;
    return totals.frontendRejectedSources === 1 && totals.rawOversizePackets === 1 && totals.rawEmptyPackets === 1;
  }, '来源和载荷边界应显式计数');
  assert.equal(hostPackets.length, 2);
  assert.equal(lab.getStats().totals.ioErrors, 0);
  assert.equal(lab.getStats().limits.maxDatagramBytes, 1426);
  await Promise.all([lab.close(), lab.close()]);
  assert.equal(lab.getStats().state, 'closed');
  assert.equal(lab._sockets.size, 0);
  assert.equal(lab._timer, null);
  assert.equal(lab.getStats().queue.packets, 0);
  await assert.rejects(lab.start(), /关闭/);
});

test('空包和超长首包不得抢占 frontend 客户端来源', async t => {
  const { lab, ready, hostPackets } = await fixture(t, { clients: 1 });
  const stranger = await socket(t);
  await send(stranger, Buffer.alloc(0), ready.ports[0]);
  await send(stranger, Buffer.alloc(MAX_PAYLOAD + 1), ready.ports[0]);
  await until(() => lab.getStats().totals.rawPackets === 2, '无效首包应记录');
  assert.equal(lab._sessions[0].peer, null);
  assert.equal(lab.getStats().totals.rawEmptyPackets, 1);
  assert.equal(lab.getStats().totals.rawOversizePackets, 1);
  const received = [];
  const client = await socket(t, packet => received.push(packet));
  await send(client, Buffer.alloc(MAX_PAYLOAD, 0x7a), ready.ports[0]);
  await until(() => received.length === 1, '合法客户端仍应取得来源所有权');
  assert.equal(lab._sessions[0].peer.port, client.address().port);
  assert.equal(hostPackets.length, 1);
  const stats = lab.getStats();
  assert.equal(stats.totals.frontendRejectedSources, 0);
  assert.equal(stats.totals.maxRawPacketBytes, MAX_PAYLOAD + 1);
  assert.equal(stats.sessions[0].c2h.maxSealedPacketBytes, MAX_DATAGRAM);
  assert.equal(stats.sessions[0].h2c.maxTransportPacketBytes, MAX_DATAGRAM);
});

async function externalFixture(t, options = {}) {
  const lab = new UdpEnetLab({ hostPort: 12345, clients: 1, externalHost: true, ...options });
  t.after(() => lab.close());
  const ready = await lab.start();
  const config = lab.getExternalHostConfig();
  const workers = [];
  for (const entry of config.sessions) {
    const worker = { accepted: [], rejected: 0, packets: [] };
    worker.transport = await socket(t, (packet, source) => {
      worker.packets.push(Buffer.from(packet));
      const raw = worker.codec.open(packet, source);
      if (!raw) { worker.rejected++; return; }
      worker.accepted.push(raw);
      worker.transport.send(worker.codec.seal(raw), entry.return_port, ADDRESS, error => assert.ifError(error));
    });
    worker.codec = new UdpTunnelCodec({ sessionId: Buffer.from(entry.session_id_hex, 'hex'),
      key: Buffer.from(entry.key_hex, 'hex'), txDirection: 1,
      source: { address: ADDRESS, port: entry.source_port }, expiresAt: performance.now() + config.ttl_msec });
    t.after(() => worker.codec.close());
    workers.push(worker);
  }
  return { lab, ready, config, workers,
    attach: () => lab.attachExternalHost({ ports: workers.map(worker => worker.transport.address().port) }) };
}

test('externalHost 双会话 codec 回环、双向真实去重、私有配置与 close 擦零', async t => {
  const { lab, ready, config, workers, attach } = await externalFixture(t, { clients: 2, duplicate: 1 });
  assert.equal(ready.externalHost, true);
  assert.equal(config.host_port, ready.hostPort);
  assert.equal(config.ttl_msec, 120000);
  assert.equal(config.sessions.length, 2);
  assert.equal(lab._sockets.size, 6, '外部模式不创建 backend socket');
  assert.equal(new Set(config.sessions.map(entry => entry.session_id_hex)).size, 2);
  for (const [index, entry] of config.sessions.entries()) {
    assert.match(entry.session_id_hex, /^[a-f0-9]{16}$/);
    assert.match(entry.key_hex, /^[a-f0-9]{64}$/);
    assert.equal(entry.source_port, lab._sessions[index].leftTransportPort);
    assert.equal(entry.return_port, lab._sessions[index].rightTransportPort);
    assert.notEqual(entry.source_port, entry.return_port);
    assert.equal(lab._sessions[index].rightCodec, undefined);
    assert.equal(lab._sessions[index].backend, undefined);
  }
  for (const ports of [[], [1], [1, 1], [0, 2], [65536, 2], [1.5, 2], ['1', 2], new Array(2)]) {
    assert.throws(() => lab.attachExternalHost({ ports }), /ports/);
  }
  attach();
  assert.throws(attach, /首次/);
  const received = [[], []];
  const clients = await Promise.all(received.map(messages => socket(t, packet => messages.push(Buffer.from(packet)))));
  const payloads = [Buffer.alloc(MAX_PAYLOAD, 0x65), Buffer.from('external-client-1')];
  await Promise.all(clients.map((client, index) => send(client, payloads[index], ready.ports[index])));
  await until(() => received.every(messages => messages.length === 1)
    && workers.every(worker => worker.rejected === 1)
    && lab.getStats().totals.authRejectedPackets === 2, '两个方向应各自在最终 codec 拒绝封包副本');
  for (const [index, worker] of workers.entries()) {
    assert.deepEqual(received[index], [payloads[index]], '不得二次 seal 或跨会话返回');
    assert.deepEqual(worker.accepted, [payloads[index]]);
    assert.equal(worker.packets.length, 2);
    assert.deepEqual(worker.packets[0], worker.packets[1], '故障副本必须保持封包和序列号');
  }
  const stats = lab.getStats();
  assert.equal(stats.sessions[0].h2c.rawPackets, 0, '外部 h2c 不应进入 Node raw/seal');
  assert.equal(stats.sessions[0].c2h.authAcceptedPackets, 0, 'c2h 必须由外部 codec 验证');
  assert.equal(stats.totals.authAcceptedPackets, 2);
  assert.equal(stats.totals.maxSealedPacketBytes, MAX_DATAGRAM);
  assert.equal(stats.totals.maxTransportPacketBytes, MAX_DATAGRAM);
  assert.equal(stats.totals.ioErrors, 0);
  const publicJson = JSON.stringify({ ready, stats });
  assert.doesNotMatch(publicJson, /session_id_hex|key_hex|credentials/);
  for (const entry of config.sessions) {
    assert.ok(!publicJson.includes(entry.key_hex));
    assert.ok(!publicJson.includes(entry.session_id_hex));
  }
  const credentials = lab._sessions.map(session => session.credentials);
  await lab.close();
  assert.throws(() => lab.getExternalHostConfig(), /运行态/);
  assert.throws(attach, /运行态/);
  for (const [index, credential] of credentials.entries()) {
    assert.ok(credential.key.every(value => value === 0));
    assert.ok(credential.sessionId.every(value => value === 0));
    assert.ok(lab._sessions[index].leftCodec.key.every(value => value === 0));
    assert.ok(lab._sessions[index].leftCodec.id.every(value => value === 0));
  }
  assert.equal(lab._sockets.size, 0);
});

test('externalHost 固定双来源/封包边界、双向 loss，丢包不消耗回程防重放窗口', async t => {
  const { lab, ready, config, workers, attach } = await externalFixture(t, { loss: 1 });
  const session = lab._sessions[0];
  const worker = workers[0];
  const entry = config.sessions[0];
  const rogue = await socket(t);
  const received = [];
  const client = await socket(t, packet => received.push(packet.toString()));
  await send(client, Buffer.from('before-attach'), ready.ports[0]);
  await until(() => lab.getStats().totals.externalUnattachedPackets === 1, '未 attach 流量须明确计数且不得发送');
  attach();
  const reply = worker.codec.seal(Buffer.from('host-reply'));
  await send(rogue, reply, entry.return_port);
  await send(worker.transport, reply, entry.source_port);
  await until(() => lab.getStats().totals.wrongSourcePackets === 2, '外部入站及 leftTransport 均应固定来源');
  assert.equal(session.leftCodec.highest, -1);
  await send(worker.transport, Buffer.alloc(0), entry.return_port);
  await send(worker.transport, Buffer.alloc(34), entry.return_port);
  await send(worker.transport, Buffer.alloc(MAX_DATAGRAM + 1), entry.return_port);
  await until(() => lab.getStats().totals.transportUndersizePackets === 2
    && lab.getStats().totals.transportOversizePackets === 1, '错误封包长度须显式计数');
  await send(client, Buffer.from('lost-client'), ready.ports[0]);
  await send(worker.transport, reply, entry.return_port);
  await until(() => lab.getStats().sessions[0].c2h.lossDroppedPackets === 1
    && lab.getStats().sessions[0].h2c.lossDroppedPackets === 1, '两个方向均应对已经封装的报文丢包');
  assert.equal(worker.accepted.length, 0);
  assert.equal(received.length, 0);
  assert.equal(session.leftCodec.highest, -1, 'Node 不得提前 open 外部报文');
  lab.options.loss = 0;
  await send(worker.transport, reply, entry.return_port);
  await until(() => received.length === 1, '同一报文在故障移除后仍应通过认证');
  await send(worker.transport, reply, entry.return_port);
  await until(() => lab.getStats().totals.authRejectedPackets === 2, '首次错源和最终重放均应拒绝');
  const tampered = worker.codec.seal(Buffer.from('bad-auth'));
  tampered[tampered.length - 1] ^= 1;
  await send(worker.transport, tampered, entry.return_port);
  await until(() => lab.getStats().totals.authRejectedPackets === 3, '外部报文认证仍由 leftCodec 检查');
  await send(client, Buffer.from('recovered-client'), ready.ports[0]);
  await until(() => received.includes('recovered-client'), '双向链路应恢复');
  assert.deepEqual(received, ['host-reply', 'recovered-client']);
  assert.deepEqual(worker.accepted.map(packet => packet.toString()), ['recovered-client']);
  assert.equal(lab.getStats().totals.maxTransportPacketBytes, MAX_DATAGRAM + 1);
  assert.equal(lab.getStats().totals.ioErrors, 0);
});

test('封装后 duplicate 保留序列号，由两端 codec 真实去重', async t => {
  const { lab, ready, hostPackets } = await fixture(t, { clients: 1, duplicate: 1 });
  const received = [];
  const client = await socket(t, packet => received.push(packet.toString()));
  await send(client, Buffer.from('duplicate-check'), ready.ports[0]);
  await until(() => received.length === 1 && lab.getStats().totals.authRejectedPackets === 2,
    '两个方向的同序列号副本均应拒绝');
  assert.deepEqual(received, ['duplicate-check']);
  assert.equal(hostPackets.length, 1);
  const stats = lab.getStats();
  assert.equal(stats.totals.sealedPackets, 2);
  assert.equal(stats.totals.duplicatePackets, 2);
  assert.equal(stats.totals.transportSentPackets, 4);
  assert.equal(stats.totals.authAcceptedPackets, 2);
});

test('真实 transport UDP 拒绝错源、坏认证和跨 session 封包，且不污染重放窗口', async t => {
  const { lab, hostPackets } = await fixture(t);
  const [first, second] = lab._sessions;
  const rogue = await socket(t);
  const payload = Buffer.from('transport-auth');
  const packet = first.leftCodec.seal(payload);
  const port = first.rightTransport.address().port;
  await send(rogue, packet, port);
  await until(() => lab.getStats().totals.wrongSourcePackets === 1, '错源必须计数');
  const tampered = Buffer.from(packet);
  tampered[tampered.length - 1] ^= 1;
  await send(first.leftTransport, tampered, port);
  await send(second.leftTransport, packet, second.rightTransport.address().port);
  await until(() => lab.getStats().totals.authRejectedPackets === 3, '错误认证及跨 session 应被拒绝');
  assert.equal(hostPackets.length, 0);
  await send(first.leftTransport, packet, port);
  await until(() => hostPackets.length === 1, '先前错误封包不应污染合法序列号');
  await send(first.leftTransport, packet, port);
  await until(() => lab.getStats().totals.authRejectedPackets === 4, '合法封包重放仍须拒绝');
  assert.deepEqual(hostPackets[0].packet, payload);
  assert.equal(hostPackets[0].source.port, first.stats.backendPort);
});

test('5% 丢包加 jitter 的三客户端链路保持身份隔离，故障作用于封包', async t => {
  const { lab, ready, hostPackets } = await fixture(t, {
    clients: 3, seed: 31, loss: 0.05, delayMs: 4, jitterMs: 10,
  });
  const received = [[], [], []];
  const clients = await Promise.all(received.map(messages => socket(t, packet => messages.push(packet.toString()))));
  const count = 240;
  // 分批投递避免把操作系统 UDP 接收缓冲溢出误当作注入丢包。
  for (let base = 0; base < count; base += 12) {
    const sends = [];
    for (let index = base; index < base + 12; index++) {
      for (let client = 0; client < clients.length; client++) {
        sends.push(send(clients[client], Buffer.from(`${client}:${index}`), ready.ports[client]));
      }
    }
    await Promise.all(sends);
    await wait(10);
  }
  await until(() => {
    const stats = lab.getStats();
    return stats.totals.rawPackets >= count * clients.length
      && received.every(messages => messages.length > count / 2)
      && stats.queue.packets === 0
      && stats.totals.transportReceivedPackets === stats.totals.transportSentPackets
      && stats.totals.forwardedPackets === stats.totals.authAcceptedPackets;
  }, '弱网数据应排空且各客户端均收到足量 echo');
  // 让最后一批回包也完成投递，断言不依赖精确的到包数量。
  await wait(80);
  for (let client = 0; client < clients.length; client++) {
    assert.ok(received[client].every(message => message.startsWith(`${client}:`)), '不能跨客户端泄漏');
    assert.equal(new Set(received[client]).size, received[client].length);
  }
  const backendPorts = lab.getStats().sessions.map(session => session.backendPort);
  for (const { packet, source } of hostPackets) {
    const client = Number(packet.toString().split(':')[0]);
    assert.equal(source.port, backendPorts[client]);
  }
  const stats = lab.getStats();
  assert.ok(stats.totals.lossDroppedPackets > 0, '固定 seed 的足量数据应实际发生丢包');
  assert.equal(stats.totals.authRejectedPackets, 0);
  assert.equal(stats.totals.rawOversizePackets, 0);
  assert.equal(stats.totals.ioErrors, 0);
  assert.equal(stats.totals.transportSentPackets + stats.totals.lossDroppedPackets, stats.totals.sealedPackets);
  assert.ok(stats.totals.transportSentBytes < stats.totals.sealedBytes);
  assert.equal(stats.totals.transportSentBytes, stats.totals.transportReceivedBytes);
});

test('队列包数、字节和 2 秒年龄硬预算；close 不发送待到期数据', async t => {
  const { lab, ready, hostPackets } = await fixture(t, {
    clients: 1, delayMs: 10000, queueMaxPackets: 2, queueMaxBytes: 4096,
  });
  const client = await socket(t);
  for (let index = 0; index < 5; index++) await send(client, Buffer.alloc(32, index), ready.ports[0]);
  await until(() => lab.getStats().totals.rawPackets === 5, '应接收全部原始数据');
  assert.equal(lab.getStats().queue.packets, 2);
  assert.equal(lab.getStats().totals.queueOverflowPackets, 3);
  assert.ok(lab.getStats().queue.bytes <= 4096);
  await until(() => lab.getStats().totals.queueExpiredPackets === 2, '排队数据最多保存两秒');
  assert.equal(lab.getStats().queue.packets, 0);
  assert.equal(hostPackets.length, 0);
  await send(client, Buffer.from('pending-at-close'), ready.ports[0]);
  await until(() => lab.getStats().queue.packets === 1, '关闭前应有延迟数据');
  const session = lab._sessions[0];
  await Promise.all([lab.close(), lab.close()]);
  await lab.close();
  assert.equal(lab.getStats().totals.closeDroppedPackets, 1);
  assert.equal(lab.getStats().totals.transportSentPackets, 0);
  assert.equal(lab.getStats().queue.bytes, 0);
  assert.equal(session.leftCodec.closed, true);
  assert.equal(session.rightCodec.closed, true);
  assert.ok(session.leftCodec.key.every(value => value === 0));
  assert.ok(session.rightCodec.key.every(value => value === 0));
  assert.equal(lab._bound.size, 0);
  assert.equal(lab._timer, null);

  const bytes = await fixture(t, { clients: 1, delayMs: 10000, queueMaxPackets: 10, queueMaxBytes: 70 });
  await send(client, Buffer.alloc(32), bytes.ready.ports[0]);
  await send(client, Buffer.alloc(32), bytes.ready.ports[0]);
  await until(() => bytes.lab.getStats().totals.rawPackets === 2, '字节预算测试应接收原始数据');
  assert.equal(bytes.lab.getStats().queue.packets, 1);
  assert.equal(bytes.lab.getStats().queue.bytes, 66, '预算必须计算封装后字节数');
  assert.equal(bytes.lab.getStats().totals.queueOverflowPackets, 1);
});

test('双向一次性 blackout 在封包层丢弃，结束后恢复', async t => {
  const { host, lab, ready, hostPackets } = await fixture(t, { clients: 1, blackoutMs: 1500 });
  const received = [];
  const client = await socket(t, packet => received.push(packet.toString()));
  await send(client, Buffer.from('blackout-client'), ready.ports[0]);
  const session = lab._sessions[0];
  // 直接从已连接的真实 host 回包，覆盖 h2c 的 blackout。
  await send(host, Buffer.from('blackout-host'), session.stats.backendPort);
  await until(() => {
    const stats = lab.getStats().sessions[0];
    return stats.c2h.blackoutDroppedPackets >= 1 && stats.h2c.blackoutDroppedPackets >= 1;
  }, 'blackout 应同时暂停两个方向');
  await until(() => !lab._blackout(), 'blackout 应自行结束');
  await send(client, Buffer.from('recovered'), ready.ports[0]);
  await until(() => received.includes('recovered'), 'blackout 结束后应恢复');
  assert.ok(!hostPackets.some(({ packet }) => packet.toString() === 'blackout-client'));
});

test('发送错误统计、配置边界、启动中关闭和未启动关闭', async t => {
  for (const options of [{ clients: 0 }, { clients: 4 }, { loss: 1.1 }, { jitterMs: -1 },
    { queueMaxBytes: 0 }, { externalHost: 1 }, { externalHost: 'true' }]) {
    assert.throws(() => new UdpEnetLab({ hostPort: 12345, ...options }), /无效/);
  }
  const fresh = new UdpEnetLab({ hostPort: 12345 });
  await fresh.close();
  await fresh.close();
  assert.equal(fresh.getStats().state, 'closed');
  const pending = new UdpEnetLab({ hostPort: 12345 });
  const rejected = assert.rejects(pending.start(), /取消/);
  await pending.close();
  await rejected;
  assert.equal(pending._bound.size, 0);

  const { lab, ready } = await fixture(t, { clients: 1 });
  await new Promise(resolve => lab._sessions[0].backend.close(resolve));
  const client = await socket(t);
  await send(client, Buffer.from('closed-backend'), ready.ports[0]);
  await until(() => lab.getStats().totals.sendErrors === 1, '实际发送错误应统计而不是 uncaught');
  assert.equal(lab.getStats().totals.ioErrors, 1);
  await new Promise(resolve => lab._sessions[0].leftTransport.close(resolve));
  await send(client, Buffer.from('closed-transport'), ready.ports[0]);
  await until(() => lab.getStats().totals.sendErrors === 2, '真实 transport 关闭后的发送错误同样应计数');
  assert.equal(lab.getStats().totals.ioErrors, 2);
});

async function cli(t, hostPort, args = []) {
  const child = spawn(process.execPath, [fileURLToPath(new URL('./network_udp_enet_proxy.mjs', import.meta.url)),
    `--host-port=${hostPort}`, '--clients=1', ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let pending = '';
  const privateConfigs = [];
  let stderr = '';
  let exit = null;
  child.stdout.on('data', chunk => {
    pending += chunk;
    let newline;
    while ((newline = pending.indexOf('\n')) !== -1) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      if (line.startsWith('UDP_LAB_PRIVATE_CONFIG ')) privateConfigs.push(JSON.parse(line.slice('UDP_LAB_PRIVATE_CONFIG '.length)));
      else stdout += `${line}\n`;
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.once('exit', (code, signal) => { exit = { code, signal }; });
  t.after(async () => {
    if (!exit) {
      child.stdin.end();
      await until(() => exit, 'CLI 清理应退出');
    }
    assert.equal(stderr, '');
  });
  const lines = () => stdout.split('\n').filter(Boolean).map(line => {
    const separator = line.indexOf(' ');
    return { type: line.slice(0, separator), value: JSON.parse(line.slice(separator + 1)) };
  });
  await until(() => stdout.includes('UDP_LAB_READY ') && stdout.endsWith('\n'), 'CLI 应输出 ready');
  return { child, lines, privateConfigs, exited: () => exit, text: () => stdout };
}

test('CLI externalHost 只通过私有匿名管道请求凭据，attach 回执与常规输出不泄密', async t => {
  const instance = await cli(t, 12345, ['--external-host=1']);
  const ready = instance.lines().find(line => line.type === 'UDP_LAB_READY').value;
  assert.equal(ready.externalHost, true);
  assert.equal(instance.privateConfigs.length, 0, 'READY 不得自动输出凭据');
  instance.child.stdin.write('{"type":"external-config"}\n');
  await until(() => instance.privateConfigs.length === 1, '私有配置只在显式请求后返回');
  const config = instance.privateConfigs[0];
  assert.equal(config.sessions.length, 1);
  const transport = await socket(t);
  instance.child.stdin.write(`${JSON.stringify({ type: 'attach', ports: [transport.address().port] })}\n`);
  await until(() => instance.lines().some(line => line.type === 'UDP_LAB_ATTACHED'), 'attach 应输出公开确认');
  assert.deepEqual(instance.lines().find(line => line.type === 'UDP_LAB_ATTACHED').value, { attached: true });
  instance.child.stdin.write('{"type":"stats"}\n{"type":"close"}\n');
  await until(() => instance.exited(), '外部模式 close 应退出');
  assert.equal(instance.exited().code, 0);
  assert.doesNotMatch(instance.text(), /PRIVATE_CONFIG|session_id_hex|key_hex|credentials/);
  assert.ok(!instance.text().includes(config.sessions[0].key_hex));
  assert.ok(!instance.text().includes(config.sessions[0].session_id_hex));
  assert.equal(instance.lines().find(line => line.type === 'UDP_LAB_FINAL').value.state, 'closed');
});

test('CLI JSON 行 stats/close 以及 EOF 优雅退出，不输出会话凭据', async t => {
  const host = await socket(t);
  const first = await cli(t, host.address().port);
  first.child.stdin.write('{"type":"stats"}\n');
  await until(() => first.lines().some(line => line.type === 'UDP_LAB_STATS'), 'CLI 应输出统计');
  first.child.stdin.write('{"type":"blackout","durationMs":300}\n');
  await until(() => first.lines().some(line => line.type === 'UDP_LAB_BLACKOUT'), 'CLI应确认活跃期断流');
  first.child.stdin.write('{"type":"close"}\n');
  await until(() => first.exited(), 'close 命令应退出');
  assert.equal(first.exited().code, 0);
  const final = first.lines().find(line => line.type === 'UDP_LAB_FINAL');
  assert.equal(final.value.state, 'closed');
  assert.equal(final.value.queue.packets, 0);
  assert.equal(final.value.manualBlackouts, 1);
  assert.ok(final.value.nodeProcessCpuUsec.user >= 0);
  assert.doesNotMatch(first.text(), /"(?:key|id|sessionId)"/);
  const second = await cli(t, host.address().port);
  second.child.stdin.end();
  await until(() => second.exited(), 'EOF 应退出');
  assert.equal(second.exited().code, 0);
  assert.equal(second.lines().filter(line => line.type === 'UDP_LAB_FINAL').length, 1);
});
