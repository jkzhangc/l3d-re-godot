// 隧道中继服务（路线二）：在云端把「外网客户端 UDP」与「房主 TCP」双向桥接。
//
// 为什么自写而不用 frps：frpc.exe 无签名、常被杀软误报，且 Android 无法运行 frpc。
// 本模块是纯 Node.js（dgram + net），无二进制依赖，服务端与 master-server 同进程。
//
// 数据流：
//   外网客户端 ──UDP──▶ [中继 UDP 公网端口] ──TCP──▶ 房主隧道客户端 ──UDP──▶ 本机游戏(127.0.0.1:27015)
//   本机游戏  ──UDP──▶ 房主隧道客户端 ──TCP──▶ [中继] ──UDP──▶ 外网客户端
//
// 关键设计（对齐 udp_relay.py 的 per-client socket 模型）：
//   每个外网客户端按来源地址区分，服务端分配 2 字节 clientId；
//   房主侧隧道客户端为每个 clientId 创建独立的本地 UDP socket（绑定不同源端口），
//   这样本机 ENet Host 能按源地址区分不同 peer（已由 net_tunnel_probe 实测验证）。
//
// 协议（二进制，4 字节大端长度前缀 + 1 字节类型 + 载荷）：
//   0x01 REGISTER       host→server  载荷=JSON{protocol,gameVersion}
//   0x02 REGISTERED     server→host  载荷=JSON{tunnelId,tunnelPort}
//   0x03 RELAY_TO_HOST  server→host  载荷=[2字节clientId(BE)][原始UDP包]
//   0x04 RELAY_FROM_HOST host→server 载荷=[2字节clientId(BE)][原始UDP包]
//   0x05 KEEPALIVE      双向          无载荷
//   0x06 RELEASE        host→server  无载荷
//   0x07 ERROR          server→host  载荷=JSON{message}
//
// 相关文档：`互联网联机模式策划方案.md` §2（房主可达性）

import dgram from 'node:dgram';
import net from 'node:net';

const MSG_REGISTER = 0x01;
const MSG_REGISTERED = 0x02;
const MSG_RELAY_TO_HOST = 0x03;
const MSG_RELAY_FROM_HOST = 0x04;
const MSG_KEEPALIVE = 0x05;
const MSG_RELEASE = 0x06;
const MSG_ERROR = 0x07;

const DEFAULT_TCP_PORT = 10001;
const DEFAULT_PORT_START = 27015;
const DEFAULT_PORT_END = 27030;
const CLIENT_TIMEOUT_MS = 60000;
const HOST_TIMEOUT_MS = 120000;
const SWEEP_INTERVAL_MS = 10000;

/**
 * 隧道中继服务。
 * @param {object} [opts]
 * @param {number} [opts.tcpPort] TCP 控制端口（房主连接），默认 10001
 * @param {number} [opts.portStart] UDP 公网端口池起始
 * @param {number} [opts.portEnd] UDP 公网端口池结束
 * @param {() => number} [opts.now] 注入时间函数（便于测试）
 */
export class TunnelRelay {
  constructor(opts = {}) {
    this.tcpPort = opts.tcpPort || DEFAULT_TCP_PORT;
    this.portStart = opts.portStart || DEFAULT_PORT_START;
    this.portEnd = opts.portEnd || DEFAULT_PORT_END;
    this._now = opts.now || (() => Date.now());

    this.availablePorts = new Set();
    for (let p = this.portStart; p <= this.portEnd; p++) {
      this.availablePorts.add(p);
    }

    // tunnelId -> Tunnel
    this.tunnels = new Map();
    this.tcpServer = null;
    this.sweepTimer = null;
  }

  /**
   * 启动 TCP 服务器。
   * @returns {Promise<TunnelRelay>} 监听就绪后 resolve
   */
  start() {
    return new Promise((resolve, reject) => {
      this.tcpServer = net.createServer((socket) => this._handleConnection(socket));
      this.tcpServer.once('error', reject);
      this.tcpServer.listen(this.tcpPort, '0.0.0.0', () => {
        console.log(`[tunnel-relay] TCP :${this.tcpPort}, UDP pool ${this.portStart}-${this.portEnd} (${this.availablePorts.size} free)`);
        this.tcpServer.removeListener('error', reject);
        resolve(this);
      });
      this.sweepTimer = setInterval(() => this._sweep(), SWEEP_INTERVAL_MS);
    });
  }

