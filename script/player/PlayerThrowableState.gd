extends State

## ── 架构定位 ──
## 系统：玩家状态机 ｜ 层：玩法（State）
## 联机：终点与伤害由 Host 复核
## 职责：投掷状态机（举起→瞄准→投掷）。
## 依赖：ThrowableData、ThrowableProjectile、PlayerState

## 投掷状态分为举起、瞄准、投掷；终点和伤害参数在 Host 侧重新验证，不能信任客户端。
## 投掷物状态 — 举起投掷物 → 瞄准（显示路径+终点）→ 投掷
##
## 「投掷物键」(5) 进入；再次按 5 或按主/副武器键放下。
## 2026-09-14 改版：按 5 进入后**轨迹线常显**、朝向跟随移动不锁定（自由瞄准）；
##   快速按一下「确定键」= 即刻扔出（按下进固定瞄准、松开即掷，手感为按 Z 扔）。
## 固定朝向 = 旧逻辑原样保留：按住「确定键」锁定朝向瞄准，松开投掷；
##   按住时按「取消键」取消瞄准解锁朝向。
## 「投掷加格键」(A) / 「投掷减格键」(S) 调终点格数（0 ~ throw_range_max），
##   轨迹常显后 READY / AIM 两阶段都可调。

const TILE_SIZE: int = 32
const DEFAULT_RANGE: int = 3

const AIM_INDICATOR_SCRIPT := preload("res://script/throw_aim_indicator.gd")

enum Phase { RAISE, READY, AIM }

var _phase: int = Phase.RAISE
var _td: ThrowableData = null
var _range: int = DEFAULT_RANGE
var _aim_indicator: Node2D = null
## ★放下 / 投掷后要回到的状态名（`""` → Idle）；由 Player 层在发起切换前交给本状态。
## 举着枪按 5 掏手雷 → 结束时回到举枪，而不是被丢回空手（见 `Player._return_pose_state`）。
var _return_state: String = ""

## ── 按住 Z 的"持续瞄准"参数（2026-10-03 用户需求改版）──
## 「轻按 Z 直接扔」与「A/S 调距离」保持原样；**只改按住 Z 之后**的行为：
##   ① 角色原地不动 ② 方向键选投掷方向（角色转身）
##   ③ **重复按同一个方向键**把落点推远一格（换方向保留距离）
##   ④ 「按住」比轻按更久时，距离自动压回**最低**，从最近处开始往外扫
const AIM_HOLD_RESET_SEC := 0.20   ## 超过这个时长才认定为"按住"（轻按=快速扔，不重置距离）
var _aim_hold_time: float = 0.0    ## AIM 已持续时长
var _aim_range_reset: bool = false ## 本轮瞄准是否已把距离压回最低
var _last_aim_dir: Vector2 = Vector2.ZERO  ## 上一次按下的方向键（判定"重复按同一个方向"）


func enter() -> void:
	_td = get_player_state().throwable
	if not _td:
		transition_requested.emit("Idle")
		return
	## 取用即清空（避免陈旧值）。
	_return_state = character.take_return_pose_state()
	character.player_in_weapon_state = true
	_phase = Phase.RAISE
	_range = DEFAULT_RANGE
	# 配置了举起行走图 → 切投掷物行走图；否则不显示持物外观
	if _td.held_walk_texture:
		character.enter_throwable_mode(_td)
	character.velocity = Vector2.ZERO
	character.update_appearance(false, false)
	# 2026-09-14：轨迹线常显——举起即显示，朝向不锁定（自由瞄准）
	_create_aim_indicator()


func exit() -> void:
	character.player_in_weapon_state = false
	character.unlock_facing()
	character.exit_throwable_mode()
	_remove_aim_indicator()


func process_update(delta: float) -> void:
	match _phase:
		Phase.RAISE:
			_phase = Phase.READY
		Phase.READY:
			_process_ready()
		Phase.AIM:
			## ★AIM 需要 delta 了（2026-10-03）：用"按住时长"区分**轻按 Z** 与**按住 Z**。
			_process_aim(delta)


func _process_ready() -> void:
	# 再次按投掷物键 → 放下（回到进入前的姿态：举枪 / 空手）
	if Global.item_key_just_pressed("投掷物键"):
		_finish()
		return
	# 主/副武器键 → 切武器放下
	if Global.item_key_just_pressed("主武器键") or Global.item_key_just_pressed("副武器键"):
		transition_requested.emit("Idle")
		return
	var move_dir: Vector2 = Global.move_input()
	if move_dir != Vector2.ZERO:
		character.update_facing(move_dir)
	character.update_appearance(move_dir != Vector2.ZERO, false)
	# 调终点格数（READY 阶段轨迹已常显，A/S 直接可调）
	if Input.is_action_just_pressed("投掷加格键"):
		_range = mini(_range + 1, _td.throw_range_max)
	if Input.is_action_just_pressed("投掷减格键"):
		_range = maxi(_range - 1, _td.throw_range_min)
	# 确定键按下 → 进入瞄准（旧逻辑保留）；**轻按**立刻松开就是"随手扔出去"的手感，
	# **按住**则走 `_process_aim` 的持续瞄准（原地不动 + 方向键选向/调距）。
	if Input.is_action_just_pressed("确定键"):
		## ★不再 `lock_facing()`（2026-10-03 用户需求改版）：按住 Z 期间要用**方向键改投掷方向**，
		## 而朝向一旦锁定，`update_facing()` 会直接 early-return → 方向键失效。
		## 这里反而要清掉可能残留的锁（玩家先前用取消键锁过朝向时）。
		character.unlock_facing()
		_aim_hold_time = 0.0
		_aim_range_reset = false
		_last_aim_dir = Vector2.ZERO
		_phase = Phase.AIM
		return
	# 轨迹线常显（2026-09-14）：READY 阶段朝向不锁定，指示器随朝向逐帧刷新
	if _aim_indicator:
		_aim_indicator.direction = character.get_facing_vector()
		_aim_indicator.range_tiles = _range


