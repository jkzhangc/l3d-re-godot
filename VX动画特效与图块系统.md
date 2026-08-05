# VX 动画特效与图块系统

本文档包含 VX Anim Sprite 动画特效系统的完整参数参考，以及 VXTileMap/A4 图块转换器的详细说明。日常开发参考 CLAUDE.md 即可，需要查具体参数时看本文档。

---

## VXAnimSprite 动画特效

**`script/vx_anim_sprite.gd`** — 播放 VX Ace 格式精灵表动画（960px 宽 = 5 列 × 192px/格）。支持三层偏移叠加：`cell.offset`（多精灵）→ `frame_offsets[N]`（每帧）→ `position_offset`（整体）。

### 核心参数

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

### VXAnimCellData

**`script/vx_anim_cell_data.gd`** — 同帧多精灵时的单格数据：

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

### Static 方法

```gdscript
# 从 .tscn 场景播放（推荐 — 支持 Inspector 拖拽 + offset_override）
var a = VXAnimSprite.play_scene(packed_scene, pos, parent)
VXAnimSprite.play_scene(packed, pos, parent, 10.0, target, offset_vec)

# 旧版字符串方式（仍然可用）
VXAnimSprite.play_at("血", pos, parent)
VXAnimSprite.play_at("anim/爆炸.tscn", pos, parent)

# 手动控制
var b = VXAnimSprite.from_scene(packed_scene, offset_override)
var c = VXAnimSprite.from_name("爆発", 15.0)
b.follow_target = player
b.follow_enabled = true
```

### 动画特效字段（WeaponData / Enemy）

均使用 `PackedScene` 类型，Inspector 拖入 `anim/` 下的 `.tscn` 文件：

| 位置 | 字段 | 类型 | 触发时机 |
|------|------|------|---------|
| WeaponData | `attack_effect_anim_down/left/right/up` | PackedScene | 开枪/攻击时，按玩家朝向选择 |
| WeaponData | `attack_effect_follow` | bool | 攻击特效是否跟随角色 |
| WeaponData | `attack_effect_offset_override` | Vector2 | 攻击特效位置偏移 |
| WeaponData | `hit_effect_anim` | PackedScene | 子弹/近战命中时 |
| WeaponData | `hit_effect_follow` | bool | 命中特效是否跟随目标 |
| WeaponData | `hit_effect_offset_override` | Vector2 | 命中特效位置偏移 |
| Enemy | `attack_effect_anim` | PackedScene | 敌人攻击命中时 |
| Enemy | `attack_effect_follow` | bool | 敌人攻击特效是否跟随玩家 |
| Enemy | `attack_effect_offset_override` | Vector2 | 敌人攻击特效位置偏移 |

### 实现要点

- **`_sprites` 数组独立化**：`_ready()` 开头显式 `_sprites = []`，避免 Godot 4 类级 `Array[Sprite2D] = []` 默认值跨实例共享
- **多精灵帧索引**：`_update_multi()` 使用 `_get_actual_frame()` 匹配 `cell_data.frame_idx`，而非直接用 `_seq_idx`
- **混合模式**：Additive/Subtractive 使用 `CanvasItemMaterial` 的 `BLEND_MODE_ADD`/`BLEND_MODE_SUB`（GPU 级混合）
- **极短帧**：帧持续时间 ≤0.05 秒时，视觉暂留可能产生"残影"效果，属正常现象

### VX Anim Editor

`addons/vx_anim_editor/` — 底部面板 "VX Anim" 标签页：精灵表网格视图 + 帧序列编辑 + 实时预览。详见 `addons/vx_anim_editor/README.md`。

---

## VXTileMap — VX Ace 自动图块节点（⚠️ 实验性）

`addons/vx_tilemap/` 是 Godot 编辑器插件，提供 `VXTileMap` 自定义节点 + 底部面板可视化网格编辑器。

**已知限制**：
- 16×16 subtile 拼接索引尚未校准——标准格式渲染结果不正确
- `TileA4-Tw.png`（标准 A4）和 `TileA4-Twnew.png`（简化格式）格式完全不同，不可互换
- 当前仅简化格式（`use_standard_format=false`）使用完整 tile 映射，bitmask 覆盖不全

### 文件结构

