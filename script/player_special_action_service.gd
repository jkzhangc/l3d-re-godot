extends RefCounted

## ── 架构定位 ──
## 系统：玩家特殊行动（SA / 见切 / 反击 / Heat / 削り / 覚醒 / 搓招）｜ 层：服务类（RefCounted，由 player 持有）
## 联机：Host 权威结算 + Client 表现（各接口见方法注释；双域 TP 独立推进）
## 职责：SA 技能效果（感覚向上/リサイタル/しゃがみ回避/バックパック）、しゃがみ持续与 TP 消耗、
##       Heat（计时/染色/禁止见切）、削り（弹药/耐久削减）、覚醒（集中射撃）、见切窗口与
##       反击（角色专属）、搓招缓冲，以及一整套联机 SA 表现接线。
## 依赖：player 实体（读/写 SA 运行时字段与外观状态；经 _p.* 访问节点）、Players、Global、SkillData 等
##
## 【为什么从 player.gd 抽出（2026-10-08）】本块约 665 行、41 个方法，是 player.gd 内聚度最高
## 也最独立的一块（特殊行动状态机 + 联机表现接线）。抽出后 player.gd 保留**同名转发门面**，
## 外部调用点（状态脚本、NetworkWorld、测试）零改动。
##
## 【状态变量为何留在 player】`_sa_crouch_active` / `_sa_crouch_until_msec` / `_sa_crouch_skill` /
## `_sa_crouch_drain_accum` / `_network_sa_crouch_hold` / `_sa_auto_mukiri_until_msec` /
## `_mukiri_window_until_msec` / `_mukiri_last_attempt_msec` / `_counter_cooldown_until_msec` /
## `_mukiri_anim_busy` / `_heat_time` / `_awaken_active` / `_awaken_tint_applied` /
## `_motion_buffer` / `network_swallow_locked` **全部保留在 player.gd**（network_swallow_locked
## 被 NetworkWorld 直读，部分字段供调试/测试观察）—— 只搬「逻辑」不搬「状态」。
## 本服务经 `_p.<字段名>` 直接读写（GDScript 下划线仅约定，跨对象可访问）。
##
## 【帧常量的真源】`AWAKEN_DAMAGE_MULT` 等常量在 player.gd 保留同名转发别名（外部状态脚本
## 经 `character.AWAKEN_DAMAGE_MULT` 访问），真源在本文件。

## 见切判定窗口（原作 0.3 秒，"大甘"）
const MUKIRI_WINDOW_MS: int = 300
## 两次见切输入的最小间隔（原作 0.7 秒）
const MUKIRI_INTERVAL_MS: int = 700
## 反击触发冷却，防一次窗口内重复触发
const COUNTER_COOLDOWN_MS: int = 1000

## Heat 持续秒数（原作未公开精确值，按体感）
const HEAT_DURATION: float = 6.0
## 削り：弹夹每次 -2
const ATTRITION_AMMO: int = 2
## 削り：耐久每次 -8
const ATTRITION_DURABILITY: float = 8.0

## 覚醒：发动中 TP 缓慢消耗（原作「徐々にTPを消費」）
const AWAKEN_TP_DRAIN_PER_SEC: float = 5.0
## 覚醒：射撃威力上升倍率
const AWAKEN_DAMAGE_MULT: float = 1.5
## 覚醒：即死对 Boss 无效 → 改为伤害 ×1.5（原作必殺对 Boss 同规则）
const AWAKEN_BOSS_DAMAGE_MULT: float = 1.5
## 覚醒：怯み时长（Boss 吃怯み不吃即死）
const AWAKEN_HITSTUN_SEC: float = 0.8

## 搓招方向输入缓冲
const MOTION_DIRS: Array[String] = ["上", "下", "左", "右"]
const MOTION_BUFFER_MAX: int = 8

## 成就系统入口（**preload 常量而不是 class_name**：本项目 class_name 不进全局类缓存，
## 跨文件按名字引用会在 headless / 导出时报 Parse Error —— 见 MEMORY「class_name 不跨文件」）。
const ACHIEVEMENTS := preload("res://script/achievements.gd")
## 精灵帧常量真源（见切动画切帧用；player.gd 的 FRAME_W 等是它的转发别名）。
const Sprite := preload("res://script/player_sprite_renderer.gd")

## 宿主 player 实体。
var _p: Node = null


func _init(player: Node) -> void:
	_p = player


# ═══════════════════════════════════════
# SA 技能入口 / 搓招校验
# ═══════════════════════════════════════

func use_skill(trigger: String = "") -> void:
	if not _p.current_character:
		return
	var skills: Array[SkillData] = _p.current_character.skills
	if skills.is_empty():
		print("[技能] 当前角色没有技能")
		return
	var skill: SkillData = _find_skill_by_trigger(skills, trigger)
	if not skill:
		print("[技能] 没有绑定触发键 %s 的技能" % trigger)
		return
	_use_skill_core(trigger, _match_motion(skill.command_motion))


