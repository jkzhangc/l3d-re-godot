extends Control

## ── 架构定位 ──
## 系统：动画编辑器 ｜ 层：工具（独立运行场景的控件）
## 联机：不涉及
## 职责：把 VX 动画精灵表画成可点选的格子；序列中的格子标绿、当前播放帧标黄。
## 依赖：无（纯 Control 自绘），由 `script/tools/anim_editor.gd` 创建与驱动。
##
## 【为什么单独成文件】格子换算（纹理 → 行列 → pattern 索引）与命中测试只此一份，
## 编辑器只关心「点到了第几格」；将来换布局也不用改编辑器主逻辑。

signal pattern_clicked(pattern: int)

const C_BG := Color(0.075, 0.075, 0.085, 1.0)
const C_GRID := Color(1, 1, 1, 0.16)
const C_GRID_OUTER := Color(1, 1, 1, 0.30)
const C_ARMED := Color(0.25, 0.9, 1.0, 0.22)
const C_ARMED_BORDER := Color(0.3, 0.95, 1.0, 0.95)
const C_ACTIVE := Color(1.0, 0.82, 0.15, 0.32)
const C_HOVER := Color(1, 1, 1, 0.10)
const C_ACTIVE_BORDER := Color(1.0, 0.85, 0.2, 0.95)
const C_LABEL := Color(1, 1, 1, 0.55)
const C_HINT := Color(0.65, 0.68, 0.72, 1.0)

## 默认格子尺寸（VX Ace 标准 192×192；仅用于推算行数）
const DEFAULT_CELL := 192.0

var texture: Texture2D = null
var h_frames: int = 5
var v_frames: int = 0
var active_pattern: int = -1
## 多格模式下「待放置」的图案（青色框）
var armed_pattern: int = -1
var zoom: float = 1.0

var _hover: int = -1
var _rows: int = 1
var _cell: Vector2 = Vector2(DEFAULT_CELL, DEFAULT_CELL)
var _draw_scale: float = 1.0
var _draw_origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true


## 外部数据变了 → 重画。
func refresh() -> void:
	queue_redraw()


func total_cells() -> int:
	## 不依赖 _draw 是否跑过：按纹理与 v_frames 现算行数。
	var rows: int = _rows
	if texture != null:
		rows = v_frames if v_frames > 0 else maxi(1, int(ceil(float(texture.get_height()) / DEFAULT_CELL)))
	return maxi(1, maxi(1, h_frames) * rows)


## 屏幕坐标 → pattern 索引；点在外面返回 -1。
func pattern_at(pos: Vector2) -> int:
	if texture == null:
		return -1
	var local: Vector2 = (pos - _draw_origin) / maxf(_draw_scale, 0.001)
	if local.x < 0.0 or local.y < 0.0:
		return -1
	var col: int = int(local.x / _cell.x)
	var row: int = int(local.y / _cell.y)
	if col < 0 or col >= h_frames or row < 0 or row >= _rows:
		return -1
	return row * h_frames + col


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 1.12, 0.25, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom / 1.12, 0.25, 6.0)
			queue_redraw()
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var idx: int = pattern_at(mb.position)
			if idx >= 0:
				pattern_clicked.emit(idx)
			accept_event()
	elif event is InputEventMouseMotion:
		var idx2: int = pattern_at((event as InputEventMouseMotion).position)
		if idx2 != _hover:
			_hover = idx2
			queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG, true)
	var font: Font = ThemeDB.fallback_font
	if texture == null:
		draw_string(font, Vector2(16, 28), "未加载精灵表（右侧「贴图」选择 PNG）",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_HINT)
		return

	_compute_layout()
	var tex_size := Vector2(texture.get_size())
	draw_texture_rect(texture, Rect2(_draw_origin, tex_size * _draw_scale), false)

	for row: int in range(_rows):
		for col: int in range(h_frames):
			var idx: int = row * h_frames + col
			var rect := Rect2(
				_draw_origin + Vector2(float(col) * _cell.x, float(row) * _cell.y) * _draw_scale,
				_cell * _draw_scale)
			if idx == armed_pattern:
				draw_rect(rect, C_ARMED, true)
				draw_rect(rect.grow(-1.0), C_ARMED_BORDER, false, 2.0)
			if idx == active_pattern:
				draw_rect(rect, C_ACTIVE, true)
			if idx == _hover:
				draw_rect(rect, C_HOVER, true)
			draw_rect(rect, C_GRID, false, 1.0)
			var label_pos: Vector2 = rect.position + Vector2(4, 15)
			draw_string(font, label_pos, str(idx), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_LABEL)
			if idx == active_pattern:
				draw_rect(rect.grow(-1.0), C_ACTIVE_BORDER, false, 2.0)

	# 整张表的外框
	draw_rect(Rect2(_draw_origin, tex_size * _draw_scale), C_GRID_OUTER, false, 1.0)


func _compute_layout() -> void:
	var tex_size := Vector2(texture.get_size())
	_rows = v_frames if v_frames > 0 else maxi(1, int(ceil(tex_size.y / DEFAULT_CELL)))
	h_frames = maxi(1, h_frames)
	_cell = Vector2(tex_size.x / float(h_frames), tex_size.y / float(_rows))
	var pad: float = 14.0
	var fit: float = minf(
		(size.x - pad * 2.0) / maxf(tex_size.x, 1.0),
		(size.y - pad * 2.0) / maxf(tex_size.y, 1.0))
	_draw_scale = maxf(0.02, fit * zoom)
	_draw_origin = (size - tex_size * _draw_scale) * 0.5
