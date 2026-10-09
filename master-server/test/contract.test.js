// 端到端契约测试：7 个端点的行为，重点覆盖方案 §8.2 列出的 7 条。
//
// 用 Node 内置 test runner（`node --test`），零额外依赖，避免为测试再引 Jest 之类。
// 服务通过 `createApp()` 注入内存实现，**不监听端口**（用 supertest 那样起真 HTTP
// 会引入依赖；这里用 node:http 直接请求 startServer 起的临时端口更贴近真实）。

import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { startServer } from '../server.js';

let server;
let baseUrl;

/**
 * 请求级唯一 IP 计数器。
 *
 * 【为什么必须这么做】服务端对「注册房间」有 **5 次/分钟/IP** 的限流（§3.6）。测试若
 * 全部从 127.0.0.1 发请求，跑到第 6 个注册用例就会被自己触发的 429 打断 —— 那是**服务端
 * 行为正确**、测试隔离不足。真实世界里不同玩家来自不同出口 IP，因此这里给每个请求一个
 * 独立 IP（经 X-Forwarded-For，同时顺带覆盖 clientIp() 的 XFF 解析）。
 *
 * 需要验证限流本身的用例，显式传 `{ pinIp }` 钉住同一个 IP。
 */
let ipCounter = 0;
function nextIp() {
  ipCounter += 1;
  return `203.0.113.${(ipCounter % 250) + 1}`;
}

