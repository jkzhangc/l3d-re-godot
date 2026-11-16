extends Node

## 隧道客户端（路线二）：在游戏内内置 UDP-over-TCP 隧道，替代 frpc。
##
## 原理：房主本机的 ENet Host 监听 UDP game_port；本客户端用 TCP 连到云端中继，
## 把外网客户端经中继转发来的数据用 UDP 投给本机游戏，反向亦然。
## 对 ENet 协议完全透明——只是搬运原始 UDP 字节。
##
## 数据流：
##   本机游戏(ENet, 127.0.0.1:game_port) ←UDP→ [本客户端] ←TCP→ [中继] ←UDP→ 外网客户端
##
## per-client socket 模型（对齐 udp_relay.py 实测验证的逻辑）：
##   每个外网客户端由中继分配 2 字节 clientId；本客户端为每个 clientId 创建
##   独立的 PacketPeerUDP（绑定不同本地源端口 → ENet Host 按源地址区分 peer）。
##
## 用法（由 network_lobby.gd 驱动）：
##   1. setup(server_host, server_port)
##   2. start(game_port)              → 连中继，REGISTER
##   3. 等 tunnel_ready 信号          → 用公网地址注册房间
##   4. _process 自动双向转发
##   5. stop()                        → RELEASE + 断开
##
## 相关文档：`互联网联机模式策划方案.md` §2（房主可达性，路线二）

signal tunnel_ready(public_address: String, public_port: int)
signal tunnel_failed(reason: String)
signal tunnel_closed()

# ── 二进制协议（与服务端 tunnel_relay.js 对齐）──
const MSG_REGISTER := 0x01
const MSG_REGISTERED := 0x02
const MSG_RELAY_TO_HOST := 0x03
const MSG_RELAY_FROM_HOST := 0x04
const MSG_KEEPALIVE := 0x05
const MSG_RELEASE := 0x06
const MSG_ERROR := 0x07

## 中继服务 TCP 端口（与服务端 tunnel_relay.js DEFAULT_TCP_PORT 一致）。
const TUNNEL_TCP_PORT := 10001
## 连接中继的**自控超时**（秒）。
## ★ 为什么必须自控（2026-10 实测 + 引擎源码坐实）：Godot 的 StreamPeerTCP 在「对端不响应」
## 与「对端主动拒绝(RST)」两种情况下**都不会及时暴露失败** —— 实测黑洞地址与本地无监听
## 端口**都恰好等到 30.0s** 才转 STATUS_ERROR（回归用例：
## `.workbuddy/tmp/tunnel_connect_timeout_check.*`）。
## 根因（引擎源码，已坐实）：`core/io/stream_peer_tcp.cpp` 的 `poll()` 在 STATUS_CONNECTING 时
## 重试 `_sock->connect_to_host()`，**只有等到 `timeout` 才转 STATUS_ERROR**；`timeout` 由
## `connect_to_host()` 设为 `now + GLOBAL_GET("network/limits/tcp/connect_timeout_seconds")*1000`
## —— 该设置**官方默认 30 秒**，本项目 project.godot 未覆盖 → 恒为 30s。
## 不设自控超时，玩家会卡在「正在连接隧道服务…」整整 30 秒且**无法取消/重试**，
## 且"地址填错"与"防火墙丢包"在 UI 上完全同相、无法区分。
const CONNECT_TIMEOUT := 10.0
## 房主侧心跳间隔（与服务端 HOST_TIMEOUT_MS 配套，10s 一次，120s 超时）。
const KEEPALIVE_INTERVAL := 10.0
## per-client UDP socket 空闲多久后回收（秒，对齐中继 60s 客户端超时）。
const CLIENT_IDLE_TIMEOUT := 60.0
## 每帧每个客户端最多转发多少个出站包（防突发打满 TCP 缓冲）。
const MAX_OUTGOING_PER_CLIENT := 64
## 单包上限（对齐 ENet MTU 1392 + 安全余量；超过的包直接丢，与 frps udpPacketSize 同义）。
const MAX_PACKET_SIZE := 1500
## 单帧上限（★ 2026-10 修 P3）：帧长来自 TCP 流、对端可控；若不校验，恶意/损坏的
## 大 length 会让 `_recv_buffer` 无限增长（服务端同款漏洞实测灌 5MB 涨 5MB）。
## 合法帧最大 = [2字节 clientId] + UDP 数据(≤1500) 或 REGISTERED 的小 JSON，均 < 8KB。
const MAX_FRAME_SIZE := 8192
## @trace NET-LAT-P1：限制应用累计队列与每次泵送工作量，不任意丢弃ENet数据报。
const MAX_SEND_QUEUE_BYTES := 512 * 1024
const MAX_SEND_QUEUE_AGE_MSEC := 2000
const MAX_RECV_BUFFER_BYTES := 512 * 1024
const MAX_READ_BYTES_PER_PUMP := 128 * 1024
const MAX_WRITE_BYTES_PER_PUMP := 128 * 1024
const MAX_MESSAGES_PER_PUMP := 256
const PUMP_BUDGET_USEC := 2000

