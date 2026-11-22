# RM2K3 地图转换为 Godot 可编辑 TileMap

本工具把 RPG Maker 2003 的 LMU 地图转换为 Godot 4.6 的真正 `TileMapLayer` 场景。生成后可以在 Godot 编辑器中逐格选择、绘制、擦除和替换图块。

## 一键转换

在本目录打开 Windows 命令提示符：

```bat
convert_map.bat "E:\15.L3D" 141 "D:\!bird's-eye-view-arpg-test-\l3d-re-godot" "D:\!bird's-eye-view-arpg-test-\l3d-re-godot\art\Tilesets\rm2k3_auto"
```

参数依次是：RM2K3 工程目录、地图 ID、Godot 工程目录、输出目录。地图 ID `141` 对应 `Map0141.lmu`；脚本会自动补齐四位编号。
第 5/6 个参数（可选）是 LMU 缺失宽高字段时的显式尺寸。通常不需要：只缺一边时
`export_map.py` 会用已有的一边整除格数补齐（如 Map0030 只存高度 25、共 500 格 → 20×25）；
两边都缺时才按格数反推，且只有 RM2K3 最小尺寸 20×15 之下**恰好只有一组**因式分解才自动采用
（如 300 格 → 20×15），多解仍会要求显式 `--width/--height`。
第 7 个参数（可选）`rebuild` 在新建目标场景路径时强制重建 TileSet（会丢弃碰撞与 `z_index` 加工）；目标场景已存在则忽略，以保护作者资源。

脚本按三步执行，任一步失败即以非零码中断（不会留下半成品）：

