extends State
## 追击玩家 — 直接朝玩家移动


func enter() -> void:
	character.update_moving(true)


func process_update(_delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	var player: Node2D = enemy._player_ref
	if not player:
		transition_requested.emit("Idle")
		return
	# 攻击触发矩形 — 跟随敌人朝向旋转
	var fw: Vector2 = enemy.get_facing_vector()
	var rect_center: Vector2 = enemy.global_position + fw * enemy.attack_range_forward_offset
	var rel: Vector2 = player.global_position - rect_center
	var rt: Vector2 = Vector2(fw.y, -fw.x)
	var lx: float = abs(rel.dot(rt))
	var ly: float = abs(rel.dot(fw))
	if lx <= enemy.attack_range.x / 2.0 and ly <= enemy.attack_range.y / 2.0:
		transition_requested.emit("Attack")
		return


func physics_update(delta: float) -> void:
	var enemy: Node2D = character
	var player: Node2D = enemy._player_ref
	if not player:
		return

	var move_dir: Vector2 = (player.global_position - enemy.global_position).normalized()
	character.update_facing_from_direction(move_dir)
	var motion: Vector2 = move_dir * enemy.move_speed * delta
	character.move_and_collide(motion)
