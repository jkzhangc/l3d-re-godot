extends Node

## ── 架构定位 ──
## 系统：联机快照回归 ｜ 层：专用行为测试
## 直接调用生产接收入口、epoch helper、列表收敛及广播调度，不创建网络连接。
## 仅替换实体表现/座位注册和最终 RPC 发送边界；不复制待测门控逻辑。
## 入口：godot --headless --path <项目目录> res://tools/network_snapshot_stream_check.tscn

class NetStub extends RefCounted:
	var is_host: bool = false
	var my_peer_id: int = 2
	var peers: Array = [1, 2, 3, 4]

	func get_peer_ids() -> Array:
		return peers


class PickupStub extends Node2D:
	var item: ItemData = null
	var weapon_data: WeaponData = null
	var refreshes: int = 0
	var configured_id: int = 0
	var disabled: bool = false

	func _refresh_sprite() -> void:
		refreshes += 1

	func configure_network_pickup(pickup_id: int, _is_weapon: bool) -> void:
		configured_id = pickup_id

	func reset_network_pickup_request() -> void:
		pass

	func disable_network_pickup() -> void:
		disabled = true
		hide()


class TestWorld extends "res://script/network_world.gd":
	var player_calls: Array = []
	var enemy_calls: Array = []
	var builds: Array[int] = [0, 0, 0]
	var sent: Array = []
	var compact_requested: bool = false

	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
		_quest_flags_synced = true

	func _exit_tree() -> void:
		pass

	func _is_net_test_session() -> bool:
		return false

	func _reconcile_network_seats(_peer_ids: Array[int]) -> void:
		pass

	## 真实 _apply_client_snapshot 仍负责解析、遍历、收敛与移除。
	## 此处只记录交给表现层的动态开关，避免创建完整 Player/状态机。
	func _ensure_client_player(peer_id: int, public_state: Dictionary, snap: bool,
			apply_dynamic: bool = true) -> void:
		player_calls.append([peer_id, snap, apply_dynamic])
		var entry: Dictionary = _players.get(peer_id, {})
		if entry.is_empty():
			var node := CharacterBody2D.new()
			add_child(node)
			entry = {"node": node, "hp": -1.0}
		entry["cold"] = public_state.get("cold", entry.get("cold", ""))
		if apply_dynamic:
			(entry["node"] as CharacterBody2D).position = public_state.get("position", Vector2.ZERO)
			entry["hp"] = public_state.get("hp", -1.0)
		_players[peer_id] = entry

	func _ensure_client_enemy(entity_id: int, public_state: Dictionary, snap: bool,
			apply_dynamic: bool = true) -> void:
		enemy_calls.append([entity_id, snap, apply_dynamic])
		var entry: Dictionary = _enemies.get(entity_id, {})
		if entry.is_empty():
			var node := CharacterBody2D.new()
			add_child(node)
			entry = {"node_id": node.get_instance_id(), "hp": -1.0}
		entry["cold"] = public_state.get("cold", entry.get("cold", ""))
		if apply_dynamic:
			var node := instance_from_id(int(entry["node_id"])) as CharacterBody2D
			node.position = public_state.get("position", Vector2.ZERO)
			entry["hp"] = public_state.get("hp", -1.0)
		_enemies[entity_id] = entry

	func _build_snapshot() -> Array:
		builds[0] += 1
		return [{"player_build": builds[0]}]

	func _build_enemy_snapshot(compact: bool = false) -> Array:
		builds[1] += 1
		compact_requested = compact
		return [{"enemy_build": builds[1]}]

	func _build_pickup_snapshot() -> Array:
		builds[2] += 1
		return [{"pickup_build": builds[2]}]

	func _send_world_snapshot_payload(peer_id: int, snapshot_epoch: int,
			player_states: Array, enemy_states: Array, pickup_states: Array) -> void:
		sent.append([peer_id, snapshot_epoch, player_states, enemy_states, pickup_states])


var _checks: int = 0
var _failures: int = 0


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("NETWORK_SNAPSHOT_STREAM_CHECK %s %s" % ["PASS" if ok else "FAIL", label])


func _world() -> TestWorld:
	var world := TestWorld.new()
	world.net = NetStub.new()
	add_child(world)
	return world


