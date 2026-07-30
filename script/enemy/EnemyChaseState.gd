extends State
## 追击玩家 — A* 寻路 + 调试输出 + 路径可视化

# ── 路径跟踪 ──
var _path: Array[Vector2] = []
var _path_idx: int = 0
var _repath_timer: float = 0.0
var _first_path: bool = true  ## 首次寻路打印详细信息
var _no_path_count: int = 0    ## 连续无路径次数
var _last_failed: bool = false  ## 上次寻路是否失败
var _last_player_pos: Vector2 = Vector2.ZERO  ## 上次寻路时玩家位置
var _fallback_mode: bool = false  ## 降级模式：连续失败后切到直接追击，避免卡顿

# ── A* 网格缓存（静态：所有敌人共享，只查一次）──
static var _tile_walk_cache: Dictionary = {}  ## Vector2i → bool — 地图格子缓存
var _cell_size: float = 32.0
var _space_state: PhysicsDirectSpaceState2D = null
var _tilemaps: Array[TileMapLayer] = []  ## 缓存所有 TileMapLayer

const REPATH_INTERVAL: float = 0.5          ## 正常重算间隔
const REPATH_FAIL_INTERVAL: float = 3.0     ## 寻路失败后重试间隔（避免卡顿）
const REPATH_FAIL_MOVE_DIST: float = 48.0   ## 失败后玩家移动多远才重试
const WAYPOINT_RADIUS: float = 10.0
const MAX_ASTAR_ITERATIONS: int = 2000
const NO_PATH_STOP: int = 5       ## 连续无路径多少次后停止移动
const FALLBACK_THRESHOLD: int = 2  ## 连续失败多少次切到直接追击模式


func enter() -> void:
	character.update_moving(true)
	_path = []
	_path_idx = 0
	_repath_timer = 0.0
	_no_path_count = 0
	_last_failed = false
	_last_player_pos = Vector2.ZERO
	_fallback_mode = false
	_space_state = null
	_first_path = true
	_tile_walk_cache.clear()
	# 找到所有 TileMapLayer
	_tilemaps.clear()
	_find_all_tilemaps()
	# 注册调试绘制字段
	character._debug_path = []
	character._debug_path_idx = 0
	character._debug_path_found = false
	character._debug_start_grid = Vector2i.ZERO
	character._debug_end_grid = Vector2i.ZERO
	character._debug_start_walkable = false
	character._debug_end_walkable = false
	character._debug_astar_iters = 0
	character._debug_walk_cache = {}


