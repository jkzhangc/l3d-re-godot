extends "res://script/player/PlayerGroundState.gd"

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State，继承 PlayerGroundState）
## 联机：Host 注入已验证输入
## 职责：跑步状态（默认移动方式）：全速移动，承载武器/消耗品/投掷入口。
## 依赖：PlayerGroundState、Player 实体、PlayerState

## 跑步状态是默认移动状态；进入举枪、投掷、推击或装填后由状态机暂时接管输入。
## 跑步状态 — 默认移动方式


func enter() -> void:
	character.update_appearance(true, false)


func process_update(_delta: float) -> void:
	## 武器/消耗品/投掷输入由基类统一消费（逻辑与优先级同旧实现）。
	if _consume_common_inputs():
		return

	var move_dir: Vector2 = PlayerInput.move_vector()
	if move_dir == Vector2.ZERO:
		transition_requested.emit("Idle")
		return

	if PlayerInput.is_walk_held():
		transition_requested.emit("Walk")
		return

	character.update_facing(move_dir)


func physics_update(delta: float) -> void:
	character.velocity = PlayerInput.move_vector() * character.run_speed
	character.move_with_corner_assist()
