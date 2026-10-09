extends Node
##
## lobby_client.gd 回归 —— headless。
##
## 【为什么存在】`lobby_client` 有两块**容易悄悄写错、又无法靠肉眼发现**的逻辑：
##   1. 冷启动阶梯状态机（纯函数，但边界极易差一）；
##   2. 响应解析的**脏数据健壮性** —— 服务端返回非 JSON / 缺字段时，客户端必须
##      "不崩、发正确信号"，而不是抛异常或静默卡死（方案 §8.2 明确列为用例）。
## 另有联网集成段：给 `--lobby-url` 时会对着**真实 Master Server** 跑全流程。
##
## 用法：
##   # 只跑离线用例
##   "<godot>" --headless --path <proj> res://tools/lobby_client_test.tscn
##   # 连真实服务跑集成用例（需先 npm start 起 master-server）
##   "<godot>" --headless --path <proj> res://tools/lobby_client_test.tscn -- --lobby-url=http://127.0.0.1:10000
##
## 判定：末尾打印 AUTO_LOBBY_CLIENT_COMPLETE（全过）或 AUTO_LOBBY_CLIENT_FAILED（含原因）。

const TEST_PROTOCOL := "l3d_main_v2_combat_rpc"
const LIVE_TIMEOUT := 20.0

var _failures: Array[String] = []
var _checks := 0

func _ready() -> void:
	await get_tree().process_frame

	await _test_stage_machine()
	await _test_url_allowlist()
	await _test_dirty_response()

	var live_url := _get_arg("--lobby-url=")
	if not live_url.is_empty():
		await _test_live_roundtrip(live_url)
	else:
		print("[LOBBY_TEST] 未提供 --lobby-url，跳过联网集成用例")

	if _failures.is_empty() and _checks > 0:
		print("[LOBBY_TEST] AUTO_LOBBY_CLIENT_COMPLETE checks=%d" % _checks)
		get_tree().quit(0)
	else:
		# ⚠ 断言数为 0 也必须判失败：那意味着脚本根本没跑起来（例如目标脚本解析失败），
		# 而不是"没有问题"。
		if _checks == 0:
			_failures.append("断言数为 0：用例未真正执行（脚本加载失败？）")
		for f: String in _failures:
			printerr("[LOBBY_TEST] 失败：%s" % f)
		printerr("[LOBBY_TEST] AUTO_LOBBY_CLIENT_FAILED checks=%d fail=%d" % [_checks, _failures.size()])
		get_tree().quit(1)

# ─────────────────────────── 离线：阶梯状态机 ───────────────────────────

func _test_stage_machine() -> void:
	var c := _make_client()
	if c == null:
		return
	# 边界取自 WAKE_STAGE_BOUNDS = [3, 15, 45]，共 4 档（0..3）。
	var cases: Array = [
		[0.0, 0, "<3s 正在连接"],
		[2.99, 0, "刚好未到 3s"],
		[3.0, 1, "恰好 3s 进入第 2 档（左闭右开）"],
		[14.99, 1, "未到 15s"],
		[15.0, 2, "恰好 15s"],
		[44.99, 2, "未到 45s"],
		[45.0, 3, "恰好 45s"],
		[74.99, 3, "接近超时仍在第 4 档"],
	]
	for case: Array in cases:
		var secs: float = case[0]
		var want: int = case[1]
		var note: String = case[2]
		var got: int = c._stage_for(secs)
		_expect(got == want, "阶梯 %.2fs 应为第 %d 档，实得 %d（%s）" % [secs, want, got, note])
	c.queue_free()

# ─────────────────────────── 离线：URL 白名单 ───────────────────────────

func _test_url_allowlist() -> void:
	var c := _make_client()
	if c == null:
		return
	var allowed: Array[String] = [
		"https://lobby.example.com",
		"https://a.b.c:8443/x",
		"http://127.0.0.1:10000",
		"http://localhost:10000",
	]
	var denied: Array[String] = [
		"http://lobby.example.com",       # 明文 HTTP 到公网 —— Android 9+ 会直接失败
		"http://192.168.1.10:10000",      # 私网 http
		"ftp://lobby.example.com",
		"lobby.example.com",              # 无协议
		"",
	]
	for url: String in allowed:
		_expect(c._is_url_allowed(url), "应放行 %s" % url)
	for url: String in denied:
		_expect(not c._is_url_allowed(url), "应拒绝 %s" % url)

	# setup() 要能因不安全基址而失败，以便调用方降级到直连页签。
	_expect(not c.setup("http://lobby.example.com"), "setup 应拒绝明文公网基址")
	_expect(c.setup("http://127.0.0.1:10000"), "setup 应接受本地开发基址")
	_expect(c.base_url == "http://127.0.0.1:10000", "base_url 应记录规范化结果，实得 %s" % c.base_url)
	# 尾斜杠必须被剥掉，否则会拼出 '//api/rooms'。
	_expect(c.setup("https://lobby.example.com/"), "setup 应接受尾斜杠")
	_expect(c.base_url == "https://lobby.example.com", "尾斜杠应被剥掉，实得 %s" % c.base_url)
	c.queue_free()

