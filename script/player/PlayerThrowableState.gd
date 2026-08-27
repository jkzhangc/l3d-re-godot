extends State
## 投掷状态分为举起、瞄准、投掷；终点和伤害参数在 Host 侧重新验证，不能信任客户端。
## 投掷物状态 — 举起投掷物 → 瞄准（显示路径+终点）→ 投掷
##
## 「投掷物键」(5) 进入；再次按 5 或按主/副武器键放下。
## 按住「确定键」瞄准，松开投掷；按住时按「取消键」取消瞄准。
## 「投掷加格键」(A) / 「投掷减格键」(S) 调终点格数（0 ~ throw_range_max）。
## 举起时朝向跟随移动；按住「确定键」瞄准时朝向锁定，可移动。

const TILE_SIZE: int = 32
const DEFAULT_RANGE: int = 3

const AIM_INDICATOR_SCRIPT := preload("res://script/throw_aim_indicator.gd")

enum Phase { RAISE, READY, AIM }

var _phase: int = Phase.RAISE
var _td: ThrowableData = null
var _range: int = DEFAULT_RANGE
var _aim_indicator: Node2D = null


func enter() -> void:
	_td = get_player_state().throwable
	if not _td:
		transition_requested.emit("Idle")
		return
	character.player_in_weapon_state = true
	_phase = Phase.RAISE
	_range = DEFAULT_RANGE
	# 配置了举起行走图 → 切投掷物行走图；否则不显示持物外观
	if _td.held_walk_texture:
		character.enter_throwable_mode(_td)
	character.velocity = Vector2.ZERO
	character.update_appearance(false, false)


func exit() -> void:
	character.player_in_weapon_state = false
	character.unlock_facing()
	character.exit_throwable_mode()
	_remove_aim_indicator()


func process_update(_delta: float) -> void:
	match _phase:
		Phase.RAISE:
			_phase = Phase.READY
		Phase.READY:
			_process_ready()
		Phase.AIM:
			_process_aim()


func _process_ready() -> void:
	# 再次按投掷物键 → 放下
	if Input.is_action_just_pressed("投掷物键"):
		transition_requested.emit("Idle")
		return
	# 主/副武器键 → 切武器放下
	if Input.is_action_just_pressed("主武器键") or Input.is_action_just_pressed("副武器键"):
		transition_requested.emit("Idle")
		return
	var move_dir: Vector2 = Input.get_vector("左", "右", "上", "下")
	if move_dir != Vector2.ZERO:
		character.update_facing(move_dir)
	character.update_appearance(move_dir != Vector2.ZERO, false)
	# 确定键 → 锁定朝向并进入瞄准
	if Input.is_action_just_pressed("确定键"):
		character.lock_facing()
		_phase = Phase.AIM
		_create_aim_indicator()


func _process_aim() -> void:
	# 按住攻击键时按取消键 → 取消瞄准（解锁朝向）
	if Input.is_action_just_pressed("取消键"):
		character.unlock_facing()
		_phase = Phase.READY
		_remove_aim_indicator()
		return
	# 调终点格数
	if Input.is_action_just_pressed("投掷加格键"):
		_range = mini(_range + 1, _td.throw_range_max)
	if Input.is_action_just_pressed("投掷减格键"):
		_range = maxi(_range - 1, 0)
	# 松开攻击键 → 投掷
	if Input.is_action_just_released("确定键"):
		_throw()
		return
	var move_dir: Vector2 = Input.get_vector("左", "右", "上", "下")
	character.update_appearance(move_dir != Vector2.ZERO, false)
	if _aim_indicator:
		_aim_indicator.direction = character.get_facing_vector()
		_aim_indicator.range_tiles = _range


func physics_update(_delta: float) -> void:
	character.velocity = Input.get_vector("左", "右", "上", "下") * character.run_speed
	character.move_and_slide()


func _throw() -> void:
	var dir: Vector2 = character.get_facing_vector()
	var start: Vector2 = character.global_position
	var end: Vector2 = start + dir * (_range * TILE_SIZE)
	ThrowableProjectile.spawn(_td, start, end, character)
	get_player_state().throwable = null
	_remove_aim_indicator()
	transition_requested.emit("Idle")


func _create_aim_indicator() -> void:
	if _aim_indicator:
		return
	_aim_indicator = Node2D.new()
	_aim_indicator.name = "ThrowAimIndicator"
	_aim_indicator.z_index = 5
	_aim_indicator.set_script(AIM_INDICATOR_SCRIPT)
	character.add_child(_aim_indicator)
	_aim_indicator.direction = character.get_facing_vector()
	_aim_indicator.range_tiles = _range


func _remove_aim_indicator() -> void:
	if _aim_indicator and is_instance_valid(_aim_indicator):
		_aim_indicator.queue_free()
	_aim_indicator = null
