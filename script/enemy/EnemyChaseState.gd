class_name EnemyChaseState extends State
## 追击玩家 — A* 寻路（Godot 内置 AStarGrid2D）+ 调试输出 + 路径可视化
##
## 网格分辨率：32×32 像素（原生图块分辨率）
## 碰撞体感知：Decor/Upper 层通过图块中心点碰撞多边形检测判定阻挡
## 敌人互为障碍：寻路时将其他敌人格子临时标记为不可行走，避免互相穿过

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
static var _tile_walk_cache: Dictionary = {}  ## Vector2i → bool — 地图格子缓存（32×32 分辨率）
static var _cell_size: float = 32.0  ## 网格分辨率（原生图块大小）
static var _tilemaps: Array[TileMapLayer] = []  ## 缓存所有 TileMapLayer（所有敌人共享）
static var _astar_grid: AStarGrid2D = null  ## Godot 内置 A* 网格（静态，全图共享）
static var _grid_building: bool = false   ## 是否正在分帧构建网格
static var _grid_build_y: int = 0         ## 当前构建到的行
static var _grid_build_bounds: Rect2i = Rect2i()  ## 构建区域
static var _grid_build_frame: int = -1    ## 当前帧已处理过（防同帧重复）
static var _grid_build_solids: int = 0     ## 累计障碍物计数
var _collision_half: Vector2 = Vector2(12, 14)  ## 碰撞体半尺寸，用于推墙距离

const BUILD_CHUNK: int = 1500  ## 每帧最多处理的格子数

const REPATH_INTERVAL: float = 0.5          ## 正常重算间隔
const REPATH_FAIL_INTERVAL: float = 3.0     ## 寻路失败后重试间隔（避免卡顿）
const REPATH_FAIL_MOVE_DIST: float = 48.0   ## 失败后玩家移动多远才重试
const WAYPOINT_RADIUS: float = 10.0
const NO_PATH_STOP: int = 5       ## 连续无路径多少次后停止移动
const FALLBACK_THRESHOLD: int = 2  ## 连续失败多少次切到直接追击模式
const PUSH_APART_RADIUS: float = 36.0   ## 敌人推开检测半径
const PUSH_APART_FORCE: float = 220.0   ## 推开速度（像素/秒，强力分离）


func enter() -> void:
	character.update_moving(true)
# 注：enemy 使用 MOTION_MODE_FLOATING，up_direction 无需设置
	# 获取碰撞体半尺寸用于推墙计算
	var col_shape: CollisionShape2D = character.get_node_or_null("CollisionShape2D")
	if col_shape and col_shape.shape is RectangleShape2D:
		_collision_half = (col_shape.shape as RectangleShape2D).size * 0.5
	else:
		_collision_half = Vector2(12, 14)  # 默认 24×28
	_path = []
	_path_idx = 0
	_repath_timer = 0.0
	_no_path_count = 0
	_last_failed = false
	_last_player_pos = Vector2.ZERO
	_fallback_mode = false
	_first_path = true
	# 找到所有 TileMapLayer（static 缓存，只在首次进入时搜索并打印）
	if _tilemaps.is_empty() or not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_astar_grid = null  ## 失效 AStarGrid2D，触发重建
		_grid_building = false  ## 中断分帧构建
		_find_all_tilemaps()
		var names: String = ""
		for tm in _tilemaps:
			if not is_instance_valid(tm):
				continue
			names += tm.name + " "
		print("[A*] 找到 TileMapLayer (%d 个): [%s]" % [_tilemaps.size(), names.strip_edges()])
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
	character._debug_cell_size = _cell_size


func process_update(_delta: float) -> void:
	if character.guard_dead():
		return

	var enemy: Node2D = character
	if not enemy.has_valid_player_target():
		transition_requested.emit("Idle")
		return
	var player: Node2D = enemy._player_ref

	var fw: Vector2 = enemy.get_facing_vector()
	var rect_center: Vector2 = enemy.global_position + fw * enemy.attack_range_forward_offset
	var rel: Vector2 = player.global_position - rect_center
	var rt: Vector2 = Vector2(fw.y, -fw.x)
	if abs(rel.dot(rt)) <= enemy.attack_range.x / 2.0 and abs(rel.dot(fw)) <= enemy.attack_range.y / 2.0:
		transition_requested.emit("Attack")
		return


