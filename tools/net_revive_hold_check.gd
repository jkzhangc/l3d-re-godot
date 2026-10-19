extends Node

## 独立回环回归：只替换场景生命周期与连接层，不替换救援计时、输入或 RPC。
## 入口：godot --headless --path <项目目录> res://tools/net_revive_hold_check.tscn
## 不使用 --net-test 参数，不连接真实 Net、不加载地图、不写存档或配置。
const WorldScript := preload("res://script/network_world.gd")
const StateScript := preload("res://script/player_state.gd")
const ACTION: StringName = &"功能键"
const CONNECT_TIMEOUT_MSEC := 5000
const WATCHDOG_MSEC := 60000


class NetStub extends RefCounted:
	var is_host: bool = false
	var my_peer_id: int = 1
	var peer_ids: Array[int] = []

	func get_peer_ids() -> Array[int]:
		return peer_ids.duplicate()


class FakePlayer extends CharacterBody2D:
	var max_hp: float = 200.0
	var health: float = 200.0
	var downed: bool = false
	var dead: bool = false
	var revive_count: int = 0
	var revived_msec: int = -1

	func is_network_dead() -> bool:
		return downed or dead or health <= 0.0

	func apply_network_revive_state(hp: float) -> void:
		health = hp
		downed = false
		dead = false
		revive_count += 1
		revived_msec = Time.get_ticks_msec()


class TestWorld extends "res://script/network_world.gd":
	# 三个分支使用同一个类，保留父类全部 RPC 签名与实现。
	var received_starts: Array[Dictionary] = []
	var captures: int = 0

	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)

	func _process(_delta: float) -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass

	func _exit_tree() -> void:
		pass

	# 只观察真实 RPC 受理入口，所有资格判断与计时仍由父类执行。
	func _try_host_start_revive(reviver_id: int, target_id: int, claimed_position: Variant = null,
			local_input: bool = false) -> void:
		received_starts.append({
			"reviver": reviver_id, "target": target_id, "at": Time.get_ticks_msec(),
		})
		super._try_host_start_revive(reviver_id, target_id, claimed_position, local_input)


var _worlds: Array[TestWorld] = []
var _apis: Array[SceneMultiplayer] = []
var _peers: Array[ENetMultiplayerPeer] = []
var _host: TestWorld
var _client_a: TestWorld
var _client_b: TestWorld
var _driver: TestWorld
var _ids: Array[int] = []
var _total: int = 0
var _failures: int = 0
var _began_msec: int = 0
var _finished: bool = false
var _old_poll: bool = true
var _old_max_fps: int = 0


func _ready() -> void:
	_began_msec = Time.get_ticks_msec()
	_old_poll = get_tree().multiplayer_poll
	_old_max_fps = Engine.max_fps
	get_tree().multiplayer_poll = false
	Engine.max_fps = 120
	call_deferred("_run")


func _process(_delta: float) -> void:
	if not _finished and Time.get_ticks_msec() - _began_msec > WATCHDOG_MSEC:
		_check(false, "总超时：测试未能完成")
		_finish()


func _check(ok: bool, label: String) -> void:
	_total += 1
	if not ok:
		_failures += 1
	print("NET_REVIVE_HOLD_CHECK %s %s" % ["PASS" if ok else "FAIL", label])


func _finish() -> void:
	if _finished:
		return
	_finished = true
	set_process(false)
	Input.action_release(ACTION)
	_driver = null
	for peer: ENetMultiplayerPeer in _peers:
		peer.close()
	for api: SceneMultiplayer in _apis:
		api.multiplayer_peer = null
	get_tree().multiplayer_poll = _old_poll
	Engine.max_fps = _old_max_fps
	print("NET_REVIVE_HOLD_CHECK total=%d passed=%d failed=%d" % [
		_total, _total - _failures, _failures,
	])
	get_tree().quit(1 if _failures > 0 else 0)


func _poll() -> void:
	for api: SceneMultiplayer in _apis:
		var err: Error = api.poll()
		if err != OK and not _finished:
			_check(false, "SceneMultiplayer.poll 失败：%s" % error_string(err))
			_finish()


func _frame() -> void:
	await get_tree().process_frame
	if _finished:
		return
	_poll()
	# Input 是进程共享的：每个阶段只允许这一位玩家采集。
	if is_instance_valid(_driver):
		_driver.captures += 1
		_driver._capture_revive_input()
	_poll()
	_poll()
	if is_instance_valid(_host):
		_host._update_host_revives()
	_poll()


