@tool
class_name VXGridConfig extends Resource
## A4 自动图块网格配置 — 将 bitmask 映射到纹理坐标。
## 保存为 .tres 文件，可在多个 VXTileMap 节点间复用。
##
## 区域制：通过定义纹理上的矩形区域来标记屋顶/墙体 tiles。
## 每个区域 = {name, rect:Rect2i, type:int}
##
## 用法：
##   var cfg = VXGridConfig.create_standard_a4()
##   cfg.build_cache()
##   var rect = cfg.get_source_rect(bitmask, is_roof)


# ═══════════════════════════════════════
# 格式模式
# ═══════════════════════════════════════

enum FormatMode {
	SIMPLIFIED,  ## 完整 tile 模式 — 直接用 bitmask 查表得 32×32 tile
	STANDARD,    ## 16×16 subtile 模式 — 每组 4 象限从 4 个源 tile 组装
}


# ═══════════════════════════════════════
# 区域类型
# ═══════════════════════════════════════

enum RegionType {
	ROOF = 0,  ## 屋顶 / 天花板面
	WALL = 1,  ## 墙体 / 侧面
}


# ═══════════════════════════════════════
# 基础设置
# ═══════════════════════════════════════

@export_group("Texture")
@export var source_texture: Texture2D = null:
	set(v):
		source_texture = v
		emit_changed()

@export var tile_size: int = 32:
	set(v):
		tile_size = v
		emit_changed()

@export var format_mode: FormatMode = FormatMode.SIMPLIFIED:
	set(v):
		format_mode = v
		emit_changed()


# ═══════════════════════════════════════
# 网格布局（纹理中的全局 tile 排列）
# ═══════════════════════════════════════

@export_group("Grid Layout")
## 每组中的列数
@export var group_cols: int = 2:
	set(v):
		group_cols = v
		_build_cache()
## 每组中的行数
@export var group_rows: int = 5:
	set(v):
		group_rows = v
		_build_cache()
## 纹理中的组数（水平排列）
@export var group_count: int = 6:
	set(v):
		group_count = v
		_build_cache()


# ═══════════════════════════════════════
# 区域定义
# ═══════════════════════════════════════

@export_group("Regions")
## 区域列表 — 每个 Dictionary: {"name":"屋顶-组0", "rect":Rect2i(0,0,2,3), "type":0}
## Rect2i = (col, row, width, height) — 纹理中的全局 tile 坐标
## type: 0=ROOF, 1=WALL
@export var regions: Array[Dictionary] = []:
	set(v):
		regions = v
		_build_cache()


# ═══════════════════════════════════════
# Bitmask → Tile 映射
# ═══════════════════════════════════════

@export_group("Bitmask Maps")
## {bitmask: Vector2i(local_col, local_row)} — 屋顶映射
@export var roof_map: Dictionary = {}:
	set(v):
		roof_map = v
		_build_cache()
## {bitmask: Vector2i(local_col, local_row)} — 墙体映射
@export var wall_map: Dictionary = {}:
	set(v):
		wall_map = v
		_build_cache()
## bitmask=0（孤立 tile）的屋顶坐标
@export var isolated_roof_coord: Vector2i = Vector2i(0, 0):
	set(v):
		isolated_roof_coord = v
		_build_cache()


# ═══════════════════════════════════════
# Standard 格式 — 组内角色坐标
# ═══════════════════════════════════════

@export_group("Standard Format — Source Roles")
@export var std_roof_single_coord: Vector2i = Vector2i(0, 0)
@export var std_roof_quad_coord: Vector2i  = Vector2i(1, 0)
@export var std_roof_tl_coord: Vector2i    = Vector2i(0, 1)
@export var std_roof_tr_coord: Vector2i    = Vector2i(1, 1)
@export var std_roof_bl_coord: Vector2i    = Vector2i(0, 2)
@export var std_roof_br_coord: Vector2i    = Vector2i(1, 2)
@export var std_wall_tl_coord: Vector2i    = Vector2i(0, 3)
@export var std_wall_tr_coord: Vector2i    = Vector2i(1, 3)
@export var std_wall_bl_coord: Vector2i    = Vector2i(0, 4)
@export var std_wall_br_coord: Vector2i    = Vector2i(1, 4)


