extends RefCounted

## 仅供本机实验：主线程只交换配置、停止标记和统计，socket 与 codec 全归工作线程。
const Codec = preload("res://script/udp_tunnel_codec.gd")
const LOOPBACK := "127.0.0.1"
const MAX_PACKETS_PER_DIRECTION := 64
const PUMP_BUDGET_USEC := 2000
const PUBLISH_INTERVAL_USEC := 20000

var _thread: Thread = null
var _mutex := Mutex.new()
var _stop_requested: bool = false
var _published_stats: Dictionary = {}

# 以下字段只在工作线程读写；主线程必须 stop/join 后才可再次 start。
var _sessions: Array[Dictionary] = []
var _stats: Dictionary = {}
var _last_publish_usec: int = 0
var _next_slot: int = 0


func start(config: Dictionary) -> Error:
	if is_started():
		return ERR_ALREADY_IN_USE
	var snapshot: Dictionary = config.duplicate(true)
	if not _valid_config(snapshot):
		return ERR_INVALID_PARAMETER
	# 不把控制面 token 或其他无关字段带入工作线程。
	var worker_config: Dictionary = {
		"host_port": int(snapshot["host_port"]),
		"sessions": snapshot["sessions"].duplicate(true),
		"ttl_msec": int(snapshot.get("ttl_msec", 120000)),
		"poll_interval_usec": int(snapshot.get("poll_interval_usec", 1000)),
	}
	snapshot.clear()
	_mutex.lock()
	_stop_requested = false
	_published_stats = _empty_stats("starting", true)
	_mutex.unlock()
	_thread = Thread.new()
	# 显式保持强引用；调用方不能以释放引用代替 stop/join。
	var error: Error = _thread.start(_thread_main.bind(worker_config, self))
	if error != OK:
		worker_config.clear()
		var failed: Dictionary = _empty_stats("closed", false)
		failed["startup_error"] = int(error)
		_mutex.lock()
		_published_stats = failed
		_mutex.unlock()
		_thread = null
	return error


## start、stop、is_started 只由主线程调用；绝不持锁 join。
func stop() -> void:
	_mutex.lock()
	_stop_requested = true
	_mutex.unlock()
	if is_started():
		_thread.wait_to_finish()
	_thread = null
	_mutex.lock()
	if _published_stats.is_empty():
		_published_stats = _empty_stats("closed", false)
	_mutex.unlock()


func is_started() -> bool:
	return _thread != null and _thread.is_started()


func get_stats() -> Dictionary:
	_mutex.lock()
	var snapshot: Dictionary = _published_stats.duplicate(true)
	_mutex.unlock()
	return _empty_stats("idle", false) if snapshot.is_empty() else snapshot


func _valid_config(config: Dictionary) -> bool:
	if not _integer_in_range(config.get("host_port"), 1, 65535):
		return false
	if not _integer_in_range(config.get("ttl_msec", 120000), 1, 2147483647):
		return false
	if not _integer_in_range(config.get("poll_interval_usec", 1000), 1, 20000):
		return false
	var sessions: Variant = config.get("sessions")
	if not sessions is Array or sessions.size() < 1 or sessions.size() > 3:
		return false
	for item: Variant in sessions:
		if not item is Dictionary:
			return false
		if not _valid_hex(item.get("session_id_hex"), 16) or not _valid_hex(item.get("key_hex"), 64):
			return false
		if not _integer_in_range(item.get("source_port"), 1, 65535) \
				or not _integer_in_range(item.get("return_port"), 1, 65535):
			return false
	return true


func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number == floor(number) and number >= minimum and number <= maximum


func _valid_hex(value: Variant, length: int) -> bool:
	if not value is String or value.length() != length:
		return false
	for index: int in range(length):
		if "0123456789abcdefABCDEF".find(value.substr(index, 1)) < 0:
			return false
	return true


func _empty_counters() -> Dictionary:
	return {"transport_packets": 0, "raw_packets": 0, "accepted_packets": 0,
		"rejected_packets": 0, "rejected_no_forward": 0, "forwarded_packets": 0,
		"sealed_packets": 0, "returned_packets": 0, "raw_oversize": 0,
		"wire_oversize": 0, "seal_rejected": 0, "io_errors": 0, "busy_errors": 0,
		"receive_errors": 0, "send_drops": 0, "busy_drops": 0}


