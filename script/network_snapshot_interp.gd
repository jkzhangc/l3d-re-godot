extends RefCounted

## ── 架构定位 ──
## 系统：联机表现 ｜ 层：网络（RefCounted）
## 联机：仅 Client 使用
## 职责：远端实体位置快照插值缓冲：固定延迟 + 样本间线性插值，起停干脆且不外推。
## 依赖：被 Player 的远端表现使用

## 远端实体位置快照插值缓冲。
##
## 旧的远端表现每帧向最新快照位置做指数平滑 lerp，起停时呈现"先慢后快、
## 滑行半天"的摩擦力观感。本缓冲保存最近若干个快照样本（带到达时间戳），
## 渲染时固定落后 render_delay 秒，在相邻两个样本之间线性插值：
## 匀速移动完全贴合快照，起停干脆，且能吸收轻微的网络抖动。
## 数据不足（丢包 / 卡顿）时停在最新样本位置，绝不外推。

const MAX_SAMPLES := 24

## 样本 {t: float, pos: Vector2}，t 为到达时刻（秒），按追加顺序递增。
var _samples: Array = []
var _render_delay: float


func _init(render_delay: float) -> void:
	_render_delay = maxf(render_delay, 0.0)


## 权威校准（可靠快照 / 生成 / 死亡定位）：清空历史并直接落位。
func reset(position: Vector2) -> void:
	_samples.clear()
	_samples.append({"t": _now(), "pos": position})


## 追加一个不可靠快照样本；缓冲为空时等价于 reset（首包直接落位）。
func push_sample(position: Vector2) -> void:
	if _samples.is_empty():
		reset(position)
		return
	_samples.append({"t": _now(), "pos": position})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## 当前应渲染的位置；缓冲为空时返回 null，调用方保持原位置不动。
func sample_render_position() -> Variant:
	if _samples.is_empty():
		return null
	var render_time := _now() - _render_delay
	var newest: Dictionary = _samples[_samples.size() - 1]
	if render_time >= float(newest["t"]):
		# 新样本之后没有更多数据：停在最新位置等待下一包。
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
