# net_proto — Godot 4.6 Host-authoritative ENet 原型

`net_proto/` 是与主项目隔离的最小联机实验项目。当前实现使用 Godot 4.6 的 ENet 高层多人 API，但不再依赖运行时创建的 `MultiplayerSpawner` / `MultiplayerSynchronizer`。

## 当前协议

- 连接与握手：ENet + `hello/hello_ack`，协议版本 `net_proto_v3_persistent_scene_ready`
- 场景切换：Host 通过 reliable RPC 广播 `start_game`
- 玩家、敌人和子弹的生成/销毁：Host 通过 reliable RPC 广播
- Client 输入：通过 `unreliable_ordered` RPC 上报方向和开火状态
- 移动、HP、倒地/复活、敌人 AI、子弹命中：仅 Host 模拟
- 高频状态同步：Host 每 0.05 秒发送只包含玩家和敌人位置、HP 等数据的 `unreliable_ordered` 快照
- 初次进入：Client 向常驻 `/root/Net` 发送 `report_game_scene_ready`，在收到完整世界快照前每 0.5 秒重试；Host 可在游戏场景尚未加载时暂存 ready，并在 `Game` 就绪后发送快照
- 子弹表现：Client 收到可靠生成消息后进行直线视觉外推，最终以 Host 的可靠销毁消息为准

高频快照不携带子弹列表，避免大量子弹使 unreliable 数据包超过 ENet MTU；子弹生命周期由 reliable spawn/despawn 保证，完整世界快照只用于新 Client 补齐当前世界。

采用显式 RPC/快照，是因为旧原型在 Godot 4.6.3 中动态配置 `SceneReplicationConfig` 时，`^position`、`^hp`、`^alive` 属性路径无法可靠解析，导致复制数据没有真正到达 Client。

## 手动运行

```powershell
# 窗口 1：Host
& "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe" --path net_proto

# 窗口 2：Client
& "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe" --path net_proto
```

Host 点击“创建房间”，Client 填写 `127.0.0.1` 并点击“加入”。握手后由 Host 点击“开始游戏”。跨机器测试需放行 UDP 27015。

| 输入 | 行为 |
|---|---|
| W / A / S / D | 上报移动输入，Host 模拟位置 |
| 鼠标左键 | 上报开火，Host 生成子弹并判定命中 |
| X / Esc | 退出 |

## 快速静态/资源检查

```powershell
& "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe" `
  --headless --path net_proto `
  --log-file "net_proto/.static_test_godot.log" `
  --script res://tests/test_sync_config.gd
```

该测试加载全部关键脚本、场景和实体预制体，实例化 `game.tscn`，核对 `Players` / `Enemies` / `Bullets` 节点，并确保旧复制节点没有回流。

## 本地双进程自测

```powershell
powershell -ExecutionPolicy Bypass -File net_proto/tests/run_local_smoke.ps1
```

也可指定 Godot：

```powershell
powershell -ExecutionPolicy Bypass -File net_proto/tests/run_local_smoke.ps1 `
  -Godot "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"
```

脚本最多等待 15 秒，并要求 Host 和 Client 分别打印：

- `[AUTO] host PASS`
- `[AUTO] client PASS`

自动测试覆盖：连接/握手、双玩家生成、Client 输入到 Host 权威移动、玩家位置与 HP 同步、敌人生成与销毁、子弹可靠生成与销毁，以及 Client 断开后的 Host 玩家清理。默认还会故意把 Host 切换游戏场景延迟 1.5 秒，验证 Client 即使先进入 `Game`，ready 也不会因 Host 仍在 Lobby 而丢失。

## 2026-08-19 局域网玩家生成卡住修复

真实双机局域网测试暴露了本机同步启动未覆盖的竞态：Client 可能比 Host 更早完成场景切换。旧版 Client 只向 `/root/Game` 发送一次 `game_ready`；若 Host 当时仍在 Lobby，Godot 会因为目标 RPC 节点尚不存在而丢弃调用，之后 Host 永远不会把该 Client 加入 ready 列表或发送玩家快照，HUD 因而一直停在“等待玩家实体生成”。

现在改为：

- ready 上报发送到场景切换期间一直存在的 Autoload `/root/Net`。
- `Net` 在 Host 的 `Game` 尚未生成时暂存 ready 请求。
- Host 的 `Game` 进入树后消费暂存请求并发送完整快照。
- Client 在确认自己的玩家已包含于完整快照之前，每 0.5 秒重发 ready。
- HUD 会显示 ready 重试次数，便于现场判断卡在“请求没到 Host”还是“快照没回来”。
- 协议版本升级为 `net_proto_v3_persistent_scene_ready`，两台电脑必须使用同一版文件。

## 2026-08-19 实际验证状态

已验证：

- Godot 4.6.3 可解析全部关键 GDScript。
- `lobby.tscn`、`game.tscn`、HUD、三个实体预制体均可加载。
- `game.tscn` 可实例化，容器节点名与 `game.gd` 一致。
- 玩家和敌人脚本只负责状态显示；子弹脚本在 Client 侧仅做视觉外推。命中、伤害和生命周期仍只由 Host 的 `game.gd` 模拟。
- 静态/资源冒烟测试：退出码 0，0 个失败。
- 本机双进程 ENet 冒烟测试通过，Host 和 Client 均输出 PASS。
- 延迟 Host 场景切换 1.5 秒的竞态回归测试通过：Client 连续重试 ready，Host 的常驻 Net 暂存请求，进入 Game 后成功生成 Client 玩家并回传快照。
- 已确认 Client 输入能驱动 Host 权威玩家移动，位置与 HP 快照能抵达 Client。
- 已确认敌人和子弹在 Client 生成，敌人/子弹按 Host 消息销毁，Client 退出后 Host 清理对应玩家。
- 已将高频快照与子弹生命周期拆分，复测时不再出现 unreliable 数据包超过 ENet MTU 的警告。

尚未人工/环境验证：

- GUI 双窗口的完整视觉效果和手感。
- 三台真实电脑的局域网连接已由用户验证通过：1 台 Host + 2 台 Client 均可进入并生成玩家实体。
- 3–4 名玩家同时联机。
- 高延迟、丢包和抖动环境。
- 长时间运行及大量实体压力。
- 断线重连、NAT 穿透与公网安全；这些能力当前尚未实现。

> 无头运行会打印 Windows 根证书存储读取警告；静态测试和双进程测试仍正常通过，该警告与本原型网络逻辑无关。

## 目录

```text
net_proto/
├── project.godot
├── scene/                 # lobby / game / hud
├── object/                # player / enemy / bullet
├── script/
│   ├── net/net_connection.gd
│   ├── lobby.gd
│   ├── game.gd
│   └── player.gd / enemy.gd / bullet.gd / hud.gd
└── tests/
    ├── test_sync_config.gd
    └── run_local_smoke.ps1
```

## 原型边界

- 无客户端预测、回滚和插值；子弹外推只用于视觉表现。
- 自动瞄准最近敌人，没有同步鼠标世界坐标。
- 无地图碰撞/导航，实体使用简单距离判定。
- 没有断线重连、房间发现、NAT 穿透和公网安全机制。