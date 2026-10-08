extends "res://script/network_world.gd"

## --net-test 无头回归专用子类：仅在命令行带 `--net-test` 前缀参数时由 game_init 实例化，
## 生产环境永远不会加载它。此文件从 network_world.gd 原样搬出全部自动回归编排代码
## （_is_auto_* 谓词覆写、_run_auto_* 协程、测试助手与 3 个 multi_disconnect_* RPC），
## 不改动任何网络协议 / 游戏逻辑。基类保留恒 false 的同名谓词 stub 以守护生产派发分支。


# ---------------------------------------------------------------- Automated smoke input

## 受控双端回归：生产安全门仍只接受真实本地按键请求；此逻辑只在显式无头测试参数下运行。
func _is_auto_multi_disconnect_test() -> bool:
	return "--net-test-multi-disconnect" in OS.get_cmdline_user_args()


func _get_auto_client_role() -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-client-role="):
			return argument.trim_prefix("--net-test-client-role=").strip_edges().to_lower()
	return ""


func _are_network_seats_reconciled(expected_peer_ids: Array[int]) -> bool:
	if Players.seat_count() != expected_peer_ids.size():
		return false
	var expected := expected_peer_ids.duplicate()
	expected.sort()
	var owners: Array[int] = []
	for seat_index: int in range(Players.seat_count()):
		var state := Players.get_seat(seat_index)
		if not state:
			return false
		owners.append(state.owner_peer_id)
	return owners == expected


@rpc("authority", "call_remote", "reliable")
func multi_disconnect_complete() -> void:
	if not net.is_host:
		_auto_multi_disconnect_complete = true


@rpc("any_peer", "call_remote", "reliable")
func multi_disconnect_ack() -> void:
	if not net.is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if peer_id > 1 and peer_id in net.get_peer_ids():
		_auto_multi_disconnect_acks[peer_id] = true


@rpc("authority", "call_remote", "reliable")
func multi_disconnect_release() -> void:
	if not net.is_host:
		_auto_multi_disconnect_release = true


func _get_auto_expected_player_count() -> int:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--net-test-players="):
			return clampi(int(argument.trim_prefix("--net-test-players=")), 3, 4)
	return 3


func _run_auto_host_multi_disconnect_test() -> void:
	var initial_count := _get_auto_expected_player_count()
	var remaining_count := initial_count - 1
	var deadline := Time.get_ticks_msec() + 12000
	while (net.get_peer_ids().size() < initial_count or _players.size() < initial_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if net.get_peer_ids().size() != initial_count or _players.size() != initial_count:
		printerr("[NetworkWorld] AUTO_MULTI_HOST_SETUP_FAILED peers=%d players=%d seats=%d expected=%d" % [net.get_peer_ids().size(), _players.size(), Players.seat_count(), initial_count])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
	deadline = Time.get_ticks_msec() + 12000
	while (net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids()):
		printerr("[NetworkWorld] AUTO_MULTI_HOST_DISCONNECT_FAILED peers=%d players=%d seats=%d expected=%d" % [net.get_peer_ids().size(), _players.size(), Players.seat_count(), remaining_count])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_DISCONNECT_COMPLETE peers=%d players=%d seats=%d" % [remaining_count, remaining_count, remaining_count])
	_auto_multi_disconnect_acks.clear()
	multi_disconnect_complete.rpc()
	deadline = Time.get_ticks_msec() + 12000
	while _auto_multi_disconnect_acks.size() < remaining_count - 1 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host:
		return
	if _auto_multi_disconnect_acks.size() != remaining_count - 1:
		printerr("[NetworkWorld] AUTO_MULTI_HOST_ACK_FAILED received=%d expected=%d" % [_auto_multi_disconnect_acks.size(), remaining_count - 1])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_HOST_ACK_COMPLETE clients=%d" % _auto_multi_disconnect_acks.size())
	multi_disconnect_release.rpc()
	await get_tree().create_timer(0.75).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


func _run_auto_client_multi_disconnect_test() -> void:
	var role := _get_auto_client_role()
	var initial_count := _get_auto_expected_player_count()
	var remaining_count := initial_count - 1
	var deadline := Time.get_ticks_msec() + 12000
	while (_players.size() < initial_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or net.is_host:
		return
	if _players.size() != initial_count or Players.seat_count() != initial_count:
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_SETUP_FAILED role=%s peers=%d players=%d seats=%d expected=%d" % [role, net.get_peer_ids().size(), _players.size(), Players.seat_count(), initial_count])
		net.leave()
		get_tree().quit(1)
		return
	if role == "drop":
		print("[NetworkWorld] AUTO_MULTI_CLIENT_DROP_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
		await get_tree().create_timer(0.50).timeout
		net.leave()
		get_tree().quit()
		return
	if role != "stay":
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_ROLE_FAILED role=%s" % role)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_READY peers=%d players=%d seats=%d" % [initial_count, initial_count, initial_count])
	deadline = Time.get_ticks_msec() + 12000
	while (not _auto_multi_disconnect_complete or net.get_peer_ids().size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(net.get_peer_ids())) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var expected_peer_ids: Array[int] = net.get_peer_ids()
	if not _auto_multi_disconnect_complete or expected_peer_ids.size() != remaining_count or _players.size() != remaining_count or not _are_network_seats_reconciled(expected_peer_ids):
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_FAILED complete=%s peers=%d players=%d seats=%d expected=%d" % [_auto_multi_disconnect_complete, expected_peer_ids.size(), _players.size(), Players.seat_count(), remaining_count])
		net.leave()
		get_tree().quit(1)
		return
	multi_disconnect_ack.rpc_id(1)
	deadline = Time.get_ticks_msec() + 12000
	while not _auto_multi_disconnect_release and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _auto_multi_disconnect_release:
		printerr("[NetworkWorld] AUTO_MULTI_CLIENT_RELEASE_FAILED role=%s" % role)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_MULTI_CLIENT_STAY_COMPLETE peers=%d players=%d seats=%d" % [remaining_count, remaining_count, remaining_count])
	net.leave()
	get_tree().quit()

## --net-test=slow-host-ready 专用：回归"Client 的 scene-ready 报告先于 Host 场景
## 就绪到达"的竞态。必须让 Host 进程同时携带 --net-test-host-scene-delay-ms=N
## （由 game_init.gd 延迟创建 NetworkWorld），否则 Client 的 ready 不会落入缓冲窗口。
## 修复前该竞态会吞掉 ready 记录：_ready_client_peers 永远为空、世界快照永不发出，
## Client 画面永久卡死 —— 正是手工对局中"客户端卡住"的根因。
func _is_auto_slow_host_ready_test() -> bool:
	return "--net-test=slow-host-ready" in OS.get_cmdline_user_args()


## Host 端断言：竞态发生后，Client 仍被纳入 _ready_client_peers 且可靠世界快照
## 最终被补发（计数 > 0）。
func _run_auto_host_slow_host_ready_test() -> void:
	var deadline := Time.get_ticks_msec() + 12000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _ready_client_peers.is_empty():
		printerr("[NetworkWorld] AUTO_SLOWHOST_HOST_FAILED ready_peers_empty")
		get_tree().quit(1)
		return
	deadline = Time.get_ticks_msec() + 4000
	while _auto_world_snapshot_sent_count <= 0 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _auto_world_snapshot_sent_count <= 0:
		printerr("[NetworkWorld] AUTO_SLOWHOST_HOST_FAILED no_world_snapshot_sent")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_SLOWHOST_HOST_COMPLETE snapshots=%d ready_peers=%d" % [_auto_world_snapshot_sent_count, _ready_client_peers.size()])
	await get_tree().create_timer(0.30).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


## Client 端断言：收到可靠世界快照（_initial_world_received）、Host 实体已在本端
## 重建 —— 即"Client 先就绪"的会话里远端精灵能够正常刷出。
func _run_auto_client_slow_host_ready_test() -> void:
	var deadline := Time.get_ticks_msec() + 12000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var host_node := _player_node(_players.get(1, {}))
	if not _initial_world_received or _players.size() < 2 or not is_instance_valid(host_node):
		printerr("[NetworkWorld] AUTO_SLOWHOST_CLIENT_FAILED world=%s players=%d host_node=%s" % [
			str(_initial_world_received), _players.size(), str(is_instance_valid(host_node))])
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_SLOWHOST_CLIENT_COMPLETE players=%d" % _players.size())
	await get_tree().create_timer(0.40).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


## --net-test=downed-wipe 专用：验证倒地流血 → 真死亡 → 团灭黑屏 → 重载本章收敛。
## 团灭会触发一次真实换图，因此用 Engine meta（跨场景存活、随进程结束）区分两次进图：
## 第一次进图执行"双端倒地 → 加速流血 → 团灭触发"，第二次进图只做恢复验证后退出。
## 正式游戏绝不会进入这些分支。
func _is_auto_team_wipe_test() -> bool:
	return "--net-test=downed-wipe" in OS.get_cmdline_user_args()


## 第一次进图的 Host 场景：等 Client 就位后，用与真实敌人完全一致的生产伤害链路
## （CharacterBody2D.take_damage → network_damage_applied 信号）把双端同时打到 0 ——
## 双端同时倒地 → 无站立玩家 → 满足团灭条件。真实流血需 20 秒，测试把权威流血池
## 压到 0.4 令其在下一帧耗尽。触发后场景由 _update_host_wipe 走切图协议重载，
## 本协程到此结束 —— 绝不能在这里 leave()/quit()，否则切图协议中断。
func _run_auto_host_team_wipe_test() -> void:
	if Engine.has_meta("l3d_auto_team_wipe_stage"):
		_run_auto_host_team_wipe_verify()
		return
	Engine.set_meta("l3d_auto_team_wipe_stage", 1)
	var deadline := Time.get_ticks_msec() + 8000
	while (_players.size() < 2 or net.get_peer_ids().size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var client_id := 0
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			client_id = peer_id
			break
	var host_node := _player_node(_players.get(int(net.my_peer_id), {}))
	var client_node := _player_node(_players.get(client_id, {}))
	if client_id <= 1 or not is_instance_valid(host_node) or not is_instance_valid(client_node):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_SETUP_FAILED client=%d" % client_id)
		get_tree().quit(1)
		return
	# 生产伤害入口：伤害信号同步把玩家登记为权威倒地（_handle_host_player_downed）。
	# ガッツ（HP≥2 保底 1 HP）会拦下 max_hp+1 的致死伤 → 永远不倒地（DOWN_FAILED 假红），
	# 先压 HP=1 再打（take_damage 链路原样保留）。
	_force_auto_test_player_low_hp(client_node)
	_force_auto_test_player_low_hp(host_node)
	client_node.take_damage(client_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998900)
	host_node.take_damage(host_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998901)
	deadline = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		var host_entry_now := _players.get(int(net.my_peer_id), {}) as Dictionary
		var client_entry_now := _players.get(client_id, {}) as Dictionary
		if bool(host_entry_now.get("downed", false)) and bool(client_entry_now.get("downed", false)):
			break
		await get_tree().create_timer(0.05).timeout
	var host_entry := _players.get(int(net.my_peer_id), {}) as Dictionary
	var client_entry := _players.get(client_id, {}) as Dictionary
	if not (bool(host_entry.get("downed", false)) and bool(client_entry.get("downed", false))):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_DOWN_FAILED host=%s client=%s" % [
			str(bool(host_entry.get("downed", false))), str(bool(client_entry.get("downed", false)))])
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_DOWNED_OK")
	# 加速流血：直接改写权威流血池（Host 是唯一写入者），下一帧 _update_host_downed
	# 就会耗尽转真死亡，随后 _check_host_team_wipe 立即命中"全员非站立"。
	host_entry["downed_hp"] = 0.4
	_players[int(net.my_peer_id)] = host_entry
	client_entry["downed_hp"] = 0.4
	_players[client_id] = client_entry
	deadline = Time.get_ticks_msec() + 4000
	while not _wipe_active and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _wipe_active:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_TRIGGER_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_TRIGGERED scene=%s" % _scene_path)
	# 黑屏淡出 + 停留结束后自动换图；本实例的职责到此为止。


## 第一次进图的 Client 场景。验证两点：
## 1) 快照把 downed=true 同步到本地 entry（救援筛选与生命三态判定的数据来源）；
## 2) team_wipe_presentation 广播把本地 _wipe_active 置位（黑屏 + 输入冻结）。
## 之后等待换图，不主动退出。
func _run_auto_client_team_wipe_test() -> void:
	if Engine.has_meta("l3d_auto_team_wipe_stage"):
		_run_auto_client_team_wipe_verify()
		return
	Engine.set_meta("l3d_auto_team_wipe_stage", 1)
	var deadline := Time.get_ticks_msec() + 8000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received or _players.size() < 2:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_SETUP_FAILED world=%s players=%d" % [str(_initial_world_received), _players.size()])
		get_tree().quit(1)
		return
	var local_entry := _players.get(int(net.my_peer_id), {}) as Dictionary
	deadline = Time.get_ticks_msec() + 4000
	while not bool(local_entry.get("downed", false)) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		local_entry = _players.get(int(net.my_peer_id), {}) as Dictionary
	if not bool(local_entry.get("downed", false)):
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_DOWN_FLAG_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_DOWNED_OK")
	deadline = Time.get_ticks_msec() + 4000
	while not _wipe_active and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _wipe_active:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_FADE_FAILED")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_FADE_OK")


