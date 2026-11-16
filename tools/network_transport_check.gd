extends Node

## ── 架构定位 ──
## 系统：联机传输回归 ｜ 层：tools（headless）
## 直接测试生产发送队列的部分写、预算与清理；校验Net pump生命周期/暂停，且不访问公网。
## @trace NET-LAT-P1
class PartialTunnel extends "res://script/tunnel_client.gd":
	var bytes: PackedByteArray = PackedByteArray()
	var capacity: int = 0
	var fail_write: bool = false

	func _write_tcp_chunk(data: PackedByteArray) -> Array:
		if fail_write:
			return [ERR_CONNECTION_ERROR, 0]
		var count: int = mini(capacity, data.size())
		bytes.append_array(data.slice(0, count))
		capacity -= count
		return [OK, count]

class IncomingTunnel extends "res://script/tunnel_client.gd":
	var messages: int = 0

	func _handle_message(_type: int, _payload: PackedByteArray) -> void:
		messages += 1

var _checks: int = 0
var _failed: int = 0

func _ready() -> void:
	call_deferred("_run")

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("NETWORK_TRANSPORT_CHECK %s %s" % ["PASS" if condition else "FAIL", label])

func _new_tunnel() -> PartialTunnel:
	var tunnel := PartialTunnel.new()
	tunnel._tcp = StreamPeerTCP.new()
	tunnel._state = "registered"
	return tunnel

func _test_partial_queue() -> void:
	var tunnel := _new_tunnel()
	tunnel.capacity = 3
	tunnel._send_message(4, PackedByteArray([11, 12, 13]))
	_check(tunnel.bytes == PackedByteArray([0, 0, 0]), "部分写只交付3字节，不阻塞")
	_check(tunnel._send_queue_bytes == 5 and int(tunnel._send_queue[0]["offset"]) == 3,
		"队列精确保留未写字节和偏移")
	tunnel.capacity = 0
	tunnel._send_message(5, PackedByteArray())
	_check(tunnel._send_queue.size() == 2 and tunnel._send_queue_bytes == 10, "背压后第二帧按顺序排队")
	tunnel.capacity = 100
	tunnel._flush_send_queue()
	_check(tunnel.bytes == PackedByteArray([0, 0, 0, 4, 4, 11, 12, 13, 0, 0, 0, 1, 5]),
		"恢复后帧头/载荷完整，已写字节不重复")
	_check(tunnel._send_queue.is_empty() and tunnel._send_queue_bytes == 0,
		"恢复后累计字节归零")
	var stats: Dictionary = tunnel.get_transport_stats()
	_check(int(stats["bytes_sent"]) == 13 and int(stats["send_partial_writes"]) > 0,
		"发送字节与部分写诊断可观测")
	tunnel.stop()
	_check(tunnel._tcp == null and tunnel._send_queue.is_empty(), "stop关闭连接并清队列")
	tunnel.free()

func _test_failures_and_bounds() -> void:
	var tunnel := _new_tunnel()
	tunnel.capacity = 0
	tunnel._send_message(4, PackedByteArray([1, 2]))
	tunnel._send_queue[0]["queued_msec"] = Time.get_ticks_msec() - tunnel.MAX_SEND_QUEUE_AGE_MSEC - 10
	tunnel._flush_send_queue()
	_check(tunnel._state == "closed" and tunnel._send_queue_bytes == 0,
		"过期积压明确关闭，不保持无限旧状态")
	tunnel.free()
	tunnel = _new_tunnel()
	tunnel._send_queue_bytes = tunnel.MAX_SEND_QUEUE_BYTES - 1
	tunnel._send_message(4, PackedByteArray([1]))
	_check(tunnel._state == "closed" and tunnel._tcp == null and tunnel._send_queue.is_empty(),
		"总字节硬上限会关闭并释放连接")
	tunnel.free()
	tunnel = _new_tunnel()
	tunnel.fail_write = true
	tunnel._send_message(4, PackedByteArray([1]))
	_check(tunnel._state == "closed" and tunnel._send_queue_bytes == 0,
		"写错误不假成功，清理待发字节")
	tunnel.free()

