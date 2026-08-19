extends Node2D
## 最小 Host-authoritative 游戏世界。
## 生命周期使用 reliable RPC，运行状态使用显式 unreliable 快照。
## 刻意不依赖 MultiplayerSpawner/MultiplayerSynchronizer，避免动态属性路径问题。

const PLAYER_SCENE := preload("res://object/player.tscn")
const ENEMY_SCENE := preload("res://object/enemy.tscn")
const BULLET_SCENE := preload("res://object/bullet.tscn")

const ARENA_RECT := Rect2(-900.0, -550.0, 1800.0, 1100.0)
const PLAYER_SPEED := 220.0
const ENEMY_SPEED := 72.0
const BULLET_SPEED := 620.0
const SNAPSHOT_INTERVAL := 0.05
const ENEMY_SPAWN_INTERVAL := 2.5
const FIRE_COOLDOWN := 0.25
const PLAYER_MAX_HP := 100.0
const READY_RETRY_INTERVAL := 0.5

@onready var players_root: Node2D = $Players
@onready var enemies_root: Node2D = $Enemies
@onready var bullets_root: Node2D = $Bullets
@onready var camera: Camera2D = $Camera2D

var _players: Dictionary = {}
var _enemies: Dictionary = {}
var _bullets: Dictionary = {}
var _ready_peers: Dictionary = {}
var _enemy_counter := 1
var _bullet_counter := 1
var _enemy_spawn_timer := 0.35
var _snapshot_timer := 0.0
var _world_time := 0.0
var _initial_snapshot_applied := false
var _ready_retry_timer := 0.0
var _ready_attempts := 0

var _test_mode := ""
var _test_enemy_spawned := false
var _test_enemy_despawned := false
var _test_bullet_spawned := false
var _test_client_seen_enemy := false
var _test_client_seen_bullet := false
var _test_sent_result := false
var _test_damage_applied := false


func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	if "--net-test=host" in user_args:
		_test_mode = "host"
	elif "--net-test=client" in user_args:
		_test_mode = "client"
	$World/Ground.scale = Vector2(1800.0 / 64.0, 1100.0 / 64.0)
	if Net.is_host:
		Net.peer_left.connect(_on_peer_left)
		Net.game_scene_ready_received.connect(_on_game_scene_ready_received)
		_add_player(Net.my_peer_id, Vector2(-250.0, 0.0), false)
		call_deferred("_consume_pending_scene_ready")
		if _test_mode == "host":
			_spawn_enemy(Vector2(80.0, 0.0))
			_test_enemy_spawned = true
	else:
		if Net.has_network():
			call_deferred("_request_ready")
		else:
			print("[Game] offline observation mode")


func _exit_tree() -> void:
	if Net.peer_left.is_connected(_on_peer_left):
		Net.peer_left.disconnect(_on_peer_left)
	if Net.game_scene_ready_received.is_connected(_on_game_scene_ready_received):
		Net.game_scene_ready_received.disconnect(_on_game_scene_ready_received)


func _request_ready() -> void:
	if Net.is_host or not Net.has_network() or _initial_snapshot_applied:
		return
	_ready_attempts += 1
	_ready_retry_timer = READY_RETRY_INTERVAL
	Net.report_game_scene_ready.rpc_id(1, scene_file_path)
	print("[Game] GAME_READY sent attempt=%d via=/root/Net" % _ready_attempts)


func _process(delta: float) -> void:
	_world_time += delta
	var me := players_root.get_node_or_null(str(Net.my_peer_id)) as Node2D
	if me:
		camera.global_position = me.global_position
	if Net.is_host:
		_host_process(delta)
	else:
		_client_process(delta)
	if not _test_mode.is_empty():
		_run_test_checks()


# ---------------------------------------------------------------- host simulation

