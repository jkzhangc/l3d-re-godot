# RM2K3 → VX Ace 图块转换分析

基于 `2K_TO_VA` 工具（`C:\Users\Administrator\Downloads\2K_TO_VA\batch_convert.py`）的逆向分析，
结合项目中 `addons/vx_tilemap/` 的现有实现，梳理两种引擎的自动图块系统差异与设计原理。

---

## 1. RM2K3 Chipset 格式

RM2K3 的 chipset 是一张 **480×256** 的 PNG（16×16 px/tile，共 30×16 tile），内部划分为三个功能区域：

```
┌─────────────────┬──────────┬──────────────────┐
│   自动图块区      │  下层区   │     上层区        │
│  (x=0..192)     │(192..288)│   (288..480)     │
│  12列×16行       │ 6列×16行 │   12列×16行       │
│  16组 autotile   │ 96 tile  │   192 tile       │
│  每组 3×4 tile   │ → A5     │   → B            │
│      → A2        │          │                  │
└─────────────────┴──────────┴──────────────────┘
```

### RM2K3 自动图块单元（3×4 = 12 tile）

每个 autotile 单元占 **48×64 px**（3 列 × 4 行），12 个 tile 各有不同角色：

```
列:  0      1      2
行0: TL     ?      TR      ← 外角 / 外边
行1: BTL    ?      BTR     ← 内角
行2: ?      ?      ?       ← RM2K3 专用（大面积填充 / 过渡）※ VX Ace 丢弃
行3: BBL    ?      BBR     ← 底边
```

**关键发现**：RM2K3 的中间列（col 1）和第三行（row 2）在转换为 VX Ace 时被**完全丢弃**。
这 6 个被丢弃的 tile 是 RM2K3 引擎自行处理的"填充 tile"和"过渡 tile"，
VX Ace 的 autotile 引擎不需要它们——它通过 bitmask 从 6 个核心 tile 中推导所有组合。

---

## 2. 2K_TO_VA 转换算法

### 2.1 背景色键检测

工具用**四边采样法**自动检测 chipset 的背景色：

```python
def detect_bg_key(img):
    # 采样上边 + 下边 + 左边 + 右边的像素
    # 取出现频率最高的颜色作为背景色键
    # 原理：chipset 的四条边必然是背景色，不会被 tile 内容干扰
```

容差 80（Manhattan 距离），将匹配像素变透明。

### 2.2 A2 自动图块转换（核心逻辑）

从 RM2K3 chipset 前半部分提取 16 组 autotile（4 行 × 4 列），每组 48×64 px：

```python
# 从 3×4 网格中只提取 6 个关键 tile：
topL = src.crop((sx,      sy,      sx+16, sy+16))   # (0,0) TL 外角
topR = src.crop((sx+32,   sy,      sx+48, sy+16))   # (2,0) TR 外角
bTL  = src.crop((sx,      sy+16,   sx+16, sy+32))   # (0,1) 内角 TL
bTR  = src.crop((sx+32,   sy+16,   sx+48, sy+32))   # (2,1) 内角 TR
bBL  = src.crop((sx,      sy+48,   sx+16, sy+64))   # (0,3) 底边 BL
bBR  = src.crop((sx+32,   sy+48,   sx+48, sy+64))   # (2,3) 底边 BR

# 组装为 2×3 排列（VX Ace A2 格式）
asm = Image.new('RGBA', (32, 48))
asm.paste(topL, (0,  0))
asm.paste(topR, (16, 0))
asm.paste(bTL,  (0,  16))
asm.paste(bTR,  (16, 16))
asm.paste(bBL,  (0,  32))
asm.paste(bBR,  (16, 32))

# 2x 最近邻放大（16→32 px）→ 64×96
vx = asm.resize((64, 96), Image.NEAREST)
```

**组装后的 VX Ace A2 autotile 单元**（64×96 px = 2×3 tile @ 32px）：

```
┌──────┬──────┐
│  TL  │  TR  │  ← 外角：两侧都无同类地形
│ 外角 │ 外角 │
├──────┼──────┤
│ BTL  │ BTR  │  ← 内角：两侧都有同类地形
│ 内角 │ 内角 │
├──────┼──────┤
│ BBL  │ BBR  │  ← 底边/填充：下方无同类地形
│ 底边 │ 底边 │
└──────┴──────┘
```

每 8 组排一行，最多 2 行，输出到 512×384 的标准 A2 画布。

### 2.3 A5 下层转换

```python
# 从 chipset x=192..288（6 列 × 16 行）
# 2x 缩放 → 192×512，pad 到 256×512
a5_src = src.crop((192, 0, 288, h))       # 96×256 px → 6×16 tile @16px
a5 = a5_src.resize((192, h * 2), Image.NEAREST)  # → 192×512 @32px
```

### 2.4 B 上层转换

