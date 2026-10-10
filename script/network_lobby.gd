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
## 端口输入框（**加入房间**用；默认 27015，可改为内网穿透服务分配的 UDP 端口）。
@onready var port_edit: SpinBox = %PortEdit
## ★创建房间的本机监听端口（2026-09-27 用户需求：与"加入端口"分开，各自独立可调）。
@onready var host_port_edit: SpinBox = %HostPortEdit
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
## ── 两界面结构（2026-09-27 用户需求：大厅 / 房间分离）──
## 大厅 = 开房/加入；房间 = 选角色/难度/开局 + 四个玩家槽位（L4D2 版式）。
@onready var connect_panel: Control = $ConnectPanel
@onready var room_panel: Control = $RoomPanel
@onready var difficulty_select: OptionButton = %DifficultySelect
@onready var room_name_label: Label = %RoomNameLabel
@onready var room_info_label: Label = %RoomInfoLabel
@onready var room_log_label: Label = %RoomLogLabel
## 演示用未类型化 Array：`%` 取到的节点静态类型未知，写死 Array[Label] 会在赋值时校验失败。
@onready var slot_labels: Array = [%SlotName1, %SlotName2, %SlotName3, %SlotName4]
## 房间信息卡的容器（代码往里面插「选择章节」一行，避免再改 .tscn）。
@onready var room_info_box: Control = $RoomPanel/Margin/Column/Row/Left/InfoCard/InfoBox
## 房间内「选择章节」（代码创建）：主机可选从战役的哪一关开始，客户端只显示。
var chapter_select: OptionButton = null
var _chapter_entries: Array[Dictionary] = []
var _selected_chapter: int = 0

var _connected := false
var _log_lines: Array[String] = []
var _refreshing_character_select := false
## 通过节点路径读取 Autoload，避免 Godot 编辑器热重载期间短暂丢失 `Net` 全局标识符。
var net: Variant = null

## ── 互联网页签（2026-10-09）──
## 大厅分「互联网 / 直连」两种连接方式。互联网 = 走 Master Server 房间目录；
## 直连 = 现有表单（降级路径，**不得移除**，方案 §6）。
## 页签与 InternetPanel 全部代码构建，避免改 .tscn 丢属性。
const INTERNET_PANEL_SCRIPT := "res://script/internet_lobby_panel.gd"
## 隧道客户端已升级为 autoload（project.godot 的 `Tunnel="*res://script/tunnel_client.gd"`），
## 不再用脚本常量 new 出来挂到本场景（原因见下方 `_setup_connection_tabs` 第 4 步）。
var _tab_bar: HBoxContainer = null
var _internet_tab_btn: Button = null
var _direct_tab_btn: Button = null
var _direct_container: Control = null
var _internet_panel: Control = null
## 隧道客户端（路线二）：房主开互联网房时自动拉起，替代 frpc。
var _tunnel_client: Node = null
## 自动穿透模式下，等隧道就绪后需要用到的房间名（异步流程中转存）。
var _pending_internet_room_name := ""
## 开局流程进行中（`_on_start_pressed` 内含 `await`，用它防连点重复广播 start_game）。
var _starting := false

const TAB_INTERNET := "internet"
const TAB_DIRECT := "direct"

## 本机作为互联网房主时的房间凭据（**不落盘**，方案 §3.4）。空 = 当前不是互联网房主。
var _internet_room_id := ""
var _internet_host_token := ""
## 心跳定时器（房主侧保活）。10s 一次，与服务端 60s 超时配套（方案 §3.5）。
var _heartbeat_accum := 0.0
const HEARTBEAT_INTERVAL := 10.0


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

	_setup_room_panel()
	_setup_connection_tabs()
	_sync_panels()
	## 两界面正文字号统一放大（2026-09-28 用户反馈"文字太小"）：正文 24 / 窗内标题 36。
	## 放在最后调用，连 `_add_wip_notice()` / `_add_back_button()` 新建的控件一起覆盖。
	_apply_panel_font_sizes()

	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_run_auto_host()
	elif "--net-test=client" in user_args:
		_run_auto_client()


# ---------------------------------------------------------------- 两界面结构（2026-09-27）

## 档位：正文 24、窗内标题 36（都是 12 的整倍 —— 像素字体铁律）；页标题是 60px 渐变，不动。
## 提为类级常量（2026-10-01）：端口框宽度要按同一字号算，两处必须同源。
const BODY_FONT_SIZE: int = 24
const PANEL_TITLE_FONT_SIZE: int = 36


