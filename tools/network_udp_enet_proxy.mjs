import dgram from 'node:dgram';
import { randomBytes } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { UdpTunnelCodec, HEADER_BYTES, TAG_BYTES, MAX_PAYLOAD, MAX_DATAGRAM } from '../master-server/src/udp_tunnel_codec.js';

const ADDRESS = '127.0.0.1';
const MAX_QUEUE_AGE_MS = 2000;
const COUNTERS = [
  'rawPackets', 'rawBytes', 'rawOversizePackets', 'rawEmptyPackets',
  'sealedPackets', 'sealedBytes', 'sealRejectedPackets', 'duplicatePackets',
  'lossDroppedPackets', 'blackoutDroppedPackets', 'queueEnqueuedPackets',
  'queueOverflowPackets', 'queueExpiredPackets', 'closeDroppedPackets',
  'transportSentPackets', 'transportSentBytes', 'transportReceivedPackets',
  'transportReceivedBytes', 'wrongSourcePackets', 'authAcceptedPackets',
  'authRejectedPackets', 'forwardedPackets', 'forwardedBytes',
  'frontendRejectedSources', 'ioErrors', 'socketErrors', 'sendErrors',
  'startupErrors', 'closeErrors', 'streamErrors',
  'maxRawPacketBytes', 'maxSealedPacketBytes', 'maxTransportPacketBytes',
  'transportUndersizePackets', 'transportOversizePackets', 'externalUnattachedPackets',
];
const counters = () => Object.fromEntries(COUNTERS.map(name => [name, 0]));

