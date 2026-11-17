extends SceneTree

## ── 架构定位 ──
## 系统：UDP弱网验收 ｜ 层：本地隔离真实Net/World事务探针
## 真实 ENet 游戏事务探针；只使用内存会话，不调用配置/存档保存入口。
## 不传 --net-test*，保证 GameInit 加载生产 NetworkWorld 而非自动回归子类。
const MAP := "res://scene/maps/突袭-第一关-开头安全屋-户外.tscn"
var PICKUP_SCENE: PackedScene
var PICKUP_SCRIPT: GDScript
var OLD_WEAPON: Resource
var KNIFE: Resource
var TARGETS: Array[Resource] = []
var SUPPORTS: Array[Resource] = []

var _role: String = "client"
var _port: int = 28160
var _clients: int = 2
var _index: int = 0
var _count: int = 150
var _fps: int = 60
var _net: Node
var _probe: Probe
var _finished: bool = false
var _finishing: bool = false
var _checks: int = 0
var _failures: Array[String] = []
var _items: Array = []
var _transactions: Array = []
var _stages: Array = []
var _peers: Array[int] = []
var _peer_indices: Dictionary = {}
var _expected: Dictionary = {}
var _stage: int = 0
var _waiting: Dictionary = {}
var _acks: Dictionary = {}
var _client_stages: Dictionary = {}
var _remote_failures: Array = []
var _client_reports: Dictionary = {}
var _old_world_id: int = 0
var _old_nodes: Array[WeakRef] = []
var _echo_stage: int = -1
var _echo_token: String = ""
var _echo_sent: Dictionary = {}
var _echo_received: Dictionary = {}
var _echo_host_seen: Dictionary = {}
var _echo_active_announced: bool = false
var _echo_raw: Array = []
var _echo_duplicates: int = 0
var _echo_summary: Dictionary = {}
var _finish_acks: Dictionary = {}
var _enet_final_counters: Dictionary = {}

class Probe extends Node:
	var diagnostic: SceneTree

	@rpc("authority", "call_remote", "reliable")
	func command(stage: int, token: String, action: String, data: Dictionary) -> void:
		# RPC 回调只排队，不在网络派发栈中换图或释放节点。
		diagnostic.call_deferred("_client_command", stage, token, action, data)

	@rpc("any_peer", "call_remote", "reliable")
	func ack(stage: int, token: String, report: Dictionary) -> void:
		diagnostic._receive_ack(multiplayer.get_remote_sender_id(), stage, token, report)

	@rpc("any_peer", "call_remote", "reliable")
	func echo_request(stage: int, token: String, seq: int, stamp: int) -> void:
		var sender: int = multiplayer.get_remote_sender_id()
		diagnostic._receive_echo_request(sender, stage, token, seq, stamp)

	@rpc("authority", "call_remote", "reliable")
	func echo_reply(stage: int, token: String, seq: int, stamp: int) -> void:
		diagnostic._receive_echo_reply(stage, token, seq, stamp)

	@rpc("authority", "call_remote", "reliable")
	func finish(ok: bool, host_result: Dictionary) -> void:
		diagnostic.call_deferred("_client_finish", ok, host_result)

	@rpc("any_peer", "call_remote", "reliable")
	func finish_ack() -> void:
		var sender: int = multiplayer.get_remote_sender_id()
		if diagnostic._role == "host" and diagnostic._peers.has(sender):
			diagnostic._finish_acks[sender] = true

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--udp-lab-role="):
			_role = argument.trim_prefix("--udp-lab-role=")
		elif argument.begins_with("--udp-lab-port="):
			_port = int(argument.trim_prefix("--udp-lab-port="))
		elif argument.begins_with("--udp-lab-clients="):
			_clients = int(argument.trim_prefix("--udp-lab-clients="))
		elif argument.begins_with("--udp-lab-index="):
			_index = int(argument.trim_prefix("--udp-lab-index="))
		elif argument.begins_with("--udp-lab-count="):
			_count = int(argument.trim_prefix("--udp-lab-count="))
		elif argument.begins_with("--udp-lab-fps="):
			_fps = int(argument.trim_prefix("--udp-lab-fps="))
	call_deferred("_boot")

