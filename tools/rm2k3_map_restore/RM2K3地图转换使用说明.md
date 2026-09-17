# RM2K3 地图转换为 Godot 可编辑 TileMap

本工具把 RPG Maker 2003 的 LMU 地图转换为 Godot 4.6 的真正 `TileMapLayer` 场景。生成后可以在 Godot 编辑器中逐格选择、绘制、擦除和替换图块。

## 一键转换

在本目录打开 Windows 命令提示符：

```bat
convert_map.bat "E:\15.L3D" 141 "D:\!bird's-eye-view-arpg-test-\l3d-re-godot" "D:\!bird's-eye-view-arpg-test-\l3d-re-godot\art\Tilesets\rm2k3_auto"
```

参数依次是：RM2K3 工程目录、地图 ID、Godot 工程目录、输出目录。地图 ID `141` 对应 `Map0141.lmu`；脚本会自动补齐四位编号。
第 5/6 个参数（可选）是 LMU 缺失宽高字段时的显式尺寸。通常不需要：LMU 缺宽高时
`export_map.py` 会按格数反推，只有当 RM2K3 最小尺寸 20×15 之下**恰好只有一组**
因式分解时才自动采用（如 300 格 → 20×15），多解仍会要求显式 `--width/--height`。
第 7 个参数（可选）`rebuild` 强制重建 TileSet，丢弃编辑器侧的碰撞与 `z_index` 加工。

脚本按三步执行，任一步失败即以非零码中断（不会留下半成品）：

| 步骤 | 动作 | 产物 |
|---|---|---|
| 1/3 | `rm2k3_autotile_atlas.py --game-dir <RM2K3> --map-id <ID>` | `<输出目录>\autotiles\`：A1–A4 全图案 atlas + 水体/瀑布动画帧 |
| 2/3 | `export_map.py` | `MapXXXX_tilemap.json` + 分层 atlas + render |
| 3/3 | Godot headless 生成器 | `tres/MapXXXX_*_tileset.tres` + `scene/maps_auto/MapXXXX_auto.tscn` |

Godot 路径在 `convert_map.bat` 的 `GODOT_EXE` 中修改。

> ⚠ **步骤 1 的芯片组来源**：按 LMU 的芯片组字段解析（即本图实际使用的素材），
> 不是旧实现那样盲取 `ChipSet\` 目录里的第一个文件。详见
> [`RM2K3到VX_Ace图块转换说明.md`](RM2K3到VX_Ace图块转换说明.md)。

> **第 3 步是增量的**：目标 TileSet 已存在时**复用**它、只补齐缺失格位，编辑器侧加工
> （碰撞多边形、逐格 `z_index`、资源与 `ext_resource` 的 `uid`）都会保留；已有 TileSet
> 覆盖全部所需格位时不写文件。传第 7 个参数 `rebuild` 可强制重建（丢弃上述加工）。
> ⚠ headless 运行没有编辑器的 ResourceUID 缓存，`ResourceSaver` 不写 `uid=`，
> 生成器会在保存后把保存前的 uid 与 `ext_resource` 的 uid 补回去
>（`scene/maps/突袭-第二关-学校门口.tscn` 正是按 uid 引用这两个 TileSet 的）。
> ⚠ `scene/maps_auto/MapXXXX_auto.tscn` 本身始终重生成。

> ⚠ **批处理文件的编码**：`convert_map.bat` 与 `convert_chipset.bat` 均保持**纯 ASCII**。
> cmd.exe 用 OEM 代码页（中文 Windows 为 936）解析批处理，UTF-8 中文会乱码，且行尾的
> 前导字节可能吞掉换行符、或吃掉 `^` 转义把 `^<` 变成真重定向，把下一行粘连成命令。
> `convert_chipset.bat` 原先就是这样**实际不可用**的（无参路径直接报解析错误），
> 已于 2026-09-11 改为纯 ASCII 并加 `chcp 65001`。**新增 bat 时请同样遵守。**


## 分步转换

```bash
python export_map.py "E:/15.L3D" 141 --output "D:/project/art/Tilesets/rm2k3_auto"
```

然后从 Godot 项目目录运行：

```bash
godot --headless --path . --script res://script/map_restore/map_tilemap_generator.gd -- \
  "D:/project/art/Tilesets/rm2k3_auto/Map0141_tilemap.json" \
  "D:/project/art/Tilesets/rm2k3_auto/Map0141_lower_tiles.png" \
  "D:/project/art/Tilesets/rm2k3_auto/Map0141_upper_tiles.png" \
  "res://tres/Map0141_lower_tileset.tres" \
  "res://tres/Map0141_upper_tileset.tres" \
  "res://scene/maps_auto/Map0141_auto.tscn"
