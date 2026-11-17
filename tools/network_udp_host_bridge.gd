extends SceneTree

## 独立本机测试入口；控制 socket 属于主线程，游戏数据面只属于 worker。
const Worker = preload("res://tools/network_udp_host_worker.gd")
const LOOPBACK := "127.0.0.1"
const TIMEOUT_MSEC := 120000
const MAX_CONTROL_PACKETS_PER_FRAME := 16
const MAX_CONTROL_BYTES := 1024

var _worker: Worker = null
var _control: PacketPeerUDP = null
var _control_token: String = ""
var _started_msec: int = 0
var _ready_printed: bool = false
var _finished: bool = false
var _control_io_errors: int = 0
var _control_busy_errors: int = 0
var _control_rejected: int = 0


func _initialize() -> void:
	_started_msec = Time.get_ticks_msec()
	var encoded: String = OS.get_environment("UDP_LAB_HOST_CONFIG")
	# 凭据不再留给本进程内后续脚本或子进程继承；副本只存在于 encoded 与 config。
	OS.unset_environment("UDP_LAB_HOST_CONFIG")
	if encoded.is_empty() or encoded.length() > 65536:
		_finish(1, "invalid_config")
		return
	var parser := JSON.new()
	var parse_error: Error = parser.parse(encoded)
	encoded = ""
	if parse_error != OK or not parser.data is Dictionary:
		_finish(1, "invalid_config")
		return
	var config: Dictionary = parser.data
	var token: Variant = config.get("control_token")
	if not token is String or token.is_empty() or token.length() > 256:
		config.clear()
		_finish(1, "invalid_config")
		return
	_control_token = token
	_control = PacketPeerUDP.new()
	var error: Error = _control.bind(0, LOOPBACK)
	if error != OK:
		_control_io_errors += 1
		config.clear()
		_finish(1, "control_bind_failed")
		return
	_worker = Worker.new()
	error = _worker.start(config)
	config.clear()
	if error != OK:
		_finish(1, "worker_start_failed")


func _process(_delta: float) -> bool:
	if _finished:
		return false
	if Time.get_ticks_msec() - _started_msec >= TIMEOUT_MSEC:
		_finish(1, "timeout")
		return false
	var stats: Dictionary = _worker.get_stats()
	if not bool(stats.get("running", false)):
		_finish(1, "worker_closed")
		return false
	if not _ready_printed and bool(stats.get("ready", false)):
		_ready_printed = true
		print("UDP_HOST_READY ", JSON.stringify({"ports": stats["ports"],
			"backend_ports": stats["backend_ports"], "sessions": stats["sessions"].size(),
			"control_port": _control.get_local_port()}))
	_poll_control()
	return false


func _poll_control() -> void:
	for _packet_index: int in range(MAX_CONTROL_PACKETS_PER_FRAME):
		if _finished or _control.get_available_packet_count() <= 0:
			return
		var packet: PackedByteArray = _control.get_packet()
		var source_ip: String = _control.get_packet_ip()
		var error: Error = _control.get_packet_error()
		if error != OK:
			if error == ERR_BUSY:
				_control_busy_errors += 1
			else:
				_control_io_errors += 1
			return
		if source_ip != LOOPBACK or packet.is_empty() or packet.size() > MAX_CONTROL_BYTES:
			_control_rejected += 1
			continue
		var parser := JSON.new()
		if parser.parse(packet.get_string_from_utf8()) != OK or not parser.data is Dictionary:
			_control_rejected += 1
			continue
		var command: Dictionary = parser.data
		# 不回显命令、凭据或认证失败内容；控制 token 只来自私有环境配置。
		if command.get("token") != _control_token:
			_control_rejected += 1
			continue
		match command.get("type"):
			"close":
				_finish(0)
				return
			"stats":
				print("UDP_HOST_STATS ", JSON.stringify(_worker.get_stats()))
			_:
				_control_rejected += 1


func _finish(exit_code: int, reason: String = "") -> void:
	if _finished:
		return
	_finished = true
	var stats: Dictionary = {"state": "closed", "running": false, "ready": false,
		"ports": [], "backend_ports": [], "sessions": [], "totals": {"io_errors": 0},
		"created_sockets": 0, "closed_sockets": 0}
	if _worker != null:
		_worker.stop()
		stats = _worker.get_stats()
		_worker = null
	if _control != null:
		_control.close()
		_control = null
	_control_token = ""
	stats["control_io_errors"] = _control_io_errors
	stats["control_busy_errors"] = _control_busy_errors
	stats["control_rejected"] = _control_rejected
	if int(stats.get("startup_error", OK)) != OK \
			or int(stats.get("totals", {}).get("io_errors", 0)) > 0 \
			or _control_io_errors > 0 \
			or int(stats.get("closed_sockets", 0)) != int(stats.get("created_sockets", 0)):
		exit_code = 1
	if not reason.is_empty():
		print("UDP_HOST_ERROR ", JSON.stringify({"error": reason}))
	stats["exit_code"] = exit_code
	print("UDP_HOST_FINAL ", JSON.stringify(stats))
	quit(exit_code)


func _finalize() -> void:
	# 其他正常退出路径同样负责 stop/join；没有阻塞 stdin 的悬挂线程。
	if not _finished:
		_finish(1, "process_exit")
