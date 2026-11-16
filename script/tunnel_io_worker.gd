extends RefCounted

## ── 架构定位 ──
## 系统：隧道独立I/O原型 ｜ 层：可回退的纯字节传输工作器
## 主线程仅交换配置、停止标记、事件和统计；全部 socket 生命周期属于工作线程。
## 未派发游戏RPC/访问活动场景；默认不开启，实验结论见联机策划方案§17。
const MSG_REGISTER := 0x01
const MSG_REGISTERED := 0x02
const MSG_RELAY_TO_HOST := 0x03
const MSG_RELAY_FROM_HOST := 0x04
const MSG_KEEPALIVE := 0x05
const MSG_RELEASE := 0x06
const MSG_ERROR := 0x07
const MAX_PACKET_SIZE := 1500
const MAX_FRAME_SIZE := 8192
const MAX_CLIENTS := 64
const MAX_EVENTS := 16
const MAX_SEND_QUEUE_BYTES := 512 * 1024
const MAX_RECV_BUFFER_BYTES := 512 * 1024
const MAX_SEND_QUEUE_AGE_MSEC := 2000
const MAX_READ_BYTES_PER_PUMP := 128 * 1024
const MAX_WRITE_BYTES_PER_PUMP := 128 * 1024
const MAX_MESSAGES_PER_PUMP := 256
const MAX_OUTGOING_PER_CLIENT := 64
const PUMP_BUDGET_USEC := 2000
const PUBLISH_INTERVAL_USEC := 20000
const KEEPALIVE_INTERVAL_USEC := 10000000
const CLIENT_IDLE_TIMEOUT_MSEC := 60000
const CLEANUP_INTERVAL_USEC := 5000000

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _stop_requested: bool = false
var _events: Array[Dictionary] = []
var _published_stats: Dictionary = {}
var _running: bool = false

# start 在创建线程前写入；join 之前不再修改。
var _server_host: String = ""
var _server_port: int = 10001
var _game_port: int = 27015
var _register_payload: PackedByteArray = PackedByteArray()
var _connect_timeout_usec: int = 10000000
var _poll_interval_usec: int = 1000

# 以下字段仅由工作线程访问，包括新会话重置与最终清理。
var _tcp: StreamPeerTCP = null
var _resolver_id: int = IP.RESOLVER_INVALID_ID
var _connect_started: bool = false
var _clients: Dictionary = {}
var _recv_buffer: PackedByteArray = PackedByteArray()
var _send_queue: Array[Dictionary] = []
var _state: String = "idle"
var _registered: bool = false
var _terminal_event: Dictionary = {}
var _phase_started_usec: int = 0
var _last_keepalive_usec: int = 0
var _last_cleanup_usec: int = 0
var _last_publish_usec: int = 0
var _recv_blocked_since_usec: int = 0
var _next_outgoing_client: int = 0
var _send_queue_bytes: int = 0
var _send_queue_peak_bytes: int = 0
var _send_partial_writes: int = 0
var _bytes_sent: int = 0
var _bytes_received: int = 0
var _iterations: int = 0
var _work_usec: int = 0
var _last_pump_usec: int = 0
var _max_pump_usec: int = 0
var _max_iteration_gap_usec: int = 0
var _max_send_queue_age_msec: int = 0
var _deadline_usec: int = 0
var _write_remaining: int = 0
var _messages_remaining: int = 0


func start(config: Dictionary) -> Error:
	if is_started():
		return ERR_ALREADY_IN_USE
	_server_host = str(config.get("server_host", ""))
	_server_port = int(config.get("server_port", 10001))
	_game_port = int(config.get("game_port", 27015))
	var timeout: float = float(config.get("connect_timeout", 10.0))
	if _server_host.is_empty() or _server_port < 1 or _server_port > 65535:
		return ERR_INVALID_PARAMETER
	if _game_port < 1 or _game_port > 65535 or not is_finite(timeout) or timeout <= 0.0:
		return ERR_INVALID_PARAMETER
	_connect_timeout_usec = maxi(1, int(timeout * 1000000.0))
	_poll_interval_usec = clampi(int(config.get("poll_interval_usec", 1000)), 1000, 20000)
	_register_payload = JSON.stringify({
		"protocol": str(config.get("protocol", "")),
		"gameVersion": str(config.get("game_version", "")),
	}).to_utf8_buffer()
	if _register_payload.size() + 1 > MAX_FRAME_SIZE:
		return ERR_INVALID_PARAMETER
	var initial_stats: Dictionary = _empty_stats("connecting", true)
	_mutex.lock()
	_stop_requested = false
	_events = []
	_published_stats = initial_stats
	_running = true
	_mutex.unlock()
	_thread = Thread.new()
	# 显式绑定强引用，调用方仍须 stop/join 后才能释放 worker。
	var error: Error = _thread.start(_thread_main.bind(self))
	if error != OK:
		var failed_stats: Dictionary = _empty_stats("closed", false)
		_mutex.lock()
		_running = false
		_published_stats = failed_stats
		_mutex.unlock()
		_thread = null
	return error


