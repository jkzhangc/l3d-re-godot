class_name EnemyWitchIdleState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 执行刺激判定；Client 靠 visual_char_index / transform 跟随表现。
## 职责：女巫（ブレアウィッチ）徘徊态 —— 与原作/L4D 的 Witch 同构：
##       · 平时**低头徘徊**，即使玩家在视野内也不主动接近、不攻击；
##       · 玩家靠太近 / 停留太久 / **攻击她** → 惊动，尖叫并全力追杀；
##       · 若始终不被惊动，玩家可以安全路过 —— 这就是「纯路线回避考验」。
## 依赖：State、enemy 实体（witch_* 系列参数）、`Enemy.startle_witch()`（惊动唯一入口）
##
## 原作依据（E:/15.L3D readme/enemy.html ブレアウィッチ条）：
##   「普段はうずくまって泣いている。近づきすぎたり攻撃すると怒り、全力で
##     襲いかかってくる。刺激しなければやり過ごせる。」
##
## ★2026-10-25 重做（用户：「现在她更像一个会站桩的普通怪，缺少别开枪、绕过去的决策压力」）：
##   旧实现只有一条"越近越快"的累积（rate = radius / dist，160px 内 1 秒内必惊动），
##   叠加 2× 缩放下屏幕半宽仅 320px，等于**任何走廊路过都会惊动她** —— "绕开"实际不存在。
##   现在改成三圈结构（与 L4D 一致）：
##     警戒圈 200px：停步、转向你、低吼一次 —— 可读的"她注意到你了"
##     刺激圈 110px：停留才累积（边缘 4 秒 / 圈心 0.33 秒），离开就以 0.4/秒 回落
##     贴脸 46px ：立刻惊动（等于撞到她）
##   再加上"被攻击立即惊动"（见 Enemy.take_damage），玩家才真的要在"绕 / 打"之间做选择。

var _wander_dir: Vector2 = Vector2.ZERO
var _wander_timer: float = 0.0
var _stim: float = 0.0            ## 刺激值 0..1，累积到 1 即惊动
var _alert_notified: bool = false  ## 警戒低吼是否已播（进圈一次，出圈复位）


func enter() -> void:
	var enemy: Node2D = character
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_stim = 0.0
	_alert_notified = false
	_random_wander(enemy)
	# 徘徊态姿态：低头哭泣（用行走第一帧，配合极慢的原地摇摆）
	if enemy.animation_timer:
		enemy.animation_timer.stop()
	enemy.update_moving(false)


func exit() -> void:
	var enemy: Node2D = character
	if enemy.animation_timer:
		enemy.animation_timer.start()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return
	var enemy: Node2D = character

	# 注意这里**不检查视野锥**：女巫低头哭泣，玩家从背后靠近一样会被察觉（原作如此）。
	var player: Node2D = enemy._player_ref if enemy.has_valid_player_target() else null
	var d: float = INF
	if is_instance_valid(player):
		d = player.global_position.distance_to(enemy.global_position)

	# ── ① 贴脸：立刻惊动（原作「近づきすぎたり…怒り」）──
	if d <= enemy.witch_touch_radius:
		enemy.startle_witch("贴脸")
		return

	# ── ② 刺激圈内累积（越近越快；二次曲线让"边缘路过"更安全）──
	if d <= enemy.witch_stim_radius:
		var t: float = 1.0 - clampf(d / maxf(enemy.witch_stim_radius, 1.0), 0.0, 1.0)
		var rate: float = lerpf(enemy.witch_stim_edge_rate, enemy.witch_stim_close_rate, t * t)
		_stim += delta * rate * enemy.witch_stim_speed
		if _stim >= 1.0:
			enemy.startle_witch("刺激值满")
			return
	else:
		# 玩家在刺激圈外（**包括"圈外但还在警戒圈里"这种情况**）→ 刺激值回落。
		# 旧实现只在"完全没有可追目标"时回落：站在 200px 处观望会把刺激值一直吊着，
		# 退开也降不了火，"退一步冷静"的应对手段实际不存在。
		_stim = maxf(0.0, _stim - delta * enemy.witch_stim_decay)

	# ── ③ 警戒圈：停步 + 转向 + 低吼一次（给玩家"该绕开"的信号）──
	if d <= enemy.witch_alert_radius:
		if not _alert_notified:
			_alert_notified = true
			_warn_once(enemy)
		enemy.velocity = Vector2.ZERO
		enemy.update_facing_from_direction(player.global_position - enemy.global_position)
		enemy.update_moving(false)
		return

	# 出了警戒圈 → 复位，下次再靠近会重新低吼
	_alert_notified = false

	# ── ④ 徘徊（极慢，几乎原地）──
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_random_wander(enemy)

	var speed: float = enemy.witch_wander_speed
	enemy.velocity = _wander_dir * speed
	enemy.update_facing_from_direction(_wander_dir)
	enemy.update_moving(speed > 1.0)
	enemy.move_with_corner_assist()


func physics_update(_delta: float) -> void:
	pass  ## 位移统一在 process_update 里（女巫移速极慢，不需要物理帧插值）


func _random_wander(enemy: Node2D) -> void:
	## 女巫徘徊：非常小的位移半径（"うずくまって泣いている"），主要是朝向变化。
	var angle: float = randf_range(0.0, TAU)
	_wander_dir = Vector2.RIGHT.rotated(angle)
	_wander_timer = randf_range(2.5, 5.0)


## 警戒低吼：这是"可以绕开"的唯一听觉提示。
## 没有它，玩家只能靠"突然被追"来发现她的存在 —— 那就变成纯惩罚而不是决策。
func _warn_once(enemy: Node2D) -> void:
	## 2026-10-29：警戒低吼优先走随机池；池空才回退单条 / 发现音。
	var snd: AudioStream = enemy._pick_pool_stream(enemy.witch_alert_sound_pool)
	var pitch: float = 0.8
	if snd == null:
		snd = enemy.witch_alert_sound
	if snd == null:
		snd = enemy.get_discover_sound()
		pitch = enemy.get_discover_pitch() * 0.8
	if snd != null:
		enemy._play_sound(snd, pitch)
	print("[敵人] 女巫抬头（警戒）：玩家进入 %.0fpx 警戒圈，仍在刺激圈外" % enemy.witch_alert_radius)
