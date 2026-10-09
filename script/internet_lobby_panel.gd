extends Control
##
## 互联网大厅面板（策划方案 §5.2 / §5.3）
##
## 职责：纯表现层。消费 `Net`（联机）与 `LobbyClient`（房间目录）的信号，刷新界面；
## 不持有权威状态、不直接发 HTTP。
##
## 【三种视图，同面板内切换】
##   list    —— 在线房间列表（自动刷新 + 手动刷新 + 创建入口）
##   create  —— 创建互联网房间表单（含可达性自检三步）
##   load    —— 加载 / 冷启动阶梯（方案 §4.4 的四段文案）
##
## 【为什么代码构建】与 `network_lobby._setup_room_panel()` / `_add_back_button()` 同风格：
## 避免编辑器重存 .tscn 时丢属性；也让字号/字体统一覆盖能自动跟随（见 _apply_fonts）。
##
## 【UI 铁律】字体只走 Global.get_ui_font()/apply_ui_font()，禁止硬编码 .ttf；
## 字号只用 12 的整倍（正文 24 / 窗内标题 36）。

## 请求加入某房间（由大厅脚本接走，调用 Net.join_game）。
signal join_requested(address: String, port: int, room_name: String)
## 请求创建并注册一个互联网房间。
## `tunnel_address` / `tunnel_port`：外网能连到的穿透地址与端口（方案 §2.3 A1）。
signal create_requested(room_name: String, tunnel_address: String, tunnel_port: int)
## 注册成功：把房间投影与 hostToken 交给大厅脚本（它负责与 Net 会话绑定 + 心跳）。
signal room_registered_external(room: Dictionary, host_token: String)
## 请求关闭（返回直连页签）。
signal closed()

const CLIENT_SCRIPT := "res://script/lobby_client.gd"

## 列表自动刷新间隔（方案 §5.3：8s）。
const REFRESH_INTERVAL := 8.0
## 触摸友好的行高下限（列表项可点高度 ≥ 触摸控件同级规格）。
const ROW_MIN_HEIGHT := 56.0

const COLOR_TITLE := Color("e8c44b")
const COLOR_HINT := Color(0.78, 0.84, 0.9)
const COLOR_ERROR := Color(1.0, 0.45, 0.4)
const COLOR_OK := Color(0.55, 0.92, 0.6)
const COLOR_WARN := Color(1.0, 0.85, 0.3)

# ── 子视图 ──
var _views: Dictionary = {}          ## "list"/"create"/"load" -> Control
var _current_view := ""

# ── list 视图控件 ──
var _room_list: VBoxContainer
var _list_status: Label
var _refresh_btn: Button
var _create_btn: Button
var _last_update_label: Label

# ── create 视图控件 ──
var _room_name_edit: LineEdit
## 穿透地址 / 穿透端口（方案 §2.3 A1）：
## 房主跑起穿透客户端后，把"外网能连到的那个地址与端口"填进来 —— 大厅靠它找到房间。
var _tunnel_addr_edit: LineEdit
var _tunnel_port_edit: SpinBox
var _self_check_labels: Array[Label] = []
var _create_status: Label
var _confirm_create_btn: Button

# ── load 视图控件 ──
var _load_label: Label
var _load_retry_btn: Button
var _load_fallback_btn: Button

# ── 运行时 ──
var _client: Node = null
var _refresh_accum := 0.0
var _game_version := ""
var _last_rooms: Array = []


func _ready() -> void:
	_build_ui()
	_setup_client()
	set_process(true)
	show_list()
	_apply_fonts()


# ─────────────────────────── 对外入口 ───────────────────────────

## 切到列表视图并立即刷新一次。
func show_list() -> void:
	_switch_view("list")
	_refresh_now()

## 切到创建视图（从列表点「创建房间」进入）。
func show_create() -> void:
	_switch_view("create")
	if _room_name_edit != null:
		var default_name: String = Global.last_room_name if not Global.last_room_name.is_empty() else "%s 的房间" % str(Net.player_name)
		_room_name_edit.text = default_name
	_update_self_check()

## 由大厅脚本在注册成功后回调，切回列表。
func on_room_registered() -> void:
	_set_status(_create_status, "已创建，正在进入房间…", COLOR_OK)

## 由大厅脚本在外层失败时回调（例如 Net.host_game 失败）。
func on_create_failed(reason: String) -> void:
	_set_status(_create_status, "创建失败：%s" % reason, COLOR_ERROR)