func request_stop() -> void:
	_mutex.lock()
	_stop_requested = true
	_mutex.unlock()


## 与 start/is_started 一样仅在主线程调用；绝不持锁等待线程。
func stop() -> void:
	request_stop()
	if is_started():
		_thread.wait_to_finish()
	_thread = null


func drain_events() -> Array[Dictionary]:
	_mutex.lock()
	var events: Array[Dictionary] = _events
	_events = []
	_mutex.unlock()
	return events


func get_stats() -> Dictionary:
	_mutex.lock()
	var snapshot: Dictionary = _published_stats.duplicate(true)
	_mutex.unlock()
	if snapshot.is_empty():
		return _empty_stats("idle", false)
	return snapshot


func is_running() -> bool:
	_mutex.lock()
	var running: bool = _running
	_mutex.unlock()
	return running


func is_started() -> bool:
	return _thread != null and _thread.is_started()


func _should_stop() -> bool:
	_mutex.lock()
	var requested: bool = _stop_requested
	_mutex.unlock()
	return requested


func _empty_stats(state: String, running: bool) -> Dictionary:
	return {"state": state, "threaded_io": true, "thread_running": running,
		"clients": 0, "send_queue_bytes": 0, "send_queue_peak_bytes": 0,
		"send_queue_age_msec": 0, "recv_buffer_bytes": 0, "send_partial_writes": 0,
		"bytes_sent": 0, "bytes_received": 0, "iterations": 0, "work_usec": 0,
		"last_pump_usec": 0, "max_pump_usec": 0, "max_iteration_gap_usec": 0,
		"max_send_queue_age_msec": 0}


func _reset_session() -> void:
	_clients.clear()
	_recv_buffer.clear()
	_send_queue.clear()
	_terminal_event = {}
	_resolver_id = IP.RESOLVER_INVALID_ID
	_connect_started = false
	_registered = false
	_state = "connecting"
	_phase_started_usec = Time.get_ticks_usec()
	_last_keepalive_usec = _phase_started_usec
	_last_cleanup_usec = _phase_started_usec
	_last_publish_usec = 0
	_recv_blocked_since_usec = 0
	_next_outgoing_client = 0
	_send_queue_bytes = 0
	_send_queue_peak_bytes = 0
	_send_partial_writes = 0
	_bytes_sent = 0
	_bytes_received = 0
	_iterations = 0
	_work_usec = 0
	_last_pump_usec = 0
	_max_pump_usec = 0
	_max_iteration_gap_usec = 0
	_max_send_queue_age_msec = 0


func _thread_main(_lifetime_guard: RefCounted) -> void:
	_reset_session()
	_tcp = StreamPeerTCP.new()
	var previous_iteration_usec: int = Time.get_ticks_usec()
	_publish(true)
	while _state != "closed" and not _should_stop():
		var started_usec: int = Time.get_ticks_usec()
		_max_iteration_gap_usec = maxi(_max_iteration_gap_usec, started_usec - previous_iteration_usec)
		previous_iteration_usec = started_usec
		_iterations += 1
		_deadline_usec = started_usec + PUMP_BUDGET_USEC
		_write_remaining = MAX_WRITE_BYTES_PER_PUMP
		_messages_remaining = MAX_MESSAGES_PER_PUMP
		_tick_connection(started_usec)
		if _state == "awaiting_registered" or _state == "registered":
			if _iterations % 2 == 0:
				_pump_incoming()
				_pump_outgoing()
			else:
				_pump_outgoing()
				_pump_incoming()
			_tick_maintenance(Time.get_ticks_usec())
		_last_pump_usec = Time.get_ticks_usec() - started_usec
		_work_usec += _last_pump_usec
		_max_pump_usec = maxi(_max_pump_usec, _last_pump_usec)
		_publish()
		if _state == "closed" or _should_stop():
			break
		# 工作超出间隔也至少让出一次 CPU；空闲时补足配置的轮询间隔。
		OS.delay_usec(maxi(1, _poll_interval_usec - (Time.get_ticks_usec() - started_usec)))
	var normal_stop: bool = _should_stop()
	if normal_stop:
		_try_release()
	_close_sockets()
	_state = "closed"
	_recv_buffer.clear()
	_send_queue.clear()
	_send_queue_bytes = 0
	_publish(true, {} if normal_stop else _terminal_event, false)


