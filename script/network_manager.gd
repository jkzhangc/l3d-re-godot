extends Node

## ── 架构定位 ──
## 系统：联机连接层 ｜ 层：单例（autoload: Net）
## 联机：Host 权威 v2.1
## 职责：ENet 连接、握手协议、玩家名单与角色表校验、场景 ready 与安全切图协议；不管理游戏实体。
## 依赖：ENetMultiplayerPeer、UPnP；NetworkWorld 为其场景内搭档

## 主项目联机连接层（Host 权威 v2.1）。
## 只负责 ENet、握手、玩家列表和场景 ready；游戏实体由 NetworkWorld 管理。
##
## 【阅读地图】
## 1. host_game()/join_game()/leave() 管理 ENet 连接的创建与销毁；
## 2. hello → hello_ack 完成协议版本、昵称、角色表同步，handshake_ok 前不允许进入游戏；
## 3. Host 是大厅结构状态的唯一写入者：角色选择请求会经过白名单校验后再广播完整表；
## 4. start_game()/scene_transition_commit()/scene_transition_ack() 用“旧场景静默 → 短暂排空 → 同步换图”
##    的顺序规避 RPC 仍指向已释放 NetworkWorld 节点的竞态；
## 5. _session_player_states 在换图期间保存 Host 权威 PlayerState。具体玩家、敌人和掉落物的
##    生命周期、输入和快照均在场景内的 NetworkWorld 中处理。
##
## 本脚本不模拟战斗，也不相信客户端给出的资源或角色数据；它只维护联机会话的连接级事实。

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
## UPnP 自动端口映射结果（Host 专用）。映射成功时广播外部地址，
## 大厅 UI 据此提示"把该地址告诉好友"；失败时给出改用内网穿透工具的提示。
signal upnp_port_mapped(port: int, external_ip: String)
signal upnp_mapping_failed(reason: String)

const PROTOCOL_VERSION := "l3d_main_v2_combat_rpc"
const DEFAULT_PORT := 27015
const MAX_CLIENTS := 4
## 给 LAN 上已发送的 scene-RPC 一小段排空时间；切图时双方仍保留旧 NetworkWorld，随后再同时释放。
const SCENE_TRANSITION_FLUSH_SECONDS := 0.25
## UPnP 端口映射在路由器上显示的描述名。
const UPNP_MAPPING_DESCRIPTION := "nobita-l4d-udp"
const DEFAULT_CHARACTER_PATH := CharacterCatalog.DEFAULT_CHARACTER_PATH

var is_host := false
var my_peer_id := 1
var player_name := "玩家"
var handshake_ok := false
var active_scene_path := ""
## 当前场景转换的目的入口 ID；由 Host 随转换广播，供 NetworkWorld 放置玩家。
var active_arrival_id := ""
var active_arrival_position: Variant = null
## Host 当前监听的端口（host_game 写入，大厅 UI 展示真实端口而非默认值）。
var active_port := DEFAULT_PORT
## 是否在创建房间时尝试 UPnP 自动端口映射（内网穿透第一步）。大厅 UI 可关闭。
var upnp_enabled := true
var _upnp_mapped_port := 0
## UPnP discover/add_port_mapping 是阻塞调用，全部在工作线程执行；
## 结果经 call_deferred 回主线程后才发信号。leave() 触发的删映射同样异步。
var _upnp_threads: Array[Thread] = []

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

## 创建 Host（服务器也是本地玩家）。成功后立即建立本机玩家名单和默认角色记录；
## 远端玩家仍须通过 hello 握手才会出现在会话表中。
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
	active_port = port
	_player_names = {my_peer_id: _sanitize_name(player_name)}
	_player_character_paths = {my_peer_id: _get_default_character_path()}
	_session_player_states.clear()
	_connect_multiplayer_signals()
	player_list_changed.emit()
	print("[Net] HOST listening port=%d peer_id=%d protocol=%s" % [port, my_peer_id, PROTOCOL_VERSION])
	if upnp_enabled:
		_start_upnp_mapping(port)
	return OK

## 创建 Client 连接。这里只发起 ENet 连接，不代表已进入可游戏状态；
## _on_connected_to_server() 发送 hello，待 hello_ack 后 handshake_ok 才会变为 true。
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

