extends Node
##
## 互联网大厅 HTTP 客户端（策划方案 §5.1）
##
## 职责：Master Server 的**全部** HTTP 交互 —— 房间列表 / 注册 / 心跳 / 删除 / 上报不可达。
## 不持有任何权威状态：房间列表是**只读投影**；roomId / hostToken 只是会话凭据。
##
## 【为什么用请求队列】Godot 的 `HTTPRequest` **同一个实例一次只能处理一个请求**
## （忙时 `request()` 返回 `ERR_BUSY`，不是自动排队）。若每次请求都 `new` 一个节点，
## 又会累积节点与连接。所以只创建一个 `HTTPRequest`，用队列**串行化** —— 由 `_pump()` 驱动。
##
## 【为什么不做 autoload】它只在大厅生命周期内需要，挂在场景上即可，避免给 `Net`
## 增加跨场景职责。若将来要在游戏内保活心跳，再评估升级为 autoload。
##
## 【HTTPS 硬要求】Android 9+ 默认禁止明文 HTTP（cleartext），`HTTPRequest` 会直接失败。
## 故只允许 `https://` 基址；**仅**开发用地址 `http://127.0.0.1` / `http://localhost` 例外。
## 移动端若配了自建 http 服务，大厅会整体不可用（方案 §5.1 的 C13）。
##
## 【它不做的事】不参与进入房间（那由 `Net.join_game` 直接连）。Master Server 只管"找房间"。

# ── 对外信号：UI 只关心这些，不直接读内部状态 ──

## 房间列表到达（只读投影，元素为 Dictionary）。
signal rooms_received(rooms: Array)
## 注册成功：返回房间投影与**仅此一次**的 hostToken。
signal room_registered(room: Dictionary, host_token: String)
## 心跳成功，`ttl` 为服务端给的超时秒数。
signal heartbeat_ok(ttl: int)
## 心跳失败。`reason == "not_found"` 时客户端应触发**注册自愈**（重新注册，方案 §4.7）。
signal heartbeat_failed(reason: String)
## 主动删除完成（房主正常退出）。
signal room_deleted()
## 通用业务失败（400/403 等），`operation` 标明是哪个动作，便于 UI 与日志定位。
signal request_failed(operation: String, reason: String)
## 大厅服务不可达（网络层失败或超时）。UI 应走方案 §4.4 的降级路径。
signal lobby_unreachable(reason: String)
## 冷启动阶梯推进，`stage ∈ [0,3]`，UI 据此显示渐进文案（方案 §4.4）。
signal waking_up(stage: int)
## 被限流（429）。UI 约定：**静默退避、不清列表**（方案 §3.6）。
signal rate_limited(retry_after_sec: int)

# ── 常量 ──

## 单次请求超时。设 75s：覆盖托管平台约 1 分钟的冷启动 + 网络余量（方案 §4.4）。
const TIMEOUT_SECONDS := 75.0
## 冷启动阶梯边界（秒）。stage = 落在哪个区间：<3 → 0，<15 → 1，<45 → 2，<75 → 3。
## 与方案 §4.4 的四条"仍在唤醒"文案一一对应；超时后由 lobby_unreachable 接管。
const WAKE_STAGE_BOUNDS: Array[float] = [3.0, 15.0, 45.0]
## 本地开发默认基址（M1 自带渲染/本机 node 服务）。
const DEFAULT_BASE_URL := "http://127.0.0.1:10000"

var base_url: String = ""

var _http: HTTPRequest
var _queue: Array[Dictionary] = []
var _in_flight := false
var _current: Dictionary = {}
var _elapsed := 0.0
var _last_stage := -1

func _ready() -> void:
	set_process(false)
	_http = HTTPRequest.new()
	_http.name = "LobbyHttp"
	## 不用线程：本客户端本身就在主线程串行排队，开线程只会引入时序不确定性。
	_http.use_threads = false
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)

