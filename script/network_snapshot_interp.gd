extends RefCounted

## ── 架构定位 ──
## 系统：联机表现 ｜ 层：网络（RefCounted）
## 联机：仅 Client 使用
## 职责：远端实体位置快照插值缓冲：**自适应**固定延迟 + 样本间线性插值，起停干脆且不外推。
## 依赖：被 Player / Enemy 的远端表现使用

## 远端实体位置快照插值缓冲（自适应抖动缓冲）。
##
## 【为什么改成自适应（2026-10-01，用户要求"尽量让玩家感觉不到延迟"）】
## 固定延迟只能按**最坏**抖动取值才不会卡顿 —— 等于让所有人在平稳网络下也白等那几十毫秒；
## 反之按最好情况取值，一有抖动就"停住 → 跳一下"。两边都错，所以做成自适应的：
## 构造传入的值是**延迟下限**（≈ 2.2 个快照间隔）：
##   · 快照迟到（实际间隔 > 估计间隔 × `LATE_RATIO`）→ 抬高额外延迟；
##   · 快照按时到达 → 每秒按 `EXTRA_DECAY_PER_SEC` 缓慢收回额外延迟。
## 结果：平稳网络下延迟就是下限（比原来的固定值低 10~15ms），只有真抖动时才临时加缓冲。
##
## ★另有**绝对上限** `max_delay`（用户 2026-10-01："网络有 100ms 也尽量保持 70ms 左右"）：
## 额外延迟最多顶到该值就不再涨 —— 延迟可预期，不会随持续抖动越滚越大。
## 代价是极端抖动下可能出现轻微顿感，这是"延迟可预期"换来的，属**有意取舍**。
##
## 渲染时固定落后 `render_delay()` 秒，在相邻两个样本之间线性插值：
## 匀速移动完全贴合快照，起停干脆，且能吸收轻微网络抖动。
## 数据不足（丢包 / 卡顿）时停在最新样本位置，**绝不外推**。

const MAX_SAMPLES := 24
## 额外延迟的默认上限系数（未显式给 `max_delay` 时使用）：生效延迟最高 = 下限 × 本值
const MAX_DELAY_MULT := 2.2
## 每次"迟到"快照累计的额外延迟（秒）
const EXTRA_PER_LATE := 0.010
## 额外延迟的回收速度（秒 / 秒）：按时到达时缓慢收回
const EXTRA_DECAY_PER_SEC := 0.015
## 迟到判据：实际间隔 > 估计间隔 × 本值
const LATE_RATIO := 1.6
## 间隔估计的单次上限倍数（一次大卡顿不该把"正常间隔"抬坏）
const GAP_CLAMP_MULT := 2.0
## 下限 ≈ 几个快照间隔（仅用于给间隔估计一个初值）
const FLOOR_INTERVALS := 2.2

## 样本 {t: float, pos: Vector2}，t 为到达时刻（秒），按追加顺序递增。
var _samples: Array = []
var _base_delay: float
## 生效延迟的**硬上限**。用户 2026-10-01 明确要求："网络有 100ms 也尽量保持 70ms 左右"
## —— 即宁可偶尔多一点点顿感，也不许缓冲随抖动无限膨胀（延迟必须可预期）。
var _max_delay: float
var _extra_delay: float = 0.0
var _interval_ema: float = 0.0
var _last_decay_time: float = 0.0

## ── 有限外推（2026-10-10，仅远端敌人启用）──
## 当渲染延迟**小于**快照间隔时（用户要求敌人 15ms < 16.7ms），缓冲每个周期会干涸一小段，
## 纯插值只能"停在最新样本"→ 表现为**一卡一卡**。允许在样本耗尽后按最近速度**短暂外推**，
## 把这一小段补平。外推上限取 1 个快照间隔的时长，且限制位移 —— 外推过远会在敌人急停/
## 转向时"冲出去再弹回"，比轻微卡顿更糟。
var _extrapolate: bool = false
## 外推的最大时长（秒）。≈ 1 个 60Hz 快照间隔，刚好覆盖缓冲干涸 + 轻微抖动。
const MAX_EXTRAPOLATE_SECONDS := 0.017