func _check(ok: bool, label: String) -> bool:
	_checks += 1
	if not ok:
		_failures.append(label)
		print("UDP_GAME_CHECK_FAILED " + label)
	return ok

func _world() -> Node:
	return current_scene.get_node_or_null("NetworkWorld") if current_scene != null else null

func _state(world: Node, peer: int) -> Variant:
	if not is_instance_valid(world):
		return null
	var players: Dictionary = world.get("_players")
	var entry: Dictionary = players.get(peer, {})
	return entry.get("state")

func _player(world: Node, peer: int) -> Node2D:
	var players: Dictionary = world.get("_players")
	var entry: Dictionary = players.get(peer, {})
	return world.call("_player_node", entry) as Node2D

func _item_id(item: Resource) -> String:
	return str(item.get("item_id")) if item != null else ""

func _host_dropped_count(world: Node) -> int:
	# 基于生产快照数 mg_01，不依赖生产脚本中并不存在的计数器。
	var count: int = 0
	var packets: Array = world.call("_build_pickup_snapshot")
	for packet: Dictionary in packets:
		if str(packet.get("weapon_id", "")) == "mg_01":
			count += 1
	return count

func _world_ready(previous_id: int = 0) -> bool:
	var world: Node = _world()
	if world == null or world.get_instance_id() == previous_id or bool(world.get("_scene_transitioning")):
		return false
	if _role == "client":
		return bool(world.call("_client_ready_to_send"))
	if not bool(world.get("_host_world_ready")):
		return false
	var ready: Dictionary = world.get("_ready_client_peers")
	for peer: int in _peers:
		if not ready.has(peer) or _state(world, peer) == null:
			return false
	return true

func _wait_world(previous_id: int = 0) -> bool:
	var deadline: int = Time.get_ticks_msec() + 10000
	while not _finished and not _world_ready(previous_id) and Time.get_ticks_msec() < deadline:
		await process_frame
	return _check(_world_ready(previous_id), "NetworkWorld双方就绪 previous=%d" % previous_id)

func _boot() -> void:
	# SceneTree --script在autoload就绪前解析，依赖Global的拾取脚本必须延后加载。
	PICKUP_SCENE = load("res://object/weapon_pickup.tscn")
	PICKUP_SCRIPT = load("res://script/weapon_pickup.gd")
	OLD_WEAPON = load("res://object/weapon_mg_01.tres")
	KNIFE = load("res://object/weapon_knife.tres")
	TARGETS.assign([load("res://object/weapon_pistol_02.tres"), load("res://object/weapon_rifle_02.tres")])
	SUPPORTS.assign([load("res://object/item_painkiller.tres"), load("res://object/item_adrenaline.tres")])
	_net = root.get_node("Net")
	_probe = Probe.new()
	_probe.name = "UdpGameProbe"
	_probe.diagnostic = self
	_probe.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_probe)
	Engine.max_fps = maxi(1, _fps)
	_net.set("upnp_enabled", false)
	if not _check(_role in ["host", "client"] and _clients >= 1 and _clients <= 4
			and _count > 0 and _count <= 2000 and _port > 0 and _port < 65536,
			"启动参数有效"):
		await _abort("启动参数无效")
		return
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test"):
			await _abort("禁止 --net-test*：会让GameInit加载harness而非生产NetworkWorld")
			return
	# equip_weapon_in_slot 会经 mark_acquired 首次收藏落 config。
	# 仅向内存已有集合预置本探针资源 ID，使真实拾取入口幂等早退；不调用保存。
	var global: Node = root.get_node("Global")
	var collected: PackedStringArray = global.get("collection_ids")
	for item: Resource in [OLD_WEAPON, KNIFE, TARGETS[0], TARGETS[1], SUPPORTS[0], SUPPORTS[1]]:
		if not collected.has(_item_id(item)):
			collected.append(_item_id(item))
	for weapon: Resource in [OLD_WEAPON, TARGETS[0], TARGETS[1]]:
		if not weapon.ammo_item_id.is_empty() and not collected.has(weapon.ammo_item_id):
			collected.append(weapon.ammo_item_id)
	global.set("collection_ids", collected)
	create_timer(100.0 if _role == "host" else 110.0).timeout.connect(_timeout)
	_net.set("player_name", "UdpLabHost" if _role == "host" else "UdpLab%d" % _index)
	if _role == "client":
		if not _check(int(_net.call("join_game", "127.0.0.1", _port)) == OK, "Client真实ENet建连"):
			await _abort("Client建连失败")
		return
	if not _check(int(_net.call("host_game", _port)) == OK, "Host真实ENet监听"):
		await _abort("Host监听失败")
		return
	print("UDP_GAME_HOST_READY " + JSON.stringify({"port": _port, "clients": _clients, "count": _count}))
	await _run_host()