## 配置基址。返回是否可用（URL 不合规时返回 false，调用方应降级到直连页签）。
func setup(url: String) -> bool:
	var candidate := url.strip_edges()
	if candidate.is_empty():
		candidate = DEFAULT_BASE_URL
	# 规范化：去掉尾部所有 '/'，避免拼出 '//api/rooms'。
	while candidate.ends_with("/"):
		candidate = candidate.substr(0, candidate.length() - 1)
	if not _is_url_allowed(candidate):
		printerr("[LobbyClient] 拒绝不安全的基址（须 https，或本地开发用 127.0.0.1/localhost）：%s" % candidate)
		return false
	base_url = candidate
	print("[LobbyClient] 基址 = %s" % base_url)
	return true

## 当前是否有未完成的请求（含排队中）。UI 可用它禁用按钮防连点。
func is_busy() -> bool:
	return _in_flight or not _queue.is_empty()

# ─────────────────────────── 对外动作 ───────────────────────────

## 拉取房间列表。`protocol` 必须带上 —— 服务端按它**等值过滤**（协议分桶，方案 §3.3）。
func fetch_rooms(protocol: String, game_version: String = "") -> void:
	var query := "?protocol=%s" % protocol.uri_encode()
	if not game_version.is_empty():
		query += "&game=%s" % game_version.uri_encode()
	_enqueue("fetch_rooms", HTTPClient.METHOD_GET, "/api/rooms" + query, {})

## 注册房间。`payload` 至少含 protocol；服务端会补默认值并做校验。
func register_room(payload: Dictionary) -> void:
	_enqueue("register_room", HTTPClient.METHOD_POST, "/api/rooms", payload)

## 心跳保活。`current_players` < 0 表示不改人数。
func heartbeat(room_id: String, host_token: String, current_players: int = -1) -> void:
	var body := {"hostToken": host_token}
	if current_players >= 0:
		body["currentPlayers"] = current_players
	_enqueue("heartbeat", HTTPClient.METHOD_POST, "/api/rooms/%s/heartbeat" % room_id, body)

## 主动关闭房间（房主正常退出）。**退出顺序**：先 DELETE 再 Net.leave()（方案 §4.6）。
func delete_room(room_id: String, host_token: String) -> void:
	_enqueue("delete_room", HTTPClient.METHOD_DELETE, "/api/rooms/%s" % room_id,
		{"hostToken": host_token})

## 上报"此房连不上"（可选，M2 才用于降权）。
func report_unreachable(room_id: String) -> void:
	_enqueue("report_unreachable", HTTPClient.METHOD_POST,
		"/api/rooms/%s/report_unreachable" % room_id, {})

# ─────────────────────────── 队列驱动 ───────────────────────────

func _enqueue(operation: String, method: int, path: String, body: Dictionary) -> void:
	if base_url.is_empty():
		request_failed.emit(operation, "not_configured")
		return
	_queue.append({
		"operation": operation,
		"method": method,
		"path": path,
		"body": body,
	})
	_pump()

## 出队并发出**一条**请求。HTTPRequest 忙时绝不再发（它的 request() 不是排队的）。
func _pump() -> void:
	if _in_flight or _queue.is_empty() or base_url.is_empty():
		return
	var op: Dictionary = _queue.pop_front()
	var headers := PackedStringArray(["Content-Type: application/json"])
	## ⚠ Godot 4.6 的 `HTTPRequest.request()` 第 4 参是 **String**（请求体文本），
	## 不是 PackedByteArray —— 传字节数组会以 "Invalid argument" 解析失败。
	var body_text := ""
	var body: Dictionary = op.get("body", {})
	if not body.is_empty():
		body_text = JSON.stringify(body)

	var err: int = _http.request(base_url + str(op["path"]), headers,
		int(op["method"]), body_text)
	if err != OK:
		# 连发都发不出去（URL 非法 / 通道异常）：算这一条失败，继续下一条，不卡队列。
		printerr("[LobbyClient] 请求发出失败 op=%s err=%s" % [op["operation"], error_string(err)])
		request_failed.emit(str(op["operation"]), "request_error_%d" % err)
		_pump()
		return

	_in_flight = true
	_current = op
	_elapsed = 0.0
	_last_stage = -1
	set_process(true)