## 转发：注册房间（大厅脚本构造 payload —— 它才知道 Net 的真实端口）。
func register_room(payload: Dictionary) -> void:
	if _client == null:
		_set_status(_create_status, "内部错误：大厅客户端未就绪", COLOR_ERROR)
		return
	_client.register_room(payload)

## 转发：心跳保活（房主侧每 10s 一次）。
func heartbeat(room_id: String, host_token: String, current_players: int = -1) -> void:
	if _client == null:
		return
	_client.heartbeat(room_id, host_token, current_players)

## 转发：主动关闭房间（房主正常退出时调用，方案 §4.6 退出顺序第①步）。
func delete_room(room_id: String, host_token: String) -> void:
	if _client == null:
		return
	_client.delete_room(room_id, host_token)

## 当前是否配置好了大厅地址（未配置时创建/列表都应提示）。
func is_ready() -> bool:
	return _client != null

# ─────────────────────────── 客户端接线 ───────────────────────────

func _setup_client() -> void:
	var script: GDScript = load(CLIENT_SCRIPT) as GDScript
	if script == null:
		_set_status(_list_status, "内部错误：找不到 lobby_client.gd", COLOR_ERROR)
		return
	_client = script.new() as Node
	_client.name = "LobbyClient"
	add_child(_client)
	var url := Global.master_server_url
	if not _client.setup(url):
		_set_status(_list_status, "大厅地址不安全或无效：%s" % url, COLOR_ERROR)
		return
	## 移动端 + 明文 http：Android 9+ 会直接拒绝，提前说清楚而不是让玩家看到"连不上"。
	if not _client.is_mobile_safe():
		_set_status(_list_status,
			"当前大厅地址是明文 HTTP，安卓端无法连接；请等大厅启用 HTTPS 域名后再用手机联机。",
			COLOR_WARN)
	_client.rooms_received.connect(_on_rooms_received)
	_client.room_registered.connect(_on_room_registered)
	_client.request_failed.connect(_on_request_failed)
	_client.lobby_unreachable.connect(_on_lobby_unreachable)
	_client.waking_up.connect(_on_waking_up)
	_client.rate_limited.connect(_on_rate_limited)


func _process(delta: float) -> void:
	if _client == null or _current_view != "list":
		return
	_refresh_accum += delta
	if _refresh_accum >= REFRESH_INTERVAL:
		_refresh_accum = 0.0
		if not _client.is_busy():
			_refresh_now()


func _refresh_now() -> void:
	if _client == null:
		return
	if _client.is_busy():
		return
	_refresh_accum = 0.0
	_client.fetch_rooms(Net.PROTOCOL_VERSION, _game_version)


# ─────────────────────────── 信号处理 ───────────────────────────

func _on_rooms_received(rooms: Array) -> void:
	_hide_load_view()
	_last_rooms = rooms
	_render_rooms(rooms)
	_last_update_label.text = "上次更新：刚刚"
	_set_status(_list_status, "", COLOR_HINT)


func _on_room_registered(room: Dictionary, host_token: String) -> void:
	## 真正把房间挂到 Net 会话上由**大厅脚本**做（它才知道 Net 的 host_game 端口）。
	_set_status(_create_status, "已创建，正在进入房间…", COLOR_OK)
	set_meta("pending_room_id", str(room.get("id", "")))
	set_meta("pending_host_token", host_token)
	room_registered_external.emit(room, host_token)


func _on_request_failed(operation: String, reason: String) -> void:
	if operation == "fetch_rooms":
		_set_status(_list_status, "刷新失败：%s" % _friendly(reason), COLOR_ERROR)
	elif operation == "register_room":
		_set_status(_create_status, "创建失败：%s" % _friendly(reason), COLOR_ERROR)
	elif operation == "delete_room":
		## 删除失败只记日志，不打断退出（方案 §4.6：允许失败）。
		print("[InternetPanel] 房间删除失败：%s" % reason)


func _on_lobby_unreachable(reason: String) -> void:
	if _current_view == "list":
		_show_load_view(reason)


func _on_waking_up(stage: int) -> void:
	if _current_view == "list":
		_show_load_view("")
	_update_load_stage(stage)


func _on_rate_limited(retry_after_sec: int) -> void:
	## 约定：静默退避、**不清列表**（方案 §3.6）。
	_set_status(_list_status, "请求过于频繁，%d 秒后自动重试" % retry_after_sec, COLOR_WARN)