## 第二次进图（团灭重载后）的 Host 验证：客户端已回到场景，所有会话状态满血
## （团灭重置 + spawn 兜底），且没有任何玩家带着倒地/死亡 entry 标记。
func _run_auto_host_team_wipe_verify() -> void:
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_STAGE scene=%s" % _scene_path)
	var deadline := Time.get_ticks_msec() + 10000
	while (_players.size() < 2 or _ready_client_peers.is_empty()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _players.size() < 2 or _ready_client_peers.is_empty():
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_FAILED players=%d ready=%d" % [_players.size(), _ready_client_peers.size()])
		get_tree().quit(1)
		return
	var ok := true
	for value: Variant in _players.keys():
		var entry := _players[int(value)] as Dictionary
		var state := entry.get("state") as PlayerState
		if not state or state.current_hp <= 0.0:
			ok = false
		if bool(entry.get("downed", false)) or bool(entry.get("dead", false)):
			ok = false
	if not ok:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_HOST_VERIFY_FAILED hp_or_state")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_HOST_RECOVERY_COMPLETE players=%d" % _players.size())
	await get_tree().create_timer(0.30).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


## 第二次进图（团灭重载后）的 Client 验证：收到可靠世界快照，本地玩家站立且 HP>0。
func _run_auto_client_team_wipe_verify() -> void:
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_STAGE scene=%s" % _scene_path)
	var deadline := Time.get_ticks_msec() + 10000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received or _players.size() < 2:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_FAILED no_world")
		get_tree().quit(1)
		return
	var local_node := _player_node(_players.get(int(net.my_peer_id), {}))
	if not is_instance_valid(local_node) or local_node.is_network_dead() or local_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_VERIFY_FAILED not_standing")
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_TEAM_WIPE_CLIENT_RECOVERY_COMPLETE hp=%.1f" % local_node.current_hp)
	await get_tree().create_timer(0.80).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


func _is_auto_network_feature_test() -> bool:
	return "--net-test-features" in OS.get_cmdline_user_args()


func _is_auto_character_select_test() -> bool:
	return "--net-test-character-select" in OS.get_cmdline_user_args()


func _run_auto_host_character_select_world_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	var client_id := 0
	while Time.get_ticks_msec() < deadline:
		for peer_id: int in net.get_peer_ids():
			if peer_id > 1:
				client_id = peer_id
				break
		var host_state := (_players.get(int(net.my_peer_id), {}).get("state") as PlayerState)
		var client_state := (_players.get(client_id, {}).get("state") as PlayerState)
		if client_id > 1 and host_state and client_state:
			break
		await get_tree().create_timer(0.05).timeout
	var host_state := (_players.get(int(net.my_peer_id), {}).get("state") as PlayerState)
	var client_state := (_players.get(client_id, {}).get("state") as PlayerState)
	var host_expected := str(net.get_player_character_path(int(net.my_peer_id)))
	var client_expected := str(net.get_player_character_path(client_id))
	if client_id <= 1 or not host_state or not client_state or host_state.character_path != host_expected or client_state.character_path != client_expected:
		printerr("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_FAILED host=%s/%s client=%s/%s" % [host_state.character_path if host_state else "<none>", host_expected, client_state.character_path if client_state else "<none>", client_expected])
		get_tree().quit(1)
		return
	deadline = Time.get_ticks_msec() + 6000
	while not _auto_character_world_acks.has(client_id) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _auto_character_world_acks.has(client_id):
		printerr("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_FAILED missing_client_ack peer=%d" % client_id)
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_CHARACTER_HOST_WORLD_COMPLETE host=%s client=%s" % [host_state.character_path.get_file(), client_state.character_path.get_file()])
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _run_auto_client_character_select_world_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while (not _initial_world_received or _players.size() < 2) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var local_id := int(net.my_peer_id)
	var host_state := (_players.get(1, {}).get("state") as PlayerState)
	var local_state := (_players.get(local_id, {}).get("state") as PlayerState)
	var host_expected := str(net.get_player_character_path(1))
	var local_expected := str(net.get_player_character_path(local_id))
	if not _initial_world_received or not host_state or not local_state or host_state.character_path != host_expected or local_state.character_path != local_expected:
		printerr("[NetworkWorld] AUTO_CHARACTER_CLIENT_WORLD_FAILED host=%s/%s local=%s/%s" % [host_state.character_path if host_state else "<none>", host_expected, local_state.character_path if local_state else "<none>", local_expected])
		get_tree().quit(1)
		return
	auto_character_world_ack.rpc_id(1)
	print("[NetworkWorld] AUTO_CHARACTER_CLIENT_WORLD_COMPLETE host=%s local=%s" % [host_state.character_path.get_file(), local_state.character_path.get_file()])
	await get_tree().create_timer(0.80).timeout
	if is_inside_tree():
		net.leave()
		get_tree().quit()


