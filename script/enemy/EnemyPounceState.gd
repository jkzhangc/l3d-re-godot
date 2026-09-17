class_name EnemyPounceState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 权威结算命中；Client 靠 transform 快照跟随移动、靠 visual_char_index
##       拿到扑咬帧（本期复用攻击帧序列，无需专用网络字段）。
## 职责：首狩り（クビカリ）突进 —— ハンター 系专属：
##       远距锁定时高速冲刺扑向玩家；命中则造成伤害并附带 Heat（封锁玩家见切/切人），
##       随后进入长后摇（「大きな隙」）给玩家反击窗口；扑空则直接进后摇。
## 依赖：State、enemy 实体（pounce_* 系列参数 / attack_damage / attack_causes_heat）
##
## 原作依据（E:/15.L3D readme/enemy.html ハンター条）：
##   「すばやい動きで接近し、爪で攻撃する。首を狙った攻撃（首狩り）は弾薬耐久を削り、
##     プレイヤーを Heat 状態にする。ただし首狩りの後は大きな隙ができる。」
## 设计要点（对齐设计总纲 §3.1「首狩り：命中附带削损+玩家 Heat → 威胁防御系统本体」）：
##   · 触发距离：pounce_trigger_min_dist < 距离 ≤ pounce_trigger_max_dist
##     （太近直接走 Attack 状态即可，太远不该起跳）；
##   · 冲刺期间沿锁定方向直线突进，不重算寻路（"すばやい動き"的压迫感来源）；
##   · 命中判定用"与玩家的距离"而非矩形 —— 突进是动量的，矩形判定会随朝向抖；
##   · 收尾统一进后摇（attack_cooldown_frames），命中/扑空都一样：
##     这就是原作「首狩り後は大きな隙」，也是本项目"抓后摇反击"教学点。

enum Phase { WINDUP, DASH, RECOVER }

var _phase: int = Phase.WINDUP
var _timer: float = 0.0
var _dash_dir: Vector2 = Vector2.ZERO
var _hit_done: bool = false


func enter() -> void:
	var enemy: Node2D = character
	_phase = Phase.WINDUP
	_hit_done = false

	# 停掉行走动画 timer，防止回调覆盖扑咬帧（与 AttackState 同约定）
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	# 断线/切图时目标可能已失效
	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	var player: Node2D = enemy._player_ref
	_dash_dir = (player.global_position - enemy.global_position).normalized()
	if _dash_dir == Vector2.ZERO:
		_dash_dir = enemy.get_facing_vector()
	# 起跳前先转向 —— 俯视角里"面向玩家再扑"是可读性的关键
	character.update_facing_from_direction(_dash_dir)

	character.update_moving(true)
	character.velocity = Vector2.ZERO
	_timer = maxf(0.0, enemy.pounce_windup_seconds)
	# 预备帧：用攻击序列第 0 帧（蹲伏蓄力）
	enemy.set_attack_char_index(enemy.attack_char_sequence[0])
	# 切换附加动作表（ハンターγ 的突刺/攻击分属独立贴图）
	# 注：必须在 set_attack_char_index 之后再 push，否则 push 会把帧重置到 char_idx=0。
	if enemy.attack_texture != null:
		enemy.push_action_texture(enemy.attack_texture, enemy.attack_char_sequence[0])
	# 起跳音效（扑咬的"吼"）
	if enemy.pounce_sound:
		enemy._play_sound(enemy.pounce_sound, enemy.pounce_sound_pitch)
	else:
		enemy._play_sound(enemy.attack_sound, enemy.attack_sound_pitch)

	if _timer <= 0.0:
		_start_dash(enemy)


func exit() -> void:
	var enemy: Node2D = character
	if enemy.animation_timer:
		enemy.animation_timer.start()
	# 还原附加动作表（若本状态切过）
	if enemy.has_method("restore_walk_texture") and enemy.has_action_texture():
		enemy.restore_walk_texture()
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character

	match _phase:
		Phase.WINDUP:
			# 蓄力期间不移动，纯"预备"（给玩家一个反应窗口，避免无预警瞬移）
			_timer -= delta
			if _timer <= 0.0:
				_start_dash(enemy)

		Phase.DASH:
			_timer -= delta
			# 冲刺期间目标失效 → 中止，直接进后摇
			if not enemy.has_valid_player_target():
				_enter_recover(enemy)
				return
			var player: Node2D = enemy._player_ref
			# 吸附追击：冲刺途中每帧把 _dash_dir 朝玩家方向插值，
			# 让「すばやい動きで接近」表现为锁定扑咬而非纯直线扑空。
			# 位移（移速×倍率×时长）通常小于触发带宽，纯直线几乎必然落空，
			# 因此这里必须允许转向（用户 2026-09-12 决定采用吸附方案）。
			var turn: float = clampf(enemy.pounce_homing_turn_rate, 0.0, 1.0)
			if turn > 0.0:
				var to_p: Vector2 = (player.global_position - enemy.global_position).normalized()
				if to_p != Vector2.ZERO:
					_dash_dir = _dash_dir.lerp(to_p, clampf(turn * delta * 60.0, 0.0, 1.0)).normalized()
					character.update_facing_from_direction(_dash_dir)
			# 命中判定：突进途中一旦进入 pounce_hit_radius 就结算（只结算一次）
			if not _hit_done and player.global_position.distance_to(enemy.global_position) <= enemy.pounce_hit_radius:
				_do_pounce_hit(enemy, player)
				_hit_done = true
			if _hit_done:
				_enter_recover(enemy)
				return
			# 冲刺末帧的宽容判定：到达终点时若已贴到 hit_radius × tolerance 内，
			# 视作接触命中。否则中距起跳（位移不足以跑完全程）会长期空扑。
			if _timer <= 0.0:
				if not _hit_done:
					var tol: float = maxf(1.0, enemy.pounce_hit_tolerance)
					if player.global_position.distance_to(enemy.global_position) <= enemy.pounce_hit_radius * tol:
						_do_pounce_hit(enemy, player)
						_hit_done = true
				_enter_recover(enemy)
				return
			# 扑咬帧动画：锁定型已在 _start_dash 设好并全程保持（无需每帧刷新）；
			# 非锁定型（ハンター/ハンターβ）按冲刺进度推进，最后一帧收尾。
			if not enemy.pounce_hold_frame_during_dash:
				var seq: Array = enemy.attack_char_sequence
				if seq.size() > 0:
					var t: float = 1.0 - clampf(_timer / maxf(0.001, enemy.pounce_dash_seconds), 0.0, 1.0)
					var idx: int = clampi(int(t * float(seq.size())), 0, seq.size() - 1)
					enemy.set_attack_char_index(seq[idx])

		Phase.RECOVER:
			_timer -= delta
			if _timer <= 0.0:
				transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	var enemy: Node2D = character
	if _phase != Phase.DASH:
		character.velocity = Vector2.ZERO
		character.move_with_corner_assist()
		return
	# 冲刺：沿锁定方向直线突进（speed = 基础移速 × 倍率）
	# 走 move_with_corner_assist 而不是 move_and_slide —— 项目铁律：
	# 敌人移动一律经拐角辅助，否则会在 32px 窄道里被薄碰撞边卡住。
	## 突进速度：pounce_dash_speed > 0 时用绝对值（2026-09-15），否则 move_speed×倍率
	var dash_speed: float = enemy.pounce_dash_speed if enemy.pounce_dash_speed > 0.0 \
			else enemy.move_speed * enemy.pounce_speed_mult
	character.velocity = _dash_dir * dash_speed
	character.move_with_corner_assist()


