extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host
## 职责：剧本事件与尸潮生命周期编排（Crescendo/Finale/Alarm/Boss/Horde），含事件期间敌人目标锁定与解锁。
## 依赖：Director、HoldoutMachine、ScriptedEventTrigger

## 编排脚本事件和尸潮生命周期；联机 Client 不执行自己的事件副本。
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
## 倒计时每帧刷新（用于防守战 HUD）：剩余秒数 + 总秒数
signal scripted_event_tick(remaining: float, total: float)

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
## 固定刷怪点的轮转起点（2026-09-26）：每批 +1，让"多出来的那一只"在点位之间轮换，
## 避免永远同一个点多刷一只（5 只 / 3 点：这批 2、2、1，下批换个点 2、2、1）。
var _event_wave_index: int = 0
## 防守战期间被锁定目标的敌人；事件结束时逐个解锁，恢复普通 AI。
var _locked_enemies: Array[Node2D] = []

# 外部引用
var _director: Node = null


# ═══════════════════════════════════════
# 初始化
# ═══════════════════════════════════════
## Director 处于防守战挂起（set_director_suspended）状态时，本模块不碰节奏控制器：
## 节奏的冻结/恢复/尸潮收尾全部由 Director 统一负责。
func _is_director_suspended() -> bool:
	return bool(_director and _director.get("director_suspended"))


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
	## 固定刷怪点的轮转起点（2026-09-26）：每批 +1，让"多出来的那一只"在点位间轮换。
	_event_wave_index = 0
	_locked_enemies.clear()

	var event_name: String = config.get("event_name", "Unnamed")
	var event_type: int = config.get("event_type", ScriptedEventTrigger.EventType.CRESCENDO)
	print("[EventManager] ★ 剧本事件开始: %s (type=%d, duration=%.1fs)" % [event_name, event_type, _event_timer])

	# 暂停正常节奏，强制进入 Peak 模式
	## ⚠ 防守战挂起（director_suspended）期间绝不能 force_peak：防守战本体走剧本事件
	## 管线，一启动就把节奏强切 peak = 触发尸潮狂暴 + 尸潮 BGM；且挂起期间节奏被冻结、
	## cooldown 永远不会来 → 尸潮 BGM 永远停不下来（2026-09-12 用户实测双 BGM 的根因）。
	var pc: Node = _director.get_node_or_null("PacingController")
	if pc and not _is_director_suspended():
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

	# 防守战：开局即把机器附近的已存在丧尸也强制锁定追击最近玩家，
	# 让「附近已刷出来的丧尸」在防守战一开始就扑向玩家（与新刷的丧尸行为一致）。
	if bool(config.get("lock_nearby_at_start", false)):
		var center: Vector2 = config.get("lock_nearby_center", Vector2.ZERO)
		var radius: float = float(config.get("lock_nearby_radius", 0.0))
		_lock_nearby_enemies(center, radius)


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


## 剩余秒数（倒计时 UI 用）；无事件进行中返回 0。
func get_event_remaining() -> float:
	if not _scripted_event_active:
		return 0.0
	return maxf(_event_timer, 0.0)


## 事件总时长（秒）；无事件进行中返回 0。
func get_event_duration() -> float:
	if not _scripted_event_active:
		return 0.0
	return maxf(float(_event_config.get("event_duration", 60.0)), 0.0)


## 提前结束当前事件（照常触发完成事件与解锁）。
func abort_scripted_event() -> void:
	if not _scripted_event_active:
		return
	print("[EventManager] 剧本事件被提前结束")
	_end_scripted_event()


# ═══════════════════════════════════════
# 内部 — 防守战目标锁定
# ═══════════════════════════════════════

## 给本批新敌人各自锁定一名「最近的玩家」为固定追击目标。
## 通过 Players.nearest_entity_to(敌人位置) 取离该丧尸最近的存活玩家：
##   - 单人模式：场上只有一个玩家 → 锁定唯一玩家
##   - 联机模式：每个丧尸锁定离自己最近的玩家（即「追击附近的玩家」）
## 无视视野/距离，且不会因丢失视野放弃（直到防守战结束统一解锁）。
func _lock_new_enemies(enemies: Array[Node2D]) -> void:
	for enemy: Node2D in enemies:
		if not is_instance_valid(enemy):
			continue
		if not enemy.has_method("lock_forced_target"):
			continue
		var target: Node2D = Players.nearest_entity_to(enemy.global_position) as Node2D
		enemy.lock_forced_target(target)
		_locked_enemies.append(enemy)


## 事件结束 → 解除全部锁定，敌人恢复普通 AI（视野发现/放弃逻辑重新生效）。
func _release_locked_enemies() -> void:
	var released: int = 0
	for enemy: Node2D in _locked_enemies:
		if not is_instance_valid(enemy):
			continue
		if enemy.has_method("release_forced_target"):
			enemy.release_forced_target()
			released += 1
	_locked_enemies.clear()
	if released > 0:
		print("[EventManager] 已解除 %d 个敌人的目标锁定" % released)


