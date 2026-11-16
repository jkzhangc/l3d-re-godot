extends SceneTree

## ── 架构定位 ──
## 系统：网络帧相位诊断 ｜ 层：tools独立双端长样本探针
## 纯诊断：复用生产 Net/Tunnel，不加载游戏场景，不修改配置或存档。
## 随机deadline仍由_process量化执行；echo/simulated共享可靠流，不把两者差值当物理等待。
## simulated 只是接收请求到诊断节点下一次物理回调的边界代理，并非真实游戏移动。
## 所有 *_usec 均为微秒；客户端 RTT 只减客户端时钟，host_wait 只减宿主时钟。
const MAX_QUEUE: int = 4096
const REPLY_TIMEOUT_USEC: int = 5000000
const TOTAL_TIMEOUT_SECONDS: float = 120.0

var _role: String = "client"
var _address: String = "127.0.0.1"
var _port: int = 27871
var _fps: int = 60
var _count: int = 500
var _seed: int = 31
var _start_delay_usec: int = 0
var _interval_usec: int = 50000
var _use_tunnel: bool = false
var _net: Node
var _tunnel: Node
var _probe: PhaseProbe
var _finished: bool = false
var _window_active: bool = false
var _window_start_usec: int = 0
var _window_end_usec: int = 0
var _last_render_usec: int = 0
var _last_physics_usec: int = 0
var _render_gaps: Array = []
var _physics_gaps: Array = []
var _trace_missing: bool = true
var _trace: Dictionary = {"rows": [], "dropped": 0}
var _rows: Array[Dictionary] = []
var _row_by_seq: Dictionary = {}
var _simulation_queue: Array[Dictionary] = []
var _queue_peak: int = 0
var _queue_overflow: int = 0
var _request_count: int = 0
var _echo_count: int = 0
var _simulated_count: int = 0
var _duplicates: Array[Dictionary] = []
var _invalid: Array[Dictionary] = []
var _errors: Array[String] = []
var _begin_sent: bool = false
var _begin_received: bool = false
var _send_enabled: bool = false
var _end_sent: bool = false
var _end_result_received: bool = false
var _end_ack_received: bool = false
var _host_peer: int = 0
var _host_result: Dictionary = {}
var _client_end_counts: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _schedule_anchor_usec: int = 0
var _deadline_usec: int = 0
var _deadline_index: int = -1
var _last_send_usec: int = 0
var _skipped: Array[Dictionary] = []

