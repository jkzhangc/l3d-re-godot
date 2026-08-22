extends State
## 推击状态 — 近战推击（无伤害，纯击退）
##
## 推击动画：shove_char_sequence（统一帧时长 shove_frame_duration）
## 在 shove_hit_at_sequence_idx 处创建判定区域
## 动画结束后直接切回武器举起状态（无攻击后动画）
## 敌人被推中：闪白 2 帧（由 enemy._play_hit_feedback 处理）

var _wd: WeaponData = null
var _seq_idx: int = 0
var _timer: float = 0.0
var _hit_done: bool = false
var _hitbox: Area2D = null


func enter() -> void:
	_wd = _get_weapon()
	if not _wd:
		transition_requested.emit("Idle")
		return

	# 推击疲劳检查：冷却中则拒绝推击
	if not character.can_shove():
		var state_name: String = _wd.weapon_state_name
		if not state_name.is_empty():
			transition_requested.emit(state_name)
		else:
			transition_requested.emit("Idle")
		return

	_seq_idx = 0
	_timer = _wd.shove_frame_duration
	_hit_done = false
	_hitbox = null

	# 确保武器模式开启（上一个武器状态 exit 时可能关闭了）
	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true
	# 切换推击行走图
	character.enter_shove_mode()

	# 记录推击（疲劳计数）
	character.on_shove_performed()

	_set_shove_frame(0)


func exit() -> void:
	character.player_in_weapon_state = false
	_cleanup_hitbox()
	character.exit_shove_mode()
	# 恢复武器就绪外观
	if _wd:
		character.set_weapon_ready_frame()
	# 关闭武器模式（下一个状态 enter 会重新开启）
	character.exit_weapon_mode()
	# 标记跳过举起动画
	character.set_meta("weapon_skip_raise", true)


func process_update(delta: float) -> void:
	if not _wd:
		transition_requested.emit("Idle")
		return

	_timer -= delta
	if _timer <= 0.0:
		_seq_idx += 1
		var seq: Array[int] = _wd.get_shove_char_sequence()
		if _seq_idx >= seq.size():
			# 推击动画结束 → 直接切回武器举起状态（无攻击后动画）
			var state_name: String = _wd.weapon_state_name
			if not state_name.is_empty():
				transition_requested.emit(state_name)
			else:
				transition_requested.emit("Idle")
			return

		_timer = _wd.shove_frame_duration
		_set_shove_frame(_seq_idx)

		# 在命中索引发射判定区域
		if not _hit_done and _seq_idx == _wd.shove_hit_at_sequence_idx:
			_create_shove_hitbox()
			# 播放推击音效
			if _wd.shove_sound:
				_play_attack_sound(_wd.shove_sound)


func physics_update(delta: float) -> void:
	var move_dir: Vector2 = Input.get_vector("左", "右", "上", "下")
	character.velocity = move_dir * character.run_speed
	character.move_and_slide()
	# 推击中允许转向
	if move_dir != Vector2.ZERO:
		character.update_facing(move_dir)

	# 推击判定区域存在时检测命中（只检测一次）
	if _hitbox and not _hit_done:
		_check_shove_hits()


func _set_shove_frame(seq_idx: int) -> void:
	var char_idx: int = _wd.get_shove_char_sequence()[seq_idx]
	character.set_attack_char_index(char_idx)


func _create_shove_hitbox() -> void:
	_hitbox = Area2D.new()
	_hitbox.name = "ShoveHitbox"
	_hitbox.collision_layer = 0
	_hitbox.collision_mask = 24  ## 检测层 4（敌人物理体）+ 层 5（受击碰撞体）

	var shape: CollisionShape2D = CollisionShape2D.new()
	var rect: RectangleShape2D = RectangleShape2D.new()
	rect.size = _wd.shove_range_size
	shape.shape = rect
	shape.position = Vector2.ZERO
	_hitbox.add_child(shape)

	# 放置判定区域：角色位置 + 前方偏移
	var offset: Vector2 = character.get_facing_vector() * _wd.shove_range_forward_offset
	_hitbox.global_position = character.global_position + offset

	character.get_tree().current_scene.add_child(_hitbox)
	print("[推击] 判定区域已创建 | 偏移=%s | 大小=%s" % [offset, _wd.shove_range_size])


