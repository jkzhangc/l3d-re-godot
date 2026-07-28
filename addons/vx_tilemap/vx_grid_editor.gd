@tool
extends Control
## VX Grid Editor — A4 图块裁剪网格可视化编辑器 v2（区域拖拽制）。
##
## 在 Godot 编辑器底部面板中运行，提供：
##   - 纹理 + 网格叠加 + 区域着色（屋顶绿 / 墙体蓝）
##   - 拖拽绘制矩形区域（DRAW_REGION 模式）
##   - 点击选中 / 删除区域（EDIT_REGION 模式）
##   - bitmask 分配（ASSIGN_ROOF / ASSIGN_WALL 模式）
##   - 3×3 邻居复选框 + 快速预设
##   - 组导航（◀ ▶）


# ═══════════════════════════════════════
# 编辑器模式
# ═══════════════════════════════════════

enum EditorMode {
	VIEW,          ## 点击 tile 查看其 bitmask 分配
	ASSIGN_ROOF,   ## 点击 tile → 分配当前 bitmask 到 roof_map
	ASSIGN_WALL,   ## 点击 tile → 分配当前 bitmask 到 wall_map
	DRAW_REGION,   ## 在纹理上拖拽绘制新区域
	EDIT_REGION,   ## 点击选中 / 调整已有区域
}


# ═══════════════════════════════════════
# 常用 bitmask 预设
# ═══════════════════════════════════════

const BITMASK_PRESETS: Array[Dictionary] = [
	{ "label": "中央 255",   "bitmask": 255, "desc": "8 方向全有墙" },
	{ "label": "TL外角 38",  "bitmask": 38,  "desc": "右下有墙" },
	{ "label": "T边 110",   "bitmask": 110, "desc": "左右下有墙" },
	{ "label": "TR外角 76",  "bitmask": 76,  "desc": "左下" },
	{ "label": "L边 55",    "bitmask": 55,  "desc": "上下右" },
	{ "label": "R边 205",   "bitmask": 205, "desc": "上下左" },
	{ "label": "BL外角 19",  "bitmask": 19,  "desc": "上右" },
	{ "label": "B边 155",   "bitmask": 155, "desc": "上左右" },
	{ "label": "BR外角 137", "bitmask": 137, "desc": "上左" },
	{ "label": "孤立 0",     "bitmask": 0,   "desc": "无邻居" },
]


# ═══════════════════════════════════════
# 注入引用
# ═══════════════════════════════════════

var editor_interface: EditorInterface = null


# ═══════════════════════════════════════
# 状态
# ═══════════════════════════════════════

var _config: VXGridConfig = null
var _mode: EditorMode = EditorMode.VIEW
var _current_bitmask: int = 255
var _current_group: int = 0
var _selected_tile: Vector2i = Vector2i(-1, -1)
var _selected_region: int = -1       ## 选中的区域索引（-1 = 无）
var _draw_region_start: Vector2i = Vector2i(-1, -1)  ## 拖拽起点（tile 坐标）
var _draw_region_type: int = 0       ## 拖拽中的区域类型
var _draw_region_name: String = ""   ## 拖拽中的区域名称
var _zoom_level: float = 1.0
var _drag_active: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _scroll_ofs: Vector2 = Vector2.ZERO


# ═══════════════════════════════════════
# UI 节点引用
# ═══════════════════════════════════════

var _texture_ctrl: Control = null
var _texture_scroll: ScrollContainer = null
var _status_label: Label = null
var _bitmask_label: Label = null
var _tile_info_label: Label = null
var _mode_label: Label = null
var _group_label: Label = null
var _grid_cols_spin: SpinBox = null
var _grid_rows_spin: SpinBox = null
var _group_count_spin: SpinBox = null
var _neighbor_checks: Array[CheckBox] = []
var _region_list_vbox: VBoxContainer = null  ## 右侧区域列表容器
var _draw_region_type_btn: OptionButton = null
var _draw_region_name_edit: LineEdit = null


# ═══════════════════════════════════════
# 公开 API
# ═══════════════════════════════════════

func load_config(cfg: VXGridConfig) -> void:
	if cfg == null:
		return
	_config = cfg
	_config.ensure_cache()
	_current_group = 0
	_selected_tile = Vector2i(-1, -1)
	_selected_region = -1
	_sync_spinboxes()
	_refresh_region_list()
	_update_all()


func new_config() -> void:
	_config = VXGridConfig.new()
	_config.tile_size = 32
	_config.group_cols = 2
	_config.group_rows = 5
	_config.group_count = 6
	_config.source_texture = null
	_config.regions = []
	_current_group = 0
	_selected_tile = Vector2i(-1, -1)
	_selected_region = -1
	_sync_spinboxes()
	_refresh_region_list()
	_update_all()


# ═══════════════════════════════════════
# UI 构建
# ═══════════════════════════════════════

func _enter_tree() -> void:
	_build_ui()

	# 连接纹理控件信号
	if _texture_ctrl:
		if not _texture_ctrl.draw.is_connected(_on_texture_ctrl_draw):
			_texture_ctrl.draw.connect(_on_texture_ctrl_draw)
		if not _texture_ctrl.gui_input.is_connected(_on_texture_ctrl_gui_input):
			_texture_ctrl.gui_input.connect(_on_texture_ctrl_gui_input)

	if _config == null:
		new_config()

	call_deferred("_deferred_init_draw")