class PhaseProbe:
	extends Node
	var diagnostic: SceneTree

	func _process(_delta: float) -> void:
		diagnostic.call("_render_tick")

	func _physics_process(_delta: float) -> void:
		diagnostic.call("_physics_tick")

	@rpc("any_peer", "call_remote", "reliable")
	func begin(settings: Dictionary) -> void:
		diagnostic.call("_receive_begin", multiplayer.get_remote_sender_id(), settings)

	@rpc("authority", "call_remote", "reliable")
	func begin_ack() -> void:
		diagnostic.call("_receive_begin_ack")

	@rpc("any_peer", "call_remote", "reliable")
	func request(seq: int, client_stamp_usec: int) -> void:
		diagnostic.call("_receive_request", multiplayer.get_remote_sender_id(), seq, client_stamp_usec)

	@rpc("authority", "call_remote", "reliable")
	func echo(seq: int, client_stamp_usec: int) -> void:
		diagnostic.call("_receive_echo", seq, client_stamp_usec)

	@rpc("authority", "call_remote", "reliable")
	func simulated(seq: int, client_stamp_usec: int, host_wait_usec: int) -> void:
		diagnostic.call("_receive_simulated", seq, client_stamp_usec, host_wait_usec)

	@rpc("any_peer", "call_remote", "reliable")
	func end(counts: Dictionary) -> void:
		diagnostic.call("_receive_end", multiplayer.get_remote_sender_id(), counts)

	@rpc("authority", "call_remote", "reliable")
	func end_result(result: Dictionary) -> void:
		diagnostic.call("_receive_end_result", result)

	@rpc("authority", "call_remote", "reliable")
	func end_ack() -> void:
		diagnostic.call("_receive_end_ack")

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--phase-role="):
			_role = arg.trim_prefix("--phase-role=")
		elif arg.begins_with("--phase-address="):
			_address = arg.trim_prefix("--phase-address=").strip_edges()
		elif arg.begins_with("--phase-port="):
			_port = clampi(arg.trim_prefix("--phase-port=").to_int(), 1, 65535)
		elif arg.begins_with("--phase-fps="):
			_fps = clampi(arg.trim_prefix("--phase-fps=").to_int(), 1, 1000)
		elif arg.begins_with("--phase-count="):
			_count = clampi(arg.trim_prefix("--phase-count=").to_int(), 1, MAX_QUEUE)
		elif arg.begins_with("--phase-seed="):
			_seed = clampi(arg.trim_prefix("--phase-seed=").to_int(), 0, 2147483647)
		elif arg.begins_with("--phase-start-usec="):
			_start_delay_usec = clampi(arg.trim_prefix("--phase-start-usec=").to_int(), 0, 5000000)
		elif arg.begins_with("--phase-interval-usec="):
			_interval_usec = clampi(arg.trim_prefix("--phase-interval-usec=").to_int(), 5000, 1000000)
		elif arg == "--phase-tunnel":
			_use_tunnel = true
	if _address.is_empty():
		_address = "127.0.0.1"
	Engine.max_fps = _fps
	# Autoload 的 _ready 期间不能直接修改 root 子节点。
	call_deferred("_start")

func _start() -> void:
	if _role != "host" and _role != "client":
		_fail("phase-role 必须为 host 或 client")
		return
	_net = root.get_node_or_null("Net")
	_tunnel = root.get_node_or_null("Tunnel")
	if _net == null or (_role == "host" and _use_tunnel and _tunnel == null):
		_fail("缺少生产 Net/Tunnel Autoload")
		return
	_probe = PhaseProbe.new()
	_probe.name = "PhaseProbe"
	_probe.diagnostic = self
	_probe.process_priority = 0
	_probe.process_physics_priority = 0
	root.add_child(_probe)
	# 只改本次进程内的运行态，不调用任何配置保存接口。
	_net.set("upnp_enabled", false)
	_net.set("player_name", "PhaseDiagnostic")
	var failed_callback: Callable = _connection_failed
	var disconnected_callback: Callable = _server_disconnected
	_net.connect("connection_failed", failed_callback)
	_net.connect("server_disconnected", disconnected_callback)
	var timeout_callback: Callable = _overall_timeout
	create_timer(TOTAL_TIMEOUT_SECONDS).timeout.connect(timeout_callback)
	if _role == "host":
		var error: int = int(_net.call("host_game", _port))
		if error != OK:
			_fail("host_game: " + error_string(error))
			return
		if _use_tunnel:
			var ready_callback: Callable = _tunnel_ready
			var tunnel_failed_callback: Callable = _fail
			_tunnel.connect("tunnel_ready", ready_callback)
			_tunnel.connect("tunnel_failed", tunnel_failed_callback)
			_tunnel.call("setup", "8.138.99.96", 10001)
			_tunnel.call("start", _port)
		else:
			_print_ready("127.0.0.1", _port)
	else:
		var error: int = int(_net.call("join_game", _address, _port))
		if error != OK:
			_fail("join_game: " + error_string(error))

func _print_ready(address: String, port: int) -> void:
	if not _finished:
		print("PHASE_READY " + JSON.stringify({"address": address, "port": port}))

func _tunnel_ready(address: String, port: int) -> void:
	_print_ready(address, port)

