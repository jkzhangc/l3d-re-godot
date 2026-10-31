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

# ── 智能尸潮（2026-10-31 重做：击杀驱动的压力表）──
## BUILD 段累计一个「压力进度」（单位=秒），填满即开尸潮。三个来源：
##   ① 基线：每帧 +delta（无论打不打都在涨）→ 纯时间节奏；
##   ② 击杀：每杀 +`smart_per_kill_sec` 秒 → **杀得越多越容易触发**（2026-10-31 用户定）；
##   ③ 安静：无交战时填充倍率 ×`smart_idle_mult`（躲着不打也会被摸上门）。
## 目标时长 = 本段 BUILD 的 `phase_duration`（由难度间隔表反推，见 Director._apply_config）。
## 只统计 **BUILD 段**的击杀 —— 峰值/余韵/喘息里的击杀属于这一波本身，不能直接喂下一波。
## 关掉 = 回到「难度间隔表」的纯定时节奏（强度只在后段可提前）。
@export var smart_horde: bool = false
## 每击杀相当于「提前多少秒」。2.0 = 30 杀提前 1 分钟。设 0 = 击杀不参与（纯时间）。
@export var smart_per_kill_sec: float = 2.0
## 无交战时的进度填充倍率（1.5 = 安静时比交战快 50%）。设 1.0 = 交战与否等价。
@export var smart_idle_mult: float = 1.5
## 本段 BUILD 的**最短时长**（秒）：尸潮不会早于它触发，充当两波之间的硬间隔。
@export var smart_min_sec: float = 30.0
## ★两波尸潮之间的**硬间隔**（秒，从上一波 PEAK **开始**算）。0 = 不设闸。
## 这是一道与阶段无关的兜底闸：即使 `force_build()` 把阶段强推回 BUILD、
## 或击杀把压力条瞬间灌满，也不会出现「刚结束又立刻来一波」。
## 实际最小间隔 = max(本值, 峰值时长 + 余韵 + 喘息 + `smart_min_sec`)。
@export var smart_gap_sec: float = 90.0
## [已停用] 旧「0 杀无交战阈值」。2026-10-31 起目标时长由难度间隔表反推，本值不再读取。
@export var smart_base_sec: float = 120.0
## [已停用] 旧「阈值上限」。同上，不再读取。
@export var smart_max_sec: float = 360.0

## 本章累计击杀（Director 每 0.5s 从 ChapterStats 喂进来；仅用于诊断展示）
var _horde_kills: int = 0
## 本段 BUILD 已累积的压力进度（秒）。进 BUILD 时清零。
var _progress_sec: float = 0.0
## 本图第几段 BUILD（0 = 开场第一段，用于「首波时长单独给」）。
var build_index: int = 0
## 首波 BUILD 时长区间（秒），由 Director 用「间隔 × first_scale − overhead」算好注入。
## `first_build_max <= 0` = 未配置，退回 build_min/max。
var first_build_min: float = 0.0
var first_build_max: float = 0.0
## 距上一次 PEAK **开始**的秒数：`smart_gap_sec` 硬间隔闸用。
## 换图时置大值，避免「上一张图的尸潮」把新图首波也压住。
var _since_peak_sec: float = 1.0e9

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
## `engaged`：当前是否有敌人在交战（Director 每帧传入 `IntensityTracker.in_combat`）。
## FADE 段必须等到「无交战」才算自然收尾；BUILD 段则用它决定是否套用
## `smart_idle_mult`（安静加速）。
func update(delta: float, intensity: float, alive_enemy_count: int,
		_horde_active: bool = false, engaged: bool = false) -> void:
	if paused or not enabled:
		return

	phase_elapsed += delta
	## 记录「距上一波 PEAK 开始」的时长：`smart_gap_sec` 硬间隔闸的唯一依据。
	_since_peak_sec += delta
	var should_transition: bool = false

	## 重新武装：强度掉回阈值 80% 以下才算"这一波真的过去了"。
	if not _peak_armed and intensity < peak_intensity_threshold * 0.8:
		_peak_armed = true

	match current_phase:
		Phase.BUILD:
			## ★2026-10-31 用户定稿：智能尸潮 = **击杀驱动的压力表**。
			## 旧实现（2026-10-30 双触发）有两个问题：
			##   ① 阈值 = base + 击杀×2 —— 杀得越多**越晚**来，与用户要的正好相反；
			##   ② 「连续无交战 120s」在实战里几乎攒不起来（in_combat 是「任一玩家 500px
			##      内有敌人」，路上一直有游荡者），实际只剩时间上限一条路 → 短图一波都没有。
			## 现在：进度条基线随 `delta` 涨，击杀直接加秒数，安静再乘倍率，任一条都能推满。
			## 目标时长 `phase_duration` 由难度间隔表反推（Director._apply_config），
			## 所以「难度改变时间」仍然成立，只是击杀会让它提前。
			if smart_horde:
				var idle_mult: float = maxf(smart_idle_mult, 0.0) if not engaged else 1.0
				_progress_sec += delta * idle_mult
				var target: float = phase_duration
				## 两道闸叠加：①本段 BUILD 至少走 `smart_min_sec`；②距上一波开始至少 `smart_gap_sec`。
				## ②是 2026-10-31 新加的「防突然再来一次」兜底 —— 它与 FADE/COOLDOWN 的长度、
				## 以及 `force_build()` 强推阶段都无关，只认「上一波什么时候开始的」。
				var gap_ok: bool = smart_gap_sec <= 0.0 or _since_peak_sec >= smart_gap_sec
				if gap_ok and phase_elapsed >= smart_min_sec and _progress_sec >= target:
					should_transition = true
					print("[Pacing] 触发尸潮：压力 %.0f/%.0fs（本章击杀 %d，每杀 +%.1fs，安静×%.2f，距上一波 %.0fs）"
						% [_progress_sec, target, _horde_kills, smart_per_kill_sec,
							smart_idle_mult, _since_peak_sec])
			else:
				## 旧模型：时间硬上限，强度只在 BUILD 后段（`peak_trigger_after_ratio`）可提前。
				if phase_elapsed >= phase_duration:
					should_transition = true
					print("[Pacing] 触发尸潮：BUILD 时间上限 %.0fs 到" % phase_duration)
				elif intensity > peak_intensity_threshold and _peak_armed \
						and phase_elapsed >= phase_duration * peak_trigger_after_ratio:
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