## 大厅 / 房间两界面的正文字号统一（2026-09-28 用户反馈「文字太小」）。
## 档位：正文 24、窗内标题 36（都是 12 的整倍 —— 像素字体铁律）；页标题是 60px 渐变，不动。
## 刻意用代码统一覆盖而不写进 .tscn：既避免「编辑器重存丢属性」，也让之后新增的控件自动跟随。
func _apply_panel_font_sizes() -> void:
	for panel: Control in [connect_panel, room_panel]:
		if panel == null:
			continue
		for node: Node in panel.find_children("*", "Control", true, false):
			if node is Label:
				Global.apply_ui_font(node as Label, BODY_FONT_SIZE)
			elif node is BaseButton:
				## Button / OptionButton / CheckBox 都走这里（OptionButton 继承 Button）。
				(node as BaseButton).add_theme_font_size_override("font_size", BODY_FONT_SIZE)
			elif node is LineEdit:
				(node as LineEdit).add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	## 窗内标题比正文大一档，保住层级。
	for title_path: String in ["ConnectPanel/VBox/Title", "RoomPanel/Margin/Column/Title"]:
		var title: Label = get_node_or_null(title_path) as Label
		if title != null:
			Global.apply_ui_font(title, PANEL_TITLE_FONT_SIZE)
	## 端口框宽度必须跟着字号走（放在字号设置之后）。
	_widen_port_fields()


## ── 端口输入框宽度（2026-10-01 用户反馈：手机端端口框只能显示四位数）──
## 端口最大 65535 = **5 位**。SpinBox 没有自己的字体 —— 字体与字号都在**内部 LineEdit** 上：
##   · `find_children("*", "Control")` **拿不到**它（实测：遍历走不到 → 字号覆盖落空 → 输入框仍按默认字号
##     算最小宽，正文放大后 5 位数字被裁掉）；
##   · 正确入口是官方 API `SpinBox.get_line_edit()`。
## 这里显式把正文字号套到内部 LineEdit + 按**字体实测宽度**留位（不写死像素），字号再改也自动跟随。
const PORT_DIGITS: int = 5
## SpinBox 右侧上下箭头 + 内边距的宽裕量（正文 24px 下实测取值；字号更大时偏保守无害）。
const PORT_SPIN_EXTRA: float = 56.0


func _widen_port_fields() -> void:
	for box: SpinBox in [port_edit, host_port_edit]:
		if box == null:
			continue
		var inner: LineEdit = box.get_line_edit()
		var font: Font = Global.get_ui_font()
		if inner != null:
			inner.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
			var inner_font: Font = inner.get_theme_font("font")
			if inner_font != null:
				font = inner_font
		var text_w: float = 0.0
		if font != null:
			text_w = font.get_string_size("0".repeat(PORT_DIGITS),
				HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT_SIZE).x
		if text_w <= 0.0:
			text_w = float(PORT_DIGITS) * float(BODY_FONT_SIZE) * 0.62   ## 兜底估算
		box.custom_minimum_size = Vector2(text_w + PORT_SPIN_EXTRA, box.custom_minimum_size.y)


## 房间界面的一次性初始化：难度选项 + 只读信息栏。
## 难度是本局属性（Global.selected_difficulty：0 简单 / 1 中等 / 2 困难 / 3 专家），
## 只有主机可改；客户端看到的是主机同步过来的值，下拉框置灰。
func _setup_room_panel() -> void:
	for label: String in ["简单", "中等", "困难", "专家"]:
		difficulty_select.add_item(label)
	difficulty_select.select(clampi(Global.selected_difficulty, 0,
		maxi(difficulty_select.item_count - 1, 0)))
	difficulty_select.item_selected.connect(_on_difficulty_selected)
	_setup_visual_style()
	_setup_chapter_select()
	_refresh_room_info()


func _on_difficulty_selected(index: int) -> void:
	if net == null or not bool(net.get("is_host")):
		_refresh_room_info()
		return
	Global.selected_difficulty = index
	_log("难度已设为：%s" % difficulty_select.get_item_text(index))


func _refresh_room_info() -> void:
	var host_side: bool = net != null and bool(net.get("is_host"))
	difficulty_select.disabled = not host_side
	room_name_label.text = "房间：%s" % ("本机（主机）" if host_side else "已加入")
	var campaign_name: String = "—"
	if _chapter_entries.size() > 0:
		campaign_name = str(_chapter_entries[clampi(_selected_chapter, 0,
			_chapter_entries.size() - 1)].get("campaign", "—"))
	room_info_label.text = "战役：%s\n起始章节：%s" % [campaign_name, _selected_chapter + 1]
	_refresh_chapter_select()


## 大厅 / 房间两个界面按"是否已连接"切换。
func _sync_panels() -> void:
	if connect_panel:
		connect_panel.visible = not _connected
	if room_panel:
		room_panel.visible = _connected


# ---------------------------------------------------------------- 互联网 / 直连 页签（2026-10-09）

