class_name EnemyRocketState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：仅 Host 执行；开火瞬间经 NetworkWorld 广播镜像火箭（Client 只做视觉与音效）
## 职责：ネメシス 火箭筒攻击：触发带举起 → 举着继续靠近 → 进开火带开火 →
##       倒放举起动作放下武器 → 回追击。
## 依赖：State、enemy 实体（rocket_* 参数）、object/enemy_rocket.tscn
##
## 【动作参数口径】与普攻的 `attack_char_sequence` / `attack_frame_durations` 完全一致：
##   · `rocket_raise_char_sequence` = 角色格序列（每格 = 行走图里的一个角色格，0~7）
##   · `rocket_raise_frame_durations` = 与序列同下标的每格时长（秒，缺项用 rocket_frame_seconds）
##   开火同理（`rocket_fire_char_sequence` / `rocket_fire_frame_durations`），
##   并用 `rocket_fire_at_sequence_idx` 指定「播到第几格时发射」。
## 【放下 = 倒放举起】用户口径与玩家武器一致：不单独做放下动画，把举起序列反向播一遍。
## 【距离】触发带（trigger_*）决定什么时候掏筒；开火带（fire_*）决定什么时候打。

enum Phase { RAISE, APPROACH, FIRE, LOWER }

## 序列被清空时的兜底（正常请在 tres 里配）：4 = 扛筒格，5 = 端平格。
const FALLBACK_RAISE: Array[int] = [4]
const FALLBACK_FIRE: Array[int] = [5]
const ROCKET_SCENE := preload("res://object/enemy_rocket.tscn")

var _phase: int = Phase.RAISE
var _idx: int = 0
var _timer: float = 0.0
var _fired: bool = false


func enter() -> void:
	var enemy: Node2D = character
	_phase = Phase.RAISE
	_idx = 0
	_timer = 0.0
	_fired = false

	# 停掉行走动画 timer，防止回调覆盖动作帧（与 Attack/Pounce/Tongue 同约定）
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	# 断线/切图时目标可能已失效
	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	var dir: Vector2 = enemy._player_ref.global_position - enemy.global_position
	if dir.length_squared() > 1.0:
		character.update_facing_from_direction(dir)
	character.update_moving(false)
	character.velocity = Vector2.ZERO

	## 举枪音：默认与玩家火箭筒一致（カチャ.ogg），tres 可覆盖
	if enemy.rocket_raise_sound:
		enemy._play_sound(enemy.rocket_raise_sound, 1.0)
	_draw(enemy, _raise_seq(enemy), 0)
	_timer = _dur(enemy, _raise_dur(enemy), 0)


func exit() -> void:
	var enemy: Node2D = character
	if enemy.animation_timer:
		enemy.animation_timer.start()
	character.velocity = Vector2.ZERO
	## 没 push 过动作表，直接按行走表站立帧重画即可（_anim_step 停在 0 = 迈步姿势，
	## 所以先归 1，与 restore_walk_texture 的口径一致）
	enemy._anim_step = 1
	enemy._refresh_sprite()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character

	match _phase:
		Phase.RAISE:
			_timer -= delta
			if _timer > 0.0:
				return
			var raise: Array = _raise_seq(enemy)
			_idx += 1
			if _idx >= raise.size():
				## 举好了 → 停在最后一格，进入「举着靠近」
				_phase = Phase.APPROACH
				_idx = raise.size() - 1
				return
			_draw(enemy, raise, _idx)
			_timer = _dur(enemy, _raise_dur(enemy), _idx)

		Phase.APPROACH:
			if not enemy.has_valid_player_target():
				_enter_lower(enemy)
				return
			var d: float = enemy._player_ref.global_position.distance_to(enemy.global_position)
			## 进到开火带上限就开火；比下限还近（贴脸）同样开火 —— 否则举着筒永远不打。
			if d <= maxf(1.0, enemy.rocket_fire_max_dist):
				_phase = Phase.FIRE
				_idx = 0
				_draw(enemy, _fire_seq(enemy), 0)
				_timer = _dur(enemy, _fire_dur(enemy), 0)
				_try_fire(enemy)

		Phase.FIRE:
			_timer -= delta
			if _timer > 0.0:
				return
			var fire: Array = _fire_seq(enemy)
			_idx += 1
			if _idx >= fire.size():
				_enter_lower(enemy)
				return
			_draw(enemy, fire, _idx)
			_timer = _dur(enemy, _fire_dur(enemy), _idx)
			_try_fire(enemy)

		Phase.LOWER:
			_timer -= delta
			if _timer > 0.0:
				return
			_idx -= 1
			if _idx < 0:
				## 放下完毕 → 冷却从此刻起算，回追击
				enemy._rocket_cooldown_left = maxf(0.05, enemy.rocket_cooldown_seconds)
				transition_requested.emit("Chase")
				return
			_draw(enemy, _raise_seq(enemy), _idx)
			_timer = _dur(enemy, _raise_dur(enemy), _idx)


