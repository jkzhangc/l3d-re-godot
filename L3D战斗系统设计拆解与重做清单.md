# L3D 战斗系统设计拆解与重做清单

> 配套文档：`游戏设计方向-L3D混合.md`（设计总纲，已声明是对原版 L3D 官方说明书的提炼）、`攻击系统参考.md`、`技能与搓招系统.md`、`投掷物系统.md`、`倒地救援与团灭实施方案.md`、`角色切换系统设计.md`、`导演系统设计方案.md`、`项目进度评估报告-2026-09-02.md`。
> 说明：本仓库不含 `../L3D参考项目_官方说明书整理.md`（设计总纲引用的原版手册），以下"原版 L3D 战斗设计"均基于设计总纲 + 现有战斗子系统文档**实证重建**。
> 与《全面重做规划清单》的关系：本文 §2 的重做项 → 模块映射见 §3 / 该文件 §7，二者必须保持一致。

---

## 1. 原版 L3D 战斗系统设计拆解（五维度）

### 1.1 战斗机制（Combat Mechanics）

| 要素 | 原版 L3D 设计 | 当前实现状态 | 落差 |
|------|--------------|-------------|------|
| **核心循环：见切→反击→背刺即死** | 敌人命中瞬间按见切（0.3s 窗口）→ 无伤+反击（必带超 Push 推开敌群）→ 绕背攻击触发**背刺即死**（无视 HP/威力；Boss 改 1.5× 伤）。三支柱之一 | **完全缺失**（`PlayerMikiriState` 不存在，全 `.gd` 零匹配） | 设计支柱未落地，属最高优先级 |
| **Guts 保底不死** | HP≥2 时任何攻击最低保留 1 HP（与静香回复联动） | 未实现 | 伤害结算无 clamp |
| **Rush 三型节奏** | 单发型（杀够数结束）/耐久型（倒计时防守）/永续型（完成事件才结束，必须边打边走） | 仅"耐久型"在防守战有雏形；单发/永续未实现 | 节奏多样性缺失 |
| **角色=打法** | 共享框架（SA/反击/武器槽）+ 专属技能组合把角色推向不同玩法 | `CharacterData` 的 `base_speed`/`critical_rate` **零引用**，全角色同速同龄 | 差异化在代码层被架空 |
| **武器系统** | 主/副槽；远程 TAP/HOLD 双模式；近战；推击（无伤击退+溅射+连锁推挤）；装填 NORMAL/SHOTGUN；消耗品（治疗/辅助） | ✅ 较完整（6 把武器、双装填、推击疲劳、暴击爆头） | 数据驱动良好，主要问题是 `player.gd` 承载过重 |
| **投掷物** | 举起/瞄准（路径+终点，A/S 调格数）/投掷；抛物线；爆炸/火海 | ✅ 燃烧瓶/手雷可用，但持物外观 `held_walk_texture` 未配置 | 表现层缺口 |
| **倒地/救援/团灭** | HP=0→倒地（爬行+流血 20s）→队友长按 3s 救起 30% HP→全员非站立黑屏重载本章 | ✅ 已落地（`倒地救援与团灭实施方案`） | 实现完整，是亮点 |
| **属性系统（炎/雷/氷/酸）** | 第一章不做；第五章前引入，敌人预留 `element_resist` 字典 | 未做（按计划后置） | 属预期后置，但需**预留数据结构** |
| **武器削损（Heat/酸）** | 第一章不做；Hunter 实装时再评估 | 未做（后置） | 预期后置 |

### 1.2 数值平衡（Numerical Balance）

