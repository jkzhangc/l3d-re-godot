extends RefCounted
## VX Ace A4 墙壁 autotile 引擎 — 16×16 subtile 动态组合
##
## 标准 A4 格式 2列×5行/组:
##   (0,0) 屋顶-单个   (1,0) 屋顶-四边角
##   (0,1) 屋顶TL      (1,1) 屋顶TR
##   (0,2) 屋顶BL      (1,2) 屋顶BR
##   (0,3) 墙壁TL      (1,3) 墙壁TR
##   (0,4) 墙壁BL      (1,4) 墙壁BR
##
## 渲染规则:
##   上方无同 terrain → 屋顶（行0-2）
##   上方有同 terrain → 墙壁（行3-4）
##   每个32x32输出 = 4个16x16象限，从对应源 tile 取对应区域
##
## ⚠️ 标准格式 subtile 校准状态:
##   _get_subtile_offset() 的 16×16 象限映射为固定规则，但像素分析表明
##   不同 A4 group 的象限排列并不统一（详见 RM2K3_to_VX-Ace_图块转换分析.md 第4节）。
##   当前规则对部分 group 有效，对另一些 group 会产生错误的象限选择。
##   如需标准格式正确渲染，需要对每个目标 group 进行像素级校准。
##   简化格式（完整 32×32 tile + bitmask 直查表）不受此问题影响。
##
## A2 简化模式（NEW）:
##   基于 2K_TO_VA 工具验证的 A2 2×3 结构，get_source_rect() 现支持
##   TileGroup.A2 的简化模式（完整 32×32 tile 查表）。

const _TD = preload("res://addons/vx_tilemap/vx_tile_data.gd")


# ═══════════════════════════════════════
# 公开 API
# ═══════════════════════════════════════

## 获取 4 个 16×16 源矩形 (TL, TR, BL, BR)
##   has_above → TL/TR 用墙壁(被上方遮挡), 否则用屋顶
##   has_below → BL/BR 用墙壁(下方有墙, 立面可见), 否则延展屋顶
static func get_a4_subtiles(group_origin: Vector2i, bitmask: int, has_above: bool, has_below: bool) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	# Quadrant roof/wall selection
	var is_roof := [
		not has_above,   # TL: roof unless wall above hides it
		not has_above,   # TR: roof unless wall above hides it
		not has_below,   # BL: wall face if wall below, else roof extends down
		not has_below,   # BR: wall face if wall below, else roof extends down
	]

	for quad: int in range(4):
		var coord: Vector2i = _get_quadrant_source_coord(group_origin, is_roof[quad], quad)
		var sub_offset: Vector2i = _get_subtile_offset(quad, bitmask)
		var src_px := coord * 32 + sub_offset
		result.append(Rect2i(src_px, Vector2i(16, 16)))

	return result


## 完整 32×32 tile 查找 (简化格式向后兼容)
## 支持 A2（地面）和 A4（墙壁）两种自动图块
static func get_source_rect(group: int, bitmask: int, has_above: bool = false, _has_below: bool = false) -> Rect2i:
	match group:
		_TD.TileGroup.A4:
			return _get_a4_simple_rect(bitmask, has_above)
		_TD.TileGroup.A2:
			return _get_a2_simple_rect(bitmask)
		_:
			push_warning("VXAutotile: TileGroup %d not supported" % group)
			return Rect2i(0, 0, 32, 32)


# ═══════════════════════════════════════
# Subtile 组合
# ═══════════════════════════════════════

## 获取指定象限的源 tile 坐标
static func _get_quadrant_source_coord(group_origin: Vector2i, is_roof: bool, quad: int) -> Vector2i:
	var col := group_origin.x
	var row := group_origin.y

	match quad:
		0: return Vector2i(col + _TD.A4_COL_LEFT,  row + (_TD.A4_ROOF_TL_ROW if is_roof else _TD.A4_WALL_TL_ROW))
		1: return Vector2i(col + _TD.A4_COL_RIGHT, row + (_TD.A4_ROOF_TL_ROW if is_roof else _TD.A4_WALL_TL_ROW))
		2: return Vector2i(col + _TD.A4_COL_LEFT,  row + (_TD.A4_ROOF_BL_ROW if is_roof else _TD.A4_WALL_BL_ROW))
		_: return Vector2i(col + _TD.A4_COL_RIGHT, row + (_TD.A4_ROOF_BL_ROW if is_roof else _TD.A4_WALL_BL_ROW))


