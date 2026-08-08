---
name: project-audit-2026-08-08
description: 全项目文档、结构与运行状态审阅记录
metadata:
  type: project
  reviewed: 2026-08-08
---

# 项目审阅记录（2026-08-08）

> 本文件仅记录审阅时观察到的项目现状，不新增或覆盖开发规则。若内容与 `CLAUDE.md` 冲突，以 `CLAUDE.md` 为准；若文档状态与实际实现冲突，以当前代码和可复现运行结果为准。

## 一句话结论

这是一个 Godot 4.6.3、Mobile 渲染器、1280×960 基准分辨率的俯视角 2D 像素风 L4D2 同人项目。核心单机战斗循环、数据驱动武器、基础敌人状态机、角色切换、菜单、Director Phase 1–3、HUD 与 VX 素材工具链已经形成；特殊感染者、完整 L4D2 生存流程和可验证的多人联机仍是主要缺口。

## 审阅范围

- 根目录指导与记忆：`CLAUDE.md`、`MEMORY.md`、`memory/project-status.md`、`memory/scene-conventions.md`、`.claude/settings.local.json`
- 项目说明与设计文档：根目录全部 Markdown（共 59 个，含插件、引擎参考和素材分析文档）及 README
- 代码/资源结构：GDScript、场景、`.tres` 数据资源、插件、地图和 Autoload 配置
- 运行检查：Godot 4.6.3 headless editor scan，插件初始化成功并正常卸载

## 实际项目结构

| 类别 | 数量/说明 |
|---|---|
| GDScript（含插件） | 85 个文件（核心 `script/` 约 79 个） |
| 场景 `.tscn` | 35 个（含地图、菜单、动画和测试场景） |
| 数据资源 `.tres` | 21 个，集中在 `object/` 与 `tres/` |
| PNG | 2272 张，主要是 VX/RPG Maker 图块、角色、动画和 UI 素材 |
| 音频 | 20 个 MP3、616 个 WAV |
| Markdown | 59 个；另有 TXT/RB/RPG Maker CHM 工具资料 |
| Godot 插件 | `addons/vx_tilemap`、`addons/vx_anim_editor`，均在 `project.godot` 启用 |
| Autoload | `Global`、`Director`、`Lobby`、`NetworkSyncManager` |

## 已形成的系统

1. **基础框架**：标题画面 → 战役选择 → 角色选择 → 难度选择 → 地图/安全屋；单例负责全局设置、存档/checkpoint、导演和网络入口。
2. **玩家与武器**：Player 状态机覆盖待机、行走、跑步、枪械、刀、攻击和装填；WeaponData/BulletData/CharacterData 资源驱动；支持主副武器槽、点射/连发、霰弹逐发装填、后摇动画、拾取替换和掉落。
3. **敌人**：基础感染者状态机（Idle/Discover/Chase/Attack/Knockback/Hitstun/Death/HeadshotDeath）、HurtArea 层 5、暴击/爆头、击退/硬直、子弹与近战去重；EnemyChaseState 使用共享地图缓存的四方向 A* 和实体障碍处理。
4. **Director**：Intensity 五因子、Build-up/Peak/Cooldown 节奏、散兵/尸潮生成、自然/剧本事件、物品投放、安全门和传送点。
5. **角色切换与 UI**：`Global.team` 保存队伍成员独立状态；Q/Ctrl+1/2/3 切换；队友站立精灵；战斗 HUD、快捷栏、伤害数字、渐变像素字体、设置和音频总线。
6. **素材/编辑器工具链**：VXAnimSprite（帧序列、每帧时长、多精灵、偏移、混合、跟随目标）与 VX Anim Editor；VXTileMap/VXGridEditor；A1/A4/RM2K3→VX Ace 图块转换资料。

## 重要的“文档状态”判断

- `README.md` 是最新的面向用户概览（2026-08-08 修改），但“联机同步已完成”的措辞应理解为代码框架/同步路径已写入，不等于经过多人实测的完成版。
- `联机系统架构设计.md` 标题仍是“待实现”，`联机系统实施计划.md` 是实施规划；因此多人功能的成熟度低于 README 的“已实现功能”表述，后续应补充实际测试状态（Host/Client、断线、权威校验、延迟）。
- `L4D2缺失功能清单.md`（最后更新 2026-07-30）比当前 README/代码旧，仍把部分已经存在的 Director、HUD、菜单/角色切换能力列为待实现或旧优先级，不能单独作为当前状态依据。
- `memory/project-status.md`（2026-08-04）明确下一步为 Director Phase 4：Hunter/Smoker/Boomer/Tank/Witch，以及正式 HUD 素材接入和更多角色。
- `CLAUDE.md` 是编码时的最高优先级项目规范：尤其是 Godot 4.6 lambda connect 写法、场景层级/寻路规则、碰撞层矩阵、像素字体整数倍渲染和 VXAnimSprite 约定。
- `engine-reference/` 实际含 `godot/`、`unity/`、`unreal/`、`rpgvxace-docs/` 等资料；Godot 参考包含 VERSION、breaking/deprecated/best-practices、modules 和 networking 原始文档。写 Godot 代码前应优先读 `engine-reference/godot/`。
- 运行入口存在两个层次：`project.godot` 的 `[run] main_scene` 为 `res://scene/title_screen.tscn`，应用配置的 `run/main_scene` UID 指向同一标题场景；`scene/main.tscn` 是旧/直接进入游戏地图式入口。README 中 `godot scene/main.tscn` 属于调试/绕过标题流程的启动方式。

