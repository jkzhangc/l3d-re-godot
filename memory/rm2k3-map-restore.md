# RM2K3 地图还原进度

## 已确认的工作边界

- **源工程**：`E:/15.L3D`（RPG Maker 2003 / LCF 格式）。
- **Godot 工程**：本项目；版本 Godot 4.6.3。
- **本轮目标**：只处理地图树中 `Map0065: SUDDEN ATTACK` 的子地图。
- **保留现有手做地图，不覆盖**：`scene/maps/突袭-第一关-街道.tscn`、`突袭-第一关-开头安全屋-户外.tscn`、`突袭-第一关-结尾安全屋-室内.tscn`。
- **建议的自动生成目标目录**：`scene/maps_auto/`。
- **缺失 VA 素材**：允许由原始 RM2k3 芯片组直接转换，但必须新建独立目录，例如 `art/Tilesets/rm2k3_auto/`；不得混入或覆盖既有 `art/Tilesets/`。
- **本轮不做**：事件逻辑、碰撞/通行性和寻路调校。用户后续自行调校。

## SUDDEN ATTACK 地图树与本轮范围

LMT 地图树已持久化到 [`tools/rm2k3_map_restore/map_tree.json`](../tools/rm2k3_map_restore/map_tree.json)。

```text
Map0065  SUDDEN ATTACK                     战役入口图；无完整 MapInfo，暂不转换
├─ Map0136  CP1-1                          芯片组 24: 街L3D
│  ├─ Map0137  セーフハウス（安全屋）       芯片组 8: のび太の家
│  └─ Map0139  スタート地点（起点）         芯片组 23: 街L3D
├─ Map0141  CP2-1                          芯片组 6: 学校・外観_○
│  ├─ Map0142  CP2-2                       芯片组 7: 学校 内観 - ○
│  └─ Map0143  セーフハウス（安全屋）       芯片组 7: 学校 内観 - ○
├─ Map0144  CP3-1                          芯片组 15: 洞窟L3D
│  └─ Map0145  セーフハウス（安全屋）       芯片组 16: 01 - ○
└─ Map0146  CPフィナーレ（CP 终章）          芯片组 16: 01 - ○
   └─ Map0147  CPフィナーレ                 芯片组 39: 01 - ○
```

`Map0140: キャラ選択（角色选择）` 的父节点是 `Map0079`，不是 SUDDEN ATTACK 子树，本轮排除。

### 本轮实际待生成地图

CP1 三张（136、137、139）已有人手版本作对照，暂不覆盖。待还原的 7 张为：

| 地图 | 名称 | 尺寸 | 芯片组 | 原始芯片组文件 |
|---|---|---:|---:|---|
| Map0141 | CP2-1 | 58×128 | 6 | `学校・外観_○` → `妛峑丒奜娤_仜.xyz` |
| Map0142 | CP2-2 | 344×191 | 7 | `学校 内観 - ○` → `妛峑 撪娤 - 仜.png` |
| Map0143 | 安全屋 | MapInfo 缺失 | 7 | `妛峑 撪娤 - 仜.png` |
| Map0144 | CP3-1 | 167×150 | 15 | `洞窟L3D` → `摯孉L3D.png` |
| Map0145 | 安全屋 | MapInfo 缺失 | 16 | `01 - ○` → `01 - 仜.bmp` |
| Map0146 | CP 终章 | 100×96 | 16 | `01 - 仜.bmp` |
| Map0147 | CP 终章 | 40×50 | 39 | `01 - 仜.bmp` |

对 137、139、143、145 等缺少宽高字段的图，LMU 仍有完整的上下层图块矩阵；转换时需通过矩阵格数、合理因子和 RM2k3 编辑器视图确认宽高，不能凭空假定。

## 已保存的解析产物

- [`tools/rm2k3_map_restore/parse_lcf.py`](../tools/rm2k3_map_restore/parse_lcf.py)：可复用 LCF 解析器。
- [`tools/rm2k3_map_restore/map_tree.json`](../tools/rm2k3_map_restore/map_tree.json)：本次解析结果（地图树、每图摘要、55 个芯片组表、芯片组原文件匹配）。
- 重新生成命令：

  ```bash
  cd tools/rm2k3_map_restore
  python parse_lcf.py
  ```

