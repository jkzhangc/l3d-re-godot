# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此仓库中工作时提供指导。

> **注意**：仓库中同时存在 `AGENTS.md`，该文件是旧版 CLAUDE.md 的衍生副本，内容已过时。**请忽略 `AGENTS.md`**，所有项目指导以本文件（`CLAUDE.md`）为准。

## 项目概述

**のび太的求生之路** — 一个关于野比大雄的 Left 4 Dead 2 同人游戏重制版，使用 **Godot 4.6** 构建的俯视角 2D 像素风格游戏。力求还原 L4D2 的核心机制与游戏体验。

## 项目文档

编写功能代码前请参考以下文档：
- **`游戏系统架构文档.md`** — 完整系统架构（状态机、武器、菜单、存档、物品数据）
- **`攻击系统参考.md`** — 攻击动画、子弹、弹夹/弹药、近战判定、武器槽位、消耗品热键
- **`L4D2特色机制参考.md`** — L4D2 原版机制详解（武器/敌人/导演AI/关卡/物品）
- **`L4D2缺失功能清单.md`** — 当前项目相对 L4D2 的缺失功能 + 优先实现列表
- **`导演系统设计方案.md`** — Director AI 完整设计（紧张度/节奏/生成/物品/事件）+ 5 阶段实施计划
- **`A1动画图块实现方案.md`** — VX Ace A1 水流动画 → Godot TileSet 内置动画方案 + 手动设置步骤
- **`TileSet工作流完整指南.txt`** — 图块素材 → TileSet → TileMapLayer 工作流
- **`art/Tilesets/TileA4-Tw_bitmask速查表.txt`** — A4 墙壁自动图块 → Godot Terrain Bitmask 映射表（附标注图）

## 引擎配置

- **Godot 版本**：4.6
- **物理引擎**：Jolt Physics（在 `project.godot` 中设置）
- **渲染器**：Mobile（`rendering_method="mobile"`）—— 简化 2D/2.5D 渲染
- **Windows GPU**：Direct3D 12（`d3d12`）
- **功能标签**：`4.6`、`Mobile`
- **游戏分辨率**：640×480（设计基准，HUD 布局以此为准）

## 项目规范

### 目录结构
| 目录 | 用途 |
|-----------|---------|
| `art/Characters/` | 角色精灵表 |
| `art/Tilesets/`  | 图块素材（RPG Maker VX Ace 格式，32×32） |
| `art/Animations/` | VX Ace 动画精灵表（.png 源文件，100+ 张） |
| `art/Title/`     | 标题画面素材（`title1.png` 等） |
| `art/System/`    | 系统窗口素材（RM03 格式系统窗口） |
| `art/Ui/`        | HUD/UI 素材（HP 血条框/填充、Boss 血条、GO 图标，详见下文） |
| `art/misc/`、`art/Weapon/` | 杂项与武器图标 |
| `anim/` | 动画特效场景（`.tscn`，由 VX Anim Editor 生成） |
| `script/` | GDScript 脚本文件（`.gd`） |
| `scene/`  | Godot 场景文件（`.tscn`） |
| `object/` | 可复用的游戏对象、预制体、打包场景（武器/角色/物品 `.tres` 数据资源） |
| `tres/` | TileSet 资源文件（`.tres`） |
| `shader/` | 自定义着色器文件（`.gdshader`） |
| `music/`  | 背景音乐 |
| `sound/`  | 音效 |

### 文件命名
- 美术资源使用日文描述性名称，基于内容命名（角色名、动画组）。
- 导入文件（`.import`）由 Godot 自动生成 —— 切勿直接编辑。

### GDScript 风格
- 使用 **GDScript**（而非 C#）—— 项目目标平台为 `Mobile`，与 GDScript 更为契合。
- 脚本放在 `script/` 目录，场景放在 `scene/` 目录，可复用对象/打包场景放在 `object/` 目录，动画特效场景放在 `anim/` 目录，TileSet 资源放在 `tres/` 目录。
- **Godot 4.6：lambda 不能直接作为 `connect()` 参数**，必须先赋值给 `Callable` 变量：
  ```gdscript
  # ❌ 报错: "Standalone lambdas cannot be accessed"
  timer.timeout.connect(func(): print("x"))
  # ✅ 正确
  var cb: Callable = func(): print("x")
  timer.timeout.connect(cb)
  ```

## 快速参考（开发速记）

- **场景入口**：`scene/main.tscn`
- **关卡场景标准**：`scene/maps/突袭-第一关-开头安全屋-户外.tscn`（开局安全屋）。GroundLayer→DecorLayer(y_sort)→UpperLayer(y_sort,上层装饰)。玩家/敌人必须是 **DecorLayer 子节点**。UpperLayer 不参与 A\* 寻路。详见 `memory/scene-conventions.md`
- **旧测试地图**：`scene/maps/test.tscn`
- **菜单键**：`X` / `Esc` 打开主菜单（继续游戏/设置/退出游戏）。**武器举起/攻击状态下菜单键被屏蔽**，取消键用于固定朝向。
- **设置系统**：标题画面 + 游戏内菜单均有设置选项。可调音乐音量/音效音量（0–100%、蓝色音量条）、固定朝向模式（切换式/按住式）。设置保存到 `config.json`。
- **音频总线**：Global 启动时自动创建 `SFX` / `Music` 总线。SFX 音效路由到 SFX 总线，BGM/死亡音乐路由到 Music 总线，音量通过 `AudioServer.set_bus_volume_db()` 控制。
- **固定朝向**：武器举起（READY 阶段）/攻击状态下，根据设置模式控制朝向：**切换式**=按取消键锁定/解锁；**按住式**=按住取消键锁定、松开解锁。锁定后移动不改变朝向。
- **攻击移动**：武器攻击状态下玩家可以移动（velocity 由方向键控制，朝向锁定不变）。
- **调试可视化开关**：`TAB` 键（切换碰撞体/血条/受击碰撞体调试绘制：玩家=绿色、敌人=红色、受击碰撞体=黄色、子弹/攻击触发=青色、攻击判定=橙红）
- **全局单例**：`Global` autoload（`script/global.gd`），含调试标志、文字渲染参数、色表缓存、**音频总线管理**（SFX/Music）、**音量/朝向设置**（`music_volume`/`sfx_volume`/`facing_lock_mode`）、死亡处理参数（`death_music_path` / `death_music_volume_db` 音量 / `death_fade_duration` 黑屏淡入时长 / `death_black_hold` 全黑等待时长）
- **数据资源**：物品/武器/角色等游戏数据均以 `.tres` 资源形式存在 `object/` 目录，通过 Godot Inspector 可视化编辑；玩家脚本通过 `current_character` 引用 `CharacterData` 资源。TileSet 相关的 `.tres` 资源单独存放在 `tres/` 目录
- **输入映射**：在 `project.godot` 的 `[input]` 段定义
- **HUD/血条**：`art/Ui/` 下的血条素材是**正式游戏 HUD** 专用（玩家/敌人/Boss 血条），尚未接入代码。注意 `player.gd::_draw()` 里那个手绘矩形血条是**调试可视化**（红框+绿填充，与碰撞体一起，仅在 `Global.debug_visuals` 为 true 时绘制），正式游戏不显示，二者互不相干。

### 动画系统 — 帧序列 + 每帧时长

所有动画统一使用 **"帧序列数组 + 每帧时长数组"** 模式，Inspector 可直接编辑：

| 动画类型 | 帧序列字段 | 时长字段 | 说明 |
|----------|-----------|---------|------|
| **武器举起/放下** | `weapon_raise_char_sequence: Array[int]` | `weapon_raise_frame_durations: Array[float]` | 举起正向、放下反向播放 |
| **武器攻击** | `attack_char_sequence: Array[int]` | `attack_frame_durations: Array[float]` | 空则使用默认 0.1 秒 |
| **攻击后动画** | `post_attack_char_sequence: Array[int]` | `post_attack_frame_durations: Array[float]` | 攻击帧播完后、切回举起前播放；空则跳过 |
| **武器装填（NORMAL）** | `reload_char_sequence: Array[int]` | `reload_frame_durations: Array[float]` | 播放一次 → 装弹 → 等待帧 |
| **武器装填（SHOTGUN 循环）** | `shotgun_reload_loop_char_sequence: Array[int]` | `shotgun_reload_loop_frame_durations: Array[float]` | 逐发循环（每轮装 1 发） |
| **武器装填（SHOTGUN 结束）** | `shotgun_reload_end_char_sequence: Array[int]` | `shotgun_reload_end_frame_durations: Array[float]` | 循环结束后上膛 |
| **敌人攻击** | `attack_char_sequence: Array[int]` | `attack_frame_durations: Array[float]` | 空则使用默认 0.1 秒 |
| **武器拾取踏步** | `pickup_step_frames: Array[int]` | `pickup_step_duration: float` | 单一时长应用于所有帧 |
| **玩家行走/跑步** | `WALK_SEQUENCE` 常量 | `walk/run_frame_duration` | CharacterData 驱动 |