var _tcp: StreamPeerTCP = null
var _server_host: String = ""
var _server_port: int = TUNNEL_TCP_PORT
var _game_port: int = 27015
var _recv_buffer: PackedByteArray = PackedByteArray()
var _state: String = "idle"  # idle / connecting / awaiting_registered / registered / closed
var _public_port: int = 0
var _tunnel_id: String = ""
var _keepalive_accum: float = 0.0
## 连接阶段的累计耗时（秒）——用于自控超时（见 CONNECT_TIMEOUT）。
## 声明为实例变量而非直接读常量：无头用例可注入短值，避免测试真等 10s。
var _connect_accum: float = 0.0
## 实际的连接超时秒数（默认取 CONNECT_TIMEOUT，用例可覆写）。
var connect_timeout: float = CONNECT_TIMEOUT
## clientId(int) → { "socket": PacketPeerUDP, "last_seen": float(Time.get_ticks_msec) }
var _clients: Dictionary = {}
var _idle_check_accum: float = 0.0
var _send_queue: Array[Dictionary] = []
var _send_queue_bytes: int = 0
var _send_queue_peak_bytes: int = 0
var _send_partial_writes: int = 0
var _bytes_sent: int = 0
var _bytes_received: int = 0
var _last_pump_usec: int = 0
var _max_pump_usec: int = 0
var _incoming_pumping: bool = false
var _outgoing_pumping: bool = false
var _outgoing_deadline_usec: int = 0
var _outgoing_write_remaining: int = 0
var _next_outgoing_client: int = 0
var _register_accum: float = 0.0

## @trace NET-LAT-P2：worker独占socket；门面只在主线程派发连接事件，业务RPC仍由Net执行。
const IO_WORKER := preload("res://script/tunnel_io_worker.gd")
var threaded_io_enabled: bool = false  # 原型先显式开启；低帧率应用RTT未证明稳定收益。
var _io_worker: RefCounted = null
var _io_generation: int = 0
var _session_server_host: String = ""
var _exiting: bool = false
var _last_io_stats: Dictionary = {}
var _max_event_dispatch_usec: int = 0


## ★必须**永不暂停**（2026-10-12 实测：进安全屋客户端 SERVER_DISCONNECTED 的根因）：
## 章节完成页会 `get_tree().paused = true`（chapter_summary.gd），而本节点是 autoload，
## 默认 `PROCESS_MODE_INHERIT` → 继承根节点的 PAUSABLE → 暂停时 `_process` 停摆
## → **TCP 隧道不再转发任何 UDP** → 两端 ENet 收不到包 → 客户端报 `SERVER_DISCONNECTED`。
## 隧道是**传输层**，必须独立于游戏暂停持续搬运字节；否则任何"暂停整树"的界面（章节完成、
## 暂停菜单、安全屋台词窗口）都会把联机打断。探针证据：默认 process_mode 的节点在
## paused 时 `_process` 计数为 0、设 ALWAYS（枚举值 3）后照常。
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 仅本机诊断开关：保留原主线程路径做A/B对照，不改线上帧协议。
	if "--net-tunnel-threaded-io" in OS.get_cmdline_user_args():
		threaded_io_enabled = true
	if "--net-tunnel-main-thread" in OS.get_cmdline_user_args():
		threaded_io_enabled = false


# ═════════════════════════════ 对外接口 ═════════════════════════════

## 从 Master Server URL 提取主机名（去掉协议、端口、路径）。
## 例："http://8.138.99.96:10000" → "8.138.99.96"
static func extract_host_from_url(url: String) -> String:
	var host := url.strip_edges()
	if host.begins_with("http://"):
		host = host.substr(7)
	elif host.begins_with("https://"):
		host = host.substr(8)
	var slash := host.find("/")
	if slash >= 0:
		host = host.substr(0, slash)
	var colon := host.rfind(":")
	if colon >= 0:
		host = host.substr(0, colon)
	return host


