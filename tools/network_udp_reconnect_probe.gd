extends SceneTree

## 真实生产 ENet 大厅与可靠 RPC 重连探针；不加载 World，不证明战斗进度恢复。
## 控制口仅监听回环，认证桥由外部 runner 建立；本工具不保存配置或结果。
var _role: String = "client"
var _port: int = 28160
var _index: int = 0
var _clients: int = 2
var _net: Node
var _probe: ReconnectProbe
var _control: PacketPeerUDP
var _control_token: String = ""
var _started_usec: int = 0
var _finished: bool = false
var _finishing: bool = false
var _finish_due_usec: int = 0
var _finish_snapshot: Dictionary = {}
var _checks: int = 0
var _failures: Array[String] = []
var _events: Array = []
var _epochs: Dictionary = {}
var _reply_cache: Dictionary = {}
var _old_peer_id: int = 0
var _join_epoch: int = 1
var _drop_count: int = 0
var _join_count: int = 0
var _peer_ids: Array = []
var _last_names: Dictionary = {}
var _name_history: Dictionary = {}
var _removed_peer_ids: Array = []
var _host_starts: int = 0
var _ledger: Dictionary = {}
var _apply_by_index: Dictionary = {}
var _requests_by_epoch: Dictionary = {}
var _dedup_by_epoch: Dictionary = {}
var _requests_by_index: Dictionary = {}
var _counts_by_index: Dictionary = {}
var _busy: bool = false
var _exercise_epoch: int = 0
var _exercise_count: int = 0
var _exercise_failures_before: int = 0
var _next_seq: int = 0
var _next_send_usec: int = 0
var _reply_deadline_usec: int = 0
var _sent_requests: int = 0
var _received: int = 0
var _sent: Dictionary = {}
var _responses: Dictionary = {}
var _raw: Array = []

class ReconnectProbe extends Node:
	var diagnostic: SceneTree

	func _process(_delta: float) -> void:
		diagnostic.call("_tick")

	@rpc("any_peer", "call_remote", "reliable")
	func transaction(epoch: int, index: int, seq: int, stamp: int) -> void:
		# sender 必须在 RPC 派发栈中取出，不延后读取。
		var sender: int = multiplayer.get_remote_sender_id()
		diagnostic.call("_receive_transaction", sender, epoch, index, seq, stamp)

	@rpc("authority", "call_remote", "reliable")
	func transaction_reply(epoch: int, index: int, seq: int, stamp: int, applied_total: int) -> void:
		var sender: int = multiplayer.get_remote_sender_id()
		diagnostic.call("_receive_reply", sender, epoch, index, seq, stamp, applied_total)

func _initialize() -> void:
	_started_usec = Time.get_ticks_usec()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--udp-re-role="):
			_role = argument.trim_prefix("--udp-re-role=")
		elif argument.begins_with("--udp-re-port="):
			_port = int(argument.trim_prefix("--udp-re-port="))
		elif argument.begins_with("--udp-re-index="):
			_index = int(argument.trim_prefix("--udp-re-index="))
		elif argument.begins_with("--udp-re-clients="):
			_clients = int(argument.trim_prefix("--udp-re-clients="))
	_control_token = OS.get_environment("UDP_LAB_RE_CONTROL_TOKEN")
	call_deferred("_boot")