**停顿/暂停**：不需要额外字段。把需要停顿的那帧在 `attack_frame_durations` 中设为较大值即可（如 `0.43` 秒 ≈ 20 帧暂停 + 0.1 秒帧时长）。旧版 `enemy.gd` 的 `attack_pause_after_idx` / `attack_pause_frames` 已移除。

### VX Ace 动画特效系统

**`VXAnimSprite`**（`script/vx_anim_sprite.gd`）— 播放 VX Ace 格式精灵表动画（960px 宽 = 5 列 × 192px/格）。支持三层偏移叠加：`cell.offset`（多精灵）→ `frame_offsets[N]`（每帧）→ `position_offset`（整体）。

**核心参数**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `texture` | Texture2D | — | 精灵表 |
| `h_frames` | int | 5 | 列数 |
| `fps` | float | 10.0 | 统一帧速（`frame_durations` 空时用） |
| `animation_scale` | Vector2 | (1,1) | 整体缩放 |
| `animation_rotation` | float | 0 | 整体旋转（度） |
| `position_offset` | Vector2 | (0,0) | 整体位置偏移（叠加到节点坐标） |
| `frame_offsets` | Array[Vector2] | [] | 每帧 XY 偏移（索引=帧序列号） |
| `looping` | bool | false | 循环 |
| `auto_free` | bool | true | 播完自动 queue_free |
| `frame_sequence` | Array[int] | [] | 自定义格子播放顺序（空=0,1,2...） |
| `frame_durations` | Array[float] | [] | 每帧秒数（空=用 fps） |
| `cell_data` | Array[VXAnimCellData] | [] | 多精灵配置（空=单精灵模式） |
| `follow_target` | Node2D | null | 跟随目标节点（启用后每帧跟随实体移动） |
| `follow_enabled` | bool | false | 是否开启跟随（Inspector 开关） |

**`VXAnimCellData`**（`script/vx_anim_cell_data.gd`）— 同帧多精灵时的单格数据：

| 字段 | 类型 | 说明 |
|------|------|------|
| `frame_idx` | int | 所属帧序号 |
| `pattern` | int | 格子索引 |
| `offset` | Vector2 | 相对动画中心偏移（px） |
| `scale` | Vector2 | 缩放 |
| `rotation_deg` | float | 旋转（度） |
| `opacity` | float | 0-1 透明度 |
| `blend_mode` | int | 0=Normal, 1=Additive, 2=Subtractive |
| `flip_h` | bool | 水平翻转 |

**Static 方法**：
```gdscript
# 从 .tscn 场景播放（推荐 — 支持 Inspector 拖拽 + offset_override）
var a = VXAnimSprite.play_scene(packed_scene, pos, parent)              # 基本播放
VXAnimSprite.play_scene(packed, pos, parent, 10.0, target, offset_vec)  # 跟随 + 偏移覆盖
var b = VXAnimSprite.from_scene(packed_scene, offset_override)           # 手动控制

# 旧版字符串方式（仍然可用，用于 .png 直加载）
VXAnimSprite.play_at("血", pos, parent)               # 从 art/Animations/ 加载 .png
VXAnimSprite.play_at("anim/爆炸.tscn", pos, parent)   # 从 anim/ 加载 .tscn
var c = VXAnimSprite.from_name("爆発", 15.0)          # 手动控制

# 通用属性
b.follow_target = player
b.follow_enabled = true
b.frame_sequence = [0, 2, 4, 3, 1]
b.frame_durations = [0.1, 0.1, 0.3, 0.1, 0.1]
```

**动画特效字段**（均使用 `PackedScene` 类型，Inspector 拖入 `anim/` 下的 `.tscn` 文件）：

| 位置 | 字段 | 类型 | 触发时机 |
|------|------|------|---------|
| WeaponData | `attack_effect_anim_down/left/right/up` | PackedScene | 开枪/攻击时，按玩家朝向选择对应方向特效 |
| WeaponData | `attack_effect_follow` | bool | 攻击特效是否跟随角色实体移动 |
| WeaponData | `attack_effect_offset_override` | Vector2 | 攻击特效位置偏移（叠加到 .tscn 内置 position_offset） |
| WeaponData | `hit_effect_anim` | PackedScene | 子弹/近战命中时，目标位置 |
| WeaponData | `hit_effect_follow` | bool | 命中特效是否跟随目标实体移动 |
| WeaponData | `hit_effect_offset_override` | Vector2 | 命中特效位置偏移（叠加到 .tscn 内置 position_offset） |
| Enemy | `attack_effect_anim` | PackedScene | 敌人攻击命中时，玩家位置 |
| Enemy | `attack_effect_follow` | bool | 敌人攻击特效是否跟随玩家实体移动 |
| Enemy | `attack_effect_offset_override` | Vector2 | 敌人攻击特效位置偏移（叠加到 .tscn 内置 position_offset） |

**素材目录**：`art/Animations/`（已放入 100+ 张 VX Ace 动画精灵表）。

**VX Anim Editor**（`addons/vx_anim_editor/`）— VXAnimSprite 可视化编辑器，Godot 底部面板 "VX Anim" 标签页：
- 精灵表网格视图 + 帧序列编辑 + 实时预览
- 新建/打开/保存动画为 `.tscn` 文件
- 详见 `addons/vx_anim_editor/README.md`

**实现要点**（2026-07-26 修复）：

- **`_sprites` 数组独立化**：`_ready()` 开头显式 `_sprites = []`，避免 Godot 4 类级 `Array[Sprite2D] = []` 默认值跨实例共享。共享会导致多个动画实例争抢同一个 sprite 子节点（一个实例创建 sprite 后，另一个实例的 `_sprites.size()` 也为 1，跳过创建，直接操作前者的 sprite——造成帧错乱/残影）。
- **多精灵帧索引**：`_update_multi()` 使用 `_get_actual_frame()`（返回 `frame_sequence[_seq_idx]`）匹配 `cell_data.frame_idx`，而非直接用 `_seq_idx`。
- **混合模式**：Additive/Subtractive 使用 `CanvasItemMaterial` 的 `BLEND_MODE_ADD`/`BLEND_MODE_SUB`（GPU 级混合），而非自定义 shader（原 `COLOR = src + COLOR` 会错误地将 modulate 颜色叠加到纹理上）。
- **极短帧注意**：帧持续时间 ≤0.05 秒（FPS≥20）时，人眼视觉暂留可能产生类似"残影"的效果，这是正常现象而非 bug。

### Godot 4.6 注意事项

- **Lambda 不能直接传 `connect()`**：必须先赋值给 `Callable` 变量。`timer.timeout.connect(func(): ...)` → 解析错误。
- **GDScript 类级声明无缩进**：`func`、`@export`、`@onready`、`const` 等顶格写（0 tab），只有函数体才缩进。用 `Write` 工具覆盖 `.gd` 文件时务必检查 tab。

## 美术资源

所有纹理均以 `CompressedTexture2D` 格式导入，使用默认设置（无 mipmap、无 HDR）。

### 角色（Characters/）

6 张角色精灵表：

| 角色 | 精灵表 |
|------|--------|
| **のび太（大雄）** | 待机组、行走组（`のび太歩行セット.png`）、持刀变体（`のび太セットナイフ.png`） |
| **男性僵尸** | 基础版（`男性ゾンビ1.png`）、变体2（`男性ゾンビ1-2.png`）、修正版（`男性ゾンビ1fix.png`） |

### UI 素材（Ui/）

HUD/血条素材，沿用 RPG Maker 风格命名：**バー = 条（bar，外框/底框）**、**メーター = 表盘（meter，前景填充）**，后缀区分用途与尺寸。命名规律：

| 后缀 | 含义 |
|------|------|
| 无后缀 | 小尺寸基础版（120×16，用于角色头顶血条） |
| `Ｔ`（Title） | 大尺寸版（214 宽，用于菜单/标题栏） |
| `Ｅ`（Enemy） | 敌人配色（红色填充 / 灰框） |
| `BOSS1`/`BOSS2` | Boss 血条框（214×82，两种边框变体） |
| `(heat)` | 红色填充版（疑似过热/警告状态） |

**清单（10 张，均为 `CompressedTexture2D`、无 mipmap，配置正确）：**

