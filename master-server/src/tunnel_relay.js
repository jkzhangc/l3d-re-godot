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

// ★ 单帧长度上限（2026-10 修 P3）：帧头是**对端可控的 32 位值**，旧实现直接信任，
// 攻击者发 `msgLen=0xFFFFFFFF` 后持续灌数据 → `_recvBuf` 无限增长（实测灌 5MB 涨 5MB、
// socket 不断）→ 中继内存被线性吃光。合法帧最大 = [2字节 clientId] + UDP 数据(≤1500)
// 或 REGISTER 的小 JSON，全都 < 8KB，故 8KB 上限有充足余量。
const MAX_FRAME_SIZE = 8192;

/**
 * 隧道中继服务。
 * @param {object} [opts]
 * @param {number} [opts.tcpPort] TCP 控制端口（房主连接），默认 10001
 * @param {number} [opts.portStart] UDP 公网端口池起始
 * @param {number} [opts.portEnd] UDP 公网端口池结束
 * @param {number} [opts.maxTunnelsPerIp] 每来源 IP 的并发隧道上限（默认 8，防端口池耗尽 DoS）
 * @param {number} [opts.maxQueuedFrames] 每连接待写应用帧上限，默认 256（可为 0）
 * @param {number} [opts.maxQueuedBytes] 每连接待写应用字节上限，默认 1 MiB（含帧头，可为 0）
 * @param {number} [opts.maxPendingBytes] 每连接应用队列 + TCP writableLength 硬预算，默认 2 MiB
 * @param {() => number} [opts.now] 注入时间函数（便于测试）
 */
