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
		# 连锁推挤：被击退的敌人碰撞到附近敌人时，也推开它们
		_chain_push_nearby_enemies(enemy, _knockback_velocity)
	else:
		_knockback_velocity = Vector2.ZERO


## 连锁推挤：被击退的敌人碰到附近敌人时，也会推开它们
const CHAIN_PUSH_RADIUS: float = 32.0   ## 连锁推挤检测半径
const CHAIN_PUSH_FACTOR: float = 0.6    ## 连锁推挤力度系数（小于1，衰减传递）
const CHAIN_PUSH_FORCE_THRESHOLD: float = 5.0   ## 最小推挤力度（低于此值不传递）
const CHAIN_PUSH_STUN: float = 0.25     ## 连锁推挤硬直时长（秒）

func _chain_push_nearby_enemies(enemy: Node2D, knockback_vel: Vector2) -> void:
	var tree: SceneTree = enemy.get_tree()
	if not tree:
		return

	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var my_pos: Vector2 = enemy.global_position
	var vel_mag: float = knockback_vel.length()
	if vel_mag < 10.0:
		return

	var pushed_count: int = 0
	for other in enemies:
		if other == enemy:
			continue
		if not is_instance_valid(other):
			continue
		if other.get("_is_dead") == true:
			continue
		# 跳过已经处于击退中的敌人（它们已经在处理自己的连锁推挤）
		# 注意：硬直中的敌人不跳过 — 允许击退打断硬直（重置硬直计时）
		var sm: Node = other.get_node_or_null("StateMachine")
		if sm and sm.current_state:
			var sname: String = sm.current_state.name
			if sname == "Knockback":
				continue

		var other_pos: Vector2 = other.global_position
		var dist: float = my_pos.distance_to(other_pos)
		if dist < CHAIN_PUSH_RADIUS and dist > 0.01:
			# 推开方向：从被击退敌人指向附近敌人
			var push_dir: Vector2 = (other_pos - my_pos).normalized()
			# 推挤力度：距离越近越强，叠加击退速度方向的影响
			var falloff: float = 1.0 - (dist / CHAIN_PUSH_RADIUS)
			var chain_force: float = vel_mag * CHAIN_PUSH_FACTOR * falloff
			if chain_force < CHAIN_PUSH_FORCE_THRESHOLD:
				continue
			# 推开方向混合：70% 径向推开 + 30% 击退方向传递
			var chain_dir: Vector2 = (push_dir * 0.7 + knockback_vel.normalized() * 0.3).normalized()
			if other.has_method("take_damage"):
				# 0 伤害 + 连锁推挤力度（作为击退初速）+ 短硬直
				other.take_damage(0.0, chain_force, chain_dir, false, CHAIN_PUSH_STUN, 0.0)
				pushed_count += 1

	if pushed_count > 0:
		print("[连锁推挤] %s 推开了 %d 个附近敌人 | 自身速度=%.0f" % [enemy.name, pushed_count, vel_mag])