func _exit_tree() -> void:
	if _texture_ctrl:
		if _texture_ctrl.draw.is_connected(_on_texture_ctrl_draw):
			_texture_ctrl.draw.disconnect(_on_texture_ctrl_draw)
		if _texture_ctrl.gui_input.is_connected(_on_texture_ctrl_gui_input):
			_texture_ctrl.gui_input.disconnect(_on_texture_ctrl_gui_input)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.name = "VXGridEditorRoot"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.add_theme_constant_override("separation", 2)
	add_child(root)

	_build_toolbar(root)
	_build_main_area(root)
	_build_status_bar(root)


func _build_toolbar(parent: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.name = "Toolbar"
	bar.add_theme_constant_override("separation", 4)
	parent.add_child(bar)

	# 文件按钮
	bar.add_child(_make_button("加载纹理...", _on_load_texture))
	bar.add_child(_make_button("新建", _on_new_config))
	bar.add_child(_make_button("打开.tres...", _on_open_config))
	bar.add_child(_make_button("保存.tres...", _on_save_config))

	bar.add_child(_make_separator())

	# 组导航
	bar.add_child(_make_button("◀", _on_prev_group))
	_group_label = _make_label("组: 1/6")
	_group_label.custom_minimum_size = Vector2(55, 0)
	bar.add_child(_group_label)
	bar.add_child(_make_button("▶", _on_next_group))

	bar.add_child(_make_separator())

	# 网格参数
	bar.add_child(_make_label("列:"))
	_grid_cols_spin = _make_spinbox(1, 32, 2, _on_grid_params_changed)
	bar.add_child(_grid_cols_spin)
	bar.add_child(_make_label("行:"))
	_grid_rows_spin = _make_spinbox(1, 32, 5, _on_grid_params_changed)
	bar.add_child(_grid_rows_spin)
	bar.add_child(_make_label("组:"))
	_group_count_spin = _make_spinbox(1, 16, 6, _on_grid_params_changed)
	bar.add_child(_group_count_spin)

	bar.add_child(_make_separator())

	# 区域按钮
	bar.add_child(_make_button("+区域", _on_start_draw_region))
	bar.add_child(_make_button("编辑区域", _on_mode_edit_region))

	bar.add_child(_make_separator())

	# bitmask 分配模式
	bar.add_child(_make_button("查看", _on_mode_view))
	bar.add_child(_make_button("分配屋顶", _on_mode_assign_roof))
	bar.add_child(_make_button("分配墙体", _on_mode_assign_wall))
	_mode_label = _make_label("[查看]")
	_mode_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5, 0.9))
	bar.add_child(_mode_label)


func _build_main_area(parent: VBoxContainer) -> void:
	var split := HSplitContainer.new()
	split.name = "MainSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = -300  # 右侧约 300px
	parent.add_child(split)

	# ═══ 左侧：纹理预览 ═══
	var left := VBoxContainer.new()
	left.name = "TexturePanel"
	left.custom_minimum_size = Vector2(300, 200)
	split.add_child(left)

	var tex_hint := Label.new()
	tex_hint.text = "滚轮缩放 | 中键拖拽 | 模式决定左键行为"
	tex_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	tex_hint.add_theme_font_size_override("font_size", 10)
	left.add_child(tex_hint)

	_texture_scroll = ScrollContainer.new()
	_texture_scroll.name = "TextureScroll"
	_texture_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_texture_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_texture_scroll)

	_texture_ctrl = Control.new()
	_texture_ctrl.name = "TextureGrid"
	_texture_ctrl.mouse_filter = Control.MOUSE_FILTER_STOP
	_texture_scroll.add_child(_texture_ctrl)

	# ═══ 右侧面板 ═══
	var right := VBoxContainer.new()
	right.name = "RightPanel"
	right.custom_minimum_size = Vector2(220, 150)
	split.add_child(right)

	# -- 区域列表 --
	var rl_title := Label.new()
	rl_title.text = "已定义区域:"
	rl_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	rl_title.add_theme_font_size_override("font_size", 13)
	right.add_child(rl_title)

	_region_list_vbox = VBoxContainer.new()
	_region_list_vbox.name = "RegionList"
	_region_list_vbox.add_theme_constant_override("separation", 2)
	right.add_child(_region_list_vbox)

	right.add_child(_make_separator())

	# -- Bitmask 编辑 --
	var bm_title := Label.new()
	bm_title.text = "当前 Bitmask"
	bm_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	bm_title.add_theme_font_size_override("font_size", 13)
	right.add_child(bm_title)

	_bitmask_label = Label.new()
	_bitmask_label.text = "255  (0b11111111)"
	_bitmask_label.add_theme_color_override("font_color", Color(1, 1, 0, 0.9))
	_bitmask_label.add_theme_font_size_override("font_size", 16)
	right.add_child(_bitmask_label)

	right.add_child(_make_separator())

	# 3×3 邻居编辑
	var ng_label := Label.new()
	ng_label.text = "3×3 邻居（点击切换）:"
	ng_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	ng_label.add_theme_font_size_override("font_size", 12)
	right.add_child(ng_label)

	var ng_grid := GridContainer.new()
	ng_grid.columns = 3
	ng_grid.add_theme_constant_override("h_separation", 2)
	ng_grid.add_theme_constant_override("v_separation", 2)
	right.add_child(ng_grid)

	var neighbor_names := ["↖", "↑", "↗", "←", "●", "→", "↙", "↓", "↘"]
	var neighbor_bits  := [128, 1, 16, 8, -1, 2, 64, 4, 32]
	_neighbor_checks.clear()

	for i: int in range(9):
		if neighbor_bits[i] == -1:
			var cb := CheckBox.new()
			cb.text = "●"
			cb.button_pressed = true
			cb.disabled = true
			cb.add_theme_font_size_override("font_size", 14)
			ng_grid.add_child(cb)
			_neighbor_checks.append(cb)
		else:
			var cb := CheckBox.new()
			cb.text = neighbor_names[i]
			cb.tooltip_text = neighbor_names[i] + " (bit=%d)" % neighbor_bits[i]
			cb.button_pressed = (_current_bitmask & neighbor_bits[i]) != 0
			cb.toggled.connect(_on_neighbor_toggled)
			cb.add_theme_font_size_override("font_size", 14)
			ng_grid.add_child(cb)
			_neighbor_checks.append(cb)

	right.add_child(_make_separator())

	# 快速预设
	var preset_label := Label.new()
	preset_label.text = "快速预设:"
	preset_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	preset_label.add_theme_font_size_override("font_size", 12)
	right.add_child(preset_label)

	var preset_flow := FlowContainer.new()
	preset_flow.add_theme_constant_override("h_separation", 3)
	preset_flow.add_theme_constant_override("v_separation", 3)
	right.add_child(preset_flow)

	for preset: Dictionary in BITMASK_PRESETS:
		var btn := Button.new()
		btn.text = preset["label"]
		btn.tooltip_text = preset["desc"]
		btn.custom_minimum_size = Vector2(78, 22)
		btn.add_theme_font_size_override("font_size", 10)
		btn.pressed.connect(_on_preset_pressed.bind(preset["bitmask"]))
		preset_flow.add_child(btn)

	right.add_child(_make_separator())

	# 选中 tile 信息
	_tile_info_label = Label.new()
	_tile_info_label.text = "选中: 无"
	_tile_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	_tile_info_label.add_theme_font_size_override("font_size", 11)
	right.add_child(_tile_info_label)