export class TunnelRelay {
  constructor(opts = {}) {
    this.tcpPort = opts.tcpPort || DEFAULT_TCP_PORT;
    this.portStart = opts.portStart || DEFAULT_PORT_START;
    this.portEnd = opts.portEnd || DEFAULT_PORT_END;
    // ★ 每 IP 并发隧道上限（2026-10 补 P4）：中继 REGISTER 无凭据（共享密钥对可逆向的
    //   客户端是安全剧场，未采用），故用「每来源 IP 并发上限」做纵深防御 —— 单 IP 无法
    //   独自刷满仅 27 个的公网端口池。默认 8 远高于正常玩家用量（每人 1 个），不会误伤
    //   NAT 后同 IP 的少数玩家；真要 DoS 需多个 IP，成本抬高。
    this.maxTunnelsPerIp = opts.maxTunnelsPerIp || 8;
    this.maxQueuedFrames = opts.maxQueuedFrames ?? 256;
    this.maxQueuedBytes = opts.maxQueuedBytes ?? 1024 * 1024;
    this.maxPendingBytes = opts.maxPendingBytes ?? 2 * 1024 * 1024;
    for (const key of ['maxQueuedFrames', 'maxQueuedBytes', 'maxPendingBytes']) {
      if (!Number.isSafeInteger(this[key]) || this[key] < 0) {
        throw new RangeError(`${key} 必须为非负安全整数`);
      }
    }
    this._sendSockets = new Set();
    this._sendStats = {
      tcpAcceptedFrames: 0,
      tcpAcceptedBytes: 0,
      backpressureEvents: 0,
      drainEvents: 0,
      sendOverflowDisconnects: 0,
      writeErrors: 0,
      peakQueuedFrames: 0,
      peakQueuedBytes: 0,
      peakPendingBytes: 0,
    };
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
      for (const socket of this._sendSockets) this._closeConnection(socket, 'server_shutdown');
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
    let queuedFrames = 0;
    let queuedBytes = 0;
    let writableBytes = 0;
    let backpressuredConnections = 0;
    for (const socket of this._sendSockets) {
      const state = socket._sendState;
      queuedFrames += state.queue.length;
      queuedBytes += state.queuedBytes;
      writableBytes += socket.writableLength || 0;
      if (state.blocked) backpressuredConnections++;
    }
    return {
      activeTunnels: this.tunnels.size,
      availablePorts: this.availablePorts.size,
      totalPorts: this.portEnd - this.portStart + 1,
      totalClients,
      queuedFrames,
      queuedBytes,
      writableBytes,
      pendingBytes: queuedBytes + writableBytes,
      backpressuredConnections,
      ...this._sendStats,
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
    this._initSendState(socket);
    // 记录来源 IP，供「每 IP 并发隧道上限」使用（见 maxTunnelsPerIp）。
    socket._remoteIp = (socket.remoteAddress || 'unknown').replace(/^::ffff:/, '');

    socket.on('data', (data) => {
      if (socket._sendState.closed) return;
      socket._recvBuf = Buffer.concat([socket._recvBuf, data]);
      while (!socket._sendState.closed && socket._recvBuf.length >= 4) {
        const msgLen = socket._recvBuf.readUInt32BE(0);
        // ★ 帧长越界 → 视为协议违规（伪造帧头），立即断开并释放端口，避免缓冲被灌爆。
        if (msgLen < 1 || msgLen > MAX_FRAME_SIZE) {
          console.warn(`[tunnel-relay] 帧长越界（${msgLen}B），断开该连接`);
          this._closeConnection(socket, 'invalid_frame');
          return;
        }
        if (socket._recvBuf.length < 4 + msgLen) break;
        const msgBuf = socket._recvBuf.subarray(4, 4 + msgLen);
        socket._recvBuf = socket._recvBuf.subarray(4 + msgLen);
        this._handleMessage(socket, msgBuf);
      }
    });

    socket.on('close', () => this._closeConnection(socket, 'host_disconnect'));

    socket.on('error', (err) => {
      console.error('[tunnel-relay] TCP error:', err.message);
      this._closeConnection(socket, 'host_error');
    });
  }

  _handleMessage(socket, msgBuf) {
    if (socket._sendState?.closed || socket._sendState?.ending || socket.destroyed || msgBuf.length < 1) return;
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
    // ★ 每 IP 并发隧道上限（P4）：先于端口分配检查，避免单 IP 刷满端口池。
    const ip = socket._remoteIp || 'unknown';
    let owned = 0;
    for (const t of this.tunnels.values()) {
      if (t.ownerIp === ip) owned++;
    }
    if (owned >= this.maxTunnelsPerIp) {
      this._sendMsg(socket, MSG_ERROR, JSON.stringify({ message: 'too_many_tunnels' }));
      console.warn(`[tunnel-relay] ${ip} 并发隧道已达上限 ${this.maxTunnelsPerIp}，拒绝注册`);
      this._endAfterFlush(socket);
      return;
    }
    if (this.availablePorts.size === 0) {
      this._sendMsg(socket, MSG_ERROR, JSON.stringify({ message: 'no_available_ports' }));
      this._endAfterFlush(socket);
      return;
    }

    let info;
    try { info = JSON.parse(payload.toString('utf8')); } catch (_) { info = null; }
    // 先校验再占端口：JSON null/数组/标量不能进入字段读取，避免回调异常与端口泄漏。
    if (info === null || typeof info !== 'object' || Array.isArray(info)) {
      this._sendMsg(socket, MSG_ERROR, JSON.stringify({ message: 'invalid_register' }));
      this._endAfterFlush(socket);
      return;
    }

    const port = this.availablePorts.values().next().value;
    this.availablePorts.delete(port);

    const tunnel = {
      id: Math.random().toString(36).substring(2, 10),
      port,
      ownerIp: ip,
      udpSocket: null,
      hostSocket: socket,
      clients: new Map(),         // clientId -> {address, port, lastSeen}
      addrToClientId: new Map(),   // "addr:port" -> clientId
      nextClientId: 1,
      freeClientIds: [],           // 回收的 clientId（仅当新 id 用尽时才复用，见 _allocClientId）
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

    if (this._sendMsg(socket, MSG_REGISTERED, JSON.stringify({
      tunnelId: tunnel.id,
      tunnelPort: port,
    })) === false) return;
    console.log(`[tunnel-relay] Tunnel ${tunnel.id} registered → port ${port}`);
  }

  _handleUdpMessage(tunnel, msg, rinfo) {
    if (tunnel.destroyed || tunnel.hostSocket.destroyed || tunnel.hostSocket._sendState?.closed) return;
    const addrKey = `${rinfo.address}:${rinfo.port}`;
    let clientId = tunnel.addrToClientId.get(addrKey);
    if (clientId === undefined) {
      clientId = this._allocClientId(tunnel);
      if (clientId === null) {
        // ★ 16 位 clientId 用尽：丢弃该包而不是让上游抛 ERR_OUT_OF_RANGE
        // （旧实现 `nextClientId++` 无上限 → `buf.writeUInt16BE(>65535)` 抛异常，
        //  该异常位于 dgram 'message' 回调内 → uncaughtException → 中继进程退出）。
        console.warn(`[tunnel-relay] Tunnel ${tunnel.id}: clientId 池耗尽，丢弃来自 ${addrKey} 的包`);
        return;
      }
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

  /**
   * 分配一个 16 位 clientId。
   * 优先用全新自增值（正常路径不重用，避免与刚超时客户端的旧映射混淆）；
   * 新 id 用尽后，从回收池（_freeClientId 归还）取；池也空则返回 null（调用方丢弃并告警）。
   * @returns {number|null}
   */
  _allocClientId(tunnel) {
    if (tunnel.nextClientId <= 0xffff) {
      return tunnel.nextClientId++;
    }
    while (tunnel.freeClientIds.length > 0) {
      const id = tunnel.freeClientIds.pop();
      // 防御：回收池里的 id 必须确实空闲、且仍在 16 位范围
      if (id >= 1 && id <= 0xffff && !tunnel.clients.has(id)) {
        return id;
      }
    }
    return null;
  }

  /** 归还一个 clientId 到回收池（由超时清理调用）。 */
  _freeClientId(tunnel, clientId) {
    if (clientId >= 1 && clientId <= 0xffff && !tunnel.freeClientIds.includes(clientId)) {
      tunnel.freeClientIds.push(clientId);
    }
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

  _initSendState(socket) {
    if (socket._sendState) return socket._sendState;
    const state = { queue: [], queuedBytes: 0, blocked: false, closed: false };
    state.onDrain = () => {
      if (state.closed || !state.blocked) return;
      this._sendStats.drainEvents++;
      state.blocked = false;
      while (!state.closed && !state.blocked && state.queue.length > 0) {
        const frame = state.queue.shift();
        state.queuedBytes -= frame.length;
        if (!this._writeFrame(socket, frame)) return;
      }
      if (state.ending && !state.closed && state.queue.length === 0) socket.end();
    };
    socket._sendState = state;
    this._sendSockets.add(socket);
    socket.on?.('drain', state.onDrain);
    return state;
  }

  _endAfterFlush(socket) {
    const state = socket._sendState;
    if (state.closed) return;
    state.ending = true;
    if (state.queue.length === 0) socket.end();
  }

  _observePending(socket) {
    const state = socket._sendState;
    const pendingBytes = state.queuedBytes + (socket.writableLength || 0);
    // 峰值为单连接历史最大值；getStats 中当前值为所有连接之和。
    this._sendStats.peakQueuedFrames = Math.max(this._sendStats.peakQueuedFrames, state.queue.length);
    this._sendStats.peakQueuedBytes = Math.max(this._sendStats.peakQueuedBytes, state.queuedBytes);
    this._sendStats.peakPendingBytes = Math.max(this._sendStats.peakPendingBytes, pendingBytes);
    return pendingBytes;
  }

  _sendOverflow(socket) {
    this._sendStats.sendOverflowDisconnects++;
    console.warn('[tunnel-relay] 发送积压超过硬预算，断开并释放隧道');
    this._closeConnection(socket, 'send_overflow');
    return false;
  }

  _writeFrame(socket, frame) {
    let writable;
    try {
      writable = socket.write(frame);
    } catch (err) {
      this._sendStats.writeErrors++;
      console.error('[tunnel-relay] TCP write error:', err.message);
      this._closeConnection(socket, 'write_error');
      return false;
    }
    // false 表示整帧已被 Node 接纳，不是部分帧失败；只能排队后续帧，绝不重发此帧。
    this._sendStats.tcpAcceptedFrames++;
    this._sendStats.tcpAcceptedBytes += frame.length;
    if (writable === false) {
      socket._sendState.blocked = true;
      this._sendStats.backpressureEvents++;
    }
    if (this._observePending(socket) > this.maxPendingBytes) return this._sendOverflow(socket);
    return true;
  }

  _sendMsg(socket, type, data) {
    const state = this._initSendState(socket);
    if (state.closed || socket.destroyed || socket.writableEnded) {
      this._closeConnection(socket, 'socket_unwritable');
      return false;
    }
    const dataBytes = typeof data === 'string' ? Buffer.byteLength(data, 'utf8')
      : Buffer.isBuffer(data) ? data.length : 0;
    const frameBytes = 5 + dataBytes;
    if (state.queuedBytes + (socket.writableLength || 0) + frameBytes > this.maxPendingBytes) {
      return this._sendOverflow(socket);
    }
    if (state.blocked) {
      if (state.queue.length + 1 > this.maxQueuedFrames || state.queuedBytes + frameBytes > this.maxQueuedBytes) {
        return this._sendOverflow(socket);
      }
      state.queue.push(encodeMessage(type, data));
      state.queuedBytes += frameBytes;
      this._observePending(socket);
      return true;
    }
    return this._writeFrame(socket, encodeMessage(type, data));
  }

  // ───────────────────────── 生命周期 ─────────────────────────

  _closeConnection(socket, reason) {
    const state = socket._sendState;
    if (state) {
      state.closed = true;
      state.queue.length = 0;
      state.queuedBytes = 0;
      state.blocked = false;
      socket.removeListener?.('drain', state.onDrain);
    }
    this._sendSockets.delete(socket);
    socket._recvBuf = Buffer.alloc(0);
    if (socket._tunnel) this._destroyTunnel(socket._tunnel, reason);
    if (!socket.destroyed) socket.destroy();
  }

  _destroyTunnel(tunnel, reason) {
    if (tunnel.destroyed) return;
    tunnel.destroyed = true;
    if (tunnel.hostSocket._tunnel === tunnel) tunnel.hostSocket._tunnel = null;
    // 释放即结束此 TCP 会话，避免残留帧流入同连接上重新注册的隧道。
    this._closeConnection(tunnel.hostSocket, reason);
    tunnel.clients.clear();
    tunnel.addrToClientId.clear();
    tunnel.freeClientIds.length = 0;
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
          this._freeClientId(tunnel, cid);   // ★ 归还 id，供池耗尽时复用
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