func physics_update(delta: float) -> void:
	_build_step()  ## 持续分帧构建 AStarGrid2D（如在构建中）

	var enemy: Node2D = character
	if not enemy.has_valid_player_target():
		character.velocity = Vector2.ZERO
		transition_requested.emit("Idle")
		return
	var player: Node2D = enemy._player_ref

	var to_player: Vector2 = player.global_position - enemy.global_position
	if to_player.length() < 1.0:
		return

	var speed: float = enemy.move_speed

	# ── 降级模式：连续失败2次 → 切到直接追击（避免A*卡顿）──
	if _fallback_mode:
		_repath_timer += delta
		if _repath_timer >= REPATH_FAIL_INTERVAL:
			_repath_timer = 0.0
			var player_moved: float = player.global_position.distance_to(_last_player_pos)
			if player_moved > REPATH_FAIL_MOVE_DIST:
				_fallback_mode = false
				_path = _find_path(enemy.global_position, player.global_position)
				_last_player_pos = player.global_position
				if not _path.is_empty():
					_path_idx = 1 if _path.size() > 1 else 0
					_last_failed = false
					enemy._debug_path = _path
					enemy._debug_path_idx = _path_idx
				else:
					_fallback_mode = true
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
				_fallback_mode = true
		else:
			_no_path_count = 0
		enemy._debug_path = _path
		enemy._debug_path_idx = _path_idx
		enemy._debug_walk_cache = _tile_walk_cache
		if Global.debug_visuals:
			enemy.queue_redraw()

	# ── 确定移动目标方向 ──
	if _path.is_empty():
		_move_direct(enemy, to_player, speed, delta)
		return

	_no_path_count = 0
	while _path_idx < _path.size():
		if enemy.global_position.distance_to(_path[_path_idx]) < 16.0:
			_path_idx += 1
		else:
			break

	var move_dir: Vector2
	if _path_idx >= _path.size():
		move_dir = to_player.normalized()
	else:
		move_dir = (_path[_path_idx] - enemy.global_position).normalized()


	character.update_facing_from_direction(move_dir)
	_move_with_stuck_recovery(character, move_dir, speed, delta)
	_push_apart_from_other_enemies(character, delta, move_dir)

# 移动工具
# ═══════════════════════════════════════

func _move_direct(enemy: Node2D, to_player: Vector2, speed: float, delta: float) -> void:
	var move_dir: Vector2 = to_player.normalized()
	character.update_facing_from_direction(move_dir)
	_move_with_stuck_recovery(character, move_dir, speed, delta)
	_push_apart_from_other_enemies(character, delta, move_dir)

const ENEMY_LAYER_BIT: int = 8  ## Layer 4 = 1<<3，敌人物理体所在层

func _move_with_stuck_recovery(body: CharacterBody2D, move_dir: Vector2, speed: float, delta: float) -> void:
	## 临时关闭敌人间硬碰撞 → 只撞墙不撞敌人，像以撒那样靠软推力分离
	var prev_pos := body.global_position
	# 移除敌人层碰撞 → move_and_collide 不会因敌人而停下
	var saved_mask := body.collision_mask
	body.collision_mask = saved_mask & ~ENEMY_LAYER_BIT

	var motion := move_dir * speed * delta
	for _i in range(6):
		var col := body.move_and_collide(motion)
		if not col:
			break
		# 只会撞到墙壁（敌人层已移除），正常滑墙
		motion = motion.slide(col.get_normal()).normalized() * speed * delta
		if motion.length() < 1.0:
			break

	# 恢复碰撞掩码
	body.collision_mask = saved_mask

	# 卡住检测
	if body.global_position.distance_to(prev_pos) < 1.5:
		for _i in range(3):
			body.move_and_collide(move_dir * speed * delta)
			if body.global_position.distance_to(prev_pos) > 1.5:
				break


