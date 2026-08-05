---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 当前状态 (2026-08-04)

核心战斗循环完整。导演系统 Phase 3 完成。**角色切换系统 + 菜单流程完成。**

### 导演系统 Phase 1–3 ✅ 完成

| 模块 | 文件 | 状态 |
|------|------|------|
| 总控 Autoload | `director.gd` | ✅ |
| 紧张度 | `intensity_tracker.gd` | ✅ |
| 节奏控制 | `pacing_controller.gd` | ✅ |
| 生成管理 | `spawn_manager.gd` | ✅ |
| 事件编排 | `event_manager.gd` | ✅ |
| 物品投放 | `item_manager.gd` | ✅ |
| 场景参数 | `director_config.gd` | ✅ |
| 生成点/区 | `spawn_point.gd` / `spawn_zone.gd` | ✅ |
| 安全门 | `safe_door.gd` | ✅ |
| 传送点 | `teleport_point.gd` | ✅ |
| 剧本事件 | `event_trigger.gd` | ✅ |

### 角色切换系统 ✅ 完成 (2026-08-04)

| 模块 | 文件 | 状态 |
|------|------|------|
| 角色数据扩展 | `character_data.gd` | ✅ 武器行走图字典 + 武器限制白名单 + 选择头像 |
| 战役数据 | `campaign_data.gd` + `campaign_assault.tres` | ✅ |
| 队伍系统 | `global.gd` | ✅ Array[Dictionary] 队伍 + 战役/难度状态 + checkpoint 序列化 |
| 切换管理器 | `character_switch_manager.gd` | ✅ Q 循环切换 + Ctrl+1/2/3 直选 + 队友静态精灵 + 死亡切换 |
| 队友站立精灵 | `teammate_standin.gd` + `teammate_standin.tscn` | ✅ |
| 武器拾取限制 | `weapon_pickup.gd` | ✅ can_use_weapon() 检查 |
| 存档扩展 | `save_manager.gd` | ✅ 队伍序列化 + 战役/难度字段 |
| Player 适配 | `player.gd` | ✅ 武器行走图查找 + refresh_after_switch() + 死亡切换 |
| 输入映射 | `project.godot` | ✅ 切换角色键(Q) + 选择队员1/2/3键(Ctrl+1/2/3) |

### 菜单流程 ✅ 完成 (2026-08-04)

| 界面 | 文件 | 状态 |
|------|------|------|
| 标题画面 | `title_screen.gd` | ✅ "开始游戏" → 战役选择 |
| 战役选择 | `campaign_select.gd` + `campaign_select.tscn` | ✅ RM2K3 窗口 + 列表 + 描述面板 |
| 角色选择 | `character_select_menu.gd` + `character_select.tscn` | ✅ 左面板角色列表 + 右面板队伍槽位 + 武器兼容显示 |
| 难度选择 | `difficulty_select.gd` + `difficulty_select.tscn` | ✅ 简单/普通/困难/专家 四选一 |
| GameInit | `game_init.gd` | ✅ 场景启动时自动创建 CharacterSwitchManager |
| HUD | `hud.gd` | ✅ 显示当前队员名/队伍索引 |

### 菜单流程

```
标题画面 → 战役选择 → 角色选择 → 难度选择 → 加载安全屋场景
  ↑          ↓           ↓           ↓
  └── 取消返回 ←── 取消返回 ←── 取消返回
```

### 角色切换要点

- **武器行走图**：CharacterData 新增 `weapon_walk_textures: Dictionary`（键=weapon_state_name，值=Texture2D），渲染时先查角色字典，回退 WeaponData.weapon_walk_texture
- **武器限制**：CharacterData 新增 `allowed_primary_weapons` / `allowed_secondary_weapons`（item_id 白名单），空=全部允许
- **切换操作**：Q 键循环切换（0.5s 冷却），Ctrl+1/2/3 直接选队员
- **队友精灵**：纯 Node2D+Sprite2D，挂在 DecorLayer 下，无敌无碰撞
- **死亡切换**：当前角色 HP=0 时优先切换到存活队员，全灭才走死亡流程

### 下一步

1. **Phase 4** — 特殊感染者 + Boss（Hunter/Smoker/Boomer/Tank/Witch）
2. **HUD 正式化** — 接入 `art/Ui/` 的血条素材替换调试手绘血条
3. **添加更多角色** — 创建 `character_*.tres`，配置专属武器行走图和武器限制

**Why:** 角色切换系统和完整菜单流程已完成。导演系统 Phase 3 可用。下一步需要特殊感染者逻辑来支撑导演系统的 Boss/Crescendo 事件类型。
