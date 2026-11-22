# RM2K3 地图还原与 TileMap 转换工具

`parse_lcf.py` 负责生成地图树和芯片组摘要；`rm2k3_autotile_atlas.py` 负责 A1–A4 自动图块全图案 atlas 与水/瀑布动画帧；`export_map.py` 负责读取 LMU、解码图块并生成分层 atlas/JSON；`map_tilemap_generator.gd` 使用 Godot 官方 API 生成真正可编辑的 TileMapLayer；`convert_map.bat` 提供 Windows 一键入口。完整步骤见 [`RM2K3地图转换使用说明.md`](RM2K3地图转换使用说明.md)。

## 一键转换

```bat
convert_map.bat "E:\15.L3D" 141 "D:\!bird's-eye-view-arpg-test-\l3d-re-godot" "D:\!bird's-eye-view-arpg-test-\l3d-re-godot\art\Tilesets\rm2k3_auto"
```

三步执行，任一步失败即中断（`convert_map.bat` 内每步都有说明与失败分支）：

1. **A1–A4 自动图块全图案 atlas** —— `rm2k3_autotile_atlas.py`，芯片组按 LMU 字段解析
2. **LMU → 分层 atlas + TileMap JSON** —— `export_map.py`；LMU 缺宽高时**先按已有的一边整除格数补齐**
   （Map0030 只存高度 25、共 500 格 → 20×25），两边都缺时才按格数反推
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

> **第 3 步的保护规则（2026-11-22）**：首次生成地图时，既有 TileSet 沿用原增量复用；
> 目标场景已经存在时，只同步带工具来源标记的固定物品点，**不重建图块、作者节点或 TileSet**。
> `rebuild` 只用于没有既有目标场景的新建路径；已有场景时忽略并提示，避免误毁作者碰撞。
> 工具不自动修改 `scene/maps/` 下另存的手工地图。

> ⚠ `convert_map.bat` 保持**纯 ASCII**：cmd.exe 按 OEM 代码页解析批处理，UTF-8 中文会乱码，
> 行尾前导字节还可能吞掉换行符把下一行粘成命令。脚本用 `chcp 65001` 让 Python 的中文输出可读。

## 固定物品事件导入（2026-11-22）

正常运行 `convert_map.bat` / `batch_convert.py` 时，第 2 步会自动读取 LMU 事件与
`RPG_RT.ldb` 的物品名称，生成 `MapXXXX_item_pickups_report.json`，第 3 步把确认的固定
物品生成到 DecorLayer 下。复用 **`object/random_pickup.tscn` + 单项 DropPoolData**，
不是剧情钥匙用的 `script/director/item_pickup_point.gd`。因此生成点可在检查器中继续
改成多项随机池，拾取、存档消费和联机 Host 权威均走原游戏逻辑。

- 物品匹配：现有资源 `item_name` 精确匹配，或 `item_pickup_aliases.json` 的显式名称映射；
  不做包含/模糊猜测。别名表已覆盖原作常见枪械/药品（原作日文名与现有资源中文名不同，
  必须逐条列出）。新增别名可用 `export_map.py --item-aliases <json>` 指定自己的文件。
- 事件识别：完整的 L3D 固定地面拾取模板，或具备精确物品身份、单一给物品命令与
  消费开关空白页的简单事件。**同一事件的多个可达页（原作状态变量分档）会合并成一个
  多项随机池**（等价于现有的武器随机掉落物）；同条件值的后续页按 RM 页优先级视为死页。
  無限固定武器架、商店、剧情、医疗箱不拍平成一次性掉落。
- 位置：原事件 `(x, y)` → `Vector2(x * 32 + 16, y * 32 + 16)`。节点名稳定为
  `ItemPickupPoint_RM2K3_E<四位事件号>`，metadata 保留地图/事件/页/原名称/匹配依据。
- **空结果（2026-11-22）**：野外地图的补给点按原作 RND 档位精确计算不刷新概率 ——
  解析「全マップ共通処理」给点位变量赋的 `RND(min..max)`，变量值落在页条件之外的档位就是空页。
  例如固定スプレー是 `RND(1..6)`、只有值 6 显示 → 5/6 空；武器列若范围与页数刚好覆盖 → 不空。
  池里追加 `null` 条目，权重 = 空档数，物品每项权重 1。地图树名含「セーフハウス」的安全屋不加空。
  `--pickup-empty-ratio` 可强制统一比例（如 0.5）或设 0 关闭；空结果不记「已消耗」，换图会重抽。
