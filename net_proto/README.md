# net_proto — 联机原型（Host 全量模拟）

独立 Godot 4.6 项目，用**最小代码**验证《联机系统架构设计.md》第 8 节选定的
「Host 全量模拟 + 客户端输入上报」模型是否能在 4.6 的 MultiplayerSpawner /
MultiplayerSynchronizer 上跑通，并暴露原型阶段该处理的问题。

**只做一件事**：一个 4 人房间，每人在大竞技场里 WASD 移动、左键自动瞄准最近
僵尸开火。僵尸由 Host 生成并追击最近玩家。谁被打倒 3 秒后原地复活。

---

## 运行方法

两个窗口模拟双人联机：

```powershell
# 窗口 1 —— 创建房间（Host）
godot --path net_proto

# 窗口 2 —— 加入（Client）
godot --path net_proto
```

窗口 2 的昵称改掉（如「玩家B」），点「加入」。两边都点「开始游戏」。
跨机器联机时把 IP 填成 Host 局域网 IP，并在防火墙放行 UDP 27015。

> Host 端打敌人是「所见即所得」（本地直接读输入、零延迟）；客户端有 ~1 帧
> 上行延迟 + 每帧位置同步，手感差距是本次原型要肉眼观察的重点。

## 操作

| 按键 | 行为 |
|------|------|
| W / A / S / D | 移动 |
| 鼠标左键 | 开火（自动瞄准最近存活敌人） |
| X 或 Esc | 退出 |

## 架构速览（对应正式版设计）

```
Net（autoload）—— 连接 / 握手 / 房间事件 / 场景切换，零游戏状态
Lobby            —— 创建 / 加入 / 开始 / 列表 UI
Game             —— Host 权威世界：spawn 玩家·敌人·子弹；客户端只收广播 + 输入
Player/Enemy     —— Host 模拟逻辑；MultiplayerSynchronizer 同步 position/hp/alive
Bullet           —— Host 模拟；生成后无需再同步（由 despawn 广播清理）
```

| 机制 | 用法 |
|------|------|
| 实体生成/销毁 | `MultiplayerSpawner.spawn_function` + `spawn(data)`，两端同名执行 |
| 属性同步 | `SceneReplicationConfig` 方法式 API：position=ALWAYS，hp/alive=ON_CHANGE |
| 输入上行 | `@rpc` submit_input（unreliable，高频）+ fire_request（reliable，事件） |
| 加入快照 | `request_game_ready`（any_peer→host）+ `receive_snapshot`（host→client） |
| 系统消息 | `announce`（authority, call_local） |

## 冒烟测试

```powershell
godot --headless --script net_proto/tests/test_sync_config.gd
```

验证 4.6 的 `SceneReplicationConfig` 方法式 API 与 `spawn_function` 注册可用。

## 验收清单（本次原型验证目标）

- [ ] 双端进同一房间，互见对方彩色方块并实时移动（位置 ALWAYS 同步）
- [ ] Host 端僵尸独立生成/追击/攻击，客户端画面与 Host 一致（仅表现）
- [ ] 客户端可正常开火，子弹由 Host 判定命中并广播生成（客户端零模拟）
- [ ] 僵尸被打倒（alive=false）在两端同时消失；玩家倒地 3 秒复活同步
- [ ] 客户端中途加入：能拿到快照、已有实体照常显示（spawn_function 幂等）
- [ ] 客户端掉线：Host 自动删除其实体，无残留节点

## 已知边界（原型不处理，正式版再考虑）

- 无插值/预测/回滚（客户端看到的是 Host 每帧原始位置）
- 开火方向 = 自动瞄准最近敌人，不支持手动瞄准方向（正式版由鼠标世界坐标提供）
- ENet 丢包率未主动限制；本地测试看不出问题，公网需 `net/lag/max_packets` 调优
- 敌人移动无遮挡修正（穿墙），正式版用 NavigationAgent2D
- 无物理体（全用距离判定），正式版沿用主项目 Jolt + 图层

## 文件清单

```
net_proto/
├── project.godot               # 独立项目（autoload: Net；输入：WASD+左键）
├── script/
│   ├── lobby.gd                # 大厅 UI
│   ├── game.gd                 # 游戏根：spawn_function ×3 + 快照 RPC
│   ├── player.gd / enemy.gd / bullet.gd / hud.gd
│   └── net/net_connection.gd   # Net 单例（连接/握手/场景切换）
│   └── net/visuals.gd          # 方块贴图工具（纯表现）
├── scene/                      # lobby / game / hud
├── object/                     # player / enemy / bullet 预制体
└── tests/test_sync_config.gd   # 无头冒烟测试
```