| 文件 | 尺寸 | 内容 |
|------|------|------|
| `ＨＰバー.png` | 120×16 | 血条**外框**（灰色边框）— 与 `ＨＰメーター.png` 配套使用 |
| `ＨＰメーター.png` | 120×16 | 血条**前景填充**（纯黄）— 玩家满血色 |
| `ＨＰメーターＥ.png` | 120×16 | 血条前景填充（纯红）— 敌人血条 |
| `ＨＰメーターＴ.png` | 210×84 | 大尺寸表盘填充（黄橙渐变） |
| `ＨＰバーＴ.png` | 214×156 | 标题/菜单栏框（深色边框，含 3 行堆叠） |
| `ＨＰバーＴ(heat).png` | 214×84 | 深色框 + 红填充（过热/警告状态） |
| `ＨＰバーＥ.png` | 120×86 | 敌人血条框（灰色） |
| `ＨＰバーBOSS1.png` | 214×82 | Boss 血条框（变体 1，深色边框） |
| `ＨＰバーBOSS2.png` | 214×82 | Boss 血条框（变体 2，边框更粗） |
| `GO.png` | 45×29 | "GO!→" 蓝底黄字按钮图标 |

> **配套用法**：血条 = 外框（`ＨＰバー.png`）叠加前景填充（`ＨＰメーター.png`/`ＨＰメーターＥ.png`），填充宽度按 `current_hp / max_hp` 缩放。
> **现状**：这批素材尚未接入代码，是正式游戏 HUD 的待用素材。注意 `player.gd::_draw()` 里那个手绘矩形血条是**调试可视化**（仅在 `Global.debug_visuals` 为 true 时与碰撞体一起绘制），正式游戏不显示，与本批 HUD 素材无关。

### 图块素材（Tilesets/）

约 200+ 张 RPG Maker VX Ace 格式图块（**32×32 像素**），按图层分类：

| 类别 | 典型图块集 |
|------|-----------|
| **通用 TileA–TileE** | 涵盖地面、墙壁、地形、建筑、家具、装饰等标准 RPG Maker 图层 |
| **室外场景** | `Outside_*`、`Outside2_*`、`街_*`、`森_*`、`森2_*`、`空き地` |
| **室内/地下城** | `Inside_*`、`Dungeon_*`、`楼层_*` |
| **建筑主题** | 学校外观/内观、医院/病院、旅馆、洋馆、洋馆酒吧、酒场、雄家 |
| **特殊场景** | 研究所电车、最重要机密实验室、机械/工厂、公园+厕所、城堡 |
| **世界地图** | `World_A1`、`World_A2`、`World_B` |
| **杂项** | `Abyss1` 系列、`map.png`、`奨3.png`、`1.png`、`2.png` |

### 图块格式规范（RPG Maker VX Ace）

来源：`engine-reference/rpgvxace-docs/rpgvxace/6100_resource.html`

所有图块均为 **32×32 像素**，分为 A~E 五组：

| 组 | 文件尺寸 | 用途 | 说明 |
|----|---------|------|------|
| **A1** | 512×384 | 动画自动图块（海洋、深水、瀑布） | 5 个 block，block A~D 可动画 |
| **A2** | 512×384 | 地面自动图块 | 4 组×4 行，分 Field Type / Area Type |
| **A3** | 512×256 | 建筑外观自动图块 | 8×4 排列，自动生成阴影 |
| **A4** | 512×480 | 墙壁自动图块 | 8×3 排列，用于地牢生成 |
| **A5** | 256×512 | 普通下层图块 | 8×16 排列，非自动图块 |
| **B~E** | 512×512 | 上层装饰图块 | 16×16 排列，B 组左上角必须留空 |

**角色精灵格式：**
- 标准角色：4 方向（下左右上）× 3 帧，文件内 4 列×2 行（共 8 角色）
- 文件名加 `!` 前缀：取消 4 像素偏移 + 草丛半透明效果（用于门、宝箱等物件）
- 文件名加 `$` 前缀：单角色文件，尺寸变为宽 1/3、高 1/4

### A4 墙壁自动图块 → Godot Bitmask 映射

A4 图块（512×480）是 RPG Maker VX Ace 的墙壁自动图块。与 A1/A2 不同，A4 的每组 autotile 不是固定的 8×3，**实际分组取决于具体素材的排列**（例如 `TileA4-Tw.png` 实测为 8×5=40 tile/组，共 6 组）。

**原理**：VX Ace 的自动图块根据相邻 tile 是否为同种墙壁，动态选择正确的边角 tile。Godot 中通过 **TileSet Terrain + 3×3 Bitmask** 实现等价效果——bitmask 的 8 个 bit 分别代表当前 tile 周围 8 个方向是否有同类墙壁。

**参考文件**（均在 `art/Tilesets/` 下）：
| 文件 | 内容 |
|------|------|
| `TileA4-Tw_bitmask速查表.txt` | 文字映射表：局部坐标 → 角色名 → bitmask 值 |
| `TileA4-Tw_全局概览.png` | 全局分组图（6 组 × 8 列 × 5 行） |
| `TileA4-Tw_图例模板.png` | 单组 8×5 模板 + 角色/bitmask 图例 |
| `TileA4-Tw_bitmask标注.png` | 原尺寸标注图 |
| `TileA4-Tw_bitmask标注_4x.png` | 4x 放大标注图 |

**bitmask 速查**（每组行 0~2，共 24 个主体 tile）：

```
行0(外角/外边): TL外38  T边110  TR外76  L边55  中央255  R边205  BL外19  B边155
行1(内角/内边): BR外137 TL内118 T内110  TR内236 L内55  中央B255 R内205  BL内179
行2(底边/孤立): B内155  BR内137 TL孤0  T孤0   TR孤0   L孤0    C孤0    R孤0
```

> 行 3~4（底部过渡 tile）的 bitmask 需在 Godot 编辑器里看图确认，暂标为 0。

### A4 图块转换器（A4変換器.rb）

**`A4转换器.rb`** 是运行在 RPG Maker VX Ace 内部的 **RGSS3 脚本**，将标准 A4 图块组（2列×5行）重新展开为完整的 tileset 网格（含合成过渡 tile），输出 `A4-new.png`。原始版本备份在 `A4转换器_原始备份.txt`。

**运行方式**：在 VX Ace 脚本编辑器中粘贴全部代码 → 运行游戏 → 按 C 键退出（脚本末尾的 loop）。输出文件生成在游戏目录下。

**参数**：
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `$tile_w_index` | 5 | 图块组横索引（0–7），每组 64px 宽 |
| `$tile_h_index` | 1 | 图块组纵索引（0–2），每组 160px 高 |

> 源图 `TileA4-Tw.png` (512×480) = 8 组宽 × 3 组高 = 24 组。`$tile_w_index=5, $tile_h_index=1` 选第 2 行第 6 列那组。

**源格式**（VX Ace 标准 A4，单组 2 列 × 5 行 = 10 tile）：

| | col0 | col1 |
|--|------|------|
| row0 | 屋顶-单个 | 屋顶-四边角 |
| row1 | 屋顶TL | 屋顶TR |
| row2 | 屋顶BL | 屋顶BR |
| row3 | 墙壁TL | 墙壁TR |
| row4 | 墙壁BL | 墙壁BR |

**目标 new 格式输出布局**（`newbitmap` 512×480）：

```
y=0:   (0,0)屋顶单     (32,0)屋顶全角
y=32:  (0,32)屋顶TL    (32,32)屋顶中上   (64,32)屋顶TR   ─┬─ (96,32) 外角4×4网格
y=64:  (0,64)屋顶左中  (32,64)屋顶中     (64,64)屋顶右中   │  col=TL/TR, row=BL/BR
y=96:  (0,96)屋顶BL    (32,96)屋顶中下   (64,96)屋顶BR   ─┘  (96..224, 32..160)
y=128: (0,128)墙壁TL   (32,128)墙壁中上  (64,128)墙壁TR
y=160: (0,160)墙壁左中 (32,160)墙壁中    (64,160)墙壁右中
y=192: (0,192)墙壁BL   (32,192)墙壁中下  (64,192)墙壁BR
y=224: (0,224)内角TL   (32,224)内角TR    (64,224)内角BL  (96,224)内角BR
y=256: (96,256)仅顶底  (128,256)仅左右   (160,256)缺顶   (192,256)缺底  (224,256)缺左  (256,256)缺右
```

**构造方式概览**：

| 类别 | 数量 | 构造方法 |
|------|------|---------|
| 屋顶 3×3 主体 | 9 | 4 角直接 blit + 4 边从相邻 tile 各取半拼接 + 中心从 4 tile 交界取 |
| 外角变体 | 16 | 墙壁基底 + 屋顶四边角 16×16 角碎片叠加（4×4 网格，行列编码角组合） |
| 墙壁 3×3 主体 | 9 | 同上手法，从源行3-4 纯墙壁 tile 拼接 |
| 内角 | 4 | 两个 roof 象限（带 roofline 内壁）+ 屋顶内墙面填充（`rw_x, rw_y`） |
| 平行边 | 2 | 屋顶-单 底图 + 屋顶内墙面覆盖无 roofline 边 |
| T 形 | 4 | 屋顶-四边角 底图 + 屋顶内墙面覆盖缺失边 |

