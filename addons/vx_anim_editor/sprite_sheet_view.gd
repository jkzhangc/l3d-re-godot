@tool
class_name VXAnimSheetView extends Control
## 精灵表网格视图 — 独立 Control，通过 _draw() 渲染
##
## 数据由外部设置（不直接引用 panel），通过 signal 通信


# ═══════════════════════════════════════
# 可从外部设置的渲染数据
# ═══════════════════════════════════════

var sheet_texture: Texture2D = null
var sheet_h_frames: int = 5
var sheet_v_frames: int = 0
var sheet_cell_size: Vector2 = Vector2(192, 192)
var sheet_frame_sequence: Array[int] = []
var sheet_selected_idx: int = -1
var sheet_hover_cell: Vector2i = Vector2i(-1, -1)
var sheet_preview_idx: int = -1
var sheet_playing: bool = false

var grid_zoom: float = 1.0
var grid_scroll: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# 颜色
# ═══════════════════════════════════════

const COLOR_GRID := Color(1, 1, 1, 0.25)
const COLOR_HOVER := Color(1, 0.8, 0, 0.6)
const COLOR_SELECTED := Color(0.3, 0.8, 1, 0.7)
const COLOR_SEQUENCE := Color(0.3, 1, 0.5, 0.55)
const COLOR_SEQUENCE_ACTIVE := Color(0.1, 1, 0.3, 0.8)
const COLOR_BG := Color(0.15, 0.15, 0.15, 1)

# ═══════════════════════════════════════
# 交互状态
# ═══════════════════════════════════════

var _drag_active: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _scroll_start: Vector2 = Vector2.ZERO

# ═══════════════════════════════════════
# Signals
# ═══════════════════════════════════════

signal cell_clicked(pattern: int)
signal cell_right_clicked(pattern: int)
signal cell_hovered(pattern: int)
signal cell_unhovered()


# ═══════════════════════════════════════
# _draw
# ═══════════════════════════════════════

func _draw() -> void:
	var sz: Vector2 = size

	# 背景
	draw_rect(Rect2(Vector2.ZERO, sz), COLOR_BG)

	if not sheet_texture:
		return

	var cols: int = sheet_h_frames
	var vf: int = sheet_v_frames if sheet_v_frames > 0 else maxi(1, int(ceil(float(sheet_texture.get_height()) / sheet_cell_size.y)))
	var rows: int = vf

	var tex_size: Vector2 = Vector2(sheet_texture.get_width(), sheet_texture.get_height()) * grid_zoom
	var tex_pos: Vector2 = (sz - tex_size) / 2.0 + grid_scroll

	# 纹理
	draw_texture_rect(sheet_texture, Rect2(tex_pos, tex_size), false)

	# 网格
	var cell_w: float = tex_size.x / float(cols)
	var cell_h: float = tex_size.y / float(rows)

	for c in range(cols + 1):
		var x: float = tex_pos.x + float(c) * cell_w
		draw_line(Vector2(x, tex_pos.y), Vector2(x, tex_pos.y + tex_size.y), COLOR_GRID)
	for r in range(rows + 1):
		var y: float = tex_pos.y + float(r) * cell_h
		draw_line(Vector2(tex_pos.x, y), Vector2(tex_pos.x + tex_size.x, y), COLOR_GRID)

	# 帧序列叠加
	var seq_set: Dictionary = {}
	for i in range(sheet_frame_sequence.size()):
		var pat: int = sheet_frame_sequence[i]
		if not seq_set.has(pat):
			seq_set[pat] = []
		seq_set[pat].append(i)

	var seq_font: Font = get_theme_default_font()
	for pat in seq_set:
		var col: int = pat % cols
		var row: int = pat / cols
		var rx: float = tex_pos.x + float(col) * cell_w
		var ry: float = tex_pos.y + float(row) * cell_h

		var is_active: bool = false
		for si in seq_set[pat]:
			if si == sheet_selected_idx:
				is_active = true
				break

		draw_rect(Rect2(rx + 1, ry + 1, cell_w - 2, cell_h - 2),
			COLOR_SEQUENCE_ACTIVE if is_active else COLOR_SEQUENCE)

		# 居中半透明帧号
		var indices: Array = seq_set[pat]
		var label: String = ""
		for idx2 in indices:
			if label != "":
				label += ","
			label += str(idx2)
		if seq_font and label != "":
			var str_size: Vector2 = seq_font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
			var str_x: float = rx + (cell_w - str_size.x) / 2.0
			var str_y: float = ry + (cell_h + str_size.y) / 2.0
			draw_string(seq_font, Vector2(str_x, str_y), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.55))

	# 悬停高亮
	var hc: Vector2i = sheet_hover_cell
	if hc.x >= 0 and hc.y >= 0 and hc.x < cols and hc.y < rows:
		var hx: float = tex_pos.x + float(hc.x) * cell_w
		var hy: float = tex_pos.y + float(hc.y) * cell_h
		draw_rect(Rect2(hx, hy, cell_w, cell_h), COLOR_HOVER, false, 2.0)

	# 选中帧高亮
	if sheet_selected_idx >= 0 and sheet_selected_idx < sheet_frame_sequence.size():
		var pat: int = sheet_frame_sequence[sheet_selected_idx]
		var col: int = pat % cols
		var row: int = pat / cols
		var sx: float = tex_pos.x + float(col) * cell_w
		var sy: float = tex_pos.y + float(row) * cell_h
		draw_rect(Rect2(sx, sy, cell_w, cell_h), COLOR_SELECTED, false, 2.5)

	# 预览帧高亮（播放中 — 橙色）
	if sheet_playing and sheet_preview_idx >= 0 and sheet_preview_idx < sheet_frame_sequence.size():
		var pat: int = sheet_frame_sequence[sheet_preview_idx]
		var col: int = pat % cols
		var row: int = pat / cols
		var px: float = tex_pos.x + float(col) * cell_w
		var py: float = tex_pos.y + float(row) * cell_h
		draw_rect(Rect2(px, py, cell_w, cell_h), Color(1, 0.85, 0, 0.8), false, 3.0)

		# 预览大图
		var ppw: float = 96.0
		var pph: float = 96.0
		var pmargin: float = 8.0
		var ppos_x: float = tex_pos.x + tex_size.x - ppw - pmargin
		var ppos_y: float = tex_pos.y + tex_size.y - pph - pmargin
		draw_rect(Rect2(ppos_x - 2, ppos_y - 2, ppw + 4, pph + 4), Color(0, 0, 0, 0.75))
		draw_rect(Rect2(ppos_x, ppos_y, ppw, pph), Color(1, 0.85, 0, 0.5), false, 2.0)
		var src_rect := Rect2(col * sheet_cell_size.x, row * sheet_cell_size.y, sheet_cell_size.x, sheet_cell_size.y)
		draw_texture_rect_region(sheet_texture, Rect2(ppos_x, ppos_y, ppw, pph), src_rect)

	# 边界
	draw_rect(Rect2(tex_pos, tex_size), Color(1, 1, 1, 0.3), false, 1.0)