func _friendly(reason: String) -> String:
	match reason:
		"not_configured":
			return "未配置大厅地址"
		"malformed_response":
			return "大厅返回数据异常"
		"not_found":
			return "房间已不存在"
		"bad_token":
			return "房间凭据无效"
		"invalid_payload":
			return "参数被大厅拒绝"
		"timeout":
			return "连接超时"
	if reason.begins_with("network_"):
		return "网络不通"
	if reason.begins_with("http_"):
		return "大厅错误（%s）" % reason.trim_prefix("http_")
	return reason


# ─────────────────────────── 列表渲染 ───────────────────────────

func _render_rooms(rooms: Array) -> void:
	for child: Node in _room_list.get_children():
		child.queue_free()
	if rooms.is_empty():
		var empty := Label.new()
		empty.text = "现在没有房间。创建一个，或稍后点[刷新]。"
		empty.add_theme_color_override("font_color", COLOR_HINT)
		_empty_style(empty)
		_room_list.add_child(empty)
		return
	for room_value: Variant in rooms:
		if typeof(room_value) != TYPE_DICTIONARY:
			continue   ## 脏数据不得让界面崩
		_room_list.add_child(_build_room_row(room_value as Dictionary))


func _build_room_row(room: Dictionary) -> Control:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_HEIGHT)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	row.add_child(box)

	var info := Label.new()
	var cur: int = int(room.get("currentPlayers", 0))
	var max_p: int = int(room.get("maxPlayers", 4))
	var diff_names: Array[String] = ["简单", "中等", "困难", "专家"]
	var diff: int = clampi(int(room.get("difficulty", 0)), 0, diff_names.size() - 1)
	var chapter: String = str(room.get("chapterLabel", ""))
	info.text = "%s    %d/%d    %s%s" % [
		str(room.get("name", "?")), cur, max_p, diff_names[diff],
		("    " + chapter) if not chapter.is_empty() else "",
	]
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.clip_text = true
	_empty_style(info)
	box.add_child(info)

	## 按用户选择：每行右侧独立「加入」按钮。
	var join_btn := Button.new()
	join_btn.text = "加入"
	var full: bool = cur >= max_p
	join_btn.disabled = full
	if full:
		join_btn.tooltip_text = "房间已满"
	var captured := room
	join_btn.pressed.connect(func() -> void: _on_join_row(captured))
	box.add_child(join_btn)
	return row


func _on_join_row(room: Dictionary) -> void:
	var address: String = str(room.get("address", ""))
	var port: int = int(room.get("port", 27015))
	if address.is_empty() or port <= 0:
		_set_status(_list_status, "该房间信息不完整，无法加入", COLOR_ERROR)
		return
	if _client != null:
		_client.report_unreachable(str(room.get("id", "")))
	join_requested.emit(address, port, str(room.get("name", "")))


# ─────────────────────────── 创建视图 ───────────────────────────

func _update_self_check() -> void:
	## 三步自检（方案 §4.5）：这里只做**展示**，真实门槛由 lobby 侧在创建前填。
	##   ① 本机端口监听 —— 由 Net.host_game() 结果决定，此处先给中性文案
	##   ② 路由器端口映射 / UPnP —— 由 Net.upnp_port_mapped / upnp_mapping_failed 决定
	##   ③ 穿透隧道连通 —— M1 靠玩家自行确认（方案 §4.5 步骤 3 列 M2 才自动化）
	if _self_check_labels.size() < 3:
		return
	var upnp_ok: bool = int(Net.get("_upnp_mapped_port")) > 0
	_self_check_labels[0].text = "① 本机端口监听      ⏳ 创建时检测"
	_self_check_labels[1].text = "② 路由器端口映射    %s" % ("✔ UPnP 已映射" if upnp_ok else "⏳ 创建时尝试")
	_self_check_labels[2].text = "③ 穿透隧道连通      ⏳ 请确认穿透客户端日志显示 connected"


func _on_confirm_create() -> void:
	var room_name := ""
	if _room_name_edit != null:
		room_name = _room_name_edit.text.strip_edges()
	if room_name.is_empty():
		_set_status(_create_status, "请先填写房间名称", COLOR_ERROR)
		return
	## 穿透地址是**必填**：大厅必须知道外网往哪连，否则房主在列表里是个连不上的死房
	## （方案 §4.5 的意图）。UPnP 成功时这里会被自动预填。
	var tunnel_addr := ""
	if _tunnel_addr_edit != null:
		tunnel_addr = _tunnel_addr_edit.text.strip_edges()
	if tunnel_addr.is_empty():
		_set_status(_create_status,
			"请填写「穿透地址」—— 外网能连到你这台机器的地址（跑完穿透客户端后它会给出）",
			COLOR_ERROR)
		return
	var tunnel_port := 27015
	if _tunnel_port_edit != null:
		tunnel_port = int(_tunnel_port_edit.value)

	Global.last_room_name = room_name
	_create_status.text = ""
	create_requested.emit(room_name, tunnel_addr, tunnel_port)


