# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作时提供指导。

> **注意**：仓库中同时存在 `AGENTS.md`，该文件是旧版 CLAUDE.md 的衍生副本，内容已过时。**请忽略 `AGENTS.md`**，所有项目指导以本文件（`CLAUDE.md`）为准。

## 项目概述

**のび太的求生之路** — 一个关于野比大雄的 Left 4 Dead 2 同人游戏重制版，使用 **Godot 4.6.3** 构建的俯视角 2D 像素风格游戏。力求还原 L4D2 的核心机制与游戏体验。

## 项目文档

编写功能代码前请参考：

| 文档 | 内容 |
|------|------|
| **`游戏系统架构文档.md`** | 完整系统架构（状态机、武器、菜单、存档） |
| **`Global重构-PlayerState方案.md`** | 🔧 **进行中**：Global 单例 → PlayerState + 玩家注册表（S1–S6 已完成） |
| **`联机系统架构设计.md`** | 联机 v2 设计（Host 全量模拟）。仍是依据，仅 §8 原型章节作废 |
| **`攻击系统参考.md`** | 攻击动画、子弹、弹夹/弹药、近战判定、武器槽位 |
| **`L4D2特色机制参考.md`** | L4D2 原版机制详解 |
| **`L4D2缺失功能清单.md`** | 相对 L4D2 的缺失功能 + 优先实现列表 |
| **`导演系统设计方案.md`** | Director AI 完整设计 + 5 阶段实施计划 |
| **`导演系统参数参考.md`** | 全部参数速查 + 当前地图参数 |
| **`导演系统使用指南.md`** | Director 节点放置与参数手册 |
| **`角色切换系统设计.md`** | 队伍切换/武器行走图/武器限制/菜单流程（✅ 已实现） |
| **`VX动画特效与图块系统.md`** | VXAnimSprite 参数表、VXTileMap、A4 转换器、bitmask 速查 |
| **`A1动画图块实现方案.md`** | VX Ace A1 水流动画 → Godot TileSet 内置动画 |
| **`TileSet工作流完整指南.txt`** | 图块素材 → TileSet → TileMapLayer 工作流 |
| **`art/Tilesets/TileA4-Tw_bitmask速查表.txt`** | A4 墙壁自动图块 → Godot Terrain Bitmask 映射表 |
| **`开发日志.md`** | 错误修复记录 + 架构变更日志 |

## 引擎配置

- **Godot 版本**：4.6.3（可执行路径：`D:\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe`）
- **物理引擎**：Jolt Physics / **渲染器**：Mobile / **GPU**：Direct3D 12
- **游戏分辨率**：1280×960（设计基准，HUD 布局以此为准）

## Godot AI MCP 集成

**编辑器已安装 Godot AI MCP 插件 (v3.1.5)**，提供对 Godot 编辑器的完整程序化控制。**操作 Godot 场景/节点/资源时，优先使用 MCP 工具，而非直接读写 .tscn/.tres 文件。**

### MCP 优先原则

| 场景 | 做法 |
|------|------|
| 创建/修改/删除节点 | ✅ 用 `node_create` / `node_set_property` / `node_manage` |
| 编辑脚本 | ✅ 用 `script_create` / `script_patch` / `script_manage`（触发编辑器诊断） |
| 场景层级查看 | ✅ 用 `scene_get_hierarchy` / `node_get_properties` |
| 运行/测试游戏 | ✅ 用 `project_run` / `test_run` / `editor_screenshot` |
| 查看 TileMap/TileSet | ✅ 用 `tilemap_manage` / `tileset_manage` |
| UI 构建 | ✅ 用 `ui_manage`（`build_layout` / `set_anchor_preset` / `set_text`） |
| 动画 | ✅ 用 `animation_create` / `animation_manage` |
| 材质/着色器 | ✅ 用 `material_manage` / `node_set_property`（shader 赋值） |
| 粒子/CSG/相机/音频 | ✅ 用对应的专用 MCP 工具 |
| InputMap 配置 | ✅ 用 `input_map_manage` |
| 项目管理/设置 | ✅ 用 `project_manage` / `filesystem_manage` |
| 批量操作 | ✅ 用 `batch_execute`（失败自动回滚） |
| 仅批量文本替换 | ⚠️ 用 `Edit` 工具（脚本内容大面积重写时） |
| 读取纯数据文件 | ⚠️ 用 `Read` 工具（.md/.txt/.json 非 Godot 资源） |