func _tick_connection(now_usec: int) -> void:
	if _state == "connecting":
		if now_usec - _phase_started_usec >= _connect_timeout_usec:
			_fail("连接中继超时")
			return
		if not _connect_started:
			var address: String = _server_host
			if not address.is_valid_ip_address():
				if _resolver_id == IP.RESOLVER_INVALID_ID:
					_resolver_id = IP.resolve_hostname_queue_item(_server_host, IP.TYPE_ANY)
					if _resolver_id == IP.RESOLVER_INVALID_ID:
						_fail("无法创建中继域名解析请求")
						return
				var status: IP.ResolverStatus = IP.get_resolve_item_status(_resolver_id)
				if status == IP.RESOLVER_STATUS_WAITING:
					return
				address = IP.get_resolve_item_address(_resolver_id) if status == IP.RESOLVER_STATUS_DONE else ""
				IP.erase_resolve_item(_resolver_id)
				_resolver_id = IP.RESOLVER_INVALID_ID
				if address.is_empty():
					_fail("中继域名解析失败")
					return
			var error: Error = _tcp.connect_to_host(address, _server_port)
			_connect_started = true
			if error != OK:
				_fail("TCP 连接失败：%s" % error_string(error))
				return
	if _state == "closed":
		return
	var poll_error: Error = _tcp.poll()
	var tcp_status: StreamPeerTCP.Status = _tcp.get_status()
	if poll_error != OK or tcp_status == StreamPeerTCP.STATUS_ERROR:
		_fail("TCP 连接错误")
		return
	if _state == "connecting":
		if tcp_status == StreamPeerTCP.STATUS_CONNECTED:
			_tcp.set_no_delay(true)
			_state = "awaiting_registered"
			_phase_started_usec = Time.get_ticks_usec()
			_queue_message(MSG_REGISTER, _register_payload)
			_publish(true)
		elif tcp_status == StreamPeerTCP.STATUS_NONE:
			_fail("TCP 连接已关闭")
	elif tcp_status != StreamPeerTCP.STATUS_CONNECTED:
		_fail("TCP 连接已关闭")
	elif _state == "awaiting_registered" and now_usec - _phase_started_usec >= _connect_timeout_usec:
		_fail("中继注册响应超时")


func _pump_incoming() -> void:
	if _state == "closed" or Time.get_ticks_usec() >= _deadline_usec:
		return
	_process_messages()
	if _state == "closed" or Time.get_ticks_usec() >= _deadline_usec:
		return
	var available: int = _tcp.get_available_bytes()
	var room: int = MAX_RECV_BUFFER_BYTES - _recv_buffer.size()
	if available <= 0:
		return
	if room <= 0:
		_fail("隧道入站积压超限")
		return
	var requested: int = mini(available, mini(room, MAX_READ_BYTES_PER_PUMP))
	var result: Array = _tcp.get_partial_data(requested)
	if int(result[0]) != OK:
		_fail("TCP 读数据失败")
		return
	var data: PackedByteArray = result[1]
	if data.size() > requested:
		_fail("TCP 部分读返回非法长度")
		return
	_bytes_received += data.size()
	_recv_buffer.append_array(data)
	_process_messages()