# ═══════════════════════════════════════
# 缓存（内部，不导出）
# ═══════════════════════════════════════

var _roof_cache: Dictionary = {}
var _wall_cache: Dictionary = {}


# ═══════════════════════════════════════
# 区域管理
# ═══════════════════════════════════════

## 添加一个区域。
func add_region(rname: String, rect: Rect2i, rtype: int) -> void:
	regions.append({"name": rname, "rect": rect, "type": rtype})
	_build_cache()


## 移除指定索引的区域。
func remove_region(index: int) -> void:
	if index >= 0 and index < regions.size():
		regions.remove_at(index)
		_build_cache()


## 获取指定 tile 坐标的区域类型。未定义返回 -1。
func get_region_type_at(global_col: int, global_row: int) -> int:
	for region: Dictionary in regions:
		var r: Rect2i = region["rect"]
		if r.has_point(Vector2i(global_col, global_row)):
			return region["type"]
	return -1


## 指定 tile 是否属于屋顶区域。
func is_roof_tile(global_col: int, global_row: int) -> bool:
	return get_region_type_at(global_col, global_row) == RegionType.ROOF


## 指定 tile 是否属于墙体区域。
func is_wall_tile(global_col: int, global_row: int) -> bool:
	return get_region_type_at(global_col, global_row) == RegionType.WALL


## 获取某个组的所有区域索引。
func get_regions_for_group(group_index: int) -> Array[int]:
	var result: Array[int] = []
	var g_start: int = group_index * group_cols
	var g_end: int = g_start + group_cols
	for i: int in range(regions.size()):
		var r: Rect2i = regions[i]["rect"]
		if r.position.x >= g_start and r.position.x < g_end:
			result.append(i)
	return result


## 获取某个组的屋顶区域（第一个匹配的）。
func get_roof_region_for_group(group_index: int) -> Dictionary:
	for region: Dictionary in regions:
		if region["type"] != RegionType.ROOF:
			continue
		var r: Rect2i = region["rect"]
		var g_start: int = group_index * group_cols
		if r.position.x >= g_start and r.position.x < g_start + group_cols:
			return region
	return {}


## 获取某个组的墙体区域（第一个匹配的）。
func get_wall_region_for_group(group_index: int) -> Dictionary:
	for region: Dictionary in regions:
		if region["type"] != RegionType.WALL:
			continue
		var r: Rect2i = region["rect"]
		var g_start: int = group_index * group_cols
		if r.position.x >= g_start and r.position.x < g_start + group_cols:
			return region
	return {}


# ═══════════════════════════════════════
# 缓存构建
# ═══════════════════════════════════════

func _build_cache() -> void:
	_roof_cache.clear()
	_wall_cache.clear()

	var ts: int = tile_size
	var ts_vec: Vector2i = Vector2i(ts, ts)

	for bitmask: int in roof_map:
		var local: Vector2i = roof_map[bitmask]
		_roof_cache[bitmask] = Rect2i(local * ts, ts_vec)
	for bitmask: int in wall_map:
		var local: Vector2i = wall_map[bitmask]
		_wall_cache[bitmask] = Rect2i(local * ts, ts_vec)

	_roof_cache[0] = Rect2i(isolated_roof_coord * ts, ts_vec)

	emit_changed()


func ensure_cache() -> void:
	if _roof_cache.is_empty() and _wall_cache.is_empty():
		_build_cache()


# ═══════════════════════════════════════
# 渲染查找
# ═══════════════════════════════════════

func get_source_rect(bitmask: int, is_roof: bool) -> Rect2i:
	var cache := _roof_cache if is_roof else _wall_cache
	if cache.has(bitmask):
		return cache[bitmask]
	var fallback := _wall_cache.get(255, Rect2i(Vector2i(1, 3) * tile_size, Vector2i(tile_size, tile_size)))
	return fallback


