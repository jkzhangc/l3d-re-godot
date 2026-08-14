extends Node2D
## 治疗品/投掷物拾取物 — 放在地图上供玩家拾取
##
## 治疗品/辅助品：触碰自动拾取。
## 投掷物：空槽自动拾取；已持有则按住「确定键」替换（旧投掷物掉落回地面）。
##
## 支持 VX Ace 行走图渲染（与武器拾取物相同）：当 ItemData.pickup_texture 已配置时，
## 用 region 帧渲染 + 原地踏步动画；未配置则回退到 ItemData.icon 整图显示。

# ═══════════════════════════════════════
# 精灵帧常量
# ═══════════════════════════════════════
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const DIRECTIONS: int = 4

## 拾取物模板场景（投掷物替换时掉落旧投掷物用）
const PICKUP_SCENE := preload("res://object/healing_pickup.tscn")
## 掉落物短时间不可拾取，防止替换后立即重新拾取造成循环
const PICKUP_DELAY_MSEC: int = 600

const INDICATOR_SCRIPT := preload("res://script/hold_indicator.gd")

@export var item: ItemData  ## 要给予的物品（治疗品/投掷物）

@export_group("Hold Settings")
## 按住替换所需时长（秒）
@export var hold_time: float = 1.2

@export_group("Hold Indicator")
## 是否启用按住进度指示器（圆环填充动画）
@export var hold_indicator_enabled: bool = true
## 指示器圆环半径（像素）
@export var hold_indicator_radius: float = 18.0
## 圆环线宽（像素）
@export var hold_indicator_thickness: float = 3.0
## 指示器位置偏移（相对拾取物原点，Y轴向上为负）
@export var hold_indicator_offset: Vector2 = Vector2(0, -48)
## 进度填充颜色
@export var hold_indicator_color: Color = Color(1.0, 0.9, 0.2, 1.0)
## 背景圆环颜色
@export var hold_indicator_bg_color: Color = Color(0.0, 0.0, 0.0, 0.55)
## 淡入淡出速度（alpha/秒，值越大过渡越快）
@export var hold_indicator_fade_speed: float = 5.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D

var _step_idx: int = 0           ## 当前踏步帧在序列中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器
var _spawn_msec: int = 0         ## 生成时刻（掉落物拾取冷却用）
var _player_in_range: bool = false
var _player_ref: CharacterBody2D = null
var _hold_timer: float = 0.0
var _indicator_alpha: float = 0.0
var _indicator_node: Node2D = null


func _ready() -> void:
	_spawn_msec = Time.get_ticks_msec()
	if _area:
		_area.body_entered.connect(_on_body_entered)
		_area.body_exited.connect(_on_body_exited)
	_refresh_sprite()

	# 创建按住进度指示器子节点（z_index 高于精灵，确保圆环绘制在精灵上方）
	if hold_indicator_enabled:
		_indicator_node = Node2D.new()
		_indicator_node.name = "HoldIndicator"
		_indicator_node.z_index = 10
		_indicator_node.set_script(INDICATOR_SCRIPT)
		_indicator_node._pickup = self
		add_child(_indicator_node)


func _process(delta: float) -> void:
	# 踏步动画（仅行走图模式下生效）
	if item and item.pickup_texture and item.pickup_animated:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var dur: float = item.pickup_step_duration if item.pickup_step_duration > 0.0 else 0.25
		_step_timer += delta
		if _step_timer >= dur:
			_step_timer -= dur
			_step_idx = (_step_idx + 1) % frames.size()
			_refresh_sprite()

	_process_pickup(delta)


func _process_pickup(delta: float) -> void:
	if not _player_in_range or not _player_ref:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return
	if not item:
		return
	# 掉落物短时间不可拾取，防止替换后立即重新拾取循环
	if Time.get_ticks_msec() - _spawn_msec < PICKUP_DELAY_MSEC:
		return

	# 仅投掷物且已持有 → 需按住确定键替换；其余自动拾取
	var needs_hold: bool = item.item_type == ItemData.ItemType.THROWABLE and Global.throwable != null
	if not needs_hold:
		_do_pickup()
		return

	# 玩家正在武器/投掷物举起/瞄准状态，不触发替换（避免与确定键瞄准冲突）
	if _player_ref.get("player_in_weapon_state"):
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)
		return

	if Input.is_action_pressed("确定键"):
		_hold_timer += delta
		_update_hold_indicator(delta, true)
		if _hold_timer >= hold_time:
			_do_pickup()
	else:
		_hold_timer = 0.0
		_update_hold_indicator(delta, false)