func setup(server_host: String, server_port: int = TUNNEL_TCP_PORT) -> void:
	_server_host = server_host
	_server_port = server_port


## 连接中继并注册隧道。game_port 是本机 ENet Host 监听的端口。
func start(game_port: int) -> void:
	if _exiting:
		return  # 退出树期间的closed回调不能启动一个再也没有_process回收的新worker。
	if _server_host.is_empty():
		tunnel_failed.emit("未配置隧道服务地址")
		return
	if _state == "connecting" or _state == "awaiting_registered" or _state == "registered":
		push_warning("[TunnelClient] 已在运行中，忽略重复 start()")
		return
	if _io_worker != null:
		_shutdown_io_worker()
	_game_port = game_port
	_session_server_host = _server_host
	_public_port = 0
	_tunnel_id = ""
	_last_io_stats.clear()
	_max_event_dispatch_usec = 0
	if threaded_io_enabled:
		_start_io_worker()
		return
	_clear_send_queue()
	_recv_buffer.clear()
	_register_accum = 0.0
	_next_outgoing_client = 0
	_send_queue_peak_bytes = 0
	_send_partial_writes = 0
	_bytes_sent = 0
	_bytes_received = 0
	_last_pump_usec = 0
	_max_pump_usec = 0
	_keepalive_accum = 0.0
	_idle_check_accum = 0.0
	_tcp = StreamPeerTCP.new()
	_state = "connecting"
	_connect_accum = 0.0
	print("[TunnelClient] 正在连接中继 %s:%d …" % [_server_host, _server_port])
	var err := _tcp.connect_to_host(_server_host, _server_port)
	if err != OK:
		_state = "closed"
		tunnel_failed.emit("TCP 连接失败：%s" % error_string(err))
		return


## 释放隧道（发 RELEASE → 断开 TCP → 清理 per-client socket）。
func stop() -> void:
	if _io_worker != null:
		var was_io_registered: bool = _state == "registered"
		_shutdown_io_worker()
		_state = "closed"
		if was_io_registered:
			tunnel_closed.emit()
		return
	if _state == "registered" and _tcp != null:
		_send_message(MSG_RELEASE, PackedByteArray())
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	_cleanup_clients()
	_recv_buffer.clear()
	_clear_send_queue()
	var was_registered := _state == "registered"
	_state = "closed"
	if was_registered:
		tunnel_closed.emit()


func get_public_address() -> String:
	return _session_server_host if not _session_server_host.is_empty() else _server_host


func get_public_port() -> int:
	return _public_port


func is_active() -> bool:
	return _state == "registered"


# ═════════════════════════════ _process 轮询 ═════════════════════════════

func _process(delta: float) -> void:
	if _io_worker != null:
		_drain_io_events()
		return
	if _state == "idle" or _state == "closed" or _tcp == null:
		return

	_tcp.poll()
	var status := _tcp.get_status()

	if status == StreamPeerTCP.STATUS_ERROR:
		_handle_disconnect("TCP 连接错误")
		return

	if _state == "connecting":
		if status == StreamPeerTCP.STATUS_CONNECTED:
			## ★ 关闭 Nagle（2026-10-10 实测「延迟不稳 + 果冻感/回弹」的根因）：
			## 隧道把 60Hz 的小包（ENet 输入/快照）走 TCP。Nagle 默认开启 → 小包被攒着
			## 等 ACK（≈1 个 RTT）再成批发 → **交付时刻抖动且成串**。客户端输入的到达时刻
			## 因此忽早忽晚，主机就用「过时输入」推进权威位置，回头再把本地预测玩家拽回去
			## —— 观感正是"移动有果冻质感、偶尔回弹"。关掉后每个包立即发出，抖动显著收敛。
			_tcp.set_no_delay(true)
			_state = "awaiting_registered"
			_send_register()
			return
		## ★ 自控连接超时（见 CONNECT_TIMEOUT 注释）：引擎在本机实测要 30s 才暴露失败，
		## 且"地址填错"与"被丢包"同相 → 这里主动计时，到点即失败，让 UI 能给出可操作反馈。
		_connect_accum += delta
		if _connect_accum >= connect_timeout:
			_handle_disconnect("连接中继超时（%.0fs）" % connect_timeout)
		return

	if _state != "awaiting_registered" and _state != "registered":
		return
	if _state == "awaiting_registered":
		_register_accum += delta
		if _register_accum >= connect_timeout:
			_handle_disconnect("中继注册响应超时（%.0fs）" % connect_timeout)
			return

	# Net在每个物理/渲染阶段前后泵送；本回调保留独立连接/超时/保活的兜底。
	pump_incoming()
	pump_outgoing()

	if _state != "registered":
		return

	# ── keepalive ──
	_keepalive_accum += delta
	if _keepalive_accum >= KEEPALIVE_INTERVAL:
		_keepalive_accum = 0.0
		_send_message(MSG_KEEPALIVE, PackedByteArray())

	# ── 空闲客户端清理 ──
	_idle_check_accum += delta
	if _idle_check_accum >= 5.0:
		_idle_check_accum = 0.0
		_cleanup_idle_clients()