| 步骤 | 动作 | 产物 |
|---|---|---|
| 1/3 | `rm2k3_autotile_atlas.py --game-dir <RM2K3> --map-id <ID>` | `<输出目录>\autotiles\`：A1–A4 全图案 atlas + 水体/瀑布动画帧 |
| 2/3 | `export_map.py` | `MapXXXX_tilemap.json` + 分层 atlas + render |
| 3/3 | Godot headless 生成器 | `tres/MapXXXX_*_tileset.tres` + `scene/maps_auto/MapXXXX_auto.tscn` |

Godot 路径在 `convert_map.bat` 的 `GODOT_EXE` 中修改。

## 批量转换多张地图

`batch_convert.py` 包装上面的一键命令，可一次转换多张地图；同目录 `批量转换地图.cmd` 双击即用。

```bat
python batch_convert.py                   :: 交互式输入地图 ID
python batch_convert.py 30 31 35-37       :: 直接指定多张
python batch_convert.py 30:20x25 31       :: 单图显式宽高
python batch_convert.py 30-35 --rebuild   :: 强制重建 TileSet
```

地图 ID 写法可混用空格、逗号、分号：`30`、`30,31,32`、`30-35`（含两端）、
`30:20x25`（只对这张图显式指定宽高，等同 `convert_map.bat` 的第 5/6 个参数）。

| 选项 | 作用 |
|---|---|
| `--game-dir` / `--godot-dir` / `--out-dir` | 覆盖默认路径（默认 `E:\15.L3D`、仓库根、`art\Tilesets\rm2k3_auto`） |
| `--rebuild` | 新建目标场景路径时重建 TileSet；已有场景仅同步物品点，忽略此选项 |
| `--stop-on-error` | 任一地图失败即停止（默认继续跑完剩余地图） |
| `--dry-run` | 只打印将执行的命令，不落地任何文件 |
| `-y` / `--yes` | 交互模式下跳过确认 |

- 单张失败不会中断整批；结束时打印汇总表（每张的结果与耗时），有失败则以非零码退出。
- 每张图的完整控制台输出记录在 `_batch_logs\<时间戳>\MapXXXX.log`（已 gitignore）。
- 工具会自动探测**带 Pillow 的 Python**，以环境变量 `RM2K3_PY` 传给 `convert_map.bat`；
  直接调 bat 时也可自行 `set RM2K3_PY=<解释器路径>` 覆盖（缺 Pillow 会在第 1 步报
  `ModuleNotFoundError: No module named 'PIL'`）。
- **必须串行**：Godot headless 生成阶段会读写工程缓存，不要同时开多份批量任务。

> ⚠ **步骤 1 的芯片组来源**：按 LMU 的芯片组字段解析（即本图实际使用的素材），
> 不是旧实现那样盲取 `ChipSet\` 目录里的第一个文件。详见
> [`RM2K3到VX_Ace图块转换说明.md`](RM2K3到VX_Ace图块转换说明.md)。

> **第 3 步的保护规则（2026-11-22）**：首次生成目标场景时，TileSet 沿用原来的增量
> 复用/补格逻辑；**目标场景已存在时，只同步本工具生成的固定物品点**，不修改作者节点、
> 图块或 TileSet。此时 `rebuild` 会被忽略并提示；需要重新做图块应另选新的目标场景路径，
> 不会借一次物品同步丢掉作者已画的碰撞。
> headless 保存后仍恢复原有资源 uid 元数据。

> ⚠ **批处理文件的编码**：`convert_map.bat` 与 `convert_chipset.bat` 均保持**纯 ASCII**。
> cmd.exe 用 OEM 代码页（中文 Windows 为 936）解析批处理，UTF-8 中文会乱码，且行尾的
> 前导字节可能吞掉换行符、或吃掉 `^` 转义把 `^<` 变成真重定向，把下一行粘连成命令。
> `convert_chipset.bat` 原先就是这样**实际不可用**的（无参路径直接报解析错误），
> 已于 2026-09-11 改为纯 ASCII 并加 `chcp 65001`。**新增 bat 时请同样遵守。**


## 固定掉落物事件（2026-11-22）

常规转换已自动接入：`export_map.py` 读取 LMU 的物品命令和 `RPG_RT.ldb` 物品名，
用现有 `item_name` 或 `item_pickup_aliases.json` 的精确别名映射资源；生成器把匹配项
放成 DecorLayer 下的 `object/random_pickup.tscn`，内置单项 `DropPoolData`。
这与现有喷雾/武器随机点相同，可在编辑器把池改成多项；不是剧情钥匙的 ItemPickupPoint 脚本。

- 坐标按32像素格中心换算：`(x * 32 + 16, y * 32 + 16)`。
- 新增 `MapXXXX_item_pickups_report.json`：含已转换/跳过原因、原事件/页/物品名与目标资源。
- 节点名 `ItemPickupPoint_RM2K3_E<事件号>` 保持稳定；metadata 标记地图+事件来源键。
- 已有场景只同步工具标记节点，作者节点不动；未知物品保留旧成功点并报告，不猜配。
- 简单地面给物品事件和已核实的 L3D 固定拾取模板可转；**同一事件的多个可达页会合并成
  一个多项随机池**（原作状态变量分档，等价于现有的武器随机掉落物），同条件值的后续页
  按 RM 页优先级视为死页。
- 無限固定武器架（拿了不消失）、医疗箱、商店和剧情奖励不自动展开，也不移植原作完整
  事件运行时；Map0024 的 6 个固定喷雾（V1385..1390 == 6）已能识别。
- **野外补给点有概率不刷新**：按原作「全マップ共通処理」的 `RND` 档位精确计算
  （固定スプレー `RND(1..6)` 只有 6 显示 → 5/6 空；范围与页数刚好覆盖的武器列不空）。
  **RND 范围外的档位页直接剔除、不进池**（28 图霰弹/突击/狙击列各少一把、回復列少一档）。
  地图树名为 `セーフハウス` 的安全屋不加空、补给必出；`--pickup-empty-ratio` 可强制统一比例。
  空结果不记为已消耗，换图回来会重新抽。
- 别名表 `item_pickup_aliases.json` 覆盖原作常见枪械/药品的日文原名到现有资源；
  未列出的项（MP5、钉枪、機関砲/M61、消火器、链锯、熊玩偶）留在报告里，不猜配。
- Map0024 现转换 18 个点（9 个多页武器池 + 6 个固定喷雾等），Map0025 转换 14 个多页池。

只读检查（不生成图块或场景，也不需要 Pillow）：

```bash
python tools/rm2k3_map_restore/export_item_pickups.py E:/15.L3D 25 26 28 32
```

`export_map.py --item-aliases <json>` 可指定自己的精确映射表。完整规则见同目录
[README 的固定物品事件导入](README.md)。本轮未重写 `scene/maps/` 的死亡岛手工地图。

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

场景中 `GroundLayer` 只引用 lower TileSet，`UpperLayer` 只引用 upper TileSet；`DecorLayer` 不写入恢复图块，用作活体与物件的 Y 排序域。

### 场景骨架（2026-11-21）

骨架由 `script/map_restore/map_scene_template.gd` 统一生成，地图根挂 `MapContext` 声明地图标识、排序容器与相机参数。模板只保存地图内容和根下独立 `PlayerSpawn(Marker2D)`，玩家由会话在运行时直接创建到 DecorLayer。修改默认出生位只需移动标记；存档或入口落点仍由原有流程优先应用，不会被标记覆盖。

公共跟随相机、Menu 和 CombatHUD 由常驻 GameSession 持有并跨图复用，GameInit 每次入图仅创建一份。直接 F6 运行地图会自动装配会话；正常加载使用 GameSession/MapHost，业务地图身份通过 MapLocator 查询。原命令参数、首次逐格恢复与原地图持久键保持不变。转换命令不会自动重生成 `scene/maps/` 手工地图；目标场景已存在时仅同步工具标记物品点，图块和作者节点保留。首次加载时若活动地图尚未注册，预摆物品通过所属地图祖先解析持久键，不把会话路径写进存档。

模板端到端校验可从项目根运行 `python tools/test_map_scene_template.py`，预期 `MAP_SCENE_TEMPLATE_E2E: PASS`；它只在 `.workbuddy/tmp/` 下写隔离测试产物，不覆盖正式地图、TileSet、配置或玩家存档。

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

**水面（Block A/B，ID `0..2999`）与 Block C（`3000..3149`）已完整支持**（2026-10-22）：

- 水面 ID 里**已经编码了解算后的岸线变体**：`ID = block*1000 + b_subtile*50 + a_subtile`。
  转换器按 4 个 8×8 象限拼装；岸线形状用 47 项表 `BLOCK_A_SUBTILES_IDS`
  （A 组第 0–3 行 / B 组第 4–7 行），深水边界用 `b_subtile` 的 4 个位。
  `block 0/1` = 浅水两套，`block 2` = 深水（用第 1 套做岸线，故 `t ^= 3`）。
- 动画：水面「帧」是**列**（0–2，3 帧，每帧 0.3s）；Block C「帧」是**行**（0–3，4 帧）。
- ⚠ **与屋顶边缘（Block D）规则不同**，不能套同一张表：D 是 50 项、每项给 4 个显式
  `(x,y)` 偏移；水面是 47 项、每项只给「行号」，列由动画帧决定（`block 1` 再 `+3`）。
- 规则来源：EasyRPG Player `src/tilemap_layer.cpp`
  （`BlockA_Subtiles_IDS` / `GenerateAutotileAB` / `RecalculateAutotile`）。
  自检：`python verify_water_rules.py`（20 项，EXIT 0）。
- 旧实现只标定了 `1000/2000/2004` 三张「单行裁切」，其余 ID **静默丢弃** ——
  表现就是水池边一整圈、漩涡这类图块变成空洞（Godot 里显示为灰块）。

地图缺少宽高字段时通常无需手动指定：`export_map.py` 会按格数反推（RM2K3 最小
20×15 下**恰有一组**因式分解才接受，如 300 格 → 20×15；多解仍要求显式尺寸）。
显式 `--width/--height` 依然可用，且会校验宽×高必须等于 LMU 的图块数量。
输出目录建议使用 `art/Tilesets/rm2k3_auto/`，不要覆盖现有手工地图或既有素材。

## 与自动图块（A1–A4）的关系

本流程烘焙的是 RM2K3 原生 Block A/B/C/D/E/F 语义
（`block*1000+b*50+a` / `3000+50n` / `4000+50·g+v` / `5000+n` / `10000+n`），
**不涉及 VX Ace 的 A1–A4 分区**。若要给 Godot 提供可直接绘制/配 Terrain 的自动图块
（每格完整的 32×32 瓦片 + 水体动画帧），使用 `rm2k3_autotile_atlas.py`，
输出到 `art/Tilesets/rm2k3_auto/autotiles/`：

```bash
python rm2k3_autotile_atlas.py --game-dir "E:/15.L3D" --chipset-ids "6,7,15,16,39" \
  --output "../../art/Tilesets/rm2k3_auto/autotiles"
```

细节见 [`RM2K3到VX_Ace图块转换说明.md`](RM2K3到VX_Ace图块转换说明.md)。