### 典型工作流

1. **查看状态**：`editor_state` → `scene_get_hierarchy` → `node_get_properties`
2. **修改场景**：`node_create` / `node_set_property` / `node_manage` / `ui_manage`
3. **编写脚本**：`script_patch`（小改）或 `script_create`（新建）
4. **验证**：`project_run` → `editor_screenshot(source="game")` → `logs_read(source="game")`
5. **调试**：`logs_read` / `game_manage` / `game_eval`

### 操作前检查

- 编辑场景时先确认 `editor_state` 返回的 `current_scene` 是否正确
- 写属性前先 `node_get_properties` 确认属性名（Godot 内部名称可能与直觉不同）
- `project_run` 前先 `scene_save` 确保 MCP 修改已落盘
- 编辑器未运行时，大部分 MCP 工具不可用——此时回退到文件操作

## 目录结构

| 目录 | 用途 |
|-----------|---------|
| `art/Characters/` | 角色精灵表 |
| `art/Tilesets/`  | 图块素材（RPG Maker VX Ace 格式，32×32） |
| `art/Animations/` | VX Ace 动画精灵表（.png 源文件） |
| `art/Title/`     | 标题画面素材 |
| `art/System/`    | 系统窗口素材 + 字体 |
| `art/Ui/`        | HUD/UI 素材（血条框/填充、Boss 血条、GO 图标） |
| `art/misc/`、`art/Weapon/` | 杂项与武器图标 |
| `anim/` | 动画特效场景（`.tscn`） |
| `script/` | GDScript 脚本（`.gd`） |
| `scene/`  | Godot 场景文件（`.tscn`） |
| `object/` | 可复用游戏对象、武器/角色/物品 `.tres` 数据资源 |
| `tres/` | TileSet 资源文件（`.tres`） |
| `shader/` | 自定义着色器（`.gdshader`） |
| `music/` / `sound/` | 背景音乐 / 音效 |

## GDScript 风格

- 使用 **GDScript**（非 C#）—— 目标平台 Mobile
- **Godot 4.6：lambda 不能直接作为 `connect()` 参数**，必须先赋值给 `Callable` 变量：
  ```gdscript
  # ❌ 报错: "Standalone lambdas cannot be accessed"
  timer.timeout.connect(func(): print("x"))
  # ✅ 正确
  var cb: Callable = func(): print("x")
  timer.timeout.connect(cb)
  ```
- **GDScript 类级声明无缩进**：`func`、`@export`、`@onready`、`const` 顶格写（0 tab），只有函数体才缩进

## 快速参考

### 场景入口与关卡

- **场景入口**：`scene/main.tscn`
- **关卡标准**：参考 `scene/maps/突袭-第一关-开头安全屋-户外.tscn`。GroundLayer→DecorLayer(y_sort)→UpperLayer(y_sort)。玩家/敌人必须是 **DecorLayer 子节点**。UpperLayer 不参与 A* 寻路。详见 `memory/scene-conventions.md`
- **旧测试地图**：`scene/maps/test.tscn`

### 输入

| 按键 | 作用 |
|------|------|
| X / Esc | 主菜单（继续/设置/退出）。武器举起/攻击状态下屏蔽 |
| Q | 循环切换角色 |
| Ctrl+1/2/3 | 直选队员 |
| Tab | 调试可视化开关（碰撞体/血条/路径/格子） |

### 全局单例