func _host_process(delta: float) -> void:
	if _players.has(Net.my_peer_id):
		var host_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
		var host_fire := Input.is_action_pressed("fire")
		if _test_mode == "host":
			host_dir = Vector2.RIGHT
			host_fire = true
		_set_input(Net.my_peer_id, host_dir, host_fire)
	for peer_id in _players.keys():
		_simulate_player(int(peer_id), delta)
	for enemy_id in _enemies.keys().duplicate():
		_simulate_enemy(int(enemy_id), delta)
	for bullet_id in _bullets.keys().duplicate():
		_simulate_bullet(int(bullet_id), delta)
	_enemy_spawn_timer -= delta
	if _test_mode != "host" and _enemy_spawn_timer <= 0.0:
		_enemy_spawn_timer = ENEMY_SPAWN_INTERVAL
		_spawn_enemy(_random_spawn_position())
	_snapshot_timer -= delta
	if _snapshot_timer <= 0.0:
		_snapshot_timer = SNAPSHOT_INTERVAL
		_broadcast_state_snapshot()


func _client_process(delta: float) -> void:
	if not Net.has_network():
		return
	if not _initial_snapshot_applied:
		_ready_retry_timer -= delta
		if _ready_retry_timer <= 0.0:
			_request_ready()
		return
	if not _players.has(Net.my_peer_id):
		return
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var firing := Input.is_action_pressed("fire")
	if _test_mode == "client":
		dir = Vector2.RIGHT
		firing = true
	submit_input.rpc_id(1, dir, firing)


func _set_input(peer_id: int, dir: Vector2, firing: bool) -> void:
	if not _players.has(peer_id):
		return
	var state: Dictionary = _players[peer_id]
	state["input"] = dir.limit_length(1.0)
	state["firing"] = firing
	_players[peer_id] = state


func _simulate_player(peer_id: int, delta: float) -> void:
	var state: Dictionary = _players[peer_id]
	if not bool(state["alive"]):
		if float(state["respawn_at"]) > 0.0 and _world_time >= float(state["respawn_at"]):
			state["alive"] = true
			state["hp"] = PLAYER_MAX_HP
			state["pos"] = Vector2(-250.0, 0.0)
			state["respawn_at"] = 0.0
			print("[Game] PLAYER_RESPAWN peer=%d" % peer_id)
		else:
			_players[peer_id] = state
			return
	var dir: Vector2 = state["input"]
	state["pos"] = (state["pos"] + dir * PLAYER_SPEED * delta).clamp(ARENA_RECT.position, ARENA_RECT.end)
	state["fire_cd"] = maxf(0.0, float(state["fire_cd"]) - delta)
	if bool(state["firing"]) and float(state["fire_cd"]) <= 0.0:
		state["fire_cd"] = FIRE_COOLDOWN
		_spawn_bullet(peer_id, state["pos"], _aim_direction(state["pos"], dir))
	_players[peer_id] = state
	_apply_player_node(peer_id, state)


func _simulate_enemy(enemy_id: int, delta: float) -> void:
	if not _enemies.has(enemy_id):
		return
	var state: Dictionary = _enemies[enemy_id]
	var target_id := _nearest_alive_player(state["pos"])
	if target_id < 0:
		return
	var target: Dictionary = _players[target_id]
	var to_target: Vector2 = target["pos"] - state["pos"]
	if to_target.length() > 30.0:
		state["pos"] += to_target.normalized() * ENEMY_SPEED * delta
	else:
		state["attack_cd"] = maxf(0.0, float(state["attack_cd"]) - delta)
		if float(state["attack_cd"]) <= 0.0:
			state["attack_cd"] = 1.0
			_damage_player(target_id, 12.0)
	_enemies[enemy_id] = state
	_apply_enemy_node(enemy_id, state)


