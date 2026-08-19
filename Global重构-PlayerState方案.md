# Global → PlayerState 重构方案与进度

> **状态**：S1 ✅ / S2 ✅ / S3 ✅ / S4 ✅ / S5 ✅ 已完成并实测通过 · S6 待做
> **最后更新**：2026-08-19
> 本文是这轮重构的唯一执行依据。联机总体设计见 `联机系统架构设计.md`（v2 仍有效，仅 §8 原型章节作废）。

---

## 1. 背景：为什么做这件事

起因是「联机系统现在加合不合适」。结论：**现在不合适，但拦路的不是网络代码，而是 `Global` 单例。**

- 8/6 的联机回退非常干净：74 个 `.gd` / 14526 行里 grep `@rpc|multiplayer|peer|is_server()` **0 命中**
- 但 `script/global.gd` 的 per-player 字段（`player_hp` / `player_tp` / `equipment` / `weapon_magazines` / `active_weapon_slot` / `healing_item(_count)` / `support_item` / `throwable` / `inventory` / `player_character`）**结构上只装得下 1 个玩家**
- 上一轮联机之所以长出 10 参数 RPC、傀儡节点、外观字段逐个广播，根因就是「远程玩家没法拥有 Global」，只能靠 RPC 绕过。不解决单例，换成 `MultiplayerSynchronizer` 也会长回同样的形状
- **单人模式直接受益**：旧的 `_apply_team_member_to_global()` / `_save_global_to_team_member()` 是「顶层单值 ↔ team[idx] 手工双向拷贝」，逐字段复制粘贴、容易漏项，08-12 那三个角色切换 bug 全部出自这里

对应 `联机系统架构设计.md` §9.1 的 P0 改造项 **#1（Global 单例重构）+ #3（玩家注册表）**。

## 2. 范围与边界

**本轮是纯单人重构，不写任何网络代码。** 遵守 `联机系统架构设计.md` §9.5 的启动门槛 —— 已核实门槛项均未完成：

| 门槛项 | 状态 |
|--------|------|
| 特殊感染者（Hunter/Smoker/Boomer/Tank/Witch） | ❌ 未实现（只有一个通用 `object/enemy.tscn`） |
| 导演 AI Phase 4 | ❌ 未完成 |
| 倒地/救援机制 | ❌ 未实现（8/6 随回退废弃） |
| 完整关卡流程可通关 | ❌ 未完成 |

重构按 Host 权威模型预留数据形状，但不引入 `MultiplayerSynchronizer` / RPC / 大厅 / peer 的实际代码。

## 3. 已锁定的设计决策

| 决策 | 结论 | 依据 |
|------|------|------|
| 联机队伍语义 | **1 人 = 1 角色**；`team` 将来降级为座位表（每座位带 `owner_peer_id`）；联机下屏蔽切换 | 还原 L4D2；PlayerState 映射最干净；避免 12 角色在场 |
| 单人模式 | **保留现有轮换切换**（Q / Ctrl+1-N） | 不破坏已有单人体验 |
| 队伍上限 | **3 → 4 人** | L4D2 标准 |
| 移动权威模型 | **Host 全量模拟**：客户端只上报输入 + 渲染 | `联机系统架构设计.md` §1-3。v1 的混合权威（客户端权威移动 + Host 权威战斗）**已实测失败**：主机开枪客户端看不见子弹、位置漂移瞬移、伤害对不上。根因是同一实体被两端同时模拟 |
| 本轮范围 | Global→PlayerState + 玩家注册表统一 | §9.1 P0 #1 + #3 |

> ⚠️ 曾一度考虑「移动客户端权威 + 战斗 Host 权威」，那与本仓库基于实跑失败得出的 v2 结论冲突，**已否决**。

`net_proto/`（独立 Godot 联机原型项目）**已废弃**，本轮忽略。

## 4. 架构

### PlayerState（`script/player_state.gd`）— `RefCounted`

