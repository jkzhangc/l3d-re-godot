extends Node
## 第一阶段联机世界：Host 全量权威移动，客户端只提交输入并渲染快照。
##
## 禁止使用 MultiplayerSpawner / MultiplayerSynchronizer；所有实体均由可靠 RPC 显式
## spawn/despawn，位置快照通过 unreliable_ordered 广播。

const PLAYER_SCENE: PackedScene = preload("res://object/player.tscn")
const BULLET_SCENE: PackedScene = preload("res://object/bullet.tscn")
const NETWORK_PISTOL: WeaponData = preload("res://object/weapon_pistol.tres")
const SNAPSHOT_INTERVAL := 1.0 / 20.0
const LOCAL_INPUT_INTERVAL := 1.0 / 30.0
const SPAWN_SEPARATION := 56.0

var _players: Dictionary = {} # peer_id -> {node, state, input, walking, moving}
var _bullets: Dictionary = {} # bullet_id -> Bullet Node2D
var _next_bullet_id := 1
var _last_fire_msec: Dictionary = {} # peer_id -> Time.get_ticks_msec()
var _snapshot_accumulator := 0.0
var _input_accumulator := 0.0
var _scene_path := ""
var _players_parent: Node = null
var _initial_world_received := false
var _last_logged_remote_input: Dictionary = {}
var _auto_client_fire_confirmed := false
var _auto_client_bullet_seen := false
## 避免依赖编辑器正在重载的全局 Autoload 标识符；运行时取常驻 Net 节点。
var net: Variant = null


func _ready() -> void:
	net = get_node_or_null("/root/Net")
	if not net:
		push_error("[NetworkWorld] 未找到 Net Autoload")
		return
	_scene_path = get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
	_players_parent = _find_players_parent()
	if not _players_parent:
		push_error("[NetworkWorld] 未找到预置 Player 的父节点")
		return

	net.peer_left.connect(_on_peer_left)
	net.game_scene_ready_received.connect(_on_game_scene_ready_received)

	if net.is_host:
		_host_initialize_world()
	else:
		# 先接管地图预置 Player，阻止其继续执行离线状态机；随后才告知 Host 场景已就绪。
		_client_initialize_world()
		# 不能直接对场景根 RPC：Host 可能尚在切图；Net 是常驻 Autoload，会缓冲 ready。
		net.report_game_scene_ready.rpc_id(1, _scene_path)
		if "--net-test=client" in OS.get_cmdline_user_args():
			call_deferred("_run_auto_client_input_test")
	print("[NetworkWorld] ready host=%s scene=%s" % [net.is_host, _scene_path])


func _exit_tree() -> void:
	if not is_instance_valid(net):
		return
	if net.peer_left.is_connected(_on_peer_left):
		net.peer_left.disconnect(_on_peer_left)
	if net.game_scene_ready_received.is_connected(_on_game_scene_ready_received):
		net.game_scene_ready_received.disconnect(_on_game_scene_ready_received)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(net):
		return
	_capture_fire_input()
	if net.is_host:
		_capture_host_input()
		_simulate_host_players(delta)
		_snapshot_accumulator += delta
		if _snapshot_accumulator >= SNAPSHOT_INTERVAL:
			_snapshot_accumulator = fmod(_snapshot_accumulator, SNAPSHOT_INTERVAL)
			player_snapshot.rpc(_build_snapshot())
	else:
		_capture_client_input(delta)


# ---------------------------------------------------------------- Host simulation

func _host_initialize_world() -> void:
	Players.clear_seats()
	var local_id: int = int(net.my_peer_id)
	var host_node := _find_preplaced_player()
	if host_node:
		_register_host_player(local_id, host_node, true)
	else:
		_register_host_player(local_id, _instantiate_player(_spawn_position(0), net.my_peer_id), true)
	_consume_pending_scene_ready()