func _process_messages() -> void:
	while _recv_buffer.size() >= 4 and _state != "closed":
		if _messages_remaining <= 0 or Time.get_ticks_usec() >= _deadline_usec:
			return
		var length: int = (_recv_buffer[0] << 24) | (_recv_buffer[1] << 16) | (_recv_buffer[2] << 8) | _recv_buffer[3]
		if length < 1 or length > MAX_FRAME_SIZE:
			_fail("收到非法帧长（%d 字节）" % length)
			return
		if _recv_buffer.size() < length + 4:
			return
		_messages_remaining -= 1
		var message_type: int = _recv_buffer[4]
		var payload: PackedByteArray = _recv_buffer.slice(5, length + 4)
		if not _handle_message(message_type, payload):
			return
		_recv_buffer = _recv_buffer.slice(length + 4)
		_recv_blocked_since_usec = 0


func _handle_message(message_type: int, payload: PackedByteArray) -> bool:
	match message_type:
		MSG_REGISTERED:
			if _registered:
				return true
			var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
			if not parsed is Dictionary:
				_fail("REGISTERED 响应解析失败")
				return false
			var info: Dictionary = parsed
			var raw_port: Variant = info.get("tunnelPort", 0)
			var raw_id: Variant = info.get("tunnelId", "")
			if not (raw_port is int or raw_port is float) or not raw_id is String:
				_fail("REGISTERED 响应字段类型错误")
				return false
			var port_number: float = float(raw_port)
			if not is_finite(port_number) or port_number < 1.0 or port_number > 65535.0 or port_number != floor(port_number):
				_fail("REGISTERED 响应端口无效")
				return false
			_registered = true
			_state = "registered"
			_last_keepalive_usec = Time.get_ticks_usec()
			_publish(true, {"type": "registered", "tunnel_id": String(raw_id), "public_port": int(port_number)})
		MSG_RELAY_TO_HOST:
			if not _registered:
				_fail("中继在注册完成前发送数据")
				return false
			return _relay_to_game(payload)
		MSG_ERROR:
			var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
			var reason: String = "unknown"
			if parsed is Dictionary:
				reason = str(parsed.get("message", "unknown"))
			_fail("中继拒绝：%s" % reason)
			return false
		MSG_KEEPALIVE:
			pass
		_:
			_fail("收到未知中继消息类型：%d" % message_type)
			return false
	return true


func _relay_to_game(payload: PackedByteArray) -> bool:
	if payload.size() < 2 or payload.size() > MAX_PACKET_SIZE + 2:
		_fail("中继 UDP 数据报长度无效")
		return false
	var client_id: int = (payload[0] << 8) | payload[1]
	if not _clients.has(client_id):
		if _clients.size() >= MAX_CLIENTS:
			_fail("隧道客户端 socket 数量超过上限（64）")
			return false
		var socket: PacketPeerUDP = PacketPeerUDP.new()
		var error: Error = socket.bind(0, "127.0.0.1")
		if error == OK:
			error = socket.connect_to_host("127.0.0.1", _game_port)
		if error != OK:
			socket.close()
			_fail("创建本机 UDP socket 失败：%s" % error_string(error))
			return false
		_clients[client_id] = {"socket": socket, "last_seen": Time.get_ticks_msec()}
	var client: Dictionary = _clients[client_id]
	var socket: PacketPeerUDP = client["socket"]
	# 合法入站活动本身就刷新空闲时间；ERR_BUSY重试期间也必须保住ENet源端口。
	client["last_seen"] = Time.get_ticks_msec()
	var error: Error = _put_game_packet(socket, payload.slice(2))
	if error == ERR_BUSY:
		# 不消费 TCP 帧，下一轮重试同一数据报，且不越过它转发后续帧。
		if _recv_blocked_since_usec == 0:
			_recv_blocked_since_usec = Time.get_ticks_usec()
		return false
	if error != OK:
		_fail("隧道投递本机 UDP 失败：%s" % error_string(error))
		return false
	client["last_seen"] = Time.get_ticks_msec()
	return true


func _pump_outgoing() -> void:
	if _state == "closed":
		return
	_flush_send_queue()
	if _state != "registered":
		return
	_poll_game_outgoing()
	_flush_send_queue()