func _run_host() -> void:
	var deadline: int = Time.get_ticks_msec() + 20000
	while (_net.call("get_player_names") as Dictionary).size() < _clients + 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	var names: Dictionary = _net.call("get_player_names")
	if not _check(names.size() == _clients + 1, "生产hello握手人数"):
		await _abort("等待客户端握手超时")
		return
	for client_index: int in range(_clients):
		var found: int = 0
		for peer_value: Variant in names:
			if int(peer_value) > 1 and str(names[peer_value]) == "UdpLab%d" % client_index:
				found = int(peer_value)
		if not _check(found > 1 and not _peers.has(found), "昵称对应独立客户端%d" % client_index):
			await _abort("客户端昵称或索引不匹配")
			return
		_peers.append(found)
		_peer_indices[found] = client_index
		_expected[found] = _item_id(TARGETS[client_index % TARGETS.size()])
	var error: int = _net.rpc("start_game", MAP, "", null, 0, false, true)
	if not _check(error == OK, "生产start_game首图RPC") or not await _wait_world():
		await _abort("首图未就绪")
		return
	var world: Node = _world()
	for peer: int in _peers:
		var state: Variant = _state(world, peer)
		state.equipment["primary"] = OLD_WEAPON
		state.equipment["secondary"] = KNIFE
		state.active_weapon_slot = "primary"
		_player(world, peer).call("enter_weapon_mode", OLD_WEAPON)
	world.call("_broadcast_reliable_world_snapshot")
	for peer: int in _peers:
		await _host_pickup(peer)
		if _finished or _finishing:
			return
	for peer: int in _peers:
		await _host_support(peer)
		if _finished or _finishing:
			return
	var carry: Dictionary = {"expected": _expected.duplicate(), "support_empty": true}
	await _host_stage("checkpoint", carry, _peers)
	_old_world_id = world.get_instance_id()
	_capture_old_nodes(world)
	error = _net.rpc("start_game", MAP, "", null, 0, false, true)
	_check(error == OK, "生产start_game第二图RPC")
	if not await _wait_world(_old_world_id):
		await _abort("第二图未就绪")
		return
	_check(_old_references_cleared(), "Host上一图动态节点释放（不跨world比较数字ID）")
	world = _world()
	for peer: int in _peers:
		_check(_loadout_matches(world, peer, str(_expected[peer])), "Host跨图装备保留%d" % peer)
		_check(_state(world, peer).support_item == null, "Host跨图消费保留%d" % peer)
	world.call("_broadcast_reliable_world_snapshot")
	await _host_stage("transition", carry, _peers)
	_echo_host_seen.clear()
	await _host_stage("echo", {"count": _count}, _peers)
	for peer: int in _peers:
		var seen: Dictionary = _echo_host_seen.get(peer, {})
		_check(seen.size() == _count, "Host每客户端echo完整%d" % peer)
	await _finish_host()

