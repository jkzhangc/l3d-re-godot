extends Node
## NetworkSyncManager Autoload — 联机战斗同步
##
## 集中管理所有战斗相关 RPC，遵循 Host-Authoritative 模型：
##   Client → @rpc("any_peer") → Host 执行逻辑 → @rpc("authority") → Clients 更新


# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════
const ENEMY_SYNC_INTERVAL: float = 0.1  ## 敌人状态批量同步频率（10Hz）


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _enemy_sync_timer: float = 0.0
var _enemy_name_counter: int = 0  ## 敌人唯一名称计数器


func _process(delta: float) -> void:
	# Host 定时批量广播敌人状态
	if not multiplayer.is_server():
		return
	if not Lobby.is_online():
		return

	_enemy_sync_timer += delta
	if _enemy_sync_timer >= ENEMY_SYNC_INTERVAL:
		_enemy_sync_timer = 0.0
		_broadcast_enemy_states()


# ═══════════════════════════════════════
# Client → Host RPCs
# ═══════════════════════════════════════

## Client 请求 Host 代为执行远程攻击（生成子弹）
@rpc("any_peer", "reliable")
func request_attack(peer_id: int, weapon_item_id: String) -> void:
	if not multiplayer.is_server():
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_attack: 未找到 Player%d" % peer_id)
		return
	if player.has_method("_execute_attack"):
		player._execute_attack(weapon_item_id)
		print("[NetSync] Host 执行 Player%d 的攻击 (武器=%s)" % [peer_id, weapon_item_id])


