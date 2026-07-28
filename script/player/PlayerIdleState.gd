extends State
## 站立状态 — 玩家不移动时


func enter() -> void:
	character.velocity = Vector2.ZERO
	character.update_appearance(false, false)


func process_update(_delta: float) -> void:
	# 切换武器
	if Input.is_action_just_pressed("主武器键"):
		_try_switch_weapon("primary")
		return
	if Input.is_action_just_pressed("副武器键"):
		_try_switch_weapon("secondary")
		return

	# 使用消耗品
	if Input.is_action_just_pressed("治疗品键"):
		Global.use_healing_item()
		return
	if Input.is_action_just_pressed("辅助品键"):
		Global.use_support_item()
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
	var wd: WeaponData = Global.get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		transition_requested.emit(wd.weapon_state_name)


func _try_switch_weapon(slot: String) -> void:
	if Global.switch_to_slot(slot):
		# 切换成功，无其他操作（下次举起武器会用新武器）
		pass


func physics_update(delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_and_slide()