## 释放技能核心（C2 拆分：无 Input / 搓招缓冲读取，联机下 Host 替 Client 玩家
## 结算经此入口）。motion_ok 由调用方预校验——搓招缓冲只存在于输入方本机，
## Host 无法重放输入序列，请求协议信任 Client 的本地预校验（与射击瞄准同类
## 的意图信任）；单机入口传 _match_motion 实测结果，行为不变。
## TP 走 PlayerState 权威值（Host 上 get_state_for_entity 对权威实体返回权威域）。
## 返回是否成功释放（校验失败逐项早退）。
func _use_skill_core(trigger: String, motion_ok: bool) -> bool:
	if not _p.current_character:
		return false
	var skill: SkillData = _find_skill_by_trigger(_p.current_character.skills, trigger)
	if not skill:
		print("[技能] 没有绑定触发键 %s 的技能" % trigger)
		return false
	if not motion_ok:
		print("[技能] 搓招失败：%s 需要方向指令 [%s]" % [skill.skill_name, skill.command_motion])
		return false
	var state: PlayerState = Players.get_state_for_entity(_p)
	if not state:
		return false
	if skill.tp_cost > 0 and state.current_tp < skill.tp_cost:
		print("[技能] TP 不足: 需要 %d, 当前 %d" % [skill.tp_cost, state.current_tp])
		return false
	## ★唯一写入口（2026-10-03）：钳到 [0, 上限]，不再裸减。
	##   上限判据用 `get_max_tp()`（= CharacterData.max_tp，现四人皆 100）——
	##   越界曾导致 HUD 显示出「133」这类超过上限的数字。
	state.change_tp(-skill.tp_cost)
	print("[技能] 释放 %s | 消耗 TP %d | 剩余 %d" % [skill.skill_name, skill.tp_cost, state.current_tp])
	_execute_skill_effect(skill, trigger)
	return true


# ═══════════════════════════════════════
# SA 技能效果（说明书 §6.2：SA = 每角色一个专属主动技）
# ═══════════════════════════════════════

## 按 skill_type 分派实际效果。
func _execute_skill_effect(skill: SkillData, trigger: String = "") -> void:
	if skill.sa_sound:
		var scene: Node = _p.get_tree().current_scene if _p.get_tree() else null
		Global.play_sfx_managed(skill.sa_sound, scene)
	match skill.skill_type:
		SkillData.SkillType.SA_SEEKER:
			# のび太「感覚向上」：持续时间内敌方攻击完全见切（无伤）
			_p._sa_auto_mukiri_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
			print("[SA] 感覚向上：%.0f 秒内完全见切（敌方攻击无效化）" % skill.duration)
		SkillData.SkillType.SA_RECITAL:
			# ジャイアン「ジャイアンリサイタル」：半径内全体敌人踉跄（0 伤害 + 硬直）
			var staggered: int = _sa_recital_stagger(skill.radius, skill.stagger_duration)
			print("[SA] ジャイアンリサイタル：%.0fpx 内 %d 个敌人踉跄 %.1fs" % [skill.radius, staggered, skill.stagger_duration])
		SkillData.SkillType.SA_CROUCH:
			# 静香「しゃがみ回避」：基础无敌 duration 秒；按住 SA 键持续蹲（急速耗 TP）
			_start_crouch_dodge(skill)
		SkillData.SkillType.SA_BACKPACK:
			# スネ夫「バックパック」：背包系统未实装，占位
			print("[SA] バックパック：背包系统未实装（占位）")
		_:
			print("[技能] %s：无绑定效果（GENERIC 占位）" % skill.skill_name)
	# 联机（C2）：Host 侧结算完成后广播表现（Client 解析本地同名技能：
	# 播 sa_sound / 蹲下染色与计时 / 感覚向上计时；RECITAL 的敌人踉跄由 Host
	# 结算经快照体现，不在此复现）。单机 / Client 端为 no-op。
	_announce_network_sa_event("sa:" + (trigger if not trigger.is_empty() else skill.command_trigger))


## リサイタル：半径内所有存活敌人进入踉跄（0 伤害 → 不弹数字；hitstun → 原地冻结）
func _sa_recital_stagger(radius: float, stagger: float) -> int:
	var count: int = 0
	for e: Node2D in _p.get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		if e.global_position.distance_to(_p.global_position) > radius:
			continue
		if e.has_method("take_damage"):
			e.take_damage(0.0, 0.0, (e.global_position - _p.global_position).normalized(), false, 0.0, stagger)
			count += 1
	return count


## しゃがみ回避：进入蹲下无敌；每帧由 _update_sa_state 维持/结束。
func _start_crouch_dodge(skill: SkillData) -> void:
	_p._sa_crouch_skill = skill
	_p._sa_crouch_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
	_p._sa_crouch_active = true
	_p._sa_crouch_drain_accum = 0.0  # 每次进入蹲下都从 0 起算（不留上次的余量）
	if _p.sprite:
		_p.sprite.modulate = Color(0.75, 0.85, 1.0)  # 蹲下（无敌）的视觉提示
	print("[SA] しゃがみ回避：无敌 %.1f 秒（按住 SA 键持续蹲，每秒耗 %.0f TP）" % [skill.duration, skill.crouch_tp_drain])


