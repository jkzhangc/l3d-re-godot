extends Node2D

## ── 架构定位 ──
## 系统：联机掉落物回归 ｜ 层：专用行为测试
## 从固定物品目录取真实资源，调用生产登记/构建/镜像入口；不写存档。
## 默认单进程；--pickup-peer=host/client 使用27885端口，验证真实生产握手与可靠RPC。
## 验证全目录覆盖、真实外观/坐标/弹药、辅助品、未知ID无幽灵、重复与删除收敛。
const WHITELIST := preload("res://script/network_whitelist.gd")
const CATALOG := preload("res://script/item_catalog_data.gd")
const WEAPON_SCENE := preload("res://object/weapon_pickup.tscn")
const ITEM_SCENE := preload("res://object/healing_pickup.tscn")
const PICKUP := preload("res://script/weapon_pickup.gd")

class TestWorld extends "res://script/network_world.gd":
	var catalog_peer_ready: bool = false
	var catalog_stage_ack: int = -1

	func _ready() -> void:
		set_process(false)
		set_physics_process(false)

	func _exit_tree() -> void:
		pass

	@rpc("any_peer", "call_remote", "reliable")
	func catalog_ready() -> void:
		var sender: int = multiplayer.get_remote_sender_id()
		if net.is_host and net.get_peer_ids().has(sender):
			_ready_client_peers[sender] = true
			catalog_peer_ready = true

	@rpc("any_peer", "call_remote", "reliable")
	func catalog_ack(stage: int) -> void:
		if net.is_host and _ready_client_peers.has(multiplayer.get_remote_sender_id()):
			catalog_stage_ack = stage

var _checks: int = 0
var _failures: int = 0

func _ready() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("NETWORK_PICKUP_CATALOG_CHECK FAIL " + label)