| 参数 | 原版/当前设定 | 来源 | 现存问题 |
|------|--------------|------|---------|
| 玩家 `max_hp` | 200 | `player.gd` | 与敌人 `max_hp=100` 比例 2:1，需结合难度档校准 |
| 敌人 `move_speed` | 120 px/s；`attack_damage=10`；`attack_range=20`；视野 90°/200px；`lose_player_time=5s` | `enemy.gd` 导出参数 | 单一种敌人模板，无梯度 |
| 紧张度公式 | `hp*0.30 + ammo*0.20 + proximity*0.15 + progress*0.15 + combat*0.20`；`combat_factor` 直接 `0.8/0.2` 硬编码 | `intensity_tracker.gd` | **combat 因子无渐变**（战斗中恒 0.8），节奏起伏被压平 |
| 难度四档 | Easy/Normal/Hard/Expert，被伤 **10 倍差**（总纲 §8 默认） | `游戏设计方向-L3D混合.md` | 10 倍差过大，待调参阶段收敛 |
| 推击疲劳 | `shove_fatigue_limit=3` / `cooldown=2.0s` / `reset=3.0s` | `CharacterData` | 合理，但写死在角色默认值 |
| 倒地 | `BLEED_HP=100` / `BLEED_RATE=5/s`(20s) / 救援 3s / 复血 30% | `network_world.gd` 常量 | 常量散落联机文件，未入数据资源 |
| **`CharacterData` 死字段** | `base_speed` / `critical_rate` 声明后**零引用**；暴击量纲冲突（CharacterData 用 0–1，WeaponData 用 0–100） | `character_data.gd` vs `weapon_data.gd` | 角色差异化与暴击系统同时失效 |
| 武器数值 | 伤害/射速/击退/暴击/溅射全 `@export` 在 WeaponData | `weapon_data.gd` | 驱动良好，但缺乏"平衡基线表"（各武器 DPS/控场力未归一） |

### 1.3 技能体系（Skill System）

| 层 | 原版设计 | 当前实现状态 |
|----|---------|-------------|
| 资源模型 | `SkillData`（tp_cost / cooldown / command_trigger / command_motion / icon / effect_anim） | ✅ 结构存在，`skill_test`/`skill_form_switch` 占位 |
| 搓招输入 | 技能键(5)+触发键(Z/X)+方向序列（"下右"）；4 方向简化 | ✅ 框架已通（`_match_motion` 缓冲匹配） |
| TP 经济 | `max_tp`/`current_tp`/`tp_regen`；TP 恢复品 | ✅ 消耗/回复已通 |
| **SA（特殊行动）** | のび太=感覚向上 / ジャイアン=リサイタル / スネ夫=バックパック / 静香=しゃがみ回避（一闪） | ❌ **空壳**：仅 `use_skill` 扣 TP，无实际效果 |
| **反击类型** | 角色差异化反击（拳打/强打/一闪）作为 CharacterData 字段 | ❌ 未落地 |
| 冷却 | `cooldown` 字段 | ❌ **未接入计时** |
| 技能 UI | HUD 显示 TP 数值，无图标栏 | ❌ 仅 `TPLabel` |
| 角色技能表 | `CharacterData.skills` 数组 | ❌ 各角色为空 |

### 1.4 敌人 AI（Enemy AI）

| 要素 | 原版/设计 | 当前实现状态 | 落差 |
|------|----------|-------------|------|
| 状态机 | Idle/Discover/Chase/Attack/Hitstun/Knockback/Death/HeadshotDeath | ✅ 8 态完整 | —— |
| 寻路 | A* + 流场 + 狭窄通道排队 + 卡墙恢复 + 转向限速 | ✅ 较完整（`EnemyChaseState` 内实现） | 全部塞进单一状态（god-state） |
| **敌种阵容（L3D）** | 丧尸 + Crimson Head（10s 力竭）+ Hunter 系 + 女巫 + Tyrant（Boss） | ❌ **仅 1 种**（`enemy.tscn`）；Hunter/女巫/Tyrant 全未实现 | 阵容 85% 空缺 |
| **敌种抽象** | 应数据驱动（参数+可选状态覆盖） | ❌ 无 `EnemyArchetype`；差异仅靠 `@export` 数值，全部跑同一套 FSM | 新增敌种=改内核 |
| 可行走性 | 两套 TileMap 判定（按图层名子串 `"wall"/"decor"/"ground"`） | `EnemyChaseState:843-864` vs `director.gd:630-646` | 不可移植、换图块集风险高 |
| 特感编排 | Director Phase 4（生成预算/时机/事件） | ❌ 未开始（`spawn_point` 的 `SPECIAL` 枚举预留但无实体） | —— |

