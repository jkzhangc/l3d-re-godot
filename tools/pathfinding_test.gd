extends Node2D
## 敌人寻路（EnemyChaseState）验证 harness —— headless 运行。
##
## 运行：
##   godot --headless --path <项目> res://tools/pathfinding_test.tscn
##
## 【为什么能脱离真实地图跑】
## `EnemyChaseState._is_walkable()` 的第一件事是查静态缓存 `_tile_walk_cache`，
## 命中就直接返回。harness 因此可以：
##   1. 直接填一份合成的可行走网格（不依赖图块素材与 TileSet）；
##   2. 手工建一个与之同构的 AStarGrid2D 塞进静态字段；
##   3. 放一个只有"存在性"意义的空 TileMapLayer 让 `_ensure_astar_grid()` 通过。
## 这样就能在无渲染、无地图资源的环境里验证寻路算法本身。
##
## 【2026-09-10 三次修订新增的回归项】
##   · 平滑后的路径**每一段**都必须"碰撞体全程可通过"（用真实 TileSet 夹具验证）；
##   · 航点必须落在其格的立足点上（旧实现会把航点从格心推开，实测推到贴墙甚至出通道）；
##   · 进度式卡住判定：原地振荡必须被累计，持续靠近（哪怕很慢）必须不累计。
##
## 【合成地图布局】24×20 格
##   · x=10、y=0..9 是一道竖墙（用于视野/绕行用例）
##   · y=12..19 是开阔区（用于"被包围"与"斜线简化"用例）
##
## 后段 `_test_body_fit_walkability` 不走上面的桩，而是运行时拼一个真实 TileSet
## （地面 / 满格墙 / 漏边薄条）来驱动 `_is_walkable`，覆盖一格宽通道与未知图层。

const ENEMY_SCENE := preload("res://object/enemy.tscn")
const CHASE_SCRIPT := preload("res://script/enemy/EnemyChaseState.gd")

const CELL: int = 32
const GW: int = 24
const GH: int = 20
const WALL_X: int = 10
const WALL_Y_MAX: int = 9

## 被包围用例：玩家与其四个正交邻居
const PLAYER_CELL := Vector2i(14, 16)
const CHASER_CELL := Vector2i(4, 16)
const NEIGHBOR_CELLS: Array[Vector2i] = [
	Vector2i(13, 16), Vector2i(15, 16), Vector2i(14, 15), Vector2i(14, 17),
]
## 远侧同伴：距玩家 6 格（超出豁免半径 96px）、距追击者 4 格（在标记半径 288px 内）
const FAR_CELL := Vector2i(8, 16)

var _walk: Dictionary = {}
var _grid: AStarGrid2D
var _layer: TileMapLayer
var _enemy: CharacterBody2D
var _state: State
var _others: Array[Node2D] = []

var _checks: int = 0
var _failures: int = 0


func _ready() -> void:
	print("=== 敌人寻路验证（EnemyChaseState）===")
	_build_walk_map()
	_build_astar_grid()
	_build_scene()
	_run_tests()
	print("=== PATHFINDING_TEST: %d/%d checks passed ===" % [_checks - _failures, _checks])
	get_tree().quit(1 if _failures > 0 else 0)


# ═══════════════════════════════════════
# 场景装配
# ═══════════════════════════════════════

func _in_bounds(gp: Vector2i) -> bool:
	return gp.x >= 0 and gp.y >= 0 and gp.x < GW and gp.y < GH


func _is_open(gp: Vector2i) -> bool:
	if not _in_bounds(gp):
		return false
	if gp.x == WALL_X and gp.y <= WALL_Y_MAX:
		return false
	return true


func _cell_center(gp: Vector2i) -> Vector2:
	return Vector2(gp.x * CELL + CELL * 0.5, gp.y * CELL + CELL * 0.5)


func _build_walk_map() -> void:
	for x in range(GW):
		for y in range(GH):
			var gp := Vector2i(x, y)
			_walk[gp] = _is_open(gp)


func _build_astar_grid() -> void:
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(0, 0, GW, GH)
	_grid.cell_size = Vector2(CELL, CELL)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_grid.update()
	for x in range(GW):
		for y in range(GH):
			var gp := Vector2i(x, y)
			if not _is_open(gp):
				_grid.set_point_solid(gp, true)