> **关键约定**：内角、平行边、T 形的"墙面"部分**必须从屋顶 tile 的内部取**（`rw_x=wx+16, rw_y=wy+48`，即 屋顶TL 右下 16×16 纯墙区），不能引用纯墙壁 tile，以保证墙面纹理与 roofline 色调一致。纯墙壁 tile（源行3-4）仅用于"墙壁 3×3"行。

**已实现 vs 待补充**：

| 状态 | 内容 |
|------|------|
| ✅ 已实现 | 屋顶 3×3、外角 16 种、墙壁 3×3、内角 4 种、平行边 2 种、T 形 4 种 |
| ❌ 未实现 | 遍历全部 24 组（当前只转一组）、阴影行（不需要）、屋顶更多边角组合 |

## RPG Maker VX Ace 帮助文档

完整引擎文档已从 Steam 安装目录解压至：
**`engine-reference/rpgvxace-docs/`**（来源：`D:\SteamLibrary\steamapps\common\RPGVXAce\RPGVXAce.chm`）

| 目录/文件 | 内容 |
|-----------|------|
| `rpgvxace/` | 编辑器操作手册（地图编辑、数据库设置、事件命令等） |
| `rgss/` | RGSS3（Ruby Game Scripting System 3）完整 API 参考 |
| `rpgvxace/6100_resource.html` | **素材格式规范**（图块、角色、图标、音视频） |
| `rpgvxace/3310_db_tileset.html` | 图块数据库设置（通行度、梯子、草丛、柜台等属性） |
| `rgss/gc_rpg_tileset.html` | Tileset 类的 RGSS 数据结构定义 |

编写与图块素材相关的代码时，请参考 `rpgvxace/6100_resource.html` 了解素材格式约束。

## 开发命令

```bash
# 在 Godot 编辑器中启动项目
godot --editor

# 直接运行游戏（调试模式）
godot --editor --debug

# 运行游戏（非调试模式）
godot

# 运行指定场景
godot scene/main.tscn

# 无头运行（用于 CI / 自动化检查）
godot --headless --quit

# 导出项目
godot --headless --export-release "Windows Desktop" build/game.exe
```

## 当前状态

项目处于**核心战斗循环搭建阶段**。已有功能：

| 系统 | 状态 | 说明 |
|------|------|------|
| 标题画面 | ✅ 可用 | RM2K3 风格窗口 + 光标动画 + 20 色表采样 + 粗体/描边/阴影 + **纵向渐变** |
| 角色选择 | ⚠️ 占位 | 仅显示"开发中"文字 |
| 主菜单 | ✅ 可用 | 物品/装备双面板 + 存档 + 退出 |
| 玩家角色 | ✅ 可用 | 完整状态机（待机/行走/跑步/手枪/小刀/霰弹枪/步枪）；外观/HP/音效由 CharacterData 驱动 |
| 武器系统 | ✅ 可用 | 手枪/小刀/霰弹枪/步枪/冲锋枪举起放下 + 攻击 + 弹夹/装填 + 拾取/替换/掉落 + **WeaponSlot 枚举**（主/副武器）+ **BulletData** 子弹列表 + **FireMode**（TAP点按/HOLD连发）+ 碰撞体方向旋转 |
| 装填系统 | ✅ 可用 | `PlayerReloadState`：NORMAL 模式（一次装满）+ SHOTGUN 模式（逐发循环+结束上膛）；装填动画 + 音效 + 共用等待帧 + 朝向锁定；**装填期间可移动**（仅位移，朝向不变） |
| 攻击后动画 | ✅ 可用 | 攻击帧播完后可选播放 `post_attack_char_sequence` + `post_attack_sound`，再切回武器举起 |
| 霰弹枪 | ✅ 可用 | `weapon_shotgun.tres`，3发散射 + 穿透(2) + 击退 + SHOTGUN 逐发装填 + 攻击后动画；复用 Pistol 状态脚本，纯数据驱动 |
| 步枪 | ✅ 可用 | `weapon_rifle.tres`，攻击力 30 + HOLD 按住连发 + 30发弹夹 + ammo_rifle；复用 Pistol 状态脚本 |
| 冲锋枪 | ✅ 可用 | `weapon_smg.tres`，攻击力 20 + HOLD 按住连发 + 30发弹夹 + ammo_smg + 硬直 0.1s；与步枪共用 Rifle 状态 |
| 子弹实体 | ✅ 可用 | Node2D + Sprite2D + Area2D（collision_mask=24 层4+5）+ **发射者排除** + **目标永久去重** + **尸体穿透** + 碰撞矩形随方向旋转（Area2D 节点偏移到精灵中心再旋转，避免 offset 被旋转带偏）+ debug 可视化（TAB 青色绘制） |
| 敌人 AI | ✅ 可用 | 状态机（待机/发现/追击(**A\*寻路**)/攻击/**击退**/硬直/死亡/爆头）+ **受击碰撞体**（HurtArea）+ 暴击率判定 + 攻击矩形拆分；**A\***：TileMapLayer 格子可通行性 + 八方向搜索 + 共线平滑 + 推离墙壁 + 降级模式 + 失败退避 + 实体障碍(敌人互绕+多人接口) + static 地图缓存共享 + TAB 调试可视化(路径线/红绿格子) |
| 寻路系统 | ✅ 可用 | 详见下文「敌人 A* 寻路系统」 |
| 死亡系统 | ✅ 可用 | 死亡精灵 + 渐黑遮罩（CanvasLayer）+ 自动重载存档；黑屏时长（淡入/全黑等待）与死亡音乐音量均在 Global 单例可配 |
| 角色参数 | ✅ 可用 | CharacterData 资源统一管理行走图/HP/音效，player.gd 通过 `current_character` 引用 |
| 地图编辑 | ✅ 可用 | 运行时图块编辑器 + TileSet 生成器 |
| 存档系统 | ✅ 可用 | JSON 存档 + 自动保存 + L4D2 风格死亡重载 |
| 文字渐变 | ✅ 可用 | CPU 预渲染 + 人工亮度渐变（SubViewport → Image → ImageTexture） |
| 武器拾取物 | ✅ 可用 | 地图放置 + 自动拾取/长按替换 + **替换时旧武器掉落地面** + **弹药随武器转移（弹夹+备弹）** + 掉落至 GroundLayer 节点下 + 踏步动画 |
| 战斗 HUD | ✅ 可用 | CanvasLayer (layer=10) — HP 血条（左上）+ 5 槽位竖排快捷栏（右侧垂直居中）。武器名称/弹药显示在框内。可见性支持总/分开关 |
| 伤害数字 | ✅ 可用 | `DamageNumber`（Node2D + GradientLabel + CanvasLayer）；渐变上浮+缓动+淡出；字体/颜色/粗体/阴影/偏移/时长全部 Inspector 可配 |
| 受击碰撞体 | ✅ 可用 | 玩家和敌人各有 `HurtArea`（Area2D + RectangleShape2D），位于碰撞层 5；攻击判定统一通过受击碰撞体 |
| 相机跟随 | ✅ 可用 | 平滑跟随玩家 + 基于 GroundLayer/DecorLayer tile 范围的边界限制 |

### 碰撞层系统

所有物理体和检测区域使用以下碰撞层分配：

| 层 | Bit | 用途 |
|----|-----|------|
| 1 | 1 | 墙壁/地面（TileMapLayer） |
| 3 | 4 | 玩家物理体 (CharacterBody2D) |
| 4 | 8 | 敌人物理体 (CharacterBody2D) |
| **5** | **16** | **受击碰撞体 (HurtArea)** — 玩家和敌人的可命中区域 |

**攻击检测矩阵**：

| 攻击类型 | collision_mask | 检测目标 |
|---------|---------------|---------|
| 子弹 (Area2D) | 24 (层4+5) | 敌人物理体 + 受击碰撞体 |
| 近战 hitbox (Area2D) | 24 (层4+5) | 敌人物理体 + 受击碰撞体 |
| 敌人视野 (VisionArea) | 15 (层1-4) | 玩家物理体（不含受击碰撞体） |

### 受击碰撞体 (HurtArea)

**2026-07-28 新增** — 玩家和敌人各自在 `_ready()` 中动态创建 `HurtArea` 节点（Area2D + RectangleShape2D），作为统一的受击判定区域。

**配置**（Inspector 可调）：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `hurtbox_size` | Vector2 | (28, 44) | 受击碰撞体尺寸 |
| `hurtbox_offset` | Vector2 | (0, -8) | 受击碰撞体偏移（相对角色原点） |