func _player(peer_id: int, value: float, cold: String = "new") -> Dictionary:
	return {"peer_id": peer_id, "position": Vector2(value, 0), "hp": value, "cold": cold}


func _enemy(entity_id: int, value: float, cold: String = "new") -> Dictionary:
	return {"entity_id": entity_id, "position": Vector2(value, 0), "hp": value, "cold": cold}


func _pickup(pickup_id: int, value: float) -> Dictionary:
	return {"pickup_id": pickup_id, "pickup_kind": "healing",
		"item_id": "first_aid_spray", "position": Vector2(value, 0)}


func _seed_pickup(world: TestWorld, pickup_id: int) -> PickupStub:
	var pickup := PickupStub.new()
	world.add_child(pickup)
	pickup.position = Vector2(10, 0)
	world._pickups[pickup_id] = pickup
	return pickup


func _test_actual_helper() -> void:
	var world := _world()
	_check(world._accept_dynamic_epoch(102, &"enemy"), "实际 helper 接受敌人 102")
	_check(world._accept_dynamic_epoch(101, &"player"), "实际 helper 不因敌人 102 丢玩家 101")
	_check(world._accept_dynamic_epoch(100, &"pickup"), "实际 helper 不跨流丢掉落物 100")
	for stream: StringName in [&"player", &"enemy", &"pickup"]:
		_check(world._accept_dynamic_epoch(110, stream), "%s 接受更新版本" % stream)
		_check(world._accept_dynamic_epoch(110, stream), "%s 同版本允许可靠包/分片" % stream)
		_check(not world._accept_dynamic_epoch(109, stream), "%s 拒绝本流乱序旧版本" % stream)
	_check(not world._accept_dynamic_epoch(109), "单参数旧入口仍使用真实 player 水位")
	world.free()


func _test_hot_streams_and_chunks() -> void:
	var world := _world()
	world.player_snapshot(102, 1, [_enemy(1, 102)])
	world.player_position_snapshot(101, [_player(3, 101)])
	_check(world._players[3]["hp"] == 101.0, "实际热入口：enemy102 不淘汰 player101")
	world.player_position_snapshot(101, [_player(3, 999)])
	world.player_position_snapshot(100, [_player(3, 999)])
	_check(world.player_calls.size() == 1, "玩家热包重复/乱序不进入应用层")
	world.player_position_snapshot(105, [_player(3, 105)])
	world.player_snapshot(102, 0, [_enemy(2, 102)])
	_check(world._enemies.has(2), "较新玩家包到达后，同轮敌人另一分片仍应用")
	world.player_snapshot(102, 1, [_enemy(1, 999)])
	world.player_snapshot(101, 2, [_enemy(3, 999)])
	_check(world.enemy_calls.size() == 2 and world._enemies[1]["hp"] == 102.0,
		"敌人同轮重复序号及跨轮旧片不应用")
	world.player_snapshot(104, 1, [_enemy(1, 104)])
	world.player_snapshot(104, 0, [_enemy(2, 104)])
	_check(world._enemies[1]["hp"] == 104.0 and world._enemies[2]["hp"] == 104.0,
		"敌人新轮清空分片集合，片序倒置也可应用")
	world.free()


