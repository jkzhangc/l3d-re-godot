extends Node2D
## 即时图块可视化器 — 无需预生成 TileSet 即可浏览图块素材
##
## 功能：
##   - 将任意 VX Ace 图块图片按 32×32 网格绘制
##   - 鼠标滚轮缩放，中键拖拽平移
##   - 鼠标悬停高亮当前 tile，点击打印 tile 坐标
##   - 适合快速浏览图块素材、确定 tile_x/tile_y
##
## 使用方法：
##   1. 在检查器中设置 tileset_texture
##   2. 运行场景
##   3. 滚轮缩放，中键拖拽，点击查看 tile 编号

@export var tileset_texture: Texture2D:
	set(v):
		tileset_texture = v
		if tileset_texture:
			_calc_grid()
			queue_redraw()

@export var tile_size: int = 32
@export var show_grid: bool = true
@export var show_coords: bool = true
@export var highlight_hover: bool = true
@export var grid_color: Color = Color(1, 1, 1, 0.15)
@export var highlight_color: Color = Color(1, 1, 0, 0.35)

var _cols: int = 0
var _rows: int = 0
var _hover_tile: Vector2i = Vector2i(-1, -1)
var _zoom: float = 1.0
var _pan: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _pan_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	if tileset_texture:
		_calc_grid()
	print("图块可视化器就绪 — 滚轮缩放 | 中键拖拽 | 点击查看 tile 坐标")


func _calc_grid() -> void:
	if tileset_texture:
		_cols = tileset_texture.get_width() / tile_size
		_rows = tileset_texture.get_height() / tile_size


func _draw() -> void:
	if not tileset_texture:
		_draw_placeholder()
		return

	var src_rect: Rect2 = Rect2(0, 0, tileset_texture.get_width(), tileset_texture.get_height())
	draw_texture_rect(tileset_texture, src_rect, false)

	# 网格线
	if show_grid:
		for x: int in range(1, _cols):
			var line_x: int = x * tile_size
			draw_line(Vector2(line_x, 0), Vector2(line_x, tileset_texture.get_height()),
				grid_color, 1.0)
		for y: int in range(1, _rows):
			var line_y: int = y * tile_size
			draw_line(Vector2(0, line_y), Vector2(tileset_texture.get_width(), line_y),
				grid_color, 1.0)

	# 高亮悬停的 tile
	if highlight_hover and _hover_tile.x >= 0 and _hover_tile.x < _cols \
			and _hover_tile.y >= 0 and _hover_tile.y < _rows:
		var hl_rect: Rect2 = Rect2(
			_hover_tile.x * tile_size, _hover_tile.y * tile_size,
			tile_size, tile_size
		)
		draw_rect(hl_rect, highlight_color, true)
		draw_rect(hl_rect, Color.YELLOW, false, 2.0)

	# 坐标标注
	if show_coords and _zoom > 0.5:
		var font: Font = ThemeDB.fallback_font
		var font_size: int = max(10, int(12 / _zoom))
		for y: int in _rows:
			for x: int in _cols:
				var label: String = "%d,%d" % [x, y]
				var pos: Vector2 = Vector2(x * tile_size + 4, y * tile_size + 16)
				draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
					Color(1, 1, 1, 0.5))


func _draw_placeholder() -> void:
	var rect: Rect2 = Rect2(0, 0, 512, 512)
	draw_rect(rect, Color(0.2, 0.2, 0.2, 1), true)
	draw_rect(rect, Color.RED, false, 2.0)
	var font: SystemFont = ThemeDB.fallback_font
	draw_string(font, Vector2(160, 248), "请在检查器中设置 tileset_texture！",
		HORIZONTAL_ALIGNMENT_CENTER, -1, 16, Color.RED)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clamp(_zoom * 1.15, 0.1, 8.0)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clamp(_zoom / 1.15, 0.1, 8.0)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_dragging = true
				_drag_start = event.position
				_pan_start = _pan
			else:
				_dragging = false
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_print_tile_at(event.position)

	if event is InputEventMouseMotion:
		if _dragging:
			var delta: Vector2 = event.position - _drag_start
			_pan = _pan_start + delta
			queue_redraw()
		else:
			_update_hover(event.position)


func _update_hover(screen_pos: Vector2) -> void:
	var tex_pos: Vector2 = (screen_pos - _pan) / _zoom
	var tx: int = int(tex_pos.x / tile_size)
	var ty: int = int(tex_pos.y / tile_size)
	var new_hover: Vector2i = Vector2i(tx, ty)
	if new_hover != _hover_tile:
		_hover_tile = new_hover
		queue_redraw()


func _print_tile_at(screen_pos: Vector2) -> void:
	var tex_pos: Vector2 = (screen_pos - _pan) / _zoom
	var tx: int = int(tex_pos.x / tile_size)
	var ty: int = int(tex_pos.y / tile_size)

	if tx < 0 or tx >= _cols or ty < 0 or ty >= _rows:
		print("点击位置超出图块范围")
		return

	print("图块坐标: (%d, %d)  —  AtlasCoords: Vector2i(%d, %d)" % [tx, ty, tx, ty])


func _process(_delta: float) -> void:
	scale = Vector2(_zoom, _zoom)
	position = _pan
