extends Node

## 敌人碰撞一致性回归（2026-10-19 用户拍板方案 A）。
##
## 背景：Host 用真实物理模拟**所有**玩家（`network_world._simulate_host_players`
## → `move_with_corner_assist()` → `move_and_slide()`），而玩家 `collision_mask = 11`
## 含敌人层 8 → 玩家会被敌人实体挡住。Client 镜像原本把 `CollisionShape2D` 一起关掉，
## 本机预测于是直接穿身而过 —— 同一段输入两端物理规则不同，位置差累积到 70px 量级，
## 远超纠偏死区（`max(0.5, 最近速度 × RTT)`，跑动约 10~14px）→ 逐帧回拽 = 用户报的「回弹」。
##
## 本用例锁三条不变量：
## ① 活的 Client 镜像保留实体碰撞（且真的能挡住玩家）；
## ② 镜像的 AI/视野/受击盒仍然关停（客户端不跑模拟、不重复结算伤害）；
## ③ 死亡后碰撞必须关掉（尸体不挡路，与 Host `_disable_for_corpse()` 一致），
##    且尸体重复 `configure_network_entity`（每包都会调）不得把碰撞开回来。
##
## 入口：godot --headless --path <项目目录> res://tools/net_enemy_collision_check.tscn
## 不加载地图、不联网、不写存档或配置。

class BehaviorNet extends RefCounted:
	var is_host: bool = false


## 仅替换会话启动与 RPC 发送边界，快照构建/解析/实体创建/行为应用均跑生产实现。
class BehaviorWorld extends "res://script/network_world.gd":
	var sent_behaviors: Array = []

	func _ready() -> void:
		set_process(false)
		set_physics_process(false)
		_players_parent = self

	func _exit_tree() -> void:
		pass

	func _send_to_ready_clients(method: StringName, args: Array = []) -> void:
		sent_behaviors.append([method, args])


const EnemyScene := preload("res://object/enemy.tscn")
const PlayerScene := preload("res://object/player.tscn")
const ENEMY_COLLISION_LAYER: int = 8
const PLAYER_COLLISION_LAYER: int = 4
## 敌人实体 20x28（居中于原点）、玩家 24x27（偏移 y+3.5）→ 间距 60 时
## 两体之间还剩 38px 空隙，足以区分「撞得到」与「撞不到」。
const PLAYER_POS := Vector2(0.0, 0.0)
const MIRROR_POS := Vector2(60.0, 0.0)

var _total: int = 0
var _failures: int = 0
var _finished: bool = false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	_total += 1
	if not ok:
		_failures += 1
	print("NET_ENEMY_COLLISION_CHECK %s %s" % ["PASS" if ok else "FAIL", label])


func _spawn_enemy(pos: Vector2) -> CharacterBody2D:
	var enemy := EnemyScene.instantiate() as CharacterBody2D
	enemy.global_position = pos
	add_child(enemy)
	return enemy


## `set_deferred("disabled", ...)` 要等下一次刷新才落地 —— 少等一帧就会读到旧值。
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame


