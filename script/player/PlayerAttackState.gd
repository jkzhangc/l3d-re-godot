extends State
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
	character.move_and_slide()
