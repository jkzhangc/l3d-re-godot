extends State
## 小刀攻击状态 — 播放攻击动画并执行近战判定
##
## 攻击动画: melee_attack_char_sequence（或回退 attack_char_sequence）
## 在 melee_hit_at_sequence_idx 处创建判定区域
## 动画结束后切回 Knife（READY 阶段，跳过举起动画）

var _wd: WeaponData = null
var _seq_idx: int = 0
var _timer: float = 0.0
var _hit_done: bool = false
var _hitbox: Area2D = null
var _is_headshot: bool = false   ## 本次攻击是否暴击（对所有命中目标生效）
var _post_attack_active: bool = false  ## 是否正在播放攻击后动画
var _wait_frames: int = 0              ## 攻击完成后等待帧计数器（fire rate 控制）


func enter() -> void:
	_wd = _get_weapon()
	if not _wd:
		transition_requested.emit("Idle")
		return

	_seq_idx = 0
	_timer = _wd.get_melee_attack_frame_duration(_seq_idx)
	_hit_done = false
	_hitbox = null
	_post_attack_active = false
	_wait_frames = 0

	# 掷骰判定本次攻击是否暴击
	_is_headshot = _roll_critical()

	# 确保武器模式开启（上一个武器状态 exit 时可能关闭了）
	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true

	_set_attack_frame(_seq_idx)


func exit() -> void:
	character.player_in_weapon_state = false
	_cleanup_hitbox()
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

	# --- 等待帧阶段（攻击完成后的冷却） ---
	if _wait_frames > 0:
		_wait_frames -= 1
		if _wait_frames <= 0:
			if _try_continue_attack():
				return
			transition_requested.emit("Knife")
		return

	_timer -= delta
	if _timer <= 0.0:
		if _post_attack_active:
			# 攻击后动画帧切换
			_seq_idx += 1
			var post_seq: Array[int] = _wd.get_post_attack_char_sequence()
			if _seq_idx >= post_seq.size():
				_on_attack_complete()
				return
			_timer = _wd.get_post_attack_frame_duration(_seq_idx)
			_set_post_attack_frame(_seq_idx)
			return

		_seq_idx += 1
		if _seq_idx >= _wd.get_melee_attack_char_sequence().size():
			# 攻击动画结束 → 检查是否有攻击后动画
			var post_seq: Array[int] = _wd.get_post_attack_char_sequence()
			if post_seq.size() > 0:
				_post_attack_active = true
				_seq_idx = 0
				_timer = _wd.get_post_attack_frame_duration(0)
				_set_post_attack_frame(0)
				if _wd.post_attack_sound:
					_play_attack_sound(_wd.post_attack_sound)
			else:
				_on_attack_complete()
			return

		_timer = _wd.get_melee_attack_frame_duration(_seq_idx)
		_set_attack_frame(_seq_idx)

		# 在命中索引发射判定区域（特效/音效已移至 _create_melee_hitbox 内）
		if not _hit_done and _seq_idx == _wd.melee_hit_at_sequence_idx:
			_create_melee_hitbox()


func physics_update(delta: float) -> void:
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()

	# 近战判定区域存在时检测命中（只检测一次）
	if _hitbox and not _hit_done:
		_check_melee_hits()


func _set_attack_frame(seq_idx: int) -> void:
	var char_idx: int = _wd.get_melee_attack_char_sequence()[seq_idx]
	character.set_attack_char_index(char_idx)


func _set_post_attack_frame(seq_idx: int) -> void:
	var char_idx: int = _wd.get_post_attack_char_sequence()[seq_idx]
	character.set_attack_char_index(char_idx)


func _roll_critical() -> bool:
	## 掷骰判定是否暴击（爆头）
	if _wd.critical_rate <= 0.0:
		return false
	if _wd.critical_rate >= 100.0:
		return true
	return randf() * 100.0 < _wd.critical_rate


