# RM2K3 → VX Ace → Godot 图块转换说明

## 重要原则

这不是把 RM2K3 图片直接改名成 VX Ace，也不是把 VX Ace 的 A1/A2/A3/A4 PNG 直接交给 Godot。

转换分为两层：

```text
RM2K3 ChipSet  →  VA 中间图集  →  Godot 完整 32×32 图块 atlas
```

- `*_VA.png`：用于检查 VA 风格的分区、组和动画帧排布。
- `*_godot.png`：每格都是完整 32×32 tile，才能交给 Godot `TileSetAtlasSource`。
- `*_mapping.json`：记录源区域、目标区域、图块坐标、帧参数和校准警告。

## 使用

```bash
python rm2k3_to_va.py "E:/15.L3D/ChipSet/01 - 仜.bmp" --output "D:/project/art/Tilesets/converted"
```

Windows：

```bat
convert_chipset.bat "E:\15.L3D\ChipSet\01 - 仜.bmp" "D:\project\art\Tilesets\converted"
```

可选参数：

```bash
--groups A1,A2,A3,A4,A5,B,C,D,E
--scale 2
--frames 3
--frame-duration 0.3
```

## 输入格式

支持：

- RM2K3 `.xyz`（`XYZ1 + zlib + palette`）
- 480×256 PNG
- 480×256 8-bit BMP

## 输出

对每个请求的类型输出：

```text
芯片名_A1_VA.png
芯片名_A1_godot.png
...
芯片名_mapping.json
芯片名_report.json
```

`*_godot.png` 是 Godot 可使用的普通图块 atlas；它不再依赖 Godot 对 VX Ace 自动图块格式的理解。

## 各类型说明

- **A1**：水面、海洋、河流、动画自动图块。动画帧需要按实际 RM2K3 block 标定后横向排列。
- **A2**：地面自动图块。不能把 RM2K3 左侧自动区无条件当成 A2；需要确认原始语义后再做六 tile 组装。
- **A3**：建筑自动图块，独立输出，不能套用 A2 的组布局。
- **A4**：墙壁自动图块。不同组的 16×16 象限布局可能不同，报告会标记 `needs_calibration`。
- **A5**：普通下层图块，转换为完整 32×32 普通 atlas。
- **B/C/D/E**：分别输出，保留源区域和索引，不混成一个无法追踪的图集。

当前脚本会对自动图块输出结构化的 VA/Godot 检查图和映射记录；A1/A2/A3/A4/D/E 的真正语义校准仍需依据芯片组和 RM2K3 编辑器确认，报告不会静默宣称完全等价。

### ⚠ `*_VA.png` 与 `*_godot.png` 当前逐像素相同（2026-09-11 实测）

上文「`*_VA.png` 仅用于检查、Godot 必须用 `*_godot.png`」在**当前实现**下没有实质差别：
`REGIONS` 全是规整 16px 网格，`crop(rect)` 后 ×N 与「逐格 crop 后 resize」在数学上等价。
实测两张样例芯片组的 9 组产物全部 `ImageChops.difference(...).getbbox() is None`（尺寸也相同）。
这只是把「VA 中间态 / Godot 终态」的分层契约留在代码结构里，**不要据此认为二者内容不同**。
真正有语义差异的是下面 §A1–A4 全图案管道（它才真的做了象限拼装）。

## A1–A4 全图案 atlas（Godot 可直接使用）— `rm2k3_autotile_atlas.py`

`rm2k3_to_va.py` 输出的 A1–A4 是**矩形裁切**，每个自动图块只是 3×4 的碎片拼贴，
不是 Godot 能用的一格一图。要真正给 Godot 用，走 `rm2k3_autotile_atlas.py`：

```bash
python rm2k3_autotile_atlas.py "奨3.png" --output "art/Tilesets/rm2k3_auto/autotiles"
```

输出（`--scale 2` → 每格 32×32）：

```text
芯片名_A1_patterns.png            2 个自动图块 × 48 个完整图案（16×12 瓦片）
芯片名_A1_water1_frames.png       水体 1 的 3 帧（3 列 = 连续帧，6 行 = 示意格）
芯片名_A1_water2_frames.png       水体 2 的 3 帧
芯片名_A2_patterns.png            2 个自动图块
芯片名_A2_waterfall_frames.png    瀑布 3 帧
芯片名_A3_patterns.png            4 个自动图块
芯片名_A4_patterns.png            4 个自动图块
芯片名_A1A4_report.json           逐块源矩形 / 格位 / variant 映射 / 校准状态
```

### 「全图案」格式的来源与取舍

格式取自参考转换器（くらむぼん）的**附加素材 / おまけ**输出：单个自动图块展开成
**48 个完整瓦片，8 列 × 6 行**。48 就是 3×3 邻接位掩码的有效组合数，因此每格都是
完整 32×32 瓦片，可直接喂 `TileSetAtlasSource`，不需要引擎理解复合格式。

