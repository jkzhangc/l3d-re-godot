extends State
## 跑步状态 — 默认移动方式


func enter() -> void:
	character.update_appearance(true, false)


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
		transition_requested.emit("Idle")
		return

	if Input.is_action_pressed("行走键"):
		transition_requested.emit("Walk")
		return

	character.update_facing(move_dir)


func _try_weapon_state() -> void:
	var wd: WeaponData = Global.get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		transition_requested.emit(wd.weapon_state_name)


func _try_switch_weapon(slot: String) -> void:
	Global.switch_to_slot(slot)


func physics_update(delta: float) -> void:
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()