**`Global`** autoload（`script/global.gd`）：调试标志、文字渲染参数、色表缓存、音频总线管理（SFX/Music）、音量/朝向设置、死亡处理参数。`Global.play_sfx_managed()` 同一音效最多并发 3 个。

### 碰撞层

| 层 | Bit | 用途 |
|----|-----|------|
| 1 | 1 | 墙壁/地面（TileMapLayer） |
| 3 | 4 | 玩家物理体 |
| 4 | 8 | 敌人物理体 |
| **5** | **16** | **受击碰撞体 (HurtArea)** |

**攻击检测矩阵**：子弹 mask=24（层4+5），近战 hitbox mask=24，敌人视野 mask=15（层1-4）。

### 菜单流程

```
标题画面 → 战役选择 → 角色选择(1-3人) → 难度选择 → 加载安全屋
```

相关脚本：`campaign_select.gd` / `character_select_menu.gd` / `difficulty_select.gd`。窗口素材：`art/System/Window frame.png`（64×63，九宫格）+ `art/System/Window background color.png`（64×64，缩放背景）。菜单 UI 采用场景节点预置模式，脚本通过 `@onready` 引用节点，布局参数均为 `@export`。

### 固定朝向

武器举起/攻击状态下，根据设置模式控制朝向：**切换式**=按取消键锁定/解锁；**按住式**=按住取消键锁定、松开解锁。攻击状态下玩家可移动（velocity 由方向键控制，朝向锁定不变）。

### 音频

Global 启动时自动创建 `SFX` / `Music` 总线。SFX 音效→SFX 总线，BGM/死亡音乐→Music 总线。音量通过 `AudioServer.set_bus_volume_db()` 控制，设置保存到 `config.json`。

### 字体

使用 **方舟像素字体 (Ark Pixel)** monospaced 中文版：

| 字体 | 原生尺寸 | 完美字号 | 用途 |
|------|----------|----------|------|
| 16px (`text_font_path`) | 16px | 16、32 | 全局默认，正文/标题 |
| 12px (`text_font_path_small`) | 12px | 12、24 | 小字/说明/HP/ATK |

**铁律**：只能在原生尺寸或其整数倍下渲染。导入参数：`antialiasing=0`、`hinting=0`、`subpixel_positioning=0`、`oversampling=1.0`。

### 文字渲染

统一使用 **`GradientLabel`**（`script/gradient_label.gd`）渲染渐变文字。内部双路径：`use_gradient=true` → `TextGradientRenderer`（CPU SubViewport 预渲染 + 逐像素亮度渐变）；`use_gradient=false` → Label + `shader/text_color.gdshader` 纯色。效果：阴影（偏移叠加，z_index=-1）、描边（渐变路径 CPU 8 邻域检测 / 非渐变路径 shader 检测）。全局默认参数在 `Global` 中 `@export`。

### 调试可视化

TAB 键绘制：玩家=绿色、敌人=红色、受击碰撞体=黄色、子弹/攻击触发=青色、攻击判定=橙红。注意 `player.gd::_draw()` 的手绘矩形血条仅在 `Global.debug_visuals=true` 时显示，与正式 HUD 素材无关。

---

## 动画系统 — 帧序列 + 每帧时长

所有动画统一使用 **"帧序列数组 + 每帧时长数组"** 模式，Inspector 可直接编辑：