func _process_aim(delta: float) -> void:
	# 取消键 → 退出瞄准回到 READY（不投掷）
	if Input.is_action_just_pressed("取消键"):
		_aim_hold_time = 0.0
		_aim_range_reset = false
		_phase = Phase.READY
		_remove_aim_indicator()
		return

	## ★「按住」比轻按更久 → 把落点距离压回**最低**，于是「按住 Z + 连按方向键」
	##   是从最**近**处开始往外扫的（2026-10-03 用户需求）。
	##   **轻按 Z**（点一下立刻松手）不重置 —— 那是"随手扔出去"，
	##   应沿用 A/S 预先调好的距离（用户要求「按 Z 扔的操作不变」）。
	_aim_hold_time += delta
	if not _aim_range_reset and _aim_hold_time >= AIM_HOLD_RESET_SEC:
		_range = _td.throw_range_min
		_aim_range_reset = true

	## ★方向键 = 选投掷方向（角色跟着**转身**，扔出去的方向就是角色面向）；
	##   **重复按同一个方向** = 落点再推远一格。换方向**保留**当前距离（用户拍板），
	##   所以只有"同方向重复按"才递增。
	var dir_in: Vector2 = Global.move_input()
	if dir_in != Vector2.ZERO:
		character.update_facing(dir_in)
	var pressed_dir: Vector2 = _pressed_direction()
	if pressed_dir != Vector2.ZERO:
		if pressed_dir == _last_aim_dir:
			_range = mini(_range + 1, _td.throw_range_max)
		_last_aim_dir = pressed_dir
	character.update_appearance(dir_in != Vector2.ZERO, false)

	# A/S 调距离（保持原样；下限用数据里的最低距离，允许作者设 0 = 扔脚下）
	if Input.is_action_just_pressed("投掷加格键"):
		_range = mini(_range + 1, _td.throw_range_max)
	if Input.is_action_just_pressed("投掷减格键"):
		_range = maxi(_range - 1, _td.throw_range_min)

	# 松开 Z → 投掷
	if Input.is_action_just_released("确定键"):
		_throw()
		return

	if _aim_indicator:
		_aim_indicator.direction = character.get_facing_vector()
		_aim_indicator.range_tiles = _range


## 本帧刚**按下**的方向键（4 向）。用于「重复按同一个方向 → 落点推远一格」。
## 用 `just_pressed` 而非持续按住：这样"按住不放"只算一次，必须**松手再按**才继续推远。
func _pressed_direction() -> Vector2:
	var d := Vector2.ZERO
	if Input.is_action_just_pressed("右"):
		d.x += 1.0
	elif Input.is_action_just_pressed("左"):
		d.x -= 1.0
	elif Input.is_action_just_pressed("下"):
		d.y += 1.0
	elif Input.is_action_just_pressed("上"):
		d.y -= 1.0
	return d


func physics_update(_delta: float) -> void:
	## ★按住 Z 的持续瞄准期间**原地不动**（2026-10-03 用户需求）：
	##   否则方向键既改朝向又当移动键，落点会跟着人跑、很难瞄。
	##   注意只在 AIM 阶段定住 —— READY 阶段（掏出来还没按 Z）照常走位，
	##   不然"掏出手雷就没法跑"（用户明确要保留走位自由度）。
	if _phase == Phase.AIM:
		character.velocity = Vector2.ZERO
		character.move_with_corner_assist()
		return
	character.velocity = Global.move_input() * character.run_speed
	character.move_with_corner_assist()


func _throw() -> void:
	var dir: Vector2 = character.get_facing_vector()
	var start: Vector2 = character.global_position
	var end: Vector2 = start + dir * (_range * TILE_SIZE)
	ThrowableProjectile.spawn(_td, start, end, character)
	# 叠数投掷物（炸药）：扔一次减一个，归零才清槽；普通投掷物直接清槽
	get_player_state().consume_throwable()
	_remove_aim_indicator()
	## 投掷完成 → 回到进入前的姿态（举枪 / 空手）。
	_finish()


## 放下 / 投掷后的唯一出口：回到"进入前的姿态"。
func _finish() -> void:
	if not _return_state.is_empty():
		transition_requested.emit(_return_state)
		return
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