## 不等待完整 world_snapshot 的首图输入回归：Client 预置 Player 接管后立刻上传输入，
## Host 只以自身收到的 submit_input 作为通过依据。正式游戏不会进入此分支。
func _is_auto_client_ready_input_test() -> bool:
	return "--net-test-client-ready-input" in OS.get_cmdline_user_args()


func _run_auto_host_ready_input_test() -> void:
	var deadline := Time.get_ticks_msec() + 6000
	var client_id := 0
	while Time.get_ticks_msec() < deadline:
		for peer_id: int in net.get_peer_ids():
			if peer_id > 1:
				client_id = peer_id
				break
		if client_id > 1 and _auto_client_ready_input_seen_by_host:
			print("[NetworkWorld] AUTO_CLIENT_READY_INPUT_HOST_COMPLETE peer=%d" % client_id)
			await get_tree().create_timer(0.30).timeout
			if is_inside_tree() and net.is_host:
				net.leave()
				get_tree().quit()
			return
		await get_tree().create_timer(0.05).timeout
	printerr("[NetworkWorld] AUTO_CLIENT_READY_INPUT_HOST_FAILED peer=%d" % client_id)
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit(1)


func _run_auto_client_ready_input_test() -> void:
	if not _client_local_ready:
		printerr("[NetworkWorld] AUTO_CLIENT_READY_INPUT_CLIENT_FAILED local_ready=false")
		return
	# 输入已在 _ready() 中、scene-ready 上报前发出；短暂保持按键以避免网络帧恰好错过，
	# 再等待 Host 对该输入的权威接收。
	await get_tree().create_timer(0.35).timeout
	Input.action_release("右")
	await get_tree().create_timer(1.00).timeout
	if is_inside_tree() and not net.is_host:
		net.leave()
		get_tree().quit()


## 单一双端回归覆盖：客户端投掷物输入、Host 权威消费、死亡救援与举放武器过渡。
## 测试只在明确 --net-test-features 下运行，正式游戏完全不会进入此分支。
func _run_auto_host_feature_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while net.get_peer_ids().size() < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not is_inside_tree() or not net.is_host or net.get_peer_ids().size() < 2:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_SETUP_FAILED missing_client")
		return
	var client_id := 0
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			client_id = peer_id
			break
	var client_entry: Dictionary = _players.get(client_id, {})
	var client_state := client_entry.get("state") as PlayerState
	if client_id <= 1 or not client_state:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_SETUP_FAILED missing_client_state")
		return
	# 此测试不依赖常规回归启动参数：明确配置白名单内的有效主/副武器，
	# 这样后续真实 toggle RPC 一定有可验证的 Host 权威武器状态。
	client_state.equipment["primary"] = NETWORK_PISTOL
	client_state.equipment["secondary"] = NETWORK_KNIFE
	client_state.active_weapon_slot = "primary"
	client_state.set_magazine_ammo(NETWORK_PISTOL.item_id, NETWORK_PISTOL.magazine_capacity)
	client_state.throwable = NETWORK_GRENADE
	world_snapshot.rpc_id(client_id, _build_snapshot(), _build_enemy_snapshot(false), _build_pickup_snapshot())
	deadline = Time.get_ticks_msec() + 6000
	while client_state.throwable != null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if client_state.throwable != null:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_THROWABLE_FAILED not_consumed")
		return
	var host_entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var host_node := _player_node(host_entry)
	var client_node := _player_node(client_entry)
	if not is_instance_valid(host_node) or not is_instance_valid(client_node):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_REVIVE_SETUP_FAILED missing_node")
		return
	_set_auto_test_player_position(client_id, host_node.global_position + Vector2(12.0, 0.0))
	# 真实 Host 伤害链路必须在 Client 产生受伤闪烁、数字和音效；
	# 先给一名敌人和 Host 各造成非致命伤，再进行后续倒地/救援回归。
	var feedback_enemy: CharacterBody2D = null
	for enemy_entry_value: Variant in _enemies.values():
		var candidate := _resolve_enemy_entry(enemy_entry_value as Dictionary)
		if is_instance_valid(candidate) and not candidate.is_network_dead():
			feedback_enemy = candidate
			break
	if not is_instance_valid(feedback_enemy):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_HURT_SETUP_FAILED missing_enemy")
		return
	feedback_enemy.take_damage(1.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 998800)
	host_node.take_damage(1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998801)
	print("[NetworkWorld] AUTO_FEATURE_HOST_HURT_APPLIED enemy=%s player=%d" % [feedback_enemy.name, int(net.my_peer_id)])
	await get_tree().create_timer(0.35).timeout
	_force_auto_test_player_low_hp(host_node)  # ガッツ拦致死伤，先压 HP=1（见 helper 注释）
	host_node.take_damage(host_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998802)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 4000
	while host_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if host_node.is_network_dead() or host_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_REVIVE_FAILED hp=%.1f" % host_node.current_hp)
		return
	# 接着验证 Client 自身倒地：Host 必须清空其陈旧输入，客户端必须冻结死亡位置。
	_force_auto_test_player_low_hp(client_node)  # ガッツ拦致死伤，先压 HP=1
	client_node.take_damage(client_node.max_hp + 1.0, 0.0, Vector2.ZERO, false, 0.0, 0.0, 998803)
	deadline = Time.get_ticks_msec() + 2000
	while not client_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not client_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_SETUP_FAILED")
		return
	await get_tree().create_timer(0.90).timeout
	var client_entry_after_death: Dictionary = _players.get(client_id, {})
	var client_input: Vector2 = client_entry_after_death.get("input", Vector2.ZERO)
	var client_marked_stopped := not bool(client_entry_after_death.get("moving", false)) and client_input.is_zero_approx()
	# 倒地回归点：Client 倒地必须登记为权威 entry 标记（而不只是节点躺地表现），
	# 否则 _find_revive_target_for 与快照 downed 字段都会失效。
	if not bool(client_entry_after_death.get("downed", false)):
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DOWNED_FLAG_FAILED")
		return
	_try_host_start_revive(int(net.my_peer_id), client_id)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 2500
	while client_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if client_node.is_network_dead() or client_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_REVIVE_FAILED hp=%.1f" % client_node.current_hp)
		return
	print("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_COMPLETE stopped=%s revived_hp=%.1f" % [client_marked_stopped, client_node.current_hp])
	if not client_marked_stopped:
		printerr("[NetworkWorld] AUTO_FEATURE_HOST_CLIENT_DEATH_FAILED stopped=false")
		return
	print("[NetworkWorld] AUTO_FEATURE_HOST_COMPLETE revived_hp=%.1f" % host_node.current_hp)
	# Client 接下来还要完成武器举放与固定朝向回归；Host 必须持续在线直到请求已被权威处理。
	await get_tree().create_timer(15.0).timeout
	if is_inside_tree() and net.is_host:
		net.leave()
		get_tree().quit()


