extends Node
## 网络管理器 Autoload — 管理 ENet 连接、玩家加入/离开、Lobby 状态。
##
## 使用：
##   NetworkManager.host_game(9999)
##   NetworkManager.join_game("192.168.1.5", 9999)

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal game_started()  ## Host 开始游戏，所有客户端加载地图

const DEFAULT_PORT: int = 9999
const MAX_PLAYERS: int = 4

var _peer: ENetMultiplayerPeer = null
var _player_names: Dictionary = {}  ## peer_id → name

## 当前连接的玩家列表
var players: Array[int] = []  ## peer_id 列表（1 = server）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## 是否正在联机（Host 或 Client）
func is_online() -> bool:
	return _peer != null


## 是否是服务器（Host）
func is_server() -> bool:
	return _peer != null and multiplayer.is_server()


## 获取本地玩家 ID
func get_my_id() -> int:
	return multiplayer.get_unique_id()


## 创建主机
func host_game(port: int = DEFAULT_PORT) -> void:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		printerr("[NetworkManager] 创建服务器失败: %d" % err)
		_peer = null
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	players = [1]  # Host = peer ID 1
	print("[NetworkManager] 服务器已创建 (port=%d)" % port)


## 加入游戏
func join_game(address: String, port: int = DEFAULT_PORT) -> void:
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		printerr("[NetworkManager] 连接失败: %d" % err)
		_peer = null
		return
	multiplayer.multiplayer_peer = _peer
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[NetworkManager] 正在连接 %s:%d ..." % [address, port])
	# 等待连接确认
	var cb: Callable = func(): print("[NetworkManager] 连接建立完成！当前 peers: %s" % str(multiplayer.get_peers()))
	await get_tree().create_timer(0.5).timeout
	cb.call()


## 玩家状态同步信号（由 NetworkSpawner 监听）
signal recv_player_state(pid: int, pos: Vector2, facing: int, hp: float, moving: bool, weapon_id: String)

## 广播玩家状态到所有 peer
@rpc("any_peer", "unreliable_ordered", "call_remote")
func broadcast_player_state(pid: int, pos_x: float, pos_y: float, facing: int, hp: float, moving: bool, weapon_id: String) -> void:
	recv_player_state.emit(pid, Vector2(pos_x, pos_y), facing, hp, moving, weapon_id)


## 敌人状态同步
signal recv_enemy_states(states: Array)

@rpc("authority", "unreliable", "call_remote")
func broadcast_enemy_states(states: Array) -> void:
	recv_enemy_states.emit(states)


## 武器掉落物同步
signal recv_pickup_removed(pickup_path: String)

@rpc("any_peer", "reliable", "call_remote")
func remove_pickup(pickup_path: String) -> void:
	recv_pickup_removed.emit(pickup_path)


## 断开连接


func disconnect_game() -> void:
	if _peer:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	players.clear()
	_player_names.clear()
	print("[NetworkManager] 已断开")


func _on_peer_connected(id: int) -> void:
	if not id in players:
		players.append(id)
	_player_names[id] = "玩家%d" % id
	print("[NetworkManager] 玩家 %d 已连接 (总数: %d, 列表: %s)" % [id, players.size(), str(players)])
	player_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	_player_names.erase(id)
	print("[NetworkManager] 玩家 %d 已断开 (总数: %d, 剩余IDs: %s)" % [id, players.size(), str(players)])
	player_disconnected.emit(id)


## 获取玩家名称
func get_player_name(id: int) -> String:
	return _player_names.get(id, "玩家%d" % id)


## 开始游戏：Host 调用，通知所有客户端加载地图
@rpc("authority", "call_local", "reliable")
func start_game(map_path: String) -> void:
	print("[NetworkManager] 开始游戏 → %s" % map_path)
	game_started.emit()
	var tree := get_tree()
	if tree:
		var err := tree.change_scene_to_file(map_path)
		if err != OK:
			printerr("[NetworkManager] 加载地图失败: %s" % map_path)