func _check_shove_hits() -> void:
	if not _hitbox:
		return

	var bodies: Array[Node2D] = _hitbox.get_overlapping_bodies()
	var areas: Array[Area2D] = _hitbox.get_overlapping_areas()

	var hit_any: bool = false
	var hit_ids: Array[int] = []

	for body: Node2D in bodies:
		if body == character:
			continue
		if _is_target_dead(body) or body.is_in_group("player"):
			continue
		if body.has_method("take_damage"):
			var bid: int = body.get_instance_id()
			if bid in hit_ids:
				continue
			hit_ids.append(bid)
			# 推击：0 伤害 + 击退（enemy.take_damage 内部触发白色闪帧）
			body.take_damage(0.0, _wd.shove_knockback_force, character.get_facing_vector(), false, _wd.shove_knockback_duration, 0.0)
			print("[推击] 击中 body: %s | 击退力度=%.0f | 击退时长=%.1fs" % [body.name, _wd.shove_knockback_force, _wd.shove_knockback_duration])
			hit_any = true

	for area: Area2D in areas:
		var parent: Node = area.get_parent()
		if parent == character or parent == _hitbox:
			continue
		if _is_target_dead(parent) or (parent and parent.is_in_group("player")):
			continue
		if parent and parent.has_method("take_damage"):
			var pid: int = parent.get_instance_id()
			if pid in hit_ids:
				continue
			hit_ids.append(pid)
			parent.take_damage(0.0, _wd.shove_knockback_force, character.get_facing_vector(), false, _wd.shove_knockback_duration, 0.0)
			print("[推击] 击中 area: %s | 击退力度=%.0f | 击退时长=%.1fs" % [parent.name, _wd.shove_knockback_force, _wd.shove_knockback_duration])
			hit_any = true

	if hit_any:
		_hit_done = true
		# 溅射击退：命中目标周围的敌人也受影响（仅一级，不连锁）
		_apply_splash_knockback(hit_ids)


func _is_target_dead(target: Node) -> bool:
	if target == null:
		return true
	return target.get("_is_dead") == true or target.get("_is_dying") == true


## 溅射击退：对被推中目标周围的敌人施加击退效果（仅一级，不连锁）
## @param hit_ids: 已直接命中的目标 instance_id 列表（跳过这些，避免重复）
func _apply_splash_knockback(hit_ids: Array[int]) -> void:
	if not _wd or _wd.shove_splash_radius <= 0.0:
		return

	# 溅射中心 = 角色前方（推击判定区域位置）
	var splash_center: Vector2 = character.global_position + character.get_facing_vector() * _wd.shove_range_forward_offset
	var splash_radius: float = _wd.shove_splash_radius

	var tree: SceneTree = character.get_tree()
	if not tree:
		return

	# 遍历场景中所有敌人
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var splash_count: int = 0

	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		if enemy == character:
			continue
		# 跳过已直接命中的目标
		if enemy.get_instance_id() in hit_ids:
			continue
		# 跳过已死亡的敌人
		if enemy.get("_is_dead") == true:
			continue

		# 检查是否在溅射范围内
		var dist: float = enemy.global_position.distance_to(splash_center)
		if dist > splash_radius:
			continue

		if not enemy.has_method("take_damage"):
			continue

		# 溅射击退方向和力度（从溅射中心向外推开）
		var splash_dir: Vector2 = (enemy.global_position - splash_center).normalized()
		if splash_dir == Vector2.ZERO:
			splash_dir = character.get_facing_vector()

		# 溅射击退力度衰减：边缘=50%，中心=100%
		var falloff: float = 1.0 - (dist / splash_radius) * 0.5
		var splash_force: float = _wd.shove_knockback_force * falloff

		enemy.take_damage(0.0, splash_force, splash_dir, false, _wd.shove_knockback_duration * falloff, 0.0)
		splash_count += 1
		print("[推击] 溅射命中: %s | 距离=%.0f | 力度=%.0f" % [enemy.name, dist, splash_force])

	if splash_count > 0:
		print("[推击] 溅射影响 %d 个敌人 | 半径=%.0f" % [splash_count, splash_radius])


func _cleanup_hitbox() -> void:
	if _hitbox:
		_hitbox.queue_free()
		_hitbox = null


func _play_attack_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return get_player_state().get_active_weapon()