func _run() -> void:
	# ★ 确定性前提：Director 会把这个测试场景当正式地图自动刷怪
	# （实测日志 "SpawnManager scatter spawn: 1 enemies"）—— 多出来的实体
	# 会混进 test_move 的查询结果，让「6px 不被挡」随机翻车。
	# 先关总开关，再把已经刷出来的敌人清掉，等一帧让 queue_free 真正生效。
	var director: Node = get_node_or_null("/root/Director")
	if director != null:
		director.set("auto_spawn_enabled", false)
	for value: Node in get_tree().get_nodes_in_group("enemy"):
		value.queue_free()
	await get_tree().process_frame
	await get_tree().physics_frame
	_check(get_tree().get_nodes_in_group("enemy").is_empty(), "测试空间内没有残留敌人（Director 已静默）")

	var mirror := _spawn_enemy(MIRROR_POS)
	var player := PlayerScene.instantiate() as CharacterBody2D
	# 联机实体：跳过单机座位绑定，且不跑本机输入/移动逻辑（本用例只查碰撞查询）。
	player.network_controlled = true
	player.global_position = PLAYER_POS
	add_child(player)
	player.set_process(false)
	player.set_physics_process(false)
	await get_tree().process_frame

	mirror.configure_network_entity(101, true)
	await _settle()

	var shape := mirror.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_check(mirror.network_presentation_only, "镜像已标记 presentation_only")
	_check(shape != null, "镜像带 CollisionShape2D 节点")

	# ── ① 存活镜像保留实体碰撞 ───────────────────────────────────
	_check(shape != null and not shape.disabled, "镜像存活时保留实体碰撞（两端物理规则一致）")
	_check(mirror.collision_layer == ENEMY_COLLISION_LAYER, "镜像仍在敌人碰撞层 8")
	_check((mirror.collision_mask & PLAYER_COLLISION_LAYER) != 0, "镜像 mask 仍含玩家层 4")

	# ② 真实物理查询：同一段位移，撞得到 / 撞不到必须真的有区别。
	var blocked: bool = player.test_move(player.global_transform, Vector2(60.0, 0.0))
	_check(blocked, "镜像存活时玩家向它位移 60px 会被挡住（真实物理查询）")
	var free_near: bool = player.test_move(player.global_transform, Vector2(6.0, 0.0))
	_check(not free_near, "镜像存活时玩家小幅位移 6px 不被挡（不是全场误报）")

	# ── ③ 镜像仍然不跑 AI、不算伤害 ──────────────────────────────
	_check(mirror.vision_area != null and not mirror.vision_area.monitoring, "镜像视野仍然关闭（不跑 AI）")
	_check(mirror.hurt_area != null and not mirror.hurt_area.monitoring, "镜像受击盒仍然关闭（伤害只走 Host 权威）")
	var sm := mirror.get_node_or_null("StateMachine") as Node
	_check(sm == null or sm.process_mode == Node.PROCESS_MODE_DISABLED, "镜像状态机仍然停摆")

	# ── ④ 存活快照不得把碰撞关掉 ─────────────────────────────────
	mirror.apply_network_presentation(Vector2(300.0, 300.0), 2, true, float(mirror.max_hp), -1, false, false, false)
	await _settle()
	_check(shape != null and not shape.disabled, "存活快照下发后碰撞仍然启用")

	# ── ⑤ 死亡后关碰撞（尸体不挡路）─────────────────────────────
	mirror.apply_network_presentation(Vector2(300.0, 300.0), 2, false, 0.0, -1, true, false, false)
	await _settle()
	_check(bool(mirror._is_dead), "镜像已进入死亡态")
	_check(shape != null and shape.disabled, "死亡后关闭实体碰撞（尸体不挡路）")

	# ── ⑥ 尸体重复 configure（每个快照包都会调）不得重开碰撞 ──────
	mirror.configure_network_entity(101, true)
	await _settle()
	_check(shape != null and shape.disabled, "尸体重复 configure_network_entity 不会重新打开碰撞")
	mirror.apply_network_presentation(Vector2(10, 10), 0, true, 100.0, 1, false, false, false, 8)
	_check(mirror.is_network_dead() and shape.disabled, "可靠死亡后迟到存活热包不能复活镜像")

	# ── ⑦ Host 侧敌人不受影响 ───────────────────────────────────
	var host_enemy := _spawn_enemy(Vector2(900.0, 900.0))
	await get_tree().process_frame
	host_enemy.configure_network_entity(102, false)
	await _settle()
	var host_shape := host_enemy.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_check(not host_enemy.network_presentation_only, "Host 敌人未标记 presentation_only")
	_check(host_shape != null and not host_shape.disabled, "Host 敌人碰撞保持启用")
	var host_hp_before: float = float(host_enemy.current_hp)
	host_enemy.apply_network_presentation(Vector2(900.0, 900.0), 0, false, 5.0, -1, false, false, true)
	_check(is_equal_approx(float(host_enemy.current_hp), host_hp_before),
		"apply_network_presentation 对 Host 实体是空操作（快照不写权威敌人血量）")

	await _test_network_behaviors(player)
	_finish([mirror, player, host_enemy])