  /**
   * 停止所有服务并释放端口。
   * @returns {Promise<void>} 所有套接字关闭后 resolve
   */
  stop() {
    return new Promise((resolve) => {
      if (this.sweepTimer) { clearInterval(this.sweepTimer); this.sweepTimer = null; }
      for (const tunnel of this.tunnels.values()) {
        this._destroyTunnel(tunnel, 'server_shutdown');
      }
      this.tunnels.clear();
      if (this.tcpServer) {
        this.tcpServer.close(() => resolve());
        this.tcpServer = null;
      } else {
        resolve();
      }
    });
  }

  getStats() {
    let totalClients = 0;
    for (const t of this.tunnels.values()) totalClients += t.clients.size;
    return {
      activeTunnels: this.tunnels.size,
      availablePorts: this.availablePorts.size,
      totalPorts: this.portEnd - this.portStart + 1,
      totalClients,
    };
  }

  // ───────────────────────── TCP 连接处理 ─────────────────────────

  _handleConnection(socket) {
    // ★ 关闭 Nagle（2026-10-10）：隧道把游戏 60Hz 的小包走 TCP 转发，Nagle 会把小包
    // 攒着等 ACK（≈1 RTT）再成批发 → 交付时刻抖动、成串到达，客户端表现为"延迟忽高忽低
    // + 移动果冻感/回弹"。每包立即发出后抖动显著收敛。UDP 侧本就无此问题。
    socket.setNoDelay(true);
    socket._recvBuf = Buffer.alloc(0);
    socket._tunnel = null;

    socket.on('data', (data) => {
      socket._recvBuf = Buffer.concat([socket._recvBuf, data]);
      while (socket._recvBuf.length >= 4) {
        const msgLen = socket._recvBuf.readUInt32BE(0);
        if (socket._recvBuf.length < 4 + msgLen) break;
        const msgBuf = socket._recvBuf.subarray(4, 4 + msgLen);
        socket._recvBuf = socket._recvBuf.subarray(4 + msgLen);
        this._handleMessage(socket, msgBuf);
      }
    });

    socket.on('close', () => {
      if (socket._tunnel) {
        this._destroyTunnel(socket._tunnel, 'host_disconnect');
        socket._tunnel = null;
      }
    });

    socket.on('error', (err) => {
      console.error('[tunnel-relay] TCP error:', err.message);
    });
  }

  _handleMessage(socket, msgBuf) {
    if (msgBuf.length < 1) return;
    const type = msgBuf[0];
    const payload = msgBuf.subarray(1);

    switch (type) {
      case MSG_REGISTER:
        this._handleRegister(socket, payload);
        break;
      case MSG_RELAY_FROM_HOST:
        this._handleRelayFromHost(socket, payload);
        break;
      case MSG_KEEPALIVE:
        if (socket._tunnel) socket._tunnel.lastKeepalive = this._now();
        break;
      case MSG_RELEASE:
        if (socket._tunnel) {
          this._destroyTunnel(socket._tunnel, 'host_release');
          socket._tunnel = null;
        }
        break;
      default:
        console.warn('[tunnel-relay] Unknown message type:', type);
    }
  }

  _handleRegister(socket, payload) {
    if (socket._tunnel) {
      this._sendMsg(socket, MSG_ERROR, JSON.stringify({ message: 'already_registered' }));
      return;
    }
    if (this.availablePorts.size === 0) {
      this._sendMsg(socket, MSG_ERROR, JSON.stringify({ message: 'no_available_ports' }));
      socket.end();
      return;
    }

    let info = {};
    try { info = JSON.parse(payload.toString('utf8')); } catch (_) { /* ignore */ }

    const port = this.availablePorts.values().next().value;
    this.availablePorts.delete(port);

    const tunnel = {
      id: Math.random().toString(36).substring(2, 10),
      port,
      udpSocket: null,
      hostSocket: socket,
      clients: new Map(),         // clientId -> {address, port, lastSeen}
      addrToClientId: new Map(),   // "addr:port" -> clientId
      nextClientId: 1,
      lastKeepalive: this._now(),
      gameVersion: info.gameVersion || '',
      protocol: info.protocol || '',
    };
    socket._tunnel = tunnel;
    this.tunnels.set(tunnel.id, tunnel);

    // 在公网端口上创建 UDP 监听
    const udp = dgram.createSocket('udp4');
    udp.on('message', (msg, rinfo) => this._handleUdpMessage(tunnel, msg, rinfo));
    udp.on('error', (err) => console.error(`[tunnel-relay] UDP :${port} error:`, err.message));
    udp.bind(port, '0.0.0.0', () => {
      console.log(`[tunnel-relay] UDP :${port} (tunnel ${tunnel.id}) ready`);
    });
    tunnel.udpSocket = udp;

    this._sendMsg(socket, MSG_REGISTERED, JSON.stringify({
      tunnelId: tunnel.id,
      tunnelPort: port,
    }));
    console.log(`[tunnel-relay] Tunnel ${tunnel.id} registered → port ${port}`);
  }

