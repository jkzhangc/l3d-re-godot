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
@export var horde_total_min: int = 3          ## 尸潮期间**同时维持**的存活数下限（由 DirectorConfig 覆盖）
@export var horde_total_max: int = 15         ## 尸潮期间同时维持的存活数上限
@export var horde_batch_size: int = 5         ## 每次补充的上限：缺多少补多少，不会一次刷满
@export var horde_batch_interval: float = 5.0 ## 补充批次的基础间隔（秒）
@export var horde_duration_min: float = 25.0  ## 尸潮持续时长下限（秒）—— 结束条件从"额度刷完"改为"窗口走完"
@export var horde_duration_max: float = 40.0  ## 尸潮持续时长上限（秒）；会被 peak_timeout 截断
@export var max_active_common: int = 15       ## 同时最多普通感染者

# ═══════════════════════════════════════
# 画面外补怪总开关（2026-10-29 用户需求）
# ═══════════════════════════════════════
## ★关闭（默认）→ build 预算批次与喘息补位**一律不发货**，路上只剩作者 SpawnZone 与
## 尸潮/特感/Boss 事件。打开 → 按下面的人数区间在「前方屏外」补位：
## 威胁圈内**跌到下限**才开补，**补到上限**才停手（迟滞带：中间区间不补也不停，避免"杀一只补一只"）。
## ⚠ 打开后，本文件的 `build_threat_limit` 与 `relax_target` 不再是补怪闸门（被本区间取代）。
@export var offscreen_refill_enabled: bool = false
@export var offscreen_refill_min: int = 4
@export var offscreen_refill_max: int = 10

## 迟滞带闩锁：true = 本轮"开补"尚未补到上限。
var _refill_latch: bool = false

# ═══════════════════════════════════════
# L4D 模型参数（2026-10-24）
# ═══════════════════════════════════════
## ★核心：开启后本模块改用「消耗型预算 + 峰值尸潮窗口（按时间结束、期间补怪）+ 喘息低人口」。
## 与旧模型的根本差别：旧模型的补位是**维持数量**（缺多少补多少，击杀立刻腾位），
## 因此原地打会稳定成"永远有 N 只"；新模型的预算是**可消耗的**，用完就停手。
@export var l4d_model: bool = false

@export_group("L4D — 加压预算（BUILD 阶段）")
@export var build_budget_min: int = 12         ## 每个 Build 阶段发放的预算下限（按难度/人数放大）
@export var build_budget_max: int = 20         ## 预算上限。用完即停手，直到进入下一阶段
@export var build_batch_min: int = 2           ## 每批最少几只
@export var build_batch_max: int = 3           ## 每批最多几只
@export var build_interval_min: float = 5.0    ## 两批之间最短秒数
@export var build_interval_max: float = 9.0    ## 两批之间最长秒数

@export_group("L4D — 尸潮（PEAK 入场爆发 + 整段补怪）")
@export var mob_size_min: int = 14             ## 尸潮规模下限（按难度/人数放大）
@export var mob_size_max: int = 22             ## 尸潮规模上限
## 从**背后**来的比例（L4D 原版 75%）。玩家回头才有压力，才有被包夹的戏剧性。
@export_range(0.0, 1.0, 0.05) var mob_behind_ratio: float = 0.75

@export_group("L4D — 喘息（COOLDOWN / Relax）")
## 喘息期维持多少只。0 = 完全不生成（最接近 L4D 的 Relax）。
@export var relax_target: int = 2
## 喘息期补位的最短间隔（秒），仅 relax_target > 0 时生效。
@export var relax_interval: float = 7.0
## 加压阶段：贴脸敌人达到这个数就不再追加（预算之外的软闸，防"围成一圈"）。
## 实际值会按难度/人数放大。默认 10：进图预铺的游荡者已占 5~7 只，闸太紧会让预算花不出去。
@export var build_threat_limit: int = 10

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

# ── L4D 模型运行时 ──
var _budget_left: int = 0        ## 当前 Build 阶段剩余的普通感染者预算（用完即停手）
var _relax_timer: float = 0.0    ## 喘息期补位计时（仅 relax_target > 0）

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

	## ★尸潮窗口（2026-10-29 用户定稿）：峰值期间**按时间维持人数**，两个模型共用，
	## 且**不受「画面外补怪」总开关影响** —— 那个开关管的是路上零散的补位；
	## 尸潮是事件本身，关掉补怪开关也要有完整的一波（缺多少补多少，直到峰值结束）。
	if current_phase == &"peak" and _horde_active:
		_update_horde(delta, alive_count)
	elif not l4d_model and _horde_active:
		## 非峰值阶段的窗口倒计时（正常不会出现，防御性保留）
		_horde_time_left -= delta
		if _horde_time_left <= 0.0:
			_horde_active = false

	if not offscreen_refill_enabled:
		return

	## ★L4D 模型（2026-10-24）：生成时机完全由「预算 + 阶段」决定。
	## peak 已在上面的尸潮窗口处理过，这里只负责 build 预算与 cooldown 喘息。
	if l4d_model:
		_update_l4d(delta, intensity, alive_count)
		return

	match current_phase:
		&"build":
			_update_scatter(delta, intensity, alive_count)
		&"peak":
			pass   # 尸潮窗口已在上方推进
		&"cooldown":
			pass  # 不主动生成


