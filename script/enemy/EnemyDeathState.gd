extends State
## 死亡状态关闭碰撞/视野并保留尸体；是否销毁由 Host 的尸体管理策略决定。
## 普通死亡状态 — 显示死亡精灵 (char_idx=4)，尸体保留在地图上
##
## 禁用碰撞和视野，精灵保持死亡帧不动

func enter() -> void:
	var enemy: Node2D = character
	enemy.update_moving(false)
	enemy.velocity = Vector2.ZERO

	# 手动清理碰撞和视野
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

	# 设置死亡精灵
	enemy._refresh_sprite_with_index(enemy.death_char_index)

	# 注册到全局尸体列表
	enemy._register_corpse()

	print("[敵人] 进入普通死亡状态（尸体保留）")


func process_update(_delta: float) -> void:
	pass  # 尸体不处理任何逻辑


func physics_update(_delta: float) -> void:
	pass  # 尸体不受物理影响
