extends RefCounted
## VX Ace 图块系统的常量和数据结构
##
## 参考文档：
##   RM2K3_to_VX-Ace_图块转换分析.md — RM2K3→VX Ace 自动图块转换原理
##   art/Tilesets/TileA4-Twnew_format-analysis.md — TileA4-Twnew 简化格式详解
##   engine-reference/rpgvxace-docs/rpgvxace/6100_resource.html — VX Ace 素材规范
##
## ═══════════════════════════════════════
## A2 地面自动图块（每组 2列×3行 = 6 tile）
## ═══════════════════════════════════════
##
##   行0: [外角-TL] [外角-TR]  ← 两侧无同类地形（边界外角）
##   行1: [内角-TL] [内角-TR]  ← 两侧有同类地形（内部拐角）
##   行2: [填充-TL] [填充-TR]  ← 填充/底边（边缘或无邻）
##
##   与 RM2K3 的关系：RM2K3 的 3×4 自动图块去掉中间列和第3行后即得此 2×3 结构。
##   详见 RM2K3_to_VX-Ace_图块转换分析.md 第2.2节。
##
## ═══════════════════════════════════════
## A4 墙壁自动图块（每组 2列×5行 = 10 tile）
## ═══════════════════════════════════════
##
##   行0: (0,0) 屋顶-单个    (1,0) 屋顶-四边角
##   行1: (0,1) 屋顶TL       (1,1) 屋顶TR
##   行2: (0,2) 屋顶BL       (1,2) 屋顶BR
##   行3: (0,3) 墙壁TL       (1,3) 墙壁TR
##   行4: (0,4) 墙壁BL       (1,4) 墙壁BR
##
##   渲染规则：
##     上方无墙 → 用屋顶（行0-2）
##     上方有墙 → 用墙壁（行3-4）
##     每个 32x32 tile 的 4 个 16x16 象限从对应的 4 个源格各取 16x16
##
##   ⚠️ 标准格式 subtile 校准问题：
##     像素分析表明，不同 A4 group 内部 16×16 象限的排列（外角/内角/边缘）
##     并不统一——Group 0 墙体 tile 有 2 种变体，Group 1/2 墙体 tile 接近均匀。
##     _get_subtile_offset() 的固定映射无法覆盖所有 group，需要逐组校准。
##     当前推荐使用简化格式（完整 32×32 tile + bitmask 直查表）避免此问题。


# ═══════════════════════════════════════
# 图块组类型
# ═══════════════════════════════════════

enum TileGroup {
	A1,  ## 动画自动图块（水面/瀑布）
	A2,  ## 地面自动图块
	A3,  ## 建筑外观自动图块（自动阴影）
	A4,  ## 墙壁自动图块
	A5,  ## 普通下层图块
	B,   ## 上层装饰图块
	C,   ## 上层装饰图块
	D,   ## 上层装饰图块
	E,   ## 上层装饰图块
}


# ═══════════════════════════════════════
# 3x3 Bitmask 常量
# ═══════════════════════════════════════

const BIT_UP := 1
const BIT_RIGHT := 2
const BIT_DOWN := 4
const BIT_LEFT := 8
const BIT_UP_RIGHT := 16
const BIT_DOWN_RIGHT := 32
const BIT_DOWN_LEFT := 64
const BIT_UP_LEFT := 128

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i( 0, -1),  # bit 0: UP
	Vector2i( 1,  0),  # bit 1: RIGHT
	Vector2i( 0,  1),  # bit 2: DOWN
	Vector2i(-1,  0),  # bit 3: LEFT
	Vector2i( 1, -1),  # bit 4: UP_RIGHT
	Vector2i( 1,  1),  # bit 5: DOWN_RIGHT
	Vector2i(-1,  1),  # bit 6: DOWN_LEFT
	Vector2i(-1, -1),  # bit 7: UP_LEFT
]


# ═══════════════════════════════════════
# VX Ace 标准文件尺寸
# ═══════════════════════════════════════

const STANDARD_SIZES := {
	TileGroup.A1: Vector2i(512, 384),
	TileGroup.A2: Vector2i(512, 384),
	TileGroup.A3: Vector2i(512, 256),
	TileGroup.A4: Vector2i(512, 480),
	TileGroup.A5: Vector2i(256, 512),
	TileGroup.B:  Vector2i(512, 512),
	TileGroup.C:  Vector2i(512, 512),
	TileGroup.D:  Vector2i(512, 512),
	TileGroup.E:  Vector2i(512, 512),
}