func _settings() -> Dictionary:
	return {"role": _role, "address": _address, "port": _port, "fps_limit": _fps,
		"count": _count, "seed": _seed, "start_delay_usec": _start_delay_usec,
		"interval_usec": _interval_usec, "tunnel_requested": _use_tunnel,
		"threaded_io_requested": "--net-tunnel-threaded-io" in OS.get_cmdline_user_args(),
		"max_lateness_usec": _max_lateness_usec(), "total_timeout_seconds": TOTAL_TIMEOUT_SECONDS}

func _open_window() -> void:
	_window_start_usec = Time.get_ticks_usec()
	_window_active = true
	_last_render_usec = 0
	_last_physics_usec = 0
	_trace_missing = not (_net.has_method("reset_transport_trace") and _net.has_method("take_transport_trace"))
	if not _trace_missing:
		_net.call("reset_transport_trace", true)

func _close_window() -> void:
	if not _window_active:
		return
	_window_active = false
	_window_end_usec = Time.get_ticks_usec()
	if not _trace_missing:
		var snapshot: Variant = _net.call("take_transport_trace")
		if snapshot is Dictionary:
			_trace = snapshot
			if not _trace.has("rows") or not _trace.has("dropped"):
				_trace_missing = true
				_errors.append("take_transport_trace 缺少 rows/dropped 字段")
		else:
			_trace_missing = true
			_errors.append("take_transport_trace 未返回 Dictionary")
		_net.call("reset_transport_trace", false)

func _receive_begin(sender: int, settings: Dictionary) -> void:
	if _finished or _role != "host" or sender <= 1:
		return
	if _begin_received:
		_duplicates.append({"kind": "begin", "peer": sender})
		return
	_begin_received = true
	_host_peer = sender
	# 宿主采样使用客户端声明的发送目标；帧率仍分别使用各端启动参数。
	_count = clampi(int(settings.get("count", 500)), 1, MAX_QUEUE)
	_seed = clampi(int(settings.get("seed", 31)), 0, 2147483647)
	_interval_usec = clampi(int(settings.get("interval_usec", 50000)), 5000, 1000000)
	_start_delay_usec = clampi(int(settings.get("start_delay_usec", 0)), 0, 5000000)
	_open_window()
	var error: int = _probe.rpc_id(sender, &"begin_ack")
	if error != OK:
		_fail("begin_ack: " + error_string(error))

func _receive_begin_ack() -> void:
	if _finished or _role != "client" or not _begin_sent:
		return
	if _begin_received:
		_duplicates.append({"kind": "begin_ack"})
		return
	_begin_received = true
	_open_window()
	_rng.seed = _seed
	# start-usec 是 begin_ack 后的本地延后量，绝不是跨机共享的 ticks。
	_schedule_anchor_usec = _window_start_usec + _start_delay_usec
	_advance_deadline()
	var start_callback: Callable = _enable_sending
	create_timer(maxf(0.000001, float(_start_delay_usec) / 1000000.0)).timeout.connect(start_callback)

func _enable_sending() -> void:
	if not _finished and not _end_sent:
		_send_enabled = true

func _max_lateness_usec() -> int:
	return ceili(float(_interval_usec) * 1.45)

func _advance_deadline() -> void:
	if _deadline_index < 0:
		_deadline_usec = _schedule_anchor_usec
	_deadline_index += 1
	# 只累计独立 RNG 生成的间隔；绝不使用 now + interval 重设节拍。
	_deadline_usec += _rng.randi_range(ceili(float(_interval_usec) * 0.55), floori(float(_interval_usec) * 1.45))