## UPnP 成功拿到外部地址时，由大厅脚本调它预填（省去房主手填）。
func prefill_tunnel_address(address: String, port: int) -> void:
	if _tunnel_addr_edit != null and _tunnel_addr_edit.text.strip_edges().is_empty():
		_tunnel_addr_edit.text = address
	if _tunnel_port_edit != null and port > 0:
		_tunnel_port_edit.value = float(port)


# ─────────────────────────── 加载 / 冷启动阶梯 ───────────────────────────

func _show_load_view(reason: String) -> void:
	if _current_view == "load":
		return
	_switch_view("load")
	if reason.is_empty():
		_load_label.text = "正在连接服务器大厅…"
	else:
		_load_label.text = "无法连接大厅服务"
	_load_retry_btn.visible = not reason.is_empty()
	_load_fallback_btn.visible = not reason.is_empty()
	_update_load_stage(0)


## 方案 §4.4 的四段文案（stage 0..3）。
func _update_load_stage(stage: int) -> void:
	if _load_label == null:
		return
	var texts: Array[String] = [
		"正在连接服务器大厅…",
		"正在唤醒大厅服务（免费服务首次访问较慢，请稍候）…",
		"仍在唤醒中，最长可能需要 1 分钟…",
		"网络似乎不通畅，请检查网络后重试",
	]
	if stage >= 0 and stage < texts.size():
		_load_label.text = texts[stage]
		## 前三档只提示"仍在唤醒"，第 4 档起才给可操作按钮（方案 §4.4 阶梯）。
		var actionable: bool = stage >= 3
		_load_retry_btn.visible = actionable
		_load_fallback_btn.visible = actionable


## 超时后大厅脚本也会调它；收到 rooms_received 时自动隐藏。
func _hide_load_view() -> void:
	if _current_view == "load":
		_switch_view("list")


# ─────────────────────────── UI 构建 ───────────────────────────

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_views["list"] = _build_list_view()
	_views["create"] = _build_create_view()
	_views["load"] = _build_load_view()
	for key: String in _views.keys():
		var v: Control = _views[key]
		v.visible = false
		add_child(v)


func _build_list_view() -> Control:
	var root := VBoxContainer.new()
	root.name = "ListView"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12.0
	root.offset_top = 12.0
	root.offset_right = -12.0
	root.offset_bottom = -12.0
	root.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "在线房间"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	_room_list = VBoxContainer.new()
	_room_list.name = "RoomList"
	_room_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_room_list)

	_last_update_label = Label.new()
	_last_update_label.text = "上次更新：—"
	_last_update_label.add_theme_color_override("font_color", COLOR_HINT)
	root.add_child(_last_update_label)

	_list_status = Label.new()
	_list_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_list_status)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	root.add_child(btn_row)

	_refresh_btn = Button.new()
	_refresh_btn.text = "刷新"
	_refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	btn_row.add_child(_refresh_btn)

	_create_btn = Button.new()
	_create_btn.text = "创建房间"
	_create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_create_btn.pressed.connect(show_create)
	btn_row.add_child(_create_btn)
	return root