func _build_scene() -> void:
	# 1) 占位 TileMapLayer —— 只用于让 _ensure_astar_grid() 认为"地图存在"
	_layer = TileMapLayer.new()
	_layer.name = "GroundLayer"
	add_child(_layer)

	# 2) 注入静态寻路状态（合成网格 + 预建 A*）
	var tms: Array[TileMapLayer] = [_layer]
	CHASE_SCRIPT._tilemaps = tms
	CHASE_SCRIPT._tile_walk_cache = _walk
	CHASE_SCRIPT._astar_grid = _grid
	CHASE_SCRIPT._grid_building = false

	# 3) 追击者实体（enemy.tscn，关闭自身状态机与 _process 以免干扰）
	_enemy = ENEMY_SCENE.instantiate() as CharacterBody2D
	add_child(_enemy)
	_enemy.global_position = _cell_center(CHASER_CELL)
	_enemy.set_process(false)
	var sm: Node = _enemy.get_node_or_null("StateMachine")
	if sm:
		sm.set_process(false)
		sm.set_physics_process(false)

	# 4) 追击状态（手动构造，不入树）
	_state = CHASE_SCRIPT.new() as State
	_state.character = _enemy
	_state.enter()

	# 5) 其余同伴
	for gp in NEIGHBOR_CELLS:
		_spawn_standin(gp)
	_spawn_standin(FAR_CELL)


func _spawn_standin(gp: Vector2i) -> void:
	var n := Node2D.new()
	n.global_position = _cell_center(gp)
	add_child(n)
	n.add_to_group("enemy")
	_others.append(n)


func _player_world() -> Vector2:
	return _cell_center(PLAYER_CELL)


# ═══════════════════════════════════════
# 用例
# ═══════════════════════════════════════

func _run_tests() -> void:
	_test_line_of_sight()
	_test_pull_string()
	_test_smooth_path_reduces_waypoints()
	_test_smooth_path_keeps_detour()
	_test_soft_cost_marking()
	_test_soft_cost_restored_after_find_path()
	_test_surrounded_player_reachable()
	_test_body_fit_walkability()
	_test_narrow_passage_followable()
	_test_no_push_off_center()
	_test_stuck_progress_detection()


func _test_line_of_sight() -> void:
	# 横穿竖墙 → 不通视
	_check(not _state._has_line_of_sight(_cell_center(Vector2i(6, 5)), _cell_center(Vector2i(14, 5))),
		"视线横穿墙体 → 判定为不可直达")
	# 开阔区横向 / 纵向 → 通视
	_check(_state._has_line_of_sight(_cell_center(Vector2i(2, 5)), _cell_center(Vector2i(8, 5))),
		"开阔区横向 → 判定为可直达")
	_check(_state._has_line_of_sight(_cell_center(Vector2i(2, 1)), _cell_center(Vector2i(2, 9))),
		"开阔区纵向 → 判定为可直达")
	# 擦着墙角斜穿 → 碰撞体跨格，应判为不可直达（不允许切角）
	_check(not _state._has_line_of_sight(_cell_center(Vector2i(9, 9)), _cell_center(Vector2i(11, 11))),
		"斜穿墙角（碰撞体跨 4 格）→ 判定为不可直达")


func _test_pull_string() -> void:
	var staircase: Array[Vector2] = []
	for i in range(1, 9):
		staircase.append(_cell_center(Vector2i(i, i)))
	var pulled: Array[Vector2] = _state._pull_string(staircase)
	_check(pulled.size() == 2, "开阔区斜向阶梯 8 点 → 视线简化到 2 点（实际 %d）" % pulled.size())
	if pulled.size() == 2:
		_check(pulled[0].is_equal_approx(staircase[0]) and pulled[1].is_equal_approx(staircase[7]),
			"简化后保留首尾端点")


