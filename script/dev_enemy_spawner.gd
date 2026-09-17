class_name DevEnemySpawner extends Node2D

## ── 架构定位 ──
## 系统：开发工具 ｜ 层：测试（Node2D）
## 联机：仅单机测试用（不入联机流程）
## 职责：敌人试验场自动刷敌节点 —— 按 Inspector 配置持续生成丧尸/特感，供实机调参。
## 依赖：Director.spawn_special_enemy（特感）、object/enemy.tscn（丧尸）
##
## 使用（2026-09-17 用户需求）：
##   1. 本节点放在地图的 DecorLayer 下（生成的敌人挂到同一层，保证 y_sort 正确）。
##   2. 丧尸/特感各自独立配置：开关、模式（固定单个 / 按池 weight 加权随机）、
##      刷的间隔、一次刷几只、场上最多多少只。
##   3. 生成位置 = 玩家周围环形随机（min~max 距离），点查询图块障碍层避免嵌墙。
##
## 测试场运行方式：编辑器里打开 scene/maps/测试-敌人试验场.tscn → F6 直接跑。

enum SpawnMode { FIXED, WEIGHTED_POOL }

const ENEMY_SCENE := preload("res://object/enemy.tscn")

@export_group("丧尸（普通敌人）")
@export var zombie_enabled: bool = true
@export var zombie_mode: SpawnMode = SpawnMode.FIXED
## FIXED 模式用的变体。空 = 不注入（enemy.tscn 默认男性丧尸外观）。
@export var zombie_fixed: ZombieVariant
## WEIGHTED_POOL 模式：按各变体 tres 的 weight 加权随机。
@export var zombie_pool: Array[ZombieVariant] = []
## 刷的间隔（秒）。
@export var zombie_interval: float = 3.0
## 一次刷几只。
@export var zombie_batch: int = 1
## 场上最多多少只（不含特感）。
@export var zombie_max_alive: int = 10

@export_group("特感")
@export var special_enabled: bool = false
@export var special_mode: SpawnMode = SpawnMode.FIXED
## FIXED 模式用的特感。
@export var special_fixed: SpecialEnemyData
## WEIGHTED_POOL 模式：按各 tres 的 weight 加权随机。
@export var special_pool: Array[SpecialEnemyData] = []
## 刷的间隔（秒）。
@export var special_interval: float = 6.0
## 一次刷几只。
@export var special_batch: int = 1
## 场上最多多少只（不含丧尸）。
@export var special_max_alive: int = 2

@export_group("通用")
## 生成点距玩家的最小/最大距离（px，环形随机）。
@export var spawn_min_dist: float = 280.0
@export var spawn_max_dist: float = 520.0
## true = 屏蔽掉"玩家太远/太近不刷"之类的生成限制，纯按配置刷（试验场语义）。
@export var ignore_director_limits: bool = true

var _zombie_timer: float = 0.0
var _special_timer: float = 0.0
var _warned_no_special: bool = false


func _physics_process(delta: float) -> void:
	# 联机 Client 禁用（P0-B2）：试验场是单机调参工具；Client 若放行会绕过 Director 的
	# 生成禁令私刷敌人，与 Host 世界分裂。判定方式与 director.gd 同款。
	if _is_network_client_session():
		return
	var player: Node2D = _get_player()
	if player == null or player.get("_is_dying") == true:
		return

	if zombie_enabled:
		_zombie_timer += delta
		if _zombie_timer >= maxf(0.2, zombie_interval):
			_zombie_timer = 0.0
			_spawn_batch(player, false)
	if special_enabled:
		_special_timer += delta
		if _special_timer >= maxf(0.2, special_interval):
			_special_timer = 0.0
			_spawn_batch(player, true)


func _get_player() -> Node2D:
	return get_tree().get_first_node_in_group("player") as Node2D


## 场上存活计数：敌人都在 "enemy" 组；特感额外在 "special_enemies" 组。
func _alive_count(special: bool) -> int:
	if special:
		return get_tree().get_nodes_in_group("special_enemies").size()
	return get_tree().get_nodes_in_group("enemy").size() \
			- get_tree().get_nodes_in_group("special_enemies").size()


func _spawn_batch(player: Node2D, special: bool) -> void:
	var max_alive: int = special_max_alive if special else zombie_max_alive
	var batch: int = maxi(1, special_batch if special else zombie_batch)
	var room: int = max_alive - _alive_count(special)
	if room <= 0:
		print("[试验场] 已达上限（%d）本批跳过" % max_alive)
		return
	var decor: Node = get_parent()
	for _i: int in mini(batch, room):
		var pos: Vector2 = _pick_spawn_position(player)
		if pos == Vector2.INF:
			print("[试验场] 找不到可行走点，本批放弃")
			return
		var spawned: Node2D = _spawn_one(pos, special, decor)
		if spawned == null:
			print("[试验场] 生成失败")
			return


