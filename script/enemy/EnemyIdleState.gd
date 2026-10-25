extends State

## ── 架构定位 ──
## 系统：敌人状态机 ｜ 层：玩法（State）
## 联机：Host 执行发现判定
## 职责：空闲状态：按「站—走—站」的节奏在出生点附近徘徊，并主动轮询视野锥以切换 Discover。
## 依赖：State、enemy 实体、VisionArea

## 仅在实体未死亡且无目标时轮询视野；Host 执行发现判定，Client 不自行改变 AI 状态。
##
## ★2026-10-24 重写（用户：「求生之路里一片区域有丧尸在徘徊」）：
## 旧实现是「每 1.2~3.2 秒随机换一次方向、24px/s 连续走」，观感像**原地发抖** ——
## 既没有停顿（真丧尸会站着发呆），也没有活动范围（随机游走会缓慢漂移）。
## 现在改成 L4D 那种行为：
##   · **停顿 0.9~2.8s（站着不动）→ 走 0.9~2.4s → 再停**，走得慢、有明显的静止段；
##   · 目标点取在当前「家」半径 150px 内，偏离就折回 —— 游荡者留在自己的区域，
##     不会追着玩家一路漂成"同一批怪"；
##   · 走路前仍做点位可走检查，避免贴墙上抖动。

const WALK_SPEED: float = 30.0        ## 徘徊步速（px/s）：比追击慢得多，一眼能分辨
const MOVE_MIN: float = 0.9           ## 一次连续走多久（秒）下限
const MOVE_MAX: float = 2.4           ## 上限
const PAUSE_MIN: float = 0.9          ## 两次移动之间站多久（秒）下限
const PAUSE_MAX: float = 2.8          ## 上限
const WANDER_RADIUS: float = 150.0    ## 活动半径：以"家"为圆心的徘徊范围
const ARRIVE_EPS: float = 12.0        ## 到达判定

var _wander_dir: Vector2 = Vector2.ZERO
var _wander_target: Vector2 = Vector2.ZERO
var _phase_timer: float = 0.0
var _walking: bool = false
var _home: Vector2 = Vector2.ZERO
var _home_set: bool = false


func enter() -> void:
	character.update_moving(false)
	character.velocity = Vector2.ZERO
	## 第一次进 Idle 时把当前位置记为「家」；之后被击退/追击跑远再回来，
	## 仍然围绕这个家徘徊（不让游荡者整体迁移）。
	if not _home_set:
		_home = character.global_position
		_home_set = true
	_start_pause()


func _start_pause() -> void:
	_walking = false
	_phase_timer = randf_range(PAUSE_MIN, PAUSE_MAX)
	character.velocity = Vector2.ZERO
	character.update_moving(false)


func _start_walk() -> void:
	_walking = true
	_phase_timer = randf_range(MOVE_MIN, MOVE_MAX)
	var offset: Vector2 = Vector2.RIGHT.rotated(randf_range(0.0, TAU)) * randf_range(40.0, 110.0)
	var target: Vector2 = character.global_position + offset
	## 目标点越出活动半径 → 折回半径内侧，保证不会越走越远。
	if target.distance_to(_home) > WANDER_RADIUS:
		var outward: Vector2 = target - _home
		if outward.length() < 0.001:
			outward = Vector2.RIGHT
		target = _home + outward.normalized() * (WANDER_RADIUS * 0.6)
	_wander_target = target
	var delta: Vector2 = target - character.global_position
	if delta.length() < 0.001:
		_wander_dir = Vector2.RIGHT.rotated(randf_range(0.0, TAU))
	else:
		_wander_dir = delta.normalized()


func process_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character

	# 主动轮询 VisionArea 内重叠的 body（比 body_entered 信号更可靠）
	var vision: Area2D = enemy.get_node_or_null("VisionArea") as Area2D
	if not vision:
		return

	var bodies: Array[Node2D] = vision.get_overlapping_bodies()
	for body: Node2D in bodies:
		# 检查是否为玩家（仅玩家有 get_weapon_data 方法）
		if enemy._is_player_body(body):
			# 扇形视野检测
			if enemy._is_in_vision_cone(body):
				enemy._player_in_sight = true
				enemy._player_ref = body
				print("[敵人] 在视野中发现玩家！")
				transition_requested.emit("Discover")
				return


func physics_update(delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	if enemy._player_ref != null and enemy._is_player_body(enemy._player_ref):
		return

	_phase_timer -= delta

	## ① 站着发呆：这是"徘徊"的停顿段，不能一直动
	if not _walking:
		enemy.velocity = Vector2.ZERO
		enemy.update_moving(false)
		if _phase_timer <= 0.0:
			_start_walk()
		return

	## ② 走动：到点 / 超时 / 前方不可走 → 停下来
	if _phase_timer <= 0.0:
		_start_pause()
		return
	if enemy.global_position.distance_to(_wander_target) < ARRIVE_EPS:
		_start_pause()
		return

	var next_pos: Vector2 = enemy.global_position + _wander_dir * WALK_SPEED * delta
	if not _can_walk_toward(next_pos):
		_start_pause()
		return

	enemy.velocity = _wander_dir * WALK_SPEED
	enemy.update_facing_from_direction(_wander_dir)
	enemy.update_moving(true)
	enemy.move_with_corner_assist()


func _can_walk_toward(pos: Vector2) -> bool:
	var tree: SceneTree = character.get_tree()
	if not tree:
		return true

	# 只做最简单的“点位是否可走”检查：避免空中/墙上巡逻；不做复杂地图扫描。
	for tm: TileMapLayer in tree.get_nodes_in_group("tilemap"):
		if not is_instance_valid(tm) or tm.tile_set == null:
			continue
		# 无 physics layer 的 TileSet（纯视觉图块集）跳过，否则 get_collision_polygons_count(0)
		# 会每格刷 "Index p_layer_id = 0 is out of bounds"（第四关 Map0146 曾刷数千条）。
		if tm.tile_set.get_physics_layers_count() == 0:
			continue
		var local_pos: Vector2 = tm.to_local(pos)
		var coords: Vector2i = tm.local_to_map(local_pos)
		var tile_data: TileData = tm.get_cell_tile_data(coords)
		if tile_data and tile_data.get_collision_polygons_count(0) > 0:
			return false
	return true
