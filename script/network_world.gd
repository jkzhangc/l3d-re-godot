extends Node
## 第一阶段联机世界：Host 全量权威移动，客户端只提交输入并渲染快照。
##
## 禁止使用 MultiplayerSpawner / MultiplayerSynchronizer；所有实体均由可靠 RPC 显式
## spawn/despawn，位置快照通过 unreliable_ordered 广播。

const PLAYER_SCENE: PackedScene = preload("res://object/player.tscn")
const BULLET_SCENE: PackedScene = preload("res://object/bullet.tscn")
const ENEMY_SCENE: PackedScene = preload("res://object/enemy.tscn")
const PICKUP_SCENE: PackedScene = preload("res://object/weapon_pickup.tscn")
const NETWORK_PISTOL: WeaponData = preload("res://object/weapon_pistol.tres")
const NETWORK_KNIFE: WeaponData = preload("res://object/weapon_knife.tres")
const NETWORK_RIFLE: WeaponData = preload("res://object/weapon_rifle.tres")
const NETWORK_SMG: WeaponData = preload("res://object/weapon_smg.tres")
const NETWORK_SHOTGUN: WeaponData = preload("res://object/weapon_shotgun.tres")
## 联机武器必须从 Host 固定白名单解析，绝不根据客户端输入动态 load() 资源。
const NETWORK_WEAPONS: Dictionary = {
	"pistol_01": NETWORK_PISTOL,
	"knife_01": NETWORK_KNIFE,
	"rifle_01": NETWORK_RIFLE,
	"smg_01": NETWORK_SMG,
	"shotgun_01": NETWORK_SHOTGUN,
}
const SNAPSHOT_INTERVAL := 1.0 / 20.0
const LOCAL_INPUT_INTERVAL := 1.0 / 30.0
const SPAWN_SEPARATION := 56.0

var _players: Dictionary = {} # peer_id -> {node, state, input, walking, moving}
var _enemies: Dictionary = {} # entity_id -> {node, scene_path}
var _next_enemy_id := 1
var _pickups: Dictionary = {} # pickup_id -> WeaponPickup
var _next_pickup_id := 1
## safe-door path -> { peer_id: true }; the Host owns readiness.
var _safe_door_ready: Dictionary = {}
var _door_ready_status: Dictionary = {}
var _bullets: Dictionary = {} # bullet_id -> Bullet Node2D
var _next_bullet_id := 1
## 攻击冷却按「玩家 + Host 当前武器」独立记录，避免切换武器后互相影响。
var _last_attack_msec: Dictionary = {}
var _snapshot_accumulator := 0.0
var _input_accumulator := 0.0
var _scene_path := ""
var _players_parent: Node = null
var _initial_world_received := false
## Net 在双方真正换图前发出的过渡信号；置位后本场景不再发送任何 RPC，避免旧节点路径的在途包。
var _scene_transitioning := false
var _last_logged_remote_input: Dictionary = {}
var _auto_client_fire_confirmed := false
var _auto_client_bullet_seen := false
## 自动双端回归统计本次攻击由 Host 确认并生成的视觉弹丸数量。
## 这会让单发步枪和多弹丸霰弹枪都能验证，而不是仅检查「至少看到一颗」。
var _auto_client_bullets_seen := 0
var _auto_client_attack_weapon_id := ""
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
	net.scene_transition_started.connect(_on_scene_transition_started)

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
	if net.scene_transition_started.is_connected(_on_scene_transition_started):
		net.scene_transition_started.disconnect(_on_scene_transition_started)


func _on_scene_transition_started(target_scene_path: String) -> void:
	## 两端在同一可靠 start_game RPC 内进入静默期，保留旧树短暂排空此前的 RPC。
	if _scene_transitioning:
		return
	_scene_transitioning = true
	print("[NetworkWorld] SCENE_TRANSITION_QUIET current=%s target=%s" % [_scene_path, target_scene_path])


func _physics_process(delta: float) -> void:
	if not is_instance_valid(net) or _scene_transitioning:
		return
	_capture_weapon_switch_input()
	_capture_weapon_raise_input()
	_capture_fire_input()
	if net.is_host:
		_capture_host_input()
		_simulate_host_players(delta)
		_register_untracked_host_enemies()
		_refresh_host_safe_door_readiness()
		_snapshot_accumulator += delta
		if _snapshot_accumulator >= SNAPSHOT_INTERVAL:
			_snapshot_accumulator = fmod(_snapshot_accumulator, SNAPSHOT_INTERVAL)
			# 高频不可靠快照使用紧凑数组格式，避免敌人数量增长后超过 ENet MTU。
			player_snapshot.rpc(_build_snapshot(), _build_enemy_snapshot(true))
	else:
		_capture_client_input(delta)


# ---------------------------------------------------------------- Host simulation

func _host_initialize_world() -> void:
	# Scene switching must only discard old node bindings. Persistent PlayerState lives in Net.
	Players.clear_entity_bindings()
	var local_id: int = int(net.my_peer_id)
	var host_node := _find_preplaced_player()
	if host_node:
		_register_host_player(local_id, host_node, true)
	else:
		_register_host_player(local_id, _instantiate_player(_spawn_position(0), local_id), true)
	for peer_id: int in net.get_peer_ids():
		if peer_id > 1:
			_register_host_player(peer_id, _instantiate_player(_spawn_position(_players.size()), peer_id), false)
	# 若本轮 start_game 前客户端已报告 ready，先把其权威实体在 Host 场景里重建出来。
	for peer_id: int in net.take_pending_scene_ready(_scene_path):
		_add_host_peer(peer_id)
	# Enemy/Pickup joins its groups from _ready(), so scan after the scene is completely ready.
	call_deferred("_finish_host_world_initialization")


func _finish_host_world_initialization() -> void:
	if not is_instance_valid(self) or not net.is_host:
		return
	_register_initial_host_enemies()
	_register_initial_host_pickups()
	_consume_pending_scene_ready()


func _client_initialize_world() -> void:
	# Keep snapshot data during map loads, only invalidate scene-node bindings.
	Players.clear_entity_bindings()
	var local_id: int = int(net.my_peer_id)
	var local_node := _find_preplaced_player()
	if not local_node:
		local_node = _instantiate_player(_spawn_position(0), local_id)
	var state := _find_or_create_player_state(local_id, "", local_node.current_hp)
	state.owner_peer_id = local_id
	state.position = local_node.global_position
	state.facing = local_node.facing
	var seat_index := _ensure_player_state_seat(state)
	local_node.configure_network_entity(local_id, local_id)
	local_node.exit_weapon_mode()
	Players.register_entity(local_node, seat_index)
	_players[local_id] = {
		"node": local_node,
		"state": state,
		"input": Vector2.ZERO,
		"moving": false,
		"walking": false,
	}
	_set_local_player(local_node, seat_index)
	_prepare_client_preplaced_enemies()
	_prepare_client_preplaced_pickups()
	print("[NetworkWorld] CLIENT_LOCAL_READY peer=%d" % local_id)