func _do_pickup() -> void:
	if not item:
		return
	# 投掷物单槽位：已持有则先掉落旧的（同副武器替换逻辑）
	if item.item_type == ItemData.ItemType.THROWABLE and Global.throwable:
		_drop_old_throwable(_player_ref)
	Global.pickup_consumable(item)
	queue_free()


func _drop_old_throwable(body: Node2D) -> void:
	## 将旧的投掷物生成为地面拾取物，掉落在玩家脚下。
	var old: ThrowableData = Global.throwable
	if not old:
		return
	var drop: Node2D = PICKUP_SCENE.instantiate()
	drop.item = old
	drop.position = body.global_position
	var parent: Node = get_parent()
	if not parent:
		parent = get_tree().current_scene
	parent.add_child(drop)
	print("[拾取] 投掷物替换: %s → %s" % [old.item_name, item.item_name])


func _refresh_sprite() -> void:
	if not _sprite or not item:
		return

	# 行走图模式：ItemData 配置了地面精灵表
	if item.pickup_texture:
		var frames: Array[int] = item.pickup_step_frames
		if frames.is_empty():
			frames = [1, 0, 1, 2]
		var frame: int
		if item.pickup_animated and frames.size() > 0:
			frame = frames[_step_idx]
		else:
			frame = frames[0] if frames.size() > 0 else 1

		var char_col: int = item.pickup_char_idx % CHARS_PER_ROW
		var char_row: int = item.pickup_char_idx / CHARS_PER_ROW
		var x: int = char_col * (FRAME_W * 3) + frame * FRAME_W
		var y: int = char_row * (FRAME_H * DIRECTIONS) + item.pickup_direction * FRAME_H

		_sprite.texture = item.pickup_texture
		_sprite.region_enabled = true
		_sprite.region_rect = Rect2(x, y, FRAME_W, FRAME_H)
		return

	# 回退：整图显示 icon
	if item.icon:
		_sprite.texture = item.icon
		_sprite.region_enabled = false


func _on_body_entered(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player:
		_player_in_range = true
		_player_ref = player
		_hold_timer = 0.0


func _on_body_exited(body: Node2D) -> void:
	var player: CharacterBody2D = body as CharacterBody2D
	if player and player == _player_ref:
		_player_in_range = false
		_player_ref = null
		_hold_timer = 0.0


func _update_hold_indicator(delta: float, is_holding: bool) -> void:
	## 更新按住进度指示器的淡入/淡出透明度，并触发重绘
	if not hold_indicator_enabled or not _indicator_node:
		return
	var target: float = 1.0 if is_holding else 0.0
	_indicator_alpha = move_toward(_indicator_alpha, target, hold_indicator_fade_speed * delta)
	if _indicator_alpha > 0.001 or _hold_timer > 0.0:
		_indicator_node.queue_redraw()


func _indicator_draw(node: Node2D) -> void:
	## 由 hold_indicator.gd 子节点的 _draw() 回调
	## 绘制背景圆环 + 进度填充弧线
	if _indicator_alpha <= 0.001:
		return

	var progress: float = clampf(_hold_timer / hold_time, 0.0, 1.0)
	var center: Vector2 = hold_indicator_offset
	var radius: float = hold_indicator_radius
	var thickness: float = hold_indicator_thickness
	var pts: int = 64

	var bg: Color = hold_indicator_bg_color
	bg.a *= _indicator_alpha
	node.draw_arc(center, radius, 0, TAU, pts, bg, thickness, true)

	if progress > 0.0:
		var fg: Color = hold_indicator_color
		fg.a *= _indicator_alpha
		var start_angle: float = -PI / 2.0
		var end_angle: float = start_angle + progress * TAU
		node.draw_arc(center, radius, start_angle, end_angle, pts, fg, thickness, true)