```python
# 从 chipset x=288..480（剩余列）
# 2x 缩放 → pad 到 512×512
b_src = src.crop((288, 0, w, h))           # 192×256 px → 12×16 tile @16px
b = b_src.resize((b_w * 2, b_h * 2), Image.NEAREST)  # → 384×512 @32px
```

---

## 3. VX Ace 自动图块结构对比

### 3.1 A2 地面自动图块（512×384）

从 2K_TO_VA 工具确认的结构：

| 属性 | 值 |
|------|-----|
| 每组尺寸 | 2 列 × 3 行 = 6 tile（64×96 px） |
| 动画帧 | 每组可垂直堆叠 3 帧（2×9 = 18 tile） |
| 布局规则 | 外角行 → 内角行 → 底边行 |
| 相关 Godot Terrain | 3×3 bitmask 匹配 |

A2 的核心设计：**6 个 tile 覆盖所有 bitmask 组合**。外角 tile 用于地形边界，
内角 tile 用于内部拐角，底边 tile 用于填充/过渡。相比 RM2K3 的 12 tile 方案更紧凑。

### 3.2 A4 墙壁自动图块（512×480）

每组 **2 列 × 5 行**：

```
(0,0) 屋顶-单个    (1,0) 屋顶-四边角
(0,1) 屋顶-TL     (1,1) 屋顶-TR       ← 上方无墙时使用（天花板面）
(0,2) 屋顶-BL     (1,2) 屋顶-BR
(0,3) 墙壁-TL     (1,3) 墙壁-TR       ← 上方有墙时使用（墙体侧面）
(0,4) 墙壁-BL     (1,4) 墙壁-BR
```

**渲染规则**：
- 上方无墙 → TL/TR 象限取行 1-2（屋顶），BL/BR 也取行 1-2（屋顶延展）
- 上方有墙 → TL/TR 象限取行 3（墙壁立面），BL/BR 取行 4（墙壁延展）
- 每个 32×32 输出 tile 由 4 个 16×16 象限拼接而成

### 3.3 A2 vs A4 关键差异

| 维度 | A2（地面） | A4（墙壁） |
|------|----------|----------|
| 单元尺寸 | 2×3 tile | 2×5 tile |
| 渲染粒度 | 完整 32×32 tile | 16×16 象限拼接 |
| 上下区分 | 无（纯 2D） | 有（屋顶/墙体=伪 3D） |
| 动画支持 | 有（3 帧叠放） | 无 |
| Godot 实现难度 | 较低（直接 bitmask→tile） | 较高（需 subtile 组合） |

---

## 4. A4 Tile 像素数据分析

通过对 `TileA4-Tw.png`（标准格式，512×480）的像素级分析，
发现了一个关键问题：**不同 group 的 16×16 象限布局不一致**。

### 4.1 分析数据

```
组0（cols 0-1）:
  Roof-TL (0,1):  4 象限各不相同 → 4 种变体
  Roof-TR (1,1):  4 象限各不相同
  Roof-BL (0,2):  4 象限各不相同
  Roof-BR (1,2):  4 象限各不相同
  Wall-TL (0,3):  仅 2 种（上下半各一）
  Wall-TR (1,3):  仅 2 种
  Wall-BL (0,4):  几乎无差异
  Wall-BR (1,4):  几乎无差异

组1（cols 2-3）:
  Roof-*:          全部 4 种变体
  Wall-TL (2,3):  无差异（均匀）
  Wall-TR (3,3):  无差异
  Wall-BL (2,4):  2-3 种变体
  Wall-BR (3,4):  2 种变体

组2（cols 4-5）:
  Roof-*:          全部 4 种变体
  Wall-*:          全部无差异（均匀色块）
```

### 4.2 结论

**VX Ace A4 的 16×16 象限布局不是跨组统一的**。每个组的 tile 艺术家
根据该墙壁纹理的特点自行决定哪些象限需要变体、哪些用均匀色块。
这意味着：

- `vx_autotile.gd` 中的 `_get_subtile_offset()` **无法用一套固定规则覆盖所有组**
- 标准格式的 subtile 拼接需要**按组校准**——每组需要知道其 4 个象限分别对应
  哪种 bitmask 情况（外角/内角/单边开放）
- **简化格式**（完整 32×32 tile + bitmask 直查表）是更实用的方案，
  因为它绕过了 subtile 选择的不确定性

---

## 5. 对 Godot TileSet 的实践启示

### 5.1 现有工具状态

| 工具 | 格式 | 状态 |
|------|------|------|
| `vx_autotile.gd` simplified（A4） | 完整 tile + bitmask 查表 | ✅ 可用（9 种 bitmask） |
| `vx_autotile.gd` simplified（A2） | 完整 tile + 自动 bitmask→坐标 | ✅ **新增**（`get_a2_local_coord()`） |
| `vx_autotile.gd` standard（A4） | 16×16 subtile 拼接 | ❌ 未校准（象限布局跨组不一致） |
| `vx_grid_config.gd` | 可序列化配置 | ✅ 可用（新增 `create_a2_config()`） |
| `vx_grid_editor.gd` | 可视化编辑器 | ✅ 可用 |
| `tileset_generator.gd` | Godot TileSet 生成 | ✅ 可用（A5/B/C/D/E，不含 A1-A4） |