# ═══════════════════════════════════════
# A4 组结构定义
# ═══════════════════════════════════════

## 每组 2 列 × 5 行
const A4_GROUP_COLS := 2
const A4_GROUP_ROWS := 5

## 屋顶/墙壁 行偏移（相对于组起始行）
const A4_ROOF_SINGLE_ROW := 0   ## 屋顶-单个
const A4_ROOF_TL_ROW := 1       ## 屋顶TL / 墙壁TL
const A4_ROOF_BL_ROW := 2       ## 屋顶BL / 墙壁BL
const A4_WALL_TL_ROW := 3       ## 墙壁TL
const A4_WALL_BL_ROW := 4       ## 墙壁BL

## 列偏移
const A4_COL_LEFT := 0          ## 左列（TL/BL）
const A4_COL_RIGHT := 1         ## 右列（TR/BR）


# ═══════════════════════════════════════
# A2 组结构定义
# ═══════════════════════════════════════

## A2 每组 2 列 × 3 行（64×96 px @ 32px tile）
## 每组可垂直堆叠 3 个动画帧 → 2×9 = 18 tile 含动画
const A2_GROUP_COLS := 2
const A2_GROUP_ROWS := 3        ## 不含动画帧，仅基础单元
const A2_ANIM_FRAMES := 3       ## 每组最多 3 个动画帧垂直排列

## A2 行偏移（相对于组起始行）
const A2_OUTER_ROW := 0         ## 外角行 — 两侧无同类地形
const A2_INNER_ROW := 1         ## 内角行 — 两侧有同类地形
const A2_FILL_ROW := 2          ## 填充行 — 边缘/底边/无邻

## A2 列偏移
const A2_COL_LEFT := 0          ## 左列（TL）
const A2_COL_RIGHT := 1         ## 右列（TR）

## A2 标准纹理中的组布局
## A2 画布 512×384 = 16×12 tile。每行最多 8 组（每组 2 列），
## 每组含 3 动画帧时占 2×9 tile。
const A2_MAX_GROUPS_PER_ROW := 8
const A2_GROUP_PITCH := 2       ## 组间距（列数）


# ═══════════════════════════════════════
# TileA4-Twnew.png 简化格式映射（向后兼容）
# ═══════════════════════════════════════

## TileA4-Twnew 是一个 3 列格式的单墙壁组
## 行0-2: 屋顶（9 tile）, 行3-4: 墙壁（8 tile）

const A4_SIMPLE_ROOF_MAP := {
	# bitmask: Vector2i(col, row)
	38:  Vector2i(0, 0),   ## TL-外角
	110: Vector2i(1, 0),   ## T-上边
	76:  Vector2i(2, 0),   ## TR-外角
	55:  Vector2i(0, 1),   ## L-左边
	255: Vector2i(1, 1),   ## 中央
	205: Vector2i(2, 1),   ## R-右边
	19:  Vector2i(0, 2),   ## BL-外角
	155: Vector2i(1, 2),   ## B-下边
	137: Vector2i(2, 2),   ## BR-外角
}

const A4_SIMPLE_WALL_MAP := {
	38:  Vector2i(0, 3),   ## TL-外角 → 内角TL
	110: Vector2i(1, 3),   ## T-上边 → 内壁A
	76:  Vector2i(2, 3),   ## TR-外角 → 内角TR
	55:  Vector2i(1, 3),   ## L-左边 → 内壁A
	255: Vector2i(1, 3),   ## 中央 → 内壁A
	205: Vector2i(2, 3),   ## R-右边 → 内角TR
	19:  Vector2i(3, 3),   ## BL-外角 → 内壁B
	155: Vector2i(1, 3),   ## B-下边 → 内壁A
	137: Vector2i(3, 3),   ## BR-外角 → 内壁B
}


# ═══════════════════════════════════════
# 工具方法
# ═══════════════════════════════════════