| 动画类型 | 帧序列字段 | 时长字段 | 说明 |
|----------|-----------|---------|------|
| 武器举起/放下 | `weapon_raise_char_sequence` | `weapon_raise_frame_durations` | 举起正向、放下反向 |
| 武器攻击 | `attack_char_sequence` | `attack_frame_durations` | 空则默认 0.1s |
| 攻击后动画 | `post_attack_char_sequence` | `post_attack_frame_durations` | 攻击帧播完后、切回举起前；空则跳过 |
| 武器装填(NORMAL) | `reload_char_sequence` | `reload_frame_durations` | 播放一次 → 装弹 |
| 武器装填(SHOTGUN循环) | `shotgun_reload_loop_char_sequence` | `shotgun_reload_loop_frame_durations` | 逐发循环 |
| 武器装填(SHOTGUN结束) | `shotgun_reload_end_char_sequence` | `shotgun_reload_end_frame_durations` | 循环结束后上膛 |
| 敌人攻击 | `attack_char_sequence` | `attack_frame_durations` | 空则默认 0.1s |
| 武器拾取踏步 | `pickup_step_frames` | `pickup_step_duration` | 单一时长 |
| 玩家行走/跑步 | `WALK_SEQUENCE` 常量 | `walk/run_frame_duration` | CharacterData 驱动 |

**停顿**：把需要停顿的那帧在时长数组中设为较大值即可（如 `0.43`）。

---

## VX Anim 动画特效

**`VXAnimSprite`**（`script/vx_anim_sprite.gd`）— 播放 VX Ace 格式精灵表动画（960px 宽 = 5 列 × 192px/格）。完整参数表见 **`VX动画特效与图块系统.md`**。

**快速使用**：
```gdscript
# 从 .tscn 场景播放（推荐 — 支持 Inspector 拖拽）
VXAnimSprite.play_scene(packed_scene, pos, parent)
VXAnimSprite.play_scene(packed, pos, parent, 10.0, target, offset_vec)

# 旧版字符串方式
VXAnimSprite.play_at("血", pos, parent)
VXAnimSprite.play_at("anim/爆炸.tscn", pos, parent)
```

**动画特效字段**（WeaponData / Enemy，均为 `PackedScene`，Inspector 拖入 `anim/` 下 `.tscn`）：
- WeaponData：`attack_effect_anim_down/left/right/up`（开枪特效）、`hit_effect_anim`（命中特效），各有 `_follow`/`_offset_override` 后缀字段
- Enemy：`attack_effect_anim` + `_follow`/`_offset_override`

**素材目录**：`art/Animations/`（100+ 张 VX Ace 动画精灵表）。**VX Anim Editor**：`addons/vx_anim_editor/`，底部面板 "VX Anim" 标签页。

**⚠️ 关键实现细节**：`_sprites` 数组在 `_ready()` 显式 `= []`（防 Godot 4 类级默认值跨实例共享）；多精灵帧索引用 `_get_actual_frame()` 匹配；混合模式用 `CanvasItemMaterial`（GPU 级）而非自定义 shader。

---

## 当前功能状态

### 核心战斗

| 系统 | 状态 | 关键文件 |
|------|------|------|
| 标题画面 | ✅ | RM2K3 风格窗口 + 光标动画 + 纵向渐变 |
| 主菜单 | ✅ | 物品/装备双面板 + 存档 + 退出 |
| 玩家角色 | ✅ | 完整状态机（待机/行走/跑步/手枪/小刀/霰弹枪/步枪）；CharacterData 驱动 |
| 武器系统 | ✅ | 手枪/小刀/霰弹枪/步枪/冲锋枪 + WeaponSlot 枚举 + BulletData 子弹列表 + FireMode |
| 装填系统 | ✅ | NORMAL 模式（一次装满）+ SHOTGUN 模式（逐发循环+结束上膛） |
| 子弹实体 | ✅ | 发射者排除 + 永久去重 + 尸体穿透 + 碰撞矩形随方向旋转 |
| 敌人 AI | ✅ | 状态机 + A* 寻路 + 攻击/击退/硬直/死亡/爆头 + HurtArea |
| 死亡系统 | ✅ | 死亡精灵 + 渐黑遮罩 + checkpoint + 死亡优先切换队员 |
| 存档系统 | ✅ | 纯内存 checkpoint + JSON 磁盘存档（含队伍序列化） |
| 武器拾取物 | ✅ | 自动拾取/长按替换 + 踏步动画 + 进度指示器 |
| 战斗 HUD | ✅ | HP 血条 + 5 槽位快捷栏 + 队员名/索引 |
| 受击碰撞体 | ✅ | HurtArea（层5），支持源头去重 |
| 相机跟随 | ✅ | Phantom Camera 插件（SIMPLE 跟随 + 阻尼 + 地图边界限制） |