func _push_apart_from_other_enemies(enemy: Node2D, delta: float, move_dir: Vector2 = Vector2.ZERO) -> void:
	## 自然推开挡路敌人：沿移动方向推开，而非盲目径向挤
	var tree: SceneTree = enemy.get_tree()
	if not tree:
		return

	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var my_pos: Vector2 = enemy.global_position
	var has_move_dir: bool = move_dir.length() > 0.3

	for other in enemies:
		if other == enemy:
			continue
		if not is_instance_valid(other):
			continue
		if other.get("_is_dead") == true:
			continue
		var sm: Node = other.get_node_or_null("StateMachine")
		if sm and sm.current_state:
			var sname: String = sm.current_state.name
			if sname == "Knockback" or sname == "Hitstun":
				continue

		var other_pos: Vector2 = other.global_position
		var dist: float = my_pos.distance_to(other_pos)
		if dist < PUSH_APART_RADIUS and dist > 0.01:
			var push_dir: Vector2
			if has_move_dir:
				var radial: Vector2 = (other_pos - my_pos).normalized()
				var side: Vector2 = Vector2(-move_dir.y, move_dir.x)
				var side_dot: float = radial.dot(side)
				push_dir = (move_dir * 0.75 + side * side_dot * 0.25).normalized()
			else:
				push_dir = (my_pos - other_pos).normalized()

			var push_strength: float = (1.0 - dist / PUSH_APART_RADIUS) * PUSH_APART_FORCE
			var motion: Vector2 = push_dir * push_strength * delta
			if other is CharacterBody2D:
				other.move_and_collide(motion)
			else:
				other.global_position += motion

			if has_move_dir:
				var self_push: Vector2 = move_dir * push_strength * 0.5 * delta
				enemy.move_and_collide(self_push)


# ═══════════════════════════════════════
# A* 寻路（Godot 内置 AStarGrid2D）
# ═══════════════════════════════════════

static func prebuild() -> void:
	## 场景加载后立即启动网格构建（由 GameInit 延迟调用）。
	## 避免首个敌人进入追击时才同步创建 AStarGrid2D（update() 为一次性同步开销，
	## 大图会卡一帧），把一次性成本前移到加载阶段。
	## _ensure_astar_grid 内部已处理：已就绪直接返回、场景切换后自动重新发现图块。
	_ensure_astar_grid()


static func tick_build() -> void:
	## 每物理帧驱动网格分帧构建（由 GameInit 调用）。
	## 敌人尚未追击时也能推进构建；闲置时仅一次布尔判断，开销可忽略。
	_build_step()


static func _ensure_astar_grid() -> bool:
	## 确保 AStarGrid2D 已构建。返回 true 表示就绪（立即可用）。
	## 如果尚未构建，启动分帧构建并返回 false（调用者应使用降级追击）。
	if _astar_grid and not _tilemaps.is_empty() and is_instance_valid(_tilemaps[0]):
		if _grid_building:
			return false  ## 构建中，尚未就绪
		return true

	# 正在构建中，不要重启
	if _grid_building:
		return false

	# 重新发现 tilemaps
	if _tilemaps.is_empty() or not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_find_all_tilemaps()

	if _tilemaps.is_empty():
		return false

	# 计算所有 tilemap 的合并边界
	var bounds: Rect2i = Rect2i()
	var first: bool = true
	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var rect: Rect2i = tm.get_used_rect()
		if first:
			bounds = rect
			first = false
		else:
			bounds = bounds.merge(rect)

	if first:
		return false

	var total_cells: int = bounds.size.x * bounds.size.y
	var est_frames: int = ceili(float(total_cells) / float(BUILD_CHUNK))
	print("[A*] 分帧构建 AStarGrid2D: region=%s cells=%d (约%d帧完成)" % [str(bounds), total_cells, est_frames])

	_astar_grid = AStarGrid2D.new()
	_astar_grid.region = bounds
	_astar_grid.cell_size = Vector2(_cell_size, _cell_size)
	_astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar_grid.update()

	# 启动分帧构建
	_grid_building = true
	_grid_build_y = bounds.position.y
	_grid_build_bounds = bounds
	_grid_build_frame = -1
	_grid_build_solids = 0

	return false  ## 构建中，稍后才就绪