- 不用 `Resource`：会引入资源缓存/共享语义（正是旧读档 bug 的成因）
- 不用 `Node`：单人 4 座位里只有 1 个有实体节点，另外 3 个是纯数据
- 将来联机：Host 权威下 PlayerState 只在 Host 侧写；客户端 HUD 要的队友 HP 由玩家实体节点的代理属性暴露给 `MultiplayerSynchronizer`（v2 文档 §6.1 Layer 2）

字段：`character` / `character_path` / `current_hp` / `current_tp` / `equipment` / `active_weapon_slot` / `weapon_magazines` / `healing_item(_count)` / `support_item` / `throwable` / `inventory` / `facing` / `position` / `shove_fatigue_count` / `shove_cooldown_timer` / `shove_idle_timer` / `tp_regen_timer` / `seat_index` / `owner_peer_id`

方法：装备（`get_active_weapon` / `get_equipped_weapon` / `equip_weapon_in_slot` / `unequip_slot` / `switch_to_slot` / `get_active_weapon_state_name`）、消耗品（`use_healing_item` / `use_support_item` / `pickup_consumable`）、弹药（`get/set_magazine_ammo` / `count/consume_ammo_item`）、背包（`add_item` / `remove_item`）、`is_alive` / `get_max_hp` / `get_max_tp` / `init_from_character` / `clone` / `to_dict` / `from_dict` / `describe`

**两个必须记住的坑**：
1. `character_path` 必须单独存 —— 座位上的 `CharacterData` 是 `duplicate()` 出来的，而 `Resource.duplicate()` 会**清空 `resource_path`**，光靠 `character` 本身存不出路径
2. `use_healing_item()` / `use_support_item()` 改为**返回被消耗的 ItemData**，效果由调用方施加（原实现内部找玩家节点，是单例假设）

### PlayerRegistry（`script/player_registry.gd`）— autoload `Players`

放新 autoload 而不是塞进 Global（Global 已 650 行且职责过载；注册表恰恰是「绝不能有单玩家味道」的那一层）。

- **座位层**：`seats` / `active_seat_index` / `seats_authored` / `seat_count` / `get_seat` / `get_active_state` / `set_active_seat` / `next_living_seat` / `living_seat_count` / `clear_seats` / `add_seat`
- **实体层**：`register_entity` / `unregister_entity` / `get_local_entity` / `get_entity_for_seat` / `all_entities` / `nearest_entity_to`

**关键契约**：
- `get_active_state()` **保证非 null** —— 座位表为空时懒创建座位 0（のび太）。安全屋户外地图是单角色回退模式，依赖这个兜底。这同时**统一了 `init_new_game()` 原来那两条分岔的初始化路径**
- `seats_authored` 表示座位表是否由「菜单/存档/checkpoint」正式填充过。`try_load_or_init()` 必须用它判断，**不能用 `seat_count()==0`** —— 因为其他游戏流程调用 `Players.get_active_state()` 时仍可能触发懒创建

### ItemCodec（`script/item_codec.gd`）— 打断循环依赖

`PlayerState` 要序列化物品、`SaveManager` 要创建 `PlayerState`，互相引用会让 GDScript 编译失败，而且报的是**误导性的 `Identifier not found: Players`（连 autoload 名都认不出）**。把物品编解码抽到不依赖任何一方的 `ItemCodec`，处在依赖链最底层。

依赖方向：`ItemCodec` ← `PlayerState` ← `SaveManager`

### Global 兼容策略：迁移期加 shim，S5 后删除

per-player 字段改为**转发属性**，方法改为**转发调用**，指向 `Players.get_active_state()`。

为什么可行：
- getter 返回的是 PlayerState 里那个 Dictionary/Array 的**同一引用**，所以 `Global.equipment[slot] = wd` / `Global.inventory.append(x)` 这类原地修改语义不变
- 只有 `=` 整体赋值走 setter，也正确
- 59 处调用点**一行都不用改**就能跑起来 → 第一步就能全流程验证

