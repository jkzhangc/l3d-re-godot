extends State
## 装填状态 — 处理普通装填和霰弹枪逐发装填
##
## NORMAL 模式：播放装填动画 → 装上弹药 → 等待帧 → 回到武器状态
## SHOTGUN 模式：循环播放单发装填动画（每发装一颗）→ 播放结束动画 → 等待帧 → 回到武器状态
##
## 动画帧序列和每帧时长在 WeaponData 中配置
## 等待帧时长 reload_wait_duration 两种模式共用

enum Phase { ANIM, END_ANIM, WAIT }

var _wd: WeaponData = null
var _phase: int = Phase.ANIM
var _seq_idx: int = 0
var _timer: float = 0.0
var _reload_done: bool = false   ## 弹药是否已装入（NORMAL 模式下动画结束后设为 true）
var _was_facing_locked: bool = false  ## 进入装填前朝向是否已锁定
var _shells_needed: int = 0     ## 霰弹枪需要装填的总发数
var _shells_loaded: int = 0     ## 霰弹枪已装填的发数（本地计数器，不依赖 RPC 返回值）


func enter() -> void:
	_wd = _get_weapon()
	if not _wd:
		transition_requested.emit("Idle")
		return

	# 近战武器不需要装填
	if not _wd.is_ranged or _wd.magazine_capacity <= 0:
		_return_to_weapon()
		return

	# 弹夹已满
	var current: int = Global.get_magazine_ammo(_wd.item_id)
	if current >= _wd.magazine_capacity:
		print("[装填] 弹夹已满 (%d/%d)" % [current, _wd.magazine_capacity])
		_return_to_weapon()
		return

	# 没有备用弹药
	var available: int = Global.count_ammo_item(_wd.ammo_item_id)
	if available <= 0:
		print("[装填] 没有可用弹药！(%s)" % _wd.ammo_item_id)
		_return_to_weapon()
		return

	# 进入装填
	character.enter_weapon_mode(_wd)
	character.player_in_weapon_state = true

	# 保存并锁定朝向
	_was_facing_locked = character.is_facing_locked()
	character.lock_facing()

	_phase = Phase.ANIM
	_seq_idx = 0
	_reload_done = false

	if _wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
		_start_shotgun_loop()
	else:
		_start_normal_anim()


func exit() -> void:
	character.player_in_weapon_state = false
	# 恢复装填前的朝向锁定状态
	if not _was_facing_locked:
		character.unlock_facing()
	if _wd:
		character.set_weapon_ready_frame()
	character.exit_weapon_mode()
	# 标记跳过举起动画
	character.set_meta("weapon_skip_raise", true)


func process_update(delta: float) -> void:
	if not _wd:
		transition_requested.emit("Idle")
		return

	match _phase:
		Phase.ANIM:
			_process_anim(delta)
		Phase.END_ANIM:
			_process_end_anim(delta)
		Phase.WAIT:
			_process_wait(delta)


func physics_update(_delta: float) -> void:
	# 装填期间允许移动（朝向锁定，仅位移）
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()


# ============================================================
# NORMAL 模式
# ============================================================

func _start_normal_anim() -> void:
	_seq_idx = 0
	var seq: Array[int] = _wd.get_reload_char_sequence()
	if seq.size() == 0:
		# 没有动画帧 → 直接装弹
		_do_reload()
		_enter_wait()
		return
	_timer = _wd.get_reload_frame_duration(0)
	_set_reload_frame(0)
	if _wd.reload_sound:
		_play_sound(_wd.reload_sound)


func _process_anim(delta: float) -> void:
	if _wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
		_process_shotgun_loop(delta)
		return

	# NORMAL 模式：逐帧播放
	_timer -= delta
	if _timer <= 0.0:
		_seq_idx += 1
		var seq: Array[int] = _wd.get_reload_char_sequence()
		if _seq_idx >= seq.size():
			# 动画结束 → 装弹
			if not _reload_done:
				_do_reload()
				_reload_done = true
			_enter_wait()
		else:
			_timer = _wd.get_reload_frame_duration(_seq_idx)
			_set_reload_frame(_seq_idx)


# ============================================================
# SHOTGUN 模式
# ============================================================

func _start_shotgun_loop() -> void:
	_seq_idx = 0
	# 预先计算需要装填的发数（避免循环中依赖异步 RPC 返回值导致死循环）
	var current: int = Global.get_magazine_ammo(_wd.item_id)
	var available: int = Global.count_ammo_item(_wd.ammo_item_id)
	_shells_needed = mini(_wd.magazine_capacity - current, available)
	_shells_loaded = 0
	print("[霰弹枪装填] 需要装 %d 发 (当前=%d/%d 备弹=%d)" % [_shells_needed, current, _wd.magazine_capacity, available])

	var seq: Array[int] = _wd.get_shotgun_loop_char_sequence()
	if seq.size() == 0 or _shells_needed <= 0:
		# 没有循环动画帧或无需装填 → 直接结束
		if _shells_needed > 0:
			_load_one_shell()
		_enter_shotgun_end()
		return
	_timer = _wd.get_shotgun_loop_frame_duration(0)
	_set_reload_frame(0)
	if _wd.shotgun_reload_loop_sound:
		_play_sound(_wd.shotgun_reload_loop_sound)