## Client 请求 Host 代为执行近战攻击判定
@rpc("any_peer", "reliable")
func request_melee(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_melee: 未找到 Player%d" % peer_id)
		return
	if player.has_method("_execute_melee"):
		player._execute_melee()
		print("[NetSync] Host 执行 Player%d 的近战判定" % peer_id)


## Client 请求 Host 代为装填
@rpc("any_peer", "reliable")
func request_reload(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_reload: 未找到 Player%d" % peer_id)
		return
	if player.has_method("_execute_reload"):
		player._execute_reload()
		print("[NetSync] Host 执行 Player%d 的装填" % peer_id)


## Client 通知 Host：枪声惊动了某个敌人
@rpc("any_peer", "reliable")
func alert_enemy_by_gunshot(enemy_name: String, shooter_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var enemy: Node = _find_enemy(enemy_name)
	var shooter: Node = _find_player(shooter_peer_id)
	if enemy and shooter and enemy.has_method("alert_by_gunshot"):
		enemy.alert_by_gunshot(shooter)
		print("[NetSync] 枪声惊动敌人: %s (shooter=Player%d)" % [enemy_name, shooter_peer_id])


# ═══════════════════════════════════════
# Host → Clients RPCs
# ═══════════════════════════════════════

## Host 广播：生成敌人（Client 端创建 puppet 敌人）
@rpc("authority", "reliable")
func spawn_enemy(enemy_name: String, pos: Vector2, facing: int) -> void:
	if multiplayer.is_server():
		return  # Host 已通过 Director 本地生成
	var enemy_scene: PackedScene = load("res://object/enemy.tscn") as PackedScene
	if not enemy_scene:
		printerr("[NetSync] 无法加载 enemy.tscn")
		return
	var enemy: Node2D = enemy_scene.instantiate()
	enemy.name = enemy_name
	enemy.global_position = pos
	if facing >= 0:
		enemy.initial_facing = facing
	var tree := get_tree()
	if tree and tree.current_scene:
		var decor: Node = tree.current_scene.get_node_or_null("DecorLayer")
		if decor:
			decor.add_child(enemy)
			print("[NetSync] Client 生成 puppet 敌人: %s at (%d,%d)" % [enemy_name, int(pos.x), int(pos.y)])

## Host 广播：玩家 HP 变化（reliable）
@rpc("authority", "reliable")
func sync_player_hp(player_name: String, hp: float) -> void:
	var player: Node = _find_player_by_name(player_name)
	if not player:
		return
	player.current_hp = hp
	print("[NetSync] sync_player_hp: %s HP=%.0f" % [player_name, hp])


## Host 广播：敌人 HP 变化 / 死亡（reliable，低频）
## call_local 确保 Host 也执行此 RPC（用于播放命中特效和伤害数字）
@rpc("authority", "call_local", "reliable")
func sync_enemy_hp(enemy_name: String, hp: float, is_dead: bool) -> void:
	var enemy: Node = _find_enemy(enemy_name)
	if not enemy:
		return
	var old_hp: float = enemy.current_hp
	var damage: float = old_hp - hp
	enemy.current_hp = hp

	if damage > 0.0 and get_tree() and get_tree().current_scene:
		# 伤害数字：Host 已在 enemy.take_damage() 中生成（带头部颜色），此处跳过避免重复
		if not multiplayer.is_server():
			var dmg_color: Color = Color.WHITE
			DamageNumber.spawn(enemy.global_position, damage, get_tree().current_scene, 0, dmg_color)
		# 命中特效：所有端都播放（Host 依赖此路径，bullet._hit() 的本地特效可能为空）
		var hit_effect: PackedScene = load("res://anim/anim_effect_hit.tscn") as PackedScene
		if hit_effect:
			VXAnimSprite.play_scene(hit_effect, enemy.global_position, get_tree().current_scene)

	if is_dead and not enemy._is_dead:
		enemy._is_dead = true
		if enemy.has_method("_show_death_sprite"):
			enemy._show_death_sprite()
		print("[NetSync] 敌人死亡同步: %s" % enemy_name)


## Host 广播：批量敌人状态（unreliable, 10Hz）
@rpc("authority", "unreliable")
func sync_enemies_batch(data: Dictionary) -> void:
	for enemy_name: String in data:
		var enemy: Node = _find_enemy(enemy_name)
		if not enemy:
			continue
		var state: Dictionary = data[enemy_name]
		enemy.global_position = state.get("pos", enemy.global_position)
		if "facing" in state:
			enemy._facing = state["facing"]
		if "moving" in state and enemy.has_method("update_moving"):
			enemy.update_moving(state["moving"])
		# 存储同步的状态名（供 puppet 驱动动画）
		if "state" in state:
			enemy.set_meta("synced_state", state["state"])
		# HP 通过独立的 reliable RPC 更新，不在批量中覆盖


## Host 广播：攻击特效/音效/视觉子弹给 Clients
## 当 Host 自己攻击时，本地已播放特效，此 RPC 通知所有 Client 播放
@rpc("authority", "unreliable")
func broadcast_attack_effects(peer_id: int, weapon_item_id: String, pos: Vector2, facing: int) -> void:
	if multiplayer.is_server():
		return  # Host 已本地播放，跳过

	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] broadcast_attack_effects: 未找到 Player%d" % peer_id)
		return

	# 查找 WeaponData
	var wd: WeaponData = null
	var known: Array[String] = [
		"res://object/weapon_pistol.tres",
		"res://object/weapon_knife.tres",
		"res://object/weapon_shotgun.tres",
		"res://object/weapon_rifle.tres",
		"res://object/weapon_smg.tres",
	]
	for path: String in known:
		if ResourceLoader.exists(path):
			var res: WeaponData = load(path) as WeaponData
			if res and res.item_id == weapon_item_id:
				wd = res
				break

	if not wd:
		return

	# 播放攻击特效
	var effect_scene: PackedScene = wd.get_attack_effect_anim(facing)
	if effect_scene:
		var follow: Node2D = player if wd.attack_effect_follow else null
		VXAnimSprite.play_scene(effect_scene, pos, get_tree().current_scene, 10.0, follow, wd.attack_effect_offset_override)

	# 播放攻击音效
	if wd.attack_sound:
		Global.play_sfx_managed(wd.attack_sound, get_tree().current_scene)

	# 远程武器：生成视觉子弹
	if wd.is_ranged and wd.bullet_list.size() > 0:
		var bullet_scene: PackedScene = load("res://object/bullet.tscn") as PackedScene
		if bullet_scene:
			var base_dir: Vector2 = _facing_to_vector(facing)
			for bd: BulletData in wd.bullet_list:
				var bullet: Node2D = bullet_scene.instantiate()
				var dir_vec: Vector2 = bd.get_fire_direction(base_dir)
				if bullet.has_method("setup"):
					bullet.setup({
						"direction": dir_vec,
						"speed": bd.speed,
						"max_range": bd.max_range,
						"damage": 0.0,
						"destroy_on_hit": false,
						"penetration": 0,
						"critical_rate": 0.0,
						"texture": bd.bullet_texture,
						"anim_frames": bd.bullet_anim_frames,
						"frame_duration": bd.bullet_frame_duration,
						"collision_size": bd.collision_size,
						"collision_offset": bd.collision_offset,
						"shooter": player,
					})
				# 禁用碰撞检测（纯视觉）
				var area: Area2D = bullet.get_node_or_null("Area2D")
				if area:
					area.collision_mask = 0
				var extra: Vector2 = bd.get_extra_offset(facing)
				bullet.position = pos + dir_vec * bd.spawn_offset + extra
				get_tree().current_scene.add_child(bullet)


# ═══════════════════════════════════════
# 内部工具方法
# ═══════════════════════════════════════

func _broadcast_enemy_states() -> void:
	## Host 收集所有敌人的状态并批量广播
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	if enemies.is_empty():
		return

	var data: Dictionary = {}
	for enemy: Node in enemies:
		if not is_instance_valid(enemy):
			continue
		# 获取当前状态名
		var state_name: String = ""
		var sm: Node = enemy.get_node_or_null("StateMachine")
		if sm and sm.current_state:
			state_name = sm.current_state.name
		var state: Dictionary = {
			"pos": enemy.global_position,
			"facing": enemy.get("_facing"),
			"moving": enemy.get("_moving"),
			"state": state_name,
		}
		data[enemy.name] = state

	if not data.is_empty():
		sync_enemies_batch.rpc(data)


## 通过 peer_id 查找 Player 节点
func _find_player(peer_id: int) -> Node:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return null
	var container: Node = tree.current_scene.get_node_or_null("DecorLayer/Players")
	if not container:
		return null
	return container.get_node_or_null(NodePath("Player%d" % peer_id))


## 通过 name 查找 Player 节点
func _find_player_by_name(player_name: String) -> Node:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return null
	var parts: PackedStringArray = player_name.split("/")
	# 支持 "Player1" 格式和 "DecorLayer/Players/Player1" 格式
	if parts.size() == 1:
		var container: Node = tree.current_scene.get_node_or_null("DecorLayer/Players")
		if container:
			return container.get_node_or_null(NodePath(player_name))
		return null
	return tree.current_scene.get_node_or_null(NodePath(player_name))


## 通过 name 查找 Enemy 节点
func _find_enemy(enemy_name: String) -> Node:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return null
	# 尝试直接路径查找
	var parts: PackedStringArray = enemy_name.split("/")
	if parts.size() > 1:
		return tree.current_scene.get_node_or_null(NodePath(enemy_name))
	# 按名称遍历 enemies 组
	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	for enemy: Node in enemies:
		if is_instance_valid(enemy) and enemy.name == enemy_name:
			return enemy
	return null


## 为动态生成的敌人分配唯一名称
func get_unique_enemy_name() -> String:
	_enemy_name_counter += 1
	return "Enemy_%d" % _enemy_name_counter


## 将 facing int 转为方向向量（与 player.gd FaceDir 枚举一致）
func _facing_to_vector(facing: int) -> Vector2:
	match facing:
		0: return Vector2(0, 1)    # DOWN
		1: return Vector2(-1, 0)   # LEFT
		2: return Vector2(1, 0)    # RIGHT
		3: return Vector2(0, -1)   # UP
	return Vector2(0, 1)