func _advance(msec: int) -> void:
	var deadline: int = Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline and not _finished:
		await _frame()


func _make_branch(label: String, peer: ENetMultiplayerPeer, is_host: bool) -> TestWorld:
	var branch := Node.new()
	branch.name = label
	add_child(branch)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, branch.get_path())
	api.multiplayer_peer = peer
	_apis.append(api)
	var world := TestWorld.new()
	world.name = "NetworkWorld"
	var stub := NetStub.new()
	stub.is_host = is_host
	world.net = stub
	branch.add_child(world)
	_worlds.append(world)
	_check(branch.get_path_to(world) == NodePath("NetworkWorld") and world.multiplayer == api,
		"%s 使用相同相对 RPC 路径与独立 MultiplayerAPI" % label)
	return world


func _connect_loopback() -> bool:
	var server := ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	var err: Error = server.create_server(0, 2, 3)
	_check(err == OK, "Host 仅绑定回环地址并申请临时 UDP 端口")
	if err != OK:
		return false
	_peers.append(server)
	var port: int = server.get_host().get_local_port()
	_host = _make_branch("Host", server, true)
	for label: String in ["ClientA", "ClientB"]:
		var peer := ENetMultiplayerPeer.new()
		err = peer.create_client("127.0.0.1", port, 3)
		_check(err == OK, "%s 创建回环 ENet Client" % label)
		if err != OK:
			peer.close()
			return false
		_peers.append(peer)
		var world := _make_branch(label, peer, false)
		if label == "ClientA":
			_client_a = world
		else:
			_client_b = world
	var deadline: int = Time.get_ticks_msec() + CONNECT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline and not _finished:
		await _frame()
		if _apis[0].get_peers().size() == 2 \
				and _peers[1].get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
				and _peers[2].get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break
	var connected: bool = _apis[0].get_peers().size() == 2 \
		and _peers[1].get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and _peers[2].get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	_check(connected, "同进程 Host 与两个 Client 已通过真实 ENet 建连")
	if not connected:
		return false
	for index: int in range(_worlds.size()):
		_ids.append(_apis[index].get_unique_id())
	for index: int in range(_worlds.size()):
		var world: TestWorld = _worlds[index]
		world.net.my_peer_id = _ids[index]
		world.net.peer_ids.assign(_ids)
		world._client_local_ready = true
		world._initial_world_received = true
		for peer_id: int in _ids:
			var player := FakePlayer.new()
			player.name = "Player_%d" % peer_id
			player.collision_layer = 0
			player.collision_mask = 0
			world.add_child(player)
			var state := StateScript.new()
			state.owner_peer_id = peer_id
			world._players[peer_id] = {"node": player, "state": state}
			if peer_id != 1:
				world._ready_client_peers[peer_id] = true
	_check(_ids[0] == 1 and _ids[1] > 1 and _ids[2] > 1 and _ids[1] != _ids[2],
		"使用真实 ENet 分配的不同 peer ID，不伪造 RPC sender")
	return true


func _player(world: TestWorld, peer_id: int) -> FakePlayer:
	return world._players[peer_id]["node"] as FakePlayer


func _set_player(world: TestWorld, peer_id: int, position: Vector2, downed: bool, dead: bool = false) -> void:
	var entry: Dictionary = world._players[peer_id]
	var player: FakePlayer = _player(world, peer_id)
	player.position = position
	player.downed = downed
	player.dead = dead
	player.health = 0.0 if downed or dead else player.max_hp
	var state: PlayerState = entry["state"] as PlayerState
	state.current_hp = player.health
	state.position = position
	entry["downed"] = downed
	entry["dead"] = dead
	entry["downed_hp"] = WorldScript.DOWNED_BLEED_HP
	entry["revive_progress"] = 0.0
	world._players[peer_id] = entry


func _set_all(peer_id: int, position: Vector2, downed: bool, dead: bool = false) -> void:
	for world: TestWorld in _worlds:
		_set_player(world, peer_id, position, downed, dead)


func _release() -> void:
	Input.action_release(ACTION)
	await _advance(100)
	_driver = null


