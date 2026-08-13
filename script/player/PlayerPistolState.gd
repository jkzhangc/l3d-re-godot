extends State
## 手枪举起状态 — 主武器举起
##
## 举起动画：正向播放 weapon_raise_char_sequence
## 放下动画：反向播放 weapon_raise_char_sequence
## 举起后可移动，按「确定键」→ 攻击，按「装填键」→ 装弹

enum Phase { RAISE, READY, LOWER }

var _phase: int = Phase.RAISE
var _seq_idx: int = 0        ## 当前在 raise_char_sequence 中的索引
var _timer: float = 0.0
var _wd: WeaponData = null


func enter() -> void:
	_wd = _get_weapon()
	if not _wd:
		transition_requested.emit("Idle")
		return

	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true

	if character.has_meta("weapon_skip_raise") and character.get_meta("weapon_skip_raise"):
		character.remove_meta("weapon_skip_raise")
		_phase = Phase.READY
		character.set_weapon_ready_frame()
		character.update_appearance(false, false)
	else:
		_phase = Phase.RAISE
		_seq_idx = 0
		_timer = _wd.get_raise_frame_duration(0)
		character.set_weapon_frame(0)
		character.velocity = Vector2.ZERO
		if _wd.raise_sound:
			_play_sound(_wd.raise_sound)


func exit() -> void:
	character.player_in_weapon_state = false
	character.exit_weapon_mode()


func process_update(delta: float) -> void:
	match _phase:
		Phase.RAISE:
			_timer -= delta
			if _timer <= 0.0:
				_seq_idx += 1
				var seq: Array[int] = _wd.get_raise_char_sequence()
				if _seq_idx >= seq.size():
					# 举起完成 → 就绪
					_phase = Phase.READY
					character.update_appearance(false, false)
				else:
					_timer = _wd.get_raise_frame_duration(_seq_idx)
					character.set_weapon_frame(_seq_idx)

		Phase.READY:
			# --- 固定朝向输入处理 ---
			if Global.facing_lock_mode == 0:
				# 切换式：按取消键切换朝向锁定
				if Input.is_action_just_pressed("取消键"):
					character.toggle_facing_lock()
			else:
				# 按住式：按住取消键锁定朝向，松开解锁
				if Input.is_action_pressed("取消键"):
					if not character.is_facing_locked():
						character.lock_facing()
				elif character.is_facing_locked():
					character.unlock_facing()

			var move_dir: Vector2 = Input.get_vector("左", "右", "上", "下")
			character.update_appearance(move_dir != Vector2.ZERO, false)
			if move_dir != Vector2.ZERO:
				character.update_facing(move_dir)

			# 主武器键：同槽位→放下；不同槽位→切换并举起
			if Input.is_action_just_pressed("主武器键"):
				if Global.active_weapon_slot == "primary":
					_begin_lower()
				else:
					_try_raise_weapon("primary")
				return

			# 副武器键：同槽位→放下；不同槽位→切换并举起
			if Input.is_action_just_pressed("副武器键"):
				if Global.active_weapon_slot == "secondary":
					_begin_lower()
				else:
					_try_raise_weapon("secondary")
				return

			# 使用消耗品
			if Input.is_action_just_pressed("治疗品键"):
				Global.use_healing_item()
				return
			if Input.is_action_just_pressed("辅助品键"):
				Global.use_support_item()
				return

			if Input.is_action_just_pressed("举起放下武器键"):
				_begin_lower()

			if Input.is_action_just_pressed("推击键"):
				transition_requested.emit("Shove")

			if Input.is_action_just_pressed("确定键"):
				# 在拾取物范围内时不攻击，让拾取物处理按住替换
				if not character._near_pickup:
					transition_requested.emit("PistolAttack")

			if Input.is_action_just_pressed("装填键"):
				transition_requested.emit("Reload")

		Phase.LOWER:
			_timer -= delta
			if _timer <= 0.0:
				_seq_idx -= 1
				if _seq_idx < 0:
					# 放下完成 → 退出
					transition_requested.emit("Idle")
				else:
					_timer = _wd.get_raise_frame_duration(_seq_idx)
					character.set_weapon_frame(_seq_idx)


func physics_update(delta: float) -> void:
	if _phase == Phase.READY:
		character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	else:
		character.velocity = Vector2.ZERO
	character.move_and_slide()


func _begin_lower() -> void:
	## 开始放下动画：从序列倒数第二帧开始（最后一帧 = 就绪帧已在显示）
	# 放下武器时取消固定朝向
	character.unlock_facing()
	var seq: Array[int] = _wd.get_raise_char_sequence()
	_seq_idx = seq.size() - 2
	_phase = Phase.LOWER
	if _seq_idx >= 0:
		_timer = _wd.get_raise_frame_duration(_seq_idx)
		character.set_weapon_frame(_seq_idx)
	else:
		# 序列只有1帧 → 直接退出
		transition_requested.emit("Idle")
		return
	if _wd.lower_sound:
		_play_sound(_wd.lower_sound)


func _play_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return Global.get_active_weapon()


func _try_raise_weapon(slot: String) -> void:
	var wd: WeaponData = Global.get_equipped_weapon(slot)
	if not wd or wd.weapon_state_name.is_empty():
		return
	Global.active_weapon_slot = slot
	transition_requested.emit(wd.weapon_state_name)
