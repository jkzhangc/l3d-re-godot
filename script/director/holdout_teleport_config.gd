class_name HoldoutTeleportConfig extends Resource

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：数据（Resource）
## 联机：不涉及
## 职责：防守战结束后生成的单个传送点配置；数组即多传送点。
## 依赖：HoldoutMachine.teleport_points

## 防守战「完成事件 · 添加传送点」的单条配置。
##
## HoldoutMachine.teleport_points 是 Array[HoldoutTeleportConfig]，
## 一个条目 = 防守战结束后生成一个传送点，因此可以配置多个。
##
## 用法：在 Inspector 里给 teleport_points 加元素，展开后逐条填目标场景/位置/外观。
## 若只想「显示已摆好的传送点」而不需要动态生成，请用 HoldoutMachine.show_node_paths。

# ═══════════════════════════════════════
# 目标
# ═══════════════════════════════════════
@export var enabled: bool = true                          ## false=跳过本条目
@export_file("*.tscn") var target_scene: String = ""      ## 传送目标场景
@export var target_arrival_id: String = ""                ## 目标场景入口 ID（留空=默认出生点）
@export var use_target_arrival_position: bool = false     ## true=用下方坐标作为落点
@export var target_arrival_position: Vector2 = Vector2.ZERO
@export var capture_checkpoint: bool = true               ## 传送前是否记录 checkpoint

# ═══════════════════════════════════════
# 位置
# ═══════════════════════════════════════
@export var marker_path: NodePath                         ## 用该节点的位置作为坐标（优先）
@export var offset: Vector2 = Vector2.ZERO                ## 未指定 marker 时，相对机器的偏移

# ═══════════════════════════════════════
# 外观（VX Ace 行走图）
# ═══════════════════════════════════════
@export var walk_texture: Texture2D                       ## 留空=沿用机器自身的 walk_texture
@export_range(0, 7, 1) var walk_char_index: int = 6
@export_range(0, 3, 1) var walk_direction: int = 2
@export var animated: bool = true

# ═══════════════════════════════════════
# 交互
# ═══════════════════════════════════════
@export var interact_label: String = "前往"
@export_range(8.0, 512.0, 1.0) var interact_range: float = 48.0

# ═══════════════════════════════════════
# 显隐
# ═══════════════════════════════════════
## 生成后是否先隐藏。隐藏期间玩家靠近按确定键**不会**传送（见 teleport_point.gd 的可见性校验）。
@export var start_hidden: bool = false