func _simulate_bullet(bullet_id: int, delta: float) -> void:
	if not _bullets.has(bullet_id):
		return
	var state: Dictionary = _bullets[bullet_id]
	state["ttl"] = float(state["ttl"]) - delta
	state["pos"] += state["dir"] * float(state["speed"]) * delta
	var hit_enemy := -1
	for enemy_id in _enemies.keys():
		var enemy: Dictionary = _enemies[enemy_id]
		if state["pos"].distance_to(enemy["pos"]) < 22.0:
			hit_enemy = int(enemy_id)
			break
	if hit_enemy >= 0:
		var enemy: Dictionary = _enemies[hit_enemy]
		enemy["hp"] = float(enemy["hp"]) - 25.0
		if float(enemy["hp"]) <= 0.0:
			_enemy_despawn(hit_enemy)
		else:
			_enemies[hit_enemy] = enemy
		_remove_bullet(bullet_id)
		return
	if float(state["ttl"]) <= 0.0 or not ARENA_RECT.grow(100.0).has_point(state["pos"]):
		_remove_bullet(bullet_id)
		return
	_bullets[bullet_id] = state
	_apply_bullet_node(bullet_id, state)


func _damage_player(peer_id: int, damage: float) -> void:
	var state: Dictionary = _players[peer_id]
	state["hp"] = maxf(0.0, float(state["hp"]) - damage)
	if float(state["hp"]) <= 0.0:
		state["alive"] = false
		state["respawn_at"] = _world_time + 3.0
		print("[Game] PLAYER_DOWN peer=%d" % peer_id)
	_players[peer_id] = state
	_apply_player_node(peer_id, state)


# ---------------------------------------------------------------- entity lifecycle

func _add_player(peer_id: int, pos: Vector2, broadcast: bool = true) -> void:
	if _players.has(peer_id):
		return
	_players[peer_id] = {"id": peer_id, "name": Net.get_player_name(peer_id), "pos": pos, "hp": PLAYER_MAX_HP, "alive": true, "input": Vector2.ZERO, "firing": false, "fire_cd": 0.0, "respawn_at": 0.0}
	_ensure_player_node(peer_id, _players[peer_id])
	if broadcast:
		_broadcast_spawn_player(peer_id, _players[peer_id])
	print("[Game] SPAWN_PLAYER peer=%d" % peer_id)


func _ensure_player_node(peer_id: int, state: Dictionary) -> void:
	_players[peer_id] = _merge_player_state(_players.get(peer_id, {}), state)
	var merged: Dictionary = _players[peer_id]
	var node := players_root.get_node_or_null(str(peer_id)) as Node2D
	if node == null:
		node = PLAYER_SCENE.instantiate()
		node.name = str(peer_id)
		players_root.add_child(node)
	node.setup(peer_id, str(merged["name"]), merged["pos"], float(merged["hp"]), bool(merged["alive"]))


func _apply_player_node(peer_id: int, state: Dictionary) -> void:
	var node := players_root.get_node_or_null(str(peer_id))
	if node:
		node.setup(peer_id, str(state["name"]), state["pos"], float(state["hp"]), bool(state["alive"]))


func _merge_player_state(old: Dictionary, incoming: Dictionary) -> Dictionary:
	var result := old.duplicate()
	for key in incoming.keys():
		result[key] = incoming[key]
	if not result.has("input"):
		result["input"] = Vector2.ZERO
	if not result.has("firing"):
		result["firing"] = false
	if not result.has("fire_cd"):
		result["fire_cd"] = 0.0
	if not result.has("respawn_at"):
		result["respawn_at"] = 0.0
	return result


func _spawn_enemy(pos: Vector2) -> void:
	if not Net.is_host:
		return
	var enemy_id := _enemy_counter
	_enemy_counter += 1
	_enemies[enemy_id] = {"id": enemy_id, "pos": pos, "hp": 100.0, "alive": true, "attack_cd": 0.0}
	_ensure_enemy_node(enemy_id, _enemies[enemy_id])
	_broadcast_spawn_enemy(enemy_id, _enemies[enemy_id])
	print("[Game] SPAWN_ENEMY id=%d" % enemy_id)