static func _build_step() -> void:
	## 每帧处理 BUILD_CHUNK 个格子，分帧完成障碍物标记。
	## 可被多次调用，同帧内只执行一次。
	if not _grid_building or not _astar_grid:
		return

	var cf: int = Engine.get_physics_frames()
	if _grid_build_frame == cf:
		return  ## 本帧已处理过
	_grid_build_frame = cf

	var bounds: Rect2i = _grid_build_bounds
	var count: int = 0

	while _grid_build_y < bounds.position.y + bounds.size.y:
		for x in range(bounds.position.x, bounds.position.x + bounds.size.x):
			var gp := Vector2i(x, _grid_build_y)
			if not _is_walkable(gp):
				_astar_grid.set_point_solid(gp, true)
				_grid_build_solids += 1
			count += 1
			if count >= BUILD_CHUNK:
				return  ## 下帧继续
		_grid_build_y += 1

	# 构建完成
	_grid_building = false
	var total: int = bounds.size.x * bounds.size.y
	print("[A*] AStarGrid2D 构建完成: %d cells, 障碍物 %d (%.1f%%)" % [total, _grid_build_solids, float(_grid_build_solids) / float(total) * 100.0])


func _mark_enemy_obstacles() -> Array[Vector2i]:
	## 将其他敌人占用的格子临时标记为障碍物，返回被标记的格子列表
	var blocked: Array[Vector2i] = []
	if not _astar_grid:
		return blocked

	var tree: SceneTree = character.get_tree()
	if not tree:
		return blocked

	var enemies: Array[Node] = tree.get_nodes_in_group("enemy")
	var my_grid: Vector2i = _world_to_grid(character.global_position)

	for other in enemies:
		if other == character:
			continue
		if not is_instance_valid(other):
			continue
		if other.get("_is_dead") == true:
			continue

		var gp: Vector2i = _world_to_grid(other.global_position)
		if gp == my_grid:
			continue
		if not _astar_grid.region.has_point(gp):
			continue
		# 只标记当前可行走的格子（已经是墙的不用重复标记）
		if not _astar_grid.is_point_solid(gp):
			_astar_grid.set_point_solid(gp, true)
			blocked.append(gp)

	return blocked


func _clear_enemy_obstacles(cells: Array[Vector2i]) -> void:
	if not _astar_grid:
		return
	for gp in cells:
		if _astar_grid.region.has_point(gp):
			_astar_grid.set_point_solid(gp, false)


func _find_path(from: Vector2, to: Vector2) -> Array[Vector2]:
	var start: Vector2i = _world_to_grid(from)
	var end: Vector2i = _world_to_grid(to)
	var start_ok: bool = _is_walkable(start)
	var end_ok: bool = _is_walkable(end)

	character._debug_start_grid = start
	character._debug_end_grid = end
	character._debug_start_walkable = start_ok
	character._debug_end_walkable = end_ok

	if _first_path:
		print("[A*] ═══ 寻路开始（AStarGrid2D, %dpx 格子）═══" % int(_cell_size))
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

	# ── 确保 AStarGrid2D 已构建 ──
	if not _ensure_astar_grid():
		print("[A*] ❌ 无法构建寻路网格！")
		character._debug_path_found = false
		character._debug_astar_iters = 0
		_first_path = false
		return []

	# ── 标记其他敌人为临时障碍物 ──
	var blocked_cells: Array[Vector2i] = _mark_enemy_obstacles()

	# ── 使用 Godot 内置 AStarGrid2D 寻路 ──
	var id_path: PackedVector2Array = _astar_grid.get_id_path(start, end)

	# ── 清除临时障碍物 ──
	_clear_enemy_obstacles(blocked_cells)

	if id_path.is_empty():
		if Global.debug_visuals:
			print("[A*] ❌ 无路径！")
		character._debug_path_found = false
		character._debug_astar_iters = 0
		_first_path = false
		return []

	# 转换为 Array[Vector2i]（get_id_path 返回 PackedVector2Array，元素为浮点格子坐标）
	var grid_path: Array[Vector2i] = []
	for p: Vector2 in id_path:
		grid_path.append(Vector2i(int(p.x), int(p.y)))

	# 平滑路径（共线简化 + 碰撞体感知推墙）
	var smoothed: Array[Vector2] = _smooth_path(grid_path)

	if Global.debug_visuals:
		print("[A*] ✅ 找到路径！原始=%d 平滑后=%d" % [grid_path.size(), smoothed.size()])
		if smoothed.size() > 0:
			print("[A*]   起点: (%.0f, %.0f)  终点: (%.0f, %.0f)" % [smoothed[0].x, smoothed[0].y, smoothed[smoothed.size()-1].x, smoothed[smoothed.size()-1].y])

	character._debug_path_found = true
	character._debug_astar_iters = 0  ## AStarGrid2D 不暴露迭代数
	_first_path = false
	return smoothed