## 已验证的格式结论

### LMT（地图树）

- 文件：`E:/15.L3D/RPG_RT.lmt`，头为 `LcfMapTree`。
- 已解析 55 个节点：根节点 + 54 个地图节点。
- 树节点含 ID、父节点、缩进层级、类型和原始名字；名字存在 GBK 中文与 SJIS 日文混用，JSON 保留原始 hex 与解码结果。
- 父节点和缩进均已可用；早期调试输出中出现的 `33032` 等数字是把 BER 整数误当大端整数，不能使用。

### LMU（地图）

- 文件头：`LcfMapUnit`。
- 已解析块：`0x01` 芯片组 ID、`0x02` 高、`0x03` 宽、`0x47` 下层矩阵、`0x48` 上层矩阵、`0x51` 事件数据。
- 图块矩阵是 **小端 uint16，每格两字节**。
- 上层图块值已经确认：`10000 + n`，`n=0..191`，可直接映射到 VA `B` 图。
- 下层包含 `0`、`4000+n`、`5000+n` 三个范围；其“自动图块 / 普通下层 / 固定块”的精确语义仍需结合 EasyRPG 规则和原始芯片组渲染标定。

### LDB（芯片组）

- 芯片组表为 `RPG_RT.ldb` 的 `0x14` 区；本工程共 55 个条目。
- 条目字段：`0x01` 显示名、`0x02` 原始芯片组文件名（无扩展名）、`0x03/0x04/0x05` 图块属性数据。
- 55 个条目中 43 个已按文件名匹配到 `E:/15.L3D/ChipSet/` 的实际素材文件。
- 对本轮 7 张目标图使用的芯片组，全部已匹配到原始素材。

## 后续实施顺序

1. 读取 `map_tree.json`，不要重新手工解析 LMT/LDB。
2. 用 CP1 人手地图（136/137/139）做对照，先完成“下层图块值 → VA A2/A4/A5 / B 坐标”映射标定。
3. 对 141–147 建立 `chip_id → VA 图片 + atlas 坐标` 映射；缺失素材输出至 `art/Tilesets/rm2k3_auto/`。
4. 先生成一张 CP2 地图到 `scene/maps_auto/`，使用项目既有 `GroundLayer / DecorLayer / UpperLayer` 场景规范；截图与原图对比后再批量生成其余 6 张。
5. 事件节点仅保留位置占位；碰撞、通行性、事件逻辑在用户后续调校阶段处理。

## 首图纵向切片进度（2026-08-31）

