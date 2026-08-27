# AGENTS.md

本文件为 AI 编程助手（ZCode 等）在此仓库中工作时提供指导。

> 说明：本文件由项目原有的 `CLAUDE.md` 转换而来，并整合了 `memory/project-status.md` 中的项目记忆。原始文件保留未删除，以便回溯。

## 项目概述

**のび太的求生之路** — 一个关于野比大雄的 Left 4 Dead 2 同人游戏重制版，使用 **Godot 4.6** 构建的俯视角 2D 像素风格游戏。力求还原 L4D2 的核心机制与游戏体验。

## 项目文档

编写功能代码前请参考以下文档：
- **`游戏系统架构文档.md`** — 完整系统架构（状态机、武器、菜单、存档、物品数据）
- **`攻击系统参考.md`** — 攻击动画、子弹、弹夹/弹药、近战判定、武器槽位、消耗品热键
- **`L4D2特色机制参考.md`** — L4D2 原版机制详解（武器/敌人/导演AI/关卡/物品）
- **`L4D2缺失功能清单.md`** — 当前项目相对 L4D2 的缺失功能 + 优先实现列表
- **`TileSet工作流完整指南.txt`** — 图块素材 → TileSet → TileMapLayer 工作流
- **`art/Tilesets/TileA4-Tw_bitmask速查表.txt`** — A4 墙壁自动图块 → Godot Terrain Bitmask 映射表（附标注图）

## 引擎配置

- **Godot 版本**：4.6
- **物理引擎**：Jolt Physics（在 `project.godot` 中设置）
- **渲染器**：Mobile（`rendering_method="mobile"`）—— 简化 2D/2.5D 渲染
- **Windows GPU**：Direct3D 12（`d3d12`）
- **功能标签**：`4.6`、`Mobile`

## 项目规范

### 目录结构
| 目录 | 用途 |
|-----------|---------|
| `art/Characters/` | 角色精灵表 |
| `art/Tilesets/`  | 图块素材（RPG Maker VX Ace 格式，32×32） |
| `art/Title/`     | 标题画面素材（`title1.png` 等） |
| `art/System/`    | 系统窗口素材（RM03 格式系统窗口） |
| `art/Ui/`        | HUD/UI 素材（HP 血条框/填充、Boss 血条、GO 图标，详见下文） |
| `art/misc/`、`art/Weapon/` | 杂项与武器图标 |
| `script/` | GDScript 脚本文件（`.gd`） |
| `scene/`  | Godot 场景文件（`.tscn`） |
| `object/` | 可复用的游戏对象、预制体、打包场景 |
| `shader/` | 自定义着色器文件（`.gdshader`） |
| `music/`  | 背景音乐 |
| `sound/`  | 音效 |

### 文件命名
- 美术资源使用日文描述性名称，基于内容命名（角色名、动画组）。
- 导入文件（`.import`）由 Godot 自动生成 —— 切勿直接编辑。

### GDScript 风格
- 使用 **GDScript**（而非 C#）—— 项目目标平台为 `Mobile`，与 GDScript 更为契合。
- 脚本放在 `script/` 目录，场景放在 `scene/` 目录，可复用对象/打包场景放在 `object/` 目录。

## 快速参考（开发速记）

- **场景入口**：`scene/main.tscn`
- **菜单键**：`X` / `Esc` 打开主菜单（物品/装备双面板 + 存档 + 退出）
- **全局单例**：`Global` autoload（`script/global.gd`），含调试标志、文字渲染参数、色表缓存，以及死亡处理参数（`death_music_path` / `death_music_volume_db` 音量 / `death_fade_duration` 黑屏淡入时长 / `death_black_hold` 全黑等待时长）
- **数据资源**：物品/武器/角色均以 `.tres` 资源形式存在 `object/` 目录，通过 Godot Inspector 可视化编辑；玩家脚本通过 `current_character` 引用 `CharacterData` 资源
- **输入映射**：在 `project.godot` 的 `[input]` 段定义
- **HUD/血条**：`art/Ui/` 下的血条素材是**正式游戏 HUD** 专用（玩家/敌人/Boss 血条），尚未接入代码。注意 `player.gd::_draw()` 里那个手绘矩形血条是**调试可视化**（红框+绿填充，与碰撞体一起，仅在 `Global.debug_visuals` 为 true 时绘制），正式游戏不显示，二者互不相干。

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

项目处于**核心战斗循环与局域网合作模式并行开发阶段**。已有功能：

| 系统 | 状态 | 说明 |
|------|------|------|
| 标题画面 | ✅ 可用 | RM2K3 风格窗口 + 光标动画 + 20 色表采样 + 粗体/描边/阴影 + **纵向渐变**；可进入单人或联机流程 |
| 角色选择 | ✅ 可用 | 单人和联机大厅均可完成角色选择；联机由 Host 统一确认与开局 |
| 主菜单 | ✅ 可用 | 物品/装备双面板 + 存档 + 退出 |
| 玩家角色 | ✅ 可用 | 完整状态机覆盖待机/移动/枪械/近战/推击/投掷等基础动作；外观、HP、音效由 CharacterData 驱动 |
| 武器与物品 | ✅ 可用 | 多类枪械、近战武器、治疗/辅助品、燃烧瓶/手雷基础投掷、拾取/替换与 Host 权威共享拾取 |
| 敌人 AI | ✅ 可用 | 状态机（待机/发现/追击/攻击/击退/死亡/爆头）+ 暴击率判定；普通尸潮和特感仍待扩展 |
| Director | ✅ Phase 1–3 | 已接入紧张度、节奏/生成、物品投放、场景参数、安全门和传送点的基础编排；特感/Boss 调度待 Phase 4 |
| 安全门/章节流程 | 🧪 基础闭环 | 安全门确认、章节总结与场景推进已接入；救援、团灭恢复与完整战役验收待补齐 |
| 局域网联机 | 🧪 开发/回归中 | ENet 大厅/握手/选角、Host 权威移动战斗、敌人/子弹/掉落物同步及 Client 请求式拾取已接入；默认 UDP 27015，完整多人战役仍未验收 |
| 死亡系统 | ✅ 可用 | 死亡精灵 + 渐黑遮罩（CanvasLayer）+ 自动重载存档；黑屏时长（淡入/全黑等待）与死亡音乐音量均在 Global 单例可配 |
| 角色参数 | ✅ 可用 | CharacterData 资源统一管理行走图/HP/音效，player.gd 通过 `current_character` 引用 |
| 地图编辑 | ✅ 可用 | 运行时图块编辑器 + TileSet 生成器 |
| 存档系统 | ✅ 可用 | JSON 存档 + 自动保存 + L4D2 风格死亡重载；联机 Host 存档恢复仍待设计 |
| 文字渐变 | ✅ 可用 | CPU 预渲染 + 人工亮度渐变（SubViewport → Image → ImageTexture） |

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
