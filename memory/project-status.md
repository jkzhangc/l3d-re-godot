---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## net_proto/ — 独立联机原型项目

`net_proto/` 是一个**完全独立的 Godot 项目**（有自己的 `project.godot`），用于验证联机架构的可行性。做单机内容时**忽略该目录**，不要修改其中的文件，也不要将其内容纳入单机功能的考量范围。

## 开发环境

- **Godot 可执行文件**：`D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe`（不在 PATH，命令行需全路径）
- **无头验证**：`& "D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe" --headless --path <项目目录> --quit`

## 联机开发（2026-08-04 启动）

- **架构决策**：v2 = **Host 全量模拟 + 客户端纯渲染**（5 条铁律，详见 `联机系统架构设计.md`）。v1 混合权威已被否决。
- **独立原型**：`net_proto/` —— 最小垂直切片（大厅→连接→玩家生成→输入同步→子弹→敌人→快照→掉线），**全部验证通过后才允许移植主项目**。

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

### 已知待优化

- **菜单 UI 优化** — 标题画面/战役选择/角色选择/难度选择界面目前功能可用，但视觉效果简陋，后续需整体美化（窗口排版、字体渲染、过渡动画等）

### 武器近战推击 ✅ 完成 (2026-08-10)

| 模块 | 文件 | 状态 |
|------|------|------|
| 输入映射 | `project.godot` | ✅ `推击键` → S 键 (physical_keycode=83) |
| 推击数据 | `weapon_data.gd` | ✅ shove_char_sequence / shove_frame_duration / shove_range / shove_knockback / shove_sound 等字段 |
| 角色推击图 | `character_data.gd` | ✅ `shove_walk_texture` 泛用图 + `shove_walk_textures` 字典（按武器状态名映射） |
| 推击状态 | `script/player/PlayerShoveState.gd` | ✅ 帧序列动画 + 判定区域 + 0 伤害纯击退 + 推击专用音效 |
| 推击触发 | `PlayerPistolState.gd` / `PlayerKnifeState.gd` | ✅ READY 阶段 S 键 → Shove |
| 场景注册 | `object/player.tscn` | ✅ Shove 状态节点 |
| 推击纹理 | `player.gd` | ✅ enter_shove_mode / exit_shove_mode + 纹理优先级（角色字典→角色通用→武器专用→回退） |
| 受击反馈 | `enemy.gd` + `player.gd` | ✅ `hit_feedback_mode` + `hit_feedback_duration` @export + `_play_hit_feedback()` |
| 0 伤害抑制 | `enemy.gd` | ✅ take_damage 0 伤害不弹数字/不播音效 |

**推击纹理优先级**：`character.get_shove_walk_texture(state_name)` → 字典查 `shove_walk_textures` → 回退 `shove_walk_texture` → `_wd.shove_walk_texture` → 普通 `weapon_walk_texture`

**受击反馈**：damage>0 闪红、damage=0（推击）闪亮白（modulate 3,3,3）。模式 0=闪（瞬间变色→渐变恢复），模式 1=渐隐（变色→渐渐消失）。时长默认 0.5s，敌我各自 @export 可配。

**默认参数**：击退力度=400px/s、击退时长=5.0s、判定矩形=48×32、前方偏移=24px

### 下一步

1. **Phase 4** — 特殊感染者 + Boss（Hunter/Smoker/Boomer/Tank/Witch）
2. **HUD 正式化** — 接入 `art/Ui/` 的血条素材替换调试手绘血条
3. **添加更多角色** — 创建 `character_*.tres`，配置专属武器行走图和武器限制

**Why:** 角色切换系统和完整菜单流程已完成。导演系统 Phase 3 可用。下一步需要特殊感染者逻辑来支撑导演系统的 Boss/Crescendo 事件类型。

## 多人联机 Phase 1（2026-08-20）✅ 完成核心闭环

- 架构：Host 全权威模拟；Client 仅上传输入、接收并插值快照。
- 新增：`script/network_manager.gd`、`script/network_lobby.gd`、`script/network_world.gd`、`scene/network_lobby.tscn`。
- 接入：标题菜单新增“联机游戏”，`Net` 与 `Players` 注册为 Autoload。
- 联机流程：Host 建房 → Client 加入 → 协议握手 → 开始游戏 → 双端切换安全屋地图 → Host 权威移动 → Client 输入上传与插值 → Client 离开 → Host Despawn。
- RPC 约定：输入与移动快照使用 `unreliable_ordered`；握手、场景切换、Spawn/Despawn、初始 World Snapshot 使用 `reliable`。
- 明确未使用：`MultiplayerSpawner`、`MultiplayerSynchronizer`、`SceneReplicationConfig`。
- 单机保护：在线会话跳过存档加载、Checkpoint、角色切换管理器、A* 预构建和 Director gameplay 入口。
- 验证：Godot 4.6.3 无头扫描通过；双端本地烟测通过，Client exit code=0；`git diff --check` 通过。
- 已知噪声：headless Dummy 渲染器会触发 `TextGradientRenderer` 空纹理错误，属于既有 UI 渲染问题，不影响联机闭环。
