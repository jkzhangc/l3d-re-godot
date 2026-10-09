extends RefCounted

## ── 架构定位 ──
## 系统：敌人调试可视化 ｜ 层：服务类（RefCounted，由 enemy 持有）
## 联机：仅本机调试（Global.debug_visuals 关闭时整块不执行），与联机无关
## 职责：在敌人节点上绘制调试信息：碰撞体/血条/视野扇形/攻击矩形/A* 路径与可行走网格。
## 依赖：enemy 实体（读 @export 视野/攻击字段、debug 状态变量；经 _e.draw_* 发绘制指令）
##
## 【为什么从 enemy.gd 抽出（2026-10-08）】调试绘制约 155 行、纯可视化、零玩法耦合。
## 抽出后 enemy.gd 只留 `func _draw(): _debug_drawer.draw()` 一行转发。
##
## 【为什么要经 _e.draw_* 而不是自己画】`draw_rect` / `draw_line` 等是 **CanvasItem 的绘制
## 指令**，必须在宿主节点自己的 `_draw()` 回调**同步调用栈内**发出才有效。本服务的 `draw()`
## 正是被 `_e._draw()` 同步调用的，所以 `_e.draw_rect(...)` 落在同一次绘制通道内，行为等价。
##
## 【状态变量留在 enemy】`_debug_path` / `_debug_path_idx` / `_debug_start_grid` /
## `_debug_end_grid` / `_debug_cell_size` / `_debug_path_found` / `_debug_astar_iters` /
## `_debug_walk_cache` 全部保留在 enemy.gd（EnemyChaseState 会直接写 `enemy._debug_path`）。

var _e: Node = null


func _init(enemy: Node) -> void:
	_e = enemy


## 调试可视化主入口（由 enemy._draw() 转发）。Global.debug_visuals 关闭时直接返回。
func draw() -> void:
	if not Global.debug_visuals:
		return

	var cs: CollisionShape2D = _e.get_node("CollisionShape2D")
	var color: Color = Color.GRAY if _e._is_dead else Color.RED
	var shape: Shape2D = cs.shape
	if shape is RectangleShape2D:
		var rect: RectangleShape2D = shape as RectangleShape2D
		var pos: Vector2 = cs.position
		_e.draw_rect(Rect2(pos - rect.size / 2, rect.size), color, false, 1.0)

	if _e._is_dead:
		var bar_w: float = 48.0
		var bar_h: float = 4.0
		var bar_y: float = -40.0
		_e.draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.GRAY, true)
		return

	var forward: Vector2 = _e.get_facing_vector()
	var half_angle: float = deg_to_rad(_e.vision_angle / 2.0)
	var segments: int = 16
	var points: PackedVector2Array = PackedVector2Array()
	points.append(Vector2.ZERO)
	for i: int in range(segments + 1):
		var a: float = -half_angle + (2.0 * half_angle) * float(i) / float(segments)
		points.append(forward.rotated(a) * _e.vision_range)
	_e.draw_polygon(points, PackedColorArray([Color(1, 1, 0, 0.1)]))

	var left_edge: Vector2 = forward.rotated(-half_angle) * _e.vision_range
	var right_edge: Vector2 = forward.rotated(half_angle) * _e.vision_range
	_e.draw_line(Vector2.ZERO, left_edge, Color(1, 1, 0, 0.3))
	_e.draw_line(Vector2.ZERO, right_edge, Color(1, 1, 0, 0.3))
	_e.draw_arc(Vector2.ZERO, _e.vision_range, -half_angle, half_angle, 16, Color(1, 1, 0, 0.3))

	# 攻击命中矩形（attack_hit_range）—— 橙紅，跟随朝向旋转
	var hit_offset: Vector2 = forward * _e.attack_hit_forward_offset
	var hw: float = _e.attack_hit_range.x / 2.0
	var hh: float = _e.attack_hit_range.y / 2.0
	var hit_side: Vector2 = Vector2(-forward.y, forward.x)
	var hit_corners: PackedVector2Array = PackedVector2Array([
			hit_offset + forward * hh + hit_side * hw,
			hit_offset + forward * hh - hit_side * hw,
			hit_offset - forward * hh - hit_side * hw,
			hit_offset - forward * hh + hit_side * hw,
	])
	hit_corners.append(hit_corners[0])
	_e.draw_polyline(hit_corners, Color.ORANGE_RED, 1.0)

	# 攻击触发矩形（attack_range）—— 青色，与判定矩形相同旋转逻辑
	var tr_offset: Vector2 = forward * _e.attack_range_forward_offset
	var tr_hw: float = _e.attack_range.x / 2.0
	var tr_hh: float = _e.attack_range.y / 2.0
	var tr_corners: PackedVector2Array
	if abs(forward.x) > abs(forward.y):
		var side: Vector2 = Vector2(-forward.y, forward.x)
		tr_corners = PackedVector2Array([
			tr_offset + forward * tr_hh + side * tr_hw,
			tr_offset + forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh - side * tr_hw,
			tr_offset - forward * tr_hh + side * tr_hw,
		])
	else:
		tr_corners = PackedVector2Array([
			tr_offset + Vector2(-tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw, -tr_hh),
			tr_offset + Vector2( tr_hw,  tr_hh),
			tr_offset + Vector2(-tr_hw,  tr_hh),
		])
	tr_corners.append(tr_corners[0])
	_e.draw_polyline(tr_corners, Color.CYAN, 1.0)

	var bar_w: float = 48.0
	var bar_h: float = 4.0
	var bar_y: float = -40.0
	var ratio: float = _e.current_hp / _e.max_hp
	_e.draw_rect(Rect2(-bar_w / 2, bar_y, bar_w, bar_h), Color.RED, false, 1.0)
	_e.draw_rect(Rect2(-bar_w / 2, bar_y, bar_w * ratio, bar_h), Color.RED, true)

	# 绘制受击碰撞体（黄色）
	if _e.hurt_area:
		var hshape_node: CollisionShape2D = _e.hurt_area.get_node_or_null("HurtShape")
		if hshape_node and hshape_node.shape is RectangleShape2D:
			var hs: Vector2 = (hshape_node.shape as RectangleShape2D).size
			var ho: Vector2 = hshape_node.position
			_e.draw_rect(Rect2(ho - hs / 2, hs), Color.YELLOW, false, 1.0)

	# ── A* 调试：绘制路径 ──
	draw_path()

	# ── A* 调试：绘制可行走网格 ──
	draw_walk_grid()