### 1.5 关卡战斗节奏（Level Combat Pacing）

| 要素 | 原版/设计 | 当前实现状态 | 落差 |
|------|----------|-------------|------|
| Director 核心 | 紧张度→节奏(Build/Peak/Cooldown)→生成/物品/事件 | ✅ Phase 1–3（intensity/pacing/spawn/event/item） | —— |
| **Rush 三型** | 单发/耐久/永续（设计总纲 §1.2） | ❌ 仅耐久型在防守战雏形；单发/永续无 | 节奏多样性缺失 |
| 防守战（Holdout） | 耐久型 Finale 原型；强制追击最近玩家 + 开局附近一起追 | ✅ 09-03 已改（见记忆） | 实现完整 |
| 剧本事件 | CRESCENDO/FINALE/ALARM/BOSS | ✅ `event_manager` + `ScriptedEventTrigger` | —— |
| **动态音乐** | 按紧张度切换 BGM | ❌ 未做 | 氛围缺失 |
| **章节内容** | 市街地+学校 5 图贯通 | ❌ 仅 1 关有内容；第二关 2 图空图、无生成区/安全门 | 最大短板 |
| 地图碰撞/通行性 | 还原图需碰撞数据供寻路 | ❌ 所有还原图无碰撞/通行性 → 敌人寻路不可用 | 阻断内容生产 |
| 难度/进度因子 | `progress_factor` 越接近终点越紧张 | ✅ 公式存在 | 合理 |

---

## 2. 重做清单（逐维度：现状分析 / 问题定位 / 具体重做规划方案）

> 每项均包含三要素：**现状分析说明 → 问题定位 → 具体重做规划方案**（非大纲级）。

### 2.1 战斗机制重做（核心循环：见切/反击/背刺 + Guts）

**【现状分析说明】**
当前战斗机制以"射击/近战/推击/装填/投掷"为骨架，数据驱动程度高（WeaponData 字段齐全），倒地救援与团灭也已落地。但设计总纲定义的最高优先级支柱——**见切→反击→背刺即死循环**——在代码中完全不存在。玩家当前只有被动受击与主动攻击，缺少原版 L3D 的"防御反击"手感来源。Guts 保底不死同样缺失，伤害结算直接扣血无下限保护。

**【问题定位】**
1. 缺乏 `PlayerMikiriState` 及对应的命中框激活帧读取机制（反击需读取敌人 `AttackState` 的命中框激活帧，当前无此接口）。
2. `player.gd` 已达 1542 行 god-object，新状态若直接挂入会进一步膨胀；且武器状态（Pistol/Knife）近 100% 重复、Sniper/Shotgun/Rifle/Smg 的 `*Attack` 节点是硬编码 `emit("Pistol")` 的**不可达死节点**，新增见切状态需先理顺状态机。
3. 命中结算依赖鸭子类型 `body.get("current_hp")` / `get("_is_dead")`，背刺即死需要统一的"即死"语义，当前 `Damageable` 接口未建立。
4. 背刺规则"敌人与玩家朝向相同"需要双方 facing 的可查询接口，当前 facing 散落在各状态。