func _ensure_enemy_node(enemy_id: int, state: Dictionary) -> void:
	var old: Dictionary = _enemies.get(enemy_id, {"attack_cd": 0.0})
	for key in state.keys():
		old[key] = state[key]
	_enemies[enemy_id] = old
	var node := enemies_root.get_node_or_null("E_%d" % enemy_id) as Node2D
	if node == null:
		node = ENEMY_SCENE.instantiate()
		node.name = "E_%d" % enemy_id
		enemies_root.add_child(node)
	node.setup(enemy_id, old["pos"], float(old["hp"]), bool(old["alive"]))
	if not Net.is_host:
		_test_client_seen_enemy = true


func _apply_enemy_node(enemy_id: int, state: Dictionary) -> void:
	var node := enemies_root.get_node_or_null("E_%d" % enemy_id)
	if node:
		node.setup(enemy_id, state["pos"], float(state["hp"]), bool(state["alive"]))


func _enemy_despawn(enemy_id: int) -> void:
	_enemies.erase(enemy_id)
	var node := enemies_root.get_node_or_null("E_%d" % enemy_id)
	if node:
		node.queue_free()
	_broadcast_despawn_enemy(enemy_id)
	_test_enemy_despawned = true
	print("[Game] DESPAWN_ENEMY id=%d" % enemy_id)


func _spawn_bullet(owner_id: int, pos: Vector2, dir: Vector2) -> void:
	var bullet_id := _bullet_counter
	_bullet_counter += 1
	var state := {"id": bullet_id, "owner": owner_id, "pos": pos, "dir": dir.normalized(), "speed": BULLET_SPEED, "ttl": 2.0}
	_bullets[bullet_id] = state
	_ensure_bullet_node(bullet_id, state)
	_broadcast_spawn_bullet(bullet_id, state)
	_test_bullet_spawned = true
	print("[Game] SPAWN_BULLET id=%d owner=%d" % [bullet_id, owner_id])


func _ensure_bullet_node(bullet_id: int, state: Dictionary) -> void:
	_bullets[bullet_id] = state.duplicate()
	var node := bullets_root.get_node_or_null("B_%d" % bullet_id) as Node2D
	if node == null:
		node = BULLET_SCENE.instantiate()
		node.name = "B_%d" % bullet_id
		bullets_root.add_child(node)
	node.setup(bullet_id, int(state["owner"]), state["pos"], state["dir"])
	if not Net.is_host:
		_test_client_seen_bullet = true


func _apply_bullet_node(bullet_id: int, state: Dictionary) -> void:
	var node := bullets_root.get_node_or_null("B_%d" % bullet_id)
	if node:
		node.setup(bullet_id, int(state["owner"]), state["pos"], state["dir"])


func _remove_bullet(bullet_id: int) -> void:
	_bullets.erase(bullet_id)
	var node := bullets_root.get_node_or_null("B_%d" % bullet_id)
	if node:
		node.queue_free()
	_broadcast_despawn_bullet(bullet_id)
	print("[Game] DESPAWN_BULLET id=%d" % bullet_id)


func _on_peer_left(peer_id: int) -> void:
	_ready_peers.erase(peer_id)
	_players.erase(peer_id)
	var node := players_root.get_node_or_null(str(peer_id))
	if node:
		node.queue_free()
	_broadcast_despawn_player(peer_id)
	print("[Game] DESPAWN_PLAYER peer=%d" % peer_id)


# ---------------------------------------------------------------- client to host RPC

@rpc("any_peer", "call_remote", "reliable")
func game_ready() -> void:
	# v2 兼容入口。v3 Client 改为向常驻 /root/Net 上报，避免 Host 切场景期间丢 RPC。
	if not Net.is_host:
		return
	_accept_ready_peer(multiplayer.get_remote_sender_id())


func _on_game_scene_ready_received(peer_id: int, ready_scene_path: String) -> void:
	if not Net.is_host or ready_scene_path != scene_file_path:
		return
	Net.clear_pending_scene_ready(peer_id)
	_accept_ready_peer(peer_id)