func _render_tick() -> void:
	if _finished:
		return
	var now: int = Time.get_ticks_usec()
	if _window_active:
		if _last_render_usec > 0:
			_render_gaps.append([now, now - _last_render_usec, Engine.get_process_frames()])
		_last_render_usec = now
	if _role != "client" or _net == null:
		return
	if not _begin_sent:
		if bool(_net.call("is_online_session")):
			_begin_sent = true
			var error: int = _probe.rpc_id(1, &"begin", _settings())
			if error != OK:
				_fail("begin: " + error_string(error))
		return
	if not _window_active or not _send_enabled or _end_sent:
		return
	if _rows.size() < _count:
		if now < _deadline_usec:
			return
		# 严重迟到的 slot 直接丢弃但保留原始记录；seq 只随真正发包递增。
		while now - _deadline_usec > _max_lateness_usec():
			_skipped.append({"deadline_index": _deadline_index, "deadline_usec": _deadline_usec,
				"deadline_offset_usec": _deadline_usec - _schedule_anchor_usec,
				"observed_usec": now, "lateness_usec": now - _deadline_usec})
			_advance_deadline()
		if now >= _deadline_usec:
			_send_request()
		# 每次 _process 最多发一个，即使高负载也不追赶突发。
		return
	if _echo_count == _count and _simulated_count == _count:
		_send_end()
	elif now - _last_send_usec >= REPLY_TIMEOUT_USEC:
		_errors.append("最后请求发出后 5000000 usec 仍未收齐 echo/simulated")
		_send_end()

func _send_request() -> void:
	var stamp: int = Time.get_ticks_usec()
	var seq: int = _rows.size()
	var row: Dictionary = {"seq": seq, "client_stamp_usec": stamp,
		"deadline_index": _deadline_index, "deadline_usec": _deadline_usec,
		"deadline_offset_usec": _deadline_usec - _schedule_anchor_usec,
		"send_usec": stamp, "lateness_usec": stamp - _deadline_usec,
		"process_frame": Engine.get_process_frames(), "physics_frame": Engine.get_physics_frames(),
		"echo_recv_usec": -1, "echo_rtt_usec": -1,
		"simulated_recv_usec": -1, "simulated_rtt_usec": -1, "host_wait_usec": -1}
	_rows.append(row)
	_row_by_seq[seq] = row
	_last_send_usec = stamp
	_request_count += 1
	var error: int = _probe.rpc_id(1, &"request", seq, stamp)
	if error != OK:
		_errors.append("request seq=%d: %s" % [seq, error_string(error)])
	_advance_deadline()

func _receive_request(sender: int, seq: int, client_stamp_usec: int) -> void:
	var received_usec: int = Time.get_ticks_usec()
	if _finished or not _window_active or _role != "host" or sender != _host_peer:
		return
	_request_count += 1
	if seq < 0 or seq >= _count or client_stamp_usec < 0:
		_invalid.append({"kind": "request", "seq": seq, "stamp_usec": client_stamp_usec})
		return
	# 第一种响应不等物理帧；这里不强制 flush，不改变待测生产传输调度。
	var error: int = _probe.rpc_id(sender, &"echo", seq, client_stamp_usec)
	if error != OK:
		_errors.append("echo seq=%d: %s" % [seq, error_string(error)])
	_echo_count += 1
	if _row_by_seq.has(seq):
		_duplicates.append({"kind": "request", "seq": seq, "stamp_usec": client_stamp_usec,
			"received_usec": received_usec})
		return
	var row: Dictionary = {"seq": seq, "client_stamp_usec": client_stamp_usec,
		"received_usec": received_usec, "recv_process_frame": Engine.get_process_frames(),
		"recv_physics_frame": Engine.get_physics_frames(), "simulated_usec": -1,
		"simulated_process_frame": -1, "simulated_physics_frame": -1, "host_wait_usec": -1}
	_rows.append(row)
	_row_by_seq[seq] = row
	if _simulation_queue.size() >= MAX_QUEUE:
		_queue_overflow += 1
		return
	_simulation_queue.append(row)
	_queue_peak = maxi(_queue_peak, _simulation_queue.size())