func _test_smooth_path_reduces_waypoints() -> void:
	# 开阔区从 (1,12) 走到 (12,19) 的阶梯格路径
	var grid_path: Array[Vector2i] = []
	var cur := Vector2i(1, 12)
	grid_path.append(cur)
	while cur != Vector2i(12, 19):
		if cur.x < 12:
			cur.x += 1
		elif cur.y < 19:
			cur.y += 1
		grid_path.append(cur)
	var smoothed: Array[Vector2] = _state._smooth_path(grid_path)
	_check(smoothed.size() < grid_path.size(),
		"开阔区阶梯路径被简化（%d 格 → %d 航点）" % [grid_path.size(), smoothed.size()])
	_check(smoothed.size() == 2,
		"开阔区斜线全程可直达 → 只留起点+终点（实际 %d）" % smoothed.size())


func _test_smooth_path_keeps_detour() -> void:
	# 绕过竖墙的路径：下 → 右 → 上
	var grid_path: Array[Vector2i] = []
	for y in range(5, 11):
		grid_path.append(Vector2i(6, y))
	for x in range(7, 15):
		grid_path.append(Vector2i(x, 10))
	for y in range(9, 4, -1):
		grid_path.append(Vector2i(14, y))
	var smoothed: Array[Vector2] = _state._smooth_path(grid_path)
	_check(smoothed.size() >= 3,
		"绕墙路径未被简化成直线（保留 %d 个航点）" % smoothed.size())
	var crosses_wall := false
	for i in range(smoothed.size() - 1):
		if _segment_crosses_wall(smoothed[i], smoothed[i + 1]):
			crosses_wall = true
	_check(not crosses_wall, "简化后没有任何一段横穿墙体")
	var all_walkable := true
	for wp in smoothed:
		var gp := Vector2i(int(floor(wp.x / CELL)), int(floor(wp.y / CELL)))
		if not _is_open(gp):
			all_walkable = false
	_check(all_walkable, "简化后所有航点都落在可行走格内")


func _segment_crosses_wall(a: Vector2, b: Vector2) -> bool:
	var steps: int = maxi(1, ceili(a.distance_to(b) / 4.0))
	for i in range(steps + 1):
		var p: Vector2 = a.lerp(b, float(i) / float(steps))
		var gp := Vector2i(int(floor(p.x / CELL)), int(floor(p.y / CELL)))
		if not _is_open(gp):
			return true
	return false


func _test_soft_cost_marking() -> void:
	var touched: Array[Vector2i] = _state._mark_enemy_soft_costs(_player_world())
	var near_touched := 0
	for gp in NEIGHBOR_CELLS:
		if touched.has(gp):
			near_touched += 1
	_check(near_touched == 0, "玩家周围的 4 个同伴完全不被标记（实际 %d 个被标记）" % near_touched)
	_check(touched.has(FAR_CELL), "远离玩家的同伴被标记为软代价")
	_check(not touched.has(PLAYER_CELL), "玩家所在格永不被标记")
	_check(is_equal_approx(_grid.get_point_weight_scale(FAR_CELL), CHASE_SCRIPT.ENEMY_SOFT_COST),
		"被标记格代价提升到 ENEMY_SOFT_COST")
	var any_solid := false
	for gp in NEIGHBOR_CELLS + [FAR_CELL, PLAYER_CELL]:
		if _grid.is_point_solid(gp):
			any_solid = true
	_check(not any_solid, "同伴格子没有被写成硬障碍（is_point_solid 全为 false）")
	_state._clear_enemy_soft_costs(touched)
	var residue := 0
	for gp in touched:
		if not is_equal_approx(_grid.get_point_weight_scale(gp), CHASE_SCRIPT.DEFAULT_POINT_COST):
			residue += 1
	_check(residue == 0, "软代价被完整还原（残余 %d 格）" % residue)


func _test_soft_cost_restored_after_find_path() -> void:
	var path: Array[Vector2] = _state._find_path(_enemy.global_position, _player_world())
	_check(path.size() >= 2, "包围场景下 _find_path 返回有效路径（%d 航点）" % path.size())
	var residue := 0
	for gp in NEIGHBOR_CELLS + [FAR_CELL]:
		if not is_equal_approx(_grid.get_point_weight_scale(gp), CHASE_SCRIPT.DEFAULT_POINT_COST):
			residue += 1
	_check(residue == 0, "_find_path 结束后没有软代价残余（残余 %d 格）" % residue)


