extends Node
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

@export var horde_total_min: int = 10         ## 尸潮最少总数
@export var horde_total_max: int = 30         ## 尸潮最多总数
@export var horde_batch_size: int = 4         ## 每批数量
@export var horde_batch_interval: float = 3.0 ## 批次基础间隔（秒）
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
var _horde_total: int = 0
var _horde_spawned: int = 0
var _horde_remaining: int = 0
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
	if _horde_total == 0:
		return 0.0
	return float(_horde_spawned) / float(_horde_total)


# ═══════════════════════════════════════
# 内部 — 散兵生成
# ═══════════════════════════════════════
func _update_scatter(delta: float, intensity: float, alive_count: int) -> void:
	if alive_count >= max_active_common:
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

	count = mini(count, max_active_common - alive_count)
	if count <= 0:
		return

	print("[SpawnManager] scatter spawn: %d enemies" % count)
	_director.spawn_horde(count, _find_decor())


func _reset_scatter_timer() -> void:
	_scatter_interval = randf_range(scatter_interval_min, scatter_interval_max)
	_scatter_timer = _scatter_interval


# ═══════════════════════════════════════
# 内部 — 尸潮生成
# ═══════════════════════════════════════
func _start_horde() -> void:
	_horde_active = true
	_horde_total = randi_range(horde_total_min, horde_total_max)
	_horde_spawned = 0
	_horde_remaining = _horde_total
	_horde_batch_timer = 0.0  # 第一批立即生成
	print("[SpawnManager] HORDE START: total=%d" % _horde_total)


func _update_horde(delta: float, alive_count: int) -> void:
	if not _horde_active:
		return

	_horde_batch_timer -= delta
	if _horde_batch_timer > 0.0:
		return

	# 检查是否已完成或超出上限
	if _horde_remaining <= 0:
		print("[SpawnManager] horde complete: %d/%d spawned" % [_horde_spawned, _horde_total])
		_horde_active = false
		return

	if alive_count >= max_active_common:
		_horde_batch_timer = 1.0
		return

	# 当前批次数量
	var batch: int = mini(horde_batch_size, _horde_remaining)
	batch = mini(batch, max_active_common - alive_count)

	print("[SpawnManager] horde batch: %d enemies (remaining=%d)" % [batch, _horde_remaining])
	var spawned: int = _director.spawn_horde(batch, _find_decor())
	_horde_spawned += spawned
	_horde_remaining -= spawned

	# 下一批间隔
	_horde_batch_timer = randf_range(2.0, 5.0)


# ═══════════════════════════════════════
# 内部 — 查找 DecorLayer
# ═══════════════════════════════════════
func _find_decor() -> Node:
	if _director and _director.has_method("_find_decor_layer"):
		return _director._find_decor_layer()
	return null
