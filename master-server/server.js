// Master Server 入口：路由装配 + 监听。
// 契约见 `互联网联机模式策划方案.md` §3.2（API）与 §3.8（目录结构）。

import express from 'express';
import cors from 'cors';
import { pathToFileURL } from 'node:url';
import { createRouter } from './src/routes.js';
import { RoomStore } from './src/rooms.js';
import { RateLimiter } from './src/rate_limit.js';

/**
 * 构造一个未监听的 Express app（便于测试直接注入，不占端口）。
 * @param {object} [opts]
 * @param {RoomStore} [opts.store]
 * @param {RateLimiter} [opts.limiter]
 * @param {() => number} [opts.now]
 */
export function createApp(opts = {}) {
  const app = express();

  // ⚠ Godot 桌面端无 CORS 限制，但 **Android/Web 导出需要**（§3.6）。
  app.use(cors({ origin: '*' }));
  app.use(express.json({ limit: '16kb' }));

  const { router, store, limiter } = createRouter(opts);
  app.use(router);

  // 兜底错误处理：任何未捕获异常都返回 JSON，不泄漏栈。
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    console.error('[master-server] unhandled error:', err?.message || err);
    res.status(400).json({ success: false, error: 'bad_request' });
  });

  // 供调用方启动/停止后台定时器（server.js 与测试都用）。
  app.locals.store = store;
  app.locals.limiter = limiter;
  return app;
}

/**
 * 启动 HTTP 服务并挂上清理定时器。
 * @param {object} [opts]
 * @param {number} [opts.port] 不传则取 process.env.PORT，再退 10000
 * @returns {import('node:http').Server}
 */
export function startServer(opts = {}) {
  const app = createApp(opts);
  app.locals.store.startSweeper();
  app.locals.limiter.startSweeper();

  const port = opts.port || Number(process.env.PORT) || 10000;
  // ⚠ 必须监听 0.0.0.0，**不能**写 localhost —— 否则托管平台探测不到（§3.8）。
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`[master-server] listening on 0.0.0.0:${port}`);
  });
  return server;
}

// 仅在被直接执行时启动（被 import 时不启动，便于测试）。
// ⚠ 不要用 `import.meta.url === 'file://' + process.argv[1]` 手拼：本仓库路径含
// `!` 与中文字符，Windows 下拼接结果与 URL 编码不一致，会**静默不启动**。
// 官方推荐用 pathToFileURL 归一化后比较。
const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  startServer();
}