func _test_surrounded_player_reachable() -> void:
	# 反证：把四个邻居按旧实现写成硬障碍 → 目标格不可达
	for gp in NEIGHBOR_CELLS:
		_grid.set_point_solid(gp, true)
	var blocked_path: Array[Vector2] = _state._find_path(_enemy.global_position, _player_world())
	_check(blocked_path.is_empty(),
		"反证：邻居被写成硬障碍时路径为空（复现原缺陷，实际 %d 航点）" % blocked_path.size())
	for gp in NEIGHBOR_CELLS:
		_grid.set_point_solid(gp, false)
	var ok_path: Array[Vector2] = _state._find_path(_enemy.global_position, _player_world())
	_check(ok_path.size() >= 2,
		"修复后：同样被 4 个同伴围住仍能找到路径（%d 航点）" % ok_path.size())


# ═══════════════════════════════════════
# 可行走性 / 窄通道 —— 用真实 TileSet 驱动（不走上面的 _walk 桩）
# ═══════════════════════════════════════
## 旧规则是「该格任一图块带碰撞多边形 → 整格不可行走」。对一格宽的通道，
## 自动图块会把墙边的一条薄碰撞条带漏进通道格，于是整格被判死 —— 敌人明明过得去，
## 寻路却认为走不通。这里在运行时拼一个最小 TileSet：
##   0 = 纯地面 / 1 = 满格墙 / 2 = 左边缘 8px 薄条（模拟漏边）/ 3 = 右边缘薄条
## 地形是「两格厚横墙上只留一格宽门洞」。验证四件事：
##   ① 门洞判为可行走，且立足点被推到没有漏边的一侧；
##   ② 满格墙 / 无地面空区 / 未知层名 / wall 层名 仍判为不可行走；
##   ③ 端到端：真实 A* 路径确实取道门洞；
##   ④ 路径没有任何一段穿过不可行走格，且所有航点都站得下。

const FX_W: int = 20
const FX_H: int = 20
const FX_WALL_ROW_A: int = 8
const FX_WALL_ROW_B: int = 9
const FX_GAP_X: int = 10
const FX_LEAK_PX: float = 8.0
const FX_ABOVE := Vector2i(10, 2)
const FX_BELOW := Vector2i(10, 16)
const FX_DOOR_CELL := Vector2i(3, 15)
const FX_WALLNAME_CELL := Vector2i(6, 15)


func _fx_center(gp: Vector2i) -> Vector2:
	return Vector2(float(gp.x) * CELL + CELL * 0.5, float(gp.y) * CELL + CELL * 0.5)


func _fx_set_poly(src: TileSetAtlasSource, coords: Vector2i, pts: PackedVector2Array) -> void:
	var td: TileData = src.get_tile_data(coords, 0)
	td.add_collision_polygon(0)
	td.set_collision_polygon_points(0, 0, pts)


func _fx_make_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	ts.add_physics_layer(0)
	var img := Image.create_empty(CELL * 4, CELL, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(CELL, CELL)
	for i in range(4):
		src.create_tile(Vector2i(i, 0))
	ts.add_source(src, 0)
	## ⚠ 坐标以**格心**为原点（与 Godot 图块碰撞多边形的实际存储方式一致）：
	## 整格矩形是 -16..16，左侧 8px 薄条是 -16..-8。按左上角写会让夹具与真实地图不符。
	var h: float = CELL * 0.5
	_fx_set_poly(src, Vector2i(1, 0),
		PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)]))
	_fx_set_poly(src, Vector2i(2, 0),
		PackedVector2Array([Vector2(-h, -h), Vector2(-h + FX_LEAK_PX, -h), Vector2(-h + FX_LEAK_PX, h), Vector2(-h, h)]))
	_fx_set_poly(src, Vector2i(3, 0),
		PackedVector2Array([Vector2(h - FX_LEAK_PX, -h), Vector2(h, -h), Vector2(h, h), Vector2(h - FX_LEAK_PX, h)]))
	return ts