**行为**：
- 位于碰撞层 5（bit 16），不检测任何东西（`collision_mask=0`）
- **死亡时自动禁用**：玩家死亡 → `hurt_area.monitoring/monitorable = false`；敌人变成尸体 → 同上
- **Debug 可视化**：TAB 键切换，黄色矩形绘制

**攻击去重机制（三层防护）**：
- **第1层 — 子弹侧永久去重**：`_hit_targets: Dictionary`（`instance_id` → `true`），一旦命中永久标记，同一子弹绝不对同一目标重复判定。body_entered + area_entered 双重触发只生效一次
- **第2层 — 目标侧源头去重**：`take_damage()` 新增 `source_id: int = 0` 参数。敌人/玩家的 `_recent_damage_sources` 字典追踪 1 秒内的伤害来源，同一 `source_id` 拒绝重复判定。向后兼容（`source_id=0` 跳过检查）
- **第3层 — 近战去重**：`_check_melee_hits()` 按 `instance_id` 去重，遍历 bodies + areas 统一去重
- 子弹记录 `_shooter` 引用，**防止击中发射者自己**（子弹 mask=24 会检测到玩家的 HurtArea）

**尸体穿透**：
- 子弹 `_hit()` 在去重后、计数前检查 `_is_dead` / `_is_dying`，尸体直接跳过 —— 不消耗穿透、不播放命中特效
- 近战 `_check_melee_hits()` 通过 `_is_target_dead()` 跳过尸体
- 敌人攻击 `_do_attack_hit()` 跳过已死亡玩家和已死亡敌人（友军伤害）

### 武器拾取物

**`script/weapon_pickup.gd`** — 地图放置的武器拾取节点，支持自动拾取/长按替换 + 踏步动画。

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `weapon_data` | WeaponData | — | 要给予的武器资源 |
| `pickup_texture` | Texture2D | — | 地上显示的精灵表 |
| `pickup_char_idx` | int | 0 | 精灵表中的角色索引（选角色） |
| `pickup_direction` | int | 0 | 朝向（0=下, 1=左, 2=右, 3=上） |
| `pickup_reserve_ammo` | int | 0 | 拾取时给予的备弹数量（对应 weapon_data.ammo_item_id） |
| `pickup_magazine_ammo` | int | -1 | 拾取时弹夹子弹数（-1=自动填满弹夹容量，0=空弹夹） |
| `pickup_step_frames` | Array[int] | `[1, 0, 1, 2]` | 踏步帧序列（与玩家行走帧一致） |
| `pickup_step_duration` | float | 0.25 | 每帧持续时间（秒） |
| `pickup_animated` | bool | true | 是否启用踏步动画（关闭=静态站立帧） |
| `hold_time` | float | 1.2 | 按住替换所需时长（秒） |
| `hold_indicator_enabled` | bool | true | 是否启用按住进度指示器（圆环填充动画） |
| `hold_indicator_radius` | float | 18.0 | 指示器圆环半径（像素） |
| `hold_indicator_thickness` | float | 3.0 | 圆环线宽（像素） |
| `hold_indicator_offset` | Vector2 | (0, -48) | 指示器位置偏移（相对拾取物原点） |
| `hold_indicator_color` | Color | 金色 (1, 0.9, 0.2) | 进度填充颜色 |
| `hold_indicator_bg_color` | Color | 暗色半透明 | 背景圆环颜色 |
| `hold_indicator_fade_speed` | float | 5.0 | 淡入淡出速度（alpha/秒） |

**渲染公式**：`x = char_col * 144 + frame * 48`，`y = char_row * 256 + direction * 64`

**拾取逻辑**：
- 该槽位为空 → 自动拾取装备
- 槽位已有武器 → 按住确定键（Space/Z）替换（默认 1.2 秒，`hold_time` 可配）
- **按住进度指示器**：按住时拾取物上方显示金色圆环顺时针填充，淡入淡出动画（`hold_indicator_*` 系列参数可配，`hold_indicator_enabled=false` 可关闭）
- **不再限制武器举起/攻击状态**（`_can_hold_pickup()` 仅检查玩家是否在范围内）
- **拾取范围内禁止攻击**：玩家进入拾取物范围时设置 `_near_pickup` 标志，武器 READY 状态检测到此标志后跳过攻击触发，确保按住替换不被攻击动画打断

**替换掉落**（`_drop_weapon()`）：
- 旧武器生成为新的 WeaponPickup，掉落在玩家脚下
- **远程武器**：弹夹子弹和备弹一并转移到拾取物（`pickup_magazine_ammo` / `pickup_reserve_ammo`），同时从 Global 清除
- 掉落物添加到 **GroundLayer** 节点下（`find_child("GroundLayer")` 递归查找，回退到场景根）

**WeaponData 地面显示字段**（控制掉落武器的外观）：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `pickup_texture` | Texture2D | — | 掉落在地面时的精灵表。**为空时回退到 `weapon_walk_texture` + 举起序列首帧 char_idx + 面朝下**（2026-07-28 修复：避免所有掉落武器显示为手枪图像） |
| `pickup_char_idx` | int | 0 | 精灵表中的角色索引（仅在 `pickup_texture` 非空时使用） |
| `pickup_direction` | int | 0 | 朝向（0=下, 1=左, 2=右, 3=上）（仅在 `pickup_texture` 非空时使用） |
| `pickup_step_frames` | Array[int] | [] | 地面踏步帧序列（空=使用 WeaponPickup 默认序列 `[1, 0, 1, 2]`） |
| `pickup_step_duration` | float | 0.0 | 地面踏步每帧时长秒（0=使用默认 0.25s） |
| `pickup_animated` | bool | true | 地面是否播放踏步动画 |

**WeaponData 武器类型字段**：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `is_ranged` | bool | true | true=远程, false=近战 |
| `weapon_slot` | `enum WeaponSlot` | `PRIMARY` | `PRIMARY`=主武器, `SECONDARY`=副武器 |

> **`WeaponSlot` 枚举**（2026-07-26）：`PRIMARY`（主武器，如步枪/冲锋枪）和 `SECONDARY`（副武器，如手枪/小刀）。每个武器只能二选一。`get_slot_key()` 返回 `"primary"` / `"secondary"` 字符串用于 `Global.equipment` 字典查找。存档序列化为 int（0/1），反序列化兼容旧版字符串格式。

### BulletData 子弹数据

**`script/bullet_data.gd`** — `class_name BulletData extends Resource`，封装单颗子弹的全部配置。由 `WeaponData.bullet_list: Array[BulletData]` 引用，每次攻击遍历列表发射所有子弹。每颗子弹可独立设置外观、弹道、角度/方向、按朝向的额外偏移。

| 分组 | 字段 | 类型 | 默认值 | 说明 |
|------|------|------|--------|------|
| 外观 | `bullet_texture` | Texture2D | — | 子弹精灵图（水平帧条，单帧宽=图宽/动画帧数） |
| | `bullet_anim_frames` | int | 1 | 水平排列的动画帧数 |
| | `bullet_frame_duration` | int | 1 | 每帧持续的物理帧数 |
| 弹道 | `speed` | float | 300.0 | 飞行速度 |
| | `max_range` | float | 300.0 | 最大飞行距离 |
| | `damage` | float | 0.0 | 子弹伤害（0=使用武器 attack_power） |
| | `destroy_on_hit` | bool | true | 击中后是否消失 |
| | `penetration` | int | 0 | 穿透数（0=单目标） |
| | `spawn_offset` | float | 24.0 | 生成位置的前方偏移 |
| 方向控制 | `angle_offset` | float | 0.0 | 相对朝向旋转角度（度），正=顺时针 |
| | `direction_override` | Vector2 | (0,0) | 非零时覆盖为绝对方向，忽略朝向和角度 |
| 方向偏移 | `offset_down/up/left/right` | Vector2 | — | 按角色朝向的额外偏移 |
| 击退 | `knockback_enabled` | bool | false | 是否启用击退 |
| | `knockback_force` | float | 200.0 | 击退力度（像素/秒） |
| | `knockback_stun_duration` | float | 0.5 | 击退后硬直时长（秒） |
| 碰撞体 | `collision_size` | Vector2 | (0,0) | 碰撞矩形尺寸（0=使用默认 24×28） |
| | `collision_offset` | Vector2 | (0,0) | 碰撞体中心在子弹局部空间的位置（设到精灵中心如 `(24,32)` 可避免旋转时偏移） |

**方法**：
- `get_effective_damage(attack_power)` — 返回子弹伤害（>0 用自身，否则回退武器攻击力）
- `get_extra_offset(facing)` — 根据角色朝向返回额外偏移
- `get_fire_direction(base_dir)` — 计算最终发射方向（优先级：direction_override > angle_offset > base_dir）