func _create_melee_hitbox() -> void:
	# 播放攻击特效和音效（本地预测：Client 和 Host 都播放）
	var effect_scene: PackedScene = _wd.get_attack_effect_anim(character.facing)
	if effect_scene:
		var follow: Node2D = character if _wd.attack_effect_follow else null
		VXAnimSprite.play_scene(effect_scene, character.global_position, character.get_tree().current_scene, 10.0, follow, _wd.attack_effect_offset_override)
	if _wd.attack_sound:
		_play_attack_sound(_wd.attack_sound)

	# 联机模式：Client 不本地创建判定区域，通过 RPC 让 Host 代为执行
	if Lobby.is_online() and not multiplayer.is_server():
		NetworkSyncManager.request_melee.rpc_id(1, _wd.item_id)
		_hit_done = true  # 标记完成，避免 physics_update 中重复触发
		return

	_hitbox = Area2D.new()
	_hitbox.name = "MeleeHitbox"
	_hitbox.collision_layer = 0   ## 不需要属于任何层
	_hitbox.collision_mask = 24   ## 检测层 4（敌人物理体）+ 层 5（受击碰撞体）

	var shape: CollisionShape2D = CollisionShape2D.new()
	var rect: RectangleShape2D = RectangleShape2D.new()
	rect.size = _wd.melee_range_size
	shape.shape = rect
	shape.position = Vector2.ZERO
	_hitbox.add_child(shape)

	# 放置判定区域：角色位置 + 前方偏移
	var offset: Vector2 = _get_melee_offset()
	_hitbox.global_position = character.global_position + offset

	character.get_tree().current_scene.add_child(_hitbox)
	print("[小刀] 近战判定区域已创建 | 偏移=%s | 大小=%s" % [offset, _wd.melee_range_size])

	# 联机模式：Host 广播攻击特效/音效给其他客户端
	if Lobby.is_online() and multiplayer.is_server():
		NetworkSyncManager.broadcast_attack_effects.rpc(multiplayer.get_unique_id(), _wd.item_id, character.global_position, character.facing)


func _get_melee_offset() -> Vector2:
	var fv: Vector2 = character.get_facing_vector()
	return fv * _wd.melee_range_forward_offset


func _check_melee_hits() -> void:
	if not _hitbox:
		return

	var bodies: Array[Node2D] = _hitbox.get_overlapping_bodies()
	var areas: Array[Area2D] = _hitbox.get_overlapping_areas()

	var damage: float = _wd.get_effective_damage()
	var hit_any: bool = false
	var hit_ids: Array[int] = []  ## 已命中目标 instance_id（防双次命中）

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
			body.take_damage(damage, 0.0, character.get_facing_vector(), _is_headshot, 0.0, _wd.hitstun_duration, 0, _wd.hit_effect_anim)
			if _wd.hit_effect_anim:
				var hf: Node2D = body if _wd.hit_effect_follow else null
				VXAnimSprite.play_scene(_wd.hit_effect_anim, body.global_position, character.get_tree().current_scene, 10.0, hf, _wd.hit_effect_offset_override)
			if _wd.hit_sound:
				_play_attack_sound(_wd.hit_sound)
			print("[小刀] 击中 body: %s | 伤害=%d | 爆头=%s" % [body.name, int(damage), str(_is_headshot)])
			hit_any = true
		else:
			print("[小刀] 击中 body: %s（无 take_damage 方法）" % body.name)

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
			parent.take_damage(damage, 0.0, character.get_facing_vector(), _is_headshot, 0.0, _wd.hitstun_duration, 0, _wd.hit_effect_anim)
			if _wd.hit_effect_anim:
				var hf2: Node2D = parent if _wd.hit_effect_follow else null
				VXAnimSprite.play_scene(_wd.hit_effect_anim, parent.global_position, character.get_tree().current_scene, 10.0, hf2, _wd.hit_effect_offset_override)
			if _wd.hit_sound:
				_play_attack_sound(_wd.hit_sound)
			print("[小刀] 击中 area: %s | 伤害=%d | 爆头=%s" % [parent.name, int(damage), str(_is_headshot)])
			hit_any = true

	# 只在真正命中时标记完成，避免物理服务器延迟导致空判
	if hit_any:
		_hit_done = true


func _is_target_dead(target: Node) -> bool:
	## 检查目标是否已死亡（敌人 _is_dead 或 玩家 _is_dying）
	if target == null:
		return true
	return target.get("_is_dead") == true or target.get("_is_dying") == true


func _cleanup_hitbox() -> void:
	if _hitbox:
		_hitbox.queue_free()
		_hitbox = null


func _on_attack_complete() -> void:
	## 攻击动画（含攻击后动画）全部播完。
	## 根据 fire_mode 和 post_press_wait_frames 决定等待/连发/切回就绪。
	if _wd.post_press_wait_frames > 0:
		_wait_frames = _wd.post_press_wait_frames
	elif _try_continue_attack():
		return
	else:
		transition_requested.emit("Knife")


func _try_continue_attack() -> bool:
	## HOLD 模式下按住确定键 → 重新开始一轮攻击。
	## 返回 true 表示已重新开始攻击。
	if _wd.fire_mode == WeaponData.FireMode.HOLD and Input.is_action_pressed("确定键"):
		# 重新开始攻击
		_seq_idx = 0
		_timer = _wd.get_melee_attack_frame_duration(_seq_idx)
		_hit_done = false
		_cleanup_hitbox()
		_post_attack_active = false
		# 重新掷骰暴击
		_is_headshot = _roll_critical()
		_set_attack_frame(_seq_idx)
		return true
	return false


func _play_attack_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return Global.get_active_weapon()
