// 房间存储（内存 Map）、ID 生成、hostToken 校验与清理定时器。
// 契约见 `互联网联机模式策划方案.md` §3.1（房间对象）、§3.4（归属认证）、§3.5（生命周期）。
//
// 存储选型：**纯内存 Map**（§3.7）。托管平台重启后房间消失无害 —— 房主仍在运行，
// 客户端会重发 POST /api/rooms（方案 §4.7 注册自愈）。不做数据库，直到出现账号/排行需求。

import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';

/** 心跳间隔的期望值（客户端每 10s 一次，见 §3.5）。 */
export const HEARTBEAT_INTERVAL_MS = 10_000;
/** 清理扫描周期。 */
export const SWEEP_INTERVAL_MS = 10_000;
/**
 * 房间超时：60s。方案 §3.5 把源方案的 30s 放宽到此值，理由是移动端切后台 /
 * 系统 GC 抖动 / 弱网抖动会吃掉 1–2 个心跳周期；60s = 容忍连续 5 次丢包。
 */
export const ROOM_TIMEOUT_MS = 60_000;
/** 房间空闲上限，防刷爆内存（§3.5）。 */
export const MAX_ROOMS = 500;

/** ID 字符集：Base32 去掉易混的 0/O/1/I/L（§3.1）。 */
const ID_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const ID_LENGTH = 6;

function generateRoomId() {
  const bytes = randomBytes(ID_LENGTH);
  let out = '';
  for (let i = 0; i < ID_LENGTH; i += 1) {
    out += ID_ALPHABET[bytes[i] % ID_ALPHABET.length];
  }
  return out;
}

/** 常量时间比较两个等长 hex 字符串；长度不等直接 false（不泄漏长度以外信息）。 */
function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a, 'hex');
  const bufB = Buffer.from(b, 'hex');
  if (bufA.length !== bufB.length || bufA.length === 0) return false;
  return timingSafeEqual(bufA, bufB);
}

export class RoomStore {
  /**
   * @param {object} [opts]
   * @param {number} [opts.now] 注入时钟（测试用），默认 Date.now
   */
  constructor(opts = {}) {
    /** @type {Map<string, object>} roomId -> 内部房间记录 */
    this.rooms = new Map();
    /** roomId -> hostToken 的 sha256 hex（**只存 hash**，不存明文，见 §3.4） */
    this.tokenHashes = new Map();
    this.now = opts.now || (() => Date.now());
    this._sweepTimer = null;
  }