func _run_auto_client_feature_test() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var local_id := int(net.my_peer_id)
	var entry: Dictionary = _players.get(local_id, {})
	var state := entry.get("state") as PlayerState
	while (not state or state.throwable == null) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		entry = _players.get(local_id, {})
		state = entry.get("state") as PlayerState
	if not state or state.throwable != NETWORK_GRENADE:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_THROWABLE_SETUP_FAILED item=%s" % [state.throwable.item_id if state and state.throwable else "<none>"])
		return
	throwable_hold_request.rpc_id(1, true)
	await get_tree().create_timer(0.15).timeout
	throwable_aim_request.rpc_id(1, true)
	await get_tree().create_timer(0.15).timeout
	throwable_range_request.rpc_id(1, 1)
	await get_tree().create_timer(0.15).timeout
	throwable_throw_request.rpc_id(1)
	deadline = Time.get_ticks_msec() + 3500
	while state.throwable != null and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if state.throwable != null:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_THROWABLE_FAILED not_consumed")
		return
	# Host 会通过真实 take_damage() 广播敌人和玩家受伤表现；Client 只验证收到的表现 RPC，
	# 不在本地扣血或驱动敌人状态机。
	deadline = Time.get_ticks_msec() + 3500
	while (
		_auto_client_player_hurt_presentations < 1
		or _auto_client_enemy_hurt_presentations < 1
	) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var hurt_presentation_ok := _auto_client_player_hurt_presentations >= 1 and _auto_client_enemy_hurt_presentations >= 1
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_HURT_COMPLETE player_events=%d enemy_events=%d" % [
		_auto_client_player_hurt_presentations,
		_auto_client_enemy_hurt_presentations,
	])
	if not hurt_presentation_ok:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_HURT_FAILED player_events=%d enemy_events=%d" % [
			_auto_client_player_hurt_presentations,
			_auto_client_enemy_hurt_presentations,
		])
		return
	# Host 在投掷校验及受伤表现回归结束后会令自己倒地；客户端必须以真实 RPC 请求救援。
	var host_entry: Dictionary = _players.get(1, {})
	var host_node := _player_node(host_entry)
	deadline = Time.get_ticks_msec() + 4000
	while (not is_instance_valid(host_node) or not host_node.is_network_dead()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		host_entry = _players.get(1, {})
		host_node = _player_node(host_entry)
	if not is_instance_valid(host_node) or not host_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_REVIVE_SETUP_FAILED host_dead=%s" % [is_instance_valid(host_node) and host_node.is_network_dead()])
		return
	# 倒地回归点：Host 的 downed 标记必须经快照同步到 Client entry ——
	# 它是救援目标筛选（_find_revive_target_for）与生命三态判定的数据来源；
	# 只有节点躺地表现而缺少该标记时，Client 将无法发起救援。
	if not bool((_players.get(1, {}) as Dictionary).get("downed", false)):
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DOWNED_FLAG_FAILED")
		return
	revive_start_request.rpc_id(1, 1)
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 2500
	while host_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if host_node.is_network_dead() or host_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_REVIVE_FAILED hp=%.1f" % [host_node.current_hp if is_instance_valid(host_node) else -1.0])
		return
	entry = _players.get(local_id, {})
	state = entry.get("state") as PlayerState
	var local_node := _player_node(entry)
	if not is_instance_valid(local_node):
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_SETUP_FAILED missing_local_node")
		return
	deadline = Time.get_ticks_msec() + 4000
	while not local_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not local_node.is_network_dead():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_SETUP_FAILED local_dead=false")
		return
	await get_tree().process_frame
	var collision_shape := local_node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	# 倒地语义回归点：碰撞体在倒地期间必须重新启用（倒地爬行不能穿墙），
	# 取代旧的"死亡=碰撞关闭"断言；复活后同样保持启用。
	var collision_enabled_while_downed := is_instance_valid(collision_shape) and not collision_shape.disabled
	# 直接提交死亡后的移动意图；Host 入口必须忽略它，客户端的位置也不能继续漂移。
	await get_tree().create_timer(0.20).timeout
	var death_position := local_node.global_position
	submit_input.rpc_id(1, Vector2.RIGHT, false)
	await get_tree().create_timer(0.40).timeout
	var frozen := local_node.global_position.distance_to(death_position) <= 0.5
	deadline = Time.get_ticks_msec() + REVIVE_DURATION_MSEC + 3500
	while local_node.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if local_node.is_network_dead() or local_node.current_hp <= 0.0:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_REVIVE_FAILED hp=%.1f" % local_node.current_hp)
		return
	await get_tree().process_frame
	var collision_restored := is_instance_valid(collision_shape) and not collision_shape.disabled
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_COMPLETE frozen=%s collision_enabled_while_downed=%s collision_restored=%s revived=true" % [frozen, collision_enabled_while_downed, collision_restored])
	if not frozen or not collision_enabled_while_downed or not collision_restored:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_DEATH_FAILED frozen=%s collision_enabled_while_downed=%s collision_restored=%s" % [frozen, collision_enabled_while_downed, collision_restored])
		return
	var active_weapon: WeaponData = state.get_active_weapon() if state else null
	if not is_instance_valid(local_node) or not active_weapon:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_TRANSITION_SETUP_FAILED node=%s weapon=%s" % [is_instance_valid(local_node), active_weapon != null])
		return
	var transition_wait := _get_network_weapon_transition_duration(active_weapon) + 0.30
	# 先统一到放下状态；不假设客户端初始表现是否已由场景/快照切换为举起。
	if local_node.is_weapon_mode_active():
		weapon_toggle_request.rpc_id(1)
		await get_tree().create_timer(transition_wait).timeout
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	var raised: bool = local_node.is_weapon_mode_active()
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	var lowered: bool = not local_node.is_weapon_mode_active()
	if not raised or not lowered:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_TRANSITION_FAILED raised=%s lowered=%s" % [raised, lowered])
		return
	# 固定朝向回归：Client 只能请求 Host 加锁；Host 在锁定时收到移动输入也不得改变 facing，
	# 解锁后下一次移动则必须恢复正常转向。
	weapon_toggle_request.rpc_id(1)
	await get_tree().create_timer(transition_wait).timeout
	if not local_node.is_weapon_mode_active():
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_SETUP_FAILED weapon_not_raised")
		return
	# Player.facing is an integer enum; use the vector accessor here so the
	# regression verifies direction without duplicating Player.FaceDir values.
	var locked_facing: Vector2 = local_node.get_facing_vector()
	var test_direction := Vector2.RIGHT if locked_facing != Vector2.RIGHT else Vector2.LEFT
	# The test uses explicit state requests rather than toggle so an inherited
	# scene/animation lock state cannot invert the assertion.
	facing_lock_request.rpc_id(1, false, true)
	await get_tree().create_timer(0.12).timeout
	submit_input.rpc_id(1, test_direction, false)
	await get_tree().create_timer(0.20).timeout
	var facing_after_lock: Vector2 = local_node.get_facing_vector()
	var stayed_locked: bool = facing_after_lock.is_equal_approx(locked_facing)
	var lock_state_synced: bool = local_node.is_facing_locked()
	facing_lock_request.rpc_id(1, false, false)
	await get_tree().create_timer(0.12).timeout
	submit_input.rpc_id(1, test_direction, false)
	await get_tree().create_timer(0.20).timeout
	var facing_after_unlock: Vector2 = local_node.get_facing_vector()
	var unlocked_turns: bool = facing_after_unlock.is_equal_approx(test_direction)
	var unlock_state_synced: bool = not local_node.is_facing_locked()
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_COMPLETE locked=%s unlocked=%s lock_state=%s unlock_state=%s" % [stayed_locked, unlocked_turns, lock_state_synced, unlock_state_synced])
	if not stayed_locked or not unlocked_turns or not lock_state_synced or not unlock_state_synced:
		printerr("[NetworkWorld] AUTO_FEATURE_CLIENT_FACING_FAILED locked=%s unlocked=%s expected=(%.0f,%.0f) locked_actual=(%.0f,%.0f) unlocked_actual=(%.0f,%.0f)" % [
			stayed_locked,
			unlocked_turns,
			test_direction.x,
			test_direction.y,
			facing_after_lock.x,
			facing_after_lock.y,
			facing_after_unlock.x,
			facing_after_unlock.y,
		])
		return
	print("[NetworkWorld] AUTO_FEATURE_CLIENT_COMPLETE throwable=true revive=true transition=true facing_lock=true")
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _is_auto_enemy_test_scene() -> bool:
	return "--net-test-enemies" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _run_auto_host_enemy_test() -> void:
	## Director 由 Host 运行。这里只验证它确实将动态敌人收编到网络实体表，
	## Client 的独立断言会验证可靠 spawn 包创建了表现实体。
	var deadline := Time.get_ticks_msec() + 30000
	while _enemies.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	if _enemies.is_empty():
		printerr("[NetworkWorld] AUTO_ENEMY_HOST_FAILED no_registered_enemy")
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_HOST_COMPLETE registered=%d" % _enemies.size())
	# 死亡广播回归：等 Client 建立表现实体后击杀一名敌人。
	# Client 侧断言会验证可靠 enemy_death_presentation 已被应用（而非等 2s 重同步）。
	deadline = Time.get_ticks_msec() + 8000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	await get_tree().create_timer(1.00).timeout
	var victim := _find_first_alive_host_enemy()
	if not is_instance_valid(victim):
		printerr("[NetworkWorld] AUTO_ENEMY_HOST_DEATH_FAILED no_victim")
		net.leave()
		get_tree().quit(1)
		return
	victim.take_damage(victim.current_hp + 1.0, 0.0, Vector2.RIGHT, false, 0.0, 0.0, 998801)
	deadline = Time.get_ticks_msec() + 4000
	while not victim.is_network_dead() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_ENEMY_HOST_DEATH_COMPLETE victim=%s dead=%s" % [victim.name, victim.is_network_dead()])
	# 留出 Client 完成死亡断言并自行退出；Host 随后走 _on_peer_left 的常规收束。
	await get_tree().create_timer(4.0).timeout


func _find_first_alive_host_enemy() -> CharacterBody2D:
	for entry_value: Variant in _enemies.values():
		var enemy := _resolve_enemy_entry(entry_value as Dictionary)
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			return enemy
	return null


func _run_auto_client_enemy_test() -> void:
	var deadline := Time.get_ticks_msec() + 35000
	while (not _initial_world_received or _enemies.is_empty()) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning:
		return
	var has_network_enemy := false
	for entry_value: Variant in _enemies.values():
		var enemy := _resolve_enemy_entry(entry_value as Dictionary)
		if is_instance_valid(enemy) and int(enemy.get("network_entity_id")) > 0:
			has_network_enemy = true
			break
	if not _initial_world_received or not has_network_enemy:
		printerr("[NetworkWorld] AUTO_ENEMY_CLIENT_FAILED local_ready=%s enemies=%d network_enemy=%s" % [_initial_world_received, _enemies.size(), has_network_enemy])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_CLIENT_COMPLETE received=%d" % _enemies.size())
	# 死亡广播回归：Host 会击杀一名敌人；Client 必须收到可靠死亡表现并立即变尸体。
	deadline = Time.get_ticks_msec() + 8000
	while _auto_client_enemy_death_presentations < 1 and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _auto_client_enemy_death_presentations < 1:
		printerr("[NetworkWorld] AUTO_ENEMY_CLIENT_DEATH_FAILED presentations=%d" % _auto_client_enemy_death_presentations)
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_ENEMY_CLIENT_DEATH_COMPLETE")
	# Give the Host smoke coroutine one network tick to record its own assertion before teardown.
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


## ── D2 外观/难度一致性回归（--net-test-appearance，第一关街道图）──
## Host：定向刷 1 特感（ブレインディモス，Director.spawn_special_enemy 生产路径）
## + 1 变体丧尸（中年ゾンビ，与 spawn_enemy 同字段注入），等收编后周期性广播吐酸
## 表现（镜像弹纯视觉，多次广播幂等无害）。Client 断言四件套：
##   A1 特感 spawn 外观注入 / A5 变体行走图重建 / A2 酸弹镜像 / B1 难度覆写
##   （Host --net-test-difficulty=2，Client 预置 1，进图后必须被同步覆写为 2）。
func _is_auto_appearance_test() -> bool:
	return "--net-test-appearance" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _run_auto_host_appearance_test() -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while _ready_client_peers.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	var decor := get_tree().current_scene.find_child("DecorLayer", true, false) as Node2D
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if decor == null or player == null:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_decor_or_player")
		net.leave()
		get_tree().quit(1)
		return
	# 特感：走 Director 生产路径（注入 special_data → 快照携带 special_id）。
	var special_data := load("res://tres/specials/ブレインディモス.tres") as SpecialEnemyData
	var director := get_node_or_null("/root/Director")
	if special_data == null or director == null or not director.has_method("spawn_special_enemy"):
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_special_pipeline")
		net.leave()
		get_tree().quit(1)
		return
	var sp: Node2D = director.spawn_special_enemy(player.global_position + Vector2(140.0, 0.0), special_data, decor)
	# 变体：与 spawn_enemy 同字段注入（apply_to_enemy + variant_data → 快照携带 variant_id）。
	var variant := load("res://tres/zombies/中年ゾンビ.tres") as ZombieVariant
	if variant == null:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED missing_variant_tres")
		net.leave()
		get_tree().quit(1)
		return
	var zombie := ENEMY_SCENE.instantiate() as CharacterBody2D
	zombie.global_position = player.global_position + Vector2(-140.0, 0.0)
	variant.apply_to_enemy(zombie)
	zombie.variant_data = variant
	decor.add_child(zombie)
	# 等收编（_register_untracked_host_enemies 周期扫描）。
	deadline = Time.get_ticks_msec() + 8000
	var registered := false
	while Time.get_ticks_msec() < deadline and not registered:
		registered = _find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_special_id() == "brain_demos") > 0 \
			and _find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_variant_id() == "chunen") > 0
		if not registered:
			await get_tree().create_timer(0.10).timeout
	if not registered:
		printerr("[NetworkWorld] AUTO_APPEARANCE_HOST_FAILED not_registered")
		net.leave()
		get_tree().quit(1)
		return
	# ⚠ 标记必须先于吐酸广播：net-test 下 Client 一断开 Host 即被
	# _finish_auto_host_after_client_leave 收束，挂起协程不再恢复——若把
	# COMPLETE 放在广播循环之后，Client 先退出时标记永远打不出来。
	print("[NetworkWorld] AUTO_APPEARANCE_HOST_COMPLETE special=brain_demos variant=chunen")
	# 吐酸表现广播 ×6（镜像弹纯视觉即焚，重复广播幂等），收尾尽力执行。
	for i: int in 6:
		var sp_node := _resolve_enemy_entry(_enemies.get(_find_entity_id_by_filter(func(e: CharacterBody2D) -> bool: return e.get_network_special_id() == "brain_demos"), {}) as Dictionary)
		if is_instance_valid(sp_node):
			announce_enemy_acid_spit(sp_node, sp_node.global_position, Vector2.RIGHT)
		await get_tree().create_timer(0.50).timeout
	await get_tree().create_timer(3.0).timeout