## 只搬字节，不调用Multiplayer.poll或游戏节点，允许Net在轮询前调用。
func pump_incoming() -> void:
	if _io_worker != null:
		_drain_io_events()
		return
	if _incoming_pumping or _tcp == null or (_state != "awaiting_registered" and _state != "registered"):
		return
	_incoming_pumping = true
	var started: int = Time.get_ticks_usec()
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_incoming_pumping = false
		_handle_disconnect("TCP 连接已关闭")
		return
	var avail: int = mini(_tcp.get_available_bytes(), MAX_READ_BYTES_PER_PUMP)
	if avail > 0:
		var result: Array = _tcp.get_partial_data(avail)
		if int(result[0]) != OK:
			_incoming_pumping = false
			_handle_disconnect("TCP 读数据失败")
			return
		var data: PackedByteArray = result[1]
		_bytes_received += data.size()
		_recv_buffer.append_array(data)
		if _recv_buffer.size() > MAX_RECV_BUFFER_BYTES:
			_incoming_pumping = false
			_handle_disconnect("隧道入站积压超限")
			return
	_process_messages()
	_note_pump_duration(started)
	_incoming_pumping = false


func pump_outgoing() -> void:
	if _io_worker != null:
		return  # ENet已flush进localhost UDP，由独占socket的worker收走。
	if _outgoing_pumping or _tcp == null or (_state != "registered" and _state != "awaiting_registered"):
		return
	_outgoing_pumping = true
	var started: int = Time.get_ticks_usec()
	_outgoing_deadline_usec = started + PUMP_BUDGET_USEC
	_outgoing_write_remaining = MAX_WRITE_BYTES_PER_PUMP
	_flush_send_queue()
	if _state == "registered" and _tcp != null:
		_poll_game_outgoing()
		_flush_send_queue()
	_note_pump_duration(started)
	_outgoing_deadline_usec = 0
	_outgoing_pumping = false


func _note_pump_duration(started_usec: int) -> void:
	_last_pump_usec = Time.get_ticks_usec() - started_usec
	_max_pump_usec = maxi(_max_pump_usec, _last_pump_usec)


func get_transport_stats() -> Dictionary:
	if _io_worker != null:
		var snapshot: Dictionary = _io_worker.get_stats()
		snapshot["state"] = _state
		snapshot["max_event_dispatch_usec"] = _max_event_dispatch_usec
		return snapshot
	if not _last_io_stats.is_empty():
		return _last_io_stats.duplicate(true)
	var age: int = 0
	if not _send_queue.is_empty():
		age = maxi(0, Time.get_ticks_msec() - int(_send_queue[0]["queued_msec"]))
	return {"state": _state, "send_queue_bytes": _send_queue_bytes,
		"send_queue_peak_bytes": _send_queue_peak_bytes, "send_queue_age_msec": age,
		"send_partial_writes": _send_partial_writes, "bytes_sent": _bytes_sent,
		"bytes_received": _bytes_received, "recv_buffer_bytes": _recv_buffer.size(),
		"last_pump_usec": _last_pump_usec, "max_pump_usec": _max_pump_usec,
		"threaded_io": false, "thread_running": false}


