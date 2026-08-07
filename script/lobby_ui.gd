extends Control
## 联机大厅 UI — 创建/加入房间界面
##
## 操作：
##   上/下   → 移动光标
##   确定键  → 确认选择
##   取消键  → 返回标题画面


const MENU_ITEMS_HOST: Array[String] = ["创建房间", "返回"]
const MENU_ITEMS_CLIENT: Array[String] = ["输入 IP 地址", "加入房间", "返回"]

enum Phase { MAIN, HOST_LOBBY, CLIENT_LOBBY, JOINING }

@export_group("布局")
@export var font_size: int = 16
@export var item_height: float = 28.0
@export var item_spacing: float = 8.0
@export var start_y: float = 180.0
@export var panel_width: float = 320.0
@export var panel_height: float = 360.0

@export_group("字体/颜色")
@export var font_path: String = "res://art/System/ark-pixel-16px-monospaced-zh_cn.ttf"
@export var color_sheet_path: String = "res://art/System/Text color, 20 types (each 16 x 16).png"
@export var text_color_index: int = 1
@export var text_color_row: int = 0

@export_group("场景路径")
@export var title_screen_scene: String = "res://scene/title_screen.tscn"
@export var game_map_path: String = "res://scene/maps/multiplayer_test.tscn"

var _phase: int = Phase.MAIN
var _cursor_idx: int = 0
var _ip_address: String = "127.0.0.1"

# UI 元素
var _title_label: Label = null
var _item_labels: Array[Label] = []
var _cursor_rect: ColorRect = null
var _ip_input: LineEdit = null
var _player_list_labels: Array[Label] = []
var _status_label: Label = null
var _start_button_rect: ColorRect = null
var _start_button_label: Label = null
var _in_ip_edit: bool = false


func _ready() -> void:
	# 连接 Lobby 信号
	Lobby.player_connected.connect(_on_player_connected)
	Lobby.player_disconnected.connect(_on_player_disconnected)
	Lobby.server_disconnected.connect(_on_server_disconnected)

	_create_ui()
	_refresh_phase()


func _create_ui() -> void:
	# 背景
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = Color(0.02, 0.02, 0.08, 0.92)
	bg.size = Vector2(1280, 960)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 面板背景
	var panel := ColorRect.new()
	panel.name = "Panel"
	panel.color = Color(0.05, 0.05, 0.15, 0.9)
	panel.size = Vector2(panel_width, panel_height)
	panel.position = Vector2((1280.0 - panel_width) / 2.0, (960.0 - panel_height) / 2.0 - 40)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	# 标题
	_title_label = _make_label("のび太的求生之路 — 联机模式", Vector2(panel.position.x, panel.position.y + 20), 20)
	_title_label.size.x = panel_width
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_title_label)

	# IP 输入框（初始隐藏）
	_ip_input = LineEdit.new()
	_ip_input.name = "IPInput"
	_ip_input.text = _ip_address
	_ip_input.placeholder_text = "输入 IP 地址..."
	_ip_input.size = Vector2(200, 30)
	_ip_input.position = Vector2((1280.0 - 200) / 2.0, start_y)
	var ip_cb: Callable = func(new_text: String): _ip_address = new_text
	_ip_input.text_changed.connect(ip_cb)
	_ip_input.visible = false
	add_child(_ip_input)

	# 状态文字
	_status_label = _make_label("", Vector2(panel.position.x, panel.position.y + panel_height - 60), 14)
	_status_label.size.x = panel_width
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.modulate = Color(0.6, 0.6, 0.7)
	add_child(_status_label)

	# 光标矩形
	_cursor_rect = ColorRect.new()
	_cursor_rect.name = "CursorRect"
	_cursor_rect.color = Color(0.3, 0.3, 0.6, 0.5)
	_cursor_rect.size = Vector2(panel_width - 40, item_height)
	_cursor_rect.visible = false
	add_child(_cursor_rect)


func _make_label(text: String, pos: Vector2, fsize: int) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override("font_size", fsize)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if not font_path.is_empty() and ResourceLoader.exists(font_path):
		var fd: FontFile = load(font_path) as FontFile
		if fd:
			label.add_theme_font_override("font", fd)
	return label


func _build_item_labels(items: Array[String]) -> void:
	_clear_item_labels()
	var base_x: float = (1280.0 - panel_width) / 2.0 + 20
	for i: int in range(items.size()):
		var y: float = start_y + i * (item_height + item_spacing)
		var label := _make_label("  %s" % items[i], Vector2(base_x, y), font_size)
		add_child(label)
		_item_labels.append(label)


func _clear_item_labels() -> void:
	for label in _item_labels:
		if is_instance_valid(label):
			label.queue_free()
	_item_labels.clear()


func _clear_player_list() -> void:
	for label in _player_list_labels:
		if is_instance_valid(label):
			label.queue_free()
	_player_list_labels.clear()


func _refresh_phase() -> void:
	_clear_item_labels()
	_clear_player_list()
	_cursor_rect.visible = false
	_ip_input.visible = false
	_in_ip_edit = false
	_start_button_rect = null
	_start_button_label = null

	match _phase:
		Phase.MAIN:
			_status_label.text = ""
			_build_item_labels(MENU_ITEMS_HOST)
			_cursor_idx = 0
			_cursor_rect.visible = true

		Phase.HOST_LOBBY:
			_status_label.text = "房间已创建 — 等待玩家加入..."
			_refresh_cursor()
			_cursor_rect.visible = false
			# 显示玩家列表
			_refresh_player_list()
			# 显示开始按钮
			_create_start_button()

		Phase.CLIENT_LOBBY:
			_status_label.text = "已连接到房间"
			_cursor_rect.visible = false
			_refresh_player_list()

		Phase.JOINING:
			_status_label.text = "正在连接 %s:%d ..." % [_ip_address, Lobby.PORT]
			_ip_input.visible = true
			_build_item_labels(MENU_ITEMS_CLIENT)
			_cursor_idx = 0
			_cursor_rect.visible = true

	_refresh_cursor()