# ═══════════════════════════════════════
# 节奏阶段切换回调
# ═══════════════════════════════════════
func on_phase_changed(phase: StringName) -> void:
	current_phase = phase
	print("[SpawnManager] phase → %s" % phase)

	## ★L4D 模型的阶段语义 ——
	##   build  = 发预算，缓慢加压（预算用完就静默）
	##   peak   = 入场发一波 + **整段持续补怪**（2026-10-29 改：按时间结束，见 _start_mob）
	##   fade   = 余韵，什么都不生成
	##   cooldown = 喘息，最多维持 relax_target 只
	if l4d_model:
		_on_phase_changed_l4d(phase)
		return

	match phase:
		&"build":
			_horde_active = false
			_reset_scatter_timer()
			_scatter_timer = 0.0  # 第一次立即刷，不等待
		&"peak":
			_start_horde()
		&"cooldown":
			_horde_active = false


func _on_phase_changed_l4d(phase: StringName) -> void:
	match phase:
		&"build":
			_horde_active = false
			## 常态补怪：**不吃难度**（2026-10-29 用户定稿），各难度密度一致
			_budget_left = Players.scale_ambient_count(
				randi_range(build_budget_min, build_budget_max))
			_scatter_timer = 0.0  # 进入加压阶段的第一批立即生成（不干等）
			print("[SpawnManager] L4D build: 预算 %d 只" % _budget_left)
		&"peak":
			_start_mob()   ## 入场爆发 + 建立峰值补怪窗口
		&"fade":
			_horde_active = false
		&"cooldown":
			_horde_active = false
			_budget_left = 0
			_relax_timer = relax_interval


# ═══════════════════════════════════════
# L4D 模型 — 每帧驱动
# ═══════════════════════════════════════
func _update_l4d(delta: float, intensity: float, alive_count: int) -> void:
	match current_phase:
		&"build":
			_update_build_budget(delta, intensity, alive_count)
		&"cooldown":
			_update_relax(delta, alive_count)
		_:
			pass  # peak / fade：**不生成**。峰值是"停手段"，让玩家把存量打完。


## 加压阶段：从预算里扣，每次 1~2 只、间隔 8~16 秒。
## 预算耗尽 → 静默（这就是空窗的来源）；进入下一阶段会重新发预算。
## ★2026-10-29：补怪窗口由 `offscreen_refill_min/max` 决定 —— 只有威胁圈降到下限以下
## 才开补，一次最多补到上限（迟滞带，替代旧的 build_threat_limit 软闸）。
func _update_build_budget(delta: float, intensity: float, alive_count: int) -> void:
	if _budget_left <= 0:
		return
	var active_cap: int = Players.scaled_active_cap(max_active_common)
	if alive_count >= active_cap:
		return
	## 补怪上下限（附近威胁圈内人口）
	var floor_n: int = _refill_floor()
	var ceiling_n: int = _refill_ceiling()
	if floor_n <= 0:
		return
	var threat: int = _threat_count()
	## 迟滞带：低于下限才开补；开补后一直补到上限才停手。
	if not _refill_allowed(threat, floor_n, ceiling_n):
		return

	_scatter_timer -= delta
	if _scatter_timer > 0.0:
		return
	_scatter_timer = randf_range(minf(build_interval_min, build_interval_max),
		maxf(build_interval_min, build_interval_max))

	var count: int = randi_range(mini(build_batch_min, build_batch_max),
		maxi(build_batch_min, build_batch_max))
	count = Players.scale_ambient_count(count)
	count = mini(count, _budget_left)
	count = mini(count, active_cap - alive_count)
	count = mini(count, ceiling_n - threat)
	if count <= 0:
		return

	var spawned: int = _spawn_ahead_l4d(count)
	_budget_left = maxi(_budget_left - spawned, 0)
	if spawned > 0:
		print("[SpawnManager] L4D build 批次 %d 只（预算剩 %d / 附近 %d→%d）"
			% [spawned, _budget_left, threat, threat + spawned])
	if threat + spawned >= ceiling_n:
		_refill_latch = false