func _consume_pending_scene_ready() -> void:
	if not Net.is_host:
		return
	for peer_id in Net.take_pending_scene_ready(scene_file_path):
		_accept_ready_peer(peer_id)


func _accept_ready_peer(peer_id: int) -> void:
	if peer_id <= 1 or not Net.get_player_names().has(peer_id):
		return
	_ready_peers[peer_id] = true
	if not _players.has(peer_id):
		_add_player(peer_id, Vector2(-250.0, 100.0 + 60.0 * (_players.size() - 1)))
	world_snapshot.rpc_id(peer_id, _build_snapshot())
	print("[Game] SNAPSHOT_SENT peer=%d players=%d enemies=%d bullets=%d" % [peer_id, _players.size(), _enemies.size(), _bullets.size()])


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(dir: Vector2, firing: bool) -> void:
	if not Net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and _ready_peers.has(sender) and _players.has(sender):
		_set_input(sender, dir, firing)


# ---------------------------------------------------------------- host to client RPC

@rpc("authority", "call_remote", "reliable")
func spawn_player(peer_id: int, state: Dictionary) -> void:
	if not Net.is_host:
		_ensure_player_node(peer_id, state)
		print("[Game] REMOTE_SPAWN_PLAYER peer=%d" % peer_id)


@rpc("authority", "call_remote", "reliable")
func despawn_player(peer_id: int) -> void:
	if Net.is_host:
		return
	_players.erase(peer_id)
	var node := players_root.get_node_or_null(str(peer_id))
	if node:
		node.queue_free()
	print("[Game] REMOTE_DESPAWN_PLAYER peer=%d" % peer_id)


@rpc("authority", "call_remote", "reliable")
func spawn_enemy(enemy_id: int, state: Dictionary) -> void:
	if not Net.is_host:
		_ensure_enemy_node(enemy_id, state)
		print("[Game] REMOTE_SPAWN_ENEMY id=%d" % enemy_id)


@rpc("authority", "call_remote", "reliable")
func despawn_enemy(enemy_id: int) -> void:
	if Net.is_host:
		return
	_enemies.erase(enemy_id)
	var node := enemies_root.get_node_or_null("E_%d" % enemy_id)
	if node:
		node.queue_free()
	print("[Game] REMOTE_DESPAWN_ENEMY id=%d" % enemy_id)


@rpc("authority", "call_remote", "reliable")
func spawn_bullet(bullet_id: int, state: Dictionary) -> void:
	if not Net.is_host:
		_ensure_bullet_node(bullet_id, state)
		print("[Game] REMOTE_SPAWN_BULLET id=%d" % bullet_id)


@rpc("authority", "call_remote", "reliable")
func despawn_bullet(bullet_id: int) -> void:
	if Net.is_host:
		return
	_bullets.erase(bullet_id)
	var node := bullets_root.get_node_or_null("B_%d" % bullet_id)
	if node:
		node.queue_free()
	print("[Game] REMOTE_DESPAWN_BULLET id=%d" % bullet_id)


@rpc("authority", "call_remote", "unreliable_ordered")
func state_snapshot(snapshot: Dictionary) -> void:
	if not Net.is_host:
		_apply_snapshot(snapshot)


@rpc("authority", "call_remote", "reliable")
func world_snapshot(snapshot: Dictionary) -> void:
	if not Net.is_host:
		_apply_snapshot(snapshot)
		_initial_snapshot_applied = _players.has(Net.my_peer_id)
		print("[Game] SNAPSHOT_APPLIED local_player=%s attempts=%d" % [_initial_snapshot_applied, _ready_attempts])


func _broadcast_spawn_player(peer_id: int, state: Dictionary) -> void:
	for ready_id in _ready_peers.keys():
		spawn_player.rpc_id(int(ready_id), peer_id, _player_public_state(state))


func _broadcast_despawn_player(peer_id: int) -> void:
	for ready_id in _ready_peers.keys():
		despawn_player.rpc_id(int(ready_id), peer_id)