  _handleUdpMessage(tunnel, msg, rinfo) {
    const addrKey = `${rinfo.address}:${rinfo.port}`;
    let clientId = tunnel.addrToClientId.get(addrKey);
    if (clientId === undefined) {
      clientId = tunnel.nextClientId++;
      tunnel.clients.set(clientId, { address: rinfo.address, port: rinfo.port, lastSeen: this._now() });
      tunnel.addrToClientId.set(addrKey, clientId);
      console.log(`[tunnel-relay] Tunnel ${tunnel.id}: client ${clientId} ← ${addrKey}`);
    } else {
      const c = tunnel.clients.get(clientId);
      if (c) c.lastSeen = this._now();
    }

    // 转发给房主：[2字节 clientId (BE)][原始 UDP 数据]
    const buf = Buffer.allocUnsafe(2 + msg.length);
    buf.writeUInt16BE(clientId, 0);
    msg.copy(buf, 2);
    this._sendMsg(tunnel.hostSocket, MSG_RELAY_TO_HOST, buf);
  }

  _handleRelayFromHost(socket, payload) {
    const tunnel = socket._tunnel;
    if (!tunnel || !tunnel.udpSocket || payload.length < 2) return;
    const clientId = payload.readUInt16BE(0);
    const udpData = payload.subarray(2);
    const client = tunnel.clients.get(clientId);
    if (!client) return;
    tunnel.udpSocket.send(udpData, client.port, client.address, (err) => {
      if (err) console.error(`[tunnel-relay] send to client ${clientId} failed:`, err.message);
    });
  }

  // ───────────────────────── 协议工具 ─────────────────────────

  _sendMsg(socket, type, data) {
    let payload;
    if (typeof data === 'string') {
      payload = Buffer.concat([Buffer.from([type]), Buffer.from(data, 'utf8')]);
    } else if (Buffer.isBuffer(data)) {
      payload = Buffer.concat([Buffer.from([type]), data]);
    } else {
      payload = Buffer.from([type]);
    }
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32BE(payload.length, 0);
    socket.write(Buffer.concat([header, payload]));
  }

  // ───────────────────────── 生命周期 ─────────────────────────

  _destroyTunnel(tunnel, reason) {
    if (tunnel.udpSocket) {
      try { tunnel.udpSocket.close(); } catch (_) { /* already closed */ }
      tunnel.udpSocket = null;
    }
    this.availablePorts.add(tunnel.port);
    this.tunnels.delete(tunnel.id);
    console.log(`[tunnel-relay] Tunnel ${tunnel.id} destroyed (${reason}), port ${tunnel.port} freed`);
  }

  _sweep() {
    const now = this._now();
    for (const [id, tunnel] of this.tunnels) {
      if (now - tunnel.lastKeepalive > HOST_TIMEOUT_MS) {
        console.log(`[tunnel-relay] Tunnel ${id} host timeout`);
        if (tunnel.hostSocket && !tunnel.hostSocket.destroyed) tunnel.hostSocket.destroy();
        this._destroyTunnel(tunnel, 'host_timeout');
        continue;
      }
      for (const [cid, client] of tunnel.clients) {
        if (now - client.lastSeen > CLIENT_TIMEOUT_MS) {
          tunnel.addrToClientId.delete(`${client.address}:${client.port}`);
          tunnel.clients.delete(cid);
          console.log(`[tunnel-relay] Tunnel ${id}: client ${cid} timeout`);
        }
      }
    }
  }
}

// 导出消息类型常量（供测试用）
export const MSG = {
  REGISTER: MSG_REGISTER,
  REGISTERED: MSG_REGISTERED,
  RELAY_TO_HOST: MSG_RELAY_TO_HOST,
  RELAY_FROM_HOST: MSG_RELAY_FROM_HOST,
  KEEPALIVE: MSG_KEEPALIVE,
  RELEASE: MSG_RELEASE,
  ERROR: MSG_ERROR,
};

// 编码工具（供测试用）
export function encodeMessage(type, data) {
  let payload;
  if (typeof data === 'string') {
    payload = Buffer.concat([Buffer.from([type]), Buffer.from(data, 'utf8')]);
  } else if (Buffer.isBuffer(data)) {
    payload = Buffer.concat([Buffer.from([type]), data]);
  } else {
    payload = Buffer.from([type]);
  }
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, payload]);
}