func _smooth_path(grid_path: Array[Vector2i]) -> Array[Vector2]:
	## 共线简化 → 转世界坐标 → 碰撞体感知推墙
	var world := _to_world_array(grid_path)
	if grid_path.size() <= 2:
		return _push_from_walls(world)

	var keypoints: Array[Vector2i] = [grid_path[0]]
	for i in range(1, grid_path.size() - 1):
		var prev: Vector2i = grid_path[i - 1]
		var curr: Vector2i = grid_path[i]
		var next_: Vector2i = grid_path[i + 1]
		if (curr - prev) != (next_ - curr):
			keypoints.append(curr)
	keypoints.append(grid_path[grid_path.size() - 1])

	world = _to_world_array(keypoints)
	return _push_from_walls(world)


func _push_from_walls(world_path: Array[Vector2]) -> Array[Vector2]:
	## 碰撞体感知推墙：按敌人碰撞体全尺寸推开，确保碰撞体不会被障碍物卡住
	##
	## 狭窄通道保护：如果格子在 2 面及以上有墙（如狭窄走廊），
	## 限制推力不超出格子中心到边界的距离（cell_half - margin），
	## 防止路径点被推出可行走格子。
	if world_path.is_empty():
		return world_path

	# 使用碰撞体全尺寸（而非半尺寸）+ 额外余量确保不卡
	var push_full_x := _collision_half.x + 6.0
	var push_full_y := _collision_half.y + 6.0
	var cell_half: float = _cell_size / 2.0
	var max_push: float = cell_half - 2.0  ## 格内最大推力（留 2px 边距）
	var result: Array[Vector2] = []

	for wp in world_path:
		var gp: Vector2i = _world_to_grid(wp)
		var push := Vector2.ZERO
		var wall_count: int = 0  ## 相邻墙体计数（仅计四正方向）
		# 检测相邻8格（包括对角线），确保斜角也不卡
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				var n: Vector2i = Vector2i(gp.x + dx, gp.y + dy)
				if not _is_walkable(n):
					var weight: float = 1.0 if dx == 0 or dy == 0 else 0.7  # 对角线权重稍低
					push.x -= dx * push_full_x * weight
					push.y -= dy * push_full_y * weight
					if dx == 0 or dy == 0:
						wall_count += 1  # 只计正方向墙

		# 狭窄通道保护：≥2 面正方向有墙 → 限制推力，防止推出格子
		if wall_count >= 2:
			push.x = clampf(push.x, -max_push, max_push)
			push.y = clampf(push.y, -max_push, max_push)

		result.append(wp + push)

	return result


# ═══════════════════════════════════════
# 网格工具
# ═══════════════════════════════════════

static func _find_all_tilemaps() -> void:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		_search_tilemaps((main_loop as SceneTree).root)

static func _search_tilemaps(node: Node) -> void:
	if node is TileMapLayer:
		_tilemaps.append(node)
	for child in node.get_children():
		_search_tilemaps(child)


func _world_to_grid(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / _cell_size), floori(world.y / _cell_size))


func _grid_to_world(gp: Vector2i) -> Vector2:
	return Vector2(gp.x * _cell_size + _cell_size / 2.0, gp.y * _cell_size + _cell_size / 2.0)