## 喘息阶段：**只在补怪开关打开时**维持 `offscreen_refill_min` 的下限。
## 旧 `relax_target` 是"维持多少只"；现在统一由上下限接管（见 offscreen_refill_* 注释）。
func _update_relax(delta: float, alive_count: int) -> void:
	var floor_n: int = _refill_floor()
	var ceiling_n: int = _refill_ceiling()
	if floor_n <= 0:
		return
	_relax_timer -= delta
	if _relax_timer > 0.0:
		return
	_relax_timer = relax_interval
	var threat: int = _threat_count()
	if not _refill_allowed(threat, floor_n, ceiling_n):
		return
	var active_cap: int = Players.scaled_active_cap(max_active_common)
	if alive_count >= active_cap:
		return
	var spawned: int = _spawn_ahead_l4d(1)
	if spawned > 0 and threat + spawned >= ceiling_n:
		_refill_latch = false


## 补怪人数下限 / 上限（按人数与难度放大，和全项目刷怪倍率同一口径）。
func _refill_floor() -> int:
	return Players.scale_ambient_count(maxi(0, offscreen_refill_min))


func _refill_ceiling() -> int:
	return maxi(_refill_floor(), Players.scale_ambient_count(maxi(0, offscreen_refill_max)))


## 迟滞带判定（上下限的真正入口）：
##   ① 已到上限 → 关闩（本轮补位结束）
##   ② 跌到下限或以下 → 开闩（下一批可以补）
##   ③ 中间区间 → 保持上一状态（开着就一直补到上限，关着就不补）
## 这样「补怪上下限」才都起作用：只写下限会变成"补一只就停"，只写上限会变成"永远在补"。
func _refill_allowed(threat: int, floor_n: int, ceiling_n: int) -> bool:
	if ceiling_n <= 0:
		_refill_latch = false
		return false
	if threat >= ceiling_n:
		_refill_latch = false
		return false
	if threat <= floor_n:
		_refill_latch = true
	return _refill_latch


## 只在「前方屏外」补位（走 Director 的取点器，只是不再维持数量）。
func _spawn_ahead_l4d(count: int) -> int:
	if _director.has_method("spawn_mob_batch"):
		return int(_director.call("spawn_mob_batch", count, 0))
	return 0


func _threat_count() -> int:
	if _director.has_method("count_threat_near_players"):
		return int(_director.call("count_threat_near_players"))
	return 0


# ═══════════════════════════════════════
# L4D 模型 — 尸潮（峰值入场，一次性）
# ═══════════════════════════════════════
## 进入峰值时先发一波「砸下来」的尸潮（前方 + 背后 75%），
## 然后**整个峰值期间持续补怪**，直到峰值阶段按时间结束（2026-10-29 用户定稿）。
## 补怪目标复用旧模型的 horde_total_min/max（已按难度/人数放大）；
## 窗口长度 = 峰值阶段时长（PacingController 的 phase_duration）。
func _start_mob() -> void:
	var size: int = Players.scale_spawn_count(randi_range(
		mini(mob_size_min, mob_size_max), maxi(mob_size_min, mob_size_max)))
	var ratio: float = clampf(mob_behind_ratio, 0.0, 1.0)
	var behind: int = int(round(float(size) * ratio))
	var front: int = size - behind
	_horde_active = true
	## 峰值窗口：以 PacingController 抽好的 phase_duration 为准（峰值按时间结束）
	_horde_target_alive = Players.scale_spawn_count(randi_range(
		mini(horde_total_min, horde_total_max), maxi(horde_total_min, horde_total_max)))
	var pc: Node = _director.get_node_or_null("PacingController") if _director != null else null
	_horde_duration = float(pc.get("phase_duration")) if pc != null else 60.0
	_horde_time_left = maxf(_horde_duration, 1.0)
	_horde_spawned = 0
	_horde_batch_timer = 0.0   # 入场爆发后立刻允许第一次补位
	print("[SpawnManager] ★MOB 入场：共 %d 只（前方 %d / 背后 %d / 背后比例 %.0f%%），峰值 %.0fs 内维持 %d 只" % [
		size, front, behind, ratio * 100.0, _horde_duration, _horde_target_alive])
	if _director.has_method("spawn_mob_batch"):
		var spawned: int = int(_director.call("spawn_mob_batch", front, behind))
		_horde_spawned += spawned
		print("[SpawnManager] MOB 落地 %d/%d 只（落点不足时宁缺不挤）" % [spawned, size])


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
	## 存活上限按真人数放大（见 Players.scaled_active_cap）：
	## 2026-10-30 起多人 = 基础上限 ×2 / ×2.5 / ×3（2 / 3 / 4+ 人），单人再乘难度倍率。
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

	count = Players.scale_ambient_count(count)
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
	## L4D 模型：峰值不再「维持数量」—— 尸潮在进入峰值那一刻已由 `_start_mob` 一次性发完。
	## 外部调用（EventManager 的紧张度触发）在 l4d 模型下必须无效，
	## 否则峰值又会退化成"持续供水口"，空窗就做不出来。
	if l4d_model:
		return
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
