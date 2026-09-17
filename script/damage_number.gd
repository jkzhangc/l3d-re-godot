class_name DamageNumber
extends Node2D

## ── 架构定位 ──
## 系统：伤害数字 ｜ 层：表现（Node2D）
## 联机：不涉及（纯表现）
## 职责：受击飘字：用 GradientLabel 渲染并做上浮+缓动，参数全部 @export。
## 依赖：GradientLabel

## 伤害数字弹出 — 被击中时从目标位置浮起并消失。
##
## 使用 GradientLabel（渐变路径），与标题画面共用字体/着色器/色表系统。
## 字体、颜色、粗体、阴影、上浮距离、缓动等全部公开为 @export 参数。
##
## 用法：
##   DamageNumber.spawn(global_position, damage, get_tree().current_scene)


# ═══════════════════════════════════════
# 缓动函数枚举
# ═══════════════════════════════════════

enum EasingType {
	LINEAR,           ## 线性（匀速）
	EASE_IN_QUAD,     ## 二次缓入（慢→快）
	EASE_OUT_QUAD,    ## 二次缓出（快→慢）
	EASE_IN_OUT_QUAD, ## 二次缓入缓出
	EASE_OUT_CUBIC,   ## 三次缓出（更快减速）
	EASE_OUT_EXPO,    ## 指数缓出
	EASE_OUT_BACK,    ## 回退缓出（超过目标后回弹）
	EASE_OUT_ELASTIC, ## 弹性缓出（震荡衰减）
	EASE_OUT_BOUNCE,  ## 弹跳缓出
}


# ═══════════════════════════════════════
# 公开参数（Inspector 可调）
# ═══════════════════════════════════════

@export var amount: float = 0.0            ## 伤害数值
@export var font_path: String = "res://art/System/fusion-pixel-12px-monospaced-zh_hans.ttf"  ## 字体路径（2026-09-17 与界面定稿统一）
@export var color_index: int = 1           ## 色表颜色索引（0–19，默认 1 = 标题画面同款白）
@export var color_row: int = 0             ## 色表颜色行（0–3，同一色相明暗变体）
@export var font_size: int = 24            ## 字号（1280×960 基准；fusion-pixel 12 基底，取 12 整倍）
@export var bold: bool = false             ## 粗体（1px 右偏移叠加，开启会让文字更亮）
@export var shadow_enabled: bool = true    ## 阴影
@export var rise_distance: float = 10.0    ## 上浮距离（像素）
@export var duration: float = 0.5         ## 总显示时长（秒）
@export var use_easing: bool = true        ## 是否使用缓动
@export var easing_type: EasingType = EasingType.EASE_OUT_ELASTIC  ## 缓动函数类型
@export var modulate_color: Color = Color.WHITE  ## 颜色叠加（White=不变）
## 文本覆盖（留空=显示整数伤害值）。用于「無効」等非数值反馈（2026-09-16 正面弹开提示）。
@export var text_override: String = ""
@export var position_offset: Vector2 = Vector2(0, -40)  ## 整体位置偏移（相对目标，像素）


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════

var _label: GradientLabel = null
var _elapsed: float = 0.0
var _start_world_pos: Vector2 = Vector2.ZERO

## 共享 CanvasLayer——所有伤害数字共用同一个层
static var _shared_canvas: CanvasLayer = null

## 共享色表 Image（避免每个实例重复 I/O）
static var _shared_color_img: Image = null


# ═══════════════════════════════════════
# 静态方法
# ═══════════════════════════════════════

## 快速生成伤害数字。
## text_override 非空时显示该文本（如「無効」），忽略 dmg 数值（2026-09-16）。
static func spawn(world_pos: Vector2, dmg: float, parent: Node, col_idx: int = 1, mod_col: Color = Color.WHITE, text_override: String = "") -> DamageNumber:
	var dn := DamageNumber.new()
	dn.amount = dmg
	dn.global_position = world_pos
	dn.color_index = col_idx
	dn.modulate_color = mod_col
	dn.text_override = text_override
	parent.add_child(dn)
	return dn


# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	## 树被暂停（章节总结/终章 ED）时也把 0.5s 动画放完自动消失——
	## 否则飘字冻结在 layer 100 上，压在黑幕(90)之上残留到切场景（实测教训）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("damage_number")
	_ensure_shared_canvas()
	_ensure_shared_color_img()
	_create_label()
	_start_world_pos = global_position + position_offset + Vector2(randf_range(-8.0, 8.0), randf_range(-4.0, 4.0))


## 清掉当前所有伤害数字（全屏演出如终章 ED 启动前调用）。
static func clear_all() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group("damage_number"):
		node.queue_free()
	if _shared_canvas and is_instance_valid(_shared_canvas):
		_shared_canvas.queue_free()
	_shared_canvas = null