func _start_io_worker() -> void:
	_io_generation += 1
	_state = "connecting"
	_public_port = 0
	_tunnel_id = ""
	_io_worker = IO_WORKER.new()
	var error: Error = _io_worker.start({"server_host": _server_host, "server_port": _server_port,
		"game_port": _game_port, "protocol": Net.PROTOCOL_VERSION,
		"game_version": str(ProjectSettings.get_setting("application/config/version", "")),
		"connect_timeout": connect_timeout})
	if error != OK:
		_shutdown_io_worker()
		_state = "closed"
		tunnel_failed.emit("无法启动隧道收发线程：%s" % error_string(error))
		return
	print("[TunnelClient] 独立I/O连接中继 %s:%d" % [_server_host, _server_port])


func _shutdown_io_worker() -> void:
	_io_generation += 1
	if _io_worker == null:
		return
	var worker: RefCounted = _io_worker
	_io_worker = null
	worker.stop()
	_last_io_stats = worker.get_stats()
	_last_io_stats["state"] = "closed"
	_last_io_stats["max_event_dispatch_usec"] = _max_event_dispatch_usec
	_recv_buffer.clear()
	_clear_send_queue()


func _drain_io_events() -> void:
	if _io_worker == null:
		return
	var generation: int = _io_generation
	var worker: RefCounted = _io_worker
	# 对外保留连接阶段可观测性；registered只能由事件推进，确保ready信号不遗漏。
	var status: Dictionary = worker.get_stats()
	if _state == "connecting" and str(status.get("state", "")) == "awaiting_registered":
		_state = "awaiting_registered"
	var events: Array[Dictionary] = worker.drain_events()
	for event: Dictionary in events:
		# 信号回调可能立即stop/start；旧会话剩余事件不得污染新会话。
		if generation != _io_generation or worker != _io_worker:
			return
		_max_event_dispatch_usec = maxi(_max_event_dispatch_usec,
			Time.get_ticks_usec() - int(event.get("queued_usec", Time.get_ticks_usec())))
		match str(event.get("type", "")):
			"registered":
				_tunnel_id = str(event.get("tunnel_id", ""))
				_public_port = int(event.get("public_port", 0))
				_state = "registered"
				print("[TunnelClient] 独立I/O就绪：公网端口 %d" % _public_port)
				tunnel_ready.emit(_session_server_host, _public_port)
			"failed", "closed":
				var was_registered: bool = _state == "registered"
				var reason: String = str(event.get("reason", "隧道关闭"))
				_shutdown_io_worker()
				_state = "closed"
				if was_registered:
					tunnel_closed.emit()
				else:
					tunnel_failed.emit(reason)
				return


# ═════════════════════════════ 协议收发 ═════════════════════════════

func _send_register() -> void:
	var payload := JSON.stringify({
		"protocol": Net.PROTOCOL_VERSION,
		"gameVersion": str(ProjectSettings.get_setting("application/config/version", "")),
	}).to_utf8_buffer()
	_send_message(MSG_REGISTER, payload)
	print("[TunnelClient] 已发送 REGISTER（protocol=%s）" % Net.PROTOCOL_VERSION)


## 发送一条消息：[4字节大端长度][1字节类型][载荷]
## 帧头/体先组为一帧，再部分写；发送偏移跨泵送保留，不阻塞、不重发已写字节。
func _send_message(type: int, payload: PackedByteArray) -> void:
	if _tcp == null:
		return
	var length := payload.size() + 1
	var frame := PackedByteArray([
		(length >> 24) & 0xFF,
		(length >> 16) & 0xFF,
		(length >> 8) & 0xFF,
		length & 0xFF,
		type,
	])
	frame.append_array(payload)
	if _send_queue_bytes + frame.size() > MAX_SEND_QUEUE_BYTES:
		_handle_disconnect("隧道发送积压超限，请检查网络或降低联机负载")
		return
	_send_queue.append({"frame": frame, "offset": 0, "queued_msec": Time.get_ticks_msec()})
	_send_queue_bytes += frame.size()
	_send_queue_peak_bytes = maxi(_send_queue_peak_bytes, _send_queue_bytes)
	# 出站批处理只在泵送结束flush，避免每个UDP包重复耗尽工作预算。
	if not _outgoing_pumping:
		_flush_send_queue()