func _test_shared_write_budget() -> void:
	var tunnel := _new_tunnel()
	tunnel._outgoing_pumping = true
	tunnel._outgoing_deadline_usec = Time.get_ticks_usec() + 1000000
	tunnel._outgoing_write_remaining = 5
	tunnel.capacity = 100
	tunnel._send_message(4, PackedByteArray([1, 2, 3, 4]))
	tunnel._flush_send_queue()
	tunnel._flush_send_queue()
	_check(tunnel.bytes.size() == 5 and tunnel._outgoing_write_remaining == 0,
		"同次pump重复flush共享字节预算，不各自重置")
	_check(tunnel._send_queue_bytes == 4, "预算用尽后保留完整剩余字节")
	tunnel._outgoing_pumping = false
	tunnel._flush_send_queue()
	_check(tunnel.bytes == PackedByteArray([0, 0, 0, 5, 4, 1, 2, 3, 4]),
		"下一次pump恢复后仍按原偏移续传")
	tunnel.stop()
	tunnel.free()


func _test_registration_timeout() -> void:
	var server := TCPServer.new()
	var err: Error = server.listen(27982, "127.0.0.1")
	_check(err == OK, "注册超时测试服务监听成功")
	if err != OK:
		return
	var tunnel: Node = load("res://script/tunnel_client.gd").new()
	add_child(tunnel)
	tunnel.connect_timeout = 0.2
	tunnel.setup("127.0.0.1", 27982)
	tunnel.start(27983)
	var accepted: StreamPeerTCP = null
	var deadline: int = Time.get_ticks_msec() + 2500
	var saw_registration: bool = false
	while Time.get_ticks_msec() < deadline and tunnel._state != "closed":
		if accepted == null and server.is_connection_available():
			accepted = server.take_connection()
		if tunnel._state == "awaiting_registered":
			saw_registration = true
		await get_tree().process_frame
	_check(saw_registration and tunnel._state == "closed" and tunnel._tcp == null,
		"TCP已连但中继不回REGISTERED时自控超时，不永久挂起")
	tunnel.stop()
	tunnel.free()
	if accepted != null:
		accepted.disconnect_from_host()
	server.stop()


func _test_round_robin() -> void:
	var tunnel := _new_tunnel()
	var sockets: Array[PacketPeerUDP] = []
	var writers: Array[PacketPeerUDP] = []
	for client_id: int in [1, 2]:
		var socket := PacketPeerUDP.new()
		var err: Error = socket.bind(0, "127.0.0.1")
		_check(err == OK, "轮转测试UDP接收socket绑定 cid=%d" % client_id)
		var writer := PacketPeerUDP.new()
		writer.set_dest_address("127.0.0.1", socket.get_local_port())
		writer.put_packet(PackedByteArray([client_id]))
		sockets.append(socket)
		writers.append(writer)
		tunnel._clients[client_id] = {"socket": socket, "last_seen": Time.get_ticks_msec()}
	await get_tree().process_frame
	await get_tree().process_frame
	tunnel._outgoing_pumping = true
	tunnel._outgoing_deadline_usec = Time.get_ticks_usec() - 1
	tunnel._poll_game_outgoing()
	_check(tunnel._next_outgoing_client == 1 and tunnel._send_queue.is_empty(),
		"第一位耗尽时间预算后游标移向第二位，不固定从首peer重试")
	tunnel._outgoing_deadline_usec = Time.get_ticks_usec() + 1000000
	tunnel._poll_game_outgoing()
	var first_frame: PackedByteArray = tunnel._send_queue[0]["frame"] if not tunnel._send_queue.is_empty() else PackedByteArray()
	_check(first_frame.size() >= 8 and first_frame[6] == 2 and tunnel._send_queue.size() == 2,
		"下一轮从第二位优先排包，两个客户端均获得发送机会")
	tunnel._outgoing_pumping = false
	tunnel.stop()
	for writer: PacketPeerUDP in writers:
		writer.close()
	tunnel.free()


