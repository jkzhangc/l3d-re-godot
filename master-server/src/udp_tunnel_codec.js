// @trace NET-UDP-PROTOTYPE：隔离协议核，不被server.js导入，不创建公网监听。
// 会话id/key与来源必须由受保护的控制面/探测协商注入；本模块不负责发放凭据。
import { createHmac, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';
import { performance } from 'node:perf_hooks';

export const HEADER_BYTES = 18;
export const TAG_BYTES = 16;
export const MAX_PAYLOAD = 1392;
export const MAX_DATAGRAM = HEADER_BYTES + MAX_PAYLOAD + TAG_BYTES;
export const REPLAY_WINDOW = 256;
const MAGIC = Buffer.from('L3DU');
const MAX_SEQUENCE = 0xffffffff;

export class UdpTunnelCodec {
  constructor({ sessionId, key, txDirection, source, expiresAt,
    now = () => performance.now(), packetsPerSecond = 2048, bytesPerSecond = 2 * 1024 * 1024 }) {
    // expiresAt是本进程单调时钟deadline，不是来自远端的Unix时间。
    const started = now();
    if (!Buffer.isBuffer(sessionId) || sessionId.length !== 8 || !Buffer.isBuffer(key) || key.length !== 32
      || ![0, 1].includes(txDirection) || !source || typeof source.address !== 'string'
      || !isIP(source.address) || !Number.isInteger(source.port) || source.port < 1 || source.port > 65535
      || !Number.isFinite(started) || !Number.isFinite(expiresAt) || expiresAt <= started || !Number.isFinite(packetsPerSecond) || packetsPerSecond < 1
      || !Number.isFinite(bytesPerSecond) || bytesPerSecond < MAX_DATAGRAM) {
      throw new TypeError('invalid UDP session configuration');
    }
    this.id = Buffer.from(sessionId);
    this.key = Buffer.from(key);
    this.txDirection = txDirection;
    this.source = { address: source.address, port: source.port };
    this.expiresAt = expiresAt;
    this.now = now;
    this.nextSequence = 0;
    this.highest = -1;
    this.seen = new Set();
    this.pps = packetsPerSecond;
    this.bps = bytesPerSecond;
    this.packetTokens = this.pps;
    this.byteTokens = this.bps;
    this.lastRefill = started;
    this.closed = false;
  }

  seal(payload) {
    if (this.closed || this.now() >= this.expiresAt || this.nextSequence > MAX_SEQUENCE
      || !Buffer.isBuffer(payload) || payload.length < 1 || payload.length > MAX_PAYLOAD) return null;
    const body = Buffer.alloc(HEADER_BYTES + payload.length);
    MAGIC.copy(body);
    body[4] = 1;
    body[5] = this.txDirection;
    this.id.copy(body, 6);
    body.writeUInt32BE(this.nextSequence++, 14);
    payload.copy(body, HEADER_BYTES);
    return Buffer.concat([body, createHmac('sha256', this.key).update(body).digest().subarray(0, TAG_BYTES)]);
  }

  // 无效包无响应、不更新窗口/端点；乱序在窗口内透传，可靠性由ENet提供，不在这里重传。
  open(packet, source) {
    const now = this.now();
    if (this.closed || now >= this.expiresAt || !Buffer.isBuffer(packet)
      || packet.length <= HEADER_BYTES + TAG_BYTES || packet.length > MAX_DATAGRAM
      || !source || source.address !== this.source.address || source.port !== this.source.port
      || !packet.subarray(0, 4).equals(MAGIC) || packet[4] !== 1 || packet[5] !== 1 - this.txDirection
      || !packet.subarray(6, 14).equals(this.id)) return null;
    const body = packet.subarray(0, -TAG_BYTES);
    const tag = createHmac('sha256', this.key).update(body).digest().subarray(0, TAG_BYTES);
    if (!timingSafeEqual(tag, packet.subarray(-TAG_BYTES))) return null;
    const sequence = packet.readUInt32BE(14);
    if (sequence <= this.highest - REPLAY_WINDOW || this.seen.has(sequence)) return null;
    const elapsed = Math.max(0, now - this.lastRefill) / 1000;
    this.packetTokens = Math.min(this.pps, this.packetTokens + elapsed * this.pps);
    this.byteTokens = Math.min(this.bps, this.byteTokens + elapsed * this.bps);
    this.lastRefill = Math.max(this.lastRefill, now);
    if (this.packetTokens < 1 || this.byteTokens < packet.length) return null;
    this.packetTokens--;
    this.byteTokens -= packet.length;
    this.highest = Math.max(this.highest, sequence);
    this.seen.add(sequence);
    for (const old of this.seen) if (old <= this.highest - REPLAY_WINDOW) this.seen.delete(old);
    return Buffer.from(body.subarray(HEADER_BYTES));
  }

  close() {
    this.closed = true;
    this.key.fill(0);
    this.seen.clear();
  }
}