func _run() -> void:
	if "--pickup-peer=host" in OS.get_cmdline_user_args():
		await _run_peer_host()
		return
	if "--pickup-peer=client" in OS.get_cmdline_user_args():
		await _run_peer_client()
		return
	var ground := Node2D.new()
	ground.name = "GroundLayer"
	add_child(ground)
	var host := TestWorld.new()
	add_child(host)
	var client := TestWorld.new()
	add_child(client)
	var resources: Array[ItemData] = []
	var expected: Dictionary = {}
	var weapons: int = 0
	var throwables: int = 0
	var ground_items: int = 0
	for entry: Dictionary in CATALOG.ENTRIES:
		var data: ItemData = load(str(entry["path"])) as ItemData
		if data == null or data.item_type == ItemData.ItemType.AMMO:
			continue
		var resolved: ItemData = null
		if data is WeaponData:
			weapons += 1
			resolved = WHITELIST.weapon_by_id(data.item_id)
		elif data is ThrowableData:
			throwables += 1
			resolved = WHITELIST.throwable_by_id(data.item_id)
		elif data.item_type == ItemData.ItemType.HEALING or data.item_type == ItemData.ItemType.SUPPORT:
			ground_items += 1
			resolved = WHITELIST.ground_item_by_id(data.item_id)
		else:
			continue
		_check(resolved == data, "固定白名单覆盖当前目录 " + data.item_id)
		resources.append(data)
		var pickup: Node2D = (WEAPON_SCENE if data is WeaponData else ITEM_SCENE).instantiate()
		pickup.name = "CatalogPickup%d" % resources.size()
		pickup.set("cap_exempt", true)
		pickup.set("require_function_key", resources.size() % 2 == 0)
		if data is WeaponData:
			PICKUP.apply_weapon_ground_display(pickup, data)
			pickup.set("pickup_reserve_ammo", 0)
			pickup.set("pickup_magazine_ammo", 0)
		else:
			pickup.set("item", data)
		ground.add_child(pickup)
		pickup.position = Vector2(resources.size() * 48, 300)
		pickup.set_process(false)
		var id: int = host._register_host_pickup(pickup)
		expected[id] = {"data": data, "position": pickup.global_position,
			"key": bool(pickup.get("require_function_key"))}
	_check(weapons == WHITELIST.NETWORK_WEAPONS.size(), "全部武器资源与白名单双向覆盖")
	_check(throwables == WHITELIST.NETWORK_THROWABLES.size(), "全部投掷物资源与白名单双向覆盖")
	_check(ground_items == WHITELIST.NETWORK_HEALINGS.size() + WHITELIST.NETWORK_SUPPORTS.size(),
		"全部治疗/辅助资源与白名单双向覆盖")
	var packets: Array = host._build_pickup_snapshot()
	_check(packets.size() == resources.size(), "Host完整登记并编码全部目录")
	for value: Variant in host._pickups.values():
		(value as Node).queue_free()
	host._pickups.clear()
	await get_tree().process_frame
	client._apply_client_pickup_snapshot(packets)
	_check(client._pickups.size() == expected.size(), "Client完整重建全部镜像")
	var instances: Dictionary = {}
	for key: Variant in expected.keys():
		var row: Dictionary = expected[key]
		var data: ItemData = row["data"]
		var node: Node2D = client._pickup_node(int(key))
		_check(is_instance_valid(node), "镜像存在 " + data.item_id)
		if not is_instance_valid(node):
			continue
		instances[key] = node.get_instance_id()
		_check(node.global_position.is_equal_approx(row["position"]), "镜像坐标 " + data.item_id)
		_check(node.visible and bool(node.get("cap_exempt")) and not node.is_in_group("ground_item"),
			"镜像可见且不被本地上限淘汰 " + data.item_id)
		_check(int(node.get("network_pickup_id")) == int(key), "稳定ID " + data.item_id)
		_check(bool(node.get("require_function_key")) == bool(row["key"]), "交互条件跟随Host " + data.item_id)
		var sprite: Sprite2D = node.get_node_or_null("Sprite2D") as Sprite2D
		if data is WeaponData:
			_check(node.get("weapon_data") == data, "武器资源身份 " + data.item_id)
			_check(int(node.get("pickup_reserve_ammo")) == 0 and int(node.get("pickup_magazine_ammo")) == 0,
				"零弹药不被回填 " + data.item_id)
			_check(sprite != null and sprite.texture == node.get("pickup_texture")
				and int(node.get("pickup_char_idx")) == (data as WeaponData).pickup_char_idx,
				"武器真实地面显示 " + data.item_id)
		else:
			_check(node.get("item") == data, "物品资源身份 " + data.item_id)
			_check(sprite != null and sprite.texture != null, "物品真实地面显示 " + data.item_id)
	client._apply_client_pickup_snapshot(packets)
	var stable: bool = true
	for key: Variant in instances.keys():
		stable = stable and client._pickup_node(int(key)).get_instance_id() == int(instances[key])
	_check(stable, "重复快照复用原节点不闪烁或复制")
	var count_before: int = ground.get_child_count()
	var with_unknown: Array = packets.duplicate(true)
	with_unknown.append({"pickup_id": 99999, "pickup_kind": "weapon", "weapon_id": "not_a_game_weapon"})
	with_unknown.append({"pickup_id": 99998, "pickup_kind": "healing", "item_id": "res://object/weapon_mg_01.tres"})
	client._apply_client_pickup_snapshot(with_unknown)
	_check(not client._pickups.has(99999) and not client._pickups.has(99998), "未知ID与路径字符串不会进入镜像表")
	_check(ground.get_child_count() == count_before, "未知ID不实例化默认外观幽灵")
	var removed_id: int = int(packets[0]["pickup_id"])
	var removed: Node2D = client._pickup_node(removed_id)
	packets.remove_at(0)
	client._apply_client_pickup_snapshot(packets)
	_check(not client._pickups.has(removed_id) and removed.is_queued_for_deletion() and not removed.visible,
		"Host移除后Client立即隐藏并销毁")
	await get_tree().process_frame
	client._apply_client_pickup_snapshot([])
	_check(client._pickups.is_empty(), "空权威列表清空全部镜像")
	await get_tree().process_frame
	print("NETWORK_PICKUP_CATALOG_CHECK weapons=%d throwables=%d items=%d checks=%d failures=%d" % [
		weapons, throwables, ground_items, _checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _peer_world() -> TestWorld:
	var ground := Node2D.new()
	ground.name = "GroundLayer"
	add_child(ground)
	var world := TestWorld.new()
	world.name = "NetworkWorld"
	world.net = Net
	add_child(world)
	return world


func _run_peer_host() -> void:
	Net.upnp_enabled = false
	_check(Net.host_game(27885) == OK, "专用端口Host建连")
	var world: TestWorld = _peer_world()
	var ground: Node = get_node("GroundLayer")
	var all_data: Array[ItemData] = []
	for entry: Dictionary in CATALOG.ENTRIES:
		if str(entry["group"]) == "弹药":
			continue
		var data: ItemData = load(str(entry["path"])) as ItemData
		if data == null:
			continue
		all_data.append(data)
		var pickup: Node2D = (WEAPON_SCENE if data is WeaponData else ITEM_SCENE).instantiate()
		pickup.name = "PeerPickup%d" % all_data.size()
		pickup.set("cap_exempt", true)
		pickup.set("require_function_key", all_data.size() % 2 == 0)
		if data is WeaponData:
			PICKUP.apply_weapon_ground_display(pickup, data)
			pickup.set("pickup_reserve_ammo", 0)
			pickup.set("pickup_magazine_ammo", 0)
		else:
			pickup.set("item", data)
		ground.add_child(pickup)
		pickup.position = Vector2(all_data.size() * 48, 300)
		pickup.set_process(false)
		world._register_host_pickup(pickup)
	var deadline: int = Time.get_ticks_msec() + 15000
	while not world.catalog_peer_ready and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.02).timeout
	_check(world.catalog_peer_ready, "客户端同路径就绪")
	for stage: int in 3:
		if not world.catalog_peer_ready:
			break
		if stage == 2:
			var removed: Node2D = world._pickup_node(1)
			world._pickups.erase(1)
			removed.queue_free()
		world._send_pickup_snapshot_to_ready_clients()
		deadline = Time.get_ticks_msec() + 5000
		while world.catalog_stage_ack < stage and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.02).timeout
		_check(world.catalog_stage_ack == stage, "Client确认一致阶段%d" % stage)
	print("NETWORK_PICKUP_PEER_HOST checks=%d failures=%d" % [_checks, _failures])
	await get_tree().create_timer(0.2).timeout
	Net.leave()
	get_tree().quit(0 if _failures == 0 else 1)