func _broadcast_spawn_enemy(enemy_id: int, state: Dictionary) -> void:
	for ready_id in _ready_peers.keys():
		spawn_enemy.rpc_id(int(ready_id), enemy_id, _enemy_public_state(state))


func _broadcast_despawn_enemy(enemy_id: int) -> void:
	for ready_id in _ready_peers.keys():
		despawn_enemy.rpc_id(int(ready_id), enemy_id)


func _broadcast_spawn_bullet(bullet_id: int, state: Dictionary) -> void:
	for ready_id in _ready_peers.keys():
		spawn_bullet.rpc_id(int(ready_id), bullet_id, _bullet_public_state(state))


func _broadcast_despawn_bullet(bullet_id: int) -> void:
	for ready_id in _ready_peers.keys():
		despawn_bullet.rpc_id(int(ready_id), bullet_id)


func _broadcast_state_snapshot() -> void:
	if _ready_peers.is_empty():
		return
	var snapshot := _build_state_snapshot()
	for ready_id in _ready_peers.keys():
		state_snapshot.rpc_id(int(ready_id), snapshot)


# ---------------------------------------------------------------- snapshots

func _apply_snapshot(snapshot: Dictionary) -> void:
	if snapshot.has("players"):
		var player_ids := {}
		for value in snapshot["players"]:
			var state: Dictionary = value
			var entity_id := int(state["id"])
			player_ids[entity_id] = true
			_ensure_player_node(entity_id, state)
		_remove_missing_nodes(players_root, player_ids, "", _players)
	if snapshot.has("enemies"):
		var enemy_ids := {}
		for value in snapshot["enemies"]:
			var state: Dictionary = value
			var entity_id := int(state["id"])
			enemy_ids[entity_id] = true
			_ensure_enemy_node(entity_id, state)
		_remove_missing_nodes(enemies_root, enemy_ids, "E_", _enemies)
	if snapshot.has("bullets"):
		var bullet_ids := {}
		for value in snapshot["bullets"]:
			var state: Dictionary = value
			var entity_id := int(state["id"])
			bullet_ids[entity_id] = true
			_ensure_bullet_node(entity_id, state)
		_remove_missing_nodes(bullets_root, bullet_ids, "B_", _bullets)


func _remove_missing_nodes(root: Node2D, live_ids: Dictionary, prefix: String, state_store: Dictionary) -> void:
	for node in root.get_children():
		if node is not Node2D:
			continue
		var entity_id := str(node.name).trim_prefix(prefix).to_int()
		if not live_ids.has(entity_id):
			state_store.erase(entity_id)
			node.queue_free()


func _build_snapshot() -> Dictionary:
	var snapshot := _build_state_snapshot()
	snapshot["bullets"] = []
	for state in _bullets.values():
		snapshot["bullets"].append(_bullet_public_state(state))
	return snapshot


func _build_state_snapshot() -> Dictionary:
	var snapshot := {"players": [], "enemies": []}
	for state in _players.values():
		snapshot["players"].append(_player_public_state(state))
	for state in _enemies.values():
		snapshot["enemies"].append(_enemy_public_state(state))
	return snapshot


func _player_public_state(state: Dictionary) -> Dictionary:
	return {"id": state["id"], "name": state["name"], "pos": state["pos"], "hp": state["hp"], "alive": state["alive"]}


func _enemy_public_state(state: Dictionary) -> Dictionary:
	return {"id": state["id"], "pos": state["pos"], "hp": state["hp"], "alive": state["alive"]}


func _bullet_public_state(state: Dictionary) -> Dictionary:
	return {"id": state["id"], "owner": state["owner"], "pos": state["pos"], "dir": state["dir"], "speed": state["speed"], "ttl": state["ttl"]}


func get_network_sync_status() -> String:
	if Net.is_host:
		return "Host 权威世界已启动"
	if _initial_snapshot_applied:
		return "世界快照已同步"
	return "等待 Host 世界快照（ready 重试 %d）" % _ready_attempts


