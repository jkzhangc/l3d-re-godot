extends State
## 手枪攻击状态 — 播放攻击动画并发射子弹
##
## 攻击动画: attack_char_sequence（默认 [3,4,3,2]）
## 在 fire_at_sequence_idx 处发射子弹
## 动画结束后切回 Pistol（READY 阶段，跳过举起动画）

var _wd: WeaponData = null
var _seq_idx: int = 0
var _timer: float = 0.0
var _fired: bool = false
var _post_attack_active: bool = false  ## 是否正在播放攻击后动画
var _wait_frames: int = 0              ## 攻击完成后等待帧计数器（fire rate 控制）


func enter() -> void:
	_wd = _get_weapon()
	if not _wd:
		transition_requested.emit("Idle")
		return

	# 远程武器：弹夹为空则播放空弹音效，不进入攻击动画
	if _wd.is_ranged and _wd.magazine_capacity > 0:
		var current: int = Global.get_magazine_ammo(_wd.item_id)
		if current <= 0:
			print("[手枪] 弹夹为空！咔嚓——")
			if _wd.empty_fire_sound:
				_play_attack_sound(_wd.empty_fire_sound)
			transition_requested.emit("Pistol")
			return

	_seq_idx = 0
	_timer = _wd.get_attack_frame_duration(_seq_idx)
	_fired = false
	_post_attack_active = false
	_wait_frames = 0

	# 确保武器模式开启（上一个武器状态 exit 时可能关闭了）
	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true

	# 设置攻击动画第一帧
	_set_attack_frame(_seq_idx)

func exit() -> void:
	character.player_in_weapon_state = false
	# 恢复武器就绪外观（char_idx_2）
	if _wd:
		character.set_weapon_ready_frame()
	# 关闭武器模式（下一个状态 enter 会重新开启）
	character.exit_weapon_mode()
	# 标记跳过举起动画，下次进入 Pistol 时直接 READY
	character.set_meta("weapon_skip_raise", true)


func process_update(delta: float) -> void:
	if not _wd:
		transition_requested.emit("Idle")
		return

	# --- 等待帧阶段（攻击完成后的 fire rate 冷却） ---
	if _wait_frames > 0:
		_wait_frames -= 1
		if _wait_frames <= 0:
			if _try_continue_attack():
				return
			transition_requested.emit("Pistol")
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
		if _seq_idx >= _wd.attack_char_sequence.size():
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

		_timer = _wd.get_attack_frame_duration(_seq_idx)
		_set_attack_frame(_seq_idx)

		# 发射时机检查
		if not _fired and _seq_idx == _wd.fire_at_sequence_idx:
			_fire_bullet()
			_fired = true


func physics_update(delta: float) -> void:
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()


func _set_attack_frame(seq_idx: int) -> void:
	var char_idx: int = _wd.attack_char_sequence[seq_idx]
	character.set_attack_char_index(char_idx)


func _set_post_attack_frame(seq_idx: int) -> void:
	var char_idx: int = _wd.get_post_attack_char_sequence()[seq_idx]
	character.set_attack_char_index(char_idx)


