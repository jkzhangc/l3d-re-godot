extends Node

## ── 架构定位 ──
## 系统：独立隧道I/O回归 ｜ 层：专用本地集成测试
## Relay和假ENet游戏UDP回显在独立测试线程；主线程故意停顿，验证纯字节收发继续。
## 不联网、不改配置；专用27984/27985端口，串行运行。
const WORKER := preload("res://script/tunnel_io_worker.gd")
const TUNNEL := preload("res://script/tunnel_client.gd")

class SimWorker extends "res://script/tunnel_io_worker.gd":
	var limits: Array[int] = []
	var captured := PackedByteArray()
	var write_error: Error = OK
	var udp_busy: bool = false
	var delivered: Array[PackedByteArray] = []

	func _write_tcp_chunk(data: PackedByteArray) -> Array:
		if write_error != OK:
			return [write_error, 0]
		var count: int = mini(data.size(), limits.pop_front()) if not limits.is_empty() else data.size()
		captured.append_array(data.slice(0, count))
		return [OK, count]

	func _put_game_packet(_socket: PacketPeerUDP, data: PackedByteArray) -> Error:
		if udp_busy:
			return ERR_BUSY
		delivered.append(data)
		return OK

class EventWorker extends RefCounted:
	var stopped: bool = false
	var events: Array[Dictionary] = [
		{"type": "registered", "tunnel_id": "old", "public_port": 27990},
		{"type": "closed", "reason": "旧会话末尾事件"}]

	func get_stats() -> Dictionary:
		return {"state": "registered", "thread_running": false}

	func drain_events() -> Array[Dictionary]:
		var result: Array[Dictionary] = events
		events = []
		return result

	func stop() -> void:
		stopped = true

class LocalRelay extends RefCounted:
	var thread: Thread
	var mutex: Mutex = Mutex.new()
	var quitting: bool = false
	var state: Dictionary = {}
	var malformed: bool = false
	var silent: bool = false

	func start() -> Error:
		thread = Thread.new()
		return thread.start(run.bind(self))

	func snapshot() -> Dictionary:
		mutex.lock()
		var result: Dictionary = state.duplicate(true)
		mutex.unlock()
		return result

	func stop() -> void:
		mutex.lock()
		quitting = true
		mutex.unlock()
		if thread != null and thread.is_started():
			thread.wait_to_finish()

	func should_stop() -> bool:
		mutex.lock()
		var result: bool = quitting
		mutex.unlock()
		return result

	func publish(value: Dictionary) -> void:
		mutex.lock()
		state = value
		mutex.unlock()

	func frame(kind: int, payload: PackedByteArray) -> PackedByteArray:
		var n: int = payload.size() + 1
		var result := PackedByteArray([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255, kind])
		result.append_array(payload)
		return result

	func run(_guard: RefCounted) -> void:
		var server := TCPServer.new()
		var game := PacketPeerUDP.new()
		var error: Error = server.listen(27984, "127.0.0.1")
		if error == OK:
			error = game.bind(27985, "127.0.0.1")
		if error != OK:
			publish({"error": error})
			return
		var tcp: StreamPeerTCP = null
		var incoming := PackedByteArray()
		var output := PackedByteArray()
		var registered: bool = false
		var seq: int = 0
		var next_send: int = 0
		var seen: Dictionary = {}
		var duplicates: int = 0
		var mismatches: int = 0
		var sessions: int = 0
		publish({"ready": true, "echoes": 0, "sessions": 0})
		while not should_stop():
			if tcp == null and server.is_connection_available():
				tcp = server.take_connection()
				tcp.set_no_delay(true)
				sessions += 1
				registered = false
				incoming.clear()
				output.clear()
			if tcp != null:
				tcp.poll()
				if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
					tcp.disconnect_from_host()
					tcp = null
				else:
					var avail: int = tcp.get_available_bytes()
					if avail > 0:
						var read: Array = tcp.get_partial_data(avail)
						if int(read[0]) == OK:
							incoming.append_array(read[1])
					while incoming.size() >= 5:
						var n: int = (incoming[0] << 24) | (incoming[1] << 16) | (incoming[2] << 8) | incoming[3]
						if n < 1 or n > 8192 or incoming.size() < n + 4:
							break
						var kind: int = incoming[4]
						var data: PackedByteArray = incoming.slice(5, n + 4)
						incoming = incoming.slice(n + 4)
						if kind == 1 and not silent:
							output.append_array(frame(2, ("null" if malformed else '{"tunnelId":"local","tunnelPort":27990}').to_utf8_buffer()))
							registered = not malformed
						elif kind == 4:
							var token: String = data.hex_encode()
							if seen.has(token):
								duplicates += 1
							seen[token] = true
							if data.size() != 4 or data[1] != data[2]:
								mismatches += 1
					if registered and Time.get_ticks_msec() >= next_send:
						next_send = Time.get_ticks_msec() + 10
						seq = (seq + 1) % 250
						var cid: int = 1 + seq % 2
						output.append_array(frame(3, PackedByteArray([0, cid, cid, seq])))
					if not output.is_empty():
						# 故意每次仅写3字节，覆盖TCP帧头/体跨read分片。
						var result: Array = tcp.put_partial_data(output.slice(0, mini(3, output.size())))
						if int(result[0]) == OK and int(result[1]) > 0:
							output = output.slice(int(result[1]))
			while game.get_available_packet_count() > 0:
				var data: PackedByteArray = game.get_packet()
				game.set_dest_address(game.get_packet_ip(), game.get_packet_port())
				game.put_packet(data)
			publish({"ready": true, "echoes": seen.size(), "duplicates": duplicates,
				"mismatches": mismatches, "sessions": sessions})
			OS.delay_usec(1000)
		if tcp != null:
			tcp.disconnect_from_host()
		server.stop()
		game.close()