func _host_pickup(peer: int) -> void:
	var world: Node = _world()
	var client_index: int = int(_peer_indices[peer])
	var target: Resource = TARGETS[client_index % TARGETS.size()]
	var player: Node2D = _player(world, peer)
	var pickup: Node2D = PICKUP_SCENE.instantiate() as Node2D
	PICKUP_SCRIPT.apply_weapon_ground_display(pickup, target)
	pickup.name = "UdpLabSource%d" % client_index
	pickup.set("cap_exempt", true)
	pickup.set("require_function_key", true)
	pickup.process_mode = Node.PROCESS_MODE_DISABLED
	var ground: Node = current_scene.find_child("GroundLayer", true, false)
	(ground if ground != null else current_scene).add_child(pickup)
	pickup.global_position = player.global_position
	var pickup_id: int = int(world.call("_register_host_pickup", pickup))
	var baseline: int = _host_dropped_count(world)
	var before_ids: Array = _mg_ids(world)
	_items.append({"peer": peer, "index": client_index, "world": 1, "pickup_id": pickup_id,
		"expected_id": target.item_id, "old_id": "mg_01"})
	world.call("_broadcast_reliable_world_snapshot")
	var data: Dictionary = {"peer": peer, "pickup_id": pickup_id, "expected_id": target.item_id,
		"old_count": baseline, "expected": {peer: target.item_id}}
	await _host_stage("pickup", data, [peer])
	var deadline: int = Time.get_ticks_msec() + 10000
	while not _pickup_committed(world, data) and Time.get_ticks_msec() < deadline and not _finished:
		await process_frame
	_check(_pickup_committed(world, data), "Host拾取权威提交%d" % peer)
	# 两条相同ID请求在同一可靠流中；检查最终掉落总增量，不能靠第二次装备事件蒙混过关。
	await create_timer(0.25).timeout
	var after_count: int = _host_dropped_count(world)
	_check(after_count - baseline == 1, "重复同源pickup_request只掉一把mg_01 peer=%d" % peer)
	var drops: Array = []
	for id_value: Variant in _mg_ids(world):
		if not before_ids.has(id_value):
			var dropped: Node2D = world.call("_pickup_node", int(id_value)) as Node2D
			_check(dropped != null and dropped.global_position.distance_to(player.global_position) <= 200.0,
				"旧mg_01落在玩家附近 peer=%d" % peer)
			drops.append(int(id_value))
	data["drops"] = drops
	data["old_count"] = baseline
	world.call("_broadcast_reliable_world_snapshot")
	await _host_stage("pickup_observe", data, _peers)
	_transactions.append({"kind": "pickup", "peer": peer, "source_id": pickup_id,
		"expected_id": target.item_id, "requests": 2, "old_count_before": baseline,
		"old_count_after": after_count, "old_drop_ids": drops, "committed": _pickup_committed(world, data)})

func _host_support(peer: int) -> void:
	var world: Node = _world()
	var support: Resource = SUPPORTS[int(_peer_indices[peer]) % SUPPORTS.size()]
	_state(world, peer).support_item = support
	world.call("_broadcast_reliable_world_snapshot")
	await _host_stage("support", {"peer": peer, "support_id": support.item_id}, [peer])
	_check(_state(world, peer).support_item == null, "Host辅助品消费后槽空%d" % peer)
	world.call("_broadcast_reliable_world_snapshot")
	await _host_stage("support_observe", {"peer": peer}, _peers)
	_transactions.append({"kind": "support", "peer": peer, "item_id": support.item_id,
		"requests": 1, "empty": _state(world, peer).support_item == null})

func _loadout_matches(world: Node, peer: int, expected_id: String) -> bool:
	var state: Variant = _state(world, peer)
	return state != null and _item_id(state.get_equipped_weapon("primary")) == expected_id \
		and _item_id(state.get_equipped_weapon("secondary")) == _item_id(KNIFE)

func _pickup_committed(world: Node, data: Dictionary) -> bool:
	return is_instance_valid(world) and _loadout_matches(world, int(data["peer"]), str(data["expected_id"])) \
		and world.call("_pickup_node", int(data["pickup_id"])) == null \
		and _host_dropped_count(world) == int(data["old_count"]) + 1

func _mg_ids(world: Node) -> Array:
	var ids: Array = []
	var packets: Array = world.call("_build_pickup_snapshot")
	for packet: Dictionary in packets:
		if str(packet.get("weapon_id", "")) == "mg_01":
			ids.append(int(packet["pickup_id"]))
	return ids

