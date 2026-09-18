class_name EnemySwallowState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：仅 Host 执行；命中后玩家进入「被吞」表现由快照同步（玩家隐藏 + 致死）
## 职责：丸呑み（ハンターγ 零距离必杀）—— 贴脸吞入玩家 → 咀嚼循环 → 吐出即死。
## 依赖：State、enemy 实体（swallow_* 参数）、player（take_damage / 隐藏表现）
##
## 原作依据（E:/15.L3D readme/enemy.html ハンターγ 条）：
##   「水陸両用のハンター改良種。……零距離で「丸呑み」という独自の必殺技を使用することがある。
##     これを食らうと大ダメージを受けるばかりか、多段削りで武器も駄目にされてしまうので、
##     接近する時（された時）は特に注意しよう。他のハンターに比べると耐久力も高く……」
##
## 动画编排（用户 2026-09-12 提供原作 y2 表现）：
##   0 → 1(丸呑み判定区) → 2 → 3
##   若丸呑み命中玩家：玩家消失 → 循环 2→3 多次 → 回到 1 → 吐出玩家
##   吐出 = 显示角色 + 角色直接死亡 + 切换到下一个角色；过一会回到 0；伤害为致死。
##
## 设计要点：
##   · 距离判定用「玩家与本体的距离」而非矩形 —— 零距离必杀，贴脸才有意义；
##   · 判定只在 1 帧（吞入帧）发生一次，成功则整段吞入，失败则收尾回 Chase；
##   · 咀嚼期间玩家不可见且不参与碰撞（避免被其他敌人继续打），
##     但玩家掉血/切人逻辑仍走 player._die() 正常通道（保留 ガッツ 之外的致死语义）。
##   · 致死语义：原作明确「伤害是致死」。ガッツ（HP≥2 保底 1）会拦住致命伤，
##     所以致死路径直接调用 player 的致死入口，而不是发一个巨大伤害值。

enum Phase { WINDUP, BITE, CHEW, SPIT, RECOVER }

## 咀嚼循环计数：2→3 每轮 +1，达到 swallow_chew_cycles 后吐
var _phase: int = Phase.WINDUP
var _timer: float = 0.0
var _chew_count: int = 0
var _chew_toggle: int = 0
var _bit: bool = false          ## 吞入判定是否成功（整段状态的核心标志）
var _victim: Node2D = null
var _victim_hidden: bool = false


func enter() -> void:
	var enemy: Node2D = character
	_phase = Phase.WINDUP
	_bit = false
	_chew_count = 0
	_chew_toggle = 0
	_victim = null
	_victim_hidden = false

	# 停行走动画，避免 timer 回调覆盖丸呑み帧
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	_victim = enemy._player_ref
	# 面向玩家（俯视角可读性：先转向再张嘴）
	var d: Vector2 = _victim.global_position - enemy.global_position
	character.update_facing_from_direction(d)
	character.update_moving(false)
	character.velocity = Vector2.ZERO

	# 切换丸呑み动作表（若有），并显示准备帧（seq[0]）
	if enemy.swallow_texture != null:
		enemy.push_action_texture(enemy.swallow_texture, _seq_at(0))
	else:
		enemy.set_attack_char_index(_seq_at(0))

	# 起手音效
	enemy._play_sound(enemy.attack_sound, enemy.attack_sound_pitch)

	# 准备帧 → 短暂前摇（给玩家一个"要被吞了"的视觉预警）
	_timer = 0.18