func _build_status_bar(parent: VBoxContainer) -> void:
	_status_label = Label.new()
	_status_label.text = "就绪"
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_status_label.add_theme_font_size_override("font_size", 11)
	parent.add_child(_status_label)


# ═══════════════════════════════════════
# UI 辅助方法
# ═══════════════════════════════════════

func _make_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(36, 26)
	btn.add_theme_font_size_override("font_size", 12)
	btn.pressed.connect(callback)
	return btn


func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _make_separator() -> ColorRect:
	var sep := ColorRect.new()
	sep.size = Vector2(1, 22)
	sep.color = Color(1, 1, 1, 0.15)
	sep.custom_minimum_size = Vector2(1, 0)
	return sep


func _make_spinbox(min_v: int, max_v: int, default_v: int, callback: Callable) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.value = default_v
	sb.custom_minimum_size = Vector2(42, 24)
	sb.value_changed.connect(callback)
	return sb


# ═══════════════════════════════════════
# 区域列表刷新
# ═══════════════════════════════════════

func _refresh_region_list() -> void:
	if not _region_list_vbox:
		return

	# 清除旧子节点
	for child: Node in _region_list_vbox.get_children():
		child.queue_free()

	if not _config or _config.regions.is_empty():
		var lbl := Label.new()
		lbl.text = "（无区域）"
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		lbl.add_theme_font_size_override("font_size", 11)
		_region_list_vbox.add_child(lbl)
		return

	var type_names := ["屋顶", "墙体"]
	var type_colors := [Color(0.3, 1.0, 0.3, 0.7), Color(0.4, 0.6, 1.0, 0.7)]

	for i: int in range(_config.regions.size()):
		var region: Dictionary = _config.regions[i]
		var r: Rect2i = region["rect"]
		var rtype: int = region["type"]
		var rname: String = region.get("name", "区域%d" % i)

		var row := HBoxContainer.new()
		row.name = "RegionRow_%d" % i
		row.add_theme_constant_override("separation", 3)

		# 类型色块
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(10, 16)
		swatch.color = type_colors[rtype] if rtype < type_colors.size() else Color.GRAY
		row.add_child(swatch)

		# 名称按钮（点击选中）
		var name_btn := Button.new()
		name_btn.text = rname
		name_btn.tooltip_text = "%s  (%d,%d %d×%d)" % [type_names[rtype], r.position.x, r.position.y, r.size.x, r.size.y]
		name_btn.add_theme_font_size_override("font_size", 11)
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.pressed.connect(_on_region_row_clicked.bind(i))
		if i == _selected_region:
			name_btn.add_theme_color_override("font_color", Color.YELLOW)
		row.add_child(name_btn)

		# 删除按钮
		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.custom_minimum_size = Vector2(22, 20)
		del_btn.add_theme_font_size_override("font_size", 12)
		del_btn.tooltip_text = "删除区域 \"%s\"" % rname
		del_btn.pressed.connect(_on_region_delete.bind(i))
		row.add_child(del_btn)

		_region_list_vbox.add_child(row)


# ═══════════════════════════════════════
# 纹理网格绘制
# ═══════════════════════════════════════

func _draw_texture_grid() -> void:
	if _texture_ctrl:
		_texture_ctrl.queue_redraw()


