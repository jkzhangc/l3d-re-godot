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
## 大厅角色选择是 Host 权威的结构性状态；变更后广播完整表。
signal player_character_list_changed
signal player_character_selection_rejected(reason: String)
signal game_scene_ready_received(peer_id: int, scene_path: String)
## 场景内 NetworkWorld 必须在真正换图前立即停止发送 RPC，避免旧节点路径的在途包命中已释放场景。
signal scene_transition_started(scene_path: String)

const PROTOCOL_VERSION := "l3d_main_v2_combat_rpc"
const DEFAULT_PORT := 27015
const MAX_CLIENTS := 4
## 给 LAN 上已发送的 scene-RPC 一小段排空时间；切图时双方仍保留旧 NetworkWorld，随后再同时释放。
const SCENE_TRANSITION_FLUSH_SECONDS := 0.25
const DEFAULT_CHARACTER_PATH := CharacterCatalog.DEFAULT_CHARACTER_PATH

var is_host := false
var my_peer_id := 1
var player_name := "玩家"
var handshake_ok := false
var active_scene_path := ""

var _player_names: Dictionary = {}
## peer_id -> CharacterData 资源路径。只接受由本机角色目录生成的白名单项。
var _player_character_paths: Dictionary = {}
var _allowed_character_paths: Dictionary = {} # resource_path -> display name
var _pending_scene_ready: Dictionary = {}
## 切图前由 Client 回传的静默确认。Host 等待此确认后才释放旧场景，
## 防止客户端旧 NetworkWorld 的在途 RPC 命中 Host 已重建的新场景路径。
var _pending_scene_transition_acks: Dictionary = {}
var _scene_transition_serial: int = 0
## 跨地图持续存在的权威玩家数据。只有 Host 写入；客户端仅缓存 Host 快照用于表现。
## 绝不能把这些数据放进 NetworkWorld，因为场景切换会释放 NetworkWorld。
var _session_player_states: Dictionary = {} # peer_id -> PlayerState
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
	_player_character_paths = {my_peer_id: _get_default_character_path()}
	_session_player_states.clear()
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
	_session_player_states.clear()
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
	_player_character_paths.clear()
	_pending_scene_ready.clear()
	_pending_scene_transition_acks.clear()
	_scene_transition_serial = 0
	_session_player_states.clear()
	player_list_changed.emit()

func get_player_name(peer_id: int) -> String:
	return str(_player_names.get(peer_id, "玩家%d" % peer_id))

func get_player_names() -> Dictionary:
	return _player_names.duplicate()

func get_player_character_path(peer_id: int) -> String:
	return str(_player_character_paths.get(peer_id, ""))


func get_player_character_paths() -> Dictionary:
	return _player_character_paths.duplicate()


func get_character_display_name(character_path: String) -> String:
	_ensure_character_whitelist()
	return str(_allowed_character_paths.get(character_path, "未选择"))


func get_available_character_paths() -> Array[String]:
	_ensure_character_whitelist()
	var paths: Array[String] = []
	for value: Variant in _allowed_character_paths.keys():
		paths.append(str(value))
	paths.sort()
	return paths


func are_all_players_character_selected() -> bool:
	if _player_names.is_empty():
		return false
	for value: Variant in _player_names.keys():
		if get_player_character_path(int(value)).is_empty():
			return false
	return true


## UI 只能调用这个入口：Client 发请求，Host 在本地执行同一套验证。
func request_local_character_selection(character_path: String) -> bool:
	if not handshake_ok:
		return false
	if is_host:
		return _apply_host_character_selection(my_peer_id, character_path, false)
	request_character_selection.rpc_id(1, character_path)
	return true


func get_peer_ids() -> Array[int]:
	var result: Array[int] = []
	for key: Variant in _player_names.keys():
		result.append(int(key))
	result.sort()
	return result

func get_session_player_state(peer_id: int) -> PlayerState:
	return _session_player_states.get(peer_id) as PlayerState


func set_session_player_state(peer_id: int, state: PlayerState) -> void:
	if peer_id <= 0 or not state:
		return
	_session_player_states[peer_id] = state