func _find_entity_id_by_filter(filter: Callable) -> int:
	for key: Variant in _enemies.keys():
		var enemy := _resolve_enemy_entry(_enemies[key] as Dictionary)
		if is_instance_valid(enemy) and int(enemy.get("network_entity_id")) > 0 and filter.call(enemy):
			return int(key)
	return 0


func _run_auto_client_appearance_test() -> void:
	# 与 network_world 白名单同一份 tres：Client 重建用 preload 常量，断言用 load()
	# 取回的是同一缓存实例，纹理按引用相等比较成立。
	var special_res := load("res://tres/specials/ブレインディモス.tres") as SpecialEnemyData
	var variant_res := load("res://tres/zombies/中年ゾンビ.tres") as ZombieVariant
	var deadline := Time.get_ticks_msec() + 35000
	var special_hit := false
	var variant_hit := false
	while Time.get_ticks_msec() < deadline and not (special_hit and variant_hit):
		special_hit = false
		variant_hit = false
		for key: Variant in _enemies.keys():
			var enemy := _resolve_enemy_entry(_enemies[key] as Dictionary)
			if not is_instance_valid(enemy):
				continue
			if not special_hit and enemy.get("walk_texture") == special_res.texture \
					and enemy.get("spit_enabled") == true:
				special_hit = true
			if not variant_hit and enemy.get("walk_texture") == variant_res.normal_texture:
				variant_hit = true
		if special_hit and variant_hit:
			break
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(self) or _scene_transitioning:
		return
	if not (special_hit and variant_hit):
		printerr("[NetworkWorld] AUTO_APPEARANCE_CLIENT_FAILED special=%s variant=%s enemies=%d" % [special_hit, variant_hit, _enemies.size()])
		net.leave()
		get_tree().quit(1)
		return
	# 酸弹镜像（A2）：Host 周期广播，任意时刻场景里出现非权威镜像弹即通过。
	deadline = Time.get_ticks_msec() + 12000
	var mirror_seen := false
	while Time.get_ticks_msec() < deadline and not mirror_seen:
		for child: Node in get_tree().current_scene.get_children():
			if child is EnemyAcidSpit and child.get("_authoritative") == false:
				mirror_seen = true
				break
		if not mirror_seen:
			await get_tree().create_timer(0.05).timeout
	# 难度一致性（B1）：Client 预置 1、Host 固定 2 —— 进图后必须被 start_game 覆写。
	var difficulty_ok: bool = Global.selected_difficulty == 2
	if not mirror_seen or not difficulty_ok:
		printerr("[NetworkWorld] AUTO_APPEARANCE_CLIENT_FAILED mirror=%s difficulty=%d (expected 2)" % [mirror_seen, Global.selected_difficulty])
		net.leave()
		get_tree().quit(1)
		return
	print("[NetworkWorld] AUTO_APPEARANCE_CLIENT_COMPLETE mirror=true difficulty=2")
	await get_tree().create_timer(0.20).timeout
	net.leave()
	get_tree().quit()


func _is_auto_safe_door_test_scene() -> bool:
	return "--net-test-safe-door" in OS.get_cmdline_user_args() and "突袭-第一关-街道" in _scene_path


func _get_auto_safe_door() -> Node2D:
	if not get_tree().current_scene:
		return null
	var door := get_tree().current_scene.find_child("SafeDoor", true, false) as Node2D
	return door if is_instance_valid(door) and door.has_method("get_network_door_key") else null


func _set_auto_test_player_position(peer_id: int, position: Vector2) -> void:
	var entry: Dictionary = _players.get(peer_id, {})
	var node := _player_node(entry)
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node):
		return
	node.global_position = position
	if state:
		state.position = position
	_players[peer_id] = entry


