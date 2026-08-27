extends State
## 单机由本状态读取本地输入；联机 Host 不走这里读取键盘，而由 NetworkWorld 注入已验证输入。
## 站立状态 — 玩家不移动时


func enter() -> void:
	character.velocity = Vector2.ZERO
	character.update_appearance(false, false)


func process_update(_delta: float) -> void:
	# 直接举起武器
	if Input.is_action_just_pressed("主武器键"):
		_try_raise_weapon("primary")
		return
	if Input.is_action_just_pressed("副武器键"):
		_try_raise_weapon("secondary")
		return

	# 使用消耗品
	if Input.is_action_just_pressed("治疗品键"):
		character.use_healing_item()
		return
	if Input.is_action_just_pressed("辅助品键"):
		character.use_support_item()
		return

	# 投掷物
	if Input.is_action_just_pressed("投掷物键"):
		_try_throwable()
		return

	if Input.is_action_just_pressed("举起放下武器键"):
		_try_weapon_state()
		return

	var move_dir: Vector2 = Input.get_vector("左", "右", "上", "下")
	if move_dir == Vector2.ZERO:
		return

	if Input.is_action_pressed("行走键"):
		transition_requested.emit("Walk")
	else:
		transition_requested.emit("Run")


func _try_weapon_state() -> void:
	var wd: WeaponData = get_player_state().get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		transition_requested.emit(wd.weapon_state_name)


func _try_raise_weapon(slot: String) -> void:
	var wd: WeaponData = get_player_state().get_equipped_weapon(slot)
	if not wd or wd.weapon_state_name.is_empty():
		return
	get_player_state().active_weapon_slot = slot
	transition_requested.emit(wd.weapon_state_name)


func _try_throwable() -> void:
	if get_player_state().throwable:
		transition_requested.emit("Throwable")


func physics_update(delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_and_slide()