## 在 ConnectPanel 内加一条页签栏，并把现有表单收进「直连」子容器。
##
## 【为什么这样改而不是重做大堂】现有 ConnectPanel 的表单是降级路径（方案 §6 要求
## **不得移除**），整块保留最安全；「互联网」只是与它并列的另一种方式。页签栏与互联网
## 面板都在代码里搭，避免编辑器重存 .tscn 丢属性（与 _setup_room_panel 同风格）。
func _setup_connection_tabs() -> void:
	var vbox: Control = _connect_vbox()
	if vbox == null:
		return

	## 1) 把现有表单控件收进一个「直连」容器：除标题与返回按钮外全部搬进去。
	_direct_container = VBoxContainer.new()
	_direct_container.name = "DirectView"
	_direct_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_direct_container.add_theme_constant_override("separation", 10)
	vbox.add_child(_direct_container)
	for child: Node in vbox.get_children():
		if child == _direct_container or child == _tab_bar:
			continue
		if child is Label and (child as Label).name == "Title":
			continue      ## 窗内标题留在外面（它是面板级标题）
		if (child as Node).name == "BackToTitleBtn" or (child as Node).name == "WipNotice":
			continue      ## 属于大厅界面而非表单
		if child is Control:
			vbox.remove_child(child)
			_direct_container.add_child(child)

	## 2) 页签栏插到标题正下方。
	_tab_bar = HBoxContainer.new()
	_tab_bar.name = "ConnectionTabs"
	_tab_bar.add_theme_constant_override("separation", 8)
	vbox.add_child(_tab_bar)
	vbox.move_child(_tab_bar, 1)   ## 0 是标题

	_internet_tab_btn = Button.new()
	_internet_tab_btn.name = "InternetTabBtn"
	_internet_tab_btn.text = "互联网"
	_internet_tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_internet_tab_btn.toggle_mode = true
	_internet_tab_btn.pressed.connect(func() -> void: _select_tab(TAB_INTERNET))
	_tab_bar.add_child(_internet_tab_btn)

	_direct_tab_btn = Button.new()
	_direct_tab_btn.name = "DirectTabBtn"
	_direct_tab_btn.text = "直连"
	_direct_tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_direct_tab_btn.toggle_mode = true
	_direct_tab_btn.pressed.connect(func() -> void: _select_tab(TAB_DIRECT))
	_tab_bar.add_child(_direct_tab_btn)

	## 3) 互联网面板（独立脚本，代码构建）。
	var script: GDScript = load(INTERNET_PANEL_SCRIPT) as GDScript
	if script == null:
		push_error("[NetworkLobby] 找不到 internet_lobby_panel.gd")
		_select_tab(TAB_DIRECT)
		return
	_internet_panel = script.new() as Control
	_internet_panel.name = "InternetView"
	_internet_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_internet_panel)
	_internet_panel.join_requested.connect(_on_internet_join_requested)
	_internet_panel.create_requested.connect(_on_internet_create_requested)
	_internet_panel.room_registered_external.connect(_on_internet_room_registered)
	_internet_panel.closed.connect(func() -> void: _select_tab(TAB_DIRECT))

	## 4) 隧道客户端（路线二）：**autoload 常驻**（project.godot 的 `Tunnel=...`），
	##    这里只取引用 + 接信号，绝不再挂到本场景。
	## 【为什么】房主「开始游戏」会 change_scene_to_file 释放大厅场景；此前把隧道挂在
	##    大厅下 → 开局瞬间隧道被销毁 → 外网客户端收不到回包 → ENet 超时
	##    SERVER_DISCONNECTED，且客户端表现为「只看得见自己、仍是 P1」（实测 bug）。
	## 【为何判 is_connected】Tunnel 是**跨场景常驻**的 autoload，而本大厅会随进出房间
	##    反复实例化；不判重就连多次 → 一个信号触发多个回调（重复注册房间等）。
	_tunnel_client = get_node_or_null("/root/Tunnel")
	if _tunnel_client == null:
		push_error("[NetworkLobby] 未找到 Tunnel autoload（检查 project.godot 的 [autoload]）")
	else:
		for pair: Array in [
				["tunnel_ready", _on_tunnel_ready],
				["tunnel_failed", _on_tunnel_failed],
				["tunnel_closed", _on_tunnel_closed]]:
			var sig: String = str(pair[0])
			var handler: Callable = pair[1]
			if not _tunnel_client.is_connected(sig, handler):
				_tunnel_client.connect(sig, handler)

	_select_tab(TAB_DIRECT)   ## 默认直连：不改变老玩家的既有路径
	## ⚠ 新增控件是在 `_setup_room_panel()` 的 `_push_down_content()` **之后**加进来的，
	## 需要再套一次缩进，否则页签会压在页标题上。
	_push_down_content(connect_panel)


func _select_tab(which: String) -> void:
	if _direct_container == null or _internet_panel == null:
		return
	var internet: bool = which == TAB_INTERNET
	_direct_container.visible = not internet
	_internet_panel.visible = internet
	if _internet_tab_btn != null:
		_internet_tab_btn.button_pressed = internet
	if _direct_tab_btn != null:
		_direct_tab_btn.button_pressed = not internet
	if internet:
		_internet_panel.show_list()
		_log("已切到互联网模式：从大厅房间列表加入，或创建互联网房间。")


