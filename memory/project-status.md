---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 当前状态 (2026-08-05)

核心战斗循环完整。导演系统 Phase 3 完成。角色切换系统 + 菜单流程完成。**多人联机系统 Phase 1–3a 完成，Phase 3b 部分完成。**

### 联机系统进度

| Phase | 内容 | 状态 |
|-------|------|------|
| Phase 1 | 输入抽象层 (PlayerInput / LocalPlayerInput) | ✅ |
| Phase 2 | 网络基础设施 (NetworkManager / Lobby / LAN广播) | ✅ |
| Phase 3a | 玩家位置同步 (RPC 30Hz) | ✅ |
| Phase 3b | 敌人 + 武器掉落物 + 玩家状态同步 | ⚠️ 部分完成 |

### Phase 3b 已知问题

| 问题 | 严重程度 | 原因 |
|------|---------|------|
| 敌人 AI 双方都在跑，位置冲突回弹 | **高** | Client 端 StateMachine 没完全禁用，或 Host 同步位置与 Client 本地 AI 位置冲突 |
| Client 打不死敌人 | **高** | 伤害只在本地计算，没有通过 RPC 传给 Host 判定 |
| 敌人死亡状态不同步 | **高** | 死亡/尸体没有跨 peer 同步 |
| Client 捡武器失败 | **中** | 移除 Host-only 后各自捡，但 Global 状态没跨 peer 同步 |
| 敌人位置 lerp 不平滑 | **低** | 10Hz + lerp(0.3) 不够，需要更高频率或更平滑的插值 |

### 下一步 (Phase 3b 修复 + Phase 4)

1. **修复敌人同步** — 完全禁用 Client AI，Host 权威运行 + 同步位置/HP/死亡状态
2. **修复伤害同步** — Client 攻击 → RPC 通知 Host → Host 计算伤害 → 广播 HP 变化
3. **修复死亡同步** — 敌人死亡 → Host 广播 → Client 切换死亡精灵/禁用碰撞
4. **武器掉落物完整同步** — Client 捡武器 → RPC → Host 验证 → 广播结果
5. **Phase 4** — 物品/交互/安全门同步

### 联机架构

```
Host (权威)                          Client
┌──────────────┐                    ┌──────────────┐
│ Player (本地) │                    │ Player (本地) │
│ Enemy AI      │──RPC广播────────→│ Enemy (静态)  │
│ Pickup 处理   │                    │ Pickup (同步) │
│ 伤害判定      │                    │ 特效播放      │
└──────────────┘                    └──────────────┘
```

### 核心文件（联机相关）

| 文件 | 用途 |
|------|------|
| `script/network_manager.gd` | Autoload — 连接管理 + 所有联机 RPC |
| `script/network_spawner.gd` | 玩家生成 + 接收 player_state RPC |
| `script/network_enemy_syncer.gd` | 敌人状态广播/接收 |
| `script/network_pickup_syncer.gd` | 武器掉落物移除同步 |
| `script/network_player.gd` | 远程玩家视觉节点 |
| `script/player_input.gd` | 输入抽象层 (PlayerInput) |
| `script/player/local_player_input.gd` | 本地输入 (LocalPlayerInput) |
| `script/lobby.gd` + `scene/lobby.tscn` | 联机大厅 |
| `addons/LANServerBroadcast/` | LAN 游戏广播 (已适配 4.6) |
| `LANServerBroadcast插件说明.md` | 插件迁移记录 |