func _physics_tick() -> void:
	if _finished or not _window_active:
		return
	var now: int = Time.get_ticks_usec()
	if _last_physics_usec > 0:
		_physics_gaps.append([now, now - _last_physics_usec, Engine.get_physics_frames()])
	_last_physics_usec = now
	if _role != "host":
		return
	# Net 在 -10000 优先级轮询；本节点在 0 优先级的下一次回调消费队列。
	# 若请求在本物理帧的 head poll 收到，可在同一物理帧消费，不额外强加一帧。
	for row: Dictionary in _simulation_queue:
		var simulated_usec: int = Time.get_ticks_usec()
		var wait_usec: int = simulated_usec - int(row["received_usec"])
		row["simulated_usec"] = simulated_usec
		row["simulated_process_frame"] = Engine.get_process_frames()
		row["simulated_physics_frame"] = Engine.get_physics_frames()
		row["host_wait_usec"] = wait_usec
		var error: int = _probe.rpc_id(_host_peer, &"simulated", int(row["seq"]), int(row["client_stamp_usec"]), wait_usec)
		if error != OK:
			_errors.append("simulated seq=%d: %s" % [int(row["seq"]), error_string(error)])
		_simulated_count += 1
	_simulation_queue.clear()

func _reply_row(kind: String, seq: int, stamp: int, received_usec: int) -> Dictionary:
	if not _row_by_seq.has(seq):
		_invalid.append({"kind": kind, "seq": seq, "stamp_usec": stamp, "received_usec": received_usec})
		return {}
	var row: Dictionary = _row_by_seq[seq]
	if int(row["client_stamp_usec"]) != stamp:
		_invalid.append({"kind": kind, "seq": seq, "stamp_usec": stamp, "received_usec": received_usec})
		return {}
	if int(row[kind + "_recv_usec"]) >= 0:
		_duplicates.append({"kind": kind, "seq": seq, "stamp_usec": stamp, "received_usec": received_usec})
		return {}
	return row

func _receive_echo(seq: int, stamp: int) -> void:
	if _finished or _role != "client":
		return
	var now: int = Time.get_ticks_usec()
	var row: Dictionary = _reply_row("echo", seq, stamp, now)
	if row.is_empty():
		return
	row["echo_recv_usec"] = now
	row["echo_rtt_usec"] = now - stamp
	_echo_count += 1

func _receive_simulated(seq: int, stamp: int, host_wait_usec: int) -> void:
	if _finished or _role != "client":
		return
	var now: int = Time.get_ticks_usec()
	var row: Dictionary = _reply_row("simulated", seq, stamp, now)
	if row.is_empty():
		return
	if host_wait_usec < 0:
		_invalid.append({"kind": "negative_host_wait", "seq": seq, "host_wait_usec": host_wait_usec})
		return
	row["simulated_recv_usec"] = now
	row["simulated_rtt_usec"] = now - stamp
	row["host_wait_usec"] = host_wait_usec
	_simulated_count += 1

func _missing(kind: String) -> Array[int]:
	var missing: Array[int] = []
	for seq: int in range(_count):
		if not _row_by_seq.has(seq):
			missing.append(seq)
		elif _role == "client":
			var row: Dictionary = _row_by_seq[seq]
			if int(row[kind + "_recv_usec"]) < 0:
				missing.append(seq)
		elif kind == "simulated":
			var row: Dictionary = _row_by_seq[seq]
			if int(row["simulated_usec"]) < 0:
				missing.append(seq)
	return missing

func _counts() -> Dictionary:
	return {"target": _count, "requests": _request_count, "rows": _rows.size(),
		"echo": _echo_count, "simulated": _simulated_count,
		"missing_echo_seq": _missing("echo"), "missing_simulated_seq": _missing("simulated"),
		"duplicates": _duplicates.size(), "invalid": _invalid.size(), "errors": _errors.size(),
		"skipped": _skipped.size(), "queue_pending": _simulation_queue.size(),
		"queue_peak": _queue_peak, "queue_overflow": _queue_overflow}