func _test_network_behaviors(player: CharacterBody2D) -> void:
	var world := BehaviorWorld.new()
	world.net = BehaviorNet.new()
	add_child(world)
	world._players[27] = {"node": player}
	var packet := {"entity_id": 701, "variant_id": "male", "position": Vector2(500, 500),
		"hp": 100.0, "behavior_revision": 1, "ai_state": "Discover",
		"forced_target_locked": true, "forced_target_peer_id": 27, "rage": true}
	world._ensure_client_enemy(701, packet, true)
	var enemy := world._resolve_enemy_entry(world._enemies[701])
	await _settle()
	_check(enemy.get_network_variant_id() == "male", "真实创建路径按白名单保留变体 id")
	_check(enemy.is_rage() and enemy.has_forced_target() and enemy.get_forced_target() == player,
		"初始生成/晚加入重建直接恢复狂暴与 peer 目标")
	_check(enemy.discover_label.visible, "发现标签来自快照而非 Client 状态机")
	var speed: float = enemy.move_speed
	var damage: float = enemy.attack_damage
	var behavior := packet.duplicate()
	behavior.merge({"behavior_revision": 3, "ai_state": "Chase", "rage": false,
		"forced_target_locked": false, "forced_target_peer_id": 0}, true)
	world.enemy_behavior_presentation(701, behavior)
	world._ensure_client_enemy(701, packet, true, false)
	enemy.apply_network_element_tint(8)
	_check(not enemy.is_rage() and not enemy.has_forced_target() and not enemy.discover_label.visible,
		"旧可靠快照与旧热包狂暴位不能回滚新可靠释放事件")
	_check(enemy.move_speed == speed and enemy.attack_damage == damage, "Client 狂暴进出不改伤害与速度")
	_check(enemy.move_speed == world.NETWORK_VARIANT_MALE.move_speed
		and enemy.attack_damage == world.NETWORK_VARIANT_MALE.attack_damage, "Client 初始狂暴同样不写权威数值")
	_check(enemy.walk_texture == enemy._base_walk_texture, "退出狂暴恢复原普通图")
	behavior.merge({"behavior_revision": 4, "forced_target_locked": true, "forced_target_peer_id": 83}, true)
	world.enemy_behavior_presentation(701, behavior)
	_check(enemy.get_forced_target() == null and enemy.get_network_forced_target_peer_id() == 83,
		"目标镜像尚未建立时保留 peer 键而非 instance_id")
	world._players[83] = {"node": player}
	world._refresh_client_enemy_targets()
	_check(enemy.get_forced_target() == player, "玩家镜像重建后按 peer 键补绑")
	world.enemy_behavior_presentation(702, behavior)
	var pending_packet := packet.duplicate()
	pending_packet["entity_id"] = 702
	world._ensure_client_enemy(702, pending_packet, true)
	var pending := world._resolve_enemy_entry(world._enemies[702])
	_check(pending.get_network_forced_target_peer_id() == 83 and not pending.is_rage(),
		"先到可靠行为再到生成包时保留最新版本")
	world._remove_client_enemy(702)
	world._ensure_client_enemy(702, pending_packet, true)
	pending = world._resolve_enemy_entry(world._enemies[702])
	_check(pending.get_network_forced_target_peer_id() == 83 and not pending.is_rage(),
		"节点重建后旧生成包仍不能回滚已知可靠行为")
	var old := world._normalize_enemy_snapshot([703, Vector2.ZERO, 0, 100.0, false, 1, false, false])
	_check(int(old["element_state"]) == -1 and not old.has("behavior_revision"), "旧 8 项包保留缺省语义")
	var legacy_packet := {"entity_id": 703, "variant_id": "male", "position": Vector2.ZERO,
		"hp": 100.0, "ai_state": "Idle", "element_state": 8}
	world._ensure_client_enemy(703, legacy_packet, true)
	var legacy_enemy := world._resolve_enemy_entry(world._enemies[703])
	_check(legacy_enemy.is_rage() and not legacy_enemy.has_forced_target(), "旧字典包狂暴位可用且默认不锁目标")
	world._ensure_client_enemy(703, old, false)
	_check(legacy_enemy.is_rage(), "旧 8 项包缺字段不误清既有狂暴")
	var old_exit := world._normalize_enemy_snapshot([703, Vector2.ZERO, 0, 100.0, false, 1, false, false, 0])
	world._ensure_client_enemy(703, old_exit, false)
	_check(not legacy_enemy.is_rage(), "旧 9 项包仍可正常退出狂暴")
	var no_rage_packet := packet.duplicate()
	no_rage_packet.merge({"entity_id": 704, "variant_id": "chunen"}, true)
	world._ensure_client_enemy(704, no_rage_packet, true)
	var no_rage := world._resolve_enemy_entry(world._enemies[704])
	_check(not no_rage.is_rage() and no_rage.has_forced_target(), "无狂暴图变体仍正确同步目标")
	var state_machine := enemy.get_node("StateMachine")
	_check(state_machine.process_mode == Node.PROCESS_MODE_DISABLED and not enemy.vision_area.monitoring,
		"所有行为同步后 Client AI/视野仍关停")
	var hp_before: float = enemy.current_hp
	enemy.take_damage(10.0, 0.0, Vector2.ZERO)
	_check(enemy.current_hp == hp_before, "Client 本地伤害入口仍为 no-op")
	# 同一个实体在生产 Host build 中生成 peer 键、字典扩展和原长热条目。
	world.net.is_host = true
	enemy.configure_network_entity(701, false)
	enemy._forced_target_locked = true
	enemy._forced_target = player
	var full: Dictionary = world._public_enemy_state(701)
	_check(int(full["forced_target_peer_id"]) == 27 and full.has("behavior_revision"),
		"真实 Host build 把目标节点转换为玩家 peer 键")
	var hot: Array = world._build_enemy_snapshot(true)
	_check(not hot.is_empty() and (hot[0] as Array).size() == 9, "高频条目继续保持 9 项不扩包")
	world._sync_host_enemy_behaviors()
	var sent_count := world.sent_behaviors.size()
	world._sync_host_enemy_behaviors()
	_check(world.sent_behaviors.size() == sent_count, "状态未变化不重复可靠广播")
	world.net.is_host = false
	enemy.configure_network_entity(701, true)
	world.queue_free()
	await get_tree().process_frame


func _finish(nodes: Array) -> void:
	if _finished:
		return
	_finished = true
	for node: Node in nodes:
		if is_instance_valid(node):
			node.queue_free()
	print("NET_ENEMY_COLLISION_CHECK total=%d passed=%d failed=%d" % [
		_total, _total - _failures, _failures])
	get_tree().quit(1 if _failures > 0 else 0)
