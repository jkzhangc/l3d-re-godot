extends Node
## NetworkSyncManager Autoload — 联机战斗同步
##
## 集中管理所有战斗相关 RPC，遵循 Host-Authoritative 模型：
##   Client → @rpc("any_peer") → Host 执行逻辑 → @rpc("authority") → Clients 更新


# ═══════════════════════════════════════
# 常量
# ═══════════════════════════════════════
const ENEMY_SYNC_INTERVAL: float = 0.025  ## 敌人状态批量同步频率（40Hz）


# ═══════════════════════════════════════
# 内部状态
# ═══════════════════════════════════════
var _enemy_sync_timer: float = 0.0
var _enemy_name_counter: int = 0  ## 敌人唯一名称计数器
var _prev_enemy_states: Dictionary = {}  ## 上一帧敌人状态（检测 Attack 状态变化）
var _pending_enemy_hp: Dictionary = {}  ## Client 尚未生成敌人时暂存 HP/死亡结果
var _request_last_ms: Dictionary = {}  ## sender_id -> request_name -> last accepted time

const REQUEST_INTERVAL_MS: Dictionary = {
	"attack": 50,
	"melee": 120,
	"reload": 120,
	"gunshot_alert": 50,
}


func _process(delta: float) -> void:
	_process_pending_enemy_hp()
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
func request_attack(weapon_item_id: String = "") -> void:
	if not multiplayer.is_server():
		return
	var peer_id := _get_request_sender_id()
	if not _accept_request(peer_id, "attack"):
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_attack: 未找到 Player%d" % peer_id)
		return
	var validated_weapon_id := _get_validated_weapon_id(player, weapon_item_id)
	if validated_weapon_id.is_empty():
		return
	if player.has_method("_execute_attack"):
		player._execute_attack(validated_weapon_id)
		print("[NetSync] Host 执行 Player%d 的攻击 (武器=%s)" % [peer_id, validated_weapon_id])
		# 同步弹药变化回请求方 Client
		_sync_ammo_back(peer_id, player, validated_weapon_id)
		# 广播攻击特效给其他 Client（排除攻击者，攻击者已有本地预测）
		_broadcast_attack_to_others(peer_id, player, validated_weapon_id)


## Client 请求 Host 代为执行近战攻击判定
@rpc("any_peer", "reliable")
func request_melee(weapon_item_id: String = "") -> void:
	if not multiplayer.is_server():
		return
	var peer_id := _get_request_sender_id()
	if not _accept_request(peer_id, "melee"):
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_melee: 未找到 Player%d" % peer_id)
		return
	var validated_weapon_id := _get_validated_weapon_id(player, weapon_item_id)
	if validated_weapon_id.is_empty():
		return
	if player.has_method("_execute_melee"):
		player._execute_melee(validated_weapon_id)
		print("[NetSync] Host 执行 Player%d 的近战判定 (武器=%s)" % [peer_id, weapon_item_id])
		# 广播近战特效给其他 Client
		_broadcast_attack_to_others(peer_id, player, validated_weapon_id)


## Client 请求 Host 代为装填
## shell_count: -1=全部装填(NORMAL模式), 1=装一发(霰弹枪模式)
## reserve_count：兼容当前远程 PlayerData 尚未完整同步的临时参数；后续库存权威化阶段移除。
@rpc("any_peer", "reliable")
func request_reload(weapon_item_id: String = "", shell_count: int = -1, reserve_count: int = 0) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := _get_request_sender_id()
	if not _accept_request(peer_id, "reload"):
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_reload: 未找到 Player%d" % peer_id)
		return
	var validated_weapon_id := _get_validated_weapon_id(player, weapon_item_id)
	if validated_weapon_id.is_empty():
		return
	var validated_shell_count := -1 if shell_count < 0 else 1
	var validated_reserve_count := clampi(reserve_count, 0, 999)
	if player.has_method("_execute_reload"):
		# 当前远程 PlayerData 的备弹仍依赖客户端临时上报；限制范围，避免负数/超大值。
		player._execute_reload(validated_weapon_id, validated_shell_count, validated_reserve_count)
		print("[NetSync] Host 执行 Player%d 的装填 (武器=%s shells=%d)" % [peer_id, validated_weapon_id, validated_shell_count])
		# 同步弹药变化回请求方 Client
		_sync_ammo_back(peer_id, player, validated_weapon_id)