## ── 智能尸潮：击杀喂入 / 进度查询（2026-10-31 压力表）──
## Director 每 0.5s 把「本章新增击杀」喂进来（来源 ChapterStats.get_totals().kills）。
## **只计入 BUILD 段**：峰值里杀的怪就是这一波本身，让它直接喂下一波会造成连环尸潮。
func note_kills(count: int) -> void:
	var n: int = maxi(count, 0)
	if n <= 0:
		return
	_horde_kills += n
	if not smart_horde or current_phase != Phase.BUILD:
		return
	if smart_per_kill_sec > 0.0:
		_progress_sec += float(n) * smart_per_kill_sec


## 本段 BUILD 的目标时长（秒）。非 BUILD 段返回 0。
func smart_target() -> float:
	return phase_duration if current_phase == Phase.BUILD else 0.0


## 诊断用：当前累计击杀 / 压力进度 / 目标时长 / 触发参数。
func smart_debug() -> Dictionary:
	return {
		"kills": _horde_kills,
		"progress": _progress_sec,
		"target": smart_target(),
		"per_kill_sec": smart_per_kill_sec,
		"idle_mult": smart_idle_mult,
		"build_index": build_index,
		"since_peak": _since_peak_sec if _since_peak_sec < 1.0e8 else -1.0,
		"gap": smart_gap_sec,
	}


## 换图 / 新局：重置压力表、首波计数与硬间隔计时。Director 在应用 DirectorConfig 时调用。
func reset_for_new_map() -> void:
	_horde_kills = 0
	_progress_sec = 0.0
	build_index = 0
	## 新图还没打过尸潮 —— 置大值让 `smart_gap_sec` 不拦首波。
	_since_peak_sec = 1.0e9


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
	## ★2026-10-31：压力进度随阶段切换清零 —— 一波结束后从 0 重新累积，
	## 不会把上一波之前攒的进度带过来（用户要求「尸潮结束后从头算起」）。
	_progress_sec = 0.0
	## 进峰值即"解除武装"：下一次强度触发必须先让强度掉回阈值 80% 以下。
	if new_phase == Phase.PEAK:
		_peak_armed = false
		## ★2026-10-31：硬间隔闸的计时从「尸潮开始」重新起算 —— 之后的
		## 余韵/喘息/加压不管多短，都不可能在下一次尸潮上「攒时间」。
		_since_peak_sec = 0.0
	phase_duration = _rand_duration(new_phase)
	if new_phase == Phase.BUILD:
		build_index += 1

	var phase_name: StringName = _phase_name(new_phase)
	if new_phase == Phase.BUILD and smart_horde:
		print("[Pacing] → build（智能尸潮：压力 0/%.0fs；每杀 +%.1fs，安静×%.2f；本章击杀 %d）"
			% [phase_duration, smart_per_kill_sec, smart_idle_mult, _horde_kills])
	else:
		print("[Pacing] → %s (duration=%.1fs)" % [phase_name, phase_duration])
	phase_changed.emit(phase_name)


func _rand_duration(phase: Phase) -> float:
	var base_min: float
	var base_max: float
	match phase:
		Phase.BUILD:
			## ★首波单独给时长（2026-10-31 用户实测「首波 35~59s 太早，普通要 2 分钟左右」）：
			## 区间由 Director 按「间隔 × smart_horde_first_scale − overhead」算好注入，
			## 对**间隔**打折而不是对 BUILD 打折 —— 否则峰值/余韵/喘息会被一起缩掉。
			if build_index == 0 and smart_horde and first_build_max > 0.0:
				base_min = first_build_min
				base_max = first_build_max
			else:
				base_min = build_min
				base_max = build_max
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
