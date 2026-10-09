# master-server —— 互联网联机的大厅服务器（房间目录）

只负责**找房间**：玩家注册自己的房间、其他人拉列表、点一下就加入。
**不参与游戏数据转发**（不模拟、不中继），信任边界不因此扩大。
契约与设计依据见仓库根目录的 `互联网联机模式策划方案.md`（§3 API、§4 托管、§8 验证）。

## 为什么需要它

当前游戏只能用 UPnP + 手动填 IP 直连。UPnP 常失败，玩家又没有"去哪里找房"的地方。
本服务的职责就是把「交换 IP」这件事消灭掉。

```
互联网联机 = ①房主可达性（穿透，本服务不负责） + ②房间发现（本服务负责）
```

## 快速开始

```bash
cd master-server
npm install
npm test          # 19 个契约用例
npm start         # 默认监听 0.0.0.0:10000（或 $PORT）
```

自测：

```bash
curl localhost:10000/health
# {"status":"ok"}
```

## API（7 个端点）

| # | 方法 | 路径 | 认证 | 说明 |
|---|---|---|---|---|
| 1 | GET | `/health` | 无 | 存活探测 |
| 2 | GET | `/api/rooms?protocol=<p>&game=<v>` | 无 | 房间列表，**按 protocol 等值过滤** |
| 3 | POST | `/api/rooms` | 无 | 注册房间，返回 `{room, hostToken}`（token **仅此一次**） |
| 4 | POST | `/api/rooms/:id/heartbeat` | `hostToken` | 保活 + 更新人数 |
| 5 | DELETE | `/api/rooms/:id` | `hostToken` | 主动关闭 |
| 6 | GET | `/api/stats` | 无 | `{rooms, players}`（运维/自测用） |
| 7 | POST | `/api/rooms/:id/report_unreachable` | 无 | 连接失败计数（M2 才用于降权） |

### 关键约定（改动前必读）

- **`hostToken` 只在注册响应出现一次**，服务端只存 `sha256`，比较用常量时间。
  列表投影里**绝不含** token 或任何派生值。
- **协议分桶**：`Net.PROTOCOL_VERSION` 只接受完全匹配、不匹配直接断连，所以列表里
  混入其他协议的房 = 「点进去必然失败」。故列表默认按请求方 protocol 过滤。
- **`transport` 目前只接受 `udp`**：ENet 走 UDP；`tcp` 需要换
  `WebSocketMultiplayerPeer`，尚未实现。显式拒绝而非静默接受。
- **`currentPlayers` 一律 clamp** 到 `[1, maxPlayers]`，永不信任自报值。
- **`address` 白名单**：只接受域名或公网 IPv4；拒绝 IPv6、`localhost` 与全部内网段。
- **房间超时 60s**（不是源方案的 30s）：容忍移动端切后台连续丢包。
- **不保活**：托管平台冷启动由客户端 UI 做阶梯提示，服务端不做 ping 保活
  （24×7 会吃掉免费档全部实例时）。

### 限流

| 维度 | 阈值 | 理由 |
|---|---|---|
| IP 总闸 | 120 次/分钟 | 列表 8s 自动刷新 ≈ 7.5 次/分钟/人；国内移动网络大量玩家共享出口 IP |
| IP 注册 | 5 次/分钟 | 挡刷房 |
| token 心跳 | 最小 5s 间隔 | 容忍抖动 |

超限返回 **429 + `Retry-After`**；客户端约定**静默退避、不清列表**。

## 存储

**纯内存 `Map`**，无数据库。托管平台重启后房间消失**无害** —— 房主仍在运行，
客户端心跳收到 404 会立即重发注册（客户端侧实现"注册自愈"）。
房间上限 500，超限丢弃最久未心跳的。

## 部署

- 监听必须 `0.0.0.0`（**不能**写 `localhost`，否则平台探测不到）。
- 端口取 `process.env.PORT`，退 10000。
- Render：`Runtime=Node` → `Build: npm install` → `Start: npm start`。
- ⚠ `onrender.com` 国内可达性差，M1 仅作验证；M2 迁国内（三丰云 / 阿里云学生机 / Oracle Always Free）。

## 目录

```
master-server/
├── package.json
├── server.js          # 入口：createApp / startServer（导出以便测试注入）
├── src/
│   ├── rooms.js       # 内存存储、ID 生成、token 校验、清理定时器
│   ├── validate.js    # 字段校验与 address 白名单
│   ├── rate_limit.js  # IP / token 双维度限流
│   └── routes.js      # 7 个端点
└── test/
    └── contract.test.js
```