func _poll_game_outgoing() -> void:
	if _clients.is_empty():
		return
	var client_ids: Array = _clients.keys()
	var start_index: int = _next_outgoing_client % client_ids.size()
	for step: int in range(client_ids.size()):
		var index: int = (start_index + step) % client_ids.size()
		# 预算耗尽时保留尚未服务的当前客户端，不能先跳过它再返回。
		_next_outgoing_client = index
		if _messages_remaining <= 0 or Time.get_ticks_usec() >= _deadline_usec \
				or _send_queue_bytes > MAX_SEND_QUEUE_BYTES - MAX_PACKET_SIZE - 7:
			return
		_next_outgoing_client = (index + 1) % client_ids.size()
		var client_id: int = int(client_ids[index])
		var client: Dictionary = _clients[client_id]
		var socket: PacketPeerUDP = client["socket"]
		var count: int = 0
		while count < MAX_OUTGOING_PER_CLIENT:
			if _messages_remaining <= 0 or Time.get_ticks_usec() >= _deadline_usec:
				return
			# 接收前预留完整数据报空间，不先取包再因队列已满而丢弃。
			if _send_queue_bytes > MAX_SEND_QUEUE_BYTES - MAX_PACKET_SIZE - 7:
				return
			if socket.get_available_packet_count() <= 0:
				break
			var data: PackedByteArray = socket.get_packet()
			var error: Error = socket.get_packet_error()
			if error != OK:
				_fail("读取本机 UDP 失败：%s" % error_string(error))
				return
			if data.size() > MAX_PACKET_SIZE:
				_fail("本机 UDP 数据报超过隧道 MTU 上限")
				return
			client["last_seen"] = Time.get_ticks_msec()
			var payload: PackedByteArray = PackedByteArray([(client_id >> 8) & 0xFF, client_id & 0xFF])
			payload.append_array(data)
			_queue_message(MSG_RELAY_FROM_HOST, payload)
			count += 1
			_messages_remaining -= 1
			if _state == "closed":
				return


func _queue_message(message_type: int, payload: PackedByteArray) -> void:
	var length: int = payload.size() + 1
	var frame: PackedByteArray = PackedByteArray([
		(length >> 24) & 0xFF, (length >> 16) & 0xFF,
		(length >> 8) & 0xFF, length & 0xFF, message_type])
	frame.append_array(payload)
	if _send_queue_bytes + frame.size() > MAX_SEND_QUEUE_BYTES:
		_fail("隧道发送积压超限")
		return
	_send_queue.append({"frame": frame, "offset": 0, "queued_msec": Time.get_ticks_msec()})
	_send_queue_bytes += frame.size()
	_send_queue_peak_bytes = maxi(_send_queue_peak_bytes, _send_queue_bytes)


func _flush_send_queue() -> void:
	while not _send_queue.is_empty() and _state != "closed":
		if _write_remaining <= 0 or Time.get_ticks_usec() >= _deadline_usec:
			return
		var item: Dictionary = _send_queue[0]
		var age: int = maxi(0, Time.get_ticks_msec() - int(item["queued_msec"]))
		_max_send_queue_age_msec = maxi(_max_send_queue_age_msec, age)
		if age > MAX_SEND_QUEUE_AGE_MSEC:
			_fail("隧道发送队列长时间未排空")
			return  # 恢复可写也不能先发送过期字节，再因队列清空而逃过超时检查。
		var frame: PackedByteArray = item["frame"]
		var offset: int = int(item["offset"])
		var end: int = mini(frame.size(), offset + _write_remaining)
		var result: Array = _write_tcp_chunk(frame.slice(offset, end))
		if int(result[0]) != OK:
			_fail("TCP 写数据失败：%s" % error_string(int(result[0])))
			return
		var sent: int = int(result[1])
		if sent < 0 or sent > end - offset:
			_fail("TCP 部分写返回非法长度")
			return
		if sent < end - offset:
			_send_partial_writes += 1
		if sent == 0:
			return
		item["offset"] = offset + sent
		_send_queue_bytes -= sent
		_bytes_sent += sent
		_write_remaining -= sent
		if offset + sent == frame.size():
			_send_queue.pop_front()


## 窄I/O边界：生产只在worker线程调用；确定性测试不启动线程时可注入部分写/忙返回。
func _write_tcp_chunk(data: PackedByteArray) -> Array:
	return _tcp.put_partial_data(data)


func _put_game_packet(socket: PacketPeerUDP, data: PackedByteArray) -> Error:
	return socket.put_packet(data)


