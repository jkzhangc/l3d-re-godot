---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 当前状态 (2026-07-28)

核心战斗循环已基本完整。已实现：玩家状态机(idle/walk/run/pistol/knife/shotgun/rifle + 攻击 + 装填)、武器系统(远程弹夹+霰弹逐发装填+近战判定+BulletData多子弹)、敌人AI状态机(Idle→Discover→Chase→Attack→Knockback→Death/HeadshotDeath)、**受击碰撞体系统**(HurtArea层5)、**子弹发射者排除+目标去重+尸体穿透**、战斗HUD(HP血条+5槽快捷栏)、菜单系统(物品/装备双面板)、武器拾取物(接触拾取/长按替换/掉落保留外观+弹药+踏步动画)、死亡系统(黑屏+自动重载)、存档系统(JSON)、相机跟随+地图边界、标题画面(RM2K3风格)、文字渐变渲染、VXAnimSprite动画特效

### 本次更新 (2026-07-28)

- **受击碰撞体 (HurtArea)**：玩家和敌人各自动创建 Area2D + RectangleShape2D，位于碰撞层5(bit 16)。攻击检测统一经此碰撞体。TAB黄色绘制。
- **碰撞层重组**：层1=墙壁, 层3=玩家物理体, 层4=敌人物理体, 层5=受击碰撞体。子弹/近战 mask=24(层4+5)。
- **子弹去重**：`_hit_targets: Array[int]` 按 instance_id 去重，防物理体+受击碰撞体双重触发。
- **发射者排除**：子弹记录 `_shooter` 引用，防击中自己（mask=24会检测到玩家HurtArea）。
- **尸体穿透**：子弹 `_hit()` 检查 `_is_dead`/`_is_dying`，尸体不消耗穿透、不播特效。近战 `_is_target_dead()` 同理。敌人攻击跳过已死亡目标。
- **武器掉落图像修复**：WeaponData.pickup_texture 为空时回退到 weapon_walk_texture + 举起序列首帧 char_idx + 面朝下。
- **武器掉落踏步动画**：WeaponData 新增 `pickup_step_frames`/`pickup_step_duration`/`pickup_animated` 字段，掉落武器可独立配置地面动画。

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