### 角色切换系统

| 系统 | 状态 | 说明 |
|------|------|------|
| 战役/角色/难度选择 | ✅ | 完整菜单流程 |
| 队伍系统 | ✅ | `Global.team: Array[Dictionary]`，独立 HP/装备/弹药/位置 |
| 切换管理器 | ✅ | Q 循环 + Ctrl+1/2/3 直选 + 0.5s 冷却 |
| 队友精灵 | ✅ | TeammateStandin（Node2D+Sprite2D），挂在 DecorLayer |
| 武器行走图 | ✅ | `CharacterData.weapon_walk_textures`，回退 WeaponData 兜底 |
| 武器限制 | ✅ | `allowed_primary/secondary_weapons`（item_id 白名单） |
| 死亡切换 | ✅ | HP=0 自动切存活队员，全灭才走死亡流程 |

### 导演系统

| 系统 | 状态 | 说明 |
|------|------|------|
| 导演总控 | ✅ | `Director` autoload |
| 紧张度 | ✅ | 五因子（HP/弹药/距离/进度/战斗） |
| 节奏控制 | ✅ | Build-up → Peak → Cooldown |
| 生成管理 | ✅ | 散兵定时 + 尸潮分批 |
| 事件编排 | ✅ | 自然尸潮 + 剧本事件（Crescendo） |
| 物品投放 | ✅ | HP<50%/弹药<30% 决策 |
| 安全门/传送点 | ✅ | SafeDoor/TeleportPoint + 踏步动画 |

### 技能与 TP 系统

| 系统 | 状态 | 说明 |
|------|------|------|
| 角色 TP | ✅ | `CharacterData.max_tp` + 运行时 `current_tp`，随队伍切换/存档同步 |
| TP 自动回复 | ✅ | 每角色 `tp_regen_amount`/`tp_regen_interval`（回复量/间隔各不相同） |
| TP 恢复品 | ✅ | `ItemData.tp_restore` + `hp_restore`，`use_healing/support_item` 应用效果 |
| 物品掉落行走图 | ✅ | `ItemData`「地面显示」组，`healing_pickup` 支持 VX Ace 行走图 + 踏步动画 |
| 技能数据 | ✅ | `SkillData` 资源（`tp_cost`/`cooldown`/`command_trigger`/`command_motion`） |
| 技能搓招 | ✅ | 举起武器 + 按住技能键(5) + 触发键（确定/取消键）→ `player.use_skill(trigger)` |
| 方向指令 | ✅ | `command_motion` 方向序列（上/下/左/右），`_match_motion` 匹配 |

详见 **`技能与搓招系统.md`**。

### 投掷物系统

| 系统 | 状态 | 说明 |
|------|------|------|
| 投掷物数据 | ✅ | `ThrowableData extends ItemData`（投掷/爆炸/燃烧参数），ItemType.THROWABLE |
| 投掷物掉落物 | ✅ | 单槽位 `Global.throwable`，复用 healing_pickup，地图放置手雷/燃烧瓶 |
| 投掷物使用 | ✅ | 数字5举起 → 按住确定键瞄准（路径+终点）→ 松开投掷；取消键取消 |
| 举起行走图 | ✅ | `held_walk_texture` + 每角色 `throwable_walk_char_idx`（留空不显示），跟随朝向+踏步 |
| 调格数 | ✅ | W/E 调节终点格数（0~8，默认3），瞄准时朝向锁定、可移动 |
| 手雷爆炸 | ✅ | 爆炸半径范围伤害+击退 |
| 燃烧瓶火海 | ✅ | `FirePatch` 火精灵（天罰キャラチップ.png）填充范围 + 持续灼烧，12 帧完整动画（4方向×3踏步） |