## 无论连接处于“正在连线 / 已握手 / 已进图”哪一阶段，都将其还原为离线状态。
## 同时清理跨图 PlayerState，避免下一次会话继承上一次 Host 的权威运行时数据。
func leave() -> void:
	_disconnect_multiplayer_signals()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	is_host = false
	my_peer_id = 1
	handshake_ok = false
	active_scene_path = ""
	active_arrival_id = ""
	active_arrival_position = null
	_player_names.clear()
	_player_character_paths.clear()
	_pending_scene_ready.clear()
	_pending_scene_transition_acks.clear()
	_scene_transition_serial = 0
	_session_player_states.clear()
	if _upnp_mapped_port > 0:
		_remove_upnp_mapping_async(_upnp_mapped_port)
		_upnp_mapped_port = 0
	player_list_changed.emit()

# ---------------------------------------------------------------- UPnP 端口映射（内网穿透）

## Host 开局后尝试 UPnP 自动端口映射：在 NAT 路由器上为本机打开 UDP 端口，
## 让公网玩家可以直连。discover()/add_port_mapping() 会阻塞数百毫秒到数秒，
## 必须放进工作线程；结果经 call_deferred 回主线程后才发信号、改状态。
## 路由器不支持 UPnP 或映射被拒绝时，大厅会提示改用 frp/樱花等内网穿透工具。
func _start_upnp_mapping(port: int) -> void:
	_reap_finished_upnp_threads()
	var thread := Thread.new()
	_upnp_threads.append(thread)
	thread.start(_upnp_mapping_worker.bind(port))

func _upnp_mapping_worker(port: int) -> void:
	var upnp := UPNP.new()
	var discover_result: int = upnp.discover()
	var gateway := upnp.get_gateway() if discover_result == OK else null
	if not is_instance_valid(gateway) or not gateway.is_valid_gateway():
		call_deferred("_finish_upnp_mapping", port, false, "未发现支持 UPnP 的路由器（可改用内网穿透工具）")
		return
	var add_result: int = gateway.add_port_mapping(port, port, UPNP_MAPPING_DESCRIPTION, "UDP", 0)
	if add_result != OK:
		call_deferred("_finish_upnp_mapping", port, false, "UPnP 端口映射被拒绝（%s）" % error_string(add_result))
		return
	var external_ip := upnp.query_external_address()
	call_deferred("_finish_upnp_mapping", port, true, external_ip)

func _finish_upnp_mapping(port: int, ok: bool, info: String) -> void:
	if ok:
		_upnp_mapped_port = port
		print("[Net] UPnP 映射成功 UDP %d 外部地址=%s" % [port, info if not info.is_empty() else "未知"])
		upnp_port_mapped.emit(port, info)
	else:
		printerr("[Net] UPnP 映射失败 UDP %d：%s" % [port, info])
		upnp_mapping_failed.emit(info)

## 房间解散/离开时异步删除已建立的映射，避免路由器残留永久转发规则。
func _remove_upnp_mapping_async(port: int) -> void:
	_reap_finished_upnp_threads()
	var thread := Thread.new()
	_upnp_threads.append(thread)
	thread.start(_upnp_remove_worker.bind(port))

func _upnp_remove_worker(port: int) -> void:
	var upnp := UPNP.new()
	if upnp.discover() != OK:
		return
	var gateway := upnp.get_gateway()
	if is_instance_valid(gateway) and gateway.is_valid_gateway():
		gateway.delete_port_mapping(port, "UDP")
		print("[Net] UPnP 已删除 UDP %d 映射" % port)

## 回收已结束的工作线程（Thread 必须被引用防止被 GC，结束后需 wait_to_finish）。
func _reap_finished_upnp_threads() -> void:
	for index: int in range(_upnp_threads.size() - 1, -1, -1):
		var thread: Thread = _upnp_threads[index]
		if thread.is_started() and not thread.is_alive():
			thread.wait_to_finish()
			_upnp_threads.remove_at(index)

func _exit_tree() -> void:
	for thread: Thread in _upnp_threads:
		# started 且已结束 → 直接回收；仍在运行 → 等待收尾（UPnP 调用自带超时）。
		if thread.is_started():
			thread.wait_to_finish()
	_upnp_threads.clear()

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

## Client → Host 的首个握手包。Host 从 RPC sender 取得 peer_id，而非相信客户端自报身份；
## 版本或昵称不合规时不把该连接写入玩家列表。
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

## Host → Client 的握手确认。完整名单和角色路径表是大厅 UI 的只读投影；
## Client 不得直接修改它们，任何选择都必须回到 request_character_selection() 请求。
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