# ---------------------------------------------------------------- helpers / test

func _nearest_alive_player(pos: Vector2) -> int:
	var result := -1
	var best := INF
	for peer_id in _players.keys():
		var state: Dictionary = _players[peer_id]
		if bool(state["alive"]):
			var distance := pos.distance_squared_to(state["pos"])
			if distance < best:
				best = distance
				result = int(peer_id)
	return result


func _aim_direction(pos: Vector2, fallback: Vector2) -> Vector2:
	var target_id := _nearest_alive_enemy(pos)
	if target_id >= 0:
		return (_enemies[target_id]["pos"] - pos).normalized()
	return fallback.normalized() if fallback != Vector2.ZERO else Vector2.RIGHT


func _nearest_alive_enemy(pos: Vector2) -> int:
	var result := -1
	var best := INF
	for enemy_id in _enemies.keys():
		var state: Dictionary = _enemies[enemy_id]
		var distance := pos.distance_squared_to(state["pos"])
		if distance < best:
			best = distance
			result = int(enemy_id)
	return result


func _random_spawn_position() -> Vector2:
	return Vector2(randf_range(-750.0, 750.0), randf_range(-400.0, 400.0))


func _run_test_checks() -> void:
	if _test_mode == "host" and not _test_damage_applied and _world_time >= 1.5:
		var damage_target := _first_client_id()
		if damage_target > 1:
			_damage_player(damage_target, 10.0)
			_test_damage_applied = true
	if _test_mode == "host" and not _test_sent_result and _world_time >= 5.0:
		_test_sent_result = true
		var client_state: Dictionary = _players.get(_first_client_id(), {})
		var moved := not client_state.is_empty() and float(client_state["pos"].x) > -220.0
		var hp_changed := not client_state.is_empty() and float(client_state["hp"]) < PLAYER_MAX_HP
		var ok := _players.size() >= 2 and moved and hp_changed and _test_enemy_spawned and _test_bullet_spawned and _test_enemy_despawned
		var message := "players=%d moved=%s hp_sync_source=%s enemy_spawn=%s bullet_spawn=%s enemy_despawn=%s" % [_players.size(), moved, hp_changed, _test_enemy_spawned, _test_bullet_spawned, _test_enemy_despawned]
		print("[AUTO] host %s %s" % ["PASS" if ok else "FAIL", message])
		for ready_id in _ready_peers.keys():
			test_result.rpc_id(int(ready_id), ok, message)
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0 if ok else 1)
	elif _test_mode == "client" and not _test_sent_result and _world_time >= 10.0:
		_test_sent_result = true
		printerr("[AUTO] client TIMEOUT players=%d enemy=%s bullet=%s" % [_players.size(), _test_client_seen_enemy, _test_client_seen_bullet])
		get_tree().quit(1)


@rpc("authority", "call_remote", "reliable")
func test_result(ok: bool, message: String) -> void:
	if Net.is_host:
		return
	_test_sent_result = true
	var my_state: Dictionary = _players.get(Net.my_peer_id, {})
	var moved := not my_state.is_empty() and float(my_state["pos"].x) > -220.0
	var hp_synced := not my_state.is_empty() and float(my_state["hp"]) < PLAYER_MAX_HP
	var client_ok := ok and _players.size() >= 2 and moved and hp_synced and _test_client_seen_enemy and _test_client_seen_bullet
	print("[AUTO] client %s host_ok=%s local_players=%d moved=%s hp_synced=%s enemy=%s bullet=%s %s" % ["PASS" if client_ok else "FAIL", ok, _players.size(), moved, hp_synced, _test_client_seen_enemy, _test_client_seen_bullet, message])
	get_tree().quit(0 if client_ok else 1)


func _first_client_id() -> int:
	for peer_id in _players.keys():
		if int(peer_id) != 1:
			return int(peer_id)
	return -1