func _check(ok: bool, label: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append(label)
	return ok

func _event(kind: String, data: Dictionary = {}) -> void:
	var entry: Dictionary = data.duplicate(true)
	entry["type"] = kind
	entry["elapsed_ms"] = (Time.get_ticks_usec() - _started_usec) / 1000
	_events.append(entry)

func _boot() -> void:
	_net = root.get_node_or_null("Net")
	if not _check(_net != null, "生产 Net Autoload 存在"):
		_shutdown()
		return
	if not _check(_role in ["host", "client"] and _port > 0 and _port < 65536
			and _clients >= 1 and _clients <= 4 and _index >= 0 and _index < _clients,
			"启动参数有效") or not _check(not _control_token.is_empty(), "本地控制认证已配置"):
		_shutdown()
		return
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test"):
			_check(false, "禁止 --net-test 参数，必须保留生产 Net 路径")
			_shutdown()
			return
	if not _net.is_node_ready():
		await _net.ready
	_probe = ReconnectProbe.new()
	_probe.name = "UdpReconnectProbe"
	_probe.diagnostic = self
	_probe.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_probe)
	Engine.max_fps = 120
	_net.set("upnp_enabled", false)
	_net.connect("connection_established", _on_connection_established)
	_net.connect("handshake_completed", _on_handshake_completed)
	_net.connect("connection_failed", _on_connection_failed)
	_net.connect("server_disconnected", _on_server_disconnected)
	_net.connect("player_list_changed", _on_player_list_changed)
	root.multiplayer.peer_connected.connect(_on_peer_connected)
	root.multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_control = PacketPeerUDP.new()
	var bind_error: int = _control.bind(0, "127.0.0.1")
	if not _check(bind_error == OK, "控制 UDP 绑定回环临时端口"):
		_shutdown()
		return
	_net.set("player_name", "UdpReconnectHost" if _role == "host" else "UdpReconnect%d" % _index)
	var network_error: int
	if _role == "host":
		_host_starts += 1
		network_error = int(_net.call("host_game", _port))
	else:
		_join_count += 1
		network_error = int(_net.call("join_game", "127.0.0.1", _port))
	_event("host_started" if _role == "host" else "join_started", {"port": _port, "epoch": 1, "error": network_error})
	if not _check(network_error == OK, "生产 ENet 启动返回 OK"):
		_shutdown()
		return
	print("UDP_RE_READY " + JSON.stringify({"role": _role, "index": _index, "control_port": _control.get_local_port()}))

func _is_offline() -> bool:
	var peer: MultiplayerPeer = root.multiplayer.multiplayer_peer
	return (peer == null or peer is OfflineMultiplayerPeer) and not bool(_net.call("has_network"))

func _connected() -> bool:
	if _net == null or not bool(_net.call("has_network")):
		return false
	var peer: MultiplayerPeer = root.multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and bool(_net.call("is_online_session"))

func _actual_peer_id() -> int:
	if _net == null or not bool(_net.call("has_network")):
		return 0
	return root.multiplayer.get_unique_id()

func _status() -> Dictionary:
	var names: Dictionary = _net.call("get_player_names") if _net != null else {}
	var peer: MultiplayerPeer = root.multiplayer.multiplayer_peer
	var result: Dictionary = {"role": _role, "index": _index, "ok": _failures.is_empty(),
		"connected": _connected(), "has_network": bool(_net.call("has_network")) if _net != null else false,
		"handshake_ok": bool(_net.get("handshake_ok")) if _net != null else false,
		"connection_status": peer.get_connection_status() if peer != null else MultiplayerPeer.CONNECTION_DISCONNECTED,
		"offline": _is_offline() if _net != null else true, "peer_id": _actual_peer_id(),
		"old_peer_id": _old_peer_id, "peer_ids": _peer_ids.duplicate(), "names": names,
		"checks": _checks, "failures": _failures.duplicate(), "epochs": _epochs.duplicate(true),
		"events": _events.duplicate(true), "busy": _busy, "finishing": _finishing,
		"join_epoch": _join_epoch, "drop_count": _drop_count, "join_count": _join_count,
		"measurement": "真实生产 ENet 大厅/可靠 RPC；重复请求验证应用幂等，不是可靠层去重；不含 World 战斗进度恢复"}
	if _role == "host":
		result.merge({"ledger_count": _ledger.size(), "apply_by_index": _apply_by_index.duplicate(),
			"requests_by_epoch": _requests_by_epoch.duplicate(), "dedup_by_epoch": _dedup_by_epoch.duplicate(),
			"requests_by_index": _requests_by_index.duplicate(), "counts_by_index": _counts_by_index.duplicate(),
			"connected_peer_ids": Array(root.multiplayer.get_peers()) if _net != null and bool(_net.call("has_network")) else [],
			"name_history": _name_history.duplicate(true), "removed_peer_ids": _removed_peer_ids.duplicate(),
			"host_starts": _host_starts})
	return result