func exit() -> void:
	var enemy: Node2D = character
	# 万一中途被打断（击退/死亡）仍隐藏着玩家 → 必须还原，否则玩家永久不可见
	if _victim_hidden:
		_restore_victim()
	if enemy.swallow_texture != null and enemy.has_action_texture():
		enemy.restore_walk_texture()
	if enemy.animation_timer:
		enemy.animation_timer.start()
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		# 本体死亡 → 吐回玩家（不能把玩家永久吞着）
		if _victim_hidden:
			_restore_victim()
			_victim = null
		return

	var enemy: Node2D = character

	match _phase:
		Phase.WINDUP:
			_timer -= delta
			if _timer <= 0.0:
				_enter_bite(enemy)

		Phase.BITE:
			## 吞入判定帧（原作 1）：只在此帧判定一次。
			_timer -= delta
			if _timer <= 0.0:
				_resolve_bite(enemy)

		Phase.CHEW:
			## 咀嚼循环：2 → 3 → 2 → 3 …… 每轮 swallow_chew_interval。
			_timer -= delta
			if _timer <= 0.0:
				_chew_count += 1
				if _chew_count >= maxi(1, enemy.swallow_chew_cycles):
					_enter_spit(enemy)
					return
				_chew_toggle = (_chew_toggle + 1) % 2
				_set_frame(2 if _chew_toggle == 0 else 3)
				_timer = maxf(0.05, enemy.swallow_chew_interval)

		Phase.SPIT:
			## 吐出帧（原作回到 1）：玩家重新出现并立即致死 → 切人。
			_timer -= delta
			if _timer <= 0.0:
				_do_spit(enemy)

		Phase.RECOVER:
			## 原作「过一会回到 0」：停顿后回 Chase。
			_timer -= delta
			if _timer <= 0.0:
				# 冷却从收尾起算，防止被同一玩家再次贴脸连吞
				enemy._swallow_cooldown_left = maxf(0.0, enemy.swallow_cooldown_seconds)
				transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_with_corner_assist()


# ═══════════════════════════════════════
# 内部 — 阶段推进
# ═══════════════════════════════════════

## 准备 → 吞入判定帧（原作 0 → 1）
func _enter_bite(enemy: Node2D) -> void:
	_phase = Phase.BITE
	_set_frame(1)
	# 判定帧本身也给一点停留时间，让"张嘴咬"这个动作看得见
	_timer = 0.12


## 解析吞入结果：距离 + 概率双判定。
func _resolve_bite(enemy: Node2D) -> void:
	var ok: bool = false
	if enemy.has_valid_player_target():
		var p: Node2D = enemy._player_ref
		var dist: float = p.global_position.distance_to(enemy.global_position)
		if dist <= maxf(1.0, enemy.swallow_trigger_range):
			ok = randf() < clampf(enemy.swallow_chance, 0.0, 1.0)
			if ok:
				_victim = p

	if not ok:
		# 扑空 → 直接进收尾（不惩罚性地连续尝试；冷却留给下一次贴近）
		bit_fail_recover(enemy)
		return

	_bit = true
	print("[敵人] 丸呑み！玩家被吞入（距离 %.0f，概率 %.2f）"
		% [_victim.global_position.distance_to(enemy.global_position), enemy.swallow_chance])
	_hide_victim()
	_phase = Phase.CHEW
	_chew_count = 0
	_chew_toggle = 0
	_set_frame(2)
	_timer = maxf(0.05, enemy.swallow_chew_interval)


func bit_fail_recover(enemy: Node2D) -> void:
	print("[敵人] 丸呑み判定失败（玩家脱出）")
	_enter_recover(enemy)


## 咀嚼结束 → 吐出帧
func _enter_spit(enemy: Node2D) -> void:
	_phase = Phase.SPIT
	_set_frame(1)
	_timer = 0.16


## 吐出：玩家重新出现 + 立即致死 + 切人（原作「显示角色并角色直接死亡切换到下一个角色」）。
func _do_spit(enemy: Node2D) -> void:
	if _victim == null or not is_instance_valid(_victim):
		_enter_recover(enemy)
		return

	_restore_victim()

	# 致死路径：原作明确「伤害是致死」。ガッツ 会拦住 HP≥2 的致命伤，
	# 所以不能发一个巨大伤害值了事 —— 直接走玩家的致死入口。
	if enemy.swallow_is_lethal:
		_apply_lethal(_victim)
	else:
		var dir: Vector2 = (_victim.global_position - enemy.global_position).normalized()
		if _victim.has_method("take_damage"):
			_victim.take_damage(float(_victim.get("max_hp")), 0.0, dir, false, 0.0, 0.0,
				enemy.next_attack_source_id(), enemy.attack_element, false)

	# 多段削り：武器弹药/耐久削减（原作「多段削りで武器も駄目に」）
	var att: float = float(enemy.swallow_weapon_attrition)
	if att > 0.0 and _victim.has_method("apply_weapon_attrition"):
		_victim.apply_weapon_attrition(att)

	print("[敵人] 丸呑み吐出 → 玩家致死并切换角色")
	_victim = null
	_enter_recover(enemy)