详见 **`投掷物系统.md`**。

---

## 核心系统速查

### 受击碰撞体 (HurtArea)

玩家和敌人在 `_ready()` 中动态创建 HurtArea 节点（Area2D + RectangleShape2D），位于碰撞层 5。死亡时自动禁用。参数：`hurtbox_size: Vector2`（默认 28,44）、`hurtbox_offset: Vector2`（默认 0,-8）。

**攻击去重（三层防护）**：
1. **子弹侧永久去重**：`_hit_targets` Dictionary（instance_id→true），同一子弹不对同一目标重复判定
2. **目标侧源头去重**：`take_damage(source_id)` 追踪 1 秒内伤害来源，同 source_id 拒绝重复
3. **近战去重**：`_check_melee_hits()` 按 instance_id 去重

**尸体穿透**：子弹 `_hit()` 检查 `_is_dead/_is_dying`，尸体跳过（不消耗穿透、不播特效）。

### 子弹系统

**BulletData**（`script/bullet_data.gd`）：`class_name BulletData extends Resource`。核心字段：外观（`bullet_texture`/`bullet_anim_frames`）、弹道（`speed`/`max_range`/`damage`/`penetration`/`spawn_offset`）、方向（`angle_offset`/`direction_override`/`offset_*`）、击退（`knockback_*`）、碰撞体（`collision_size`/`collision_offset`）。`get_effective_damage()`：子弹 damage>0 用自身，否则回退武器 attack_power。

**子弹实体**（`script/bullet.gd`）：Node2D 运行时子弹，从 `object/bullet.tscn` 实例化。水平帧条渲染（`region_rect` 按动画帧选列），sprite 旋转跟随飞行方向。`setup()` 在 `add_child()` 之前调用，不能依赖 `@onready`。碰撞体：`Area2D.position = collision_offset`（旋转围绕精灵中心）。

**枪声惊敌**：`WeaponData.gunshot_range`（默认 500px），开火时范围内 Idle 敌人自动进入 Discover 状态。0=静音武器。

### 敌人攻击与击退/硬直

敌人攻击使用两个独立矩形：**触发矩形**（`attack_range`+`attack_range_forward_offset`，追击→攻击检测）和**命中矩形**（`attack_hit_range`+`attack_hit_forward_offset`，攻击动画中伤害判定）。统一投影法判定（`_is_target_in_hit_rect()`）。

**击退（Knockback）**：BulletData 中 `knockback_enabled=true` 时生效。`EnemyKnockbackState`：速度=dir×force，线性减速 600px/s²，倒计时 stun→0→切 Chase。

**硬直（Hitstun）**：原地冻结无位移。优先级：击退 > 硬直。远程回退：`BulletData.hitstun_duration=0` → 用 `WeaponData.hitstun_duration`。Idle 状态被命中→先 Discover 不硬直；Chase 状态才生效。

### 武器拾取物

**`script/weapon_pickup.gd`** — 地图放置的武器拾取节点。空槽位自动拾取，已有武器按住确定键替换（`hold_time=1.2s` 可配）。拾取范围内禁止攻击。替换时旧武器掉落为 WeaponPickup（弹药一并转移，添加到 GroundLayer）。

**WeaponData 关键字段**：`weapon_slot`（PRIMARY/SECONDARY 枚举）、`is_ranged`、`pickup_texture`（空则回退 `weapon_walk_texture`）。

### 敌人 A* 寻路

**`script/enemy/EnemyChaseState.gd`** — 基于 TileMapLayer 格子的 A*（32×32 格子，四方向邻居，曼哈顿距离，最大 2000 迭代）。地图缓存为 `static var`，全图只查一次。层识别按节点名：含 `"upper"/"decor"` → 查碰撞多边形；含 `"wall"` → 始终阻挡；含 `"ground"/"floor"` → 可行走。实体障碍（敌人互绕）每帧实时检测。降级模式：连续失败 2 次→直接追击+滑墙。