**【具体重做规划方案】**
1. **先建接口层（对应 M07）**：定义 `Damageable` 接口（`take_damage(dmg, knockback, dir, is_deadly=false)` + `is_dead()` + `get_facing()`），统一所有伤害入口；`HitResolver.resolve_hits(hitbox, ...)` 供近战/推击/子弹共用。
2. **新增 `PlayerMikiriState`（对应 M10）**：
   - 监听所有敌方 `AttackState` 广播的 `hitbox_activated` 信号（在敌方 `attack_hit_at_sequence_idx` 帧触发）。
   - 见切窗口：`mikiri_window = 0.3s`；窗口内收到输入（非架势=确定键 Z；架势中=确定/取消均可）→ 进入 `MikiriSuccess` 子状态。
   - 反击：前方范围攻击，`super_push = true`（复用推击溅射+连锁逻辑，力度 ×1.5），推开敌群。
   - 背刺即死：反击命中时若 `enemy.get_facing() == self.get_facing()`（原版"双方朝向一致"规则）→ 调用 `enemy.take_damage(0, ..., is_deadly=true)`；Boss（`boss_flag`）免疫即死，改 `damage *= 1.5`。
   - Guts：在 `HitResolver` 内 `if attacker_dmg > 0 and target.current_hp - dmg < 1 and target.current_hp >= 2: dmg = target.current_hp - 1`。
3. **状态机归并（对应 M09）**：合并武器状态为 `PlayerWeaponReadyState` + `PlayerWeaponAttackState`（ranged/melee 分支），删除死节点；见切状态优先级高于攻击输入。
4. **数据驱动**：`WeaponData`/敌人配置增加 `boss_flag`、`instakill_resist`（○/△/× 三档）。

### 2.2 数值平衡重做

**【现状分析说明】**
数值目前分两层：WeaponData（武器）已数据驱动良好；但"角色层"与"全局节奏层"存在结构性缺陷。紧张度公式的 `combat_factor` 在战斗中恒为 0.8、脱战恒为 0.2，缺乏过渡，导致节奏曲线被压平；难度四档默认 10 倍被伤差过大；`CharacterData.base_speed`/`critical_rate` 声明后零引用，且暴击量纲在 CharacterData(0–1) 与 WeaponData(0–100) 间冲突，使角色差异化与暴击系统同时失效。倒地/救援等常量散落在 `network_world.gd`（联机文件），未入资源，调参需改代码。

**【问题定位】**
1. 角色差异化数据未贯通：`player.gd:47-48` 用 `@export` 覆盖 `CharacterData`，导致 `base_speed`/`critical_rate` 死字段。
2. 量纲不统一：暴击在角色层(0–1)与武器层(0–100)双轨，结算易错且无单一真相。
3. 节奏因子硬编码：`intensity_tracker.gd` 的 `combat_factor` 无渐变；`intensity_tracker.gd:154` 进度因子写死 `return 0.3`。
4. 平衡参数无基线表：各武器 DPS/控场力、敌人梯度未归一，调参靠手感。

**【具体重做规划方案】**
1. **角色数据落地（对应 M04）**：`CharacterData` 真正驱动 `walk_speed`/`run_speed`/`critical_rate`（统一为 0–100 整数，WeaponData 不再存独立暴击）；删除 `base_speed` 死字段或正确引用；各角色 `skills` 数组填充。
2. **平衡资源表（新增 `BalanceConfig.tres`，对应 M06）**：集中存放难度倍率（替换 10 倍差为分层曲线，如 Easy×0.5 / Normal×1 / Hard×1.8 / Expert×3）、敌人梯度模板、武器 DPS 基线。
3. **紧张度去硬编码（对应 M17）**：`combat_factor` 改为基于"近 X 秒交火时长/受到伤害速率"的连续值（0.2→0.8 平滑）；`progress_factor` 改为读取关卡实际进度；所有权重入 `DirectorConfig`。
4. **倒地/救援常量入资源**：将 `BLEED_HP`/`BLEED_RATE`/`REVIVE_DURATION` 等移入 `DirectorConfig` 或 `BalanceConfig`，联机文件只读取。

### 2.3 技能体系重做

**【现状分析说明】**
技能系统当前是设计文档自承的"空壳子"：搓招输入框架（技能键+触发键+方向序列）与 TP 消耗/回复已通，`SkillData` 结构存在，但 `cooldown` 未接入计时、`effect_anim` 为预留、实际技能效果为零。仅 2 个占位技能。角色差异化 SA（感覚向上/リサイタル/バックパック/しゃがみ回避）与各角色反击类型完全未落地，HUD 仅显示 TP 数值无图标栏。

