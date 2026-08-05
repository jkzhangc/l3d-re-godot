class_name ScriptedEventTrigger extends Area2D
## 剧本事件触发器 — 放置在地图中，玩家进入区域时触发防守事件
##
## 支持 Crescendo（计时防守）、Finale（最终章节）、Alarm（警报）、
## Boss（Boss 出场）、Horde（直接尸潮）五种事件类型
##
## 触发后通知 Director→EventManager 接管节奏和生成

# ═══════════════════════════════════════
# 枚举
# ═══════════════════════════════════════
enum EventType { CRESCENDO, FINALE, ALARM, BOSS, HORDE }

# ═══════════════════════════════════════
# 配置
# ═══════════════════════════════════════
@export var event_type: int = EventType.CRESCENDO  ## 事件类型
@export var event_duration: float = 60.0            ## 防守时长（秒）。Crescendo/Finale/Alarm 计时防守；Boss/Horde 忽略
@export var spawn_interval: float = 3.0             ## 生成间隔（秒），每过此间隔出一波敌人
@export var spawn_per_wave: int = 3                 ## 每波敌人数
@export var max_active: int = 12                    ## 事件期间最大存活敌人数
@export var one_shot: bool = true                   ## 是否只触发一次
@export var auto_trigger: bool = true               ## true=玩家进入区域自动触发, false=需手动调用 trigger()
@export var event_name: String = ""                 ## 事件标识符（可选，用于信号/日志）
@export var hint_message: String = "防守直到警报停止！"  ## 触发时 HUD 提示文字

@export_group("触发区域外观（调试）")
@export var show_debug_rect: bool = true            ## 是否绘制触发区域矩形
@export var debug_rect_color: Color = Color(1.0, 0.3, 0.0, 0.3)  ## 区域颜色

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal event_triggered(event_name: String)
signal event_completed(event_name: String)

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var _triggered: bool = false
var _is_active: bool = false

# ═══════════════════════════════════════
# 生命周期
# ═══════════════════════════════════════

func _ready() -> void:
	if auto_trigger:
		var cb: Callable = _on_body_entered
		body_entered.connect(cb)

	if event_name.is_empty():
		event_name = name if not name.is_empty() else "UnnamedEvent"

	# 创建提示标签（编辑器中可见）
	if not has_node("HintLabel"):
		var label := Label.new()
		label.name = "HintLabel"
		label.text = event_name
		label.add_theme_font_size_override("font_size", 11)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.position = Vector2(-60, -28)
		label.size = Vector2(120, 20)
		label.modulate = Color(1, 1, 1, 0.6)
		add_child(label)


func _draw() -> void:
	if not show_debug_rect:
		return

	# 绘制触发区域边框
	if has_node("CollisionShape2D"):
		var cs: CollisionShape2D = $CollisionShape2D as CollisionShape2D
		if cs and cs.shape:
			var shape: RectangleShape2D = cs.shape as RectangleShape2D
			if shape:
				var rect := Rect2(-shape.size / 2.0, shape.size)
				draw_rect(rect, debug_rect_color, true)
				draw_rect(rect, Color(debug_rect_color.r, debug_rect_color.g, debug_rect_color.b, 0.8), false, 2.0)


# ═══════════════════════════════════════
# 触发
# ═══════════════════════════════════════

func _on_body_entered(body: Node2D) -> void:
	if _triggered and one_shot:
		return
	if not body is CharacterBody2D:
		return
	if not body.has_method("get_weapon_data"):
		return

	trigger()


## 手动触发事件（auto_trigger=false 时由外部调用）
func trigger() -> void:
	if _triggered and one_shot:
		return

	_triggered = true
	_is_active = true
	print("[EventTrigger] 触发: %s (type=%d, duration=%.1fs)" % [event_name, event_type, event_duration])

	# 通知 Director → EventManager
	var director: Node = get_node_or_null("/root/Director")
	if not director:
		printerr("[EventTrigger] Director autoload 未找到！")
		return

	if director.has_method("start_scripted_event"):
		director.start_scripted_event(_build_config())
	else:
		printerr("[EventTrigger] Director 没有 start_scripted_event 方法")

	event_triggered.emit(event_name)


## 事件完成回调（由 EventManager 调用）
func on_event_completed() -> void:
	if not _is_active:
		return
	_is_active = false
	print("[EventTrigger] 完成: %s" % event_name)

	# 禁用碰撞体（防止再次触发）
	if one_shot:
		monitoring = false
		for child: Node in get_children():
			if child is CollisionShape2D:
				child.disabled = true

	event_completed.emit(event_name)


# ═══════════════════════════════════════
# 内部
# ═══════════════════════════════════════

func _build_config() -> Dictionary:
	return {
		"event_name": event_name,
		"event_type": event_type,
		"event_duration": event_duration,
		"spawn_interval": spawn_interval,
		"spawn_per_wave": spawn_per_wave,
		"max_active": max_active,
		"trigger_node": self,  # 用于完成回调
	}


func is_active() -> bool:
	return _is_active
