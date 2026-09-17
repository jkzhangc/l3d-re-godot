extends State

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State，占位）
## 联机：未接入
## 职责：旧版通用攻击骨架，实际手枪/小刀逻辑已分别由专用状态实现，本类仅保留占位与 TODO。
## 依赖：State

## 旧版通用攻击占位状态，具体手枪/小刀逻辑分别由专用状态实现。
## 攻击状态 — 占位骨架，后续实现武器攻击逻辑
##
## TODO:
##   - 播放攻击动画（根据武器类型选择）
##   - 生成攻击判定区域（Area2D / 射线）
##   - 动画结束后自动切回 Idle


func enter() -> void:
	## TODO: 播放攻击动画，锁定移动
	pass


func process_update(_delta: float) -> void:
	## TODO: 动画播放完毕后 → transition_requested.emit("Idle")
	pass


func physics_update(_delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_with_corner_assist()