func _empty_stats(state: String, running: bool) -> Dictionary:
	return {"state": state, "running": running, "ready": false,
		"ports": [], "backend_ports": [], "sessions": [], "totals": _empty_counters(),
		"iterations": 0, "max_iteration_gap_usec": 0, "work_usec": 0,
		"last_pump_usec": 0, "max_pump_usec": 0, "created_sockets": 0,
		"closed_sockets": 0, "startup_error": int(OK),
		"max_payload": Codec.MAX_PAYLOAD, "max_datagram": Codec.MAX_DATAGRAM}


func _should_stop() -> bool:
	_mutex.lock()
	var requested: bool = _stop_requested
	_mutex.unlock()
	return requested


func _thread_main(config: Dictionary, _lifetime_guard: RefCounted) -> void:
	_sessions = []
	_stats = _empty_stats("starting", true)
	_last_publish_usec = 0
	_next_slot = 0
	var poll_interval_usec: int = int(config["poll_interval_usec"])
	var error: Error = _open_sessions(config)
	# 丢弃工作线程配置副本；凭据此后只由各 codec 持有。
	config.clear()
	_stats["startup_error"] = int(error)
	if error == OK:
		_stats["state"] = "running"
		_stats["ready"] = true
		_publish(true)
		var previous_usec: int = Time.get_ticks_usec()
		while not _should_stop():
			var started_usec: int = Time.get_ticks_usec()
			_stats["max_iteration_gap_usec"] = maxi(int(_stats["max_iteration_gap_usec"]), started_usec - previous_usec)
			previous_usec = started_usec
			_stats["iterations"] += 1
			_pump(started_usec + PUMP_BUDGET_USEC)
			var elapsed_usec: int = Time.get_ticks_usec() - started_usec
			_stats["last_pump_usec"] = elapsed_usec
			_stats["work_usec"] += elapsed_usec
			_stats["max_pump_usec"] = maxi(int(_stats["max_pump_usec"]), elapsed_usec)
			_publish()
			if _should_stop():
				break
			OS.delay_usec(maxi(1, poll_interval_usec - (Time.get_ticks_usec() - started_usec)))
	_close_sessions()
	_stats["state"] = "closed"
	_stats["running"] = false
	_stats["ready"] = false
	_publish(true)


func _open_sessions(config: Dictionary) -> Error:
	# 先登记全部资源，任一 bind/configure 失败也走唯一清理路径。
	for item: Dictionary in config["sessions"]:
		var counters: Dictionary = _empty_counters()
		_sessions.append({"transport": PacketPeerUDP.new(), "backend": PacketPeerUDP.new(),
			"codec": Codec.new(), "return_port": int(item["return_port"]), "counters": counters})
		_stats["sessions"].append(counters)
		_stats["created_sockets"] += 2
	var expires_at_msec: int = Time.get_ticks_msec() + int(config["ttl_msec"])
	for index: int in range(_sessions.size()):
		var session: Dictionary = _sessions[index]
		var item: Dictionary = config["sessions"][index]
		var transport: PacketPeerUDP = session["transport"]
		var backend: PacketPeerUDP = session["backend"]
		var codec: Codec = session["codec"]
		var key: PackedByteArray = String(item["key_hex"]).hex_decode()
		var error: Error = codec.configure(String(item["session_id_hex"]).hex_decode(), key,
			1, LOOPBACK, int(item["source_port"]), expires_at_msec)
		key.fill(0)
		key.clear()
		item.erase("key_hex")
		item.erase("session_id_hex")
		if error != OK:
			return error
		error = transport.bind(0, LOOPBACK)
		if error == OK:
			error = backend.bind(0, LOOPBACK)
		if error == OK:
			error = backend.connect_to_host(LOOPBACK, int(config["host_port"]))
		if error != OK:
			_record_io_error(session["counters"], error)
			return error
		_stats["ports"].append(transport.get_local_port())
		_stats["backend_ports"].append(backend.get_local_port())
	return OK


func _pump(deadline_usec: int) -> void:
	var slots: int = _sessions.size() * 2
	var start_slot: int = _next_slot
	for step: int in range(slots):
		var slot: int = (start_slot + step) % slots
		if Time.get_ticks_usec() >= deadline_usec or _should_stop():
			_next_slot = slot
			return
		# 单个方向耗尽预算后，下一轮从它的后继方向开始。
		_next_slot = (slot + 1) % slots
		var session: Dictionary = _sessions[slot >> 1]
		if slot % 2 == 0:
			_pump_transport(session, deadline_usec)
		else:
			_pump_backend(session, deadline_usec)
	_next_slot = (start_slot + 1) % slots