func _fx_build_layers(with_leak: bool = true) -> Array[TileMapLayer]:
	var ts := _fx_make_tileset()

	var ground := TileMapLayer.new()
	ground.name = "GroundLayer"
	ground.tile_set = ts
	add_child(ground, true)  ## force_readable_name：名字必须可读，图层角色靠它判定
	for x in range(FX_W):
		for y in range(FX_H):
			ground.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	for x in range(FX_W):
		if x == FX_GAP_X:
			continue
		ground.set_cell(Vector2i(x, FX_WALL_ROW_A), 0, Vector2i(1, 0))
		ground.set_cell(Vector2i(x, FX_WALL_ROW_B), 0, Vector2i(1, 0))
	if with_leak:
		# 门洞两格：假想的"自动图块把左侧墙面一条薄边漏进通道格"
		ground.set_cell(Vector2i(FX_GAP_X, FX_WALL_ROW_A), 0, Vector2i(2, 0))
		ground.set_cell(Vector2i(FX_GAP_X, FX_WALL_ROW_B), 0, Vector2i(2, 0))
	else:
		# 无漏边：门洞两格就是普通地面 —— 这才是本工程实际的全格碰撞地形
		ground.set_cell(Vector2i(FX_GAP_X, FX_WALL_ROW_A), 0, Vector2i(0, 0))
		ground.set_cell(Vector2i(FX_GAP_X, FX_WALL_ROW_B), 0, Vector2i(0, 0))

	var door := TileMapLayer.new()
	door.name = "铁门"   ## 未知层名：旧实现完全忽略它
	door.tile_set = ts
	add_child(door, true)  ## force_readable_name：名字必须可读，图层角色靠它判定
	door.set_cell(FX_DOOR_CELL, 0, Vector2i(1, 0))

	var wall_named := TileMapLayer.new()
	wall_named.name = "WallLayer"   ## 名字含 wall：即使图块无碰撞也整格阻挡
	wall_named.tile_set = ts
	add_child(wall_named, true)  ## force_readable_name：名字必须可读，图层角色靠它判定
	wall_named.set_cell(FX_WALLNAME_CELL, 0, Vector2i(0, 0))

	var layers: Array[TileMapLayer] = [ground, door, wall_named]
	return layers


func _fx_build_grid() -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, FX_W, FX_H)
	grid.cell_size = Vector2(CELL, CELL)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for x in range(FX_W):
		for y in range(FX_H):
			var gp := Vector2i(x, y)
			if not CHASE_SCRIPT._is_walkable(gp):
				grid.set_point_solid(gp, true)
	return grid