## Client 通知 Host：枪声惊动了某个敌人
@rpc("any_peer", "reliable")
func alert_enemy_by_gunshot(enemy_name: String, shooter_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := _get_request_sender_id()
	if sender_id != shooter_peer_id or not _accept_request(sender_id, "gunshot_alert"):
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
			# 处理可能先于 puppet 生成到达的可靠死亡/HP 结果，避免短暂攻击动画或过期丢失。
			_apply_pending_enemy_hp(enemy_name, enemy)
			print("[NetSync] Client 生成 puppet 敌人: %s at (%d,%d)" % [enemy_name, int(pos.x), int(pos.y)])

## Host 广播：玩家 HP 变化（reliable）
@rpc("authority", "reliable")
func sync_player_hp(player_name: String, hp: float) -> void:
	var player: Node = _find_player_by_name(player_name)
	if not player:
		return
	player.current_hp = hp
	# 只有本地玩家才写入本地 HUD/存档全局值，不能把远程玩家 HP 覆盖到自己的 Global。
	if player.get_multiplayer_authority() == multiplayer.get_unique_id():
		Global.player_hp = hp
	print("[NetSync] sync_player_hp: %s HP=%.0f" % [player_name, hp])


## Host 广播：玩家受敌人攻击命中特效。
@rpc("authority", "call_local", "reliable")
func sync_player_hit_effect(player_name: String, effect_path: String, hit_pos: Vector2) -> void:
	if effect_path.is_empty():
		return
	var effect_scene := load(effect_path) as PackedScene
	if effect_scene and get_tree() and get_tree().current_scene:
		VXAnimSprite.play_scene(effect_scene, hit_pos, get_tree().current_scene)


## Host 广播：敌人 HP 变化 / 死亡（reliable，低频）
## call_local 确保 Host 也执行此 RPC（用于播放命中特效和伤害数字）
@rpc("authority", "call_local", "reliable")
func sync_enemy_hp(enemy_name: String, hp: float, is_dead: bool, is_headshot: bool = false, hit_effect_path: String = "") -> void:
	var enemy: Node = _find_enemy(enemy_name)
	if not enemy:
		if not multiplayer.is_server():
			# 死亡结果必须保留到对应 puppet 生成；非死亡 HP 更新使用有限 TTL 防止异常名称泄漏。
			var ttl_ms: int = 30000 if is_dead else 5000
			_pending_enemy_hp[enemy_name] = {"hp": hp, "is_dead": is_dead, "is_headshot": is_headshot, "hit_effect_path": hit_effect_path, "expires": Time.get_ticks_msec() + ttl_ms}
		print("[NetSync] sync_enemy_hp: 暂存未生成敌人 %s" % enemy_name)
		return
	_apply_enemy_hp(enemy, hp, is_dead, is_headshot, hit_effect_path)


func _apply_enemy_hp(enemy: Node, hp: float, is_dead: bool, is_headshot: bool, hit_effect_path: String = "") -> void:
	var old_hp: float = enemy.current_hp
	var damage: float = old_hp - hp
	enemy.current_hp = hp

	if damage > 0.0 and get_tree() and get_tree().current_scene:
		# 伤害数字：Host 已在 enemy.take_damage() 中生成（带头部颜色），此处跳过避免重复
		if not multiplayer.is_server():
			var dmg_color: Color = Color.WHITE
			DamageNumber.spawn(enemy.global_position, damage, get_tree().current_scene, 0, dmg_color)
		# 命中特效：所有端都播放（Host 依赖此路径，bullet._hit() 的本地特效可能为空）
		var hit_effect: PackedScene = load(hit_effect_path) as PackedScene if not hit_effect_path.is_empty() else load("res://anim/anim_effect_hit.tscn") as PackedScene
		if hit_effect:
			VXAnimSprite.play_scene(hit_effect, enemy.global_position, get_tree().current_scene)
	elif not hit_effect_path.is_empty() and get_tree() and get_tree().current_scene:
		# call_local Host 的 HP 已经先在 take_damage 中更新，不能依赖 damage 差值判断特效。
		var explicit_effect := load(hit_effect_path) as PackedScene
		if explicit_effect:
			VXAnimSprite.play_scene(explicit_effect, enemy.global_position, get_tree().current_scene)

		# Client 端：销毁命中点附近的视觉子弹（模拟穿透检测，视觉子弹 collision_mask=0 不会碰撞）
		if not multiplayer.is_server():
			_destroy_nearby_visual_bullets(enemy.global_position)

	if is_dead and not enemy._is_dead:
		if enemy.has_method("_apply_network_death"):
			enemy._apply_network_death(is_headshot)
		elif enemy.has_method("_show_death_sprite"):
			enemy._is_dead = true
			enemy._show_death_sprite()
		print("[NetSync] 敌人死亡同步: %s" % enemy.name)


func _process_pending_enemy_hp() -> void:
	if multiplayer.is_server() or _pending_enemy_hp.is_empty():
		return
	var now := Time.get_ticks_msec()
	var completed: Array[String] = []
	for enemy_name: String in _pending_enemy_hp:
		var pending: Dictionary = _pending_enemy_hp[enemy_name]
		var enemy := _find_enemy(enemy_name)
		if enemy:
			# 遍历期间不要直接修改字典，统一在循环结束后清理。
			_apply_pending_enemy_hp(enemy_name, enemy, false)
			completed.append(enemy_name)
		elif not bool(pending.get("is_dead", false)) and now >= int(pending.get("expires", 0)):
			completed.append(enemy_name)
	for enemy_name: String in completed:
		_pending_enemy_hp.erase(enemy_name)


func _apply_pending_enemy_hp(enemy_name: String, enemy: Node = null, consume: bool = true) -> void:
	if not _pending_enemy_hp.has(enemy_name):
		return
	var pending: Dictionary = _pending_enemy_hp[enemy_name]
	var target: Node = enemy if enemy else _find_enemy(enemy_name)
	if target:
		_apply_enemy_hp(target, pending.get("hp", target.current_hp), pending.get("is_dead", false), pending.get("is_headshot", false), pending.get("hit_effect_path", ""))
		if consume:
			_pending_enemy_hp.erase(enemy_name)


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
				bullet.add_to_group("visual_bullet")
				get_tree().current_scene.add_child(bullet)


## Host → Client: 同步玩家弹药（reliable，攻击/装填后触发）
@rpc("authority", "reliable")
func sync_player_ammo(peer_id: int, weapon_id: String, magazine_ammo: int) -> void:
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] sync_player_ammo: 未找到 Player%d" % peer_id)
		return
	var pd = player.get("player_data")
	if pd:
		pd.set_magazine_ammo(weapon_id, magazine_ammo)
	# 同步到 Global（驱动 HUD 刷新）
	Global.set_magazine_ammo(weapon_id, magazine_ammo)
	print("[NetSync] Client 弹夹同步: Player%d %s=%d" % [peer_id, weapon_id, magazine_ammo])