func _end_crouch_dodge() -> void:
	_p._sa_crouch_active = false
	_p._sa_crouch_skill = null
	_p._sa_crouch_drain_accum = 0.0
	_p._network_sa_crouch_hold = false  # Host 权威实体的按住登记随蹲下结束一并清除
	if _p.sprite:
		_p.sprite.modulate = Color.WHITE
	print("[SA] しゃがみ回避结束")
	# 联机（C2）：Host 侧结束（超时/TP 尽/死亡）广播对齐表现；Client 本地结束
	# 与 crouch_end_presentation 幂等（LAN 漂移 <1s）；单机 no-op。
	_announce_network_sa_event("crouch_end")


## しゃがみ按住每帧扣 TP —— **按秒计价、与帧率无关**。
##
## ★2026-10-04 修复（用户报「TP 到不了 0 / 静香技能一直能用」时一并查出的真实缺陷）：
## 旧实现是
##     `var drain := maxi(1, int(round(crouch_tp_drain * delta)))` → `change_tp(-drain)`
## 两个毛病：
##   ① `maxi(1, …)` 让**每帧至少扣 1 点** → 实际速率 = **帧率**（60fps 时 60 TP/s，
##      是 `crouch_tp_drain = 15` 设计值的 4 倍；144fps 更离谱，且低帧率时反而变慢 ——
##      「耗蓝速度取决于电脑性能」本身就是 bug）；
##   ② `round()` 把不足 1 点的零头直接抹掉，无法表达"每秒 15"这种非整数/帧的量。
## 现在改用**小数累加器**：不足 1 点的部分留到下一帧，长期平均速率恒等于
## `crouch_tp_drain` 点/秒（15 TP/s → 满蓝 100 可按住约 6.6 秒）。
func _drain_crouch_tp(delta: float) -> void:
	if _p._sa_crouch_skill == null:
		return
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state == null or state.current_tp <= 0:
		return
	_p._sa_crouch_drain_accum += _p._sa_crouch_skill.crouch_tp_drain * delta
	var whole: int = int(_p._sa_crouch_drain_accum)
	if whole <= 0:
		return  ## 攒着，下一帧一起扣（避免"每帧至少 1"的帧率依赖）
	_p._sa_crouch_drain_accum -= float(whole)
	state.change_tp(-whole)


## 本机（**本地显示域**）释放该技能要花的 TP；没有该技能 / 不耗 TP 时返回 0。
## 联机 Client 的"能不能放"预校验用（与 Host 权威校验同一份 SkillData，两端同值）。
func local_skill_tp_cost(trigger: String) -> int:
	if not _p.current_character:
		return 0
	var skill: SkillData = _find_skill_by_trigger(_p.current_character.skills, trigger)
	return skill.tp_cost if skill else 0


## 联机 Client：把本次**已确认生效**的技能 TP 从本地显示域扣掉。
##
## ★为什么需要（2026-10-04 用户报「点按静香技能会一直能用 / TP 到不了 0」的联机根因）：
## 联机下技能由 Host 结算，TP 也从 **Host 权威域**扣；而 Client 的 HUD 读的是
## **本地显示域**（双域设计，见 `_update_network_sa_state` 注释）。旧实现里 Client 侧
## **没有任何一处**为"释放技能"扣本地 TP（表现接口只播音效/染色，按住消耗又要求
## 一直按住键）→ 点按（tap）时本地 TP 一点不掉 → 玩家看到「TP 一直满、技能一直能用」。
## 现在：Host 确认后广播 `sa_presentation`，Client 在**同一次事件**上镜像扣一次
## （各域各扣一次，与覚醒 TP 的"双域独立推进"口径一致），并由 `local_skill_tp_cost`
## 在本机做发送前预校验，避免 TP 空转刷请求。
func pay_local_sa_tp(trigger: String) -> void:
	var cost: int = local_skill_tp_cost(trigger)
	if cost <= 0:
		return
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state == null:
		return
	state.change_tp(-cost)
	print("[SA] 本地 TP 同步扣除: -%d | 剩余 %d" % [cost, state.current_tp])


# ═══════════════════════════════════════
# Heat / 削り（原作说明书 §4.6）
# ═══════════════════════════════════════

## Heat 状态：禁止切人、禁止见切（反击无效）、TP 停止回复、Guts 停止。
func _apply_heat() -> void:
	var was_active: bool = _p._heat_time > 0.0
	_p._heat_time = HEAT_DURATION  # 刷新与首次置位统一（联机表现同语义）
	if not was_active and _p.sprite:
		_p.sprite.modulate = Color(1.8, 0.6, 0.6)
	# 联机（C2）：Heat 染色 + 本地计时广播（否则 Client 不知道自己处于 Heat，
	# 会误解见切失效的反馈）；单机 / Client 端 no-op。
	_announce_network_sa_event("heat")
	if not was_active:
		print("[状态] Heat！%.0f 秒内禁止见切/反击、TP 停止回复、Guts 停止" % HEAT_DURATION)


func is_heat_active() -> bool:
	return _p._heat_time > 0.0


