class_name BurnEffect extends Sprite2D

## ── 架构定位 ──
## 系统：灼烧状态视觉 ｜ 层：表现（Sprite2D）
## 联机：各端独立表现（点燃/熄灭由本端 take_damage / DoT 逻辑驱动，无 RPC）
## 职责：燃烧中单位身上的跟随火焰行走图（与 FirePatch 同素材同帧切法，覆盖身体中上部）
## 依赖：无（纯表现；attach/detach 由 player.gd / enemy.gd 调用）

const TEXTURE_PATH := "res://art/misc/天罰キャラチップ.png"
const FRAME_W: int = 48
const FRAME_H: int = 64
const CHARS_PER_ROW: int = 4
const STEP_FRAMES: int = 3          ## 每个方向的踏步帧数（VX Ace 3 列）
const DIRECTIONS: int = 4
const FRAME_DURATION: float = 0.1   ## 火精灵动画帧间隔
const TOTAL_FRAMES: int = STEP_FRAMES * DIRECTIONS

## 角色索引 2 = 火海同款红色火（item_molotov.tres fire_char_idx=2；0 号是黄火）
const CHAR_IDX: int = 2
const BODY_OFFSET := Vector2(0, -16)  ## 覆盖身体中上部（角色原点在脚部）
## 尺寸与火海一致：原帧 48×64 全尺寸（2026-09-15 用户反馈 0.6 太小）

var _frame: int = 0
var _frame_timer: float = 0.0


## 给单位挂上燃烧视觉（已挂则复用，不重复叠加）。返回实例（可能为 null：宿主不在树中）。
static func attach(host: Node2D) -> BurnEffect:
	if host == null or not host.is_inside_tree():
		return null
	var existing := host.get_node_or_null(^"BurnEffect") as BurnEffect
	if existing:
		return existing
	var effect := BurnEffect.new()
	effect.name = "BurnEffect"
	host.add_child(effect)
	return effect


## 摘掉燃烧视觉（不存在则无操作）。
static func detach(host: Node2D) -> void:
	if host == null:
		return
	var existing := host.get_node_or_null(^"BurnEffect")
	if existing:
		existing.queue_free()


func _ready() -> void:
	var tex: Texture2D = load(TEXTURE_PATH)
	if tex:
		texture = tex
		region_enabled = true
		_frame = randi() % TOTAL_FRAMES
		region_rect = _fire_region(_frame)
	else:
		printerr("[BurnEffect] 火精灵表加载失败: %s" % TEXTURE_PATH)
	position = BODY_OFFSET
	# 尺寸=原帧全尺寸（与火海一致），不缩放；z_index 保持 0（相对宿主）：
	# 后 add_child 画在宿主贴图上，有效 z 仍属单位层（z=1），不会盖过 UpperLayer。


func _process(delta: float) -> void:
	_frame_timer += delta
	if _frame_timer >= FRAME_DURATION:
		_frame_timer = 0.0
		_frame = (_frame + 1) % TOTAL_FRAMES
		region_rect = _fire_region(_frame)


func _fire_region(flat: int) -> Rect2:
	# 与 FirePatch 同切法（角色索引 CHAR_IDX=2，火海同款红火）：按帧先切方向行，再切踏步列
	var dir: int = flat / STEP_FRAMES
	var col: int = flat % STEP_FRAMES
	var char_col: int = CHAR_IDX % CHARS_PER_ROW
	var char_row: int = CHAR_IDX / CHARS_PER_ROW
	var x: int = char_col * (FRAME_W * STEP_FRAMES) + col * FRAME_W
	var y: int = char_row * (FRAME_H * DIRECTIONS) + dir * FRAME_H
	return Rect2(x, y, FRAME_W, FRAME_H)
