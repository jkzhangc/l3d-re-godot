extends State
## 行走状态 — 按住行走键移动


func enter() -> void:
	character.update_appearance(true, true)


func process_update(_delta: float) -> void:
	# 切换武器
	if character._player_input.is_action_just_pressed("主武器键"):
		_try_switch_weapon("primary")
		return
	if character._player_input.is_action_just_pressed("副武器键"):
		_try_switch_weapon("secondary")
		return

	# 使用消耗品
	if character._player_input.is_action_just_pressed("治疗品键"):
		Global.use_healing_item()
		return
	if character._player_input.is_action_just_pressed("辅助品键"):
		Global.use_support_item()
		return

	if character._player_input.is_action_just_pressed("举起放下武器键"):
		_try_weapon_state()
		return

	var move_dir: Vector2 = character._player_input.get_move_vector()
	if move_dir == Vector2.ZERO:
		transition_requested.emit("Idle")
		return

	if not character._player_input.is_action_pressed("行走键"):
		transition_requested.emit("Run")
		return

	character.update_facing(move_dir)


func _try_weapon_state() -> void:
	var wd: WeaponData = Global.get_active_weapon()
	if wd and not wd.weapon_state_name.is_empty():
		transition_requested.emit(wd.weapon_state_name)


func _try_switch_weapon(slot: String) -> void:
	if Global.switch_to_slot(slot):
		pass


func physics_update(delta: float) -> void:
	character.velocity = character._player_input.get_move_vector() * character.walk_speed
	character.move_and_slide()
