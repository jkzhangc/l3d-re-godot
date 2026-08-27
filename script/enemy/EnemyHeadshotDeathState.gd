extends State
## 爆头死亡包含独立动画与暂停阶段，不能被普通受击状态抢占。
## 爆头死亡状态 — 播放爆头动画 (char_idx 5 → 暂停20帧 → char_idx 6)，尸体保留
##
## 动画结束后保持 char_idx 6，尸体永久保留在地图上
##
## 注意：不能调用 _disable_for_corpse() 因为它会关掉 StateMachine，
## 但本状态的 process_update 正是驱动动画阶段的引擎。

enum Phase { ANIM, PAUSE, DONE }

var _phase: int = Phase.ANIM
var _pause_frames_left: int = 0
var _fallen_sound_played: bool = false


func enter() -> void:
	var enemy: Node2D = character
	enemy.update_moving(false)
	enemy.velocity = Vector2.ZERO

	# 手动清理碰撞和视野（但不关 StateMachine，因为需要 process_update 驱动动画）
	if enemy.get_node_or_null("CollisionShape2D"):
		enemy.get_node("CollisionShape2D").set_deferred("disabled", true)
	var vision: Area2D = enemy.get_node_or_null("VisionArea") as Area2D
	if vision:
		vision.set_deferred("monitoring", false)
		vision.set_deferred("monitorable", false)
	var label: Label = enemy.get_node_or_null("DiscoverLabel") as Label
	if label:
		label.hide()
	var timer: Timer = enemy.get_node_or_null("AnimationTimer") as Timer
	if timer:
		timer.stop()

	# 设置爆头死亡第一帧
	enemy._refresh_sprite_with_index(enemy.headshot_char_index_1)
	_pause_frames_left = enemy.headshot_pause_frames
	_phase = Phase.ANIM
	_fallen_sound_played = false

	print("[敵人] 进入爆头死亡状态（动画播放中）")


func process_update(_delta: float) -> void:
	var enemy: Node2D = character

	match _phase:
		Phase.ANIM:
			# 第一帧显示→进入暂停
			_phase = Phase.PAUSE

		Phase.PAUSE:
			if _pause_frames_left > 0:
				_pause_frames_left -= 1
				return

			# 暂停结束 → 切到最终死亡帧
			_phase = Phase.DONE
			enemy._refresh_sprite_with_index(enemy.headshot_char_index_2)
			# 播放倒地音效
			enemy._play_sound(enemy.headshot_fall_sound)
			# 注册到全局尸体列表
			enemy._register_corpse()
			# 动画完成，现在可以安全关闭 StateMachine
			var sm: Node = enemy.get_node_or_null("StateMachine")
			if sm:
				sm.set_process(false)
				sm.set_physics_process(false)
			print("[敵人] 爆头死亡动画完成（尸体保留）")

		Phase.DONE:
			pass  # 永久保持


func physics_update(_delta: float) -> void:
	pass  # 尸体不受物理影响
