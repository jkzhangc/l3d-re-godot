extends Control

## ── 架构定位 ──
## 系统：动画编辑器 ｜ 层：工具（帧视图的 cell 覆盖层）
## 联机：不涉及
## 职责：在预览画面上画出当前帧的 cell 边框/序号，并处理选中、拖动、右击菜单——
##       对齐 RPG Maker VX Ace 帧视图的交互（白框=选中，红框=已放置，数字=层级）。
## 依赖：VXAnimCellData（数据结构），由 `script/tools/anim_editor.gd` 驱动。

signal cell_selected(idx: int)
signal cell_moved(idx: int)
signal cell_menu_requested(idx: int, screen_pos: Vector2)
signal empty_clicked(local_pos: Vector2)
signal empty_menu_requested(local_pos: Vector2, screen_pos: Vector2)

const C_SELECTED := Color(1, 1, 1, 0.95)
const C_PLACED := Color(1.0, 0.35, 0.35, 0.85)
const C_NUMBER := Color(1, 1, 1, 0.9)
const C_CENTER := Color(0.35, 0.9, 1.0, 0.5)

## 当前帧的 cell（VXAnimCellData 引用，顺序 = 绘制/层级顺序，后面的在上层）
var cells: Array = []
var selected: int = -1
## 预览中心在本地坐标里的位置（由编辑器按视口尺寸写入）
var center: Vector2 = Vector2.ZERO
## 单个 cell 的基准尺寸（192×192，已乘动画整体缩放）
var cell_size: Vector2 = Vector2(192, 192)
## 是否允许放置（多格模式）
var placing: bool = false

var _drag_idx: int = -1
var _drag_start: Vector2 = Vector2.ZERO
var _drag_origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func refresh() -> void:
	queue_redraw()


func _cell_rect(cell) -> Rect2:
	var sc: Vector2 = cell.scale if cell.scale.x > 0.0 else Vector2.ONE
	var sz: Vector2 = Vector2(cell_size.x * sc.x, cell_size.y * sc.y)
	var c: Vector2 = center + Vector2(cell.offset)
	return Rect2(c - sz * 0.5, sz)


func cell_index_at(pos: Vector2) -> int:
	for i: int in range(cells.size() - 1, -1, -1):
		if _cell_rect(cells[i]).has_point(pos):
			return i
	return -1


func _draw() -> void:
	## 中心十字：cell 坐标 (0,0) 的位置
	draw_line(center + Vector2(-10, 0), center + Vector2(10, 0), C_CENTER, 1.0)
	draw_line(center + Vector2(0, -10), center + Vector2(0, 10), C_CENTER, 1.0)

	var font: Font = ThemeDB.fallback_font
	for i: int in range(cells.size()):
		var cell = cells[i]
		var r: Rect2 = _cell_rect(cell)
		var col: Color = C_SELECTED if i == selected else C_PLACED
		draw_rect(r, col, false, 1.5 if i == selected else 1.0)
		## 序号 = 层级（越大越靠前）
		draw_string(font, r.position + Vector2(3, 14), str(i + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_NUMBER)
		if i == selected:
			## 选中框四角加粗，和 VA 的白框对应
			var corner: float = 10.0
			draw_line(r.position, r.position + Vector2(corner, 0), C_SELECTED, 2.0)
			draw_line(r.position, r.position + Vector2(0, corner), C_SELECTED, 2.0)
			draw_line(r.position + Vector2(r.size.x, 0), r.position + Vector2(r.size.x - corner, 0), C_SELECTED, 2.0)
			draw_line(r.position + Vector2(r.size.x, 0), r.position + Vector2(r.size.x, corner), C_SELECTED, 2.0)
			draw_line(r.position + Vector2(0, r.size.y), r.position + Vector2(corner, r.size.y), C_SELECTED, 2.0)
			draw_line(r.position + Vector2(0, r.size.y), r.position + Vector2(0, r.size.y - corner), C_SELECTED, 2.0)
			draw_line(r.position + r.size, r.position + r.size - Vector2(corner, 0), C_SELECTED, 2.0)
			draw_line(r.position + r.size, r.position + r.size - Vector2(0, corner), C_SELECTED, 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var idx: int = cell_index_at(mb.position)
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if idx >= 0:
				selected = idx
				queue_redraw()
				cell_menu_requested.emit(idx, Vector2(DisplayServer.mouse_get_position()))
			elif placing:
				empty_menu_requested.emit(mb.position, Vector2(DisplayServer.mouse_get_position()))
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if idx >= 0:
				selected = idx
				_drag_idx = idx
				_drag_start = mb.position
				_drag_origin = Vector2(cells[idx].offset)
				queue_redraw()
				cell_selected.emit(idx)
			elif placing:
				empty_clicked.emit(mb.position)
			accept_event()
		else:
			if _drag_idx >= 0:
				_drag_idx = -1
				accept_event()
		return

	if event is InputEventMouseMotion and _drag_idx >= 0:
		var mm := event as InputEventMouseMotion
		if not (mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_drag_idx = -1
			return
		var delta: Vector2 = mm.position - _drag_start
		## VA：默认 8px 步进，按住 Alt 变 2px
		var step: float = 2.0 if mm.alt_pressed else 8.0
		var snapped: Vector2 = (delta / step).round() * step
		cells[_drag_idx].offset = _drag_origin + snapped
		queue_redraw()
		cell_moved.emit(_drag_idx)
		accept_event()