func _test_world_stream_matrix() -> void:
	## 三类新鲜度的全部八种组合；真实 world/各 apply 函数决定列表是否收敛。
	for mask: int in range(8):
		var world := _world()
		world._ensure_client_player(3, _player(3, 10, "old"), false)
		world._ensure_client_player(4, _player(4, 10, "old"), false)
		world._ensure_client_enemy(1, _enemy(1, 10, "old"), false)
		world._ensure_client_enemy(2, _enemy(2, 10, "old"), false)
		var pickup := _seed_pickup(world, 1)
		var extra := _seed_pickup(world, 2)
		var streams: Array[StringName] = [&"player", &"enemy", &"pickup"]
		for index: int in range(3):
			world._accept_dynamic_epoch(200 if (mask & (1 << index)) != 0 else 90, streams[index])
		world.world_snapshot(100, [_player(3, 100)], [_enemy(1, 100)], [_pickup(1, 100)])
		var player_ok: bool = (mask & 1) == 0
		var enemy_ok: bool = (mask & 2) == 0
		var pickup_ok: bool = (mask & 4) == 0
		var label: String = "world 各流独立 mask=%d" % mask
		_check(world._players[3]["hp"] == (100.0 if player_ok else 10.0)
			and world._players.has(4) == not player_ok, label + " 玩家动态/旧列表保护")
		_check(world._enemies[1]["hp"] == (100.0 if enemy_ok else 10.0)
			and world._enemies.has(2) == not enemy_ok, label + " 敌人动态/旧列表保护")
		_check(pickup.position.x == (100.0 if pickup_ok else 10.0)
			and world._pickups.has(2) == not pickup_ok
			and extra.is_queued_for_deletion() == pickup_ok, label + " 掉落物动态/旧列表保护")
		_check(world._players[3]["cold"] == "new" and world._enemies[1]["cold"] == "new",
			label + " 过时可靠仍交付低频数据")
		_check(world.player_calls.back()[1] == player_ok and world.player_calls.back()[2] == player_ok
			and world.enemy_calls.back()[1] == enemy_ok and world.enemy_calls.back()[2] == enemy_ok,
			label + " 实际应用参数匹配各流新鲜度")
		var player_calls: int = world.player_calls.size()
		var enemy_calls: int = world.enemy_calls.size()
		world.world_snapshot(100, [], [], [])
		world.world_snapshot(99, [], [], [])
		_check(world.player_calls.size() == player_calls and world.enemy_calls.size() == enemy_calls
			and world._pickups.has(1), label + " 重复/乱序可靠全量整体忽略")
		world.free()


func _test_pickup_stream() -> void:
	var world := _world()
	var pickup := _seed_pickup(world, 1)
	world.player_position_snapshot(201, [_player(3, 201)])
	world.player_snapshot(202, 0, [_enemy(1, 202)])
	world.pickup_snapshot(200, [_player(3, 200, "pickup-cold")], [_pickup(1, 200)])
	_check(pickup.position.x == 200 and pickup.refreshes == 1,
		"旧于玩家/敌人但本流最新的 pickup 列表必须应用")
	_check(world._players[3]["hp"] == 201.0 and world._players[3]["cold"] == "pickup-cold",
		"pickup 可靠包独立保护玩家动态且仍补低频")
	world.world_snapshot(199, [_player(3, 199)], [_enemy(1, 199)], [])
	_check(world._pickups.has(1) and pickup.refreshes == 1,
		"world 旧于 pickup 水位时不按空旧列表误删掉落物")
	world.pickup_snapshot(198, [_player(3, 198, "older-cold")], [])
	_check(world._pickups.has(1) and world._players[3]["hp"] == 201.0,
		"乱序 pickup 旧列表不误删，玩家动态不回退")
	world.pickup_snapshot(203, [_player(3, 203)], [_pickup(1, 203)])
	world.player_position_snapshot(202, [_player(3, 999)])
	world.player_snapshot(202, 1, [_enemy(2, 202)])
	_check(world._players[3]["hp"] == 203.0 and world._enemies.has(2),
		"pickup 推进 player 但不推进 enemy；迟到敌人同轮分片仍生效")
	world.pickup_snapshot(204, [], [])
	_check(world._pickups.is_empty() and pickup.is_queued_for_deletion(),
		"新 pickup 空列表仍能收敛移除，玩家列表不由 pickup 收敛")
	_check(world._players.has(3), "pickup 空玩家数组不删除新玩家")
	world.free()


func _test_reliable_vs_hot() -> void:
	var world := _world()
	world.world_snapshot(100, [_player(3, 100)], [_enemy(1, 100)], [])
	world.player_position_snapshot(99, [_player(3, 999)])
	world.player_snapshot(99, 0, [_enemy(1, 999)])
	_check(world._players[3]["hp"] == 100.0 and world._enemies[1]["hp"] == 100.0,
		"新可靠全量之后，两个流都拒绝迟到旧热包")
	world.player_snapshot(101, 0, [_enemy(1, 101)])
	world.world_snapshot(101, [_player(3, 101)], [_enemy(1, 101)], [])
	world.player_snapshot(101, 1, [_enemy(2, 101)])
	_check(world._enemies.has(2) and world._players[3]["hp"] == 101.0,
		"同版本可靠/热包交错后，未见过的敌人分片仍应用")
	world.free()


