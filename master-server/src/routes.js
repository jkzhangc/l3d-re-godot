// 7 个端点的路由装配。
// 契约见 `互联网联机模式策划方案.md` §3.2（API 契约）与 §3.4/§3.5/§3.6。
//
// ⚠ 边界：Master Server **不参与**进入房间，只负责「找房间」（§5.4）。它不模拟、
// 不转发任何游戏数据，信任边界不因此扩大（§6）。

import { Router } from 'express';
import { RoomStore } from './rooms.js';
import { RateLimiter, clientIp } from './rate_limit.js';
import { validateRoomPayload } from './validate.js';

/**
 * @param {object} [opts]
 * @param {RoomStore} [opts.store]
 * @param {RateLimiter} [opts.limiter]
 * @param {() => number} [opts.now]
 */
export function createRouter(opts = {}) {
  const now = opts.now || (() => Date.now());
  const store = opts.store || new RoomStore({ now });
  const limiter = opts.limiter || new RateLimiter({ now });

  const router = Router();

  /** 统一的 429 响应：告知客户端退避（客户端约定**静默退避不清列表**，§3.6）。 */
  function tooMany(res, retryAfterSec) {
    res.set('Retry-After', String(retryAfterSec));
    res.status(429).json({ success: false, error: 'rate_limited', retryAfterSec });
  }

  // ── 1. GET /health —— 供托管平台存活探测 ──
  router.get('/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  // ── 2. GET /api/rooms?protocol=<p>&game=<v> —— 房间列表 ──
  // 默认按请求方的 protocol 过滤（协议分桶，§3.3）；game 为空则不限版本。
  router.get('/api/rooms', (req, res) => {
    const gate = limiter.checkIp(clientIp(req));
    if (!gate.allowed) return tooMany(res, gate.retryAfterSec);

    const protocol = typeof req.query.protocol === 'string' ? req.query.protocol : '';
    const game = typeof req.query.game === 'string' ? req.query.game : '';
    const rooms = store.list({ protocol, game });
    return res.json({ success: true, serverTime: now(), rooms });
  });

  // ── 3. POST /api/rooms —— 注册房间（成功返回 {id, hostToken}）──
  router.post('/api/rooms', (req, res) => {
    const ip = clientIp(req);
    const gate = limiter.checkIp(ip);
    if (!gate.allowed) return tooMany(res, gate.retryAfterSec);
    const reg = limiter.checkRegister(ip);
    if (!reg.allowed) return tooMany(res, reg.retryAfterSec);

    const validated = validateRoomPayload(req.body);
    if (!validated.ok) {
      return res.status(400).json({ success: false, error: 'invalid_payload', reason: validated.reason });
    }

    const { room, hostToken, replacedRoomId } = store.create(validated.value);
    // hostToken 仅在此响应出现一次；服务端只留 hash（§3.4）。
    return res.status(201).json({ success: true, room, hostToken, replacedRoomId });
  });

  // ── 4. POST /api/rooms/:id/heartbeat —— 保活 + 更新人数 ──
  router.post('/api/rooms/:id/heartbeat', (req, res) => {
    const gate = limiter.checkIp(clientIp(req));
    if (!gate.allowed) return tooMany(res, gate.retryAfterSec);

    const roomId = String(req.params.id || '');
    // token 级最小间隔：先按 roomId 记一次，挡住同房高频心跳。
    const hb = limiter.checkHeartbeat(roomId);
    if (!hb.allowed) return tooMany(res, hb.retryAfterSec);

    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const result = store.heartbeat(roomId, body.hostToken, body.currentPlayers);
    if (!result.ok) {
      // not_found → 404：客户端据此触发「注册自愈」（§4.7）。
      // bad_token → 403：凭据错误，客户端不应自愈（重注册也拿不到这个房间）。
      const status = result.reason === 'not_found' ? 404 : 403;
      return res.status(status).json({ success: false, error: result.reason });
    }
    return res.json({ success: true, ttl: result.ttl });
  });

  // ── 5. DELETE /api/rooms/:id —— 主动关闭（房主正常退出）──
  router.delete('/api/rooms/:id', (req, res) => {
    const gate = limiter.checkIp(clientIp(req));
    if (!gate.allowed) return tooMany(res, gate.retryAfterSec);

    const roomId = String(req.params.id || '');
    const token = (req.body && req.body.hostToken) || req.get('x-host-token') || '';
    const result = store.remove(roomId, token);
    if (!result.ok) {
      const status = result.reason === 'not_found' ? 404 : 403;
      return res.status(status).json({ success: false, error: result.reason });
    }
    return res.json({ success: true });
  });

  // ── 6. GET /api/stats —— 供自测/运维（§3.2 标注为可选）──
  router.get('/api/stats', (req, res) => {
    let players = 0;
    for (const rec of store.rooms.values()) players += rec.currentPlayers;
    res.json({ success: true, rooms: store.size, players });
  });

  // ── 7. POST /api/rooms/:id/report_unreachable —— 连接失败上报（可选，M2）──
  // M1 先只做计数与日志，不做降权/隐藏（那需要更成熟的判定，见 §3.2 的"可选"标注）。
  router.post('/api/rooms/:id/report_unreachable', (req, res) => {
    const gate = limiter.checkIp(clientIp(req));
    if (!gate.allowed) return tooMany(res, gate.retryAfterSec);

    const roomId = String(req.params.id || '');
    const rec = store.rooms.get(roomId);
    if (!rec) return res.status(404).json({ success: false, error: 'not_found' });
    rec.unreachableReports = (rec.unreachableReports || 0) + 1;
    console.log(`[master-server] unreachable report room=${roomId} count=${rec.unreachableReports}`);
    return res.json({ success: true });
  });

  return { router, store, limiter };
}
