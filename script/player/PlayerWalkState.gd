extends "res://script/player/PlayerGroundState.gd"

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State，继承 PlayerGroundState）
## 联机：Host 注入已验证输入
## 职责：行走状态：按住行走键时的低速移动与外观分支。
## 依赖：PlayerGroundState、Player 实体、PlayerState

## 行走状态只负责移动速度/外观分支；武器和攻击状态通过 transition_requested 切入。
## 行走状态 — 按住行走键移动


func enter() -> void:
	character.update_appearance(true, true)


func process_update(_delta: float) -> void:
	## 武器/消耗品/投掷输入由基类统一消费（逻辑与优先级同旧实现）。
	if _consume_common_inputs():
		return

	var move_dir: Vector2 = PlayerInput.move_vector()
	if move_dir == Vector2.ZERO:
		transition_requested.emit("Idle")
		return

	if not PlayerInput.is_walk_held():
		transition_requested.emit("Run")
		return

	character.update_facing(move_dir)


func physics_update(delta: float) -> void:
	character.velocity = PlayerInput.move_vector() * character.walk_speed
	character.move_with_corner_assist()