func physics_update(_delta: float) -> void:
	var enemy: Node2D = character
	if _phase != Phase.APPROACH:
		character.velocity = Vector2.ZERO
		character.move_with_corner_assist()
		return
	if not enemy.has_valid_player_target():
		character.velocity = Vector2.ZERO
		return
	var to_player: Vector2 = enemy._player_ref.global_position - enemy.global_position
	if to_player.length_squared() <= 1.0:
		character.velocity = Vector2.ZERO
		return
	var move_dir: Vector2 = to_player.normalized()
	character.update_facing_from_direction(move_dir)
	character.velocity = move_dir * enemy.move_speed * maxf(0.1, enemy.rocket_approach_speed_mult)
	character.move_with_corner_assist()
	## 朝向一变 update_facing_from_direction 会按行走表重画 → 把「举着火箭筒」那格盖回来
	_draw(enemy, _raise_seq(enemy), _idx)


func _enter_lower(enemy: Node2D) -> void:
	_phase = Phase.LOWER
	_idx = _raise_seq(enemy).size() - 1
	_timer = _dur(enemy, _raise_dur(enemy), maxi(_idx, 0))
	if enemy.rocket_lower_sound:
		enemy._play_sound(enemy.rocket_lower_sound, 1.0)
	_draw(enemy, _raise_seq(enemy), maxi(_idx, 0))


## 到达开火格就发射一次（多格动作里只发一发）。
func _try_fire(enemy: Node2D) -> void:
	if _fired:
		return
	var size: int = maxi(_fire_seq(enemy).size(), 1)
	var at: int = clampi(enemy.rocket_fire_at_sequence_idx, 0, size - 1)
	if _idx < at:
		return
	_fired = true
	_fire_rocket(enemy)


func _fire_rocket(enemy: Node2D) -> void:
	if enemy.rocket_fire_sound:
		enemy._play_sound(enemy.rocket_fire_sound, 1.0)

	## 发射方向取「开火瞬间的玩家位置」——举起期间玩家可以走位
	var dir: Vector2 = enemy.get_facing_vector()
	if enemy.has_valid_player_target():
		var to_p: Vector2 = enemy._player_ref.global_position - enemy.global_position
		if to_p.length_squared() > 1.0:
			dir = to_p.normalized()

	var proj: Node2D = ROCKET_SCENE.instantiate()
	## 出口 = 身前 24px；落进墙里就退回本体原点（同吐酸的嵌墙脱困）
	var spawn_pos: Vector2 = enemy.global_position + dir * 24.0
	var space: PhysicsDirectSpaceState2D = enemy.get_world_2d().direct_space_state
	var point_q := PhysicsPointQueryParameters2D.new()
	point_q.position = spawn_pos
	point_q.collision_mask = 1 | 32
	if not space.intersect_point(point_q).is_empty():
		spawn_pos = enemy.global_position
	proj.global_position = spawn_pos
	proj.set("direction", dir)
	proj.set("speed", enemy.rocket_speed)
	proj.set("damage", enemy.get_rocket_damage())
	proj.set("explosion_radius", enemy.rocket_explosion_radius)
	proj.set("visual_scale", enemy.rocket_visual_scale)
	proj.set("max_range", enemy.rocket_max_range)
	proj.set("explosion_effect", enemy.rocket_explosion_effect)
	proj.set("explode_sound", enemy.rocket_explode_sound)
	proj.set("source_id", enemy.next_attack_source_id())
	var parent: Node = enemy.get_tree().current_scene
	if parent == null:
		parent = enemy.get_parent()
	parent.add_child(proj)
	_announce_network_rocket(enemy, spawn_pos, dir)


## Host：开火事件广播（entity_id + 出口 + 方向）。速度/半径/特效由 Client 从本地
## enemy 节点字段解析（apply_to_enemy 注入保证有值），资源不经网络传输。
func _announce_network_rocket(enemy: Node2D, spawn_pos: Vector2, dir: Vector2) -> void:
	var tree := enemy.get_tree()
	if tree == null or tree.current_scene == null:
		return
	var world: Node = tree.current_scene.find_child("NetworkWorld", true, false)
	if world != null and world.has_method("announce_enemy_rocket"):
		world.call("announce_enemy_rocket", enemy, spawn_pos, dir)


# ── 序列读取 ──

func _raise_seq(enemy: Node2D) -> Array:
	var f: Array = enemy.rocket_raise_char_sequence
	return f if not f.is_empty() else FALLBACK_RAISE


func _fire_seq(enemy: Node2D) -> Array:
	var f: Array = enemy.rocket_fire_char_sequence
	return f if not f.is_empty() else FALLBACK_FIRE


func _raise_dur(enemy: Node2D) -> Array:
	return enemy.rocket_raise_frame_durations


func _fire_dur(enemy: Node2D) -> Array:
	return enemy.rocket_fire_frame_durations


## 第 i 格的显示时长：durations 有就用它，缺项回退 rocket_frame_seconds。
func _dur(enemy: Node2D, durations: Array, i: int) -> float:
	if i >= 0 and i < durations.size():
		return maxf(0.02, float(durations[i]))
	return maxf(0.02, float(enemy.rocket_frame_seconds))


## 画序列里第 i 格（角色格号 → 站立帧）。
func _draw(enemy: Node2D, seq: Array, i: int) -> void:
	if seq.is_empty():
		return
	var cell: int = int(seq[clampi(i, 0, seq.size() - 1)])
	enemy.set_attack_char_index(cell)