func _tick() -> void:
	if _finished:
		return
	if Time.get_ticks_usec() - _started_usec >= 120000000:
		_check(false, "overall_timeout_120s")
		_shutdown()
		return
	if _control != null:
		for _packet_index: int in range(32):
			if _control.get_available_packet_count() <= 0:
				break
			var packet: PackedByteArray = _control.get_packet()
			var address: String = _control.get_packet_ip()
			var source_port: int = _control.get_packet_port()
			if address != "127.0.0.1" or packet.size() > 4096:
				continue
			var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if not parsed is Dictionary:
				continue
			var command: Dictionary = parsed
			if not command.get("token") is String or str(command.get("token")) != _control_token:
				continue
			_handle_control(command, source_port)
	if _finishing:
		if Time.get_ticks_usec() >= _finish_due_usec:
			_shutdown()
		return
	if _busy:
		_exercise_tick()

func _reply(source_port: int, request_id: Variant, data: Dictionary) -> void:
	var response: Dictionary = data.duplicate(true)
	response["request_id"] = request_id
	var address_error: int = _control.set_dest_address("127.0.0.1", source_port)
	_check(address_error == OK and _control.put_packet(JSON.stringify(response).to_utf8_buffer()) == OK,
		"本地控制回复发送成功")

func _handle_control(command: Dictionary, source_port: int) -> void:
	var request_id: Variant = command.get("request_id")
	if not (request_id is String or request_id is int or request_id is float):
		return
	var key: String = JSON.stringify(request_id)
	if key.length() > 256:
		return
	var kind: String = str(command.get("type", ""))
	if kind == "status":
		_reply(source_port, request_id, _status())
		return
	if _reply_cache.has(key):
		_reply(source_port, request_id, _reply_cache[key])
		return
	var response: Dictionary = {}
	if _finishing:
		response = {"accepted": false, "error": "finishing"}
	elif kind == "finish":
		_validate_finish()
		_finishing = true
		_finish_snapshot = _status()
		_finish_due_usec = Time.get_ticks_usec() + (150000 if _role == "host" else 500000)
		response = {"accepted": true, "finishing": true, "ok": _failures.is_empty()}
	elif _role != "client":
		response = {"accepted": false, "error": "client_only"}
	elif _busy:
		response = {"accepted": false, "busy": true, "error": "exercise_busy"}
	elif kind == "drop":
		response = _drop()
	elif kind == "join":
		response = _join(command)
	elif kind == "exercise":
		response = _start_exercise(command)
	else:
		response = {"accepted": false, "error": "unknown_type"}
	if _reply_cache.size() >= 128:
		_reply_cache.erase(_reply_cache.keys()[0])
	_reply_cache[key] = response.duplicate(true)
	_reply(source_port, request_id, response)

func _drop() -> Dictionary:
	# 仅由常驻节点 _process 控制队列调用，不在任何 RPC/peer 信号栈内 leave。
	if not _check(_connected(), "drop 前真实连接且生产 hello 已完成"):
		return {"dropped": false, "error": "not_connected"}
	_old_peer_id = _actual_peer_id()
	var before_status: int = root.multiplayer.multiplayer_peer.get_connection_status()
	_net.call("leave")
	_drop_count += 1
	var offline: bool = _is_offline()
	_check(offline, "Net.leave 后 MultiplayerPeer 离线")
	_event("dropped", {"old_peer_id": _old_peer_id, "before_status": before_status,
		"offline": offline, "names": _net.call("get_player_names")})
	return {"dropped": offline, "old_peer_id": _old_peer_id, "peer_id": _actual_peer_id(),
		"offline": offline, "connected": _connected(), "drop_count": _drop_count}

func _join(command: Dictionary) -> Dictionary:
	var new_port: int = int(command.get("port", 0))
	var epoch: int = int(command.get("epoch", 2))
	if not _check(_is_offline() and _drop_count > 0, "再次 join 前已真实 leave 且离线"):
		return {"accepted": false, "error": "must_drop_first"}
	if not _check(new_port > 0 and new_port < 65536 and epoch == 2, "重连端口与 epoch 有效"):
		return {"accepted": false, "error": "invalid_join"}
	_port = new_port
	_join_epoch = epoch
	_net.set("player_name", "UdpReconnect%d" % _index)
	var error: int = int(_net.call("join_game", "127.0.0.1", _port))
	_join_count += 1
	_check(error == OK, "再次生产 Net.join_game 返回 OK")
	_event("join_started", {"epoch": epoch, "port": _port, "old_peer_id": _old_peer_id,
		"new_peer_id": _actual_peer_id(), "error": error, "connected": false})
	return {"accepted": error == OK, "connecting": error == OK, "connected": false,
		"epoch": epoch, "old_peer_id": _old_peer_id, "peer_id": _actual_peer_id(), "error": error}