func _enter_recover(enemy: Node2D) -> void:
	_phase = Phase.RECOVER
	_set_frame(0)
	_timer = maxf(0.0, enemy.swallow_recover_seconds)


# ═══════════════════════════════════════
# 内部 — 玩家表现
# ═══════════════════════════════════════

## 把玩家「吞进肚子」：不可见 + 停碰撞（避免咀嚼期间被其他敌人继续打/被推走）。
func _hide_victim() -> void:
	if _victim == null or not is_instance_valid(_victim):
		return
	_victim_hidden = true
	# 联机（C3）：置 network_swallow_locked 锁——NetworkWorld 的 Host 模拟 /
	# Client 本地预测都据此冻结被吞玩家（否则会从 Hunterγ 肚子里走出去），
	# 并广播吞入表现让各 Client 隐藏对应玩家节点。
	if _victim.has_method("apply_network_swallow_state"):
		_victim.call("apply_network_swallow_state", true)
	_announce_swallow(true)
	_victim.visible = false
	if _victim.has_method("set_physics_process"):
		_victim.set_physics_process(false)
	if _victim.has_method("set_process"):
		_victim.set_process(false)
	# 关掉碰撞体，防止咀嚼期间被误判命中
	for c: Node in _victim.get_children():
		if c is CollisionShape2D or c is CollisionPolygon2D:
			(c as Node2D).set_deferred("disabled", true)


func _restore_victim() -> void:
	if _victim == null or not is_instance_valid(_victim):
		_victim_hidden = false
		return
	# 联机（C3）：解锁 + 广播吐出表现（幂等；见 _hide_victim 注释）。
	if _victim.has_method("apply_network_swallow_state"):
		_victim.call("apply_network_swallow_state", false)
	_announce_swallow(false)
	_victim.visible = true
	if _victim.has_method("set_physics_process"):
		_victim.set_physics_process(true)
	if _victim.has_method("set_process"):
		_victim.set_process(true)
	for c: Node in _victim.get_children():
		if c is CollisionShape2D or c is CollisionPolygon2D:
			(c as Node2D).set_deferred("disabled", false)
	_victim_hidden = false


## 联机（C3）：吞入/吐出表现广播。Host 闸在 NetworkWorld 侧；
## 单机（无 NetworkWorld 节点）no-op。
func _announce_swallow(active: bool) -> void:
	var tree := get_tree()
	if not tree:
		return
	var scene := tree.current_scene
	if not scene:
		return
	var world: Node = scene.find_child("NetworkWorld", true, false)
	if world and world.has_method("announce_enemy_swallow"):
		world.call("announce_enemy_swallow", character, _victim, active)


## 无视 ガッツ 的致死入口。优先用玩家自带的强制致死方法，
## 没有则退回「把 HP 打到 0 再触发 _die()」。
func _apply_lethal(victim: Node2D) -> void:
	if victim.get("_is_dying") == true:
		return
	if victim.has_method("force_lethal_death"):
		victim.force_lethal_death(int(character.get_instance_id()))
		return
	# 回退：直接归零 HP 并触发出血→_die 路径
	victim.set("current_hp", 0.0)
	var st: PlayerState = Players.get_state_for_entity(victim)
	if st:
		st.current_hp = 0.0
	if victim.has_method("_die"):
		victim._die()


# ═══════════════════════════════════════
# 内部 — 帧
# ═══════════════════════════════════════

func _seq_at(i: int) -> int:
	var seq: Array = character.swallow_char_sequence
	if seq.is_empty():
		return 0
	return int(seq[clampi(i, 0, seq.size() - 1)])


func _set_frame(seq_idx: int) -> void:
	character.set_attack_char_index(_seq_at(seq_idx))
