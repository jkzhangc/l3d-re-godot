extends State
## 未发现玩家 — 原地不动，每帧主动轮询视野内是否有玩家


func enter() -> void:
	character.update_moving(false)
	character.velocity = Vector2.ZERO


func process_update(_delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character

	# 主动轮询 VisionArea 内重叠的 body（比 body_entered 信号更可靠）
	var vision: Area2D = enemy.get_node_or_null("VisionArea") as Area2D
	if not vision:
		return

	var bodies: Array[Node2D] = vision.get_overlapping_bodies()
	for body: Node2D in bodies:
		# 检查是否为玩家（仅玩家有 get_weapon_data 方法）
		if enemy._is_player_body(body):
			# 扇形视野检测
			if enemy._is_in_vision_cone(body):
				enemy._player_in_sight = true
				enemy._player_ref = body
				print("[敵人] 在视野中发现玩家！")
				transition_requested.emit("Discover")
				return


func physics_update(_delta: float) -> void:
	character.move_and_slide()