func _reset_case(reviver: TestWorld, target_id: int) -> void:
	await _release()
	for world: TestWorld in _worlds:
		world._revive_attempts.clear()
		world._combat_busy_until_msec.clear()
		world.received_starts.clear()
		world.captures = 0
		for index: int in range(_ids.size()):
			var peer_id: int = _ids[index]
			_set_player(world, peer_id, Vector2(1000.0 + 500.0 * index, 0.0), false)
			var player: FakePlayer = _player(world, peer_id)
			player.revive_count = 0
			player.revived_msec = -1
	_set_all(int(reviver.net.my_peer_id), Vector2.ZERO, false)
	_set_all(target_id, Vector2(32.0, 0.0), true)
	_driver = reviver


func _attempt(reviver_id: int) -> Dictionary:
	return _host._revive_attempts.get(reviver_id, {}) as Dictionary


func _wait_attempt(reviver_id: int, target_id: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline and not _finished:
		await _frame()
		if int(_attempt(reviver_id).get("target", 0)) == target_id:
			return true
	return false


func _requests(reviver_id: int, target_id: int) -> Array[int]:
	var times: Array[int] = []
	for item: Dictionary in _host.received_starts:
		if int(item["reviver"]) == reviver_id and int(item["target"]) == target_id:
			times.append(int(item["at"]))
	return times


func _check_isolated_driver(label: String) -> void:
	var isolated: bool = true
	for world: TestWorld in _worlds:
		if world != _driver and world.captures != 0:
			isolated = false
	_check(isolated and _driver.captures > 0, "%s 只有当前施救者采集共享 Input" % label)


func _check_replicated(target_id: int, label: String) -> void:
	var expected_hp: float = _player(_host, target_id).max_hp * WorldScript.REVIVE_HP_RATIO
	for world: TestWorld in _worlds:
		var entry: Dictionary = world._players[target_id]
		var state: PlayerState = entry["state"] as PlayerState
		var player: FakePlayer = _player(world, target_id)
		_check(not bool(entry.get("downed", true)) and not bool(entry.get("dead", true))
			and not player.is_network_dead() and player.revive_count == 1
			and is_equal_approx(player.health, expected_hp)
			and is_equal_approx(state.current_hp, expected_hp),
			"%s %s 权威/真实 revive_presentation RPC 恢复 HP 与倒地标记且仅一次" % [
				label, world.get_parent().name,
			])


func _long_hold(reviver: TestWorld, target_id: int, label: String, drift: bool = false) -> void:
	await _reset_case(reviver, target_id)
	var reviver_id: int = int(reviver.net.my_peer_id)
	Input.action_press(ACTION)
	var accepted: bool = await _wait_attempt(reviver_id, target_id)
	_check(accepted, "%s 真实输入通过生产入口起救" % label)
	if not accepted:
		await _release()
		return
	var started: int = int(_attempt(reviver_id)["started_msec"])
	var stable: bool = true
	var not_early: bool = true
	var monotonic: bool = true
	var previous: float = 0.0
	var moved: bool = false
	var deadline: int = started + WorldScript.REVIVE_DURATION_MSEC + 1200
	while Time.get_ticks_msec() < deadline and not _finished:
		await _frame()
		var target: FakePlayer = _player(_host, target_id)
		if target.revive_count > 0:
			not_early = not_early and target.revived_msec - started >= WorldScript.REVIVE_DURATION_MSEC
			break
		var attempt: Dictionary = _attempt(reviver_id)
		stable = stable and int(attempt.get("started_msec", -1)) == started \
			and int(attempt.get("target", 0)) == target_id
		var progress: float = _host._get_host_revive_progress_for(target_id)
		monotonic = monotonic and progress >= previous
		previous = progress
		if drift and not moved and Time.get_ticks_msec() - started >= 500:
			# 目标进入 52→88px 滞回区，同时出现更近的倒地者；不应换目标或重起计时。
			_set_all(target_id, Vector2((WorldScript.REVIVE_RANGE + WorldScript.REVIVE_HOLD_RANGE) / 2.0, 0.0), true)
			_set_all(1, Vector2(16.0, 0.0), true)
			moved = true
	_check(stable, "%s 重复请求期间 started_msec 与目标保持不变" % label)
	_check(monotonic and previous > 0.5, "%s 生产救援进度持续递增" % label)
	_check(not_early and _player(_host, target_id).revive_count == 1,
		"%s 使用生产 REVIVE_DURATION_MSEC 完成真实长按且不提前" % label)
	if not reviver.net.is_host:
		var times: Array[int] = _requests(reviver_id, target_id)
		var minimum: int = maxi(2, int(float(WorldScript.REVIVE_DURATION_MSEC) / float(WorldScript.REVIVE_REQUEST_RETRY_MSEC)) - 2)
		var cadence: bool = times.size() >= minimum
		for index: int in range(1, times.size()):
			var gap: int = times[index] - times[index - 1]
			cadence = cadence and gap >= WorldScript.REVIVE_REQUEST_RETRY_MSEC - 30 \
				and gap <= WorldScript.REVIVE_REQUEST_RETRY_MSEC + 150
		_check(cadence, "%s Host 实收周期重发 requests=%d retry_msec=%d" % [
			label, times.size(), WorldScript.REVIVE_REQUEST_RETRY_MSEC,
		])
	if drift:
		_check(moved and _player(_host, 1).revive_count == 0 and bool(_host._players[1]["downed"]),
			"%s 滞回范围与更近倒地队友不抢当前目标" % label)
	await _advance(100)
	_check_replicated(target_id, label)
	_check_isolated_driver(label)
	await _release()


func _cancel_and_repress() -> void:
	var reviver_id: int = _ids[1]
	await _reset_case(_client_a, 1)
	Input.action_press(ACTION)
	var accepted: bool = await _wait_attempt(reviver_id, 1)
	_check(accepted, "取消/重按：Client 已起救")
	if not accepted:
		return
	_host._revive_attempts[reviver_id]["started_msec"] = Time.get_ticks_msec() - int(WorldScript.REVIVE_DURATION_MSEC / 2)
	_check(_host._get_host_revive_progress_for(1) >= 0.49, "取消前注入半程进度，仅用于取消用例")
	Input.action_release(ACTION)
	await _advance(100)
	_check(_attempt(reviver_id).is_empty() and _client_a._revive_attempts.is_empty()
		and is_zero_approx(_host._get_host_revive_progress_for(1)) and _player(_host, 1).revive_count == 0,
		"松开通过真实 revive_cancel_request 清理双端尝试与进度，不复活")
	var pressed_at: int = Time.get_ticks_msec()
	Input.action_press(ACTION)
	accepted = await _wait_attempt(reviver_id, 1)
	_check(accepted and int(_attempt(reviver_id).get("started_msec", -1)) >= pressed_at,
		"重新按下建立新计时，不继承已取消进度")
	await _advance(WorldScript.REVIVE_REQUEST_RETRY_MSEC * 2 + 40)
	_check(_player(_host, 1).revive_count == 0 and _host._get_host_revive_progress_for(1) < 0.4,
		"重按后多次重发仍从零计时")
	if not _attempt(reviver_id).is_empty():
		_host._revive_attempts[reviver_id]["started_msec"] = Time.get_ticks_msec() - WorldScript.REVIVE_DURATION_MSEC
		await _advance(100)
	_check_replicated(1, "取消后重按")
	_check_isolated_driver("取消后重按")


func _switch_target() -> void:
	var reviver_id: int = _ids[1]
	var next_target: int = _ids[2]
	await _reset_case(_client_a, 1)
	_set_all(next_target, Vector2(1000.0, 0.0), true)
	Input.action_press(ACTION)
	var accepted: bool = await _wait_attempt(reviver_id, 1)
	_check(accepted, "切目标：原目标已起救")
	if not accepted:
		return
	_host._revive_attempts[reviver_id]["started_msec"] = Time.get_ticks_msec() - int(WorldScript.REVIVE_DURATION_MSEC / 2)
	var switched_at: int = Time.get_ticks_msec()
	_set_all(1, Vector2(WorldScript.REVIVE_HOLD_RANGE + 64.0, 0.0), true)
	_set_all(next_target, Vector2(32.0, 0.0), true)
	accepted = await _wait_attempt(reviver_id, next_target)
	_check(accepted and int(_attempt(reviver_id).get("started_msec", -1)) >= switched_at,
		"按住换目标：原目标出范围后真实 RPC 为新目标重新计时")
	await _advance(WorldScript.REVIVE_REQUEST_RETRY_MSEC * 2 + 40)
	_check(is_zero_approx(_host._get_host_revive_progress_for(1))
		and _host._get_host_revive_progress_for(next_target) < 0.4
		and _player(_host, 1).revive_count == 0 and _player(_host, next_target).revive_count == 0,
		"换目标清除旧进度，新目标不继承半程计时")
	if not _attempt(reviver_id).is_empty():
		_host._revive_attempts[reviver_id]["started_msec"] = Time.get_ticks_msec() - WorldScript.REVIVE_DURATION_MSEC
		await _advance(100)
	_check_replicated(next_target, "切目标")
	_check(bool(_host._players[1]["downed"]) and _player(_host, 1).revive_count == 0,
		"切目标后不会误救原目标")
	_check_isolated_driver("切目标")


func _rejections() -> void:
	var reviver_id: int = _ids[1]
	var observation_msec: int = WorldScript.REVIVE_REQUEST_RETRY_MSEC * 2 + 60
	await _reset_case(_client_a, 1)
	_set_all(1, Vector2(WorldScript.REVIVE_RANGE + 8.0, 0.0), true)
	Input.action_press(ACTION)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).is_empty(), "起手超范围：Client 本地筛选不发请求")
	# 故意制造过时的 Client 视图，证明 Host 在真实 RPC 入口独立拒绝。
	_set_player(_client_a, 1, Vector2(32.0, 0.0), true)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).size() >= 2 and _attempt(reviver_id).is_empty()
		and _player(_host, 1).revive_count == 0,
		"Host 拒绝超出起手范围的重复 RPC，不能把滞回范围当起手范围")
	_check_isolated_driver("起手超范围")

	await _reset_case(_client_a, 1)
	_set_all(1, Vector2(32.0, 0.0), false, true)
	Input.action_press(ACTION)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).is_empty(), "真死亡：Client 本地筛选不发请求")
	_set_player(_client_a, 1, Vector2(32.0, 0.0), true)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).size() >= 2 and _attempt(reviver_id).is_empty()
		and _player(_host, 1).dead and _player(_host, 1).revive_count == 0,
		"Host 拒绝过时倒地视图对真死亡目标的重复 RPC")
	_check_isolated_driver("真死亡")

	await _reset_case(_client_a, 1)
	_set_all(reviver_id, Vector2.ZERO, true)
	Input.action_press(ACTION)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).is_empty(), "施救者倒地：Client 本地禁止施救")
	_set_player(_client_a, reviver_id, Vector2.ZERO, false)
	await _advance(observation_msec)
	_check(_requests(reviver_id, 1).size() >= 2 and _attempt(reviver_id).is_empty()
		and _player(_host, 1).revive_count == 0,
		"Host 独立拒绝倒地施救者的重复 RPC")
	_check_isolated_driver("倒地施救者")

	for reason: String in ["超出持续范围", "施救途中倒地", "目标途中真死亡"]:
		await _reset_case(_client_a, 1)
		Input.action_press(ACTION)
		var accepted: bool = await _wait_attempt(reviver_id, 1)
		_check(accepted, "%s：中断前已正常起救" % reason)
		if not accepted:
			continue
		if reason == "超出持续范围":
			_set_all(1, Vector2(WorldScript.REVIVE_HOLD_RANGE + 8.0, 0.0), true)
		elif reason == "施救途中倒地":
			_set_all(reviver_id, Vector2.ZERO, true)
		else:
			_set_all(1, Vector2(32.0, 0.0), false, true)
		await _advance(observation_msec)
		_check(_attempt(reviver_id).is_empty() and _player(_host, 1).revive_count == 0
			and is_zero_approx(_host._get_host_revive_progress_for(1)),
			"%s：生产推进自动取消，不会救活" % reason)
		_check_isolated_driver(reason)


func _run() -> void:
	print("NET_REVIVE_HOLD_CHECK BEGIN baseline=8a26ee4d duration_msec=%d retry_msec=%d" % [
		WorldScript.REVIVE_DURATION_MSEC, WorldScript.REVIVE_REQUEST_RETRY_MSEC,
	])
	_check(InputMap.has_action(ACTION), "项目存在真实功能键 action")
	if not InputMap.has_action(ACTION):
		_finish()
		return
	var connected: bool = await _connect_loopback()
	if not connected or _finished:
		_finish()
		return
	# 三次真实长按都不注入 started_msec；前两次验证 Client 每 200ms 重发的原始故障。
	await _long_hold(_client_a, 1, "Client→Host")
	await _long_hold(_client_a, _ids[2], "Client→另Client", true)
	await _long_hold(_host, _ids[2], "Host本地→Client")
	await _cancel_and_repress()
	await _switch_target()
	await _rejections()
	await _release()
	_finish()