func _to_world_array(grid_path: Array[Vector2i]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for gp in grid_path:
		result.append(_grid_to_world(gp))
	return result


func _find_nearest_walkable(pos: Vector2i) -> Vector2i:
	for r in range(1, 8):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n: Vector2i = Vector2i(pos.x + dx, pos.y + dy)
				if _is_walkable(n):
					return n
	return Vector2i(-999999, -999999)


# ═══════════════════════════════════════
# 可行走性检测（32×32 原生图块 + 碰撞多边形中心检测）
# ═══════════════════════════════════════

static func _is_walkable(gp: Vector2i) -> bool:
	## 以实际图块碰撞体为准：Wall 层整块阻挡，Decor/Upper 按碰撞多边形判定
	##
	## 策略：
	## - Ground/Floor 图块存在 → 基础可行走
	## - Wall 层图块存在 → 强制阻挡
	## - Decor/Upper 有碰撞体 → 阻挡（墙体/柱子，含半格边缘变体）
	##   例外：狭窄通道豁免 — 如果该格被两面相对的墙夹在中间
	##   （上下是墙+左右是地面，或左右是墙+上下是地面），
	##   则判定为 autotile 边缘变体进入通道格 → 不阻挡，
	##   让敌人能通过 32px（1 格）宽的狭窄通道。
	if _tile_walk_cache.has(gp):
		return _tile_walk_cache[gp]

	# 检测静态缓存是否失效（场景重载后）
	if not _tilemaps.is_empty() and not is_instance_valid(_tilemaps[0]):
		_tilemaps.clear()
		_tile_walk_cache.clear()
		_astar_grid = null  ## 场景重载 → 失效网格
		_grid_building = false  ## 中断分帧构建
		_find_all_tilemaps()

	var has_ground: bool = false
	var has_wall_layer: bool = false
	var blocked_by_decor_collision: bool = false
	var found_layers: String = ""

	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var td: TileData = tm.get_cell_tile_data(gp)
		if td == null:
			continue
		var name_lower: String = tm.name.to_lower()
		found_layers += tm.name + ","

		if "wall" in name_lower:
			# Wall 层：无论碰撞多边形如何，整块 32×32 图块都阻挡
			has_wall_layer = true

		elif "upper" in name_lower or "decor" in name_lower:
			if _tile_has_collision(td):
				# 有碰撞体即阻挡（含半格边缘变体，避免敌人穿过墙边）
				blocked_by_decor_collision = true

		elif "ground" in name_lower or "floor" in name_lower:
			has_ground = true

	# 狭窄通道豁免：被两面相对的墙夹住 + 另两面是地面 → 不阻挡
	if blocked_by_decor_collision and has_ground:
		if _is_sandwiched_passage(gp):
			blocked_by_decor_collision = false

	# 最终判定：有地面 且 没有被墙体阻挡 → 可行走
	var walkable: bool = has_ground and not has_wall_layer and not blocked_by_decor_collision

	_tile_walk_cache[gp] = walkable

	if _tile_walk_cache.size() < 10:
		print("[A* DEBUG] 图块 %s → layers=[%s] → walkable=%s  ground=%s wall=%s decor_block=%s" % [str(gp), found_layers, str(walkable), str(has_ground), str(has_wall_layer), str(blocked_by_decor_collision)])

	return walkable


const ORIENT_NONE: int = 0
const ORIENT_HORIZONTAL: int = 1  ## 水平细条：宽度满、高度薄（上下墙漏进来的边）
const ORIENT_VERTICAL: int = 2    ## 垂直细条：高度满、宽度薄（左右墙漏出来的边）
const ORIENT_FULL: int = 3        ## 满格/整块/角落碰撞


static func _collision_orientation(gp: Vector2i) -> int:
	## 返回该格自身 decor/upper 碰撞体的方向分类，用于区分「通道漏边」与「薄墙本身」。
	var found: bool = false
	var minx := 1e9
	var maxx := -1e9
	var miny := 1e9
	var maxy := -1e9
	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var td: TileData = tm.get_cell_tile_data(gp)
		if td == null:
			continue
		var name_lower: String = tm.name.to_lower()
		if not ("upper" in name_lower or "decor" in name_lower):
			continue
		for pi in range(td.get_collision_polygons_count(0)):
			found = true
			for p in td.get_collision_polygon_points(0, pi):
				minx = minf(minx, p.x)
				maxx = maxf(maxx, p.x)
				miny = minf(miny, p.y)
				maxy = maxf(maxy, p.y)
	if not found:
		return ORIENT_NONE
	var w: float = maxx - minx
	var h: float = maxy - miny
	if w >= 28.0 and h >= 28.0:
		return ORIENT_FULL
	if w >= 28.0 and h < 20.0:
		return ORIENT_HORIZONTAL
	if h >= 28.0 and w < 20.0:
		return ORIENT_VERTICAL
	return ORIENT_FULL


static func _is_sandwiched_passage(gp: Vector2i) -> bool:
	## 检查 gp 是否处于"两面墙夹中间"的狭窄通道中（1 格宽通道豁免）。
	##
	## 关键：只有当该格自身碰撞体是「垂直于通道方向的细条」（autotile 边缘变体
	## 漏进通道格）时才豁免；若碰撞体是「沿通道方向的细条」（薄墙本身），则不豁免。
	## 例：上下是墙、左右是地面（水平通道）→ 该格碰撞体必须是"水平细条"（上下墙漏进来的边）；
	## 若该格碰撞体是"垂直细条"（如 x=25 的竖向薄墙），则是墙本身，保持阻挡。

	# 水平通道：上下被阻挡 + 左右是纯地面（有 ground 且 无 blocking）
	var top_blocked: bool = _cell_has_blocking_tile(gp + Vector2i(0, -1))
	var bottom_blocked: bool = _cell_has_blocking_tile(gp + Vector2i(0, 1))
	var left_clear: bool = _cell_has_ground_tile(gp + Vector2i(-1, 0)) and not _cell_has_blocking_tile(gp + Vector2i(-1, 0))
	var right_clear: bool = _cell_has_ground_tile(gp + Vector2i(1, 0)) and not _cell_has_blocking_tile(gp + Vector2i(1, 0))

	# 垂直通道：左右被阻挡 + 上下是纯地面
	var left_blocked: bool = _cell_has_blocking_tile(gp + Vector2i(-1, 0))
	var right_blocked: bool = _cell_has_blocking_tile(gp + Vector2i(1, 0))
	var top_clear: bool = _cell_has_ground_tile(gp + Vector2i(0, -1)) and not _cell_has_blocking_tile(gp + Vector2i(0, -1))
	var bottom_clear: bool = _cell_has_ground_tile(gp + Vector2i(0, 1)) and not _cell_has_blocking_tile(gp + Vector2i(0, 1))

	var orient: int = _collision_orientation(gp)

	# 水平通道：上下墙夹 → 该格碰撞体应为水平细条（上下墙漏进来的边）
	if top_blocked and bottom_blocked and left_clear and right_clear and orient == ORIENT_HORIZONTAL:
		return true

	# 垂直通道：左右墙夹 → 该格碰撞体应为垂直细条（左右墙漏出来的边）
	if left_blocked and right_blocked and top_clear and bottom_clear and orient == ORIENT_VERTICAL:
		return true

	return false


static func _cell_has_blocking_tile(at: Vector2i) -> bool:
	## 检查某格是否有 wall 层图块 或 decor/upper 层碰撞图块（中心在内）
	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var td: TileData = tm.get_cell_tile_data(at)
		if td == null:
			continue
		var name_lower: String = tm.name.to_lower()
		if "wall" in name_lower:
			return true
		if ("upper" in name_lower or "decor" in name_lower) and _tile_has_collision(td):
			return true
	return false


static func _cell_has_ground_tile(at: Vector2i) -> bool:
	## 检查某格是否有 ground/floor 层图块
	for tm in _tilemaps:
		if not is_instance_valid(tm):
			continue
		var name_lower: String = tm.name.to_lower()
		if "ground" in name_lower or "floor" in name_lower:
			if tm.get_cell_tile_data(at) != null:
				return true
	return false


static func _tile_has_collision(td: TileData) -> bool:
	return td.get_collision_polygons_count(0) > 0
