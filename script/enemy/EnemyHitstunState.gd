extends State
## 硬直不产生位移；命中来源和持续时间由权威伤害流程决定。
## 硬直状态 — 被击中后短暂冻结（无击退位移）
##
## 与击退状态的区别：
##   - 击退（Knockback）：沿子弹方向推开 + 硬直
##   - 硬直（Hitstun）：原地冻结，无位移
##
## 行为：
##   1. 硬直期间不能移动/攻击
##   2. 朝向伤害来源方向
##   3. 硬直结束后自动切回 Chase 状态

var _stun_timer: float = 0.0


func enter() -> void:
	var enemy: Node2D = character
	enemy.update_moving(false)

	# 读取硬直时长（由 enemy.take_damage() 在切换状态前设置）
	_stun_timer = enemy._hitstun_duration

	# 朝向伤害来源方向（如果有击退方向则用，否则保持当前朝向）
	if enemy._knockback_dir != Vector2.ZERO:
		enemy.update_facing_from_direction(-enemy._knockback_dir)

	print("[硬直] 进入硬直状态 | duration=%.2fs" % _stun_timer)


func exit() -> void:
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	_stun_timer -= delta
	if _stun_timer <= 0.0:
		print("[硬直] 硬直结束 → 追击")
		transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	# 硬直期间完全不移动
	pass
