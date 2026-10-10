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
## 房主侧心跳间隔（与服务端 HOST_TIMEOUT_MS 配套，10s 一次，120s 超时）。
const KEEPALIVE_INTERVAL := 10.0
## per-client UDP socket 空闲多久后回收（秒，对齐中继 60s 客户端超时）。
const CLIENT_IDLE_TIMEOUT := 60.0
## 每帧每个客户端最多转发多少个出站包（防突发打满 TCP 缓冲）。
const MAX_OUTGOING_PER_CLIENT := 64
## 单包上限（对齐 ENet MTU 1392 + 安全余量；超过的包直接丢，与 frps udpPacketSize 同义）。
const MAX_PACKET_SIZE := 1500

var _tcp: StreamPeerTCP = null
var _server_host: String = ""
var _server_port: int = TUNNEL_TCP_PORT
var _game_port: int = 27015
var _recv_buffer: PackedByteArray = PackedByteArray()
var _state: String = "idle"  # idle / connecting / awaiting_registered / registered / closed
var _public_port: int = 0
var _tunnel_id: String = ""
var _keepalive_accum: float = 0.0
## clientId(int) → { "socket": PacketPeerUDP, "last_seen": float(Time.get_ticks_msec) }
var _clients: Dictionary = {}
var _idle_check_accum: float = 0.0


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
	_game_port = game_port
	if _server_host.is_empty():
		tunnel_failed.emit("未配置隧道服务地址")
		return
	if _state == "connecting" or _state == "registered":
		push_warning("[TunnelClient] 已在运行中，忽略重复 start()")
		return
	_tcp = StreamPeerTCP.new()
	_state = "connecting"
	print("[TunnelClient] 正在连接中继 %s:%d …" % [_server_host, _server_port])
	var err := _tcp.connect_to_host(_server_host, _server_port)
	if err != OK:
		_state = "closed"
		tunnel_failed.emit("TCP 连接失败：%s" % error_string(err))
		return


## 释放隧道（发 RELEASE → 断开 TCP → 清理 per-client socket）。
func stop() -> void:
	if _state == "registered" and _tcp != null:
		_send_message(MSG_RELEASE, PackedByteArray())
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	_cleanup_clients()
	_recv_buffer.clear()
	var was_registered := _state == "registered"
	_state = "closed"
	if was_registered:
		tunnel_closed.emit()


func get_public_address() -> String:
	return _server_host


func get_public_port() -> int:
	return _public_port


func is_active() -> bool:
	return _state == "registered"


# ═════════════════════════════ _process 轮询 ═════════════════════════════

func _process(delta: float) -> void:
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
			_send_register()
			_state = "awaiting_registered"
		return

	if _state != "awaiting_registered" and _state != "registered":
		return

	# ── 读 TCP 入站 ──
	var avail := _tcp.get_available_bytes()
	if avail > 0:
		var result := _tcp.get_data(avail)
		if result[0] == OK:
			_recv_buffer.append_array(result[1])
			_process_messages()
		else:
			_handle_disconnect("TCP 读数据失败")
			return

	if _state != "registered":
		return

	# ── 转发 本机游戏 → 中继（轮询 per-client socket 的出站包）──
	_poll_game_outgoing()

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


# ═════════════════════════════ 协议收发 ═════════════════════════════

func _send_register() -> void:
	var payload := JSON.stringify({
		"protocol": Net.PROTOCOL_VERSION,
		"gameVersion": str(ProjectSettings.get_setting("application/config/version", "")),
	}).to_utf8_buffer()
	_send_message(MSG_REGISTER, payload)
	print("[TunnelClient] 已发送 REGISTER（protocol=%s）" % Net.PROTOCOL_VERSION)


## 发送一条消息：[4字节大端长度][1字节类型][载荷]
## ⚠ 一次 `put_data` 发整帧，不拆成「先头后体」两次：两次写会变成两个 TCP 段
## （关闭 Nagle 后各自立即发出），每包多一个段的协议开销，也让接收端多一次组帧。
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
	_tcp.put_data(frame)


## 从 _recv_buffer 解析完整消息。
func _process_messages() -> void:
	while _recv_buffer.size() >= 4:
		var length := (_recv_buffer[0] << 24) | (_recv_buffer[1] << 16) | (_recv_buffer[2] << 8) | _recv_buffer[3]
		if length < 1:
			## 跳过空消息
			_recv_buffer = _recv_buffer.slice(4)
			continue
		if _recv_buffer.size() < 4 + length:
			break  # 不完整，等更多数据
		var type := _recv_buffer[4]
		var payload := _recv_buffer.slice(5, 4 + length)
		_recv_buffer = _recv_buffer.slice(4 + length)
		_handle_message(type, payload)


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
	tunnel_ready.emit(_server_host, _public_port)


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
	socket.put_packet(data)


## 轮询所有 per-client socket，把游戏回包通过 TCP 发回中继。
func _poll_game_outgoing() -> void:
	if _clients.is_empty():
		return
	for client_id: int in _clients.keys():
		var client: Dictionary = _clients[client_id]
		var socket: PacketPeerUDP = client["socket"]
		var count := 0
		while socket.get_available_packet_count() > 0 and count < MAX_OUTGOING_PER_CLIENT:
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
	if _state == "registered" or _state == "connecting":
		stop()