func _run_peer_client() -> void:
	_check(Net.join_game("127.0.0.1", 27885) == OK, "专用端口Client建连")
	var world: TestWorld = _peer_world()
	var deadline: int = Time.get_ticks_msec() + 12000
	while not Net.is_online_session() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.02).timeout
	_check(Net.is_online_session(), "生产握手成功")
	if not Net.is_online_session():
		get_tree().quit(1)
		return
	world.catalog_ready.rpc_id(1)
	var all_data: Array[ItemData] = []
	for entry: Dictionary in CATALOG.ENTRIES:
		if str(entry["group"]) != "弹药":
			var data: ItemData = load(str(entry["path"])) as ItemData
			if data != null:
				all_data.append(data)
	var original_instances: Dictionary = {}
	for stage: int in 3:
		deadline = Time.get_ticks_msec() + 8000
		while int(world._last_dynamic_epochs[&"pickup"]) < stage + 1 and Time.get_ticks_msec() < deadline:
			await get_tree().create_timer(0.02).timeout
		_check(int(world._last_dynamic_epochs[&"pickup"]) == stage + 1, "可靠RPC收到阶段%d" % stage)
		_check(world._pickups.size() == all_data.size() - (1 if stage == 2 else 0), "两端完整集合一致阶段%d" % stage)
		for index: int in all_data.size():
			var id: int = index + 1
			if stage == 2 and id == 1:
				_check(not world._pickups.has(id), "可靠删除收敛")
				continue
			var node: Node2D = world._pickup_node(id)
			var data: ItemData = all_data[index]
			_check(is_instance_valid(node), "RPC镜像存在 " + data.item_id)
			if not is_instance_valid(node):
				continue
			var actual: ItemData = node.get("weapon_data") as WeaponData if data is WeaponData else node.get("item") as ItemData
			_check(actual == data and node.visible and node.global_position.is_equal_approx(Vector2(id * 48, 300)),
				"RPC内容坐标可见性一致 " + data.item_id)
			_check(bool(node.get("require_function_key")) == (id % 2 == 0), "RPC交互条件一致 " + data.item_id)
			if stage == 0:
				original_instances[id] = node.get_instance_id()
			else:
				_check(int(original_instances[id]) == node.get_instance_id(), "RPC重同步不重建 " + data.item_id)
		world.catalog_ack.rpc_id(1, stage)
		Net.flush_transport()
	print("NETWORK_PICKUP_PEER_CLIENT items=%d checks=%d failures=%d" % [all_data.size(), _checks, _failures])
	await get_tree().create_timer(0.1).timeout
	Net.leave()
	get_tree().quit(0 if _failures == 0 else 1)