func _flush_send_queue() -> void:
	if _tcp == null or _send_queue.is_empty():
		return
	var started: int = Time.get_ticks_usec()
	var deadline: int = _outgoing_deadline_usec if _outgoing_pumping else started + PUMP_BUDGET_USEC
	var byte_budget: int = _outgoing_write_remaining if _outgoing_pumping else MAX_WRITE_BYTES_PER_PUMP
	var written: int = 0
	while not _send_queue.is_empty() and _tcp != null:
		var item: Dictionary = _send_queue[0]
		if Time.get_ticks_msec() - int(item["queued_msec"]) > MAX_SEND_QUEUE_AGE_MSEC:
			_handle_disconnect("隧道发送队列长时间未排空")
			return
		if written >= byte_budget or Time.get_ticks_usec() >= deadline:
			return
		var frame: PackedByteArray = item["frame"]
		var offset: int = int(item["offset"])
		var end: int = mini(frame.size(), offset + byte_budget - written)
		var result: Array = _write_tcp_chunk(frame.slice(offset, end))
		if int(result[0]) != OK:
			_handle_disconnect("TCP 写数据失败：%s" % error_string(int(result[0])))
			return
		var sent: int = int(result[1])
		if sent < 0 or sent > end - offset:
			_handle_disconnect("TCP 部分写返回非法长度")
			return
		if sent < end - offset:
			_send_partial_writes += 1
		if sent == 0:
			return
		item["offset"] = offset + sent
		_send_queue_bytes -= sent
		_bytes_sent += sent
		written += sent
		if _outgoing_pumping:
			_outgoing_write_remaining -= sent
		if int(item["offset"]) >= frame.size():
			_send_queue.pop_front()
		else:
			_send_queue[0] = item


## 窄I/O边界便于用部分写/慢读替身覆盖，生产仍只使用同一TCP对象。
func _write_tcp_chunk(data: PackedByteArray) -> Array:
	return _tcp.put_partial_data(data)


func _clear_send_queue() -> void:
	_send_queue.clear()
	_send_queue_bytes = 0


## 从 _recv_buffer 解析完整消息。
func _process_messages() -> void:
	var started: int = Time.get_ticks_usec()
	var processed: int = 0
	while _recv_buffer.size() >= 4:
		if processed >= MAX_MESSAGES_PER_PUMP or Time.get_ticks_usec() - started >= PUMP_BUDGET_USEC:
			return
		processed += 1
		var length := (_recv_buffer[0] << 24) | (_recv_buffer[1] << 16) | (_recv_buffer[2] << 8) | _recv_buffer[3]
		if length < 1:
			## 跳过空消息
			_recv_buffer = _recv_buffer.slice(4)
			continue
		## ★ 帧长越界 → 协议违规，断开而不是让缓冲被灌爆（见 MAX_FRAME_SIZE）。
		if length > MAX_FRAME_SIZE:
			_handle_disconnect("收到非法帧长（%d 字节）" % length)
			return
		if _recv_buffer.size() < 4 + length:
			break  # 不完整，等更多数据
		var type := _recv_buffer[4]
		var payload := _recv_buffer.slice(5, 4 + length)
		_recv_buffer = _recv_buffer.slice(4 + length)
		_handle_message(type, payload)
		if _state == "closed":
			return


func _handle_message(type: int, payload: PackedByteArray) -> void:
	match type:
		MSG_REGISTERED:
			_handle_registered(payload)
		MSG_RELAY_TO_HOST:
			_handle_relay_to_host(payload)
		MSG_ERROR:
			var info = JSON.parse_string(payload.get_string_from_utf8())
			var msg := str(info.get("message", "unknown")) if info is Dictionary else "unknown"
			_handle_disconnect("中继拒绝：%s" % msg)
		MSG_KEEPALIVE:
			pass  # 仅保活，无需处理


func _handle_registered(payload: PackedByteArray) -> void:
	var info = JSON.parse_string(payload.get_string_from_utf8())
	if not info is Dictionary:
		_handle_disconnect("REGISTERED 响应解析失败")
		return
	_tunnel_id = str(info.get("tunnelId", ""))
	_public_port = int(info.get("tunnelPort", 0))
	if _public_port == 0:
		_handle_disconnect("REGISTERED 响应缺少端口")
		return
	_state = "registered"
	print("[TunnelClient] 隧道就绪：公网端口 %d（ID %s）" % [_public_port, _tunnel_id])
	tunnel_ready.emit(_session_server_host, _public_port)