func _send_end() -> void:
	if _end_sent or _finished:
		return
	_end_sent = true
	_close_window()
	var error: int = _probe.rpc_id(1, &"end", _counts())
	if error != OK:
		_fail("end: " + error_string(error))
		return
	var end_timeout_callback: Callable = _end_timeout
	create_timer(5.0).timeout.connect(end_timeout_callback)

func _receive_end(sender: int, counts: Dictionary) -> void:
	if _finished or _role != "host" or sender != _host_peer or not _begin_received:
		return
	_client_end_counts = counts
	_close_window()
	var result: Dictionary = _result()
	var brief: Dictionary = {"ok": result["ok"], "counts": result["counts"],
		"summary": result["summary"], "trace_missing": _trace_missing,
		"trace_dropped": _trace.get("dropped", 0), "window_start_usec": _window_start_usec,
		"window_end_usec": _window_end_usec, "errors": _errors}
	# 全量原始数据只写宿主日志；RPC 回传汇总，避免大包污染测量。
	var result_error: int = _probe.rpc_id(sender, &"end_result", brief)
	var ack_error: int = _probe.rpc_id(sender, &"end_ack")
	if result_error != OK or ack_error != OK:
		_errors.append("end_result/end_ack: %s / %s" % [error_string(result_error), error_string(ack_error)])
		result["ok"] = false
		result["errors"] = _errors
	print("PHASE_HOST_RESULT " + JSON.stringify(result))
	_finished = true
	var exit_code: int = 0 if bool(result["ok"]) else 1
	var stop_callback: Callable = _shutdown.bind(exit_code)
	# 给可靠 end_result/end_ack 留出发送机会，不用 OS.sleep 阻塞主线程。
	create_timer(0.15).timeout.connect(stop_callback)

func _receive_end_result(result: Dictionary) -> void:
	if _finished or _role != "client" or not _end_sent:
		return
	if _end_result_received:
		_duplicates.append({"kind": "end_result"})
		return
	_end_result_received = true
	_host_result = result
	_try_finish_client()

func _receive_end_ack() -> void:
	if _finished or _role != "client" or not _end_sent:
		return
	if _end_ack_received:
		_duplicates.append({"kind": "end_ack"})
		return
	_end_ack_received = true
	_try_finish_client()

func _try_finish_client() -> void:
	if not _end_result_received or not _end_ack_received:
		return
	var result: Dictionary = _result()
	result["host_result"] = _host_result
	result["ok"] = bool(result["ok"]) and bool(_host_result.get("ok", false))
	print("PHASE_RESULT " + JSON.stringify(result))
	_finished = true
	call_deferred("_shutdown", 0 if bool(result["ok"]) else 1)

func _summary(values: Array) -> Dictionary:
	if values.is_empty():
		return {"unit": "usec", "n": 0, "min_usec": null, "p50_usec": null,
			"p95_usec": null, "p99_usec": null, "max_usec": null}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	return {"unit": "usec", "n": n, "min_usec": sorted[0],
		"p50_usec": sorted[maxi(0, ceili(float(n) * 0.50) - 1)],
		"p95_usec": sorted[maxi(0, ceili(float(n) * 0.95) - 1)],
		"p99_usec": sorted[maxi(0, ceili(float(n) * 0.99) - 1)], "max_usec": sorted[-1]}

func _summaries() -> Dictionary:
	var summaries: Dictionary = {}
	var fields: Array[String] = ["host_wait_usec"]
	if _role == "client":
		fields.append_array(["echo_rtt_usec", "simulated_rtt_usec", "lateness_usec"])
	for field: String in fields:
		var values: Array = []
		for row: Dictionary in _rows:
			var value: int = int(row.get(field, -1))
			if value >= 0:
				values.append(value)
		summaries[field] = _summary(values)
	var render_values: Array = []
	for gap: Array in _render_gaps:
		render_values.append(gap[1])
	var physics_values: Array = []
	for gap: Array in _physics_gaps:
		physics_values.append(gap[1])
	summaries["render_gap_usec"] = _summary(render_values)
	summaries["physics_gap_usec"] = _summary(physics_values)
	return summaries