func _test_incoming_budget() -> void:
	var tunnel := IncomingTunnel.new()
	tunnel._state = "registered"
	for index: int in range(tunnel.MAX_MESSAGES_PER_PUMP + 20):
		tunnel._recv_buffer.append_array(PackedByteArray([0, 0, 0, 1, 5]))
	tunnel._process_messages()
	_check(tunnel.messages <= tunnel.MAX_MESSAGES_PER_PUMP and not tunnel._recv_buffer.is_empty(),
		"入站解帧有单次预算，剩余完整帧被保留")
	var attempts: int = 0
	while not tunnel._recv_buffer.is_empty() and attempts < 20:
		tunnel._process_messages()
		attempts += 1
	_check(tunnel.messages == tunnel.MAX_MESSAGES_PER_PUMP + 20 and tunnel._recv_buffer.is_empty(),
		"后续泵送处理全部帧，无预算丢包")
	tunnel.free()

func _test_lifecycle() -> void:
	var net: Node = get_node("/root/Net")
	var tree: SceneTree = get_tree()
	var original: bool = tree.multiplayer_poll
	net.upnp_enabled = false
	var err: Error = net.host_game(27981)
	_check(err == OK and not tree.multiplayer_poll, "建房后仅Net接管默认poll")
	_check(net.process_mode == Node.PROCESS_MODE_ALWAYS and net.process_priority < 0,
		"Net在业务前运行且不随暂停停止")
	var tail: Node = net.get_node_or_null("TransportTail")
	_check(tail != null and tail.process_mode == Node.PROCESS_MODE_ALWAYS
		and tail.process_priority > 0 and tail.process_physics_priority > 0,
		"出站收尾在业务后，两阶段都不随暂停停止")
	var before: int = int(net.get_network_diagnostics()["pump_polls"])
	net.reset_transport_trace()
	net._poll_transport(0)
	net._poll_transport(1)
	net.flush_transport()
	var trace: Dictionary = net.take_transport_trace()
	var phases: Array[int] = []
	for row: PackedInt64Array in trace["rows"]:
		phases.append(int(row[0]))
	_check(phases == [0, 1, 2] and int(trace["dropped"]) == 0, "诊断阶段记录区分physics/render poll及flush")
	var calls: int = int(net.get_network_diagnostics()["pump_polls"])
	net.poll_transport_render_tail()
	_check(int(net.get_network_diagnostics()["pump_polls"]) == calls, "晚poll默认关闭，生产派发频率不变")
	net._late_render_poll_enabled = true
	net.reset_transport_trace()
	net.poll_transport_render_tail()
	trace = net.take_transport_trace()
	_check(trace["rows"].size() == 1 and int(trace["rows"][0][0]) == 3,
		"显式实验晚poll记录独立phase，take关闭记录")
	net._late_render_poll_enabled = false
	net._poll_transport(0)
	_check(net.take_transport_trace()["rows"].is_empty(), "关闭采样后不产生新trace行")
	net.reset_transport_trace()
	net._transport_trace_rows.resize(net.TRANSPORT_TRACE_MAX_ROWS)
	net._record_transport_trace(0, Time.get_ticks_usec())
	trace = net.take_transport_trace()
	_check(trace["rows"].size() == net.TRANSPORT_TRACE_MAX_ROWS and int(trace["dropped"]) == 1,
		"trace有界，超限明确计数不扩大采样数组")
	tree.paused = true
	await tree.process_frame
	await tree.process_frame
	tree.paused = false
	_check(int(net.get_network_diagnostics()["pump_polls"]) > before, "暂停期间仍派发连接层网络")
	net.leave()
	_check(tree.multiplayer_poll == original and not bool(net.get_network_diagnostics()["pump_active"]),
		"离开恢复原poll设置并停泵")
	tree.multiplayer_poll = false
	err = net.host_game(27981)
	net.leave()
	_check(err == OK and not tree.multiplayer_poll, "原本关闭自动poll的上下文也被原样恢复")
	tree.multiplayer_poll = original

func _run() -> void:
	_test_partial_queue()
	_test_failures_and_bounds()
	_test_shared_write_budget()
	_test_incoming_budget()
	await _test_round_robin()
	await _test_registration_timeout()
	await _test_lifecycle()
	print("NETWORK_TRANSPORT_CHECK checks=%d failures=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