func _process_shotgun_loop(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_seq_idx += 1
		var seq: Array[int] = _wd.get_shotgun_loop_char_sequence()
		if _seq_idx >= seq.size():
			# 循环动画播放完一轮 → 装一发子弹
			_load_one_shell()
			# 用本地计数器判断是否继续（不依赖异步 RPC 返回的 Global 值）
			if _shells_loaded >= _shells_needed:
				_enter_shotgun_end()
				return
			# 继续循环
			_seq_idx = 0
			_timer = _wd.get_shotgun_loop_frame_duration(0)
			_set_reload_frame(0)
			if _wd.shotgun_reload_loop_sound:
				_play_sound(_wd.shotgun_reload_loop_sound)
		else:
			_timer = _wd.get_shotgun_loop_frame_duration(_seq_idx)
			_set_reload_frame(_seq_idx)


func _enter_shotgun_end() -> void:
	_phase = Phase.END_ANIM
	_seq_idx = 0
	var seq: Array[int] = _wd.get_shotgun_end_char_sequence()
	if seq.size() == 0:
		# 没有结束动画 → 直接等待
		_enter_wait()
		return
	_timer = _wd.get_shotgun_end_frame_duration(0)
	_set_reload_frame(0)
	if _wd.shotgun_reload_end_sound:
		_play_sound(_wd.shotgun_reload_end_sound)


func _process_end_anim(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_seq_idx += 1
		var seq: Array[int] = _wd.get_shotgun_end_char_sequence()
		if _seq_idx >= seq.size():
			_enter_wait()
		else:
			_timer = _wd.get_shotgun_end_frame_duration(_seq_idx)
			_set_reload_frame(_seq_idx)


# ============================================================
# 等待帧（共用）
# ============================================================

func _enter_wait() -> void:
	_phase = Phase.WAIT
	_timer = _wd.reload_wait_duration


func _process_wait(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_return_to_weapon()


# ============================================================
# 弹药操作
# ============================================================

## NORMAL 模式：一次性装入所有可用的弹药
func _do_reload() -> void:
	# 联机模式：Client 发 RPC + 本地乐观扣除备弹（Host 只确认弹夹数）
	if Lobby.is_online() and not multiplayer.is_server():
		var reserve: int = Global.count_ammo_item(_wd.ammo_item_id)
		var cur: int = Global.get_magazine_ammo(_wd.item_id)
		var need: int = _wd.magazine_capacity - cur
		var local_load: int = mini(need, reserve)
		if local_load > 0:
			Global.consume_ammo_item(_wd.ammo_item_id, local_load)
			# 先更新本地弹夹显示，Host 回包会再次校正为权威值。
			Global.set_magazine_ammo(_wd.item_id, cur + local_load)
		NetworkSyncManager.request_reload.rpc_id(1, _wd.item_id, -1, reserve)
		return

	var current: int = Global.get_magazine_ammo(_wd.item_id)
	var capacity: int = _wd.magazine_capacity
	var need: int = capacity - current
	var available: int = Global.count_ammo_item(_wd.ammo_item_id)
	var to_load: int = mini(need, available)
	var consumed: int = Global.consume_ammo_item(_wd.ammo_item_id, to_load)

	if consumed > 0:
		Global.set_magazine_ammo(_wd.item_id, current + consumed)
		print("[装填] 完成: %d → %d / %d (背包剩余: %d)" % [
			current,
			Global.get_magazine_ammo(_wd.item_id),
			capacity,
			Global.count_ammo_item(_wd.ammo_item_id)
		])


## SHOTGUN 模式：装入一发子弹
func _load_one_shell() -> void:
	# 联机模式：Client 只发 RPC + 本地计数，不直接操作 Global（避免与 RPC 返回值冲突）
	if Lobby.is_online() and not multiplayer.is_server():
		_shells_loaded += 1
		var reserve: int = Global.count_ammo_item(_wd.ammo_item_id)
		# 本地乐观扣除 1 发备弹
		if reserve > 0:
			Global.consume_ammo_item(_wd.ammo_item_id, 1)
			# 本地预测一发装填；Host 回包负责最终校正。
			Global.set_magazine_ammo(_wd.item_id, Global.get_magazine_ammo(_wd.item_id) + 1)
		NetworkSyncManager.request_reload.rpc_id(1, _wd.item_id, 1, reserve)
		return

	var current: int = Global.get_magazine_ammo(_wd.item_id)
	if current >= _wd.magazine_capacity:
		return

	var available: int = Global.count_ammo_item(_wd.ammo_item_id)
	if available <= 0:
		return

	var consumed: int = Global.consume_ammo_item(_wd.ammo_item_id, 1)
	if consumed > 0:
		_shells_loaded += 1
		Global.set_magazine_ammo(_wd.item_id, current + 1)
		print("[霰弹枪装填] +1 → %d / %d (背包剩余: %d)" % [
			Global.get_magazine_ammo(_wd.item_id),
			_wd.magazine_capacity,
			Global.count_ammo_item(_wd.ammo_item_id)
		])


# ============================================================
# 工具方法
# ============================================================

func _set_reload_frame(seq_idx: int) -> void:
	var char_idx: int
	match _phase:
		Phase.ANIM:
			if _wd.reload_mode == WeaponData.ReloadMode.SHOTGUN:
				char_idx = _wd.get_shotgun_loop_char_sequence()[seq_idx]
			else:
				char_idx = _wd.get_reload_char_sequence()[seq_idx]
		Phase.END_ANIM:
			char_idx = _wd.get_shotgun_end_char_sequence()[seq_idx]
		_:
			return
	character.set_attack_char_index(char_idx)


func _return_to_weapon() -> void:
	if _wd and not _wd.weapon_state_name.is_empty():
		transition_requested.emit(_wd.weapon_state_name)
	else:
		transition_requested.emit("Idle")


func _play_sound(stream: AudioStream) -> void:
	Global.play_sfx_managed(stream, character.get_tree().current_scene)


func _get_weapon() -> WeaponData:
	return Global.get_active_weapon()