func _process(delta: float) -> void:
	if not _label or not is_instance_valid(_label):
		return

	_elapsed += delta
	var t: float = clampf(_elapsed / duration, 0.0, 1.0)

	# 上浮偏移
	var eased_t: float = _apply_easing(t) if use_easing else t
	var offset_y: float = -eased_t * rise_distance

	# 淡出：最后 40% 时间逐渐透明
	var alpha: float = 1.0
	if t > 0.6:
		alpha = 1.0 - (t - 0.6) / 0.4

	# 世界坐标 → 屏幕坐标
	var screen_pos := _world_to_screen(_start_world_pos)
	screen_pos.y += offset_y

	# 居中
	if _label.size.x > 0:
		screen_pos.x -= _label.size.x / 2.0

	_label.position = screen_pos
	_label.modulate = Color(modulate_color.r, modulate_color.g, modulate_color.b, modulate_color.a * alpha)

	if t >= 1.0:
		_cleanup()


# ═══════════════════════════════════════
# 共享 CanvasLayer
# ═══════════════════════════════════════

func _ensure_shared_canvas() -> void:
	if _shared_canvas and is_instance_valid(_shared_canvas):
		return
	var tree := get_tree()
	if not tree:
		return
	var existing := tree.get_first_node_in_group("damage_number_layer")
	if existing and existing is CanvasLayer:
		_shared_canvas = existing as CanvasLayer
		return
	_shared_canvas = CanvasLayer.new()
	_shared_canvas.name = "DamageNumberLayer"
	_shared_canvas.layer = 100
	_shared_canvas.add_to_group("damage_number_layer")
	if tree.current_scene:
		tree.current_scene.add_child(_shared_canvas)
	else:
		tree.root.add_child(_shared_canvas)


# ═══════════════════════════════════════
# 共享色表
# ═══════════════════════════════════════

func _ensure_shared_color_img() -> void:
	if _shared_color_img:
		return
	if Global and Global.has_method("get_cached_color_image"):
		_shared_color_img = Global.get_cached_color_image()
	if not _shared_color_img and not Global.text_color_sheet_path.is_empty():
		_shared_color_img = Image.load_from_file(Global.text_color_sheet_path)


# ═══════════════════════════════════════
# GradientLabel 创建（与标题画面菜单完全一致）
# ═══════════════════════════════════════

func _create_label() -> void:
	if not _shared_canvas or not is_instance_valid(_shared_canvas):
		return

	_label = GradientLabel.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# —— 资源路径（必须在 add_child 前设，防止 _resolve_paths() 回退到 Global）——
	if not font_path.is_empty():
		_label.font_path_override = font_path
	_label.color_sheet_path_override = "res://art/System/Text color, 20 types (each 16 x 16).png"

	# 共享色表（避免重复 I/O，与标题画面 set_color_image() 同理）
	if _shared_color_img:
		_label.set_color_image(_shared_color_img)

	_shared_canvas.add_child(_label)

	# —— 效果属性（必须在 add_child 后设，覆盖 _enter_tree() 的 Global 默认值）——
	_label.text = text_override if not text_override.is_empty() else str(int(amount))
	_label.text_font_size = font_size
	_label.color_index = color_index
	_label.color_row = color_row
	_label.bold = bold
	_label.shadow = shadow_enabled
	_label.shadow_color = Color(0, 0, 0, 1)
	_label.shadow_offset = Vector2(2, 2)
	_label.outline = false


# ═══════════════════════════════════════
# 坐标转换
# ═══════════════════════════════════════

func _world_to_screen(world_pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if not vp:
		return world_pos
	return vp.get_canvas_transform() * world_pos


# ═══════════════════════════════════════
# 缓动函数
# ═══════════════════════════════════════

func _apply_easing(t: float) -> float:
	match easing_type:
		EasingType.LINEAR:
			return t
		EasingType.EASE_IN_QUAD:
			return t * t
		EasingType.EASE_OUT_QUAD:
			return 1.0 - (1.0 - t) * (1.0 - t)
		EasingType.EASE_IN_OUT_QUAD:
			if t < 0.5:
				return 2.0 * t * t
			else:
				var u: float = -2.0 * t + 2.0
				return 1.0 - u * u / 2.0
		EasingType.EASE_OUT_CUBIC:
			return 1.0 - pow(1.0 - t, 3.0)
		EasingType.EASE_OUT_EXPO:
			if t >= 1.0:
				return 1.0
			return 1.0 - pow(2.0, -10.0 * t)
		EasingType.EASE_OUT_BACK:
			const c1: float = 1.70158
			const c3: float = c1 + 1.0
			return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0)
		EasingType.EASE_OUT_ELASTIC:
			if t <= 0.0:
				return 0.0
			if t >= 1.0:
				return 1.0
			return pow(2.0, -10.0 * t) * sin((t - 0.075) * TAU / 0.3) + 1.0
		EasingType.EASE_OUT_BOUNCE:
			return _ease_out_bounce(t)
		_:
			return t


func _ease_out_bounce(t: float) -> float:
	const n1: float = 7.5625
	const d1: float = 2.75
	if t < 1.0 / d1:
		return n1 * t * t
	elif t < 2.0 / d1:
		var u: float = t - 1.5 / d1
		return n1 * u * u + 0.75
	elif t < 2.5 / d1:
		var u: float = t - 2.25 / d1
		return n1 * u * u + 0.9375
	else:
		var u: float = t - 2.625 / d1
		return n1 * u * u + 0.984375


# ═══════════════════════════════════════
# 清理
# ═══════════════════════════════════════

func _cleanup() -> void:
	if _label and is_instance_valid(_label):
		_label.queue_free()
		_label = null
	queue_free()
