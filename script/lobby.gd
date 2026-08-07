extends Node
## Lobby Autoload — 联机连接管理
##
## 负责：创建/加入房间、玩家列表、场景加载协调
## 参考：Godot 4.6 官方 Lobby 示例（high_level_multiplayer.rst 359-627 行）


# ═══════════════════════════════════════
# 信号
# ═══════════════════════════════════════
signal player_connected(peer_id: int, player_info: Dictionary)
signal player_disconnected(peer_id: int)
signal server_disconnected
signal game_started                   ## 所有玩家就绪，Host 广播后触发


# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════
const PORT: int = 27015
const MAX_CONNECTIONS: int = 4
const DEFAULT_SERVER_IP: String = "127.0.0.1"


# ═══════════════════════════════════════
# 状态
# ═══════════════════════════════════════
var players: Dictionary = {}         ## peer_id → player_info
var player_info: Dictionary = {"name": "Player"}
var players_loaded: int = 0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ═══════════════════════════════════════
# 公共接口
# ═══════════════════════════════════════

## 创建游戏房间（作为 Host）
func create_game() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error: Error = peer.create_server(PORT, MAX_CONNECTIONS)
	if error != OK:
		printerr("[Lobby] 创建服务器失败: %d" % error)
		return error
	multiplayer.multiplayer_peer = peer
	players[1] = player_info
	player_connected.emit(1, player_info)
	print("[Lobby] 房间已创建 — 端口 %d, 最大 %d 人" % [PORT, MAX_CONNECTIONS])
	return OK


## 加入游戏房间（作为 Client）
func join_game(address: String = DEFAULT_SERVER_IP) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error: Error = peer.create_client(address, PORT)
	if error != OK:
		printerr("[Lobby] 连接失败: %s:%d (err=%d)" % [address, PORT, error])
		return error
	multiplayer.multiplayer_peer = peer
	print("[Lobby] 正在连接 %s:%d ..." % [address, PORT])
	return OK


## 断开并重置网络状态
func remove_multiplayer_peer() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	players_loaded = 0
	print("[Lobby] 网络已断开")


## 检查当前是否在联机模式（非 OfflineMultiplayerPeer）
func is_online() -> bool:
	return not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


# ═══════════════════════════════════════
# RPC — 场景加载 + 游戏开始协调
# ═══════════════════════════════════════

## Host 调用：通知所有 peer 加载指定场景
@rpc("call_local", "reliable")
func load_game(game_scene_path: String) -> void:
	print("[Lobby] 加载游戏场景: %s" % game_scene_path)
	get_tree().change_scene_to_file(game_scene_path)


## 每个 peer 加载完场景后调用：通知 Host 自己就绪
@rpc("any_peer", "call_local", "reliable")
func player_loaded() -> void:
	if multiplayer.is_server():
		players_loaded += 1
		print("[Lobby] 玩家就绪: %d/%d" % [players_loaded, players.size()])
		if players_loaded == players.size():
			_start_game()
			players_loaded = 0


func _start_game() -> void:
	print("[Lobby] 所有玩家就绪，开始游戏！")
	start_game.rpc()


## Host 广播：游戏正式开始（game_init.gd 监听 game_started 信号来 spawn 玩家）
@rpc("call_local", "reliable")
func start_game() -> void:
	print("[Lobby] start_game RPC 收到")
	game_started.emit()


# ═══════════════════════════════════════
# 连接回调
# ═══════════════════════════════════════

func _on_player_connected(id: int) -> void:
	print("[Lobby] 新玩家已连接: %d — 发送注册" % id)
	_register_player.rpc_id(id, player_info)


@rpc("any_peer", "reliable")
func _register_player(new_player_info: Dictionary) -> void:
	var new_player_id: int = multiplayer.get_remote_sender_id()
	players[new_player_id] = new_player_info
	print("[Lobby] 玩家已注册: %d (当前 %d 人)" % [new_player_id, players.size()])
	player_connected.emit(new_player_id, new_player_info)


func _on_player_disconnected(id: int) -> void:
	print("[Lobby] 玩家已断开: %d" % id)
	players.erase(id)
	player_disconnected.emit(id)


func _on_connected_ok() -> void:
	var peer_id: int = multiplayer.get_unique_id()
	players[peer_id] = player_info
	print("[Lobby] 连接成功！我的 ID: %d" % peer_id)
	player_connected.emit(peer_id, player_info)


func _on_connected_fail() -> void:
	printerr("[Lobby] 连接失败！")
	remove_multiplayer_peer()


func _on_server_disconnected() -> void:
	print("[Lobby] 服务器断开！")
	remove_multiplayer_peer()
	players.clear()
	server_disconnected.emit()
