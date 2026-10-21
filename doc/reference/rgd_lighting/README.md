# 参考：RGD Lighting（原工程效果截图）

来源工程：`C:/Users/Administrator/Downloads/RGD灯光 for URGE`（RGSS/RGD，作者 invwindy）。
本目录只放**效果参考截图**，用于对照本项目夜间视界的观感；不含任何原工程素材。

| 文件 | 看什么 |
|---|---|
| `01_fireplace_room.png` | 壁炉光照：亮核 + 长尾渐变，光在墙边被切断，房间外全黑 |
| `02_green_lamp_corridor.png` | 走廊绿灯：光沿走廊铺开，被墙挡住不进房间，只从门口漏进去 |
| `03_shadow_below_player.png` | 人物脚下/背光侧的投影（人物阴影） |
| `04_occlusion_split.png` | 上下两个房间各自有光，墙体把两边完全分开 |
| `05_player_flashlight.png` | 手电筒锥形光 + 遮挡（锥形会被墙截断） |

## 原工程是怎么做的

`Scripts.rvdata2` 解包后（Ruby Marshal + zlib）相关脚本：
`RGD Lighting - Settings` / `- Occlusion` / `- Main` / `- Particle`。

- **视口之间混合**：`@viewport2` 用 `light.png`（径向渐变）在黑幕上"挖洞"，
  `@viewport1` 用 `light-illum.png` 加法叠色，两个视口各管一半，最后合成。
- **每种光** = 可见范围图 + 发光图 + `:color`（加法色调）+ `:power` + `:light_rand`（亮度随机百分比）。
- **闪烁**：每 5 帧重掷一次 `rand(2r)-r`，再 `old=(old*4+new)/5` 低通 —— 不规则但平滑。
- **建筑遮挡**：按图块区域投射，光被墙截断；`OCCLUSION_AMBIENT` 控制被遮区域的残余亮度。
- **人物阴影**：光源对附近事件投影，按朝向选侧面图，可调投影距离/角度/不透明度。

## 本项目怎么对应的

> ⚠ 2026-10-21 起，本工程的夜间渲染已改用 **Godot 内置 2D 灯光节点**
> （`CanvasModulate` + `PointLight2D` + `LightOccluder2D`），下表里"两个视口 / 射线扇形 /
> 加法叠色 pass"那几行是**历史实现**，已删除。保留原样只为对照原工程思路。
> 现行对应关系见 `内置2D灯光迁移方案.md`。

| 原工程 | 本项目（历史映射 → 现行做法） |
|---|---|
| 两个视口 | ~~`NightOverlay` 里的 `SubViewport` + 两个全屏合成 pass~~ → `CanvasModulate`（黑幕+夜色调）+ 每灯一个 `PointLight2D` |
| `light.png` 径向曲线 | `NightOverlay.GRADIENT_PROFILE`（未变，仍是内置灯贴图的来源） |
| `light-illum.png` 加法叠色 | ~~`shader/night_glow.gdshader`~~ → 由 `PointLight2D` 的 ADD 混合直接完成 |
| `:color` | `register_light(..., color)` / `LightEmitter.light_color`（未变） |
| `:light_rand` | `register_light(..., flicker)`（未变，节奏已放缓） |
| 建筑遮挡 | ~~每盏灯 160 条射线打 `collision_layer = 1`~~ → TileSet 遮挡层生成的 `LightOccluder2D`（GPU 裁剪） |
| 人物阴影 | 角色节点的 `NightShadow` 子精灵（`show_behind_parent`，压扁 + 背光偏移）（未变，新增拉伸量羽化） |

试验场：`scene/fx/light_lab.tscn`（F6 直接跑），可实时开关发光/遮挡/闪烁对比。