func _result() -> Dictionary:
	var counts: Dictionary = _counts()
	var missing_echo: Array = counts["missing_echo_seq"]
	var missing_simulated: Array = counts["missing_simulated_seq"]
	var ok: bool = (_begin_received and _window_end_usec > 0 and _rows.size() == _count
		and missing_echo.is_empty() and missing_simulated.is_empty()
		and _duplicates.is_empty() and _invalid.is_empty() and _errors.is_empty()
		and _queue_overflow == 0 and not _trace_missing and int(_trace.get("dropped", 0)) == 0)
	if _role == "host":
		var client_missing_echo: Array = _client_end_counts.get("missing_echo_seq", [-1])
		var client_missing_simulated: Array = _client_end_counts.get("missing_simulated_seq", [-1])
		ok = (ok and int(_client_end_counts.get("requests", -1)) == _count
			and int(_client_end_counts.get("echo", -1)) == _count
			and int(_client_end_counts.get("simulated", -1)) == _count
			and client_missing_echo.is_empty() and client_missing_simulated.is_empty()
			and int(_client_end_counts.get("duplicates", -1)) == 0
			and int(_client_end_counts.get("invalid", -1)) == 0
			and int(_client_end_counts.get("errors", -1)) == 0)
	return {"ok": ok, "settings": _settings(), "time_unit": "usec",
		"measurement": "模拟物理边界代理，非真实游戏移动；跨机 ticks 不做相减",
		"clock_domain": _role + "_local_monotonic", "window_start_usec": _window_start_usec,
		"window_end_usec": _window_end_usec,
		"window_duration_usec": maxi(0, _window_end_usec - _window_start_usec),
		"schedule_anchor_usec": _schedule_anchor_usec, "rows": _rows,
		"gap_columns": ["sample_usec", "gap_usec", "local_frame"],
		"render_gap_rows": _render_gaps, "physics_gap_rows": _physics_gaps,
		"skipped_deadline_rows": _skipped, "counts": counts, "summary": _summaries(),
		"duplicates": _duplicates, "invalid": _invalid, "errors": _errors,
		"trace_missing": _trace_missing, "net_trace": _trace,
		"protocol": {"begin_sent": _begin_sent, "begin_received": _begin_received,
			"end_sent": _end_sent, "end_received": not _client_end_counts.is_empty(),
			"end_result_received": _end_result_received, "end_ack_received": _end_ack_received},
		"client_end_counts": _client_end_counts,
		"tunnel_stats": _tunnel.call("get_transport_stats") if _role == "host" and _use_tunnel and _tunnel != null else {}}

func _connection_failed() -> void:
	_fail("生产 Net 连接失败")

func _server_disconnected() -> void:
	_fail("收到生产 Net server_disconnected，end 协议尚未完成")

func _overall_timeout() -> void:
	_fail("整体 120 秒超时")

func _end_timeout() -> void:
	if not _finished:
		_fail("end_result/end_ack 等待 5 秒超时")

func _fail(message: String) -> void:
	if _finished:
		return
	_errors.append(message)
	_close_window()
	var result: Dictionary = _result()
	result["ok"] = false
	if _role == "client":
		result["host_result"] = _host_result
	print(("PHASE_HOST_RESULT " if _role == "host" else "PHASE_RESULT ") + JSON.stringify(result))
	printerr("PHASE_ERROR " + message)
	_finished = true
	# RPC/Autoload 回调中不直接拆卸生产 MultiplayerPeer。
	call_deferred("_shutdown", 1)

func _shutdown(exit_code: int) -> void:
	if _role == "host" and _use_tunnel and _tunnel != null:
		_tunnel.call("stop")
	if _net != null:
		_net.call("leave")
	quit(exit_code)
