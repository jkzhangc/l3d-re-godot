extends Control
## Lobby 界面 — 房间等待 / 服务器浏览
##
## Host 端：显示已连接玩家，等待所有人就绪后开始游戏。
## Client 端：显示 LAN 游戏列表，选择并加入。
##
## 使用 NetworkManager + ServerAdvertiser/ServerListener

@export var campaign_scene: String = "res://scene/maps/test.tscn"  ## TODO: 改回 "res://scene/campaign_select.tscn"

## UI 节点引用
@onready var _status_label: Label = $Panel/VBox/StatusLabel
@onready var _player_list: Label = $Panel/VBox/PlayerList
@onready var _server_list: ItemList = $Panel/VBox/ServerList
@onready var _host_btn: Button = $Panel/VBox/HostBtn
@onready var _join_btn: Button = $Panel/VBox/JoinBtn
@onready var _start_btn: Button = $Panel/VBox/StartBtn
@onready var _back_btn: Button = $Panel/VBox/BackBtn
@onready var _ip_input: LineEdit = $Panel/VBox/IPInput
@onready var _port_input: LineEdit = $Panel/VBox/PortInput

var _is_host: bool = false


func _ready() -> void:
	# 连接 NetworkManager 信号
	NetworkManager.player_connected.connect(_on_player_connected)
	NetworkManager.player_disconnected.connect(_on_player_disconnected)
	NetworkManager.game_started.connect(_on_game_started)

	# 按钮
	_host_btn.pressed.connect(_on_host_pressed)
	_join_btn.pressed.connect(_on_join_pressed)
	_start_btn.pressed.connect(_on_start_pressed)
	_back_btn.pressed.connect(_on_back_pressed)
	var cb: Callable = _on_server_selected
	_server_list.item_selected.connect(cb)

	# 默认端口
	_port_input.text = str(NetworkManager.DEFAULT_PORT)

	# ServerListener 在按下 Join 前创建（用于搜索 LAN 游戏）
	# Host 不需要监听（它是广播方）
	_setup_server_browser()

	_update_ui()


func _setup_server_browser() -> void:
	var listener := ServerListener.new()
	listener.name = "ServerListener"
	listener.new_server.connect(_on_new_server)
	listener.remove_server.connect(_on_remove_server)
	add_child(listener)


func _update_ui() -> void:
	if _is_host:
		_status_label.text = "等待玩家加入..."
		_host_btn.hide()
		_join_btn.hide()
		_server_list.hide()
		_ip_input.hide()
		_port_input.hide()
		_start_btn.show()
		_update_player_list()
	else:
		_status_label.text = "搜索局域网游戏..."
		_host_btn.show()
		_join_btn.show()
		_start_btn.hide()


func _update_player_list() -> void:
	var lines: PackedStringArray = []
	for id in NetworkManager.players:
		lines.append("  %s  (ID: %d)" % [NetworkManager.get_player_name(id), id])
	_player_list.text = "已连接玩家:\n" + "\n".join(lines) if lines.size() > 0 else "已连接玩家:\n  (等待中...)"


# ═══════════════════════════════════════
# 信号回调
# ═══════════════════════════════════════


func _update_advertiser() -> void:
	var adv: ServerAdvertiser = get_node_or_null("ServerAdvertiser")
	if adv:
		adv.server_info["cur_players"] = NetworkManager.players.size()
func _on_player_connected(_id: int) -> void:
	_status_label.text = "已连接到房间！等待 Host 开始游戏..."
	if not _is_host:
		_host_btn.hide()
		_join_btn.hide()
		_server_list.hide()
	_update_player_list()
	_update_advertiser()


func _on_player_disconnected(_id: int) -> void:
	_update_player_list()


func _on_game_started() -> void:
	pass  # 场景切换由 NetworkManager.start_game RPC 处理


# ═══════════════════════════════════════
# 按钮回调
# ═══════════════════════════════════════

func _on_host_pressed() -> void:
	var port: int = int(_port_input.text) if _port_input.text.is_valid_int() else NetworkManager.DEFAULT_PORT
	NetworkManager.host_game(port)
	_is_host = true
	# 移除 ServerListener（Host 不需要监听）
	var sl: Node = get_node_or_null("ServerListener")
	if sl:
		sl.queue_free()

	# 启动 LAN 广播
	var advertiser := ServerAdvertiser.new()
	advertiser.name = "ServerAdvertiser"
	advertiser.server_info["name"] = "のび太的求生之路"
	advertiser.server_info["port"] = int(port)
	advertiser.server_info["max_players"] = 4
	advertiser.server_info["cur_players"] = NetworkManager.players.size()
	add_child(advertiser)

	_update_ui()


func _on_join_pressed() -> void:
	var ip: String = _ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var port: int = int(_port_input.text) if _port_input.text.is_valid_int() else NetworkManager.DEFAULT_PORT
	NetworkManager.join_game(ip, port)

	# 等待连接...然后显示
	_status_label.text = "正在连接 %s:%d ..." % [ip, port]
	_host_btn.hide()
	_join_btn.hide()
	_server_list.hide()


func _on_start_pressed() -> void:
	if not _is_host:
		return
	# 通知所有客户端加载地图
	NetworkManager.start_game.rpc(campaign_scene)


func _on_back_pressed() -> void:
	NetworkManager.disconnect_game()
	_is_host = false
	var tree := get_tree()
	if tree:
		tree.change_scene_to_file("res://scene/title_screen.tscn")


# ═══════════════════════════════════════
# LAN 服务器列表
# ═══════════════════════════════════════

func _on_new_server(info: Dictionary) -> void:
	var label: String = "%s (%d/%d)" % [
		info.get("name", "??"),
		info.get("cur_players", 0),
		info.get("max_players", 4),
	]
	var idx: int = _server_list.add_item(label)
	_server_list.set_item_metadata(idx, info)


func _on_remove_server(ip: String) -> void:
	for i in range(_server_list.item_count):
		var info: Dictionary = _server_list.get_item_metadata(i)
		if info.get("ip", "") == ip:
			_server_list.remove_item(i)
			break


func _on_server_selected(idx: int) -> void:
	var info: Dictionary = _server_list.get_item_metadata(idx)
	_ip_input.text = info.get("ip", "")
	_port_input.text = str(info.get("port", NetworkManager.DEFAULT_PORT))