func _capture_old_nodes(world: Node) -> void:
	_old_nodes.clear()
	for id_value: Variant in _mg_ids(world):
		var node: Node2D = world.call("_pickup_node", int(id_value)) as Node2D
		if node != null:
			_old_nodes.append(weakref(node))

func _old_references_cleared() -> bool:
	for reference: WeakRef in _old_nodes:
		if reference.get_ref() != null:
			return false
	return true

func _host_stage(action: String, data: Dictionary, targets: Array) -> void:
	if _finished or _finishing:
		return
	data = data.duplicate(true)
	if _world() != null:
		_world().call("_broadcast_reliable_world_snapshot")
		data["snapshot_epoch"] = int(_world().get("_snapshot_epoch"))
	_stage += 1
	var stage: int = _stage
	var token: String = "udp-game-%d-%s" % [stage, action]
	_waiting = {"stage": stage, "token": token, "targets": targets.duplicate(), "action": action}
	_acks.clear()
	if action == "echo":
		_echo_stage = stage
		_echo_token = token
	for peer: int in targets:
		_check(_probe.rpc_id(peer, "command", stage, token, action, data) == OK, "可靠指令发送%s peer=%d" % [action, peer])
	_net.call("flush_transport")
	var started: int = Time.get_ticks_msec()
	# echo preparation (world + reliable snapshot) and client reply budget must fit too.
	var stage_budget: int = 20000
	if action == "echo":
		stage_budget = 32000 + int(data.get("count", _count)) * 50
	var deadline: int = started + stage_budget
	while _acks.size() < targets.size() and Time.get_ticks_msec() < deadline and not _finished:
		await process_frame
	for peer: int in targets:
		_check(_acks.has(peer), "阶段确认%s peer=%d stage=%d" % [action, peer, stage])
	_stages.append({"stage": stage, "action": action, "targets": targets.duplicate(),
		"acks": _acks.duplicate(true), "elapsed_ms": Time.get_ticks_msec() - started})
	print("UDP_GAME_STAGE " + JSON.stringify(_stages.back()))
	_waiting.clear()

func _receive_ack(sender: int, stage: int, token: String, report: Dictionary) -> void:
	if _role != "host" or _waiting.is_empty() or stage != int(_waiting["stage"]) \
			or token != str(_waiting["token"]) or not (_waiting["targets"] as Array).has(sender):
		return
	if _acks.has(sender):
		_check(false, "阶段ack重复 peer=%d stage=%d" % [sender, stage])
		return
	_acks[sender] = report.duplicate(true)
	for failure: Variant in report.get("failures", []):
		_remote_failures.append({"peer": sender, "stage": stage, "failure": str(failure)})
	if int(report.get("total_failures", 0)) > 0 and (report.get("failures", []) as Array).is_empty():
		_remote_failures.append({"peer": sender, "stage": stage, "failure": "客户端累计断言失败", "count": report["total_failures"]})
	_client_reports[sender] = report.duplicate(true)

