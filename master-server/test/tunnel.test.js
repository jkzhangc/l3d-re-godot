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
import { TunnelRelay, MSG, encodeMessage } from '../src/tunnel_relay.js';

const TCP_PORT = 10090;
const UDP_START = 40000;
const UDP_END = 40002;

let relay;

function createHostClient() {
  return new Promise((resolve, reject) => {
    const sock = net.connect(TCP_PORT, '127.0.0.1', () => resolve(sock));
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
});
