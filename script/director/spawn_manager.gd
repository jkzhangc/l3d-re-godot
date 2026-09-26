extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host
## 职责：敌人投放调度：build 阶段定时撒散兵，peak 阶段分批出尸潮，受阶段与存活上限约束。
## 依赖：Director.spawn_ahead_batch（前方屏外定点刷怪）、PacingController 信号

## 管理普通/特殊敌人的生成冷却与数量限制；正式执行仍由 Director/Host 调用。
## 敌人生成调度器 — 管理自动生成散兵 + 尸潮分批
##
## 由 pacing_controller 的 phase_changed 信号驱动，
## 在 Build-up 阶段定时生成散兵，Peak 阶段分批生成尸潮
## 所有参数 Inspector 可调

# ═══════════════════════════════════════
# 参数（Inspector 可调）
# ═══════════════════════════════════════
@export var scatter_min: int = 1              ## 散兵最少数量
@export var scatter_max: int = 3              ## 散兵最多数量
@export var scatter_interval_min: float = 15.0  ## 散兵生成间隔最短（秒）
@export var scatter_interval_max: float = 30.0  ## 散兵生成间隔最长（秒）

## ★2026-09-26 语义变更：尸潮从「一次性总额度」改为「持续窗口内维持的同时存活数」。
## 旧语义下额度刷完即 _horde_active=false，而 peak 阶段本管理器只跑尸潮、**不跑散兵**
## → 峰值剩余时间完全零刷怪（用户实测：尸潮只出几只 → 空场 → 杀完即结束）。
@export var horde_total_min: int = 10         ## 尸潮期间**同时维持**的存活数下限（地图原有覆盖值继续生效）
@export var horde_total_max: int = 30         ## 尸潮期间同时维持的存活数上限
@export var horde_batch_size: int = 8         ## 每次补充的上限：缺多少补多少，不会一次刷满
@export var horde_batch_interval: float = 5.0 ## 补充批次的基础间隔（秒）
@export var horde_duration_min: float = 25.0  ## 尸潮持续时长下限（秒）—— 结束条件从"额度刷完"改为"窗口走完"
@export var horde_duration_max: float = 40.0  ## 尸潮持续时长上限（秒）；会被 peak_timeout 截断
@export var max_active_common: int = 15       ## 同时最多普通感染者

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var enabled: bool = true
var current_phase: StringName = &"cooldown"

# 散兵计时
var _scatter_timer: float = 0.0
var _scatter_interval: float = 0.0

# 尸潮状态
var _horde_active: bool = false
var _horde_target_alive: int = 0      ## 本波要维持的同时存活数（已按真人数放大）
var _horde_spawned: int = 0           ## 本波累计生成数（诊断 / 日志）
var _horde_duration: float = 0.0      ## 本波持续时长（已按 peak_timeout 截断）
var _horde_time_left: float = 0.0     ## 剩余时长 —— 归零即本波结束
var _horde_batch_timer: float = 0.0

# 外部引用（由 director 注入）
var _director: Node = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════
func setup(director_node: Node) -> void:
	_director = director_node


# ═══════════════════════════════════════
# 每帧由 director 调用
# ═══════════════════════════════════════
func update(delta: float, intensity: float, alive_count: int) -> void:
	if not enabled or not _director:
		return

	match current_phase:
		&"build":
			_update_scatter(delta, intensity, alive_count)
		&"peak":
			_update_horde(delta, alive_count)
		&"cooldown":
			pass  # 不主动生成


# ═══════════════════════════════════════
# 节奏阶段切换回调
# ═══════════════════════════════════════
func on_phase_changed(phase: StringName) -> void:
	current_phase = phase
	print("[SpawnManager] phase → %s" % phase)

	match phase:
		&"build":
			_horde_active = false
			_reset_scatter_timer()
			_scatter_timer = 0.0  # 第一次立即刷，不等待
		&"peak":
			_start_horde()
		&"cooldown":
			_horde_active = false


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════
func is_horde_active() -> bool:
	return _horde_active


func get_horde_progress() -> float:
	## 尸潮改为持续窗口后，进度 = 已走过的窗口时间比例（0 → 1）。
	if _horde_duration <= 0.0:
		return 0.0
	return clampf(1.0 - _horde_time_left / _horde_duration, 0.0, 1.0)