### 5.2 推荐工作流

1. **A5 / B~E 普通图块** → `tileset_generator.gd` → `.tres` → `TileMapLayer`
2. **A2 地面 autotile** → `VXTileMap` 节点 + `tile_group=1`（A2）+ 简化模式，
   由 `vx_tile_data.gd::get_a2_local_coord()` 自动将 bitmask 映射到 2×3 组内坐标
3. **A4 墙壁 autotile** → 推荐简化格式（如 `TileA4-Twnew.png`），
   在 Godot TileSet 编辑器中配置 Terrain bitmask；如需标准格式（如 `TileA4-Tw.png`），
   需先对每组进行象限校准

### 5.3 Godot Terrain Bitmask 配置要点

Godot 的 Terrain 系统使用标准 3×3 bitmask（与 VX Ace 相同）：

```
bit 0 (1)   = ↑  上方有同 terrain
bit 1 (2)   = →  右侧
bit 2 (4)   = ↓  下方
bit 3 (8)   = ←  左侧
bit 4 (16)  = ↗  右上角
bit 5 (32)  = ↘  右下角
bit 6 (64)  = ↙  左下角
bit 7 (128) = ↖  左上角
```

对于 A4 墙壁，设置两个 Terrain（"墙壁顶面" + "墙壁侧面"）并建立连接规则，
可让 Godot 自动处理屋顶/墙体的切换。这本质上就是 VX Ace 引擎的 autotile 逻辑
在 Godot 中的等价实现。

### 5.4 A2 自动图块的 Godot 配置思路

基于 2K_TO_VA 工具确认的 A2 结构（2×3 = 6 tile 每组），
在 Godot 中配置单个 Terrain "地面"即可：

1. 将 6 个 tile 各自设置正确的 bitmask
2. Godot Terrain 绘制模式自动根据相邻 tile 选择正确的 tile

这比 A4 简单——不需要 terrain 之间的连接规则，也无需 16×16 subtile 组合。

### 5.5 A2 bitmask→Tile 自动映射算法

在 `vx_tile_data.gd` 的 `get_a2_local_coord()` 中实现了基于 bitmask 的自动 tile 选择。
算法根据 4 个主方向（上下左右）的邻居数量来决定使用 2×3 组中的哪个 tile：

```
邻居数 = 0 (孤立)  → 填充 tile (col=0, row=2)
邻居数 = 4 (环绕)  → 填充中央  (col=1, row=2)
邻居数 = 1 (单边)  → 外角 tile (col=0, row=0)
邻居数 = 2 (对边)  → 填充 tile (col=1, row=2)  ← 直线穿过，非拐角
邻居数 = 2 (L形)   → 内角 tile (col=1, row=1)  ← 拐角
邻居数 = 3 (三边)  → 内角 tile (col=0, row=1)
```

**原理**：VX Ace A2 的 6 个 tile 中——
- 行 0（外角行）用于地形边界的凸角（向外开放）
- 行 1（内角行）用于地形内部的凹角（被包围）
- 行 2（填充行）用于直线边、孤立块、大面积填充

RM2K3 用 12 个 tile + 引擎内部逻辑处理这些情况；VX Ace 压缩为 6 个 tile，
在 Godot 中通过上述 bitmask 映射即可等价还原。

### 5.6 本分析对 VXTileMap 代码的改进摘要

| 文件 | 改进内容 |
|------|---------|
| `vx_tile_data.gd` | 新增 `A2_GROUP_COLS/ROWS`、`A2_ANIM_FRAMES`、行/列偏移常量；新增 `get_a2_group_origin()` 和 `get_a2_local_coord()` 方法 |
| `vx_autotile.gd` | `get_source_rect()` 新增 `TileGroup.A2` 分支；新增 `_get_a2_simple_rect()`；文档标注了标准格式 subtile 校准问题及其像素分析依据 |
| `vx_grid_config.gd` | 新增 `create_a2_config()` 工厂方法，支持多组 + 可选动画帧 |

---

## 6. 参考

- **2K_TO_VA 工具**：`C:\Users\Administrator\Downloads\2K_TO_VA\batch_convert.py`
- **RPG Maker VX Ace 素材规范**：`engine-reference/rpgvxace-docs/rpgvxace/6100_resource.html`
- **RGSS3 Tileset 类**：`engine-reference/rpgvxace-docs/rgss/gc_rpg_tileset.html`
- **VX Ace 图块数据库**：`engine-reference/rpgvxace-docs/rpgvxace/3310_db_tileset.html`
- **TileA4-Twnew 格式分析**：`art/Tilesets/TileA4-Twnew_format-analysis.md`
- **TileSet 工作流指南**：`TileSet工作流完整指南.txt`
- **项目 A4 自动图块实现**：`addons/vx_tilemap/`