func _test_body_fit_walkability() -> void:
	var saved_layers: Array[TileMapLayer] = CHASE_SCRIPT._tilemaps
	var saved_walk: Dictionary = CHASE_SCRIPT._tile_walk_cache
	var saved_stand: Dictionary = CHASE_SCRIPT._stand_cache
	var saved_grid: AStarGrid2D = CHASE_SCRIPT._astar_grid
	var saved_building: bool = CHASE_SCRIPT._grid_building

	# 先释放 _build_scene() 里的占位 GroundLayer：否则同名冲突会让 Godot 把新图层
	# 自动改名为 "@TileMapLayer@N"，图层角色（按名字子串判定）立刻失效。
	if is_instance_valid(_layer):
		remove_child(_layer)
		_layer.free()

	CHASE_SCRIPT._tilemaps = _fx_build_layers()
	CHASE_SCRIPT._tile_walk_cache = {}
	CHASE_SCRIPT._stand_cache = {}
	CHASE_SCRIPT._astar_grid = null
	CHASE_SCRIPT._grid_building = false

	var gap_cell := Vector2i(FX_GAP_X, FX_WALL_ROW_A)
	var gap_center := _fx_center(gap_cell)
	var mid: float = CELL * 0.5

	# ① 基础分类仍然正确
	_check(not CHASE_SCRIPT._is_walkable(Vector2i(5, FX_WALL_ROW_A)), "满格墙 → 不可行走")
	_check(not CHASE_SCRIPT._is_walkable(Vector2i(90, 90)), "无地面图块的空区 → 不可行走")
	_check(CHASE_SCRIPT._is_walkable(Vector2i(5, 2)), "普通地面 → 可行走")

	# ② 反证：门洞格的几何中心确实站不下 —— 旧实现正是在这里把整格判死
	_check(CHASE_SCRIPT._body_blocked_at(gap_center),
		"反证：1 格宽门洞的格心站不下（旧实现据此整格判死）")

	# ③ 新判定：门洞可行走，且立足点被推到没有漏边的一侧
	_check(CHASE_SCRIPT._is_walkable(gap_cell), "1 格宽门洞（左侧 8px 漏边）→ 可行走")
	var stand: Vector2 = CHASE_SCRIPT._stand_center(gap_cell)
	var half_x: float = CHASE_SCRIPT._body_half.x - CHASE_SCRIPT.BODY_CLEARANCE
	_check(stand.x - half_x >= FX_LEAK_PX - 0.01 and stand.x > mid,
		"门洞立足点让开漏边：碰撞体左缘 %.1f ≥ 漏边 %.1f（立足点 x=%.1f）" % [
			stand.x - half_x, FX_LEAK_PX, stand.x])

	# ④ 未知层名 / wall 层名
	_check(not CHASE_SCRIPT._is_walkable(FX_DOOR_CELL),
		"未知名图层（铁门）带碰撞图块 → 阻挡（旧实现完全忽略它）")
	_check(not CHASE_SCRIPT._is_walkable(FX_WALLNAME_CELL),
		"名字含 wall 的图层即使图块无碰撞 → 整格阻挡")

	# ⑤ 端到端：真实网格 + 真实路径
	CHASE_SCRIPT._astar_grid = _fx_build_grid()
	var path: Array[Vector2] = _state._find_path(_fx_center(FX_ABOVE), _fx_center(FX_BELOW))
	_check(path.size() >= 2, "横穿 1 格宽门洞能找到路径（%d 航点）" % path.size())

	var uses_gap := false
	for i in range(path.size() - 1):
		for gp in _state._segment_cells(path[i], path[i + 1]):
			if gp == gap_cell:
				uses_gap = true
	_check(uses_gap, "路径的格子序列经过门洞格 —— 确实取道门洞（而非绕开或穿墙）")

	var all_fit := true
	for wp in path:
		if not _state._body_fits_at(wp):
			all_fit = false
	_check(all_fit, "所有航点都站得下（碰撞体在航点上不与任何图块碰撞）")

	## ⚠ 本夹具的门洞带 **8px 半格漏边**（一个假想形状，本工程实际不存在 ——
	## tres/*_tileset.tres 里所有碰撞多边形都是整格矩形）。半格碰撞下
	## "每格一个立足点"的模型无法保证整条路径可跟随：进入通道前的那一段仍走在格心线上，
	## 会蹭到漏边。这是已知限制，不在此处断言。
	## 全格碰撞（本工程的实际形状）的可跟随性由 _test_narrow_passage_followable() 覆盖。

	var crosses := false
	for i in range(path.size() - 1):
		if not _state._segment_cells_walkable(path[i], path[i + 1]):
			crosses = true
	_check(not crosses, "路径没有任何一段穿过不可行走格")

	# 还原静态状态，避免影响其他用例
	CHASE_SCRIPT._tilemaps = saved_layers
	CHASE_SCRIPT._tile_walk_cache = saved_walk
	CHASE_SCRIPT._stand_cache = saved_stand
	CHASE_SCRIPT._astar_grid = saved_grid
	CHASE_SCRIPT._grid_building = saved_building


# ═══════════════════════════════════════
# 三次修订的回归项
# ═══════════════════════════════════════

