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
## 强度最多能把 Build 提前多少（0.85 = 只允许在 Build 进度 85% 之后由强度触发）。
## ★2026-10-29：没有这道闸时，一进图开打二三十秒强度就到阈值 → 尸潮间隔完全由战斗决定，
## 难度表里的「普通 3~5 分钟」根本落不了地（用户实测「尸潮太快」）。
@export_range(0.1, 1.0, 0.05) var peak_trigger_after_ratio: float = 0.85
@export var cooldown_intensity_threshold: float = 0.3  ## 紧张度 > 此值提前结束 Cooldown

# ── 智能尸潮（2026-10-29 用户设计；2026-10-30 改为双触发）──
## 开启后 BUILD 有两个触发源，**任一满足即进尸潮**：
##   ① 连续**无交战**达到阈值（提前触发，有节奏感）；
##   ② BUILD 时长走完（时间硬上限，兜底，不会无限安静）。
## 阈值 = clamp(base + 本章击杀数 × per_kill, min, max)：杀得越多，需要安静越久。
## 关掉 = 回到「难度间隔表 / build_min~max」的定时节奏（强度只在后段可提前）。
@export var smart_horde: bool = false
@export var smart_base_sec: float = 120.0      ## 0 杀时的无交战阈值（默认 2 分钟）
@export var smart_per_kill_sec: float = 2.0    ## 每击杀 +2s（用户 2026-10-29 定）
@export var smart_min_sec: float = 30.0        ## 阈值下限（两波之间的硬间隔）
@export var smart_max_sec: float = 360.0       ## 阈值上限（6 分钟）

## 本章累计击杀（Director 每 0.5s 从 ChapterStats 喂进来；换图由 ChapterStats 归零）
var _horde_kills: int = 0
## 连续无交战秒数：只在 BUILD 段累计，进峰值清零
var _quiet_sec: float = 0.0

# ── L4D 模型（2026-10-24）──
## 开启后：峰值为「停手段」（不再持续供怪），峰值结束先进 FADE 余韵，再进 COOLDOWN 喘息。
@export var l4d_model: bool = true
## 峰值最短停留 = 峰值时长的**下限**。
## ⚠ 2026-10-29 起峰值改为「按时间结束」，本值不再参与结束判定，只兜底不让峰值短于它。
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
## `horde_active`：旧模型下 = 尸潮窗口是否仍在维持数量（**已不参与结束判定**，
## 2026-10-29 起峰值一律按时间结束，保留参数是为了不破坏外部调用签名）。
## `engaged`：**L4D 模型专用** —— 当前是否有敌人在交战（Director 每帧传入
## `IntensityTracker.in_combat`）。FADE 段必须等到「无交战」才算自然收尾。
func update(delta: float, intensity: float, alive_enemy_count: int,
		_horde_active: bool = false, engaged: bool = false) -> void:
	if paused or not enabled:
		return

	phase_elapsed += delta
	var should_transition: bool = false

	## 重新武装：强度掉回阈值 80% 以下才算"这一波真的过去了"。
	if not _peak_armed and intensity < peak_intensity_threshold * 0.8:
		_peak_armed = true

	match current_phase:
		Phase.BUILD:
			## ★2026-10-30 用户定稿：智能尸潮 = 双触发，任一满足即开：
			##   ① 无交战计时达到阈值（可提前，保留「安静久了来一波」的节奏感）；
			##   ② BUILD 时长走完（时间硬上限，兜底，不会因为一直交战而无限不来）。
			## 两个计时都只在 BUILD 段累计；进 PEAK / FADE / COOLDOWN 一律清零，
			## 下一次 BUILD 从 0 开始 —— 用户要求「尸潮结束后从头算起」。
			if engaged:
				_quiet_sec = 0.0
			else:
				_quiet_sec += delta
			var time_up: bool = phase_elapsed >= phase_duration
			var quiet_up: bool = smart_horde and _quiet_sec >= smart_threshold()
			if time_up or quiet_up:
				should_transition = true
				if time_up:
					print("[Pacing] 触发尸潮：BUILD 时间上限 %.0fs 到" % phase_duration)
				else:
					print("[Pacing] 触发尸潮：连续无交战 %.0fs ≥ 阈值 %.0fs"
						% [_quiet_sec, smart_threshold()])
			elif not smart_horde and intensity > peak_intensity_threshold and _peak_armed \
					and phase_elapsed >= phase_duration * peak_trigger_after_ratio:
				## 旧模型的强度触发：只在 BUILD 后段生效；智能尸潮开启时不参与，
				## 否则双触发之外又多出第三个触发源，节奏会被战斗拖着走。
				should_transition = true

		Phase.PEAK:
			## ★2026-10-29 用户定稿：峰值**按时间结束**，不再看场上是否清空。
			## 旧语义（"清空才进余韵"）等于用**击杀速度**当结束条件：玩家越猛尸潮越短、
			## 下一波越早，节奏完全被击杀速度带走。现在 peak 时长 = phase_duration
			## （peak_timeout，按难度/配置），到点就收尾；残兵交给 FADE 段等它清完
			##（旧模型没有 FADE，直接进喘息）。尸潮窗口内的补怪由 SpawnManager 负责。
			if phase_elapsed >= phase_duration:
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


## ── 智能尸潮：击杀喂入 / 阈值查询（2026-10-29）──
## Director 每 0.5s 把「本章新增击杀」喂进来（来源 ChapterStats.get_totals().kills）。
func note_kills(count: int) -> void:
	_horde_kills += maxi(count, 0)


## 当前需要的「无交战秒数」。杀得越多越久，夹在 [min, max] 里。
func smart_threshold() -> float:
	return clampf(smart_base_sec + float(_horde_kills) * smart_per_kill_sec,
			smart_min_sec, smart_max_sec)


## 诊断用：当前累计击杀 / 已安静多久。
func smart_debug() -> Dictionary:
	return {
		"kills": _horde_kills,
		"quiet": _quiet_sec,
		"threshold": smart_threshold(),
	}


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
	## ★2026-10-30：任何阶段切换都清零「无交战」计时 —— 尸潮结束（进 FADE/COOLDOWN）
	## 后必须从头算起；`phase_elapsed` 本身每阶段归零，时间硬上限同样不会跨尸潮累积。
	_quiet_sec = 0.0
	## 进峰值即"解除武装"：下一次强度触发必须先让强度掉回阈值 80% 以下。
	if new_phase == Phase.PEAK:
		_peak_armed = false
	phase_duration = _rand_duration(new_phase)

	var phase_name: StringName = _phase_name(new_phase)
	if new_phase == Phase.BUILD and smart_horde:
		print("[Pacing] → build（智能尸潮：无交战 %.0fs 或时间上限 %.0fs，任一满足；本章击杀 %d）"
			% [smart_threshold(), phase_duration, _horde_kills])
	else:
		print("[Pacing] → %s (duration=%.1fs)" % [phase_name, phase_duration])
	phase_changed.emit(phase_name)


func _rand_duration(phase: Phase) -> float:
	var base_min: float
	var base_max: float
	match phase:
		Phase.BUILD:     base_min = build_min; base_max = build_max
		Phase.PEAK:      return maxf(peak_timeout, peak_sustain)
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