func remove_session_player_state(peer_id: int) -> void:
	_session_player_states.erase(peer_id)

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
	hello_ack.rpc_id(sender, PROTOCOL_VERSION, _player_names.duplicate(), _player_character_paths.duplicate())
	player_list.rpc(_player_names.duplicate())
	player_character_list.rpc(_player_character_paths.duplicate())
	player_list_changed.emit()
	handshake_completed.emit()

@rpc("authority", "call_remote", "reliable")
func hello_ack(version: String, names: Dictionary, character_paths: Dictionary) -> void:
	if version != PROTOCOL_VERSION:
		printerr("[Net] bad handshake ack protocol=%s" % version)
		return
	handshake_ok = true
	_player_names = names.duplicate()
	_player_character_paths = character_paths.duplicate()
	my_peer_id = multiplayer.get_unique_id()
	print("[Net] HANDSHAKE_OK client peer=%d players=%d" % [my_peer_id, _player_names.size()])
	player_list_changed.emit()
	player_character_list_changed.emit()
	handshake_completed.emit()

@rpc("authority", "call_remote", "reliable")
func player_list(names: Dictionary) -> void:
	_player_names = names.duplicate()
	player_list_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func request_character_selection(character_path: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _player_names.has(sender):
		return
	_apply_host_character_selection(sender, character_path, true)


@rpc("authority", "call_remote", "reliable")
func player_character_list(character_paths: Dictionary) -> void:
	_player_character_paths = character_paths.duplicate()
	player_character_list_changed.emit()


@rpc("authority", "call_remote", "reliable")
func character_selection_rejected(reason: String) -> void:
	player_character_selection_rejected.emit(reason)


func _apply_host_character_selection(peer_id: int, character_path: String, notify_requester: bool) -> bool:
	if not is_host or not _player_names.has(peer_id):
		return false
	_ensure_character_whitelist()
	if not _allowed_character_paths.has(character_path):
		_reject_character_selection(peer_id, "角色无效或当前不可用", notify_requester)
		return false
	## 允许多个 peer 选择同一个白名单角色；仍由 Host 写入并广播完整角色表。
	_player_character_paths[peer_id] = character_path
	print("[Net] CHARACTER_SELECTED peer=%d character=%s" % [peer_id, character_path])
	player_character_list_changed.emit()
	if has_network() and not multiplayer.get_peers().is_empty():
		player_character_list.rpc(_player_character_paths.duplicate())
	return true


func _reject_character_selection(peer_id: int, reason: String, notify_requester: bool) -> void:
	print("[Net] CHARACTER_SELECT_REJECT peer=%d reason=%s" % [peer_id, reason])
	if notify_requester and peer_id > 1 and has_network():
		character_selection_rejected.rpc_id(peer_id, reason)
	elif peer_id == my_peer_id:
		player_character_selection_rejected.emit(reason)


func _ensure_character_whitelist() -> void:
	if not _allowed_character_paths.is_empty():
		return
	## 必须与单人角色选择共用目录：Host 白名单是客户端选择请求的唯一权威来源。
	for character: CharacterData in CharacterCatalog.load_available_characters():
		_allowed_character_paths[character.resource_path] = character.character_name
	if _allowed_character_paths.is_empty():
		push_error("[Net] 角色白名单为空；请检查 CharacterCatalog 的正式角色资源")


func _get_default_character_path() -> String:
	_ensure_character_whitelist()
	if _allowed_character_paths.has(DEFAULT_CHARACTER_PATH):
		return DEFAULT_CHARACTER_PATH
	var paths := get_available_character_paths()
	return paths[0] if not paths.is_empty() else ""

# ---------------------------------------------------------------- scene lifecycle

@rpc("authority", "call_local", "reliable")
func start_game(scene_path: String) -> void:
	active_scene_path = scene_path
	_scene_transition_serial += 1
	var transition_serial := _scene_transition_serial
	_pending_scene_transition_acks.clear()
	## 第一阶段：双方保留旧场景，但立即令旧 NetworkWorld 静默。
	## Client 只能确认静默，不能自行提前切图；否则 Host 先后顺序不同仍会让旧 RPC 打到已释放的节点路径。
	scene_transition_started.emit(scene_path)
	print("[Net] START_GAME %s serial=%d (flush=%.2fs)" % [scene_path, transition_serial, SCENE_TRANSITION_FLUSH_SECONDS])
	if is_host:
		call_deferred("_host_commit_scene_transition", scene_path, transition_serial)
	else:
		scene_transition_ack.rpc_id(1, transition_serial, scene_path)


func _host_commit_scene_transition(scene_path: String, transition_serial: int) -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if not tree:
		return
	var deadline := Time.get_ticks_msec() + 900
	while is_inside_tree() and transition_serial == _scene_transition_serial and not _have_all_scene_transition_acks():
		if Time.get_ticks_msec() >= deadline:
			print("[Net] SCENE_TRANSITION_ACK_TIMEOUT serial=%d acked=%d expected=%d" % [transition_serial, _pending_scene_transition_acks.size(), multiplayer.get_peers().size()])
			break
		await tree.create_timer(0.02).timeout
	if not is_inside_tree() or transition_serial != _scene_transition_serial:
		return
	## 第二阶段：同一个可靠 RPC 让所有同意静默的 peer 一起开始短暂 flush 后再释放旧场景。
	print("[Net] SCENE_TRANSITION_COMMIT serial=%d" % transition_serial)
	scene_transition_commit.rpc(scene_path, transition_serial)


@rpc("authority", "call_local", "reliable")
func scene_transition_commit(scene_path: String, transition_serial: int) -> void:
	if transition_serial != _scene_transition_serial or scene_path != active_scene_path:
		return
	call_deferred("_change_scene_after_flush", scene_path, transition_serial)


func _change_scene_after_flush(scene_path: String, transition_serial: int) -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if not tree:
		return
	await tree.create_timer(SCENE_TRANSITION_FLUSH_SECONDS).timeout
	if not is_inside_tree() or transition_serial != _scene_transition_serial:
		return
	_change_scene_safely(scene_path)


@rpc("any_peer", "call_remote", "reliable")
func scene_transition_ack(transition_serial: int, scene_path: String) -> void:
	if not is_host or transition_serial != _scene_transition_serial or scene_path != active_scene_path:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _player_names.has(sender):
		return
	_pending_scene_transition_acks[sender] = true
	print("[Net] SCENE_TRANSITION_ACK peer=%d serial=%d" % [sender, transition_serial])


func _have_all_scene_transition_acks() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	for peer_id: int in multiplayer.get_peers():
		if not _pending_scene_transition_acks.get(peer_id, false):
			return false
	return true

func request_scene_change(scene_path: String) -> void:
	## 游戏内场景切换入口：联机时由 Host 广播，客户端只向 Host 请求。
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		printerr("[Net] CHANGE_SCENE_INVALID path=%s" % scene_path)
		return
	if not is_online_session():
		call_deferred("_change_scene_safely", scene_path)
		return
	if is_host:
		start_game.rpc(scene_path)
	else:
		request_scene_change_rpc.rpc_id(1, scene_path)

@rpc("any_peer", "call_remote", "reliable")
func request_scene_change_rpc(scene_path: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _player_names.has(sender):
		return
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		printerr("[Net] CHANGE_SCENE_INVALID peer=%d path=%s" % [sender, scene_path])
		return
	print("[Net] SCENE_CHANGE_REQUEST peer=%d path=%s" % [sender, scene_path])
	start_game.rpc(scene_path)

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
	_player_character_paths.erase(peer_id)
	_pending_scene_ready.erase(peer_id)
	_pending_scene_transition_acks.erase(peer_id)
	remove_session_player_state(peer_id)
	print("[Net] PEER_DISCONNECTED peer=%d" % peer_id)
	player_list_changed.emit()
	player_character_list_changed.emit()
	# ENet 刚触发断线时，其余连接也可能正处于关闭事件队列中；延后一帧，只对仍可用的连接广播。
	call_deferred("_broadcast_player_list_after_peer_left")
	peer_left.emit(peer_id)


func _broadcast_player_list_after_peer_left() -> void:
	if not is_host or not has_network() or multiplayer.get_peers().is_empty():
		return
	player_list.rpc(_player_names.duplicate())
	player_character_list.rpc(_player_character_paths.duplicate())


func _sanitize_name(value: String) -> String:
	var result := value.strip_edges()
	if result.is_empty():
		return "玩家"
	return result.left(16)
