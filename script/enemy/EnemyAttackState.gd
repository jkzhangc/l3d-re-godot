extends State
## 敌人攻击状态 — 面向玩家 → 近战动画 → 判定 → 后摇
##
## 攻击序列: attack_char_sequence（默认 [1,2,3,1,0]）
## 伤害判定在 hit_at_sequence_idx（默认 2），按方向偏移矩形
## 停顿效果：在 attack_frame_durations 中把判定帧的时长拉长即可
##   （例如 0.43 秒 ≈ 旧版 20 帧暂停 + 0.1 秒帧时长）

enum Phase { ANIM, COOLDOWN }

var _seq_idx: int = 0
var _timer: float = 0.0
var _phase: int = Phase.ANIM
var _cooldown_left: int = 0
var _hit_done: bool = false


func enter() -> void:
	var enemy: Node2D = character
	_seq_idx = 0
	_timer = enemy.get_attack_frame_duration(_seq_idx)
	_phase = Phase.ANIM
	_hit_done = false

	# 停掉行走动画 timer，防止回调覆盖攻击帧
	if enemy.animation_timer:
		enemy.animation_timer.stop()

	# 断线/切图时目标可能已进入 queue_free；不要在攻击状态继续读取失效引用。
	if not enemy.has_valid_player_target():
		character.update_moving(false)
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return
	var player: Node2D = enemy._player_ref
	var dir: Vector2 = player.global_position - enemy.global_position
	character.update_facing_from_direction(dir)

	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_set_attack_frame(_seq_idx)

	# 若判定帧就是第一帧 → 立即命中
	if _seq_idx == enemy.hit_at_sequence_idx:
		_do_attack_hit()
		_hit_done = true


func exit() -> void:
	# 恢复行走动画 timer
	var enemy: Node2D = character
	if enemy.animation_timer:
		enemy.animation_timer.start()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	if not enemy.has_valid_player_target():
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return

	match _phase:
		Phase.ANIM:
			_timer -= delta
			if _timer <= 0.0:
				_seq_idx += 1
				if _seq_idx >= enemy.attack_char_sequence.size():
					_enter_cooldown(enemy)
					return

				_timer = enemy.get_attack_frame_duration(_seq_idx)
				_set_attack_frame(_seq_idx)

				# 命中判定
				if not _hit_done and _seq_idx == enemy.hit_at_sequence_idx:
					_do_attack_hit()
					_hit_done = true

		Phase.COOLDOWN:
			_cooldown_left -= 1
			if _cooldown_left <= 0:
				transition_requested.emit("Chase")


func physics_update(_delta: float) -> void:
	character.velocity = Vector2.ZERO
	character.move_and_slide()


func _enter_cooldown(enemy: Node2D) -> void:
	_phase = Phase.COOLDOWN
	_cooldown_left = enemy.attack_cooldown_frames
	character.update_moving(false)
	print("[敵人] 攻击后摇: %d 帧" % _cooldown_left)


func _set_attack_frame(seq_idx: int) -> void:
	var enemy: Node2D = character
	var char_idx: int = enemy.attack_char_sequence[seq_idx]
	enemy.set_attack_char_index(char_idx)


## 判断目标是否在攻击命中矩形内（投影法，所有方向统一旋转）
## 将目标相对向量投影到前方/侧方轴，检查是否在矩形半宽半高内
func _is_target_in_hit_rect(to_target: Vector2, fv: Vector2, half_w: float, half_h: float) -> bool:
	# 投影到前方轴（纵向）和侧方轴（横向），四个方向统一
	var fwd: float = to_target.dot(fv)
	var lat: float = to_target.dot(Vector2(-fv.y, fv.x))
	return abs(fwd) <= half_h and abs(lat) <= half_w


func _do_attack_hit() -> void:
	var enemy: Node2D = character
	var player: Node2D = enemy._player_ref

	var fv: Vector2 = enemy.get_facing_vector()
	var hit_center: Vector2 = enemy.global_position + fv * enemy.attack_hit_forward_offset
	var hit_w: float = enemy.attack_hit_range.x
	var hit_h: float = enemy.attack_hit_range.y
	var half_w: float = hit_w / 2.0
	var half_h: float = hit_h / 2.0

	# 对玩家的命中判定（跳过已死亡玩家）
	if player and player.get("_is_dying") != true:
		var to_player: Vector2 = player.global_position - hit_center
		if _is_target_in_hit_rect(to_player, fv, half_w, half_h):
			var dmg: float = enemy.attack_damage
			var dir: Vector2 = (player.global_position - enemy.global_position).normalized()
			if player.has_method("take_damage"):
				player.take_damage(dmg, 120.0, dir)
				# 播放攻击音效
				enemy._play_sound(enemy.attack_sound)
				# 播放攻击特效
				if enemy.attack_effect_anim:
					var efollow: Node2D = player if enemy.attack_effect_follow else null
					VXAnimSprite.play_scene(enemy.attack_effect_anim, player.global_position, enemy.get_tree().current_scene, 10.0, efollow, enemy.attack_effect_offset_override)
				print("[敵人] 攻击命中玩家！伤害=%d" % int(dmg))
			else:
				print("[敵人] 攻击！目标无 take_damage 方法")
		else:
			print("[敵人] 攻击落空（玩家不在矩形判定区内）")

	# 友军伤害：对命中矩形内的其他敌人造成伤害（默认关闭，跳过已死亡敌人）
	if enemy.can_damage_enemies:
		var all_enemies: Array[Node] = enemy.get_tree().get_nodes_in_group("enemy")
		for other: Node2D in all_enemies:
			if other == enemy or other == player:
				continue
			if other.get("_is_dead") == true:
				continue
			if other is CharacterBody2D and other.has_method("take_damage"):
				var to_other: Vector2 = other.global_position - hit_center
				if _is_target_in_hit_rect(to_other, fv, half_w, half_h):
					var dmg: float = enemy.attack_damage
					var dir: Vector2 = (other.global_position - enemy.global_position).normalized()
					other.take_damage(dmg, 120.0, dir)
					print("[敵人] 友军伤害！命中其他敌人 伤害=%d" % int(dmg))