**使用示例**：在 `bullet_list` 添加 3 颗 BulletData，分别设 `angle_offset = -15, 0, 15` → 三发散射。

### 子弹实体

**`script/bullet.gd`** — `class_name Bullet extends Node2D`，运行时子弹节点。由 `PlayerPistolAttackState._fire_bullet()` 从 `object/bullet.tscn` 实例化。

**渲染方式**：单张水平帧条图片（`art/Barrages/`），均分为 `bullet_anim_frames` 列。每帧宽 = 图宽 / 帧数，帧 X = `当前帧索引 × 单帧宽`。精灵旋转跟随飞行方向（图片默认朝 RIGHT = 0°）。

**场景结构**：
```
Bullet (Node2D)
├── Sprite2D (pos 0,-5)  ← 水平帧条精灵，region_rect 按动画帧选列
├── Area2D                ← collision_mask=24（层4+层5），rotation 跟随方向
│   └── CollisionShape2D  ← RectangleShape2D，尺寸/偏移可由 BulletData 覆盖
```

**关键方法**：

| 方法 | 说明 |
|------|------|
| `setup(params)` | 从字典批量设置参数（direction/speed/damage/penetration/collision_size/collision_offset/**anim_frames/frame_duration**/knockback_force/knockback_stun/shooter 等） |
| `_refresh_sprite()` | 水平帧条渲染：`frame_w = tex_w / anim_frames`，`region_rect = Rect2(frame * frame_w, 0, frame_w, tex_h)` + **sprite.rotation = direction.angle() - PI/2**（纹理默认朝 DOWN） |
| `_apply_collision_shape()` | 设置碰撞矩形尺寸；将 `collision_offset` 应用到 `Area2D.position`（而非 `CollisionShape2D.position`），使旋转围绕精灵中心而非 bullet 原点 |
| `_update_area_rotation()` | 将 `Area2D.rotation` 设为 `direction.angle()`，碰撞矩形对齐飞行方向 |
| `_hit(target)` | 伤害判定 + **目标解析**（area→parent）+ **永久去重**（`_hit_targets` Dictionary）+ **发射者排除** + **尸体跳过** + 暴击掷骰 + 击退参数传递 + 传入 `source_id=get_instance_id()` 供目标侧去重 + 播放命中特效/音效 |
| `_draw()` | 青色（Cyan）绘制旋转+偏移后的碰撞矩形（TAB 键切换） |

**命中流程**（2026-07-28 更新）：
1. 解析真正可伤害目标（若传入 HurtArea 则取其 parent CharacterBody2D）
2. 检查 `take_damage` 方法存在性
3. **永久去重**：目标 `instance_id` 在 `_hit_targets` Dictionary 中 → 跳过（防 body + hurtbox 双重触发，同一子弹永久只判定一次）
4. **发射者排除**：`_shooter` 不为空且目标=发射者 → 跳过
5. **尸体跳过**：`_is_dead` 或 `_is_dying` → 跳过（不消耗穿透、不播特效）
6. `_hits += 1`，掷骰暴击，调用 `take_damage(..., source_id=get_instance_id())`（传入子弹 ID 供目标侧源头去重），播放特效/音效

**⚠️ `@onready` 时序注意**：`setup()` 在 `add_child()` **之前**调用，此时 `@onready` 变量尚未初始化。`_apply_collision_shape()`（含 Area2D 节点定位）和 `_update_area_rotation()` 均使用 `$` 路径直查（降级 fallback），不能依赖 `@onready` 缓存引用。

**碰撞体位置实现**（2026-07-28 修正）：
- `CollisionShape2D.position = Vector2.ZERO`（形状原点对齐 Area2D 原点）
- `Area2D.position = _collision_offset`（整个检测区移到精灵中心）
- 这样 `Area2D.rotation` 围绕精灵中心旋转，碰撞体不会因为旋转而偏移到奇怪位置

### 远程武器空弹机制

**空弹检查**在 `PlayerPistolAttackState.enter()` 开头完成：
- 弹夹为空 → 播放 `WeaponData.empty_fire_sound` → 立即切回 `Pistol` 状态（不播放攻击动画、不发射子弹）
- 有弹药 → 正常进入攻击动画 → `_fire_bullet()` 消耗弹药并生成子弹

**`WeaponData` 新增字段**：`empty_fire_sound: AudioStream`（空弹音效，Inspector 可配）

**BulletData 碰撞体字段**：`collision_size: Vector2`（0=使用默认 24×28）、`collision_offset: Vector2`（碰撞体偏移）

### 敌人攻击矩形系统

敌人攻击使用**两个独立矩形**，拆分触发与判定：

| 矩形 | 字段 | 用途 | Debug 颜色 | 检测位置 |
|------|------|------|-----------|---------|
| **触发矩形** | `attack_range` + `attack_range_forward_offset` | 玩家进入 → 追击→攻击 | **青色** (CYAN) | `EnemyChaseState.process_update()` |
| **命中矩形** | `attack_hit_range` + `attack_hit_forward_offset` | 攻击动画中判定伤害 | **橙红** (ORANGE_RED) | `EnemyAttackState._do_attack_hit()` |

两者均在 `enemy.gd:_draw()` 中绘制（TAB 键切换），跟随敌人朝向旋转。

**矩形检测算法 — 统一投影法**（2026-07-25 统一）：

```gdscript
# 将目标相对向量投影到前方轴（纵向）和侧方轴（横向）
# 四个方向统一，不再区分左/右和上/下
func _is_target_in_hit_rect(to_target, fv, half_w, half_h):
    var fwd = to_target.dot(fv)                      # 前方投影
    var lat = to_target.dot(Vector2(-fv.y, fv.x))    # 侧方投影
    return abs(fwd) <= half_h and abs(lat) <= half_w
```

> **注意**：追击触发判定（`EnemyChaseState`）和攻击命中判定（`EnemyAttackState`）均使用此统一投影法。近战武器（`PlayerKnifeAttackState`）使用 **Area2D hitbox** 方案（创建临时 `Area2D` + `get_overlapping_bodies()`），与敌人矩形判定不同。

### 子弹击退系统

**BulletData** 中启用击退后，子弹命中敌人触发 `EnemyKnockbackState`：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `knockback_enabled` | bool | false | 启用击退 |
| `knockback_force` | float | 200.0 | 击退力度（像素/秒初速） |
| `knockback_stun_duration` | float | 0.5 | 硬直时长（秒） |

**数据流**：`BulletData` → `PlayerPistolAttackState._fire_bullet()` → `bullet.setup()` → `bullet._hit()` → `target.take_damage(dmg, force, dir, headshot, stun)` → enemy 设置 `_knockback_dir/force/stun` → StateMachine → `"Knockback"`

**EnemyKnockbackState**（`script/enemy/EnemyKnockbackState.gd`）：
- `enter()`: 速度 = `dir × force`，朝向伤害来源
- `physics_update()`: 每帧 `move_and_collide(velocity × delta)`，线性减速（600px/s²）
- `process_update()`: 倒计时 stun → 0 → 切换到 `"Chase"`
- 死亡检查：`guard_dead()` 可在击退期间触发死亡转换

### 敌人硬直系统（Hitstun）

被击中后敌人原地冻结片刻，无击退位移。与击退的区别：
- **击退（Knockback）**：沿子弹方向推开 + 硬直
- **硬直（Hitstun）**：原地冻结，无位移

**数据来源**：

| 武器类型 | 配置位置 | 字段 | 优先级 |
|---------|---------|------|--------|
| 远程 | `BulletData.hitstun_duration` | >0 使用自身，=0 回退到 `WeaponData.hitstun_duration` |
| 近战 | `WeaponData.hitstun_duration` | 直接使用 |

**数据流**：
- 远程：`BulletData.hitstun_duration`（或回退 `WeaponData`）→ `_fire_bullet()` → `bullet.setup()` → `bullet._hit()` → `enemy.take_damage(dmg, force, dir, headshot, stun, hitstun)` → `_hitstun_duration` → StateMachine → `"Hitstun"`
- 近战：`WeaponData.hitstun_duration` → `_check_melee_hits()` → `enemy.take_damage(..., hitstun)` → 同上

**优先级**：击退优先于硬直。如果同时有击退参数（`knockback_force > 0 && knockback_stun > 0`），硬直不生效。

**Idle 状态特殊处理**：敌人未发现玩家时被命中，硬直不生效，先进入 Discover 状态（"！" 发现动画）。**硬直仅在追击（Chase）状态下生效**，攻击（Attack）和发现（Discover）状态不打断。击退不受此限制（强物理反馈，可打断攻击/发现）。

**远程武器回退**：`BulletData.hitstun_duration = 0` 时自动回退到 `WeaponData.hitstun_duration`，与伤害的 `get_effective_damage()` 模式一致。只需在 WeaponData 上设 `hitstun_duration` 即可让所有子弹生效。

