extends Node
## 网络敌人同步器 — Host 广播敌人状态，Client 接收并更新。
##
## 由 GameInit 在联机时自动创建。

const SYNC_INTERVAL: float = 0.1  ## 10Hz 敌人同步
var _timer: float = 0.0


func _ready() -> void:
	if not NetworkManager.is_online():
		queue_free()
		return

	if multiplayer.is_server():
		# Host: 定期广播所有敌人状态
		set_process(true)
	else:
		# Client: 监听状态更新
		NetworkManager.recv_enemy_states.connect(_on_enemy_states)


func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	_timer += delta
	if _timer < SYNC_INTERVAL:
		return
	_timer = 0.0
	_broadcast_enemy_states()


func _broadcast_enemy_states() -> void:
	var tree := get_tree()
	if not tree:
		return
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	if enemies.is_empty():
		return

	# 构建状态数组: [path_hash, x, y, facing, hp, state_hash]
	var states: Array = []
	for e in enemies:
		if not is_instance_valid(e) or e.get("_is_dead"):
			continue
		var sm: Node = e.get_node_or_null("StateMachine")
		var state_name: String = sm.current_state.name if sm and sm.current_state else "Idle"
		# 使用节点路径作为跨 peer 的唯一标识
		var node_path: String = str(e.get_path())
		states.append_array([
			node_path.hash(),
			e.global_position.x,
			e.global_position.y,
			e.get("_facing") if e.get("_facing") != null else 0,
			e.get("current_hp") if e.get("current_hp") != null else 100.0,
			state_name.hash(),
		])

	if states.is_empty():
		return

	NetworkManager.broadcast_enemy_states.rpc(states)


func _on_enemy_states(states: Array) -> void:
	# states: [id, x, y, facing, hp, state_hash, id, x, y, ...]
	var tree := get_tree()
	if not tree:
		return

	# 构建 path_hash → Node 映射
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var path_map: Dictionary = {}
	for e in enemies:
		path_map[str(e.get_path()).hash()] = e

	var i: int = 0
	while i + 5 < states.size():
		var path_hash: int = states[i]
		var x: float = states[i + 1]
		var y: float = states[i + 2]
		var facing: int = states[i + 3]
		var hp: float = states[i + 4]
		var _state_hash: int = states[i + 5]
		i += 6

		var enemy: Node = path_map.get(path_hash)
		if not enemy or not is_instance_valid(enemy):
			continue

		# 更新位置（平滑插值）
		enemy.global_position = enemy.global_position.lerp(Vector2(x, y), 0.3)
		# 更新朝向
		if enemy.get("_facing") != null:
			enemy.set("_facing", facing)
		# 更新 HP
		if enemy.get("current_hp") != null:
			enemy.set("current_hp", hp)
		# 强制刷新精灵
		if enemy.has_method("_refresh_sprite"):
			enemy._refresh_sprite()
