extends Control

## ── 架构定位 ──
## 系统：联机大厅 ｜ 层：表现（Control）
## 联机：纯表现层，不写权威状态
## 职责：联机大厅界面：按钮只调用 Net 的公开请求接口，并按 Net 信号刷新 UI；另含无头回归用自动流程。
## 依赖：Net 的公开接口与信号

## 正式联机大厅：连接 UI 和自动测试入口；握手、玩家名单与角色选择均由 Net Host 权威维护。
##
## 此脚本是“表现层”：按钮只调用 Net 的公开请求接口，收到 Net 的信号后刷新文字和控件；
## 它不自行写玩家名单、角色表或场景状态。正常流程为：创建/加入 → hello 握手完成 → 选择角色
## （Client 请求、Host 校验并广播）→ Host 在所有玩家选好后按 Start → Net 的安全切图协议接管。
## _run_auto_* 系列只服务无头双端回归，不能作为正式玩法同步逻辑的入口。

const GAME_SCENE := "res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"
const AUTO_TEST_SCENE := "res://scene/maps/test.tscn"
## 仅供无头双端回归：验证安全门全员确认、统一切图与章节总结准备链路。
const AUTO_SAFE_DOOR_TEST_SCENE := "res://scene/maps/突袭-第一关-街道.tscn"
## 结尾安全屋场景键（--net-test-scene=safehouse2 / safehouse3）：用户实测的
## 「客户端看到主机玩家卡在原地踏步」发生在这两张图，留出双端回归入口。
const SAFEHOUSE_CH2_SCENE := "res://scene/maps/突袭-第二关-结尾安全屋.tscn"
const SAFEHOUSE_CH3_SCENE := "res://scene/maps/突袭-第三关-结尾安全屋.tscn"
## 为显式授权、CI 排队和较慢机器保留足够的双进程启动窗口；不影响正常大厅连接。
const AUTO_HOST_TIMEOUT := 30.0

@onready var name_edit: LineEdit = %NameEdit
@onready var ip_edit: LineEdit = %IpEdit
## 端口输入框（建主与加入共用；默认 27015，可改为内网穿透服务分配的 UDP 端口）。
@onready var port_edit: SpinBox = %PortEdit
## 建主时是否尝试 UPnP 自动端口映射（路由器不支持时改用 frp/樱花等穿透工具）。
@onready var upnp_check: CheckBox = %UpnpCheck
@onready var create_btn: Button = %CreateBtn
@onready var join_btn: Button = %JoinBtn
@onready var start_btn: Button = %StartBtn
@onready var leave_btn: Button = %LeaveBtn
@onready var character_select: OptionButton = %CharacterSelect
@onready var character_hint: Label = %CharacterHint
@onready var status_label: Label = %StatusLabel
@onready var players_label: Label = %PlayersLabel
@onready var log_label: Label = %LogLabel

var _connected := false
var _log_lines: Array[String] = []
var _refreshing_character_select := false
## 通过节点路径读取 Autoload，避免 Godot 编辑器热重载期间短暂丢失 `Net` 全局标识符。
var net: Variant = null


