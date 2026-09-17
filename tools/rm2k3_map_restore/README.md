# RM2K3 地图还原与 TileMap 转换工具

`parse_lcf.py` 负责生成地图树和芯片组摘要；`rm2k3_autotile_atlas.py` 负责 A1–A4 自动图块全图案 atlas 与水/瀑布动画帧；`export_map.py` 负责读取 LMU、解码图块并生成分层 atlas/JSON；`map_tilemap_generator.gd` 使用 Godot 官方 API 生成真正可编辑的 TileMapLayer；`convert_map.bat` 提供 Windows 一键入口。完整步骤见 [`RM2K3地图转换使用说明.md`](RM2K3地图转换使用说明.md)。

## 一键转换

```bat
convert_map.bat "E:\15.L3D" 141 "D:\!bird's-eye-view-arpg-test-\l3d-re-godot" "D:\!bird's-eye-view-arpg-test-\l3d-re-godot\art\Tilesets\rm2k3_auto"
```

三步执行，任一步失败即中断（`convert_map.bat` 内每步都有说明与失败分支）：

1. **A1–A4 自动图块全图案 atlas** —— `rm2k3_autotile_atlas.py`，芯片组按 LMU 字段解析
2. **LMU → 分层 atlas + TileMap JSON** —— `export_map.py`；LMU 缺宽高时按格数反推
   （RM2K3 最小 20×15 下**只有一组**因式分解才接受，如 300 格 → 20×15；多解则仍要求显式 `--width/--height`）
3. **JSON/atlas → 可编辑 TileMapLayer 场景** —— `map_tilemap_generator.gd`

输出文件包括：

- `autotiles\<芯片名>_A1|A2|A3|A4_patterns.png`：每个自动图块的 48 个完整 32×32 图案
- `autotiles\<芯片名>_A1_water1|water2_frames.png`、`_A2_waterfall_frames.png`：动画帧
- `autotiles\<芯片名>_A1A4_report.json`：逐块源矩形、`variant_to_slot`、`distinct_patterns`、自检结果
- `Map0141_tilemap.json`：逐格 lower/upper ID 和分层 atlas 映射
- `Map0141_lower_tiles.png`：只包含下层 D/E 图块
- `Map0141_upper_tiles.png`：只包含上层 F 图块
- `Map0141_render.png`：上下层合成的视觉对照图
- `tres/Map0141_lower_tileset.tres`：下层 TileSet
- `tres/Map0141_upper_tileset.tres`：上层 TileSet
- `scene/maps_auto/Map0141_auto.tscn`：真实可编辑 TileMapLayer 场景

> **第 3 步是增量的**：目标 TileSet 已存在时**复用**它、只补齐缺失格位，从而保留编辑器侧的
> 加工 —— 碰撞多边形（`physics_layer_0/*`）、逐格 `z_index`、资源与 `ext_resource` 的 `uid`。
> 已有 TileSet 覆盖全部所需格位时**完全不动文件**（无格式抖动）。实测 Map0141 的 73 + 35 个
> 碰撞多边形在多次重跑后原样保留。传第 7 个参数 `rebuild` 可强制重建（会丢弃上述加工）。
> `scene/maps_auto/MapXXXX_auto.tscn` 本身始终重生成（它是流水线的派生产物）。

> ⚠ `convert_map.bat` 保持**纯 ASCII**：cmd.exe 按 OEM 代码页解析批处理，UTF-8 中文会乱码，
> 行尾前导字节还可能吞掉换行符把下一行粘成命令。脚本用 `chcp 65001` 让 Python 的中文输出可读。

## 当前编码约定

- `4000 + 50×group + variant`：Block D 自动图块，按 EasyRPG 四象限规则烘焙。
- `5000+n`：Block E 普通下层图块。
- `10000+n`：Block F 普通上层图块；`10000` 是透明保留格并跳过。
- LMU 图层矩阵按 `y * width + x` 读取。

不要直接使用 `2K_TO_VA/batch_convert.py` 的 A2 结果：它会把 RM2K3 左侧自动图块统一压成 VX Ace A2，河流和水面等 A1 语义内容会错位。

## 通用芯片组转换

`rm2k3_to_va.py` 可独立转换 `.xyz`、480×256 PNG 和 8-bit BMP 芯片组：

```bash
python rm2k3_to_va.py "E:/15.L3D/ChipSet/01 - 仜.bmp" --output "D:/project/art/Tilesets/converted"
```

它分别输出 A1/A2/A3/A4/A5/B/C/D/E 的 `*_VA.png` 中间图、`*_godot.png` 完整 32×32 图块 atlas、`*_mapping.json` 和 `*_report.json`。其中 `*_VA.png` 只用于检查 VA 分区；Godot 只能使用已经展开/烘焙后的 `*_godot.png`。

> ⚠ **实测（2026-09-11）**：上面这句在本实现下没有实质差别 —— `REGIONS` 全是规整 16px 网格，
> `crop(rect)×N` 与「逐格 crop 后 resize」数学等价，两张样例芯片组的 9 组产物**逐像素相同**
> （`ImageChops.difference(...).getbbox() is None`，尺寸也一致）。该分层只是契约，不是内容差异。

## A1–A4 全图案 atlas（真正可给 Godot 用）

`rm2k3_to_va.py` 的 A1–A4 是矩形裁切，不是 Godot 能用的一格一图。真正做过象限拼装、
每格都是完整 32×32 瓦片的是：

```bash
python rm2k3_autotile_atlas.py "奨3.png" --output "art/Tilesets/rm2k3_auto/autotiles"
cd tools/rm2k3_map_restore && python verify_autotile_atlas.py   # 84 项自检，EXIT 0
```

格式取自参考转换器的「附加素材 / おまけ」输出（单个自动图块 → 48 个完整瓦片，8×6），
并给出 `variant_to_slot` 映射与水体/瀑布动画帧（横向连续帧）。
细节与参考实现坐标缺陷的实证见 [`RM2K3到VX_Ace图块转换说明.md`](RM2K3到VX_Ace图块转换说明.md)。

事件、碰撞、通行性、寻路不会自动导入。RM2K3 下层动画图块（ID 2000 段，水面）已支持：
会烘焙进下层 atlas 并以 Godot tile 动画播放（每帧 0.3s）；目前只标定了 `2000`/`2004` →
芯片组动画区 row 7 深水，其余 2000 段 ID 会告警并跳过（`needs_calibration`，见表
`export_map.py::BLOCK_A_ANIM`）。自动图块报告会明确标记 `needs_calibration`。

芯片组透明色按格式语义处理：XYZ 和索引 PNG/BMP 使用 palette index 0；已有 PNG `tRNS` alpha 会保留。不会删除所有粉色，也不会使用带容差的颜色抠除，以免误删有效像素。
