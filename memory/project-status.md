---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 当前状态 (2026-07-29)

核心战斗循环已基本完整。已实现：玩家状态机(idle/walk/run/pistol/knife/shotgun/rifle + 攻击 + 装填)、武器系统(手枪/小刀/霰弹枪/步枪/冲锋枪 — 远程弹夹+霰弹逐发装填+近战判定+BulletData多子弹+FireMode TAP/HOLD)、敌人AI状态机(Idle→Discover→Chase(**墙跟随寻路**)→Attack→Knockback/→Hitstun→Death/HeadshotDeath)、**受击碰撞体系统**(HurtArea层5)、**子弹发射者排除+目标去重+尸体穿透**、**子弹水平帧条动画**(Barrages图片)、战斗HUD(HP血条+5槽快捷栏)、菜单系统(物品/装备双面板)、武器拾取物(接触拾取/长按替换/掉落保留外观+弹药+踏步动画)、死亡系统(黑屏+自动重载)、存档系统(JSON)、相机跟随+地图边界、标题画面(RM2K3风格)、文字渐变渲染、VXAnimSprite动画特效

### 本次更新 (2026-07-29)

- **敌人 A* 寻路**：`EnemyChaseState` — TileMapLayer 格子数据构建可通行网格(32×32)，A* 八方向搜索+共线平滑+推离墙壁(WALL_PUSH 14px)，路径点追踪+剩余速度滑墙。降级模式(连续失败3次→直接追击防卡顿)，失败退避(3s冷却+48px移动阈值)。地图缓存 static 全敌人共享，entity障碍检测(其他敌人+多人玩家接口 `extra_obstacle_nodes`)。无路径超过5次→停止移动等待。
- **步枪/冲锋枪实装**：`weapon_rifle.tres`(攻击力30, HOLD连发, 30发弹夹, ammo_rifle) + `weapon_smg.tres`(攻击力20, HOLD连发, 30发弹夹, ammo_smg, 硬直0.1s)。两者共用 Rifle 状态(复用 PlayerPistolState/PlayerPistolAttackState)。

### 关键文件

| 文件 | 用途 |
|------|------|
| `CLAUDE.md` | 项目主文档（碰撞层系统、受击碰撞体、子弹实体、武器拾取物） |
| `游戏系统架构文档.md` | 完整系统架构（含受击碰撞体、敌人AI、死亡系统） |
| `攻击系统参考.md` | 武器/子弹/近战/消耗品/受击碰撞体/尸体穿透 |
| `L4D2缺失功能清单.md` | 功能缺口 + 优先实现列表 |
| `L4D2特色机制参考.md` | L4D2原版机制参考 |

### 其他

- **击退系统已恢复**：BulletData.knockback_enabled/knockback_force/knockback_stun_duration → EnemyKnockbackState（子弹驱动击退）
- **VXAnimSprite**：2026-07-26 修复 _sprites 数组共享 + 多精灵帧索引 + 混合模式，详见 CLAUDE.md
- **VXTileMap 插件** (`addons/vx_tilemap/`)：实验性，简化格式可用，标准格式待校准
- **场景入口**：`scene/main.tscn`
- AGENTS.md 已过时——忽略，使用 CLAUDE.md。