func _client_command(stage: int, token: String, action: String, data: Dictionary) -> void:
	if _role != "client" or _finished or _finishing:
		return
	if _client_stages.has(stage):
		# 不因重复控制消息再次执行辅助消费或拾取事务。
		_check(false, "可靠控制指令重复stage=%d" % stage)
		return
	_client_stages[stage] = token
	var initial_failures: int = _failures.size()
	var initial_checks: int = _checks
	var started: int = Time.get_ticks_msec()
	var ready: bool = await _wait_world(_old_world_id if action == "transition" else 0)
	if ready:
		var world: Node = _world()
		var snapshot_deadline: int = Time.get_ticks_msec() + 10000
		while int(world.get("_last_reliable_world_epoch")) < int(data.get("snapshot_epoch", -1)) \
				and Time.get_ticks_msec() < snapshot_deadline:
			await process_frame
		_check(int(world.get("_last_reliable_world_epoch")) >= int(data.get("snapshot_epoch", -1)),
			"阶段前可靠世界快照已应用stage=%d" % stage)
		match action:
			"pickup":
				var id: int = int(data["pickup_id"])
				var deadline: int = Time.get_ticks_msec() + 10000
				while (world.call("_pickup_node", id) == null or not _loadout_matches(world, int(data["peer"]), "mg_01")) \
						and Time.get_ticks_msec() < deadline:
					await process_frame
				_check(int(_net.get("my_peer_id")) == int(data["peer"]), "拾取目标为本机座位")
				var source: Node2D = world.call("_pickup_node", id) as Node2D
				_check(source != null and _item_id(source.get("weapon_data") as Resource) == str(data["expected_id"]),
					"Client看到白名单目标真实动态源")
				_check(_loadout_matches(world, int(data["peer"]), "mg_01"), "Client拾取前主mg_01副knife")
				world.call("request_pickup", id)
				world.call("request_pickup", id)
				deadline = Time.get_ticks_msec() + 10000
				while not _pickup_committed(world, data) and Time.get_ticks_msec() < deadline:
					await process_frame
				_check(_pickup_committed(world, data), "Client装备/源删除/旧mg唯一同事务")
				_items.append(data.duplicate(true))
				_transactions.append({"kind": "pickup", "stage": stage, "source_id": id, "requests": 2,
					"committed": _pickup_committed(world, data)})
			"pickup_observe":
				await _client_observe_pickup(world, data)
			"support":
				var peer: int = int(data["peer"])
				var deadline: int = Time.get_ticks_msec() + 10000
				while (_state(world, peer) == null or _item_id(_state(world, peer).support_item) != str(data["support_id"])) \
						and Time.get_ticks_msec() < deadline:
					await process_frame
				var slot_ready: bool = _state(world, peer) != null and _item_id(_state(world, peer).support_item) == str(data["support_id"])
				_check(slot_ready and peer == int(_net.get("my_peer_id")), "辅助槽可靠快照含预设物品")
				if slot_ready:
					# 仅一次；不能拿另一份未来道具重试旧消费事务。
					world.call("request_support_use")
					await _client_observe_support(world, peer)
				_transactions.append({"kind": "support", "stage": stage, "item_id": data["support_id"],
					"requests": 1 if slot_ready else 0, "empty": _state(world, peer) != null and _state(world, peer).support_item == null})
			"support_observe":
				await _client_observe_support(world, int(data["peer"]))
			"checkpoint":
				await _client_observe_carry(world, data)
				_old_world_id = world.get_instance_id()
				_capture_old_nodes(world)
			"transition":
				_check(world.get_instance_id() != _old_world_id, "Client真实切图重建NetworkWorld")
				_check(_old_references_cleared(), "Client上一图动态节点清理（数字ID可复用）")
				await _client_observe_carry(world, data)
			"echo":
				await _run_echo(stage, token, int(data["count"]))
			_:
				_check(false, "未知阶段" + action)
	var report: Dictionary = {"stage": stage, "action": action, "index": _index,
		"checks": _checks - initial_checks, "total_checks": _checks,
		"failures": _failures.slice(initial_failures), "total_failures": _failures.size(),
		"elapsed_ms": Time.get_ticks_msec() - started}
	if action == "echo":
		report["echo"] = _echo_summary.duplicate(true)
	_stages.append(report.duplicate(true))
	_check(_probe.rpc_id(1, "ack", stage, token, report) == OK, "可靠阶段ack发送stage=%d" % stage)
	_net.call("flush_transport")
	print("UDP_GAME_CLIENT_STAGE " + JSON.stringify(report))

func _client_observe_pickup(world: Node, data: Dictionary) -> void:
	var deadline: int = Time.get_ticks_msec() + 10000
	while not _pickup_committed(world, data) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_pickup_committed(world, data), "所有Client同见装备/源删除/唯一旧mg")
	for id_value: Variant in data.get("drops", []):
		var node: Node2D = world.call("_pickup_node", int(id_value)) as Node2D
		_check(node != null and node.is_visible_in_tree(), "所有Client可见旧mg ID=%d" % int(id_value))