func _capture_weapon_switch_input() -> void:
	if Input.is_action_just_pressed("主武器键"):
		_request_weapon_switch("primary")
	elif Input.is_action_just_pressed("副武器键"):
		_request_weapon_switch("secondary")


func _capture_weapon_raise_input() -> void:
	if not Input.is_action_just_pressed("举起放下武器键"):
		return
	if net.is_host:
		_try_host_toggle_weapon(int(net.my_peer_id))
	elif _initial_world_received:
		weapon_toggle_request.rpc_id(1)


func _request_weapon_switch(slot: String) -> void:
	if net.is_host:
		_try_host_weapon_switch(int(net.my_peer_id), slot)
	elif _initial_world_received:
		# Client 只提交槽位意图；Host 从自身 PlayerState 校验真实装备。
		weapon_switch_request.rpc_id(1, slot)


func _capture_fire_input() -> void:
	if not Input.is_action_just_pressed("确定键"):
		return
	if net.is_host:
		_try_host_attack(int(net.my_peer_id))
	elif _initial_world_received:
		# Client 只提交攻击意图；位置、朝向、武器、弹药和伤害均由 Host 重建与校验。
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
	if not is_instance_valid(node) or _players.has(peer_id):
		return
	var state := _find_or_create_player_state(peer_id, "", node.current_hp)
	state.owner_peer_id = peer_id
	state.position = node.global_position
	state.facing = node.facing
	node.configure_network_entity(peer_id, peer_id)
	if _is_network_regression_loadout():
		_configure_network_loadout(state, node)
	else:
		node.exit_weapon_mode()
	var seat_index := _ensure_player_state_seat(state)
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

func _is_network_regression_loadout() -> bool:
	return "--net-test=host" in OS.get_cmdline_user_args() and _get_network_primary_loadout_weapon() != null


func _configure_network_loadout(state: PlayerState, node: CharacterBody2D) -> void:
	var primary_weapon := _get_network_primary_loadout_weapon()
	if not state or not is_instance_valid(node) or not primary_weapon or not NETWORK_KNIFE:
		return
	# 不使用 WeaponData.weapon_slot：现有手枪和小刀资源都写成了 1。
	# 正常联机默认手枪；无头回归可由本机启动参数选择白名单中的主武器，仍不接受 Client RPC 的武器数据。
	state.equipment["primary"] = primary_weapon
	state.equipment["secondary"] = NETWORK_KNIFE
	state.active_weapon_slot = "primary"
	state.set_magazine_ammo(primary_weapon.item_id, primary_weapon.magazine_capacity)
	node.enter_weapon_mode(primary_weapon)
	node.set_weapon_ready_frame()


func _get_network_primary_loadout_weapon() -> WeaponData:
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--net-test-weapon="):
			continue
		var weapon_id := argument.trim_prefix("--net-test-weapon=")
		var requested := _get_network_weapon_data_by_id(weapon_id)
		if requested and requested.is_ranged:
			return requested
		push_warning("[NetworkWorld] 忽略无效的联机回归主武器: %s" % weapon_id)
	return null


func _get_network_weapon_data_by_id(weapon_id: String) -> WeaponData:
	return NETWORK_WEAPONS.get(weapon_id) as WeaponData


func _get_attack_cooldown_msec(wd: WeaponData) -> int:
	var seconds := 0.0
	if wd.is_ranged:
		for index: int in range(wd.attack_char_sequence.size()):
			seconds += wd.get_attack_frame_duration(index)
	else:
		var melee_sequence: Array[int] = wd.get_melee_attack_char_sequence()
		for index: int in range(melee_sequence.size()):
			seconds += wd.get_melee_attack_frame_duration(index)
	seconds = maxf(0.1, seconds / maxf(0.01, wd.attack_speed))
	return int(roundi(seconds * 1000.0))


func _try_host_weapon_switch(peer_id: int, slot: String) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	if slot != "primary" and slot != "secondary":
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0:
		return
	var wd := state.get_equipped_weapon(slot)
	if not wd or state.active_weapon_slot == slot:
		return
	state.active_weapon_slot = slot
	if node.is_weapon_mode_active():
		node.enter_weapon_mode(wd)
		node.set_weapon_ready_frame()
	print("[NetworkWorld] HOST_WEAPON_SWITCH peer=%d slot=%s weapon=%s" % [peer_id, slot, wd.item_id])