## 当前主要缺口与风险

### 功能缺口

- 特殊感染者与 Boss（Hunter、Smoker、Boomer、Tank、Witch、Spitter、Jockey、Charger）尚未形成完整可玩逻辑。
- 倒地/救援、电击器复活、救援载具、完整安全门→推进→救援关卡循环尚未完成。
- 投掷品、近战推击、弹药堆交互、特殊弹药等仍是下一阶段内容。
- 多人网络虽然有 Lobby、RPC 和同步管理器，但需要真实 Host/Client 回归测试；当前不能把“代码存在”当成网络功能验收完成。
- `art/Ui/` 正式血条素材在规范中已有说明，但部分 HUD 仍可能使用调试绘制，需逐项核对。

### 维护风险

- 文档更新时间不一致（README 2026-08-08、开发日志 2026-08-06、状态记忆 2026-08-04、缺失清单 2026-07-30），功能状态容易互相矛盾。
- 地图场景体积差异很大，`突袭-第一关-街道.tscn` 约 664 KB；修改 TileMap/碰撞前要避免全文件机械重写。
- `未使用素材/`、大量原始图块和引擎资料占据仓库绝大多数体积；代码检索应排除 `.godot`、导入文件和未使用素材以降低噪声。
- 部分插件 README 仍描述旧的字符串动画调用方式，当前 CLAUDE/VX 文档推荐 PackedScene + Inspector 字段；以当前代码与 CLAUDE 为准。

## 建议的下一步顺序

1. 建立一份单一状态表，统一 README、`memory/project-status.md`、`L4D2缺失功能清单.md` 的日期和完成定义。
2. 先做多人联机最小验收：双实例 Host/Client、玩家生成、移动/攻击/敌人 HP、断线清理，并记录已知限制。
3. 实现 Director Phase 4 的 Hunter/Smoker/Boomer，再补 Tank/Witch；同时增加每个特殊感染者的独立场景和测试地图。
4. 接入正式 HUD 资源并验证 1280×960、整数缩放、中文像素字体显示。
5. 再实现倒地/救援与投掷品，最后扩展关卡路线、救援事件和动态音乐。

## 联机 Phase 0 执行状态（2026-08-08）

已开始执行独立方案文件 `联机系统改进方案-2026-08-08.md`：

- 战斗请求 RPC 已改为使用远程 sender ID，不再信任客户端传入的玩家 ID。
- 攻击、近战、装填请求增加武器校验与请求限频。
- Lobby ready 改为按 peer 去重，断线会移除 ready 状态；场景路径增加地图目录白名单。
- 尚未实施 MultiplayerSpawner、MultiplayerSynchronizer、Host 权威移动和完整远程库存同步。

本轮 Godot 4.6.3 项目扫描未发现 GDScript 解析错误。无头编辑器仍会报告已有的证书/编辑器设置写入、GradientLabel 编辑器上下文和资源退出清理警告，这些不是本轮联机改动引入的网络错误。

## 双屏测试反馈（2026-08-08）

用户实测结果：连接、大厅、玩家生成、移动、基础战斗和大部分同步正常；发现两个问题：

- Client 敌人死亡状态不同步
- Client 装填时备弹减少，但弹夹没有增加

已针对性修复：

- `sync_enemy_hp` 增加爆头标记，Client 使用 `_apply_network_death()` 进入尸体状态；如果死亡 RPC 早于敌人 puppet 生成，则暂存最多 2 秒，生成后补应用。
- Client 装填增加弹夹本地预测；Host 装填结果回传仍会校正弹夹，增加了目标 Player/同步值日志。

建议回归：分别测试普通死亡、爆头死亡、普通枪械 NORMAL 装填、霰弹枪逐发装填，并观察 Client 日志中的 `敌人死亡同步` 与 `Client 弹夹同步`。

## 可复现检查

```text
Godot Engine v4.6.3.stable.official.7d41c59c4
headless --editor --quit：通过
插件：VXTileMap、VXAnimEditor 均加载并卸载成功
```

## 双屏回归修复记录（2026-08-08）

用户反馈：弹夹同步已正常，但 Client 偶发有一名敌人未显示死亡；该敌人均处于循环攻击动画。Client 日志同时出现“敌人死亡同步”与“尸体注册”，表明死亡 RPC 已到达，问题在客户端表现层覆盖而非网络传输本身。

已修复：

- `script/enemy.gd` 的 `_process()`、`_process_puppet_attack_anim()` 和动画 Timer 回调增加 `_is_dead` 保护。
- `_apply_network_death()` / `_show_death_sprite()` 清除 puppet 攻击动画计时器、序号和上一次同步状态，并将 `synced_state` 置为 `Death`。
- Client puppet 死亡后不会再被批量 `Attack` 状态重新触发循环攻击动画。
- `script/network_sync_manager.gd` 在 puppet 生成后立即应用暂存 HP/死亡结果；死亡结果暂存时间延长为 30 秒，普通 HP 更新为 5 秒 TTL，避免分批生成时死亡事件先到导致丢失。

验证：Godot 4.6.3 headless 项目检查通过（退出码 0）；输出中的证书、GradientLabel 编辑器上下文和编辑器设置写入错误为环境/既有警告，与本次 GDScript 修改无关。