func draw_path() -> void:
	if _e._debug_path.is_empty():
		return

	# 路径线 — 绿色
	if _e._debug_path.size() >= 2:
		for i in range(_e._debug_path.size() - 1):
			var a: Vector2 = _e._debug_path[i] - _e.global_position
			var b: Vector2 = _e._debug_path[i + 1] - _e.global_position
			_e.draw_line(a, b, Color.GREEN, 2.0)

	# 路径点 — 绿色小圈
	for wp: Vector2 in _e._debug_path:
		var lp: Vector2 = wp - _e.global_position
		_e.draw_circle(lp, 3.0, Color.GREEN)
		_e.draw_circle(lp, 4.0, Color.DARK_GREEN, false, 1.0)

	# 下一个目标路径点 — 亮黄色
	if _e._debug_path_idx < _e._debug_path.size():
		var target: Vector2 = _e._debug_path[_e._debug_path_idx] - _e.global_position
		_e.draw_circle(target, 6.0, Color.YELLOW, false, 2.0)

	# 起点/终点标记（格子坐标 → 世界坐标）
	var cell_half: float = _e._debug_cell_size / 2.0
	var start_wp: Vector2 = Vector2(_e._debug_start_grid.x * _e._debug_cell_size + cell_half, _e._debug_start_grid.y * _e._debug_cell_size + cell_half) - _e.global_position
	var end_wp: Vector2 = Vector2(_e._debug_end_grid.x * _e._debug_cell_size + cell_half, _e._debug_end_grid.y * _e._debug_cell_size + cell_half) - _e.global_position
	_e.draw_rect(Rect2(start_wp - Vector2(6, 6), Vector2(12, 12)), Color.BLUE, false, 2.0)
	_e.draw_rect(Rect2(end_wp - Vector2(6, 6), Vector2(12, 12)), Color.RED, false, 2.0)

	# 路径状态文字
	var status: String = "OK:%d" % _e._debug_path.size() if _e._debug_path_found else "FAIL(iters:%d)" % _e._debug_astar_iters
	_e.draw_string(ThemeDB.fallback_font, Vector2(20, -50), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.GREEN if _e._debug_path_found else Color.RED)


func draw_walk_grid() -> void:
	if _e._debug_walk_cache.is_empty():
		return

	var cell_half: float = _e._debug_cell_size / 2.0
	var cs: float = _e._debug_cell_size

	# 性能优化：按可见范围计算网格坐标遍历，而非遍历整个缓存字典
	# 预构建后缓存可能包含全图数万格子，遍历字典每帧极卡
	var view_range: int = 6  ## 格子数（约 192px @ 32px/cell）
	var center_gp: Vector2i = Vector2i(floori(_e.global_position.x / cs), floori(_e.global_position.y / cs))

	for dx in range(-view_range, view_range + 1):
		for dy in range(-view_range, view_range + 1):
			var gp: Vector2i = Vector2i(center_gp.x + dx, center_gp.y + dy)
			if not _e._debug_walk_cache.has(gp):
				continue
			var world: Vector2 = Vector2(gp.x * cs + cell_half, gp.y * cs + cell_half)
			var local: Vector2 = world - _e.global_position

			var walkable: bool = _e._debug_walk_cache[gp]
			if walkable:
				_e.draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(0, 1, 0, 0.08), true)
			else:
				_e.draw_rect(Rect2(local - Vector2(cell_half, cell_half), Vector2(cs, cs)), Color(1, 0, 0, 0.15), true)
				_e.draw_line(local + Vector2(-4, -4), local + Vector2(4, 4), Color.RED, 1.0)
				_e.draw_line(local + Vector2(-4, 4), local + Vector2(4, -4), Color.RED, 1.0)