func _test_narrow_passage_followable() -> void:
	## 复刻第二关学校内部那类地形：**全格碰撞的墙 + 一格宽通道**。
	## 旧实现的"推墙"会把通道格的航点横向推出通道 14px（实测），于是
	##   ① 路径线穿过墙体（用户报的"路径线穿墙"）；
	##   ② 敌人朝通道外的航点走 → 沿墙前后 2.67px 振荡、永远过不去（"挤墙/拐不了弯"）。
	## 这里把它钉成回归项：平滑后的每一段都必须可跟随，且航点落在通道中线上。
	var saved_layers: Array[TileMapLayer] = CHASE_SCRIPT._tilemaps
	var saved_walk: Dictionary = CHASE_SCRIPT._tile_walk_cache
	var saved_stand: Dictionary = CHASE_SCRIPT._stand_cache
	var saved_rects: Dictionary = CHASE_SCRIPT._cell_rect_cache
	var saved_grid: AStarGrid2D = CHASE_SCRIPT._astar_grid
	var saved_building: bool = CHASE_SCRIPT._grid_building
	var saved_body: Vector2 = CHASE_SCRIPT._body_half

	if is_instance_valid(_layer):
		remove_child(_layer)
		_layer.free()

	CHASE_SCRIPT._tilemaps = _fx_build_layers(false)
	CHASE_SCRIPT._tile_walk_cache = {}
	CHASE_SCRIPT._stand_cache = {}
	CHASE_SCRIPT._cell_rect_cache = {}
	CHASE_SCRIPT._astar_grid = null
	CHASE_SCRIPT._grid_building = false
	## 用敌人的真实碰撞体尺寸（20×28 → 半 10/14），否则这条用例测的不是真实几何
	CHASE_SCRIPT._body_half = Vector2(10.0, 14.0)

	var gap_cell := Vector2i(FX_GAP_X, FX_WALL_ROW_A)
	_check(CHASE_SCRIPT._is_walkable(gap_cell), "全格碰撞下，一格宽通道判为可行走")
	_check(CHASE_SCRIPT._stand_center(gap_cell).distance_to(Vector2(16.0, 16.0)) < 0.01,
		"全格碰撞下通道格立足点就是格心（格内离墙最远）")

	CHASE_SCRIPT._astar_grid = _fx_build_grid()
	var path: Array[Vector2] = _state._find_path(_fx_center(FX_ABOVE), _fx_center(FX_BELOW))
	_check(path.size() >= 2, "横穿一格宽通道能找到路径（%d 航点）" % path.size())

	var seg_bad := 0
	var worst_seg := ""
	for i in range(path.size() - 1):
		if not CHASE_SCRIPT._segment_followable(path[i], path[i + 1]):
			seg_bad += 1
			if worst_seg == "":
				worst_seg = "#%d (%.1f,%.1f)→(%.1f,%.1f)" % [
					i, path[i].x, path[i].y, path[i + 1].x, path[i + 1].y]
	_check(seg_bad == 0,
		"通道地形下每一段都可跟随（不可跟随 %d 段 首个=%s）" % [seg_bad, worst_seg])

	var off_center := 0
	for wp in path:
		var gp := Vector2i(floori(wp.x / float(CELL)), floori(wp.y / float(CELL)))
		var expect: Vector2 = _fx_center(gp)
		if wp.distance_to(expect) > 0.01:
			off_center += 1
	_check(off_center == 0, "航点没有被推离格心（偏离格心的航点 %d 个）" % off_center)

	# 还原
	CHASE_SCRIPT._tilemaps = saved_layers
	CHASE_SCRIPT._tile_walk_cache = saved_walk
	CHASE_SCRIPT._stand_cache = saved_stand
	CHASE_SCRIPT._cell_rect_cache = saved_rects
	CHASE_SCRIPT._astar_grid = saved_grid
	CHASE_SCRIPT._grid_building = saved_building
	CHASE_SCRIPT._body_half = saved_body

func _test_no_push_off_center() -> void:
	## 回归：平滑不得把航点推离它所属格的立足点。
	## 旧实现会把航点从格心推开最多 half+6（实测在一格宽通道里横推 14px），
	## 后果是路径线出通道、敌人贴着墙来回磨。立足点才是格内离墙最远的位置。
	var grid: Array[Vector2i] = []
	var cur := Vector2i(2, 16)
	grid.append(cur)
	while cur != Vector2i(16, 16):
		cur.x += 1
		grid.append(cur)
	while cur != Vector2i(16, 19):
		cur.y += 1
		grid.append(cur)
	var smoothed: Array[Vector2] = _state._smooth_path(grid)
	var worst := 0.0
	var worst_wp := Vector2.ZERO
	for wp in smoothed:
		var gp := Vector2i(int(floor(wp.x / CELL)), int(floor(wp.y / CELL)))
		var stand: Vector2 = CHASE_SCRIPT._stand_center(gp)
		var mid: Vector2 = Vector2(CELL, CELL) * 0.5
		var expect: Vector2 = Vector2(float(gp.x) * CELL, float(gp.y) * CELL) + (mid if stand.x < -1e8 else stand)
		var d: float = wp.distance_to(expect)
		if d > worst:
			worst = d
			worst_wp = wp
	_check(worst <= 0.01,
		"航点都落在其格立足点上（最大偏离 %.2fpx，来自 %s）" % [worst, str(worst_wp)])