func _pump_transport(session: Dictionary, deadline_usec: int) -> void:
	var transport: PacketPeerUDP = session["transport"]
	var backend: PacketPeerUDP = session["backend"]
	var codec: Codec = session["codec"]
	var counters: Dictionary = session["counters"]
	for _packet_index: int in range(MAX_PACKETS_PER_DIRECTION):
		if Time.get_ticks_usec() >= deadline_usec or transport.get_available_packet_count() <= 0:
			return
		var packet: PackedByteArray = transport.get_packet()
		# 来源元数据对应刚刚取出的包，不能在 get_packet 之前读取。
		var source_ip: String = transport.get_packet_ip()
		var source_port: int = transport.get_packet_port()
		var error: Error = transport.get_packet_error()
		if error != OK:
			counters["receive_errors"] += 1
			_record_io_error(counters, error)
			return
		counters["transport_packets"] += 1
		if packet.size() > Codec.MAX_DATAGRAM:
			counters["wire_oversize"] += 1
		var payload: PackedByteArray = codec.open(packet, source_ip, source_port)
		if payload.is_empty():
			counters["rejected_packets"] += 1
			counters["rejected_no_forward"] += 1
			continue
		counters["accepted_packets"] += 1
		error = backend.put_packet(payload)
		if error == OK:
			counters["forwarded_packets"] += 1
		else:
			_record_send_drop(counters, error)


func _pump_backend(session: Dictionary, deadline_usec: int) -> void:
	var transport: PacketPeerUDP = session["transport"]
	var backend: PacketPeerUDP = session["backend"]
	var codec: Codec = session["codec"]
	var counters: Dictionary = session["counters"]
	for _packet_index: int in range(MAX_PACKETS_PER_DIRECTION):
		if Time.get_ticks_usec() >= deadline_usec or backend.get_available_packet_count() <= 0:
			return
		var raw: PackedByteArray = backend.get_packet()
		var error: Error = backend.get_packet_error()
		if error != OK:
			counters["receive_errors"] += 1
			_record_io_error(counters, error)
			return
		counters["raw_packets"] += 1
		if raw.size() > Codec.MAX_PAYLOAD:
			counters["raw_oversize"] += 1
			continue
		var packet: PackedByteArray = codec.seal(raw)
		if packet.is_empty():
			counters["seal_rejected"] += 1
			continue
		counters["sealed_packets"] += 1
		error = transport.set_dest_address(LOOPBACK, int(session["return_port"]))
		if error == OK:
			error = transport.put_packet(packet)
		if error == OK:
			counters["returned_packets"] += 1
		else:
			_record_send_drop(counters, error)


func _record_io_error(counters: Dictionary, error: Error) -> void:
	if error == ERR_BUSY:
		counters["busy_errors"] += 1
	else:
		counters["io_errors"] += 1


func _record_send_drop(counters: Dictionary, error: Error) -> void:
	_record_io_error(counters, error)
	counters["send_drops"] += 1
	if error == ERR_BUSY:
		counters["busy_drops"] += 1
	# UDP 忙时直接丢弃；不引入重排、重传或用户态排队。


func _close_sessions() -> void:
	for session: Dictionary in _sessions:
		var transport: PacketPeerUDP = session["transport"]
		var backend: PacketPeerUDP = session["backend"]
		var codec: Codec = session["codec"]
		transport.close()
		backend.close()
		codec.close()
		_stats["closed_sockets"] += 2
	_sessions.clear()


func _publish(force: bool = false) -> void:
	var now_usec: int = Time.get_ticks_usec()
	if not force and now_usec - _last_publish_usec < PUBLISH_INTERVAL_USEC:
		return
	_last_publish_usec = now_usec
	var totals: Dictionary = _empty_counters()
	for counters: Dictionary in _stats["sessions"]:
		for counter: String in totals:
			totals[counter] += int(counters[counter])
	_stats["totals"] = totals
	var snapshot: Dictionary = _stats.duplicate(true)
	_mutex.lock()
	_published_stats = snapshot
	_mutex.unlock()
