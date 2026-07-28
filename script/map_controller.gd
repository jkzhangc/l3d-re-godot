extends Node2D
## 地图测试场景控制器
##
## 功能：
##   - WASD/方向键 平移摄像头
##   - 鼠标滚轮 缩放
##   - 鼠标中键拖拽 平移
##   - 数字键 1-4 切换测试模式
##
## 依赖：
##   - TileMapLayer 子节点（底层 ground_layer + 上层 decor_layer）
##   - 预生成的 TileSet .tres 文件（使用 tileset_generator.gd 生成）

@onready var camera: Camera2D = $Camera2D
@onready var ground_layer: TileMapLayer = $GroundLayer
@onready var decor_layer: TileMapLayer = $DecorLayer

## 测试用的 TileSet 资源
@export var ground_tileset: TileSet   ## A5 或 A2 下层图块
@export var decor_tileset: TileSet    ## B/C/D/E 上层图块

@export var pan_speed: float = 600.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.25
@export var max_zoom: float = 4.0
@export var grid_size: Vector2i = Vector2i(30, 20)  ## 测试地图大小

var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _cam_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	if ground_tileset and ground_layer:
		ground_layer.tile_set = ground_tileset
	if decor_tileset and decor_layer:
		decor_layer.tile_set = decor_tileset
	_print_controls()


func _print_controls() -> void:
	print("=".repeat(50))
	print("  地图测试场景 — 控制说明")
	print("=".repeat(50))
	print("  WASD / 方向键 : 平移摄像头")
	print("  鼠标滚轮       : 缩放")
	print("  鼠标中键拖拽   : 平移")
	print("  数字键 1       : 随机填充底层（A5 地面）")
	print("  数字键 2       : 规则条纹测试")
	print("  数字键 3       : 清除地图")
	print("  数字键 4       : 填充指定行范围")
	print("=".repeat(50))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(-zoom_speed, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(zoom_speed, event.position)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_dragging = true
				_drag_start = event.position
				_cam_start = camera.position
			else:
				_dragging = false

	if event is InputEventMouseMotion and _dragging:
		var delta: Vector2 = event.position - _drag_start
		camera.position = _cam_start - delta / camera.zoom

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1: _test_fill_random_ground()
			KEY_2: _test_stripe_pattern()
			KEY_3: _clear_map()
			KEY_4: _test_fill_row_range(3, 8)


func _process(delta: float) -> void:
	var move_dir: Vector2 = Input.get_vector(
		"ui_left", "ui_right", "ui_up", "ui_down"
	)
	if move_dir != Vector2.ZERO:
		camera.position += move_dir * pan_speed * delta / camera.zoom


func _zoom_at(amount: float, screen_pos: Vector2) -> void:
	var old_zoom: Vector2 = camera.zoom
	var new_zoom: Vector2 = Vector2(
		clamp(old_zoom.x + amount, min_zoom, max_zoom),
		clamp(old_zoom.y + amount, min_zoom, max_zoom),
	)
	if new_zoom == old_zoom:
		return

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var world_before: Vector2 = camera.global_position + (screen_pos - viewport_size / 2) / old_zoom
	camera.zoom = new_zoom
	var world_after: Vector2 = camera.global_position + (screen_pos - viewport_size / 2) / new_zoom
	camera.position += world_before - world_after


# ═══════════════════════════════════════════════════════
#  测试模式 — 程序化放置图块示例
# ═══════════════════════════════════════════════════════

func _test_fill_random_ground() -> void:
	if not ground_layer or not ground_tileset:
		print("[错误] 未设置 ground_tileset")
		return

	var source_id: int = 0
	var source: TileSetAtlasSource = ground_tileset.get_source(source_id) as TileSetAtlasSource
	var cols: int = source.texture.get_width() / 32
	var rows: int = source.texture.get_height() / 32

	print("随机填充 %dx%d 地面 (图块范围 %dx%d)..." % [grid_size.x, grid_size.y, cols, rows])

	for y: int in grid_size.y:
		for x: int in grid_size.x:
			var tile_x: int = randi() % cols
			var tile_y: int = randi() % min(rows, 6)
			ground_layer.set_cell(Vector2i(x, y), source_id, Vector2i(tile_x, tile_y))

	print("  完成！已填充 %d 个图块" % (grid_size.x * grid_size.y))


func _test_stripe_pattern() -> void:
	if not ground_layer or not ground_tileset:
		print("[错误] 未设置 ground_tileset")
		return

	var source_id: int = 0
	var source: TileSetAtlasSource = ground_tileset.get_source(source_id) as TileSetAtlasSource
	var cols: int = source.texture.get_width() / 32
	var rows: int = source.texture.get_height() / 32

	print("条纹测试: 横向 = 不同 tile_x, 纵向 = 不同 tile_y")

	for y: int in grid_size.y:
		for x: int in grid_size.x:
			var tile_x: int = x % cols
			var tile_y: int = y % rows
			ground_layer.set_cell(Vector2i(x, y), source_id, Vector2i(tile_x, tile_y))

	print("  完成！每列不同 tile_x, 每行不同 tile_y")


func _test_fill_row_range(from_row: int, to_row: int) -> void:
	if not ground_layer or not ground_tileset:
		print("[错误] 未设置 ground_tileset")
		return

	var source_id: int = 0
	var source: TileSetAtlasSource = ground_tileset.get_source(source_id) as TileSetAtlasSource
	var total_rows: int = source.texture.get_height() / 32
	var clamped_from: int = clampi(from_row, 0, total_rows - 1)
	var clamped_to: int = clampi(to_row, clamped_from, total_rows - 1)

	print("填充 A5 行 %d~%d (共 %d 行)..." % [clamped_from, clamped_to, clamped_to - clamped_from + 1])

	for y: int in grid_size.y:
		for x: int in grid_size.x:
			var tile_y: int = randi() % (clamped_to - clamped_from + 1) + clamped_from
			var tile_x: int = (x + y * 7) % 8
			ground_layer.set_cell(Vector2i(x, y), source_id, Vector2i(tile_x, tile_y))

	print("  完成！")


func _clear_map() -> void:
	print("清除地图...")
	if ground_layer:
		ground_layer.clear()
	if decor_layer:
		decor_layer.clear()
	print("  已清除！")


# ═══════════════════════════════════════════════════════
#  实用方法 — 可在其他脚本中调用
# ═══════════════════════════════════════════════════════

func place_tile(layer: TileMapLayer, pos: Vector2i, atlas_coords: Vector2i,
		source_id: int = 0) -> void:
	layer.set_cell(pos, source_id, atlas_coords)


func fill_rect(layer: TileMapLayer, rect: Rect2i, atlas_coords: Vector2i,
		source_id: int = 0) -> void:
	for y: int in range(rect.position.y, rect.position.y + rect.size.y):
		for x: int in range(rect.position.x, rect.position.x + rect.size.x):
			layer.set_cell(Vector2i(x, y), source_id, atlas_coords)


func get_tile_at(layer: TileMapLayer, pos: Vector2i) -> Dictionary:
	var cell: Vector2i = layer.get_cell_atlas_coords(pos)
	var source: int = layer.get_cell_source_id(pos)
	return {"source_id": source, "atlas_coords": cell}