func _test_authority_and_ready() -> void:
	var world := _world()
	world.net.is_host = true
	world.world_snapshot(100, [_player(3, 100)], [_enemy(1, 100)], [])
	world.pickup_snapshot(100, [_player(3, 100)], [])
	world.player_position_snapshot(100, [_player(3, 100)])
	world.player_snapshot(100, 0, [_enemy(1, 100)])
	_check(world.player_calls.is_empty() and world.enemy_calls.is_empty()
		and world._last_reliable_world_epoch == -1, "Host 拒绝全部客户端镜像入口")
	world.net.is_host = false
	world._client_local_ready = true
	_check(not world._client_ready_to_send(), "本地 ready 不足以放行上行 RPC")
	world.player_position_snapshot(101, [_player(2, 101)])
	_check(not world._client_ready_to_send(), "热包创建本机实体仍不能代替初始 world gating")
	world.world_snapshot(100, [_player(2, 100)], [], [])
	_check(world._initial_world_received and world._client_ready_to_send(),
		"过时可靠全量仍完成本机初始 world ready，不回退 gating")
	world._client_local_ready = false
	_check(not world._client_ready_to_send(), "收到 world 后仍要求本地 ready")
	world._scene_transitioning = true
	var count: int = world.player_calls.size()
	world.pickup_snapshot(300, [_player(2, 300)], [])
	_check(world.player_calls.size() == count, "切图期间 pickup 入口保持静默")
	world.free()


func _test_build_once() -> void:
	var world := _world()
	world.net.is_host = true
	world._ready_client_peers = {2: true, 3: true, 9: true}
	world._broadcast_reliable_world_snapshot()
	_check(world.builds == [1, 1, 1] and not world.compact_requested,
		"多个 ready peer 的可靠广播只构建三类 payload 各一次，敌人使用全量格式")
	_check(world.sent.size() == 2 and world.sent[0][0] == 2 and world.sent[1][0] == 3,
		"只发 ready 且在线目标，排除在线未 ready 的4与离线9")
	_check(world._snapshot_epoch == 1 and world.sent[0][1] == world.sent[1][1],
		"一次广播只占一个 epoch，多 peer 同轮")
	_check(is_same(world.sent[0][2], world.sent[1][2])
		and is_same(world.sent[0][3], world.sent[1][3])
		and is_same(world.sent[0][4], world.sent[1][4]), "多 peer 复用同一组三类 payload 对象")
	world._broadcast_reliable_world_snapshot()
	_check(world.builds == [2, 2, 2] and world._snapshot_epoch == 2,
		"下一轮重新构建一次，不跨轮缓存旧 payload")
	world._ready_client_peers = {9: true}
	world._broadcast_reliable_world_snapshot()
	_check(world.builds == [2, 2, 2] and world.sent.size() == 4 and world._snapshot_epoch == 2,
		"无在线 ready 目标不构建、不发送、不消耗版本")
	world._ready_client_peers = {2: true}
	world._scene_transitioning = true
	world._broadcast_reliable_world_snapshot()
	world._send_reliable_world_snapshot(2)
	_check(world.builds == [2, 2, 2] and world.sent.size() == 4,
		"切图广播及单目标初始化均不构建/发送")
	world._scene_transitioning = false
	world.net.is_host = false
	world._broadcast_reliable_world_snapshot()
	world._send_reliable_world_snapshot(2)
	_check(world.builds == [2, 2, 2], "非 Host 不能构建发送可靠全量")
	world.net.is_host = true
	world._send_reliable_world_snapshot(1)
	_check(world.builds == [2, 2, 2], "单目标发送不接受 Host 自己")
	world._send_reliable_world_snapshot(2)
	_check(world.builds == [3, 3, 3] and world.sent.size() == 5 and world._snapshot_epoch == 3,
		"单目标 ready 初始化保持独立全量构建与发送入口")
	world.free()


func _run() -> void:
	_test_actual_helper()
	_test_hot_streams_and_chunks()
	_test_world_stream_matrix()
	_test_pickup_stream()
	_test_reliable_vs_hot()
	_test_authority_and_ready()
	_test_build_once()
	print("NETWORK_SNAPSHOT_STREAM_CHECK checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