func _client_initialize_world() -> void:
	# 地图预置 Player 的 _ready() 已按离线流程运行过；清空其座位映射后，
	# 将它复用为本客户端自己的网络表现实体，避免首个快照再生成一个 Player。
	Players.clear_seats()
	var local_id: int = int(net.my_peer_id)
	var local_node := _find_preplaced_player()
	if not local_node:
		local_node = _instantiate_player(_spawn_position(0), local_id)
	var state := _make_player_state("", local_node.current_hp)
	state.owner_peer_id = local_id
	state.position = local_node.global_position
	state.facing = local_node.facing
	var seat_index := Players.add_seat(state)
	local_node.configure_network_entity(local_id, local_id)
	_configure_network_loadout(state, local_node)
	Players.register_entity(local_node, seat_index)
	_players[local_id] = {
		"node": local_node,
		"state": state,
		"input": Vector2.ZERO,
		"moving": false,
		"walking": false,
	}
	_set_local_player(local_node, seat_index)
	print("[NetworkWorld] CLIENT_LOCAL_READY peer=%d" % local_id)


func _capture_fire_input() -> void:
	if not Input.is_action_just_pressed("确定键"):
		return
	if net.is_host:
		_try_host_fire(int(net.my_peer_id))
	elif _initial_world_received:
		# Client 只提交开火意图；位置、朝向、弹药和伤害全部由 Host 重建与校验。
		fire_request.rpc_id(1)


func _capture_host_input() -> void:
	if not _players.has(net.my_peer_id):
		return
	_set_input(net.my_peer_id, _read_local_direction(), Input.is_action_pressed("行走键"))


func _capture_client_input(delta: float) -> void:
	if not _initial_world_received:
		return
	_input_accumulator += delta
	if _input_accumulator < LOCAL_INPUT_INTERVAL:
		return
	_input_accumulator = fmod(_input_accumulator, LOCAL_INPUT_INTERVAL)
	submit_input.rpc_id(1, _read_local_direction(), Input.is_action_pressed("行走键"))


func _read_local_direction() -> Vector2:
	return Input.get_vector("左", "右", "上", "下")


func _set_input(peer_id: int, direction: Vector2, walking: bool) -> void:
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var normalized := direction.limit_length(1.0)
	entry["input"] = normalized
	entry["walking"] = walking
	_players[peer_id] = entry
	if net.is_host and peer_id != int(net.my_peer_id):
		var previous: Vector2 = _last_logged_remote_input.get(peer_id, Vector2.INF)
		if previous != normalized:
			_last_logged_remote_input[peer_id] = normalized
			print("[NetworkWorld] HOST_INPUT peer=%d dir=(%.2f, %.2f) walk=%s" % [peer_id, normalized.x, normalized.y, walking])


func _simulate_host_players(_delta: float) -> void:
	for key: Variant in _players.keys():
		var peer_id := int(key)
		var entry: Dictionary = _players[peer_id]
		var node := entry.get("node") as CharacterBody2D
		if not is_instance_valid(node):
			continue
		var direction: Vector2 = entry.get("input", Vector2.ZERO)
		var walking: bool = bool(entry.get("walking", false))
		var moving := not direction.is_zero_approx()
		node.velocity = direction * (node.walk_speed if walking else node.run_speed)
		if moving:
			node.update_facing(direction)
		node.move_and_slide()
		node.update_appearance(moving, walking)
		_sync_state_from_node(peer_id, node, moving, walking)


func _sync_state_from_node(peer_id: int, node: CharacterBody2D, moving: bool, walking: bool) -> void:
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var state := entry.get("state") as PlayerState
	if state:
		state.position = node.global_position
		state.facing = node.facing
		state.current_hp = node.current_hp
	entry["moving"] = moving
	entry["walking"] = walking
	_players[peer_id] = entry


