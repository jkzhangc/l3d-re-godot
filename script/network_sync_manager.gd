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
func request_attack(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player: Node = _find_player(peer_id)
	if not player:
		print("[NetSync] request_attack: 未找到 Player%d" % peer_id)
		return
	if player.has_method("_execute_attack"):
		player._execute_attack()
		print("[NetSync] Host 执行 Player%d 的攻击" % peer_id)


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

## Host 广播：玩家 HP 变化（reliable）
@rpc("authority", "reliable")
func sync_player_hp(player_name: String, hp: float) -> void:
	var player: Node = _find_player_by_name(player_name)
	if not player:
		return
	player.current_hp = hp
	print("[NetSync] sync_player_hp: %s HP=%.0f" % [player_name, hp])


## Host 广播：敌人 HP 变化 / 死亡（reliable，低频）
@rpc("authority", "reliable")
func sync_enemy_hp(enemy_name: String, hp: float, is_dead: bool) -> void:
	var enemy: Node = _find_enemy(enemy_name)
	if not enemy:
		return
	enemy.current_hp = hp
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
		# HP 通过独立的 reliable RPC 更新，不在批量中覆盖


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
		var state: Dictionary = {
			"pos": enemy.global_position,
			"facing": enemy.get("_facing"),
			"moving": enemy.get("_moving"),
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