func _ready() -> void:
	## 场景内全部 Label 套全局阴影（原 .tscn 里的 Label 都没带阴影，与全游戏风格不一致）
	for node in find_children("", "Label", true, false):
		Global.apply_text_shadow(node as Label)
	_add_wip_notice()
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
	net.player_character_list_changed.connect(_refresh_ui)
	create_btn.pressed.connect(_on_create_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	start_btn.pressed.connect(_on_start_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	character_select.item_selected.connect(_on_character_selected)
	net.upnp_port_mapped.connect(_on_upnp_port_mapped)
	net.upnp_mapping_failed.connect(_on_upnp_mapping_failed)
	start_btn.disabled = true
	leave_btn.disabled = true
	character_select.disabled = true
	_log("请创建房间或加入已有房间（默认 127.0.0.1:27015）")
	_refresh_ui()
	_add_back_button()

	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_run_auto_host()
	elif "--net-test=client" in user_args:
		_run_auto_client()


# ---------------------------------------------------------------- 表现层小件

## 「返回标题」按钮（2026-09-14 用户要求）：不必重开游戏就能回标题；
## 已连接时先离开房间，再停大厅 BGM 切回标题（标题有自己的 BGM）。
func _add_back_button() -> void:
	var vbox: Control = get_node_or_null("VBox")
	if vbox == null:
		return
	var back_btn := Button.new()
	back_btn.name = "BackToTitleBtn"
	back_btn.text = "返回标题界面"
	back_btn.pressed.connect(_on_back_to_title_pressed)
	vbox.add_child(back_btn)


func _on_back_to_title_pressed() -> void:
	if net and _connected:
		net.leave()
		_connected = false
	Global.stop_lobby_music()
	var err: Error = get_tree().change_scene_to_file("res://scene/title_screen.tscn")
	if err != OK:
		printerr("[NetworkLobby] 返回标题失败: %d" % err)


## 联机暂未完成提示（2026-09-14 用户要求）：挂在标题下方，黄字醒目。
func _add_wip_notice() -> void:
	var vbox: Control = get_node_or_null("VBox")
	if vbox == null:
		return
	var notice := Label.new()
	notice.name = "WipNotice"
	notice.text = "※ 联机模式暂未完成 —— 目前仅为基础联机同步（Host 权威），内容与存档请以单人模式为准；遇到异常请先回单人确认。"
	notice.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	notice.add_theme_font_size_override("font_size", 15)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Global.apply_text_shadow(notice)
	vbox.add_child(notice)
	vbox.move_child(notice, 1)  # 标题之下、表单之上


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
	if _is_auto_character_select_test():
		await _run_auto_host_character_select_lobby_test()
		if not is_inside_tree():
			return
	var game_scene := _get_game_scene_for_launch()
	print("[AUTO] host 握手完成，广播开始游戏: %s" % game_scene)
	# D2 修正：开局 RPC 必须携带难度（B1 随 start_game 广播）；原调用漏参导致
	# net-test 流程恒走 -1（不覆盖），Client 的 Global.selected_difficulty 与 Host 脱钩。
	net.start_game.rpc(game_scene, "", null, Global.selected_difficulty)


func _run_auto_client() -> void:
	net.player_name = _get_auto_client_name()
	_set_connect_buttons_disabled(true)
	var err: Error = net.join_game("127.0.0.1")
	if err != OK:
		printerr("[AUTO] client 加入失败: ", error_string(err))
		get_tree().quit(1)
		return
	print("[AUTO] client 已发起加入，等待握手和 host 开始游戏 ...")
	if _is_auto_character_select_test():
		call_deferred("_run_auto_client_character_select_lobby_test")


func _is_auto_character_select_test() -> bool:
	return "--net-test-character-select" in OS.get_cmdline_user_args()


func _run_auto_host_character_select_lobby_test() -> void:
	var available_paths: Array[String] = net.get_available_character_paths()
	if CharacterCatalog.DEFAULT_CHARACTER_PATH not in available_paths or CharacterCatalog.BIGG_CHARACTER_PATH not in available_paths:
		printerr("[AUTO] AUTO_CHARACTER_HOST_LOBBY_FAILED catalog=%s" % str(available_paths))
		get_tree().quit(1)
		return
	## 主机与客户端都选胖虎，验证白名单和重复角色选择均由 Host 正确接受。
	if not net.request_local_character_selection(CharacterCatalog.BIGG_CHARACTER_PATH):
		printerr("[AUTO] AUTO_CHARACTER_HOST_LOBBY_FAILED host_selection_not_applied")
		get_tree().quit(1)
		return
	var deadline := Time.get_ticks_msec() + 8000
	while not net.are_all_players_character_selected() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var host_path: String = str(net.get_player_character_path(int(net.my_peer_id)))
	var client_id := 0
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			client_id = peer_id
			break
	var client_path: String = str(net.get_player_character_path(client_id))
	if not net.are_all_players_character_selected() or host_path != CharacterCatalog.BIGG_CHARACTER_PATH or client_id <= 1 or client_path != CharacterCatalog.BIGG_CHARACTER_PATH:
		printerr("[AUTO] AUTO_CHARACTER_HOST_LOBBY_FAILED host=%s client=%d client_character=%s" % [host_path, client_id, client_path])
		get_tree().quit(1)
		return
	print("[AUTO] AUTO_CHARACTER_HOST_LOBBY_COMPLETE catalog=true duplicate_accepted=true host=%s client=%s" % [host_path.get_file(), client_path.get_file()])


func _run_auto_client_character_select_lobby_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while not net.handshake_ok and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not net.handshake_ok:
		printerr("[AUTO] AUTO_CHARACTER_CLIENT_LOBBY_FAILED handshake_timeout")
		get_tree().quit(1)
		return
	var available_paths: Array[String] = net.get_available_character_paths()
	if CharacterCatalog.DEFAULT_CHARACTER_PATH not in available_paths or CharacterCatalog.BIGG_CHARACTER_PATH not in available_paths:
		printerr("[AUTO] AUTO_CHARACTER_CLIENT_LOBBY_FAILED catalog=%s" % str(available_paths))
		get_tree().quit(1)
		return
	if not net.request_local_character_selection(CharacterCatalog.BIGG_CHARACTER_PATH):
		printerr("[AUTO] AUTO_CHARACTER_CLIENT_LOBBY_FAILED duplicate_request_not_sent")
		get_tree().quit(1)
		return
	deadline = Time.get_ticks_msec() + 3000
	while str(net.get_player_character_path(int(net.my_peer_id))) != CharacterCatalog.BIGG_CHARACTER_PATH and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if str(net.get_player_character_path(int(net.my_peer_id))) != CharacterCatalog.BIGG_CHARACTER_PATH:
		printerr("[AUTO] AUTO_CHARACTER_CLIENT_LOBBY_FAILED duplicate_not_confirmed selected=%s" % str(net.get_player_character_path(int(net.my_peer_id))))
		get_tree().quit(1)
		return
	print("[AUTO] AUTO_CHARACTER_CLIENT_LOBBY_COMPLETE catalog=true duplicate_accepted=true selected=%s" % CharacterCatalog.BIGG_CHARACTER_PATH.get_file())

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
	## 2026-09-24：新增两张结尾安全屋的场景键。用户实测「客户端那边看到主机玩家卡在原地
	## 踏步」就发生在这两张图 —— 能直接拉双端回归才有定位手段（此前只能用默认开头安全屋）。
	if "--net-test-scene=safehouse2" in user_args:
		return SAFEHOUSE_CH2_SCENE
	if "--net-test-scene=safehouse3" in user_args:
		return SAFEHOUSE_CH3_SCENE
	if "--net-test-scene=safe-door" in user_args or "--net-test-scene=enemies" in user_args:
		return AUTO_SAFE_DOOR_TEST_SCENE
	return AUTO_TEST_SCENE if "--net-test-scene=test" in user_args else GAME_SCENE


# ---------------------------------------------------------------- 按钮

func _on_create_pressed() -> void:
	net.player_name = name_edit.text
	net.upnp_enabled = upnp_check.button_pressed
	# 端口由大厅输入框提供：默认 27015。使用 frp 等端口映射型内网穿透时，
	# 这里应填穿透隧道指向本机的本地 UDP 端口（或保持默认并在穿透服务侧映射它）。
	var port := int(port_edit.value)
	var err: Error = net.host_game(port)
	if err != OK:
		_log("创建房间失败：%s" % error_string(err))
		return
	_connected = true
	_log("已创建房间（UDP 端口 %d），正在尝试 UPnP 端口映射 ..." % port)
	_refresh_ui()


func _on_join_pressed() -> void:
	net.player_name = name_edit.text
	# 端口由大厅输入框提供：默认 27015；内网穿透场景填穿透服务分配的远程 UDP 端口。
	var port := int(port_edit.value)
	var err: Error = net.join_game(ip_edit.text, port)
	if err != OK:
		_log("加入失败：%s" % error_string(err))
		return
	_log("正在加入 %s:%d ..." % [ip_edit.text, port])
	_set_connect_buttons_disabled(true)


## 仅 Host 可触发。实际“是否每名玩家均选角”的判定仍交给 Net，避免 UI 本地状态与会话事实不一致。
func _on_start_pressed() -> void:
	if not net.is_host or not net.handshake_ok:
		return
	if not net.are_all_players_character_selected():
		_log("不能开始：请等待所有玩家完成角色选择")
		_refresh_ui()
		return
	_log("全部角色已确认，广播开始游戏 ...")
	# B1 难度同步（D2 用例暴露）：开局广播必须携带难度 —— 原调用漏参（默认 -1 不覆盖），
	# 联机开局的 Client 难度从未被同步，只有中途切图（request_scene_change）才带上。
	net.start_game.rpc(GAME_SCENE, "", null, Global.selected_difficulty)


func _on_leave_pressed() -> void:
	net.leave()
	_connected = false
	_log("已离开房间")
	_refresh_ui()


func _on_character_selected(index: int) -> void:
	if _refreshing_character_select or not net or not net.handshake_ok:
		return
	var character_path := str(character_select.get_item_metadata(index))
	if character_path.is_empty():
		return
	if not net.request_local_character_selection(character_path):
		_log("角色选择请求未发送，请先完成连接与握手")
		_refresh_ui()


# ---------------------------------------------------------------- 连接事件

func _on_connection_established() -> void:
	_connected = true
	_log("ENet 传输已连接，等待 Host 握手回执 ...")
	_refresh_ui()


func _on_handshake_completed() -> void:
	_connected = true
	_log("协议握手完成，请选择角色（允许与其他玩家重复）")
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


## UPnP 映射成功：向 Host 展示可直连的公网地址与端口。
## 若走内网穿透（frp/樱花等），把下面 IP 换成穿透服务分配的地址、端口填穿透端口即可。
func _on_upnp_port_mapped(port: int, external_ip: String) -> void:
	if external_ip.is_empty():
		_log("UPnP 已映射 UDP %d（未能查询外部 IP），好友可用路由器 WAN IP:%d 直连" % [port, port])
	else:
		_log("UPnP 已映射，公网直连地址：%s:%d（把该地址告诉好友）" % [external_ip, port])


func _on_upnp_mapping_failed(reason: String) -> void:
	_log("UPnP 失败：%s；可改用 frp/樱花等内网穿透，将 UDP 端口映射到本机后让好友连接穿透地址" % reason)



# ---------------------------------------------------------------- UI

## 将 Net 当前会话快照投影到控件；本函数应保持无副作用，不能借刷新机会修改联机权威状态。
func _refresh_ui() -> void:
	if not is_node_ready() or not net:
		return
	var selection_ready: bool = _connected and bool(net.handshake_ok)
	if net.is_host:
		status_label.text = "状态：主机（UDP 端口 %d）" % int(net.active_port)
		start_btn.disabled = not (net.handshake_ok and net.are_all_players_character_selected())
	else:
		var text := "未连接"
		if _connected:
			text = "已握手，等待主机开始" if net.handshake_ok else "传输已连接，握手中"
		status_label.text = "状态：%s" % text
		start_btn.disabled = true
	create_btn.disabled = _connected
	join_btn.disabled = _connected
	leave_btn.disabled = not _connected
	_refresh_character_select(selection_ready)

	var names: Dictionary = net.get_player_names()
	var peer_ids: Array[int] = []
	for value: Variant in names.keys():
		peer_ids.append(int(value))
	peer_ids.sort()
	var lines: Array[String] = ["玩家列表（%d）：" % names.size()]
	for peer_id: int in peer_ids:
		var character_path: String = str(net.get_player_character_path(peer_id))
		var character_name: String = str(net.get_character_display_name(character_path)) if not character_path.is_empty() else "未选择"
		lines.append("  · %s（%s，peer %d）" % [str(names[peer_id]), character_name, peer_id])
	players_label.text = "\n".join(lines)


func _refresh_character_select(selection_ready: bool) -> void:
	_refreshing_character_select = true
	character_select.clear()
	var selected_path: String = str(net.get_player_character_path(int(net.my_peer_id)))
	var available_paths: Array[String] = net.get_available_character_paths()
	# 未选择时保留真实占位项，避免下拉框视觉默认值与玩家列表状态不一致。
	character_select.add_item("请选择角色")
	character_select.set_item_metadata(0, "")
	var selected_index := 0
	for character_path: String in available_paths:
		var item_index := character_select.item_count
		character_select.add_item(net.get_character_display_name(character_path))
		character_select.set_item_metadata(item_index, character_path)
		if not selected_path.is_empty() and character_path == selected_path:
			selected_index = item_index
	character_select.select(selected_index)
	character_select.disabled = not selection_ready or character_select.item_count <= 1
	if not selection_ready:
		character_hint.text = "连接并完成握手后可选择角色"
	elif selected_path.is_empty():
		character_hint.text = "请选择角色（可与其他玩家重复）；主机将在全员确认后才能开始。"
	elif net.is_host and not net.are_all_players_character_selected():
		character_hint.text = "等待其他玩家选择角色。"
	else:
		character_hint.text = "角色已由主机确认。"
	_refreshing_character_select = false


func _set_connect_buttons_disabled(value: bool) -> void:
	create_btn.disabled = value
	join_btn.disabled = value
	start_btn.disabled = true
	leave_btn.disabled = value
	character_select.disabled = true


func _log(msg: String) -> void:
	_log_lines.append("[%s] %s" % [Time.get_time_string_from_system(), msg])
	if _log_lines.size() > 14:
		_log_lines.pop_front()
	log_label.text = "\n".join(_log_lines)
