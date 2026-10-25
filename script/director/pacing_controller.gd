extends Node

## ── 架构定位 ──
## 系统：导演系统 ｜ 层：玩法（Node，子模块）
## 联机：仅单机/Host
## 职责：把紧张度翻译为 build/peak/cooldown 三阶段循环，并广播 phase_changed 供生成器使用。
## 依赖：被 Director 调用，广播给 SpawnManager

## 将紧张度转换为 BUILDUP/PEAK/RELAX 等节奏阶段，供 Director 决定是否触发事件。
## 节奏控制器 — 管理 Build-up → Peak → Cooldown 三阶段循环
##
## 根据紧张度 + 时间自动切换阶段，所有参数 Inspector 可调

# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal phase_changed(phase: StringName)  ## "build", "peak", "cooldown"

# ═══════════════════════════════════════
# 枚举
# ═══════════════════════════════════════
## ★2026-10-24：新增 FADE（Peak Fade 余韵段）。枚举顺序勿动 ——
## COOLDOWN 仍是「喘息」，外部大量 `phase == &"cooldown"` 判断依赖它。
enum Phase { BUILD, PEAK, COOLDOWN, FADE }

# ═══════════════════════════════════════
# 参数（Inspector 可调）
# ═══════════════════════════════════════
@export var build_min: float = 36.0        ## Build-up 最短时长（秒）
@export var build_max: float = 108.0       ## Build-up 最长时长（秒）
@export var peak_timeout: float = 60.0     ## Peak 最大持续时长（秒）
@export var cooldown_min: float = 0.0      ## Cooldown 最短时长（秒）
@export var cooldown_max: float = 10.0     ## Cooldown 最长时长（秒）
@export var variation: float = 0.2         ## 时长随机偏移（±比例）
@export var peak_intensity_threshold: float = 0.7   ## 紧张度 > 此值提前进入 Peak
@export var cooldown_intensity_threshold: float = 0.3  ## 紧张度 > 此值提前结束 Cooldown

# ── L4D 模型（2026-10-24）──
## 开启后：峰值为「停手段」（不再持续供怪），峰值结束先进 FADE 余韵，再进 COOLDOWN 喘息。
@export var l4d_model: bool = true
## 峰值最短停留（Sustain Peak）：进峰值后至少撑这么久才允许结束。
@export var peak_sustain: float = 4.0
## 余韵判定：持续「无交战」这么多秒 → 进喘息。
@export var fade_quiet_sec: float = 2.5
## 余韵兜底时长（残兵躲角落时不会永远卡住）。
@export var fade_timeout: float = 12.0

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var current_phase: Phase = Phase.COOLDOWN  ## 从喘息开始，等玩家出安全屋
var phase_elapsed: float = 0.0
var phase_duration: float = 0.0
var enabled: bool = true
var paused: bool = false
var _fade_quiet: float = 0.0               ## FADE 段「连续无交战」累计秒数
## ★峰值再触发闸（施密特触发器，2026-10-24 用户实测「尸潮刚结束又立刻来一次」）：
## 强度必须**先掉回** `peak_intensity_threshold * 0.8` 以下，才允许下一次由强度触发峰值。
## 没有这道闸时，交战保持会让强度长期贴在阈值之上 → 每 3 秒一轮"喘息→爬升→尸潮"。
var _peak_armed: bool = true