func _run_auto_host_safe_door_test() -> void:
	## 先让 Host 单独确认。Client 保持在远处，因此绝不能触发切图。
	await get_tree().create_timer(0.75).timeout
	if not is_instance_valid(self) or _scene_transitioning or not net.is_host:
		return
	var door := _get_auto_safe_door()
	if not is_instance_valid(door):
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_SETUP_FAILED missing_door")
		return
	var host_id := int(net.my_peer_id)
	_set_auto_test_player_position(host_id, door.global_position + Vector2(-8.0, 0.0))
	request_safe_door_ready(str(door.call("get_network_door_key")))
	await get_tree().create_timer(0.30).timeout
	if _scene_transitioning:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_HOST_SOLO_FAILED transitioned=true")
		return
	print("[NetworkWorld] AUTO_SAFE_DOOR_HOST_SOLO_BLOCKED")
	## 再由 Host 把 Client 的权威实体移到门旁。全员到门后无需 Client 再确认。
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			_set_auto_test_player_position(peer_id, door.global_position + Vector2(8.0, 0.0))
	print("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_STAGED")
	await get_tree().create_timer(0.30).timeout
	# 验证此时只由 Host 再次确认也可统一切图。切图静默信号会立即发出，
	# 不能 await 后再断言，因为旧 NetworkWorld 随后会随场景释放。
	request_safe_door_ready(str(door.call("get_network_door_key")))
	if not _scene_transitioning:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_ALL_ARRIVED_FAILED transitioned=false")
		return
	print("[NetworkWorld] AUTO_SAFE_DOOR_HOST_CONFIRM_TRANSITIONED")


func _run_auto_client_safe_door_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_SETUP_FAILED world=false")
		return
	while is_instance_valid(self) and not _scene_transitioning and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if _scene_transitioning:
		print("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_HOST_CONFIRM_TRANSITIONED")
	else:
		printerr("[NetworkWorld] AUTO_SAFE_DOOR_CLIENT_TRANSITION_TIMEOUT")


func _run_auto_client_input_test() -> void:
	# world_snapshot 到达时，_initial_world_received 只表示本地实体已经创建；装备字段仍可能
	# 在同帧稍后才由 Host 快照写入。等待本地状态真正拥有主武器，避免回归测试将启动时序
	# 误判为拾取/掉落物同步故障。
	var primary_weapon := await _wait_for_auto_client_primary_weapon(5000)
	if not primary_weapon:
		return
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var initial_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	if initial_ammo != primary_weapon.magazine_capacity:
		printerr("[NetworkWorld] AUTO_CLIENT_INITIAL_AMMO_FAILED weapon=%s ammo=%d expected=%d" % [primary_weapon.item_id, initial_ammo, primary_weapon.magazine_capacity])


	# 拾取回归只验证掉落物事务；不要先跑战斗/近战路径，避免经过相邻物品时
	# 自动拾取改变测试前置状态。
	if "--net-test-throwable-pickup" in OS.get_cmdline_user_args():
		await _run_auto_client_throwable_pickup_test()
		net.leave()
		get_tree().quit()
		return
	if "--net-test-pickup" in OS.get_cmdline_user_args():
		await _run_auto_client_pickup_test()
		net.leave()
		get_tree().quit()
		return

	Input.action_press("右")
	var animation_frames: Dictionary = {}
	for _sample: int in range(8):
		await get_tree().create_timer(0.08).timeout
		var sample_entry: Dictionary = _players.get(int(net.my_peer_id), {})
		var sample_node := _player_node(sample_entry)
		if is_instance_valid(sample_node):
			var sample_sprite := sample_node.get_node_or_null("Sprite2D") as Sprite2D
			if sample_sprite:
				animation_frames[sample_sprite.region_rect.position.x] = true
	Input.action_release("右")
	await get_tree().create_timer(0.35).timeout
	entry = _players.get(int(net.my_peer_id), {})
	var node := _player_node(entry)
	var animation_advanced := animation_frames.size() > 1
	print("[NetworkWorld] AUTO_CLIENT_INPUT_COMPLETE pos=%s animation_advanced=%s frames=%d" % [
		node.global_position if is_instance_valid(node) else Vector2.ZERO,
		animation_advanced,
		animation_frames.size(),
	])
	if not animation_advanced:
		printerr("[NetworkWorld] AUTO_CLIENT_ANIMATION_FAILED")

	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	# HOLD 武器（如冲锋枪）必须在同一次连续按住中产生多次 Host 权威攻击，
	# 不能仅验证一次按键会开火，否则会漏掉冲锋枪无法连发的回归。
	var hold_fire_test := primary_weapon.fire_mode == WeaponData.FireMode.HOLD
	var required_attack_count := 3 if hold_fire_test else 1
	var required_visual_bullets := primary_weapon.bullet_list.size() * required_attack_count
	var fire_hold_duration := 0.75 if hold_fire_test else 0.12
	Input.action_press("确定键")
	await get_tree().create_timer(fire_hold_duration).timeout
	Input.action_release("确定键")
	var deadline := Time.get_ticks_msec() + 3000
	while (
		(not _auto_client_fire_confirmed or _auto_client_bullets_seen < required_visual_bullets)
		and Time.get_ticks_msec() < deadline
	):
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var final_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	var fire_ok := (
		_auto_client_fire_confirmed
		and _auto_client_attack_weapon_id == primary_weapon.item_id
		and _auto_client_bullets_seen >= required_visual_bullets
		and final_ammo <= primary_weapon.magazine_capacity - required_attack_count
	)
	print("[NetworkWorld] AUTO_CLIENT_FIRE_COMPLETE weapon=%s hold_mode=%s confirmed=%s bullets_seen=%d required_bullets=%d ammo=%d" % [
		_auto_client_attack_weapon_id,
		hold_fire_test,
		_auto_client_fire_confirmed,
		_auto_client_bullets_seen,
		required_visual_bullets,
		final_ammo,
	])
	if not fire_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_FIRE_FAILED expected_weapon=%s hold_mode=%s weapon=%s confirmed=%s bullets_seen=%d required_bullets=%d ammo=%d" % [
			primary_weapon.item_id,
			hold_fire_test,
			_auto_client_attack_weapon_id,
			_auto_client_fire_confirmed,
			_auto_client_bullets_seen,
			required_visual_bullets,
			final_ammo,
		])
	# 第二段：先按已知摆位右走（确定性），再在**有上限的近距离内**按快照里的敌人位置贴身。
	# ⚠ 不能无脑去追「最近敌人」：可能追到远处或被墙挡住的敌人，反而走离目标
	# （实测 in_range=false pos=(1238,4586)，比固定走位更糟）。也不保持纯固定走位：
	# 敌人由 Director 驱动会挪动，固定走位会走空（实测 HOST_MELEE_WHIFF）。
	# ⚠ 上界必须覆盖「前方补位带」（360~560px）——2026-09-23 第三轮实测：客户端成为刷怪锚点
	# 后，最近的敌人常常就是刚补在它前方约 400px 的那只，旧的 200px 上界会直接放弃贴身、
	# 原地挥空（HOST_MELEE_WHIFF，3/3 失败）。近战判定矩形是「朝向前方 48×32」，
	# 所以贴身收在 ≤30px 并保持朝向即可稳定命中。
	Input.action_press("右")
	await get_tree().create_timer(0.72).timeout
	Input.action_release("右")
	await get_tree().create_timer(0.30).timeout
	const APPROACH_MAX_DISTANCE := 700.0
	const APPROACH_NEAR := 30.0
	var approach_deadline := Time.get_ticks_msec() + 5000
	var in_range := false
	var sticky: CharacterBody2D = null
	while Time.get_ticks_msec() < approach_deadline:
		entry = _players.get(int(net.my_peer_id), {})
		node = _player_node(entry)
		if not is_instance_valid(node):
			break
		if not is_instance_valid(sticky):
			sticky = _nearest_client_enemy_node(node.global_position)
		if not is_instance_valid(sticky):
			break
		var delta: Vector2 = sticky.global_position - node.global_position
		var dist: float = delta.length()
		if dist <= APPROACH_NEAR:
			in_range = true
			break
		if dist > APPROACH_MAX_DISTANCE:
			## 目标跑远了 → 换一个最近的目标再判断一次（仍不追超距目标）
			sticky = _nearest_client_enemy_node(node.global_position)
			if not is_instance_valid(sticky):
				break
			delta = sticky.global_position - node.global_position
			if delta.length() > APPROACH_MAX_DISTANCE:
				break     # 附近没有可贴身的目标 → 保持确定性走位结果，直接出手
		if absf(delta.x) > 5.0:
			Input.action_press("右" if delta.x > 0.0 else "左")
		if absf(delta.y) > 5.0:
			Input.action_press("下" if delta.y > 0.0 else "上")
		await get_tree().create_timer(0.05).timeout
		Input.action_release("右")
		Input.action_release("左")
		Input.action_release("下")
		Input.action_release("上")
	await get_tree().create_timer(0.25).timeout
	entry = _players.get(int(net.my_peer_id), {})
	node = _player_node(entry)
	print("[NetworkWorld] AUTO_CLIENT_KNIFE_POSITION in_range=%s pos=%s" % [
		in_range, node.global_position if is_instance_valid(node) else Vector2.ZERO])

	# 第三段：验证客户端只提交切换/攻击意图，而 Host 以固定副武器（小刀）确认表现与伤害。
	Input.action_press("副武器键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("副武器键")
	deadline = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		state = entry.get("state") as PlayerState
		if state and state.active_weapon_slot == "secondary" and state.get_active_weapon() == NETWORK_KNIFE:
			break
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var knife_switched := state != null and state.active_weapon_slot == "secondary" and state.get_active_weapon() == NETWORK_KNIFE
	if not knife_switched:
		printerr("[NetworkWorld] AUTO_CLIENT_KNIFE_SWITCH_FAILED slot=%s" % [state.active_weapon_slot if state else "<none>"])

	# 小刀命中必须通过 Host 的物理查询和敌人权威 take_damage() 产生；客户端只通过敌人快照观察 HP 变化。
	# 按 entity_id 跟踪同一只敌人的 hp——总和分析会被 Director scatter 新刷的敌人抬高（假红）。
	var enemy_hp_map_before := _get_client_enemy_hp_map()
	var enemy_hp_before: float = _get_client_live_enemy_hp_total()
	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	Input.action_press("确定键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("确定键")
	deadline = Time.get_ticks_msec() + 6000
	var melee_damage_seen := false
	var enemy_hp_after := enemy_hp_before
	## 逐帧差分（2026-09-23 稳定化）：原先只比对「攻击前已存在」的 enemy_id —— 若这一刀
	## 砍中的是 Director 在这段时间新刷出的敌人，HP 确实掉了却判不出来（实测假红）。
	## 改为比对相邻两次采样的**同名**敌人：新刷敌人首帧即进入两张表，其后掉血可被捕捉；
	## 而 scatter 只会抬高总和、不会造成同一 id 掉血，所以不会引入假绿。
	var hp_map_prev := enemy_hp_map_before
	## 兜底再挥：敌人可能在逼近后又挪开，导致这一刀落空。窗口内允许补挥若干次
	## （仍走正常输入链路），避免把「用例运气」当成回归结论。
	## 2026-09-23 第三轮：补挥次数 1 → 4、窗口 3s → 6s，并在窗口内**持续贴身**
	## （客户端成为刷怪锚点后身边的怪一直在换，贴身一次不等于下一刀还在范围内）。
	var reswings := 0
	var next_swing_at := Time.get_ticks_msec() + 1200
	while Time.get_ticks_msec() < deadline:
		enemy_hp_after = _get_client_live_enemy_hp_total()
		var hp_map_after := _get_client_enemy_hp_map()
		for enemy_key: int in hp_map_after.keys():
			if not hp_map_prev.has(enemy_key):
				continue
			if float(hp_map_after[enemy_key]) <= float(hp_map_prev[enemy_key]) - NETWORK_KNIFE.get_effective_damage() + 0.1:
				melee_damage_seen = true
				break
		hp_map_prev = hp_map_after
		if melee_damage_seen:
			break
		_auto_client_steer_toward_nearest_enemy()
		if _auto_client_fire_confirmed and reswings < 4 and Time.get_ticks_msec() >= next_swing_at:
			reswings += 1
			next_swing_at = Time.get_ticks_msec() + 1200
			Input.action_press("确定键")
			await get_tree().create_timer(0.12).timeout
			Input.action_release("确定键")
		await get_tree().create_timer(0.05).timeout
		Input.action_release("右")
		Input.action_release("左")
		Input.action_release("下")
		Input.action_release("上")
	var knife_ok := knife_switched and _auto_client_fire_confirmed and _auto_client_attack_weapon_id == NETWORK_KNIFE.item_id and not _auto_client_bullet_seen and melee_damage_seen
	print("[NetworkWorld] AUTO_CLIENT_KNIFE_COMPLETE switched=%s confirmed=%s weapon=%s bullet_seen=%s melee_damage_seen=%s enemy_hp_before=%.1f enemy_hp_after=%.1f" % [
		knife_switched,
		_auto_client_fire_confirmed,
		_auto_client_attack_weapon_id,
		_auto_client_bullet_seen,
		melee_damage_seen,
		enemy_hp_before,
		enemy_hp_after,
	])
	if not knife_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_KNIFE_FAILED switched=%s confirmed=%s weapon=%s bullet_seen=%s melee_damage_seen=%s enemy_hp_before=%.1f enemy_hp_after=%.1f" % [
			knife_switched,
			_auto_client_fire_confirmed,
			_auto_client_attack_weapon_id,
			_auto_client_bullet_seen,
			melee_damage_seen,
			enemy_hp_before,
			enemy_hp_after,
		])
	net.leave()
	get_tree().quit()