> **⚠️**：DecorLayer 上有碰撞多边形的 tile 会阻挡 A*。MOTION_MODE_FLOATING 下 `up_direction` 不能设为 `Vector2.ZERO`。

### 战斗 HUD

**`script/ui/hud.gd`** — CanvasLayer：HP 血条（`ＨＰバー.png` + `ＨＰメーター.png`，<30% 变红）+ HP 数值标签 + 5 槽位栏（主/副武器 + 治疗/辅助品 + 投掷品预留）。可见性和布局参数全部 `@export`。

### 伤害数字

**`DamageNumber`**（`script/damage_number.gd`）— `DamageNumber.spawn(global_position, damage, get_tree().current_scene)`。使用 GradientLabel + 9 种缓动。所有参数 `@export`（`font_size=32`、`rise_distance=20`、`duration=1.0`、`color_index=1` 等）。

### 相机跟随

**`script/camera_follow.gd`** — Camera2D 扩展，底层已接入 **Phantom Camera 插件**（`addons/phantom_camera/`）。运行时在 `_ready()` 动态创建 `PhantomCameraHost` + `PhantomCamera2D` 子节点：SIMPLE 跟随模式 + `follow_damping`（阻尼值 `1/follow_speed`）+ 显式 limit 四边。保留原 `@export` 接口（`follow_speed=5.0`、`default_zoom=(2,2)`、`bounds_margin`、`bound_layers`）——边界仍由 `bound_layers` 各层 `get_used_rect()` 的**并集**计算（地图小于视口时自动扩展居中）。`teleport_to_player()` 方法保留供场景切换/真正传送用，但**切换角色/死亡切换不再调用它**——切换不改玩家位置（不传送），相机继续阻尼跟随即可；旧实现瞬切会在玩家移动时把阻尼滞后的相机拉到玩家位置造成可见跳变（见开发日志 2026-08-18）。

**Phantom Camera 依赖**：`PhantomCameraManager` autoload（project.godot）+ 插件已启用（`[editor_plugins]`）。插件编辑器面板/自定义节点类型需**重启编辑器**后完全生效（运行时无需）。

---

## 图块素材（Tilesets/）

约 200+ 张 RPG Maker VX Ace 格式图块（**32×32 像素**）。A1=动画自动图块、A2=地面、A3=建筑外观、A4=墙壁、A5=普通下层、B~E=上层装饰。详细格式规范见 `engine-reference/rpgvxace-docs/rpgvxace/6100_resource.html`。

A4 墙壁自动图块 → Godot Terrain Bitmask 映射详见 **`VX动画特效与图块系统.md`** 和 `art/Tilesets/TileA4-Tw_bitmask速查表.txt`。

---

## UI 素材（art/Ui/）

HUD/血条素材，9 张 CompressedTexture2D（无 mipmap）。命名规律：`ＨＰバー`=外框、`ＨＰメーター`=填充；后缀 `Ｔ`=大尺寸(214宽)、`Ｅ`=敌人配色(红色/灰框)、`BOSS1/BOSS2`=Boss 血条框(214×82)。配套用法：外框叠加填充，填充宽度按 HP% 缩放。**现状**：尚未接入代码，是正式 HUD 待用素材。调试可视化中的手绘血条与此无关。

---

## 引擎参考文档（engine-reference/）

`engine-reference/` 包含 Godot/Unity/Unreal 的版本锁定 API 参考。**本项目使用 Godot 4.6**，编写代码时优先参考 `engine-reference/godot/`：`VERSION.md` → `deprecated-apis.md` → `breaking-changes.md` → `modules/*.md`。Godot 4.6 发布于 2026 年 1 月，LLM 知识截止 ~4.3，API 偏差风险高。
