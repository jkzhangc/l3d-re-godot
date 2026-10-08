extends "res://script/player/PlayerGroundState.gd"

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State，继承 PlayerGroundState）
## 联机：Host 注入已验证输入
## 职责：站立状态：速度归零，消费武器/消耗品/投掷/举枪等边沿输入，按移动输入切 Walk/Run。
## 依赖：PlayerGroundState、Player 实体、PlayerState

## 单机由本状态读取本地输入；联机 Host 不走这里读取键盘，而由 NetworkWorld 注入已验证输入。
## 站立状态 — 玩家不移动时


func enter() -> void:
	character.velocity = Vector2.ZERO
	character.update_appearance(false, false)


func process_update(_delta: float) -> void:
	## 武器/消耗品/投掷输入由基类统一消费（逻辑与优先级同旧实现）。
	if _consume_common_inputs():
		return

	var move_dir: Vector2 = PlayerInput.move_vector()
	if move_dir == Vector2.ZERO:
		return

	if PlayerInput.is_walk_held():
		transition_requested.emit("Walk")
	else:
		transition_requested.emit("Run")


func physics_update(delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_with_corner_assist()
