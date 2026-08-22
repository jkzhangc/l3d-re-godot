extends Control
## 正式联机大厅：连接 UI 和自动测试入口；握手/玩家名单由 net 单例维护。

const GAME_SCENE := "res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"
const AUTO_TEST_SCENE := "res://scene/maps/test.tscn"
## 仅供无头双端回归：验证安全门全员确认、统一切图与章节总结准备链路。
const AUTO_SAFE_DOOR_TEST_SCENE := "res://scene/maps/突袭-第一关-街道.tscn"
## 为显式授权、CI 排队和较慢机器保留足够的双进程启动窗口；不影响正常大厅连接。
const AUTO_HOST_TIMEOUT := 30.0

@onready var name_edit: LineEdit = %NameEdit
@onready var ip_edit: LineEdit = %IpEdit
@onready var create_btn: Button = %CreateBtn
@onready var join_btn: Button = %JoinBtn
@onready var start_btn: Button = %StartBtn
@onready var leave_btn: Button = %LeaveBtn
@onready var status_label: Label = %StatusLabel
@onready var players_label: Label = %PlayersLabel
@onready var log_label: Label = %LogLabel

var _connected := false
var _log_lines: Array[String] = []
## 通过节点路径读取 Autoload，避免 Godot 编辑器热重载期间短暂丢失 `Net` 全局标识符。
var net: Variant = null


func _ready() -> void:
	net = get_node_or_null("/root/Net")
	if not net:
		push_error("[NetworkLobby] 未找到 Net Autoload")
		return
	net.connection_established.connect(_on_connection_established)
	net.connection_failed.connect(_on_connection_failed)
	net.server_disconnected.connect(_on_server_disconnected)
	net.peer_joined.connect(_on_peer_joined)
	net.peer_left.connect(_on_peer_left)
	net.handshake_completed.connect(_on_handshake_completed)
	net.player_list_changed.connect(_refresh_ui)
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	start_btn.pressed.connect(_on_start_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	start_btn.disabled = true
	leave_btn.disabled = true
	_log("请创建房间或加入已有房间（默认 127.0.0.1:27015）")

	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_run_auto_host()
	elif "--net-test=client" in user_args:
		_run_auto_client()


# ---------------------------------------------------------------- 无头自动联机测试

func _run_auto_host() -> void:
	net.player_name = "HostAuto"
	_set_connect_buttons_disabled(true)
	var err: Error = net.host_game()
	if err != OK:
		printerr("[AUTO] host 创建房间失败: ", error_string(err))
		get_tree().quit(1)
		return
	_connected = true
	_refresh_ui()
	print("[AUTO] host 房间已创建，等待完成握手的 client ...")
	var deadline := Time.get_ticks_msec() + int(AUTO_HOST_TIMEOUT * 1000.0)
	while net.get_player_names().size() < _get_auto_expected_player_count() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if net.get_player_names().size() < _get_auto_expected_player_count():
		printerr("[AUTO] host 等待 client 握手超时")
		get_tree().quit(1)
		return
	var game_scene := _get_game_scene_for_launch()
	print("[AUTO] host 握手完成，广播开始游戏: %s" % game_scene)
	net.start_game.rpc(game_scene)


func _run_auto_client() -> void:
	net.player_name = _get_auto_client_name()
	_set_connect_buttons_disabled(true)
	var err: Error = net.join_game("127.0.0.1")
	if err != OK:
		printerr("[AUTO] client 加入失败: ", error_string(err))
		get_tree().quit(1)
		return
	print("[AUTO] client 已发起加入，等待握手和 host 开始游戏 ...")


func _get_auto_expected_player_count() -> int:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-players="):
			return clampi(int(argument.trim_prefix("--net-test-players=")), 2, 4)
	return 2


func _get_auto_client_name() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-client-role="):
			var role := argument.trim_prefix("--net-test-client-role=").strip_edges().capitalize()
			return "Client" + (role if not role.is_empty() else "Auto")
	return "ClientAuto"


func _get_game_scene_for_launch() -> String:
	var user_args := OS.get_cmdline_user_args()
	if "--net-test-scene=safe-door" in user_args or "--net-test-scene=enemies" in user_args:
		return AUTO_SAFE_DOOR_TEST_SCENE
	return AUTO_TEST_SCENE if "--net-test-scene=test" in user_args else GAME_SCENE


# ---------------------------------------------------------------- 按钮

func _on_create_pressed() -> void:
	net.player_name = name_edit.text
	var err: Error = net.host_game()
	if err != OK:
		_log("创建房间失败：%s" % error_string(err))
		return
	_connected = true
	_log("已创建房间（端口 %d）" % net.DEFAULT_PORT)
	_refresh_ui()


func _on_join_pressed() -> void:
	net.player_name = name_edit.text
	var err: Error = net.join_game(ip_edit.text)
	if err != OK:
		_log("加入失败：%s" % error_string(err))
		return
	_log("正在加入 %s ..." % ip_edit.text)
	_set_connect_buttons_disabled(true)


func _on_start_pressed() -> void:
	if net.is_host and net.handshake_ok:
		_log("广播开始游戏 ...")
		net.start_game.rpc(GAME_SCENE)


func _on_leave_pressed() -> void:
	net.leave()
	_connected = false
	_log("已离开房间")
	_refresh_ui()


# ---------------------------------------------------------------- 连接事件

func _on_connection_established() -> void:
	_connected = true
	_log("ENet 传输已连接，等待 Host 握手回执 ...")
	_refresh_ui()


func _on_handshake_completed() -> void:
	_connected = true
	_log("协议握手完成")
	_refresh_ui()


func _on_connection_failed() -> void:
	_connected = false
	_log("连接失败（请检查 IP / 端口）")
	_refresh_ui()


func _on_server_disconnected() -> void:
	_connected = false
	_log("与主机断开连接")
	_refresh_ui()


func _on_peer_joined(_peer_id: int) -> void:
	if net.is_host:
		_log("有玩家接入，等待协议握手 ...")


func _on_peer_left(_peer_id: int) -> void:
	if net.is_host:
		_log("有玩家离开")
	_refresh_ui()


# ---------------------------------------------------------------- UI

func _refresh_ui() -> void:
	if not is_node_ready():
		return
	if net.is_host:
		status_label.text = "状态：主机（端口 %d）" % net.DEFAULT_PORT
		start_btn.disabled = not net.handshake_ok
	else:
		var text := "未连接"
		if _connected:
			text = "已握手，等待主机开始" if net.handshake_ok else "传输已连接，握手中"
		status_label.text = "状态：%s" % text
		start_btn.disabled = true
	create_btn.disabled = _connected
	join_btn.disabled = _connected
	leave_btn.disabled = not _connected

	var names: Dictionary = net.get_player_names()
	var lines: Array[String] = ["玩家列表（%d）：" % names.size()]
	for pid in names.keys():
		lines.append("  · %s (peer %d)" % [names[pid], pid])
	players_label.text = "\n".join(lines)


func _set_connect_buttons_disabled(value: bool) -> void:
	create_btn.disabled = value
	join_btn.disabled = value
	start_btn.disabled = true
	leave_btn.disabled = value


func _log(msg: String) -> void:
	_log_lines.append("[%s] %s" % [Time.get_time_string_from_system(), msg])
	if _log_lines.size() > 14:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)