# ─────────────────────────── 离线：脏数据健壮性 ───────────────────────────

func _test_dirty_response() -> void:
	var c := _make_client()
	if c == null:
		return

	# 1) 空 body + 200 → 不得崩；fetch_rooms 应发 rooms_received([])。
	var got_rooms := {}
	c.rooms_received.connect(func(rooms: Array) -> void: got_rooms["v"] = rooms)
	c._current = {"operation": "fetch_rooms"}
	c._on_request_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray())
	_expect(got_rooms.has("v") and (got_rooms["v"] as Array).is_empty(), "空 body 应产出空列表且不崩")

	# 2) 非 JSON（HTML 错误页）+ 500 → 应发 request_failed，不得崩。
	var got_err := {}
	c.request_failed.connect(func(op: String, reason: String) -> void:
		got_err["op"] = op
		got_err["reason"] = reason)
	c._current = {"operation": "fetch_rooms"}
	c._on_request_completed(HTTPRequest.RESULT_SUCCESS, 500, PackedStringArray(),
		"<html>502 Bad Gateway</html>".to_utf8_buffer())
	_expect(got_err.get("op", "") == "fetch_rooms", "非 JSON 500 应发 request_failed(fetch_rooms)")

	# 3) 201 但缺 hostToken → 应判为 malformed_response，不得把空 token 当成成功。
	var got_reg := {}
	c.request_failed.connect(func(op: String, reason: String) -> void:
		if op == "register_room":
			got_reg["reason"] = reason)
	c._current = {"operation": "register_room"}
	c._on_request_completed(HTTPRequest.RESULT_SUCCESS, 201, PackedStringArray(),
		JSON.stringify({"success": true, "room": {"id": "ABC123"}}).to_utf8_buffer())
	_expect(got_reg.get("reason", "") == "malformed_response",
		"缺 hostToken 应判 malformed_response，实得 %s" % got_reg.get("reason", "<none>"))

	# 4) 心跳 404 → heartbeat_failed("not_found")，供上层触发注册自愈。
	var got_hb := {}
	c.heartbeat_failed.connect(func(reason: String) -> void: got_hb["reason"] = reason)
	c._current = {"operation": "heartbeat"}
	c._on_request_completed(HTTPRequest.RESULT_SUCCESS, 404, PackedStringArray(),
		JSON.stringify({"success": false, "error": "not_found"}).to_utf8_buffer())
	_expect(got_hb.get("reason", "") == "not_found", "404 心跳应发 heartbeat_failed(not_found)")

	# 5) 网络层失败 → lobby_unreachable（UI 走降级路径）。
	var got_unreachable := {}
	c.lobby_unreachable.connect(func(reason: String) -> void: got_unreachable["reason"] = reason)
	c._current = {"operation": "fetch_rooms"}
	c._on_request_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())
	_expect(not got_unreachable.is_empty(), "网络失败应发 lobby_unreachable")

	# 6) 429 → rate_limited，且带上 retryAfterSec。
	var got_429 := {}
	c.rate_limited.connect(func(retry_after: int) -> void: got_429["v"] = retry_after)
	c._current = {"operation": "fetch_rooms"}
	c._on_request_completed(HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(),
		JSON.stringify({"error": "rate_limited", "retryAfterSec": 42}).to_utf8_buffer())
	_expect(got_429.get("v", -1) == 42, "429 应带 retryAfterSec=42，实得 %s" % got_429.get("v", "<none>"))

	# 7) 未被 setup 时发请求 → request_failed(not_configured)，且不进队列。
	var got_nc := {}
	c.request_failed.connect(func(op: String, reason: String) -> void:
		if reason == "not_configured":
			got_nc["ok"] = true)
	c.fetch_rooms(TEST_PROTOCOL)
	_expect(got_nc.get("ok", false), "未配置基址时发请求应报 not_configured")
	_expect(not c.is_busy(), "未配置时不应留下排队请求")

	c.queue_free()

# ─────────────────────────── 联网集成 ───────────────────────────