func _queue_age_msec() -> int:
	if _send_queue.is_empty():
		return 0
	return maxi(0, Time.get_ticks_msec() - int(_send_queue[0]["queued_msec"]))


func _tick_maintenance(now_usec: int) -> void:
	if _state == "closed":
		return
	var age: int = _queue_age_msec()
	_max_send_queue_age_msec = maxi(_max_send_queue_age_msec, age)
	if age > MAX_SEND_QUEUE_AGE_MSEC:
		_fail("隧道发送队列长时间未排空")
		return
	if _recv_blocked_since_usec > 0 and now_usec - _recv_blocked_since_usec > MAX_SEND_QUEUE_AGE_MSEC * 1000:
		_fail("隧道本机 UDP 长时间不可写")
		return
	if _state != "registered":
		return
	if now_usec - _last_keepalive_usec >= KEEPALIVE_INTERVAL_USEC:
		_last_keepalive_usec = now_usec
		_queue_message(MSG_KEEPALIVE, PackedByteArray())
	if now_usec - _last_cleanup_usec >= CLEANUP_INTERVAL_USEC:
		_last_cleanup_usec = now_usec
		var now_msec: int = Time.get_ticks_msec()
		for client_id: int in _clients.keys():
			var client: Dictionary = _clients[client_id]
			if now_msec - int(client["last_seen"]) > CLIENT_IDLE_TIMEOUT_MSEC:
				var socket: PacketPeerUDP = client["socket"]
				# 已进入接收缓冲的回包不能因空闲清理而被静默丢弃。
				if socket.get_available_packet_count() == 0:
					socket.close()
					_clients.erase(client_id)


func _fail(reason: String) -> void:
	if _state == "closed":
		return
	_terminal_event = {"type": "closed" if _registered else "failed", "reason": reason}
	_state = "closed"


func _try_release() -> void:
	if not _registered or _tcp == null or _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	# 不可把 RELEASE 插到半帧中间；仅尝试一次有预算的非阻塞排空。
	_deadline_usec = Time.get_ticks_usec() + PUMP_BUDGET_USEC
	_write_remaining = MAX_WRITE_BYTES_PER_PUMP
	if _state != "closed":
		_flush_send_queue()
	if _send_queue.is_empty():
		_tcp.put_partial_data(PackedByteArray([0, 0, 0, 1, MSG_RELEASE]))


func _close_sockets() -> void:
	if _resolver_id != IP.RESOLVER_INVALID_ID:
		IP.erase_resolve_item(_resolver_id)
		_resolver_id = IP.RESOLVER_INVALID_ID
	for client_id: int in _clients.keys():
		var socket: PacketPeerUDP = _clients[client_id]["socket"]
		socket.close()
	_clients.clear()
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null


func _publish(force: bool = false, event: Dictionary = {}, running: bool = true) -> void:
	var now_usec: int = Time.get_ticks_usec()
	if not force and now_usec - _last_publish_usec < PUBLISH_INTERVAL_USEC:
		return
	_last_publish_usec = now_usec
	var age: int = _queue_age_msec()
	_max_send_queue_age_msec = maxi(_max_send_queue_age_msec, age)
	var snapshot: Dictionary = {"state": _state, "threaded_io": true,
		"thread_running": running, "clients": _clients.size(),
		"send_queue_bytes": _send_queue_bytes, "send_queue_peak_bytes": _send_queue_peak_bytes,
		"send_queue_age_msec": age, "recv_buffer_bytes": _recv_buffer.size(),
		"send_partial_writes": _send_partial_writes, "bytes_sent": _bytes_sent,
		"bytes_received": _bytes_received, "iterations": _iterations, "work_usec": _work_usec,
		"last_pump_usec": _last_pump_usec, "max_pump_usec": _max_pump_usec,
		"max_iteration_gap_usec": _max_iteration_gap_usec,
		"max_send_queue_age_msec": _max_send_queue_age_msec}
	_mutex.lock()
	_published_stats = snapshot
	_running = running
	if not event.is_empty():
		if _events.size() >= MAX_EVENTS:
			_events.pop_front()
		var stamped: Dictionary = event.duplicate()
		stamped["queued_usec"] = now_usec
		_events.append(stamped)
	_mutex.unlock()