func _test_stuck_progress_detection() -> void:
	## 回归：卡住判定必须看"有没有更靠近航点"，而不是"单帧位移大小"。
	## 旧判据（位移 < 0.3px）在敌人贴墙振荡时永远不触发 —— 实测每帧位移恒为
	## move_speed/60 = 2.67px，于是敌人 220 帧原地来回磨却报 stuck=0。
	var wps: Array[Vector2] = [Vector2(1000.0, 1000.0)]
	_state._path = wps
	_state._path_idx = 0
	_state._wp_tracked_idx = -1
	_state._wp_best_dist = 1e30
	_state._stuck_frames = 0

	# ① 原地不动（等价于贴墙来回磨：距离不变）→ 必须累计到阈值
	#    多跑一帧：第 1 帧只是建立 "已到达的最近距离" 这个基准，不计为卡住。
	_enemy.global_position = Vector2(900.0, 900.0)
	for i in range(CHASE_SCRIPT.STUCK_SKIP_FRAMES + 1):
		_state._update_stuck_state(_enemy)
	_check(_state._stuck_frames >= CHASE_SCRIPT.STUCK_SKIP_FRAMES,
		"原地振荡 %d 帧 → 卡住计数达到阈值 %d（实际 %d）" % [
			CHASE_SCRIPT.STUCK_SKIP_FRAMES + 1, CHASE_SCRIPT.STUCK_SKIP_FRAMES, _state._stuck_frames])

	# ② 明显靠近 → 不累计
	_state._wp_tracked_idx = -1
	_state._wp_best_dist = 1e30
	_state._stuck_frames = 0
	_enemy.global_position = Vector2(900.0, 900.0)
	for i in range(CHASE_SCRIPT.STUCK_SKIP_FRAMES):
		_enemy.global_position += Vector2(1.0, 0.0)
		_state._update_stuck_state(_enemy)
	_check(_state._stuck_frames == 0,
		"持续靠近时不累计卡住（实际 %d）" % _state._stuck_frames)

	# ③ 慢慢靠近（0.3px/帧，低于单帧阈值 0.5）→ 也不应累计（否则被群挤时会被误判卡住）
	_state._wp_tracked_idx = -1
	_state._wp_best_dist = 1e30
	_state._stuck_frames = 0
	_enemy.global_position = Vector2(900.0, 900.0)
	for i in range(CHASE_SCRIPT.STUCK_SKIP_FRAMES):
		_enemy.global_position += Vector2(0.3, 0.0)
		_state._update_stuck_state(_enemy)
	_check(_state._stuck_frames < CHASE_SCRIPT.STUCK_SKIP_FRAMES,
		"以 0.3px/帧 缓慢靠近时不会触发卡住阈值（实际计数 %d，阈值 %d）" % [
			_state._stuck_frames, CHASE_SCRIPT.STUCK_SKIP_FRAMES])

	# ④ 振荡（前后各 2.67px，净位移为 0）→ 必须累计
	_state._wp_tracked_idx = -1
	_state._wp_best_dist = 1e30
	_state._stuck_frames = 0
	_enemy.global_position = Vector2(900.0, 900.0)
	for i in range(CHASE_SCRIPT.STUCK_SKIP_FRAMES + 1):
		_enemy.global_position += Vector2(2.67 if i % 2 == 0 else -2.67, 0.0)
		_state._update_stuck_state(_enemy)
	_check(_state._stuck_frames >= CHASE_SCRIPT.STUCK_SKIP_FRAMES,
		"往返振荡（每帧 2.67px 但有去无回）→ 仍被识别为卡住（实际 %d）" % _state._stuck_frames)

	# 还原，避免影响后续用例
	var empty: Array[Vector2] = []
	_state._path = empty
	_state._path_idx = 0
	_state._stuck_frames = 0
	_state._wp_best_dist = 1e30
	_state._wp_tracked_idx = -1


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