func _register_host_player(peer_id: int, node: CharacterBody2D, is_preplaced: bool) -> void:
	if not is_instance_valid(node):
		return
	var state := _make_player_state("", node.current_hp)
	state.owner_peer_id = peer_id
	state.position = node.global_position
	state.facing = node.facing
	node.configure_network_entity(peer_id, peer_id)
	_configure_network_loadout(state, node)
	var seat_index := Players.add_seat(state)
	if not is_preplaced:
		node.global_position = _spawn_position(_players.size())
	Players.register_entity(node, seat_index)
	# Host 也走同一套表现初始化，保证新实体的角色、HP 和朝向与 PlayerState 一致。
	node.apply_network_spawn_state(state.character, state.current_hp, node.global_position, state.facing, true)
	if peer_id == net.my_peer_id:
		_set_local_player(node, seat_index)
	_players[peer_id] = {
		"node": node,
		"state": state,
		"input": Vector2.ZERO,
		"moving": false,
		"walking": false,
	}
	_sync_state_from_node(peer_id, node, false, false)
	print("[NetworkWorld] HOST_SPAWN peer=%d preplaced=%s" % [peer_id, is_preplaced])


func _add_host_peer(peer_id: int) -> void:
	if _players.has(peer_id):
		return
	var node := _instantiate_player(_spawn_position(_players.size()), peer_id)
	_register_host_player(peer_id, node, false)
	_broadcast_spawn_player(peer_id)


# ---------------------------------------------------------------- Host-authoritative combat

func _configure_network_loadout(state: PlayerState, node: CharacterBody2D) -> void:
	if not state or not is_instance_valid(node) or not NETWORK_PISTOL:
		return
	var slot := NETWORK_PISTOL.get_slot_key()
	state.equipment[slot] = NETWORK_PISTOL
	state.active_weapon_slot = slot
	state.set_magazine_ammo(NETWORK_PISTOL.item_id, NETWORK_PISTOL.magazine_capacity)
	node.enter_weapon_mode(NETWORK_PISTOL)
	node.set_weapon_ready_frame()


func _get_fire_cooldown_msec(wd: WeaponData) -> int:
	var seconds := 0.0
	for index: int in range(wd.attack_char_sequence.size()):
		seconds += wd.get_attack_frame_duration(index)
	seconds = maxf(0.1, seconds / maxf(0.01, wd.attack_speed))
	return int(roundi(seconds * 1000.0))