var _checks: int = 0
var _failures: int = 0
var _ready_signals: int = 0
var _closed_signals: int = 0
var _failed_signals: int = 0
var _signals_on_main: bool = true

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("NETWORK_TUNNEL_THREAD_CHECK %s %s" % ["PASS" if ok else "FAIL", message])

func _ready() -> void:
	call_deferred("_run")

func _on_ready(_address: String, _port: int) -> void:
	_ready_signals += 1
	_signals_on_main = _signals_on_main and Thread.is_main_thread()

func _on_closed() -> void:
	_closed_signals += 1
	_signals_on_main = _signals_on_main and Thread.is_main_thread()

func _on_failed(_reason: String) -> void:
	_failed_signals += 1
	_signals_on_main = _signals_on_main and Thread.is_main_thread()

func _run() -> void:
	_test_deterministic_io()
	await _test_budget_fairness()
	var relay := LocalRelay.new()
	_check(relay.start() == OK, "本地独立模拟中继启动")
	var deadline: int = Time.get_ticks_msec() + 3000
	while not relay.snapshot().get("ready", false) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(relay.snapshot().get("ready", false), "本地TCP与UDP均监听成功")
	var tunnel: Node = TUNNEL.new()
	add_child(tunnel)
	tunnel.threaded_io_enabled = true
	tunnel.tunnel_ready.connect(_on_ready)
	tunnel.tunnel_closed.connect(_on_closed)
	tunnel.tunnel_failed.connect(_on_failed)
	tunnel.setup("127.0.0.1", 27984)
	tunnel.start(27985)
	deadline = Time.get_ticks_msec() + 3000
	while not tunnel.is_active() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(tunnel.is_active() and _ready_signals == 1, "分片REGISTERED只触发一次ready")
	var before: int = int(relay.snapshot().get("echoes", 0))
	# 故意阻塞主线程，不能依赖_process/physics或call_deferred搬数据。
	OS.delay_usec(300000)
	var after: int = int(relay.snapshot().get("echoes", 0))
	_check(after >= before + 3, "主线程300ms停顿时双向TCP/UDP仍往返")
	_check(tunnel._tcp == null and tunnel._clients.is_empty(), "门面不持有worker的socket")
	_check(int(relay.snapshot().get("duplicates", -1)) == 0
		and int(relay.snapshot().get("mismatches", -1)) == 0, "两客户端数据报不重复且cid保持")
	var stats: Dictionary = tunnel.get_transport_stats()
	_check(stats.get("thread_running", false) and int(stats.get("bytes_sent", 0)) > 0
		and int(stats.get("bytes_received", 0)) > 0 and int(stats.get("iterations", 0)) > 3,
		"线程字节/工作量诊断可读取")
	get_tree().paused = true
	await get_tree().process_frame
	OS.delay_usec(100000)
	get_tree().paused = false
	_check(int(relay.snapshot().get("echoes", 0)) > after, "场景树暂停也不停止字节转发")
	var started: int = Time.get_ticks_usec()
	tunnel.stop()
	_check(Time.get_ticks_usec() - started < 500000 and tunnel._io_worker == null,
		"stop有界join并移除worker")
	_check(_closed_signals == 1 and not tunnel.is_active(), "主动停止只关闭一次")
	tunnel.stop()
	_check(_closed_signals == 1, "重复stop幂等")
	tunnel.start(27985)
	deadline = Time.get_ticks_msec() + 3000
	while _ready_signals < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(_ready_signals == 2 and tunnel.is_active(), "同一门面stop后可重新start")
	relay.stop()
	deadline = Time.get_ticks_msec() + 3000
	while tunnel._io_worker != null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(_closed_signals == 2 and tunnel._io_worker == null, "远端关闭由主线程派发并回收线程")
	_check(_signals_on_main and _failed_signals == 0, "所有门面信号均在主线程执行")
	tunnel.free()
	await _test_reentrant_events()
	await _test_failure_and_cancel()
	var invalid := WORKER.new()
	_check(invalid.start({"server_host": "", "game_port": 1}) == ERR_INVALID_PARAMETER,
		"非法配置不创建线程")
	invalid.stop()
	print("NETWORK_TUNNEL_THREAD_CHECK checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _arm(worker: SimWorker) -> void:
	worker._deadline_usec = Time.get_ticks_usec() + 1000000
	worker._write_remaining = WORKER.MAX_WRITE_BYTES_PER_PUMP
	worker._messages_remaining = WORKER.MAX_MESSAGES_PER_PUMP


func _test_deterministic_io() -> void:
	var encoder := LocalRelay.new()
	var worker := SimWorker.new()
	worker._state = "registered"
	worker._registered = true
	var first: PackedByteArray = encoder.frame(4, PackedByteArray([0, 1, 8, 9]))
	var second: PackedByteArray = encoder.frame(5, PackedByteArray())
	worker._queue_message(4, PackedByteArray([0, 1, 8, 9]))
	worker._queue_message(5, PackedByteArray())
	worker.limits.assign([1, 0])
	_arm(worker)
	worker._flush_send_queue()
	_check(worker.captured == first.slice(0, 1) and worker._send_queue_bytes == first.size() + second.size() - 1,
		"部分写1字节后零写保留精确offset和字节数")
	worker.limits.assign([2, 1, 0])
	_arm(worker)
	worker._flush_send_queue()
	_arm(worker)
	worker._flush_send_queue()
	var expected: PackedByteArray = first.duplicate()
	expected.append_array(second)
	_check(worker.captured == expected and worker._send_queue.is_empty() and worker._send_queue_bytes == 0,
		"跨轮重试不重发前缀且帧间不交错")
	worker._queue_message(5, PackedByteArray())
	worker.write_error = ERR_CONNECTION_ERROR
	_arm(worker)
	worker._flush_send_queue()
	_check(worker._state == "closed" and worker._terminal_event.get("type") == "closed",
		"注册后写错误仅终止当前会话")

	var busy := SimWorker.new()
	busy._state = "registered"
	busy._registered = true
	busy.udp_busy = true
	busy._recv_buffer = encoder.frame(3, PackedByteArray([0, 7, 8, 9]))
	busy._recv_buffer.append_array(encoder.frame(3, PackedByteArray([0, 7, 10, 11])))
	var original: PackedByteArray = busy._recv_buffer.duplicate()
	_arm(busy)
	busy._process_messages()
	_check(busy._recv_buffer == original and busy.delivered.is_empty(), "UDP忙时不消费帧也不越过它转发后帧")
	var busy_socket: PacketPeerUDP = busy._clients[7]["socket"]
	var busy_port: int = busy_socket.get_local_port()
	busy._clients[7]["last_seen"] = Time.get_ticks_msec() - WORKER.CLIENT_IDLE_TIMEOUT_MSEC - 10
	_arm(busy)
	busy._process_messages()
	busy._last_cleanup_usec = Time.get_ticks_usec() - WORKER.CLEANUP_INTERVAL_USEC - 1
	busy._tick_maintenance(Time.get_ticks_usec())
	_check(busy._clients.has(7) and busy._clients[7]["socket"] == busy_socket
		and busy_socket.get_local_port() == busy_port,
		"UDP忙重试刷新活动时间，空闲清理不更换源端口")
	busy.udp_busy = false
	_arm(busy)
	busy._process_messages()
	_check(busy.delivered.size() == 2 and busy.delivered[0] == PackedByteArray([8, 9])
		and busy.delivered[1] == PackedByteArray([10, 11]) and busy._recv_buffer.is_empty(),
		"UDP忙恢复后每个数据报按序恰好投递一次")
	busy._close_sockets()

	var full := SimWorker.new()
	full._state = "registered"
	full._registered = true
	var large := PackedByteArray()
	large.resize(WORKER.MAX_SEND_QUEUE_BYTES)
	full._queue_message(4, large)
	_check(full._state == "closed" and full._send_queue_bytes == 0, "发送队列超限先拒绝不越界分配队列")
	var old := SimWorker.new()
	old._state = "registered"
	old._registered = true
	old._queue_message(5, PackedByteArray())
	old._send_queue[0]["queued_msec"] = Time.get_ticks_msec() - WORKER.MAX_SEND_QUEUE_AGE_MSEC - 10
	old._tick_maintenance(Time.get_ticks_usec())
	_check(old._state == "closed", "发送队列年龄超限明确关闭而非无限积压")
	var writable_old := SimWorker.new()
	writable_old._state = "registered"
	writable_old._registered = true
	writable_old._queue_message(5, PackedByteArray())
	writable_old._send_queue[0]["queued_msec"] = Time.get_ticks_msec() - WORKER.MAX_SEND_QUEUE_AGE_MSEC - 10
	_arm(writable_old)
	writable_old._flush_send_queue()
	_check(writable_old._state == "closed" and writable_old.captured.is_empty(),
		"恢复可写时先检查过期，不向TCP交付过期帧")
	var invalid := SimWorker.new()
	invalid._state = "registered"
	invalid._registered = true
	invalid._recv_buffer = PackedByteArray([0, 0, 32, 1, 3])
	_arm(invalid)
	invalid._process_messages()
	_check(invalid._state == "closed", "非法帧长不等待无限流")


func _test_budget_fairness() -> void:
	var worker := SimWorker.new()
	worker._state = "registered"
	worker._registered = true
	var senders: Array[PacketPeerUDP] = []
	var setup_ok: bool = true
	# 五个真实localhost UDP端点，各自连续三轮提供64包。
	for id: int in range(1, 6):
		var receiver := PacketPeerUDP.new()
		var sender := PacketPeerUDP.new()
		var error: Error = receiver.bind(0, "127.0.0.1")
		if error == OK:
			error = sender.bind(0, "127.0.0.1")
		if error == OK:
			error = sender.connect_to_host("127.0.0.1", receiver.get_local_port())
		if error == OK:
			error = receiver.connect_to_host("127.0.0.1", sender.get_local_port())
		setup_ok = setup_ok and error == OK
		worker._clients[id] = {"socket": receiver, "last_seen": Time.get_ticks_msec()}
		senders.append(sender)
	_check(setup_ok, "公平性夹具五个真实UDP客户端绑定成功")
	if setup_ok:
		var serviced: Dictionary = {}
		var ready: bool = true
		var sent_ok: bool = true
		for round_index: int in 3:
			for i: int in senders.size():
				var receiver: PacketPeerUDP = worker._clients[i + 1]["socket"]
				while receiver.get_available_packet_count() > 0:
					receiver.get_packet()
				for sequence: int in 64:
					sent_ok = senders[i].put_packet(PackedByteArray([i + 1, sequence])) == OK and sent_ok
			var deadline: int = Time.get_ticks_msec() + 1000
			var all_ready: bool = false
			while not all_ready and Time.get_ticks_msec() < deadline:
				all_ready = true
				for client: Dictionary in worker._clients.values():
					all_ready = (client["socket"] as PacketPeerUDP).get_available_packet_count() >= 64 and all_ready
				if not all_ready:
					await get_tree().process_frame
			ready = ready and all_ready
			worker._send_queue.clear()
			worker._send_queue_bytes = 0
			_arm(worker)
			worker._poll_game_outgoing()
			for packet: Dictionary in worker._send_queue:
				var frame: PackedByteArray = packet["frame"]
				serviced[(frame[5] << 8) | frame[6]] = true
		_check(sent_ok and ready, "连续三轮每客户端64包都准备就绪")
		_check(serviced.size() == 5, "256消息预算连续三轮仍服务全部五客户端，无固定末位饥饿")
	worker._close_sockets()
	for sender: PacketPeerUDP in senders:
		sender.close()


func _test_reentrant_events() -> void:
	var relay := LocalRelay.new()
	_check(relay.start() == OK, "重入测试中继启动")
	var deadline: int = Time.get_ticks_msec() + 3000
	while not relay.snapshot().get("ready", false) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var tunnel: Node = TUNNEL.new()
	add_child(tunnel)
	tunnel.threaded_io_enabled = true
	tunnel.setup("127.0.0.1", 27984)
	tunnel._session_server_host = "127.0.0.1"
	var stale := EventWorker.new()
	tunnel._io_worker = stale
	tunnel._state = "connecting"
	var callbacks: Dictionary = {"ready": 0, "closed": 0}
	var restart: Callable = func(_address: String, _port: int) -> void:
		callbacks["ready"] += 1
		if callbacks["ready"] == 1:
			tunnel.stop()
			tunnel.start(27985)
	var closed: Callable = func() -> void: callbacks["closed"] += 1
	tunnel.tunnel_ready.connect(restart)
	tunnel.tunnel_closed.connect(closed)
	tunnel._drain_io_events()
	_check(stale.stopped and tunnel._io_worker != null and tunnel._io_worker != stale
		and tunnel._state == "connecting" and callbacks["closed"] == 1,
		"ready回调stop/start后旧批次closed不得关闭新worker")
	# setup只配置下一会话，不得改掉已经连接的公网地址。
	tunnel.setup("192.0.2.77", 1)
	deadline = Time.get_ticks_msec() + 3000
	while callbacks["ready"] < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(callbacks["ready"] == 2 and tunnel.is_active() and tunnel.get_public_address() == "127.0.0.1",
		"运行中setup不改当前会话对外地址")
	var worker: RefCounted = tunnel._io_worker
	var restart_on_exit: Callable = func() -> void: tunnel.start(27985)
	tunnel.tunnel_closed.connect(restart_on_exit)
	tunnel.free()
	_check(not worker.is_started() and not worker.is_running(), "退出树closed回调不可重建线程且原线程已join")
	relay.stop()


func _test_failure_and_cancel() -> void:
	for malformed: bool in [true, false]:
		var relay := LocalRelay.new()
		relay.malformed = malformed
		relay.silent = not malformed
		_check(relay.start() == OK, "失败夹具启动")
		var deadline: int = Time.get_ticks_msec() + 3000
		while not relay.snapshot().get("ready", false) and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		var worker := WORKER.new()
		_check(worker.start({"server_host": "127.0.0.1", "server_port": 27984,
			"game_port": 27985, "connect_timeout": 0.15}) == OK, "失败会话线程启动")
		deadline = Time.get_ticks_msec() + 3000
		while worker.is_running() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		worker.stop()
		var events: Array[Dictionary] = worker.drain_events()
		_check(events.size() == 1 and events[0].get("type") == "failed"
			and ("解析失败" in str(events[0].get("reason")) if malformed else "注册响应超时" in str(events[0].get("reason"))),
			"畸形注册仅一次failed" if malformed else "静默注册单调超时仅一次failed")
		relay.stop()
	var dns := WORKER.new()
	_check(dns.start({"server_host": "cancel-test.invalid", "game_port": 27985}) == OK,
		"域名解析会话可启动")
	var started: int = Time.get_ticks_usec()
	dns.stop()
	_check(Time.get_ticks_usec() - started < 500000 and not dns.is_started(), "域名连接阶段停止有界join")