**【问题定位】**
1. `SkillData` 无"效果载体"：技能应触发的是一段效果（伤害/治疗/增益/形态切换/召唤），当前 `use_skill` 只扣 TP。
2. `cooldown` 计时缺失：无 `_update_cooldowns(delta)` 驱动。
3. 角色差异化无数据：反击类型、SA 参数未进入 `CharacterData`，"角色=打法"无法实现。
4. 无技能 UI：玩家不知道有什么技能、冷却状态。

**【具体重做规划方案】**
1. **技能效果载体（对应 M04/M09）**：`SkillData` 增加 `effect_type`（DAMAGE/HEAL/BUFF/FORM_SWITCH/SUMMON）+ `effect_payload`（引用 BulletData/HealAmount/BuffSpec）。`player.gd::use_skill` 改为按 `effect_type` 派发到 `HitResolver`/治疗/`BuffSystem`。
2. **冷却系统（对应 M09）**：`CharacterData` 维护 `cooldown_timers: Dictionary[skill_id, float]`；每帧 `_update_cooldowns(delta)`；HUD 读此显示。
3. **角色 SA 差异化（对应 M10/M31）**：在 `CharacterData` 增 `special_action: SkillData` 与 `counter_type`（拳打/强打/一闪）。のび太=感覚向上（数秒完全见切态）、ジャイアン=リサイタル（歌声全体踉跄）、スネ夫=バックパック（切换背包/手持）、静香=しゃがみ回避（短无敌）+一闪。
4. **技能 UI（对应 M25/M27）**：HUD 加技能图标栏（来自 `SkillData.icon`），显示冷却遮罩与 TP 是否充足。

### 2.4 敌人 AI 重做

**【现状分析说明】**
敌人 AI 状态机（8 态）与寻路（A*+流场+门控+卡墙恢复+转向限速）实现完整且质量较高，但**全部敌人只有 1 种**（`enemy.tscn`），且寻路与 AI 逻辑全部塞进 `EnemyChaseState.gd`（980 行 god-state）。设计总纲要求的 L3D 阵容（Crimson Head/Hunter/女巫/Tyrant）85% 未实现，且无 `EnemyArchetype` 抽象——新增敌种必须改共享内核。两套 TileMap 可行走性判定不可移植。

**【问题定位】**
1. 敌种零抽象（E2）：无 `extends enemy.gd` 子类，差异仅靠 `@export` 数值。
2. 导航耦合进状态（E1）：A*/流场/门控/恢复全在 `EnemyChaseState`，状态文件不可读不可测。
3. 阵容空缺（E2）：Hunter/女巫/Tyrant 的 AI 形态完全未设计。
4. 可行走性双实现（E3）：按图层名子串判定，换图块集即崩。

**【具体重做规划方案】**
1. **抽 `NavigationService`（对应 M13）**：将 `EnemyChaseState` 的 A*/流场/门控/卡墙/转向全部移到独立服务，状态退化为"取方向→移动"的薄消费者。
2. **建 `EnemyArchetype` 资源（对应 M05）**：用 `.tres` 描述敌种（max_hp/速度/攻击/视野 + 可选状态覆盖）。普通丧尸与 Crimson Head 仅是参数变体（Crimson Head 加 `exhaust_after=10s`）；Hunter/女巫/Tyrant 通过"基础 FSM + 特感行为覆盖"表达，新增敌种=加配置。
3. **统一 `WalkabilityProvider`（对应 M14）**：合并两套判定为接口（按 `is_walkable(cell)` 而非图层名），解除对具体图块集耦合。
4. **阵容路线图（对应 M16 + 后续章节）**：第一章先 Crimson Head（参数变体，成本低）；第二章 Hunter 系（首狩り→Heat 封锁见切）、女巫（徘徊/刺激追杀）、Tyrant（全抗性+Normalize）。

### 2.5 关卡战斗节奏重做

