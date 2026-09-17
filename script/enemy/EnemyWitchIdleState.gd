class_name EnemyWitchIdleState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 执行刺激判定；Client 靠 visual_char_index / transform 跟随表现。
## 职责：女巫（ブレアウィッチ）徘徊态 —— 与原作/L4D 的 Witch 同构：
##       · 平时**低头徘徊**，即使玩家在视野内也不主动接近、不攻击；
##       · 玩家靠太近 / 停留太久 / 攻击她 → 累积「刺激值」；
##       · 刺激值满 → 尖叫并进入全力追杀（Enraged 态，速度大幅提升）；
##       · 若始终不被刺激，玩家可以安全路过 —— 这就是「纯路线回避考验」。
## 依赖：State、enemy 实体（witch_* 系列参数）
##
## 原作依据（E:/15.L3D readme/enemy.html ブレアウィッチ条）：
##   「普段はうずくまって泣いている。近づきすぎたり攻撃すると怒り、全力で
##     襲いかかってくる。刺激しなければやり過ごせる。」
## 设计定稿（2026-09-12，对齐设计总纲 §3.1）：
##   · 徘徊态不接近不攻击 → 玩家可绕行；
##   · 刺激来源三档（越近越快 / 攻击必激怒 / 手电或大声？本项目简化为前两者）；
##   · 散弾枪易误触 —— 由"攻击即激怒"自然覆盖（大范围武器容易打到她）。

enum Stim { NONE, NEAR, ATTACKED }

var _wander_dir: Vector2 = Vector2.ZERO
var _wander_timer: float = 0.0
var _stim: float = 0.0   ## 刺激值 0..1，累积到 1 即激怒


func enter() -> void:
	var enemy: Node2D = character
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_stim = 0.0
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

	# ── 刺激判定：玩家距离越近，累积越快 ──
	# 注意这里**不检查视野锥**：女巫低头哭泣，玩家从背后靠近一样会被察觉（原作如此）。
	if enemy.has_valid_player_target():
		var player: Node2D = enemy._player_ref
		var d: float = player.global_position.distance_to(enemy.global_position)
		if d <= 1.0:
			d = 1.0
		if d <= enemy.witch_stim_radius:
			# 越近累积越快：贴脸时约 0.35s 激怒，站在边缘约 2.5s
			var rate: float = enemy.witch_stim_radius / d
			_stim += delta * rate * enemy.witch_stim_speed
			if _stim >= 1.0:
				_enrage(enemy)
				return
	else:
		# 无目标：慢慢平息（玩家走远后刺激值回落，避免"路过一次永久激怒"）
		_stim = maxf(0.0, _stim - delta * 0.3)

	# ── 徘徊移动（极慢，几乎原地）──
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


func _enrage(enemy: Node2D) -> void:
	## 刺激满 → 尖叫 + 全力追杀。
	## 激怒是**不可逆**的（原作如此）：一旦被激怒就追杀到死或玩家离开场景。
	enemy.witch_enraged = true
	enemy.move_speed = enemy.move_speed * enemy.witch_enrage_speed_mult
	if enemy.witch_scream_sound:
		enemy._play_sound(enemy.witch_scream_sound, enemy.witch_scream_sound_pitch)
	else:
		enemy._play_sound(enemy.discover_sound, enemy.discover_sound_pitch)
	print("[敵人] 女巫被刺激（刺激值满）→ 全力追杀！移速 → %d" % int(enemy.move_speed))
	# 激怒后走 Chase（复用现有追击 + 攻击链路；女巫不参与首狩り/正面抗性）
	transition_requested.emit("Chase")