- 原作这套概率来自 `全マップ共通処理` 进图时给点位状态变量赋 `RND`：例如固定スプレー是
  `V1385..1390 = RND(1..6/1..7/1..10)`，只有抽到 6 才显示喷雾，其余值落在空页。
- 增量：按地图+事件来源键去重，只增删改本工具标记的节点；作者自行摆放节点保留。
  暂时无法映射或坏数据的来源键保留上次成功结果，不把失败当成删除指令。
- **范围限制**：不翻译 RM2K3 的整个事件/条件运行时；复杂条目写进报告，人工决定后再接。
  本次没有批量重写正在制作的死亡岛手工地图。

只检查事件、不生成图块或场景：

```bash
python tools/rm2k3_map_restore/export_item_pickups.py E:/15.L3D 25 26 28 32
python -m unittest discover -s tools/rm2k3_map_restore/tests -p test_item_pickups.py -v
```

真实样本（2026-11-22 第二轮校准）：Map0024 有 18 个点（9 个多页武器池 + 6 个此前漏检的
固定喷雾 + 其它单页），Map0025 有 14 个点且全部是多页池；Map0032 有 14 个可确认物品。
未映射项（MP5、钉枪、機関砲/M61、消火器、链锯、熊玩偶）在各图报告的 `unmapped_items`
里列出，不替换成别的武器。

## 批量转换（多张地图）

`batch_convert.py` 把上面的命令包装成可一次导出多张地图的工具；同目录的 `批量转换地图.cmd`
双击即进入交互输入（也可从命令行调用）。

```bat
python batch_convert.py                   :: 交互式输入
python batch_convert.py 30 31 35-37       :: 直接指定多张
python batch_convert.py 30:20x25 31       :: 单图显式宽高
python batch_convert.py 30-35 --rebuild   :: 强制重建 TileSet
```

- ID 写法可混用：`30`、`30,31,32`、`30-35`（含两端）、`30:20x25`（仅该图显式宽高）。
- 默认参数已对齐本工程（`E:\15.L3D`、仓库根、`art\Tilesets\rm2k3_auto`），
  可用 `--game-dir` / `--godot-dir` / `--out-dir` 覆盖。
- 单张失败**不中断**其余地图；结束打印汇总表并以非零码退出。
  `--stop-on-error` 改为遇错即停，`--dry-run` 只打印将执行的命令。
- 每张图的完整输出写入 `_batch_logs\<时间戳>\MapXXXX.log`（已加入 `.gitignore`）。
- **串行执行**：Godot headless 会占用工程缓存，不要并行跑多份批量任务。
- 工具会自动探测**带 Pillow 的 Python**并以 `RM2K3_PY` 传给 `convert_map.bat`
  （不同 shell/IDE 的 `python` 可能指向没装 Pillow 的运行时）；直接调 bat 时也可手动
  `set RM2K3_PY=<解释器路径>` 覆盖。

## 地图场景模板（2026-11-21 更新）

`convert_map.bat` 的第 3 步仍调用 `script/map_restore/map_tilemap_generator.gd`；场景骨架现集中在 `script/map_restore/map_scene_template.gd`，不要在多个生成入口维护重复模板。

| 部分 | 新生成结构 |
|---|---|
| 地图根 | 挂 `script/map/map_context.gd`，声明 `map_id` 与容器/边界路径 |
| 图块 | GroundLayer / DecorLayer / UpperLayer；地面、上层保持各自原 TileSet |
| 活体 | 内容图不保存玩家；会话把玩家直接创建到 DecorLayer，参与 Y 排序 |
| 出生标记 | 根下独立 `PlayerSpawn(Marker2D)`；修改此标记即可调整默认出生位 |
| 相机 | MapContext 保存边界、缩放与跟随参数；会话复用 `camera_follow.gd` 并逐图重绑 |
| 公共装配 | GameSession 持有 Menu、CombatHUD 和相机；GameInit 每次入图创建一次 |

