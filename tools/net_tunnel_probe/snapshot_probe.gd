extends Node
##
## 快照流带宽探针（测试工具，不属于正式游戏代码）
##
## 目的：用**与 script/network_world.gd 完全同构的数据结构**（27 字段玩家紧凑数组 +
## 9 字段敌人紧凑数组），按真实的 60Hz 频率，通过真实 ENet 经 UDP 中继发送，
## 测量 4 人局下 Host 单方向的真实字节占用。
##
## 与正式代码的对应关系（参数均抄自 network_world.gd）：
##   - PLAYER_SNAPSHOT_INTERVAL = 1/60（L120）
##   - SNAPSHOT_INTERVAL        = 1/60（L119，敌人/世界快照）
##   - 玩家紧凑数组字段顺序与 _build_compact_player_snapshot()（L4754）一致
##   - 敌人紧凑数组字段顺序与 _build_enemy_snapshot(compact=true)（L4657）一致
##
## 相关文档：`互联网联机模式策划方案.md` §12.3（实测报告）。
##
## 用法（由 runner.py 调用）：
##   Host  : ... --snap=host  --snap-port=27015 --snap-enemies=15 --snap-life=20
##   Client: ... --snap=client --snap-addr=<ip> --snap-port=<port> --snap-life=20

var _net: Node = null
var _role := ""
var _port := 27015
var _addr := "127.0.0.1"
var _enemy_count := 15
var _life := 20.0

const PLAYER_SNAPSHOT_INTERVAL := 1.0 / 60.0
const SNAPSHOT_INTERVAL := 1.0 / 60.0

var _player_accum := 0.0
var _enemy_accum := 0.0
var _sent_players := 0
var _sent_enemies := 0
var _run := true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a: String in OS.get_cmdline_user_args():
		if a == "--snap=host":
			_role = "host"
		elif a == "--snap=client":
			_role = "client"
		elif a.begins_with("--snap-port="):
			_port = a.trim_prefix("--snap-port=").to_int()
		elif a.begins_with("--snap-addr="):
			_addr = a.trim_prefix("--snap-addr=").strip_edges()
		elif a.begins_with("--snap-enemies="):
			_enemy_count = a.trim_prefix("--snap-enemies=").to_int()
		elif a.begins_with("--snap-life="):
			_life = a.trim_prefix("--snap-life=").to_float()
	if _role.is_empty():
		return
	_net = get_node_or_null("/root/Net")
	if _net == null:
		printerr("[SNAP] FATAL no /root/Net")
		get_tree().quit(2)
		return
	_net.player_name = "SnapHost" if _role == "host" else "SnapClient"
	_net.upnp_enabled = false
	if _role == "host":
		var err: int = _net.host_game(_port)
		if err != OK:
			printerr("[SNAP] HOST_FAIL")
			get_tree().quit(1)
			return
		print("[SNAP] HOST_LISTENING port=%d" % _port)
	else:
		var err2: int = _net.join_game(_addr, _port)
		if err2 != OK:
			printerr("[SNAP] CLIENT_FAIL")
			get_tree().quit(1)
			return
		print("[SNAP] CLIENT_JOINING %s:%d" % [_addr, _port])
	# 等握手完成再开始计数
	var t := 0.0
	while t < _life + 10.0 and not _net.handshake_ok:
		await get_tree().create_timer(0.2).timeout
		t += 0.2
	if not _net.handshake_ok:
		printerr("[SNAP] HANDSHAKE_TIMEOUT")
		get_tree().quit(3)
		return
	print("[SNAP] HANDSHAKE_OK role=%s enemies=%d" % [_role, _enemy_count])
	# 运行 _life 秒
	var elapsed := 0.0
	while elapsed < _life:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	_run = false
	print("[SNAP] DONE sent_players=%d sent_enemies=%d" % [_sent_players, _sent_enemies])
	get_tree().quit(0)

func _physics_process(delta: float) -> void:
	if not _run or _role.is_empty() or _net == null or not _net.handshake_ok:
		return
	if not _net.is_host:
		return
	if _net.get_peer_ids().size() <= 1:
		return
	_player_accum += delta
	_enemy_accum += delta
	if _player_accum >= PLAYER_SNAPSHOT_INTERVAL:
		_player_accum = fmod(_player_accum, PLAYER_SNAPSHOT_INTERVAL)
		var ps := _build_player_snapshot()
		for pid: int in _net.get_peer_ids():
			if pid <= 1:
				continue
			player_position_snapshot.rpc_id(pid, ps)
		_sent_players += 1
	if _enemy_accum >= SNAPSHOT_INTERVAL:
		_enemy_accum = fmod(_enemy_accum, SNAPSHOT_INTERVAL)
		var es := _build_enemy_snapshot()
		for pid2: int in _net.get_peer_ids():
			if pid2 <= 1:
				continue
			player_snapshot.rpc_id(pid2, [], es)
		_sent_enemies += 1

## 与 _build_compact_player_snapshot() 同构：27 字段。4 名玩家（Host 也要发）。
func _build_player_snapshot() -> Array:
	var states: Array = []
	for i in range(4):
		var ammo_counts := {"pistol_ammo": 60, "rifle_ammo": 120}
		states.append([
			100 + i, "玩家%d" % i, "res://object/character_nobita.tres",
			87.5, Vector2(1234.56, 789.01),
			1, true, false, "weapon_rifle",
			"weapon_rifle", "weapon_pistol", "primary",
			{"weapon_rifle": [30, 90], "weapon_pistol": [15, 45]},
			true, "",  # weapon_raised, weapon_transition
			"item_grenade", false, false,
			3, false, 30,
			false, -1.0, 0.0,  # downed, bleed_ratio, revive_progress
			0, Vector2.ZERO,   # facing_locked, locked_facing
			ammo_counts,
			"item_first_aid_spray", 1,
		])
	return states

## 与 _build_enemy_snapshot(compact=true) 同构：9 字段。
func _build_enemy_snapshot() -> Array:
	var states: Array = []
	for i in range(_enemy_count):
		states.append([
			200 + i,
			Vector2(1000.0 + i * 37.5, 500.0 - i * 21.25),
			3, 42.0, true, 1, false, false, 0,
		])
	return states

@rpc("authority", "call_remote", "unreliable_ordered")
func player_snapshot(player_states: Array, enemy_states: Array) -> void:
	pass

@rpc("authority", "call_remote", "unreliable_ordered")
func player_position_snapshot(player_states: Array) -> void:
	pass