func get_standard_role_coord(group_index: int, role: int) -> Vector2i:
	var local: Vector2i
	match role:
		0: local = std_roof_single_coord
		1: local = std_roof_quad_coord
		2: local = std_roof_tl_coord
		3: local = std_roof_tr_coord
		4: local = std_roof_bl_coord
		5: local = std_roof_br_coord
		6: local = std_wall_tl_coord
		7: local = std_wall_tr_coord
		8: local = std_wall_bl_coord
		9: local = std_wall_br_coord
		_: return Vector2i.ZERO
	return global_coord(group_index, local.x, local.y)


func global_coord(group: int, local_col: int, local_row: int) -> Vector2i:
	return Vector2i(group * group_cols + local_col, local_row)


func get_group_origin(group_index: int) -> Vector2i:
	return Vector2i(group_index * group_cols, 0)


func total_cols() -> int:
	return group_cols * group_count


func total_rows() -> int:
	return group_rows


func get_group_at_col(global_col: int) -> int:
	return global_col / group_cols


# ═══════════════════════════════════════
# 验证
# ═══════════════════════════════════════

func validate() -> Array[String]:
	var errors: Array[String] = []

	if source_texture == null:
		errors.append("source_texture 未设置")

	if tile_size <= 0:
		errors.append("tile_size 必须 > 0，当前值: %d" % tile_size)

	if group_cols <= 0 or group_rows <= 0:
		errors.append("group_cols / group_rows 必须 > 0")

	if group_count <= 0:
		errors.append("group_count 必须 > 0")

	# 检查区域坐标不越界
	var max_col: int = total_cols() - 1
	var max_row: int = total_rows() - 1
	for i: int in range(regions.size()):
		var region: Dictionary = regions[i]
		var r: Rect2i = region["rect"]
		if r.position.x < 0 or r.position.x + r.size.x - 1 > max_col:
			errors.append("regions[%d] \"%s\" — col 越界 (%d-%d, max=%d)" % [
				i, region.get("name", "?"), r.position.x, r.position.x + r.size.x - 1, max_col])
		if r.position.y < 0 or r.position.y + r.size.y - 1 > max_row:
			errors.append("regions[%d] \"%s\" — row 越界 (%d-%d, max=%d)" % [
				i, region.get("name", "?"), r.position.y, r.position.y + r.size.y - 1, max_row])

	# 检查映射坐标不越界
	for bitmask: int in roof_map:
		var c: Vector2i = roof_map[bitmask]
		if c.x < 0 or c.x > max_col:
			errors.append("roof_map[%d]=%s — col 越界" % [bitmask, c])
		if c.y < 0 or c.y > max_row:
			errors.append("roof_map[%d]=%s — row 越界" % [bitmask, c])

	for bitmask: int in wall_map:
		var c: Vector2i = wall_map[bitmask]
		if c.x < 0 or c.x > max_col:
			errors.append("wall_map[%d]=%s — col 越界" % [bitmask, c])
		if c.y < 0 or c.y > max_row:
			errors.append("wall_map[%d]=%s — row 越界" % [bitmask, c])

	return errors


# ═══════════════════════════════════════
# 工厂方法
# ═══════════════════════════════════════

## 从 vx_tile_data.gd 硬编码映射创建默认配置（匹配 TileA4-Twnew 4×5 简化格式）。
static func create_default() -> VXGridConfig:
	var cfg := VXGridConfig.new()
	var TD = preload("res://addons/vx_tilemap/vx_tile_data.gd")

	cfg.format_mode = FormatMode.SIMPLIFIED
	cfg.tile_size = 32
	cfg.group_cols = 4
	cfg.group_rows = 5
	cfg.group_count = 1

	# 单一区域：屋顶 (0,0)-(4,3), 墙体 (0,3)-(4,2)
	cfg.regions = [
		{"name": "屋顶", "rect": Rect2i(0, 0, 4, 3), "type": RegionType.ROOF},
		{"name": "墙体", "rect": Rect2i(0, 3, 4, 2), "type": RegionType.WALL},
	]

	cfg.roof_map = TD.A4_SIMPLE_ROOF_MAP.duplicate()
	cfg.wall_map = TD.A4_SIMPLE_WALL_MAP.duplicate()
	cfg.isolated_roof_coord = Vector2i(0, 0)

	cfg._build_cache()
	return cfg


