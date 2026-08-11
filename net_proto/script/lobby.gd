extends Control
## 大厅：创建房间 / 加入房间 / 开始游戏 / 玩家列表 / 日志。
##
## 连接逻辑全部委托给 Net 单例，这里只做 UI 呈现。

const GAME_SCENE := "res://scene/game.tscn"

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


func _ready() -> void:
	Net.connection_established.connect(_on_connection_established)
	Net.connection_failed.connect(_on_connection_failed)
	Net.server_disconnected.connect(_on_server_disconnected)
	Net.peer_joined.connect(_on_peer_joined)
	Net.peer_left.connect(_on_peer_left)
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	start_btn.pressed.connect(_on_start_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	start_btn.disabled = true
	leave_btn.disabled = true
	_log("请创建房间或加入已有房间（默认 127.0.0.1:27015）")

	# 无头自动联机测试（-- --net-test=host / client）
	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_run_auto_host()
	elif "--net-test=client" in user_args:
		_run_auto_client()


func _exit_tree() -> void:
	# 节点销毁时信号连接自动清理，无需手动 disconnect
	pass


# ---------------------------------------------------------------- 无头自动联机测试

## Host 端：建房间 → 等 Client → 广播开始。诊断在 game.gd（切场景后 lobby 会被销毁）。
func _run_auto_host() -> void:
	Net.player_name = "HostAuto"
	create_btn.disabled = true
	join_btn.disabled = true
	leave_btn.disabled = true
	start_btn.disabled = true
	var err := Net.host_game()
	if err != OK:
		print("[AUTO] host 创建房间失败: ", error_string(err))
		get_tree().quit(1)
		return
	print("[AUTO] host 房间已创建，等待 client 接入 ...")
	await get_tree().create_timer(1.5).timeout
	print("[AUTO] host 广播开始游戏")
	Net.start_game.rpc(GAME_SCENE)


## Client 端：加入。诊断在 game.gd。
func _run_auto_client() -> void:
	Net.player_name = "ClientAuto"
	var err := Net.join_game("127.0.0.1")
	if err != OK:
		print("[AUTO] client 加入失败: ", error_string(err))
		get_tree().quit(1)
		return
	print("[AUTO] client 已发起加入，等待 host 开始游戏 ...")


# ---------------------------------------------------------------- 按钮

func _on_create_pressed() -> void:
	Net.player_name = name_edit.text
	var err := Net.host_game()
	if err != OK:
		_log("创建房间失败：%s" % error_string(err))
		return
	_connected = true
	_log("已创建房间（端口 %d）" % Net.DEFAULT_PORT)
	_refresh_ui()


func _on_join_pressed() -> void:
	Net.player_name = name_edit.text
	var err := Net.join_game(ip_edit.text)
	if err != OK:
		_log("加入失败：%s" % error_string(err))
		return
	_log("正在加入 %s ..." % ip_edit.text)
	create_btn.disabled = true
	join_btn.disabled = true


func _on_start_pressed() -> void:
	if not Net.is_host:
		return
	_log("广播开始游戏 ...")
	Net.start_game.rpc(GAME_SCENE)


func _on_leave_pressed() -> void:
	Net.leave()
	_connected = false
	_log("已离开房间")
	_refresh_ui()


# ---------------------------------------------------------------- 连接事件

func _on_connection_established() -> void:
	_connected = true
	_log("TCP 连接成功，等待 Host 握手回执 ...")
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
	if Net.is_host:
		_log("有玩家接入，等待握手 ...")


func _on_peer_left(_peer_id: int) -> void:
	if Net.is_host:
		_log("有玩家离开")
	_refresh_ui()


# ---------------------------------------------------------------- UI 刷新

func _refresh_ui() -> void:
	if Net.is_host:
		status_label.text = "状态：主机（端口 %d）" % Net.DEFAULT_PORT
		start_btn.disabled = not _connected
	else:
		status_label.text = "状态：%s" % ("已连接（等待主机开始游戏）" if _connected else "未连接")
		start_btn.disabled = true
	create_btn.disabled = _connected
	join_btn.disabled = _connected
	leave_btn.disabled = not _connected

	var names := Net.get_player_names()
	var lines: Array[String] = ["玩家列表（%d）：" % names.size()]
	for pid in names.keys():
		lines.append("  · %s (peer %d)" % [names[pid], pid])
	players_label.text = "\n".join(lines)


func _log(msg: String) -> void:
	_log_lines.append("[%s] %s" % [Time.get_time_string_from_system(), msg])
	if _log_lines.size() > 30:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)