两处与参考转换器的**有意差异**：

1. **格位顺序**：参考的おまけ表把「源块原样」和「拼装图案」混排，格位不构成变体索引。
   本模块默认 `--layout variant`，格位 = 互异图案顺序，并在报告里给出
   `variant_to_slot` / `slot_to_variant`，可直接配 Godot TileSet Terrain。
   `--layout reference` 可还原参考原摆法用于对照。
2. **画布宽度**：参考输出 16×16 瓦片（行 6–7 / 14–15 留空）；本模块按块数压紧为
   16×12 瓦片，不浪费空行。

### 关于 variant 数量的一个实测结论

`export_map.py` 的 `D_QUARTER_OFFSETS` 实为 **50 项，但只有 48 个互异图案**：
表内 `0` / `47` / `48` 是同一个「四面相邻＝内部填充」图案。映射图块 ID
`4000 + 50*group + variant` 时 `variant` 可取 0–49，全部都能经
`variant_to_slot` 落到 48 个格位之一。据此也可确认自动图块源块是 **48×64px（3×4 瓦片）**，
象限索引 `qx∈0..2, qy∈0..3`，不存在越出源块的读取。

### 均匀填充块（`uniform_block`）

部分源块本身就是**均匀填充**（48 个 8px 碎片里只有 4 种），此时 48 个图案全部相同，
报告里该块会标 `"distinct_patterns": 1, "uniform_block": true`。
实测学校外景芯片组（chipset 6）的 g0 / g4 / g2 属此类 —— 这是**素材属性，不是转换错误**；
这类块在 RM2K3 里等价于普通图块，手绘时取其中任一格即可。

### ⚠ 参考转换器公布版本的坐标缺陷（重要）

参考实现把原语写成
`putImageData(imageData, (dx - sx) * tileSize, ...)`，即把源瓦片 (sx, sy)
写到画布 `(dx - sx, dy - sy)`。该表达式在多数调用点算出**负坐标**，写入随即被
画布裁掉。用 Node + 规范精确的 `putImageData` 垫片**实际运行原始 JS**，输出为空
（A5/B 整张全空，A1 仅余 4 列细条，C/D/E 只剩左上角残缺）。

正确语义是 **目标 = (dx, dy)、源 = (sx, sy)**，由原站文档内嵌的四张 golden 样例图
独立印证：

| 样例 | 观测 | 对应 `dest=(dx,dy)` 的落点 |
|---|---|---|
| A5 | 8×16 全格有内容 | `(0,0)`6×16 + `(6,0)`2×8 + `(6,8)`2×8 |
| B | 仅 col 0–5 与 8–13 | 四段 6×8 |
| A1 | col 0–5 + col 14–15，row 0–8 | 水体三带 + 瀑布两列 |
| D 全图案 | row 0–5 / 8–13 各 16 列 | 四个 8×6 块的 2×2 摆位 |

`rm2k3_patterns.py` 已按 golden 语义实现，并在模块头记录该结论；
`verify_autotile_atlas.py` 内含**反向对照**：把落点改回缺陷公式后，
reference 布局只剩 5/48 格有内容，证明断言确实抓得住这个缺陷。

### 自检

```bash
cd tools/rm2k3_map_restore
python verify_autotile_atlas.py      # 84 项，EXIT 0
```

覆盖：48/48 图案齐全、atlas 尺寸、象限不越界、variant→格位映射完备、
动画帧互异性 == 源列互异性、两次生成逐字节一致、1× 缩放、反向对照。

### 仍需人工确认的部分

- 水体 / 瀑布的**邻接变体（岸边、瀑布上下缘）语义**尚未标定，报告标 `needs_calibration`。
- 动画帧的拼装已按参考 A1 段 1:1 移植并经文档样例校验，但「6 个示意格各对应什么
  邻接位置」需按 RM2K3 编辑器确认后才能用于手绘。
- 事件逻辑、碰撞/通行性、寻路仍未自动导入。


## 为什么不能直接使用 2K_TO_VA

`C:/Users/Administrator/Downloads/2K_TO_VA/batch_convert.py` 已保存为 `reference/2K_TO_VA_batch_convert.py` 供对照。它的 A2 段把左侧自动图块统一压成 VX Ace A2；如果其中实际包含 RM2K3 A1 水面/河流，转换后就会错位。因此本项目的通用工具把类型拆开，并把 VA 中间结果与 Godot 最终结果分离。

## 与地图转换器的关系

`export_map.py` / `map_tilemap_generator.gd` 负责 LMU 地图和分层 TileMap；`rm2k3_to_va.py` 负责芯片组类型转换。后续地图转换器应使用 `*_godot.png` 和 `*_mapping.json`，不能使用 `*_VA.png` 直接创建 Godot TileSet。
