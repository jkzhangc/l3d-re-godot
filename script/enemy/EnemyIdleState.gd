extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 执行发现判定
## 职责：空闲状态：随机漫游避免站在原地发呆，并主动轮询视野锥以切换 Discover。
## 依赖：State、enemy 实体、VisionArea

## 仅在实体未死亡且无目标时轮询视野；Host 执行发现判定，Client 不自行改变 AI 状态。
## 未发现玩家时随机漫游，避免所有丧尸站着发呆导致街道显得空且死板。

var _wander_dir: Vector2 = Vector2.ZERO
var _wander_timer: float = 0.0
var _wander_target: Vector2 = Vector2.ZERO

func enter() -> void:
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	_reset_wander()


func _reset_wander() -> void:
	var angle: float = randf_range(0.0, TAU)
	_wander_dir = Vector2.RIGHT.rotated(angle)
	_wander_target = character.global_position + _wander_dir * randf_range(40.0, 120.0)
	_wander_timer = randf_range(1.2, 3.2)


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_reset_wander()

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


func physics_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	if enemy._player_ref != null and enemy._is_player_body(enemy._player_ref):
		return

	var wander_speed: float = 24.0
	if _wander_dir == Vector2.ZERO:
		_reset_wander()

	var next_pos: Vector2 = enemy.global_position + _wander_dir * wander_speed * delta
	if not _can_walk_toward(next_pos):
		_reset_wander()
		next_pos = enemy.global_position + _wander_dir * wander_speed * delta

	enemy.velocity = _wander_dir * wander_speed
	enemy.update_facing_from_direction(_wander_dir)
	enemy.update_moving(true)
	enemy.move_with_corner_assist()

	if enemy.global_position.distance_to(_wander_target) < 10.0:
		_reset_wander()


func _can_walk_toward(pos: Vector2) -> bool:
	var line: Dictionary = {}
	line["pos"] = pos
	var tree: SceneTree = character.get_tree()
	if not tree:
		return true

	# 只做最简单的“点位是否可走”检查：避免空中/墙上巡逻；不做复杂地图扫描。
	for tm: TileMapLayer in tree.get_nodes_in_group("tilemap"):
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		# 无 physics layer 的 TileSet（纯视觉图块集）跳过，否则 get_collision_polygons_count(0)
		# 会每格刷 "Index p_layer_id = 0 is out of bounds"（第四关 Map0146 曾刷数千条）。
		if tm.tile_set.get_physics_layers_count() == 0:
			continue
		var local_pos: Vector2 = tm.to_local(pos)
		var coords: Vector2i = tm.local_to_map(local_pos)
		var tile_data: TileData = tm.get_cell_tile_data(coords)
		if tile_data and tile_data.get_collision_polygons_count(0) > 0:
			return false
	return true
