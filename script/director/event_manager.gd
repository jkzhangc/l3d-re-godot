extends Node
## 事件编排器 — 根据紧张度和节奏触发自然事件 + 管理剧本事件
##
## Phase 2: 自然尸潮触发（紧张度持续高位 → 强制 Peak）
## Phase 3: 剧本事件（Crescendo 防守、Finale、Alarm、Boss、Horde）

# ═══════════════════════════════════════
# 参数 — 自然尸潮
# ═══════════════════════════════════════
const HORDE_INTENSITY_THRESHOLD: float = 0.65   ## 触发尸潮的紧张度阈值
const HORDE_SUSTAIN_TIME: float = 8.0           ## 紧张度持续高于阈值多久后触发（秒）
const HORDE_COOLDOWN: float = 60.0              ## 两次尸潮之间最小间隔（秒）
const PEAK_HORDE_COOLDOWN: float = 30.0         ## Peak 阶段内再次触发尸潮的冷却

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal scripted_event_started(event_name: String)
signal scripted_event_completed(event_name: String)
signal scripted_event_progress(ratio: float)  ## 事件进度 0.0~1.0（用于 UI）

# ═══════════════════════════════════════
# 运行时 — 自然事件
# ═══════════════════════════════════════
var enabled: bool = true
var _above_threshold_time: float = 0.0
var _last_horde_time_msec: int = -999999
var _last_peak_horde_time_msec: int = -999999

# ═══════════════════════════════════════
# 运行时 — 剧本事件
# ═══════════════════════════════════════
var _scripted_event_active: bool = false
var _event_config: Dictionary = {}
var _event_timer: float = 0.0
var _event_spawn_timer: float = 0.0
var _event_total_spawned: int = 0

# 外部引用
var _director: Node = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════
func setup(director_node: Node) -> void:
	_director = director_node


# ═══════════════════════════════════════
# 每帧由 director 调用
# ═══════════════════════════════════════
func update(delta: float, intensity: float, phase: StringName, alive_enemy_count: int) -> void:
	if not enabled or not _director:
		return

	# ── 剧本事件模式：接管一切 ──
	if _scripted_event_active:
		_update_scripted_event(delta, alive_enemy_count)
		return

	# ── 自然尸潮：紧张度持续高位 → 触发 Peak ──
	if intensity >= HORDE_INTENSITY_THRESHOLD:
		_above_threshold_time += delta
		if _above_threshold_time >= HORDE_SUSTAIN_TIME:
			if _can_trigger_horde(phase):
				_trigger_horde(phase)
				_above_threshold_time = 0.0
	else:
		_above_threshold_time = maxf(0.0, _above_threshold_time - delta * 2.0)


# ═══════════════════════════════════════
# 剧本事件 API
# ═══════════════════════════════════════

func start_scripted_event(config: Dictionary) -> void:
	## 开始一个剧本事件（由 EventTrigger 调用）
	if _scripted_event_active:
		printerr("[EventManager] 已有剧本事件进行中，忽略: %s" % config.get("event_name", "?"))
		return

	_scripted_event_active = true
	_event_config = config
	_event_timer = config.get("event_duration", 60.0)
	_event_spawn_timer = 0.0  # 第一批立即生成
	_event_total_spawned = 0

	var event_name: String = config.get("event_name", "Unnamed")
	var event_type: int = config.get("event_type", ScriptedEventTrigger.EventType.CRESCENDO)
	print("[EventManager] ★ 剧本事件开始: %s (type=%d, duration=%.1fs)" % [event_name, event_type, _event_timer])

	# 暂停正常节奏，强制进入 Peak 模式
	var pc: Node = _director.get_node_or_null("PacingController")
	if pc:
		pc.paused = true
		if pc.has_method("force_peak"):
			pc.force_peak()

	# 暂停 SpawnManager（剧本事件自己管理生成）
	var sm: Node = _director.get_node_or_null("SpawnManager")
	if sm:
		sm.enabled = false

	# 信号
	scripted_event_started.emit(event_name)
	if _director.has_signal("scripted_event_triggered"):
		_director.scripted_event_triggered.emit(event_name)


func is_scripted_event_active() -> bool:
	return _scripted_event_active