func _client_observe_support(world: Node, peer: int) -> void:
	var deadline: int = Time.get_ticks_msec() + 10000
	while (_state(world, peer) == null or _state(world, peer).support_item != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_state(world, peer) != null and _state(world, peer).support_item == null, "Client辅助消费可靠回灌槽空peer=%d" % peer)

func _client_observe_carry(world: Node, data: Dictionary) -> void:
	var expected: Dictionary = data["expected"]
	for peer_value: Variant in expected:
		var peer: int = int(peer_value)
		var deadline: int = Time.get_ticks_msec() + 10000
		while not _loadout_matches(world, peer, str(expected[peer_value])) and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(_loadout_matches(world, peer, str(expected[peer_value])), "Client跨图装备peer=%d" % peer)
		await _client_observe_support(world, peer)

func _run_echo(stage: int, token: String, count: int) -> void:
	_echo_stage = stage
	_echo_token = token
	_echo_sent.clear()
	_echo_received.clear()
	_echo_raw.clear()
	_echo_duplicates = 0
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 82631 + _index
	var base: int = Time.get_ticks_usec() + 50000
	for seq: int in range(count):
		# 50ms绝对deadline加随机抖动，不把帧等待误差逐次累加。
		var due: int = base + seq * 50000 + rng.randi_range(-10000, 10000)
		while Time.get_ticks_usec() < due and not _finished:
			await process_frame
		var stamp: int = Time.get_ticks_usec()
		_echo_sent[seq] = stamp
		_check(_probe.rpc_id(1, "echo_request", stage, token, seq, stamp) == OK, "echo发送seq=%d" % seq)
	var deadline: int = Time.get_ticks_msec() + 10000
	while _echo_received.size() < count and Time.get_ticks_msec() < deadline and not _finished:
		await process_frame
	var missing: Array = []
	var samples: Array = []
	for seq: int in range(count):
		if not _echo_received.has(seq):
			missing.append(seq)
		else:
			samples.append(float(_echo_received[seq]))
	samples.sort()
	_check(missing.is_empty(), "可靠echo无遗漏")
	_check(_echo_duplicates == 0, "可靠echo无重复")
	_echo_summary = {"count": count, "received": _echo_received.size(), "missing": missing,
		"duplicates": _echo_duplicates, "p50_ms": _percentile(samples, 0.50),
		"p95_ms": _percentile(samples, 0.95), "p99_ms": _percentile(samples, 0.99),
		"raw": _echo_raw.duplicate(true), "clock": "client_monotonic_usec_only"}

func _receive_echo_request(sender: int, stage: int, token: String, seq: int, stamp: int) -> void:
	if _role != "host" or not _peers.has(sender) or stage != _echo_stage or token != _echo_token:
		return
	if not _check(seq >= 0 and seq < _count, "Host收到echo合法seq peer=%d" % sender):
		return
	var seen: Dictionary = _echo_host_seen.get(sender, {})
	_check(not seen.has(seq), "Host可靠echo请求不重复peer=%d seq=%d" % [sender, seq])
	seen[seq] = true
	_echo_host_seen[sender] = seen
	if not _echo_active_announced and seq >= 10:
		_echo_active_announced = true
		print("UDP_GAME_ECHO_ACTIVE")  # runner仅在活跃期触发一次300ms断流。
	# sender 在RPC栈中立即取出；严格回到原客户端，不广播，不做跨设备时钟相减。
	_check(_probe.rpc_id(sender, "echo_reply", stage, token, seq, stamp) == OK, "echo按原sender回传peer=%d" % sender)

func _receive_echo_reply(stage: int, token: String, seq: int, stamp: int) -> void:
	if _role != "client" or stage != _echo_stage or token != _echo_token:
		return
	if not _check(_echo_sent.has(seq) and int(_echo_sent.get(seq, -1)) == stamp, "echo身份/seq/stamp匹配"):
		return
	if _echo_received.has(seq):
		_echo_duplicates += 1
		return
	var rtt: float = float(Time.get_ticks_usec() - stamp) / 1000.0
	_echo_received[seq] = rtt
	_echo_raw.append({"seq": seq, "sent_usec": stamp, "rtt_ms": rtt})