## 互联网列表里点「加入」→ 复用现有 Net.join_game 入口（零改动，方案 §5.4）。
func _on_internet_join_requested(address: String, port: int, room_name: String) -> void:
	net.player_name = name_edit.text
	_log("正在加入互联网房间「%s」：%s:%d …" % [room_name, address, port])
	var err: Error = net.join_game(address, port)
	if err != OK:
		_log("加入失败：%s" % error_string(err))
		return
	_set_connect_buttons_disabled(true)


## 创建互联网房间：① 本机 host_game（拿到真实端口）→ ② 连接隧道（自动模式）或直接用
## 玩家手填的穿透地址（手动模式）→ ③ 向大厅注册。
##
## 自动模式（路线二）：tunnel_address 为空 → 启动内置隧道客户端 → 等隧道就绪 → 注册。
## 手动模式：tunnel_address 非空 → 直接用玩家填的穿透地址注册（现有逻辑）。
func _on_internet_create_requested(room_name: String, tunnel_address: String, tunnel_port: int) -> void:
	net.player_name = name_edit.text
	var port := int(host_port_edit.value)

	## 自动模式不需要 UPnP（隧道处理 NAT 穿透）；手动模式保留 UPnP 预填逻辑。
	if tunnel_address.is_empty():
		net.upnp_enabled = false
	else:
		net.upnp_enabled = upnp_check.button_pressed

	var err: Error = net.host_game(port)
	if err != OK:
		_log("创建房间失败：%s" % error_string(err))
		if _internet_panel != null and _internet_panel.has_method("on_create_failed"):
			_internet_panel.on_create_failed(error_string(err))
		return
	_connected = true

	## ── 自动穿透模式：启动隧道客户端，等就绪后注册 ──
	if tunnel_address.is_empty():
		if _tunnel_client == null:
			_log("隧道客户端未初始化，回退到手动模式")
			if _internet_panel != null and _internet_panel.has_method("on_create_failed"):
				_internet_panel.on_create_failed("隧道客户端未初始化")
			return
		## ⚠ 必须显式标注类型：`_tunnel_client` 静态类型是 Node，对它调用自定义方法
		## 会被视为动态调用返回 Variant，用 `:=` 会报「Cannot infer the type」并导致整脚本加载失败。
		var server_host: String = _tunnel_client.extract_host_from_url(Global.master_server_url)
		if server_host.is_empty():
			_log("无法从大厅地址提取服务器主机名")
			if _internet_panel != null and _internet_panel.has_method("on_create_failed"):
				_internet_panel.on_create_failed("无法解析服务器地址")
			return
		_pending_internet_room_name = room_name
		_tunnel_client.setup(server_host)
		_tunnel_client.start(port)
		if _internet_panel != null and _internet_panel.has_method("set_tunnel_status"):
			_internet_panel.set_tunnel_status(
				"正在连接隧道服务 %s:%d …" % [server_host, _tunnel_client.TUNNEL_TCP_PORT],
				Color(0.78, 0.84, 0.9))
		_log("本机已监听 UDP %d，正在连接隧道服务…" % port)
		_refresh_ui()
		return

	## ── 手动模式：直接用玩家填的穿透地址注册 ──
	_log("本机已监听 UDP %d，正在向大厅注册房间「%s」…" % [port, room_name])
	var payload := {
		"name": room_name,
		"hostName": str(net.player_name),
		"address": tunnel_address,
		"port": tunnel_port,
		"transport": "udp",
		"currentPlayers": 1,
		"maxPlayers": Net.MAX_CLIENTS,
		"difficulty": Global.selected_difficulty,
		"chapterLabel": _current_chapter_label(),
		"gameVersion": _changelog_version(),
		"protocol": Net.PROTOCOL_VERSION,
	}
	if _internet_panel != null and _internet_panel.has_method("register_room"):
		_internet_panel.register_room(payload)
	_refresh_ui()


func _current_chapter_label() -> String:
	if _chapter_entries.size() == 0:
		return ""
	return str(_chapter_entries[clampi(_selected_chapter, 0, _chapter_entries.size() - 1)].get("label", ""))


func _changelog_version() -> String:
	## 与 title_screen 的 CHANGELOG_VERSION_TEXT 同源（方案 §3.3：列表按版本分桶）。
	return str(ProjectSettings.get_setting("application/config/version", ""))


## 注册成功 → 记下凭据 + 启动心跳（房主侧保活）。
func _on_internet_room_registered(room: Dictionary, host_token: String) -> void:
	_internet_room_id = str(room.get("id", ""))
	_internet_host_token = host_token
	_heartbeat_accum = 0.0
	_log("房间已注册（ID %s），好友可在互联网列表看到。" % _internet_room_id)
	if _internet_panel != null and _internet_panel.has_method("on_room_registered"):
		_internet_panel.on_room_registered()


# ── 隧道信号处理（路线二：自动穿透）──

