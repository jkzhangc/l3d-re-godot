extends Node

## 独立回环回归，不改用户配置、不加载地图、不访问互联网服务。
## 入口：godot --headless --path <项目目录> res://tools/net_room_settings_check.tscn
## 真实 ENet/握手/设置/切图协议；仅替换最终场景加载与大厅联网发现、装饰初始化。
const LOBBY_SCENE := preload("res://scene/network_lobby.tscn")
const TIMEOUT_MSEC := 5000


class TestNet extends "res://script/network_manager.gd":
	var visited_scenes: Array[String] = []

	func _ready() -> void:
		set_process(false)
		upnp_enabled = false

	func _create_peer() -> MultiplayerPeer:
		var peer := ENetMultiplayerPeer.new()
		peer.set_bind_ip("127.0.0.1")
		return peer

	func _change_scene_safely(scene_path: String) -> void:
		visited_scenes.append(scene_path)


class TestLobby extends "res://script/network_lobby.gd":
	func _ready() -> void:
		set_process(false)
		net.room_settings_changed.connect(_on_room_settings_changed)
		next_room_friendly_fire_check.toggled.connect(_on_next_room_friendly_fire_toggled)
		friendly_fire_check.toggled.connect(_on_friendly_fire_toggled)
		_apply_panel_font_sizes()
		_refresh_friendly_fire_controls()

	func _refresh_ui() -> void:
		_refresh_friendly_fire_controls()


var _apis: Array[SceneMultiplayer] = []
var _nets: Array[TestNet] = []
var _lobbies: Array[TestLobby] = []
var _checks := 0
var _failures := 0
var _old_poll := true
var _old_max_fps := 0
var _started_msec := 0
var _finished := false


func _ready() -> void:
	_old_poll = get_tree().multiplayer_poll
	_old_max_fps = Engine.max_fps
	get_tree().multiplayer_poll = false
	Engine.max_fps = 120
	_started_msec = Time.get_ticks_msec()
	call_deferred("_run")


func _process(_delta: float) -> void:
	if not _finished and Time.get_ticks_msec() - _started_msec > 30000:
		_check(false, "回归总超时")
		_finish()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("NET_ROOM_SETTINGS_CHECK %s %s" % ["PASS" if ok else "FAIL", label])


func _frame() -> void:
	await get_tree().process_frame
	if _finished:
		return
	for api: SceneMultiplayer in _apis:
		var err: Error = api.poll()
		if err != OK:
			_check(false, "回环 poll 失败：%s" % error_string(err))
			_finish()
			return