# ═══════════════════════════════════════
# 覚醒コマンド（原作：構え中 Z+X；のび太=「集中射撃」）
# ═══════════════════════════════════════

## 尝试发动觉醒。成功返回 true。
## 原作（player.html のび太）：「構え中Z+Xで発動。発動中は徐々にTPを消費するが、
## 射撃攻撃の威力が上昇し、ハンドガン・マグナムの攻撃に即死・怯み効果が付与される。」
## 本工程触发 = 构势（举枪 READY）中按**空格（覚醒键）**（2026-09-13 用户改版：
## 组合键按住Z+按X 容易被攻击状态转移吞输入 → 改专用键，空格已从确定键摘除）。
## 覚醒键按下是本函数内的硬条件（单一判据，调用点不用各自判输入）。
func try_activate_awaken() -> bool:
	if _p._awaken_active or _p._is_dying:
		return false
	if not Input.is_action_pressed("覚醒键"):
		return false
	return _activate_awaken_core()


## 覚醒发动核心（无 Input 读取）：联机下 Host 替 Client 玩家结算时经此入口
## （Host 上读不到 Client 键盘，输入判定由 Client 的 awaken_request 上报替代）。
## 校验 awaken_type + TP（PlayerState 权威值），成功后置 _awaken_active + 金色染色。
func _activate_awaken_core() -> bool:
	if _p._awaken_active or _p._is_dying:
		return false
	if _p.current_character == null or _p.current_character.awaken_type == "none":
		return false
	var state: PlayerState = Players.get_state_for_entity(_p)
	if state == null or state.current_tp <= 0:
		print("[覚醒] TP 不足，无法发动")
		return false
	_p._awaken_active = true
	if _p.sprite:
		_p.sprite.modulate = Color(1.9, 1.7, 0.9)
		_p._awaken_tint_applied = true
	print("[覚醒] 集中射撃発動！TP 每秒 -%d、射撃威力 ×%.1f、即死・怯み（Boss 免疫即死）" % [
		int(AWAKEN_TP_DRAIN_PER_SEC), AWAKEN_DAMAGE_MULT])
	return true


func is_awaken_active() -> bool:
	return _p._awaken_active


## 覚醒（集中射撃）射撃威力倍率。暴露成方法是因为联机 Host 侧持有的 shooter 变量
## 静态类型为 CharacterBody2D，读不到本脚本的 const（2026-09-24：Host 权威弹补上
## 覚醒伤害倍率时使用，避免在 network_world 里再写一份硬编码常量）。
func get_awaken_damage_mult() -> float:
	return AWAKEN_DAMAGE_MULT


## 每帧：发动中 TP 缓慢消耗；TP 耗尽 / 死亡 / 切人 → 解除。
func _update_awaken(delta: float) -> void:
	if not _p._awaken_active:
		return
	var state: PlayerState = Players.get_state_for_entity(_p)
	var tp_left: int = state.current_tp if state else 0
	if state:
		## ★唯一写入口：钳到 [0, 上限]（旧实现裸减只有 0 下限、没有上限）
		state.change_tp(-int(round(AWAKEN_TP_DRAIN_PER_SEC * delta)))
		tp_left = state.current_tp
	if tp_left <= 0 or _p._is_dying:
		_deactivate_awaken()
		if tp_left <= 0:
			print("[覚醒] TP 耗尽，集中射撃解除")


## 公开包装：供**武器状态**在"玩家主动放下武器"时调用（见 `PlayerPistolState._begin_lower`）。
## 内部 `_deactivate_awaken()` 仍供 TP 耗尽 / 死亡等内部路径使用。
## ★为什么要一个公开入口：放下武器解除覚醒是"动作驱动"的（玩家按了放下键），
##   不能挂在 `exit_weapon_mode()` 上（那个函数被状态切换复用 → 开枪也会解）。
func deactivate_awaken() -> void:
	_deactivate_awaken()


func _deactivate_awaken() -> void:
	if not _p._awaken_active:
		return
	_p._awaken_active = false
	# 还原染色：Heat 的红色染色优先（两者可能并存）
	if _p.sprite and _p._awaken_tint_applied:
		_p.sprite.modulate = Color(1.8, 0.6, 0.6) if is_heat_active() else Color.WHITE
		_p._awaken_tint_applied = false
	# 联机（C1）：Host 权威实体上任何解除路径（TP 耗尽/死亡/放下武器）统一出口广播；
	# 单机/Client 端 find_child 找不到 NetworkWorld → no-op。
	var tree: SceneTree = _p.get_tree()
	if tree:
		var scene := tree.current_scene
		if scene:
			var world: Node = scene.find_child("NetworkWorld", true, false)
			if world and world.has_method("announce_player_awaken"):
				world.call("announce_player_awaken", _p, false)