func _start_exercise(command: Dictionary) -> Dictionary:
	var epoch: int = int(command.get("epoch", 0))
	var count: int = int(command.get("count", 40))
	if not _check(epoch in [1, 2] and epoch == _join_epoch and count >= 20 and count <= 200,
			"exercise epoch/count 有效"):
		return {"accepted": false, "error": "invalid_exercise"}
	if not _check(_connected() and not _epochs.has(str(epoch)), "exercise 连接已握手且 epoch 未执行"):
		return {"accepted": false, "error": "not_ready_or_repeated"}
	if epoch == 2:
		var first: Dictionary = _epochs.get("1", {})
		if not _check(bool(first.get("ok", false)) and int(first.get("count", -1)) == count
				and _old_peer_id > 1 and _actual_peer_id() != _old_peer_id, "第二阶段复用相同 seq/count 且 peer 已更换"):
			return {"accepted": false, "error": "epoch_one_or_reconnect_missing"}
	_busy = true
	_exercise_epoch = epoch
	_exercise_count = count
	_exercise_failures_before = _failures.size()
	_next_seq = 0
	_next_send_usec = Time.get_ticks_usec()
	_reply_deadline_usec = 0
	_sent_requests = 0
	_received = 0
	_sent.clear()
	_responses.clear()
	_raw.clear()
	_epochs[str(epoch)] = {"ok": false, "busy": true, "count": count}
	_event("exercise_started", {"epoch": epoch, "count": count, "peer_id": _actual_peer_id()})
	return {"accepted": true, "busy": true, "epoch": epoch, "count": count}

func _exercise_tick() -> void:
	var now: int = Time.get_ticks_usec()
	if _next_seq < _exercise_count:
		if now < _next_send_usec:
			return
		if not _check(_connected(), "发送事务时生产连接仍在线"):
			_complete_exercise()
			return
		var seq: int = _next_seq
		_sent[seq] = now
		# 故意两次应用请求；不是依赖可靠传输层消除重复消息。
		for _copy: int in range(2):
			var error: int = _probe.rpc_id(1, "transaction", _exercise_epoch, _index, seq, now)
			_check(error == OK, "可靠事务请求发送 epoch=%d seq=%d" % [_exercise_epoch, seq])
			_sent_requests += 1
		_next_seq += 1
		_next_send_usec = now + 50000
		if _next_seq == _exercise_count:
			_reply_deadline_usec = now + 10000000
		return
	if _received >= _exercise_count * 2 or now >= _reply_deadline_usec:
		_complete_exercise()

func _receive_transaction(sender: int, epoch: int, index: int, seq: int, stamp: int) -> void:
	if _finished or _finishing or _role != "host":
		return
	var names: Dictionary = _net.call("get_player_names")
	if not _check(sender > 1 and names.has(sender) and str(names.get(sender, "")) == "UdpReconnect%d" % index
			and Array(root.multiplayer.get_peers()).has(sender), "Host 事务 sender 在生产 hello 名单与真实连接中"):
		return
	if not _check(epoch in [1, 2] and index >= 0 and index < _clients and seq >= 0 and seq < 200 and stamp > 0,
			"Host 事务字段有效"):
		return
	var epoch_key: String = str(epoch)
	var index_key: String = str(index)
	var request_key: String = "%d:%d" % [epoch, index]
	_requests_by_epoch[epoch_key] = int(_requests_by_epoch.get(epoch_key, 0)) + 1
	_requests_by_index[request_key] = int(_requests_by_index.get(request_key, 0)) + 1
	# 幂等键不含 epoch 或 peer，真实重连后仍查同一应用账本。
	var ledger_key: String = "%d:%d" % [index, seq]
	if _ledger.has(ledger_key):
		_dedup_by_epoch[epoch_key] = int(_dedup_by_epoch.get(epoch_key, 0)) + 1
	else:
		_check(epoch == 1, "第二阶段不得新应用第一阶段的重复事务")
		_apply_by_index[index_key] = int(_apply_by_index.get(index_key, 0)) + 1
		_counts_by_index[index_key] = maxi(int(_counts_by_index.get(index_key, 0)), seq + 1)
		# 保存首次应用的回执值，保证不同 epoch 重提仍返回同一事务结果。
		_ledger[ledger_key] = _ledger.size() + 1
	var applied_total: int = int(_ledger[ledger_key])
	var error: int = _probe.rpc_id(sender, "transaction_reply", epoch, index, seq, stamp, applied_total)
	_check(error == OK, "Host 可靠事务回执发送 sender=%d" % sender)

