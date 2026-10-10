#!/usr/bin/env node
// 隧道中继公网端到端验收：模拟「房主(TCP) + 外网客户端(UDP)」，验证完整往返。
//
// 用法：
//   node tunnel_e2e_check.mjs <host> <tcpPort>
//   node tunnel_e2e_check.mjs 8.138.99.96 10001
//
// 退出码：0 = 通过；1 = 失败（附原因）。
//
// 验证内容：
//   1. 房主 TCP 连中继控制口，发 REGISTER → 收到 REGISTERED（含分配的公网 UDP 端口）
//   2. 外网客户端向该 UDP 端口发 PING → 房主侧收到 RELAY_TO_HOST
//   3. 房主回 RELAY_FROM_HOST(PONG) → 外网客户端收到 PONG
// 任一步失败都会打印 ❌ 并退 1，可直接用于 CI / 部署后验收。

import net from 'node:net';
import dgram from 'node:dgram';

const HOST = process.argv[2] || '8.138.99.96';
const TCP_PORT = Number(process.argv[3] || 10001);
const TIMEOUT_MS = 8000;

const MSG = {
  REGISTER: 0x01, REGISTERED: 0x02, RELAY_TO_HOST: 0x03,
  RELAY_FROM_HOST: 0x04, KEEPALIVE: 0x05, RELEASE: 0x06, ERROR: 0x07,
};

/** 编码协议帧：[4字节大端长度][1字节类型][载荷] */
function encode(type, data) {
  let payload;
  if (typeof data === 'string') payload = Buffer.concat([Buffer.from([type]), Buffer.from(data, 'utf8')]);
  else if (Buffer.isBuffer(data)) payload = Buffer.concat([Buffer.from([type]), data]);
  else payload = Buffer.from([type]);
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, payload]);
}

let tunnelPort = 0;
let buf = Buffer.alloc(0);
let settled = false;

const timer = setTimeout(() => finish(false, `超时：${TIMEOUT_MS}ms 内未完成往返`), TIMEOUT_MS);

function finish(passed, message) {
  if (settled) return;
  settled = true;
  clearTimeout(timer);
  console.log(`[验收] ${passed ? '✅' : '❌'} ${message}`);
  process.exit(passed ? 0 : 1);
}

const host = net.connect(TCP_PORT, HOST);
host.on('error', (e) => finish(false, `房主 TCP 连接错误: ${e.message}`));
host.on('connect', () => {
  console.log(`[验收] 房主 TCP 已连中继 ${HOST}:${TCP_PORT}，发 REGISTER`);
  host.write(encode(MSG.REGISTER, JSON.stringify({
    protocol: 'l3d_main_v2_combat_rpc',
    gameVersion: 'e2e-check',
  })));
});

host.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  while (buf.length >= 4) {
    const len = buf.readUInt32BE(0);
    if (buf.length < 4 + len) break;
    const msg = buf.subarray(4, 4 + len);
    buf = buf.subarray(4 + len);
    const type = msg[0];
    const payload = msg.subarray(1);

    if (type === MSG.REGISTERED) {
      const info = JSON.parse(payload.toString('utf8'));
      tunnelPort = info.tunnelPort;
      console.log(`[验收] REGISTERED：tunnelId=${info.tunnelId} 公网端口=${tunnelPort}`);
      console.log(`[验收] 外网客户端向 ${HOST}:${tunnelPort} 发 PING（UDP）`);
      client.send(Buffer.from('PING'), tunnelPort, HOST);
    } else if (type === MSG.RELAY_TO_HOST) {
      const clientId = payload.readUInt16BE(0);
      const text = payload.subarray(2).toString('utf8');
      console.log(`[验收] 房主收到 RELAY_TO_HOST：clientId=${clientId} data=${text}`);
      const reply = Buffer.concat([
        Buffer.from([(clientId >> 8) & 0xff, clientId & 0xff]),
        Buffer.from('PONG'),
      ]);
      host.write(encode(MSG.RELAY_FROM_HOST, reply));
    } else if (type === MSG.ERROR) {
      finish(false, `中继返回 ERROR: ${payload.toString('utf8')}`);
    }
  }
});

const client = dgram.createSocket('udp4');
client.on('error', (e) => finish(false, `UDP socket 错误: ${e.message}`));
client.on('message', (msg) => {
  const text = msg.toString('utf8');
  console.log(`[验收] 外网客户端收到 UDP 回包：${text}`);
  if (text === 'PONG') {
    finish(true, `公网链路完整：TCP 注册 + UDP ${HOST}:${tunnelPort} 往返成功`);
  }
});