func _on_texture_ctrl_draw() -> void:
	if not _config:
		_draw_placeholder()
		return

	var tex: Texture2D = _config.source_texture
	if not tex:
		_draw_placeholder()
		return

	var ctrl: Control = _texture_ctrl
	var ts: int = _config.tile_size
	var zoom: float = _zoom_level
	var draw_ts: float = float(ts) * zoom
	var total_c: int = _config.total_cols()
	var total_r: int = _config.total_rows()
	var ofs: Vector2 = _scroll_ofs

	# 1. 纹理
	ctrl.draw_texture_rect(tex, Rect2(ofs, Vector2(float(total_c) * draw_ts, float(total_r) * draw_ts)), false)

	# 2. 区域着色
	for region: Dictionary in _config.regions:
		var r: Rect2i = region["rect"]
		var rtype: int = region["type"]
		var color: Color
		if rtype == VXGridConfig.RegionType.ROOF:
			color = Color(0.2, 0.85, 0.2, 0.10)
		else:
			color = Color(0.25, 0.35, 1.0, 0.10)

		var draw_rect := Rect2(
			Vector2(float(r.position.x) * draw_ts, float(r.position.y) * draw_ts) + ofs,
			Vector2(float(r.size.x) * draw_ts, float(r.size.y) * draw_ts)
		)
		ctrl.draw_rect(draw_rect, color, true)
		ctrl.draw_rect(draw_rect, Color(color.r, color.g, color.b, 0.5), false, 1.0)

		# 标签
		if zoom > 0.35:
			var font := ThemeDB.fallback_font
			var font_size: int = max(7, int(8 * zoom))
			var lbl: String = region.get("name", "?")
			ctrl.draw_string(font, draw_rect.position + Vector2(2, draw_rect.size.y - 2), lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.55))

	# 3. 网格线
	var grid_weak := Color(1, 1, 1, 0.10)
	var grid_strong := Color(1, 1, 1, 0.30)
	var group_boundary := Color(1, 0.8, 0.3, 0.4)

	for x: int in range(total_c + 1):
		var lx: float = float(x) * draw_ts + ofs.x
		var color: Color = grid_weak
		var width: float = 0.5
		if x % _config.group_cols == 0:
			color = group_boundary
			width = 1.5
		ctrl.draw_line(Vector2(lx, ofs.y), Vector2(lx, ofs.y + float(total_r) * draw_ts), color, width)

	for y: int in range(total_r + 1):
		var ly: float = float(y) * draw_ts + ofs.y
		ctrl.draw_line(Vector2(ofs.x, ly), Vector2(ofs.x + float(total_c) * draw_ts, ly), grid_weak, 0.5)

	# 4. 已分配 bitmask 的 tile 标签
	var font := ThemeDB.fallback_font
	var font_size: int = max(8, int(9 * zoom))

	for bm: int in _config.roof_map:
		var coord: Vector2i = _config.roof_map[bm]
		_draw_labeled_cell(ctrl, coord, bm, font, font_size, Color(0.3, 1.0, 0.3, 0.45), ofs, draw_ts)
	for bm: int in _config.wall_map:
		var coord: Vector2i = _config.wall_map[bm]
		_draw_labeled_cell(ctrl, coord, bm, font, font_size, Color(0.4, 0.6, 1.0, 0.45), ofs, draw_ts)

	var iso_coord: Vector2i = _config.isolated_roof_coord
	_draw_labeled_cell(ctrl, iso_coord, 0, font, font_size, Color(1.0, 0.6, 0.2, 0.35), ofs, draw_ts)

	# 5. 当前组高亮
	var gx_hl: float = float(_current_group * _config.group_cols) * draw_ts + ofs.x
	ctrl.draw_rect(Rect2(gx_hl, ofs.y, float(_config.group_cols) * draw_ts, float(total_r) * draw_ts),
		Color(1, 0.85, 0.2, 0.07), true)
	ctrl.draw_rect(Rect2(gx_hl, ofs.y, float(_config.group_cols) * draw_ts, float(total_r) * draw_ts),
		Color(1, 0.85, 0.2, 0.35), false, 1.5)

	# 6. 选中区域高亮
	if _selected_region >= 0 and _selected_region < _config.regions.size():
		var sr_region: Dictionary = _config.regions[_selected_region]
		var sr: Rect2i = sr_region["rect"]
		var sr_draw := Rect2(
			Vector2(float(sr.position.x) * draw_ts, float(sr.position.y) * draw_ts) + ofs,
			Vector2(float(sr.size.x) * draw_ts, float(sr.size.y) * draw_ts)
		)
		ctrl.draw_rect(sr_draw, Color(1, 1, 0, 0.12), true)
		ctrl.draw_rect(sr_draw, Color.YELLOW, false, 2.0)

	# 7. 拖拽中的区域预览（虚线效果用半透明+描边模拟）
	if _draw_region_start.x >= 0 and _mode == EditorMode.DRAW_REGION:
		var end_tile := _selected_tile  # 鼠标当前位置
		if end_tile.x >= 0:
			var x1: int = min(_draw_region_start.x, end_tile.x)
			var y1: int = min(_draw_region_start.y, end_tile.y)
			var x2: int = max(_draw_region_start.x, end_tile.x)
			var y2: int = max(_draw_region_start.y, end_tile.y)
			var prev_color := Color(1, 1, 0, 0.2) if _draw_region_type == 0 else Color(0.6, 0.8, 1, 0.2)
			var prev_rect := Rect2(
				Vector2(float(x1) * draw_ts, float(y1) * draw_ts) + ofs,
				Vector2(float(x2 - x1 + 1) * draw_ts, float(y2 - y1 + 1) * draw_ts)
			)
			ctrl.draw_rect(prev_rect, prev_color, true)
			ctrl.draw_rect(prev_rect, Color(1, 0.9, 0.3, 0.7), false, 2.0)

	# 8. 选中 tile 高亮
	if _selected_tile.x >= 0 and _selected_tile.y >= 0:
		var sr := Rect2(
			Vector2(float(_selected_tile.x) * draw_ts, float(_selected_tile.y) * draw_ts) + ofs,
			Vector2(draw_ts, draw_ts)
		)
		ctrl.draw_rect(sr, Color(1, 1, 0, 0.2), true)
		ctrl.draw_rect(sr, Color.YELLOW, false, 1.5)

	_texture_ctrl.custom_minimum_size = Vector2(float(total_c) * draw_ts + 30, float(total_r) * draw_ts + 10)