```

生成器参数顺序是：JSON、下层 atlas、上层 atlas、下层 TileSet、上层 TileSet、场景。

## 输出文件

- `MapXXXX_tilemap.json`：地图尺寸、原始图块 ID、每格 lower/upper key 和分层 atlas 坐标。
- `MapXXXX_lower_tiles.png`：仅包含下层 D/E 图块。
- `MapXXXX_upper_tiles.png`：仅包含上层 F 图块。
- `MapXXXX_render.png`：上下层合成的视觉对照图，不是地图数据。
- `tres/MapXXXX_lower_tileset.tres`：下层专用 TileSet。
- `tres/MapXXXX_upper_tileset.tres`：上层专用 TileSet。
- `scene/maps_auto/MapXXXX_auto.tscn`：真实可编辑 TileMapLayer 场景。

场景中 `GroundLayer` 只引用 lower TileSet，`UpperLayer` 只引用 upper TileSet；`DecorLayer` 留给玩家、事件和装饰，不写入恢复图块。

## 图块编码

- `4000 + 50×group + variant`：Block D 自动图块，按 EasyRPG 四个 8px 象限烘焙为普通 atlas tile。
- `5000+n`：Block E 普通下层图块。
- `10000+n`：Block F 普通上层图块；`10000` 是透明保留格并跳过。
- LMU 的 0x47/0x48 矩阵按 `y * width + x` 读取。

不要直接使用 `2K_TO_VA/batch_convert.py` 的 A2 结果作为 RM2K3 地图图块。该工具会把左侧自动图块统一压成 VX Ace A2，河流和水面等 A1 语义内容会错位。

## 编辑生成的地图

在 Godot 中打开 `scene/maps_auto/MapXXXX_auto.tscn`，选中 `GroundLayer` 或 `UpperLayer`，底部 TileMap 面板会显示对应层自己的 atlas。两层不共享 TileSet，可以分别设置碰撞、导航和其他属性。

## 透明背景处理

RM2K3 的透明色不是固定的纯粉色。转换器按格式语义处理：XYZ 和索引 PNG/BMP 使用 palette index 0；已有 PNG `tRNS` alpha 会保留。不会按相近颜色或容差删除像素，避免把有效的粉色、灰色或蓝色图案误删。

## 当前边界

事件逻辑、事件图像、碰撞/通行性、寻路不会自动导入。

**Block A（下层动画图块，水面）已支持**：ID `2000 段` 会烘焙进下层 atlas 并以
Godot 的 tile 动画播放（每帧 0.3s）。目前只标定了 `2000` 与 `2004` → 芯片组动画区
row 7（深水）；其余 2000 段 ID 会打印 `WARNING: 未标定的下层动画 ID 已跳过` 并留空。
遇到时把该 ID 加进 `export_map.py` 的 `BLOCK_A_ANIM`（ID → 芯片组动画区行号）即可。

地图缺少宽高字段时通常无需手动指定：`export_map.py` 会按格数反推（RM2K3 最小
20×15 下**恰有一组**因式分解才接受，如 300 格 → 20×15；多解仍要求显式尺寸）。
显式 `--width/--height` 依然可用，且会校验宽×高必须等于 LMU 的图块数量。
输出目录建议使用 `art/Tilesets/rm2k3_auto/`，不要覆盖现有手工地图或既有素材。

## 与自动图块（A1–A4）的关系

本流程烘焙的是 RM2K3 原生 Block D/E/F 语义（`4000+50·g+v` / `5000+n` / `10000+n`），
**不涉及 VX Ace 的 A1–A4 分区**。若要给 Godot 提供可直接绘制/配 Terrain 的自动图块
（每格完整的 32×32 瓦片 + 水体动画帧），使用 `rm2k3_autotile_atlas.py`，
输出到 `art/Tilesets/rm2k3_auto/autotiles/`：

```bash
python rm2k3_autotile_atlas.py --game-dir "E:/15.L3D" --chipset-ids "6,7,15,16,39" \
  --output "../../art/Tilesets/rm2k3_auto/autotiles"
```

细节见 [`RM2K3到VX_Ace图块转换说明.md`](RM2K3到VX_Ace图块转换说明.md)。
