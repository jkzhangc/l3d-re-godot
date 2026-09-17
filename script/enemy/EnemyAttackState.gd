extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 结算玩家伤害
## 职责：攻击状态：面向玩家 → 挥舞动画 → 命中帧判定 → 后摇，命中时通知玩家以打通见切回路。
## 依赖：State、enemy 实体、玩家见切接口

## 攻击命中帧由 Host 结算玩家伤害；Client 只看到攻击动画和 NetworkWorld 的伤害事件。
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

	# 特感专属攻击动作表：若配置了 attack_texture，切过去并按其序列索引取帧。
	# 普通僵尸 attack_texture 为空 → 走原路径（同一张表内切角色格）。
	if enemy.attack_texture != null:
		enemy.push_action_texture(enemy.attack_texture,
			enemy.attack_char_sequence[0] if enemy.attack_char_sequence.size() > 0 else 0)
		## 诊断（2026-09-15）： tres 配的序列若在实机仍显示为默认 12310，看这行打印即可
		## 分辨「注入丢失」还是「渲染问题」；定位后可移除。
		print("[EnemyAttack] 动作表切换 seq=%s hit@%d tex=%s" % [
			enemy.attack_char_sequence, enemy.hit_at_sequence_idx,
			enemy.attack_texture.resource_path.get_file()])
	else:
		_set_attack_frame(_seq_idx)

	# 攻击音效在挥击动作「开始」时播放，而不是命中那一刻 ——
	# 用户 2026-09-12 反馈：贴在命中帧会让声音滞后于视觉动作，听感像是"打中了才吼"。
	# 前摇起手同时出声，玩家才能靠听觉预判攻击（尤其背后遇袭时）。
	enemy._play_sound(enemy.attack_sound, enemy.attack_sound_pitch)

	# 若判定帧就是第一帧 → 立即命中
	if _seq_idx == enemy.hit_at_sequence_idx:
		_do_attack_hit()
		_hit_done = true


func exit() -> void:
	# 恢复行走动画 timer
	var enemy: Node2D = character
	# 攻击收势 → 跑步形态切回步行（2026-09-13 用户反馈：T-002 攻击完后贴脸仍是跑步图）。
	## 顺序（2026-09-15 修复）：先归位形态再恢复行走表——反过来会按攻击进入时的
	## 跑步格（walk_char_index=0）画一帧「回到0」的残留。
	if enemy.has_method("notify_run_mode_hit"):
		enemy.notify_run_mode_hit()
	if enemy.has_method("restore_walk_texture") and enemy.has_action_texture():
		enemy.restore_walk_texture()
	if enemy.animation_timer:
		enemy.animation_timer.start()
	# 之后由距离判定决定是否再次起跑（命中路径里已重置过，幂等）。


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
	character.move_with_corner_assist()


func _enter_cooldown(enemy: Node2D) -> void:
	_phase = Phase.COOLDOWN
	_cooldown_left = enemy.attack_cooldown_frames
	character.update_moving(false)
	## 后摇期保持攻击末帧（2026-09-15 用户定稿：后摇不切行走图/索引，后摇结束才切回）
	print("[敵人] 攻击后摇: %d 帧" % _cooldown_left)


func _set_attack_frame(seq_idx: int) -> void:
	var enemy: Node2D = character
	if seq_idx < 0 or seq_idx >= enemy.attack_char_sequence.size():
		return
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
			## 难度缩放：走 enemy 的统一入口（attack_damage × enemy_damage 倍率），2026-09-16。
			var dmg: float = enemy.get_final_attack_damage()
			var dir: Vector2 = (player.global_position - enemy.global_position).normalized()
			if player.has_method("take_damage"):
				# 命中玩家 → 跑步形态切回步行（暴君/猎杀者双速规则，用户 2026-09-13 定稿）
				enemy.notify_run_mode_hit()
				var hp_before: float = float(player.get("current_hp")) if player.get("current_hp") != null else -1.0
				player.take_damage(dmg, 120.0, dir, false, 0.0, 0.0, enemy.next_attack_source_id(), enemy.attack_element, enemy.attack_causes_heat)
				# 注：攻击音效已在 enter() 挥击起手时播放，此处不再重复播放（用户 2026-09-12 反馈）
				# 播放攻击特效（喷血）——仅在实际掉血时播放：
				# 见切/しゃがみ等无效化命中时玩家不掉血，不喷血（用户 2026-09-11 反馈）
				var hp_after: float = float(player.get("current_hp")) if player.get("current_hp") != null else -1.0
				if hp_before >= 0.0 and hp_after >= 0.0 and hp_after < hp_before:
					# 击中目标音效（2026-09-15 用户需求）：与喷血同条件，实际掉血才响
					enemy._play_sound(enemy.hit_target_sound, enemy.hit_target_sound_pitch)
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
