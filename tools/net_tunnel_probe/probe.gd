extends Node
##
## ENet-over-UDP-tunnel 探针（测试工具，不属于正式游戏代码）
##
## 用法（由 runner.py 调用；也可手动跑）：
##   Host  : godot --headless --path <proj> res://tools/net_tunnel_probe/probe.tscn -- --probe=host --probe-port=27015
##   Client: ... -- --probe=client --probe-addr=<ip> --probe-port=<port> --probe-name=C1 --probe-payloads=1200,3000
##
## 目的：在不改动正式 Net / lobby 的前提下，用真实 ENetMultiplayerPeer 走真实 UDP 隧道，采集：
##   1) 隧道后多个 Client 能否被 Host 区分成不同 peer（多客户端映射正确性）
##   2) 指定字节数的可靠 RPC 能否送达（触发 ENet 分片，对照隧道单包上限）
##
## 相关文档：`互联网联机模式策划方案.md` §2.4 / §12（实测报告）。
##
## ⚠ 本脚本通过 get_node("/root/Net") 复用正式 Net 单例的连接与握手路径，
##    但**不**加载任何游戏场景；握手完成后只做测量与打印，绝不改正式逻辑。

const PROBE_HOST_FLAG := "--probe=host"
const PROBE_CLIENT_FLAG := "--probe=client"

var _role := ""
var _addr := "127.0.0.1"
var _port := 27015
var _name := "Probe"
var _payload_bytes := 0
var _life := 25.0
var _net: Node = null

var _payload_ok := false
var _payload_reply := -1
var _start_ms := 0
var _bytes_sent_est := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	for a: String in args:
		if a == PROBE_HOST_FLAG:
			_role = "host"
		elif a == PROBE_CLIENT_FLAG:
			_role = "client"
		elif a.begins_with("--probe-addr="):
			_addr = a.trim_prefix("--probe-addr=").strip_edges()
		elif a.begins_with("--probe-port="):
			_port = a.trim_prefix("--probe-port=").to_int()
		elif a.begins_with("--probe-name="):
			_name = a.trim_prefix("--probe-name=").strip_edges()
		elif a.begins_with("--probe-payload="):
			_payload_bytes = a.trim_prefix("--probe-payload=").to_int()
		elif a.begins_with("--probe-payloads="):
			for token: String in a.trim_prefix("--probe-payloads=").split(","):
				var n := token.strip_edges().to_int()
				if n > 0:
					_payload_queue.append(n)
		elif a.begins_with("--probe-life="):
			_life = a.trim_prefix("--probe-life=").to_float()
	if _role.is_empty():
		return  # 非探针模式，什么都不做
	_net = get_node_or_null("/root/Net")
	if _net == null:
		printerr("[PROBE] FATAL no /root/Net autoload")
		get_tree().quit(2)
		return
	_start_ms = Time.get_ticks_msec()
	print("[PROBE] START role=%s addr=%s port=%d payload=%d" % [_role, _addr, _port, _payload_bytes])
	if _role == "host":
		_run_host()
	else:
		_run_client()

func _run_host() -> void:
	_net.player_name = "ProbeHost"
	# 关闭 UPnP：本机测试无路由器，避免工作线程噪声。
	_net.upnp_enabled = false
	var err: int = _net.host_game(_port)
	if err != OK:
		printerr("[PROBE] HOST_FAIL err=%s" % error_string(err))
		get_tree().quit(1)
		return
	print("[PROBE] HOST_LISTENING port=%d" % _port)
	_net.connection_established.connect(_on_host_probe_connected)
	_net.peer_left.connect(_on_host_peer_left)
	# 周期性打印存活 peer 列表：用于判定"多客户端是否被区分"。
	var t := 0.0
	var printed_peers := ""
	while true:
		await get_tree().create_timer(0.5).timeout
		t += 0.5
		var ids: Array = _net.get_peer_ids()
		var names: Dictionary = _net.get_player_names()
		var cur := "%s" % str(ids)
		if cur != printed_peers:
			print("[PROBE] HOST_PEERS t=%.1f ids=%s names=%s" % [t, str(ids), str(names.keys())])
			printed_peers = cur
		if t >= _life:
			break
	print("[PROBE] HOST_DONE final_peers=%d" % _net.get_peer_ids().size())
	get_tree().quit(0)

