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

	_seq_idx = 0
	_timer = _wd.shove_frame_duration
	_hit_done = false
	_hitbox = null

	# 确保武器模式开启（上一个武器状态 exit 时可能关闭了）
	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true
	# 切换推击行走图
	character.enter_shove_mode()

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
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()

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
		if _is_target_dead(body):
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
		if _is_target_dead(parent):
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


func _is_target_dead(target: Node) -> bool:
	if target == null:
		return true
	return target.get("_is_dead") == true or target.get("_is_dying") == true


func _cleanup_hitbox() -> void:
	if _hitbox:
		_hitbox.queue_free()
		_hitbox = null


func _play_attack_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return Global.get_active_weapon()