func process_update(_delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	var player: Node2D = enemy._player_ref
	if not player:
		transition_requested.emit("Idle")
		return

	var fw: Vector2 = enemy.get_facing_vector()
	var rect_center: Vector2 = enemy.global_position + fw * enemy.attack_range_forward_offset
	var rel: Vector2 = player.global_position - rect_center
	var rt: Vector2 = Vector2(fw.y, -fw.x)
	if abs(rel.dot(rt)) <= enemy.attack_range.x / 2.0 and abs(rel.dot(fw)) <= enemy.attack_range.y / 2.0:
		transition_requested.emit("Attack")
		return


func physics_update(delta: float) -> void:
	var enemy: Node2D = character
	var player: Node2D = enemy._player_ref
	if not player:
		return

	var to_player: Vector2 = player.global_position - enemy.global_position
	if to_player.length() < 1.0:
		return

	var speed: float = enemy.move_speed

	# ── 降级模式：连续失败3次 → 切到直接追击（避免A*卡顿）──
	if _fallback_mode:
		# 直接朝玩家移动 + 滑墙，不跑A*
		_repath_timer += delta
		if _repath_timer >= REPATH_FAIL_INTERVAL:
			_repath_timer = 0.0
			var player_moved: float = player.global_position.distance_to(_last_player_pos)
			if player_moved > REPATH_FAIL_MOVE_DIST:
				# 玩家移动够远，尝试恢复A*
				_fallback_mode = false
				_path = _find_path(enemy.global_position, player.global_position)
				_last_player_pos = player.global_position
				if not _path.is_empty():
					_path_idx = 1 if _path.size() > 1 else 0
					_last_failed = false
					enemy._debug_path = _path
					enemy._debug_path_idx = _path_idx
				else:
					_fallback_mode = true  # 还是失败，继续降级
		if _fallback_mode:
			_move_direct(enemy, to_player, speed, delta)
			return

	# 定期重算路径（失败后退避）
	_repath_timer += delta
	var should_repath: bool = _path.is_empty()
	if not should_repath and not _last_failed:
		if _repath_timer >= REPATH_INTERVAL:
			should_repath = true

	if should_repath:
		_repath_timer = 0.0
		_last_player_pos = player.global_position
		_path = _find_path(enemy.global_position, player.global_position)
		_path_idx = 1 if _path.size() > 1 else 0
		_last_failed = _path.is_empty()
		if _last_failed:
			_no_path_count += 1
			if _no_path_count >= FALLBACK_THRESHOLD:
				_fallback_mode = true  # 切到降级模式
		else:
			_no_path_count = 0
		enemy._debug_path = _path
		enemy._debug_path_idx = _path_idx
		enemy._debug_walk_cache = _tile_walk_cache
		if Global.debug_visuals:
			enemy.queue_redraw()

	# ── 确定移动目标方向（所有模式统一走 _move_with_slide，速度一致）──
	if _path.is_empty():
		_move_direct(enemy, to_player, speed, delta)
		return

	_no_path_count = 0
	while _path_idx < _path.size():
		if enemy.global_position.distance_to(_path[_path_idx]) < WAYPOINT_RADIUS:
			_path_idx += 1
		else:
			break

	var move_dir: Vector2
	if _path_idx >= _path.size():
		move_dir = to_player.normalized()
	else:
		move_dir = (_path[_path_idx] - enemy.global_position).normalized()

	character.update_facing_from_direction(move_dir)
	_move_with_remainder_slide(character, move_dir, speed, delta)


# ═══════════════════════════════════════
# 移动工具
# ═══════════════════════════════════════

func _move_direct(enemy: Node2D, to_player: Vector2, speed: float, delta: float) -> void:
	## 直接朝玩家移动（降级模式 / 无路径回退）
	var move_dir: Vector2 = to_player.normalized()
	character.update_facing_from_direction(move_dir)
	_move_with_remainder_slide(character, move_dir, speed, delta)


func _move_with_remainder_slide(body: CharacterBody2D, move_dir: Vector2, speed: float, delta: float) -> void:
	## 移动 + 碰撞时用剩余速度滑墙（总移动量 ≤ speed*delta）
	var motion: Vector2 = move_dir * speed * delta
	for _i in range(3):
		var col: KinematicCollision2D = body.move_and_collide(motion)
		if not col:
			break
		motion = col.get_remainder().slide(col.get_normal())
		if motion.length() < 0.5:
			break


# ═══════════════════════════════════════
# A* 寻路（带调试输出）
# ═══════════════════════════════════════

func _find_path(from: Vector2, to: Vector2) -> Array[Vector2]:
	var start: Vector2i = _world_to_grid(from)
	var end: Vector2i = _world_to_grid(to)
	var start_ok: bool = _is_walkable(start)
	var end_ok: bool = _is_walkable(end)

	# 存储调试信息
	character._debug_start_grid = start
	character._debug_end_grid = end
	character._debug_start_walkable = start_ok
	character._debug_end_walkable = end_ok

	if _first_path or true:
		print("[A*] ═══ 寻路开始 ═══")
		print("[A*] 敌人世界: (%.0f, %.0f) → 格子: %s  可行走=%s" % [from.x, from.y, str(start), str(start_ok)])
		print("[A*] 玩家世界: (%.0f, %.0f) → 格子: %s  可行走=%s" % [to.x, to.y, str(end), str(end_ok)])

	if not end_ok:
		print("[A*] ⚠ 目标不可通行，搜索邻近格子...")
		end = _find_nearest_walkable(end)
		if end == Vector2i(-999999, -999999):
			print("[A*] ❌ 找不到可通行的邻近格子！")
			character._debug_path_found = false
			character._debug_astar_iters = 0
			_first_path = false
			return []
		print("[A*]   邻近可通行格子: %s" % str(end))

	if not start_ok:
		print("[A*] ❌ 起点不可通行！")
		character._debug_path_found = false
		character._debug_astar_iters = 0
		_first_path = false
		return []

	if start == end:
		print("[A*] 起点=终点，直走")
		character._debug_path_found = true
		character._debug_astar_iters = 0
		_first_path = false
		return [to]

	# A*
	var open_set: Array[Vector2i] = [start]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {}
	var f_score: Dictionary = {}
	g_score[start] = 0.0
	f_score[start] = _heuristic(start, end)

	var iterations: int = 0
	var explored: int = 0

	while open_set.size() > 0:
		iterations += 1
		if iterations > MAX_ASTAR_ITERATIONS:
			print("[A*] ⚠ 达到最大迭代 %d，停止搜索" % MAX_ASTAR_ITERATIONS)
			break

		# 找最小 f_score
		var current: Vector2i = open_set[0]
		var current_f: float = f_score.get(current, 1e9)
		var best_idx: int = 0
		for i in range(1, open_set.size()):
			var f: float = f_score.get(open_set[i], 1e9)
			if f < current_f:
				current = open_set[i]
				current_f = f
				best_idx = i
		open_set.remove_at(best_idx)
		explored += 1

		if current == end:
			var raw_path: Array[Vector2i] = _reconstruct_path(came_from, current)
			var smoothed: Array[Vector2] = _smooth_path(raw_path)
			print("[A*] ✅ 找到路径！探索=%d 迭代=%d 原始=%d 平滑后=%d" % [explored, iterations, raw_path.size(), smoothed.size()])
			if smoothed.size() > 0:
				print("[A*]   起点: (%.0f, %.0f)  终点: (%.0f, %.0f)" % [smoothed[0].x, smoothed[0].y, smoothed[smoothed.size()-1].x, smoothed[smoothed.size()-1].y])
			character._debug_path_found = true
			character._debug_astar_iters = iterations
			_first_path = false
			return smoothed

		for neighbor in _get_neighbors(current):
			var dx: int = neighbor.x - current.x
			var dy: int = neighbor.y - current.y
			var move_cost: float = 1.0 if dx == 0 or dy == 0 else 1.41421356
			var tent_g: float = g_score[current] + move_cost

			if tent_g < g_score.get(neighbor, 1e9):
				came_from[neighbor] = current
				g_score[neighbor] = tent_g
				f_score[neighbor] = tent_g + _heuristic(neighbor, end)
				if neighbor not in open_set:
					open_set.append(neighbor)

	print("[A*] ❌ 无路径！探索=%d 迭代=%d open_set剩余=%d" % [explored, iterations, open_set.size()])
	character._debug_path_found = false
	character._debug_astar_iters = iterations
	_first_path = false
	return []


func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while current in came_from:
		current = came_from[current]
		path.insert(0, current)
	return path


func _smooth_path(grid_path: Array[Vector2i]) -> Array[Vector2]:
	## 共线简化 → 转世界坐标 → 推离墙壁
	if grid_path.size() <= 2:
		return _push_from_walls(_to_world_array(grid_path))

	var world: Array[Vector2] = []
	world.append(_grid_to_world(grid_path[0]))

	for i in range(1, grid_path.size() - 1):
		var prev: Vector2i = grid_path[i - 1]
		var curr: Vector2i = grid_path[i]
		var next_: Vector2i = grid_path[i + 1]
		var d1: Vector2i = curr - prev
		var d2: Vector2i = next_ - curr
		if d1.x * d2.y != d1.y * d2.x:
			world.append(_grid_to_world(curr))

	world.append(_grid_to_world(grid_path[grid_path.size() - 1]))
	return _push_from_walls(world)


const WALL_PUSH: float = 14.0  ## 推离墙壁的像素距离（32格-24碰撞体=8, 需 >4 才有 clearance）

func _push_from_walls(world_path: Array[Vector2]) -> Array[Vector2]:
	## 将路径点从相邻墙壁推开，避免碰撞体擦边卡住
	var result: Array[Vector2] = []
	for wp in world_path:
		var gp: Vector2i = _world_to_grid(wp)
		var offset := Vector2.ZERO
		# 四方向邻居
		if not _is_tile_walkable(Vector2i(gp.x - 1, gp.y)):
			offset.x += WALL_PUSH
		if not _is_tile_walkable(Vector2i(gp.x + 1, gp.y)):
			offset.x -= WALL_PUSH
		if not _is_tile_walkable(Vector2i(gp.x, gp.y - 1)):
			offset.y += WALL_PUSH
		if not _is_tile_walkable(Vector2i(gp.x, gp.y + 1)):
			offset.y -= WALL_PUSH
		# 对角线邻居也检查（墙角最容易卡）
		if not _is_tile_walkable(Vector2i(gp.x - 1, gp.y - 1)):
			offset += Vector2(WALL_PUSH * 0.5, WALL_PUSH * 0.5)
		if not _is_tile_walkable(Vector2i(gp.x + 1, gp.y - 1)):
			offset += Vector2(-WALL_PUSH * 0.5, WALL_PUSH * 0.5)
		if not _is_tile_walkable(Vector2i(gp.x - 1, gp.y + 1)):
			offset += Vector2(WALL_PUSH * 0.5, -WALL_PUSH * 0.5)
		if not _is_tile_walkable(Vector2i(gp.x + 1, gp.y + 1)):
			offset += Vector2(-WALL_PUSH * 0.5, -WALL_PUSH * 0.5)
		result.append(wp + offset)
	return result


func _is_tile_walkable(gp: Vector2i) -> bool:
	## 仅查地图层（不含实体），用于确定墙壁位置
	if _tile_walk_cache.has(gp):
		return _tile_walk_cache[gp]
	# 按 _is_walkable 的地图层逻辑查一次
	var w := false
	for tm in _tilemaps:
		var td: TileData = tm.get_cell_tile_data(gp)
		if td == null:
			continue
		var nl := tm.name.to_lower()
		if "decor" in nl or "wall" in nl:
			w = false; break
		if "ground" in nl or "floor" in nl:
			w = true
	_tile_walk_cache[gp] = w
	return w


func _to_world_array(grid_path: Array[Vector2i]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for gp in grid_path:
		result.append(_grid_to_world(gp))
	return result


func _heuristic(a: Vector2i, b: Vector2i) -> float:
	var dx: int = absi(a.x - b.x)
	var dy: int = absi(a.y - b.y)
	return float(maxi(dx, dy)) + 0.41421356 * float(mini(dx, dy))


func _get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var n: Vector2i = Vector2i(pos.x + dx, pos.y + dy)
			if not _is_walkable(n):
				continue
			if dx != 0 and dy != 0:
				if not _is_walkable(Vector2i(pos.x + dx, pos.y)):
					continue
				if not _is_walkable(Vector2i(pos.x, pos.y + dy)):
					continue
			neighbors.append(n)
	return neighbors


func _find_nearest_walkable(pos: Vector2i) -> Vector2i:
	for r in range(1, 8):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n: Vector2i = Vector2i(pos.x + dx, pos.y + dy)
				if _is_walkable(n):
					return n
	return Vector2i(-999999, -999999)


# ═══════════════════════════════════════
# 网格工具
# ═══════════════════════════════════════

func _find_all_tilemaps() -> void:
	var tree: SceneTree = character.get_tree()
	if tree:
		_search_tilemaps(tree.root)

func _search_tilemaps(node: Node) -> void:
	if node is TileMapLayer:
		_tilemaps.append(node)
	for child in node.get_children():
		_search_tilemaps(child)


func _world_to_grid(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / _cell_size), floori(world.y / _cell_size))


func _grid_to_world(gp: Vector2i) -> Vector2:
	return Vector2(gp.x * _cell_size + _cell_size / 2.0, gp.y * _cell_size + _cell_size / 2.0)


func _is_walkable(gp: Vector2i) -> bool:
	## 综合判断：1.地图tile(缓存) 2.实体障碍(每帧实时，因敌人/玩家会移动)
	if _tile_walk_cache.has(gp):
		# 地图结果已缓存，只需实时查实体
		if not _tile_walk_cache[gp]:
			return false
		return not _is_cell_blocked_by_entity(gp)

	# 首次查询此格子 — 判断地图层
	var walkable: bool = false
	var found_layers: String = ""

	for tm in _tilemaps:
		var td: TileData = tm.get_cell_tile_data(gp)
		if td == null:
			continue
		var name_lower: String = tm.name.to_lower()
		found_layers += tm.name + ","
		if "decor" in name_lower or "wall" in name_lower:
			walkable = false
			break
		if "ground" in name_lower or "floor" in name_lower:
			walkable = true

	_tile_walk_cache[gp] = walkable  # 地图结果永久缓存

	# 地板格子还需实时查实体障碍
	if walkable and _is_cell_blocked_by_entity(gp):
		walkable = false

	if _tile_walk_cache.size() < 5:
		print("[A* DEBUG] 格子 %s → layers=[%s] → walkable=%s" % [str(gp), found_layers, str(walkable)])

	return walkable


# ═══════════════════════════════════════
# 实体障碍检测（敌人 + 多人玩家接口）
# ═══════════════════════════════════════

## 多人模式接口：外部注册的障碍节点（如其他玩家的 CharacterBody2D）
## 用法：enemy.get_node("StateMachine/Chase").extra_obstacle_nodes.append(other_player)
var extra_obstacle_nodes: Array[Node2D] = []


func _is_cell_blocked_by_entity(gp: Vector2i) -> bool:
	## 检查格子上是否有其他敌人或外部注册的障碍实体
	var world: Vector2 = _grid_to_world(gp)
	if not _space_state:
		_space_state = character.get_world_2d().direct_space_state

	# 用 intersect_point 检测敌人碰撞层（layer 4 = bit 8）
	var query: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	query.position = world
	query.collision_mask = 8  # layer 4 = enemy
	query.exclude = [character]
	var results: Array[Dictionary] = _space_state.intersect_point(query)
	if not results.is_empty():
		return true

	# 检查外部注册的障碍节点（多人模式玩家等）
	for node in extra_obstacle_nodes:
		if not is_instance_valid(node):
			continue
		var dist: float = world.distance_to(node.global_position)
		if dist < _cell_size * 0.8:  # 在格子范围内
			return true

	return false
