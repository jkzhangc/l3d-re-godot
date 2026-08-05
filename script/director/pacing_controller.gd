extends Node
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
enum Phase { BUILD, PEAK, COOLDOWN }

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

# ═══════════════════════════════════════
# 运行时
# ═══════════════════════════════════════
var current_phase: Phase = Phase.COOLDOWN  ## 从喘息开始，等玩家出安全屋
var phase_elapsed: float = 0.0
var phase_duration: float = 0.0
var enabled: bool = true
var paused: bool = false


# ═══════════════════════════════════════
# 每帧由 director 调用
# ═══════════════════════════════════════
func update(delta: float, intensity: float, alive_enemy_count: int) -> void:
	if paused or not enabled:
		return

	phase_elapsed += delta
	var should_transition: bool = false

	match current_phase:
		Phase.BUILD:
			if phase_elapsed >= phase_duration:
				should_transition = true
			elif intensity > peak_intensity_threshold:
				should_transition = true

		Phase.PEAK:
			if alive_enemy_count <= 0 and phase_elapsed > 3.0:
				should_transition = true
			elif phase_elapsed >= peak_timeout:
				should_transition = true

		Phase.COOLDOWN:
			if phase_elapsed >= phase_duration:
				should_transition = true
			elif intensity > cooldown_intensity_threshold and phase_elapsed > 3.0:
				should_transition = true

	if should_transition:
		_advance_phase()


# ═══════════════════════════════════════
# 手动切换阶段
# ═══════════════════════════════════════
func force_peak() -> void:
	_set_phase(Phase.PEAK)


func force_cooldown() -> void:
	_set_phase(Phase.COOLDOWN)


# ═══════════════════════════════════════
# 内部 — 阶段推进
# ═══════════════════════════════════════
func _advance_phase() -> void:
	match current_phase:
		Phase.BUILD:     _set_phase(Phase.PEAK)
		Phase.PEAK:      _set_phase(Phase.COOLDOWN)
		Phase.COOLDOWN:  _set_phase(Phase.BUILD)


func _set_phase(new_phase: Phase) -> void:
	current_phase = new_phase
	phase_elapsed = 0.0
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
		Phase.COOLDOWN:  base_min = cooldown_min; base_max = cooldown_max

	return randf_range(base_min, base_max)


func _phase_name(phase: Phase) -> StringName:
	match phase:
		Phase.BUILD:    return &"build"
		Phase.PEAK:     return &"peak"
		Phase.COOLDOWN: return &"cooldown"
	return &"unknown"
