extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 物理模拟
## 职责：击退状态：沿受击方向位移并可连锁推动附近敌人，结束后回到 Chase。
## 依赖：State、enemy 实体

## 击退位移由 Host 物理模拟，结束后回到 Chase；Client 只跟随快照。
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
## ★闪避第二阶段（2026-10-31）：侧移结束后朝玩家高速突进的剩余时长 / 速度。
var _dash_left: float = 0.0
var _dash_speed: float = 0.0


func enter() -> void:
	var enemy: Node2D = character
	enemy.update_moving(false)

	# 读取击退参数（由 enemy.take_damage() 在切换状态前设置）
	_knockback_velocity = enemy._knockback_dir * enemy._knockback_force
	_stun_timer = enemy._knockback_stun

	# 朝向伤害来源方向
	enemy.update_facing_from_direction(-enemy._knockback_dir)

	## 闪避第二段：正面走位标记 → 侧移结束后朝玩家高速突进（原作手感）。
	_dash_left = 0.0
	_dash_speed = 0.0
	if enemy.get("_dodge_dash_pending") == true:
		enemy.set("_dodge_dash_pending", false)
		_dash_left = float(enemy.get("frontal_dodge_dash_time"))
		_dash_speed = float(enemy.get("frontal_dodge_dash_force"))
		if _dash_left > 0.0 and _dash_speed > 0.0:
			enemy.update_moving(true)   # 突进时播行走帧，别像滑行
			print("[閃避] 侧移后接突进：%.0f / %.2fs" % [_dash_speed, _dash_left])

	print("[擊退] 进入击退状态 | force=%.0f stun=%.2fs dir=%s" % [
		enemy._knockback_force, _stun_timer, enemy._knockback_dir])


func exit() -> void:
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	## 突进阶段由 physics_update 自己计时；此处直接返回，避免侧移硬直一到期就切走。
	if _dash_left > 0.0:
		return
	_stun_timer -= delta
	if _stun_timer <= 0.0:
		## 2026-10-30：击退结束若还欠一段硬直（爆炸震慑 / 胖虎 SA），
		## 先进 Hitstun 把「几秒不能动」补完，再回 Chase。
		if character._hitstun_after_knockback and character._hitstun_duration > 0.0:
			character._hitstun_after_knockback = false
			print("[擊退] 击退结束 → 追加硬直 %.2fs" % character._hitstun_duration)
			transition_requested.emit("Hitstun")
			return
		print("[擊退] 硬直结束 → 追击")
		transition_requested.emit("Chase")


func physics_update(delta: float) -> void:
	var enemy_node: Node2D = character
	## ── 第二阶段：朝最近玩家高速突进（不衰减，按时间收尾）──
	if _dash_left > 0.0:
		_dash_left -= delta
		var target: Node2D = null
		if Players != null and Players.has_method("nearest_entity_to"):
			target = Players.nearest_entity_to(enemy_node.global_position)
		if target != null and is_instance_valid(target):
			var to_target: Vector2 = target.global_position - enemy_node.global_position
			if to_target.length() > 1.0:
				var dir: Vector2 = to_target.normalized()
				enemy_node.move_and_collide(dir * _dash_speed * delta)
				enemy_node.update_facing_from_direction(dir)
				_chain_push_nearby_enemies(enemy_node, dir * _dash_speed)
		if _dash_left <= 0.0:
			_dash_left = 0.0
			enemy_node.update_moving(false)
		return
	# 应用击退速度（逐帧衰减）
	if _knockback_velocity.length() > 1.0:
		var motion: Vector2 = _knockback_velocity * delta
		var enemy: Node2D = character
		enemy.move_and_collide(motion)
		# 线性减速
		_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, DECELERATION * delta)
		# 连锁推挤（仅一级）：被击退的敌人推开附近敌人，但被推开的不再连锁
		_chain_push_nearby_enemies(enemy, _knockback_velocity)
	else:
		_knockback_velocity = Vector2.ZERO


## 连锁推挤：被击退的敌人把**身前一排**的同伴一起顶开。
## ★2026-10-31 用户实测修复「四个排成一列，第一个被击退后，后面一两只定着不动」。
## 旧实现：`chain_force = 自身速度 × 0.85 × (1 - dist/36)`。列队时相邻两只正好贴靠（dist≈32）
## → falloff≈0.11 → 传递力度只剩 ~39px/s，配 `DECELERATION=600` 只能挪 1~2px；
## 再往下一跳又按"被推者的当前速度"继续衰减 → 第三只 ~3px/s 低于阈值，整列就断在那里。
## 现在改为**每跳固定基准力度 + 温和距离衰减**：力度不随父级速度衰减，
## 所以一列上的每只都被顶开相近的距离，不会越传越弱。
const CHAIN_PUSH_RADIUS: float = 40.0        ## 检测半径（≥ 两个身位贴靠）
const CHAIN_PUSH_BASE_FORCE: float = 380.0   ## 每跳基准力度（位移 ≈ 76px）
const CHAIN_PUSH_MIN_FACTOR: float = 0.6     ## 最远端的力度下限倍率
const CHAIN_PUSH_MIN_VEL: float = 20.0       ## 自身速度低于此值不再传递（已在滑停）
const CHAIN_PUSH_STUN: float = 0.25          ## 连锁推挤的位移时长（秒）

func _chain_push_nearby_enemies(enemy: Node2D, knockback_vel: Vector2) -> void:
	var tree: SceneTree = enemy.get_tree()
	if not tree:
		return
	var vel_mag: float = knockback_vel.length()
	if vel_mag < CHAIN_PUSH_MIN_VEL:
		return
	var dir_norm: Vector2 = knockback_vel.normalized()
	var my_pos: Vector2 = enemy.global_position
	var pushed_count: int = 0
	for other in tree.get_nodes_in_group("enemy"):
		if other == enemy:
			continue
		if not is_instance_valid(other):
			continue
		if other.get("_is_dead") == true:
			continue
		# 已经在被击退的不重复施加（防互相无限弹）
		var sm: Node = other.get_node_or_null("StateMachine")
		if sm and sm.current_state and String(sm.current_state.name) == "Knockback":
			continue
		var other_pos: Vector2 = other.global_position
		var offset: Vector2 = other_pos - my_pos
		var dist: float = offset.length()
		if dist <= 0.01 or dist >= CHAIN_PUSH_RADIUS:
			continue
		# 只顶「被击退方向前方」的同伴；侧后方的不动（否则尸潮里会互相乱撞）
		if offset.normalized().dot(dir_norm) < 0.2:
			continue
		var t: float = clampf(1.0 - dist / CHAIN_PUSH_RADIUS, 0.0, 1.0)
		var chain_force: float = CHAIN_PUSH_BASE_FORCE * lerpf(CHAIN_PUSH_MIN_FACTOR, 1.0, t)
		var chain_dir: Vector2 = (offset.normalized() * 0.7 + dir_norm * 0.3).normalized()
		if other.has_method("take_damage"):
			other.take_damage(0.0, chain_force, chain_dir, false, CHAIN_PUSH_STUN, 0.0)
			pushed_count += 1
	if pushed_count > 0:
		print("[连锁推挤] %s 顶开 %d 只（基准力度 %.0f）" % [enemy.name, pushed_count, CHAIN_PUSH_BASE_FORCE])