## Host → Client: 同步玩家备弹数量（reliable，装填后触发）
@rpc("authority", "reliable")
func sync_player_reserve_ammo(peer_id: int, ammo_item_id: String, count: int) -> void:
	# 接收端：更新 Global inventory 中的备弹数量，使 HUD 刷新正确
	# 注意：count 是 Host 端的 player_data.count_ammo_item() 结果
	# Client 端直接从 player_data 同步更准确，此处作为辅助
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] sync_player_reserve_ammo: 未找到 Player%d" % peer_id)
		return
	var pd = player.get("player_data")
	if not pd:
		return
	# 计算差值并调整 inventory
	var current_count: int = pd.count_ammo_item(ammo_item_id)
	var diff: int = count - current_count
	if diff > 0:
		# 需要添加弹药物品
		var ammo_res := _find_ammo_resource(ammo_item_id)
		if ammo_res:
			for _i: int in range(diff):
				pd.inventory.append(ammo_res.duplicate())
	elif diff < 0:
		# 需要移除弹药物品
		pd.consume_ammo_item(ammo_item_id, -diff)
	# 同步到 Global
	Global.weapon_magazines = pd.weapon_magazines.duplicate()
	Global.inventory = pd.inventory.duplicate()


## Host → Clients: 敌人进入 Attack 状态（reliable，立即通知）
@rpc("authority", "call_local", "reliable")
func sync_enemy_attack(enemy_name: String, facing: int) -> void:
	if multiplayer.is_server():
		return  # Host 不需要 puppet 动画
	var enemy: Node = _find_enemy(enemy_name)
	if not enemy:
		return
	# 标记敌人进入攻击状态，触发 puppet 攻击动画
	enemy.set_meta("synced_attack", true)
	enemy.set_meta("synced_attack_facing", facing)
	# 设置状态为 Attack 以便 puppet 驱动
	enemy.set_meta("synced_state", "Attack")


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
		# 跳过已死亡的敌人（死亡精灵已显示，不再更新状态）
		if enemy.get("_is_dead") == true:
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

		# 检测 Attack 状态变化 → 立即发送可靠 RPC
		var prev_state: String = _prev_enemy_states.get(enemy.name, "")
		if state_name == "Attack" and prev_state != "Attack":
			sync_enemy_attack.rpc(enemy.name, enemy.get("_facing"))
			print("[NetSync] 敌人 Attack 状态变化: %s → 立即广播" % enemy.name)

	if not data.is_empty():
		sync_enemies_batch.rpc(data)
		# 保存本帧状态供下次比较
		_prev_enemy_states.clear()
		for enemy_name: String in data:
			_prev_enemy_states[enemy_name] = data[enemy_name]["state"]