`team` 不做 shim，**一次性替换**为 `Players.seats`（`Global.team[i]["position"] = ...` 这种下标写法没法代理）。其余 per-player shim 仅在调用侧迁移期间保留，已于 S5 删除。

切换语义的变化：
```
旧：_save_global_to_team_member(old) → set_active_team_index(new) → 11 个字段来回拷
新：Players.set_active_seat(new) → player.refresh_after_switch()
```

---

## 5. 进度

### ✅ S1 · 骨架落地（已完成）

- 新建 `script/player_state.gd`、`script/player_registry.gd`
- `project.godot` 注册 `Players` autoload（排在 `Global` 之后）
- 验证：`project_run` 无报错，`game_eval` 确认 `get_active_state()` 懒创建座位 0 正常、group 兜底扫描能找到实体

### ✅ S2 · 数据层切换（已完成并实测通过）

改动文件：

| 文件 | 改动 |
|------|------|
| `script/global.gd` | 迁移期以 per-player 转发 shim 过渡；删除 `_apply_team_member_to_global` / `_save_global_to_team_member` / `get_current_team_member` / `set_active_team_index` / `_find_player_node`；`get_team_size()` 保留为队伍级兼容入口；checkpoint 改存 `seats`（`PlayerState.clone()`），消除旧的「顶层单值 + team 数组」重复；`init_new_game()` / `try_load_or_init()` 统一初始化路径。S5 已删除全部 per-player shim。 |
| `script/save_manager.gd` | 重写为 seats 序列化 + `save_version: 2`；保留 v1 旧存档读取（`_load_legacy`）；物品编解码移出到 `ItemCodec` |
| `script/item_codec.gd` | **新建** —— 打断 PlayerState ↔ SaveManager 循环依赖 |
| `script/character_select_menu.gd` | `_confirm_team()` 构造 `PlayerState` 而非 Dictionary |
| `script/character_switch_manager.gd` | 切换改为换绑座位；standin 外观读 `PlayerState`；`_find_next_living_member()` → `Players.next_living_seat()` |
| `script/player.gd` | 删掉冗余的「同步到队伍成员数据」（`Global.player_hp = current_hp` 现在直接写座位）；`_try_switch_on_death()` 改写座位 HP |

**实测验证结果**（MCP `project_run` + `game_eval`）：

| 项 | 结果 |
|----|------|
| 单角色回退模式（安全屋，座位表为空） | ✅ 懒创建座位 0，游戏日志干净 |
| `to_dict()`/`from_dict()` 内存往返 | ✅ 角色/HP/TP/治疗品/辅助品/投掷物/背包/装备/弹夹/朝向/位置全部还原；`duplicate()` 出来的弹药（无 resource_path）走手工重建成功 |
| 磁盘存档 v2 往返 | ✅ 存盘 → 清空座位 → 读档，HP=88 / TP=12 / 手雷 / 弹夹全部还原 |
| 双座位切换 | ✅ のび太(HP150/霰弹枪/mag3) ⇄ ジャイ(HP90/步枪/mag11) **整套换绑**，旧座位数据无损；`shotgun` 弹夹归 0 证明是整字典替换而非部分拷贝 |
| 死亡切换 | ✅ 座位 0 打死 → 自动切座位 1，`is_dying` 正确复位 |
| 全队死亡 | ✅ 不再尝试切换，`is_dying=true` / `death_phase=1` 走真死亡流程 |

**顺带修掉的既有 bug**：

