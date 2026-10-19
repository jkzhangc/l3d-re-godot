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

	_finish([mirror, player, host_enemy])


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