func _try_host_fire(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0:
		return
	var wd := state.get_active_weapon()
	if not wd or not wd.is_ranged or wd.magazine_capacity <= 0 or wd.bullet_list.is_empty():
		return
	var current := state.get_magazine_ammo(wd.item_id)
	if current <= 0:
		return
	var now := Time.get_ticks_msec()
	var cooldown_msec := _get_fire_cooldown_msec(wd)
	if now - int(_last_fire_msec.get(peer_id, -cooldown_msec)) < cooldown_msec:
		return
	_last_fire_msec[peer_id] = now
	state.set_magazine_ammo(wd.item_id, current - 1)
	_sync_state_from_node(peer_id, node, bool(entry.get("moving", false)), bool(entry.get("walking", false)))
	node.play_network_fire_presentation(wd)
	fire_presentation.rpc(peer_id, current - 1)
	var bullet_index := 0
	for bd: BulletData in wd.bullet_list:
		_spawn_host_bullet(peer_id, node, wd, bd, bullet_index)
		bullet_index += 1
	if wd.gunshot_range > 0.0:
		_alert_host_enemies(node, wd.gunshot_range)
	print("[NetworkWorld] HOST_FIRE peer=%d ammo=%d bullets=%d" % [peer_id, current - 1, wd.bullet_list.size()])


func _spawn_host_bullet(peer_id: int, shooter: CharacterBody2D, wd: WeaponData, bd: BulletData, bullet_index: int) -> void:
	var bullet_id := _next_bullet_id
	_next_bullet_id += 1
	var direction := bd.get_fire_direction(shooter.get_facing_vector())
	var start_position := shooter.global_position + direction * bd.spawn_offset + bd.get_extra_offset(shooter.facing)
	var bullet := BULLET_SCENE.instantiate() as Node2D
	if not bullet:
		return
	bullet.setup({
		"network_entity_id": bullet_id,
		"network_visual_only": false,
		"direction": direction,
		"speed": bd.speed,
		"max_range": bd.max_range,
		"damage": bd.get_effective_damage(wd.attack_power),
		"destroy_on_hit": bd.destroy_on_hit,
		"penetration": bd.penetration,
		"critical_rate": wd.critical_rate,
		"hit_effect_anim": wd.hit_effect_anim,
		"hit_effect_follow": wd.hit_effect_follow,
		"hit_effect_offset_override": wd.hit_effect_offset_override,
		"hit_sound": wd.hit_sound,
		"texture": bd.bullet_texture,
		"anim_frames": bd.bullet_anim_frames,
		"frame_duration": bd.bullet_frame_duration,
		"collision_size": bd.collision_size,
		"collision_offset": bd.collision_offset,
		"knockback_force": bd.knockback_force if bd.knockback_enabled else 0.0,
		"knockback_stun": bd.knockback_stun_duration if bd.knockback_enabled else 0.0,
		"hitstun_duration": bd.hitstun_duration if bd.hitstun_duration > 0.0 else wd.hitstun_duration,
		"shooter": shooter,
	})
	bullet.global_position = start_position
	get_tree().current_scene.add_child(bullet)
	_bullets[bullet_id] = bullet
	bullet.finished.connect(_on_host_bullet_finished)
	spawn_bullet.rpc(bullet_id, peer_id, start_position, direction, bullet_index)


func _on_host_bullet_finished(bullet_id: int) -> void:
	if not _bullets.has(bullet_id):
		return
	_bullets.erase(bullet_id)
	despawn_bullet.rpc(bullet_id)


func _alert_host_enemies(shooter: CharacterBody2D, range: float) -> void:
	for enemy: Node in get_tree().get_nodes_in_group("enemy"):
		if is_instance_valid(enemy) and enemy.global_position.distance_to(shooter.global_position) <= range and enemy.has_method("alert_by_gunshot"):
			enemy.alert_by_gunshot(shooter)


# ---------------------------------------------------------------- Explicit lifecycle and RPCs

@rpc("any_peer", "call_remote", "reliable")
func fire_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_fire(sender)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(direction: Vector2, walking: bool) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_set_input(sender, direction, walking)


@rpc("authority", "call_remote", "reliable")
func fire_presentation(peer_id: int, magazine_ammo: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var wd := state.get_active_weapon() if state else null
	if state and wd:
		state.set_magazine_ammo(wd.item_id, magazine_ammo)
	if is_instance_valid(node) and wd:
		node.play_network_fire_presentation(wd)
	if peer_id == int(net.my_peer_id):
		_auto_client_fire_confirmed = true


@rpc("authority", "call_remote", "reliable")
func spawn_bullet(bullet_id: int, shooter_peer_id: int, start_position: Vector2, direction: Vector2, bullet_index: int) -> void:
	if net.is_host or bullet_id <= 0 or _bullets.has(bullet_id):
		return
	var bd: Variant = _get_network_bullet_data(bullet_index)
	if not bd:
		return
	var bullet := BULLET_SCENE.instantiate() as Node2D
	if not bullet:
		return
	bullet.call("setup", {
		"network_entity_id": bullet_id,
		"network_visual_only": true,
		"direction": direction,
		"speed": bd.speed,
		"max_range": bd.max_range,
		"damage": 0.0,
		"texture": bd.bullet_texture,
		"anim_frames": bd.bullet_anim_frames,
		"frame_duration": bd.bullet_frame_duration,
	})
	bullet.global_position = start_position
	get_tree().current_scene.add_child(bullet)
	_bullets[bullet_id] = bullet
	bullet.connect("finished", _on_client_bullet_finished)
	_auto_client_bullet_seen = true
	print("[NetworkWorld] CLIENT_BULLET bullet=%d shooter=%d" % [bullet_id, shooter_peer_id])


@rpc("authority", "call_remote", "reliable")
func despawn_bullet(bullet_id: int) -> void:
	if net.is_host:
		return
	var bullet := _bullets.get(bullet_id) as Node
	_bullets.erase(bullet_id)
	if is_instance_valid(bullet):
		bullet.queue_free()


func _on_client_bullet_finished(bullet_id: int) -> void:
	_bullets.erase(bullet_id)


func _get_network_bullet_data(bullet_index: int) -> Variant:
	if not NETWORK_PISTOL or bullet_index < 0 or bullet_index >= NETWORK_PISTOL.bullet_list.size():
		return null
	return NETWORK_PISTOL.bullet_list[bullet_index]


@rpc("authority", "call_remote", "reliable")
func spawn_player(peer_id: int, public_state: Dictionary) -> void:
	if net.is_host:
		return
	_ensure_client_player(peer_id, public_state, true)


@rpc("authority", "call_remote", "reliable")
func despawn_player(peer_id: int) -> void:
	if net.is_host:
		return
	_remove_player(peer_id)


@rpc("authority", "call_remote", "reliable")
func world_snapshot(states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(states, true)
	_initial_world_received = _players.has(net.my_peer_id)
	print("[NetworkWorld] WORLD_SNAPSHOT players=%d local_ready=%s" % [states.size(), _initial_world_received])


@rpc("authority", "call_remote", "unreliable_ordered")
func player_snapshot(states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(states, false)


func _on_game_scene_ready_received(peer_id: int, ready_scene_path: String) -> void:
	if not net.is_host or ready_scene_path != _scene_path:
		return
	net.clear_pending_scene_ready(peer_id)
	_accept_ready_peer(peer_id)


func _consume_pending_scene_ready() -> void:
	if not net.is_host:
		return
	for peer_id: int in net.take_pending_scene_ready(_scene_path):
		_accept_ready_peer(peer_id)


func _accept_ready_peer(peer_id: int) -> void:
	if peer_id <= 1 or not net.get_player_names().has(peer_id):
		return
	_add_host_peer(peer_id)
	world_snapshot.rpc_id(peer_id, _build_snapshot())
	print("[NetworkWorld] WORLD_SNAPSHOT_SENT peer=%d" % peer_id)


func _on_peer_left(peer_id: int) -> void:
	if not net.is_host:
		return
	if _players.has(peer_id):
		_remove_player(peer_id)
		despawn_player.rpc(peer_id)
		print("[NetworkWorld] HOST_DESPAWN peer=%d" % peer_id)


func _broadcast_spawn_player(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	var packet := _public_state(peer_id)
	for target_id: int in net.get_peer_ids():
		if target_id > 1 and target_id != peer_id:
			spawn_player.rpc_id(target_id, peer_id, packet)


# ---------------------------------------------------------------- Client presentation

func _apply_client_snapshot(states: Array, snap: bool) -> void:
	var seen: Dictionary = {}
	for value: Variant in states:
		if not (value is Dictionary):
			continue
		var public_state := value as Dictionary
		var peer_id := int(public_state.get("peer_id", 0))
		if peer_id <= 0:
			continue
		seen[peer_id] = true
		_ensure_client_player(peer_id, public_state, snap)
	# 不可靠移动快照可能丢包或乱序；只允许可靠的 world_snapshot 收敛实体列表。
	if snap:
		for key: Variant in _players.keys():
			var existing_id := int(key)
			if not seen.has(existing_id):
				_remove_player(existing_id)


func _ensure_client_player(peer_id: int, public_state: Dictionary, snap: bool) -> void:
	var entry: Dictionary = _players.get(peer_id, {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node):
		node = _instantiate_player(_packet_position(public_state), peer_id)
		var state := _make_player_state(str(public_state.get("character_path", "")), float(public_state.get("hp", 1.0)))
		state.owner_peer_id = peer_id
		node.configure_network_entity(peer_id, peer_id)
		_configure_network_loadout(state, node)
		var seat_index := Players.add_seat(state)
		Players.register_entity(node, seat_index)
		entry = {"node": node, "state": state, "input": Vector2.ZERO, "moving": false, "walking": false}
		_players[peer_id] = entry
		if peer_id == net.my_peer_id:
			_set_local_player(node, seat_index)

	var state := entry.get("state") as PlayerState
	var character := _load_character(str(public_state.get("character_path", "")))
	if state:
		if character:
			state.character = character
			state.character_path = str(public_state.get("character_path", ""))
		state.current_hp = float(public_state.get("hp", state.current_hp))
		state.position = _packet_position(public_state)
		state.facing = int(public_state.get("facing", state.facing))
		# 移动快照只收敛 Host 已确认的弹夹数，绝不重新装备或重置武器状态。
		var weapon_id := str(public_state.get("weapon_id", ""))
		if not weapon_id.is_empty():
			state.set_magazine_ammo(
				weapon_id,
				int(public_state.get("magazine_ammo", state.get_magazine_ammo(weapon_id)))
			)
	# 只有可靠的 spawn/world snapshot 才能重置初始状态。移动快照不能先写入
	# stopped 状态再写回 moving，否则每个 20Hz 快照都会把 _anim_step 清零，
	# 客户端角色会永远停在同一张行走帧上。
	if snap:
		node.apply_network_spawn_state(character, float(public_state.get("hp", node.current_hp)), _packet_position(public_state), int(public_state.get("facing", 0)), true)
	else:
		node.current_hp = clampf(float(public_state.get("hp", node.current_hp)), 0.0, node.max_hp)
	node.apply_network_presentation(_packet_position(public_state), int(public_state.get("facing", 0)), bool(public_state.get("moving", false)), bool(public_state.get("walking", false)), snap)
	entry["moving"] = bool(public_state.get("moving", false))
	entry["walking"] = bool(public_state.get("walking", false))
	_players[peer_id] = entry


func _remove_player(peer_id: int) -> void:
	# 客户端在场景切换/丢失包期间绝不能因非完整快照销毁自己的预置实体。
	if not net.is_host and peer_id == int(net.my_peer_id):
		return
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as Node
	_players.erase(peer_id)
	if is_instance_valid(node):
		node.queue_free()


# ---------------------------------------------------------------- Automated smoke input

func _run_auto_client_input_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received:
		printerr("[NetworkWorld] AUTO_CLIENT_INPUT_TIMEOUT")
		return

	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var initial_ammo := state.get_magazine_ammo(NETWORK_PISTOL.item_id) if state else -1
	if initial_ammo != NETWORK_PISTOL.magazine_capacity:
		printerr("[NetworkWorld] AUTO_CLIENT_INITIAL_AMMO_FAILED ammo=%d expected=%d" % [initial_ammo, NETWORK_PISTOL.magazine_capacity])

	Input.action_press("右")
	var animation_frames: Dictionary = {}
	for _sample: int in range(8):
		await get_tree().create_timer(0.08).timeout
		var sample_entry: Dictionary = _players.get(int(net.my_peer_id), {})
		var sample_node := sample_entry.get("node") as CharacterBody2D
		if is_instance_valid(sample_node):
			var sample_sprite := sample_node.get_node_or_null("Sprite2D") as Sprite2D
			if sample_sprite:
				animation_frames[sample_sprite.region_rect.position.x] = true
	Input.action_release("右")
	await get_tree().create_timer(0.35).timeout
	entry = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
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
	Input.action_press("确定键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("确定键")
	deadline = Time.get_ticks_msec() + 3000
	while (not _auto_client_fire_confirmed or not _auto_client_bullet_seen) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var final_ammo := state.get_magazine_ammo(NETWORK_PISTOL.item_id) if state else -1
	var fire_ok := _auto_client_fire_confirmed and _auto_client_bullet_seen and final_ammo == NETWORK_PISTOL.magazine_capacity - 1
	print("[NetworkWorld] AUTO_CLIENT_FIRE_COMPLETE confirmed=%s bullet_seen=%s ammo=%d" % [
		_auto_client_fire_confirmed,
		_auto_client_bullet_seen,
		final_ammo,
	])
	if not fire_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_FIRE_FAILED confirmed=%s bullet_seen=%s ammo=%d" % [
			_auto_client_fire_confirmed,
			_auto_client_bullet_seen,
			final_ammo,
		])
	net.leave()
	get_tree().quit()


# ---------------------------------------------------------------- State serialisation / scene helpers

func _build_snapshot() -> Array:
	var states: Array = []
	for key: Variant in _players.keys():
		states.append(_public_state(int(key)))
	states.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["peer_id"]) < int(b["peer_id"]))
	return states


func _public_state(peer_id: int) -> Dictionary:
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var weapon: WeaponData = state.get_active_weapon() if state else null
	return {
		"peer_id": peer_id,
		"name": net.get_player_name(peer_id),
		"character_path": state.character_path if state else "",
		"hp": state.current_hp if state else node.current_hp,
		"position": node.global_position,
		"facing": node.facing,
		"moving": bool(entry.get("moving", false)),
		"walking": bool(entry.get("walking", false)),
		"weapon_id": weapon.item_id if weapon else "",
		"magazine_ammo": state.get_magazine_ammo(weapon.item_id) if state and weapon else 0,
	}


func _make_player_state(character_path: String, hp: float) -> PlayerState:
	var path := character_path if not character_path.is_empty() else Players.DEFAULT_CHARACTER_PATH
	var character := _load_character(path)
	var state := PlayerState.new()
	state.init_from_character(character, path)
	state.current_hp = hp if hp > 0.0 else state.get_max_hp()
	return state


func _load_character(path: String) -> CharacterData:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var resource := load(path)
	if resource is CharacterData:
		return (resource as CharacterData).duplicate() as CharacterData
	return null


func _packet_position(packet: Dictionary) -> Vector2:
	var position_value: Variant = packet.get("position", Vector2.ZERO)
	if position_value is Vector2:
		return position_value as Vector2
	if position_value is Dictionary:
		var dict := position_value as Dictionary
		return Vector2(float(dict.get("x", 0.0)), float(dict.get("y", 0.0)))
	return Vector2.ZERO


func _find_players_parent() -> Node:
	var preplaced := _find_preplaced_player()
	return preplaced.get_parent() if is_instance_valid(preplaced) else null


func _find_preplaced_player() -> CharacterBody2D:
	var scene := get_tree().current_scene
	if not scene:
		return null
	for node: Node in scene.get_tree().get_nodes_in_group("player"):
		if node is CharacterBody2D:
			return node as CharacterBody2D
	return null


func _instantiate_player(position: Vector2, peer_id: int = 0) -> CharacterBody2D:
	var node := PLAYER_SCENE.instantiate() as CharacterBody2D
	# Player._ready() 会在 add_child() 时执行，必须预先关闭单机状态机和自动座位注册。
	if peer_id > 0:
		node.configure_network_entity(peer_id, peer_id)
	node.global_position = position
	_players_parent.add_child(node)
	return node


func _spawn_position(index: int) -> Vector2:
	var anchor := _find_preplaced_player()
	var origin := anchor.global_position if is_instance_valid(anchor) else Vector2.ZERO
	return origin + Vector2(SPAWN_SEPARATION * index, 0.0)


func _set_local_player(node: Node2D, seat_index: int) -> void:
	Players.active_seat_index = seat_index
	Players.set_local_entity(node)
	var camera := get_tree().current_scene.find_child("Camera2D", true, false)
	if camera and camera.has_method("set_follow_target"):
		camera.set_follow_target(node)