func _run_client() -> void:
	_net.player_name = _name
	_net.upnp_enabled = false
	var err: int = _net.join_game(_addr, _port)
	if err != OK:
		printerr("[PROBE] CLIENT_FAIL err=%s" % error_string(err))
		get_tree().quit(1)
		return
	print("[PROBE] CLIENT_JOINING addr=%s port=%d" % [_addr, _port])
	_net.connection_established.connect(_on_client_probe_established)
	_net.handshake_completed.connect(_on_client_probe_handshake)
	_net.connection_failed.connect(_on_client_probe_failed)
	_net.server_disconnected.connect(_on_client_probe_disconnected)
	var t := 0.0
	while t < _life:
		await get_tree().create_timer(0.25).timeout
		t += 0.25
		var want_payload := _payload_bytes > 0 or not _payload_queue.is_empty()
		if _net.is_online_session() and not _payload_probe_started and want_payload:
			_payload_probe_started = true
			_start_payload_probe()
	print("[PROBE] CLIENT_DONE handshake=%s payload_ok=%s reply_bytes=%d" % [str(_net.handshake_ok), str(_payload_ok), _payload_reply])
	get_tree().quit(0 if _net.handshake_ok else 1)

var _payload_probe_started := false
var _payload_queue: Array = []

func _start_payload_probe() -> void:
	if _payload_queue.is_empty():
		_payload_queue = [_payload_bytes]
	_send_next_payload()

func _send_next_payload() -> void:
	if _payload_queue.is_empty():
		print("[PROBE] PAYLOAD_ALL_SENT")
		return
	var n: int = int(_payload_queue.pop_front())
	# 构造指定字节数的可靠 RPC 载荷（单字节字符 → 字节数≈字符数）。
	var body := ""
	var i := 0
	while i < n:
		body += "x"
		i += 1
	var t0 := Time.get_ticks_msec()
	print("[PROBE] PAYLOAD_SEND bytes=%d" % n)
	probe_payload.rpc_id(1, body, t0, n)

func _on_host_probe_connected() -> void:
	print("[PROBE] HOST_TRANSPORT_CONNECTED")

func _on_host_peer_left(peer_id: int) -> void:
	print("[PROBE] HOST_PEER_LEFT peer=%d" % peer_id)

func _on_client_probe_established() -> void:
	print("[PROBE] CLIENT_TRANSPORT_CONNECTED")

func _on_client_probe_handshake() -> void:
	print("[PROBE] CLIENT_HANDSHAKE_OK")

func _on_client_probe_failed() -> void:
	printerr("[PROBE] CLIENT_CONNECTION_FAILED")

func _on_client_probe_disconnected() -> void:
	printerr("[PROBE] CLIENT_SERVER_DISCONNECTED")

## Client → Host：大载荷。Host 收到后回一个短确认（证明整包送达，不被隧道单包上限截断）。
@rpc("any_peer", "call_remote", "reliable")
func probe_payload(body: String, sent_msec: int, declared: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	print("[PROBE] HOST_RECV_PAYLOAD peer=%d bytes=%d declared=%d" % [sender, body.length(), declared])
	probe_payload_ack.rpc_id(sender, body.length(), sent_msec, declared)

## Host → Client：确认回执。收到后自动发下一个尺寸，形成"逐级加压"序列。
@rpc("authority", "call_remote", "reliable")
func probe_payload_ack(size: int, sent_msec: int, declared: int) -> void:
	print("[PROBE] CLIENT_RECV_ACK bytes=%d declared=%d rtt_ms=%d" % [size, declared, Time.get_ticks_msec() - sent_msec])
	call_deferred("_send_next_payload")