func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	# 已被超时取消的请求：_current 已清空，直接忽略（避免重复发信号）。
	if _current.is_empty():
		return
	var op := _current
	_current = {}
	_in_flight = false
	set_process(false)

	var operation := str(op["operation"])
	var text := body.get_string_from_utf8()

	# 网络层失败（连不上 / TLS 失败 / 被中断）→ 走"大厅不可达"降级路径。
	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("lobby_unreachable", "network_%d" % result)
		_pump()
		return

	# 429：限流。单独信号，UI 静默退避且**不清列表**。
	if response_code == 429:
		rate_limited.emit(_retry_after_seconds(text))
		_pump()
		return

	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	var dict: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	match operation:
		"fetch_rooms":
			if response_code == 200:
				var rooms: Variant = dict.get("rooms", [])
				rooms_received.emit(rooms if typeof(rooms) == TYPE_ARRAY else [])
			else:
				request_failed.emit(operation, _error_of(dict, response_code))
		"register_room":
			if response_code == 201:
				var room: Variant = dict.get("room", {})
				var token := str(dict.get("hostToken", ""))
				if typeof(room) == TYPE_DICTIONARY and not token.is_empty():
					room_registered.emit(room, token)
				else:
					request_failed.emit(operation, "malformed_response")
			else:
				request_failed.emit(operation, _error_of(dict, response_code))
		"heartbeat":
			if response_code == 200:
				heartbeat_ok.emit(int(dict.get("ttl", 0)))
			else:
				# 404 → 触发注册自愈；403 → 凭据错误（重注册也拿不回来）。
				heartbeat_failed.emit(_error_of(dict, response_code))
		"delete_room":
			if response_code == 200:
				room_deleted.emit()
			else:
				request_failed.emit(operation, _error_of(dict, response_code))
		"report_unreachable":
			# 上报失败无需打扰用户（它只是统计）。
			pass
		_:
			request_failed.emit(operation, "unknown_operation")

	_pump()

## 冷启动阶梯 + 超时。只在有请求在飞时运行（_pump 里 set_process(true)）。
func _process(delta: float) -> void:
	if not _in_flight:
		return
	_elapsed += delta
	var stage := _stage_for(_elapsed)
	if stage != _last_stage:
		_last_stage = stage
		waking_up.emit(stage)
	if _elapsed >= TIMEOUT_SECONDS:
		_timeout_current()

func _timeout_current() -> void:
	set_process(false)
	_http.cancel_request()
	var op := _current
	_current = {}
	_in_flight = false
	printerr("[LobbyClient] 请求超时（%.0fs）op=%s" % [TIMEOUT_SECONDS, op.get("operation", "?")])
	lobby_unreachable.emit("timeout")
	_pump()

## 落在哪个阶梯区间。返回 0..WAKE_STAGE_BOUNDS.size()。
func _stage_for(seconds: float) -> int:
	for i: int in range(WAKE_STAGE_BOUNDS.size()):
		if seconds < WAKE_STAGE_BOUNDS[i]:
			return i
	return WAKE_STAGE_BOUNDS.size()

# ─────────────────────────── 工具 ───────────────────────────

## 只放行 https，以及本地开发用的 127.0.0.1 / localhost（方案 §5.1 的 C13）。
func _is_url_allowed(url: String) -> bool:
	if url.begins_with("https://"):
		return true
	if url.begins_with("http://127.0.0.1"):
		return true
	if url.begins_with("http://localhost"):
		return true
	return false

func _error_of(dict: Dictionary, response_code: int) -> String:
	var err := str(dict.get("error", ""))
	if not err.is_empty():
		return err
	var reason := str(dict.get("reason", ""))
	if not reason.is_empty():
		return reason
	return "http_%d" % response_code

func _retry_after_seconds(text: String) -> int:
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if typeof(parsed) == TYPE_DICTIONARY:
		return int((parsed as Dictionary).get("retryAfterSec", 0))
	return 0