## 隧道就绪：用隧道公网地址向大厅注册房间。
func _on_tunnel_ready(public_address: String, public_port: int) -> void:
	_log("隧道就绪：公网地址 %s:%d" % [public_address, public_port])
	if _internet_panel != null and _internet_panel.has_method("set_tunnel_status"):
		_internet_panel.set_tunnel_status(
			"✔ 隧道已连接，公网端口 %d" % public_port, Color(0.55, 0.92, 0.6))
	if _pending_internet_room_name.is_empty():
		return
	var room_name := _pending_internet_room_name
	_pending_internet_room_name = ""
	var payload := {
		"name": room_name,
		"hostName": str(net.player_name),
		"address": public_address,
		"port": public_port,
		"transport": "udp",
		"currentPlayers": 1,
		"maxPlayers": Net.MAX_CLIENTS,
		"difficulty": Global.selected_difficulty,
		"chapterLabel": _current_chapter_label(),
		"gameVersion": _changelog_version(),
		"protocol": Net.PROTOCOL_VERSION,
	}
	if _internet_panel != null and _internet_panel.has_method("register_room"):
		_internet_panel.register_room(payload)


## 隧道连接失败：通知面板 + 清理本机 host。
func _on_tunnel_failed(reason: String) -> void:
	_log("隧道连接失败：%s" % reason)
	_pending_internet_room_name = ""
	if _internet_panel != null and _internet_panel.has_method("set_tunnel_status"):
		_internet_panel.set_tunnel_status("✖ 隧道连接失败：%s" % reason, Color(1.0, 0.45, 0.4))
	if _internet_panel != null and _internet_panel.has_method("on_create_failed"):
		_internet_panel.on_create_failed("隧道连接失败")
	## host_game 已启动但隧道没通 → 回退到离线
	if _connected and bool(net.get("is_host")):
		net.leave()
		_connected = false
	_refresh_ui()


## 隧道意外断开（非主动 stop）。
func _on_tunnel_closed() -> void:
	_log("隧道已断开")
	if not _internet_room_id.is_empty():
		## 房间还在大厅但隧道已断 → 清除凭据，房间会自然超时
		_internet_room_id = ""
		_internet_host_token = ""
	if _internet_panel != null and _internet_panel.has_method("set_tunnel_status"):
		_internet_panel.set_tunnel_status("隧道已断开", Color(1.0, 0.85, 0.3))
	_refresh_ui()


func _process(delta: float) -> void:
	_update_internet_heartbeat(delta)


## 房主侧心跳：每 10s 一次。服务端 60s 无心跳即清房（方案 §3.5）。
func _update_internet_heartbeat(delta: float) -> void:
	if _internet_room_id.is_empty() or _internet_panel == null:
		return
	if not _connected or not bool(net.get("is_host")):
		return
	_heartbeat_accum += delta
	if _heartbeat_accum < HEARTBEAT_INTERVAL:
		return
	_heartbeat_accum = 0.0
	var players: int = net.get_player_names().size()
	_internet_panel.heartbeat(_internet_room_id, _internet_host_token, players)


## 右侧四个玩家槽位（L4D2 版式）：按 peer 顺序填，空位显示「有空位」。
## 同一个函数也给隐藏的 `%PlayersLabel` 供旧文本（回归用例仍在读它）。
func _refresh_slots(names: Dictionary, peer_ids: Array[int]) -> void:
	if slot_labels.is_empty():
		return
	for i: int in range(slot_labels.size()):
		var label: Variant = slot_labels[i]
		if not (label is Label):
			continue
		if i >= peer_ids.size():
			(label as Label).text = "○ 有空位\n　 等待玩家加入"
			continue
		var peer_id: int = peer_ids[i]
		var character_path: String = str(net.get_player_character_path(peer_id))
		var character_name: String = str(net.get_character_display_name(character_path)) \
			if not character_path.is_empty() else "未选择角色"
		var tag: String = "（主机）" if peer_id == 1 else ""
		var ready: String = "已选角色" if not character_path.is_empty() else "待选角色"
		(label as Label).text = "● %s%s\n　 角色：%s · %s" % [
			str(names[peer_id]), tag, character_name, ready]


# ---------------------------------------------------------------- 视觉样式（2026-09-27）
# 与「选择角色 / 选择战役」同款：下滚全景背景 + RM2K3 窗口皮（底色块 + 九宫格边框）
# + 左上角渐变页标题。刻意在代码里搭而不是写进 .tscn —— 这些资源路径与九宫格边距已在
# 那两个界面验证过，代码复刻不会有"编辑器重存丢属性"的风险。字体一律走全局唯一入口。
const BACKDROP_PATH := "res://art/Panorama/地下.png"
const WINDOW_BG_PATH := "res://art/System/Window background color.png"
const WINDOW_FRAME_PATH := "res://art/System/Window frame.png"
const COLOR_SHEET_PATH := "res://art/System/Text color, 20 types (each 16 x 16).png"
const WINDOW_MARGIN := 24.0
## 页标题（60px ＋留白）占用的顶部高度。面板内容与窗口皮都要整体下移这么多，
## 否则窗内标题会和页标题叠在同一行（用户实测："大厅有两个标题、旧标题没删"）。
const PAGE_TITLE_BAND := 92.0
## 内容相对窗口内边的缩进（窗口皮的内边距之外再留一点，文字不贴框）。
const CONTENT_PADDING := 12.0