## `extrapolate` = 是否启用有限外推（默认关闭：远端玩家已调好，不引入外推副作用）。
func _init(render_delay: float, max_delay: float = -1.0, extrapolate: bool = false) -> void:
	_extrapolate = extrapolate
	_base_delay = maxf(render_delay, 0.0)
	_max_delay = max_delay if max_delay > 0.0 else _base_delay * MAX_DELAY_MULT
	if _max_delay < _base_delay:
		_max_delay = _base_delay
	## 间隔估计初值：下限 ÷ FLOOR_INTERVALS（首个间隔到达后很快被真实值取代）
	_interval_ema = _base_delay / FLOOR_INTERVALS if _base_delay > 0.0 else 0.0
	_last_decay_time = _now()


## 当前生效的渲染延迟 = 下限 + 自适应额外量。用例与调试用。
func render_delay() -> float:
	return _base_delay + _extra_delay


## 延迟下限（构造时传入，不含自适应量）。用例用。
func base_delay() -> float:
	return _base_delay


## 生效延迟硬上限。用例用。
func max_delay() -> float:
	return _max_delay


## 权威校准（可靠快照 / 生成 / 死亡定位）：清空历史并直接落位，同时复位自适应量。
func reset(position: Vector2) -> void:
	_samples.clear()
	_samples.append({"t": _now(), "pos": position})
	_extra_delay = 0.0
	_last_decay_time = _now()


## 追加一个不可靠快照样本；缓冲为空时等价于 reset（首包直接落位）。
func push_sample(position: Vector2) -> void:
	var now := _now()
	if _samples.is_empty():
		reset(position)
		return
	var last_t: float = float(_samples[_samples.size() - 1]["t"])
	_note_gap(maxf(now - last_t, 0.0))
	_samples.append({"t": now, "pos": position})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## 用到达间隔维持「估计间隔」与「额外延迟」两个量。
func _note_gap(gap: float) -> void:
	if _interval_ema <= 0.0:
		_interval_ema = gap
		return
	if gap > _interval_ema * LATE_RATIO:
		## 迟到：抬高额外延迟 —— 宁可多缓冲一点，也不要"停住再跳一下"
		## 上限是**绝对值**（`_max_delay`），不随抖动累积 → 延迟始终可预期
		var cap: float = maxf(_max_delay - _base_delay, 0.0)
		_extra_delay = minf(_extra_delay + EXTRA_PER_LATE, cap)
	## 估计间隔按钳制后的值更新（上限 GAP_CLAMP_MULT 倍），避免一次卡顿毁掉基准
	var clamped: float = minf(gap, _interval_ema * GAP_CLAMP_MULT)
	_interval_ema = lerpf(_interval_ema, clamped, 0.25)


## 当前应渲染的位置；缓冲为空时返回 null，调用方保持原位置不动。
func sample_render_position() -> Variant:
	if _samples.is_empty():
		return null
	var now := _now()
	if _extra_delay > 0.0 and _last_decay_time > 0.0:
		_extra_delay = maxf(_extra_delay - EXTRA_DECAY_PER_SEC * maxf(now - _last_decay_time, 0.0), 0.0)
	_last_decay_time = now

	var render_time := now - render_delay()
	var newest: Dictionary = _samples[_samples.size() - 1]
	if render_time >= float(newest["t"]):
		# 新样本之后没有更多数据。
		if _extrapolate:
			## 有限外推：按最近两个样本的速度往未来推，但**最多推 MAX_EXTRAPOLATE_SECONDS**，
			## 且样本不足 2 个时不推。补平"延迟 < 快照间隔"造成的缓冲干涸（一卡一卡）。
			var lead := minf(render_time - float(newest["t"]), MAX_EXTRAPOLATE_SECONDS)
			if lead > 0.0 and _samples.size() >= 2:
				var prev: Dictionary = _samples[_samples.size() - 2]
				var span := maxf(float(newest["t"]) - float(prev["t"]), 0.0001)
				var velocity := (newest["pos"] as Vector2 - prev["pos"] as Vector2) / span
				return (newest["pos"] as Vector2) + velocity * lead
		# 不外推（或外推不可用）：停在最新位置等待下一包。
		return newest["pos"]
	var oldest: Dictionary = _samples[0]
	if render_time <= float(oldest["t"]):
		return oldest["pos"]
	for index: int in range(_samples.size() - 1):
		var a: Dictionary = _samples[index]
		var b: Dictionary = _samples[index + 1]
		if render_time < float(b["t"]):
			var span := maxf(float(b["t"]) - float(a["t"]), 0.0001)
			var weight := clampf((render_time - float(a["t"])) / span, 0.0, 1.0)
			return (a["pos"] as Vector2).lerp(b["pos"], weight)
	return newest["pos"]


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
