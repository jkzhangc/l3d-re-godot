extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 决定状态迁移
## 职责：发现状态：短暂播放「!」提示作为节奏缓冲，随后进入 Chase。
## 依赖：State、enemy 实体

## 发现阶段是短暂的视觉/节奏状态，结束后才进入 Chase；联机状态由 Host 快照决定。
## 发现玩家 — 显示 "!" 表情符号，持续 2 秒后开始追击

var _timer: float = 0.0
const DISCOVER_DURATION: float = 0.5


func enter() -> void:
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_timer = DISCOVER_DURATION

	# 播放发现音效
	var enemy: Node2D = character
	enemy._play_sound(enemy.get_discover_sound(), enemy.get_discover_pitch())

	# 显示 "!"
	var label: Label = character.get_node_or_null("DiscoverLabel") as Label
	if label:
		label.text = "!"
		label.show()


func exit() -> void:
	# 隐藏 "!"
	var label: Label = character.get_node_or_null("DiscoverLabel") as Label
	if label:
		label.hide()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	_timer -= delta
	if _timer <= 0.0:
		transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	character.move_with_corner_assist()
