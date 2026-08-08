extends Node
class_name ServerListener

## LAN 广播：Client 端监听局域网内的游戏房间。
## 放到 Server Browser 场景中，发现/移除游戏时发射信号。

signal new_server(server_info: Dictionary)
signal remove_server(ip: String)

@export var server_cleanup_threshold: int = 3

var _socket: PacketPeerUDP = null
var _cleanup_timer: Timer = null
var _known_servers: Dictionary = {}  ## ip → {name, port, last_seen, ...}


func _ready() -> void:
	_socket = PacketPeerUDP.new()
	var err: Error = _socket.bind(ServerAdvertiser.DEFAULT_PORT)
	if err != OK:
		printerr("[ServerListener] UDP 监听失败 port=%d (同一机器只能一个实例监听)" % ServerAdvertiser.DEFAULT_PORT)
		_socket.close()
		_socket = null  # 标记为失败，_process 检查
	else:
		print("[ServerListener] 正在监听 LAN 广播 port=%d" % ServerAdvertiser.DEFAULT_PORT)

	_cleanup_timer = Timer.new()
	_cleanup_timer.wait_time = float(server_cleanup_threshold)
	_cleanup_timer.one_shot = false
	_cleanup_timer.autostart = true
	var cb: Callable = _cleanup
	_cleanup_timer.timeout.connect(cb)
	add_child(_cleanup_timer)


func _process(_delta: float) -> void:
	if not _socket:
		return
	while _socket.get_available_packet_count() > 0:
		var server_ip: String = _socket.get_packet_ip()
		var _port: int = _socket.get_packet_port()
		var packet: PackedByteArray = _socket.get_packet()

		if server_ip == "":
			continue

		var msg: String = packet.get_string_from_utf8()
		var info: Dictionary = JSON.parse_string(msg) if msg else {}
		if not info:
			continue

		info["ip"] = server_ip
		info["last_seen"] = Time.get_unix_time_from_system()

		if not _known_servers.has(server_ip):
			_known_servers[server_ip] = info
			print("[ServerListener] 发现游戏: %s (%s:%s)" % [info.get("name", "?"), server_ip, info.get("port", "?")])
			new_server.emit(info)
		else:
			_known_servers[server_ip]["last_seen"] = info["last_seen"]


func _cleanup() -> void:
	var now: int = Time.get_unix_time_from_system()
	var to_remove: Array[String] = []
	for ip in _known_servers:
		var info: Dictionary = _known_servers[ip]
		if now - info.get("last_seen", 0) > server_cleanup_threshold:
			to_remove.append(ip)
	for ip in to_remove:
		_known_servers.erase(ip)
		print("[ServerListener] 游戏已离线: %s" % ip)
		remove_server.emit(ip)


func _exit_tree() -> void:
	if _socket:
		_socket.close()