func _create_start_button() -> void:
	var btn_w: float = 160.0
	var btn_h: float = 36.0
	_start_button_rect = ColorRect.new()
	_start_button_rect.name = "StartButton"
	_start_button_rect.color = Color(0.15, 0.4, 0.15, 0.8)
	_start_button_rect.size = Vector2(btn_w, btn_h)
	_start_button_rect.position = Vector2((1280.0 - btn_w) / 2.0, panel.position.y + panel_height - 100)
	add_child(_start_button_rect)

	_start_button_label = _make_label("开始游戏", Vector2(_start_button_rect.position.x, _start_button_rect.position.y), font_size)
	_start_button_label.size.x = btn_w
	_start_button_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_button_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_start_button_label)


func _refresh_player_list() -> void:
	_clear_player_list()
	var base_x: float = (1280.0 - panel_width) / 2.0 + 30
	var base_y: float = start_y + 60
	for peer_id: int in Lobby.players:
		var info: Dictionary = Lobby.players[peer_id]
		var name_str: String = info.get("name", "Player %d" % peer_id)
		var marker: String = " [HOST]" if peer_id == 1 else ""
		var label := _make_label("%s%s (ID:%d)" % [name_str, marker, peer_id], Vector2(base_x, base_y), font_size)
		base_y += item_height
		add_child(label)
		_player_list_labels.append(label)


func _refresh_cursor() -> void:
	if not _cursor_rect or not _cursor_rect.visible:
		return
	var base_x: float = (1280.0 - panel_width) / 2.0 + 16
	_cursor_rect.position = Vector2(base_x, start_y + _cursor_idx * (item_height + item_spacing) - 2)


func _input(event: InputEvent) -> void:
	if _in_ip_edit:
		if event.is_action_pressed("取消键") or event.is_action_pressed("确定键"):
			_in_ip_edit = false
			_ip_input.release_focus()
			_ip_input.visible = false
			_cursor_rect.visible = true
		return

	match _phase:
		Phase.MAIN:
			_handle_main_input(event)
		Phase.JOINING:
			_handle_joining_input(event)
		Phase.HOST_LOBBY:
			_handle_host_lobby_input(event)
		Phase.CLIENT_LOBBY:
			if event.is_action_pressed("取消键"):
				_go_back_to_title()


func _handle_main_input(event: InputEvent) -> void:
	var item_count: int = MENU_ITEMS_HOST.size()

	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		_refresh_cursor()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		_refresh_cursor()
	elif event.is_action_pressed("确定键"):
		match _cursor_idx:
			0:  # 创建房间
				var err: Error = Lobby.create_game()
				if err == OK:
					_phase = Phase.HOST_LOBBY
					_refresh_phase()
				else:
					_status_label.text = "创建房间失败 (err=%d)" % err
			1:  # 返回
				_go_back_to_title()
	elif event.is_action_pressed("取消键"):
		_go_back_to_title()


func _handle_joining_input(event: InputEvent) -> void:
	var item_count: int = MENU_ITEMS_CLIENT.size()

	if event.is_action_pressed("上"):
		_cursor_idx = (_cursor_idx - 1 + item_count) % item_count
		_refresh_cursor()
	elif event.is_action_pressed("下"):
		_cursor_idx = (_cursor_idx + 1) % item_count
		_refresh_cursor()
	elif event.is_action_pressed("确定键"):
		match _cursor_idx:
			0:  # 输入 IP
				_in_ip_edit = true
				_ip_input.visible = true
				_ip_input.grab_focus()
				_cursor_rect.visible = false
			1:  # 加入房间
				var err: Error = Lobby.join_game(_ip_address)
				if err == OK:
					# 连接成功会触发 connected_to_server → _on_connected_ok
					pass
				else:
					_status_label.text = "连接失败 (err=%d)" % err
			2:  # 返回
				_phase = Phase.MAIN
				_refresh_phase()
	elif event.is_action_pressed("取消键"):
		_phase = Phase.MAIN
		_refresh_phase()


func _handle_host_lobby_input(event: InputEvent) -> void:
	if event.is_action_pressed("取消键"):
		Lobby.remove_multiplayer_peer()
		_go_back_to_title()
	elif event.is_action_pressed("确定键"):
		# 检查是否点击了开始按钮（简化：Host 模式下确定键即开始）
		if Lobby.players.size() >= 1:
			var map_path: String = game_map_path
			print("[大厅] Host 启动游戏 → %s" % map_path)
			Lobby.load_game.rpc(map_path)


func _go_back_to_title() -> void:
	if Lobby.is_online():
		Lobby.remove_multiplayer_peer()
	get_tree().change_scene_to_file(title_screen_scene)


# ═══════════════════════════════════════
# Lobby 信号回调
# ═══════════════════════════════════════

func _on_player_connected(peer_id: int, _player_info: Dictionary) -> void:
	print("[大厅UI] 玩家已连接: %d" % peer_id)
	if _phase == Phase.JOINING:
		# Client 连接成功 → 进入等待室
		_phase = Phase.CLIENT_LOBBY
	_refresh_phase()


func _on_player_disconnected(peer_id: int) -> void:
	print("[大厅UI] 玩家已断开: %d" % peer_id)
	_refresh_phase()


func _on_server_disconnected() -> void:
	print("[大厅UI] 服务器断开！返回标题画面")
	_status_label.text = "服务器已断开！"
	var cb: Callable = _go_back_to_title
	var timer := get_tree().create_timer(2.0)
	timer.timeout.connect(cb)