**【现状分析说明】**
Director 的 Phase 1–3（紧张度/节奏/生成/事件/物品）已落地，防守战（耐久型）与倒地团灭也已实现。但 Rush 三型中仅耐久型有雏形（单发/永续未做），动态音乐未做，最大短板是**内容**：仅 1 关有实际内容，第二关 2 张图是空图（无生成区/安全门/敌人），且所有 RM2K3 还原图**无碰撞/通行性数据** → 敌人寻路在还原图上完全不可用。这直接阻断第一章贯通与后续章节扩展。

**【问题定位】**
1. 节奏多样性缺失：Rush 仅耐久型，单发/永续型（原版"移动射击"关键体验）未实现。
2. 内容生产阻塞：还原图缺碰撞/通行性，Director 查 TileSet physics 得空层 → 寻路失效。
3. 章节未贯通：第二关两张图未登记 `campaign_assault.tres`、`level_scenes`。
4. 动态音乐缺位：紧张度信号已暴露但无 BGM 切换。

**【具体重做规划方案】**
1. **还原管线固化碰撞（对应 M30/P1）**：将"地形 ID→TileSet physics 层"做成 `tools/rm2k3_map_restore/` 标准步骤（参考 L3D 原版 MOD 思路），不再逐图手填；输出碰撞+通行性。
2. **Rush 三型落地（对应 M20）**：
   - 单发型：`pacing_controller` 波次 + `event_manager` 杀够数结束（街道图）。
   - 耐久型：已有防守战原型，HUD 计时器复用。
   - 永续型：事件期间禁用 SpawnManager 暂停、要求玩家移动到达点才结束（蹲点无效）。
3. **章节贯通（对应 M30）**：学校两张图补 SpawnZone（参考街道 12 个）/SafeDoor/DirectorConfig/传送点链路，登记进 `campaign_assault.tres`；单人从开头安全屋连续打到学校出口无空图/卡死。
4. **动态音乐（对应 M17/M27）**：`intensity_changed`/`pacing_phase_changed` 信号接入 `AudioManager` 做 BGM crossfade（build/peak/cooldown 三态）。
5. **双人验收（对应 M22/M30）**：用 `tools/net_regression` 新增本章场景回归。

---

## 3. 与《全面重做规划清单》的模块映射（统一）

| 重做项（本文 §2） | 对应模块 ID | 阶段 | 说明 |
|------------------|-----------|------|------|
| 战斗核心循环（见切/反击/背刺/Guts） | **M07 + M10** | R2 | 先建 `Damageable`/`HitResolver`，再实现 `PlayerMikiriState` |
| 状态机归并 + 武器死节点清理 | **M09** | R2 | 合并武器状态、删死节点 |
| 角色数据落地 + 暴击量纲统一 | **M04** | R1 | 修 `base_speed`/`critical_rate` 死字段 |
| 平衡资源表 + 紧张度去硬编码 | **M06 + M17** | R1/R4 | `BalanceConfig`/`DirectorConfig` 集中 |
| 技能效果载体 + 冷却 + 角色 SA | **M04 + M09 + M10 + M31** | R1–R2/R7 | 空壳→落地，含静香 |
| 技能 UI | **M25 + M27** | R6 | HUD 图标栏 |
| 导航服务抽取 | **M13** | R3 | 解 `EnemyChaseState` god-state |
| 敌种 Archetype + 阵容 | **M05 + M15 + M16** | R1/R3 | 数据驱动敌种 |
| 可行走性统一 | **M14** | R3 | `WalkabilityProvider` |
| Rush 三型 + 防守战 + 动态音乐 | **M17 + M19 + M20** | R4 | Director Phase 4 + 节奏 |
| 还原图碰撞管线 + 章节贯通 | **M30** | R7 | 第一章垂直切片 |

> 二者必须同步维护：本文是战斗维度的**详细设计依据**，《全面重做规划清单》是其**执行编排**。任何战斗重做项的优先级/依赖/阶段调整，需同时更新两文件。