## 根据象限和局部 bitmask 决定取源 tile 中哪个 16×16 区域
## 返回 Vector2i(sub_x, sub_y) — 在源 tile 中的偏移
static func _get_subtile_offset(quad: int, bitmask: int) -> Vector2i:
	var has_up := (bitmask & _TD.BIT_UP) != 0
	var has_right := (bitmask & _TD.BIT_RIGHT) != 0
	var has_down := (bitmask & _TD.BIT_DOWN) != 0
	var has_left := (bitmask & _TD.BIT_LEFT) != 0
	var has_ur := (bitmask & _TD.BIT_UP_RIGHT) != 0
	var has_dr := (bitmask & _TD.BIT_DOWN_RIGHT) != 0
	var has_dl := (bitmask & _TD.BIT_DOWN_LEFT) != 0
	var has_ul := (bitmask & _TD.BIT_UP_LEFT) != 0

	match quad:
		0:  # TL quadrant — check left, up, up-left neighbors
			if not has_left and not has_up:
				return Vector2i(0, 0)    # outer corner — both sides open
			elif has_left and has_up:
				return Vector2i(16, 16)  # inner corner — both sides closed
			elif not has_left:
				return Vector2i(0, 16)   # left side open
			else:
				return Vector2i(16, 0)   # top side open

		1:  # TR quadrant — check right, up, up-right neighbors
			if not has_right and not has_up:
				return Vector2i(16, 0)   # outer corner
			elif has_right and has_up:
				return Vector2i(0, 16)   # inner corner
			elif not has_right:
				return Vector2i(16, 16)  # right side open
			else:
				return Vector2i(0, 0)    # top side open

		2:  # BL quadrant — check left, down, down-left neighbors
			if not has_left and not has_down:
				return Vector2i(0, 16)   # outer corner
			elif has_left and has_down:
				return Vector2i(16, 0)   # inner corner
			elif not has_left:
				return Vector2i(0, 0)    # left side open
			else:
				return Vector2i(16, 16)  # down side open

		_:  # BR quadrant — check right, down, down-right neighbors
			if not has_right and not has_down:
				return Vector2i(16, 16)  # outer corner
			elif has_right and has_down:
				return Vector2i(0, 0)    # inner corner
			elif not has_right:
				return Vector2i(16, 0)   # right side open
			else:
				return Vector2i(0, 16)   # down side open


# ═══════════════════════════════════════
# 简化格式 (TileA4-Twnew) 向后兼容
# ═══════════════════════════════════════

static func _get_a4_simple_rect(bitmask: int, has_above: bool) -> Rect2i:
	var coord: Vector2i
	if has_above:
		coord = _TD.A4_SIMPLE_WALL_MAP.get(bitmask, Vector2i(1, 3))
	else:
		coord = _TD.A4_SIMPLE_ROOF_MAP.get(bitmask, Vector2i(1, 1))
		# bitmask 0 (孤立) → roof-single
		if bitmask == 0:
			coord = Vector2i(0, 0)
	return Rect2i(coord * 32, Vector2i(32, 32))


## A2 简化格式 — 完整 32×32 tile 查找
## 使用 vx_tile_data.gd 的 get_a2_local_coord() 将 bitmask 映射到 2×3 组内坐标
## 调用方需提供 group_origin 来获取绝对坐标；此处返回相对于组原点的矩形
## 注意：此方法假设纹理以单一 A2 组开头（cols 0-1, rows 0-2），
## 如需多组/多帧，应通过 VXGridConfig 或传入 group_index 来定位
static func _get_a2_simple_rect(bitmask: int) -> Rect2i:
	var local: Vector2i = _TD.get_a2_local_coord(bitmask)
	return Rect2i(local * 32, Vector2i(32, 32))
