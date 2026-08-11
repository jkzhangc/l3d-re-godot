extends Node
## Net —— 连接生命周期单例（autoload）。
##
## 只负责「连接 / 握手 / 房间事件 / 场景切换」，不存放任何游戏状态。
## 游戏实体状态全部放在 game 场景的实体节点上（Host 权威），
## 见 联机系统架构设计.md 第 3 / 7 节。

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connection_established
signal connection_failed
signal server_disconnected

const PROTOCOL_VERSION := "net_proto_v1"
const DEFAULT_PORT := 27015
const MAX_CLIENTS := 4

var is_host := false
var my_peer_id := 1
var player_name := "玩家"

var _player_names: Dictionary = {}  # peer_id -> name
var _signals_connected := false


func _ready() -> void:
	# 即使大厅场景暂停也要能收连接事件
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------- 连接操作

func host_game(port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	my_peer_id = multiplayer.get_unique_id()
	_player_names = {my_peer_id: player_name}
	_connect_multiplayer_signals()
	print("[Net] 已创建房间（端口 %d，我的 peer_id=%d）" % [port, my_peer_id])
	return OK


func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	_connect_multiplayer_signals()
	print("[Net] 正在加入 %s:%d ..." % [ip, port])
	return OK


func leave() -> void:
	if _signals_connected:
		_disconnect_multiplayer_signals()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	is_host = false
	my_peer_id = 1
	_player_names.clear()


# ---------------------------------------------------------------- 握手

## 客户端连上后立即调用：版本校验 + 注册名字（仅 Host 执行）。
@rpc("any_peer", "call_remote", "reliable")
func hello(version: String, name: String) -> void:
	if not is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		printerr("[Net] 版本不匹配，踢出 peer %d（%s != %s）" % [sender, version, PROTOCOL_VERSION])
		multiplayer.disconnect_peer(sender)
		return
	_player_names[sender] = name
	print("[Net] peer %d 握手成功：%s" % [sender, name])
	hello_ack.rpc_id(sender, my_peer_id, _player_names.duplicate())


## Host → 指定客户端：握手回执（告知 Host peer_id 与当前玩家名单）。
@rpc("authority", "call_remote", "reliable")
func hello_ack(_host_id: int, names: Dictionary) -> void:
	my_peer_id = multiplayer.get_unique_id()
	print("[Net] 已加入房间（我的 peer_id=%d，当前 %d 人）" % [my_peer_id, names.size()])
	_player_names = names


## Host 广播开始游戏（所有端执行场景切换）。
@rpc("authority", "call_local", "reliable")
func start_game(scene_path: String) -> void:
	print("[Net] 开始游戏：%s" % scene_path)
	get_tree().change_scene_to_file(scene_path)


# ---------------------------------------------------------------- 信号

func _connect_multiplayer_signals() -> void:
	# CLAUDE.md 提示：Godot 4.6 lambda 不能直接作为 connect 参数 → 用命名函数引用。
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_signals_connected = true


func _disconnect_multiplayer_signals() -> void:
	multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	multiplayer.connection_failed.disconnect(_on_connection_failed)
	multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	multiplayer.peer_connected.disconnect(_on_peer_connected)
	multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	_signals_connected = false


func _on_connected_to_server() -> void:
	# 客户端连上 Host：立即握手（携带版本与名字）
	hello.rpc_id(1, PROTOCOL_VERSION, player_name)
	connection_established.emit()


func _on_connection_failed() -> void:
	printerr("[Net] 连接失败")
	leave()
	connection_failed.emit()


func _on_server_disconnected() -> void:
	printerr("[Net] 与主机断开")
	leave()
	server_disconnected.emit()


func _on_peer_connected(peer_id: int) -> void:
	if is_host:
		print("[Net] peer %d 连接（等待握手）" % peer_id)
		peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if is_host:
		_player_names.erase(peer_id)
		print("[Net] peer %d 断开" % peer_id)
		peer_left.emit(peer_id)


# ---------------------------------------------------------------- 工具

func get_player_name(peer_id: int) -> String:
	return _player_names.get(peer_id, "玩家%d" % peer_id)


func get_player_names() -> Dictionary:
	return _player_names.duplicate()
