extends Node
## 网络玩家同步 — 使用 RPC 广播位置，手动管理 NetworkPlayer 节点。
##
## - Host 为所有 peer 创建 NetworkPlayer
## - 每个 Player 通过 NetworkManager RPC 广播自己的位置
## - 收到 RPC 后更新对应的 NetworkPlayer 位置

const NETWORK_PLAYER_PATH: String = "res://object/network_player.tscn"


func _ready() -> void:
	if not NetworkManager.is_online():
		return

	if multiplayer.is_server():
		# Host: 为所有 peer 创建 NetworkPlayer（跳过自己）
		for pid in NetworkManager.players:
			_create_network_player(pid)
		NetworkManager.player_connected.connect(_on_peer_connected)
		NetworkManager.player_disconnected.connect(_on_peer_disconnected)

	# 连接 RPC 信号（NetworkManager 收到位置后更新 NetworkPlayer）
	NetworkManager.recv_player_state.connect(_on_player_state)


func _create_network_player(pid: int) -> void:
	# 不为自己创建 NetworkPlayer（自己用真实的 Player）
	if pid == multiplayer.get_unique_id():
		return
	# 检查是否已存在
	var target: Node = _get_spawn_target()
	if target and target.has_node("NetworkPlayer_%d" % pid):
		return

	var scene: PackedScene = load(NETWORK_PLAYER_PATH) as PackedScene
	if not scene:
		printerr("[NetworkSpawner] 无法加载 NetworkPlayer 场景")
		return

	var np: Node = scene.instantiate()
	np.name = "NetworkPlayer_%d" % pid
	np.set("peer_id", pid)
	np.set("player_name", NetworkManager.get_player_name(pid))

	# 添加到场景
	var decor := _find_decor_layer()
	if decor:
		decor.add_child(np)
	elif target:
		target.add_child(np)

	print("[NetworkSpawner] 创建 NetworkPlayer_%d" % pid)


func _get_spawn_target() -> Node:
	return get_node_or_null("SpawnedPlayers")


func _on_peer_connected(pid: int) -> void:
	if pid != 1:
		_create_network_player(pid)


func _on_peer_disconnected(pid: int) -> void:
	_remove_network_player(pid)


func _remove_network_player(pid: int) -> void:
	var target: Node = _get_spawn_target()
	var decor := _find_decor_layer()
	for parent in [target, decor]:
		if parent:
			var np: Node = parent.get_node_or_null("NetworkPlayer_%d" % pid)
			if np:
				np.queue_free()
				return


func _on_player_state(pid: int, pos: Vector2, facing: int, hp: float, moving: bool, weapon_id: String) -> void:
	# 自己的 NetworkPlayer 完全隐藏（自己看自己是真实的 Player）
	if pid == multiplayer.get_unique_id():
		return

	# 确保 NetworkPlayer 存在
	var decor := _find_decor_layer()
	var np_name: String = "NetworkPlayer_%d" % pid
	var np: Node = null
	if decor:
		np = decor.get_node_or_null(np_name)
	if not np:
		_create_network_player(pid)
		if decor:
			np = decor.get_node_or_null(np_name)
	if not np:
		return

	np.position = pos

	# 更新精灵动画
	var sprite: Sprite2D = np.get_node_or_null("RemoteSprite")
	if sprite:
		var row_map := {0: 0, 1: 1, 2: 2, 3: 3}
		var row: int = row_map.get(facing, 0)
		if moving:
			# 简单的两帧动画：在 frame 0 和 frame 2 之间切换
			var frame: int = 0 if (Time.get_ticks_msec() / 300) % 2 == 0 else 96
			sprite.region_rect = Rect2(frame, row * 64, 48, 64)
		else:
			sprite.region_rect = Rect2(48, row * 64, 48, 64)  # 站立帧


func _find_decor_layer() -> Node:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return null
	return _find_decor_recursive(tree.current_scene)


func _find_decor_recursive(node: Node) -> Node:
	var n: String = node.name.to_lower()
	if "decor" in n:
		return node
	for child in node.get_children():
		var found := _find_decor_recursive(child)
		if found:
			return found
	return null