func _build_create_view() -> Control:
	var root := VBoxContainer.new()
	root.name = "CreateView"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12.0
	root.offset_top = 12.0
	root.offset_right = -12.0
	root.offset_bottom = -12.0
	root.add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "创建互联网房间"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	root.add_child(title)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	root.add_child(name_row)
	var name_tag := Label.new()
	name_tag.text = "房间名称"
	name_row.add_child(name_tag)
	_room_name_edit = LineEdit.new()
	_room_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_name_edit.max_length = 32
	name_row.add_child(_room_name_edit)

	var limit_row := HBoxContainer.new()
	limit_row.add_theme_constant_override("separation", 8)
	root.add_child(limit_row)
	var limit_tag := Label.new()
	limit_tag.text = "人数上限    4（固定）"
	limit_row.add_child(limit_tag)

	## 穿透地址 / 端口（方案 §2.3 A1）：外网能连到的地址。
	## 跑完穿透客户端后（playit.gg / 自建 frps），它会给出这样一对值。
	var tunnel_row := HBoxContainer.new()
	tunnel_row.add_theme_constant_override("separation", 8)
	root.add_child(tunnel_row)
	var tunnel_tag := Label.new()
	tunnel_tag.text = "穿透地址"
	tunnel_row.add_child(tunnel_tag)
	_tunnel_addr_edit = LineEdit.new()
	_tunnel_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tunnel_addr_edit.max_length = 253
	_tunnel_addr_edit.placeholder_text = "如 8.138.99.96 或 xxx.playit.gg"
	tunnel_row.add_child(_tunnel_addr_edit)

	var tunnel_port_row := HBoxContainer.new()
	tunnel_port_row.add_theme_constant_override("separation", 8)
	root.add_child(tunnel_port_row)
	var tunnel_port_tag := Label.new()
	tunnel_port_tag.text = "穿透端口"
	tunnel_port_row.add_child(tunnel_port_tag)
	_tunnel_port_edit = SpinBox.new()
	_tunnel_port_edit.min_value = 1.0
	_tunnel_port_edit.max_value = 65535.0
	_tunnel_port_edit.value = 27015.0
	tunnel_port_row.add_child(_tunnel_port_edit)
	var tunnel_port_hint := Label.new()
	tunnel_port_hint.text = "穿透客户端分配的公网端口（可能与本机端口不同）"
	tunnel_port_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tunnel_port_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tunnel_port_hint.add_theme_color_override("font_color", COLOR_HINT)
	tunnel_port_row.add_child(tunnel_port_hint)

	var conn_title := Label.new()
	conn_title.text = "── 连通性 ──"
	conn_title.add_theme_color_override("font_color", COLOR_HINT)
	root.add_child(conn_title)

	_self_check_labels.clear()
	for i: int in range(3):
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		root.add_child(l)
		_self_check_labels.append(l)

	_create_status = Label.new()
	_create_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_create_status)

	var hint := Label.new()
	hint.text = "提示：房间会被注册到大厅，好友即可在列表里看到并一键加入。"
	hint.add_theme_color_override("font_color", COLOR_HINT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	root.add_child(btn_row)
	var cancel := Button.new()
	cancel.text = "返回列表"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(show_list)
	btn_row.add_child(cancel)
	_confirm_create_btn = Button.new()
	_confirm_create_btn.text = "创建房间"
	_confirm_create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_create_btn.pressed.connect(_on_confirm_create)
	btn_row.add_child(_confirm_create_btn)
	return root


func _build_load_view() -> Control:
	var root := VBoxContainer.new()
	root.name = "LoadView"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12.0
	root.offset_top = 12.0
	root.offset_right = -12.0
	root.offset_bottom = -12.0
	root.add_theme_constant_override("separation", 12)

	_load_label = Label.new()
	_load_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_load_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	root.add_child(btn_row)
	_load_retry_btn = Button.new()
	_load_retry_btn.text = "重试"
	_load_retry_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_retry_btn.visible = false
	_load_retry_btn.pressed.connect(_on_refresh_pressed)
	btn_row.add_child(_load_retry_btn)
	_load_fallback_btn = Button.new()
	_load_fallback_btn.text = "改用直连 IP"
	_load_fallback_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_load_fallback_btn.visible = false
	_load_fallback_btn.pressed.connect(func() -> void: closed.emit())
	btn_row.add_child(_load_fallback_btn)
	return root


func _on_refresh_pressed() -> void:
	_switch_view("list")
	_refresh_now()


func _switch_view(name: String) -> void:
	_current_view = name
	for key: String in _views.keys():
		var v: Control = _views[key]
		v.visible = (key == name)


func _set_status(label: Label, text: String, color: Color) -> void:
	if label == null:
		return
	label.text = text
	label.add_theme_color_override("font_color", color)


func _empty_style(label: Label) -> void:
	Global.apply_ui_font(label, 24)
	Global.apply_text_shadow(label)


## 字号与字体统一（正文 24 / 标题 36，均为 12 的整倍）。
func _apply_fonts() -> void:
	for node: Node in find_children("*", "Control", true, false):
		if node is Label:
			var l := node as Label
			var is_title: bool = l.name == "Title" or l.text in ["在线房间", "创建互联网房间"]
			Global.apply_ui_font(l, 36 if is_title else 24)
			if not is_title:
				Global.apply_text_shadow(l)
		elif node is BaseButton:
			(node as BaseButton).add_theme_font_size_override("font_size", 24)
		elif node is LineEdit:
			(node as LineEdit).add_theme_font_size_override("font_size", 24)
