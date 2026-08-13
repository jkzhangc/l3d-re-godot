extends Node2D
## 治疗品拾取物 — 放在地图上，玩家触碰自动拾取（增加医疗包数量）
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

@export var item: ItemData  ## 要给予的治疗品（ItemType.HEALING）

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _area: Area2D = $Area2D

var _step_idx: int = 0           ## 当前踏步帧在序列中的索引
var _step_timer: float = 0.0     ## 踏步帧计时器


func _ready() -> void:
	if _area:
		_area.body_entered.connect(_on_body_entered)
	_refresh_sprite()


func _process(delta: float) -> void:
	# 踏步动画（仅行走图模式下生效）
	if not item or not item.pickup_texture or not item.pickup_animated:
		return
	var frames: Array[int] = item.pickup_step_frames
	if frames.is_empty():
		frames = [1, 0, 1, 2]
	var dur: float = item.pickup_step_duration if item.pickup_step_duration > 0.0 else 0.25
	_step_timer += delta
	if _step_timer >= dur:
		_step_timer -= dur
		_step_idx = (_step_idx + 1) % frames.size()
		_refresh_sprite()


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
	if not item:
		return
	if body is CharacterBody2D and body.has_method("get_weapon_data"):
		Global.pickup_consumable(item)
		queue_free()
