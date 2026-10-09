// IP / token 双维度限流（方案 §3.6）。
//
// 为什么是**两级**：
//   · IP 级 —— 挡住单机刷房 / 简单 DoS；
//   · token 级 —— 挡住「拿到一个合法 token 后高频心跳」，单靠 IP 级看不清这种行为。
//
// 两个阈值相对源方案都做了放宽，理由写在 §3.6：
//   · IP 60 → **120 次/分钟**：列表 8s 自动刷新 ≈ 7.5 次/分钟/人，而国内移动网络
//     大量玩家共享出口 IP（CGNAT），60 会互相拖累；
//   · 心跳间隔 10s → **5s**：容忍抖动，不必对每个包都卡死。

/** 固定窗口计数器的默认上限。 */
const DEFAULT_WINDOW_MS = 60_000;
const DEFAULT_IP_LIMIT = 120;
const DEFAULT_REGISTER_LIMIT = 5;
const DEFAULT_HEARTBEAT_MIN_INTERVAL_MS = 5_000;

class FixedWindowCounter {
  constructor(limit, windowMs, now) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    /** @type {Map<string, {count: number, windowStart: number}>} */
    this.buckets = new Map();
  }

  /**
   * 记一次访问。
   * @returns {{allowed: boolean, retryAfterSec: number}}
   */
  hit(key) {
    const ts = this.now();
    const bucket = this.buckets.get(key);
    if (!bucket || ts - bucket.windowStart >= this.windowMs) {
      this.buckets.set(key, { count: 1, windowStart: ts });
      return { allowed: true, retryAfterSec: 0 };
    }
    bucket.count += 1;
    if (bucket.count > this.limit) {
      const elapsed = ts - bucket.windowStart;
      return { allowed: false, retryAfterSec: Math.max(1, Math.ceil((this.windowMs - elapsed) / 1000)) };
    }
    return { allowed: true, retryAfterSec: 0 };
  }

  /** 清理过窗的桶，防 map 无限增长。 */
  sweep() {
    const ts = this.now();
    for (const [key, bucket] of this.buckets) {
      if (ts - bucket.windowStart >= this.windowMs) this.buckets.delete(key);
    }
  }
}

class MinIntervalLimiter {
  constructor(minIntervalMs, now) {
    this.minIntervalMs = minIntervalMs;
    this.now = now;
    /** @type {Map<string, number>} */
    this.lastSeen = new Map();
  }

  /** @returns {{allowed: boolean, retryAfterSec: number}} */
  hit(key) {
    const ts = this.now();
    const last = this.lastSeen.get(key);
    if (last !== undefined && ts - last < this.minIntervalMs) {
      return {
        allowed: false,
        retryAfterSec: Math.max(1, Math.ceil((this.minIntervalMs - (ts - last)) / 1000)),
      };
    }
    this.lastSeen.set(key, ts);
    return { allowed: true, retryAfterSec: 0 };
  }

  sweep() {
    const ts = this.now();
    for (const [key, last] of this.lastSeen) {
      if (ts - last >= this.minIntervalMs) this.lastSeen.delete(key);
    }
  }
}

export class RateLimiter {
  /**
   * @param {object} [opts]
   * @param {() => number} [opts.now] 注入时钟（测试用）
   */
  constructor(opts = {}) {
    const now = opts.now || (() => Date.now());
    this.now = now;
    this.ip = new FixedWindowCounter(DEFAULT_IP_LIMIT, DEFAULT_WINDOW_MS, now);
    this.register = new FixedWindowCounter(DEFAULT_REGISTER_LIMIT, DEFAULT_WINDOW_MS, now);
    this.heartbeat = new MinIntervalLimiter(DEFAULT_HEARTBEAT_MIN_INTERVAL_MS, now);
    this._sweepTimer = null;
  }

  /** 所有请求的 IP 级总闸。 */
  checkIp(ip) {
    return this.ip.hit(ip);
  }

  /** 注册房间的 IP 级闸（更严）。 */
  checkRegister(ip) {
    return this.register.hit(ip);
  }

  /** 心跳的 token 级最小间隔。 */
  checkHeartbeat(roomId) {
    return this.heartbeat.hit(roomId);
  }

  sweep() {
    this.ip.sweep();
    this.register.sweep();
    this.heartbeat.sweep();
  }

  startSweeper(intervalMs = DEFAULT_WINDOW_MS) {
    if (this._sweepTimer) return;
    this._sweepTimer = setInterval(() => this.sweep(), intervalMs);
    if (typeof this._sweepTimer.unref === 'function') this._sweepTimer.unref();
  }

  stopSweeper() {
    if (this._sweepTimer) {
      clearInterval(this._sweepTimer);
      this._sweepTimer = null;
    }
  }
}

/**
 * 取客户端 IP：优先 `X-Forwarded-For` 最后一跳（托管平台的反代会追加）。
 * ⚠ 注意托管平台差异：Render 等在反代后，直连 IP 是内网地址，必须读 XFF。
 */
export function clientIp(req) {
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.length > 0) {
    const parts = xff.split(',');
    return parts[parts.length - 1].trim();
  }
  return req.socket?.remoteAddress || 'unknown';
}
