# VX Anim Editor — VXAnimSprite 可视化动画编辑器

## 概述

在 Godot 编辑器底部面板提供 VX Ace 特效动画（VXAnimSprite）的可视化编辑工具。

- **精灵表格式**：RPG Maker VX Ace 动画精灵表（通常 960×192px = 5 列 × 192px/格）
- **动画素材目录**：`art/Animations/`（已放入 100+ 张动画精灵表）
- **保存格式**：`.tscn`（PackedScene，可直接 `load().instantiate()` 调用）
- **实体类**：`VXAnimSprite extends Node2D`

---

## 打开编辑器

1. Godot 编辑器中打开项目
2. 底部面板找到 **"VX Anim"** 标签页
3. 选中场景中的 VXAnimSprite 节点 → 自动加载编辑

或：
- 点击 **`＋ 新建`** 创建空白动画配置
- 点击 **`📂 打开`** 加载已保存的 `.tscn` 动画文件

---

## 编辑操作

### 精灵表网格视图（左侧）

| 操作 | 方式 |
|------|------|
| 加帧到序列 | 点击空格子 → 追加到序列末尾 |
| 选中帧 | 点击已在序列中的格子（蓝色高亮）|
| 删帧（该 pattern 的全部出现）| 右键格子 |
| 缩放手势 | Ctrl + 滚轮 |
| 平移视图 | 中键拖拽 |

### 帧序列面板（右侧）

每帧显示：序号 `#N` + 缩略图 + ✕删除 + ◀▶排序 + 时长 + **X/Y 偏移**

| 操作 | 方式 |
|------|------|
| 选帧 | 点击缩略图 |
| 删帧（单个）| 点击 ✕ 按钮 |
| 向前/后移动 | 点击 ◀ / ▶ 按钮 |
| 调整时长 | 数字框（秒，0.01–5.00）|
| 调整帧偏移 | X/Y 数字框（像素，-500–500）|

### 工具栏参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| ▶ 播放 / ⏸ 暂停 | 在面板内预览动画 | — |
| ↻ 循环 | 循环播放（也控制 `looping` 属性）| 关 |
| fps | 播放速度（帧/秒），对应 `frame_durations` 为空时的默认值 | 10 |
| 列数 | 精灵表列数（`h_frames`）| 5 |
| 单精灵/多精灵 | 模式切换，多精灵的 `cell_data` 在 Inspector 中编辑 | 单精灵 |
| 播完消除 | `auto_free` — 播放完毕自动 `queue_free` | 开 |
| 居中 | `centered` — 精灵锚点居中 | 开 |
| 整体偏移 X/Y | `position_offset` — 动画整体的像素偏移 | (0,0) |
| 帧偏移 X/Y | `frame_offsets[i]` — 每帧的额外像素偏移（在序列面板中编辑）| (0,0) |

---

## 保存与加载

### 保存

点击 **`💾 保存`** → 选择路径 → 保存为 `.tscn`

原理：将 VXAnimSprite 节点序列化为 PackedScene，保持所有 Inspector 可配置属性（texture, fps, h_frames, looping, auto_free, centered, frame_sequence, frame_durations, frame_offsets, position_offset, cell_data, animation_scale, animation_rotation）。

### 加载

点击 **`📂 打开`** → 选择 `.tscn` → 加载动画配置进行编辑

---

## 运行时调用

保存的动画可在游戏代码中直接使用：

```gdscript
# 一次性播放（auto_free=true，播完自动消除）
var anim: VXAnimSprite = load("res://animations/explosion.tscn").instantiate()
anim.global_position = target_pos
get_tree().current_scene.add_child(anim)

# 手动控制
var anim: VXAnimSprite = load("res://animations/muzzle_flash.tscn").instantiate()
anim.global_position = player.global_position
anim.looping = false
anim.auto_free = true
get_tree().current_scene.add_child(anim)

# 一行调用（VXAnimSprite 静态方法）
VXAnimSprite.play_at("血", hit_pos, get_tree().current_scene)
```

### 与 WeaponData / Enemy 集成

WeaponData 和 Enemy 的动画特效字段直接填动画名（不含 `.png`）：

```gdscript
# WeaponData（按方向区分）
attack_effect_anim_down = "ハンドガン発射_下"   # 向下枪口闪光
attack_effect_anim_left = "ハンドガン発射_左"   # 向左枪口闪光
attack_effect_anim_right = "ハンドガン発射_右"  # 向右枪口闪光
attack_effect_anim_up = "ハンドガン発射_上"     # 向上枪口闪光
hit_effect_anim = "血"                          # 击中特效

# Enemy
attack_effect_anim = "血"
```

> 这些字段在运行时通过 `VXAnimSprite.play_at(name, pos, parent)` 自动加载并播放。

---

## 文件结构

```
addons/vx_anim_editor/
├── plugin.cfg              # 插件注册
├── plugin.gd               # EditorPlugin 入口
├── anim_editor_panel.gd    # 主面板（工具栏 + 序列编辑 + 文件操作）
├── sprite_sheet_view.gd    # 精灵表网格视图（VXAnimSheetView 类）
└── README.md               # 本文档
```

---

## VXAnimSprite 完整参数参考

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `texture` | Texture2D | — | VX Ace 动画精灵表 |
| `h_frames` | int | 5 | 列数（VX Ace 标准 = 5）|
| `v_frames` | int | 0 | 行数（0 = 自动计算）|
| `fps` | float | 10.0 | 统一帧速（`frame_durations` 空时使用）|
| `looping` | bool | false | 循环播放 |
| `auto_free` | bool | true | 播完自动 queue_free |
| `centered` | bool | true | 居中锚点（false = 左上角）|
| `animation_scale` | Vector2 | (1, 1) | 整体缩放 |
| `animation_rotation` | float | 0 | 整体旋转（度）|
| `position_offset` | Vector2 | (0,0) | 整体位置偏移（叠加到节点坐标） |
| `frame_offsets` | Array[Vector2] | [] | 每帧 XY 偏移（索引对应帧序列号） |
| `frame_sequence` | Array[int] | [] | 自定义帧播放顺序（空 = 0,1,2...）|
| `frame_durations` | Array[float] | [] | 每帧秒数（空 = 用 fps）|
| `cell_data` | Array[VXAnimCellData] | [] | 多精灵配置（空 = 单精灵模式）|

> **偏移叠加顺序**：最终精灵位置 = `VXAnimCellData.offset` → `frame_offsets[N]` → `position_offset`（三层叠加，均在 Inspector 或编辑面板中直接设置）。

### VXAnimCellData（多精灵模式单格参数）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `frame_idx` | int | 0 | 所属帧序号 |
| `pattern` | int | 0 | 格子索引 |
| `offset` | Vector2 | (0,0) | 像素偏移 |
| `scale` | Vector2 | (1,1) | 缩放 |
| `rotation_deg` | float | 0 | 旋转（度）|
| `opacity` | float | 1.0 | 0–1 透明度 |
| `blend_mode` | int | 0 | 0=Normal, 1=Additive, 2=Subtractive |
| `flip_h` | bool | false | 水平翻转 |

### 静态工厂方法

```gdscript
# 从文件名加载（自动加 art/Animations/ 前缀 + .png 后缀）
VXAnimSprite.from_name("爆発", 15.0)

# 在指定位置播放，播完自动消除
VXAnimSprite.play_at("血", global_position, get_tree().current_scene)
```