## 防守战开局：把 center 半径内的已存在丧尸强制锁定追击最近玩家。
## 这些丧尸不是本次事件刷出来的（属于开局前就有的普通尸潮），但仍要参与防守战，
## 因此直接拉进 _locked_enemies，待事件结束（_release_locked_enemies）时统一解锁，恢复普通 AI。
func _lock_nearby_enemies(center: Vector2, radius: float) -> void:
	if radius <= 0.0:
		return
	var tree := get_tree()
	if not tree:
		return
	for e: Node in tree.get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if e.has_method("has_forced_target") and e.has_forced_target():
			continue  # 已经锁定过（如刚刷出的）就不重复
		if (e as Node2D).global_position.distance_to(center) > radius:
			continue
		if not e.has_method("lock_forced_target"):
			continue
		var target: Node2D = Players.nearest_entity_to((e as Node2D).global_position) as Node2D
		e.lock_forced_target(target)
		_locked_enemies.append(e)


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
		# 默认沿用 SpawnManager 的尸潮节奏：
		#   max_active     ← max_active_common（同屏存活上限）
		#   spawn_per_wave ← horde_batch_size（每批数量）
		#   spawn_interval ← horde_batch_interval（批次间隔）
		# 不传这些参数时（如防守战 / HoldoutMachine），防守战 = 一场持续的尸潮；
		# 其余剧本事件若显式传了对应字段，则以传入值为准。
		var sm: Node = _director.get_node_or_null("SpawnManager")
		# 用 Object.get() 动态取 SpawnManager 的尸潮参数（避免对基类型 Node 做静态成员访问报错）
		var max_active: int = int(_event_config.get("max_active", sm.get("max_active_common") if sm else 12))
		var per_wave: int = int(_event_config.get("spawn_per_wave", sm.get("horde_batch_size") if sm else 3))
		var interval: float = float(_event_config.get("spawn_interval", sm.get("horde_batch_interval") if sm else 3.0))
		## 每批数量与存活上限按真人数放大（2026-09-25 用户需求）：
		## 防守战与尸潮事件批都走这里，是它们的唯一生成点。
		## ⚠ max_active 语义是"上限"，只在 >0 时放大（0 = 沿用全局 SpawnManager，此时上面已取到 40）。
		## 批次间隔（interval）**不**缩放：人数越多越靠"量"而不是"频率"加压，
		## 否则 4 人下刷怪节奏会碎成滴答声。
		per_wave = Players.scale_spawn_count(per_wave)
		## 上限用温和曲线（见 Players.scaled_active_cap）：刷怪量照倍率，实体数不翻倍。
		max_active = Players.scaled_active_cap(max_active)

		if alive_count < max_active:
			var to_spawn: int = mini(per_wave, max_active - alive_count)
			var decor: Node = _find_decor()
			if decor:
				var new_enemies: Array[Node2D] = []
				## 固定刷怪点（2026-09-26 用户需求）：事件配置里带了点位就用点位轮转均分，
				## 没带就**完全沿用原来的"前方屏外刷"**。倍率已在上面按真人数放大过，
				## 因此「均分」天然继承按人数的刷怪倍率（先放大、后分散）。
				var fixed_points: Array = _event_config.get("spawn_positions", [])
				if not fixed_points.is_empty():
					new_enemies = _director.spawn_horde_nodes_at_positions(
						fixed_points, to_spawn, decor, _event_wave_index)
				else:
					new_enemies = _director.spawn_horde_nodes(to_spawn, decor)
				_event_wave_index += 1
				_event_total_spawned += new_enemies.size()
				if bool(_event_config.get("target_lock", false)):
					_lock_new_enemies(new_enemies)

		_event_spawn_timer = interval

	# 进度 + 倒计时信号
	scripted_event_progress.emit(get_event_progress())
	scripted_event_tick.emit(maxf(_event_timer, 0.0), get_event_duration())


func _end_scripted_event() -> void:
	var event_name: String = _event_config.get("event_name", "Unnamed")
	print("[EventManager] ★ 剧本事件结束: %s (共生成 %d 个敌人)" % [event_name, _event_total_spawned])

	_scripted_event_active = false

	# 解除防守战目标锁定 → 新生成的敌人恢复正常状态
	_release_locked_enemies()

	# 恢复正常节奏 → Cooldown
	## 防守战挂起期间不要解除暂停：SETTLE 阶段也在挂起窗口内，节奏解冻由
	## Director.set_director_suspended(false) 统一负责（含从 cooldown 重新计时）。
	var pc: Node = _director.get_node_or_null("PacingController")
	if pc and not _is_director_suspended():
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