## 联机表现接口（C1，由 NetworkWorld 的 awaken_presentation 调用）：
## 置 _awaken_active + 染色还原——发起者本人的 Client 也经此获得即时染色，
## 其余 Client 的远端玩家同款；后续 TP 扣费由本实体 _process 的
## network_controlled 分支内 _update_awaken 各自域独立推进（同速同规则）。
func apply_network_awaken_state(active: bool) -> void:
	if active:
		if _p._awaken_active:
			return
		if _p.current_character == null or _p.current_character.awaken_type == "none":
			return
		_p._awaken_active = true
		if _p.sprite:
			_p.sprite.modulate = Color(1.9, 1.7, 0.9)
			_p._awaken_tint_applied = true
		print("[覚醒] 联机染色 ON（peer 表现）")
	else:
		if not _p._awaken_active:
			return
		_p._awaken_active = false
		if _p.sprite and _p._awaken_tint_applied:
			_p.sprite.modulate = Color(1.8, 0.6, 0.6) if is_heat_active() else Color.WHITE
			_p._awaken_tint_applied = false
		print("[覚醒] 联机染色 OFF（peer 表现）")


## 削り：削减装备中武器的弹药/耐久。
## 远程=弹夹 -ATTRITION_AMMO；近战=耐久 -ATTRITION_DURABILITY（max_durability>0 才有耐久，
## 原作"无限耐久武器免疫削り"）。耐久归零 → 武器损坏（卸下）。
func _apply_attrition() -> void:
	var state: PlayerState = Players.get_state_for_entity(_p)
	if not state:
		return
	var wd: WeaponData = state.get_active_weapon()
	if not wd:
		return
	if wd.is_ranged and wd.magazine_capacity > 0:
		var before: int = state.get_magazine_ammo(wd.item_id)
		if before <= 0:
			return
		var after: int = maxi(0, before - ATTRITION_AMMO)
		state.set_magazine_ammo(wd.item_id, after)
		print("[削り] %s 弹夹 %d → %d" % [wd.item_name, before, after])
	elif wd.max_durability > 0.0:
		var before_d: float = state.get_weapon_durability(wd.item_id, wd.max_durability)
		var after_d: float = maxf(0.0, before_d - ATTRITION_DURABILITY)
		state.set_weapon_durability(wd.item_id, after_d)
		print("[削り] %s 耐久 %.0f → %.0f" % [wd.item_name, before_d, after_d])
		if after_d <= 0.0:
			state.unequip_slot(state.active_weapon_slot)
			_p._weapon_mode = false
			_p.player_in_weapon_state = false
			_p._refresh_sprite()
			print("[削り] %s 耐久耗尽，武器损坏！" % wd.item_name)


## SA 状态每帧维护：发动输入、しゃがみ持续（按住延长 + TP 消耗）、超时结束。
## 仅本地权威实体调用（network_controlled 分支在 _process 里提前 return）。
func _update_sa_state(delta: float) -> void:
	if _p._is_dying:
		if _p._sa_crouch_active:
			_end_crouch_dodge()
		return
	# 覚醒（集中射撃）：发动中 TP 缓慢消耗，耗尽/死亡自动解除
	_update_awaken(delta)
	# Heat 状态计时与褪色（Heat 中禁止见切/反击、TP 停、Guts 停）
	if _p._heat_time > 0.0:
		_p._heat_time -= delta
		if _p._heat_time <= 0.0 and _p.sprite and not _p._sa_crouch_active:
			_p.sprite.modulate = Color.WHITE
			print("[状态] Heat 解除")
	# SA 发动键（原作 X 键；本工程菜单在 P/Esc，X 无冲突，绑在 project.godot 的「SA键」）
	if Input.is_action_just_pressed("SA键"):
		use_skill("SA键")
	# 见切输入（原作 Z=攻击兼见切；「确定键」按下即登记 0.3s 判定窗口）
	if Input.is_action_just_pressed("确定键"):
		_try_mukiri_input()
	# しゃがみ持续：超时结束；按住 SA 键且 TP 未耗尽 → 延长并扣 TP
	var now: int = Time.get_ticks_msec()
	if _p._sa_crouch_active:
		if now >= _p._sa_crouch_until_msec:
			_end_crouch_dodge()
		elif Input.is_action_pressed("SA键") and _p._sa_crouch_skill:
			var state: PlayerState = Players.get_state_for_entity(_p)
			if state and state.current_tp > 0:
				_p._sa_crouch_until_msec = now + int(_p._sa_crouch_skill.duration * 1000.0)
				_drain_crouch_tp(delta)


## 敌方攻击是否被无效化（しゃがみ无敌 / 感覚向上完全见切 / 见切输入窗口）。
## 见切成功时对实际伤害（>0）触发反击。
func _should_negate_hit(damage: float) -> bool:
	var now: int = Time.get_ticks_msec()
	# しゃがみ回避（无敌）
	if _p._sa_crouch_active or now < _p._sa_crouch_until_msec:
		_p._play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[SA] しゃがみ回避：攻击无效化")
		return true
	# 感覚向上（完全见切 → 自动反击，即原作"见切是反击的触发器"）；Heat 中禁止见切
	if now < _p._sa_auto_mukiri_until_msec and not is_heat_active():
		_p._play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[SA] 感覚向上：见切成功（无伤）")
		if damage > 0.0:
			_try_counter()
		return true
	# 见切输入窗口（0.3s；原作 Z 键攻击兼见切）；Heat 中禁止见切
	if now < _p._mukiri_window_until_msec and not is_heat_active():
		_p._mukiri_window_until_msec = 0
		_p._play_hit_feedback(Color(2.0, 2.0, 2.0, 1.0), 0.08)
		print("[见切] 成功（无伤）")
		_play_mukiri_anim()
		# 联机（C2）：见切成功动画广播（Client 远端玩家播同款见切行走图序列）。
		_announce_network_sa_event("mukiri")
		if damage > 0.0:
			_try_counter()
		return true
	return false


