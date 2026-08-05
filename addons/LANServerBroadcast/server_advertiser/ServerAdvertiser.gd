extends Node
class_name ServerAdvertiser

## LAN 广播：Host 端定时广播游戏房间信息（名称、端口、人数等）。
## 放到 Lobby 场景中（仅 Host 激活），自动向局域网广播。

const DEFAULT_PORT := 3111

@export var broadcast_interval: float = 1.0
var server_info: Dictionary = {"name": "LAN Game"}

var _socket: PacketPeerUDP = null
var _timer: Timer = null
var _broadcast_port := DEFAULT_PORT


func _ready() -> void:
	if not multiplayer.is_server():
		return

	_socket = PacketPeerUDP.new()
	_socket.set_broadcast_enabled(true)
	_socket.set_dest_address("255.255.255.255", _broadcast_port)

	_timer = Timer.new()
	_timer.wait_time = broadcast_interval
	_timer.one_shot = false
	_timer.autostart = true
	var cb: Callable = _broadcast
	_timer.timeout.connect(cb)
	add_child(_timer)


func _broadcast() -> void:
	var data: String = JSON.stringify(server_info)
	var packet: PackedByteArray = data.to_utf8_buffer()
	_socket.put_packet(packet)


func _exit_tree() -> void:
	if _timer:
		_timer.stop()
	if _socket:
		_socket.close()