1. **存档漏字段** —— v1 `_serialize_team()` 只存 8 个字段，漏了 `current_tp` / `healing_item` / `support_item` / `throwable` / `inventory`，`_deserialize_team()` 还把它们硬编码成 `null`/`[]`。**读档后队员的 TP、治疗品、投掷物、背包会丢**。现在走 `PlayerState.to_dict()` 全覆盖
2. **共享 CharacterData 实例** —— v1 `_deserialize_team()` 的 `load(resource_path)` 后没 `duplicate()`，读档后同角色的多个队员共用一个实例，改一个影响全部，还污染资源缓存里的 `.tres` 母本
3. **双份真相源** —— `CharacterData.current_hp/current_tp` 与 `Global.player_hp`/`team[i]["current_hp"]` 两边都在写。现在**明确 PlayerState 为唯一真相源**，CharacterData 运行时字段只作 `init_from_character()` 的初始化来源
4. **JSON int→float 漂移** —— 弹夹值读档后变成 `5.0`。`from_dict()` 现在强制 `int()` 回收

### ✅ S3 · 注册表接线（已完成并实测通过）

- `player.gd` 在 `_ready()` 注册实体、`_exit_tree()` 注销实体。
- HUD、角色切换、菜单武器状态、相机、Director、物品管理、传送点、敌人索敌统一通过 `Players.get_local_entity()` / `all_entities()` / `nearest_entity_to()` 取玩家；删除重复的分组扫描与递归场景树查找。
- 消耗品效果施加移到玩家节点的 `use_healing_item()` / `use_support_item()` / `apply_item_effects()`；`PlayerState` 只负责扣除数据，`Global._apply_item_effects()` 已删除。迁移期的 `Global.use_*` 转发已在 S5 与其余 per-player shim 一并删除。
- `enemy.gd` 仍保留 VisionArea 的当前目标快速路径，fallback 改为注册表最近实体；多目标仇恨属 §9.3 P1，不在本轮。

**实测验证结果**（Godot 4.6.3，MCP `project_run` + `game_eval`）：

| 项 | 结果 |
|----|------|
| 启动与注册 | ✅ 安全屋启动无 S3 脚本错误，日志出现 `Player → 座位 0`，本地/全部/最近实体均返回同一玩家 |
| HUD / 相机 / 菜单 / 传送点 | ✅ HUD 与相机引用注册实体；菜单武器状态结果一致；传送点从注册表取得玩家 |
| 注销与时序兜底 | ✅ 主动注销后 group fallback 可恢复注册，实体数仍为 1；真实退树由 `_exit_tree()` 注销 |
| 治疗品 / 辅助品 | ✅ 治疗品扣到 0 并恢复 25 HP；辅助品清空并恢复 30 TP；测试后状态完整还原 |
| Director / 敌人 | ✅ Director 正常启动；Director/ItemManager 查找包装与敌人 fallback 已静态确认只读 `Players`；本图未放置敌人节点 |

运行期仅见既有文字色表 `Image.load_from_file()` 导出警告，与 S3 无关。

### ✅ S4 · 去 shim（已完成并实测通过）

- 所有调用侧均已脱离 `Global` 的 per-player 转发层：玩家实体与状态机用实体绑定的 `PlayerState`，HUD 用本地激活座位，拾取物按交互中的玩家实体取状态。
- 新增 `Players.get_state_for_entity(node)`，将场景玩家实体反查为其座位状态；这避免 Director、拾取物和未来多实体场景误读 `Players.get_active_state()`。
- `weapon_pickup.gd` / `healing_pickup.gd` 现在按交互者的状态处理装备、弹夹、备弹、治疗品和投掷物替换。
- HUD 已直接读取 `PlayerState.current_hp/current_tp`、治疗品与装备数据。
- Director 的弹药压力和物品投放条件均改为读取传入玩家实体对应的状态，修复先前 HP 读实体、弹药却读 Global 顶层的不一致。
- SafeDoor 回血同时写玩家实体镜像与该实体的 `PlayerState.current_hp`。

**验证**（Godot 4.6.3，2026-08-19）：

1. 静态扫描 per-player Global 字段和方法，在 `script/` 中仅剩 `global.gd` 内的 shim 说明注释；调用侧为 **0**。
2. 运行 `res://scene/maps/突袭-第一关-开头安全屋-户外.tscn` 成功进入 live；实体、seat 0、HP/TP 与绑定状态一致。
3. 运行时直接调用 Director 的弹药/补给查询，均返回当前传入玩家的 `PlayerState` 数据，无脚本错误。

