extends Node2D

## ── 架构定位 ──
## 系统：调试可视化 ｜ 层：工具类（Node2D，攻击状态临时创建、退出即释放）
## 联机：仅本机调试；`Global.debug_visuals` 关闭时攻击状态根本不会创建它
## 职责：画一个**轴对齐**的攻击判定矩形：判定区生成前是虚线预测框，生成后是实线真实判定区。
## 依赖：Global.debug_visuals（TAB 总开关）、ThemeDB 兜底字体（标注文字）
##
## 【为什么是轴对齐而不是旋转矩形】玩家的近战 / 推击判定用的是
## `RectangleShape2D` + `CollisionShape2D.position = 0`，**没有 rotation** ——
## 世界里就是一个正放的矩形（size.x 横向、size.y 纵向）。敌人攻击用的是
## 「投影法 + 朝向旋转」（`EnemyAttackState._is_target_in_hit_rect`），两者不同。
## 这里若画成旋转矩形，会让人以为"左右砍比上下砍远"，与真实判定不符。
##
## 【为什么单独开节点，而不是画在 player._draw() 里】player.gd **全程没有 queue_redraw()**，
## `_draw()` 只在首次绘制与树结构变化时执行 —— 挂在那里等于一次性静态图。
## 本节点由攻击状态每帧驱动 `update_region()` 并按需重绘，生命周期与攻击动作严格对齐。

const ACTIVE_COLOR := Color(1.0, 0.35, 0.2)        ## 判定区已生成（真实生效范围）
const PREVIEW_COLOR := Color(1.0, 0.85, 0.3, 0.85) ## 判定区未生成（预测，虚线）
const SPLASH_COLOR := Color(0.35, 0.85, 1.0, 0.55)

var region_size: Vector2 = Vector2.ZERO
var active: bool = false
var caption: String = ""
var splash_radius: float = 0.0

var _debug_on: bool = true


func _ready() -> void:
	## 判定框必须压在角色/敌人上面（本节点与 hitbox 同级挂在 current_scene 下）。
	z_index = 200
	z_as_relative = true


## 由攻击状态每帧调用。`global_pos` = 判定矩形中心（世界坐标）。
## `size` = 判定矩形尺寸（宽×高，轴对齐）；`is_active` = 真实判定区是否已生成。
## `text` = 左上角标注（如 "近战 48×32"）；`splash` > 0 时额外画溅射圈（推击）。
func update_region(global_pos: Vector2, size: Vector2, is_active: bool,
		text: String = "", splash: float = 0.0) -> void:
	var changed: bool = global_pos != global_position or size != region_size \
		or is_active != active or text != caption or splash != splash_radius
	## TAB 中途开关也要立刻重绘：否则关闭后上一帧的框会一直留在屏幕上。
	var dbg: bool = bool(Global.debug_visuals)
	if dbg != _debug_on:
		_debug_on = dbg
		changed = true
	global_position = global_pos
	region_size = size
	active = is_active
	caption = text
	splash_radius = splash
	if changed:
		queue_redraw()


func _draw() -> void:
	if not _debug_on or not Global.debug_visuals:
		return
	if region_size.x <= 0.0 or region_size.y <= 0.0:
		return

	var rect := Rect2(-region_size * 0.5, region_size)
	if active:
		## 真实判定区：半透明填充 + 实线描边（命中帧之后，位置已固定，不再跟随角色）
		draw_rect(rect, Color(ACTIVE_COLOR.r, ACTIVE_COLOR.g, ACTIVE_COLOR.b, 0.16), true)
		draw_rect(rect, ACTIVE_COLOR, false, 2.0)
	else:
		## 预测框：虚线（还没到命中帧，角色仍可转向，框会跟着转）
		_dashed_rect(rect, PREVIEW_COLOR, 1.5, 5.0, 4.0)

	if splash_radius > 0.0:
		draw_arc(Vector2.ZERO, splash_radius, 0.0, TAU, 32, SPLASH_COLOR, 1.5)
		draw_arc(Vector2.ZERO, splash_radius * 0.5, 0.0, TAU, 24,
			Color(SPLASH_COLOR.r, SPLASH_COLOR.g, SPLASH_COLOR.b, 0.18), 1.0)

	if not caption.is_empty():
		var color: Color = ACTIVE_COLOR if active else PREVIEW_COLOR
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(1, -5), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)


func _dashed_rect(rect: Rect2, color: Color, width: float, dash: float, gap: float) -> void:
	var p0 := rect.position
	var p1 := Vector2(rect.end.x, rect.position.y)
	var p2 := rect.end
	var p3 := Vector2(rect.position.x, rect.end.y)
	_dashed_line(p0, p1, color, width, dash, gap)
	_dashed_line(p1, p2, color, width, dash, gap)
	_dashed_line(p2, p3, color, width, dash, gap)
	_dashed_line(p3, p0, color, width, dash, gap)


func _dashed_line(from: Vector2, to: Vector2, color: Color, width: float,
		dash: float, gap: float) -> void:
	var total: float = from.distance_to(to)
	if total <= 0.0:
		return
	var dir: Vector2 = (to - from) / total
	var step: float = dash + gap
	var t: float = 0.0
	while t < total:
		var seg_end: float = minf(t + dash, total)
		draw_line(from + dir * t, from + dir * seg_end, color, width)
		t += step
