extends State
## 击退/硬直状态 — 被击退子弹命中后进入
##
## 行为：
##   1. 沿子弹方向以 knockback_force 速度被推开
##   2. 速度逐帧线性衰减
##   3. 硬直期间不能移动/攻击
##   4. 硬直结束后自动切回 Chase 状态

## 击退速度衰减率（像素/秒²）— 控制击退多快停下
const DECELERATION: float = 600.0

var _knockback_velocity: Vector2 = Vector2.ZERO
var _stun_timer: float = 0.0


func enter() -> void:
	var enemy: Node2D = character
	enemy.update_moving(false)

	# 读取击退参数（由 enemy.take_damage() 在切换状态前设置）
	_knockback_velocity = enemy._knockback_dir * enemy._knockback_force
	_stun_timer = enemy._knockback_stun

	# 朝向伤害来源方向
	enemy.update_facing_from_direction(-enemy._knockback_dir)

	print("[擊退] 进入击退状态 | force=%.0f stun=%.2fs dir=%s" % [
		enemy._knockback_force, _stun_timer, enemy._knockback_dir])


func exit() -> void:
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	_stun_timer -= delta
	if _stun_timer <= 0.0:
		print("[擊退] 硬直结束 → 追击")
		transition_requested.emit("Chase")


func physics_update(delta: float) -> void:
	# 应用击退速度（逐帧衰减）
	if _knockback_velocity.length() > 1.0:
		var motion: Vector2 = _knockback_velocity * delta
		var enemy: Node2D = character
		enemy.move_and_collide(motion)
		# 线性减速
		_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, DECELERATION * delta)
	else:
		_knockback_velocity = Vector2.ZERO