func _percentile(sorted: Array, fraction: float) -> float:
	if sorted.is_empty():
		return -1.0
	return float(sorted[clampi(int(ceil(float(sorted.size()) * fraction)) - 1, 0, sorted.size() - 1)])

func _enet_counters() -> Dictionary:
	var result: Dictionary = {}
	var peer: ENetMultiplayerPeer = root.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer != null and peer.host != null:
		# 仅独立测试进程在结束时消费计数，不能拿总发包数当重传次数。
		result = {"sent_bytes": peer.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA),
			"sent_packets": peer.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS),
			"received_bytes": peer.host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA),
			"received_packets": peer.host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS)}
	return result


func _result(ok: bool) -> Dictionary:
	if _enet_final_counters.is_empty():
		_enet_final_counters = _enet_counters()
	return {"ok": ok, "role": _role, "index": _index, "checks": _checks,
		"failures": _failures.duplicate(), "remote_failures": _remote_failures.duplicate(true),
		"items": _items.duplicate(true), "transactions": _transactions.duplicate(true),
		"stages": _stages.duplicate(true), "echo": _echo_summary.duplicate(true),
		"enet": _enet_final_counters, "network": _net.call("get_network_diagnostics"),
		"clients": _client_reports.duplicate(true), "count": _count, "fps": _fps,
		"warnings": ["未测试死亡/气力/ガッツ；不将弱网RTT与20ms阈值比较", "引擎退出残留资源告警由runner另行报告，不替代事务断言"]}

func _finish_host() -> void:
	if _finishing or _finished:
		return
	_finishing = true
	_quiesce_test_world()
	var ok: bool = _failures.is_empty() and _remote_failures.is_empty()
	var result: Dictionary = _result(ok)
	for peer: int in _peers:
		_check(_probe.rpc_id(peer, "finish", ok, result) == OK, "Host可靠finish发送peer=%d" % peer)
	_net.call("flush_transport")
	var deadline: int = Time.get_ticks_msec() + 3000
	while _finish_acks.size() < _peers.size() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_finish_acks.size() == _peers.size(), "所有Client收到finish确认")
	ok = _failures.is_empty() and _remote_failures.is_empty()
	print("UDP_GAME_HOST_RESULT " + JSON.stringify(_result(ok)))
	await create_timer(0.3).timeout
	_finished = true
	_net.call("leave")
	quit(0 if ok else 1)

func _client_finish(host_ok: bool, host_result: Dictionary) -> void:
	if _finished or _finishing or _role != "client":
		return
	_finishing = true
	_quiesce_test_world()
	var ok: bool = host_ok and _failures.is_empty()
	var result: Dictionary = _result(ok)
	result["host_ok"] = host_ok
	result["host_failures"] = host_result.get("failures", [])
	_check(_probe.rpc_id(1, "finish_ack") == OK, "Client可靠finish确认")
	_net.call("flush_transport")
	result["ok"] = host_ok and _failures.is_empty()
	result["failures"] = _failures.duplicate()
	print("UDP_GAME_CLIENT_RESULT " + JSON.stringify(result))
	# Host收到所有finish_ack后先关闭会话，避免多个Client同时离房触发relay收尾竞态。
	await create_timer(0.7).timeout
	_finished = true
	_net.call("leave")
	quit(0 if host_ok and _failures.is_empty() else 1)

func _abort(reason: String) -> void:
	if _finished or _finishing:
		return
	_check(false, reason)
	if _role == "host":
		await _finish_host()
	else:
		print("UDP_GAME_CLIENT_RESULT " + JSON.stringify(_result(false)))
		_finished = true
		_net.call("leave")
		quit(1)

func _quiesce_test_world() -> void:
	var world: Node = _world()
	if world != null:
		# 成功断言之后显式进入切图静默态，测试收尾不继续向离开的peer发世界包。
		world.set("_scene_transitioning", true)
		world.set_process(false)
		world.set_physics_process(false)


func _timeout() -> void:
	if not _finished and not _finishing:
		call_deferred("_abort", "overall_timeout")