/** 基于 fetch 的薄封装：返回 {status, body, headers}。 */
async function request(method, path, body, { headers = {}, pinIp } = {}) {
  const opts = { method, headers: { ...headers } };
  opts.headers['x-forwarded-for'] = pinIp || nextIp();
  if (body !== undefined) {
    opts.headers['content-type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${path}`, opts);
  const text = await res.text();
  let parsed = null;
  try {
    parsed = text.length > 0 ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed, headers: res.headers };
}

let addrCounter = 0;

function validRoom(overrides = {}) {
  // 默认给**唯一 address**：服务端把「同 address+port」视为同一房主重复注册并覆盖旧房
  // （§3.5「单 hostToken 房间数 = 1」在注册期的实用代理，因为注册时还没有 token）。
  // 测试若不换地址，多个用例会互相覆盖对方的房间。
  addrCounter += 1;
  return {
    name: '欢乐合作房',
    hostName: '玩家A',
    address: `host-${addrCounter}.frp.example.com`,
    port: 27015,
    transport: 'udp',
    currentPlayers: 1,
    maxPlayers: 4,
    difficulty: 2,
    chapterLabel: '第一关-街道',
    gameVersion: 'v0.33',
    protocol: 'l3d_main_v2_combat_rpc',
    ...overrides,
  };
}

before(async () => {
  // 端口 0 = 让 OS 分配空闲端口，避免与开发中的服务冲突。
  server = startServer({ port: 0 });
  await new Promise((resolve) => server.once('listening', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  server?.close();
});

describe('GET /health', () => {
  it('返回 ok', async () => {
    const r = await request('GET', '/health');
    assert.equal(r.status, 200);
    assert.equal(r.body.status, 'ok');
  });
});

describe('POST /api/rooms —— 注册', () => {
  it('成功返回 201 + room + hostToken（token 仅此一次）', async () => {
    const r = await request('POST', '/api/rooms', validRoom());
    assert.equal(r.status, 201);
    assert.equal(r.body.success, true);
    assert.ok(r.body.hostToken, 'hostToken 必须返回');
    assert.equal(r.body.room.id.length, 6, 'id 应为 6 位');
    assert.match(r.body.room.id, /^[A-HJ-NP-Z2-9]{6}$/, 'id 字符集排除 0/O/1/I/L');
  });

  it('列表中**绝不**出现 hostToken', async () => {
    await request('POST', '/api/rooms', validRoom());
    const r = await request('GET', '/api/rooms?protocol=l3d_main_v2_combat_rpc');
    assert.equal(r.status, 200);
    for (const room of r.body.rooms) {
      assert.ok(!('hostToken' in room), '列表不得含 hostToken');
      assert.ok(!JSON.stringify(room).includes('hostToken'));
    }
  });

  it('拒绝指向内网的 address', async () => {
    for (const bad of ['192.168.1.5', '10.0.0.1', '127.0.0.1', '169.254.1.1', '172.16.0.1', 'localhost']) {
      const r = await request('POST', '/api/rooms', validRoom({ address: bad }));
      assert.equal(r.status, 400, `应拒绝 ${bad}`);
      assert.equal(r.body.error, 'invalid_payload');
    }
  });

  it('拒绝非法端口与超限人数', async () => {
    assert.equal((await request('POST', '/api/rooms', validRoom({ port: 0 }))).status, 400);
    assert.equal((await request('POST', '/api/rooms', validRoom({ port: 70000 }))).status, 400);
    assert.equal((await request('POST', '/api/rooms', validRoom({ maxPlayers: 5 }))).status, 400);
  });

  it('拒绝非 udp 的 transport（M1 仅 UDP）', async () => {
    const r = await request('POST', '/api/rooms', validRoom({ transport: 'tcp' }));
    assert.equal(r.status, 400);
    assert.match(r.body.reason, /udp/);
  });

  it('clamp currentPlayers 到 [1, maxPlayers]（永不信任自报值）', async () => {
    const hi = await request('POST', '/api/rooms', validRoom({ currentPlayers: 999, name: 'clamp-hi' }));
    assert.equal(hi.body.room.currentPlayers, 4);
    const lo = await request('POST', '/api/rooms', validRoom({ currentPlayers: -5, name: 'clamp-lo' }));
    assert.equal(lo.body.room.currentPlayers, 1);
  });

  it('名字清洗：控制字符被剔除、空白名回退默认值', async () => {
    const r = await request('POST', '/api/rooms', validRoom({ name: '   \u0007 \u001b  ' }));
    assert.equal(r.body.room.name, '房主的房间');
  });
});

describe('POST /api/rooms/:id/heartbeat —— 心跳', () => {
  it('正确 token 保活，返回 ttl', async () => {
    const created = await request('POST', '/api/rooms', validRoom());
    const { id } = created.body.room;
    const { hostToken } = created.body;

    const r = await request('POST', `/api/rooms/${id}/heartbeat`, { hostToken, currentPlayers: 3 });
    assert.equal(r.status, 200);
    assert.equal(r.body.ttl, 60);
  });

  it('错误 token → 403（不应触发注册自愈）', async () => {
    const created = await request('POST', '/api/rooms', validRoom());
    const { id } = created.body.room;
    const r = await request('POST', `/api/rooms/${id}/heartbeat`, { hostToken: 'deadbeef'.repeat(8) });
    assert.equal(r.status, 403);
    assert.equal(r.body.error, 'bad_token');
  });

  it('同房间 5s 内二次心跳 → 429（token 级最小间隔）', async () => {
    const created = await request('POST', '/api/rooms', validRoom());
    const { id } = created.body.room;
    const { hostToken } = created.body;
    const first = await request('POST', `/api/rooms/${id}/heartbeat`, { hostToken });
    assert.equal(first.status, 200, '首次心跳应放行');
    const second = await request('POST', `/api/rooms/${id}/heartbeat`, { hostToken });
    assert.equal(second.status, 429, '紧接的第二次应被最小间隔拦下');
  });

  it('不存在的房间 → 404（客户端据此触发注册自愈，§4.7）', async () => {
    const r = await request('POST', '/api/rooms/ZZZZZZ/heartbeat', { hostToken: 'ab'.repeat(32) });
    assert.equal(r.status, 404);
    assert.equal(r.body.error, 'not_found');
  });
});

describe('DELETE /api/rooms/:id —— 主动关闭', () => {
  it('正确 token 删除成功，随后列表里消失', async () => {
    const created = await request('POST', '/api/rooms', validRoom({ name: '待删房' }));
    const { id } = created.body.room;
    const { hostToken } = created.body;

    const del = await request('DELETE', `/api/rooms/${id}`, { hostToken });
    assert.equal(del.status, 200);

    const list = await request('GET', '/api/rooms?protocol=l3d_main_v2_combat_rpc');
    assert.ok(!list.body.rooms.some((x) => x.id === id), '删除后不应再出现');
  });

  it('错误 token → 403，房间仍在', async () => {
    const created = await request('POST', '/api/rooms', validRoom({ name: '保护房' }));
    const { id } = created.body.room;
    const del = await request('DELETE', `/api/rooms/${id}`, { hostToken: 'ff'.repeat(32) });
    assert.equal(del.status, 403);
    const list = await request('GET', '/api/rooms?protocol=l3d_main_v2_combat_rpc');
    assert.ok(list.body.rooms.some((x) => x.id === id), '拒绝后房间应仍在');
  });
});

describe('GET /api/rooms —— 协议分桶', () => {
  it('只返回同 protocol 的房间（§3.3）', async () => {
    await request('POST', '/api/rooms', validRoom({ protocol: 'proto_A', name: 'A房' }));
    await request('POST', '/api/rooms', validRoom({ protocol: 'proto_B', name: 'B房' }));

    const a = await request('GET', '/api/rooms?protocol=proto_A');
    assert.ok(a.body.rooms.every((x) => x.protocol === 'proto_A'));
    assert.ok(a.body.rooms.some((x) => x.name === 'A房'));
  });

  it('game 参数按版本等值过滤', async () => {
    await request('POST', '/api/rooms', validRoom({ protocol: 'proto_C', gameVersion: 'v1', name: 'v1房' }));
    await request('POST', '/api/rooms', validRoom({ protocol: 'proto_C', gameVersion: 'v2', name: 'v2房' }));

    const v1 = await request('GET', '/api/rooms?protocol=proto_C&game=v1');
    assert.ok(v1.body.rooms.every((x) => x.gameVersion === 'v1'));
    assert.ok(v1.body.rooms.some((x) => x.name === 'v1房'));
  });
});

describe('GET /api/stats', () => {
  it('返回房间数与玩家数', async () => {
    const r = await request('GET', '/api/stats');
    assert.equal(r.status, 200);
    assert.equal(typeof r.body.rooms, 'number');
    assert.equal(typeof r.body.players, 'number');
  });
});

describe('限流（§3.6）', () => {
  it('同一 IP 第 6 次注册 → 429，且带 Retry-After', async () => {
    // 钉住同一个 IP，制造真实的高频注册。
    const pinIp = '198.51.100.77';
    const results = [];
    for (let i = 0; i < 6; i += 1) {
      // 每次换 address 以避免「重复注册覆盖」逻辑干扰计数。
      results.push(await request('POST', '/api/rooms',
        validRoom({ address: `host-${i}.example.com` }), { pinIp }));
    }
    const firstFiveOk = results.slice(0, 5).every((r) => r.status === 201);
    assert.ok(firstFiveOk, '前 5 次应放行');
    assert.equal(results[5].status, 429, '第 6 次应被限流');
    assert.equal(results[5].body.error, 'rate_limited');
    assert.ok(Number(results[5].headers.get('retry-after')) >= 1, '应给出 Retry-After');
  });
});

describe('CORS', () => {
  it('响应头允许任意来源（Android/Web 导出需要）', async () => {
    const r = await request('GET', '/health');
    assert.equal(r.headers.get('access-control-allow-origin'), '*');
  });
});