func _receive_reply(sender: int, epoch: int, index: int, seq: int, stamp: int, applied_total: int) -> void:
	if _finished or _finishing or _role != "client":
		return
	if not _check(_busy and sender == 1 and epoch == _exercise_epoch and index == _index
			and seq >= 0 and seq < _exercise_count and _sent.has(seq)
			and int(_sent.get(seq, -1)) == stamp and applied_total > 0, "Client 回执身份/epoch/index/seq/stamp 匹配"):
		return
	var replies: Array = _responses.get(seq, [])
	var response: Array = [epoch, index, seq, stamp, applied_total]
	_check(replies.size() < 2, "每 seq 恰好两份应用回执")
	if not replies.is_empty():
		_check(replies[0] == response, "同 seq 两份回执完全一致")
	else:
		var rtt_ms: float = float(Time.get_ticks_usec() - stamp) / 1000.0
		_raw.append([seq, stamp, rtt_ms, applied_total])
		if epoch == 2:
			var first_raw: Array = (_epochs.get("1", {}) as Dictionary).get("raw", [])
			var previous_total: int = -1
			for row: Array in first_raw:
				if int(row[0]) == seq:
					previous_total = int(row[3])
					break
			_check(previous_total == applied_total, "重连后同事务回执与首次应用一致")
	replies.append(response)
	_responses[seq] = replies
	_received += 1

func _complete_exercise() -> void:
	var missing: Array = []
	var samples: Array = []
	var duplicate_responses: int = 0
	for seq: int in range(_exercise_count):
		var replies: Array = _responses.get(seq, [])
		if replies.size() != 2:
			missing.append({"seq": seq, "received": replies.size()})
		duplicate_responses += maxi(0, replies.size() - 1)
	for row: Array in _raw:
		samples.append(float(row[2]))
	samples.sort()
	_check(_sent_requests == _exercise_count * 2 and _received == _exercise_count * 2,
		"可靠应用请求与双回执总数完整")
	_check(missing.is_empty() and _responses.size() == _exercise_count, "每 seq 两份回执无遗漏")
	_check(duplicate_responses == _exercise_count, "预期重复应用回执数量正确")
	_epochs[str(_exercise_epoch)] = {"ok": _failures.size() == _exercise_failures_before,
		"busy": false, "sent_requests": _sent_requests, "received": _received, "unique": _responses.size(),
		"missing": missing, "expected_duplicate_responses": _exercise_count,
		"duplicate_responses": duplicate_responses, "count": _exercise_count,
		"peer_id": _actual_peer_id(), "p50_ms": _percentile(samples, 0.50),
		"p95_ms": _percentile(samples, 0.95), "p99_ms": _percentile(samples, 0.99),
		"raw_columns": ["seq", "client_stamp_usec", "first_reply_rtt_ms", "applied_total"],
		"raw": _raw.duplicate(true), "clock": "client_local_monotonic_usec"}
	_event("exercise_completed", {"epoch": _exercise_epoch, "ok": _epochs[str(_exercise_epoch)]["ok"],
		"received": _received, "unique": _responses.size()})
	_busy = false

func _percentile(sorted: Array, fraction: float) -> float:
	if sorted.is_empty():
		return -1.0
	return float(sorted[clampi(ceili(float(sorted.size()) * fraction) - 1, 0, sorted.size() - 1)])

func _on_connection_established() -> void:
	_event("transport_connected", {"epoch": _join_epoch, "peer_id": _actual_peer_id()})

func _on_handshake_completed() -> void:
	var peer_id: int = _actual_peer_id()
	if not _peer_ids.has(peer_id):
		_peer_ids.append(peer_id)
	_event("handshake_completed", {"epoch": _join_epoch, "peer_id": peer_id, "names": _net.call("get_player_names")})

func _on_connection_failed() -> void:
	_event("connection_failed", {"epoch": _join_epoch})
	if not _finishing:
		_check(false, "生产连接失败")