func _setup_visual_style() -> void:
	_add_backdrop()
	_add_page_title()
	_skin_panel(connect_panel)
	_skin_panel(room_panel)
	## ⚠ 必须在 _skin_panel 之后：这样连窗口皮（WindowBg/WindowFrame）一起下移。
	_push_down_content(connect_panel)
	_push_down_content(room_panel)
	_style_window_title("ConnectPanel/VBox/Title", "创建 / 加入房间")
	_style_window_title("RoomPanel/Margin/Column/Title", "游戏大厅")


## 把面板下的控件排进「窗口」里：窗口皮下移到页标题之下，内容再往里缩 CONTENT_PADDING。
func _push_down_content(panel: Control) -> void:
	if panel == null:
		return
	var skin_top: float = WINDOW_MARGIN + PAGE_TITLE_BAND
	var inner: float = skin_top + CONTENT_PADDING
	for child: Node in panel.get_children():
		var ctrl: Control = child as Control
		if ctrl == null:
			continue
		if ctrl.name == "WindowBg" or ctrl.name == "WindowFrame":
			ctrl.offset_top = skin_top
			continue
		ctrl.offset_top = inner
		ctrl.offset_left = inner
		ctrl.offset_right = -inner


func _add_backdrop() -> void:
	if not ResourceLoader.exists(BACKDROP_PATH):
		return
	var backdrop: PanoramaBackdrop = PanoramaBackdrop.new()
	backdrop.texture_path = BACKDROP_PATH
	backdrop.bg_scale = 2.0
	backdrop.scroll_speed = 20.0
	backdrop.dim_alpha = 0.35
	add_child(backdrop)
	move_child(backdrop, 0)   ## 垫底：add_child 默认加到末尾，会盖住窗口


## 左上角页标题：与选择角色 / 选择战役同款渐变大字（60px = 12 × 5）。
func _add_page_title() -> void:
	var gl: GradientLabel = GradientLabel.new()
	gl.name = "PageTitle"
	gl.text = "多人大厅"
	gl.position = Vector2(40.0, 16.0)
	gl.size = Vector2(340.0, 84.0)
	gl.text_font_size = 60
	gl.color_index = 1
	gl.bold = true
	gl.shadow = true
	gl.color_sheet_path_override = COLOR_SHEET_PATH
	var img: Image = _color_sheet_image()
	if img:
		gl.set_color_image(img)
	add_child(gl)


func _color_sheet_image() -> Image:
	var tex: Texture2D = ResourceLoader.load(COLOR_SHEET_PATH) as Texture2D
	return tex.get_image() if tex != null else null


## 给一个面板套窗口皮：底色块 + 九宫格边框，插在最底层且不吃鼠标事件。
func _skin_panel(panel: Control) -> void:
	if panel == null:
		return
	var bg: TextureRect = TextureRect.new()
	bg.name = "WindowBg"
	bg.texture = ResourceLoader.load(WINDOW_BG_PATH) as Texture2D
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.offset_left = WINDOW_MARGIN
	bg.offset_top = WINDOW_MARGIN
	bg.offset_right = -WINDOW_MARGIN
	bg.offset_bottom = -WINDOW_MARGIN
	panel.add_child(bg)
	panel.move_child(bg, 0)

	var frame: NinePatchRect = NinePatchRect.new()
	frame.name = "WindowFrame"
	frame.texture = ResourceLoader.load(WINDOW_FRAME_PATH) as Texture2D
	frame.patch_margin_left = 20
	frame.patch_margin_top = 20
	frame.patch_margin_right = 20
	frame.patch_margin_bottom = 20
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = WINDOW_MARGIN
	frame.offset_top = WINDOW_MARGIN
	frame.offset_right = -WINDOW_MARGIN
	frame.offset_bottom = -WINDOW_MARGIN
	panel.add_child(frame)
	panel.move_child(frame, 1)


func _style_window_title(path: String, text_value: String) -> void:
	var label := get_node_or_null(path) as Label
	if label == null:
		return
	label.text = text_value
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_color_override("font_color", Color("e8c44b"))


## 房间内「选择章节」：主机可选从战役的哪一关开始；客户端只显示。
## 章节表与调试「跳转章节」共用 CampaignData.collect_chapter_entries()。
func _setup_chapter_select() -> void:
	if room_info_box == null or chapter_select != null:
		return
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "ChapterRow"
	row.add_theme_constant_override("separation", 8)
	var tag: Label = Label.new()
	tag.text = "选择章节："
	row.add_child(tag)
	chapter_select = OptionButton.new()
	chapter_select.name = "ChapterSelect"
	chapter_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(chapter_select)
	room_info_box.add_child(row)
	_chapter_entries = CampaignData.collect_all_level_entries()
	for entry: Dictionary in _chapter_entries:
		chapter_select.add_item(str(entry.get("label", "?")))
	chapter_select.item_selected.connect(_on_chapter_selected)
	_refresh_chapter_select()


