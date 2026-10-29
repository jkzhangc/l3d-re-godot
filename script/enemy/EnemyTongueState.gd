class_name EnemyTongueState extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：仅 Host 执行；特效是本地表现（Client 不跑 AI 状态机，舌头动画不跨端）
## 职责：舌头攻击 —— バイオゲラス（用户口中的「变色龙」）专属：
##       中距离停步 → 本体蓄力（新动作）→ 播放「舌头 + 本体」特效动画 → 前方矩形判定 → 后摇。
## 依赖：State、enemy 实体（tongue_* 参数）、VXAnimSprite（art/Animations/バイオゲラス攻撃アニメ*.png）
##
## 【为什么特效里包含本体】原作素材 `バイオゲラス攻撃アニメ.png / 2.png` 是「本体新动作 +
## 舌头」合成好的 5×5 动画表（不是单独的舌头图层）。播放时隐藏本体精灵，让特效里的本体
## 接管表现，结束后恢复 —— 这就是用户说的「特效动画是舌头和本体新动作」。
##
## 【朝向帧序列】5×5 表按方向分组（右 / 左 / 下 / 上），帧序列由
## SpecialEnemyData.tongue_frames_* 注入。横向/下用第一张表，上用第二张表。

enum Phase { WINDUP, STRIKE, RECOVER }

## VX 动画播放器（preload 常量而不是 class_name：本项目 class_name 不进全局类缓存）。
const ANIM := preload("res://script/vx_anim_sprite.gd")

var _phase: int = Phase.WINDUP
var _timer: float = 0.0
var _dir: Vector2 = Vector2.ZERO
var _seq: Array[int] = []
var _strike_elapsed: float = 0.0
var _strike_duration: float = 0.0
var _hit_at: float = 0.0
var _hit_done: bool = false
var _sprite_hidden: bool = false


func enter() -> void:
	var enemy: Node2D = character
	_phase = Phase.WINDUP
	_hit_done = false
	_strike_elapsed = 0.0
	_sprite_hidden = false

	# 停掉行走动画 timer，防止回调覆盖动作帧（与 Attack/Pounce/Swallow 同约定）
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	# 断线/切图时目标可能已失效
	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	var player: Node2D = enemy._player_ref
	_dir = player.global_position - enemy.global_position
	if _dir.length_squared() <= 1.0:
		_dir = enemy.get_facing_vector()
	else:
		_dir = _dir.normalized()
	# 面向玩家再吐舌 —— 俯视角可读性
	character.update_facing_from_direction(_dir)
	_dir = enemy.get_facing_vector()

	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_timer = maxf(0.0, enemy.tongue_windup_seconds)

	# 蓄力本体帧：优先切攻击表（新动作），没有攻击表就只换角色格
	if enemy.attack_texture != null:
		enemy.push_action_texture(enemy.attack_texture, enemy.tongue_body_frame)
	else:
		enemy.set_attack_char_index(enemy.tongue_body_frame)

	if _timer <= 0.0:
		_start_strike(enemy)


func exit() -> void:
	var enemy: Node2D = character
	_show_enemy_sprite(enemy)
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
			_timer -= delta
			if _timer <= 0.0:
				_start_strike(enemy)

		Phase.STRIKE:
			_strike_elapsed += delta
			if not _hit_done and _strike_elapsed >= _hit_at:
				_do_tongue_hit(enemy)
				_hit_done = true
			if _strike_elapsed >= _strike_duration + 0.05:
				_enter_recover(enemy)

		Phase.RECOVER:
			_timer -= delta
			if _timer <= 0.0:
				transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	# 吐舌全程站桩（本体在特效里，节点本身不移动）
	character.velocity = Vector2.ZERO
	character.move_with_corner_assist()