# ═══════════════════════════════════════
# 内部 — 散兵生成
# ═══════════════════════════════════════
func _update_scatter(delta: float, intensity: float, alive_count: int) -> void:
	## 存活上限按真人数**温和**放大（见 Players.scaled_active_cap 的成本说明）。
	var active_cap: int = Players.scaled_active_cap(max_active_common)
	if alive_count >= active_cap:
		return

	_scatter_timer -= delta
	if _scatter_timer > 0.0:
		return

	_reset_scatter_timer()

	# 数量由紧张度决定
	var count: int
	if intensity < 0.2:
		count = scatter_min
	elif intensity < 0.4:
		count = randi_range(scatter_min, scatter_min + 1)
	else:
		count = randi_range(scatter_min, scatter_max)

	count = Players.scale_spawn_count(count)
	count = mini(count, active_cap - alive_count)
	if count <= 0:
		return

	print("[SpawnManager] scatter spawn: %d enemies（倍率 %.1f× / %d 人）" % [
		count, Players.spawn_scale(), Players.spawn_player_count()])
	# 位置改由 Director.spawn_ahead_batch（前方扇区 + 屏幕外 + 前方带数量闸门）决定，
	# 不再走"作者点缺失时全图随机撒点"的旧回退。
	_director.spawn_ahead_batch(count)


func _reset_scatter_timer() -> void:
	_scatter_interval = randf_range(scatter_interval_min, scatter_interval_max)
	_scatter_timer = _scatter_interval


# ═══════════════════════════════════════
# 内部 — 尸潮生成
# ═══════════════════════════════════════
func _start_horde() -> void:
	_horde_active = true
	## ★2026-09-26 大改（用户实测"尸潮只刷几只、然后前面再也不刷、杀完就结束"）：
	## 旧实现把 horde_total 当**一次性总额度**：刷满就 _horde_active = false；
	## 而 peak 阶段 SpawnManager **只跑尸潮、不跑散兵**（见 update 的 match）→
	## 额度用尽后整个峰值窗口零刷怪。再叠加「场上清空 → peak 提前结束」，
	## 观感就是"几只 → 空场 → 杀完即结束"。
	## 现在：horde_total 变成**尸潮期间要维持的同时存活数**，缺多少补多少
	##（被击杀、被"离得太远回收"都会腾出名额 → 前面立刻补），结束由 horde_duration 决定。
	_horde_target_alive = Players.scale_spawn_count(randi_range(horde_total_min, horde_total_max))
	_horde_duration = randf_range(minf(horde_duration_min, horde_duration_max),
		maxf(horde_duration_min, horde_duration_max))
	## 尸潮窗口不能超过峰值阶段本身：否则 peak 先超时结束（BGM/狂暴先收），尸潮还在补怪。
	var pc: Node = _director.get_node_or_null("PacingController") if _director != null else null
	if pc != null:
		_horde_duration = minf(_horde_duration, float(pc.get("peak_timeout")))
	_horde_time_left = _horde_duration
	_horde_spawned = 0
	_horde_batch_timer = 0.0  # 第一批立即生成
	print("[SpawnManager] HORDE START: 维持 %d 只 / 持续 %.0fs" % [_horde_target_alive, _horde_duration])


func _update_horde(delta: float, alive_count: int) -> void:
	if not _horde_active:
		return

	_horde_time_left -= delta
	if _horde_time_left <= 0.0:
		print("[SpawnManager] horde window over: %.0fs 内共生成 %d 只" % [_horde_duration, _horde_spawned])
		_horde_active = false
		return

	## 目标存活数：按真人数放大过，但不越过作者设的同屏硬上限。
	var active_cap: int = Players.scaled_active_cap(max_active_common)
	var target_alive: int = mini(_horde_target_alive, active_cap)

	## 只在**低于目标**时补充（达标就待命，不空刷）。计时器只减不重置，
	## 因此一有敌人被击杀或被"离得太远回收"，下一批会立刻补上来（用户要的"前面立马补几个"）。
	if alive_count >= target_alive:
		_horde_batch_timer = maxf(_horde_batch_timer - delta, 0.0)
		return

	_horde_batch_timer -= delta
	if _horde_batch_timer > 0.0:
		return

	## 每批数量：基准按真人数放大 → 再受「离目标差多少」与「同屏上限余量」双重约束。
	var batch: int = mini(Players.scale_spawn_count(horde_batch_size), target_alive - alive_count)
	batch = mini(batch, active_cap - alive_count)
	if batch <= 0:
		return

	print("[SpawnManager] horde batch: %d 只（场上 %d / 目标 %d，剩 %.0fs）" % [
		batch, alive_count, target_alive, _horde_time_left])
	var spawned: int = _director.spawn_ahead_batch(batch).size()
	_horde_spawned += spawned

	## 下一批间隔（基准 horde_batch_interval，允许 ±40% 抖动避免机械感）
	_horde_batch_timer = randf_range(maxf(horde_batch_interval * 0.6, 0.5), horde_batch_interval)


# ═══════════════════════════════════════
# 内部 — 查找 DecorLayer
# ═══════════════════════════════════════
func _find_decor() -> Node:
	if _director and _director.has_method("_find_decor_layer"):
		return _director._find_decor_layer()
	return null
