---
name: project-status
description: Current project implementation status and what's been built so far
metadata:
  type: project
---

## 设计方向（2026-09-02 定稿）⚠️ 后续开发以本节为准

整体方向已定为 **L3D 混合路线**，总纲见根目录 `游戏设计方向-L3D混合.md`（与其他文档冲突时以总纲为准）：

- **战斗核心**：见切（0.3s 完美回避）→ 反击（超 Push）→ 背刺即死（双方朝向一致时秒杀，Boss 1.5 倍伤）+ Guts 保底；属性系统与武器削损**后置不做**。
- **敌人**：L3D 阵容 —— 丧尸+Crimson Head（第一章 Rush 主体）、Hunter 系、女巫、Tyrant；L4D2 的 Smoker/Boomer/Spitter/Jockey/Charger 不做。
- **角色**：先做 3~4 人差异化（のび太见切特化 / ジャイアン攻击手 / スネ夫后勤 / 静香辅助+一闪反击），复用现有 SkillData 搓招框架；觉醒/双持不做。
- **当前焦点**：第一章 = 市街地+学校 5 图贯通（学校双图需补碰撞/刷怪区/安全门并登记 campaign），里程碑 M0~M6 见总纲 §6。M0（git 止血）与 M1（还原管线补碰撞/通行性）为前置。

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

### 下一步（2026-09-02 更新）

1. **M0 工程止血** — git 提交收敛（1639 删除+26 修改+21 未跟踪自 9/1 悬空）、大二进制 `git rm --cached`、分支归一到 main
2. **M1 还原管线补碰撞/通行性** — 地形 ID→TileSet physics 做成管线标准步骤，街道图验证寻路
3. **M2 战斗核心三件套** — 见切/反击 + 背刺即死 + Guts（与 M1 可并行，test 图验证）
4. **M3 Crimson Head + 单发型 Rush**、M4 角色差异化、M5 第一章贯通、M6 双人验收 —— 详见总纲 §6

**Why:** 原"Phase 4 特殊感染者（Hunter/Smoker/Boomer/Tank/Witch）"路线已被 L3D 阵容方案替代；角色"添加更多角色"目标改为差异化现有角色而非单纯新增。

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
---

## 主项目联机最新状态（2026-08-27）

> 本节覆盖上文 2026-08-04 / 2026-08-20 的阶段性描述；`net_proto/` 仍是独立原型，但其显式 RPC/快照方案已经移植到主项目。

### 已完成的局域网合作主干

- **Host 权威**：Client 仅上报输入和交互意图；Host 结算玩家移动、武器/弹药、近战推击、投掷物、敌人 AI、子弹、伤害、掉落物和安全门/章节确认。
- **连接与大厅**：`Net`（`script/network_manager.gd`）管理 ENet、`hello → hello_ack` 握手、玩家名单、角色选择、断开与跨场景会话；`network_lobby.gd` 提供创建/加入/开始游戏。
- **显式同步**：结构性事件使用 reliable RPC；玩家/敌人高频位置快照使用 `unreliable_ordered`。不使用 `MultiplayerSpawner`、`MultiplayerSynchronizer` 或动态 `SceneReplicationConfig`。
- **跨图与实体**：场景 ready/flush 协议避免切图时 RPC 丢失；`PlayerState` 与 `Players` 提供座位与玩家实体注册，`NetworkWorld` 只管理当前场景实体。
- **共享拾取**：武器、治疗品和投掷物均由 Host 校验距离、归属、槽位和库存后提交。2026-08-27 已修复 Client 无法请求拾取投掷物的问题，并完成双端自动回归。
- **自动测试**：无头 Host/Client 测试已覆盖握手、角色选择、移动、战斗/敌人、掉落物、投掷物拾取、安全门与断开等回归入口。

### 当前限制与下一阶段

1. 验证双人首关完整通关：多人倒地/救援、团灭恢复、Host 存档、章节流程和长时间稳定性。
2. 扩展到 3–4 人、复杂尸潮与特感场景，并在高延迟/丢包下调优同步表现。
3. 最后再实现房间发现、断线重连、UPnP/NAT 穿透与公网安全；主机迁移不作为当前局域网版本前置条件。

### 本轮维护记录

- 核心联机与单人脚本已补充中文职责/边界注释，便于区分单人、Host 和 Client 的执行路径。
- 验证：Godot 4.6.3 无头编辑器扫描退出码为 `0`；已有 UI 渲染/证书类警告属于项目既有噪声，未发现本轮脚本解析错误。

---

## 联机倒地/救援/团灭（2026-08-28）✅ 已落地