## Client → Host 的角色选择意图。character_path 只是“候选键”，Host 会以本地目录产生的
## _allowed_character_paths 白名单复核，随后通过 player_character_list 广播最终事实。
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

## Host 发起开局的第一阶段：通知两端旧场景中的 NetworkWorld 立即停止业务 RPC。
## 真正的 change_scene 被延后到双方 scene_transition_ack 均到达之后。
@rpc("authority", "call_local", "reliable")
func start_game(scene_path: String, arrival_id: String = "", arrival_position: Variant = null, difficulty: int = -1) -> void:
	active_scene_path = scene_path
	active_arrival_id = arrival_id.strip_edges()
	active_arrival_position = arrival_position if arrival_position is Vector2 else null
	# P0-B1 难度同步：Host 把 selected_difficulty 随开局 RPC 广播，Client 写入本地 Global，
	# 两端难度倍率（hp/damage/intensity）才能一致。-1 = 不覆盖（lobby 等未选难度的调用）。
	if difficulty >= 0:
		if Global.selected_difficulty != difficulty:
			print("[Net] DIFFICULTY_SYNC %d -> %d" % [Global.selected_difficulty, difficulty])
		Global.selected_difficulty = difficulty
	_scene_transition_serial += 1
	var transition_serial := _scene_transition_serial
	_pending_scene_transition_acks.clear()
	## 第一阶段：双方保留旧场景，但立即令旧 NetworkWorld 静默。
	## Client 只能确认静默，不能自行提前切图；否则 Host 先后顺序不同仍会让旧 RPC 打到已释放的节点路径。
	scene_transition_started.emit(scene_path)
	print("[Net] START_GAME %s arrival=%s serial=%d (flush=%.2fs)" % [scene_path, active_arrival_id, transition_serial, SCENE_TRANSITION_FLUSH_SECONDS])
	if is_host:
		call_deferred("_host_commit_scene_transition", scene_path, active_arrival_id, active_arrival_position, transition_serial)
	else:
		scene_transition_ack.rpc_id(1, transition_serial, scene_path)


func _host_commit_scene_transition(scene_path: String, arrival_id: String, arrival_position: Variant, transition_serial: int) -> void:
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
	scene_transition_commit.rpc(scene_path, arrival_id, arrival_position, transition_serial)


## Host 广播切图提交。serial 使迟到的旧轮次 ACK/commit 无法影响当前场景切换。
@rpc("authority", "call_local", "reliable")
func scene_transition_commit(scene_path: String, arrival_id: String, arrival_position: Variant, transition_serial: int) -> void:
	if transition_serial != _scene_transition_serial or scene_path != active_scene_path or arrival_id != active_arrival_id:
		return
	active_arrival_position = arrival_position if arrival_position is Vector2 else null
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

func request_scene_change(scene_path: String, arrival_id: String = "", arrival_position: Variant = null) -> void:
	## 游戏内场景切换入口：联机时由 Host 广播，客户端只向 Host 请求。
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		printerr("[Net] CHANGE_SCENE_INVALID path=%s" % scene_path)
		return
	if not is_online_session():
		Global.set_pending_arrival(scene_path, arrival_id, arrival_position)
		call_deferred("_change_scene_safely", scene_path)
		return
	if is_host:
		start_game.rpc(scene_path, arrival_id, arrival_position, Global.selected_difficulty)
	else:
		request_scene_change_rpc.rpc_id(1, scene_path, arrival_id, arrival_position)

@rpc("any_peer", "call_remote", "reliable")
func request_scene_change_rpc(scene_path: String, arrival_id: String = "", arrival_position: Variant = null) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _player_names.has(sender):
		return
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		printerr("[Net] CHANGE_SCENE_INVALID peer=%d path=%s" % [sender, scene_path])
		return
	print("[Net] SCENE_CHANGE_REQUEST peer=%d path=%s arrival=%s" % [sender, scene_path, arrival_id])
	start_game.rpc(scene_path, arrival_id, arrival_position, Global.selected_difficulty)

func _change_scene_safely(scene_path: String) -> void:
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		printerr("[Net] CHANGE_SCENE_FAILED path=%s error=%s" % [scene_path, error_string(err)])

## Client/Host 的新场景 NetworkWorld 准备好后上报。Host 以该记录决定何时发送初始世界快照，
## 防止 RPC 先于接收端节点创建而丢失。
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