- 已新增 `tools/rm2k3_map_restore/export_map.py`，可从显式源目录读取 LMU 的 0x47/0x48 逐格矩阵，并导出 JSON + 独立芯片组 atlas。
- 已生成 `art/Tilesets/rm2k3_auto/Map0141.json` 和 `Map0141_chipset.png`：Map0141 为 128×58、7424 格；下层 5143 格为 `5000+n`（标记 `A1_raw`），2281 格为 `4000+n`（标记 `A5`），上层为 `10000+n`（标记 `B`）。
- 已新增 `scene/maps_auto/Map0141_CP2-1.tscn` 与 `script/map_restore/map_restore_preview.gd`，遵循 GroundLayer / DecorLayer / UpperLayer / PlayerSpawn / Camera2D 层级；当前用原始 atlas 片元预览，不接入事件、碰撞、通行性或寻路。
- 已确认 `C:/Users/Administrator/Downloads/2K_TO_VA/batch_convert.py` 的 A2 段会把 RM2K3 左侧自动图块区统一压成 VX Ace A2 的 6 tile；这会把实际 A1 语义的河流/水面重排，不能用于本恢复管线。当前保留 12-tile 原始索引，A1 动画帧与 A2/A4 语义标定仍待后续。
- Godot 4.6.3 无头项目扫描与 Map0141 场景加载通过；仅出现项目既有 GradientLabel/资源 UID 警告。
- 复核 EasyRPG 规则后修正了先前错误：`5000+n` 是 Block E 普通下层，`4000+50*g+v` 是 Block D 自动图块，`10000` 是 Block F 的透明保留格；LMU 矩阵为行主序。`batch_convert.py` 将左侧自动区硬压成 A2 的做法不能直接用于本工程。
- 当前 `Map0141_render.png` 已作为 `GroundLayer/PreviewImage` 静态资源嵌入场景，编辑器和运行时都可见；此前“编辑器空白”是因为只有运行时脚本且 TileSet 为空。
- 已根据 EasyRPG `GenerateAutotiles()` 修正 D 自动图块象限坐标：源坐标使用 `((group_origin + quarter_offset) * 2 + output_quarter) * 8`，此前少乘 2 会造成横向条带。修正后 Map0141 局部渲染与 RM2K3 编辑器的灰地、蓝地、绿地、花坛、广场和教学楼细节对齐。
- 已新增可复用转换管线：`export_map.py` 输出实际使用的烘焙 32×32 atlas 与 `MapXXXX_tilemap.json`；`script/map_restore/map_tilemap_generator.gd` 使用官方 `TileSetAtlasSource`、`TileMapLayer.set_cell()`、`ResourceSaver` 和 `PackedScene.pack()` 生成真正可编辑的 TileMap；`convert_map.bat` 提供 Windows 一键入口；详细说明见 `tools/rm2k3_map_restore/RM2K3地图转换使用说明.md`。
- Map0141 已实际生成分层可编辑资源：`tres/Map0141_lower_tileset.tres`（128 tiles）与 `tres/Map0141_upper_tileset.tres`（25 tiles），以及 `scene/maps_auto/Map0141_auto.tscn`；GroundLayer 7424 格，UpperLayer 214 格。两层分别引用外置 TileSet，场景不再依赖 PreviewImage。
- `tools/rm2k3_map_restore/convert_map.bat` 已更新为一键生成分层 atlas/TileSet/TileMap；使用说明位于 `tools/rm2k3_map_restore/RM2K3地图转换使用说明.md`。
- 已保存原始 `2K_TO_VA/batch_convert.py` 到 `tools/rm2k3_map_restore/reference/2K_TO_VA_batch_convert.py`，并新增通用 `rm2k3_to_va.py`：支持 XYZ/PNG/BMP，分别输出 A1/A2/A3/A4/A5/B/C/D/E 的 VA 中间图、Godot 32×32 atlas、mapping 和 report。VA 自动图块 PNG 不能直接给 Godot 使用，必须使用 `*_godot.png` 展开结果；A1/A2/A3/A4/D/E 报告会标记待语义校准。
- 当前转换边界：未自动导入事件、碰撞/通行性、寻路和 A1 水面动画；运行期若 Director 查询 TileSet physics 会出现空 physics 层警告，属于待导入碰撞属性，不影响图块编辑。
- 已批量生成尺寸已确认的 Map0142、Map0144、Map0146、Map0147：均有独立 lower/upper atlas、外置 TileSet 和可编辑 TileMap 场景；对应尺寸分别为 344×191、167×150、100×96、40×50。Map0143/0145 的 LMU 仍只有 300 格且缺少宽高字段，暂不猜测生成。
- 已修复 PNG/BMP 芯片组的纯色背景：索引图像按 palette index 0 转 alpha=0，保留已有 tRNS，不使用粉色匹配或宽容差删除；Map0141/142/144/146/147 的 atlas 和 TileSet 已全部重新生成。
- 已确认并记录：RPG Maker 2000/2003 地图的最低尺寸为 20×15。Map0143 和 Map0145 的 LMU 缺失宽高字段，但其 300 格矩阵已按用户确认的 20×15 导出；`export_map.py` 支持 `--width 20 --height 15` 覆盖并校验格数。
- 用户已修改 `tools/rm2k3_map_restore/export_map.py`；后续操作需保留该版本，不覆盖或回退其改动。当前已检查该文件语法正常，Map0143/0145 的现有输出和 Godot 场景加载均正常。

## 现有参考资料

- `RM2K3_to_VX-Ace_图块转换分析.md`：2K_TO_VA 的芯片组区域与 A2/A4/A5/B 转换规则。
- `A4转换器.rb`：A4 转换参考实现。
- `A1动画图块实现方案.md`：动画图块设计。
- `memory/scene-conventions.md`：Godot 地图节点、图层和寻路命名规范。
- `C:/Users/Administrator/Downloads/2K_TO_VA/batch_convert.py`：原始转换器参考。