**EnemyHitstunState**（`script/enemy/EnemyHitstunState.gd`）：
- `enter()`: 读取 `_hitstun_duration`，冻结移动，朝向伤害来源
- `physics_update()`: 完全不移动（pass）
- `process_update()`: 倒计时 → 0 → 切换到 `"Chase"`
- 死亡检查：`guard_dead()` 可在硬直期间触发死亡转换

### 战斗 HUD 系统

**`script/ui/hud.gd`** — CanvasLayer 主脚本：
- **HP 血条**（左上角，位置可配）：`ＨＰバー.png` 外框 + `ＨＰメーター.png` 填充（`size.x` 按 HP% 裁剪）；低血量(<30%)变红
- **HP 数值标签**：独立 CanvasLayer 子节点，屏幕绝对坐标定位（不受布局容器限制），可单独显隐
- **槽位栏**（右侧垂直居中，位置可配）：5 个竖排槽位，每槽包含热键+图标+名称+弹药/数量

**`script/ui/hud_slot.gd`** — 单个槽位（104×52）：
- 槽位 1/2 = 主/副武器（从 `Global.equipment` 读取 WeaponData）— 显示名称 + 弹夹 "12/15" + **备弹 "备弹 20"**
- 槽位 3/4 = 治疗/辅助品（从 `Global.healing_item` / `Global.support_item`）— 显示名称 + 背包数量 "x3"
- 槽位 5 = 投掷品（预留，空槽位显示 "—"）
- 选中槽位金色高亮 + 空槽位灰色
- 远程武器备弹从 `Global.count_ammo_item(wd.ammo_item_id)` 读取，灰色小字显示在弹夹下方

**可见性控制**（全部 `@export`，Inspector 实时可调）：
- `hud_visible` — 总开关
- `hp_bar_visible` — HP 血条单独
- `hp_label_visible` — HP 数值标签单独
- `slot_bar_visible` — 槽位栏单独

**布局参数**（全部 `@export`，Inspector 实时生效）：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `hp_bar_pos` | Vector2 | `(6, 6)` | HP 血条屏幕坐标 |
| `hp_label_offset` | Vector2 | `(2, 0)` | HP 数值标签偏移 |
| `slot_bar_pos` | Vector2 | `(0, 0)` | 槽位栏坐标；`(0,0)`=自动右侧居中 |

### 伤害数字弹出系统

**`DamageNumber`**（`script/damage_number.gd`）— `class_name DamageNumber extends Node2D`，被击中时从目标位置浮起渐变数字。

使用 `GradientLabel`（渐变路径），与标题画面共用字体、着色器（text_color.gdshader）、色表系统。所有伤害数字共用一个 `CanvasLayer`（layer=100）。

**快速使用**：
```gdscript
DamageNumber.spawn(global_position, damage, get_tree().current_scene)
# 可选参数：col_idx（色表列）, mod_col（颜色叠加）
```

**全部 `@export` 参数**（Inspector 可调）：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `amount` | float | 0 | 伤害数值 |
| `font_path` | String | SimsunXS | 字体路径 |
| `color_index` | int | 1 | 色表颜色索引（0–19） |
| `color_row` | int | 0 | 色表颜色行（0–3，明暗变体） |
| `font_size` | int | 16 | 字号 |
| `bold` | bool | false | 粗体（1px 偏移叠加，开启后文字更亮） |
| `shadow_enabled` | bool | true | 阴影 |
| `rise_distance` | float | 20 | 上浮距离（像素） |
| `duration` | float | 1.0 | 显示时长（秒） |
| `use_easing` | bool | true | 是否使用缓动 |
| `easing_type` | enum | EASE_OUT_CUBIC | 缓动函数（9 种可选） |
| `modulate_color` | Color | White | 颜色叠加 |
| `position_offset` | Vector2 | (0, -30) | 整体位置偏移（相对目标，像素） |

**9 种缓动**：`LINEAR` / `EASE_IN_QUAD` / `EASE_OUT_QUAD` / `EASE_IN_OUT_QUAD` / `EASE_OUT_CUBIC` / `EASE_OUT_EXPO` / `EASE_OUT_BACK` / `EASE_OUT_ELASTIC` / `EASE_OUT_BOUNCE`

**GradientLabel 属性顺序**（⚠️ 重要）：资源路径（`font_path_override`、`color_sheet_path_override`、`color_shader_path_override`）必须在 `add_child` **之前**设，防止 `_enter_tree()` → `_resolve_paths()` 回退到 Global；效果属性（`use_gradient`、`color_index`、`bold`、`shadow` 等）必须在 `add_child` **之后**设，因为 `_enter_tree()` → `_load_defaults_from_global()` 会用 Global 值覆盖。

**音效并发限制**：`Global.play_sfx_managed()`（`script/global.gd`）— 同一音效最多同时播放 `max_sfx_concurrency`（默认 3）个实例，超出丢弃。防止多个相同音效叠加导致音量过大。

**调用位置**：
- `player.gd:take_damage()` — 玩家受伤弹出红色调数字
- `enemy.gd:take_damage()` — 敌人受伤弹出白/金色（爆头）数字

### 敌人 A* 寻路系统

**`script/enemy/EnemyChaseState.gd`** — 基于 TileMapLayer 格子数据的 A* 寻路（2026-07-30 重写，2026-08-02 修复）。

**网格构建**：
- 格子大小 32×32（与 TileSet 一致）
- 地图缓存为 `static var _tile_walk_cache`，所有敌人共享，全图只查一次，**不在 enter() 中清空**（地图数据不变，缓存永久有效）
- TileMapLayer 列表为 `static var _tilemaps`，**只在首个敌人进入 Chase 时搜索一次**，后续敌人直接复用
- **层识别规则**（按 TileMapLayer 节点名）：
  - 名含 `"upper"` → 跳过（上层装饰，不参与寻路）
  - 名含 `"wall"` → 始终不可行走
  - 名含 `"decor"` → 检查 TileData 碰撞体（`get_collision_polygons_count(0) > 0`），有碰撞才阻挡，无碰撞视为透明装饰
  - 名含 `"ground"` / `"floor"` → 可行走

> **⚠️ 重要**：DecorLayer（`街道B.tres`）上**有碰撞多边形的 tile 会阻挡 A* 寻路**。给装饰层 tile 加碰撞体时需注意——加了碰撞的 tile 将视为障碍物，A* 会绕开。物理碰撞是亚像素精度，但 A* 是整格（32×32）判定：只要 tile 有碰撞多边形，整格都不可通行。

**A* 搜索**：
- **四方向邻居**（上下左右，禁止斜线），曼哈顿距离启发式，统一代价 1.0，最大 2000 次迭代
- 路径平滑：去除连续同方向中间点，只保留方向变化点（拐弯点）
- **碰撞体感知推墙**（`_push_from_walls`）：每个路径点按敌人碰撞体半尺寸 + 4px 推开，自由方向不限制
- 起点检测使用 `_is_walkable_no_entity()`（跳过实体障碍检查，避免敌人重合时寻路失败）

**移动**（以撒风格）：
- 敌人使用 `MOTION_MODE_FLOATING`（俯视角），**`up_direction` 不能设为 `Vector2.ZERO`**（Godot 4 会在 C++ 层报错）。浮空模式下 `up_direction` 无需设置，保持默认即可
- `_move_with_stuck_recovery`：`move_and_collide` 全速滑墙（slide 后重新归一化到全速），最多 6 次迭代
- 卡住检测：位移 < 1.5px 时追加 3 次硬推恢复
- 敌人之间正常物理碰撞，滑墙自然推开

**路径跟踪**：
- 距离判定推进：`WAYPOINT_RADIUS=16px` 内切下一点
- 每 `REPATH_INTERVAL=0.5s` 重算路径

**实体障碍（敌人互绕）**：
- 用 `intersect_point`（collision_mask=8, enemy 层）实时检测其他敌人占据的格子
- 多人模式接口：`extra_obstacle_nodes: Array[Node2D]`
- 实体检测不缓存（每帧实时），地图层永久缓存

**降级模式**：
- 连续寻路失败 `FALLBACK_THRESHOLD=2` 次 → 切到直接追击 + 滑墙
- 每 `REPATH_FAIL_INTERVAL=3s` 检查玩家是否移动超过 `REPATH_FAIL_MOVE_DIST=48px`，满足则尝试恢复 A*

**TAB 调试可视化**：
- 绿色连线 + 绿圈 = A* 路径，黄色大圈 = 当前目标点
- 蓝色框 = 起点格子，红色框 = 终点格子
- 绿色半透明 = 已探测可通行格子，红色半透明+❌ = 墙壁格子
- 左上角状态文字：`OK:N` 或 `FAIL(iters:N)`