当前输出为纯内容地图；直接 F6 运行时 MapContext 自动接入会话。生产加载采用 `GameSession/MapHost`，引擎当前场景是会话，业务通过 MapLocator 取源地图。存档键、随机补给键和机关 RPC 相对路径保持原地图口径，现有联机权威及 ready 协议不变。不要在模板中重新放入公共 UI 或预置玩家；TileSet 的增量复用逻辑保持不变。

从项目根可运行零第三方 Python 依赖的模板端到端检查：

```bash
python tools/test_map_scene_template.py
```

检查真实生成、TileSet 增量重跑不改文件，以及生成地图启动后的玩家注册、HUD 和镜头跟随；预期末行 `MAP_SCENE_TEMPLATE_E2E: PASS`。测试仅在 `.workbuddy/tmp/` 下创建独立输出，不覆盖正式地图或用户存档。Godot 路径不同可传 `--godot`。

## 当前编码约定

下层 ID 分区（EasyRPG `map_data.h`，**权威**）：

| 区间 | 内容 | 处理 |
|---|---|---|
| `0..999` / `1000..1999` / `2000..2999` | **水面自动图块**（Block A ×2 + Block B 深水） | 按 `block*1000 + b_subtile*50 + a_subtile` 解码，4 个 8×8 象限拼装（见下） |
| `3000..3149` | **Block C**：3 个 4 帧动画（漩涡、水面装饰…） | 列 `3..5`、行 `4..7`，静态取第 0 帧 |
| `4000+50×group+variant` | Block D 自动图块（屋顶/墙壁/草地） | 按 4 象限表烘焙（12 组 × 50 = 4000..4599） |
| `5000+n` | Block E 普通下层 | 原样裁切 |
| `10000+n` | Block F 普通上层；`10000` = 透明格，跳过 | 原样裁切 |

LMU 图层矩阵按 `y * width + x` 读取。

### ★水面「水池边」的拼装规则（与屋顶边缘不同，2026-10-22 查实）

- 地图里存的下层 ID **已经编码了解算后的变体**：
  `ID = block*1000 + b_subtile*50 + a_subtile`
  - `block 0/1` = 浅水（A 组两套），`block 2` = 深水
  - `a_subtile ∈ 0..46` = 岸线形状 → `BLOCK_A_SUBTILES_IDS[a][row][col]`
    给出**每个 8×8 象限取自芯片组 A 组哪一行（0..3）**，`-1` = 该象限改取 B 组水身
  - `b_subtile ∈ 0..15` = 深水边界位（位序 TL,TR,BL,BR），该象限取 B 组第 `4+t` 行；
    深水块（block 2）额外 `t ^= 3`
  - 还有第三趟：`b/a` 同时非零时用 B 组覆盖（别删，删了内角会错）
- ⚠ **不要套用 Block D 的表**：D 是 50 项、每项给 4 个显式 `(x,y)` 偏移；
  水面只有 47 项、每项只给「行号」，列由动画帧 `animID` 决定（`block 1` 再 `+3`）。
- 动画：水面的「帧」是**列**（0..2，3 帧）；Block C 的「帧」是**行**（0..3，4 帧）。
- 规则来源：EasyRPG Player `src/tilemap_layer.cpp`
  （`BlockA_Subtiles_IDS` / `GenerateAutotileAB` / `RecalculateAutotile`）。
  自检：`python verify_water_rules.py`（20 项，EXIT 0）。

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

固定物品事件现按上述保守规则导入；其他事件、碰撞、通行性、寻路不会自动导入。RM2K3 下层动画图块（ID 2000 段，水面）已支持：
会烘焙进下层 atlas 并以 Godot tile 动画播放（每帧 0.3s）；目前只标定了 `2000`/`2004` →
芯片组动画区 row 7 深水，其余 2000 段 ID 会告警并跳过（`needs_calibration`，见表
`export_map.py::BLOCK_A_ANIM`）。自动图块报告会明确标记 `needs_calibration`。

芯片组透明色按格式语义处理：XYZ 和索引 PNG/BMP 使用 palette index 0；已有 PNG `tRNS` alpha 会保留。不会删除所有粉色，也不会使用带容差的颜色抠除，以免误删有效像素。