  /** 生成一个房间 ID（保证当前未占用）。 */
  _uniqueId() {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const id = generateRoomId();
      if (!this.rooms.has(id)) return id;
    }
    // 极端碰撞：退化为 UUID 前 8 位（仍满足字符集要求）。
    return randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase();
  }

  /** 记录数（供 /api/stats 与测试）。 */
  get size() {
    return this.rooms.size;
  }

  /**
   * 注册房间。
   * @param {object} value 已经过 validate.js 规范化的字段
   * @returns {{room: object, hostToken: string, replacedRoomId: string|null}}
   *   hostToken **仅此一次返回**，服务端只留 hash。
   */
  create(value) {
    // 同一 hostToken 只允许 1 个房间（§3.5）。但注册时还没有 token，故按
    // 「同 address+port」判定重复注册 —— 同一房主重开视为覆盖旧房而非报错。
    let replacedRoomId = null;
    for (const [id, rec] of this.rooms) {
      if (rec.address === value.address && rec.port === value.port) {
        this.rooms.delete(id);
        this.tokenHashes.delete(id);
        replacedRoomId = id;
        break;
      }
    }

    const id = this._uniqueId();
    const hostToken = randomBytes(32).toString('hex');
    const tokenHash = hashToken(hostToken);
    const ts = this.now();
    const room = {
      id,
      ...value,
      createdAt: ts,
      lastHeartbeat: ts,
    };
    this.rooms.set(id, room);
    this.tokenHashes.set(id, tokenHash);
    this._enforceCapacity();
    return { room: publicRoom(room), hostToken, replacedRoomId };
  }

  /** 超容量时丢弃**最久未心跳**的房间（§3.5 防刷爆内存）。 */
  _enforceCapacity() {
    while (this.rooms.size > MAX_ROOMS) {
      let oldestId = null;
      let oldestTs = Infinity;
      for (const [id, rec] of this.rooms) {
        if (rec.lastHeartbeat < oldestTs) {
          oldestTs = rec.lastHeartbeat;
          oldestId = id;
        }
      }
      if (oldestId === null) break;
      this.rooms.delete(oldestId);
      this.tokenHashes.delete(oldestId);
    }
  }

  /** 校验 hostToken 是否为该房间的合法持有者（常量时间）。 */
  _isOwner(roomId, hostToken) {
    if (typeof hostToken !== 'string' || hostToken.length === 0) return false;
    const expected = this.tokenHashes.get(roomId);
    if (!expected) return false;
    return safeEqualHex(hashToken(hostToken), expected);
  }

  /**
   * 心跳保活 + 更新 currentPlayers。
   * @returns {{ok: true, ttl: number} | {ok: false, reason: string}}
   */
  heartbeat(roomId, hostToken, currentPlayers) {
    const rec = this.rooms.get(roomId);
    if (!rec) return { ok: false, reason: 'not_found' };
    if (!this._isOwner(roomId, hostToken)) return { ok: false, reason: 'bad_token' };
    if (currentPlayers !== undefined && currentPlayers !== null) {
      const n = Number(currentPlayers);
      if (Number.isFinite(n)) {
        rec.currentPlayers = Math.min(Math.max(Math.trunc(n), 1), rec.maxPlayers);
      }
    }
    rec.lastHeartbeat = this.now();
    return { ok: true, ttl: Math.round(ROOM_TIMEOUT_MS / 1000) };
  }

  /**
   * 主动关闭房间（房主正常退出）。
   * @returns {{ok: true} | {ok: false, reason: string}}
   */
  remove(roomId, hostToken) {
    const rec = this.rooms.get(roomId);
    if (!rec) return { ok: false, reason: 'not_found' };
    if (!this._isOwner(roomId, hostToken)) return { ok: false, reason: 'bad_token' };
    this.rooms.delete(roomId);
    this.tokenHashes.delete(roomId);
    return { ok: true };
  }

  /**
   * 列表：按 protocol 等值过滤（§3.3 协议分桶），gameVersion 可选过滤。
   * 服务端**不做版本兼容判断**，只做等值过滤 —— 兼容逻辑不放在大厅服务器。
   * @param {{protocol?: string, game?: string}} filter
   */
  list(filter = {}) {
    const out = [];
    for (const rec of this.rooms.values()) {
      if (filter.protocol && rec.protocol !== filter.protocol) continue;
      if (filter.game && rec.gameVersion !== filter.game) continue;
      out.push(publicRoom(rec));
    }
    // 稳定排序：先按人数降序（人气房靠前），再按创建时间升序。
    out.sort((a, b) => {
      if (b.currentPlayers !== a.currentPlayers) return b.currentPlayers - a.currentPlayers;
      return a.createdAt - b.createdAt;
    });
    return out;
  }

  /** 清理超时房间，返回被删数量。 */
  sweep() {
    const deadline = this.now() - ROOM_TIMEOUT_MS;
    let removed = 0;
    for (const [id, rec] of this.rooms) {
      if (rec.lastHeartbeat < deadline) {
        this.rooms.delete(id);
        this.tokenHashes.delete(id);
        removed += 1;
      }
    }
    return removed;
  }

  /** 启动清理定时器（幂等）。 */
  startSweeper() {
    if (this._sweepTimer) return;
    this._sweepTimer = setInterval(() => this.sweep(), SWEEP_INTERVAL_MS);
    if (typeof this._sweepTimer.unref === 'function') this._sweepTimer.unref();
  }

  /** 停止清理定时器。 */
  stopSweeper() {
    if (this._sweepTimer) {
      clearInterval(this._sweepTimer);
      this._sweepTimer = null;
    }
  }
}

/** sha256 hex（hostToken 只以 hash 形式落内存，§3.4）。 */
export function hashToken(token) {
  return createHash('sha256').update(String(token)).digest('hex');
}

/** 对外投影：**绝不包含** hostToken 或任何 token 派生值（§3.4 边界）。 */
export function publicRoom(rec) {
  return {
    id: rec.id,
    name: rec.name,
    hostName: rec.hostName,
    address: rec.address,
    port: rec.port,
    transport: rec.transport,
    currentPlayers: rec.currentPlayers,
    maxPlayers: rec.maxPlayers,
    difficulty: rec.difficulty,
    chapterLabel: rec.chapterLabel,
    gameVersion: rec.gameVersion,
    protocol: rec.protocol,
    hasPassword: rec.hasPassword,
    createdAt: rec.createdAt,
    lastHeartbeat: rec.lastHeartbeat,
  };
}