func _on_chapter_selected(index: int) -> void:
	if net == null or not bool(net.get("is_host")):
		_refresh_chapter_select()
		return
	_selected_chapter = index
	_log("起始章节已设为：%s" % chapter_select.get_item_text(index))
	_refresh_room_info()


func _refresh_chapter_select() -> void:
	if chapter_select == null:
		return
	var host_side: bool = net != null and bool(net.get("is_host"))
	chapter_select.disabled = not host_side or chapter_select.item_count == 0
	if chapter_select.item_count > 0:
		chapter_select.select(clampi(_selected_chapter, 0, chapter_select.item_count - 1))


## 开始游戏用哪张图：选了章节就用它，否则回退到默认第一关。
func _current_start_scene() -> String:
	if _selected_chapter >= 0 and _selected_chapter < _chapter_entries.size():
		var scene_path: String = str(_chapter_entries[_selected_chapter].get("scene", ""))
		if not scene_path.is_empty():
			return scene_path
	return GAME_SCENE


# ---------------------------------------------------------------- 表现层小件

## 「返回标题」按钮（2026-09-14 用户要求）：不必重开游戏就能回标题；
## 已连接时先离开房间，再停大厅 BGM 切回标题（标题有自己的 BGM）。
func _add_back_button() -> void:
	var vbox: Control = _connect_vbox()
	if vbox == null:
		return
	var back_btn := Button.new()
	back_btn.name = "BackToTitleBtn"
	back_btn.text = "返回标题界面"
	back_btn.pressed.connect(_on_back_to_title_pressed)
	vbox.add_child(back_btn)


## 大厅（连接）界面的纵向容器。2026-09-27 拆成「大厅 / 房间」两界面后，路径从 `VBox`
## 变成 `ConnectPanel/VBox` —— 「返回标题」与 WIP 提示都只属于大厅界面，房间界面不放它们。
func _connect_vbox() -> Control:
	return get_node_or_null("ConnectPanel/VBox") as Control


func _on_back_to_title_pressed() -> void:
	if net and _connected:
		## 与「离开该大厅」同一套退出顺序：先销房，再断连接（方案 §4.6）。
		_delete_internet_room_if_host()
		net.leave()
		_connected = false
	Global.stop_lobby_music()
	## ★走统一入口（2026-10-02）：它会清会话状态（座位表 / checkpoint / 任务旗标）——
	## 直连 `change_scene_to_file(标题)` 会把上一局全留下 → 「重新开房后还是上一把的角色」。
	Global.go_to_title_screen()


## 联机提示（2026-09-14 用户要求挂在标题下方，黄字醒目）。
## 2026-09-29 用户改口径：原先写「暂未完成 —— 请以单人模式为准」太劝退，
## 改成「有问题请到交流群反馈」—— 联机已经是可用功能，需要的是反馈而不是劝退。
func _add_wip_notice() -> void:
	var vbox: Control = _connect_vbox()
	if vbox == null:
		return
	var notice := Label.new()
	notice.name = "WipNotice"
	notice.text = "※ 联机模式仍有 bug 在处理 —— 遇到问题请到交流群反馈，我们会尽快修。"
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
	# ★创建房间用**独立的本机监听端口**（2026-09-27 用户需求：建主端口与加入端口分开设置）。
	# 使用 frp 等端口映射型内网穿透时，这里填穿透隧道指向本机的本地 UDP 端口。
	var port := int(host_port_edit.value)
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
	## 重入保护：本函数开头有 `await`（等 DELETE 收尾），期间按钮仍可点 → 连点会
	## 广播两次 start_game。用一个标志把第二次点击挡在门外。
	if _starting:
		return
	if not net.are_all_players_character_selected():
		_log("不能开始：请等待所有玩家完成角色选择")
		_refresh_ui()
		return
	_starting = true
	## 开局前把互联网房从大厅**下架**（玩家已连上，发现层不再需要）。
	## ⚠ 必须等 DELETE 收尾再切图：切图会释放大厅场景 → LobbyClient 被销毁 →
	##   DELETE 发不出去 → 房间残留到服务端 60s 超时（2026-10-10 用户实测：
	##   「游戏都开始了，房间列表里还有之前的房间」）。
	## ⚠ 但下架**绝不停隧道** —— 隧道正承载着已连入的玩家，停掉等于当场断线。
	await _retire_internet_room_before_game()
	_log("全部角色已确认，广播开始游戏 ...")
	# B1 难度同步（D2 用例暴露）：开局广播必须携带难度 —— 原调用漏参（默认 -1 不覆盖），
	# 联机开局的 Client 难度从未被同步，只有中途切图（request_scene_change）才带上。
	## 起始关卡 = 房间里选的章节（2026-09-27 用户需求：主机可选战役/章节）；
	## 没选就回退到默认第一关。这样"不想从头测"可以直接从房间跳到目标关。
	net.start_game.rpc(_current_start_scene(), "", null, Global.selected_difficulty)