func _start_strike(enemy: Node2D) -> void:
	_phase = Phase.STRIKE
	_strike_elapsed = 0.0
	_hit_done = false
	_seq = _frames_for_facing(enemy)
	var frame_sec: float = maxf(0.03, enemy.tongue_effect_frame_seconds)
	_strike_duration = maxf(frame_sec, float(_seq.size()) * frame_sec)
	_hit_at = clampf(_strike_duration * 0.45, 0.08, maxf(0.09, _strike_duration - 0.05))

	# 吐舌音效 + 特效（特效里含本体，先隐藏本体精灵）
	if enemy.tongue_sound or not enemy.tongue_sound_pool.is_empty():
		enemy._play_pool(enemy.tongue_sound_pool, enemy.tongue_sound, enemy.tongue_sound_pitch)
	# 联机：先广播，让 Client 与 Host 同帧开始播（伤害仍 Host 权威）
	enemy.announce_tongue(int(enemy.get("_facing")))
	## 只有特效真的播出来才隐藏本体；特效缺失时保持本体可见（宁可不播，也不能让敌人凭空消失）。
	if _play_tongue_effect(enemy):
		_hide_enemy_sprite(enemy)


func _frames_for_facing(enemy: Node2D) -> Array[int]:
	return enemy.tongue_frames_for_facing(int(enemy.get("_facing")))


## 生成并播放舌头特效。横向/下用第一张表，上用第二张表。返回是否成功生成。
func _play_tongue_effect(enemy: Node2D) -> bool:
	var facing: int = int(enemy.get("_facing"))
	var packed: PackedScene = enemy.tongue_effect_scene_for_facing(facing)
	if packed == null:
		return false
	var anim: Node2D = ANIM.from_scene(packed)
	if anim == null:
		return false
	# 这些必须在 add_child（_ready）之前设置：_ready 会按 fps/帧序列建计时器并显示首帧。
	anim.set("frame_sequence", _seq)
	anim.set("fps", 1.0 / maxf(0.03, enemy.tongue_effect_frame_seconds))
	anim.set("auto_free", true)
	## 每方向的脚底锚点不同（原素材按 RM2K3 事件锚点排版），Host/Client 共用同一份校正。
	anim.set("position_offset", enemy.tongue_effect_offset_for_facing(facing))
	anim.set("follow_target", enemy)
	anim.set("follow_enabled", true)
	anim.global_position = enemy.global_position
	var parent: Node = enemy.get_tree().current_scene
	if parent == null:
		parent = enemy.get_parent()
	if parent == null:
		anim.queue_free()
		return false
	parent.add_child(anim)
	return true


func _hide_enemy_sprite(enemy: Node2D) -> void:
	if enemy.sprite == null:
		return
	enemy.sprite.visible = false
	_sprite_hidden = true


func _show_enemy_sprite(enemy: Node2D) -> void:
	if not _sprite_hidden:
		return
	_sprite_hidden = false
	if is_instance_valid(enemy) and enemy.sprite != null:
		enemy.sprite.visible = true


func _enter_recover(enemy: Node2D) -> void:
	_phase = Phase.RECOVER
	_show_enemy_sprite(enemy)
	# 后摇 + 冷却（冷却从后摇结束起算，与首狩り/吐酸同规则）
	_timer = maxf(0.05, enemy.tongue_recover_seconds)
	enemy._tongue_cooldown_left = _timer + maxf(0.0, enemy.tongue_cooldown_seconds)
	character.update_moving(false)
	character.velocity = Vector2.ZERO


## 前方矩形判定：以吐舌瞬间的朝向为轴，长度 = tongue_hit_range.x，宽度 = tongue_hit_range.y。
func _do_tongue_hit(enemy: Node2D) -> void:
	if not enemy.has_valid_player_target():
		return
	var player: Node2D = enemy._player_ref
	if player.get("_is_dying") == true or not is_instance_valid(player):
		return
	var rel: Vector2 = player.global_position - enemy.global_position
	var forward: float = rel.dot(_dir)
	if forward <= 0.0:
		return
	var lateral: float = absf(rel.cross(_dir))
	var reach: float = maxf(16.0, enemy.tongue_hit_range.x)
	var half_w: float = maxf(8.0, enemy.tongue_hit_range.y * 0.5)
	if forward > reach or lateral > half_w:
		return
	var dmg: float = enemy.get_tongue_damage()
	player.take_damage(dmg, enemy.pounce_knockback_force * 0.5, _dir, false, 0.0, 0.0,
		enemy.next_attack_source_id(), enemy.attack_element, false)
	# 命中玩家 → 跑步形态切回步行（与首狩り同规则）
	enemy.notify_run_mode_hit()
	print("[敵人] 舌头攻击命中！伤害=%d（前 %.0f / 横 %.0f）" % [int(dmg), forward, lateral])
