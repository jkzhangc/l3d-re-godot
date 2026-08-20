extends Node
## 主项目联机连接层（Host 权威 v2.1）。
## 只负责 ENet、握手、玩家列表和场景 ready；游戏实体由 NetworkWorld 管理。

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal connection_established
signal connection_failed
signal server_disconnected
signal handshake_completed
signal player_list_changed
signal game_scene_ready_received(peer_id: int, scene_path: String)

const PROTOCOL_VERSION := "l3d_main_v2_combat_rpc"
const DEFAULT_PORT := 27015
const MAX_CLIENTS := 4

var is_host := false
var my_peer_id := 1
var player_name := "玩家"
var handshake_ok := false
var active_scene_path := ""

var _player_names: Dictionary = {}
var _pending_scene_ready: Dictionary = {}
var _signals_connected := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func has_network() -> bool:
	return multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)

func is_online_session() -> bool:
	return has_network() and handshake_ok

func host_game(port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = true
	my_peer_id = multiplayer.get_unique_id()
	handshake_ok = true
	_player_names = {my_peer_id: _sanitize_name(player_name)}
	_connect_multiplayer_signals()
	player_list_changed.emit()
	print("[Net] HOST listening port=%d peer_id=%d protocol=%s" % [port, my_peer_id, PROTOCOL_VERSION])
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	is_host = false
	my_peer_id = multiplayer.get_unique_id()
	handshake_ok = false
	_connect_multiplayer_signals()
	print("[Net] CLIENT connecting %s:%d" % [address, port])
	return OK

func leave() -> void:
	_disconnect_multiplayer_signals()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	is_host = false
	my_peer_id = 1
	handshake_ok = false
	active_scene_path = ""
	_player_names.clear()
	_pending_scene_ready.clear()
	player_list_changed.emit()

func get_player_name(peer_id: int) -> String:
	return str(_player_names.get(peer_id, "玩家%d" % peer_id))

func get_player_names() -> Dictionary:
	return _player_names.duplicate()

func get_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for key: Variant in _player_names.keys():
		result.append(int(key))
	result.sort()
	return result

# ---------------------------------------------------------------- handshake

@rpc("any_peer", "call_remote", "reliable")
func hello(version: String, name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		return
	if version != PROTOCOL_VERSION:
		printerr("[Net] reject peer=%d protocol=%s expected=%s" % [sender, version, PROTOCOL_VERSION])
		multiplayer.disconnect_peer(sender)
		return
	_player_names[sender] = _sanitize_name(name)
	print("[Net] HANDSHAKE_OK peer=%d name=%s" % [sender, _player_names[sender]])
	hello_ack.rpc_id(sender, PROTOCOL_VERSION, _player_names.duplicate())
	player_list.rpc(_player_names.duplicate())
	player_list_changed.emit()
	handshake_completed.emit()

@rpc("authority", "call_remote", "reliable")
func hello_ack(version: String, names: Dictionary) -> void:
	if version != PROTOCOL_VERSION:
		printerr("[Net] bad handshake ack protocol=%s" % version)
		return
	handshake_ok = true
	_player_names = names.duplicate()
	my_peer_id = multiplayer.get_unique_id()
	print("[Net] HANDSHAKE_OK client peer=%d players=%d" % [my_peer_id, _player_names.size()])
	player_list_changed.emit()
	handshake_completed.emit()

@rpc("authority", "call_remote", "reliable")
func player_list(names: Dictionary) -> void:
	_player_names = names.duplicate()
	player_list_changed.emit()

# ---------------------------------------------------------------- scene lifecycle

@rpc("authority", "call_local", "reliable")
func start_game(scene_path: String) -> void:
	active_scene_path = scene_path
	print("[Net] START_GAME %s" % scene_path)
	call_deferred("_change_scene_safely", scene_path)

func _change_scene_safely(scene_path: String) -> void:
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		printerr("[Net] CHANGE_SCENE_FAILED path=%s error=%s" % [scene_path, error_string(err)])

@rpc("any_peer", "call_remote", "reliable")
func report_game_scene_ready(scene_path: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _player_names.has(sender):
		return
	if scene_path != active_scene_path:
		printerr("[Net] ignore scene-ready peer=%d path=%s expected=%s" % [sender, scene_path, active_scene_path])
		return
	_pending_scene_ready[sender] = scene_path
	game_scene_ready_received.emit(sender, scene_path)

func take_pending_scene_ready(scene_path: String) -> Array[int]:
	var result: Array[int] = []
	for value: Variant in _pending_scene_ready.keys():
		var peer_id := int(value)
		if str(_pending_scene_ready[value]) == scene_path:
			result.append(peer_id)
			_pending_scene_ready.erase(value)
	return result

func clear_pending_scene_ready(peer_id: int) -> void:
	_pending_scene_ready.erase(peer_id)

# ---------------------------------------------------------------- signals

func _connect_multiplayer_signals() -> void:
	if _signals_connected:
		return
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_signals_connected = true

func _disconnect_multiplayer_signals() -> void:
	if not _signals_connected:
		return
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	_signals_connected = false

func _on_connected_to_server() -> void:
	print("[Net] TRANSPORT_CONNECTED")
	hello.rpc_id(1, PROTOCOL_VERSION, _sanitize_name(player_name))
	connection_established.emit()

func _on_connection_failed() -> void:
	printerr("[Net] CONNECTION_FAILED")
	leave()
	connection_failed.emit()

func _on_server_disconnected() -> void:
	printerr("[Net] SERVER_DISCONNECTED")
	leave()
	server_disconnected.emit()

func _on_peer_connected(peer_id: int) -> void:
	if is_host:
		print("[Net] PEER_CONNECTED peer=%d" % peer_id)
		peer_joined.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return
	_player_names.erase(peer_id)
	_pending_scene_ready.erase(peer_id)
	print("[Net] PEER_DISCONNECTED peer=%d" % peer_id)
	player_list.rpc(_player_names.duplicate())
	player_list_changed.emit()
	peer_left.emit(peer_id)

func _sanitize_name(value: String) -> String:
	var result := value.strip_edges()
	if result.is_empty():
		return "玩家"
	return result.left(16)