运行期仍只见既有的文字色表导出警告和编辑器外树绝对路径警告，均与本阶段无关。

### ✅ S5 · 删除 Global per-player shim（已完成）

- 删除 `script/global.gd` 内全部 per-player 转发属性：角色、HP/TP、背包、装备、武器槽/弹夹、治疗品、辅助品和投掷物。
- 删除全部 per-player 转发方法：背包、武器装备、消耗品和弹药 API；`PlayerState` / 注册实体现在是这些状态与行为的唯一入口。
- `Global.gold`、checkpoint、场景、音频和调试配置继续保留；`get_team_size()` 仍是队伍级兼容入口，不属于 per-player shim。

**验证**：对整个 `script/` 扫描 `Global.<per-player>` 调用及 `global.gd` 内旧属性/方法定义均为 **0**。本阶段没有加入 RPC、peer、`MultiplayerSpawner`、`MultiplayerSynchronizer`、房间或大厅代码。
### ⬜ S6 · 3 → 4 人（待做）

- `character_select_menu.gd:7` `max_team_size` 3 → 4
- `_build_team_slots()`（164-175）：第 4 槽位 y = `70+3*42 = 196`，**需截图确认不与其他窗口元素重叠**，必要时收窄行距（当前布局 `Vector2(348, 70.0 + i*42)`，无溢出处理）
- InputMap 加 `选择队员4键` = Ctrl+4：`input_map_manage(op="ensure_action")` + `input_map_manage(op="ensure_binding", event_type="key", keycode="4", ctrl=true)`
- `character_switch_manager.gd:196-204`：3 个硬编码 `elif` 改为按 `Players.seat_count()` 循环匹配 `选择队员N键`
- 顺带：删 `character_data.gd:to_dict()` 死代码（已确认无调用方）

---

## 6. 踩过的坑（务必记住）

1. **新增 autoload 后编辑器会报假错** —— 添加 `Players` autoload 后，编辑器进程报 `Compile Error: Identifier not found: Players`（出现在 `character_select_menu.gd` / `character_switch_manager.gd` / `save_manager.gd`）。**游戏进程全新启动完全正常**，`project_run` 的 `current_run_errors` 为空。这是编辑器需要重启才认新 autoload 名的产物，不是代码问题。判据：看游戏进程而非编辑器进程。

2. **GDScript 循环依赖报错极具误导性** —— `PlayerState` ↔ `SaveManager` 互相引用时，报的不是「循环依赖」而是 `Identifier not found: Players`，并级联到多个无关文件。解法是抽出无依赖的第三方类（`ItemCodec`）。

3. **`Resource.duplicate()` 清空 `resource_path`** —— 所以 `PlayerState.character_path` 必须单独存；背包里 `duplicate()` 的弹药也因此必须靠 ItemCodec 的手工重建路径。

4. **`script_patch` 的诊断输出极其冗长** —— 文件处于中间破损态时，MCP 诊断会把每个错误连完整调用栈一起返回，非常占上下文。批量改动时改用 `Edit` 工具（不触发编辑器诊断），最后统一 `project_run` 验证一次。

5. **`take_damage()` 有 3 个必填参数** —— `take_damage(damage, _knockback_force, direction, ...)`。少传参数会让游戏进入 debugger break 卡死，必须 `project_manage(op="stop")` 才能恢复。

6. **`game_eval` 代码缩进必须用 tab**，否则 Mixed tabs/spaces 让游戏 break。

7. **多角色功能必须走完整菜单流程或手动建座位再 `reload_current_scene()`** —— 安全屋户外地图起始只有 1 个座位，`CharacterSwitchManager._ready()` 在 `seat_count() <= 1` 时直接 `return` 并禁用自身，测不出切换。