## 等待可靠 world_snapshot 已把 Host 权威主武器写入本地 PlayerState。
## --net-test-weapon 指定时仍校验它，未指定时则直接使用 Host 已同步的 primary 装备，
## 使测试不会依赖客户端本地命令行去猜测 Host 的初始配置。
func _wait_for_auto_client_primary_weapon(timeout_msec: int) -> WeaponData:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var expected_weapon := _get_network_primary_loadout_weapon()
	while Time.get_ticks_msec() < deadline:
		if _initial_world_received:
			var entry: Dictionary = _players.get(int(net.my_peer_id), {})
			var state := entry.get("state") as PlayerState
			var primary := state.get_equipped_weapon("primary") if state else null
			if primary and (not expected_weapon or primary.item_id == expected_weapon.item_id):
				return primary
		await get_tree().create_timer(0.05).timeout
	var expected_id := expected_weapon.item_id if expected_weapon else "<host-snapshot-primary>"
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var actual := state.get_equipped_weapon("primary") if state else null
	printerr("[NetworkWorld] AUTO_CLIENT_PRIMARY_WEAPON_TIMEOUT expected=%s actual=%s world=%s" % [
		expected_id,
		actual.item_id if actual else "<none>",
		_initial_world_received,
	])
	return null


## 回归 Client 按住确认键拾取武器：Host 替换装备、删除源掉落物、生成旧武器掉落物，再由可靠快照回写客户端。
func _run_auto_client_pickup_test() -> void:
	var primary_weapon := await _wait_for_auto_client_primary_weapon(5000)
	if not primary_weapon:
		return
	var deadline := Time.get_ticks_msec() + 5000
	var source := _find_client_pickup_by_weapon_id(NETWORK_PISTOL.item_id)
	while not is_instance_valid(source) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
		source = _find_client_pickup_by_weapon_id(NETWORK_PISTOL.item_id)
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := _player_node(entry)
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(source) or not is_instance_valid(node) or not state:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED source=%s node=%s state=%s primary=%s" % [is_instance_valid(source), is_instance_valid(node), state != null, primary_weapon.item_id])
		return
	var target_weapon := NETWORK_PISTOL
	var target_slot := target_weapon.get_slot_key()
	var old_weapon := state.get_equipped_weapon(target_slot)
	if not old_weapon or old_weapon.item_id == target_weapon.item_id:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED slot=%s old_weapon=%s" % [target_slot, old_weapon.item_id if old_weapon else "<none>"])
		return
	# 先用正常客户端输入移动到测试图里的手枪范围内，使 Host 仍会执行距离校验。
	# 随后按确定的 network_pickup_id 精确提交一次请求：测试图内相邻的多个掉落物都会监听同一个“确定键”，
	# 长按自动化有概率先命中路过的另一个物品，导致回归用例误报；正式的按住交互仍由 weapon_pickup.gd 覆盖。
	## 【2026-09-26 修】原实现只在开始时选一个轴、按住不放 3 秒：
	## 落点稍远或有拐角就走不到位 —— 实测把"多人补位落点"改成**绕锚点环形搜索**后，
	## 客户端出生点变了（距掉落物 ~380px），步行速度下 3 秒连直线都走不到，3 次尝试全失败。
	## 改成每 0.05s 重新判定方向（需要时同时按两个轴），截止时间放宽到 6 秒。
	deadline = Time.get_ticks_msec() + 6000
	var pressed_actions: Array[String] = []
	while Time.get_ticks_msec() < deadline \
			and node.global_position.distance_to(source.global_position) > 18.0:
		var delta_to_go: Vector2 = source.global_position - node.global_position
		var want: Array[String] = []
		if absf(delta_to_go.x) > 6.0:
			want.append("右" if delta_to_go.x > 0.0 else "左")
		if absf(delta_to_go.y) > 6.0:
			want.append("下" if delta_to_go.y > 0.0 else "上")
		for action: String in want:
			if not pressed_actions.has(action):
				Input.action_press(action)
				pressed_actions.append(action)
		for action: String in pressed_actions.duplicate():
			if not want.has(action):
				Input.action_release(action)
				pressed_actions.erase(action)
		await get_tree().create_timer(0.05).timeout
	for action: String in pressed_actions:
		Input.action_release(action)
	await get_tree().create_timer(0.08).timeout
	var in_range := node.global_position.distance_to(source.global_position) <= 28.0
	if not in_range:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_MOVE_FAILED player=%s source=%s" % [node.global_position, source.global_position])
		return
	request_pickup(source.network_pickup_id)
	deadline = Time.get_ticks_msec() + 3000
	var primary_swapped := false
	var dropped_old_seen := false
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		state = entry.get("state") as PlayerState
		primary_swapped = state != null and state.get_equipped_weapon(target_slot) == target_weapon
		dropped_old_seen = _has_client_pickup_weapon_near(old_weapon.item_id, node.global_position, 64.0)
		if primary_swapped and dropped_old_seen:
			break
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_CLIENT_PICKUP_COMPLETE slot=%s old=%s equipped=%s swapped=%s dropped_old_seen=%s pickups=%d" % [
		target_slot,
		old_weapon.item_id,
		state.get_equipped_weapon(target_slot).item_id if state and state.get_equipped_weapon(target_slot) else "<none>",
		primary_swapped,
		dropped_old_seen,
		_pickups.size(),
	])
	if not primary_swapped or not dropped_old_seen:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_FAILED slot=%s old=%s swapped=%s dropped_old_seen=%s" % [target_slot, old_weapon.item_id, primary_swapped, dropped_old_seen])