func _fire_bullet() -> void:
	# 播放攻击特效和音效（本地预测：Client 和 Host 都播放）
	var effect_scene: PackedScene = _wd.get_attack_effect_anim(character.facing)
	if effect_scene:
		var follow: Node2D = character if _wd.attack_effect_follow else null
		VXAnimSprite.play_scene(effect_scene, character.global_position, character.get_tree().current_scene, 10.0, follow, _wd.attack_effect_offset_override)
	if _wd.attack_sound:
		_play_attack_sound(_wd.attack_sound)

	# 联机模式：Client 不本地生成子弹，通过 RPC 让 Host 代为执行
	if Lobby.is_online() and not multiplayer.is_server():
		NetworkSyncManager.request_attack.rpc_id(1, multiplayer.get_unique_id())
		return

	# 消耗弹药
	var current: int = Global.get_magazine_ammo(_wd.item_id)
	if current <= 0:
		print("[手枪] 弹夹为空！咔嚓——")
		return

	Global.set_magazine_ammo(_wd.item_id, current - 1)
	var bullet_count: int = _wd.bullet_list.size()
	print("[手枪] 发射！弹夹剩余: %d / %d | 子弹数: %d" % [current - 1, _wd.magazine_capacity, bullet_count])

	# 加载子弹场景（只加载一次）
	var bullet_scene: PackedScene = load("res://object/bullet.tscn") as PackedScene
	if not bullet_scene:
		print("[手枪] 错误：无法加载子弹场景")
		return

	var base_dir: Vector2 = character.get_facing_vector()
	var base_pos: Vector2 = character.global_position

	# 遍历 bullet_list，每颗子弹独立配置
	for bd: BulletData in _wd.bullet_list:
		var bullet: Node2D = bullet_scene.instantiate()

		# 方向：BulletData 控制角度/方向覆盖
		var dir_vec: Vector2 = bd.get_fire_direction(base_dir)
		var damage: float = bd.get_effective_damage(_wd.attack_power)

		if bullet.has_method("setup"):
			bullet.setup({
				"direction": dir_vec,
				"speed": bd.speed,
				"max_range": bd.max_range,
				"damage": damage,
				"destroy_on_hit": bd.destroy_on_hit,
				"penetration": bd.penetration,
				"critical_rate": _wd.critical_rate,
				"hit_effect_anim": _wd.hit_effect_anim,
				"hit_effect_follow": _wd.hit_effect_follow,
				"hit_effect_offset_override": _wd.hit_effect_offset_override,
				"hit_sound": _wd.hit_sound,
				"texture": bd.bullet_texture,
				"anim_frames": bd.bullet_anim_frames,
				"frame_duration": bd.bullet_frame_duration,
				"collision_size": bd.collision_size,
				"collision_offset": bd.collision_offset,
				"knockback_force": bd.knockback_force if bd.knockback_enabled else 0.0,
				"knockback_stun": bd.knockback_stun_duration if bd.knockback_enabled else 0.0,
					"hitstun_duration": bd.hitstun_duration if bd.hitstun_duration > 0.0 else _wd.hitstun_duration,
				"shooter": character,
			})

		# 子弹初始位置 = 角色位置 + 前方偏移 + 方向额外偏移
		var extra: Vector2 = bd.get_extra_offset(character.facing)
		bullet.position = base_pos + dir_vec * bd.spawn_offset + extra

		# 添加到场景树
		character.get_tree().current_scene.add_child(bullet)

	# 播放开枪音效（只播一次，不是每颗子弹都播）
	# 播放开枪特效
	# 枪声惊动范围内敌人（仅 Host 执行）
	if _wd.gunshot_range > 0.0:
		_alert_nearby_enemies()


func _on_attack_complete() -> void:
	## 攻击动画（含攻击后动画）全部播完。
	## 根据 fire_mode 和 post_press_wait_frames 决定等待/连发/切回就绪。
	if _wd.post_press_wait_frames > 0:
		_wait_frames = _wd.post_press_wait_frames
	elif _try_continue_attack():
		return
	else:
		transition_requested.emit("Pistol")


func _try_continue_attack() -> bool:
	## HOLD 模式下按住确定键 → 重新开始一轮攻击。
	## 返回 true 表示已重新开始攻击。
	if _wd.fire_mode == WeaponData.FireMode.HOLD and Input.is_action_pressed("确定键"):
		# HOLD 模式下检查弹药（空弹则终止连发）
		if _wd.is_ranged and _wd.magazine_capacity > 0:
			if Global.get_magazine_ammo(_wd.item_id) <= 0:
				if _wd.empty_fire_sound:
					_play_attack_sound(_wd.empty_fire_sound)
				return false
		# 重新开始攻击
		_seq_idx = 0
		_timer = _wd.get_attack_frame_duration(_seq_idx)
		_fired = false
		_post_attack_active = false
		_set_attack_frame(_seq_idx)
		return true
	return false


func _play_attack_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return Global.get_active_weapon()


## 通知枪声范围内的敌人（仅影响 Idle 状态的敌人）
func _alert_nearby_enemies() -> void:
	var tree := character.get_tree()
	if not tree:
		return
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var shoot_pos: Vector2 = character.global_position
	var rng: float = _wd.gunshot_range
	var count: int = 0
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		if enemy.global_position.distance_to(shoot_pos) > rng:
			continue
		if enemy.has_method("alert_by_gunshot"):
			enemy.alert_by_gunshot(character)
			count += 1
	if count > 0:
		print("[枪声] 惊动 %d 个敌人（范围 %.0fpx）" % [count, rng])