func _draw_labeled_cell(ctrl: Control, coord: Vector2i, bitmask: int, font: Font,
		font_size: int, color: Color, ofs: Vector2, draw_ts: float) -> void:
	var rect := Rect2(
		Vector2(float(coord.x) * draw_ts, float(coord.y) * draw_ts) + ofs,
		Vector2(draw_ts, draw_ts)
	)
	ctrl.draw_rect(rect, color, true)
	ctrl.draw_rect(rect, Color(color.r, color.g, color.b, 0.85), false, 1.0)

	if _zoom_level > 0.35:
		var label_pos := Vector2(float(coord.x) * draw_ts + 2, float(coord.y) * draw_ts + draw_ts - 2) + ofs
		ctrl.draw_string(font, label_pos, str(bitmask),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.8))


func _draw_placeholder() -> void:
	if not _texture_ctrl:
		return
	var ctrl: Control = _texture_ctrl
	var font := ThemeDB.fallback_font
	var msg: String
	if _config == null:
		msg = "未加载配置\n点击 [新建] 或 [打开.tres...]"
	elif _config.source_texture == null:
		msg = "未加载纹理\n点击 [加载纹理...]"
	else:
		msg = "..."
	ctrl.draw_string(font, Vector2(20, 40), msg,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.6, 0.6, 0.8))
	ctrl.custom_minimum_size = Vector2(320, 200)


# ═══════════════════════════════════════
# 纹理控件输入处理
# ═══════════════════════════════════════

func _on_texture_ctrl_gui_input(event: InputEvent) -> void:
	var mev := event as InputEventMouseButton

	if mev:
		# 滚轮缩放
		if mev.button_index == MOUSE_BUTTON_WHEEL_UP and mev.pressed:
			_zoom_level = clamp(_zoom_level * 1.2, 0.15, 6.0)
			_draw_texture_grid()
			return
		if mev.button_index == MOUSE_BUTTON_WHEEL_DOWN and mev.pressed:
			_zoom_level = clamp(_zoom_level / 1.2, 0.15, 6.0)
			_draw_texture_grid()
			return

		# 中键拖拽
		if mev.button_index == MOUSE_BUTTON_MIDDLE:
			if mev.pressed:
				_drag_active = true
				_drag_start = mev.position - _scroll_ofs
			else:
				_drag_active = false
			return

		# 左键按下
		if mev.button_index == MOUSE_BUTTON_LEFT and mev.pressed:
			var tile := _screen_to_tile(mev.position)
			match _mode:
				EditorMode.DRAW_REGION:
					# 开始拖拽
					if tile.x >= 0 and tile.y >= 0:
						_draw_region_start = tile
						_selected_tile = tile
						_draw_texture_grid()
				EditorMode.EDIT_REGION:
					_on_edit_region_click(tile)
				_:
					if tile.x >= 0 and tile.y >= 0:
						_on_tile_clicked(tile)
			return

		# 左键松开 — 完成拖拽
		if mev.button_index == MOUSE_BUTTON_LEFT and not mev.pressed:
			if _mode == EditorMode.DRAW_REGION and _draw_region_start.x >= 0:
				var end_tile := _screen_to_tile(mev.position)
				if end_tile.x >= 0 and end_tile.y >= 0:
					_finish_draw_region(end_tile)
				else:
					_draw_region_start = Vector2i(-1, -1)
					_draw_texture_grid()
			return

		# 右键
		if mev.button_index == MOUSE_BUTTON_RIGHT and mev.pressed:
			var tile := _screen_to_tile(mev.position)
			if tile.x >= 0 and tile.y >= 0:
				_on_tile_right_clicked(tile)
			return

	# 中键拖拽移动
	if event is InputEventMouseMotion:
		var mev_motion := event as InputEventMouseMotion

		if _drag_active:
			_scroll_ofs = mev_motion.position - _drag_start
			_draw_texture_grid()
			return

		# DRAW_REGION 模式下实时更新预览
		if _mode == EditorMode.DRAW_REGION and _draw_region_start.x >= 0:
			var tile := _screen_to_tile(mev_motion.position)
			if tile.x >= 0 and tile.y >= 0:
				_selected_tile = tile
				_draw_texture_grid()


func _screen_to_tile(screen_pos: Vector2) -> Vector2i:
	if not _config:
		return Vector2i(-1, -1)

	var draw_ts: float = float(_config.tile_size) * _zoom_level
	var local: Vector2 = screen_pos - _scroll_ofs
	var col: int = int(floor(local.x / draw_ts))
	var row: int = int(floor(local.y / draw_ts))

	if col < 0 or col >= _config.total_cols() or row < 0 or row >= _config.total_rows():
		return Vector2i(-1, -1)

	return Vector2i(col, row)


# ═══════════════════════════════════════
# 区域管理 — 拖拽绘制
# ═══════════════════════════════════════

func _on_start_draw_region() -> void:
	_mode = EditorMode.DRAW_REGION
	_mode_label.text = "[拖拽区域]"
	_mode_label.add_theme_color_override("font_color", Color(1, 0.9, 0.3, 0.9))
	_draw_region_start = Vector2i(-1, -1)
	_selected_region = -1
	_selected_tile = Vector2i(-1, -1)

	# 弹出简单对话框选择区域类型和名称
	_show_draw_region_dialog()


