class_name EnemySpitState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 权威生成酸弹；Client 靠 transform 快照跟随、靠 visual_char_index 拿吐酸帧。
##       出酸瞬间经 NetworkWorld 广播 enemy_acid_spit_presentation（A2）→ Client 生成
##       非权威镜像弹（只做视觉音效，伤害/相消仍 Host 判定）。
## 职责：远程吐酸 —— ブレインディモス 专属（全工程首个敌人远程攻击状态）：
##       中距离停步 → 后仰蓄力 → 吐出酸弹（命中玩家：伤害+削り；与玩家子弹相消）→ 后摇 → 回追击。
## 依赖：State、enemy 实体（spit_* 系列参数）、object/enemy_acid_spit.tscn
##
## 原作依据（E:/15.L3D readme/enemy.html ブレインディモス条）：
##   「遠距離から酸をはきかけてくるのが、さらに嫌らしい。正面から撃ち合いをすると
##   酸で銃弾を相殺してしまうこともある。おまけにこの酸には削り効果があり、
##   連続で食らうと武器があっという間にダメにされてしまう。」
## 设计要点：
##   · 触发判定在 ChaseState._can_spit（距离带 + 冷却 + LOS），本状态只负责演出与发射；
##   · 冷却从后摇结束后起算（与首狩り同规则），由 enemy._process 统一递减；
##   · 发射方向取「发射瞬间玩家位置」——蓄力期间玩家可以走位躲弹（反应窗口的意义）。

enum Phase { WINDUP, RECOVER }

var _phase: int = Phase.WINDUP
var _timer: float = 0.0
var _fired: bool = false
var _seq: Array = []


func enter() -> void:
	var enemy: Node2D = character
	_phase = Phase.WINDUP
	_fired = false

	# 停掉行走动画 timer，防止回调覆盖吐酸帧（与 AttackState/PounceState 同约定）
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	# 断线/切图时目标可能已失效
	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	var player: Node2D = enemy._player_ref
	var dir: Vector2 = player.global_position - enemy.global_position
	if dir == Vector2.ZERO:
		dir = enemy.get_facing_vector()
	else:
		dir = dir.normalized()
	# 吐酸前先转向 —— 俯视角里"面向玩家再吐"是可读性的关键
	character.update_facing_from_direction(dir)

	character.update_moving(true)
	character.velocity = Vector2.ZERO

	_seq = enemy.spit_char_sequence if enemy.spit_char_sequence.size() > 0 else enemy.attack_char_sequence
	_timer = maxf(0.05, enemy.spit_windup_seconds)
	# 蓄力帧：序列第 0 帧（后仰蓄势）
	enemy.set_attack_char_index(_seq[0])
	## 吐酸音效在【出酸瞬间】播（_fire_acid）——2026-09-17 用户反馈：蓄力开始就播，
	## 音效播完了酸才出来，听感脱节。


func exit() -> void:
	var enemy: Node2D = character
	if enemy.animation_timer:
		enemy.animation_timer.start()
	character.velocity = Vector2.ZERO


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character

	match _phase:
		Phase.WINDUP:
			_timer -= delta
			if _timer <= 0.0 and not _fired:
				_fire_acid(enemy)
				_fired = true
				_phase = Phase.RECOVER
				_timer = maxf(0.05, enemy.spit_recover_seconds)
				# 冷却从后摇结束后才开始算（与首狩り同规则），由 enemy._process 递减
				enemy._spit_cooldown_left = maxf(0.05, enemy.spit_recover_seconds) \
						+ maxf(0.0, enemy.spit_cooldown_seconds)
				character.update_moving(false)
				character.velocity = Vector2.ZERO

		Phase.RECOVER:
			_timer -= delta
			if _timer <= 0.0:
				transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	# 吐酸全程站桩（原作虫子是"停在原地噗咻一口"的节奏）
	character.velocity = Vector2.ZERO
	character.move_with_corner_assist()


func _fire_acid(enemy: Node2D) -> void:
	# 吐酸帧：序列的发射索引帧（前倾吐酸姿势）
	var fire_idx: int = clampi(enemy.spit_fire_at_sequence_idx, 1, _seq.size() - 1) if _seq.size() > 1 else 0
	enemy.set_attack_char_index(_seq[fire_idx])
	# 出酸瞬间播放吐酸音效（与酸弹同帧）
	if enemy.spit_sound:
		enemy._play_sound(enemy.spit_sound, enemy.spit_sound_pitch)

	# 发射方向取「发射瞬间玩家位置」——蓄力期间玩家可以走位躲弹
	var dir: Vector2 = enemy.get_facing_vector()
	if enemy.has_valid_player_target():
		var to_p: Vector2 = enemy._player_ref.global_position - enemy.global_position
		if to_p.length_squared() > 1.0:
			dir = to_p.normalized()

	var scene: PackedScene = enemy.spit_projectile_scene \
			if enemy.spit_projectile_scene != null \
			else preload("res://object/enemy_acid_spit.tscn")
	var proj: Node2D = scene.instantiate()
	## 出口 = 虫嘴前方 28px。⚠ 不要加 y 抬高（2026-09-17 实机反馈：抬高 20px 会让酸
	## 从玩家碰撞体上方飞过——穿过玩家不掉血，到射程尽头才因别的判定受伤）。
	## 俯视角的"高度"纯靠表现层，碰撞必须在玩家所在的地平面。
	## 嵌墙脱困（2026-09-17 用户反馈：窄道吐酸被墙挡——生成点戳进墙格，酸一出生就被吃）：
	## 生成点按图块障碍层（1|32）点查询，落在墙里 → 退回虫体原点（本体必然不在墙内）。
	var spawn_pos: Vector2 = enemy.global_position + dir * 28.0
	var space: PhysicsDirectSpaceState2D = enemy.get_world_2d().direct_space_state
	var point_q := PhysicsPointQueryParameters2D.new()
	point_q.position = spawn_pos
	point_q.collision_mask = 1 | 32
	if not space.intersect_point(point_q).is_empty():
		spawn_pos = enemy.global_position
	proj.global_position = spawn_pos
	proj.direction = dir
	proj.speed = enemy.spit_projectile_speed
	proj.damage = enemy.get_spit_damage()
	proj.source_id = enemy.next_attack_source_id()
	proj.impact_effect = enemy.spit_impact_effect
	proj.impact_tone = enemy.spit_impact_tone
	var parent: Node = enemy.get_tree().current_scene
	if parent == null:
		parent = enemy.get_parent()
	parent.add_child(proj)
	## A2 联机：把本次吐酸广播给 Client（单机/无联机时在 NetworkWorld 内 no-op）。
	_announce_network_spit(enemy, spawn_pos, dir)


## Host：吐酸事件广播（entity_id + 出口坐标 + 方向）。速度/特效/音效由 Client 从
## 本地 enemy 节点字段解析（A1 注入保证有值），资源不经网络传输。
func _announce_network_spit(enemy: Node2D, spawn_pos: Vector2, dir: Vector2) -> void:
	var tree := enemy.get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null:
		return
	var world := scene.find_child("NetworkWorld", true, false)
	if world != null and world.has_method("announce_enemy_acid_spit"):
		world.call("announce_enemy_acid_spit", enemy, spawn_pos, dir)