# ═══════════════════════════════════════
# 自动适配
# ═══════════════════════════════════════

func fit_to_view() -> void:
	## 自动缩放使纹理适配当前视图
	if not sheet_texture:
		return
	var sz: Vector2 = size
	if sz.x <= 0 or sz.y <= 0:
		return
	var tw: float = float(sheet_texture.get_width())
	var th: float = float(sheet_texture.get_height())
	var fit_zoom: float = minf((sz.x - 40) / tw, (sz.y - 40) / th)
	grid_zoom = clampf(fit_zoom, 0.1, 2.0)
	grid_scroll = Vector2.ZERO
	queue_redraw()


# ═══════════════════════════════════════
# 输入处理
# ═══════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if not sheet_texture:
		return

	var sz: Vector2 = size
	var tex_size: Vector2 = Vector2(sheet_texture.get_width(), sheet_texture.get_height()) * grid_zoom
	var tex_pos: Vector2 = (sz - tex_size) / 2.0 + grid_scroll

	var cols: int = sheet_h_frames
	var vf: int = sheet_v_frames if sheet_v_frames > 0 else maxi(1, int(ceil(float(sheet_texture.get_height()) / sheet_cell_size.y)))
	var rows: int = vf
	var cell_w: float = tex_size.x / float(cols)
	var cell_h: float = tex_size.y / float(rows)

	var hover_changed: bool = false

	if event is InputEventMouseMotion:
		var mp: Vector2 = event.position
		if mp.x >= tex_pos.x and mp.x < tex_pos.x + tex_size.x and mp.y >= tex_pos.y and mp.y < tex_pos.y + tex_size.y:
			var col: int = int((mp.x - tex_pos.x) / cell_w)
			var row: int = int((mp.y - tex_pos.y) / cell_h)
			var new_hover := Vector2i(col, row)
			if new_hover != sheet_hover_cell:
				sheet_hover_cell = new_hover
				hover_changed = true
				cell_hovered.emit(row * cols + col)
		else:
			if sheet_hover_cell.x >= 0:
				sheet_hover_cell = Vector2i(-1, -1)
				hover_changed = true
				cell_unhovered.emit()

		if _drag_active and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			grid_scroll = _scroll_start + (event.position - _drag_start)

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.ctrl_pressed:
			grid_zoom = minf(grid_zoom * 1.2, 8.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.ctrl_pressed:
			grid_zoom = maxf(grid_zoom / 1.2, 0.1)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_drag_active = true
			_drag_start = event.position
			_scroll_start = grid_scroll
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if sheet_hover_cell.x >= 0 and sheet_hover_cell.y >= 0 and sheet_hover_cell.x < cols and sheet_hover_cell.y < rows:
				var pat: int = sheet_hover_cell.y * cols + sheet_hover_cell.x
				cell_clicked.emit(pat)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if sheet_hover_cell.x >= 0 and sheet_hover_cell.y >= 0 and sheet_hover_cell.x < cols and sheet_hover_cell.y < rows:
				var pat: int = sheet_hover_cell.y * cols + sheet_hover_cell.x
				cell_right_clicked.emit(pat)

	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_drag_active = false

	if hover_changed:
		queue_redraw()