## 见切成功动画：切换到见切行走图并按角色索引序列播放（配置方式同举枪动画）。
## 素材 = CharacterData.mukiri_walk_texture（空则回退推击图/反撃套）。
func _play_mukiri_anim() -> void:
	if _p._mukiri_anim_busy or _p._is_dying or _p.sprite == null:
		return
	var tex: Texture2D = null
	var seq: Array[int] = []
	var durations: Array[float] = []
	if _p.current_character:
		tex = _p.current_character.mukiri_walk_texture
		if not tex:
			tex = _p.current_character.shove_walk_texture
		seq = _p.current_character.mukiri_char_sequence
		durations = _p.current_character.mukiri_frame_durations
	if not tex or seq.is_empty():
		return
	_p._mukiri_anim_busy = true
	for i: int in seq.size():
		var char_idx: int = seq[i]
		var char_col: int = char_idx % Sprite.CHARS_PER_ROW
		var char_row: int = char_idx / Sprite.CHARS_PER_ROW
		var dir_row: int = Sprite.DIR_ROWS[_p._facing]
		_p.sprite.texture = tex
		_p.sprite.region_enabled = true
		_p.sprite.region_rect = Rect2(
			char_col * (Sprite.FRAME_W * 3) + Sprite.STAND_FRAME * Sprite.FRAME_W,
			char_row * (Sprite.FRAME_H * Sprite.DIRECTIONS) + dir_row * Sprite.FRAME_H,
			Sprite.FRAME_W, Sprite.FRAME_H)
		var fd: float = durations[i] if i < durations.size() else 0.08
		var tree := _p.get_tree()
		if not tree:
			return
		await tree.create_timer(fd).timeout
		if not _p.is_inside_tree():
			return
	_p._mukiri_anim_busy = false
	_p._refresh_sprite()


## 见切输入：按「确定键」即登记 0.3s 判定窗口（与攻击共用一键，同原作）。
## Heat 中见切使用不可（原作 system.html ◆ヒート：「見切り使用不可(カウンター不可)」）——
## 输入直接吞掉并给反馈，不再登记无效窗口（无效化判定侧本就有 is_heat_active 门）。
func _try_mukiri_input() -> void:
	var now: int = Time.get_ticks_msec()
	if is_heat_active():
		if now - _p._mukiri_last_attempt_msec >= MUKIRI_INTERVAL_MS:
			_p._mukiri_last_attempt_msec = now
			print("[状态] Heat 中见切使用不可！")
		return
	if now - _p._mukiri_last_attempt_msec < MUKIRI_INTERVAL_MS:
		return
	_p._mukiri_last_attempt_msec = now
	_p._mukiri_window_until_msec = now + MUKIRI_WINDOW_MS


# ═══════════════════════════════════════
# 反击（说明书 §4.3/§6.2：见切成功后触发，类型=角色专属）
# ═══════════════════════════════════════

## 见切成功 → 前方 ±60°、88px 扇形内敌人吃反击：
##   punch（拳打）= 2×攻击 + 推开；heavy（强打）= 3×攻击 + 大推；
##   issen（一闪）= 4×攻击 + 超Push + 即死（Boss 抗性系统未实装，当前对全部敌人生效）。
func _try_counter() -> void:
	var now: int = Time.get_ticks_msec()
	if now < _p._counter_cooldown_until_msec:
		return
	var ctype: String = _p.current_character.counter_type if _p.current_character else "none"
	if ctype == "none":
		return
	# 原作（system.html ◆カウンター）：反击只在**非架势**（未举枪）时触发；构势中见切只免伤
	if _p.player_in_weapon_state:
		print("[反击] 构势中不触发反击（原作：カウンター=構えていない時のみ）")
		return
	_p._counter_cooldown_until_msec = now + COUNTER_COOLDOWN_MS
	if _p.current_character.counter_sound:
		var scene: Node = _p.get_tree().current_scene if _p.get_tree() else null
		Global.play_sfx_managed(_p.current_character.counter_sound, scene)
	# 联机（C2）：反击音效广播（反击伤害/击退结算本就在 Host，Client 只需听声）。
	_announce_network_sa_event("counter")
	var facing: Vector2 = _p.get_facing_vector()
	var dmg_mult: float = 2.0
	var push_force: float = 320.0
	var push_stun: float = 0.4
	var instant_kill: bool = false
	match ctype:
		"punch":
			dmg_mult = 2.0; push_force = 320.0; push_stun = 0.4
		"heavy":
			dmg_mult = 3.0; push_force = 520.0; push_stun = 0.8
		"issen":
			dmg_mult = 4.0; push_force = 640.0; push_stun = 1.0; instant_kill = true
	var base: float = float(_p.current_character.get_effective_attack()) if _p.current_character else 10.0
	var hit_count: int = 0
	for e: Node2D in _p.get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(e) or e.get("_is_dead") == true or e.get("_is_dying") == true:
			continue
		var to_e: Vector2 = e.global_position - _p.global_position
		if to_e.length() > 88.0 or to_e.length() < 1.0:
			continue
		if to_e.normalized().dot(facing) < 0.5:
			continue
		if not e.has_method("take_damage"):
			continue
		var dmg: float = base * dmg_mult
		if instant_kill and e.get("current_hp") != null:
			dmg = maxf(dmg, float(e.get("current_hp")) + 1.0)
		e.take_damage(dmg, push_force, facing, false, push_stun, 0.0)
		hit_count += 1
	print("[反击] %s：命中 %d 个敌人（威力 x%.0f，推力 %.0f%s）" % [ctype, hit_count, dmg_mult, push_force, "，即死" if instant_kill else ""])
	## 成就「カウンター免許皆伝」：计发动次数（命中至少一个敌人才算一次有效反击）
	if hit_count > 0:
		var cst: PlayerState = Players.get_state_for_entity(_p)
		ACHIEVEMENTS.on_counter(cst.seat_index if cst else ACHIEVEMENTS.TEAM_SEAT)