## 开局前向大厅下架房间（**保留隧道**），并等 DELETE 送达或超时。
## 与 `_delete_internet_room_if_host()` 的区别：这里不触碰隧道 —— 隧道要陪玩家进局。
func _retire_internet_room_before_game() -> void:
	if _internet_room_id.is_empty():
		return
	if _internet_panel != null and _internet_panel.has_method("delete_room"):
		_internet_panel.delete_room(_internet_room_id, _internet_host_token)
		_log("已在开局前下架房间 %s" % _internet_room_id)
	_internet_room_id = ""
	_internet_host_token = ""
	## 等 DELETE 收尾（最多 2s）。HTTP 通常几十~几百 ms；超时也放行，**绝不阻断开局**。
	if _internet_panel != null and _internet_panel.has_method("is_delete_pending"):
		var deadline := Time.get_ticks_msec() + 2000
		while Time.get_ticks_msec() < deadline and bool(_internet_panel.is_delete_pending()):
			await get_tree().create_timer(0.05).timeout


func _on_leave_pressed() -> void:
	## ── 退出顺序（方案 §4.6，不得颠倒）──
	## ① DELETE /api/rooms/:id（带 hostToken）—— 让房间**立即**从列表消失
	## ② Net.leave()（清 ENet、UPnP 反向删映射）
	## ③ 清本地 roomId / hostToken
	## ⚠ 顺序不能反：先 leave() 会让心跳停止但仍留一个 60s 才清的死房。
	## ⚠ ① 允许失败（网络断了就靠超时清理），**不得阻断** ②。
	_delete_internet_room_if_host()
	net.leave()
	_connected = false
	_log("已离开房间")
	_refresh_ui()


## 若本机是互联网房主，向大厅销掉房间并清本地凭据（方案 §4.6）。
func _delete_internet_room_if_host() -> void:
	if _internet_room_id.is_empty():
		## 即使没注册成功（如隧道还在连接中），也要停隧道
		if _tunnel_client != null and _tunnel_client.is_active():
			_tunnel_client.stop()
		return
	if _internet_panel != null and _internet_panel.has_method("delete_room"):
		_internet_panel.delete_room(_internet_room_id, _internet_host_token)
		_log("已通知大厅关闭房间 %s" % _internet_room_id)
	_internet_room_id = ""
	_internet_host_token = ""
	## 停止隧道（路线二：房主退出时自动释放）
	if _tunnel_client != null and _tunnel_client.is_active():
		_tunnel_client.stop()
		_log("隧道已释放")


func _on_character_selected(index: int) -> void:
	if _refreshing_character_select:
		return
	if not net or not net.handshake_ok:
		## ⚠ **不能静默返回**（2026-10-01 玩家反馈手机端「选完角色右边不变」）：
		## 下拉框会照常显示玩家点的这一项，但请求根本没发出去 → UI 与权威状态不一致，
		## 而且没有任何线索。这里既打印原因，也把下拉框**拉回权威值**（提示必须与真实可执行性同源）。
		print("[大廳] 角色选择被忽略：连接/握手未就绪 → 下拉框已拉回权威值")
		_refresh_ui()
		return
	var character_path := str(character_select.get_item_metadata(index))
	if character_path.is_empty():
		## 占位项（index 0，metadata 为空）或越界索引：同样不静默 —— 触摸点偏差在手机上是真实存在的，
		## 表现为"点了一下没反应"，玩家无法区分是没点到还是被忽略。
		print("[大廳] 角色选择无效：index=%d 没有角色路径（占位项/越界）→ 下拉框已拉回权威值" % index)
		_refresh_ui()
		return
	if not net.request_local_character_selection(character_path):
		_log("角色选择请求未发送，请先完成连接与握手")
		_refresh_ui()
	else:
		print("[大廳] 已发送角色选择请求：%s" % character_path.get_file())


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
		## 顺带预填互联网创建表单，省去房主手填穿透地址（方案 §2.3 A1 的自动化）。
		if _internet_panel != null and _internet_panel.has_method("prefill_tunnel_address"):
			_internet_panel.prefill_tunnel_address(external_ip, port)


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
	## 两界面切换 + 房间槽位 + 只读信息（2026-09-27：大厅 / 房间分离）
	_sync_panels()
	_refresh_room_info()
	_refresh_slots(names, peer_ids)


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
	## 房间界面也有一个日志栏（两个界面互斥，各自显示同一份日志）
	if room_log_label:
		room_log_label.text = "\n".join(_log_lines)