## 回归 Client 拾取投掷物：客户端节点必须可提交请求，Host 再权威写入 throwable 并删除掉落物。
func _run_auto_client_throwable_pickup_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := _player_node(entry)
	## 安全屋开局随机掉落表的投掷物是混合概率（grenade/molotov/flash 只会刷出其一或都不出），
	## 用例若只找手雷会随掉落随机性摆烂（2026-09-18 连续两轮 SETUP_FAILED，Host 该局刷的是
	## 燃烧瓶）——泛化为「任一白名单投掷物掉落」，消除 setup 的运气依赖。
	var td: ThrowableData = null
	var source: Node2D = null
	## 09-22：random_pickup 在联机 Client 侧已禁用本地随机刷（两端各自 roll 不同步），
	## 投掷物源改由 Host 下发 —— 既可能是安全屋预摆掉落的快照，也可能是 Host
	## 收编扫描（≤0.5s）补发的动态掉落物。因此这里必须**轮询等待**而不是一次性查找。
	deadline = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		for throwable_id: String in NETWORK_THROWABLES.keys():
			source = _find_client_pickup_by_throwable_id(throwable_id)
			if is_instance_valid(source):
				td = NETWORK_THROWABLES[throwable_id] as ThrowableData
				break
		if is_instance_valid(source) and td != null:
			break
		await get_tree().create_timer(0.10).timeout
	if not is_instance_valid(node) or not is_instance_valid(source) or td == null:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_SETUP_FAILED player=%s source=%s td=%s" % [is_instance_valid(node), is_instance_valid(source), td != null])
		return
	var source_id := int(source.get("network_pickup_id"))
	var source_position := source.global_position
	var request_enabled := source_id > 0 and not bool(source.get("network_presentation_only"))
	if not request_enabled:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_REQUEST_DISABLED pickup=%d presentation_only=%s" % [source_id, source.get("network_presentation_only")])
		return
	# 通过生产输入移动，让 Host 的距离校验覆盖真实 Client -> Host 路径。
	var travel_delta := source_position - node.global_position
	if absf(travel_delta.x) > 8.0:
		Input.action_press("右" if travel_delta.x > 0.0 else "左")
		deadline = Time.get_ticks_msec() + 5000
		while Time.get_ticks_msec() < deadline and absf(source_position.x - node.global_position.x) > 16.0:
			await get_tree().create_timer(0.05).timeout
		Input.action_release("右" if travel_delta.x > 0.0 else "左")
	travel_delta = source_position - node.global_position
	if absf(travel_delta.y) > 8.0:
		Input.action_press("下" if travel_delta.y > 0.0 else "上")
		deadline = Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline and absf(source_position.y - node.global_position.y) > 16.0:
			await get_tree().create_timer(0.05).timeout
		Input.action_release("下" if travel_delta.y > 0.0 else "上")
	await get_tree().create_timer(0.08).timeout
	var in_range := node.global_position.distance_to(source_position) <= 28.0
	if not in_range:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_MOVE_FAILED player=%s source=%s" % [node.global_position, source_position])
		return
	# 进入范围时 HealingPickup 可能已通过生产逻辑自动提交请求；仍在场时再显式提交一次，
	# 覆盖 request_pickup() 路径但避免访问已释放的源节点。
	if _pickups.has(source_id):
		request_pickup(source_id)
	deadline = Time.get_ticks_msec() + 3000
	var acquired := false
	var removed := false
	while Time.get_ticks_msec() < deadline:
		entry = _players.get(int(net.my_peer_id), {})
		var state := entry.get("state") as PlayerState
		acquired = state != null and state.throwable == td
		removed = not _pickups.has(source_id)
		if acquired and removed:
			break
		await get_tree().create_timer(0.05).timeout
	print("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_COMPLETE pickup=%d acquired=%s removed=%s" % [source_id, acquired, removed])
	if not acquired or not removed:
		printerr("[NetworkWorld] AUTO_CLIENT_THROWABLE_PICKUP_FAILED pickup=%d acquired=%s removed=%s" % [source_id, acquired, removed])


## ⚠ 掉落物查找助手必须**先判 is_instance_valid(value) 再 as Node2D**：
## 对已释放对象做 `as Node2D` 会抛 "Trying to cast a freed object" 运行时错，
## 静默中止整个查找函数（2026-09-22 实测：Client 端 _pickups 残留已 queue_free
## 条目 → 查找恒返回 null → 投掷物拾取用例 SETUP_FAILED）。
func _find_client_pickup_by_throwable_id(item_id: String) -> Node2D:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var throwable := pickup.get("item") as ThrowableData
		if throwable and throwable.item_id == item_id:
			return pickup
	return null


func _find_client_pickup_by_weapon_id(weapon_id: String) -> Node2D:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		if weapon and weapon.item_id == weapon_id:
			return pickup
	return null


func _has_client_pickup_weapon_near(weapon_id: String, position: Vector2, max_distance: float) -> bool:
	for value: Variant in _pickups.values():
		if not is_instance_valid(value):
			continue
		var pickup := value as Node2D
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		if weapon and weapon.item_id == weapon_id and pickup.global_position.distance_to(position) <= max_distance:
			return true
	return false


## 自动双端烟测只从客户端已接收的 Host 敌人快照累计生命值；不读取或伪造 Host 命中结果。
## --net-test harness 专用：把玩家 HP 压到 1 再吃致死伤。
## ガッツ（HP≥2 保底 1 HP，player.gd）会拦下 harness 的 max_hp+1 致死伤
## （2026-09 加的机制没同步测试，features/downed-wipe 双双 setup 失败）。
## 压 HP=1 后 take_damage 链路原样保留（信号/倒地登记不变），只绕开保底语义。
func _force_auto_test_player_low_hp(node: CharacterBody2D) -> void:
	var state := Players.get_state_for_entity(node)
	if state:
		state.current_hp = 1.0
	node.current_hp = 1.0


## --net-test harness 专用：离给定坐标最近的**活**敌（Client 视角镜像节点）。
## 用于近战用例动态逼近——敌人由 Director 驱动会移动，固定走位会走空。
func _nearest_client_enemy_node(from_position: Vector2) -> CharacterBody2D:
	var best: CharacterBody2D = null
	var best_dist: float = INF
	for key: Variant in _enemies.keys():
		var enemy := _resolve_enemy_entry(_enemies[key] as Dictionary)
		if not is_instance_valid(enemy) or enemy.is_network_dead():
			continue
		var dist: float = from_position.distance_squared_to(enemy.global_position)
		if dist < best_dist:
			best_dist = dist
			best = enemy
	return best


## --net-test harness 专用：把客户端朝「最近的活敌」推进一小步（走正常输入键，不传送坐标）。
## 2026-09-23 第三轮稳定化：客户端成为刷怪锚点后，前方补位带（360~560px）里的怪会持续
## 补充/移动，近战用例必须"边贴边砍"才能在挥刀瞬间处于判定范围内。
## 调用方负责在随后的等待帧里松开方向键（与既有走位循环同款约定）。
func _auto_client_steer_toward_nearest_enemy() -> void:
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := _player_node(entry)
	if not is_instance_valid(node):
		return
	var target := _nearest_client_enemy_node(node.global_position)
	if not is_instance_valid(target):
		return
	var delta: Vector2 = target.global_position - node.global_position
	if absf(delta.x) > 4.0:
		Input.action_press("右" if delta.x > 0.0 else "左")
	if absf(delta.y) > 4.0:
		Input.action_press("下" if delta.y > 0.0 else "上")


## --net-test harness 专用：Client 视角各活敌的 hp 快照（entity_id → hp）。
## 判定近战伤害必须跟踪**同一只**敌人——Director 持续 scatter 刷新敌人，
## 用 hp 总和比较会被新入场敌人抬高（weapon 场景 140→280 假红的根因）。
func _get_client_enemy_hp_map() -> Dictionary:
	var map := {}
	for key: Variant in _enemies.keys():
		var enemy := _resolve_enemy_entry(_enemies[key])
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			map[int(key)] = enemy.current_hp
	return map


func _get_client_live_enemy_hp_total() -> float:
	var total := 0.0
	for enemy_entry: Dictionary in _enemies.values():
		var enemy := _resolve_enemy_entry(enemy_entry)
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			total += enemy.current_hp
	return total