# ═══════════════════════════════════════
# 每帧由 director 调用
# ═══════════════════════════════════════
## `horde_active`：旧模型下 = 尸潮窗口是否仍在维持数量（见下面 PEAK 分支）。
## `engaged`：**L4D 模型专用** —— 当前是否有敌人在交战（Director 每帧传入
## `IntensityTracker.in_combat`）。FADE 段必须等到「无交战」才算自然收尾。
func update(delta: float, intensity: float, alive_enemy_count: int,
		horde_active: bool = false, engaged: bool = false) -> void:
	if paused or not enabled:
		return

	phase_elapsed += delta
	var should_transition: bool = false

	## 重新武装：强度掉回阈值 80% 以下才算"这一波真的过去了"。
	if not _peak_armed and intensity < peak_intensity_threshold * 0.8:
		_peak_armed = true

	match current_phase:
		Phase.BUILD:
			if phase_elapsed >= phase_duration:
				should_transition = true
			elif intensity > peak_intensity_threshold and _peak_armed:
				should_transition = true

		Phase.PEAK:
			if l4d_model:
				## ★L4D 模型（2026-10-24）：峰值是「停手段」。
				## 进入峰值时尸潮已经一次性发出去了，这里只负责判定何时收尾：
				##   · 至少撑够 peak_sustain（Sustain Peak，保证"砸下来"的存在感）；
				##   · 场上清空 → 进余韵；
				##   · 或者超时 → 进余韵（防止残兵卡住节奏）。
				## 旧模型的 `horde_active` 在这里**故意不看** —— 峰值不再维持数量。
				if phase_elapsed >= peak_sustain:
					if alive_enemy_count <= 0:
						should_transition = true
					elif phase_elapsed >= peak_timeout:
						should_transition = true
			else:
				## 旧模型：尸潮窗口（SpawnManager 正在维持数量）内**不**因"一时清空"提前结束。
				if alive_enemy_count <= 0 and phase_elapsed > 3.0 and not horde_active:
					should_transition = true
				elif phase_elapsed >= peak_timeout:
					should_transition = true

		Phase.FADE:
			## 余韵段（L4D Peak Fade）：不生成任何敌人，等战斗自然收尾。
			## 「自然收尾」= 场上没有敌人，且没有任何交战持续 fade_quiet_sec 秒。
			if alive_enemy_count <= 0 and not engaged:
				_fade_quiet += delta
			else:
				_fade_quiet = 0.0
			if _fade_quiet >= fade_quiet_sec:
				should_transition = true
			elif phase_elapsed >= fade_timeout:
				should_transition = true

		Phase.COOLDOWN:
			if phase_elapsed >= phase_duration:
				should_transition = true
			elif not l4d_model and intensity > cooldown_intensity_threshold and phase_elapsed > 3.0:
				## ★L4D 模型下**故意不因强度提前结束喘息**（2026-10-24）：
				## 交战保持会让强度在残余敌人清完前一直偏高，3 秒就到阈值 →
				## 喘息名存实亡，且会立刻接下一发尸潮（用户听到的就是"音乐刚停、预警音又响"）。
				## L4D 的 Relax 只由「时间到」和「走远」结束（走远由 Director.relax_advance 处理）。
				should_transition = true

	if should_transition:
		_advance_phase()


# ═══════════════════════════════════════
# 手动切换阶段
# ═══════════════════════════════════════
## ★开场立即刷怪（2026-09-27）：让 Director 在勾了 spawn_immediate_on_start 的图上，
## 于场景加载时直接跳出喘息进入 build（SpawnManager 进 build 时会把散兵计时清零 → 立刻刷第一批）。
func force_build() -> void:
	_set_phase(Phase.BUILD)


func force_peak() -> void:
	_set_phase(Phase.PEAK)


func force_cooldown() -> void:
	_set_phase(Phase.COOLDOWN)


func force_fade() -> void:
	_set_phase(Phase.FADE)


## 当前阶段名（StringName）。**外部一律用这个，不要按枚举序号 match** ——
## 2026-10-24 新增了 FADE，序号会随枚举顺序变化。
func get_phase_name() -> StringName:
	return _phase_name(current_phase)


# ═══════════════════════════════════════
# 内部 — 阶段推进
# ═══════════════════════════════════════
func _advance_phase() -> void:
	match current_phase:
		Phase.BUILD:     _set_phase(Phase.PEAK)
		## L4D 模型：峰值结束后先进余韵（等战斗自然收尾），再进喘息。
		Phase.PEAK:      _set_phase(Phase.FADE if l4d_model else Phase.COOLDOWN)
		Phase.FADE:      _set_phase(Phase.COOLDOWN)
		Phase.COOLDOWN:  _set_phase(Phase.BUILD)


func _set_phase(new_phase: Phase) -> void:
	current_phase = new_phase
	phase_elapsed = 0.0
	_fade_quiet = 0.0
	## 进峰值即"解除武装"：下一次强度触发必须先让强度掉回阈值 80% 以下。
	if new_phase == Phase.PEAK:
		_peak_armed = false
	phase_duration = _rand_duration(new_phase)

	var phase_name: StringName = _phase_name(new_phase)
	print("[Pacing] → %s (duration=%.1fs)" % [phase_name, phase_duration])
	phase_changed.emit(phase_name)


func _rand_duration(phase: Phase) -> float:
	var base_min: float
	var base_max: float
	match phase:
		Phase.BUILD:     base_min = build_min; base_max = build_max
		Phase.PEAK:      return peak_timeout
		Phase.FADE:      return fade_timeout
		Phase.COOLDOWN:  base_min = cooldown_min; base_max = cooldown_max

	return randf_range(base_min, base_max)


func _phase_name(phase: Phase) -> StringName:
	match phase:
		Phase.BUILD:    return &"build"
		Phase.PEAK:     return &"peak"
		Phase.FADE:     return &"fade"
		Phase.COOLDOWN: return &"cooldown"
	return &"unknown"