# ═══════════════════════════════════════
# 联机 SA / 见切 / 反击接线（C2，由 NetworkWorld 调用 / network_controlled 分支驱动）
# ═══════════════════════════════════════

## network_controlled 实体的 SA 状态每帧维护（与单机 _update_sa_state 同规则同速度）：
##   - Host 权威实体：Heat 计时（take_damage→_apply_heat 真实置位，原实现无人推进
##     会让联机玩家 Heat 永不褪色）；しゃがみ按住延长读 sa_crouch_hold RPC 登记的
##     _network_sa_crouch_hold，扣权威 TP；
##   - Client 本地预测实体：Heat 计时（heat_presentation 本地置位）；しゃがみ按住
##     直读本机键盘，扣显示 TP（双域独立推进，同 C1 覚醒 TP 精度）；
##   - Client 远端玩家：仅 Heat 计时与蹲下超时（按住延长由 Host 权威侧结算，
##     结束经 crouch_end_presentation 对齐）。
## 超时/TP 尽各自结束：Host 侧结束经 _end_crouch_dodge 广播表现；Client 本地结束
## 与表现幂等；感覚向上/见切窗口是 msec 时间戳比较，无需每帧推进。
func _update_network_sa_state(delta: float) -> void:
	if _p._is_dying:
		if _p._sa_crouch_active:
			_end_crouch_dodge()
		return
	# Heat 状态计时与褪色（与单机 _update_sa_state 同条件：蹲下中不覆盖染色）
	if _p._heat_time > 0.0:
		_p._heat_time -= delta
		if _p._heat_time <= 0.0 and _p.sprite and not _p._sa_crouch_active:
			_p.sprite.modulate = Color.WHITE
			print("[状态] Heat 解除")
	var now: int = Time.get_ticks_msec()
	if _p._sa_crouch_active:
		if now >= _p._sa_crouch_until_msec:
			_end_crouch_dodge()
			return
		var hold: bool = _p._network_sa_crouch_hold
		if _p.network_local_prediction:
			hold = Input.is_action_pressed("SA键")  # Client 本地实体直读本机键盘
		if hold and _p._sa_crouch_skill:
			var state: PlayerState = Players.get_state_for_entity(_p)
			if state and state.current_tp > 0:
				_p._sa_crouch_until_msec = now + int(_p._sa_crouch_skill.duration * 1000.0)
				_drain_crouch_tp(delta)


## 联机表现接口（C2，由 NetworkWorld 的 sa_presentation 调用）：
## Client 按本地同名技能解析表现——sa_sound、しゃがみ染色/计时、感覚向上计时。
## RECITAL 的敌人踉跄 / BACKPACK 占位不在此复现（前者由 Host 结算经快照体现）。
## 技能解析走 _find_skill_by_trigger 同款回退（两端同一 CharacterData 资源，
## 结果一致），零资源传输。
func apply_network_sa_skill(trigger: String) -> void:
	if not _p.current_character:
		return
	var skill: SkillData = _find_skill_by_trigger(_p.current_character.skills, trigger)
	if not skill:
		return
	if skill.sa_sound:
		var scene: Node = _p.get_tree().current_scene if _p.get_tree() else null
		Global.play_sfx_managed(skill.sa_sound, scene)
	match skill.skill_type:
		SkillData.SkillType.SA_SEEKER:
			_p._sa_auto_mukiri_until_msec = Time.get_ticks_msec() + int(skill.duration * 1000.0)
		SkillData.SkillType.SA_CROUCH:
			_start_crouch_dodge(skill)
	print("[SA] 联机表现：%s（peer 表现）" % skill.skill_name)