func _on_server_disconnected() -> void:
	# Host finish 先离房，Client 在收尾阶段收到此信号是预期行为。
	_event("server_disconnected", {"epoch": _join_epoch, "finishing": _finishing})
	if not _finishing:
		_check(false, "非收尾阶段收到 server_disconnected")

func _on_peer_connected(peer_id: int) -> void:
	_event("peer_connected", {"peer_id": peer_id})

func _on_peer_disconnected(peer_id: int) -> void:
	_event("peer_disconnected", {"peer_id": peer_id, "names": _net.call("get_player_names")})

func _on_player_list_changed() -> void:
	var names: Dictionary = _net.call("get_player_names")
	if _role == "host" and not _finishing:
		for old_peer: Variant in _last_names:
			if int(old_peer) > 1 and not names.has(old_peer):
				_removed_peer_ids.append(int(old_peer))
				_event("old_peer_removed_from_names", {"peer_id": int(old_peer), "name": _last_names[old_peer],
					"names_count": names.size()})
		for peer_value: Variant in names:
			if int(peer_value) <= 1:
				continue
			var player_name: String = str(names[peer_value])
			var history: Array = _name_history.get(player_name, [])
			if not history.has(int(peer_value)):
				history.append(int(peer_value))
			_name_history[player_name] = history
	_last_names = names.duplicate()
	_event("player_list_changed", {"names": names})

func _validate_finish() -> void:
	_check(not _busy, "finish 前异步 exercise 已完成")
	if _role == "client":
		for epoch: String in ["1", "2"]:
			_check(bool((_epochs.get(epoch, {}) as Dictionary).get("ok", false)), "Client epoch %s 完成且通过" % epoch)
		_check(_drop_count == 1 and _join_count == 2 and _peer_ids.size() == 2,
			"同 Client 进程完成一次 leave 与两次不同 peer 的 hello")
		return
	_check(_host_starts == 1, "同 Host 进程仅 host_game 一次")
	var names: Dictionary = _net.call("get_player_names")
	_check(_connected() and names.size() == _clients + 1, "Host finish 前重连客户端均在生产 hello 名单")
	var expected_total: int = 0
	var shared_count: int = int(_counts_by_index.get("0", 0))
	for index: int in range(_clients):
		var index_key: String = str(index)
		var count: int = int(_counts_by_index.get(index_key, 0))
		_check(count == shared_count, "所有客户端事务段长度一致 index=%d" % index)
		expected_total += count
		_check(count >= 20 and count <= 200 and int(_apply_by_index.get(index_key, -1)) == count,
			"Host 每客户端仅应用一个 seq 段 index=%d" % index)
		for epoch: int in [1, 2]:
			_check(int(_requests_by_index.get("%d:%d" % [epoch, index], 0)) == count * 2,
				"Host 双阶段每客户端双请求完整 epoch=%d index=%d" % [epoch, index])
		var history: Array = _name_history.get("UdpReconnect%d" % index, [])
		_check(history.size() == 2 and history[0] != history[1], "同昵称两次 hello 使用不同 peer index=%d" % index)
		if not history.is_empty():
			_check(_removed_peer_ids.has(history[0]), "旧 peer 已从生产名单移除 index=%d" % index)
	_check(_ledger.size() == expected_total and expected_total >= 20 * _clients, "Host 跨重连应用账本总数恒定")
	_check(int(_dedup_by_epoch.get("1", 0)) == expected_total, "首阶段每事务第二次请求幂等")
	_check(int(_dedup_by_epoch.get("2", 0)) == expected_total * 2, "重连阶段所有旧事务均幂等")

func _shutdown() -> void:
	if _finished:
		return
	_finished = true
	var result: Dictionary = _status()
	if not _finish_snapshot.is_empty():
		result["before_finish"] = _finish_snapshot
	if _net != null:
		_net.call("leave")
		_check(_is_offline(), "结束后 Net 与 MultiplayerPeer 离线")
		result["offline_after_leave"] = _is_offline()
	if _control != null:
		_control.close()
	_control_token = ""
	result["ok"] = _failures.is_empty()
	result["checks"] = _checks
	result["failures"] = _failures.duplicate()
	print("UDP_RE_RESULT " + JSON.stringify(result))
	quit(0 if _failures.is_empty() else 1)