function randomGenerator(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = Math.imul(state ^ (state >>> 15), 1 | state);
    value ^= value + Math.imul(value ^ (value >>> 7), 61 | value);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

// 所有故障都作用于 seal 后的数据报；此适配器不负责生产凭据协商。
export class UdpEnetLab {
  constructor({ hostPort, clients = 2, seed = 31, loss = 0, delayMs = 0,
    jitterMs = 0, duplicate = 0, queueMaxPackets = 8192,
    queueMaxBytes = 8 * 1024 * 1024, blackoutMs = 0, blackoutAfterMs = 0,
    externalHost = false } = {}) {
    if (!Number.isInteger(hostPort) || hostPort < 1 || hostPort > 65535
      || typeof externalHost !== 'boolean'
      || !Number.isInteger(clients) || clients < 1 || clients > 3
      || !Number.isInteger(seed) || seed < 0 || seed > 0xffffffff
      || ![loss, duplicate].every(value => Number.isFinite(value) && value >= 0 && value <= 1)
      || ![delayMs, jitterMs, blackoutMs, blackoutAfterMs].every(value => Number.isFinite(value) && value >= 0 && value <= 0x7fffffff)
      || ![queueMaxPackets, queueMaxBytes].every(value => Number.isSafeInteger(value) && value >= 1)) {
      throw new TypeError('无效的 UDP 实验配置');
    }
    this.options = { hostPort, clients, seed, loss, delayMs, jitterMs, duplicate,
      queueMaxPackets, queueMaxBytes, blackoutMs, blackoutAfterMs };
    this.externalHost = externalHost;
    if (externalHost) this.options.externalHost = true;
    this._externalAttached = false;
    this._state = 'new';
    this._closing = false;
    this._sessions = [];
    this._sockets = new Set();
    this._bound = new Set();
    this._closedSockets = new WeakSet();
    this._totals = counters();
    this._heap = [];
    this._queueBytes = 0;
    this._peakPackets = 0;
    this._peakBytes = 0;
    this._timer = null;
    this._timerDue = Infinity;
    this._startedAt = null;
    this._closedAt = null;
    this._manualBlackoutUntil = 0;
    this._manualBlackouts = 0;
    this._cpuStart = null;
    this._startPromise = null;
    this._closePromise = null;
  }

  _count(session, direction, name, amount = 1) {
    this._totals[name] += amount;
    if (session) {
      session.stats.totals[name] += amount;
      if (direction) session.stats[direction][name] += amount;
    }
  }

  _maximum(session, direction, name, value) {
    this._totals[name] = Math.max(this._totals[name], value);
    session.stats.totals[name] = Math.max(session.stats.totals[name], value);
    session.stats[direction][name] = Math.max(session.stats[direction][name], value);
  }

  _ioError(session, direction, name) {
    this._count(session, direction, 'ioErrors');
    this._count(session, direction, name);
  }

  _socket(session) {
    const socket = dgram.createSocket('udp4');
    this._sockets.add(socket);
    socket.on('error', () => this._ioError(session, null, 'socketErrors'));
    socket.on('listening', () => this._bound.add(socket));
    socket.on('close', () => {
      this._bound.delete(socket);
      this._closedSockets.add(socket);
    });
    return socket;
  }

  _bind(socket, session) {
    return new Promise((resolveBind, reject) => {
      const onError = error => { socket.off('listening', onListening); reject(error); };
      const onListening = () => { socket.off('error', onError); resolveBind(); };
      socket.once('error', onError);
      socket.once('listening', onListening);
      try { socket.bind(0, ADDRESS); } catch (error) {
        socket.off('error', onError);
        socket.off('listening', onListening);
        this._ioError(session, null, 'startupErrors');
        reject(error);
      }
    });
  }

  _connect(socket, session) {
    return new Promise((resolveConnect, reject) => {
      const onError = error => { socket.off('connect', onConnect); reject(error); };
      const onConnect = () => { socket.off('error', onError); resolveConnect(); };
      socket.once('error', onError);
      socket.once('connect', onConnect);
      try { socket.connect(this.options.hostPort, ADDRESS); } catch (error) {
        socket.off('error', onError);
        socket.off('connect', onConnect);
        this._ioError(session, null, 'startupErrors');
        reject(error);
      }
    });
  }

  async start() {
    if (this._closing || this._state === 'closed') throw new Error('UDP 实验已关闭');
    if (!this._startPromise) {
      this._state = 'starting';
      this._startPromise = this._start().catch(async error => {
        this._closing = true;
        await this._dispose();
        this._state = 'closed';
        this._closedAt = performance.now();
        throw error;
      });
    }
    return this._startPromise;
  }

  async _start() {
    for (let index = 0; index < this.options.clients; index++) {
      if (this._closing) throw new Error('UDP 实验启动已取消');
      const session = {
        peer: null,
        stats: { client: index, frontendPort: null, backendPort: null,
          totals: counters(), c2h: counters(), h2c: counters() },
        random: {
          c2h: randomGenerator((this.options.seed ^ Math.imul(index + 1, 0x9e3779b9)) >>> 0),
          h2c: randomGenerator((this.options.seed ^ Math.imul(index + 1, 0x85ebca6b) ^ 0xa5a5a5a5) >>> 0),
        },
      };
      this._sessions.push(session);
      const roles = this.externalHost ? ['frontend', 'leftTransport', 'rightTransport']
        : ['frontend', 'backend', 'leftTransport', 'rightTransport'];
      for (const role of roles) {
        if (this._closing) throw new Error('UDP 实验启动已取消');
        session[role] = this._socket(session);
        await this._bind(session[role], session);
      }
      if (this._closing) throw new Error('UDP 实验启动已取消');
      if (session.backend) await this._connect(session.backend, session);
      session.stats.frontendPort = session.frontend.address().port;
      session.stats.backendPort = session.backend?.address().port ?? null;
      session.leftTransportPort = session.leftTransport.address().port;
      session.rightTransportPort = session.rightTransport.address().port;
      const sessionId = randomBytes(8);
      const key = randomBytes(32);
      try {
        const expiresAt = performance.now() + 120000; // 本地实验最长110秒；凭据仍短期且close清零。
        session.leftCodec = new UdpTunnelCodec({ sessionId, key, txDirection: 0,
          source: { address: ADDRESS, port: session.rightTransport.address().port }, expiresAt });
        if (this.externalHost) {
          session.credentials = { sessionId: Buffer.from(sessionId), key: Buffer.from(key) };
        } else {
          session.rightCodec = new UdpTunnelCodec({ sessionId, key, txDirection: 1,
            source: { address: ADDRESS, port: session.leftTransport.address().port }, expiresAt });
        }
      } finally {
        key.fill(0);
        sessionId.fill(0);
      }
      session.frontend.on('message', (packet, source) => {
        if (this._closing) return;
        if (source.address !== ADDRESS || (session.peer && source.port !== session.peer.port)) {
          this._count(session, 'c2h', 'frontendRejectedSources');
          return;
        }
        if (!session.peer && packet.length > 0 && packet.length <= MAX_PAYLOAD) {
          session.peer = { address: source.address, port: source.port };
        }
        this._raw(session, 'c2h', packet);
      });
      session.backend?.on('message', packet => this._raw(session, 'h2c', packet));
      session.rightTransport.on('message', (packet, source) => {
        if (this.externalHost) this._receiveExternal(session, packet, source);
        else this._receive(session, 'c2h', packet, source);
      });
      session.leftTransport.on('message', (packet, source) => this._receive(session, 'h2c', packet, source));
    }
    if (this._closing) throw new Error('UDP 实验启动已取消');
    this._startedAt = performance.now();
    this._cpuStart = process.cpuUsage();
    this._state = 'running';
    return { address: ADDRESS, ports: this._sessions.map(session => session.stats.frontendPort),
      hostPort: this.options.hostPort, ...(this.externalHost ? { externalHost: true } : {}) };
  }

  // 私有本机程序接口；调用方不得把返回值写入常规日志或统计。
  getExternalHostConfig() {
    if (!this.externalHost || this._state !== 'running' || this._closing) {
      throw new Error('外部 host 配置仅在 externalHost 运行态可用');
    }
    return { host_port: this.options.hostPort, ttl_msec: 120000,
      sessions: this._sessions.map(session => ({
        session_id_hex: session.credentials.sessionId.toString('hex'),
        key_hex: session.credentials.key.toString('hex'),
        source_port: session.leftTransportPort, return_port: session.rightTransportPort,
      })) };
  }

  attachExternalHost({ ports } = {}) {
    if (!this.externalHost || this._state !== 'running' || this._closing || this._externalAttached) {
      throw new Error('外部 host 仅可在 externalHost 运行态首次 attach');
    }
    if (!Array.isArray(ports) || ports.length !== this._sessions.length
      || ![...ports].every(port => Number.isInteger(port) && port >= 1 && port <= 65535)
      || new Set(ports).size !== ports.length) {
      throw new TypeError('外部 host ports 必须与会话数量一致、唯一且在1..65535范围');
    }
    this._sessions.forEach((session, index) => { session.externalTransportPort = ports[index]; });
    this._externalAttached = true;
  }

  triggerBlackout(durationMs) {
    if (this._state !== 'running' || !Number.isFinite(durationMs) || durationMs < 1 || durationMs > 2000) {
      throw new TypeError('blackout必须在运行态指定1..2000ms');
    }
    this._manualBlackoutUntil = performance.now() + durationMs;
    this._manualBlackouts++;
  }

  _blackout(now = performance.now()) {
    if (now < this._manualBlackoutUntil) return true;
    if (this._startedAt === null || !this.options.blackoutMs) return false;
    const elapsed = now - this._startedAt - this.options.blackoutAfterMs;
    return elapsed >= 0 && elapsed < this.options.blackoutMs;
  }

  _raw(session, direction, payload) {
    if (this._closing) return;
    this._count(session, direction, 'rawPackets');
    this._count(session, direction, 'rawBytes', payload.length);
    this._maximum(session, direction, 'maxRawPacketBytes', payload.length);
    if (payload.length > MAX_PAYLOAD) {
      this._count(session, direction, 'rawOversizePackets');
      return;
    }
    if (!payload.length) {
      this._count(session, direction, 'rawEmptyPackets');
      return;
    }
    const codec = direction === 'c2h' ? session.leftCodec : session.rightCodec;
    const packet = codec.seal(payload);
    if (!packet) { this._count(session, direction, 'sealRejectedPackets'); return; }
    this._count(session, direction, 'sealedPackets');
    this._count(session, direction, 'sealedBytes', packet.length);
    this._maximum(session, direction, 'maxSealedPacketBytes', packet.length);
    if (this.externalHost && direction === 'c2h') {
      session.lastC2h?.fill(0);
      session.lastC2h = Buffer.from(packet); // private bounded capture, never in stats/logs
    }
    this._fault(session, direction, packet);
  }

  // Test-only capture/replay over an owned anonymous pipe, not a public endpoint.
  exportReplay() {
    if (!this.externalHost || this._closing || !this._externalAttached
      || this._sessions.some(session => !session.lastC2h)) throw new Error('replay capture incomplete');
    return { packets: this._sessions.map(session => session.lastC2h.toString('base64')) };
  }

  injectReplay({ packets } = {}) {
    if (!this.externalHost || this._closing || !this._externalAttached
      || !Array.isArray(packets) || packets.length !== this._sessions.length
      || Array.from(packets).some(value => typeof value !== 'string' || value.length > 2000
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(value))) throw new Error('invalid replay input');
    const frames = packets.map(value => Buffer.from(value, 'base64'));
    if (frames.some(frame => frame.length <= HEADER_BYTES + TAG_BYTES || frame.length > MAX_DATAGRAM)) {
      frames.forEach(frame => frame.fill(0));
      throw new Error('invalid replay length');
    }
    frames.forEach((frame, index) => {
      const session = this._sessions[index];
      // New trusted source -> new worker: do not let wrong source rejection masquerade as old-key rejection.
      this._send(session, 'c2h', session.leftTransport, frame,
        { address: ADDRESS, port: session.externalTransportPort }, 'transportSent');
    });
    return { packets: frames.length, trustedSource: true, bypassedFaultInjection: true };
  }

  _fault(session, direction, packet) {
    if (this.externalHost && !this._externalAttached) {
      this._count(session, direction, 'externalUnattachedPackets');
      return;
    }
    const random = session.random[direction];
    const copies = random() < this.options.duplicate ? 2 : 1;
    if (copies === 2) this._count(session, direction, 'duplicatePackets');
    for (let index = 0; index < copies; index++) {
      if (this._blackout()) { this._count(session, direction, 'blackoutDroppedPackets'); continue; }
      if (random() < this.options.loss) { this._count(session, direction, 'lossDroppedPackets'); continue; }
      const delay = Math.max(0, this.options.delayMs + (random() * 2 - 1) * this.options.jitterMs);
      this._enqueue(session, direction, packet, delay);
    }
  }

  _enqueue(session, direction, packet, delay) {
    if (this._heap.length >= this.options.queueMaxPackets || this._queueBytes + packet.length > this.options.queueMaxBytes) {
      this._count(session, direction, 'queueOverflowPackets');
      return;
    }
    const now = performance.now();
    const entry = { session, direction, packet, due: now + delay, expires: now + MAX_QUEUE_AGE_MS };
    entry.wake = Math.min(entry.due, entry.expires);
    this._heap.push(entry);
    let child = this._heap.length - 1;
    while (child > 0) {
      const parent = (child - 1) >>> 1;
      if (this._heap[parent].wake <= entry.wake) break;
      this._heap[child] = this._heap[parent];
      child = parent;
    }
    this._heap[child] = entry;
    this._queueBytes += packet.length;
    this._peakPackets = Math.max(this._peakPackets, this._heap.length);
    this._peakBytes = Math.max(this._peakBytes, this._queueBytes);
    this._count(session, direction, 'queueEnqueuedPackets');
    this._arm();
  }

  _pop() {
    const first = this._heap[0];
    const last = this._heap.pop();
    if (this._heap.length) {
      let parent = 0;
      while (parent * 2 + 1 < this._heap.length) {
        let child = parent * 2 + 1;
        if (child + 1 < this._heap.length && this._heap[child + 1].wake < this._heap[child].wake) child++;
        if (last.wake <= this._heap[child].wake) break;
        this._heap[parent] = this._heap[child];
        parent = child;
      }
      this._heap[parent] = last;
    }
    this._queueBytes -= first.packet.length;
    return first;
  }

  _arm() {
    if (this._closing || !this._heap.length) return;
    const due = this._heap[0].wake;
    if (this._timer && this._timerDue <= due) return;
    if (this._timer) clearTimeout(this._timer);
    this._timerDue = due;
    this._timer = setTimeout(() => {
      this._timer = null;
      this._timerDue = Infinity;
      this._flush();
    }, Math.max(0, due - performance.now()));
  }

  _flush() {
    if (this._closing) return;
    let now = performance.now();
    while (this._heap.length && this._heap[0].wake <= now) {
      const { session, direction, packet, expires } = this._pop();
      if (now >= expires) this._count(session, direction, 'queueExpiredPackets');
      else if (this._blackout(now)) this._count(session, direction, 'blackoutDroppedPackets');
      else {
        const socket = direction === 'c2h' ? session.leftTransport : session.rightTransport;
        const port = direction === 'c2h'
          ? (this.externalHost ? session.externalTransportPort : session.rightTransportPort)
          : session.leftTransportPort;
        this._send(session, direction, socket, packet, { address: ADDRESS, port }, 'transportSent');
      }
      now = performance.now();
    }
    this._arm();
  }

  _send(session, direction, socket, packet, target, counter) {
    if (this._closing) return;
    const complete = error => {
      if (error) this._ioError(session, direction, 'sendErrors');
      else {
        this._count(session, direction, `${counter}Packets`);
        this._count(session, direction, `${counter}Bytes`, packet.length);
      }
    };
    try {
      if (target) socket.send(packet, target.port, target.address, complete);
      else socket.send(packet, complete);
    } catch (error) { complete(error); }
  }

  _transportLength(session, direction, packet) {
    this._maximum(session, direction, 'maxTransportPacketBytes', packet.length);
    if (packet.length > MAX_DATAGRAM) {
      this._count(session, direction, 'transportOversizePackets');
      return false;
    }
    if (packet.length <= HEADER_BYTES + TAG_BYTES) {
      this._count(session, direction, 'transportUndersizePackets');
      return false;
    }
    return true;
  }

  _receiveExternal(session, packet, source) {
    if (this._closing) return;
    this._count(session, 'h2c', 'transportReceivedPackets');
    this._count(session, 'h2c', 'transportReceivedBytes', packet.length);
    const validLength = this._transportLength(session, 'h2c', packet);
    if (!this._externalAttached) {
      this._count(session, 'h2c', 'externalUnattachedPackets');
      return;
    }
    if (source.address !== ADDRESS || source.port !== session.externalTransportPort) {
      this._count(session, 'h2c', 'wrongSourcePackets');
      return;
    }
    if (!validLength) return;
    // 此处只检查固定来源/长度；不 open、不二次 seal，防重放仅由 leftCodec 执行。
    this._count(session, 'h2c', 'sealedPackets');
    this._count(session, 'h2c', 'sealedBytes', packet.length);
    this._maximum(session, 'h2c', 'maxSealedPacketBytes', packet.length);
    this._fault(session, 'h2c', packet);
  }

  _receive(session, direction, packet, source) {
    if (this._closing) return;
    this._count(session, direction, 'transportReceivedPackets');
    this._count(session, direction, 'transportReceivedBytes', packet.length);
    this._transportLength(session, direction, packet);
    if (this._blackout()) { this._count(session, direction, 'blackoutDroppedPackets'); return; }
    const codec = direction === 'c2h' ? session.rightCodec : session.leftCodec;
    if (source.address !== codec.source.address || source.port !== codec.source.port) {
      this._count(session, direction, 'wrongSourcePackets');
    }
    const payload = codec.open(packet, source);
    if (!payload) { this._count(session, direction, 'authRejectedPackets'); return; }
    this._count(session, direction, 'authAcceptedPackets');
    if (direction === 'c2h') this._send(session, direction, session.backend, payload, null, 'forwarded');
    else if (session.peer) this._send(session, direction, session.frontend, payload, session.peer, 'forwarded');
  }

  async _dispose() {
    if (this._timer) clearTimeout(this._timer);
    this._timer = null;
    this._timerDue = Infinity;
    for (const entry of this._heap) this._count(entry.session, entry.direction, 'closeDroppedPackets');
    this._heap.length = 0;
    this._queueBytes = 0;
    for (const session of this._sessions) {
      session.leftCodec?.close();
      session.rightCodec?.close();
      session.lastC2h?.fill(0);
      session.lastC2h = null;
      session.credentials?.key.fill(0);
      session.credentials?.sessionId.fill(0);
      session.leftCodec?.id.fill(0);
      session.rightCodec?.id.fill(0);
    }
    await Promise.all([...this._sockets].map(socket => new Promise(resolveClose => {
      if (this._closedSockets.has(socket)) { resolveClose(); return; }
      try { socket.close(resolveClose); } catch (error) {
        this._ioError(null, null, 'closeErrors');
        resolveClose();
      }
    })));
    this._sockets.clear();
    this._bound.clear();
  }

  async close() {
    if (!this._closePromise) {
      this._closing = true;
      if (this._timer) clearTimeout(this._timer);
      this._timer = null;
      this._closePromise = (async () => {
        if (this._startPromise) {
          try { await this._startPromise; } catch { /* 启动失败已完成计数和回收。 */ }
        }
        await this._dispose();
        this._state = 'closed';
        this._closedAt ??= performance.now();
      })();
    }
    return this._closePromise;
  }

  getStats() {
    return {
      state: this._state, address: ADDRESS, hostPort: this.options.hostPort,
      ports: this._sessions.map(session => session.stats.frontendPort),
      configuration: { ...this.options },
      manualBlackouts: this._manualBlackouts,
      nodeProcessCpuUsec: this._cpuStart ? process.cpuUsage(this._cpuStart) : { user: 0, system: 0 },
      cpuScope: 'entire Node proxy process including authentication, queue and diagnostics; not Godot or per-thread CPU',
      limits: { maxPayloadBytes: MAX_PAYLOAD, maxDatagramBytes: MAX_DATAGRAM, queueMaxAgeMs: MAX_QUEUE_AGE_MS },
      uptimeMs: this._startedAt === null ? 0 : (this._closedAt ?? performance.now()) - this._startedAt,
      queue: { packets: this._heap.length, bytes: this._queueBytes, peakPackets: this._peakPackets, peakBytes: this._peakBytes },
      totals: { ...this._totals },
      sessions: this._sessions.map(session => ({
        ...session.stats, totals: { ...session.stats.totals },
        c2h: { ...session.stats.c2h }, h2c: { ...session.stats.h2c },
      })),
    };
  }
}

async function main() {
  const names = { 'host-port': 'hostPort', clients: 'clients', seed: 'seed', loss: 'loss',
    'delay-ms': 'delayMs', 'jitter-ms': 'jitterMs', duplicate: 'duplicate',
    'queue-max-packets': 'queueMaxPackets', 'queue-max-bytes': 'queueMaxBytes',
    'blackout-after-ms': 'blackoutAfterMs', 'blackout-ms': 'blackoutMs',
    'external-host': 'externalHost' };
  const options = {};
  for (const argument of process.argv.slice(2)) {
    const match = /^--([a-z-]+)=(.+)$/.exec(argument);
    if (!match || !Object.hasOwn(names, match[1]) || Object.hasOwn(options, names[match[1]]) || !match[2].trim()) {
      throw new Error('参数必须为已知且不重复的 --名称=数值');
    }
    if (match[1] === 'external-host') {
      if (!['0', '1'].includes(match[2])) throw new Error('external-host必须为0或1');
      options.externalHost = match[2] === '1';
    } else options[names[match[1]]] = Number(match[2]);
  }
  const lab = new UdpEnetLab(options);
  let finishing = null;
  let outputAvailable = true;
  let input;
  const output = (prefix, value) => {
    if (outputAvailable) process.stdout.write(`${prefix} ${JSON.stringify(value)}\n`);
  };
  const finish = () => {
    if (!finishing) finishing = Promise.resolve().then(async () => {
      input?.close();
      process.stdin.pause();
      await lab.close();
      output('UDP_LAB_FINAL', lab.getStats());
    });
    return finishing;
  };
  process.stdout.on('error', () => {
    outputAvailable = false;
    lab._ioError(null, null, 'streamErrors');
    void finish();
  });
  process.stdin.on('error', () => { lab._ioError(null, null, 'streamErrors'); void finish(); });
  process.once('SIGTERM', () => { void finish(); });
  process.once('SIGINT', () => { void finish(); });
  try {
    const ready = await lab.start();
    if (finishing) { await finishing; return; }
    output('UDP_LAB_READY', ready);
    input = createInterface({ input: process.stdin, crlfDelay: Infinity });
    input.on('line', line => {
      if (finishing) return;
      let command;
      try { command = JSON.parse(line); } catch { output('UDP_LAB_ERROR', { message: '无效的 JSON 命令' }); return; }
      if (command?.type === 'stats') output('UDP_LAB_STATS', lab.getStats());
      else if (command?.type === 'blackout') {
        try { lab.triggerBlackout(command.durationMs); output('UDP_LAB_BLACKOUT', { durationMs: command.durationMs }); }
        catch { output('UDP_LAB_ERROR', { message: 'blackout时长必须为1..2000ms' }); }
      }
      // 仅限父进程持有的本机匿名 PIPE，不是生产控制面。runner 必须截获并丢弃私有行，禁止保存/打印。
      else if (command?.type === 'external-config') {
        try { output('UDP_LAB_PRIVATE_CONFIG', lab.getExternalHostConfig()); }
        catch (error) { output('UDP_LAB_ERROR', { message: error.message }); }
      }
      else if (command?.type === 'export-replay') {
        try { output('UDP_LAB_PRIVATE_REPLAY', lab.exportReplay()); }
        catch (error) { output('UDP_LAB_ERROR', { message: error.message }); }
      }
      else if (command?.type === 'inject-replay') {
        try { output('UDP_LAB_REPLAY_INJECTED', lab.injectReplay(command)); }
        catch (error) { output('UDP_LAB_ERROR', { message: error.message }); }
      }
      else if (command?.type === 'attach') {
        try { lab.attachExternalHost(command); output('UDP_LAB_ATTACHED', { attached: true }); }
        catch (error) { output('UDP_LAB_ERROR', { message: error.message }); }
      }
      else if (command?.type === 'close') void finish();
      else output('UDP_LAB_ERROR', { message: lab.externalHost
        ? '仅支持 stats/blackout/external-config/attach/close 命令' : '仅支持 stats/blackout/close 命令' });
    });
    input.once('close', () => { void finish(); });
  } catch (error) {
    await lab.close();
    throw error;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { process.stderr.write(`UDP_LAB_ERROR ${error.message}\n`); process.exitCode = 1; });
}
