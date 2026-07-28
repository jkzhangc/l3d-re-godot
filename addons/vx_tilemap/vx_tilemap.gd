@tool
class_name VXTileMap extends Node2D
## VX Ace autotile map node — A4 walls with 16x16 subtile composition

const _TD = preload("res://addons/vx_tilemap/vx_tile_data.gd")
const _AT = preload("res://addons/vx_tilemap/vx_autotile.gd")


# ═══════════════════════════════════════
# Export params
# ═══════════════════════════════════════

@export_group("Tile Sheet")
@export var tile_sheet: Texture2D:
	set(v):
		tile_sheet = v
		queue_redraw()
@export var tile_group: int = 3

@export_group("Map")
@export var map_size: Vector2i = Vector2i(30, 20):
	set(v):
		map_size = v
		queue_redraw()
@export var tile_size: int = 32:
	set(v):
		tile_size = v
		queue_redraw()
@export var draw_grid: bool = false:
	set(v):
		draw_grid = v
		queue_redraw()

@export_group("Autotile")
@export var use_standard_format: bool = false
@export var autotile_group_index: int = 0
@export var autotile_terrain_id: int = 0
## 可视化网格配置 — 为 null 时使用硬编码映射回退
@export var grid_config: VXGridConfig = null:
	set(v):
		grid_config = v
		if grid_config:
			grid_config.ensure_cache()
		queue_redraw()


# ═══════════════════════════════════════
# Map data
# ═══════════════════════════════════════

@export var map_data: Dictionary = {}:
	set(v):
		map_data = v
		queue_redraw()


# ═══════════════════════════════════════
# Editor hover
# ═══════════════════════════════════════

var editor_hover_cell: Vector2i = Vector2i(-1, -1):
	set(v):
		editor_hover_cell = v
		queue_redraw()
var editor_preview_terrain: int = 1


# ═══════════════════════════════════════
# Public API
# ═══════════════════════════════════════

func set_cell(pos: Vector2i, terrain_id: int = 1) -> void:
	map_data[pos] = terrain_id
	queue_redraw()


func erase_cell(pos: Vector2i) -> void:
	map_data.erase(pos)
	queue_redraw()


func get_cell(pos: Vector2i) -> int:
	return map_data.get(pos, 0)


func has_cell(pos: Vector2i) -> bool:
	return map_data.has(pos)


func clear() -> void:
	map_data.clear()
	queue_redraw()


func fill_rect(rect: Rect2i, terrain_id: int = 1) -> void:
	for y: int in range(rect.position.y, rect.position.y + rect.size.y):
		for x: int in range(rect.position.x, rect.position.x + rect.size.x):
			map_data[Vector2i(x, y)] = terrain_id
	queue_redraw()


# ═══════════════════════════════════════
# Render
# ═══════════════════════════════════════

func _draw() -> void:
	var ts: int = tile_size

	# 确定使用的纹理（grid_config 优先于 tile_sheet）
	var use_cfg: bool = grid_config != null and grid_config.source_texture != null
	var draw_tex: Texture2D = grid_config.source_texture if use_cfg else tile_sheet
	if not draw_tex:
		return

	for pos: Vector2i in map_data.keys():
		var tid: int = map_data[pos]
		if tid <= 0:
			continue

		var neighbors: Array = _build_neighbor_grid(pos, tid)
		var bitmask: int = _TD.calc_bitmask(neighbors)
		var has_above: bool = neighbors[0][1]
		var has_below: bool = neighbors[2][1]

		if tile_group == 3 and use_standard_format:
			# A4 standard: 16x16 subtile composition
			var group_origin: Vector2i
			if use_cfg and grid_config.format_mode == 1:  # STANDARD mode
				group_origin = grid_config.get_group_origin(autotile_group_index)
			else:
				group_origin = _TD.get_a4_group_origin(autotile_group_index)
			var subtiles: Array[Rect2i] = _AT.get_a4_subtiles(group_origin, bitmask, has_above, has_below)
			var dst := Vector2(pos) * ts
			var hs := ts / 2
			draw_texture_rect_region(draw_tex, Rect2(dst, Vector2(hs, hs)), subtiles[0])
			draw_texture_rect_region(draw_tex, Rect2(dst + Vector2(hs, 0), Vector2(hs, hs)), subtiles[1])
			draw_texture_rect_region(draw_tex, Rect2(dst + Vector2(0, hs), Vector2(hs, hs)), subtiles[2])
			draw_texture_rect_region(draw_tex, Rect2(dst + Vector2(hs, hs), Vector2(hs, hs)), subtiles[3])
		else:
			# Simplified: full 32x32 tile
			var src_rect: Rect2i
			if use_cfg:
				src_rect = grid_config.get_source_rect(bitmask, not has_above)
			else:
				src_rect = _AT.get_source_rect(tile_group, bitmask, has_above, has_below)
			var dst := Vector2(pos) * ts
			draw_texture_rect_region(draw_tex, Rect2(dst, Vector2(ts, ts)), src_rect)

	# Grid overlay
	if draw_grid:
		var gc := Color(1, 1, 1, 0.15)
		for x: int in range(0, map_size.x + 1):
			draw_line(Vector2(x * ts, 0), Vector2(x * ts, map_size.y * ts), gc, 0.5)
		for y: int in range(0, map_size.y + 1):
			draw_line(Vector2(0, y * ts), Vector2(map_size.x * ts, y * ts), gc, 0.5)

	# Editor cursor
	if Engine.is_editor_hint() and editor_hover_cell.x >= 0:
		var pv := Vector2(editor_hover_cell) * ts
		draw_rect(Rect2(pv, Vector2(ts, ts)), Color(1, 1, 1, 0.3), false, 2.0)


# ═══════════════════════════════════════
# Internal
# ═══════════════════════════════════════

func _build_neighbor_grid(pos: Vector2i, terrain_id: int) -> Array:
	var grid: Array = []
	for dy: int in range(-1, 2):
		var row: Array = []
		for dx: int in range(-1, 2):
			var np := pos + Vector2i(dx, dy)
			row.append(map_data.get(np, 0) == terrain_id)
		grid.append(row)
	return grid