func _wait_until(condition: Callable, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not condition.call() and Time.get_ticks_msec() < deadline and not _finished:
		await _frame()
	var ok: bool = not _finished and bool(condition.call())
	_check(ok, label)
	return ok


func _make_net(label: String) -> TestNet:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	_apis.append(api)
	var instance := TestNet.new()
	instance.name = "Net"
	branch.add_child(instance)
	_nets.append(instance)
	return instance


func _make_lobby(connection: TestNet) -> TestLobby:
	var lobby := LOBBY_SCENE.instantiate() as Control
	lobby.set_script(TestLobby)
	var test_lobby := lobby as TestLobby
	test_lobby.net = connection
	add_child(test_lobby)
	_lobbies.append(test_lobby)
	return test_lobby


func _run() -> void:
	var host := _make_net("Host")
	var host_ui := _make_lobby(host)
	_check(host.PROTOCOL_VERSION == "l3d_main_v3_snapshot_versions", "协议版本号已升级为 v3_snapshot_versions")
	_check(not host.friendly_fire_enabled, "Net 默认关闭友伤")
	_check(not host_ui.next_room_friendly_fire_check.button_pressed, "离线预选默认关闭")
	_check(not host.set_host_friendly_fire_enabled(true), "离线不可直接修改房间状态")
	host_ui.next_room_friendly_fire_check.button_pressed = true
	_check(not host.friendly_fire_enabled, "离线预选仅留在 UI，不写 Net")
	var err: Error = host_ui._host_game_with_room_settings(0)
	_check(err == OK, "经真实 host_game 创建回环临时端口房间")
	if err != OK:
		_finish()
		return
	_check(host.friendly_fire_enabled, "host_game 内 leave 清零后，仍应用保存的预选")
	_check(host_ui.friendly_fire_check.button_pressed and not host_ui.friendly_fire_check.disabled,
		"房主控件显示开启且可操作")
	_check(host_ui.next_room_friendly_fire_check.disabled, "连接后锁定下一房间预选")
	var server: ENetMultiplayerPeer = host.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var port: int = server.get_host().get_local_port()
	var client := _make_net("Client")
	var client_ui := _make_lobby(client)
	err = client.join_game("127.0.0.1", port)
	_check(err == OK, "Client 发起真实回环加入")
	if err != OK or not await _wait_until(func() -> bool: return client.handshake_ok, "hello_ack 同步已开启房间"):
		_finish()
		return
	_check(client.friendly_fire_enabled and client_ui.friendly_fire_check.button_pressed,
		"Client 握手后显示 Host 当前值")
	_check(client_ui.friendly_fire_check.disabled and client_ui.next_room_friendly_fire_check.disabled,
		"Client 的房间设置及预选均只读")
	_check(not client.set_host_friendly_fire_enabled(false), "Client 调用 Host setter 被拒绝")
	client.friendly_fire_enabled = false
	client.room_settings(false)
	client_ui._on_friendly_fire_toggled(false)
	_check(client.friendly_fire_enabled and host.friendly_fire_enabled, "Client 直接赋值、本地伪同步及 UI 回调均不能改设置")
	host_ui.friendly_fire_check.button_pressed = false
	if not await _wait_until(func() -> bool: return not client.friendly_fire_enabled, "房主关闭后可靠广播到 Client"):
		_finish()
		return
	host_ui.friendly_fire_check.button_pressed = true
	if not await _wait_until(func() -> bool: return client.friendly_fire_enabled, "房主开启后可靠广播到 Client"):
		_finish()
		return
	var late := _make_net("LateClient")
	var late_ui := _make_lobby(late)
	err = late.join_game("127.0.0.1", port)
	_check(err == OK, "晚加入 Client 发起连接")
	if err != OK or not await _wait_until(func() -> bool: return late.handshake_ok, "晚加入握手完成"):
		_finish()
		return
	_check(late.friendly_fire_enabled and late_ui.friendly_fire_check.button_pressed and late_ui.friendly_fire_check.disabled,
		"晚加入收到当前开关并只读显示")
	var first_scene := "res://tools/net_room_settings_check.tscn"
	var second_scene := "res://scene/network_lobby.tscn"
	host.start_game.rpc(first_scene, "", null, Global.selected_difficulty, host.friendly_fire_enabled)
	if not await _wait_until(func() -> bool: return host.visited_scenes.size() == 1 and client.visited_scenes.size() == 1 and late.visited_scenes.size() == 1,
		"真实 start_game/ACK/commit/flush 完成，不加载地图"):
		_finish()
		return
	_check(host.friendly_fire_enabled and client.friendly_fire_enabled and late.friendly_fire_enabled,
		"开局后三端保持同一开启值")
	host.request_scene_change(second_scene)
	if not await _wait_until(func() -> bool: return host.visited_scenes.size() == 2 and client.visited_scenes.size() == 2 and late.visited_scenes.size() == 2,
		"经 request_scene_change 完成第二轮切图"):
		_finish()
		return
	_check(host.friendly_fire_enabled and client.friendly_fire_enabled and late.friendly_fire_enabled,
		"跨图不丢失友伤设置")
	# 未显式携带选项的旧内部调用必须沿用会话状态，不能被默认 false 覆盖。
	host.start_game.rpc(first_scene, "", null, Global.selected_difficulty)
	if not await _wait_until(func() -> bool: return host.visited_scenes.size() == 3 and client.visited_scenes.size() == 3 and late.visited_scenes.size() == 3,
		"省略可选设置参数的切图仍可完成"):
		_finish()
		return
	_check(host.friendly_fire_enabled and client.friendly_fire_enabled and late.friendly_fire_enabled,
		"省略设置参数时保留已同步房间值")
	for connection: TestNet in _nets:
		connection.leave()
	for index: int in range(_nets.size()):
		_check(not _nets[index].friendly_fire_enabled and not _lobbies[index].next_room_friendly_fire_check.button_pressed
			and not _lobbies[index].next_room_friendly_fire_check.disabled,
			"端 %d 离房清零且可预选新房间" % index)
	client.room_settings(true)
	client.hello_ack(host.PROTOCOL_VERSION, {}, {}, true)
	client.start_game(first_scene, "", null, -1, true)
	_check(not client.friendly_fire_enabled and not client.handshake_ok and client.active_scene_path.is_empty(),
		"离房后在途/本地回调不能恢复旧房间设置")
	err = host_ui._host_game_with_room_settings(0)
	_check(err == OK and not host.friendly_fire_enabled, "重新建房默认关闭，不继承上一房间")
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	for connection: TestNet in _nets:
		connection.leave()
	get_tree().multiplayer_poll = _old_poll
	Engine.max_fps = _old_max_fps
	print("NET_ROOM_SETTINGS_CHECK total=%d passed=%d failed=%d" % [_checks, _checks - _failures, _failures])
	get_tree().quit(1 if _failures > 0 or _checks == 0 else 0)