func _show_draw_region_dialog() -> void:
	# 使用 AcceptDialog 简单选择
	var dlg := AcceptDialog.new()
	dlg.name = "DrawRegionDialog"
	dlg.title = "新建区域"
	dlg.size = Vector2(280, 150)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	dlg.add_child(vbox)

	# 类型选择
	var type_hbox := HBoxContainer.new()
	var type_lbl := Label.new()
	type_lbl.text = "类型: "
	type_hbox.add_child(type_lbl)

	var type_opt := OptionButton.new()
	type_opt.name = "TypeOption"
	type_opt.add_item("屋顶 (Roof)", VXGridConfig.RegionType.ROOF)
	type_opt.add_item("墙体 (Wall)", VXGridConfig.RegionType.WALL)
	type_opt.selected = _draw_region_type
	type_hbox.add_child(type_opt)
	vbox.add_child(type_hbox)

	# 名称输入
	var name_hbox := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "名称: "
	name_hbox.add_child(name_lbl)

	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.text = _draw_region_name if _draw_region_name != "" else "区域%d" % _config.regions.size()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_hbox.add_child(name_edit)
	vbox.add_child(name_hbox)

	var hint := Label.new()
	hint.text = "确定后在纹理上拖拽绘制区域"
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	hint.add_theme_font_size_override("font_size", 10)
	vbox.add_child(hint)

	dlg.confirmed.connect(_on_draw_region_dialog_confirmed.bind(dlg, type_opt, name_edit))
	dlg.canceled.connect(_on_draw_region_dialog_canceled.bind(dlg))

	add_child(dlg)
	dlg.popup_centered()


func _on_draw_region_dialog_confirmed(dlg: AcceptDialog, type_opt: OptionButton, name_edit: LineEdit) -> void:
	_draw_region_type = type_opt.get_selected_id()
	_draw_region_name = name_edit.text.strip_edges()
	if _draw_region_name == "":
		_draw_region_name = "区域%d" % _config.regions.size()
	dlg.queue_free()
	_draw_texture_grid()


func _on_draw_region_dialog_canceled(dlg: AcceptDialog) -> void:
	dlg.queue_free()
	_mode = EditorMode.VIEW
	_mode_label.text = "[查看]"
	_draw_region_start = Vector2i(-1, -1)
	_draw_texture_grid()


func _finish_draw_region(end_tile: Vector2i) -> void:
	if _draw_region_start.x < 0:
		return

	var x1: int = min(_draw_region_start.x, end_tile.x)
	var y1: int = min(_draw_region_start.y, end_tile.y)
	var x2: int = max(_draw_region_start.x, end_tile.x)
	var y2: int = max(_draw_region_start.y, end_tile.y)

	var rect := Rect2i(x1, y1, x2 - x1 + 1, y2 - y1 + 1)
	_config.add_region(_draw_region_name, rect, _draw_region_type)
	print("[VXGrid] 创建区域 \"%s\" %s (类型=%s)" % [
		_draw_region_name, rect, "屋顶" if _draw_region_type == 0 else "墙体"])

	_draw_region_start = Vector2i(-1, -1)
	_mode = EditorMode.VIEW
	_mode_label.text = "[查看]"
	_mode_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5, 0.9))
	_selected_region = _config.regions.size() - 1

	_refresh_region_list()
	_draw_texture_grid()
	_update_all()


# ═══════════════════════════════════════
# 区域管理 — 选中 / 删除
# ═══════════════════════════════════════

func _on_mode_edit_region() -> void:
	_mode = EditorMode.EDIT_REGION
	_mode_label.text = "[编辑区域]"
	_mode_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 0.9))
	_draw_texture_grid()


func _on_edit_region_click(tile: Vector2i) -> void:
	if not _config:
		return

	# 查找点击位置所属的区域
	var found: int = -1
	for i: int in range(_config.regions.size()):
		var r: Rect2i = _config.regions[i]["rect"]
		if r.has_point(tile):
			found = i
			break

	_selected_region = found
	_selected_tile = tile

	if found >= 0:
		var region: Dictionary = _config.regions[found]
		print("[VXGrid] 选中区域 \"%s\" (索引=%d)" % [region.get("name", "?"), found])

	_refresh_region_list()
	_draw_texture_grid()
	_update_tile_info()


func _on_region_row_clicked(index: int) -> void:
	_selected_region = index
	_mode = EditorMode.EDIT_REGION
	_mode_label.text = "[编辑区域]"
	_mode_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3, 0.9))
	_refresh_region_list()
	_draw_texture_grid()
	print("[VXGrid] 选中区域索引=%d" % index)


func _on_region_delete(index: int) -> void:
	if not _config:
		return
	var rname: String = _config.regions[index].get("name", "区域%d" % index)
	_config.remove_region(index)

	if _selected_region == index:
		_selected_region = -1
	elif _selected_region > index:
		_selected_region -= 1

	print("[VXGrid] 已删除区域 \"%s\"" % rname)
	_refresh_region_list()
	_draw_texture_grid()
	_update_all()


# ═══════════════════════════════════════
# 交互逻辑
# ═══════════════════════════════════════

func _on_tile_clicked(global_tile: Vector2i) -> void:
	_selected_tile = global_tile

	match _mode:
		EditorMode.VIEW:
			_update_tile_info()
		EditorMode.ASSIGN_ROOF:
			_assign_bitmask(global_tile, true)
		EditorMode.ASSIGN_WALL:
			_assign_bitmask(global_tile, false)

	_draw_texture_grid()
	_update_all()


func _on_tile_right_clicked(global_tile: Vector2i) -> void:
	var found_roof: Array = []
	var found_wall: Array = []

	for bm: int in _config.roof_map:
		if _config.roof_map[bm] == global_tile:
			found_roof.append(bm)
	for bm: int in _config.wall_map:
		if _config.wall_map[bm] == global_tile:
			found_wall.append(bm)

	for bm: int in found_roof:
		_config.roof_map.erase(bm)
	for bm: int in found_wall:
		_config.wall_map.erase(bm)

	if _config.isolated_roof_coord == global_tile:
		_config.isolated_roof_coord = Vector2i(0, 0)

	if found_roof.size() > 0 or found_wall.size() > 0:
		_config._build_cache()
		print("[VXGrid] 已清除 tile %s (roof:%d wall:%d)" % [global_tile, found_roof.size(), found_wall.size()])

	_draw_texture_grid()
	_update_all()