| 文件 | 用途 |
|------|------|
| `addons/vx_tilemap/plugin.gd` | EditorPlugin |
| `addons/vx_tilemap/vx_tilemap.gd` | 核心节点（`class_name VXTileMap extends Node2D`） |
| `addons/vx_tilemap/vx_autotile.gd` | Autotile 引擎（simplified + standard subtile 两种模式） |
| `addons/vx_tilemap/vx_tile_data.gd` | 数据结构（TileGroup 枚举、bitmask 常量、A4 组布局） |
| `addons/vx_tilemap/vx_grid_config.gd` | `VXGridConfig` Resource — 可序列化网格配置 |
| `addons/vx_tilemap/vx_grid_editor.gd` | 底部面板可视化编辑器 |

### VXGridEditor 底部面板

- 打开 Godot 编辑器 → 底部 "VX Grid" 标签页
- **区域管理**：`[+区域]` → 选类型+命名 → 在纹理上拖拽绘制矩形区域（屋顶=绿色、墙体=蓝色、选中=黄色）
- **Bitmask 分配**：3×3 邻居复选框 + 快速预设按钮
- **组导航**：◀ ▶ 切换组，当前组橙色高亮
- **保存/加载**：配置存为 `.tres` 文件

---

## A4 图块转换器（A4変換器.rb）

**`A4转换器.rb`** 是运行在 RPG Maker VX Ace 内部的 RGSS3 脚本，将标准 A4 图块组（2列×5行）重新展开为完整 tileset 网格（含合成过渡 tile），输出 `A4-new.png`。原始版本备份在 `A4转换器_原始备份.txt`。

**运行方式**：在 VX Ace 脚本编辑器中粘贴全部代码 → 运行游戏 → 按 C 键退出。输出文件生成在游戏目录下。

**参数**：
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `$tile_w_index` | 5 | 图块组横索引（0–7），每组 64px 宽 |
| `$tile_h_index` | 1 | 图块组纵索引（0–2），每组 160px 高 |

> 源图 `TileA4-Tw.png` (512×480) = 8 组宽 × 3 组高 = 24 组。

### 源格式（VX Ace 标准 A4，单组 2 列 × 5 行）

| | col0 | col1 |
|--|------|------|
| row0 | 屋顶-单个 | 屋顶-四边角 |
| row1 | 屋顶TL | 屋顶TR |
| row2 | 屋顶BL | 屋顶BR |
| row3 | 墙壁TL | 墙壁TR |
| row4 | 墙壁BL | 墙壁BR |

### 构造方式概览

| 类别 | 数量 | 构造方法 |
|------|------|---------|
| 屋顶 3×3 主体 | 9 | 4 角直接 blit + 4 边从相邻 tile 拼接 + 中心从 4 tile 交界取 |
| 外角变体 | 16 | 墙壁基底 + 屋顶四边角 16×16 角碎片叠加 |
| 墙壁 3×3 主体 | 9 | 从源行3-4 纯墙壁 tile 拼接 |
| 内角 | 4 | 两个 roof 象限 + 屋顶内墙面填充 |
| 平行边 | 2 | 屋顶-单底图 + 屋顶内墙面覆盖 |
| T 形 | 4 | 屋顶-四边角底图 + 屋顶内墙面覆盖缺失边 |

> **关键约定**：内角、平行边、T 形的"墙面"部分必须从屋顶 tile 内部取（`rw_x=wx+16, rw_y=wy+48`），不能引用纯墙壁 tile，以保证墙面纹理与 roofline 色调一致。

**状态**：屋顶 3×3、外角 16 种、墙壁 3×3、内角 4 种、平行边 2 种、T 形 4 种已实现。遍历全部 24 组、阴影行、更多边角组合未实现。

---

## A4 墙壁自动图块 → Godot Bitmask 映射

A4 图块（512×480）是 RPG Maker VX Ace 的墙壁自动图块。与 A1/A2 不同，A4 的每组 autotile 不是固定的 8×3，实际分组取决于具体素材排列（例如 `TileA4-Tw.png` 实测为 8×5=40 tile/组，共 6 组）。

**原理**：VX Ace 根据相邻 tile 是否为同种墙壁动态选择边角 tile。Godot 中通过 **TileSet Terrain + 3×3 Bitmask** 实现等价效果。

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