func _start_dash(enemy: Node2D) -> void:
	_phase = Phase.DASH
	_timer = maxf(0.05, enemy.pounce_dash_seconds)
	# 冲刺中允许再次朝向修正一次（玩家在蓄力期间移动的情况）
	if enemy.has_valid_player_target():
		var p: Node2D = enemy._player_ref
		var d: Vector2 = (p.global_position - enemy.global_position).normalized()
		if d != Vector2.ZERO:
			_dash_dir = d
			character.update_facing_from_direction(_dash_dir)
	# 突刺帧：锁定型（ハンターγ）在冲刺开始即切到 seq[1] 并全程保持。
	# 原作「直到突刺移动结束之前，一直保持1」—— 必须在这里设，不能放在 DASH 分支尾部，
	# 因为 DASH 分支有多处提前 return（命中判定），尾部的帧更新会被跳过。
	if enemy.pounce_hold_frame_during_dash:
		var s: Array = enemy.attack_char_sequence
		if s.size() > 0:
			enemy.set_attack_char_index(s[mini(1, s.size() - 1)])


func _enter_recover(enemy: Node2D) -> void:
	_phase = Phase.RECOVER
	# 「首狩り後は大きな隙」：后摇统一走 attack_cooldown_frames（ハンター = 90 帧 ≈1.5s）
	_timer = float(enemy.attack_cooldown_frames) / 60.0
	# 冷却从后摇结束之后才开始算 —— 否则短后摇 + 短冷却会退化成连续扑咬
	enemy._pounce_cooldown_left = _timer + maxf(0.0, enemy.pounce_cooldown_seconds)
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	# 扑地收尾帧（用攻击序列末帧 = 趴地姿态）
	var seq: Array = enemy.attack_char_sequence
	if seq.size() > 0:
		enemy.set_attack_char_index(seq[seq.size() - 1])
	print("[敵人] 首狩り结束 → 后摇 %.2fs（破绽窗口）" % _timer)


func _do_pounce_hit(enemy: Node2D, player: Node2D) -> void:
	## 首狩り命中：伤害 + Heat（attack_causes_heat 由特感数据注入）。
	## 对齐设计总纲：「命中附带削损+玩家 Heat（封锁见切/切人）」。
	if player.get("_is_dying") == true:
		return
	if not player.has_method("take_damage"):
		return
	## 难度缩放：attack_damage 已含 enemy_damage 倍率（2026-09-16），再乘首狩り自身倍率。
	var dmg: float = enemy.get_final_attack_damage() * enemy.pounce_damage_mult
	var dir: Vector2 = (player.global_position - enemy.global_position).normalized()
	if dir == Vector2.ZERO:
		dir = enemy.get_facing_vector()
	player.take_damage(dmg, enemy.pounce_knockback_force, dir, false, 0.0, 0.0,
		enemy.next_attack_source_id(), enemy.attack_element, enemy.attack_causes_heat)
	# 命中玩家 → 跑步形态切回步行（暴君/猎杀者双速规则，用户 2026-09-13 定稿）
	enemy.notify_run_mode_hit()
	# 注：起跳音效已在 enter() 蓄力起手时播放，命中瞬间不再补声（用户 2026-09-12 反馈）
	print("[敵人] 首狩り命中！伤害=%d Heat=%s" % [int(dmg), str(enemy.attack_causes_heat)])
	# 命中特效（复用攻击特效配置）
	if enemy.attack_effect_anim:
		var efollow: Node2D = player if enemy.attack_effect_follow else null
		VXAnimSprite.play_scene(enemy.attack_effect_anim, player.global_position,
			enemy.get_tree().current_scene, 10.0, efollow, enemy.attack_effect_offset_override)