func _assign_bitmask(global_tile: Vector2i, is_roof: bool) -> void:
	if not _config:
		return

	# 先从对方的 map 中移除
	if is_roof:
		var to_remove: Array = []
		for bm: int in _config.wall_map:
			if _config.wall_map[bm] == global_tile:
				to_remove.append(bm)
		for bm: int in to_remove:
			_config.wall_map.erase(bm)
	else:
		var to_remove: Array = []
		for bm: int in _config.roof_map:
			if _config.roof_map[bm] == global_tile:
				to_remove.append(bm)
		for bm: int in to_remove:
			_config.roof_map.erase(bm)

	if _current_bitmask == 0:
		_config.isolated_roof_coord = global_tile
	else:
		if is_roof:
			_config.roof_map[_current_bitmask] = global_tile
		else:
			_config.wall_map[_current_bitmask] = global_tile

	_config._build_cache()
	print("[VXGrid] bitmask=%d → tile=%s (%s)" % [
		_current_bitmask, global_tile, "屋顶" if is_roof else "墙体"])


# ═══════════════════════════════════════
# Bitmask 编辑
# ═══════════════════════════════════════

func _on_neighbor_toggled(_pressed: bool) -> void:
	_recalc_bitmask_from_checks()


func _recalc_bitmask_from_checks() -> void:
	var bits: int = 0
	var neighbor_bits := [128, 1, 16, 8, -1, 2, 64, 4, 32]
	for i: int in range(9):
		if neighbor_bits[i] == -1:
			continue
		if _neighbor_checks[i].button_pressed:
			bits |= neighbor_bits[i]
	_current_bitmask = bits
	_update_bitmask_display()


func _on_preset_pressed(bitmask: int) -> void:
	_current_bitmask = bitmask
	_update_neighbor_checks()
	_update_bitmask_display()


func _update_neighbor_checks() -> void:
	var neighbor_bits := [128, 1, 16, 8, -1, 2, 64, 4, 32]
	for i: int in range(9):
		if neighbor_bits[i] == -1:
			continue
		_neighbor_checks[i].set_pressed_no_signal((_current_bitmask & neighbor_bits[i]) != 0)


func _update_bitmask_display() -> void:
	if _bitmask_label:
		var bin_str: String = ""
		for i: int in range(8):
			bin_str = ("1" if (_current_bitmask >> i) & 1 else "0") + bin_str
		_bitmask_label.text = "%d  (0b%s)" % [_current_bitmask, bin_str]


# ═══════════════════════════════════════
# 模式切换
# ═══════════════════════════════════════

func _on_mode_view() -> void:
	_mode = EditorMode.VIEW
	_mode_label.text = "[查看]"
	_mode_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5, 0.9))
	_draw_region_start = Vector2i(-1, -1)


func _on_mode_assign_roof() -> void:
	_mode = EditorMode.ASSIGN_ROOF
	_mode_label.text = "[分配屋顶]"
	_mode_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4, 0.9))
	_draw_region_start = Vector2i(-1, -1)


func _on_mode_assign_wall() -> void:
	_mode = EditorMode.ASSIGN_WALL
	_mode_label.text = "[分配墙体]"
	_mode_label.add_theme_color_override("font_color", Color(0.4, 0.5, 1.0, 0.9))
	_draw_region_start = Vector2i(-1, -1)


# ═══════════════════════════════════════
# 组导航
# ═══════════════════════════════════════

func _on_prev_group() -> void:
	if not _config:
		return
	_current_group = max(0, _current_group - 1)
	_draw_texture_grid()
	_update_group_label()


func _on_next_group() -> void:
	if not _config:
		return
	_current_group = min(_config.group_count - 1, _current_group + 1)
	_draw_texture_grid()
	_update_group_label()


func _update_group_label() -> void:
	if _group_label and _config:
		_group_label.text = "组: %d/%d" % [_current_group + 1, _config.group_count]


# ═══════════════════════════════════════
# 网格参数回调
# ═══════════════════════════════════════

func _on_grid_params_changed(_v: float) -> void:
	if not _config:
		return
	_config.group_cols = int(_grid_cols_spin.value)
	_config.group_rows = int(_grid_rows_spin.value)
	_config.group_count = int(_group_count_spin.value)
	_config._build_cache()
	_draw_texture_grid()
	_update_all()


func _sync_spinboxes() -> void:
	if not _config:
		return
	if _grid_cols_spin:   _grid_cols_spin.value = _config.group_cols
	if _grid_rows_spin:   _grid_rows_spin.value = _config.group_rows
	if _group_count_spin: _group_count_spin.value = _config.group_count


# ═══════════════════════════════════════
# 文件操作
# ═══════════════════════════════════════

func _on_load_texture() -> void:
	var fd := EditorFileDialog.new()
	fd.name = "LoadTextureDialog"
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.title = "加载图块纹理"
	fd.add_filter("*.png", "PNG 图像")
	fd.file_selected.connect(_on_texture_file_selected.bind(fd))
	fd.canceled.connect(_on_dialog_cancel.bind(fd))
	add_child(fd)
	fd.popup_centered_ratio(0.7)