### 相机跟随与地图边界

**`script/camera_follow.gd`** — Camera2D 扩展脚本，挂载到测试场景的 Camera2D 节点。

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `follow_enabled` | bool | true | 是否启用跟随 |
| `follow_speed` | float | 5.0 | 平滑速度（越大越快，1=瞬间） |
| `limit_to_map` | bool | true | 启用地图边界限制 |
| `bounds_margin` | float | 32.0 | 边界缓冲（像素） |
| `bound_layers` | Array[NodePath] | `["../GroundLayer", "../DecorLayer"]` | TileMapLayer 路径 |

**边界计算**：遍历 `bound_layers` 中每个 TileMapLayer 的 `get_used_rect()`，取并集作为地图边界。视口边缘不超过地图边界+缓冲。

**自动查找玩家**：递归搜索 `CharacterBody2D` + `has_method("get_weapon_data")`。

### 文字渲染系统

统一使用 **`GradientLabel`**（`script/gradient_label.gd`）渲染渐变文字，内部自动选择路径：

```
GradientLabel（统一接口）
  ├─ use_gradient = true  → TextGradientRenderer → TextureRect（渐变纹理）
  └─ use_gradient = false → Label + shader 纯色（关掉渐变）
```

**核心类**：
- **`GradientLabel`**（`script/gradient_label.gd`）— 对外统一节点，封装双路径 + bold/shadow/outline
- **`TextGradientRenderer`**（`script/text_gradient_renderer.gd`）— 渐变引擎：SubViewport 光栅化 → 逐像素亮度渐变 → ImageTexture
- **`shader/text_color.gdshader`** — 非渐变路径着色器（纯色 + 可选描边）

**效果**：
- **粗体**：1px 右偏移叠加
- **阴影**：偏移 + 暗色叠加，z_index = -1
- **描边**：渐变路径用 CPU 端 8 邻域边缘检测，非渐变路径用 shader 检测
- **全局默认**：`script/global.gd` 中 `@export` 文字渲染参数，GradientLabel 在 `_enter_tree()` 时自动同步
- **色表缓存**：`Global.get_cached_color_image()` 避免重复 I/O

### 已解决：纵向渐变

TTF 字体 + canvas_item shader 的 `UV.y` 是字体图集全局坐标，无法做逐字形渐变。通过 **CPU 端 SubViewport 预渲染 + 人工亮度渐变** 绕过此限制，封装为 `GradientLabel` 统一接口。详见 `文字渐变实现方案.md`。

### VXTileMap — VX Ace 自动图块节点（⚠️ 实验性）

**`addons/vx_tilemap/`** 是一个 Godot 编辑器插件，提供 `VXTileMap` 自定义节点 + 底部面板可视化网格编辑器。

**已知限制**：
- 16×16 subtile 拼接索引尚未校准——标准格式渲染结果不正确
- `TileA4-Tw.png`（标准 A4）和 `TileA4-Twnew.png`（简化格式）格式完全不同，不可互换
- 当前仅简化格式（`use_standard_format=false`）使用完整 tile 映射，bitmask 覆盖不全

**A4 格式理解**（已确认 — TileA4-Tw.png 标准 VX Ace A4：每组 2列×5行，6组，共 16列×15行=240 tile）：
```
标准 2×5/组:                   TileA4-Twnew (简化):
(0,0)屋顶-单个 (1,0)屋顶-四边角   行0: TL外  T边  TR外
(0,1)屋顶TL    (1,1)屋顶TR       行1: L边  中央  R边
(0,2)屋顶BL    (1,2)屋顶BR       行2: BL外  B边  BR外
(0,3)墙壁TL    (1,3)墙壁TR       行3: 内角TL 内壁A 内角TR 内壁B
(0,4)墙壁BL    (1,4)墙壁BR       行4: 阴影L  阴影C  阴影R  阴影BR
```

**渲染规则**（理论正确，subtile偏移待修）：
- TL/TR 象限：上方无墙→屋顶，上方有墙→墙壁
- BL/BR 象限：下方无墙→屋顶（延伸），下方有墙→墙壁（立面）

**文件结构**：
| 文件 | 用途 |
|------|------|
| `addons/vx_tilemap/plugin.gd` | EditorPlugin — 注册节点 + 画布交互 + 底部面板注册 |
| `addons/vx_tilemap/vx_tilemap.gd` | 核心节点（`class_name VXTileMap extends Node2D`）；导出 `grid_config: VXGridConfig`，渲染优先使用 config，回退硬编码 |
| `addons/vx_tilemap/vx_autotile.gd` | Autotile 引擎（两种模式：simplified + standard subtile） |
| `addons/vx_tilemap/vx_tile_data.gd` | 数据结构（TileGroup 枚举、bitmask 常量、A4 组布局、硬编码映射表——作为默认值/回退） |
| `addons/vx_tilemap/vx_grid_config.gd` | **NEW** `VXGridConfig` Resource — 可序列化的网格配置（纹理、组布局、区域列表、bitmask 映射）。通过 `regions: Array[Dictionary]` 定义屋顶/墙体矩形区域 |
| `addons/vx_tilemap/vx_grid_editor.gd` | **NEW** 底部面板可视化编辑器 — 纹理+网格预览、拖拽绘制区域、区域列表管理、3×3 bitmask 编辑、快速预设、组导航 |

**VXGridEditor 底部面板**：
- 打开 Godot 编辑器 → 底部 "VX Grid" 标签页
- **区域管理**：点击 `[+区域]` → 选类型+命名 → 在纹理上拖拽绘制矩形区域
- **区域可视化**：屋顶区域=绿色、墙体区域=蓝色、选中区域=黄色高亮
- **Bitmask 分配**：3×3 邻居复选框 + 快速预设按钮 → `[分配屋顶]`/`[分配墙体]` 模式点击 tile
- **组导航**：◀ ▶ 切换组，当前组橙色高亮
- **保存/加载**：配置存为 `.tres` 文件，可在 VXTileMap 节点的 `grid_config` 属性中引用

**待解决**：
- 标准格式 `_get_subtile_offset()` 中 16×16 区域偏移量需对照实际素材校准
- 简化格式需补全 bitmask→tile 映射表
- 区域与 bitmask 分配的整合（目前区域只用于可视化标识，不直接影响渲染）

## 引擎参考文档（engine-reference/）

`engine-reference/` 目录包含三大游戏引擎的版本锁定 API 参考文档。这些文档的存在是因为 LLM 的知识截止日期（2025 年 5 月）早于各引擎的最新版本，直接使用模型训练数据中的 API 可能会产生过时或错误的代码。

### 文档结构
```
engine-reference/
├── README.md                           # 目录说明与维护指南
├── godot/
│   ├── VERSION.md                      # 版本信息
│   ├── breaking-changes.md             # 版本间的破坏性变更
│   ├── deprecated-apis.md              # 已废弃 API 对照表
│   ├── current-best-practices.md       # 模型训练数据之外的新最佳实践
│   └── modules/                        # 各子系统快速参考
│       ├── animation.md, audio.md, input.md, navigation.md
│       ├── networking.md, physics.md, rendering.md, ui.md
├── unity/
│   ├── VERSION.md, breaking-changes.md, deprecated-apis.md, current-best-practices.md
│   ├── PLUGINS.md
│   ├── modules/ (同上 8 个子系统)
│   └── plugins/ (addressables.md, cinemachine.md, dots-entities.md)
└── unreal/
    ├── VERSION.md, breaking-changes.md, deprecated-apis.md, current-best-practices.md
    ├── PLUGINS.md
    ├── modules/ (同上 8 个子系统)
    └── plugins/ (common-ui.md, gameplay-ability-system.md, gameplay-camera-system.md, pcg.md)
```

### 各引擎版本

| 引擎 | 版本 | 发布日期 | LLM 知识截止 | 风险 |
|------|------|----------|-------------|------|
| **Godot** | 4.6 | 2026 年 1 月 | ~4.3 | 高 — 4.4/4.5/4.6 有重大变更 |
| **Unity** | 6.3 LTS | 2025 年 12 月 | ~2022 LTS | 高 — Unity 6 系列全面重构 |
| **Unreal** | 5.7 | 2025 年 11 月 | ~5.3 | 高 — 5.4/5.5/5.6/5.7 有重大变更 |

### 使用原则

编写引擎相关代码时应遵循以下顺序：
1. 先读对应引擎的 `VERSION.md` 确认版本
2. 查 `deprecated-apis.md` 避免使用已废弃 API
3. 查 `breaking-changes.md` 了解版本间的破坏性变更
4. 根据当前任务读取相关 `modules/*.md`

**当前项目使用 Godot 4.6**，编写代码时请优先参考 `engine-reference/godot/` 下的文档。