## 根据 3x3 邻居矩阵计算 bitmask
static func calc_bitmask(neighbors: Array) -> int:
	var bits: int = 0
	for i: int in range(8):
		var offset: Vector2i = NEIGHBOR_OFFSETS[i]
		var nx: int = 1 + offset.x
		var ny: int = 1 + offset.y
		if neighbors[ny][nx]:
			bits |= (1 << i)
	return bits


## 获取 A4 组的基坐标（源纹理中的左上角 tile 坐标）
## group_index: 0-7，对应第几组墙壁
static func get_a4_group_origin(group_index: int) -> Vector2i:
	return Vector2i(group_index * A4_GROUP_COLS, 0)


## 获取标准 A4 格式的 tile 坐标
## 参数:
##   group_origin: 组左上角坐标 Vector2i(col, row)
##   is_roof: true=屋顶, false=墙壁
##   quadrant: 象限 0=TL, 1=TR, 2=BL, 3=BR
##   对于"屋顶-单个"和"屋顶-四边角"需要特殊处理
static func get_a4_standard_coord(group_origin: Vector2i, is_roof: bool, quadrant: int) -> Vector2i:
	var row_off: int
	var col_off: int

	match quadrant:
		0:  # TL
			col_off = A4_COL_LEFT
			row_off = A4_ROOF_TL_ROW if is_roof else A4_WALL_TL_ROW
		1:  # TR
			col_off = A4_COL_RIGHT
			row_off = A4_ROOF_TL_ROW if is_roof else A4_WALL_TL_ROW
		2:  # BL
			col_off = A4_COL_LEFT
			row_off = A4_ROOF_BL_ROW if is_roof else A4_WALL_BL_ROW
		3:  # BR
			col_off = A4_COL_RIGHT
			row_off = A4_ROOF_BL_ROW if is_roof else A4_WALL_BL_ROW

	return group_origin + Vector2i(col_off, row_off)


## 获取 A2 组的基坐标（源纹理中的左上角 tile 坐标）
## group_index: 0-N，对应第几组地面 autotile
## anim_frame: 0-2，动画帧索引（0=基础帧）
static func get_a2_group_origin(group_index: int, anim_frame: int = 0) -> Vector2i:
	return Vector2i(
		(group_index % A2_MAX_GROUPS_PER_ROW) * A2_GROUP_PITCH,
		(group_index / A2_MAX_GROUPS_PER_ROW) * A2_GROUP_ROWS * A2_ANIM_FRAMES + anim_frame * A2_GROUP_ROWS
	)


## 根据 A2 autotile 的 bitmask 返回组内局部坐标
## 返回 Vector2i(local_col, local_row)，组内局部坐标（0-1 列, 0-2 行）
## 基于 VX Ace A2 2×3 自动图块的标准 bitmask→tile 映射规则
static func get_a2_local_coord(bitmask: int) -> Vector2i:
	# A2 自动图块：6 个 tile 覆盖所有 bitmask
	# 根据 bitmask 的 4 个主方向（上下左右）判断使用哪个 tile
	var has_up := (bitmask & BIT_UP) != 0
	var has_right := (bitmask & BIT_RIGHT) != 0
	var has_down := (bitmask & BIT_DOWN) != 0
	var has_left := (bitmask & BIT_LEFT) != 0

	# 统计相邻方向数
	var count := (1 if has_up else 0) + (1 if has_right else 0) + (1 if has_down else 0) + (1 if has_left else 0)

	match count:
		0:  # 孤立 — 使用填充 tile
			return Vector2i(A2_COL_LEFT, A2_FILL_ROW)
		4:  # 四面环绕 — 使用填充中央 tile
			return Vector2i(A2_COL_RIGHT, A2_FILL_ROW)
		1:  # 单边 — 使用外角
			return Vector2i(A2_COL_LEFT, A2_OUTER_ROW)
		2:  # 两边 — 判断是直线还是拐角
			if (has_up and has_down) or (has_left and has_right):
				# 直线穿过 → 填充
				return Vector2i(A2_COL_RIGHT, A2_FILL_ROW)
			else:
				# L 形拐角 → 内角
				return Vector2i(A2_COL_RIGHT, A2_INNER_ROW)
		3:  # 三边 — 使用内角
			return Vector2i(A2_COL_LEFT, A2_INNER_ROW)
		_:  # 回退
			return Vector2i(A2_COL_LEFT, A2_FILL_ROW)