## 为标准 VX Ace A4 格式（TileA4-Tw.png）创建配置。
## 2 列 × 5 行 × 6 组。每组有屋顶区域(0-2行)和墙体区域(3-4行)。
static func create_standard_a4() -> VXGridConfig:
	var cfg := VXGridConfig.new()

	cfg.format_mode = FormatMode.STANDARD
	cfg.tile_size = 32
	cfg.group_cols = 2
	cfg.group_rows = 5
	cfg.group_count = 6

	# 为每组生成屋顶和墙体两个区域
	cfg.regions = []
	for g: int in range(cfg.group_count):
		var gx: int = g * cfg.group_cols
		cfg.regions.append({
			"name": "屋顶-组%d" % g,
			"rect": Rect2i(gx, 0, cfg.group_cols, 3),  # 行0-2
			"type": RegionType.ROOF,
		})
		cfg.regions.append({
			"name": "墙体-组%d" % g,
			"rect": Rect2i(gx, 3, cfg.group_cols, 2),  # 行3-4
			"type": RegionType.WALL,
		})

	cfg.std_roof_single_coord = Vector2i(0, 0)
	cfg.std_roof_quad_coord  = Vector2i(1, 0)
	cfg.std_roof_tl_coord    = Vector2i(0, 1)
	cfg.std_roof_tr_coord    = Vector2i(1, 1)
	cfg.std_roof_bl_coord    = Vector2i(0, 2)
	cfg.std_roof_br_coord    = Vector2i(1, 2)
	cfg.std_wall_tl_coord    = Vector2i(0, 3)
	cfg.std_wall_tr_coord    = Vector2i(1, 3)
	cfg.std_wall_bl_coord    = Vector2i(0, 4)
	cfg.std_wall_br_coord    = Vector2i(1, 4)

	cfg._build_cache()
	return cfg


## 为标准 VX Ace A2 格式创建配置。
## 每组 2 列 × 3 行（64×96 px），可垂直堆叠 3 个动画帧。
## 默认配置为单组、单帧（无动画）。如需动画，手动扩展 group_rows。
## 参考：RM2K3_to_VX-Ace_图块转换分析.md 第3.1节
static func create_a2_config(group_count: int = 4, include_anim_frames: bool = false) -> VXGridConfig:
	var cfg := VXGridConfig.new()
	var TD = preload("res://addons/vx_tilemap/vx_tile_data.gd")

	cfg.format_mode = FormatMode.SIMPLIFIED  # A2 使用简化模式（完整 tile 查表）
	cfg.tile_size = 32
	cfg.group_cols = TD.A2_GROUP_COLS       # 2
	cfg.group_rows = TD.A2_GROUP_ROWS * (TD.A2_ANIM_FRAMES if include_anim_frames else 1)  # 3 or 9
	cfg.group_count = group_count

	# 为每组生成区域
	cfg.regions = []
	for g: int in range(group_count):
		var gx: int = g * cfg.group_cols
		cfg.regions.append({
			"name": "地面-组%d" % g,
			"rect": Rect2i(gx, 0, cfg.group_cols, cfg.group_rows),
			"type": RegionType.ROOF,  # A2 无屋顶/墙体之分，借用 ROOF 类型
		})

	# A2 的 bitmask 映射由 get_a2_local_coord() 在运行时计算，
	# 不在此处硬编码 roof_map/wall_map。
	# 调用方可通过 grid_config 的 roof_map 覆盖特定 bitmask 映射。

	cfg._build_cache()
	return cfg


func get_mapped_tile_count() -> int:
	return roof_map.size() + wall_map.size() + 1