- **语义**：联机 HP=0 → 倒地（躺地 + 60px/s 爬行 + 流血池 100@5/s ≈ 20s + 头顶救援进度环）→ 队友按住确定键 3s 救起（30% HP）或流血耗尽转真死亡。全员非站立 → Host 黑屏 2s+1s 后重载本章，会话满血重置；真死亡玩家在下一章开头满血归队（消除安全门软锁）。单人规则不变。
- **状态承载**：倒地/死亡是场景运行时状态（NetworkWorld entry：`downed`/`dead`/`downed_hp`），不进 PlayerState、不进存档；玩家快照尾部追加 `downed`/`bleed_ratio`/`revive_progress`，对旧 21 字段包向后兼容。
- **关键文件**：`script/network_world.gd`（倒地推进/救援校验/团灭检测/输入三态闸门 `_get_local_player_life_state`）、`script/player.gd`（`network_downed` / `set_network_downed`）、`script/network_revive_indicator.gd`（新）、`script/enemy.gd`（`_is_player_body` 跳过 HP≤0）。
- **验证**：`--net-test-features`（街道图，双向倒地救援 + 快照标记 + 倒地碰撞断言）与新增 `--net-test=downed-wipe`（test 图，倒地→流血→团灭→重载→恢复验证）双端回归全绿；无头扫描退出码 0；单人安全屋冒烟 600 帧退出码 0。
- **已知边界**：死亡观战镜头、二次倒地加速流血、电击器复活、HUD 流血/救援进度显示待做。详见 `倒地救援与团灭实施方案.md`。

---

## 联机表现同步修复 + 内网穿透（2026-08-29）✅ 已落地

- **远端表现**：`script/network_snapshot_interp.gd` 快照插值缓冲取代指数平滑（玩家 50ms / 敌人 60ms 渲染延迟，样本间线性插值，不外推）——修"主机玩家移动像有摩擦力"。
- **可靠重同步软并流**：每 2 秒的 `world_snapshot(snap=true)` 对已跟踪实体不再硬切位置/重置行走动画（玩家走 `apply_network_resync_state`，敌人按 `snap and not established`），偏差 >96px 才硬校准——修客户端全体实体周期性顿挫与踏步动画频率不一致。
- **客户端本地预测**：`network_local_prediction` 已启用（此前恒 false）；本地输入当帧驱动移动/朝向，快照经 `apply_network_authority_target(pos, facing)` 纠偏（移动中偏差 >16px 才 480px/s 纠偏，停止后 720px/s 收敛；静止未锁定时回填权威朝向）——修自己角色一顿一顿与输入 RTT 延迟。
- **丧尸不围尸**：`enemy.gd::has_valid_player_target()` 复核目标存活（HP>0 且非躺地），目标倒地/死亡即清引用回 Idle → 视野轮询改找附近存活玩家，没有则待机；`_try_find_player` 场景树兜底同样只认存活玩家。
- **敌人死亡可靠广播**：Host `_announce_host_enemy_deaths()` 每帧用 `enemy_death_presentation` 广播新死亡（紧凑快照跳过尸体），Client 立即切尸体/爆头表现 + 音效；迟到"存活"不可靠包对尸体丢弃。`--net-test-enemies` 新增 `AUTO_ENEMY_CLIENT_DEATH_COMPLETE` 断言。
- **头顶名牌**：`script/player_nameplate.gd`（1P/2P 座位编号 + 昵称 + ＨＰバー/ＨＰメーター 血条），`NetworkWorld._attach_player_nameplate` 三条注册路径挂载，座位重排自动刷新；已运行时截图验证。
- **初始武器**：`CharacterData.initial_weapon`（默认手枪 `weapon_pistol.tres`），`PlayerState.init_from_character` 统一发放满弹匣——单机/联机共用入口。
- **UPnP 端口映射**：Host 建房后工作线程 `UPNP.discover → add_port_mapping(UDP)`，`upnp_port_mapped`/`upnp_mapping_failed` 信号回大厅展示公网地址或提示 frp 等穿透；大厅新增 `%UpnpCheck` 开关；`leave()` 异步删映射，`Net.active_port` 显示真实端口。
- **验证**：`--net-test-features`、`--net-test-enemies`、`--net-test=downed-wipe` 双端回归全绿；`--net-test-weapon=smg_01` 开火/切刀链路通过；无头整项目解析 0 错误。已知噪声：团灭测试协程换图瞬间的 `get_tree()` 空引用打印（既有竞态）；`--net-test-weapon=smg_01` 近战子断言可能因僵尸先被子弹打死而不触发。
- **运维注意**：清理无头测试进程勿用 `taskkill /IM Godot_v4.6.3-stable_win64.exe`（编辑器同名会被误杀），按 PID 或等后台任务自退出。