func _try_host_toggle_weapon(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var wd: WeaponData = state.get_active_weapon() if state else null
	if not is_instance_valid(node) or not wd or node.current_hp <= 0.0:
		return
	if node.is_weapon_mode_active():
		node.exit_weapon_mode()
	else:
		node.enter_weapon_mode(wd)
		node.set_weapon_ready_frame()
	print("[NetworkWorld] HOST_WEAPON_TOGGLE peer=%d raised=%s" % [peer_id, node.is_weapon_mode_active()])


func _try_host_attack(peer_id: int) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(node) or not state or node.current_hp <= 0.0:
		return
	# 武器完全从 Host 当前 PlayerState 读取，客户端 RPC 不携带 weapon_id/目标/伤害等参数。
	var wd := state.get_active_weapon()
	if not wd or not node.is_weapon_mode_active():
		return
	var now := Time.get_ticks_msec()
	var cooldown_msec := _get_attack_cooldown_msec(wd)
	var attack_key := "%d:%s" % [peer_id, wd.item_id]
	if now - int(_last_attack_msec.get(attack_key, -cooldown_msec)) < cooldown_msec:
		return
	_last_attack_msec[attack_key] = now

	if wd.is_ranged:
		if wd.magazine_capacity <= 0 or wd.bullet_list.is_empty():
			return
		var current := state.get_magazine_ammo(wd.item_id)
		if current <= 0:
			return
		state.set_magazine_ammo(wd.item_id, current - 1)
		_sync_state_from_node(peer_id, node, bool(entry.get("moving", false)), bool(entry.get("walking", false)))
		node.play_network_attack_presentation(wd)
		attack_presentation.rpc(peer_id, wd.item_id, current - 1)
		var bullet_index := 0
		for bd: BulletData in wd.bullet_list:
			_spawn_host_bullet(peer_id, node, wd, bd, bullet_index)
			bullet_index += 1
		if wd.gunshot_range > 0.0:
			_alert_host_enemies(node, wd.gunshot_range)
		print("[NetworkWorld] HOST_FIRE peer=%d ammo=%d bullets=%d" % [peer_id, current - 1, wd.bullet_list.size()])
		return

	var is_headshot := wd.critical_rate > 0.0 and randf() * 100.0 < wd.critical_rate
	node.play_network_attack_presentation(wd)
	# -1 表示近战无弹夹变化；客户端只播放 Host 确认的表现。
	attack_presentation.rpc(peer_id, wd.item_id, -1)
	_schedule_host_melee_hit(node, wd, is_headshot)
	print("[NetworkWorld] HOST_MELEE peer=%d weapon=%s" % [peer_id, wd.item_id])


func _schedule_host_melee_hit(node: CharacterBody2D, wd: WeaponData, is_headshot: bool) -> void:
	# 避免切图释放 NetworkWorld 后，旧协程再访问空的 SceneTree。
	if not is_inside_tree():
		return
	var tree := get_tree()
	if not tree:
		return
	var delay := 0.0
	for index: int in range(mini(wd.melee_hit_at_sequence_idx, wd.get_melee_attack_char_sequence().size())):
		delay += wd.get_melee_attack_frame_duration(index)
	if delay > 0.0:
		await tree.create_timer(delay).timeout
	if is_inside_tree() and is_instance_valid(node) and node.is_inside_tree():
		_perform_host_melee_attack(node, wd, is_headshot)


func _perform_host_melee_attack(node: CharacterBody2D, wd: WeaponData, is_headshot: bool) -> void:
	var shape := RectangleShape2D.new()
	shape.size = wd.melee_range_size
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = Transform2D(0.0, node.global_position + node.get_facing_vector() * wd.melee_range_forward_offset)
	query.collision_mask = 24 # 敌人 body (layer 4) + hurtbox (layer 5)
	query.exclude = [node.get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = true
	# NetworkWorld 是普通 Node；物理 World2D 应从挥刀者这个 CanvasItem 取得。
	var results: Array[Dictionary] = node.get_world_2d().direct_space_state.intersect_shape(query, 64)
	var hit_enemy_ids: Dictionary = {}
	for result: Dictionary in results:
		var collider := result.get("collider") as Node
		if not is_instance_valid(collider):
			continue
		for enemy_entry: Dictionary in _enemies.values():
			var enemy := enemy_entry.get("node") as CharacterBody2D
			if not is_instance_valid(enemy) or enemy.get("_is_dead") == true:
				continue
			if collider != enemy and not enemy.is_ancestor_of(collider):
				continue
			var enemy_id := enemy.get_instance_id()
			if hit_enemy_ids.has(enemy_id):
				break
			hit_enemy_ids[enemy_id] = true
			enemy.take_damage(wd.get_effective_damage(), 0.0, node.get_facing_vector(), is_headshot, 0.0, wd.hitstun_duration)
			print("[NetworkWorld] HOST_MELEE_HIT enemy=%s damage=%d headshot=%s" % [enemy.name, int(wd.get_effective_damage()), is_headshot])
			break


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
	# Client 只从 Host 确认的白名单 weapon_id + 弹丸索引还原视觉弹道，绝不接收伤害或子弹数据对象。
	spawn_bullet.rpc(bullet_id, peer_id, start_position, direction, wd.item_id, bullet_index)


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
func weapon_switch_request(slot: String) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_weapon_switch(sender, slot)


@rpc("any_peer", "call_remote", "reliable")
func weapon_toggle_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_toggle_weapon(sender)


@rpc("any_peer", "call_remote", "reliable")
func fire_request() -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_try_host_attack(sender)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_input(direction: Vector2, walking: bool) -> void:
	if not net.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not _players.has(sender):
		return
	_set_input(sender, direction, walking)


@rpc("authority", "call_remote", "reliable")
func attack_presentation(peer_id: int, weapon_id: String, magazine_ammo: int) -> void:
	if net.is_host or not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not state or not is_instance_valid(node):
		return
	var wd := _apply_client_weapon_snapshot(state, node, {
		"primary_weapon_id": weapon_id,
		"secondary_weapon_id": _weapon_id_for_slot(state, "secondary"),
		"active_weapon_slot": _find_network_weapon_slot(state, weapon_id),
		"weapon_raised": true,
	})
	if not wd:
		return
	if wd.is_ranged and magazine_ammo >= 0:
		state.set_magazine_ammo(wd.item_id, magazine_ammo)
	node.play_network_attack_presentation(wd)
	if peer_id == int(net.my_peer_id):
		_auto_client_fire_confirmed = true
		_auto_client_attack_weapon_id = wd.item_id


@rpc("authority", "call_remote", "reliable")
func spawn_bullet(bullet_id: int, shooter_peer_id: int, start_position: Vector2, direction: Vector2, weapon_id: String, bullet_index: int) -> void:
	if net.is_host or bullet_id <= 0 or _bullets.has(bullet_id):
		return
	var bd: BulletData = _get_network_bullet_data(weapon_id, bullet_index)
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
	_auto_client_bullets_seen += 1
	print("[NetworkWorld] CLIENT_BULLET bullet=%d shooter=%d weapon=%s index=%d" % [bullet_id, shooter_peer_id, weapon_id, bullet_index])


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


func _get_network_bullet_data(weapon_id: String, bullet_index: int) -> BulletData:
	var weapon := _get_network_weapon_data_by_id(weapon_id)
	if not weapon or not weapon.is_ranged or bullet_index < 0 or bullet_index >= weapon.bullet_list.size():
		return null
	return weapon.bullet_list[bullet_index] as BulletData


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


## Director 在 Client 完成首次 world_snapshot 后才创建的感染者，必须走可靠 spawn 包。
## 高频紧凑敌人快照不包含场景路径，不能用于创建一个此前未知的实体。
@rpc("authority", "call_remote", "reliable")
func spawn_network_enemy(public_state: Dictionary) -> void:
	if net.is_host or _scene_transitioning:
		return
	var entity_id := int(public_state.get("entity_id", 0))
	if entity_id <= 0:
		return
	_ensure_client_enemy(entity_id, public_state, true)
	print("[NetworkWorld] CLIENT_ENEMY_SPAWN id=%d" % entity_id)


@rpc("authority", "call_remote", "reliable")
func world_snapshot(player_states: Array, enemy_states: Array, pickup_states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(player_states, true)
	_apply_client_enemy_snapshot(enemy_states, true)
	_apply_client_pickup_snapshot(pickup_states)
	_initial_world_received = _players.has(net.my_peer_id)
	print("[NetworkWorld] WORLD_SNAPSHOT players=%d enemies=%d local_ready=%s" % [player_states.size(), enemy_states.size(), _initial_world_received])


@rpc("authority", "call_remote", "unreliable_ordered")
func player_snapshot(player_states: Array, enemy_states: Array) -> void:
	if net.is_host:
		return
	_apply_client_snapshot(player_states, false)
	_apply_client_enemy_snapshot(enemy_states, false)


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
	# 首次世界快照是可靠的，保留字典格式及预置敌人的场景路径。
	world_snapshot.rpc_id(peer_id, _build_snapshot(), _build_enemy_snapshot(false), _build_pickup_snapshot())
	print("[NetworkWorld] WORLD_SNAPSHOT_SENT peer=%d enemies=%d" % [peer_id, _enemies.size()])


func _on_peer_left(peer_id: int) -> void:
	if not net.is_host:
		return
	if _players.has(peer_id):
		_remove_player(peer_id)
		despawn_player.rpc(peer_id)
		print("[NetworkWorld] HOST_DESPAWN peer=%d" % peer_id)
	_clear_host_safe_door_ready_for_peer(peer_id)
	# 仅无头双端回归收束：Client 完成输入验证并离开后，让 Host 自行干净退出。
	# 正式房间继续保留 Host，不会走此分支。
	if "--net-test=host" in OS.get_cmdline_user_args() and net.get_peer_ids().size() <= 1:
		call_deferred("_finish_auto_host_after_client_leave")


func _finish_auto_host_after_client_leave() -> void:
	if not net or not net.is_host or net.get_peer_ids().size() > 1:
		return
	print("[NetworkWorld] AUTO_HOST_COMPLETE client_left=true")
	net.leave()
	get_tree().quit()


func _broadcast_spawn_player(peer_id: int) -> void:
	if not _players.has(peer_id):
		return
	var packet := _public_state(peer_id)
	for target_id: int in net.get_peer_ids():
		if target_id > 1 and target_id != peer_id:
			spawn_player.rpc_id(target_id, peer_id, packet)


# ---------------------------------------------------------------- Client presentation

func _find_network_weapon_slot(state: PlayerState, weapon_id: String) -> String:
	if not state:
		return ""
	for slot: Variant in state.equipment.keys():
		var equipped := state.equipment.get(slot) as WeaponData
		if equipped and equipped.item_id == weapon_id:
			return str(slot)
	return ""


func _apply_client_weapon_snapshot(state: PlayerState, node: CharacterBody2D, public_state: Dictionary) -> WeaponData:
	## 装备和举枪状态一律由 Host 的公开快照收敛；客户端绝不自行补默认手枪/小刀。
	if not state or not is_instance_valid(node):
		return null
	var primary := _get_network_weapon_data_by_id(str(public_state.get("primary_weapon_id", "")))
	var secondary := _get_network_weapon_data_by_id(str(public_state.get("secondary_weapon_id", "")))
	state.equipment["primary"] = primary
	state.equipment["secondary"] = secondary
	var requested_slot := str(public_state.get("active_weapon_slot", "primary"))
	state.active_weapon_slot = requested_slot if requested_slot == "primary" or requested_slot == "secondary" else "primary"
	var packet_magazines: Variant = public_state.get("weapon_magazines", {})
	if packet_magazines is Dictionary:
		state.weapon_magazines = (packet_magazines as Dictionary).duplicate()
	var remote_weapon := state.get_active_weapon()
	if bool(public_state.get("weapon_raised", false)) and remote_weapon:
		if not node.is_weapon_mode_active() or node.get_network_weapon_id() != remote_weapon.item_id:
			node.enter_weapon_mode(remote_weapon)
			node.set_weapon_ready_frame()
	else:
		node.exit_weapon_mode()
	return remote_weapon


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
		node.exit_weapon_mode()
		var seat_index: int = _ensure_player_state_seat(state)
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
		# 快照中的 weapon_id 由 Host 的 active_weapon_slot 生成；只在实际变化时更新外观，
		# 避免每个 20Hz 包打断攻击动画或重置行走帧。
		var remote_weapon := _apply_client_weapon_snapshot(state, node, public_state)
		if remote_weapon and remote_weapon.is_ranged:
			state.set_magazine_ammo(
				remote_weapon.item_id,
				int(public_state.get("magazine_ammo", state.get_magazine_ammo(remote_weapon.item_id)))
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


# ---------------------------------------------------------------- Client enemy presentation

func _apply_client_enemy_snapshot(states: Array, snap: bool) -> void:
	var seen: Dictionary = {}
	for value: Variant in states:
		var public_state := _normalize_enemy_snapshot(value)
		if public_state.is_empty():
			continue
		var entity_id := int(public_state.get("entity_id", 0))
		if entity_id <= 0:
			continue
		seen[entity_id] = true
		_ensure_client_enemy(entity_id, public_state, snap)
	# 只有可靠完整快照才收敛动态实体；预置尸体不会被 Host 自动移除。
	if snap:
		for key: Variant in _enemies.keys():
			var entity_id := int(key)
			if not seen.has(entity_id):
				_remove_client_enemy(entity_id)


## 可靠 world_snapshot 使用字典（含预置场景路径）；20Hz 快照使用紧凑数组，减少 ENet 包尺寸。
func _normalize_enemy_snapshot(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	if value is Array:
		var packet := value as Array
		if packet.size() < 8:
			return {}
		return {
			"entity_id": int(packet[0]),
			"position": packet[1],
			"facing": int(packet[2]),
			"hp": float(packet[3]),
			"moving": bool(packet[4]),
			"visual_char_index": int(packet[5]),
			"dead": bool(packet[6]),
			"headshot": bool(packet[7]),
		}
	return {}


func _ensure_client_enemy(entity_id: int, public_state: Dictionary, snap: bool) -> void:
	var entry: Dictionary = _enemies.get(entity_id, {})
	var node := entry.get("node") as CharacterBody2D
	if not is_instance_valid(node):
		var scene_path := str(public_state.get("scene_path", ""))
		# 紧凑不可靠包不带场景路径；在可靠 world_snapshot 建立实体前不创建未知敌人。
		if scene_path.is_empty() and not snap:
			return
		if not scene_path.is_empty() and get_tree().current_scene:
			node = get_tree().current_scene.get_node_or_null(NodePath(scene_path)) as CharacterBody2D
		if not is_instance_valid(node):
			node = ENEMY_SCENE.instantiate() as CharacterBody2D
			if not is_instance_valid(node):
				return
			node.configure_network_entity(entity_id, true)
			node.global_position = _packet_position(public_state)
			get_tree().current_scene.add_child(node)
		node.configure_network_entity(entity_id, true)
		entry = {"node": node, "scene_path": scene_path}
		_enemies[entity_id] = entry
	node.apply_network_presentation(
		_packet_position(public_state),
		int(public_state.get("facing", 0)),
		bool(public_state.get("moving", false)),
		float(public_state.get("hp", node.current_hp)),
		int(public_state.get("visual_char_index", -1)),
		bool(public_state.get("dead", false)),
		bool(public_state.get("headshot", false)),
		snap
	)


func _remove_client_enemy(entity_id: int) -> void:
	if not _enemies.has(entity_id):
		return
	var entry: Dictionary = _enemies[entity_id]
	var node := entry.get("node") as Node
	_enemies.erase(entity_id)
	if is_instance_valid(node):
		node.queue_free()


func _remove_player(peer_id: int) -> void:
	# 客户端在场景切换/丢失包期间绝不能因非完整快照销毁自己的预置实体。
	if not net.is_host and peer_id == int(net.my_peer_id):
		return
	if not _players.has(peer_id):
		return
	var entry: Dictionary = _players[peer_id]
	var node := entry.get("node") as Node
	# Host 释放断线玩家前，先清除所有敌人的目标引用，防止 Chase 状态读取失效实例。
	if net.is_host and is_instance_valid(node):
		for enemy_node: Node in get_tree().get_nodes_in_group("enemy"):
			if enemy_node.has_method("clear_target_if_matches"):
				enemy_node.clear_target_if_matches(node)
	_players.erase(peer_id)
	if is_instance_valid(node):
		node.queue_free()


# ---------------------------------------------------------------- Host-authoritative pickups

func _register_initial_host_pickups() -> void:
	_pickups.clear()
	_next_pickup_id = 1
	var candidates: Array[Node2D] = []
	_collect_weapon_pickups(get_tree().current_scene, candidates)
	candidates.sort_custom(func(a: Node2D, b: Node2D) -> bool: return str(a.get_path()) < str(b.get_path()))
	for pickup: Node2D in candidates:
		_register_host_pickup(pickup)
	print("[NetworkWorld] HOST_PICKUPS_REGISTERED count=%d" % _pickups.size())


func _collect_weapon_pickups(root: Node, out: Array[Node2D]) -> void:
	if not is_instance_valid(root):
		return
	if root is Node2D and root.has_method("configure_network_pickup") and root.get("weapon_data") is WeaponData:
		out.append(root as Node2D)
	for child: Node in root.get_children():
		_collect_weapon_pickups(child, out)


func _register_host_pickup(pickup: Node2D) -> int:
	if not is_instance_valid(pickup):
		return 0
	for existing_id: Variant in _pickups.keys():
		if _pickups[existing_id] == pickup:
			return int(existing_id)
	var pickup_id: int = _next_pickup_id
	_next_pickup_id += 1
	pickup.call("configure_network_pickup", pickup_id, false)
	_pickups[pickup_id] = pickup
	return pickup_id


func _prepare_client_preplaced_pickups() -> void:
	var candidates: Array[Node2D] = []
	_collect_weapon_pickups(get_tree().current_scene, candidates)
	for pickup: Node2D in candidates:
		pickup.call("configure_network_pickup", 0, true)
		# 等 Host 的可靠快照分配稳定 ID，防止客户端在首帧走到预置物品旁时本地拾取。
		pickup.visible = false


func _build_pickup_snapshot() -> Array:
	var packets: Array = []
	for value: Variant in _pickups.keys():
		var pickup_id: int = int(value)
		var pickup := _pickups[pickup_id] as Node2D
		if not is_instance_valid(pickup):
			continue
		var weapon := pickup.get("weapon_data") as WeaponData
		if not weapon:
			continue
		var scene := get_tree().current_scene
		packets.append({
			"pickup_id": pickup_id,
			"scene_path": str(scene.get_path_to(pickup)) if scene else "",
			"position": pickup.global_position,
			"weapon_id": weapon.item_id,
			"reserve_ammo": int(pickup.get("pickup_reserve_ammo")),
			"magazine_ammo": int(pickup.get("pickup_magazine_ammo")),
			"char_idx": int(pickup.get("pickup_char_idx")),
			"direction": int(pickup.get("pickup_direction")),
		})
	packets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["pickup_id"]) < int(b["pickup_id"]))
	return packets


func request_pickup(pickup_id: int) -> void:
	if net.is_host:
		_try_host_pickup(int(net.my_peer_id), pickup_id)
	elif _initial_world_received:
		pickup_request.rpc_id(1, pickup_id)


@rpc("any_peer", "call_remote", "reliable")
func pickup_request(pickup_id: int) -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_pickup(sender, pickup_id)


func _try_host_pickup(peer_id: int, pickup_id: int) -> void:
	if not net.is_host or not _players.has(peer_id) or not _pickups.has(pickup_id):
		return
	var pickup := _pickups[pickup_id] as Node2D
	var entry: Dictionary = _players[peer_id]
	var player := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	var weapon := pickup.get("weapon_data") as WeaponData if is_instance_valid(pickup) else null
	if not is_instance_valid(pickup) or not is_instance_valid(player) or not state or not weapon:
		return
	if player.global_position.distance_to(pickup.global_position) > 40.0:
		return
	if state.character and not state.character.can_use_weapon(weapon):
		return
	var slot: String = weapon.get_slot_key()
	var old: WeaponData = state.get_equipped_weapon(slot)
	if old:
		_spawn_host_dropped_weapon(old, player.global_position, state)
	state.equipment[slot] = weapon
	if weapon.is_ranged:
		var mag: int = int(pickup.get("pickup_magazine_ammo"))
		state.set_magazine_ammo(weapon.item_id, clampi(weapon.magazine_capacity if mag < 0 else mag, 0, weapon.magazine_capacity))
		_add_host_reserve_ammo(state, weapon, int(pickup.get("pickup_reserve_ammo")))
	if state.active_weapon_slot == slot and player.is_weapon_mode_active():
		player.enter_weapon_mode(weapon)
		player.set_weapon_ready_frame()
	_pickups.erase(pickup_id)
	pickup.queue_free()
	# 拾取是一个不可拆分的权威事务：装备/弹匣变化与地面掉落物变化必须在同一条可靠 RPC 中抵达 Client。
	# 不能只可靠发送 pickup 列表、再依赖并行 20Hz 不可靠玩家快照更新装备，否则会出现图标、主机状态和地面物不同步。
	pickup_snapshot.rpc(_build_snapshot(), _build_pickup_snapshot())
	print("[NetworkWorld] HOST_PICKUP peer=%d pickup=%d weapon=%s" % [peer_id, pickup_id, weapon.item_id])


func _spawn_host_dropped_weapon(weapon: WeaponData, position: Vector2, state: PlayerState) -> void:
	var pickup := PICKUP_SCENE.instantiate() as Node2D
	if not is_instance_valid(pickup):
		return
	pickup.set("weapon_data", weapon)
	pickup.set("pickup_texture", weapon.pickup_texture if weapon.pickup_texture else weapon.weapon_walk_texture)
	pickup.set("pickup_char_idx", weapon.pickup_char_idx)
	pickup.set("pickup_direction", weapon.pickup_direction)
	if weapon.is_ranged:
		pickup.set("pickup_magazine_ammo", state.get_magazine_ammo(weapon.item_id))
		state.weapon_magazines.erase(weapon.item_id)
		var reserve: int = state.count_ammo_item(weapon.ammo_item_id)
		pickup.set("pickup_reserve_ammo", reserve)
		if reserve > 0:
			state.consume_ammo_item(weapon.ammo_item_id, reserve)
	pickup.global_position = position
	var parent := get_tree().current_scene.find_child("GroundLayer", true, false)
	(parent if parent else get_tree().current_scene).add_child(pickup)
	_register_host_pickup(pickup)


func _add_host_reserve_ammo(state: PlayerState, weapon: WeaponData, amount: int) -> void:
	if amount <= 0 or weapon.ammo_item_id.is_empty():
		return
	var resource: ItemData = _find_ammo_resource_for_weapon(state, weapon.ammo_item_id)
	if not resource:
		return
	for index: int in range(amount):
		state.add_item(resource.duplicate())


func _find_ammo_resource_for_weapon(state: PlayerState, ammo_item_id: String) -> ItemData:
	var path := "res://object/item_%s_ammo.tres" % ammo_item_id.trim_prefix("ammo_")
	if ResourceLoader.exists(path):
		var resource := load(path)
		if resource is ItemData:
			return resource as ItemData
	for item: Resource in state.inventory:
		if item is ItemData and (item as ItemData).item_id == ammo_item_id:
			return item as ItemData
	return null


@rpc("authority", "call_remote", "reliable")
func pickup_snapshot(player_states: Array, pickup_states: Array) -> void:
	if net.is_host or _scene_transitioning:
		return
	# 与 Host 的 _try_host_pickup() 同包发送，先收敛装备/弹匣，再更新掉落物。
	_apply_client_snapshot(player_states, false)
	_apply_client_pickup_snapshot(pickup_states)


func _apply_client_pickup_snapshot(states: Array) -> void:
	var seen: Dictionary = {}
	for packet_value: Variant in states:
		if not packet_value is Dictionary:
			continue
		var packet := packet_value as Dictionary
		var pickup_id: int = int(packet.get("pickup_id", 0))
		if pickup_id <= 0:
			continue
		seen[pickup_id] = true
		var pickup := _pickups.get(pickup_id) as Node2D
		if not is_instance_valid(pickup):
			var path := str(packet.get("scene_path", ""))
			if not path.is_empty():
				pickup = get_tree().current_scene.get_node_or_null(NodePath(path)) as Node2D
			if not is_instance_valid(pickup):
				pickup = PICKUP_SCENE.instantiate() as Node2D
				var parent := get_tree().current_scene.find_child("GroundLayer", true, false)
				(parent if parent else get_tree().current_scene).add_child(pickup)
			_pickups[pickup_id] = pickup
		var weapon := _get_network_weapon_data_by_id(str(packet.get("weapon_id", "")))
		if not weapon:
			continue
		pickup.set("weapon_data", weapon)
		pickup.set("pickup_texture", weapon.pickup_texture if weapon.pickup_texture else weapon.weapon_walk_texture)
		pickup.set("pickup_reserve_ammo", int(packet.get("reserve_ammo", 0)))
		pickup.set("pickup_magazine_ammo", int(packet.get("magazine_ammo", -1)))
		pickup.set("pickup_char_idx", int(packet.get("char_idx", 0)))
		pickup.set("pickup_direction", int(packet.get("direction", 0)))
		pickup.global_position = _packet_position(packet)
		pickup.call("_refresh_sprite")
		pickup.call("configure_network_pickup", pickup_id, true)
		pickup.visible = true
		pickup.call("reset_network_pickup_request")
	for old_id: Variant in _pickups.keys():
		var id: int = int(old_id)
		if not seen.has(id):
			var stale := _pickups[id] as Node
			_pickups.erase(id)
			if is_instance_valid(stale):
				stale.queue_free()

# ---------------------------------------------------------------- Host-authoritative safe doors

func request_safe_door_ready(door_key: String) -> void:
	if door_key.is_empty():
		return
	if net.is_host:
		_try_host_safe_door_ready(int(net.my_peer_id), door_key)
	elif _initial_world_received:
		safe_door_ready_request.rpc_id(1, door_key)


@rpc("any_peer", "call_remote", "reliable")
func safe_door_ready_request(door_key: String) -> void:
	if not net.is_host:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender > 1:
		_try_host_safe_door_ready(sender, door_key)


func _try_host_safe_door_ready(peer_id: int, door_key: String) -> void:
	if not net.is_host or not _players.has(peer_id):
		return
	var door := _find_safe_door(door_key)
	if not is_instance_valid(door) or not _is_host_player_at_safe_door(peer_id, door):
		return
	var changed_keys: Dictionary = {}
	for key: Variant in _safe_door_ready.keys():
		var ready_by_peer := _safe_door_ready[key] as Dictionary
		if ready_by_peer.erase(peer_id):
			changed_keys[str(key)] = true
		if ready_by_peer.is_empty():
			_safe_door_ready.erase(key)
	var ready_here: Dictionary = _safe_door_ready.get(door_key, {}) as Dictionary
	if not ready_here.get(peer_id, false):
		ready_here[peer_id] = true
		_safe_door_ready[door_key] = ready_here
		changed_keys[door_key] = true
	for changed_key: Variant in changed_keys.keys():
		_broadcast_safe_door_ready_status(str(changed_key))
	if _are_all_players_ready_at_safe_door(door_key, door):
		door.call("commit_host_network_entry")


func _find_safe_door(door_key: String) -> Node2D:
	if door_key.is_empty() or not get_tree().current_scene:
		return null
	var node := get_tree().current_scene.get_node_or_null(NodePath(door_key)) as Node2D
	if not is_instance_valid(node) or not node.has_method("commit_host_network_entry"):
		return null
	return node


func _is_host_player_at_safe_door(peer_id: int, door: Node2D) -> bool:
	if not _players.has(peer_id) or not is_instance_valid(door):
		return false
	var player := (_players[peer_id] as Dictionary).get("node") as CharacterBody2D
	if not is_instance_valid(player):
		return false
	return player.global_position.distance_to(door.global_position) <= float(door.get("interact_range"))


func _are_all_players_ready_at_safe_door(door_key: String, door: Node2D) -> bool:
	var ready_here: Dictionary = _safe_door_ready.get(door_key, {}) as Dictionary
	for peer_id: int in net.get_peer_ids():
		if not _players.has(peer_id) or not ready_here.get(peer_id, false):
			return false
		if not _is_host_player_at_safe_door(peer_id, door):
			return false
	return not ready_here.is_empty()


func _clear_host_safe_door_ready_for_peer(peer_id: int) -> void:
	if not net.is_host:
		return
	var changed_keys: Array[String] = []
	for key: Variant in _safe_door_ready.keys():
		var ready_by_peer := _safe_door_ready[key] as Dictionary
		if ready_by_peer.erase(peer_id):
			changed_keys.append(str(key))
		if ready_by_peer.is_empty():
			_safe_door_ready.erase(key)
	for door_key: String in changed_keys:
		_broadcast_safe_door_ready_status(door_key)


func _refresh_host_safe_door_readiness() -> void:
	if not net.is_host or _safe_door_ready.is_empty():
		return
	var changed_keys: Array[String] = []
	for key: Variant in _safe_door_ready.keys():
		var door_key: String = str(key)
		var door := _find_safe_door(door_key)
		var ready_by_peer := _safe_door_ready[key] as Dictionary
		var stale_peers: Array[int] = []
		for peer_value: Variant in ready_by_peer.keys():
			var peer_id := int(peer_value)
			if not is_instance_valid(door) or not _is_host_player_at_safe_door(peer_id, door):
				stale_peers.append(peer_id)
		for peer_id: int in stale_peers:
			ready_by_peer.erase(peer_id)
		if not stale_peers.is_empty():
			changed_keys.append(door_key)
		if ready_by_peer.is_empty():
			_safe_door_ready.erase(key)
	for door_key: String in changed_keys:
		_broadcast_safe_door_ready_status(door_key)


func _broadcast_safe_door_ready_status(door_key: String) -> void:
	var ready_here: Dictionary = _safe_door_ready.get(door_key, {}) as Dictionary
	var ready_count: int = ready_here.size()
	var total_count: int = net.get_peer_ids().size()
	_apply_safe_door_ready_status(door_key, ready_count, total_count)
	safe_door_ready_status.rpc(door_key, ready_count, total_count)


func _apply_safe_door_ready_status(door_key: String, ready_count: int, total_count: int) -> void:
	_door_ready_status[door_key] = {"ready_count": ready_count, "total_count": total_count}
	var door := _find_safe_door(door_key)
	if is_instance_valid(door) and door.has_method("apply_network_ready_status"):
		door.call("apply_network_ready_status", ready_count, total_count, false)


@rpc("authority", "call_remote", "reliable")
func safe_door_ready_status(door_key: String, ready_count: int, total_count: int) -> void:
	if net.is_host:
		return
	_apply_safe_door_ready_status(door_key, ready_count, total_count)


# ---------------------------------------------------------------- Automated smoke input

func _run_auto_client_input_test() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not _initial_world_received and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _initial_world_received:
		printerr("[NetworkWorld] AUTO_CLIENT_INPUT_TIMEOUT")
		return

	var primary_weapon := _get_network_primary_loadout_weapon()
	if not primary_weapon:
		printerr("[NetworkWorld] AUTO_CLIENT_PRIMARY_WEAPON_MISSING")
		return
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var state := entry.get("state") as PlayerState
	var initial_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	if initial_ammo != primary_weapon.magazine_capacity:
		printerr("[NetworkWorld] AUTO_CLIENT_INITIAL_AMMO_FAILED weapon=%s ammo=%d expected=%d" % [primary_weapon.item_id, initial_ammo, primary_weapon.magazine_capacity])

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
	# 拾取/掉落物使用独立分支：从初始移动终点直接前往左侧手枪，避免战斗后被地图中部碰撞阻隔。
	if "--net-test-pickup" in OS.get_cmdline_user_args():
		await _run_auto_client_pickup_test()
		net.leave()
		get_tree().quit()
		return

	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	Input.action_press("确定键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("确定键")
	deadline = Time.get_ticks_msec() + 3000
	while (
		(not _auto_client_fire_confirmed or _auto_client_bullets_seen < primary_weapon.bullet_list.size())
		and Time.get_ticks_msec() < deadline
	):
		await get_tree().create_timer(0.05).timeout
	entry = _players.get(int(net.my_peer_id), {})
	state = entry.get("state") as PlayerState
	var final_ammo := state.get_magazine_ammo(primary_weapon.item_id) if state else -1
	var fire_ok := (
		_auto_client_fire_confirmed
		and _auto_client_attack_weapon_id == primary_weapon.item_id
		and _auto_client_bullets_seen == primary_weapon.bullet_list.size()
		and final_ammo == primary_weapon.magazine_capacity - 1
	)
	print("[NetworkWorld] AUTO_CLIENT_FIRE_COMPLETE weapon=%s confirmed=%s bullets_seen=%d expected_bullets=%d ammo=%d" % [
		_auto_client_attack_weapon_id,
		_auto_client_fire_confirmed,
		_auto_client_bullets_seen,
		primary_weapon.bullet_list.size(),
		final_ammo,
	])
	if not fire_ok:
		printerr("[NetworkWorld] AUTO_CLIENT_FIRE_FAILED expected_weapon=%s weapon=%s confirmed=%s bullets_seen=%d expected_bullets=%d ammo=%d" % [
			primary_weapon.item_id,
			_auto_client_attack_weapon_id,
			_auto_client_fire_confirmed,
			_auto_client_bullets_seen,
			primary_weapon.bullet_list.size(),
			final_ammo,
		])

	# 第二段：先通过正常的客户端输入移动到 Enemy2 的近战距离内。
	# 不传送客户端坐标，确保本回归仍覆盖「Client 输入 → Host 模拟移动 → Host 判定」完整链路。
	Input.action_press("右")
	await get_tree().create_timer(0.72).timeout
	Input.action_release("右")
	await get_tree().create_timer(0.35).timeout
	entry = _players.get(int(net.my_peer_id), {})
	node = entry.get("node") as CharacterBody2D
	print("[NetworkWorld] AUTO_CLIENT_KNIFE_POSITION pos=%s" % [node.global_position if is_instance_valid(node) else Vector2.ZERO])

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
	var enemy_hp_before: float = _get_client_live_enemy_hp_total()
	_auto_client_fire_confirmed = false
	_auto_client_bullet_seen = false
	_auto_client_bullets_seen = 0
	_auto_client_attack_weapon_id = ""
	Input.action_press("确定键")
	await get_tree().create_timer(0.12).timeout
	Input.action_release("确定键")
	deadline = Time.get_ticks_msec() + 3000
	var melee_damage_seen := false
	var enemy_hp_after := enemy_hp_before
	while Time.get_ticks_msec() < deadline:
		enemy_hp_after = _get_client_live_enemy_hp_total()
		melee_damage_seen = enemy_hp_after <= enemy_hp_before - NETWORK_KNIFE.get_effective_damage() + 0.1
		if _auto_client_fire_confirmed and melee_damage_seen:
			break
		await get_tree().create_timer(0.05).timeout
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


## 回归 Client 按住确认键拾取武器：Host 替换装备、删除源掉落物、生成旧武器掉落物，再由可靠快照回写客户端。
func _run_auto_client_pickup_test() -> void:
	var source := _find_client_pickup_by_weapon_id(NETWORK_PISTOL.item_id)
	var entry: Dictionary = _players.get(int(net.my_peer_id), {})
	var node := entry.get("node") as CharacterBody2D
	var state := entry.get("state") as PlayerState
	if not is_instance_valid(source) or not is_instance_valid(node) or not state:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED source=%s node=%s state=%s" % [is_instance_valid(source), is_instance_valid(node), state != null])
		return
	var target_weapon := NETWORK_PISTOL
	var target_slot := target_weapon.get_slot_key()
	var old_weapon := state.get_equipped_weapon(target_slot)
	if not old_weapon or old_weapon.item_id == target_weapon.item_id:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_SETUP_FAILED slot=%s old_weapon=%s" % [target_slot, old_weapon.item_id if old_weapon else "<none>"])
		return
	# 仅用正常客户端输入接近测试图里的手枪；不直接调用 request_pickup()，以覆盖 Ground pickup 的按住交互。
	Input.action_press("左")
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and node.global_position.distance_to(source.global_position) > 18.0:
		await get_tree().create_timer(0.05).timeout
	Input.action_release("左")
	await get_tree().create_timer(0.08).timeout
	var in_range := node.global_position.distance_to(source.global_position) <= 28.0
	if not in_range:
		printerr("[NetworkWorld] AUTO_CLIENT_PICKUP_MOVE_FAILED player=%s source=%s" % [node.global_position, source.global_position])
		return
	Input.action_press("确定键")
	await get_tree().create_timer(1.45).timeout
	Input.action_release("确定键")
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


func _find_client_pickup_by_weapon_id(weapon_id: String) -> Node2D:
	for value: Variant in _pickups.values():
		var pickup := value as Node2D
		var weapon := pickup.get("weapon_data") as WeaponData if is_instance_valid(pickup) else null
		if weapon and weapon.item_id == weapon_id:
			return pickup
	return null


func _has_client_pickup_weapon_near(weapon_id: String, position: Vector2, max_distance: float) -> bool:
	for value: Variant in _pickups.values():
		var pickup := value as Node2D
		var weapon := pickup.get("weapon_data") as WeaponData if is_instance_valid(pickup) else null
		if weapon and weapon.item_id == weapon_id and pickup.global_position.distance_to(position) <= max_distance:
			return true
	return false


## 自动双端烟测只从客户端已接收的 Host 敌人快照累计生命值；不读取或伪造 Host 命中结果。
func _get_client_live_enemy_hp_total() -> float:
	var total := 0.0
	for enemy_entry: Dictionary in _enemies.values():
		var enemy := enemy_entry.get("node") as CharacterBody2D
		if is_instance_valid(enemy) and not enemy.is_network_dead():
			total += enemy.current_hp
	return total


# ---------------------------------------------------------------- State serialisation / scene helpers

# ---------------------------------------------------------------- Enemy state serialisation / scene helpers

func _register_initial_host_enemies() -> void:
	_enemies.clear()
	_next_enemy_id = 1
	var candidates: Array[CharacterBody2D] = []
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		if value is CharacterBody2D:
			candidates.append(value as CharacterBody2D)
	var scene := get_tree().current_scene
	candidates.sort_custom(func(a: CharacterBody2D, b: CharacterBody2D) -> bool:
		var path_a := str(scene.get_path_to(a)) if scene else str(a.get_path())
		var path_b := str(scene.get_path_to(b)) if scene else str(b.get_path())
		return path_a < path_b
	)
	for enemy: CharacterBody2D in candidates:
		var entity_id := _next_enemy_id
		_next_enemy_id += 1
		var scene_path := str(scene.get_path_to(enemy)) if scene else ""
		enemy.configure_network_entity(entity_id, false)
		_enemies[entity_id] = {"node": enemy, "scene_path": scene_path}
	print("[NetworkWorld] HOST_ENEMIES_REGISTERED count=%d" % _enemies.size())


func _register_untracked_host_enemies() -> void:
	## Director 可以在地图运行后动态生成感染者。新节点进入 enemy group 后在此被 Host 收编。
	if not net.is_host:
		return
	var tracked_nodes: Dictionary = {}
	for entry_value: Variant in _enemies.values():
		var tracked := (entry_value as Dictionary).get("node") as CharacterBody2D
		if is_instance_valid(tracked):
			tracked_nodes[tracked.get_instance_id()] = true
	var scene := get_tree().current_scene
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		var enemy := value as CharacterBody2D
		if not is_instance_valid(enemy) or tracked_nodes.has(enemy.get_instance_id()):
			continue
		var entity_id := _next_enemy_id
		_next_enemy_id += 1
		var scene_path := str(scene.get_path_to(enemy)) if scene else ""
		enemy.configure_network_entity(entity_id, false)
		_enemies[entity_id] = {"node": enemy, "scene_path": scene_path}
		var public_state := _public_enemy_state(entity_id)
		var ready_client_count := 0
		for peer_id: int in net.get_peer_ids():
			# 只向已完成本场景 world_snapshot 的 Client 发场景节点 RPC，
			# 避免 Client 尚在切图时出现 "NetworkWorld not found" 在途包错误。
			if peer_id > 1 and _players.has(peer_id):
				spawn_network_enemy.rpc_id(peer_id, public_state)
				ready_client_count += 1
		print("[NetworkWorld] HOST_ENEMY_REGISTERED id=%d path=%s clients=%d" % [entity_id, scene_path, ready_client_count])

func _prepare_client_preplaced_enemies() -> void:
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		if value is CharacterBody2D:
			(value as CharacterBody2D).configure_network_entity(0, true)


func _build_enemy_snapshot(compact: bool = false) -> Array:
	var states: Array = []
	for key: Variant in _enemies.keys():
		var entity_id := int(key)
		var public_state := _public_enemy_state(entity_id)
		if public_state.is_empty():
			continue
		if compact:
			# 高频 ENet 包：只发送客户端表现必需的数据；场景路径只在可靠 world_snapshot 中发送。
			states.append([
				entity_id,
				public_state["position"],
				public_state["facing"],
				public_state["hp"],
				public_state["moving"],
				public_state["visual_char_index"],
				public_state["dead"],
				public_state["headshot"],
			])
		else:
			states.append(public_state)
	if compact:
		states.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	else:
		states.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["entity_id"]) < int(b["entity_id"]))
	return states


func _public_enemy_state(entity_id: int) -> Dictionary:
	if not _enemies.has(entity_id):
		return {}
	var entry: Dictionary = _enemies[entity_id]
	var enemy := entry.get("node") as CharacterBody2D
	if not is_instance_valid(enemy):
		return {}
	return {
		"entity_id": entity_id,
		"scene_path": str(entry.get("scene_path", "")),
		"position": enemy.global_position,
		"facing": enemy.get_network_facing(),
		"hp": enemy.current_hp,
		"moving": enemy.is_moving_for_network(),
		"ai_state": enemy.get_network_ai_state(),
		"visual_char_index": enemy.get_network_visual_char_index(),
		"dead": enemy.is_network_dead(),
		"headshot": enemy.is_network_headshot_dead(),
	}


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
		"primary_weapon_id": _weapon_id_for_slot(state, "primary"),
		"secondary_weapon_id": _weapon_id_for_slot(state, "secondary"),
		"active_weapon_slot": state.active_weapon_slot if state else "primary",
		"weapon_magazines": state.weapon_magazines.duplicate() if state else {},
		"weapon_raised": node.is_weapon_mode_active() if is_instance_valid(node) else false,
		"magazine_ammo": state.get_magazine_ammo(weapon.item_id) if state and weapon else 0,
	}


func _weapon_id_for_slot(state: PlayerState, slot: String) -> String:
	var wd: WeaponData = state.get_equipped_weapon(slot) if state else null
	return wd.item_id if wd else ""


func _find_or_create_player_state(peer_id: int, character_path: String, hp: float) -> PlayerState:
	var state: PlayerState = net.get_session_player_state(peer_id) if net and net.has_method("get_session_player_state") else null
	if not state:
		for index: int in range(Players.seat_count()):
			var candidate := Players.get_seat(index)
			if candidate and candidate.owner_peer_id == peer_id:
				state = candidate
				break
	if not state:
		state = _make_player_state(character_path, hp)
		state.owner_peer_id = peer_id
	if net and net.has_method("set_session_player_state"):
		net.set_session_player_state(peer_id, state)
	return state


func _ensure_player_state_seat(state: PlayerState) -> int:
	for index: int in range(Players.seat_count()):
		if Players.get_seat(index) == state:
			state.seat_index = index
			return index
	return Players.add_seat(state)


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