## 攻击/装填后同步弹夹弹药回请求方 Client
## 注意：不同步备弹 — Client 端本地管理备弹（乐观扣除），Host 端 player_data.inventory 未同步
func _sync_ammo_back(peer_id: int, player: Node, weapon_item_id: String) -> void:
	var pd = player.get("player_data")
	if not pd:
		return
	var mag: int = pd.get_magazine_ammo(weapon_item_id)
	sync_player_ammo.rpc_id(peer_id, peer_id, weapon_item_id, mag)


## 广播攻击特效给除攻击者外的所有 Client
func _broadcast_attack_to_others(attacker_id: int, player: Node, weapon_item_id: String) -> void:
	if not Lobby.is_online() or not multiplayer.is_server():
		return
	for pid: int in Lobby.players:
		if pid == 1 or pid == attacker_id:
			continue  # 跳过 Host（已本地播放）和攻击者（已有本地预测）
		broadcast_attack_effects.rpc_id(pid, attacker_id, weapon_item_id, player.global_position, player.get("facing"))


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


func _get_request_sender_id() -> int:
	var sender_id := multiplayer.get_remote_sender_id()
	# call_local RPC 在本机没有 remote sender，Host 自己的 ID 是 1。
	return multiplayer.get_unique_id() if sender_id == 0 else sender_id


func _accept_request(sender_id: int, request_name: String) -> bool:
	if sender_id <= 0 or not Lobby.players.has(sender_id):
		return false
	var now := Time.get_ticks_msec()
	var per_sender: Dictionary = _request_last_ms.get(sender_id, {})
	var last: int = int(per_sender.get(request_name, -1000000))
	var interval: int = int(REQUEST_INTERVAL_MS.get(request_name, 100))
	if now - last < interval:
		return false
	per_sender[request_name] = now
	_request_last_ms[sender_id] = per_sender
	return true


func _get_validated_weapon_id(player: Node, requested_id: String) -> String:
	var pd = player.get("player_data")
	var active: WeaponData = pd.get_active_weapon() if pd else null
	var puppet_weapon = player.get("_puppet_weapon_data")
	if puppet_weapon is WeaponData:
		active = puppet_weapon as WeaponData
	if not active:
		active = player.get("_weapon_data") as WeaponData
	if not active:
		active = Global.get_active_weapon()
	if not active:
		return ""
	if requested_id.is_empty() or requested_id == active.item_id:
		return active.item_id
	return ""


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


## 查找弹药 ItemData 资源
func _find_ammo_resource(ammo_item_id: String) -> Resource:
	var derived := "res://object/item_%s_ammo.tres" % ammo_item_id.trim_prefix("ammo_")
	if ResourceLoader.exists(derived):
		var res: Resource = load(derived)
		if res is ItemData and res.item_id == ammo_item_id:
			return res
	var direct := "res://object/item_%s.tres" % ammo_item_id
	if direct != derived and ResourceLoader.exists(direct):
		var res: Resource = load(direct)
		if res is ItemData and res.item_id == ammo_item_id:
			return res
	return null


## 销毁命中点附近的视觉子弹（Client 端，模拟穿透检测）
## 只销毁最近的一颗（对应非穿透子弹），穿透子弹的额外子弹继续飞行
const VISUAL_BULLET_DESTROY_RADIUS: float = 80.0

func _destroy_nearby_visual_bullets(hit_pos: Vector2) -> void:
	var tree := get_tree()
	if not tree:
		return
	var bullets: Array[Node] = tree.get_nodes_in_group("visual_bullet")
	var closest: Node2D = null
	var closest_dist: float = VISUAL_BULLET_DESTROY_RADIUS
	for bullet: Node in bullets:
		if not is_instance_valid(bullet):
			continue
		var dist: float = bullet.global_position.distance_to(hit_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest = bullet as Node2D
	if closest:
		closest.queue_free()