func _spawn_one(pos: Vector2, special: bool, decor: Node) -> Node2D:
	if special:
		var data: SpecialEnemyData = _pick_special()
		if data == null:
			if not _warned_no_special:
				_warned_no_special = true
				print("[试验场] 未配置特感（special_fixed / special_pool 均为空），跳过特感生成")
			return null
		var dir: Node = get_node_or_null("/root/Director")
		if dir == null or not dir.has_method("spawn_special_enemy"):
			return null
		var enemy: Node2D = dir.spawn_special_enemy(pos, data, decor)
		if enemy:
			print("[试验场] 刷特感：%s @ %s" % [data.id, pos])
		return enemy

	var enemy: Node2D = ENEMY_SCENE.instantiate()
	enemy.global_position = pos
	var zv: ZombieVariant = _pick_zombie()
	if zv != null:
		## 与 Director.spawn_enemy 的变体注入同字段（2026-09-17 试验场）
		enemy.walk_texture = zv.normal_texture
		enemy.move_speed = zv.move_speed
		enemy.attack_damage = zv.attack_damage
		if float(zv.get("max_hp")) > 0.0:
			enemy.max_hp = float(zv.get("max_hp"))
		if zv.get("discover_sound") != null:
			enemy.discover_sound = zv.get("discover_sound")
		if zv.get("hurt_sound") != null:
			enemy.hurt_sound = zv.get("hurt_sound")
		if zv.get("attack_sound") != null:
			enemy.attack_sound = zv.get("attack_sound")
		if zv.get("death_sound") != null:
			enemy.death_sound = zv.get("death_sound")
		if zv.get("headshot_sound") != null:
			enemy.headshot_sound = zv.get("headshot_sound")
		if zv.get("headshot_fall_sound") != null:
			enemy.headshot_fall_sound = zv.get("headshot_fall_sound")
		if zv.get("hit_target_sound") != null:
			enemy.hit_target_sound = zv.get("hit_target_sound")
		if zv.rage_texture != null:
			enemy.variant_rage_texture = zv.rage_texture
			enemy.variant_rage_move_speed = zv.rage_move_speed
			enemy.variant_rage_attack_damage = zv.rage_attack_damage
			enemy.variant_rage_exhaust_seconds = zv.get("rage_exhaust_seconds")
			enemy.variant_rage_exhaust_down_seconds = zv.get("rage_exhaust_down_seconds")
	decor.add_child(enemy)
	print("[试验场] 刷丧尸：%s @ %s" % [zv.id if zv != null else "默认丧尸", pos])
	return enemy


func _pick_zombie() -> ZombieVariant:
	if zombie_mode == SpawnMode.FIXED:
		return zombie_fixed
	if zombie_pool.is_empty():
		return zombie_fixed
	return _weighted_pick(zombie_pool)


func _pick_special() -> SpecialEnemyData:
	if special_mode == SpawnMode.FIXED:
		return special_fixed
	if special_pool.is_empty():
		return special_fixed
	return _weighted_pick(special_pool)


## 按 tres 的 weight 加权随机（weight<=0 不会被选中；全 0 时退回第一个）。
func _weighted_pick(pool: Array) -> Resource:
	var total: float = 0.0
	for r: Resource in pool:
		if r != null and float(r.get("weight")) > 0.0:
			total += float(r.get("weight"))
	if total <= 0.0:
		return pool[0]
	var roll: float = randf() * total
	for r: Resource in pool:
		if r != null and float(r.get("weight")) > 0.0:
			roll -= float(r.get("weight"))
			if roll <= 0.0:
				return r
	return pool.back()


## 玩家周围取可行走点：优先复用 Director 的 A*/图块级判定（列车台这类 83% 障碍的窄图，
## 自造点查询几乎全落墙）；无 Director 时退回自采样。
func _pick_spawn_position(player: Node2D) -> Vector2:
	var dir: Node = get_node_or_null("/root/Director")
	if dir != null and dir.has_method("_find_walkable_near_player"):
		var pos: Variant = dir.call("_find_walkable_near_player", player)
		if pos is Vector2 and pos != Vector2.ZERO:
			return pos
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	for _i: int in 24:
		var ang: float = randf() * TAU
		var dist: float = randf_range(spawn_min_dist, spawn_max_dist)
		var pos: Vector2 = player.global_position + Vector2.from_angle(ang) * dist
		var q := PhysicsPointQueryParameters2D.new()
		q.position = pos
		q.collision_mask = 1 | 32
		if space.intersect_point(q).is_empty():
			return pos
	return Vector2.INF


func _is_network_client_session() -> bool:
	## 与 director.gd 同款：用节点路径而非 Autoload 标识符，兼容脚本热重载时序。
	var net: Node = get_node_or_null("/root/Net")
	return net != null \
		and net.has_method("is_online_session") \
		and net.is_online_session() \
		and not bool(net.get("is_host"))