## 中继 → 本机游戏：收到的 payload = [2字节 clientId (BE)][原始 UDP 数据]
func _handle_relay_to_host(payload: PackedByteArray) -> void:
	if payload.size() < 2:
		return
	var client_id := (payload[0] << 8) | payload[1]
	var data := payload.slice(2)
	if data.size() > MAX_PACKET_SIZE:
		print("[TunnelClient] 入站包 %d 字节超限，丢弃" % data.size())
		return

	# 获取或创建 per-client socket
	var client: Dictionary = _clients.get(client_id, {})
	if client.is_empty():
		var socket := PacketPeerUDP.new()
		var err := socket.bind(0, "127.0.0.1")
		if err != OK:
			print("[TunnelClient] 绑定 UDP socket 失败：%s" % error_string(err))
			return
		err = socket.connect_to_host("127.0.0.1", _game_port)
		if err != OK:
			print("[TunnelClient] 连接本机游戏端口失败：%s" % error_string(err))
			return
		_clients[client_id] = {"socket": socket, "last_seen": Time.get_ticks_msec()}
		print("[TunnelClient] 新客户端 %d（共 %d 个）" % [client_id, _clients.size()])

	_clients[client_id]["last_seen"] = Time.get_ticks_msec()
	var socket: PacketPeerUDP = _clients[client_id]["socket"]
	var err: Error = socket.put_packet(data)
	if err != OK:
		_handle_disconnect("隧道投递本机UDP失败：%s" % error_string(err))


## 轮询所有 per-client socket，把游戏回包通过 TCP 发回中继。
func _poll_game_outgoing() -> void:
	if _clients.is_empty():
		return
	var started: int = Time.get_ticks_usec()
	var deadline: int = _outgoing_deadline_usec if _outgoing_pumping else started + PUMP_BUDGET_USEC
	var client_ids: Array = _clients.keys()
	var start_index: int = _next_outgoing_client % client_ids.size()
	# 每轮换起点，且在开始处理当前peer前推进游标；预算耗尽时下轮轮到后续玩家。
	for step: int in range(client_ids.size()):
		var index: int = (start_index + step) % client_ids.size()
		_next_outgoing_client = (index + 1) % client_ids.size()
		var client_id: int = int(client_ids[index])
		var client: Dictionary = _clients[client_id]
		var socket: PacketPeerUDP = client["socket"]
		var count := 0
		while socket.get_available_packet_count() > 0 and count < MAX_OUTGOING_PER_CLIENT:
			if Time.get_ticks_usec() >= deadline or _send_queue_bytes >= MAX_SEND_QUEUE_BYTES - MAX_PACKET_SIZE - 7:
				return
			var data := socket.get_packet()
			if socket.get_packet_error() != OK:
				break
			if data.is_empty():
				break
			client["last_seen"] = Time.get_ticks_msec()
			# 构造 RELAY_FROM_HOST 载荷：[2字节 clientId (BE)][数据]
			var payload := PackedByteArray()
			payload.append((client_id >> 8) & 0xFF)
			payload.append(client_id & 0xFF)
			payload.append_array(data)
			_send_message(MSG_RELAY_FROM_HOST, payload)
			if _tcp == null or _state != "registered":
				return
			count += 1


# ═════════════════════════════ 生命周期 / 清理 ═════════════════════════════

func _handle_disconnect(reason: String) -> void:
	print("[TunnelClient] 断开：%s" % reason)
	_cleanup_clients()
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	var was_registered := _state == "registered"
	_state = "closed"
	_recv_buffer.clear()
	_clear_send_queue()
	if was_registered:
		tunnel_closed.emit()
	else:
		tunnel_failed.emit(reason)


func _cleanup_idle_clients() -> void:
	var now := Time.get_ticks_msec()
	var to_remove: Array[int] = []
	for client_id: int in _clients.keys():
		var last_seen: float = float(_clients[client_id].get("last_seen", 0.0))
		if now - last_seen > CLIENT_IDLE_TIMEOUT * 1000.0:
			to_remove.append(client_id)
	for id: int in to_remove:
		var socket: PacketPeerUDP = _clients[id]["socket"]
		if socket != null:
			socket.close()
		_clients.erase(id)
		print("[TunnelClient] 客户端 %d 超时清理" % id)


func _cleanup_clients() -> void:
	for client_id: int in _clients.keys():
		var socket: PacketPeerUDP = _clients[client_id]["socket"]
		if socket != null:
			socket.close()
	_clients.clear()


func _exit_tree() -> void:
	_exiting = true
	if _tcp != null or _io_worker != null:
		stop()