func _on_texture_file_selected(path: String, dialog: EditorFileDialog) -> void:
	dialog.queue_free()
	var tex: Texture2D = load(path) as Texture2D
	if tex:
		_config.source_texture = tex
		# 自动适配 group_cols/group_rows
		var tw: int = tex.get_width() / _config.tile_size
		var th: int = tex.get_height() / _config.tile_size
		if tw > 0 and th > 0:
			# 尝试推断格式
			if tw == 16 and th == 15:
				# 标准 VX Ace A4: 2列×5行×6组 + 剩4列
				_config.group_cols = 2
				_config.group_rows = 5
				_config.group_count = 6
			else:
				_config.group_cols = tw
				_config.group_rows = th
				_config.group_count = 1
			_sync_spinboxes()
		_config._build_cache()
		_draw_texture_grid()
		_update_all()
		print("[VXGrid] 已加载纹理: %s (%dx%d)" % [path, tex.get_width(), tex.get_height()])
	else:
		push_error("[VXGrid] 无法加载纹理: %s" % path)


func _on_new_config() -> void:
	new_config()
	_draw_texture_grid()
	_update_all()
	print("[VXGrid] 创建新配置")


func _on_open_config() -> void:
	var fd := EditorFileDialog.new()
	fd.name = "OpenConfigDialog"
	fd.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.title = "打开 VXGridConfig .tres"
	fd.add_filter("*.tres", "Godot Resource 文件")
	fd.file_selected.connect(_on_config_file_selected.bind(fd))
	fd.canceled.connect(_on_dialog_cancel.bind(fd))
	add_child(fd)
	fd.popup_centered_ratio(0.7)


func _on_config_file_selected(path: String, dialog: EditorFileDialog) -> void:
	dialog.queue_free()
	var res: Resource = load(path)
	if res is VXGridConfig:
		load_config(res as VXGridConfig)
		_draw_texture_grid()
		_update_all()
		print("[VXGrid] 已加载配置: %s" % path)
	else:
		push_error("[VXGrid] 不是有效的 VXGridConfig: %s" % path)


func _on_save_config() -> void:
	if not _config:
		push_error("[VXGrid] 没有配置可保存")
		return

	var errors: Array[String] = _config.validate()
	if errors.size() > 0:
		for err: String in errors:
			push_warning("[VXGrid] 验证警告: %s" % err)

	var fd := EditorFileDialog.new()
	fd.name = "SaveConfigDialog"
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.title = "保存 VXGridConfig .tres"
	fd.add_filter("*.tres", "Godot Resource 文件")
	fd.file_selected.connect(_on_save_path_selected.bind(fd))
	fd.canceled.connect(_on_dialog_cancel.bind(fd))
	add_child(fd)
	fd.popup_centered_ratio(0.7)


func _on_save_path_selected(path: String, dialog: EditorFileDialog) -> void:
	dialog.queue_free()
	var err: int = ResourceSaver.save(_config, path)
	if err == OK:
		print("[VXGrid] 配置已保存: %s" % path)
		_update_status("已保存: %s" % path)
	else:
		push_error("[VXGrid] 保存失败: %s (error %d)" % [path, err])


func _on_dialog_cancel(dialog: EditorFileDialog) -> void:
	dialog.queue_free()


# ═══════════════════════════════════════
# UI 更新
# ═══════════════════════════════════════

func _update_all() -> void:
	_update_bitmask_display()
	_update_group_label()
	_update_tile_info()
	_update_status("")


func _update_tile_info() -> void:
	if not _tile_info_label or not _config:
		return

	if _selected_tile.x < 0:
		_tile_info_label.text = "选中: 无"
		return

	var group: int = _config.get_group_at_col(_selected_tile.x)
	var local_col: int = _selected_tile.x % _config.group_cols
	var local_row: int = _selected_tile.y
	var rt := _config.get_region_type_at(_selected_tile.x, _selected_tile.y)

	var info := "选中: (%d,%d) [组%d 局部(%d,%d)]" % [
		_selected_tile.x, _selected_tile.y, group, local_col, local_row]

	if rt == VXGridConfig.RegionType.ROOF:
		info += " 屋顶区域"
	elif rt == VXGridConfig.RegionType.WALL:
		info += " 墙体区域"

	# 已有分配
	var assigned: String = ""
	for bm: int in _config.roof_map:
		if _config.roof_map[bm] == _selected_tile:
			assigned += " roof:%d" % bm
	for bm: int in _config.wall_map:
		if _config.wall_map[bm] == _selected_tile:
			assigned += " wall:%d" % bm
	if _config.isolated_roof_coord == _selected_tile:
		assigned += " isolated"

	if assigned != "":
		info += " | 已分配:" + assigned
	else:
		info += " | 未分配"

	_tile_info_label.text = info


func _update_status(msg: String) -> void:
	if not _status_label:
		return

	if msg != "":
		_status_label.text = msg
		return

	if not _config:
		_status_label.text = "未加载配置"
		return

	var tex_info: String = "无纹理"
	if _config.source_texture:
		var tex: Texture2D = _config.source_texture
		tex_info = "%s (%dx%d)" % [tex.resource_path.get_file(), tex.get_width(), tex.get_height()]

	var mapped := _config.get_mapped_tile_count()
	var mode_names := ["查看", "分配屋顶", "分配墙体", "拖拽区域", "编辑区域"]
	_status_label.text = "%s | %d×%d tiles | %d组 | %d区域 | 已分配:%d | %s" % [
		tex_info,
		_config.total_cols(), _config.total_rows(),
		_config.group_count,
		_config.regions.size(),
		mapped,
		mode_names[_mode] if _mode < mode_names.size() else "?"
	]


func _deferred_init_draw() -> void:
	if _config == null:
		new_config()
	_refresh_region_list()
	_update_all()
	_draw_texture_grid()
