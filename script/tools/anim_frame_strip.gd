extends Control

## ── 架构定位 ──
## 系统：动画编辑器 ｜ 层：工具（帧条控件）
## 联机：不涉及
## 职责：像 RMVX Ace 的动画编辑器那样，把「帧」画成一排缩略图：
##       点击选中、左右拖动排序、右键弹帧菜单、播放时高亮当前帧。
## 依赖：无（纯 Control 自绘），由 `script/tools/anim_editor.gd` 驱动。

signal frame_selected(idx: int)
signal frame_reordered(from_idx: int, to_idx: int)
signal frame_menu_requested(idx: int, screen_pos: Vector2)

const THUMB := 58.0
const GAP := 6.0
const PAD := 6.0

const C_BG := Color(0.075, 0.075, 0.085, 1.0)
const C_CELL_BG := Color(0.12, 0.12, 0.14, 1.0)
const C_BORDER := Color(1, 1, 1, 0.38)
const C_SELECTED := Color(1.0, 0.82, 0.15, 1.0)
const C_PLAYING := Color(0.3, 1.0, 0.5, 1.0)
const C_TEXT := Color(1, 1, 1, 0.75)
const C_DROP := Color(0.35, 0.75, 1.0, 1.0)

var sheet: Texture2D = null
var h_frames: int = 5
var v_frames: int = 0
var sequence: Array[int] = []
var selected: int = 0
var playing: bool = false
## 播放中当前帧（由编辑器逐帧更新；-1 = 不画播放高亮）
var playing_index: int = -1

var _hover: int = -1
var _drag_from: int = -1
var _drag_to: int = -1
var _dragging: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = THUMB + PAD * 2.0


func refresh() -> void:
	custom_minimum_size.x = maxf(1.0, _content_width())
	queue_redraw()


func _content_width() -> float:
	return PAD * 2.0 + maxi(0, sequence.size()) * (THUMB + GAP)


func _slot_rect(i: int) -> Rect2:
	return Rect2(Vector2(PAD + float(i) * (THUMB + GAP), PAD), Vector2(THUMB, THUMB))


func _index_at(pos: Vector2) -> int:
	if sequence.is_empty():
		return -1
	var i: int = int((pos.x - PAD) / (THUMB + GAP))
	if i < 0 or i >= sequence.size():
		return -1
	return i


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG, true)
	var font: Font = ThemeDB.fallback_font
	if sequence.is_empty():
		draw_string(font, Vector2(PAD, 26), "（还没有帧：点「＋ 添加帧」或「按格子重建序列」）",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, C_TEXT)
		return
	for i: int in range(sequence.size()):
		var r := _slot_rect(i)
		draw_rect(r, C_CELL_BG, true)
		draw_texture_region(sequence[i], r)
		var border: Color = C_BORDER
		var width: float = 1.0
		if i == selected:
			border = C_SELECTED
			width = 2.0
		elif playing and i == playing_index:
			border = C_PLAYING
			width = 2.0
		draw_rect(r, border, false, width)
		draw_string(font, r.position + Vector2(3, 12), str(i + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_TEXT)
		if _dragging and i == _drag_to and _drag_from >= 0:
			draw_rect(Rect2(r.position + Vector2(-3, 0), Vector2(3, r.size.y)), C_DROP, true)


func draw_texture_region(pattern: int, into: Rect2) -> void:
	if sheet == null or pattern < 0:
		return
	var tex_size := Vector2(sheet.get_size())
	var rows: int = v_frames if v_frames > 0 else maxi(1, int(ceil(tex_size.y / 192.0)))
	var cell := Vector2(tex_size.x / float(maxi(1, h_frames)), tex_size.y / float(rows))
	var col: int = pattern % maxi(1, h_frames)
	var row: int = pattern / maxi(1, h_frames)
	var src := Rect2(Vector2(float(col) * cell.x, float(row) * cell.y), cell)
	## 等比缩进缩略图，别把非正方形格子拉扁。
	var s: float = minf(into.size.x / maxf(cell.x, 1.0), into.size.y / maxf(cell.y, 1.0))
	var dst_size: Vector2 = cell * s
	var dst := Rect2(into.position + (into.size - dst_size) * 0.5, dst_size)
	draw_texture_rect_region(sheet, dst, src)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag_from >= 0 and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var to: int = _index_at(mm.position)
			if to >= 0:
				_dragging = true
				_drag_to = to
				queue_redraw()
		else:
			var h: int = _index_at(mm.position)
			if h != _hover:
				_hover = h
				queue_redraw()
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		var ri: int = _index_at(mb.position)
		if ri >= 0:
			selected = ri
			queue_redraw()
			frame_menu_requested.emit(ri, get_screen_position() + mb.position)
			accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		var i: int = _index_at(mb.position)
		if i >= 0:
			selected = i
			_drag_from = i
			_drag_to = i
			_dragging = false
			queue_redraw()
			frame_selected.emit(i)
			accept_event()
	else:
		if _drag_from >= 0:
			if _dragging and _drag_to != _drag_from:
				frame_reordered.emit(_drag_from, _drag_to)
			_drag_from = -1
			_drag_to = -1
			_dragging = false
			queue_redraw()
			accept_event()