func _test_live_roundtrip(url: String) -> void:
	var c := _make_client()
	if c == null:
		return
	if not c.setup(url):
		_fail("集成用例基址不可用：%s" % url)
		c.queue_free()
		return
	print("[LOBBY_TEST] 开始联网集成：%s" % c.base_url)

	# ① 注册
	var reg := await _await_register(c, {
		"name": "测试房",
		"hostName": "GodotTest",
		"address": "lobby-itest.frp.example.com",
		"port": 27015,
		"currentPlayers": 1,
		"maxPlayers": 4,
		"protocol": TEST_PROTOCOL,
		"gameVersion": "v0.33",
	})
	if reg.is_empty():
		c.queue_free()
		return
	var room: Dictionary = reg["room"]
	var token: String = reg["token"]
	var room_id := str(room.get("id", ""))
	_expect(room_id.length() == 6, "注册应返回 6 位 id，实得 '%s'" % room_id)
	_expect(not token.is_empty(), "注册应返回 hostToken")
	print("[LOBBY_TEST] 注册成功 id=%s" % room_id)

	# ② 列表应含这间房，且**不含 hostToken**
	var rooms := await _await_rooms(c)
	_expect(rooms.any(func(r: Variant) -> bool: return str((r as Dictionary).get("id", "")) == room_id),
		"列表应包含刚注册的房间")
	var leaked := rooms.any(func(r: Variant) -> bool: return (r as Dictionary).has("hostToken"))
	_expect(not leaked, "列表**不得**含 hostToken")

	# ③ 心跳
	var ttl := await _await_heartbeat(c, room_id, token, 3)
	_expect(ttl == 60, "心跳应返回 ttl=60，实得 %d" % ttl)

	# ④ 删除 → 列表不再含
	await _await_delete(c, room_id, token)
	var rooms2 := await _await_rooms(c)
	_expect(not rooms2.any(func(r: Variant) -> bool: return str((r as Dictionary).get("id", "")) == room_id),
		"删除后列表不应再含该房间")
	print("[LOBBY_TEST] 联网集成完成")

	c.queue_free()

func _await_register(c: Node, payload: Dictionary) -> Dictionary:
	var box := {}
	c.room_registered.connect(func(room: Dictionary, token: String) -> void:
		box["room"] = room
		box["token"] = token)
	c.request_failed.connect(func(_op: String, reason: String) -> void: box["err"] = reason)
	c.register_room(payload)
	var ok := await _wait_until(func() -> bool: return box.has("room") or box.has("err"))
	if not ok or box.has("err"):
		_fail("注册失败：%s" % box.get("err", "超时"))
		return {}
	return box

func _await_rooms(c: Node) -> Array:
	var box := {}
	c.rooms_received.connect(func(rooms: Array) -> void: box["v"] = rooms)
	c.request_failed.connect(func(_op: String, reason: String) -> void: box["err"] = reason)
	c.fetch_rooms(TEST_PROTOCOL)
	var ok := await _wait_until(func() -> bool: return box.has("v") or box.has("err"))
	if not ok or box.has("err"):
		_fail("拉列表失败：%s" % box.get("err", "超时"))
		return []
	return box["v"]

func _await_heartbeat(c: Node, room_id: String, token: String, players: int) -> int:
	var box := {}
	c.heartbeat_ok.connect(func(ttl: int) -> void: box["ttl"] = ttl)
	c.heartbeat_failed.connect(func(reason: String) -> void: box["err"] = reason)
	c.heartbeat(room_id, token, players)
	var ok := await _wait_until(func() -> bool: return box.has("ttl") or box.has("err"))
	if not ok or box.has("err"):
		_fail("心跳失败：%s" % box.get("err", "超时"))
		return -1
	return int(box["ttl"])

func _await_delete(c: Node, room_id: String, token: String) -> void:
	var box := {}
	c.room_deleted.connect(func() -> void: box["ok"] = true)
	c.request_failed.connect(func(_op: String, reason: String) -> void: box["err"] = reason)
	c.delete_room(room_id, token)
	var ok := await _wait_until(func() -> bool: return box.has("ok") or box.has("err"))
	if not ok or box.has("err"):
		_fail("删除失败：%s" % box.get("err", "超时"))

## 轮询等待条件成立（避免对每个信号都写一套 await 超时样板）。
func _wait_until(cond: Callable, timeout: float = LIVE_TIMEOUT) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().create_timer(0.05).timeout
	return cond.call()

# ─────────────────────────── 工具 ───────────────────────────

func _make_client() -> Node:
	# load() 返回 Variant，需显式收窄类型，否则 := 无法推断（GDScript 静态检查会报 Parse Error）。
	var script: GDScript = load("res://script/lobby_client.gd") as GDScript
	# ⚠ 目标脚本若解析失败，load() 会返回 null 并打印 SCRIPT ERROR —— 若不在这里拦下，
	# 后续断言会全部变成 "Nonexistent function" 噪音，甚至可能让用例**假绿**。
	if script == null:
		_fail("无法加载 res://script/lobby_client.gd（应为解析错误，见上方 SCRIPT ERROR）")
		return null
	var c: Node = script.new() as Node
	if c == null:
		_fail("lobby_client.gd 实例化失败")
		return null
	c.name = "LobbyClientTest"
	add_child(c)
	return c

func _expect(cond: bool, message: String) -> void:
	_checks += 1
	if not cond:
		_failures.append(message)

func _fail(message: String) -> void:
	_checks += 1
	_failures.append(message)

func _get_arg(prefix: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.trim_prefix(prefix).strip_edges()
	return ""