func get_event_progress() -> float:
	## 返回 0.0~1.0 事件进度
	if not _scripted_event_active:
		return 0.0
	var total: float = _event_config.get("event_duration", 60.0)
	if total <= 0.0:
		return 0.0
	return 1.0 - (_event_timer / total)


# ═══════════════════════════════════════
# 内部 — 剧本事件更新
# ═══════════════════════════════════════

func _update_scripted_event(delta: float, alive_count: int) -> void:
	_event_timer -= delta
	_event_spawn_timer -= delta

	# 检查是否超时
	if _event_timer <= 0.0:
		_end_scripted_event()
		return

	# 定时生成敌人
	if _event_spawn_timer <= 0.0:
		var max_active: int = _event_config.get("max_active", 12)
		var per_wave: int = _event_config.get("spawn_per_wave", 3)

		if alive_count < max_active:
			var to_spawn: int = mini(per_wave, max_active - alive_count)
			var decor: Node = _find_decor()
			if decor:
				var spawned: int = _director.spawn_horde(to_spawn, decor)
				_event_total_spawned += spawned

		_event_spawn_timer = _event_config.get("spawn_interval", 3.0)

	# 进度信号
	scripted_event_progress.emit(get_event_progress())


func _end_scripted_event() -> void:
	var event_name: String = _event_config.get("event_name", "Unnamed")
	print("[EventManager] ★ 剧本事件结束: %s (共生成 %d 个敌人)" % [event_name, _event_total_spawned])

	_scripted_event_active = false

	# 恢复正常节奏 → Cooldown
	var pc: Node = _director.get_node_or_null("PacingController")
	if pc:
		pc.paused = false
		if pc.has_method("force_cooldown"):
			pc.force_cooldown()

	# 恢复 SpawnManager
	var sm: Node = _director.get_node_or_null("SpawnManager")
	if sm:
		sm.enabled = true

	# 通知 EventTrigger
	var trigger: Node = _event_config.get("trigger_node") as Node
	if trigger and is_instance_valid(trigger) and trigger.has_method("on_event_completed"):
		trigger.on_event_completed()

	# 信号
	scripted_event_completed.emit(event_name)

	_event_config.clear()


# ═══════════════════════════════════════
# 查询
# ═══════════════════════════════════════
func get_threshold_ratio() -> float:
	## 紧张度超过阈值的持续时间比例（0-1），用于 UI
	return clampf(_above_threshold_time / HORDE_SUSTAIN_TIME, 0.0, 1.0)


# ═══════════════════════════════════════
# 内部 — 自然尸潮触发判定
# ═══════════════════════════════════════
func _can_trigger_horde(phase: StringName) -> bool:
	if _scripted_event_active:
		return false

	var now: int = Time.get_ticks_msec()

	if phase == &"peak":
		# Peak 内也可再次触发尸潮（加码），冷却较短
		if now - _last_peak_horde_time_msec < int(PEAK_HORDE_COOLDOWN * 1000):
			return false
	else:
		# Build / Cooldown 阶段：触发即进入 Peak
		if now - _last_horde_time_msec < int(HORDE_COOLDOWN * 1000):
			return false

	return true


func _trigger_horde(phase: StringName) -> void:
	if _scripted_event_active:
		return

	var now: int = Time.get_ticks_msec()
	print("[EventManager] triggering horde! phase=%s intensity=%.2f" % [phase, _director.get_intensity()])

	if phase == &"peak":
		# 已在 Peak → 追加一批尸潮
		_last_peak_horde_time_msec = now
		var sm: Node = _director.get_node_or_null("SpawnManager")
		if sm and sm.has_method("_start_horde"):
			sm._start_horde()
	else:
		# Build/Cooldown → 强制进入 Peak
		_last_horde_time_msec = now
		var pc: Node = _director.get_node_or_null("PacingController")
		if pc and pc.has_method("force_peak"):
			pc.force_peak()

	# 发送信号
	if _director.has_signal("horde_incoming"):
		_director.horde_incoming.emit()


# ═══════════════════════════════════════
# 内部 — 查找 DecorLayer
# ═══════════════════════════════════════
func _find_decor() -> Node:
	if _director and _director.has_method("_find_decor_layer"):
		return _director._find_decor_layer()
	return null