## 联机表现接口（C2，crouch_end_presentation）：Host 权威侧蹲下结束的对齐信号，幂等
## （Client 本地同规则超时大概率已自行结束）。
func apply_network_crouch_end() -> void:
	if _p._sa_crouch_active:
		_end_crouch_dodge()


## 联机表现接口（C2，counter_presentation）：反击音效（伤害/击退结算在 Host，快照体现）。
func play_network_counter_presentation() -> void:
	if _p.current_character and _p.current_character.counter_sound:
		var scene: Node = _p.get_tree().current_scene if _p.get_tree() else null
		Global.play_sfx_managed(_p.current_character.counter_sound, scene)


## 联机表现接口（C2，heat_presentation）：Heat 染色 + 本地计时置位——
## _update_network_sa_state 推进计时并在到期褪色，与单机同规则。
func apply_network_heat_state() -> void:
	_p._heat_time = HEAT_DURATION
	if _p.sprite:
		_p.sprite.modulate = Color(1.8, 0.6, 0.6)


## 联机（C2）：Host 权威实体的しゃがみ按住登记（sa_crouch_hold RPC 写入）。
func set_network_crouch_hold(active: bool) -> void:
	_p._network_sa_crouch_hold = active


# ── 联机丸呑み表现（C3，由 NetworkWorld 的 swallow_presentation / Host 侧
#    EnemySwallowState._hide_victim/_restore_victim 调用）──

## 吞入/吐出表现：隐藏/恢复 + 碰撞闸（与 EnemySwallowState._hide_victim 同款）
## 并置 network_swallow_locked 锁。Host 权威实体被 _hide_victim 调用时同样生效
## （重复隐藏无害），关键是为 _simulate_host_players 提供冻结判据。
func apply_network_swallow_state(active: bool) -> void:
	if _p.network_swallow_locked == active:
		return
	_p.network_swallow_locked = active
	_p.visible = not active
	if active:
		_p.velocity = Vector2.ZERO
	for c: Node in _p.get_children():
		if c is CollisionShape2D or c is CollisionPolygon2D:
			(c as Node2D).set_deferred("disabled", active)
	print("[敵人] 联机丸呑み表现：%s（peer 表现）" % ("吞入隐藏" if active else "吐出恢复"))


## 联机（C2）：Client 本地实体按帧记录搓招缓冲——_update_motion_input 挂在
## _process 非联机分支，network_controlled 实体不会自行记录，由 NetworkWorld
## 的 _capture_sa_input 每帧代为驱动。
func poll_network_motion_input() -> void:
	_update_motion_input()


## 联机（C2）：SA 请求的搓招预校验（缓冲在本机，Host 无法重放输入序列——
## 请求协议信任 Client 预校验，Host 侧 motion_ok 恒 true）。
func validate_skill_motion(trigger: String) -> bool:
	if not _p.current_character:
		return false
	var skill: SkillData = _find_skill_by_trigger(_p.current_character.skills, trigger)
	if not skill:
		return false
	return _match_motion(skill.command_motion)


## 联机事件统一出口（C2）：Host 结算侧（技能释放/蹲下结束/见切成功/反击/Heat）
## 挂 call；单机（无 NetworkWorld 节点）与 Client 端（world 内 host 闸）均 no-op。
func _announce_network_sa_event(event: String) -> void:
	var tree := _p.get_tree()
	if not tree:
		return
	var scene := tree.current_scene
	if not scene:
		return
	var world: Node = scene.find_child("NetworkWorld", true, false)
	if world and world.has_method("announce_player_sa_event"):
		world.call("announce_player_sa_event", _p, event)


## 攻击后硬直是否跳过（说明书被动：コマンドー=机枪/散弹/马格南；かいりき=近战）。
func skip_post_attack(weapon_state_name: String) -> bool:
	if not _p.current_character:
		return false
	if _p.current_character.kairiki and weapon_state_name == "Knife":
		return true
	if _p.current_character.commando and weapon_state_name in ["Smg", "Shotgun", "Magnum"]:
		return true
	return false


## 按触发键查找技能（command_trigger 匹配；无匹配时回退到第一个未绑定触发键的技能）
func _find_skill_by_trigger(skills: Array[SkillData], trigger: String) -> SkillData:
	for s: SkillData in skills:
		if s.command_trigger == trigger:
			return s
	for s: SkillData in skills:
		if s.command_trigger.is_empty():
			return s
	return null


## 每帧记录方向键输入到搓招缓冲
func _update_motion_input() -> void:
	for d: String in MOTION_DIRS:
		if Input.is_action_just_pressed(d):
			_record_motion(d)


func _record_motion(direction: String) -> void:
	_p._motion_buffer.append(direction)
	if _p._motion_buffer.size() > MOTION_BUFFER_MAX:
		_p._motion_buffer.pop_front()


## 检查最近方向输入是否以指定指令序列结尾（如 "下右"）
func _match_motion(motion: String) -> bool:
	if motion.is_empty():
		return true
	var n: int = motion.length()
	if n > _p._motion_buffer.size():
		return false
	var start: int = _p._motion_buffer.size() - n
	for i: int in range(n):
		if _p._motion_buffer[start + i] != motion[i]:
			return false
	return true
