extends Node
## 游戏启动器 — 场景加载时初始化玩家数据 + 创建 CharacterSwitchManager
##
## 联机模式：等待 Lobby.start_game 信号 → 通过 MultiplayerSpawner 生成玩家
## 单机模式：保持原有逻辑


func _ready() -> void:
	if Lobby.is_online():
		_init_network_game()
	else:
		_init_singleplayer_game()


func _init_singleplayer_game() -> void:
	Global.try_load_or_init()
	print("[GameInit] 单机初始化完成 | debug=%s | HP=%.0f | team=%d | checkpoint=%s" % [
		Global.debug_enabled, Global.player_hp, Global.get_team_size(),
		"有" if not Global.checkpoint.is_empty() else "无"
	])
	_spawn_switch_manager()
	_spawn_network_support()


func _spawn_network_support() -> void:
	## 联机模式：创建网络同步节点
	if not NetworkManager.is_online():
		return
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return

	# NetworkSpawner — 玩家生成和位置同步
	_spawn_syncer(tree, "NetworkSpawner", "res://script/network_spawner.gd")
	# NetworkEnemySyncer — 敌人状态同步
	_spawn_syncer(tree, "NetworkEnemySyncer", "res://script/network_enemy_syncer.gd")
	# NetworkPickupSyncer — 武器掉落物同步
	_spawn_syncer(tree, "NetworkPickupSyncer", "res://script/network_pickup_syncer.gd")


func _spawn_syncer(tree: SceneTree, name_str: String, script_path: String) -> void:
	if tree.current_scene.find_child(name_str, true, false):
		return
	if not ResourceLoader.exists(script_path):
		return
	var scr: Script = load(script_path) as Script
	var node := Node.new()
	node.set_script(scr)
	node.name = name_str
	tree.current_scene.call_deferred("add_child", node)


func _init_network_game() -> void:
	## 联机模式：通知 Host 本 peer 已加载，等待 game_started 信号
	print("[GameInit] 联机模式 — peer_id=%d is_server=%s" % [multiplayer.get_unique_id(), multiplayer.is_server()])

	# 连接 Lobby.game_started 信号（start_game RPC 触发后 emit）
	var cb: Callable = _on_start_game
	if not Lobby.game_started.is_connected(cb):
		Lobby.game_started.connect(cb)

	# 连接断连信号：移除离线的玩家节点
	var dc_cb: Callable = _on_player_disconnected
	if not Lobby.player_disconnected.is_connected(dc_cb):
		Lobby.player_disconnected.connect(dc_cb)

	# 通知 Host 本 peer 已加载地图
	Lobby.player_loaded.rpc_id(1)


func _on_player_disconnected(peer_id: int) -> void:
	## 玩家断连：移除对应的 Player 节点
	print("[GameInit] 玩家 %d 断连，移除 Player 节点" % peer_id)
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var player_name := "Player%d" % peer_id
	var container: Node = tree.current_scene.get_node_or_null("DecorLayer/Players")
	if container:
		var player: Node = container.get_node_or_null(NodePath(player_name))
		if player:
			player.queue_free()
			print("[GameInit] %s 已移除" % player_name)


func _on_start_game() -> void:
	## Host 广播 start_game 后，Host 为每个 peer 创建 Player
	print("[GameInit] game_started! peer=%d is_server=%s" % [multiplayer.get_unique_id(), multiplayer.is_server()])

	# 初始化玩家数据（从 Global 读取初始数据）
	if multiplayer.is_server():
		Global.try_load_or_init()

	# Host 为所有 peer 生成玩家（通过 RPC 在所有 peer 上创建）
	if multiplayer.is_server():
		var idx: int = 0
		for peer_id: int in Lobby.players:
			var pos: Vector2 = Vector2(-349 + idx * 48, -68)
			idx += 1
			_create_player.rpc(peer_id, pos)


## 在所有 peer 上创建一个 Player 节点
@rpc("call_local", "reliable")
func _create_player(peer_id: int, spawn_pos: Vector2) -> void:
	print("[GameInit] _create_player: peer=%d pos=%s" % [peer_id, spawn_pos])

	var player_scene: PackedScene = load("res://object/player.tscn") as PackedScene
	if not player_scene:
		printerr("[GameInit] 无法加载 Player 场景")
		return

	var player: CharacterBody2D = player_scene.instantiate()
	player.name = "Player%d" % peer_id
	player.set_multiplayer_authority(peer_id)
	player.position = spawn_pos

	var tree := get_tree()
	if tree and tree.current_scene:
		var container: Node = tree.current_scene.get_node_or_null("DecorLayer/Players")
		if container:
			container.add_child(player, true)
			print("[GameInit] Player%d 已创建 (authority=%d)" % [peer_id, peer_id])
		else:
			printerr("[GameInit] 未找到 Players 容器")


func _spawn_switch_manager() -> void:
	## 如果队伍 > 1人且场景中不存在，自动创建 CharacterSwitchManager
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var existing: Node = tree.current_scene.find_child("CharacterSwitchManager", true, false)
	if existing:
		return
	var script_path := "res://script/character_switch_manager.gd"
	if not ResourceLoader.exists(script_path):
		return
	var mgr_script: Script = load(script_path) as Script
	var mgr := Node.new()
	mgr.set_script(mgr_script)
	mgr.name = "CharacterSwitchManager"
	# 延迟添加，避免在场景初始化期间 add_child
	tree.current_scene.call_deferred("add_child", mgr)
	var log_cb: Callable = func(): print("[GameInit] CharacterSwitchManager 已创建 team=%d" % Global.get_team_size())
	log_cb.call_deferred()
